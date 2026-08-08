import Foundation

/// Renders subtitles into an MP4 with ffmpeg (spec §3). ffmpeg is an
/// opt-in dependency for this feature alone; everything here degrades to a
/// disabled button when it is missing.
struct BurnInService {
    enum BurnInError: LocalizedError {
        case outputWouldReplaceSource
        case ffmpegFailed(String)

        var errorDescription: String? {
            switch self {
            case .outputWouldReplaceSource:
                return "The output file would replace the source video. Choose a different name."
            case .ffmpegFailed(let message):
                return message
            }
        }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var label: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    /// libass sizes against a default PlayResY of 384, so these values are
    /// resolution-independent.
    static func forceStyle(for size: TextSize) -> String {
        switch size {
        case .small: return "FontSize=14,MarginV=18,BorderStyle=3"
        case .medium: return "FontSize=20,MarginV=22,BorderStyle=3"
        case .large: return "FontSize=27,MarginV=26,BorderStyle=3"
        }
    }

    /// A fresh temp directory whose path contains no libass filter
    /// metacharacters; the SRT is always written here under a fixed name so
    /// user-controlled text never reaches the filter string (spec §3.2).
    static func makeWorkingSubtitleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-burnin-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("subs.srt")
    }

    static func validateOutput(source: URL, output: URL) throws {
        if source.standardizedFileURL.path == output.standardizedFileURL.path {
            throw BurnInError.outputWouldReplaceSource
        }
    }

    static func makeArguments(source: URL, subtitleFile: URL, forceStyle: String, output: URL) -> [String] {
        [
            "-y", "-nostdin",
            "-i", source.path,
            "-vf", "subtitles=filename=\(subtitleFile.path):force_style='\(forceStyle)'",
            "-c:v", "h264_videotoolbox", "-q:v", "60",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    /// Parses "time=HH:MM:SS.cc" from an ffmpeg stderr stats line.
    static func parseProgressSeconds(fromStderrLine line: String) -> Double? {
        guard let range = line.range(of: #"time=(\d+):(\d{2}):(\d{2}(?:\.\d+)?)"#, options: .regularExpression) else {
            return nil
        }
        let value = line[range].dropFirst("time=".count)
        let parts = value.split(separator: ":")
        guard parts.count == 3,
            let hours = Double(parts[0]),
            let minutes = Double(parts[1]),
            let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Preflight half 2 (spec §3.1): the filter list must include
    /// `subtitles`, or this build lacks libass and would fail mid-encode.
    static func hasSubtitlesFilter(inFiltersOutput output: String) -> Bool {
        output.contains(" subtitles ")
    }

    struct PreflightResult {
        let available: Bool
        let message: String?
    }

    /// Runs both preflight checks (spec §3.1). Not cached here — AppModel
    /// caches the result and exposes a Recheck, because "just installed
    /// ffmpeg" is exactly when a stale probe hurts.
    static func preflight() async -> PreflightResult {
        let output = await runCapturingOutput(arguments: ["ffmpeg", "-hide_banner", "-filters"])
        guard let output else {
            return PreflightResult(available: false, message: "ffmpeg was not found. Install it with: brew install ffmpeg")
        }
        guard hasSubtitlesFilter(inFiltersOutput: output) else {
            return PreflightResult(available: false, message: "This ffmpeg build lacks the subtitles filter (libass). Reinstall with: brew install ffmpeg")
        }
        return PreflightResult(available: true, message: nil)
    }

    /// Runs a command via /usr/bin/env with tool paths; nil if launch fails
    /// or it exits non-zero.
    private static func runCapturingOutput(arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.environment = ProcessEnvironment.withToolPaths()
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// Writes the SRT to a safe temp path, runs ffmpeg, reports progress from
    /// stderr, and cleans up. On any failure or cancellation the partial
    /// output and the temp directory are removed (spec §3.2/§3.4).
    @MainActor
    func burnIn(
        source: URL,
        segments: [TranscriptionSegment],
        textSize: TextSize,
        output: URL,
        durationSeconds: Double,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws {
        try Self.validateOutput(source: source, output: output)

        let subtitleURL = Self.makeWorkingSubtitleURL()
        let workingDirectory = subtitleURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        try SubtitleWriter.writeSRT(segments: segments, to: subtitleURL)

        // A process box, mirroring TranscriptionService's ProcessBox, lets
        // the onCancel closure below terminate the process without
        // capturing the non-Sendable Process directly.
        let processBox = BurnInProcessBox()
        let collector = StderrCollector()

        try await withTaskCancellationHandler {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.environment = ProcessEnvironment.withToolPaths()
            process.arguments =
                ["ffmpeg"]
                + Self.makeArguments(
                    source: source,
                    subtitleFile: subtitleURL,
                    forceStyle: Self.forceStyle(for: textSize),
                    output: output
                )

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()

            // Collect a stderr tail for error reporting while scanning lines
            // for progress stamps.
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    collector.markEOF()
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                collector.append(text)
                if durationSeconds > 0, let seconds = Self.parseProgressSeconds(fromStderrLine: text) {
                    let fraction = min(seconds / durationSeconds, 0.999)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            progress(fraction, String(format: "Rendering… %.0f%%", fraction * 100))
                        }
                    }
                }
            }

            processBox.process = process
            try process.run()
            // A cancellation that landed between storing the process and
            // run() found isRunning == false and did nothing; catch up now
            // so ffmpeg does not run a full encode after cancel.
            if Task.isCancelled {
                processBox.terminate()
            }
            let terminationStatus = await process.waitForTermination()
            // The process exiting does not guarantee the readability handler
            // (on a background queue) has delivered the last stderr chunk —
            // and that chunk is usually ffmpeg's actual fatal error line.
            await collector.waitForEOF()

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            }
            guard terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: output)
                throw BurnInError.ffmpegFailed(collector.tail())
            }
        } onCancel: {
            processBox.terminate()
        }
    }
}

/// Mirrors TranscriptionService's ProcessBox: holds the in-flight Process so
/// the withTaskCancellationHandler's onCancel closure (which runs
/// concurrently and must be Sendable) can terminate it safely.
private final class BurnInProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcess: Process?

    var process: Process? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProcess
        }
        set {
            lock.lock()
            storedProcess = newValue
            lock.unlock()
        }
    }

    func terminate() {
        lock.lock()
        let process = storedProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        // ffmpeg may not exit promptly on SIGTERM if a native codec is mid
        // frame; escalate to SIGKILL rather than leave the app hung waiting.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Accumulates ffmpeg stderr across the readability handler's background
/// queue; keeps only a bounded tail for error messages.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var eofReached = false
    private var eofWaiter: CheckedContinuation<Void, Never>?

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        if text.count > 8000 {
            text = String(text.suffix(4000))
        }
        lock.unlock()
    }

    /// Called when the pipe reads empty data (EOF). Resumes any waiter.
    func markEOF() {
        lock.lock()
        eofReached = true
        let waiter = eofWaiter
        eofWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    /// Blocks (async) until the pipe has drained; the process exiting does
    /// not guarantee the last stderr chunk has been delivered yet.
    func waitForEOF() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if eofReached {
                lock.unlock()
                continuation.resume()
            } else {
                eofWaiter = continuation
                lock.unlock()
            }
        }
    }

    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        let lines = text.split(separator: "\n").suffix(6)
        return lines.isEmpty ? "ffmpeg failed with no error output." : lines.joined(separator: "\n")
    }
}
