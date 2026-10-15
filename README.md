# GBL Root Canoe

[中文版](README_zh.md)

![Stone Badge](https://stone.professorlee.work/api/stone/superturtlee/gbl_root_canoe)

`gbl_root_canoe` is an EDK2-based workspace for patching the EFI applications within Qualcomm ABL (Android Bootloader) images. It leverages a GBL (Generic Bootloader Loader) vulnerability to patch the ABL into a cracked loader that provides a **Fake Locked Bootloader** state on Snapdragon 8 Gen 5 / 8 Elite (Gen 5) devices, bypassing bootloader unlock detection.

Two different locations are involved and are easy to confuse:

- The raw **`efisp` partition** (`/dev/block/by-name/efisp`) — a bare block device.
- The **`efisp/` directory** on the `persist` partition (ext4, auto-mounted at `/mnt/vendor/persist`) — a filesystem directory holding `boot.efi` (the cracked ABL), `boot_backup.efi`, `BOOTENTRIES` and `tools/`.

> ⚠️ **This fork removes the superfastboot integration.** Upstream also built and flashed a first-stage loader — the *superfastboot BDS* (`BDS.efi`, built from the `uefi` submodule) — **raw to the `efisp` partition**. That loader was the only component that read the `persist` `efisp/` boot root and `BOOTENTRIES`, then chained to the selected entry. In this fork the BDS is **no longer built, packaged, or flashed**. The cracked ABL is still produced and (in the module/toolkit flow) still written to `persist/efisp/boot.efi`, but **no bundled component loads it any more**. The device's native (e.g. Xiaomi) fastboot is **not** known to read `BOOTENTRIES` or to load `persist/efisp/boot.efi`. Until a loading path is established, treat the `persist` `efisp/` files as **produced but without a known load path**.

---

## Builder Guide

This section is for developers who want to compile the toolkits from source.

### Prerequisites
You must be on a **Linux** host to build the project:
- `gcc` / `clang`, `lld`, `make`, `zip`, `python3`
- `liblzma-dev` (for compiling `extractfv`)
- **Android NDK** (Required for `make target_magisk_module` to cross-compile tools for Android)
- **MinGW-w64**

### Build Targets

**Note:** You **do not** need to provide an `abl.img` to build the distributable toolkits or module.

- **`make target_toolkit_linux`**
  Builds the boot-menu tools (`RebootTools`, `BLTools`, `ArbTools`) from the `uefi` submodule and compiles the patching utilities (`extractfv`, `patch_abl`) for Linux.

- **`make target_toolkit_windows`**
  Same as above, but cross-compiles the utilities into Windows `.exe` programs using MinGW-w64.

- **`make target_magisk_module`**
  Cross-compiles the patcher tools for Android using your NDK, builds the tools, and packages everything as a KernelSU/Magisk module.

- **`make target_toolkit_android`**
  Produces a standalone Android arm64 toolkit (`toolkit_android.zip`) with Android-native binaries for on-device use outside of the module.

---

## User Guide

For more detailed instructions, please refer to the [Wiki](https://github.com/superturtlee/gbl_root_canoe/wiki).

### 1. Using the Module (On-Device)

The module is designed to run directly on your rooted Android device.

**Requirements:**
- Device must be Snapdragon 8 Gen 5 / 8 Elite (Gen 5).
- Bootloader must be unlocked.
- Kernel must NOT have Baseband Guard.
- The ABL on the `abl` partition must contain the GBL vulnerability. If it does not, flash an older ABL with the vulnerability first (the cracked `boot.efi` does not need to match the ABL on the `abl` partition).

**Installation & Usage:**
When flashing the module via a root manager (KernelSU, Magisk, or APatch), the script interacts with you using the volume keys:
- **Volume Up (First-time installation):** The script extracts the current-slot `.abl`, cracks it into `boot.efi`, and places `boot.efi` and `BOOTENTRIES` (plus `tools/`) into `/mnt/vendor/persist/efisp/`. After this, reboot into Recovery and **format Data**. Once booted, install this module again (Volume Down the second time) to complete the installation.
- **Volume Down (OTA retention or post-format):** Installs the OTA-update patch. After each OTA, open the module WebUI and flash again to retain the BL version.

> ⚠️ With the BDS removed, this fork lays out the `persist` `efisp/` boot root but does not install anything that reads it. There is currently **no known load path** for the cracked `boot.efi` in this fork.

### 2. Using the PC Toolkits (Linux / Windows)

If you downloaded the `target_toolkit_linux` or `target_toolkit_windows` zip files:
1. Extract the toolkit zip on your PC.
2. Place your device's stock `abl.img` inside the `images/` (or `images\`) directory of the toolkit.
3. **Linux:** Run `bash build.sh`. **Windows:** Run `build.bat`.
4. The script extracts and cracks the ABL, outputting `ABL.efi` (fake re-lock) and `ABL_original.efi` (original). Check `patch_log.txt` - if it says "Warning: Failed to patch ABL GBL", the ABL lacks the vulnerability and the `abl` partition must be downgraded to an older ABL with it.

Then complete the install manually (see the [Wiki](https://github.com/superturtlee/gbl_root_canoe/wiki) for full steps): copy `ABL.efi` into `/mnt/vendor/persist/efisp/` (as `boot.efi`), create `BOOTENTRIES`, and `sync`. (As noted above, with the BDS removed nothing in this fork loads those files.)

### 3. OTA Upgrade
Before rebooting for an OTA update, use the module WebUI to flash and retain the old ABL version. "Update efisp" is enabled by default; for a major version upgrade keep it on, otherwise the device may get stuck on the first boot screen.

### 4. File Reference
1. `boot.efi` / `ABL.efi`: The cracked ABL with fake re-lock (the module names it `boot.efi`; the toolkit names it `ABL.efi`), written to the `persist` partition under `efisp/`. With the BDS removed, this fork has **no known component that loads it**.
2. `BDS.efi`: The upstream superfastboot first-stage loader, flashed raw to the `efisp` partition. **Removed in this fork** — no longer built, packaged, or flashed.
3. `LinuxLoader.efi` / `ABL_original.efi`: the extracted, unpatched ABL EFI. `extractfv` first writes it as `LinuxLoader.efi`; the toolkit then renames it to `ABL_original.efi` and keeps it for analysis (do not flash). Neither file is part of the module's final output — the original image is your stock `abl.img`, and the patched result is `boot.efi` / `ABL.efi` (item 1).
4. `BOOTENTRIES`: Boot entry list for the superfastboot BDS (`<name>:<path relative to efisp/>`). Its only consumer was the BDS; without it, the file has no reader in this fork.
