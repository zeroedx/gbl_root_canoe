# GBL Root Canoe

[中文版](README_zh.md)

`gbl_root_canoe` is an EDK2-based workspace for patching the EFI applications within Qualcomm ABL (Android Bootloader) images. It leverages a GBL (Generic Bootloader Loader) vulnerability to patch the ABL, primarily intended for achieving a **Fake Locked Bootloader** state on Snapdragon 8 Gen 5 / 8 Elite (Gen 5) devices to bypass bootloader unlock detection. The patched EFI is flashed into the `efisp` partition.

The project ships two artifacts: a **Magisk module** (`magisk_module.zip`) for on-device use, and a **Windows patching toolkit** (`toolkit_windows.zip`) for patching an `abl.img` on a PC.

---

## Builder Guide

This section is for developers who want to compile the artifacts from source.

### Prerequisites
You must be on a **Linux** host to build the project:
- `gcc` / `clang`, `make`, `zip`, `python3`
- `liblzma-dev` (for compiling `extractfv`)
- **Android NDK** (Required for `make build_module` to cross-compile tools for Android)
- **MinGW-w64** (`x86_64-w64-mingw32-gcc`, required for `make dist_loader_windows` cross-compilation)

### Build Targets

**Note:** You **do not** need to provide an `abl.img` to build the distributable artifacts. Set the `DIST_NAME` environment variable to name your release ZIP (e.g., `DIST_NAME=toolkit make dist_loader_windows`).

- **`make dist_loader_windows`**
  Cross-compiles the patching utilities (`extractfv`, `patch_abl`) into Windows `.exe` programs using MinGW-w64 and packages them into `release/$(DIST_NAME)_windows.zip`.

- **`make build_module`**
  Cross-compiles the patcher tools for Android using your NDK and packages them into a Magisk Module zip in `release/`.

- **`make patch`**
  Development helper: patches a local `images/abl.img` and drops the result in `dist/` for inspection.

---

## User Guide

This section is for end-users using the compiled outputs found in the `release/` directory. For more detailed instructions, please refer to the [Wiki](https://github.com/superturtlee/gbl_root_canoe/wiki).

### 1. Using the Magisk Module (On-Device)

The Magisk module is designed to run directly on your rooted Android device.

**Requirements:**
- Device must be Snapdragon 8 Gen 5 / 8 Elite (Gen 5).
- Bootloader must be unlocked.
- Kernel must NOT have Baseband Guard.

**Installation & Usage:**
When flashing the Magisk module via a root manager (like KernelSU, Magisk, or APatch), the customized script will interact with you using the volume keys:
- **Volume Up (First-time installation):** The script automatically extracts the live `.abl` image, patches it, and flashes the patched file directly to `/dev/block/by-name/efisp`. After this finishes, you must reboot into Recovery mode and **format Data**. Once booted, install this module again (selecting Volume Down the second time) to complete the installation.
- **Volume Down (OTA retention or post-format):** Used for retaining the BL version after an OTA update. Before updating OTA, use the module to automatically downgrade ABL, then reboot the system.

### 2. Using the Windows Toolkit

If you downloaded the `toolkit_windows.zip` file:
1. Extract the toolkit zip on your PC.
2. Place your device's stock `abl.img` inside the `images\` directory of the toolkit.
3. Run `build.bat`.
4. The script extracts and patches the ABL, outputting `ABL.efi` (patched, for the fake re-lock) and `ABL_original.efi` (original, for analysis only). Check `patch_log.txt`; if it says "Warning: Failed to patch ABL GBL", the device is not vulnerable and the `abl` partition needs to be downgraded to an older ABL with the vulnerability.

Then flash the patched `ABL.efi` to the `efisp` partition (e.g. `fastboot flash efisp ABL.efi`) or use the on-device module flow described above.

### 3. OTA Upgrade
Before rebooting for an OTA update, use the module to flash and retain the old ABL version. If you are doing a major version upgrade, it is recommended to check "Update efisp", otherwise the device might get stuck on the initial boot screen.

### 4. Explanation of Different Variants
1. `ABL.efi`: The patched ABL (fake re-lock).
2. `ABL_original.efi`: For developers to analyze in IDA, used for error reporting. **DO NOT flash**.
