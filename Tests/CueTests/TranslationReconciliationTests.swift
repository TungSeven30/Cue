import Testing
@testable import Cue

@Suite struct TranslationReconciliationTests {
    @Test func remapsExactMatchesOntoFinalIDs() {
        let streamed = [
            TranscriptionSegment(id: 5, start: 0.0, end: 2.0, text: "hola"),
            TranscriptionSegment(id: 6, start: 2.0, end: 4.0, text: "mundo"),
        ]
        let partials = [TranscriptionSegment(id: 5, start: 0.0, end: 2.0, text: "hello")]
        // Final pass renumbered ids but kept the first segment intact.
        let final = [
            TranscriptionSegment(id: 1, start: 0.0, end: 2.0, text: "hola"),
            TranscriptionSegment(id: 2, start: 2.0, end: 4.0, text: "mundo"),
        ]
        let remapped = TranslationReconciliation.remap(partials: partials, streamed: streamed, final: final)
        #expect(remapped == [TranscriptionSegment(id: 1, start: 0.0, end: 2.0, text: "hello")])
    }

    @Test func dropsPartialsWhoseSegmentsWereMerged() {
        let streamed = [
            TranscriptionSegment(id: 1, start: 0.0, end: 1.0, text: "a"),
            TranscriptionSegment(id: 2, start: 1.0, end: 2.0, text: "b"),
        ]
        let partials = [
            TranscriptionSegment(id: 1, start: 0.0, end: 1.0, text: "A"),
            TranscriptionSegment(id: 2, start: 1.0, end: 2.0, text: "B"),
        ]
        // Final pass merged the two into one segment: no exact match survives.
        let final = [TranscriptionSegment(id: 1, start: 0.0, end: 2.0, text: "a b")]
        let remapped = TranslationReconciliation.remap(partials: partials, streamed: streamed, final: final)
        #expect(remapped.isEmpty)
    }

    @Test func emptyInputsProduceEmptyOutput() {
        #expect(TranslationReconciliation.remap(partials: [], streamed: [], final: []).isEmpty)
    }
}
