# Cue for Windows

The Windows build of Cue. It lives beside the macOS app rather than inside
it: the Mac app is built on Apple-only frameworks (SwiftUI, AVFoundation,
Metal, Keychain, FSEvents), so the Windows app re-implements the same
pipeline in Rust and keeps the *contracts* identical. A subtitle, a model
file, or a job transcript produced on one platform is byte-compatible with
the other.

Status: **phase 1 of 6**, a headless engine and CLI. See
[`PLAN.md`](PLAN.md) for the roadmap.

## Layout

| Crate | What it is | macOS counterpart |
|---|---|---|
| `crates/cue-core` | Segments, transcript cleanup, silence-aware chunk planning, SRT/VTT/TXT/MD/JSON export and SRT/VTT import (with legacy-encoding detection), ffmpeg audio extraction + cache, model catalog and resumable, hash-verified downloader | `TranscriptionPostProcessor`, `TranscriptionChunkPlanner`, `SubtitleWriter`, `SubtitleReader`, `AudioCache`, `FFmpegAudioExtractor`, `ModelDownloader` |
| `crates/cue-engine` | Built-in whisper.cpp engine (CPU, or Vulkan/CUDA by feature), resident model cache, fresh state per chunk, streaming segments, cancel, resume | `WhisperCppEngine`, `WhisperModelCache` |
| `crates/cue-cli` | `cue.exe`: `transcribe`, `models`, `convert`, `doctor` | `Sources/CLI` |

Everything in `cue-core` is platform-neutral and tested on Linux and Windows.

## Build

Needs Rust (stable), CMake and a C/C++ compiler (MSVC Build Tools on Windows).

```sh
cd windows
cargo test --workspace
cargo build --release -p cue-cli                    # CPU
cargo build --release -p cue-cli --features vulkan  # GPU: NVIDIA, AMD, Intel (needs the Vulkan SDK to build)
```

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
```

The default model is Large v3 Turbo (quantized), downloaded on first use
from the same pinned Hugging Face revision the Mac app uses.

## Invariants carried over from macOS

- Every chunk gets a fresh whisper state from the resident model; a reused
  state drifts timestamps between runs.
- Chunk cut rules match `TranscriptionChunkPlanner` and the Python helper so
  resume points agree across backends.
- All backends' output goes through the same cleanup before export.
- Subtitle files are written atomically (temp file, then rename).
