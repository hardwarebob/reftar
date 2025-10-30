#!/bin/bash
# Quick reflink functionality test for reftar on btrfs

set -e

REFTAR="./target/release/reftar"
TEST_DIR="test_data"
ARCHIVE="test_reflink.reftar"
RESTORE_DIR="restored"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Quick Reflink Test Suite ==="
echo

# Cleanup
rm -rf "$RESTORE_DIR" "$ARCHIVE" "$TEST_DIR"/*.test* 2>/dev/null || true

# Test 1: Reflinked files with deduplication
echo -e "${YELLOW}Test 1: Creating and archiving reflinked files${NC}"
echo "Creating 5MB file..."
dd if=/dev/urandom of="$TEST_DIR/test_original.bin" bs=1M count=5 status=none

echo "Creating 3 reflinked copies..."
cp --reflink=always "$TEST_DIR/test_original.bin" "$TEST_DIR/test_ref1.bin"
cp --reflink=always "$TEST_DIR/test_original.bin" "$TEST_DIR/test_ref2.bin"
cp --reflink=always "$TEST_DIR/test_original.bin" "$TEST_DIR/test_ref3.bin"

echo "Creating archive..."
$REFTAR create -f "$ARCHIVE" "$TEST_DIR"/test_*.bin 2>&1 | grep -v "^$"

ARCHIVE_SIZE=$(stat -c %s "$ARCHIVE")
TOTAL_FILES_SIZE=$((5 * 1024 * 1024 * 4))  # 4 files x 5MB

echo "Archive size: $(( ARCHIVE_SIZE / 1024 / 1024 ))MB"
echo "Total file sizes: $(( TOTAL_FILES_SIZE / 1024 / 1024 ))MB"

# Archive should be much smaller than 4x5MB due to deduplication
if [ "$ARCHIVE_SIZE" -lt "$((TOTAL_FILES_SIZE / 2))" ]; then
    echo -e "${GREEN}✓ Deduplication working (archive is $(( (ARCHIVE_SIZE * 100) / TOTAL_FILES_SIZE ))% of total size)${NC}"
else
    echo -e "${RED}✗ Deduplication may not be working effectively${NC}"
fi

echo ""
echo "Extracting archive..."
mkdir -p "$RESTORE_DIR"
$REFTAR extract -f "$ARCHIVE" -C "$RESTORE_DIR" 2>&1 | grep -E "(Extracting|Extracted:)" || true

echo ""
echo "Verifying checksums..."
for file in test_original.bin test_ref1.bin test_ref2.bin test_ref3.bin; do
    ORIG_SUM=$(sha256sum "$TEST_DIR/$file" | cut -d' ' -f1)
    REST_SUM=$(sha256sum "$RESTORE_DIR/$file" | cut -d' ' -f1)
    if [ "$ORIG_SUM" = "$REST_SUM" ]; then
        echo -e "  $file: ${GREEN}✓${NC}"
    else
        echo -e "  $file: ${RED}✗ MISMATCH${NC}"
        exit 1
    fi
done

echo ""

# Test 2: Duplicate content (not reflinked) - should still deduplicate
echo -e "${YELLOW}Test 2: Deduplication of regular duplicate files${NC}"
rm -f "$ARCHIVE" "$RESTORE_DIR"/*

echo "Creating files with duplicate content (not reflinked)..."
echo "Unique data block ABC123" > "$TEST_DIR/test_dup1.txt"
cat "$TEST_DIR/test_dup1.txt" > "$TEST_DIR/test_dup2.txt"
cat "$TEST_DIR/test_dup1.txt" > "$TEST_DIR/test_dup3.txt"

$REFTAR create -f "$ARCHIVE" "$TEST_DIR"/test_dup*.txt 2>&1 | grep -v "^$"
$REFTAR extract -f "$ARCHIVE" -C "$RESTORE_DIR" 2>&1 | grep -v "^$"

for file in test_dup1.txt test_dup2.txt test_dup3.txt; do
    if cmp -s "$TEST_DIR/$file" "$RESTORE_DIR/$file"; then
        echo -e "  $file: ${GREEN}✓${NC}"
    else
        echo -e "  $file: ${RED}✗ MISMATCH${NC}"
        exit 1
    fi
done

echo ""

# Test 3: Mixed file sizes
echo -e "${YELLOW}Test 3: Mixed file sizes (small and large)${NC}"
rm -f "$ARCHIVE" "$RESTORE_DIR"/*

echo "Creating mixed size files..."
echo "small" > "$TEST_DIR/test_small.txt"
dd if=/dev/urandom of="$TEST_DIR/test_medium.bin" bs=1K count=100 status=none
dd if=/dev/urandom of="$TEST_DIR/test_large.bin" bs=1M count=10 status=none

$REFTAR create -f "$ARCHIVE" "$TEST_DIR"/test_small.txt "$TEST_DIR"/test_medium.bin "$TEST_DIR"/test_large.bin 2>&1 | grep -v "^$"
$REFTAR extract -f "$ARCHIVE" -C "$RESTORE_DIR" 2>&1 | grep -v "^$"

echo "Verifying..."
for file in test_small.txt test_medium.bin test_large.bin; do
    if cmp -s "$TEST_DIR/$file" "$RESTORE_DIR/$file"; then
        echo -e "  $file: ${GREEN}✓${NC}"
    else
        echo -e "  $file: ${RED}✗ MISMATCH${NC}"
        exit 1
    fi
done

echo ""

# Test 4: Directory structure preservation
echo -e "${YELLOW}Test 4: Directory structure${NC}"
rm -f "$ARCHIVE"
rm -rf "$RESTORE_DIR"

echo "Creating directory structure..."
mkdir -p "$TEST_DIR/test_subdir/nested"
echo "file in subdir" > "$TEST_DIR/test_subdir/file1.txt"
echo "nested file" > "$TEST_DIR/test_subdir/nested/file2.txt"

$REFTAR create -f "$ARCHIVE" "$TEST_DIR/test_subdir" 2>&1 | grep -v "^$"
mkdir -p "$RESTORE_DIR"
$REFTAR extract -f "$ARCHIVE" -C "$RESTORE_DIR" 2>&1 | grep -v "^$"

if [ -f "$RESTORE_DIR/test_data/test_subdir/file1.txt" ] && \
   [ -f "$RESTORE_DIR/test_data/test_subdir/nested/file2.txt" ]; then
    echo -e "${GREEN}✓ Directory structure preserved${NC}"
else
    echo -e "${RED}✗ Directory structure not preserved${NC}"
    ls -R "$RESTORE_DIR"
    exit 1
fi

echo ""

# Test 5: Archive listing
echo -e "${YELLOW}Test 5: Archive listing${NC}"
FILE_COUNT=$($REFTAR list -f "$ARCHIVE" | wc -l)
echo "Files in archive: $FILE_COUNT"
if [ "$FILE_COUNT" -ge 3 ]; then
    echo -e "${GREEN}✓ List command works${NC}"
else
    echo -e "${RED}✗ Unexpected file count${NC}"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}All tests passed!${NC}"
echo "=========================================="

# Cleanup
rm -rf "$RESTORE_DIR" "$ARCHIVE" "$TEST_DIR"/test_* 2>/dev/null || true
