import SwiftUI

/// Editor for the five-field override set (spec §1.2). Every control's first
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
                Picker("Translate to", selection: $overrides.translationTargetLanguage) {
                    Text("Inherit (\(settings.translationTargetLanguage))").tag(String?.none)
                    ForEach(AppSettingPresets.translationTargetLanguages) { preset in
                        Text(preset.label).tag(String?.some(preset.value))
                    }
                }
                Picker("Auto-translate", selection: $overrides.autoTranslate) {
                    Text("Inherit (\(settings.autoTranslateAfterTranscription ? "On" : "Off"))").tag(Bool?.none)
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
}
