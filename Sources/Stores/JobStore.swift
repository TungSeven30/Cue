import Foundation

/// What a load produced: the jobs, plus the failure messages the caller
/// must surface on the main actor. Built off the main actor so a large
/// history never blocks first-window presentation.
struct JobLoadSnapshot: Sendable {
    let jobs: [TranscriptionJob]
    let failures: [String]
}

/// Persists each job as its own file under Application Support/Cue/jobs/.
/// Writes happen on a background queue from an immutable snapshot, so saving
/// a large job never blocks the main thread, and one corrupt file can only
/// lose one job instead of the whole history. Loading decodes files
/// concurrently and returns them in a total, deterministic order.
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
    private let fileManagerBox: SendableFileManager
    private let failureInjector: FailureInjector
    private let ioQueue = DispatchQueue(label: "Cue.JobStore", qos: .utility)
    /// Routes `persistenceDidFail` to the one AppModel that owns this store.
    let notificationToken = UUID()
    private(set) var startupError: String?

    private nonisolated var fileManager: FileManager { fileManagerBox.value }

    init(
        fileManager: FileManager = .default,
        baseURL: URL? = nil,
        failureInjector: @escaping FailureInjector = { _, _ in }
    ) {
        self.fileManagerBox = SendableFileManager(fileManager)
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
            postPersistenceFailure(message)
        }
    }

    /// Synchronous load on the main actor. Prefer `loadJobsSnapshot()` from a
    /// background task plus `recordStartupFailures(_:)` when the caller can
    /// afford to show its window first.
    func loadJobs() -> [TranscriptionJob] {
        let snapshot = loadJobsSnapshot()
        recordStartupFailures(snapshot.failures)
        return snapshot.jobs
    }

    /// The whole load, safe to run off the main actor: legacy migration,
    /// concurrent decode of every per-job file, quarantine of unreadable
    /// files, relaunch sanitising, and a deterministic final order.
    nonisolated func loadJobsSnapshot() -> JobLoadSnapshot {
        var failures: [String] = []
        var jobs = migrateLegacyStoreIfNeeded(failures: &failures)

        let files: [URL]
        do {
            try failureInjector(.listDirectory, jobsFolderURL)
            files = try fileManager.contentsOfDirectory(at: jobsFolderURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("corrupt") }
        } catch {
            failures.append(
                "Could not read job history at \(jobsFolderURL.path): \(error.localizedDescription). Existing jobs may be hidden."
            )
            return JobLoadSnapshot(
                jobs: jobs.map(Self.sanitizedAfterRelaunch).sorted(by: JobLoadOrdering.storeOrder),
                failures: failures
            )
        }

        // Decode in parallel into a slot per directory entry, then apply the
        // results in listing order: the outcome cannot depend on which
        // thread finished first, and quarantine messages keep their order.
        let decoded = Self.decodeConcurrently(files, failureInjector: failureInjector)
        for (file, result) in zip(files, decoded) {
            switch result {
            case .success(let job):
                jobs.removeAll { $0.id == job.id }
                jobs.append(job)
            case .failure(let error):
                // Preserve the unreadable job instead of overwriting it on
                // the next save, so the data can still be recovered by hand.
                let backupURL = file.deletingPathExtension().appendingPathExtension("corrupt.json")
                do {
                    try injectedRemove(at: backupURL)
                    try injectedCopy(from: file, to: backupURL)
                    failures.append(
                        "Could not read job file \(file.lastPathComponent): \(error.localizedDescription). It was preserved at \(backupURL.path)."
                    )
                } catch let backupError {
                    failures.append(
                        "Could not read job file \(file.lastPathComponent): \(error.localizedDescription). The original remains at \(file.path), but a recovery copy could not be created: \(backupError.localizedDescription)."
                    )
                }
            }
        }

        return JobLoadSnapshot(
            jobs: jobs.map(Self.sanitizedAfterRelaunch).sorted(by: JobLoadOrdering.storeOrder),
            failures: failures
        )
    }

    /// Surfaces the failures a background load collected, exactly as the
    /// synchronous load would have as it went.
    func recordStartupFailures(_ failures: [String]) {
        for failure in failures {
            recordStartupFailure(failure)
        }
    }

    private nonisolated static func decodeConcurrently(
        _ files: [URL],
        failureInjector: @escaping FailureInjector
    ) -> [Result<TranscriptionJob, Error>] {
        guard !files.isEmpty else { return [] }
        final class Slots: @unchecked Sendable {
            var results: [Result<TranscriptionJob, Error>?]
            init(count: Int) { results = Array(repeating: nil, count: count) }
        }
        let slots = Slots(count: files.count)
        // Each iteration writes its own slot, so no synchronisation is needed
        // beyond concurrentPerform's completion barrier.
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let file = files[index]
            let result = Result<TranscriptionJob, Error> {
                try failureInjector(.read, file)
                let data = try Data(contentsOf: file)
                return try makeDecoder().decode(TranscriptionJob.self, from: data)
            }
            slots.results[index] = result
        }
        return slots.results.map { $0! }
    }

    /// A job persisted mid-run stays "Transcribing"/"Translating" forever
    /// after a crash or force-quit — unstartable, uncancelable, and only
    /// recoverable by deleting it. Mark it canceled instead so it can be
    /// re-run, keeping any segments it already produced.
    nonisolated static func sanitizedAfterRelaunch(_ job: TranscriptionJob) -> TranscriptionJob {
        guard job.status.isRunning else { return job }
        var job = job
        job.status = .canceled
        job.progress = JobProgress(stage: .canceled, detail: "Interrupted — the app quit while this job was running.", fraction: nil)
        job.log += "This job was interrupted by an app quit and marked as canceled.\n"
        return job
    }

    /// Saves one job. Encoding and writing happen off the main thread; calls
    /// for the same job are serialized by the queue, last write wins.
    func saveJob(_ job: TranscriptionJob) {
        let url = fileURL(for: job.id)
        let token = notificationToken
        let failureInjector = self.failureInjector
        ioQueue.async {
            do {
                let data = try Self.makeEncoder().encode(job)
                try failureInjector(.write, url)
                try data.write(to: url, options: .atomic)
            } catch {
                Self.postFailure(
                    "Could not save job \(job.id.uuidString): \(error.localizedDescription). Its latest state is still in memory.",
                    token: token
                )
            }
        }
    }

    /// Blocks until every write enqueued so far has hit the disk. Called on
    /// app termination so debounced edits and final job states are not lost.
    func flush() {
        ioQueue.sync {}
    }

    func deleteJob(_ id: UUID) {
        let url = fileURL(for: id)
        let token = notificationToken
        let fileManager = fileManagerBox
        let failureInjector = self.failureInjector
        ioQueue.async {
            do {
                if fileManager.value.fileExists(atPath: url.path) {
                    try failureInjector(.remove, url)
                    try fileManager.value.removeItem(at: url)
                }
            } catch {
                Self.postFailure(
                    "Could not delete job history \(id.uuidString): \(error.localizedDescription)",
                    token: token
                )
            }
        }
    }

    private nonisolated func fileURL(for id: UUID) -> URL {
        jobsFolderURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// One-time migration from the old single jobs.json: split it into
    /// per-job files, then rename it (never delete) so the original data
    /// survives even if something goes wrong later. A job that already has a
    /// per-job file is skipped — that file is newer than the legacy snapshot
    /// and must not be clobbered.
    private nonisolated func migrateLegacyStoreIfNeeded(failures: inout [String]) -> [TranscriptionJob] {
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
            failures.append(
                "Could not finish migrating legacy job history: \(error.localizedDescription). The original remains at \(legacyFileURL.path)."
            )
            // If decoding succeeded but a later write/move failed, keep those
            // jobs visible for this launch while retaining the source file for
            // a safe retry next time.
            return decodedJobs
        }
    }

    private nonisolated func injectedRead(from url: URL) throws -> Data {
        try failureInjector(.read, url)
        return try Data(contentsOf: url)
    }

    private nonisolated func injectedRemove(at url: URL) throws {
        try failureInjector(.remove, url)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private nonisolated func injectedCopy(from source: URL, to destination: URL) throws {
        try failureInjector(.copy, destination)
        try fileManager.copyItem(at: source, to: destination)
    }

    private nonisolated func injectedMove(from source: URL, to destination: URL) throws {
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

    private nonisolated static func postFailure(_ message: String, token: UUID) {
        NSLog("Cue: %@", message)
        NotificationCenter.default.post(
            name: persistenceDidFail,
            object: token,
            userInfo: ["message": message]
        )
    }

    private func postPersistenceFailure(_ message: String) {
        Self.postFailure(message, token: notificationToken)
    }

    private func recordStartupFailure(_ message: String) {
        startupError = message
        postPersistenceFailure(message)
    }
}

extension JobStore: JobPersisting {}
