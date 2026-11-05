VESC_TOOL ?= vesc_tool
PYTHON ?= python3

# One binary per chip - native libs only run on the chip they were built for.
ESP_TARGETS = esp32c3 esp32c6 esp32s3 esp32s31 esp32p4

# Single source of truth for the version, stamped into README-gen.md and into
# esp_led_version.lisp - which float_accessories imports too.
VERSION=`cat version`

all: esp_led_strip.vescpkg

esp_led_strip.vescpkg: libs pkgdesc.qml README-gen.md ui.qml
	$(VESC_TOOL) --buildPkgFromDesc pkgdesc.qml \
	--testPkgDesc 'custom:Devkit C3' --testPkgDesc 'custom:Avaspark RGB V3' \
	--testPkgDesc 'vesc bms:VESC BMS' --testPkgDesc 'vesc:test' 

# The store description. gen_readme.py translates README.md into the markdown
# VESC Tool renders (see its docstring); Build Info names the version and the
# commit the binaries came from.
README-gen.md: README.md version gen_readme.py
	$(PYTHON) gen_readme.py
	echo "" >> $@
	echo "### Build Info" >> $@
	echo "" >> $@
	echo "- Version: ${VERSION}" >> $@
	echo "- Build Date: `date --rfc-3339=seconds`" >> $@
	echo "- Git Commit: #`git rev-parse --short HEAD`" >> $@

# The About dialog comes from README-gen.md, so it cannot drift from the store
# description.
ui.qml: ui.qml.in version README-gen.md gen_ui.py
	$(PYTHON) gen_ui.py

# Shared lisp constants, generated from the C enums so consumers cannot drift.
defs: esp_led_defs.lisp esp_led_version.lisp
esp_led_defs.lisp: gen_defs.py esp_led_strip/code.c
	$(PYTHON) gen_defs.py

# The lisp-visible library version, from the same `version` file as the README.
esp_led_version.lisp: version gen_version.py
	$(PYTHON) gen_version.py

# Objects are not target-suffixed, so they are removed between targets.
# float_accessories builds this target for the binaries and the generated
# lisp, so the version is generated here, not only for the .vescpkg.
libs: esp_led_defs.lisp esp_led_version.lisp
	for t in $(ESP_TARGETS); do \
		rm -f esp_led_strip/*.o esp_led_strip/*.d; \
		$(MAKE) -C esp_led_strip ESP_TARGET=$$t || exit 1; \
	done
	rm -f esp_led_strip/*.o esp_led_strip/*.d

clean:
	rm -f esp_led_strip.vescpkg README-gen.md ui.qml
	for t in $(ESP_TARGETS); do \
		$(MAKE) -C esp_led_strip ESP_TARGET=$$t clean; \
	done

.PHONY: all clean libs defs
