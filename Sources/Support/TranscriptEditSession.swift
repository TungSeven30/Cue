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

typealias TranscriptSegmentCommit = @MainActor @Sendable (TranscriptionSegment, String) -> Void

/// Nonisolated token for `UndoManager.registerUndo`. Undo/redo callbacks hop back
/// to the main actor before touching UI state or registering the inverse action.
private final class TranscriptUndoBridge: NSObject, @unchecked Sendable {
    struct SingleAction: Sendable {
        let segment: TranscriptionSegment
        let applyText: String
        let inverseApplyText: String
    }

    struct BatchAction: Sendable {
        let applications: [AppliedSegmentText]
        let segmentsByID: [Int: TranscriptionSegment]
    }

    struct AppliedSegmentText: Sendable {
        let segmentID: Int
        let text: String
    }

    func registerSingle(
        undoManager: UndoManager,
        action: SingleAction,
        commit: @escaping TranscriptSegmentCommit,
        actionName: String
    ) {
        undoManager.registerUndo(withTarget: self) { bridge in
            guard let bridge = bridge as? TranscriptUndoBridge else { return }
            MainActor.assumeIsolated {
                commit(action.segment, action.applyText)
                bridge.registerSingle(
                    undoManager: undoManager,
                    action: SingleAction(
                        segment: action.segment,
                        applyText: action.inverseApplyText,
                        inverseApplyText: action.applyText
                    ),
                    commit: commit,
                    actionName: actionName
                )
            }
        }
        undoManager.setActionName(actionName)
    }

    func registerBatch(
        undoManager: UndoManager,
        action: BatchAction,
        inverse: BatchAction,
        commit: @escaping TranscriptSegmentCommit,
        actionName: String
    ) {
        undoManager.registerUndo(withTarget: self) { bridge in
            guard let bridge = bridge as? TranscriptUndoBridge else { return }
            MainActor.assumeIsolated {
                bridge.applyBatch(action, commit: commit)
                bridge.registerBatch(
                    undoManager: undoManager,
                    action: inverse,
                    inverse: action,
                    commit: commit,
                    actionName: actionName
                )
            }
        }
        undoManager.setActionName(actionName)
    }

    @MainActor
    private func applyBatch(_ action: BatchAction, commit: TranscriptSegmentCommit) {
        for application in action.applications {
            guard let segment = action.segmentsByID[application.segmentID] else { continue }
            commit(segment, application.text)
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

    private let undoBridge = TranscriptUndoBridge()
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
        commit: TranscriptSegmentCommit
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
        commit: TranscriptSegmentCommit
    ) {
        guard let editingSegmentID,
            let segment = segments.first(where: { $0.id == editingSegmentID })
        else { return }
        endEditing(segment: segment, finalText: segment.text, commit: commit)
    }

    func applyLiveEdit(
        segment: TranscriptionSegment,
        newText: String,
        commit: TranscriptSegmentCommit
    ) {
        guard segment.text != newText else { return }
        commit(segment, newText)
    }

    func replaceAll(
        changes: [TranscriptTextChange],
        segments: [TranscriptionSegment],
        commit: TranscriptSegmentCommit
    ) {
        guard !changes.isEmpty else { return }
        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        for change in changes {
            guard let segment = segmentsByID[change.segmentID] else { continue }
            commit(segment, change.newText)
        }
        registerBatchUndo(changes: changes, segmentsByID: segmentsByID, commit: commit)
    }

    func undo() {
        undoManager.undo()
    }

    private func registerTextUndo(
        segment: TranscriptionSegment,
        previousText: String,
        newText: String,
        commit: TranscriptSegmentCommit
    ) {
        undoBridge.registerSingle(
            undoManager: undoManager,
            action: TranscriptUndoBridge.SingleAction(
                segment: segment,
                applyText: previousText,
                inverseApplyText: newText
            ),
            commit: commit,
            actionName: "Edit Subtitle"
        )
    }

    private func registerBatchUndo(
        changes: [TranscriptTextChange],
        segmentsByID: [Int: TranscriptionSegment],
        commit: TranscriptSegmentCommit
    ) {
        let undoApplications = changes.map {
            TranscriptUndoBridge.AppliedSegmentText(segmentID: $0.segmentID, text: $0.previousText)
        }
        let redoApplications = changes.map {
            TranscriptUndoBridge.AppliedSegmentText(segmentID: $0.segmentID, text: $0.newText)
        }
        let actionName = changes.count == 1 ? "Replace" : "Replace All"
        undoBridge.registerBatch(
            undoManager: undoManager,
            action: TranscriptUndoBridge.BatchAction(applications: undoApplications, segmentsByID: segmentsByID),
            inverse: TranscriptUndoBridge.BatchAction(applications: redoApplications, segmentsByID: segmentsByID),
            commit: commit,
            actionName: actionName
        )
    }
}
