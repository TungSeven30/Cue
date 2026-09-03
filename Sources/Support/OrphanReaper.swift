import Foundation

/// Terminates worker processes left behind by a previous app instance that
/// died mid-job (crash, force-quit, or being replaced by an install). The
/// Python backends, yt-dlp, and their ffmpeg children keep running with no
/// parent to stream results to — burning CPU and NAS bandwidth for nothing.
///
/// Workers are recognized by command line, not by a PID registry: every
/// worker's arguments contain one of our unique temp-dir markers, which also
/// catches grandchildren (ffmpeg spawned by the Python script) that no
/// registry of direct children could track. Only true orphans are killed —
/// processes whose parent is gone, so launchd (pid 1) adopted them. A worker
/// whose parent is alive belongs to another running Cue (the CLI beside the
/// GUI, or a second instance) and must be left alone.
enum OrphanReaper {
    /// Binaries our pipeline spawns; nothing else is ever killed. Python
    /// appears under version-suffixed names (python3.13) and as the
    /// framework's "Python" executable, so names match by prefix.
    private static let workerBinaryPrefixes = ["ffmpeg", "python", "yt-dlp"]
    /// Temp-path markers written by BackendScriptWriter, the Python script's
    /// TemporaryDirectory prefix, BurnInService, and MediaDownloadService's
    /// staging folder — including the pre-rename spellings so orphans from
    /// WhisperDesk-era builds are still caught.
    private static let markers = [
        "/T/cue_", "cue_backend.py", "/T/cue-", ".cue-download-", "/T/whisperdesk_", "/T/whisperdesk-",
    ]

    /// Called once at launch, before any job can start (so every match is a
    /// leftover from a dead instance, never our own worker).
    static func reap() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/ps", directoryHint: .notDirectory)
            process.arguments = ["-axo", "pid=,ppid=,command="]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return }
            for pid in orphanPIDs(inPSOutput: output) {
                NSLog("Cue: terminating orphaned worker process %d.", pid)
                kill(pid, SIGTERM)
            }
        }
    }

    /// Pure matcher, split out for tests: `ps -axo pid=,ppid=,command=` lines
    /// in, PIDs of orphaned workers out.
    static func orphanPIDs(inPSOutput output: String) -> [pid_t] {
        output.split(separator: "\n").compactMap { line in
            guard let entry = parse(line) else { return nil }
            // Reparented to launchd means the Cue that spawned it is gone.
            guard entry.parent == 1 else { return nil }
            let binary = entry.command.split(separator: " ", maxSplits: 1)[0]
            let binaryName = String(binary.split(separator: "/").last ?? binary).lowercased()
            guard workerBinaryPrefixes.contains(where: { binaryName.hasPrefix($0) }),
                markers.contains(where: { entry.command.contains($0) })
            else { return nil }
            return entry.pid
        }
    }

    private static func parse(_ line: Substring) -> (pid: pid_t, parent: pid_t, command: String)? {
        var rest = line.drop(while: { $0 == " " })
        func nextField() -> Substring? {
            rest = rest.drop(while: { $0 == " " })
            guard let end = rest.firstIndex(of: " ") else { return nil }
            let field = rest[..<end]
            rest = rest[end...]
            return field
        }
        guard let pidField = nextField(), let pid = pid_t(pidField),
            let parentField = nextField(), let parent = pid_t(parentField)
        else { return nil }
        let command = rest.drop(while: { $0 == " " })
        guard !command.isEmpty else { return nil }
        return (pid, parent, String(command))
    }
}
