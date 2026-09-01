# pipeline and manifest chaining

Multi-stage workflows via `.cue.json` manifests. Single-command `pipeline` or explicit stage chain.

## Sub-features

- **Manifest file:** `<basename>.cue.json` next to `--output-dir` (see `CLIManifest.manifestURL`)
- **Chain:** `cue transcribe …` → `cue translate clip.cue.json --to …` → optional `summarize`, `burn-in`
- **pipeline command:** fetch (if URL) → transcribe (if empty transcript) → translate (if `--to` or auto-translate setting) → summarize (if `--summary` or setting) → subtitle export → optional `--burn-in`
- **`--json` on any stage:** manifest JSON on stdout; prior stage files on disk
- **Input types:** media file, `.cue.json`, `.srt`/`.vtt` (becomes transcript), http(s) URL (auto-fetch)
- **Decode tolerance:** older manifests missing fields still load (`CLIManifestTests.decodesAMinimalManifest`)

## How to get to it (user POV)

User runs the full flow in the app queue. Headless:

```bash
# One shot
./script/cue pipeline "https://example.com/watch?v=…" --to English --summary --json

# Or chain manifests
./script/cue transcribe clip.mkv --output-dir ./out --json > /dev/null
./script/cue translate ./out/clip.cue.json --to Vietnamese --json
```

## Driving it with ./script/cue

### Chain after transcribe (cheapest integration test)

```bash
SCRATCH="$(./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh pipeline)"
EV="$(dirname "$SCRATCH")/evidence"
mkdir -p "$EV" "$SCRATCH"

# Assume transcribe already produced $SCRATCH/clip.cue.json
MANIFEST="$SCRATCH/clip.cue.json"

./script/cue translate "$MANIFEST" \
  --to English \
  --output-dir "$SCRATCH" \
  --json 2>"$EV/translate.stderr" \
  | tee "$EV/translate-manifest.json"
echo "translate exit=$?" >> "$EV/commands.log"
```

Skip live translate if doctor shows translation-key **warning** — document skip in `commands.log`.

### Full pipeline (Mac + fixture or URL)

```bash
./script/cue pipeline "$SCRATCH/clip.mkv" \
  --output-dir "$SCRATCH" \
  --format srt,vtt \
  --json 2>"$EV/pipeline.stderr" \
  | tee "$EV/pipeline-manifest.json"
```

**Assert on Mac:**
- Manifest `stage` reflects last completed stage (`pipeline` when using pipeline command)
- Chained translate: `translation` array populated when key available
- `outputs` lists written paths; re-recording same path replaces, does not duplicate (`CLIManifestTests.recordingTheSamePathReplacesRatherThanDuplicates`)
- JSON stdout slashes unescaped for jq (`CLIManifestTests.jsonOutputIsStableAndUnescaped`)

### Inspect manifest without binary (any platform)

Read tests and source:

```bash
# On Mac after a run:
jq '.stage, .outputs, (.transcript | length)' "$SCRATCH/clip.cue.json"
```

## Gotchas

- **Manifest detection:** Paths ending in `.cue.json` or `.json` load as manifest (`CLIManifest.looksLikeManifest`) — do not name media `something.json` unless intentional.
- **Translation settings on read:** `--to` on a later stage updates translation fields; transcription fields stay as recorded in manifest.
- **Re-transcribe invalidates translation:** New ASR run clears `translation` array in runner.
- **pipeline translate gate:** Runs translate when `--to` is set **or** `autoTranslateAfterTranscription` in Settings — may surprise agents expecting transcribe-only.
- **`--burn-in` at end of pipeline** needs ffmpeg (doctor warning if missing).
- **URL in pipeline:** Requires yt-dlp (doctor warning if missing); uses `MediaDownloadService`, not GUI download list.
