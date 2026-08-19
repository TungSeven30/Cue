import Foundation

/// stdout carries the result — the manifest JSON under `--json` — and
/// nothing else. Progress, warnings, and file notices go to stderr, so
/// `cue transcribe clip.mp4 --json | jq .transcript` works without any
/// quieting flags.
@MainActor
final class CLIConsole {
    let isJSON: Bool
    let isQuiet: Bool

    init(isJSON: Bool, isQuiet: Bool) {
        self.isJSON = isJSON
        self.isQuiet = isQuiet
    }

    func note(_ message: String) {
        guard !isQuiet else { return }
        writeError(message + "\n")
    }

    func result(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    func failure(_ message: String) {
        writeError("error: " + message + "\n")
    }

    func progressReporter(stage: String) -> CLIProgressReporter {
        CLIProgressReporter(stage: stage, console: self)
    }

    fileprivate func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Collapses the fine-grained progress the services emit into one stderr
/// line per visible change. Transcription reports several times a second;
/// printing all of it would bury the output a person is reading and fill a
/// CI log with thousands of near-identical lines.
@MainActor
final class CLIProgressReporter {
    private let stage: String
    private let console: CLIConsole
    private var lastPercent: Int?
    private var lastDetail: String?

    init(stage: String, console: CLIConsole) {
        self.stage = stage
        self.console = console
    }

    func report(fraction: Double?, detail: String) {
        guard !console.isQuiet else { return }
        let percent = fraction.map { Int(($0 * 100).rounded()) }
        guard percent != lastPercent || detail != lastDetail else { return }
        lastPercent = percent
        lastDetail = detail
        let prefix = percent.map { String(format: "%3d%% ", $0) } ?? "     "
        console.writeError("[\(stage)] \(prefix)\(detail)\n")
    }
}
