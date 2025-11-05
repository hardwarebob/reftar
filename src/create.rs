//! Archive creation functionality

use crate::format::*;
use crate::reflink;
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

/// Extent tracking for deduplication and references
#[derive(Debug, Clone)]
pub struct ExtentInfo {
    pub extent_id: u64,
    pub file_path: PathBuf,
    pub offset: u64,
    pub length: u64,
    pub checksum: u32,
}

/// Archive creator
pub struct ArchiveCreator<W: Write + Seek> {
    writer: BufWriter<W>,
    block_size: u32,
    extent_map: HashMap<u32, ExtentInfo>, // Maps checksum to extent info
    next_extent_id: u64,
    source_file: Option<File>, // Keep track of source file for reflinks
}

impl<W: Write + Seek> ArchiveCreator<W> {
    /// Create a new archive creator
    pub fn new(writer: W, block_size: Option<u32>) -> Result<Self> {
        let block_size = block_size.unwrap_or(DEFAULT_BLOCK_SIZE);

        let mut creator = Self {
            writer: BufWriter::new(writer),
            block_size,
            extent_map: HashMap::new(),
            next_extent_id: 0,
            source_file: None,
        };

        // Write archive header
        let header = ArchiveHeader::new(block_size);
        header.write(&mut creator.writer)?;

        Ok(creator)
    }

    /// Add a file to the archive
    pub fn add_file(&mut self, source_path: &Path, archive_path: &Path) -> Result<()> {
        let metadata = fs::metadata(source_path)
            .with_context(|| format!("Failed to read metadata for {:?}", source_path))?;

        // Build file header
        let file_header = self.build_file_header(source_path, archive_path, &metadata)?;

        // Write file header
        file_header.write(&mut self.writer, self.block_size)?;

        // Handle file data based on size and type
        if file_header.file_type == FileType::Regular && file_header.inline_data.is_empty() {
            // File is large enough to have extents
            self.write_file_extents(source_path, file_header.file_size)?;
        }

        Ok(())
    }

    /// Add a directory recursively to the archive
    pub fn add_directory(&mut self, source_path: &Path, archive_base: &Path) -> Result<()> {
        let metadata = fs::metadata(source_path)?;

        // Add the directory itself
        let archive_path = archive_base.join(
            source_path
                .file_name()
                .unwrap_or(source_path.as_os_str()),
        );
        let dir_header = self.build_file_header(source_path, &archive_path, &metadata)?;
        dir_header.write(&mut self.writer, self.block_size)?;

        // Recursively add contents
        if metadata.is_dir() {
            for entry in fs::read_dir(source_path)? {
                let entry = entry?;
                let entry_path = entry.path();
                let rel_path = archive_path.join(entry.file_name());

                if entry_path.is_dir() {
                    self.add_directory(&entry_path, &archive_path)?;
                } else {
                    self.add_file(&entry_path, &rel_path)?;
                }
            }
        }

        Ok(())
    }

    /// Build a file header from filesystem metadata
    fn build_file_header(
        &self,
        source_path: &Path,
        archive_path: &Path,
        metadata: &fs::Metadata,
    ) -> Result<FileHeader> {
        let file_type = if metadata.is_dir() {
            FileType::Directory
        } else if metadata.is_symlink() {
            FileType::SymbolicLink
        } else {
            FileType::Regular
        };

        let file_size = metadata.len() as u128;

        // Read inline data for small files
        let inline_data = if file_type == FileType::Regular
            && file_size > 0
            && file_size < self.block_size as u128
        {
            let mut data = Vec::new();
            File::open(source_path)?.read_to_end(&mut data)?;
            data
        } else {
            Vec::new()
        };

        let link_name = if file_type == FileType::SymbolicLink {
            fs::read_link(source_path)?
                .to_string_lossy()
                .to_string()
        } else {
            String::new()
        };

        // Get username and groupname
        let username = get_username(metadata.uid()).unwrap_or_else(|| metadata.uid().to_string());
        let groupname =
            get_groupname(metadata.gid()).unwrap_or_else(|| metadata.gid().to_string());

        // Get filesystem info if we can open the file
        let (source_filesystem_type, source_filesystem_id) = if file_type == FileType::Regular {
            if let Ok(file) = File::open(source_path) {
                (
                    reflink::get_filesystem_type(&file).unwrap_or_default(),
                    reflink::get_filesystem_id(&file).unwrap_or(0),
                )
            } else {
                (String::new(), 0)
            }
        } else {
            (String::new(), 0)
        };

        Ok(FileHeader {
            file_size,
            file_type,
            uid: metadata.uid() as u64,
            gid: metadata.gid() as u64,
            device_major: 0,
            device_minor: 0,
            access_time: metadata.atime() as u64,
            modify_time: metadata.mtime() as u64,
            creation_time: metadata.ctime() as u64,
            username,
            groupname,
            file_path: archive_path
                .parent()
                .unwrap_or(Path::new(""))
                .to_string_lossy()
                .to_string(),
            file_name: archive_path
                .file_name()
                .unwrap_or(archive_path.as_os_str())
                .to_string_lossy()
                .to_string(),
            link_name,
            extended_permissions: Vec::new(), // TODO: implement xattr support
            source_filesystem_type,
            source_filesystem_id,
            inline_data,
        })
    }

    /// Write file extents (for files larger than block size)
    fn write_file_extents(&mut self, source_path: &Path, file_size: u128) -> Result<()> {
        let mut file = File::open(source_path)?;
        let num_blocks = ((file_size + self.block_size as u128 - 1) / self.block_size as u128) as u32;

        for block_idx in 0..num_blocks {
            let block_offset = block_idx as u64 * self.block_size as u64;
            let block_len = if block_idx == num_blocks - 1 {
                // Last block might be partial
                (file_size - block_offset as u128) as usize
            } else {
                self.block_size as usize
            };

            // Read block data
            let mut block_data = vec![0u8; self.block_size as usize];
            file.seek(SeekFrom::Start(block_offset))?;
            let bytes_read = file.read(&mut block_data[..block_len])?;

            // Calculate checksum on the full block (including padding)
            // This must match what we write and what extraction will verify
            let checksum = crc32fast::hash(&block_data);

            // Check if this block is a duplicate (could be referenced)
            let (extent_id, extent_type) = if let Some(existing) = self.extent_map.get(&checksum) {
                // Found duplicate - create reference extent pointing to existing extent
                (existing.extent_id, ExtentType::Reference)
            } else {
                // New data - create data extent with new ID
                let new_id = self.next_extent_id;
                self.next_extent_id += 1;
                (new_id, ExtentType::Data)
            };

            let extent_header = ExtentHeader {
                extent_id,
                length_in_blocks: 1,
                extent_type,
                source_extent_start: block_offset,
                checksum,
            };

            // Write extent header
            extent_header.write(&mut self.writer, self.block_size)?;

            // Write data if not a reference
            if extent_type == ExtentType::Data {
                // Write the full block (padded to block_size)
                self.writer.write_all(&block_data)?;

                // Track this extent for future references
                self.extent_map.insert(
                    checksum,
                    ExtentInfo {
                        extent_id,
                        file_path: source_path.to_path_buf(),
                        offset: block_offset,
                        length: bytes_read as u64,
                        checksum,
                    },
                );
            }
        }

        Ok(())
    }

    /// Flush and finish writing the archive
    pub fn finish(mut self) -> Result<()> {
        self.writer.flush()?;
        Ok(())
    }
}

// Helper functions for getting user/group names
fn get_username(uid: u32) -> Option<String> {
    // Use nix crate to get username
    nix::unistd::User::from_uid(nix::unistd::Uid::from_raw(uid))
        .ok()?
        .map(|u| u.name)
}

fn get_groupname(gid: u32) -> Option<String> {
    // Use nix crate to get groupname
    nix::unistd::Group::from_gid(nix::unistd::Gid::from_raw(gid))
        .ok()?
        .map(|g| g.name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use tempfile::NamedTempFile;

    #[test]
    fn test_create_empty_archive() {
        let buf = Vec::new();
        let creator = ArchiveCreator::new(Cursor::new(buf), None).unwrap();
        creator.finish().unwrap();
    }

    #[test]
    fn test_add_small_file() {
        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(b"Hello, world!").unwrap();
        temp_file.flush().unwrap();

        let buf = Vec::new();
        let mut creator = ArchiveCreator::new(Cursor::new(buf), None).unwrap();
        creator
            .add_file(temp_file.path(), Path::new("test.txt"))
            .unwrap();
        creator.finish().unwrap();
    }
}
