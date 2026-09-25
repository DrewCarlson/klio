//! The C ABI surface of the klio runtime: booting a program through the
//! interpreter (`klio transpile`'s launcher and any C host), and the
//! runtime a natively compiled program calls (`klio transpile --native`).

const std = @import("std");
const cli = @import("cli");
const runtime = @import("runtime");
const ir = @import("ir");
const stdlib = @import("stdlib");

const RunCtx = union(enum) {
    /// Sources built over the data home's stdlib and packs.
    sources: struct {
        paths: []const []const u8,
        features: []const []const u8,
    },
    /// Programs built over a sema image, which names its own base.
    image: struct {
        bytes: []const u8,
        paths: []const []const u8,
        texts: ?[]const []const u8,
        args: []const []const u8,
    },
};

fn runBody(ctx: RunCtx) c_int {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
    // The same backing the `klio` binary installs: the collector over the slab.
    var arena: ?std.heap.ArenaAllocator = null;
    defer if (arena) |*a| a.deinit();
    const gpa = runtime.allocTrackWrap(runtime.backing.processAllocator(&arena));
    return switch (ctx) {
        .sources => |s| @intCast(cli.sema_run_cmd.run(gpa, s.paths, s.features)),
        .image => |im| @intCast(cli.image_cmd.runOnImage(gpa, im.bytes, im.paths, im.texts, im.args, "transpile the program again with this klio")),
    };
}

fn runOnBigStack(ctx: RunCtx) c_int {
    runtime.tls_fast.claimOwner();
    runtime.runstats.markStart();
    return runtime.runOnBigStackMainThread(RunCtx, c_int, runBody, ctx);
}

/// Run the Kotlin program at `path` as `klio run` would. Returns the exit code,
/// 0 for success and 1 for diagnostics or a runtime error. Runs on an explicit
/// large stack switched to in place, since a transpiled binary's C `main` gets
/// only the process rlimit, and stays on the caller's thread so an emitted
/// `main` that opens a window keeps the process main thread.
export fn klio_rt_run_file(path: [*:0]const u8) c_int {
    const p: []const u8 = std.mem.span(path);
    return runOnBigStack(.{ .sources = .{ .paths = &.{p}, .features = &.{} } });
}

/// Run the program made of the source files `paths`, with the pack features
/// `features` (`<pack>/<feature>`) selected, as `klio run` would.
export fn klio_rt_run_sources(paths: [*]const [*:0]const u8, n_paths: u32, features: ?[*]const [*:0]const u8, n_features: u32) c_int {
    const a = std.heap.c_allocator;
    const ps = a.alloc([]const u8, n_paths) catch return 2;
    defer a.free(ps);
    for (ps, 0..) |*p, i| p.* = std.mem.span(paths[i]);
    const fs = a.alloc([]const u8, n_features) catch return 2;
    defer a.free(fs);
    for (fs, 0..) |*f, i| f.* = std.mem.span(features.?[i]);
    return runOnBigStack(.{ .sources = .{ .paths = ps, .features = fs } });
}

/// Run the programs `paths` over the sema image `image` (`image_len`
/// bytes), or when `image` is null the one in the file `image_path`, with
/// `main(args)`. `texts`, when given, are the programs' sources, so the
/// files need not exist where the binary runs. Nothing is read from the
/// data home.
export fn klio_rt_run_image(
    image: ?[*]const u8,
    image_len: usize,
    image_path: ?[*:0]const u8,
    paths: [*]const [*:0]const u8,
    texts: ?[*]const [*:0]const u8,
    n_paths: u32,
    args: ?[*]const [*:0]const u8,
    n_args: u32,
) c_int {
    const a = std.heap.c_allocator;
    // The run reads the base's names and bodies out of the image, so a
    // copy read from its file lives as long as the process.
    const bytes: []const u8 = if (image) |im| im[0..image_len] else blk: {
        const path = image_path orelse return 2;
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        break :blk std.Io.Dir.cwd().readFileAlloc(threaded.io(), std.mem.span(path), std.heap.page_allocator, .unlimited) catch {
            std.debug.print("error: cannot read base image {s}\n", .{path});
            return 1;
        };
    };
    const ps = a.alloc([]const u8, n_paths) catch return 2;
    defer a.free(ps);
    for (ps, 0..) |*p, i| p.* = std.mem.span(paths[i]);
    const ts: ?[][]const u8 = if (texts) |t| blk: {
        const out = a.alloc([]const u8, n_paths) catch return 2;
        for (out, 0..) |*x, i| x.* = std.mem.span(t[i]);
        break :blk out;
    } else null;
    defer if (ts) |t| a.free(t);
    const as = a.alloc([]const u8, n_args) catch return 2;
    defer a.free(as);
    for (as, 0..) |*x, i| x.* = std.mem.span(args.?[i]);
    return runOnBigStack(.{ .image = .{ .bytes = bytes, .paths = ps, .texts = ts, .args = as } });
}

/// Library version tag for the header/link handshake.
export fn klio_rt_abi_version() c_int {
    return 7;
}

// The native object ABI a compiled program calls: frames it publishes to the
// collector, the collector's phases, boxing, strings and capture cells. The
// resolved runtime (`resolved.zig`) carries classes, natives and the rest.

/// A `Value` as C sees it: two words, no tag union, never read by compiled code.
pub const CValue = runtime.CValue;
const toC = runtime.toC;
const fromC = runtime.fromC;

comptime {
    if (@sizeOf(runtime.Value) != @sizeOf(CValue)) {
        @compileError("the native ABI passes a Value as two words; it is no longer that size");
    }
}

fn natAlloc() std.mem.Allocator {
    return std.heap.c_allocator;
}

// Roots: the collector never scans the native stack, so a frame publishes its slots.

pub const NatFrame = extern struct {
    prev: ?*NatFrame,
    n: u32,
    slots: [*]CValue,
};

threadlocal var nat_top: ?*NatFrame = null;

export fn klio_nat_enter(f: *NatFrame) void {
    f.prev = nat_top;
    nat_top = f;
}

export fn klio_nat_leave(f: *NatFrame) void {
    nat_top = f.prev;
}

fn markNatFrames(m: *runtime.gc.Marker) void {
    var cur = nat_top;
    while (cur) |f| : (cur = f.prev) {
        var i: u32 = 0;
        while (i < f.n) : (i += 1) {
            var v = fromC(f.slots[i]);
            v.gcMark(m);
        }
    }
}

var nat_roots_registered = false;

/// Turns the collector on; a compiled program calls no `klio_rt_run_*` entry.
export fn klio_nat_init(void_arg: u32) void {
    _ = void_arg;
    if (nat_roots_registered) return;
    nat_roots_registered = true;
    runtime.gc.registerRoot(markNatFrames);
    runtime.backing.configureGcFromEnv();
}

/// Called between class registration and the program body: cells minted up to
/// here are program-lifetime and stay off the sweep registry.
export fn klio_nat_begin() void {
    runtime.gc.alloc_perm = false;
}

/// The safe point, polled at function entry and loop back edges; no borrow is
/// held across it.
export fn klio_nat_safepoint() void {
    runtime.assertNoCellLock();
    if (!runtime.gc.pending()) return;
    runtime.gc.collect();
}

/// The published-frame chain top and a way back; a `longjmp` skips every leave.
export fn klio_nat_frame_mark() ?*NatFrame {
    return nat_top;
}

export fn klio_nat_frame_restore(mark: ?*NatFrame) void {
    nat_top = mark;
}

// Boxing. A box carries its kind: `Char` prints as a character, `Short` and
// `Byte` render as themselves, and the unsigned classes hold the same bits as
// their signed widths.

/// A box of the wrong kind is a fault in the compiler, not in the program.
fn unboxFault(want: []const u8, v: runtime.Value) noreturn {
    const pre = "runtime error: a compiled program read a ";
    _ = std.c.write(2, pre.ptr, pre.len);
    const tag = @tagName(std.meta.activeTag(v));
    _ = std.c.write(2, tag.ptr, tag.len);
    _ = std.c.write(2, " as ", 4);
    _ = std.c.write(2, want.ptr, want.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

export fn klio_nat_box_int(v: i32) CValue {
    return toC(.{ .Int = v });
}
export fn klio_nat_box_long(v: i64) CValue {
    return toC(.{ .Long = v });
}
export fn klio_nat_box_double(v: f64) CValue {
    return toC(.{ .Double = v });
}
export fn klio_nat_box_float(v: f32) CValue {
    return toC(.{ .Float = v });
}
export fn klio_nat_box_bool(v: i32) CValue {
    return toC(.{ .Bool = v != 0 });
}
export fn klio_nat_box_unit() CValue {
    return toC(.Unit);
}
export fn klio_nat_box_char(v: u16) CValue {
    return toC(.{ .Char = v });
}
export fn klio_nat_box_short(v: i16) CValue {
    return toC(.{ .Short = v });
}
export fn klio_nat_box_byte(v: i8) CValue {
    return toC(.{ .Byte = v });
}
export fn klio_nat_box_uint(v: u32) CValue {
    return toC(.{ .UInt = v });
}
export fn klio_nat_box_ulong(v: u64) CValue {
    return toC(.{ .ULong = v });
}
export fn klio_nat_box_ushort(v: u16) CValue {
    return toC(.{ .UShort = v });
}
export fn klio_nat_box_ubyte(v: u8) CValue {
    return toC(.{ .UByte = v });
}

export fn klio_nat_int(cv: CValue) i32 {
    const v = fromC(cv);
    return switch (v) {
        .Int => |x| x,
        else => unboxFault("Int", v),
    };
}
export fn klio_nat_long(cv: CValue) i64 {
    const v = fromC(cv);
    return switch (v) {
        .Long => |x| x,
        else => unboxFault("Long", v),
    };
}
export fn klio_nat_double(cv: CValue) f64 {
    const v = fromC(cv);
    return switch (v) {
        .Double => |x| x,
        else => unboxFault("Double", v),
    };
}
export fn klio_nat_float(cv: CValue) f32 {
    const v = fromC(cv);
    return switch (v) {
        .Float => |x| x,
        else => unboxFault("Float", v),
    };
}
export fn klio_nat_bool(cv: CValue) i32 {
    const v = fromC(cv);
    return switch (v) {
        .Bool => |x| @intFromBool(x),
        else => unboxFault("Boolean", v),
    };
}
export fn klio_nat_char(cv: CValue) u16 {
    const v = fromC(cv);
    return switch (v) {
        .Char => |x| x,
        else => unboxFault("Char", v),
    };
}
export fn klio_nat_short(cv: CValue) i16 {
    const v = fromC(cv);
    return switch (v) {
        .Short => |x| x,
        else => unboxFault("Short", v),
    };
}
export fn klio_nat_byte(cv: CValue) i8 {
    const v = fromC(cv);
    return switch (v) {
        .Byte => |x| x,
        else => unboxFault("Byte", v),
    };
}
export fn klio_nat_uint(cv: CValue) u32 {
    const v = fromC(cv);
    return switch (v) {
        .UInt => |x| x,
        else => unboxFault("UInt", v),
    };
}
export fn klio_nat_ulong(cv: CValue) u64 {
    const v = fromC(cv);
    return switch (v) {
        .ULong => |x| x,
        else => unboxFault("ULong", v),
    };
}
export fn klio_nat_ushort(cv: CValue) u16 {
    const v = fromC(cv);
    return switch (v) {
        .UShort => |x| x,
        else => unboxFault("UShort", v),
    };
}
export fn klio_nat_ubyte(cv: CValue) u8 {
    const v = fromC(cv);
    return switch (v) {
        .UByte => |x| x,
        else => unboxFault("UByte", v),
    };
}

export fn klio_nat_string(bytes: [*]const u8, len: usize) CValue {
    const a = natAlloc();
    const s = runtime.strInit(a, bytes[0..len]) catch @panic("klio_nat_string: out of memory");
    return toC(.{ .String = s });
}

export fn klio_nat_null() CValue {
    return toC(.Null);
}

export fn klio_nat_is_null(v: CValue) i32 {
    return if (fromC(v) == .Null) 1 else 0;
}

// Capture cells: a `var` a lambda captures becomes a shared box.

export fn klio_nat_cell(v: CValue) CValue {
    const a = natAlloc();
    return toC(runtime.Value.newCell(a, fromC(v)) catch @panic("klio_nat_cell: out of memory"));
}

export fn klio_nat_cell_get(c: CValue) CValue {
    const v = fromC(c);
    const g = v.Cell.borrow();
    defer g.deinit();
    return toC(g.get().*);
}

export fn klio_nat_cell_set(c: CValue, v: CValue) void {
    const cv = fromC(c);
    const g = cv.Cell.borrowMut();
    defer g.deinit();
    g.get().* = fromC(v);
}

/// The runtime of programs compiled from sema's lowering.
pub const resolved = @import("resolved.zig");

comptime {
    _ = resolved;
}

test {
    std.testing.refAllDecls(resolved);
}
