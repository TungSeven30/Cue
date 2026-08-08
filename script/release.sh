#!/usr/bin/env bash
set -euo pipefail

# One-command release:
#   guards (clean master, up to date, new version, CHANGELOG entry)
#   -> version-stamp commit + complete test/build gates
#   -> notarized and verified DMG
#   -> annotated tag + canonical GitHub release
#   -> rolling download asset + Sparkle appcast (published last)
#
# Usage: script/release.sh 2.3.1

VERSION="${1:?usage: release.sh <version>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_REPO="TungSeven30/Cue"
ARCHIVE_DIR="$HOME/Library/Application Support/Cue/release-archive"
cd "$ROOT_DIR"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "version must be stable SemVer in MAJOR.MINOR.PATCH form."
[[ -z "$(git status --porcelain)" ]] || fail "working tree not clean; commit or stash first."
[[ "$(git rev-parse --abbrev-ref HEAD)" == "master" ]] || fail "releases are cut from master."
git fetch origin --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/master)" ]] || fail "master and origin/master differ; push or pull first."
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "tag v$VERSION already exists."

# The CHANGELOG section for this version doubles as the release notes.
NOTES="$(awk -v v="$VERSION" '
  $0 ~ "^## "v"( |$)" { found = 1; next }
  /^## / { found = 0 }
  found { print }
' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || fail "no '## $VERSION' section in CHANGELOG.md — write the notes first."

# Stamp the default version so the tagged commit reports itself correctly
# (and the stamp commit bumps the commit count Sparkle uses as CFBundleVersion).
/usr/bin/sed -E -i '' "s/(APP_VERSION:-)[0-9.]+\}/\1$VERSION}/" script/build_and_run.sh
if ! git diff --quiet; then
  git add script/build_and_run.sh
  git commit -m "Stamp release builds as version $VERSION"
fi

# Fail before notarization or publication if any behavioral, parity, or
# compiler-warning gate regressed.
"$ROOT_DIR/script/run_tests.sh"
swift build -c release -Xswiftc -warnings-as-errors

export APP_VERSION="$VERSION"
"$ROOT_DIR/script/build_and_run.sh" --release

mkdir -p "$ARCHIVE_DIR"
cp "$ROOT_DIR/dist/Cue.dmg" "$ARCHIVE_DIR/Cue-$VERSION.dmg"
hdiutil verify "$ARCHIVE_DIR/Cue-$VERSION.dmg" >/dev/null
codesign --verify --verbose=2 "$ARCHIVE_DIR/Cue-$VERSION.dmg"
xcrun stapler validate "$ARCHIVE_DIR/Cue-$VERSION.dmg"
python3 "$ROOT_DIR/script/audit_dependencies.py" \
  --output "$ARCHIVE_DIR/Cue-$VERSION-dependency-audit.json"
python3 "$ROOT_DIR/script/generate_sbom.py" --version "$VERSION" \
  --output "$ARCHIVE_DIR/Cue-$VERSION-sbom.cdx.json"
(
  cd "$ARCHIVE_DIR"
  shasum -a 256 "Cue-$VERSION.dmg" > "Cue-$VERSION.dmg.sha256"
)

git tag -a "v$VERSION" -m "Cue $VERSION"
git push --atomic origin master "v$VERSION"
gh release create "v$VERSION" \
  "$ARCHIVE_DIR/Cue-$VERSION.dmg" \
  "$ARCHIVE_DIR/Cue-$VERSION.dmg.sha256" \
  "$ARCHIVE_DIR/Cue-$VERSION-sbom.cdx.json" \
  "$ARCHIVE_DIR/Cue-$VERSION-dependency-audit.json" \
  --repo "$MAIN_REPO" --title "Cue $VERSION" --notes "$NOTES"

# The public appcast is the final publication point. If this step fails, the
# canonical tag and release remain valid and release_update.sh can be safely
# re-run without rebuilding by setting CUE_SKIP_RELEASE_BUILD=1.
CUE_SKIP_RELEASE_BUILD=1 "$ROOT_DIR/script/release_update.sh" "$VERSION"

echo ""
echo "Released Cue $VERSION: tested, notarized, tagged, on GitHub, and live in the update feed."
