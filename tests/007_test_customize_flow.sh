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
exit 0
EOF
cat > "$WORK/bin/dd" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

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
    sh "$WORK/run.sh" 2>&1
}

echo "--- first install (Vol+) with a vulnerable ABL reaches the format step ---"
out=$(EXTRACTFV_MODE=ok PATCH_ABL_MODE=vuln run_install up)
case "$out" in
  *"安装完成，请重启到recovery进行格式化"*) pass "up/vuln: installer reaches format step" ;;
  *) fail "up/vuln: did not reach format step ($(printf '%s' "$out" | tail -n2 | tr '\n' ' '))" ;;
esac

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
out=$(run_install down)
case "$out" in
  *"安装完成，请重启系统即可"*) pass "down: OTA path completes" ;;
  *) fail "down: OTA path did not complete ($out)" ;;
esac

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
