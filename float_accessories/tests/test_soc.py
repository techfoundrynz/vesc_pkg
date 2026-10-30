"""Run using LBM_TEST_RUNNER (see tests/lispbm.mk)."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SocTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"),
                         "Set LBM_TEST_RUNNER to the LispBM test runner (see tests/lispbm.mk)")
    def test_voltage_curves_and_normalization(self):
        can_source = (ROOT / "lib/can.lisp").read_text()
        # Use the production curves without initializing unrelated CAN state.
        curves = can_source[can_source.index("(defun get-voltage-curve"):
                            can_source.index("; --- CAN discovery")]
        program = "\n".join([(ROOT / "lib/utils.lisp").read_text(), curves,
                             (ROOT / "tests/soc.lisp").read_text()])
        program = program.replace("@const-start", "").replace("@const-end", "")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "soc.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=30)
            # The upstream runner returns 1 on success, 0 on test failure.
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
