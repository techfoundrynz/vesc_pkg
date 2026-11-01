"""Run real LED mode selection and cache flushing with recorded hardware calls."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LedModeTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_modes_precedence_and_cache(self):
        paths = [ROOT.parent / "lib_esp_led_strip/esp_led_defs.lisp",
                 ROOT / "lib/led-vars.lisp", ROOT / "lib/led.lisp",
                 ROOT / "tests/led_modes.lisp"]
        program = "\n".join(p.read_text() for p in paths)
        program = program.replace("ext-esp_led-seg-look ", "test-look ")
        program = program.replace("ext-esp_led-seg-fx-val ", "test-value ")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "led_modes.lisp"
            path.write_text(program)
            # Incremental reading honors production's constant-heap directives,
            # including the mode table; writable caches must stay in RAM.
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-i", "-h", "131072", str(path)],
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)
