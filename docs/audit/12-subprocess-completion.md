# Subprocess completion and bounded waits

PipeCollector delivers the final unterminated line before signaling EOF. Python workers synchronously retain terminal envelopes until the actor consumes them; exit waits for draining before dropping worker identity. Worker input pipes use macOS F_SETNOSIGPIPE so writing to an exited worker produces a catchable error rather than terminating Cue. Burn-in preflight drains both output streams and bounds execution plus pipe draining with a 10-second timeout and termination escalation. No new dependencies.

| Fixture | Before | After, final full-suite run |
| --- | --- | --- |
| Lines delivered: `a`, `b`, unterminated tail | 2 of 3 | 3 of 3 |
| Immediate worker exit after unterminated final result | 0 / 20 results | 20 / 20 results |
| 1 MiB stderr flood before successful stdout | Failure after 3.06480 s (fixture alarm) | Success in 0.08302 s |
| Ignored SIGTERM, 100 ms configured timeout | 3.06023 s (fixture alarm; timeout ignored) | 0.40978 s |

The first repaired-result test exposed SIGPIPE during shutdown; that intermediate run exited with status 141 and was not accepted. The pipe option fixes this additional crash path. Cancellation and inherited-open-pipe tests also pass; they verify child termination and bounded return without waiting for a descendant to close its inherited descriptor.

Validation: `./script/run_tests.sh`: **489 Swift tests, 8 Python tests, zero compiler warnings**. These are synthetic subprocess tests; Qwen recognition speed and translation quality are not claimed to change.

A final concurrent-drain probe reproduced another shutdown race: three waiters plus cancellation completed only **1/3**, with **two leaked-continuation diagnostics**. EOF waiters now have individual identities, so cancellation removes only its own continuation and EOF resumes every remaining waiter: **3/3 completed, zero leaked-continuation diagnostics**. The added regression passes in the final **495-test Swift / 8-test Python** gate with zero compiler warnings.
