# Subtitle import: adopt existing sidecars, load from anywhere

Date: 2026-08-15

## Problem

Cue writes SRT sidecars next to the source media (`movie.ja.srt`, `movie.vi.srt`,
`movie.bilingual.srt`) whenever a job finishes, but it cannot read them back. Adding a
video that already has subtitles — Cue's own output from a previous run, or a file that
shipped with the media — starts from zero: a full ASR pass to reproduce a transcript
that is already sitting in the same folder.

The user wants an existing subtitle recognized and loaded on add, plus a way to load a
subtitle from a different folder, so it can be edited or burned in without
re-transcribing.

## Decisions

| Question | Decision |
| --- | --- |
| What does a detected subtitle become? | Auto-loaded into the job's transcript slot |
| Multiple matches in one folder? | Route by language code; fill transcript and translation slots |
| Queue behavior for an adopted job? | Skip ASR; queue for translation if configured |
| Where do edits go? | Written back to the imported file automatically (debounced) |
| Loading from another folder? | Menu command + file picker + slot picker |

Auto write-back was chosen against the recommendation in brainstorming. It is
implemented with a debounce, an atomic write, a one-time backup, and an
external-change guard (see *Write-back* below); those safeguards are load-bearing, not
polish.

## Architecture

Three new pure units plus one new `AppModel` section. No existing component is
restructured. `BurnInService`, `ExportCoordinator`'s planning, `TranscriptView`, and the
export sheet require no changes at all — they read `transcriptSegments` and
`translatedSegments`, which is precisely why imported subtitles land in those arrays
rather than in a separate track.

### `SubtitleReader` (`Sources/Services/SubtitleReader.swift`)

Parse-only counterpart to `SubtitleWriter`; an `enum` with static functions, no state.

```swift
enum SubtitleReader {
    enum Error: Swift.Error { case unreadable, unsupportedFormat, noCues, tooLarge }
    static func parse(contentsOf url: URL) throws -> [TranscriptionSegment]
    static func parse(_ text: String, format: SubtitleExportFormat) throws -> [TranscriptionSegment]
}
```

- Formats: SRT and WebVTT, chosen by file extension.
- Decoding order: UTF-8, then UTF-16 when a BOM is present, then Windows-1252. Older
  SRT files are frequently Latin-1 and would otherwise fail outright. A leading BOM is
  stripped.
- Block parsing is tolerant: an optional index line, a timestamp line, then text lines
  until a blank line. Timestamps accept `,` or `.` as the decimal separator, tolerate a
  missing hours field (`MM:SS.mmm`), and ignore trailing WebVTT cue settings on the
  timestamp line. VTT `WEBVTT`, `NOTE`, `STYLE`, and `REGION` blocks are skipped.
- A malformed block is skipped, not fatal — real-world files carry junk tails. `noCues`
  is thrown only when nothing at all parsed.
- Cue ids are **renumbered `1...n`; the file's own indices are discarded.**
  `TranscriptionSegment.id` doubles as the join key for
  `ExportCoordinator.bilingualSegments` and translation reconciliation, and third-party
  SRT files routinely have duplicate, missing, or non-monotonic indices. Importing
  those verbatim would silently break bilingual export and progressive translation
  matching.
- Text runs through the existing `SubtitleWriter.sanitizedCueText`. `end` is clamped to
  `max(end, start)`.
- Inline markup (`<i>`, `{\an8}`) is preserved verbatim. ffmpeg's `subtitles` filter
  renders it, so stripping it would lose formatting on burn-in.
- Files over 20 MB throw `tooLarge`, so a mislabeled file cannot be read into memory.

### `SubtitleSidecarScanner` (`Sources/Models/SubtitleSidecarScanner.swift`)

Pure routing over a directory listing, testable without the filesystem in the same
style as `WatchFolderScanEngine`.

```swift
struct SubtitleSidecarScanner {
    struct Match { let url: URL; let slot: Slot }
    enum Slot { case transcript, translation }
    static func match(
        mediaURL: URL,
        candidates: [URL],
        sourceLanguage: String,
        translationTargetLanguage: String
    ) -> [Match]
}
```

Candidate rules:

- Same directory as the media file.
- Extension `srt` or `vtt`, case-insensitive.
- Name is exactly `<base>.<ext>` or `<base>.<tag>.<ext>`, where `<base>` is the media
  file name without its extension, compared case-insensitively. No fuzzy matching —
  `movie (1).srt` is not a match for `movie.mp4`.
- `<base>.bilingual.<ext>` is always skipped. Its two-line cues would corrupt the
  transcript with interleaved translation text.

Routing:

- Language codes come from `ExportCoordinator.sidecarLanguageCode`, the same function
  that names Cue's own sidecars, so a round trip through export and re-import is exact.
- A tag matching the translation target language routes to the translation slot.
- No tag, the tag `original`, or a tag matching the source language routes to the
  transcript slot.
- Ties are broken deterministically: no tag, then `original`, then source-language
  code, then alphabetical.
- **A lone candidate always routes to the transcript slot, whatever its tag.** A
  translation with no transcript is a broken state in this codebase — bilingual export
  and `canTranslate` both require a transcript — so the scanner cannot produce it.

### Job model (`Sources/Models/TranscriptionJob.swift`)

```swift
struct ImportedSubtitleSource: Codable, Hashable {
    var path: String
    var importedAt: Date
    var format: SubtitleExportFormat
    var fileSize: Int
    var modifiedAt: Date
    var didBackup: Bool
}

var importedTranscriptSource: ImportedSubtitleSource?
var importedTranslationSource: ImportedSubtitleSource?
```

Both decode with `decodeIfPresent` defaulting to `nil`, matching how every other added
field migrates in this file. `fileSize`/`modifiedAt` capture the file's state at import
for the external-change guard; `didBackup` records that the one-time `.bak` was already
taken, so it survives relaunch and never repeats. `format` is only ever `.srt` or
`.vtt` — the other `SubtitleExportFormat` cases are export-only and never produced by
the reader.

These fields are deliberately **not** part of `TranscriptionIdentity` — they describe
where a transcript came from, not what would produce it.

## Data flow

### Adoption on add

One `AppModel` helper serves both entry points:

```swift
private func adoptSidecars(for ids: [UUID])
```

Called from `addVideos(urls:)` and `ingestWatchFolderFiles(_:folderID:)`.

1. Jobs are inserted into the sidebar immediately, as today. A 200-file batch must not
   block on disk I/O.
2. Scanning (directory listing) and parsing run off the main actor in a `Task`, with
   results applied back through `updateJob`.
3. Adopted jobs get `status = .transcriptionComplete`, populated segments, provenance
   records, and a log line: `Loaded subtitles from movie.en.srt (412 cues).`
4. `transcriptionFinishedAt` stays `nil` — nothing was transcribed, and the timing and
   ETA code already treat it as optional.

**Race with auto-start.** `addVideos` calls `processQueue()` immediately when
`autoStartAddedJobs` is on, which would start ASR before adoption lands. `AppModel`
keeps transient, non-persisted state:

```swift
private var subtitleScanPendingIDs: Set<UUID> = []
```

Two call sites must respect it, because scheduling does not go through a single
predicate:

- `jobViews` (AppModel.swift:881) filters out pending ids alongside its existing
  `archivedAt == nil` filter. This is the one that matters: `pumpGPU` and
  `pumpTranslation` schedule via `PipelineScheduler.nextGPUJob(jobs: jobViews, …)`, so
  filtering `jobNeedsWork` alone would leave the race open.
- `jobNeedsWork` returns `false` for pending ids, so `hasPendingWork` and the
  "all queued jobs finished" notification do not fire while a scan is outstanding.

`processQueue()` is called once the scan settles. The set is in-memory only; a job whose
scan is interrupted by a quit is simply never adopted, which is safe.

### Queue behavior

An adopted job looks like a finished transcription to `jobNeedsWork` and
`PipelineScheduler`, which is the intent: ASR is skipped, and the job queues for
translation when translation is configured and its slot is empty.

### Re-transcription

`startTranscriptionNow` (AppModel.swift:1190) currently skips ASR when the transcript is
non-empty, the file fingerprint matches, and the settings identity matches. An imported
transcript satisfies all three by accident — its settings snapshot describes globals at
add time, not anything that produced those subtitles.

- The skip branch is bypassed when `importedTranscriptSource != nil`. Pressing
  Transcribe on an imported job means *actually run ASR*.
- A real run clears `importedTranscriptSource`, and the existing
  `translatedSegments = []` reset at line 1220 gains a matching
  `importedTranslationSource = nil` — otherwise write-back would keep syncing a file
  whose content no longer matches the job.

## UI

Auto-detection is silent. A batch add cannot raise dialogs; the job simply appears as
*Transcript ready*.

1. **Provenance chip** in the Transcript and Translation tabs:
   `Imported from movie.en.srt · Syncing`, with *Reveal in Finder* and *Unlink*.
   Unlink clears provenance and stops write-back. With automatic write-back enabled,
   this escape hatch is required, not optional.
2. **`Load Subtitles…`** in the File menu (`Sources/App/CueApp.swift` commands) and in
   the empty state of each tab, beside the existing Transcribe/Translate buttons.
3. **Slot picker sheet** after the file picker (`NSOpenPanel` filtered to `.srt`/`.vtt`):
   Transcript or Translation. Translation is disabled while the transcript slot is
   empty, enforcing the same invariant the scanner enforces, so translation-without-
   transcript is unreachable from either path. Replacing non-empty segments asks for
   confirmation first.
4. **Log line** on every import, as above.

## Write-back

A new `// MARK: - Imported subtitle sync` section in `AppModel`, driven by
`updateTranscriptSegment` and `updateTranslatedSegment` (AppModel.swift:1826) — the only
segment edit entry points. `TranscriptView`'s Replace All routes through them too.

- **Debounced 1.5 s**, coalesced per job and slot, so a Replace All firing 400 edits
  produces one write. Flushed from the existing `flushPendingWork()` (quit) and on job
  deselect.
- **Atomic**, reusing `SubtitleWriter.writeSRT`/`writeVTT`. The imported format is
  preserved: a `.vtt` import is written back as WebVTT.
- Written **without** the intro summary. `ExportCoordinator.applyingIntro` stays
  export-only, so the file mirrors exactly what the editor shows.
- **One-time `.bak`** of the original, when no `.bak` already exists; recorded via
  `didBackup`. Auto-adoption takes it at import time, because a re-translation can
  unlink the file before any edit is ever made. A manual Load Subtitles… takes it when
  the slot picker commits instead, so cancelling the picker leaves nothing behind.
  Write-back takes it before the first write if neither has (`didBackup == false`,
  e.g. the folder was read-only earlier).
- **External-change guard.** Before writing, the file's current size and modification
  date are compared against the values recorded at import. On mismatch the write is
  skipped, sync pauses, and the job log records
  `Subtitle file changed outside Cue; sync paused.` Without this, editing the file in
  another application and then touching any segment in Cue would silently destroy the
  external edits.
- **Overwrite guard.** `autoExportSidecars` skips any document whose destination path
  equals an imported source path (standardized comparison). Otherwise a finished
  translation would rewrite the imported file *with the intro summary prepended*,
  silently modifying a user's file.

## Error handling

| Situation | Behavior |
| --- | --- |
| Unparseable file during auto-detect | Skipped; one line in the job log. No dialog. |
| Unparseable file during manual load | Alert — the user explicitly asked for this file. |
| Write-back to an offline volume or read-only file | Job log entry plus an error state on the provenance chip. Provenance is kept and retried on the next edit, never silently unlinked. |
| External change detected | Sync pauses with a log line; the user can Unlink or re-import. |

## Testing

swift-testing, run via `script/run_tests.sh`.

**`SubtitleReaderTests`**
- `,` and `.` decimal separators; missing hours field.
- UTF-8, UTF-16 with BOM, Windows-1252 decoding.
- Duplicate and non-monotonic source indices are renumbered `1...n`.
- A malformed block mid-file is skipped and the rest still parses.
- An empty or cue-less file throws `noCues`.
- `-->` appearing inside cue text does not split the cue.
- Files over the size cap throw `tooLarge`.

**`SubtitleSidecarScannerTests`**
- A lone match routes to the transcript slot regardless of its tag.
- `movie.ja.srt` + `movie.vi.srt` with a Vietnamese target fills both slots correctly.
- `movie.bilingual.srt` is never matched.
- Near-miss base names (`movie (1).srt`, `movie2.srt`) are ignored.
- Uppercase `.SRT` is matched.
- Tie-break order holds when several transcript-eligible candidates exist.

**`AppModelSubtitleImportTests`**
- Adoption sets status, segments, and provenance.
- A pending scan keeps the job out of scheduling: with `autoStartAddedJobs` on, adding a
  file that has a sidecar does not begin ASR before adoption lands, and `jobNeedsWork`
  returns `false` for the pending job.
- Transcribe on an imported job bypasses the skip branch and clears both provenance
  fields.
- `autoExportSidecars` skips a destination matching an imported source path.
- N segment edits produce exactly one write-back.
- A size/mtime mismatch pauses sync without writing.

**Round-trip parity**
- `SubtitleWriter.writeSRT` → `SubtitleReader.parse` returns segments identical to the
  input, for both SRT and VTT. This guards both sides against future drift, the same
  tactic the repo already uses for the generated Python backend script.

Coverage floors are enforced by `script/run_coverage.sh`; the new files are covered by
the suites above.

## Out of scope

- ASS/SSA subtitle formats.
- Fuzzy or scored filename matching beyond the exact `<base>[.tag]` rule.
- Editing cue timings (the editor edits text only today; unchanged here).
- Re-scanning a folder for subtitles that appear *after* a job was added.
