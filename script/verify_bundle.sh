#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: verify_bundle.sh <Cue.app> [expected-version]}"
EXPECTED_VERSION="${2:-}"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Cue"
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SHADER="$APP_BUNDLE/Contents/Resources/ggml-metal.metal"

fail() {
  echo "error: bundle verification failed: $*" >&2
  exit 1
}

[[ -d "$APP_BUNDLE" ]] || fail "$APP_BUNDLE does not exist"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [[ -n "$EXPECTED_VERSION" && "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  fail "expected version $EXPECTED_VERSION, found $ACTUAL_VERSION"
fi

[[ -x "$APP_BINARY" ]] || fail "Cue executable is missing or not executable"
EXPECTED_ARCH="${CUE_EXPECTED_ARCH:-$(uname -m)}"
ARCHITECTURES="$(lipo -archs "$APP_BINARY")"
case " $ARCHITECTURES " in
  *" $EXPECTED_ARCH "*) ;;
  *) fail "Cue executable architectures ($ARCHITECTURES) do not include $EXPECTED_ARCH" ;;
esac
[[ -d "$SPARKLE" ]] || fail "Sparkle.framework is missing"
otool -L "$APP_BINARY" | grep -Fq '@rpath/Sparkle.framework/' \
  || fail "Cue executable is not linked to embedded Sparkle"
otool -l "$APP_BINARY" | grep -Fq '@executable_path/../Frameworks' \
  || fail "Cue executable has no Frameworks rpath"

[[ -s "$SHADER" ]] || fail "merged whisper.cpp Metal shader is missing"
SHADER_MODE="$(stat -f '%Lp' "$SHADER")"
[[ "$SHADER_MODE" == "644" ]] || fail "Metal shader permissions are $SHADER_MODE, expected 644"
if grep -Fq '#include "ggml-common.h"' "$SHADER"; then
  fail "Metal shader still depends on the unbundled ggml-common.h"
fi

# Compile through the same runtime Metal API whisper.cpp uses. This catches
# missing headers and invalid merged source even on CLT-only build machines.
RUNTIME_METAL_OK=0
set +e
xcrun swift "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify_metal_shader.swift" "$SHADER"
RUNTIME_STATUS=$?
set -e
if [[ "$RUNTIME_STATUS" == "0" ]]; then
  RUNTIME_METAL_OK=1
elif [[ "$RUNTIME_STATUS" != "77" ]]; then
  fail "Metal's runtime compiler rejected the packaged shader"
fi

# Full Xcode provides the offline Metal compiler. Command Line Tools do not;
# the structural shader checks above still run there.
OFFLINE_METAL_OK=0
if xcrun -f metal >/dev/null 2>&1; then
  TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEMP_DIR"' EXIT
  xcrun metal -c "$SHADER" -o "$TEMP_DIR/ggml-metal.air"
  OFFLINE_METAL_OK=1
fi
if [[ "$RUNTIME_METAL_OK" != "1" && "$OFFLINE_METAL_OK" != "1" ]]; then
  fail "neither a Metal runtime device nor the offline Metal compiler is available"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null \
    || fail "code signature is invalid"
fi

echo "Verified Cue.app $ACTUAL_VERSION ($ARCHITECTURES executable, Sparkle, rpath, Metal resource, signature)."
