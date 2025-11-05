#!/bin/bash
# Verify that blocks are physically shared between files (reflinks)
# Uses filefrag, FIEMAP, and other tools to check actual physical block sharing

set -e

DIRECTORY="test_data"
REPORT_FILE=""
VERBOSE=false

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] DIRECTORY

Verify physical block sharing (reflinks) between files in DIRECTORY.
This checks if files actually share physical disk blocks, not just content.

Options:
    -o REPORT_FILE      Save detailed report to file
    -v                  Verbose output
    -h                  Show this help

Requirements:
    - filefrag command (part of e2fsprogs)
    - Files must be on a reflink-capable filesystem (btrfs, XFS, etc.)

Examples:
    # Check test_data directory
    $0 test_data

    # Verbose output with report
    $0 -v -o sharing_report.txt restored
EOF
}

while getopts "o:vh" opt; do
    case $opt in
        o) REPORT_FILE=$OPTARG ;;
        v) VERBOSE=true ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

shift $((OPTIND-1))

if [ $# -eq 1 ]; then
    DIRECTORY="$1"
fi

if [ ! -d "$DIRECTORY" ]; then
    echo -e "${RED}Error: Directory not found: $DIRECTORY${NC}"
    exit 1
fi

# Check for required tools
if ! command -v filefrag &> /dev/null; then
    echo -e "${RED}Error: filefrag command not found${NC}"
    echo "Please install e2fsprogs package"
    exit 1
fi

echo "=== Physical Block Sharing Verification ==="
echo "Directory: $DIRECTORY"
echo

# Check filesystem type
FS_TYPE=$(stat -f -c %T "$DIRECTORY" 2>/dev/null || echo "unknown")
echo "Filesystem: $FS_TYPE"

case $FS_TYPE in
    btrfs|xfs)
        echo -e "${GREEN}✓ Filesystem supports reflinks${NC}"
        ;;
    ext4)
        echo -e "${YELLOW}⚠ ext4 may support reflinks (depends on kernel version)${NC}"
        ;;
    *)
        echo -e "${YELLOW}⚠ Unknown if filesystem supports reflinks${NC}"
        ;;
esac
echo

# Find all regular files
FILES=($(find "$DIRECTORY" -type f ! -path "*/.*" ! -name "*.txt" ! -name "*.md" | sort))

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files found in $DIRECTORY"
    exit 1
fi

echo "Analyzing ${#FILES[@]} files for physical block sharing..."
echo

# Function to get physical block numbers for a file using filefrag
get_physical_blocks() {
    local file="$1"
    # Use filefrag -v to get verbose output with physical block numbers
    # Format: ext logical_start..logical_end: physical_start..physical_end: length: flags
    filefrag -v "$file" 2>/dev/null | grep -E "^\s*[0-9]+" | awk '{print $4}' | sed 's/\.\./\n/g' | sed 's/://g' | sort -n
}

# Function to check if a file has shared extents using filefrag
has_shared_extents() {
    local file="$1"
    filefrag -v "$file" 2>/dev/null | grep -q "shared" && return 0 || return 1
}

# Create temp directory for analysis
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Extract physical block information for each file
declare -A FILE_BLOCKS  # Maps filename -> list of physical blocks
declare -A BLOCK_FILES  # Maps physical_block -> list of files using it
TOTAL_SHARED_BLOCKS=0
TOTAL_BLOCKS=0

echo "Phase 1: Extracting physical block information..."
echo

for file in "${FILES[@]}"; do
    filename=$(basename "$file")

    if [ "$VERBOSE" = true ]; then
        echo -n "  Analyzing $filename... "
    fi

    # Check if file has shared extents flag
    has_shared=false
    if has_shared_extents "$file"; then
        has_shared=true
        if [ "$VERBOSE" = true ]; then
            echo -e "${YELLOW}[has shared flag]${NC}"
        fi
    else
        if [ "$VERBOSE" = true ]; then
            echo "[no shared flag]"
        fi
    fi

    # Get physical blocks
    blocks=$(get_physical_blocks "$file")

    if [ -n "$blocks" ]; then
        echo "$blocks" > "$TEMP_DIR/${filename}.blocks"

        # Track which files use which blocks
        for block in $blocks; do
            if [ -z "${BLOCK_FILES[$block]}" ]; then
                BLOCK_FILES[$block]="$filename"
            else
                BLOCK_FILES[$block]="${BLOCK_FILES[$block]} $filename"
            fi
            TOTAL_BLOCKS=$((TOTAL_BLOCKS + 1))
        done
    fi
done

if [ "$VERBOSE" = false ]; then
    echo "  Done"
fi

echo
echo "Phase 2: Analyzing shared physical blocks..."
echo

# Find blocks that are used by multiple files
SHARED_BLOCKS=0
SHARED_BLOCK_LIST=()

for block in "${!BLOCK_FILES[@]}"; do
    files=(${BLOCK_FILES[$block]})
    if [ ${#files[@]} -gt 1 ]; then
        SHARED_BLOCKS=$((SHARED_BLOCKS + 1))
        SHARED_BLOCK_LIST+=("$block:${BLOCK_FILES[$block]}")
    fi
done

# Results
echo "=== Results ==="
echo

if [ $SHARED_BLOCKS -eq 0 ]; then
    echo -e "${RED}✗ No physically shared blocks found${NC}"
    echo
    echo "Possible reasons:"
    echo "  - Files were copied instead of reflinked"
    echo "  - Filesystem doesn't support reflinks"
    echo "  - Files don't have overlapping content"
else
    echo -e "${GREEN}✓ Found $SHARED_BLOCKS physically shared blocks${NC}"
    echo

    SHARING_RATIO=$(( SHARED_BLOCKS * 100 / (${#BLOCK_FILES[@]} + 1) ))
    echo "Statistics:"
    echo "  Total unique physical blocks: ${#BLOCK_FILES[@]}"
    echo "  Blocks shared between files: $SHARED_BLOCKS"
    echo "  Sharing ratio: ${SHARING_RATIO}%"
    echo

    # Show details of shared blocks
    echo "Shared Blocks Details:"
    echo

    shown=0
    for entry in "${SHARED_BLOCK_LIST[@]}"; do
        if [ $shown -ge 10 ]; then
            remaining=$((${#SHARED_BLOCK_LIST[@]} - 10))
            echo "  ... and $remaining more shared blocks"
            break
        fi

        block=$(echo "$entry" | cut -d: -f1)
        files=$(echo "$entry" | cut -d: -f2-)

        echo "  Physical block $block shared by:"
        for f in $files; do
            echo "    - $f"
        done
        echo

        shown=$((shown + 1))
    done
fi

# Check for files that should be sharing but aren't
echo "File-by-File Analysis:"
echo

for i in "${!FILES[@]}"; do
    file1="${FILES[$i]}"
    filename1=$(basename "$file1")

    # Check if this file has the shared extent flag
    shared_flag=""
    if has_shared_extents "$file1"; then
        shared_flag=" ${GREEN}[reflinked]${NC}"
    fi

    echo -e "  $filename1$shared_flag"

    # Count how many blocks this file shares with others
    if [ -f "$TEMP_DIR/${filename1}.blocks" ]; then
        file1_blocks=$(cat "$TEMP_DIR/${filename1}.blocks")
        shared_with_others=0

        for block in $file1_blocks; do
            files=(${BLOCK_FILES[$block]})
            if [ ${#files[@]} -gt 1 ]; then
                shared_with_others=$((shared_with_others + 1))
            fi
        done

        total_blocks=$(echo "$file1_blocks" | wc -l)
        if [ $shared_with_others -gt 0 ]; then
            share_pct=$(( shared_with_others * 100 / total_blocks ))
            echo "    Shares $shared_with_others/$total_blocks blocks (${share_pct}%) with other files"
        else
            echo "    No blocks shared with other files"
        fi
    fi
done

echo

# Save detailed report if requested
if [ -n "$REPORT_FILE" ]; then
    {
        echo "=== Physical Block Sharing Report ==="
        echo "Generated: $(date)"
        echo "Directory: $DIRECTORY"
        echo "Filesystem: $FS_TYPE"
        echo
        echo "Files analyzed: ${#FILES[@]}"
        echo "Total unique physical blocks: ${#BLOCK_FILES[@]}"
        echo "Physically shared blocks: $SHARED_BLOCKS"
        echo
        echo "=== Detailed Sharing Information ==="
        echo

        for entry in "${SHARED_BLOCK_LIST[@]}"; do
            block=$(echo "$entry" | cut -d: -f1)
            files=$(echo "$entry" | cut -d: -f2-)

            echo "Physical block $block:"
            for f in $files; do
                echo "  $f"
            done
            echo
        done

        echo "=== Per-File Physical Block Map ==="
        echo

        for file in "${FILES[@]}"; do
            filename=$(basename "$file")
            echo "$filename:"

            if has_shared_extents "$file"; then
                echo "  [Has shared extents flag]"
            fi

            if [ -f "$TEMP_DIR/${filename}.blocks" ]; then
                echo "  Physical blocks:"
                cat "$TEMP_DIR/${filename}.blocks" | head -20
                block_count=$(cat "$TEMP_DIR/${filename}.blocks" | wc -l)
                if [ $block_count -gt 20 ]; then
                    echo "  ... and $((block_count - 20)) more blocks"
                fi
            fi
            echo
        done
    } > "$REPORT_FILE"

    echo "Detailed report saved to: $REPORT_FILE"
    echo
fi

# Summary with color coding
echo "=== Summary ==="
echo

if [ $SHARED_BLOCKS -gt 0 ]; then
    echo -e "${GREEN}✓ Physical block sharing verified${NC}"
    echo "Files in this directory share physical disk blocks (reflinks working)"
    exit 0
else
    echo -e "${YELLOW}⚠ No physical block sharing detected${NC}"
    echo "Files may have duplicate content but don't share physical blocks"
    exit 1
fi
