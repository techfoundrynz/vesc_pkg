"""Restart supervision must leave room in a Wi-Fi-enabled C3's Lisp heap."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkerHeapTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_eight_restart_monitors_fit_retained_heap_budget(self):
        source = (ROOT / "float_accessories.lisp").read_text()
        monitor = source[source.index("(defun spawn-with-restart"):source.index("; The event handler")]
        program = """@const-start
(def DBG-CORE 1)
(def ticks 0)
(defun dbg (category message) nil)
(defun dbg-err (message) nil)
(defun worker () (loop () t { (setq ticks (+ ticks 1)) (sleep 0.01) }))
""" + monitor + "\n@const-end\n"
        program += "\n".join('(spawn-with-restart "worker" 64 worker)' for _ in range(8))
        program += """
(sleep 0.1)
(gc)
(check (< (lbm-heap-state 'get-num-alloc-cells) 360))
(check (> ticks 0))
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "worker_heap.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "2560", str(path)],
                                    text=True, errors="replace", capture_output=True, timeout=15)
            self.assertIn("SUCCESS", result.stdout, (result.stdout + result.stderr)[-4000:])
