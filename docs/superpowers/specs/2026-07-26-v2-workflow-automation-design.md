# v2 Workflow Automation — Design

**Date:** 2026-07-26
**Branch:** `v2-workflow`, cut from master `fdefa3e`
**Status:** Implemented on v2-workflow

## Goal

Three capabilities that turn WhisperDesk from a file-at-a-time tool into something
that runs unattended and can be steered:

1. **Watch folder** — drop files in a designated folder and wake up to translated
   sidecars beside them.
2. **Burn-in export** — an ffmpeg-rendered MP4 with subtitles baked into the
   picture, for players and devices that ignore sidecars.
3. **Queue upgrades** — drag-reorder the queue, and give any single job its own
   settings without disturbing the global defaults.

The three share one prerequisite: a job must be able to run on settings that are
not the live global settings. That refactor is Phase 0.

## Decisions taken

| Decision | Choice | Reason |
| --- | --- | --- |
| Branch base | master | Queue/export work is largely disjoint from the in-flight `v2-zero-dependency` (PR #2); neither branch blocks the other. |
| Burn-in renderer | ffmpeg, feature-gated | libass handles styling, CJK fonts, and MKV. Burn-in is an opt-in power feature, so it does not compromise the zero-dependency default path. |
| Override scope | Curated subset of five fields | Covers the real cases without rebuilding the Settings window inside an inspector. |
| Watch-folder file lifecycle | Leave files in place, track a ledger | Never move files the user owns. |
| Watch-folder settings | Per-folder profile | An inbox can differ from interactive defaults, and changing globals mid-run cannot corrupt an overnight batch. |

Work happens in a git worktree at
`~/.config/superpowers/worktrees/whisper/v2-workflow`, because another session is
actively committing to `v2-zero-dependency` in the primary checkout.

---

## Phase 0 — Backbone: effective settings

Today `AppModel.startTranscriptionNow` passes the live `AppSettingsStore` to the
services and stamps a `JobSettingsSnapshot` onto the job afterwards. A job
therefore always runs on whatever the globals happen to say at that moment.
Per-job overrides and per-folder profiles both require the opposite.

### 0.1 Extract preset tables into pure values

`AppSettingsStore.applyQualityPreset()` (`Sources/Models/AppSettingsStore.swift:494`)
applies a preset by mutating eleven published properties. Resolution cannot use
it without mutating globals.

```swift
struct TranscriptionQualityParameters: Hashable {
    var preprocessAudio: Bool
    var vadFilter: Bool
    var removeEmptySegments: Bool
    var removeRepeatedText: Bool
    var mergeShortSegments: Bool
    var minSegmentDuration: Double
    var maxMergeGap: Double
    var beamSize: Int
    var bestOf: Int
    var temperature: Double
    var noSpeechThreshold: Double
}

extension TranscriptionQualityPreset {
    /// `nil` for `.custom`, which means "whatever the individual fields say".
    var parameters: TranscriptionQualityParameters? { ... }
}
```

`applyQualityPreset()` becomes an assignment from `parameters`. Behaviour is
unchanged; the values become testable.

`TranscriptionPreset.backend` and `.model` are already pure properties and need
no change.

### 0.2 The override set

```swift
struct JobSettingsOverrides: Codable, Hashable {
    var sourceLanguage: String?
    var transcriptionPreset: TranscriptionPreset?
    var transcriptionQualityPreset: TranscriptionQualityPreset?
    var translationTargetLanguage: String?
    var autoTranslate: Bool?

    var isEmpty: Bool  // all fields nil
}
```

`nil` means inherit. `TranscriptionPreset.custom` is never offered in the
override picker: "custom" means "read the global decoding fields", which is
identical to inheriting.

### 0.3 Resolution

```swift
extension JobSettingsSnapshot {
    @MainActor
    init(settings: AppSettingsStore, overrides: JobSettingsOverrides)
}
```

Layering rules:

- `sourceLanguage`, `translationTargetLanguage` — override wins, else global.
- `transcriptionPreset` — when overridden, its `backend` and `model` populate
  `whisperBackend` and `whisperModel`; otherwise both are inherited directly.
- `transcriptionQualityPreset` — when overridden, its `parameters` populate the
  eleven decoding fields; otherwise all eleven are inherited.
- Everything else in the snapshot is inherited unchanged.

`autoTranslate` is not part of the snapshot. It is resolved separately at the
point `AppModel` decides whether to chain a translation
(`overrides.autoTranslate ?? settings.autoTranslateAfterTranscription`).

### 0.4 Service signatures

Verified against current usage — `TranscriptionService` reads only the fourteen
fields already present in `JobSettingsSnapshot`; `TranslationService` reads five
snapshot fields plus `translationPrompt` and `translationAPIKey`. The full
contract is therefore the snapshot plus a small credentials value:

```swift
struct TranslationCredentials {
    let apiKey: String
    let prompt: String
    let provider: TranslationProvider
}
```

Credentials travel separately so secrets never enter the persisted snapshot.

New signatures:

```swift
func transcribe(videoURL: URL,
                settings: JobSettingsSnapshot,
                progress: @escaping @MainActor (JobProgress) -> Void) async throws -> TranscriptionResult

func translate(segments: [TranscriptionSegment],
               sourceLanguage: String,
               settings: JobSettingsSnapshot,
               credentials: TranslationCredentials,
               existingTranslations: [TranscriptionSegment],
               progress: @escaping @MainActor (JobProgress) -> Void,
               onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void) async throws -> [TranscriptionSegment]

func summarize(segments: [TranscriptionSegment],
               language: String,
               settings: JobSettingsSnapshot,
               credentials: TranslationCredentials) async throws -> String
```

This is the largest diff on the branch. It is mechanical, but it touches every
service call site in `AppModel`.

### 0.5 Job model

```swift
var overrides: JobSettingsOverrides   // input: what you want this job to do
var settings: JobSettingsSnapshot     // record: what the last run actually used
var orderIndex: Double                // queue position
var origin: JobOrigin                 // .manual | .watchFolder
```

`settings` keeps its current meaning and is written only after resolution.
All new fields decode with `decodeIfPresent` and safe defaults, matching the
existing migration style:

- `overrides` → `JobSettingsOverrides()`
- `origin` → `.manual`
- `orderIndex` → `-createdAt.timeIntervalSince1970`, which approximates today's
  newest-first ordering for existing jobs (the old sort keyed on `updatedAt`;
  creation order is the stable choice, since `updatedAt` churns on every edit).

### 0.6 Skip-if-unchanged

`AppModel.swift:380-398` currently compares eighteen fields of `job.settings`
against the globals by hand. It becomes: resolve the effective snapshot, then
compare its transcription-relevant fields against `job.settings`.

```swift
extension JobSettingsSnapshot {
    /// Fields that change the transcript. Excludes translation and summary
    /// settings, which do not invalidate a transcript.
    var transcriptionIdentity: TranscriptionIdentity
}
```

`transcriptionIdentity` includes `transcriptionProcessingVersion`, so bumping
that value still invalidates every cached transcript.

---

## Phase 1 — Queue upgrades

### 1.1 Ordering

`jobs` is kept sorted by `orderIndex` ascending, both on load and after mutation.
`processQueue()` selects the lowest-`orderIndex` job with status `.queued`
instead of the first array element.

Index assignment:

- Manual add: `(jobs.map(\.orderIndex).min() ?? 0) - 1` — new files land on top,
  matching today's behaviour.
- Watch-folder ingest: `(jobs.map(\.orderIndex).max() ?? 0) + 1` — an overnight
  batch runs in arrival order and never jumps ahead of hand-queued work.
- Drag: midpoint of the two new neighbours; at the edges, `min - 1` or `max + 1`.
  Only the moved job is persisted, which matters because job storage is one file
  per job.
- Renormalization: when the gap between neighbours would fall below `1e-9`,
  rewrite all indices as `0, 1, 2, …` and persist every job once.

Reordering never affects the job that is already running; it only changes what
`processQueue()` picks next.

### 1.2 Per-job override UI

A "Job Settings…" sheet, reachable from the sidebar context menu and from the
detail header. Five controls, each offering "Inherit (*current global value*)" as
the first option so the effective value is always visible.

Disabled while that job is running. A sidebar badge marks any job where
`!overrides.isEmpty`, so a job that will behave differently looks different.

### 1.3 Queue affordances

Context menu gains Move to Top, Move to Bottom (dragging through a long list is
impractical), and Remove from Queue (`.queued` → `.idle`). No priority tiers, no
inter-job dependencies.

---

## Phase 2 — Watch folder

### 2.1 Configuration

Added to `AppSettingsStore`:

- `watchFolderEnabled: Bool` (default `false`)
- `watchFolderPath: String`
- `watchFolderProfile: JobSettingsOverrides`

The profile editor is the same five-field view built in Phase 1, reused verbatim.

The promise is *translated* sidecars, and translation needs an API key. When the
watch folder is enabled, the profile resolves to auto-translate, and no
translation API key is configured, the watch-folder Settings section shows an
inline warning ("files will be transcribed but not translated until an API key
is added"). Ingestion still proceeds — a transcript-only sidecar beats nothing —
but the shortfall is visible before bedtime, not discovered at breakfast.

### 2.2 Detection

`WatchFolderService` uses FSEvents as a hint and a directory scan as the source
of truth. `scan()` is triggered by:

- an `FSEventStream` on the folder (latency 1.0s, `.fileEvents`),
- a 60-second repeating timer,
- app launch and folder enablement,
- `NSWorkspace.didWakeNotification`.

`scan()` is idempotent and ledger-driven, so a duplicated event costs nothing and
a dropped event costs at most sixty seconds. The failure this design must not
have is sleeping through the night and missing a file, which pure FSEvents would
allow.

### 2.3 Scan rules

A file is ingested only if it passes every filter:

1. Extension is a known media type (list shared with drag-and-drop).
2. Not a dotfile; extension is not `part`, `download`, or `crdownload`.
3. Its fingerprint is absent from the ledger.
4. No existing job in the list has the same `sourceFingerprint`, **regardless of
   status**. Path-only or queued/running-only checks would both re-ingest a file
   whose job was canceled, or whose job was added manually (manual jobs never
   write the ledger), creating duplicates. A deliberate consequence: deleting a
   canceled watch job makes its file eligible again on the next scan —
   cancel-then-delete means "do it over".
5. **Stability gate:** size unchanged across two checks at least 2 seconds apart.
   Without this, a large file still being copied in is transcribed at whatever
   fraction of it has landed.

Survivors become `.queued` jobs with `overrides = watchFolderProfile`,
`origin = .watchFolder`, and `orderIndex = max + 1`, then `processQueue()` runs.
Ingest must **not** go through `AppModel.enqueueJob`, which clears `queuePaused`
as a side effect (`AppModel.swift:318`) — reusing it would silently violate the
paused-queue rule in 2.6. Ingest also ignores `autoStartAddedJobs`; that toggle
governs interactive adds, and a watch folder that only queues would defeat its
purpose.

### 2.4 Ledger

`WatchFolderLedger` persists `[fingerprint: Outcome]` as JSON in Application
Support, alongside job storage. Fingerprint is the existing
`TranscriptionJob.fingerprint` format (`path|size|mtime`).

- An entry is written when a **watch-origin** job reaches success or failure.
  Recording failures is deliberate: a file that reliably fails must not be
  retried every sixty seconds forever. Cancellation writes nothing — the
  still-listed canceled job blocks re-ingest via scan rule 4 instead, so
  deleting it is the "retry" gesture. Manual jobs never touch the ledger.
- Because the fingerprint includes size and mtime, replacing or re-encoding a
  file changes its fingerprint and legitimately re-runs it.
- Entries whose file no longer exists are pruned during `scan()`, keeping the
  ledger bounded.
- Settings gains a "Clear watch history" button for "just do all of it again".

### 2.5 Output

Sidecar export is implicit for `origin == .watchFolder` jobs, regardless of the
global `autoExportSidecar` toggle. The feature is definitionally "wake up to
sidecars", so a stale toggle must not silently produce nothing. Sidecars use the
existing `autoExportSidecars` path and land beside the source video.

### 2.6 Interaction with a paused queue

Watch-folder ingest does **not** clear `queuePaused`. Cancelling is an explicit
instruction to stop working, and a newly arrived file should not override it.
Ingested files are queued and logged, and the existing Resume Queue button
appears. The accepted cost: a queue paused at bedtime means no sidecars by
morning.

### 2.7 Keeping the machine awake

Unattended overnight processing fails silently if the Mac idle-sleeps mid-batch,
and App Nap can throttle the 60-second rescan timer while the app is in the
background. While any job is running (`activeJobID != nil`), `AppModel` holds a
`ProcessInfo.beginActivity` assertion with `[.userInitiated,
.idleSystemSleepDisabled]` and a reason string, ended when the queue drains.
Display sleep stays allowed — only system sleep is held off, and only while
there is actual work. A closed lid still sleeps the machine; that is macOS
policy, not ours, and the README should say "leave the lid open or connect a
display" for overnight runs.

This applies to all jobs, not just watch-origin ones — a hand-queued overnight
batch deserves the same guarantee.

---

## Phase 3 — Burn-in export

### 3.1 Preflight

Two checks, cached but refreshable — the current `ProcessEnvironment.hasFFmpeg`
is a `static let` computed once per launch, which cannot see an ffmpeg installed
five minutes ago in response to a disabled button:

1. `ffmpeg` is executable on the tool PATH.
2. `ffmpeg -filters` output contains `subtitles`. A minimal build without libass
   otherwise fails deep into an encode with an opaque error.

When either check fails, the burn-in action is disabled and offers
`brew install ffmpeg` with a Recheck button.

### 3.2 Command

```
ffmpeg -y -i <source> \
  -vf "subtitles=<tempdir>/subs.srt:force_style='<style from 3.3>'" \
  -c:v h264_videotoolbox -q:v 60 \
  -c:a aac -b:a 192k \
  -movflags +faststart \
  <output.mp4>
```

`-q:v 60` is VideoToolbox's 0–100 quality scale; 60 is a visually transparent
default for burned subtitles without bloating the file. It is a constant, not a
user setting.

**Path safety.** The `subtitles` filter requires `:`, `'`, `[`, `]`, and `,` to be
escaped, and media filenames routinely contain them. Rather than escape user
input, `SubtitleWriter` writes the chosen document to a fixed safe name
(`subs.srt`) inside a freshly created temporary directory, so no user-controlled
text ever enters the filter string. The temp directory is removed when the
operation ends, including on failure and cancellation.

Audio is always re-encoded to AAC rather than stream-copied. Copying is faster
and lossless, but fails for some source codecs in an MP4 container — and failing
forty minutes into an encode is worse than a small, predictable quality cost.

### 3.3 Content and styling

The subtitle document is one of original, translation, or bilingual, with the
intro summary applied by the existing `applyingIntro` path.

Styling is three presets — Small, Medium, Large — mapping to `FontSize` and
`MarginV` in the `force_style` string, always combined with a box background
(`BorderStyle=3`) for legibility over bright footage. Exact point sizes are an
implementation-plan detail; the spec-level requirement is three fixed presets
and no general ASS styling editor.

### 3.4 Execution

**Entry point:** a "Burn In MP4…" action in the export sheet and the job context
menu, enabled when the job has segments and preflight passes. It opens a small
sheet: document (original / translation / bilingual), text size preset, output
location — then runs.

Burn-in runs through the existing job machinery: new `JobStatus.burningIn` and
`JobStage.burningIn`, driven by `activeTask` and `activeJobID`. This makes it
automatically mutually exclusive with transcription — a VideoToolbox encode and a
whisper decode would contend for the same silicon — and inherits cancellation,
progress reporting, and logging without new mechanism.

`JobStatus.isRunning` must include `.burningIn`. That one line is what extends
the existing guarantees — the delete guard, cancel stamping, and the
interrupted-on-load recovery in `JobStore` — to burn-in; without it, a crash
mid-encode leaves the job showing "Burning in" forever.

- `jobNeedsWork` returns `false` for burn-in: it is never auto-queued, only
  started explicitly.
- Progress comes from parsing `time=HH:MM:SS.ms` off ffmpeg's stderr against the
  `AVAsset` duration.
- On completion, status returns to `.translationComplete` or
  `.transcriptionComplete` based on whether the job has translated segments —
  the same recomputation already used at `AppModel.swift:400`.
- Cancellation terminates the process and deletes the partial output.
- Output defaults to `<name>.burned.mp4` beside the source. Writing over the
  source file is refused outright.

### 3.5 Cross-branch note

On master, ffmpeg remains genuinely required, because the Python helper uses it
to extract audio; burn-in is simply a second consumer. Once PR #2 lands, ffmpeg
becomes burn-in-only, and the diagnostics entry wording must change to say so.
That is a one-line follow-up at merge time, not a blocker.

---

## Error handling

| Failure | Behaviour |
| --- | --- |
| Watch folder deleted or unreadable | Log once, disable the stream, surface a warning in Settings; do not spin. |
| File disappears between scan and start | Job fails with a clear message; ledger records the failure. |
| Watch-folder job fails | Ledger records the failure so it is not retried every scan; the log explains why. |
| ffmpeg missing or lacking libass | Burn-in disabled with an install hint and a Recheck button. |
| ffmpeg exits non-zero | Partial output deleted, stderr tail written to the job log, status `.failed`. |
| Burn-in output equals the source path | Refused before launching ffmpeg. |
| Override references a removed preset | Decoding falls back to `nil`, i.e. inherit. |
| orderIndex collision after manual edits | Renormalization pass restores strict ordering. |

## Testing

Unit tested — all pure, no filesystem or network:

- settings resolution and inheritance for each of the five override fields
- the quality-preset parameter table
- `orderIndex` midpoint, edge insertion, and renormalization
- ledger add, skip, prune, and failure recording
- scan-rule dedup: same fingerprint in the job list (any status) blocks ingest;
  canceled-then-deleted becomes eligible again
- the stability gate, driven by an injectable clock
- media-extension filtering and partial-download exclusion
- ffmpeg argument construction, including the temp-path safety property
- ffmpeg progress parsing, including malformed lines
- the output-equals-source guard

`WatchFolderService` takes an injectable clock and directory lister so its logic
is testable without a real folder.

Verified manually, with steps recorded in the implementation plan: the FSEvents
callback, a real ffmpeg encode of a short clip, and SwiftUI drag-reorder.

`./script/run_tests.sh` stays green throughout. Baseline at branch creation is 27
tests across 5 suites; the expected end state is roughly 55.

## Non-goals

- Recursive watch folders, and more than one watch folder
- Automatic burn-in from the watch folder
- Soft-muxed (`mov_text`) subtitle tracks
- HDR/10-bit-preserving burn-in — output is always 8-bit SDR H.264; an HDR
  source comes out tone-shifted, and that is documented rather than solved
- A general subtitle styling editor
- Per-job overrides of decoding parameters (beam size, temperature, thresholds)
- Parallel job execution

## Phase order and dependencies

Phase 0 unblocks everything and lands first. Phase 1 depends on Phase 0 and
builds the override editor that Phase 2 reuses. Phase 2 depends on both. Phase 3
is independent of Phases 1 and 2 and could move earlier if burn-in turns out to
be the more urgent capability.
