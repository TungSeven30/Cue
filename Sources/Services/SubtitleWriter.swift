import Foundation

enum SubtitleExportFormat: String, CaseIterable, Identifiable {
    case srt
    case text
    case markdown
    case json

    var id: String { rawValue }

    var label: String {
        switch self {
        case .srt: return "SRT"
        case .text: return "Plain Text"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .srt: return "srt"
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
            \(segment.text)
            """
        }
        .joined(separator: "\n\n") + "\n"

        try srt.write(to: url, atomically: true, encoding: .utf8)
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
            "- `\(formatDisplayTimestamp(segment.start)) - \(formatDisplayTimestamp(segment.end))` \(segment.text)"
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

    static func formatDisplayTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let wholeSeconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
    }

    static func formatSRTTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let wholeSeconds = Int(seconds) % 60
        let milliseconds = Int((seconds - floor(seconds)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, milliseconds)
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        formatSRTTimestamp(seconds)
    }
}
