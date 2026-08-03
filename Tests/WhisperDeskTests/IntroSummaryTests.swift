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


struct IntroCueSplittingTests {
    @Test func shortSummaryStaysWhole() {
        #expect(SubtitleWriter.introCueTexts("A quiet town hides a secret.") == ["A quiet town hides a secret."])
    }

    @Test func longSummarySplitsOnSentenceBoundaries() {
        let sentence = "In a rain-soaked port town, a retired detective takes one last case."
        let summary = Array(repeating: sentence, count: 8).joined(separator: " ")
        let chunks = SubtitleWriter.introCueTexts(summary)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 220 })
        // Nothing lost, nothing reordered.
        #expect(chunks.joined(separator: " ") == summary)
        // Every chunk ends on a sentence boundary, not mid-sentence.
        #expect(chunks.allSatisfy { $0.hasSuffix("case.") })
    }

    @Test func multiCueIntroTimesSequentiallyAndRenumbers() {
        let sentence = "In a rain-soaked port town, a retired detective takes one last case."
        let summary = Array(repeating: sentence, count: 8).joined(separator: " ")
        let dialogue = [TranscriptionSegment(id: 1, start: 2.0, end: 4.0, text: "Hello.")]
        let result = SubtitleWriter.segmentsPrependingIntro(summary, to: dialogue)
        let introCount = result.count - dialogue.count
        #expect(introCount > 1)
        // Sequential, non-overlapping intro cues starting at zero.
        #expect(result[0].start == 0)
        for index in 1..<introCount {
            #expect(result[index].start == result[index - 1].end)
        }
        // Ids re-sequenced across the whole file.
        #expect(result.map(\.id) == Array(1...result.count))
        // Dialogue timing untouched.
        #expect(result.last?.start == 2.0)
    }

    @Test func detailedPromptRaisesTheBudget() {
        let brief = TranslationService.summaryInstructions(detail: .brief, language: "English")
        let detailed = TranslationService.summaryInstructions(detail: .detailed, language: "English")
        #expect(brief.contains("280"))
        #expect(detailed.contains("900"))
        #expect(detailed.contains("5-8 sentences"))
        // Both stay spoiler-safe and JSON-shaped.
        for prompt in [brief, detailed] {
            #expect(prompt.contains("Do not reveal"))
            #expect(prompt.contains(#"{"summary":"..."}"#))
        }
    }
}
