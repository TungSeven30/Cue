# 02 — Vietnamese decoding and legacy-source protection

Windows-1258 vowel/tone sequences now decode as Vietnamese and normalize to composed Unicode. UTF-8, BOM-marked UTF-16, and the existing Western fallback remain supported. All automatic legacy-encoding choices are explicitly uncertain: imported-file synchronization pauses using the existing persisted pause/error fields, preserving original bytes. No dependencies or job-format fields were added.

| Measurement | Before | After |
|---|---|---|
| Windows-1258 bytes `56 69 EA F2 74` | `Viêòt` (wrong) | `Việt` (correct) |
| Automatic source write-back permitted for ambiguous legacy import | Yes | No |
| 10k-cue UTF-8 SRT parse median, 10 warm invocations | 96.35 ms | 97.39 ms |
| Parse range | 95.43–97.04 ms | 95.51–99.53 ms |
| Parsed cue count | 10,000 | 10,000 |
| Full Swift suite | 459 passed | 461 passed |
| Python suite / compiler warnings | 8 passed / 0 | 8 passed / 0 |

The parser did not get faster: this run's median increased 1.04 ms. The item corrects decoding and protects source files; it does not claim a performance improvement. Synthetic fixture: 917,787 bytes, optimized compilation, same machine and warm filesystem. Tests cover the Vietnamese regression, modern Japanese/Vietnamese UTF-8, Western text, source-byte preservation, and the sync guard. Validation: `./script/run_tests.sh`.

Automatic detection cannot prove a legacy encoding. An explicit selector/preview is a separate behavior proposal; TCVN3/VNI and ASS are not implemented by this item.
