@echo off
rem Build a patched efisp loader from images\abl.img using the packaged tools.
rem
rem Nothing here writes a partition, so a failed run can never leave the device
rem unbootable. The output matches the Magisk module layout: the loader is
rem written raw at the start of the efisp partition, with no launcher (BDS).
setlocal enabledelayedexpansion
cd /d "%~dp0"

if not exist "images\abl.img" (
  echo ERROR: place your stock ABL dump at images\abl.img first.
  exit /b 1
)
if not exist "bin\extractfv.exe" (
  echo ERROR: bin\extractfv.exe is missing, extract the complete toolkit archive.
  exit /b 1
)
if not exist "bin\patch_abl.exe" (
  echo ERROR: bin\patch_abl.exe is missing, extract the complete toolkit archive.
  exit /b 1
)

rem A leftover output from an earlier run must never be mistaken for this run's
rem result: a stale efisp.img would let a failed patch look successful.
if exist "efisp.img" del /q "efisp.img"
if exist "ABL_original.efi" del /q "ABL_original.efi"
if exist "patch_log.txt" del /q "patch_log.txt"
if exist "efisp.img" (
  echo ERROR: cannot remove efisp.img from a previous run.
  exit /b 1
)

if exist "extracted" rmdir /s /q "extracted"
mkdir "extracted"

"bin\extractfv.exe" -o "extracted" "images\abl.img"
if errorlevel 1 (
  echo ERROR: extractfv failed.
  exit /b 1
)
if not exist "extracted\LinuxLoader.efi" (
  echo ERROR: extractfv produced no LinuxLoader.efi.
  exit /b 1
)

move /y "extracted\LinuxLoader.efi" "ABL_original.efi" >nul
"bin\patch_abl.exe" "ABL_original.efi" "efisp.img" > "patch_log.txt" 2>&1
if errorlevel 1 (
  type "patch_log.txt"
  if exist "efisp.img" del /q "efisp.img"
  echo ERROR: patch_abl failed.
  exit /b 1
)
type "patch_log.txt"
if not exist "efisp.img" (
  echo ERROR: patch_abl produced no efisp.img.
  exit /b 1
)

rem The patched loader is valid either way, but without the GBL patch the
rem vulnerability is absent and the abl partition has to be downgraded first.
findstr /c:"Warning: Failed to patch ABL GBL" "patch_log.txt" >nul 2>&1
if not errorlevel 1 (
  set "gbl_ok=no"
  echo.
  echo WARNING: no GBL exploit found in this ABL ^(Failed to patch ABL GBL^).
  echo efisp.img is still produced and valid, but the abl partition must be
  echo downgraded to an older ABL with the GBL vulnerability before booting.
) else (
  set "gbl_ok=yes"
)

echo.
echo ========================================
echo Patched. Outputs:
echo   efisp.img        - patched loader, write it to the START of the efisp partition
echo   ABL_original.efi - original unpatched loader ^(analysis only, do NOT flash^)
echo   patch_log.txt    - full patcher output, including the GBL verdict
echo.
echo efisp.img is written raw at offset 0 of the efisp partition, which is exactly
echo where the Magisk module puts it. No launcher stage is involved, so do not
echo flash any BDS image on top of this layout.
echo.
echo ---- Manual install flow ----
echo 1. Copy efisp.img to the device and write it to the efisp partition:
echo      dd if=efisp.img of=/dev/block/by-name/efisp bs=4M conv=fsync
echo 2. Read the written range back and compare it before rebooting.
if "!gbl_ok!"=="no" (
  echo 3. Downgrade the abl partition to an older ABL with the GBL vulnerability
  echo    BEFORE rebooting, or the device will not boot.
)
echo ========================================
endlocal
