# doctor / help / version

Agent-friendly introspection and environment diagnostics. Zero media required.

## Sub-features

- **help** — full usage text (`CueCommandLine.usageText`); lists every command and option
- **version** — `Cue <CFBundleShortVersionString> (<CFBundleVersion>)`
- **doctor** — probes ffmpeg, yt-dlp, python3, optional Python ASR backends, translation key presence
- **doctor --json** — same rows as JSON array (`EnvironmentDiagnostic`: `id`, `title`, `detail`, `recovery`, `state`, optional `repairCommand`)
- **Argument parse errors** — unknown options, missing values → exit **2** + usage on stderr
- **Aliases** — `--help`/`-h`, `--version`/`-v` as first token

## How to get to it (user POV)

From Terminal (or an agent shell on macOS):

```bash
./script/cue help
./script/cue version
./script/cue doctor
./script/cue doctor --json
```

In the GUI, similar diagnostics appear in Settings/status UI — this skill uses the CLI only.

## Driving it with ./script/cue

```bash
EVIDENCE_ROOT="$(./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh doctor-smoke)"
EV="$EVIDENCE_ROOT/../evidence"
mkdir -p "$EV"

# 1. Help — stdout only, exit 0
./script/cue help | tee "$EV/help.txt"
echo "help exit=$?" >> "$EV/commands.log"

# 2. Version
./script/cue version | tee "$EV/version.txt"
echo "version exit=$?" >> "$EV/commands.log"

# 3. Doctor JSON — jq-friendly stdout; progress-free
./script/cue doctor --json 2>"$EV/doctor.stderr" | tee "$EV/doctor.json"
echo "doctor exit=$?" >> "$EV/commands.log"

# 4. Bad invocation — exit 2
./script/cue transcribe 2>"$EV/bad-invoke.stderr" || true
echo "transcribe-no-input exit=$?" >> "$EV/commands.log"

# 5. Unknown option — exit 2
./script/cue transcribe clip.mkv --not-a-flag 2>"$EV/unknown-opt.stderr" || true
echo "unknown-opt exit=$?" >> "$EV/commands.log"
```

**Assert on Mac:**
- `help.txt` contains every `CLICommand` raw value (pinned by `CLIArgumentsTests.usageTextDocumentsEveryCommand`)
- `doctor.json` is valid JSON array; first row id is `built-in-engine`, state `passed`
- Failed doctor exit is **1** only when a **required** probe fails (selected Python backend missing its module)
- Warnings (yt-dlp missing, no OpenAI key) still exit **0**

**Usage text excerpt** (from `CueCommandLine.usageText` — verify in repo if binary unavailable):

```
Cue — transcribe, translate, and export subtitles without the GUI.

USAGE
  Cue <command> <input> [options]

COMMANDS
  fetch <url>          Download a video page with yt-dlp.
  transcribe <input>   Transcribe media on-device.
  translate <input>    Translate an existing transcript.
  summarize <input>    Write the spoiler-free intro cue.
  burn-in <input>      Render subtitles into the video.
  pipeline <input>     fetch → transcribe → translate → summarize → export.
  doctor               Report engine and tool availability.
  help, version
```

## Gotchas

- **No binary:** `./script/cue` exits **2** with "no Cue build found" — build with `./script/build_and_run.sh --bundle` first.
- **Doctor vs translate:** Missing cloud API key is a **warning**, not failure. Translate stage still fails at runtime with exit **1** if you attempt it without a key.
- **Selected backend matters:** With built-in whisper.cpp (default), Python backend probes are warnings only. Explicit `--backend mlx-whisper` in Settings makes mlx-whisper **required** (failure → doctor exit 1).
- **GUI tokens are not CLI:** `-psn_0_*` and `-NSDocumentRevisionsDebugMode` parse as `nil` command — app opens GUI instead (`CLIArgumentsTests.nonCommandArgumentsAreNotACLIInvocation`).
- **`--help` on a stage command** prints usage and exits 0 without running the stage (`CueCommandLine.execute`).
- **Never log keys:** Doctor reports "API key is configured" or not — never print Keychain values.
