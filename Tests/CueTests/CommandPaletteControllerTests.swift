import Combine
import CoreGraphics
import Foundation
import Testing

@testable import Cue

/// Selection rules of the palette: which rows the keyboard can reach, how it
/// wraps, what typing resets, and what gets announced. No window involved.
@MainActor
struct CommandPaletteControllerTests {
    private typealias Fixtures = PaletteFixtures

    @MainActor private final class Spoken {
        var lines: [String] = []
    }

    @MainActor private final class Counter {
        var value = 0
    }

    /// With no jobs and an empty context these five commands are the
    /// runnable ones, in inventory order.
    private let runnableCommands = [
        "command:addFiles", "command:addFromURL", "command:runDiagnostics", "command:openSetupGuide",
        "command:openSettings",
    ]

    private func controller(
        _ query: String = "",
        spoken: Spoken? = nil,
        jobs: [PaletteJobSummary] = [],
        _ configure: (inout PaletteContext) -> Void = { _ in }
    ) -> PaletteController {
        PaletteController(
            snapshot: Fixtures.snapshot(jobs: jobs, configure),
            query: query,
            announce: { spoken?.lines.append($0) }
        )
    }

    // MARK: - Initial selection

    @Test func startsOnTheFirstRunnableRowAndSkipsDisabledOnes() {
        let palette = controller(">")
        #expect(palette.results.selectableIDs == runnableCommands)
        #expect(palette.selectedID == "command:addFiles")
        #expect(palette.selectedEntry?.title == "Add Files…")
        // Disabled commands are listed (with their reasons) but never selected.
        #expect(palette.results.entryCount > palette.results.selectableIDs.count)
    }

    @Test func aPaletteWithNothingRunnableSelectsNothing() {
        let palette = controller("qzxv")
        #expect(palette.selectedID == nil)
        #expect(palette.selectedRow == nil)
        #expect(palette.results.emptyState != nil)
        palette.moveSelection(by: 1)
        #expect(palette.selectedID == nil)
    }

    // MARK: - Moving

    @Test func arrowsWalkRunnableRowsAndWrapAtBothEnds() {
        let palette = controller(">")
        for expected in runnableCommands.dropFirst() {
            palette.moveSelection(by: 1)
            #expect(palette.selectedID == expected)
        }
        palette.moveSelection(by: 1)
        #expect(palette.selectedID == runnableCommands.first)
        palette.moveSelection(by: -1)
        #expect(palette.selectedID == runnableCommands.last)
    }

    @Test func pagingClampsInsteadOfWrapping() {
        let palette = controller(">")
        palette.moveSelection(by: 6, wrapping: false)
        #expect(palette.selectedID == runnableCommands.last)
        palette.moveSelection(by: 6, wrapping: false)
        #expect(palette.selectedID == runnableCommands.last)
        palette.moveSelection(by: -6, wrapping: false)
        #expect(palette.selectedID == runnableCommands.first)
    }

    @Test func selectionChangesAreAnnouncedButRepeatsAreNot() {
        let spoken = Spoken()
        let palette = controller(">", spoken: spoken)
        palette.moveSelection(by: 1)
        #expect(spoken.lines == ["Add from URL…, File menu, Command, Shortcut Command L"])
        palette.selectFirst()
        #expect(spoken.lines.count == 2)
        palette.selectFirst()
        #expect(spoken.lines.count == 2)
        palette.selectLast()
        #expect(spoken.lines.last == "Open Settings…, Cue menu, Command, Shortcut Command Comma")
        #expect(palette.selectedID == "command:openSettings")
    }

    // MARK: - Typing

    @Test func typingRestartsAtTheBestMatchAndAnnouncesTheCount() {
        let spoken = Spoken()
        let palette = controller("", spoken: spoken, jobs: [Fixtures.job("Zebra Migration"), Fixtures.job("Keynote")])
        palette.moveSelection(by: 1)
        spoken.lines.removeAll()

        palette.setQuery("zebra")
        #expect(palette.query == "zebra")
        #expect(palette.selectedID?.hasPrefix("job:") == true)
        #expect(spoken.lines.count == 1)
        #expect(spoken.lines.first?.hasPrefix("1 result. Zebra Migration, ") == true)

        palette.setQuery("zebra")
        #expect(spoken.lines.count == 1)

        palette.setQuery("qzxv")
        #expect(palette.selectedID == nil)
        #expect(spoken.lines.last == "No results")
    }

    @Test func aRefusedRunShowsItsReasonUntilTheNextKeystroke() {
        let spoken = Spoken()
        let palette = controller(">", spoken: spoken)
        palette.refuse("Nothing is running")
        #expect(palette.notice == "Nothing is running")
        #expect(spoken.lines == ["Nothing is running"])

        palette.moveSelection(by: 1)
        #expect(palette.notice == nil)

        palette.refuse("Select a job first")
        palette.setQuery(">add")
        #expect(palette.notice == nil)
    }

    @Test func theFooterHintFollowsTheScope() {
        let palette = controller("")
        #expect(!palette.isCommandsScope)
        #expect(palette.scopeHint == "Type > for commands only")
        palette.setQuery(">")
        #expect(palette.isCommandsScope)
        #expect(palette.scopeHint == "Commands only · delete > to search everything")
    }

    // MARK: - Pointer

    @Test func clickAndHoverNeverSelectDisabledOrUnknownRows() throws {
        let palette = controller(">")
        let disabled = try #require(palette.results.entryRows.first { !$0.isSelectable })
        palette.select(id: disabled.id)
        #expect(palette.selectedID == "command:addFiles")
        palette.select(id: "command:nothing")
        #expect(palette.selectedID == "command:addFiles")
        palette.select(id: "command:openSettings")
        #expect(palette.selectedID == "command:openSettings")

        palette.hover(id: disabled.id, at: CGPoint(x: 10, y: 10))
        palette.hover(id: disabled.id, at: CGPoint(x: 60, y: 60))
        #expect(palette.selectedID == "command:openSettings")
    }

    @Test func hoverNeedsRealPointerMovement() {
        let palette = controller(">")
        let target = "command:openSetupGuide"

        // The first report only records where the pointer rests.
        palette.hover(id: target, at: CGPoint(x: 100, y: 100))
        #expect(palette.selectedID == "command:addFiles")
        // Jitter below the slop is not movement.
        palette.hover(id: target, at: CGPoint(x: 100.5, y: 100.5))
        #expect(palette.selectedID == "command:addFiles")
        palette.hover(id: target, at: CGPoint(x: 103, y: 100))
        #expect(palette.selectedID == target)

        // A list that scrolls under a resting pointer must not steal the
        // selection back from the keyboard.
        palette.moveSelection(by: -1)
        let keyboardRow = palette.selectedID
        palette.hover(id: "command:addFiles", at: CGPoint(x: 103, y: 100))
        #expect(palette.selectedID == keyboardRow)
    }

    // MARK: - App changes underneath

    @Test func refreshKeepsTheSelectionWhileItsRowStillRuns() {
        let spoken = Spoken()
        let palette = controller(">", spoken: spoken)
        palette.select(id: "command:runDiagnostics")

        var next = palette.snapshot
        next.context.canPerformPrimaryAction = true
        palette.refresh(with: next)

        #expect(palette.selectedID == "command:runDiagnostics")
        #expect(palette.results.selectableIDs.first == "command:primaryAction")
        // Nothing the user did, so nothing is announced.
        #expect(spoken.lines.isEmpty)
    }

    @Test func refreshMovesOffARowThatStoppedBeingRunnable() {
        let palette = controller(">")
        palette.select(id: "command:runDiagnostics")

        var next = palette.snapshot
        next.context.isRunningDiagnostics = true
        palette.refresh(with: next)

        #expect(palette.selectedID == "command:addFiles")
        #expect(palette.results.entryRows.first { $0.id == "command:runDiagnostics" }?.subtitle == "Already checking")
    }

    @Test func refreshWithAnUnchangedSnapshotChangesNothing() {
        let palette = controller(">")
        let changes = Counter()
        let subscription = palette.objectWillChange.sink { changes.value += 1 }
        palette.refresh(with: palette.snapshot)
        #expect(changes.value == 0)
        subscription.cancel()
    }
}
