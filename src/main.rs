mod create;
mod extract;
mod format;
mod reflink;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::fs::{File, OpenOptions};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "reftar")]
#[command(version = "0.1.0")]
#[command(about = "A tar-like utility with support for reflinks and shared data blocks", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Create a new archive
    Create {
        /// Output archive file
        #[arg(short = 'f', long)]
        file: PathBuf,

        /// Block size in bytes (default: 4096)
        #[arg(short = 'b', long)]
        block_size: Option<u32>,

        /// Files or directories to add to the archive
        #[arg(required = true)]
        inputs: Vec<PathBuf>,

        /// Verbose output
        #[arg(short = 'v', long)]
        verbose: bool,
    },

    /// Extract files from an archive
    Extract {
        /// Input archive file
        #[arg(short = 'f', long)]
        file: PathBuf,

        /// Output directory (default: current directory)
        #[arg(short = 'C', long, default_value = ".")]
        output_dir: PathBuf,

        /// Verbose output
        #[arg(short = 'v', long)]
        verbose: bool,
    },

    /// List files in an archive
    List {
        /// Input archive file
        #[arg(short = 'f', long)]
        file: PathBuf,

        /// Verbose output
        #[arg(short = 'v', long)]
        verbose: bool,
    },

    /// Show archive information
    Info {
        /// Input archive file
        #[arg(short = 'f', long)]
        file: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Create {
            file,
            block_size,
            inputs,
            verbose,
        } => create_archive(file, block_size, inputs, verbose)?,

        Commands::Extract {
            file,
            output_dir,
            verbose,
        } => extract_archive(file, output_dir, verbose)?,

        Commands::List { file, verbose } => list_archive(file, verbose)?,

        Commands::Info { file } => show_archive_info(file)?,
    }

    Ok(())
}

fn create_archive(
    output_path: PathBuf,
    block_size: Option<u32>,
    inputs: Vec<PathBuf>,
    verbose: bool,
) -> Result<()> {
    if verbose {
        println!("Creating archive: {}", output_path.display());
        if let Some(bs) = block_size {
            println!("Block size: {} bytes", bs);
        }
    }

    let output_file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&output_path)
        .with_context(|| format!("Failed to create archive file: {:?}", output_path))?;

    let mut creator = create::ArchiveCreator::new(output_file, block_size)?;

    for input in inputs {
        if verbose {
            println!("Adding: {}", input.display());
        }

        let metadata = std::fs::metadata(&input)
            .with_context(|| format!("Failed to read metadata for {:?}", input))?;

        if metadata.is_dir() {
            creator.add_directory(&input, std::path::Path::new(""))?;
        } else {
            let file_name = input
                .file_name()
                .ok_or_else(|| anyhow::anyhow!("Invalid file name"))?;
            creator.add_file(&input, std::path::Path::new(file_name))?;
        }
    }

    creator.finish()?;

    if verbose {
        println!("Archive created successfully");
    }

    Ok(())
}

fn extract_archive(input_path: PathBuf, output_dir: PathBuf, verbose: bool) -> Result<()> {
    if verbose {
        println!("Extracting archive: {}", input_path.display());
        println!("Output directory: {}", output_dir.display());
    }

    let input_file = File::open(&input_path)
        .with_context(|| format!("Failed to open archive file: {:?}", input_path))?;

    // Create output directory if it doesn't exist
    std::fs::create_dir_all(&output_dir)?;

    let mut extractor = extract::ArchiveExtractor::new(input_file, output_dir)?;

    extractor.extract_all()?;

    if verbose {
        println!("Extraction completed successfully");
    }

    Ok(())
}

fn list_archive(input_path: PathBuf, verbose: bool) -> Result<()> {
    if verbose {
        println!("Listing archive: {}", input_path.display());
        println!();
    }

    let input_file = File::open(&input_path)
        .with_context(|| format!("Failed to open archive file: {:?}", input_path))?;

    let mut extractor = extract::ArchiveExtractor::new(input_file, PathBuf::from("/tmp"))?;

    let files = extractor.list_files()?;

    for file in &files {
        println!("{}", file);
    }

    if verbose {
        println!();
        println!("Total files: {}", files.len());
    }

    Ok(())
}

fn show_archive_info(input_path: PathBuf) -> Result<()> {
    let mut input_file = File::open(&input_path)
        .with_context(|| format!("Failed to open archive file: {:?}", input_path))?;

    let header = format::ArchiveHeader::read(&mut input_file)?;

    println!("Archive Information:");
    println!("  Format version: {}", header.version);
    println!("  Block size: {} bytes", header.block_size);

    // Get file size
    let metadata = std::fs::metadata(&input_path)?;
    println!("  Archive size: {} bytes ({:.2} MB)", metadata.len(), metadata.len() as f64 / 1024.0 / 1024.0);

    Ok(())
}
