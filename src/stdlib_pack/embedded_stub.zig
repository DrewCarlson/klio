//! Stand-in for `embedded.zig` where build.zig is bypassed: no baked bytes, so
//! the pack comes from `KLIO_STDLIB_PACK` or the cwd checkout.

pub const pack_bytes: ?[]const u8 = null;
