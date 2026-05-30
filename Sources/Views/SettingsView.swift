import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Whisper") {
                Picker("Backend", selection: $settings.whisperBackend) {
                    ForEach(WhisperBackend.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                TextField("Source language (auto, ja, zh, ko...)", text: $settings.sourceLanguage)
                TextField("Preferred Whisper model", text: $settings.whisperModel)
            }

            Section("Translation") {
                TextField("OpenAI model", text: $settings.openAIModel)
                SecureField("OpenAI API key", text: $settings.openAIAPIKey)
            }

            Section("Notes") {
                Text("Recommended setup for Apple Silicon is ffmpeg plus the `mlx-whisper` Python package. Translation uses the OpenAI Responses API with your configured model.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
