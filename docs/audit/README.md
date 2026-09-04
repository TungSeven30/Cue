# Cue audit implementation

The thirteen behavior-fix items are implemented as separate commits. Item 14 adds a repeatable isolated harness; actual cold launch, first-pixel timing, and 60/120 Hz frame traces remain unverified. No new dependencies were added. Public interfaces and SRT/WebVTT output remain compatible; new persistence metadata is optional and older JSON remains readable.

## Results

| Item | Recorded before → after | Evidence |
| --- | --- | --- |
| 1. Subtitle boundaries / overlap | 5 errors in 14 probes → 0 | [Timing](01-subtitle-timing.md) |
| 2. Vietnamese decoding | `Viêòt` → `Việt`; ambiguous imports cannot auto-overwrite sources | [Encoding](02-vietnamese-decoding.md) |
| 3. Translation correspondence | 2/2 wrongly paired rows → 0; 5 stale fields → 0 | [Correspondence](03-translation-correspondence.md) |
| 4. Supported parsing / preview text | 0/2 valid VTT fixtures → 2/2; markup becomes readable text | [Parsing](04-supported-subtitle-parsing.md) |
| 5. Retry the failed stage | Wrong transcription retry → translation retry or burn-in options, preserving transcript | [Retry](05-stage-aware-retry.md) |
| 6. Concurrent job decoding | 2 ThreadSanitizer warnings → 0 | [Hydration](06-hydration-race.md) |
| 7. Imported-file timestamp precision | 0.765432-second round-trip error → 0 | [Timestamp precision](07-subtitle-mtime-precision.md) |
| 8. Import races | Wrong-target/running-job overwrites → rejected | [Import races](08-subtitle-import-races.md) |
| 9. Stored-value validation | 0/2 malformed jobs rejected → 2/2; unsafe progress values are indeterminate | [Stored values](09-stored-value-validation.md) |
| 10. Playback lifecycle | 2/2 old player items retained after deselection → 0/2 | [Playback](10-playback-selection-lifetime.md) |
| 11. Replace All / file work | 8,849.21 ms → 11.22 ms for 10k cues; 20,000 publications → 1 | [Responsiveness](11-responsive-subtitle-edits.md) |
| 12. Subprocess completion | 0/20 final results → 20/20; concurrent drain completion 1/3 → 3/3 | [Subprocesses](12-subprocess-completion.md) |
| 13. Native accessibility / motion | 13 pt resize affordance → 28 pt; real keyboard/VoiceOver actions and focus ring | [Native UI](13-native-accessibility.md) |
| 14. Baseline harness | Blocked isolated window → 20/20 measured fixture runs; frame traces still open | [Runtime measurements](14-isolated-baseline.md) |

Not every metric improved. Safer parsing increased the optimized 10k-cue SRT median from 96.35 ms before this series to 121.55 ms after parser validation. The native UI comparison increased median playback footprint from 71.75 to 73.06 MiB and mean CPU from 7.21% to 7.26%. The reports describe workloads and limits; these are not speed wins.

The final full suite passes **495 Swift tests and 14 Python tests with zero compiler warnings**. Individual reports retain the test counts and measurements recorded at their respective gates, before later unrelated tests were added. The local release-mode bundle is `dist/Cue.app`; it has not been installed over the user's application or published.

Each item has one commit. Shared-file changes mean some out-of-order Git reverts need conflict resolution; the [independent rollback patches and guarded utility](rollbacks/README.md) preserve the remaining fixes without reorganizing production code. The patches target this audited source and each is validated with the remaining full suite.

## Visual evidence

[Before](screenshots/13-workspace-before-dark.png) · [After](screenshots/13-workspace-after-dark.png) · [Light mode](screenshots/13-workspace-after-light.png) · [Native focus ring](screenshots/13-native-focus.png) · [Readable subtitle markup](04-supported-subtitle-parsing.md)

## Decisions still separate

- Encoding selector / preview: recommended deferral for the primarily Unicode Qwen → Vietnamese workflow. TCVN3/VNI remain out of scope without representative files.
- Restore selected job, tab, and position: recommended, always paused; not implemented without the requested individual approval.
- New app-wide Find / preview / playback menu commands: awaiting individual approval.
- ASS: explicitly excluded.
- Installing full Xcode for frame profiling: awaiting the user's choice; nothing installed.
