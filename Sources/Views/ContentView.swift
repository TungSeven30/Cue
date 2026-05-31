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
                model.selectVideo()
            } label: {
                Label("Open Video", systemImage: "folder")
            }
            .help("Open a video or audio file")

            Button {
                model.startTranscription()
            } label: {
                Label("Transcribe", systemImage: "waveform")
            }
            .disabled(!model.canTranscribe)
            .help("Transcribe the selected video locally")

            Button {
                model.startTranslation()
            } label: {
                Label("Translate", systemImage: "character.bubble")
            }
            .disabled(!model.canTranslate)
            .help("Translate the transcript into English")

            Menu {
                Button("Original Transcript") { model.exportTranscript() }
                    .disabled(model.transcriptSegments.isEmpty)
                Button("English Translation") { model.exportTranslation() }
                    .disabled(model.translatedSegments.isEmpty)
                Button("Bilingual Captions") { model.exportBilingual() }
                    .disabled(model.translatedSegments.isEmpty)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .disabled(model.transcriptSegments.isEmpty)
            .help("Export subtitles as .srt")

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
}
