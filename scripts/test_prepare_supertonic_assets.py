import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from prepare_supertonic_assets import install_assets, validate_assets

class AssetsTests(unittest.TestCase):
    def test_failed_download_never_publishes_partial_directory(self):
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / 'assets'
            def fail(name, path):
                path.write_bytes(b'partial')
                raise OSError('network failure')
            with self.assertRaises(OSError):
                install_assets(target, ['onnx/a'], fail, 'revision')
            self.assertFalse(target.exists())

    def test_corruption_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'assets'
            manifest = install_assets(root, ['onnx/a'], lambda n, p: p.write_bytes(b'abc'), 'revision')
            validate_assets(root, manifest)
            (root / 'onnx/a').write_bytes(b'abd')
            with self.assertRaises(ValueError):
                validate_assets(root, manifest)

    def test_traversal_rejected_before_download(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ['../escape', '/absolute', 'onnx/../escape']:
                with self.assertRaises(ValueError):
                    install_assets(Path(d) / 'assets', [name], lambda n, p: self.fail('download called'), 'revision')

    def test_existing_install_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'assets'
            root.mkdir()
            (root / 'keep').write_text('old')
            with self.assertRaises(FileExistsError):
                install_assets(root, ['a'], lambda n, p: p.write_bytes(b'new'), 'revision')
            self.assertEqual((root / 'keep').read_text(), 'old')

if __name__ == '__main__': unittest.main()
