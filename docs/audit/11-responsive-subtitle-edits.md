# Responsive subtitle editing and file I/O

Replace All now applies changed cue text in one job publication and one debounced persistence request, preserving IDs and timings. Manual file parsing runs in a detached task. Normal imported-subtitle writes run on a serial utility queue, preserving the backup and external-change protections. Selection submits pending writes without waiting; quit explicitly waits for accepted writes. Canceled queued writes cannot modify an unlinked source.

| Measurement | Before | After |
| --- | ---: | ---: |
| Replace text across 10,000 cues, AppModel call | 8,849.21075 ms | 11.220583 ms |
| Observable publications for that call | 20,000 | 1 |
| Normal manual parse / source write execution | Main actor | Background executor / serial queue |

Timing uses the same debug test harness and 10,000-cue fixture with `CUE_AUDIT_BENCH=1 ./script/run_tests.sh`. It measures model mutation, not rendered-frame latency or asynchronous persistence completion. The file-I/O change improves isolation from UI work; total disk throughput and end-to-end import speed were not measured and are not claimed to improve.

Regression tests verify one publication, text and timing preservation, an independently responsive main actor during an injected blocked read, consecutive writes without false external-change detection, backups, off-main writer execution, and canceled writes leaving the original bytes intact. Final gate: **484 Swift tests, 8 Python tests, zero compiler warnings**, using `./script/run_tests.sh`. No dependencies, public API removals, or file-format changes.

Final review also moved the confirmed manual-import backup and file-state checks off the main actor. The slot picker is disabled during that accepted operation, and selection/job revision/activity are rechecked afterward. A blocked-backup regression confirms the main actor can clear selection while disk work waits, and the late result cannot populate the now-unselected job. This final validation passed **494 Swift tests and 8 Python tests, zero compiler warnings** on the completed branch. The earlier 484-test count records the initial item gate; no disk-throughput improvement is claimed.
