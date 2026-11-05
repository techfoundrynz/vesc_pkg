"""Pairing state messages refresh the MAC after the device commits the change."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PairingRefreshTests(unittest.TestCase):
    def test_pairing_completion_reads_committed_config(self):
        node = shutil.which('node') or shutil.which('node.exe')
        if not node:
            self.skipTest('Requires Node.js')
        qml = (ROOT / 'ui.qml.in').read_text(encoding='utf-8')
        start = qml.index('    function applyPubmotePairingState(')
        end = qml.index('\n    function ', start + 1)
        handler_start = qml.index('} else if (str.startsWith("pairing-status")) {')
        handler_start = qml.index('\n', handler_start) + 1
        handler = qml[handler_start:qml.index('} else if', handler_start)]
        program = '''
const assert = require('assert');
let pubmotePairingState = 0;
const faConfigIndex = 2;
let storedMac = -1, displayedMac = -1, reads = 0;
const mCommands = {customConfigGet(index, defaults) {
    assert.equal(index, faConfigIndex); assert.equal(defaults, false);
    reads++; displayedMac = storedMac;
}};
''' + qml[start:end] + '\nfunction receive(str) {\n' + handler + '\n}\n' + '''
receive('pairing-status 1\\0');
receive('pairing-status 2\\0');
assert.equal(pubmotePairingState, 2); assert.equal(reads, 0);
// Device writes the MAC before emitting its completion callback.
storedMac = 0x81234567 | 0;
receive('pairing-status 0\\0');
assert.equal(pubmotePairingState, 0);
assert.equal(displayedMac, storedMac); assert.equal(reads, 1);
// Unpairing can report idle while already idle; it still needs a refresh.
storedMac = -1;
receive('pairing-status 0\\0');
assert.equal(displayedMac, -1); assert.equal(reads, 2);
receive('pairing-status invalid\\0'); assert.equal(reads, 2);
'''
        result = subprocess.run([node, '-'], input=program.encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors='replace'))


if __name__ == '__main__':
    unittest.main()
