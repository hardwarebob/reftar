#!/bin/bash
# Basic reflink test for reftar

set -e

REFTAR="./target/release/reftar"
TEST_DIR="test_data"

echo "=== Basic Reflink Test ==="
echo

# Create test files with reflinks
echo "Step 1: Creating source file (1MB)..."
dd if=/dev/urandom of="$TEST_DIR/source.bin" bs=1K count=1024 status=none

echo "Step 2: Creating reflinked copies..."
cp --reflink=always "$TEST_DIR/source.bin" "$TEST_DIR/reflink1.bin"
cp --reflink=always "$TEST_DIR/source.bin" "$TEST_DIR/reflink2.bin"

echo "Step 3: Checking disk usage..."
du -sh "$TEST_DIR"
echo "  (Should be around 1MB despite having 3x 1MB files)"

echo ""
echo "Step 4: Creating archive..."
$REFTAR create -f test_basic.reftar -v "$TEST_DIR/"/*.bin

echo ""
echo "Step 5: Archive info..."
$REFTAR info -f test_basic.reftar

echo ""
echo "Step 6: Listing archive..."
$REFTAR list -f test_basic.reftar

echo ""
echo "Step 7: Extracting archive..."
rm -rf restored_test
mkdir -p restored_test
$REFTAR extract -f test_basic.reftar -C restored_test -v

echo ""
echo "Step 8: Verifying extracted files..."
echo -n "  source.bin: "
if cmp -s "$TEST_DIR/source.bin" "restored_test/source.bin"; then
    echo "✓ OK"
else
    echo "✗ MISMATCH"
    exit 1
fi

echo -n "  reflink1.bin: "
if cmp -s "$TEST_DIR/reflink1.bin" "restored_test/reflink1.bin"; then
    echo "✓ OK"
else
    echo "✗ MISMATCH"
    exit 1
fi

echo -n "  reflink2.bin: "
if cmp -s "$TEST_DIR/reflink2.bin" "restored_test/reflink2.bin"; then
    echo "✓ OK"
else
    echo "✗ MISMATCH"
    exit 1
fi

echo ""
echo "=== All tests passed! ==="

# Cleanup
rm -f test_basic.reftar
rm -rf restored_test
