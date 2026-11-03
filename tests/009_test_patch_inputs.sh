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
# Same image with the "unlocked"/"locked" pair the ADRL pass needs removed: every
# other patch still applies, so this is the expected partial result.
GOLDEN_NOADRL_MD5=77ee97bcec65ddc06c682fe3051537e5

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
  # $1 = binary, $2 = input, $3 = output, $4 = log file, $5 = rc file
  rm -f "$3"
  "$1" "$2" "$3" > "$4" 2>&1
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
  run_case "$bin" "$TMP/normal.efi" "$TMP/out_normal.efi" "$TMP/normal.log" "$TMP/normal.rc"
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
  if grep -q "ADRL triple not found" "$TMP/normal.log"; then
    fail "$label: the supported image reports a missing ADRL triple"
  else
    pass "$label: the supported image patches the ADRL triple"
  fi
  if no_diagnostics "$TMP/normal.log"; then
    pass "$label: the supported image produces no sanitizer diagnostics"
  else
    fail "$label: the supported image produced sanitizer diagnostics"
  fi

  # --- ADRL-less variant: the "unlocked"->"locked" patch cannot be applied.
  # The remaining patches do not depend on it, so the tool keeps exit 0 and
  # writes a partially patched image; that is the upstream contract (a patch
  # that does not apply is a warning, not an error). The assertions pin that
  # outcome exactly -- status, size, partial-result checksum and the log line
  # the installer and the flasher show the user -- so it cannot drift silently.
  run_case "$bin" "$TMP/noadrl.efi" "$TMP/out_noadrl.efi" "$TMP/noadrl.log" "$TMP/noadrl.rc"
  rc=$(cat "$TMP/noadrl.rc")
  if [ "$rc" -lt 128 ]; then
    pass "$label: an image without the ADRL marker does not crash"
  else
    fail "$label: an image without the ADRL marker died from signal $((rc - 128))"
  fi
  if [ "$rc" -eq 0 ]; then
    pass "$label: an image without the ADRL marker completes with exit 0"
  else
    fail "$label: an image without the ADRL marker exited with $rc"
  fi
  if [ -f "$TMP/out_noadrl.efi" ] && [ "$(stat -c%s "$TMP/out_noadrl.efi")" = "$(stat -c%s "$TMP/noadrl.efi")" ]; then
    pass "$label: the ADRL-less image keeps the input size"
  else
    fail "$label: the ADRL-less image produced a missing or truncated output"
  fi
  if [ "$(md5sum "$TMP/out_noadrl.efi" 2>/dev/null | cut -d' ' -f1)" = "$GOLDEN_NOADRL_MD5" ]; then
    pass "$label: the ADRL-less image gets every patch except the ADRL one"
  else
    fail "$label: the ADRL-less output changed (expected $GOLDEN_NOADRL_MD5, got $(md5sum "$TMP/out_noadrl.efi" 2>/dev/null | cut -d' ' -f1))"
  fi
  if cmp -s "$TMP/out_noadrl.efi" "$TMP/out_normal.efi"; then
    fail "$label: skipping the ADRL pass did not change the output"
  else
    pass "$label: skipping the ADRL pass changes the output as expected"
  fi
  if grep -q "ADRL triple not found, skipping the unlocked->locked patch" "$TMP/noadrl.log"; then
    pass "$label: the log names the patch that was skipped"
  else
    fail "$label: the log does not say which patch was skipped"
  fi
  if grep -q "Error: ADRL verification failed" "$TMP/noadrl.log"; then
    fail "$label: a run that succeeded still reports an ADRL verification error"
  else
    pass "$label: a skipped ADRL patch reports no verification error"
  fi
  if no_diagnostics "$TMP/noadrl.log"; then
    pass "$label: the ADRL-less variant produces no sanitizer diagnostics"
  else
    fail "$label: the ADRL-less variant produced sanitizer diagnostics"
  fi

  # --- a failed run must not leave anything at the output path that a caller
  # could mistake for the result of this run. The shipped callers delete the
  # file first, and the patcher itself never truncates one it did not produce.
  printf 'output from an earlier run' > "$TMP/stale.efi"
  stale_md5=$(md5sum "$TMP/stale.efi" | cut -d' ' -f1)
  "$bin" "$TMP/empty.bin" "$TMP/stale.efi" > "$TMP/stale.log" 2>&1
  echo "$?" > "$TMP/stale.rc"
  rc=$(cat "$TMP/stale.rc")
  if [ "$rc" -ne 0 ]; then
    if [ ! -e "$TMP/stale.efi" ] || [ "$(md5sum "$TMP/stale.efi" 2>/dev/null | cut -d' ' -f1)" = "$stale_md5" ]; then
      pass "$label: a failed run never leaves a partial output file"
    else
      fail "$label: a failed run truncated the previous output file"
    fi
  else
    fail "$label: an empty input was accepted over a stale output file"
  fi

  # --- inputs that must be rejected without crashing
  for case in empty trunc random; do
    case "$case" in
      empty)  input="$TMP/empty.bin" ;;
      trunc)  input="$TMP/trunc.efi" ;;
      random) input="$TMP/random.bin" ;;
    esac
    run_case "$bin" "$input" "$TMP/out_$case.efi" "$TMP/$case.log" "$TMP/$case.rc"
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
    if no_diagnostics "$TMP/$case.log"; then
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
