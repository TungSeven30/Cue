# Release and rollback runbook

## Preconditions

- Work from a clean `master` equal to `origin/master`; the version must have a
  matching `## MAJOR.MINOR.PATCH` section in `CHANGELOG.md`.
- Confirm the Developer ID Application identity, `whisperdesk-notary`
  notarytool profile, Sparkle private key, and `gh` access on the release Mac.
- Review dependency changes under `docs/dependency-policy.md`.

## Required rehearsal

Run `script/rehearse_release.sh VERSION`. It builds and notarizes the DMG,
validates Gatekeeper/stapling/signatures, mounts the image, performs real
Metal inference from the shipped app, and generates and validates a signed
appcast. It never tags, uploads, or publishes.

If only the final validation step needs repeating, use
`CUE_REHEARSAL_SKIP_BUILD=1 script/rehearse_release.sh VERSION` against the
already notarized `dist/Cue.dmg`.

## Production release

Run `script/release.sh VERSION` once. The script enforces the clean/up-to-date
guards, stamps the version, executes tests and the Swift 6 warnings-as-errors
build, creates and verifies the notarized artifact, archives it, generates a
SHA-256 file/SBOM/dependency evidence, creates the signed tag and canonical
GitHub release, and only then publishes the rolling Sparkle asset and signed
appcast.

Record the version, git commit/tag, notarization submission ID, DMG SHA-256,
canonical release URL, and cue-releases appcast commit in the release notes or
operator log. Verify the update from the previously released Cue version on a
separate macOS user or machine.

## Failure recovery by publication point

- Before the tag push: nothing is public. Preserve the version-stamp commit,
  fix the cause, rerun the complete rehearsal, and retry the release. Do not
  hand-edit the archived DMG.
- Tag/release exists but appcast publication failed: the authoritative release
  is valid but not advertised. Verify the archived artifact again, then run
  `CUE_SKIP_RELEASE_BUILD=1 script/release_update.sh VERSION`.
- Rolling asset uploaded but appcast push failed: rerun the same command; the
  upload is idempotent and the appcast commit is created only when changed.
- Appcast advertises a bad release: immediately stop promotion by reverting
  the appcast commit in `TungSeven30/cue-releases` and removing the bad rolling
  asset. Keep the canonical tag/release as incident evidence and mark it
  clearly as affected. Publish a fixed version with a strictly higher SemVer
  and CFBundleVersion; Sparkle rollback to a lower build is not the recovery
  mechanism.
- Signing/notarization compromise: stop publishing, revoke or rotate the
  affected credential through Apple/Sparkle/GitHub, preserve logs, and ship a
  new higher version only after the complete trust chain is re-established.

Never replace an already published version with different bytes. A changed
artifact always receives a new version and new provenance evidence.
