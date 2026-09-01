#!/usr/bin/env bash
# Creates an isolated scratch directory for Cue CLI verification runs.
# Invoked from the verify-cue skill; do not write into ~/Movies or real watch folders.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
RUN_ID="${1:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
EVIDENCE_ROOT="${CUE_VERIFY_EVIDENCE_ROOT:-$ROOT_DIR/.cue-verify-evidence}"
SCRATCH="$EVIDENCE_ROOT/$RUN_ID/scratch"
mkdir -p "$SCRATCH"
printf '%s\n' "$SCRATCH"
