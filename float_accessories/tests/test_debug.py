"""Diagnostics logger: masks, throttling, prefixes and the diag report."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DebugTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_masks_throttle_prefixes_and_diag(self):
        program = "\n".join((ROOT / p).read_text() for p in ["lib/debug.lisp", "tests/debug.lisp"])
        program = program.replace("@const-start", "").replace("@const-end", "")
        for old, new in [("systime", "test-clock"), ("secs-since", "test-age"), ("print", "test-print")]:
            program = program.replace("(" + old + " ", "(" + new + " ").replace("(" + old + ")", "(" + new + ")")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "debug.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, errors="replace", capture_output=True, timeout=15)
            self.assertIn("SUCCESS", result.stdout, (result.stdout + result.stderr)[-4000:])


if __name__ == "__main__":
    unittest.main()
