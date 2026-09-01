# fetch (URL input)

Download media from an http(s) page via yt-dlp before transcribe/pipeline stages.

## Sub-features

- **fetch command:** `./script/cue fetch <url>` — writes/updates manifest with local `source.path`
- **Implicit fetch:** Any stage accepting `<input>` treats http(s) URLs as fetch-first (`CLIRunner.loadInput`)
- **URL normalization:** trims, adds https to bare hosts (`MediaDownloadService.normalizedWebURL`)
- **Staging:** `--output-dir` or Settings download directory
- **Progress:** `[fetch] NNN% detail` on stderr
- **Doctor:** yt-dlp probe id `yt-dlp` — always **optional** (warning if missing, never fails doctor for built-in backend)

## How to get to it (user POV)

User pastes a YouTube/page URL via "Add from URL" in the GUI. CLI equivalent:

```bash
./script/cue fetch "https://www.youtube.com/watch?v=…" --output-dir ~/Downloads
./script/cue pipeline "https://youtu.be/abc123" --to English --json
```

## Driving it with ./script/cue

**Prerequisites:** `doctor --json` shows yt-dlp row `state: passed`. If `warning`, skip live fetch and note in evidence.

```bash
SCRATCH="$(./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh fetch)"
EV="$(dirname "$SCRATCH")/evidence"
mkdir -p "$EV" "$SCRATCH"

URL="https://www.youtube.com/watch?v=dQw4w9WgXcQ"   # short, public test URL

./script/cue fetch "$URL" \
  --output-dir "$SCRATCH" \
  --json 2>"$EV/fetch.stderr" \
  | tee "$EV/fetch-manifest.json"
echo "fetch exit=$?" >> "$EV/commands.log"
```

**Assert on Mac (when yt-dlp present):**
- Exit **0**
- Manifest `stage` is `fetch`; `source.pageURL` matches URL
- `source.path` points to downloaded media inside `$SCRATCH`
- stderr shows yt-dlp progress lines

**Skip path (no yt-dlp):**

```bash
jq '.[] | select(.id=="yt-dlp") | .state' "$EV/doctor.json"
# "warning" → document: "fetch skipped; yt-dlp not installed"
```

**Unit-level confidence without network** (via tests):

```bash
./script/run_tests.sh
# MediaDownloadServiceTests: URL parsing, yt-dlp argument shape, progress parsing
```

## Gotchas

- **Not required for doctor:** Missing yt-dlp never fails doctor when using built-in ASR (`EnvironmentDiagnosticsTests`).
- **Network + ToS:** Fetch hits real hosts; use short public URLs in scratch dirs only.
- **Playlist URLs:** yt-dlp invoked with `--no-playlist` — one video per job.
- **Local paths rejected as URLs:** `/Users/me/clip.mkv` is a file path, not fetch (`MediaDownloadServiceTests.rejectsAnythingThatIsNotAWebAddress`).
- **fetch without URL:** `fetch needs an http(s) URL` → exit **1** or **2** depending on error class.
- **GUI download list:** Concurrent URL ingests in `AppModel.downloads` are out of band — CLI fetch is synchronous in one process.
