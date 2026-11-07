# Cue for Windows

The Windows build of Cue. It lives beside the macOS app rather than inside
it: the Mac app is built on Apple-only frameworks (SwiftUI, AVFoundation,
Metal, Keychain, FSEvents), so the Windows app re-implements the same
pipeline in Rust and keeps the *contracts* identical. A subtitle, a model
file, or a job transcript produced on one platform is byte-compatible with
the other.

Status: **phase 3 of 6**: the engine, the CLI (transcribe and translate) and
the desktop app. See
[`PLAN.md`](PLAN.md) for the roadmap.

## Layout

| Crate | What it is | macOS counterpart |
|---|---|---|
| `crates/cue-core` | Segments, transcript cleanup, silence-aware chunk planning, SRT/VTT/TXT/MD/JSON export and SRT/VTT import (with legacy-encoding detection), ffmpeg audio extraction + cache, model catalog and resumable, hash-verified downloader | `TranscriptionPostProcessor`, `TranscriptionChunkPlanner`, `SubtitleWriter`, `SubtitleReader`, `AudioCache`, `FFmpegAudioExtractor`, `ModelDownloader` |
| `crates/cue-engine` | Built-in whisper.cpp engine (CPU, or Vulkan/CUDA by feature), resident model cache, fresh state per chunk, streaming segments, cancel, resume | `WhisperCppEngine`, `WhisperModelCache` |
| `crates/cue-runtime` | The app's engine room: job queue with one transcription slot and one translation slot, coalesced per-job saves, settings, per-job overrides, sidecar export, events for the UI | `AppModel`, `PipelineCoordinator`, `PipelineScheduler`, `JobRepository`, `ExportCoordinator` |
| `crates/cue-cli` | `cue.exe`: `transcribe`, `translate`, `pipeline`, `models`, `convert`, `keys`, `doctor` | `Sources/CLI` |
| `crates/cue-app` | `cue-desktop.exe`: Tauri shell over `cue-runtime`; the UI is plain HTML/CSS/JS in `ui/` with no build step | `Sources/Views` |

Jobs (`cue-core::jobs`) are stored one JSON file per job in
`%LOCALAPPDATA%\Cue\jobs\<UUID>.json`, in the same format the Mac app writes
to `~/Library/Application Support/Cue/jobs/`, so a job file copied between
machines opens on either side. Fields one side doesn't know are kept.

Everything in `cue-core` is platform-neutral and tested on Linux and Windows.

## Build

Needs Rust (stable), CMake and a C/C++ compiler (MSVC Build Tools on Windows).

```sh
cd windows
cargo test --workspace
cargo build --release -p cue-cli                    # CPU
cargo build --release -p cue-cli --features vulkan  # GPU: NVIDIA, AMD, Intel (needs the Vulkan SDK to build)
cargo run -p cue-app                                # the desktop app (add --features vulkan for GPU)
```

The app uses the WebView2 runtime that ships with Windows 10 and 11. On
Linux it builds against WebKitGTK (`libwebkit2gtk-4.1-dev`) for development.
Video preview plays what WebView2 can decode (MP4/H.264, WebM); other
containers such as MKV still transcribe and export, just without a preview.

At runtime Cue needs `ffmpeg.exe` next to `cue.exe` or on `PATH` (the
installer will bundle it). Data lives in `%LOCALAPPDATA%\Cue` (override with
`CUE_HOME`).

## Use

```sh
cue doctor
cue models                       # catalog + what is installed
cue transcribe movie.mkv         # writes movie.srt next to it
cue transcribe a.mp4 b.mp4 -l ja -f srt,vtt -o subs --stream
cue convert old.srt --to vtt

cue keys set openai                          # paste a key; saved in Credential Manager
cue translate movie.srt --to Vietnamese      # movie.translated.vietnamese.srt
cue translate movie.srt --to ja -t claude-sonnet-5 --bilingual
cue translate movie.srt -t local/qwen3 --local-endpoint http://localhost:1234
cue pipeline movie.mkv --to German -f srt,vtt   # transcribe, then translate
```

Translation picks the provider from the model name, like the Mac app:
`claude*` is Anthropic, `gemini*` Google, `openrouter/`, `groq/`, `cerebras/`
and `local/` route by prefix, anything else is OpenAI. Keys come from
Windows Credential Manager (`cue keys set|list|remove`), then
`CUE_<PROVIDER>_API_KEY`, then the provider's usual variable such as
`OPENAI_API_KEY`. `CUE_TRANSLATION_MODEL` and `CUE_LOCAL_ENDPOINT` set
defaults. An interrupted translation leaves a `.partial.json` beside the
output and the next run picks up where it stopped.

The default model is Large v3 Turbo (quantized), downloaded on first use
from the same pinned Hugging Face revision the Mac app uses.

## Invariants carried over from macOS

- Every chunk gets a fresh whisper state from the resident model; a reused
  state drifts timestamps between runs.
- Chunk cut rules match `TranscriptionChunkPlanner` and the Python helper so
  resume points agree across backends.
- All backends' output goes through the same cleanup before export.
- Subtitle files are written atomically (temp file, then rename).
- Translation prompts, JSON schemas, batch sizes and output names match
  `TranslationService` and `ExportCoordinator`; API keys never touch disk
  outside Credential Manager.
