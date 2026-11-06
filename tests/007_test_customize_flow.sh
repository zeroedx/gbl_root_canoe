# Simulate the real customize.sh installer flow off-device to confirm the
# refactored key handling and the added extract/patch error checks behave as
# intended. Magisk builtins (ui_print/abort/set_perm*) are stubbed and the two
# helper binaries are replaced with controllable fakes.
cd "$(dirname "$0")"
MODULE=../magisk_module
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "Test passed: $1"; }
fail() { echo "Test failed: $1"; FAIL=1; }

# ── Fake system tools on PATH. ──
mkdir -p "$WORK/bin"
cat > "$WORK/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.boot.slot_suffix) printf '%s\n' '_a' ;;
  ro.product.name) printf '%s\n' "${STUB_PRODUCT:-myron}" ;;
  *) printf '%s\n' "" ;;
esac
EOF
# Pops the next queued key each time it is called, so a run can drive the
# volume-key prompts deterministically.
cat > "$WORK/bin/getevent" <<'EOF'
#!/bin/sh
q="${GETEVENT_QUEUE:-/dev/null}"
pos="${GETEVENT_POS:-/dev/null}"
n=$(cat "$pos" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$pos"
line=$(sed -n "${n}p" "$q" 2>/dev/null)
case "$line" in
  up)   printf 'KEY_VOLUMEUP\n' ;;
  down) printf 'KEY_VOLUMEDOWN\n' ;;
  *)    : ;;
esac
EOF
cat > "$WORK/bin/blockdev" <<'EOF'
#!/bin/sh
case "$1" in
  --getsize64)
    if [ "${BD_MODE:-ok}" = "wrongsize" ]; then
      printf '%s\n' 999999
    else
      wc -c < "$2" 2>/dev/null | tr -d ' '
    fi ;;
  *) exit 0 ;;
esac
EOF
# Minimal dd: copy the input to the output, or to stdout when no of= is given.
# DD_MODE=fail makes every call fail; DD_MODE=corrupt corrupts writes to a block
# device (so a read-back mismatch can be exercised without disturbing the backup
# read); DD_MODE=short writes only half the input so a truncated backup can be
# exercised.
cat > "$WORK/bin/dd" <<'EOF'
#!/bin/sh
in=""; out=""
for a in "$@"; do
  case "$a" in
    if=*) in="${a#if=}" ;;
    of=*) out="${a#of=}" ;;
  esac
done
[ "${DD_MODE:-ok}" = "fail" ] && exit 1
if [ -n "$out" ]; then
  case "${DD_MODE:-ok}" in
    corrupt)
      case "$out" in
        */block/by-name/*) printf 'corrupted-block-device\n' > "$out"; exit 0 ;;
      esac
      cat "$in" > "$out"; exit 0 ;;
    short)
      n=$(wc -c < "$in"); head -c $((n / 2)) "$in" > "$out"; exit 0 ;;
    *) cat "$in" > "$out"; exit 0 ;;
  esac
fi
[ -n "$in" ] && cat "$in"
exit 0
EOF
cat > "$WORK/bin/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

# ── Block-device stand-ins. The installer reads and writes these through the dd
#    stub, so the real backup and read-back code paths are exercised. ──
mkdir -p "$WORK/dev/block/by-name"
printf 'original-efisp-content\n' > "$WORK/dev/block/by-name/efisp"
printf 'original-abl-a\n'         > "$WORK/dev/block/by-name/abl_a"
printf 'original-abl-b\n'         > "$WORK/dev/block/by-name/abl_b"
export GBL_BY_NAME_DIR="$WORK/dev/block/by-name"
export GBL_BACKUP_DIR="$WORK/backup"

# ── Fake module tree with controllable helper binaries. ──
mkdir -p "$WORK/mod/bin" "$WORK/mod/tmp" "$WORK/mod/ablrepo"
cat > "$WORK/mod/bin/extractfv" <<'EOF'
#!/bin/sh
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "${EXTRACTFV_MODE:-ok}" in
  fail)  exit 1 ;;
  empty) exit 0 ;;
  *)     printf 'loader' > "$dir/LinuxLoader.efi"; exit 0 ;;
esac
EOF
cat > "$WORK/mod/bin/patch_abl" <<'EOF'
#!/bin/sh
out="$2"
case "${PATCH_ABL_MODE:-vuln}" in
  fail)  printf 'Warning: Failed to patch ABL GBL\n'; exit 1 ;;
  empty) exit 0 ;;
  novuln) printf 'Warning: Failed to patch ABL GBL\n'; printf 'patched' > "$out" ;;
  *)     printf 'Saved to %s\n' "$out"; printf 'patched' > "$out" ;;
esac
EOF
chmod +x "$WORK/mod/bin/"*

# ── Harness: source the real customize.sh with stubbed Magisk builtins. ──
cat > "$WORK/run.sh" <<'EOF'
ui_print() { printf 'UI: %s\n' "$*"; }
abort() { printf 'ABORT: %s\n' "$*"; exit 1; }
set_perm() { :; }
set_perm_recursive() { :; }
export MODPATH="$WORK/mod"
. "$MODULE/customize.sh"
EOF

# run_install <keys...>  -> runs the installer, prints UI/ABORT lines
run_install() {
  keys="$*"
  : > "$WORK/keys"
  for k in $keys; do printf '%s\n' "$k" >> "$WORK/keys"; done
  rm -f "$WORK/pos"
  GETEVENT_QUEUE="$WORK/keys" GETEVENT_POS="$WORK/pos" \
    WORK="$WORK" MODULE="$MODULE" \
    EXTRACTFV_MODE="${EXTRACTFV_MODE:-ok}" PATCH_ABL_MODE="${PATCH_ABL_MODE:-vuln}" \
    DD_MODE="${DD_MODE:-ok}" BD_MODE="${BD_MODE:-ok}" STUB_PRODUCT="${STUB_PRODUCT:-myron}" \
    GBL_BY_NAME_DIR="${GBL_BY_NAME_DIR:-$WORK/dev/block/by-name}" \
    GBL_BACKUP_DIR="${GBL_BACKUP_DIR:-$WORK/backup}" \
    sh "$WORK/run.sh" 2>&1
}

# Reset the stand-in partitions and backups between cases.
reset_fixtures() {
  printf 'original-efisp-content\n' > "$WORK/dev/block/by-name/efisp"
  printf 'original-abl-a\n'         > "$WORK/dev/block/by-name/abl_a"
  printf 'original-abl-b\n'         > "$WORK/dev/block/by-name/abl_b"
  rm -rf "$WORK/backup"
}

echo "--- first install (Vol+) with a vulnerable ABL reaches the format step ---"
reset_fixtures
out=$(EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"安装完成，请重启到recovery进行格式化"*) pass "up/vuln: installer reaches format step" ;;
  *) fail "up/vuln: did not reach format step ($(printf '%s' "$out" | tail -n2 | tr '\n' ' '))" ;;
esac

echo "--- the efisp write is read back and verified ---"
# patched.efi holds the fake patcher's output ("patched"); the efisp stand-in must
# now contain exactly that, proving the read-back matched the written range.
if [ "$(cat "$WORK/dev/block/by-name/efisp" 2>/dev/null)" = "patched" ]; then
  pass "verified write leaves the patched bytes on efisp"
else
  fail "efisp does not hold the patched bytes ($(cat "$WORK/dev/block/by-name/efisp" 2>/dev/null))"
fi

echo "--- backups record model, slot, time and SHA-256 ---"
bk=$(ls "$WORK/backup"/efisp*.img 2>/dev/null | head -n 1)
if [ -n "$bk" ] && [ -f "$bk.meta" ] && [ -f "$bk.sha256" ]; then
  meta_sha=$(sed -n 's/^sha256=//p' "$bk.meta")
  real_sha=$(sha256sum "$bk" | cut -d' ' -f1)
  if [ -n "$meta_sha" ] && [ "$meta_sha" = "$real_sha" ] \
     && grep -q '^model=' "$bk.meta" && grep -q '^slot=' "$bk.meta" && grep -q '^created=' "$bk.meta"; then
    pass "backup records model/slot/time/sha256 and the hash matches"
  else
    fail "backup metadata is incomplete or the hash does not match"
  fi
  # The backup must hold the ORIGINAL partition content, not the flashed one.
  if [ "$(cat "$bk")" = "original-efisp-content" ]; then
    pass "backup preserves the original efisp content"
  else
    fail "backup does not hold the original content"
  fi
else
  fail "no efisp backup with metadata was produced"
fi
# The abl backup must also exist (backup happens before the downgrade/flash).
if ls "$WORK/backup"/abl_a*.img >/dev/null 2>&1; then
  pass "abl partition was backed up too"
else
  fail "abl partition was not backed up"
fi

echo "--- a failed backup aborts before any flash ---"
reset_fixtures
out=$(DD_MODE=fail EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: efisp backup failed"*) pass "backup failure aborts the install" ;;
  *) fail "backup failure was not fatal ($out)" ;;
esac
if [ "$(cat "$WORK/dev/block/by-name/efisp")" = "original-efisp-content" ]; then
  pass "aborted install left efisp untouched"
else
  fail "aborted install still modified efisp"
fi

echo "--- an uncreatable backup directory aborts before any flash ---"
reset_fixtures
: > "$WORK/blocker"
out=$(GBL_BACKUP_DIR="$WORK/blocker/sub" EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: efisp backup failed"*) pass "unwritable backup dir aborts the install" ;;
  *) fail "unwritable backup dir was not fatal ($out)" ;;
esac
rm -f "$WORK/blocker"

echo "--- a truncated backup aborts before any flash ---"
reset_fixtures
out=$(DD_MODE=short EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: efisp backup failed"*) pass "a short backup read aborts the install" ;;
  *) fail "a short backup read was not fatal ($out)" ;;
esac
if [ "$(cat "$WORK/dev/block/by-name/efisp")" = "original-efisp-content" ]; then
  pass "short backup read left efisp untouched"
else
  fail "short backup read still modified efisp"
fi

echo "--- a backup/source size mismatch aborts before any flash ---"
reset_fixtures
out=$(BD_MODE=wrongsize EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: efisp backup failed"*) pass "a backup size mismatch aborts the install" ;;
  *) fail "a backup size mismatch was not fatal ($out)" ;;
esac
if [ "$(cat "$WORK/dev/block/by-name/efisp")" = "original-efisp-content" ]; then
  pass "size mismatch left efisp untouched"
else
  fail "size mismatch still modified efisp"
fi

echo "--- a read-back mismatch aborts instead of reporting success ---"
reset_fixtures
out=$(DD_MODE=corrupt EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: flash failed"*) pass "read-back mismatch aborts the install" ;;
  *) fail "read-back mismatch was not detected ($out)" ;;
esac
case "$out" in
  *"安装完成，请重启到recovery进行格式化"*) fail "read-back mismatch still reported success" ;;
  *) pass "read-back mismatch never reports success" ;;
esac

echo "--- an unknown device is rejected before touching any partition ---"
reset_fixtures
out=$(STUB_PRODUCT=unknown_x99 EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: unsupported device"*) pass "unknown device aborts the install" ;;
  *) fail "unknown device was not rejected ($out)" ;;
esac
if [ "$(cat "$WORK/dev/block/by-name/efisp")" = "original-efisp-content" ] \
   && [ ! -d "$WORK/backup" ]; then
  pass "unknown device touched neither the partition nor backups"
else
  fail "unknown device had side effects"
fi

echo "--- extract failure aborts instead of proceeding ---"
out=$(EXTRACTFV_MODE=fail PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: extract failed"*) pass "extract failure aborts (exit checked)" ;;
  *) fail "extract failure not detected ($out)" ;;
esac

echo "--- empty extract output aborts instead of proceeding ---"
out=$(EXTRACTFV_MODE=empty PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"ABORT: extract produced no output"*) pass "empty extract output aborts (-s check)" ;;
  *) fail "empty extract output not detected ($out)" ;;
esac

echo "--- patch failure aborts instead of proceeding ---"
out=$(EXTRACTFV_MODE=ok PATCH_ABL_MODE=fail run_install up)
case "$out" in
  *"ABORT: patch failed"*) pass "patch failure aborts (exit checked)" ;;
  *) fail "patch failure not detected ($out)" ;;
esac

echo "--- patch producing no output aborts instead of proceeding ---"
out=$(EXTRACTFV_MODE=ok PATCH_ABL_MODE=empty run_install up)
case "$out" in
  *"ABORT: patch failed"*) pass "missing patched.efi aborts (-s check)" ;;
  *) fail "missing patched.efi not detected ($out)" ;;
esac

echo "--- no-GBL-vuln path offers downgrade and honours Vol- cancel ---"
out=$(EXTRACTFV_MODE=ok PATCH_ABL_MODE=novuln run_install up down)
case "$out" in
  *"ABORT: downgrade declined"*) pass "downgrade declined aborts cleanly" ;;
  *) fail "downgrade cancel not honoured ($out)" ;;
esac

echo "--- OTA update (Vol-) completes without touching partitions ---"
reset_fixtures
out=$(run_install down)
case "$out" in
  *"安装完成，请重启系统即可"*) pass "down: OTA path completes" ;;
  *) fail "down: OTA path did not complete ($out)" ;;
esac
if [ "$(cat "$WORK/dev/block/by-name/efisp")" = "original-efisp-content" ] \
   && [ ! -d "$WORK/backup" ]; then
  pass "down: OTA path wrote nothing and made no backup"
else
  fail "down: OTA path had side effects"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
