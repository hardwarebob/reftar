# Release Instructions

This document describes how to create a new release of reftar.

## Automated Release Process

The project includes a GitHub Actions workflow (`.github/workflows/release.yml`) that automatically builds binaries for multiple platforms and creates GitHub releases.

### Supported Platforms

The workflow builds for the following platforms:

- **Linux x86_64** (GNU libc)
- **Linux x86_64** (musl - static binary)
- **Linux ARM64** (aarch64)
- **macOS x86_64** (Intel)
- **macOS ARM64** (Apple Silicon)

### Creating a Release

There are two ways to trigger a release:

#### 1. Using Git Tags (Recommended)

Create and push a version tag:

```bash
# Update version in Cargo.toml if needed
vim Cargo.toml

# Update CHANGELOG.md
vim CHANGELOG.md

# Commit changes
git add Cargo.toml CHANGELOG.md
git commit -m "Bump version to v0.1.1"

# Create and push tag
git tag v0.1.1
git push origin main
git push origin v0.1.1
```

The workflow will automatically:
1. Build binaries for all platforms
2. Generate SHA256 checksums
3. Create a GitHub release with all artifacts
4. Generate release notes from commits

#### 2. Manual Trigger

You can also manually trigger the workflow from the GitHub Actions UI:

1. Go to the Actions tab in your repository
2. Select "Release" workflow
3. Click "Run workflow"
4. Enter the version tag (e.g., `v0.1.1`)
5. Click "Run workflow"

### Release Checklist

Before creating a release:

- [ ] Update version number in `Cargo.toml`
- [ ] Update `CHANGELOG.md` with new version and changes
- [ ] Run tests: `cargo test`
- [ ] Build locally: `cargo build --release`
- [ ] Test the binary manually
- [ ] Commit version bump changes
- [ ] Create and push git tag
- [ ] Verify GitHub Actions workflow completes successfully
- [ ] Download and test release binaries
- [ ] Update release notes on GitHub if needed

### Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **MAJOR** version (1.0.0): Incompatible API/format changes
- **MINOR** version (0.1.0): Add functionality in a backwards compatible manner
- **PATCH** version (0.1.1): Backwards compatible bug fixes

### Release Artifacts

Each release includes:

- Binary tarballs for each platform (`reftar-<platform>.tar.gz`)
- `checksums.txt` with SHA256 hashes of all binaries
- Auto-generated release notes
- Links to source code (automatically added by GitHub)

### Testing Releases

After a release is created, test the binaries:

```bash
# Download a binary
wget https://github.com/hardwarebob/reftar/releases/download/v0.1.0/reftar-linux-x86_64.tar.gz

# Verify checksum
sha256sum reftar-linux-x86_64.tar.gz
# Compare with checksums.txt from release

# Extract and test
tar xzf reftar-linux-x86_64.tar.gz
./reftar --version
./reftar --help
```

### Troubleshooting

If the release workflow fails:

1. Check the GitHub Actions logs for errors
2. Common issues:
   - Compilation errors (fix in code)
   - Missing dependencies (update workflow)
   - Permission issues (check GITHUB_TOKEN permissions)
3. You can re-run the workflow after fixing issues
4. Delete failed releases and tags if needed:
   ```bash
   git tag -d v0.1.0
   git push origin :refs/tags/v0.1.0
   ```

### Pre-release Testing

For testing releases before making them public:

1. Create a tag with `-rc` suffix (e.g., `v0.1.1-rc1`)
2. The workflow will create a pre-release
3. Test thoroughly
4. Create the final release tag when ready

## Manual Release (Without CI)

If you need to create a release manually:

```bash
# Build for current platform
cargo build --release

# Create tarball
cd target/release
tar czf reftar-$(uname -s)-$(uname -m).tar.gz reftar

# Generate checksum
sha256sum reftar-*.tar.gz > checksums.txt

# Upload to GitHub releases manually
```
