import Foundation

enum JobStatus: String, Codable, CaseIterable {
    case idle
    case transcribing
    case transcriptionComplete
    case translating
    case translationComplete
    case canceled
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .transcribing:
            return "Transcribing"
        case .transcriptionComplete:
            return "Transcription complete"
        case .translating:
            return "Translating"
        case .translationComplete:
            return "Translation complete"
        case .canceled:
            return "Canceled"
        case .failed:
            return "Failed"
        }
    }

    /// SF Symbol used to represent the status in lists and headers.
    var systemImage: String {
        switch self {
        case .idle:
            return "circle.dashed"
        case .transcribing:
            return "waveform"
        case .transcriptionComplete:
            return "text.alignleft"
        case .translating:
            return "character.bubble"
        case .translationComplete:
            return "checkmark.seal.fill"
        case .canceled:
            return "stop.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum JobStage: String, Codable, Hashable {
    case queued
    case preflight
    case extractingAudio
    case loadingModel
    case transcribing
    case translating
    case complete
    case failed
    case canceled

    var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .preflight:
            return "Checking setup"
        case .extractingAudio:
            return "Extracting audio"
        case .loadingModel:
            return "Loading model"
        case .transcribing:
            return "Transcribing"
        case .translating:
            return "Translating"
        case .complete:
            return "Complete"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        }
    }
}

struct JobProgress: Codable, Hashable {
    var stage: JobStage
    var detail: String
    var fraction: Double?

    static let idle = JobProgress(stage: .queued, detail: "Ready", fraction: nil)
}
