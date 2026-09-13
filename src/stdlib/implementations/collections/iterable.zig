//! Iterable-wide intrinsics: random and shuffle, filterNotNull, sumOf,
//! max/min-of, distinctBy, grouping, association and sorted-by.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const MapPair = runtime.MapPair;
const InstanceData = runtime.InstanceData;
const Error = std.mem.Allocator.Error;

const array_mod = @import("array.zig");
const kotlinFloatMax = array_mod.kotlinFloatMax;
const kotlinFloatMin = array_mod.kotlinFloatMin;

const common_mod = @import("common.zig");
const arityErr = common_mod.arityErr;
const compareValues = common_mod.compareValues;
const containsBoxedH = common_mod.containsBoxedH;
const display = common_mod.display;
const eqBoxedH = common_mod.eqBoxedH;
const findKeyIndexBoxedH = common_mod.findKeyIndexBoxedH;
const fmt = common_mod.fmt;
const invoke = common_mod.invoke;
const isCallable = common_mod.isCallable;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const makeList = common_mod.makeList;
const makeListBorrowed = common_mod.makeListBorrowed;
const makeListFromArrayList = common_mod.makeListFromArrayList;
const makeMapFromArrayList = common_mod.makeMapFromArrayList;
const ok = common_mod.ok;
const readOnlyMutationGuard = common_mod.readOnlyMutationGuard;
const recvListItems = common_mod.recvListItems;
const reverseOrder = common_mod.reverseOrder;
const snapshotItems = common_mod.snapshotItems;
const thrown = common_mod.thrown;
const typeErr = common_mod.typeErr;
const writeBackItems = common_mod.writeBackItems;

const list_transforms_mod = @import("list_transforms.zig");
const sortListHostAware = list_transforms_mod.sortListHostAware;
const sortListHostAwareDesc = list_transforms_mod.sortListHostAwareDesc;

const views_mod = @import("views.zig");
const sublistComodGuard = views_mod.sublistComodGuard;
const syncSublist = views_mod.syncSublist;

var random_state: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x2545F4914F6CDD1D);

const IndexOutcome = union(enum) { idx: usize, err: RuntimeError };

/// A uniform index in `[0, n)`. A supplied `Random` argument is drawn through
/// the host so a seeded source stays deterministic.
fn pickIndex(ctx: *CallCtx, n: usize) Error!IndexOutcome {
    if (n <= 1) return .{ .idx = 0 };
    if (ctx.args.len > 1 and ctx.args[1] == .Instance) {
        const arg = ctx.args[1];
        if (try ctx.host.invokeMethod(&arg, "nextInt", &.{Value.newInt(@intCast(n))}, ctx.out)) |res| {
            switch (res) {
                .ok => |v| if (v.asI64()) |iv| {
                    const m = @mod(iv, @as(i64, @intCast(n)));
                    return .{ .idx = @intCast(m) };
                },
                .err => |e| return .{ .err = e },
            }
        }
    }
    return .{ .idx = random_state.random().uintLessThan(usize, n) };
}

pub fn coll_random(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("random requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "random")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
    const idx = switch (try pickIndex(ctx, items.len)) {
        .idx => |i| i,
        .err => |e| return .{ .err = e },
    };
    const v = items[idx];
    if (runtime.reclaimEnabled()) v.retain();
    return ok(v);
}

pub fn coll_random_or_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("randomOrNull requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "randomOrNull")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(.Null);
    const idx = switch (try pickIndex(ctx, items.len)) {
        .idx => |i| i,
        .err => |e| return .{ .err = e },
    };
    const v = items[idx];
    if (runtime.reclaimEnabled()) v.retain();
    return ok(v);
}

fn shuffleInPlace(ctx: *CallCtx, slice: []Value) Error!?RuntimeError {
    var i: usize = slice.len;
    while (i > 1) {
        i -= 1;
        const j = switch (try pickIndex(ctx, i + 1)) {
            .idx => |x| x,
            .err => |e| return e,
        };
        const tmp = slice[i];
        slice[i] = slice[j];
        slice[j] = tmp;
    }
    return null;
}

pub fn coll_shuffled(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("shuffled requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "shuffled")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (try shuffleInPlace(ctx, items)) |e| return .{ .err = e };
    return ok(try makeList(a, items, false));
}

pub fn array_shuffle(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("shuffle requires an array receiver");
    const arr = ctx.args[0].Array;
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    if (try shuffleInPlace(ctx, buf)) |e| return .{ .err = e };
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

pub fn coll_mut_list_shuffle(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.shuffle")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    if (try shuffleInPlace(ctx, g.get().items)) |e| return .{ .err = e };
    return ok(.Unit);
}

pub fn coll_iter_filter_not_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "filterNotNull")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    var result: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (v != .Null) try result.append(a, v);
    }
    return ok(try makeListBorrowed(a, result, false));
}

/// Accumulator kind of a `sumOf` fold. The sum keeps the selector's kind, so an
/// Int sum wraps at 32 bits and an empty receiver yields that kind's zero.
const SumKind = enum { int, long, uint, ulong, double };

fn sumKindFromTyName(name: []const u8) ?SumKind {
    const simple = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[i + 1 ..] else name;
    if (std.mem.eql(u8, simple, "Int")) return .int;
    if (std.mem.eql(u8, simple, "Long")) return .long;
    if (std.mem.eql(u8, simple, "UInt")) return .uint;
    if (std.mem.eql(u8, simple, "ULong")) return .ulong;
    if (std.mem.eql(u8, simple, "Double")) return .double;
    return null;
}

fn sumKindOfValue(v: Value) ?SumKind {
    return switch (v) {
        .Int, .Short, .Byte => .int,
        .Long => .long,
        .UInt, .UShort, .UByte => .uint,
        .ULong => .ulong,
        .Double, .Float => .double,
        else => null,
    };
}

pub fn coll_iter_sum_of(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("sumOf expects (receiver, block)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "sumOf")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var kind: ?SumKind = if (ctx.host.callableReturnTy(&block)) |n| sumKindFromTyName(n) else null;
    var ai: i32 = 0;
    var al: i64 = 0;
    var au: u32 = 0;
    var aul: u64 = 0;
    var ad: f64 = 0;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        const rk = sumKindOfValue(r) orelse {
            const rd = try display(a, r);
            return typeErr(try fmt(a, "sumOf selector must return a numeric value, got {s}", .{rd}));
        };
        if (kind == null) kind = rk;
        // A wider result kind in the same family widens the running sum.
        switch (kind.?) {
            .int => switch (rk) {
                .long => {
                    al = ai;
                    kind = .long;
                },
                .double => {
                    ad = @floatFromInt(ai);
                    kind = .double;
                },
                else => {},
            },
            .uint => switch (rk) {
                .ulong => {
                    aul = au;
                    kind = .ulong;
                },
                .double => {
                    ad = @floatFromInt(au);
                    kind = .double;
                },
                else => {},
            },
            .long => if (rk == .double) {
                ad = @floatFromInt(al);
                kind = .double;
            },
            .ulong => if (rk == .double) {
                ad = @floatFromInt(aul);
                kind = .double;
            },
            .double => {},
        }
        switch (kind.?) {
            .int => ai +%= @as(i32, @truncate(r.asI64() orelse 0)),
            .long => al +%= r.asI64() orelse 0,
            .uint => au +%= @as(u32, @truncate(r.asU64() orelse 0)),
            .ulong => aul +%= r.asU64() orelse 0,
            .double => ad += r.asF64() orelse 0,
        }
    }
    return switch (kind orelse .int) {
        .int => ok(.{ .Int = ai }),
        .long => ok(.{ .Long = al }),
        .uint => ok(.{ .UInt = au }),
        .ulong => ok(.{ .ULong = aul }),
        .double => ok(.{ .Double = ad }),
    };
}

fn iterMaxMinOfOrNull(ctx: *CallCtx, want_max: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var best: ?Value = null;
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(items);
    const loop_keepalive = runtime.keepaliveMark();
    for (items) |v| {
        runtime.keepaliveRestore(loop_keepalive);
        if (best) |b| runtime.keepalivePush(b);
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (best) |b| {
            // A Double or Float selector uses Math.min/max semantics, where NaN
            // propagates and `-0.0 < 0.0`, not the Comparable total order.
            if (r == .Double and b == .Double) {
                const m = if (want_max) kotlinFloatMax(r.Double, b.Double) else kotlinFloatMin(r.Double, b.Double);
                best = .{ .Double = m };
            } else if (r == .Float and b == .Float) {
                const m = if (want_max)
                    kotlinFloatMax(@floatCast(r.Float), @floatCast(b.Float))
                else
                    kotlinFloatMin(@floatCast(r.Float), @floatCast(b.Float));
                best = .{ .Float = @floatCast(m) };
            } else {
                const o = switch (try compareValues(a, r, b)) {
                    .order => |o| o,
                    .err => |e| return e,
                };
                const take = if (want_max) o == .gt else o == .lt;
                if (take) best = r;
            }
        } else {
            best = r;
        }
    }
    return ok(best orelse Value.Null);
}

pub fn coll_iter_max_of_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinOfOrNull(ctx, true, "maxOfOrNull");
}

pub fn coll_iter_min_of_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinOfOrNull(ctx, false, "minOfOrNull");
}

pub fn coll_iter_distinct_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("distinctBy expects (receiver, block)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "distinctBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var keys: std.ArrayList(Value) = .empty;
    var result: std.ArrayList(Value) = .empty;
    for (items) |v| {
        const key = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (!try containsBoxedH(ctx.host, ctx.out, keys.items, &key)) {
            try keys.append(a, key);
            try result.append(a, v);
        }
    }
    return ok(try makeListBorrowed(a, result, false));
}

pub fn coll_iter_group_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2 and ctx.args.len != 3) return arityErr("groupBy expects (receiver, keySelector[, valueTransform])");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "groupBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const key_block = ctx.args[1];
    const has_value_transform = ctx.args.len == 3;
    const Group = struct { key: Value, vs: std.ArrayList(Value) };
    var groups: std.ArrayList(Group) = .empty;
    for (items) |v| {
        const key = switch (try invoke(ctx, &key_block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        var value = v;
        if (has_value_transform) {
            const value_block = ctx.args[2];
            value = switch (try invoke(ctx, &value_block, &.{v})) {
                .value => |val| val,
                .err => |e| return e,
            };
        }
        var found = false;
        for (groups.items) |*g| {
            if (try eqBoxedH(ctx.host, ctx.out, &g.key, &key)) {
                try g.vs.append(a, value);
                found = true;
                break;
            }
        }
        if (!found) {
            var vs: std.ArrayList(Value) = .empty;
            try vs.append(a, value);
            try groups.append(a, .{ .key = key, .vs = vs });
        }
    }
    defer if (runtime.freeScratch()) groups.deinit(a);
    var entries: std.ArrayList(MapPair) = .empty;
    for (groups.items) |g| {
        try entries.append(a, .{ .key = g.key, .value = try makeListBorrowed(a, g.vs, false) });
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_iter_grouping_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("groupingBy expects (receiver, keySelector)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "groupingBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    const id = ctx.host.allocInstanceId();
    const src = try makeList(a, items, false);
    const fields = [_]InstanceData.Field{
        .{ .name = "__grouping_src", .value = src },
        .{ .name = "__grouping_key", .value = block },
    };
    return ok(try ctx.host.newSynthInstance("kotlin.collections.Grouping", id, &fields));
}

pub fn coll_grouping_source_iterator(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Instance) return typeErr("sourceIterator expects a Grouping receiver");
    const src: Value = blk: {
        const g = ctx.args[0].Instance.borrow();
        defer g.deinit();
        break :blk (g.get().get("__grouping_src") orelse return typeErr("not a Grouping"));
    };
    return (try ctx.host.invokeMethod(&src, "iterator", &.{}, ctx.out)) orelse
        typeErr("Grouping source is not iterable");
}

pub fn coll_grouping_key_of(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .Instance) return arityErr("keyOf expects (Grouping, element)");
    const key: Value = blk: {
        const g = ctx.args[0].Instance.borrow();
        defer g.deinit();
        break :blk (g.get().get("__grouping_key") orelse return typeErr("not a Grouping"));
    };
    return switch (try invoke(ctx, &key, &.{ctx.args[1]})) {
        .value => |v| ok(v),
        .err => |e| e,
    };
}

/// A `Grouping` reduced to its elements plus a way to key one. A null `key`
/// means the receiver's own `keyOf` method supplies it.
const GroupingParts = union(enum) {
    parts: struct { items: []Value, key: ?Value, receiver: Value },
    err: EvalResult,
};

/// Drain a Kotlin-written `Grouping` through the interface protocol: a
/// statically bound `groupingBy` splices its inline body instead of building
/// `__grouping_src`.
fn groupingItemsViaProtocol(ctx: *CallCtx, recv: Value) Error!?[]Value {
    const it = switch ((try ctx.host.invokeMethod(&recv, "sourceIterator", &.{}, ctx.out)) orelse return null) {
        .ok => |v| v,
        .err => return null,
    };
    var items: std.ArrayList(Value) = .empty;
    errdefer items.deinit(ctx.allocator);
    while (true) {
        const more = switch ((try ctx.host.invokeMethod(&it, "hasNext", &.{}, ctx.out)) orelse return null) {
            .ok => |v| v,
            .err => return null,
        };
        if (more != .Bool or !more.Bool) break;
        const next = switch ((try ctx.host.invokeMethod(&it, "next", &.{}, ctx.out)) orelse return null) {
            .ok => |v| v,
            .err => return null,
        };
        try items.append(ctx.allocator, next);
    }
    return try items.toOwnedSlice(ctx.allocator);
}

fn groupingParts(ctx: *CallCtx, v: Value) Error!GroupingParts {
    const a = ctx.allocator;
    if (v == .Instance) {
        const captured: ?struct { src: Value, key: Value } = blk: {
            const g = v.Instance.borrow();
            defer g.deinit();
            const inst = g.get();
            const src = inst.get("__grouping_src") orelse break :blk null;
            if (src != .List) break :blk null;
            const key = inst.get("__grouping_key") orelse break :blk null;
            break :blk .{ .src = src, .key = key };
        };
        if (captured) |c| {
            const items = try snapshotItems(a, c.src.List.items);
            return .{ .parts = .{ .items = items, .key = c.key, .receiver = v } };
        }
        if (try groupingItemsViaProtocol(ctx, v)) |items| {
            return .{ .parts = .{ .items = items, .key = null, .receiver = v } };
        }
    }
    return .{ .err = typeErr("expected a Grouping receiver") };
}

const GroupingKey = union(enum) { value: Value, err: EvalResult };

fn groupingKeyOf(ctx: *CallCtx, key: ?Value, receiver: Value, element: Value) Error!GroupingKey {
    if (key) |k| {
        return switch (try invoke(ctx, &k, &.{element})) {
            .value => |val| .{ .value = val },
            .err => |e| .{ .err = e },
        };
    }
    const r = (try ctx.host.invokeMethod(&receiver, "keyOf", &.{element}, ctx.out)) orelse
        return .{ .err = typeErr("Grouping has no keyOf") };
    return switch (r) {
        .ok => |val| .{ .value = val },
        .err => .{ .err = r },
    };
}

pub fn coll_grouping_each_count(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const gp = switch (try groupingParts(ctx, ctx.args[0])) {
        .parts => |p| p,
        .err => |e| return e,
    };
    const Count = struct { key: Value, n: i64 };
    var counts: std.ArrayList(Count) = .empty;
    for (gp.items) |v| {
        const k = switch (try groupingKeyOf(ctx, gp.key, gp.receiver, v)) {
            .value => |val| val,
            .err => |e| return e,
        };
        var found = false;
        for (counts.items) |*c| {
            if (try eqBoxedH(ctx.host, ctx.out, &c.key, &k)) {
                c.n += 1;
                found = true;
                break;
            }
        }
        if (!found) try counts.append(a, .{ .key = k, .n = 1 });
    }
    var entries: std.ArrayList(MapPair) = .empty;
    for (counts.items) |c| {
        try entries.append(a, .{ .key = c.key, .value = Value.newInt(c.n) });
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_grouping_fold(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const gp = switch (try groupingParts(ctx, ctx.args[0])) {
        .parts => |p| p,
        .err => |e| return e,
    };
    const initial = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    if (ctx.args.len <= 2) return arityErr("fold expects (initial, operation)");
    const op = ctx.args[2];
    var acc: std.ArrayList(MapPair) = .empty;
    for (gp.items) |v| {
        const k = switch (try groupingKeyOf(ctx, gp.key, gp.receiver, v)) {
            .value => |val| val,
            .err => |e| return e,
        };
        const pos = try findKeyIndexBoxedH(ctx.host, ctx.out, acc.items, &k);
        const cur = if (pos) |p| acc.items[p].value else blk: {
            if (isCallable(initial)) {
                break :blk switch (try invoke(ctx, &initial, &.{ k, v })) {
                    .value => |val| val,
                    .err => |e| return e,
                };
            } else break :blk initial;
        };
        // The computed-initial overload keys its operation:
        // `fold(initialValueSelector: (K, T) -> R, operation: (K, R, T) -> R)`.
        const next = switch (if (isCallable(initial))
            try invoke(ctx, &op, &.{ k, cur, v })
        else
            try invoke(ctx, &op, &.{ cur, v })) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (pos) |p| {
            acc.items[p].value = next;
        } else {
            try acc.append(a, .{ .key = k, .value = next });
        }
    }
    return ok(try makeMapFromArrayList(a, acc, false));
}

pub fn coll_grouping_reduce(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const gp = switch (try groupingParts(ctx, ctx.args[0])) {
        .parts => |p| p,
        .err => |e| return e,
    };
    if (ctx.args.len <= 1) return arityErr("reduce expects (operation)");
    const op = ctx.args[1];
    var acc: std.ArrayList(MapPair) = .empty;
    for (gp.items) |v| {
        const k = switch (try groupingKeyOf(ctx, gp.key, gp.receiver, v)) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, acc.items, &k)) |p| {
            const cur = acc.items[p].value;
            const next = switch (try invoke(ctx, &op, &.{ k, cur, v })) {
                .value => |val| val,
                .err => |e| return e,
            };
            if (runtime.reclaimEnabled()) cur.release(a);
            acc.items[p].value = next;
        } else {
            if (runtime.reclaimEnabled()) v.retain();
            try acc.append(a, .{ .key = k, .value = v });
        }
    }
    return ok(try makeMapFromArrayList(a, acc, false));
}

pub fn coll_iter_associate(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("associate expects (receiver, block)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "associate")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var entries: std.ArrayList(MapPair) = .empty;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (r != .Pair) {
            if (runtime.reclaimEnabled()) r.release(a);
            return typeErr("associate selector must return Pair");
        }
        const key = r.Pair.first.asPtr().*;
        const val = r.Pair.second.asPtr().*;
        // key and val are borrowed reads of the owned Pair, so retain before
        // storing, then release `r`.
        if (runtime.reclaimEnabled()) {
            key.retain();
            val.retain();
        }
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, entries.items, &key)) |i| {
            if (runtime.reclaimEnabled()) {
                entries.items[i].value.release(a);
                key.release(a); // existing key kept; drop the duplicate's retain
            }
            entries.items[i].value = val;
        } else {
            try entries.append(a, .{ .key = key, .value = val });
        }
        if (runtime.reclaimEnabled()) r.release(a);
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_iter_associate_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2 and ctx.args.len != 3) return arityErr("associateBy expects (receiver, keySelector[, valueTransform])");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "associateBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const key_block = ctx.args[1];
    const has_value_transform = ctx.args.len == 3;
    var entries: std.ArrayList(MapPair) = .empty;
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(items);
    const loop_keepalive = runtime.keepaliveMark();
    for (items) |v| {
        runtime.keepaliveRestore(loop_keepalive);
        runtime.keepalivePushPairs(entries.items);
        const key = switch (try invoke(ctx, &key_block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        runtime.keepalivePush(key);
        var value = v;
        var value_owned = false;
        if (has_value_transform) {
            const value_block = ctx.args[2];
            value = switch (try invoke(ctx, &value_block, &.{v})) {
                .value => |val| val,
                .err => |e| return e,
            };
            value_owned = true;
        }
        runtime.keepalivePush(value);
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, entries.items, &key)) |i| {
            if (runtime.reclaimEnabled()) {
                entries.items[i].value.release(a);
                key.release(a);
                if (!value_owned) value.retain();
            }
            entries.items[i].value = value;
        } else {
            if (runtime.reclaimEnabled() and !value_owned) value.retain();
            try entries.append(a, .{ .key = key, .value = value });
        }
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_iter_associate_with(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("associateWith expects (receiver, block)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "associateWith")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var entries: std.ArrayList(MapPair) = .empty;
    for (items) |v| {
        const val = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, entries.items, &v)) |i| {
            if (runtime.reclaimEnabled()) entries.items[i].value.release(a);
            entries.items[i].value = val;
        } else {
            if (runtime.reclaimEnabled()) v.retain();
            try entries.append(a, .{ .key = v, .value = val });
        }
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

fn sortByKeyInsertion(ctx: *CallCtx, items: []Value, block: Value, descending: bool) Error!?EvalResult {
    const a = ctx.allocator;
    const keys = try a.alloc(Value, items.len);
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(items);
    const loop_keepalive = runtime.keepaliveMark();
    for (items, 0..) |v, i| {
        runtime.keepaliveRestore(loop_keepalive);
        runtime.keepalivePushSlice(keys[0..i]);
        keys[i] = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
    }
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const o = switch (try compareValues(a, keys[j - 1], keys[j])) {
                .order => |o| o,
                .err => |e| return e,
            };
            const flipped = if (descending) reverseOrder(o) else o;
            if (flipped == .gt) {
                std.mem.swap(Value, &items[j - 1], &items[j]);
                std.mem.swap(Value, &keys[j - 1], &keys[j]);
                j -= 1;
            } else break;
        }
    }
    return null;
}

fn iterSortedByImpl(ctx: *CallCtx, descending: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    if (try sortByKeyInsertion(ctx, items, block, descending)) |e| return e;
    return ok(try makeList(a, items, false));
}

pub fn coll_iter_sorted_by(ctx: *CallCtx) Error!EvalResult {
    return iterSortedByImpl(ctx, false, "sortedBy");
}

pub fn coll_iter_sorted_by_desc(ctx: *CallCtx) Error!EvalResult {
    return iterSortedByImpl(ctx, true, "sortedByDescending");
}

fn iterMaxMinByImpl(ctx: *CallCtx, descending: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(Value.Null);
    const block = ctx.args[1];
    var best_key = switch (try invoke(ctx, &block, &.{items[0]})) {
        .value => |v| v,
        .err => |e| return e,
    };
    var best = items[0];
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(items);
    const loop_keepalive = runtime.keepaliveMark();
    for (items[1..]) |v| {
        runtime.keepaliveRestore(loop_keepalive);
        runtime.keepalivePush(best_key);
        runtime.keepalivePush(best);
        const key = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        const o = switch (try compareValues(a, key, best_key)) {
            .order => |o| o,
            .err => |e| return e,
        };
        const take = if (descending) o == .lt else o == .gt;
        if (take) {
            best_key = key;
            best = v;
        }
    }
    return ok(best);
}

pub fn coll_iter_max_by_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinByImpl(ctx, false, "maxByOrNull");
}

pub fn coll_iter_min_by_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinByImpl(ctx, true, "minByOrNull");
}

const CmpResult = union(enum) { n: i64, err: EvalResult };

pub fn invokeComparatorCompare(ctx: *CallCtx, comparator: Value, x: Value, y: Value) Error!CmpResult {
    const args = [_]Value{ x, y };
    const r = if (try ctx.host.invokeMethod(&comparator, "compare", &args, ctx.out)) |m|
        m
    else
        try ctx.host.invokeCallable(&comparator, &args, ctx.out);
    return switch (r) {
        .ok => |v| if (v.asI64()) |n| .{ .n = n } else .{ .err = typeErr("Comparator.compare must return Int") },
        .err => |e| .{ .err = .{ .err = e } },
    };
}

pub fn coll_mut_list_sort(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.sort")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    // Host-aware so user `Comparable` instances sort through their `compareTo`.
    if (try sortListHostAware(ctx, copy)) |e| return e;
    writeBackItems(it, a, copy) catch return error.OutOfMemory;
    return ok(Value.Unit);
}

/// Stable bottom-up merge sort driven by a Kotlin `Comparator`: an insertion
/// sort's O(n²) comparator callbacks time out on large lists.
pub fn mergeSortComparator(ctx: *CallCtx, cmp: Value, items: []Value) Error!?EvalResult {
    const a = ctx.allocator;
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
                const c = switch (try invokeComparatorCompare(ctx, cmp, items[i], items[j])) {
                    .n => |v| v,
                    .err => |e| return e,
                };
                // Take the left run on a tie so the sort stays stable.
                if (c <= 0) {
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

pub fn coll_mut_list_sort_with(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.sortWith")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len <= 1) return arityErr("sortWith expects (comparator)");
    const cmp = ctx.args[1];
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    if (try mergeSortComparator(ctx, cmp, copy)) |e| return e;
    writeBackItems(it, a, copy) catch return error.OutOfMemory;
    return ok(Value.Unit);
}

pub fn coll_mut_list_fill(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.fill")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len <= 1) return arityErr("fill expects (value)");
    const value = ctx.args[1];
    const g = it.borrowMut();
    defer g.deinit();
    for (g.get().items) |*slot| slot.* = value;
    return ok(Value.Unit);
}

pub fn coll_mut_list_reverse(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.reverse")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    std.mem.reverse(Value, g.get().items);
    return ok(Value.Unit);
}

pub fn coll_iter_sorted_with(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("sortedWith expects (receiver, comparator)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "sortedWith")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    const comparator = ctx.args[1];
    if (comparator == .Comparator) {
        const descending = comparator.Comparator.descending;
        const empty = blk: {
            const steps_g = comparator.Comparator.steps.borrow();
            defer steps_g.deinit();
            break :blk steps_g.get().len == 0;
        };
        if (empty) {
            if (try sortListHostAwareDesc(ctx, items, descending)) |e| return e;
            return ok(try makeList(a, items, false));
        }
    }
    if (try mergeSortComparator(ctx, comparator, items)) |e| return e;
    return ok(try makeList(a, items, false));
}

fn iterExtreme(ctx: *CallCtx, want_max: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var best: ?Value = null;
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(items);
    const loop_keepalive = runtime.keepaliveMark();
    for (items) |v| {
        runtime.keepaliveRestore(loop_keepalive);
        if (best) |b| runtime.keepalivePush(b);
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (best) |b| {
            const o = switch (try compareValues(a, b, r)) {
                .order => |o| o,
                .err => |e| return e,
            };
            const replace = (want_max and o == .lt) or (!want_max and o == .gt);
            best = if (replace) r else b;
        } else best = r;
    }
    if (best) |b| return ok(b);
    return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
}

pub fn coll_iter_max_of(ctx: *CallCtx) Error!EvalResult {
    return iterExtreme(ctx, true, "maxOf");
}

pub fn coll_iter_min_of(ctx: *CallCtx) Error!EvalResult {
    return iterExtreme(ctx, false, "minOf");
}

pub fn coll_iter_on_each(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("onEach expects (receiver, block)");
    const recv = ctx.args[0];
    const items = switch (try iterableItemsCtx(ctx, recv, "onEach")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    for (items) |v| {
        switch (try invoke(ctx, &block, &.{v})) {
            .value => {},
            .err => |e| return e,
        }
    }
    return ok(recv);
}

pub fn coll_iter_map_not_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("mapNotNull expects (receiver, block)");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "mapNotNull")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var result: std.ArrayList(Value) = .empty;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (r != .Null) try result.append(a, r);
    }
    return ok(try makeListFromArrayList(a, result, false));
}
