# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting flow for this repository
(Security → Advisories → Report a vulnerability). Do not open a public issue
for an unpatched vulnerability or include API keys, transcripts, source media,
notarization credentials, or signing material in a report.

Include the affected Cue version and macOS version, a minimal reproduction,
the expected/observed impact, and whether the issue requires a configured
cloud provider or optional Python backend. Maintainers should acknowledge a
complete report within seven days and coordinate disclosure after a fix is
available.

## Supported versions

Security fixes are released on the current stable line. Older releases should
be upgraded through Cue's signed Sparkle update flow or the latest notarized
DMG. Release artifacts include a SHA-256 file, CycloneDX SBOM, and dependency
audit evidence.
