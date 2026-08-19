import Foundation
import Testing
@testable import Cue

struct SubtitleReaderTests {
    @Test func readsAPlainSRT() {
        let srt = """
            1
            00:00:01,000 --> 00:00:03,500
            First line

            2
            00:01:02,250 --> 00:01:04,000
            Second line
            wrapped onto two rows
            """
        let segments = SubtitleReader.parse(srt)
        #expect(segments.count == 2)
        #expect(segments[0].start == 1.0)
        #expect(segments[0].end == 3.5)
        #expect(segments[0].text == "First line")
        #expect(segments[1].start == 62.25)
        #expect(segments[1].text == "Second line\nwrapped onto two rows")
    }

    @Test func readsWebVTTIncludingItsHeaderAndCueSettings() {
        let vtt = """
            WEBVTT

            NOTE this block has no timing line

            1
            00:00:01.000 --> 00:00:03.500 align:start position:10%
            Hello

            00:04.000 --> 00:06.000
            Timestamp without an hours field
            """
        let segments = SubtitleReader.parse(vtt)
        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello")
        #expect(segments[0].end == 3.5)
        #expect(segments[1].start == 4.0)
        #expect(segments[1].end == 6.0)
    }

    // Every downstream stage matches translations to sources by id, so ids
    // are re-sequenced rather than trusted — a hand-edited file repeats them.
    @Test func idsAreResequencedFromOne() {
        let srt = """
            7
            00:00:01,000 --> 00:00:02,000
            A

            7
            00:00:02,000 --> 00:00:03,000
            B
            """
        let segments = SubtitleReader.parse(srt)
        #expect(segments.map(\.id) == [1, 2])
    }

    @Test func toleratesCRLFAndABOM() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nWindows line endings\r\n"
        let segments = SubtitleReader.parse(srt)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Windows line endings")
    }

    @Test func skipsBlocksWithoutUsableTiming() {
        let srt = """
            1
            00:00:01,000 --> not-a-timestamp
            Dropped

            2
            00:00:02,000 --> 00:00:03,000
            Kept
            """
        let segments = SubtitleReader.parse(srt)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Kept")
    }

    @Test func parsesTimestampsInBothPunctuations() {
        #expect(SubtitleReader.parseTimestamp("00:00:01,500") == 1.5)
        #expect(SubtitleReader.parseTimestamp("00:00:01.500") == 1.5)
        #expect(SubtitleReader.parseTimestamp("01:02:03,004") == 3723.004)
        #expect(SubtitleReader.parseTimestamp("02:03.500") == 123.5)
        #expect(SubtitleReader.parseTimestamp("garbage") == nil)
        #expect(SubtitleReader.parseTimestamp("") == nil)
        #expect(SubtitleReader.parseTimestamp("00:00:00:01") == nil)
    }

    @Test func readingAFileWithNoCuesIsAnError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.srt")
        try "WEBVTT\n\nnothing here\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            _ = try SubtitleReader.read(contentsOf: url)
        }
    }

    // The round trip the CLI actually relies on: a file Cue wrote must read
    // back with the same timings.
    @Test func roundTripsWhatSubtitleWriterProduces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = [
            TranscriptionSegment(id: 1, start: 0.5, end: 2.25, text: "Bonjour"),
            TranscriptionSegment(id: 2, start: 2.25, end: 4, text: "Ça va ?"),
        ]
        let url = directory.appendingPathComponent("round.srt")
        try SubtitleWriter.writeSRT(segments: original, to: url)
        let readBack = try SubtitleReader.read(contentsOf: url)

        #expect(readBack.count == original.count)
        for (left, right) in zip(readBack, original) {
            #expect(abs(left.start - right.start) < 0.001)
            #expect(abs(left.end - right.end) < 0.001)
            #expect(left.text == right.text)
        }
    }
}
