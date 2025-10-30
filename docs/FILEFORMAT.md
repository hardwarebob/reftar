# Overview
The reftar file format has the following requirements
* large blocks (4k or higher) and block alignment to support direct reflinking of files.
* Superset of tar functionality
* Ability to link extents in later files to files earlier in the archive
* Ability to stream the archive.
* Ability to interrupt archive creation and retain what has been created so far.
* Focus on modern support and flexibility over file size efficiency. UTF8 filename support.
All data is little endian.

# Archive Header
This is the main header for the archive and has basic information about how/when/where it was created. Inspired directly from the tar format, but expanded for modern contexts and usage.

| Name  | size (bytes) | type  | Notes  | 
|---|---|---|---|
|reftar magic bytes| 6 |literal string|"reftar"
|reftar archive version|2|int8| version is set to 1.
|block size| 4 | int32| Block size in bytes - default is 4096|
|Padding | n | 0x00 literal | padded with 0x00 to blocksize boundary 

# Files
Each file has a header, and 0-N extent/data sections

## File Header

| Name  | size (bytes) | type  | Notes |
| --- | --- | --- | --- |
| Header magic | 4| literal | 'FILE'
| Header size| 4| int | Total size of file header to read
| File Size | 12 | int | Reported file size. If under blocksize (and not reflinked), there is no extent header or blocks   |
| File Type | 1 | char | File type - the same as tar.
| UID | 8 | int |
| GID | 8 | int |
| device major | 8 |int
| device minor | 8 |int
| Access time | 8 |int
| Modifiy Time | 8 |int
| Creation Time | 8 |int
| Username | 4+n | size+char |
| Groupname | 4+n| size+char |
| File Path  | 4+n | size+char |
| File Name | 4+n| size+char |
| Link Name | 4+n| size+char || Name of linked file (if symbolic link)
| Extended permissions | 4+n | size+char | binary blob of extended permissions. This is verbatim from filesystem.
| Source filesystem type | 128 | char | Indicates the source filesystem to allow confirmation for extended permissions
| source Filesystem ID | 8 | int | UUID of source filesystem 
| File Data | n | |For files that are under block size
| Padding | n | 0x00 literal | padded with 0x00 to blocksize boundary 

Following the file header, we have N extent sections, which may or may not include blocks

### extent header

| Name | size (bytes) | type | Notes |
| --- | --- | --- | --- |
| extent ID | 8 | int | Unique ID of the extent within the file
| length in blocks | 4 | int | Number of blocks - can be 0 for sparse references
| Extent type | 1 | char | Extent type can be D (data), S (sparse) or R (reference - ) If block is a reference, the extent ID must match a previous existing extent in the file.
| source extent start | 8 | int | Used when adding new files - the location of the block on the original filesystem.
| checksum | 4 | CRC | Checksum for data blocks.  Empty for sparse extents or references.
| Padding | n | 0x00 literal | padded with 0x00 to blocksize boundary 
### Extent Block data
Raw data - length in blocks * block length.  If the archive is created on the same filesystem as the source file, this can be reflinked, rather than copied.





# Archive footer
This is optional, but contains summary information about the archive
TODO
