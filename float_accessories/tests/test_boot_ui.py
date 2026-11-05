"""Late UI attachment and lost config replies must recover from boot snapshots."""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def function(source, name):
    start = source.index('    function ' + name + '(')
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class BootUiTests(unittest.TestCase):
    def test_late_ready_reload_and_retry_without_reloading_edits(self):
        node = shutil.which('node') or shutil.which('node.exe')
        if not node:
            self.skipTest('Requires Node.js')
        qml = (ROOT / 'ui.qml.in').read_text()
        constants = dict((name, int(value)) for name, value in re.findall(
            r'readonly property int (boot\w+): (\d+)', qml))
        import json
        program = 'const container=' + json.dumps(constants) + ';\n'
        program += '''
const assert = require('assert');
let bootState=0, bootLoadingText="", readConfig=false, configReloadRequested=false;
let packageReady=false;
const qsTr=(s)=>s;
const lastStatusTime=0;
let bootConfigRequested=false, bootConfigRetryTicks=0, mCustomConf=null;
let requests=0, reloads=0, queries=0, schema=null;
const faConfigIndex=1;
const mCommands={lispGetStats() {throw new Error('Boot polling must not pause Lisp for statistics');},customConfigGet(i,d) {assert.equal(i,1);assert.equal(d,false);requests++;},
    lispSendReplCmd(s) {throw new Error('Boot polling must not submit REPL code: '+s);}};
const VescIf={isPortConnected() {return true;},customConfig() {return schema;}};
const startupConfigReloadTimer={start() {reloads++;}};
'''
        for name in ('resolveCustomConf', 'reloadMissingConfigAfterBoot', 'applyBootState', 'pollBootProgress', 'applyBootLog', 'bootStatusText', 'bootProgressStep'):
            program += function(qml, name) + '\n'
        program += '''
// Each boot phase has readable text and a matching stage in the progress bar.
for (const [state,step] of [[container.bootWaiting,0], [container.bootLoadingCode,1],
    [container.bootLoadingLibraries,2], [container.bootCreatingImage,3],
    [container.bootStarting,4], [container.bootReady,5], [container.bootFailed,0]]) {
    bootState=state;
    bootLoadingText='Loading package';
    const lastStatusTime=0;
    assert.equal(bootProgressStep(),step);
    assert(bootStatusText().length>0);
}
bootState=container.bootWaiting;
// Firmware begins preparing storage and parsing before FA can report its state.
applyBootLog('Preparing new image...\\0');
assert(bootStatusText().includes('preparing image storage'));
applyBootLog('Parsing 7780 characters\\0');
assert(bootStatusText().includes('parsing package'));
applyBootLog('unrelated Lisp output');
assert(bootStatusText().includes('parsing package'));
// Loading code and creating the image can be queried before the app is ready.
for(let i=0;i<10;i++) pollBootProgress(); assert.equal(queries,0);
// A late-opened page sees the next module log even if it missed Parsing.
applyBootLog('"FA loaded bms"');
assert.equal(bootStatusText(),'Loading bms...');
assert.equal(bootState,container.bootLoadingCode); pollBootProgress();
applyBootState(container.bootCreatingImage); pollBootProgress();
assert.equal(queries,0); assert.equal(requests,0); assert.equal(reloads,0);
// Ready was emitted while this page was closed; a later snapshot must recover.
// Ready is repeated by the regular app status query, not just emitted once.
applyBootState(container.bootReady);
applyBootState(container.bootReady);
assert.equal(reloads,1); assert.equal(requests,0);
// An allocated but empty ConfigParams object still requires enumeration.
mCustomConf={hasParam() {return false;}};
applyBootState(container.bootReady); assert.equal(requests,0);
// Firmware enumeration finishes, then fetch values from the real FA schema.
schema={hasParam(name) {return name==='led_enabled';}};
mCustomConf=schema; bootConfigRequested=false;
reloadMissingConfigAfterBoot(); assert.equal(requests,1);
// First values reply is lost. A subsequent poll retries instead of getting stuck.
pollBootProgress(); pollBootProgress(); pollBootProgress();
assert.equal(requests,2); assert.equal(reloads,1);
// Once config arrives, repeated Ready snapshots cannot overwrite unsaved edits.
readConfig=true; packageReady=true;
for(let i=0;i<6;i++) {applyBootState(container.bootReady);pollBootProgress();}
assert.equal(requests,2); assert.equal(reloads,1); assert.equal(queries,0);
applyBootState(NaN); applyBootState(99); assert.equal(bootState,container.bootReady);
// A newly opened page may already have cached config; still refresh once on Ready.
bootState=container.bootWaiting; applyBootState(container.bootReady);
assert.equal(requests,3);
applyBootState(container.bootReady); assert.equal(requests,3);
applyBootState(container.bootFailed); assert.equal(bootState,container.bootFailed);
'''
        result = subprocess.run([node, '-'], input=program.encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors='replace'))
