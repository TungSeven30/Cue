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
            TranscriptionSegment(id: 1, start: 0, end: 2_400, text: "First forty minutes.")
        ]
        let newlyCollected = [
            TranscriptionSegment(id: 2, start: 2_400, end: 2_500, text: "After resume.")
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

    private var settings: TranscriptionSettingsSnapshot {
        TranscriptionSettingsSnapshot(
            sourceLanguage: "auto", qwenContext: "", whisperModel: "ggml-large-v3-turbo-q5_0.bin",
            whisperBackendRawValue: "whisper-cpp", preprocessAudio: false,
            vadFilter: false, removeEmptySegments: true, removeRepeatedText: true,
            mergeShortSegments: true, minSegmentDuration: 0.7, maxMergeGap: 0.45,
            beamSize: 5, bestOf: 5, temperature: 0, noSpeechThreshold: 0.6
        )
    }

    // Saved partials keep their streamed ids while the resumed run's raw
    // segments start at 1 again; cleaning them as one transcript is what
    // keeps ids unique — duplicates break translation lookups (which key by
    // id) and SRT cue numbering.
    @Test func resumedTranscriptHasUniqueSequentialIDs() {
        let partials = [
            TranscriptionSegment(id: 1, start: 0, end: 4, text: "Saved one."),
            TranscriptionSegment(id: 2, start: 4, end: 9, text: "Saved two."),
        ]
        let newlyCollected = [
            TranscriptionSegment(id: 1, start: 9, end: 13, text: "Resumed one."),
            TranscriptionSegment(id: 2, start: 13, end: 18, text: "Resumed two."),
        ]
        let combined = TranscriptionPostProcessor.cleanResumed(
            partials: partials, newlyCollected: newlyCollected, settings: settings)
        #expect(combined.map(\.id) == [1, 2, 3, 4])
        #expect(combined.map(\.text) == ["Saved one.", "Saved two.", "Resumed one.", "Resumed two."])
    }

    // A saved cue ending exactly on the chunk boundary belongs to the
    // finished chunk and must survive the merge.
    @Test func mergeKeepsCueEndingExactlyAtTheResumeFrontier() {
        let existing = [TranscriptionSegment(id: 1, start: 0, end: 2_400, text: "First forty minutes.")]
        let batch = [TranscriptionSegment(id: 2, start: 2_400, end: 2_500, text: "After resume.")]
        let merged = TranscriptionChunkPlanner.mergePartialSegments(existing: existing, batch: batch)
        #expect(merged.map(\.text) == ["First forty minutes.", "After resume."])
    }

    // The engine feeds normalized [-1, 1] floats; the silence threshold must
    // be in the same units or every frame reads as silent and cuts land in
    // the middle of speech instead of inside pauses. Mirrors
    // script/test_chunk_planning.py's synthetic tone/silence pattern.
    @Test func speechChunksAreCutOnlyInsideSilence() {
        let rate = 16_000
        var samples: [Float] = []
        var silences: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for _ in 0..<8 {
            samples += tone(seconds: 100, rate: rate)
            cursor += 100
            samples += [Float](repeating: 0, count: 2 * rate)
            silences.append((cursor, cursor + 2))
            cursor += 2
        }
        let chunks = TranscriptionChunkPlanner.planSpeechChunks(
            samples: samples, sampleRate: rate, targetChunk: 150, maxChunk: 300)
        #expect(chunks.count >= 2)
        #expect(chunks.first?.start == 0)
        #expect(abs((chunks.last?.end ?? 0) - Double(samples.count) / Double(rate)) < 0.001)
        for (current, following) in zip(chunks, chunks.dropFirst()) {
            #expect(current.end == following.start)
        }
        for chunk in chunks.dropLast() {
            #expect(
                silences.contains { $0.start <= chunk.end && chunk.end <= $0.end },
                "cut at \(chunk.end)s did not land in silence")
        }
    }

    @Test func continuousSpeechIsNeverCutMidWord() {
        let samples = tone(seconds: 700, rate: 16_000)
        let chunks = TranscriptionChunkPlanner.planSpeechChunks(samples: samples, sampleRate: 16_000)
        #expect(chunks.count == 1)
    }

    private func tone(seconds: Double, rate: Int, amplitude: Float = 0.25) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            amplitude * Float(sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
        }
    }
}
