import AppKit
import SwiftUI

/// Native stepper provides a focus ring and a keyboard/VoiceOver alternative
/// to the preview's drag handle. Height remains stored in the existing key.
struct PreviewHeightControl: NSViewRepresentable {
    @Binding var height: Double

    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(640, max(140, value)) : 280
    }

    func makeNSView(context: Context) -> Control { Control() }

    func updateNSView(_ control: Control, context: Context) {
        control.doubleValue = Self.clamped(height)
        control.onChange = { height = $0 }
    }

    final class Control: NSStepper {
        var onChange: ((Double) -> Void)?

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 28))
            minValue = 140
            maxValue = 640
            increment = 20
            valueWraps = false
            doubleValue = 280
            target = self
            action = #selector(valueChanged)
            setAccessibilityElement(true)
            setAccessibilityRole(.incrementor)
            setAccessibilityLabel("Video preview height")
            toolTip = "Resize the video preview. Use Up or Down when focused."
        }

        required init?(coder: NSCoder) { nil }

        @objc private func valueChanged() { onChange?(doubleValue) }

        private func adjust(by delta: Double) {
            doubleValue = PreviewHeightControl.clamped(doubleValue + delta)
            valueChanged()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }

        override func accessibilityValue() -> Any? { doubleValue }
        override func accessibilityPerformIncrement() -> Bool { adjust(by: increment); return true }
        override func accessibilityPerformDecrement() -> Bool { adjust(by: -increment); return true }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            // AppKit steppers do not retain keyboard focus after a mouse click
            // by default; make the advertised arrow-key alternative reachable.
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: adjust(by: increment)
            case 125: adjust(by: -increment)
            default: super.keyDown(with: event)
            }
        }
    }
}

enum TranscriptMotion {
    static func followTransaction(reduceMotion: Bool) -> Transaction {
        var transaction = Transaction(animation: reduceMotion ? nil : .easeInOut(duration: 0.2))
        transaction.disablesAnimations = reduceMotion
        return transaction
    }
}
