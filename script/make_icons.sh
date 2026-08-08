#!/usr/bin/env bash
set -euo pipefail

# Regenerates every raster icon asset from the vector sources, using only
# stock macOS tools. Edit the SVGs, run this, rebuild:
#   Resources/AppIcon.svg             -> AppIcon.icns, AppIcon.png, AppIconSource.png
#   Resources/MenuBarIconTemplate.svg -> MenuBarIconTemplate.png, MenuBarIconTemplate@2x.png

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT_DIR/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# App icon: 1024px master render, downscaled into a full .iconset.
qlmanage -t -s 1024 -o "$TMP" "$RES/AppIcon.svg" >/dev/null
ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
cp "$TMP/AppIcon.svg.png" "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$TMP/AppIcon.svg.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
sips -z 64 64 "$TMP/AppIcon.svg.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
cp "$TMP/AppIcon.svg.png" "$RES/AppIcon.png"
cp "$TMP/AppIcon.svg.png" "$RES/AppIconSource.png"

# Menu-bar template: 18pt + @2x, monochrome (macOS tints it at runtime).
qlmanage -t -s 36 -o "$TMP" "$RES/MenuBarIconTemplate.svg" >/dev/null
cp "$TMP/MenuBarIconTemplate.svg.png" "$RES/MenuBarIconTemplate@2x.png"
sips -z 18 18 "$TMP/MenuBarIconTemplate.svg.png" --out "$RES/MenuBarIconTemplate.png" >/dev/null

echo "Icons regenerated in $RES."
