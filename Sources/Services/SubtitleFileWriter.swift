import Foundation

/// Serializes source-file I/O without holding the main actor. A later edit
/// uses the mtime of our preceding write, even before its UI callback arrives.
final class SubtitleFileWriter: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let jobID: UUID
        let slot: SubtitleSidecarScanner.Slot
    }

    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false
        func cancel() { lock.withLock { canceled = true } }
        var isCanceled: Bool { lock.withLock { canceled } }
    }

    struct Request: Sendable {
        let id = UUID()
        let key: Key
        let source: ImportedSubtitleSource
        let segments: [TranscriptionSegment]
        let cancellation = Cancellation()
    }

    struct Completion: Sendable {
        let request: Request
        let source: ImportedSubtitleSource
        let logLine: String?
    }

    private let queue = DispatchQueue(label: "Cue.SubtitleFileWriter", qos: .userInitiated)
    private let beforeWrite: @Sendable () -> Void
    // Accessed only on queue.
    private var latest: [Key: ImportedSubtitleSource] = [:]
    private var completed: [Key: Completion] = [:]

    init(beforeWrite: @escaping @Sendable () -> Void = {}) {
        self.beforeWrite = beforeWrite
    }

    func write(_ request: Request, completion: @escaping @Sendable (Completion) -> Void) {
        queue.async { [self] in
            beforeWrite()
            guard !request.cancellation.isCanceled else { return }
            var source = request.source
            if let previous = latest[request.key], previous.path == source.path, previous.importedAt == source.importedAt {
                source = previous
            }
            var logLine: String?
            if !source.syncPaused {
                if !source.matchesFileOnDisk() {
                    source.syncPaused = true
                    logLine = "\(source.fileName) changed outside Cue; sync paused."
                } else {
                    do {
                        guard !request.cancellation.isCanceled else { return }
                        if !source.didBackup {
                            let backup = source.url.appendingPathExtension("bak")
                            if !FileManager.default.fileExists(atPath: backup.path) {
                                try FileManager.default.copyItem(at: source.url, to: backup)
                            }
                            source.didBackup = true
                        }
                        guard !request.cancellation.isCanceled else { return }
                        try SubtitleWriter.write(segments: request.segments, format: source.format, to: source.url)
                        source.refreshFileState()
                        source.lastSyncError = nil
                    } catch {
                        source.lastSyncError = error.localizedDescription
                        logLine = "Could not update \(source.fileName): \(error.localizedDescription)"
                    }
                }
            }
            latest[request.key] = source
            let result = Completion(request: request, source: source, logLine: logLine)
            completed[request.key] = result
            completion(result)
        }
    }

    /// Explicit durability barrier for quit/tests, never used by selection or
    /// the normal edit debounce. No main-actor callback is needed to finish.
    func flush() -> [Completion] {
        queue.sync {
            defer { completed.removeAll() }
            return Array(completed.values)
        }
    }
}
