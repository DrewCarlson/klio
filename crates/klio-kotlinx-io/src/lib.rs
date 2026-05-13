//! Native bindings for `kotlinx-io`.
//!
//! The surface area is `Buffer`, `Source`, `Sink`, the `Path` /
//! `FileSystem` types, and the byte / UTF-8 encoder helpers.
//! Native bindings registered here back the byte-copy primitives and
//! the file-system entry points; the interpreted Kotlin in the pack
//! covers the buffered-stream layering and DSL.

use klio_stdlib::HostBindings;

#[must_use]
pub fn host_bindings() -> HostBindings {
    HostBindings::new()
}
