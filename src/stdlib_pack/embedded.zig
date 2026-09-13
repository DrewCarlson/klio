//! The stdlib pack baked into the binary: build.zig builds it with `embed_gen`
//! and wires the bytes in as the anonymous import `stdlib_pack_bytes`.
//! `stdlib_pack` falls back to them when neither the `KLIO_STDLIB_PACK`
//! override nor the cwd source checkout is available. Builds that bypass
//! build.zig (scripts/zigcheck.py) substitute `embedded_stub.zig`.

pub const pack_bytes: ?[]const u8 = @embedFile("stdlib_pack_bytes");
