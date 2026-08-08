import AppKit
import SwiftUI

/// Dropdown for the menu-bar item: queue at a glance plus the two controls
/// that matter mid-batch, without bringing the main window forward.
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.menuBarStatusText)
        if let eta = model.queueETAText {
            Text(eta)
        }
        Divider()
        if model.queuePaused {
            Button("Resume Queue") { model.startAllPendingJobs() }
        } else {
            Button("Pause Queue") { model.pauseQueue() }
                .disabled(!model.hasPendingWork && model.menuBarStatusText == "Idle")
        }
        Button("Start All Pending") { model.startAllPendingJobs() }
            .disabled(!model.hasPendingWork)
        Divider()
        Button("Open Cue") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }
}

/// The template glyph shipped in Resources; falls back to an SF Symbol if
/// the bundle copy is ever missing.
struct MenuBarLabel: View {
    var body: some View {
        if let image = Bundle.main.image(forResource: "MenuBarIconTemplate") {
            Image(
                nsImage: {
                    image.isTemplate = true
                    image.size = NSSize(width: 18, height: 18)
                    return image
                }())
        } else {
            Image(systemName: "waveform")
        }
    }
}
