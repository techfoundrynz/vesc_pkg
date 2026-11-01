"""LED segment setup, flush cache and PWM highbeams with every lib call recorded."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LedCoreTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_setup_flush_and_highbeam(self):
        self.run_lisp("tests/led_core.lisp")

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_decide_mode_brightness_and_flags(self):
        self.run_lisp("tests/led_decide.lisp")

    def run_lisp(self, test):
        files = [ROOT.parent / "lib_esp_led_strip/esp_led_defs.lisp", ROOT / "lib/debug.lisp", ROOT / "lib/utils.lisp",
                 ROOT / "lib/led-vars.lisp", ROOT / "lib/led.lisp", ROOT / test]
        program = "\n".join(p.read_text().replace("@const-start", "").replace("@const-end", "")
                            for p in files)
        # ext-* names are reserved by LispBM; route the lib calls to recorders.
        program = program.replace("(ext-esp_led-", "(test-led-")
        for old, new in [("systime", "test-clock"), ("secs-since", "test-age")]:
            if "decide" in test:
                program = program.replace("(" + old + " ", "(" + new + " ").replace("(" + old + ")", "(" + new + ")")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "led_core.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, errors="replace", capture_output=True, timeout=30)
            self.assertIn("SUCCESS", result.stdout, (result.stdout + result.stderr)[-4000:])


if __name__ == "__main__":
    unittest.main()
