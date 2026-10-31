"""Chip GPIO capabilities from ESP-IDF v5.5.4 soc/<target>/soc_caps.h.

These are SoC capabilities, not board wiring or flash/PSRAM reservations.
All four supported targets have the same input and output GPIO masks.
"""
TARGETS = {
    "esp32c3": {"max": 21, "gap": []},
    "esp32c6": {"max": 30, "gap": []},
    "esp32s3": {"max": 48, "gap": [22, 25]},
    "esp32p4": {"max": 54, "gap": []},
}

def emit_header(path):
    out = ["// Generated from conf/pin_caps.py; see Espressif ESP-IDF v5.5.4.",
           "#ifndef FA_PIN_CAPS_H", "#define FA_PIN_CAPS_H", "#include <stdbool.h>"]
    for i, (target, caps) in enumerate(TARGETS.items()):
        out += [("#if" if i == 0 else "#elif") + " defined(CONFIG_IDF_TARGET_" + target.upper() + ")",
                "#define FA_GPIO_MAX " + str(caps["max"])]
        gap = caps["gap"]
        predicate = "pin >= 0 && pin <= FA_GPIO_MAX"
        if gap: predicate += " && (pin < %d || pin > %d)" % tuple(gap)
        out += ["static inline bool fa_gpio_valid(int pin) { return " + predicate + "; }"]
    out += ["#else", '#error "Unsupported FA GPIO target"', "#endif", "#endif", ""]
    path.write_text("\n".join(out), encoding="utf-8")
