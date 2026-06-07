const std = @import("std");
const cli = @import("cli");

pub fn main() !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    return cli.run(gpa_state.allocator());
}
