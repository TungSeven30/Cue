import Testing
@testable import Cue

@Suite struct StreamEventDecodingTests {
    @Test func decodesProgressEvent() {
        let line = #"{"stage": "transcribing", "detail": "Working.", "fraction": 0.5}"#
        guard case .progress(let update)? = TranscriptionStreamEvent.decode(line) else {
            Issue.record("expected progress event"); return
        }
        #expect(update.stage == .transcribing)
        #expect(update.fraction == 0.5)
    }

    @Test func decodesSegmentsEvent() {
        let line = #"{"event": "segments", "segments": [{"id": 1, "start": 0.0, "end": 1.5, "text": "hello"}]}"#
        guard case .segments(let batch)? = TranscriptionStreamEvent.decode(line) else {
            Issue.record("expected segments event"); return
        }
        #expect(batch == [TranscriptionSegment(id: 1, start: 0.0, end: 1.5, text: "hello")])
    }

    @Test func ignoresUnknownEventsAndNonJSON() {
        #expect(TranscriptionStreamEvent.decode(#"{"event": "heartbeat"}"#) == nil)
        #expect(TranscriptionStreamEvent.decode("plain stderr noise") == nil)
        #expect(TranscriptionStreamEvent.decode("") == nil)
    }
}
