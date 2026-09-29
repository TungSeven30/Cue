import Foundation

/// A run of text that is either plain or emphasized because the search
/// matched it. Pure, so the highlight rules are unit-tested without SwiftUI;
/// the view turns segments into an `AttributedString`.
struct PaletteTextSegment: Equatable, Sendable {
    let text: String
    let isEmphasized: Bool
}

enum PaletteHighlight {
    /// Splits `text` at the engine's match ranges. Ranges are Character
    /// offsets (what `CommandPaletteSearch` reports), so combining marks,
    /// emoji, and kana keep their boundaries. Ranges may arrive unsorted,
    /// overlapping, or past the end (a subtitle that changed since the match
    /// was computed); they are clamped and merged rather than trusted.
    static func segments(for text: String, ranges: [Range<Int>]) -> [PaletteTextSegment] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        let clamped =
            ranges
            .map { max(0, $0.lowerBound)..<min(characters.count, $0.upperBound) }
            .filter { $0.lowerBound < $0.upperBound }
        guard !clamped.isEmpty else { return [PaletteTextSegment(text: text, isEmphasized: false)] }

        var segments: [PaletteTextSegment] = []
        var cursor = 0
        for range in CommandPaletteSearch.mergeRanges(clamped) {
            if range.lowerBound > cursor {
                segments.append(
                    PaletteTextSegment(text: String(characters[cursor..<range.lowerBound]), isEmphasized: false)
                )
            }
            segments.append(
                PaletteTextSegment(text: String(characters[range]), isEmphasized: true)
            )
            cursor = range.upperBound
        }
        if cursor < characters.count {
            segments.append(PaletteTextSegment(text: String(characters[cursor...]), isEmphasized: false))
        }
        return segments
    }
}
