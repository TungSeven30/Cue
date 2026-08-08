# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
./script/build_and_run.sh              # debug build, opens the app
./script/build_and_run.sh --install    # release build installed to /Applications (or ~/Applications)
./script/build_and_run.sh --release    # Developer ID-signed, notarized dist/Cue.dmg (needs local cert + notarytool credentials, see README)
./script/build_and_run.sh --debug      # debug build under lldb
./script/build_and_run.sh --logs       # debug build with live `log stream` output
./script/run_tests.sh                  # run the full swift-testing suite
```

- **Always use `script/run_tests.sh`, not `swift test`.** With Command Line Tools only (no Xcode), `swift test` builds the tests but silently runs zero of them (the generated runner lacks the Testing framework search path); the script detects this and loads the test bundle directly via a `dlopen` shim. Single-test filtering (`swift test --filter Name`) only works when a full Xcode install is present — passing `--filter` on a CLT-only machine is silently ignored, so the whole suite runs. Run `xcrun --sdk macosx --show-sdk-platform-path` to check which mode you're in.
- No separate lint command exists.

## Architecture

**Single-window SwiftUI app, one shared state tree.** `AppModel` (`Sources/Stores/AppModel.swift`, ~1450 lines, `@MainActor` `ObservableObject`) is the hub everything routes through: job CRUD, the run queue, watch-folder ingest, export, burn-in, sidecar auto-export, intro-summary generation, and notifications all live there as extensions/sections rather than separate coordinators. Read it first when tracing any user-facing action.

**Two independently serial pipeline slots, one GPU consumer at a time.** Jobs (`TranscriptionJob`, `Sources/Models/TranscriptionJob.swift`) move through `JobStatus`/`JobStage`. `AppModel` runs a GPU slot (transcription and burn-in) and a translation slot (`pumpGPU`/`pumpTranslation`), each serial, that may overlap and pipeline the queue — job B's transcription can start while job A is still translating; `PipelineScheduler.swift` holds the pure "who runs next" decision, never assume concurrent transcription runs on the GPU slot. Segments streamed from the built-in whisper.cpp engine and the Qwen3 backend land in `partialTranscriptSegments` as they arrive and are cleared on completion — a partial transcript must never satisfy the has-transcript checks that gate queue advancement and translation; `ProgressiveTranslationDriver` + `TranslationReconciliation` (`Sources/Services/`) drive incremental cloud translation behind the transcription frontier (local-LLM translation waits for completion instead of overlapping). `JobStore` (`Sources/Stores/JobStore.swift`) persists each job as its own JSON file under `~/Library/Application Support/Cue/jobs/`, written atomically off the main thread; a job caught "running" at load time (crash/force-quit) is sanitized back to `.canceled` rather than left stuck. A legacy single `jobs.json` is migrated to per-job files on first launch and kept as a backup, never deleted.

**Job settings resolution has two layers.** `AppSettingsStore` holds global defaults; `JobSettingsOverrides` layers per-job overrides on top to produce a `JobSettingsSnapshot` frozen onto the job (services never read `AppSettingsStore` directly during a run). Within that snapshot, `TranscriptionIdentity` is the subset of fields that determines the *transcript* output — two runs with equal identity can skip re-transcription. Any new field that affects the transcript must be added there too, and any new translation-facing field must go through `updatingTranslationFields(from:)`, or stale values get stamped silently — see the comment block above `JobSettingsSnapshot` in `TranscriptionJob.swift`.

**Transcription backend dispatch** (`Sources/Services/TranscriptionService.swift`): `.auto` resolves to the built-in engine; explicit backends run as configured.
- Built-in path: fully in-process — native AVFoundation extraction (`AudioExtractor`, cached up to 10 GB by `AudioCache`) → `ModelDownloader` (short-circuits if already installed) → `WhisperCppEngine` (an `actor` wrapping the pinned whisper.cpp SwiftPM dependency, Metal-accelerated) → the same `TranscriptionPostProcessor` cleanup used by every backend.
- Optional Python backends (mlx-whisper, faster-whisper, Qwen3-ASR): `BackendScriptWriter` writes a self-contained helper script to disk at runtime (the same logic is checked into the repo root as `transcribe.py`, a standalone CLI copy for scripted use — keep both in sync if you touch the transcription logic), which runs as a subprocess and streams JSON progress events over stderr, including `segments` events that carry the Qwen3 backend's silence-aware streamed batches.
- `TranscriptionPostProcessor` (same file) does shared cleanup: drops empty segments, collapses repeats, merges fragments, and stretches/repairs zero-length or overlong cues.

**Translation is direct HTTPS, no SDKs.** `TranslationService` (`Sources/Services/TranslationService.swift`) infers the provider (OpenAI, Anthropic, Google, or a `local/`-prefixed OpenAI-compatible server) from the model name string alone — there's no separate provider picker. Requests are chunked with a JSON-schema-constrained response format per provider, retried on transient failure, and auto-split into smaller chunks on oversized-response errors; recent already-translated pairs are carried forward across chunks so names/tone/honorifics stay consistent. `TranslationCredentials` (API key + local server URL) is built fresh per run and never persisted onto the job — job files must never carry secrets.

**Watch folder** is its own small pipeline: `WatchFolderService` (polling/orchestration) + `WatchFolderScanEngine` (diffing the folder, scanned recursively through subfolders) + `WatchFolderLedger` (tracks already-ingested files so they aren't re-queued). Ingested jobs bypass `AppModel.enqueueJob` on purpose — that path would clear `queuePaused` and would respect `autoStartAddedJobs`, both of which are semantics for interactive adds only, not automatic ingest (see the comment above the watch-folder ingest function in `AppModel.swift`).

**Secrets** live in the macOS Keychain via `KeychainStore` (`Sources/Support/KeychainStore.swift`) — never in job files, settings plists, or exports.

**Layout:**
- `Sources/App` — app entry point and menu commands
- `Sources/Stores` — `AppModel` (central state) and `JobStore` (persistence)
- `Sources/Services` — transcription/translation engines, audio extraction/caching, burn-in, model download, watch folder, environment diagnostics
- `Sources/Models` — `TranscriptionJob`, settings/preset enums, job status/stage
- `Sources/Views` — SwiftUI views
- `Sources/Support` — Keychain, process helpers, the Python backend script writer
- `Tests/CueTests` — swift-testing suite (`import Testing`, `@Test func ...`, `@testable import Cue`)
- `script/` — build, test, and release tooling

## Gotchas worth knowing before touching the build

- The whisper.cpp SwiftPM dependency is pinned by commit revision (not `exact:` version) to v1.7.2 — later tags replaced the manifest with a `systemLibrary` requiring pkg-config, which would break the zero-dependency install story. Don't casually bump this dependency; read the comment in `Package.swift` first.
- whisper.cpp compiles its Metal shader at runtime and needs `ggml-common.h` inlined into `ggml-metal.metal` (SwiftPM's bundle accessor and Metal's runtime compiler can't resolve the `#include` on their own). `build_and_run.sh`'s `build_bundle` does this inlining and copies the result into `Contents/Resources`; `WhisperCppEngine` points `GGML_METAL_PATH_RESOURCES` at it. If the whisper.cpp checkout layout changes, this step needs updating.
- Code signing uses a stable local identity (`WhisperDesk Local Signing`) rather than ad-hoc signing for debug builds, so the Keychain's "Always Allow" grants survive rebuilds.
