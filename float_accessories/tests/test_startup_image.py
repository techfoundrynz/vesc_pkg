"""Native extensions must be registered when the first startup image is saved."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StartupImageTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_native_selector_for_all_supported_chips(self):
        root = (ROOT / "float_accessories.lisp").read_text()
        loader = root[root.index("(defun load-native-libs"):root.index("; Boot timings:")]
        loader = loader.replace("(ext-facfg-get ", "(test-cfg-get ")
        for target in ("esp32c3", "esp32c6", "esp32s3", "esp32s31"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                # Define only this chip's imports, as the installer will do.
                # Referencing an omitted chip in the executed branch must fail.
                program = f'''
(def facfg-{target} 1)
(def esp_led-{target} 2)
(def loaded nil)
(def DBG-CORE 1)
(def esp_led-version 1)
(defun check-platform () t)
(defun sysinfo (key) "{target}")
(defun load-native-lib (blob) {{ (setq loaded (cons blob loaded)) t }})
(defun test-cfg-get (key) 1)
(defun dbg (category text) nil)
''' + loader + "\n(load-native-libs)\n(check (eq loaded '(2 1)))\n"
                path = Path(tmp) / "native_selector.lisp"
                path.write_text(program)
                result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                        text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("SUCCESS", result.stdout)

    def run_lisp(self, program):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "startup.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertIn("SUCCESS", result.stdout, result.stdout + result.stderr)

    def boot_prefix(self, source):
        return source[source.index("; Boot state protocol"):source.index("; Every bundled")]

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_cold_save_warm_reload_and_late_state_query(self):
        source = (ROOT / "float_accessories.lisp").read_text()
        root = source[source.index("(defun load-native-libs"):]
        root = root.replace("@const-start", "").replace("@const-end", "")
        for old, new in [("(load-native-libs)", "(test-load)"),
                         ("(image-save)", "(test-save)"),
                         ("(setup)", "(test-setup)"), ("(init)", "(test-init)"),
                         ("(secs-since 0)", "0.0")]:
            root = root.replace(old, new)
        program = """
(def loads 0)
(def saves 0)
(def starts 0)
(def saved-state 0)
(def reports nil)
(defun expect (actual wanted)
    (if (not (eq actual wanted)) (exit-error (to-str (list actual 'wanted wanted)))))
(defun send-data (message) (setq reports (append reports (list message))))
(defun print (message) nil)
(defun test-load () { (expect fa-boot-state 2) (setq loads (+ loads 1)) })
(defun test-save () {
    (expect loads 1)
    (expect fa-boot-state 3)
    (setq saved-state fa-boot-state)
    (setq saves (+ saves 1))
    t
})
(defun test-setup () (expect fa-boot-state 4))
(defun test-init () { (expect fa-boot-state 4) (setq starts (+ starts 1)) })
""" + self.boot_prefix(source) + root + """
(expect loads 1)
(expect saves 1)
(expect starts 1)
(expect reports '("fa-boot-state 1" "fa-boot-state 2" "fa-boot-state 3" "fa-boot-state 4" "fa-boot-state 5"))
; The UI was closed when Ready was emitted. Querying recovers the same state,
; repeatedly, without acknowledging or rewriting the startup image.
(setq reports nil)
(fa-boot-status)
(fa-boot-status)
(expect reports '("fa-boot-state 5" "fa-boot-state 5"))
(expect saves 1)
; The saved image captured CreatingImage, then main advances on warm boot.
(setq fa-boot-state saved-state)
(setq reports nil)
(main)
(expect reports '("fa-boot-state 2" "fa-boot-state 4" "fa-boot-state 5"))
(expect loads 2)
(expect starts 2)
(expect saves 1)
(main)
(expect loads 3)
(expect saves 1)
(expect starts 3)
(check t)
"""
        self.run_lisp(program)

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_failed_image_save_reports_failure_and_does_not_start(self):
        source = (ROOT / "float_accessories.lisp").read_text()
        cold_start = source[source.rindex("\n(fa-set-boot-state 2)"):]
        for result in ("nil", '(exit-error "flash failed")'):
            with self.subTest(result=result):
                program = """
(def starts 0)
(def reports nil)
(defun load-native-libs () t)
(defun print (message) nil)
(defun send-data (message) (setq reports (append reports (list message))))
(defun run-main (reload) (setq starts (+ starts 1)))
""" + self.boot_prefix(source) + "\n(defun image-save () " + result + ")\n(defun cold-start () {\n" + cold_start + """
})
(def result (trap (cold-start)))
(check (and (eq (ix result 0) 'exit-error)
    (= fa-boot-state 6) (= starts 0)
    (eq reports '("fa-boot-state 1" "fa-boot-state 2" "fa-boot-state 3" "fa-boot-state 6"))))
"""
                self.run_lisp(program)
