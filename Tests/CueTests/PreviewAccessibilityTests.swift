import AppKit
import SwiftUI
import Testing
@testable import Cue

@MainActor
struct PreviewAccessibilityTests {
    @Test func nativeResizeControlSupportsVoiceOverAndKeyboard() throws {
        _ = NSApplication.shared
        let control = PreviewHeightControl.Control()
        var changes: [Double] = []
        control.onChange = { changes.append($0) }
        #expect(control.accessibilityRole() == .incrementor)
        #expect(control.accessibilityLabel() == "Video preview height")
        #expect(control.acceptsFirstResponder)
        #expect(control.accessibilityPerformIncrement())
        #expect(control.doubleValue == 300)
        #expect(control.accessibilityPerformDecrement())
        #expect(control.doubleValue == 280)
        let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        control.keyDown(with: up)
        #expect(control.doubleValue == 300)
        #expect(changes == [300, 280, 300])
        #expect(control.frame.width >= 20 && control.frame.height >= 20)
        for _ in 0..<100 { _ = control.accessibilityPerformIncrement() }
        #expect(control.doubleValue == 640)
        for _ in 0..<100 { _ = control.accessibilityPerformDecrement() }
        #expect(control.doubleValue == 140)
    }

    @Test func corruptSavedHeightCannotBecomeInvalidLayout() {
        #expect(PreviewHeightControl.clamped(.nan) == 280)
        #expect(PreviewHeightControl.clamped(.infinity) == 280)
        #expect(PreviewHeightControl.clamped(-1) == 140)
        #expect(PreviewHeightControl.clamped(900) == 640)
        #expect(PreviewHeightControl.clamped(321) == 321)
    }

    @Test func reducedMotionDisablesInheritedFollowAnimations() {
        let reduced = TranscriptMotion.followTransaction(reduceMotion: true)
        #expect(reduced.animation == nil)
        #expect(reduced.disablesAnimations)
        let normal = TranscriptMotion.followTransaction(reduceMotion: false)
        #expect(normal.animation != nil)
        #expect(!normal.disablesAnimations)
    }
}
