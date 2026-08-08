#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Cue"
BUNDLE_ID="com.local.Cue"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${APP_VERSION:-2.3.0}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
# Public half of the Sparkle EdDSA pair; the private key lives in the
# login Keychain of the release machine (generate_keys).
SPARKLE_PUBLIC_KEY="enyN4b2NQyac4vMMX3Zp8dge4IYwiXX5ysBYLIunnBg="
SPARKLE_FEED_URL="https://raw.githubusercontent.com/TungSeven30/cue-releases/main/appcast.xml"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Sparkle compares CFBundleVersion, so releases need a strictly increasing
# build number; the commit count provides one with no bookkeeping.
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="AppIcon.icns"
ICON_SOURCE="$ROOT_DIR/Resources/$ICON_FILE"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

build_bundle() {
  local configuration="${1:-debug}"
  local swift_args=()
  if [[ "$configuration" == "release" ]]; then
    swift_args=(-c release)
  fi

  # ${arr[@]+...} guards the empty-array case: macOS's bash 3.2 treats an
  # empty "${arr[@]}" as an unbound variable under set -u.
  swift build ${swift_args[@]+"${swift_args[@]}"}
  BUILD_DIR="$(swift build ${swift_args[@]+"${swift_args[@]}"} --show-bin-path)"
  BUILD_BINARY="$BUILD_DIR/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  # Sparkle ships as a framework SwiftPM leaves next to the binary; embed it
  # and point the binary's rpath at the bundle's Frameworks directory.
  if [[ -d "$BUILD_DIR/Sparkle.framework" ]]; then
    mkdir -p "$APP_CONTENTS/Frameworks"
    cp -R "$BUILD_DIR/Sparkle.framework" "$APP_CONTENTS/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY" 2>/dev/null || true
  fi
  if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$APP_RESOURCES/$ICON_FILE"
  fi
  # Menu-bar template icon (18pt + @2x), loaded via Bundle.image(forResource:).
  for menubar_icon in "MenuBarIconTemplate.png" "MenuBarIconTemplate@2x.png"; do
    if [[ -f "$ROOT_DIR/Resources/$menubar_icon" ]]; then
      cp "$ROOT_DIR/Resources/$menubar_icon" "$APP_RESOURCES/$menubar_icon"
    fi
  done
  # whisper.cpp compiles its Metal shaders at runtime from ggml-metal.metal.
  # SwiftPM ships that file in a resource bundle whose accessor looks at the
  # .app root (where codesign forbids content), and the raw file cannot
  # compile anyway: Metal's runtime compiler has no include path for its
  # `#include "ggml-common.h"`. Inline the header (upstream's embed step does
  # the same merge) and ship the self-contained shader in Resources;
  # WhisperCppEngine points ggml at it via GGML_METAL_PATH_RESOURCES.
  local ggml_src="$ROOT_DIR/.build/checkouts/whisper.cpp/ggml/src"
  if [[ ! -f "$ggml_src/ggml-common.h" || ! -f "$ggml_src/ggml-metal.metal" ]]; then
    echo "error: whisper.cpp shader sources not found under $ggml_src;" >&2
    echo "the checkout layout changed — update the shader-merge step." >&2
    exit 1
  fi
  awk '/#include "ggml-common.h"/ {
         while ((getline line < common) > 0) print line
         close(common); next
       } { print }' \
    common="$ggml_src/ggml-common.h" \
    "$ggml_src/ggml-metal.metal" > "$APP_RESOURCES/ggml-metal.metal"
  grep -q 'ggml-common.h' "$APP_RESOURCES/ggml-metal.metal" && {
    echo "error: ggml-common.h was not inlined into ggml-metal.metal" >&2
    exit 1
  }

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.video</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © $(date +%Y). All rights reserved.</string>
</dict>
</plist>
PLIST

  /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
  if command -v codesign >/dev/null 2>&1; then
    # A stable local identity keeps the app's code signature constant across
    # rebuilds, so Keychain "Always Allow" grants persist. Ad-hoc signing (-)
    # changes every build and re-triggers the password prompt each install.
    # The cert keeps its WhisperDesk-era name: renaming it would mint a new
    # identity and void every Keychain "Always Allow" grant on this Mac.
    local identity="${SIGN_IDENTITY:-WhisperDesk Local Signing}"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$identity"; then
      # An expired or untrusted local cert must not abort the build silently
      # (set -e); report it and fall back to ad-hoc signing.
      if ! codesign --force --deep --sign "$identity" "$APP_BUNDLE"; then
        echo "warning: signing with '$identity' failed; falling back to ad-hoc signing" >&2
        codesign --force --deep --sign - "$APP_BUNDLE"
      fi
    else
      codesign --force --deep --sign - "$APP_BUNDLE"
    fi
  fi
}

# Builds a Developer ID-signed, notarized DMG ready to share with other Macs.
# One-time setup (see script comments / README):
#   1. Install a "Developer ID Application" certificate in the keychain.
#   2. xcrun notarytool store-credentials whisperdesk-notary \
#        --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
make_release_dmg() {
  local identity="${DEV_ID_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  fi
  if [[ -z "$identity" ]]; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "Create one at developer.apple.com (Account > Certificates > Developer ID Application)," >&2
    echo "install it in Keychain Access, then re-run. Or pass DEV_ID_IDENTITY explicitly." >&2
    exit 1
  fi
  # Profile name predates the Cue rename; stored notarytool credentials are
  # keyed to it, so keep it unless you re-run store-credentials.
  local notary_profile="${NOTARY_PROFILE:-whisperdesk-notary}"

  build_bundle release
  # Replace the local dev signature with the distribution one: Developer ID,
  # hardened runtime, and a secure timestamp are all required by notarization.
  # --deep so the embedded Sparkle framework gets the Developer ID
  # signature too; notarization rejects mixed-identity nesting.
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$APP_BUNDLE"
  codesign --verify --strict --verbose=2 "$APP_BUNDLE"

  local staging
  staging="$(mktemp -d)"
  cp -R "$APP_BUNDLE" "$staging/"
  ln -s /Applications "$staging/Applications"
  local dmg="$DIST_DIR/$APP_NAME.dmg"
  rm -f "$dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO "$dmg"
  rm -rf "$staging"
  # Sign the DMG container too, so the image itself passes signature
  # evaluation (the app inside is what Gatekeeper ultimately assesses).
  codesign --force --timestamp --sign "$identity" "$dmg"

  echo "Submitting $dmg to Apple for notarization (profile: $notary_profile)…"
  if ! xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait; then
    echo "error: notarization failed. If credentials are missing, run the one-time setup:" >&2
    echo "  xcrun notarytool store-credentials $notary_profile --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID" >&2
    echo "On a rejected submission, inspect the log:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $notary_profile" >&2
    exit 1
  fi
  xcrun stapler staple "$dmg"
  echo ""
  echo "Ready to share: $dmg"
  echo "Recipients can open it on any Mac with no Gatekeeper warnings."
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

open_installed_app() {
  local app_path="$1"
  /usr/bin/open -n "$app_path"
}

register_app() {
  local app_path="$1"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$app_path" >/dev/null 2>&1 || true
  fi
}

install_app() {
  build_bundle release

  local target_dir="$INSTALL_DIR"
  if [[ "$target_dir" == "/Applications" && ! -w "$target_dir" ]]; then
    target_dir="$HOME/Applications"
  fi
  mkdir -p "$target_dir"

  local installed_app="$target_dir/$APP_NAME.app"
  rm -rf "$installed_app"
  /usr/bin/ditto "$APP_BUNDLE" "$installed_app"
  xattr -dr com.apple.quarantine "$installed_app" >/dev/null 2>&1 || true
  register_app "$installed_app"

  echo "Installed $installed_app"
  open_installed_app "$installed_app"
  rm -rf "$APP_BUNDLE"
}

case "$MODE" in
  run)
    build_bundle debug
    open_app
    ;;
  --debug|debug)
    build_bundle debug
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_bundle debug
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_bundle debug
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    build_bundle debug
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --install|install)
    install_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --release|release)
    make_release_dmg
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install|--release]" >&2
    exit 2
    ;;
esac
