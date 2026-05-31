import Foundation

enum ProcessEnvironment {
    /// Environment for spawned helpers (python3, ffmpeg) with common Homebrew
    /// and local bin directories added to PATH.
    ///
    /// Apps launched from Finder inherit only the minimal launchd PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), so `/usr/bin/env python3` and the
    /// Python helper's `subprocess.run(["ffmpeg", ...])` would otherwise miss
    /// Homebrew installs. Prepending these directories makes the GUI behave
    /// like a terminal session.
    static func withToolPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let toolDirectories = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let existing = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let ordered = toolDirectories + existing.split(separator: ":").map(String.init)

        var seen = Set<String>()
        environment["PATH"] = ordered
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }
}
