# 01 — Subtitle timing and overlap recovery

Baseline: 6a5160e, M5 Max, macOS 26.5.2, Swift 6.3.3. No dependency or serialized-format changes.

AVPlayer now observes cue boundaries on its media clock, retaining the 250 ms observer only as a scrub fallback. Cue membership is exactly [start, end); a longer cue reappears when the latest overlapping cue ends. Nonfinite seeks are ignored and an empty subtitle list clears the overlay.

| Measurement | Before | After |
|---|---:|---:|
| Incorrect results in the same 14 boundary/overlap probes | 5 | 0 |
| Cue [1,2) incorrectly visible at 0.85 seconds | Yes | No |
| Cue [1,2) incorrectly visible at 2.24 seconds | Yes | No |
| Long cue missing at 4 seconds after nested overlap | Yes | No |
| Full Swift regression suite | 456 passed | 459 passed |
| Python regression suite | 8 passed | 8 passed |
| Compiler warnings | 0 | 0 |

Validation: `./script/run_tests.sh`; optimized standalone harness calling the real PlayerController's updateSegments/seek methods at identical timestamps. New tests cover half-open boundaries, reverse seeks, unsorted nested overlaps, empty lists, zero-length cues, and nonfinite seeks.

These numbers measure cue selection, not display presentation latency. No claim of lower CPU, fewer dropped frames, or a measured 60/120 Hz presentation improvement. Those require the application instrumentation item.
