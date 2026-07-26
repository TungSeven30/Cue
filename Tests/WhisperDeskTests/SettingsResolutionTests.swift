import Foundation
import Testing
@testable import WhisperDesk

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
        o.transcriptionPreset = .bestAccuracy
        o.transcriptionQualityPreset = .movieDialogue
        o.translationTargetLanguage = "Vietnamese"
        o.autoTranslate = true
        let data = try JSONEncoder().encode(o)
        let back = try JSONDecoder().decode(JobSettingsOverrides.self, from: data)
        #expect(back == o)
    }
}
