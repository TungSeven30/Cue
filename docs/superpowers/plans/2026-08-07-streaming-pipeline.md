# Streaming Pipeline (Watch-While-Transcribing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Segments appear in the UI as the engine produces them, translation runs behind the transcription frontier, and the queue pipelines (job B transcribes while job A finishes translating) — per `docs/superpowers/specs/2026-08-07-streaming-pipeline-design.md`.

**Architecture:** A unified `onSegments` batch callback flows from both streaming backends (whisper.cpp native callback; Qwen3 silence-aware chunk-driving over the existing stderr JSON protocol) through `TranscriptionService` into `AppModel`, which replaces its single `activeTask`/`activeJobID` with two independently serial slots (GPU, translation). A `ProgressiveTranslationDriver` accumulates streamed batches and re-invokes the existing `TranslationService.translate` incrementally — the service already skips fully-translated chunks and seeds from `existingTranslations`, so incremental calls do only new work.

**Tech Stack:** Swift 6 toolchain in language mode 5, SwiftPM, swift-testing (`import Testing`, `@Test`, `#expect`), whisper.cpp pinned at v1.7.2, Python helper script for Qwen3.

## Global Constraints

- **Tests run ONLY via `./script/run_tests.sh`** — never bare `swift test` (CLT-only machine silently runs zero tests). `--filter` is silently ignored on this machine; the whole suite always runs.
- **Build check:** `swift build 2>&1 | tail -20` compiles without running the app.
- **whisper.cpp stays pinned at v1.7.2** (revision pin in `Package.swift`). `new_segment_callback` exists in that version; do not bump the dependency.
- **No new SwiftPM dependencies.**
- **`AppModel` is `@MainActor`**; callbacks from background threads/queues hop via `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` (existing pattern — emission order preserved, unlike unstructured Tasks).
- **Tolerant decoding:** every new `TranscriptionJob` field decodes via `decodeIfPresent` with a default, so existing job files load unchanged.
- **`BackendScriptWriter.swift` and repo-root `transcribe.py` must stay in sync** — every helper-script change lands in both.
- **Serial GPU invariant:** at most one transcription runs at a time. At most one translation runs at a time. The two may overlap.
- **Secrets never persist onto jobs** — `TranslationCredentials` is built fresh per run (existing rule; the driver must follow it too).
- Commits end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Job model — partial transcript, timing fields, duration formatting

**Files:**
- Modify: `Sources/Models/TranscriptionJob.swift` (fields + `init` + `init(from:)` + `CodingKeys`)
- Create: `Sources/Models/JobTiming.swift`
- Test: `Tests/WhisperDeskTests/JobTimingTests.swift`

**Interfaces:**
- Consumes: existing `TranscriptionJob` custom `init(from:)` pattern (see `partialTranslatedSegments` at line ~66 for the exact tolerant-decode idiom).
- Produces (later tasks rely on these exact names):
  - `TranscriptionJob.partialTranscriptSegments: [TranscriptionSegment]` (default `[]`)
  - `TranscriptionJob.transcriptionStartedAt: Date?`, `transcriptionFinishedAt: Date?`, `translationStartedAt: Date?`, `finishedAt: Date?` (all default `nil`)
  - `JobTimingFormatter.format(_ seconds: TimeInterval) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperDesk

@Suite struct JobTimingTests {
    @Test func formatsSecondsMinutesHours() {
        #expect(JobTimingFormatter.format(45) == "45s")
        #expect(JobTimingFormatter.format(432) == "7m 12s")
        #expect(JobTimingFormatter.format(3840) == "1h 04m")
    }

    @Test func rejectsNonsenseDurations() {
        #expect(JobTimingFormatter.format(-5) == "")
        #expect(JobTimingFormatter.format(.infinity) == "")
    }

    @Test func decodesLegacyJobWithoutStreamingFields() throws {
        // A job encoded before this change must load with defaults.
        var job = TranscriptionJob(sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"), settings: JobSettingsSnapshot(settings: AppSettingsStore()))
        job.partialTranscriptSegments = [TranscriptionSegment(id: 1, start: 0, end: 1, text: "x")]
        job.transcriptionStartedAt = Date()
        let data = try JSONEncoder().encode(job)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "partialTranscriptSegments")
        json.removeValue(forKey: "transcriptionStartedAt")
        json.removeValue(forKey: "transcriptionFinishedAt")
        json.removeValue(forKey: "translationStartedAt")
        json.removeValue(forKey: "finishedAt")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(TranscriptionJob.self, from: stripped)
        #expect(decoded.partialTranscriptSegments.isEmpty)
        #expect(decoded.transcriptionStartedAt == nil)
        #expect(decoded.finishedAt == nil)
    }
}
```

Note: check `TranscriptionJob`'s actual designated initializer signature before writing the test — mirror whatever the existing tests (e.g. `JobStoreTests`) use to construct a job.

- [ ] **Step 2: Run the suite to verify the new tests fail**

Run: `./script/run_tests.sh 2>&1 | tail -20`
Expected: compile error (`JobTimingFormatter` and the new fields don't exist).

- [ ] **Step 3: Implement**

`Sources/Models/JobTiming.swift`:

```swift
import Foundation

/// Human-readable durations for the job status line and log
/// ("45s", "7m 12s", "1h 04m").
enum JobTimingFormatter {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }
}
```

In `TranscriptionJob.swift`, next to `partialTranslatedSegments`, add stored properties, default them in the designated init, add `CodingKeys` cases, and decode tolerantly in `init(from:)`:

```swift
var partialTranscriptSegments: [TranscriptionSegment]
var transcriptionStartedAt: Date?
var transcriptionFinishedAt: Date?
var translationStartedAt: Date?
var finishedAt: Date?
```

```swift
partialTranscriptSegments = try container.decodeIfPresent([TranscriptionSegment].self, forKey: .partialTranscriptSegments) ?? []
transcriptionStartedAt = try container.decodeIfPresent(Date.self, forKey: .transcriptionStartedAt)
transcriptionFinishedAt = try container.decodeIfPresent(Date.self, forKey: .transcriptionFinishedAt)
translationStartedAt = try container.decodeIfPresent(Date.self, forKey: .translationStartedAt)
finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./script/run_tests.sh 2>&1 | tail -20`
Expected: all tests pass, including the three new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/TranscriptionJob.swift Sources/Models/JobTiming.swift Tests/WhisperDeskTests/JobTimingTests.swift
git commit -m "Add partial-transcript and timing fields to TranscriptionJob"
```

---

### Task 2: Window-local cleanup subset

**Files:**
- Modify: `Sources/Services/TranscriptionService.swift` (the `TranscriptionPostProcessor` enum in the same file)
- Test: `Tests/WhisperDeskTests/StreamCleanupTests.swift`

**Interfaces:**
- Consumes: `TranscriptionPostProcessor`'s existing private helpers `normalizeWhitespace`, `collapseRepeatedText`, and the internal `repairInvalidTimings(_:minimumDuration:gapToNext:)` — all in the same file, so `private` access works.
- Produces: `TranscriptionPostProcessor.cleanWindow(_ segments: [TranscriptionSegment], settings: TranscriptionSettingsSnapshot) -> [TranscriptionSegment]`

The subset is deliberately **window-local and deterministic**: per-segment text normalization, per-segment repeat collapsing, empty-segment drop, zero-duration repair. It must **never renumber** (segment ids are globally monotonic across windows and later batches must not disturb earlier ones) and never merge across segments.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WhisperDesk

@Suite struct StreamCleanupTests {
    private var settings: TranscriptionSettingsSnapshot {
        // Build the same way TranscriptionService does; copy the field list
        // from the snapshot construction in TranscriptionService.transcribe.
        TranscriptionSettingsSnapshot(
            sourceLanguage: "auto", whisperModel: "ggml-large-v3-turbo-q5_0.bin",
            whisperBackendRawValue: "whisper-cpp", preprocessAudio: false,
            vadFilter: false, removeEmptySegments: true, removeRepeatedText: true,
            mergeShortSegments: true, minSegmentDuration: 1.0, maxMergeGap: 0.4,
            beamSize: 5, bestOf: 5, temperature: 0, noSpeechThreshold: 0.6
        )
    }

    @Test func preservesIDsAndNeverRenumbers() {
        let batch = [
            TranscriptionSegment(id: 41, start: 100.0, end: 101.5, text: "  hello  "),
            TranscriptionSegment(id: 42, start: 101.5, end: 101.5, text: "world"),
        ]
        let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: settings)
        #expect(cleaned.map(\.id) == [41, 42])
        #expect(cleaned[0].text == "hello")
        #expect(cleaned[1].end > cleaned[1].start)  // zero-duration repaired
    }

    @Test func dropsEmptySegments() {
        let batch = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "   "),
            TranscriptionSegment(id: 2, start: 1, end: 2, text: "keep"),
        ]
        let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: settings)
        #expect(cleaned.map(\.id) == [2])
    }

    @Test func isIdempotent() {
        let batch = [
            TranscriptionSegment(id: 1, start: 0, end: 0.05, text: " a a a a a a "),
            TranscriptionSegment(id: 2, start: 3, end: 3, text: "b"),
        ]
        let once = TranscriptionPostProcessor.cleanWindow(batch, settings: settings)
        let twice = TranscriptionPostProcessor.cleanWindow(once, settings: settings)
        #expect(once == twice)
    }

    @Test func laterBatchesDoNotAlterEarlierOutput() {
        let a = [TranscriptionSegment(id: 1, start: 0, end: 2, text: "first")]
        let b = [TranscriptionSegment(id: 2, start: 2, end: 4, text: "second")]
        let aCleaned = TranscriptionPostProcessor.cleanWindow(a, settings: settings)
        _ = TranscriptionPostProcessor.cleanWindow(b, settings: settings)
        #expect(TranscriptionPostProcessor.cleanWindow(a, settings: settings) == aCleaned)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./script/run_tests.sh 2>&1 | tail -20`; expected: compile error (`cleanWindow` undefined).

- [ ] **Step 3: Implement**, next to `clean` in `TranscriptionPostProcessor`:

```swift
/// Window-local subset of `clean` for streamed batches: deterministic,
/// idempotent, per-segment only. No renumbering (ids are globally
/// monotonic across windows), no merges, no cross-window dedupe — the
/// full `clean` pass at completion remains authoritative.
static func cleanWindow(_ segments: [TranscriptionSegment], settings: TranscriptionSettingsSnapshot) -> [TranscriptionSegment] {
    var cleaned = segments.map { segment in
        TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: normalizeWhitespace(segment.text))
    }
    if settings.removeRepeatedText {
        cleaned = cleaned.map { segment in
            TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: collapseRepeatedText(segment.text))
        }
    }
    if settings.removeEmptySegments {
        cleaned = cleaned.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    return repairInvalidTimings(cleaned)
}
```

- [ ] **Step 4: Run to verify pass** — `./script/run_tests.sh 2>&1 | tail -20`; all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/TranscriptionService.swift Tests/WhisperDeskTests/StreamCleanupTests.swift
git commit -m "Add window-local cleanup subset for streamed segment batches"
```

---

### Task 3: WhisperCppEngine segment streaming

**Files:**
- Modify: `Sources/Services/WhisperCppEngine.swift`
- Test: `Tests/WhisperDeskTests/WhisperStreamingIntegrationTests.swift` (gated — runs only when the default model is already installed)

**Interfaces:**
- Consumes: existing `CallbackBox` pattern (progress + abort callbacks marshalled through `Unmanaged` user data), `whisper_full_n_segments`, `whisper_full_get_segment_t0/t1/text` (already used for final result extraction — mirror that code exactly).
- Produces: `WhisperCppEngine.transcribe(...)` gains parameter `onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void = { _ in }` (after `onProgress`). Callback fires on whisper worker threads — same threading contract as `onProgress`.

whisper.cpp v1.7.2's `whisper_new_segment_callback` signature is `(ctx, state, n_new, user_data)`. The delta is the last `n_new` segments of `whisper_full_n_segments(ctx)` — no stored state needed.

- [ ] **Step 1: Extend CallbackBox and the engine signature**

```swift
private final class CallbackBox {
    let onProgress: @Sendable (Double) -> Void
    let onSegments: @Sendable ([TranscriptionSegment]) -> Void
    let isCancelled: @Sendable () -> Bool

    init(onProgress: @escaping @Sendable (Double) -> Void,
         onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.onProgress = onProgress
        self.onSegments = onSegments
        self.isCancelled = isCancelled
    }
}
```

Add to `transcribe` after the `onProgress` parameter:

```swift
onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void = { _ in },
```

and pass it into the `CallbackBox` initializer.

- [ ] **Step 2: Wire the callback** (next to the existing `progress_callback` wiring):

```swift
params.new_segment_callback = { ctx, _, nNew, userData in
    guard let ctx, let userData, nNew > 0 else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
    let total = Int(whisper_full_n_segments(ctx))
    let first = max(0, total - Int(nNew))
    var batch: [TranscriptionSegment] = []
    for index in first..<total {
        let text = String(cString: whisper_full_get_segment_text(ctx, Int32(index)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        batch.append(TranscriptionSegment(
            id: index + 1,
            start: Double(whisper_full_get_segment_t0(ctx, Int32(index))) / 100.0,
            end: Double(whisper_full_get_segment_t1(ctx, Int32(index))) / 100.0,
            text: text
        ))
    }
    if !batch.isEmpty { box.onSegments(batch) }
}
params.new_segment_callback_user_data = userData
```

Match the exact optionality of `whisper_full_get_segment_text`'s return in this pinned revision — copy whatever the existing final-result extraction in this file does (if it force-unwraps or nil-checks, do the same).

- [ ] **Step 3: Write the gated integration test**

The test synthesizes speech with `/usr/bin/say`, converts via `AudioExtractor`, and runs the engine — but only when the default model is already installed (never download in tests). Find the installed-model path helper by grepping `ModelDownloader` for its models directory; use the same path logic.

```swift
import Foundation
import Testing
@testable import WhisperDesk

@Suite struct WhisperStreamingIntegrationTests {
    @Test func streamedSegmentsMatchFinalResult() async throws {
        // Locate the installed default model the way ModelDownloader does;
        // silently pass when it is not installed (CI-less local gate).
        let modelURL = ModelDownloader.installURL(for: ModelDownloader.defaultModel)  // use the real helper name found by grep
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appendingPathComponent("fixture.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "This is a streaming test. The quick brown fox jumps over the lazy dog. Segments should arrive incrementally."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let wav = dir.appendingPathComponent("fixture.wav")
        try await AudioExtractor.extract(from: aiff, to: wav)

        let streamedBatches = OSAllocatedUnfairLock(initialState: [[TranscriptionSegment]]())
        let result = try await WhisperCppEngine().transcribe(
            wavURL: wav, modelURL: modelURL, language: "en",
            beamSize: 3, noSpeechThreshold: 0.6,
            onProgress: { _ in },
            onSegments: { batch in streamedBatches.withLock { $0.append(batch) } },
            isCancelled: { false }
        )
        let streamed = streamedBatches.withLock { $0 }.flatMap { $0 }
        #expect(!streamed.isEmpty)
        #expect(streamed.map(\.id) == result.segments.map(\.id))
        #expect(streamed.map(\.text) == result.segments.map(\.text))
    }
}
```

Add `import os` for `OSAllocatedUnfairLock` if needed. Note: `WhisperCppEngine.Result`'s segments are extracted the same way as the callback's, so equality should hold exactly; if the engine's final extraction trims differently, mirror it.

- [ ] **Step 4: Run the suite** — `./script/run_tests.sh 2>&1 | tail -20`. Expected: all green (the integration test either exercises streaming or passes vacuously without the model).

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/WhisperCppEngine.swift Tests/WhisperDeskTests/WhisperStreamingIntegrationTests.swift
git commit -m "Stream new-segment batches from the whisper.cpp engine"
```

---

### Task 4: TranscriptionService — onSegments plumb-through and stream-event decoding

**Files:**
- Modify: `Sources/Services/TranscriptionService.swift`
- Test: `Tests/WhisperDeskTests/StreamEventDecodingTests.swift`

**Interfaces:**
- Consumes: Task 2's `cleanWindow`, Task 3's engine parameter.
- Produces:
  - `TranscriptionService.transcribe(videoURL:settings:progress:onSegments:)` — new final parameter `onSegments: (@MainActor ([TranscriptionSegment]) -> Void)? = nil`. Batches are **already window-cleaned** when delivered; delivered on the main actor in emission order.
  - `TranscriptionStreamEvent` (internal enum, replaces the `private` `TranscriptionProgressEvent` as the stderr line decoder):

```swift
enum TranscriptionStreamEvent: Equatable {
    case progress(JobProgress)
    case segments([TranscriptionSegment])
    static func decode(_ line: String) -> TranscriptionStreamEvent?
}
```

- [ ] **Step 1: Write the failing decoding tests**

```swift
import Testing
@testable import WhisperDesk

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
```

- [ ] **Step 2: Run to verify failure** — compile error, `TranscriptionStreamEvent` undefined.

- [ ] **Step 3: Implement the decoder** (replacing the `private struct TranscriptionProgressEvent` declaration site; keep that struct nested/private inside the new enum):

```swift
enum TranscriptionStreamEvent: Equatable {
    case progress(JobProgress)
    case segments([TranscriptionSegment])

    private struct SegmentsEnvelope: Decodable {
        let event: String
        let segments: [TranscriptionSegment]
    }

    private struct ProgressEnvelope: Decodable {
        let stage: JobStage
        let detail: String
        let fraction: Double?
    }

    static func decode(_ line: String) -> TranscriptionStreamEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
        if let envelope = try? JSONDecoder().decode(SegmentsEnvelope.self, from: data), envelope.event == "segments" {
            return .segments(envelope.segments)
        }
        if let envelope = try? JSONDecoder().decode(ProgressEnvelope.self, from: data) {
            return .progress(JobProgress(stage: envelope.stage, detail: envelope.detail, fraction: envelope.fraction))
        }
        return nil
    }
}
```

(Progress lines lack an `event` key and segments lines lack `stage`, so each decode attempt fails cleanly on the other shape. Trying segments first keeps a future progress-shaped superset from shadowing it.)

- [ ] **Step 4: Plumb `onSegments` through both paths**

Add the parameter to `transcribe` and `transcribeNatively`:

```swift
onSegments: (@MainActor ([TranscriptionSegment]) -> Void)? = nil
```

Native path — pass to the engine (the snapshot is captured `let`, safe in the `@Sendable` closure):

```swift
onSegments: { batch in
    let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: snapshot)
    guard !cleaned.isEmpty else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { onSegments?(cleaned) }
    }
},
```

Python path — replace the stderr handler body:

```swift
let stderr = PipeCollector { line in
    guard let event = TranscriptionStreamEvent.decode(line) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            switch event {
            case .progress(let update):
                progress(update)
            case .segments(let batch):
                let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: snapshot)
                if !cleaned.isEmpty { onSegments?(cleaned) }
            }
        }
    }
}
```

- [ ] **Step 5: Run the suite** — `./script/run_tests.sh 2>&1 | tail -20`; all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/Services/TranscriptionService.swift Tests/WhisperDeskTests/StreamEventDecodingTests.swift
git commit -m "Plumb streamed segment batches through TranscriptionService"
```

---

### Task 5: Qwen3 chunk driving in the helper script

**Files:**
- Modify: `Sources/Support/BackendScriptWriter.swift` (embedded script) and `transcribe.py` (identical changes — Global Constraint)
- Create: `script/test_chunk_planning.py` (standalone test harness)

**Interfaces:**
- Consumes: the script's existing `emit(stage, detail, fraction)` helper, `load_with_qwen3`, `group_timed_tokens`, `call_with_supported_kwargs`.
- Produces:
  - Python `plan_speech_chunks(samples, sample_rate, min_silence=0.5, target_chunk=150.0, max_chunk=300.0) -> list[tuple[float, float]]` — pure, testable.
  - New CLI flag `--stream-segments` (default off, so CLI users of `transcribe.py` keep exact current behavior); Swift passes `--stream-segments true` (add to the argument array in `TranscriptionService.transcribe`).
  - stderr event: `{"event": "segments", "segments": [{"id": …, "start": …, "end": …, "text": …}, …]}` — one line per chunk, ids globally increasing across chunks.

- [ ] **Step 1: Write the chunk-planning function** (add near `group_timed_tokens` in both script copies):

```python
def plan_speech_chunks(samples, sample_rate, min_silence=0.5, target_chunk=150.0, max_chunk=300.0):
    """Cut points for chunked ASR, placed only inside detected silences.

    samples: array('h') of 16-bit mono PCM. Returns [(start_s, end_s), ...]
    covering the whole file. A file with no usable silences returns a single
    chunk — never a mid-speech cut.
    """
    import math
    total_seconds = len(samples) / float(sample_rate)
    if total_seconds <= max_chunk:
        return [(0.0, total_seconds)]
    frame = max(1, int(sample_rate * 0.05))  # 50 ms frames
    rms = []
    for i in range(0, len(samples) - frame + 1, frame):
        window = samples[i:i + frame]
        rms.append(math.sqrt(sum(s * s for s in window) / len(window)))
    if not rms:
        return [(0.0, total_seconds)]
    threshold = max(1.0, 0.1 * sorted(rms)[int(len(rms) * 0.95)])
    frame_seconds = frame / float(sample_rate)
    # Candidate cut points: centers of silent runs >= min_silence.
    candidates = []
    run_start = None
    for index, value in enumerate(rms):
        if value < threshold:
            if run_start is None:
                run_start = index
        else:
            if run_start is not None:
                run_len = (index - run_start) * frame_seconds
                if run_len >= min_silence:
                    candidates.append((run_start + (index - run_start) / 2.0) * frame_seconds)
                run_start = None
    if run_start is not None and (len(rms) - run_start) * frame_seconds >= min_silence:
        candidates.append((run_start + (len(rms) - run_start) / 2.0) * frame_seconds)
    if not candidates:
        return [(0.0, total_seconds)]
    chunks = []
    start = 0.0
    for _ in range(10000):  # bounded; each iteration advances start
        remaining = total_seconds - start
        if remaining <= max_chunk:
            chunks.append((start, total_seconds))
            break
        in_window = [c for c in candidates if start + min_silence < c <= start + max_chunk]
        if in_window:
            cut = min(in_window, key=lambda c: abs(c - (start + target_chunk)))
        else:
            later = [c for c in candidates if c > start + max_chunk]
            if not later:
                chunks.append((start, total_seconds))
                break
            cut = later[0]  # first silence after the cap beats a mid-speech cut
        chunks.append((start, cut))
        start = cut
    return chunks
```

- [ ] **Step 2: Write the test harness** `script/test_chunk_planning.py`:

```python
#!/usr/bin/env python3
"""Verifies plan_speech_chunks against synthetic audio with known silences.
Run: python3 script/test_chunk_planning.py  (exit 0 = pass)."""
import array
import math
import re
import sys
from pathlib import Path

# Import the function from the repo-root script copy.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from transcribe import plan_speech_chunks  # noqa: E402

RATE = 16000

def tone(seconds, amplitude=8000):
    return [int(amplitude * math.sin(2 * math.pi * 220 * t / RATE)) for t in range(int(seconds * RATE))]

def silence(seconds):
    return [0] * int(seconds * RATE)

def build(*parts):
    samples = array.array("h")
    for part in parts:
        samples.extend(part)
    return samples

failures = []

def check(name, condition):
    if not condition:
        failures.append(name)

# 1. Short file -> single chunk.
short = build(tone(30))
check("short file is one chunk", plan_speech_chunks(short, RATE) == [(0.0, 30.0)])

# 2. Long file with silences every ~100s: cuts land inside silences.
pattern = []
for _ in range(8):
    pattern.append(tone(100))
    pattern.append(silence(2))
long_audio = build(*pattern)
chunks = plan_speech_chunks(long_audio, RATE, target_chunk=150.0, max_chunk=300.0)
check("multiple chunks", len(chunks) >= 2)
check("chunks tile the file",
      abs(chunks[0][0]) < 1e-6 and abs(chunks[-1][1] - len(long_audio) / RATE) < 1e-6
      and all(abs(chunks[i][1] - chunks[i + 1][0]) < 1e-6 for i in range(len(chunks) - 1)))
silence_spans = []
cursor = 0.0
for _ in range(8):
    cursor += 100.0
    silence_spans.append((cursor, cursor + 2.0))
    cursor += 2.0
for _, end in chunks[:-1]:
    check(f"cut {end:.1f}s lands in a silence",
          any(s <= end <= e for s, e in silence_spans))

# 3. No silences at all -> single chunk despite length.
no_silence = build(tone(400))
check("no-silence file is one chunk", len(plan_speech_chunks(no_silence, RATE)) == 1)

if failures:
    print("FAILED:", "; ".join(failures))
    sys.exit(1)
print("chunk planning OK")
```

- [ ] **Step 3: Run the harness against `transcribe.py`**

Run: `python3 script/test_chunk_planning.py`
Expected first run: `ImportError` (function not yet in `transcribe.py`); after adding it to both copies: `chunk planning OK`.

- [ ] **Step 4: Rework `load_with_qwen3` for chunked streaming**

Add parameters `stream_segments: bool` and thread the flag from `main()`'s argparse (`parser.add_argument("--stream-segments", default="false")`, parsed like the existing boolean flags). New flow when `stream_segments` and the audio is long enough to chunk:

```python
def load_with_qwen3(audio_path: Path, model: str, language: str, stream_segments: bool = False):
    from mlx_qwen3_asr import transcribe as qwen3_transcribe
    import array as _array
    import wave

    emit("loadingModel", f"Loading {model} with Qwen3 ASR. First run may download the model.", 0.18)

    chunks = [(0.0, None)]
    samples = None
    sample_rate = 16000
    if stream_segments:
        try:
            with wave.open(str(audio_path), "rb") as handle:
                sample_rate = handle.getframerate()
                raw = handle.readframes(handle.getnframes())
            samples = _array.array("h")
            samples.frombytes(raw)
            planned = plan_speech_chunks(samples, sample_rate)
            if len(planned) > 1:
                chunks = planned
        except Exception:
            chunks = [(0.0, None)]  # unreadable as plain WAV: fall back to one call

    all_tokens = []
    all_segments = []
    next_id = 1
    for chunk_index, (chunk_start, chunk_end) in enumerate(chunks):
        if chunk_end is None or len(chunks) == 1:
            chunk_path = audio_path
        else:
            chunk_path = audio_path.with_name(f"{audio_path.stem}.chunk{chunk_index}.wav")
            first = int(chunk_start * sample_rate)
            last = int(chunk_end * sample_rate)
            with wave.open(str(chunk_path), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(sample_rate)
                out.writeframes(samples[first:last].tobytes())
        fraction = 0.2 + 0.7 * (chunk_index / max(1, len(chunks)))
        emit("transcribing", f"Transcribing chunk {chunk_index + 1} of {len(chunks)}.", fraction)
        result = call_with_supported_kwargs(
            qwen3_transcribe,
            str(chunk_path),
            model=model,
            language=None if language == "auto" else language,
            return_timestamps=True,
        )
        if chunk_path != audio_path:
            chunk_path.unlink(missing_ok=True)
        raw_segments = getattr(result, "segments", None) or []
        tokens = []
        for segment in raw_segments:
            if isinstance(segment, dict):
                start, end, text = segment.get("start", 0.0), segment.get("end", 0.0), segment.get("text", "")
            else:
                start = getattr(segment, "start", 0.0)
                end = getattr(segment, "end", 0.0)
                text = getattr(segment, "text", "")
            tokens.append({
                "start": float(start or 0.0) + chunk_start,
                "end": float(end or 0.0) + chunk_start,
                "text": str(text).strip(),
            })
        all_tokens.extend(tokens)
        batch = []
        for group in group_timed_tokens(tokens):
            batch.append({"id": next_id, "start": group["start"], "end": group["end"], "text": group["text"].strip()})
            next_id += 1
        all_segments.extend(batch)
        if stream_segments and batch:
            print(json.dumps({"event": "segments", "segments": batch}), file=sys.stderr, flush=True)

    emit("transcribing", "Normalizing transcript segments.", 0.92)
    segments = all_segments
    if not segments:
        # The loop always ran at least once, so `result` is bound.
        if str(getattr(result, "text", "") or "").strip():
            raise RuntimeError(
                "Qwen3 ASR produced text but no timestamps. Install the aligner extra: pip install 'mlx-qwen3-asr[aligner]'"
            )
        raise RuntimeError("Qwen3 ASR returned no transcript.")
    return "qwen3-asr", segments
```

Important details: token grouping runs **per chunk** (so cue boundaries never span a chunk cut, which is inside a silence anyway); ids increase globally; the final stdout payload uses the accumulated `segments` exactly as today. Note the model may reload per chunk if `mlx_qwen3_asr.transcribe` does not cache internally — acceptable in v1; leave a comment saying so. Apply the identical change in `BackendScriptWriter.swift`'s embedded string.

- [ ] **Step 5: Pass the flag from Swift**

In `TranscriptionService.transcribe`'s Python argument array, add:

```swift
"--stream-segments",
"true",
```

- [ ] **Step 6: Verify both script copies compile and stay in sync**

```bash
python3 -m py_compile transcribe.py && echo transcribe.py OK
python3 script/test_chunk_planning.py
swift build 2>&1 | tail -5
```

Also extract-and-compile the embedded copy: write a throwaway snippet or run the app-side path via `swift build`; at minimum re-read the `BackendScriptWriter.swift` diff side-by-side against the `transcribe.py` diff and confirm the hunks match.

- [ ] **Step 7: Run the suite** — `./script/run_tests.sh 2>&1 | tail -20`; all green.

- [ ] **Step 8: Commit**

```bash
git add Sources/Support/BackendScriptWriter.swift Sources/Services/TranscriptionService.swift transcribe.py script/test_chunk_planning.py
git commit -m "Chunk-drive Qwen3 ASR and stream segment batches over stderr"
```

---

### Task 6: TranslationReconciliation pure logic

**Files:**
- Create: `Sources/Services/TranslationReconciliation.swift`
- Test: `Tests/WhisperDeskTests/TranslationReconciliationTests.swift`

**Interfaces:**
- Produces: `TranslationReconciliation.remap(partials:streamed:final:) -> [TranscriptionSegment]` — maps partial translations (keyed by streamed-segment ids) onto the final cleaned transcript by exact `(start, end, text)` match; unmatched finals are simply absent from the result (they will be translated by the tail call). Result segments carry **final** ids.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WhisperDesk

@Suite struct TranslationReconciliationTests {
    @Test func remapsExactMatchesOntoFinalIDs() {
        let streamed = [
            TranscriptionSegment(id: 5, start: 0.0, end: 2.0, text: "hola"),
            TranscriptionSegment(id: 6, start: 2.0, end: 4.0, text: "mundo"),
        ]
        let partials = [TranscriptionSegment(id: 5, start: 0.0, end: 2.0, text: "hello")]
        // Final pass renumbered ids but kept the first segment intact.
        let final = [
            TranscriptionSegment(id: 1, start: 0.0, end: 2.0, text: "hola"),
            TranscriptionSegment(id: 2, start: 2.0, end: 4.0, text: "mundo"),
        ]
        let remapped = TranslationReconciliation.remap(partials: partials, streamed: streamed, final: final)
        #expect(remapped == [TranscriptionSegment(id: 1, start: 0.0, end: 2.0, text: "hello")])
    }

    @Test func dropsPartialsWhoseSegmentsWereMerged() {
        let streamed = [
            TranscriptionSegment(id: 1, start: 0.0, end: 1.0, text: "a"),
            TranscriptionSegment(id: 2, start: 1.0, end: 2.0, text: "b"),
        ]
        let partials = [
            TranscriptionSegment(id: 1, start: 0.0, end: 1.0, text: "A"),
            TranscriptionSegment(id: 2, start: 1.0, end: 2.0, text: "B"),
        ]
        // Final pass merged the two into one segment: no exact match survives.
        let final = [TranscriptionSegment(id: 1, start: 0.0, end: 2.0, text: "a b")]
        let remapped = TranslationReconciliation.remap(partials: partials, streamed: streamed, final: final)
        #expect(remapped.isEmpty)
    }

    @Test func emptyInputsProduceEmptyOutput() {
        #expect(TranslationReconciliation.remap(partials: [], streamed: [], final: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Maps partial translations made from streamed (pre-cleanup) segments onto
/// the final cleaned transcript. The final pass can renumber and merge, so
/// matching is by exact (start, end, text); anything that does not match is
/// dropped and re-translated by the completion tail call.
enum TranslationReconciliation {
    private struct Key: Hashable {
        let start: Double
        let end: Double
        let text: String
    }

    static func remap(
        partials: [TranscriptionSegment],
        streamed: [TranscriptionSegment],
        final: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        guard !partials.isEmpty else { return [] }
        let partialTextByID = Dictionary(partials.map { ($0.id, $0.text) }, uniquingKeysWith: { _, last in last })
        var translatedByKey: [Key: String] = [:]
        for segment in streamed {
            guard let text = partialTextByID[segment.id] else { continue }
            translatedByKey[Key(start: segment.start, end: segment.end, text: segment.text)] = text
        }
        return final.compactMap { segment in
            guard let text = translatedByKey[Key(start: segment.start, end: segment.end, text: segment.text)] else {
                return nil
            }
            return TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: text)
        }
    }
}
```

- [ ] **Step 4: Run the suite** — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/TranslationReconciliation.swift Tests/WhisperDeskTests/TranslationReconciliationTests.swift
git commit -m "Add pure reconciliation of partial translations onto final transcripts"
```

---

### Task 7: ProgressiveTranslationDriver

**Files:**
- Create: `Sources/Services/ProgressiveTranslationDriver.swift`
- Test: `Tests/WhisperDeskTests/ProgressiveTranslationDriverTests.swift`

**Interfaces:**
- Consumes: Task 6's `TranslationReconciliation.remap`.
- Produces:

```swift
@MainActor
final class ProgressiveTranslationDriver {
    /// (source segments, existing translations, onPartial) -> fully mapped result.
    /// AppModel wires this to TranslationService.translate; tests inject fakes.
    typealias TranslateCall = (
        _ segments: [TranscriptionSegment],
        _ existing: [TranscriptionSegment],
        _ onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void
    ) async throws -> [TranscriptionSegment]

    init(chunkSize: Int, overlapAllowed: Bool,
         translate: @escaping TranslateCall,
         onPartial: @escaping ([TranscriptionSegment]) -> Void,
         onNeedsTranslation: @escaping () -> Void)

    func ingest(_ batch: [TranscriptionSegment])
    func translateAvailable() async          // runs INSIDE the translation slot
    func finish(finalTranscript: [TranscriptionSegment]) async throws -> [TranscriptionSegment]
}
```

**Key property that keeps this simple:** the driver never manages its own concurrency. `translateAvailable()` and `finish()` only ever execute inside AppModel's serial translation slot, so there is never an in-flight call to coordinate with. `ingest` only accumulates and signals `onNeedsTranslation` (at most one outstanding signal); AppModel responds by enqueuing one slot work item.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WhisperDesk

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
        #expect(requests == 0)                       // below threshold
        driver.ingest([segment(3)])
        #expect(requests == 1)                       // crossed
        driver.ingest([segment(4)])
        #expect(requests == 1)                       // no second signal while one is outstanding
        await driver.translateAvailable()
        #expect(calls.count == 1)
        #expect(calls[0].count == 4)                 // snapshot includes everything streamed so far
        driver.ingest([segment(5), segment(6), segment(7)])
        #expect(requests == 2)                       // new material past the last request re-signals
    }

    @Test func localProviderNeverRequestsMidStream() async throws {
        var requests = 0
        var calls = 0
        let driver = ProgressiveTranslationDriver(
            chunkSize: 1, overlapAllowed: false,
            translate: { segments, _, _ in calls += 1; return segments },
            onPartial: { _ in },
            onNeedsTranslation: { requests += 1 }
        )
        driver.ingest([segment(1), segment(2), segment(3)])
        #expect(requests == 0)
        _ = try await driver.finish(finalTranscript: [segment(1), segment(2), segment(3)])
        #expect(calls == 1)                          // exactly the one completion call
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
        await driver.translateAvailable()            // fails silently mid-stream
        driver.ingest([segment(2)])
        #expect(requests == 1)                       // failed: no further mid-stream requests
        shouldFail = false
        let result = try? await driver.finish(finalTranscript: [segment(1), segment(2)])
        #expect(result?.count == 2)                  // finish still runs and can succeed
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
            onNeedsTranslation: { }
        )
        driver.ingest([segment(1)])
        await driver.translateAvailable()
        // Final pass renumbers: same (start, end, text), new id.
        let final = [TranscriptionSegment(id: 100, start: 1, end: 2, text: "s1")]
        _ = try await driver.finish(finalTranscript: final)
        #expect(receivedExisting == [TranscriptionSegment(id: 100, start: 1, end: 2, text: "T1")])
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Accumulates streamed transcript batches and drives incremental
/// translation behind the frontier. Owns no concurrency: `ingest` only
/// buffers and signals; `translateAvailable`/`finish` run inside AppModel's
/// serial translation slot, so calls never overlap.
@MainActor
final class ProgressiveTranslationDriver {
    typealias TranslateCall = (
        _ segments: [TranscriptionSegment],
        _ existing: [TranscriptionSegment],
        _ onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void
    ) async throws -> [TranscriptionSegment]

    private let chunkSize: Int
    private let overlapAllowed: Bool
    private let translate: TranslateCall
    private let onPartial: ([TranscriptionSegment]) -> Void
    private let onNeedsTranslation: () -> Void

    private(set) var streamed: [TranscriptionSegment] = []
    private(set) var partials: [TranscriptionSegment] = []
    private var requestedThrough = 0
    private var failedMidStream = false

    init(chunkSize: Int, overlapAllowed: Bool,
         translate: @escaping TranslateCall,
         onPartial: @escaping ([TranscriptionSegment]) -> Void,
         onNeedsTranslation: @escaping () -> Void) {
        self.chunkSize = max(1, chunkSize)
        self.overlapAllowed = overlapAllowed
        self.translate = translate
        self.onPartial = onPartial
        self.onNeedsTranslation = onNeedsTranslation
    }

    func ingest(_ batch: [TranscriptionSegment]) {
        streamed += batch
        maybeRequest()
    }

    /// One incremental pass over everything streamed so far. TranslationService
    /// skips chunks already covered by `partials`, so repeated calls only do
    /// new work. Mid-stream errors are swallowed (transcription must continue);
    /// `finish` surfaces any real failure.
    func translateAvailable() async {
        guard !failedMidStream else { return }
        let snapshot = streamed
        do {
            _ = try await translate(snapshot, partials) { [weak self] batch in
                self?.recordPartials(batch)
            }
        } catch is CancellationError {
            // Slot canceled: the job's cancel path handles state.
        } catch {
            failedMidStream = true
        }
        maybeRequest()
    }

    /// Reconcile partials onto the final transcript, then translate the tail.
    func finish(finalTranscript: [TranscriptionSegment]) async throws -> [TranscriptionSegment] {
        let reconciled = TranslationReconciliation.remap(partials: partials, streamed: streamed, final: finalTranscript)
        return try await translate(finalTranscript, reconciled) { [weak self] batch in
            self?.recordPartials(batch)
        }
    }

    private func maybeRequest() {
        guard overlapAllowed, !failedMidStream, streamed.count - requestedThrough >= chunkSize else { return }
        requestedThrough = streamed.count
        onNeedsTranslation()
    }

    private func recordPartials(_ batch: [TranscriptionSegment]) {
        partials = batch
        onPartial(batch)
    }
}
```

- [ ] **Step 4: Run the suite** — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/ProgressiveTranslationDriver.swift Tests/WhisperDeskTests/ProgressiveTranslationDriverTests.swift
git commit -m "Add progressive translation driver for streamed transcripts"
```

---

### Task 8: PipelineScheduler pure math

**Files:**
- Create: `Sources/Models/PipelineScheduler.swift`
- Test: `Tests/WhisperDeskTests/PipelineSchedulerTests.swift`

**Interfaces:**
- Produces:

```swift
enum PipelineScheduler {
    struct JobView: Equatable {
        let id: UUID
        let orderIndex: Double
        let status: JobStatus
        let hasTranscript: Bool
    }
    /// Next queued job needing transcription (min orderIndex), or nil.
    static func nextGPUJob(jobs: [JobView], gpuBusy: Bool, queuePaused: Bool) -> UUID?
    /// Next queued job that already has a transcript (min orderIndex), or nil.
    static func nextTranslationJob(jobs: [JobView], translationBusy: Bool, queuePaused: Bool) -> UUID?
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperDesk

@Suite struct PipelineSchedulerTests {
    private func job(_ order: Double, status: JobStatus = .queued, hasTranscript: Bool = false) -> PipelineScheduler.JobView {
        PipelineScheduler.JobView(id: UUID(), orderIndex: order, status: status, hasTranscript: hasTranscript)
    }

    @Test func gpuPicksLowestOrderQueuedWithoutTranscript() {
        let a = job(2), b = job(1), c = job(0, hasTranscript: true)
        #expect(PipelineScheduler.nextGPUJob(jobs: [a, b, c], gpuBusy: false, queuePaused: false) == b.id)
    }

    @Test func gpuRespectsBusyAndPause() {
        let a = job(1)
        #expect(PipelineScheduler.nextGPUJob(jobs: [a], gpuBusy: true, queuePaused: false) == nil)
        #expect(PipelineScheduler.nextGPUJob(jobs: [a], gpuBusy: false, queuePaused: true) == nil)
    }

    @Test func translationPicksQueuedWithTranscript() {
        let a = job(1, hasTranscript: true), b = job(0)
        #expect(PipelineScheduler.nextTranslationJob(jobs: [a, b], translationBusy: false, queuePaused: false) == a.id)
        #expect(PipelineScheduler.nextTranslationJob(jobs: [a, b], translationBusy: true, queuePaused: false) == nil)
    }

    @Test func slotsPipelineIndependently() {
        // A translating-adjacent world: one queued job per slot; both fire.
        let forGPU = job(1), forTranslation = job(0, hasTranscript: true)
        let jobs = [forGPU, forTranslation]
        #expect(PipelineScheduler.nextGPUJob(jobs: jobs, gpuBusy: false, queuePaused: false) == forGPU.id)
        #expect(PipelineScheduler.nextTranslationJob(jobs: jobs, translationBusy: false, queuePaused: false) == forTranslation.id)
    }

    @Test func nonQueuedJobsAreInvisible() {
        let running = job(0, status: .transcribing)
        let done = job(1, status: .translationComplete, hasTranscript: true)
        #expect(PipelineScheduler.nextGPUJob(jobs: [running, done], gpuBusy: false, queuePaused: false) == nil)
        #expect(PipelineScheduler.nextTranslationJob(jobs: [running, done], translationBusy: false, queuePaused: false) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure slot-assignment decisions for the two-slot pipeline. AppModel owns
/// the slots; this owns only the "who runs next" math so it stays testable.
enum PipelineScheduler {
    struct JobView: Equatable {
        let id: UUID
        let orderIndex: Double
        let status: JobStatus
        let hasTranscript: Bool
    }

    static func nextGPUJob(jobs: [JobView], gpuBusy: Bool, queuePaused: Bool) -> UUID? {
        guard !gpuBusy, !queuePaused else { return nil }
        return jobs
            .filter { $0.status == .queued && !$0.hasTranscript }
            .min { $0.orderIndex < $1.orderIndex }?
            .id
    }

    static func nextTranslationJob(jobs: [JobView], translationBusy: Bool, queuePaused: Bool) -> UUID? {
        guard !translationBusy, !queuePaused else { return nil }
        return jobs
            .filter { $0.status == .queued && $0.hasTranscript }
            .min { $0.orderIndex < $1.orderIndex }?
            .id
    }
}
```

- [ ] **Step 4: Run the suite** — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/PipelineScheduler.swift Tests/WhisperDeskTests/PipelineSchedulerTests.swift
git commit -m "Add pure two-slot pipeline scheduling decisions"
```

---

### Task 9: AppModel adopts two slots (behavior-preserving pipelining + timing)

**Files:**
- Modify: `Sources/Stores/AppModel.swift`

**Interfaces:**
- Consumes: Tasks 1 and 8.
- Produces (Task 10 builds on these exact names):
  - `private var gpuTask: Task<Void, Never>?`, `private(set) var gpuJobID: UUID?`
  - `private var translationTask: Task<Void, Never>?`, `private(set) var translationJobID: UUID?`
  - `private var translationWorkQueue: [(jobID: UUID, work: @MainActor () async -> Void)] = []`
  - `private func enqueueTranslationWork(jobID: UUID, _ work: @escaping @MainActor () async -> Void)`
  - `processQueue()` now pumps both slots.

This task is a **refactor with one behavior change** (pipelining): all existing tests must stay green, and the app must behave identically for single jobs. No streaming yet.

- [ ] **Step 1: Replace the slot fields**

Delete `activeTask`/`activeJobID`; add the four slot fields and the work queue above. Add a compatibility computed property so call-site churn stays reviewable:

```swift
/// Any pipeline work in flight (either slot).
var isProcessing: Bool {
    gpuJobID != nil || translationJobID != nil
}
```

Then fix every former `activeJobID`/`activeTask` reference by role, not by find-replace:
- `startTranscription` guard `if activeJobID != nil { enqueueJob(...) }` → `if gpuJobID != nil`
- `startTranslation` guard → `if translationJobID != nil { enqueueJob(...) }`
- `cancelActiveJob` → cancel **both** slots (see Step 4)
- the deletion/selection guard `guard id != activeJobID` (line ~361) → `guard id != gpuJobID, id != translationJobID`
- diagnostics guard (line ~59) and `updateProcessingActivity()` → busy when either slot is non-nil
- inside the transcription task: `activeTask = nil; activeJobID = nil` → `gpuTask = nil; gpuJobID = nil`, and `startTranscriptionNow`'s `activeJobID = jobID` / `activeTask = Task { … }` assignments → the GPU fields
- inside the translation task: `startTranslationNow`'s `activeJobID = jobID` / `activeTask = Task { … }` assignments → `translationJobID = jobID` / `translationTask = Task { … }`, and its cleanup → `translationTask = nil; translationJobID = nil`

- [ ] **Step 2: Split `processQueue` into two pumps**

```swift
/// Pumps both slots. GPU: next queued job without a transcript.
/// Translation: FIFO work items first (streaming drivers, Task 10), then
/// queued jobs that already have transcripts.
private func processQueue() {
    defer { updateProcessingActivity() }
    pumpTranslation()
    pumpGPU()
    if gpuJobID == nil, translationJobID == nil, translationWorkQueue.isEmpty, didProcessQueuedJob,
       PipelineScheduler.nextGPUJob(jobs: jobViews, gpuBusy: false, queuePaused: queuePaused) == nil,
       PipelineScheduler.nextTranslationJob(jobs: jobViews, translationBusy: false, queuePaused: queuePaused) == nil {
        didProcessQueuedJob = false
        notify(title: "WhisperDesk", body: "All queued jobs finished.")
    }
}

private var jobViews: [PipelineScheduler.JobView] {
    jobs.map { PipelineScheduler.JobView(id: $0.id, orderIndex: $0.orderIndex, status: $0.status, hasTranscript: !$0.transcriptSegments.isEmpty) }
}

private func pumpGPU() {
    guard let id = PipelineScheduler.nextGPUJob(jobs: jobViews, gpuBusy: gpuJobID != nil, queuePaused: queuePaused),
          let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    didProcessQueuedJob = true
    startTranscriptionNow(at: index, force: false)
    // Same stall guard as the old processQueue: a job that could not start
    // must not wedge the queue on a stuck "queued" entry.
    if gpuJobID == nil, jobs.first(where: { $0.id == id })?.status == .queued {
        markFailed(id, message: "Could not start this job. Check the file and settings.")
        processQueue()
    }
}

private func pumpTranslation() {
    guard translationTask == nil else { return }
    if !translationWorkQueue.isEmpty {
        let item = translationWorkQueue.removeFirst()
        translationJobID = item.jobID
        translationTask = Task {
            await item.work()
            translationTask = nil
            translationJobID = nil
            processQueue()
        }
        return
    }
    guard let id = PipelineScheduler.nextTranslationJob(jobs: jobViews, translationBusy: false, queuePaused: queuePaused),
          let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    didProcessQueuedJob = true
    startTranslationNow(at: index)
    if translationJobID == nil, jobs.first(where: { $0.id == id })?.status == .queued {
        markFailed(id, message: "Could not start this job. Check the file and settings.")
        processQueue()
    }
}

private func enqueueTranslationWork(jobID: UUID, _ work: @escaping @MainActor () async -> Void) {
    translationWorkQueue.append((jobID: jobID, work: work))
}
```

- [ ] **Step 3: Rewire the transcription→translation handoff**

In `startTranscriptionNow`'s task, the `willTranslate` branch currently does `activeTask = nil; activeJobID = nil; startTranslation(jobID: jobID); return`. Replace with: clear the GPU slot, then `startTranslation(jobID: jobID)` (which now checks the **translation** slot and either starts immediately or queues the job), then `processQueue()` so the freed GPU picks the next queued job — this is the pipelining moment. Keep the skip-check path's `startTranslation(jobID:)` call as is (it now routes to the translation slot too).

- [ ] **Step 4: Cancel cancels both phases**

```swift
func cancelActiveJob() {
    if queuedJobCount > 0 { queuePaused = true }
    gpuTask?.cancel()
    translationTask?.cancel()
    translationWorkQueue.removeAll()
    for id in [gpuJobID, translationJobID].compactMap({ $0 }) {
        updateJob(id) { job in
            job.status = .canceled
            job.progress = JobProgress(stage: .canceled, detail: "Canceling current operation.", fraction: nil)
            job.log += "Cancel requested.\n"
        }
    }
}
```

- [ ] **Step 5: Stamp timing and log durations**

- `startTranscriptionNow` (fresh-run branch, where it already resets `translatedSegments`): `jobs[index].transcriptionStartedAt = Date()`, and nil out `transcriptionFinishedAt`, `translationStartedAt`, `finishedAt`. On the skip-check path stamp `transcriptionStartedAt = Date()` and `transcriptionFinishedAt = Date()` (the run's clock starts now; transcription cost nothing).
- After `transcriptionService.transcribe` returns: `updateJob(jobID) { $0.transcriptionFinishedAt = Date() }`.
- `startTranslationNow`: `jobs[index].translationStartedAt = jobs[index].translationStartedAt ?? Date()`.
- `finishTranscription` **when no translation follows** — extend the no-translate completion in the transcription task: stamp `finishedAt = Date()` and append the duration to the completion detail. Implement a helper and call it from both completion paths:

```swift
/// Stamps finishedAt, rewrites the completion detail with the total
/// duration, and logs the phase breakdown (with overlap when phases ran
/// concurrently).
private func recordCompletionTiming(for id: UUID) {
    updateJob(id) { job in
        job.finishedAt = Date()
        guard let started = job.transcriptionStartedAt, let finished = job.finishedAt else { return }
        let total = JobTimingFormatter.format(finished.timeIntervalSince(started))
        guard !total.isEmpty else { return }
        job.progress = JobProgress(stage: .complete, detail: job.progress.detail + " Done in \(total).", fraction: 1)
        if let tStart = job.transcriptionStartedAt, let tEnd = job.transcriptionFinishedAt {
            job.log += "Transcription took \(JobTimingFormatter.format(tEnd.timeIntervalSince(tStart))).\n"
        }
        if let xStart = job.translationStartedAt, let finishedAt = job.finishedAt {
            job.log += "Translation took \(JobTimingFormatter.format(finishedAt.timeIntervalSince(xStart))).\n"
            if let tEnd = job.transcriptionFinishedAt, xStart < tEnd {
                job.log += "Translation overlapped transcription by \(JobTimingFormatter.format(tEnd.timeIntervalSince(xStart))).\n"
            }
        }
        job.log += "Job finished in \(total).\n"
    }
}
```

Call `recordCompletionTiming(for: jobID)` right after `finishTranscription(...)` in the no-translate branch, and right after `finishTranslation(...)` in the translation task.

- [ ] **Step 6: Build, run the suite, and smoke-check**

```bash
swift build 2>&1 | tail -5
./script/run_tests.sh 2>&1 | tail -20
```

Expected: all existing tests green. Then `./script/build_and_run.sh` and verify by hand: single job transcribes + translates exactly as before; queue two jobs with auto-translate on and confirm job B starts transcribing while job A is still translating (the pipelining moment); Stop cancels both.

Testing note (conscious deviation from spec §8): the spec sketches scheduler state-machine tests with fake transcription/translation services. `AppModel` holds concrete service structs with no protocol seams, and adding them would be a large unrelated refactor. Instead the slot-decision logic is pure and fully tested (Task 8), the driver is fully tested with injected fakes (Task 7), and slot wiring is verified by the existing suite plus the manual pipelining check above. If a reviewer disagrees, the seam to add is a closure-injection point for the two service calls — not a protocol hierarchy.

- [ ] **Step 7: Commit**

```bash
git add Sources/Stores/AppModel.swift
git commit -m "Split the run loop into GPU and translation slots with queue pipelining"
```

---

### Task 10: AppModel streaming wiring (partial transcript + driver sessions)

**Files:**
- Modify: `Sources/Stores/AppModel.swift`

**Interfaces:**
- Consumes: Tasks 4, 7, 9. `AppSettingsStore.currentTranslationProvider` (existing), `resolved.translationChunkMode.chunkSize` (existing).
- Produces: streaming behavior per spec §§4–6; `private var drivers: [UUID: ProgressiveTranslationDriver] = [:]`, `private var streamingTranslationFraction: [UUID: Double] = [:]`.

- [ ] **Step 1: Create the driver and stream segments in `startTranscriptionNow`**

In the fresh-run branch, clear stale partials and build the driver before starting the task:

```swift
jobs[index].partialTranscriptSegments = []
```

```swift
let willTranslate = autoTranslate && settings.isTranslationReady
var driver: ProgressiveTranslationDriver?
if willTranslate {
    let overlapAllowed = settings.currentTranslationProvider != .local
    let credentials = makeTranslationCredentials()  // fresh per run; never persisted
    driver = ProgressiveTranslationDriver(
        chunkSize: resolved.translationChunkMode.chunkSize,
        overlapAllowed: overlapAllowed,
        translate: { [weak self] segments, existing, onPartial in
            guard let self else { throw CancellationError() }
            return try await self.translationService.translate(
                segments: segments,
                sourceLanguage: resolved.sourceLanguage,
                settings: resolved,
                credentials: credentials,
                existingTranslations: existing,
                progress: { [weak self] update in
                    self?.recordStreamingTranslationProgress(update, for: jobID)
                },
                onPartial: onPartial
            )
        },
        onPartial: { [weak self] batch in
            self?.updatePartialTranslation(batch, for: jobID)
        },
        onNeedsTranslation: { [weak self] in
            guard let self, let driver = self.drivers[jobID] else { return }
            self.updateJob(jobID, debouncePersist: true) { job in
                job.translationStartedAt = job.translationStartedAt ?? Date()
            }
            self.enqueueTranslationWork(jobID: jobID) {
                await driver.translateAvailable()
            }
            self.processQueue()
        }
    )
    drivers[jobID] = driver
}
```

Pass the stream into the service call inside the task:

```swift
let result = try await transcriptionService.transcribe(videoURL: videoURL, settings: resolved, progress: { [weak self] progress in
    self?.updateProgress(progress, for: jobID)
}, onSegments: { [weak self] batch in
    guard let self else { return }
    self.updateJob(jobID, debouncePersist: true) { job in
        job.partialTranscriptSegments += batch
    }
    self.drivers[jobID]?.ingest(batch)
})
```

- [ ] **Step 2: Route the completion through the driver**

Replace the `willTranslate` handoff from Task 9 (`startTranslation(jobID:)`) with a driver-finish work item:

```swift
if willTranslate, let driver = drivers[jobID] {
    gpuTask = nil
    gpuJobID = nil
    updateJob(jobID) { job in
        job.status = .translating
        job.translationStartedAt = job.translationStartedAt ?? Date()
        job.progress = JobProgress(stage: .translating, detail: "Finishing translation.", fraction: nil)
    }
    enqueueTranslationWork(jobID: jobID) { [weak self] in
        guard let self else { return }
        do {
            let final = self.jobs.first(where: { $0.id == jobID })?.transcriptSegments ?? []
            let translated = try await driver.finish(finalTranscript: final)
            let target = resolved.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = await self.makeIntroSummary(
                from: translated,
                language: target.isEmpty ? "English" : target,
                for: jobID
            )
            self.finishTranslation(translated, summary: summary, for: jobID)
            self.recordCompletionTiming(for: jobID)
        } catch is CancellationError {
            self.markCanceled(jobID)
        } catch {
            self.markFailed(jobID, message: "Translation failed: \(error.localizedDescription)")
        }
        self.drivers[jobID] = nil
        self.streamingTranslationFraction[jobID] = nil
        self.notifyJobFinished(jobID)
    }
    processQueue()
    return
}
```

Ordering note: `finishTranscription(result, …)` must run **before** this block (it stamps `transcriptSegments` and clears `partialTranscriptSegments`), so the work item reads the final cleaned transcript. Non-streaming backends hit exactly this same path — their driver simply never ingested, so `finish` is one whole-transcript translate call, identical to today's behavior.

The skip-check path (existing transcript reused) keeps its `startTranslation(jobID:)` route: it has no streamed segments, so a driver adds nothing there.

- [ ] **Step 3: Clear partials and driver state on every terminal path**

- `finishTranscription`: add `job.partialTranscriptSegments = []`.
- Transcription `catch` paths (`markCanceled` / `markFailed`): after marking, run `drivers[jobID] = nil`, `streamingTranslationFraction[jobID] = nil`, and remove that job's queued work: `translationWorkQueue.removeAll { $0.jobID == jobID }`. Partials stay on the job (spec §6 — retained).
- `cancelActiveJob` (Task 9 version): also `drivers.removeAll()` and `streamingTranslationFraction.removeAll()` after cancelling the tasks (single-cancel path: cancel is app-wide stop, both slots die).

- [ ] **Step 4: Two-line progress while overlapping**

```swift
/// Translation progress arriving while the job is still transcribing must
/// not overwrite the transcription progress bar; remember the fraction and
/// let the transcription updates compose the two-line detail.
private func recordStreamingTranslationProgress(_ update: JobProgress, for id: UUID) {
    guard let fraction = update.fraction else { return }
    streamingTranslationFraction[id] = fraction
    if jobs.first(where: { $0.id == id })?.status == .translating {
        updateProgress(update, for: id)  // post-transcription: normal path
    }
}
```

And in `updateProgress`, compose when both phases are live:

```swift
private func updateProgress(_ progress: JobProgress, for id: UUID) {
    var composed = progress
    if progress.stage == .transcribing,
       let translated = streamingTranslationFraction[id],
       let fraction = progress.fraction {
        composed = JobProgress(
            stage: .transcribing,
            detail: "Transcribing \(Int(fraction * 100))% · Translated \(Int(translated * 100))%",
            fraction: fraction
        )
    }
    updateJob(id, debouncePersist: true) { job in
        job.progress = composed
        job.log += "\(composed.stage.label): \(composed.detail)\n"
    }
}
```

- [ ] **Step 5: Build, run the suite, and smoke-check streaming**

```bash
swift build 2>&1 | tail -5
./script/run_tests.sh 2>&1 | tail -20
```

Then `./script/build_and_run.sh` with a real video (built-in backend, cloud translation configured): transcript pane fills within ~30 s; translation partial count climbs while transcription still runs; the progress line shows both percentages; completed job's log has the phase breakdown and "Done in …". Repeat once with the Qwen3 backend.

- [ ] **Step 6: Commit**

```bash
git add Sources/Stores/AppModel.swift
git commit -m "Wire streamed segments and progressive translation into the pipeline"
```

---

### Task 11: UI — live partials in the tabs and player

**Files:**
- Modify: `Sources/Stores/AppModel.swift` (two computed properties)
- Modify: `Sources/Views/DetailView.swift`

**Interfaces:**
- Consumes: Task 1's `partialTranscriptSegments`, existing `partialTranslatedSegments`.
- Produces: `AppModel.displayTranscriptSegments`, `AppModel.displayTranslatedSegments`.

- [ ] **Step 1: Add display accessors** next to the existing `transcriptSegments` computed property:

```swift
/// What the transcript tab and player should render: the final transcript
/// when it exists, else the live streamed partials. Gating logic
/// (canTranslate, skip checks, export) must keep using the real fields.
var displayTranscriptSegments: [TranscriptionSegment] {
    guard let job = currentJob else { return [] }
    return job.transcriptSegments.isEmpty ? job.partialTranscriptSegments : job.transcriptSegments
}

var displayTranslatedSegments: [TranscriptionSegment] {
    guard let job = currentJob else { return [] }
    return job.translatedSegments.isEmpty ? job.partialTranslatedSegments : job.translatedSegments
}
```

- [ ] **Step 2: Point rendering (and only rendering) at the display vars**

In `DetailView.swift`:
- `syncOverlaySegments()` becomes:

```swift
private func syncOverlaySegments() {
    // The overlay and highlight follow whichever text the user is looking
    // at: translation on the translation tab, else the original — live
    // partials included while a job streams.
    let segments = tab == .translation && !model.displayTranslatedSegments.isEmpty
        ? model.displayTranslatedSegments
        : model.displayTranscriptSegments
    playerController.updateSegments(segments)
}
```

- The `.onChange(of: model.transcriptSegments)` / `.onChange(of: model.translatedSegments)` watchers become `.onChange(of: model.displayTranscriptSegments)` / `.onChange(of: model.displayTranslatedSegments)` so streamed batches re-sync the overlay.
- Find the transcript-tab and translation-tab list content (grep `transcriptSegments` and `translatedSegments` in `DetailView.swift`) and switch **list rendering only** to the display vars. Do NOT touch: `nextActionRow` (button gating), export functions, `canTranslate`-style guards — those must keep reading the real fields, so a half-streamed job can't be exported or double-started.

- [ ] **Step 3: Build and smoke-check**

```bash
swift build 2>&1 | tail -5
./script/run_tests.sh 2>&1 | tail -20
```

Then `./script/build_and_run.sh`: during a streaming run, the transcript tab fills live; switching to the translation tab shows partial translations as rows and as player subtitles; beyond the translated frontier the overlay shows nothing; after completion everything looks exactly as before.

- [ ] **Step 4: Commit**

```bash
git add Sources/Stores/AppModel.swift Sources/Views/DetailView.swift
git commit -m "Render live partial transcripts and translations in the tabs and player"
```

---

### Task 12: Docs, spec status, final verification

**Files:**
- Modify: `CLAUDE.md`, `docs/superpowers/specs/2026-08-07-streaming-pipeline-design.md`

- [ ] **Step 1: Update CLAUDE.md's architecture section**

In the "Serial job queue" paragraph, document the new shape (keep it tight, matching the file's voice): two independently serial slots (GPU transcription, translation) that may overlap and pipeline the queue; streamed batches land in `partialTranscriptSegments` (cleared at completion — a partial transcript must never satisfy the has-transcript checks); `ProgressiveTranslationDriver` + `TranslationReconciliation` drive incremental translation; the helper-script stderr protocol now carries `segments` events, and `transcribe.py` must stay in sync.

- [ ] **Step 2: Flip the spec header** to `**Status:** Implemented`.

- [ ] **Step 3: Full verification**

```bash
./script/run_tests.sh 2>&1 | tail -20
python3 script/test_chunk_planning.py
swift build 2>&1 | tail -5
```

All green, no warnings introduced.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-08-07-streaming-pipeline-design.md
git commit -m "Document the streaming pipeline architecture"
```

---

## Manual smoke tests (deferred to the user, per house convention)

- Drop a long real video (built-in backend + cloud translation): press play within the first minute; watch subtitles stay ahead of the playhead.
- Same with the Qwen3 backend (first subtitles after model load + one chunk).
- Two-job queue overnight-style: B transcribes while A translates; both complete; watch outcomes and sidecars appear once each.
- Cancel mid-stream: partial transcript and translations survive on the canceled job; Resume Translation works.
- Local-LLM provider: no translation requests until transcription completes.
