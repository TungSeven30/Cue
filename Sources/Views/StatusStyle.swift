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
