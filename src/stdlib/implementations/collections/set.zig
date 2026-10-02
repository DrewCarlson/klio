//! `Set` intrinsics: set algebra, membership, sorting and mutation.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common_mod = @import("common.zig");
const appendVL = common_mod.appendVL;
const arityErr = common_mod.arityErr;
const containsBoxedH = common_mod.containsBoxedH;
const indexOfBoxedH = common_mod.indexOfBoxedH;
const invoke = common_mod.invoke;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const listLenOf = common_mod.listLenOf;
const makeListVL = common_mod.makeListVL;
const makeSetVL = common_mod.makeSetVL;
const ok = common_mod.ok;
const readOnlyMutationGuard = common_mod.readOnlyMutationGuard;
const recvSet = common_mod.recvSet;
const recvSetItems = common_mod.recvSetItems;
const snapshotItems = common_mod.snapshotItems;
const structuralBump = common_mod.structuralBump;
const typeErr = common_mod.typeErr;

const list_mod = @import("list.zig");
const collToString = list_mod.collToString;
const withIndexImpl = list_mod.withIndexImpl;

const list_transforms_mod = @import("list_transforms.zig");

const sequence_mod = @import("sequence.zig");
const materialiseSequence = sequence_mod.materialiseSequence;

const views_mod = @import("views.zig");
const map_mod = @import("map.zig");
const hashing = @import("hashing.zig");

fn setPlusImpl(ctx: *CallCtx, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    const own = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(own);
    var seen = hashing.Seen.init();
    defer seen.deinit(a);
    if (try seenAddAll(ctx, &seen, own)) |e| return e;
    switch (arg) {
        .List => |l| {
            const src = try snapshotItems(a, l.items);
            defer if (runtime.freeScratch()) a.free(src);
            if (try seenAddAll(ctx, &seen, src)) |e| return e;
        },
        .Set => |st| {
            const src = try snapshotItems(a, st.dense());
            defer if (runtime.freeScratch()) a.free(src);
            if (try seenAddAll(ctx, &seen, src)) |e| return e;
        },
        .Array, .Range, .Sequence => {
            const xs = switch (try iterableItemsCtx(ctx, arg, what)) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            if (try seenAddAll(ctx, &seen, xs)) |e| return e;
        },
        else => if (try seenAddAll(ctx, &seen, &.{arg})) |e| return e,
    }
    return ok(try seen.intoSet(a, false));
}

/// Keeps each of `xs` in `seen` unless an equal element is kept: the exception when a
/// `hashCode` override throws.
fn seenAddAll(ctx: *CallCtx, seen: *hashing.Seen, xs: []const Value) Error!?EvalResult {
    for (xs) |v| switch (try seen.add(ctx.host, ctx.out, ctx.allocator, v)) {
        .added, .present => {},
        .thrown => |e| return e,
    };
    return null;
}

/// The elements of `xs` as a dedupe to test membership against.
fn seenOf(ctx: *CallCtx, xs: []const Value) Error!union(enum) { seen: hashing.Seen, thrown: EvalResult } {
    var seen = hashing.Seen.init();
    if (try seenAddAll(ctx, &seen, xs)) |e| {
        seen.deinit(ctx.allocator);
        return .{ .thrown = e };
    }
    return .{ .seen = seen };
}

/// Whether `seen` holds an element equal to `v`.
fn seenHas(ctx: *CallCtx, seen: *hashing.Seen, v: Value) Error!union(enum) { yes: bool, thrown: EvalResult } {
    return switch (try seen.find(ctx.host, ctx.out, ctx.allocator, v)) {
        .at => .{ .yes = true },
        .none => .{ .yes = false },
        .thrown => |e| .{ .thrown = e },
    };
}

pub fn coll_set_plus(ctx: *CallCtx) Error!EvalResult {
    return setPlusImpl(ctx, "Set.plus");
}
pub fn coll_set_union(ctx: *CallCtx) Error!EvalResult {
    return setPlusImpl(ctx, "Set.plus");
}

pub fn coll_set_minus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.minus")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("minus requires an argument");
    const arg = ctx.args[1];
    var removals: std.ArrayList(Value) = .empty;
    defer if (runtime.freeScratch()) removals.deinit(a);
    switch (arg) {
        .List => |l| try appendVL(&removals, a, l.items),
        .Set => |s| try appendVL(&removals, a, s.dense()),
        .Array, .Range, .Sequence => {
            const xs = switch (try iterableItemsCtx(ctx, arg, "minus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            try removals.appendSlice(a, xs);
        },
        else => try removals.append(a, arg),
    }
    var gone = switch (try seenOf(ctx, removals.items)) {
        .seen => |x| x,
        .thrown => |e| return e,
    };
    defer gone.deinit(a);
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| switch (try seenHas(ctx, &gone, v)) {
        .yes => |y| if (!y) try out.append(a, v),
        .thrown => |e| return e,
    };
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(try Value.newSet(a, .{ .elems = try ValueList.init(a, out), .mutable = false, .backing = null }));
}
pub fn coll_set_subtract(ctx: *CallCtx) Error!EvalResult {
    return coll_set_minus(ctx);
}

pub fn coll_set_intersect(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.intersect")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("intersect requires an argument");
    const arg = ctx.args[1];
    var other: std.ArrayList(Value) = .empty;
    defer if (runtime.freeScratch()) other.deinit(a);
    switch (arg) {
        .List => |l| try appendVL(&other, a, l.items),
        .Set => |s| try appendVL(&other, a, s.dense()),
        else => switch (try iterableItemsCtx(ctx, arg, "Set.intersect")) {
            .items => |x| try other.appendSlice(a, x),
            .err => |e| return e,
        },
    }
    var kept = switch (try seenOf(ctx, other.items)) {
        .seen => |x| x,
        .thrown => |e| return e,
    };
    defer kept.deinit(a);
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| switch (try seenHas(ctx, &kept, v)) {
        .yes => |y| if (y) try out.append(a, v),
        .thrown => |e| return e,
    };
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(try Value.newSet(a, .{ .elems = try ValueList.init(a, out), .mutable = false, .backing = null }));
}

pub fn coll_set_size(ctx: *CallCtx) Error!EvalResult {
    const st = switch (try recvSet(ctx.allocator, ctx.args, "Set.size")) {
        .set => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(st.len())));
}
pub fn coll_set_is_empty(ctx: *CallCtx) Error!EvalResult {
    const st = switch (try recvSet(ctx.allocator, ctx.args, "Set.isEmpty")) {
        .set => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = st.len() == 0 });
}
pub fn coll_set_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const st = switch (try recvSet(ctx.allocator, ctx.args, "Set.isNotEmpty")) {
        .set => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = st.len() != 0 });
}
pub fn coll_set_contains(ctx: *CallCtx) Error!EvalResult {
    switch (try recvSet(ctx.allocator, ctx.args, "Set.contains")) {
        .set => {},
        .err => |e| return e,
    }
    if (ctx.args.len < 2) return arityErr("contains requires an argument");
    const needle = ctx.args[1];
    const l = try hashing.setFind(ctx.host, ctx.out, ctx.allocator, ctx.args[0].Set, &needle);
    return switch (l.found) {
        .thrown => |e| e,
        .at => ok(.{ .Bool = true }),
        .none => ok(.{ .Bool = false }),
    };
}

pub fn coll_set_to_string(ctx: *CallCtx) Error!EvalResult {
    return collToString(ctx, "Set.toString");
}

pub fn coll_mut_set_add(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    switch (try recvSet(a, ctx.args, "MutableSet.add")) {
        .set => {},
        .err => |e| return e,
    }
    if (ctx.args.len < 2) return arityErr("add requires an argument");
    return switch (try hashing.setAdd(ctx.host, ctx.out, a, ctx.args[0].Set, ctx.args[1])) {
        .thrown => |e| e,
        .done => |added| ok(.{ .Bool = added }),
    };
}
pub fn coll_mut_set_remove(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    switch (try recvSet(a, ctx.args, "MutableSet.remove")) {
        .set => {},
        .err => |e| return e,
    }
    if (ctx.args.len < 2) return arityErr("remove requires an argument");
    const removed = switch (try hashing.setRemove(ctx.host, ctx.out, a, ctx.args[0].Set, ctx.args[1])) {
        .thrown => |e| return e,
        .done => |x| x,
    };
    return ok(.{ .Bool = removed });
}
pub fn coll_mut_set_clear(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.clear")) {
        .items => |x| x,
        .err => |e| return e,
    };
    {
        const g = it.borrowMut();
        defer g.deinit();
        if (runtime.reclaimEnabled()) for (g.get().items) |v| v.release(a);
        g.get().clearRetainingCapacity();
    }
    return ok(Value.Unit);
}

pub fn collectColl(a: Allocator, v: ?Value) Error!?[]Value {
    if (v) |val| {
        switch (val) {
            .List => |l| return try snapshotItems(a, l.items),
            .Set => |s| return try snapshotItems(a, s.dense()),
            .Array => |arr| return try arr.snapshot(a),
            else => {},
        }
    }
    return null;
}

/// A `removeAll` argument that is a function reference rather than a collection
/// is the predicate form `removeAll { (T) -> Boolean }`.
fn isPredicateArg(v: Value) bool {
    return switch (v) {
        .IrClosure, .BoundMethod, .Intrinsic => true,
        else => false,
    };
}

fn mutCollRemoveRetainPred(ctx: *CallCtx, items: ValueList, retain: bool) Error!EvalResult {
    const a = ctx.allocator;
    const pred = ctx.args[1];
    const snap = try snapshotItems(a, items);
    defer if (runtime.freeScratch()) a.free(snap);
    const keep = try a.alloc(bool, snap.len);
    defer if (runtime.freeScratch()) a.free(keep);
    for (snap, 0..) |v, i| {
        const rv = switch (try invoke(ctx, &pred, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        const truth = rv == .Bool and rv.Bool;
        keep[i] = if (retain) truth else !truth;
    }
    var changed = false;
    {
        const g = items.borrowMut();
        defer g.deinit();
        const list = g.get();
        const before = list.items.len;
        var w: usize = 0;
        for (list.items, 0..) |v, i| {
            const k = if (i < keep.len) keep[i] else true;
            if (k) {
                list.items[w] = v;
                w += 1;
            } else if (runtime.reclaimEnabled()) {
                v.release(a);
            }
        }
        list.shrinkRetainingCapacity(w);
        changed = list.items.len != before;
    }
    return ok(.{ .Bool = changed });
}

pub fn mutCollRemoveRetain(ctx: *CallCtx, items: ValueList, what: []const u8, retain: bool, allow_array: bool) Error!EvalResult {
    const a = ctx.allocator;
    const arg = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    if (isPredicateArg(arg)) return mutCollRemoveRetainPred(ctx, items, retain);
    _ = allow_array; // `removeAll`/`retainAll` accept an Array overload too.
    const other = blk: {
        switch (arg) {
            .List => |l| break :blk try snapshotItems(a, l.items),
            .Set => |s| break :blk try snapshotItems(a, s.dense()),
            .Array => |arr| break :blk try arr.snapshot(a),
            else => break :blk switch (try iterableItemsCtx(ctx, arg, what)) {
                .items => |x| x,
                .err => |e| return e,
            },
        }
    };
    // Decide per element under a snapshot, since membership dispatches a user
    // `equals` that re-enters the VM, then compact in place under one borrow.
    const snap = try snapshotItems(a, items);
    defer if (runtime.freeScratch()) a.free(snap);
    const keep_flags = try a.alloc(bool, snap.len);
    defer if (runtime.freeScratch()) a.free(keep_flags);
    var others = switch (try seenOf(ctx, other)) {
        .seen => |x| x,
        .thrown => |e| return e,
    };
    defer others.deinit(a);
    for (snap, 0..) |v, i| {
        const present = switch (try seenHas(ctx, &others, v)) {
            .yes => |y| y,
            .thrown => |e| return e,
        };
        keep_flags[i] = if (retain) present else !present;
    }
    var changed = false;
    {
        const g = items.borrowMut();
        defer g.deinit();
        const list = g.get();
        const before = list.items.len;
        var w: usize = 0;
        var r: usize = 0;
        while (r < list.items.len) : (r += 1) {
            const v = list.items[r];
            if (r < keep_flags.len and keep_flags[r]) {
                list.items[w] = v;
                w += 1;
            } else if (runtime.reclaimEnabled()) {
                v.release(a);
            }
        }
        list.shrinkRetainingCapacity(w);
        changed = list.items.len != before;
    }
    return ok(.{ .Bool = changed });
}

pub fn coll_mut_set_remove_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.removeAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, "removeAll", false, true);
}
pub fn coll_mut_set_retain_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.retainAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, "retainAll", true, true);
}

pub fn coll_set_contains_all(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    switch (try recvSet(a, ctx.args, "Set.containsAll")) {
        .set => {},
        .err => |e| return e,
    }
    if (ctx.args.len < 2) return arityErr("containsAll requires a collection");
    const other = switch (try iterableItemsCtx(ctx, ctx.args[1], "Set.containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    for (other) |o| {
        const l = try hashing.setFind(ctx.host, ctx.out, a, ctx.args[0].Set, &o);
        switch (l.found) {
            .thrown => |e| return e,
            .none => return ok(.{ .Bool = false }),
            .at => {},
        }
    }
    return ok(.{ .Bool = true });
}

pub fn coll_set_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, false));
}
pub fn coll_set_to_mutable_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toMutableList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, true));
}
pub fn coll_set_to_set_(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try copySet(a, it, false));
}
pub fn coll_set_to_mutable_set_(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toMutableSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try copySet(a, it, true));
}

/// A new set of a set's elements, which are distinct already.
fn copySet(a: Allocator, it: ValueList, mutable: bool) Error!Value {
    var copy: std.ArrayList(Value) = .empty;
    try appendVL(&copy, a, it);
    if (runtime.reclaimEnabled()) for (copy.items) |e| e.retain();
    return Value.newSet(a, .{
        .elems = try ValueList.init(a, copy),
        .mutable = mutable,
        .backing = null,
        .mod_count = try common_mod.modCountFor(a, mutable),
    });
}
pub fn coll_set_with_index(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.withIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return withIndexImpl(ctx, try snapshotItems(a, it));
}
pub fn coll_mut_set_add_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    switch (try recvSet(a, ctx.args, "MutableSet.addAll")) {
        .set => {},
        .err => |e| return e,
    }
    const arg = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    const to_add = if (arg == .Sequence)
        switch (try materialiseSequence(a, ctx.host, ctx.out, arg)) {
            .items => |x| x,
            .err => |e| return .{ .err = e },
        }
    else
        (try collectColl(a, arg)) orelse switch (try iterableItemsCtx(ctx, arg, "MutableSet.addAll")) {
            .items => |x| x,
            .err => |e| return e,
        };
    var changed = false;
    for (to_add) |v| switch (try hashing.setAdd(ctx.host, ctx.out, a, ctx.args[0].Set, v)) {
        .thrown => |e| return e,
        .done => |added| changed = changed or added,
    };
    return ok(.{ .Bool = changed });
}
