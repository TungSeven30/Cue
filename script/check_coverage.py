#!/usr/bin/env python3
"""Enforce line-coverage floors from coverage-thresholds.json."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_coverage.py <llvm-cov-json>")
    report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    policy = json.loads((ROOT / "coverage-thresholds.json").read_text(encoding="utf-8"))
    data = report["data"][0]
    total = float(data["totals"]["lines"]["percent"])
    failures: list[str] = []
    minimum = float(policy["totalLinesPercent"])
    if total < minimum:
        failures.append(f"total line coverage {total:.2f}% is below {minimum:.2f}%")

    files = {str(Path(item["filename"]).resolve().relative_to(ROOT)): item for item in data["files"] if Path(item["filename"]).is_relative_to(ROOT)}
    scope = policy["domainScope"]
    scoped_files = [item for filename, item in files.items() if filename.startswith(tuple(scope["prefixes"]))]
    scoped_covered = sum(item["summary"]["lines"]["covered"] for item in scoped_files)
    scoped_count = sum(item["summary"]["lines"]["count"] for item in scoped_files)
    scoped_percent = 100 * scoped_covered / scoped_count if scoped_count else 0
    scoped_minimum = float(scope["minimumLinesPercent"])
    if scoped_percent < scoped_minimum:
        failures.append(f"Models/Services line coverage {scoped_percent:.2f}% is below {scoped_minimum:.2f}%")

    measured: list[tuple[str, float, float]] = []
    for filename, required in policy["criticalFiles"].items():
        if filename not in files:
            failures.append(f"critical coverage file is missing: {filename}")
            continue
        actual = float(files[filename]["summary"]["lines"]["percent"])
        required = float(required)
        measured.append((filename, actual, required))
        if actual < required:
            failures.append(f"{filename} line coverage {actual:.2f}% is below {required:.2f}%")

    print(f"Total line coverage: {total:.2f}% (minimum {minimum:.2f}%)")
    print(f"Models/Services line coverage: {scoped_percent:.2f}% (minimum {scoped_minimum:.2f}%)")
    for filename, actual, required in measured:
        print(f"  {filename}: {actual:.2f}% (minimum {required:.2f}%)")
    if failures:
        raise SystemExit("coverage policy failed:\n- " + "\n- ".join(failures))


if __name__ == "__main__":
    main()
