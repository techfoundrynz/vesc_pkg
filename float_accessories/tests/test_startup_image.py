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
        for target in ("esp32c3", "esp32c6", "esp32s3"):
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

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_cold_save_and_warm_native_reload(self):
        root = (ROOT / "float_accessories.lisp").read_text()
        # Exercise the root's actual save/start sequencing and main wrapper.
        # Imports are covered separately; these stubs stand in for the native
        # loader, image persistence, hardware setup and worker creation.
        root = root[root.index("(defun load-native-libs"):]
        root = root.replace("@const-start", "").replace("@const-end", "")
        for old, new in [("(load-native-libs)", "(test-load)"),
                         ("(image-save)", "(test-save)"),
                         ("(setup)", "(test-setup)"),
                         ("(init)", "(test-init)"),
                         ("(secs-since 0)", "0.0")]:
            root = root.replace(old, new)
        program = """
(def loads 0)
(def saves 0)
(def starts 0)
(def announcements 0)
(defun send-data (message) {
    (expect saves 1)
    (expect startup-image-created t)
    (expect message "fa-image-created")
    (setq announcements (+ announcements 1))
})
(defun print (message) nil)
(defun expect (actual wanted)
    (if (not (eq actual wanted)) (exit-error (to-str (list actual 'wanted wanted)))))
(defun test-load () (setq loads (+ loads 1)))
(defun test-save () {
    (expect loads 1)
    (expect startup-image-created nil)
    (setq saves (+ saves 1))
    t
})
(defun test-setup () t)
(defun test-init () (setq starts (+ starts 1)))
""" + root + """
; Cold start loads once, then saves the table, then starts the application.
(expect loads 1)
(expect saves 1)
(expect starts 1)
(expect announcements 1)
; Restore the value actually saved in the image before simulating warm boots.
(setq startup-image-created nil)
; The firmware calls main with no arguments on every image boot. Each boot
; must rebind executable pointers without rewriting the saved image.
(main)
(expect loads 2)
(expect saves 1)
(expect starts 2)
(main)
(expect loads 3)
(expect saves 1)
(expect starts 3)
(expect announcements 1)
(check t)
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "startup.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUCCESS", result.stdout)

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_failed_image_save_does_not_announce_or_start(self):
        source = (ROOT / "float_accessories.lisp").read_text()
        cold_start = source[source.rindex("\n(load-native-libs)"):]
        program = """
(def startup-image-created nil)
(def starts 0)
(def announcements 0)
(defun load-native-libs () t)
(defun print (message) nil)
(defun image-save () nil)
(defun send-data (message) (setq announcements (+ announcements 1)))
(defun run-main (reload) (setq starts (+ starts 1)))
(defun cold-start () {
""" + cold_start + """
})
(def result (trap (cold-start)))
(check (and (eq (ix result 0) 'exit-error)
    (eq startup-image-created nil) (= starts 0) (= announcements 0)))
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "failed_startup.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUCCESS", result.stdout)
