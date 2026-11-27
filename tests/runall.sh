#run all tests
cd "$(dirname "$0")" || exit 1

fail() {
    echo "Test $1 failed. Stopping further tests."
    exit 1
}

# The toolkit tests verify a built package, so build any that is missing. A
# build failure is reported as a test failure rather than skipped, so a broken
# toolkit cannot pass unnoticed.
build_toolkit() {
    kind=$1
    zip=../targets/toolkit_$kind/build/toolkit_$kind.zip
    [ -f "$zip" ] && return 0
    echo "--- building the $kind toolkit ---"
    ( cd .. && ${MAKE:-make} "toolkit_$kind" ) ||
        fail "012_test_toolkit.sh ($kind): the package did not build."
}

for t in 001_test_extract 004_test_patch 005_test_device_map \
         006_test_bl_flasher 007_test_customize_flow 008_test_webui \
         009_test_patch_inputs 010_test_safety_hardening \
         011_test_device_gate_webui; do
    ./$t.sh || fail "$t.sh"
done

for kind in android windows; do
    build_toolkit "$kind"
    ./012_test_toolkit.sh "$kind" "../targets/toolkit_$kind/build/toolkit_$kind.zip" ||
        fail "012_test_toolkit.sh ($kind)"
done

echo "All tests passed successfully."
