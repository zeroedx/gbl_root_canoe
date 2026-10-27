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

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
