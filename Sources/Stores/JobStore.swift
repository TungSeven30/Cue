import Foundation

/// Persists each job as its own file under Application Support/Cue/jobs/.
/// Writes happen on a background queue from an immutable snapshot, so saving
/// a large job never blocks the main thread, and one corrupt file can only
/// lose one job instead of the whole history.
@MainActor
final class JobStore {
    nonisolated static let persistenceDidFail = Notification.Name("Cue.JobStore.persistenceDidFail")

    enum Operation: Sendable {
        case createDirectory
        case listDirectory
        case read
        case write
        case remove
        case copy
        case move
    }

    typealias FailureInjector = @Sendable (Operation, URL) throws -> Void

    /// FileManager is documented as safe to use from multiple threads, but
    /// its Objective-C declaration predates Swift's Sendable annotations.
    private final class SendableFileManager: @unchecked Sendable {
        let value: FileManager

        init(_ value: FileManager) {
            self.value = value
        }
    }

    private let folderURL: URL
    private let jobsFolderURL: URL
    private let legacyFileURL: URL
    private let fileManager: FileManager
    private let failureInjector: FailureInjector
    private let ioQueue = DispatchQueue(label: "Cue.JobStore", qos: .utility)
    private(set) var startupError: String?

    init(
        fileManager: FileManager = .default,
        baseURL: URL? = nil,
        failureInjector: @escaping FailureInjector = { _, _ in }
    ) {
        self.fileManager = fileManager
        self.failureInjector = failureInjector
        let resolvedBase =
            baseURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        folderURL = resolvedBase.appendingPathComponent("Cue", isDirectory: true)
        jobsFolderURL = folderURL.appendingPathComponent("jobs", isDirectory: true)
        legacyFileURL = folderURL.appendingPathComponent("jobs.json")
        do {
            try failureInjector(.createDirectory, jobsFolderURL)
            try fileManager.createDirectory(at: jobsFolderURL, withIntermediateDirectories: true)
        } catch {
            let message = "Could not create the job-history folder at \(jobsFolderURL.path): \(error.localizedDescription)"
            startupError = message
            Self.reportFailure(message)
        }
    }

    func loadJobs() -> [TranscriptionJob] {
        var jobs = migrateLegacyStoreIfNeeded()

        let files: [URL]
        do {
            try failureInjector(.listDirectory, jobsFolderURL)
            files = try fileManager.contentsOfDirectory(at: jobsFolderURL, includingPropertiesForKeys: nil)
        } catch {
            recordStartupFailure(
                "Could not read job history at \(jobsFolderURL.path): \(error.localizedDescription). Existing jobs may be hidden."
            )
            return jobs.map(Self.sanitizedAfterRelaunch).sorted { $0.updatedAt > $1.updatedAt }
        }
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.contains("corrupt") {
            do {
                try failureInjector(.read, file)
                let data = try Data(contentsOf: file)
                let decoded = try Self.makeDecoder().decode(TranscriptionJob.self, from: data)
                jobs.removeAll { $0.id == decoded.id }
                jobs.append(decoded)
            } catch {
                // Preserve the unreadable job instead of overwriting it on
                // the next save, so the data can still be recovered by hand.
                let backupURL = file.deletingPathExtension().appendingPathExtension("corrupt.json")
                do {
                    try injectedRemove(at: backupURL)
                    try injectedCopy(from: file, to: backupURL)
                    recordStartupFailure(
                        "Could not read job file \(file.lastPathComponent): \(error.localizedDescription). It was preserved at \(backupURL.path)."
                    )
                } catch let backupError {
                    recordStartupFailure(
                        "Could not read job file \(file.lastPathComponent): \(error.localizedDescription). The original remains at \(file.path), but a recovery copy could not be created: \(backupError.localizedDescription)."
                    )
                }
            }
        }

        return jobs.map(Self.sanitizedAfterRelaunch).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A job persisted mid-run stays "Transcribing"/"Translating" forever
    /// after a crash or force-quit — unstartable, uncancelable, and only
    /// recoverable by deleting it. Mark it canceled instead so it can be
    /// re-run, keeping any segments it already produced.
    static func sanitizedAfterRelaunch(_ job: TranscriptionJob) -> TranscriptionJob {
        guard job.status.isRunning else { return job }
        var job = job
        job.status = .canceled
        job.progress = JobProgress(stage: .canceled, detail: "Interrupted — the app quit while this job was running.", fraction: nil)
        job.log += "This job was interrupted by an app quit and marked as canceled.\n"
        return job
    }

    /// Saves one job. Writes happen off the main thread; calls for the same job
    /// are serialized by the queue, last write wins. Encoding stays on the main
    /// actor so the IO queue only receives Sendable snapshots.
    func saveJob(_ job: TranscriptionJob) {
        let url = fileURL(for: job.id)
        let encoded: Data
        do {
            encoded = try Self.makeEncoder().encode(job)
        } catch {
            Self.reportFailure(
                "Could not encode job \(job.id.uuidString): \(error.localizedDescription). Its latest state is still in memory."
            )
            return
        }
        Self.enqueuePersist(
            encoded: encoded,
            jobID: job.id,
            to: url,
            on: ioQueue,
            failureInjector: failureInjector
        )
    }

    /// Blocks until every write enqueued so far has hit the disk. Called on
    /// app termination so debounced edits and final job states are not lost.
    func flush() {
        Self.waitForIOQueue(ioQueue)
    }

    func deleteJob(_ id: UUID) {
        Self.enqueueDelete(
            at: fileURL(for: id),
            id: id,
            on: ioQueue,
            fileManager: SendableFileManager(fileManager),
            failureInjector: failureInjector
        )
    }

    private nonisolated static func enqueuePersist(
        encoded: Data,
        jobID: UUID,
        to url: URL,
        on queue: DispatchQueue,
        failureInjector: FailureInjector
    ) {
        queue.async {
            persistJob(encoded: encoded, jobID: jobID, to: url, failureInjector: failureInjector)
        }
    }

    private nonisolated static func persistJob(
        encoded: Data,
        jobID: UUID,
        to url: URL,
        failureInjector: FailureInjector
    ) {
        do {
            try failureInjector(.write, url)
            try encoded.write(to: url, options: .atomic)
        } catch {
            reportFailure(
                "Could not save job \(jobID.uuidString): \(error.localizedDescription). Its latest state is still in memory."
            )
        }
    }

    private nonisolated static func enqueueDelete(
        at url: URL,
        id: UUID,
        on queue: DispatchQueue,
        fileManager: SendableFileManager,
        failureInjector: FailureInjector
    ) {
        queue.async {
            deleteJobFile(at: url, id: id, fileManager: fileManager, failureInjector: failureInjector)
        }
    }

    private nonisolated static func deleteJobFile(
        at url: URL,
        id: UUID,
        fileManager: SendableFileManager,
        failureInjector: FailureInjector
    ) {
        do {
            if fileManager.value.fileExists(atPath: url.path) {
                try failureInjector(.remove, url)
                try fileManager.value.removeItem(at: url)
            }
        } catch {
            reportFailure("Could not delete job history \(id.uuidString): \(error.localizedDescription)")
        }
    }

    private nonisolated static func waitForIOQueue(_ queue: DispatchQueue) {
        queue.sync {}
    }

    private func fileURL(for id: UUID) -> URL {
        jobsFolderURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// One-time migration from the old single jobs.json: split it into
    /// per-job files, then rename it (never delete) so the original data
    /// survives even if something goes wrong later. A job that already has a
    /// per-job file is skipped — that file is newer than the legacy snapshot
    /// and must not be clobbered.
    private func migrateLegacyStoreIfNeeded() -> [TranscriptionJob] {
        guard let data = try? injectedRead(from: legacyFileURL) else {
            return []
        }
        var decodedJobs: [TranscriptionJob] = []
        do {
            let jobs = try Self.makeDecoder().decode([TranscriptionJob].self, from: data)
            decodedJobs = jobs
            let encoder = Self.makeEncoder()
            for job in jobs {
                let url = fileURL(for: job.id)
                guard !fileManager.fileExists(atPath: url.path) else { continue }
                let encoded = try encoder.encode(job)
                try failureInjector(.write, url)
                try encoded.write(to: url, options: .atomic)
            }
            let backupURL = folderURL.appendingPathComponent("jobs.migrated.json")
            if fileManager.fileExists(atPath: backupURL.path) {
                try injectedRemove(at: backupURL)
            }
            try injectedMove(from: legacyFileURL, to: backupURL)
            NSLog("Cue: migrated %d job(s) to per-job storage.", jobs.count)
            return []
        } catch {
            let backupURL = folderURL.appendingPathComponent("jobs.corrupt.json")
            try? injectedRemove(at: backupURL)
            try? injectedCopy(from: legacyFileURL, to: backupURL)
            recordStartupFailure(
                "Could not finish migrating legacy job history: \(error.localizedDescription). The original remains at \(legacyFileURL.path)."
            )
            // If decoding succeeded but a later write/move failed, keep those
            // jobs visible for this launch while retaining the source file for
            // a safe retry next time.
            return decodedJobs
        }
    }

    private func injectedRead(from url: URL) throws -> Data {
        try failureInjector(.read, url)
        return try Data(contentsOf: url)
    }

    private func injectedRemove(at url: URL) throws {
        try failureInjector(.remove, url)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func injectedCopy(from source: URL, to destination: URL) throws {
        try failureInjector(.copy, destination)
        try fileManager.copyItem(at: source, to: destination)
    }

    private func injectedMove(from source: URL, to destination: URL) throws {
        try failureInjector(.move, destination)
        try fileManager.moveItem(at: source, to: destination)
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // JSON has no NaN/infinity; the default strategy throws, which would
        // leave a job permanently unsaveable over one bad timestamp.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    private nonisolated static func reportFailure(_ message: String) {
        NSLog("Cue: %@", message)
        NotificationCenter.default.post(name: persistenceDidFail, object: message)
    }

    private func recordStartupFailure(_ message: String) {
        startupError = message
        Self.reportFailure(message)
    }
}

extension JobStore: JobPersisting {}
