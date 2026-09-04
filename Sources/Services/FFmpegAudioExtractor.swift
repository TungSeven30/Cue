import Foundation

/// Which decoder produced an extracted WAV.
enum ExtractionRoute: Equatable, Sendable {
    /// AVFoundation, in-process.
    case native
    /// The ffmpeg CLI, for containers macOS cannot demux (Matroska above all).
    case ffmpeg
}

/// AVFoundation could not read the file and no ffmpeg is available to try.
struct FFmpegUnavailableError: LocalizedError {
    let underlying: String

    var errorDescription: String? {
        "macOS could not read this file's audio (\(underlying)). Install ffmpeg (brew install ffmpeg) so Cue can read containers macOS does not support, such as MKV."
    }
}

/// Native extraction first, ffmpeg second. Supported containers never touch
/// ffmpeg; MKV and other formats AVFoundation rejects fall through to the
/// same plain `pcm_s16le / 16 kHz / mono` command the Python helper runs, so
/// every backend still shares one cache entry per source file.
enum AudioSourceExtractor {
    static func extract(
        from source: URL,
        to destination: URL,
        hasFFmpeg: Bool = ProcessEnvironment.hasFFmpeg,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ExtractionRoute {
        do {
            try await AudioExtractor.extract(from: source, to: destination, onProgress: progress)
            return .native
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard hasFFmpeg else {
                throw FFmpegUnavailableError(underlying: error.localizedDescription)
            }
            try await FFmpegAudioExtractor.extract(from: source, to: destination)
            return .ffmpeg
        }
    }
}

/// Runs ffmpeg to produce the 16 kHz mono 16-bit PCM WAV the engines expect.
/// Writes to a same-directory temp file and moves it into place, so an
/// interrupted run never leaves a partial WAV where the cache would treat
/// existence as validity.
enum FFmpegAudioExtractor {
    static func extract(
        from source: URL,
        to destination: URL,
        environment: [String: String] = ProcessEnvironment.withToolPaths()
    ) async throws {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".partial-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = environment
        process.arguments = [
            "ffmpeg", "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", source.path, "-vn",
            "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
            // The temp file has no .wav extension, so name the container.
            "-f", "wav", temp.path,
        ]
        let stderr = PipeCollector()
        process.standardError = stderr.pipe
        process.standardOutput = FileHandle.nullDevice
        let box = ProcessBox()
        box.process = process

        try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                throw AudioExtractorError.readerFailed("could not start ffmpeg: \(error.localizedDescription)")
            }
            // A cancellation that landed before run() found nothing to stop.
            if Task.isCancelled {
                box.terminate()
            }
            let status = await process.waitForTermination()
            await stderr.waitForEOF()
            stderr.close()
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: temp)
                throw CancellationError()
            }
            guard status == 0 else {
                try? FileManager.default.removeItem(at: temp)
                let lastLine =
                    stderr.text()
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .last
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw AudioExtractorError.readerFailed(
                    (lastLine?.isEmpty == false ? lastLine! : "ffmpeg exited with status \(status)"))
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        } onCancel: {
            box.terminate()
        }
    }
}
