import Combine
import CoreGraphics
import Foundation

/// The palette's live state: what was typed, what it found, and which row is
/// selected. Views bind to it and forward keys; every rule about selection
/// (skip disabled rows, wrap at the ends, keep the selection when the app
/// changes underneath) lives here so it is testable without a window.
@MainActor
final class PaletteController: ObservableObject {
    @Published private(set) var query: String
    @Published private(set) var results: PaletteResults
    @Published private(set) var selectedID: String?
    /// Why the last run was refused ("Nothing is running"). Shown in the
    /// footer until the next keystroke or selection change.
    @Published private(set) var notice: String?
    private(set) var index: PaletteIndex
    /// What `index` was built from; a refresh with an equal snapshot is free.
    private(set) var snapshot: PaletteSnapshot

    /// Speaks a change to VoiceOver. Injected so the controller stays free of
    /// AppKit and tests can read what would have been said.
    private let announce: @MainActor (String) -> Void

    init(
        snapshot: PaletteSnapshot,
        query: String = "",
        announce: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let index = PaletteIndex.build(from: snapshot)
        let results = index.results(for: query)
        self.snapshot = snapshot
        self.index = index
        self.query = query
        self.results = results
        self.selectedID = results.selectableIDs.first
        self.announce = announce
    }

    /// For tests that hand-build an index.
    init(
        index: PaletteIndex,
        query: String = "",
        announce: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let results = index.results(for: query)
        self.snapshot = PaletteSnapshot()
        self.index = index
        self.query = query
        self.results = results
        self.selectedID = results.selectableIDs.first
        self.announce = announce
    }

    var selectedRow: PaletteRowModel? {
        guard let selectedID else { return nil }
        return results.entryRows.first { $0.id == selectedID }
    }

    var selectedEntry: PaletteEntry? { selectedRow?.entry }
    var isCommandsScope: Bool { results.query.scope == .commands }

    /// Typing always restarts at the best match: the row the user selected
    /// for the previous text says nothing about the new text.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        notice = nil
        results = index.results(for: text)
        selectedID = results.selectableIDs.first
        announce(announcementAfterTyping)
    }

    /// The app changed while the palette is open (a job finished, a folder was
    /// added). Rows refresh; the selection stays on the same row when it
    /// still exists. Silent: nothing the user did.
    func refresh(with newSnapshot: PaletteSnapshot) {
        guard newSnapshot != snapshot else { return }
        snapshot = newSnapshot
        update(index: PaletteIndex.build(from: newSnapshot))
    }

    func update(index newIndex: PaletteIndex) {
        index = newIndex
        let fresh = newIndex.results(for: query)
        if fresh != results { results = fresh }
        if let selectedID, fresh.selectableIDs.contains(selectedID) { return }
        selectedID = fresh.selectableIDs.first
    }

    /// ↑/↓ and ⌃P/⌃N wrap around; paging clamps at the ends.
    func moveSelection(by delta: Int, wrapping: Bool = true) {
        let ids = results.selectableIDs
        notice = nil
        guard !ids.isEmpty else {
            selectedID = nil
            return
        }
        guard let current = selectedID.flatMap({ ids.firstIndex(of: $0) }) else {
            selectedID = delta >= 0 ? ids.first : ids.last
            announceSelection()
            return
        }
        let count = ids.count
        let target = wrapping ? ((current + delta) % count + count) % count : min(max(current + delta, 0), count - 1)
        if ids[target] != selectedID {
            selectedID = ids[target]
            announceSelection()
        }
    }

    func selectFirst() {
        notice = nil
        if selectedID != results.selectableIDs.first {
            selectedID = results.selectableIDs.first
            announceSelection()
        }
    }

    func selectLast() {
        notice = nil
        if selectedID != results.selectableIDs.last {
            selectedID = results.selectableIDs.last
            announceSelection()
        }
    }

    /// Hover and click. Disabled rows never take the selection.
    func select(id: String) {
        guard results.selectableIDs.contains(id), id != selectedID else { return }
        notice = nil
        selectedID = id
    }

    /// The pointer is over a row. Only real pointer movement selects: a list
    /// that scrolls under a resting pointer (arrow keys, a new result set)
    /// reports the same position and must not steal the selection back from
    /// the keyboard. The first report only records where the pointer is.
    func hover(id: String, at point: CGPoint) {
        defer { lastPointer = point }
        guard let last = lastPointer else { return }
        guard abs(point.x - last.x) + abs(point.y - last.y) >= Self.pointerSlop else { return }
        select(id: id)
    }

    private static let pointerSlop: CGFloat = 1.5
    private var lastPointer: CGPoint?

    /// The row a refused run explains itself on.
    func refuse(_ reason: String) {
        notice = reason
        announce(reason)
    }

    /// Footer hint about what typing does next.
    var scopeHint: String {
        isCommandsScope ? "Commands only · delete > to search everything" : "Type > for commands only"
    }

    private var announcementAfterTyping: String {
        guard let row = selectedRow else { return results.summary }
        return "\(results.summary). \(row.accessibilityLabel)"
    }

    private func announceSelection() {
        if let row = selectedRow { announce(row.accessibilityLabel) }
    }
}
