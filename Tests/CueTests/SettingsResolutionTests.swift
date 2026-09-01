import Foundation
import Testing
@testable import Cue

struct QualityPresetParameterTests {
    @Test func customHasNoParameters() {
        #expect(TranscriptionQualityPreset.custom.parameters == nil)
    }

    // Values must match the table previously hard-coded in
    // AppSettingsStore.applyQualityPreset(), which this replaces.
    @Test func balancedMatchesLegacyTable() throws {
        let p = try #require(TranscriptionQualityPreset.balanced.parameters)
        #expect(p.preprocessAudio == true)
        #expect(p.vadFilter == true)
        #expect(p.removeEmptySegments == true)
        #expect(p.removeRepeatedText == true)
        #expect(p.mergeShortSegments == true)
        #expect(p.minSegmentDuration == 0.7)
        #expect(p.maxMergeGap == 0.45)
        #expect(p.beamSize == 5)
        #expect(p.bestOf == 5)
        #expect(p.temperature == 0)
        #expect(p.noSpeechThreshold == 0.6)
    }

    @Test func everyNonCustomPresetHasParameters() {
        for preset in TranscriptionQualityPreset.allCases where preset != .custom {
            #expect(preset.parameters != nil, "\(preset) must provide parameters")
        }
    }

    @Test func fastDisablesPreprocessAndMerge() throws {
        let p = try #require(TranscriptionQualityPreset.fast.parameters)
        #expect(p.preprocessAudio == false)
        #expect(p.mergeShortSegments == false)
        #expect(p.beamSize == 3)
    }

    @Test func qwenMoviePreservesCleanAudioAndSpokenRepetition() throws {
        let p = try #require(TranscriptionQualityPreset.qwenMovie.parameters)
        #expect(!p.preprocessAudio)
        #expect(!p.removeRepeatedText)
        #expect(p.mergeShortSegments)
        #expect(p.beamSize == 1)
        #expect(TranscriptionQualityPreset.available(for: .qwen3ASR) == [.qwenMovie, .custom])
    }
}

struct JobSettingsOverridesTests {
    @Test func defaultIsEmpty() {
        #expect(JobSettingsOverrides().isEmpty)
    }

    @Test func anyFieldMakesItNonEmpty() {
        var o = JobSettingsOverrides()
        o.translationTargetLanguage = "Vietnamese"
        #expect(!o.isEmpty)
    }

    @Test func decodesFromEmptyObject() throws {
        let o = try JSONDecoder().decode(JobSettingsOverrides.self, from: Data("{}".utf8))
        #expect(o.isEmpty)
    }

    // Spec error-handling table: an override naming a preset this build no
    // longer knows must decode as nil (inherit), not fail the whole job file.
    @Test func unknownPresetRawValueDecodesAsInherit() throws {
        let json = #"{"transcriptionPreset":"laserFocus","sourceLanguage":"ja"}"#
        let o = try JSONDecoder().decode(JobSettingsOverrides.self, from: Data(json.utf8))
        #expect(o.transcriptionPreset == nil)
        #expect(o.sourceLanguage == "ja")
    }

    @Test func roundTrips() throws {
        var o = JobSettingsOverrides()
        o.sourceLanguage = "ja"
        o.qwenContext = "Totoro Satsuki"
        o.transcriptionPreset = .bestAccuracy
        o.transcriptionQualityPreset = .movieDialogue
        o.translationTargetLanguage = "Vietnamese"
        o.autoTranslate = true
        o.translationSourceLanguage = "ja"
        o.openAIModel = "gpt-5.5"
        o.generateSummary = true
        o.summaryDetail = .detailed
        o.whisperBackend = .qwen3ASR
        o.whisperModel = AppSettingsStore.qwen3DefaultModel
        let data = try JSONEncoder().encode(o)
        let back = try JSONDecoder().decode(JobSettingsOverrides.self, from: data)
        #expect(back == o)
    }
}

struct TranscriptionJobMigrationTests {
    private func decodeJob(_ json: String) throws -> TranscriptionJob {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: Data(json.utf8))
    }

    private var legacyJobJSON: String {
        """
        {
          "id": "\(UUID().uuidString)",
          "sourcePath": "/tmp/example.mp4",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z",
          "status": "idle",
          "progress": {"stage": "idle", "detail": "x"},
          "settings": {
            "sourceLanguage": "auto",
            "whisperModel": "m",
            "whisperBackend": "auto",
            "openAIModel": "gpt-5.5"
          },
          "transcriptSegments": [],
          "translatedSegments": [],
          "log": "log\\n"
        }
        """
    }

    @Test func legacyJobGetsDefaultsForNewFields() throws {
        let job = try decodeJob(legacyJobJSON)
        #expect(job.overrides.isEmpty)
        #expect(job.origin == .manual)
        // Spec §0.5: -createdAt approximates today's newest-first ordering.
        #expect(job.orderIndex == -job.createdAt.timeIntervalSince1970)
    }

    @Test func newFieldsRoundTrip() throws {
        var job = try decodeJob(legacyJobJSON)
        job.overrides.translationTargetLanguage = "Vietnamese"
        job.origin = .watchFolder
        job.orderIndex = 42.5
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TranscriptionJob.self, from: try encoder.encode(job))
        #expect(back.overrides.translationTargetLanguage == "Vietnamese")
        #expect(back.origin == .watchFolder)
        #expect(back.orderIndex == 42.5)
    }
}

struct SnapshotResolutionTests {
    /// Decodes a baseline snapshot without touching AppSettingsStore
    /// (UserDefaults/Keychain). decodeIfPresent fills defaults.
    private func makeSnapshot() throws -> JobSettingsSnapshot {
        let json = """
            {
              "sourceLanguage": "auto",
              "whisperModel": "mlx-community/whisper-large-v3-turbo",
              "whisperBackend": "mlx-whisper",
              "openAIModel": "gpt-5.5"
            }
            """
        return try JSONDecoder().decode(JobSettingsSnapshot.self, from: Data(json.utf8))
    }

    @Test func emptyOverridesChangeNothing() throws {
        let base = try makeSnapshot()
        #expect(base.applying(JobSettingsOverrides()) == base)
    }

    @Test func languageOverridesWin() throws {
        var o = JobSettingsOverrides()
        o.sourceLanguage = "ja"
        o.translationTargetLanguage = "Vietnamese"
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.sourceLanguage == "ja")
        #expect(resolved.qwenContext == "")
        #expect(resolved.translationTargetLanguage == "Vietnamese")
        // Untouched fields inherit.
        #expect(resolved.whisperModel == "mlx-community/whisper-large-v3-turbo")
    }

    @Test func transcriptionPresetExpandsToBackendAndModel() throws {
        var o = JobSettingsOverrides()
        o.transcriptionPreset = .bestAccuracy
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.transcriptionPreset == .bestAccuracy)
        #expect(resolved.whisperBackend == .qwen3ASR)
        #expect(resolved.whisperModel == AppSettingsStore.qwen3DefaultModel)
    }

    @Test func qualityPresetExpandsToParameters() throws {
        var o = JobSettingsOverrides()
        o.transcriptionQualityPreset = .noisyAudio
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.transcriptionQualityPreset == .noisyAudio)
        #expect(resolved.beamSize == 7)
        #expect(resolved.noSpeechThreshold == 0.45)
        #expect(resolved.minSegmentDuration == 1.0)
    }

    @Test func identityIgnoresTranslationFields() throws {
        let base = try makeSnapshot()
        var o = JobSettingsOverrides()
        o.translationTargetLanguage = "Vietnamese"
        #expect(base.applying(o).transcriptionIdentity == base.transcriptionIdentity)
    }

    @Test func identityChangesWithTranscriptionFields() throws {
        let base = try makeSnapshot()
        var o = JobSettingsOverrides()
        o.sourceLanguage = "ja"
        #expect(base.applying(o).transcriptionIdentity != base.transcriptionIdentity)

        var contextOverride = JobSettingsOverrides()
        contextOverride.qwenContext = "Arrakis Chani"
        #expect(base.applying(contextOverride).transcriptionIdentity == base.transcriptionIdentity)

        var qwenOverride = JobSettingsOverrides()
        qwenOverride.transcriptionPreset = .bestAccuracy
        let qwen = base.applying(qwenOverride)
        #expect(qwen.applying(contextOverride).transcriptionIdentity != qwen.transcriptionIdentity)
    }

    // A translation run must not rewrite the record of which settings
    // produced the transcript, or a later skip check would trust a
    // transcript the current model never made.
    @Test func directBackendAndModelOverridesWinAfterPreset() throws {
        var o = JobSettingsOverrides()
        o.transcriptionPreset = .builtIn
        o.whisperBackend = .mlxWhisper
        o.whisperModel = AppSettingsStore.mlxTurboModel
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.whisperBackend == .mlxWhisper)
        #expect(resolved.whisperModel == AppSettingsStore.mlxTurboModel)
    }

    @Test func translationAndSummaryOverridesWin() throws {
        var o = JobSettingsOverrides()
        o.translationSourceLanguage = "ja"
        o.openAIModel = "claude-sonnet-4"
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.translationSourceLanguage == "ja")
        #expect(resolved.openAIModel == "claude-sonnet-4")
    }

    @Test func updatingTranslationFieldsPreservesTranscriptionIdentity() throws {
        let original = try makeSnapshot()
        var o = JobSettingsOverrides()
        o.sourceLanguage = "ja"
        o.translationTargetLanguage = "Vietnamese"
        let resolved = original.applying(o)
        let stamped = original.updatingTranslationFields(from: resolved)
        #expect(stamped.transcriptionIdentity == original.transcriptionIdentity)
        #expect(stamped.translationTargetLanguage == "Vietnamese")
    }
}
