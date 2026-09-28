import AppKit
import SwiftUI
@testable import Cue

/// Opt-in renders of real SwiftUI views for visual review. Set
/// `CUE_SNAPSHOT_DIR` to a folder and run `script/run_tests.sh`; tests gated on
/// `ViewSnapshot.isEnabled` write PNGs there and are skipped otherwise.
///
/// The view is hosted in an off-screen window and captured through the window
/// server (`screencapture -l`), which — unlike `cacheDisplay` — includes
/// sidebar vibrancy and table rows. Callers must build models over temp
/// stores and suite defaults: nothing here may touch the user's jobs,
/// settings, or Keychain.
@MainActor
enum ViewSnapshot {
    nonisolated static var isEnabled: Bool {
        guard let path = ProcessInfo.processInfo.environment["CUE_SNAPSHOT_DIR"] else { return false }
        return !path.isEmpty
    }

    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["CUE_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Renders `content` at `size` points and returns the PNG's URL, or nil
    /// when snapshots are disabled.
    @discardableResult
    static func capture<Content: View>(
        _ content: Content,
        name: String,
        size: CGSize,
        colorScheme: ColorScheme = .light
    ) async throws -> URL? {
        guard let directory = outputDirectory else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let root =
            content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle(host)

        let url = directory.appendingPathComponent(name).appendingPathExtension("png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        _ = await process.waitForTermination()
        return url
    }

    /// Lets AppKit populate lazy table rows and finish layout passes.
    private static func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        }
    }
}
