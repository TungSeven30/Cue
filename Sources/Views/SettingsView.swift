import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $settings.transcriptionPreset) {
                    ForEach(TranscriptionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Picker("Quality", selection: $settings.transcriptionQualityPreset) {
                    ForEach(TranscriptionQualityPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                presetPicker(
                    "Language",
                    presets: AppSettingPresets.transcriptionLanguages,
                    selection: $settings.sourceLanguage
                )
                Toggle("Start jobs automatically when files are added", isOn: $settings.autoStartAddedJobs)
                Toggle("Show advanced transcription controls", isOn: $settings.showAdvancedControls)
                if settings.showAdvancedControls {
                    backendPicker
                    TextField("Custom language code", text: $settings.sourceLanguage)
                    presetPicker(
                        "Whisper model",
                        presets: AppSettingPresets.whisperModels(for: settings.whisperBackend),
                        selection: $settings.whisperModel
                    )
                    TextField("Custom Whisper model", text: $settings.whisperModel)
                    Toggle("Clean audio before transcription", isOn: $settings.preprocessAudio)
                        .help("Cleans audio with an ffmpeg filter before transcription; skipped when ffmpeg is not installed")
                    Toggle("Voice activity detection", isOn: $settings.vadFilter)
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

                presetPicker(
                    "LLM",
                    presets: AppSettingPresets.translationModels,
                    selection: $settings.openAIModel
                )
                TextField("Custom OpenAI model", text: $settings.openAIModel)
                Picker("Chunk mode", selection: $settings.translationChunkMode) {
                    ForEach(TranslationChunkMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper("Parallel chunks: \(settings.translationParallelism)", value: $settings.translationParallelism, in: 1...4)
                SecureField("OpenAI API key", text: $settings.openAIAPIKey)
                SecureField("Anthropic API key", text: $settings.anthropicAPIKey)
                SecureField("Google API key", text: $settings.googleAPIKey)
                TextField("Local server URL", text: $settings.localTranslationEndpoint)
            } header: {
                Label("Translation", systemImage: "character.bubble")
            } footer: {
                Text("Use any OpenAI (gpt-…), Anthropic (claude-…), or Google (gemini-…) model — the provider and API key are chosen from the model name. Keys are stored in the Keychain. A local/… model needs no key — it talks to the OpenAI-compatible server at the Local server URL (LM Studio, Ollama).")
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
