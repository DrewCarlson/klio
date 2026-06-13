//! Stand-in for `embedded.zig` in builds that bypass build.zig (per-module
//! verification via scripts/zigcheck.py): no baked pack bytes, so the stdlib
//! pack comes from the `KLIO_STDLIB_PACK` override or the cwd source
//! checkout, exactly as before the embed existed.

pub const pack_bytes: ?[]const u8 = null;
