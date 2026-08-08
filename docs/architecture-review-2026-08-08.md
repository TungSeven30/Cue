# Cue architecture and delivery review — 2026-08-08

## Executive summary

Cue's core design is sound for a native desktop application: immutable job snapshots isolate runs from live settings, the GPU and translation lanes are modeled separately, native and Python transcription share post-processing, and per-job atomic files limit persistence blast radius. The test suite covers pure scheduling, parsing, migration, export, persistence-failure, and media logic with enforced coverage floors.

The one confirmed user-facing correctness defect was the documented standalone `transcribe.py` drifting from the embedded backend. Several delivery and durability risks could turn into equally serious failures: mutable/unverified model downloads, best-effort persistence that could silently lose data, stale asynchronous diagnostics, packaging steps that hid failures, and an update feed published before the canonical release. CI and an enforced formatter were also absent.

All locally actionable findings from this audit are now closed or guarded. The complete release artifact was notarized and exercised through Gatekeeper and real packaged Metal inference without publishing. The only evidence that necessarily remains external is a green GitHub-hosted CI run after these uncommitted changes are pushed and, for a real release, production publication itself.

## Findings and disposition

| Priority | Area | Finding | Impact | Disposition |
|---|---|---|---|---|
| P0 | Python backend | The embedded helper and root `transcribe.py` had roughly 450 changed lines. The standalone CLI lacked audio caching/`--audio-wav`, signal cleanup, and fallback cache-key behavior. | Documented CLI was slower and behaved differently; cancellation could orphan ffmpeg. | Fixed. The embedded source is canonical, a sync tool regenerates the CLI, and tests require byte-for-byte parity. |
| P1 | Model supply chain | Model URLs used the mutable `main` branch and accepted any completed download without a size/hash check. Existing partial files counted as installed. | A truncated, replaced, or upstream-mutated model could fail later or run untrusted bytes/data. | Fixed. URLs use an immutable revision; six built-in artifacts have pinned size/SHA-256 metadata; corrupt files are replaced; unknown downloads are refused. A metadata-bound stamp avoids rehashing unchanged multi-GB files. |
| P1 | Persistence | Keychain writes and several job/watch-history operations were best-effort. Legacy plaintext was removed even if Keychain migration failed; legacy job migration could advance after partial write failure. | Secrets or job history could disappear, or watched files could be re-queued, without an actionable UI error. | Fixed. Writes report success, migrations retain their source until complete, failures remain retryable/visible, unreadable inputs are preserved, and the app presents storage errors. |
| P1 | Release ordering | The Sparkle update was published before the git tag and canonical GitHub release. Direct update publication had no canonical-release guard. | Installed apps could be offered a version whose authoritative release did not exist; recovery was ambiguous. | Fixed. Tests/build/artifact verification run first, then tag and canonical release, then rolling asset and appcast. Update publication is guarded and rerunnable with an existing artifact. |
| P1 | App packaging | Packaging killed a running Cue process in every mode, tolerated `install_name_tool` failure, and only checked that shader text was copied. Sparkle absence was non-fatal. | A packaging-only command disrupted users; broken rpaths/frameworks or invalid Metal source could ship. | Fixed. `--bundle` is non-disruptive; Sparkle and rpath are mandatory; every bundle verifies plist/version, linking, signature, and shader resource. The packaged shader is compiled through Metal's runtime API, with the offline compiler as the headless-CI fallback. |
| P1 | Async state | Overlapping diagnostics runs could complete out of order and overwrite newer settings results. | UI could show a stale provider/backend readiness state. | Fixed and regression-tested. The prior task is canceled and only the newest snapshot may publish results. |
| P2 | Test seams | Translation/catalog code used `URLSession.shared` directly. `AppModel` constructed diagnostics/settings/job storage internally. | Provider and race behavior required live/global dependencies and was difficult to test deterministically. | Improved. A shared `HTTPClient` boundary covers API calls; diagnostics has a protocol; `AppModel` accepts isolated settings, storage, and diagnostics dependencies. Deterministic tests cover catalog HTTP status and diagnostics ordering. |
| P2 | Test discovery | Python checks were ad hoc, and standalone parity was not part of the main test command. | A green Swift run could miss backend regressions. | Fixed. `script/run_tests.sh` discovers Python unittests before executing the real Swift Testing entry point. |
| P2 | CI/style | No CI workflow or enforced formatter existed. Release warnings were not a gate. | Regressions depended on a release-machine manual checklist; formatting drift increased review noise. | Fixed. macOS CI runs Python/Swift tests, warnings-as-errors release build, parity, strict formatting, shell syntax, and app-bundle packaging. Swift sources were normalized; the verbatim embedded Python container is intentionally excluded. |
| P2 | State architecture | `AppModel` was the central owner of queue state, persistence batching, watch-service lifetimes, and export planning in addition to presentation state. | Changes had a wide review surface; orchestration tests required global state. | Improved incrementally. `JobRepository`, `PipelineCoordinator`, `WatchFolderCoordinator`, and `ExportCoordinator` now own those boundaries with characterization tests; AppModel remains the presentation/orchestration facade. |
| P1 | Packaged inference | Source/resource checks did not prove that the shipped executable could initialize whisper.cpp with its packaged Metal shader and model. | A structurally valid app could silently fall back to CPU or fail only after release. | Fixed and exercised. The shipped executable has an internal self-test; bundle/rehearsal gates run actual inference, require the packaged resource path and Apple GPU, and reject Metal fallback. Architecture is validated with `lipo`. |
| P1 | Release proof | Signing/notarization logic existed, but there was no safe end-to-end rehearsal of Gatekeeper, mounted-app inference, and signed appcast generation. | The first complete exercise could occur during a live release. | Fixed and exercised against the final source state. Apple accepted notarization submission `c6dfeed6-1450-48e4-8b9f-777dd83235dc`; the stapled DMG, mounted app, Gatekeeper, Metal inference, and signed appcast all passed without publication. |
| P2 | Language mode | The package used Swift 5 language mode despite a Swift 6 toolchain. | Strict concurrency defects stayed latent and future migration risk accumulated. | Fixed. Production and tests use Swift 6; an actor-isolation defect in player observer cleanup was corrected; warnings-as-errors release compilation and all tests pass. |
| P2 | Dependency provenance | Sparkle allowed a version range and GitHub Actions used a mutable major tag; releases emitted no machine-readable dependency evidence. | Builds and CI could resolve reviewed names to changed code; consumers lacked provenance artifacts. | Fixed. Swift dependencies and Actions use immutable reviewed pins. CI/release audit the allowlist; canonical releases include SHA-256, CycloneDX SBOM, and dependency JSON. |
| P2 | Coverage | Tests were numerous but no measured coverage policy existed. | Large untested regressions could accumulate behind a green test count. | Fixed. CI enforces whole-app, Models/Services, and critical-file line floors from a tracked policy. Current measured coverage is 22.00% whole app and 50.93% Models/Services; critical files range from 54.69% to 96.77%. |
| P2 | Operations/security | No repository security policy, threat model, dependency policy, rollback procedure, or data-recovery runbook existed. | Incident handling and recovery depended on undocumented maintainer knowledge. | Fixed. Policies and runbooks now document trust boundaries, residual risks, credential handling, release recovery by publication point, and per-job restoration. |

## Implementation plan

### Phase 1 — correctness and reproducibility (completed)

1. Make the embedded backend the single source of truth.
2. Regenerate `transcribe.py` and fail tests on drift.
3. Discover all Python behavioral tests from the main test command.
4. Cancel and gate overlapping diagnostics runs.
5. Build release configuration with warnings as errors.

### Phase 2 — durability and integrity (completed)

1. Pin model revision, byte counts, and SHA-256 digests.
2. Verify old installs once and every new download; invalidate verification when file metadata changes.
3. Preserve legacy secrets until Keychain confirms replacement and retry failed writes.
4. Make job migration transactional at the source-file level, keep decoded jobs visible after a partial migration, preserve corrupt inputs, and surface persistence failures.

### Phase 3 — testable boundaries (completed for current risk areas)

1. Add an injectable HTTP client for translation, summaries, and model catalog calls.
2. Add a diagnostics protocol and dependency-injected `AppModel` initializer.
3. Add deterministic regression tests for HTTP failures, download integrity, Keychain retry behavior, and stale diagnostics.

### Phase 4 — build and release gates (completed)

1. Add a non-launching, non-killing bundle mode.
2. Make embedded Sparkle and rpath setup mandatory.
3. Verify the actual packaged Metal source with a compiler, not string checks alone.
4. Validate version, signature, notarization/stapling, and DMG before publication.
5. Publish the canonical release before the Sparkle feed.
6. Add CI, shell syntax checks, strict Swift formatting, and warnings-as-errors.

### Phase 5 — incremental `AppModel` decomposition (completed for audited boundaries)

This is a maintainability program, not a release blocker. Preserve behavior and move one tested responsibility at a time:

1. `JobRepository` owns immutable pending snapshots, debounce/coalescing, delete cancellation, and termination flush; `JobStore` remains the disk adapter behind `JobPersisting`.
2. `PipelineCoordinator` owns slot tasks/IDs, FIFO translation handoffs, targeted removal, and app-wide cancellation; `PipelineScheduler` remains the pure selection policy.
3. `ExportCoordinator` owns deterministic document plans, safe names, extension normalization, bilingual construction, intro application, and sidecar writing.
4. `WatchFolderCoordinator` owns live-service reconciliation, restart/stop behavior, and observation lifetimes.
5. `AppModel` remains the `@MainActor` presentation facade and domain orchestrator. Progressive-translation behavior, alerts, and burn-in stay there because moving them offered no independent correctness gain in this pass.
6. Characterization tests cover each new boundary without changing persisted formats or job-state transitions.

### Phase 6 — audit evidence and operations (completed)

1. Move production and test targets to Swift 6 language mode.
2. Add deterministic disk-operation injection and recovery tests for create, list, read, write, and legacy-move failures.
3. Pin dependency and workflow inputs, audit them in CI/release, and generate SBOM/checksum evidence.
4. Measure coverage and enforce total, domain, and critical-file floors.
5. Add security, dependency, release/rollback, and data-recovery runbooks.
6. Execute the notarized nonpublishing release rehearsal and shipped-app inference gate.

## Verification baseline after the changes

- `script/run_coverage.sh`: 4 Python tests and 214 Swift tests; the integration test loads the same self-contained shader used by the app on Apple M5 Max Metal, and enforced coverage passes (22.00% total, 50.93% Models/Services).
- `swift build -c release -Xswiftc -warnings-as-errors`: passes.
- `script/lint_swift.sh`: passes in strict mode.
- `python3 script/sync_backend_script.py --check`: exact backend parity.
- `python3 script/audit_dependencies.py`: exact Swift dependency and full-SHA Actions policy passes; deterministic CycloneDX generation passes.
- `script/build_and_run.sh --bundle`: produces a signed, structurally verified arm64 application bundle without launching or terminating Cue; packaged `ggml-metal.metal` runtime-compiles to 225 functions.
- `script/verify_packaged_inference.sh dist/Cue.app`: actual ggml-tiny inference uses `dist/Cue.app/Contents/Resources` and Apple M5 Max Metal; no fallback.
- `script/rehearse_release.sh 2.3.1`: Developer ID signing, Apple notarization, stapling, DMG verification, Gatekeeper, mounted-app bundle/inference checks, and signed appcast validation pass; nothing uploaded or published.

## Remaining external confirmation

- Push the change set through the repository's normal review process and
  require the new GitHub Actions workflow to pass on the hosted `macos-15`
  runner. Local execution covers the same commands, but cannot manufacture a
  GitHub check-run record without publishing the branch.
- A production release remains an explicit maintainer action. The audit used
  the nonpublishing rehearsal by design and did not create tags, releases,
  uploads, or appcast commits.
