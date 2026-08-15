import Foundation
import Testing

@testable import Cue

struct SubtitleReaderTests {
    @Test func parsesStandardSRT() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,500
            Hello there

            2
            00:00:03,000 --> 00:00:04,000
            Second cue
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.count == 2)
        #expect(segments[0].start == 1.0)
        #expect(segments[0].end == 2.5)
        #expect(segments[0].text == "Hello there")
        #expect(segments[1].id == 2)
    }

    // Cue ids double as the join key for bilingual export and translation
    // reconciliation, so the file's own indices must never be trusted.
    @Test func renumbersDuplicateAndNonMonotonicIndices() throws {
        let srt = """
            7
            00:00:01,000 --> 00:00:02,000
            First

            7
            00:00:02,000 --> 00:00:03,000
            Second

            3
            00:00:03,000 --> 00:00:04,000
            Third
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.map(\.id) == [1, 2, 3])
        #expect(segments.map(\.text) == ["First", "Second", "Third"])
    }

    @Test func acceptsDotSeparatorAndMissingHours() {
        #expect(SubtitleReader.parseTimestamp("00:00:01,500") == 1.5)
        #expect(SubtitleReader.parseTimestamp("00:00:01.500") == 1.5)
        #expect(SubtitleReader.parseTimestamp("01:02.500") == 62.5)
        #expect(SubtitleReader.parseTimestamp("01:01:01,000") == 3661.0)
        #expect(SubtitleReader.parseTimestamp("nonsense") == nil)
    }

    @Test func parsesVTTSkippingHeaderAndNotes() throws {
        let vtt = """
            WEBVTT

            NOTE this is a comment

            cue-1
            00:00:01.000 --> 00:00:02.000 align:start position:10%
            Hello
            """
        let segments = try SubtitleReader.parse(vtt, format: .vtt)
        #expect(segments.count == 1)
        #expect(segments[0].start == 1.0)
        #expect(segments[0].end == 2.0)
        #expect(segments[0].text == "Hello")
    }

    // Real files carry junk tails; one bad block must not lose the file.
    @Test func skipsMalformedBlockAndKeepsTheRest() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,000
            Good

            garbage with no timing at all

            2
            00:00:03,000 --> 00:00:04,000
            Also good
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.map(\.text) == ["Good", "Also good"])
    }

    @Test func arrowInsideCueTextStaysWithTheCue() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,000
            step one --> step two
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.count == 1)
        #expect(segments[0].text == "step one --> step two")
    }

    @Test func emptyFileThrowsNoCues() {
        #expect(throws: SubtitleReader.ReadError.noCues) {
            try SubtitleReader.parse("\n\n", format: .srt)
        }
    }

    @Test func decodesLatin1AndStripsBOM() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nCafé\n"
        let latin1 = try #require(srt.data(using: .windowsCP1252))
        let decoded = try #require(SubtitleReader.decode(latin1))
        #expect(decoded.contains("Café"))

        let withBOM = try #require(("\u{FEFF}" + srt).data(using: .utf8))
        let strippedText = try #require(SubtitleReader.decode(withBOM))
        #expect(strippedText.hasPrefix("1"))
    }

    @Test func rejectsUnsupportedExtension() {
        let url = URL(filePath: "/tmp/subs.ass", directoryHint: .notDirectory)
        #expect(throws: SubtitleReader.ReadError.unsupportedFormat("ass")) {
            try SubtitleReader.parse(contentsOf: url)
        }
    }

    // Guards both sides of the writer/reader pair against future drift, the
    // same tactic the repo uses for the generated Python backend script.
    @Test func roundTripsThroughSubtitleWriter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = [
            TranscriptionSegment(id: 1, start: 0.5, end: 2.25, text: "Hello"),
            TranscriptionSegment(id: 2, start: 3661.0, end: 3662.5, text: "World"),
        ]
        for format in [SubtitleExportFormat.srt, .vtt] {
            let url = dir.appendingPathComponent("round.\(format.fileExtension)")
            try SubtitleWriter.write(segments: original, format: format, to: url)
            let parsed = try SubtitleReader.parse(contentsOf: url)
            #expect(parsed == original, "\(format.label) round trip changed the segments")
        }
    }
}
