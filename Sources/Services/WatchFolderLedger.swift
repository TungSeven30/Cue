import Foundation

/// Remembers which watch-folder files have already reached a terminal
/// outcome, so scans never re-ingest them (spec §2.4). Keyed by the same
/// path|size|mtime fingerprint jobs use, so replacing a file re-runs it.
@MainActor
final class WatchFolderLedger {
    enum Outcome: String, Codable {
        case success
        case failure
    }

    private var entries: [String: Outcome]
    private let fileURL: URL

    init(baseURL: URL? = nil) {
        let resolvedBase = baseURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = resolvedBase.appendingPathComponent("Cue", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("watch-ledger.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Outcome].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    var fingerprints: Set<String> {
        Set(entries.keys)
    }

    func contains(_ fingerprint: String) -> Bool {
        entries[fingerprint] != nil
    }

    func record(_ fingerprint: String, outcome: Outcome) {
        entries[fingerprint] = outcome
        persist()
    }

    func prune(fileExists: (String) -> Bool) {
        let before = entries.count
        entries = entries.filter { fileExists(Self.path(fromFingerprint: $0.key)) }
        if entries.count != before {
            persist()
        }
    }

    func clear() {
        entries = [:]
        persist()
    }

    /// Forgets only the entries under one folder, so clearing a single watch
    /// folder's history cannot make another folder's completed files re-run.
    func clear(underPath folderPath: String) {
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let before = entries.count
        entries = entries.filter { !Self.path(fromFingerprint: $0.key).hasPrefix(prefix) }
        if entries.count != before {
            persist()
        }
    }

    /// The fingerprint is "path|size|mtime"; the path itself may contain
    /// pipes, so strip exactly the two trailing components.
    static func path(fromFingerprint fingerprint: String) -> String {
        fingerprint.components(separatedBy: "|").dropLast(2).joined(separator: "|")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
