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

        let cues = contents
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
}
