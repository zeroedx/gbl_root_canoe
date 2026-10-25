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
EXTRACTFV=$WORK/extractfv
PATCH_ABL=$WORK/patch_abl
gcc -O2 -o "$EXTRACTFV" ../tools/extractfv.c -llzma 2>/dev/null
gcc -O2 -o "$PATCH_ABL" ../tools/patch_abl.c 2>/dev/null

# classify_loader <LinuxLoader.efi> <workdir>
#   Runs patch_abl and prints "vuln" / "no-vuln" / "error:<reason>".
#   "vuln"/"no-vuln" require exit 0, a non-empty output and the tool's own
#   "Saved to" confirmation; anything else is "error". A "vuln" verdict also
#   requires the patched output to differ from the input, so a no-op run is
#   never mistaken for a successful patch. The GBL warning alone never decides
#   the verdict.
#   Observed semantics (patchlib.h / patch_abl.c):
#     has-vuln : patch_abl exit 0, "Saved to" printed, output differs, no GBL warning
#     no-vuln  : patch_abl exit 0, "Saved to" printed, GBL warning printed
#     failure  : patch_abl exit != 0, or no "Saved to", or empty output
classify_loader() {
  loader="$1"; d="$2"
  "$PATCH_ABL" "$loader" "$d/patched.efi" > "$d/patch.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then printf 'error:patch_abl exit %d\n' "$rc"; return 2; fi
  if [ ! -s "$d/patched.efi" ]; then
    printf 'error:patched.efi missing or empty\n'; return 2
  fi
  if ! grep -q "Saved to " "$d/patch.log"; then
    printf 'error:patch_abl did not report a saved output\n'; return 2
  fi
  if grep -q "Warning: Failed to patch ABL GBL" "$d/patch.log"; then
    printf 'no-vuln\n'; return 1
  fi
  if cmp -s "$loader" "$d/patched.efi"; then
    printf 'error:patch_abl made no changes\n'; return 2
  fi
  printf 'vuln\n'; return 0
}

# classify_firmware <abl.img> <workdir>
#   Extract the loader, then classify it. Extraction failure or a missing/empty
#   LinuxLoader.efi is an error, never a verdict.
classify_firmware() {
  img="$1"; d="$2"
  rm -rf "$d"; mkdir -p "$d"
  "$EXTRACTFV" "$img" -o "$d" > "$d/extract.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then printf 'error:extractfv exit %d\n' "$rc"; return 2; fi
  if [ ! -s "$d/LinuxLoader.efi" ]; then
    printf 'error:LinuxLoader.efi missing or empty\n'; return 2
  fi
  classify_loader "$d/LinuxLoader.efi" "$d"
}

if [ ! -x "$EXTRACTFV" ] || [ ! -x "$PATCH_ABL" ]; then
  fail "could not build extractfv/patch_abl"
else
  for p in myron pudding popsicle pandora nezha nezha_global; do
    out=$(classify_firmware "$ABLREPO/$p/abl.img" "$WORK/vuln_$p")
    case "$out" in
      vuln)    pass "$p: firmware carries the GBL vulnerability" ;;
      no-vuln) fail "$p: firmware lacks the GBL vulnerability" ;;
      *)       fail "$p: could not verify firmware ($out)" ;;
    esac
  done

  echo "--- negative controls (failures must be detected, never pass) ---"
  # Extraction failure: a non-ABL input yields no LinuxLoader.efi.
  printf 'this is not an abl image\n' > "$WORK/notabl.bin"
  out=$(classify_firmware "$WORK/notabl.bin" "$WORK/neg_extract")
  if [ "$out" = "vuln" ]; then
    fail "extraction failure was misclassified as vulnerable"
  else
    pass "extraction failure detected ($out)"
  fi

  # Missing output: an empty image also yields no LinuxLoader.efi.
  : > "$WORK/empty.bin"
  out=$(classify_firmware "$WORK/empty.bin" "$WORK/neg_empty")
  if [ "$out" = "vuln" ]; then
    fail "missing output was misclassified as vulnerable"
  else
    pass "missing output detected ($out)"
  fi

  # Processing failure: patch_abl must reject a missing input file.
  if "$PATCH_ABL" "$WORK/does_not_exist.efi" "$WORK/x.efi" > "$WORK/neg_patch.log" 2>&1; then
    fail "patch_abl accepted a missing input file"
  else
    pass "processing failure detected (patch_abl rejects missing input)"
  fi

  # No-vuln detection: a real loader with the UTF-16 "efisp" marker removed must
  # be classified "no-vuln", proving the warning branch is actually exercised.
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
  gcc -O2 -o "$WORK/strip_efisp" "$WORK/strip_efisp.c" 2>/dev/null
  if [ -x "$WORK/strip_efisp" ]; then
    "$EXTRACTFV" "$ABLREPO/myron/abl.img" -o "$WORK/nv" >/dev/null 2>&1
    if "$WORK/strip_efisp" "$WORK/nv/LinuxLoader.efi" "$WORK/nv/stripped.efi" >/dev/null 2>&1; then
      mkdir -p "$WORK/neg_novuln"
      out=$(classify_loader "$WORK/nv/stripped.efi" "$WORK/neg_novuln")
      if [ "$out" = "no-vuln" ]; then
        pass "no-vuln firmware detected ($out)"
      else
        fail "no-vuln firmware misclassified ($out)"
      fi
    else
      fail "could not build the no-vuln fixture"
    fi
  else
    fail "could not build the no-vuln fixture generator"
  fi

  # Firmware verification failure: a tampered image must not match its sha256.
  cp "$ABLREPO/pudding/abl.img" "$WORK/tampered.img"
  printf 'X' | dd of="$WORK/tampered.img" bs=1 seek=100 conv=notrunc 2>/dev/null
  exp=$(cut -d' ' -f1 "$ABLREPO/pudding/abl.sha256" | tr -d '[:space:]')
  act=$(sha256sum "$WORK/tampered.img" | cut -d' ' -f1)
  if [ "$exp" != "$act" ]; then
    pass "firmware verification failure detected (tampered image)"
  else
    fail "firmware verification did not detect a tampered image"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
