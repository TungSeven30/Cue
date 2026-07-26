import Foundation

enum SubtitleExportFormat: String, CaseIterable, Identifiable {
    case srt
    case vtt
    case text
    case markdown
    case json

    var id: String { rawValue }

    var label: String {
        switch self {
        case .srt: return "SRT"
        case .vtt: return "WebVTT"
        case .text: return "Plain Text"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .text: return "txt"
        case .markdown: return "md"
        case .json: return "json"
        }
    }
}

enum SubtitleWriter {
    static func write(segments: [TranscriptionSegment], format: SubtitleExportFormat, to url: URL) throws {
        switch format {
        case .srt:
            try writeSRT(segments: segments, to: url)
        case .vtt:
            try writeVTT(segments: segments, to: url)
        case .text:
            try writeText(segments: segments, to: url)
        case .markdown:
            try writeMarkdown(segments: segments, to: url)
        case .json:
            try writeJSON(segments: segments, to: url)
        }
    }

    static func writeSRT(segments: [TranscriptionSegment], to url: URL) throws {
        let srt = segments.map { segment in
            """
            \(segment.id)
            \(formatTimestamp(segment.start)) --> \(formatTimestamp(segment.end))
            \(sanitizedCueText(segment.text))
            """
        }
        .joined(separator: "\n\n") + "\n"

        try srt.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeVTT(segments: [TranscriptionSegment], to url: URL) throws {
        let body = segments.map { segment in
            """
            \(segment.id)
            \(formatVTTTimestamp(segment.start)) --> \(formatVTTTimestamp(segment.end))
            \(sanitizedCueText(segment.text))
            """
        }
        .joined(separator: "\n\n")

        try ("WEBVTT\n\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeText(segments: [TranscriptionSegment], to url: URL) throws {
        let text = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeMarkdown(segments: [TranscriptionSegment], to url: URL) throws {
        let markdown = segments.map { segment in
            let singleLine = sanitizedCueText(segment.text).replacingOccurrences(of: "\n", with: " / ")
            return "- `\(formatDisplayTimestamp(segment.start)) - \(formatDisplayTimestamp(segment.end))` \(singleLine)"
        }
        .joined(separator: "\n") + "\n"
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeJSON(segments: [TranscriptionSegment], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(segments)
        try data.write(to: url, options: .atomic)
    }

    /// A blank line terminates a cue in SRT/VTT, so a translation containing
    /// consecutive newlines would corrupt every cue after it. Collapse runs
    /// of newlines to a single line break (intentional two-line cues, e.g.
    /// bilingual captions, survive) and trim the edges.
    static func sanitizedCueText(_ text: String) -> String {
        var sanitized = text.replacingOccurrences(of: "\r\n", with: "\n")
        sanitized = sanitized.replacingOccurrences(of: "\r", with: "\n")
        while sanitized.contains("\n\n") {
            sanitized = sanitized.replacingOccurrences(of: "\n\n", with: "\n")
        }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatDisplayTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let wholeSeconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
    }

    static func formatSRTTimestamp(_ seconds: Double) -> String {
        // Round to whole milliseconds first so values like 1.0599 become
        // 00:00:01,060 instead of truncating to ,059, and let the carry
        // roll into seconds naturally.
        let totalMilliseconds = max(0, Int((seconds * 1000).rounded()))
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let wholeSeconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, milliseconds)
    }

    static func formatVTTTimestamp(_ seconds: Double) -> String {
        formatSRTTimestamp(seconds).replacingOccurrences(of: ",", with: ".")
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        formatSRTTimestamp(seconds)
    }
}
