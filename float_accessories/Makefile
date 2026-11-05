VESC_TOOL ?= vesc_tool
PYTHON ?= python3
LBM_TEST_RUNNER ?= /tmp/fa_lbm_runner

# One binary per chip - native libs only run on the chip they were built for.
ESP_TARGETS = esp32c3 esp32c6 esp32s3 esp32s31
PACKAGE_TARGET ?= all
ifeq ($(PACKAGE_TARGET),all)
PACKAGE_OUTPUTS = float_accessories.vescpkg $(addprefix float_accessories_,$(addsuffix .vescpkg,$(ESP_TARGETS)))
else
ifeq ($(filter $(PACKAGE_TARGET),esp32c3 esp32c6 esp32s3 esp32s31),)
$(error PACKAGE_TARGET must be all, esp32c3, esp32c6, esp32s3 or esp32s31)
endif
PACKAGE_OUTPUTS = float_accessories_$(PACKAGE_TARGET).vescpkg
endif

# Single source of truth for the package version. It is stamped into the
# generated README (build info) and into the About box in the UI.
VERSION=`cat version`

all: $(PACKAGE_OUTPUTS)

# Host-only regression suite; no firmware toolchain or connected device needed.
test:
	$(MAKE) -f tests/lispbm.mk LBM_TEST_RUNNER="$(LBM_TEST_RUNNER)" "$(LBM_TEST_RUNNER)"
	LBM_TEST_RUNNER="$(LBM_TEST_RUNNER)" $(PYTHON) -m unittest discover -s tests -v

# Regenerate the config sources from conf/gen_conf.py when it changed.
conf/settings.xml fa_cfg/datatypes.h fa_cfg/conf_lookup.h fa_cfg/pin_caps.h &: conf/gen_conf.py conf/pin_caps.py
	$(PYTHON) conf/gen_conf.py

conf/confparser.c conf/confparser.h conf/confxml.c conf/confxml.h conf/conf_default.h &: conf/settings.xml
	cd conf && $(VESC_TOOL) --xmlConfToCode settings.xml

# The esp_led_strip lib binaries are imported from ../lib_esp_led_strip -
# build them there first.
esp_led_libs:
	$(MAKE) -C ../lib_esp_led_strip libs ESP_TARGETS="$(ESP_TARGETS)"

fa_cfg_libs: conf/confparser.c fa_cfg/datatypes.h
	for t in $(ESP_TARGETS); do \
		rm -f fa_cfg/*.o fa_cfg/*.d conf/*.o conf/*.d native/*.o native/*.d native/ssbms/*.o native/ssbms/*.d native/ow_bms/*.o native/ow_bms/*.d; \
		$(MAKE) -C fa_cfg ESP_TARGET=$$t || exit 1; \
	done
	rm -f fa_cfg/*.o fa_cfg/*.d conf/*.o conf/*.d native/*.o native/*.d native/ssbms/*.o native/ssbms/*.d native/ow_bms/*.o native/ow_bms/*.d

# Built from pkgdesc.qml rather than a --buildPkg string, so the package can
# declare isCompatible and refuse non-Express hardware. --testPkgDesc runs that
# function at build time against a fake device, so a broken check is caught here
# instead of on a user's bench.
README-gen.md: README.md version
	cp $< $@
	echo "" >> $@
	echo "### Build Info" >> $@
	echo "" >> $@
	echo "- Version: ${VERSION}" >> $@
	echo "- Build Date: `date --rfc-3339=seconds`" >> $@
	echo "- Git Commit: #`git rev-parse --short HEAD`" >> $@

# The About box is generated from README-gen.md, so it cannot drift from the
# package store description. gen_ui.py does the substitution (not sed, which
# would need escaping for arbitrary markdown).
ui.qml: ui.qml.in version README-gen.md gen_ui.py conf/pin_caps.py
	$(PYTHON) gen_ui.py

# The lisp's package version, from the same `version` file as the About box.
lib/version-gen.lisp: version gen_version.py
	$(PYTHON) gen_version.py

PACKAGE_DEPS = esp_led_libs fa_cfg_libs pkgdesc.qml README-gen.md ui.qml lib/version-gen.lisp compact_package.py build_package.py

float_accessories.vescpkg: $(PACKAGE_DEPS)
	$(PYTHON) build_package.py --vesc-tool "$(VESC_TOOL)"

# A target build needs only that chip's toolchain and native binaries.
float_accessories_esp32c3.vescpkg: ESP_TARGETS = esp32c3
float_accessories_esp32c6.vescpkg: ESP_TARGETS = esp32c6
float_accessories_esp32s3.vescpkg: ESP_TARGETS = esp32s3
float_accessories_esp32s31.vescpkg: ESP_TARGETS = esp32s31

float_accessories_%.vescpkg: $(PACKAGE_DEPS)
	$(PYTHON) build_package.py --vesc-tool "$(VESC_TOOL)" --target "$*"

clean:
	rm -f float_accessories.vescpkg
	rm -f float_accessories_esp32c3.vescpkg float_accessories_esp32c6.vescpkg float_accessories_esp32s3.vescpkg
	rm -f README-gen.md ui.qml
	for t in $(ESP_TARGETS); do \
		$(MAKE) -C fa_cfg ESP_TARGET=$$t clean; \
	done
	$(MAKE) -C ../lib_esp_led_strip clean ESP_TARGETS="$(ESP_TARGETS)"

.PHONY: all clean test esp_led_libs fa_cfg_libs
