import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compact_package", ROOT / "compact_package.py")
compact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compact)


def package_fields(fields):
    raw = bytearray(b"VESC Packet\0")
    for name, data in fields:
        raw += name + b"\0" + struct.pack(">I", len(data)) + data
    return struct.pack(">I", len(raw)) + zlib.compress(raw, 9)


def unpack_fields(package):
    raw = zlib.decompress(package[4:])
    _, offset = compact.read_string(raw, 0)
    result = []
    while offset < len(raw):
        name, offset = compact.read_string(raw, offset)
        size = struct.unpack_from(">I", raw, offset)[0]
        offset += 4
        result.append((name, raw[offset:offset + size]))
        offset += size
    return result


class CompactPackageTests(unittest.TestCase):
    def test_target_build_keeps_features_and_only_matching_native_binaries(self):
        root = b'''(import "fa_esp32c3.bin" 'native-c3)
(import "fa_esp32c6.bin" 'native-c6)
(import "fa_esp32s3.bin" 'native-s3)
(import "fa_esp32s31.bin" 'native-s31)
(import "ow.lisp" 'ow)(import "aux.lisp" 'aux)
(read-eval-program ow)(read-eval-program aux)
'''
        imports = [(b"native-c3", b"\x01\x02\x03\0"),
                   (b"native-c6", b"\x07\x08\x09\0"),
                   (b"native-s3", b"\x04\x05\x06\0"),
                   (b"native-s31", b"\x0a\x0b\x0c\0"),
                   (b"ow", b"(def ow-enabled t)\0"),
                   (b"aux", b"(def aux-enabled t)\0")]
        original = package_fields([(b"name", b"Float Accessories"),
                                   (b"lispData", compact.pack_lisp(b"\x12\x34", root, imports)),
                                   (b"qmlFile", b"Item {}")])
        for target, keep, remove in (("esp32c3", b"native-c3", b"native-s3"),
                                     ("esp32c6", b"native-c6", b"native-c3"),
                                     ("esp32s3", b"native-s3", b"native-c3"),
                                     ("esp32s31", b"native-s31", b"native-c3")):
            result, _, _ = compact.compact_package(original, target)
            fields = dict(unpack_fields(result))
            new_root, new_imports = compact.unpack_lisp(fields[b"lispData"])
            self.assertEqual(dict(new_imports)[keep], dict(imports)[keep])
            self.assertNotIn(remove, dict(new_imports))
            self.assertNotIn(b"'" + remove, new_root)
            self.assertIn(b"(read-eval-program ow)", new_root)
            self.assertIn(b"(read-eval-program aux)", new_root)
            self.assertIn(b'(def fa-package-target "' + target.encode() + b'")', new_root)
            self.assertEqual(fields[b"qmlFile"], b"Item {}")
            self.assertEqual(fields[b"lispData"][:2], b"\x12\x34")
            self.assertEqual(compact.compact_package(result, target)[0], result)
            other = "esp32s3" if target == "esp32c3" else "esp32c3"
            with self.assertRaisesRegex(ValueError, "Cannot retarget"):
                compact.compact_package(result, other)

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_target_guard_refuses_wrong_chip_before_loading_features(self):
        source = b'(import "fa_esp32c3.bin" \'native)(def feature-loaded t)'
        data = compact.pack_lisp(b"\0\0", source, [(b"native", b"\x01\0")])
        root, _ = compact.unpack_lisp(compact.target_lisp(data, "esp32c3"))
        for board, success in (("esp32c3", True), ("esp32s3", False)):
            program = ('(defun sysinfo (key) "' + board + '")(defun import (path tag) t)\n').encode() + root
            program += b"\n(check feature-loaded)"
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "target.lisp"
                path.write_bytes(program)
                result = subprocess.run([os.environ["LBM_TEST_RUNNER"], str(path)],
                                        text=True, capture_output=True, timeout=15)
                if success:
                    self.assertIn("SUCCESS", result.stdout)
                else:
                    self.assertNotIn("SUCCESS", result.stdout)
                    self.assertIn("This package requires esp32c3", result.stdout)

    def test_source_preserves_strings_and_imports(self):
        original = b'''; whole-line comment
  (import "lib/test.lisp" 'test) ; keep this import
  (def text " spaces ; inside string ")
  (def quote "escaped \\" quote ; still string") ; remove this
  (def lines "first
    second   
 third")
'''
        expected = b'''(import "lib/test.lisp" 'test)
(def text " spaces ; inside string ")
(def quote "escaped \\" quote ; still string")
(def lines "first
    second   
 third")
'''
        self.assertEqual(compact.reduce_source(original), expected)

    def test_package_roundtrip_preserves_binary_payloads_and_metadata(self):
        root = b'''; Root comment
  (import "native.bin" 'native)
  (import "lib/module.lisp" 'module)
  (import "other.lbm" 'other)
  (read-eval-program module)
'''
        binary = bytes.fromhex("cafebabe") + bytes(range(256)) + b"\0; native data\xff"
        imports = [(b"native", binary),
                   (b"module", b'; module comment\n  (def colour "RGB + W; \\\"white\\\"")\n\0'),
                   (b"other", b'; other comment\n (def answer 42)\n\0')]
        lisp = compact.pack_lisp(b"\x12\x34", root, imports)
        original = package_fields([(b"name", b"test"), (b"lispData", lisp),
                                   (b"qmlFile", b"// QML stays intact\nItem {}"),
                                   (b"unknown-future-field", b"\xff\0unchanged")])
        result, before, after = compact.compact_package(original)
        self.assertEqual(before, len(lisp))
        self.assertLess(after, before)
        fields = unpack_fields(result)
        for (name, old), (_, new) in zip(unpack_fields(original), fields):
            if name != b"lispData":
                self.assertEqual(new, old)
        reduced_lisp = dict(fields)[b"lispData"]
        self.assertEqual(reduced_lisp[:2], b"\x12\x34")
        new_root, new_imports = compact.unpack_lisp(reduced_lisp)
        self.assertIn(b'(import "native.bin"', new_root)
        self.assertIn(b'(import "lib/module.lisp"', new_root)
        self.assertEqual(new_imports[0], imports[0])
        self.assertEqual(new_imports[1][1], compact.tighten_source(imports[1][1]) + b"\0")
        self.assertEqual(new_imports[2][1], b"(def answer 42)\n\0")
        self.assertEqual(compact.compact_package(result)[0], result)

    def test_tightening_preserves_tokens_strings_and_directives(self):
        source = b'''@const-start
 (def text " spaces (and braces {}) ; inside string ")
 (def escaped "escaped \\\" quote")
 (def xs '( 1 2 (3 4) ))
 (def bytes [1 2 3])
 (defun value (x) { (+ x 1) })
@const-end
'''
        tight = compact.tighten_source(source)
        self.assertEqual(compact.source_tokens(tight), compact.source_tokens(source))
        self.assertLess(len(tight), len(compact.reduce_source(source)))
        self.assertIn(b'" spaces (and braces {}) ; inside string "', tight)
        self.assertEqual(compact.tighten_source(tight), tight)

    def test_tight_root_still_identifies_every_text_import(self):
        root = b'''(import "native.bin" 'native)(import "module.lisp" 'module)
(def text "(import \\\"not-a-module.lisp\\\" 'native)")
'''
        imports = [(b"native", b"\xff\0; binary"),
                   (b"module", b"; comment\n (def answer 42)\n\0")]
        result = compact.compact_lisp(compact.pack_lisp(b"\0\0", root, imports))
        _, decoded = compact.unpack_lisp(result)
        self.assertEqual(decoded[0], imports[0])
        self.assertEqual(decoded[1][1], b"(def answer 42)\n\0")
        self.assertEqual(compact.compact_lisp(result), result)

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_tight_source_with_real_incremental_reader(self):
        source = b'''@const-start
 (def xs '(1 2 (3 4)))
 (def bytes [1 2 3])
 (def text " keep ; {} (spaces) ")
 (defun plus (a b) { (+ a b) })
@const-end
(check (and (= (plus 2 3) 5) (= (bufget-u8 bytes 1) 2)
            (eq xs '(1 2 (3 4))) (eq text " keep ; {} (spaces) ")))
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "tight.lisp"
            path.write_bytes(compact.tighten_source(source))
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-i", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUCCESS", result.stdout)

    def test_import_offsets_are_four_byte_aligned(self):
        for root_length in range(1, 9):
            for first_size in range(1, 9):
                imports = [(b"a", b"x" * first_size), (b"long-tag", b"data")]
                packed = compact.pack_lisp(b"\0\0", b" " * root_length, imports)
                _, offset = compact.read_string(packed, 2)
                count = struct.unpack_from(">H", packed, offset)[0]
                offset += 2
                for _ in range(count):
                    _, offset = compact.read_string(packed, offset)
                    start, _ = struct.unpack_from(">II", packed, offset)
                    self.assertEqual(start % 4, 0)
                    offset += 8
                self.assertEqual(compact.unpack_lisp(packed)[1], imports)

    def test_rejects_unclosed_string_and_incorrect_package_size(self):
        with self.assertRaises(ValueError):
            compact.reduce_source(b'(def text "unclosed)')
        package = package_fields([(b"lispData", compact.pack_lisp(b"\0\0", b"(main)", []))])
        with self.assertRaises(ValueError):
            compact.compact_package(b"\0\0\0\0" + package[4:])


if __name__ == "__main__":
    unittest.main()
