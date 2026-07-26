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
