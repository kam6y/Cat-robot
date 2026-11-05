#!/usr/bin/env python3
"""Download (--download) or validate the revision-pinned, device-local endpoint models."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def prepare(root, manifest, download=False):
    entries = json.loads(manifest.read_text())["files"]
    if not entries or len({e["path"] for e in entries}) != len(entries):
        raise ValueError("Empty or duplicate model manifest")
    for entry in entries:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or "\\" in str(relative):
            raise ValueError("Unsafe model path")
        path = root / relative
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("Model path escapes asset root")
        if download:
            url = entry["url"]
            if not url.startswith(("https://huggingface.co/", "https://raw.githubusercontent.com/")):
                raise ValueError("Unrecognized model source")
            data = urllib.request.urlopen(url, timeout=90).read()
        else:
            data = path.read_bytes()
        if len(data) != entry["size"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Model checksum mismatch: " + entry["path"])
        if download:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + ".download")
            temporary.write_bytes(data)
            temporary.replace(path)
    return len(entries)


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=repo / "CatRobot/LocalAssets/SmartTurn")
    parser.add_argument("--manifest", type=Path, default=repo / "CatRobot/Resources/smart-turn-manifest.json")
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    print("Validated", prepare(args.root, args.manifest, args.download), "Smart Turn / Silero files")


if __name__ == "__main__":
    main()
