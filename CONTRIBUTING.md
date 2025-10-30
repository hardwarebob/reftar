# Contributing to Reftar

Thank you for considering contributing to reftar! This document provides guidelines and information for contributors.

## Development Setup

### Prerequisites

- Rust 1.70 or later
- A Linux system (for testing reflink functionality)
- Git

### Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/yourusername/reftar.git
   cd reftar
   ```

3. Build the project:
   ```bash
   cargo build
   ```

4. Run tests:
   ```bash
   cargo test
   ```

## Code Organization

The codebase is organized as follows:

- `src/format.rs` - Binary format definitions and serialization/deserialization
- `src/create.rs` - Archive creation logic with deduplication
- `src/extract.rs` - Archive extraction logic with reference resolution
- `src/reflink.rs` - Reflink detection and platform-specific ioctl wrappers
- `src/main.rs` - CLI interface using clap
- `src/lib.rs` - Library exports

## Testing

### Running Tests

```bash
# Run all tests
cargo test

# Run tests with output
cargo test -- --nocapture

# Run specific test
cargo test test_name
```

### Adding Tests

- Add unit tests in the same file as the code being tested
- Use the `#[cfg(test)]` module convention
- Add integration tests in the `tests/` directory (to be created)

### Test Coverage

Aim for:
- All public APIs should have tests
- Edge cases and error conditions should be tested
- File format serialization/deserialization should be thoroughly tested

## Code Style

### Rust Style Guidelines

- Follow standard Rust formatting (use `cargo fmt`)
- Run `cargo clippy` and address warnings
- Use meaningful variable and function names
- Add documentation comments for public APIs

### Documentation

- Add doc comments (`///`) for all public functions and types
- Include examples in doc comments where helpful
- Update README.md for user-facing changes
- Update FILEFORMAT.md for format changes

## Pull Request Process

1. Create a new branch for your feature or bugfix:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Make your changes and commit them with clear messages:
   ```bash
   git commit -m "Add feature: description of feature"
   ```

3. Ensure tests pass and code is formatted:
   ```bash
   cargo fmt
   cargo clippy
   cargo test
   ```

4. Push to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```

5. Open a Pull Request with:
   - Clear description of changes
   - Reference to any related issues
   - Screenshots/examples if applicable

## Areas for Contribution

### High Priority

- **Extended Attributes**: Implement full xattr preservation
- **Testing**: Add comprehensive test suite
- **Documentation**: Improve code documentation and examples
- **Error Handling**: Better error messages and recovery

### Medium Priority

- **Compression**: Add compression support for data extents
- **Encryption**: Add encryption support
- **macOS Support**: Implement APFS reflink support
- **Progress Indicators**: Add progress bars for long operations

### Low Priority

- **Multi-threading**: Parallel compression/decompression
- **Incremental Backups**: Support for incremental archives
- **Archive Verification**: Verify archive integrity
- **Format Optimizations**: Further reduce archive size

## Commit Message Guidelines

Follow conventional commits format:

```
type(scope): subject

body

footer
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

Examples:
```
feat(create): add compression support for data extents

Implements zstd compression for data extents with configurable
compression level. Adds new ExtentType::Compressed variant.

Closes #42
```

## Questions or Problems?

- Open an issue for bugs or feature requests
- Start a discussion for questions or ideas
- Check existing issues and PRs before creating new ones

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (MIT OR Apache-2.0).
