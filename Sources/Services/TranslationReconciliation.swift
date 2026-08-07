import Foundation

/// Maps partial translations made from streamed (pre-cleanup) segments onto
/// the final cleaned transcript. The final pass can renumber and merge, so
/// matching is by exact (start, end, text); anything that does not match is
/// dropped and re-translated by the completion tail call.
enum TranslationReconciliation {
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
