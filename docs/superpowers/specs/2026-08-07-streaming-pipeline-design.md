# Streaming Pipeline (Watch-While-Transcribing) — Design

**Date:** 2026-08-07
**Branch:** to be cut from master
**Status:** Implemented

## Goal

Collapse time-to-first-subtitle from minutes to seconds. Today a job is
all-or-nothing: transcription completes, then translation completes, then the
user can watch. Instead, segments appear in the transcript pane and the player
as the engine produces them, and translation chunks fire as soon as enough
segments exist to fill one — so a user can drop a file, press play within the
first minute, and watch with translated subtitles whose frontier outruns the
playhead.

Secondary goal delivered by the same restructuring: **queue pipelining** — the
GPU never idles waiting for a network-bound translation tail. Job B's
transcription starts the moment job A's transcription finishes, even while A is
still translating.

## Decisions taken

| Decision | Choice | Reason |
| --- | --- | --- |
| Streaming backends in v1 | Built-in whisper.cpp + Qwen3-ASR | Built-in is nearly free (native callback); Qwen3 is the user's daily driver. mlx-whisper / faster-whisper keep today's behavior. |
| Local-LLM translation overlap | Cloud overlaps, local waits | A local LLM contends with the ASR model for GPU/unified memory. Cloud providers are network-bound and overlap freely. |
| Queue behavior | Pipeline the queue | GPU slot and translation slot run independently; batch throughput improves; one-GPU-consumer invariant preserved. |
| Architecture | Two-slot scheduler in AppModel (Approach A) | Delivers pipelining while keeping the codebase's shape: pure logic in small units, orchestration in AppModel. Rejected: intra-job overlap only (no pipelining); StreamingPipeline actor (relocates run-loop logic every shipped feature reaches into AppModel for). |
| Job timing display | Total + phase breakdown | Completed status line shows "Done in 7m 12s"; the job log records per-phase durations and overlap. |
| Resume/checkpointing | Out of scope | Incremental persistence lands as a by-product (the checkpoint foundation), but resume UX is a separate effort. Interrupted jobs are still sanitized to `.canceled`; they now keep their partials. |
| New feature flag | None | Streaming is core behavior, not a mode. Non-streaming backends degrade gracefully to today's experience through the same code path. |

## 1. Segment streaming (producer side)

### 1.1 Unified interface

`TranscriptionService.transcribe(...)` gains one optional callback alongside
the existing `onProgress`:

```swift
onSegments: @Sendable ([TranscriptionSegment]) -> Void
```

It delivers **batches** of newly finalized segments, timestamps relative to the
file start, in order, no overlaps with previously delivered batches. Backends
that never call it (mlx-whisper, faster-whisper) produce a job that looks
exactly like today's app — no downstream special-casing.

### 1.2 Built-in engine (whisper.cpp)

`WhisperCppEngine` wires `new_segment_callback` /
`new_segment_callback_user_data` through the existing `CallbackBox` pattern
(same as progress and abort callbacks). whisper.cpp invokes it after each
decode window (~30 s of audio); the callback reads the window's new segments
(`whisper_full_n_segments` delta) and forwards one batch. The callback fires on
whisper's worker threads — like the abort callback, it must not touch
task-local state; it marshals through the box to the main actor.

The final return value of `transcribe` is still the complete segment list, and
the full `TranscriptionPostProcessor.clean` still runs on it. Streaming adds a
path; it does not change the authoritative result.

### 1.3 Qwen3-ASR backend (chunk driving)

The wrapper script (authored in `BackendScriptWriter`, mirrored in the
repo-root `transcribe.py` — keep both in sync) gains chunk-driving for the
`qwen3-asr` backend:

1. Split the extracted WAV at detected silences: energy-based detection,
   silence ≥ 0.5 s, target chunk length 2–3 min, hard cap 5 min. A file with
   no usable silences degrades to a single chunk — today's behavior, never a
   worse transcript.
2. Load the model once; call `qwen3_transcribe` per chunk; offset each chunk's
   timestamps by the chunk start; run the existing `group_timed_tokens`
   per chunk.
3. After each chunk, emit `{"event": "segments", "segments": [...]}` as a line
   on stderr — the same line-delimited JSON protocol
   `TranscriptionService` already parses for progress events. The Swift side
   decodes the new event type and forwards the batch to `onSegments`.

First subtitles arrive after model load + one chunk (~30–60 s wall-clock).
The script still prints the complete result on stdout at the end, unchanged.

### 1.4 Per-batch cleanup

Streamed batches pass through a **window-local, deterministic subset** of
`TranscriptionPostProcessor` before anyone sees them: whitespace trim, drop
empty segments, zero/near-zero-duration repair. Operations that need the whole
transcript (cross-window dedupe, echo-after-silence removal, short-segment
merges, renumbering) run only in the final full pass at completion, which
remains authoritative. The subset must be stable: cleaning a batch twice
yields the same result, and cleaning batch N never alters batch N−1.

## 2. Progressive translation

### 2.1 ProgressiveTranslationDriver (new, `Sources/Services`)

A small unit with one job: consume streamed segment batches, cut translation
chunks, call the existing `TranslationService`, emit partials.

- **Input:** segment batches (post window-local cleanup), the job's resolved
  `JobSettingsSnapshot`, `TranslationCredentials`.
- **Chunk cutting:** pure, unit-testable math using the job's existing
  `translationChunkMode` sizing. Chunks are cut **only at streamed-batch
  boundaries** — the places where per-batch cleanup is deterministic.
- **Output:** partial translated segments through a callback, feeding the
  existing `partialTranslatedSegments` field and its persistence path.
  Carried-forward context pairs work exactly as in a normal chunked
  translation run.
- **Provider gate:** for cloud providers the driver attaches when
  transcription starts and translates behind the frontier. For the local
  provider it buffers batches and issues no requests until transcription
  completes — same code path, one gate on `TranslationProvider`.
- The driver never touches `AppModel`; it is driven by callbacks and emits
  through callbacks.

### 2.2 Reconciliation at completion

The final full-transcript cleanup can merge segments or shift window-edge
text, so partials keyed to streamed segments may not match the final
transcript 1:1. Policy:

1. After the final pass, re-map partial translations onto final segments by
   exact `(start, end, text)` match.
2. Unmatched partials are discarded; their spans join the untranslated tail.
3. The tail (everything past the translated frontier plus discarded spans) is
   translated by the normal completion-path translation call, seeded with the
   matched partials via the existing `existingTranslations` mechanism.

Correctness never depends on the mapping: exports, sidecars, and the intro
summary read only the post-reconciliation result. Mismatches are the
exception (cleanup mostly touches window edges), so re-translation volume is
small.

## 3. Two-slot scheduler

### 3.1 Slots

`activeTask`/`activeJobID` are replaced by two independently serial slots in
`AppModel`:

- **GPU slot** — at most one transcription at a time. This is the existing
  one-GPU-consumer invariant, now named. When it frees, the scheduler starts
  the next queued job's transcription immediately, even if a translation is
  still running.
- **Translation slot** — at most one translation driver at a time, FIFO by
  job. Serves both overlapped (streaming) translations and today's
  standalone translation runs.

Queue-pause semantics, `queuedJobCount`, `orderIndex` selection, and watch
ingest behavior are unchanged. `updateProcessingActivity()` (sleep assertion)
considers both slots.

### 3.2 Status model

No new `JobStatus` cases. A job with both phases active shows `.transcribing`
with a two-line progress detail ("Transcribing 62% · Translated 41%"); when
transcription completes it transitions to `.translating` as today.
`isRunning` semantics are untouched, so every existing guard — burn-in
gating, reorder rules, Start All, cancel eligibility — stays correct without
edits.

### 3.3 Completion-order effects

Watch outcomes, sidecar auto-export, the completion notification, and the
intro summary fire exactly once, at a job's **full** completion (both phases
done), as today. Two jobs being in flight means two progress rows in the
sidebar; nothing else about their lifecycles changes.

## 4. Job model and persistence

- New field `partialTranscriptSegments: [TranscriptionSegment]` on
  `TranscriptionJob`, mirroring `partialTranslatedSegments`: tolerant decode
  (`decodeIfPresent`, default `[]`), cleared when the final transcript is
  stamped. Keeping partials out of `transcriptSegments` keeps the
  re-transcription skip check and the crash sanitizer correct — a partial
  transcript must never satisfy "this job already has a transcript".
- Partials persist through the existing `updateJob` → `JobStore` atomic-write
  path, once per streamed batch (a few writes per minute — well within what
  the store handles).
- New timing fields on `TranscriptionJob`: `transcriptionStartedAt`,
  `transcriptionFinishedAt`, `translationStartedAt`, `finishedAt` (all
  optional `Date`, tolerant decode). Completed status line shows
  "Done in 7m 12s" (m/s; h/m over an hour), measured from transcription start
  to full completion. The job log records the per-phase breakdown and, when
  phases overlapped, the overlap duration. Failed/canceled jobs show no
  duration line; their log already carries the trail.

## 5. UI behavior

- **Transcript tab** renders `partialTranscriptSegments` while transcription
  runs, filling as batches land; it switches to the final transcript at
  completion.
- **Translation tab** upgrades from today's "N segment(s) already saved"
  count to rendering partial translations as live rows.
- **Player overlay** follows the visible tab, as today
  (`PlayerController.updateSegments`). Beyond the translated frontier the
  overlay shows nothing — for a non-speaker, untranslated text is noise.
- No auto-play, no "watchable now" notification. The file is simply there and
  improving when the user opens it. The completion notification is unchanged.

## 6. Failure and cancellation

Streaming must never make a failure lose more than the sequential path would.

- **Cancel** cancels both of the job's phases; partial transcript and partial
  translations are retained on the canceled job (an upgrade from
  all-or-nothing).
- **Transcription fails mid-stream:** job takes today's failure path;
  partials are retained; the job's translation driver stops.
- **Translation fails while transcription is running** (rate limit, credits,
  server down): the driver stops, **transcription continues to completion**,
  then the job takes today's translation-failure path — transcript preserved,
  partials preserved, retry resumes from partials via `existingTranslations`.
- **Crash/force-quit:** the load-time sanitizer still marks the job
  `.canceled`; it keeps its persisted partials.

## 7. Out of scope

- Resume of interrupted jobs (the persistence groundwork lands here; the
  resume state machine and UX are a separate spec).
- Streaming for mlx-whisper and faster-whisper.
- Any change to translation providers, chunk sizing, or context carrying.
- Cross-episode glossary, confidence re-decode (separate roadmap items).

## 8. Testing

All via `./script/run_tests.sh` (never bare `swift test`).

- **Pure units:**
  - Driver chunk-cutting math: batch accumulation, boundary-only cuts,
    chunk-mode sizing, local-provider buffering gate.
  - Window-local cleanup subset: deterministic per batch; idempotent;
    batch N never alters batch N−1.
  - Reconciliation: exact-match re-mapping, orphan discard, tail computation.
  - Silence-splitting: chunk boundaries land in silences, cap respected,
    no-silence file → one chunk (validated against synthetic WAV fixtures
    with known silence layout via `transcribe.py`, plus a Swift mirror of the
    boundary math if the logic is ported).
- **Scheduler state machine:** fake transcription/translation services
  emitting scripted batches. Assert: never two concurrent transcriptions;
  queue pipelining (B transcribes while A translates); cancel and failure
  paths per §6; watch outcomes and sidecars fire exactly once at full
  completion; timing fields stamped correctly including overlap.
- **Engine callback:** tiny audio fixture through `WhisperCppEngine`; assert
  segments arrive incrementally and the final result equals the
  non-streaming result for the same input.
- **Stderr protocol:** `segments` event decoding, interleaved with progress
  events, tolerant of unknown future event types.
