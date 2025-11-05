//! Archive extraction functionality

use crate::format::*;
use anyhow::Result;
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// Extent data cache for resolving references
#[derive(Debug, Clone)]
struct CachedExtent {
    extent_id: u64,
    data: Vec<u8>,
    /// File path and offset where this extent was written (for reflinks)
    file_location: Option<(PathBuf, u64)>,
}

/// Archive extractor
pub struct ArchiveExtractor<R: Read + Seek> {
    reader: BufReader<R>,
    block_size: u32,
    extent_cache: HashMap<u64, CachedExtent>, // Maps extent_id to cached data
    output_dir: PathBuf,
    current_file_path: Option<PathBuf>, // Track current file being extracted
}

impl<R: Read + Seek> ArchiveExtractor<R> {
    /// Create a new archive extractor
    pub fn new(reader: R, output_dir: PathBuf) -> Result<Self> {
        let mut reader = BufReader::new(reader);

        // Read archive header
        let header = ArchiveHeader::read(&mut reader)?;

        Ok(Self {
            reader,
            block_size: header.block_size,
            extent_cache: HashMap::new(),
            output_dir,
            current_file_path: None,
        })
    }

    /// Extract all files from the archive
    pub fn extract_all(&mut self) -> Result<()> {
        loop {
            match self.extract_next_file() {
                Ok(true) => continue,
                Ok(false) => break, // End of archive
                Err(e) => {
                    // Check if we hit EOF
                    if e.to_string().contains("failed to fill whole buffer") {
                        break;
                    }
                    return Err(e);
                }
            }
        }

        Ok(())
    }

    /// Extract the next file from the archive
    /// Returns Ok(true) if a file was extracted, Ok(false) if EOF reached
    pub fn extract_next_file(&mut self) -> Result<bool> {
        // Try to read file header
        let file_header = match FileHeader::read(&mut self.reader, self.block_size) {
            Ok(header) => header,
            Err(e) => {
                // Check if this is EOF
                if e.to_string().contains("failed to fill whole buffer") {
                    return Ok(false);
                }
                return Err(e);
            }
        };

        // Build output path
        let output_path = self.output_dir.join(&file_header.file_path).join(&file_header.file_name);

        // Create parent directories
        if let Some(parent) = output_path.parent() {
            fs::create_dir_all(parent)?;
        }

        // Extract based on file type
        match file_header.file_type {
            FileType::Directory => {
                fs::create_dir_all(&output_path)?;
            }
            FileType::SymbolicLink => {
                #[cfg(unix)]
                std::os::unix::fs::symlink(&file_header.link_name, &output_path)?;
            }
            FileType::Regular => {
                if !file_header.inline_data.is_empty() {
                    // Small file with inline data
                    let mut file = File::create(&output_path)?;
                    file.write_all(&file_header.inline_data)?;
                } else if file_header.file_size > 0 {
                    // Large file with extents
                    self.current_file_path = Some(output_path.clone());
                    self.extract_file_with_extents(&output_path, file_header.file_size)?;
                    self.current_file_path = None;
                } else {
                    // Empty file
                    File::create(&output_path)?;
                }
            }
            _ => {
                // Skip other file types for now
                eprintln!("Skipping unsupported file type: {:?}", file_header.file_type);
            }
        }

        // Set file metadata
        self.set_file_metadata(&output_path, &file_header)?;

        println!("Extracted: {}", output_path.display());

        Ok(true)
    }

    /// Extract a file that has extents
    fn extract_file_with_extents(&mut self, output_path: &Path, file_size: u128) -> Result<()> {
        let mut output_file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(output_path)?;

        // Set file size
        output_file.set_len(file_size as u64)?;

        let mut current_offset = 0u64;

        // Read extents until we've reconstructed the entire file
        while current_offset < file_size as u64 {
            let extent_header = ExtentHeader::read(&mut self.reader, self.block_size)?;

            match extent_header.extent_type {
                ExtentType::Data => {
                    // Read and write data blocks
                    let data_size = extent_header.length_in_blocks as u64 * self.block_size as u64;
                    let mut data = vec![0u8; data_size as usize];
                    self.reader.read_exact(&mut data)?;

                    // Verify checksum
                    let calculated_checksum = crc32fast::hash(&data);
                    if calculated_checksum != extent_header.checksum {
                        anyhow::bail!(
                            "Checksum mismatch for extent {}: expected {}, got {}",
                            extent_header.extent_id,
                            extent_header.checksum,
                            calculated_checksum
                        );
                    }

                    // Write to output file
                    output_file.seek(SeekFrom::Start(current_offset))?;
                    output_file.write_all(&data)?;

                    // Cache this extent for potential references (with file location for reflinks)
                    let file_location = self.current_file_path.clone().map(|p| (p, current_offset));
                    self.extent_cache.insert(
                        extent_header.extent_id,
                        CachedExtent {
                            extent_id: extent_header.extent_id,
                            data: data.clone(),
                            file_location,
                        },
                    );

                    current_offset += data_size;
                }
                ExtentType::Sparse => {
                    // Sparse extent - just skip (file is already sized correctly with zeros)
                    let skip_size = extent_header.length_in_blocks as u64 * self.block_size as u64;
                    current_offset += skip_size;
                }
                ExtentType::Reference => {
                    // Reference to earlier extent
                    if let Some(cached) = self.extent_cache.get(&extent_header.extent_id) {
                        let data_size = cached.data.len() as u64;
                        let mut reflink_used = false;

                        // Try to use reflink if we have file location information
                        if let Some((ref source_path, source_offset)) = cached.file_location {
                            // Try to open the source file and use FICLONERANGE
                            if let Ok(source_file) = File::open(source_path) {
                                output_file.flush()?; // Ensure file is on disk

                                match crate::reflink::try_reflink_range(
                                    &source_file,
                                    source_offset,
                                    &output_file,
                                    current_offset,
                                    data_size,
                                ) {
                                    Ok(true) => {
                                        // Reflink succeeded!
                                        reflink_used = true;
                                    }
                                    Ok(false) => {
                                        // Reflink not supported, will fall back to copy
                                    }
                                    Err(e) => {
                                        // Reflink failed, will fall back to copy
                                        eprintln!("Warning: reflink failed ({}), falling back to copy", e);
                                    }
                                }
                            }
                        }

                        // Fall back to regular copy if reflink didn't work
                        if !reflink_used {
                            output_file.seek(SeekFrom::Start(current_offset))?;
                            output_file.write_all(&cached.data)?;
                        }

                        current_offset += data_size;
                    } else {
                        anyhow::bail!(
                            "Reference to unknown extent ID: {}",
                            extent_header.extent_id
                        );
                    }
                }
            }
        }

        Ok(())
    }

    /// Set file metadata (permissions, timestamps, ownership)
    fn set_file_metadata(&self, path: &Path, header: &FileHeader) -> Result<()> {
        // Set permissions
        #[cfg(unix)]
        {
            let metadata = fs::metadata(path)?;
            let mut permissions = metadata.permissions();
            // Default to 0644 for files, 0755 for directories
            let mode = if header.file_type == FileType::Directory {
                0o755
            } else {
                0o644
            };
            permissions.set_mode(mode);
            fs::set_permissions(path, permissions)?;
        }

        // Set timestamps
        #[cfg(unix)]
        {
            use std::time::{Duration, SystemTime};

            let _atime = SystemTime::UNIX_EPOCH + Duration::from_secs(header.access_time);
            let _mtime = SystemTime::UNIX_EPOCH + Duration::from_secs(header.modify_time);

            // Use filetime crate for setting times
            // For now, we'll skip this as it requires an additional dependency
            // TODO: Add filetime crate and implement timestamp setting
        }

        // Set ownership (requires root privileges)
        // TODO: Implement ownership setting with appropriate privilege checks

        Ok(())
    }

    /// List all files in the archive without extracting
    pub fn list_files(&mut self) -> Result<Vec<String>> {
        let mut files = Vec::new();

        loop {
            match FileHeader::read(&mut self.reader, self.block_size) {
                Ok(header) => {
                    let path = format!("{}/{}", header.file_path, header.file_name);
                    files.push(path);

                    // Skip extent data if present
                    if header.file_type == FileType::Regular
                        && header.inline_data.is_empty()
                        && header.file_size > 0
                    {
                        self.skip_extents(header.file_size)?;
                    }
                }
                Err(e) => {
                    if e.to_string().contains("failed to fill whole buffer") {
                        break;
                    }
                    return Err(e);
                }
            }
        }

        Ok(files)
    }

    /// Skip over extent data without reading it
    fn skip_extents(&mut self, file_size: u128) -> Result<()> {
        let mut current_offset = 0u64;

        while current_offset < file_size as u64 {
            let extent_header = ExtentHeader::read(&mut self.reader, self.block_size)?;

            match extent_header.extent_type {
                ExtentType::Data => {
                    // Skip data blocks
                    let data_size = extent_header.length_in_blocks as u64 * self.block_size as u64;
                    self.reader.seek(SeekFrom::Current(data_size as i64))?;
                    current_offset += data_size;
                }
                ExtentType::Sparse => {
                    let skip_size = extent_header.length_in_blocks as u64 * self.block_size as u64;
                    current_offset += skip_size;
                }
                ExtentType::Reference => {
                    // References don't have data, just the header
                    let ref_size = extent_header.length_in_blocks as u64 * self.block_size as u64;
                    current_offset += ref_size;
                }
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::create::ArchiveCreator;
    use std::io::Cursor;
    use tempfile::TempDir;

    #[test]
    fn test_extract_empty_archive() {
        let buf = Vec::new();
        let creator = ArchiveCreator::new(Cursor::new(buf), None).unwrap();
        let archive_data = creator.finish().unwrap();

        let temp_dir = TempDir::new().unwrap();
        let cursor = Cursor::new(archive_data);
        let mut extractor = ArchiveExtractor::new(cursor, temp_dir.path().to_path_buf()).unwrap();
        extractor.extract_all().unwrap();
    }
}
