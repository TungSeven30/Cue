# 06 — Race-free job hydration

Parallel decoding remains parallel. An NSLock now protects the short assignment into the shared Swift Array; writing separate indices does not make mutation of that Array value safe.

| Measurement | Before | After |
|---|---:|---:|
| ThreadSanitizer warnings, same extracted function harness | 2 | 0 |
| Full Swift suite | 471 passed | 472 passed |
| Distinct job payloads verified in 8 simultaneous real-store snapshots | — | 1,600/1,600 |
| Python tests / compiler warnings | 8 / 0 | 8 / 0 |

The sanitizer harness extracts the exact decodeConcurrently implementation and supplies a minimal Codable payload, repeating 256 parallel decodes five times. It isolates the Swift Array access race; this is not a claim that the entire application has passed ThreadSanitizer. The new application test verifies payloads, counts, failure lists, and deterministic order in simultaneous snapshots. `./script/run_tests.sh` passes. No throughput improvement is claimed; no dependencies, APIs, or file formats changed.
