import Foundation

struct TranscriptionJob: Codable, Identifiable, Hashable {
    var id: UUID
    var sourcePath: String
    var createdAt: Date
    var updatedAt: Date
    var status: JobStatus
    var progress: JobProgress
    var settings: JobSettingsSnapshot
    var transcriptSegments: [TranscriptionSegment]
    var translatedSegments: [TranscriptionSegment]
    var log: String

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    var title: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    @MainActor
    init(sourceURL: URL, settings: AppSettingsStore) {
        let now = Date()
        self.id = UUID()
        self.sourcePath = sourceURL.path
        self.createdAt = now
        self.updatedAt = now
        self.status = .idle
        self.progress = .idle
        self.settings = JobSettingsSnapshot(settings: settings)
        self.transcriptSegments = []
        self.translatedSegments = []
        self.log = "Choose a video to begin.\n"
    }
}

struct JobSettingsSnapshot: Codable, Hashable {
    var sourceLanguage: String
    var whisperModel: String
    var whisperBackend: WhisperBackend
    var openAIModel: String

    @MainActor
    init(settings: AppSettingsStore) {
        sourceLanguage = settings.sourceLanguage
        whisperModel = settings.whisperModel
        whisperBackend = settings.whisperBackend
        openAIModel = settings.openAIModel
    }
}
