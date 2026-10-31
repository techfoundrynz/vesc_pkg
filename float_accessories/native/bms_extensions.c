/* Stateless framing helpers share the existing FA native image. UART and
 * backend ownership remain with Lisp; importing these never opens hardware. */
#ifdef FA_HOST_TEST
#include "native_iface.h"
#else
#include "express/vesc_c_if.h"
#endif
#include "ssbms_protocol.h"
#include "ow_protocol.h"
#include "buffer.h"

static lbm_array_header_t *byte_array(lbm_value value) {
    if (!VESC_IF->lbm_is_byte_array(value)) {
        return NULL;
    }
    return (lbm_array_header_t *)VESC_IF->lbm_car(value);
}

static lbm_value request(lbm_value *args, lbm_uint argn) {
    if (argn != 3 || !VESC_IF->lbm_is_number(args[1]) || !VESC_IF->lbm_is_number(args[2])) {
        return VESC_IF->lbm_enc_sym_terror;
    }
    lbm_array_header_t *array = byte_array(args[0]);
    if (!array) {
        return VESC_IF->lbm_enc_sym_terror;
    }
    size_t n = ssbms_read_request((uint8_t *)array->data, array->size,
        VESC_IF->lbm_dec_as_u32(args[1]), VESC_IF->lbm_dec_as_u32(args[2]));
    return n ? VESC_IF->lbm_enc_u(n) : VESC_IF->lbm_enc_sym_eerror;
}

static lbm_value scan(lbm_value *args, lbm_uint argn) {
    if (argn != 4 || !VESC_IF->lbm_is_number(args[1]) ||
            !VESC_IF->lbm_is_number(args[2]) || !VESC_IF->lbm_is_number(args[3])) {
        return VESC_IF->lbm_enc_sym_terror;
    }
    lbm_array_header_t *array = byte_array(args[0]);
    if (!array) {
        return VESC_IF->lbm_enc_sym_terror;
    }
    uint32_t n = VESC_IF->lbm_dec_as_u32(args[1]);
    if (n > array->size || n > SSBMS_RX_CAPACITY) {
        return VESC_IF->lbm_enc_sym_eerror;
    }
    return VESC_IF->lbm_enc_i(ssbms_find_reply((uint8_t *)array->data, n,
        VESC_IF->lbm_dec_as_u32(args[2]), VESC_IF->lbm_dec_as_u32(args[3])));
}

static lbm_value ow_sum(lbm_value *args, lbm_uint argn) {
    if (argn != 3 || !VESC_IF->lbm_is_number(args[1]) || !VESC_IF->lbm_is_number(args[2])) {
        return VESC_IF->lbm_enc_sym_terror;
    }
    lbm_array_header_t *array = byte_array(args[0]);
    if (!array) return VESC_IF->lbm_enc_sym_terror;
    uint32_t start = VESC_IF->lbm_dec_as_u32(args[1]);
    uint32_t end = VESC_IF->lbm_dec_as_u32(args[2]);
    if (start > end || end > array->size || end - start > 1024) return VESC_IF->lbm_enc_sym_eerror;
    return VESC_IF->lbm_enc_i(ow_checksum((uint8_t *)array->data + start, end - start));
}

static lbm_value ow_magic(lbm_value *args, lbm_uint argn) {
    if (argn != 4 || !VESC_IF->lbm_is_number(args[1]) || !VESC_IF->lbm_is_number(args[2])) {
        return VESC_IF->lbm_enc_sym_terror;
    }
    lbm_array_header_t *array = byte_array(args[0]);
    lbm_array_header_t *magic = byte_array(args[3]);
    if (!array || !magic || magic->size < 3) return VESC_IF->lbm_enc_sym_terror;
    uint32_t length = VESC_IF->lbm_dec_as_u32(args[1]);
    uint32_t start = VESC_IF->lbm_dec_as_u32(args[2]);
    if (length > array->size || length > 1024 || start > length) return VESC_IF->lbm_enc_sym_eerror;
    return VESC_IF->lbm_enc_u(ow_find_magic((uint8_t *)array->data, length, start, (uint8_t *)magic->data));
}

/* Use the same float32_auto encoder as the firmware CAN implementation. */
static lbm_value can_pair(lbm_value *args, lbm_uint argn) {
    if (argn != 3 || !VESC_IF->lbm_is_number(args[1]) || !VESC_IF->lbm_is_number(args[2])) return VESC_IF->lbm_enc_sym_terror;
    lbm_array_header_t *array = byte_array(args[0]);
    if (!array || array->size < 8) return VESC_IF->lbm_enc_sym_terror;
    int32_t index = 0;
    buffer_append_float32_auto((uint8_t *)array->data, VESC_IF->lbm_dec_as_float(args[1]), &index);
    buffer_append_float32_auto((uint8_t *)array->data, VESC_IF->lbm_dec_as_float(args[2]), &index);
    return VESC_IF->lbm_enc_u(8);
}

void bms_extensions_init(void) {
    VESC_IF->lbm_add_extension("ext-bms-can-pair", can_pair);
    VESC_IF->lbm_add_extension("ext-ow-checksum", ow_sum);
    VESC_IF->lbm_add_extension("ext-ow-find-magic", ow_magic);
    VESC_IF->lbm_add_extension("ext-ssbms-request", request);
    VESC_IF->lbm_add_extension("ext-ssbms-scan", scan);
}
