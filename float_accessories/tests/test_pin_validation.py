"""GPIO policy and real native config-boundary tests for all supported chips."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "conf"))
import gen_conf
from pin_caps import TARGETS, emit_header

class PinValidationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gcc"), "Requires a host C compiler")
    def test_all_targets_and_transactional_config_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            gen_conf.emit_datatypes(tmp / "datatypes.h")
            gen_conf.emit_lookup(tmp / "conf_lookup.h")
            emit_header(tmp / "pin_caps.h")
            (tmp / "code.c").write_text((ROOT / "fa_cfg/code.c").read_text())
            (tmp / "conf_general.h").write_text("")
            (tmp / "confparser.h").write_text('''#include "datatypes.h"
#define SERIALIZED_CONFIG_LENGTH (sizeof(FaConfig) + 1)
int32_t confparser_serialize_faconfig(uint8_t *, const FaConfig *);
bool confparser_deserialize_faconfig(const uint8_t *, FaConfig *);
void confparser_set_defaults_faconfig(FaConfig *);
''')
            (tmp / "confxml.h").write_text("#define data_faconfig_ ((uint8_t *)0)\n#define DATA_FACONFIG__SIZE 0\n")
            for target, maximum in [("esp32c3",21),("esp32c6",30),("esp32s3",48),("esp32p4",54),("esp32s31",61)]:
                with self.subTest(target=target):
                    binary = tmp / target
                    command = ["gcc", "-std=gnu99", "-O2", "-ffunction-sections", "-fdata-sections",
                        "-Wl,--gc-sections", "-DIS_VESC_LIB", "-DCONFIG_IDF_TARGET_"+target.upper(),
                        "-DEXPECT_MAX="+str(maximum), "-I"+str(tmp), "-I"+str(ROOT.parent / "c_libs"),
                        str(ROOT / "tests/pin_config.c"), "-o", str(binary)]
                    if target == "esp32s3": command.insert(1,"-DEXPECT_S3_GAP")
                    if target == "esp32s31": command.insert(1,"-DEXPECT_S31_GAPS")
                    result = subprocess.run(command,text=True,capture_output=True)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    subprocess.run([str(binary)],check=True,capture_output=True)

    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_unassigned_humidity_pins_do_not_start_i2c(self):
        program = (ROOT / "lib/humidity.lisp").read_text()
        program = program.replace("@const-start", "").replace("@const-end", "")
        program += '''
(def sda -1)
(def scl -1)
(defun get-config (name) (if (eq name 'humidity-sda-pin) sda scl))
(defun dbg-warn (message) nil)
(defun i2c-start (rate data clock) (exit-error "I2C must not start"))
(defun expect-no-start () (if (init-humidity) (exit-error "Expected no sensor startup")))
(expect-no-start)
(setq sda 8)
(expect-no-start)
(setq scl 8)
(expect-no-start)
(check t)
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "humidity.lisp"
            path.write_text(program)
            result = subprocess.run([os.environ["LBM_TEST_RUNNER"], "-h", "65536", str(path)],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 1, (result.stdout+result.stderr)[:5000])
            self.assertIn("SUCCESS", result.stdout)

    def test_all_gpio_fields_are_tagged_and_have_shared_ui_policy(self):
        pins = [p for p in gen_conf.PARAMS if p[0].endswith("_pin")]
        self.assertEqual(len(pins),17)
        self.assertTrue(all(p[2][1:3] == (-1,61) for p in pins))
        qml = (ROOT / "ui.qml.in").read_text(encoding="utf-8")
        for key, *_ in pins:
            self.assertIn('getParamInt("'+key+'")',qml)
            self.assertIn('updateParamInt("'+key+'"',qml)
        self.assertIn('if (pinConfigError !== "")',qml)

    def test_ui_validation_matches_native_policy(self):
        node = shutil.which("node") or shutil.which("node.exe")
        if not node:
            # Windows node is accessible from WSL without requiring a Linux install.
            windows_node = Path("/mnt/c/Program Files/nodejs/node.exe")
            if windows_node.exists(): node = str(windows_node)
        if not node: self.skipTest("Requires Node.js")
        qml = (ROOT / "ui.qml.in").read_text(encoding="utf-8")
        funcs = []
        for name in ("gpioPinValid", "gpioRangeDescription", "pinConfigurationError"):
            start = qml.index("function "+name+"(")
            brace = qml.index("{",start); depth = 1; end = brace + 1
            while depth:
                depth += (qml[end] == "{") - (qml[end] == "}"); end += 1
            funcs.append(qml[start:end])
        widgets = re.findall(r'\["[^"\n]+", (\w+)\.value\]', funcs[-1])
        program = "const gpioTargets="+json.dumps(TARGETS)+"; let gpioTarget='';\n"+"\n".join(funcs)
        program += "\n"+"\n".join("let "+w+"={value:-1};" for w in widgets)
        program += '''
const assert=require('assert');
assert(pinConfigurationError().includes('Waiting'));
for (const [target,max] of [['esp32c3',21],['esp32c6',30],['esp32s3',48],['esp32p4',54],['esp32s31',61]]) {
  gpioTarget=target;
  for(let pin=-5;pin<=100;pin++) {
    const expected=pin===-1 || (pin>=0&&pin<=max&&(target!=='esp32s3'||pin<22||pin>25)&&(target!=='esp32s31'||(pin!==29&&pin!==41)));
    assert.equal(!!gpioPinValid(pin),expected,target+':'+pin);
  }
  if(target==='esp32s31') assert.equal(gpioRangeDescription(),'0-28, 30-40, 42-61');
  assert.equal(pinConfigurationError(),'');
  assert(!gpioPinValid(1.5)); assert(!gpioPinValid(NaN));
}
'''
        for widget in widgets:
            program += f"gpioTarget='esp32s3'; {widget}.value=22; assert(pinConfigurationError().includes('invalid')); {widget}.value=-1;\n"
        for widget in widgets:
            for pin in (29, 41):
                program += f"gpioTarget='esp32s31'; {widget}.value={pin}; assert(pinConfigurationError().includes('invalid')); {widget}.value=-1;\n"
        # Script via stdin as UTF-8 bytes: argv is encoded with the locale's
        # codec, which fails on the UI's en dashes under a latin-1 locale.
        result=subprocess.run([node,"-"],input=program.encode("utf-8"),capture_output=True)
        output=(result.stdout+result.stderr).decode("utf-8",errors="replace")
        self.assertEqual(result.returncode,0,output)
