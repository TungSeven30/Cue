# 09 — Validate stored cues and progress

Job loading rejects duplicate IDs and invalid/nonfinite cue timestamps before rendering or export. The existing recovery-copy path retains both original job JSON and a .corrupt.json copy and reports the failure. Legacy migration validates too. Nonfinite/out-of-range progress becomes indeterminate, including live progress in the sidebar and detail pane; nonfinite ordering and resume values receive safe defaults.

| Measurement | Before | After |
|---|---:|---:|
| Malformed cue jobs rejected with recovery copies | 0/2 | 2/2 |
| Unsafe progress values retained after loading | 4/4 | 0/4 |
| New persisted-value regression assertion failures | 5 | 0 |
| Swift / Python tests | 476 / 8 passed | 479 / 8 passed |
| Compiler warnings | 0 | 0 |

Validation: `./script/run_tests.sh`, exercising real save/load, preserved files, NaN, infinity, huge/negative fractions, duplicate IDs, and infinite timestamps. A separate live-progress test verifies only finite 0–1 fractions reach percentage formatting. No latency or memory improvement is claimed. No dependency or serialized-format changes.
