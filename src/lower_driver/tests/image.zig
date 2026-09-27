//! The base image: a baked base serialized and read back. Programs over it
//! run through `driver.expectOutputOver` (tests/over.zig), which reads every
//! baked base back through the image too; these check what the image
//! refuses.

const std = @import("std");
const sema = @import("sema");
const ir = @import("ir");
const span = @import("span");
const interp_ir = @import("interp_ir");

const driver = @import("../lower_driver.zig");
const base_image = driver.pipeline.base_image;
const natives = driver.natives;

const testing = std.testing;

fn encodeMini(a: std.mem.Allocator) ![]const u8 {
    const baked = try driver.bake(a);
    return baked.encode(a);
}

test "an image names its layout, and a foreign file is not one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try encodeMini(arena.allocator());
    const h = base_image.header(bytes) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(base_image.version, h.version);
    try testing.expect(h.prefix > 0);
    try testing.expect(base_image.header("not an image at all, just some bytes") == null);
    var bad = try arena.allocator().dupe(u8, bytes);
    bad[0] = 'X';
    try testing.expect(base_image.header(bad) == null);
}

test "a base whose symbols differ from the image's is stale" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try encodeMini(a);
    // The miniature base with one more declaration: the prefix differs.
    var map = span.SourceMap.init(a);
    var files: std.ArrayList(sema.SourceFile) = .empty;
    for (driver.mini_base.files) |f| try driver.parseInto(a, &map, &files, f.path, f.source, .base);
    try driver.parseInto(a, &map, &files, "extra.kt", "package kotlin\npublic fun extraBaseFunction(): Int = 1\n", .base);
    const s = try sema.Sema.init(a);
    try s.addFiles(files.items);
    try testing.expectError(error.Stale, base_image.decode(a, bytes, s, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn }));
}

/// The miniature base's image decoded into `a`, over a sema that collected
/// the base afresh, as a run decodes it.
fn decodeLoaded(a: std.mem.Allocator, bytes: []const u8) !base_image.Loaded {
    var map = span.SourceMap.init(a);
    var files: std.ArrayList(sema.SourceFile) = .empty;
    for (driver.mini_base.files) |f| try driver.parseInto(a, &map, &files, f.path, f.source, .base);
    const s = try sema.Sema.init(a);
    try s.addFiles(files.items);
    return base_image.decode(a, bytes, s, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn });
}

fn decodeMini(a: std.mem.Allocator, bytes: []const u8) !*ir.Module {
    return (try decodeLoaded(a, bytes)).br.m;
}

test "an image decoded twice from one buffer gives each module bodies of its own" {
    var keep = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer keep.deinit();
    const bytes = try encodeMini(keep.allocator());
    // The first run's module and every body it decodes die with its arena,
    // after which another run can be given the same memory.
    var run1 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run1.deinit();
    const m1 = try decodeMini(run1.allocator(), bytes);
    var fid: ?usize = null;
    for (m1.funcs.items, 0..) |*f, i| {
        if (f.deferred_offset == 0) continue;
        try testing.expect(m1.ensureFuncBody(f));
        fid = i;
        break;
    }
    const first = m1.funcs.items[fid orelse return error.TestUnexpectedResult].blocks;
    var run2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run2.deinit();
    const m2 = try decodeMini(run2.allocator(), bytes);
    const f = &m2.funcs.items[fid.?];
    try testing.expect(f.deferred_offset != 0);
    try testing.expect(m2.ensureFuncBody(f));
    // The first run's blocks would outlive it here.
    try testing.expect(f.blocks.ptr != first.ptr);
    try testing.expectEqual(first.len, f.blocks.len);
}

test "a decoded image holds every function and class of the bake, block for block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const baked = try driver.bake(a);
    const bytes = try baked.encode(a);
    const loaded = try decodeLoaded(a, bytes);
    const m0 = baked.br.m;
    const m1 = loaded.br.m;
    try testing.expectEqual(m0.funcs.items.len, m1.funcs.items.len);
    try testing.expectEqual(m0.classes.items.len, m1.classes.items.len);
    try testing.expectEqual(baked.lowered.count(), loaded.lowered.count());
    for (m0.funcs.items, m1.funcs.items) |*f0, *f1| {
        try testing.expectEqualStrings(f0.fqn, f1.fqn);
        try testing.expectEqual(f0.params.len, f1.params.len);
        _ = m1.ensureFuncBody(f1);
        try testing.expectEqual(f0.blocks.len, f1.blocks.len);
        for (f0.blocks, f1.blocks) |b0, b1| {
            try testing.expectEqual(b0.insts.len, b1.insts.len);
            try testing.expectEqual(std.meta.activeTag(b0.terminator), std.meta.activeTag(b1.terminator));
        }
    }
    for (m0.classes.items, m1.classes.items) |c0, c1| try testing.expectEqualStrings(c0.fqn, c1.fqn);
}

test "a decoded image, its bodies materialised, encodes to the same bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try encodeMini(a);
    const loaded = try decodeLoaded(a, bytes);
    for (loaded.br.m.funcs.items) |*f| _ = loaded.br.m.ensureFuncBody(f);
    var map = span.SourceMap.init(a);
    const reloaded = try base_image.load(a, bytes, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn }, &map);
    for (reloaded.br.m.funcs.items) |*f| _ = reloaded.br.m.ensureFuncBody(f);
    const again = try base_image.encode(a, a, reloaded.br.s, reloaded.br, &reloaded.lowered, reloaded.header.prefix, &map, map.files.items.len, "");
    try testing.expectEqualSlices(u8, bytes, again);
}

test "a program over the base image runs the base's inline functions and natives" {
    try driver.expectOutputOverImage(&.{
        \\fun twice(x: Int): Int = x.let { it * 2 }
        \\fun main() {
        \\    println(twice(21))
        \\    println("ab".plus("cd"))
        \\    repeat(2) { println(it) }
        \\}
    }, "42\nabcd\n0\n1\n");
}
