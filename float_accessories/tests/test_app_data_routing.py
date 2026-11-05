"""Source-aware status replies stay on their requesting connection."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AppDataRoutingTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_reply_scope_cleanup_and_legacy_fallback(self):
        source = (ROOT / "lib/utils.lisp").read_text(encoding="utf-8")
        functions = source[source.index("(defun dispatch-trapped"):source.index("(defun event-handler")]
        program = r'''
(def route 0)
(def replies nil)
(def errors nil)
(def enabled nil)
(def modern t)
(def command-count 0)
(defun check-eq (got expected)
    (if (not (eq got expected)) (exit-error (to-str (list got 'expected expected)))))
(defun dbg-err (message) (setq errors (cons message errors)))
(defun app-data-reply (source) {
    (if (= source 99) (exit-error 'stale-source))
    (setq route source)
})
(defun event-enable (name) {
    (if (and (eq name 'event-data-rx-source) (not modern))
        (exit-error 'unsupported-event))
    (setq enabled (cons name enabled))
})
(defun send-data (message) (setq replies (cons (list route message) replies)))
(defun command-rx (data) {
    (setq command-count (+ command-count 1))
    (send-data data)
    (if (eq data "bad") (exit-error 'bad-command))
})
''' + functions + r'''
(enable-app-data-events)
(check-eq enabled '(event-data-rx-source))
(setq modern nil)
(enable-app-data-events)
(check-eq enabled '(event-data-rx event-data-rx-source))
(command-rx-from 11 "usb")
(check-eq route 0)
(command-rx-from 22 "ble")
(check-eq route 0)
(check-eq replies '((22 "ble") (11 "usb")))
(command-rx-from 11 "bad")
(check-eq route 0)
(check-eq (length errors) 1)
(command-rx-from 99 "stale")
(check-eq route 0)
(check-eq command-count 3)
(check-eq (length errors) 2)
(send-data "unsolicited")
(check-eq (car replies) '(0 "unsolicited"))
(check t)
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app_data_routing.lisp"
            path.write_text(program, encoding="utf-8")
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)
