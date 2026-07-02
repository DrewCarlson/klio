//! Build-time generator: `parity-base-gen <out-dir>` bakes the parity
//! harness's EmbeddedOnly dependency bases (both stdlib gate variants) to
//! `<out-dir>/embedded-gate{0,1}.klio-image`. The build graph runs this with
//! the repo root as cwd; every parity test binary then loads the lowered
//! stdlib base instead of re-parsing and re-lowering it per process.
//!
//! A gate variant that cannot be baked writes an empty file: loaders reject
//! it and fall back to the per-process source build, so the build never
//! fails on serializability, it only loses the speedup.

const std = @import("std");

const parity = @import("parity");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var it = try init.args.iterateAllocator(a);
    defer it.deinit();
    _ = it.next(); // program name
    const out_dir = it.next() orelse {
        std.debug.print("usage: parity-base-gen <out-dir>\n", .{});
        return 2;
    };

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, out_dir) catch {};
    for ([_]bool{ false, true }) |full| {
        const bytes: []const u8 = (try parity.bakeEmbeddedBase(a, io, full)) orelse blk: {
            std.debug.print("parity-base-gen: gate{d} base not bakeable; writing empty placeholder\n", .{@intFromBool(full)});
            break :blk &.{};
        };
        const path = try std.fmt.allocPrint(a, "{s}/embedded-gate{d}.klio-image", .{ out_dir, @intFromBool(full) });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }
    return 0;
}
