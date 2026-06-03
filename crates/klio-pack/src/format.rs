//! On-disk format constants and shared types for `.klio-pack` files.
//!
//! A pack is a single file:
//!
//! ```text
//! +-------------------------+
//! | magic       "KPK\0"     |  4 bytes
//! | version     u32 LE      |  4
//! | flags       u32 LE      |  4
//! | pack_hash   [u8; 32]    | 32   blake3 of every byte after this field
//! | dir_len     u32 LE      |  4
//! | dir         [u8; ...]   |      postcard-encoded SectionDirectory
//! | payloads    [u8; ...]   |      concatenated section bodies
//! +-------------------------+
//! ```
//!
//! The directory lists every section; each entry records its offset
//! (relative to the start of the payload area), on-disk length, the
//! uncompressed length when [`Compression::Zstd`] is in use, and a
//! compression tag. Readers may skip unknown sections without
//! understanding their contents.

use serde::{Deserialize, Serialize};

/// Magic bytes at the start of every pack file.
pub const MAGIC: &[u8; 4] = b"KPK\0";

/// Pack format version. Bumped when the on-disk layout or the
/// `SectionDirectory` schema changes incompatibly. v2 added pack
/// features (`PackManifest.default_features`/`features`, per-dependency
/// `features`/`default_features`); postcard is sequential, so old packs
/// are rejected on read and must be rebuilt.
pub const FORMAT_VERSION: u32 = 2;

/// Length of the blake3 pack hash, in bytes.
pub const HASH_LEN: usize = 32;

/// Compression scheme applied to a section payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum Compression {
    None = 0,
    Zstd = 1,
    /// zstd compressed against the dictionary bytes carried in
    /// this pack's `zstd_dict` section. Section is rejected if
    /// the pack does not carry a matching dictionary.
    ZstdDict = 2,
}

/// Directory entry for one section. Names are case-sensitive byte strings;
/// well-known names are listed under [`section_names`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SectionEntry {
    /// Section name (e.g. `"manifest"`).
    pub name: String,
    /// Offset of the section payload from the start of the payload area.
    pub offset: u64,
    /// On-disk length of the payload (compressed when `compression != None`).
    pub stored_len: u64,
    /// Uncompressed length. Equal to `stored_len` for [`Compression::None`].
    pub uncompressed_len: u64,
    /// Compression scheme applied to the payload bytes.
    pub compression: Compression,
}

/// Sorted directory of section entries. Sections are ordered by name so
/// the encoded directory is byte-deterministic for a given input set.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SectionDirectory {
    pub entries: Vec<SectionEntry>,
}

/// Well-known section names. Sections outside this list are still legal —
/// readers must tolerate them — but tooling keys off these constants.
pub mod section_names {
    pub const MANIFEST: &str = "manifest";
    /// Raw `.kt` source bytes carried in the pack. The interpreter
    /// parses these at install time. Frozen AST sections (`ast`,
    /// `resolved`, `typeck`) are reserved for a later phase that
    /// adds serde derives across the front-end crates.
    pub const SOURCES: &str = "sources";
    pub const AST: &str = "ast";
    pub const RESOLVED: &str = "resolved";
    pub const TYPECK: &str = "typeck";
    pub const SYMBOLS: &str = "symbols";
    pub const BINDINGS: &str = "bindings";
    pub const TESTS: &str = "tests";
    pub const DEBUG: &str = "debug";
    /// Raw zstd dictionary bytes. When present, sections marked
    /// `Compression::ZstdDict` decode against these bytes.
    pub const ZSTD_DICT: &str = "zstd_dict";
}

/// Byte offset of the `dir_len` u32 inside the file header. Useful for
/// readers walking the header without recomputing the layout.
pub const DIR_LEN_OFFSET: usize = 4 + 4 + 4 + HASH_LEN;

/// Byte offset where the hashed region begins. Everything from this
/// offset to end-of-file participates in `pack_hash`.
pub const HASHED_REGION_OFFSET: usize = DIR_LEN_OFFSET;

/// Byte offset of the `pack_hash` field inside the header.
pub const HASH_OFFSET: usize = 4 + 4 + 4;
