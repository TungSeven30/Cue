import AVKit
import Foundation
import Testing
@testable import Cue

@MainActor
struct PlayerControllerTests {
    @Test func cueMembershipUsesExactHalfOpenBoundaries() {
        let controller = PlayerController()
        controller.updateSegments([TranscriptionSegment(id: 1, start: 1, end: 2, text: "Việt Nam")])
        for time in [0, 0.849, 0.85, 0.999, 1, 1.5, 1.999, 2, 2.24, 2.25] {
            controller.seek(to: time)
            let expected: Int? = (1..<2).contains(time) ? 1 : nil
            #expect(controller.activeSegmentID == expected, "time=\(time)")
            #expect(controller.overlayText == (expected == nil ? "" : "Việt Nam"))
        }
    }

    @Test func nestedOverlapRecoversTheStillActiveCueAndReseeks() {
        let controller = PlayerController()
        controller.updateSegments([
            TranscriptionSegment(id: 2, start: 2, end: 3, text: "Short"),
            TranscriptionSegment(id: 1, start: 0, end: 10, text: "Long"),
        ])
        for (time, expected) in [(1.0, 1), (2.5, 2), (4, 1), (10, 0), (2, 2), (0, 1)] {
            controller.seek(to: time)
            #expect(controller.activeSegmentID == (expected == 0 ? nil : expected))
        }
        controller.updateSegments([])
        #expect(controller.activeSegmentID == nil)
        #expect(controller.overlayText.isEmpty)
    }

    @Test func zeroLengthCuesAndNonfiniteSeeksDoNotReplaceVisibleText() {
        let controller = PlayerController()
        controller.updateSegments([
            TranscriptionSegment(id: 1, start: 0, end: 10, text: "Visible"),
            TranscriptionSegment(id: 2, start: 2, end: 2, text: "Empty"),
        ])
        controller.seek(to: 2)
        #expect(controller.activeSegmentID == 1)
        controller.seek(to: .nan)
        controller.seek(to: .infinity)
        #expect(controller.overlayText == "Visible")
    }
}
