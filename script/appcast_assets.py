#!/usr/bin/env python3
"""Validate and list every local artifact referenced by Cue's Sparkle appcast."""

import argparse
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET


DOWNLOAD_HOST = "github.com"
DOWNLOAD_PATH_PREFIX = "/TungSeven30/cue-releases/releases/download/stable/"
SUPPORTED_SUFFIXES = (".dmg", ".delta")


def referenced_assets(appcast: Path, archive: Path) -> list[Path]:
    root = ET.parse(appcast).getroot()
    assets: list[Path] = []
    seen: set[str] = set()
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] != "enclosure":
            continue
        raw_url = element.attrib.get("url", "")
        parsed = urlparse(raw_url)
        if parsed.scheme != "https" or parsed.netloc != DOWNLOAD_HOST or not parsed.path.startswith(DOWNLOAD_PATH_PREFIX):
            raise ValueError(f"unexpected appcast download URL: {raw_url}")
        name = unquote(parsed.path.removeprefix(DOWNLOAD_PATH_PREFIX))
        if not name or "/" in name or not name.endswith(SUPPORTED_SUFFIXES):
            raise ValueError(f"unsafe or unsupported appcast asset: {raw_url}")
        if name in seen:
            continue
        path = archive / name
        if not path.is_file():
            raise ValueError(f"appcast references missing local artifact: {path}")
        seen.add(name)
        assets.append(path)
    if not assets:
        raise ValueError("appcast contains no downloadable enclosures")
    return assets


def verify_available(assets: list[Path], release_json: Path) -> None:
    payload = json.loads(release_json.read_text())
    available = {entry.get("name") for entry in payload.get("assets", [])}
    missing = [asset.name for asset in assets if asset.name not in available]
    if missing:
        raise ValueError("release is missing appcast assets: " + ", ".join(missing))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--available-assets-json", type=Path)
    args = parser.parse_args()
    try:
        assets = referenced_assets(args.appcast, args.archive)
        if args.available_assets_json:
            verify_available(assets, args.available_assets_json)
        else:
            for asset in assets:
                print(asset.resolve())
    except (ET.ParseError, OSError, ValueError, json.JSONDecodeError) as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
