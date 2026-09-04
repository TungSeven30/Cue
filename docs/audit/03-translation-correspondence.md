# 03 — Translation correspondence and stale derived content

Independent imports are paired by unambiguous start/end timestamps at millisecond subtitle precision, not by their independently assigned IDs. Bilingual export and translation resumption apply the same validation to existing history. A resegmented or ambiguous import cannot be adopted as a corresponding translation. Replacing an original transcript clears old translations, partials, summary, translation-file association, and transcription resume position; pending translation write-back is canceled.

| Regression measurement | Before | After |
|---|---:|---:|
| Incorrect bilingual rows when the translation omits cue 1 | 2 of 2 | 0 of 2 |
| Stale derived fields after loading a new original | 5 of 5 | 0 of 5 |
| New regression failures | 3 assertions | 0 |
| Full Swift suite | 461 existing tests passed | 464 tests passed |
| Python tests / compiler warnings | 8 / 0 | 8 / 0 |

Before and after run the same new tests through `./script/run_tests.sh`. Extra coverage rejects merged cues, duplicate timing candidates, and ambiguous translations. No performance improvement is claimed: these are correspondence and invalidation measurements. No dependencies or serialized fields changed.
