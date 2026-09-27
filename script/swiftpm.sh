#!/usr/bin/env bash
# Runs a SwiftPM subcommand on Cue's pinned build system:
#   script/swiftpm.sh build -c release
#   script/swiftpm.sh test --filter Name
#
# Swift 6.4 (the macOS 27 toolchain) makes Swift Build SwiftPM's default
# engine. Swift Build compiles the pinned whisper.cpp package's
# ggml-metal.metal resource with the `metal` compiler, which Command Line
# Tools does not include (and Xcode installs only as an optional component),
# so the default build fails before reaching Cue. Cue never uses that
# compiled library: it ships a self-contained shader that ggml compiles at
# runtime (script/prepare_metal_shader.sh). The native build system copies
# the resource unchanged, exactly as every Cue release through 2.7 was built.
# Older toolchains, including CI's, accept the same flag. Every build and test
# entry point goes through this file so the choice lives in one place;
# script/test_swiftpm_entry_points.py enforces that.
set -euo pipefail

subcommand="${1:?usage: swiftpm.sh <build|test> [arguments...]}"
shift
exec swift "$subcommand" --build-system native "$@"
