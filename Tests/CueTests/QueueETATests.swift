import Foundation
import Testing
@testable import Cue

@Suite struct QueueETATests {
    @Test func averagesHistoryTimesPendingJobs() {
        #expect(QueueETA.estimate(recentDurations: [100, 200], pendingCount: 2, activeFraction: nil) == 300)
    }

    @Test func activeJobContributesItsRemainder() {
        #expect(QueueETA.estimate(recentDurations: [100], pendingCount: 1, activeFraction: 0.75) == 125)
    }

    @Test func noHistoryMeansNoEstimate() {
        #expect(QueueETA.estimate(recentDurations: [], pendingCount: 3, activeFraction: 0.5) == nil)
    }

    @Test func idleLaneWithNothingPendingMeansNoEstimate() {
        #expect(QueueETA.estimate(recentDurations: [100], pendingCount: 0, activeFraction: nil) == nil)
    }

    @Test func garbageDurationsAreIgnored() {
        #expect(QueueETA.estimate(recentDurations: [-5, .infinity, 100], pendingCount: 1, activeFraction: nil) == 100)
    }

    @Test func outOfRangeFractionIsClamped() {
        #expect(QueueETA.estimate(recentDurations: [100], pendingCount: 0, activeFraction: 1.4) == 0)
    }
}
