# Zero-Dependency Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WhisperDesk transcribes out of the box — no ffmpeg, no Python — by extracting audio natively with AVFoundation and running Whisper in-process via whisper.cpp, with the Python backends demoted to optional "advanced engines".

**Architecture:** Three phases, each shippable alone. Phase 1 replaces ffmpeg with an AVFoundation `AudioExtractor` that writes the same cached 16 kHz mono WAVs the Python helper expects (the helper just stops running its own ffmpeg step). Phase 2 adds a native transcription engine: whisper.cpp compiled in via SwiftPM (Metal-accelerated), plus a `ModelDownloader` that fetches GGML models with in-app progress. Phase 3 makes the native engine the default backend, reworks diagnostics/setup-guide so a fresh install reports zero missing dependencies, and updates docs.

**Tech Stack:** AVFoundation (`AVAssetReader`), whisper.cpp via SwiftPM (pinned release, Metal), `URLSession` download delegate, swift-testing (run via `script/run_tests.sh`).

**Constraints locked in during design:**
- The audio cache key scheme must match the Python helper's (`sha256(path|size|mtime_ns|preprocess=...)` → `~/Library/Caches/WhisperDesk/audio/<digest24>.wav`) so both paths share one cache.
- "Clean audio" preprocessing (`highpass/afftdn/loudnorm`) is ffmpeg-only. When ffmpeg is absent, extraction is plain; the toggle's help text says it needs ffmpeg. No attempt to reimplement DSP filters natively (YAGNI).
- Existing persisted jobs and settings must decode unchanged; `WhisperBackend` raw values are append-only.
- whisper.cpp exact symbol names must be verified against the **pinned** release during Task 6 — the C API below is from `whisper.h` and is stable, but the implementer must compile against the pin before trusting this document.

---

## Phase 1 — Native audio extraction (removes ffmpeg)

### Task 1: `AudioExtractor` core — decode any AV container to 16 kHz mono WAV

**Files:**
- Create: `Sources/Services/AudioExtractor.swift`
- Test: `Tests/WhisperDeskTests/AudioExtractorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import AVFoundation
import Foundation
import Testing
@testable import WhisperDesk

struct AudioExtractorTests {
    /// Writes a 2-second 440 Hz stereo 44.1 kHz WAV fixture with AVAudioFile.
    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / 44_100) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func extractsToSixteenKilohertzMonoWav() async throws {
        let source = try makeFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("extracted-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await AudioExtractor.extract(from: source, to: destination)

        let output = try AVAudioFile(forReading: destination)
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
        let seconds = Double(output.length) / output.fileFormat.sampleRate
        #expect(abs(seconds - 2.0) < 0.1)
    }

    @Test func throwsOnFileWithNoAudioTrack() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).txt")
        try Data("not audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).wav")

        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extract(from: source, to: destination)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./script/run_tests.sh 2>&1 | grep -E "AudioExtractor|error"`
Expected: compile error — `AudioExtractor` does not exist.

- [ ] **Step 3: Implement `AudioExtractor`**

```swift
import AVFoundation
import Foundation

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The file has no audio track."
        case .readerFailed(let message):
            return "Audio extraction failed: \(message)"
        }
    }
}

/// Decodes any AVFoundation-readable container to the 16 kHz mono 16-bit
/// PCM WAV the transcription engines expect. Replaces the ffmpeg step.
enum AudioExtractor {
    static func extract(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractorError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "could not start reading")
        }

        // Stream into a same-volume temp file and move it into place only
        // after the header patch succeeds, so an interrupted extraction never
        // leaves a partial WAV at the destination (downstream cache logic
        // treats file-existence as validity).
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(destinationURL.lastPathComponent + ".partial-\(UUID().uuidString)")
        do {
            try Self.writeWAV(from: output, reader: reader, to: tempURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Streams decoded PCM into `fileURL` behind a placeholder header, then
    /// patches the header with the final sizes — avoids buffering hours of audio.
    private static func writeWAV(from output: AVAssetReaderTrackOutput,
                                 reader: AVAssetReader, to fileURL: URL) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: Self.wavHeader(dataLength: 0))

        var pcmBytes: UInt32 = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer, length > 0 {
                guard UInt64(pcmBytes) + UInt64(length) <= UInt64(UInt32.max) - 36 else {
                    throw AudioExtractorError.readerFailed("audio exceeds the 4 GiB WAV limit")
                }
                try handle.write(contentsOf: Data(bytes: pointer, count: length))
                pcmBytes += UInt32(length)
            }
        }
        if reader.status == .failed {
            throw AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "unknown decode error")
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.wavHeader(dataLength: pcmBytes))
    }

    /// Canonical 44-byte PCM WAV header: 16 kHz, mono, 16-bit little-endian.
    static func wavHeader(dataLength: UInt32) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataLength))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                     // fmt chunk size
        append(UInt16(1))                      // PCM
        append(UInt16(1))                      // mono
        append(UInt32(16_000))                 // sample rate
        append(UInt32(16_000 * 2))             // byte rate
        append(UInt16(2))                      // block align
        append(UInt16(16))                     // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataLength)
        return data
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/run_tests.sh 2>&1 | tail -3`
Expected: all suites PASS including `AudioExtractorTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/AudioExtractor.swift Tests/WhisperDeskTests/AudioExtractorTests.swift
git commit -m "Add AVFoundation audio extractor producing 16kHz mono WAV"
```

### Task 2: Shared audio cache, compatible with the Python helper's keys

**Files:**
- Create: `Sources/Services/AudioCache.swift`
- Test: `Tests/WhisperDeskTests/AudioCacheTests.swift`
- Reference: `Sources/Support/BackendScriptWriter.swift` (`audio_cache_path`, `prune_audio_cache`) — the Swift implementation must mirror this byte-for-byte.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import WhisperDesk

struct AudioCacheTests {
    // Mirrors the Python helper: payload is
    // "<resolved path>|<size>|<mtime_ns>|preprocess=<True/False>",
    // digest is the first 24 hex chars of sha256, file "<digest>.wav".
    @Test func cacheKeyMatchesPythonScheme() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-key-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let url = try AudioCache.cachedAudioURL(for: file, preprocess: false)
        #expect(url.pathExtension == "wav")
        #expect(url.deletingPathExtension().lastPathComponent.count == 24)
        // Deterministic: same input, same key.
        #expect(try AudioCache.cachedAudioURL(for: file, preprocess: false) == url)
        // Preprocess flag participates in the key.
        #expect(try AudioCache.cachedAudioURL(for: file, preprocess: true) != url)
    }

    @Test func pruneDeletesOldestBeyondCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<3 {
            let url = dir.appendingPathComponent("f\(index).wav")
            try Data(count: 1_000).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10))],
                ofItemAtPath: url.path
            )
        }
        AudioCache.prune(directory: dir, maxBytes: 2_500, keeping: dir.appendingPathComponent("f2.wav"))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(remaining == ["f1.wav", "f2.wav"])
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `./script/run_tests.sh` → compile error (`AudioCache` missing).

- [ ] **Step 3: Implement `AudioCache`** — port `audio_cache_path` and `prune_audio_cache` from the embedded Python (use `CryptoKit.SHA256`; `st_mtime_ns` comes from `URLResourceKey.contentModificationDateKey` converted to nanoseconds; Python renders the flag as `True`/`False` — reproduce that capitalization exactly). Expose:

```swift
import CryptoKit
import Foundation

enum AudioCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperDesk/audio", isDirectory: true)
    }

    static func cachedAudioURL(for sourceURL: URL, preprocess: Bool) throws -> URL {
        let resolved = sourceURL.resolvingSymlinksInPath().path
        let attrs = try FileManager.default.attributesOfItem(atPath: resolved)
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let mtimeNs = UInt64(mtime.timeIntervalSince1970 * 1_000_000_000)
        let flag = preprocess ? "True" : "False"
        let payload = "\(resolved)|\(size)|\(mtimeNs)|preprocess=\(flag)"
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(digest).wav")
    }

    static func prune(directory: URL, maxBytes: UInt64 = 10 * 1024 * 1024 * 1024, keeping: URL?) {
        // Same policy as the Python helper: sort .wav files by mtime, delete
        // oldest (never `keeping`) until the total is under maxBytes.
        // (Implementation identical in shape to prune_audio_cache.)
    }
}
```

The `prune` body must be written out fully in implementation (list files, sum sizes, delete oldest-first skipping `keeping`); test drives correctness. `prune` must also sweep stale `*.partial-*` files (left behind by a hard kill or power loss during extraction), not just `*.wav`.

⚠️ **mtime fidelity check:** Python uses `st_mtime_ns` (integer nanoseconds); `Date` round-trips through Double and can drift a few hundred ns, producing a *different* digest than Python for the same file. During implementation, verify with one real file that Swift and Python produce the same key (`python3 -c` one-liner vs a debug print). If they differ, read `st_mtimespec` via `stat()` directly instead of Foundation. Cache sharing is the whole point of this task — do not skip the check.

- [ ] **Step 4: Run tests** — expect PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add shared audio cache with Python-compatible keys"`.

### Task 3: Wire native extraction into `TranscriptionService`

**Files:**
- Modify: `Sources/Services/TranscriptionService.swift` (`transcribe(videoURL:settings:progress:)`)
- Modify: `Sources/Support/BackendScriptWriter.swift` (embedded script: accept a pre-extracted WAV)

- [ ] **Step 1: Teach the Python helper to accept pre-extracted audio.** Add `--audio-wav PATH` to the embedded script's argparse; when present and the file exists, `prepare_audio` returns that path directly (no ffmpeg, no cache write). Bump nothing else — the script rewrites itself on next launch because its content hash changes.

- [ ] **Step 2: Extract in Swift before spawning Python.** In `TranscriptionService.transcribe`, before building the process arguments:

```swift
let wantsPreprocess = snapshot.preprocessAudio && ProcessEnvironment.hasFFmpeg
let cachedWav = try AudioCache.cachedAudioURL(for: videoURL, preprocess: wantsPreprocess)
var audioArgument: [String] = []
if FileManager.default.fileExists(atPath: cachedWav.path) {
    audioArgument = ["--audio-wav", cachedWav.path]
} else if !wantsPreprocess {
    progress(JobProgress(stage: .extractingAudio, detail: "Extracting audio.", fraction: 0.08))
    try await AudioExtractor.extract(from: videoURL, to: cachedWav)
    AudioCache.prune(directory: AudioCache.directory, keeping: cachedWav)
    audioArgument = ["--audio-wav", cachedWav.path]
}
// wantsPreprocess && no cache → pass nothing; the Python helper runs its
// ffmpeg filter chain exactly as today.
```

`ProcessEnvironment.hasFFmpeg` is a new small helper: `which ffmpeg` against `ProcessEnvironment.withToolPaths()`'s PATH, cached per launch. If native extraction throws (exotic container), log via a progress event and fall through to passing nothing (Python/ffmpeg path) — behavior is never worse than today. The cache-hit existence check above is safe because `AudioExtractor.extract` is atomic: it writes to a temp file and moves it into place only on success, so a file at the cached path is always a complete WAV.

- [ ] **Step 3: Manual verification.** Transcribe one real clip with "Clean audio" off and ffmpeg renamed away (`sudo mv` not needed — just run with `PATH=/usr/bin`): the job must complete. Expected log line: `Extracting audio.` from Swift, none from ffmpeg.
- [ ] **Step 4: Run the full suite** — `./script/run_tests.sh` all green.
- [ ] **Step 5: Commit** — `git commit -m "Extract audio natively, passing pre-extracted WAV to the helper"`.

### Task 4: Diagnostics — ffmpeg becomes optional

**Files:**
- Modify: `Sources/Services/EnvironmentDiagnosticsService.swift` (ffmpeg entry: `optional: true`, recovery text: "Only needed for the Clean audio option and rare containers AVFoundation can't read.")
- Modify: `Sources/Views/SetupGuideView.swift` — no code change needed (optional styling already exists); verify the ffmpeg row renders with the `optional` badge.
- Modify: `Sources/Views/DetailView.swift` / `SettingsView.swift` — "Clean audio" toggle help text gains "(requires ffmpeg)".

Steps: change → run app → confirm diagnostics pill shows warning (not failure) without ffmpeg → commit `"Make ffmpeg an optional dependency in diagnostics"`.

---

## Phase 2 — Native whisper.cpp engine (removes Python for the default path)

### Task 5: Pin whisper.cpp via SwiftPM

**Files:**
- Modify: `Package.swift`

- [x] **Step 1:** Add the dependency, pinned to an exact release (choose the newest tagged release at implementation time and record it here). Pinned: **v1.7.2** (commit `6266a9f9e56a5b925e9892acf650f3eb1245814d`) — the newest tag whose `Package.swift` builds the sources via SwiftPM; v1.7.3 through v1.9.1 (latest release) either replace the manifest with a `systemLibrary` requiring a pkg-config-installed libwhisper or drop `Package.swift` entirely. Pinned by revision rather than `exact:` because SwiftPM forbids the unsafe build flags in whisper.cpp's manifest for version-based dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/ggml-org/whisper.cpp", revision: "6266a9f9e56a5b925e9892acf650f3eb1245814d") // tag v1.7.2
],
// target WhisperDesk:
dependencies: [.product(name: "whisper", package: "whisper.cpp")]
```

- [x] **Step 2:** `swift build` — expect a long first compile (C/C++/Metal). If the package product name differs on the pinned tag, take the name from that tag's `Package.swift`, not from this document. (Product name on v1.7.2 is `whisper`.)
- [x] **Step 3:** Smoke-test linkage: temporarily call `whisper_print_system_info()` from app startup, run, check the log mentions `METAL = 1`, then remove the call. (Verified via a temporary test: `... NEON = -1 | ARM_FMA = 1 | METAL = 1 ...`; temp test removed.)
- [x] **Step 4:** Commit — `"Add whisper.cpp as a pinned SwiftPM dependency"`.

Review notes for later tasks: (a) v1.7.2 ships `ggml-metal.metal` as a SwiftPM *resource bundle* (`whisper_whisper.bundle`) compiled at runtime — Task 11's release build must confirm the bundle travels inside the .app or Metal silently falls back to CPU; (b) the upgrade path past v1.7.2 is upstream's prebuilt `whisper.xcframework` release artifacts, not a newer SwiftPM tag.

### Task 6: `WhisperCppEngine` — transcription actor over the C API

**Files:**
- Create: `Sources/Services/WhisperCppEngine.swift`
- Test: `Tests/WhisperDeskTests/WhisperCppEngineTests.swift` (segment-mapping logic only; full-model inference is not unit-testable in CI)

- [x] **Step 1: Failing test for timestamp mapping** (whisper.cpp reports centiseconds):

```swift
@Test func mapsCentisecondTimestampsToSeconds() {
    let segment = WhisperCppEngine.mapSegment(index: 0, t0: 150, t1: 425, text: " Hello there ")
    #expect(segment.id == 1)
    #expect(segment.start == 1.5)
    #expect(segment.end == 4.25)
    #expect(segment.text == "Hello there")
}
```

- [x] **Step 2:** Run — fails (type missing).
- [x] **Step 3: Implement.** Core shape (verify each symbol against the pinned tag's `whisper.h` before use):

```swift
import Foundation
import whisper

actor WhisperCppEngine {
    struct Result { let segments: [TranscriptionSegment] }

    static func mapSegment(index: Int, t0: Int64, t1: Int64, text: String) -> TranscriptionSegment {
        TranscriptionSegment(
            id: index + 1,
            start: Double(t0) / 100.0,
            end: Double(t1) / 100.0,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func transcribe(
        wavURL: URL,
        modelURL: URL,
        language: String,          // "auto" → nil for whisper.cpp autodetect
        beamSize: Int,
        noSpeechThreshold: Double,
        onProgress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Result {
        var contextParams = whisper_context_default_params()   // Metal on by default
        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            throw WhisperCppError.modelLoadFailed(modelURL.lastPathComponent)
        }
        defer { whisper_free(context) }

        let samples = try Self.loadPCM16AsFloat(wavURL)        // strip 44-byte header, Int16 → Float32 / 32768

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = Int32(beamSize)
        params.no_speech_thold = Float(noSpeechThreshold)
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.no_context = true                               // match condition_on_previous_text=False
        // language: hold the C string alive for the whole whisper_full call
        // progress_callback / abort_callback: box the closures via user_data

        let status = whisper_full(context, params, samples, Int32(samples.count))
        guard status == 0 else { throw WhisperCppError.inferenceFailed(Int(status)) }

        let count = Int(whisper_full_n_segments(context))
        let segments = (0..<count).map { i in
            Self.mapSegment(
                index: i,
                t0: whisper_full_get_segment_t0(context, Int32(i)),
                t1: whisper_full_get_segment_t1(context, Int32(i)),
                text: String(cString: whisper_full_get_segment_text(context, Int32(i)))
            )
        }
        return Result(segments: segments)
    }
}
```

Implementation notes that are load-bearing:
- **C callback plumbing:** `params.progress_callback` and `params.abort_callback` take C function pointers plus `*_user_data`; pass an `Unmanaged<Box>` pointer holding the two Swift closures. No Swift closures directly — C function pointers cannot capture.
- **Language string lifetime:** `params.language` is `UnsafePointer<CChar>` — use `withCString` *around* the `whisper_full` call; a dangling pointer here is a classic crash.
- **`loadPCM16AsFloat`**: read the WAV produced by `AudioExtractor`, skip the header by parsing the `data` chunk offset (do not hardcode 44 — some tools emit extended headers), convert Int16 LE → Float in [-1, 1].
- [x] **Step 4:** Run tests — mapping test passes.
- [x] **Step 5:** Manual end-to-end: download a tiny model by hand (`ggml-tiny.bin`), transcribe the Task 1 fixture, expect non-empty segments.
- [x] **Step 6:** Commit — `"Add native whisper.cpp transcription engine"`.

### Task 7: `ModelDownloader` with progress and resume

**Files:**
- Create: `Sources/Services/ModelDownloader.swift`
- Test: `Tests/WhisperDeskTests/ModelDownloaderTests.swift`

Design (all decided, no open questions):
- Models live in `~/Library/Application Support/WhisperDesk/models/<file>.bin`.
- Source URLs: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<file>` for `ggml-large-v3-turbo-q5_0.bin` (default, ~574 MB), `ggml-large-v3-turbo.bin`, `ggml-medium.bin`, `ggml-small.bin`, `ggml-base.bin`, `ggml-tiny.bin`.
- `URLSession` download task with a delegate reporting `JobProgress(stage: .loadingModel, detail: "Downloading <name> (<pct>%)", fraction:)`; partial downloads resume via `resumeData` persisted next to the target as `<file>.resume`.
- A finished download is `moveItem`-ed into place atomically; presence of the final file == installed. `installedModels()` lists the directory.

Test (failing first): destination-path derivation, "already installed" short-circuit, and resume-data file naming — the pure logic, with the network layer injected as a protocol so tests never hit the network. Commit: `"Add whisper model downloader with progress and resume"`.

### Task 8: Route the new backend through `TranscriptionService` and the UI

**Files:**
- Modify: `Sources/Models/AppSettingsStore.swift` — `WhisperBackend` gains `case native = "whisper-cpp"` (append-only; existing raw values untouched). `AppSettingPresets.whisperModels(for: .native)` lists the six GGML models. `normalizeModelForSelectedBackend` maps non-`ggml-` models to `ggml-large-v3-turbo-q5_0.bin`. `TranscriptionPreset.fastAppleSilicon` keeps MLX; new preset `case builtIn` ("Built-in (no setup)") pairs `.native` + default model and becomes the **first** preset in the list.
- Modify: `Sources/Services/TranscriptionService.swift` — `transcribe` branches: `.native` → `AudioExtractor`/`AudioCache` (already done in Task 3) + `ModelDownloader.ensureInstalled` + `WhisperCppEngine`, mapping progress into the existing `JobProgress` stages; all other backends → the Python subprocess path unchanged. Cancellation: the existing `Task` cancellation flips the engine's `isCancelled` box (abort callback returns true → `whisper_full` exits early).
- Modify: `Sources/Stores/AppModel.swift` — no structural change; verify the skip-unchanged-transcript fingerprint check includes the backend/model (it already compares `whisperBackend`/`whisperModel`).
- Test: extend `TranscriptionPostProcessorTests` with one case feeding `WhisperCppEngine.mapSegment` output through `TranscriptionPostProcessor.clean` to prove the shared cleanup pipeline applies to native results.

Steps: failing test → implement → full suite → manual end-to-end with the real default model on a short clip → commit `"Route native whisper.cpp backend through transcription pipeline"`.

---

## Phase 3 — Native by default, zero-dependency first run

### Task 9: Defaults and migration

**Files:**
- Modify: `Sources/Models/AppSettingsStore.swift`

- Fresh installs (no stored `whisperBackend` key): default preset `builtIn`, backend `.native`, model `ggml-large-v3-turbo-q5_0.bin`.
- Existing installs: stored settings win — someone already on MLX stays on MLX. Verify by decoding a UserDefaults snapshot with `whisperBackend = "mlx-whisper"` and asserting nothing changes.
- `.auto` backend resolution order becomes: native (always available) — so `.auto` simply behaves as `.native` unless the user explicitly picks a Python backend. Keep the raw value `"auto"` decoding.
- Commit: `"Default new installs to the built-in whisper.cpp backend"`.

### Task 10: Diagnostics and setup guide for the zero-dependency world

**Files:**
- Modify: `Sources/Services/EnvironmentDiagnosticsService.swift` — Python/mlx/faster/qwen3 probes become `optional: true` with a new leading diagnostic: "Built-in engine — Ready (nothing to install)". Only probe Python tools at all when an advanced backend is selected or installed (`settings.whisperBackend != .native` → full probe; otherwise probe cheaply and mark informational).
- Modify: `Sources/Views/SetupGuideView.swift` — intro copy becomes: "WhisperDesk works out of the box. The items below are **optional** engines and features."; the sheet **no longer auto-opens** when only optional items are missing (`AppModel.runDiagnostics` gate changes from `state == .failed` to `state == .failed && !optional` — after Task 9 nothing required can fail on a fresh install).
- Modify: `Sources/Stores/AppModel.swift` — first-launch experience: instead of the setup sheet, the model-download progress appears on the first transcription job.
- Commit: `"Report zero required dependencies with the built-in engine"`.

### Task 11: Docs, release, and regression pass

**Files:**
- Modify: `README.md` — install section drops the brew/pip block for the default path (moves under "Optional engines"); performance table gains a "Built-in (whisper.cpp)" note: same model family, expect roughly MLX-comparable times on Apple Silicon, and Intel Macs now work (CPU, slow).
- Modify: `script/build_and_run.sh` — nothing expected; confirm `--release` DMG size (whisper.cpp adds ~10–20 MB with Metal shaders) and that notarization passes with the C++ code (hardened runtime: no JIT entitlements needed).
- Regression checklist (manual, on the release build):
  - [ ] Fresh-user simulation: `defaults delete com.local.WhisperDesk` equivalent (new macOS user account), no ffmpeg/Python on PATH → drop a clip → transcription completes with model download progress.
  - [ ] Pristine-Mac check (from Task 10 review): on a Mac with no Command Line Tools, the diagnostics python3 probe invokes the `/usr/bin/python3` shim, which may pop Apple's "install developer tools?" dialog at first launch — verify on a clean VM/account; if it fires, gate the Python probes behind a dialog-free `xcode-select -p` check.
  - [x] Existing MLX user: settings preserved (automated: `AppSettingsStoreTests` decodes a stored `mlx-whisper` snapshot unchanged); Python-path runtime still a manual spot-check.
  - [x] Cancel mid-native-transcription stops within ~2 s (measured 0.03 s from cancel to `CancellationError` on Metal with `ggml-tiny` over a 4-minute clip, via a temporary swift-testing check, since deleted; caveat: a cancel issued during model load / first-run Metal shader compile only takes effect once `whisper_full` starts servicing the abort callback — observed ~4 s in that window).
  - [ ] Translated job → export SRT with intro summary → cue timings sane.
- Commit: `"Document the zero-dependency install"` and tag the release.

Release-verification notes (2026-07-26): the review-note risk from Task 5 was real but understated — SwiftPM's `whisper_whisper.bundle` accessor looks for the bundle at the .app root, where codesign rejects it ("unsealed contents present in the bundle root"), and the raw `ggml-metal.metal` cannot compile at runtime anyway because Metal's `newLibraryWithSource` has no include path for `#include "ggml-common.h"` (so Metal silently fell back to CPU even in dev builds). Fix: `build_and_run.sh` now inlines `ggml-common.h` into the shader (the same merge as upstream's embed step) and ships it in `Contents/Resources`; `WhisperCppEngine` points ggml at it via `GGML_METAL_PATH_RESOURCES`. Verified end to end by a temp test compiling the shipped shader through `whisper_init` on Metal (`ggml_metal_init` loaded the staged copy, GPU initialized). DMG grew 3.6 → 4.1 MB (the 10–20 MB estimate assumed heavier payloads); notarization `Accepted`, stapled; `spctl` accepts both DMG (`Notarized Developer ID`) and .app.

---

## Self-review notes

- **Spec coverage:** ffmpeg removal (Tasks 1–4), Python removal for default path (5–8), zero-dependency first run (9–10), docs/release (11). "Clean audio without ffmpeg" is explicitly out of scope (design constraint).
- **Type consistency:** `AudioExtractor.extract(from:to:)`, `AudioCache.cachedAudioURL(for:preprocess:)`, `WhisperCppEngine.mapSegment(index:t0:t1:text:)` used consistently across tasks.
- **Known risk register:** (1) whisper.cpp API drift vs the pinned tag — Task 5/6 verify against `whisper.h` before coding; (2) cache-key ns fidelity — explicit check in Task 2; (3) notarization of C++/Metal — checked in Task 11; (4) beam-search memory on 8 GB Airs with the full turbo model — default is the q5_0 quant partly for this reason.
