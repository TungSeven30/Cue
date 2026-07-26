import Foundation
import Testing
@testable import WhisperDesk

struct IntroSummaryTests {
    private let segments = [
        TranscriptionSegment(id: 1, start: 12.0, end: 14.0, text: "First line"),
        TranscriptionSegment(id: 2, start: 15.0, end: 17.0, text: "Second line"),
    ]

    @Test func nilOrEmptySummaryLeavesSegmentsUntouched() {
        #expect(SubtitleWriter.segmentsPrependingIntro(nil, to: segments) == segments)
        #expect(SubtitleWriter.segmentsPrependingIntro("   \n", to: segments) == segments)
    }

    @Test func introEndsBeforeFirstDialogueCappedAtTen() {
        let result = SubtitleWriter.segmentsPrependingIntro("A summary.", to: segments)
        #expect(result.count == 3)
        #expect(result[0].start == 0)
        // First dialogue at 12s: the intro is capped at 10s.
        #expect(result[0].end == 10.0)
        #expect(result[0].text == "A summary.")
    }

    @Test func introEndsAtFirstDialogueWhenWithinCap() {
        let early = [TranscriptionSegment(id: 1, start: 6.0, end: 8.0, text: "Hi")]
        let result = SubtitleWriter.segmentsPrependingIntro("A summary.", to: early)
        #expect(result[0].end == 6.0)
    }

    // A fast-starting film still gets a readable intro: minimum 3 seconds,
    // briefly overlapping the first dialogue.
    @Test func introKeepsMinimumThreeSecondsWhenDialogueStartsImmediately() {
        let immediate = [TranscriptionSegment(id: 1, start: 0.5, end: 2.0, text: "Hi")]
        let result = SubtitleWriter.segmentsPrependingIntro("A summary.", to: immediate)
        #expect(result[0].end == 3.0)
    }

    @Test func introAloneWhenNoSegments() {
        let result = SubtitleWriter.segmentsPrependingIntro("A summary.", to: [])
        #expect(result.count == 1)
        #expect(result[0].start == 0)
        #expect(result[0].end == 8.0)
    }

    @Test func cueNumbersAreSequentialAfterInsertion() {
        let result = SubtitleWriter.segmentsPrependingIntro("A summary.", to: segments)
        #expect(result.map(\.id) == [1, 2, 3])
        #expect(result[1].text == "First line")
        #expect(result[2].text == "Second line")
    }

    @Test func parseSummaryExtractsAndTrims() throws {
        let raw = """
        ```json
        {"summary": "  In 1960s Saigon, a young chef opens a noodle stall.  "}
        ```
        """
        let summary = try TranslationService.parseSummary(from: raw)
        #expect(summary == "In 1960s Saigon, a young chef opens a noodle stall.")
    }

    @Test func parseSummaryRejectsEmptySummary() {
        do {
            _ = try TranslationService.parseSummary(from: #"{"summary": "   "}"#)
            Issue.record("Expected an error for an empty summary")
        } catch {}
    }
}
