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
        .sheet(isPresented: $model.isShowingBurnInSheet) {
            BurnInOptionsView(model: model)
        }
        .sheet(item: $model.subtitleLoadRequest) { request in
            SubtitleSlotPickerView(request: request)
                .environmentObject(model)
        }
        .sheet(
            item: Binding(
                get: { model.overridesEditorJobID.flatMap { id in model.jobs.first { $0.id == id } } },
                set: { model.overridesEditorJobID = $0?.id }
            )
        ) { job in
            JobSettingsOverridesView(
                title: "Job Settings — \(job.title)",
                settings: model.settings,
                overrides: job.overrides
            ) { model.setOverrides($0, for: job.id) }
        }
        .alert(
            "Could Not Save Data",
            isPresented: Binding(
                get: { storageError != nil },
                set: { if !$0 { clearStorageError() } }
            )
        ) {
            Button("OK") { clearStorageError() }
        } message: {
            Text(storageError ?? "The latest data is still in memory.")
        }
    }

    private var storageError: String? {
        model.persistenceError ?? model.settings.secretPersistenceError
    }

    private func clearStorageError() {
        model.persistenceError = nil
        model.settings.secretPersistenceError = nil
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
                    // .help on the Label, not the Button: tooltips on
                    // toolbar Buttons are unreliable on macOS.
                    .help(model.primaryActionHelp)
            }
            .disabled(!model.canPerformPrimaryAction)

            Button {
                model.selectVideo()
            } label: {
                Label("Add Files", systemImage: "folder.badge.plus")
                    .help("Add one or more video or audio files as jobs")
            }

            Button {
                model.startTranscription(force: true)
            } label: {
                Label("Retry Transcribe", systemImage: "arrow.clockwise")
                    .help("Transcribe this video again from scratch")
            }
            .disabled(!model.canTranscribe)

            Button {
                model.isPlayerVisible.toggle()
            } label: {
                Label("Video Preview", systemImage: model.isPlayerVisible ? "play.rectangle.fill" : "play.rectangle")
                    .help(model.isPlayerVisible ? "Hide the video preview" : "Show the video preview")
            }
            .disabled(model.currentJob == nil)

            if model.canCancel {
                Button(role: .destructive) {
                    model.cancelActiveJob()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help("Stop all running jobs and pause the queue")
            }
        }
    }
}
