#run all tests
cd "$(dirname "$0")"
./001_test_extract.sh
if [ $? -ne 0 ]; then
    echo "Test 001_test_extract.sh failed. Stopping further tests."
    exit 1
fi
./004_test_patch.sh
if [ $? -ne 0 ]; then
    echo "Test 004_test_patch.sh failed. Stopping further tests."
    exit 1
fi
./005_test_device_map.sh
if [ $? -ne 0 ]; then
    echo "Test 005_test_device_map.sh failed. Stopping further tests."
    exit 1
fi
echo "All tests passed successfully."