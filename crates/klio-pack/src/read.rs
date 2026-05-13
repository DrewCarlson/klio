//! Pack reader. Validates the header, the pack hash, and decodes the
//! section directory eagerly; section payloads are decoded on demand.

use crate::format::{
    Compression, SectionDirectory, SectionEntry, FORMAT_VERSION, HASHED_REGION_OFFSET, HASH_LEN,
    HASH_OFFSET, MAGIC,
};
use crate::PackError;
use std::borrow::Cow;

/// Parsed view over a pack's bytes. The bytes are kept alive for the
/// lifetime of the reader; payload accessors return borrowed slices for
/// uncompressed sections and owned `Vec<u8>` for compressed ones.
#[derive(Debug)]
pub struct PackReader {
    bytes: Vec<u8>,
    dir: SectionDirectory,
    payload_start: usize,
}

impl PackReader {
    /// Construct a reader from a complete pack byte stream. Verifies the
    /// magic, format version, and pack hash; rejects truncated streams.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, PackError> {
        if bytes.len() < HASHED_REGION_OFFSET + 4 {
            return Err(PackError::Truncated);
        }
        if &bytes[0..4] != MAGIC {
            return Err(PackError::BadMagic);
        }
        let version =
            u32::from_le_bytes(bytes[4..8].try_into().expect("4-byte version slice"));
        if version != FORMAT_VERSION {
            return Err(PackError::VersionMismatch {
                expected: FORMAT_VERSION,
                found: version,
            });
        }
        let stored_hash: [u8; HASH_LEN] = bytes[HASH_OFFSET..HASH_OFFSET + HASH_LEN]
            .try_into()
            .expect("32-byte hash slice");
        let computed = blake3::hash(&bytes[HASHED_REGION_OFFSET..]);
        if computed.as_bytes() != &stored_hash {
            return Err(PackError::HashMismatch);
        }

        let dir_len = u32::from_le_bytes(
            bytes[HASHED_REGION_OFFSET..HASHED_REGION_OFFSET + 4]
                .try_into()
                .expect("4-byte dir_len slice"),
        ) as usize;
        let dir_start = HASHED_REGION_OFFSET + 4;
        let dir_end = dir_start
            .checked_add(dir_len)
            .ok_or(PackError::Truncated)?;
        if dir_end > bytes.len() {
            return Err(PackError::Truncated);
        }
        let dir: SectionDirectory =
            postcard::from_bytes(&bytes[dir_start..dir_end]).map_err(PackError::Decode)?;
        let payload_start = dir_end;
        // Validate that every entry's window lands inside the file.
        for e in &dir.entries {
            let end = e.offset.checked_add(e.stored_len).ok_or(PackError::Truncated)?;
            if (payload_start as u64).checked_add(end).map_or(true, |p| p as usize > bytes.len()) {
                return Err(PackError::Truncated);
            }
        }
        Ok(Self { bytes, dir, payload_start })
    }

    /// Pack format version recorded in the header. Always equal to
    /// [`FORMAT_VERSION`] for readers that successfully parsed.
    #[must_use]
    pub fn format_version(&self) -> u32 {
        FORMAT_VERSION
    }

    /// Borrow the directory entries (sorted by name).
    #[must_use]
    pub fn sections(&self) -> &[SectionEntry] {
        &self.dir.entries
    }

    /// Iterate section names in directory order.
    pub fn section_names(&self) -> impl Iterator<Item = &str> {
        self.dir.entries.iter().map(|e| e.name.as_str())
    }

    /// Read a section by name. Returns the uncompressed payload bytes;
    /// for an uncompressed section the bytes are borrowed from the
    /// in-memory pack image, for a zstd section a fresh `Vec` is built.
    pub fn read_section(&self, name: &str) -> Result<Option<Cow<'_, [u8]>>, PackError> {
        let Some(entry) = self.dir.entries.iter().find(|e| e.name == name) else {
            return Ok(None);
        };
        let start = self.payload_start + entry.offset as usize;
        let end = start + entry.stored_len as usize;
        let stored = &self.bytes[start..end];
        match entry.compression {
            Compression::None => Ok(Some(Cow::Borrowed(stored))),
            Compression::Zstd => {
                let mut out =
                    Vec::with_capacity(usize::try_from(entry.uncompressed_len).unwrap_or(0));
                zstd::stream::copy_decode(stored, &mut out).map_err(PackError::Compression)?;
                if out.len() as u64 != entry.uncompressed_len {
                    return Err(PackError::LengthMismatch {
                        section: entry.name.clone(),
                        expected: entry.uncompressed_len,
                        actual: out.len() as u64,
                    });
                }
                Ok(Some(Cow::Owned(out)))
            }
        }
    }

    /// Compute the pack hash as stored in the header. Useful for
    /// content-addressing on the caller side.
    #[must_use]
    pub fn pack_hash(&self) -> [u8; HASH_LEN] {
        self.bytes[HASH_OFFSET..HASH_OFFSET + HASH_LEN]
            .try_into()
            .expect("32-byte hash slice")
    }
}
