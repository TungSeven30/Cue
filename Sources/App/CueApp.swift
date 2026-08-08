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
        LegacyMigration.run()
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

                Button("Add Files...") {
                    model.selectVideo()
                }
                .keyboardShortcut("o")

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

                Button("Cancel Current Job") {
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

                Button("Export...") {
                    model.isShowingExportSheet = true
                }
                .keyboardShortcut("e")
                .disabled(model.transcriptSegments.isEmpty)

                Button("Export Log...") {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
