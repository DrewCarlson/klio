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
    /// Optional zstd dictionary bytes. When supplied, sections
    /// added via `add_zstd_dict` compress against it and the
    /// dictionary is emitted as a `zstd_dict` section so readers
    /// can decompress without out-of-band state.
    zstd_dict: Option<Vec<u8>>,
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

    /// Compress this section against the writer's zstd dictionary.
    /// Calling this without first calling [`Self::set_zstd_dict`]
    /// produces an error at [`Self::finish`].
    pub fn add_zstd_dict(&mut self, name: impl Into<String>, payload: Vec<u8>) -> &mut Self {
        self.add_section(name, payload, Compression::ZstdDict)
    }

    /// Attach a zstd dictionary to this pack. Subsequent
    /// [`Self::add_zstd_dict`] calls compress against the
    /// dictionary; the dictionary itself is emitted as a
    /// `zstd_dict` section.
    pub fn set_zstd_dict(&mut self, bytes: Vec<u8>) -> &mut Self {
        self.zstd_dict = Some(bytes);
        self
    }

    /// Encode the pack to a byte vector. Output is deterministic for a
    /// given set of input sections.
    pub fn finish(mut self) -> Result<Vec<u8>, PackError> {
        // Emit the dictionary as a `zstd_dict` section so readers
        // can resolve it on load. If the user explicitly added a
        // zstd_dict section we honour theirs.
        if let Some(dict) = &self.zstd_dict {
            if !self.sections.iter().any(|s| s.name == section_names::ZSTD_DICT) {
                self.sections.push(PendingSection {
                    name: section_names::ZSTD_DICT.to_string(),
                    payload: dict.clone(),
                    compression: Compression::None,
                });
            }
        }
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
        let dict_for_encode = self.zstd_dict.clone();
        for s in self.sections {
            let uncompressed_len = s.payload.len() as u64;
            let stored = match s.compression {
                Compression::None => s.payload,
                Compression::Zstd => zstd::stream::encode_all(s.payload.as_slice(), DEFAULT_ZSTD_LEVEL)
                    .map_err(PackError::Compression)?,
                Compression::ZstdDict => {
                    let dict = dict_for_encode.as_ref().ok_or_else(|| {
                        PackError::Compression(std::io::Error::new(
                            std::io::ErrorKind::InvalidInput,
                            "ZstdDict section requires set_zstd_dict before finish",
                        ))
                    })?;
                    let mut encoder =
                        zstd::stream::Encoder::with_dictionary(Vec::new(), DEFAULT_ZSTD_LEVEL, dict)
                            .map_err(PackError::Compression)?;
                    use std::io::Write;
                    encoder.write_all(&s.payload).map_err(PackError::Compression)?;
                    encoder.finish().map_err(PackError::Compression)?
                }
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
