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

    // Conversion and OCR tools emit separator lines carrying a space or tab.
    // Splitting on "\n\n" alone merges the neighbouring cues into one whose
    // text swallows the next cue's index and timestamp — and because write-back
    // re-serializes what was parsed, the user's first edit would save that
    // corruption into their own file.
    @Test func splitsCuesOnWhitespaceBearingSeparatorLines() throws {
        let srt =
            "1\n00:00:01,000 --> 00:00:02,000\nA\n \n"
            + "2\n00:00:03,000 --> 00:00:04,000\nB\n\t\n"
            + "3\n00:00:05,000 --> 00:00:06,000\nC"
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.map(\.text) == ["A", "B", "C"])
        #expect(segments.map(\.start) == [1.0, 3.0, 5.0])
    }

    // The dialog shown by a failed Load Subtitles… prints localizedDescription,
    // so every case must read as an explanation rather than "error 2".
    @Test func readErrorsCarryAReadableDescription() {
        let messages = [
            SubtitleReader.ReadError.unreadable,
            .unsupportedFormat("ass"),
            .noCues,
            .tooLarge(30 * 1024 * 1024),
        ].map(\.localizedDescription)
        #expect(messages.allSatisfy { !$0.contains("couldn't be completed") })
        #expect(messages.contains { $0.contains("SRT") })
        #expect(messages.contains { $0.contains("no subtitle cues") })
        #expect(messages.contains { $0.contains("MB") })
    }

    // The cap exists so a mislabeled video is refused rather than read into
    // memory; the parameter keeps the test off a 20 MB fixture.
    @Test func fileOverTheSizeCapThrowsTooLarge() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-reader-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8).write(to: url)

        #expect(throws: SubtitleReader.ReadError.tooLarge(38)) {
            try SubtitleReader.parse(contentsOf: url, maximumSize: 8)
        }
        // The same file passes with the cap it actually fits under, so the
        // throw above is the cap and not a parse failure.
        #expect(try SubtitleReader.parse(contentsOf: url, maximumSize: 1024).count == 1)
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

    // The UTF-16 BOM check must come before UTF-8 to stop Foundation's lenient
    // .utf16 decoder from claiming non-UTF-16 bytes and producing garbage. This
    // test exercises that BOM-sniff branch.
    @Test func decodesUTF16WithBOM() throws {
        let text = "Hello\nWorld"

        // UTF-16 Little-Endian with BOM (FF FE).
        var utf16le = Data([0xFF, 0xFE])  // LE BOM
        utf16le.append(try #require(text.data(using: .utf16LittleEndian)))
        let decodedLE = try #require(SubtitleReader.decode(utf16le))
        #expect(decodedLE == text)

        // UTF-16 Big-Endian with BOM (FE FF).
        var utf16be = Data([0xFE, 0xFF])  // BE BOM
        utf16be.append(try #require(text.data(using: .utf16BigEndian)))
        let decodedBE = try #require(SubtitleReader.decode(utf16be))
        #expect(decodedBE == text)
    }

    // Verify that Latin-1 bytes without a UTF-16 BOM fall through to
    // Windows-1252 decoding rather than being misinterpreted as garbage
    // UTF-16. This guards against the lenient .utf16 decoder.
    @Test func latin1WithoutBOMDecodesAsWindows1252NotUTF16Garbage() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nCafé\n"
        let latin1Data = try #require(srt.data(using: .windowsCP1252))

        // Confirm no UTF-16 BOM is present.
        guard latin1Data.count >= 2 else { return }
        let first = latin1Data[latin1Data.startIndex]
        let second = latin1Data[latin1Data.index(after: latin1Data.startIndex)]
        #expect((first, second) != (0xFF, 0xFE))
        #expect((first, second) != (0xFE, 0xFF))

        // Decode should succeed and contain the accented character, not garbage.
        let decoded = try #require(SubtitleReader.decode(latin1Data))
        #expect(decoded.contains("Café"))
    }

    // FFmpeg and players respect inline markup (`<i>`, `{\an8}`, etc.);
    // it must survive parsing unchanged.
    @Test func preservesInlineMarkupVerbatim() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,000
            <i>Italics</i> and {\\an8}position
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.count == 1)
        #expect(segments[0].text == "<i>Italics</i> and {\\an8}position")
    }
}
