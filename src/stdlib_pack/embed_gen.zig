//! Build-time stdlib pack generator: `embed_gen <out-path>` builds the
//! stdlib `.klio-pack` byte stream from the repo source checkout and writes
//! it to `<out-path>`. The top-level build.zig runs this with the repo root
//! as cwd and embeds the output into the interpreter binary.

const std = @import("std");

const pack = @import("pack");
const stdlib = @import("stdlib");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var it = try init.args.iterateAllocator(a);
    defer it.deinit();
    _ = it.next(); // program name
    const out_path = it.next() orelse {
        std.debug.print("usage: embed_gen <out-path>\n", .{});
        return 2;
    };

    var err: pack.PackError = undefined;
    var built = (try stdlib.build_stdlib_pack(a, true, &err)) orelse {
        std.debug.print("stdlib pack build failed: {f}\n", .{err});
        return 1;
    };
    defer built.deinit(a);

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = built.items });
    return 0;
}
