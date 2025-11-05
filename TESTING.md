# Testing Reftar

This document provides comprehensive instructions for testing reftar's functionality, including reflink support, deduplication, and archive integrity.

## Quick Start

```bash
# Build reftar
cargo build --release

# Run basic functionality test
./tests/basic_reflink_test.sh

# Verify physical block sharing (requires btrfs)
./tools/verify_physical_sharing.sh test_data
```

## Test Environment Setup

### Required Tools

```bash
# Debian/Ubuntu
sudo apt-get install e2fsprogs btrfs-progs

# RHEL/CentOS
sudo yum install e2fsprogs btrfs-progs

# Arch Linux
sudo pacman -S e2fsprogs btrfs-progs
```

### Setting Up btrfs Test Filesystem

For full reflink testing, you need a btrfs filesystem:

#### Option 1: Use Existing btrfs Partition
```bash
# Check if a directory is on btrfs
stat -f -c %T /path/to/directory
```

#### Option 2: Create Loop Device btrfs (Recommended for Testing)
```bash
# Create 1GB image file
dd if=/dev/zero of=btrfs.img bs=1M count=1024

# Format as btrfs
mkfs.btrfs btrfs.img

# Mount it
sudo mkdir -p /mnt/reftar_test
sudo mount -o loop btrfs.img /mnt/reftar_test

# Set ownership
sudo chown -R $USER:$USER /mnt/reftar_test

# Use for testing
export TEST_DATA=/mnt/reftar_test/test_data
mkdir -p $TEST_DATA
```

#### Option 3: Docker Container with btrfs
```bash
# Create docker volume with btrfs
docker volume create --driver local \
  --opt type=btrfs \
  --opt device=/dev/loop0 \
  reftar_test

# Run container with btrfs volume
docker run -it --rm \
  -v reftar_test:/test_data \
  -v $(pwd):/reftar \
  -w /reftar \
  rust:latest bash
```

## Test Categories

### 1. Basic Functionality Tests

#### Test Archive Creation
```bash
# Create test files
mkdir -p test_data
echo "Hello, reftar!" > test_data/file1.txt
echo "Another file" > test_data/file2.txt
mkdir test_data/subdir
echo "Nested file" > test_data/subdir/file3.txt

# Create archive
./target/release/reftar create -f test.reftar -v test_data/

# Verify archive was created
ls -lh test.reftar
```

#### Test Archive Listing
```bash
# List contents
./target/release/reftar list -f test.reftar

# Verbose listing with statistics
./target/release/reftar list -f test.reftar -v
```

#### Test Archive Information
```bash
# Show archive metadata
./target/release/reftar info -f test.reftar
```

#### Test Extraction
```bash
# Extract to directory
mkdir restored
./target/release/reftar extract -f test.reftar -C restored/ -v

# Verify files
diff -r test_data restored/test_data
```

### 2. Reflink Tests

These tests verify that reftar correctly handles reflinked files and preserves physical block sharing.

#### Test 2.1: Create Reflinked Files
```bash
# Create source file
dd if=/dev/urandom of=test_data/source.bin bs=1M count=5

# Create reflinked copies (requires btrfs/XFS)
cp --reflink=always test_data/source.bin test_data/ref1.bin
cp --reflink=always test_data/source.bin test_data/ref2.bin
cp --reflink=always test_data/source.bin test_data/ref3.bin

# Verify disk usage (should be ~5MB, not 20MB)
du -sh test_data/
```

#### Test 2.2: Verify Physical Sharing (Before Archive)
```bash
# Verify files actually share physical blocks
./tools/verify_physical_sharing.sh -v test_data

# Expected output:
# ✓ Found N physically shared blocks
# ✓ Physical block sharing verified
```

#### Test 2.3: Archive Reflinked Files
```bash
# Create archive
./target/release/reftar create -f reflink_test.reftar -v test_data/*.bin

# Check archive size
# Should be ~5MB + overhead, not 20MB
ls -lh reflink_test.reftar
```

#### Test 2.4: Extract and Verify Reflinks Preserved
```bash
# Extract to btrfs filesystem
mkdir -p test_data/restored
./target/release/reftar extract -f reflink_test.reftar -C test_data/restored -v

# Verify physical block sharing restored
./tools/verify_physical_sharing.sh test_data/restored

# Expected output:
# ✓ Found N physically shared blocks
# ✓ Physical block sharing verified
```

#### Test 2.5: Verify File Contents
```bash
# Check all files match originals
for f in source.bin ref1.bin ref2.bin ref3.bin; do
    echo -n "$f: "
    if cmp -s "test_data/$f" "test_data/restored/$f"; then
        echo "✓ OK"
    else
        echo "✗ MISMATCH"
        exit 1
    fi
done
```

### 3. Deduplication Tests

These tests verify content-level deduplication in the archive format.

#### Test 3.1: Duplicate Content Detection
```bash
# Create files with identical content (not reflinked)
echo "Duplicate data block" > test_data/dup1.txt
cat test_data/dup1.txt > test_data/dup2.txt
cat test_data/dup1.txt > test_data/dup3.txt

# Analyze content sharing
./tools/verify_block_sharing.sh test_data
```

#### Test 3.2: Archive Deduplication
```bash
# Create archive
./target/release/reftar create -f dup_test.reftar test_data/dup*.txt

# Archive should be much smaller than sum of files
ls -lh dup_test.reftar
du -sh test_data/dup*.txt
```

#### Test 3.3: Extract Deduplicated Files
```bash
# Extract
mkdir dup_restored
./target/release/reftar extract -f dup_test.reftar -C dup_restored

# Verify all files
for f in dup1.txt dup2.txt dup3.txt; do
    cmp -s "test_data/$f" "dup_restored/$f" && echo "$f: ✓" || echo "$f: ✗"
done
```

### 4. Mixed File Size Tests

#### Test 4.1: Small Files (Inline Data)
```bash
# Files smaller than block size (4KB) use inline storage
echo "Small file" > test_data/small.txt

./target/release/reftar create -f small.reftar test_data/small.txt
./target/release/reftar extract -f small.reftar -C restored/

cmp -s test_data/small.txt restored/small.txt && echo "✓ Small file OK"
```

#### Test 4.2: Large Files (Multiple Extents)
```bash
# Create 20MB file
dd if=/dev/urandom of=test_data/large.bin bs=1M count=20

./target/release/reftar create -f large.reftar test_data/large.bin
./target/release/reftar extract -f large.reftar -C restored/

# Verify with checksums
sha256sum test_data/large.bin restored/large.bin
```

#### Test 4.3: Sparse Files
```bash
# Create sparse file (10MB apparent, minimal actual)
dd if=/dev/zero of=test_data/sparse.bin bs=1M seek=10 count=0
echo "Start" > test_data/sparse.bin
dd if=/dev/urandom of=test_data/sparse.bin bs=1K seek=10230 count=10 conv=notrunc

# Archive and extract
./target/release/reftar create -f sparse.reftar test_data/sparse.bin
./target/release/reftar extract -f sparse.reftar -C restored/

# Verify size preserved
stat -c %s test_data/sparse.bin
stat -c %s restored/sparse.bin
```

### 5. Directory Structure Tests

#### Test 5.1: Nested Directories
```bash
# Create nested structure
mkdir -p test_data/level1/level2/level3
echo "Deep file" > test_data/level1/level2/level3/deep.txt

./target/release/reftar create -f nested.reftar test_data/level1
./target/release/reftar extract -f nested.reftar -C restored/

# Verify structure
test -f restored/test_data/level1/level2/level3/deep.txt && echo "✓ Structure preserved"
```

#### Test 5.2: Symbolic Links
```bash
# Create symlink
ln -s file1.txt test_data/link.txt

./target/release/reftar create -f symlink.reftar test_data/link.txt test_data/file1.txt
./target/release/reftar extract -f symlink.reftar -C restored/

# Verify symlink
test -L restored/test_data/link.txt && echo "✓ Symlink preserved"
readlink restored/test_data/link.txt
```

### 6. Automated Test Scripts

#### Test 6.1: Basic Reflink Test
```bash
# Fast test with 1MB files
./tests/basic_reflink_test.sh
```

#### Test 6.2: Comprehensive Test Suite
```bash
# Full test suite (may take several minutes)
./tests/reflink_tests.sh
```

#### Test 6.3: Quick Reflink Test
```bash
# Fast reflink verification
./tests/quick_reflink_test.sh
```

#### Test 6.4: Full Cycle Test (Configurable)
```bash
# Small test (fast)
./tools/test_reftar_full_cycle.sh -n 5 -s 50 -S 500 -c 10

# Medium test
./tools/test_reftar_full_cycle.sh -n 10 -s 100 -S 2000 -c 15

# Large test
./tools/test_reftar_full_cycle.sh -n 20 -s 500 -S 5000 -c 30

# Keep test files for inspection
./tools/test_reftar_full_cycle.sh -k
```

## Test Tool Reference

### verify_physical_sharing.sh

Verifies actual physical block sharing using `filefrag`.

```bash
# Basic usage
./tools/verify_physical_sharing.sh directory/

# Verbose output
./tools/verify_physical_sharing.sh -v directory/

# Save detailed report
./tools/verify_physical_sharing.sh -o report.txt directory/
```

**What it checks:**
- Filesystem type and reflink capability
- Physical block numbers for each file
- Which files share which physical blocks
- Reflink flags on files

**Expected output on success:**
```
✓ Found N physically shared blocks
Physical block XXXXX shared by:
  - file1.bin
  - file2.bin
✓ Physical block sharing verified
```

### verify_block_sharing.sh

Analyzes content-level block sharing via checksums.

```bash
# Basic usage
./tools/verify_block_sharing.sh directory/

# Custom block size
./tools/verify_block_sharing.sh -b 128 directory/

# Save report
./tools/verify_block_sharing.sh -o report.txt directory/
```

**What it checks:**
- Which blocks have identical content
- Deduplication potential
- Storage efficiency
- Most frequently shared blocks

### generate_test_data.sh

Creates test files with configurable shared blocks.

```bash
# Generate 10 files with moderate sharing
./tools/generate_test_data.sh -n 10 -c 20

# Generate large files
./tools/generate_test_data.sh -n 5 -S 10000 -c 5

# Heavy deduplication scenario
./tools/generate_test_data.sh -n 30 -s 100 -S 500 -c 50
```

## Performance Testing

### Benchmark Archive Creation
```bash
# Create 100MB of test data
./tools/generate_test_data.sh -n 10 -s 5000 -S 15000

# Time archive creation
time ./target/release/reftar create -f perf.reftar test_data/*.bin

# Check throughput
# Archive size / time = MB/s
```

### Benchmark Extraction
```bash
# Time extraction
time ./target/release/reftar extract -f perf.reftar -C restored/

# Check extraction speed
```

### Compare with/without Reflinks
```bash
# Extract to btrfs (with reflinks)
time ./target/release/reftar extract -f test.reftar -C /mnt/btrfs/restored/

# Extract to ext4 (without reflinks)
time ./target/release/reftar extract -f test.reftar -C /mnt/ext4/restored/

# Compare times and disk usage
du -sh /mnt/btrfs/restored/
du -sh /mnt/ext4/restored/
```

## Integration Testing

### Test with Real-World Data

```bash
# Archive your home directory (be careful!)
./target/release/reftar create -f home_backup.reftar ~/Documents/

# Verify listing
./target/release/reftar list -f home_backup.reftar | wc -l

# Extract to test location
./target/release/reftar extract -f home_backup.reftar -C /tmp/restore/

# Verify random files
diff ~/Documents/file.txt /tmp/restore/Documents/file.txt
```

### Test with Git Repository

```bash
# Clone a git repo with history (lots of duplicates)
git clone --bare https://github.com/some/repo.git test_repo.git

# Archive it
./target/release/reftar create -f repo.reftar test_repo.git/

# Check compression ratio (should be good due to git object dedup)
ls -lh repo.reftar
du -sh test_repo.git/

# Extract and verify
./target/release/reftar extract -f repo.reftar -C restored/
cd restored/test_repo.git && git fsck
```

## Troubleshooting Tests

### Test Fails: "Reflink not supported"

**Cause:** Filesystem doesn't support reflinks.

**Solution:**
```bash
# Check filesystem type
stat -f -c %T test_data

# If not btrfs/XFS, tests will fall back to regular copy
# This is expected behavior
```

### Test Fails: "Checksum mismatch"

**Cause:** Data corruption or bug in archive format.

**Solution:**
```bash
# Rebuild with debug info
cargo build --release

# Check if issue is reproducible
./target/release/reftar create -f test.reftar test_data/
./target/release/reftar extract -f test.reftar -C restored/

# Compare files
sha256sum test_data/* restored/test_data/*
```

### Test Fails: "Permission denied"

**Cause:** Test directory not owned by current user.

**Solution:**
```bash
# Fix ownership
sudo chown -R $USER:$USER test_data/

# Or run specific test with proper permissions
```

### Physical Sharing Not Verified

**Cause:** Files extracted to non-reflink filesystem or reflink failed.

**Check:**
```bash
# Is output on btrfs?
stat -f -c %T restored/

# Are reflink warnings printed?
./target/release/reftar extract -f test.reftar -C restored/ -v 2>&1 | grep -i reflink

# Check if data is still correct (should be)
cmp -s original.bin restored/original.bin && echo "Data OK"
```

## Continuous Integration

### GitHub Actions Example

```yaml
name: Test Reftar

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install Rust
        uses: actions-rust-lang/setup-rust-toolchain@v1

      - name: Install dependencies
        run: sudo apt-get install -y e2fsprogs btrfs-progs

      - name: Build
        run: cargo build --release

      - name: Run tests
        run: cargo test

      - name: Run basic reflink test
        run: ./tests/basic_reflink_test.sh

      - name: Run unit tests
        run: cargo test --release
```

## Test Coverage Goals

- ✅ Archive creation (all file types)
- ✅ Archive extraction (all file types)
- ✅ Archive listing
- ✅ Content deduplication
- ✅ Physical reflink preservation (Linux/btrfs)
- ✅ Graceful fallback (non-reflink filesystems)
- ✅ Checksum verification
- ✅ Directory structures
- ✅ Symbolic links
- ⚠️ Sparse files (partial)
- ⚠️ Hard links (stored as separate files)
- ⚠️ Extended attributes (limited)
- ⚠️ Special devices (not supported)

## Reporting Bugs

When reporting test failures, include:

1. **System information:**
   ```bash
   uname -a
   cargo --version
   stat -f -c %T test_data
   ```

2. **Reftar version:**
   ```bash
   ./target/release/reftar --version
   ```

3. **Test commands and output:**
   ```bash
   ./target/release/reftar create -f test.reftar test_data/ 2>&1 | tee create.log
   ./target/release/reftar extract -f test.reftar -C restored/ 2>&1 | tee extract.log
   ```

4. **File comparisons:**
   ```bash
   sha256sum test_data/* > original.sha256
   sha256sum restored/test_data/* > restored.sha256
   diff original.sha256 restored.sha256
   ```

## Further Reading

- [README.md](README.md) - Project overview
- [USAGE.md](USAGE.md) - User guide
- [FILEFORMAT.md](docs/FILEFORMAT.md) - Archive format specification
- [REFLINK_COMPLETE.md](REFLINK_COMPLETE.md) - Reflink implementation details
- [tools/README.md](tools/README.md) - Testing tools documentation
