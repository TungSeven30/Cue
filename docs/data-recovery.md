# Data backup and recovery

## What is stored where

- Jobs: `~/Library/Application Support/Cue/jobs/<UUID>.json`
- Legacy/recovery job snapshots: `~/Library/Application Support/Cue/jobs*.json`
  and `*.corrupt.json`
- Watch history: `~/Library/Application Support/Cue/watch-ledger.json` plus a
  `.corrupt` preservation copy when decoding fails
- Verified GGML models: `~/Library/Application Support/Cue/models/`
- Extracted-audio cache: `~/Library/Caches/Cue/audio/` (rebuildable)
- Preferences/watch-folder profiles: macOS preferences for bundle
  `com.local.Cue`
- API keys: login Keychain generic-password items for service `com.local.Cue`

Source media and exported subtitle/video files remain wherever the user chose;
they are not copied into Cue's data directory.

## Backup

Quit Cue normally so debounced snapshots are flushed. Copy the entire
`~/Library/Application Support/Cue` directory to a dated backup while the app
is closed. Export preferences with
`defaults export com.local.Cue cue-preferences.plist`. Keychain items are not
included in that file; rely on the user's encrypted macOS/Time Machine backup
or re-enter provider keys after recovery. The caches directory can be omitted.

## Recovering job history

1. Quit Cue and make a second untouched copy of the current Cue data directory.
2. Inspect the in-app persistence error and the preserved `.corrupt.json` file;
   do not rename it over the original until its JSON has been validated.
3. Restore individual `<UUID>.json` files into the `jobs` directory while Cue
   is closed. Per-job files isolate recovery, so one damaged file need not
   replace healthy history.
4. Relaunch. Jobs that were running at the crash are intentionally marked
   canceled with partial segments retained; queue them again to resume work.

For a failed legacy migration, keep `jobs.json` in place. Cue retries the
migration and skips any newer per-job file with the same UUID, preventing an
old aggregate snapshot from clobbering recovered work.

## Watch folders and models

Restoring or deleting `watch-ledger.json` changes duplicate-ingest memory only;
it does not delete source files. Clearing it may queue every eligible file
again. Models may be restored from backup, but Cue revalidates their pinned
size/hash and replaces invalid bytes. The audio cache is always disposable.

## Validation after recovery

Open several recovered jobs, verify transcript and translation segment counts,
export a test subtitle, and confirm enabled watch folders point to mounted
paths before resuming the full queue. Keep the pre-recovery copy until that
validation succeeds.
