# Windows port plan

## Decision: a separate Rust + Tauri app in `windows/`, sharing contracts, not code

Cue's Swift code is almost entirely Apple-only: SwiftUI views, AVFoundation
extraction, Metal-accelerated whisper.cpp via SwiftPM, Keychain, FSEvents,
Combine-backed `ObservableObject` state, Sparkle updates. Swift does build on
Windows, but none of those frameworks do, so "sharing the Swift core" would
mean refactoring the shipping Mac app around abstractions just to reuse the
pure-logic slice, which is a few thousand lines.

So the Windows app is its own codebase with the same behavior and the same
data contracts:

| Shared contract | How it stays in sync |
|---|---|
| Segment / job JSON shape | Same field names (`id`, `start`, `end`, `text`) |
| Subtitle output | Writer ported line for line; tests assert the macOS byte layout |
| Transcript cleanup | `TranscriptionPostProcessor` ported with its tests |
| Chunk/resume boundaries | `TranscriptionChunkPlanner` ported; same constants |
| Model files | Same pinned Hugging Face revision, names, sizes, SHA-256 |
| Python backends | Phase 5 reuses the generated `transcribe.py` and its `--serve` protocol unchanged |
| Translation prompts and schemas | Phase 2 ports them verbatim |

Stack: **Rust core + Tauri 2 shell + web UI**. Rust gives an in-process
whisper.cpp (whisper-rs) with Vulkan for any GPU vendor, a single small
installer, and, importantly, a core that builds and tests on Linux, so
most work is verifiable without a Windows machine. Alternatives considered:
C#/WinUI 3 (most native look, but Windows-only builds and weaker whisper.cpp
bindings) and Python + Qt (reuses `transcribe.py` directly, but heavy
installers, slow start, frequent antivirus false positives).

## Platform replacements

| macOS | Windows |
|---|---|
| AVFoundation extraction (ffmpeg fallback) | Bundled ffmpeg.exe, always |
| Metal | Vulkan (default), CUDA (optional build), CPU fallback |
| Keychain | Windows Credential Manager (`keyring` crate) |
| FSEvents watch folders | ReadDirectoryChangesW (`notify` crate) + periodic rescan |
| Sleep assertion | `SetThreadExecutionState` |
| Menu bar extra | System tray icon |
| User notifications | Windows toast notifications |
| Sparkle | Tauri updater (signed update manifest) |
| Developer ID + notarization | Authenticode code signing |
| `~/Library/Application Support/Cue` | `%LOCALAPPDATA%\Cue` |

## Phases (one PR each)

1. **Core + CLI** (done): cleanup, chunking, subtitle I/O, ffmpeg audio
   cache, model download, whisper.cpp engine, `cue.exe`, Windows CI with a
   real tiny-model transcription and a Vulkan build.
2. **Translation** (done): all seven providers over direct HTTPS, token-aware
   batching, schema-validated responses, retries and splitting, resume of
   partial translations, credentials in Credential Manager. Adds
   `cue translate` and `cue pipeline`.
3. **Desktop app (Tauri)** (done): job queue with the two-slot scheduler, per-job
   JSON persistence compatible with the Mac format, transcript/translation
   editor, video preview with subtitle overlay, settings, export dialogs.
4. **Automation** (done): watch folders (recursive, stability gate,
   Mac-format ledger, per-folder overrides), URL ingest via yt-dlp (with a
   checksum-verified installer), tray icon with close-to-tray, toast
   notifications, keep-awake, burn-in via ffmpeg/libass, sidebar grouped by
   source folder, Ctrl+K command palette. Deferred: the Mac's hand-made
   folders (its "folder book"); the sidebar groups by the folder a video is
   in instead.
5. **Optional backends and extras** (this PR): faster-whisper (CUDA when
   CTranslate2 sees an NVIDIA GPU, else CPU) through the shared Python helper
   in serve mode, with a resident worker like `PythonWorkerPool`; the
   spoiler-free intro summary (end of run or on demand, editable, shown as
   the opening cues of SRT/VTT); subtitle import (sidecars beside new and
   watched videos, and loading a file into either slot by hand). Dropped:
   Qwen3-ASR, because the helper's Qwen path runs on MLX, which is
   Apple-only. A PyTorch port of it would be a new backend on both sides.
6. **Ship**: installer (NSIS/MSI) bundling ffmpeg, auto-update, Authenticode
   signing (needs a code-signing certificate), release workflow.
