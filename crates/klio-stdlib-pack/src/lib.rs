//! Embedded stdlib pack.
//!
//! The build script for this crate calls
//! [`klio_stdlib::build_stdlib_pack`] once per Cargo build and writes
//! the resulting `.klio-pack` byte stream into `OUT_DIR`. The crate
//! root embeds those bytes via `include_bytes!` so the interpreter
//! ships with the pack inlined into the binary.
//!
//! For day-to-day stdlib iteration, set
//! `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` and the
//! [`stdlib_pack_bytes`] helper returns the on-disk pack instead. The
//! embedded slice still ships in the binary; the env override only
//! affects the runtime path.

use std::borrow::Cow;

/// Embedded stdlib pack bytes — written by `build.rs` into `OUT_DIR`
/// at compile time and included via `include_bytes!`.
pub const STDLIB_PACK: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/stdlib.klio-pack"));

/// Return the stdlib pack bytes the host should load. Respects the
/// `KLIO_STDLIB_PACK` environment variable: when set to a readable
/// file path, the file's contents are returned (handy for in-place
/// pack edits without rebuilding the binary). Otherwise the embedded
/// [`STDLIB_PACK`] slice is returned.
#[must_use]
pub fn stdlib_pack_bytes() -> Cow<'static, [u8]> {
    if let Ok(path) = std::env::var("KLIO_STDLIB_PACK") {
        if let Ok(bytes) = std::fs::read(&path) {
            return Cow::Owned(bytes);
        }
    }
    Cow::Borrowed(STDLIB_PACK)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_pack_loads() {
        let bytes = stdlib_pack_bytes();
        assert!(!bytes.is_empty(), "embedded stdlib pack should not be empty");
        // Round-trip through PackReader to validate the embed.
        let pack = klio_pack::PackReader::from_bytes(bytes.into_owned())
            .expect("embedded stdlib pack must validate");
        let names: Vec<_> = pack.section_names().collect();
        assert!(names.iter().any(|n| *n == klio_pack::section_names::MANIFEST));
        assert!(names.iter().any(|n| *n == klio_pack::section_names::BINDINGS));
    }
}
