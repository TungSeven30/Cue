import Foundation

/// What a load produced. `warnings` are user-facing messages the caller
/// surfaces on the main actor; a corrupt file never throws, it is backed up
/// and reported.
struct JobFolderLoadResult: Sendable {
    var folders: [JobFolder]
    var warnings: [String]

    static let empty = JobFolderLoadResult(folders: [], warnings: [])
}

/// Persists the folder list as one small JSON file, `Cue/folders.json`, next
/// to the `jobs/` directory. Job *membership* is not stored here: it lives
/// in each job's `folderID` and saves through the ordinary job path, so a
/// lost or damaged folder file can never lose a job. Writes are atomic and
/// happen on a serial background queue from an immutable snapshot.
final class JobFolderStore: Sendable {
    nonisolated static let persistenceDidFail = Notification.Name("Cue.JobFolderStore.persistenceDidFail")
    static let fileName = "folders.json"
    static let corruptFileName = "folders.corrupt.json"
    private static let currentVersion = 1

    /// nil for the in-memory store used when a test injects its own job
    /// repository: those tests must never touch the real Application Support.
    let fileURL: URL?
    private let queue = DispatchQueue(label: "Cue.JobFolderStore", qos: .utility)

    /// Same base-directory convention as `JobStore(baseURL:)`: the file is
    /// `<base>/Cue/folders.json`, `<base>` defaulting to Application Support.
    init(baseURL: URL? = nil) {
        let base =
            baseURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("Cue", isDirectory: true).appendingPathComponent(Self.fileName)
    }

    /// For an owner that already resolved the `Cue` directory itself (the
    /// job store exposes it as `directoryURL`).
    init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent(Self.fileName)
    }

    private init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Loads nothing and saves nothing.
    static var inMemory: JobFolderStore {
        JobFolderStore(fileURL: nil)
    }

    private struct Document: Codable {
        var version: Int
        var folders: [JobFolder]
    }

    /// Decodes each folder on its own so one malformed entry cannot take the
    /// rest with it.
    private struct LossyDocument: Decodable {
        var folders: [JobFolder] = []
        var skipped = 0

        private struct Skip: Decodable {
            init(from decoder: Decoder) throws {}
        }

        private enum CodingKeys: String, CodingKey { case folders }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var list = try container.nestedUnkeyedContainer(forKey: .folders)
            while !list.isAtEnd {
                if let folder = try? list.decode(JobFolder.self) {
                    folders.append(folder)
                } else {
                    skipped += 1
                    _ = try? list.decode(Skip.self)
                }
            }
        }
    }

    /// Safe to call off the main actor.
    nonisolated func load() -> JobFolderLoadResult {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try Self.makeDecoder().decode(LossyDocument.self, from: data)
            guard document.skipped > 0 else {
                return JobFolderLoadResult(folders: document.folders, warnings: [])
            }
            let backup = backUpCorruptFile(at: fileURL)
            return JobFolderLoadResult(
                folders: document.folders,
                warnings: [
                    "Some folders in the folder list could not be read (\(document.skipped)). "
                        + "Their jobs were placed automatically. \(backup)"
                ]
            )
        } catch {
            let backup = backUpCorruptFile(at: fileURL)
            return JobFolderLoadResult(
                folders: [],
                warnings: [
                    "The folder list could not be read (\(error.localizedDescription)). "
                        + "Your jobs are safe and were placed in folders automatically. \(backup)"
                ]
            )
        }
    }

    /// Copies the unreadable file aside (replacing an older backup) before
    /// the next save overwrites it, like `JobStore` does for a job file.
    private nonisolated func backUpCorruptFile(at url: URL) -> String {
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(Self.corruptFileName)
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
            return "The original was kept as \(Self.corruptFileName)."
        } catch {
            return "The original could not be backed up: \(error.localizedDescription)"
        }
    }

    /// Queues an atomic write of `folders`; the last call wins.
    func save(_ folders: [JobFolder]) {
        guard let fileURL else { return }
        queue.async {
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try Self.makeEncoder().encode(Document(version: Self.currentVersion, folders: folders))
                try data.write(to: fileURL, options: .atomic)
            } catch {
                let message =
                    "Could not save the folder list: \(error.localizedDescription). Folder names and layout may be lost on relaunch."
                NSLog("Cue: %@", message)
                NotificationCenter.default.post(name: Self.persistenceDidFail, object: message)
            }
        }
    }

    /// Blocks until every queued write has reached the disk.
    func flush() {
        queue.sync {}
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
