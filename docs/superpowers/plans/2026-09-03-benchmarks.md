# Performance pass 2026-09-03 — before/after

Machine: Apple M5 Max, macOS 26, Swift 6 CLT toolchain. Model for native
runs: `ggml-tiny.bin` (the only installed GGML model; the default
large-v3-turbo-q5_0 was not on this machine). Python backends installed:
mlx-whisper 0.4.3 (large-v3-turbo), mlx-qwen3-asr 0.3.5 (Qwen3-ASR-1.7B),
faster-whisper 1.2.1 (large-v3-turbo, int8 CPU). Fixture for engine and
Python rows: a 17 s spoken clip from the system voice.

"Debug bundle" rows come from `CUE_BENCH=1` in the test bundle (debug
build); they compare before/after fairly but their absolute values are
slower than the shipped release binary. "Release harness" rows are from
standalone `swiftc -O` / C harnesses linked against the same code.

| Benchmark | Before | After | Change |
|---|---|---|---|
| Launch: decode 574 job files, 68.5 MB (debug bundle) | 0.949 s | 0.163 s | 5.8× |
| Chunk planner, 2-hour signal (debug bundle) | 4.524 s | 0.055 s | 82× |
| Chunk planner, 2-hour signal (release harness) | 0.049 s | 0.006 s | 8× |
| PCM16→Float, 2-hour WAV (debug bundle) | 8.745 s | 0.152 s | 58× |
| PCM16→Float, 2-hour WAV (release harness) | 0.232 s | 0.020 s | 11×, bit-exact |
| Native engine, first job (tiny, cold cache) | 0.265 s | 0.217 s | 1.2× |
| Native engine, second job (tiny) | 0.213 s | 0.144 s | 1.5× (model load skipped) |
| Native engine, third job (tiny) | 0.214 s | 0.145 s | 1.5× |
| Python mlx-whisper, first job | 1.574 s (one-shot) | 1.080 s (worker spawn) | 1.5× |
| Python mlx-whisper, subsequent job | 1.284 s (one-shot) | 0.203 s (resident) | 6.3× |
| Python Qwen3-ASR, first job | 5.255 s | 3.290 s | 1.6× |
| Python Qwen3-ASR, subsequent job | 3.324 s | 1.848 s | 1.8× |
| Python faster-whisper, first job | 7.189 s | 6.797 s | 1.06× (CPU inference bound) |
| Python faster-whisper, subsequent job | 6.602 s | 5.226 s | 1.3× |
| Main-thread work per streamed batch, 600-job history (debug bundle) | 0.698 ms | 0.587 ms | 1.2× |
| Watch-folder ingest of 200 files, incl. store flush (debug bundle) | 0.043 s | 0.037 s | 1.2× |
| Nested watch-folder drop reported after | ≤ 60 s (timer) | 2.7 s | — |
| Native audio extraction, 30 min AAC (release harness) | 0.41 s | 0.41 s | unchanged (measured, not a bottleneck) |
| Full test suite via `script/run_tests.sh` | hung (killed after 836 s) | 456 tests pass in 9.4 s | deadlock fixed |

Output identity checks that passed alongside the numbers:

- Native engine: resident weights + fresh state == cold load, byte for byte;
  multi-chunk runs identical across three runs including a cold reload
  (`WhisperEngineDeterminismTests`).
- Python: for all three backends the resident worker's segments equal the
  one-shot helper's and are identical across three worker runs
  (`BenchmarkTests.pythonWorkerFirstAndSecondRunPerBackend`).
- Planner: vDSP decisions identical to the scalar reference on tone/silence,
  noise, near-silent gaps, full scale, all-zero, and short signals
  (`ChunkPlannerVectorTests`).

Where the native "second job" saving comes from: with tiny the model load is
about 60 ms, so the per-job saving here is small. For the default
large-v3-turbo-q5_0 (574 MB) the skipped work per job is the file read plus
Metal upload, estimated at 0.5–1.5 s per job on this class of machine; run
the `nativeEngineFirstAndSecondRun` benchmark once that model is installed
to get the real number.
