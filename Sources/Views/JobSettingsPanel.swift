import SwiftUI

/// Sizing, wording, and motion for the job-settings card under the video
/// preview. These are pure functions so the rules are unit-tested directly.
enum JobSettingsLayout {
    /// Persisted disclosure state; do not rename.
    static let expandedStorageKey = "detailJobSettingsExpanded"

    /// The detail pane at the app's 1080×720 minimum window: a 250 pt sidebar
    /// and about 52 pt of toolbar leave roughly 830×668.
    static let minimumPaneHeight: CGFloat = 668
    /// An open panel never takes the transcript below this much height.
    static let minimumTranscriptHeight: CGFloat = 160
    /// Below this an open panel is too short to read, so it stops shrinking
    /// and scrolls instead.
    static let minimumPanelHeight: CGFloat = 96

    /// Everything in the preview layout that is not the player, the open
    /// panel, or the transcript: the one-line header, the card's own row, the
    /// view picker, dividers, and spacing. It grows with Text size.
    static func chromeHeight(textScale: CGFloat) -> CGFloat {
        140 + 60 * (max(textScale, 1) - 1)
    }

    /// How tall the open panel may be before it scrolls: whatever the pane has
    /// left after the player, the fixed chrome, and the transcript's minimum.
    static func expandedPanelMaxHeight(paneHeight: CGFloat, playerHeight: CGFloat, textScale: CGFloat) -> CGFloat {
        guard paneHeight.isFinite, playerHeight.isFinite, textScale.isFinite else { return minimumPanelHeight }
        let free = paneHeight - chromeHeight(textScale: textScale) - playerHeight - minimumTranscriptHeight
        return max(minimumPanelHeight, free)
    }

    /// The one-line summary shown while the card is collapsed, for example
    /// "Japanese → English · Large v3 · Auto-translate on".
    @MainActor
    static func summary(for settings: JobSettingsSnapshot, autoTranslate: Bool) -> String {
        [
            "\(languageLabel(settings.translationSourceLanguage)) → \(languageLabel(settings.translationTargetLanguage))",
            modelLabel(backend: settings.whisperBackend, model: settings.whisperModel),
            autoTranslate ? "Auto-translate on" : "Auto-translate off",
        ].joined(separator: " · ")
    }

    private static func languageLabel(_ value: String) -> String {
        AppSettingPresets.translationSourceLanguages.first { $0.value == value }?.label ?? value
    }

    /// The menu's own name for the model when it has one; otherwise the last
    /// path component, so a Hugging Face repo id stays short.
    @MainActor
    private static func modelLabel(backend: WhisperBackend, model: String) -> String {
        if let preset = AppSettingPresets.whisperModels(for: backend).first(where: { $0.value == model }) {
            return preset.label
        }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    /// Stages a failure can be attributed to; anything else reads as a
    /// generic stop, matching the banner's "Processing Stopped".
    private static let failableStages: Set<JobStage> = [
        .preflight, .extractingAudio, .loadingModel, .transcribing, .translating, .burningIn,
    ]

    /// What the collapsed row says about a failed job: the stage, then the
    /// first line of the reason. The full reason stays in the panel's banner.
    static func failureHint(failedStage: JobStage?, detail: String) -> String {
        let phrase: String
        if let failedStage, failableStages.contains(failedStage) {
            phrase = "\(failedStage.label) failed"
        } else {
            phrase = "Processing stopped"
        }
        let reason =
            detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let reason else { return phrase }
        return "\(phrase): \(reason)"
    }

    /// VoiceOver value for the disclosure: its state, then what the sighted
    /// row shows, with the arrow spoken as a word.
    static func accessibilityValue(isExpanded: Bool, detail: String) -> String {
        let state = isExpanded ? "Expanded" : "Collapsed"
        let spoken = detail.replacingOccurrences(of: " → ", with: " to ")
        return spoken.isEmpty ? state : "\(state). \(spoken)"
    }

    /// Expanding and collapsing animate unless the user asked for reduced motion.
    static func toggleTransaction(reduceMotion: Bool) -> Transaction {
        TranscriptMotion.followTransaction(reduceMotion: reduceMotion)
    }
}

/// A card under the video preview with the selected job's settings and
/// workflows. Collapsed it is one row: a disclosure with a summary line (or the
/// failure and a Retry button), then the preview-size controls. Expanded it
/// also holds everything the full header card offers while the preview is
/// hidden: run options, the next action, progress and failure details, and
/// environment checks. The panel is height-capped and scrolls so the transcript
/// keeps room.
struct JobSettingsCard<PreviewControls: View>: View {
    @ObservedObject var model: AppModel
    let paneHeight: CGFloat
    let playerHeight: CGFloat
    @ViewBuilder let previewControls: () -> PreviewControls

    @AppStorage(JobSettingsLayout.expandedStorageKey) private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cueTextScale) private var textScale

    private var isFailed: Bool { model.progress.stage == .failed }

    private var summary: String {
        guard let resolved = model.selectedJobResolvedSettings else { return "" }
        return JobSettingsLayout.summary(for: resolved, autoTranslate: model.jobCardAutoTranslate.wrappedValue)
    }

    /// The failure when there is one, since that is what needs attention;
    /// otherwise the settings the next run will use.
    private var rowDetail: String {
        isFailed
            ? JobSettingsLayout.failureHint(failedStage: model.progress.failedStage, detail: model.progress.detail)
            : summary
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                Divider()
                panel
            }
        }
        .background(isFailed ? Color.red.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator, lineWidth: 1)
                if isFailed {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            disclosureButton
            if isFailed {
                Button {
                    model.retrySelectedFailedStage()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Retry the stage that failed")
            }
            previewControls()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var disclosureButton: some View {
        Button {
            withTransaction(JobSettingsLayout.toggleTransaction(reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .cueFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text("Job settings")
                    .cueFont(.subheadline, weight: .semibold)
                if isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
                Text(rowDetail)
                    .cueFont(.caption, weight: isFailed ? .medium : nil)
                    .foregroundStyle(isFailed ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityLabel("Job settings")
        .accessibilityValue(JobSettingsLayout.accessibilityValue(isExpanded: isExpanded, detail: rowDetail))
        .accessibilityHint("Shows or hides this job's run options and actions")
        .help(rowDetail.isEmpty ? "Job settings" : rowDetail)
    }

    private var panel: some View {
        ViewThatFits(in: .vertical) {
            panelContent
            ScrollView { panelContent }
        }
        .frame(
            maxHeight: JobSettingsLayout.expandedPanelMaxHeight(
                paneHeight: paneHeight,
                playerHeight: playerHeight,
                textScale: textScale
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Job settings")
    }

    /// The header card's content, minus the title the compact header already
    /// shows and the chips the run options repeat.
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(model.selectedVideoURL?.path(percentEncoded: false) ?? "No file selected")
                    .cueFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                JobDiagnosticsPill(model: model)
            }

            JobProgressStrip(model: model)

            JobNextActionRow(model: model)

            Divider()

            RunOptionsRow(model: model)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
