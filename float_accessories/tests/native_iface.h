/* Host adapter for the production native extension wrappers. */
#include "lispbm.h"
static const struct {
    bool (*lbm_is_byte_array)(lbm_value);
    bool (*lbm_is_number)(lbm_value);
    lbm_value (*lbm_car)(lbm_value);
    uint32_t (*lbm_dec_as_u32)(lbm_value);
    float (*lbm_dec_as_float)(lbm_value);
    lbm_value (*lbm_enc_u)(lbm_uint);
    lbm_value (*lbm_enc_i)(lbm_int);
    bool (*lbm_add_extension)(const char *, extension_fptr);
    lbm_value lbm_enc_sym_terror;
    lbm_value lbm_enc_sym_eerror;
} fa_host_interface = {
    lbm_is_array_rw, lbm_is_number, lbm_car, lbm_dec_as_u32, lbm_dec_as_float,
    lbm_enc_u, lbm_enc_i, lbm_add_extension, ENC_SYM_TERROR, ENC_SYM_EERROR
};
#define VESC_IF (&fa_host_interface)
