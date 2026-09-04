import AppKit
import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case transcript
    case translation
    case log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: return "Transcript"
        case .translation: return "Translation"
        case .log: return "Log"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: return "text.alignleft"
        case .translation: return "character.bubble"
        case .log: return "list.bullet.rectangle"
        }
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playerController: PlayerController
    @State private var tab: WorkspaceTab = .transcript
    @AppStorage("followPlayback") private var followPlayback = true
    @AppStorage("playerHeight") private var playerHeight = 280.0
    @State private var dragStartHeight: Double?
    @State private var isHoveringResizeHandle = false

    var body: some View {
        Group {
            if model.currentJob == nil {
                emptyWorkspace
            } else {
                workspace
            }
        }
        .navigationTitle("Cue")
        .navigationSubtitle(model.currentJob?.title ?? "")
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            var isDirectory: ObjCBool = false
            let containsFolder = fileURLs.contains { url in
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            let added = model.addMedia(urls: fileURLs)
            if added == 0 && containsFolder {
                let alert = NSAlert()
                alert.messageText = "No Video or Audio Files Found"
                alert.informativeText = "The dropped folder does not contain any video or audio files."
                alert.alertStyle = .informational
                alert.runModal()
            }
            return added > 0
        }
        .onAppear { syncPlayer() }
        .onChange(of: model.selectedJobID) { syncPlayer() }
        .onChange(of: model.isPlayerVisible) { syncPlayer() }
        .onChange(of: tab) { syncOverlaySegments() }
        // A cheap revision key instead of comparing whole segment arrays on
        // every render (see AppModel.overlayRevision).
        .onChange(of: model.overlayRevision) { syncOverlaySegments() }
    }

    private func syncPlayer() {
        guard let url = model.selectedVideoURL else {
            playerController.clear()
            return
        }
        guard model.isPlayerVisible else { return }
        playerController.load(url: url)
        syncOverlaySegments()
    }

    private func syncOverlaySegments() {
        // Nothing to keep in sync while the player is hidden; syncPlayer
        // re-syncs when it appears.
        guard model.isPlayerVisible else { return }
        // The overlay and highlight follow whichever text the user is looking
        // at: translation on the translation tab, else the original — live
        // partials included while a job streams.
        let segments =
            tab == .translation && !model.displayTranslatedSegments.isEmpty
            ? model.displayTranslatedSegments
            : model.displayTranscriptSegments
        playerController.updateSegments(segments)
    }

    @ViewBuilder
    private var emptyWorkspace: some View {
        if model.isHydratingJobs {
            // The history is still decoding off the main actor; flashing the
            // welcome screen for a beat would be wrong for a returning user.
            ProgressView("Loading jobs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.jobs.isEmpty {
            WelcomeWorkspaceView(model: model)
        } else {
            ContentUnavailableView {
                Label("No Job Selected", systemImage: "film.stack")
            } description: {
                Text("Select a video or audio job from the sidebar to inspect its transcript, translations, or video preview.")
            } actions: {
                Button("Add Files…") { model.selectVideo() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if model.isPlayerVisible {
                // The full header card would leave no room for the video and
                // the transcript, so shrink it to one line while previewing.
                compactHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                PlayerPane(controller: playerController)
                    .frame(height: playerHeight)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                playerResizeHandle
                    .padding(.bottom, 2)
            } else {
                HeaderCard(model: model)
                    .padding(20)
            }

            HStack(spacing: 12) {
                Picker("View", selection: $tab) {
                    ForEach(WorkspaceTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.isPlayerVisible {
                    Toggle("Follow playback", isOn: $followPlayback)
                        .toggleStyle(.checkbox)
                        .help("Keep the playing segment scrolled into view")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background {
                // Background keyboard shortcuts for Cmd+1 / Cmd+2 / Cmd+3 tab switching
                HStack {
                    Button("") { tab = .transcript }.keyboardShortcut("1", modifiers: [.command])
                    Button("") { tab = .translation }.keyboardShortcut("2", modifiers: [.command])
                    Button("") { tab = .log }.keyboardShortcut("3", modifiers: [.command])
                }
                .opacity(0)
                .allowsHitTesting(false)
            }

            Divider()

            tabContent
        }
    }

    /// Drag up or down to resize the video; double-click to reset.
    private var playerResizeHandle: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(.tertiary)
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Resize video preview")
            .accessibilityValue("\(Int(playerHeight)) points")
            .onHover { inside in
                isHoveringResizeHandle = inside
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                // Hiding the player while hovered would otherwise leave the
                // resize cursor stuck (the matching un-hover never fires).
                if isHoveringResizeHandle {
                    isHoveringResizeHandle = false
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = playerHeight
                        }
                        playerHeight = min(640, max(140, (dragStartHeight ?? playerHeight) + value.translation.height))
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
            .onTapGesture(count: 2) {
                playerHeight = 280
            }
            .help("Drag to resize the video preview; double-click to reset")
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            if let job = model.currentJob {
                Image(systemName: job.status.systemImage)
                    .foregroundStyle(job.status.tint)
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(job.status.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.isSelectedJobRunning, let fraction = model.progress.displayFraction {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .transcript:
            if model.displayTranscriptSegments.isEmpty {
                if model.isSelectedJobRunning || model.currentJob?.status.isRunning == true {
                    TranscriptLoadingSkeletonView(
                        title: "Transcribing Audio…",
                        detail: model.progress.detail,
                        fraction: model.progress.displayFraction
                    )
                } else if model.currentJob?.status == .queued {
                    QueuedJobPlaceholderView(model: model)
                } else {
                    ContentUnavailableView {
                        Label("No Transcript Yet", systemImage: "waveform")
                    } description: {
                        Text("Run transcription to turn the source audio into editable subtitle segments.")
                    } actions: {
                        Button("Transcribe") { model.startTranscription() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canTranscribe)
                        Button("Load Subtitles…") { model.presentSubtitleLoadPanel() }
                            .disabled(!model.canLoadSubtitles)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ImportedSubtitleBanner(model: model, slot: .transcript)
                    segmentList(segments: model.displayTranscriptSegments, slot: .transcript, onEdit: model.updateTranscriptSegment)
                }
            }
        case .translation:
            if model.displayTranslatedSegments.isEmpty {
                if model.currentJob?.status == .translating {
                    TranscriptLoadingSkeletonView(
                        title: "Translating Subtitles…",
                        detail: model.progress.detail.isEmpty ? "Generating \(model.translationTargetLabel) subtitles…" : model.progress.detail,
                        fraction: model.progress.displayFraction
                    )
                } else if model.transcriptSegments.isEmpty {
                    ContentUnavailableView {
                        Label("No Translation Yet", systemImage: "character.bubble")
                    } description: {
                        Text("Transcribe the video first, then translate the segments into \(model.translationTargetLabel).")
                    } actions: {
                        Button("Transcribe") { model.startTranscription() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canTranscribe)
                        Button("Load Subtitles…") { model.presentSubtitleLoadPanel() }
                            .disabled(!model.canLoadSubtitles)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Translation Yet", systemImage: "character.bubble")
                    } description: {
                        Text(translationHint)
                    } actions: {
                        Button("Translate") { model.startTranslation() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canTranslate)
                        Button("Load Subtitles…") { model.presentSubtitleLoadPanel() }
                            .disabled(!model.canLoadSubtitles)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ImportedSubtitleBanner(model: model, slot: .translation)
                    segmentList(segments: model.displayTranslatedSegments, slot: .translation, onEdit: model.updateTranslatedSegment)
                }
            }
        case .log:
            ScrollView {
                LogView(log: model.log)
                    .padding(20)
            }
        }
    }

    private func segmentList(
        segments: [TranscriptionSegment],
        slot: SubtitleSidecarScanner.Slot,
        onEdit: @escaping (TranscriptionSegment, String) -> Void
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptView(
                    segments: segments,
                    warnings: model.qualityWarnings(for: segments, slot: slot),
                    activeSegmentID: model.isPlayerVisible ? playerController.activeSegmentID : nil,
                    onEdit: onEdit,
                    onSeek: model.isPlayerVisible ? { playerController.seek(to: $0.start) } : nil
                )
                .padding(20)
            }
            .onChange(of: playerController.activeSegmentID) { _, newID in
                guard followPlayback, model.isPlayerVisible, let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var translationHint: String {
        if model.transcriptSegments.isEmpty {
            return "Transcribe the video first, then translate the segments into \(model.translationTargetLabel)."
        }
        if !model.settings.isTranslationReady {
            return model.settings.currentTranslationProvider == .local
                ? "Set the Local server URL in Settings (⌘,) to translate the transcript into \(model.translationTargetLabel)."
                : "Add a \(model.settings.currentTranslationProvider.label) API key in Settings (⌘,) to translate the transcript into \(model.translationTargetLabel)."
        }
        return "Translate the transcript into natural \(model.translationTargetLabel) subtitles with your configured model."
    }
}

// MARK: - Header

private struct HeaderCard: View {
    @ObservedObject var model: AppModel
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentJob?.title ?? "Untitled")
                        .font(.headline)
                    Text(model.selectedVideoURL?.path(percentEncoded: false) ?? "No file selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                diagnosticsPill
            }

            progressStrip

            nextActionRow

            Divider()

            settingsSummary

            RunOptionsRow(model: model)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var settingsSummary: some View {
        if let job = model.currentJob {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    metadataChip(icon: "speedometer", text: job.settings.transcriptionPreset.label)
                    metadataChip(icon: "gauge.with.needle", text: job.settings.transcriptionQualityPreset.label)
                    metadataChip(icon: "cpu", text: "\(job.settings.whisperBackend.label) · \(job.settings.whisperModel)")
                    metadataChip(icon: "character.bubble", text: "\(job.settings.translationSourceLanguage) → \(job.settings.translationTargetLanguage)")
                    if !job.settings.openAIModel.isEmpty {
                        metadataChip(icon: "sparkles", text: job.settings.openAIModel)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func metadataChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private var diagnosticsPill: some View {
        Button {
            showDiagnostics.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isRunningDiagnostics ? "arrow.triangle.2.circlepath" : diagnosticsIcon)
                    .symbolEffect(.pulse, isActive: model.isRunningDiagnostics)
                Text(model.isRunningDiagnostics ? "Checking…" : model.diagnosticsSummary)
                    .font(.callout)
            }
            .foregroundStyle(diagnosticsColor)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(diagnosticsColor.opacity(0.12), in: Capsule())
        .popover(isPresented: $showDiagnostics, arrowEdge: .bottom) {
            DiagnosticsPopover(model: model)
        }
    }

    /// The pill only escalates for hard failures; missing optional tools
    /// stay discoverable as per-item warnings inside the popover.
    private var diagnosticsPillState: DiagnosticState? {
        guard !model.diagnostics.isEmpty else {
            return nil
        }
        return model.diagnostics.contains { $0.state == .failed } ? .failed : .passed
    }

    private var diagnosticsIcon: String {
        diagnosticsPillState?.systemImage ?? "stethoscope"
    }

    private var diagnosticsColor: Color {
        diagnosticsPillState?.tint ?? .secondary
    }

    @ViewBuilder
    private var progressStrip: some View {
        let progress = model.progress
        let isFailed = progress.stage == .failed
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let status = model.currentJob?.status {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.tint)
                        .symbolEffect(.pulse, isActive: model.isSelectedJobRunning)
                }
                Text(progress.stage.label)
                    .font(.subheadline.weight(.semibold))
                if !isFailed {
                    Text(progress.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let fraction = progress.displayFraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if isFailed {
                // Show the full failure reason, wrapped, in a red-tinted banner with direct recovery options.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Processing Stopped")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.red)
                            Text(progress.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.retrySelectedFailedStage()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if progress.detail.localizedCaseInsensitiveContains("ffmpeg") || progress.detail.localizedCaseInsensitiveContains("python")
                            || progress.detail.localizedCaseInsensitiveContains("model")
                        {
                            Button("System Setup…") {
                                model.isShowingSetupGuide = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        CopyFeedbackButton(text: progress.detail, helpText: "Copy error description")
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.red.opacity(0.2), lineWidth: 1)
                )
            } else if let fraction = progress.displayFraction {
                ProgressView(value: fraction)
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            } else if model.isSelectedJobRunning {
                ProgressView().progressViewStyle(.linear)
            } else if model.currentJob?.status == .translationComplete {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Translation Ready")
                        .font(.subheadline.weight(.semibold))
                    Text("· \(model.translatedSegments.count) subtitle cues")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.isShowingExportSheet = true
                    } label: {
                        Label("Export Subtitles…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if model.currentJob?.status == .transcriptionComplete && model.translatedSegments.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.teal)
                    Text("Transcript Ready")
                        .font(.subheadline.weight(.semibold))
                    Text("· \(model.transcriptSegments.count) subtitle cues")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.isShowingExportSheet = true
                    } label: {
                        Label("Export Subtitles…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var nextActionRow: some View {
        if model.transcriptSegments.isEmpty {
            Button {
                model.startTranscription()
            } label: {
                Label("Transcribe", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canTranscribe)
        }
        if !model.transcriptSegments.isEmpty, model.translatedSegments.isEmpty {
            HStack(spacing: 10) {
                Button {
                    model.startTranslation()
                } label: {
                    Label(
                        model.partialTranslatedSegments.isEmpty
                            ? "Translate to \(model.translationTargetLabel)"
                            : "Resume Translation",
                        systemImage: "character.bubble"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canTranslate)

                if !model.settings.isTranslationReady {
                    Text(
                        model.settings.currentTranslationProvider == .local
                            ? "Set the Local server URL in Settings to enable translation."
                            : "Add a \(model.settings.currentTranslationProvider.label) API key in Settings to enable translation."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !model.partialTranslatedSegments.isEmpty {
                    Text("\(model.partialTranslatedSegments.count) segment(s) already saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if !model.transcriptSegments.isEmpty {
            summaryRow
        }
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.generateSummaryNow()
                } label: {
                    Label(
                        model.currentJob?.summary == nil ? "Write Intro Summary" : "Redo Intro Summary",
                        systemImage: "sparkles"
                    )
                }
                .disabled(!model.canGenerateSummary)
                .help("Ask the translation LLM for a spoiler-free intro, shown as the first cue of SRT/VTT exports")

                if model.isGeneratingSummary {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            // Full width, wrapped over several lines: the summary is a paragraph, not a label.
            if !model.isGeneratingSummary, let summary = model.currentJob?.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(summary)
            }
        }
    }
}

private struct RunOptionsRow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    private var resolvedBackend: WhisperBackend {
        model.selectedJobResolvedSettings?.whisperBackend ?? model.settings.whisperBackend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run options")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Defaults…") {
                    openSettings()
                }
                .buttonStyle(.borderless)
                .help("Edit app-wide default settings")
            }

            HStack(alignment: .bottom, spacing: 20) {
                field(title: "Preset") {
                    Picker(
                        "Preset",
                        selection: model.jobCardBinding(get: \.transcriptionPreset) { overrides, value, _ in
                            overrides.transcriptionPreset = value
                            overrides.whisperBackend = nil
                            overrides.whisperModel = nil
                        }
                    ) {
                        ForEach(TranscriptionPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                field(title: "Quality") {
                    Picker(
                        "Quality",
                        selection: model.jobCardBinding(get: \.transcriptionQualityPreset) { overrides, value, _ in
                            overrides.transcriptionQualityPreset = value
                        }
                    ) {
                        ForEach(TranscriptionQualityPreset.available(for: resolvedBackend)) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                field(title: "Transcribe language") {
                    presetMenu(
                        "Language",
                        presets: AppSettingPresets.transcriptionLanguages,
                        selection: model.jobCardBinding(get: \.sourceLanguage) { overrides, value, _ in
                            overrides.sourceLanguage = value
                        }
                    )
                    .frame(width: 130)
                }
            }

            if resolvedBackend == .qwen3ASR {
                field(title: "Qwen names & terms") {
                    TextField(
                        "Character names, places, vocabulary",
                        text: model.jobCardBinding(get: \.qwenContext) { overrides, value, _ in
                            overrides.qwenContext = value.isEmpty ? nil : value
                        }
                    )
                    .textFieldStyle(.roundedBorder)
                    .help("Space-separated terms supplied to Qwen's context prompt")
                }
            }

            if model.settings.showAdvancedControls {
                HStack(alignment: .bottom, spacing: 20) {
                    field(title: "Backend") {
                        Picker(
                            "Backend",
                            selection: model.jobCardBinding(get: \.whisperBackend) { overrides, value, resolved in
                                overrides.transcriptionPreset = .custom
                                overrides.whisperBackend = value
                                overrides.whisperModel = AppSettingsStore.normalizedWhisperModel(
                                    for: value,
                                    current: resolved.whisperModel,
                                    force: true
                                )
                            }
                        ) {
                            ForEach(WhisperBackend.allCases) { backend in
                                Text(backend.label).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    field(title: resolvedBackend == .qwen3ASR ? "Qwen model" : "Whisper model") {
                        presetMenu(
                            resolvedBackend == .qwen3ASR ? "Qwen model" : "Whisper model",
                            presets: AppSettingPresets.whisperModels(for: resolvedBackend),
                            selection: model.jobCardBinding(get: \.whisperModel) { overrides, value, _ in
                                overrides.transcriptionPreset = .custom
                                overrides.whisperModel = value
                            }
                        )
                        .frame(minWidth: 220)
                    }

                    if let message = model.selectedJobTranscriptionValidationMessage {
                        Button("Repair") {
                            model.repairSelectedJobTranscriptionModel()
                        }
                        .help(message)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 20) {
                field(title: "Translate from") {
                    presetMenu(
                        "Translate from",
                        presets: AppSettingPresets.translationSourceLanguages,
                        selection: model.jobCardBinding(get: \.translationSourceLanguage) { overrides, value, _ in
                            overrides.translationSourceLanguage = value
                        }
                    )
                    .frame(width: 150)
                }

                field(title: "Translate to") {
                    presetMenu(
                        "Translate to",
                        presets: AppSettingPresets.translationTargetLanguages,
                        selection: model.jobCardBinding(get: \.translationTargetLanguage) { overrides, value, _ in
                            overrides.translationTargetLanguage = value
                        }
                    )
                    .frame(width: 150)
                }

                field(title: "Translation LLM") {
                    presetMenu(
                        "LLM",
                        presets: AppSettingPresets.translationModels,
                        selection: model.jobCardBinding(get: \.openAIModel) { overrides, value, _ in
                            overrides.openAIModel = value
                        }
                    )
                    .frame(width: 170)
                }
            }

            HStack(spacing: 14) {
                Toggle("Auto-translate", isOn: model.jobCardAutoTranslate)
                    .toggleStyle(.checkbox)
                Toggle("Intro summary", isOn: model.jobCardGenerateSummary)
                    .toggleStyle(.checkbox)
                    .help("Generate a spoiler-free intro from the subtitles, shown at the start of exported SRT/VTT files")
                if model.jobCardShowsIntroSummaryDetail {
                    Picker("", selection: model.jobCardSummaryDetail) {
                        ForEach(SummaryDetail.allCases) { detail in
                            Text(detail.label).tag(detail)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .labelsHidden()
                    .help("Brief: 1-3 sentences in one subtitle. Detailed: a fuller spoiler-free introduction shown as a sequence of subtitles")
                }
                Toggle("Advanced", isOn: $model.settings.showAdvancedControls)
                    .toggleStyle(.checkbox)
                if let resolved = model.selectedJobResolvedSettings {
                    Text("\(resolved.translationSourceLanguage) → \(resolved.translationTargetLanguage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .disabled(model.currentJob == nil || model.isSelectedJobRunning)
        .opacity(model.isSelectedJobRunning ? 0.55 : 1)
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func presetMenu(
        _ title: String,
        presets: [SettingsPreset],
        selection: Binding<String>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.value)
            }
            if !presets.map(\.value).contains(selection.wrappedValue) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

private struct DiagnosticsPopover: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("System Check")
                    .font(.headline)
                Spacer()
                Button {
                    // Close the popover before presenting the sheet so the
                    // two do not fight over presentation.
                    dismiss()
                    DispatchQueue.main.async {
                        model.isShowingSetupGuide = true
                    }
                } label: {
                    Label("Setup Guide", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                Button {
                    model.runDiagnostics()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunningDiagnostics)
            }

            if model.diagnostics.isEmpty {
                Text("Run a system check to verify local dependencies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.diagnostics) { diagnostic in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: diagnostic.state.systemImage)
                            .foregroundStyle(diagnostic.state.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.title)
                                .font(.callout.weight(.semibold))
                            Text(diagnostic.state == .passed ? diagnostic.detail : diagnostic.recovery)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if diagnostic.state != .passed, let command = diagnostic.repairCommand {
                            CopyFeedbackButton(text: command, helpText: command, showsLabel: false)
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Welcome Workspace

private struct WelcomeWorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 8) {
                Text("Welcome to Cue")
                    .font(.title.weight(.bold))

                Text("Fast, accurate, and completely private subtitles and translation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                trustCard(
                    icon: "lock.shield.fill",
                    title: "100% On-Device & Private",
                    subtitle: "Audio stays on your Mac. Whisper engine runs locally with zero telemetry."
                )
                trustCard(
                    icon: "bolt.fill",
                    title: "Metal Accelerated",
                    subtitle: "Hardware-accelerated by Apple Silicon for instant transcription speed."
                )
                trustCard(
                    icon: "character.bubble.fill",
                    title: "Smart Translation",
                    subtitle: "Translate into 50+ languages with synchronized subtitle cues."
                )
            }
            .frame(maxWidth: 680)

            VStack(spacing: 12) {
                Button {
                    model.selectVideo()
                } label: {
                    Label("Add Files…", systemImage: "folder.badge.plus")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 16) {
                    Button {
                        model.promptForRemoteMedia()
                    } label: {
                        Label("Add from URL…", systemImage: "link")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Text("·")
                        .foregroundStyle(.secondary)

                    Button {
                        addWatchFolderViaPanel()
                    } label: {
                        Label("Watch a Folder…", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .font(.callout)
            }

            Text("Drop files anywhere · Supports MP4, MOV, MKV, MP3, WAV, M4A, FLAC, AAC")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 20)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trustCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private func addWatchFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders to watch. New videos dropped into them are processed automatically."
        if panel.runModal() == .OK {
            for url in panel.urls {
                model.addWatchFolder(path: url.path)
            }
        }
    }
}

// MARK: - Skeletons & Queued Placeholders

private struct TranscriptLoadingSkeletonView: View {
    let title: String
    let detail: String
    var fraction: Double? = nil
    @State private var isShimmering = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let fraction {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .progressViewStyle(.linear)
                }

                VStack(spacing: 8) {
                    ForEach(1...4, id: \.self) { index in
                        skeletonRow(index: index)
                    }
                }
                .opacity(isShimmering ? 0.35 : 0.85)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: isShimmering)
            }
            .padding(20)
        }
        .onAppear {
            isShimmering = true
        }
    }

    private func skeletonRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 28, height: 16)

                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 110, height: 12)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(maxWidth: index % 2 == 0 ? .infinity : 320, minHeight: 11, maxHeight: 11)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary.opacity(0.7))
                    .frame(width: index % 2 == 0 ? 210 : 150, height: 11)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(.background.secondary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct QueuedJobPlaceholderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Queued for Processing", systemImage: "clock.fill")
                .foregroundStyle(Color.indigo)
        } description: {
            Text("This video is waiting in the queue. Transcription will start automatically when prior jobs finish.")
        } actions: {
            if model.canStartSelectedJob {
                Button("Start Now") {
                    model.startSelectedJob()
                }
                .buttonStyle(.borderedProminent)
            }
            if model.queuePaused {
                Button("Resume Queue") {
                    model.startAllPendingJobs()
                }
            }
        }
    }
}
