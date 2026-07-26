import Foundation

/// Pure math for job list ordering. Jobs sort ascending by orderIndex; new
/// manual jobs go on top, watch-folder ingests at the bottom, and a drag
/// rewrites only the moved job (spec §1.1).
enum QueueOrdering {
    static let minimumGap = 1e-9

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

    static func needsRenormalization(before: Double?, after: Double?) -> Bool {
        guard let before, let after else { return false }
        return abs(after - before) < minimumGap
    }

    static func renormalized(count: Int) -> [Double] {
        (0..<count).map(Double.init)
    }
}
