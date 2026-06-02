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
pub const STDLIB_PACK: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/stdlib.klio-pack"));

/// Return the stdlib pack bytes the host should load. Respects the
/// `KLIO_STDLIB_PACK` environment variable: when set to a readable
/// file path, the file's contents are returned (handy for in-place
/// pack edits without rebuilding the binary). Otherwise the embedded
/// [`STDLIB_PACK`] slice is returned.
#[must_use]
pub fn stdlib_pack_bytes() -> Cow<'static, [u8]> {
    if let Ok(path) = std::env::var("KLIO_STDLIB_PACK")
        && let Ok(bytes) = std::fs::read(&path)
    {
        return Cow::Owned(bytes);
    }
    Cow::Borrowed(STDLIB_PACK)
}

/// Read the embedded stdlib pack's manifest and return the implicit
/// package list it declares. Reflects the pack's declaration, so as
/// the embedded pack adds packages (or future kotlinx packs declare
/// their own) callers automatically see the union.
#[must_use]
pub fn embedded_implicit_packages() -> Vec<String> {
    let bytes = stdlib_pack_bytes();
    let Ok(pack) = klio_pack::PackReader::from_bytes(bytes.into_owned()) else {
        return Vec::new();
    };
    let Ok(Some(payload)) = pack.read_section(klio_pack::section_names::MANIFEST) else {
        return Vec::new();
    };
    let manifest: klio_pack::schema::PackManifest = match klio_pack::schema::decode(&payload) {
        Ok(m) => m,
        Err(_) => return Vec::new(),
    };
    manifest.implicit_packages
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_pack_loads() {
        let bytes = stdlib_pack_bytes();
        assert!(
            !bytes.is_empty(),
            "embedded stdlib pack should not be empty"
        );
        // Round-trip through PackReader to validate the embed.
        let pack = klio_pack::PackReader::from_bytes(bytes.into_owned())
            .expect("embedded stdlib pack must validate");
        let names: Vec<_> = pack.section_names().collect();
        assert!(names.contains(&klio_pack::section_names::MANIFEST));
        assert!(names.contains(&klio_pack::section_names::BINDINGS));
    }

    #[test]
    fn embedded_implicit_packages_match_static_list() {
        // The static `klio_stdlib::IMPLICITLY_IMPORTED_PACKAGES` is
        // the boot-time source; the pack manifest is the persistent
        // form a future build will read directly. They must agree for
        // the duration of the transition.
        let from_pack = embedded_implicit_packages();
        let from_static: Vec<String> = klio_stdlib::IMPLICITLY_IMPORTED_PACKAGES
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        assert_eq!(from_pack, from_static);
    }
}
