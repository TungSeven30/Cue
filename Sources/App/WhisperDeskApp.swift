import AppKit
import SwiftUI

@main
struct WhisperDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A single-window scene: File > New Window on a WindowGroup would
        // open extra windows sharing this one AppModel and AVPlayer.
        Window("WhisperDesk", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .commands {
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
