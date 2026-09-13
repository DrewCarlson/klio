//! `Array` intrinsics: slicing, content equality/toString/hashCode,
//! deep variants, copying, filling, sorting and reductions.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common_mod = @import("common.zig");
const arityErr = common_mod.arityErr;
const coerceNeedleToArrayKind = common_mod.coerceNeedleToArrayKind;
const compareValues = common_mod.compareValues;
const containsBoxed = common_mod.containsBoxed;
const containsBoxedH = common_mod.containsBoxedH;
const display = common_mod.display;
const eqBoxed = common_mod.eqBoxed;
const eqBoxedH = common_mod.eqBoxedH;
const fmt = common_mod.fmt;
const iterableItems = common_mod.iterableItems;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const makeArray = common_mod.makeArray;
const makeArrayBorrowed = common_mod.makeArrayBorrowed;
const makeStringOwned = common_mod.makeStringOwned;
const ok = common_mod.ok;
const okElem = common_mod.okElem;
const thrown = common_mod.thrown;
const typeErr = common_mod.typeErr;

const iterable_mod = @import("iterable.zig");
const invokeComparatorCompare = iterable_mod.invokeComparatorCompare;

const list_transforms_mod = @import("list_transforms.zig");
const sortListHostAware = list_transforms_mod.sortListHostAware;
const sortListHostAwareDesc = list_transforms_mod.sortListHostAwareDesc;
const sumValues = list_transforms_mod.sumValues;

// =====================================================================
// Array ops
// =====================================================================

fn arrayPrimDefault(prim: ?PrimitiveArrayKind) Value {
    return switch (prim orelse return Value.Null) {
        .Int => .{ .Int = 0 },
        .Long => .{ .Long = 0 },
        .Double => .{ .Double = 0.0 },
        .Float => .{ .Float = 0.0 },
        .Short => .{ .Short = 0 },
        .Byte => .{ .Byte = 0 },
        .Boolean => .{ .Bool = false },
        .Char => .{ .Char = 0 },
        .UInt => .{ .UInt = 0 },
        .ULong => .{ .ULong = 0 },
        .UShort => .{ .UShort = 0 },
        .UByte => .{ .UByte = 0 },
    };
}

fn arrayPrimOf(v: Value) ?PrimitiveArrayKind {
    return switch (v) {
        .Array => |arr| arr.primKind(),
        else => null,
    };
}

const IdxOutcome = union(enum) { idx: i64, err: EvalResult };

fn arrayOptIndex(a: Allocator, ctx: *CallCtx, idx: usize, default: i64, what: []const u8) Error!IdxOutcome {
    if (idx >= ctx.args.len) return .{ .idx = default };
    // A named-arg reorder pads omitted middle defaults with Null.
    if (ctx.args[idx] == .Null) return .{ .idx = default };
    if (ctx.args[idx].asI64()) |v| return .{ .idx = v };
    return .{ .err = typeErr(try fmt(a, "{s}: index argument must be an Int", .{what})) };
}

/// Every caller passes a freshly-`fmt`'d (owned) message; free it after
/// `thrown` has duped it into the StringRef under the reclaim path.
fn indexOob(a: Allocator, msg: []const u8) Error!EvalResult {
    const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    if (runtime.freeScratch()) a.free(msg);
    return e;
}

fn illegalArg(a: Allocator, msg: []const u8) Error!EvalResult {
    const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
    if (runtime.freeScratch()) a.free(msg);
    return e;
}

pub fn array_slice_impl(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("sliceArray requires a receiver");
    const recv = ctx.args[0];
    if (recv != .Array) return typeErr("sliceArray requires an array receiver");
    const arr = recv.Array;
    const prim = arr.primKind();
    if (ctx.args.len < 2) return arityErr("sliceArray expects (receiver, range)");
    const src = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(src);
    if (ctx.args[1] == .Range) {
        const rs = ctx.args[1].Range.start;
        const re = ctx.args[1].Range.end;
        const slen: i64 = @intCast(src.len);
        // An empty range yields an empty array; otherwise the range must be in
        // bounds (Kotlin's sliceArray throws for a negative/over-length range).
        if (rs > re) return ok(try makeArray(a, &.{}, prim));
        if (rs < 0 or re >= slen) {
            return indexOob(a, try fmt(a, "sliceArray: range {d}..{d} out of bounds for length {d}", .{ rs, re, src.len }));
        }
        return ok(try makeArray(a, src[@intCast(rs)..@intCast(re + 1)], prim));
    }
    // `sliceArray(indices: Collection<Int>)`: gather `this[indices[k]]`.
    const idxs = switch (try iterableItemsCtx(ctx, ctx.args[1], "sliceArray")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(idxs);
    const sel = try a.alloc(Value, idxs.len);
    defer if (runtime.freeScratch()) a.free(sel);
    for (idxs, 0..) |iv, k| {
        const i: i64 = switch (iv) {
            .Int => |x| x,
            .Long => |x| x,
            else => return typeErr("sliceArray index must be Int"),
        };
        if (i < 0 or i >= src.len) return indexOob(a, "sliceArray: index out of bounds");
        var e = src[@intCast(i)];
        if (runtime.reclaimEnabled()) e.retain();
        sel[k] = e;
    }
    return ok(try makeArray(a, sel, prim));
}

pub fn array_content_equals(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentEquals requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("contentEquals expects (other)");
    const other = ctx.args[1];
    if (recv == .Null or other == .Null) {
        return ok(.{ .Bool = recv == .Null and other == .Null });
    }
    const xa = switch (try iterableItems(a, recv, "contentEquals")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(xa);
    const xb = switch (try iterableItems(a, other, "contentEquals")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(xb);
    if (xa.len != xb.len) return ok(.{ .Bool = false });
    for (xa, xb) |*x, *y| {
        if (!try eqBoxedH(ctx.host, ctx.out, x, y)) return ok(.{ .Bool = false });
    }
    return ok(.{ .Bool = true });
}

pub fn array_content_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentToString requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(try makeStringOwned(a, "null"));
    const items = switch (try iterableItems(a, recv, "contentToString")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (items, 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        // Each element renders through its own `toString()`, so a user
        // override fires instead of the structural `ClassName@id`.
        if (v == .Instance) {
            if (try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out)) |m| {
                if (m == .ok and m.ok == .String) {
                    const g = m.ok.String.borrow();
                    defer g.deinit();
                    try out.appendSlice(a, g.get().bytes);
                    continue;
                }
                if (m == .err) return m;
            }
        }
        try out.appendSlice(a, try display(a, v));
    }
    try out.append(a, ']');
    const buf = try out.toOwnedSlice(a);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}

fn longHash(bits: i64) i32 {
    const u: u64 = @bitCast(bits);
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(bits ^ @as(i64, @bitCast(u >> 32)))))));
}

/// `kotlinValueHash` with member dispatch: a user instance's own
/// hashCode() override participates, as on the JVM.
fn valueHashDispatch(ctx: *CallCtx, v: Value) i32 {
    switch (v) {
        .Instance, .Exception => {
            const r = ctx.host.invokeMethod(&v, "hashCode", &.{}, ctx.out) catch return kotlinValueHash(v);
            if (r) |res| switch (res) {
                .ok => |hv| if (hv == .Int) return @truncate(hv.Int),
                .err => {},
            };
            return kotlinValueHash(v);
        },
        else => return kotlinValueHash(v),
    }
}

fn kotlinValueHash(v: Value) i32 {
    // The scalar/String cases live in `Value.kotlinScalarHash` (shared
    // with the host persistent-collection fast paths so bucket placement
    // can never diverge); every other shape hashes 0 here exactly as the
    // pre-refactor switch did.
    return Value.kotlinScalarHash(&v) orelse 0;
}

pub fn array_content_hash_code(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentHashCode requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(.{ .Int = 0 });
    const items = switch (try iterableItems(a, recv, "contentHashCode")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    var result: i32 = 1;
    for (items) |e| {
        result = result *% 31 +% valueHashDispatch(ctx, e);
    }
    return ok(.{ .Int = result });
}

pub fn array_or_empty(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len > 0 and ctx.args[0] == .Array) return ok(ctx.args[0]);
    return ok(try makeArray(a, &.{}, null));
}

fn deepToString(a: Allocator, v: Value) Error![]u8 {
    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(a);
    return deepToStringRec(a, v, &path);
}

/// `contentDeepToString`, tracking the array-backing identities on the current
/// path so a reference cycle (`b[0] = a; a[0] = b`) renders as `[...]` instead
/// of recursing forever.
fn deepToStringRec(a: Allocator, v: Value, path: *std.ArrayList(usize)) Error![]u8 {
    switch (v) {
        .Array => |arr| {
            const id = arr.identity();
            for (path.items) |p| {
                if (p == id) return a.dupe(u8, "[...]");
            }
            try path.append(a, id);
            defer _ = path.pop();
            var out: std.ArrayList(u8) = .empty;
            try out.append(a, '[');
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try deepToStringRec(a, arr.get(i), path));
            }
            try out.append(a, ']');
            return out.toOwnedSlice(a);
        },
        .Null => return a.dupe(u8, "null"),
        else => return display(a, v),
    }
}

pub fn array_content_deep_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentDeepToString requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(try makeStringOwned(a, "null"));
    const buf = try deepToString(a, recv);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}

fn deepEq(x: Value, y: Value) bool {
    if (x == .Array and y == .Array) {
        const xa = x.Array;
        const ya = y.Array;
        const n = xa.len();
        if (n != ya.len()) return false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!deepEq(xa.get(i), ya.get(i))) return false;
        }
        return true;
    }
    return eqBoxed(&x, &y);
}

pub fn array_content_deep_equals(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("contentDeepEquals requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("contentDeepEquals expects (other)");
    const other = ctx.args[1];
    return ok(.{ .Bool = deepEq(recv, other) });
}

fn deepHashElement(ctx: *CallCtx, v: Value) i32 {
    switch (v) {
        .Array => |arr| {
            var result: i32 = 1;
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                result = result *% 31 +% deepHashElement(ctx, arr.get(i));
            }
            return result;
        },
        else => return valueHashDispatch(ctx, v),
    }
}

pub fn array_content_deep_hash_code(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("contentDeepHashCode requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(.{ .Int = 0 });
    return ok(.{ .Int = deepHashElement(ctx, recv) });
}

pub fn array_contains(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len < 2) return arityErr("contains expects (element)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "contains")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const needle = coerceNeedleToArrayKind(ctx.args[1], arrayPrimOf(ctx.args[0]));
    return ok(.{ .Bool = try containsBoxedH(ctx.host, ctx.out, items, &needle) });
}

pub fn array_contains_all(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len < 2) return arityErr("containsAll expects (elements)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const needles = switch (try iterableItems(a, ctx.args[1], "containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(needles);
    const kind = arrayPrimOf(ctx.args[0]);
    for (needles) |*n| {
        const needle = coerceNeedleToArrayKind(n.*, kind);
        if (!containsBoxed(items, &needle)) return ok(.{ .Bool = false });
    }
    return ok(.{ .Bool = true });
}

pub fn array_element_at(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("elementAt requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "elementAt")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const index = switch (try arrayOptIndex(a, ctx, 1, -1, "elementAt")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (index < 0 or @as(usize, @intCast(index)) >= items.len) {
        return indexOob(a, try fmt(a, "index: {d}, size: {d}", .{ index, items.len }));
    }
    return okElem(items[@intCast(index)]);
}

pub fn array_plus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("plus requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("plus expects (element|elements)");
    const other = ctx.args[1];
    var items: std.ArrayList(Value) = .empty;
    {
        const xs = switch (try iterableItems(a, recv, "plus")) {
            .items => |x| x,
            .err => |e| return e,
        };
        defer if (runtime.freeScratch()) a.free(xs);
        try items.appendSlice(a, xs);
    }
    switch (other) {
        .Array, .List, .Set => {
            const xs = switch (try iterableItems(a, other, "plus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            try items.appendSlice(a, xs);
        },
        else => try items.append(a, other),
    }
    return ok(try makeArrayBorrowed(a, items, arrayPrimOf(recv)));
}

pub fn array_plus_element(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("plusElement requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("plusElement expects (element)");
    const other = ctx.args[1];
    var items: std.ArrayList(Value) = .empty;
    const xs = switch (try iterableItems(a, recv, "plusElement")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(xs);
    try items.appendSlice(a, xs);
    try items.append(a, other);
    return ok(try makeArrayBorrowed(a, items, arrayPrimOf(recv)));
}

pub fn array_copy_into(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("copyInto requires an array receiver");
    const src_arr = ctx.args[0].Array;
    if (ctx.args.len < 2) return arityErr("copyInto expects (destination, ...)");
    const dest_val = ctx.args[1];
    if (dest_val != .Array) return typeErr("copyInto destination must be an array");
    const dest_arr = dest_val.Array;
    const src_len: i64 = @intCast(src_arr.len());
    const dest_offset = switch (try arrayOptIndex(a, ctx, 2, 0, "copyInto")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const start = switch (try arrayOptIndex(a, ctx, 3, 0, "copyInto")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const end = switch (try arrayOptIndex(a, ctx, 4, src_len, "copyInto")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (start < 0 or end > src_len or start > end) {
        return indexOob(a, try fmt(a, "copyInto: source range [{d}, {d}) out of bounds for length {d}", .{ start, end, src_len }));
    }
    const count = end - start;
    const dest_len: i64 = @intCast(dest_arr.len());
    if (dest_offset < 0 or dest_offset + count > dest_len) {
        return indexOob(a, try fmt(a, "copyInto: destination range [{d}, {d}) out of bounds for length {d}", .{ dest_offset, dest_offset + count, dest_len }));
    }
    const sub = try src_arr.snapshotRange(a, @intCast(start), @intCast(end));
    // The snapshot bridges src->dest; free the spine on exit (`set` retains into
    // the destination under a reclaiming backend).
    defer if (runtime.freeScratch()) a.free(sub);
    const base: usize = @intCast(dest_offset);
    for (sub, 0..) |v, i| dest_arr.set(a, base + i, v);
    return ok(dest_val);
}

pub fn array_copy_of(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("copyOf requires an array receiver");
    const arr = ctx.args[0].Array;
    const prim = arr.primKind();
    const cur_len: i64 = @intCast(arr.len());
    const new_size = switch (try arrayOptIndex(a, ctx, 1, cur_len, "copyOf")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (new_size < 0) {
        const msg = try fmt(a, "{d}", .{new_size});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const n: usize = @intCast(new_size);
    const default = arrayPrimDefault(prim);
    const cur = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(cur);
    var out: std.ArrayList(Value) = .empty;
    try out.ensureTotalCapacityPrecise(a, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out.appendAssumeCapacity(if (i < cur.len) cur[i] else default);
    }
    return ok(try makeArrayBorrowed(a, out, prim));
}

pub fn array_copy_of_range(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("copyOfRange requires an array receiver");
    const arr = ctx.args[0].Array;
    const prim = arr.primKind();
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 1, 0, "copyOfRange")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 2, len, "copyOfRange")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "copyOfRange: [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "copyOfRange: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const snap = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(snap);
    return ok(try makeArray(a, snap[@intCast(from)..@intCast(to)], prim));
}

pub fn array_fill(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("fill requires an array receiver");
    const arr = ctx.args[0].Array;
    if (ctx.args.len < 2) return arityErr("fill expects (element, ...)");
    const element = ctx.args[1];
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 2, 0, "fill")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 3, len, "fill")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "fill: [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "fill: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    var i: usize = @intCast(from);
    while (i < @as(usize, @intCast(to))) : (i += 1) arr.set(a, i, element);
    return ok(Value.Unit);
}

/// `UIntArray.asIntArray()` (and the U{Byte,Short,Long} siblings): a signed
/// VIEW sharing the unsigned array's packed buffer, so mutations through either
/// alias — the mirror of `IntArray.asUIntArray()` (the unsigned ctor). klio
/// otherwise falls to the stdlib body, which copies.
pub fn array_as_signed_view(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("asArray requires an array receiver");
    const arr = ctx.args[0].Array;
    const src = arr.primKind() orelse return typeErr("asArray requires a primitive array");
    const dst: PrimitiveArrayKind = switch (src) {
        .UByte => .Byte,
        .UShort => .Short,
        .UInt => .Int,
        .ULong => .Long,
        else => return typeErr("asArray: receiver is not an unsigned array"),
    };
    switch (arr.storage()) {
        .scalars => |pb| return ok(.{ .Array = runtime.ArrayData.scalars(pb.clone(), dst) }),
        .boxed => return typeErr("asArray: unsigned array is not packed"),
    }
}

/// In-place `reverse()` / `reverse(fromIndex, toIndex)` for an array. The
/// unsigned `reverse()` stdlib body delegates to `storage.reverse()`, which
/// does not reach the array's elements here, so the unsigned arrays bind this.
pub fn array_reverse(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("reverse requires an array receiver");
    const arr = ctx.args[0].Array;
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 1, 0, "reverse")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 2, len, "reverse")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "reverse: range [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "reverse: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    std.mem.reverse(Value, buf[@intCast(from)..@intCast(to)]);
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

pub fn array_sort(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("sort requires an array receiver");
    const arr = ctx.args[0].Array;
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 1, 0, "sort")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 2, len, "sort")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "sort: range [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "sort: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    const sub = buf[@intCast(from)..@intCast(to)];
    if (try sortListHostAware(ctx, sub)) |e| return e;
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

pub fn array_sort_with(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("sortWith requires an array receiver");
    const arr = ctx.args[0].Array;
    if (ctx.args.len < 2) return arityErr("sortWith expects (comparator, ...)");
    const comparator = ctx.args[1];
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 2, 0, "sortWith")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 3, len, "sortWith")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "sortWith: range [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "sortWith: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    const sub = buf[@intCast(from)..@intCast(to)];
    // An empty-step natural/reversed Comparator (`naturalOrder()`,
    // `reverseOrder()` — the body of `sortDescending`) sorts by the
    // elements' own order, host-aware so user `Comparable.compareTo`
    // dispatches; its `compare` surface cannot see the host.
    if (comparator == .Comparator) {
        const empty = blk: {
            const steps_g = comparator.Comparator.steps.borrow();
            defer steps_g.deinit();
            break :blk steps_g.get().len == 0;
        };
        if (empty) {
            if (try sortListHostAwareDesc(ctx, sub, comparator.Comparator.descending)) |e| return e;
            try arr.writeBack(a, buf);
            return ok(Value.Unit);
        }
    }
    var i: usize = 1;
    while (i < sub.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const n = switch (try invokeComparatorCompare(ctx, comparator, sub[j - 1], sub[j])) {
                .n => |v| v,
                .err => |e| return e,
            };
            if (n > 0) {
                std.mem.swap(Value, &sub[j - 1], &sub[j]);
                j -= 1;
            } else break;
        }
    }
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

fn arraySumImpl(ctx: *CallCtx, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return sumValues(a, items, what);
}

pub fn array_sum_int(ctx: *CallCtx) Error!EvalResult {
    return arraySumImpl(ctx, "Array.sum");
}

/// `U{Byte,Short,Int}Array.sum(): UInt` and `ULongArray.sum(): ULong`. The
/// generic sum widens unsigned elements but returns `Int`/`Long`; Kotlin's
/// unsigned sum widens to `UInt` (or `ULong` for a ULongArray).
pub fn array_sum_unsigned(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("sum requires an array receiver");
    const prim = ctx.args[0].Array.primKind() orelse return typeErr("sum requires a primitive unsigned array");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "sum")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (prim == .ULong) {
        var acc: u64 = 0;
        for (items) |v| acc +%= v.asU64() orelse 0;
        return ok(.{ .ULong = acc });
    }
    var acc: u32 = 0;
    for (items) |v| acc +%= @as(u32, @truncate(v.asU64() orelse 0));
    return ok(.{ .UInt = acc });
}

pub fn array_average_impl(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("Array.average requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "Array.average")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(.{ .Double = std.math.nan(f64) });
    var acc: f64 = 0.0;
    for (items) |v| {
        acc += switch (v) {
            .Int, .Long, .Short, .Byte => @floatFromInt(v.asI64() orelse 0),
            .Double => |d| d,
            .Float => |f| @as(f64, f),
            else => return typeErr("Array.average: non-numeric element"),
        };
    }
    return ok(.{ .Double = acc / @as(f64, @floatFromInt(items.len)) });
}

fn arrayMaxMinImpl(ctx: *CallCtx, want_max: bool, what: []const u8) Error!EvalResult {
    return arrayMaxMinCore(ctx, want_max, false, what);
}

pub fn array_min_or_null(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinCore(ctx, false, true, "Array.minOrNull");
}

pub fn array_max_or_null(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinCore(ctx, true, true, "Array.maxOrNull");
}

fn arrayMaxMinCore(ctx: *CallCtx, want_max: bool, or_null: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) {
        if (or_null) return ok(Value.Null);
        const msg = try fmt(a, "{s}: empty", .{what});
        const e = try thrown(a, "kotlin.NoSuchElementException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    // Floating-point arrays follow `Math.min`/`Math.max` semantics: NaN
    // propagates (any NaN element makes the result NaN) and signed zero is
    // ordered `-0.0 < 0.0`. The natural `compareValues` order expresses
    // neither, so fold the raw f64s directly.
    if (items[0] == .Double or items[0] == .Float) {
        const is_float = items[0] == .Float;
        var acc: f64 = floatVal(items[0]) orelse return floatFallback(a, items, want_max);
        for (items[1..]) |v| {
            const x = floatVal(v) orelse return floatFallback(a, items, want_max);
            acc = if (want_max) kotlinFloatMax(acc, x) else kotlinFloatMin(acc, x);
        }
        return ok(if (is_float) .{ .Float = @floatCast(acc) } else .{ .Double = acc });
    }
    return floatFallback(a, items, want_max);
}

pub fn floatVal(v: Value) ?f64 {
    return switch (v) {
        .Double => |d| d,
        .Float => |f| @floatCast(f),
        else => null,
    };
}

pub fn kotlinFloatMin(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    if (x == 0.0 and y == 0.0) return if (std.math.signbit(x) or std.math.signbit(y)) -0.0 else 0.0;
    return @min(x, y);
}

pub fn kotlinFloatMax(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    if (x == 0.0 and y == 0.0) return if (std.math.signbit(x) and std.math.signbit(y)) -0.0 else 0.0;
    return @max(x, y);
}

/// Natural-order min/max fold (non-float arrays, or a float array that turned
/// out to hold a non-float `Comparable` element).
pub fn floatFallback(a: Allocator, items: []const Value, want_max: bool) Error!EvalResult {
    var best = items[0];
    for (items[1..]) |v| {
        const o = switch (try compareValues(a, v, best)) {
            .order => |o| o,
            .err => |e| return e,
        };
        const take = if (want_max) o == .gt else o == .lt;
        if (take) best = v;
    }
    return ok(best);
}

pub fn array_max(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinImpl(ctx, true, "Array.max");
}
pub fn array_min(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinImpl(ctx, false, "Array.min");
}

/// `minWith`/`maxWith`(`OrNull`) over any iterable: fold by the Comparator
/// argument (args[1]) rather than natural order.
fn minMaxWithImpl(ctx: *CallCtx, want_max: bool, or_null: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len < 2) return arityErr(try fmt(a, "{s} expects (comparator)", .{what}));
    // `iterableItemsCtx` drains a `.Sequence` receiver via the host (the plain
    // `iterableItems` only snapshots eager collections).
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) {
        if (or_null) return ok(Value.Null);
        const msg = try fmt(a, "{s}: empty", .{what});
        const e = try thrown(a, "kotlin.NoSuchElementException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const comparator = ctx.args[1];
    var best = items[0];
    for (items[1..]) |v| {
        const n = switch (try invokeComparatorCompare(ctx, comparator, v, best)) {
            .n => |x| x,
            .err => |e| return e,
        };
        const take = if (want_max) n > 0 else n < 0;
        if (take) best = v;
    }
    return ok(best);
}

pub fn coll_min_with(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, false, false, "minWith");
}
pub fn coll_max_with(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, true, false, "maxWith");
}
pub fn coll_min_with_or_null(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, false, true, "minWithOrNull");
}
pub fn coll_max_with_or_null(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, true, true, "maxWithOrNull");
}
