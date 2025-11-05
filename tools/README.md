# Reftar Testing Tools

This directory contains comprehensive testing and verification tools for reftar's reflink and deduplication capabilities.

## Tools Overview

### 1. `generate_test_data.sh` - Test Data Generator
Creates files with configurable shared data blocks for testing deduplication.

**Usage:**
```bash
./tools/generate_test_data.sh [OPTIONS]

Options:
  -n NUM_FILES          Number of files (default: 5)
  -s MIN_SIZE_KB        Minimum file size in KB (default: 100)
  -S MAX_SIZE_KB        Maximum file size in KB (default: 5000)
  -b SHARED_BLOCK_SIZE  Shared block size in KB (default: 64)
  -c NUM_SHARED_BLOCKS  Number of shared blocks (default: 10)
  -o OUTPUT_DIR         Output directory (default: test_data)
  -r SEED               Random seed for reproducibility (default: 42)
```

**Examples:**
```bash
# Generate 10 files with moderate sharing
./tools/generate_test_data.sh -n 10 -c 20

# Generate large files with minimal sharing
./tools/generate_test_data.sh -n 5 -S 10000 -c 5

# Heavy deduplication scenario
./tools/generate_test_data.sh -n 30 -s 100 -S 500 -c 50
```

**What it does:**
- Creates a library of shared data blocks
- Generates files by combining shared and unique blocks
- Each file has ~70% shared blocks, ~30% unique blocks
- Creates metadata file with checksums
- Reports theoretical deduplication potential

### 2. `verify_block_sharing.sh` - Content-Level Analysis
Analyzes files to detect blocks with identical content (via checksums).

**Usage:**
```bash
./tools/verify_block_sharing.sh [OPTIONS] DIRECTORY

Options:
  -b BLOCK_SIZE_KB  Block size for analysis in KB (default: 64)
  -o REPORT_FILE    Save detailed report to file
```

**Examples:**
```bash
# Analyze test_data directory
./tools/verify_block_sharing.sh test_data

# Analyze with custom block size
./tools/verify_block_sharing.sh -b 128 restored

# Save detailed report
./tools/verify_block_sharing.sh -o report.txt test_data
```

**What it does:**
- Extracts blocks from all files
- Calculates SHA256 checksums for each block
- Identifies blocks with duplicate content
- Shows which files share which blocks
- Calculates deduplication potential
- Reports top shared blocks

**Output:**
- Total blocks analyzed
- Unique vs shared blocks
- Deduplication ratio
- Potential storage savings
- Top 10 most shared blocks with locations

### 3. `verify_physical_sharing.sh` ⭐ NEW - Physical Block Verification
Verifies actual physical block sharing on disk using `filefrag`.

**Usage:**
```bash
./tools/verify_physical_sharing.sh [OPTIONS] DIRECTORY

Options:
  -o REPORT_FILE  Save detailed report to file
  -v              Verbose output
```

**Examples:**
```bash
# Check if files physically share blocks
./tools/verify_physical_sharing.sh test_data

# Verbose output with detailed report
./tools/verify_physical_sharing.sh -v -o sharing.txt restored
```

**What it does:**
- Uses `filefrag -v` to get physical block information
- Detects "shared" extent flags set by filesystem
- Maps physical block numbers to files
- Identifies blocks shared by multiple files
- Verifies actual reflink usage (not just content similarity)

**Requirements:**
- `filefrag` command (from e2fsprogs package)
- Reflink-capable filesystem (btrfs, XFS, ext4)

**Output:**
- Filesystem type and reflink capability
- Number of physically shared blocks
- Which files share which physical blocks
- Per-file sharing statistics
- Reflink flags on each file

**Key Difference:** This tool verifies *actual* physical sharing on disk, not just content similarity. It answers "Are these files using reflinks?" not just "Do these files have duplicate content?"

### 4. `test_reftar_full_cycle.sh` - Complete Test Cycle
Runs a complete test: generate → archive → restore → verify.

**Usage:**
```bash
./tools/test_reftar_full_cycle.sh [OPTIONS]

Options:
  -n NUM_FILES           Number of files (default: 10)
  -s MIN_SIZE_KB         Minimum size (default: 100)
  -S MAX_SIZE_KB         Maximum size (default: 2000)
  -b SHARED_BLOCK_SIZE   Shared block size (default: 64)
  -c NUM_SHARED_BLOCKS   Number of shared blocks (default: 15)
  -k                     Keep test files after completion
```

**Examples:**
```bash
# Small fast test
./tools/test_reftar_full_cycle.sh -n 5 -s 50 -S 500 -c 10

# Medium test (default)
./tools/test_reftar_full_cycle.sh

# Large test with heavy deduplication
./tools/test_reftar_full_cycle.sh -n 20 -s 500 -S 5000 -c 30

# Keep test files for inspection
./tools/test_reftar_full_cycle.sh -k
```

**Test Phases:**
1. Generate test data with shared blocks
2. Analyze original block sharing (content-level)
3. Create archive with reftar
4. Extract archive
5. Verify file contents (checksums)
6. Analyze restored block sharing
7. Compare original vs restored sharing
8. Performance summary

**Reports:**
- Creation/extraction time and speed
- Archive compression ratio
- Deduplication effectiveness
- Block sharing comparison
- All checksums verified

### 5. `demo_reflink_testing.sh` - Interactive Demonstration
Demonstrates all testing capabilities in a guided walkthrough.

**Usage:**
```bash
./tools/demo_reflink_testing.sh
```

**What it does:**
- Creates reflinked files on btrfs
- Verifies physical block sharing
- Analyzes content-level sharing
- Creates and extracts archive
- Compares all results
- Shows current limitations

**Perfect for:**
- Understanding reftar capabilities
- Seeing all tools in action
- Verifying installation
- Demonstrating to others

## Testing Workflows

### Quick Verification
```bash
# Create some test files
dd if=/dev/urandom of=test_data/file1.bin bs=1M count=5
cp --reflink=always test_data/file1.bin test_data/file2.bin
cp --reflink=always test_data/file1.bin test_data/file3.bin

# Verify physical sharing
./tools/verify_physical_sharing.sh test_data
```

### Complete Test Suite
```bash
# Run full test cycle with custom configuration
./tools/test_reftar_full_cycle.sh -n 10 -c 20 -k

# Inspect results
cat test_reftar_cycle/original_analysis.txt
cat test_reftar_cycle/restored_analysis.txt
```

### Content vs Physical Comparison
```bash
# Generate test data
./tools/generate_test_data.sh -n 5 -c 15

# Check content-level sharing
./tools/verify_block_sharing.sh test_data

# Check physical sharing (requires btrfs)
./tools/verify_physical_sharing.sh test_data
```

### Benchmark Deduplication
```bash
# Heavy deduplication scenario
./tools/generate_test_data.sh -n 30 -s 100 -S 500 -c 50

# Create archive
./target/release/reftar create -f test.reftar test_data/*.bin

# Compare sizes
du -sh test_data  # Apparent size
ls -lh test.reftar  # Archive size with deduplication
```

## Understanding the Output

### Content-Level Sharing (verify_block_sharing.sh)
```
Total blocks analyzed: 100
Unique blocks: 40
Shared blocks: 10
Deduplication ratio: 50%
```
**Meaning:** 50% of blocks have duplicate content that could be deduplicated.

### Physical Sharing (verify_physical_sharing.sh)
```
✓ Found 5 physically shared blocks
Physical block 12345 shared by:
  - file1.bin
  - file2.bin
```
**Meaning:** Files actually share physical disk blocks (reflinks are working).

### Key Distinction
- **Content sharing** = blocks with same data (potential for dedup)
- **Physical sharing** = blocks actually shared on disk (reflinks working)

Reftar handles content sharing (deduplication in archive).
Physical sharing (reflinks) requires both:
1. Source files with reflinks
2. Extraction with reflink support (not yet implemented)

## Requirements

### All Tools
- Bash 4.0+
- Standard Unix utilities (dd, du, find, stat)

### verify_physical_sharing.sh
- `filefrag` command (e2fsprogs package)
- Reflink-capable filesystem for meaningful results

### Installation
```bash
# Debian/Ubuntu
sudo apt-get install e2fsprogs

# RHEL/CentOS
sudo yum install e2fsprogs

# Arch
sudo pacman -S e2fsprogs
```

## Current Status

✅ **Working:**
- Test data generation with configurable sharing
- Content-level deduplication analysis
- Physical block sharing verification
- Full archive/extract cycle testing
- Checksum verification

⚠️ **Limitations:**

- Physical sharing verification requires Linux + reflink supported filesystem

## See Also

- [REFLINK_STATUS.md](../REFLINK_STATUS.md) - Detailed reflink implementation status
- [TEST_RESULTS.md](../TEST_RESULTS.md) - Comprehensive test results
- [USAGE.md](../USAGE.md) - Reftar usage guide
- [FILEFORMAT.md](../docs/FILEFORMAT.md) - Archive format specification
