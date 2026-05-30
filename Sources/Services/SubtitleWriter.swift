import Foundation

enum SubtitleWriter {
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

    private static func formatTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let wholeSeconds = Int(seconds) % 60
        let milliseconds = Int((seconds - floor(seconds)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, milliseconds)
    }
}
