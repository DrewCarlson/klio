//! List sorting and transforms: sorted, reversed, sum, average, min and max,
//! toMap, distinct, take, drop, slice, subList, plus, minus, chunked, windowed
//! and zip.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const MapPair = runtime.MapPair;
const CollBackingRef = runtime.CollBackingRef;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const array_mod = @import("array.zig");
const floatFallback = array_mod.floatFallback;
const floatVal = array_mod.floatVal;
const kotlinFloatMax = array_mod.kotlinFloatMax;
const kotlinFloatMin = array_mod.kotlinFloatMin;

const builders_mod = @import("builders.zig");
const materialiseIterableInstance = builders_mod.materialiseIterableInstance;

const common_mod = @import("common.zig");
const CompareOutcome = common_mod.CompareOutcome;
const RangeIter = common_mod.RangeIter;
const appendArrItems = common_mod.appendArrItems;
const appendVL = common_mod.appendVL;
const arityErr = common_mod.arityErr;
const asRangeView = common_mod.asRangeView;
const compareValues = common_mod.compareValues;
const containsBoxedH = common_mod.containsBoxedH;
const display = common_mod.display;
const eqBoxed = common_mod.eqBoxed;
const findKeyIndexBoxed = common_mod.findKeyIndexBoxed;
const findKeyIndexBoxedH = common_mod.findKeyIndexBoxedH;
const fmt = common_mod.fmt;
const i32ToOrdering = common_mod.i32ToOrdering;
const indexOfBoxedH = common_mod.indexOfBoxedH;
const invoke = common_mod.invoke;
const isCallable = common_mod.isCallable;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const listLen = common_mod.listLen;
const makeList = common_mod.makeList;
const makeListBorrowed = common_mod.makeListBorrowed;
const makeListFromArrayList = common_mod.makeListFromArrayList;
const makeMapH = common_mod.makeMapH;
const makePair = common_mod.makePair;
const modCountFor = common_mod.modCountFor;
const ok = common_mod.ok;
const recvListItems = common_mod.recvListItems;
const reverseOrder = common_mod.reverseOrder;
const snapshotItems = common_mod.snapshotItems;
const sortValuesNaturalDesc = common_mod.sortValuesNaturalDesc;
const thrown = common_mod.thrown;
const typeErr = common_mod.typeErr;

const list_mod = @import("list.zig");
const coll_mut_list_add = list_mod.coll_mut_list_add;
const coll_mut_list_add_all = list_mod.coll_mut_list_add_all;
const coll_mut_list_remove = list_mod.coll_mut_list_remove;
const coll_mut_list_remove_all = list_mod.coll_mut_list_remove_all;

const set_mod = @import("set.zig");
const coll_mut_set_add = set_mod.coll_mut_set_add;
const coll_mut_set_add_all = set_mod.coll_mut_set_add_all;
const coll_mut_set_remove = set_mod.coll_mut_set_remove;
const coll_mut_set_remove_all = set_mod.coll_mut_set_remove_all;

const views_mod = @import("views.zig");
const counterNowOf = views_mod.counterNowOf;
const sublistBackingOf = views_mod.sublistBackingOf;

fn compareHostAware(ctx: *CallCtx, x: Value, y: Value) Error!CompareOutcome {
    if (x == .Instance) {
        if (try ctx.host.invokeMethod(&x, "compareTo", &.{y}, ctx.out)) |m| {
            if (m == .ok and m.ok == .Int) return .{ .order = i32ToOrdering(m.ok.Int) };
        }
    }
    return compareValues(ctx.allocator, x, y);
}

pub fn sortListHostAware(ctx: *CallCtx, items: []Value) Error!?EvalResult {
    return sortListHostAwareDesc(ctx, items, false);
}

/// Natural-order sort; `descending` flips the comparison. Stable both ways, so
/// equal elements keep their original order, as in kotlinc.
pub fn sortListHostAwareDesc(ctx: *CallCtx, items: []Value, descending: bool) Error!?EvalResult {
    const a = ctx.allocator;
    var needs_host = false;
    for (items) |v| {
        if (v == .Instance) {
            needs_host = true;
            break;
        }
    }
    if (!needs_host) return sortValuesNaturalDesc(a, items, descending);
    const n = items.len;
    if (n < 2) return null;
    const buf = try a.alloc(Value, n);
    defer if (runtime.freeScratch()) a.free(buf);
    var width: usize = 1;
    while (width < n) : (width *= 2) {
        var lo: usize = 0;
        while (lo < n) : (lo += 2 * width) {
            const mid = @min(lo + width, n);
            const hi = @min(lo + 2 * width, n);
            var i = lo;
            var j = mid;
            var k = lo;
            while (i < mid and j < hi) {
                const raw = switch (try compareHostAware(ctx, items[i], items[j])) {
                    .order => |o| o,
                    .err => |e| return e,
                };
                const o = if (descending) reverseOrder(raw) else raw;
                // Take the left run on a tie so the sort stays stable.
                if (o != .gt) {
                    buf[k] = items[i];
                    i += 1;
                } else {
                    buf[k] = items[j];
                    j += 1;
                }
                k += 1;
            }
            while (i < mid) : ({
                i += 1;
                k += 1;
            }) buf[k] = items[i];
            while (j < hi) : ({
                j += 1;
                k += 1;
            }) buf[k] = items[j];
        }
        @memcpy(items[0..n], buf[0..n]);
    }
    return null;
}

pub fn coll_list_sorted(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.sorted")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    if (try sortListHostAware(ctx, copy)) |e| return e;
    return ok(try makeList(a, copy, false));
}

pub fn coll_list_sorted_descending(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const v = try coll_list_sorted(ctx);
    if (v == .err) return v;
    const items = try snapshotItems(a, v.ok.List.items);
    defer if (runtime.freeScratch()) a.free(items);
    std.mem.reverse(Value, items);
    return ok(try makeList(a, items, false));
}

pub fn coll_list_reversed(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.reversed")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const out = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(out);
    std.mem.reverse(Value, out);
    return ok(try makeList(a, out, false));
}

pub fn coll_list_indices(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.indices")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const len: i64 = @intCast(listLen(it));
    return ok(try Value.newRange(ctx.allocator, .{ .start = 0, .end = len - 1, .step = 1, .kind = .Int }));
}

pub fn coll_list_last_index(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.lastIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@as(i64, @intCast(listLen(it))) - 1));
}

pub fn coll_list_sum(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("Iterable.sum requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "Iterable.sum")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return sumValues(a, items, "Iterable.sum");
}

/// Sum in Kotlin's result type: Long, Double and Float keep their type, while
/// Int, Short and Byte sum to a wrapping Int.
pub fn sumValues(a: Allocator, items: []const Value, what: []const u8) Error!EvalResult {
    var acc_i: i64 = 0;
    var acc_u: u64 = 0;
    var acc_f: f64 = 0;
    var any_long = false;
    var any_float = false;
    var any_double = false;
    // Unsigned sums keep their width: UInt wraps at u32, UByte and UShort widen
    // to UInt, ULong stays ULong.
    var any_unsigned = false;
    var any_ulong = false;
    for (items) |v| {
        switch (v) {
            .Long => {
                any_long = true;
                acc_i +%= v.asI64().?;
            },
            .Int, .Short, .Byte => acc_i +%= v.asI64().?,
            .UByte, .UShort, .UInt => {
                any_unsigned = true;
                acc_u +%= v.asU64().?;
            },
            .ULong => {
                any_unsigned = true;
                any_ulong = true;
                acc_u +%= v.asU64().?;
            },
            .Float => {
                any_float = true;
                acc_f += v.asF64().?;
            },
            .Double => {
                any_double = true;
                acc_f += v.asF64().?;
            },
            else => {
                const vd = try display(a, v);
                return typeErr(try fmt(a, "{s} requires numeric elements, got {s}", .{ what, vd }));
            },
        }
    }
    if (any_double) return ok(.{ .Double = acc_f + @as(f64, @floatFromInt(acc_i)) });
    if (any_float) return ok(.{ .Float = @floatCast(acc_f + @as(f64, @floatFromInt(acc_i))) });
    if (any_unsigned) {
        if (any_ulong) return ok(.{ .ULong = acc_u });
        return ok(.{ .UInt = @truncate(acc_u) });
    }
    if (any_long) return ok(.{ .Long = acc_i });
    return ok(Value.newInt(@as(i32, @truncate(acc_i))));
}

pub fn coll_list_average(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("average requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "average")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(.{ .Double = std.math.nan(f64) });
    var sum: f64 = 0.0;
    var n: i64 = 0;
    for (items) |v| {
        sum += v.asF64() orelse {
            const vd = try display(a, v);
            return typeErr(try fmt(a, "List.average requires numeric elements, got {s}", .{vd}));
        };
        n += 1;
    }
    return ok(.{ .Double = sum / @as(f64, @floatFromInt(n)) });
}

pub fn coll_list_max_or_null(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, true, true, "List.maxOrNull");
}

pub fn coll_list_min_or_null(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, false, true, "List.minOrNull");
}

pub fn coll_list_max(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, true, false, "List.max");
}

pub fn coll_list_min(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, false, false, "List.min");
}

fn collListMinMaxCore(ctx: *CallCtx, want_max: bool, or_null: bool, what: []const u8) Error!EvalResult {
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
    // Floating-point elements follow `Math.min`/`Math.max`, where NaN propagates
    // and `-0.0 < 0.0`; the natural order expresses neither.
    if (items[0] == .Double or items[0] == .Float) {
        const is_float = items[0] == .Float;
        var acc: f64 = floatVal(items[0]) orelse return floatFallback(a, items, want_max);
        for (items[1..]) |v| {
            const x = floatVal(v) orelse return floatFallback(a, items, want_max);
            acc = if (want_max) kotlinFloatMax(acc, x) else kotlinFloatMin(acc, x);
        }
        return ok(if (is_float) .{ .Float = @floatCast(acc) } else .{ .Double = acc });
    }
    var best = items[0];
    for (items[1..]) |v| {
        const o = switch (try compareHostAware(ctx, v, best)) {
            .order => |o| o,
            .err => |e| return e,
        };
        const take = if (want_max) o == .gt else o == .lt;
        if (take) best = v;
    }
    return ok(best);
}

pub fn pairsFromValues(a: Allocator, items: []const Value, who: []const u8) Error!union(enum) { entries: std.ArrayList(MapPair), err: EvalResult } {
    var entries: std.ArrayList(MapPair) = .empty;
    for (items) |v| {
        if (v != .Pair) return .{ .err = typeErr(try fmt(a, "{s} requires a collection of Pair<K, V>", .{who})) };
        const key = v.Pair.first.asPtr().*;
        const val = v.Pair.second.asPtr().*;
        if (findKeyIndexBoxed(entries.items, &key)) |i| {
            entries.items[i].value = val;
        } else {
            try entries.append(a, .{ .key = key, .value = val });
        }
    }
    return .{ .entries = entries };
}

/// Read a user `Map` implementation into `MapPair`s through its `entries` view;
/// an entry may be a `Map.Entry` instance, a builtin `MapEntry` or a `Pair`.
pub fn userMapPairs(ctx: *CallCtx, inst: Value, who: []const u8) Error!union(enum) { entries: []MapPair, err: EvalResult } {
    const a = ctx.allocator;
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePush(inst);
    const entries_r = (try ctx.host.getProperty(&inst, "entries", ctx.out)) orelse
        return .{ .err = typeErr(try fmt(a, "{s} requires a Map or a collection of Pairs", .{who})) };
    const entries_val = switch (entries_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = .{ .err = e } },
    };
    runtime.keepalivePush(entries_val);
    const items = switch (try materialiseIterableInstance(ctx, entries_val)) {
        .items => |x| x,
        .err => |e| return .{ .err = e },
    };
    runtime.keepalivePushSlice(items);
    const loop_keepalive = runtime.keepaliveMark();
    var out: std.ArrayList(MapPair) = .empty;
    for (items) |entry| {
        runtime.keepaliveRestore(loop_keepalive);
        runtime.keepalivePushPairs(out.items);
        runtime.keepalivePush(entry);
        var key: Value = undefined;
        var val: Value = undefined;
        switch (entry) {
            .MapEntry => |me| {
                key = me.key.asPtr().*;
                val = me.value.asPtr().*;
            },
            .Pair => |p| {
                key = p.first.asPtr().*;
                val = p.second.asPtr().*;
            },
            else => {
                const kr = (try ctx.host.getProperty(&entry, "key", ctx.out)) orelse
                    return .{ .err = typeErr(try fmt(a, "{s} entry is missing key", .{who})) };
                key = switch (kr) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = .{ .err = e } },
                };
                runtime.keepalivePush(key);
                const vr = (try ctx.host.getProperty(&entry, "value", ctx.out)) orelse
                    return .{ .err = typeErr(try fmt(a, "{s} entry is missing value", .{who})) };
                val = switch (vr) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = .{ .err = e } },
                };
            },
        }
        runtime.keepalivePush(key);
        runtime.keepalivePush(val);
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, out.items, &key)) |i| {
            out.items[i].value = val;
        } else {
            try out.append(a, .{ .key = key, .value = val });
        }
    }
    return .{ .entries = try out.toOwnedSlice(a) };
}

pub fn coll_list_to_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const recv = if (ctx.args.len > 0) ctx.args[0] else Value.Null;
    const items = switch (recv) {
        .Array => |arr| try arr.snapshot(a),
        else => switch (try iterableItemsCtx(ctx, recv, "toMap")) {
            .items => |x| x,
            .err => |e| return e,
        },
    };
    defer if (runtime.freeScratch()) a.free(items);
    const entries = switch (try pairsFromValues(a, items, "toMap")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len >= 2 and ctx.args[1] == .Map) {
        const dest = ctx.args[1];
        const g = dest.Map.entries.borrowMut();
        defer g.deinit();
        for (entries.items) |kv| {
            var found = false;
            for (g.get().pairs.items) |*slot| {
                if (eqBoxed(&slot.key, &kv.key)) {
                    if (runtime.reclaimEnabled()) {
                        kv.value.retain();
                        slot.value.release(a);
                    }
                    slot.value = kv.value;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (runtime.reclaimEnabled()) {
                    kv.key.retain();
                    kv.value.retain();
                }
                try g.get().pairs.append(a, kv);
                try g.get().noteAppended(a, g.get().pairs.items.len - 1);
            }
        }
        return ok(dest);
    }
    return ok(try makeMapH(ctx.host, ctx.out, a, entries.items, false));
}

pub fn coll_list_distinct(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.distinct")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    var out: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (!try containsBoxedH(ctx.host, ctx.out, out.items, &v)) try out.append(a, v);
    }
    return ok(try makeListBorrowed(a, out, false));
}

fn listTakeCount(ctx: *CallCtx, what: []const u8) Error!union(enum) { n: i64, err: EvalResult } {
    const a = ctx.allocator;
    const n = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse return .{ .err = typeErr(try fmt(a, "{s} requires an Int", .{what})) }) else return .{ .err = typeErr(try fmt(a, "{s} requires an Int", .{what})) };
    if (n < 0) {
        const msg = try fmt(a, "Requested element count {d} is less than zero.", .{n});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return .{ .err = e };
    }
    return .{ .n = n };
}

pub fn coll_list_take_last(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.takeLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const n: usize = @intCast(switch (try listTakeCount(ctx, "takeLast")) {
        .n => |v| v,
        .err => |e| return e,
    });
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    const start = items.len -| n;
    return ok(try makeList(a, items[start..], false));
}

pub fn coll_list_drop_last(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.dropLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const n: usize = @intCast(switch (try listTakeCount(ctx, "dropLast")) {
        .n => |v| v,
        .err => |e| return e,
    });
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    const end = items.len -| n;
    return ok(try makeList(a, items[0..end], false));
}

fn isMultiElementArg(v: Value) bool {
    return switch (v) {
        .List, .Set, .Range, .Sequence, .Array => true,
        else => false,
    };
}

pub fn coll_mut_collection_plus_assign(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return arityErr("plusAssign requires an argument");
    const multi = isMultiElementArg(ctx.args[1]);
    return switch (ctx.args[0]) {
        .List => if (multi) coll_mut_list_add_all(ctx) else coll_mut_list_add(ctx),
        .Set => if (multi) coll_mut_set_add_all(ctx) else coll_mut_set_add(ctx),
        else => typeErr("plusAssign requires a mutable collection receiver"),
    };
}

pub fn coll_mut_collection_minus_assign(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return arityErr("minusAssign requires an argument");
    const multi = isMultiElementArg(ctx.args[1]);
    return switch (ctx.args[0]) {
        .List => if (multi) coll_mut_list_remove_all(ctx) else coll_mut_list_remove(ctx),
        .Set => if (multi) coll_mut_set_remove_all(ctx) else coll_mut_set_remove(ctx),
        else => typeErr("minusAssign requires a mutable collection receiver"),
    };
}

pub fn coll_list_slice(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.slice")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    const len: i64 = @intCast(items.len);
    var out: std.ArrayList(Value) = .empty;
    if (ctx.args.len > 1 and asRangeView(ctx.args[1]) != null) {
        const r = asRangeView(ctx.args[1]).?;
        var rit = RangeIter.init(r.start, r.end, r.step, r.kind);
        while (rit.next()) |i| {
            if (i < 0 or i >= len) {
                const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
                const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
                if (runtime.freeScratch()) a.free(msg);
                return e;
            }
            try out.append(a, items[@intCast(i)]);
        }
    } else if (ctx.args.len > 1 and ctx.args[1] == .List) {
        const idx_g = ctx.args[1].List.items.borrow();
        defer idx_g.deinit();
        for (idx_g.get().items) |idx_val| {
            const i = idx_val.asI64() orelse return typeErr("slice indices must be Int");
            if (i < 0 or i >= len) {
                const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
                const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
                if (runtime.freeScratch()) a.free(msg);
                return e;
            }
            try out.append(a, items[@intCast(i)]);
        }
    } else {
        return typeErr("slice requires an IntRange or List<Int>");
    }
    return ok(try makeListBorrowed(a, out, false));
}

pub fn coll_list_sublist(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .List) return typeErr("subList requires a List receiver");
    const recv = ctx.args[0];
    recv.refreshArrayView();
    recv.refreshSublistView();
    const from = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse return typeErr("subList requires Int fromIndex")) else return typeErr("subList requires Int fromIndex");
    const to = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse return typeErr("subList requires Int toIndex")) else return typeErr("subList requires Int toIndex");
    const parent_items = recv.List.items;
    const parent_backing = sublistBackingOf(recv);
    const recv_len: usize = listLen(recv.List.items);
    const len_i: i64 = @intCast(recv_len);
    if (from < 0 or to > len_i) {
        const msg = try fmt(a, "fromIndex: {d}, toIndex: {d}, size: {d}", .{ from, to, len_i });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    if (from > to) {
        const msg = try fmt(a, "fromIndex: {d} > toIndex: {d}", .{ from, to });
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const new_from: usize = @intCast(from);
    const win_len: usize = @intCast(to - from);
    var window: std.ArrayList(Value) = .empty;
    {
        const rg = parent_items.borrow();
        defer rg.deinit();
        try window.appendSlice(a, rg.get().items[new_from .. new_from + win_len]);
    }
    if (runtime.reclaimEnabled()) for (window.items) |e| e.retain();
    const mutable = recv.List.mutable;
    const backing = try CollBackingRef.init(a, .{ .sublist = .{
        .parent = parent_items,
        .parent_backing = parent_backing,
        .from = new_from,
        .len = win_len,
        .exp_mod = counterNowOf(recv.List.mod_count),
    } });
    // Share the root list's structural counter, so a modification of the parent
    // not made through this view trips this subList's iterators, as Kotlin's
    // SubList does by tracking root.modCount.
    const shared_mc = if (recv.List.mod_count.get()) |mc| runtime.OptRef(u64).from(mc.clone()) else try modCountFor(a, mutable);
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, window),
        .mutable = mutable,
        .enum_entries = false,
        .backing = backing.cell,
        .mod_count = shared_mc,
    }));
}

pub fn coll_list_plus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.plus")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    try appendVL(&out, a, it);
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    switch (arg) {
        .List => |l| try appendVL(&out, a, l.items),
        .Set => |s| try appendVL(&out, a, s.items),
        .Range, .Sequence, .Array => {
            const xs = switch (try iterableItemsCtx(ctx, arg, "plus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            try out.appendSlice(a, xs);
        },
        else => try out.append(a, arg),
    }
    return ok(try makeListBorrowed(a, out, false));
}

/// `plusElement` appends its argument as one element even when it is a
/// collection, unlike `plus`, which flattens one.
pub fn coll_list_plus_element(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.plusElement")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    try appendVL(&out, a, it);
    if (ctx.args.len < 2) return arityErr("plusElement requires an argument");
    try out.append(a, ctx.args[1]);
    return ok(try makeListBorrowed(a, out, false));
}

/// The static-Iterable surface: returns a List whatever the runtime collection
/// kind, as kotlinc resolves for an Iterable-typed receiver.
pub fn coll_iterable_minus(ctx: *CallCtx) Error!EvalResult {
    return iterableListOpAdapter(ctx, coll_list_minus, "Iterable.minus");
}

pub fn coll_iterable_plus(ctx: *CallCtx) Error!EvalResult {
    return iterableListOpAdapter(ctx, coll_list_plus, "Iterable.plus");
}

fn iterableListOpAdapter(ctx: *CallCtx, comptime core: fn (*CallCtx) Error!EvalResult, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    if (ctx.args[0] == .List) return core(ctx);
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, items);
    if (runtime.freeScratch()) a.free(items);
    const recv = try makeListFromArrayList(a, list, false);
    var new_args = try a.alloc(Value, ctx.args.len);
    defer if (runtime.freeScratch()) a.free(new_args);
    new_args[0] = recv;
    @memcpy(new_args[1..], ctx.args[1..]);
    var sub = ctx.*;
    sub.args = new_args;
    return core(&sub);
}

pub fn coll_list_minus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.minus")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("minus requires an argument");
    const arg = ctx.args[1];
    var removals: std.ArrayList(Value) = .empty;
    // `minus(elements)` removes every member of `elements`, while
    // `minus(element)` removes only the first occurrence.
    var is_collection = true;
    switch (arg) {
        .List => |l| try appendVL(&removals, a, l.items),
        .Set => |s| try appendVL(&removals, a, s.items),
        .Range, .Sequence, .Array => {
            const xs = switch (try iterableItemsCtx(ctx, arg, "minus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            try removals.appendSlice(a, xs);
        },
        else => {
            is_collection = false;
            try removals.append(a, arg);
        },
    }
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (is_collection) {
            if (!try containsBoxedH(ctx.host, ctx.out, removals.items, &v)) try out.append(a, v);
        } else if (try indexOfBoxedH(ctx.host, ctx.out, removals.items, &v)) |pos| {
            _ = removals.orderedRemove(pos);
        } else {
            try out.append(a, v);
        }
    }
    return ok(try makeListBorrowed(a, out, false));
}

pub fn coll_list_chunked(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.chunked")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("chunked requires an Int size");
    const size_i = ctx.args[1].Int;
    if (size_i <= 0) {
        const msg = try fmt(a, "Size {d} must be greater than zero.", .{size_i});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const size: usize = @intCast(size_i);
    const transform: ?Value = if (ctx.args.len > 2 and ctx.args[2] != .Null) ctx.args[2] else null;
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    var groups: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < items.len) {
        const end = @min(i + size, items.len);
        const chunk = try makeList(a, items[i..end], false);
        if (transform) |block| {
            const r = switch (try invoke(ctx, &block, &.{chunk})) {
                .value => |v| v,
                .err => |e| return e,
            };
            try groups.append(a, r);
        } else {
            try groups.append(a, chunk);
        }
        i += size;
    }
    return ok(try makeListFromArrayList(a, groups, false));
}

pub fn coll_list_windowed(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.windowed")) {
        .items => |x| x,
        .err => |e| return e,
    };
    // Peel a trailing callable as the `transform` of the
    // `windowed(size, step, partialWindows, transform)` overload, so the scalar
    // args read positionally and omitted middle defaults still bind.
    var n = ctx.args.len;
    const transform: ?Value = if (n > 2 and isCallable(ctx.args[n - 1])) blk: {
        n -= 1;
        break :blk ctx.args[n];
    } else null;
    if (n < 2 or ctx.args[1] != .Int) return typeErr("windowed requires an Int size");
    const size_i = ctx.args[1].Int;
    if (size_i <= 0) {
        const msg = try fmt(a, "size {d} must be greater than zero.", .{size_i});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const step_i: i64 = if (n <= 2) 1 else (if (ctx.args[2].isIntegral()) ctx.args[2].asI64().? else return typeErr("windowed step must be Int"));
    if (step_i <= 0) {
        const msg = try fmt(a, "step {d} must be greater than zero.", .{step_i});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const partial_windows: bool = if (n <= 3) false else (if (ctx.args[3] == .Bool) ctx.args[3].Bool else return typeErr("windowed partialWindows must be Bool"));
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    const size: usize = @intCast(size_i);
    const step: usize = @intCast(step_i);
    var out: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < items.len) {
        const end = i + size;
        const window: ?Value = if (end <= items.len)
            try makeList(a, items[i..end], false)
        else if (partial_windows)
            try makeList(a, items[i..], false)
        else
            null;
        if (window) |w| {
            if (transform) |block| {
                const r = switch (try invoke(ctx, &block, &.{w})) {
                    .value => |v| v,
                    .err => |e| return e,
                };
                try out.append(a, r);
            } else {
                try out.append(a, w);
            }
        } else break;
        i += step;
    }
    return ok(try makeListFromArrayList(a, out, false));
}

pub fn coll_list_zip(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const lhs = switch (try recvListItems(a, ctx.args, "List.zip")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("zip requires a second collection");
    const rhs_val = ctx.args[1];
    const transform: ?Value = if (ctx.args.len > 2 and isZipTransform(ctx.args[2])) ctx.args[2] else null;
    var rhs: std.ArrayList(Value) = .empty;
    defer if (runtime.freeScratch()) rhs.deinit(a);
    switch (rhs_val) {
        .List => |l| try appendVL(&rhs, a, l.items),
        .Set => |s| try appendVL(&rhs, a, s.items),
        .Array => |arr| try appendArrItems(&rhs, a, arr),
        .Range => |r| {
            var rit = RangeIter.init(r.start, r.end, r.step, r.kind);
            while (rit.next()) |n| try rhs.append(a, Value.newInt(n));
        },
        else => {
            const rd = try display(a, rhs_val);
            return typeErr(try fmt(a, "zip requires a collection, got {s}", .{rd}));
        },
    }
    const lhs_items = try snapshotItems(a, lhs);
    defer if (runtime.freeScratch()) a.free(lhs_items);
    var result: std.ArrayList(Value) = .empty;
    const n = @min(lhs_items.len, rhs.items.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (transform) |t| {
            const r = switch (try invoke(ctx, &t, &.{ lhs_items[i], rhs.items[i] })) {
                .value => |v| v,
                .err => |e| return e,
            };
            try result.append(a, r);
        } else {
            lhs_items[i].retain();
            rhs.items[i].retain();
            try result.append(a, try makePair(a, lhs_items[i], rhs.items[i]));
        }
    }
    return ok(try makeListFromArrayList(a, result, false));
}

fn isZipTransform(v: Value) bool {
    return switch (v) {
        .IrClosure, .BoundMethod, .Instance, .Class, .Intrinsic => true,
        else => false,
    };
}
