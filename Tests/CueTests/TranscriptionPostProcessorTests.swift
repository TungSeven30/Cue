import Foundation
import Testing
@testable import Cue

struct TranscriptionPostProcessorTests {
    // A zero-duration segment whose successor starts at (or before) the same
    // time must still be extended to a readable duration; a brief overlap
    // beats a cue that displays for 0 seconds.
    @Test func zeroDurationSegmentWithOverlappingNextIsRepaired() {
        let segments = [
            TranscriptionSegment(id: 1, start: 10.0, end: 10.0, text: "One"),
            TranscriptionSegment(id: 2, start: 10.0, end: 12.0, text: "Two"),
        ]
        let repaired = TranscriptionPostProcessor.repairInvalidTimings(segments)
        #expect(repaired[0].end - repaired[0].start > 0.2, "Zero-duration cue was left unrepaired")
    }

    @Test func zeroDurationSegmentIsCappedByNextSegmentWhenRoomExists() {
        let segments = [
            TranscriptionSegment(id: 1, start: 10.0, end: 10.05, text: "One"),
            TranscriptionSegment(id: 2, start: 10.5, end: 12.0, text: "Two"),
        ]
        let repaired = TranscriptionPostProcessor.repairInvalidTimings(segments)
        #expect(repaired[0].end <= 10.5, "Repair should not push past the next segment when there is room")
        #expect(repaired[0].end > repaired[0].start)
    }

    // The native whisper.cpp path must run through the SAME cleanup pipeline
    // as the Python backends: segments produced by WhisperCppEngine.mapSegment
    // fed to TranscriptionPostProcessor.clean get whitespace normalization,
    // duplicate collapsing, and empty-segment removal identically.
    @Test func nativeEngineSegmentsRunThroughSharedCleanupPipeline() {
        let raw = [
            WhisperCppEngine.mapSegment(index: 0, t0: 0, t1: 150, text: "  Hello   world  "),
            WhisperCppEngine.mapSegment(index: 1, t0: 155, t1: 300, text: "Hello world"),
            WhisperCppEngine.mapSegment(index: 2, t0: 305, t1: 305, text: "   "),
        ]
        let snapshot = TranscriptionSettingsSnapshot(
            sourceLanguage: "auto",
            whisperModel: ModelDownloader.defaultModel,
            whisperBackendRawValue: WhisperBackend.native.rawValue,
            preprocessAudio: false,
            vadFilter: true,
            removeEmptySegments: true,
            removeRepeatedText: true,
            mergeShortSegments: false,
            minSegmentDuration: 0.7,
            maxMergeGap: 0.45,
            beamSize: 5,
            bestOf: 5,
            temperature: 0,
            noSpeechThreshold: 0.6
        )

        let cleaned = TranscriptionPostProcessor.clean(raw, settings: snapshot)

        // Whitespace normalized, adjacent duplicate merged, empty dropped.
        #expect(cleaned.count == 1)
        #expect(cleaned[0].text == "Hello world")
        #expect(cleaned[0].id == 1)
        #expect(cleaned[0].start == 0.0)
        #expect(cleaned[0].end == 3.0)
    }
}
