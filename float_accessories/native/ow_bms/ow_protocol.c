#include "ow_protocol.h"
uint32_t ow_checksum(const uint8_t *data, size_t length) {
    uint32_t sum = 0;
    for (size_t i = 0; i < length; i++) sum += data[i];
    return sum;
}
size_t ow_find_magic(const uint8_t *data, size_t length, size_t start, const uint8_t magic[3]) {
    for (size_t i = start; i + 3 <= length; i++) {
        if (data[i] == magic[0] && data[i + 1] == magic[1] && data[i + 2] == magic[2]) return i;
    }
    return length;
}
