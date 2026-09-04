import Foundation

/// Collects everything a child process writes to one pipe, optionally
/// delivering complete lines as they arrive. Reads happen on the file
/// handle's own readability queue, never on a Swift cooperative thread, so
/// callers can `await waitForEOF()` without parking an executor.
///
/// Line buffering happens on raw bytes: a chunk boundary can split a
/// multibyte UTF-8 character, and decoding such a chunk in isolation would
/// silently drop it. The newline search is incremental — bytes already
/// scanned are never rescanned — so a single huge line (the helper's final
/// JSON payload) costs O(n), not O(n²).
final class PipeCollector: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var storage = Data()
    private var pendingData = Data()
    /// Prefix of `pendingData` already known to contain no newline.
    private var scannedCount = 0
    private let onLine: (@Sendable (String) -> Void)?
    /// Whether every byte is kept for `data()`/`text()`. A long-lived worker
    /// only needs its lines delivered; retaining them would grow forever.
    private let retainsData: Bool
    private var didReachEOF = false
    private var eofContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(retainsData: Bool = true, onLine: (@Sendable (String) -> Void)? = nil) {
        self.onLine = onLine
        self.retainsData = retainsData
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                // Empty read signals EOF: the process closed its write end.
                handle.readabilityHandler = nil
                self.signalEOF()
            } else {
                self.ingest(data)
            }
        }
    }

    /// Suspends until the pipe has been fully drained to EOF. Resolves
    /// immediately if EOF was already observed, and resolves early if the
    /// waiting task is cancelled (a lingering grandchild can hold a pipe
    /// open indefinitely; callers that must not hang race this against a
    /// timeout).
    func waitForEOF() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didReachEOF || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                eofContinuations[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = eofContinuations.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume()
        }
    }

    private func signalEOF() {
        lock.lock()
        // Deliver the unterminated final line before notifying drain waiters.
        // Readability callbacks are serialized on the file handle's queue.
        let tail = pendingData.isEmpty ? nil : String(decoding: pendingData, as: UTF8.self)
        pendingData.removeAll()
        scannedCount = 0
        lock.unlock()
        if let tail { onLine?(tail) }
        lock.lock()
        didReachEOF = true
        let continuations = Array(eofContinuations.values)
        eofContinuations.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func text() -> String {
        String(data: data(), encoding: .utf8) ?? ""
    }

    func close() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Appends bytes exactly as the readability handler does. Exposed so
    /// tests can feed split reads without a live process.
    func ingest(_ data: Data) {
        var completeLines: [String] = []

        lock.lock()
        if retainsData {
            storage.append(data)
        }
        if onLine != nil {
            pendingData.append(data)
            let newline = UInt8(ascii: "\n")
            while let newlineIndex = pendingData[(pendingData.startIndex + scannedCount)...].firstIndex(of: newline) {
                let line = String(decoding: pendingData[pendingData.startIndex..<newlineIndex], as: UTF8.self)
                completeLines.append(line)
                pendingData.removeSubrange(pendingData.startIndex...newlineIndex)
                scannedCount = 0
            }
            scannedCount = pendingData.count
        }
        lock.unlock()

        completeLines.forEach { onLine?($0) }
    }
}
