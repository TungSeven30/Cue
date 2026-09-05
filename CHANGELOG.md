# Changelog

Notable changes per release. `script/release.sh <version>` requires a section
here for the version being released and uses it as the GitHub release notes.

## 2.7.0 — 2026-09-05

- **Subtitle timing is exact during playback.** Cues now use their true
  start-inclusive/end-exclusive boundaries, seeks reject invalid times, and
  an overlapping long cue returns after a shorter cue ends instead of leaving
  the preview blank.
- **Vietnamese subtitle imports preserve tone marks.** Windows-1258 combining
  sequences such as `Việt` decode correctly and normalize to Unicode. Because
  legacy encodings are inherently ambiguous, Cue pauses automatic write-back
  until the imported text is reviewed; UTF-8 Japanese/Vietnamese files keep
  their normal workflow.
- SRT and WebVTT import handles tab-separated cue settings, NOTE-prefixed cue
  identifiers, and missing SRT blank separators without silently losing cues.
  Unsupported source formatting protects the original from lossy write-back,
  while the video preview renders supported tags and entities as readable text.
- Imported translations are paired by unambiguous millisecond cue timing rather
  than unrelated row numbers. Replacing a transcript clears stale translations,
  partials, summaries, and resume state, and a subtitle picker cannot write into
  a different or newly running job while its sheet is open.
- Retrying a failed job resumes the stage that failed: translation retries keep
  the transcript, and burn-in failures return to output options instead of
  starting speech recognition again.
- **Large subtitle edits stay responsive.** Replace All on the 10,000-cue test
  fixture fell from 8.85 seconds and 20,000 model publications to 11.22 ms and
  one publication. Subtitle reads, backups, and write-back no longer block the
  main actor.
- Fixed races in concurrent job-history loading, imported-file modification
  timestamps, player teardown, Python worker shutdown, final unterminated
  helper output, and ffmpeg preflight timeout/cancellation. These could lose a
  final result, retain old media, overwrite a changed subtitle source, or hang
  shutdown.
- The preview-size control is now a native AppKit stepper with keyboard and
  VoiceOver increment/decrement actions and a system focus ring. Sidebar filters
  expose individual selected states, and transcript following and loading
  shimmer honor Reduce Motion.

## 2.6.0 — 2026-09-03

- **MKV files work on the built-in engine.** macOS cannot read Matroska, so
  the default engine used to fail those jobs with "The file has no audio
  track"; with ffmpeg installed it now extracts the audio through ffmpeg
  automatically, and without it the error says what to install.
- **Model weights stay loaded between jobs.** The built-in whisper.cpp
  engine keeps the model resident (freed after ten idle minutes or under
  memory pressure), and the Python backends run in a resident helper process
  that keeps its model loaded, so a batch of clips pays the load once. A
  repeat mlx-whisper job on a short clip went from 1.3 s to 0.2 s.
- **Long files transcribe reproducibly.** Every audio chunk now runs on a
  fresh whisper.cpp inference state; the previous shared state drifted cue
  timestamps by tens of milliseconds from chunk two onward.
- **Launch is faster with a large history.** Job files decode in parallel
  after the window is shown (0.95 s → 0.16 s for 574 jobs in the test
  build), in a fixed, deterministic order.
- **Watch folders react to nested drops in seconds** instead of waiting for
  the 60-second rescan: the folder is watched recursively with FSEvents and
  a follow-up scan runs as soon as a new file has held still.
- Smoother UI while a job streams: quality warnings are cached instead of
  recomputed on every progress tick, transcript rows skip unchanged
  re-renders, the video overlay only syncs while the player is visible, and
  the run log shows its tail without re-splitting the whole log.
- Fixed a deadlock in the environment diagnostics probes that could wedge
  the diagnostics pill (and hung the test suite): probes no longer block
  cooperative threads while draining their pipes.
- Faster chunk planning and audio loading (vDSP), bit-identical results.

## 2.5.0 — 2026-09-02

- Added **shimmering skeleton loading states** for transcription and translation,
  giving immediate visual confirmation with live progress details while models
  load and audio is processed.
- Added a **welcome onboarding workspace** highlighting privacy, on-device Metal
  acceleration, and multi-language translation, with clear next actions and format
  guides.
- Upgraded empty states across the sidebar and model browser with clear
  descriptions and single-click reset filters.
- Added **completion badges** and **actionable error recovery banners** with
  retry options, system setup links, and one-click error copying.
- Added instant **copy confirmation micro-feedback** (green checkmark) in the run
  log, setup guide, and diagnostic popover.
- Added **⌘1 / ⌘2 / ⌘3 keyboard shortcuts** to switch between Transcript,
  Translation, and Log tabs, plus comprehensive VoiceOver accessibility labels.

- Add from URL no longer dead-ends when **yt-dlp** is missing: Cue offers to
  install it with Homebrew right in the app, shows brew's progress in a
  sheet, and starts fetching your link automatically once it lands. Without
  Homebrew you get exact manual instructions instead of a bare error. The
  setup guide's yt-dlp row gained the same Install button.
- Fixed a build break in the job card's settings bindings that kept the
  current source from compiling under Swift 6 toolchains.
- Resume-from-chunks fixes for the built-in engine: silence detection now
  works on the engine's normalized audio (chunk cuts land in real pauses
  instead of mid-sentence), a saved cue ending exactly on a chunk boundary is
  no longer dropped on resume, and a resumed transcript is cleaned as one
  document so cue ids stay unique — duplicate ids broke translation lookups
  and SRT numbering.
- A subtitle file with a malformed timestamp (`inf`, `nan`, or an absurd
  value) is now rejected instead of crashing export and silently making the
  job unsaveable.
- Stopping a job during its final translation requests no longer lets the job
  flip to "Translation ready" after the cancel.
- Pressing Translate on a job that already has a translation now translates
  again (it was a silent no-op), and changing the target language discards
  partials made for the previous language.
- Automatic sidecar export keeps a one-time `.bak` of any subtitle file it
  would overwrite, so hand edits to an earlier export survive a re-run.
- Quitting while jobs or downloads are running now asks first, and stops the
  helper processes (yt-dlp, ffmpeg, Python) instead of leaving them orphaned.
  The launch-time orphan sweep only touches processes whose parent is gone,
  so a CLI run beside the GUI is never killed, and it now covers yt-dlp.
- Groq, Cerebras, OpenRouter, and local Chat Completions requests set an
  output token budget (Groq's small default truncated most chunks and forced
  splits); rate-limited requests honor `Retry-After` and back off longer.
- The CLI rejects misspelled options instead of running with defaults, runs
  the one-time WhisperDesk data migration before headless commands, and
  cleans up after Ctrl-C.
- Media dropped on the Dock icon or opened via Finder's Open With becomes
  jobs; the menu command that stops every lane is now labeled "Stop All
  Jobs"; advanced controls the selected engine ignores are hidden; watch
  folder scans run off the main thread; per-job and watch-folder settings
  can now override the translation LLM, source language, and intro summary.

## 2.4.0 — 2026-08-22

- Added **Add from URL** (⌘L): paste or drop a video page link and Cue fetches
  it with yt-dlp into a Downloads folder you choose, then queues it as an
  ordinary job. Fetches run alongside the queue and appear in a sidebar
  Downloads section with progress, cancel, and retry.
- Added a **headless CLI** inside the app binary — `Cue.app/Contents/MacOS/Cue
  transcribe clip.mkv` — with `fetch`, `transcribe`, `translate`, `summarize`,
  `burn-in`, `pipeline`, and `doctor` stages. Each stage writes a
  `<name>.cue.json` manifest that the next stage reads, so runs chain and stay
  scriptable; `--json` prints the manifest on stdout while progress goes to
  stderr. Settings and API keys come from the app's own Settings and Keychain.
- Added **subtitle import**: existing SRT/WebVTT sidecars sitting next to the
  media are detected on add and adopted into the matching transcript and
  translation slots (routed by language code), so jobs that already have
  subtitles skip ASR entirely and go straight to translation or export.
- Added a **Load Subtitles…** command (⌘⇧O) that loads a subtitle from any
  folder into a chosen slot — with an import-time backup, a provenance banner,
  automatic write-back of edits to the imported file, and safeguards so sidecar
  exports never overwrite the original. Imported files keep UTF-8, UTF-16, and
  Windows-1252 encodings working.
- `cue translate` also accepts an existing `.srt`/`.vtt` file, so subtitles Cue
  did not produce can be translated without re-transcribing.
- The intro summary in the job detail header now wraps over several lines and
  its text can be selected.

## 2.3.6 — 2026-08-13

- Added a single-job Start action that runs only the selected job while leaving
  the rest of the queue paused until Start All resumes it.
- Local LM Studio and OpenAI-compatible servers can now be reached by network
  address, tested from Settings, and queried for available or running models.
- Simplified the Translation and Intro Summary settings with provider-aware
  model pickers, local running-model selectors, and collapsed cloud API keys.
- Added the macOS local-network permission description and packaging checks
  needed for reliable connections to model servers on another computer.

## 2.3.5 — 2026-08-12

- Kept the sidebar responsive with large job histories by batching queue,
  persistence, selection, and status calculations into single-pass updates.
- Added live row progress, queue positions and estimates, clickable status
  filters with counts, and smart selection commands for everyday queue work.
- Added bulk queue/archive/retry actions, quick retry for failed jobs, and Undo
  for archive, unarchive, and queue-removal actions.

## 2.3.4 — 2026-08-08

- Sidebar jobs now support native Command-click and Shift-click multi-selection,
  with confirmed bulk deletion that leaves source media and exports untouched.
- Added a Qwen-specific movie profile, vocabulary context, an in-memory
  NumPy chunk path with vectorized silence planning, and per-stage/RTF metrics.
- Cloud translation now starts with the first useful transcript batch, sizes
  requests by estimated tokens, and never resubmits already translated ranges.

## 2.3.3 — 2026-08-08

- Corrected the packaged Metal shader's file permissions so a Cue app placed
  in `/Applications` remains readable across macOS user accounts and Sparkle
  updates no longer report an irregular-resource warning. Includes all 2.3.2
  summary-model, provider-routing, and reliability improvements.

## 2.3.2 — 2026-08-08

- Intro summaries can use the translation model, a different cloud model,
  or an OpenAI-compatible local model. An optional fallback runs only when
  the primary model explicitly refuses the content for a policy/safety reason.
- Translation requests now keep the selected provider, credentials, endpoint,
  and model routing together throughout retries and recursive chunk splits.
- The standalone `transcribe.py` is generated from the app's canonical backend
  and now has the same audio cache, cancellation cleanup, and preprocessing
  fallback behavior; CI rejects future drift.
- Model downloads, job persistence, Keychain failures, interrupted-job
  recovery, diagnostics, and release verification now fail visibly and retain
  recoverable data instead of silently continuing.
- Migrated the project to Swift 6 strict concurrency and expanded deterministic
  coverage across the pipeline, storage, networking, packaging, and real
  packaged Metal inference.

## 2.3.1 — 2026-08-08

- In-app updates: Cue now checks for and installs new versions itself
  (Cue > Check for Updates…) — no more manual DMG downloads.
- Sidebar sorting: Organize > Sort by queue order, date completed, name,
  or length.
- Auto-archive: finished jobs older than a configurable window (default
  30 days) leave the sidebar automatically; an Archived filter and
  context-menu Archive/Unarchive manage them by hand.
- Menu-bar item: queue status, running-job percent, time remaining, and
  pause/resume without opening the main window.
- Queue time estimate ("~12m left") from your recent job durations, and an
  optional "sleep the Mac when the queue finishes" for overnight batches.
- Offline volumes: jobs on an unmounted disk or NAS share wait and retry
  instead of failing, while runnable jobs behind them proceed.
- Orphaned transcription workers from a crashed or replaced app instance
  are cleaned up at launch.
- Faster launches with large job histories (removed per-row filesystem
  stats on network volumes).

## 2.3.0 — 2026-08-08

- Renamed to Cue (formerly WhisperDesk); jobs, settings, and keys migrate
  automatically, and the app has a new icon and wordmark.
- Watch while transcribing: subtitles stream into the transcript pane and
  player as they are produced, with cloud translation running behind the
  transcription frontier.
- Pipelined queue: the next job's transcription starts while the previous
  job's translation finishes.
- Folders mean everything inside them: dropped folders and watch folders
  ingest videos from subfolders, in episode order.
- Per-job timing ("Done in 7m 12s") with a per-phase breakdown in the log.
- Canceling mid-run keeps partial transcripts and translations.

## 2.2.2 — 2026-08-03

- Multiple watch folders, each with its own language/preset/translation
  profile; full-screen video; detailed summaries.

## 2.2.1 — 2026-07-27

- OpenRouter translation models; sidebar polish.

## 2.2.0 — 2026-07-27

- Watch folders, burn-in export, queue control.

## 2.1.0 — 2026-07-27

- Local LLM translation via OpenAI-compatible servers (LM Studio, Ollama,
  mlx-lm) with the local/ model prefix.

## 2.0.0 — 2026-07-26

- Zero-dependency install: built-in Metal-accelerated whisper.cpp engine,
  no Homebrew or Python required. (2.0.1 fixed first-run Metal shader
  compilation.)

## 1.0.0 — 2026-07-26

- First release: on-device transcription, LLM translation, synced review
  UI, SRT/WebVTT export.
