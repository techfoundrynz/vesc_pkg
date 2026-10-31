#ifndef FA_SSBMS_PROTOCOL_H
#define FA_SSBMS_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define SSBMS_MAX_CELLS 32
#define SSBMS_MAX_FRAME (2 * SSBMS_MAX_CELLS + 7)
#define SSBMS_RX_CAPACITY 256

uint16_t ssbms_crc(const uint8_t *data, size_t length);
/* Read-only request builder. Returns 8 on success, 0 for invalid arguments. */
size_t ssbms_read_request(uint8_t *dst, size_t capacity, unsigned reg, unsigned count);
/* Find a complete, CRC-valid reply to exactly this read, skipping stream noise.
 * Incomplete input returns -1; caller retains it until completion or timeout. */
int ssbms_find_reply(const uint8_t *data, size_t length, unsigned reg, unsigned count);

#endif
