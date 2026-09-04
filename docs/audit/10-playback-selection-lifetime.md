# 10 — Clear playback when selection disappears

Selection changes pause playback. Clearing either single or multiple selection releases the AVPlayerItem and subtitle overlay. DetailView also clears playback when its selected media URL is absent. The controller resets its cached URL so selecting the same file again loads it normally.

| Same two deselection paths | Before | After |
|---|---:|---:|
| Old player items retained | 2/2 | 0/2 |
| Playback rate after deselection | 1.0 | 0.0 |
| Stale active cue / overlay retained | Yes | No |
| New regression assertion failures | 8 | 0 |
| Swift / Python tests | 479 / 8 passed | 480 / 8 passed |
| Compiler warnings | 0 | 0 |

Validation: `./script/run_tests.sh`, exercising both real AppModel selection APIs and AVPlayer state. Fixture media is not a decoded video, so this measures player lifecycle/rate, not audible playback or memory reclamation. No dependency, serialized-format, or appearance changes.
