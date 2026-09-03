import AppKit
import SwiftUI

extension JobStatus {
    /// Accent color used alongside `systemImage` in lists and headers.
    var tint: Color {
        switch self {
        case .idle:
            return .secondary
        case .queued:
            return .indigo
        case .transcribing, .translating, .burningIn:
            return .blue
        case .transcriptionComplete:
            return .teal
        case .translationComplete:
            return .green
        case .canceled:
            return .orange
        case .failed:
            return .red
        }
    }
}

extension DiagnosticState {
    var tint: Color {
        switch self {
        case .passed:
            return .green
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }

    var systemImage: String {
        switch self {
        case .passed:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }
}

/// A compact copy button that provides immediate visual confirmation with a checkmark.
struct CopyFeedbackButton: View {
    let text: String
    var label: String = "Copy"
    var icon: String = "doc.on.doc"
    var helpText: String = "Copy to clipboard"
    var showsLabel: Bool = true
    @State private var hasCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hasCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                hasCopied = false
            }
        } label: {
            if showsLabel {
                Label(hasCopied ? "Copied" : label, systemImage: hasCopied ? "checkmark" : icon)
                    .foregroundStyle(hasCopied ? Color.green : Color.primary)
            } else {
                Image(systemName: hasCopied ? "checkmark" : icon)
                    .foregroundStyle(hasCopied ? Color.green : Color.secondary)
            }
        }
        .help(hasCopied ? "Copied to clipboard" : helpText)
    }
}
