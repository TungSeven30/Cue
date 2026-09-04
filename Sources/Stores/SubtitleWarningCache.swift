import Foundation

/// Quality warnings for one displayed subtitle list, plus the per-segment
/// grouping the transcript rows read, computed once per distinct array.
struct SubtitleWarnings: Equatable, Sendable {
    let list: [SubtitleQualityWarning]
    let bySegment: [Int: [SubtitleQualityWarning]]

    static let empty = SubtitleWarnings(list: [], bySegment: [:])
}

/// Memoises `SubtitleWarnings` so a SwiftUI render does not re-trim every
/// segment of a 3,000-cue transcript on every progress tick. During a
/// streaming run the displayed array grows by a batch at a time; without a
/// cache the per-render cost is O(n) and the whole run is O(n²).
///
/// Identity fast path: the cache retains the array it computed for. Any
/// mutation of the job's copy therefore has to copy-on-write into a new
/// buffer, so "same buffer address and same count" proves the contents are
/// unchanged. Append path: when the cached array is a prefix of the new one
/// only the new suffix is evaluated.
@MainActor
final class SubtitleWarningCache {
    struct Key: Hashable {
        let jobID: UUID
        let slot: SubtitleSidecarScanner.Slot
    }

    private struct Entry {
        let segments: [TranscriptionSegment]
        let warnings: SubtitleWarnings
    }

    private var entries: [Key: Entry] = [:]
    /// Number of individual segments evaluated so far (test seam).
    private(set) var computeCount = 0

    func warnings(for segments: [TranscriptionSegment], key: Key) -> SubtitleWarnings {
        if let entry = entries[key] {
            if Self.sharesStorage(entry.segments, segments) {
                return entry.warnings
            }
            if segments.count > entry.segments.count,
                segments.prefix(entry.segments.count).elementsEqual(entry.segments)
            {
                var list = entry.warnings.list
                var bySegment = entry.warnings.bySegment
                for segment in segments[entry.segments.count...] {
                    append(evaluate(segment), for: segment.id, into: &list, &bySegment)
                }
                let warnings = SubtitleWarnings(list: list, bySegment: bySegment)
                store(Entry(segments: segments, warnings: warnings), for: key)
                return warnings
            }
        }
        var list: [SubtitleQualityWarning] = []
        var bySegment: [Int: [SubtitleQualityWarning]] = [:]
        for segment in segments {
            append(evaluate(segment), for: segment.id, into: &list, &bySegment)
        }
        let warnings = SubtitleWarnings(list: list, bySegment: bySegment)
        store(Entry(segments: segments, warnings: warnings), for: key)
        return warnings
    }

    /// Drops everything cached for a job (on delete, so its segment arrays
    /// are not retained for the app's lifetime).
    func invalidate(jobID: UUID) {
        entries = entries.filter { $0.key.jobID != jobID }
    }

    /// The four rules the transcript view shows, unchanged from
    /// `AppModel.qualityWarnings`.
    static func compute(_ segment: TranscriptionSegment) -> [SubtitleQualityWarning] {
        var warnings: [SubtitleQualityWarning] = []
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Empty text"))
        }
        if segment.end <= segment.start {
            warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Invalid timing"))
        }
        if segment.end - segment.start > 8 {
            warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Long duration"))
        }
        if trimmed.count > 90 {
            warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Long subtitle text"))
        }
        return warnings
    }

    private func evaluate(_ segment: TranscriptionSegment) -> [SubtitleQualityWarning] {
        computeCount += 1
        return Self.compute(segment)
    }

    private func append(
        _ warnings: [SubtitleQualityWarning],
        for segmentID: Int,
        into list: inout [SubtitleQualityWarning],
        _ bySegment: inout [Int: [SubtitleQualityWarning]]
    ) {
        guard !warnings.isEmpty else { return }
        list.append(contentsOf: warnings)
        bySegment[segmentID, default: []].append(contentsOf: warnings)
    }

    /// Only the two slots of the job being looked at are worth keeping; a
    /// selection change drops the previous job's arrays.
    private func store(_ entry: Entry, for key: Key) {
        entries = entries.filter { $0.key.jobID == key.jobID }
        entries[key] = entry
    }

    private static func sharesStorage(_ a: [TranscriptionSegment], _ b: [TranscriptionSegment]) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBufferPointer { first in
            b.withUnsafeBufferPointer { second in
                first.baseAddress == second.baseAddress
            }
        }
    }
}
