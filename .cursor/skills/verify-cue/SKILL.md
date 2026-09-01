---
name: verify-cue
description: >-
  Verify Cue (native macOS 14+ Apple Silicon subtitle studio) via its headless CLI
  harness. Use when launching, doctoring, driving, or capturing evidence for CLI
  commands (help, version, doctor, transcribe, translate, fetch, pipeline) —
  not for SwiftUI/GUI flows (watch folders, job queue UI; Nori owns those).
---

# verify-cue

Cue ships one macOS binary that is both the GUI app and a headless CLI. The CLI runs before any SwiftUI window, never constructs `AppModel`, and has no queue, job persistence, or notifications. Verification agents drive `./script/cue` (dev) or `/Applications/Cue.app/Contents/MacOS/Cue` (installed).

**Platform:** macOS 14+, Apple Silicon. This skill documents Mac-native commands only. Linux cloud VMs cannot compile or run the binary — inspect sources and tests there, then hand off to a Mac worker to close the loop.

**Sources:** `Sources/CLI/` (`CueCommandLine.swift`, `CLIArguments.swift`, `CLIRunner.swift`, `CLIManifest.swift`, `CLIConsole.swift`).

## Launch

Resolve the binary (first match wins):

```bash
# Dev checkout — preferred during development
./script/cue <command> [args]

# Installed app
/Applications/Cue.app/Contents/MacOS/Cue <command> [args]
# or ~/Applications/Cue.app/Contents/MacOS/Cue

# Build without launching GUI (writes dist/Cue.app)
./script/build_and_run.sh --bundle

# Build and launch GUI (not needed for CLI verification)
./script/build_and_run.sh
```

`script/cue` searches, in order: `dist/Cue.app`, `/Applications/Cue.app`, `~/Applications/Cue.app`. If none exist, it exits **2** with install hints.

**GUI fall-through:** Arguments whose first token is not a known CLI command launch the GUI (Finder `-psn_…`, Xcode debug flags). Do not treat those as CLI failures.

**Known commands:** `fetch`, `transcribe`, `translate`, `summarize`, `burn-in`, `pipeline`, `doctor`, `help`, `version` (aliases: `--help`/`-h`, `--version`/`-v`).

## Doctor

Run environment diagnostics before expensive stages:

```bash
./script/cue doctor
./script/cue doctor --json | jq .
```

**Exit codes (doctor):**
- **0** — no row with `state: failed` (warnings are OK)
- **1** — at least one **failed** row (selected backend cannot run)

**Diagnostic semantics** (`EnvironmentDiagnosticsService`):
- **passed** — ready
- **warning** — optional extra missing (yt-dlp, ffmpeg, Python backends, cloud translation API key)
- **failed** — required for the **selected** Settings backend (e.g. mlx-whisper when that backend is chosen)

Built-in whisper.cpp always passes. yt-dlp is **never required** — only warns when missing (needed for `fetch` / URL inputs). Translation API key warns for cloud providers; local translation passes without a key.

**Cheap doctor path (always run first on Mac):**
1. `./script/cue help` → exit 0, usage on stdout
2. `./script/cue version` → exit 0, `Cue <semver> (<build>)`
3. `./script/cue doctor --json` → parse JSON array of diagnostics
4. `./script/cue transcribe` (no input) → exit **2**, usage error on stderr

## Drive

Drive the **cheapest real path first**, then feature-specific flows in `features/`.

### Isolation

Never write into the user's Movies folder, real watch folders, or `~/Library/Application Support/Cue/jobs/`.

```bash
SCRATCH="$(./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh)"
EVIDENCE="$(dirname "$SCRATCH")"   # .cue-verify-evidence/<run-id>/
```

Pass `--output-dir "$SCRATCH"` on every stage that writes files. Use a tiny local media fixture you copy into `$SCRATCH` (do not commit large binaries). Kill only Cue processes **you** started.

### stdout / stderr contract

- **stdout:** result only — manifest JSON with `--json`, help/version text, doctor JSON, or output file paths (plain mode)
- **stderr:** progress (`[stage] NNN% detail`), `[write] path` notes, `error: …` failures
- With `--json`, pipe stdout to `jq`; keep stderr visible for progress

### Exit codes (all commands)

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Ran and failed (stage error, doctor failed probe) |
| 2 | Bad invocation (parse error, missing input, unknown option, no binary) |
| 130 | Canceled |

### Recommended drive order

1. **Introspection** — `help`, `version`, `doctor --json` (see [features/doctor-help-version.md](features/doctor-help-version.md))
2. **Parse failures** — missing input, unknown `--format`, exit 2
3. **Transcribe** — tiny fixture, `--output-dir`, `--json` (see [features/transcribe.md](features/transcribe.md))
4. **Pipeline / chain** — pass `.cue.json` to next stage (see [features/pipeline.md](features/pipeline.md))
5. **Fetch** — only if doctor shows yt-dlp passed (see [features/fetch.md](features/fetch.md))
6. **Translate** — only if Keychain has a key or local model; skip live translate otherwise (see [features/translate.md](features/translate.md))

### Tests (regression, not runtime proof)

Always use the project test script — **never** plain `swift test` on CLT-only Macs (runs zero tests silently):

```bash
./script/run_tests.sh
```

Relevant CLI tests: `Tests/CueTests/CLIArgumentsTests.swift`, `CLIManifestTests.swift`, `EnvironmentDiagnosticsTests.swift`. GUI/queue surfaces: `WatchFolderTests.swift`, `WatchFolderCoordinatorTests.swift`, `MediaDownloadServiceTests.swift` (out of band for this skill).

## Evidence

Collect artifacts under **`.cue-verify-evidence/<run-id>/`** (repo root, gitignored in practice):

```
.cue-verify-evidence/<run-id>/
  scratch/          # --output-dir contents (safe to delete on cleanup)
  evidence/         # KEEP — copies of manifests, jq output, doctor JSON, logs
    doctor.json
    help.txt
    version.txt
    transcribe-manifest.json
    commands.log      # exact commands + exit codes
```

After each command:

```bash
mkdir -p "$EVIDENCE/evidence"
./script/cue doctor --json 2>"$EVIDENCE/evidence/doctor.stderr" \
  | tee "$EVIDENCE/evidence/doctor.json"
echo "exit=$?" >> "$EVIDENCE/evidence/commands.log"
```

**Never** commit API keys. Redact Keychain-backed settings in notes; doctor only reports whether a key *exists*, never its value.

## Cleanup

```bash
# Remove scratch media/output only — NOT evidence/
rm -rf "$EVIDENCE/scratch"

# Kill only processes you started (if a transcribe is still running)
pkill -f "Contents/MacOS/Cue transcribe" 2>/dev/null || true
```

Do **not** delete `.cue-verify-evidence/<run-id>/evidence/` — that is the proof bundle. Do not touch `~/Library/Application Support/Cue/`.

## Helpers

| Helper | Purpose |
|--------|---------|
| `./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh [run-id]` | Creates `.cue-verify-evidence/<run-id>/scratch`, prints path |
| `./script/cue` | Resolves dev/installed binary |
| `./script/run_tests.sh` | Full test suite (Python parity + Swift) |
| `./script/build_and_run.sh --bundle` | Produce `dist/Cue.app` for CLI runs |

Override evidence root: `CUE_VERIFY_EVIDENCE_ROOT=/tmp/my-run ./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh`

## Out of band (mention only)

These are real product surfaces but **not** driven by this skill:

- **Watch folders** — `WatchFolderService` / `AppModel` (SwiftUI + persistence)
- **URL ingest UI** — `MediaDownloadService` via GUI downloads list
- **Job queue** — `AppModel`, `PipelineCoordinator`, `JobStore`

CLI `fetch` and `pipeline` with an https URL cover URL ingest headlessly; the GUI queue is Nori's lane.

## Feature map

See [features/README.md](features/README.md) for per-command driving instructions.
