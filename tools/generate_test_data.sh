#!/bin/bash
# Generate test files with configurable shared block segments
# This creates files that share specific data blocks, simulating reflinked data

set -e

# Default configuration
NUM_FILES=5
MIN_SIZE_KB=100
MAX_SIZE_KB=5000
SHARED_BLOCK_SIZE_KB=64
NUM_SHARED_BLOCKS=10
OUTPUT_DIR="test_data"
SEED=42

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate test files with shared data blocks for reftar testing.

Options:
    -n NUM_FILES           Number of files to generate (default: 5)
    -s MIN_SIZE_KB         Minimum file size in KB (default: 100)
    -S MAX_SIZE_KB         Maximum file size in KB (default: 5000)
    -b SHARED_BLOCK_SIZE   Size of shared blocks in KB (default: 64)
    -c NUM_SHARED_BLOCKS   Number of shared blocks (default: 10)
    -o OUTPUT_DIR          Output directory (default: test_data)
    -r SEED                Random seed for reproducibility (default: 42)
    -h                     Show this help

Examples:
    # Generate 10 files with lots of sharing
    $0 -n 10 -c 20

    # Generate large files with minimal sharing
    $0 -n 5 -S 10000 -c 5

    # Small files with heavy deduplication
    $0 -n 20 -s 50 -S 200 -c 30
EOF
}

while getopts "n:s:S:b:c:o:r:h" opt; do
    case $opt in
        n) NUM_FILES=$OPTARG ;;
        s) MIN_SIZE_KB=$OPTARG ;;
        S) MAX_SIZE_KB=$OPTARG ;;
        b) SHARED_BLOCK_SIZE_KB=$OPTARG ;;
        c) NUM_SHARED_BLOCKS=$OPTARG ;;
        o) OUTPUT_DIR=$OPTARG ;;
        r) SEED=$OPTARG ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

echo "=== Test Data Generator ==="
echo "Configuration:"
echo "  Files: $NUM_FILES"
echo "  Size range: ${MIN_SIZE_KB}KB - ${MAX_SIZE_KB}KB"
echo "  Shared block size: ${SHARED_BLOCK_SIZE_KB}KB"
echo "  Number of shared blocks: $NUM_SHARED_BLOCKS"
echo "  Output directory: $OUTPUT_DIR"
echo "  Random seed: $SEED"
echo

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate shared blocks
SHARED_BLOCKS_DIR="$OUTPUT_DIR/.shared_blocks"
mkdir -p "$SHARED_BLOCKS_DIR"

echo "Generating $NUM_SHARED_BLOCKS shared data blocks..."
for i in $(seq 1 $NUM_SHARED_BLOCKS); do
    dd if=/dev/urandom of="$SHARED_BLOCKS_DIR/block_$i.dat" \
       bs=1K count=$SHARED_BLOCK_SIZE_KB status=none 2>/dev/null
done
echo -e "${GREEN}✓ Shared blocks created${NC}"

# Generate files with shared blocks
echo
echo "Generating $NUM_FILES files with shared blocks..."

# Use seed for reproducible randomness
RANDOM=$SEED

for file_num in $(seq 1 $NUM_FILES); do
    filename="$OUTPUT_DIR/testfile_$(printf "%03d" $file_num).bin"

    # Random file size between min and max
    size_kb=$((MIN_SIZE_KB + RANDOM % (MAX_SIZE_KB - MIN_SIZE_KB + 1)))

    # Calculate number of blocks needed
    num_blocks=$(( (size_kb + SHARED_BLOCK_SIZE_KB - 1) / SHARED_BLOCK_SIZE_KB ))

    echo -n "  File $file_num: ${size_kb}KB ($num_blocks blocks) - "

    # Create file by concatenating blocks
    rm -f "$filename"
    shared_count=0
    unique_count=0

    for block_pos in $(seq 1 $num_blocks); do
        # Randomly decide if this block should be shared (70% chance) or unique (30% chance)
        if [ $((RANDOM % 100)) -lt 70 ] && [ $NUM_SHARED_BLOCKS -gt 0 ]; then
            # Use a shared block
            shared_block_id=$((1 + RANDOM % NUM_SHARED_BLOCKS))
            cat "$SHARED_BLOCKS_DIR/block_$shared_block_id.dat" >> "$filename"
            shared_count=$((shared_count + 1))
        else
            # Generate unique block
            dd if=/dev/urandom bs=1K count=$SHARED_BLOCK_SIZE_KB >> "$filename" 2>/dev/null
            unique_count=$((unique_count + 1))
        fi
    done

    # Trim to exact size
    truncate -s ${size_kb}K "$filename"

    echo "${shared_count} shared, ${unique_count} unique blocks"
done

echo -e "${GREEN}✓ Files generated${NC}"

# Generate metadata file
METADATA_FILE="$OUTPUT_DIR/test_metadata.txt"
cat > "$METADATA_FILE" << EOF
# Test Data Metadata
Generated: $(date)
Configuration:
  num_files=$NUM_FILES
  min_size_kb=$MIN_SIZE_KB
  max_size_kb=$MAX_SIZE_KB
  shared_block_size_kb=$SHARED_BLOCK_SIZE_KB
  num_shared_blocks=$NUM_SHARED_BLOCKS
  seed=$SEED

Files:
EOF

for file_num in $(seq 1 $NUM_FILES); do
    filename="testfile_$(printf "%03d" $file_num).bin"
    size=$(stat -c %s "$OUTPUT_DIR/$filename")
    checksum=$(sha256sum "$OUTPUT_DIR/$filename" | cut -d' ' -f1)
    echo "  $filename: size=$size bytes, sha256=$checksum" >> "$METADATA_FILE"
done

echo
echo "Metadata saved to: $METADATA_FILE"

# Calculate statistics
echo
echo "Statistics:"
TOTAL_SIZE=$(du -sb "$OUTPUT_DIR"/testfile_*.bin | awk '{sum+=$1} END {print sum}')
ACTUAL_DISK=$(du -sb "$OUTPUT_DIR"/testfile_*.bin | awk '{sum+=$1} END {print sum}')
SHARED_BLOCKS_SIZE=$(du -sb "$SHARED_BLOCKS_DIR" | cut -f1)

echo "  Total apparent size: $(( TOTAL_SIZE / 1024 ))KB"
echo "  Shared blocks library: $(( SHARED_BLOCKS_SIZE / 1024 ))KB"
echo "  Theoretical max deduplication: $(( (TOTAL_SIZE - SHARED_BLOCKS_SIZE) * 100 / TOTAL_SIZE ))%"

# Check if we're on btrfs and can use reflinks
if [ "$(stat -f -c %T "$OUTPUT_DIR" 2>/dev/null)" = "btrfs" ]; then
    echo
    echo -e "${YELLOW}Note: On btrfs filesystem - you can use cp --reflink to create reflinked copies${NC}"
fi

echo
echo "=== Test data generation complete ==="
echo "Files are in: $OUTPUT_DIR"
