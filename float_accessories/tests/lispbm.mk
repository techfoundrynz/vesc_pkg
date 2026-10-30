# Build the sibling firmware's LispBM test runner without writing into it.
# make -f tests/lispbm.mk /tmp/fa_white_lbm_runner
LISPBM := ../../vesc_express/main/lispBM
include $(LISPBM)/lispbm.mk

/tmp/fa_white_lbm_runner: $(LISPBM_SRC) $(LISPBM_H) $(LISPBM)/tests/test_lisp_code_cps.c
	gcc -O0 -std=gnu99 -DLBM64 -DFULL_RTS_LIB -DLBM_USE_DYN_FUNS -DLBM_USE_DYN_MACROS -DLBM_USE_DYN_LOOPS -DLBM_USE_DYN_ARRAYS $(LISPBM_SRC) $(LISPBM)/platform/linux/src/platform_mutex.c $(LISPBM)/platform/linux/src/platform_timestamp.c $(LISPBM)/tests/test_lisp_code_cps.c $(LISPBM_INC) -I$(LISPBM)/platform/linux/include -lpthread -lm -o $@
