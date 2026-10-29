#!/usr/bin/env python3
"""Validate prepared dictionary and native build; never download or compile."""
import argparse
import json
from pathlib import Path
import plistlib
import sys

from prepare_supertonic_assets import asset_path, digest


def validate_dictionary(root, files):
    if not files:
        raise ValueError("Empty jpreprocess dictionary manifest")
    for entry in files:
        path = asset_path(root, entry["path"])
        if path.is_symlink() or not path.is_file():
            raise ValueError("Missing dictionary file: " + entry["path"])
        if path.stat().st_size != entry["size"] or digest(path) != entry["sha256"]:
            raise ValueError("Dictionary checksum mismatch: " + entry["path"])


def validate_framework(root):
    info_path = root / "Info.plist"
    if not info_path.is_file():
        raise ValueError("Missing CJPPronunciation.xcframework; run scripts/build_jpreprocess.sh")
    info = plistlib.loads(info_path.read_bytes())
    found = []
    for entry in info.get("AvailableLibraries", []):
        variant = entry.get("SupportedPlatformVariant", "device")
        found.append((entry.get("SupportedPlatform"), variant, tuple(sorted(entry.get("SupportedArchitectures", [])))))
        base = asset_path(root, entry["LibraryIdentifier"])
        library = asset_path(base, entry["LibraryPath"])
        headers = asset_path(base, entry["HeadersPath"])
        if library.suffix != ".a" or not library.is_file():
            raise ValueError("Missing static jpreprocess library: " + str(library))
        for name in ["CJPPronunciation.h", "module.modulemap"]:
            if not (headers / name).is_file():
                raise ValueError("Missing native header/module: " + name)
    if sorted(found) != [("ios", "device", ("arm64",)), ("ios", "simulator", ("arm64", "x86_64"))]:
        raise ValueError("jpreprocess requires arm64 iPhone and arm64/x86_64 Simulator slices")


def native_sources(source_root):
    native = source_root / "native/japanese-pronunciation"
    # Cargo's generated target sources are not inputs to the native adapter.
    files = [native / name for name in ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "build.rs")]
    for folder in ("src", "include", "tests"):
        files.extend((native / folder).rglob("*"))
    files = [p for p in files if p.is_file() and p.suffix in (".rs", ".toml", ".lock", ".h", ".modulemap")]
    script = source_root / "scripts/build_jpreprocess.sh"
    if script.is_file():
        files.append(script)
    return {str(p.relative_to(source_root)): digest(p) for p in sorted(files)}


def native_artifacts(root):
    framework = root / "CJPPronunciation.xcframework"
    return {str(p.relative_to(root)): digest(p) for p in sorted(framework.rglob("*")) if p.is_file()}


def validate_receipt(root, source_root):
    receipt_path = root / "native-build.json"
    if not receipt_path.is_file():
        raise ValueError("Missing native build receipt; run scripts/build_jpreprocess.sh")
    receipt = json.loads(receipt_path.read_text())
    sources = native_sources(source_root)
    artifacts = native_artifacts(root)
    if not sources or sources != receipt.get("sourceFiles"):
        raise ValueError("jpreprocess source changed; rebuild with scripts/build_jpreprocess.sh")
    if not artifacts or artifacts != receipt.get("artifactFiles"):
        raise ValueError("jpreprocess native artifact changed; rebuild with scripts/build_jpreprocess.sh")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--write-receipt", action="store_true", help="Build-script use only, after compiling all slices")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("version") != "0.15.0":
        raise ValueError("Unexpected jpreprocess dictionary version")
    validate_dictionary(args.root / "dictionary", manifest["files"])
    validate_framework(args.root / "CJPPronunciation.xcframework")
    if args.write_receipt:
        payload = {"sourceFiles": native_sources(args.source_root), "artifactFiles": native_artifacts(args.root)}
        (args.root / "native-build.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    validate_receipt(args.root, args.source_root)
    print("PASS: jpreprocess dictionary and native build verified")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
