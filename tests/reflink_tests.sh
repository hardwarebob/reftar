#!/bin/bash
# Reflink functionality tests for reftar on btrfs filesystem
# This test suite verifies that reftar correctly handles reflinked files

set -e

REFTAR="./target/release/reftar"
TEST_DIR="test_data"
ARCHIVE="test_reflink.reftar"
RESTORE_DIR="restored_data"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Reftar Reflink Tests ==="
echo

# Check if reftar is built
if [ ! -f "$REFTAR" ]; then
    echo -e "${RED}Error: reftar binary not found at $REFTAR${NC}"
    echo "Please run: cargo build --release"
    exit 1
fi

# Check if test_data is on btrfs
FS_TYPE=$(stat -f -c %T "$TEST_DIR" 2>/dev/null || echo "unknown")
echo "Filesystem type for $TEST_DIR: $FS_TYPE"
if [ "$FS_TYPE" != "btrfs" ]; then
    echo -e "${YELLOW}Warning: $TEST_DIR is not on btrfs. Reflink tests may not work as expected.${NC}"
    echo "Continuing anyway..."
fi
echo

# Cleanup function
cleanup() {
    rm -rf "$RESTORE_DIR" "$ARCHIVE" 2>/dev/null || true
}

# Run cleanup on exit
trap cleanup EXIT

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test function
run_test() {
    local test_name="$1"
    echo -e "${YELLOW}Test: $test_name${NC}"
}

pass_test() {
    echo -e "${GREEN}✓ PASSED${NC}"
    ((TESTS_PASSED++))
    echo
}

fail_test() {
    local msg="$1"
    echo -e "${RED}✗ FAILED: $msg${NC}"
    ((TESTS_FAILED++))
    echo
}

# Get inode number
get_inode() {
    stat -c %i "$1"
}

# Get file size
get_size() {
    stat -c %s "$1"
}

# Check if two files share extents (btrfs specific)
check_shared_extents() {
    local file1="$1"
    local file2="$2"

    # Use filefrag to check for shared extents
    if command -v filefrag &> /dev/null; then
        local extents1=$(filefrag -v "$file1" 2>/dev/null | grep -c "shared" || echo "0")
        local extents2=$(filefrag -v "$file2" 2>/dev/null | grep -c "shared" || echo "0")

        if [ "$extents1" -gt 0 ] || [ "$extents2" -gt 0 ]; then
            return 0  # Files share extents
        fi
    fi

    # Alternative: check if files have same physical blocks using debugfs/filefrag
    # For now, we'll just check if cp --reflink works
    return 1
}

# ============================================================================
# Test 1: Create files with reflinks
# ============================================================================
run_test "Creating test files with reflinks"

# Clean test directory contents (but keep the directory)
rm -f "$TEST_DIR"/* 2>/dev/null || true

# Create a source file with some data (larger than block size)
dd if=/dev/urandom of="$TEST_DIR/source.bin" bs=1M count=2 2>/dev/null

# Create reflinked copies using cp --reflink
cp --reflink=always "$TEST_DIR/source.bin" "$TEST_DIR/reflink1.bin" 2>/dev/null || {
    fail_test "Cannot create reflinks (cp --reflink failed). Is this really btrfs?"
    exit 1
}

cp --reflink=always "$TEST_DIR/source.bin" "$TEST_DIR/reflink2.bin"
cp --reflink=always "$TEST_DIR/source.bin" "$TEST_DIR/reflink3.bin"

# Verify files are identical
if cmp -s "$TEST_DIR/source.bin" "$TEST_DIR/reflink1.bin" && \
   cmp -s "$TEST_DIR/source.bin" "$TEST_DIR/reflink2.bin" && \
   cmp -s "$TEST_DIR/source.bin" "$TEST_DIR/reflink3.bin"; then
    pass_test
else
    fail_test "Reflinked files are not identical to source"
    exit 1
fi

# ============================================================================
# Test 2: Verify reflinked files share extents
# ============================================================================
run_test "Verifying reflinked files share extents"

# Check disk usage - reflinked files should use minimal additional space
SOURCE_SIZE=$(get_size "$TEST_DIR/source.bin")
TOTAL_APPARENT=$((SOURCE_SIZE * 4))  # 4 files total

# Get actual disk usage (in KB, then convert to bytes)
ACTUAL_USAGE=$(du -sk "$TEST_DIR" | cut -f1)
ACTUAL_USAGE=$((ACTUAL_USAGE * 1024))

echo "  Source file size: $SOURCE_SIZE bytes"
echo "  Total apparent size (4 files): $TOTAL_APPARENT bytes"
echo "  Actual disk usage: $ACTUAL_USAGE bytes"

# Actual usage should be significantly less than 4x the file size
# Allow some overhead for metadata
MAX_EXPECTED=$((SOURCE_SIZE * 2))  # Should be around 1x + metadata

if [ "$ACTUAL_USAGE" -lt "$MAX_EXPECTED" ]; then
    echo "  ✓ Reflinks are sharing data (using $(( (ACTUAL_USAGE * 100) / TOTAL_APPARENT ))% of apparent size)"
    pass_test
else
    echo "  ✗ Files don't appear to be sharing data efficiently"
    fail_test "Disk usage too high for reflinked files"
fi

# ============================================================================
# Test 3: Create archive with reflinked files
# ============================================================================
run_test "Creating archive containing reflinked files"

$REFTAR create -f "$ARCHIVE" -v "$TEST_DIR"/ > /dev/null 2>&1 || {
    fail_test "Archive creation failed"
    exit 1
}

# Check archive was created
if [ -f "$ARCHIVE" ]; then
    ARCHIVE_SIZE=$(get_size "$ARCHIVE")
    echo "  Archive size: $ARCHIVE_SIZE bytes"
    echo "  Source data size: $TOTAL_APPARENT bytes"
    pass_test
else
    fail_test "Archive file was not created"
    exit 1
fi

# ============================================================================
# Test 4: Verify archive contents
# ============================================================================
run_test "Listing archive contents"

FILE_COUNT=$($REFTAR list -f "$ARCHIVE" | wc -l)
echo "  Files in archive: $FILE_COUNT"

# Should have: directory + 4 binary files
if [ "$FILE_COUNT" -ge 5 ]; then
    pass_test
else
    fail_test "Expected at least 5 entries in archive, got $FILE_COUNT"
fi

# ============================================================================
# Test 5: Extract archive
# ============================================================================
run_test "Extracting archive"

mkdir -p "$RESTORE_DIR"
$REFTAR extract -f "$ARCHIVE" -C "$RESTORE_DIR" -v > /dev/null 2>&1 || {
    fail_test "Archive extraction failed"
    exit 1
}

# Check extracted files exist
if [ -f "$RESTORE_DIR/test_data/source.bin" ] && \
   [ -f "$RESTORE_DIR/test_data/reflink1.bin" ] && \
   [ -f "$RESTORE_DIR/test_data/reflink2.bin" ] && \
   [ -f "$RESTORE_DIR/test_data/reflink3.bin" ]; then
    pass_test
else
    fail_test "Not all files were extracted"
    exit 1
fi

# ============================================================================
# Test 6: Verify extracted file contents
# ============================================================================
run_test "Verifying extracted file contents"

# Compare all extracted files with originals
if cmp -s "$TEST_DIR/source.bin" "$RESTORE_DIR/test_data/source.bin" && \
   cmp -s "$TEST_DIR/reflink1.bin" "$RESTORE_DIR/test_data/reflink1.bin" && \
   cmp -s "$TEST_DIR/reflink2.bin" "$RESTORE_DIR/test_data/reflink2.bin" && \
   cmp -s "$TEST_DIR/reflink3.bin" "$RESTORE_DIR/test_data/reflink3.bin"; then
    echo "  ✓ All files match originals"
    pass_test
else
    fail_test "Extracted files don't match originals"
    exit 1
fi

# ============================================================================
# Test 7: Test with duplicate content (deduplication)
# ============================================================================
run_test "Testing deduplication with duplicate files"

# Create regular files with duplicate content (not reflinked)
echo "Test content for deduplication" > "$TEST_DIR/dup1.txt"
cat "$TEST_DIR/dup1.txt" > "$TEST_DIR/dup2.txt"
cat "$TEST_DIR/dup1.txt" > "$TEST_DIR/dup3.txt"

# Create archive
DEDUP_ARCHIVE="test_dedup.reftar"
$REFTAR create -f "$DEDUP_ARCHIVE" -v "$TEST_DIR"/*.txt > /dev/null 2>&1

DEDUP_ARCHIVE_SIZE=$(get_size "$DEDUP_ARCHIVE")
echo "  Dedup archive size: $DEDUP_ARCHIVE_SIZE bytes"

# Extract and verify
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"
$REFTAR extract -f "$DEDUP_ARCHIVE" -C "$RESTORE_DIR" > /dev/null 2>&1

if cmp -s "$TEST_DIR/dup1.txt" "$RESTORE_DIR/dup1.txt" && \
   cmp -s "$TEST_DIR/dup2.txt" "$RESTORE_DIR/dup2.txt" && \
   cmp -s "$TEST_DIR/dup3.txt" "$RESTORE_DIR/dup3.txt"; then
    echo "  ✓ Deduplicated files extracted correctly"
    pass_test
else
    fail_test "Deduplicated files don't match"
fi

rm -f "$DEDUP_ARCHIVE"

# ============================================================================
# Test 8: Test with sparse files
# ============================================================================
run_test "Testing sparse file handling"

# Create a sparse file (10MB with holes)
dd if=/dev/zero of="$TEST_DIR/sparse.bin" bs=1M seek=10 count=0 2>/dev/null

# Write some data at the beginning and end
echo "Start" > "$TEST_DIR/sparse.bin"
dd if=/dev/urandom of="$TEST_DIR/sparse.bin" bs=1K seek=10230 count=10 conv=notrunc 2>/dev/null

SPARSE_APPARENT=$(get_size "$TEST_DIR/sparse.bin")
SPARSE_ACTUAL=$(du -b "$TEST_DIR/sparse.bin" | cut -f1)

echo "  Sparse file apparent size: $SPARSE_APPARENT bytes"
echo "  Sparse file actual size: $SPARSE_ACTUAL bytes"

# Create archive with sparse file
SPARSE_ARCHIVE="test_sparse.reftar"
$REFTAR create -f "$SPARSE_ARCHIVE" "$TEST_DIR/sparse.bin" > /dev/null 2>&1

# Extract
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"
$REFTAR extract -f "$SPARSE_ARCHIVE" -C "$RESTORE_DIR" > /dev/null 2>&1

# Verify
RESTORED_SIZE=$(get_size "$RESTORE_DIR/sparse.bin")
if [ "$RESTORED_SIZE" -eq "$SPARSE_APPARENT" ]; then
    echo "  ✓ Sparse file size preserved"

    # Compare contents
    if cmp -s "$TEST_DIR/sparse.bin" "$RESTORE_DIR/sparse.bin"; then
        echo "  ✓ Sparse file contents match"
        pass_test
    else
        fail_test "Sparse file contents don't match"
    fi
else
    fail_test "Sparse file size mismatch: expected $SPARSE_APPARENT, got $RESTORED_SIZE"
fi

rm -f "$SPARSE_ARCHIVE"

# ============================================================================
# Test 9: Test with large files (multiple blocks)
# ============================================================================
run_test "Testing large file handling (multiple extents)"

# Create a larger file (20MB)
dd if=/dev/urandom of="$TEST_DIR/large.bin" bs=1M count=20 2>/dev/null

# Create archive
LARGE_ARCHIVE="test_large.reftar"
$REFTAR create -f "$LARGE_ARCHIVE" -v "$TEST_DIR/large.bin" > /dev/null 2>&1

echo "  Large file size: $(get_size "$TEST_DIR/large.bin") bytes"
echo "  Archive size: $(get_size "$LARGE_ARCHIVE") bytes"

# Extract
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"
$REFTAR extract -f "$LARGE_ARCHIVE" -C "$RESTORE_DIR" -v > /dev/null 2>&1

# Verify with checksum
ORIG_CHECKSUM=$(sha256sum "$TEST_DIR/large.bin" | cut -d' ' -f1)
RESTORED_CHECKSUM=$(sha256sum "$RESTORE_DIR/large.bin" | cut -d' ' -f1)

echo "  Original checksum:  $ORIG_CHECKSUM"
echo "  Restored checksum:  $RESTORED_CHECKSUM"

if [ "$ORIG_CHECKSUM" = "$RESTORED_CHECKSUM" ]; then
    pass_test
else
    fail_test "Checksums don't match"
fi

rm -f "$LARGE_ARCHIVE"

# ============================================================================
# Test 10: Test archive info command
# ============================================================================
run_test "Testing archive info command"

$REFTAR info -f "$ARCHIVE" > /tmp/reftar_info.txt

if grep -q "Format version: 1" /tmp/reftar_info.txt && \
   grep -q "Block size: 4096" /tmp/reftar_info.txt; then
    echo "  ✓ Archive info shows correct format"
    pass_test
else
    fail_test "Archive info missing expected fields"
fi

rm -f /tmp/reftar_info.txt

# ============================================================================
# Summary
# ============================================================================
echo "=========================================="
echo "Test Results:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "=========================================="

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! ✓${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. ✗${NC}"
    exit 1
fi
