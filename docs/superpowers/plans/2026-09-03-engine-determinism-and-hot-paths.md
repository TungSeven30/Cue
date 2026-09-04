# Engine Determinism and Hot Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep model weights resident across jobs with fresh per-job (and per-chunk) inference state, hydrate the job store off the main actor, remove the streaming-time hot-path recomputation in the UI, make watch folders react to nested changes, batch persistence, vectorise the signal-processing loops, and fix the MKV failure on the built-in engine, all without changing inference semantics.

**Architecture:** A new `WhisperModelCache` actor owns `whisper_context` weights loaded with `_no_state`; `WhisperCppEngine` creates one `whisper_state` per chunk and reads results through the `_from_state` API. A new `PythonWorkerPool` keeps one helper process alive per (backend, model) using a `--serve` mode added to the embedded script. `JobStore` decodes concurrently with deterministic ordering and `AppModel` hydrates asynchronously with a merge step. UI hot paths get an id→index cache, a warning cache keyed on array identity, Equatable rows, and visibility gating. `WatchFolderService` moves to FSEvents with a follow-up scan.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, whisper.cpp v1.7.2 C API, Accelerate/vDSP, CoreServices FSEvents, Foundation `Process`, Python 3 (embedded helper), swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-03-engine-determinism-and-hot-paths-design.md`

**Status (2026-09-03):** all twelve tasks landed on `perf/engine-determinism-and-hot-paths`.
Deviations from the text below, made during implementation and recorded in
the spec: the helper's `--serve` result line travels on stderr (one ordered
pipe), the worker pool keys on script path rather than a hash, the Python
worker benchmark lives in `BenchmarkTests` rather than a separate script,
and the diagnostics probe was rewritten to await its pipes instead of
blocking a cooperative thread (a pre-existing deadlock found by the
baseline run). Before/after numbers: `2026-09-03-benchmarks.md`.

## Global Constraints

- Swift language mode 6, macOS 14 deployment target; build must pass `swift build -c release -Xswiftc -warnings-as-errors`.
- Run tests with `script/run_tests.sh`, never `swift test` (CLT-only machine runs zero tests otherwise).
- `transcribe.py` is generated: edit `BackendScript.source`, run `python3 script/sync_backend_script.py`, commit both.
- No inference-semantics changes: no `flash_attn`, no decoding parameter, prompt, model, chunk-boundary, or translation-scheduling changes.
- whisper.cpp stays pinned at v1.7.2 (`6266a9f`); no new SwiftPM dependencies.
- Format with `script/format_swift.sh`; `script/lint_swift.sh` must pass.
- Commit after every task; commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Benchmark harness (baseline numbers before any change)

**Files:**
- Create: `Tests/CueTests/BenchmarkTests.swift`
- Create: `script/bench_python_worker.py` (later used by Task 6; here only the launch/planner/engine benchmarks run)

**Interfaces:**
- Produces: `CUE_BENCH=1 script/run_tests.sh` prints `BENCH <name> <seconds>` lines to stdout for: `launch.loadJobs`, `planner.rms2h`, `engine.pcmLoad2h`, `engine.first`, `engine.second`, `engine.chunked.first`, `engine.chunked.second`.

- [ ] **Step 1: Write the benchmark suite (skips unless `CUE_BENCH=1`)**

```swift
import Foundation
import Testing
@testable import Cue

/// Wall-clock benchmarks. Skipped unless CUE_BENCH=1 so the normal suite
/// stays fast; results print as "BENCH <name> <seconds>".
@Suite(.serialized) struct BenchmarkTests {
    private static var enabled: Bool { ProcessInfo.processInfo.environment["CUE_BENCH"] == "1" }

    private func report(_ name: String, _ seconds: Double) {
        print(String(format: "BENCH %@ %.4f", name, seconds))
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

    @Test @MainActor func launchLoadJobsFromRealStore() throws {
        guard Self.enabled else { return }
        // The real store is read-only here: loadJobs never writes unless a
        // legacy jobs.json exists, and a corrupt file is copied, not moved.
        let store = JobStore()
        var count = 0
        let seconds = timed { count = store.loadJobs().count }
        report("launch.loadJobs(\(count) jobs)", seconds)
    }

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
            for i in 0..<count { words[i] = Int16(truncatingIfNeeded: i &* 7919) }
        }
        var wav = AudioExtractor.wavHeader(dataLength: UInt32(pcm.count))
        wav.append(pcm)
        try wav.write(to: url)
        let seconds = timed { _ = try? WhisperCppEngine.loadPCM16AsFloat(url) }
        report("engine.pcmLoad2h", seconds)
    }

    @Test func nativeEngineFirstAndSecondRun() async throws {
        guard Self.enabled, let modelURL = BenchmarkFixtures.installedModelURL() else { return }
        let wav = try await BenchmarkFixtures.spokenFixtureWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        func run() async throws -> Double {
            try await timedAsync {
                _ = try await WhisperCppEngine().transcribe(
                    wavURL: wav, modelURL: modelURL, language: "en", beamSize: 5, noSpeechThreshold: 0.6,
                    onProgress: { _ in }, isCancelled: { false })
            }
        }
        report("engine.first", try await run())
        report("engine.second", try await run())
    }
}

enum BenchmarkFixtures {
    static func installedModelURL() -> URL? {
        let downloader = ModelDownloader()
        return ModelDownloader.models.reversed().lazy
            .map { downloader.destinationURL(for: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// ~17 s of speech from the system voice, extracted to 16 kHz mono.
    static func spokenFixtureWAV() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-fixture-\(UUID().uuidString)", isDirectory: true)
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
        return wav
    }
}
```

- [ ] **Step 2: Run the benchmarks on the untouched code and record the numbers**

Run: `CUE_BENCH=1 script/run_tests.sh 2>&1 | grep '^BENCH'`
Expected: seven `BENCH` lines. Paste them into `docs/superpowers/plans/2026-09-03-benchmarks.md` under "Before".

- [ ] **Step 3: Commit**

```bash
git add Tests/CueTests/BenchmarkTests.swift docs/superpowers/plans/2026-09-03-benchmarks.md
git commit -m "Add opt-in wall-clock benchmarks for launch, planner, and engine paths"
```

---

### Task 2: vDSP planner and PCM conversion, bisect candidate search

**Files:**
- Modify: `Sources/Services/TranscriptionChunkPlanner.swift:63-147`
- Modify: `Sources/Services/WhisperCppEngine.swift:274-326`
- Modify: `Sources/Support/BackendScriptWriter.swift` (plan_speech_chunks window search) and regenerate `transcribe.py`
- Create: `Tests/CueTests/ChunkPlannerVectorTests.swift`

**Interfaces:**
- Produces: `TranscriptionChunkPlanner.frameRMS(samples:frame:) -> [Float]` (internal, vDSP), `TranscriptionChunkPlanner.referenceFrameRMS(samples:frame:) -> [Float]` (internal, scalar reference kept for tests), `TranscriptionChunkPlanner.silenceCandidates(rms:frameSeconds:threshold:minSilence:) -> [Double]`, `TranscriptionChunkPlanner.chooseCuts(candidates:totalSeconds:minSilence:targetChunk:maxChunk:firstTarget:) -> [SpeechChunk]`.

- [ ] **Step 1: Write failing tests that pin the vectorised paths to the scalar reference**

```swift
import Accelerate
import Foundation
import Testing
@testable import Cue

@Suite struct ChunkPlannerVectorTests {
    private let rate = 16_000

    private func tone(seconds: Double, amplitude: Float = 0.25) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
    }

    private func noise(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
        }
    }

    private var signals: [[Float]] {
        var interleaved: [Float] = []
        for _ in 0..<8 {
            interleaved += tone(seconds: 100)
            interleaved += [Float](repeating: 0, count: 2 * rate)
        }
        return [
            interleaved,
            noise(seconds: 700, seed: 7),
            tone(seconds: 700, amplitude: 1.0),  // full-scale, no silence
            [Float](repeating: 0, count: 700 * rate),  // all silence
        ]
    }

    @Test func vectorisedRMSMatchesScalarReferenceWithinEpsilon() {
        for samples in signals {
            let frame = 800
            let fast = TranscriptionChunkPlanner.frameRMS(samples: samples, frame: frame)
            let reference = TranscriptionChunkPlanner.referenceFrameRMS(samples: samples, frame: frame)
            #expect(fast.count == reference.count)
            for (a, b) in zip(fast, reference) {
                #expect(abs(a - b) <= max(1e-6, abs(b) * 1e-5))
            }
        }
    }

    @Test func plannerDecisionsAreIdenticalToScalarReference() {
        for samples in signals {
            let fast = TranscriptionChunkPlanner.planSpeechChunks(samples: samples, sampleRate: rate, targetChunk: 150, maxChunk: 300)
            let reference = TranscriptionChunkPlanner.referencePlanSpeechChunks(samples: samples, sampleRate: rate, targetChunk: 150, maxChunk: 300)
            #expect(fast == reference)
        }
    }

    @Test func bisectWindowSearchMatchesLinearSearch() {
        let candidates: [Double] = [3, 17, 44.5, 90, 91, 150, 299, 301, 480, 650]
        let fast = TranscriptionChunkPlanner.chooseCuts(candidates: candidates, totalSeconds: 700, minSilence: 0.5, targetChunk: 150, maxChunk: 300, firstTarget: 90)
        let reference = TranscriptionChunkPlanner.referenceChooseCuts(candidates: candidates, totalSeconds: 700, minSilence: 0.5, targetChunk: 150, maxChunk: 300, firstTarget: 90)
        #expect(fast == reference)
    }

    @Test func pcmConversionIsBitExact() throws {
        let samples: [Int16] = (0..<50_000).map { Int16(truncatingIfNeeded: $0 &* 7919) } + [Int16.min, Int16.max, 0, -1, 1]
        var data = Data()
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        var wav = AudioExtractor.wavHeader(dataLength: UInt32(data.count))
        wav.append(data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let floats = try WhisperCppEngine.loadPCM16AsFloat(url)
        #expect(floats.count == samples.count)
        for (float, sample) in zip(floats, samples) {
            #expect(float.bitPattern == (Float(sample) / 32_768).bitPattern)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `script/run_tests.sh` → compile errors for the missing `frameRMS`, `referenceFrameRMS`, `referencePlanSpeechChunks`, `chooseCuts`, `referenceChooseCuts`.

- [ ] **Step 3: Implement the planner split (vDSP RMS, bisect, scalar reference kept internal)**

```swift
import Accelerate
import Foundation

enum TranscriptionChunkPlanner {
    // … existing constants, pendingChunks, mergePartialSegments, combinedSegments unchanged …

    static func planSpeechChunks(samples: [Float], sampleRate: Int, minSilence: Double = defaultMinSilence,
                                 targetChunk: Double = defaultTargetChunk, maxChunk: Double = defaultMaxChunk,
                                 firstTarget: Double = defaultFirstTarget) -> [SpeechChunk] {
        plan(samples: samples, sampleRate: sampleRate, minSilence: minSilence, targetChunk: targetChunk,
             maxChunk: maxChunk, firstTarget: firstTarget, rms: frameRMS, cuts: chooseCuts)
    }

    /// Scalar implementation kept only as the oracle for the vector tests.
    static func referencePlanSpeechChunks(samples: [Float], sampleRate: Int, minSilence: Double = defaultMinSilence,
                                          targetChunk: Double = defaultTargetChunk, maxChunk: Double = defaultMaxChunk,
                                          firstTarget: Double = defaultFirstTarget) -> [SpeechChunk] {
        plan(samples: samples, sampleRate: sampleRate, minSilence: minSilence, targetChunk: targetChunk,
             maxChunk: maxChunk, firstTarget: firstTarget, rms: referenceFrameRMS, cuts: referenceChooseCuts)
    }

    private static func plan(
        samples: [Float], sampleRate: Int, minSilence: Double, targetChunk: Double, maxChunk: Double, firstTarget: Double,
        rms: ([Float], Int) -> [Float],
        cuts: ([Double], Double, Double, Double, Double, Double) -> [SpeechChunk]
    ) -> [SpeechChunk] {
        let totalSeconds = Double(samples.count) / Double(sampleRate)
        if totalSeconds <= maxChunk { return [SpeechChunk(start: 0, end: totalSeconds)] }
        let frame = max(1, Int(Double(sampleRate) * 0.05))
        let values = rms(samples, frame)
        guard let peak = values.max(), peak > 0 else { return [SpeechChunk(start: 0, end: totalSeconds)] }
        let sorted = values.sorted()
        let percentileIndex = Int(Double(sorted.count - 1) * 0.95)
        let reference = sorted[max(0, min(percentileIndex, sorted.count - 1))]
        let threshold = max(1.0 / 32_768.0, 0.1 * Double(reference))
        let frameSeconds = Double(frame) / Double(sampleRate)
        let candidates = silenceCandidates(rms: values, frameSeconds: frameSeconds, threshold: threshold, minSilence: minSilence)
        guard !candidates.isEmpty else { return [SpeechChunk(start: 0, end: totalSeconds)] }
        return cuts(candidates, totalSeconds, minSilence, targetChunk, maxChunk, firstTarget)
    }

    /// Per-frame RMS via vDSP. Identical frame layout to the scalar version:
    /// only whole frames count, the tail is dropped.
    static func frameRMS(samples: [Float], frame: Int) -> [Float] {
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return [] }
        var rms = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<frameCount {
                var value: Float = 0
                vDSP_rmsqv(base + index * frame, 1, &value, vDSP_Length(frame))
                rms[index] = value
            }
        }
        return rms
    }

    static func referenceFrameRMS(samples: [Float], frame: Int) -> [Float] {
        let frameCount = samples.count / frame
        var rms = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let offset = index * frame
            var sum: Float = 0
            for sample in samples[offset..<(offset + frame)] { sum += sample * sample }
            rms[index] = sqrt(sum / Float(frame))
        }
        return rms
    }

    static func silenceCandidates(rms: [Float], frameSeconds: Double, threshold: Double, minSilence: Double) -> [Double] {
        var candidates: [Double] = []
        var runStart: Int?
        for (index, value) in rms.enumerated() {
            if Double(value) < threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if Double(index - start) * frameSeconds >= minSilence {
                    candidates.append((Double(start) + Double(index - start) / 2.0) * frameSeconds)
                }
                runStart = nil
            }
        }
        if let start = runStart, Double(rms.count - start) * frameSeconds >= minSilence {
            candidates.append((Double(start) + Double(rms.count - start) / 2.0) * frameSeconds)
        }
        return candidates
    }

    /// Greedy cut selection with binary search over the ascending candidate list.
    static func chooseCuts(candidates: [Double], totalSeconds: Double, minSilence: Double,
                           targetChunk: Double, maxChunk: Double, firstTarget: Double) -> [SpeechChunk] {
        var chunks: [SpeechChunk] = []
        var start = 0.0
        for _ in 0..<10_000 {
            if totalSeconds - start <= maxChunk {
                chunks.append(SpeechChunk(start: start, end: totalSeconds)); break
            }
            // in-window: candidates in (start + minSilence, start + maxChunk]
            let lower = upperBound(candidates, start + minSilence)      // first > start+minSilence
            let upper = upperBound(candidates, start + maxChunk)        // first > start+maxChunk
            let desired = chunks.isEmpty ? firstTarget : targetChunk
            let cut: Double
            if lower < upper {
                cut = candidates[lower..<upper].min { abs($0 - (start + desired)) < abs($1 - (start + desired)) }!
            } else if upper < candidates.count {
                cut = candidates[upper]
            } else {
                chunks.append(SpeechChunk(start: start, end: totalSeconds)); break
            }
            chunks.append(SpeechChunk(start: start, end: cut))
            start = cut
        }
        return chunks
    }

    static func referenceChooseCuts(candidates: [Double], totalSeconds: Double, minSilence: Double,
                                    targetChunk: Double, maxChunk: Double, firstTarget: Double) -> [SpeechChunk] {
        // verbatim copy of the pre-existing loop body (filter / first(where:))
    }

    /// Index of the first element strictly greater than `value` (candidates ascending).
    private static func upperBound(_ values: [Double], _ value: Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
```

Note the `min(by:)` tie-break: `Array.min(by:)` returns the first minimal element in iteration order, and the slice iterates ascending exactly like the filtered array did, so ties resolve identically.

- [ ] **Step 4: Implement the vDSP PCM conversion in `loadPCM16AsFloat`**

Replace the `(0..<sampleCount).map { … }` block with:

```swift
return data.withUnsafeBytes { raw -> [Float] in
    var floats = [Float](repeating: 0, count: sampleCount)
    guard sampleCount > 0, let base = raw.baseAddress else { return floats }
    // The data chunk is not guaranteed 2-byte aligned inside the RIFF
    // container; vDSP_vflt16 needs aligned Int16, so copy the chunk
    // into an aligned scratch buffer first (one memcpy, still far
    // cheaper than a per-sample closure).
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: sampleCount)
    defer { scratch.deallocate() }
    memcpy(scratch, base + body, sampleCount * 2)
    floats.withUnsafeMutableBufferPointer { out in
        vDSP_vflt16(scratch, 1, out.baseAddress!, 1, vDSP_Length(sampleCount))
        var scale: Float = 1.0 / 32_768
        vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(sampleCount))
    }
    return floats
}
```

`Float(Int16) / 32768` and `Float(Int16) * (1/32768)` are the same IEEE value because 1/32768 is a power of two (verified bit-exact in Task 1's harness and asserted by the test).

- [ ] **Step 5: Python: bisect in `plan_speech_chunks`** — in `BackendScript.source` add `import bisect` and replace the two list comprehensions:

```python
        lower = bisect.bisect_right(candidates, start + min_silence)
        upper = bisect.bisect_right(candidates, start + max_chunk)
        desired = first_target if not chunks else target_chunk
        if lower < upper:
            cut = min(candidates[lower:upper], key=lambda c: abs(c - (start + desired)))
        elif upper < len(candidates):
            cut = candidates[upper]  # first silence after the cap beats a mid-speech cut
        else:
            chunks.append((start, total_seconds))
            break
```

Then `python3 script/sync_backend_script.py`.

- [ ] **Step 6: Run tests** — `script/run_tests.sh` → all pass including `ChunkPlannerVectorTests`, `TranscriptionResumeTests`, and the Python `test_chunk_planning.py`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Services/TranscriptionChunkPlanner.swift Sources/Services/WhisperCppEngine.swift Sources/Support/BackendScriptWriter.swift transcribe.py Tests/CueTests/ChunkPlannerVectorTests.swift
git commit -m "Vectorise chunk planning and PCM conversion with vDSP; bisect candidate search"
```

---

### Task 3: Incremental pipe collection

**Files:**
- Modify: `Sources/Services/TranscriptionService.swift:837-918` (`PipeCollector`)
- Create: `Tests/CueTests/PipeCollectorTests.swift`

**Interfaces:**
- Produces: `PipeCollector` becomes `internal` (was `private`) with `init(onLine:)`, `func ingest(_ data: Data)` (test seam that feeds bytes exactly as the readability handler does), `data()`, `text()`, `waitForEOF()`, `close()`.

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import Cue

@Suite struct PipeCollectorTests {
    @Test func linesSplitAcrossReadsDecodeIdentically() {
        let lock = NSLock()
        var lines: [String] = []
        let collector = PipeCollector { line in lock.withLock { lines.append(line) } }
        collector.ingest(Data("{\"a\":1}\n{\"b\":".utf8))
        collector.ingest(Data("2}\n{\"c\":\"é".utf8))
        collector.ingest(Data("\"}\n".utf8))
        #expect(lock.withLock { lines } == ["{\"a\":1}", "{\"b\":2}", "{\"c\":\"é\"}"])
    }

    @Test func multibyteCharacterSplitAcrossReadsIsPreserved() {
        let lock = NSLock()
        var lines: [String] = []
        let collector = PipeCollector { line in lock.withLock { lines.append(line) } }
        let bytes = Array("héllo\n".utf8)  // é is C3 A9
        collector.ingest(Data(bytes[0..<2]))
        collector.ingest(Data(bytes[2...]))
        #expect(lock.withLock { lines } == ["héllo"])
    }

    @Test func singleHugeLineIsCollectedIntactAndNotRescanned() {
        let collector = PipeCollector()  // stdout: no onLine consumer
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<400 { collector.ingest(chunk) }  // 25 MB, zero newlines
        collector.ingest(Data("\n".utf8))
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(collector.data().count == 400 * 64 * 1024 + 1)
        #expect(seconds < 1.0, "quadratic rescans took \(seconds)s")
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error (`PipeCollector` private, no `ingest`).

- [ ] **Step 3: Implement**

```swift
final class PipeCollector: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var storage = Data()
    private var pendingData = Data()
    /// Bytes of `pendingData` already known to contain no newline.
    private var scanned = 0
    private let onLine: ((String) -> Void)?
    private var didReachEOF = false
    private var eofContinuation: CheckedContinuation<Void, Never>?

    init(onLine: ((String) -> Void)? = nil) {
        self.onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; self.signalEOF() } else { self.ingest(data) }
        }
    }

    func ingest(_ data: Data) {
        var completeLines: [String] = []
        lock.lock()
        storage.append(data)
        if let onLine = onLine {
            _ = onLine
            pendingData.append(data)
            while let newlineIndex = pendingData[(pendingData.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) {
                completeLines.append(String(decoding: pendingData[pendingData.startIndex..<newlineIndex], as: UTF8.self))
                pendingData.removeSubrange(pendingData.startIndex...newlineIndex)
                scanned = 0
            }
            scanned = pendingData.count
        }
        lock.unlock()
        completeLines.forEach { onLine?($0) }
    }
    // waitForEOF, signalEOF, data(), text(), close() unchanged
}
```

- [ ] **Step 4: Run tests** → pass. **Step 5: Commit** `git commit -am "Make pipe line collection incremental and skip splitting without a consumer"`.

---

### Task 4: Resident model weights, fresh state per chunk

**Files:**
- Create: `Sources/Services/WhisperModelCache.swift`
- Modify: `Sources/Services/WhisperCppEngine.swift` (whole file)
- Modify: `Sources/Services/TranscriptionService.swift:345` (pass through; no API change)
- Modify: `Sources/Stores/AppModel.swift` `prepareForTermination` (evict cache)
- Create: `Tests/CueTests/WhisperModelCacheTests.swift`
- Modify: `Tests/CueTests/WhisperCppEngineTests.swift` (determinism tests)

**Interfaces:**
- Produces:
  ```swift
  final class WhisperModel: @unchecked Sendable { let context: OpaquePointer; let key: WhisperModelCache.Key }
  actor WhisperModelCache {
      struct Key: Hashable { let path: String; let size: Int64; let modifiedNanoseconds: Int64 }
      static let shared: WhisperModelCache
      init(idleTimeout: TimeInterval = 600, loader: @escaping @Sendable (URL) throws -> OpaquePointer = defaultLoader)
      func acquire(modelURL: URL) throws -> WhisperModel   // lease count += 1
      func release(_ model: WhisperModel)                  // lease count -= 1; starts idle timer at 0
      func evictAll()                                      // frees idle entries now
      func residentKeys() -> [Key]                         // tests
      nonisolated func handleMemoryPressure()              // hooked to a DispatchSource in the app
  }
  struct ChunkPlanning: Sendable { var minSilence, targetChunk, maxChunk, firstTarget: Double; static let `default` }
  ```
  `WhisperCppEngine.init(cache: WhisperModelCache = .shared, chunkPlanning: ChunkPlanning = .default)`; `transcribe(...)` signature unchanged.

- [ ] **Step 1: Failing cache tests (use a fake loader so no model file is needed)**

```swift
import Foundation
import Testing
@testable import Cue

@Suite struct WhisperModelCacheTests {
    private final class Ledger: @unchecked Sendable {
        let lock = NSLock()
        var loads: [String] = []
        var frees = 0
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)-\(name).bin")
        try Data("weights".utf8).write(to: url)
        return url
    }

    private func makeCache(idleTimeout: TimeInterval = 600, ledger: Ledger) -> WhisperModelCache {
        WhisperModelCache(
            idleTimeout: idleTimeout,
            loader: { url in
                ledger.lock.withLock { ledger.loads.append(url.lastPathComponent) }
                return OpaquePointer(bitPattern: 0x1)!  // never dereferenced by the fake
            },
            unloader: { _ in ledger.lock.withLock { ledger.frees += 1 } }
        )
    }

    @Test func sameModelIsLoadedOnce() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let url = try makeFile("a")
        let first = try await cache.acquire(modelURL: url)
        await cache.release(first)
        let second = try await cache.acquire(modelURL: url)
        await cache.release(second)
        #expect(ledger.lock.withLock { ledger.loads.count } == 1)
        #expect(first === second)
    }

    @Test func differentModelEvictsTheIdleOne() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let a = try makeFile("a"), b = try makeFile("b")
        let modelA = try await cache.acquire(modelURL: a)
        await cache.release(modelA)
        _ = try await cache.acquire(modelURL: b)
        #expect(await cache.residentKeys().map(\.path) == [b.path])
        #expect(ledger.lock.withLock { ledger.frees } == 1)
    }

    @Test func leasedModelSurvivesEvictionUntilReleased() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let url = try makeFile("a")
        let model = try await cache.acquire(modelURL: url)
        await cache.evictAll()
        #expect(await cache.residentKeys().count == 1)
        await cache.release(model)
        await cache.evictAll()
        #expect(await cache.residentKeys().isEmpty)
    }

    @Test func replacedModelFileInvalidatesTheEntry() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let url = try makeFile("a")
        let first = try await cache.acquire(modelURL: url)
        await cache.release(first)
        try Data("different weights".utf8).write(to: url)
        let second = try await cache.acquire(modelURL: url)
        await cache.release(second)
        #expect(ledger.lock.withLock { ledger.loads.count } == 2)
    }

    @Test func idleTimeoutFreesTheModel() async throws {
        let ledger = Ledger()
        let cache = makeCache(idleTimeout: 0.2, ledger: ledger)
        let url = try makeFile("a")
        let model = try await cache.acquire(modelURL: url)
        await cache.release(model)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await cache.residentKeys().isEmpty)
    }
}
```

- [ ] **Step 2: Implement `WhisperModelCache`**

```swift
import Foundation
import whisper

final class WhisperModel: @unchecked Sendable {
    let context: OpaquePointer
    let key: WhisperModelCache.Key
    private let unloader: @Sendable (OpaquePointer) -> Void
    init(context: OpaquePointer, key: WhisperModelCache.Key, unloader: @escaping @Sendable (OpaquePointer) -> Void) { … }
    deinit { unloader(context) }
}

actor WhisperModelCache {
    struct Key: Hashable, Sendable { let path: String; let size: Int64; let modifiedNanoseconds: Int64 }
    private struct Entry { let model: WhisperModel; var leases: Int; var idleSince: ContinuousClock.Instant? }

    static let shared = WhisperModelCache()

    private let idleTimeout: Duration
    private let loader: @Sendable (URL) throws -> OpaquePointer
    private let unloader: @Sendable (OpaquePointer) -> Void
    private var entries: [Key: Entry] = [:]
    private var idleTask: Task<Void, Never>?

    init(idleTimeout: TimeInterval = 600,
         loader: @escaping @Sendable (URL) throws -> OpaquePointer = WhisperModelCache.defaultLoader,
         unloader: @escaping @Sendable (OpaquePointer) -> Void = { whisper_free($0) }) { … }

    static func key(for url: URL) throws -> Key {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw WhisperCppError.modelLoadFailed(url.lastPathComponent) }
        return Key(path: url.path, size: Int64(info.st_size),
                   modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
    }

    func acquire(modelURL: URL) throws -> WhisperModel {
        let key = try Self.key(for: modelURL)
        if var entry = entries[key] { entry.leases += 1; entry.idleSince = nil; entries[key] = entry; return entry.model }
        evictIdle(exceptKey: key)  // capacity one: any other idle model goes now
        let context = try loader(modelURL)
        let model = WhisperModel(context: context, key: key, unloader: unloader)
        entries[key] = Entry(model: model, leases: 1, idleSince: nil)
        return model
    }

    func release(_ model: WhisperModel) {
        guard var entry = entries[model.key] else { return }
        entry.leases = max(0, entry.leases - 1)
        if entry.leases == 0 { entry.idleSince = .now; scheduleIdleSweep() }
        entries[model.key] = entry
    }

    func evictAll() { evictIdle(exceptKey: nil) }
    func residentKeys() -> [Key] { Array(entries.keys) }
    nonisolated func handleMemoryPressure() { Task { await self.evictAll() } }

    private func evictIdle(exceptKey: Key?) {
        for (key, entry) in entries where entry.leases == 0 && key != exceptKey { entries[key] = nil }
    }

    private func scheduleIdleSweep() {
        idleTask?.cancel()
        idleTask = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            self.sweepExpired()
        }
    }

    private func sweepExpired() {
        let now = ContinuousClock.now
        for (key, entry) in entries where entry.leases == 0 {
            if let since = entry.idleSince, now - since >= idleTimeout { entries[key] = nil }
        }
    }

    static let defaultLoader: @Sendable (URL) throws -> OpaquePointer = { url in
        _ = metalShaderPathConfigured
        let params = whisper_context_default_params()
        guard let context = whisper_init_from_file_with_params_no_state(url.path, params) else {
            throw WhisperCppError.modelLoadFailed(url.lastPathComponent)
        }
        return context
    }
    // metalShaderPathConfigured moves here from WhisperCppEngine.
}
```

Memory pressure: in `AppModel.init` register `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))` whose handler calls `WhisperModelCache.shared.handleMemoryPressure()`; store the source in a property so it stays alive; `prepareForTermination` calls `evictAll()` via a `Task`. Note the entry is freed when the last reference to `WhisperModel` drops; since inference holds the `WhisperModel` for the duration of `transcribe`, `deinit` cannot run while a state exists.

- [ ] **Step 3: Refactor `WhisperCppEngine` to per-chunk states**

```swift
struct ChunkPlanning: Sendable {
    var minSilence = TranscriptionChunkPlanner.defaultMinSilence
    var targetChunk = TranscriptionChunkPlanner.defaultTargetChunk
    var maxChunk = TranscriptionChunkPlanner.defaultMaxChunk
    var firstTarget = TranscriptionChunkPlanner.defaultFirstTarget
    static let `default` = ChunkPlanning()
}

actor WhisperCppEngine {
    private let cache: WhisperModelCache
    private let chunkPlanning: ChunkPlanning
    init(cache: WhisperModelCache = .shared, chunkPlanning: ChunkPlanning = .default) { … }

    func transcribe(wavURL:modelURL:language:beamSize:noSpeechThreshold:resumeThrough:startingSegmentID:onProgress:onSegments:onChunkComplete:isCancelled:) async throws -> Result {
        let samples = try Self.loadPCM16AsFloat(wavURL)
        let planned = TranscriptionChunkPlanner.planSpeechChunks(samples: samples, sampleRate: 16_000,
            minSilence: chunkPlanning.minSilence, targetChunk: chunkPlanning.targetChunk,
            maxChunk: chunkPlanning.maxChunk, firstTarget: chunkPlanning.firstTarget)
        let pending = TranscriptionChunkPlanner.pendingChunks(planned, resumeThrough: resumeThrough)
        guard !pending.isEmpty else { return Result(segments: []) }
        let model = try await cache.acquire(modelURL: modelURL)
        defer { Task { await cache.release(model) } }   // see note below: release via a detached hop
        // single-chunk fast path and chunk loop as today, but each call:
        let batch = try Self.runInference(model: model, samples: slice, …)
    }

    private static func runInference(model: WhisperModel, samples: [Float], …) throws -> [TranscriptionSegment] {
        guard let state = whisper_init_state(model.context) else { throw WhisperCppError.inferenceFailed(-1) }
        defer { whisper_free_state(state) }
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        // … identical params …
        params.new_segment_callback = { _, state, nNew, userData in
            guard let state, let userData, nNew > 0 else { return }
            let total = Int(whisper_full_n_segments_from_state(state))
            // map via whisper_full_get_segment_t0_from_state / t1_from_state / text_from_state
        }
        let status = withExtendedLifetime(box) { … whisper_full_with_state(model.context, state, params, samples, Int32(samples.count)) … }
        let count = Int(whisper_full_n_segments_from_state(state))
        // read segments with the _from_state accessors
    }
}
```

`release` must run even if the caller's task is cancelled; use `withTaskCancellationHandler` is not needed because `defer` runs on the actor; to avoid awaiting inside `defer`, call `cache.releaseNonisolated(model)` implemented as `nonisolated func release(_:) { Task { await self.releaseOnActor(model) } }` — the lease decrement is asynchronous but ordered per model. Tests that inspect eviction call `await cache.settle()` (an actor method that awaits nothing but runs after queued hops) before asserting.

- [ ] **Step 4: Determinism tests (model-gated)**

```swift
@Test func repeatedTranscriptionsAreByteIdentical() async throws {
    guard let modelURL = BenchmarkFixtures.installedModelURL() else { return }
    let wav = try await BenchmarkFixtures.spokenFixtureWAV()
    defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
    let cache = WhisperModelCache()
    func run() async throws -> [TranscriptionSegment] {
        try await WhisperCppEngine(cache: cache).transcribe(wavURL: wav, modelURL: modelURL, language: "en",
            beamSize: 5, noSpeechThreshold: 0.6, onProgress: { _ in }, isCancelled: { false }).segments
    }
    let first = try await run()
    let second = try await run()          // resident weights, fresh state
    await cache.evictAll()
    let cold = try await run()            // cold load
    #expect(first == second)
    #expect(first == cold)
    #expect(!first.isEmpty)
}

@Test func multiChunkRunsAreDeterministic() async throws {
    guard let modelURL = BenchmarkFixtures.installedModelURL() else { return }
    let wav = try await BenchmarkFixtures.spokenFixtureWAV()   // ~17 s with pauses
    defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
    let planning = ChunkPlanning(minSilence: 0.3, targetChunk: 6, maxChunk: 9, firstTarget: 5)
    let cache = WhisperModelCache()
    var chunkEnds: [[Double]] = []
    func run() async throws -> [TranscriptionSegment] {
        var ends: [Double] = []
        let result = try await WhisperCppEngine(cache: cache, chunkPlanning: planning).transcribe(
            wavURL: wav, modelURL: modelURL, language: "en", beamSize: 5, noSpeechThreshold: 0.6,
            onProgress: { _ in }, onChunkComplete: { ends.append($0) }, isCancelled: { false })
        chunkEnds.append(ends)
        return result.segments
    }
    let a = try await run(), b = try await run()
    #expect(chunkEnds[0].count >= 2, "fixture must split into several chunks")
    #expect(chunkEnds[0] == chunkEnds[1])
    #expect(a == b)
}

@Test func cancellationStopsInferenceAndLeavesCacheUsable() async throws {
    guard let modelURL = BenchmarkFixtures.installedModelURL() else { return }
    let wav = try await BenchmarkFixtures.spokenFixtureWAV()
    defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
    let cache = WhisperModelCache()
    let flag = OSAllocatedUnfairLock(initialState: false)
    let task = Task {
        try await WhisperCppEngine(cache: cache).transcribe(wavURL: wav, modelURL: modelURL, language: "en",
            beamSize: 5, noSpeechThreshold: 0.6, onProgress: { _ in },
            onSegments: { _ in flag.withLock { $0 = true } }, isCancelled: { flag.withLock { $0 } })
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    let after = try await WhisperCppEngine(cache: cache).transcribe(wavURL: wav, modelURL: modelURL, language: "en",
        beamSize: 5, noSpeechThreshold: 0.6, onProgress: { _ in }, isCancelled: { false })
    #expect(!after.segments.isEmpty)
}
```

(`onChunkComplete` closures are `@Sendable`; collect through an `OSAllocatedUnfairLock` in the real test.)

- [ ] **Step 5: Run tests, then commit** `git commit -am "Keep whisper weights resident; fresh whisper_state per chunk for deterministic output"`.

---

### Task 5: MKV fallback and extractor robustness

**Files:**
- Create: `Sources/Services/FFmpegAudioExtractor.swift`
- Modify: `Sources/Services/AudioExtractor.swift:104-116` (contiguity guard)
- Modify: `Sources/Services/TranscriptionService.swift:296-317` (`transcribeNatively`)
- Create: `Tests/CueTests/AudioExtractionFallbackTests.swift`

**Interfaces:**
- Produces: `enum FFmpegAudioExtractor { static func extract(from: URL, to: URL, environment: [String: String] = ProcessEnvironment.withToolPaths()) async throws }`, `struct FFmpegUnavailableError: LocalizedError`, and `enum AudioSourceExtractor { static func extract(from:to:hasFFmpeg:progress:) async throws -> ExtractionRoute }` where `ExtractionRoute` is `.native` or `.ffmpeg`.

- [ ] **Step 1: Failing tests**

```swift
@Suite struct AudioExtractionFallbackTests {
    private func ffmpegPath() -> String? { ProcessEnvironment.toolExists("ffmpeg") ? "ffmpeg" : nil }

    @Test func mkvFallsBackToFFmpegWhenNativeCannotOpenIt() async throws {
        guard ffmpegPath() != nil else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mkv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 2 s of 440 Hz in an MKV container, made by ffmpeg itself.
        let mkv = dir.appendingPathComponent("tone.mkv")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        make.environment = ProcessEnvironment.withToolPaths()
        make.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "aac", mkv.path]
        try make.run(); make.waitUntilExit()
        try #require(make.terminationStatus == 0)
        let out = dir.appendingPathComponent("out.wav")
        let route = try await AudioSourceExtractor.extract(from: mkv, to: out, hasFFmpeg: true, progress: nil)
        #expect(route == .ffmpeg)
        let floats = try WhisperCppEngine.loadPCM16AsFloat(out)
        #expect(abs(Double(floats.count) / 16_000 - 2.0) < 0.1)
    }

    @Test func supportedContainerStaysOnNativePath() async throws {
        // AudioExtractorTests' 44.1 kHz stereo WAV fixture
        let route = try await AudioSourceExtractor.extract(from: fixture, to: out, hasFFmpeg: true, progress: nil)
        #expect(route == .native)
    }

    @Test func missingFFmpegProducesAnActionableError() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("bogus-\(UUID().uuidString).mkv")
        try Data("not media".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        do {
            _ = try await AudioSourceExtractor.extract(from: bogus, to: bogus.appendingPathExtension("wav"), hasFFmpeg: false, progress: nil)
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription.contains("ffmpeg"))
        }
    }
}
```

- [ ] **Step 2: Implement `FFmpegAudioExtractor` + `AudioSourceExtractor`**

```swift
struct FFmpegUnavailableError: LocalizedError {
    let underlying: String
    var errorDescription: String? {
        "Cue could not read this file's audio (\(underlying)). Install ffmpeg (brew install ffmpeg) so Cue can read containers macOS cannot, such as MKV."
    }
}

enum ExtractionRoute: Equatable, Sendable { case native, ffmpeg }

enum AudioSourceExtractor {
    static func extract(from source: URL, to destination: URL, hasFFmpeg: Bool = ProcessEnvironment.hasFFmpeg,
                        progress: (@Sendable (Double) -> Void)?) async throws -> ExtractionRoute {
        do {
            try await AudioExtractor.extract(from: source, to: destination, onProgress: progress)
            return .native
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard hasFFmpeg else { throw FFmpegUnavailableError(underlying: error.localizedDescription) }
            try await FFmpegAudioExtractor.extract(from: source, to: destination)
            return .ffmpeg
        }
    }
}

enum FFmpegAudioExtractor {
    static func extract(from source: URL, to destination: URL, environment: [String: String] = ProcessEnvironment.withToolPaths()) async throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = environment
        process.arguments = ["ffmpeg", "-y", "-nostdin", "-i", source.path, "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", temp.path]
        let stderr = PipeCollector()
        process.standardError = stderr.pipe
        process.standardOutput = FileHandle.nullDevice
        let box = ProcessBox(); box.process = process
        return try await withTaskCancellationHandler {
            try process.run()
            if Task.isCancelled { box.terminate() }
            let status = await process.waitForTermination()
            await stderr.waitForEOF(); stderr.close()
            if Task.isCancelled { try? FileManager.default.removeItem(at: temp); throw CancellationError() }
            guard status == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw AudioExtractorError.readerFailed(stderr.text().split(separator: "\n").last.map(String.init) ?? "ffmpeg exited with status \(status)")
            }
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp) }
            else { try FileManager.default.moveItem(at: temp, to: destination) }
        } onCancel: { box.terminate() }
    }
}
```

`ProcessBox` moves out of `TranscriptionService.swift` into `Sources/Support/ProcessBox.swift` (internal) so both call sites share it.

- [ ] **Step 3: Use it in `transcribeNatively`** — replace the `try await AudioExtractor.extract(from:to:) { … }` call with `let route = try await AudioSourceExtractor.extract(from: videoURL, to: cachedWav, progress: …)` and log `Extracted audio with ffmpeg (macOS could not read this container).` through `progress(JobProgress(stage: .extractingAudio, detail: …, fraction: 0.12))` when `route == .ffmpeg`.

- [ ] **Step 4: Contiguity guard in `AudioExtractor.writeWAV`**

```swift
guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
let length = CMBlockBufferGetDataLength(blockBuffer)
guard length > 0 else { continue }
guard UInt64(pcmBytes) + UInt64(length) <= UInt64(UInt32.max) - 36 else { throw … }
var bytes = Data(count: length)
try bytes.withUnsafeMutableBytes { raw in
    let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
    guard status == kCMBlockBufferNoErr else { throw AudioExtractorError.readerFailed("could not copy sample data (\(status))") }
}
try handle.write(contentsOf: bytes)
pcmBytes += UInt32(length)
```

`CMBlockBufferCopyDataBytes` handles non-contiguous buffers; the output for contiguous buffers is byte-identical.

- [ ] **Step 5: Run tests; commit** `git commit -am "Fall back to ffmpeg when AVFoundation cannot read a container (MKV); copy non-contiguous sample buffers"`.

---

### Task 6: Persistent Python workers

**Files:**
- Modify: `Sources/Support/BackendScriptWriter.swift` (`--serve` mode, model cache, per-job runner) and regenerate `transcribe.py`
- Create: `Sources/Services/PythonWorkerPool.swift`
- Modify: `Sources/Services/TranscriptionService.swift:120-278` (Python path uses the pool)
- Modify: `Sources/Stores/AppModel.swift` `prepareForTermination` (pool shutdown)
- Create: `script/test_serve_mode.py`
- Create: `Tests/CueTests/PythonWorkerPoolTests.swift` and `Tests/CueTests/Fixtures/fake_worker.py` (bundled via `resources` in Package.swift test target)

**Interfaces:**
- Produces:
  ```swift
  struct PythonJobRequest: Codable, Sendable { let inputPath, language, qwenContext, model, backend: String; let preprocessAudio, vadFilter, streamSegments: Bool; let beamSize, bestOf, startingSegmentID: Int; let temperature, noSpeechThreshold, resumeThroughSeconds: Double; let audioWav: String? }
  struct PythonJobResult: Sendable { let backend: String; let segments: [TranscriptionSegment] }
  actor PythonWorkerPool {
      static let shared: PythonWorkerPool
      init(scriptURL: @escaping @Sendable () throws -> URL = BackendScriptWriter.ensureScript, pythonExecutable: [String] = ["/usr/bin/env", "python3"], idleTimeout: TimeInterval = 600, killGrace: TimeInterval = 3)
      func run(_ request: PythonJobRequest, onEvent: @escaping @Sendable (TranscriptionStreamEvent) -> Void) async throws -> PythonJobResult
      func shutdown() async
      func residentWorkerPID() -> Int32?   // tests
  }
  ```
  Wire protocol: request line `{"event":"job","id":"<uuid>", …PythonJobRequest fields in snake_case…}`; shutdown line `{"event":"shutdown"}`; result line on stdout `{"event":"result","id":…,"backend":…,"segments":[…]}` or `{"event":"error","id":…,"message":…}`; stderr keeps today's events.

- [ ] **Step 1: Python serve mode + model cache (in `BackendScript.source`)**

Refactor `main()` into `run_job(args, program_started) -> tuple[str, list]` (raises on failure; identical body to today's loop) and add:

```python
MODEL_CACHE: dict = {}


def cached_model(kind: str, key, factory):
    """Loaded backend objects survive across jobs in --serve mode. They are
    stateless across transcribe calls, so reuse cannot change output."""
    entry = MODEL_CACHE.get(kind)
    if entry is None or entry[0] != key:
        MODEL_CACHE.clear()  # one resident model: never hold two multi-GB models
        entry = (key, factory())
        MODEL_CACHE[kind] = entry
    return entry[1]
```

`load_with_faster_whisper`: `runner = cached_model("faster-whisper", resolved_model, lambda: WhisperModel(resolved_model, device="cpu", compute_type="int8"))`. `load_with_qwen3`: `session, aligner = cached_model("qwen3-asr", model, lambda: (session_type(model=model) if session_type else None, aligner_type() if aligner_type else None))`. mlx-whisper already caches via its `ModelHolder`.

```python
def serve() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("event") == "shutdown":
            return 0
        if message.get("event") != "job":
            continue
        job_id = message.get("id")
        try:
            args = job_arguments(message)
            used_backend, segments = run_job(args, time.perf_counter())
            payload = {"event": "result", "id": job_id, "backend": used_backend, "segments": segments}
        except SystemExit as exc:  # handle_termination
            raise
        except Exception as exc:
            payload = {"event": "error", "id": job_id, "message": str(exc)}
        print(json.dumps(payload, ensure_ascii=False), file=sys.stdout, flush=True)
    return 0
```

`job_arguments(message)` builds the same `argparse.Namespace` the CLI produces (`parser.parse_args([...])` from the message fields), so `run_job` cannot diverge between modes. `main()` handles `--serve` by calling `serve()`.

- [ ] **Step 2: `script/test_serve_mode.py`** — feeds two job lines for `faster-whisper` with a fake `faster_whisper` module (records `WhisperModel` constructions and `transcribe` calls, returns two fake segments), a third job with a bad backend name, then shutdown; asserts one construction, two results with fresh ids per job, one error line, exit code 0, and that stderr contains the `loadingModel`/`complete` events per job.

- [ ] **Step 3: `PythonWorkerPool`**

```swift
actor PythonWorkerPool {
    private struct Key: Hashable { let backend: String; let model: String; let scriptPath: String }
    private final class Worker {
        let key: Key; let process: Process; let stdin: FileHandle; let stdout: PipeCollector; let stderr: PipeCollector
        var busy = false; var idleSince: ContinuousClock.Instant?
        var resultContinuation: CheckedContinuation<PythonJobResult, Error>?
        var eventHandler: (@Sendable (TranscriptionStreamEvent) -> Void)?
        var currentJobID: String?
    }
    private var worker: Worker?
    …
    func run(_ request: PythonJobRequest, onEvent: …) async throws -> PythonJobResult {
        let key = Key(backend: request.backend, model: request.model, scriptPath: try scriptURL().path)
        let worker = try await workerFor(key)          // spawns, or terminates a different-key worker first
        precondition(!worker.busy)                       // one job at a time (GPU slot serialises callers)
        worker.busy = true; defer { worker.busy = false; worker.idleSince = .now; scheduleIdleSweep() }
        let jobID = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                worker.resultContinuation = continuation; worker.eventHandler = onEvent; worker.currentJobID = jobID
                do { try worker.stdin.write(contentsOf: Data((try encodeJob(request, id: jobID) + "\n").utf8)) }
                catch { continuation.resume(throwing: error); worker.resultContinuation = nil }
            }
        } onCancel: {
            Task { await self.cancelCurrentJob() }   // SIGTERM now, SIGKILL after killGrace, drop worker
        }
    }
}
```

stdout lines: decode `{"event":"result"|"error","id":…}`; ignore lines whose `id` does not match the current job (stray prints). stderr lines: `TranscriptionStreamEvent.decode` → `eventHandler`; non-JSON lines accumulate into `worker.errorText` (bounded to the last 64 KB) for failure messages. `terminationHandler`: if a job is in flight, resume its continuation with `TranscriptionServiceError.pythonFailed(errorText or "The Python helper exited with status N.")`; drop the worker. Idle sweep: after `idleTimeout` with no job, write `{"event":"shutdown"}\n`, wait `killGrace`, then terminate/kill. `shutdown()`: same for the resident worker, awaited.

- [ ] **Step 4: Fake worker for Swift tests (`Tests/CueTests/Fixtures/fake_worker.py`)**

Implements the protocol without any ML: for each job, emits a progress line and a `segments` event on stderr, then `result` with one segment whose text is `"job <n> pid <pid>"` where `n` counts jobs *within this process* (proves reuse) — plus commands encoded in `input_path`: `crash` → `os._exit(3)` mid-job; `hang` → ignores SIGTERM and sleeps; `slow` → sleeps 2 s before the result.

- [ ] **Step 5: Swift pool tests** — reuse (same PID, `job 1`, `job 2`), isolation (result ids differ; a job never receives the previous job's `segments` event: assert events received during job 2 only carry job 2's marker), crash → `pythonFailed` and the next job gets a new PID, cancellation of `hang` → `CancellationError` within ~4 s and the process is gone (`kill(pid, 0) != 0`), idle timeout 0.5 s → `residentWorkerPID()` nil after 1.5 s.

- [ ] **Step 6: Wire `TranscriptionService`** — replace the `Process` block with `PythonWorkerPool.shared.run(request) { event in DispatchQueue.main.async { MainActor.assumeIsolated { switch event … } } }` and keep `decodePayload`'s tolerance (result decoded from the line). The `withTaskCancellationHandler`/`ProcessBox` code is deleted from this path. `AppModel.prepareForTermination` awaits `PythonWorkerPool.shared.shutdown()` via a `Task` plus a bounded `DispatchSemaphore` wait (1 s) so quit is never blocked indefinitely.

- [ ] **Step 7: Run `python3 script/sync_backend_script.py`, then all tests; commit** `git commit -am "Keep the Python helper resident between jobs (--serve mode) with idle eviction and crash recovery"`.

---

### Task 7: Concurrent, deterministically ordered job loading

**Files:**
- Modify: `Sources/Stores/JobStore.swift:65-104`
- Create: `Sources/Models/JobLoadOrdering.swift`
- Modify: `Tests/CueTests/JobStoreTests.swift`, create `Tests/CueTests/JobLoadOrderingTests.swift`

**Interfaces:**
- Produces: `enum JobLoadOrdering { static func stableSortedByOrderIndex(_ jobs: [TranscriptionJob]) -> [TranscriptionJob]; static func storeOrder(_ a: TranscriptionJob, _ b: TranscriptionJob) -> Bool }`.

- [ ] **Step 1: Failing tests** — `JobLoadOrderingTests.equalOrderIndexIsOrderedByUpdatedAtThenID` (three jobs with equal `orderIndex`, distinct `updatedAt`/ids, shuffle 20 times → same output); `JobStoreTests.concurrentLoadReturnsEverySavedJobInDeterministicOrder` (save 300 jobs with 50 sharing an `updatedAt`, load twice → identical `map(\.id)`); existing quarantine test still passes.

- [ ] **Step 2: Implement** — in `loadJobs`, collect `files` (filtered as today), then:

```swift
let slots = UnsafeMutableBufferPointer<Result<TranscriptionJob, Error>?>.allocate(capacity: files.count)
slots.initialize(repeating: nil); defer { slots.deallocate() }
let injector = failureInjector
DispatchQueue.concurrentPerform(iterations: files.count) { index in
    let file = files[index]
    slots[index] = Result { try injector(.read, file); return try Self.makeDecoder().decode(TranscriptionJob.self, from: try Data(contentsOf: file)) }
}
for (index, file) in files.enumerated() {   // sequential: quarantine/report in directory order as before
    switch slots[index]! { case .success(let job): jobs.removeAll { $0.id == job.id }; jobs.append(job)
                           case .failure(let error): /* existing quarantine block */ }
}
return jobs.map(Self.sanitizedAfterRelaunch).sorted(by: JobLoadOrdering.storeOrder)
```

`storeOrder`: `updatedAt` descending, then `id.uuidString` ascending. `stableSortedByOrderIndex`: `orderIndex` ascending, then `updatedAt` descending, then `id`. `AppModel` uses it in Task 8.

- [ ] **Step 3: Run tests, commit** `git commit -am "Decode job files concurrently with a total, deterministic load order"`.

---

### Task 8: `AppModel` id→index cache and asynchronous hydration

**Files:**
- Modify: `Sources/Stores/AppModel.swift` (init, `currentJobIndex`, every `jobs.first(where:)`/`firstIndex(where:)` by id, `updateJob`, `persistJob`, watch-folder start, `processQueue` gating)
- Modify: `Sources/Stores/JobRepository.swift` (`loadJobs` stays sync; add `nonisolated static func load(from store)`? No: `JobPersisting.loadJobs()` stays; AppModel calls it inside `Task.detached` through a `nonisolated` store method `loadJobsOffMainActor()` added to `JobStore` that does the same work without actor isolation — the store only touches `fileManager`, `failureInjector`, and `startupError`; make `startupError` writes hop to the main actor)
- Modify: `Sources/Views/DetailView.swift:89-103` and `Sources/Views/SidebarView.swift:743-758` (neutral state while `isHydratingJobs`)
- Create: `Tests/CueTests/AppModelHydrationTests.swift`; update fixtures in `AppModelSelectionTests`, `AppModelSubtitleImportTests`, `JobCardSettingsTests`, `AppModelDiagnosticsTests` to `await model.hydration()` where they read persisted jobs.

**Interfaces:**
- Produces: `AppModel.isHydratingJobs: Bool` (`@Published private(set)`), `func hydration() async` (returns when the initial load has merged), `func index(of id: UUID) -> Int?`.

- [ ] **Step 1: Failing tests**

```swift
@Test func jobsAddedDuringHydrationStayOnTopAndAreNotDuplicated() async throws {
    // Persist 40 jobs into a temp store first (JobStore.saveJob + flush).
    let model = AppModel(settings: settings, jobStore: JobStore(baseURL: baseURL), diagnosticsService: EmptySelectionDiagnostics())
    #expect(model.isHydratingJobs)
    model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2)])   // before hydration lands
    let addedIDs = model.jobs.map(\.id)
    await model.hydration()
    #expect(!model.isHydratingJobs)
    #expect(model.jobs.count == 42)
    #expect(Array(model.jobs.prefix(2).map(\.id)) == addedIDs)
    #expect(model.jobs[0].orderIndex < model.jobs[2].orderIndex)
    #expect(Set(model.jobs.map(\.id)).count == 42)
}

@Test func hydratedOrderIsStableAcrossLaunches() async throws { /* two models on the same store → identical id order */ }

@Test func watchFoldersStartOnlyAfterHydration() async throws {
    // settings.watchFolders = [temp folder containing a media file whose fingerprint is already in the persisted jobs]
    // After hydration + a manual service.scan(), the file is NOT ingested again (job count unchanged).
}

@Test func indexLookupSurvivesReorder() throws {
    // add 5 jobs, capture index(of:) for each, moveJobToBottom(first), assert index(of:) matches firstIndex(where:) for all
}
```

- [ ] **Step 2: Implement**

```swift
@Published private(set) var isHydratingJobs = true
private var hydrationTask: Task<Void, Never>?
private var jobIndexCache: [UUID: Int] = [:]

func index(of id: UUID) -> Int? {
    if let cached = jobIndexCache[id], cached < jobs.count, jobs[cached].id == id { return cached }
    jobIndexCache = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($1.id, $0) })   // ids are unique
    return jobIndexCache[id]
}
func job(withID id: UUID) -> TranscriptionJob? { index(of: id).map { jobs[$0] } }
```

Init: `jobs = []`, `persistenceError = watchLedger.startupError`, then

```swift
hydrationTask = Task { [weak self] in
    guard let self else { return }
    let loaded = await jobRepository.loadJobsOffMainActor()   // JobRepository forwards to store.loadJobsOffMainActor()
    self.finishHydration(with: loaded)
}
```

`finishHydration`: `let pending = jobs` (interactive adds); `var merged = JobLoadOrdering.stableSortedByOrderIndex(loaded.filter { !pendingIDs.contains($0.id) })`; re-stamp `pending` with `QueueOrdering.indicesForBatchAdd(count: pending.count, existing: merged.map(\.orderIndex))` in their current order; `jobs = restamped + merged`; persist the restamped ones via the batch save; `persistenceError = persistenceError ?? jobRepository.startupError`; `autoArchiveOldJobs()`; if `selectedJobID == nil` select the first non-archived; `isHydratingJobs = false`; `syncWatchFolders()`; `processQueue()`. `syncWatchFolders()` and `processQueue()` early-return while `isHydratingJobs` (they are called again by `finishHydration`). `func hydration() async { await hydrationTask?.value }`.

Replace every `jobs.first(where: { $0.id == X })` with `job(withID: X)` and every `jobs.firstIndex(where: { $0.id == X })` with `index(of: X)` (37 sites; `currentJobIndex` becomes `selectedJobID.flatMap(index(of:))`).

- [ ] **Step 3: Views** — `DetailView.emptyWorkspace`: `if model.isHydratingJobs { ProgressView("Loading jobs…") } else if model.jobs.isEmpty { WelcomeWorkspaceView }`. `SidebarView.emptyPlaceholder`: same guard before "No Jobs Yet".

- [ ] **Step 4: Update existing fixtures** — in the four `makeFixture` helpers add `await model.hydration()` (the helpers become `async`), and make the tests `async`.

- [ ] **Step 5: Run all tests; commit** `git commit -am "Hydrate the job list off the main actor and cache id lookups"`.

---

### Task 9: UI hot paths

**Files:**
- Create: `Sources/Stores/SubtitleWarningCache.swift`
- Modify: `Sources/Stores/AppModel.swift` (`qualityWarnings` → cache; `updateJob` utf8 pre-filter)
- Modify: `Sources/Views/TranscriptView.swift` (grouped warnings input, `SegmentEditorRow: Equatable`)
- Modify: `Sources/Views/DetailView.swift:64-87, 306-328`
- Modify: `Sources/Views/LogView.swift:43-49`
- Modify: `Sources/Views/PlayerPane.swift:58-65` (identity short-circuit)
- Modify: `Sources/Services/TranscriptionService.swift:786-801` (`decode` routing)
- Create: `Tests/CueTests/SubtitleWarningCacheTests.swift`, `Tests/CueTests/LogTailTests.swift`

**Interfaces:**
- Produces: `struct SubtitleWarnings: Equatable { let list: [SubtitleQualityWarning]; let bySegment: [Int: [SubtitleQualityWarning]] }`; `final class SubtitleWarningCache { func warnings(for segments: [TranscriptionSegment], key: Key) -> SubtitleWarnings; static func compute(_ segment: TranscriptionSegment) -> [SubtitleQualityWarning] }` with `struct Key: Hashable { let jobID: UUID; let slot: SubtitleSidecarScanner.Slot }`; `AppModel.qualityWarnings(for:slot:) -> SubtitleWarnings`; `enum LogTail { static func lastLines(of log: String, count: Int) -> (lines: [String], truncated: Bool) }`.

- [ ] **Step 1: Failing tests** — cache: identical array instance → same result object (`===` on an internal box or `computeCount` unchanged); appended array → `computeCount` grows by the appended count only; edited element → recompute for that array (count grows by n, results correct); second key does not share entries. `LogTail`: matches `split`-based reference for logs of 0, 1, 399, 400, 401, 5000 lines with and without a trailing newline and with empty lines.

- [ ] **Step 2: Implement the cache**

```swift
final class SubtitleWarningCache {
    struct Key: Hashable { let jobID: UUID; let slot: SubtitleSidecarScanner.Slot }
    private struct Entry { var segments: [TranscriptionSegment]; var warnings: SubtitleWarnings }
    private var entries: [Key: Entry] = [:]
    private(set) var computeCount = 0

    func warnings(for segments: [TranscriptionSegment], key: Key) -> SubtitleWarnings {
        if let entry = entries[key] {
            if Self.sameBuffer(entry.segments, segments) { return entry.warnings }
            if segments.count > entry.segments.count, segments.prefix(entry.segments.count).elementsEqual(entry.segments) {
                var list = entry.warnings.list
                var bySegment = entry.warnings.bySegment
                for segment in segments[entry.segments.count...] { append(Self.compute(segment), to: &list, &bySegment) }
                let result = SubtitleWarnings(list: list, bySegment: bySegment)
                entries[key] = Entry(segments: segments, warnings: result)
                return result
            }
        }
        var list: [SubtitleQualityWarning] = []; var bySegment: [Int: [SubtitleQualityWarning]] = [:]
        for segment in segments { append(Self.compute(segment), to: &list, &bySegment) }
        let result = SubtitleWarnings(list: list, bySegment: bySegment)
        entries[key] = Entry(segments: segments, warnings: result)
        return result
    }

    private static func sameBuffer(_ a: [TranscriptionSegment], _ b: [TranscriptionSegment]) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }
    // compute(_:) contains the four rules from AppModel.qualityWarnings verbatim.
}
```

`computeCount` increments inside `compute` (test seam). `AppModel.qualityWarnings(for segments:)` stays as a thin wrapper for tests but the view calls `model.qualityWarnings(for: segments, slot: .transcript)` which uses `SubtitleWarningCache` keyed by `selectedJobID`.

- [ ] **Step 3: Views** — `TranscriptView(segments:warnings: SubtitleWarnings, …)` uses `warnings.bySegment` directly; `SegmentEditorRow: Equatable` (`==` on `segment`, `warnings`, `isActive`) and `.equatable()` in the `ForEach`. `DetailView`: `syncOverlaySegments()` starts with `guard model.isPlayerVisible else { return }`; replace the two array `onChange` modifiers with `.onChange(of: model.overlayRevision) { syncOverlaySegments() }` where `overlayRevision` is `currentJob.map { OverlayRevision(jobID: $0.id, updatedAt: $0.updatedAt, transcriptCount: …, translationCount: …) }` (`Equatable` struct; `updatedAt` changes on every mutation so edits and appends both refresh). `PlayerController.updateSegments` returns early when the new array shares its buffer with `segments`. `LogView.visibleLines` → `LogTail.lastLines(of: log, count: Self.maxVisibleLines)` which walks `log.utf8` backwards counting `\n` and slices once. `AppModel.updateJob`: `if jobs[index].log.utf8.count > Self.maxLogLength, jobs[index].log.count > Self.maxLogLength { … }`. `TranscriptionStreamEvent.decode`: `if line.hasPrefix("{\"stage\"") { try progress first } else { existing order }` — the fallback chain stays intact so a re-ordered JSON object still decodes.

- [ ] **Step 4: Run tests; commit** `git commit -am "Cache subtitle warnings, make transcript rows Equatable, gate overlay sync, tail the log lazily"`.

---

### Task 10: Recursive FSEvents watch with a stability follow-up scan

**Files:**
- Modify: `Sources/Services/WatchFolderService.swift:37-88, 115-168`
- Modify: `Sources/Services/WatchFolderScanEngine.swift` (add `var hasPendingCandidates: Bool`)
- Create: `Sources/Services/FolderEventStream.swift`
- Modify: `Tests/CueTests/WatchFolderTests.swift` (nested detection)

**Interfaces:**
- Produces: `final class FolderEventStream { init?(path: String, latency: TimeInterval, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void); func stop() }`; `WatchFolderService.followUpDelay: TimeInterval` (static, `WatchFolderScanEngine.stabilityInterval + 0.5`).

- [ ] **Step 1: Failing test**

```swift
@Test func nestedFileIsReportedWithoutWaitingForTheTimer() async throws {
    let root = temp folder; let nested = root/"season 2"/"disc 1" (create after start)
    let service = WatchFolderService()
    let ready = OSAllocatedUnfairLock(initialState: [URL]())
    service.onFilesReady = { urls in ready.withLock { $0 += urls } }
    service.start(path: root.path)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: nested.appendingPathComponent("ep1.mkv"))
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline, ready.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
    service.stop()
    #expect(ready.withLock { $0.map(\.lastPathComponent) } == ["ep1.mkv"])
}
```

(15 s < the 60 s timer, so passing proves the event path plus the follow-up scan.)

- [ ] **Step 2: Implement `FolderEventStream`** with `FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))`, `FSEventStreamSetDispatchQueue`, `FSEventStreamStart`; the C callback pulls the `onChange` closure from an `Unmanaged<Box>` passed as `info`; `stop()` does `FSEventStreamStop`, `FSEventStreamInvalidate`, `FSEventStreamRelease` and releases the box. `WatchFolderService.start` replaces the kqueue block with `eventStream = FolderEventStream(path:…, latency: 0.5, queue: eventQueue) { [weak self] in Task { @MainActor in self?.scan() } }` (nil → the same `lastError`). After `apply(...)`: `if engine.hasPendingCandidates { scheduleFollowUpScan() }` with a cancellable `Task.sleep(for:)` stored in `followUpTask`; `stop()` cancels it.

- [ ] **Step 3: Run tests; commit** `git commit -am "Watch folders recursively with FSEvents and re-scan once the stability gate can pass"`.

---

### Task 11: Batch ingestion and off-main ledger persistence

**Files:**
- Modify: `Sources/Stores/AppModel.swift:1258-1280` (`ingestWatchFolderFiles`)
- Modify: `Sources/Services/WatchFolderLedger.swift:51-95`
- Modify: `Sources/Stores/AppModel.swift` `flushPendingWork` (ledger flush)
- Create: `Tests/CueTests/WatchFolderIngestTests.swift`; extend `WatchFolderLedgerTests`

- [ ] **Step 1: Failing tests** — ingest 25 URLs through the internal `ingestWatchFolderFiles(_:folderID:)` (make it `internal` for the test) with a `RecordingStore` injected via `JobStore`? `AppModel` takes a `JobStore`, not the protocol; add an `init` overload accepting `jobRepository: JobRepository` (internal) so the test can inject `JobRepository(store: RecordingStore)` and assert `store.saved.count == 25` and `store.saveBatches == 1` (count `flush` boundaries: add `saveBatchCount` to the recording store by counting `saveJob` bursts between `flush` calls — simpler: assert that `orderIndex` values are consecutive integers from `max+1` and that the recording store saw exactly 25 saves total with no duplicates). Ledger: `record` returns before the file exists, `flush()` makes it exist; 200 `record` calls then `flush` → file decodes to 200 entries.

- [ ] **Step 2: Implement** — ingest: build `newJobs` with `var nextIndex = QueueOrdering.indexForWatchAdd(existing: jobs.map(\.orderIndex))` then `nextIndex += 1` per job; `jobs.append(contentsOf: newJobs)`; `jobRepository.save(newJobs)`. Ledger: `private let ioQueue = DispatchQueue(label: "Cue.WatchFolderLedger", qos: .utility)`; `persist()` snapshots `entries` and `ioQueue.async { encode + atomic write }`; `func flush() { ioQueue.sync {} }`; `AppModel.flushPendingWork` calls `watchLedger.flush()`.

- [ ] **Step 3: Run tests; commit** `git commit -am "Batch watch-folder ingestion into one save; persist the ledger off the main actor"`.

---

### Task 12: Benchmarks after, docs, changelog, lint

**Files:**
- Modify: `docs/superpowers/plans/2026-09-03-benchmarks.md` ("After" table)
- Modify: `CLAUDE.md` (architecture notes: model cache, worker pool, hydration, FSEvents), `README.md` (MKV now works on the built-in engine when ffmpeg is installed; Python helper stays resident), `CHANGELOG.md`
- Create: `script/bench_python_worker.py` (times two consecutive jobs through `--serve` vs two one-shot runs, using faster-whisper `tiny` if present)

- [ ] **Step 1:** `CUE_BENCH=1 script/run_tests.sh 2>&1 | grep '^BENCH'` → record "After".
- [ ] **Step 2:** `python3 script/bench_python_worker.py` → record.
- [ ] **Step 3:** `script/format_swift.sh && script/lint_swift.sh && script/run_tests.sh && swift build -c release -Xswiftc -warnings-as-errors`.
- [ ] **Step 4:** Commit `git commit -am "Document resident engines, hydration, and MKV fallback; record benchmarks"`.
