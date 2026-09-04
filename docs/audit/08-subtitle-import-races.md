# 08 — Bind subtitle import to the intended job

The load request captures job identity, source path, and revision before opening the file panel. Both slot buttons use request-specific eligibility. Commit revalidates selection, job activity/revision, and the imported file after replacement confirmation's nested event loop. A stale request cannot write into a different or newly active job.

| Same regression scenarios | Before | After |
|---|---:|---:|
| Cues mistakenly imported into another selected job | 2 | 0 |
| Cues mistakenly imported into a job that started | 2 | 0 |
| Revision-changed job is overwritten | Yes | No |
| Swift / Python tests | 474 / 8 passed | 476 / 8 passed |
| Compiler warnings | 0 | 0 |

Validation: `./script/run_tests.sh`, including the existing manual import cases updated to supply their explicit target. The new tests exercise actual commit methods, not a duplicate eligibility implementation. No latency improvement, appearance redesign, dependency change, or persisted-format change is claimed. Ineligible picker actions are disabled.
