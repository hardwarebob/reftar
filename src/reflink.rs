//! Reflink support for copy-on-write file operations
//!
//! This module provides functionality to detect and use filesystem reflinks
//! (also known as copy-on-write clones) to efficiently copy file data.

use anyhow::Result;
use std::fs::File;
use std::os::unix::io::AsRawFd;

/// Check if two files are on the same filesystem
pub fn same_filesystem(file1: &File, file2: &File) -> Result<bool> {
    use nix::sys::stat::fstat;

    let stat1 = fstat(file1.as_raw_fd())?;
    let stat2 = fstat(file2.as_raw_fd())?;

    Ok(stat1.st_dev == stat2.st_dev)
}

/// Attempt to reflink a range of bytes from src to dest
/// Returns true if successful, false if reflink is not supported
#[cfg(target_os = "linux")]
pub fn try_reflink_range(
    src: &File,
    src_offset: u64,
    dest: &File,
    dest_offset: u64,
    length: u64,
) -> Result<bool> {
    use nix::libc::ioctl;
    use std::os::unix::io::AsRawFd;

    #[repr(C)]
    struct FileCloneRange {
        src_fd: i64,
        src_offset: u64,
        src_length: u64,
        dest_offset: u64,
    }

    let range = FileCloneRange {
        src_fd: src.as_raw_fd() as i64,
        src_offset,
        src_length: length,
        dest_offset,
    };

    let result = unsafe {
        ioctl(
            dest.as_raw_fd(),
            0x4020940D, // FICLONERANGE ioctl number
            &range as *const FileCloneRange,
        )
    };

    if result == 0 {
        Ok(true)
    } else {
        let errno = nix::errno::Errno::last();
        // EOPNOTSUPP, ENOTTY, EINVAL mean reflink not supported
        if errno == nix::errno::Errno::EOPNOTSUPP
            || errno == nix::errno::Errno::ENOTTY
            || errno == nix::errno::Errno::EINVAL
        {
            Ok(false)
        } else {
            Err(anyhow::anyhow!("FICLONERANGE failed: {}", errno))
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn try_reflink_range(
    _src: &File,
    _src_offset: u64,
    _dest: &File,
    _dest_offset: u64,
    _length: u64,
) -> Result<bool> {
    // Reflink not supported on non-Linux platforms yet
    Ok(false)
}

/// Get the filesystem type of a file
#[cfg(target_os = "linux")]
pub fn get_filesystem_type(file: &File) -> Result<String> {
    use nix::sys::statfs::fstatfs;

    let stat = fstatfs(file)?;

    // Map filesystem type codes to names
    let fs_type = match stat.filesystem_type().0 {
        0xEF53 => "ext4",
        0x58465342 => "xfs",
        0x9123683E => "btrfs",
        0x6969 => "nfs",
        0x01021994 => "tmpfs",
        _ => "unknown",
    };

    Ok(fs_type.to_string())
}

#[cfg(not(target_os = "linux"))]
pub fn get_filesystem_type(_file: &File) -> Result<String> {
    Ok("unknown".to_string())
}

/// Get filesystem device ID
pub fn get_filesystem_id(file: &File) -> Result<u64> {
    use nix::sys::stat::fstat;

    let stat = fstat(file.as_raw_fd())?;
    Ok(stat.st_dev)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_same_filesystem() {
        let file1 = NamedTempFile::new().unwrap();
        let file2 = NamedTempFile::new().unwrap();

        // Both temp files should be on the same filesystem
        assert!(same_filesystem(file1.as_file(), file2.as_file()).unwrap());
    }

    #[test]
    fn test_get_filesystem_type() {
        let file = NamedTempFile::new().unwrap();
        let fs_type = get_filesystem_type(file.as_file()).unwrap();
        // Should return some filesystem type
        assert!(!fs_type.is_empty());
    }
}
