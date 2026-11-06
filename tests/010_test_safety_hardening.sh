#!/bin/sh
# v7.4 safety hardening: verify the efisp write failure aborts before the ABL
# slot is written, and unit-test the hardened backup / read-back helpers.
#
# The end-to-end section drives the real bin/bl_flasher.sh with a stubbed
# getprop/blockdev/sync and injectable dd, so the control flow under test is the
# shipped control flow. The unit section extracts the shipped helpers verbatim.
cd "$(dirname "$0")"
MODULE=../magisk_module
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "Test passed: $1"; }
fail() { echo "Test failed: $1"; FAIL=1; }

# ── stubs on PATH: getprop / blockdev / sync / dd ──
mkdir -p "$WORK/bin"
cat > "$WORK/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.boot.slot_suffix) printf '%s\n' "${STUB_SLOT:-_a}" ;;
  ro.product.name)     printf '%s\n' "${STUB_PRODUCT:-myron}" ;;
  *)                   printf '\n' ;;
esac
EOF
cat > "$WORK/bin/blockdev" <<'EOF'
#!/bin/sh
case "$1" in
  --getsize64) wc -c < "$2" 2>/dev/null | tr -d ' ' ;;
  *) exit 0 ;;
esac
EOF
cat > "$WORK/bin/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
# dd: real copy by default; injectable failures for the efisp device. The efisp
# device is recognised by its trailing path component so the stub does not need
# BY_NAME_DIR exported into its environment.
cat > "$WORK/bin/dd" <<'EOF'
#!/bin/sh
in=""; out=""; bs=""
for a in "$@"; do
  case "$a" in
    if=*) in="${a#if=}" ;;
    of=*) out="${a#of=}" ;;
    bs=*) bs="${a#bs=}" ;;
  esac
done
case "$out" in
  */efisp)
    if [ "${DD_FAIL_WRITE_EFISP:-0}" = "1" ]; then
      echo "dd: error writing '$out': Input/output error" >&2
      exit 1
    fi ;;
esac
case "$in" in
  */efisp)
    # Only the read-back uses bs=4096; the 4M backup read must stay intact.
    if [ "${DD_CORRUPT_READ_EFISP:-0}" = "1" ] && [ "$bs" = "4096" ]; then
      head -c 65536 /dev/zero | tr '\0' 'X' > "$out"
      exit 0
    fi ;;
esac
exec /usr/bin/dd "$@"
EOF
# dd variant that silently writes only half of the input (short read).
cat > "$WORK/bin/dd_short" <<'EOF'
#!/bin/sh
in=""; out=""
for a in "$@"; do
  case "$a" in
    if=*) in="${a#if=}" ;;
    of=*) out="${a#of=}" ;;
  esac
done
[ -n "$out" ] || { cat "$in"; exit 0; }
n=$(wc -c < "$in")
head -c $((n / 2)) "$in" > "$out"
exit 0
EOF
# blockdev that always reports a fixed (wrong) size.
cat > "$WORK/bin/blockdev_fixed" <<'EOF'
#!/bin/sh
case "$1" in
  --getsize64) printf '%s\n' "${FAKE_SRC_SIZE:-999999}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

# ── end-to-end: run_flash(update-efisp) ──
echo "--- run_flash: efisp failure must not touch the ABL target slot ---"

# The end-to-end run gets its own stub directory (getprop/dd/blockdev/sync) so
# the real getprop is never sourced and the unit section below is unaffected.
mkdir -p "$WORK/e2ebin"
cat > "$WORK/e2ebin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.boot.slot_suffix) printf '%s\n' "${STUB_SLOT:-_a}" ;;
  ro.product.name)     printf '%s\n' "${STUB_PRODUCT:-myron}" ;;
  *)                   printf '\n' ;;
esac
EOF
cp "$WORK/bin/dd" "$WORK/bin/blockdev" "$WORK/bin/sync" "$WORK/e2ebin/"
chmod +x "$WORK/e2ebin/"*

e2e_setup() { # e2e_setup <warn|nowarn>
  rm -rf "$WORK/e2e"; mkdir -p "$WORK/e2e/mod/bin" "$WORK/e2e/mod/tmp" \
    "$WORK/e2e/dev/block/by-name" "$WORK/e2e/backup"
  # The real shipped flasher runs, with only its tools stubbed.
  cp "$MODULE/bin/bl_flasher.sh" "$WORK/e2e/mod/bin/bl_flasher.sh"
  cat > "$WORK/e2e/mod/bin/extractfv" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
mkdir -p "$out"
printf 'LOADER\n' > "$out/LinuxLoader.efi"
exit 0
EOF
  # Select the patcher stub:
  #   warn      -> prints the GBL warning    => NotVulnerable
  #   nowarn    -> patches, no warning       => Vulnerable
  #   identical -> "success" but same bytes  => Unknown
  #   fail      -> non-zero exit             => Error
  case "$1" in
    fail)
      cat > "$WORK/e2e/mod/bin/patch_abl" <<'EOF'
#!/bin/sh
exit 1
EOF
      ;;
    identical)
      cat > "$WORK/e2e/mod/bin/patch_abl" <<'EOF'
#!/bin/sh
printf 'Saved to %s\n' "$2"
cat "$1" > "$2"
exit 0
EOF
      ;;
    nowarn)
      cat > "$WORK/e2e/mod/bin/patch_abl" <<'EOF'
#!/bin/sh
printf 'Saved to %s\n' "$2"
printf 'PATCHED\n' > "$2"
exit 0
EOF
      ;;
    *)
      cat > "$WORK/e2e/mod/bin/patch_abl" <<'EOF'
#!/bin/sh
printf 'Warning: Failed to patch ABL GBL\n'
printf 'Saved to %s\n' "$2"
printf 'PATCHED\n' > "$2"
exit 0
EOF
      ;;
  esac
  chmod +x "$WORK/e2e/mod/bin/"*
  printf 'ORIGINAL-ABL-A\n' > "$WORK/e2e/dev/block/by-name/abl_a"
  printf 'ORIGINAL-ABL-B\n' > "$WORK/e2e/dev/block/by-name/abl_b"
  printf 'ORIGINAL-EFISP\n' > "$WORK/e2e/dev/block/by-name/efisp"
}

e2e_run() { # e2e_run <flash-mode> [extra env as KEY=VAL ...]
  _mode="$1"; shift
  PATH="$WORK/e2ebin:$PATH" \
  MODDIR="$WORK/e2e/mod" \
  BY_NAME_DIR="$WORK/e2e/dev/block/by-name" \
  GBL_BY_NAME_DIR="$WORK/e2e/dev/block/by-name" \
  GBL_BACKUP_DIR="$WORK/e2e/backup" \
  STUB_SLOT=_a STUB_PRODUCT=myron \
  "$@" sh "$WORK/e2e/mod/bin/bl_flasher.sh" flash "$_mode"
}

state_of() { cat "$WORK/e2e/mod/tmp/state" 2>/dev/null; }

# Case 1: success path (warn stub => patch_efisp ret=0 => continues to ABL slot).
e2e_setup warn
e2e_run update-efisp >/dev/null 2>&1
if [ "$(state_of)" = "success" ]; then
  pass "update-efisp success reports state=success"
else
  fail "update-efisp success misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-A" ]; then
  pass "success path copied the ABL slot"
else
  fail "success path did not copy the ABL slot"
fi

# Case 2: efisp WRITE fails → must abort with error, ABL slot untouched.
e2e_setup warn
e2e_run update-efisp env DD_FAIL_WRITE_EFISP=1 >/dev/null 2>&1
if [ "$(state_of)" = "error" ]; then
  pass "efisp write failure reports state=error (not success)"
else
  fail "efisp write failure misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-B" ]; then
  pass "efisp write failure left the ABL target slot untouched"
else
  fail "efisp write failure still modified the ABL target slot"
fi

# Case 3: efisp READ-BACK mismatch → must abort with error, ABL slot untouched.
e2e_setup warn
e2e_run update-efisp env DD_CORRUPT_READ_EFISP=1 >/dev/null 2>&1
if [ "$(state_of)" = "error" ]; then
  pass "efisp read-back mismatch reports state=error (not success)"
else
  fail "efisp read-back mismatch misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-B" ]; then
  pass "efisp read-back mismatch left the ABL target slot untouched"
else
  fail "efisp read-back mismatch still modified the ABL target slot"
fi

# Case 4: ret=2 preserved: nowarn stub skips the BL slot and reports success.
e2e_setup nowarn
e2e_run update-efisp >/dev/null 2>&1
if [ "$(state_of)" = "success" ]; then
  pass "ret=2 path still reports state=success"
else
  fail "ret=2 path misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-B" ]; then
  pass "ret=2 path still skips the ABL slot write"
else
  fail "ret=2 path wrongly wrote the ABL slot"
fi

# ── run_flash(skip-efisp): the GBL verdict gates the ABL slot write ──
echo "--- run_flash: skip-efisp must abort on Unknown/Error, keep the verdicts ---"
e2e_log() { cat "$WORK/e2e/mod/tmp/flash.log" 2>/dev/null; }
# Read the CURRENT slot's abl_a (the source copied into the target slot abl_b) so
# the checks below work for every verdict, including the ones that do write.
e2e_src_abl() { cat "$WORK/e2e/dev/block/by-name/abl_a" 2>/dev/null; }

# Vulnerable (nowarn stub): keep skipping the BL flash to retain the BL version.
e2e_setup nowarn
e2e_run skip-efisp >/dev/null 2>&1
if [ "$(state_of)" = "success" ]; then
  pass "skip-efisp/Vulnerable: state=success"
else
  fail "skip-efisp/Vulnerable misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-B" ]; then
  pass "skip-efisp/Vulnerable: the ABL target slot is left untouched"
else
  fail "skip-efisp/Vulnerable: the ABL target slot was written"
fi
case "$(e2e_log)" in
  *"检测到GBL漏洞"*) pass "skip-efisp/Vulnerable: log records the retained BL version" ;;
  *) fail "skip-efisp/Vulnerable: log missing the retention reason" ;;
esac

# NotVulnerable (warn stub): the normal BL flash behaviour must be preserved.
e2e_setup warn
e2e_run skip-efisp >/dev/null 2>&1
if [ "$(state_of)" = "success" ]; then
  pass "skip-efisp/NotVulnerable: state=success"
else
  fail "skip-efisp/NotVulnerable misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "$(e2e_src_abl)" ]; then
  pass "skip-efisp/NotVulnerable: the ABL target slot is written from the current slot"
else
  fail "skip-efisp/NotVulnerable: the ABL target slot was not written"
fi

# Unknown (patcher writes identical bytes): must abort, target slot untouched.
e2e_setup identical
e2e_run skip-efisp >/dev/null 2>&1
if [ "$(state_of)" = "error" ]; then
  pass "skip-efisp/Unknown: state=error"
else
  fail "skip-efisp/Unknown misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-B" ]; then
  pass "skip-efisp/Unknown: the ABL target slot is left untouched"
else
  fail "skip-efisp/Unknown: the ABL target slot was written"
fi
case "$(e2e_log)" in
  *"GBL 状态无法确定"*) pass "skip-efisp/Unknown: log states the abort reason" ;;
  *) fail "skip-efisp/Unknown: log missing the abort reason" ;;
esac

# Error (patcher fails): must abort, target slot untouched.
e2e_setup fail
e2e_run skip-efisp >/dev/null 2>&1
if [ "$(state_of)" = "error" ]; then
  pass "skip-efisp/Error: state=error"
else
  fail "skip-efisp/Error misreported (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-B" ]; then
  pass "skip-efisp/Error: the ABL target slot is left untouched"
else
  fail "skip-efisp/Error: the ABL target slot was written"
fi
case "$(e2e_log)" in
  *"GBL 状态无法确定"*) pass "skip-efisp/Error: log states the abort reason" ;;
  *) fail "skip-efisp/Error: log missing the abort reason" ;;
esac

# ── unit tests: hardened helpers, extracted verbatim ──
echo "--- unit: hardened backup / read-back helpers ---"
U="$WORK/unit"; mkdir -p "$U"
grep '^timestamp() {' "$MODULE/bin/bl_flasher.sh" > "$U/helpers.sh"
for fn in ensure_runtime write_log write_backup_meta backup_partition \
          verify_written_range flash_and_verify; do
  sed -n "/^$fn() {/,/^}/p" "$MODULE/bin/bl_flasher.sh" >> "$U/helpers.sh"
done
if [ "$(grep -c '^[a-z_]*() {' "$U/helpers.sh")" -ne 7 ]; then
  fail "could not extract the bl_flasher.sh helpers"
  exit 1
fi
export U RUNTIME_DIR="$U/tmp" LOG_FILE="$U/tmp/flash.log" BACKUP_ROOT="$U/backup"
export STATE_FILE="$U/tmp/state" MESSAGE_FILE="$U/tmp/message" \
       UPDATED_FILE="$U/tmp/updated" TASK_FILE="$U/tmp/task_id" \
       PID_FILE="$U/tmp/flash.pid" LOCK_DIR="$U/tmp/flash.lock"
mkdir -p "$RUNTIME_DIR" "$BACKUP_ROOT"

# verify_written_range: exact match passes; mismatch / short / read-error fail.
printf 'abcdefghij\n' > "$U/src.bin"
cp "$U/src.bin" "$U/dev_ok.bin"
if sh -c '. "$1"; verify_written_range "$(wc -c < "$2")" "$2" "$3"' _ "$U/helpers.sh" "$U/dev_ok.bin" "$U/src.bin"; then
  pass "read-back: identical range passes"
else
  fail "read-back: identical range was rejected"
fi
printf 'XXXXXXXXXX\n' > "$U/dev_bad.bin"
if sh -c '. "$1"; verify_written_range "$(wc -c < "$2")" "$2" "$3"' _ "$U/helpers.sh" "$U/dev_bad.bin" "$U/src.bin"; then
  fail "read-back: mismatching content passed"
else
  pass "read-back: mismatching content fails"
fi
head -c 4 "$U/src.bin" > "$U/dev_short.bin"
if sh -c '. "$1"; verify_written_range "$(wc -c < "$2")" "$2" "$3"' _ "$U/helpers.sh" "$U/dev_short.bin" "$U/src.bin"; then
  fail "read-back: short read passed"
else
  pass "read-back: short read fails"
fi
# A read command that errors must fail even when the source file is intact.
mkdir -p "$U/failbin"
cat > "$U/failbin/dd" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$U/failbin/dd"
if PATH="$U/failbin:$PATH" sh -c '. "$1"; verify_written_range "$(wc -c < "$2")" "$2" "$3"' _ "$U/helpers.sh" "$U/dev_ok.bin" "$U/src.bin"; then
  fail "read-back: a failing read command passed"
else
  pass "read-back: a failing read command fails"
fi
if sh -c '. "$1"; verify_written_range 0 "$2" "$3"' _ "$U/helpers.sh" "$U/dev_ok.bin" "$U/src.bin"; then
  fail "read-back: zero length passed"
else
  pass "read-back: zero length fails"
fi

# backup_partition: success, empty, short read, size mismatch, meta/sha failures.
printf 'PAYLOAD-1234\n' > "$U/part.bin"
if sh -c '. "$1"; backup_partition "$2" efisp _a' _ "$U/helpers.sh" "$U/part.bin"; then
  img=$(ls "$BACKUP_ROOT"/efisp_a*.img 2>/dev/null | head -n 1)
  if [ -n "$img" ] && [ -s "$img" ] && [ -s "$img.meta" ] && [ -s "$img.sha256" ] \
     && [ "$(sed -n 's/^sha256=//p' "$img.meta")" = "$(sha256sum "$img" | cut -d' ' -f1)" ]; then
    pass "backup: copies the partition and writes meta + sha256"
  else
    fail "backup: image or sidecars are wrong"
  fi
else
  fail "backup: failed on a readable partition"
fi

rm -rf "$BACKUP_ROOT"; mkdir -p "$BACKUP_ROOT"
: > "$U/empty.bin"
if sh -c '. "$1"; backup_partition "$2" efisp _a' _ "$U/helpers.sh" "$U/empty.bin"; then
  fail "backup: an empty backup was accepted"
else
  pass "backup: an empty backup is rejected"
fi

rm -rf "$BACKUP_ROOT"; mkdir -p "$BACKUP_ROOT"
# Short read: dd writes only half of the input while blockdev reports the true
# size, so the size cross-check must reject the backup.
mkdir -p "$U/shortbin"; cp "$WORK/bin/dd_short" "$U/shortbin/dd"; chmod +x "$U/shortbin/dd"
if PATH="$U/shortbin:$PATH" sh -c '. "$1"; backup_partition "$2" efisp _a' _ "$U/helpers.sh" "$U/part.bin"; then
  fail "backup: a short read was accepted"
else
  pass "backup: a short read is rejected"
fi

rm -rf "$BACKUP_ROOT"; mkdir -p "$BACKUP_ROOT"
# Size mismatch: dd copies fully but blockdev reports a different capacity.
mkdir -p "$U/mismbin"
cat > "$U/mismbin/blockdev" <<'EOF'
#!/bin/sh
case "$1" in
  --getsize64) printf '%s\n' 999999 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$U/mismbin/blockdev"
if PATH="$U/mismbin:$PATH" sh -c '. "$1"; backup_partition "$2" efisp _a' _ "$U/helpers.sh" "$U/part.bin"; then
  fail "backup: a size mismatch was accepted"
else
  pass "backup: a size mismatch is rejected"
fi

rm -rf "$BACKUP_ROOT"; mkdir -p "$BACKUP_ROOT"
# Metadata write failure: the .meta path is pre-created as a directory so the
# redirect fails. date is pinned so the backup filename is deterministic.
if sh -c '
  date() { printf "%s\n" "20260101-000000"; }
  . "$1"
  mkdir -p "$BACKUP_ROOT"
  mkdir "$BACKUP_ROOT/efisp_a_20260101-000000-$$.img.meta"
  backup_partition "$2" efisp _a
' _ "$U/helpers.sh" "$U/part.bin" 2>/dev/null; then
  fail "backup: a metadata write failure was accepted"
else
  pass "backup: a metadata write failure is rejected"
fi

rm -rf "$BACKUP_ROOT"; mkdir -p "$BACKUP_ROOT"
# SHA-256 sidecar write failure: pre-create the .sha256 path as a directory.
if sh -c '
  date() { printf "%s\n" "20260101-000000"; }
  . "$1"
  mkdir -p "$BACKUP_ROOT"
  mkdir "$BACKUP_ROOT/efisp_a_20260101-000000-$$.img.sha256"
  backup_partition "$2" efisp _a
' _ "$U/helpers.sh" "$U/part.bin" 2>/dev/null; then
  fail "backup: a sha256 write failure was accepted"
else
  pass "backup: a sha256 write failure is rejected"
fi

rm -rf "$BACKUP_ROOT"; mkdir -p "$BACKUP_ROOT"
# Backups must accumulate, never overwrite.
sh -c '. "$1"; backup_partition "$2" efisp _a' _ "$U/helpers.sh" "$U/part.bin" >/dev/null 2>&1
sh -c '. "$1"; backup_partition "$2" efisp _a' _ "$U/helpers.sh" "$U/part.bin" >/dev/null 2>&1
n=$(ls "$BACKUP_ROOT"/efisp_a*.img 2>/dev/null | wc -l)
[ "$n" -ge 2 ] && pass "backup: successive backups accumulate ($n kept)" \
  || fail "backup: a later backup overwrote an earlier one (kept $n)"

# Filename collision: pin the clock AND take both backups from the SAME shell
# process (same $$), same partition/slot. The second must not reuse — and so
# clobber — the first's filename; it must claim a fresh, uniquely-suffixed name.
# Two different contents prove the first backup was not overwritten.
rm -rf "$BACKUP_ROOT"; mkdir -p "$BACKUP_ROOT"
printf 'COLLIDE-FIRST\n'  > "$U/collide1.bin"
printf 'COLLIDE-SECOND\n' > "$U/collide2.bin"
sh -c '
  date() { printf "%s\n" "20260101-120000"; }
  . "$1"
  backup_partition "$2" efisp _a || exit 1
  backup_partition "$3" efisp _a || exit 2
' _ "$U/helpers.sh" "$U/collide1.bin" "$U/collide2.bin"
c_rc=$?
c_names=$(ls "$BACKUP_ROOT"/efisp_a_*.img 2>/dev/null)
c_n=$(printf '%s\n' "$c_names" | grep -c .)
if [ "$c_rc" -eq 0 ] && [ "$c_n" -eq 2 ]; then
  pass "backup collision: two same-second backups from one process made two files"
else
  fail "backup collision: expected 2 files from one process (rc=$c_rc, files=$c_n)"
fi
c_first=$(printf '%s\n' "$c_names" | sed -n '1p')
c_second=$(printf '%s\n' "$c_names" | sed -n '2p')
if [ -n "$c_first" ] && [ -n "$c_second" ] && [ "$c_first" != "$c_second" ]; then
  pass "backup collision: the two filenames differ"
else
  fail "backup collision: filenames are not distinct ('$c_first' vs '$c_second')"
fi
# Locate the first backup by content: the old scheme would have reused this exact
# name and overwritten it with the second payload.
f_first=$(grep -l 'COLLIDE-FIRST'  "$BACKUP_ROOT"/efisp_a_*.img 2>/dev/null | head -n 1)
f_second=$(grep -l 'COLLIDE-SECOND' "$BACKUP_ROOT"/efisp_a_*.img 2>/dev/null | head -n 1)
if [ -n "$f_first" ] && [ -n "$f_second" ] && [ "$f_first" != "$f_second" ]; then
  pass "backup collision: first backup kept its own content (not overwritten)"
else
  fail "backup collision: first backup was clobbered or contents were mixed"
fi
# Both backups must carry a valid .meta and .sha256 for their own bytes.
c_bad=0
for f in "$f_first" "$f_second"; do
  if [ -z "$f" ] || [ ! -s "$f.meta" ] || [ ! -s "$f.sha256" ]; then c_bad=1; continue; fi
  m=$(sed -n 's/^sha256=//p' "$f.meta")
  a=$(sha256sum "$f" | cut -d' ' -f1)
  s=$(cut -d' ' -f1 "$f.sha256" | tr -d '[:space:]')
  [ "$m" = "$a" ] && [ "$s" = "$a" ] || c_bad=1
done
if [ "$c_bad" -eq 0 ]; then
  pass "backup collision: both backups have a valid meta and sha256"
else
  fail "backup collision: a backup is missing or has an invalid meta/sha256"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
