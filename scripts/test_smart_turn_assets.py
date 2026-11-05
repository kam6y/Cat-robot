import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from prepare_smart_turn_assets import prepare


class SmartTurnAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "assets"
        self.root.mkdir()
        self.manifest = Path(self.temp.name) / "manifest.json"
        self.data = b"pinned model bytes"
        (self.root / "model.bin").write_bytes(self.data)
        self.entry = {"path": "model.bin", "size": len(self.data),
                      "sha256": hashlib.sha256(self.data).hexdigest()}
        self.write([self.entry])

    def write(self, entries):
        self.manifest.write_text(json.dumps({"files": entries}))

    def test_pinned_files_validate_without_network(self):
        self.assertEqual(prepare(self.root, self.manifest), 1)

    def test_corrupt_or_truncated_bytes_fail_validation(self):
        for data in [b"x" * len(self.data), self.data[:-1]]:
            (self.root / "model.bin").write_bytes(data)
            with self.assertRaisesRegex(ValueError, "checksum"):
                prepare(self.root, self.manifest)

    def test_missing_file_fails_validation(self):
        (self.root / "model.bin").unlink()
        with self.assertRaises(FileNotFoundError):
            prepare(self.root, self.manifest)

    def test_empty_or_duplicate_manifest_fails(self):
        for entries in [[], [self.entry, self.entry]]:
            self.write(entries)
            with self.assertRaises(ValueError):
                prepare(self.root, self.manifest)

    def test_paths_cannot_escape_asset_root(self):
        outside = self.root.parent / "outside"
        outside.write_bytes(self.data)
        (self.root / "alias").symlink_to(outside)
        for name in ["../outside", str(outside), "alias", "folder\\outside"]:
            self.write([dict(self.entry, path=name)])
            with self.assertRaises(ValueError):
                prepare(self.root, self.manifest)


if __name__ == "__main__":
    unittest.main()
