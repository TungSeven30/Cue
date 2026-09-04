import Foundation

/// Total orders for loading persisted jobs, so equal keys never depend on
/// directory-listing order, decode timing, or an unstable sort. Both orders
/// end on the id, which is unique, so they are strict total orders.
enum JobLoadOrdering {
    /// The store's own order: most recently updated first. Ties break on id.
    static func storeOrder(_ a: TranscriptionJob, _ b: TranscriptionJob) -> Bool {
        if a.updatedAt != b.updatedAt {
            return a.updatedAt > b.updatedAt
        }
        return a.id.uuidString < b.id.uuidString
    }

    /// The sidebar's order: queue position first. Jobs sharing an
    /// `orderIndex` (possible after a legacy migration or a hand-edited file)
    /// fall back to most-recently-updated, then id.
    static func stableSortedByOrderIndex(_ jobs: [TranscriptionJob]) -> [TranscriptionJob] {
        jobs.sorted { a, b in
            if a.orderIndex != b.orderIndex {
                return a.orderIndex < b.orderIndex
            }
            return storeOrder(a, b)
        }
    }
}
