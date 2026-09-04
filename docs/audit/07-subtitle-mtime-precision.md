# 07 — Preserve imported subtitle modification times

ImportedSubtitleSource retains the original modifiedAt field and adds optional numeric modifiedAtReferenceSeconds for fractional precision. New readers prefer the precise value; older readers still understand the original keys, and old files without the optional key still decode. The strict 1 ms external-change tolerance is unchanged.

| Measurement through actual JobStore save/load | Before | After |
|---|---:|---:|
| Modification-time round-trip error | 0.765432000 s | 0 s |
| Unchanged imported file still matches | No | Yes |
| Same-size file with mtime advanced 100 ms is rejected | Yes | Yes |
| Swift / Python tests | 472 / 8 passed | 474 / 8 passed |
| Compiler warnings | 0 | 0 |

Validation: `./script/run_tests.sh`, including a real temporary subtitle file, controlled fractional mtime, persistence flush, and reload. Historical fractional bits already lost by an older save cannot be reconstructed; those old associations retain conservative change detection until re-imported. No launch or playback performance improvement is claimed, and no dependencies were added.

A 100-date exact-round-trip regression also covers reference-epoch values that lose bits when converted through Unix time. The final codec stores reference-epoch seconds directly.
