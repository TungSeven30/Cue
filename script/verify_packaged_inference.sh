#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: verify_packaged_inference.sh <Cue.app> [model.bin]}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Cue"
MODEL_REVISION="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_NAME="ggml-tiny.bin"
MODEL_SIZE="77691713"
MODEL_SHA256="be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/$MODEL_REVISION/$MODEL_NAME"
MODEL_PATH="${2:-$ROOT_DIR/.build/audit/$MODEL_NAME}"

fail() {
  echo "error: packaged inference verification failed: $*" >&2
  exit 1
}

[[ -x "$APP_BINARY" ]] || fail "$APP_BINARY is missing"
mkdir -p "$(dirname "$MODEL_PATH")"
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Downloading pinned $MODEL_NAME for packaged inference verification…"
  curl --fail --location --retry 3 --output "$MODEL_PATH.partial" "$MODEL_URL"
  mv "$MODEL_PATH.partial" "$MODEL_PATH"
fi

ACTUAL_SIZE="$(stat -f '%z' "$MODEL_PATH")"
[[ "$ACTUAL_SIZE" == "$MODEL_SIZE" ]] || fail "$MODEL_NAME has size $ACTUAL_SIZE; expected $MODEL_SIZE"
ACTUAL_SHA256="$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$MODEL_SHA256" ]] || fail "$MODEL_NAME SHA-256 does not match the pinned manifest"

LOG_FILE="$(mktemp)"
cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

set +e
"$APP_BINARY" --self-test-packaged-inference "$MODEL_PATH" >"$LOG_FILE" 2>&1
STATUS=$?
set -e
if [[ "$STATUS" != "0" ]]; then
  cat "$LOG_FILE"
  fail "Cue self-test exited with status $STATUS"
fi
grep -Fq 'CUE_PACKAGED_INFERENCE_OK' "$LOG_FILE" || fail "success marker is missing"
grep -Fq 'GGML_METAL_PATH_RESOURCES = ' "$LOG_FILE" || fail "whisper.cpp did not report the packaged Metal resource path"
if grep -Eq 'ggml_backend_metal_init: error|whisper_backend_init_gpu: ggml_backend_metal_init\(\) failed' "$LOG_FILE"; then
  fail "whisper.cpp fell back after Metal initialization failed"
fi

grep -E 'GGML_METAL_PATH_RESOURCES = |ggml_metal_init: GPU name:|CUE_PACKAGED_INFERENCE_OK' "$LOG_FILE"

echo "Verified packaged whisper.cpp inference with the pinned $MODEL_NAME model and Metal resource."
