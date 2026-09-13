//! The stdlib pack baked in by build.zig via `embed_gen`, wired as the
//! anonymous import `stdlib_pack_bytes`. Builds that bypass build.zig
//! (scripts/zigcheck.py) substitute `embedded_stub.zig`.

pub const pack_bytes: ?[]const u8 = @embedFile("stdlib_pack_bytes");
