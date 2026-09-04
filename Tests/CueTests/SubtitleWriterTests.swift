import Foundation
import Testing
@testable import Cue

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cue-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SubtitleWriterTests {
    @Test func plainPreviewDecodesEntitiesOnceAndPreservesLiteralAngleBrackets() {
        #expect(SubtitleWriter.plainCueText("2 < 3 &amp;lt; &#x1F600;") == "2 < 3 &lt; 😀")
        #expect(SubtitleWriter.plainCueText("<c.green>Việt</c><00:01.000> Nam") == "Việt Nam")
        #expect(SubtitleWriter.plainCueText("&#xD800; &unknown;") == "&#xD800; &unknown;")
    }

    // A blank line inside a cue terminates it in every SRT parser, so embedded
    // newline runs from LLM translations must be collapsed.
    @Test func srtCollapsesBlankLinesInsideCueText() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            TranscriptionSegment(id: 1, start: 0, end: 2, text: "Line one\n\nLine two"),
            TranscriptionSegment(id: 2, start: 2, end: 4, text: "Second cue"),
        ]
        let url = dir.appendingPathComponent("blank.srt")
        try SubtitleWriter.writeSRT(segments: segments, to: url)
        let contents = try String(contentsOf: url, encoding: .utf8)

        let cues =
            contents
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(cues.count == 2, "Blank line inside cue text split the file into extra cues:\n\(contents)")
        #expect(cues[0].contains("Line one\nLine two"), "Intentional single line breaks should survive")
    }

    @Test func srtPreservesSingleNewlineForBilingualCues() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [TranscriptionSegment(id: 1, start: 0, end: 2, text: "Original\nTranslation")]
        let url = dir.appendingPathComponent("bilingual.srt")
        try SubtitleWriter.writeSRT(segments: segments, to: url)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("Original\nTranslation"))
    }

    @Test func srtTimestampMillisecondRollover() {
        // 2.9996 rounds to 3.000, which must carry into seconds.
        #expect(SubtitleWriter.formatSRTTimestamp(2.9996) == "00:00:03,000")
        #expect(SubtitleWriter.formatSRTTimestamp(1.0599) == "00:00:01,060")
    }

    @Test func vttOutput() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            TranscriptionSegment(id: 1, start: 0.5, end: 2.25, text: "Hello"),
            TranscriptionSegment(id: 2, start: 3661.0, end: 3662.5, text: "World"),
        ]
        let url = dir.appendingPathComponent("out.vtt")
        try SubtitleWriter.write(segments: segments, format: .vtt, to: url)
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(contents.hasPrefix("WEBVTT\n\n"), "VTT files must start with a WEBVTT header")
        #expect(contents.contains("00:00:00.500 --> 00:00:02.250"), "VTT timestamps use a dot separator:\n\(contents)")
        #expect(contents.contains("01:01:01.000 --> 01:01:02.500"))
        #expect(SubtitleExportFormat.vtt.fileExtension == "vtt")
    }

    // Int(Double) traps on NaN/infinity; one bad cue must never crash export.
    @Test func timestampFormattersNeverTrapOnBadValues() {
        #expect(SubtitleWriter.formatSRTTimestamp(.infinity) == "99:59:59,999")
        #expect(SubtitleWriter.formatSRTTimestamp(.nan) == "00:00:00,000")
        #expect(SubtitleWriter.formatSRTTimestamp(-3) == "00:00:00,000")
        #expect(SubtitleWriter.formatDisplayTimestamp(.nan) == "00:00:00")
        #expect(SubtitleWriter.formatDisplayTimestamp(-.infinity) == "00:00:00")
    }
}
