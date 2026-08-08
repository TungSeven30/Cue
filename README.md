<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/wordmark-dark.svg">
    <img src="docs/wordmark-light.svg" alt="Cue" width="420">
  </picture>
</p>

**Cue** (formerly WhisperDesk) is a native macOS app that turns local video and audio into subtitles: transcribe on-device with Whisper-family models, translate with the LLM of your choice, review and edit every segment with a synced video preview, and export clean SRT/WebVTT files — including an optional spoiler-free intro cue generated from the film itself.

Transcription runs locally. Translation and summaries use only the cloud providers or OpenAI-compatible local server you explicitly configure.

## Features

**Transcription (on-device)**
- Backends: a built-in [whisper.cpp](https://github.com/ggml-org/whisper.cpp) engine (Metal-accelerated, nothing to install) is the default; optional extras are [mlx-whisper](https://github.com/ml-explore/mlx-examples) (fast on Apple Silicon), [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (most compatible), and Qwen3-ASR (best accuracy, especially for CJK content)
- Friendly presets pair backend + model. Whisper quality presets tune preprocessing and decode controls; Qwen uses a dedicated movie profile that keeps clean audio untouched, preserves spoken repetition, and hides Whisper-only knobs
- Qwen accepts optional names and vocabulary as context, processes silence-aligned audio chunks directly from memory, and records per-stage timing plus real-time factor in the job log
- Automatic transcript cleanup: removes empty segments, collapses repeated text, merges tiny fragments, and repairs zero-length or overlong cues
- Audio is extracted natively (AVFoundation) and cached (capped at 10 GB), so re-runs skip the extraction step

**Translation**
- OpenAI, Anthropic (Claude), Google (Gemini), OpenRouter, or an OpenAI-compatible local server — the provider is inferred from the model name, so switching is just picking a different model
- Token-aware, schema-validated requests with retries, automatic chunk-splitting on oversized responses, and cross-chunk context so names, tone, and honorifics stay consistent
- Cloud translation begins after the first useful streamed transcript batch and adapts request size to the actual text instead of waiting for a fixed subtitle count; already translated ranges are never submitted twice
- Partial translations are saved continuously and resume after an interruption or failed chunk
- Optional auto-translate after transcription

**Intro summary**
- One click (or a toggle for every job) asks the translation model, a separate cloud model, or a local model for a spoiler-free, back-of-the-box intro based on the subtitles
- An optional fallback model runs only when the primary model explicitly refuses the content for a policy/safety reason; rate limits, bad keys, outages, and malformed replies never switch providers
- Prepended as the first cue of SRT/VTT exports, shown from 0s until the first dialogue (3s minimum, 10s cap)
- Generated in the translation's target language, or the film's own language for untranslated jobs

**Watch folders**
- The sidebar's Watch Folders section: click Add Watch Folder (or drag a folder from Finder into the sidebar) and every video dropped into it afterward is queued, transcribed, and translated automatically, with SRT sidecars saved next to each file
- Watch as many folders as you like, each with its own language/preset/translation profile (right-click > Folder Settings) — e.g. one inbox that translates Japanese to Vietnamese and another that only transcribes English
- Right-click a folder to pause/resume watching, reveal it in Finder, or stop watching it
- The app holds a sleep assertion while jobs are running, so an idle Mac won't nap mid-batch — but a closed lid still puts it to sleep, so leave the lid open or connect a display for overnight runs
- "Clear Watch History" forgets which files were already processed, so everything currently in the folder is picked up again

**Queue control**
- Drag jobs in the sidebar to reorder them, or use the context menu's Move to Top / Move to Bottom
- Each job's context menu has "Job Settings…" for per-job overrides — source language, preset, translation target, auto-translate — that inherit from your Settings defaults until you change them; a small slider badge marks jobs with overrides
- Remove a job from the queue (without deleting it) if you change your mind before it runs

**Review & export**
- Three-pane UI: job queue sidebar, editable transcript/translation tabs, resizable video preview with the active subtitle highlighted and overlaid on the picture
- Search, warning-filter (empty text, bad timing, overlong cues), and bulk find-and-replace
- Export SRT, WebVTT, plain text, Markdown, and JSON — original, translated, and bilingual documents, plus run logs
- Auto-sidecar export drops language-coded `.srt` files next to the source video so media players pick them up automatically
- Burn in subtitles as permanent video text: from the export sheet or a job's context menu ("Burn In Video…"), pick a text size and it renders `<name>.burned.mp4` next to the source video. This is what your ffmpeg install (also used for audio extraction) needs libass for — the standard Homebrew bottle usually includes it, but the app preflights the check and tells you if your build lacks the subtitles filter. Output is always 8-bit SDR H.264 — HDR sources come out tone-shifted, so re-encode from an SDR source if that matters to you

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

Grab `Cue.dmg` (notarized, from a release or shared directly), drag the app to Applications, and launch it. That's it — no Homebrew, no Python: transcription runs on the built-in whisper.cpp engine out of the box. The first transcription downloads the default model (~574 MB, one-time) with progress shown on the job.

Updates are built in: the app offers new versions itself (Sparkle, fed from the public [cue-releases](https://github.com/TungSeven30/cue-releases) repo), or check manually via **Cue > Check for Updates…**. Publishing a complete release is one command on the release machine: `script/release.sh <version>`.

To translate or summarize in the cloud, add the matching OpenAI, Anthropic, Google, or OpenRouter API key in Settings (⌘,). A `local/…` model uses your configured OpenAI-compatible server and needs no key.

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

For Qwen, set the spoken language when it is known and enter character names,
places, or unusual vocabulary in **Qwen names & terms**. The standalone helper
offers the same feature through `--qwen-context "Name Place Term"`.

#### Local translation

Translation can also run free and offline against any OpenAI-compatible server (LM Studio, Ollama, mlx-lm) instead of a cloud API. Pick the **Local server (LM Studio / Ollama)** model in Settings — or any `local/…` model name — and point **Local server URL** at your server (default `http://localhost:1234/v1`, LM Studio's address); no API key is needed. LM Studio's "serve on local network" toggle even lets a big Mac translate for a MacBook over the LAN — just set the URL to that Mac's address.

## Building from source (for developers)

```sh
git clone git@github.com:TungSeven30/Cue.git
cd Cue
./script/build_and_run.sh            # debug build, opens the app
```

Other script modes:

| Command | What it does |
|---|---|
| `./script/build_and_run.sh --install` | Release build installed to `/Applications` (or `~/Applications`) |
| `./script/build_and_run.sh --bundle` | Release `.app` bundle with Sparkle/signature/Metal verification; does not launch or stop Cue |
| `./script/build_and_run.sh --release` | Developer ID-signed, notarized, stapled `dist/Cue.dmg` |
| `./script/rehearse_release.sh <version>` | Full notarization/Gatekeeper/Metal/Sparkle rehearsal without publishing |
| `./script/build_and_run.sh --debug` | Debug build under `lldb` |
| `./script/build_and_run.sh --logs` | Debug build with live log streaming |
| `./script/run_tests.sh` | Runs the swift-testing suite |
| `./script/run_coverage.sh` | Runs tests with enforced total/domain/critical-file coverage floors |
| `./script/lint_swift.sh` | Enforces the repository's Swift format in strict mode |
| `./script/format_swift.sh` | Applies the repository's Swift format |

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
- **Transcription**: the default backend calls whisper.cpp (pinned SwiftPM dependency, Metal) in-process; the optional Python backends use a self-contained helper script invoked as a subprocess. Qwen reads the cached PCM WAV once, vectorizes silence planning, passes NumPy chunks without temporary files, and streams segments plus structured performance metrics over stderr
- **Translation/summaries**: direct HTTPS to the explicitly selected provider APIs—or the configured local server—with JSON-schema-constrained outputs and token-aware adaptive batching; no SDK dependencies
- **Persistence**: one JSON file per job under `~/Library/Application Support/Cue/jobs/`, written atomically off the main thread and flushed on quit; corrupt files are quarantined, never overwritten
- **Layout**: `Sources/` — `App`, `Views`, `Stores`, `Services`, `Models`, `Support`; `Tests/` — swift-testing suite; `script/` — build, test, and release tooling
- **Audit/runbooks**: [architecture review](docs/architecture-review-2026-08-08.md), [security model](docs/security-model.md), [dependency policy](docs/dependency-policy.md), [release/rollback](docs/release-runbook.md), and [data recovery](docs/data-recovery.md)

## Notes

- The default transcription setup is the built-in engine with `ggml-large-v3-turbo-q5_0` (the MLX backend uses `mlx-community/whisper-large-v3-turbo`); translation languages/model and independent primary/fallback summary models are configurable in Settings, as are the translator prompt, chunk sizes, and parallelism.
- `transcribe.py` at the repo root is the generated standalone form of the exact helper embedded in the app. Edit `BackendScript.source`, run `python3 script/sync_backend_script.py`, and commit both; the test suite rejects any drift.
