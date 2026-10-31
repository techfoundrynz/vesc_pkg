ESP_TARGET ?= esp32c3

ARCH = esp32
TARGET = fa_cfg_$(ESP_TARGET)

SOURCES = code.c buffer.c ../native/ssbms/ssbms_protocol.c ../native/ow_bms/ow_protocol.c ../native/bms_extensions.c ../conf/confparser.c ../conf/confxml.c

CFLAGS += -I. -I../conf -I../native/ssbms -I../native/ow_bms
# S3 executable RAM is scarce: accidental double intermediates pull in a large
# software arithmetic implementation even though config values are floats.
CFLAGS += -Werror=double-promotion

VESC_C_LIB_PATH=../../c_libs/
include $(VESC_C_LIB_PATH)rules.mk
