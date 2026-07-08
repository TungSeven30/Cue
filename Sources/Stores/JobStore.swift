import Foundation

/// Persists each job as its own file under Application Support/WhisperDesk/jobs/.
/// Writes happen on a background queue from an immutable snapshot, so saving
/// a large job never blocks the main thread, and one corrupt file can only
/// lose one job instead of the whole history.
@MainActor
final class JobStore {
    private let folderURL: URL
    private let jobsFolderURL: URL
    private let legacyFileURL: URL
    private let fileManager: FileManager
    private let ioQueue = DispatchQueue(label: "WhisperDesk.JobStore", qos: .utility)

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        folderURL = baseURL.appendingPathComponent("WhisperDesk", isDirectory: true)
        jobsFolderURL = folderURL.appendingPathComponent("jobs", isDirectory: true)
        legacyFileURL = folderURL.appendingPathComponent("jobs.json")
        try? fileManager.createDirectory(at: jobsFolderURL, withIntermediateDirectories: true)
    }

    func loadJobs() -> [TranscriptionJob] {
        var jobs = migrateLegacyStoreIfNeeded()

        if jobs.isEmpty {
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
                    NSLog("WhisperDesk: job file %@ could not be decoded (%@); preserved at %@", file.lastPathComponent, "\(error)", backupURL.path)
                }
            }
        }

        return jobs.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Saves one job. Encoding and writing happen off the main thread; calls
    /// for the same job are serialized by the queue, last write wins.
    func saveJob(_ job: TranscriptionJob) {
        let url = fileURL(for: job.id)
        ioQueue.async {
            guard let data = try? Self.makeEncoder().encode(job) else { return }
            try? data.write(to: url, options: .atomic)
        }
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

    /// One-time migration from the old single jobs.json. The legacy file is
    /// renamed (never deleted) after a successful split, so the original data
    /// survives even if something goes wrong later.
    private func migrateLegacyStoreIfNeeded() -> [TranscriptionJob] {
        guard let data = try? Data(contentsOf: legacyFileURL) else {
            return []
        }
        do {
            let jobs = try Self.makeDecoder().decode([TranscriptionJob].self, from: data)
            let encoder = Self.makeEncoder()
            for job in jobs {
                if let encoded = try? encoder.encode(job) {
                    try? encoded.write(to: fileURL(for: job.id), options: .atomic)
                }
            }
            let backupURL = folderURL.appendingPathComponent("jobs.migrated.json")
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.moveItem(at: legacyFileURL, to: backupURL)
            NSLog("WhisperDesk: migrated %d job(s) to per-job storage.", jobs.count)
            return jobs
        } catch {
            let backupURL = folderURL.appendingPathComponent("jobs.corrupt.json")
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: legacyFileURL, to: backupURL)
            NSLog("WhisperDesk: legacy job history could not be decoded (%@); preserved at %@", "\(error)", backupURL.path)
            return []
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
