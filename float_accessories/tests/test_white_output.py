"""Exercise LED behavior with the host LispBM runner.

make -f tests/lispbm.mk /tmp/fa_white_lbm_runner
LBM_TEST_RUNNER=/tmp/fa_white_lbm_runner python -m unittest discover -s tests
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WhiteOutputTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"),
                         "Set LBM_TEST_RUNNER to the LispBM test runner (see tests/lispbm.mk)")
    def test_actual_led_module(self):
        files = [ROOT.parent / "lib_esp_led_strip/esp_led_defs.lisp",
                 ROOT / "lib/led-vars.lisp", ROOT / "lib/led.lisp",
                 ROOT / "tests/white_output.lisp"]
        # Constant-heap placement is not under test; execute the same source in
        # RAM to fit the host runner's smaller constant heap.
        program = "\n".join(p.read_text().replace("@const-start", "").replace("@const-end", "")
                            for p in files)
        # ext-* names are reserved by LispBM. Route just this hardware call to
        # the test's recording function; all LED decision logic remains intact.
        program = program.replace("ext-esp_led-seg-overlay ", "test-overlay-write ")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "white_output.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=30)
            # The upstream runner returns 1 on success, 0 on test failure.
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
