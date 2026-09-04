import Foundation

/// Everything the Python helper needs for one job, mirroring the one-shot
/// CLI flags field for field. Encoded as the `{"event":"job",…}` line the
/// helper's `--serve` loop reads; the helper turns it back into argparse
/// arguments, so a served job is parsed by exactly the rules a one-shot run is.
struct PythonJobRequest: Sendable, Equatable {
    var inputPath: String
    var language: String
    var qwenContext: String
    var model: String
    var backend: String
    var preprocessAudio: Bool
    var vadFilter: Bool
    var beamSize: Int
    var bestOf: Int
    var temperature: Double
    var noSpeechThreshold: Double
    var streamSegments: Bool
    var resumeThroughSeconds: Double
    var startingSegmentID: Int
    var audioWav: String?

    private struct Wire: Encodable {
        let event = "job"
        let id: String
        let input_path: String
        let language: String
        let qwen_context: String
        let model: String
        let backend: String
        let preprocess_audio: Bool
        let vad_filter: Bool
        let beam_size: Int
        let best_of: Int
        let temperature: Double
        let no_speech_threshold: Double
        let stream_segments: Bool
        let resume_through_seconds: Double
        let starting_segment_id: Int
        let audio_wav: String?
    }

    func requestLine(id: String) throws -> Data {
        let wire = Wire(
            id: id, input_path: inputPath, language: language, qwen_context: qwenContext, model: model,
            backend: backend, preprocess_audio: preprocessAudio, vad_filter: vadFilter, beam_size: beamSize,
            best_of: bestOf, temperature: temperature, no_speech_threshold: noSpeechThreshold,
            stream_segments: streamSegments, resume_through_seconds: resumeThroughSeconds,
            starting_segment_id: startingSegmentID, audio_wav: audioWav
        )
        var data = try JSONEncoder().encode(wire)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

struct PythonJobResult: Sendable {
    let backend: String
    let segments: [TranscriptionSegment]
}

/// The helper's end-of-job line in `--serve` mode.
private struct ServeEnvelope: Decodable, Sendable {
    let event: String
    let id: String?
    let backend: String?
    let segments: [TranscriptionSegment]?
    let message: String?

    static func decode(_ line: String) -> ServeEnvelope? {
        guard
            line.hasPrefix("{\"event\": \"result\"") || line.hasPrefix("{\"event\": \"error\"")
                || line.hasPrefix("{\"event\":\"result\"") || line.hasPrefix("{\"event\":\"error\"")
        else { return nil }
        guard let data = line.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(ServeEnvelope.self, from: data),
            envelope.event == "result" || envelope.event == "error"
        else { return nil }
        return envelope
    }
}

/// Keeps one Python helper process alive between jobs so the interpreter
/// start, library imports, and model load are paid once per (backend, model)
/// instead of once per job.
///
/// Semantics preserved from the one-shot design:
/// - One job at a time (the GPU slot serialises callers).
/// - Cancel = SIGTERM, then SIGKILL after a grace period; the worker is
///   dropped and a fresh one spawns lazily for the next job.
/// - A worker that exits mid-job fails that job with its non-JSON stderr
///   text, exactly as a crashed one-shot helper did.
/// - Cross-job state is limited to the loaded model objects, which the
///   backends treat as immutable across `transcribe` calls.
actor PythonWorkerPool {
    struct Configuration: Sendable {
        var scriptURL: @Sendable () throws -> URL = { try BackendScriptWriter.ensureScript() }
        var launcher: [String] = ["/usr/bin/env", "python3"]
        var environment: @Sendable () -> [String: String] = { ProcessEnvironment.withToolPaths() }
        /// Seconds an idle worker stays alive after its last job.
        var idleTimeout: TimeInterval = 600
        /// Seconds between SIGTERM and SIGKILL, and between a shutdown
        /// request and SIGTERM.
        var killGrace: TimeInterval = 3

        init() {}
    }

    static let shared = PythonWorkerPool()

    private struct WorkerKey: Hashable {
        let backend: String
        let model: String
        let scriptPath: String
    }

    private final class Worker: @unchecked Sendable {
        let key: WorkerKey
        let process: Process
        let stdin: FileHandle
        /// Owns the stderr reader for the worker's lifetime: the collector
        /// only keeps a weak reference to itself inside the readability
        /// handler, so without this strong reference it would deallocate
        /// and every event line would be dropped on the floor.
        var stderrCollector: PipeCollector?
        private let lock = NSLock()
        private var eventSink: (@Sendable (TranscriptionStreamEvent) -> Void)?
        private var errorLines: [String] = []
        private static let maxErrorLines = 200

        init(key: WorkerKey, process: Process, stdin: FileHandle) {
            self.key = key
            self.process = process
            self.stdin = stdin
        }

        func beginJob(sink: @escaping @Sendable (TranscriptionStreamEvent) -> Void) {
            lock.withLock {
                eventSink = sink
                errorLines.removeAll()
            }
        }

        func endJob() {
            lock.withLock { eventSink = nil }
        }

        func deliver(_ event: TranscriptionStreamEvent) {
            let sink = lock.withLock { eventSink }
            sink?(event)
        }

        func recordErrorLine(_ line: String) {
            lock.withLock {
                errorLines.append(line)
                if errorLines.count > Self.maxErrorLines {
                    errorLines.removeFirst(errorLines.count - Self.maxErrorLines)
                }
            }
        }

        var errorText: String {
            lock.withLock { errorLines.joined(separator: "\n") }.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private final class ActiveJob {
        let id: String
        var continuation: CheckedContinuation<PythonJobResult, Error>?
        var isFinished = false

        init(id: String) {
            self.id = id
        }
    }

    private let configuration: Configuration
    /// Non-isolated mirror of the live worker so app termination can send
    /// SIGTERM without hopping onto the actor.
    private let liveProcess: ProcessBox
    private var worker: Worker?
    private var activeJob: ActiveJob?
    private var idleSweep: Task<Void, Never>?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        liveProcess = ProcessBox(killGrace: configuration.killGrace)
    }

    /// Runs one job, streaming progress/segment events to `onEvent` in
    /// emission order, and returns the helper's final result.
    func run(
        _ request: PythonJobRequest,
        onEvent: @escaping @Sendable (TranscriptionStreamEvent) -> Void
    ) async throws -> PythonJobResult {
        guard activeJob == nil else {
            throw TranscriptionServiceError.pythonFailed("Another transcription helper job is still running.")
        }
        try Task.checkCancellation()
        let scriptURL = try configuration.scriptURL()
        let key = WorkerKey(backend: request.backend, model: request.model, scriptPath: scriptURL.path)
        let worker = try ensureWorker(for: key, scriptURL: scriptURL)
        idleSweep?.cancel()
        idleSweep = nil

        let job = ActiveJob(id: UUID().uuidString)
        let jobID = job.id
        activeJob = job
        worker.beginJob(sink: onEvent)
        let line: Data
        do {
            line = try request.requestLine(id: job.id)
        } catch {
            activeJob = nil
            worker.endJob()
            throw TranscriptionServiceError.pythonFailed("Could not encode the transcription request: \(error.localizedDescription)")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PythonJobResult, Error>) in
                job.continuation = continuation
                if Task.isCancelled {
                    // Cancelled before the request went out: nothing to kill.
                    finish(job, with: .failure(CancellationError()), dropWorker: false)
                    return
                }
                do {
                    try worker.stdin.write(contentsOf: line)
                } catch {
                    finish(
                        job,
                        with: .failure(
                            TranscriptionServiceError.pythonFailed(
                                "Could not send the job to the transcription helper: \(error.localizedDescription)")),
                        dropWorker: true)
                }
            }
        } onCancel: {
            Task { await self.cancel(jobID: jobID) }
        }
    }

    /// Asks the resident worker (if any) to exit and waits, bounded by the
    /// kill grace period, forcing termination if it lingers. Used on app
    /// termination and by tests.
    func shutdown() async {
        guard let worker else { return }
        self.worker = nil
        liveProcess.process = nil
        if let job = activeJob {
            finish(job, with: .failure(CancellationError()), dropWorker: false)
        }
        requestShutdown(worker)
        let deadline = ContinuousClock.now + .seconds(configuration.killGrace)
        while worker.process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if worker.process.isRunning {
            worker.process.terminate()
            let killDeadline = ContinuousClock.now + .seconds(configuration.killGrace)
            while worker.process.isRunning, ContinuousClock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if worker.process.isRunning {
                kill(worker.process.processIdentifier, SIGKILL)
            }
        }
    }

    /// SIGTERM for the live worker from any thread, for app termination
    /// paths that cannot await. The orphan reaper covers anything that
    /// survives the app itself.
    nonisolated func terminateImmediately() {
        liveProcess.terminate()
    }

    /// Process id of the resident worker, or nil when none is alive.
    func residentWorkerPID() -> Int32? {
        guard let worker, worker.process.isRunning else { return nil }
        return worker.process.processIdentifier
    }

    // MARK: - Worker lifecycle

    private func ensureWorker(for key: WorkerKey, scriptURL: URL) throws -> Worker {
        if let worker, worker.key == key, worker.process.isRunning {
            return worker
        }
        if let stale = worker {
            self.worker = nil
            liveProcess.process = nil
            requestShutdown(stale)
        }
        let worker = try spawn(key: key, scriptURL: scriptURL)
        self.worker = worker
        liveProcess.process = worker.process
        return worker
    }

    private func spawn(key: WorkerKey, scriptURL: URL) throws -> Worker {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.launcher[0])
        process.arguments = Array(configuration.launcher.dropFirst()) + [scriptURL.path, "--serve"]
        var environment = configuration.environment()
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        // stdout carries nothing in --serve mode; stray library prints are
        // discarded rather than accumulated for the worker's lifetime.
        process.standardOutput = FileHandle.nullDevice

        let worker = Worker(key: key, process: process, stdin: stdinPipe.fileHandleForWriting)
        let stderr = PipeCollector(retainsData: false) { [weak self, weak worker] line in
            guard let worker else { return }
            if let envelope = ServeEnvelope.decode(line) {
                Task { await self?.complete(envelope, from: worker) }
                return
            }
            if let event = TranscriptionStreamEvent.decode(line) {
                // Delivered synchronously on the pipe's queue so events stay
                // in emission order; the caller hops to the main actor.
                worker.deliver(event)
            } else if !line.hasPrefix("{") {
                worker.recordErrorLine(line)
            }
        }
        process.standardError = stderr.pipe
        worker.stderrCollector = stderr
        process.terminationHandler = { [weak self, weak worker] process in
            let status = process.terminationStatus
            Task { await self?.workerExited(worker, status: status) }
        }
        do {
            try process.run()
        } catch {
            throw TranscriptionServiceError.pythonFailed(
                "Could not start the Python transcription helper: \(error.localizedDescription)")
        }
        return worker
    }

    /// Polite exit: the helper's serve loop ends on the shutdown line or on
    /// stdin EOF; SIGTERM follows after the grace period if it is still
    /// running (e.g. stuck in native code), and SIGKILL after another.
    private func requestShutdown(_ worker: Worker) {
        try? worker.stdin.write(contentsOf: Data("{\"event\":\"shutdown\"}\n".utf8))
        try? worker.stdin.close()
        let box = ProcessBox(killGrace: configuration.killGrace)
        box.process = worker.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + configuration.killGrace) {
            box.terminate()
        }
    }

    private func complete(_ envelope: ServeEnvelope, from worker: Worker) {
        guard worker === self.worker, let job = activeJob, envelope.id == job.id else { return }
        if envelope.event == "result", let backend = envelope.backend, let segments = envelope.segments {
            finish(job, with: .success(PythonJobResult(backend: backend, segments: segments)), dropWorker: false)
        } else {
            let message = envelope.message ?? "The transcription helper returned an unreadable result."
            finish(job, with: .failure(TranscriptionServiceError.pythonFailed(message)), dropWorker: false)
        }
    }

    private func workerExited(_ exited: Worker?, status: Int32) {
        guard let exited, exited === worker else { return }
        worker = nil
        liveProcess.process = nil
        if let job = activeJob {
            let text = exited.errorText
            finish(
                job,
                with: .failure(
                    TranscriptionServiceError.pythonFailed(
                        text.isEmpty ? "The Python helper exited with status \(status)." : text)),
                dropWorker: false)
        }
    }

    private func cancel(jobID: String) {
        guard let job = activeJob, job.id == jobID else { return }
        if let worker {
            self.worker = nil
            liveProcess.process = nil
            worker.endJob()
            // Same escalation as the one-shot helper: SIGTERM now, SIGKILL
            // after the grace period if Python never reaches its handler.
            let box = ProcessBox(killGrace: configuration.killGrace)
            box.process = worker.process
            box.terminate()
        }
        finish(job, with: .failure(CancellationError()), dropWorker: false)
    }

    private func finish(_ job: ActiveJob, with result: Result<PythonJobResult, Error>, dropWorker: Bool) {
        guard !job.isFinished else { return }
        job.isFinished = true
        if activeJob === job {
            activeJob = nil
        }
        worker?.endJob()
        if dropWorker, let worker {
            self.worker = nil
            liveProcess.process = nil
            requestShutdown(worker)
        }
        scheduleIdleSweep()
        job.continuation?.resume(with: result)
        job.continuation = nil
    }

    private func scheduleIdleSweep() {
        idleSweep?.cancel()
        guard worker != nil else { return }
        idleSweep = Task { [idleTimeout = configuration.idleTimeout] in
            try? await Task.sleep(for: .seconds(idleTimeout))
            guard !Task.isCancelled else { return }
            evictIdleWorker()
        }
    }

    private func evictIdleWorker() {
        guard activeJob == nil, let worker else { return }
        self.worker = nil
        liveProcess.process = nil
        requestShutdown(worker)
    }
}
