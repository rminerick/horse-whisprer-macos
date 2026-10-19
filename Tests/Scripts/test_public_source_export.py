import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zlib
from unittest.mock import patch
from types import SimpleNamespace


spec = importlib.util.spec_from_file_location("public_export", Path(__file__).resolve().parents[2] / "scripts/export_public_source.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class PublicSourceExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.manifest = self.root / "files.json"
        (self.root / "source.swift").write_text("// Public source\n")
        self.manifest.write_text(json.dumps(["source.swift"]))
        self.output = self.root / "export"

    def testCopiesOnlyReviewedFilesWithoutHistoryOrUntrackedSecrets(self):
        (self.root / ".git").mkdir()
        (self.root / ".git" / "config").write_text("private remote")
        (self.root / ".env").write_text("private settings")
        def check_complete_tree(path):
            self.assertTrue((path / "SOURCE_MANIFEST.json").is_file())
        with patch.object(exporter, "scan", side_effect=check_complete_tree) as scan:
            self.assertEqual(exporter.export(self.root, self.manifest, self.output), 1)
        scan.assert_called_once()
        self.assertEqual({p.name for p in self.output.iterdir()}, {"source.swift", "SOURCE_MANIFEST.json"})
        hashes = json.loads((self.output / "SOURCE_MANIFEST.json").read_text())
        self.assertEqual(hashes, [{"path": "source.swift", "sha256": exporter.hashlib.sha256(
            (self.output / "source.swift").read_bytes()).hexdigest()}])

    def testRejectsSensitiveAndEscapingPathsEvenIfAllowlisted(self):
        for name in ["../outside", "/etc/passwd", ".git/config", "Config/LocalOverrides.xcconfig",
                     ".env", "AuthKey.p8", "tmp/log.txt", ".codex/session.json"]:
            with self.subTest(name=name):
                self.manifest.write_text(json.dumps([name]))
                with self.assertRaises(ValueError):
                    exporter.reviewed_paths(self.root, self.manifest)

    def testRejectsSymlinkedFilesAndParents(self):
        (self.root / "linked.swift").symlink_to(self.root / "source.swift")
        (self.root / "linked-dir").symlink_to(self.root, target_is_directory=True)
        for name in ["linked.swift", "linked-dir/source.swift"]:
            self.manifest.write_text(json.dumps([name]))
            with self.assertRaises(ValueError):
                exporter.reviewed_paths(self.root, self.manifest)

    def testPrivateTextIsRejectedWithoutPrintingTheValue(self):
        private = "/" + "Users" + "/private-person/secret"
        (self.root / "source.swift").write_text(private)
        with self.assertRaises(ValueError) as caught:
            exporter.reviewed_paths(self.root, self.manifest)
        self.assertNotIn(private, str(caught.exception))

    def testScanFailureLeavesNoExport(self):
        with patch.object(exporter, "scan", side_effect=RuntimeError("scan failed")):
            with self.assertRaises(RuntimeError):
                exporter.export(self.root, self.manifest, self.output)
        self.assertFalse(self.output.exists())

    def testScannerCannotInheritLocalExclusions(self):
        def run(command, *, env, capture_output):
            self.assertTrue(capture_output)
            self.assertFalse(any(key.startswith("GITLEAKS_") for key in env))
            ignore = Path(command[command.index("--gitleaks-ignore-path") + 1])
            self.assertEqual(ignore.read_text(), "")
            config = Path(command[command.index("--config") + 1])
            self.assertEqual(config.read_text(), "[extend]\nuseDefault = true\n")
            self.assertIn("--ignore-gitleaks-allow", command)
            self.assertIn("--redact=100", command)
            return SimpleNamespace(returncode=0)
        with patch.object(exporter.shutil, "which", return_value="gitleaks"), \
             patch.dict(exporter.os.environ, {"GITLEAKS_CONFIG": "private-exclusions.toml"}), \
             patch.object(exporter.subprocess, "run", side_effect=run) as process:
            exporter.scan(self.root)
        process.assert_called_once()

    def testNeverOverwritesExistingExport(self):
        self.output.mkdir()
        with self.assertRaises(ValueError):
            exporter.export(self.root, self.manifest, self.output)

    def testPNGMetadataRemovedButPixelChunksPreserved(self):
        def chunk(kind, payload):
            return len(payload).to_bytes(4, "big") + kind + payload + zlib.crc32(kind + payload).to_bytes(4, "big")
        pixels = chunk(b"IDAT", b"unchanged compressed pixels")
        end = chunk(b"IEND", b"")
        signature = b"\x89PNG\r\n\x1a\n"
        path = self.root / "icon.png"
        path.write_bytes(signature + chunk(b"iTXt", b"private metadata") + pixels + end)
        self.assertEqual(exporter.public_bytes(path), signature + pixels + end)
        path.write_bytes(path.read_bytes() + b"hidden data")
        with self.assertRaises(ValueError):
            exporter.public_bytes(path)


if __name__ == "__main__":
    unittest.main()
