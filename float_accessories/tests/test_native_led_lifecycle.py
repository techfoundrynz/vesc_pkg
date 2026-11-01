"""Exercise production native LED initialization, rollback and color setters."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT.parent / "lib_esp_led_strip/esp_led_strip/code.c"


def function(source, name):
    start = source.index("static ", source.index(name + "(") - 30)
    brace = source.index("{", start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class NativeLedLifecycleTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gcc"), "Requires a host C compiler")
    def test_allocation_rollback_redefinition_and_rgbw_setter(self):
        source = SOURCE.read_text()
        prefix = source[:source.index("static void render_thd(")]
        prefix = prefix.replace('#include "express/vesc_c_if.h"', r"""
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>
typedef uintptr_t lbm_value;
typedef size_t lbm_uint;
typedef void *lib_thread;
typedef void *lib_mutex;
static void *current_state;
#define ARG current_state
#define HEADER
static void *allocations[64];
static int live, attempts, fail_alloc, init_calls, fail_init, deinit_calls;
static bool fail_spawn;
static void *tracked_alloc(size_t n) {
    if (++attempts == fail_alloc) return NULL;
    void *p = calloc(1, n); assert(p); allocations[live++] = p; return p;
}
static void tracked_free(void *p) {
    int i; for (i=0;i<live;i++) if (allocations[i]==p) break;
    assert(i<live); allocations[i]=allocations[--live]; free(p);
}
static bool is_number(lbm_value v) { return v != UINTPTR_MAX; }
static uint32_t as_u32(lbm_value v) { return (uint32_t)v; }
static int32_t as_i32(lbm_value v) { return (int32_t)v; }
static void lock(lib_mutex m) { }
static void error_reason(const char *s) { }
static bool led_init(int pin, int timing) { return ++init_calls != fail_init; }
static void led_deinit(int pin) { deinit_calls++; }
static void led_update(int pin, uint8_t *p, unsigned int n) {
    for (unsigned int i=0;i<n;i++) assert(p[i]==0);
}
static void *spawn(void (*fn)(void *), unsigned int n, const char *name, void *arg) {
    return fail_spawn ? NULL : (void*)1;
}
static void terminate(lib_thread thread) { assert(thread==(void*)1); }
static void print(const char *fmt, ...) { }
static const struct {
    bool (*lbm_is_number)(lbm_value);
    uint32_t (*lbm_dec_as_u32)(lbm_value);
    int32_t (*lbm_dec_as_i32)(lbm_value);
    void (*mutex_lock)(lib_mutex), (*mutex_unlock)(lib_mutex);
    void *(*malloc)(size_t);
    void (*free)(void *);
    void (*lbm_set_error_reason)(const char *);
    bool (*rgbled_init)(int,int);
    void (*rgbled_deinit)(int);
    void (*rgbled_update)(int,uint8_t*,unsigned int);
    void *(*spawn)(void (*)(void*),unsigned int,const char*,void*);
    void (*request_terminate)(lib_thread);
    void (*printf)(const char*,...);
    lbm_value lbm_enc_sym_true, lbm_enc_sym_terror, lbm_enc_sym_eerror, lbm_enc_sym_merror;
} iface = {is_number,as_u32,as_i32,lock,lock,tracked_alloc,tracked_free,error_reason,
    led_init,led_deinit,led_update,spawn,terminate,print,1,2,3,4};
#define VESC_IF (&iface)
""")
        names = ("check_num_args", "seg_arg", "ext_seg_def", "free_render_buffers",
                 "ext_init", "esp_led_stop", "ext_col_rgbw")
        code = prefix + "\nstatic void render_thd(void *arg) {}\n"
        code += "\n".join(function(source, name) for name in names)
        code += r"""
static void setup(esp_led_t *st) {
    assert(live==0); memset(st,0,sizeof(*st)); current_state=st;
    attempts=fail_alloc=init_calls=fail_init=deinit_calls=0; fail_spawn=false;
    for(int i=0;i<3;i++) {st->seg[i].defined=true;st->seg[i].pin=i;st->seg[i].len=4;}
}
int main(void) {
    esp_led_t st; lbm_value n=3;
    for(int fail=1;fail<=7;fail++) {
        setup(&st);fail_alloc=fail;
        assert(ext_init(&n,1)==iface.lbm_enc_sym_merror);
        assert(!live && !st.work && !st.group_count && !st.seg_count && !st.buf_len);
    }
    for(int fail=1;fail<=3;fail++) {
        setup(&st);fail_init=fail;
        assert(ext_init(&n,1)==iface.lbm_enc_sym_eerror);
        assert(!live && deinit_calls==fail-1 && !st.group_count);
    }
    setup(&st);fail_spawn=true;
    assert(ext_init(&n,1)==iface.lbm_enc_sym_merror);
    assert(!live && deinit_calls==3 && !st.group_count);
    setup(&st);assert(ext_init(&n,1)==iface.lbm_enc_sym_true);
    assert(live==7 && st.running);
    st.seg[0].manual=tracked_alloc(16); st.seg[1].manual=tracked_alloc(16);
    esp_led_stop(&st);
    assert(!live && !st.running && !st.group_count && !st.seg_count && !st.buf_len);
    assert(!st.seg[0].manual && !st.seg[1].manual && deinit_calls==3);
    esp_led_stop(&st);assert(!live && deinit_calls==3);
    setup(&st);memset(&st.seg[0],0xA5,sizeof(seg_t));
    st.seg[0].manual=tracked_alloc(16);
    lbm_value def[]={0,7,TYPE_GRBW,25,6,2};
    assert(ext_seg_def(def,6)==iface.lbm_enc_sym_true && !live);
    seg_t *s=&st.seg[0];
    assert(s->defined && s->on && s->pin==7 && s->type==TYPE_GRBW && s->len==25);
    assert(s->offset==6 && s->timing==2 && s->fx==FX_SOLID && s->pal==1);
    assert(s->spd==esp_led_SPD_DEF && s->size==8 && s->fx_val==255);
    assert(!s->reverse && !s->auto_white && !s->bri && !s->bri_cur);
    assert(!s->color && !s->color_cur && !s->color_fade && !s->phase);
    assert(!s->phase_rem && !s->cycle_ms && !s->ov_count && !s->ov_color && !s->ov_bri);
    assert(!s->manual);for(int i=0;i<4;i++)assert(!s->cpal[i]);
    seg_t previous=*s;st.running=true;
    assert(ext_seg_def(def,6)==iface.lbm_enc_sym_eerror && !memcmp(s,&previous,sizeof(*s)));
    st.running=false;def[3]=0;
    assert(ext_seg_def(def,6)==iface.lbm_enc_sym_terror && !memcmp(s,&previous,sizeof(*s)));
    uint32_t seed=123;
    for(int count=3;count<=4;count++)for(int k=0;k<10000;k++) {
        lbm_value a[4];for(int i=0;i<4;i++){seed=seed*1664525+1013904223;a[i]=seed;}
        assert(ext_col_rgbw(a,count)==iface.lbm_enc_sym_true);
        uint32_t want=pack(a[0]&255,a[1]&255,a[2]&255,count==4?(a[3]&255):0);
        for(int i=0;i<esp_led_SEG_MAX;i++)assert(st.seg[i].color==want && st.seg[i].fx==FX_SOLID);
    }
    lbm_value bad[]={0,UINTPTR_MAX,2,3};
    assert(ext_col_rgbw(bad,4)==iface.lbm_enc_sym_terror);
    assert(ext_col_rgbw(bad,2)==iface.lbm_enc_sym_terror);
    return 0;
}
"""
        with tempfile.TemporaryDirectory() as tmp:
            path, binary = Path(tmp)/"lifecycle.c", Path(tmp)/"lifecycle"
            path.write_text(code)
            build = subprocess.run(["gcc", "-std=c99", "-fsanitize=address,undefined",
                                    str(path), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
