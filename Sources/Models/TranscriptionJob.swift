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
    var partialTranslatedSegments: [TranscriptionSegment]
    var sourceFingerprint: String
    var log: String
    /// Spoiler-free intro generated from the subtitles; prepended as the
    /// first cue of SRT/VTT exports when present.
    var summary: String?
    /// Per-job settings overrides; nil fields inherit globals at run time.
    var overrides: JobSettingsOverrides
    /// How this job entered the app (manual add vs. watch-folder ingest).
    var origin: JobOrigin
    /// Queue/list position; lower runs and displays first.
    var orderIndex: Double

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
        self.partialTranslatedSegments = []
        self.sourceFingerprint = Self.fingerprint(for: sourceURL)
        self.log = "Choose a video to begin.\n"
        self.summary = nil
        self.overrides = JobSettingsOverrides()
        self.origin = .manual
        self.orderIndex = -now.timeIntervalSince1970
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        status = try container.decode(JobStatus.self, forKey: .status)
        progress = try container.decode(JobProgress.self, forKey: .progress)
        settings = try container.decode(JobSettingsSnapshot.self, forKey: .settings)
        transcriptSegments = try container.decode([TranscriptionSegment].self, forKey: .transcriptSegments)
        translatedSegments = try container.decode([TranscriptionSegment].self, forKey: .translatedSegments)
        partialTranslatedSegments = try container.decodeIfPresent([TranscriptionSegment].self, forKey: .partialTranslatedSegments) ?? []
        sourceFingerprint = try container.decodeIfPresent(String.self, forKey: .sourceFingerprint) ?? Self.fingerprint(for: URL(fileURLWithPath: sourcePath))
        log = try container.decode(String.self, forKey: .log)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        overrides = try container.decodeIfPresent(JobSettingsOverrides.self, forKey: .overrides) ?? JobSettingsOverrides()
        origin = try container.decodeIfPresent(JobOrigin.self, forKey: .origin) ?? .manual
        orderIndex = try container.decodeIfPresent(Double.self, forKey: .orderIndex) ?? -createdAt.timeIntervalSince1970
    }

    static func fingerprint(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(modified)"
    }
}

struct JobSettingsSnapshot: Codable, Hashable {
    static let currentTranscriptionProcessingVersion = 4

    var transcriptionProcessingVersion: Int
    var transcriptionPreset: TranscriptionPreset
    var transcriptionQualityPreset: TranscriptionQualityPreset
    var sourceLanguage: String
    var whisperModel: String
    var whisperBackend: WhisperBackend
    var openAIModel: String
    var translationSourceLanguage: String
    var translationTargetLanguage: String
    var translationChunkMode: TranslationChunkMode
    var translationParallelism: Int
    var preprocessAudio: Bool
    var vadFilter: Bool
    var removeEmptySegments: Bool
    var removeRepeatedText: Bool
    var mergeShortSegments: Bool
    var minSegmentDuration: Double
    var maxMergeGap: Double
    var beamSize: Int
    var bestOf: Int
    var temperature: Double
    var noSpeechThreshold: Double

    @MainActor
    init(settings: AppSettingsStore) {
        transcriptionProcessingVersion = Self.currentTranscriptionProcessingVersion
        transcriptionPreset = settings.transcriptionPreset
        transcriptionQualityPreset = settings.transcriptionQualityPreset
        sourceLanguage = settings.sourceLanguage
        whisperModel = settings.whisperModel
        whisperBackend = settings.whisperBackend
        openAIModel = settings.openAIModel
        translationSourceLanguage = settings.translationSourceLanguage
        translationTargetLanguage = settings.translationTargetLanguage
        translationChunkMode = settings.translationChunkMode
        translationParallelism = settings.translationParallelism
        preprocessAudio = settings.preprocessAudio
        vadFilter = settings.vadFilter
        removeEmptySegments = settings.removeEmptySegments
        removeRepeatedText = settings.removeRepeatedText
        mergeShortSegments = settings.mergeShortSegments
        minSegmentDuration = settings.minSegmentDuration
        maxMergeGap = settings.maxMergeGap
        beamSize = settings.beamSize
        bestOf = settings.bestOf
        temperature = settings.temperature
        noSpeechThreshold = settings.noSpeechThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptionProcessingVersion = try container.decodeIfPresent(Int.self, forKey: .transcriptionProcessingVersion) ?? 0
        transcriptionPreset = try container.decodeIfPresent(TranscriptionPreset.self, forKey: .transcriptionPreset) ?? .custom
        transcriptionQualityPreset = try container.decodeIfPresent(TranscriptionQualityPreset.self, forKey: .transcriptionQualityPreset) ?? .balanced
        sourceLanguage = try container.decode(String.self, forKey: .sourceLanguage)
        whisperModel = try container.decode(String.self, forKey: .whisperModel)
        whisperBackend = try container.decode(WhisperBackend.self, forKey: .whisperBackend)
        openAIModel = try container.decode(String.self, forKey: .openAIModel)
        translationSourceLanguage = try container.decodeIfPresent(String.self, forKey: .translationSourceLanguage) ?? "auto"
        translationTargetLanguage = try container.decodeIfPresent(String.self, forKey: .translationTargetLanguage) ?? "English"
        translationChunkMode = try container.decodeIfPresent(TranslationChunkMode.self, forKey: .translationChunkMode) ?? .balanced
        translationParallelism = try container.decodeIfPresent(Int.self, forKey: .translationParallelism) ?? 2
        preprocessAudio = try container.decodeIfPresent(Bool.self, forKey: .preprocessAudio) ?? true
        vadFilter = try container.decodeIfPresent(Bool.self, forKey: .vadFilter) ?? true
        removeEmptySegments = try container.decodeIfPresent(Bool.self, forKey: .removeEmptySegments) ?? true
        removeRepeatedText = try container.decodeIfPresent(Bool.self, forKey: .removeRepeatedText) ?? true
        mergeShortSegments = try container.decodeIfPresent(Bool.self, forKey: .mergeShortSegments) ?? true
        minSegmentDuration = try container.decodeIfPresent(Double.self, forKey: .minSegmentDuration) ?? 0.7
        maxMergeGap = try container.decodeIfPresent(Double.self, forKey: .maxMergeGap) ?? 0.45
        beamSize = try container.decodeIfPresent(Int.self, forKey: .beamSize) ?? 5
        bestOf = try container.decodeIfPresent(Int.self, forKey: .bestOf) ?? 5
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        noSpeechThreshold = try container.decodeIfPresent(Double.self, forKey: .noSpeechThreshold) ?? 0.6
    }
}
