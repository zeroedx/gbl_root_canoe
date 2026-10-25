# Test script for multi-device identification, firmware mapping and safety.
cd "$(dirname "$0")"
MODULE=../magisk_module
ABLREPO=$MODULE/ablrepo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "Test passed: $1"; }
fail() { echo "Test failed: $1"; FAIL=1; }

# ── Extract the real resolve_device() from customize.sh and exercise it with a
#    stub getprop, so the shipped logic itself is tested. ──
sed -n '/^resolve_device() {/,/^}/p' "$MODULE/customize.sh" > "$WORK/resolve.sh"
if [ ! -s "$WORK/resolve.sh" ]; then
  fail "could not extract resolve_device() from customize.sh"
  exit 1
fi

cat > "$WORK/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.product.name) printf '%s\n' "${STUB_PRODUCT:-}" ;;
  ro.build.version.incremental) printf '%s\n' "${STUB_INCR:-}" ;;
  ro.build.display.id) printf '%s\n' "${STUB_DISPLAY:-}" ;;
  *) printf '%s\n' "" ;;
esac
EOF
chmod +x "$WORK/getprop"
export PATH="$WORK:$PATH"

# resolve <product> <incremental> <display>  -> prints resolved repo dir (or empty)
resolve() {
  STUB_PRODUCT="$1" STUB_INCR="$2" STUB_DISPLAY="$3" \
    sh -c '. "$1"; resolve_device' _ "$WORK/resolve.sh"
}

echo "--- device identification ---"
check_map() { # check_map <desc> <expected> <product> <incr> <display>
  got=$(resolve "$3" "$4" "$5")
  if [ "$got" = "$2" ]; then pass "$1 ($got)"; else fail "$1: expected '$2', got '$got'"; fi
}
check_map "myron maps to myron"            myron        myron        ""                  ""
check_map "pudding maps to pudding"        pudding      pudding      ""                  ""
check_map "popsicle maps to popsicle"      popsicle     popsicle     ""                  ""
check_map "pandora maps to pandora"        pandora      pandora      ""                  ""
check_map "nezha_global maps to itself"    nezha_global nezha_global ""                  ""
check_map "nezha CN (CNXM) -> nezha"       nezha        nezha        "OS3.0.1.0.VNACNXM" ""
check_map "nezha EEA (EUXM) -> nezha"      nezha        nezha        "OS3.0.336.0.XPAEUXM" ""
check_map "nezha global (MIXM) -> global"  nezha_global nezha        "OS3.0.9.0.WPAMIXM" ""
check_map "nezha MIXM via display.id"      nezha_global nezha        ""                  "OS3.0.9.0.WPAMIXM"
check_map "unknown product -> no match"    ""           unknown_x99  ""                  ""
check_map "empty product -> no match"      ""           ""           ""                  ""

echo "--- firmware mapping & integrity ---"
for p in myron pudding popsicle pandora nezha nezha_global; do
  dir="$ABLREPO/$p"
  if [ ! -f "$dir/abl.img" ] || [ ! -f "$dir/abl.sha256" ]; then
    fail "$p: firmware files missing in $dir"
    continue
  fi
  exp=$(cut -d' ' -f1 "$dir/abl.sha256" | tr -d '[:space:]')
  act=$(sha256sum "$dir/abl.img" | cut -d' ' -f1)
  if [ "$exp" = "$act" ]; then pass "$p: abl.img matches abl.sha256"; else fail "$p: sha256 mismatch"; fi
done

# nezha and nezha_global must be distinct firmware, never shared.
if cmp -s "$ABLREPO/nezha/abl.img" "$ABLREPO/nezha_global/abl.img"; then
  fail "nezha and nezha_global firmware are identical (must differ)"
else
  pass "nezha and nezha_global firmware are distinct"
fi

echo "--- firmware carries the GBL vulnerability ---"
gcc -O2 -o "$WORK/extractfv" ../tools/extractfv.c -llzma 2>/dev/null
gcc -O2 -o "$WORK/patch_abl" ../tools/patch_abl.c 2>/dev/null
if [ ! -x "$WORK/extractfv" ] || [ ! -x "$WORK/patch_abl" ]; then
  fail "could not build extractfv/patch_abl"
else
  for p in myron pudding popsicle pandora nezha nezha_global; do
    d="$WORK/$p"; mkdir -p "$d"
    "$WORK/extractfv" "$ABLREPO/$p/abl.img" -o "$d" >/dev/null 2>&1
    "$WORK/patch_abl" "$d/LinuxLoader.efi" "$d/patched.efi" > "$d/log.txt" 2>&1
    if grep -q "Warning: Failed to patch ABL GBL" "$d/log.txt"; then
      fail "$p: firmware lacks the GBL vulnerability"
    else
      pass "$p: firmware patches (has GBL vulnerability)"
    fi
  done
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
