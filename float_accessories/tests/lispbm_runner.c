/* Register FA's real native protocol wrappers in the upstream test runner. */
#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#include "lispbm.h"
#include <string.h>
void bms_extensions_init(void);
static bool fa_add_extension(const char *name, extension_fptr fn) {
    bool result = lbm_add_extension(name, fn);
    if (strcmp(name, "check") == 0) bms_extensions_init();
    return result;
}
#define lbm_add_extension fa_add_extension
#include "../../../vesc_express/main/lispBM/tests/test_lisp_code_cps.c"
