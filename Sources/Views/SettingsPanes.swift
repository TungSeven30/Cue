import AppKit
import SwiftUI

// MARK: - General

/// App-level behavior: how the queue runs, where downloads go, and the menu bar
/// icon.
struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettingsStore
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some View {
        SettingsPaneScaffold(pane: .general) {
            Section {
                Toggle("Start jobs automatically when files are added", isOn: $settings.autoStartAddedJobs)
                Picker("When the queue finishes", selection: $settings.afterQueueAction) {
                    ForEach(AfterQueueAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .help("Runs after the last queued job completes — useful for overnight batches")
                Picker("Auto-archive finished jobs", selection: $settings.autoArchiveDays) {
                    Text("Never").tag(0)
                    Text("After 7 days").tag(7)
                    Text("After 30 days").tag(30)
                    Text("After 90 days").tag(90)
                }
                .help("Archived jobs leave the sidebar (see the Archived filter) but keep their transcripts on disk")
            } header: {
                SettingsSectionHeader("Queue")
            } footer: {
                SettingsFootnote(
                    "With automatic start off, added files wait until you start them. Archived jobs leave the sidebar but keep their transcripts on disk."
                )
            }

            Section {
                DownloadFolderRow(settings: settings)
            } header: {
                SettingsSectionHeader("Downloads")
            } footer: {
                SettingsFootnote("Add from URL (⌘L) saves videos here. Subtitle files exported next to a video are written beside the download.")
            }

            Section {
                Toggle("Show the Cue icon in the menu bar", isOn: $showMenuBarExtra)
            } header: {
                SettingsSectionHeader("Menu bar")
            }
        }
    }
}

/// Where File > Add from URL saves what yt-dlp fetches. The downloaded file is
/// the job's source for good — sidecar export writes beside it — so this is a
/// real destination the user picks, not a cache location.
private struct DownloadFolderRow: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Downloads folder")
                Spacer(minLength: 8)
                Button("Choose…", action: chooseFolder)
                if !settings.downloadDirectory.isEmpty {
                    Button("Reset") { settings.downloadDirectory = "" }
                }
            }
            Text(settings.resolvedDownloadDirectory.path(percentEncoded: false))
                .cueFont(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .help("Add from URL (⌘L) downloads with yt-dlp into this folder, then queues the file")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where Add from URL saves downloaded videos."
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadDirectory = url.path
        }
    }
}

// MARK: - Transcribe

/// How speech is recognized: language, quality, and the decoding controls
/// behind the Advanced disclosure. The engine and model are chosen in Models.
struct TranscribeSettingsPane: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        SettingsPaneScaffold(pane: .transcribe) {
            Section {
                Picker("Quality", selection: $settings.transcriptionQualityPreset) {
                    ForEach(TranscriptionQualityPreset.available(for: settings.whisperBackend)) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                SettingsPresetPicker(
                    title: "Language",
                    presets: AppSettingPresets.transcriptionLanguages,
                    selection: $settings.sourceLanguage
                )
                if settings.whisperBackend == .qwen3ASR {
                    TextField("Qwen names & terms", text: $settings.qwenContext)
                        .help("Space-separated character names, places, and unusual terms that Qwen should prefer")
                }
            } header: {
                SettingsSectionHeader("Recognition")
            } footer: {
                SettingsFootnote(
                    "Quality sets the decoding options below together. Changing one of them switches Quality to Custom. Choose the engine and model in Models."
                )
            }

            Section {
                DisclosureGroup(isExpanded: $settings.showAdvancedControls) {
                    AdvancedDecodingRows(settings: settings)
                } label: {
                    Text("Advanced decoding")
                }
            } footer: {
                SettingsFootnote("Only the options the selected engine reads are shown.")
            }

            Section {
                SettingsPaneLinkRow(
                    title: "Transcription engine",
                    value: "\(settings.transcriptionPreset.label) · \(settings.whisperBackend.label)",
                    pane: .models,
                    buttonTitle: "Choose in Models"
                )
            }
        }
    }
}

/// The advanced decoding controls, unchanged in behavior from the old single
/// form: each row still appears only for the engines that read it.
private struct AdvancedDecodingRows: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        TextField("Custom language code", text: $settings.sourceLanguage)
        Toggle("Clean audio before transcription", isOn: $settings.preprocessAudio)
            .help("Cleans audio with an ffmpeg filter before transcription; skipped when ffmpeg is not installed")
        // Only Faster Whisper reads these; showing a control the selected
        // engine ignores teaches users that Settings lie.
        if settings.whisperBackend == .fasterWhisper || settings.whisperBackend == .auto {
            Toggle("Voice activity detection", isOn: $settings.vadFilter)
        }
        Toggle("Remove empty segments", isOn: $settings.removeEmptySegments)
        Toggle("Remove repeated text", isOn: $settings.removeRepeatedText)
        Toggle("Merge short segments", isOn: $settings.mergeShortSegments)
        SettingsSliderRow(title: "Minimum segment", value: $settings.minSegmentDuration, range: 0.2...2.0, step: 0.1, format: "%.1fs")
        SettingsSliderRow(title: "Merge gap", value: $settings.maxMergeGap, range: 0.1...1.5, step: 0.05, format: "%.2fs")
        // Beam size: built-in engine and Faster Whisper. Best of and
        // temperature: MLX and Faster Whisper (the built-in engine always
        // beam-searches). No-speech: every Whisper.
        if settings.whisperBackend != .qwen3ASR && settings.whisperBackend != .mlxWhisper {
            Stepper("Beam size: \(settings.beamSize)", value: $settings.beamSize, in: 1...10)
        }
        if settings.whisperBackend == .fasterWhisper || settings.whisperBackend == .auto {
            Stepper("Best of: \(settings.bestOf)", value: $settings.bestOf, in: 1...10)
        }
        if settings.whisperBackend == .fasterWhisper || settings.whisperBackend == .mlxWhisper || settings.whisperBackend == .auto {
            SettingsSliderRow(title: "Temperature", value: $settings.temperature, range: 0...1, step: 0.05, format: "%.2f")
        }
        if settings.whisperBackend != .qwen3ASR {
            SettingsSliderRow(title: "No-speech threshold", value: $settings.noSpeechThreshold, range: 0...1, step: 0.05, format: "%.2f")
        }
    }
}

// MARK: - Translate

/// What gets translated and how: automatic translation, the SRT sidecar,
/// languages, batching, and the translator prompt. The translation model is
/// chosen in Models.
struct TranslateSettingsPane: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        SettingsPaneScaffold(pane: .translate) {
            Section {
                Toggle("Translate after transcription", isOn: $settings.autoTranslateAfterTranscription)
                Toggle("Save SRT subtitles next to the video when finished", isOn: $settings.autoExportSidecar)
            } header: {
                SettingsSectionHeader("Automation")
            } footer: {
                SettingsFootnote("Automatic translation needs a translation model that is ready: an API key for a cloud model, or a local server address.")
            }

            Section {
                SettingsPresetPicker(
                    title: "Translate from",
                    presets: AppSettingPresets.translationSourceLanguages,
                    selection: $settings.translationSourceLanguage
                )
                TextField("Custom source language", text: $settings.translationSourceLanguage)
                SettingsPresetPicker(
                    title: "Translate to",
                    presets: AppSettingPresets.translationTargetLanguages,
                    selection: $settings.translationTargetLanguage
                )
                TextField("Custom target language", text: $settings.translationTargetLanguage)
            } header: {
                SettingsSectionHeader("Languages")
            } footer: {
                SettingsFootnote("Pick a language from the list, or type any language name in the custom field.")
            }

            Section {
                SettingsPaneLinkRow(
                    title: "Translation model",
                    value: settings.openAIModel,
                    pane: .models,
                    buttonTitle: "Choose in Models"
                )
                Picker("Chunk mode", selection: $settings.translationChunkMode) {
                    ForEach(TranslationChunkMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper("Parallel chunks: \(settings.translationParallelism)", value: $settings.translationParallelism, in: 1...4)
            } header: {
                SettingsSectionHeader("Batching")
            } footer: {
                SettingsFootnote(
                    "Subtitles are translated in chunks. Faster uses larger chunks; Safer uses smaller ones. More parallel chunks finish sooner but send more requests at once."
                )
            }

            Section {
                // A bare TextEditor is a square white patch on the grouped
                // card. Hiding its own background and drawing the field
                // surface here (the same one the Appearance preview uses)
                // gives it the card's corner radius and a hairline edge.
                TextEditor(text: $settings.translationPrompt)
                    .cueFont(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    .accessibilityLabel("Translator prompt")
                Button("Reset Prompt") {
                    settings.resetTranslationPrompt()
                }
            } header: {
                SettingsSectionHeader("Translator prompt")
            } footer: {
                SettingsFootnote("This prompt is combined with required subtitle JSON rules during translation.")
            }
        }
    }
}

// MARK: - Summary

/// The intro summary: whether to write one, how detailed, and which models
/// write it.
struct SummarySettingsPane: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var server: LocalServerConnection

    var body: some View {
        SettingsPaneScaffold(pane: .summary) {
            Section {
                Toggle("Generate an intro summary when each job finishes", isOn: $settings.generateSummary)
                Picker("Detail", selection: $settings.summaryDetail) {
                    ForEach(SummaryDetail.allCases) { detail in
                        Text(detail.label).tag(detail)
                    }
                }
            } header: {
                SettingsSectionHeader("Intro summary")
            } footer: {
                SettingsFootnote("The summary becomes the first cue of exported SRT and VTT files.")
            }

            Section {
                ProviderModelPicker(
                    title: "Summary model",
                    presets: AppSettingPresets.summaryModels,
                    selection: $settings.summaryModel
                )
                if SettingsLocalModels.summaryIsLocal(settings) {
                    if settings.currentTranslationProvider != .local {
                        LocalServerConnectionRows(settings: settings, server: server)
                    }
                    if !server.models.isEmpty {
                        LocalModelPicker(title: "Summary running model", selection: $settings.summaryModel, models: server.models)
                    }
                }

                ProviderModelPicker(
                    title: "Policy fallback",
                    presets: AppSettingPresets.summaryFallbackModels,
                    selection: $settings.summaryFallbackModel
                )
                if SettingsLocalModels.fallbackIsLocal(settings) {
                    if settings.currentTranslationProvider != .local, !SettingsLocalModels.summaryIsLocal(settings) {
                        LocalServerConnectionRows(settings: settings, server: server)
                    }
                    if !server.models.isEmpty {
                        LocalModelPicker(title: "Fallback running model", selection: $settings.summaryFallbackModel, models: server.models)
                    }
                }

                if !settings.isSummaryReady {
                    Label(
                        "Summary model unavailable: \(settings.modelReadinessReason(settings.resolvedSummaryModel)).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                if let fallback = settings.resolvedSummaryFallbackModel, !settings.isModelReady(fallback) {
                    Label("Fallback unavailable: \(settings.modelReadinessReason(fallback)).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                SettingsSectionHeader("Models")
            } footer: {
                SettingsFootnote(
                    "The summary may use the translation model, a different cloud model, or a local/… model. The fallback is attempted only after a policy or safety refusal—not for bad keys, rate limits, outages, or malformed replies. Subtitle text is sent only to the models you select."
                )
            }
        }
    }
}

// MARK: - API keys

/// Provider keys. Cue keeps them in the Keychain, and a key is only used for
/// models from that provider.
struct APIKeysSettingsPane: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        SettingsPaneScaffold(pane: .apiKeys) {
            Section {
                SecureField("OpenAI", text: $settings.openAIAPIKey, prompt: Text("Paste key"))
                SecureField("Anthropic", text: $settings.anthropicAPIKey, prompt: Text("Paste key"))
                SecureField("Google", text: $settings.googleAPIKey, prompt: Text("Paste key"))
                SecureField("OpenRouter", text: $settings.openRouterAPIKey, prompt: Text("Paste key"))
                SecureField("Groq", text: $settings.groqAPIKey, prompt: Text("Paste key"))
                SecureField("Cerebras", text: $settings.cerebrasAPIKey, prompt: Text("Paste key"))
            } header: {
                SettingsSectionHeader("Cloud providers")
            } footer: {
                SettingsFootnote(
                    "Keys are stored in the macOS Keychain. Cue picks the provider, and so the key, from the model name: gpt-… uses OpenAI, claude-… Anthropic, gemini-… Google, openrouter/… OpenRouter, groq/… Groq, and cerebras/… Cerebras. A local/… model needs no key."
                )
            }

            if let error = settings.secretPersistenceError {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        // Clears the same message the main window's "Could Not
                        // Save Data" alert clears.
                        Button("Dismiss") { settings.secretPersistenceError = nil }
                    }
                }
            }
        }
    }
}
