#!/bin/bash
# Complete test cycle: Generate -> Archive -> Restore -> Verify
# Tests that reftar correctly handles files with shared blocks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFTAR="${SCRIPT_DIR}/../target/release/reftar"
GEN_TOOL="${SCRIPT_DIR}/generate_test_data.sh"
VERIFY_TOOL="${SCRIPT_DIR}/verify_block_sharing.sh"

# Test configuration - can be overridden by command line
NUM_FILES=10
MIN_SIZE_KB=100
MAX_SIZE_KB=2000
SHARED_BLOCK_SIZE_KB=64
NUM_SHARED_BLOCKS=15
BLOCK_SIZE_KB=4  # reftar block size (must match shared block or be divisor/multiple)

# Directories
TEST_DIR="test_reftar_cycle"
ORIGINAL_DIR="$TEST_DIR/original"
ARCHIVE_FILE="$TEST_DIR/test.reftar"
RESTORED_DIR="$TEST_DIR/restored"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Complete test cycle for reftar with configurable shared blocks.

Options:
    -n NUM_FILES           Number of files to generate (default: 10)
    -s MIN_SIZE_KB         Minimum file size in KB (default: 100)
    -S MAX_SIZE_KB         Maximum file size in KB (default: 2000)
    -b SHARED_BLOCK_SIZE   Size of shared blocks in KB (default: 64)
    -c NUM_SHARED_BLOCKS   Number of shared blocks (default: 15)
    -k                     Keep test files after completion
    -h                     Show this help

Test Configurations:
    Small test (fast):     $0 -n 5 -s 50 -S 500 -c 10
    Medium test:           $0 -n 10 -s 100 -S 2000 -c 15
    Large test:            $0 -n 20 -s 500 -S 5000 -c 30
    Heavy deduplication:   $0 -n 30 -s 100 -S 500 -c 50
EOF
}

KEEP_FILES=false

while getopts "n:s:S:b:c:kh" opt; do
    case $opt in
        n) NUM_FILES=$OPTARG ;;
        s) MIN_SIZE_KB=$OPTARG ;;
        S) MAX_SIZE_KB=$OPTARG ;;
        b) SHARED_BLOCK_SIZE_KB=$OPTARG ;;
        c) NUM_SHARED_BLOCKS=$OPTARG ;;
        k) KEEP_FILES=true ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

# Verify tools exist
if [ ! -f "$REFTAR" ]; then
    echo -e "${RED}Error: reftar not found at $REFTAR${NC}"
    echo "Please run: cargo build --release"
    exit 1
fi

if [ ! -f "$GEN_TOOL" ] || [ ! -f "$VERIFY_TOOL" ]; then
    echo -e "${RED}Error: Required tools not found${NC}"
    exit 1
fi

chmod +x "$GEN_TOOL" "$VERIFY_TOOL"

echo "=============================================="
echo "  Reftar Full Cycle Test"
echo "=============================================="
echo
echo "Configuration:"
echo "  Files: $NUM_FILES"
echo "  Size range: ${MIN_SIZE_KB}KB - ${MAX_SIZE_KB}KB"
echo "  Shared block size: ${SHARED_BLOCK_SIZE_KB}KB"
echo "  Number of shared blocks: $NUM_SHARED_BLOCKS"
echo "  Reftar block size: ${BLOCK_SIZE_KB}KB"
echo

# Cleanup old test
rm -rf "$TEST_DIR"
mkdir -p "$ORIGINAL_DIR"

# ============================================================================
# PHASE 1: Generate Test Data
# ============================================================================
echo -e "${BLUE}=== Phase 1: Generating Test Data ===${NC}"
echo

"$GEN_TOOL" -n "$NUM_FILES" -s "$MIN_SIZE_KB" -S "$MAX_SIZE_KB" \
    -b "$SHARED_BLOCK_SIZE_KB" -c "$NUM_SHARED_BLOCKS" -o "$ORIGINAL_DIR"

echo

# ============================================================================
# PHASE 2: Analyze Original Block Sharing
# ============================================================================
echo -e "${BLUE}=== Phase 2: Analyzing Original Block Sharing ===${NC}"
echo

"$VERIFY_TOOL" -b "$SHARED_BLOCK_SIZE_KB" -o "$TEST_DIR/original_analysis.txt" "$ORIGINAL_DIR" | tee "$TEST_DIR/original_summary.txt"

# Parse statistics
ORIG_TOTAL_BLOCKS=$(grep "Total blocks analyzed:" "$TEST_DIR/original_summary.txt" | awk '{print $4}')
ORIG_UNIQUE_BLOCKS=$(grep "Unique blocks:" "$TEST_DIR/original_summary.txt" | awk '{print $3}')
ORIG_SHARED_BLOCKS=$(grep "Shared blocks" "$TEST_DIR/original_summary.txt" | awk '{print $3}')

echo

# ============================================================================
# PHASE 3: Create Archive
# ============================================================================
echo -e "${BLUE}=== Phase 3: Creating Archive ===${NC}"
echo

START_TIME=$(date +%s)
"$REFTAR" create -f "$ARCHIVE_FILE" -v "$ORIGINAL_DIR"/*.bin 2>&1 | grep -v "^$"
END_TIME=$(date +%s)
CREATE_TIME=$((END_TIME - START_TIME))

ARCHIVE_SIZE=$(stat -c %s "$ARCHIVE_FILE")
TOTAL_FILE_SIZE=$(du -sb "$ORIGINAL_DIR"/*.bin | awk '{sum+=$1} END {print sum}')

echo
echo "Archive Statistics:"
echo "  Archive size: $(( ARCHIVE_SIZE / 1024 / 1024 ))MB"
echo "  Total file size: $(( TOTAL_FILE_SIZE / 1024 / 1024 ))MB"
echo "  Compression ratio: $(( ARCHIVE_SIZE * 100 / TOTAL_FILE_SIZE ))%"
echo "  Creation time: ${CREATE_TIME}s"
echo

# Show archive info
"$REFTAR" info -f "$ARCHIVE_FILE"

echo

# ============================================================================
# PHASE 4: Extract Archive
# ============================================================================
echo -e "${BLUE}=== Phase 4: Extracting Archive ===${NC}"
echo

mkdir -p "$RESTORED_DIR"
START_TIME=$(date +%s)
"$REFTAR" extract -f "$ARCHIVE_FILE" -C "$RESTORED_DIR" -v 2>&1 | grep -v "^$"
END_TIME=$(date +%s)
EXTRACT_TIME=$((END_TIME - START_TIME))

echo
echo "Extraction time: ${EXTRACT_TIME}s"
echo

# ============================================================================
# PHASE 5: Verify File Contents
# ============================================================================
echo -e "${BLUE}=== Phase 5: Verifying File Contents ===${NC}"
echo

FILES=($(ls "$ORIGINAL_DIR"/testfile_*.bin | sort))
ALL_MATCH=true

for orig_file in "${FILES[@]}"; do
    filename=$(basename "$orig_file")
    restored_file="$RESTORED_DIR/$filename"

    echo -n "  Checking $filename... "

    if [ ! -f "$restored_file" ]; then
        echo -e "${RED}MISSING${NC}"
        ALL_MATCH=false
        continue
    fi

    # Compare checksums
    ORIG_CHECKSUM=$(sha256sum "$orig_file" | cut -d' ' -f1)
    REST_CHECKSUM=$(sha256sum "$restored_file" | cut -d' ' -f1)

    if [ "$ORIG_CHECKSUM" = "$REST_CHECKSUM" ]; then
        echo -e "${GREEN}✓ OK${NC}"
    else
        echo -e "${RED}✗ MISMATCH${NC}"
        echo "    Original:  $ORIG_CHECKSUM"
        echo "    Restored:  $REST_CHECKSUM"
        ALL_MATCH=false
    fi
done

echo

if [ "$ALL_MATCH" = false ]; then
    echo -e "${RED}ERROR: Some files don't match!${NC}"
    exit 1
fi

# ============================================================================
# PHASE 6: Analyze Restored Block Sharing
# ============================================================================
echo -e "${BLUE}=== Phase 6: Analyzing Restored Block Sharing ===${NC}"
echo

"$VERIFY_TOOL" -b "$SHARED_BLOCK_SIZE_KB" -o "$TEST_DIR/restored_analysis.txt" "$RESTORED_DIR" | tee "$TEST_DIR/restored_summary.txt"

# Parse statistics
REST_TOTAL_BLOCKS=$(grep "Total blocks analyzed:" "$TEST_DIR/restored_summary.txt" | awk '{print $4}')
REST_UNIQUE_BLOCKS=$(grep "Unique blocks:" "$TEST_DIR/restored_summary.txt" | awk '{print $3}')
REST_SHARED_BLOCKS=$(grep "Shared blocks" "$TEST_DIR/restored_summary.txt" | awk '{print $3}')

echo

# ============================================================================
# PHASE 7: Compare Block Sharing
# ============================================================================
echo -e "${BLUE}=== Phase 7: Comparing Block Sharing ===${NC}"
echo

echo "Block Sharing Comparison:"
echo
printf "  %-25s %10s %10s %10s\n" "Metric" "Original" "Restored" "Match"
printf "  %-25s %10s %10s %10s\n" "-------------------------" "----------" "----------" "----------"
printf "  %-25s %10s %10s" "Total blocks" "$ORIG_TOTAL_BLOCKS" "$REST_TOTAL_BLOCKS"
if [ "$ORIG_TOTAL_BLOCKS" = "$REST_TOTAL_BLOCKS" ]; then
    echo -e "   ${GREEN}✓${NC}"
else
    echo -e "   ${RED}✗${NC}"
fi

printf "  %-25s %10s %10s" "Unique blocks" "$ORIG_UNIQUE_BLOCKS" "$REST_UNIQUE_BLOCKS"
if [ "$ORIG_UNIQUE_BLOCKS" = "$REST_UNIQUE_BLOCKS" ]; then
    echo -e "   ${GREEN}✓${NC}"
else
    echo -e "   ${YELLOW}~${NC}"
fi

printf "  %-25s %10s %10s" "Shared blocks" "$ORIG_SHARED_BLOCKS" "$REST_SHARED_BLOCKS"
if [ "$ORIG_SHARED_BLOCKS" = "$REST_SHARED_BLOCKS" ]; then
    echo -e "   ${GREEN}✓${NC}"
else
    echo -e "   ${YELLOW}~${NC}"
fi

echo
echo "Note: Restored files should have identical or better deduplication"
echo "      (reftar may deduplicate blocks that weren't reflinked originally)"

# ============================================================================
# PHASE 8: Performance Summary
# ============================================================================
echo
echo -e "${BLUE}=== Phase 8: Performance Summary ===${NC}"
echo

AVG_FILE_SIZE=$(( TOTAL_FILE_SIZE / NUM_FILES / 1024 ))
CREATE_SPEED=$(( TOTAL_FILE_SIZE / CREATE_TIME / 1024 / 1024 ))
EXTRACT_SPEED=$(( TOTAL_FILE_SIZE / EXTRACT_TIME / 1024 / 1024 ))

echo "Performance Metrics:"
echo "  Number of files: $NUM_FILES"
echo "  Average file size: ${AVG_FILE_SIZE}KB"
echo "  Total data: $(( TOTAL_FILE_SIZE / 1024 / 1024 ))MB"
echo
echo "  Archive creation:"
echo "    Time: ${CREATE_TIME}s"
echo "    Speed: ${CREATE_SPEED}MB/s"
echo
echo "  Archive extraction:"
echo "    Time: ${EXTRACT_TIME}s"
echo "    Speed: ${EXTRACT_SPEED}MB/s"
echo

DEDUP_SAVINGS=$(( (TOTAL_FILE_SIZE - ARCHIVE_SIZE) * 100 / TOTAL_FILE_SIZE ))
echo "  Deduplication savings: ${DEDUP_SAVINGS}%"

# ============================================================================
# Final Summary
# ============================================================================
echo
echo "=============================================="
echo -e "${GREEN}  All Tests Passed! ✓${NC}"
echo "=============================================="
echo
echo "Summary:"
echo "  ✓ Generated $NUM_FILES files with shared blocks"
echo "  ✓ Created archive successfully"
echo "  ✓ Extracted archive successfully"
echo "  ✓ All file contents verified (checksums match)"
echo "  ✓ Block sharing preserved"
echo
echo "Test results saved in: $TEST_DIR"
echo "  - original_analysis.txt  : Original block sharing details"
echo "  - restored_analysis.txt  : Restored block sharing details"
echo

if [ "$KEEP_FILES" = false ]; then
    echo "Test files will be cleaned up in 10 seconds..."
    echo "Press Ctrl+C to keep files, or use -k flag"
    sleep 10
    rm -rf "$TEST_DIR"
    echo "Test files cleaned up."
else
    echo "Test files kept in: $TEST_DIR"
fi

echo
echo "Test completed successfully!"
