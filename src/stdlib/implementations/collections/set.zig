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
const indexOfBoxed = common_mod.indexOfBoxed;
const invoke = common_mod.invoke;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const listLen = common_mod.listLen;
const listLenOf = common_mod.listLenOf;
const makeList = common_mod.makeList;
const makeListVL = common_mod.makeListVL;
const makeSetVL = common_mod.makeSetVL;
const mapViewAddGuard = common_mod.mapViewAddGuard;
const ok = common_mod.ok;
const readOnlyMutationGuard = common_mod.readOnlyMutationGuard;
const recvSetItems = common_mod.recvSetItems;
const snapshotItems = common_mod.snapshotItems;
const structuralBump = common_mod.structuralBump;
const typeErr = common_mod.typeErr;

const list_mod = @import("list.zig");
const collToString = list_mod.collToString;
const withIndexImpl = list_mod.withIndexImpl;

const list_transforms_mod = @import("list_transforms.zig");
const sortListHostAware = list_transforms_mod.sortListHostAware;

const sequence_mod = @import("sequence.zig");
const materialiseSequence = sequence_mod.materialiseSequence;

const views_mod = @import("views.zig");
const syncMapView = views_mod.syncMapView;

fn setPlusImpl(ctx: *CallCtx, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    try appendVL(&out, a, it);
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    switch (arg) {
        .List => |l| {
            const src = try snapshotItems(a, l.items);
            defer if (runtime.freeScratch()) a.free(src);
            for (src) |v| {
                if (!try containsBoxedH(ctx.host, ctx.out, out.items, &v)) try out.append(a, v);
            }
        },
        .Set => |s| {
            const src = try snapshotItems(a, s.items);
            defer if (runtime.freeScratch()) a.free(src);
            for (src) |v| {
                if (!try containsBoxedH(ctx.host, ctx.out, out.items, &v)) try out.append(a, v);
            }
        },
        .Array, .Range, .Sequence => {
            const xs = switch (try iterableItemsCtx(ctx, arg, what)) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            for (xs) |v| {
                if (!try containsBoxedH(ctx.host, ctx.out, out.items, &v)) try out.append(a, v);
            }
        },
        else => {
            if (!try containsBoxedH(ctx.host, ctx.out, out.items, &arg)) try out.append(a, arg);
        },
    }
    // `out` holds borrowed elements, so retain each before the set adopts them.
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(try Value.newSet(a, .{ .items = try ValueList.init(a, out), .mutable = false, .backing = null }));
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
        .Set => |s| try appendVL(&removals, a, s.items),
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
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (!try containsBoxedH(ctx.host, ctx.out, removals.items, &v)) try out.append(a, v);
    }
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(try Value.newSet(a, .{ .items = try ValueList.init(a, out), .mutable = false, .backing = null }));
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
        .Set => |s| try appendVL(&other, a, s.items),
        else => return typeErr("intersect requires a collection"),
    }
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (try containsBoxedH(ctx.host, ctx.out, other.items, &v)) try out.append(a, v);
    }
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(try Value.newSet(a, .{ .items = try ValueList.init(a, out), .mutable = false, .backing = null }));
}

pub fn coll_set_size(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.size")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(listLen(it))));
}
pub fn coll_set_is_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.isEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) == 0 });
}
pub fn coll_set_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.isNotEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) != 0 });
}
pub fn coll_set_contains(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.contains")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("contains requires an argument");
    const needle = ctx.args[1];
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    return ok(.{ .Bool = try containsBoxedH(ctx.host, ctx.out, items, &needle) });
}

pub fn coll_set_sorted(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.sorted")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    if (try sortListHostAware(ctx, copy)) |e| return e;
    return ok(try makeList(a, copy, false));
}
pub fn coll_set_sorted_descending(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const v = try coll_set_sorted(ctx);
    if (v == .err) return v;
    const items = try snapshotItems(a, v.ok.List.items);
    defer if (runtime.freeScratch()) a.free(items);
    std.mem.reverse(Value, items);
    return ok(try makeList(a, items, false));
}
pub fn coll_set_to_string(ctx: *CallCtx) Error!EvalResult {
    return collToString(ctx, "Set.toString");
}

pub fn coll_mut_set_add(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try mapViewAddGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.add")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("add requires an argument");
    const arg = ctx.args[1];
    // Snapshot for the membership check: dispatching `equals` re-enters the VM,
    // which must not happen under the mutable borrow.
    const snap = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(snap);
    if (try containsBoxedH(ctx.host, ctx.out, snap, &arg)) return ok(.{ .Bool = false });
    const g = it.borrowMut();
    defer g.deinit();
    if (runtime.reclaimEnabled()) arg.retain();
    try g.get().append(a, arg);
    return ok(.{ .Bool = true });
}
pub fn coll_mut_set_remove(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.remove")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("remove requires an argument");
    const arg = ctx.args[1];
    var removed = false;
    {
        const g = it.borrowMut();
        defer g.deinit();
        if (indexOfBoxed(g.get().items, &arg)) |pos| {
            const gone = g.get().orderedRemove(pos);
            if (runtime.reclaimEnabled()) gone.release(a);
            removed = true;
        }
    }
    if (removed) syncMapView(a, ctx.args[0]);
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
    syncMapView(a, ctx.args[0]);
    return ok(Value.Unit);
}

pub fn collectColl(a: Allocator, v: ?Value) Error!?[]Value {
    if (v) |val| {
        switch (val) {
            .List => |l| return try snapshotItems(a, l.items),
            .Set => |s| return try snapshotItems(a, s.items),
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

fn mutCollRemoveRetainPred(ctx: *CallCtx, items: ValueList, recv: Value, retain: bool) Error!EvalResult {
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
    if (changed) syncMapView(a, recv);
    return ok(.{ .Bool = changed });
}

pub fn mutCollRemoveRetain(ctx: *CallCtx, items: ValueList, recv: Value, what: []const u8, retain: bool, allow_array: bool) Error!EvalResult {
    const a = ctx.allocator;
    const arg = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    if (isPredicateArg(arg)) return mutCollRemoveRetainPred(ctx, items, recv, retain);
    _ = allow_array; // `removeAll`/`retainAll` accept an Array overload too.
    const other = blk: {
        switch (arg) {
            .List => |l| break :blk try snapshotItems(a, l.items),
            .Set => |s| break :blk try snapshotItems(a, s.items),
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
    for (snap, 0..) |v, i| {
        const present = try containsBoxedH(ctx.host, ctx.out, other, &v);
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
    if (changed) syncMapView(a, recv);
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
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "removeAll", false, true);
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
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "retainAll", true, true);
}

pub fn coll_set_contains_all(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const other = (try collectColl(a, if (ctx.args.len > 1) ctx.args[1] else null)) orelse
        return typeErr("containsAll requires a collection");
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    for (other) |o| {
        if (!try containsBoxedH(ctx.host, ctx.out, items, &o)) return ok(.{ .Bool = false });
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
    return ok(try makeSetVL(a, it, false));
}
pub fn coll_set_to_mutable_set_(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toMutableSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeSetVL(a, it, true));
}
pub fn coll_set_with_index(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.withIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try withIndexImpl(ctx, try snapshotItems(a, it)));
}
pub fn coll_mut_set_add_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try mapViewAddGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.addAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
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
    // Collect the new items under a snapshot, key `equals` re-entering the VM,
    // then append them in one borrow.
    const initial = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(initial);
    var seen: std.ArrayList(Value) = .empty;
    defer seen.deinit(a);
    try seen.appendSlice(a, initial);
    var new_items: std.ArrayList(Value) = .empty;
    defer new_items.deinit(a);
    for (to_add) |v| {
        if (!try containsBoxedH(ctx.host, ctx.out, seen.items, &v)) {
            try seen.append(a, v);
            try new_items.append(a, v);
        }
    }
    if (new_items.items.len == 0) return ok(.{ .Bool = false });
    const g = it.borrowMut();
    defer g.deinit();
    for (new_items.items) |v| {
        if (runtime.reclaimEnabled()) v.retain();
        try g.get().append(a, v);
    }
    return ok(.{ .Bool = true });
}
