//! Stands in for `sema_actuals_embedded.zig` where build.zig does not wire
//! the embedded files: the sema pipeline then reads its actuals from the
//! checkout only.

pub const File = struct { name: []const u8, bytes: []const u8 };

pub const files: []const File = &.{};
