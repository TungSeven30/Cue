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
        .sheet(isPresented: $model.isShowingExportSheet) {
            ExportOptionsView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // The primary action shows its title so the workflow step is
            // always readable, not guessed from an icon.
            Button {
                model.performPrimaryAction()
            } label: {
                Label(model.primaryActionTitle, systemImage: model.primaryActionSystemImage)
                    .labelStyle(.titleAndIcon)
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

            Button {
                model.isShowingExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.transcriptSegments.isEmpty)
            .help("Choose documents, formats, and file name to export")

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
