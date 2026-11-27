# Toolkits

Two standalone packages that patch an ABL dump on a PC or on the device. They
produce the same output as the Magisk module: a patched loader written raw at
offset 0 of the `efisp` partition.

```
make toolkit_android   # needs NDK_PATH (or ANDROID_NDK_LATEST_HOME)
make toolkit_windows   # needs mingw-w64; xz source is fetched on first build
```

Outputs land in `release/toolkit_android.zip` and
`release/toolkit_windows.zip`.

## No launcher (BDS) is built

Neither package ships a BDS image, and this is enforced at build time. The
module writes the patched loader raw at offset 0 of `efisp` with no launcher
stage in front of it, so a BDS flashed over that layout would not boot. The
packages therefore only extract, patch, and verify; they never emit a boot
manager.

## What a package contains

| Path | Purpose |
| --- | --- |
| `build.sh` / `build.bat` | Extracts `images/abl.img`, patches it, reports the GBL verdict |
| `bin/extractfv` | Pulls `LinuxLoader.efi` out of an ABL image |
| `bin/patch_abl` | Applies the GBL patch and reports whether the exploit was found |
| `images/PUT_ABL_IMG_HERE` | Placeholder; drop your stock ABL dump here as `abl.img` |

## Usage

1. Put your stock ABL dump at `images/abl.img`.
2. Run `build.sh` (Android) or `build.bat` (Windows).
3. Read the GBL verdict in the output. If the patcher reports
   `Warning: Failed to patch ABL GBL`, the loader is still valid but the `abl`
   partition must be downgraded before booting.
4. Write `efisp.img` to the `efisp` partition and verify the written range
   before rebooting. The script prints the exact commands.

The scripts touch no partition themselves, so a failed run cannot leave the
device unbootable.
