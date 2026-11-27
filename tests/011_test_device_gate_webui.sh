#!/bin/sh
# v7.5 device-whitelist gate on the WebUI flash path.
#
# customize.sh gates the installer, but the WebUI flash (bin/bl_flasher.sh) runs
# after an OTA with no installer in front of it, so it needs the same gate. These
# tests drive the real shipped bl_flasher.sh with a stubbed getprop/blockdev/dd,
# and exercise the shipped resolve_device() itself.
cd "$(dirname "$0")" || exit 1
MODULE=../magisk_module
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "Test passed: $1"; }
fail() { echo "Test failed: $1"; FAIL=1; }

# ── unit: the shipped resolve_device() maps exactly the supported codenames ──
sed -n '/^resolve_device() {/,/^}/p' "$MODULE/bin/bl_flasher.sh" > "$WORK/resolve.sh"
if [ ! -s "$WORK/resolve.sh" ]; then
  fail "could not extract resolve_device() from bl_flasher.sh"
  exit 1
fi

cat > "$WORK/getprop_unit" <<'EOF'
#!/bin/sh
case "$1" in
  ro.product.name)             printf '%s\n' "${STUB_PRODUCT:-}" ;;
  ro.build.version.incremental) printf '%s\n' "${STUB_INCR:-}" ;;
  ro.build.display.id)         printf '%s\n' "${STUB_DISPLAY:-}" ;;
  *)                           printf '\n' ;;
esac
EOF
chmod +x "$WORK/getprop_unit"
mkdir -p "$WORK/unitbin"
cp "$WORK/getprop_unit" "$WORK/unitbin/getprop"

resolve() { # resolve <product> <incr> <display>  -> prints mapping or nothing
  PATH="$WORK/unitbin:$PATH" STUB_PRODUCT="$1" STUB_INCR="$2" STUB_DISPLAY="$3" \
    sh -c '. "$1"; resolve_device' _ "$WORK/resolve.sh"
}

for dev in myron pudding popsicle pandora byron nezha_global songyuan; do
  got=$(resolve "$dev" '' '')
  if [ "$got" = "$dev" ]; then
    pass "resolve_device maps $dev"
  else
    fail "resolve_device($dev) returned '${got:-<empty>}'"
  fi
done

got=$(resolve nezha '' '')
if [ "$got" = "nezha" ]; then
  pass "resolve_device maps plain nezha to nezha"
else
  fail "resolve_device(nezha) returned '${got:-<empty>}'"
fi

got=$(resolve nezha 'V14.0.5.0.UMOMIXM' '')
if [ "$got" = "nezha_global" ]; then
  pass "resolve_device maps a nezha MIXM build to nezha_global"
else
  fail "resolve_device(nezha, MIXM) returned '${got:-<empty>}'"
fi

got=$(resolve nezha '' 'OS2.0.1.0.UMOMIXM')
if [ "$got" = "nezha_global" ]; then
  pass "resolve_device detects the MIXM suffix in display id"
else
  fail "resolve_device(nezha, display MIXM) returned '${got:-<empty>}'"
fi

# Unknown / empty codenames must not resolve.
for dev in '' unknown_device marlin 'myron '; do
  if got=$(resolve "$dev" '' ''); then
    fail "resolve_device accepted unsupported product '$dev' as '$got'"
  else
    pass "resolve_device rejects unsupported product '${dev}'"
  fi
done

# Every supported codename must have a firmware directory, so a resolved device
# can never point at a missing repo entry.
for dev in $(printf '%s\n' myron pudding popsicle pandora byron nezha nezha_global songyuan); do
  if [ -d "$MODULE/ablrepo/$dev" ]; then
    pass "ablrepo ships a directory for $dev"
  else
    fail "ablrepo is missing a directory for $dev"
  fi
done

# ── end-to-end: the real flasher must refuse an unknown device ──
mkdir -p "$WORK/bin"
cat > "$WORK/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.boot.slot_suffix)          printf '%s\n' "${STUB_SLOT:-_a}" ;;
  ro.product.name)              printf '%s\n' "${STUB_PRODUCT-myron}" ;;
  ro.build.version.incremental) printf '%s\n' "${STUB_INCR:-}" ;;
  ro.build.display.id)          printf '%s\n' "${STUB_DISPLAY:-}" ;;
  *)                            printf '\n' ;;
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
# dd records every write target so the test can prove nothing was touched.
cat > "$WORK/bin/dd" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    of=*) printf '%s\n' "${a#of=}" >> "${DD_WRITE_LOG:-/dev/null}" ;;
  esac
done
exec /usr/bin/dd "$@"
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

e2e_setup() {
  rm -rf "$WORK/e2e"; mkdir -p "$WORK/e2e/mod/bin" "$WORK/e2e/mod/tmp" \
    "$WORK/e2e/dev/block/by-name" "$WORK/e2e/backup"
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
  cat > "$WORK/e2e/mod/bin/patch_abl" <<'EOF'
#!/bin/sh
printf 'Warning: Failed to patch ABL GBL\n'
printf 'Saved to %s\n' "$2"
printf 'PATCHED\n' > "$2"
exit 0
EOF
  chmod +x "$WORK/e2e/mod/bin/"*
  printf 'ORIGINAL-ABL-A\n' > "$WORK/e2e/dev/block/by-name/abl_a"
  printf 'ORIGINAL-ABL-B\n' > "$WORK/e2e/dev/block/by-name/abl_b"
  printf 'ORIGINAL-EFISP\n' > "$WORK/e2e/dev/block/by-name/efisp"
  : > "$WORK/e2e/writes.log"
}

e2e_run() { # e2e_run <flash-mode> [extra env as KEY=VAL ...]
  _mode="$1"; shift
  DD_WRITE_LOG="$WORK/e2e/writes.log" \
  MODDIR="$WORK/e2e/mod" \
  BY_NAME_DIR="$WORK/e2e/dev/block/by-name" \
  GBL_BY_NAME_DIR="$WORK/e2e/dev/block/by-name" \
  GBL_BACKUP_DIR="$WORK/e2e/backup" \
  STUB_SLOT=_a \
  "$@" sh "$WORK/e2e/mod/bin/bl_flasher.sh" flash "$_mode"
}

state_of() { cat "$WORK/e2e/mod/tmp/state" 2>/dev/null; }

# Case 1: unknown device -> error state, nothing written, slots untouched.
e2e_setup
e2e_run update-efisp env STUB_PRODUCT=unknown_device >/dev/null 2>&1
if [ "$(state_of)" = "error" ]; then
  pass "unknown device reports state=error (not success)"
else
  fail "unknown device misreported (state=$(state_of))"
fi
if [ -s "$WORK/e2e/writes.log" ]; then
  fail "unknown device still wrote to: $(tr '\n' ' ' < "$WORK/e2e/writes.log")"
else
  pass "unknown device wrote to no partition"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-B" ] &&
   [ "$(cat "$WORK/e2e/dev/block/by-name/efisp")" = "ORIGINAL-EFISP" ]; then
  pass "unknown device left abl and efisp untouched"
else
  fail "unknown device modified a partition"
fi

# Case 2: empty codename -> same hard abort.
e2e_setup
e2e_run update-efisp env STUB_PRODUCT= >/dev/null 2>&1
if [ "$(state_of)" = "error" ] && [ ! -s "$WORK/e2e/writes.log" ]; then
  pass "empty codename aborts without writing"
else
  fail "empty codename was not safely rejected (state=$(state_of))"
fi

# Case 3: a supported device still runs the flow (gate must not block it).
e2e_setup
e2e_run update-efisp env STUB_PRODUCT=myron >/dev/null 2>&1
if [ "$(state_of)" = "success" ]; then
  pass "supported device passes the gate and completes"
else
  fail "supported device was blocked (state=$(state_of))"
fi
if [ "$(cat "$WORK/e2e/dev/block/by-name/abl_b")" = "ORIGINAL-ABL-A" ]; then
  pass "supported device still copies the ABL slot"
else
  fail "supported device did not copy the ABL slot"
fi

# Case 4: the OTA-retention path (skip-efisp) is gated too.
e2e_setup
e2e_run skip-efisp env STUB_PRODUCT=unknown_device >/dev/null 2>&1
if [ "$(state_of)" = "error" ] && [ ! -s "$WORK/e2e/writes.log" ]; then
  pass "skip-efisp path also rejects an unknown device"
else
  fail "skip-efisp path let an unknown device through (state=$(state_of))"
fi

# Case 5: a supported device is still accepted on the skip-efisp path.
e2e_setup
e2e_run skip-efisp env STUB_PRODUCT=pudding >/dev/null 2>&1
if [ "$(state_of)" = "success" ]; then
  pass "skip-efisp path accepts a supported device"
else
  fail "skip-efisp path blocked a supported device (state=$(state_of))"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
fi
echo "FAILURES PRESENT"
exit 1
