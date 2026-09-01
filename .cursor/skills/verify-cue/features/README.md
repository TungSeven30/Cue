# Cue CLI feature map

Headless verification covers the commands below. Each file documents sub-features, user POV, CLI driving steps, and gotchas.

| Feature | File | Harness |
|---------|------|---------|
| doctor / help / version | [doctor-help-version.md](doctor-help-version.md) | `./script/cue` |
| transcribe | [transcribe.md](transcribe.md) | `./script/cue transcribe` |
| pipeline + manifest chaining | [pipeline.md](pipeline.md) | `./script/cue pipeline`, `.cue.json` |
| fetch (yt-dlp) | [fetch.md](fetch.md) | `./script/cue fetch` |
| translate | [translate.md](translate.md) | `./script/cue translate` |

## Commands not yet mapped

These exist in the CLI but are lower priority for first-pass verification:

- `summarize` — intro cue generation (needs transcript + LLM credentials)
- `burn-in` — ffmpeg render (doctor should show ffmpeg availability)

Add feature files when an agent needs repeatable drive recipes for them.

## Out of band (GUI / AppModel)

| Surface | Owner | Why out of band |
|---------|-------|-----------------|
| Watch folder ingest | Nori / SwiftUI | Polling ledger + `AppModel` queue semantics |
| Add from URL (GUI) | Nori | Same yt-dlp backend as `fetch`, but download state lives in `AppModel.downloads` |
| Job queue, presets UI | Nori | `AppModel`, persistence under `~/Library/Application Support/Cue/jobs/` |

Mention these when explaining product scope; do not drive them from this skill.
