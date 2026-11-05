#!/usr/bin/env python3
"""Remove source overhead from a built .vescpkg while preserving imports.

Usage: python compact_package.py float_accessories.vescpkg [output.vescpkg]
       python compact_package.py input.vescpkg output.vescpkg --target esp32c3

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


def tighten_source(data):
    """Keep token separators only where Lisp's delimiters do not suffice."""
    result = bytearray()
    delimiters = (b"(", b")", b"{", b"}")
    for token in source_tokens(data):
        if result and result[-1:] not in delimiters and token[:1] not in delimiters:
            result += b" "
        result += token
    return bytes(result) + b"\n"


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
    # Read literal import forms even after tightening puts them on one line.
    # Tokens also keep import-like text inside strings/comments out of this set.
    tokens = source_tokens(root)
    text_names = set()
    for i in range(len(tokens) - 4):
        form = tokens[i:i + 5]
        if (form[:2] == [b"(", b"import"] and form[4] == b")"
                and form[2].startswith(b'"') and form[2].endswith(b'"')
                and form[2][1:-1].lower().endswith((b".lisp", b".lbm"))
                and form[3].startswith(b"'")):
            text_names.add(form[3][1:])
    compact_imports = []
    for name, payload in imports:
        if name in text_names:
            reduced = tighten_source(payload)
            if source_tokens(payload) != source_tokens(reduced):
                raise ValueError("Lisp tokens changed while reducing " + name.decode())
            payload = reduced + b"\0"
        compact_imports.append((name, payload))
    reduced_root = tighten_source(root)
    if source_tokens(root) != source_tokens(reduced_root):
        raise ValueError("Root Lisp tokens changed during reduction")
    result = pack_lisp(data[:2], reduced_root, compact_imports)
    # Independently read back offsets and verify every payload, including binaries.
    decoded_root, decoded_imports = unpack_lisp(result)
    if decoded_root != reduced_root or decoded_imports != compact_imports:
        raise ValueError("Compacted Lisp package failed readback validation")
    return result


TARGETS = ("esp32c3", "esp32c6", "esp32s3", "esp32s31")


def target_lisp(data, target):
    """Keep every Lisp feature, but only native binaries for this chip."""
    if target not in TARGETS:
        raise ValueError("Unsupported package target: " + target)
    root, imports = unpack_lisp(data)
    tokens = source_tokens(root)
    marker = [b"(", b"def", b"fa-package-target", ('"' + target + '"').encode(), b")"]
    already_targeted = tokens[:3] == marker[:3]
    if already_targeted and tokens[:5] != marker:
        raise ValueError("Cannot retarget an already specialized package")
    kept, dropped, found = [], set(), False
    i = 0
    while i < len(tokens):
        form = tokens[i:i + 5]
        if (len(form) == 5 and form[:2] == [b"(", b"import"] and form[4] == b")"
                and form[2].startswith(b'"') and form[3].startswith(b"'")):
            path = form[2][1:-1]
            chip = next((t for t in TARGETS if path.endswith(("_" + t + ".bin").encode())), None)
            if chip:
                if chip != target:
                    dropped.add(form[3][1:])
                    i += 5
                    continue
                found = True
        kept.append(tokens[i])
        i += 1
    if not found:
        raise ValueError("Package has no native imports for " + target)
    root = tighten_source(b" ".join(kept))
    if not already_targeted:
        # Refuse the wrong chip before importing or starting any hardware.
        guard = ('(def fa-package-target "' + target + '")'
                 '(if (!= (str-cmp (sysinfo \'hw-target) fa-package-target) 0)'
                 ' (exit-error "This package requires ' + target + '"))\n').encode()
        root = tighten_source(guard + root)
    return pack_lisp(data[:2], root, [(n, p) for n, p in imports if n not in dropped])


def compact_package(package, target=None):
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
            if target:
                data = target_lisp(data, target)
            after = len(data)
        elif name == b"name" and target:
            suffix = (" (" + target.upper().replace("ESP32", "ESP32-") + ")").encode()
            if not data.endswith(suffix):
                data += suffix
        output += name + b"\0" + struct.pack(">I", len(data)) + data
    if before is None:
        raise ValueError("Package contains no Lisp data")
    result = struct.pack(">I", len(output)) + zlib.compress(output, 9)
    return result, before, after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--target", choices=TARGETS,
                        help="omit the other chip's native binaries; all features remain enabled")
    args = parser.parse_args()
    result, before, after = compact_package(args.package.read_bytes(), args.target)
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
