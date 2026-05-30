import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedJobID },
            set: { model.selectJob($0) }
        )) {
            Section("Jobs") {
                if model.jobs.isEmpty {
                    Text("No jobs")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.jobs) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title)
                                .lineLimit(1)
                            Text(job.status.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(job.id)
                    }
                }
            }

            Section("Workflow") {
                LabeledContent("Status", value: model.status)
                LabeledContent("Setup", value: model.diagnosticsSummary)
                LabeledContent("Backend", value: model.currentJob?.settings.whisperBackend.label ?? model.settings.whisperBackend.label)
                LabeledContent("Translator", value: model.currentJob?.settings.openAIModel ?? model.settings.openAIModel)
            }

            Section("Actions") {
                Button("Open Video...") {
                    model.selectVideo()
                }
                .keyboardShortcut("o")

                Button("Run System Check") {
                    model.runDiagnostics()
                }
                .disabled(model.isRunningDiagnostics)

                Button("Transcribe") {
                    model.startTranscription()
                }
                .disabled(!model.canTranscribe)

                Button("Translate") {
                    model.startTranslation()
                }
                .disabled(!model.canTranslate)

                Button("Cancel") {
                    model.cancelActiveJob()
                }
                .disabled(!model.canCancel)

                Button("Export Transcript SRT") {
                    model.exportTranscript()
                }
                .disabled(model.transcriptSegments.isEmpty)

                Button("Export Translation SRT") {
                    model.exportTranslation()
                }
                .disabled(model.translatedSegments.isEmpty)

                Button("Export Bilingual SRT") {
                    model.exportBilingual()
                }
                .disabled(model.translatedSegments.isEmpty)
            }
        }
        .listStyle(.sidebar)
    }
}
