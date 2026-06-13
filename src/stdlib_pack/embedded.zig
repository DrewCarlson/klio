//! The stdlib pack baked into the binary. The top-level build.zig builds
//! the pack with `embed_gen` and wires the bytes in as the anonymous import
//! `stdlib_pack_bytes`; `stdlib_pack` falls back to these bytes when neither
//! the `KLIO_STDLIB_PACK` override nor the cwd source checkout is available,
//! so the installed binary runs from any directory. Builds that bypass
//! build.zig (scripts/zigcheck.py) substitute `embedded_stub.zig` instead.

pub const pack_bytes: ?[]const u8 = @embedFile("stdlib_pack_bytes");
