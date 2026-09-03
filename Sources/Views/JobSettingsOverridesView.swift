import SwiftUI

/// Editor for the per-job override set (spec §1.2). Every control's first
/// choice is "Inherit (<current global value>)" so the effective value is
/// always visible. Used for per-job overrides and the watch-folder profile.
struct JobSettingsOverridesView: View {
    let title: String
    @ObservedObject var settings: AppSettingsStore
    @State var overrides: JobSettingsOverrides
    let onSave: (JobSettingsOverrides) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            Form {
                Picker("Source language", selection: $overrides.sourceLanguage) {
                    Text("Inherit (\(globalLanguageLabel))").tag(String?.none)
                    ForEach(AppSettingPresets.transcriptionLanguages) { preset in
                        Text(preset.label).tag(String?.some(preset.value))
                    }
                }
                TextField(
                    "Qwen names & terms (blank inherits)",
                    text: Binding(
                        get: { overrides.qwenContext ?? "" },
                        set: { overrides.qwenContext = $0.isEmpty ? nil : $0 }
                    )
                )
                Picker("Transcription preset", selection: $overrides.transcriptionPreset) {
                    Text("Inherit (\(settings.transcriptionPreset.label))").tag(TranscriptionPreset?.none)
                    ForEach(TranscriptionPreset.allCases.filter { $0 != .custom }) { preset in
                        Text(preset.label).tag(TranscriptionPreset?.some(preset))
                    }
                }
                Picker("Quality preset", selection: $overrides.transcriptionQualityPreset) {
                    Text("Inherit (\(settings.transcriptionQualityPreset.label))").tag(TranscriptionQualityPreset?.none)
                    ForEach(TranscriptionQualityPreset.allCases.filter { $0 != .custom }) { preset in
                        Text(preset.label).tag(TranscriptionQualityPreset?.some(preset))
                    }
                }
                Picker("Translate from", selection: $overrides.translationSourceLanguage) {
                    Text("Inherit (\(globalTranslationSourceLabel))").tag(String?.none)
                    ForEach(AppSettingPresets.translationSourceLanguages) { preset in
                        Text(preset.label).tag(String?.some(preset.value))
                    }
                }
                Picker("Translate to", selection: $overrides.translationTargetLanguage) {
                    Text("Inherit (\(globalTargetLabel))").tag(String?.none)
                    ForEach(AppSettingPresets.translationTargetLanguages) { preset in
                        Text(preset.label).tag(String?.some(preset.value))
                    }
                }
                Picker("Translation LLM", selection: $overrides.openAIModel) {
                    Text("Inherit (\(globalModelLabel))").tag(String?.none)
                    ForEach(AppSettingPresets.translationModels) { preset in
                        Text(preset.label).tag(String?.some(preset.value))
                    }
                    if let model = overrides.openAIModel,
                        !AppSettingPresets.translationModels.contains(where: { $0.value == model })
                    {
                        Text(model).tag(String?.some(model))
                    }
                }
                Picker("Auto-translate", selection: $overrides.autoTranslate) {
                    Text("Inherit (\(settings.autoTranslateAfterTranscription ? "On" : "Off"))").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
                Picker("Intro summary", selection: $overrides.generateSummary) {
                    Text("Inherit (\(settings.generateSummary ? "On" : "Off"))").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button("Reset to Inherit All") { overrides = JobSettingsOverrides() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(overrides)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 420)
    }

    private var globalLanguageLabel: String {
        AppSettingPresets.transcriptionLanguages.first { $0.value == settings.sourceLanguage }?.label
            ?? settings.sourceLanguage
    }

    private var globalTargetLabel: String {
        AppSettingPresets.translationTargetLanguages.first { $0.value == settings.translationTargetLanguage }?.label
            ?? settings.translationTargetLanguage
    }

    private var globalTranslationSourceLabel: String {
        AppSettingPresets.translationSourceLanguages.first { $0.value == settings.translationSourceLanguage }?.label
            ?? settings.translationSourceLanguage
    }

    private var globalModelLabel: String {
        if TranslationProvider.infer(from: settings.openAIModel) == .local {
            return "Local server"
        }
        return AppSettingPresets.translationModels.first { $0.value == settings.openAIModel }?.label
            ?? settings.openAIModel
    }
}
