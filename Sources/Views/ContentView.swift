import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            DetailView(model: model, playerController: model.playerController)
                .toolbar { toolbarContent }
        }
        .sheet(isPresented: $model.isShowingExportSheet) {
            ExportOptionsView(model: model)
        }
        .sheet(isPresented: $model.isShowingSetupGuide) {
            SetupGuideView(model: model)
        }
        .sheet(item: Binding(
            get: { model.overridesEditorJobID.flatMap { id in model.jobs.first { $0.id == id } } },
            set: { model.overridesEditorJobID = $0?.id }
        )) { job in
            JobSettingsOverridesView(
                title: "Job Settings — \(job.title)",
                settings: model.settings,
                overrides: job.overrides
            ) { model.setOverrides($0, for: job.id) }
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
                model.isPlayerVisible.toggle()
            } label: {
                Label("Video Preview", systemImage: model.isPlayerVisible ? "play.rectangle.fill" : "play.rectangle")
            }
            .disabled(model.currentJob == nil)
            .help(model.isPlayerVisible ? "Hide the video preview" : "Show the video preview")

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
