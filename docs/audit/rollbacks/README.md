# Independent rollback

Each audit item has one implementation commit. Several items touch the same functions and tests, so plain out-of-order `git revert` conflicts for items 1, 2, 3, 6, and 8. The numbered patches resolve those conflicts against the completed audited source while retaining the other items.

From a clean checkout, check a rollback without changing anything:

```sh
python3 script/audit/revert_item.py 8
```

To stage that one rollback for review:

```sh
python3 script/audit/revert_item.py 8 --apply
git diff --cached
./script/run_tests.sh
```

The tool does not commit, reset, or discard edits. It refuses a dirty checkout, changed source/test history, or a patch checksum mismatch. These patches target the completed audited source. Applying multiple rollbacks together or applying one after subsequent source changes requires fresh conflict review and validation.

## Compatibility retained

- Item 2: removing Vietnamese detection and legacy-write protection leaves the decoded-text wrapper that the later parser item uses.
- Item 8: removing picker-time target/activity validation leaves compatible request fields and item 11's checks across its asynchronous backup operation. These are necessary to preserve item 11.
- Item 14: removing runtime instrumentation and ledger injection leaves audit evidence and this rollback utility available.

Each patch removes the item's corresponding regression tests. The remaining suite is run to verify that the other fixes continue to work. This checks independent rollback compatibility; it does not claim the removed behavior is safe. Rollbacks deliberately restore the original bugs.

The utility also has six synthetic Git-repository tests covering dry runs, staged application without a commit, local edits, source-history changes, checksum failures, and invalid item numbers.

## Recorded validation

All 14 variants built successfully with zero compiler warnings. Each passed its remaining Swift suite, all eight existing Python tests, and the six rollback-utility tests. The complete branch separately passed 495 Swift and 14 Python tests and the release bundle verification.

| Rolled-back item | Remaining Swift tests passed | Python tests passed | Compiler warnings |
| --- | ---: | ---: | ---: |
| 1 | 492 | 14 | 0 |
| 2 | 493 | 14 | 0 |
| 3 | 492 | 14 | 0 |
| 4 | 490 | 14 | 0 |
| 5 | 493 | 14 | 0 |
| 6 | 494 | 14 | 0 |
| 7 | 493 | 14 | 0 |
| 8 | 493 | 14 | 0 |
| 9 | 492 | 14 | 0 |
| 10 | 494 | 14 | 0 |
| 11 | 490 | 14 | 0 |
| 12 | 489 | 14 | 0 |
| 13 | 492 | 14 | 0 |
| 14 | 494 | 14 | 0 |

[Machine-readable results](validation.json) record the actual test summaries. The first attempt to share a compiler cache across checkout paths failed with a Clang module-path error; the accepted runs used a separate build cache. Only the accepted runs appear in the table.
