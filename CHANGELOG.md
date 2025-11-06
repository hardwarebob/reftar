# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2024-11-06

### Added
- GitHub Actions workflow for automated releases
- Pre-compiled binaries for multiple platforms (Linux x86_64, Linux ARM64, macOS x86_64, macOS ARM64)
- Comprehensive test suite with reflink verification using filefrag

### Changed
- Improved test script to use filefrag for extent sharing verification instead of disk usage

### Fixed
- Fixed test compilation errors in `test_extract_empty_archive`
- Fixed arithmetic expansion bug in test scripts that caused early exit with `set -e`
- Fixed `ArchiveCreator::finish()` to return the writer for testing
- Fixed cross compile for github actions.

## [0.1.0] - 2024-11-06

### Added
- Initial public alpha release
- Core archive creation and extraction functionality
- Support for reflink detection and preservation
- Data deduplication across files within archives
- Sparse file handling
- Large file support with multiple extents
- Archive listing and info commands
- Comprehensive metadata preservation (permissions, ownership, timestamps)
- Custom block size support (default 4KB)
- Verbose output modes
- UTF-8 filename support

### Features
- **Archive Operations**: Create, extract, list, and inspect reftar archives
- **Reflink Support**: Detect and preserve reflinked files on btrfs/XFS filesystems
- **Deduplication**: Automatic detection and referencing of duplicate data blocks
- **Streaming**: Efficient streaming archive creation and extraction
- **Format**: Binary format with magic bytes (REFTAR), version info, and CRC32 checksums

### Known Limitations
- Reflink functionality limited to Linux with FICLONERANGE support
- Limited extended attribute preservation
- Some special file types not fully supported
- Requires Unix-like systems for full metadata support

[Unreleased]: https://github.com/hardwarebob/reftar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hardwarebob/reftar/releases/tag/v0.1.0
