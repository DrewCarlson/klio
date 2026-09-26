//! The natives of skiko's org.jetbrains.skia over the Skia shim.
//!
//! skiko's commonMain declares each native as an `external fun` under the C
//! symbol its `@ExternalSymbolName` names, and skiko's C glue, built into the
//! Skia shim, implements it under that symbol. This module registers a host
//! function per symbol (natives.zig, generated from the Kotlin declarations)
//! that converts the Kotlin arguments to C, calls the glue, and converts the
//! result back. A pointer (NativePointer, InteropPointer) is a Long on the
//! Kotlin side. A native the shim does not carry throws
//! UnsupportedOperationException naming it.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const compose_ui = @import("compose_ui");

pub const natives = @import("natives.zig");

const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const HostBindings = stdlib.HostBindings;
const Error = std.mem.Allocator.Error;

pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    errdefer b.deinit();
    inline for (natives.all, 0..) |n, i| try b.register(n.symbol, hostFn(i));
    // The native memory InteropScope passes arrays and strings in.
    try b.register("org.jetbrains.skia.impl.__skiko_malloc", memAlloc);
    try b.register("org.jetbrains.skia.impl.__skiko_free", memFree);
    try b.register("org.jetbrains.skia.impl.__skiko_copyIn", copyIn);
    try b.register("org.jetbrains.skia.impl.__skiko_copyOut", copyOut);
    try b.register("org.jetbrains.skia.impl.__skiko_cstring", cString);
    // The platform queries of org.jetbrains.skia and org.jetbrains.skiko.
    try b.register("org.jetbrains.skia.__skiko_defaultLanguageTag", compose_ui.hostLocale);
    try b.register("org.jetbrains.skiko.__skiko_hostOs", compose_ui.hostOs);
    try b.register("org.jetbrains.skiko.__skiko_hostArch", hostArch);
    try b.register("org.jetbrains.skiko.__skiko_readFile", readFile);
    return b;
}

fn hostArch(ctx: *CallCtx) Error!EvalResult {
    const name = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => "unknown",
    };
    return .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, name) } };
}

/// `__skiko_readFile(path: String): ByteArray`: the file's bytes; a file that
/// cannot be read throws, naming it.
fn readFile(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .String) return .{ .err = .{ .Type = "loadBytesFromPath takes a path" } };
    const path = blk: {
        const g = ctx.args[0].String.borrow();
        defer g.deinit();
        break :blk try ctx.allocator.dupe(u8, g.get().bytes);
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, ctx.allocator, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const msg = try std.fmt.allocPrint(ctx.allocator, "cannot read {s}: {s}", .{ path, @errorName(e) });
            return .{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
                .fqn = try runtime.strInit(ctx.allocator, "kotlin.RuntimeException"),
                .message = .from(try runtime.strInitOwned(ctx.allocator, msg)),
                .cause = null,
            }) } };
        },
    };
    defer ctx.allocator.free(bytes);
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    try items.ensureTotalCapacityPrecise(ctx.allocator, bytes.len);
    for (bytes) |byte| items.appendAssumeCapacity(.{ .Byte = @bitCast(byte) });
    return .{ .ok = try runtime.ArrayData.initPacked(ctx.allocator, .Byte, items.items) };
}

fn pointerArg(v: Value) ?[*]u8 {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, @truncate(integer(v))))));
}

fn unit() EvalResult {
    return .{ .ok = .{ .Unit = {} } };
}

/// `__skiko_malloc(size: Long): Long`: zeroed native memory of `size` bytes
/// (at least one), 0 when it cannot be had.
fn memAlloc(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return .{ .ok = Value.newLong(0) };
    const size: usize = @intCast(@max(integer(ctx.args[0]), 1));
    const p = std.c.calloc(1, size) orelse return .{ .ok = Value.newLong(0) };
    return .{ .ok = Value.newLong(@bitCast(@as(u64, @intFromPtr(p)))) };
}

/// `__skiko_free(ptr: Long)`.
fn memFree(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len >= 1) {
        if (pointerArg(ctx.args[0])) |p| std.c.free(p);
    }
    return unit();
}

/// The packed bytes of a primitive array, or null for any other value.
fn withScalars(v: Value, comptime f: fn ([]u8, [*]u8) void, p: [*]u8) bool {
    if (v != .Array) return false;
    switch (v.Array.storage()) {
        .boxed => return false,
        .scalars => |pb| {
            const g = pb.borrow();
            defer g.deinit();
            f(g.get().bytes.items, p);
            return true;
        },
    }
}

/// `__skiko_copyIn(ptr: Long, array)`: the primitive array's elements, as C
/// lays them out, into the native memory at `ptr`.
fn copyIn(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return unit();
    const p = pointerArg(ctx.args[0]) orelse return unit();
    _ = withScalars(ctx.args[1], struct {
        fn f(bytes: []u8, dst: [*]u8) void {
            @memcpy(dst[0..bytes.len], bytes);
        }
    }.f, p);
    return unit();
}

/// `__skiko_copyOut(ptr: Long, array)`: the native memory at `ptr` into the
/// primitive array's elements.
fn copyOut(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return unit();
    const p = pointerArg(ctx.args[0]) orelse return unit();
    _ = withScalars(ctx.args[1], struct {
        fn f(bytes: []u8, src: [*]u8) void {
            @memcpy(bytes, src[0..bytes.len]);
        }
    }.f, p);
    return unit();
}

/// `__skiko_cstring(s: String): Long`: the string's UTF-8 bytes and a NUL in
/// native memory the caller frees, 0 for a null string.
fn cString(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .String) return .{ .ok = Value.newLong(0) };
    const g = ctx.args[0].String.borrow();
    defer g.deinit();
    const bytes = g.get().bytes;
    const p: [*]u8 = @ptrCast(std.c.malloc(bytes.len + 1) orelse return .{ .ok = Value.newLong(0) });
    @memcpy(p[0..bytes.len], bytes);
    p[bytes.len] = 0;
    return .{ .ok = Value.newLong(@bitCast(@as(u64, @intFromPtr(p)))) };
}

/// The C type of a signature letter.
fn CType(comptime letter: u8) type {
    return switch (letter) {
        'P' => ?*anyopaque,
        'I' => i32,
        'F' => f32,
        'Z' => i8,
        'J' => i64,
        'S' => i16,
        'B' => i8,
        'D' => f64,
        'V' => void,
        else => @compileError("no C type for signature letter " ++ .{letter}),
    };
}

/// The C function type of a signature, `<return>:<parameters>`.
fn CFn(comptime sig: []const u8) type {
    const params = sig[2..];
    var types: [params.len]type = undefined;
    for (params, 0..) |c, k| types[k] = CType(c);
    const attrs: [params.len]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
    return @Fn(&types, &attrs, CType(sig[0]), .{ .@"callconv" = .c });
}

fn toC(comptime letter: u8, v: Value) CType(letter) {
    return switch (letter) {
        'P' => @ptrFromInt(@as(usize, @bitCast(@as(isize, @truncate(integer(v)))))),
        'I' => @truncate(integer(v)),
        'J' => integer(v),
        'S' => @truncate(integer(v)),
        'B' => @truncate(integer(v)),
        'Z' => switch (v) {
            .Bool => |x| @intFromBool(x),
            else => @intFromBool(integer(v) != 0),
        },
        'F' => @floatCast(float(v)),
        'D' => float(v),
        else => unreachable,
    };
}

fn fromC(comptime letter: u8, r: CType(letter)) Value {
    return switch (letter) {
        'P' => Value.newLong(@bitCast(@as(u64, @intFromPtr(r)))),
        'I' => .{ .Int = r },
        'J' => Value.newLong(r),
        'S' => .{ .Short = r },
        'B' => .{ .Byte = r },
        'Z' => .{ .Bool = r != 0 },
        'F' => .{ .Float = r },
        'D' => .{ .Double = r },
        'V' => .{ .Unit = {} },
        else => unreachable,
    };
}

fn integer(v: Value) i64 {
    return switch (v) {
        .Int => |x| x,
        .Long => |x| x,
        .Short => |x| x,
        .Byte => |x| x,
        .Char => |x| x,
        .Bool => |x| @intFromBool(x),
        else => 0,
    };
}

fn float(v: Value) f64 {
    return switch (v) {
        .Float => |x| x,
        .Double => |x| x,
        .Int => |x| @floatFromInt(x),
        .Long => |x| @floatFromInt(x),
        else => 0,
    };
}

/// Each native's C function, looked up in the shim on its first call.
var resolved: [natives.all.len]?*anyopaque = @splat(null);
var looked_up: [natives.all.len]std.atomic.Value(bool) = @splat(.init(false));

fn symbolOf(comptime i: usize) ?*anyopaque {
    if (!looked_up[i].load(.acquire)) {
        resolved[i] = compose_ui.skiaSymbol(natives.all[i].symbol);
        looked_up[i].store(true, .release);
    }
    return resolved[i];
}

/// The host function of native `i`.
fn hostFn(comptime i: usize) stdlib.StdlibFn {
    const n = natives.all[i];
    const params = n.sig[2..];
    return struct {
        fn call(ctx: *CallCtx) Error!EvalResult {
            if (ctx.args.len < params.len) return arity(ctx, n.symbol, params.len);
            const raw = symbolOf(i) orelse return missing(ctx, n.symbol);
            const f: *const CFn(n.sig) = @ptrCast(@alignCast(raw));
            var args: std.meta.ArgsTuple(CFn(n.sig)) = undefined;
            inline for (params, 0..) |c, k| args[k] = toC(c, ctx.args[k]);
            if (n.sig[0] == 'V') {
                @call(.auto, f, args);
                return .{ .ok = .{ .Unit = {} } };
            }
            return .{ .ok = fromC(n.sig[0], @call(.auto, f, args)) };
        }
    }.call;
}

fn missing(ctx: *CallCtx, symbol: []const u8) Error!EvalResult {
    const msg = try std.fmt.allocPrint(ctx.allocator, "the Skia shim has no native {s}", .{symbol});
    return .{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.UnsupportedOperationException"),
        .message = .from(try runtime.strInitOwned(ctx.allocator, msg)),
        .cause = null,
    }) } };
}

fn arity(ctx: *CallCtx, symbol: []const u8, want: usize) Error!EvalResult {
    const msg = try std.fmt.allocPrint(ctx.allocator, "native {s} takes {d} arguments, got {d}", .{ symbol, want, ctx.args.len });
    return .{ .err = .{ .Arity = msg } };
}

test "every native has a host function under its symbol" {
    var b = try hostBindings(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectEqual(natives.all.len + 9, b.table.count());
    try std.testing.expect(b.table.get("org_jetbrains_skia_Paint__1nMake") != null);
}

test "arrays and strings go to native memory and back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: CallCtx = undefined;
    ctx.allocator = a;

    var args1 = [_]Value{Value.newLong(16)};
    ctx.args = &args1;
    const mem = (try memAlloc(&ctx)).ok;
    try std.testing.expect(mem.Long != 0);

    const src = try runtime.ArrayData.initPacked(a, .Int, &.{ .{ .Int = 7 }, .{ .Int = -1 }, .{ .Int = 300 } });
    var args2 = [_]Value{ mem, src };
    ctx.args = &args2;
    _ = try copyIn(&ctx);
    const raw: [*]const i32 = @ptrFromInt(@as(usize, @intCast(mem.Long)));
    try std.testing.expectEqualSlices(i32, &.{ 7, -1, 300 }, raw[0..3]);

    const dst = try runtime.ArrayData.initPacked(a, .Int, &.{ .{ .Int = 0 }, .{ .Int = 0 }, .{ .Int = 0 } });
    var args3 = [_]Value{ mem, dst };
    ctx.args = &args3;
    _ = try copyOut(&ctx);
    try std.testing.expectEqual(@as(i32, 300), dst.Array.get(2).Int);

    var args4 = [_]Value{mem};
    ctx.args = &args4;
    _ = try memFree(&ctx);

    var args5 = [_]Value{.{ .String = try runtime.strInit(a, "héllo") }};
    ctx.args = &args5;
    const s = (try cString(&ctx)).ok;
    const cs: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(s.Long)));
    try std.testing.expectEqualStrings("héllo", std.mem.span(cs));
    std.c.free(@constCast(@ptrCast(cs)));
}

test "signatures map to their C types" {
    try std.testing.expect(CFn("P:PIF") == fn (?*anyopaque, i32, f32) callconv(.c) ?*anyopaque);
    try std.testing.expect(CFn("V:") == fn () callconv(.c) void);
    try std.testing.expect(CFn("Z:PZ") == fn (?*anyopaque, i8) callconv(.c) i8);
}

test "arguments and results convert both ways" {
    const p = toC('P', Value.newLong(0x1000));
    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(p));
    try std.testing.expect(toC('P', Value.newLong(0)) == null);
    try std.testing.expectEqual(@as(i8, 1), toC('Z', .{ .Bool = true }));
    try std.testing.expectEqual(@as(f32, 1.5), toC('F', .{ .Float = 1.5 }));
    try std.testing.expectEqual(@as(i64, 0x1000), fromC('P', p).Long);
    try std.testing.expect(fromC('Z', 1).Bool);
    try std.testing.expectEqual(@as(i32, -3), fromC('I', -3).Int);
}

/// The index of the native under `symbol`.
fn indexOf(comptime symbol: []const u8) usize {
    @setEvalBranchQuota(100_000);
    for (natives.all, 0..) |n, i| {
        if (std.mem.eql(u8, n.symbol, symbol)) return i;
    }
    @compileError("no native " ++ symbol);
}

fn callNative(comptime symbol: []const u8, ctx: *CallCtx, args: []const Value) !Value {
    ctx.args = args;
    const r = try hostFn(indexOf(symbol))(ctx);
    return switch (r) {
        .ok => |v| v,
        .err => error.NativeFailed,
    };
}

test "Paint's natives run through the shim's glue" {
    const lib = if (@import("builtin").os.tag == .macos) "zig-out/lib/libklio_skia.dylib" else "zig-out/lib/libklio_skia.so";
    compose_ui.setSkiaLibPath(lib);
    // A checkout without a built shim has nothing to call.
    if (compose_ui.skiaSymbol("org_jetbrains_skia_Paint__1nMake") == null) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: CallCtx = undefined;
    ctx.allocator = arena.allocator();

    const paint = try callNative("org_jetbrains_skia_Paint__1nMake", &ctx, &.{});
    try std.testing.expect(paint.Long != 0);
    // A new paint is opaque black and anti-aliased off, as SkPaint's defaults.
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xFF000000))), (try callNative("org_jetbrains_skia_Paint__1nGetColor", &ctx, &.{paint})).Int);
    _ = try callNative("org_jetbrains_skia_Paint__1nSetColor", &ctx, &.{ paint, .{ .Int = 0x11223344 } });
    try std.testing.expectEqual(@as(i32, 0x11223344), (try callNative("org_jetbrains_skia_Paint__1nGetColor", &ctx, &.{paint})).Int);
    _ = try callNative("org_jetbrains_skia_Paint__1nSetStrokeWidth", &ctx, &.{ paint, .{ .Float = 2.5 } });
    try std.testing.expectEqual(@as(f32, 2.5), (try callNative("org_jetbrains_skia_Paint__1nGetStrokeWidth", &ctx, &.{paint})).Float);
    _ = try callNative("org_jetbrains_skia_Paint__1nSetAntiAlias", &ctx, &.{ paint, .{ .Bool = true } });
    try std.testing.expect((try callNative("org_jetbrains_skia_Paint__1nIsAntiAlias", &ctx, &.{paint})).Bool);

    const finalizer = try callNative("org_jetbrains_skia_Paint__1nGetFinalizer", &ctx, &.{});
    _ = try callNative("org_jetbrains_skia_impl_Managed__invokeFinalizer", &ctx, &.{ finalizer, paint });
}

test "a native the shim does not carry throws, naming it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: CallCtx = undefined;
    ctx.allocator = arena.allocator();
    const r = try missing(&ctx, "org_jetbrains_skia_Nothing__1nMake");
    try std.testing.expect(r == .err and r.err == .Thrown);
}
