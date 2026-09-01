import Foundation
import Testing
@testable import Cue

@MainActor
struct TranscriptEditSessionTests {
    @Test func undoRestoresSegmentTextAfterReplaceAll() {
        let session = TranscriptEditSession()
        var segments = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "hello world"),
            TranscriptionSegment(id: 2, start: 1, end: 2, text: "hello again"),
            TranscriptionSegment(id: 3, start: 2, end: 3, text: "goodbye"),
        ]
        let commit: (TranscriptionSegment, String) -> Void = { segment, text in
            guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
            segments[index].text = text
        }

        let changes = TranscriptReplaceAll.plannedChanges(
            in: segments,
            query: "hello",
            replacement: "hi"
        )
        #expect(changes.count == 2)

        session.replaceAll(changes: changes, segments: segments, commit: commit)

        #expect(segments[0].text == "hi world")
        #expect(segments[1].text == "hi again")
        #expect(segments[2].text == "goodbye")

        session.undo()

        #expect(segments[0].text == "hello world")
        #expect(segments[1].text == "hello again")
        #expect(segments[2].text == "goodbye")
    }

    @Test func largeTranscriptKeepsAtMostOneTextEditorRow() {
        let session = TranscriptEditSession()
        let segmentCount = 512
        let segments = (1 ... segmentCount).map { index in
            TranscriptionSegment(id: index, start: Double(index), end: Double(index) + 1, text: "Cue \(index)")
        }

        #expect(session.editorSegmentIDs.isEmpty)
        for segment in segments {
            #expect(session.rowKind(for: segment.id) == .idleText)
        }

        session.beginEditing(segmentID: 250, text: "Cue 250")

        #expect(session.editorSegmentIDs == [250])
        #expect(session.rowKind(for: 250) == .editingTextEditor)
        for segment in segments where segment.id != 250 {
            #expect(session.rowKind(for: segment.id) == .idleText)
        }

        session.endEditingIfNeeded(segments: segments, commit: { _, _ in })
        session.beginEditing(segmentID: 11, text: "Cue 11")

        #expect(session.editorSegmentIDs == [11])
        #expect(session.rowKind(for: 11) == .editingTextEditor)
        #expect(session.rowKind(for: 250) == .idleText)
    }

    @Test func replaceAllMatchCountIgnoresNonMatchingSegments() {
        let segments = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "alpha"),
            TranscriptionSegment(id: 2, start: 1, end: 2, text: "beta"),
            TranscriptionSegment(id: 3, start: 2, end: 3, text: "alphabet"),
        ]

        #expect(TranscriptReplaceAll.matchCount(in: segments, query: "alpha") == 2)
        #expect(TranscriptReplaceAll.matchCount(in: segments, query: "   ") == 0)
        #expect(TranscriptReplaceAll.matchCount(in: segments, query: "missing") == 0)
    }

    @Test func typingSessionRegistersUndoOnEndEditing() {
        let session = TranscriptEditSession()
        var segments = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "Original"),
        ]
        let commit: (TranscriptionSegment, String) -> Void = { segment, text in
            segments[0].text = text
        }

        session.beginEditing(segmentID: 1, text: "Original")
        session.applyLiveEdit(segment: segments[0], newText: "Edited", commit: commit)
        session.endEditing(segment: segments[0], finalText: segments[0].text, commit: commit)

        #expect(segments[0].text == "Edited")

        session.undo()

        #expect(segments[0].text == "Original")
    }
}
