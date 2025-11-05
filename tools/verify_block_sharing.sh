#!/bin/bash
# Verify that blocks are shared between files
# Uses checksums to identify duplicate blocks across files

set -e

# Default configuration
BLOCK_SIZE_KB=64
DIRECTORY="test_data"
REPORT_FILE=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] DIRECTORY

Analyze files in DIRECTORY to detect shared data blocks.

Options:
    -b BLOCK_SIZE_KB    Block size for analysis in KB (default: 64)
    -o REPORT_FILE      Save detailed report to file
    -h                  Show this help

Examples:
    # Analyze test_data directory
    $0 test_data

    # Analyze with custom block size
    $0 -b 128 restored

    # Save detailed report
    $0 -o report.txt test_data
EOF
}

while getopts "b:o:h" opt; do
    case $opt in
        b) BLOCK_SIZE_KB=$OPTARG ;;
        o) REPORT_FILE=$OPTARG ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

shift $((OPTIND-1))

if [ $# -eq 1 ]; then
    DIRECTORY="$1"
fi

if [ ! -d "$DIRECTORY" ]; then
    echo "Error: Directory not found: $DIRECTORY"
    exit 1
fi

BLOCK_SIZE_BYTES=$((BLOCK_SIZE_KB * 1024))

echo "=== Block Sharing Analysis ==="
echo "Directory: $DIRECTORY"
echo "Block size: ${BLOCK_SIZE_KB}KB"
echo

# Find all files (excluding hidden and metadata files)
FILES=($(find "$DIRECTORY" -type f ! -path "*/.*" ! -name "*.txt" ! -name "*.md" | sort))

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files found in $DIRECTORY"
    exit 1
fi

echo "Analyzing ${#FILES[@]} files..."
echo

# Create temp directory for block checksums
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Extract and hash blocks from each file
declare -A BLOCK_MAP  # Maps "checksum" -> "count"
declare -A BLOCK_LOCATIONS  # Maps "checksum" -> "file:block_num file:block_num ..."
TOTAL_BLOCKS=0

for file in "${FILES[@]}"; do
    filename=$(basename "$file")
    filesize=$(stat -c %s "$file")
    num_blocks=$(( (filesize + BLOCK_SIZE_BYTES - 1) / BLOCK_SIZE_BYTES ))

    echo -n "  Scanning $filename: $num_blocks blocks..."

    for block_num in $(seq 0 $((num_blocks - 1))); do
        offset=$((block_num * BLOCK_SIZE_BYTES))

        # Read block and calculate checksum
        checksum=$(dd if="$file" bs=$BLOCK_SIZE_BYTES skip=$block_num count=1 2>/dev/null | sha256sum | cut -d' ' -f1)

        # Track this block
        if [ -z "${BLOCK_MAP[$checksum]}" ]; then
            BLOCK_MAP[$checksum]=1
            BLOCK_LOCATIONS[$checksum]="$filename:$block_num"
        else
            BLOCK_MAP[$checksum]=$((${BLOCK_MAP[$checksum]} + 1))
            BLOCK_LOCATIONS[$checksum]="${BLOCK_LOCATIONS[$checksum]} $filename:$block_num"
        fi

        TOTAL_BLOCKS=$((TOTAL_BLOCKS + 1))
    done

    echo " done"
done

echo
echo "=== Analysis Results ==="
echo

# Count unique blocks and shared blocks
UNIQUE_BLOCKS=0
SHARED_BLOCKS=0
TOTAL_SHARED_INSTANCES=0

for checksum in "${!BLOCK_MAP[@]}"; do
    count=${BLOCK_MAP[$checksum]}
    if [ $count -eq 1 ]; then
        UNIQUE_BLOCKS=$((UNIQUE_BLOCKS + 1))
    else
        SHARED_BLOCKS=$((SHARED_BLOCKS + 1))
        TOTAL_SHARED_INSTANCES=$((TOTAL_SHARED_INSTANCES + count))
    fi
done

echo "Block Statistics:"
echo "  Total blocks analyzed: $TOTAL_BLOCKS"
echo "  Unique blocks: $UNIQUE_BLOCKS"
echo "  Shared blocks (appear > 1 time): $SHARED_BLOCKS"
echo "  Total shared instances: $TOTAL_SHARED_INSTANCES"
echo

DEDUP_RATIO=$(( (TOTAL_BLOCKS - UNIQUE_BLOCKS - SHARED_BLOCKS) * 100 / TOTAL_BLOCKS ))
echo "Deduplication Potential:"
echo "  Blocks that could be deduplicated: $((TOTAL_BLOCKS - UNIQUE_BLOCKS - SHARED_BLOCKS))"
echo "  Deduplication ratio: ${DEDUP_RATIO}%"
echo

APPARENT_SIZE=$((TOTAL_BLOCKS * BLOCK_SIZE_KB))
ACTUAL_SIZE=$(((UNIQUE_BLOCKS + SHARED_BLOCKS) * BLOCK_SIZE_KB))
SAVINGS=$(( (APPARENT_SIZE - ACTUAL_SIZE) * 100 / APPARENT_SIZE ))

echo "Storage Efficiency:"
echo "  Apparent size: ${APPARENT_SIZE}KB"
echo "  Actual unique data: ${ACTUAL_SIZE}KB"
echo "  Potential savings: ${SAVINGS}%"
echo

# Show most shared blocks
echo "Top Shared Blocks:"
echo

# Sort by count and show top 10
declare -a SORTED_BLOCKS
for checksum in "${!BLOCK_MAP[@]}"; do
    count=${BLOCK_MAP[$checksum]}
    if [ $count -gt 1 ]; then
        SORTED_BLOCKS+=("$count:$checksum")
    fi
done

IFS=$'\n' SORTED_BLOCKS=($(sort -rn <<<"${SORTED_BLOCKS[*]}"))
unset IFS

shown=0
for entry in "${SORTED_BLOCKS[@]}"; do
    if [ $shown -ge 10 ]; then
        break
    fi

    count=$(echo "$entry" | cut -d: -f1)
    checksum=$(echo "$entry" | cut -d: -f2-)
    short_checksum=${checksum:0:16}

    echo "  Block ${short_checksum}... appears in $count places:"

    # Show locations (limit to first 5)
    locations=(${BLOCK_LOCATIONS[$checksum]})
    display_count=0
    for loc in "${locations[@]}"; do
        if [ $display_count -ge 5 ]; then
            remaining=$((${#locations[@]} - 5))
            echo "    ... and $remaining more"
            break
        fi
        echo "    - $loc"
        display_count=$((display_count + 1))
    done

    echo

    shown=$((shown + 1))
done

# Save detailed report if requested
if [ -n "$REPORT_FILE" ]; then
    echo "=== Detailed Block Sharing Report ===" > "$REPORT_FILE"
    echo "Generated: $(date)" >> "$REPORT_FILE"
    echo "Directory: $DIRECTORY" >> "$REPORT_FILE"
    echo "Block size: ${BLOCK_SIZE_KB}KB" >> "$REPORT_FILE"
    echo >> "$REPORT_FILE"

    echo "Files analyzed:" >> "$REPORT_FILE"
    for file in "${FILES[@]}"; do
        echo "  - $(basename "$file")" >> "$REPORT_FILE"
    done
    echo >> "$REPORT_FILE"

    echo "All shared blocks:" >> "$REPORT_FILE"
    for entry in "${SORTED_BLOCKS[@]}"; do
        count=$(echo "$entry" | cut -d: -f1)
        checksum=$(echo "$entry" | cut -d: -f2-)

        echo >> "$REPORT_FILE"
        echo "Block $checksum (appears $count times):" >> "$REPORT_FILE"
        for loc in ${BLOCK_LOCATIONS[$checksum]}; do
            echo "  $loc" >> "$REPORT_FILE"
        done
    done

    echo
    echo "Detailed report saved to: $REPORT_FILE"
fi

echo
echo "=== Analysis complete ==="
