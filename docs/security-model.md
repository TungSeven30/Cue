# Security model

## Protected assets

- User media, transcripts, translations, summaries, job logs, and watch-folder
  history.
- Cloud-provider API keys stored as generic-password items in the login
  Keychain under service `com.local.Cue`.
- The Developer ID identity, Apple notarization credential profile, Sparkle
  private key, and GitHub credentials on the release machine.
- Executable code and model bytes consumed by the transcription pipeline.

## Trust boundaries and data flow

Cue reads files the user selects and enabled watch folders. Built-in
transcription stays in-process and local. Optional Python backends execute the
generated helper plus locally installed Python packages; they and ffmpeg are
therefore trusted local executables. Translation and intro summaries send
subtitle text—not source audio/video—only to the explicitly selected HTTPS
provider or configured local-server URL. A summary fallback is opt-in and runs
only after a typed policy/safety refusal; ordinary failures never route text to
another provider.

The app is Developer ID signed and notarized but is not App Sandbox confined.
That is an explicit product constraint: it must read arbitrary user-selected
media, continuously monitor external-volume folders, invoke optional local
tools, and write sidecars next to source files. The consequence is that a
compromised Cue process has the same file access granted to the current user;
input parsing, dependency integrity, and signed delivery are primary controls.

## Controls

- API keys use Keychain `kSecAttrAccessibleWhenUnlocked`. Failed writes remain
  visible and legacy plaintext is retained until migration succeeds.
- Built-in model downloads use immutable upstream revisions plus pinned byte
  counts and SHA-256 digests. Unknown artifacts are refused.
- The Python helper has one canonical embedded source; generated standalone
  parity is a test and CI gate. Child processes receive cancellation signals
  and cleanup is tested.
- Job files are one-per-job atomic JSON snapshots. Corrupt inputs are copied to
  recovery files and never silently overwritten. Disk failures are surfaced.
- Swift dependencies, the lockfile, and GitHub Actions commits are allowlisted;
  CI and releases generate dependency evidence and a CycloneDX SBOM.
- Release bundles verify architecture, Sparkle linkage/rpath, code signatures,
  runtime Metal shader loading, notarization, stapling, and Gatekeeper. The
  Sparkle appcast is signed and is published only after the canonical release.

## Residual risks

- A user-installed Python package, ffmpeg binary, or local translation server
  is outside Cue's supply-chain controls. Use the built-in engine for the
  smallest trust surface.
- Cloud providers receive subtitle text when configured; their retention and
  account policies apply. Local transcription alone sends no media to Cue's
  maintainers or a cloud service.
- Job JSON and watch history are not encrypted at rest beyond macOS filesystem
  protections. Do not place sensitive media on an untrusted or unencrypted
  user account.
- The release machine remains a high-value system. Its private keys must never
  enter the repository, CI variables, release assets, logs, or support bundles.

## Security review triggers

Repeat threat review and the release rehearsal when adding a new network
endpoint, executable subprocess, persistent data class, file parser, update
channel, entitlement, dependency, or model source. Follow
`docs/dependency-policy.md` for dependency changes and `docs/release-runbook.md`
for artifact publication.
