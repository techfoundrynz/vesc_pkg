# Build the sibling firmware's LispBM test runner without writing into it.
# make -f tests/lispbm.mk /tmp/fa_lbm_runner
LISPBM := ../../vesc_express/main/lispBM
LBM_TEST_RUNNER ?= /tmp/fa_lbm_runner
include $(LISPBM)/lispbm.mk

FA_NATIVE := native/bms_extensions.c native/ssbms/ssbms_protocol.c native/ow_bms/ow_protocol.c

$(LBM_TEST_RUNNER): tests/lispbm_runner.c tests/native_iface.h $(FA_NATIVE) $(wildcard native/*/*.h) $(LISPBM_SRC) $(LISPBM_H) $(LISPBM)/tests/test_lisp_code_cps.c
	gcc -O0 -std=gnu99 -DLBM64 -DFULL_RTS_LIB -DLBM_USE_DYN_FUNS -DLBM_USE_DYN_MACROS -DLBM_USE_DYN_LOOPS -DLBM_USE_DYN_ARRAYS $(LISPBM_SRC) $(LISPBM)/platform/linux/src/platform_mutex.c $(LISPBM)/platform/linux/src/platform_timestamp.c tests/lispbm_runner.c $(FA_NATIVE) -DFA_HOST_TEST -Itests -Inative/ssbms -Inative/ow_bms $(LISPBM_INC) -I$(LISPBM)/platform/linux/include -lpthread -lm -o $@
