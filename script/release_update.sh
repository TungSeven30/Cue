#!/usr/bin/env bash
set -euo pipefail

# Publishes a Sparkle update end-to-end:
#   1. Verify the canonical tag/release already exists (the appcast is never
#      allowed to advertise an unpublished release)
#   2. Notarized Developer ID DMG (build_and_run.sh --release), or reuse the
#      already verified dist/Cue.dmg with CUE_SKIP_RELEASE_BUILD=1
#   3. DMG uploaded as an asset of the rolling "stable" release on the
#      public TungSeven30/cue-releases repo (single URL prefix, which is
#      what generate_appcast wants)
#   4. appcast.xml regenerated (EdDSA-signed from the login Keychain) and
#      pushed to cue-releases main, where installed apps poll it
#
# Usage: script/release_update.sh <version>     e.g. script/release_update.sh 2.3.0
#
# One-time machine setup: Sparkle's generate_keys, a Developer ID cert, and
# notarytool credentials (see README). The archive of past DMGs lives in
# ~/Library/Application Support/Cue/release-archive so the appcast keeps
# older entries; don't delete it casually.

VERSION="${1:?usage: release_update.sh <version>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASES_REPO="TungSeven30/cue-releases"
MAIN_REPO="TungSeven30/Cue"
DOWNLOAD_PREFIX="https://github.com/$RELEASES_REPO/releases/download/stable/"
ARCHIVE_DIR="$HOME/Library/Application Support/Cue/release-archive"
DMG="$ROOT_DIR/dist/Cue.dmg"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "version must be stable SemVer in MAJOR.MINOR.PATCH form."

if [[ "${CUE_ALLOW_UNRELEASED_UPDATE:-0}" != "1" ]]; then
  gh release view "v$VERSION" --repo "$MAIN_REPO" >/dev/null 2>&1 \
    || fail "canonical $MAIN_REPO release v$VERSION does not exist; run script/release.sh first."
fi

APPCAST_TOOL="$(find "$ROOT_DIR/.build/artifacts" -name generate_appcast -type f | head -1)"
if [[ -z "$APPCAST_TOOL" ]]; then
  echo "error: generate_appcast not found; run 'swift build' first so SwiftPM fetches Sparkle." >&2
  exit 1
fi

export APP_VERSION="$VERSION"
if [[ "${CUE_SKIP_RELEASE_BUILD:-0}" == "1" ]]; then
  [[ -f "$DMG" ]] || fail "CUE_SKIP_RELEASE_BUILD=1 but $DMG is missing."
else
  "$ROOT_DIR/script/build_and_run.sh" --release
fi

hdiutil verify "$DMG" >/dev/null
codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"

mkdir -p "$ARCHIVE_DIR"
cp "$DMG" "$ARCHIVE_DIR/Cue-$VERSION.dmg"

"$APPCAST_TOOL" "$ARCHIVE_DIR" --download-url-prefix "$DOWNLOAD_PREFIX"

# Rolling "stable" release holds every DMG so one URL prefix covers all.
if ! gh release view stable --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  gh release create stable --repo "$RELEASES_REPO" --title "Cue downloads" \
    --notes "Update archives served to the in-app Sparkle updater."
fi
gh release upload stable "$ARCHIVE_DIR/Cue-$VERSION.dmg" --repo "$RELEASES_REPO" --clobber
# Unversioned alias so the landing-page URL
# .../releases/latest/download/Cue.dmg never needs a bump.
cp "$ARCHIVE_DIR/Cue-$VERSION.dmg" "$ARCHIVE_DIR/Cue.dmg"
gh release upload stable "$ARCHIVE_DIR/Cue.dmg" --repo "$RELEASES_REPO" --clobber

# Publish the regenerated appcast.
staging="$(mktemp -d)"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT
git clone --depth 1 "git@github.com:$RELEASES_REPO.git" "$staging/cue-releases"
cp "$ARCHIVE_DIR/appcast.xml" "$staging/cue-releases/appcast.xml"
git -C "$staging/cue-releases" add appcast.xml
if git -C "$staging/cue-releases" diff --cached --quiet; then
  echo "appcast unchanged; nothing to push."
else
  git -C "$staging/cue-releases" commit -m "Publish Cue $VERSION"
  git -C "$staging/cue-releases" push
fi

echo ""
echo "Published Cue $VERSION — installed apps will offer the update on their next check."
