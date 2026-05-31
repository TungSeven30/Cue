import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Backend", selection: $settings.whisperBackend) {
                    ForEach(WhisperBackend.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                TextField("Source language", text: $settings.sourceLanguage)
                TextField("Preferred model", text: $settings.whisperModel)
            } header: {
                Label("Transcription", systemImage: "waveform")
            } footer: {
                Text("Use a language code like `ja`, `zh`, or `ko`, or `auto` to detect it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("OpenAI model", text: $settings.openAIModel)
                SecureField("OpenAI API key", text: $settings.openAIAPIKey)
            } header: {
                Label("Translation", systemImage: "character.bubble")
            } footer: {
                Text("The API key is stored securely in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
