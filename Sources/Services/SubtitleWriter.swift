import Foundation

enum SubtitleExportFormat: String, Codable, CaseIterable, Identifiable {
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
        let srt =
            segments.map { segment in
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
        let text =
            segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeMarkdown(segments: [TranscriptionSegment], to url: URL) throws {
        let markdown =
            segments.map { segment in
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

    /// Prepends the intro-summary cue to a subtitle document. The intro runs
    /// from 0s until the first dialogue, capped at 10s; a minimum of 3s keeps
    /// it readable in fast-starting films (a brief overlap beats a flash).
    /// Cue numbers are re-sequenced so the file stays valid.
    static func segmentsPrependingIntro(_ summary: String?, to segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return segments
        }
        let chunks = introCueTexts(summary)
        var introCues: [TranscriptionSegment] = []
        if chunks.count == 1 {
            // Single short summary: keep the original before-the-dialogue
            // window (min 3s for readability, capped at 10s).
            let end: Double
            if let firstStart = segments.first?.start {
                end = min(max(3.0, firstStart), 10.0)
            } else {
                end = 8.0
            }
            introCues = [TranscriptionSegment(id: 1, start: 0, end: end, text: chunks[0])]
        } else {
            // A detailed summary runs as a sequence of cues, each held for
            // its reading time. They may overlap early dialogue — SRT allows
            // overlapping cues and players stack them; losing the intro to a
            // fast cold open would be worse.
            var cursor = 0.0
            for (index, chunk) in chunks.enumerated() {
                let duration = min(8.0, max(3.5, Double(chunk.count) * 0.055))
                introCues.append(TranscriptionSegment(id: index + 1, start: cursor, end: cursor + duration, text: chunk))
                cursor += duration
            }
        }
        let renumbered = segments.enumerated().map { index, segment in
            TranscriptionSegment(id: index + introCues.count + 1, start: segment.start, end: segment.end, text: segment.text)
        }
        return introCues + renumbered
    }

    /// Splits a summary into screen-sized pieces on sentence boundaries,
    /// packing sentences together while they fit. A short summary stays
    /// whole; a detailed one becomes a readable sequence instead of a wall
    /// of text in a single cue.
    static func introCueTexts(_ summary: String, limit: Int = 220) -> [String] {
        guard summary.count > limit else { return [summary] }
        var sentences: [String] = []
        summary.enumerateSubstrings(in: summary.startIndex..., options: .bySentences) { piece, _, _, _ in
            if let piece = piece?.trimmingCharacters(in: .whitespacesAndNewlines), !piece.isEmpty {
                sentences.append(piece)
            }
        }
        guard !sentences.isEmpty else { return [summary] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= limit {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
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
        let clamped = clampedTimestamp(seconds)
        let hours = Int(clamped / 3600)
        let minutes = Int((clamped.truncatingRemainder(dividingBy: 3600)) / 60)
        let wholeSeconds = Int(clamped) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
    }

    /// `Int(_:)` traps on NaN, infinity, and out-of-range doubles; a single
    /// bad cue must never take the app down, so clamp to a range every
    /// player accepts (0 to just under 100 hours).
    static func clampedTimestamp(_ seconds: Double) -> Double {
        guard !seconds.isNaN else { return 0 }
        return min(max(0, seconds), 359_999.999)
    }

    static func formatSRTTimestamp(_ seconds: Double) -> String {
        // Round to whole milliseconds first so values like 1.0599 become
        // 00:00:01,060 instead of truncating to ,059, and let the carry
        // roll into seconds naturally.
        let totalMilliseconds = Int((clampedTimestamp(seconds) * 1000).rounded())
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
