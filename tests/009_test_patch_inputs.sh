#!/bin/sh
# Regression tests for patch_abl on normal and abnormal input.
#
# The tool runs as root on the device and its output is written to a boot-critical
# partition, so an input it cannot handle must fail with an ordinary exit status
# instead of crashing, and the supported image must keep producing exactly the
# same bytes as before.
#
# Set SAN=address, SAN=undefined or SAN=address,undefined to build the tool with
# sanitizers and rerun every case. The sanitizer build is checked to actually be
# instrumented, so a missing runtime fails the test instead of passing silently.

cd "$(dirname "$0")" || exit 1

SRC=../tools/patch_abl.c
EXTRACT_SRC=../tools/extractfv.c
GOLDEN_MD5=278654de4d7ab660866f2050c8851ee8

PASS=0
FAIL=0
pass() { echo "Test passed: $*"; PASS=$((PASS + 1)); }
fail() { echo "Test failed: $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d) || { echo "Test failed: cannot create a scratch directory"; exit 1; }
# shellcheck disable=SC2317  # invoked through the trap below
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM HUP

# A sanitizer report is a failure in every case, sanitized build or not.
no_diagnostics() {
  grep -qE 'AddressSanitizer|LeakSanitizer|runtime error|SUMMARY:' "$1" 2>/dev/null && return 1
  return 0
}

run_case() {
  # $1 = binary, $2 = input, $3 = output, $4 = stderr file, $5 = rc file
  rm -f "$3"
  "$1" "$2" "$3" > /dev/null 2> "$4"
  echo "$?" > "$5"
}

# ---------------------------------------------------------------- build tools
if ! command -v gcc > /dev/null 2>&1; then
  echo "Test failed: gcc is required to build the patcher"
  exit 1
fi

gcc -O2 -o "$TMP/extractfv" "$EXTRACT_SRC" -llzma 2> "$TMP/extract_build.log" || {
  echo "Test failed: cannot build extractfv"
  cat "$TMP/extract_build.log"
  exit 1
}
"$TMP/extractfv" 001_myron_abl.elf -o "$TMP" > /dev/null 2>&1 || {
  echo "Test failed: cannot extract the test ABL"
  exit 1
}
cp "$TMP/LinuxLoader.efi" "$TMP/normal.efi" || exit 1

# Fixtures. The unsupported-variant image only loses the "unlocked"/"locked"
# pair the ADRL pass looks for, so the rest of the loader still patches normally.
LC_ALL=C sed -e 's/unlocked/xxxxxxxx/g' -e 's/locked/yyyyyy/g' \
  "$TMP/normal.efi" > "$TMP/noadrl.efi" 2>/dev/null
: > "$TMP/empty.bin"
head -c 512 "$TMP/normal.efi" > "$TMP/trunc.efi"
# Arbitrary bytes, reproducible enough for the purpose: only the failure
# behaviour is asserted, never the content.
awk 'BEGIN{srand(1337); for(i=0;i<4096;i++){r=int(rand()*255)+1; printf "%c", r}}' \
  > "$TMP/random.bin" 2>/dev/null

for f in noadrl.efi empty.bin trunc.efi random.bin; do
  [ -s "$TMP/$f" ] || [ "$f" = "empty.bin" ] || { echo "Test failed: fixture $f was not created"; exit 1; }
done
[ "$(stat -c%s "$TMP/noadrl.efi" 2>/dev/null || echo 0)" = "$(stat -c%s "$TMP/normal.efi")" ] || {
  echo "Test failed: the unsupported-variant fixture changed the image size"
  exit 1
}

# ------------------------------------------------------------------ run a build
# $1 = label, $2 = 1 when this build must be instrumented, $3... = compiler flags
check_build() {
  label=$1
  expect_san=$2
  shift 2
  bin="$TMP/patch_abl_$label"
  gcc "$@" -o "$bin" "$SRC" 2> "$TMP/${label}_build.log" || {
    fail "$label build"
    cat "$TMP/${label}_build.log"
    return 1
  }

  if [ "$expect_san" = "1" ]; then
    if ldd "$bin" 2>/dev/null | grep -qE 'libasan|libubsan'; then
      pass "$label build is linked against the sanitizer runtime"
    else
      fail "$label build is not linked against the sanitizer runtime"
      return 1
    fi
  fi

  # --- normal image: must be byte-identical to the reference output
  run_case "$bin" "$TMP/normal.efi" "$TMP/out_normal.efi" "$TMP/normal.err" "$TMP/normal.rc"
  rc=$(cat "$TMP/normal.rc")
  if [ "$rc" -eq 0 ]; then
    pass "$label: the supported image patches successfully"
  else
    fail "$label: the supported image exited with $rc"
  fi
  if [ -f "$TMP/out_normal.efi" ] && [ "$(stat -c%s "$TMP/out_normal.efi")" = "$(stat -c%s "$TMP/normal.efi")" ]; then
    pass "$label: the patched image keeps the input size"
  else
    fail "$label: the patched image is missing or has the wrong size"
  fi
  if [ "$(md5sum "$TMP/out_normal.efi" 2>/dev/null | cut -d' ' -f1)" = "$GOLDEN_MD5" ]; then
    pass "$label: the patched image matches the reference checksum"
  else
    fail "$label: the patched image changed (expected $GOLDEN_MD5, got $(md5sum "$TMP/out_normal.efi" 2>/dev/null | cut -d' ' -f1))"
  fi
  if no_diagnostics "$TMP/normal.err"; then
    pass "$label: the supported image produces no sanitizer diagnostics"
  else
    fail "$label: the supported image produced sanitizer diagnostics"
  fi

  # --- unsupported variant: the ADRL pass is skipped, the run still succeeds
  run_case "$bin" "$TMP/noadrl.efi" "$TMP/out_noadrl.efi" "$TMP/noadrl.err" "$TMP/noadrl.rc"
  rc=$(cat "$TMP/noadrl.rc")
  if [ "$rc" -lt 128 ]; then
    pass "$label: an image without the ADRL marker does not crash"
  else
    fail "$label: an image without the ADRL marker died from signal $((rc - 128))"
  fi
  if [ "$rc" -eq 0 ]; then
    pass "$label: an image without the ADRL marker is patched anyway"
  else
    fail "$label: an image without the ADRL marker failed with $rc"
  fi
  if [ -f "$TMP/out_noadrl.efi" ] && [ "$(stat -c%s "$TMP/out_noadrl.efi")" = "$(stat -c%s "$TMP/noadrl.efi")" ]; then
    pass "$label: the unsupported variant keeps the input size"
  else
    fail "$label: the unsupported variant produced a missing or truncated output"
  fi
  if cmp -s "$TMP/out_noadrl.efi" "$TMP/out_normal.efi"; then
    fail "$label: skipping the ADRL pass did not change the output"
  else
    pass "$label: skipping the ADRL pass changes the output as expected"
  fi
  if no_diagnostics "$TMP/noadrl.err"; then
    pass "$label: the unsupported variant produces no sanitizer diagnostics"
  else
    fail "$label: the unsupported variant produced sanitizer diagnostics"
  fi

  # --- inputs that must be rejected without crashing
  for case in empty trunc random; do
    case "$case" in
      empty)  input="$TMP/empty.bin" ;;
      trunc)  input="$TMP/trunc.efi" ;;
      random) input="$TMP/random.bin" ;;
    esac
    run_case "$bin" "$input" "$TMP/out_$case.efi" "$TMP/$case.err" "$TMP/$case.rc"
    rc=$(cat "$TMP/$case.rc")
    if [ "$rc" -lt 128 ]; then
      pass "$label: $case input does not crash"
    else
      fail "$label: $case input died from signal $((rc - 128))"
    fi
    if [ "$rc" -ne 0 ]; then
      pass "$label: $case input is rejected with a non-zero exit status"
    else
      fail "$label: $case input was accepted"
    fi
    if [ ! -f "$TMP/out_$case.efi" ]; then
      pass "$label: $case input leaves no output behind"
    else
      fail "$label: $case input produced an output file"
    fi
    if no_diagnostics "$TMP/$case.err"; then
      pass "$label: $case input produces no sanitizer diagnostics"
    else
      fail "$label: $case input produced sanitizer diagnostics"
    fi
  done
}

check_build plain 0 -O2 -Wall -Wextra

if [ -n "${SAN:-}" ]; then
  check_build san 1 -g -O1 "-fsanitize=$SAN" -fno-sanitize-recover=all
  if [ "$FAIL" -eq 0 ]; then
    echo "Sanitizer build ($SAN) reported no problems."
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All patch input tests passed ($PASS checks)."
  exit 0
fi
echo "$FAIL of $((PASS + FAIL)) patch input checks failed."
exit 1
