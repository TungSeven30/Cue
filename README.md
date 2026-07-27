# WhisperDesk

A native macOS app that turns local video and audio into subtitles: transcribe on-device with Whisper-family models, translate with the LLM of your choice, review and edit every segment with a synced video preview, and export clean SRT/WebVTT files — including an optional spoiler-free intro cue generated from the film itself.

Everything runs locally except translation and summaries, which call the API provider you configure with your own key.

## Features

**Transcription (on-device)**
- Backends: a built-in [whisper.cpp](https://github.com/ggml-org/whisper.cpp) engine (Metal-accelerated, nothing to install) is the default; optional extras are [mlx-whisper](https://github.com/ml-explore/mlx-examples) (fast on Apple Silicon), [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (most compatible), and Qwen3-ASR (best accuracy, especially for CJK content)
- Friendly presets pair backend + model; quality presets tune audio preprocessing, VAD, beam search, and no-speech thresholds for fast drafts, movie dialogue, noisy audio, or maximum accuracy
- Automatic transcript cleanup: removes empty segments, collapses repeated text, merges tiny fragments, and repairs zero-length or overlong cues
- Audio is extracted natively (AVFoundation) and cached (capped at 10 GB), so re-runs skip the extraction step

**Translation**
- OpenAI, Anthropic (Claude), or Google (Gemini) — the provider is inferred from the model name, so switching is just picking a different model
- Chunked, schema-validated requests with retries, automatic chunk-splitting on oversized responses, and cross-chunk context so names, tone, and honorifics stay consistent
- Partial translations are saved continuously and resume after an interruption or failed chunk
- Optional auto-translate after transcription

**Intro summary**
- One click (or a toggle for every job) asks your translation LLM for a spoiler-free, back-of-the-box intro based on the subtitles
- Prepended as the first cue of SRT/VTT exports, shown from 0s until the first dialogue (3s minimum, 10s cap)
- Generated in the translation's target language, or the film's own language for untranslated jobs

**Review & export**
- Three-pane UI: job queue sidebar, editable transcript/translation tabs, resizable video preview with the active subtitle highlighted and overlaid on the picture
- Search, warning-filter (empty text, bad timing, overlong cues), and bulk find-and-replace
- Export SRT, WebVTT, plain text, Markdown, and JSON — original, translated, and bilingual documents, plus run logs
- Auto-sidecar export drops language-coded `.srt` files next to the source video so media players pick them up automatically

**Reliability**
- Serial job queue for batch processing (one model on the GPU at a time) with per-job persistence — a crash or force-quit never loses finished work, and interrupted jobs resume
- Built-in diagnostics report "Ready — nothing to install" for the default engine and verify the optional extras (Python backends, ffmpeg) only if you opt into them, with a setup sheet of copyable install commands
- API keys are stored in the macOS Keychain, never in files or exports

## How long does a 30-minute clip take?

The two phases have completely different bottlenecks:

- **Transcription** runs on your Mac's GPU — it scales with the chip. The table below is for the **Balanced** preset with `whisper-large-v3-turbo` on MLX; the built-in default engine is in the same ballpark (see the notes).
- **Translation** is network-bound (cloud LLM APIs), so it takes about the same time on every Mac: typically **2–6 minutes** for a dialogue-heavy 30-minute clip with the default chunking and 2 parallel workers, varying with segment count and provider speed rather than hardware. The optional intro summary adds ~10 seconds.

| Machine | Transcribe 30 min (Balanced preset) |
|---|---|
| Mac Studio M3 Ultra (any RAM, incl. 512 GB) | ~1 min |
| MacBook Pro M4 Max | ~1–2 min |
| MacBook Pro M3 Max | ~2 min |
| MacBook Pro M4 Pro / M2 Max | ~2–3 min |
| MacBook Pro M3 Pro | ~3 min |
| MacBook Pro M2 Pro | ~3–4 min |
| MacBook Pro M4 / MacBook Air M4 | ~3–5 min |
| MacBook Air M3 | ~4–6 min |
| MacBook Air M2 | ~5–8 min |

Notes on reading the table:

- These are ballparks derived from published MLX Whisper benchmarks (e.g. ~55× real-time on an M4 Max with greedy decoding), discounted for the app's beam search and audio preprocessing. Run one of your own clips for real numbers.
- **RAM doesn't matter here** — `large-v3-turbo` needs ~1.5 GB; a 512 GB Mac Studio wins on GPU cores and memory bandwidth, not memory size. Any listed machine has plenty of RAM for transcription.
- Fanless MacBook Airs throttle on long runs — the top of each Air range reflects that.
- The **built-in whisper.cpp engine** (the default) runs the same Whisper model family (`large-v3-turbo`, q5_0-quantized) with Metal acceleration — expect roughly MLX-comparable times on Apple Silicon. On Intel Macs, build from source — the built-in engine runs CPU-only there (several times slower).
- **Maximum Accuracy** and **Noisy Audio** presets are roughly 2× the listed times (wider beam search); the **Qwen3-ASR** backend is roughly 2–3× (larger model, better accuracy).
- First run adds one-time costs: model download (~574 MB for the built-in default, ~1.5 GB for MLX) and audio extraction (~30–60 s, cached for re-runs).

## Installing (for users)

Grab `WhisperDesk.dmg` (notarized, from a release or shared directly), drag the app to Applications, and launch it. That's it — no Homebrew, no Python: transcription runs on the built-in whisper.cpp engine out of the box. The first transcription downloads the default model (~574 MB, one-time) with progress shown on the job.

To translate, add an OpenAI, Anthropic, or Google API key in Settings (⌘,).

Requires macOS 14+ and Apple Silicon (the DMG is arm64-only). On Intel Macs, build from source — the built-in engine runs CPU-only there (slow).

### Optional engines

The Python backends are alternatives to the built-in engine — each is a pip module on Python 3 (`brew install python` if you don't have it):

```sh
python3 -m pip install --user --break-system-packages mlx-whisper                # MLX Whisper (fast on Apple Silicon)
python3 -m pip install --user --break-system-packages faster-whisper             # faster-whisper (most compatible)
python3 -m pip install --user --break-system-packages 'mlx-qwen3-asr[aligner]'   # Qwen3-ASR (best accuracy, the pick for CJK content)
```

The flags matter on Homebrew's Python 3.12+, which rejects a plain `pip install` (PEP 668): `--user` keeps the packages in your home folder instead of Homebrew's, and `--break-system-packages` acknowledges the guard. On an older Python that doesn't recognize the flags, drop them.

ffmpeg (`brew install ffmpeg`) is only needed for the **Clean audio** preprocessing option and for rare containers the system decoders can't read.

#### Local translation

Translation can also run free and offline against any OpenAI-compatible server (LM Studio, Ollama, mlx-lm) instead of a cloud API. Pick the **Local server (LM Studio / Ollama)** model in Settings — or any `local/…` model name — and point **Local server URL** at your server (default `http://localhost:1234/v1`, LM Studio's address); no API key is needed. LM Studio's "serve on local network" toggle even lets a big Mac translate for a MacBook over the LAN — just set the URL to that Mac's address.

## Building from source (for developers)

```sh
git clone git@github.com:TungSeven30/WhisperDesk.git
cd WhisperDesk
./script/build_and_run.sh            # debug build, opens the app
```

Other script modes:

| Command | What it does |
|---|---|
| `./script/build_and_run.sh --install` | Release build installed to `/Applications` (or `~/Applications`) |
| `./script/build_and_run.sh --release` | Developer ID-signed, notarized, stapled `dist/WhisperDesk.dmg` |
| `./script/build_and_run.sh --debug` | Debug build under `lldb` |
| `./script/build_and_run.sh --logs` | Debug build with live log streaming |
| `./script/run_tests.sh` | Runs the swift-testing suite |

> **Testing note:** with Command Line Tools only (no Xcode), plain `swift test` builds the tests but silently runs none of them. `script/run_tests.sh` works around this by loading the test bundle directly — use it instead.

### Releasing a DMG

`--release` needs two one-time setups on the build machine:

1. A **Developer ID Application** certificate in the keychain (create at [developer.apple.com](https://developer.apple.com/account/resources/certificates/list) via a Keychain Access CSR).
2. Stored notarization credentials:
   ```sh
   xcrun notarytool store-credentials whisperdesk-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```
   using an [app-specific password](https://account.apple.com).

## Architecture

- **UI**: SwiftUI with AppKit panels, single-window, `@MainActor` state in `AppModel`
- **Transcription**: the default backend calls whisper.cpp (pinned SwiftPM dependency, Metal) in-process; the optional Python backends use a self-contained helper script (embedded in the app, written to disk at runtime) invoked as a subprocess, with JSON progress events streaming back over stderr
- **Translation/summaries**: direct HTTPS to the provider APIs with JSON-schema-constrained outputs; no SDK dependencies
- **Persistence**: one JSON file per job under `~/Library/Application Support/WhisperDesk/jobs/`, written atomically off the main thread and flushed on quit; corrupt files are quarantined, never overwritten
- **Layout**: `Sources/` — `App`, `Views`, `Stores`, `Services`, `Models`, `Support`; `Tests/` — swift-testing suite; `script/` — build, test, and release tooling

## Notes

- The default transcription setup is the built-in engine with `ggml-large-v3-turbo-q5_0` (the MLX backend uses `mlx-community/whisper-large-v3-turbo`); the default translation model and languages are configurable in Settings, as are the translator prompt, chunk sizes, and parallelism.
- `transcribe.py` at the repo root is a standalone CLI variant of the transcription helper for scripted use; the app uses its own embedded copy.
