"""Run core startup without an adapter, and exercise the bundled provider lifecycle."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VehicleTests(unittest.TestCase):
    def run_lisp(self, adapter, test):
        if not os.environ.get("LBM_TEST_RUNNER"):
            self.skipTest("Set LBM_TEST_RUNNER")
        files = [ROOT / "lib/utils.lisp", ROOT / "lib/settings-vars.lisp",
                 ROOT / "lib/settings.lisp", ROOT / "lib/vehicle.lisp",
                 ROOT / "lib/lighting-control.lisp", ROOT / "lib/can.lisp",
                 ROOT.parent / "lib_esp_led_strip/esp_led_defs.lisp",
                 ROOT / "lib/led-vars.lisp", ROOT / "lib/led.lisp",
                 ROOT / "pubmote/pubmote-consts.lisp", ROOT / "lib/commands.lisp"]
        if adapter:
            files.append(ROOT / "lib/adapters/refloat.lisp")
        program = "\n".join(p.read_text() for p in files)
        # Test the real setup/init, but replace hardware loading and thread
        # launching below. No GPIO, radio, CAN bus or real device is involved.
        main = (ROOT / "float_accessories.lisp").read_text()
        program += "\n" + main[main.index("(defun main ()"):main.rindex("@const-end")]
        program += "\n" + (ROOT / "tests/vehicle_setup.lisp").read_text()
        program += "\n" + (ROOT / "tests" / test).read_text()
        program = program.replace("@const-start", "").replace("@const-end", "")
        for old, new in [("systime", "test-clock"), ("secs-since", "test-age"),
                         ("sysinfo", "test-sysinfo"), ("send-data", "test-send"),
                         ("can-cmd", "test-can-cmd"), ("event-enable", "test-event"),
                         ("yield", "test-yield"),
                         ("ext-facfg-store", "test-store")]:
            program = program.replace("(" + old + " ", "(" + new + " ")
            program = program.replace("(" + old + ")", "(" + new + ")")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "vehicle.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "131072", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 1, (result.stdout + result.stderr)[:5000])
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)

    def test_standalone_without_adapter_import(self):
        self.run_lisp(False, "vehicle_standalone.lisp")

    def test_standalone_with_adapter_disabled(self):
        self.run_lisp(True, "vehicle_standalone.lisp")

    def test_refloat_discovery_parsing_and_disable(self):
        self.run_lisp(True, "vehicle_refloat.lisp")
