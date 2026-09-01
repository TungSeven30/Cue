# transcribe

On-device ASR for a local media file. Writes sidecar subtitles and a `<basename>.cue.json` manifest.

## Sub-features

- Input: local media path (mkv, mp4, mov, etc.)
- Output: subtitle files (default `--format srt`) + manifest beside `--output-dir`
- Settings: `--language`, `--preset`, `--quality`, `--backend`, `--model`, `--output-dir`, `--format`, `--json`, `--quiet`
- Progress on stderr: `[transcribe] NNN% detail`
- Manifest records `transcript` segments, `settings`, `outputs`, `log` notes
- Re-transcription clears any `translation` carried from an earlier manifest

## How to get to it (user POV)

User drops a video into Cue and clicks Transcribe. Headless equivalent:

```bash
./script/cue transcribe /path/to/clip.mkv --preset bestAccuracy --language ja
```

Agent verification uses an isolated scratch dir and a **tiny** fixture (seconds of audio).

## Driving it with ./script/cue

**Prerequisites:** Mac with built app; doctor shows built-in engine passed (or chosen backend ready). First run may download ASR weights via `ModelDownloader`.

```bash
SCRATCH="$(./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh transcribe)"
EV="$(dirname "$SCRATCH")/evidence"
mkdir -p "$EV" "$SCRATCH"

# Copy a tiny fixture into scratch (agent supplies one; repo has no committed media)
FIXTURE="/path/to/tiny-fixture.mkv"
cp "$FIXTURE" "$SCRATCH/"

./script/cue transcribe "$SCRATCH/tiny-fixture.mkv" \
  --output-dir "$SCRATCH" \
  --format srt \
  --json 2>"$EV/transcribe.stderr" \
  | tee "$EV/transcribe-manifest.json"

echo "transcribe exit=$?" >> "$EV/commands.log"
```

**Assert on Mac:**
- Exit **0**
- `$SCRATCH/tiny-fixture.cue.json` exists (manifest path from `CLIManifest.manifestURL`)
- `$EV/transcribe-manifest.json` parses as JSON; `stage` is `transcribe`; `transcript` non-empty
- At least one `.srt` in `outputs` with role `original`
- stderr contains `[transcribe]` progress lines unless `--quiet`

**Without a fixture:** Stop after doctor + parse-error checks; document "needs Mac worker + tiny media".

## Gotchas

- **GPU slot / time:** Transcription loads whisper.cpp (Metal). First run downloads models — allow minutes, not seconds.
- **Empty transcript:** Exit **1**, `CLIError.stageFailed("Transcription produced no segments.")`
- **Missing file:** Exit **2**, `No such file: …`
- **Partial streams:** GUI uses `partialTranscriptSegments`; CLI waits for completion — do not treat partial data as done.
- **`--json` stdout is only the manifest** — file paths and progress stay on stderr (`CLIConsole`).
- **Do not use user's Movies folder** — always `--output-dir` to scratch.
- **Settings inheritance:** Unspecified flags come from app Settings (`AppSettingsStore`); CLI does not mutate saved settings.
