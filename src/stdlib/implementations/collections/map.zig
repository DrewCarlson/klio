//! `Map` intrinsics: scope helpers, map algebra, access, key/value/entry
//! views, mutation and the additional map members.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const MapPair = runtime.MapPair;
const CollBackingRef = runtime.CollBackingRef;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const builders_mod = @import("builders.zig");
const sortMapByKey = builders_mod.sortMapByKey;

const common_mod = @import("common.zig");
const MapEntriesOutcome = common_mod.MapEntriesOutcome;
const appendVL = common_mod.appendVL;
const arityErr = common_mod.arityErr;
const containsBoxed = common_mod.containsBoxed;
const display = common_mod.display;
const entriesCounterNow = common_mod.entriesCounterNow;
const entriesModCountClone = common_mod.entriesModCountClone;
const eqBoxed = common_mod.eqBoxed;
const fmt = common_mod.fmt;
const invoke = common_mod.invoke;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const makeListFromArrayList = common_mod.makeListFromArrayList;
const makeMap = common_mod.makeMap;
const makeMapH = common_mod.makeMapH;
const makePair = common_mod.makePair;
const mapEntriesLen = common_mod.mapEntriesLen;
const mapLen = common_mod.mapLen;
const mapStructuralBump = common_mod.mapStructuralBump;
const ok = common_mod.ok;
const okElem = common_mod.okElem;
const readOnlyMutationGuard = common_mod.readOnlyMutationGuard;
const recvMapEntries = common_mod.recvMapEntries;
const snapshotEntries = common_mod.snapshotEntries;
const snapshotItems = common_mod.snapshotItems;
const thrown = common_mod.thrown;
const typeErr = common_mod.typeErr;

const list_mod = @import("list.zig");
const collToString = list_mod.collToString;

const list_transforms_mod = @import("list_transforms.zig");
const pairsFromValues = list_transforms_mod.pairsFromValues;
const userMapPairs = list_transforms_mod.userMapPairs;

const sequence_mod = @import("sequence.zig");
const materialiseSequence = sequence_mod.materialiseSequence;

// =====================================================================
// Map scope helpers
// =====================================================================

pub fn map_get_or_else(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 3) return arityErr("getOrElse expects (receiver, key, block)");
    if (ctx.args[0] != .Map) return typeErr("getOrElse requires a Map receiver");
    const key = ctx.args[1];
    {
        const g = ctx.args[0].Map.entries.borrowMut();
        defer g.deinit();
        // `getOrElse` is `get(key) ?: defaultValue()`: a present-but-null value
        // falls through to the default just like an absent key.
        if (try g.get().find(a, &key)) |i| {
            const v = g.get().pairs.items[i].value;
            if (v != .Null) return okElem(v);
        }
    }
    const block = ctx.args[2];
    return try ctx.host.invokeCallable(&block, &.{}, ctx.out);
}

pub fn map_get_or_put(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 3) return arityErr("getOrPut expects (receiver, key, block)");
    if (ctx.args[0] != .Map) return typeErr("getOrPut requires a MutableMap receiver");
    const entries_rc = ctx.args[0].Map.entries;
    const key = ctx.args[1];
    {
        const g = entries_rc.borrowMut();
        defer g.deinit();
        // `getOrPut` returns the stored value only when it is non-null; a
        // present-but-null value is recomputed and stored (Kotlin's `value
        // == null` branch).
        if (try g.get().find(a, &key)) |i| {
            const v = g.get().pairs.items[i].value;
            if (v != .Null) return okElem(v);
        }
    }
    const block = ctx.args[2];
    const new_v = switch (try invoke(ctx, &block, &.{})) {
        .value => |v| v,
        .err => |e| return e,
    };
    {
        const g = entries_rc.borrowMut();
        defer g.deinit();
        // The map takes ownership of one ref to the stored value; the block's
        // `new_v` is also returned, so retain it for the map and hand back the
        // block's owned ref untouched.
        if (runtime.reclaimEnabled()) new_v.retain();
        // A present key (its value was null, which is why we got here) is
        // updated in place; a genuinely absent key appends a new entry.
        if (try g.get().find(a, &key)) |i| {
            const old = g.get().pairs.items[i].value;
            g.get().pairs.items[i].value = new_v;
            if (runtime.reclaimEnabled()) old.release(a);
        } else {
            if (runtime.reclaimEnabled()) key.retain();
            try g.get().pairs.append(a, .{ .key = key, .value = new_v });
            try g.get().noteAppended(a, g.get().pairs.items.len - 1);
        }
    }
    return ok(new_v);
}

// =====================================================================
// Map ops
// =====================================================================

pub fn coll_map_to_mutable_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toMutableMap requires a Map receiver");
    return ok(try makeMap(a, try snapshotEntries(a, ctx.args[0].Map.entries), true));
}
pub fn coll_map_to_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toMap requires a Map receiver");
    // `toMap(destination)`: merge into the supplied mutable map and
    // return IT (live, mutable), never a read-only snapshot.
    if (ctx.args.len >= 2 and ctx.args[1] == .Map) {
        const src = try snapshotEntries(a, ctx.args[0].Map.entries);
        defer if (runtime.freeScratch()) a.free(src);
        const dest = ctx.args[1];
        const g = dest.Map.entries.borrowMut();
        defer g.deinit();
        for (src) |kv| {
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
    return ok(try makeMap(a, try snapshotEntries(a, ctx.args[0].Map.entries), false));
}

pub fn coll_map_plus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.plus")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(MapPair) = .empty;
    try out.appendSlice(a, try snapshotEntries(a, entries));
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    switch (arg) {
        .Pair => try out.append(a, .{ .key = arg.Pair.first.asPtr().*, .value = arg.Pair.second.asPtr().* }),
        .Map => |e| try out.appendSlice(a, try snapshotEntries(a, e.entries)),
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            for (g.get().items) |p| {
                if (p == .Pair) try out.append(a, .{ .key = p.Pair.first.asPtr().*, .value = p.Pair.second.asPtr().* });
            }
        },
        .Set => |s| {
            const g = s.items.borrow();
            defer g.deinit();
            for (g.get().items) |p| {
                if (p == .Pair) try out.append(a, .{ .key = p.Pair.first.asPtr().*, .value = p.Pair.second.asPtr().* });
            }
        },
        .Array, .Sequence, .Range => {
            const items = switch (try iterableItemsCtx(ctx, arg, "Map.plus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(items);
            for (items) |p| {
                if (p == .Pair) try out.append(a, .{ .key = p.Pair.first.asPtr().*, .value = p.Pair.second.asPtr().* });
            }
        },
        else => return typeErr("Map.plus expects a Pair, Map, or Iterable<Pair>"),
    }
    return ok(try makeMapH(ctx.host, ctx.out, a, out.items, false));
}

pub fn coll_map_minus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.minus")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("minus requires an argument");
    const arg = ctx.args[1];
    var keys: std.ArrayList(Value) = .empty;
    switch (arg) {
        .List => |l| try appendVL(&keys, a, l.items),
        .Set => |s| try appendVL(&keys, a, s.items),
        .Array, .Sequence, .Range => {
            const items = switch (try iterableItemsCtx(ctx, arg, "Map.minus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(items);
            try keys.appendSlice(a, items);
        },
        else => try keys.append(a, arg),
    }
    var out: std.ArrayList(MapPair) = .empty;
    const src = try snapshotEntries(a, entries);
    for (src) |kv| {
        if (!containsBoxed(keys.items, &kv.key)) try out.append(a, kv);
    }
    return ok(try makeMapH(ctx.host, ctx.out, a, out.items, false));
}

pub fn coll_map_size(ctx: *CallCtx) Error!EvalResult {
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "Map.size")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(mapLen(entries))));
}
pub fn coll_map_is_empty(ctx: *CallCtx) Error!EvalResult {
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "Map.isEmpty")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = mapLen(entries) == 0 });
}
pub fn coll_map_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "Map.isNotEmpty")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = mapLen(entries) != 0 });
}

/// Index of `key`, honoring a class-instance key's custom `equals`.
fn mapKeyIndex(ctx: *CallCtx, entries: MapEntries, key: Value) Error!?usize {
    if (key != .Instance) {
        // `find` builds/uses the hash index (O(1) for large maps), falling back
        // to a linear scan for small maps or non-hashable keys.
        const g = entries.borrowMut();
        defer g.deinit();
        return try g.get().find(ctx.allocator, &key);
    }
    const keys = blk: {
        const g = entries.borrow();
        defer g.deinit();
        var ks = try ctx.allocator.alloc(Value, g.get().pairs.items.len);
        for (g.get().pairs.items, 0..) |kv, i| ks[i] = kv.key;
        break :blk ks;
    };
    // Scratch key snapshot (the key Values themselves stay owned by the map).
    defer if (runtime.freeScratch()) ctx.allocator.free(keys);
    for (keys, 0..) |k, i| {
        if (try ctx.host.invokeMethod(&k, "equals", &.{key}, ctx.out)) |m| {
            if (m == .ok and m.ok == .Bool) {
                if (m.ok.Bool) return i;
                continue;
            }
        }
        if (eqBoxed(&k, &key)) return i;
    }
    return null;
}

pub fn coll_map_get(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.get")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("get requires a key");
    const key = ctx.args[1];
    if (try mapKeyIndex(ctx, entries, key)) |i| {
        const g = entries.borrow();
        defer g.deinit();
        if (i < g.get().pairs.items.len) return okElem(g.get().pairs.items[i].value);
    }
    return ok(Value.Null);
}
pub fn coll_map_contains_key(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.containsKey")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("containsKey requires a key");
    const key = ctx.args[1];
    return ok(.{ .Bool = (try mapKeyIndex(ctx, entries, key)) != null });
}
pub fn coll_map_contains_value(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.containsValue")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("containsValue requires a value");
    const value = ctx.args[1];
    const g = entries.borrow();
    defer g.deinit();
    for (g.get().pairs.items) |kv| {
        if (eqBoxed(&kv.value, &value)) return ok(.{ .Bool = true });
    }
    return ok(.{ .Bool = false });
}

pub fn coll_map_keys(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // A read-only map's keys view is read-only too, mirroring `entries`.
    const writable = ctx.args.len > 0 and ctx.args[0] == .Map and ctx.args[0].Map.mutable;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.keys")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var keys: std.ArrayList(Value) = .empty;
    {
        const g = entries.borrow();
        defer g.deinit();
        // The keys view owns one ref per element (its teardown releases them
        // via releaseValueList regardless of `backing`); retain each borrowed
        // key, mirroring `coll_map_entries`.
        for (g.get().pairs.items) |kv| {
            if (runtime.reclaimEnabled()) kv.key.retain();
            try keys.append(a, kv.key);
        }
    }
    const backing = try CollBackingRef.init(a, .{ .map = .{ .entries = entries, .kind = .Keys } });
    return ok(try Value.newSet(a, .{ .items = try ValueList.init(a, keys), .mutable = writable, .backing = backing.cell, .mod_count = entriesModCountClone(entries) }));
}
pub fn coll_map_values(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // A read-only map's values view is read-only too, mirroring `entries`.
    const writable = ctx.args.len > 0 and ctx.args[0] == .Map and ctx.args[0].Map.mutable;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.values")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var values: std.ArrayList(Value) = .empty;
    {
        const g = entries.borrow();
        defer g.deinit();
        // The values view owns one ref per element; retain each borrowed value.
        for (g.get().pairs.items) |kv| {
            if (runtime.reclaimEnabled()) kv.value.retain();
            try values.append(a, kv.value);
        }
    }
    const backing = try CollBackingRef.init(a, .{ .map = .{ .entries = entries, .kind = .Values } });
    return ok(try Value.newList(a, .{ .items = try ValueList.init(a, values), .mutable = writable, .enum_entries = false, .backing = backing.cell, .mod_count = entriesModCountClone(entries) }));
}
pub fn coll_map_entries(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // A read-only map's entries are read-only too: entries carry no
    // backing (setValue throws) and the view set refuses mutation.
    const writable = ctx.args.len > 0 and ctx.args[0] == .Map and ctx.args[0].Map.mutable;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.entries")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var map_entries: std.ArrayList(Value) = .empty;
    const stamp = entriesCounterNow(entries);
    {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| {
            kv.key.retain();
            kv.value.retain();
            try map_entries.append(a, try Value.newMapEntry(a, .{
                .key = try Value.boxRef(a, kv.key),
                .value = try Value.boxRef(a, kv.value),
                .backing = if (writable) .from(entries) else .{},
                .exp_mod = stamp,
            }));
        }
    }
    const backing = try CollBackingRef.init(a, .{ .map = .{ .entries = entries, .kind = .Entries } });
    return ok(try Value.newSet(a, .{ .items = try ValueList.init(a, map_entries), .mutable = writable, .backing = backing.cell, .mod_count = entriesModCountClone(entries) }));
}
pub fn coll_map_to_string(ctx: *CallCtx) Error!EvalResult {
    return collToString(ctx, "Map.toString");
}

pub fn coll_mut_map_put(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "MutableMap.put")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    if (ctx.args.len < 2) return arityErr("put requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("put requires a value");
    const value = ctx.args[2];
    if (try mapKeyIndex(ctx, entries, key)) |i| {
        const g = entries.borrowMut();
        defer g.deinit();
        // The map owns the new value; the replaced value's ownership transfers
        // to the returned `prev` (Kotlin `put` returns the previous value).
        if (runtime.reclaimEnabled()) value.retain();
        const prev = g.get().pairs.items[i].value;
        g.get().pairs.items[i].value = value;
        return ok(prev);
    }
    const g = entries.borrowMut();
    defer g.deinit();
    // The map takes ownership of one ref to the stored key and value.
    if (runtime.reclaimEnabled()) {
        key.retain();
        value.retain();
    }
    try g.get().pairs.append(a, .{ .key = key, .value = value });
    try g.get().noteAppended(a, g.get().pairs.items.len - 1);
    return ok(Value.Null);
}
pub fn coll_mut_map_remove(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "MutableMap.remove")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    if (ctx.args.len < 2) return arityErr("remove requires a key");
    const key = ctx.args[1];
    if (try mapKeyIndex(ctx, entries, key)) |pos| {
        const g = entries.borrowMut();
        defer g.deinit();
        const kv = g.get().pairs.orderedRemove(pos);
        g.get().invalidate();
        // `remove` transfers the entry out of the map: the value's owned ref
        // moves to the returned result (no retain), and the removed key — which
        // the map owned and which is not returned — must be released.
        if (runtime.reclaimEnabled()) kv.key.release(a);
        return ok(kv.value);
    }
    return ok(Value.Null);
}
pub fn coll_mut_map_clear(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "MutableMap.clear")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    const g = entries.borrowMut();
    defer g.deinit();
    g.get().pairs.clearRetainingCapacity();
    g.get().invalidate();
    return ok(Value.Unit);
}

// ----- Map scope helpers (merge / putIfAbsent / replace / compute*) -----

fn mutMapEntriesRc(a: Allocator, recv: Value, who: []const u8) Error!MapEntriesOutcome {
    if (recv == .Map) return .{ .entries = recv.Map.entries };
    return .{ .err = typeErr(try fmt(a, "{s} requires a MutableMap receiver", .{who})) };
}

fn mapFind(entries: MapEntries, key: Value) ?Value {
    const g = entries.borrow();
    defer g.deinit();
    for (g.get().pairs.items) |kv| {
        if (eqBoxed(&kv.key, &key)) return kv.value;
    }
    return null;
}

fn mapSet(a: Allocator, entries: MapEntries, key: Value, value: Value) Error!void {
    const g = entries.borrowMut();
    defer g.deinit();
    for (g.get().pairs.items) |*kv| {
        if (eqBoxed(&kv.key, &key)) {
            // Replace: the map owns the new value and drops the replaced one
            // (the existing key is kept; the new key arg is discarded).
            if (runtime.reclaimEnabled()) {
                value.retain();
                kv.value.release(a);
            }
            kv.value = value;
            return;
        }
    }
    // Append: the map takes ownership of one ref to the stored key and value.
    if (runtime.reclaimEnabled()) {
        key.retain();
        value.retain();
    }
    try g.get().pairs.append(a, .{ .key = key, .value = value });
    try g.get().noteAppended(a, g.get().pairs.items.len - 1);
}

fn mapRemoveKey(entries: MapEntries, key: Value) void {
    const g = entries.borrowMut();
    defer g.deinit();
    for (g.get().pairs.items, 0..) |kv, i| {
        if (eqBoxed(&kv.key, &key)) {
            _ = g.get().pairs.orderedRemove(i);
            g.get().invalidate();
            return;
        }
    }
}

pub fn map_merge(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "merge")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("merge requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("merge requires a value");
    const value = ctx.args[2];
    if (ctx.args.len < 4) return arityErr("merge requires a remapping block");
    const block = ctx.args[3];
    const existing = mapFind(entries, key);
    const new_val = if (existing) |old| switch (try invoke(ctx, &block, &.{ old, value })) {
        .value => |v| v,
        .err => |e| return e,
    } else value;
    if (new_val == .Null) {
        mapRemoveKey(entries, key);
    } else {
        try mapSet(a, entries, key, new_val);
    }
    return ok(new_val);
}

pub fn map_put_if_absent(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "putIfAbsent")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("putIfAbsent requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("putIfAbsent requires a value");
    const value = ctx.args[2];
    // The present value is borrowed from the map; retain before returning it.
    if (mapFind(entries, key)) |old| return okElem(old);
    try mapSet(a, entries, key, value);
    return ok(Value.Null);
}

pub fn map_replace(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "replace")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("replace requires a key");
    const key = ctx.args[1];
    if (ctx.args.len >= 4) {
        const old = ctx.args[2];
        const new = ctx.args[3];
        if (mapFind(entries, key)) |cur| {
            if (eqBoxed(&cur, &old)) {
                try mapSet(a, entries, key, new);
                return ok(.{ .Bool = true });
            }
        }
        return ok(.{ .Bool = false });
    }
    if (ctx.args.len < 3) return arityErr("replace requires a value");
    const value = ctx.args[2];
    if (mapFind(entries, key)) |old| {
        // `replace` returns the previous value: retain it before `mapSet`
        // releases the map's reference, so the returned result carries an
        // owned ref instead of a freed one.
        if (runtime.reclaimEnabled()) old.retain();
        try mapSet(a, entries, key, value);
        return ok(old);
    }
    return ok(Value.Null);
}

pub fn map_compute_if_absent(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "computeIfAbsent")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("computeIfAbsent requires a key");
    const key = ctx.args[1];
    // The present value is borrowed from the map; the register adopting the
    // result must own its ref, so retain before returning.
    if (mapFind(entries, key)) |v| return okElem(v);
    if (ctx.args.len < 3) return arityErr("computeIfAbsent requires a block");
    const block = ctx.args[2];
    const v = switch (try invoke(ctx, &block, &.{key})) {
        .value => |x| x,
        .err => |e| return e,
    };
    try mapSet(a, entries, key, v);
    return ok(v);
}

pub fn map_compute_if_present(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "computeIfPresent")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("computeIfPresent requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("computeIfPresent requires a block");
    const block = ctx.args[2];
    const old = mapFind(entries, key) orelse return ok(Value.Null);
    const new_val = switch (try invoke(ctx, &block, &.{ key, old })) {
        .value => |x| x,
        .err => |e| return e,
    };
    if (new_val == .Null) {
        mapRemoveKey(entries, key);
    } else {
        try mapSet(a, entries, key, new_val);
    }
    return ok(new_val);
}

pub fn map_compute(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "compute")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("compute requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("compute requires a block");
    const block = ctx.args[2];
    const old = mapFind(entries, key) orelse Value.Null;
    const new_val = switch (try invoke(ctx, &block, &.{ key, old })) {
        .value => |x| x,
        .err => |e| return e,
    };
    if (new_val == .Null) {
        mapRemoveKey(entries, key);
    } else {
        try mapSet(a, entries, key, new_val);
    }
    return ok(new_val);
}

// =====================================================================
// Additional Map ops
// =====================================================================

pub fn coll_map_get_or_default(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.getOrDefault")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("getOrDefault requires (key, default)");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("getOrDefault requires (key, default)");
    const default = ctx.args[2];
    const g = entries.borrowMut();
    defer g.deinit();
    if (try g.get().find(a, &key)) |i| return okElem(g.get().pairs.items[i].value);
    return ok(default);
}

pub fn coll_map_get_value(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.getValue")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("getValue requires a key");
    // Property-delegation form `getValue(thisRef, property)` keys by the
    // property name (`Map<String,V>.getValue` -> getOrImplicitDefault(name));
    // the plain `getValue(key)` form keys by the argument itself.
    const key: Value = if (ctx.args.len >= 3 and ctx.args[2] == .PropertyRef) blk: {
        const g = ctx.args[2].PropertyRef.name.borrow();
        defer g.deinit();
        break :blk .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, g.get().bytes)) };
    } else ctx.args[1];
    {
        const g = entries.borrowMut();
        defer g.deinit();
        if (try g.get().find(a, &key)) |i| return okElem(g.get().pairs.items[i].value);
    }
    const kd = try display(a, key);
    const msg = try fmt(a, "Key {s} is missing in the map.", .{kd});
    const e = try thrown(a, "kotlin.NoSuchElementException", msg);
    if (runtime.freeScratch()) a.free(msg);
    return e;
}

pub fn coll_map_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.toList")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var pairs: std.ArrayList(Value) = .empty;
    {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| {
            kv.key.retain();
            kv.value.retain();
            try pairs.append(a, try makePair(a, kv.key, kv.value));
        }
    }
    return ok(try makeListFromArrayList(a, pairs, false));
}

pub fn coll_map_to_sorted_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toSortedMap requires a Map receiver");
    const entries = try snapshotEntries(a, ctx.args[0].Map.entries);
    var descending = false;
    if (ctx.args.len > 1) {
        const cmp = ctx.args[1];
        if (cmp == .Comparator) {
            const sg = cmp.Comparator.steps.borrow();
            defer sg.deinit();
            if (sg.get().*.len == 0) {
                descending = cmp.Comparator.descending;
            } else {
                return typeErr("toSortedMap with a selector comparator is not yet supported");
            }
        } else {
            return typeErr("toSortedMap expects a Comparator argument");
        }
    }
    if (try sortMapByKey(a, entries, descending)) |e| return e;
    return ok(try makeMap(a, entries, false));
}

pub fn coll_map_count_no_pred(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len >= 2) {
        const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "count")) {
            .items => |x| x,
            .err => |e| return e,
        };
        defer if (runtime.freeScratch()) a.free(items);
        const block = ctx.args[1];
        var n: i64 = 0;
        for (items) |v| {
            const r = switch (try invoke(ctx, &block, &.{v})) {
                .value => |x| x,
                .err => |e| return e,
            };
            if (r == .Bool and r.Bool) n += 1;
        }
        return ok(Value.newInt(n));
    }
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.count")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(mapLen(entries))));
}

pub fn coll_mut_map_put_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "MutableMap.putAll")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    if (ctx.args.len < 2) return arityErr("putAll requires a Map");
    const arg = ctx.args[1];
    var to_add: []MapPair = undefined;
    switch (arg) {
        .Pair => |p| {
            const one = try a.alloc(MapPair, 1);
            one[0] = .{ .key = p.first.asPtr().*, .value = p.second.asPtr().* };
            to_add = one;
        },
        .Map => |m| to_add = try snapshotEntries(a, m.entries),
        .Array => |arr| to_add = (switch (try pairsFromValues(a, try arr.snapshot(a), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .List => |l| to_add = (switch (try pairsFromValues(a, try snapshotItems(a, l.items), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .Set => |s| to_add = (switch (try pairsFromValues(a, try snapshotItems(a, s.items), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .Sequence => {
            const items = switch (try materialiseSequence(a, ctx.host, ctx.out, arg)) {
                .items => |x| x,
                .err => |e| return .{ .err = e },
            };
            to_add = (switch (try pairsFromValues(a, items, "putAll")) {
                .entries => |x| x,
                .err => |e| return e,
            }).items;
        },
        // An Instance is either a user `Map` (drain its `entries`) or an
        // `Iterable<Pair>` (e.g. an `asIterable()` view — drain it and read each
        // Pair). `MutableMap.putAll(pairs: Iterable<Pair>)` reaches here with the
        // latter, which has no `entries` property.
        .Instance => {
            const is_map = blk: {
                const er = (try ctx.host.getProperty(&arg, "entries", ctx.out)) orelse break :blk false;
                break :blk er == .ok;
            };
            if (is_map) {
                to_add = switch (try userMapPairs(ctx, arg, "putAll")) {
                    .entries => |x| x,
                    .err => |e| return e,
                };
            } else {
                const its = switch (try iterableItemsCtx(ctx, arg, "putAll")) {
                    .items => |x| x,
                    .err => |e| return e,
                };
                to_add = (switch (try pairsFromValues(ctx.allocator, its, "putAll")) {
                    .entries => |x| x,
                    .err => |e| return e,
                }).items;
            }
        },
        else => return typeErr("putAll requires a Map or a collection of Pairs"),
    }
    const g = entries.borrowMut();
    defer g.deinit();
    // `to_add` entries are borrowed (snapshotEntries of the source map, or
    // Pair-component reads); the destination owns one ref per key+value.
    for (to_add) |kv| {
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
    return ok(Value.Unit);
}

pub fn coll_mut_map_set(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const r = try coll_mut_map_put(ctx);
    if (r == .err) return r;
    return ok(Value.Unit);
}
