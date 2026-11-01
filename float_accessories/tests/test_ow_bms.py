"""Exercise the real OW packet parser through the shared BMS interface."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
class OwBmsTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_packets_publication_commands_and_cleanup(self):
        self.run_lisp("tests/ow_bms.lisp")

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_parsers_send_paths_keys_and_init(self):
        self.run_lisp("tests/ow_bms_parsers.lisp")

    def run_lisp(self, test):
        files = ["lib/utils.lisp", "lib/bms-vars.lisp", "lib/bms.lisp",
                 "lib/bms-backend.lisp", "lib/adapters/ow-bms-vars.lisp",
                 "lib/adapters/ow-bms.lisp", test]
        program = "\n".join((ROOT / p).read_text() for p in files)
        program = program.replace("@const-start", "").replace("@const-end", "")
        for old, new in [("systime", "test-clock"), ("secs-since", "test-age"),
                         ("uart-read", "test-read"), ("uart-stop", "test-stop"),
                         ("send-bms-can", "test-broadcast"), ("aes-ctr-crypt", "test-crypt"),
                         ("uart-write", "test-write"), ("gpio-write", "test-gpio"),
                         ("sleep", "test-sleep"), ("yield", "test-yield"),
                         ("uart-start", "test-start"), ("gpio-configure", "test-configure"),
                         ("crc32", "test-crc32")]:
            program = program.replace("(" + old + " ", "(" + new + " ")
            program = program.replace("(" + old + ")", "(" + new + ")")
        program = program.replace("(set-bms-val field value)", "(test-value field value)")
        program = program.replace("(set-bms-val field index value)", "(test-indexed field index value)")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ow.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "131072", str(path)],
                                    text=True, errors="replace", capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 1, (result.stdout + result.stderr)[:6000])
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)
