import Foundation
import Testing
@testable import Cue

struct TranscriptionResumeTests {
    @Test func pendingChunksSkipFullyCompletedRanges() {
        let chunks = [
            SpeechChunk(start: 0, end: 2_400),
            SpeechChunk(start: 2_400, end: 4_800),
            SpeechChunk(start: 4_800, end: 7_200),
        ]
        let pending = TranscriptionChunkPlanner.pendingChunks(chunks, resumeThrough: 2_400)
        #expect(pending.map(\.start) == [2_400, 4_800])
        #expect(pending.allSatisfy { $0.start >= 2_400 - 0.01 })
    }

    @Test func chunkRunnerSpyInvokesOnlyAfterResumeFrontier() {
        final class ChunkRunnerSpy: @unchecked Sendable {
            private(set) var invokedStarts: [Double] = []

            func run(planned: [SpeechChunk], resumeThrough: Double) {
                let pending = TranscriptionChunkPlanner.pendingChunks(planned, resumeThrough: resumeThrough)
                invokedStarts = pending.map(\.start)
            }
        }

        let spy = ChunkRunnerSpy()
        let fortyMinutes = 40.0 * 60.0
        let eightyMinutes = 80.0 * 60.0
        let planned = [
            SpeechChunk(start: 0, end: fortyMinutes),
            SpeechChunk(start: fortyMinutes, end: eightyMinutes),
            SpeechChunk(start: eightyMinutes, end: 7_200),
        ]
        spy.run(planned: planned, resumeThrough: fortyMinutes)

        #expect(spy.invokedStarts == [fortyMinutes, eightyMinutes])
        #expect(spy.invokedStarts.allSatisfy { $0 >= fortyMinutes - 0.01 })
    }

    @Test func midChunkResumeMergeIsIdempotent() {
        let existing = [
            TranscriptionSegment(id: 1, start: 0, end: 10, text: "Opening."),
            TranscriptionSegment(id: 2, start: 10, end: 85 * 60, text: "Partial chunk."),
        ]
        let batch = [
            TranscriptionSegment(id: 1, start: 0, end: 12, text: "Opening."),
            TranscriptionSegment(id: 2, start: 12, end: 90 * 60, text: "Full first chunk."),
        ]
        let merged = TranscriptionChunkPlanner.mergePartialSegments(existing: existing, batch: batch)
        #expect(merged.count == 2)
        #expect(merged.map(\.text) == batch.map(\.text))
        #expect(merged.allSatisfy { $0.end <= 90 * 60 + 0.01 })
    }

    @Test func combinedSegmentsIncludeSavedPartialsAndNewTail() {
        let partials = [
            TranscriptionSegment(id: 1, start: 0, end: 2_400, text: "First forty minutes."),
        ]
        let newlyCollected = [
            TranscriptionSegment(id: 2, start: 2_400, end: 2_500, text: "After resume."),
        ]
        let combined = TranscriptionChunkPlanner.combinedSegments(
            partials: partials,
            newlyCollected: newlyCollected
        )
        #expect(combined.count == 2)
        #expect(combined[0].text == "First forty minutes.")
        #expect(combined[1].text == "After resume.")
    }

    @Test func chunkCompleteEventDecodesFromPythonHelper() {
        let line = #"{"event":"chunk_complete","through":5400.0}"#
        guard case .chunkComplete(let through)? = TranscriptionStreamEvent.decode(line) else {
            Issue.record("Expected chunk_complete event")
            return
        }
        #expect(through == 5_400)
    }
}
