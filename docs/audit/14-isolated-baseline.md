# Isolated runtime baseline

The local audit harness links Cue's actual debug objects and ContentView while supplying a separate entry point, synthetic completed job, empty diagnostic service, secret-free settings, and explicitly injected job/watch-ledger stores. It does not start the production updater, orphan sweep, or migration. It is not part of the shipped application. AppModel's only production change for this item is an optional watch-ledger injection; existing callers retain the same default.

The initial isolated audit could not reach a window because of production Keychain access. This harness completed **10/10 before-UI trials and 10/10 after-UI trials**. Every trial verified approximately 20 seconds of advancing media time, collected five idle footprint readings and twenty playback readings, then exited. The machine was a normal desktop session, not a dedicated performance lab.

## Controlled UI comparison

Debug objects, synthetic 90-second 1920×1080/60 fps video, 45 Japanese/Vietnamese cues, muted, follow scrolling off. Ten fresh processes per version, warm filesystem. These compare the native UI item, not the entire patch series against the installed release.

| Metric | Before UI item | After UI item |
| --- | ---: | ---: |
| SwiftUI App initialization → view appearance, median | 229.83 ms | 237.74 ms |
| App initialization → nonempty overlay model, median | 677.73 ms | 722.95 ms |
| Idle physical footprint, median, 50 samples | 67.56 MiB | 69.13 MiB |
| Playback physical footprint, median, 200 samples | 71.75 MiB | 73.06 MiB |
| Playback CPU, mean, 200 intervals | 7.21% | 7.26% |
| Playback CPU range | 3.06–9.92% | 4.21–9.84% |

**No performance improvement from the UI work is established.** These runs show higher preparation times and approximately 1.30 MiB more median playback footprint. CPU is slightly higher; no significance claim is made. The earlier installed-app readings used a different workload and are not a valid before/after comparison with this synthetic debug harness.

Physical footprint uses TASK_VM_INFO.phys_footprint; CPU uses process user+system CPU-time deltas divided by elapsed time, where 100% means one fully occupied CPU core. The helper samples itself, so its small measurement overhead is included. No ML inference ran.

## Limits

- **True cold launch: unmeasured.** The view marker begins at SwiftUI App initialization, excluding process loader work, and the filesystem was not cold.
- **Time to first visible subtitle pixels: unmeasured.** An overlay-model publication is not a presentation timestamp. Screenshots separately confirm visible output.
- **Dropped frames at 60/120 Hz: unmeasured.** Instruments/xctrace is unavailable. NSScreen reports an 8.33–41.67 ms ProMotion interval range (24–120 Hz capability), not per-frame scanout timing or fixed-refresh operation.
- **ASS: unsupported by the agreed product scope.**
- The full frame-profiling acceptance criterion for audit item 14 remains open.

Raw [before summary](runtime/ui-before-summary.json), [after summary](runtime/ui-after-summary.json), [before trials](runtime/ui-before-trials.json), and [after trials](runtime/ui-after-trials.json) include ranges and all samples.

## Reproduce

Run `./script/run_tests.sh` first, then:

```sh
python3 script/audit/build_harness.py /private/tmp/cue-audit-run /absolute/path/to/synthetic-video.mp4
python3 script/audit/measure_harness.py /private/tmp/cue-audit-run 10
```

The measurement command resets only generated fixture history inside its validated temporary root. The app can also be opened for screenshots; its Audit Appearance menu changes only that harness process. This harness targets the audited Apple Silicon machine and uses already-built dependencies; it adds none.

Regression coverage verifies that clearing one watched folder uses the injected ledger and preserves another folder's history. Final branch validation: **495 Swift tests, 14 Python tests, zero compiler warnings**. Six Python tests cover the guarded independent rollback utility. A release-mode Cue.app bundle is built and verified separately; these debug harness numbers are not production release performance claims.
