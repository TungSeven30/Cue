# translate

Translate an existing transcript from manifest, media chain, or `.srt`/`.vtt` input.

## Sub-features

- **Input:** `.cue.json` manifest (preferred), `.srt`/`.vtt` (read as transcript), or media (after transcribe in same invocation)
- **Target language:** `--to LANG` (required unless Settings default applies)
- **Source override:** `--from LANG`
- **Models:** `--translation-model` or `--model` on translate command
- **Parallelism:** `--parallelism N` (1–4)
- **Bilingual export:** `--bilingual` writes translated + stacked bilingual sidecars
- **Output:** updates manifest `translation`, writes subtitle files, refreshes `.cue.json`
- **Credentials:** Keychain via `AppSettingsStore`; local models via `--translation-model local/...`

## How to get to it (user POV)

User transcribes in the app, then enables translation to a target language. CLI:

```bash
./script/cue translate clip.cue.json --to Vietnamese --bilingual --json
```

## Driving it with ./script/cue

### Pre-check (always)

```bash
./script/cue doctor --json | jq '.[] | select(.id=="translation-key")'
```

| doctor state | Action |
|--------------|--------|
| `passed` | Run live translate |
| `warning` (no cloud key) | **Skip live translate** — record skip reason; optionally test with `--translation-model local/<model>` if local server configured |
| `passed` + local provider | Run translate without API key |

### Live translate (when key or local server available)

```bash
SCRATCH="$(./.cursor/skills/verify-cue/helpers/new-scratch-dir.sh translate)"
EV="$(dirname "$SCRATCH")/evidence"
mkdir -p "$EV" "$SCRATCH"

# Requires prior transcribe manifest in scratch
MANIFEST="$SCRATCH/clip.cue.json"

./script/cue translate "$MANIFEST" \
  --to English \
  --output-dir "$SCRATCH" \
  --json 2>"$EV/translate.stderr" \
  | tee "$EV/translate-manifest.json"
echo "translate exit=$?" >> "$EV/commands.log"
```

**Assert on Mac:**
- Exit **0** when credentials present
- Manifest `translation` count matches `transcript` count
- `outputs` includes role `translated`
- stderr `[translate]` progress unless `--quiet`

### Observe skip (no key)

```bash
./script/cue translate "$MANIFEST" --to English --json 2>&1 | tee "$EV/translate-no-key.stderr"
# Expect exit 1, stderr contains:
# "No <Provider> API key. Add one in Cue's Settings, or pass --translation-model local/<model>."
```

Never copy API keys into evidence files.

### From SRT only

```bash
./script/cue translate "$SCRATCH/existing.srt" --to French --output-dir "$SCRATCH" --json
```

Manifest stage `read` then `translate`.

## Gotchas

- **Empty transcript:** Exit **1** — `Nothing to translate — run cue transcribe first, or pass an .srt file.`
- **Keys in Keychain only:** Never `--api-key` flags; never log `translationAPIKey` values.
- **Doctor warning ≠ translate success:** Doctor exits 0 with key warning; translate still fails until key added.
- **Cloud providers:** OpenAI, Groq, etc. — doctor row id `translation-key` reflects configured provider from Settings.
- **Local provider:** Doctor passes with empty key (`EnvironmentDiagnosticsTests.translationKeyRowPassesForLocalProvider`).
- **Progressive translation:** GUI uses `ProgressiveTranslationDriver` during streaming ASR; CLI waits for full transcript before translate.
- **Re-transcribe clears translation** in manifest when chaining — re-run translate after new ASR.
