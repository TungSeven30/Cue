#!/usr/bin/env python3
"""Fail closed when dependency or GitHub Actions pins drift from policy."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {
    "sparkle": {
        "location": "https://github.com/sparkle-project/Sparkle",
        "version": "2.9.5",
        "revision": "79bc9e872948e47877e76f194cb0c8e0412b0b90",
    },
    "whisper.cpp": {
        "location": "https://github.com/ggml-org/whisper.cpp",
        "revision": "6266a9f9e56a5b925e9892acf650f3eb1245814d",
    },
}
ACTION_PATTERN = re.compile(r"^\s*-\s+uses:\s*([^\s#]+)", re.MULTILINE)
PINNED_ACTION = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")


def audit() -> dict[str, object]:
    resolved = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))
    pins = {pin["identity"]: pin for pin in resolved["pins"]}
    if set(pins) != set(EXPECTED):
        raise SystemExit(f"dependency identities differ from policy: {sorted(pins)}")

    dependencies: list[dict[str, str]] = []
    for identity, expected in EXPECTED.items():
        pin = pins[identity]
        state = pin["state"]
        for key, value in expected.items():
            actual = pin["location"] if key == "location" else state.get(key)
            if actual != value:
                raise SystemExit(f"{identity} {key} is {actual!r}; expected {value!r}")
        dependencies.append(
            {
                "identity": identity,
                "location": pin["location"],
                "revision": state["revision"],
                **({"version": state["version"]} if "version" in state else {}),
            }
        )

    package_text = (ROOT / "Package.swift").read_text(encoding="utf-8")
    if 'exact: "2.9.5"' not in package_text:
        raise SystemExit("Sparkle must use an exact version in Package.swift")
    if 'revision: "6266a9f9e56a5b925e9892acf650f3eb1245814d"' not in package_text:
        raise SystemExit("whisper.cpp must use the reviewed immutable revision")

    actions: list[str] = []
    for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        for action in ACTION_PATTERN.findall(workflow.read_text(encoding="utf-8")):
            if not PINNED_ACTION.fullmatch(action):
                raise SystemExit(f"{workflow.name}: action is not pinned to a full commit: {action}")
            actions.append(action)

    return {
        "schemaVersion": 1,
        "status": "passed",
        "swiftDependencies": dependencies,
        "githubActions": sorted(actions),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    evidence = audit()
    rendered = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")


if __name__ == "__main__":
    main()
