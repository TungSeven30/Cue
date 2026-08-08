import Foundation

/// Terminates worker processes left behind by a previous app instance that
/// died mid-job (crash, force-quit, or being replaced by an install). The
/// Python backends and their ffmpeg children keep running with no parent to
/// stream results to — burning CPU and NAS bandwidth for nothing.
///
/// Workers are recognized by command line, not by a PID registry: every
/// worker's arguments contain one of our unique temp-dir markers, which also
/// catches grandchildren (ffmpeg spawned by the Python script) that no
/// registry of direct children could track.
enum OrphanReaper {
    /// Binaries our pipeline spawns; nothing else is ever killed.
    private static let workerBinaries: Set<String> = ["ffmpeg", "python", "python3", "Python"]
    /// Temp-path markers written by BackendScriptWriter, the Python script's
    /// TemporaryDirectory prefix, and BurnInService — including the pre-rename
    /// spellings so orphans from WhisperDesk-era builds are still caught.
    private static let markers = ["/T/cue_", "cue_backend.py", "/T/cue-", "/T/whisperdesk_", "/T/whisperdesk-"]

    /// Called once at launch, before any job can start (so every match is a
    /// leftover from a dead instance, never our own worker).
    static func reap() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/ps", directoryHint: .notDirectory)
            process.arguments = ["-axo", "pid=,command="]
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

    /// Pure matcher, split out for tests: `ps -axo pid=,command=` lines in,
    /// PIDs of orphaned workers out.
    static func orphanPIDs(inPSOutput output: String) -> [pid_t] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<spaceIndex])
            else { return nil }
            let command = String(trimmed[trimmed.index(after: spaceIndex)...])
            let binary = command.split(separator: " ", maxSplits: 1)[0]
            let binaryName = String(binary.split(separator: "/").last ?? binary)
            guard workerBinaries.contains(binaryName),
                  markers.contains(where: { command.contains($0) })
            else { return nil }
            return pid
        }
    }
}
