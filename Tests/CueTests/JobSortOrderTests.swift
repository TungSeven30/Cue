import Foundation
import Testing
@testable import Cue

@Suite struct JobSortOrderTests {
    private func key(
        order: Double,
        completed: Date? = nil,
        title: String = "x",
        length: Double = 0
    ) -> JobSortOrder.Key {
        JobSortOrder.Key(orderIndex: order, completedAt: completed, title: title, mediaLength: length)
    }

    @Test func queueOrderFollowsOrderIndex() {
        let keys = [key(order: 2), key(order: 0), key(order: 1)]
        #expect(JobSortOrder.queueOrder.sortedOffsets(of: keys) == [1, 2, 0])
    }

    @Test func completedDateShowsNewestFirstAndSinksUnfinished() {
        let keys = [
            key(order: 0, completed: nil),
            key(order: 1, completed: Date(timeIntervalSince1970: 100)),
            key(order: 2, completed: Date(timeIntervalSince1970: 200)),
        ]
        #expect(JobSortOrder.completedDate.sortedOffsets(of: keys) == [2, 1, 0])
    }

    @Test func nameSortsCaseInsensitivelyWithNumbersInHumanOrder() {
        let keys = [
            key(order: 0, title: "Episode 10"),
            key(order: 1, title: "episode 2"),
            key(order: 2, title: "Another"),
        ]
        #expect(JobSortOrder.name.sortedOffsets(of: keys) == [2, 1, 0])
    }

    @Test func lengthShowsLongestFirst() {
        let keys = [key(order: 0, length: 60), key(order: 1, length: 5400), key(order: 2, length: 0)]
        #expect(JobSortOrder.length.sortedOffsets(of: keys) == [1, 0, 2])
    }

    @Test func tiesFallBackToQueueOrderDeterministically() {
        let same = Date(timeIntervalSince1970: 100)
        let keys = [key(order: 5, completed: same), key(order: 1, completed: same), key(order: 3, completed: same)]
        #expect(JobSortOrder.completedDate.sortedOffsets(of: keys) == [1, 2, 0])
    }
}
