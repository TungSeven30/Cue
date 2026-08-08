import Testing
@testable import Cue

@Suite struct StreamCleanupTests {
    private var settings: TranscriptionSettingsSnapshot {
        // Build the same way TranscriptionService does; copy the field list
        // from the snapshot construction in TranscriptionService.transcribe.
        TranscriptionSettingsSnapshot(
            sourceLanguage: "auto", whisperModel: "ggml-large-v3-turbo-q5_0.bin",
            whisperBackendRawValue: "whisper-cpp", preprocessAudio: false,
            vadFilter: false, removeEmptySegments: true, removeRepeatedText: true,
            mergeShortSegments: true, minSegmentDuration: 1.0, maxMergeGap: 0.4,
            beamSize: 5, bestOf: 5, temperature: 0, noSpeechThreshold: 0.6
        )
    }

    @Test func preservesIDsAndNeverRenumbers() {
        let batch = [
            TranscriptionSegment(id: 41, start: 100.0, end: 101.5, text: "  hello  "),
            TranscriptionSegment(id: 42, start: 101.5, end: 101.5, text: "world"),
        ]
        let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: settings)
        #expect(cleaned.map(\.id) == [41, 42])
        #expect(cleaned[0].text == "hello")
        #expect(cleaned[1].end > cleaned[1].start)  // zero-duration repaired
    }

    @Test func dropsEmptySegments() {
        let batch = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "   "),
            TranscriptionSegment(id: 2, start: 1, end: 2, text: "keep"),
        ]
        let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: settings)
        #expect(cleaned.map(\.id) == [2])
    }

    @Test func isIdempotent() {
        let batch = [
            TranscriptionSegment(id: 1, start: 0, end: 0.05, text: " a a a a a a "),
            TranscriptionSegment(id: 2, start: 3, end: 3, text: "b"),
        ]
        let once = TranscriptionPostProcessor.cleanWindow(batch, settings: settings)
        let twice = TranscriptionPostProcessor.cleanWindow(once, settings: settings)
        #expect(once == twice)
    }

    @Test func isIdempotentWithMultiGranularityRepeats() {
        // Input has repeats at multiple granularities: "a b" repeats 3 times, then "c" repeats.
        // Single pass might collapse "a b", but second pass should collapse "c c".
        // After this test, both passes should be identical (fixed point).
        let batch = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "a b a b a b c c")
        ]
        let once = TranscriptionPostProcessor.cleanWindow(batch, settings: settings)
        let twice = TranscriptionPostProcessor.cleanWindow(once, settings: settings)
        #expect(once == twice)
    }

    @Test func laterBatchesDoNotAlterEarlierOutput() {
        let a = [TranscriptionSegment(id: 1, start: 0, end: 2, text: "first")]
        let b = [TranscriptionSegment(id: 2, start: 2, end: 4, text: "second")]
        let aCleaned = TranscriptionPostProcessor.cleanWindow(a, settings: settings)
        _ = TranscriptionPostProcessor.cleanWindow(b, settings: settings)
        #expect(TranscriptionPostProcessor.cleanWindow(a, settings: settings) == aCleaned)
    }
}
