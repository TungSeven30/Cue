import SwiftUI

/// The engines and models Cue uses: the speech recognizer, and the language
/// model that translates. Everything about *how* they run lives in the
/// Transcribe and Translate panes.
struct ModelsSettingsPane: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var server: LocalServerConnection
    @ViewState private var isBrowsingOpenRouter = false

    var body: some View {
        SettingsPaneScaffold(pane: .models) {
            transcriptionSection
            translationSection
        }
        .sheet(isPresented: $isBrowsingOpenRouter) {
            OpenRouterModelBrowserView(settings: settings)
        }
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        Section {
            Picker("Preset", selection: $settings.transcriptionPreset) {
                ForEach(TranscriptionPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            if let message = settings.transcriptionValidationMessage {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Repair") {
                        settings.repairTranscriptionModelForBackend()
                    }
                }
            }
            DisclosureGroup(isExpanded: $settings.showAdvancedControls) {
                Picker("Backend", selection: $settings.whisperBackend) {
                    ForEach(WhisperBackend.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                SettingsPresetPicker(
                    title: settings.whisperBackend == .qwen3ASR ? "Qwen model" : "Whisper model",
                    presets: AppSettingPresets.whisperModels(for: settings.whisperBackend),
                    selection: $settings.whisperModel
                )
                TextField(
                    settings.whisperBackend == .qwen3ASR ? "Custom Qwen model" : "Custom Whisper model",
                    text: $settings.whisperModel
                )
            } label: {
                Text("Advanced")
            }
        } header: {
            SettingsSectionHeader("Speech recognition")
        } footer: {
            SettingsFootnote(
                "Presets keep backend and model paired. Open Advanced when you need an exact backend or model ID. Language, quality, and decoding options are in Transcribe."
            )
        }
    }

    // MARK: Translation

    private var translationSection: some View {
        Section {
            ProviderModelPicker(
                title: "Translation model",
                presets: AppSettingPresets.translationModels,
                selection: $settings.openAIModel
            )
            if settings.currentTranslationProvider == .local {
                LocalServerConnectionRows(settings: settings, server: server)
                if !server.models.isEmpty {
                    LocalModelPicker(
                        title: server.modelsAreConfirmedRunning ? "Running model" : "Server model",
                        selection: $settings.openAIModel,
                        models: server.models
                    )
                }
            }
            if settings.currentTranslationProvider == .openRouter {
                Button("Browse OpenRouter Models…") { isBrowsingOpenRouter = true }
                    .help("Pick from OpenRouter's live catalog — hundreds of models with per-token pricing; no key needed to browse")
            }
            SettingsPaneLinkRow(
                title: "API key",
                value: keyStatus,
                pane: .apiKeys,
                buttonTitle: "Open API Keys"
            )
        } header: {
            SettingsSectionHeader("Translation")
        } footer: {
            SettingsFootnote(
                "The provider is chosen from the model name: gpt-… OpenAI, claude-… Anthropic, gemini-… Google, openrouter/… OpenRouter, groq/… Groq, cerebras/… Cerebras, and local/… for LM Studio or Ollama on your network. Languages, chunking, and the prompt are in Translate."
            )
        }
    }

    /// Whether the selected translation model can run, in the words the row
    /// under it needs.
    private var keyStatus: String {
        let provider = settings.currentTranslationProvider
        if settings.isTranslationReady {
            return provider == .local ? "Local server address is set" : "\(provider.label) key is set"
        }
        return "Not ready: \(settings.modelReadinessReason(settings.openAIModel))"
    }
}
