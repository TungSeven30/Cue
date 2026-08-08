#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:?usage: prepare_metal_shader.sh <output-directory>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GGML_SOURCE="$ROOT_DIR/.build/checkouts/whisper.cpp/ggml/src"
COMMON_HEADER="$GGML_SOURCE/ggml-common.h"
METAL_SOURCE="$GGML_SOURCE/ggml-metal.metal"

if [[ ! -f "$COMMON_HEADER" || ! -f "$METAL_SOURCE" ]]; then
  echo "error: whisper.cpp shader sources not found under $GGML_SOURCE;" >&2
  echo "the pinned checkout layout changed — update prepare_metal_shader.sh." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
TEMP_SHADER="$(mktemp "$OUTPUT_DIR/.ggml-metal.metal.XXXXXX")"
cleanup() { rm -f "$TEMP_SHADER"; }
trap cleanup EXIT

# Metal's runtime compiler has no include path for ggml-common.h. This is the
# same self-contained merge performed by whisper.cpp's upstream embed step.
awk '/#include "ggml-common.h"/ {
       while ((getline line < common) > 0) print line
       close(common); next
     } { print }' \
  common="$COMMON_HEADER" "$METAL_SOURCE" > "$TEMP_SHADER"

if grep -q 'ggml-common.h' "$TEMP_SHADER"; then
  echo "error: ggml-common.h was not inlined into ggml-metal.metal" >&2
  exit 1
fi
mv "$TEMP_SHADER" "$OUTPUT_DIR/ggml-metal.metal"
