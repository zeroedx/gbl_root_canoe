# Build Guide

There is no device-specific or "generic" top-level build; the distributable
toolkits and module are built with the `target_*` targets, and each toolkit then
runs its own `build.sh` / `build.bat` against an `abl.img` you supply.


## Building the Toolkits / Module

Build from the repository root (see the README for prerequisites):

```bash
make target_toolkit_linux      # toolkit_linux.zip
make target_toolkit_windows    # toolkit_windows.zip
make target_toolkit_android    # toolkit_android.zip
make target_magisk_module      # module_android.zip
```

You do **not** need an `abl.img` to build these; the image is only required later
when you run the toolkit's `build.sh` / `build.bat`.


## Patching a Specific Device's ABL

1. Place the device's `abl.img` into the toolkit's `./images` folder
   (`PUT_ABL_IMG_HERE` is only a placeholder).
2. Run the toolkit's `build.sh` (Linux / Android) or `build.bat` (Windows).

The toolkit extracts and cracks the ABL and lays out an `efisp/` folder
(`boot.efi`, `BOOTENTRIES`, `tools/`). See the Install page for where those files
go and what currently loads them.

> Note: because the ABL patch depends on the GBL vulnerability, the ABL must
> carry it. If `patch_log.txt` reports `Failed to patch ABL GBL`, the `abl`
> partition must be downgraded to an older ABL that still has the vulnerability
> before booting.
