import Testing
@testable import Cue

struct TranslationBatchPlannerTests {
    private func segment(_ id: Int, text: String = "line") -> TranscriptionSegment {
        TranscriptionSegment(id: id, start: Double(id), end: Double(id) + 1, text: text)
    }

    @Test func respectsTokenBudgetBeforeSegmentCap() {
        let long = String(repeating: "dialogue ", count: 1_000)
        let chunks = TranslationBatchPlanner.pendingChunks(
            [segment(1, text: long), segment(2, text: long)],
            translatedIDs: [],
            mode: .safer
        )
        #expect(chunks.map(\.count) == [1, 1])
    }

    @Test func treatsCJKConservatively() {
        let latin = TranslationBatchPlanner.estimatedTokens(in: String(repeating: "a", count: 40))
        let cjk = TranslationBatchPlanner.estimatedTokens(in: String(repeating: "日", count: 40))
        #expect(latin == 10)
        #expect(cjk == 40)
    }

    @Test func translatedRangesAreExcludedAndNeverBridged() {
        let chunks = TranslationBatchPlanner.pendingChunks(
            (1...6).map { segment($0) },
            translatedIDs: [2, 3, 5],
            mode: .balanced
        )
        #expect(chunks.map { $0.map(\.id) } == [[1], [4], [6]])
    }
}
