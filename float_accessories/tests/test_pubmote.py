"""Pubmote loop phases with radio, channel and pairing helpers faked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PubmoteLoopTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_version_exchange_retries_after_lost_first_version(self):
        files = ["pubmote/pubmote-consts.lisp", "pubmote/pubmote-vars.lisp",
                 "pubmote/pubmote-utils.lisp", "pubmote/pubmote.lisp", "tests/pubmote_version.lisp"]
        program = "\n".join((ROOT / p).read_text() for p in files)
        program = program.replace("@const-start", "").replace("@const-end", "")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "version.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, errors="replace", capture_output=True, timeout=30)
            self.assertIn("SUCCESS", result.stdout, (result.stdout + result.stderr)[-4000:])

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_pairing_telemetry_and_rate(self):
        files = ["pubmote/pubmote-consts.lisp", "pubmote/pubmote-vars.lisp",
                 "pubmote/pubmote-utils.lisp", "pubmote/pubmote.lisp", "tests/pubmote_loop.lisp"]
        program = "\n".join((ROOT / p).read_text() for p in files)
        program = program.replace("@const-start", "").replace("@const-end", "")
        for old, new in [("systime", "test-clock"), ("secs-since", "test-age"), ("yield", "test-yield")]:
            program = program.replace("(" + old + " ", "(" + new + " ").replace("(" + old + ")", "(" + new + ")")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pubmote.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, errors="replace", capture_output=True, timeout=30)
            self.assertIn("SUCCESS", result.stdout, (result.stdout + result.stderr)[-4000:])


if __name__ == "__main__":
    unittest.main()
