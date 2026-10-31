ESP_TARGET ?= esp32c3

ARCH = esp32
TARGET = fa_cfg_$(ESP_TARGET)

SOURCES = code.c buffer.c ../conf/confparser.c ../conf/confxml.c

CFLAGS += -I. -I../conf
# S3 executable RAM is scarce: accidental double intermediates pull in a large
# software arithmetic implementation even though config values are floats.
CFLAGS += -Werror=double-promotion

VESC_C_LIB_PATH=../../c_libs/
include $(VESC_C_LIB_PATH)rules.mk
