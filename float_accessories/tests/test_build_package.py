"""Target builds preserve all features and never require the other chips' imports."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import build_package
import compact_package


class BuildPackageTests(unittest.TestCase):
    def test_target_source_preserves_all_feature_code(self):
        original = (ROOT / "float_accessories.lisp").read_text()
        self.assertEqual(build_package.source_for_target(original, None), original)
        for target in compact_package.TARGETS:
            with self.subTest(target=target):
                source = build_package.source_for_target(original, target)
                self.assertEqual(source.partition("@const-start")[2], original.partition("@const-start")[2])
                prologue = source.partition("@const-start")[0]
                self.assertEqual(prologue.count("(import "), 2)
                for other in compact_package.TARGETS:
                    self.assertEqual(prologue.count("_" + other + ".bin"), 2 if target == other else 0)
        with self.assertRaises(ValueError):
            build_package.source_for_target(original, "esp32p4")

    def test_build_writes_only_named_artifact_and_cleans_generated_files(self):
        original = (ROOT / "float_accessories.lisp").read_text()
        descriptor = (ROOT / "pkgdesc.qml").read_text()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "float_accessories.lisp").write_text(original)
            (root / "pkgdesc.qml").write_text(descriptor)
            universal = root / "float_accessories.vescpkg"
            universal.write_bytes(b"existing universal package")

            def fake_builder(args, **kwargs):
                description = Path(args[2]).read_text()
                import re
                source_name = re.search(r'pkgLisp: "([^"]+)"', description)[1]
                output_name = re.search(r'pkgOutput: "([^"]+)"', description)[1]
                source = (root / source_name).read_bytes()
                # The real builder has only the chosen chip's files to resolve.
                self.assertNotIn(b"_esp32s3.bin", source.partition(b"@const-start")[0])
                imports = [(name, b"\x01\0") for name in (b"facfg-esp32c6", b"esp_led-esp32c6")]
                lisp = compact_package.pack_lisp(b"\0\0", source, imports)
                raw = b"VESC Packet\0name\0" + struct.pack(">I", 2) + b"FA"
                raw += b"lispData\0" + struct.pack(">I", len(lisp)) + lisp
                (root / output_name).write_bytes(struct.pack(">I", len(raw)) + zlib.compress(raw))

            with patch.object(build_package, "ROOT", root), patch.object(build_package.subprocess, "run", fake_builder):
                output = build_package.build("vesc_tool", "esp32c6")
            self.assertEqual(output.name, "float_accessories_esp32c6.vescpkg")
            self.assertEqual(universal.read_bytes(), b"existing universal package")
            self.assertFalse(list(root.glob(".fa-build-*")))
            before = output.read_bytes()
            with patch.object(build_package, "ROOT", root), patch.object(build_package.subprocess, "run", side_effect=RuntimeError("builder failed")):
                with self.assertRaises(RuntimeError):
                    build_package.build("vesc_tool", "esp32c6")
            self.assertEqual(output.read_bytes(), before)
            self.assertFalse(list(root.glob(".fa-build-*")))
