import Foundation

@MainActor
final class JobStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folderURL = baseURL.appendingPathComponent("WhisperDesk", isDirectory: true)
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        fileURL = folderURL.appendingPathComponent("jobs.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadJobs() -> [TranscriptionJob] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        do {
            return try decoder.decode([TranscriptionJob].self, from: data)
        } catch {
            // Keep the unreadable history around instead of letting the next
            // save overwrite it, so the data can still be recovered by hand.
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
            NSLog("WhisperDesk: job history could not be decoded (%@); preserved at %@", "\(error)", backupURL.path)
            return []
        }
    }

    func saveJobs(_ jobs: [TranscriptionJob]) {
        guard let data = try? encoder.encode(jobs) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
