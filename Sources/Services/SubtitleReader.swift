import Foundation

/// Parse-only counterpart to `SubtitleWriter`. Reads SRT and WebVTT into the
/// same `TranscriptionSegment` array every downstream consumer already uses.
enum SubtitleReader {
    enum ReadError: Error, Equatable {
        case unreadable
        case unsupportedFormat(String)
        case noCues
        case tooLarge(Int)
    }

    /// A 20 MB "subtitle" is a mislabeled video; refuse it rather than read it
    /// into memory.
    static let maximumFileSize = 20 * 1024 * 1024

    static func format(for url: URL) -> SubtitleExportFormat? {
        switch url.pathExtension.lowercased() {
        case "srt": return .srt
        case "vtt": return .vtt
        default: return nil
        }
    }

    static func parse(contentsOf url: URL) throws -> [TranscriptionSegment] {
        guard let format = format(for: url) else {
            throw ReadError.unsupportedFormat(url.pathExtension.lowercased())
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maximumFileSize else { throw ReadError.tooLarge(size) }
        guard let data = try? Data(contentsOf: url), let text = decode(data) else {
            throw ReadError.unreadable
        }
        return try parse(text, format: format)
    }

    /// SRT files in the wild are frequently Latin-1, so a UTF-8 failure must
    /// not end the attempt. Order matters: UTF-16 BOM must be checked first
    /// (Foundation's `.utf16` decoder is lenient and will claim non-UTF-16 bytes
    /// as valid, shadowing other encodings), then UTF-8 (the modern default),
    /// then Windows-1252 last because it decodes any byte sequence.
    static func decode(_ data: Data) -> String? {
        // Check for UTF-16 BOM explicitly: FF FE (LE) or FE FF (BE).
        // Only try UTF-16 if the BOM is present; raw UTF-16 detection is too
        // lenient and can succeed on Windows-1252 bytes, producing garbage.
        if data.count >= 2 {
            let first = data[data.startIndex]
            let second = data[data.index(after: data.startIndex)]
            if (first == 0xFF && second == 0xFE) || (first == 0xFE && second == 0xFF) {
                if let text = String(data: data, encoding: .utf16) {
                    return stripBOM(text)
                }
            }
        }

        // Try UTF-8 next (the modern default).
        if let text = String(data: data, encoding: .utf8) {
            return stripBOM(text)
        }

        // Fall back to Windows-1252, which accepts any byte sequence.
        if let text = String(data: data, encoding: .windowsCP1252) {
            return stripBOM(text)
        }

        return nil
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    static func parse(_ text: String, format: SubtitleExportFormat) throws -> [TranscriptionSegment] {
        let normalized =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // OCR and conversion tools write separator lines that carry a
            // space or tab. Without this they don't split, so two cues merge
            // into one whose text swallows the next cue's index and timings —
            // and write-back would persist that into the user's own file. The
            // lookahead leaves the trailing newline in place so consecutive
            // whitespace-only lines collapse too.
            .replacingOccurrences(of: "\n[ \t]+(?=\n)", with: "\n", options: .regularExpression)

        var segments: [TranscriptionSegment] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines =
                block
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = lines.first else { continue }
            if format == .vtt, isVTTMetadata(first) { continue }

            // A malformed block is skipped rather than fatal: real files carry
            // junk tails, and losing the whole transcript to one bad cue is
            // the worse failure.
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                let timing = parseTimingLine(lines[timingIndex])
            else { continue }

            let body = lines[lines.index(after: timingIndex)...].joined(separator: "\n")
            let cleaned = SubtitleWriter.sanitizedCueText(body)
            guard !cleaned.isEmpty else { continue }

            // Ids are assigned here, never read from the file: they double as
            // the join key for bilingual export and translation reconciliation,
            // and third-party files routinely repeat or skip indices.
            segments.append(
                TranscriptionSegment(
                    id: segments.count + 1,
                    start: timing.start,
                    end: max(timing.end, timing.start),
                    text: cleaned
                )
            )
        }
        guard !segments.isEmpty else { throw ReadError.noCues }
        return segments
    }

    private static func isVTTMetadata(_ line: String) -> Bool {
        ["WEBVTT", "NOTE", "STYLE", "REGION"].contains { line.hasPrefix($0) }
    }

    struct Timing: Equatable {
        let start: Double
        let end: Double
    }

    static func parseTimingLine(_ line: String) -> Timing? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        // Trailing WebVTT cue settings ("align:start position:10%") and legacy
        // SRT coordinates ("X1:0 X2:100") follow the end timestamp.
        let endToken =
            parts[1]
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .first ?? ""
        guard let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
            let end = parseTimestamp(endToken)
        else { return nil }
        return Timing(start: start, end: end)
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, and `MM:SS.mmm` — WebVTT makes
    /// the hours field optional and several exporters omit it.
    static func parseTimestamp(_ token: String) -> Double? {
        let pieces = token.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard (2...3).contains(pieces.count) else { return nil }
        var seconds = 0.0
        for piece in pieces.dropLast() {
            guard let value = Double(piece) else { return nil }
            seconds = seconds * 60 + value
        }
        guard let last = Double(pieces[pieces.count - 1]) else { return nil }
        return seconds * 60 + last
    }
}

/// A manual Load Subtitles… failure is shown in a dialog, so the default
/// "The operation couldn't be completed. (…error 2.)" is not good enough:
/// every case has to say what is actually wrong with the file.
extension SubtitleReader.ReadError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The file could not be read as text."
        case .unsupportedFormat(let fileExtension):
            let named = fileExtension.isEmpty ? "That kind of file" : "“.\(fileExtension)” files"
            return "\(named) can't be loaded. Choose an SRT or WebVTT subtitle file."
        case .noCues:
            return "The file contains no subtitle cues."
        case .tooLarge(let size):
            let actual = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(SubtitleReader.maximumFileSize),
                countStyle: .file
            )
            return "The file is \(actual), past the \(limit) limit for subtitle files."
        }
    }
}
