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

    @Test func decodesQwenMetricsEvent() {
        let line =
            #"{"event":"metrics","metrics":{"backend":"qwen3-asr","audioDurationSeconds":100,"audioLoadSeconds":0.1,"chunkPlanningSeconds":0.2,"modelLoadSeconds":1.0,"inferenceSeconds":20,"normalizationSeconds":0.3,"pipelineSeconds":21.6,"audioPreparationSeconds":2,"totalSeconds":23.6,"chunkCount":2,"inferenceRTF":0.2,"totalRTF":0.236}}"#
        guard case .metrics(let metrics)? = TranscriptionStreamEvent.decode(line) else {
            Issue.record("expected metrics event"); return
        }
        #expect(metrics.chunkCount == 2)
        #expect(metrics.inferenceRTF == 0.2)
        #expect(metrics.logSummary.contains("inference RTF 0.200x"))
    }
}
