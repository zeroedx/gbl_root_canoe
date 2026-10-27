# Static checks for the WebUI assets. These guard the contract between the
# panel and the shell script: every i18n key the markup references must exist in
# both languages, and every status field the script emits must be the one the
# panel reads. Requires node (used only to evaluate the i18n module with DOM
# stubs) and grep.
cd "$(dirname "$0")"
WEBROOT=../magisk_module/webroot
SCRIPT=../magisk_module/bin/bl_flasher.sh
MODULEPROP=../magisk_module/module.prop
FAIL=0
pass() { echo "Test passed: $1"; }
fail() { echo "Test failed: $1"; FAIL=1; }

command -v node >/dev/null 2>&1 || { echo "node is required for this test"; exit 1; }

echo "--- assets referenced by the markup exist ---"
for asset in i18n.js app.js style.css; do
  if grep -q "$asset" "$WEBROOT/index.html" && [ -f "$WEBROOT/$asset" ]; then
    pass "index.html loads $asset"
  else
    fail "index.html does not reference an existing $asset"
  fi
done

echo "--- i18n keys referenced by the markup resolve in both languages ---"
node - "$WEBROOT" <<'EOF'
const fs = require('fs');
const path = require('path');
const webroot = process.argv[2];

// Minimal DOM stubs so the i18n module can run outside a browser.
const noop = () => {};
const store = new Map();
globalThis.window = globalThis;
globalThis.navigator = { languages: ['en'], language: 'en' };
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
};
globalThis.CustomEvent = class { constructor(type, init) { this.type = type; this.detail = init?.detail; } };
const stubEl = () => ({
  set textContent(v) {}, get textContent() { return ''; },
  setAttribute: noop, getAttribute: () => null,
  dataset: {}, classList: { add: noop, remove: noop },
});
globalThis.document = {
  documentElement: { lang: '' },
  title: '',
  querySelectorAll: () => [],
  getElementById: () => stubEl(),
  addEventListener: noop,
  dispatchEvent: noop,
};

eval(fs.readFileSync(path.join(webroot, 'i18n.js'), 'utf8'));
const i18n = globalThis.BlFlasherI18n;
if (!i18n) { console.log('FAIL: i18n module did not expose BlFlasherI18n'); process.exit(1); }

const html = fs.readFileSync(path.join(webroot, 'index.html'), 'utf8');
const keys = new Set();
const re = /data-i18n(?:-aria-label|-title|-placeholder)?="([^"]+)"/g;
let m;
while ((m = re.exec(html))) keys.add(m[1]);

const langs = ['zh', 'en'];
let bad = 0;
// t() falls back to the key name when a message is missing, so compare each
// referenced key against both language tables directly.
const prev = i18n.lang;
for (const key of keys) {
  for (const lang of langs) {
    i18n.setLang(lang);
    const value = i18n.t(key);
    if (value === key || value === undefined || value === null || value === '') {
      console.log(`FAIL: key "${key}" missing in ${lang}`);
      bad++;
    }
  }
}
i18n.setLang(prev);
console.log(`checked ${keys.size} markup keys across ${langs.length} languages`);
if (bad) process.exit(1);
console.log('PASS');
EOF
[ $? -eq 0 ] && pass "all markup i18n keys resolve in zh and en" || fail "some markup i18n keys are missing"

echo "--- the panel reads the fields the script emits ---"
for field in MODULE_NAME MODULE_VERSION CURRENT_SLOT TARGET_SLOT RUNNING STALE TASK_ID DEVICE MODEL STATE MESSAGE UPDATED_AT; do
  if grep -qE "(^|[^A-Za-z_])${field}=" "$SCRIPT" && grep -q "${field}" "$WEBROOT/app.js"; then
    pass "app.js consumes ${field}"
  else
    fail "field ${field} is emitted or consumed inconsistently"
  fi
done

echo "--- the panel never hardcodes module metadata ---"
if grep -qE "versionCode|5\.[0-9]|7\.[0-9]" "$WEBROOT/app.js" "$WEBROOT/index.html"; then
  fail "the panel hardcodes a version string"
else
  pass "module metadata is read from the script, not hardcoded"
fi

echo "--- module.prop declares a valid, documented module id ---"
# The module id lives in module.prop and is the single source of truth: the
# scripts read name/version from it rather than hardcoding any value. This
# section verifies that invariant instead of comparing against a string that
# no script contains.
prop_id=$(sed -n 's/^id=//p' "$MODULEPROP" | head -n 1)
valid=0
if [ -n "$prop_id" ]; then
  case "$prop_id" in
    [a-z0-9]*)
      case "$prop_id" in
        *[!a-z0-9_]*) ;;
        *) valid=1 ;;
      esac ;;
  esac
fi
if [ "$valid" = "1" ]; then
  pass "module.prop declares a valid id=$prop_id"
else
  fail "module.prop has no valid module id (got '$prop_id')"
fi

if [ "$valid" = "1" ]; then
  # A script or the panel that hardcoded the id would silently override
  # module.prop, so the metadata would no longer be authoritative.
  if grep -rn "$prop_id" "$SCRIPT" "$WEBROOT" >/dev/null 2>&1; then
    fail "module id '$prop_id' is hardcoded in a script or the panel"
  else
    pass "the module id is not hardcoded in the script or the panel"
  fi

  # The id must match what the READMEs document, so an id rename cannot ship
  # with stale documentation.
  for readme in ../README.md ../README_zh.md; do
    if [ -f "$readme" ] && grep -q "$prop_id" "$readme"; then
      pass "$(basename "$readme") documents id=$prop_id"
    else
      fail "$(basename "$readme") does not document id=$prop_id"
    fi
  done
fi

if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed successfully."
  exit 0
else
  exit 1
fi
