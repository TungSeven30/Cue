import Foundation

/// Reads SRT and WebVTT back into segments. The app never needs this — it
/// keeps segments on the job — but the CLI does: `cue translate old.srt`
/// only makes sense if subtitles Cue did not produce can enter a stage.
enum SubtitleReader {
    enum ReadError: LocalizedError {
        case noCues(String)

        var errorDescription: String? {
            switch self {
            case .noCues(let path):
                return "No subtitle cues found in \(path)."
            }
        }
    }

    static func read(contentsOf url: URL) throws -> [TranscriptionSegment] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let segments = parse(text)
        guard !segments.isEmpty else { throw ReadError.noCues(url.lastPathComponent) }
        return segments
    }

    /// Parses either format. Cue numbers are re-sequenced from 1 rather than
    /// trusted: a hand-edited file can repeat or skip them, and every
    /// downstream stage matches translations to sources by id.
    static func parse(_ text: String) -> [TranscriptionSegment] {
        let normalized =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // A BOM survives into the first cue number and breaks Int parsing.
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))

        var segments: [TranscriptionSegment] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTimingLine(lines[arrowIndex]) else { continue }
            let body =
                lines[lines.index(after: arrowIndex)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // WEBVTT's header block has an arrow-free first block, and a
            // NOTE block has no timing line, so both are skipped above.
            segments.append(
                TranscriptionSegment(id: segments.count + 1, start: start, end: end, text: body)
            )
        }
        return segments
    }

    static func parseTimingLine(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
            let start = parseTimestamp(parts[0]),
            // VTT cue settings ("align:start position:10%") ride on the end
            // stamp; take the first whitespace-separated token.
            let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0])
        else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, and VTT's `MM:SS.mmm`.
    static func parseTimestamp(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.components(separatedBy: ":")
        guard components.count == 2 || components.count == 3 else { return nil }

        var seconds = 0.0
        for (index, component) in components.enumerated() {
            guard let value = Double(component) else { return nil }
            // The last component carries the fraction; the ones before it
            // are whole minutes and hours.
            let isLast = index == components.count - 1
            if !isLast, value != value.rounded() { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}
