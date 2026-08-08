#!/usr/bin/env bash
set -euo pipefail

# One-command release:
#   guards (clean master, up to date, new version, CHANGELOG entry)
#   -> version-stamp commit
#   -> notarized DMG + Sparkle publish (release_update.sh)
#   -> annotated git tag, pushed
#   -> GitHub release on the main repo with the DMG attached,
#      using this version's CHANGELOG section as the notes
#
# Usage: script/release.sh 2.3.1

VERSION="${1:?usage: release.sh <version>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_REPO="TungSeven30/Cue"
ARCHIVE_DIR="$HOME/Library/Application Support/Cue/release-archive"
cd "$ROOT_DIR"

fail() { echo "error: $*" >&2; exit 1; }

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

"$ROOT_DIR/script/release_update.sh" "$VERSION"

git tag -a "v$VERSION" -m "Cue $VERSION"
git push origin master "v$VERSION"
gh release create "v$VERSION" "$ARCHIVE_DIR/Cue-$VERSION.dmg" \
  --repo "$MAIN_REPO" --title "Cue $VERSION" --notes "$NOTES"

echo ""
echo "Released Cue $VERSION: tagged, on GitHub, and live in the update feed."
