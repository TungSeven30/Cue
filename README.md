# WhisperDesk

WhisperDesk is a native-first macOS app for a personal video workflow:

- pick a local video file
- verify local transcription dependencies before a run
- transcribe it with Whisper locally
- choose a friendly transcription preset or advanced backend/model pair
- choose transcription quality presets for fast drafts, movie dialogue, noisy audio, or maximum accuracy
- monitor and cancel long-running transcription/translation jobs
- translate the subtitle segments into a chosen target language with chunked, validated LLM requests
- optionally translate automatically after transcription
- review and edit subtitle segments before export
- search, warning-filter, and bulk-replace subtitle text
- clean transcripts automatically by removing empty segments, collapsing repeated text, and merging tiny fragments
- resume recent jobs from local app history
- resume partial translations after an interruption or failed chunk
- export `.srt`, `.txt`, `.md`, and `.json` subtitle artifacts, logs, or all files at once

## Architecture

- macOS UI: SwiftUI + AppKit panels
- local transcription: Python helper invoked from the app
- preferred backend: `mlx-whisper` on Apple Silicon
- fallback backend: `faster-whisper`
- translation: OpenAI, Anthropic (Claude), or Google (Gemini) — provider inferred from the model name
- persistence: JSON job history under Application Support

## Recommended local setup

1. Install `ffmpeg`.
2. Install Python dependencies:
   - `pip install mlx-whisper`
   - optional fallback: `pip install faster-whisper`
3. Build and run:
   - `./script/build_and_run.sh`
4. Install as a normal macOS app:
   - `./script/build_and_run.sh --install`
   - This installs and opens `WhisperDesk.app` from `/Applications` when that folder is writable, otherwise from `~/Applications`.

## Notes

- The default transcription model is `mlx-community/whisper-large-v3-turbo`.
- The translation model, source language, target language, and translator prompt are configurable in Settings.
- Transcription presets keep backend and model choices paired; advanced controls expose the raw backend and model fields.
- Transcription quality presets tune audio preprocessing, VAD, beam search, no-speech thresholds, and subtitle cleanup.
- Translation chunking and limited parallelism are configurable in Settings.
- This app is structured so the UI remains native macOS while the speech stack stays replaceable.
- API keys (OpenAI, Anthropic, Google) are stored in the macOS Keychain (any key from earlier builds is migrated out of user defaults on first launch).
