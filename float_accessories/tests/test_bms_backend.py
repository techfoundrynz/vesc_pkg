"""Exercise backend selection and cancellation without UART hardware."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BmsBackendTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_selection_invalid_pins_and_shutdown(self):
        files = ["lib/utils.lisp", "lib/settings-vars.lisp", "lib/settings.lisp",
                 "lib/vehicle.lisp", "lib/lighting-control.lisp",
                 "lib/bms-vars.lisp", "lib/bms.lisp", "lib/bms-backend.lisp",
                 "lib/adapters/ssbms.lisp", "lib/adapters/ssbms-uart.lisp",
                 "tests/bms_backend.lisp"]
        program = "\n".join((ROOT / path).read_text() for path in files)
        program = program.replace("@const-start", "").replace("@const-end", "")
        for old, new in [("systime", "test-clock"), ("secs-since", "test-age"),
                         ("yield", "test-yield"), ("uart-stop", "test-uart-stop")]:
            program = program.replace("(" + old + " ", "(" + new + " ")
            program = program.replace("(" + old + ")", "(" + new + ")")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bms.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 1, (result.stdout + result.stderr)[:5000])
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)
