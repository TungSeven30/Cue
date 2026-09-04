# Engine determinism, model residency, and hot-path performance — design

Date: 2026-09-03. Branch: `perf/engine-determinism-and-hot-paths`.

## Goal

Make Cue materially faster to launch, faster across batches of jobs, more
responsive while a job streams, and more reliable, while keeping
transcription and translation output identical wherever that is provable
and only "within epsilon" where the current behaviour is itself not
reproducible. No inference semantics change: same decoding parameters,
prompts, models, chunk boundaries, and translation scheduling.

## Measured facts that drive the design

All measured on an Apple M5 Max with `ggml-tiny` and Cue's own compiled
whisper.cpp v1.7.2 objects (harness in the session scratchpad, numbers in
the analysis that preceded this spec):

- A second `whisper_full` call on a **reused** `whisper_context` drifts cue
  timestamps by 20–40 ms and is not reproducible run to run, even on the CPU
  backend. The first call on a fresh context is bit-identical across
  processes and between CPU and GPU. `WhisperCppEngine` runs every chunk of a
  file longer than ten minutes on one context, so chunk two onward is
  non-reproducible today.
- Loading weights with `whisper_init_from_file_with_params_no_state` and
  creating a fresh `whisper_state` per run reproduces the fresh-context
  output byte for byte (4/4 runs, GPU and CPU). `whisper_init_state` costs
  ~10 ms on tiny.
- Metal shader compile from source: ~1.3 s once per machine (macOS caches it
  per user), then ~40–80 ms. Not a per-job cost.
- `flash_attn = true` changes decoded text on near-ties (320/530 segments on
  a 30-minute file). It is excluded from this work.
- Launch decodes 574 job files (68.5 MB) synchronously on the main actor;
  the parse alone is 0.48 s, Codable decode is 2–3× that.
- Native AVFoundation extraction runs at ~4400× realtime. AVFoundation cannot
  open Matroska; the native path has no ffmpeg fallback, so every MKV fails
  on the default engine.
- vDSP PCM16→Float is bit-exact and 11× faster; vDSP frame RMS is within
  1.1e-6 relative with identical silence candidates and 7.6× faster.

## Components

### 1. `WhisperModelCache` (new, `Sources/Services/WhisperModelCache.swift`)

An actor owning resident model weights.

- Key: `(path, fileSize, mtime)` of the model file, so a replaced model
  with the same name invalidates the entry.
- Entry: `WhisperModel` (final class, `@unchecked Sendable`) wrapping the
  `whisper_context*` created by `whisper_init_from_file_with_params_no_state`;
  `deinit` calls `whisper_free`. The wrapper is only ever deallocated after
  every state created from it has been freed (states are created and freed
  inside the same function scope that holds the wrapper).
- Capacity: one resident model. Acquiring a different key evicts the
  previous entry once it is not checked out.
- Checkout counting: `acquire` returns a `WhisperModelLease`; `release`
  decrements. An entry is evictable only at zero leases.
- Eviction triggers: model key change; idle timeout (10 minutes after the
  last release, configurable for tests); memory pressure via
  `DispatchSource.makeMemoryPressureSource(.warning, .critical)`; explicit
  `evictAll()` (used by tests and by the app on termination).
- Model load errors propagate as `WhisperCppError.modelLoadFailed` exactly as
  today.

### 2. `WhisperCppEngine` (changed)

- Acquires the model from the cache (injectable, default `.shared`).
- Every inference call creates a fresh `whisper_state` with
  `whisper_init_state`, runs `whisper_full_with_state`, reads results with
  the `_from_state` accessors, and frees the state in a `defer`. The
  new-segment callback also reads through the state it is handed.
- Chunked files (over `maxChunk`) create a fresh state **per chunk**. This
  makes long-file output deterministic. It changes chunk-two-plus output
  relative to today's drifted values (text identical in every observed run,
  timestamps within ±40 ms), which is the one intentional "within epsilon"
  change in this work, and it is a correctness fix.
- Cancellation is unchanged: the abort callback polls the caller's flag;
  the state is freed on the way out; the model stays resident.
- Chunk planning parameters become an injectable `ChunkPlanning` value so
  tests can force multi-chunk runs on short fixtures without changing the
  production defaults.

### 3. Persistent Python workers (new `PythonWorkerPool`, script `--serve` mode)

- The embedded script gains a `--serve` mode: it reads one JSON job request
  per line from stdin and, per job, runs exactly the existing per-job code
  path (`prepare_audio` → backend loader → same stderr events) and finally
  writes one line to stdout: `{"event":"result","backend":…,"segments":[…]}`
  or `{"event":"error","message":…}`. Between jobs it keeps loaded model
  objects in a module-level cache keyed by `(backend, model)`; the backends
  are stateless across `transcribe` calls (faster-whisper's `WhisperModel`,
  mlx-whisper's `ModelHolder`, Qwen's `Session`/`ForcedAligner`, which the
  script already reuses across chunks inside one job). Nothing else is
  shared between jobs: temp dir, arguments, and counters are per job.
- `PythonWorkerPool` (actor) keys workers by `(backend, model, script
  hash)`; one worker is resident; requesting another key terminates the old
  worker first. `run(request)` writes the request, streams stderr events
  through the existing `TranscriptionStreamEvent` decoder, and resolves on
  the stdout result line. A worker that exits mid-job fails that job with
  the non-progress stderr text (same message shape as today) and is dropped.
- Cancellation preserves today's semantics: SIGTERM, then SIGKILL after
  three seconds; the pool drops the worker and respawns lazily. Idle
  eviction (10 minutes, configurable) sends a `{"event":"shutdown"}` line
  and then the same terminate sequence. The pool shuts every worker down on
  app termination. `OrphanReaper` already matches `cue_backend.py`, so a
  worker orphaned by a crash is reaped on the next launch as before.
- The standalone `transcribe.py` is regenerated from the embedded source;
  the parity test keeps them identical.

### 4. Job loading (`JobStore`, `JobRepository`, `AppModel`)

- `JobStore.loadJobs()` decodes files concurrently
  (`DispatchQueue.concurrentPerform`) into a slot per directory entry, so
  the result order does not depend on thread timing. Corrupt-file handling
  and the legacy migration are unchanged.
- Ordering is made total and deterministic: the store sorts by
  `updatedAt` descending then `id`; `AppModel` sorts by `orderIndex`
  ascending then `updatedAt` descending then `id`. Equal `orderIndex`
  values therefore load in the same order on every launch.
- `AppModel.init` no longer loads jobs synchronously. It starts a hydration
  task that loads off the main actor and then merges: jobs added
  interactively during hydration keep their position on top (re-stamped
  with `QueueOrdering.indicesForBatchAdd` against the loaded indices) and
  are never duplicated. Watch folders start and the queue pumps only after
  hydration, so a scan cannot re-ingest a file whose job has not loaded
  yet. `isHydratingJobs` lets the views show a neutral state instead of the
  welcome screen. Tests await `hydration()`.

### 5. UI hot paths (`AppModel`, `DetailView`, `TranscriptView`, `LogView`)

- `AppModel.index(of:)` uses a `[UUID: Int]` cache verified on every use
  (`jobs[cached].id == id`) and rebuilt only when the check fails, so it is
  correct after any reorder and O(1) on the streaming path. Every
  `firstIndex(where:)` / `first(where:)` lookup by id routes through it.
- `qualityWarnings` moves behind a `SubtitleWarningCache` keyed by job and
  slot. Fast path: same array buffer and count as the cached entry (the
  cache retains the array, so any mutation must have copied) → cached
  result. Append path: cached prefix unchanged → compute only the new
  suffix. Otherwise recompute. The cache also hands out the grouped
  dictionary so `TranscriptView` stops regrouping per render.
- `SegmentEditorRow` becomes `Equatable` (segment, warnings, active flag)
  and is used with `.equatable()`.
- Overlay synchronisation runs only while the player is visible; the
  `onChange` triggers key on `selectedJobID` plus the current job's
  `updatedAt` rather than comparing whole segment arrays per render.
- `LogView` finds the last N lines by scanning UTF-8 backwards.
- `AppModel.updateJob` checks `log.utf8.count` before the exact
  character count.
- `TranscriptionStreamEvent.decode` routes on the JSON prefix before trying
  decoders in sequence; the fallback order is unchanged.

### 6. Watch folders (`WatchFolderService`)

- The single-directory kqueue source is replaced by an `FSEventStream` on
  the folder with `kFSEventStreamCreateFlagFileEvents`, 0.5 s latency,
  delivered on a private queue and hopped to the main actor. Nested
  changes now trigger a scan immediately.
- After a scan that leaves candidates waiting for the stability gate, the
  service schedules one follow-up scan at `stabilityInterval + 0.5 s`, so
  a new file is ingested a few seconds after it stops growing instead of on
  the next 60 s tick. The 60 s timer and the wake observer stay as the
  reconciliation fallback.

### 7. Persistence batching

- Watch-folder ingest builds every job first, stamps order indices from one
  base value, appends once, and saves through the batch overload.
- `WatchFolderLedger` persists from an immutable snapshot on a utility
  queue with a `flush()` called on termination.
- `AudioExtractor` copies non-contiguous sample buffers correctly instead of
  assuming a contiguous block.

### 8. Signal processing (`WhisperCppEngine`, `TranscriptionChunkPlanner`)

- PCM16→Float uses `vDSP_vflt16` + `vDSP_vsmul` (bit-exact).
- Frame RMS uses `vDSP_rmsqv` per frame (≤1.1e-6 relative; identical
  candidates on every tested signal, verified by a test that compares
  against the scalar reference).
- Candidate-window search uses binary search on the sorted candidate list;
  the Python planner uses `bisect` the same way. Outputs are identical.

### 9. Pipe collection (`PipeCollector`)

- A scan cursor makes newline search incremental. Line splitting is skipped
  entirely when no `onLine` consumer exists; the accumulated data and the
  EOF protocol are unchanged.

### 10. MKV (`TranscriptionService`, new `FFmpegAudioExtractor`)

- When native extraction throws and ffmpeg is on the PATH, the native path
  extracts with `ffmpeg -y -i <in> -vn -acodec pcm_s16le -ar 16000 -ac 1`
  into a temp file beside the cache entry and moves it into place, exactly
  the plain command the Python helper runs. Without ffmpeg the job fails
  with a message that names ffmpeg. Supported containers still take the
  native path first.

## Testing

Targeted regression tests (all under `Tests/CueTests` unless noted):

- `WhisperModelCacheTests`: same key reuses the loaded model; a different
  key evicts; eviction waits for leases; idle timeout and explicit eviction
  free the model; memory pressure evicts an idle model.
- `WhisperCppEngineTests` (model-gated, skips without an installed model):
  two transcriptions of the same fixture are identical; a forced
  multi-chunk run is identical across runs and identical to a cold-cache
  run; cancellation mid-run throws `CancellationError` and leaves the cache
  usable.
- `PythonWorkerPoolTests` (stub script): worker reused across jobs; job
  isolation (no state from job one in job two); crash mid-job fails that
  job and the next job gets a fresh worker; cancellation terminates and
  kills a SIGTERM-ignoring worker; idle timeout evicts.
- `script/test_serve_mode.py`: serve loop with a fake backend module
  constructs the model once for two jobs, emits the same events as the
  one-shot path, and reports per-job errors without exiting.
- `JobStoreTests`: concurrent load returns the same set and deterministic
  order for equal `orderIndex`; corrupt-file quarantine still works.
- `AppModelHydrationTests`: jobs added during hydration survive the merge
  on top; watch folders and the queue wait for hydration.
- `TranscriptionResumeTests` / new `ChunkPlannerVectorTests`: vDSP planner
  matches the scalar reference exactly on tone/silence, noise, and
  clipped signals; bisect window search matches the linear search.
- `WatchFolderServiceTests`: a file created in a nested folder after
  `start` is reported without waiting for the 60 s timer.
- `AppModel` ingest test: N ingested files produce one batch save.
- `PipeCollectorTests`: a single multi-megabyte line without newlines is
  collected intact; lines split across reads decode identically.
- `AudioExtractionFallbackTests`: an MKV fixture (built with ffmpeg when
  available) extracts through the fallback; without ffmpeg the error names
  it.

## Benchmarks captured before and after

Launch job-store load; first and subsequent native transcription of a short
clip; first and subsequent Python transcription (stub worker, since no
Python backend is installed on this machine); main-thread time per
streamed batch with a 574-job list; ingestion of 200 files; chunk-planner
time on a 2-hour synthetic signal.
