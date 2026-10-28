#!/usr/bin/env python3
"""Explicit preparation of the pinned jpreprocess dictionary, outside Xcode builds."""
import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile
import urllib.request

from prepare_supertonic_assets import digest
from validate_jpreprocess_assets import validate_dictionary

ARCHIVE_URL = "https://github.com/jpreprocess/jpreprocess/releases/download/v0.15.0/naist-jdic-jpreprocess.tar.gz"
ARCHIVE_SHA256 = "8a930bbc57bf4adcf521d53544c7dc9ab8ab3aa997a591b1b1608dc5539017b8"


def extract_checked_archive(archive, destination, expected_sha256, files):
    if digest(archive) != expected_sha256:
        raise ValueError("jpreprocess archive checksum mismatch")
    if destination.exists():
        raise ValueError("Refusing to overwrite existing dictionary: " + str(destination))
    expected = {entry["path"]: entry for entry in files}
    if not expected or len(expected) != len(files):
        raise ValueError("Empty or duplicate dictionary manifest")
    with tarfile.open(archive, "r:gz") as tar:
        members = []
        seen = set()
        for member in tar.getmembers():
            path = PurePosixPath(member.name)
            if member.isdir() and member.name.rstrip("/") == "naist-jdic":
                continue
            if not member.isfile() or len(path.parts) != 2 or path.parts[0] != "naist-jdic" or ".." in path.parts or "\\" in member.name:
                raise ValueError("Unexpected dictionary archive member: " + member.name)
            name = path.parts[1]
            if name not in expected or name in seen or member.size != expected[name]["size"]:
                raise ValueError("Unexpected dictionary archive file: " + member.name)
            members.append((member, name))
            seen.add(name)
        if seen != set(expected):
            raise ValueError("Dictionary archive is incomplete")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".jpreprocess-", dir=destination.parent) as scratch:
            output = Path(scratch) / "dictionary"
            output.mkdir()
            for member, name in members:
                with tar.extractfile(member) as source, (output / name).open("wb") as target:
                    shutil.copyfileobj(source, target)
            validate_dictionary(output, files)
            output.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--archive", type=Path, help="Reuse an already downloaded archive; hash is still checked")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("version") != "0.15.0" or manifest.get("archive") != {"url": ARCHIVE_URL, "sha256": ARCHIVE_SHA256}:
        raise ValueError("Unexpected jpreprocess archive manifest")
    destination = args.root / "dictionary"
    if destination.exists():
        validate_dictionary(destination, manifest["files"])
    elif args.archive:
        extract_checked_archive(args.archive, destination, ARCHIVE_SHA256, manifest["files"])
    else:
        with tempfile.TemporaryDirectory(prefix="jpreprocess-download-") as scratch:
            archive = Path(scratch) / "dictionary.tar.gz"
            with urllib.request.urlopen(ARCHIVE_URL, timeout=60) as source, archive.open("wb") as target:
                shutil.copyfileobj(source, target)
            extract_checked_archive(archive, destination, ARCHIVE_SHA256, manifest["files"])
    print("PASS: pinned jpreprocess dictionary prepared")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, tarfile.TarError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
