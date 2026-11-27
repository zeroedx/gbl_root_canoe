# Android toolkit: patcher + extractfv for on-device use.
#
# No launcher (BDS) is built on purpose. The package targets a device that the
# Magisk module configured, where the patched loader lives raw at offset 0 of
# the efisp partition and no launcher stage exists. Shipping a BDS would let a
# user flash it over that layout and leave the device unbootable.
.PHONY: clean copy_resources patcher extractfv build test

NDK_PATH ?= $(ANDROID_NDK_LATEST_HOME)
NDK_CC := $(NDK_PATH)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android31-clang

clean:
	rm -rf build || true

copy_resources:
	mkdir -p build/toolkit/bin build/toolkit/images
	cp -r resources/. build/toolkit/

patcher: copy_resources
	@test -n "$(NDK_PATH)" || { echo "Error: set NDK_PATH"; exit 1; }
	@test -x "$(NDK_CC)" || { echo "Error: compiler not found: $(NDK_CC)"; exit 1; }
	$(NDK_CC) -O2 -I../../tools ../../tools/patch_abl.c -o build/toolkit/bin/patch_abl

extractfv: copy_resources
	@test -n "$(NDK_PATH)" || { echo "Error: set NDK_PATH"; exit 1; }
	NDK_PATH="$(NDK_PATH)" bash ../../tools/build_extractfv_android.sh
	cp ../../dist/extractfv_android build/toolkit/bin/extractfv

build: patcher extractfv
	@test -x build/toolkit/bin/patch_abl || { echo "Error: patch_abl missing"; exit 1; }
	@test -x build/toolkit/bin/extractfv || { echo "Error: extractfv missing"; exit 1; }
	@test ! -e build/toolkit/BDS.efi || { echo "Error: a BDS image must not ship in this package"; exit 1; }
	cd build/toolkit && zip -r ../toolkit_android.zip ./

test:
	sh ../../tests/012_test_toolkit.sh android build/toolkit_android.zip
