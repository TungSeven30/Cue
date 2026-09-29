import AppKit
import SwiftUI

/// The ⌘K menu item. It lives in the View menu, beside the sidebar and
/// toolbar items, and stays in its own `Commands` value so `CueApp` only
/// needs one line to adopt it.
struct CommandPaletteMenuCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            // The title stays put while the palette is open: a menu item
            // that renames itself is harder to find and to announce.
            Button("Search Commands and Jobs…") {
                toggle()
            }
            .keyboardShortcut("k")
            .disabled(!model.canToggleCommandPalette)
        }
    }

    private func toggle() {
        if model.isShowingCommandPalette {
            model.isShowingCommandPalette = false
            return
        }
        // The palette is drawn over the main window, so make sure there is
        // one, in front: the same two calls the menu bar item makes. From
        // Settings or with the window closed, ⌘K brings Cue's window up.
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        model.toggleCommandPalette()
    }
}
