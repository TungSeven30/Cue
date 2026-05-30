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
