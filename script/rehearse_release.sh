#!/usr/bin/env bash
set -euo pipefail

# Builds and notarizes the real release artifact, mounts it, exercises the app
# inside, and generates a signed appcast in a temporary directory. It never
# creates/pushes a tag, uploads an asset, changes a release, or publishes a
# feed.
VERSION="${1:?usage: rehearse_release.sh <version>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="$ROOT_DIR/dist/Cue.dmg"
TEMP_DIR="$(mktemp -d)"
MOUNT_POINT="$TEMP_DIR/mount"
MOUNTED=0

fail() {
  echo "error: release rehearsal failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "version must be stable SemVer in MAJOR.MINOR.PATCH form"

APPCAST_TOOL="$(find "$ROOT_DIR/.build/artifacts" -name generate_appcast -type f | head -1)"
[[ -x "$APPCAST_TOOL" ]] || fail "Sparkle generate_appcast is unavailable; run swift build first"

echo "Building and notarizing Cue $VERSION without publishing…"
if [[ "${CUE_REHEARSAL_SKIP_BUILD:-0}" == "1" ]]; then
  [[ -f "$DMG" ]] || fail "CUE_REHEARSAL_SKIP_BUILD=1 but $DMG is missing"
  echo "Reusing existing notarized $DMG."
else
  APP_VERSION="$VERSION" "$ROOT_DIR/script/build_and_run.sh" --release
fi

hdiutil verify "$DMG" >/dev/null
codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
MOUNTED_APP="$MOUNT_POINT/Cue.app"
[[ -d "$MOUNTED_APP" ]] || fail "mounted image does not contain Cue.app"

CUE_EXPECTED_ARCH="${CUE_EXPECTED_ARCH:-arm64}" \
  "$ROOT_DIR/script/verify_bundle.sh" "$MOUNTED_APP" "$VERSION"
spctl --assess --type execute --verbose=2 "$MOUNTED_APP"
"$ROOT_DIR/script/verify_packaged_inference.sh" "$MOUNTED_APP"

ARCHIVE="$TEMP_DIR/archive"
mkdir -p "$ARCHIVE"
cp "$DMG" "$ARCHIVE/Cue-$VERSION.dmg"
"$APPCAST_TOOL" "$ARCHIVE" \
  --download-url-prefix "https://github.com/TungSeven30/cue-releases/releases/download/stable/"
APPCAST="$ARCHIVE/appcast.xml"
[[ -s "$APPCAST" ]] || fail "generate_appcast did not create appcast.xml"
grep -Fq "Cue-$VERSION.dmg" "$APPCAST" || fail "appcast does not reference the rehearsed artifact"
grep -Fq 'sparkle:edSignature=' "$APPCAST" || fail "appcast enclosure has no EdDSA signature"
grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" \
  || fail "appcast version does not match $VERSION"

echo "Release rehearsal passed: Developer ID, notarization, stapling, Gatekeeper, mounted app, Metal inference, and signed appcast."
echo "Nothing was uploaded or published."
