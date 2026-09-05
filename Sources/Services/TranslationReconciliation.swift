import Foundation

/// Maps partial translations made from streamed (pre-cleanup) segments onto
/// the final cleaned transcript. The final pass can renumber and merge, so
/// matching is by exact (start, end, text); anything that does not match is
/// dropped and re-translated by the completion tail call.
enum TranslationReconciliation {
    private struct TimingKey: Hashable {
        let start: Double
        let end: Double

        init?(_ segment: TranscriptionSegment) {
            guard segment.start.isFinite, segment.end.isFinite,
                segment.start >= 0, segment.end >= segment.start,
                segment.end < SubtitleReader.maximumTimestampSeconds
            else { return nil }
            start = (segment.start * 1000).rounded()
            end = (segment.end * 1000).rounded()
        }
    }

    /// Imported files have independently numbered IDs. Only an unambiguous
    /// timestamp pair at subtitle-file precision can establish correspondence.
    static func alignedTranslations(
        _ translated: [TranscriptionSegment], to source: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        var byTiming: [TimingKey: [TranscriptionSegment]] = [:]
        for segment in source {
            guard let key = TimingKey(segment) else { continue }
            byTiming[key, default: []].append(segment)
        }
        var matches: [Int: [TranscriptionSegment]] = [:]
        for segment in translated {
            guard let key = TimingKey(segment), let candidates = byTiming[key], candidates.count == 1,
                let original = candidates.first
            else { continue }
            matches[original.id, default: []].append(
                TranscriptionSegment(
                    id: original.id, start: original.start, end: original.end, text: segment.text
                ))
        }
        return source.compactMap { original in
            guard let candidates = matches[original.id], candidates.count == 1 else { return nil }
            return candidates.first
        }
    }

    private struct Key: Hashable {
        let start: Double
        let end: Double
        let text: String
    }

    static func remap(
        partials: [TranscriptionSegment],
        streamed: [TranscriptionSegment],
        final: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        guard !partials.isEmpty else { return [] }
        let partialTextByID = Dictionary(partials.map { ($0.id, $0.text) }, uniquingKeysWith: { _, last in last })
        var translatedByKey: [Key: String] = [:]
        for segment in streamed {
            guard let text = partialTextByID[segment.id] else { continue }
            translatedByKey[Key(start: segment.start, end: segment.end, text: segment.text)] = text
        }
        return final.compactMap { segment in
            guard let text = translatedByKey[Key(start: segment.start, end: segment.end, text: segment.text)] else {
                return nil
            }
            return TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: text)
        }
    }
}
