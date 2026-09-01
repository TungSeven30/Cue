import Combine
import Foundation

/// How a cue row is rendered in the transcript list. Tests assert that only
/// the focused segment uses `.editingTextEditor`; everything else stays cheap.
enum TranscriptSegmentRowKind: Equatable, Sendable {
    case idleText
    case editingTextEditor
}

/// One segment text change produced by Replace All, used for undo registration.
struct TranscriptTextChange: Equatable, Sendable {
    let segmentID: Int
    let previousText: String
    let newText: String
}

enum TranscriptReplaceAll {
    static func matchCount(in segments: [TranscriptionSegment], query: String) -> Int {
        plannedChanges(in: segments, query: query, replacement: "").count
    }

    static func plannedChanges(
        in segments: [TranscriptionSegment],
        query: String,
        replacement: String
    ) -> [TranscriptTextChange] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        return segments.compactMap { segment in
            guard segment.text.localizedCaseInsensitiveContains(trimmedQuery) else { return nil }
            let updated = segment.text.replacingOccurrences(
                of: trimmedQuery,
                with: replacement,
                options: [.caseInsensitive, .literal]
            )
            guard updated != segment.text else { return nil }
            return TranscriptTextChange(
                segmentID: segment.id,
                previousText: segment.text,
                newText: updated
            )
        }
    }
}

/// Tracks which cue row is promoted to a TextEditor and registers AppKit undo
/// for typing sessions and Replace All. Timing edits can register through the
/// same undo manager later.
@MainActor
final class TranscriptEditSession: ObservableObject {
    @Published private(set) var editingSegmentID: Int?

    let undoManager = UndoManager()

    private var editingBaselineText: String?

    /// Test hook: segment IDs currently rendered as TextEditor (at most one).
    var editorSegmentIDs: Set<Int> {
        editingSegmentID.map { [$0] } ?? []
    }

    func rowKind(for segmentID: Int) -> TranscriptSegmentRowKind {
        editingSegmentID == segmentID ? .editingTextEditor : .idleText
    }

    func beginEditing(segmentID: Int, text: String) {
        editingSegmentID = segmentID
        editingBaselineText = text
    }

    func endEditing(
        segment: TranscriptionSegment,
        finalText: String,
        commit: (TranscriptionSegment, String) -> Void
    ) {
        defer {
            editingSegmentID = nil
            editingBaselineText = nil
        }
        guard let baseline = editingBaselineText, baseline != finalText else { return }
        registerTextUndo(
            segment: segment,
            previousText: baseline,
            newText: finalText,
            commit: commit
        )
    }

    func endEditingIfNeeded(
        segments: [TranscriptionSegment],
        commit: (TranscriptionSegment, String) -> Void
    ) {
        guard let editingSegmentID,
            let segment = segments.first(where: { $0.id == editingSegmentID })
        else { return }
        endEditing(segment: segment, finalText: segment.text, commit: commit)
    }

    func applyLiveEdit(
        segment: TranscriptionSegment,
        newText: String,
        commit: (TranscriptionSegment, String) -> Void
    ) {
        guard segment.text != newText else { return }
        commit(segment, newText)
    }

    func replaceAll(
        changes: [TranscriptTextChange],
        segments: [TranscriptionSegment],
        commit: (TranscriptionSegment, String) -> Void
    ) {
        guard !changes.isEmpty else { return }
        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        for change in changes {
            guard let segment = segmentsByID[change.segmentID] else { continue }
            commit(segment, change.newText)
        }
        registerBatchUndo(changes: changes, segments: segments, commit: commit)
        undoManager.setActionName(changes.count == 1 ? "Replace" : "Replace All")
    }

    func undo() {
        undoManager.undo()
    }

    private func registerTextUndo(
        segment: TranscriptionSegment,
        previousText: String,
        newText: String,
        commit: (TranscriptionSegment, String) -> Void
    ) {
        undoManager.registerUndo(withTarget: self) { session in
            commit(segment, previousText)
            session.registerTextUndo(
                segment: segment,
                previousText: newText,
                newText: previousText,
                commit: commit
            )
        }
        undoManager.setActionName("Edit Subtitle")
    }

    private func registerBatchUndo(
        changes: [TranscriptTextChange],
        segments: [TranscriptionSegment],
        commit: (TranscriptionSegment, String) -> Void
    ) {
        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        undoManager.registerUndo(withTarget: self) { session in
            for change in changes {
                guard let segment = segmentsByID[change.segmentID] else { continue }
                commit(segment, change.previousText)
            }
            let inverse = changes.map {
                TranscriptTextChange(
                    segmentID: $0.segmentID,
                    previousText: $0.newText,
                    newText: $0.previousText
                )
            }
            session.registerBatchUndo(changes: inverse, segments: segments, commit: commit)
        }
    }
}
