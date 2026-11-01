"""Saved BMS selection is independent from the live connection."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BmsUiTests(unittest.TestCase):
    def test_saved_bms_is_not_assumed_to_be_connecting_or_connected(self):
        node = shutil.which("node") or shutil.which("node.exe")
        if not node:
            windows = Path("/mnt/c/Program Files/nodejs/node.exe")
            if windows.exists(): node = str(windows)
        if not node: self.skipTest("Requires Node.js")
        qml = (ROOT / "ui.qml.in").read_text()
        functions = []
        for name in ("ssbmsBlePeerSaved", "ssbmsBlePeerLinked", "ssbmsBleConnectText"):
            start = qml.index("function " + name + "(")
            brace = qml.index("{", start)
            depth, end = 1, brace + 1
            while depth:
                depth += (qml[end] == "{") - (qml[end] == "}")
                end += 1
            functions.append(qml[start:end])
        program = '''
const assert=require('assert');
let ssbmsBlePinned=true, ssbmsBleLinkConnected=false, ssbmsBleConnecting=false;
let ssbmsBleAddressA=-1430532899, ssbmsBleAddressB=-285277951;
let ssbmsBleLinkA=0, ssbmsBleLinkB=0;
''' + "\n".join(functions) + '''
assert.equal(ssbmsBleConnectText(0xaabbccdd,0xeeff0101),'Retry');
ssbmsBleConnecting=true;
assert.equal(ssbmsBleConnectText(0xaabbccdd,0xeeff0101),'Connecting...');
ssbmsBleLinkConnected=true; ssbmsBleLinkA=1; ssbmsBleLinkB=2;
assert.equal(ssbmsBlePeerLinked(ssbmsBleAddressA,ssbmsBleAddressB),false);
assert.equal(ssbmsBleConnectText(1,2),'Connected');
ssbmsBleConnecting=false;
assert.equal(ssbmsBleConnectText(0xaabbccdd,0xeeff0101),'Retry');
ssbmsBleLinkA=ssbmsBleAddressA; ssbmsBleLinkB=ssbmsBleAddressB;
assert.equal(ssbmsBleConnectText(0xaabbccdd,0xeeff0101),'Connected');
// Forget clears the selection; it cannot itself create a radio connection.
ssbmsBlePinned=false;
assert.equal(ssbmsBlePeerSaved(0xaabbccdd,0xeeff0101),false);
assert.equal(ssbmsBleConnectText(0xaabbccdd,0xeeff0101),'Connected');
ssbmsBleLinkConnected=false;
assert.equal(ssbmsBleConnectText(0xaabbccdd,0xeeff0101),'Connect');
'''
        result = subprocess.run([node, "-"], input=program, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
