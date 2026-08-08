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
    var partialTranscriptSegments: [TranscriptionSegment]
    var transcriptionStartedAt: Date?
    var transcriptionFinishedAt: Date?
    var translationStartedAt: Date?
    var finishedAt: Date?
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
    /// When set, the job is hidden from the default sidebar views and
    /// skipped by the queue; its JSON stays on disk.
    var archivedAt: Date?

    var sourceURL: URL {
        // .notDirectory skips the lstat that URL(fileURLWithPath:) performs to
        // sniff directory-ness; on a cold network mount that stat can block for
        // hundreds of ms, and this getter runs in the sidebar's row rendering.
        URL(filePath: sourcePath, directoryHint: .notDirectory)
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
        self.partialTranscriptSegments = []
        self.transcriptionStartedAt = nil
        self.transcriptionFinishedAt = nil
        self.translationStartedAt = nil
        self.finishedAt = nil
        self.sourceFingerprint = Self.fingerprint(for: sourceURL)
        self.log = "Choose a video to begin.\n"
        self.summary = nil
        self.overrides = JobSettingsOverrides()
        self.origin = .manual
        self.orderIndex = -now.timeIntervalSince1970
        self.archivedAt = nil
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
        partialTranscriptSegments = try container.decodeIfPresent([TranscriptionSegment].self, forKey: .partialTranscriptSegments) ?? []
        transcriptionStartedAt = try container.decodeIfPresent(Date.self, forKey: .transcriptionStartedAt)
        transcriptionFinishedAt = try container.decodeIfPresent(Date.self, forKey: .transcriptionFinishedAt)
        translationStartedAt = try container.decodeIfPresent(Date.self, forKey: .translationStartedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        sourceFingerprint = try container.decodeIfPresent(String.self, forKey: .sourceFingerprint) ?? Self.fingerprint(for: URL(fileURLWithPath: sourcePath))
        log = try container.decode(String.self, forKey: .log)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        overrides = try container.decodeIfPresent(JobSettingsOverrides.self, forKey: .overrides) ?? JobSettingsOverrides()
        origin = try container.decodeIfPresent(JobOrigin.self, forKey: .origin) ?? .manual
        orderIndex = try container.decodeIfPresent(Double.self, forKey: .orderIndex) ?? -createdAt.timeIntervalSince1970
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    /// Whether an auto-archive pass should tuck this job away: terminal
    /// status, and untouched for longer than the configured window.
    static func shouldAutoArchive(
        status: JobStatus,
        finishedAt: Date?,
        updatedAt: Date,
        olderThanDays days: Int,
        now: Date = Date()
    ) -> Bool {
        guard days > 0 else { return false }
        switch status {
        case .transcriptionComplete, .translationComplete, .canceled, .failed:
            break
        case .idle, .queued, .transcribing, .translating, .burningIn:
            return false
        }
        let reference = finishedAt ?? updatedAt
        return now.timeIntervalSince(reference) > Double(days) * 86_400
    }

    static func fingerprint(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(modified)"
    }
}

/// NOTE: any new field that changes the *transcript* (not translation or
/// summary) must also be added to TranscriptionIdentity below, or the
/// skip-if-unchanged check will miss it. New translation-facing fields must
/// instead be added to updatingTranslationFields(from:), or translation runs
/// will stamp stale values for them.
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

extension JobSettingsSnapshot {
    /// Layers per-job overrides over this (global-derived) snapshot.
    /// Spec §0.3: presets expand to their constituent fields so services
    /// never need to interpret presets themselves.
    func applying(_ overrides: JobSettingsOverrides) -> JobSettingsSnapshot {
        var resolved = self
        if let language = overrides.sourceLanguage {
            resolved.sourceLanguage = language
        }
        if let target = overrides.translationTargetLanguage {
            resolved.translationTargetLanguage = target
        }
        if let preset = overrides.transcriptionPreset,
            let backend = preset.backend, let model = preset.model
        {
            resolved.transcriptionPreset = preset
            resolved.whisperBackend = backend
            resolved.whisperModel = model
        }
        if let quality = overrides.transcriptionQualityPreset,
            let params = quality.parameters
        {
            resolved.transcriptionQualityPreset = quality
            resolved.preprocessAudio = params.preprocessAudio
            resolved.vadFilter = params.vadFilter
            resolved.removeEmptySegments = params.removeEmptySegments
            resolved.removeRepeatedText = params.removeRepeatedText
            resolved.mergeShortSegments = params.mergeShortSegments
            resolved.minSegmentDuration = params.minSegmentDuration
            resolved.maxMergeGap = params.maxMergeGap
            resolved.beamSize = params.beamSize
            resolved.bestOf = params.bestOf
            resolved.temperature = params.temperature
            resolved.noSpeechThreshold = params.noSpeechThreshold
        }
        return resolved
    }

    /// A copy of `self` that adopts only the translation-facing fields from
    /// `other`. Used when stamping a translation run so the record of what
    /// produced the *transcript* (the transcriptionIdentity fields) is
    /// preserved — otherwise a later skip-if-unchanged check would compare
    /// against settings the transcript was never made with.
    func updatingTranslationFields(from other: JobSettingsSnapshot) -> JobSettingsSnapshot {
        var updated = self
        updated.openAIModel = other.openAIModel
        updated.translationSourceLanguage = other.translationSourceLanguage
        updated.translationTargetLanguage = other.translationTargetLanguage
        updated.translationChunkMode = other.translationChunkMode
        updated.translationParallelism = other.translationParallelism
        return updated
    }

    /// The fields that determine what transcript a run produces. Two
    /// snapshots with equal identity yield the same transcript, so re-running
    /// can be skipped (spec §0.6). Translation and summary settings are
    /// deliberately excluded.
    struct TranscriptionIdentity: Hashable {
        let processingVersion: Int
        let sourceLanguage: String
        let whisperModel: String
        let whisperBackend: WhisperBackend
        let preprocessAudio: Bool
        let vadFilter: Bool
        let removeEmptySegments: Bool
        let removeRepeatedText: Bool
        let mergeShortSegments: Bool
        let minSegmentDuration: Double
        let maxMergeGap: Double
        let beamSize: Int
        let bestOf: Int
        let temperature: Double
        let noSpeechThreshold: Double
    }

    var transcriptionIdentity: TranscriptionIdentity {
        TranscriptionIdentity(
            processingVersion: transcriptionProcessingVersion,
            sourceLanguage: sourceLanguage,
            whisperModel: whisperModel,
            whisperBackend: whisperBackend,
            preprocessAudio: preprocessAudio,
            vadFilter: vadFilter,
            removeEmptySegments: removeEmptySegments,
            removeRepeatedText: removeRepeatedText,
            mergeShortSegments: mergeShortSegments,
            minSegmentDuration: minSegmentDuration,
            maxMergeGap: maxMergeGap,
            beamSize: beamSize,
            bestOf: bestOf,
            temperature: temperature,
            noSpeechThreshold: noSpeechThreshold
        )
    }
}
