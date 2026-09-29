import Foundation
import Testing

@testable import Cue

/// What the sidebar does with the selection its List reports back after a
/// folder closes (see `SidebarSelection`).
struct SidebarSelectionTests {
    private let visible = UUID()
    private let other = UUID()
    private let hiddenOne = UUID()
    private let hiddenTwo = UUID()

    private func accepted(current: Set<UUID>, proposed: Set<UUID>, hidden: Set<UUID>) -> Set<UUID>? {
        SidebarSelection.accepted(current: current, proposed: proposed) { hidden.contains($0) }
    }

    @Test func aListEchoWithoutTheHiddenJobsIsIgnored() {
        let hidden: Set = [hiddenOne, hiddenTwo]
        #expect(accepted(current: [hiddenOne], proposed: [], hidden: hidden) == nil)
        #expect(accepted(current: [hiddenOne, hiddenTwo], proposed: [], hidden: hidden) == nil)
        #expect(accepted(current: [visible, hiddenOne], proposed: [visible], hidden: hidden) == nil)
        #expect(accepted(current: [visible, hiddenOne, hiddenTwo], proposed: [visible], hidden: hidden) == nil)
    }

    @Test func clickingAnotherRowReplacesTheSelectionIncludingHiddenJobs() {
        #expect(accepted(current: [hiddenOne], proposed: [other], hidden: [hiddenOne]) == [other])
        #expect(accepted(current: [visible, hiddenOne], proposed: [other], hidden: [hiddenOne]) == [other])
    }

    @Test func deselectingAVisibleRowIsHonoured() {
        #expect(accepted(current: [visible, other], proposed: [visible], hidden: []) == [visible])
        #expect(accepted(current: [visible], proposed: [], hidden: []) == [])
        #expect(accepted(current: [visible, hiddenOne], proposed: [hiddenOne], hidden: [hiddenOne]) == [hiddenOne])
    }

    @Test func clearingEverythingWhileARowIsVisibleIsHonoured() {
        #expect(accepted(current: [visible, hiddenOne], proposed: [], hidden: [hiddenOne]) == [])
    }

    @Test func extendingTheSelectionIsHonoured() {
        #expect(accepted(current: [visible], proposed: [visible, other], hidden: []) == [visible, other])
        #expect(
            accepted(current: [visible, hiddenOne], proposed: [visible, other], hidden: [hiddenOne])
                == [visible, other])
    }

    @Test func anUnchangedSelectionPassesThrough() {
        #expect(accepted(current: [visible], proposed: [visible], hidden: []) == [visible])
        #expect(accepted(current: [hiddenOne], proposed: [hiddenOne], hidden: [hiddenOne]) == [hiddenOne])
        #expect(accepted(current: [], proposed: [], hidden: []) == [])
    }

    @Test func withNothingHiddenEverythingIsHonoured() {
        #expect(accepted(current: [visible, other], proposed: [], hidden: []) == [])
        #expect(accepted(current: [visible, other], proposed: [other], hidden: []) == [other])
    }
}
