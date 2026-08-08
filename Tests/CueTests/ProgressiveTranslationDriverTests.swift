import Testing
@testable import Cue

@MainActor
@Suite struct ProgressiveTranslationDriverTests {
    private func segment(_ id: Int) -> TranscriptionSegment {
        TranscriptionSegment(id: id, start: Double(id), end: Double(id) + 1, text: "s\(id)")
    }

    @Test func requestsTranslationOncePerThresholdCrossing() async {
        var requests = 0
        var calls: [[TranscriptionSegment]] = []
        let driver = ProgressiveTranslationDriver(
            chunkSize: 3, overlapAllowed: true,
            translate: { segments, _, onPartial in
                calls.append(segments)
                onPartial(segments.map { TranscriptionSegment(id: $0.id, start: $0.start, end: $0.end, text: "T\($0.id)") })
                return segments
            },
            onPartial: { _ in },
            onNeedsTranslation: { requests += 1 }
        )
        driver.ingest([segment(1), segment(2)])
        #expect(requests == 0)  // below threshold
        driver.ingest([segment(3)])
        #expect(requests == 1)  // crossed
        driver.ingest([segment(4)])
        #expect(requests == 1)  // no second signal while one is outstanding
        await driver.translateAvailable()
        #expect(calls.count == 1)
        #expect(calls[0].count == 4)  // snapshot includes everything streamed so far
        driver.ingest([segment(5), segment(6), segment(7)])
        #expect(requests == 2)  // new material past the last request re-signals
    }

    @Test func localProviderNeverRequestsMidStream() async throws {
        var requests = 0
        var calls = 0
        let driver = ProgressiveTranslationDriver(
            chunkSize: 1, overlapAllowed: false,
            translate: { segments, _, _ in
                calls += 1; return segments
            },
            onPartial: { _ in },
            onNeedsTranslation: { requests += 1 }
        )
        driver.ingest([segment(1), segment(2), segment(3)])
        #expect(requests == 0)
        _ = try await driver.finish(finalTranscript: [segment(1), segment(2), segment(3)])
        #expect(calls == 1)  // exactly the one completion call
    }

    @Test func midStreamFailureStopsRequestsButFinishStillRuns() async {
        struct Boom: Error {}
        var requests = 0
        var shouldFail = true
        let driver = ProgressiveTranslationDriver(
            chunkSize: 1, overlapAllowed: true,
            translate: { segments, _, _ in
                if shouldFail { throw Boom() }
                return segments
            },
            onPartial: { _ in },
            onNeedsTranslation: { requests += 1 }
        )
        driver.ingest([segment(1)])
        #expect(requests == 1)
        await driver.translateAvailable()  // fails silently mid-stream
        driver.ingest([segment(2)])
        #expect(requests == 1)  // failed: no further mid-stream requests
        shouldFail = false
        let result = try? await driver.finish(finalTranscript: [segment(1), segment(2)])
        #expect(result?.count == 2)  // finish still runs and can succeed
    }

    @Test func finishSeedsTranslateWithReconciledPartials() async throws {
        var receivedExisting: [TranscriptionSegment] = []
        let driver = ProgressiveTranslationDriver(
            chunkSize: 1, overlapAllowed: true,
            translate: { segments, existing, onPartial in
                receivedExisting = existing
                onPartial(segments.map { TranscriptionSegment(id: $0.id, start: $0.start, end: $0.end, text: "T\($0.id)") })
                return segments.map { TranscriptionSegment(id: $0.id, start: $0.start, end: $0.end, text: "T\($0.id)") }
            },
            onPartial: { _ in },
            onNeedsTranslation: {}
        )
        driver.ingest([segment(1)])
        await driver.translateAvailable()
        // Final pass renumbers: same (start, end, text), new id.
        let final = [TranscriptionSegment(id: 100, start: 1, end: 2, text: "s1")]
        _ = try await driver.finish(finalTranscript: final)
        #expect(receivedExisting == [TranscriptionSegment(id: 100, start: 1, end: 2, text: "T1")])
    }

    @Test func adaptivePolicyStartsOnFirstUsefulBatch() {
        var requests = 0
        let driver = ProgressiveTranslationDriver(
            chunkSize: 80,
            initialSegmentThreshold: 12,
            targetInputTokens: 3_200,
            overlapAllowed: true,
            translate: { segments, _, _ in segments },
            onPartial: { _ in },
            onNeedsTranslation: { requests += 1 }
        )
        driver.ingest((1...11).map(segment))
        #expect(requests == 0)
        driver.ingest([segment(12)])
        #expect(requests == 1)
    }

    @Test func sparseDialogueStartsAfterUsefulAudioSpan() {
        var requests = 0
        let driver = ProgressiveTranslationDriver(
            chunkSize: 80,
            initialSegmentThreshold: 16,
            targetInputTokens: 3_200,
            overlapAllowed: true,
            translate: { segments, _, _ in segments },
            onPartial: { _ in },
            onNeedsTranslation: { requests += 1 }
        )
        let sparse = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "one"),
            TranscriptionSegment(id: 2, start: 15, end: 16, text: "two"),
            TranscriptionSegment(id: 3, start: 30, end: 31, text: "three"),
            TranscriptionSegment(id: 4, start: 50, end: 51, text: "four"),
        ]
        driver.ingest(sparse)
        #expect(requests == 1)
    }
}
