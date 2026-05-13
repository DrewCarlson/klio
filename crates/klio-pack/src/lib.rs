//! `klio-pack` — on-disk module format for the klio interpreter.
//!
//! A pack bundles a library's parsed AST, resolved symbols, type-check
//! side tables, public symbol index, and optional native-binding
//! manifest into a single byte stream that the interpreter can load
//! without re-running the front end. The same format is used by the
//! Kotlin standard library, by kotlinx modules, and by user libraries.
//!
//! M0 (this module) ships the container only: header layout, section
//! directory, deterministic writer, validating reader, optional
//! per-section zstd compression. Higher-level schemas (manifest,
//! symbol index, binding table) are added in later milestones.

pub mod format;
pub mod read;
pub mod schema;
pub mod write;

pub use format::{
    section_names, Compression, SectionDirectory, SectionEntry, FORMAT_VERSION, MAGIC,
};
pub use read::PackReader;
pub use write::{PackWriter, DEFAULT_ZSTD_LEVEL};

/// Errors produced while encoding or decoding a pack.
#[derive(Debug, thiserror::Error)]
pub enum PackError {
    #[error("pack header is truncated or shorter than expected")]
    Truncated,
    #[error("pack magic bytes do not match `KPK\\0`")]
    BadMagic,
    #[error("pack format version {found} is not supported (this build understands {expected})")]
    VersionMismatch { expected: u32, found: u32 },
    #[error("pack hash mismatch — file is corrupt or modified after writing")]
    HashMismatch,
    #[error("postcard decoding failed: {0}")]
    Decode(postcard::Error),
    #[error("postcard encoding failed: {0}")]
    Encode(postcard::Error),
    #[error("zstd error: {0}")]
    Compression(std::io::Error),
    #[error("duplicate section name `{0}` in pack")]
    DuplicateSection(String),
    #[error("section `{section}` decoded to {actual} bytes but directory expected {expected}")]
    LengthMismatch {
        section: String,
        expected: u64,
        actual: u64,
    },
    #[error("section directory of {0} bytes is larger than the format permits")]
    DirectoryTooLarge(usize),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_pack_round_trip() {
        let bytes = PackWriter::new().finish().expect("encode empty pack");
        let reader = PackReader::from_bytes(bytes.clone()).expect("decode empty pack");
        assert_eq!(reader.sections().len(), 0);
        assert_eq!(reader.section_names().count(), 0);
        // Hash is recomputed by the reader; if it disagreed we'd have
        // bailed before reaching this point.
        let _ = reader.pack_hash();
        // Re-encoding empty produces identical bytes.
        let again = PackWriter::new().finish().expect("encode empty pack again");
        assert_eq!(bytes, again, "empty pack must be deterministic");
    }

    #[test]
    fn multi_section_round_trip() {
        let manifest = b"manifest-bytes".to_vec();
        let symbols = b"symbols-bytes".to_vec();
        let bindings = b"bindings-bytes".to_vec();
        let mut w = PackWriter::new();
        // Intentionally out-of-order: the writer must sort.
        w.add_raw(section_names::SYMBOLS, symbols.clone());
        w.add_raw(section_names::MANIFEST, manifest.clone());
        w.add_raw(section_names::BINDINGS, bindings.clone());
        let bytes = w.finish().expect("encode multi-section pack");

        let reader = PackReader::from_bytes(bytes).expect("decode multi-section pack");
        let names: Vec<_> = reader.section_names().collect();
        assert_eq!(names, [section_names::BINDINGS, section_names::MANIFEST, section_names::SYMBOLS]);

        let got_manifest = reader.read_section(section_names::MANIFEST).unwrap().unwrap();
        let got_symbols = reader.read_section(section_names::SYMBOLS).unwrap().unwrap();
        let got_bindings = reader.read_section(section_names::BINDINGS).unwrap().unwrap();
        assert_eq!(&*got_manifest, &manifest[..]);
        assert_eq!(&*got_symbols, &symbols[..]);
        assert_eq!(&*got_bindings, &bindings[..]);
        assert!(reader.read_section("unknown").unwrap().is_none());
    }

    #[test]
    fn deterministic_byte_output() {
        let payload_a = b"payload-a".to_vec();
        let payload_b = b"payload-b".to_vec();
        let build = || {
            let mut w = PackWriter::new();
            // Insertion order is the opposite of what the writer
            // should emit, to make a non-deterministic implementation
            // visible.
            w.add_raw("b", payload_b.clone());
            w.add_raw("a", payload_a.clone());
            w.finish().expect("encode pack")
        };
        assert_eq!(build(), build(), "two builds of identical input must produce identical bytes");
    }

    #[test]
    fn zstd_section_round_trip() {
        // Payload long enough that compression is meaningful.
        let payload: Vec<u8> = std::iter::repeat(b'A')
            .take(8 * 1024)
            .chain(std::iter::repeat(b'B').take(8 * 1024))
            .collect();
        let mut w = PackWriter::new();
        w.add_zstd("compressed", payload.clone());
        let bytes = w.finish().expect("encode zstd pack");

        // Directory entry should reflect that the on-disk length is
        // smaller than the uncompressed length.
        let reader = PackReader::from_bytes(bytes).expect("decode zstd pack");
        let entry = reader
            .sections()
            .iter()
            .find(|e| e.name == "compressed")
            .expect("compressed section in directory");
        assert!(
            entry.stored_len < entry.uncompressed_len,
            "zstd should shrink a highly-repetitive 16 KiB payload (stored={}, uncompressed={})",
            entry.stored_len,
            entry.uncompressed_len
        );
        let decoded = reader.read_section("compressed").unwrap().unwrap();
        assert_eq!(&*decoded, &payload[..]);
    }

    #[test]
    fn tampered_pack_is_rejected() {
        let mut w = PackWriter::new();
        w.add_raw(section_names::MANIFEST, b"hello".to_vec());
        let mut bytes = w.finish().expect("encode pack");
        // Flip a byte inside the payload area. The header hash should
        // catch it on the next read.
        let last = bytes.len() - 1;
        bytes[last] ^= 0x01;
        let err = PackReader::from_bytes(bytes).expect_err("must reject tampered pack");
        assert!(matches!(err, PackError::HashMismatch));
    }

    #[test]
    fn duplicate_section_is_rejected() {
        let mut w = PackWriter::new();
        w.add_raw(section_names::MANIFEST, b"one".to_vec());
        w.add_raw(section_names::MANIFEST, b"two".to_vec());
        let err = w.finish().expect_err("must reject duplicate section");
        assert!(matches!(err, PackError::DuplicateSection(_)));
    }
}
