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
        .navigationTitle("WhisperDesk")
        .navigationSubtitle(model.currentJob?.title ?? "")
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            model.addVideos(urls: fileURLs)
            return !fileURLs.isEmpty
        }
        .onAppear { syncPlayer() }
        .onChange(of: model.selectedJobID) { syncPlayer() }
        .onChange(of: model.isPlayerVisible) { syncPlayer() }
        .onChange(of: tab) { syncOverlaySegments() }
        .onChange(of: model.displayTranscriptSegments) { syncOverlaySegments() }
        .onChange(of: model.displayTranslatedSegments) { syncOverlaySegments() }
    }

    private func syncPlayer() {
        guard model.isPlayerVisible, let url = model.selectedVideoURL else { return }
        playerController.load(url: url)
        syncOverlaySegments()
    }

    private func syncOverlaySegments() {
        // The overlay and highlight follow whichever text the user is looking
        // at: translation on the translation tab, else the original — live
        // partials included while a job streams.
        let segments = tab == .translation && !model.displayTranslatedSegments.isEmpty
            ? model.displayTranslatedSegments
            : model.displayTranscriptSegments
        playerController.updateSegments(segments)
    }

    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("No Video Selected", systemImage: "film.stack")
        } description: {
            Text("Open video or audio files, or drag them into the window, to add jobs.")
        } actions: {
            Button("Add Files…") { model.selectVideo() }
                .buttonStyle(.borderedProminent)
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
                if model.isSelectedJobRunning, let fraction = model.progress.fraction {
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
                ContentUnavailableView {
                    Label("No Transcript Yet", systemImage: "waveform")
                } description: {
                    Text("Run transcription to turn the source audio into editable subtitle segments.")
                } actions: {
                    Button("Transcribe") { model.startTranscription() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canTranscribe)
                }
            } else {
                segmentList(segments: model.displayTranscriptSegments, onEdit: model.updateTranscriptSegment)
            }
        case .translation:
            if model.displayTranslatedSegments.isEmpty {
                ContentUnavailableView {
                    Label("No Translation Yet", systemImage: "character.bubble")
                } description: {
                    Text(translationHint)
                } actions: {
                    Button("Translate") { model.startTranslation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canTranslate)
                }
            } else {
                segmentList(segments: model.displayTranslatedSegments, onEdit: model.updateTranslatedSegment)
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
        onEdit: @escaping (TranscriptionSegment, String) -> Void
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptView(
                    segments: segments,
                    warnings: model.qualityWarnings(for: segments),
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
            HStack(spacing: 12) {
                Label(job.settings.transcriptionPreset.label, systemImage: "speedometer")
                Text(job.settings.transcriptionQualityPreset.label)
                Text("\(job.settings.whisperBackend.label) · \(job.settings.whisperModel)")
                Text("\(job.settings.translationSourceLanguage) → \(job.settings.translationTargetLanguage) · \(job.settings.openAIModel)")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
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
                if let fraction = progress.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if isFailed {
                // Show the full failure reason, wrapped, in a red-tinted banner.
                Text(progress.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else if model.isSelectedJobRunning {
                ProgressView().progressViewStyle(.linear)
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
            } else if let summary = model.currentJob?.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(summary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RunOptionsRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 20) {
                field(title: "Preset") {
                    Picker("Preset", selection: $model.settings.transcriptionPreset) {
                        ForEach(TranscriptionPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                field(title: "Quality") {
                    Picker("Quality", selection: $model.settings.transcriptionQualityPreset) {
                        ForEach(TranscriptionQualityPreset.allCases) { preset in
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
                        selection: $model.settings.sourceLanguage
                    )
                    .frame(width: 130)
                }
            }

            if model.settings.showAdvancedControls {
                HStack(alignment: .bottom, spacing: 20) {
                    field(title: "Backend") {
                        Picker("Backend", selection: $model.settings.whisperBackend) {
                            ForEach(WhisperBackend.allCases) { backend in
                                Text(backend.label).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    field(title: "Whisper model") {
                        presetMenu(
                            "Whisper model",
                            presets: AppSettingPresets.whisperModels(for: model.settings.whisperBackend),
                            selection: $model.settings.whisperModel
                        )
                        .frame(minWidth: 220)
                    }

                    if let message = model.settings.transcriptionValidationMessage {
                        Button("Repair") {
                            model.settings.repairTranscriptionModelForBackend()
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
                        selection: $model.settings.translationSourceLanguage
                    )
                    .frame(width: 150)
                }

                field(title: "Translate to") {
                    presetMenu(
                        "Translate to",
                        presets: AppSettingPresets.translationTargetLanguages,
                        selection: $model.settings.translationTargetLanguage
                    )
                    .frame(width: 150)
                }

                field(title: "Translation LLM") {
                    presetMenu(
                        "LLM",
                        presets: AppSettingPresets.translationModels,
                        selection: $model.settings.openAIModel
                    )
                    .frame(width: 170)
                }
            }

            HStack(spacing: 14) {
                Toggle("Auto-translate", isOn: $model.settings.autoTranslateAfterTranscription)
                    .toggleStyle(.checkbox)
                Toggle("Intro summary", isOn: $model.settings.generateSummary)
                    .toggleStyle(.checkbox)
                    .help("Generate a spoiler-free intro from the subtitles, shown at the start of exported SRT/VTT files")
                if model.settings.generateSummary {
                    Picker("", selection: $model.settings.summaryDetail) {
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
                Text("\(model.settings.translationSourceLanguage) → \(model.settings.translationTargetLanguage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .disabled(model.isSelectedJobRunning)
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
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .labelStyle(.iconOnly)
                            .help(command)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
