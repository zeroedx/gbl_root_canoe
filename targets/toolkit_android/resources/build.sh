#!/system/bin/sh
# Build a patched efisp loader from images/abl.img using the packaged tools.
#
# This runs entirely on the device against a user-supplied ABL dump. Nothing
# here writes a partition, so a failed run can never leave the device
# unbootable. The output goes in the same place the Magisk module writes it:
# raw at the start of the efisp partition. No launcher (BDS) is produced or
# needed, so this package stays compatible with a module-configured device.
set -e

SCRIPTDIR=$(dirname "$0")
cd "$SCRIPTDIR"

if [ ! -f ./images/abl.img ]; then
  echo "ERROR: place your stock ABL dump at images/abl.img first."
  exit 1
fi
for tool in ./bin/extractfv ./bin/patch_abl; do
  if [ ! -x "$tool" ]; then
    echo "ERROR: $tool is missing, extract the complete toolkit archive."
    exit 1
  fi
done

# A leftover output from an earlier run must never be mistaken for this run's
# result: a stale efisp.img would let a failed patch look successful.
rm -f ./efisp.img ./ABL_original.efi ./patch_log.txt
if [ -e ./efisp.img ] || [ -e ./ABL_original.efi ] || [ -e ./patch_log.txt ]; then
  echo "ERROR: cannot remove outputs from a previous run."
  exit 1
fi

rm -rf ./extracted
mkdir -p ./extracted

if ! ./bin/extractfv -o ./extracted ./images/abl.img; then
  echo "ERROR: extractfv failed."
  exit 1
fi
if [ ! -s ./extracted/LinuxLoader.efi ]; then
  echo "ERROR: extractfv produced no LinuxLoader.efi."
  exit 1
fi

mv ./extracted/LinuxLoader.efi ./ABL_original.efi
if ! ./bin/patch_abl ./ABL_original.efi ./efisp.img > ./patch_log.txt 2>&1; then
  cat ./patch_log.txt
  rm -f ./efisp.img
  echo "ERROR: patch_abl failed."
  exit 1
fi
cat ./patch_log.txt
if [ ! -s ./efisp.img ]; then
  echo "ERROR: patch_abl produced no efisp.img."
  exit 1
fi

# The patched loader is valid either way, but without the GBL patch the
# vulnerability is absent and the abl partition has to be downgraded first.
# Report that as its own outcome rather than a plain success.
if grep -q "Warning: Failed to patch ABL GBL" ./patch_log.txt; then
  gbl_ok=no
  echo ""
  echo "WARNING: no GBL exploit found in this ABL (Failed to patch ABL GBL)."
  echo "efisp.img is still produced and valid, but the abl partition must be"
  echo "downgraded to an older ABL with the GBL vulnerability before booting."
  echo "警告：此 ABL 中未找到 GBL 漏洞（Failed to patch ABL GBL）。"
  echo "efisp.img 仍已生成且有效，但开机前必须将 abl 分区降级为带 GBL 漏洞的旧版 ABL。"
else
  gbl_ok=yes
fi

echo ""
echo "========================================"
echo "Patched. Outputs:"
echo "  efisp.img        - patched loader, write it to the START of the efisp partition"
echo "  ABL_original.efi - original unpatched loader (analysis only, do NOT flash)"
echo "  patch_log.txt    - full patcher output, including the GBL verdict"
echo ""
echo "efisp.img is written raw at offset 0 of the efisp partition, which is exactly"
echo "where the Magisk module puts it. No launcher stage is involved, so do not"
echo "flash any BDS image on top of this layout."
echo ""
echo "---- Manual install flow ----"
echo "1. Copy efisp.img to the device and write it to the efisp partition:"
echo "     dd if=efisp.img of=/dev/block/by-name/efisp bs=4M conv=fsync"
echo "2. Read the written range back and compare it before rebooting:"
echo "     dd if=/dev/block/by-name/efisp bs=4M count=<size/4M> | cmp - efisp.img"
if [ "$gbl_ok" = "no" ]; then
  echo "3. Downgrade the abl partition to an older ABL with the GBL vulnerability"
  echo "   BEFORE rebooting, or the device will not boot."
fi
echo "========================================"
