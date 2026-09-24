//! The sema pipeline's actuals (`stdlib_sources.SEMA_ACTUAL_FILES`) baked in
//! by build.zig, each wired as the anonymous import `sema_actual:<name>`.
//! Builds that bypass build.zig (scripts/zigcheck.py) substitute
//! `sema_actuals_stub.zig`.

const names = @import("sema_actual_names").names;

pub const File = struct { name: []const u8, bytes: []const u8 };

pub const files: []const File = blk: {
    var out: [names.len]File = undefined;
    for (names, 0..) |n, i| out[i] = .{ .name = n, .bytes = @embedFile("sema_actual:" ++ n) };
    const final = out;
    break :blk &final;
};
