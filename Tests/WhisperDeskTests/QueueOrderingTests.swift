import Foundation
import Testing
@testable import WhisperDesk

struct QueueOrderingTests {
    @Test func batchAddKeepsBatchOrderAboveExisting() {
        // First URL gets the smallest index (topmost in ascending order).
        #expect(QueueOrdering.indicesForBatchAdd(count: 3, existing: [0, 1, 2]) == [-3, -2, -1])
        #expect(QueueOrdering.indicesForBatchAdd(count: 1, existing: []) == [-1])
        #expect(QueueOrdering.indicesForBatchAdd(count: 0, existing: [5]) == [])
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

    @Test func renormalizationTriggersWhenMidpointCannotFit() {
        // Zero gap: a duplicate already exists.
        #expect(QueueOrdering.needsRenormalization(before: 1, after: 1))
        // One-ULP gap at timestamp magnitude (the real-world orderIndex
        // scale): no midpoint can land strictly between.
        let timestampScale = -1_700_000_000.0
        #expect(QueueOrdering.needsRenormalization(before: timestampScale, after: timestampScale.nextUp))
        // Healthy gaps never trigger, at any magnitude.
        #expect(!QueueOrdering.needsRenormalization(before: 1, after: 2))
        #expect(!QueueOrdering.needsRenormalization(before: timestampScale, after: timestampScale + 1))
        #expect(!QueueOrdering.needsRenormalization(before: nil, after: 2))
    }

    @Test func renormalizedIsZeroBasedSequential() {
        #expect(QueueOrdering.renormalized(count: 4) == [0, 1, 2, 3])
        #expect(QueueOrdering.renormalized(count: 0) == [])
    }

    @Test func movedBlockStartMatchesArrayMove() {
        // Moving [1] to offset 4 in a 5-element array lands the item at 3.
        var a = [0, 1, 2, 3, 4]
        a.move(fromOffsets: IndexSet(integer: 1), toOffset: 4)
        #expect(a[3] == 1)
        #expect(QueueOrdering.movedBlockStart(source: IndexSet(integer: 1), destination: 4) == 3)
        // Moving down-to-up keeps the raw destination.
        var b = [0, 1, 2, 3, 4]
        b.move(fromOffsets: IndexSet(integer: 3), toOffset: 1)
        #expect(b[1] == 3)
        #expect(QueueOrdering.movedBlockStart(source: IndexSet(integer: 3), destination: 1) == 1)
        // Multi-item block from both sides of the destination.
        var c = [0, 1, 2, 3, 4]
        c.move(fromOffsets: IndexSet([0, 4]), toOffset: 2)
        #expect(Array(c[1...2]) == [0, 4])
        #expect(QueueOrdering.movedBlockStart(source: IndexSet([0, 4]), destination: 2) == 1)
    }
}
