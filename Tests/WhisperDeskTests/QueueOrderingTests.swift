import Foundation
import Testing
@testable import WhisperDesk

struct QueueOrderingTests {
    @Test func manualAddGoesOnTop() {
        #expect(QueueOrdering.indexForManualAdd(existing: [0, 1, 2]) == -1)
        #expect(QueueOrdering.indexForManualAdd(existing: []) == -1)
    }

    @Test func watchAddGoesToBottom() {
        #expect(QueueOrdering.indexForWatchAdd(existing: [0, 1, 2]) == 3)
        #expect(QueueOrdering.indexForWatchAdd(existing: []) == 1)
    }

    @Test func destinationBetweenNeighborsIsMidpoint() {
        #expect(QueueOrdering.destinationIndex(before: 1, after: 2) == 1.5)
    }

    @Test func destinationAtEdges() {
        #expect(QueueOrdering.destinationIndex(before: nil, after: 5) == 4)
        #expect(QueueOrdering.destinationIndex(before: 5, after: nil) == 6)
        #expect(QueueOrdering.destinationIndex(before: nil, after: nil) == 0)
    }

    @Test func renormalizationTriggersOnTinyGap() {
        #expect(QueueOrdering.needsRenormalization(before: 1, after: 1 + 1e-10))
        #expect(!QueueOrdering.needsRenormalization(before: 1, after: 2))
        #expect(!QueueOrdering.needsRenormalization(before: nil, after: 2))
    }

    @Test func renormalizedIsZeroBasedSequential() {
        #expect(QueueOrdering.renormalized(count: 4) == [0, 1, 2, 3])
        #expect(QueueOrdering.renormalized(count: 0) == [])
    }
}
