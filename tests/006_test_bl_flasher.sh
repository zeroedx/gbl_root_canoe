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
for fn in ensure_runtime write_log clean_workdir build_patched_efi \
          write_backup_meta backup_partition verify_written_range flash_and_verify \
          classify_gbl detect_gbl_vulnerability; do
  sed -n "/^$fn() {/,/^}/p" "$MODULE/bin/bl_flasher.sh" >> "$WORK/helpers.sh"
done
if [ "$(grep -c '^[a-z_]*() {' "$WORK/helpers.sh")" -ne 11 ]; then
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
export GBL_BACKUP_DIR="$WORK/backup"
export BACKUP_ROOT="$WORK/backup"
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

# the device/module metadata must be present for the panel. module.prop is
# written inside the throwaway $WORK tree, so the repository is never touched.
printf '%s\n' 'id=zeroedx_fake_bl_efisp' 'name=假回锁' 'version=7.4' > "$WORK/mod/module.prop"
out=$(run_status)
[ "$(status_field "$out" DEVICE)" = "myron" ] \
  && [ "$(status_field "$out" MODULE_VERSION)" = "7.4" ] \
  && pass "status exposes DEVICE and MODULE_VERSION" \
  || fail "status missing device/module metadata ($out)"

# ── GBL state classification (Vulnerable / NotVulnerable / Unknown / Error) ──
echo "--- classify_gbl: the four states ---"
run_classify() { sh -c '. "$1"; classify_gbl "$2"' _ "$WORK/helpers.sh" "$1"; }

# A real bundled ABL carries the GBL marker, so the patcher rewrites it.
out=$(run_classify "$ABLREPO/myron/abl.img")
[ "$out" = "Vulnerable" ] && pass "real firmware is classified Vulnerable" \
  || fail "real firmware misclassified ($out)"

# Remove the UTF-16 "efisp" marker: the patcher then reports the GBL warning and
# the firmware must be classified NotVulnerable.
cat > "$WORK/strip_efisp.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 3) return 1;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(n > 0 ? n : 1);
    if (!b || fread(b, 1, n, f) != (size_t)n) { fclose(f); return 1; }
    fclose(f);
    const unsigned char pat[] = {'e',0,'f',0,'i',0,'s',0,'p',0};
    for (long i = 0; i + (long)sizeof(pat) <= n; i++)
        if (memcmp(b + i, pat, sizeof(pat)) == 0)
            for (size_t j = 0; j < sizeof(pat); j++) b[i + j] = (j % 2 == 0) ? 'x' : 0;
    FILE *o = fopen(argv[2], "wb");
    if (!o) { free(b); return 1; }
    int ok = (fwrite(b, 1, n, o) == (size_t)n);
    fclose(o); free(b);
    return ok ? 0 : 1;
}
EOF
if gcc -O2 -o "$WORK/strip_efisp" "$WORK/strip_efisp.c" 2>/dev/null \
   && "$WORK/mod/bin/extractfv" "$ABLREPO/myron/abl.img" -o "$WORK/nv" >/dev/null 2>&1 \
   && "$WORK/strip_efisp" "$WORK/nv/LinuxLoader.efi" "$WORK/nv/stripped.efi" >/dev/null 2>&1; then
  out=$(run_classify "$WORK/nv/stripped.efi")
  [ "$out" = "NotVulnerable" ] && pass "firmware without the marker is NotVulnerable" \
    || fail "marker-less firmware misclassified ($out)"
else
  fail "could not build the NotVulnerable fixture"
fi

# A missing partition and a non-ABL file are Error, never a verdict.
out=$(run_classify "$WORK/does_not_exist.img")
[ "$out" = "Error" ] && pass "a missing partition is Error" \
  || fail "missing partition misclassified ($out)"
printf 'this is not an abl image\n' > "$WORK/notabl.bin"
out=$(run_classify "$WORK/notabl.bin")
[ "$out" = "Error" ] && pass "a non-ABL input is Error" \
  || fail "non-ABL input misclassified ($out)"

# A patcher that reports success but writes identical bytes must yield Unknown,
# never Vulnerable.
mkdir -p "$WORK/mod_unknown/bin"
cp "$WORK/mod/bin/extractfv" "$WORK/mod_unknown/bin/extractfv"
cat > "$WORK/mod_unknown/bin/patch_abl" <<'EOF'
#!/bin/sh
printf 'Saved to %s\n' "$2"
cat "$1" > "$2"
EOF
chmod +x "$WORK/mod_unknown/bin/patch_abl"
out=$(MODDIR="$WORK/mod_unknown" run_classify "$ABLREPO/myron/abl.img")
[ "$out" = "Unknown" ] && pass "an unchanged patch result is Unknown" \
  || fail "unchanged patch result misclassified ($out)"

# A patcher that fails to run is Error, not Vulnerable.
mkdir -p "$WORK/mod_fail/bin"
cp "$WORK/mod/bin/extractfv" "$WORK/mod_fail/bin/extractfv"
cat > "$WORK/mod_fail/bin/patch_abl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK/mod_fail/bin/patch_abl"
out=$(MODDIR="$WORK/mod_fail" run_classify "$ABLREPO/myron/abl.img")
[ "$out" = "Error" ] && pass "a failed patcher is Error" \
  || fail "failed patcher misclassified ($out)"

# detect_gbl_vulnerability maps the states onto its exit codes.
detect_code() { sh -c '. "$1"; detect_gbl_vulnerability "$2"; echo "rc=$?"' _ "$WORK/helpers.sh" "$1"; }
case "$(detect_code "$ABLREPO/myron/abl.img")" in
  *rc=0*) pass "detect_gbl_vulnerability returns 0 for Vulnerable" ;;
  *) fail "detect_gbl_vulnerability wrong code for Vulnerable ($(detect_code "$ABLREPO/myron/abl.img"))" ;;
esac
case "$(detect_code "$WORK/does_not_exist.img")" in
  *rc=1*) pass "detect_gbl_vulnerability returns 1 for Error" ;;
  *) fail "detect_gbl_vulnerability wrong code for Error" ;;
esac

# ── backup_partition: success, hash sidecar, and failure ──
echo "--- backup_partition ---"
mkdir -p "$WORK/dev/block/by-name"
printf 'partition-payload\n' > "$WORK/dev/block/by-name/efisp"
run_backup() { sh -c '. "$1"; backup_partition "$2" "$3" "$4"' _ "$WORK/helpers.sh" "$1" "$2" "$3"; }
if run_backup "$WORK/dev/block/by-name/efisp" efisp _a; then
  bk=$(ls "$WORK/backup"/efisp_a*.img 2>/dev/null | head -n 1)
  if [ -n "$bk" ] && [ "$(cat "$bk")" = "partition-payload" ] \
     && [ "$(sed -n 's/^sha256=//p' "$bk.meta")" = "$(sha256sum "$bk" | cut -d' ' -f1)" ]; then
    pass "backup copies the partition and records a matching sha256"
  else
    fail "backup image or metadata is wrong"
  fi
  # A second backup must add a file, never overwrite the first.
  run_backup "$WORK/dev/block/by-name/efisp" efisp _a >/dev/null 2>&1
  n=$(ls "$WORK/backup"/efisp_a*.img 2>/dev/null | wc -l)
  [ "$n" -ge 2 ] && pass "backups accumulate ($n kept) rather than overwrite" \
    || fail "second backup did not add a new file (kept $n)"
else
  fail "backup_partition failed on a readable partition"
fi
if run_backup "$WORK/does_not_exist" efisp _a; then
  fail "backup_partition accepted a missing partition"
else
  pass "backup_partition rejects a missing partition"
fi

# ── verify_written_range / flash_and_verify ──
echo "--- read-back verification ---"
run_verify() { sh -c '. "$1"; verify_written_range "$2" "$3" "$4"' _ "$WORK/helpers.sh" "$1" "$2" "$3"; }
printf 'exact-content\n' > "$WORK/src.bin"
cp "$WORK/src.bin" "$WORK/dst.bin"
if run_verify "$(wc -c < "$WORK/src.bin")" "$WORK/dst.bin" "$WORK/src.bin"; then
  pass "verify_written_range accepts an identical range"
else
  fail "verify_written_range rejected an identical range"
fi
printf 'different-content-here\n' > "$WORK/dst2.bin"
if run_verify "$(wc -c < "$WORK/src.bin")" "$WORK/dst2.bin" "$WORK/src.bin"; then
  fail "verify_written_range accepted a mismatching range"
else
  pass "verify_written_range rejects a mismatching range"
fi
# A short device read must fail rather than pass on a prefix.
head -c 5 "$WORK/src.bin" > "$WORK/dst3.bin"
if run_verify "$(wc -c < "$WORK/src.bin")" "$WORK/dst3.bin" "$WORK/src.bin"; then
  fail "verify_written_range accepted a short read"
else
  pass "verify_written_range rejects a short read"
fi

run_flash() { sh -c '. "$1"; flash_and_verify "$2" "$3"' _ "$WORK/helpers.sh" "$1" "$2"; }
cp "$WORK/src.bin" "$WORK/flashdst.bin"
if run_flash "$WORK/src.bin" "$WORK/flashdst.bin" && [ "$(cat "$WORK/flashdst.bin")" = "exact-content" ]; then
  pass "flash_and_verify writes and confirms the content"
else
  fail "flash_and_verify did not write/confirm"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
