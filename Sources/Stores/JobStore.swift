import Foundation

/// Persists each job as its own file under Application Support/Cue/jobs/.
/// Writes happen on a background queue from an immutable snapshot, so saving
/// a large job never blocks the main thread, and one corrupt file can only
/// lose one job instead of the whole history.
@MainActor
final class JobStore {
    private let folderURL: URL
    private let jobsFolderURL: URL
    private let legacyFileURL: URL
    private let fileManager: FileManager
    private let ioQueue = DispatchQueue(label: "Cue.JobStore", qos: .utility)

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        let resolvedBase = baseURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        folderURL = resolvedBase.appendingPathComponent("Cue", isDirectory: true)
        jobsFolderURL = folderURL.appendingPathComponent("jobs", isDirectory: true)
        legacyFileURL = folderURL.appendingPathComponent("jobs.json")
        do {
            try fileManager.createDirectory(at: jobsFolderURL, withIntermediateDirectories: true)
        } catch {
            NSLog("Cue: could not create the jobs folder at %@ (%@); job history will not persist.", jobsFolderURL.path, "\(error)")
        }
    }

    func loadJobs() -> [TranscriptionJob] {
        migrateLegacyStoreIfNeeded()

        var jobs: [TranscriptionJob] = []
        let files = (try? fileManager.contentsOfDirectory(at: jobsFolderURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.contains("corrupt") {
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                jobs.append(try Self.makeDecoder().decode(TranscriptionJob.self, from: data))
            } catch {
                // Preserve the unreadable job instead of overwriting it on
                // the next save, so the data can still be recovered by hand.
                let backupURL = file.deletingPathExtension().appendingPathExtension("corrupt.json")
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: file, to: backupURL)
                NSLog("Cue: job file %@ could not be decoded (%@); preserved at %@", file.lastPathComponent, "\(error)", backupURL.path)
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

    /// Saves one job. Encoding and writing happen off the main thread; calls
    /// for the same job are serialized by the queue, last write wins.
    func saveJob(_ job: TranscriptionJob) {
        let url = fileURL(for: job.id)
        ioQueue.async {
            do {
                let data = try Self.makeEncoder().encode(job)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Cue: failed to save job %@ (%@); its latest state will be lost on quit.", job.id.uuidString, "\(error)")
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
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        jobsFolderURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// One-time migration from the old single jobs.json: split it into
    /// per-job files, then rename it (never delete) so the original data
    /// survives even if something goes wrong later. A job that already has a
    /// per-job file is skipped — that file is newer than the legacy snapshot
    /// and must not be clobbered.
    private func migrateLegacyStoreIfNeeded() {
        guard let data = try? Data(contentsOf: legacyFileURL) else {
            return
        }
        do {
            let jobs = try Self.makeDecoder().decode([TranscriptionJob].self, from: data)
            let encoder = Self.makeEncoder()
            for job in jobs {
                let url = fileURL(for: job.id)
                guard !fileManager.fileExists(atPath: url.path) else { continue }
                if let encoded = try? encoder.encode(job) {
                    try? encoded.write(to: url, options: .atomic)
                }
            }
            let backupURL = folderURL.appendingPathComponent("jobs.migrated.json")
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.moveItem(at: legacyFileURL, to: backupURL)
            NSLog("Cue: migrated %d job(s) to per-job storage.", jobs.count)
        } catch {
            let backupURL = folderURL.appendingPathComponent("jobs.corrupt.json")
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: legacyFileURL, to: backupURL)
            NSLog("Cue: legacy job history could not be decoded (%@); preserved at %@", "\(error)", backupURL.path)
        }
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
