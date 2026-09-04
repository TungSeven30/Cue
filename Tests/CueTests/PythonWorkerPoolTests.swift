import Foundation
import os
import Testing
@testable import Cue

/// Drives `PythonWorkerPool` against a tiny stand-in for the helper that
/// speaks the same `--serve` protocol without any ML: it numbers the jobs it
/// has served (proving reuse), stamps its pid into the output, and misbehaves
/// on request through the job's file name (`crash`, `hang`, `fail`, `slow`).
@Suite(.serialized) struct PythonWorkerPoolTests {
    private static let fakeWorker = """
        import json, os, signal, sys, time
        count = 0
        def emit(payload):
            print(json.dumps(payload), file=sys.stderr, flush=True)
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            message = json.loads(line)
            if message.get("event") == "shutdown":
                sys.exit(0)
            if message.get("event") != "job":
                continue
            count += 1
            job_id = message["id"]
            name = os.path.basename(message.get("input_path", ""))
            emit({"stage": "transcribing", "detail": f"fake job {count}", "fraction": 0.5})
            if "crash" in name:
                print("fake worker crashing on purpose", file=sys.stderr, flush=True)
                os._exit(3)
            if "hang" in name:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                time.sleep(60)
            if "slow" in name:
                time.sleep(1.0)
            if "fail" in name:
                emit({"event": "error", "id": job_id, "message": "fake failure for " + name})
                continue
            segment = {"id": 1, "start": 0.0, "end": 1.0, "text": f"job {count} pid {os.getpid()} {name}"}
            emit({"event": "segments", "segments": [segment]})
            emit({"event": "result", "id": job_id, "backend": "fake", "segments": [segment]})
        """

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [TranscriptionStreamEvent] = []

        func record(_ event: TranscriptionStreamEvent) {
            lock.withLock { events.append(event) }
        }

        var all: [TranscriptionStreamEvent] { lock.withLock { events } }

        var segmentTexts: [String] {
            all.flatMap { event -> [String] in
                if case .segments(let batch) = event { return batch.map(\.text) }
                return []
            }
        }
    }

    private struct Harness {
        let pool: PythonWorkerPool
        let directory: URL

        func request(_ name: String) -> PythonJobRequest {
            PythonJobRequest(
                inputPath: directory.appendingPathComponent(name).path, language: "en", qwenContext: "",
                model: "fake-model", backend: "fake", preprocessAudio: false, vadFilter: true, beamSize: 5,
                bestOf: 5, temperature: 0, noSpeechThreshold: 0.6, streamSegments: true,
                resumeThroughSeconds: 0, startingSegmentID: 1, audioWav: nil)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness(idleTimeout: TimeInterval = 600, killGrace: TimeInterval = 0.5) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake_worker.py")
        try Self.fakeWorker.write(to: script, atomically: true, encoding: .utf8)
        var configuration = PythonWorkerPool.Configuration()
        configuration.scriptURL = { script }
        configuration.launcher = ["/usr/bin/python3"]
        configuration.idleTimeout = idleTimeout
        configuration.killGrace = killGrace
        return Harness(pool: PythonWorkerPool(configuration: configuration), directory: directory)
    }

    private func processIsGone(_ pid: Int32, within seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            // ESRCH means no such process; a zombie still answers, so wait
            // for Foundation to reap it.
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    @Test func workerIsReusedAcrossJobsAndEventsStayWithTheirJob() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let firstEvents = EventLog()
        let first = try await harness.pool.run(harness.request("one.mp4")) { firstEvents.record($0) }
        let firstPID = await harness.pool.residentWorkerPID()
        let secondEvents = EventLog()
        let second = try await harness.pool.run(harness.request("two.mp4")) { secondEvents.record($0) }
        let secondPID = await harness.pool.residentWorkerPID()

        #expect(first.backend == "fake")
        #expect(first.segments.first?.text.hasPrefix("job 1 pid") == true)
        #expect(second.segments.first?.text.hasPrefix("job 2 pid") == true, "second job must run in the same process")
        #expect(firstPID != nil)
        #expect(firstPID == secondPID)
        #expect(firstEvents.segmentTexts.allSatisfy { $0.contains("one.mp4") })
        #expect(secondEvents.segmentTexts.allSatisfy { $0.contains("two.mp4") })
        #expect(secondEvents.segmentTexts.count == 1)
        // Streamed events precede the result for the same job.
        #expect(firstEvents.all.count == 2)
        await harness.pool.shutdown()
    }

    @Test func crashMidJobFailsThatJobAndTheNextJobGetsAFreshWorker() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        _ = try await harness.pool.run(harness.request("warm.mp4")) { _ in }
        let firstPID = try #require(await harness.pool.residentWorkerPID())

        do {
            _ = try await harness.pool.run(harness.request("crash.mp4")) { _ in }
            Issue.record("a crashed worker must fail the job")
        } catch let error as TranscriptionServiceError {
            #expect(error.localizedDescription.contains("crashing on purpose"))
        }
        #expect(await harness.pool.residentWorkerPID() == nil)

        let recovered = try await harness.pool.run(harness.request("after.mp4")) { _ in }
        let secondPID = try #require(await harness.pool.residentWorkerPID())
        #expect(secondPID != firstPID)
        #expect(recovered.segments.first?.text.hasPrefix("job 1 pid") == true, "fresh process restarts its job count")
        await harness.pool.shutdown()
    }

    @Test func helperErrorEnvelopeFailsTheJobButKeepsTheWorker() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        _ = try await harness.pool.run(harness.request("warm.mp4")) { _ in }
        let pid = await harness.pool.residentWorkerPID()

        await #expect(throws: TranscriptionServiceError.self) {
            _ = try await harness.pool.run(harness.request("fail.mp4")) { _ in }
        }
        #expect(await harness.pool.residentWorkerPID() == pid)
        let next = try await harness.pool.run(harness.request("next.mp4")) { _ in }
        #expect(next.segments.first?.text.hasPrefix("job 3 pid") == true)
        await harness.pool.shutdown()
    }

    @Test func cancellationTerminatesEvenAWorkerThatIgnoresSIGTERM() async throws {
        let harness = try makeHarness(killGrace: 0.5)
        defer { harness.cleanUp() }
        _ = try await harness.pool.run(harness.request("warm.mp4")) { _ in }
        let pid = try #require(await harness.pool.residentWorkerPID())

        let task = Task {
            try await harness.pool.run(harness.request("hang.mp4")) { _ in }
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(ContinuousClock.now - cancelledAt < .seconds(3), "cancel must not wait for the hung helper")
        #expect(await processIsGone(pid, within: 5), "SIGKILL must follow the ignored SIGTERM")
        #expect(await harness.pool.residentWorkerPID() == nil)

        let after = try await harness.pool.run(harness.request("after.mp4")) { _ in }
        #expect(after.segments.first?.text.hasPrefix("job 1 pid") == true)
        await harness.pool.shutdown()
    }

    @Test func idleWorkerIsEvictedAfterTheTimeout() async throws {
        let harness = try makeHarness(idleTimeout: 0.4, killGrace: 0.5)
        defer { harness.cleanUp() }
        _ = try await harness.pool.run(harness.request("one.mp4")) { _ in }
        let pid = try #require(await harness.pool.residentWorkerPID())

        // Poll rather than sleep a fixed amount: a loaded runner can delay
        // the sweep well past the timeout.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, await harness.pool.residentWorkerPID() != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await harness.pool.residentWorkerPID() == nil)
        #expect(await processIsGone(pid, within: 5))
    }

    @Test func shutdownStopsTheWorkerPromptly() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        _ = try await harness.pool.run(harness.request("one.mp4")) { _ in }
        let pid = try #require(await harness.pool.residentWorkerPID())

        await harness.pool.shutdown()

        #expect(await harness.pool.residentWorkerPID() == nil)
        #expect(await processIsGone(pid, within: 3))
    }

    @Test func differentModelReplacesTheWorker() async throws {
        let harness = try makeHarness(killGrace: 0.5)
        defer { harness.cleanUp() }
        _ = try await harness.pool.run(harness.request("one.mp4")) { _ in }
        let firstPID = try #require(await harness.pool.residentWorkerPID())
        var other = harness.request("two.mp4")
        other.model = "another-model"
        let result = try await harness.pool.run(other) { _ in }
        let secondPID = try #require(await harness.pool.residentWorkerPID())

        #expect(secondPID != firstPID)
        #expect(result.segments.first?.text.hasPrefix("job 1 pid") == true)
        #expect(await processIsGone(firstPID, within: 3))
        await harness.pool.shutdown()
    }

    @Test func requestLineMatchesTheHelperContract() throws {
        var request = PythonJobRequest(
            inputPath: "/tmp/a.mp4", language: "ja", qwenContext: "Arrakis", model: "m", backend: "qwen3-asr",
            preprocessAudio: true, vadFilter: false, beamSize: 3, bestOf: 2, temperature: 0.2,
            noSpeechThreshold: 0.5, streamSegments: true, resumeThroughSeconds: 12.5, startingSegmentID: 7,
            audioWav: "/tmp/a.wav")
        let object = try JSONSerialization.jsonObject(with: try request.requestLine(id: "abc")) as? [String: Any]
        #expect(object?["event"] as? String == "job")
        #expect(object?["id"] as? String == "abc")
        #expect(object?["input_path"] as? String == "/tmp/a.mp4")
        #expect(object?["qwen_context"] as? String == "Arrakis")
        #expect(object?["preprocess_audio"] as? Bool == true)
        #expect(object?["vad_filter"] as? Bool == false)
        #expect(object?["starting_segment_id"] as? Int == 7)
        #expect(object?["audio_wav"] as? String == "/tmp/a.wav")
        request.audioWav = nil
        let withoutWav = try JSONSerialization.jsonObject(with: try request.requestLine(id: "abc")) as? [String: Any]
        #expect(withoutWav?["audio_wav"] is NSNull || withoutWav?["audio_wav"] == nil)
    }
}
