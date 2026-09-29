import SwiftUI
import Testing

@testable import Cue

/// The wording, sizing, and motion rules behind the job-settings card, plus the
/// pure helpers the transcript rows use for the list-density preference.
@MainActor
struct JobSettingsPanelTests {
    /// A snapshot over an isolated defaults suite, then edited field by field so
    /// each test states exactly what it depends on.
    private func snapshot(
        backend: WhisperBackend = .mlxWhisper,
        model: String = "mlx-community/whisper-large-v3",
        source: String = "Japanese",
        target: String = "English"
    ) -> JobSettingsSnapshot {
        let suiteName = "cue-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        var snapshot = JobSettingsSnapshot(settings: settings)
        snapshot.whisperBackend = backend
        snapshot.whisperModel = model
        snapshot.translationSourceLanguage = source
        snapshot.translationTargetLanguage = target
        return snapshot
    }

    // MARK: - Collapsed summary

    @Test func collapsedSummaryNamesLanguagesModelAndAutoTranslate() {
        #expect(
            JobSettingsLayout.summary(for: snapshot(), autoTranslate: true)
                == "Japanese → English · Large v3 · Auto-translate on")
        #expect(
            JobSettingsLayout.summary(for: snapshot(), autoTranslate: false)
                == "Japanese → English · Large v3 · Auto-translate off")
    }

    @Test func summaryUsesTheModelMenusOwnNamePerBackend() {
        let faster = snapshot(backend: .fasterWhisper, model: "large-v2")
        #expect(JobSettingsLayout.summary(for: faster, autoTranslate: true).contains("· Large v2 ·"))
        let native = snapshot(backend: .native, model: "ggml-large-v3-turbo-q5_0.bin")
        #expect(
            JobSettingsLayout.summary(for: native, autoTranslate: true).contains("· Large v3 Turbo (quantized, recommended) ·"))
        let qwen = snapshot(backend: .qwen3ASR, model: "Qwen/Qwen3-ASR-0.6B")
        #expect(JobSettingsLayout.summary(for: qwen, autoTranslate: true).contains("· Qwen3 ASR 0.6B (fast) ·"))
    }

    @Test func summaryShortensAnUnlistedModelToItsLastPathComponent() {
        let custom = snapshot(model: "someone/whisper-custom-ft")
        #expect(JobSettingsLayout.summary(for: custom, autoTranslate: true).contains("· whisper-custom-ft ·"))
        let bare = snapshot(model: "my-local-model")
        #expect(JobSettingsLayout.summary(for: bare, autoTranslate: true).contains("· my-local-model ·"))
    }

    @Test func summaryReadsAutoDetectAndUnknownLanguagesSensibly() {
        let auto = snapshot(source: "auto", target: "Korean")
        #expect(JobSettingsLayout.summary(for: auto, autoTranslate: true).hasPrefix("Auto → Korean · "))
        let unknown = snapshot(source: "Klingon", target: "English")
        #expect(JobSettingsLayout.summary(for: unknown, autoTranslate: true).hasPrefix("Klingon → English · "))
    }

    // MARK: - Failure hint

    @Test func failureHintNamesTheStageThenTheFirstLineOfTheReason() {
        #expect(
            JobSettingsLayout.failureHint(failedStage: .transcribing, detail: "The model file is missing.")
                == "Transcribing failed: The model file is missing.")
        #expect(
            JobSettingsLayout.failureHint(failedStage: .translating, detail: "Rate limited by the provider.")
                == "Translating failed: Rate limited by the provider.")
        #expect(
            JobSettingsLayout.failureHint(failedStage: .extractingAudio, detail: "No audio track.")
                == "Extracting audio failed: No audio track.")
    }

    @Test func failureHintKeepsOnlyTheFirstNonEmptyLine() {
        let detail = "\n  \nffmpeg exited with status 1\nInvalid data found when processing input\n"
        #expect(
            JobSettingsLayout.failureHint(failedStage: .extractingAudio, detail: detail)
                == "Extracting audio failed: ffmpeg exited with status 1")
    }

    @Test func failureHintFallsBackToAGenericStop() {
        #expect(JobSettingsLayout.failureHint(failedStage: nil, detail: "Something broke.") == "Processing stopped: Something broke.")
        // Stages that are not a step of the pipeline never read "Failed failed".
        for stage: JobStage in [.failed, .complete, .idle, .queued, .canceled] {
            #expect(JobSettingsLayout.failureHint(failedStage: stage, detail: "Boom.") == "Processing stopped: Boom.")
        }
    }

    @Test func failureHintWithoutAReasonIsJustThePhrase() {
        #expect(JobSettingsLayout.failureHint(failedStage: .loadingModel, detail: "") == "Loading model failed")
        #expect(JobSettingsLayout.failureHint(failedStage: .loadingModel, detail: " \n \t ") == "Loading model failed")
        #expect(JobSettingsLayout.failureHint(failedStage: nil, detail: "") == "Processing stopped")
    }

    // MARK: - Height budget

    @Test func panelBudgetIsWhatTheTranscriptCanSpare() {
        // 900 pane − 140 chrome − 280 player − 160 minimum transcript.
        #expect(JobSettingsLayout.expandedPanelMaxHeight(paneHeight: 900, playerHeight: 280, textScale: 1) == 320)
        // A taller player leaves the panel less room.
        #expect(JobSettingsLayout.expandedPanelMaxHeight(paneHeight: 900, playerHeight: 400, textScale: 1) == 200)
    }

    @Test func panelBudgetShrinksAsTextGrows() {
        let standard = JobSettingsLayout.expandedPanelMaxHeight(paneHeight: 900, playerHeight: 280, textScale: 1)
        let largest = JobSettingsLayout.expandedPanelMaxHeight(paneHeight: 900, playerHeight: 280, textScale: 1.5)
        #expect(largest < standard)
        // Smaller-than-standard text never buys extra room: the chrome has a floor.
        #expect(JobSettingsLayout.chromeHeight(textScale: 0.9) == JobSettingsLayout.chromeHeight(textScale: 1))
        #expect(JobSettingsLayout.chromeHeight(textScale: 1.5) == 170)
    }

    @Test func panelNeverShrinksBelowReadableAtTheMinimumWindow() {
        // At the minimum window with the default player there is less than the
        // floor to give, so the panel keeps the floor and scrolls.
        let atMinimum = JobSettingsLayout.expandedPanelMaxHeight(
            paneHeight: JobSettingsLayout.minimumPaneHeight, playerHeight: 280, textScale: 1)
        #expect(atMinimum == JobSettingsLayout.minimumPanelHeight)
        let worstCase = JobSettingsLayout.expandedPanelMaxHeight(
            paneHeight: JobSettingsLayout.minimumPaneHeight, playerHeight: 640, textScale: 1.5)
        #expect(worstCase == JobSettingsLayout.minimumPanelHeight)
        #expect(JobSettingsLayout.expandedPanelMaxHeight(paneHeight: 0, playerHeight: 280, textScale: 1) == JobSettingsLayout.minimumPanelHeight)
    }

    @Test func panelBudgetIgnoresNonFiniteInput() {
        let floor = JobSettingsLayout.minimumPanelHeight
        #expect(JobSettingsLayout.expandedPanelMaxHeight(paneHeight: .nan, playerHeight: 280, textScale: 1) == floor)
        #expect(JobSettingsLayout.expandedPanelMaxHeight(paneHeight: .infinity, playerHeight: 280, textScale: 1) == floor)
        #expect(JobSettingsLayout.expandedPanelMaxHeight(paneHeight: 900, playerHeight: .nan, textScale: 1) == floor)
        #expect(JobSettingsLayout.expandedPanelMaxHeight(paneHeight: 900, playerHeight: 280, textScale: .nan) == floor)
    }

    @Test func aPanelAboveTheFloorAlwaysLeavesTheTranscriptItsMinimum() {
        let scales: [CGFloat] = [1, 1.15, 1.3, 1.5]
        for pane in stride(from: CGFloat(500), through: 1400, by: 50) {
            for player in stride(from: CGFloat(140), through: 640, by: 20) {
                for scale in scales {
                    let budget = JobSettingsLayout.expandedPanelMaxHeight(paneHeight: pane, playerHeight: player, textScale: scale)
                    #expect(budget >= JobSettingsLayout.minimumPanelHeight)
                    guard budget > JobSettingsLayout.minimumPanelHeight else { continue }
                    let transcript = pane - JobSettingsLayout.chromeHeight(textScale: scale) - player - budget
                    #expect(abs(transcript - JobSettingsLayout.minimumTranscriptHeight) < 0.001)
                }
            }
        }
    }

    // MARK: - Disclosure wording and motion

    @Test func disclosureValueStatesTheStateAndSpeaksTheArrow() {
        #expect(
            JobSettingsLayout.accessibilityValue(isExpanded: false, detail: "Japanese → English · Large v3 · Auto-translate on")
                == "Collapsed. Japanese to English · Large v3 · Auto-translate on")
        #expect(JobSettingsLayout.accessibilityValue(isExpanded: true, detail: "Transcribing failed: Boom.") == "Expanded. Transcribing failed: Boom.")
        #expect(JobSettingsLayout.accessibilityValue(isExpanded: true, detail: "") == "Expanded")
        #expect(JobSettingsLayout.accessibilityValue(isExpanded: false, detail: "") == "Collapsed")
    }

    @Test func expandingAnimatesUnlessMotionIsReduced() {
        let reduced = JobSettingsLayout.toggleTransaction(reduceMotion: true)
        #expect(reduced.animation == nil)
        #expect(reduced.disablesAnimations)
        let normal = JobSettingsLayout.toggleTransaction(reduceMotion: false)
        #expect(normal.animation != nil)
        #expect(!normal.disablesAnimations)
    }

    @Test func theDisclosureStateKeepsItsPersistedKey() {
        #expect(JobSettingsLayout.expandedStorageKey == "detailJobSettingsExpanded")
    }

    // MARK: - Transcript segment metrics (Detailed density)

    private func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptionSegment {
        TranscriptionSegment(id: 1, start: start, end: end, text: text)
    }

    @Test func metricsReportDurationAndCharactersPerSecond() {
        let metrics = TranscriptSegmentMetrics(segment: segment(1.0, 3.0, "abcdefghijklmnopqrst"))
        #expect(metrics.duration == 2.0)
        #expect(metrics.characterCount == 20)
        #expect(metrics.charactersPerSecond == 10)
        #expect(metrics.durationLabel == "2.0 s")
        #expect(metrics.rateLabel == "10 chars/s")
        #expect(metrics.summary == "2.0 s · 10 chars/s")
        #expect(metrics.accessibilityLabel == "Duration 2.0 seconds, 10 characters per second")
    }

    @Test func slowRatesKeepOneDecimalAndFastRatesAreWhole() {
        #expect(TranscriptSegmentMetrics(segment: segment(0, 2, "12345")).rateLabel == "2.5 chars/s")
        #expect(TranscriptSegmentMetrics(segment: segment(0, 1, String(repeating: "x", count: 17))).rateLabel == "17 chars/s")
        #expect(TranscriptSegmentMetrics(segment: segment(0, 1, String(repeating: "x", count: 17))).accessibilityLabel.hasSuffix("17 characters per second"))
    }

    @Test func aRateThatRoundsUpToTenNeverPrintsTenPointZero() {
        // 9.96 chars/s rounds to 10.0 at one decimal, so it reads as a whole number.
        let nearlyTen = TranscriptSegmentMetrics(segment: segment(0, 25.1, String(repeating: "x", count: 250)))
        #expect(nearlyTen.rateLabel == "10 chars/s")
        let justUnder = TranscriptSegmentMetrics(segment: segment(0, 1, String(repeating: "x", count: 9)))
        #expect(justUnder.rateLabel == "9.0 chars/s")
    }

    @Test func aZeroLengthCueHasNoRate() {
        let metrics = TranscriptSegmentMetrics(segment: segment(4.0, 4.0, "Hello"))
        #expect(metrics.duration == 0)
        #expect(metrics.charactersPerSecond == nil)
        #expect(metrics.rateLabel == nil)
        #expect(metrics.summary == "0.0 s")
        #expect(metrics.accessibilityLabel == "Duration 0.0 seconds")
    }

    @Test func anInvertedOrNonFiniteCueReadsAsZeroLength() {
        #expect(TranscriptSegmentMetrics(segment: segment(5.0, 3.0, "Hello")).duration == 0)
        #expect(TranscriptSegmentMetrics(segment: segment(0, .infinity, "Hello")).duration == 0)
        #expect(TranscriptSegmentMetrics(segment: segment(.nan, 2, "Hello")).duration == 0)
        #expect(TranscriptSegmentMetrics(segment: segment(0, .infinity, "Hello")).summary == "0.0 s")
    }

    @Test func aCueWithoutTextHasADurationButNoRate() {
        let empty = TranscriptSegmentMetrics(segment: segment(1, 3, ""))
        #expect(empty.characterCount == 0)
        #expect(empty.charactersPerSecond == nil)
        #expect(empty.summary == "2.0 s")
        let blank = TranscriptSegmentMetrics(segment: segment(1, 3, "  \n\t "))
        #expect(blank.characterCount == 0)
        #expect(blank.rateLabel == nil)
    }

    @Test func surroundingWhitespaceIsNotCountedButCjkCharactersAre() {
        #expect(TranscriptSegmentMetrics(segment: segment(0, 1, "  abc \n")).characterCount == 3)
        let japanese = TranscriptSegmentMetrics(segment: segment(0, 2.5, "こんにちは、世界。"))
        #expect(japanese.characterCount == 9)
        #expect(japanese.rateLabel == "3.6 chars/s")
    }

    // MARK: - Transcript row metrics per density

    @Test func comfortableRowsKeepTheOriginalLayoutValueForValue() {
        let metrics = TranscriptRowMetrics(density: .comfortable)
        #expect(metrics.sectionSpacing == 10)
        #expect(metrics.rowSpacing == 8)
        #expect(metrics.rowPadding == 12)
        #expect(metrics.contentSpacing == 6)
        #expect(metrics.editorPadding == 8)
        #expect(metrics.editorMinHeight == 46)
        #expect(metrics.badgeVerticalPadding == 2)
        #expect(!metrics.showsSegmentMetrics)
    }

    @Test func detailedRowsAddTheReadoutWithoutChangingSpacing() {
        let detailed = TranscriptRowMetrics(density: .detailed)
        let comfortable = TranscriptRowMetrics(density: .comfortable)
        #expect(detailed.showsSegmentMetrics)
        #expect(
            TranscriptRowMetrics(density: .detailed).rowPadding == comfortable.rowPadding
                && detailed.rowSpacing == comfortable.rowSpacing
                && detailed.contentSpacing == comfortable.contentSpacing
                && detailed.editorMinHeight == comfortable.editorMinHeight)
    }

    @Test func compactRowsAreTighterEverywhereAndShowNoExtras() {
        let compact = TranscriptRowMetrics(density: .compact)
        let comfortable = TranscriptRowMetrics(density: .comfortable)
        #expect(compact.sectionSpacing < comfortable.sectionSpacing)
        #expect(compact.rowSpacing < comfortable.rowSpacing)
        #expect(compact.rowPadding < comfortable.rowPadding)
        #expect(compact.contentSpacing < comfortable.contentSpacing)
        #expect(compact.editorPadding < comfortable.editorPadding)
        #expect(compact.editorMinHeight < comfortable.editorMinHeight)
        #expect(compact.badgeVerticalPadding < comfortable.badgeVerticalPadding)
        #expect(!compact.showsSegmentMetrics)
    }
}
