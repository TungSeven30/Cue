# WhisperDesk

A native macOS app that turns local video and audio into subtitles: transcribe on-device with Whisper-family models, translate with the LLM of your choice, review and edit every segment with a synced video preview, and export clean SRT/WebVTT files — including an optional spoiler-free intro cue generated from the film itself.

Everything runs locally except translation and summaries, which call the API provider you configure with your own key.

## Features

**Transcription (on-device)**
- Backends: [mlx-whisper](https://github.com/ml-explore/mlx-examples) (fast on Apple Silicon), [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (most compatible), and Qwen3-ASR (best accuracy)
- Friendly presets pair backend + model; quality presets tune audio preprocessing, VAD, beam search, and no-speech thresholds for fast drafts, movie dialogue, noisy audio, or maximum accuracy
- Automatic transcript cleanup: removes empty segments, collapses repeated text, merges tiny fragments, and repairs zero-length or overlong cues
- Extracted audio is cached (capped at 10 GB), so re-runs skip the ffmpeg step

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
- Built-in diagnostics verify ffmpeg, Python, and the whisper backends, with a guided first-run setup sheet that includes copyable install commands
- API keys are stored in the macOS Keychain, never in files or exports

## Installing (for users)

Grab `WhisperDesk.dmg` (notarized, from a release or shared directly), drag the app to Applications, and launch it. On first run the app checks for its command-line dependencies and walks you through installing anything missing. The short version:

```sh
brew install ffmpeg python
python3 -m pip install mlx-whisper
```

Optional extras: `pip install faster-whisper` (Intel Macs / compatibility) and `pip install 'mlx-qwen3-asr[aligner]'` (best accuracy). To translate, add an OpenAI, Anthropic, or Google API key in Settings (⌘,).

Requires macOS 14+. Apple Silicon strongly recommended for the MLX backends.

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
- **Transcription**: a self-contained Python helper script (embedded in the app, written to disk at runtime) invoked as a subprocess; JSON progress events stream back over stderr
- **Translation/summaries**: direct HTTPS to the provider APIs with JSON-schema-constrained outputs; no SDK dependencies
- **Persistence**: one JSON file per job under `~/Library/Application Support/WhisperDesk/jobs/`, written atomically off the main thread and flushed on quit; corrupt files are quarantined, never overwritten
- **Layout**: `Sources/` — `App`, `Views`, `Stores`, `Services`, `Models`, `Support`; `Tests/` — swift-testing suite; `script/` — build, test, and release tooling

## Notes

- The default transcription model is `mlx-community/whisper-large-v3-turbo`; the default translation model and languages are configurable in Settings, as are the translator prompt, chunk sizes, and parallelism.
- `transcribe.py` at the repo root is a standalone CLI variant of the transcription helper for scripted use; the app uses its own embedded copy.
