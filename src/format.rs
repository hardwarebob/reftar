//! Reftar file format structures and constants
//!
//! This module defines the binary format for reftar archives, including:
//! - Archive headers
//! - File headers
//! - Extent headers and data blocks

use std::io::{self, Read, Write};
use anyhow::Result;

/// Magic bytes at the start of every reftar archive
pub const REFTAR_MAGIC: &[u8; 6] = b"reftar";

/// Current archive format version
pub const REFTAR_VERSION: u16 = 1;

/// Default block size (4KB)
pub const DEFAULT_BLOCK_SIZE: u32 = 4096;

/// File header magic bytes
pub const FILE_HEADER_MAGIC: &[u8; 4] = b"FILE";

/// Archive header structure
#[derive(Debug, Clone)]
pub struct ArchiveHeader {
    pub version: u16,
    pub block_size: u32,
}

impl ArchiveHeader {
    pub fn new(block_size: u32) -> Self {
        Self {
            version: REFTAR_VERSION,
            block_size,
        }
    }

    /// Write the archive header to a writer
    pub fn write<W: Write>(&self, writer: &mut W) -> Result<()> {
        // Write magic bytes
        writer.write_all(REFTAR_MAGIC)?;

        // Write version (2 bytes, little endian)
        writer.write_all(&self.version.to_le_bytes())?;

        // Write block size (4 bytes, little endian)
        writer.write_all(&self.block_size.to_le_bytes())?;

        // Calculate padding needed to reach block boundary
        let header_size = 6 + 2 + 4; // magic + version + block_size
        let padding = (self.block_size as usize - header_size) % self.block_size as usize;

        // Write padding
        let padding_buf = vec![0u8; padding];
        writer.write_all(&padding_buf)?;

        Ok(())
    }

    /// Read the archive header from a reader
    pub fn read<R: Read>(reader: &mut R) -> Result<Self> {
        // Read and verify magic bytes
        let mut magic = [0u8; 6];
        reader.read_exact(&mut magic)?;
        if &magic != REFTAR_MAGIC {
            anyhow::bail!("Invalid reftar magic bytes");
        }

        // Read version
        let mut version_buf = [0u8; 2];
        reader.read_exact(&mut version_buf)?;
        let version = u16::from_le_bytes(version_buf);

        // Read block size
        let mut block_size_buf = [0u8; 4];
        reader.read_exact(&mut block_size_buf)?;
        let block_size = u32::from_le_bytes(block_size_buf);

        // Skip padding to block boundary
        let header_size = 6 + 2 + 4;
        let padding = (block_size as usize - header_size) % block_size as usize;
        let mut padding_buf = vec![0u8; padding];
        reader.read_exact(&mut padding_buf)?;

        Ok(Self {
            version,
            block_size,
        })
    }
}

/// File type indicator (compatible with tar)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FileType {
    Regular = b'0',
    HardLink = b'1',
    SymbolicLink = b'2',
    CharDevice = b'3',
    BlockDevice = b'4',
    Directory = b'5',
    FIFO = b'6',
}

impl FileType {
    pub fn from_byte(b: u8) -> Result<Self> {
        match b {
            b'0' => Ok(FileType::Regular),
            b'1' => Ok(FileType::HardLink),
            b'2' => Ok(FileType::SymbolicLink),
            b'3' => Ok(FileType::CharDevice),
            b'4' => Ok(FileType::BlockDevice),
            b'5' => Ok(FileType::Directory),
            b'6' => Ok(FileType::FIFO),
            _ => anyhow::bail!("Invalid file type: {}", b),
        }
    }
}

/// File header structure
#[derive(Debug, Clone)]
pub struct FileHeader {
    pub file_size: u128,
    pub file_type: FileType,
    pub uid: u64,
    pub gid: u64,
    pub device_major: u64,
    pub device_minor: u64,
    pub access_time: u64,
    pub modify_time: u64,
    pub creation_time: u64,
    pub username: String,
    pub groupname: String,
    pub file_path: String,
    pub file_name: String,
    pub link_name: String,
    pub extended_permissions: Vec<u8>,
    pub source_filesystem_type: String,
    pub source_filesystem_id: u64,
    pub inline_data: Vec<u8>, // For files under block size
}

impl FileHeader {
    /// Calculate the total size of the file header when serialized
    fn calculate_size(&self) -> u32 {
        let mut size = 0u32;
        size += 4; // magic
        size += 4; // header_size
        size += 12; // file_size
        size += 1; // file_type
        size += 8; // uid
        size += 8; // gid
        size += 8; // device_major
        size += 8; // device_minor
        size += 8; // access_time
        size += 8; // modify_time
        size += 8; // creation_time
        size += 4 + self.username.len() as u32; // username
        size += 4 + self.groupname.len() as u32; // groupname
        size += 4 + self.file_path.len() as u32; // file_path
        size += 4 + self.file_name.len() as u32; // file_name
        size += 4 + self.link_name.len() as u32; // link_name
        size += 4 + self.extended_permissions.len() as u32; // extended_permissions
        size += 128; // source_filesystem_type (fixed 128 bytes)
        size += 8; // source_filesystem_id
        size += self.inline_data.len() as u32; // inline data
        size
    }

    /// Write the file header to a writer
    pub fn write<W: Write>(&self, writer: &mut W, block_size: u32) -> Result<()> {
        // Write magic
        writer.write_all(FILE_HEADER_MAGIC)?;

        // Calculate and write header size
        let header_size = self.calculate_size();
        writer.write_all(&header_size.to_le_bytes())?;

        // Write file size (12 bytes for u128, but we use first 12 bytes)
        let file_size_bytes = self.file_size.to_le_bytes();
        writer.write_all(&file_size_bytes[..12])?;

        // Write file type
        writer.write_all(&[self.file_type as u8])?;

        // Write metadata
        writer.write_all(&self.uid.to_le_bytes())?;
        writer.write_all(&self.gid.to_le_bytes())?;
        writer.write_all(&self.device_major.to_le_bytes())?;
        writer.write_all(&self.device_minor.to_le_bytes())?;
        writer.write_all(&self.access_time.to_le_bytes())?;
        writer.write_all(&self.modify_time.to_le_bytes())?;
        writer.write_all(&self.creation_time.to_le_bytes())?;

        // Write strings with length prefix
        write_length_prefixed_string(writer, &self.username)?;
        write_length_prefixed_string(writer, &self.groupname)?;
        write_length_prefixed_string(writer, &self.file_path)?;
        write_length_prefixed_string(writer, &self.file_name)?;
        write_length_prefixed_string(writer, &self.link_name)?;

        // Write extended permissions with length prefix
        writer.write_all(&(self.extended_permissions.len() as u32).to_le_bytes())?;
        writer.write_all(&self.extended_permissions)?;

        // Write source filesystem type (fixed 128 bytes)
        let mut fs_type_buf = [0u8; 128];
        let fs_type_bytes = self.source_filesystem_type.as_bytes();
        let copy_len = fs_type_bytes.len().min(128);
        fs_type_buf[..copy_len].copy_from_slice(&fs_type_bytes[..copy_len]);
        writer.write_all(&fs_type_buf)?;

        // Write source filesystem ID
        writer.write_all(&self.source_filesystem_id.to_le_bytes())?;

        // Write inline data if present
        if !self.inline_data.is_empty() {
            writer.write_all(&self.inline_data)?;
        }

        // Pad to block boundary
        let padding = (block_size as usize - (header_size as usize % block_size as usize)) % block_size as usize;
        let padding_buf = vec![0u8; padding];
        writer.write_all(&padding_buf)?;

        Ok(())
    }

    /// Read the file header from a reader
    pub fn read<R: Read>(reader: &mut R, block_size: u32) -> Result<Self> {
        // Read and verify magic
        let mut magic = [0u8; 4];
        reader.read_exact(&mut magic)?;
        if &magic != FILE_HEADER_MAGIC {
            anyhow::bail!("Invalid file header magic");
        }

        // Read header size
        let mut header_size_buf = [0u8; 4];
        reader.read_exact(&mut header_size_buf)?;
        let header_size = u32::from_le_bytes(header_size_buf);

        // Read file size (12 bytes)
        let mut file_size_buf = [0u8; 16];
        reader.read_exact(&mut file_size_buf[..12])?;
        let file_size = u128::from_le_bytes(file_size_buf);

        // Read file type
        let mut file_type_buf = [0u8; 1];
        reader.read_exact(&mut file_type_buf)?;
        let file_type = FileType::from_byte(file_type_buf[0])?;

        // Read metadata
        let uid = read_u64(reader)?;
        let gid = read_u64(reader)?;
        let device_major = read_u64(reader)?;
        let device_minor = read_u64(reader)?;
        let access_time = read_u64(reader)?;
        let modify_time = read_u64(reader)?;
        let creation_time = read_u64(reader)?;

        // Read strings with length prefix
        let username = read_length_prefixed_string(reader)?;
        let groupname = read_length_prefixed_string(reader)?;
        let file_path = read_length_prefixed_string(reader)?;
        let file_name = read_length_prefixed_string(reader)?;
        let link_name = read_length_prefixed_string(reader)?;

        // Read extended permissions
        let mut ext_perm_len_buf = [0u8; 4];
        reader.read_exact(&mut ext_perm_len_buf)?;
        let ext_perm_len = u32::from_le_bytes(ext_perm_len_buf);
        let mut extended_permissions = vec![0u8; ext_perm_len as usize];
        reader.read_exact(&mut extended_permissions)?;

        // Read source filesystem type (fixed 128 bytes)
        let mut fs_type_buf = [0u8; 128];
        reader.read_exact(&mut fs_type_buf)?;
        let source_filesystem_type = String::from_utf8_lossy(&fs_type_buf)
            .trim_end_matches('\0')
            .to_string();

        // Read source filesystem ID
        let source_filesystem_id = read_u64(reader)?;

        // Determine if we have inline data
        let inline_data = if file_size < block_size as u128 && file_type == FileType::Regular {
            let mut data = vec![0u8; file_size as usize];
            reader.read_exact(&mut data)?;
            data
        } else {
            Vec::new()
        };

        // Skip padding to block boundary
        let total_read = header_size as usize;
        let padding = (block_size as usize - (total_read % block_size as usize)) % block_size as usize;
        let mut padding_buf = vec![0u8; padding];
        reader.read_exact(&mut padding_buf)?;

        Ok(Self {
            file_size,
            file_type,
            uid,
            gid,
            device_major,
            device_minor,
            access_time,
            modify_time,
            creation_time,
            username,
            groupname,
            file_path,
            file_name,
            link_name,
            extended_permissions,
            source_filesystem_type,
            source_filesystem_id,
            inline_data,
        })
    }
}

/// Extent type indicator
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ExtentType {
    Data = b'D',       // Regular data block
    Sparse = b'S',     // Sparse/hole (no data)
    Reference = b'R',  // Reference to earlier extent
}

impl ExtentType {
    pub fn from_byte(b: u8) -> Result<Self> {
        match b {
            b'D' => Ok(ExtentType::Data),
            b'S' => Ok(ExtentType::Sparse),
            b'R' => Ok(ExtentType::Reference),
            _ => anyhow::bail!("Invalid extent type: {}", b as char),
        }
    }
}

/// Extent header structure
#[derive(Debug, Clone)]
pub struct ExtentHeader {
    pub extent_id: u64,
    pub length_in_blocks: u32,
    pub extent_type: ExtentType,
    pub source_extent_start: u64,
    pub checksum: u32,
}

impl ExtentHeader {
    /// Write the extent header to a writer
    pub fn write<W: Write>(&self, writer: &mut W, block_size: u32) -> Result<()> {
        writer.write_all(&self.extent_id.to_le_bytes())?;
        writer.write_all(&self.length_in_blocks.to_le_bytes())?;
        writer.write_all(&[self.extent_type as u8])?;
        writer.write_all(&self.source_extent_start.to_le_bytes())?;
        writer.write_all(&self.checksum.to_le_bytes())?;

        // Pad to block boundary
        let header_size = 8 + 4 + 1 + 8 + 4; // = 25 bytes
        let padding = (block_size as usize - header_size) % block_size as usize;
        let padding_buf = vec![0u8; padding];
        writer.write_all(&padding_buf)?;

        Ok(())
    }

    /// Read the extent header from a reader
    pub fn read<R: Read>(reader: &mut R, block_size: u32) -> Result<Self> {
        let extent_id = read_u64(reader)?;
        let length_in_blocks = read_u32(reader)?;

        let mut extent_type_buf = [0u8; 1];
        reader.read_exact(&mut extent_type_buf)?;
        let extent_type = ExtentType::from_byte(extent_type_buf[0])?;

        let source_extent_start = read_u64(reader)?;
        let checksum = read_u32(reader)?;

        // Skip padding to block boundary
        let header_size = 8 + 4 + 1 + 8 + 4;
        let padding = (block_size as usize - header_size) % block_size as usize;
        let mut padding_buf = vec![0u8; padding];
        reader.read_exact(&mut padding_buf)?;

        Ok(Self {
            extent_id,
            length_in_blocks,
            extent_type,
            source_extent_start,
            checksum,
        })
    }
}

// Helper functions for reading/writing

fn write_length_prefixed_string<W: Write>(writer: &mut W, s: &str) -> io::Result<()> {
    let bytes = s.as_bytes();
    writer.write_all(&(bytes.len() as u32).to_le_bytes())?;
    writer.write_all(bytes)?;
    Ok(())
}

fn read_length_prefixed_string<R: Read>(reader: &mut R) -> Result<String> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf);

    let mut string_buf = vec![0u8; len as usize];
    reader.read_exact(&mut string_buf)?;

    Ok(String::from_utf8(string_buf)?)
}

fn read_u64<R: Read>(reader: &mut R) -> Result<u64> {
    let mut buf = [0u8; 8];
    reader.read_exact(&mut buf)?;
    Ok(u64::from_le_bytes(buf))
}

fn read_u32<R: Read>(reader: &mut R) -> Result<u32> {
    let mut buf = [0u8; 4];
    reader.read_exact(&mut buf)?;
    Ok(u32::from_le_bytes(buf))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_archive_header_roundtrip() {
        let header = ArchiveHeader::new(4096);
        let mut buf = Vec::new();
        header.write(&mut buf).unwrap();

        let mut cursor = Cursor::new(buf);
        let read_header = ArchiveHeader::read(&mut cursor).unwrap();

        assert_eq!(header.version, read_header.version);
        assert_eq!(header.block_size, read_header.block_size);
    }
}
