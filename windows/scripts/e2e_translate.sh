#!/usr/bin/env bash
# End-to-end check of `cue translate` against fake_llm_server.py: the first
# run is interrupted by a 401 halfway, the second must resume and send only
# the subtitles that are still missing. Usage: e2e_translate.sh PATH_TO_CUE
set -euo pipefail
CUE="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$(command -v python3 || command -v python)"
WORK="$(mktemp -d)"
PORT=18731
trap 'kill "$SERVER" 2>/dev/null || true' EXIT

# Give every cue a distinct, increasing start so timing alignment is exercised.
"$PY" - "$WORK/movie.srt" <<'PY'
import sys
lines = []
for i in range(1, 101):
    s = i * 2
    fmt = lambda t, ms: f"00:{t // 60:02d}:{t % 60:02d},{ms:03d}"
    lines.append(f"{i}\n{fmt(s, 0)} --> {fmt(s + 1, 500)}\nLine number {i}\n")
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(lines))
PY

FAIL_IDS=50 REQUEST_LOG="$WORK/log" "$PY" "$HERE/fake_llm_server.py" "$PORT" &
SERVER=$!
for _ in $(seq 1 50); do
  "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 1)" 2>/dev/null && break
  sleep 0.2
done

ARGS=(--to Vietnamese -t local/fake --local-endpoint "http://127.0.0.1:$PORT" --chunk-mode safer --parallelism 1)
if "$CUE" translate "$WORK/movie.srt" "${ARGS[@]}"; then
  echo "expected the first run to fail on the injected 401" >&2; exit 1
fi
test -f "$WORK/movie.translated.vietnamese.partial.json"
: > "$WORK/log"

"$CUE" translate "$WORK/movie.srt" "${ARGS[@]}" --bilingual -f srt,vtt
"$PY" - "$WORK/log" <<'PY'
import json, sys
ids = [i for line in open(sys.argv[1]) for i in json.loads(line)]
assert min(ids) > 1 and 100 in ids, f"resume sent {ids}"
PY
test ! -f "$WORK/movie.translated.vietnamese.partial.json"
grep -q "\[Vietnamese\] Line number 100" "$WORK/movie.translated.vietnamese.srt"
head -1 "$WORK/movie.translated.vietnamese.vtt" | grep -q WEBVTT
grep -A1 "^Line number 7$" "$WORK/movie.bilingual.vietnamese.srt" | grep -q "\[Vietnamese\] Line number 7"
echo "translate resume end to end: ok"
