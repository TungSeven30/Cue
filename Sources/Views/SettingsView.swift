import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @State private var isBrowsingOpenRouter = false
    @State private var localModels: [LocalServerModel] = []
    @State private var localServerStatus: LocalServerStatus = .idle

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $settings.transcriptionPreset) {
                    ForEach(TranscriptionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Picker("Quality", selection: $settings.transcriptionQualityPreset) {
                    ForEach(TranscriptionQualityPreset.available(for: settings.whisperBackend)) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                presetPicker(
                    "Language",
                    presets: AppSettingPresets.transcriptionLanguages,
                    selection: $settings.sourceLanguage
                )
                if settings.whisperBackend == .qwen3ASR {
                    TextField("Qwen names & terms", text: $settings.qwenContext)
                        .help("Space-separated character names, places, and unusual terms that Qwen should prefer")
                }
                Toggle("Start jobs automatically when files are added", isOn: $settings.autoStartAddedJobs)
                Picker("Auto-archive finished jobs", selection: $settings.autoArchiveDays) {
                    Text("Never").tag(0)
                    Text("After 7 days").tag(7)
                    Text("After 30 days").tag(30)
                    Text("After 90 days").tag(90)
                }
                .help("Archived jobs leave the sidebar (see the Archived filter) but keep their transcripts on disk")
                Picker("When the queue finishes", selection: $settings.afterQueueAction) {
                    ForEach(AfterQueueAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .help("Runs after the last queued job completes — useful for overnight batches")
                Toggle("Show the Cue icon in the menu bar", isOn: $showMenuBarExtra)
                Toggle("Show advanced transcription controls", isOn: $settings.showAdvancedControls)
                if settings.showAdvancedControls {
                    backendPicker
                    TextField("Custom language code", text: $settings.sourceLanguage)
                    presetPicker(
                        settings.whisperBackend == .qwen3ASR ? "Qwen model" : "Whisper model",
                        presets: AppSettingPresets.whisperModels(for: settings.whisperBackend),
                        selection: $settings.whisperModel
                    )
                    TextField(settings.whisperBackend == .qwen3ASR ? "Custom Qwen model" : "Custom Whisper model", text: $settings.whisperModel)
                    Toggle("Clean audio before transcription", isOn: $settings.preprocessAudio)
                        .help("Cleans audio with an ffmpeg filter before transcription; skipped when ffmpeg is not installed")
                    if settings.whisperBackend != .qwen3ASR {
                        Toggle("Voice activity detection", isOn: $settings.vadFilter)
                    }
                    Toggle("Remove empty segments", isOn: $settings.removeEmptySegments)
                    Toggle("Remove repeated text", isOn: $settings.removeRepeatedText)
                    Toggle("Merge short segments", isOn: $settings.mergeShortSegments)
                    HStack {
                        Text("Minimum segment")
                        Slider(value: $settings.minSegmentDuration, in: 0.2...2.0, step: 0.1)
                        Text("\(settings.minSegmentDuration, specifier: "%.1f")s")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Merge gap")
                        Slider(value: $settings.maxMergeGap, in: 0.1...1.5, step: 0.05)
                        Text("\(settings.maxMergeGap, specifier: "%.2f")s")
                            .monospacedDigit()
                    }
                    if settings.whisperBackend != .qwen3ASR {
                        Stepper("Beam size: \(settings.beamSize)", value: $settings.beamSize, in: 1...10)
                        Stepper("Best of: \(settings.bestOf)", value: $settings.bestOf, in: 1...10)
                        HStack {
                            Text("Temperature")
                            Slider(value: $settings.temperature, in: 0...1, step: 0.05)
                            Text("\(settings.temperature, specifier: "%.2f")")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("No-speech threshold")
                            Slider(value: $settings.noSpeechThreshold, in: 0...1, step: 0.05)
                            Text("\(settings.noSpeechThreshold, specifier: "%.2f")")
                                .monospacedDigit()
                        }
                    }
                    if let message = settings.transcriptionValidationMessage {
                        HStack {
                            Text(message)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Repair") {
                                settings.repairTranscriptionModelForBackend()
                            }
                        }
                    }
                }
            } header: {
                Label("Transcription", systemImage: "waveform")
            } footer: {
                Text("Presets keep backend and model paired. Advanced controls are available when you need exact model IDs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Translate after transcription", isOn: $settings.autoTranslateAfterTranscription)
                Toggle("Save SRT subtitles next to the video when finished", isOn: $settings.autoExportSidecar)
                presetPicker(
                    "Translate from",
                    presets: AppSettingPresets.translationSourceLanguages,
                    selection: $settings.translationSourceLanguage
                )
                TextField("Custom source language", text: $settings.translationSourceLanguage)

                presetPicker(
                    "Translate to",
                    presets: AppSettingPresets.translationTargetLanguages,
                    selection: $settings.translationTargetLanguage
                )
                TextField("Custom target language", text: $settings.translationTargetLanguage)

                translationModelPicker
                if settings.currentTranslationProvider == .local {
                    localServerControls
                }
                if settings.currentTranslationProvider == .openRouter {
                    Button("Browse OpenRouter Models…") { isBrowsingOpenRouter = true }
                        .help("Pick from OpenRouter's live catalog — hundreds of models with per-token pricing; no key needed to browse")
                }
                Picker("Chunk mode", selection: $settings.translationChunkMode) {
                    ForEach(TranslationChunkMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper("Parallel chunks: \(settings.translationParallelism)", value: $settings.translationParallelism, in: 1...4)
                DisclosureGroup("Cloud API keys") {
                    SecureField("OpenAI", text: $settings.openAIAPIKey)
                    SecureField("Anthropic", text: $settings.anthropicAPIKey)
                    SecureField("Google", text: $settings.googleAPIKey)
                    SecureField("OpenRouter", text: $settings.openRouterAPIKey)
                }
            } header: {
                Label("Translation", systemImage: "character.bubble")
            } footer: {
                Text(
                    "Use any OpenAI (gpt-…), Anthropic (claude-…), Google (gemini-…), or OpenRouter (openrouter/…) model — the provider and API key are chosen from the model name. Keys are stored in the Keychain. A local/… model needs no key — it talks to the OpenAI-compatible server at the Local server URL (LM Studio, Ollama)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Generate an intro summary when each job finishes", isOn: $settings.generateSummary)
                Picker("Detail", selection: $settings.summaryDetail) {
                    ForEach(SummaryDetail.allCases) { detail in
                        Text(detail.label).tag(detail)
                    }
                }
                providerModelPicker(
                    "Summary model",
                    presets: AppSettingPresets.summaryModels,
                    selection: $settings.summaryModel
                )
                if summaryHasExplicitLocalModel {
                    if settings.currentTranslationProvider != .local {
                        localServerConnectionControls
                    }
                    if !localModels.isEmpty {
                        localModelPicker("Summary running model", selection: $settings.summaryModel)
                    }
                }

                providerModelPicker(
                    "Policy fallback",
                    presets: AppSettingPresets.summaryFallbackModels,
                    selection: $settings.summaryFallbackModel
                )
                if fallbackHasLocalModel {
                    if settings.currentTranslationProvider != .local, !summaryHasExplicitLocalModel {
                        localServerConnectionControls
                    }
                    if !localModels.isEmpty {
                        localModelPicker("Fallback running model", selection: $settings.summaryFallbackModel)
                    }
                }

                if !settings.isSummaryReady {
                    Label(settings.modelReadinessReason(settings.resolvedSummaryModel), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let fallback = settings.resolvedSummaryFallbackModel, !settings.isModelReady(fallback) {
                    Label("Fallback unavailable: \(settings.modelReadinessReason(fallback)).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Intro Summary", systemImage: "text.badge.star")
            } footer: {
                Text(
                    "The summary may use the translation model, a different cloud model, or a local/… model. The fallback is attempted only after a policy or safety refusal—not for bad keys, rate limits, outages, or malformed replies. Subtitle text is sent only to the models you select."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $settings.translationPrompt)
                    .font(.body)
                    .frame(minHeight: 130)
                Button("Reset Prompt") {
                    settings.resetTranslationPrompt()
                }
            } header: {
                Label("Translator Prompt", systemImage: "text.quote")
            } footer: {
                Text("This prompt is combined with required subtitle JSON rules during translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .sheet(isPresented: $isBrowsingOpenRouter) {
            OpenRouterModelBrowserView(settings: settings)
        }
        .onChange(of: settings.localTranslationEndpoint) { _, _ in
            localModels = []
            localServerStatus = .idle
        }
        .onChange(of: settings.openAIModel) { _, model in
            loadLocalModelsIfNeeded(for: model)
        }
        .onChange(of: settings.summaryModel) { _, model in
            loadLocalModelsIfNeeded(for: model)
        }
        .onChange(of: settings.summaryFallbackModel) { _, model in
            loadLocalModelsIfNeeded(for: model)
        }
        .task {
            if anyLocalModelSelected {
                loadLocalModels()
            }
        }
    }

    private var localServerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            localServerConnectionControls

            if !localModels.isEmpty {
                localModelPicker(
                    localModelsAreConfirmedRunning ? "Running model" : "Server model",
                    selection: $settings.openAIModel
                )
            }
        }
    }

    private var localServerConnectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Local server URL", text: $settings.localTranslationEndpoint)
                    .onSubmit { loadLocalModels() }
                    .help("The LM Studio address on this Mac or another Mac, for example http://192.168.0.196:1234")

                Button {
                    loadLocalModels()
                } label: {
                    if localServerStatus == .loading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(localModels.isEmpty ? "Load Models" : "Reload", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(
                    settings.localTranslationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || localServerStatus == .loading
                )
            }

            localServerStatusView
        }
    }

    private func localModelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: localModelIDSelection(for: selection)) {
            Text("Choose a model…").tag("")
            ForEach(localModels) { model in
                if model.availability == .running {
                    Label(model.id, systemImage: "play.circle.fill").tag(model.id)
                } else {
                    Text(model.id).tag(model.id)
                }
            }
        }
        .help("Choose a model reported by the local server. LM Studio models marked as running are confirmed loaded instances.")
    }

    private func localModelIDSelection(for selection: Binding<String>) -> Binding<String> {
        Binding {
            let selected = selection.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard selected.lowercased().hasPrefix("local/") else { return "" }
            return String(selected.dropFirst("local/".count))
        } set: { modelID in
            guard !modelID.isEmpty else { return }
            selection.wrappedValue = "local/\(modelID)"
        }
    }

    private var summaryHasExplicitLocalModel: Bool {
        let model = settings.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.isEmpty && TranslationProvider.infer(from: model) == .local
    }

    private var fallbackHasLocalModel: Bool {
        let model = settings.summaryFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.isEmpty && TranslationProvider.infer(from: model) == .local
    }

    private var anyLocalModelSelected: Bool {
        settings.currentTranslationProvider == .local
            || summaryHasExplicitLocalModel
            || fallbackHasLocalModel
    }

    private func loadLocalModelsIfNeeded(for model: String) {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty,
            TranslationProvider.infer(from: selected) == .local,
            localModels.isEmpty,
            localServerStatus != .loading
        {
            loadLocalModels()
        }
    }

    /// A concrete local instance id is routing detail, not a separate provider.
    /// Keep provider pickers labeled "Local server" after a running model is
    /// chosen instead of presenting a confusing generic "Custom" value.
    private func providerModelPicker(
        _ title: String,
        presets: [SettingsPreset],
        selection: Binding<String>
    ) -> some View {
        Picker(title, selection: providerModelSelection(selection)) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.value)
            }
            if !presets.map(\.value).contains(selection.wrappedValue),
                TranslationProvider.infer(from: selection.wrappedValue) != .local
            {
                Text(providerModelLabel(for: selection.wrappedValue)).tag(selection.wrappedValue)
            }
        }
    }

    private func providerModelSelection(_ selection: Binding<String>) -> Binding<String> {
        Binding {
            let model = selection.wrappedValue
            return TranslationProvider.infer(from: model) == .local ? "local/" : model
        } set: { model in
            if model == "local/", TranslationProvider.infer(from: selection.wrappedValue) == .local {
                return
            }
            selection.wrappedValue = model
        }
    }

    private func providerModelLabel(for model: String) -> String {
        switch TranslationProvider.infer(from: model) {
        case .openai: return "OpenAI model"
        case .anthropic: return "Anthropic model"
        case .google: return "Google model"
        case .local: return "Local server (LM Studio / Ollama)"
        case .openRouter: return "OpenRouter model"
        }
    }

    private var translationModelPicker: some View {
        providerModelPicker(
            "LLM",
            presets: AppSettingPresets.translationModels,
            selection: $settings.openAIModel
        )
    }

    @ViewBuilder
    private var localServerStatusView: some View {
        switch localServerStatus {
        case .idle:
            Label("Enter the LM Studio address, then load its models.", systemImage: "network")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .loading:
            Label("Connecting to the local server…", systemImage: "network")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .connected(let count, let confirmedRunning):
            Label(
                confirmedRunning
                    ? "Connected — \(count) model instance\(count == 1 ? "" : "s") running"
                    : "Connected — server reports \(count) text-generation model\(count == 1 ? "" : "s")",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private var localModelsAreConfirmedRunning: Bool {
        !localModels.isEmpty && localModels.allSatisfy { $0.availability == .running }
    }

    private func loadLocalModels() {
        let endpoint = settings.localTranslationEndpoint
        localServerStatus = .loading
        Task {
            do {
                let models = try await LocalModelCatalog.fetch(endpoint: endpoint)
                guard endpoint == settings.localTranslationEndpoint else { return }
                localModels = models
                localServerStatus = .connected(models.count, confirmedRunning: localModelsAreConfirmedRunning)
            } catch {
                guard endpoint == settings.localTranslationEndpoint else { return }
                localModels = []
                localServerStatus = .failed(error.localizedDescription)
            }
        }
    }

    private var backendPicker: some View {
        Picker("Backend", selection: $settings.whisperBackend) {
            ForEach(WhisperBackend.allCases) { backend in
                Text(backend.label).tag(backend)
            }
        }
    }

    private func presetPicker(
        _ title: String,
        presets: [SettingsPreset],
        selection: Binding<String>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.value)
            }
            if !presets.map(\.value).contains(selection.wrappedValue) {
                Text("Custom").tag(selection.wrappedValue)
            }
        }
    }
}

private enum LocalServerStatus: Equatable {
    case idle
    case loading
    case connected(Int, confirmedRunning: Bool)
    case failed(String)
}
