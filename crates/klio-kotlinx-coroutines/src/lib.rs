//! Native bindings for `kotlinx.coroutines`.
//!
//! The host registry is currently empty. Rust-backed
//! implementations for the dispatcher, channel buffer queues, and
//! select-clause arbitration will get wired into [`host_bindings`]
//! and matched against FQNs from the kotlinx-coroutines klio pack
//! at install time. The interpreted Kotlin in the pack's `sources`
//! section covers everything else.

use klio_stdlib::HostBindings;

/// Return a `HostBindings` registry seeded with the Rust-backed
/// implementations this crate ships. The library's klio.toml binding
/// manifest names each FQN we satisfy; the loader joins the manifest
/// entries to the function pointers registered here.
#[must_use]
pub fn host_bindings() -> HostBindings {
    HostBindings::new()
}
