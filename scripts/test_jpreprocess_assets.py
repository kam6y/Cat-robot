import hashlib
import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest

from prepare_jpreprocess_assets import extract_checked_archive
from validate_jpreprocess_assets import validate_dictionary, validate_framework, validate_receipt, native_sources, native_artifacts


def digest(data):
    return hashlib.sha256(data).hexdigest()


class JPreprocessAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = [{"path": "dict.words", "size": 4, "sha256": digest(b"data")}]

    def archive(self, name="naist-jdic/dict.words", link=False):
        path = self.root / "archive.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            entry = tarfile.TarInfo(name)
            if link:
                entry.type = tarfile.SYMTYPE
                entry.linkname = "../../outside"
                tar.addfile(entry)
            else:
                entry.size = 4
                tar.addfile(entry, io.BytesIO(b"data"))
        return path

    def test_extracts_only_verified_files(self):
        archive = self.archive()
        output = self.root / "out"
        extract_checked_archive(archive, output, digest(archive.read_bytes()), self.files)
        self.assertTrue((output / "dict.words").is_file())
        self.assertEqual((output / "dict.words").read_bytes(), b"data")
        validate_dictionary(output, self.files)

    def test_bad_archive_checksum_does_not_write(self):
        archive = self.archive()
        output = self.root / "out"
        with self.assertRaises(ValueError):
            extract_checked_archive(archive, output, "0" * 64, self.files)
        self.assertFalse(output.exists())

    def test_traversal_and_link_members_are_rejected(self):
        for name, link in [("naist-jdic/../../outside", False), ("/absolute", False), ("naist-jdic/dict.words", True)]:
            with self.subTest(name=name, link=link):
                archive = self.archive(name, link)
                with self.assertRaises(ValueError):
                    extract_checked_archive(archive, self.root / "out", digest(archive.read_bytes()), self.files)
                self.assertFalse((self.root / "outside").exists())

    def test_missing_or_changed_dictionary_is_rejected(self):
        dictionary = self.root / "dictionary"
        dictionary.mkdir()
        with self.assertRaises(ValueError):
            validate_dictionary(dictionary, self.files)
        (dictionary / "dict.words").write_bytes(b"oops")
        with self.assertRaises(ValueError):
            validate_dictionary(dictionary, self.files)

    def framework(self):
        framework = self.root / "CJPPronunciation.xcframework"
        framework.mkdir()
        entries = []
        for name, architectures, variant in [("ios-arm64", ["arm64"], None), ("ios-arm64_x86_64-simulator", ["arm64", "x86_64"], "simulator")]:
            base = framework / name
            (base / "Headers").mkdir(parents=True)
            (base / "libcjp_pronunciation.a").write_bytes(b"!<arch>\n")
            (base / "Headers/CJPPronunciation.h").write_text("// header")
            (base / "Headers/module.modulemap").write_text("// module")
            entry = {"LibraryIdentifier": name, "LibraryPath": "libcjp_pronunciation.a", "HeadersPath": "Headers", "SupportedArchitectures": architectures, "SupportedPlatform": "ios"}
            if variant:
                entry["SupportedPlatformVariant"] = variant
            entries.append(entry)
        (framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": entries}))
        return framework

    def test_framework_requires_device_and_both_simulator_architectures(self):
        framework = self.framework()
        validate_framework(framework)
        info_path = framework / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["AvailableLibraries"][1]["SupportedArchitectures"] = ["arm64"]
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError):
            validate_framework(framework)

    def test_framework_requires_static_library_and_module(self):
        framework = self.framework()
        (framework / "ios-arm64/Headers/module.modulemap").unlink()
        with self.assertRaises(ValueError):
            validate_framework(framework)

    def test_receipt_rejects_changed_source_or_binary(self):
        source_root = self.root / "repo"
        (source_root / "native/japanese-pronunciation/src").mkdir(parents=True)
        (self.root / "CJPPronunciation.xcframework").mkdir()
        (source_root / "native/japanese-pronunciation/src/lib.rs").write_bytes(b"source")
        (self.root / "CJPPronunciation.xcframework/library.a").write_bytes(b"library")
        receipt = {"sourceFiles": {"native/japanese-pronunciation/src/lib.rs": digest(b"source")}, "artifactFiles": {"CJPPronunciation.xcframework/library.a": digest(b"library")}}
        (self.root / "native-build.json").write_text(json.dumps(receipt))
        validate_receipt(self.root, source_root)
        (source_root / "native/japanese-pronunciation/src/lib.rs").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            validate_receipt(self.root, source_root)
        (source_root / "native/japanese-pronunciation/src/lib.rs").write_bytes(b"source")
        (self.root / "CJPPronunciation.xcframework/library.a").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            validate_receipt(self.root, source_root)


    def test_receipt_ignores_generated_target_but_tracks_new_source(self):
        source_root = self.root / "repo"
        native = source_root / "native/japanese-pronunciation"
        (native / "src").mkdir(parents=True)
        (native / "src/lib.rs").write_bytes(b"source")
        framework = self.root / "CJPPronunciation.xcframework"
        framework.mkdir()
        (framework / "library.a").write_bytes(b"library")
        receipt = {"sourceFiles": native_sources(source_root), "artifactFiles": native_artifacts(self.root)}
        (self.root / "native-build.json").write_text(json.dumps(receipt))
        generated = native / "target/debug/build/serde-123/out/private.rs"
        generated.parent.mkdir(parents=True)
        generated.write_bytes(b"generated")
        (native / "target/Cargo.toml").write_bytes(b"generated manifest")
        validate_receipt(self.root, source_root)
        (native / "src/new_module.rs").write_bytes(b"new real source")
        with self.assertRaises(ValueError):
            validate_receipt(self.root, source_root)


if __name__ == "__main__":
    unittest.main()
