# Windows toolkit: patcher + extractfv for use on a PC.
#
# No launcher (BDS) is built on purpose; see ../toolkit_android/Makefile for why.
# Requires mingw-w64. The xz source is fetched by
# tools/build_extractfv_windows.sh on first use.
.PHONY: clean copy_resources patcher extractfv build test

MINGW_PREFIX ?= x86_64-w64-mingw32-

clean:
	rm -rf build || true

copy_resources:
	mkdir -p build/toolkit/bin build/toolkit/images
	cp -r resources/. build/toolkit/

patcher: copy_resources
	@command -v $(MINGW_PREFIX)gcc > /dev/null 2>&1 || \
		{ echo "Error: $(MINGW_PREFIX)gcc not found, install mingw-w64"; exit 1; }
	$(MINGW_PREFIX)gcc -O2 -I../../tools ../../tools/patch_abl.c \
		-o build/toolkit/bin/patch_abl.exe -static

extractfv: copy_resources
	@command -v $(MINGW_PREFIX)gcc > /dev/null 2>&1 || \
		{ echo "Error: $(MINGW_PREFIX)gcc not found, install mingw-w64"; exit 1; }
	MINGW_PREFIX="$(MINGW_PREFIX)" bash ../../tools/build_extractfv_windows.sh
	cp ../../dist/extractfv.exe build/toolkit/bin/extractfv.exe

build: patcher extractfv
	@test -f build/toolkit/bin/patch_abl.exe || { echo "Error: patch_abl.exe missing"; exit 1; }
	@test -f build/toolkit/bin/extractfv.exe || { echo "Error: extractfv.exe missing"; exit 1; }
	@test ! -e build/toolkit/BDS.efi || { echo "Error: a BDS image must not ship in this package"; exit 1; }
	cd build/toolkit && zip -r ../toolkit_windows.zip ./

test:
	sh ../../tests/012_test_toolkit.sh windows build/toolkit_windows.zip
