#ifndef FA_OW_PROTOCOL_H
#define FA_OW_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
uint32_t ow_checksum(const uint8_t *data, size_t length);
/* Return length when no complete three-byte marker remains. */
size_t ow_find_magic(const uint8_t *data, size_t length, size_t start, const uint8_t magic[3]);
#endif
