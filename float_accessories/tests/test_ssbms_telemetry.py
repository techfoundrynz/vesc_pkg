"""Live SSBMS card: real Lisp snapshot, UI decoding, freshness and visibility."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SsbmsTelemetryTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_snapshot_uses_complete_active_bms_and_last_telemetry_time(self):
        settings = (ROOT / "lib/settings.lisp").read_text()
        snapshot = settings[settings.index("(defun ssbms-state"):settings.index("(defun input-state")]
        program = """
(def BMS-BACKEND-SSBMS-UART 2)
(def BMS-BACKEND-SSBMS-BLE 3)
(def bms-active-backend 3)
(def bms-valid t)
(def bms-status 32)
(def bms-last-activity-time 10.0)
(def now 10.5)
(def active t)
(def test-cell-count 12)
(def message nil)
(defun min (a b) (if (< a b) a b))
(defun max (a b) (if (> a b) a b))
(defun bms-backend-active (id) active)
(defun secs-since (stamp) (- now stamp))
(defun bms-soc () 0.75)
(defun get-bms-val (field) (match field
    (bms-cell-num test-cell-count) (bms-v-tot 48.0) (bms-i-in -2.5)
    (bms-temps-adc (if (= (car (rest-args)) 0) 23.0 24.0))
    (bms-temp-ic 28.0) (bms-chg-allowed 1)
    (bms-v-cell (+ 3.8 (* 0.001 (car (rest-args)))))))
(defun send-data (value) (setq message value))
(defun expect (a b) (if (not (eq a b)) (exit-error (to-str (list a 'wanted b)))))
""" + snapshot + """
(ssbms-state)
(expect (str-cmp message "ssbms-state 3 0.5 48.00 75.0 -2.50 23.0 24.0 28.0 1 32 12 3.800 3.801 3.802 3.803 3.804 3.805 3.806 3.807 3.808 3.809 3.810 3.811") 0)
; Polling again cannot refresh the age of an unchanged BMS snapshot.
(setq now 12.5)
(ssbms-state)
(expect (str-cmp (ix (str-split message " ") 2) "2.5") 0)
(setq bms-active-backend 2)
(setq test-cell-count 32)
(ssbms-state)
(expect (length (str-split message " ")) 44)
(expect (str-cmp (ix (str-split message " ") 43) "3.831") 0)
(loopforeach invalid '(partial stopped other-backend) {
    (setq bms-valid (not (eq invalid 'partial)))
    (setq active (not (eq invalid 'stopped)))
    (setq bms-active-backend (if (eq invalid 'other-backend) 1 3))
    (ssbms-state)
    (expect (str-cmp message (if (eq invalid 'partial) "ssbms-state 3 -1" "ssbms-state 0 -1")) 0)
})
(check t)
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "snapshot.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 1, (result.stdout + result.stderr)[-10000:])
            self.assertIn("SUCCESS", result.stdout)

    def test_ui_decodes_cells_rejects_bad_frames_and_ages_without_new_telemetry(self):
        node = shutil.which("node") or shutil.which("node.exe")
        if not node and Path("/mnt/c/Program Files/nodejs/node.exe").exists():
            node = "/mnt/c/Program Files/nodejs/node.exe"
        if not node:
            self.skipTest("Requires Node.js")
        qml = (ROOT / "ui.qml.in").read_text()
        start = qml.index("function applySsbmsTelemetry(")
        brace = qml.index("{", start)
        depth, end = 1, brace + 1
        while depth:
            depth += (qml[end] == "{") - (qml[end] == "}")
            end += 1
        def binding(name):
            return re.search(r"readonly property (?:real|bool) " + name + r": (.*?)(?=\n    \S)",
                             qml, re.S).group(1).strip()
        script = """
const assert = require('assert');
let ssbmsTelemetry = null, ssbmsTelemetryClock = 0;
let statusTimeout=false, ssbmsUartSelected=false, ssbmsBleSelected=true;
let bmsConnected=0, ssbmsBleLinkConnected=true, bmsBackend={currentIndex:3};
let clock=10000; Date.now=()=>clock;
""" + qml[start:end] + "\n" + "\n".join(
            "function " + name + "(){return (" + binding(name) + ");}"
            for name in ("ssbmsTelemetryAge", "ssbmsTelemetryAvailable", "ssbmsTelemetryConnected")) + """
const cells=Array.from({length:12},(_,i)=>(3.8+i*0.001).toFixed(3));
const frame='ssbms-state 3 0.5 48.00 75.0 -2.50 23.0 24.0 28.0 1 32 12 '+cells.join(' ');
assert(ssbmsTelemetryConnected()); // BLE ready, even before first snapshot.
assert(!ssbmsTelemetryAvailable());
applySsbmsTelemetry(frame+'\\0');
assert(ssbmsTelemetryAvailable());
assert.equal(ssbmsTelemetry.cells.length,12);
assert.equal(ssbmsTelemetry.cells[11],3.811);
assert.equal(ssbmsTelemetry.soc,75);
assert.equal(ssbmsTelemetry.current,-2.5);
assert.equal(ssbmsTelemetry.mosfet,28);
assert(ssbmsTelemetry.chargeAllowed);
assert(Math.abs(ssbmsTelemetry.spread-11)<0.0001);
assert.equal(ssbmsTelemetryAge(),0.5);
ssbmsTelemetryClock=12500; assert.equal(ssbmsTelemetryAge(),3);
const previous=ssbmsTelemetry;
applySsbmsTelemetry('ssbms-state 3 -1'); assert.strictEqual(ssbmsTelemetry,previous);
assert.equal(ssbmsTelemetryAge(),3); // Missing data cannot reset the sample's age.
applySsbmsTelemetry(frame.replace('48.00','NaN')); assert.strictEqual(ssbmsTelemetry,previous);
applySsbmsTelemetry(frame+' 3.9'); assert.strictEqual(ssbmsTelemetry,previous);
bmsBackend.currentIndex=2; assert(!ssbmsTelemetryAvailable());
ssbmsBleLinkConnected=false; assert(!ssbmsTelemetryConnected());
ssbmsUartSelected=true; ssbmsBleSelected=false; bmsConnected=1; assert(ssbmsTelemetryConnected());
statusTimeout=true; assert(!ssbmsTelemetryConnected());
statusTimeout=false; ssbmsUartSelected=false; assert(!ssbmsTelemetryConnected());
applySsbmsTelemetry('ssbms-state 0 -1'); assert.equal(ssbmsTelemetry,null);
assert.equal(ssbmsTelemetryAge(),-1);
"""
        result = subprocess.run([node, "-"], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
