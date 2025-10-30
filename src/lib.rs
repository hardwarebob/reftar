//! Reftar - A tar-like utility with reflink support
//!
//! This library provides functionality for creating and extracting archives
//! with support for filesystem reflinks (copy-on-write) and data deduplication.

pub mod create;
pub mod extract;
pub mod format;
pub mod reflink;

pub use create::ArchiveCreator;
pub use extract::ArchiveExtractor;
pub use format::{ArchiveHeader, FileHeader, ExtentHeader, FileType, ExtentType};
