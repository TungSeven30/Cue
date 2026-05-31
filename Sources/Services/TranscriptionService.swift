import Foundation

struct TranscriptionResult {
    let backend: String
    let segments: [TranscriptionSegment]
}

enum TranscriptionServiceError: LocalizedError {
    case pythonFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .pythonFailed(let message):
            return message
        case .malformedResponse:
            return "The transcription helper returned malformed JSON."
        }
    }
}

struct TranscriptionService {
    @MainActor
    func transcribe(
        videoURL: URL,
        settings: AppSettingsStore,
        progress: @escaping @MainActor (JobProgress) -> Void
    ) async throws -> TranscriptionResult {
        let snapshot = TranscriptionSettingsSnapshot(
            sourceLanguage: settings.sourceLanguage,
            whisperModel: settings.whisperModel,
            whisperBackendRawValue: settings.whisperBackend.rawValue
        )

        let scriptURL = try BackendScriptWriter.ensureScript()
        let processBox = ProcessBox()

        return try await withTaskCancellationHandler {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.environment = ProcessEnvironment.withToolPaths()
            process.arguments = [
                "python3",
                scriptURL.path,
                videoURL.path,
                "--json",
                "--language",
                snapshot.sourceLanguage,
                "--model",
                snapshot.whisperModel,
                "--backend",
                snapshot.whisperBackendRawValue,
            ]
            processBox.process = process

            let stdout = PipeCollector()
            let stderr = PipeCollector { line in
                if let event = TranscriptionProgressEvent.decode(line) {
                    Task { @MainActor in
                        progress(event.progress)
                    }
                }
            }

            process.standardOutput = stdout.pipe
            process.standardError = stderr.pipe

            try process.run()
            let terminationStatus = await process.waitForTermination()
            // The process has exited, but the readability handlers run on a
            // background queue and may still have buffered pipe data that has
            // not been appended yet. Wait for both pipes to reach EOF before
            // reading, otherwise a long transcript's JSON can be truncated.
            await stdout.waitForEOF()
            await stderr.waitForEOF()
            stdout.close()
            stderr.close()

            let stdoutData = stdout.data()
            let stderrText = stderr.text().trimmingCharacters(in: .whitespacesAndNewlines)

            if Task.isCancelled {
                throw CancellationError()
            }

            guard terminationStatus == 0 else {
                // stderr carries both JSON progress events and the real error
                // text; drop the progress lines so the message is legible.
                let errorText = stderrText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                    .filter { !$0.hasPrefix("{") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw TranscriptionServiceError.pythonFailed(
                    errorText.isEmpty ? "The Python helper exited with status \(terminationStatus)." : errorText
                )
            }

            let payload = try JSONDecoder().decode(TranscriptionPayload.self, from: stdoutData)
            return TranscriptionResult(backend: payload.backend, segments: payload.segments)
        } onCancel: {
            processBox.terminate()
        }
    }
}

private struct TranscriptionSettingsSnapshot: Sendable {
    let sourceLanguage: String
    let whisperModel: String
    let whisperBackendRawValue: String
}

private struct TranscriptionPayload: Decodable {
    let backend: String
    let segments: [TranscriptionSegment]
}

private struct TranscriptionProgressEvent: Decodable {
    let stage: JobStage
    let detail: String
    let fraction: Double?

    var progress: JobProgress {
        JobProgress(stage: stage, detail: detail, fraction: fraction)
    }

    static func decode(_ line: String) -> TranscriptionProgressEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptionProgressEvent.self, from: data)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcess: Process?

    var process: Process? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProcess
        }
        set {
            lock.lock()
            storedProcess = newValue
            lock.unlock()
        }
    }

    func terminate() {
        lock.lock()
        let process = storedProcess
        lock.unlock()
        process?.terminate()
    }
}

private final class PipeCollector: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var storage = Data()
    private var pendingLine = ""
    private let onLine: ((String) -> Void)?
    private var didReachEOF = false
    private var eofContinuation: CheckedContinuation<Void, Never>?

    init(onLine: ((String) -> Void)? = nil) {
        self.onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                // Empty read signals EOF: the process closed its write end.
                handle.readabilityHandler = nil
                self.signalEOF()
            } else {
                self.append(data)
            }
        }
    }

    /// Suspends until the pipe has been fully drained to EOF. Resolves
    /// immediately if EOF was already observed.
    func waitForEOF() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didReachEOF {
                lock.unlock()
                continuation.resume()
                return
            }
            eofContinuation = continuation
            lock.unlock()
        }
    }

    private func signalEOF() {
        lock.lock()
        didReachEOF = true
        let continuation = eofContinuation
        eofContinuation = nil
        lock.unlock()
        continuation?.resume()
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

    private func append(_ data: Data) {
        let newText = String(data: data, encoding: .utf8) ?? ""
        var completeLines: [String] = []

        lock.lock()
        storage.append(data)
        pendingLine += newText
        while let newlineIndex = pendingLine.firstIndex(of: "\n") {
            let line = String(pendingLine[..<newlineIndex])
            completeLines.append(line)
            pendingLine.removeSubrange(...newlineIndex)
        }
        lock.unlock()

        completeLines.forEach { onLine?($0) }
    }
}

private extension Process {
    func waitForTermination() async -> Int32 {
        await withCheckedContinuation { continuation in
            let resumer = ProcessTerminationResumer(continuation: continuation)
            terminationHandler = { process in
                resumer.resume(process.terminationStatus)
            }
            if !isRunning {
                resumer.resume(terminationStatus)
            }
        }
    }
}

private final class ProcessTerminationResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Int32, Never>

    init(continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    func resume(_ status: Int32) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: status)
    }
}
