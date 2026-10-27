clean:
	rm -f tools/patch_abl || true
	rm -rf dist || true
	rm -rf ./build || true
	mkdir dist

# Dev helper: patch a local images/abl.img and inspect the result.
patch: clean
	gcc -O2 -o ./tools/extractfv ./tools/extractfv.c -llzma
	./tools/extractfv ./images/abl.img -o ./dist
	rm ./tools/extractfv
	mv ./dist/LinuxLoader.efi ./dist/ABL_original.efi
	gcc -o tools/patch_abl tools/patch_abl.c
	./tools/patch_abl ./dist/ABL_original.efi ./dist/ABL.efi > ./dist/patch_log.txt
	rm tools/patch_abl
	cat ./dist/patch_log.txt

# Android-native patcher binaries used by the Magisk module.
build_patcher_android:
	rm -rf ./dist
	mkdir -p ./dist
	$(NDK_PATH)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android31-clang tools/patch_abl.c -o dist/patch_abl_android
	bash ./tools/build_extractfv_android.sh

build_module: build_patcher_android
	mv dist/patch_abl_android magisk_module/bin/patch_abl
	mv dist/extractfv_android magisk_module/bin/extractfv
	mkdir -p release
	cd magisk_module && zip -r ../release/$(DIST_NAME).zip ./
	rm -f magisk_module/bin/patch_abl
	rm -f magisk_module/bin/extractfv

test:
	bash ./tests/runall.sh
