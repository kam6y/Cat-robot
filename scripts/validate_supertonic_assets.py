#!/usr/bin/env python3
"""Verify bundled assets offline before building; never download during a build."""
import argparse
import json
from pathlib import Path
from prepare_supertonic_assets import validate_assets

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    args = parser.parse_args()
    validate_assets(args.root, json.loads(args.manifest.read_text()))
    print('Supertonic assets verified')

if __name__ == '__main__':
    main()
