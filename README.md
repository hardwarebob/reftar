# Reftar

reftar is a utility for archiving files with support for referenced blocks (reflinks) between filesystems. Inspired by tar but designed with modern filesystem features in mind, reftar supports:

- Copy-on-write (CoW) reflinks for efficient data sharing
- Data deduplication across files in the archive
- Large block sizes (4K+) with block alignment
- Streaming archive creation and extraction
- Interruptible archive creation
- UTF-8 filename support
- Full tar-compatible metadata (permissions, ownership, timestamps)

## Features

- **Reflink Support**: Efficiently handle files that share data blocks using filesystem reflinks
- **Deduplication**: Automatically detect and reference duplicate data blocks within archives
- **Modern Format**: Designed for modern filesystems (btrfs, XFS, ext4) with large block support
- **Streaming**: Create and extract archives in streaming mode
- **Comprehensive Metadata**: Preserve Unix file attributes, extended permissions, and timestamps

## File Format

See [File Format Documentation](docs/FILEFORMAT.md) for detailed information about the reftar archive format.

## Installation

### Binary Releases

Pre-compiled binaries are available for multiple platforms. Download the latest release from the [Releases page](https://github.com/hardwarebob/reftar/releases).

```bash
# Linux x86_64
wget https://github.com/hardwarebob/reftar/releases/latest/download/reftar-linux-x86_64.tar.gz
tar xzf reftar-linux-x86_64.tar.gz
sudo mv reftar /usr/local/bin/

# macOS (Intel)
wget https://github.com/hardwarebob/reftar/releases/latest/download/reftar-macos-x86_64.tar.gz
tar xzf reftar-macos-x86_64.tar.gz
sudo mv reftar /usr/local/bin/

# macOS (Apple Silicon)
wget https://github.com/hardwarebob/reftar/releases/latest/download/reftar-macos-aarch64.tar.gz
tar xzf reftar-macos-aarch64.tar.gz
sudo mv reftar /usr/local/bin/
```

### Prerequisites

- Rust 1.70 or later (for building from source)
- Linux (for reflink support via FICLONERANGE ioctl)

### Building from Source

```bash
cargo build --release
```

The binary will be available at `target/release/reftar`.

### Installing from Source

```bash
cargo install --path .
```

## Usage

### Creating an Archive

```bash
# Create an archive with default settings
reftar create -f archive.reftar file1.txt file2.txt directory/

# Create with custom block size
reftar create -f archive.reftar -b 8192 myfiles/

# Verbose output
reftar create -f archive.reftar -v mydata/
```

### Extracting an Archive

```bash
# Extract to current directory
reftar extract -f archive.reftar

# Extract to specific directory
reftar extract -f archive.reftar -C /path/to/output

# Verbose output
reftar extract -f archive.reftar -v
```

### Listing Archive Contents

```bash
# List all files
reftar list -f archive.reftar

# Verbose listing
reftar list -f archive.reftar -v
```

### Show Archive Information

```bash
# Display archive metadata
reftar info -f archive.reftar
```

## How It Works

Reftar creates archives with the following structure:

1. **Archive Header**: Contains magic bytes, version, and block size
2. **File Entries**: Each file has a header followed by extent data
3. **Extent System**: Files are broken into block-aligned extents that can be:
   - **Data extents**: Contain actual file data
   - **Sparse extents**: Represent holes in files
   - **Reference extents**: Point to earlier extents with identical data

### Data Deduplication

When creating archives, reftar automatically detects duplicate data blocks across files. Instead of storing the same data multiple times, it stores it once and creates references to it from other locations. This significantly reduces archive size for datasets with shared data.

### Reflink Support

On supported filesystems (btrfs, XFS with reflink support, ext4 with CoW), reftar can detect when source files share data blocks and preserve this relationship in the archive. During extraction on compatible filesystems, these relationships can be restored using reflinks instead of copying data.

## Architecture

The project is organized into several modules:

- **format.rs**: Binary format definitions and serialization
- **create.rs**: Archive creation with extent tracking and deduplication
- **extract.rs**: Archive extraction with reference resolution
- **reflink.rs**: Filesystem reflink detection and ioctl wrappers
- **main.rs**: CLI interface

## Limitations

- Reflink functionality requires Linux with FICLONERANGE support
- Extended attribute preservation is currently limited
- Some special file types (character devices, etc.) are not yet fully supported
- Requires Unix-like systems for full metadata support

## Contributing

Contributions are welcome! Areas for improvement:

- macOS/BSD reflink support (APFS cloning)
- Extended attribute (xattr) preservation
- Compression support
- Encryption support
- Multi-threaded compression/decompression
- Progress bars and better user feedback

## License

MIT OR Apache-2.0

## File Format

See the detailed [File Format Documentation](docs/FILEFORMAT.md)


