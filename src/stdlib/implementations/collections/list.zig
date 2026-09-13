//! `List` and `MutableList` intrinsics: access, search, fold-right,
//! joinToString and mutation.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const InstanceData = runtime.InstanceData;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common_mod = @import("common.zig");
const appendVL = common_mod.appendVL;
const arityErr = common_mod.arityErr;
const bumpModCount = common_mod.bumpModCount;
const containsBoxedH = common_mod.containsBoxedH;
const display = common_mod.display;
const eqBoxedH = common_mod.eqBoxedH;
const fmt = common_mod.fmt;
const indexOfBoxed = common_mod.indexOfBoxed;
const indexOfBoxedH = common_mod.indexOfBoxedH;
const invoke = common_mod.invoke;
const isTransformCallable = common_mod.isTransformCallable;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const listLen = common_mod.listLen;
const listLenOf = common_mod.listLenOf;
const makeListBorrowed = common_mod.makeListBorrowed;
const makeListFromArrayList = common_mod.makeListFromArrayList;
const makeListVL = common_mod.makeListVL;
const makePair = common_mod.makePair;
const makeSetH = common_mod.makeSetH;
const makeStringOwned = common_mod.makeStringOwned;
const mapViewAddGuard = common_mod.mapViewAddGuard;
const ok = common_mod.ok;
const okElem = common_mod.okElem;
const readOnlyMutationGuard = common_mod.readOnlyMutationGuard;
const recvListItems = common_mod.recvListItems;
const snapshotEntries = common_mod.snapshotEntries;
const snapshotItems = common_mod.snapshotItems;
const structuralBump = common_mod.structuralBump;
const thrown = common_mod.thrown;
const typeErr = common_mod.typeErr;

const set_mod = @import("set.zig");
const collectColl = set_mod.collectColl;
const mutCollRemoveRetain = set_mod.mutCollRemoveRetain;

const views_mod = @import("views.zig");
const sublistComodGuard = views_mod.sublistComodGuard;
const syncMapView = views_mod.syncMapView;
const syncSublist = views_mod.syncSublist;

pub fn coll_list_size(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.size")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(listLen(it))));
}
pub fn coll_list_is_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.isEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) == 0 });
}
pub fn coll_list_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.isNotEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) != 0 });
}
pub fn coll_list_get(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.get")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("List.get requires an Int index");
    const i = ctx.args[1].Int;
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    if (i < 0 or @as(usize, @intCast(i)) >= items.len) {
        const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, items.len });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    return okElem(items[@intCast(i)]);
}
pub fn coll_list_contains(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.contains")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("contains requires an argument");
    const needle = ctx.args[1];
    // Snapshot first: re-entering the VM for a user `equals` under the list
    // borrow is unsafe.
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    return ok(.{ .Bool = try containsBoxedH(ctx.host, ctx.out, items, &needle) });
}
pub fn coll_list_index_of(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.indexOf")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("indexOf requires an argument");
    const needle = ctx.args[1];
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    const pos = try indexOfBoxedH(ctx.host, ctx.out, items, &needle);
    return ok(Value.newInt(if (pos) |p| @intCast(p) else -1));
}
pub fn coll_iter_index_of_first(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "indexOfFirst")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("indexOfFirst requires a block");
    const block = ctx.args[1];
    for (items, 0..) |v, i| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (r == .Bool and r.Bool) return ok(Value.newInt(@intCast(i)));
    }
    return ok(Value.newInt(-1));
}
pub fn coll_iter_index_of_last(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "indexOfLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("indexOfLast requires a block");
    const block = ctx.args[1];
    var found: i64 = -1;
    for (items, 0..) |v, i| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (r == .Bool and r.Bool) found = @intCast(i);
    }
    return ok(Value.newInt(found));
}
pub fn coll_list_fold_right(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "foldRight")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("foldRight requires an initial value");
    var acc = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("foldRight requires a block");
    const block = ctx.args[2];
    var i = items.len;
    while (i > 0) {
        i -= 1;
        acc = switch (try invoke(ctx, &block, &.{ items[i], acc })) {
            .value => |x| x,
            .err => |e| return e,
        };
    }
    return ok(acc);
}
fn reduceRightImpl(ctx: *CallCtx, or_null: bool) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "reduceRight")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("reduceRight requires a block");
    const block = ctx.args[1];
    if (items.len == 0) {
        if (or_null) return ok(Value.Null);
        return try thrown(a, "kotlin.UnsupportedOperationException", "Empty collection can't be reduced.");
    }
    var acc = items[items.len - 1];
    var i = items.len - 1;
    while (i > 0) {
        i -= 1;
        acc = switch (try invoke(ctx, &block, &.{ items[i], acc })) {
            .value => |x| x,
            .err => |e| return e,
        };
    }
    return ok(acc);
}
pub fn coll_list_reduce_right(ctx: *CallCtx) Error!EvalResult {
    return reduceRightImpl(ctx, false);
}
pub fn coll_list_reduce_right_or_null(ctx: *CallCtx) Error!EvalResult {
    return reduceRightImpl(ctx, true);
}
fn listLastImpl(ctx: *CallCtx, or_null: bool) Error!EvalResult {
    const a = ctx.allocator;
    // With no predicate, index the last element directly rather than snapshot
    // the whole collection, which would make `last()` O(n).
    if (ctx.args.len < 2) {
        switch (ctx.args[0]) {
            .List => |l| {
                const g = l.items.borrow();
                defer g.deinit();
                const items = g.get().items;
                if (items.len > 0) return okElem(items[items.len - 1]);
                if (or_null) return ok(Value.Null);
                return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
            },
            .Array => |ar| {
                const n = ar.len();
                if (n > 0) return okElem(ar.get(n - 1));
                if (or_null) return ok(Value.Null);
                return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
            },
            else => {},
        }
    }
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "last")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len >= 2) {
        const block = ctx.args[1];
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const r = switch (try invoke(ctx, &block, &.{items[i]})) {
                .value => |x| x,
                .err => |e| return e,
            };
            if (r == .Bool and r.Bool) return okElem(items[i]);
        }
        if (or_null) return ok(Value.Null);
        return try thrown(a, "kotlin.NoSuchElementException", "Collection contains no element matching the predicate.");
    }
    if (items.len > 0) return okElem(items[items.len - 1]);
    if (or_null) return ok(Value.Null);
    return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
}
pub fn coll_list_last(ctx: *CallCtx) Error!EvalResult {
    return listLastImpl(ctx, false);
}
pub fn coll_list_last_or_null(ctx: *CallCtx) Error!EvalResult {
    return listLastImpl(ctx, true);
}
pub fn coll_list_last_index_of(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.lastIndexOf")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("lastIndexOf requires an argument");
    const needle = ctx.args[1];
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (try eqBoxedH(ctx.host, ctx.out, &items[i], &needle)) return ok(Value.newInt(@intCast(i)));
    }
    return ok(Value.newInt(-1));
}

fn joinOptStr(a: Allocator, args: []const Value, idx: usize, default: []const u8) Error![]const u8 {
    if (idx >= args.len) return default;
    return switch (args[idx]) {
        .Null => default,
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk g.get().bytes;
        },
        else => |other| try display(a, other),
    };
}

fn joinToStringImpl(ctx: *CallCtx, items: []const Value, allow_instance_to_string: bool) Error!EvalResult {
    const a = ctx.allocator;
    var effective = ctx.args[1..];
    var transform_slot: ?Value = null;
    if (effective.len > 0) {
        const last = effective[effective.len - 1];
        if (isTransformCallable(last)) {
            transform_slot = last;
            effective = effective[0 .. effective.len - 1];
        }
    }
    const sep = try joinOptStr(a, effective, 0, ", ");
    const prefix = try joinOptStr(a, effective, 1, "");
    const postfix = try joinOptStr(a, effective, 2, "");
    const limit: i64 = if (effective.len <= 3 or effective[3] == .Null)
        -1
    else
        (effective[3].asI64() orelse -1);
    const truncated = try joinOptStr(a, effective, 4, "...");
    const n = items.len;
    const take: usize = if (limit < 0) n else @min(@as(usize, @intCast(limit)), n);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, prefix);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const v = items[i];
        if (i > 0) try out.appendSlice(a, sep);
        const piece: []const u8 = if (transform_slot) |t| blk: {
            const r = switch (try invoke(ctx, &t, &.{v})) {
                .value => |x| x,
                .err => |e| return e,
            };
            break :blk switch (r) {
                .String => |s| sblk: {
                    const g = s.borrow();
                    defer g.deinit();
                    break :sblk try a.dupe(u8, g.get().bytes);
                },
                else => try display(a, r),
            };
        } else if (allow_instance_to_string and v == .Instance) blk: {
            const m = try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out);
            if (m) |mr| {
                if (mr == .ok and mr.ok == .String) {
                    const g = mr.ok.String.borrow();
                    defer g.deinit();
                    break :blk try a.dupe(u8, g.get().bytes);
                }
            }
            break :blk try display(a, v);
        } else try display(a, v);
        try out.appendSlice(a, piece);
        if (runtime.freeScratch()) a.free(piece);
    }
    if (limit >= 0 and n > take) {
        if (take > 0) try out.appendSlice(a, sep);
        try out.appendSlice(a, truncated);
    }
    try out.appendSlice(a, postfix);
    const buf = try out.toOwnedSlice(a);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}

pub fn coll_list_join_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return arityErr("joinToString expects an iterable receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "joinToString")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return joinToStringImpl(ctx, items, true);
}

pub fn coll_array_join_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("Array.joinToString requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "Array.joinToString")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return joinToStringImpl(ctx, items, false);
}

/// Render one collection element, key or value: a user Instance through its own
/// `toString()`, everything else through `display`. Caller owns the slice.
fn elemPiece(ctx: *CallCtx, v: Value) Error![]u8 {
    const a = ctx.allocator;
    if (v == .Instance or v == .List or v == .Set or v == .Map or
        v == .Pair or v == .Triple or v == .Result)
    {
        if (try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out)) |mr| {
            if (mr == .ok and mr.ok == .String) {
                const g = mr.ok.String.borrow();
                defer g.deinit();
                return try a.dupe(u8, g.get().bytes);
            }
        }
    }
    return try display(a, v);
}

pub fn collToString(ctx: *CallCtx, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    if (try sublistComodGuard(a, &ctx.args[0])) |e| return e;
    const recv = ctx.args[0];
    if (recv == .Map) {
        const entries = try snapshotEntries(a, recv.Map.entries);
        defer a.free(entries);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, '{');
        for (entries, 0..) |kv, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            const kp = if (Value.referenceEq(&kv.key, &recv)) try a.dupe(u8, "(this Map)") else try elemPiece(ctx, kv.key);
            defer if (runtime.freeScratch()) a.free(kp);
            try out.appendSlice(a, kp);
            try out.append(a, '=');
            const vp = if (Value.referenceEq(&kv.value, &recv)) try a.dupe(u8, "(this Map)") else try elemPiece(ctx, kv.value);
            defer if (runtime.freeScratch()) a.free(vp);
            try out.appendSlice(a, vp);
        }
        try out.append(a, '}');
        return ok(try makeStringOwned(a, try out.toOwnedSlice(a)));
    }
    const items: ?[]Value = switch (recv) {
        .List => |l| try snapshotItems(a, l.items),
        .Set => |s| try snapshotItems(a, s.items),
        else => null,
    };
    if (items) |elems| {
        defer a.free(elems);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, '[');
        for (elems, 0..) |v, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            // A collection containing itself renders the self-slot as
            // `(this Collection)` rather than recursing, as Kotlin does.
            if (Value.referenceEq(&v, &recv)) {
                try out.appendSlice(a, "(this Collection)");
                continue;
            }
            const piece: []const u8 = try elemPiece(ctx, v);
            try out.appendSlice(a, piece);
            if (runtime.freeScratch()) a.free(piece);
        }
        try out.append(a, ']');
        const buf = try out.toOwnedSlice(a);
        return ok(try makeStringOwned(a, buf));
    }
    const buf = try display(a, recv);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}
pub fn coll_list_to_string(ctx: *CallCtx) Error!EvalResult {
    return collToString(ctx, "List.toString");
}

pub fn coll_mut_list_add(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (try readOnlyMutationGuard(a, ctx.args)) |e| return e;
    if (try mapViewAddGuard(a, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const it = switch (try recvListItems(a, ctx.args, "MutableList.add")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const user = ctx.args.len - 1;
    if (user == 1) {
        const g = it.borrowMut();
        defer g.deinit();
        if (runtime.reclaimEnabled()) ctx.args[1].retain();
        try g.get().append(a, ctx.args[1]);
        return ok(.{ .Bool = true });
    }
    if (user >= 2) {
        if (ctx.args[1] != .Int) return typeErr("add(index, item) requires an Int index");
        const i = ctx.args[1].Int;
        const item = ctx.args[2];
        const g = it.borrowMut();
        defer g.deinit();
        const len = g.get().items.len;
        if (i < 0 or @as(usize, @intCast(i)) > len) {
            const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
            const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
            if (runtime.freeScratch()) a.free(msg);
            return e;
        }
        if (runtime.reclaimEnabled()) item.retain();
        try g.get().insert(a, @intCast(i), item);
        return ok(Value.Unit);
    }
    return arityErr("add requires an argument");
}
pub fn coll_mut_list_add_first(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.addFirst")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("addFirst requires an argument");
    const g = it.borrowMut();
    defer g.deinit();
    if (runtime.reclaimEnabled()) ctx.args[1].retain();
    try g.get().insert(a, 0, ctx.args[1]);
    return ok(Value.Unit);
}
pub fn coll_mut_list_remove_first(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeFirst")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    if (g.get().items.len == 0) {
        return try thrown(a, "kotlin.NoSuchElementException", "ArrayDeque is empty.");
    }
    return ok(g.get().orderedRemove(0));
}
pub fn coll_mut_list_remove_last(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    if (g.get().pop()) |v| return ok(v);
    return try thrown(a, "kotlin.NoSuchElementException", "ArrayDeque is empty.");
}
pub fn coll_mut_list_remove_at(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeAt")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("removeAt requires an Int index");
    const i = ctx.args[1].Int;
    const g = it.borrowMut();
    defer g.deinit();
    const len = g.get().items.len;
    if (i < 0 or @as(usize, @intCast(i)) >= len) {
        const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    return ok(g.get().orderedRemove(@intCast(i)));
}
pub fn coll_mut_list_clear(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.clear")) {
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
pub fn coll_array_list_capacity_noop(ctx: *CallCtx) Error!EvalResult {
    // `trimToSize()` and `ensureCapacity(n)` are no-ops here, no backing-array
    // capacity being tracked, but Java registers them as structural
    // modifications, so a concurrent iterator must still fail fast.
    if (ctx.args.len > 0) bumpModCount(&ctx.args[0]);
    return ok(Value.Unit);
}

pub fn coll_list_flatten(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.flatten")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        switch (v) {
            .List => |l| try appendVL(&out, a, l.items),
            .Set => |s| try appendVL(&out, a, s.items),
            else => {
                const inner = switch (try iterableItemsCtx(ctx, v, "flatten")) {
                    .items => |x| x,
                    .err => |e| return e,
                };
                defer if (runtime.freeScratch()) a.free(inner);
                try out.appendSlice(a, inner);
            },
        }
    }
    return ok(try makeListBorrowed(a, out, false));
}

pub fn coll_list_unzip(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.unzip")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var firsts: std.ArrayList(Value) = .empty;
    var seconds: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (v != .Pair) return typeErr("unzip requires List<Pair<A, B>>");
        try firsts.append(a, v.Pair.first.asPtr().*);
        try seconds.append(a, v.Pair.second.asPtr().*);
    }
    return ok(try makePair(a, try makeListBorrowed(a, firsts, false), try makeListBorrowed(a, seconds, false)));
}

pub fn coll_list_contains_all(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.containsAll")) {
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

pub fn coll_list_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, false));
}
pub fn coll_list_to_mutable_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toMutableList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, true));
}
pub fn coll_list_to_set(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    return ok(try makeSetH(ctx.host, ctx.out, a, items, false));
}
pub fn coll_list_to_mutable_set(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toMutableSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    // `distinct()` is `toMutableSet().toList()`, so it dedups by `equals`, not
    // structurally.
    return ok(try makeSetH(ctx.host, ctx.out, a, items, true));
}

pub fn withIndexImpl(ctx: *CallCtx, items: []const Value) Error!Value {
    const a = ctx.allocator;
    var indexed: std.ArrayList(Value) = .empty;
    for (items, 0..) |v, i| {
        v.retain();
        const id = ctx.host.allocInstanceId();
        const fields = [_]InstanceData.Field{
            .{ .name = "index", .value = Value.newInt(@intCast(i)) },
            .{ .name = "value", .value = v },
        };
        try indexed.append(a, try ctx.host.newSynthInstance("kotlin.collections.IndexedValue", id, &fields));
    }
    return makeListFromArrayList(a, indexed, false);
}

pub fn coll_list_with_index(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.withIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try withIndexImpl(ctx, try snapshotItems(a, it)));
}
pub fn coll_array_with_index(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("Array.withIndex requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "Array.withIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return ok(try withIndexImpl(ctx, items));
}

pub fn coll_mut_list_add_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try mapViewAddGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    // `addAll` bumps the counter even for an empty argument, as JVM
    // `ArrayList.addAll` touches modCount before the size check, so a live
    // iterator fails fast afterwards.
    defer bumpModCount(&ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.addAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("addAll requires an argument");
    // In `addAll(index: Int, elements)` the collection is the third argument and
    // is inserted at `index` rather than appended.
    const indexed = ctx.args.len >= 3 and ctx.args[1] == .Int;
    const arg = if (indexed) ctx.args[2] else ctx.args[1];
    var to_add: []Value = undefined;
    switch (arg) {
        .List => |l| to_add = try snapshotItems(a, l.items),
        .Set => |s| to_add = try snapshotItems(a, s.items),
        .Array => |arr| to_add = try arr.snapshot(a),
        else => to_add = switch (try iterableItemsCtx(ctx, arg, "addAll")) {
            .items => |x| x,
            .err => |e| return e,
        },
    }
    defer if (runtime.freeScratch()) a.free(to_add);
    const changed = to_add.len != 0;
    const g = it.borrowMut();
    defer g.deinit();
    if (runtime.reclaimEnabled()) for (to_add) |v| v.retain();
    if (indexed) {
        const idx: usize = @min(@as(usize, @intCast(@max(ctx.args[1].Int, 0))), g.get().items.len);
        try g.get().insertSlice(a, idx, to_add);
    } else {
        try g.get().appendSlice(a, to_add);
    }
    return ok(.{ .Bool = changed });
}

pub fn coll_mut_list_remove(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.remove")) {
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

pub fn coll_mut_list_remove_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "removeAll", false, false);
}
pub fn coll_mut_list_retain_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.retainAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "retainAll", true, false);
}

pub fn coll_mut_list_set(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.set")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("set requires an Int index");
    const i = ctx.args[1].Int;
    if (ctx.args.len < 3) return arityErr("set requires (index, value)");
    const value = ctx.args[2];
    const g = it.borrowMut();
    defer g.deinit();
    const len = g.get().items.len;
    if (i < 0 or @as(usize, @intCast(i)) >= len) {
        const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
        // The replaced value's ownership transfers to the returned `prev`.
    if (runtime.reclaimEnabled()) value.retain();
    const prev = g.get().items[@intCast(i)];
    g.get().items[@intCast(i)] = value;
    return ok(prev);
}
