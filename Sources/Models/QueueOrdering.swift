import Foundation

/// Pure math for job list ordering. Jobs sort ascending by orderIndex; new
/// manual jobs go on top, watch-folder ingests at the bottom, and a drag
/// rewrites only the moved job (spec §1.1).
enum QueueOrdering {
    static func indexForManualAdd(existing: [Double]) -> Double {
        (existing.min() ?? 0) - 1
    }

    static func indexForWatchAdd(existing: [Double]) -> Double {
        (existing.max() ?? 0) + 1
    }

    /// Index for a job landing between two neighbours (nil = list edge).
    static func destinationIndex(before: Double?, after: Double?) -> Double {
        switch (before, after) {
        case let (b?, a?): return (b + a) / 2
        case let (nil, a?): return a - 1
        case let (b?, nil): return b + 1
        case (nil, nil): return 0
        }
    }

    /// True when a midpoint insert between these neighbours would not land
    /// strictly between them — i.e. Double precision is exhausted at this
    /// magnitude (or the gap is zero) and the whole list needs re-indexing.
    /// Deliberately magnitude-independent: orderIndex defaults are timestamp
    /// -sized (~1.7e9), where an absolute epsilon smaller than one ULP could
    /// never fire before a duplicate already existed.
    static func needsRenormalization(before: Double?, after: Double?) -> Bool {
        guard let before, let after else { return false }
        let mid = (before + after) / 2
        return !(before < mid && mid < after)
    }

    static func renormalized(count: Int) -> [Double] {
        (0..<count).map(Double.init)
    }

    /// Where a block moved with Array.move(fromOffsets:toOffset:) lands:
    /// the destination offset is expressed in pre-removal coordinates, so
    /// the landing position shifts down by the number of moved items that
    /// were originally above it.
    static func movedBlockStart(source: IndexSet, destination: Int) -> Int {
        destination - source.count(where: { $0 < destination })
    }
}
