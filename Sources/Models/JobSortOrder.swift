import Foundation

/// Sidebar sort orders. Queue order is the manual, drag-reorderable layout;
/// the others are presentation-only sorts over the same jobs.
enum JobSortOrder: String, CaseIterable, Identifiable {
    case queueOrder
    case completedDate
    case name
    case length

    var id: String { rawValue }

    var label: String {
        switch self {
        case .queueOrder: return "Queue Order"
        case .completedDate: return "Date Completed"
        case .name: return "Name"
        case .length: return "Length"
        }
    }

    /// The per-job facts a sort can use, kept primitive so the ordering
    /// logic stays testable without building full jobs.
    struct Key {
        let orderIndex: Double
        let completedAt: Date?
        let title: String
        /// Media length approximated by the last cue's end time; 0 until a
        /// transcript exists.
        let mediaLength: Double
    }

    /// Element offsets in display order. Ties (and the queueOrder case)
    /// fall back to orderIndex, so the result is deterministic.
    func sortedOffsets(of keys: [Key]) -> [Int] {
        let offsets = keys.indices.sorted { a, b in
            let ka = keys[a], kb = keys[b]
            switch self {
            case .queueOrder:
                break
            case .completedDate:
                // Newest completion first; never-finished jobs sink.
                let da = ka.completedAt ?? .distantPast
                let db = kb.completedAt ?? .distantPast
                if da != db { return da > db }
            case .name:
                let comparison = ka.title.localizedStandardCompare(kb.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .length:
                if ka.mediaLength != kb.mediaLength { return ka.mediaLength > kb.mediaLength }
            }
            return ka.orderIndex < kb.orderIndex
        }
        return Array(offsets)
    }
}

extension JobSortOrder.Key {
    init(job: TranscriptionJob) {
        self.init(
            orderIndex: job.orderIndex,
            completedAt: job.finishedAt ?? job.transcriptionFinishedAt,
            title: job.title,
            mediaLength: job.transcriptSegments.last?.end ?? job.translatedSegments.last?.end ?? 0
        )
    }
}
