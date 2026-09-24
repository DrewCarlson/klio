//! `klio-test-home`: the shared data home the program-running suites run in.
//!
//!   klio-test-home key <klio> <out-file>
//!       Writes the key of this tree: the build runs this step cached on the
//!       harness binary and every pack source, so `<out-file>`'s own path
//!       changes exactly when one of them does, and that path is the key.
//!   klio-test-home install <klio> <key-file> <home>
//!       Makes `<home>` a data home with every shipped pack built and
//!       installed by `<klio>`, unless it already holds the key's packs.
//!
//! Run from the repository root.

const std = @import("std");
const klio_child = @import("klio_child");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.args.toSlice(a);
    if (args.len == 4 and std.mem.eql(u8, args[1], "key")) {
        const key = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ args[3], args[2] });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = key });
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "install")) {
        const key = try std.Io.Dir.cwd().readFileAlloc(io, args[3], a, .limited(1 << 16));
        const klio = try std.Io.Dir.cwd().realPathFileAlloc(io, args[2], a);
        klio_child.ensureHome(a, io, klio, args[4], key) catch |e| {
            std.debug.print("klio-test-home: cannot install the packs into {s}: {s}\n", .{ args[4], @errorName(e) });
            return 1;
        };
        return 0;
    }
    std.debug.print("usage: klio-test-home key <klio> <out-file>\n       klio-test-home install <klio> <key-file> <home>\n", .{});
    return 2;
}
