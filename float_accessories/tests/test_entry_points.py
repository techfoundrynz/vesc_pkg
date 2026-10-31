"""Root import manifest and lib/entry/*.lisp stay consistent and loadable."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMPORT = re.compile(r'^\(import "([^"]+)" \'([^)\s]+)\)')
EVAL = re.compile(r'^\(read-eval-program ([^)\s]+)\)')


def lisp_lines(path):
    return [line.split(";", 1)[0].strip() for line in path.read_text().splitlines()]


def manifest():
    imports, roots = {}, []
    for line in lisp_lines(ROOT / "float_accessories.lisp"):
        if m := IMPORT.match(line):
            imports[m.group(2)] = m.group(1)
        elif m := EVAL.match(line):
            roots.append(m.group(1))
    return imports, roots


def expand(imports, tag, seen):
    """Files in the order the firmware evaluates them, following entry files."""
    path = ROOT / imports[tag]
    if not tag.startswith("entry-"):
        return [(tag, path)]
    files = []
    for line in lisp_lines(path):
        if line and not EVAL.match(line):
            raise AssertionError(f"{path.name}: entry files only evaluate imports: {line}")
        if m := EVAL.match(line):
            child = m.group(1)
            if child not in imports:
                raise AssertionError(f"{path.name} evaluates {child}, not imported by the root")
            seen.append(child)
            files += expand(imports, child, seen)
    return files


class EntryPointTests(unittest.TestCase):
    def test_every_import_is_evaluated_once(self):
        imports, roots = manifest()
        self.assertTrue(roots and all(tag.startswith("entry-") for tag in roots), roots)
        seen = list(roots)
        for tag in roots:
            expand(imports, tag, seen)
        lisp = [t for t, p in imports.items() if p.endswith(".lisp")]
        self.assertEqual(sorted(seen), sorted(lisp), "each Lisp import is evaluated exactly once")
        entries = sorted(p.stem for p in (ROOT / "lib/entry").glob("*.lisp"))
        self.assertEqual(sorted(t[len("entry-"):] for t in roots), entries)

    def test_expanded_load_order_evaluates(self):
        if not os.environ.get("LBM_TEST_RUNNER"):
            self.skipTest("Set LBM_TEST_RUNNER")
        imports, roots = manifest()
        files = [f for tag in roots for f in expand(imports, tag, [])]
        missing = [str(p) for _, p in files if not p.exists()]
        if missing:
            self.skipTest("Generated sources missing (run make first): " + ", ".join(missing))
        program = "\n".join(p.read_text() for _, p in files)
        program = program.replace("@const-start", "").replace("@const-end", "")
        # Top-level registration must see every bundled adapter after loading.
        program += """
(check (if (and (assoc bms-registry BMS-BACKEND-OW) (assoc bms-registry BMS-BACKEND-SSBMS-UART)
                (assoc bms-registry BMS-BACKEND-SSBMS-BLE) (assoc integration-registry 1)) t nil))
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "load.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "262144", str(path)],
                                    text=True, errors="replace", capture_output=True, timeout=30)
            self.assertIn("SUCCESS", result.stdout, (result.stdout + result.stderr)[-5000:])


if __name__ == "__main__":
    unittest.main()
