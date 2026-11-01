#!/usr/bin/env python3
"""Build the universal package, or a full-feature package for one ESP chip."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

import compact_package

ROOT = Path(__file__).resolve().parent


def source_for_target(source, target):
    if target is None:
        return source
    if target not in compact_package.TARGETS:
        raise ValueError("Unsupported package target: " + target)
    # Native imports form the root's initial prologue. Keep the rest verbatim,
    # including every feature and any strings/comments in its implementation.
    prologue, separator, body = source.partition("@const-start")
    if not separator:
        raise ValueError("Root source has no native import prologue")
    pattern = re.compile(r'^\s*\(import "[^"]+_(' + "|".join(compact_package.TARGETS)
                         + r')\.bin" \'[^\s)]+\)\s*$')
    kept, found = [], 0
    for line in prologue.splitlines(keepends=True):
        match = pattern.match(line)
        if match and match.group(1) != target:
            continue
        if match:
            found += 1
        kept.append(line)
    if found != 2:
        raise ValueError("Expected config and LED native imports for " + target)
    return "".join(kept) + separator + body


def build(vesc_tool, target=None):
    source = source_for_target((ROOT / "float_accessories.lisp").read_text(), target)
    output = ROOT / ("float_accessories" + ("_" + target if target else "") + ".vescpkg")
    temporary = []
    try:
        # Keep generated source beside the original so relative imports retain
        # their meaning, even when invoked from another working directory.
        for suffix, content in ((".lisp", source), (".qml", None), (".vescpkg", None)):
            with tempfile.NamedTemporaryFile(prefix=".fa-build-", suffix=suffix,
                                             dir=ROOT, delete=False) as stream:
                temporary.append(Path(stream.name))
                if content is not None:
                    stream.write(content.encode())
        descriptor = (ROOT / "pkgdesc.qml").read_text()
        descriptor = descriptor.replace('property string pkgLisp: "float_accessories.lisp"',
            "property string pkgLisp: " + json.dumps(temporary[0].name))
        descriptor = descriptor.replace('property string pkgOutput: "float_accessories.vescpkg"',
            "property string pkgOutput: " + json.dumps(temporary[2].name))
        temporary[1].write_text(descriptor)
        subprocess.run([vesc_tool, "--buildPkgFromDesc", str(temporary[1]),
                        "--testPkgDesc", "custom:Devkit C3",
                        "--testPkgDesc", "custom:Devkit C6 FH4",
                        "--testPkgDesc", "custom:rESCue S3",
                        "--testPkgDesc", "vesc:test"], cwd=ROOT, check=True)
        packed, before, after = compact_package.compact_package(temporary[2].read_bytes(), target)
        temporary[2].write_bytes(packed)
        temporary[2].replace(output)
        print(f"Built {output.name}: Lisp/import data {before} -> {after} bytes")
        return output
    finally:
        for path in temporary:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vesc-tool", default="vesc_tool")
    parser.add_argument("--target", choices=compact_package.TARGETS)
    args = parser.parse_args()
    build(args.vesc_tool, args.target)
