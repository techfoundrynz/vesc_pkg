import importlib.util
from pathlib import Path
import struct
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
        self.assertEqual(new_imports[1][1], compact.reduce_source(imports[1][1]) + b"\0")
        self.assertEqual(new_imports[2][1], b"(def answer 42)\n\0")
        self.assertEqual(compact.compact_package(result)[0], result)

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
