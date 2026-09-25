import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

class ValidateAssetsTests(unittest.TestCase):
    def test_cli_rejects_missing_corrupt_and_escaping_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'assets'; root.mkdir()
            asset = root / 'test.bin'; asset.write_bytes(b'good')
            manifest = Path(tmp) / 'manifest.json'
            entry = dict(path='test.bin', size=4, sha256=hashlib.sha256(b'good').hexdigest())
            manifest.write_text(json.dumps(dict(files=[entry])))
            def run():
                return subprocess.run([sys.executable, str(Path(__file__).with_name('validate_supertonic_assets.py')), '--root', str(root), '--manifest', str(manifest)], capture_output=True).returncode
            self.assertEqual(run(), 0)
            asset.write_bytes(b'evil'); self.assertNotEqual(run(), 0)
            asset.unlink(); self.assertNotEqual(run(), 0)
            entry['path'] = '../escape'; manifest.write_text(json.dumps(dict(files=[entry])))
            self.assertNotEqual(run(), 0)
