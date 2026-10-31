"""Check config float encoding against the original double-intermediate formulas."""
import ctypes
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

REFERENCE = r"""
#include <math.h>
#include <stdbool.h>
#include "buffer.h"
void reference_append(uint8_t *buffer, float number, int32_t *index) {
    if (fabsf(number) < 1.5e-38) number = 0.0;
    int e = 0;
    float sig = frexpf(number, &e);
    float sig_abs = fabsf(sig);
    uint32_t sig_i = 0;
    if (sig_abs >= 0.5) {
        sig_i = (uint32_t)((sig_abs - 0.5f) * 2.0f * 8388608.0f);
        e += 126;
    }
    uint32_t res = ((e & 0xFF) << 23) | (sig_i & 0x7FFFFF);
    if (sig < 0) res |= 1U << 31;
    buffer_append_uint32(buffer, res, index);
}
float reference_get(const uint8_t *buffer, int32_t *index) {
    uint32_t res = buffer_get_uint32(buffer, index);
    int e = (res >> 23) & 0xFF;
    uint32_t sig_i = res & 0x7FFFFF;
    bool neg = res & (1U << 31);
    float sig = 0.0;
    if (e != 0 || sig_i != 0) {
        sig = (float)sig_i / (8388608.0 * 2.0) + 0.5;
        e -= 126;
    }
    if (neg) sig = -sig;
    return ldexpf(sig, e);
}
"""


class ConfigFloatTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gcc"), "Requires a host C compiler")
    def test_wire_compatibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            reference = tmp / "reference.c"
            reference.write_text(REFERENCE)
            library = tmp / "buffer.so"
            compiled = subprocess.run(["gcc", "-shared", "-fPIC", "-O2", "-I", str(ROOT / "fa_cfg"),
                            str(ROOT / "fa_cfg/buffer.c"), str(reference), "-lm", "-o", str(library)],
                                      text=True, capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            lib = ctypes.CDLL(str(library))
            byte_ptr = ctypes.POINTER(ctypes.c_uint8)
            index_ptr = ctypes.POINTER(ctypes.c_int32)
            for name in ["buffer_append_float32_auto", "reference_append"]:
                getattr(lib, name).argtypes = [byte_ptr, ctypes.c_float, index_ptr]
            for name in ["buffer_get_float32_auto", "reference_get"]:
                getattr(lib, name).argtypes = [byte_ptr, index_ptr]
                getattr(lib, name).restype = ctypes.c_float

            # Both signs, every exponent, exact powers and mantissa boundaries,
            # plus floats immediately around the encoder's tiny-value cutoff.
            bits = {sign | exponent << 23 | mantissa
                    for sign in (0, 0x80000000) for exponent in range(256)
                    for mantissa in (0, 1, 2, 0x3FFFFF, 0x400000, 0x7FFFFE, 0x7FFFFF)}
            bits.update(sign | (0xA355E6 + offset)
                        for sign in (0, 0x80000000) for offset in range(-8, 9))
            rng = random.Random(0)
            bits.update(rng.getrandbits(32) for _ in range(20000))
            for word in sorted(bits):
                data = struct.pack(">I", word)
                buf = (ctypes.c_uint8 * 4).from_buffer_copy(data)
                indices = [ctypes.c_int32(0), ctypes.c_int32(0)]
                decoded = lib.buffer_get_float32_auto(buf, ctypes.byref(indices[0]))
                expected = lib.reference_get(buf, ctypes.byref(indices[1]))
                self.assertEqual(struct.pack("<f", decoded), struct.pack("<f", expected), hex(word))
                self.assertEqual([x.value for x in indices], [4, 4])
                # Non-finite input encoding was never supported by the original.
                if (word >> 23) & 0xFF == 255:
                    continue
                value = struct.unpack(">f", data)[0]
                output = [(ctypes.c_uint8 * 4)(), (ctypes.c_uint8 * 4)()]
                indices = [ctypes.c_int32(0), ctypes.c_int32(0)]
                lib.buffer_append_float32_auto(output[0], value, ctypes.byref(indices[0]))
                lib.reference_append(output[1], value, ctypes.byref(indices[1]))
                self.assertEqual(bytes(output[0]), bytes(output[1]), hex(word))
                self.assertEqual([x.value for x in indices], [4, 4])
