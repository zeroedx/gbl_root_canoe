# GBL Root Canoe

[中文版](README_zh.md)

`gbl_root_canoe` is an EDK2-based workspace for patching the EFI applications within Qualcomm ABL (Android Bootloader) images. It leverages a GBL (Generic Bootloader Loader) vulnerability to patch the ABL, primarily intended for achieving a **Fake Locked Bootloader** state on Snapdragon 8 Gen 5 / 8 Elite (Gen 5) devices to bypass bootloader unlock detection. The patched EFI is flashed into the `efisp` partition.

The project ships one artifact: a **Magisk module** (`magisk_module.zip`) for on-device use.

---

## Builder Guide

This section is for developers who want to compile the artifacts from source.

### Prerequisites
You must be on a **Linux** host to build the project:
- `gcc` / `clang`, `make`, `zip`, `python3`
- `liblzma-dev` (for compiling `extractfv`)
- **Android NDK** (Required for `make build_module` to cross-compile tools for Android)

### Build Targets

**Note:** You **do not** need to provide an `abl.img` to build the distributable artifact. Set the `DIST_NAME` environment variable to name your release ZIP (e.g., `DIST_NAME=magisk_module make build_module`).

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

**Supported devices:**
The module identifies the device by its codename (`ro.product.name`). The explicitly supported device identifiers are `myron`, `pudding`, `popsicle`, `pandora`, `nezha`, and `nezha_global`. For each of these a vulnerable ABL is bundled in the module; if the bundled firmware is missing or fails its SHA-256 check, the module falls back to the cloud repo and verifies the download the same way. An unknown device is never mapped onto another model — installation aborts safely without touching the `abl` partition.

`nezha` and `nezha_global` are identified and mapped independently: `nezha_global` is the global ROM of the `nezha` device and ships different ABL firmware, so it is matched separately by its `...MIXM` build suffix and never falls back to the domestic image.

**Installation & Usage:**
When flashing the Magisk module via a root manager (like KernelSU, Magisk, or APatch), the customized script will interact with you using the volume keys:
- **Volume Up (First-time installation):** The script automatically extracts the live `.abl` image, patches it, and flashes the patched file directly to `/dev/block/by-name/efisp`. After this finishes, you must reboot into Recovery mode and **format Data**. Once booted, install this module again (selecting Volume Down the second time) to complete the installation.
- **Volume Down (OTA retention or post-format):** Used for retaining the BL version after an OTA update. Before updating OTA, use the module to automatically downgrade ABL, then reboot the system.

> **Note:** This module's ID is `zeroedx_fake_bl_efisp`. If you previously installed the module under its old ID, uninstall the old module manually in your root manager before installing this one, so that the old and new modules do not run at the same time and touch the same partitions or files. Magisk/KernelSU will not automatically upgrade a module with the old ID to this one.

### 2. OTA Upgrade
Before rebooting for an OTA update, use the module to flash and retain the old ABL version. If you are doing a major version upgrade, it is recommended to check "Update efisp", otherwise the device might get stuck on the initial boot screen.

### 3. Explanation of Different Variants
1. `ABL.efi`: The patched ABL (fake re-lock).
2. `ABL_original.efi`: For developers to analyze in IDA, used for error reporting. **DO NOT flash**.
