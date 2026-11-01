/* Register FA's real native protocol wrappers in the upstream test runner. */
#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#include "lispbm.h"
#include <string.h>
#include <sys/mman.h>
void bms_extensions_init(void);
static bool fa_add_extension(const char *name, extension_fptr fn) {
    bool result = lbm_add_extension(name, fn);
    if (strcmp(name, "check") == 0) { bms_extensions_init(); }
    return result;
}
#define lbm_add_extension fa_add_extension
/* Symbol names live in the image. The upstream runner emulates 128 KB of
 * image flash, and 64-bit symbol entries are twice the device's size, so the
 * whole package no longer fits. Map a larger image (sys/mman.h is included
 * above so its prototype is not rewritten) and size the runner's static to
 * match before main runs. */
#define FA_IMAGE_BYTES (512 * 1024)
#define mmap(addr, length, prot, flags, fd, offset) mmap(addr, FA_IMAGE_BYTES, prot, flags, fd, offset)
#include "../../../vesc_express/main/lispBM/tests/test_lisp_code_cps.c"
#undef mmap
__attribute__((constructor)) static void fa_image_size(void) {
    image_storage_size = FA_IMAGE_BYTES;
}
