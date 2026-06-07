const std = @import("std");
const cli = @import("cli");

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return cli.run(arena.allocator());
}
