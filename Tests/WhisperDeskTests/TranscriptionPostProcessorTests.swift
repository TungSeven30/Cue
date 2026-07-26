import Foundation
import Testing
@testable import WhisperDesk

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
}
