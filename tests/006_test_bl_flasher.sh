# Test the real build_patched_efi()/clean_workdir() helpers from bl_flasher.sh.
# These cover the extract+patch pipeline and the stale-output cleanup that the
# WebUI-driven flash flow depends on. They run off-device because the helpers
# only touch extractfv/patch_abl and the module tmp directory.
cd "$(dirname "$0")"
MODULE=../magisk_module
ABLREPO=$MODULE/ablrepo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "Test passed: $1"; }
fail() { echo "Test failed: $1"; FAIL=1; }

# ── Build the extractfv/patch_abl tools the helper invokes. ──
gcc -O2 -o "$WORK/extractfv" ../tools/extractfv.c -llzma 2>/dev/null
gcc -O2 -o "$WORK/patch_abl" ../tools/patch_abl.c 2>/dev/null
if [ ! -x "$WORK/extractfv" ] || [ ! -x "$WORK/patch_abl" ]; then
  fail "could not build extractfv/patch_abl"
  exit 1
fi

# ── Extract the shipped helpers so the tested logic is the shipped logic. ──
# timestamp() is a one-liner; the rest span multiple lines and close with a
# lone "}" at column 0.
grep '^timestamp() {' "$MODULE/bin/bl_flasher.sh" > "$WORK/helpers.sh"
for fn in ensure_runtime write_log clean_workdir build_patched_efi; do
  sed -n "/^$fn() {/,/^}/p" "$MODULE/bin/bl_flasher.sh" >> "$WORK/helpers.sh"
done
if [ "$(grep -c '^[a-z_]*() {' "$WORK/helpers.sh")" -ne 5 ]; then
  fail "could not extract the bl_flasher.sh helpers"
  exit 1
fi

# MODDIR points at a throwaway copy so bl_flasher's $MODDIR/bin/* resolves to the
# tools we just built, mirroring the on-device layout.
mkdir -p "$WORK/mod/bin"
cp "$WORK/extractfv" "$WORK/mod/bin/extractfv"
cp "$WORK/patch_abl" "$WORK/mod/bin/patch_abl"
export MODDIR="$WORK/mod"
export RUNTIME_DIR="$WORK/mod/tmp"
export LOG_FILE="$RUNTIME_DIR/flash.log"
export STATE_FILE="$RUNTIME_DIR/state"
export MESSAGE_FILE="$RUNTIME_DIR/message"
export UPDATED_FILE="$RUNTIME_DIR/updated"
export TASK_FILE="$RUNTIME_DIR/task_id"
export PID_FILE="$RUNTIME_DIR/flash.pid"
export LOCK_DIR="$RUNTIME_DIR/flash.lock"
export BY_NAME_DIR="/dev/block/by-name"
mkdir -p "$RUNTIME_DIR"

run_build() { sh -c '. "$1"; build_patched_efi "$2"' _ "$WORK/helpers.sh" "$1"; }

echo "--- build_patched_efi: success path ---"
if run_build "$ABLREPO/myron/abl.img"; then
  if [ -s "$RUNTIME_DIR/patched.efi" ] && [ -s "$RUNTIME_DIR/LinuxLoader.efi" ]; then
    pass "build_patched_efi produces patched.efi from a real ABL"
  else
    fail "build_patched_efi returned 0 but produced no output"
  fi
else
  fail "build_patched_efi failed on a valid ABL image"
fi

echo "--- build_patched_efi: missing input must fail, not report success ---"
if run_build "$WORK/does_not_exist.img"; then
  fail "build_patched_efi accepted a missing input image"
else
  if [ -e "$RUNTIME_DIR/patched.efi" ]; then
    fail "build_patched_efi left a patched.efi behind after failing"
  else
    pass "missing input fails and leaves no patched.efi"
  fi
fi

echo "--- build_patched_efi: clears a stale output from a previous run ---"
printf 'this is not an abl image\n' > "$WORK/not_an_abl.bin"
printf 'stale\n' > "$RUNTIME_DIR/patched.efi"
if run_build "$WORK/not_an_abl.bin" 2>/dev/null; then
  fail "build_patched_efi accepted a non-ABL input"
else
  if [ -e "$RUNTIME_DIR/patched.efi" ]; then
    fail "stale patched.efi survived a failed run (could be mistaken for success)"
  else
    pass "stale patched.efi removed before a failed run"
  fi
fi

echo "--- clean_workdir: keeps control files, removes work artifacts ---"
: > "$RUNTIME_DIR/flash.log"
printf 'idle\n' > "$RUNTIME_DIR/state"
printf 'hello\n' > "$RUNTIME_DIR/message"
printf 'stamp\n' > "$RUNTIME_DIR/updated"
printf '123\n' > "$RUNTIME_DIR/flash.pid"
printf 'leftover\n' > "$RUNTIME_DIR/patched.efi"
printf 'leftover\n' > "$RUNTIME_DIR/LinuxLoader.efi"
printf 'leftover\n' > "$RUNTIME_DIR/repo_abl.img"
mkdir -p "$RUNTIME_DIR/flash.lock"
sh -c '. "$1"; clean_workdir' _ "$WORK/helpers.sh"
kept=1
# flash.lock is held for the whole run, so it must survive clean_workdir.
for f in flash.log state message updated flash.pid flash.lock; do
  [ -e "$RUNTIME_DIR/$f" ] || { kept=0; fail "clean_workdir removed control file $f"; }
done
[ "$kept" = "1" ] && pass "clean_workdir keeps state/log/pid/lock files"
for f in patched.efi LinuxLoader.efi repo_abl.img; do
  if [ -e "$RUNTIME_DIR/$f" ]; then
    fail "clean_workdir left work artifact $f behind"
  else
    pass "clean_workdir removed $f"
  fi
done

echo "--- print_status: reports RUNNING/STALE from the live process ---"
# Reuse the helpers already extracted above and add the status functions
# (they only read files and call getprop/kill).
cp "$WORK/helpers.sh" "$WORK/statusfull.sh"
grep '^emit() {' "$MODULE/bin/bl_flasher.sh" >> "$WORK/statusfull.sh"
for fn in current_pid detect_current_slot other_slot print_status; do
  sed -n "/^$fn() {/,/^}/p" "$MODULE/bin/bl_flasher.sh" >> "$WORK/statusfull.sh"
done

# A getprop stub that reports slot _a so a target slot can be derived.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/getprop" <<'STUB'
#!/bin/sh
case "$1" in
  ro.boot.slot_suffix) printf '%s\n' '_a' ;;
  ro.product.name) printf '%s\n' 'myron' ;;
  ro.product.model) printf '%s\n' 'Test' ;;
  *) printf '%s\n' '' ;;
esac
STUB
chmod +x "$WORK/bin/getprop"
export PATH="$WORK/bin:$PATH"

status_field() { # status_field <name>
  printf '%s' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p"
}
run_status() { sh -c '. "$1"; print_status' _ "$WORK/statusfull.sh"; }

# idle: nothing running, no stale flag.
printf '%s\n' 'idle' > "$RUNTIME_DIR/state"
rm -f "$RUNTIME_DIR/flash.pid"
out=$(run_status)
[ "$(status_field "$out" RUNNING)" = "0" ] && [ "$(status_field "$out" STALE)" = "0" ] \
  && pass "idle state reports RUNNING=0 STALE=0" \
  || fail "idle state misreported ($out)"

# interrupted: a "running" record with no live process must be flagged stale.
printf '%s\n' 'running' > "$RUNTIME_DIR/state"
printf '%s\n' '999999' > "$RUNTIME_DIR/flash.pid"
out=$(run_status)
[ "$(status_field "$out" RUNNING)" = "0" ] && [ "$(status_field "$out" STALE)" = "1" ] \
  && pass "dead pid with running state reports STALE=1" \
  || fail "stale run misreported ($out)"

# live: a real running process must be reported as running, not stale.
sleep 30 &
live=$!
printf '%s\n' "$live" > "$RUNTIME_DIR/flash.pid"
out=$(run_status)
[ "$(status_field "$out" RUNNING)" = "1" ] && [ "$(status_field "$out" STALE)" = "0" ] \
  && pass "live pid reports RUNNING=1 STALE=0" \
  || fail "live run misreported ($out)"
kill "$live" 2>/dev/null

# the device/module metadata must be present for the panel.
printf '%s\n' 'id=zeroedx_fake_bl_efisp' 'name=假回锁' 'version=7.2' > "$MODULE/module.prop.statusbak"
printf '%s\n' 'id=zeroedx_fake_bl_efisp' 'name=假回锁' 'version=7.2' > "$WORK/mod/module.prop"
out=$(run_status)
[ "$(status_field "$out" DEVICE)" = "myron" ] \
  && [ "$(status_field "$out" MODULE_VERSION)" = "7.2" ] \
  && pass "status exposes DEVICE and MODULE_VERSION" \
  || fail "status missing device/module metadata ($out)"
rm -f "$MODULE/module.prop.statusbak"

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
