# 05 — Retry the failed stage

The failure card now retries translation when translation failed, resumes transcription when ASR failed, and reopens burn-in options when burn-in failed. It no longer forces a new transcription for every error. New failures retain optional stage metadata in JobProgress; old histories remain readable, and missing stage metadata has a conservative fallback. No dependencies were added. Existing keys and formats remain compatible; older versions ignore the optional failedStage field.

| Regression measurement | Before | After |
|---|---|---|
| Imported transcript link retained on translation retry | No | Yes |
| Translation retry starts translation rather than GPU/ASR | No | Yes |
| Burn-in retry opens output options without starting ASR | No | Yes |
| Failing regression assertions | 6 | 0 |
| Swift / Python tests | 469 / 8 passed | 471 / 8 passed |
| Compiler warnings | 0 | 0 |

Measured through the same isolated AppModel test fixtures and `./script/run_tests.sh`; no production jobs or providers were used. No CPU or latency improvement is claimed. Burn-in output destinations are not persisted, so Retry asks for its output through the existing options sheet rather than guessing a file to overwrite. The failure card's appearance is unchanged.
