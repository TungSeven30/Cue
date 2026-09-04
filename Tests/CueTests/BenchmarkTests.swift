import Foundation
import Testing
@testable import Cue

/// Wall-clock benchmarks for the paths the performance work targets. They
/// are skipped unless `CUE_BENCH=1` so the normal suite stays fast, and they
/// print one `BENCH <name> <seconds>` line each so a shell pipeline can
/// collect before/after numbers:
///
///     CUE_BENCH=1 script/run_tests.sh 2>&1 | grep '^BENCH'
@Suite(.serialized) struct BenchmarkTests {
    private static var enabled: Bool { ProcessInfo.processInfo.environment["CUE_BENCH"] == "1" }

    private func report(_ name: String, _ seconds: Double) {
        print("BENCH \(name) \(String(format: "%.4f", seconds))")
    }

    private func timed(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    private func timedAsync(_ body: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    // MARK: - Launch

    /// Reads the real job history the way AppModel does at launch. The store
    /// is only read: loadJobs writes nothing unless a legacy jobs.json exists.
    @Test @MainActor func launchLoadJobsFromRealStore() {
        guard Self.enabled else { return }
        let store = JobStore()
        var count = 0
        let seconds = timed { count = store.loadJobs().count }
        report("launch.loadJobs(\(count)jobs)", seconds)
    }

    // MARK: - Signal processing

    @Test func plannerOnTwoHourSignal() {
        guard Self.enabled else { return }
        let rate = 16_000
        let samples = (0..<(rate * 7200)).map { i -> Float in
            let t = Double(i) / Double(rate)
            return Int(t / 100) % 7 == 3 ? 0 : Float(0.25 * sin(2 * .pi * 220 * t))
        }
        let seconds = timed { _ = TranscriptionChunkPlanner.planSpeechChunks(samples: samples, sampleRate: rate) }
        report("planner.rms2h", seconds)
    }

    @Test func pcmLoadTwoHourWav() throws {
        guard Self.enabled else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = 16_000 * 7200
        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { buffer in
            let words = buffer.bindMemory(to: Int16.self)
            for i in 0..<count {
                words[i] = Int16(truncatingIfNeeded: i &* 7919)
            }
        }
        var wav = AudioExtractor.wavHeader(dataLength: UInt32(pcm.count))
        wav.append(pcm)
        try wav.write(to: url)
        let seconds = timed { _ = try? WhisperCppEngine.loadPCM16AsFloat(url) }
        report("engine.pcmLoad2h", seconds)
    }

    // MARK: - Native engine

    @Test func nativeEngineFirstAndSecondRun() async throws {
        guard Self.enabled, let modelURL = BenchmarkFixtures.installedModelURL() else { return }
        let wav = try await BenchmarkFixtures.spokenFixtureWAV()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        func run() async throws -> Double {
            try await timedAsync {
                _ = try await WhisperCppEngine().transcribe(
                    wavURL: wav, modelURL: modelURL, language: "en", beamSize: 5, noSpeechThreshold: 0.6,
                    onProgress: { _ in }, isCancelled: { false })
            }
        }
        report("engine.first(\(modelURL.lastPathComponent))", try await run())
        report("engine.second", try await run())
        report("engine.third", try await run())
    }

    // MARK: - Main-thread work while a job streams

    /// Approximates what the views ask of AppModel on every streamed batch
    /// with a large history loaded: the detail pane reads the current job a
    /// couple of dozen times, recomputes quality warnings for the displayed
    /// transcript, and the sidebar recomputes its summary.
    @Test @MainActor func mainThreadWorkPerStreamedBatchWithLargeHistory() async throws {
        guard Self.enabled else { return }
        let fixture = try await BenchmarkFixtures.makeModel(historyJobs: 600)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.addVideos(urls: [fixture.baseURL.appendingPathComponent("streaming.mp4")])
        guard let jobID = model.selectedJobID, let index = model.jobs.firstIndex(where: { $0.id == jobID }) else {
            Issue.record("no selected job")
            return
        }
        model.jobs[index].status = .transcribing
        let batches = 1_500
        let seconds = timed {
            for batch in 0..<batches {
                let start = Double(batch) * 2
                model.jobs[index].partialTranscriptSegments.append(
                    TranscriptionSegment(id: batch + 1, start: start, end: start + 1.5, text: "Streamed segment number \(batch)"))
                for _ in 0..<20 {
                    _ = model.currentJob
                }
                _ = model.isSelectedJobRunning
                _ = model.canTranslate
                _ = model.qualityWarnings(for: model.displayTranscriptSegments)
                _ = model.queueSummaryText
                _ = model.hasPendingWork
            }
        }
        report("ui.streamTick(600jobs,\(batches)batches)", seconds)
        report("ui.streamTick.perBatchMs", seconds / Double(batches) * 1000)
    }

    // MARK: - Ingestion

    @Test @MainActor func watchFolderIngestionOfTwoHundredFiles() async throws {
        guard Self.enabled else { return }
        let fixture = try await BenchmarkFixtures.makeModel(historyJobs: 50)
        defer { fixture.cleanUp() }
        let folderID = UUID()
        let urls = (0..<200).map { fixture.baseURL.appendingPathComponent("ingest-\($0).mp4") }
        for url in urls {
            try Data("x".utf8).write(to: url)
        }
        let seconds = timed {
            fixture.model.ingestWatchFolderFiles(urls, folderID: folderID)
            fixture.model.flushPendingWork()
        }
        report("ingest.watch200", seconds)
    }
}

enum BenchmarkFixtures {
    static func installedModelURL() -> URL? {
        let downloader = ModelDownloader()
        return ModelDownloader.models.reversed().lazy
            .map { downloader.destinationURL(for: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// About 17 seconds of speech from the system voice, extracted to the
    /// 16 kHz mono WAV the engine consumes. `repeats` concatenates the clip
    /// that many times with `gapSeconds` of digital silence between copies,
    /// which gives the chunk planner a guaranteed cut point. The returned
    /// URL lives in its own temp directory; callers remove the directory.
    static func spokenFixtureWAV(repeats: Int = 1, gapSeconds: Double = 0) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appendingPathComponent("fixture.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", aiff.path,
            "The quick brown fox jumps over the lazy dog. This is a benchmark clip for the transcription engine. We repeat this sentence so the clip is long enough to matter. The quick brown fox jumps over the lazy dog again, and the engine keeps listening.",
        ]
        try say.run()
        say.waitUntilExit()
        let wav = dir.appendingPathComponent("fixture.wav")
        try await AudioExtractor.extract(from: aiff, to: wav)
        guard repeats > 1 || gapSeconds > 0 else { return wav }

        // AudioExtractor writes the canonical 44-byte header, so the PCM
        // payload is everything after it.
        let single = try Data(contentsOf: wav)
        let pcm = single.subdata(in: 44..<single.count)
        let gap = Data(count: Int(gapSeconds * 16_000) * 2)
        var payload = Data()
        for index in 0..<max(1, repeats) {
            if index > 0 { payload.append(gap) }
            payload.append(pcm)
        }
        var combined = AudioExtractor.wavHeader(dataLength: UInt32(payload.count))
        combined.append(payload)
        let combinedURL = dir.appendingPathComponent("fixture-\(repeats)x.wav")
        try combined.write(to: combinedURL)
        return combinedURL
    }

    @MainActor
    struct ModelFixture {
        let model: AppModel
        let baseURL: URL
        let defaults: UserDefaults
        let suiteName: String

        func cleanUp() {
            model.flushPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    /// An AppModel over a temp store pre-populated with `historyJobs`
    /// finished jobs, each carrying a modest transcript, so per-tick costs
    /// that scale with history are visible.
    @MainActor
    static func makeModel(historyJobs: Int) async throws -> ModelFixture {
        let suiteName = "bench-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let seedStore = JobStore(baseURL: baseURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for index in 0..<historyJobs {
            let segments = (0..<60).map { i in
                "{\"id\":\(i + 1),\"start\":\(Double(i) * 2),\"end\":\(Double(i) * 2 + 1.5),\"text\":\"History job \(index) line \(i)\"}"
            }.joined(separator: ",")
            let json = """
                {
                  "id": "\(UUID().uuidString)",
                  "sourcePath": "\(baseURL.path)/history-\(index).mp4",
                  "createdAt": "2026-01-01T00:00:00Z",
                  "updatedAt": "2026-01-02T00:00:00Z",
                  "status": "transcriptionComplete",
                  "progress": {"stage": "complete", "detail": "done", "fraction": 1},
                  "settings": {"sourceLanguage": "auto", "whisperModel": "m", "whisperBackend": "whisper-cpp", "openAIModel": "gpt-5.2"},
                  "transcriptSegments": [\(segments)],
                  "translatedSegments": [],
                  "orderIndex": \(Double(index)),
                  "log": "done\\n"
                }
                """
            seedStore.saveJob(try decoder.decode(TranscriptionJob.self, from: Data(json.utf8)))
        }
        seedStore.flush()
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = false
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            diagnosticsService: BenchmarkDiagnostics()
        )
        return ModelFixture(model: model, baseURL: baseURL, defaults: defaults, suiteName: suiteName)
    }
}

private actor BenchmarkDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}
