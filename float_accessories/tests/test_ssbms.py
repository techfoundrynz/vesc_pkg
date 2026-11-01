"""Real SSBMS native framing plus adapter polling/publication with fake UART."""
import ctypes
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]

class NativeBmsTests(unittest.TestCase):
    def test_s3_native_image_size(self):
        binary = ROOT / "fa_cfg/fa_cfg_esp32s3.bin"
        if not binary.exists():
            self.skipTest("Build the S3 FA native image first")
        header = struct.unpack_from("<6I", binary.read_bytes())
        self.assertEqual(header[1], 2)
        self.assertLessEqual(header[2], 7680, "FA native code exceeds the reported S3 executable block")

    @unittest.skipUnless(shutil.which("gcc"), "Requires a host compiler")
    def test_crc_vectors_stream_validation_and_ow_equivalence(self):
        with tempfile.TemporaryDirectory() as tmp:
            library = Path(tmp) / "protocol.so"
            subprocess.run(["gcc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-O2",
                str(ROOT / "native/ssbms/ssbms_protocol.c"), str(ROOT / "native/ow_bms/ow_protocol.c"),
                "-o", str(library)], check=True, capture_output=True)
            lib = ctypes.CDLL(str(library))
            ptr = ctypes.POINTER(ctypes.c_uint8)
            lib.ssbms_crc.argtypes = [ptr, ctypes.c_size_t]
            lib.ssbms_crc.restype = ctypes.c_uint16
            lib.ssbms_read_request.argtypes = [ptr, ctypes.c_size_t, ctypes.c_uint, ctypes.c_uint]
            lib.ssbms_read_request.restype = ctypes.c_size_t
            lib.ssbms_find_reply.argtypes = [ptr, ctypes.c_size_t, ctypes.c_uint, ctypes.c_uint]
            lib.ssbms_find_reply.restype = ctypes.c_int
            lib.ow_checksum.argtypes = [ptr, ctypes.c_size_t]
            lib.ow_checksum.restype = ctypes.c_uint32
            lib.ow_find_magic.argtypes = [ptr, ctypes.c_size_t, ctypes.c_size_t, ptr]
            lib.ow_find_magic.restype = ctypes.c_size_t
            def array(data): return (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
            def seal(data):
                return data + lib.ssbms_crc(array(data), len(data)).to_bytes(2, "little")
            for body, crc in [("16100001000000", "6EFA"),
                ("160302100E109A103603E805DC1068000000C8", "7E27"),
                ("16030020280FF10F060FED0FF00FF00FF00FF00FF00FF10FF10FF40FF40FF40FF40FF40FF30FF40FF40FF40FF4", "321A")]:
                self.assertEqual(seal(bytes.fromhex(body))[-2:], bytes.fromhex(crc))
            out = (ctypes.c_uint8 * 8)()
            for reg, count, frame in [(0x20,20,"160300200014C4AD"), (0x200,1,"160302000001FE84"),
                (0,16,"160300000010866B"), (0x210,7,"1603021000075BA7")]:
                self.assertEqual(lib.ssbms_read_request(out, 8, reg, count), 8)
                self.assertEqual(bytes(out), bytes.fromhex(frame))
            self.assertEqual(lib.ssbms_read_request(out, 7, 0, 1), 0)
            self.assertEqual(lib.ssbms_read_request(out, 8, 0, 33), 0)
            for count in (12,20,32):
                frame = seal(bytes.fromhex("16030020") + bytes([count*2]) + bytes.fromhex("0FF1")*count)
                find = lambda data, reg=0x20,n=count: lib.ssbms_find_reply(array(data), len(data), reg, n)
                self.assertEqual(find(frame),0)
                for n in range(len(frame)): self.assertEqual(find(frame[:n]),-1)
                self.assertEqual(find(b"junk"+frame+b"trailer"),4)
                self.assertEqual(find(frame,0x200),-1)
                self.assertEqual(find(frame,n=count-1),-1)
                for i in range(len(frame)):
                    broken=bytearray(frame);broken[i]^=1
                    self.assertEqual(find(broken),-1)
                    self.assertEqual(find(bytes(broken)+frame),len(frame))
            rng=random.Random(4)
            for _ in range(200):
                data=bytes(rng.randrange(256) for _ in range(rng.randrange(3,1025)))
                self.assertEqual(lib.ow_checksum(array(data),len(data)),sum(data))
                magic=b"\xff\x55\xaa"
                for start in (0,len(data)//2,len(data)):
                    found=data.find(magic,start)
                    self.assertEqual(lib.ow_find_magic(array(data),len(data),start,array(magic)),len(data) if found<0 else found)

CORE_FILES=["lib/utils.lisp", "lib/bms-vars.lisp", "lib/bms.lisp", "lib/bms-backend.lisp", "lib/adapters/ssbms.lisp"]

class SsbmsTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_uart_polling_mapping_staleness_and_stop(self):
        self.run_lisp(CORE_FILES+["lib/adapters/ssbms-uart.lisp"], "tests/ssbms.lisp")

    # ble-client-* and conf-get are not host builtins; the test defines fakes.
    @unittest.skipUnless(os.environ.get("LBM_TEST_RUNNER"), "Set LBM_TEST_RUNNER")
    def test_ble_link_reassembly_loss_and_cleanup(self):
        self.run_lisp(CORE_FILES+["lib/ble-client.lisp", "lib/adapters/ssbms-ble.lisp"], "tests/ssbms_ble.lisp")

    def run_lisp(self, files, test):
        curves=(ROOT / "lib/vehicle.lisp").read_text()
        curves=curves[curves.index("(defun get-voltage-curve"):curves.index("; Provider callbacks:")]
        program="\n".join((ROOT / p).read_text() for p in files)+"\n"+curves+"\n"+(ROOT/test).read_text()
        program=program.replace("@const-start", "").replace("@const-end", "")
        for old,new in [("systime","test-clock"),("secs-since","test-age"),("sleep","test-sleep"),
            ("uart-start","test-start"),("uart-stop","test-stop"),("uart-read","test-read"),
            ("uart-write","test-write"),("ext-facfg-store","test-store"),("can-local-id","test-id"),("can-send-eid","test-can")]:
            program=program.replace("("+old+" ","("+new+" ").replace("("+old+")","("+new+")")
        program=program.replace("(set-bms-val field value)","(test-value field value)")
        program=program.replace("(set-bms-val field index value)","(test-indexed field index value)")
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"ssbms.lisp";path.write_text(program)
            result=subprocess.run([os.environ["LBM_TEST_RUNNER"],"-h","131072",str(path)],text=True,capture_output=True,timeout=30)
            self.assertEqual(result.returncode,1,(result.stdout+result.stderr)[:8000])
            self.assertIn("SUCCESS",result.stdout,result.stdout+result.stderr)
