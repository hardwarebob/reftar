# Reftar Usage Guide

This document provides detailed usage information for the reftar utility.

## Basic Commands

### Create Archive

Create a new reftar archive from files and directories.

```bash
reftar create -f <archive.reftar> [OPTIONS] <inputs>...
```

**Options:**
- `-f, --file <FILE>` - Output archive file (required)
- `-b, --block-size <SIZE>` - Block size in bytes (default: 4096)
- `-v, --verbose` - Verbose output showing progress

**Examples:**

```bash
# Create archive with default settings
reftar create -f backup.reftar my_folder/

# Create archive with custom block size (8KB)
reftar create -f backup.reftar -b 8192 my_folder/

# Create archive from multiple sources
reftar create -f backup.reftar file1.txt file2.txt documents/ photos/

# Verbose mode
reftar create -f backup.reftar -v my_data/
```

### Extract Archive

Extract files from a reftar archive.

```bash
reftar extract -f <archive.reftar> [OPTIONS]
```

**Options:**
- `-f, --file <FILE>` - Input archive file (required)
- `-C, --output-dir <DIR>` - Output directory (default: current directory)
- `-v, --verbose` - Verbose output showing extracted files

**Examples:**

```bash
# Extract to current directory
reftar extract -f backup.reftar

# Extract to specific directory
reftar extract -f backup.reftar -C /restore/path

# Verbose extraction
reftar extract -f backup.reftar -v
```

### List Archive Contents

List all files in an archive without extracting.

```bash
reftar list -f <archive.reftar> [OPTIONS]
```

**Options:**
- `-f, --file <FILE>` - Input archive file (required)
- `-v, --verbose` - Show additional information including file count

**Examples:**

```bash
# Simple list
reftar list -f backup.reftar

# Verbose list with statistics
reftar list -f backup.reftar -v
```

### Show Archive Information

Display metadata about an archive.

```bash
reftar info -f <archive.reftar>
```

**Examples:**

```bash
reftar info -f backup.reftar
```

This shows:
- Format version
- Block size
- Archive file size

## Advanced Usage

### Block Size Selection

The block size affects both the archive format and deduplication granularity:

- **4096 bytes (4KB)** - Default, good for general use
- **8192 bytes (8KB)** - Better for larger files
- **16384 bytes (16KB)** - Optimal for very large files

Larger block sizes reduce header overhead but may reduce deduplication efficiency for small files.

```bash
# 4KB blocks (default)
reftar create -f archive.reftar data/

# 8KB blocks
reftar create -f archive.reftar -b 8192 data/

# 16KB blocks
reftar create -f archive.reftar -b 16384 data/
```

### Deduplication

Reftar automatically detects duplicate data blocks across files:

```bash
# Files with duplicate content will be deduplicated automatically
reftar create -f archive.reftar \
    logs/server1.log \
    logs/server2.log \
    logs/server3.log
```

If multiple files share identical data blocks, reftar stores the data once and creates references for subsequent occurrences.

### Reflink Support

On filesystems with reflink support (btrfs, XFS, ext4 with CoW):

**During Archive Creation:**
- Reftar detects the source filesystem type
- Records filesystem ID for compatibility checking

**During Extraction:**
- On compatible filesystems, reftar can use reflinks
- Falls back to regular copy if reflinks aren't supported

### Working with Large Datasets

For large datasets:

```bash
# Create archive with verbose output for progress
reftar create -f large_backup.reftar -v -b 16384 /large/dataset/

# Extract with verbose output
reftar extract -f large_backup.reftar -C /restore/location -v
```

## Filesystem Compatibility

### Supported Filesystems

**Full Support (reflink-capable):**
- btrfs
- XFS (with reflink=1 mount option)
- ext4 (on recent kernels)

**Basic Support:**
- ext3/ext4
- tmpfs
- NFS

### Cross-Filesystem Archives

Archives created on one filesystem can be extracted on any supported filesystem. Reflink optimizations will be used when available.

## File Types

Reftar supports:
- ✅ Regular files
- ✅ Directories
- ✅ Symbolic links
- ⚠️  Hard links (stored as separate files)
- ⚠️  Character/block devices (partial support)
- ⚠️  FIFOs (partial support)

## Metadata Preservation

Reftar preserves:
- File permissions (Unix mode)
- Ownership (UID/GID and username/groupname)
- Timestamps (access, modification, creation)
- File paths and names (UTF-8 encoded)
- Symbolic link targets

Note: Extended attributes (xattr) support is limited in the current version.

## Command Line Options Reference

### Planned Options (Future)

These options are planned for future versions:

**Creation Options:**
- `--reflink-data, -r` - Reflink data to archive where possible
- `--no-reflink, -N` - Disable reflink, copy all data
- `--compress, -z` - Enable compression
- `--exclude <PATTERN>` - Exclude files matching pattern

**Extraction Options:**
- `--use-usernames` - Use names from archive, not UID/GIDs
- `--use-uids` - Use UIDs from archive
- `--preserve-reflinks` - Preserve reflink structure on extraction

## Error Handling

Reftar provides clear error messages for common issues:

- Invalid archive format
- Checksum mismatches
- Missing source files
- Permission denied
- Filesystem not supported

Use verbose mode (`-v`) for detailed diagnostic information.

## Performance Tips

1. **Choose appropriate block size**: Larger blocks for larger files
2. **Use verbose mode**: Monitor progress on large operations
3. **Same filesystem**: Create archive on same filesystem as source for reflink benefits
4. **SSD storage**: Archives benefit from fast sequential I/O

## Troubleshooting

### "Invalid reftar magic bytes"
The file is not a valid reftar archive or is corrupted.

### "Checksum mismatch"
Archive data is corrupted. The integrity check failed.

### "Reference to unknown extent ID"
Archive corruption - a data reference points to non-existent data.

### Permission errors
Ensure you have read permission for source files and write permission for destination.
