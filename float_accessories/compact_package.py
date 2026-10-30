#!/usr/bin/env python3
"""Remove source overhead from a built .vescpkg while preserving imports.

Usage: python compact_package.py float_accessories.vescpkg [output.vescpkg]

The Lisp source, imported buffers and saved runtime image share flash space.
VESC Tool's --reduceLisp also removes import statements, which this firmware's
lazy import loader requires. Compact the finished package instead, retaining
those statements and every native binary byte-for-byte.
"""

import argparse
import os
from pathlib import Path
import re
import struct
import tempfile
import zlib


def read_string(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end], end + 1


def reduce_source(data):
    lines, line = [], []
    quoted = escaped = comment = False
    for char in data.decode("utf-8").rstrip("\0"):
        if comment:
            if char == "\n":
                comment = False
                lines.append("".join(line).strip())
                line = []
            continue
        if quoted:
            line.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            line.append(char)
        elif char == ";":
            comment = True
        elif char == "\n":
            lines.append("".join(line).strip())
            line = []
        else:
            line.append(char)
    if quoted:
        raise ValueError("Unclosed string in packaged Lisp source")
    if line:
        lines.append("".join(line).strip())
    return ("\n".join(line for line in lines if line) + "\n").encode("utf-8")


def source_tokens(data):
    return re.findall(rb'"(?:\\.|[^"\\])*"|[^\s(){}]+|[(){}]',
                      reduce_source(data), re.DOTALL)


def unpack_lisp(data):
    root, offset = read_string(data, 2)  # Keep the two flag bytes.
    count = struct.unpack_from(">H", data, offset)[0]
    offset += 2
    imports = []
    for _ in range(count):
        name, offset = read_string(data, offset)
        start, size = struct.unpack_from(">II", data, offset)
        offset += 8
        if start + 2 + size > len(data):
            raise ValueError("Import extends beyond packaged Lisp data")
        imports.append((name, data[start + 2:start + 2 + size]))
    return root, imports


def pack_lisp(flags, root, imports):
    prefix = flags + root + b"\0" + struct.pack(">H", len(imports))
    offset = len(prefix) + sum(len(name) + 9 for name, _ in imports) - 2
    entries = []
    for name, data in imports:
        offset = (offset + 3) & ~3
        entries.append((name, offset, data))
        offset += len(data)
    result = bytearray(prefix)
    for name, offset, data in entries:
        result += name + b"\0" + struct.pack(">II", offset, len(data))
    for _name, offset, data in entries:
        result += b"\0" * ((-(len(result) - 2)) % 4)
        if len(result) - 2 != offset:
            raise ValueError("Incorrect native import alignment")
        result += data
    return bytes(result)


def compact_lisp(data):
    root, imports = unpack_lisp(data)
    # Match the literal import syntax accepted by VESC Tool's package builder.
    text_names = {name.encode("utf-8") for path, name in re.findall(
        r'^\s*\(import\s+"([^"\n]+)"\s+\'([^\s)]+)\s*\)',
        root.decode("utf-8"), re.MULTILINE)
        if path.lower().endswith((".lisp", ".lbm"))}
    compact_imports = []
    for name, payload in imports:
        if name in text_names:
            reduced = reduce_source(payload)
            if source_tokens(payload) != source_tokens(reduced):
                raise ValueError("Lisp tokens changed while reducing " + name.decode())
            payload = reduced + b"\0"
        compact_imports.append((name, payload))
    reduced_root = reduce_source(root)
    if source_tokens(root) != source_tokens(reduced_root):
        raise ValueError("Root Lisp tokens changed during reduction")
    result = pack_lisp(data[:2], reduced_root, compact_imports)
    # Independently read back offsets and verify every payload, including binaries.
    decoded_root, decoded_imports = unpack_lisp(result)
    if decoded_root != reduced_root or decoded_imports != compact_imports:
        raise ValueError("Compacted Lisp package failed readback validation")
    return result


def compact_package(package):
    raw = zlib.decompress(package[4:])
    if struct.unpack_from(">I", package)[0] != len(raw):
        raise ValueError("Incorrect package uncompressed size")
    header, offset = read_string(raw, 0)
    if header != b"VESC Packet":
        raise ValueError("Not a VESC package")
    output = bytearray(header + b"\0")
    before = after = None
    while offset < len(raw):
        name, offset = read_string(raw, offset)
        size = struct.unpack_from(">I", raw, offset)[0]
        offset += 4
        if offset + size > len(raw):
            raise ValueError("Truncated package field")
        data = raw[offset:offset + size]
        offset += size
        if name == b"lispData":
            before = len(data)
            data = compact_lisp(data)
            after = len(data)
        output += name + b"\0" + struct.pack(">I", len(data)) + data
    if before is None:
        raise ValueError("Package contains no Lisp data")
    result = struct.pack(">I", len(output)) + zlib.compress(output, 9)
    return result, before, after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    args = parser.parse_args()
    result, before, after = compact_package(args.package.read_bytes())
    output = args.output or args.package
    # Never leave a partially written package at the final path.
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temp:
        temporary = Path(temp.name)
        temp.write(result)
    try:
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Compacted Lisp/import data: {before} -> {after} bytes "
          f"({before - after} bytes recovered for the runtime image)")


if __name__ == "__main__":
    main()
