# Changelog

Notable changes per release. `script/release.sh <version>` requires a section
here for the version being released and uses it as the GitHub release notes.

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
