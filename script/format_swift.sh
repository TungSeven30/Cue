#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# BackendScriptWriter contains a verbatim Python program. Its formatting is
# governed by sync_backend_script.py and Python tests, not Swift layout rules.
find Sources Tests -name '*.swift' \
  ! -path 'Sources/Support/BackendScriptWriter.swift' -print0 \
  | xargs -0 xcrun swift-format format --in-place --parallel --configuration .swift-format
