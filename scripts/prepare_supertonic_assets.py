#!/usr/bin/env python3
"""Explicit development-time download; the app never fetches model assets."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import urllib.request

REVISION = 'aafc6e32416a594460b32413efc49d7fe4ce6d46'
REPOSITORY = 'supertone-oss-archive/supertonic-3'

def asset_path(root, name):
    parts = PurePosixPath(name)
    if not name or parts.is_absolute() or '..' in parts.parts or '\\' in name:
        raise ValueError('Invalid asset path: ' + name)
    path = root.joinpath(*parts.parts)
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Asset escapes root: ' + name)
    return path

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()

def validate_assets(root, manifest):
    if not manifest['files']:
        raise ValueError('Empty manifest')
    for entry in manifest['files']:
        path = asset_path(root, entry['path'])
        if path.stat().st_size != entry['size'] or digest(path) != entry['sha256']:
            raise ValueError('Asset mismatch: ' + entry['path'])

def install_assets(target, names, download, revision, expected=None):
    if target.exists():
        raise FileExistsError(target)
    for name in names:
        asset_path(target, name)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.supertonic-', dir=target.parent) as d:
        root = Path(d) / 'assets'
        root.mkdir()
        entries = []
        for name in names:
            path = asset_path(root, name)
            path.parent.mkdir(parents=True, exist_ok=True)
            download(name, path)
            entries.append(dict(path=name, size=path.stat().st_size, sha256=digest(path)))
        manifest = dict(repository=REPOSITORY, revision=revision, files=entries)
        if expected is not None and manifest != expected:
            raise ValueError('Downloaded assets differ from committed manifest')
        validate_assets(root, manifest)
        root.rename(target)
    return manifest

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--revision', default=REVISION, choices=[REVISION])
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--manifest', type=Path, required=True)
    args = p.parse_args()
    expected = json.loads(args.manifest.read_text()) if args.manifest.exists() else None
    if args.output.exists():
        if expected is None: raise ValueError('Existing install requires a manifest')
        validate_assets(args.output, expected)
        print('Existing assets verified')
        return
    api = f'https://huggingface.co/api/models/{REPOSITORY}/revision/{args.revision}'
    with urllib.request.urlopen(api, timeout=60) as response:
        info = json.load(response)
    if info['sha'] != args.revision: raise ValueError('Revision mismatch')
    names = sorted(x['rfilename'] for x in info['siblings']
                   if x['rfilename'].startswith(('onnx/', 'voice_styles/')) or x['rfilename'] == 'LICENSE')
    def download(name, path):
        print('Downloading ' + name, flush=True)
        url = f'https://huggingface.co/{REPOSITORY}/resolve/{args.revision}/{name}'
        with urllib.request.urlopen(url, timeout=180) as source, path.open('wb') as out:
            shutil.copyfileobj(source, out, 1024 * 1024)
    manifest = install_assets(args.output, names, download, args.revision, expected)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    temp = args.manifest.with_suffix('.json.tmp')
    temp.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    temp.replace(args.manifest)
    print('Verified model bytes:', sum(e['size'] for e in manifest['files']))

if __name__ == '__main__': main()
