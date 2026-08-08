import Foundation

/// One-time relocation of data written when the app was WhisperDesk
/// (bundle id com.local.WhisperDesk). Must run before any store touches
/// disk or defaults, so CueApp.init calls it ahead of AppModel's creation.
enum LegacyMigration {
    static func run() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Jobs, downloaded models, and the watch-folder ledger.
        move(
            from: home.appendingPathComponent("Library/Application Support/WhisperDesk", isDirectory: true),
            to: home.appendingPathComponent("Library/Application Support/Cue", isDirectory: true),
            with: fm
        )
        // Extracted-audio cache; losing it only costs re-extraction.
        move(
            from: home.appendingPathComponent("Library/Caches/WhisperDesk", isDirectory: true),
            to: home.appendingPathComponent("Library/Caches/Cue", isDirectory: true),
            with: fm
        )
        // Settings and window state live in the bundle-id defaults domain.
        let defaults = UserDefaults.standard
        let newDomain = Bundle.main.bundleIdentifier ?? "com.local.Cue"
        if defaults.persistentDomain(forName: newDomain)?.isEmpty ?? true,
            let legacy = defaults.persistentDomain(forName: "com.local.WhisperDesk"),
            !legacy.isEmpty
        {
            defaults.setPersistentDomain(legacy, forName: newDomain)
        }
    }

    private static func move(from old: URL, to new: URL, with fm: FileManager) {
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            NSLog("Cue: could not migrate %@ to %@ (%@); starting with a fresh folder.", old.path, new.path, "\(error)")
        }
    }
}
