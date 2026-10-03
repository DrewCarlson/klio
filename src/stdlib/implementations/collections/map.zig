//! `Map` intrinsics: scope helpers, map algebra, access, views and mutation.

const std = @import("std");
const hashing = @import("hashing.zig");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const MapPair = runtime.MapPair;
const MapStore = runtime.MapStore;
const CollBackingRef = runtime.CollBackingRef;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const builders_mod = @import("builders.zig");
const sortMapByKey = builders_mod.sortMapByKey;

const common_mod = @import("common.zig");
const views_mod = @import("views.zig");
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
const makeMapBorrowed = common_mod.makeMapBorrowed;
const copyMap = common_mod.copyMap;
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

const sequence_mod = @import("sequence.zig");
const materialiseSequence = sequence_mod.materialiseSequence;

pub fn map_get_or_else(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 3) return arityErr("getOrElse expects (receiver, key, block)");
    if (ctx.args[0] != .Map) return typeErr("getOrElse requires a Map receiver");
    const key = ctx.args[1];
    {
        const g = ctx.args[0].Map.entries.borrowMut();
        defer g.deinit();
        // `getOrElse` is `get(key) ?: defaultValue()`: a present-but-null value
        // falls through to the default like an absent key.
        if (try g.get().find(a, &key)) |i| {
            const v = g.get().slots.items[i].value;
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
        // `getOrPut` returns a stored value only when non-null; a present-but-null
        // value is recomputed and stored.
        if (try g.get().find(a, &key)) |i| {
            const v = g.get().slots.items[i].value;
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
        // The map takes one ref to the stored value; the block's owned ref is
        // handed back untouched.
        if (runtime.reclaimEnabled()) new_v.retain();
        if (try g.get().find(a, &key)) |i| {
            const old = g.get().slots.items[i].value;
            g.get().slots.items[i].value = new_v;
            if (runtime.reclaimEnabled()) old.release(a);
        } else {
            if (runtime.reclaimEnabled()) key.retain();
            try g.get().append(a, .{ .key = key, .value = new_v });
        }
    }
    return ok(new_v);
}

pub fn coll_map_to_mutable_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toMutableMap requires a Map receiver");
    return ok(try copyMap(a, ctx.args[0].Map.entries, true));
}
pub fn coll_map_to_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toMap requires a Map receiver");
    // `toMap(destination)` merges into the supplied map and returns it, live.
    if (ctx.args.len >= 2 and ctx.args[1] == .Map) {
        const dest = ctx.args[1];
        const _mb = mapEntriesLen(dest.Map.entries);
        defer mapStructuralBump(dest.Map.entries, _mb);
        const r = try putAllOf(ctx, dest.Map.entries, ctx.args[0].Map.entries);
        if (r == .err) return r;
        return ok(dest);
    }
    return ok(try copyMap(a, ctx.args[0].Map.entries, false));
}

/// `Map.plus`, as `LinkedHashMap(this).apply { put(..) }`: one copy of the map, the pair or
/// pairs put into it through their keys' `hashCode()` and `equals`.
pub fn coll_map_plus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.plus")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    const out = try copyMap(a, entries, false);
    const dest = out.Map.entries;
    const mark = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(mark);
    runtime.keepalivePush(out);
    const items: []const Value = switch (arg) {
        .Pair => |p| {
            switch (try putEntry(ctx, dest, p.first.asPtrConst().*, p.second.asPtrConst().*)) {
                .prev => |old| if (old) |o| if (runtime.reclaimEnabled()) o.release(a),
                .thrown => |e| return e,
            }
            return ok(out);
        },
        .Map => |m| {
            const r = try putAllOf(ctx, dest, m.entries);
            return if (r == .err) r else ok(out);
        },
        .List, .Set, .Array, .Sequence, .Range => switch (try iterableItemsCtx(ctx, arg, "Map.plus")) {
            .items => |x| x,
            .err => |e| return e,
        },
        else => return typeErr("Map.plus expects a Pair, Map, or Iterable<Pair>"),
    };
    runtime.keepalivePushSlice(items);
    for (items) |p| {
        if (p != .Pair) continue;
        switch (try putEntry(ctx, dest, p.Pair.first.asPtrConst().*, p.Pair.second.asPtrConst().*)) {
            .prev => |old| if (old) |o| if (runtime.reclaimEnabled()) o.release(a),
            .thrown => |e| return e,
        }
    }
    return ok(out);
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
        .Set => |s| try appendVL(&keys, a, s.dense()),
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
    var gone = hashing.Seen.init();
    defer gone.deinit(a);
    for (keys.items) |k| _ = try gone.add(null, undefined, a, k);
    // As `toMutableMap().apply { minusAssign(keys) }`: one copy, of the entries kept.
    var out: std.ArrayList(MapPair) = .empty;
    {
        const g = entries.borrow();
        defer g.deinit();
        var it = g.get().live();
        while (it.next()) |kv| switch (try gone.find(null, undefined, a, kv.key)) {
            .none => try out.append(a, kv.*),
            .at, .thrown => {},
        };
    }
    return ok(try makeMapBorrowed(a, out, false));
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

/// Where a key is among a map's entries. A miss carries the key's hash when
/// the lookup took it, for the entry a put appends.
pub const Lookup = union(enum) {
    at: usize,
    none: ?u64,
    thrown: EvalResult,
};

const KeyHash = union(enum) {
    hash: u64,
    none,
    thrown: EvalResult,
};

/// A key's hash for a map's index: `keyHash` for a simple key, the
/// `hashCode()` Kotlin answers for a host-keyed one (an instance's own, a
/// callable reference's); none for a key neither hashes.
fn hostKeyHash(ctx: *CallCtx, key: *const Value) Error!KeyHash {
    if (MapStore.keyHash(key)) |h| return .{ .hash = h };
    if (!key.hostKeyed()) return .none;
    return switch (try hashing.kotlinHashCode(ctx.host, ctx.out, key)) {
        .code => |c| .{ .hash = @as(u64, @as(u32, @bitCast(c))) *% 0x9E3779B97F4A7C15 },
        .none => .none,
        .thrown => |e| .{ .thrown = e },
    };
}

const Eq = union(enum) {
    yes,
    no,
    thrown: EvalResult,
};

/// Whether stored key `k` equals host-keyed `key`, by `k.equals(key)` as the
/// map's lookup asks it.
fn instanceKeyEq(ctx: *CallCtx, k: *const Value, key: *const Value) Error!Eq {
    if (k.* != .Instance) return if (try common_mod.eqBoxedH(ctx.host, ctx.out, k, key)) .yes else .no;
    if (ctx.host.identityKey(k) != null) return if (key.* == .Instance and runtime.ObjRef(runtime.InstanceData).ptrEq(k.Instance, key.Instance)) .yes else .no;
    if (try ctx.host.callWellKnown(k, .equals, &.{key.*}, ctx.out)) |m| switch (m) {
        .ok => |v| if (v == .Bool) return if (v.Bool) .yes else .no,
        .err => return .{ .thrown = m },
    };
    return if (eqBoxed(k, key)) .yes else .no;
}

/// The entry of `key`: a host-keyed key (an instance, a callable reference,
/// a pair holding one) through its `hashCode()` and `equals`, as a `HashMap`
/// finds it, any other by value.
pub fn mapKeyIndex(ctx: *CallCtx, entries: MapEntries, key: Value) Error!Lookup {
    if (!key.hostKeyed()) {
        const g = entries.borrowMut();
        defer g.deinit();
        if (try g.get().find(ctx.allocator, &key)) |i| return .{ .at = i };
        // A map below the index's size keeps no hashes.
        const small = g.get().slots.items.len + 1 < MapStore.index_threshold;
        return .{ .none = if (small) null else MapStore.keyHash(&key) };
    }
    const indexed = blk: {
        const g = entries.borrow();
        defer g.deinit();
        break :blk g.get().slots.items.len >= MapStore.index_threshold and !g.get().unhashable;
    };
    if (!indexed) return instanceKeyScan(ctx, entries, &key, 0, null);
    switch (try hashEntries(ctx, entries)) {
        .done => {},
        .unhashable => return instanceKeyScan(ctx, entries, &key, 0, null),
        .thrown => |e| return .{ .thrown = e },
    }
    const h = switch (try hostKeyHash(ctx, &key)) {
        .hash => |x| x,
        .none => return instanceKeyScan(ctx, entries, &key, 0, null),
        .thrown => |e| return .{ .thrown = e },
    };
    // A bucket holds a few candidates: kept on the stack.
    var sfa = std.heap.stackFallback(512, ctx.allocator);
    const a = sfa.get();
    var at: std.ArrayList(u32) = .empty;
    defer at.deinit(a);
    var keys: std.ArrayList(Value) = .empty;
    defer keys.deinit(a);
    // Dispatching `equals` re-enters the VM, which must not happen under
    // the borrow: the candidates' keys are copied out first.
    const hashed = blk: {
        const g = entries.borrowMut();
        defer g.deinit();
        try g.get().bucketOf(ctx.allocator, h, &at, a);
        for (at.items) |i| try keys.append(a, g.get().slots.items[i].key);
        break :blk g.get().hashedLen();
    };
    for (at.items, keys.items) |i, *k| switch (try instanceKeyEq(ctx, k, &key)) {
        .yes => return .{ .at = i },
        .no => {},
        .thrown => |e| return .{ .thrown = e },
    };
    // Entries a `hashCode` added while the key was hashed.
    return instanceKeyScan(ctx, entries, &key, hashed, h);
}

const Put = union(enum) {
    prev: ?Value,
    thrown: EvalResult,
};

/// Puts `value` at `key` as `MutableMap.put` does: over the entry
/// `mapKeyIndex` finds, else as a new last entry. The map takes a reference
/// to what it keeps; the replaced value's moves to the caller.
pub fn putEntry(ctx: *CallCtx, entries: MapEntries, key: Value, value: Value) Error!Put {
    const found = try mapKeyIndex(ctx, entries, key);
    const g = entries.borrowMut();
    defer g.deinit();
    const h = switch (found) {
        .at => |i| if (i < g.get().slots.items.len and !g.get().isHole(i)) {
            if (runtime.reclaimEnabled()) value.retain();
            const prev = g.get().slots.items[i].value;
            g.get().slots.items[i].value = value;
            return .{ .prev = prev };
        } else null,
        .none => |h| h,
        .thrown => |e| return .{ .thrown = e },
    };
    if (runtime.reclaimEnabled()) {
        key.retain();
        value.retain();
    }
    try g.get().appendHashed(ctx.allocator, .{ .key = key, .value = value }, h);
    return .{ .prev = null };
}

/// The entry of instance `key` among the slots from `from` on, by `equals`.
fn instanceKeyScan(ctx: *CallCtx, entries: MapEntries, key: *const Value, from: usize, h: ?u64) Error!Lookup {
    var slots: std.ArrayList(u32) = .empty;
    defer if (runtime.freeScratch()) slots.deinit(ctx.allocator);
    const keys = blk: {
        const g = entries.borrow();
        defer g.deinit();
        const st = g.get();
        var ks: std.ArrayList(Value) = .empty;
        var i = from;
        while (i < st.slots.items.len) : (i += 1) {
            if (st.isHole(i)) continue;
            try ks.append(ctx.allocator, st.slots.items[i].key);
            try slots.append(ctx.allocator, @intCast(i));
        }
        break :blk ks;
    };
    defer if (runtime.freeScratch()) {
        var ks = keys;
        ks.deinit(ctx.allocator);
    };
    for (keys.items, slots.items) |*k, i| switch (try instanceKeyEq(ctx, k, key)) {
        .yes => return .{ .at = i },
        .no => {},
        .thrown => |e| return .{ .thrown = e },
    };
    return .{ .none = h };
}

const Hashing = union(enum) {
    done,
    unhashable,
    thrown: EvalResult,
};

/// Hashes the entries the index lacks, instance keys through their own
/// `hashCode()`, outside the borrow; again if a `hashCode` changed the map.
fn hashEntries(ctx: *CallCtx, entries: MapEntries) Error!Hashing {
    const a = ctx.allocator;
    var hs: std.ArrayList(u64) = .empty;
    defer hs.deinit(a);
    var tries: usize = 0;
    while (tries < 4) : (tries += 1) {
        var from: usize = 0;
        const keys = blk: {
            const g = entries.borrow();
            defer g.deinit();
            from = g.get().hashedLen();
            // No hole is past the hashes.
            const pairs = g.get().slots.items;
            if (from >= pairs.len) return .done;
            var ks = try a.alloc(Value, pairs.len - from);
            for (pairs[from..], 0..) |kv, i| ks[i] = kv.key;
            break :blk ks;
        };
        defer if (runtime.freeScratch()) a.free(keys);
        hs.clearRetainingCapacity();
        for (keys) |*k| switch (try hostKeyHash(ctx, k)) {
            .hash => |x| try hs.append(a, x),
            .none => {
                const g = entries.borrowMut();
                defer g.deinit();
                g.get().unhashable = true;
                return .unhashable;
            },
            .thrown => |e| return .{ .thrown = e },
        };
        const g = entries.borrowMut();
        defer g.deinit();
        if (try g.get().addHashes(a, from, hs.items)) continue;
    }
    return .unhashable;
}

pub fn coll_map_get(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.get")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("get requires a key");
    const key = ctx.args[1];
    switch (try mapKeyIndex(ctx, entries, key)) {
        .at => |i| {
            const g = entries.borrow();
            defer g.deinit();
            if (i < g.get().slots.items.len and !g.get().isHole(i)) return okElem(g.get().slots.items[i].value);
        },
        .none => {},
        .thrown => |e| return e,
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
    return switch (try mapKeyIndex(ctx, entries, key)) {
        .at => ok(.{ .Bool = true }),
        .none => ok(.{ .Bool = false }),
        .thrown => |e| e,
    };
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
    var it = g.get().live();
    while (it.next()) |kv| {
        if (eqBoxed(&kv.value, &value)) return ok(.{ .Bool = true });
    }
    return ok(.{ .Bool = false });
}

pub fn coll_map_keys(ctx: *CallCtx) Error!EvalResult {
    return mapView(ctx, .Keys, "Map.keys");
}
pub fn coll_map_values(ctx: *CallCtx) Error!EvalResult {
    return mapView(ctx, .Values, "Map.values");
}
pub fn coll_map_entries(ctx: *CallCtx) Error!EvalResult {
    return mapView(ctx, .Entries, "Map.entries");
}

/// The map's view of `kind`, an instance of the class `MapViews.kt` declares for it, which
/// reads the map through its lookups and walks it in place: made on first use and kept on
/// the map, as the JVM's and Kotlin/Native's maps keep theirs.
fn mapView(ctx: *CallCtx, kind: runtime.MapViewKind, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr(try fmt(a, "{s} requires a Map receiver", .{what}));
    const m = ctx.args[0].Map;
    if (m.views[@intFromEnum(kind)]) |v| {
        v.retain();
        return ok(v);
    }
    const class: runtime.WellKnownClass = switch (kind) {
        .Keys => .hash_map_keys,
        .Values => .hash_map_values,
        .Entries => .hash_map_entry_set,
    };
    const made = (try ctx.host.constructWellKnown(class, ctx.args[0..1], ctx.out)) orelse
        return typeErr(try fmt(a, "{s}: no {s} class", .{ what, class.fqn() }));
    const v = switch (made) {
        .ok => |x| x,
        else => return made,
    };
    m.setView(kind, v);
    v.retain();
    return ok(v);
}

/// `__klio_mapIterator(map, kind)` (`MapViews.kt`): an iterator over the map's keys, values
/// or entries that walks the map itself.
pub fn map_view_iterator(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len != 2 or ctx.args[0] != .Map or ctx.args[1] != .Int) return typeErr("__klio_mapIterator expects a Map and a kind");
    const kind: runtime.MapViewKind = switch (ctx.args[1].Int) {
        0 => .Keys,
        1 => .Values,
        2 => .Entries,
        else => return typeErr("__klio_mapIterator: no such kind"),
    };
    const m = ctx.args[0].Map;
    return ok(try views_mod.mapIterator(ctx.allocator, m.entries, kind, m.mutable));
}

/// `__klio_mapCheckMutable(map)` (`MapViews.kt`): `UnsupportedOperationException` for a map
/// that may not change, before a view's bulk removal reads any element.
pub fn map_check_mutable(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    return ok(Value.Unit);
}

/// `__klio_mapRemoveKey(map, key)` (`MapViews.kt`): removes the key, answering whether the
/// map held it, whatever its value.
pub fn map_remove_key(ctx: *CallCtx) Error!EvalResult {
    return switch (try removeKey(ctx, "MutableMap.keys.remove")) {
        .pair => |kv| {
            if (runtime.reclaimEnabled()) {
                kv.key.release(ctx.allocator);
                kv.value.release(ctx.allocator);
            }
            return ok(.{ .Bool = true });
        },
        .absent => ok(.{ .Bool = false }),
        .err => |e| e,
    };
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
    // The replaced value's ownership transfers to the returned `prev`.
    return switch (try putEntry(ctx, entries, key, value)) {
        .prev => |p| ok(p orelse Value.Null),
        .thrown => |e| e,
    };
}
pub fn coll_mut_map_remove(ctx: *CallCtx) Error!EvalResult {
    return switch (try removeKey(ctx, "MutableMap.remove")) {
        // The value's owned ref moves to the result; the removed key must be released.
        .pair => |kv| {
            if (runtime.reclaimEnabled()) kv.key.release(ctx.allocator);
            return ok(kv.value);
        },
        .absent => ok(Value.Null),
        .err => |e| e,
    };
}

const Removed = union(enum) { pair: MapPair, absent, err: EvalResult };

/// Takes key `ctx.args[1]` out of map `ctx.args[0]`: the pair the map held for it, owned by
/// the caller, or `absent`.
fn removeKey(ctx: *CallCtx, what: []const u8) Error!Removed {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return .{ .err = e };
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, what)) {
        .entries => |x| x,
        .err => |e| return .{ .err = e },
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    if (ctx.args.len < 2) return .{ .err = arityErr("remove requires a key") };
    const pos = switch (try mapKeyIndex(ctx, entries, ctx.args[1])) {
        .at => |i| i,
        .none => return .absent,
        .thrown => |e| return .{ .err = e },
    };
    const g = entries.borrowMut();
    defer g.deinit();
    if (pos >= g.get().slots.items.len or g.get().isHole(pos)) return .absent;
    const kv = g.get().removeAt(pos);
    g.get().compactIfSparse();
    return .{ .pair = kv };
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
    g.get().clear();
    return ok(Value.Unit);
}


fn mutMapEntriesRc(a: Allocator, recv: Value, who: []const u8) Error!MapEntriesOutcome {
    if (recv == .Map) return .{ .entries = recv.Map.entries };
    return .{ .err = typeErr(try fmt(a, "{s} requires a MutableMap receiver", .{who})) };
}

fn mapFind(entries: MapEntries, key: Value) ?Value {
    const g = entries.borrow();
    defer g.deinit();
    var it = g.get().live();
    while (it.next()) |kv| {
        if (eqBoxed(&kv.key, &key)) return kv.value;
    }
    return null;
}

fn mapSet(a: Allocator, entries: MapEntries, key: Value, value: Value) Error!void {
    const g = entries.borrowMut();
    defer g.deinit();
    var it = g.get().live();
    while (it.next()) |kv| {
        if (eqBoxed(&kv.key, &key)) {
            if (runtime.reclaimEnabled()) {
                value.retain();
                kv.value.release(a);
            }
            kv.value = value;
            return;
        }
    }
    if (runtime.reclaimEnabled()) {
        key.retain();
        value.retain();
    }
    try g.get().append(a, .{ .key = key, .value = value });
}

fn mapRemoveKey(entries: MapEntries, key: Value) void {
    const g = entries.borrowMut();
    defer g.deinit();
    var it = g.get().live();
    while (it.nextSlot()) |i| {
        if (eqBoxed(&g.get().slots.items[i].key, &key)) {
            _ = g.get().removeAt(i);
            g.get().compactIfSparse();
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
    if (try g.get().find(a, &key)) |i| return okElem(g.get().slots.items[i].value);
    return ok(default);
}

pub fn coll_map_get_value(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.getValue")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("getValue requires a key");
    // The property-delegation form `getValue(thisRef, property)` keys by the
    // property name, while plain `getValue(key)` keys by the argument.
    const key: Value = if (ctx.args.len >= 3 and ctx.args[2] == .PropertyRef) blk: {
        const g = ctx.args[2].PropertyRef.name.borrow();
        defer g.deinit();
        break :blk .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, g.get().bytes)) };
    } else ctx.args[1];
    {
        const g = entries.borrowMut();
        defer g.deinit();
        if (try g.get().find(a, &key)) |i| return okElem(g.get().slots.items[i].value);
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
        var it = g.get().live();
        while (it.next()) |kv| {
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
    // The sorted entries are the new map's: its keys are the map's, each once.
    return ok(try makeMapBorrowed(a, .fromOwnedSlice(entries), false));
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

/// Puts the entries of a user `Map`, `inst`, into map `entries`, as `HashMap.putMapEntries`
/// does: its `size` first, then, unless it is empty, each entry of its `entries` as their
/// iterator gives it. Null for an instance that is not a `Map`.
pub fn putUserMap(ctx: *CallCtx, entries: MapEntries, inst: Value, who: []const u8) Error!?EvalResult {
    const a = ctx.allocator;
    const n = (try ctx.host.callWellKnown(&inst, .map_size, &.{}, ctx.out)) orelse return null;
    switch (n) {
        .ok => |v| if (v == .Int and v.Int == 0) return ok(Value.Unit),
        .err => |e| return .{ .err = e },
    }
    const user_entries = switch ((try ctx.host.callWellKnown(&inst, .entries, &.{}, ctx.out)) orelse
        return typeErr(try fmt(a, "{s}: a map has no entries", .{who}))) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return try putEntriesOf(ctx, entries, user_entries, who);
}

/// Puts each entry of a user map's `entries` (`user_entries`) into map `entries` as its
/// iterator gives it, as `HashMap.putMapEntries` walks the source's `entrySet()`: an entry
/// may be a `Map.Entry` instance, a host entry or a `Pair`.
fn putEntriesOf(ctx: *CallCtx, entries: MapEntries, user_entries: Value, who: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    const mark = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(mark);
    runtime.keepalivePush(user_entries);
    const iter = switch ((try ctx.host.callWellKnown(&user_entries, .iterator, &.{}, ctx.out)) orelse
        return typeErr(try fmt(a, "{s}: a map's entries have no iterator", .{who}))) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    runtime.keepalivePush(iter);
    const step = runtime.keepaliveMark();
    while (true) {
        runtime.keepaliveRestore(step);
        const more = switch ((try ctx.host.callWellKnown(&iter, .has_next, &.{}, ctx.out)) orelse
            return typeErr(try fmt(a, "{s}: an iterator has no hasNext()", .{who}))) {
            .ok => |v| v == .Bool and v.Bool,
            .err => |e| return .{ .err = e },
        };
        if (!more) return ok(Value.Unit);
        const entry = switch ((try ctx.host.callWellKnown(&iter, .next, &.{}, ctx.out)) orelse
            return typeErr(try fmt(a, "{s}: an iterator has no next()", .{who}))) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        runtime.keepalivePush(entry);
        const key: Value, const val: Value = switch (entry) {
            .MapEntry => |me| .{ me.key, me.getValue() },
            .Pair => |p| .{ p.first.asPtrConst().*, p.second.asPtrConst().* },
            else => blk: {
                const k = switch ((try ctx.host.callWellKnown(&entry, .entry_key, &.{}, ctx.out)) orelse
                    return typeErr(try fmt(a, "{s}: an entry has no key", .{who}))) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = e },
                };
                runtime.keepalivePush(k);
                const v = switch ((try ctx.host.callWellKnown(&entry, .entry_value, &.{}, ctx.out)) orelse
                    return typeErr(try fmt(a, "{s}: an entry has no value", .{who}))) {
                    .ok => |x| x,
                    .err => |e| return .{ .err = e },
                };
                break :blk .{ k, v };
            },
        };
        runtime.keepalivePush(val);
        switch (try putEntry(ctx, entries, key, val)) {
            .prev => |p| if (p) |old| if (runtime.reclaimEnabled()) old.release(a),
            .thrown => |e| return e,
        }
    }
}

/// Puts every entry of map `src` into map `entries`, as `HashMap.putMapEntries` does: the
/// source's entries where they stand, each put through the keys' `hashCode()` and `equals`.
fn putAllOf(ctx: *CallCtx, entries: MapEntries, src: MapEntries) Error!EvalResult {
    const a = ctx.allocator;
    var walk = runtime.MapWalk.init(src);
    const mark = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(mark);
    while (true) {
        var one = [1]MapPair{switch (walk.next()) {
            .pair => |p| p,
            .end => return ok(Value.Unit),
            .changed => return try thrown(a, "kotlin.ConcurrentModificationException", null),
        }};
        runtime.keepaliveRestore(mark);
        runtime.keepalivePushPairs(&one);
        switch (try putEntry(ctx, entries, one[0].key, one[0].value)) {
            .prev => |p| if (p) |old| if (runtime.reclaimEnabled()) old.release(a),
            .thrown => |e| return e,
        }
    }
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
            one[0] = .{ .key = p.first.asPtrConst().*, .value = p.second.asPtrConst().* };
            to_add = one;
        },
        .Map => |m| return putAllOf(ctx, entries, m.entries),
        .Array => |arr| to_add = (switch (try pairsFromValues(a, try arr.snapshot(a), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .List => |l| to_add = (switch (try pairsFromValues(a, try snapshotItems(a, l.items), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .Set => |s| to_add = (switch (try pairsFromValues(a, try snapshotItems(a, s.dense()), "putAll")) {
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
        // An Instance is either a user `Map`, walked through `entries`, or an
        // `Iterable<Pair>` with no `entries` property, which is what
        // `MutableMap.putAll(pairs: Iterable<Pair>)` passes.
        .Instance => {
            if (try putUserMap(ctx, entries, arg, "putAll")) |r| return r;
            const its = switch (try iterableItemsCtx(ctx, arg, "putAll")) {
                .items => |x| x,
                .err => |e| return e,
            };
            to_add = (switch (try pairsFromValues(ctx.allocator, its, "putAll")) {
                .entries => |x| x,
                .err => |e| return e,
            }).items;
        },
        else => return typeErr("putAll requires a Map or a collection of Pairs"),
    }
    // `to_add` entries are borrowed, so the destination retains each.
    for (to_add) |kv| switch (try putEntry(ctx, entries, kv.key, kv.value)) {
        .prev => |p| if (p) |old| if (runtime.reclaimEnabled()) old.release(a),
        .thrown => |e| return e,
    };
    return ok(Value.Unit);
}

pub fn coll_mut_map_set(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const r = try coll_mut_map_put(ctx);
    if (r == .err) return r;
    return ok(Value.Unit);
}
