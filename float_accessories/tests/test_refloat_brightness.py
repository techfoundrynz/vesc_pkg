"""Exercise production CAN parsing and LED decisions with the host LispBM runner."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RefloatBrightnessTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_poll_parse_and_render_targets(self):
        files = [ROOT / "lib/bms-vars.lisp", ROOT / "lib/bms.lisp",
                 ROOT / "lib/bms-backend.lisp", ROOT / "lib/vehicle.lisp", ROOT / "lib/lighting-control.lisp",
                 ROOT / "lib/can.lisp", ROOT / "lib/adapters/refloat.lisp",
                 ROOT.parent / "lib_esp_led_strip/esp_led_defs.lisp", ROOT / "lib/led-vars.lisp",
                 ROOT / "lib/led.lisp", ROOT / "tests/refloat_brightness.lisp"]
        program = "\n".join(p.read_text() for p in files)
        program = program.replace("@const-start", "").replace("@const-end", "")
        # Deterministic clock and capture CAN sends; the production parser,
        # polling throttle, timeout checks and brightness decisions are intact.
        program = program.replace("(systime)", "(test-clock)")
        program = program.replace("(secs-since ", "(test-age ")
        program = program.replace("(send-data ", "(test-send ")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "refloat_brightness.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
