import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            DetailView(model: model)
                .toolbar { toolbarContent }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.performPrimaryAction()
            } label: {
                Label(model.primaryActionTitle, systemImage: model.primaryActionSystemImage)
            }
            .disabled(!model.canPerformPrimaryAction)
            .help(model.primaryActionTitle)

            Button {
                model.selectVideo()
            } label: {
                Label("Add Files", systemImage: "folder.badge.plus")
            }
            .help("Add one or more video or audio files")

            Button {
                model.startTranscription(force: true)
            } label: {
                Label("Retry Transcribe", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canTranscribe)
            .help("Run transcription again")

            Menu {
                Menu("Original Transcript") {
                    exportFormatButtons { format in
                        model.exportTranscript(format: format)
                    }
                }
                .disabled(model.transcriptSegments.isEmpty)

                Menu(model.translationExportTitle) {
                    exportFormatButtons { format in
                        model.exportTranslation(format: format)
                    }
                }
                .disabled(model.translatedSegments.isEmpty)

                Menu(model.bilingualExportTitle) {
                    exportFormatButtons { format in
                        model.exportBilingual(format: format)
                    }
                }
                .disabled(model.translatedSegments.isEmpty)

                Divider()

                Button("Export All…") { model.exportAll() }
                    .disabled(model.transcriptSegments.isEmpty)
                Button("Export Log…") { model.exportLog() }
                    .disabled(model.currentJob == nil)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .disabled(model.transcriptSegments.isEmpty)
            .help("Export subtitles and logs")

            if model.canCancel {
                Button(role: .destructive) {
                    model.cancelActiveJob()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help("Cancel the running job")
            }
        }
    }

    @ViewBuilder
    private func exportFormatButtons(action: @escaping (SubtitleExportFormat) -> Void) -> some View {
        ForEach(SubtitleExportFormat.allCases) { format in
            Button(format.label) { action(format) }
        }
    }
}
