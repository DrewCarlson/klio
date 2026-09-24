//! The host functions the miniature base's bodyless declarations bind to:
//! output, `Any`'s identity members, arrays, `String` members and the
//! primitives' `equals` and `hashCode`; conversions, `compareTo` and
//! `toString` of the numeric classes come from `stdlib.implementation`.
//!
//! A native sees primitives, strings and arrays only: the base converts an
//! instance to text with a `toString` call before a native writes it.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const StdlibFn = runtime.StdlibFn;

const table = std.StaticStringMap(StdlibFn).initComptime(.{
    .{ "kotlin.io.__writeLine", writeLine },
    .{ "kotlin.io.__write", write },
    .{ "kotlin.__concat", concat },
    .{ "kotlin.__className", className },
    .{ "kotlin.Any.toString", anyToString },
    .{ "kotlin.Any.hashCode", anyHashCode },
    .{ "kotlin.Any.equals", identityEquals },
    .{ "kotlin.String.hashCode", stringHashCode },
    .{ "kotlin.Array.size", arraySize },
    .{ "kotlin.Array.get", arrayGet },
    .{ "kotlin.Array.set", arraySet },
    .{ "kotlin.IntArray.size", arraySize },
    .{ "kotlin.IntArray.get", arrayGet },
    .{ "kotlin.IntArray.set", arraySet },
    .{ "kotlin.arrayOf", firstArg },
    .{ "kotlin.intArrayOf", firstArg },
    .{ "kotlin.arrayOfNulls", arrayOfNulls },
    .{ "kotlin.__klio_arrayConcat", arrayConcat },
    .{ "kotlin.Boolean.equals", valueEquals },
    .{ "kotlin.Boolean.hashCode", valueHashCode },
    .{ "kotlin.Boolean.compareTo", booleanCompareTo },
    .{ "kotlin.Char.equals", valueEquals },
    .{ "kotlin.Char.hashCode", valueHashCode },
    .{ "kotlin.Byte.equals", valueEquals },
    .{ "kotlin.Byte.hashCode", valueHashCode },
    .{ "kotlin.Short.equals", valueEquals },
    .{ "kotlin.Short.hashCode", valueHashCode },
    .{ "kotlin.Int.equals", valueEquals },
    .{ "kotlin.Int.hashCode", valueHashCode },
    .{ "kotlin.Long.equals", valueEquals },
    .{ "kotlin.Long.hashCode", valueHashCode },
    .{ "kotlin.Float.equals", valueEquals },
    .{ "kotlin.Float.hashCode", valueHashCode },
    .{ "kotlin.Double.equals", valueEquals },
    .{ "kotlin.Double.hashCode", valueHashCode },
    .{ "klio.test.hostAnswer", hostAnswer },
});

/// The native for the declaration `fqn`: this table first, then
/// `stdlib.implementation`. A `bridge.NativeResolver`.
pub fn resolve(fqn: []const u8) ?StdlibFn {
    return table.get(fqn) orelse stdlib.implementation(fqn);
}

/// The FQNs this table binds, for tests.
pub fn ownFqns() []const []const u8 {
    return table.keys();
}

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(what: []const u8) EvalResult {
    return .{ .err = .{ .Type = what } };
}

fn arg(ctx: *CallCtx, i: usize) ?Value {
    return if (i < ctx.args.len) ctx.args[i] else null;
}

/// The bytes of a `String` argument.
fn strArg(ctx: *CallCtx, i: usize) ?[]const u8 {
    const v = arg(ctx, i) orelse return null;
    if (v != .String) return null;
    const g = v.String.borrow();
    defer g.deinit();
    return g.get().bytes;
}

fn newString(a: Allocator, bytes: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInit(a, bytes) };
}

fn writeLine(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = strArg(ctx, 0) orelse return typeErr("__writeLine takes a String");
    ctx.out.writeln(s);
    return ok(.Unit);
}

fn write(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = strArg(ctx, 0) orelse return typeErr("__write takes a String");
    ctx.out.write(s);
    return ok(.Unit);
}

fn concat(ctx: *CallCtx) Allocator.Error!EvalResult {
    const x = strArg(ctx, 0) orelse return typeErr("__concat takes Strings");
    const y = strArg(ctx, 1) orelse return typeErr("__concat takes Strings");
    const out = try std.mem.concat(ctx.allocator, u8, &.{ x, y });
    return ok(try newString(ctx.allocator, out));
}

/// The display name of an instance's class, from its class def.
fn classNameOf(v: Value) ?[]const u8 {
    if (v != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().fqn;
}

fn identityOf(v: Value) u64 {
    return switch (v) {
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().identity;
        },
        .Array => |arr| arr.identity(),
        .String => |s| @intFromPtr(s.cell),
        else => 0,
    };
}

fn className(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = arg(ctx, 0) orelse return typeErr("__className takes a value");
    const name = classNameOf(v) orelse @tagName(std.meta.activeTag(v));
    return ok(try newString(ctx.allocator, name));
}

/// `Class@hex`: the class's name and the instance's identity.
fn anyToString(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = arg(ctx, 0) orelse return typeErr("Any.toString takes a receiver");
    const name = classNameOf(v) orelse @tagName(std.meta.activeTag(v));
    const text = try std.fmt.allocPrint(ctx.allocator, "{s}@{x}", .{ name, @as(u32, @truncate(identityOf(v))) });
    return ok(try newString(ctx.allocator, text));
}

fn anyHashCode(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = arg(ctx, 0) orelse return typeErr("Any.hashCode takes a receiver");
    return ok(.{ .Int = @bitCast(@as(u32, @truncate(identityOf(v)))) });
}

fn sameRef(x: Value, y: Value) bool {
    return switch (x) {
        .Instance => |a| y == .Instance and a.cell == y.Instance.cell,
        .Array => |a| y == .Array and a.identity() == y.Array.identity(),
        .String => |a| y == .String and a.cell == y.String.cell,
        .Null => y == .Null,
        .Unit => y == .Unit,
        else => false,
    };
}

fn identityEquals(ctx: *CallCtx) Allocator.Error!EvalResult {
    const x = arg(ctx, 0) orelse return typeErr("Any.equals takes a receiver");
    const y = arg(ctx, 1) orelse Value.Null;
    return ok(.{ .Bool = sameRef(x, y) });
}

/// `equals` of a primitive: the other value is the same primitive type
/// holding the same value. `Double` and `Float` compare bitwise, as boxed
/// values do.
fn valueEquals(ctx: *CallCtx) Allocator.Error!EvalResult {
    const x = arg(ctx, 0) orelse return typeErr("equals takes a receiver");
    const y = arg(ctx, 1) orelse Value.Null;
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return ok(.{ .Bool = false });
    const eq = switch (x) {
        .Bool => |b| b == y.Bool,
        .Char => |c| c == y.Char,
        .Byte => |n| n == y.Byte,
        .Short => |n| n == y.Short,
        .Int => |n| n == y.Int,
        .Long => |n| n == y.Long,
        .Float => |f| @as(u32, @bitCast(f)) == @as(u32, @bitCast(y.Float)),
        .Double => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(y.Double)),
        else => false,
    };
    return ok(.{ .Bool = eq });
}

/// `hashCode` of a primitive, as the JVM computes it.
fn valueHashCode(ctx: *CallCtx) Allocator.Error!EvalResult {
    const x = arg(ctx, 0) orelse return typeErr("hashCode takes a receiver");
    const h: i32 = switch (x) {
        .Bool => |b| if (b) 1231 else 1237,
        .Char => |c| c,
        .Byte => |n| n,
        .Short => |n| n,
        .Int => |n| n,
        .Long => |n| @truncate(n ^ (n >> 32)),
        .Float => |f| @bitCast(@as(u32, @bitCast(f))),
        .Double => |f| blk: {
            const bits: u64 = @bitCast(f);
            break :blk @bitCast(@as(u32, @truncate(bits ^ (bits >> 32))));
        },
        else => return typeErr("hashCode of a non-primitive"),
    };
    return ok(.{ .Int = h });
}

fn booleanCompareTo(ctx: *CallCtx) Allocator.Error!EvalResult {
    const x = arg(ctx, 0) orelse return typeErr("compareTo takes a receiver");
    const y = arg(ctx, 1) orelse return typeErr("compareTo takes an argument");
    if (x != .Bool or y != .Bool) return typeErr("Boolean.compareTo takes Booleans");
    const a: i32 = @intFromBool(x.Bool);
    const b: i32 = @intFromBool(y.Bool);
    return ok(.{ .Int = a - b });
}

/// `String.hashCode` over UTF-16 units, as the JVM computes it.
fn stringHashCode(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = strArg(ctx, 0) orelse return typeErr("String.hashCode takes a String");
    var h: i32 = 0;
    const view = std.unicode.Utf8View.init(s) catch {
        for (s) |c| h = h *% 31 +% c;
        return ok(.{ .Int = h });
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp > 0xFFFF) {
            const v = cp - 0x10000;
            h = h *% 31 +% @as(i32, @intCast(0xD800 + (v >> 10)));
            h = h *% 31 +% @as(i32, @intCast(0xDC00 + (v & 0x3FF)));
        } else h = h *% 31 +% @as(i32, @intCast(cp));
    }
    return ok(.{ .Int = h });
}

fn arrayArg(ctx: *CallCtx) ?runtime.ArrayData {
    const v = arg(ctx, 0) orelse return null;
    return if (v == .Array) v.Array else null;
}

fn indexArg(ctx: *CallCtx, len: usize) ?usize {
    const v = arg(ctx, 1) orelse return null;
    if (v != .Int or v.Int < 0) return null;
    const i: usize = @intCast(v.Int);
    return if (i < len) i else null;
}

fn hostAnswer(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return ok(.{ .Int = 42 });
}

fn arraySize(ctx: *CallCtx) Allocator.Error!EvalResult {
    const arr = arrayArg(ctx) orelse return typeErr("size of a non-array");
    return ok(.{ .Int = @intCast(arr.len()) });
}

fn arrayGet(ctx: *CallCtx) Allocator.Error!EvalResult {
    const arr = arrayArg(ctx) orelse return typeErr("get of a non-array");
    const i = indexArg(ctx, arr.len()) orelse return typeErr("array index out of bounds");
    return ok(arr.get(i));
}

fn arraySet(ctx: *CallCtx) Allocator.Error!EvalResult {
    const arr = arrayArg(ctx) orelse return typeErr("set of a non-array");
    const i = indexArg(ctx, arr.len()) orelse return typeErr("array index out of bounds");
    arr.set(ctx.allocator, i, arg(ctx, 2) orelse Value.Null);
    return ok(.Unit);
}

/// A `vararg` function whose result is the array its caller packed.
fn firstArg(ctx: *CallCtx) Allocator.Error!EvalResult {
    return ok(arg(ctx, 0) orelse return typeErr("missing argument"));
}

fn arrayOfNulls(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = arg(ctx, 0) orelse return typeErr("arrayOfNulls takes a size");
    if (n != .Int or n.Int < 0) return typeErr("arrayOfNulls takes a non-negative Int");
    var list: std.ArrayList(Value) = .empty;
    try list.appendNTimes(ctx.allocator, .Null, @intCast(n.Int));
    return ok(runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.allocator, list)));
}

/// A new array holding the elements of each array in `parts`, in order,
/// of the parts' kind: packed when they are primitive arrays.
fn arrayConcat(ctx: *CallCtx) Allocator.Error!EvalResult {
    const parts = arrayArg(ctx) orelse return typeErr("__klio_arrayConcat takes an array of arrays");
    var items: std.ArrayList(Value) = .empty;
    var kind: ?@TypeOf(parts.primKind().?) = null;
    var i: usize = 0;
    while (i < parts.len()) : (i += 1) {
        const p = parts.get(i);
        if (p != .Array) return typeErr("__klio_arrayConcat joins arrays");
        if (i == 0) kind = p.Array.primKind();
        try items.appendSlice(ctx.allocator, try p.Array.snapshot(ctx.allocator));
    }
    if (kind) |k| return ok(try runtime.ArrayData.initPacked(ctx.allocator, k, items.items));
    return ok(runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.allocator, items)));
}

test "array concatenation keeps the parts' kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const int_kind = @TypeOf(@as(runtime.ArrayData, undefined).primKind().?).Int;
    const x = try runtime.ArrayData.initPacked(a, int_kind, &.{ .{ .Int = 1 }, .{ .Int = 2 } });
    const y = try runtime.ArrayData.initPacked(a, int_kind, &.{.{ .Int = 3 }});
    var parts: std.ArrayList(Value) = .empty;
    try parts.appendSlice(a, &.{ x, y });
    const arr = runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, parts));
    var cap = runtime.CaptureOutput.init(a);
    var ctx: CallCtx = .{ .args = &.{arr}, .out = cap.output(), .host = undefined, .allocator = a };
    const r = try arrayConcat(&ctx);
    const joined = r.ok.Array;
    try std.testing.expectEqual(int_kind, joined.primKind().?);
    try std.testing.expectEqual(@as(usize, 3), joined.len());
    try std.testing.expectEqual(@as(i32, 3), joined.get(2).Int);
}

test "the table binds the base's own natives before the stdlib's" {
    try std.testing.expect(resolve("kotlin.io.__writeLine") != null);
    try std.testing.expect(resolve("kotlin.Int.toString") != null);
    try std.testing.expect(resolve("kotlin.io.no_such_native") == null);
}
