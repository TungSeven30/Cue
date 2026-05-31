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
    @State private var tab: WorkspaceTab = .transcript

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
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.addVideo(url: url)
            return true
        }
    }

    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("No Video Selected", systemImage: "film.stack")
        } description: {
            Text("Open a video or audio file — or drag one into the window — to start transcribing.")
        } actions: {
            Button("Open Video…") { model.selectVideo() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HeaderCard(model: model)
                .padding(20)

            Picker("View", selection: $tab) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .transcript:
            if model.transcriptSegments.isEmpty {
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
                ScrollView {
                    TranscriptView(
                        segments: model.transcriptSegments,
                        warnings: model.qualityWarnings(for: model.transcriptSegments),
                        onEdit: model.updateTranscriptSegment
                    )
                    .padding(20)
                }
            }
        case .translation:
            if model.translatedSegments.isEmpty {
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
                ScrollView {
                    TranscriptView(
                        segments: model.translatedSegments,
                        warnings: model.qualityWarnings(for: model.translatedSegments),
                        onEdit: model.updateTranslatedSegment
                    )
                    .padding(20)
                }
            }
        case .log:
            ScrollView {
                LogView(log: model.log)
                    .padding(20)
            }
        }
    }

    private var translationHint: String {
        if model.transcriptSegments.isEmpty {
            return "Transcribe the video first, then translate the segments into English."
        }
        if model.settings.openAIAPIKey.isEmpty {
            return "Add an OpenAI API key in Settings (⌘,) to translate the transcript into English."
        }
        return "Translate the transcript into natural English subtitles with your configured model."
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

            Divider()

            RunOptionsRow(model: model)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
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

    private var diagnosticsIcon: String {
        guard let worst = model.diagnostics.map(\.state).max(by: severityOrder) else {
            return "stethoscope"
        }
        return worst.systemImage
    }

    private var diagnosticsColor: Color {
        guard let worst = model.diagnostics.map(\.state).max(by: severityOrder) else {
            return .secondary
        }
        return worst.tint
    }

    private func severityOrder(_ lhs: DiagnosticState, _ rhs: DiagnosticState) -> Bool {
        func rank(_ state: DiagnosticState) -> Int {
            switch state {
            case .passed: return 0
            case .warning: return 1
            case .failed: return 2
            }
        }
        return rank(lhs) < rank(rhs)
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
                        .symbolEffect(.pulse, isActive: model.isBusy)
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
            } else if model.isBusy {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }
}

private struct RunOptionsRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            field(title: "Language") {
                TextField("auto", text: $model.settings.sourceLanguage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

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
                TextField("model", text: $model.settings.whisperModel)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.55 : 1)
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

private struct DiagnosticsPopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("System Check")
                    .font(.headline)
                Spacer()
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
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
