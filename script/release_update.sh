#!/usr/bin/env bash
set -euo pipefail

# Publishes a Sparkle update end-to-end:
#   1. Notarized Developer ID DMG (build_and_run.sh --release)
#   2. DMG uploaded as an asset of the rolling "stable" release on the
#      public TungSeven30/cue-releases repo (single URL prefix, which is
#      what generate_appcast wants)
#   3. appcast.xml regenerated (EdDSA-signed from the login Keychain) and
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
DOWNLOAD_PREFIX="https://github.com/$RELEASES_REPO/releases/download/stable/"
ARCHIVE_DIR="$HOME/Library/Application Support/Cue/release-archive"

APPCAST_TOOL="$(find "$ROOT_DIR/.build/artifacts" -name generate_appcast -type f | head -1)"
if [[ -z "$APPCAST_TOOL" ]]; then
  echo "error: generate_appcast not found; run 'swift build' first so SwiftPM fetches Sparkle." >&2
  exit 1
fi

export APP_VERSION="$VERSION"
"$ROOT_DIR/script/build_and_run.sh" --release

mkdir -p "$ARCHIVE_DIR"
cp "$ROOT_DIR/dist/Cue.dmg" "$ARCHIVE_DIR/Cue-$VERSION.dmg"

"$APPCAST_TOOL" "$ARCHIVE_DIR" --download-url-prefix "$DOWNLOAD_PREFIX"

# Rolling "stable" release holds every DMG so one URL prefix covers all.
if ! gh release view stable --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  gh release create stable --repo "$RELEASES_REPO" --title "Cue downloads" \
    --notes "Update archives served to the in-app Sparkle updater."
fi
gh release upload stable "$ARCHIVE_DIR/Cue-$VERSION.dmg" --repo "$RELEASES_REPO" --clobber

# Publish the regenerated appcast.
staging="$(mktemp -d)"
git clone --depth 1 "git@github.com:$RELEASES_REPO.git" "$staging/cue-releases"
cp "$ARCHIVE_DIR/appcast.xml" "$staging/cue-releases/appcast.xml"
git -C "$staging/cue-releases" add appcast.xml
if git -C "$staging/cue-releases" diff --cached --quiet; then
  echo "appcast unchanged; nothing to push."
else
  git -C "$staging/cue-releases" commit -m "Publish Cue $VERSION"
  git -C "$staging/cue-releases" push
fi
rm -rf "$staging"

echo ""
echo "Published Cue $VERSION — installed apps will offer the update on their next check."
