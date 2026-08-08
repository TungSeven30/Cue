#!/usr/bin/env python3
"""Generate a deterministic CycloneDX SBOM from SwiftPM's lockfile."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent


def component(pin: dict[str, object]) -> dict[str, object]:
    identity = str(pin["identity"])
    location = str(pin["location"])
    state = pin["state"]
    assert isinstance(state, dict)
    revision = str(state["revision"])
    version = str(state.get("version", revision))
    repo_path = location.removeprefix("https://github.com/").removesuffix(".git")
    return {
        "type": "library",
        "name": identity,
        "version": version,
        "bom-ref": f"pkg:github/{quote(repo_path)}@{quote(revision)}",
        "purl": f"pkg:github/{quote(repo_path)}@{quote(revision)}",
        "externalReferences": [{"type": "vcs", "url": f"{location}/tree/{revision}"}],
        "properties": [{"name": "cue:gitRevision", "value": revision}],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    resolved = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))
    components = sorted((component(pin) for pin in resolved["pins"]), key=lambda item: item["name"])
    root_ref = f"pkg:generic/cue@{quote(args.version)}"
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {"component": {"type": "application", "name": "Cue", "version": args.version, "bom-ref": root_ref}},
        "components": components,
        "dependencies": [{"ref": root_ref, "dependsOn": [item["bom-ref"] for item in components]}],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Generated {args.output}")


if __name__ == "__main__":
    main()
