#!/usr/bin/env python3
"""Check or stage one audited rollback; never commit or discard local edits."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def rollback(root, item, apply=False):
    root = Path(root).resolve()
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root:
        raise ValueError("Run from the repository root.")
    if git(root, "status", "--porcelain"):
        raise ValueError("The checkout must be clean, including untracked files.")
    directory = root / "docs/audit/rollbacks"
    manifest = json.loads((directory / "manifest.json").read_text())
    for path, key in [("Sources", "source_tree"), ("Tests", "test_tree")]:
        if git(root, "rev-parse", f"HEAD:{path}") != manifest[key]:
            raise ValueError("Source or test history has changed; this rollback needs review.")
    record = next((record for record in manifest["items"] if record["item"] == item), None)
    if record is None:
        raise ValueError("No rollback exists for this item.")
    patch = directory / f"{item:02}.patch"
    if hashlib.sha256(patch.read_bytes()).hexdigest() != record["patch_sha256"]:
        raise ValueError("The rollback patch does not match its recorded checksum.")
    subprocess.run(["git", "apply", "--check", "--index", str(patch)], cwd=root, check=True)
    if apply:
        subprocess.run(["git", "apply", "--index", str(patch)], cwd=root, check=True)
    return record["title"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("item", type=int, choices=range(1, 15))
    parser.add_argument("--apply", action="store_true", help="Stage the rollback for review; do not commit.")
    args = parser.parse_args()
    try:
        title = rollback(Path(__file__).resolve().parents[2], args.item, args.apply)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Rollback stopped: {error}\n")
    print(f"{'Staged' if args.apply else 'Checked'} item {args.item}: {title}")
    if args.apply:
        print("Review git diff --cached and run ./script/run_tests.sh before committing.")


if __name__ == "__main__":
    main()
