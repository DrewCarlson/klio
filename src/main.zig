const std = @import("std");
const span = @import("span");

pub fn main() !void {
    std.debug.print("klio (zig) — Kotlin interpreter\n", .{});
    // Wiring smoke check: the span module is reachable from the binary.
    std.debug.assert(@intFromEnum(span.FileId.from(0)) == 0);
}
