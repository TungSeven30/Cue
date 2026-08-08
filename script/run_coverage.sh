#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_DIR="$ROOT_DIR/.build/audit"
COVERAGE_JSON="$AUDIT_DIR/codecov.json"
mkdir -p "$AUDIT_DIR"
cd "$ROOT_DIR"

if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  CUE_ENABLE_CODE_COVERAGE=1 "$ROOT_DIR/script/run_tests.sh"
  GENERATED_JSON="$(swift test --show-codecov-path | tail -1)"
  cp "$GENERATED_JSON" "$COVERAGE_JSON"
else
  PROFILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cue-coverage.XXXXXX")"
  cleanup() { rm -rf "$PROFILE_DIR"; }
  trap cleanup EXIT
  RAW_PROFILE="$PROFILE_DIR/cue-%p.profraw"
  MERGED_PROFILE="$PROFILE_DIR/cue.profdata"
  CUE_ENABLE_CODE_COVERAGE=1 CUE_COVERAGE_PROFILE="$RAW_PROFILE" \
    "$ROOT_DIR/script/run_tests.sh"
  BIN_PATH="$(swift build --show-bin-path)"
  TEST_BINARY="$BIN_PATH/CuePackageTests.xctest/Contents/MacOS/CuePackageTests"
  xcrun llvm-profdata merge -sparse "$PROFILE_DIR"/*.profraw -o "$MERGED_PROFILE"
  xcrun llvm-cov export "$TEST_BINARY" -instr-profile "$MERGED_PROFILE" \
    -ignore-filename-regex='(/Tests/|/.build/checkouts/)' > "$COVERAGE_JSON"
fi

python3 "$ROOT_DIR/script/check_coverage.py" "$COVERAGE_JSON"
