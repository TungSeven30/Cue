import AppKit
import Combine
import SwiftUI

// The ⌘K palette: a dimmed backdrop and a floating panel over the main window.
// All decisions (what matches, what is selectable, what a row says, what runs)
// live in the pure Models/AppModel layers; this file only draws them and
// forwards keys.

// MARK: - Overlay

/// Shown by `ContentView` while `model.isShowingCommandPalette` is true.
struct CommandPaletteOverlay: View {
    let model: AppModel
    @StateObject private var controller: PaletteController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cueTextScale) private var scale

    init(model: AppModel, initialQuery: String = "") {
        self.model = model
        // The autoclosure runs once, when the overlay first appears; later
        // re-inits (every model change re-evaluates ContentView) skip it.
        _controller = StateObject(
            wrappedValue: PaletteController(
                snapshot: model.makePaletteSnapshot(),
                query: initialQuery,
                announce: PaletteAnnouncer.post
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let top = max(48, proxy.size.height * 0.14)
            ZStack(alignment: .top) {
                Color.black.opacity(colorScheme == .dark ? 0.42 : 0.24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityHidden(true)

                CommandPalettePanel(
                    controller: controller,
                    maxListHeight: max(140, min(460, proxy.size.height - top - 150 * min(scale, 1.3))),
                    onRun: run,
                    onClose: close,
                    onResignKey: close
                )
                .frame(width: min(620, max(320, proxy.size.width - 48)))
                .padding(.top, top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // `objectWillChange` fires before the mutation, so hop to the next
        // main-queue turn to read the new state, and throttle so a steady
        // stream of progress updates refreshes a few times a second at most.
        .onReceive(
            model.objectWillChange
                .receive(on: DispatchQueue.main)
                .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            controller.refresh(with: model.makePaletteSnapshot())
        }
    }

    // MARK: Actions

    private func close() {
        model.isShowingCommandPalette = false
    }

    /// Re-checks the row against the live app, then closes and runs it. A row
    /// that stopped being runnable keeps the palette open and says why.
    private func run(_ row: PaletteRowModel) {
        let target = row.entry.target
        if let reason = model.paletteUnavailabilityReason(for: target) {
            controller.refuse(reason)
            return
        }
        close()
        // One beat so the palette is gone (and focus is back) before a
        // command opens its own panel or sheet.
        let model = model
        let openSettings = openSettings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if model.performPaletteTarget(target) == .openSettings {
                openSettings()
            }
        }
    }
}

/// Speaks palette changes to VoiceOver.
enum PaletteAnnouncer {
    @MainActor
    static func post(_ text: String) {
        guard !text.isEmpty, let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

// MARK: - Panel

struct CommandPalettePanel: View {
    @ObservedObject var controller: PaletteController
    let maxListHeight: CGFloat
    let onRun: (PaletteRowModel) -> Void
    let onClose: () -> Void
    let onResignKey: () -> Void

    @Environment(\.cueTextScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(DisplayPreferenceKey.typography) private var typography: AppTypography = .system
    @ViewState private var measuredListHeight: CGFloat?

    private static let cornerRadius: CGFloat = 12
    private static let listTopID = "palette.top"

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            if let empty = controller.results.emptyState {
                emptyView(empty)
            } else {
                resultsList
            }
            Divider()
            footer
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.5)
        )
        // Layered, low-opacity shadows read as depth; one heavy shadow reads as a smudge.
        .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
        .shadow(color: .black.opacity(0.20), radius: 28, y: 14)
        .coordinateSpace(name: PaletteSpace.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    // MARK: Search field

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .cueFont(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            PaletteSearchField(
                text: Binding(get: { controller.query }, set: { controller.setQuery($0) }),
                placeholder: "Search jobs, commands, and settings",
                accessibilityLabel: "Search jobs, commands, and settings",
                accessibilityHelp: "Up and Down choose a result. Return runs it. Escape closes.",
                fontSize: CueFont.pointSize(for: .title2) * scale,
                design: typography.systemDesign,
                onMove: { controller.moveSelection(by: $0, wrapping: abs($0) == 1) },
                onSubmit: submit,
                onCancel: onClose,
                onResignKey: onResignKey
            )
            .frame(height: 26 * scale)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit() {
        if let row = controller.selectedRow {
            onRun(row)
        } else if let first = controller.results.entryRows.first {
            // Everything found is unavailable: say why for the best match.
            controller.refuse(first.subtitle)
        }
    }

    // MARK: Results

    private var resultsList: some View {
        let rows = controller.results.rows
        let estimate = rows.reduce(CGFloat(12)) { total, row in
            total + (row.entryRow == nil ? 28 : 44) * min(scale, 1.5)
        }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.listTopID)
                    ForEach(rows) { row in
                        switch row {
                        case .header(let header):
                            PaletteHeaderView(header: header)
                        case .entry(let model):
                            PaletteRowView(
                                row: model,
                                isSelected: model.id == controller.selectedID,
                                onHover: { controller.hover(id: model.id, at: $0) },
                                onRun: { onRun(model) }
                            )
                            .id(model.id)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: PaletteListHeightKey.self, value: geometry.size.height)
                    }
                )
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(measuredListHeight ?? estimate, maxListHeight))
            .onPreferenceChange(PaletteListHeightKey.self) { measuredListHeight = $0 }
            .onChange(of: controller.selectedID) { _, id in
                guard let id else { return }
                // The first row sits under its section header: show the header too.
                let isFirst = controller.results.selectableIDs.first == id
                proxy.scrollTo(isFirst ? Self.listTopID : id)
            }
            .onChange(of: controller.query) {
                proxy.scrollTo(Self.listTopID, anchor: .top)
            }
        }
    }

    private func emptyView(_ state: PaletteEmptyState) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .cueFont(.title2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(state.title)
                .cueFont(.headline)
            Text(state.message)
                .cueFont(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 132)
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                footerLeading
                Spacer(minLength: 8)
                footerScope
            }
            VStack(alignment: .leading, spacing: 2) {
                footerLeading
                footerScope
            }
        }
        .cueFont(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footerLeading: some View {
        if let notice = controller.notice {
            Label {
                Text(notice).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            .lineLimit(2)
        } else {
            // Key hints are in the field's accessibility help; reading them
            // again as a separate element is noise.
            Text("↑↓ to navigate  ·  ⏎ to open  ·  esc to close")
                .accessibilityHidden(true)
        }
    }

    private var footerScope: some View {
        Text(controller.scopeHint)
    }
}

private enum PaletteSpace {
    static let panel = "palette.panel"
}

private struct PaletteListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Rows

struct PaletteHeaderView: View {
    let header: PaletteHeader

    var body: some View {
        HStack {
            Text(header.title)
                .cueFont(.subheadline, weight: .semibold)
            Spacer(minLength: 8)
            if header.isCapped {
                Text("\(header.shown) of \(header.total)")
                    .cueFont(.subheadline, monospacedDigit: true)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            header.isCapped ? "\(header.title), showing \(header.shown) of \(header.total)" : header.title
        )
        .accessibilityAddTraits(.isHeader)
    }
}

struct PaletteRowView: View {
    let row: PaletteRowModel
    let isSelected: Bool
    let onHover: (CGPoint) -> Void
    let onRun: () -> Void

    @Environment(\.cueTextScale) private var scale

    private static let rowRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.entry.symbol)
                .cueFont(.body)
                .foregroundStyle(iconStyle)
                .frame(width: 22 * scale)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(PaletteAttributed.string(for: row.entry.title, ranges: row.titleRanges))
                    .cueFont(.body)
                    .foregroundStyle(titleStyle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !row.subtitle.isEmpty {
                    Text(PaletteAttributed.string(for: row.subtitle, ranges: row.subtitleRanges))
                        .cueFont(.subheadline)
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 40, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onRun)
        .onContinuousHover(coordinateSpace: .named(PaletteSpace.panel)) { phase in
            if case .active(let point) = phase { onHover(point) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onRun)
    }

    @ViewBuilder
    private var trailing: some View {
        if let shortcut = row.entry.shortcut {
            Text(shortcut.glyphs)
                .cueFont(.subheadline)
                .foregroundStyle(subtitleStyle)
                .lineLimit(1)
                .fixedSize()
        } else if let action = row.entry.actionLabel {
            Text(action)
                .cueFont(.subheadline)
                .foregroundStyle(subtitleStyle)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // Selected rows use the system's selection pair, which keeps its contrast
    // for every accent color. A disabled row dims its title and icon; its
    // subtitle carries the reason and stays at full secondary contrast.
    private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

    private var iconStyle: Color {
        if isSelected { return selectedText }
        if !row.isSelectable { return Color.secondary.opacity(0.6) }
        return row.entry.jobStatus?.tint ?? Color.secondary
    }

    private var titleStyle: Color {
        if isSelected { return selectedText }
        return row.isSelectable ? Color.primary : Color.secondary
    }

    private var subtitleStyle: Color {
        isSelected ? selectedText.opacity(0.9) : Color.secondary
    }
}

enum PaletteAttributed {
    /// `text` with the engine's ranges in bold. Bold, not color, so the
    /// emphasis survives on the accent-filled selected row.
    static func string(for text: String, ranges: [Range<Int>]) -> AttributedString {
        var result = AttributedString()
        for segment in PaletteHighlight.segments(for: text, ranges: ranges) {
            var part = AttributedString(segment.text)
            if segment.isEmphasized {
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(part)
        }
        return result
    }
}

extension AppTypography {
    /// The AppKit equivalent of `design`, for the palette's `NSTextField`.
    var systemDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .system: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

// MARK: - Search field

/// A borderless `NSTextField` because SwiftUI's `TextField` offers no reliable
/// way to see ↑, ↓, ⌃N, ⌃P, Return, Escape, and Tab before the text system
/// swallows them. Cocoa already maps ⌃N/⌃P to `moveDown:`/`moveUp:`, and
/// `doCommandBy` is skipped while an input method is composing, so Japanese
/// or Chinese input keeps working.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityHelp: String
    let fontSize: CGFloat
    let design: NSFontDescriptor.SystemDesign?
    /// Selection delta: ±1 for the arrow keys, ±6 for Page Up / Page Down.
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onResignKey: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PaletteTextField {
        let field = PaletteTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.allowsEditingTextAttributes = false
        field.setAccessibilityRole(.textField)
        field.onResignKey = { context.coordinator.parent.onResignKey() }
        return field
    }

    func updateNSView(_ field: PaletteTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.font = Self.font(size: fontSize, design: design)
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityHelp(accessibilityHelp)
    }

    static func font(size: CGFloat, design: NSFontDescriptor.SystemDesign?) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let design, let descriptor = base.fontDescriptor.withDesign(design),
            let font = NSFont(descriptor: descriptor, size: size)
        else { return base }
        return font
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField

        init(_ parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Composition owns Return and Escape until the input method commits.
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
                parent.onMove(-6)
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
                parent.onMove(6)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                // A dialog with one field and a list the keys already drive:
                // Tab has nowhere useful to go, so it stays put.
                break
            default:
                return false
            }
            return true
        }
    }
}

/// Takes focus when it joins a window, remembers what had focus before, and
/// gives it back when it leaves, so ⌘K, Esc returns you to where you were.
final class PaletteTextField: NSTextField {
    var onResignKey: (() -> Void)?
    private weak var hostWindow: NSWindow?
    private weak var previousResponder: NSResponder?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            hostWindow = window
            previousResponder = Self.owner(of: window.firstResponder)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        } else {
            NotificationCenter.default.removeObserver(self)
            let window = hostWindow
            let target = previousResponder
            DispatchQueue.main.async {
                guard let window, let view = target as? NSView, view.window === window else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }

    /// While a text field is being edited the first responder is its shared
    /// field editor; focus belongs to the field that owns it.
    private static func owner(of responder: NSResponder?) -> NSResponder? {
        if let textView = responder as? NSTextView, textView.isFieldEditor, let owner = textView.delegate as? NSView {
            return owner
        }
        return responder
    }
}
