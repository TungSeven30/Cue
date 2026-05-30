import AppKit
import SwiftUI

@main
struct WhisperDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("WhisperDesk", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Video...") {
                    model.selectVideo()
                }
                .keyboardShortcut("o")

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

        Settings {
            SettingsView(settings: model.settings)
                .frame(width: 560, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
