import SwiftUI
import Testing
@testable import Cue

/// Pins the persisted Appearance values and the 100% guarantee: the default
/// Text size must resolve to the platform text styles themselves.
@MainActor
struct DisplayPreferencesTests {
    @Test func persistedRawValuesAreStable() {
        #expect(DisplayPreferenceKey.typography == "displayTypography")
        #expect(DisplayPreferenceKey.textScale == "displayTextScale")
        #expect(DisplayPreferenceKey.listDensity == "displayListDensity")
        #expect(AppTypography.allCases.map(\.rawValue) == ["system", "rounded", "serif", "monospaced"])
        #expect(TextScale.allCases.map(\.rawValue) == ["smaller", "standard", "large", "larger", "largest"])
        #expect(ListDensity.allCases.map(\.rawValue) == ["compact", "comfortable", "detailed"])
        #expect(SettingsPane.storageKey == "settingsSelectedPane")
        #expect(
            SettingsPane.allCases.map(\.rawValue)
                == ["general", "appearance", "models", "transcribe", "translate", "summary", "apiKeys"]
        )
    }

    @Test func defaultsKeepTodaysLook() {
        #expect(AppTypography.system.design == nil)
        #expect(TextScale.standard.factor == 1)
        #expect(TextScale.standard.controlSize == .regular)
        #expect(ListDensity.comfortable.showsSecondaryLine)
        #expect(!ListDensity.comfortable.showsDetailLine)
        #expect(!ListDensity.compact.showsSecondaryLine)
        #expect(ListDensity.detailed.showsDetailLine)
    }

    @Test func scaleFactorsIncreaseMonotonically() {
        let factors = TextScale.allCases.map(\.factor)
        #expect(factors == factors.sorted())
        #expect(TextScale.largest.percentLabel == "150%")
        #expect(TextScale.smaller.percentLabel == "90%")
    }

    @Test func defaultScaleResolvesToPlatformTextStyles() {
        #expect(CueFont.font(.caption, scale: 1) == Font.system(.caption))
        #expect(CueFont.font(.body, scale: 1) == Font.system(.body))
        #expect(CueFont.font(.headline, scale: 1, weight: .semibold) == Font.system(.headline).weight(.semibold))
        #expect(CueFont.pointSize(for: .body) == 13)
        #expect(CueFont.pointSize(for: .caption) == 10)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersTextScaleLadder() async throws {
        let ladder = VStack(alignment: .leading, spacing: 8) {
            ForEach(TextScale.allCases) { scale in
                HStack(spacing: 12) {
                    Text("\(scale.label) \(scale.percentLabel)").cueFont(.body)
                    Text("caption sample").cueFont(.caption).foregroundStyle(.secondary)
                }
                .environment(\.cueTextScale, scale.factor)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let url = try await ViewSnapshot.capture(ladder, name: "base-text-scale-ladder", size: CGSize(width: 420, height: 260))
        #expect(url != nil)
    }
}
