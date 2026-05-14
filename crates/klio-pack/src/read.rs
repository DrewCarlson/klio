//! Pack reader. Validates the header, the pack hash, and decodes the
//! section directory eagerly; section payloads are decoded on demand.

use crate::format::{
    Compression, SectionDirectory, SectionEntry, FORMAT_VERSION, HASHED_REGION_OFFSET, HASH_LEN,
    HASH_OFFSET, MAGIC,
};
use crate::PackError;
use std::borrow::Cow;

/// Backing storage for a pack reader. Owned bytes survive any
/// file-handle lifetime; mmap'd bytes are kept alive via the
/// `memmap2::Mmap` handle.
enum Bytes {
    Owned(Vec<u8>),
    Mmap {
        // Keep the file open for as long as the mapping is live. Some
        // OSes (notably Linux) allow the mapping to outlive the file
        // descriptor, but holding the handle keeps the contract
        // explicit on every platform.
        _file: std::fs::File,
        map: memmap2::Mmap,
    },
}

impl Bytes {
    fn as_slice(&self) -> &[u8] {
        match self {
            Self::Owned(v) => v.as_slice(),
            Self::Mmap { map, .. } => &map[..],
        }
    }
}

impl std::fmt::Debug for Bytes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Owned(v) => f.debug_tuple("Owned").field(&v.len()).finish(),
            Self::Mmap { map, .. } => f.debug_tuple("Mmap").field(&map.len()).finish(),
        }
    }
}

/// Parsed view over a pack's bytes. The bytes are kept alive for the
/// lifetime of the reader; payload accessors return borrowed slices for
/// uncompressed sections and owned `Vec<u8>` for compressed ones.
#[derive(Debug)]
pub struct PackReader {
    bytes: Bytes,
    dir: SectionDirectory,
    payload_start: usize,
}

impl PackReader {
    /// Construct a reader by loading the file at `path` and decoding
    /// its bytes via a single `std::fs::read` allocation. Use
    /// [`PackReader::from_path_mmap`] for large packs where startup
    /// cost matters.
    pub fn from_path(path: &std::path::Path) -> Result<Self, PackError> {
        let bytes = std::fs::read(path).map_err(PackError::Compression)?;
        Self::from_bytes(bytes)
    }

    /// Construct a reader that mmap's the pack file. The mapping
    /// stays alive for the reader's lifetime. Verifies magic, format
    /// version, and pack hash exactly like [`Self::from_bytes`]; the
    /// only difference is the backing storage. Useful for multi-MB
    /// packs (third-party libraries, debug-section-bearing builds)
    /// where the `std::fs::read` copy would dominate startup.
    pub fn from_path_mmap(path: &std::path::Path) -> Result<Self, PackError> {
        let file = std::fs::File::open(path).map_err(PackError::Compression)?;
        // SAFETY: `Mmap::map` is read-only and the underlying file is
        // held open via the `_file` field so the mapping cannot be
        // unmapped by an OS-level GC of the descriptor. The reader
        // never `as_mut`'s the slice.
        let map = unsafe { memmap2::Mmap::map(&file) }.map_err(PackError::Compression)?;
        Self::from_storage(Bytes::Mmap { _file: file, map })
    }

    /// Construct a reader from a complete pack byte stream. Verifies the
    /// magic, format version, and pack hash; rejects truncated streams.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, PackError> {
        Self::from_storage(Bytes::Owned(bytes))
    }

    fn from_storage(bytes: Bytes) -> Result<Self, PackError> {
        let buf = bytes.as_slice();
        if buf.len() < HASHED_REGION_OFFSET + 4 {
            return Err(PackError::Truncated);
        }
        if &buf[0..4] != MAGIC {
            return Err(PackError::BadMagic);
        }
        let version =
            u32::from_le_bytes(buf[4..8].try_into().expect("4-byte version slice"));
        if version != FORMAT_VERSION {
            return Err(PackError::VersionMismatch {
                expected: FORMAT_VERSION,
                found: version,
            });
        }
        let stored_hash: [u8; HASH_LEN] = buf[HASH_OFFSET..HASH_OFFSET + HASH_LEN]
            .try_into()
            .expect("32-byte hash slice");
        let computed = blake3::hash(&buf[HASHED_REGION_OFFSET..]);
        if computed.as_bytes() != &stored_hash {
            return Err(PackError::HashMismatch);
        }

        let dir_len = u32::from_le_bytes(
            buf[HASHED_REGION_OFFSET..HASHED_REGION_OFFSET + 4]
                .try_into()
                .expect("4-byte dir_len slice"),
        ) as usize;
        let dir_start = HASHED_REGION_OFFSET + 4;
        let dir_end = dir_start
            .checked_add(dir_len)
            .ok_or(PackError::Truncated)?;
        if dir_end > buf.len() {
            return Err(PackError::Truncated);
        }
        let dir: SectionDirectory =
            postcard::from_bytes(&buf[dir_start..dir_end]).map_err(PackError::Decode)?;
        let payload_start = dir_end;
        for e in &dir.entries {
            let end = e.offset.checked_add(e.stored_len).ok_or(PackError::Truncated)?;
            if (payload_start as u64).checked_add(end).map_or(true, |p| p as usize > buf.len()) {
                return Err(PackError::Truncated);
            }
        }
        Ok(Self { bytes, dir, payload_start })
    }

    /// Pack format version recorded in the header.
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

    /// Read a section by name.
    pub fn read_section(&self, name: &str) -> Result<Option<Cow<'_, [u8]>>, PackError> {
        let Some(entry) = self.dir.entries.iter().find(|e| e.name == name) else {
            return Ok(None);
        };
        let buf = self.bytes.as_slice();
        let start = self.payload_start + entry.offset as usize;
        let end = start + entry.stored_len as usize;
        let stored = &buf[start..end];
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
            Compression::ZstdDict => {
                let dict_bytes = self.zstd_dict()?;
                let dict = dict_bytes.as_ref().ok_or_else(|| {
                    PackError::Compression(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!(
                            "section `{}` uses ZstdDict but no zstd_dict section is present",
                            entry.name
                        ),
                    ))
                })?;
                let mut decoder =
                    zstd::stream::Decoder::with_dictionary(stored, dict)
                        .map_err(PackError::Compression)?;
                let mut out =
                    Vec::with_capacity(usize::try_from(entry.uncompressed_len).unwrap_or(0));
                use std::io::Read;
                decoder.read_to_end(&mut out).map_err(PackError::Compression)?;
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

    /// Read and cache the pack's zstd dictionary if present.
    fn zstd_dict(&self) -> Result<Option<Vec<u8>>, PackError> {
        match self.read_section_raw(crate::format::section_names::ZSTD_DICT)? {
            Some(bytes) => Ok(Some(bytes.into_owned())),
            None => Ok(None),
        }
    }

    fn read_section_raw(&self, name: &str) -> Result<Option<Cow<'_, [u8]>>, PackError> {
        let Some(entry) = self.dir.entries.iter().find(|e| e.name == name) else {
            return Ok(None);
        };
        let buf = self.bytes.as_slice();
        let start = self.payload_start + entry.offset as usize;
        let end = start + entry.stored_len as usize;
        let stored = &buf[start..end];
        match entry.compression {
            Compression::None => Ok(Some(Cow::Borrowed(stored))),
            // The dictionary itself is required to be uncompressed.
            _ => Err(PackError::Compression(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "zstd_dict section must be uncompressed",
            ))),
        }
    }

    /// Compute the pack hash as stored in the header.
    #[must_use]
    pub fn pack_hash(&self) -> [u8; HASH_LEN] {
        self.bytes.as_slice()[HASH_OFFSET..HASH_OFFSET + HASH_LEN]
            .try_into()
            .expect("32-byte hash slice")
    }
}
