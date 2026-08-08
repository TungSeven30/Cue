#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# See format_swift.sh for the generated-source exclusion.
find Sources Tests -name '*.swift' \
  ! -path 'Sources/Support/BackendScriptWriter.swift' -print0 \
  | xargs -0 xcrun swift-format lint --strict --parallel --configuration .swift-format
