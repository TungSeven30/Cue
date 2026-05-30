import SwiftUI

struct JobConfigurationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Video Translation Pipeline")
                    .font(.title2.bold())

                Text("Local Whisper handles transcription first, then the translated English subtitles are generated with an LLM.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.progress.stage.label)
                            .font(.subheadline.bold())
                        Spacer()
                        Text(model.progress.detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let fraction = model.progress.fraction {
                        ProgressView(value: fraction)
                    } else if model.isBusy {
                        ProgressView()
                    } else {
                        ProgressView(value: 0)
                    }
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source")
                            .font(.headline)
                        Text(model.selectedVideoURL?.path(percentEncoded: false) ?? "No file selected")
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 20)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Language")
                            .font(.headline)
                        TextField("auto", text: $model.settings.sourceLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Whisper")
                            .font(.headline)
                        Picker("Backend", selection: $model.settings.whisperBackend) {
                            ForEach(WhisperBackend.allCases) { backend in
                                Text(backend.label).tag(backend)
                            }
                        }
                        .pickerStyle(.menu)
                        TextField("Whisper model", text: $model.settings.whisperModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                    }
                }
            }
        }
    }
}
