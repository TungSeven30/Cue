import AppKit
import Sparkle
import SwiftUI

@main
struct CueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    /// Sparkle updater; one instance for the app's lifetime. Feed URL and
    /// public key come from Info.plist (SUFeedURL / SUPublicEDKey).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // AppModel is created lazily on first render, so migrating here keeps
    // the WhisperDesk-era data move ahead of every disk and defaults read.
    init() {
        PackagedInferenceSelfTest.runAndExitIfRequested()
        // The CLI reads settings and job data too, so the one-time migration
        // must run before it — a cron job as the first launch after the
        // rename would otherwise see empty defaults and an empty job store.
        LegacyMigration.run()
        // Exits the process rather than returning when it recognises its
        // arguments, so nothing below runs in a headless invocation — no
        // windows, no watch folders, no queue, no orphan sweep.
        CueCommandLine.runAndExitIfRequested()
        OrphanReaper.reap()
    }

    var body: some Scene {
        // A single-window scene: File > New Window on a WindowGroup would
        // open extra windows sharing this one AppModel and AVPlayer.
        Window("Cue", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(after: .newItem) {
                Button(model.primaryActionTitle) {
                    model.performPrimaryAction()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canPerformPrimaryAction)

                Button("Add Files…") {
                    model.selectVideo()
                }
                .keyboardShortcut("o")

                Button("Add from URL…") {
                    model.promptForRemoteMedia()
                }
                .keyboardShortcut("l")

                Button("Load Subtitles…") {
                    model.presentSubtitleLoadPanel()
                }
                .disabled(!model.canLoadSubtitles)
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Start All") {
                    model.startAllPendingJobs()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.hasPendingWork && !model.queuePaused)

                Button("Transcribe") {
                    model.startTranscription()
                }
                .keyboardShortcut("r")
                .disabled(!model.canTranscribe)

                Button("Translate") {
                    model.startTranslation()
                }
                .keyboardShortcut("t")
                .disabled(!model.canTranslate)

                Button("Write Intro Summary") {
                    model.generateSummaryNow()
                }
                .disabled(!model.canGenerateSummary)

                // Stops both pipeline lanes and pauses the queue; the label
                // says so, because "cancel the current job" is not what it does.
                Button("Stop All Jobs") {
                    model.cancelActiveJob()
                }
                .keyboardShortcut(".")
                .disabled(!model.canCancel)
            }

            CommandGroup(after: .saveItem) {
                Button("Export Transcript SRT") {
                    model.exportTranscript(format: .srt)
                }
                .disabled(model.transcriptSegments.isEmpty)

                Button("Export \(model.translationExportTitle) SRT") {
                    model.exportTranslation(format: .srt)
                }
                .disabled(model.translatedSegments.isEmpty)

                Button("Export \(model.bilingualExportTitle) SRT") {
                    model.exportBilingual(format: .srt)
                }
                .disabled(model.translatedSegments.isEmpty)

                Button("Export…") {
                    model.isShowingExportSheet = true
                }
                .keyboardShortcut("e")
                .disabled(model.transcriptSegments.isEmpty)

                Button("Export Log…") {
                    model.exportLog()
                }
                .disabled(model.currentJob == nil)
            }
        }

        Settings {
            SettingsView(settings: model.settings)
                .frame(width: 620, height: 780)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Media dropped on the Dock icon, opened with "Open With", or passed to
    /// `open -a Cue` becomes jobs, the same as the file picker.
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenFileRequests.deliver(urls)
    }

    /// A quit mid-batch silently killed hours of transcription or a large
    /// download; ask first. Finished work is already on disk either way.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.current, model.hasActiveWork else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit While Work Is Running?"
        alert.informativeText =
            "Cue is still transcribing, translating, or downloading. Quitting stops that work now; finished jobs are kept and interrupted jobs can be started again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Files opened through the system can arrive before AppModel exists (the
/// delegate gets them during launch); they wait here until it registers.
@MainActor
enum OpenFileRequests {
    private static var handler: (([URL]) -> Void)?
    private static var pending: [URL] = []

    static func deliver(_ urls: [URL]) {
        if let handler {
            handler(urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    static func register(_ newHandler: @escaping ([URL]) -> Void) {
        handler = newHandler
        let queued = pending
        pending.removeAll()
        if !queued.isEmpty {
            newHandler(queued)
        }
    }
}
