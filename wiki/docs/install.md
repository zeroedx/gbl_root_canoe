# Installation Guide

## Boot Flow

There are two distinct locations, and they must not be confused:

- The raw **`efisp` partition** (`/dev/block/by-name/efisp`) — a bare block device.
- The **`efisp/` directory** on the `persist` partition (ext4, auto-mounted at `/mnt/vendor/persist`) — a filesystem directory.

Upstream, the real ABL (via the GBL vulnerability) loaded an embedded **superfastboot BDS** from the raw `efisp` partition. The BDS then scanned the `persist` `efisp/` boot root, read `BOOTENTRIES`, and chained to the selected entry — that was the only component that read those files:

| File (in `persist` `efisp/`) | Purpose |
|------|---------|
| `boot.efi` | Cracked ABL with fake re-lock (`Android` entry) |
| `boot_backup.efi` | Previous `boot.efi` (`$Android backup` entry) |
| `BOOTENTRIES` | Boot entry list for the BDS, format `<name>:<path relative to efisp/>` |

> ⚠️ **This fork removes the BDS.** The BDS is no longer built, packaged, or flashed to the `efisp` partition, so **nothing in this fork reads the `persist` `efisp/` boot root or `BOOTENTRIES`**. The cracked `boot.efi` is still produced and written to `persist/efisp/boot.efi`, but it now has **no known load path**. The native (e.g. Xiaomi) fastboot is **not** known to read `BOOTENTRIES` or to load `persist/efisp/boot.efi`.

## 1. Prerequisite: GBL Vulnerability

The ABL on the `abl` partition must contain the **GBL vulnerability**, which is what makes the ABL use the `efisp` scenario. If your ABL lacks it, flash an **older ABL version** that has the vulnerability to the `abl` partition first. The cracked `boot.efi` does **not** need to match the ABL on the `abl` partition.

## 2. Install Method

| Method | Description |
|--------|-------------|
| **KernelSU module (Recommended)** | Automated: extracts & cracks the current ABL and lays out the boot root |
| **Toolkit (Manual)** | For traditional users: run `build.sh` / `build.bat` on your `abl.img`, then place files manually |

## 3. Module Install (KernelSU)

### 3.1 Fresh install

1. Install the module via KernelSU. When prompted, press **Vol+ (YES)**.
   The module extracts & cracks the current-slot ABL and places `boot.efi` / `BOOTENTRIES` into `/mnt/vendor/persist/efisp/`.
2. Reboot to **Recovery** and **format data**.
   > ⚠️ The first reboot may crash — simply retry.
3. Reinstall the module and press **Vol- (NO)** to install the OTA-update patch.
4. Reboot the system.

### 3.2 After an OTA

After each OTA, open the module WebUI and flash again to keep the BL version (re-cracks the new ABL to the inactive slot / refreshes the `persist` `efisp/` tree).

> ⚠️ Reminder: with the BDS removed, this fork produces the `persist` `efisp/` tree but installs nothing that reads it. There is currently **no known load path** for the cracked `boot.efi`.

## 4. Toolkit Install (Manual)

1. Place your `abl.img` in the toolkit `images/` folder and run `build.sh` (Android/Linux) or `build.bat` (Windows). Outputs:
   - `ABL.efi` — cracked ABL (fake re-lock)
   - `ABL_original.efi` — original unpatched ABL
2. Create the folder `/mnt/vendor/persist/efisp` (e.g. via MT Manager).
3. Copy `ABL.efi` into it as `boot.efi`.
4. Create `BOOTENTRIES` with:
   ```
   Android:boot.efi
   ```
5. `sync`
   If the build log shows `Failed to patch ABL GBL`, downgrade the `abl` partition to an older ABL with the vulnerability before booting.

> ⚠️ Steps 2–5 lay out the `persist` `efisp/` tree. In this fork (BDS removed) **nothing loads it**; the `BOOTENTRIES` file has no reader.

## 5. Re-lock Mode

| Mode | Applicable scenario |
|------|---------------------|
| **True re-lock** | Devices with official unlock support (e.g. OnePlus), or international devices that passed official unlock review |
| **Fake re-lock** | Force-unlocked devices, or devices needing official fastboot as fallback |

- **Fake re-lock**: the cracked `boot.efi` already provides the fake lock.
- **True re-lock**: use the official fastboot of your device to perform the re-lock operation.
  - ✅ Some devices (e.g. Dami): re-lock does **not** wipe data.
  - ⚠️ OnePlus: requires a **deep test unlock**; data will be lost, but root is retained.

## ⚠️ Important Warnings

> Before performing any operation, verify the following:

- 📌 Restore any partition **other than those containing `boot`** that you modified.
- 📌 Partitions verified by `init`: **AVB must remain enabled** — do not modify.
- 📌 The `dtbo` partition verified by ABL **must not be modified** in true re-lock mode.
- ❌ **Do NOT install TWRP** — it will cause **data corruption**.
