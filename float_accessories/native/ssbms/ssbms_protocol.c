#include "ssbms_protocol.h"

uint16_t ssbms_crc(const uint8_t *data, size_t length) {
    uint16_t crc = 0;
    for (size_t i = 0; i < length; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (unsigned bit = 0; bit < 8; bit++) {
            crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
        }
    }
    return crc;
}

size_t ssbms_read_request(uint8_t *dst, size_t capacity, unsigned reg, unsigned count) {
    if (!dst || capacity < 8 || reg > 0xffff || count < 1 || count > SSBMS_MAX_CELLS) {
        return 0;
    }
    dst[0] = 0x16;
    dst[1] = 0x03;
    dst[2] = reg >> 8;
    dst[3] = reg;
    dst[4] = count >> 8;
    dst[5] = count;
    uint16_t crc = ssbms_crc(dst, 6);
    dst[6] = crc;
    dst[7] = crc >> 8;
    return 8;
}

int ssbms_find_reply(const uint8_t *data, size_t length, unsigned reg, unsigned count) {
    if (!data || length > SSBMS_RX_CAPACITY || reg > 0xffff || count < 1 || count > SSBMS_MAX_CELLS) {
        return -1;
    }
    size_t size = 2 * count + 7;
    for (size_t start = 0; start + size <= length; start++) {
        const uint8_t *frame = data + start;
        if (frame[0] != 0x16 || frame[1] != 0x03 || frame[2] != reg >> 8 ||
                frame[3] != (reg & 0xff) || frame[4] != 2 * count) {
            continue;
        }
        uint16_t crc = frame[size - 2] | (uint16_t)frame[size - 1] << 8;
        if (crc == ssbms_crc(frame, size - 2)) {
            return (int)start;
        }
    }
    return -1;
}
