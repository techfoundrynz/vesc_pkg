"""Compile the UI with Qt: syntax lint alone misses duplicate bindings."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "conf"))
from pin_caps import TARGETS

class QmlCompileTests(unittest.TestCase):
    def test_ui_compiles_and_duplicate_handlers_are_rejected(self):
        compiler = None
        for candidate in (Path("C:/Qt/5.15.2/mingw81_64/bin/qmlcachegen.exe"),
                          Path("/mnt/c/Qt/5.15.2/mingw81_64/bin/qmlcachegen.exe")):
            if candidate.exists():
                compiler = str(candidate)
                break
        if not compiler:
            compiler = shutil.which("qmlcachegen") or shutil.which("qmlcachegen.exe")
        if not compiler: self.skipTest("Requires Qt qmlcachegen")
        # Relative paths also work when invoking Windows Qt tools from WSL.
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            tmp = Path(tmp)
            source = tmp / "ui.qml"
            output = tmp / "ui.cpp"
            command = [compiler, "--resource-path", "/fa/ui.qml", "-o",
                       str(output.relative_to(ROOT)), str(source.relative_to(ROOT))]
            source.write_text('''import QtQuick 2.12
Item {
    property bool statusTimeout: false
    onStatusTimeoutChanged: {}
    onStatusTimeoutChanged: {}
}
''')
            bad = subprocess.run(command,cwd=ROOT,text=True,capture_output=True,timeout=30)
            self.assertNotEqual(bad.returncode,0)
            self.assertIn("Property value set multiple times",bad.stdout+bad.stderr)
            qml = (ROOT / "ui.qml.in").read_text(encoding="utf-8")
            qml = qml.replace("{{VERSION}}","test").replace("{{ABOUT_MD}}","")
            qml = qml.replace("{{GPIO_TARGETS}}",json.dumps(TARGETS))
            source.write_text(qml,encoding="utf-8")
            good = subprocess.run(command,cwd=ROOT,text=True,capture_output=True,timeout=30)
            self.assertEqual(good.returncode,0,good.stdout+good.stderr)
            self.assertTrue(output.exists())
