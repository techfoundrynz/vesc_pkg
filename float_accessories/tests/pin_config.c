/* Exercise the actual config boundary with a fake firmware/storage interface.
 * The wire codec is stubbed: these tests cover validation and commit behavior. */
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "express/vesc_c_if.h"
static vesc_c_if host_if;
static void *active_arg;
#undef VESC_IF
#define VESC_IF (&host_if)
#undef ARG
#define ARG active_arg
#include "code.c"

static unsigned stores;
static unsigned errors;
static unsigned char persisted[4096];
static const char *field_name;
static float supplied;
static char *decode_name(lbm_value value) { (void)value; return (char *)field_name; }
static bool is_number(lbm_value value) { (void)value; return true; }
static float decode_float(lbm_value value) { (void)value; return supplied; }
static int32_t decode_i32(lbm_value value) { (void)value; return (int32_t)supplied; }
static lbm_value encode_i32(int32_t value) { return (lbm_value)value; }
static int ignore_log(const char *format, ...) { (void)format; return 0; }
static int error_reason(char *reason) { assert(strstr(reason, "GPIO")); errors++; return 1; }
static bool store(eeprom_var *data, int base, int count) {
    assert(base == 0 && count * 4 <= (int)sizeof(persisted));
    memcpy(persisted, data, count * 4); stores++; return true;
}
static bool load(eeprom_var *data, int base, int count) {
    assert(base == 0 && count * 4 <= (int)sizeof(persisted));
    memcpy(data, persisted, count * 4); return true;
}
int32_t confparser_serialize_faconfig(uint8_t *dst, const FaConfig *cfg) {
    dst[0] = 1; memcpy(dst + 1, cfg, sizeof(*cfg)); return sizeof(*cfg) + 1;
}
bool confparser_deserialize_faconfig(const uint8_t *src, FaConfig *cfg) {
    if (src[0] != 1) return false;
    memcpy(cfg, src + 1, sizeof(*cfg)); return true;
}
void confparser_set_defaults_faconfig(FaConfig *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    for (unsigned i = 0; i < CFG_FIELD_COUNT; i++) if (cfg_types[i] == CFG_PIN) {
        int32_t unset = -1; memcpy((uint8_t *)cfg + cfg_offsets[i], &unset, 4);
    }
}
int main(void) {
    fa_data data = {0}; active_arg = &data;
    host_if.malloc = malloc; host_if.free = free; host_if.printf = ignore_log;
    host_if.lbm_dec_str = decode_name; host_if.lbm_is_number = is_number;
    host_if.lbm_dec_as_float = decode_float; host_if.lbm_dec_as_i32 = decode_i32;
    host_if.lbm_enc_i32 = encode_i32; host_if.lbm_set_error_reason = error_reason;
    host_if.lbm_enc_sym_true = 1; host_if.lbm_enc_sym_eerror = 0xdead;
    host_if.store_eeprom_var = store; host_if.read_eeprom_var = load;
    confparser_set_defaults_faconfig(&data.cfg);
    // Exhaustively compare the chip predicate with an independent range check.
    for (int pin = -100; pin <= 100; pin++) {
        bool expected = pin >= 0 && pin <= EXPECT_MAX;
#ifdef EXPECT_S3_GAP
        expected = expected && (pin < 22 || pin > 25);
#endif
        assert(fa_gpio_valid(pin) == expected);
    }
    // Every GPIO field is covered, including disabled features; -1 stays valid.
    unsigned pin_fields = 0;
    for (unsigned i = 0; i < CFG_FIELD_COUNT; i++) if (cfg_types[i] == CFG_PIN) {
        pin_fields++;
        field_name = cfg_names[i];
        int32_t *pin = (int32_t *)((uint8_t *)&data.cfg + cfg_offsets[i]);
        lbm_value args[] = {0, 0};
        float invalid[] = {-2.0f, 1.5f, (float)EXPECT_MAX + 1.0f, 9999.0f, INFINITY, NAN};
        for (unsigned n = 0; n < sizeof(invalid)/sizeof(invalid[0]); n++) {
            supplied = invalid[n]; *pin = 1;
            assert(ext_facfg_set(args, 2) == host_if.lbm_enc_sym_eerror);
            assert(*pin == 1);
        }
#ifdef EXPECT_S3_GAP
        for (int n = 22; n <= 25; n++) {
            supplied = (float)n;
            assert(ext_facfg_set(args, 2) == host_if.lbm_enc_sym_eerror);
            assert(*pin == 1);
        }
#endif
        supplied = (float)EXPECT_MAX;
        assert(ext_facfg_set(args, 2) == 1 && *pin == EXPECT_MAX);
        supplied = -1.0f;
        assert(ext_facfg_set(args, 2) == 1 && *pin == -1);
        // Legacy invalid stored values remain visible, but cannot reach hardware.
        *pin = EXPECT_MAX + 1;
        assert(ext_facfg_get(args, 1) == (lbm_value)-1);
        assert(*pin == EXPECT_MAX + 1);
        *pin = -1;
    }
    assert(pin_fields == 17 && errors > 0);
    uint8_t wire[sizeof(FaConfig) + 1];
    FaConfig candidate = data.cfg;
    data.cfg.can_id = 66;
    candidate.can_id = 99; candidate.led_front_pin = EXPECT_MAX + 1;
    confparser_serialize_faconfig(wire, &candidate);
    FaConfig before = data.cfg;
    assert(!set_cfg(wire));
    assert(memcmp(&before, &data.cfg, sizeof(before)) == 0 && stores == 0 && !data.changed);
    wire[0] = 0;
    assert(!set_cfg(wire));
    assert(memcmp(&before, &data.cfg, sizeof(before)) == 0 && stores == 0);
    candidate.led_front_pin = EXPECT_MAX;
    confparser_serialize_faconfig(wire, &candidate);
    assert(set_cfg(wire) && data.changed && stores == 1);
    assert(data.cfg.can_id == 99 && data.cfg.led_front_pin == EXPECT_MAX);
    // A legacy invalid config is neither discarded nor persisted automatically.
    candidate.led_front_pin = EXPECT_MAX + 1;
    confparser_serialize_faconfig(persisted, &candidate);
    read_cfg_from_eeprom(&data);
    assert(data.cfg.led_front_pin == EXPECT_MAX + 1 && stores == 1);
    assert(!write_cfg_to_eeprom(&data) && stores == 1);
    return 0;
}
