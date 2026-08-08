# Dependency and supply-chain policy

Cue intentionally has two Swift dependencies: whisper.cpp and Sparkle. Both
are locked to reviewed immutable inputs in `Package.swift` and
`Package.resolved`. GitHub Actions are pinned to full commit SHAs, even when a
human-readable tag is recorded in a comment.

## Updating a dependency

1. Read the upstream release notes and security advisories between the old and
   proposed versions.
2. Inspect the upstream tag-to-commit mapping and record the immutable commit.
3. Update `Package.swift`, resolve the package, and review the entire
   `Package.resolved` diff. Do not accept unrelated transitive changes.
4. Update the allowlist in `script/audit_dependencies.py` in the same review.
5. Run `script/run_tests.sh`, the warnings-as-errors release build, bundle
   verification, and packaged inference.
6. For whisper.cpp changes, specifically prove runtime Metal loading from the
   shipped app. For Sparkle changes, run the nonpublishing signed-appcast and
   notarization rehearsal.

## Release evidence

Every canonical GitHub release includes the notarized DMG, its SHA-256 file, a
CycloneDX SBOM, and dependency-audit JSON. `script/audit_dependencies.py`
fails CI and release creation if the lockfile or workflow pins differ from the
reviewed policy.
