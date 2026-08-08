#!/usr/bin/env python3
"""Synchronize the documented standalone helper with the app's embedded copy."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SWIFT_SOURCE = ROOT / "Sources" / "Support" / "BackendScriptWriter.swift"
STANDALONE = ROOT / "transcribe.py"
START = '    static let source = #"""\n'
END = '\n"""#\n'


def embedded_source() -> str:
    swift = SWIFT_SOURCE.read_text(encoding="utf-8")
    try:
        start = swift.index(START) + len(START)
        end = swift.index(END, start)
    except ValueError as error:
        raise RuntimeError("could not locate BackendScript.source raw string") from error
    return swift[start:end] + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail instead of rewriting when transcribe.py is out of date",
    )
    args = parser.parse_args()
    expected = embedded_source()
    actual = STANDALONE.read_text(encoding="utf-8") if STANDALONE.exists() else ""
    if actual == expected:
        print("transcribe.py matches BackendScript.source")
        return 0
    if args.check:
        print(
            "error: transcribe.py differs from BackendScript.source; "
            "run script/sync_backend_script.py",
            file=sys.stderr,
        )
        return 1
    STANDALONE.write_text(expected, encoding="utf-8")
    STANDALONE.chmod(0o755)
    print("updated transcribe.py from BackendScript.source")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
