import Foundation
import os

/// Remembers which watch-folder files have already reached a terminal
/// outcome, so scans never re-ingest them (spec §2.4). Keyed by the same
/// path|size|mtime fingerprint jobs use, so replacing a file re-runs it.
@MainActor
final class WatchFolderLedger {
    nonisolated static let persistenceDidFail = Notification.Name("Cue.WatchFolderLedger.persistenceDidFail")

    enum Outcome: String, Codable {
        case success
        case failure
    }

    private var entries: [String: Outcome]
    private let fileURL: URL
    private(set) var startupError: String? = nil
    /// Writes leave the main actor: the newest snapshot waits here and one
    /// queued block writes whatever is newest when it runs, so a burst of
    /// records produces one file write, and `flush()` waits for it.
    private let ioQueue = DispatchQueue(label: "Cue.WatchFolderLedger", qos: .utility)
    private let pendingSnapshot = OSAllocatedUnfairLock<[String: Outcome]?>(initialState: nil)

    init(baseURL: URL? = nil) {
        let resolvedBase =
            baseURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = resolvedBase.appendingPathComponent("Cue", isDirectory: true)
        fileURL = folder.appendingPathComponent("watch-ledger.json")
        entries = [:]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([String: Outcome].self, from: data)
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            let message =
                "Could not read watch-folder history: \(error.localizedDescription). The original was preserved at \(backup.path); files may be queued again."
            startupError = message
            Self.reportFailure(message)
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

    /// Blocks until every recorded change has reached the disk. Called on
    /// app termination and by tests before they reload.
    func flush() {
        ioQueue.sync {}
    }

    private func persist() {
        let snapshot = entries
        let url = fileURL
        let pending = pendingSnapshot
        let alreadyQueued = pending.withLock { current -> Bool in
            defer { current = snapshot }
            return current != nil
        }
        guard !alreadyQueued else { return }
        ioQueue.async {
            guard
                let latest = pending.withLock({ current -> [String: Outcome]? in
                    defer { current = nil }
                    return current
                })
            else { return }
            do {
                let data = try JSONEncoder().encode(latest)
                try data.write(to: url, options: .atomic)
            } catch {
                Self.reportFailure(
                    "Could not save watch-folder history: \(error.localizedDescription). Files may be queued again after relaunch."
                )
            }
        }
    }

    private nonisolated static func reportFailure(_ message: String) {
        NSLog("Cue: %@", message)
        NotificationCenter.default.post(name: persistenceDidFail, object: message)
    }
}
