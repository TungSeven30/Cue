#!/usr/bin/env bash
# Runs the swift-testing suite. With Command Line Tools only (no Xcode),
# `swift test` builds the tests but silently runs none of them: SwiftPM's
# generated runner is compiled without the Testing framework search path, so
# its canImport(Testing) is false. This script loads the built test bundle
# and invokes the Testing entry point directly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_TESTING_LIBS="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

cd "$ROOT_DIR"

# GitHub-hosted macOS runners have few vCPUs. Swift Testing's default worker
# count can saturate the cooperative thread pool and deadlock @MainActor suites.
SWIFT_TEST_PARALLEL=()
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  SWIFT_TEST_PARALLEL=(--no-parallel)
fi

# The Python helper is shipped in two forms. Run its behavioral tests and the
# parity check before Swift so the advertised standalone CLI cannot drift from
# the app's embedded copy.
python3 -m unittest discover -s script -p 'test_*.py'

# The pinned whisper.cpp SwiftPM resource contains ggml-metal.metal but omits
# its included header. Point Apple Silicon tests at the same self-contained
# shader shipped in Cue.app so the integration test proves Metal rather than
# silently falling back to CPU.
if [[ "$(uname -m)" == "arm64" && -z "${GGML_METAL_PATH_RESOURCES:-}" ]]; then
  swift package resolve
  TEST_METAL_RESOURCES="$ROOT_DIR/.build/audit/test-metal-resources"
  "$ROOT_DIR/script/prepare_metal_shader.sh" "$TEST_METAL_RESOURCES"
  export GGML_METAL_PATH_RESOURCES="$TEST_METAL_RESOURCES"
fi

# With a full Xcode install, plain `swift test` works — prefer it.
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  if [[ "${CUE_ENABLE_CODE_COVERAGE:-0}" == "1" ]]; then
    exec swift test --enable-code-coverage "${SWIFT_TEST_PARALLEL[@]}" "$@"
  fi
  exec swift test "${SWIFT_TEST_PARALLEL[@]}" "$@"
fi

BUILD_OPTIONS=(--build-tests)
if [[ "${CUE_ENABLE_CODE_COVERAGE:-0}" == "1" ]]; then
  BUILD_OPTIONS+=(--enable-code-coverage)
fi
swift build "${BUILD_OPTIONS[@]}"

BIN_PATH="$(swift build --show-bin-path)"
BUNDLE_BINARY="$BIN_PATH/CuePackageTests.xctest/Contents/MacOS/CuePackageTests"
RUNNER_DIR="$BIN_PATH/test-runner"
RUNNER="$RUNNER_DIR/run-tests"
RUNNER_SOURCE="$RUNNER_DIR/run-tests.swift"

mkdir -p "$RUNNER_DIR"
cat >"$RUNNER_SOURCE" <<'SWIFT'
import Darwin
import Foundation
import Testing

@main
struct Main {
    static func main() async {
        guard CommandLine.arguments.count > 1, dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else {
            FileHandle.standardError.write(Data("dlopen failed: \(String(cString: dlerror()))\n".utf8))
            exit(1)
        }
        await Testing.__swiftPMEntryPoint() as Never
    }
}
SWIFT

if [[ ! -x "$RUNNER" || "$RUNNER_SOURCE" -nt "$RUNNER" ]]; then
  swiftc "$RUNNER_SOURCE" -parse-as-library \
    -F "$CLT_FRAMEWORKS" -framework Testing \
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_TESTING_LIBS" \
    -o "$RUNNER"
fi

if [[ "${CUE_ENABLE_CODE_COVERAGE:-0}" == "1" ]]; then
  : "${CUE_COVERAGE_PROFILE:?set CUE_COVERAGE_PROFILE when collecting coverage with Command Line Tools}"
  exec env LLVM_PROFILE_FILE="$CUE_COVERAGE_PROFILE" "$RUNNER" "$BUNDLE_BINARY"
fi
exec "$RUNNER" "$BUNDLE_BINARY"
