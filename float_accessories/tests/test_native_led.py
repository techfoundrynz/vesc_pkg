"""Check the shared native renderer's compact implementation against its old math."""
import ctypes
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT.parent / "lib_esp_led_strip/esp_led_strip"

REFERENCE = r"""
uint32_t reference_scale(uint32_t c, uint32_t num) {
    uint32_t w = (((c >> 24) & 255) * num) / 255;
    uint32_t r = (((c >> 16) & 255) * num) / 255;
    uint32_t g = (((c >> 8) & 255) * num) / 255;
    uint32_t b = ((c & 255) * num) / 255;
    return pack(r, g, b, w);
}
uint32_t reference_interp4(const uint32_t *c, uint8_t pos) {
    uint32_t a = c[pos / 64], b = c[(pos / 64 + 1) % 4], f = pos % 64;
    uint32_t r = (((a >> 16) & 255) * (63 - f) + ((b >> 16) & 255) * f) / 63;
    uint32_t g = (((a >> 8) & 255) * (63 - f) + ((b >> 8) & 255) * f) / 63;
    uint32_t bl = ((a & 255) * (63 - f) + (b & 255) * f) / 63;
    return pack(r, g, bl, 0);
}
static void reference_render(esp_led_t *st, const seg_t *s, uint8_t master) {
    group_t *grp = &st->group[s->group];
    int n = s->len, colors = grp->colors;
    uint32_t *work = st->work;
    uint8_t *tx = grp->txbuf[grp->cur] + (uint32_t)s->offset * colors;
    fx_render(s, work);
    uint32_t bri = ((uint32_t)s->bri_cur * master) / 255;
    for (int i = 0; i < n; i++) {
        uint32_t c = reference_scale(work[i], bri);
        uint32_t w = (c >> 24) & 255, r = (c >> 16) & 255;
        uint32_t g = (c >> 8) & 255, b = c & 255;
        if (s->auto_white && colors == 4 && w == 0) {
            w = r < g ? (r < b ? r : b) : (g < b ? g : b);
            r -= w; g -= w; b -= w;
        }
        work[i] = pack(r, g, b, w);
    }
    int total = n + s->ov_count, src = 0;
    for (int i = 0; i < total; i++) {
        bool ov = false;
        for (int k = 0; k < s->ov_count; k++) if (s->ov_idx[k] == i) {ov = true; break;}
        uint32_t c;
        if (ov) c = reference_scale(s->ov_color, s->ov_bri);
        else if (src < n) {c = work[s->reverse ? n - 1 - src : src]; src++;}
        else c = 0;
        uint8_t w = c >> 24, r = c >> 16, g = c >> 8, b = c;
        uint8_t *px = tx + i * colors;
        switch (s->type) {
        case TYPE_RGB: px[0]=r; px[1]=g; px[2]=b; break;
        case TYPE_GRBW: px[0]=g; px[1]=r; px[2]=b; px[3]=w; break;
        case TYPE_RGBW: px[0]=r; px[1]=g; px[2]=b; px[3]=w; break;
        case TYPE_WRGB: px[0]=w; px[1]=r; px[2]=g; px[3]=b; break;
        default: px[0]=g; px[1]=r; px[2]=b; break;
        }
    }
}
uint32_t actual_scale(uint32_t c, uint32_t n) {return scale(c, n);}
uint32_t actual_interp4(const uint32_t *c, uint8_t p) {return interp4(c, p);}
void test_frame(const uint32_t *v, uint8_t *output, int reference) {
    uint32_t work[32] = {0}, manual[32];
    esp_led_t st = {0};
    seg_t s = {0};
    for (int i=0; i<32; i++) manual[i] = v[16] ^ (2654435761u * (i+1));
    s.fx=v[0]; s.type=v[1]; s.len=v[2]; s.reverse=v[3]; s.auto_white=v[4];
    s.bri_cur=v[5]; s.phase=v[7]; s.spd=v[8]; s.size=v[9]; s.fx_val=v[10];
    s.pal=v[11]; s.ov_bri=v[12]; s.ov_count=v[13]; s.offset=v[14];
    s.color_cur=v[15]; s.ov_color=v[16]; s.manual=manual;
    for (int k=0; k<4; k++) s.cpal[k]=v[17+k];
    for (int k=0; k<s.ov_count; k++) s.ov_idx[k]=k*2;
    st.work=work; st.group[0].colors=s.type>=TYPE_GRBW ? 4 : 3;
    st.group[0].txbuf[0]=output;
    memset(output, 0xA5, 256);
    if (reference) reference_render(&st, &s, v[6]);
    else render_seg(&st, &s, v[6]);
}
"""


class NativeLedTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gcc"), "Requires a host C compiler")
    def test_color_math_and_wire_bytes(self):
        source = (LIBRARY / "code.c").read_text()
        # Compile production effects/rendering without hardware entry points.
        source = source[:source.index("static void render_thd(")]
        source = source.replace('#include "express/vesc_c_if.h"',
                                "#include <stdint.h>\n#include <stdbool.h>\n"
                                "#include <stddef.h>\ntypedef void *lib_thread;\n"
                                "typedef void *lib_mutex;\n#define HEADER\n#define ARG NULL")
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            code, library = tmp / "renderer.c", tmp / "renderer.so"
            code.write_text(source + REFERENCE)
            built = subprocess.run(["gcc", "-shared", "-fPIC", "-O2", str(code), "-o", str(library)],
                                   text=True, capture_output=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            lib = ctypes.CDLL(str(library))
            u32 = ctypes.c_uint32
            for name in ["actual_scale", "reference_scale"]:
                getattr(lib, name).argtypes = [u32, u32]
                getattr(lib, name).restype = u32
            for name in ["actual_interp4", "reference_interp4"]:
                getattr(lib, name).argtypes = [ctypes.POINTER(u32), ctypes.c_uint8]
                getattr(lib, name).restype = u32
            lib.test_frame.argtypes = [ctypes.POINTER(u32), ctypes.POINTER(ctypes.c_uint8), ctypes.c_int]
            for value in range(256):
                color = value | ((value ^ 85) << 8) | ((255-value) << 16) | (value << 24)
                for brightness in range(256):
                    self.assertEqual(lib.actual_scale(color, brightness),
                                     lib.reference_scale(color, brightness))
            rng = random.Random(0)
            for _ in range(16):
                palette = (u32 * 4)(*(rng.getrandbits(32) for _ in range(4)))
                for position in range(256):
                    self.assertEqual(lib.actual_interp4(palette, position),
                                     lib.reference_interp4(palette, position))
            for effect in range(18):
                for pixel_type in range(5):
                    for reverse in range(2):
                        for auto_white in range(2):
                            for brightness in (0, 25, 255):
                                v = [effect, pixel_type, rng.randrange(1, 25), reverse, auto_white,
                                     brightness, rng.choice((0, 25, 255)), rng.getrandbits(32),
                                     rng.randrange(256), rng.randrange(1, 12), rng.randrange(256),
                                     rng.randrange(12), rng.randrange(256), rng.randrange(4),
                                     rng.randrange(3), rng.choice((0, 0xFFFFFF, 0xFFFFFFFF, rng.getrandbits(32))),
                                     rng.getrandbits(32), *(rng.getrandbits(32) for _ in range(4))]
                                args = (u32 * len(v))(*v)
                                actual, expected = (ctypes.c_uint8 * 256)(), (ctypes.c_uint8 * 256)()
                                lib.test_frame(args, actual, 0)
                                lib.test_frame(args, expected, 1)
                                self.assertEqual(bytes(actual), bytes(expected), v)

    @unittest.skipUnless((LIBRARY / "esp_led_strip_esp32s3.bin").is_file(), "Build S3 LED library first")
    def test_s3_executable_size(self):
        header = struct.unpack_from("<6I", (LIBRARY / "esp_led_strip_esp32s3.bin").read_bytes())
        self.assertEqual(header[1], 2)
        # This firmware/device reports 7680 as its largest executable block.
        self.assertLessEqual(header[2], 7680, "S3 LED code exceeds the reported executable block")
