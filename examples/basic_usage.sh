#!/bin/bash
# Basic usage examples for reftar

set -e

echo "=== Reftar Basic Usage Examples ==="
echo

# Build reftar if not already built
if [ ! -f "../target/release/reftar" ]; then
    echo "Building reftar..."
    cd ..
    cargo build --release
    cd examples
    echo
fi

REFTAR="../target/release/reftar"

# Create test data
echo "Creating test data..."
mkdir -p test_data
echo "Hello, World!" > test_data/file1.txt
echo "This is file 2" > test_data/file2.txt
echo "Hello, World!" > test_data/duplicate.txt  # Duplicate content for dedup demo
mkdir -p test_data/subdir
echo "Nested file" > test_data/subdir/nested.txt

# Create a larger file to demonstrate block-based storage
dd if=/dev/urandom of=test_data/large_file.bin bs=1M count=1 2>/dev/null

echo "Test data created"
echo

# Example 1: Create an archive
echo "Example 1: Creating an archive"
$REFTAR create -f test_archive.reftar -v test_data/
echo

# Example 2: Show archive info
echo "Example 2: Showing archive information"
$REFTAR info -f test_archive.reftar
echo

# Example 3: List archive contents
echo "Example 3: Listing archive contents"
$REFTAR list -f test_archive.reftar
echo

# Example 4: Extract the archive
echo "Example 4: Extracting archive"
mkdir -p extracted
$REFTAR extract -f test_archive.reftar -C extracted -v
echo

# Example 5: Verify extraction
echo "Example 5: Verifying extracted files"
echo "Original file1.txt:"
cat test_data/file1.txt
echo "Extracted file1.txt:"
cat extracted/file1.txt
echo

# Example 6: Create archive with custom block size
echo "Example 6: Creating archive with 8KB block size"
$REFTAR create -f test_archive_8k.reftar -b 8192 test_data/
echo

# Compare archive sizes
echo "Archive size comparison:"
ls -lh test_archive.reftar test_archive_8k.reftar
echo

# Cleanup
echo "Cleaning up test files..."
rm -rf test_data extracted test_archive.reftar test_archive_8k.reftar

echo "=== Examples completed ==="
