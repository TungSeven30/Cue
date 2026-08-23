import Foundation

enum YtDlpInstallError: LocalizedError {
    case homebrewMissing
    case installFailed(String)
    case stillMissing

    var errorDescription: String? {
        switch self {
        case .homebrewMissing:
            return "Homebrew is not installed. Get it from brew.sh, then run `brew install yt-dlp`."
        case .installFailed(let message):
            return message.isEmpty ? "Installing yt-dlp failed." : message
        case .stillMissing:
            return "Homebrew finished, but yt-dlp still is not available."
        }
    }
}

/// Installs yt-dlp through Homebrew so Add from URL works on a fresh machine
/// instead of telling the user to open Terminal. Spawned exactly like every
/// other helper; success is verified by re-probing for the tool, never by
/// trusting brew's exit status alone — brew can exit zero on a skipped or
/// already-installed formula that is still unreachable.
@MainActor
struct YtDlpInstaller {
    nonisolated static let defaultHomebrewLocations = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    nonisolated static func homebrewURL(searchPaths: [String] = defaultHomebrewLocations) -> URL? {
        searchPaths
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func makeArguments() -> [String] {
        ["install", "yt-dlp"]
    }

    /// Coarse phases for the progress sheet; unrecognized lines pass through
    /// so brew's own words carry whatever this mapping does not anticipate.
    nonisolated static func progressDetail(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("==> ") else { return trimmed }
        let phase = trimmed.dropFirst(4)
        if phase.hasPrefix("Auto-updating") || phase.hasPrefix("Updating") { return "Updating Homebrew…" }
        if phase.hasPrefix("Downloading") || phase.hasPrefix("Fetching") { return "Downloading yt-dlp…" }
        if phase.hasPrefix("Pouring") { return "Unpacking yt-dlp…" }
        if phase.hasPrefix("Installing") { return "Installing yt-dlp…" }
        return String(phase)
    }

    /// Runs `brew install yt-dlp` to completion. `onProgress` receives one
    /// human-readable line per interesting piece of brew output.
    func install(onProgress: @escaping @MainActor (String) -> Void) async throws {
        guard let brew = Self.homebrewURL() else { throw YtDlpInstallError.homebrewMissing }

        let processBox = DownloadProcessBox()
        let collector = DownloadOutputCollector()

        let status: Int32 = try await withTaskCancellationHandler {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.environment = ProcessEnvironment.withToolPaths()
            process.arguments = [brew.path] + Self.makeArguments()

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
                    guard let detail = Self.progressDetail(from: line) else { continue }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { onProgress(detail) }
                    }
                }
            }
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
            if Task.isCancelled { processBox.terminate() }
            let terminationStatus = await process.waitForTermination()
            await collector.waitForEOF()
            return terminationStatus
        } onCancel: {
            processBox.terminate()
        }

        if Task.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw YtDlpInstallError.installFailed(collector.errorTail())
        }
        guard MediaDownloadService.isAvailable else { throw YtDlpInstallError.stillMissing }
    }
}
