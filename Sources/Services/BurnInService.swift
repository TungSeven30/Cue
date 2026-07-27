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
            .appendingPathComponent("whisperdesk-burnin-\(UUID().uuidString)", isDirectory: true)
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
}
