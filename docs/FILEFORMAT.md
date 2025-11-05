# Reftar File Format Specification

Version 1.0 - Production

## Overview

The reftar file format is designed for efficient archiving of files with support for:
- **Block alignment** (4KB or higher) to support direct reflinking of files
- **Superset of tar functionality** with modern enhancements
- **Extent-based storage** linking extents in later files to files earlier in the archive
- **Streaming support** for archive creation and extraction
- **Interruptible creation** - partial archives are valid up to the last complete file
- **Modern features** - UTF-8 filename support, nanosecond timestamps, large files
- **Data deduplication** - reference extents eliminate duplicate data storage

**Byte Order:** All multi-byte integers are stored in little-endian format.

## Format Structure

```
┌─────────────────────────────────────────┐
│         Archive Header                  │
│  - Magic bytes ("reftar")               │
│  - Version (1)                          │
│  - Block size (default 4096)            │
│  - Padding to block boundary            │
├─────────────────────────────────────────┤
│         File Entry 1                    │
│  ├─ File Header                         │
│  │   - Metadata (path, size, times)    │
│  │   - Inline data (if size < block)   │
│  │   - Padding to block boundary       │
│  ├─ Extent Header 1 (if size >= block) │
│  │   - Extent metadata                 │
│  │   - Padding to block boundary       │
│  ├─ Extent Data 1 (if type = Data)     │
│  │   - Raw block data                  │
│  ├─ Extent Header 2                    │
│  │   - Padding to block boundary       │
│  ├─ Extent Data 2 (or reference)       │
│  └─ ...                                 │
├─────────────────────────────────────────┤
│         File Entry 2                    │
│  └─ ...                                 │
├─────────────────────────────────────────┤
│         File Entry N                    │
│  └─ ...                                 │
└─────────────────────────────────────────┘
```

## Archive Header

The archive header appears once at the beginning of the archive.

| Field | Size (bytes) | Type | Description |
|-------|--------------|------|-------------|
| Magic bytes | 6 | ASCII string | Literal "reftar" (0x72, 0x65, 0x66, 0x74, 0x61, 0x72) |
| Version | 2 | uint16 (LE) | Archive format version, currently 1 |
| Block size | 4 | uint32 (LE) | Block size in bytes (default: 4096, min: 512, max: 1048576) |
| Padding | variable | 0x00 bytes | Zero-padding to align to block boundary |

**Total size:** Aligned to block boundary (typically 4096 bytes)

**Example:**
```
Offset  Hex                                      ASCII
0x0000  72 65 66 74 61 72 01 00  00 10 00 00 00 00 00 00  reftar..........
0x0010  00 00 00 00 00 00 00 00  ... (padding to 4096)
```

## File Header

Each file in the archive has a header containing metadata.

| Field | Size (bytes) | Type | Description |
|-------|--------------|------|-------------|
| Magic bytes | 4 | ASCII string | Literal "FILE" (0x46, 0x49, 0x4C, 0x45) |
| Header size | 4 | uint32 (LE) | Total size of this header in bytes (including inline data) |
| File size | 12 | uint128 (LE, first 12 bytes) | File size in bytes (supports files up to 2^96 bytes) |
| File type | 1 | char | File type indicator (see below) |
| UID | 8 | uint64 (LE) | User ID of file owner |
| GID | 8 | uint64 (LE) | Group ID of file owner |
| Device major | 8 | uint64 (LE) | Major device number (for device files) |
| Device minor | 8 | uint64 (LE) | Minor device number (for device files) |
| Access time | 8 | uint64 (LE) | Last access time (Unix timestamp in seconds) |
| Modify time | 8 | uint64 (LE) | Last modification time (Unix timestamp in seconds) |
| Creation time | 8 | uint64 (LE) | Creation time (Unix timestamp in seconds) |
| Username | 4 + n | length + UTF-8 string | Username (length-prefixed) |
| Groupname | 4 + n | length + UTF-8 string | Group name (length-prefixed) |
| File path | 4 + n | length + UTF-8 string | Directory path (length-prefixed, UTF-8) |
| File name | 4 + n | length + UTF-8 string | File name (length-prefixed, UTF-8) |
| Link name | 4 + n | length + UTF-8 string | Symlink target (length-prefixed, UTF-8, empty if not symlink) |
| Extended perms | 4 + n | length + bytes | Extended permissions blob (length-prefixed, filesystem-specific) |
| FS type | 128 | null-padded string | Source filesystem type (e.g., "btrfs", "xfs", "ext4") |
| FS ID | 8 | uint64 (LE) | Source filesystem device ID |
| Inline data | variable | raw bytes | File data (only if file size < block size AND file type is regular) |
| Padding | variable | 0x00 bytes | Zero-padding to align to block boundary |

**Length-prefixed strings:** Each string field consists of:
1. 4-byte length (uint32 LE) - number of bytes in the string
2. UTF-8 encoded string data (NOT null-terminated)

### File Type Values

Compatible with tar format:

| Value | Type | Description |
|-------|------|-------------|
| '0' (0x30) | Regular | Regular file |
| '1' (0x31) | Hard link | Hard link to another file |
| '2' (0x32) | Symbolic link | Symbolic link |
| '3' (0x33) | Character device | Character special device |
| '4' (0x34) | Block device | Block special device |
| '5' (0x35) | Directory | Directory |
| '6' (0x36) | FIFO | Named pipe (FIFO) |

### Inline Data

For regular files smaller than the block size:
- File data is stored directly in the file header
- No extent headers or extent data follow
- This optimization reduces overhead for small files

For files >= block size or with complex layouts:
- File header contains no inline data
- Followed by one or more extent headers with their associated data

## Extent Header

Extent headers describe segments of file data. Each file >= block size has one or more extents.

| Field | Size (bytes) | Type | Description |
|-------|--------------|------|-------------|
| Extent ID | 8 | uint64 (LE) | Unique identifier for this extent (archive-wide) |
| Length in blocks | 4 | uint32 (LE) | Number of blocks (can be 0 for sparse extents) |
| Extent type | 1 | char | Type of extent: 'D', 'S', or 'R' (see below) |
| Source extent start | 8 | uint64 (LE) | Original offset in source file (informational) |
| Checksum | 4 | uint32 (LE) | CRC32 checksum of extent data (0 for sparse/reference) |
| Padding | variable | 0x00 bytes | Zero-padding to align to block boundary |

**Total size:** Aligned to block boundary (typically 25 bytes + padding to 4096)

### Extent Types

| Value | Type | Data Following | Description |
|-------|------|----------------|-------------|
| 'D' (0x44) | Data | Yes | Contains actual file data blocks |
| 'S' (0x53) | Sparse | No | Represents a hole in the file (all zeros) |
| 'R' (0x52) | Reference | No | References a previously stored extent (deduplication) |

### Extent Type Details

**Data Extent ('D'):**
- Contains actual file data
- Followed by `length_in_blocks * block_size` bytes of data
- Data is padded to block size (last block may have zeros)
- Checksum covers the full block-padded data
- Extent ID is stored for potential future references

**Sparse Extent ('S'):**
- Represents a hole in the file (sparse allocation)
- No data follows the extent header
- Length indicates how many zero blocks to create
- Used for efficient storage of sparse files
- Checksum is 0

**Reference Extent ('R'):**
- References a Data extent stored earlier in the archive
- No data follows the extent header
- Extent ID must match a previously written Data extent
- Used for deduplication when blocks are identical
- Checksum matches the referenced Data extent's checksum
- During extraction, data is copied or reflinked from the source extent

## Extent Data

For Data extents only:

| Field | Size (bytes) | Type | Description |
|-------|--------------|------|-------------|
| Raw data | `length_in_blocks * block_size` | bytes | Actual file data, padded to block size |

**Notes:**
- Data is NOT padded to block boundary (already block-sized)
- Last block may contain padding zeros if file size not block-aligned
- Checksum in extent header covers the full padded data
- On same filesystem, data can be reflinked instead of copied during archive creation

## Deduplication Strategy

The reference extent mechanism enables automatic deduplication:

1. **Archive Creation:**
   - Each data block is checksummed (CRC32)
   - If checksum matches a previous extent: write Reference extent (saves space)
   - If checksum is new: write Data extent (store the data)
   - Extent ID mapping maintained in memory during creation

2. **Archive Extraction:**
   - Data extents: Extract to file, cache (extent_id → file location)
   - Reference extents:
     - Lookup cached extent location
     - Try FICLONERANGE to reflink from source (Linux/btrfs)
     - Fall back to copying cached data if reflink fails
   - All data integrity verified via checksums

## Block Alignment Rationale

All headers and data are aligned to block boundaries:

1. **Reflink compatibility:** FICLONERANGE requires block-aligned offsets
2. **Direct I/O:** Enables efficient direct I/O operations
3. **Filesystem efficiency:** Aligned with typical filesystem block sizes
4. **Streaming:** Easy to seek to next entry on block boundaries

## Archive Footer

**Status:** Not currently implemented (reserved for future use)

Planned contents:
- Archive statistics (file count, total size, dedup ratio)
- Index of files (for faster seeking)
- Archive integrity checksum
- Creation timestamp and metadata

## Size Limits

| Item | Maximum |
|------|---------|
| Archive size | Unlimited (streaming format) |
| File size | 2^96 bytes (~79 zettabytes) |
| File path length | 2^32 - 1 bytes |
| File name length | 2^32 - 1 bytes |
| Block size | 1,048,576 bytes (1MB) |
| Files per archive | Unlimited |
| Extents per file | Unlimited |

## Compatibility Notes

### Versus tar

**Compatible:**
- File type indicators (same values)
- Metadata concepts (permissions, ownership, times)
- Directory structure handling

**Incompatible:**
- Binary format completely different
- No tar header format compatibility
- Different metadata encoding (length-prefixed vs fixed-width)

### Platform-Specific Features

**Reflink Support (FICLONERANGE):**
- Linux: btrfs, XFS (reflink=1), ext4 (recent kernels) ✅
- macOS: APFS (requires different API) ❌
- BSD: (requires different API) ❌
- Windows: ReFS (different mechanism) ❌

**Extended Attributes:**
- Currently stored as opaque blob
- Filesystem-specific format
- Limited cross-platform compatibility

## Implementation Notes

### Current Implementation Status

✅ **Fully Implemented:**
- Archive header read/write
- File header read/write with all metadata
- Extent header read/write
- Data/Sparse/Reference extent handling
- Block alignment and padding
- CRC32 checksumming
- Deduplication via reference extents
- Reflink restoration (Linux/btrfs)
- UTF-8 filename support

⚠️ **Partial Implementation:**
- Extended attributes (stored but not fully validated)
- Hard links (stored as separate files)
- Device files (format supports, extraction limited)
- Archive footer (not implemented)

### Streaming Behavior

The format supports streaming:
- No global index required
- Each file is self-contained
- Can stop reading at any point (EOF or file header magic not found)
- Partial archives are valid (all complete files before stop point)

### Error Handling

**Invalid Magic Bytes:**
- Archive header: Not a reftar archive
- File header: End of archive or corruption

**Checksum Mismatch:**
- Indicates data corruption
- Extraction should fail

**Unknown Extent Reference:**
- Extent ID not found in cache
- Indicates archive corruption or incomplete extraction

## Example Archive Layout

Small archive with two files, one reflinked:

```
Offset      Content
0x0000      Archive Header (padded to 4096 bytes)
0x1000      File Header: "file1.txt" (100 KB, no inline data)
0x2000      Extent Header: ID=1, Type=Data, Length=25 blocks
0x3000      Extent Data: 25 blocks (102,400 bytes)
0x1C000     File Header: "file2.txt" (100 KB, duplicate content)
0x1D000     Extent Header: ID=1, Type=Reference, Length=25 blocks
0x1E000     (End of archive - reference has no data)
```

**Result:** 116 KB file data stored in ~122 KB archive (6KB overhead), with file2 referencing file1's data.

## Version History

### Version 1 (Current)
- Initial format specification
- All features described in this document
- Block-aligned extent-based storage
- Deduplication via reference extents
- Reflink support for Linux

### Future Versions

Potential enhancements (not yet implemented):
- Compression (per-extent or per-archive)
- Encryption (per-file or per-archive)
- Enhanced index/footer
- Streaming compression
- Delta encoding
- Multi-volume support

## Reference Implementation

See the Rust implementation in the reftar repository:
- `src/format.rs` - Format structures and serialization
- `src/create.rs` - Archive creation
- `src/extract.rs` - Archive extraction with reflink support
- `src/reflink.rs` - FICLONERANGE implementation

## Specification Compliance

To create a compliant reftar implementation:

1. **Must** support archive header with magic "reftar"
2. **Must** support file headers with all metadata fields
3. **Must** support Data extents with block-aligned storage
4. **Must** verify checksums on extraction
5. **Must** handle all file types (at minimum: regular, directory, symlink)
6. **Should** support Sparse extents for efficiency
7. **Should** support Reference extents for deduplication
8. **May** support reflink restoration (platform-specific)
9. **May** optimize small files with inline data

A minimal implementation can ignore Reference extents (treat as Data) and still extract archives correctly, but will lose deduplication benefits.
