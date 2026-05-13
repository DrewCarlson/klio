//! Pack writer. Builds a `.klio-pack` byte stream deterministically.

use crate::format::{
    section_names, Compression, SectionDirectory, SectionEntry, FORMAT_VERSION, HASHED_REGION_OFFSET,
    HASH_LEN, MAGIC,
};
use crate::PackError;

/// Default zstd compression level. Level 3 is the zstd default — fast
/// to encode and decompresses near memcpy speed; the pack format trades
/// a bit of size for fast load times.
pub const DEFAULT_ZSTD_LEVEL: i32 = 3;

/// Builder for a pack file. Sections are added in any order and sorted
/// at finish-time so the encoded directory is deterministic.
#[derive(Debug, Default)]
pub struct PackWriter {
    sections: Vec<PendingSection>,
    flags: u32,
}

#[derive(Debug)]
struct PendingSection {
    name: String,
    payload: Vec<u8>,
    compression: Compression,
}

impl PackWriter {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the `flags` field in the pack header. Reserved for future use.
    pub fn set_flags(&mut self, flags: u32) -> &mut Self {
        self.flags = flags;
        self
    }

    /// Add a section. `name` must be unique within the pack; duplicates
    /// are rejected at [`Self::finish`].
    pub fn add_section(
        &mut self,
        name: impl Into<String>,
        payload: Vec<u8>,
        compression: Compression,
    ) -> &mut Self {
        self.sections.push(PendingSection {
            name: name.into(),
            payload,
            compression,
        });
        self
    }

    /// Convenience: add an uncompressed section.
    pub fn add_raw(&mut self, name: impl Into<String>, payload: Vec<u8>) -> &mut Self {
        self.add_section(name, payload, Compression::None)
    }

    /// Convenience: add a zstd-compressed section at the default level.
    pub fn add_zstd(&mut self, name: impl Into<String>, payload: Vec<u8>) -> &mut Self {
        self.add_section(name, payload, Compression::Zstd)
    }

    /// Encode the pack to a byte vector. Output is deterministic for a
    /// given set of input sections.
    pub fn finish(mut self) -> Result<Vec<u8>, PackError> {
        // Sort by section name so the encoded directory and payload
        // ordering are stable across builds.
        self.sections.sort_by(|a, b| a.name.cmp(&b.name));
        let mut seen = std::collections::BTreeSet::new();
        for s in &self.sections {
            if !seen.insert(s.name.as_str()) {
                return Err(PackError::DuplicateSection(s.name.clone()));
            }
        }

        // First pass: build directory entries and the concatenated
        // payload buffer with each section optionally compressed.
        let mut payloads: Vec<u8> = Vec::new();
        let mut entries: Vec<SectionEntry> = Vec::with_capacity(self.sections.len());
        for s in self.sections {
            let uncompressed_len = s.payload.len() as u64;
            let stored = match s.compression {
                Compression::None => s.payload,
                Compression::Zstd => zstd::stream::encode_all(s.payload.as_slice(), DEFAULT_ZSTD_LEVEL)
                    .map_err(PackError::Compression)?,
            };
            let offset = payloads.len() as u64;
            let stored_len = stored.len() as u64;
            payloads.extend_from_slice(&stored);
            entries.push(SectionEntry {
                name: s.name,
                offset,
                stored_len,
                uncompressed_len,
                compression: s.compression,
            });
        }

        let dir = SectionDirectory { entries };
        let dir_bytes = postcard::to_allocvec(&dir).map_err(PackError::Encode)?;
        let dir_len: u32 = dir_bytes
            .len()
            .try_into()
            .map_err(|_| PackError::DirectoryTooLarge(dir_bytes.len()))?;

        // Second pass: assemble the final file. Layout matches `format.rs`.
        let mut out: Vec<u8> = Vec::with_capacity(
            HASHED_REGION_OFFSET + 4 + dir_bytes.len() + payloads.len(),
        );
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
        out.extend_from_slice(&self.flags.to_le_bytes());
        // Reserve hash slot; filled in below once the hashed region is known.
        let hash_slot = out.len();
        out.extend_from_slice(&[0u8; HASH_LEN]);
        out.extend_from_slice(&dir_len.to_le_bytes());
        out.extend_from_slice(&dir_bytes);
        out.extend_from_slice(&payloads);

        // Hash everything after the hash field.
        let hash = blake3::hash(&out[hash_slot + HASH_LEN..]);
        out[hash_slot..hash_slot + HASH_LEN].copy_from_slice(hash.as_bytes());

        let _ = section_names::MANIFEST; // anchor the constant in scope
        Ok(out)
    }
}
