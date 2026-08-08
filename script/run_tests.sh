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

# With a full Xcode install, plain `swift test` works — prefer it.
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  exec swift test "$@"
fi

swift build --build-tests

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

exec "$RUNNER" "$BUNDLE_BINARY"
