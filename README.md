# WhisperDesk

WhisperDesk is a native-first macOS app for a personal video workflow:

- pick a local video file
- verify local transcription dependencies before a run
- transcribe it with Whisper locally
- monitor and cancel long-running transcription/translation jobs
- translate the subtitle segments into English with chunked, validated LLM requests
- review and edit subtitle segments before export
- resume recent jobs from local app history
- export `.srt` subtitle files for the transcript, translation, or bilingual captions

## Architecture

- macOS UI: SwiftUI + AppKit panels
- local transcription: Python helper invoked from the app
- preferred backend: `mlx-whisper` on Apple Silicon
- fallback backend: `faster-whisper`
- translation: OpenAI Responses API
- persistence: JSON job history under Application Support

## Recommended local setup

1. Install `ffmpeg`.
2. Install Python dependencies:
   - `pip install mlx-whisper`
   - optional fallback: `pip install faster-whisper`
3. Build and run:
   - `./script/build_and_run.sh`

## Notes

- The default transcription model is `mlx-community/whisper-large-v3-turbo`.
- The default translation model is `gpt-5.2`, but it is configurable in Settings.
- This app is structured so the UI remains native macOS while the speech stack stays replaceable.
- The OpenAI API key is stored in the macOS Keychain (any key from earlier builds is migrated out of user defaults on first launch).
