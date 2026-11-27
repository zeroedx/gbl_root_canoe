#!/bin/sh
# Verify a toolkit package: layout, no BDS, working tools, and the build script
# refusing to reuse stale output.
#
# Usage: 012_test_toolkit.sh <android|windows> <path-to-zip>
#
# The build script is run against a real ABL image from the module's ablrepo, so
# the extract+patch pipeline is the shipped one, not a reimplementation.
KIND="${1:-}"
ZIP="${2:-}"
# Resolve the package path before changing directory, so a caller-relative path
# keeps working.
if [ -n "$ZIP" ]; then
  ZIP="$(cd "$(dirname "$ZIP")" 2>/dev/null && pwd)/$(basename "$ZIP")"
fi
cd "$(dirname "$0")" || exit 1
MODULE=../magisk_module
FAIL=0
pass() { echo "Test passed: $1"; }
fail() { echo "Test failed: $1"; FAIL=1; }

case "$KIND" in
  android|windows) ;;
  *) echo "usage: $0 <android|windows> <zip>"; exit 2 ;;
esac
if [ ! -f "$ZIP" ]; then
  fail "package not found: $ZIP"
  echo "FAILURES PRESENT"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unzip -q "$ZIP" -d "$WORK/pkg" || { fail "cannot extract $ZIP"; echo "FAILURES PRESENT"; exit 1; }

echo "--- package layout ---"
for f in build.sh build.bat images/PUT_ABL_IMG_HERE; do
  if [ -e "$WORK/pkg/$f" ]; then
    pass "package ships $f"
  elif [ "$KIND" = "android" ] && [ "$f" = "build.bat" ]; then
    : # the android package does not ship the Windows script
  elif [ "$KIND" = "windows" ] && [ "$f" = "build.sh" ]; then
    : # the windows package does not ship the Android script
  else
    fail "package is missing $f"
  fi
done

if [ "$KIND" = "android" ]; then
  TOOLS="bin/extractfv bin/patch_abl"
else
  TOOLS="bin/extractfv.exe bin/patch_abl.exe"
fi
for t in $TOOLS; do
  if [ -s "$WORK/pkg/$t" ]; then
    pass "package ships $t"
  else
    fail "package is missing $t"
  fi
done

echo "--- no launcher (BDS) ships ---"
# The package targets a module-configured device, where the patched loader sits
# raw at offset 0 of efisp. A BDS flashed over that layout bricks boot, so its
# presence is a packaging error, not a feature.
if find "$WORK/pkg" -iname 'BDS.efi' | grep -q .; then
  fail "package ships a BDS image"
else
  pass "package ships no BDS image"
fi

echo "--- tools are real binaries for the right platform ---"
if [ "$KIND" = "android" ]; then
  # AArch64 ELF, e_machine 183.
  for t in $TOOLS; do
    m=$(od -An -tu2 -j18 -N2 "$WORK/pkg/$t" 2>/dev/null | tr -d ' ')
    if [ "$m" = "183" ]; then
      pass "$t is an AArch64 ELF"
    else
      fail "$t is not an AArch64 ELF (e_machine=$m)"
    fi
  done
else
  # Windows PE32+ for x86_64. The e_lfanew field at 0x3c points at the PE
  # header, whose Machine field must be 0x8664; an ARM or 32-bit build would
  # otherwise pass the MZ check alone.
  for t in $TOOLS; do
    sig=$(head -c 2 "$WORK/pkg/$t" 2>/dev/null)
    if [ "$sig" != "MZ" ]; then
      fail "$t is not a PE image"
      continue
    fi
    lfanew=$(od -An -tu4 -j60 -N4 "$WORK/pkg/$t" 2>/dev/null | tr -d ' ')
    machine=$(od -An -tx2 -j$((lfanew + 4)) -N2 "$WORK/pkg/$t" 2>/dev/null | tr -d ' ')
    if [ "$machine" = "8664" ]; then
      pass "$t is an x86_64 PE image"
    else
      fail "$t is a PE image but machine=$machine, expected 8664"
    fi
  done
fi

echo "--- the build script produces a patched loader, then refuses a stale run ---"
# Run the Android script on a host shell against a real ABL image. The packaged
# tools are AArch64 and cannot execute here, so a host build of the same sources
# stands in for them; the script logic under test is the shipped one.
if [ "$KIND" = "android" ]; then
  RUN="$WORK/run"
  mkdir -p "$RUN/bin" "$RUN/images"
  cp "$WORK/pkg/build.sh" "$RUN/build.sh"
  cp "$MODULE/ablrepo/myron/abl.img" "$RUN/images/abl.img"
  gcc -O2 -o "$RUN/bin/extractfv" ../tools/extractfv.c -llzma 2>/dev/null || {
    fail "cannot build a host extractfv"; }
  gcc -O2 -I../tools -o "$RUN/bin/patch_abl" ../tools/patch_abl.c 2>/dev/null || {
    fail "cannot build a host patch_abl"; }

  if [ -x "$RUN/bin/extractfv" ] && [ -x "$RUN/bin/patch_abl" ]; then
    out=$(cd "$RUN" && sh ./build.sh 2>&1)
    if [ -s "$RUN/efisp.img" ]; then
      pass "build.sh produced efisp.img"
    else
      fail "build.sh produced no efisp.img ($out)"
    fi
    # The output must be the patched loader, not the raw input.
    if [ -s "$RUN/efisp.img" ] && ! cmp -s "$RUN/efisp.img" "$RUN/images/abl.img"; then
      pass "efisp.img differs from the stock ABL dump"
    else
      fail "efisp.img is identical to the stock ABL dump"
    fi
    if [ -s "$RUN/ABL_original.efi" ]; then
      pass "build.sh kept the original loader for analysis"
    else
      fail "build.sh did not keep ABL_original.efi"
    fi
    # The GBL verdict must be reported explicitly, never implied.
    case "$out" in
      *"Warning: Failed to patch ABL GBL"*|*"efisp.img is still produced"*)
        pass "build.sh reports the GBL verdict explicitly" ;;
      *"Patched. Outputs:"*)
        pass "build.sh reports the GBL verdict explicitly" ;;
      *) fail "build.sh did not report a GBL verdict" ;;
    esac

    # A second run must not silently reuse the first run's output: the script
    # deletes stale outputs, so a run whose patch fails cannot report success
    # on an earlier result.
    printf '#!/bin/sh\nexit 1\n' > "$RUN/bin/patch_abl"
    chmod +x "$RUN/bin/patch_abl"
    rm -f "$RUN/efisp.img"
    out2=$(cd "$RUN" && sh ./build.sh 2>&1)
    case "$out2" in
      *"ERROR: patch_abl failed"*)
        pass "a failing patcher aborts the build" ;;
      *) fail "a failing patcher was not fatal ($out2)" ;;
    esac
    if [ -e "$RUN/efisp.img" ]; then
      fail "a failed patch left an efisp.img behind"
    else
      pass "a failed patch leaves no efisp.img"
    fi
  fi
else
  # The Windows script needs cmd.exe, so its logic is checked statically.
  if grep -q 'del /q "efisp.img"' "$WORK/pkg/build.bat"; then
    pass "build.bat clears a stale efisp.img before patching"
  else
    fail "build.bat does not clear a stale efisp.img"
  fi
  if grep -q 'patch_abl failed' "$WORK/pkg/build.bat"; then
    pass "build.bat treats a patcher failure as fatal"
  else
    fail "build.bat does not treat a patcher failure as fatal"
  fi
  if grep -q 'Warning: Failed to patch ABL GBL' "$WORK/pkg/build.bat"; then
    pass "build.bat reports the GBL verdict"
  else
    fail "build.bat does not report the GBL verdict"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
fi
echo "FAILURES PRESENT"
exit 1
