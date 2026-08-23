import Foundation

/// A page URL fetched with yt-dlp so it can enter the queue as an ordinary
/// job. Cue never scrapes sites itself: yt-dlp is spawned exactly the way
/// ffmpeg and python3 are, and everything downstream — transcription,
/// translation, export — sees a plain local file.
enum MediaDownloadError: LocalizedError {
    case toolMissing
    case notAWebURL(String)
    case ytDlpFailed(String)
    case noMediaProduced

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "yt-dlp is not installed. Run `brew install yt-dlp` and try again."
        case .notAWebURL(let text):
            return "\(text) is not an http(s) address."
        case .ytDlpFailed(let message):
            return message.isEmpty ? "yt-dlp exited with an error." : message
        case .noMediaProduced:
            return "yt-dlp finished but produced no media file."
        }
    }
}

struct MediaDownloadUpdate: Sendable {
    /// 0...1 while the transfer reports a percentage; nil for the
    /// indeterminate phases (resolving the page, merging streams).
    let fraction: Double?
    let detail: String
}

struct MediaDownloadService: Sendable {
    /// Where finished downloads land by default. A visible, user-owned
    /// folder rather than a cache: the source file has to keep existing for
    /// the job to be re-runnable, and sidecar export writes next to it.
    nonisolated static func defaultDirectory() -> URL {
        let movies =
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent("Cue Downloads", isDirectory: true)
    }

    /// Whether yt-dlp is reachable on the PATH spawned helpers see. Unlike
    /// `ProcessEnvironment.hasFFmpeg` this is not cached for the launch:
    /// installing yt-dlp is the documented fix for the one error this
    /// feature can produce, so the next attempt must see it.
    static var isAvailable: Bool {
        ProcessEnvironment.toolExists("yt-dlp")
    }

    /// Accepts what a person actually pastes — surrounding whitespace, a
    /// bare `youtu.be/…` without a scheme, a URL wrapped in angle brackets —
    /// and returns nil for anything that is not a web address. File paths
    /// are rejected here on purpose: they belong on the normal add path.
    static func normalizedWebURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return nil }

        let lowered = trimmed.lowercased()
        if lowered.contains("://") {
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
        } else if let colon = trimmed.firstIndex(of: ":") {
            // A colon with no "//" is either a scheme (mailto:, magnet:) or a
            // port. Only a port — digits straight after the colon — can be a
            // web address; without this check "mailto:me@example.com" parses
            // as the host example.com with a userinfo of "mailto:me".
            guard let next = trimmed[trimmed.index(after: colon)...].first, next.isNumber else { return nil }
        }

        let candidate = lowered.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host(), host.contains(".")
        else { return nil }
        return url
    }

    /// yt-dlp invocation for one page. The output template writes into a
    /// private staging directory so the finished file can be identified by
    /// being the only thing in it — far more robust than parsing yt-dlp's
    /// `--print filepath`, whose flags interact with `--quiet`/`--simulate`
    /// differently across versions.
    static func makeArguments(url: URL, stagingDirectory: URL) -> [String] {
        [
            "yt-dlp",
            // One page means one file; a URL that also names a playlist must
            // not silently enqueue 200 videos.
            "--no-playlist",
            // Line-buffered progress instead of \r-repainted status, and no
            // ANSI colour codes to strip back out.
            "--newline",
            "--no-color",
            "--no-part",
            // Best video+audio, falling back to the best single stream.
            "-f", "bv*+ba/b",
            "--merge-output-format", "mp4",
            // %(title).150B truncates on a byte boundary, so a long CJK
            // title cannot produce an invalid filename.
            "-o", stagingDirectory.appendingPathComponent("%(title).150B.%(ext)s").path,
            url.absoluteString,
        ]
    }

    /// Turns one yt-dlp stdout line into a progress update, or nil for the
    /// lines that carry no user-visible state.
    static func parseProgress(_ line: String) -> MediaDownloadUpdate? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[download]") {
            let body = trimmed.dropFirst("[download]".count).trimmingCharacters(in: .whitespaces)
            if let percentRange = body.range(of: "% of") {
                let percentText = body[body.startIndex..<percentRange.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                if let percent = Double(percentText) {
                    return MediaDownloadUpdate(
                        fraction: min(max(percent / 100, 0), 1),
                        detail: "Downloading… \(Int(percent))%"
                    )
                }
            }
            if body.hasPrefix("Destination:") {
                return MediaDownloadUpdate(fraction: 0, detail: "Downloading…")
            }
            return nil
        }
        if trimmed.hasPrefix("[Merger]") {
            return MediaDownloadUpdate(fraction: nil, detail: "Merging audio and video…")
        }
        if trimmed.hasPrefix("[info]") || trimmed.hasPrefix("[youtube]") {
            return nil
        }
        return nil
    }

    /// The finished media file inside a staging directory: the largest
    /// regular file with a known media extension. yt-dlp leaves the
    /// pre-merge streams behind in some configurations, and the merged
    /// result is always the biggest of them.
    static func finishedMedia(in directory: URL) -> URL? {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return
            contents
            .filter { MediaFileTypes.extensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .max { left, right in
                let leftSize = (try? left.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let rightSize = (try? right.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return leftSize < rightSize
            }
    }

    /// A destination inside `directory` that does not collide with an
    /// existing file: `clip.mp4`, then `clip-2.mp4`, and so on. Re-fetching
    /// the same page must never overwrite a file an earlier job still
    /// points at.
    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for suffix in 2...999 {
            let next = directory.appendingPathComponent(
                ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            )
            if !FileManager.default.fileExists(atPath: next.path) {
                return next
            }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }

    /// Downloads `url` into `directory` and returns the resulting file.
    /// Main-actor isolated, like BurnInService.burnIn, so `onProgress` can
    /// drive UI directly without a hop at every call site.
    @MainActor
    func download(
        url: URL,
        into directory: URL,
        onProgress: @escaping @MainActor (MediaDownloadUpdate) -> Void
    ) async throws -> URL {
        guard Self.isAvailable else { throw MediaDownloadError.toolMissing }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".cue-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        onProgress(MediaDownloadUpdate(fraction: nil, detail: "Resolving link…"))

        let processBox = DownloadProcessBox()
        let collector = DownloadOutputCollector()

        let status: Int32 = try await withTaskCancellationHandler {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.environment = ProcessEnvironment.withToolPaths()
            process.arguments = Self.makeArguments(url: url, stagingDirectory: staging)

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    collector.markStdoutEOF()
                    return
                }
                for line in collector.appendStdout(String(decoding: data, as: UTF8.self)) {
                    guard let update = Self.parseProgress(line) else { continue }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { onProgress(update) }
                    }
                }
            }
            // yt-dlp reports failures on stderr; keep a tail for the error
            // message without letting a long traceback fill the pipe buffer.
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    collector.markStderrEOF()
                    return
                }
                collector.appendStderr(String(decoding: data, as: UTF8.self))
            }

            processBox.process = process
            try process.run()
            // A cancel that landed between storing the process and run()
            // saw isRunning == false; catch up so a canceled download does
            // not keep pulling gigabytes in the background.
            if Task.isCancelled {
                processBox.terminate()
            }
            let terminationStatus = await process.waitForTermination()
            await collector.waitForEOF()
            return terminationStatus
        } onCancel: {
            processBox.terminate()
        }

        if Task.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw MediaDownloadError.ytDlpFailed(collector.errorTail())
        }
        guard let produced = Self.finishedMedia(in: staging) else {
            throw MediaDownloadError.noMediaProduced
        }

        let destination = Self.uniqueDestination(for: produced.lastPathComponent, in: directory)
        try FileManager.default.moveItem(at: produced, to: destination)
        return destination
    }
}

/// Holds the in-flight Process so the cancellation handler (which must be
/// Sendable and runs concurrently) can terminate it. Mirrors the boxes in
/// TranscriptionService and BurnInService. Shared with YtDlpInstaller,
/// which needs the same terminate-then-escalate semantics for brew.
final class DownloadProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcess: Process?

    var process: Process? {
        get { lock.withLock { storedProcess } }
        set { lock.withLock { storedProcess = newValue } }
    }

    func terminate() {
        let process = lock.withLock { storedProcess }
        guard let process, process.isRunning else { return }
        process.terminate()
        // yt-dlp spawns ffmpeg for the merge step and can sit in a blocking
        // wait; escalate rather than leave a canceled download running.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Line-splits stdout for progress parsing and keeps a bounded stderr tail
/// for error reporting, with EOF signalling so the last chunk — usually the
/// actual failure line — is never lost to the exit race.
/// Internal rather than private so the line-splitting and error-tail logic
/// can be tested directly: both fail silently in production — a missed
/// newline just stops progress updating, and a lost stderr tail turns a
/// specific yt-dlp error into a bare exit status.
final class DownloadOutputCollector: @unchecked Sendable {
    private static let maxErrorLength = 8_000

    private let lock = NSLock()
    private var pendingStdout = ""
    private var stderrTail = ""
    private var stdoutAtEOF = false
    private var stderrAtEOF = false
    private var eofContinuation: CheckedContinuation<Void, Never>?

    func appendStdout(_ text: String) -> [String] {
        lock.lock()
        pendingStdout += text
        var lines: [String] = []
        while let newline = pendingStdout.firstIndex(of: "\n") {
            lines.append(String(pendingStdout[pendingStdout.startIndex..<newline]))
            pendingStdout = String(pendingStdout[pendingStdout.index(after: newline)...])
        }
        lock.unlock()
        return lines
    }

    func appendStderr(_ text: String) {
        lock.withLock {
            stderrTail += text
            if stderrTail.count > Self.maxErrorLength {
                stderrTail = String(stderrTail.suffix(Self.maxErrorLength))
            }
        }
    }

    func errorTail() -> String {
        let tail = lock.withLock { stderrTail }
        return
            tail
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: "\n")
    }

    func markStdoutEOF() {
        lock.lock()
        stdoutAtEOF = true
        let continuation = resumableContinuationLocked()
        lock.unlock()
        continuation?.resume()
    }

    func markStderrEOF() {
        lock.lock()
        stderrAtEOF = true
        let continuation = resumableContinuationLocked()
        lock.unlock()
        continuation?.resume()
    }

    func waitForEOF() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stdoutAtEOF && stderrAtEOF {
                lock.unlock()
                continuation.resume()
                return
            }
            eofContinuation = continuation
            lock.unlock()
        }
    }

    private func resumableContinuationLocked() -> CheckedContinuation<Void, Never>? {
        guard stdoutAtEOF, stderrAtEOF else { return nil }
        let continuation = eofContinuation
        eofContinuation = nil
        return continuation
    }
}
