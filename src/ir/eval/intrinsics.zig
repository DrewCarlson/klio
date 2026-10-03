//! Host functions of a few instructions: an instance's identity hash, a
//! Long's hash, an array's length, a list's size, its element at an index
//! and a store there, an Int's or a Long's rotations and its count of one
//! bits, which compiled code compiles as its instructions (`baseline.zig`);
//! and a map's lookup, store and size, a list's append, a builder's append
//! of a string or a number and its length, which compiled code calls here
//! straight; a host iterator's `hasNext()` and `next()`; and a map entry's
//! `key` and `value`. The
//! interpreter runs every one in place of the host call (`run`); both leave
//! anything they do not take to the host function.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Value = runtime.Value;

pub const Intrinsic = union(enum) {
    none,
    any_hash,
    long_hash,
    /// The array's kind bits: 0 for `Array<T>`, a primitive kind's plus one.
    array_size: u8,
    list_size,
    list_get,
    list_set,
    list_add,
    rotate_left,
    rotate_right,
    count_one_bits,
    map_get,
    /// `put`, answering the value it replaced.
    map_put,
    /// `set`, the operator: `put`, answering `Unit`.
    map_set,
    map_size,
    sb_append,
    sb_length,
    iter_has_next,
    /// `next()`, and a primitive iterator's `nextInt()` and kin.
    iter_next,
    entry_key,
    entry_value,

    /// The arguments the call passes, its receiver first.
    pub fn arity(k: Intrinsic) u32 {
        return switch (k) {
            .list_get, .list_add, .rotate_left, .rotate_right, .map_get, .sb_append => 2,
            .list_set, .map_put, .map_set => 3,
            else => 1,
        };
    }

    /// Whether compiled code compiles it as instructions.
    pub fn compiled(k: Intrinsic) bool {
        return switch (k) {
            .none, .map_get, .map_put, .map_set, .map_size, .list_add, .sb_append, .sb_length, .iter_has_next, .iter_next, .entry_key, .entry_value => false,
            else => true,
        };
    }

    /// Whether compiled code calls its body here (`run`) straight, in place of the
    /// host function's handler.
    pub fn called(k: Intrinsic) bool {
        return switch (k) {
            .map_get, .map_put, .map_set, .map_size, .list_add, .sb_append, .sb_length, .iter_has_next, .iter_next, .entry_key, .entry_value => true,
            else => false,
        };
    }

    /// Whether a call of `k` with `n` arguments from register `lo` writing `dst` compiles
    /// as it: a store reads its element after it writes the old one to `dst`.
    pub fn fits(k: Intrinsic, lo: u32, n: u32, dst: u32) bool {
        if (k == .none or n < k.arity()) return false;
        // A called body reads exactly its arguments: `append(s, start, end)` is not `append(s)`.
        if (k.called() and n != k.arity()) return false;
        return k != .list_set or dst < lo or dst >= lo + n;
    }

    /// One byte for a native's cache (`NativeRt.intrinsic`), never 0.
    fn encode(k: Intrinsic) u8 {
        return switch (k) {
            .array_size => |bits| 32 + bits,
            else => @as(u8, @intFromEnum(k)) + 1,
        };
    }

    fn decode(b: u8) Intrinsic {
        if (b >= 32) return .{ .array_size = b - 32 };
        return switch (@as(std.meta.Tag(Intrinsic), @enumFromInt(b - 1))) {
            .none => .none,
            .any_hash => .any_hash,
            .long_hash => .long_hash,
            .array_size => unreachable,
            .list_size => .list_size,
            .list_get => .list_get,
            .list_set => .list_set,
            .list_add => .list_add,
            .rotate_left => .rotate_left,
            .rotate_right => .rotate_right,
            .count_one_bits => .count_one_bits,
            .map_get => .map_get,
            .map_put => .map_put,
            .map_set => .map_set,
            .map_size => .map_size,
            .sb_append => .sb_append,
            .sb_length => .sb_length,
            .iter_has_next => .iter_has_next,
            .iter_next => .iter_next,
            .entry_key => .entry_key,
            .entry_value => .entry_value,
        };
    }
};

/// What host function `nid` is, if it is one `Intrinsic` names.
pub fn of(module: *const ir.Module, nid: ir.NativeId) Intrinsic {
    const r = module.resolved orelse return .none;
    if (nid == .none or nid.int() >= r.natives.len) return .none;
    const name = r.natives[nid.int()].name;
    if (std.mem.eql(u8, name, "kotlin.Any.hashCode")) return .any_hash;
    if (std.mem.eql(u8, name, "kotlin.Long.hashCode")) return .long_hash;
    if (std.mem.eql(u8, name, "kotlin.Array.size")) return .{ .array_size = 0 };
    inline for (.{ "ArrayList", "MutableList", "List" }) |cls| {
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".size")) return .list_size;
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".get")) return .list_get;
    }
    if (std.mem.eql(u8, name, "kotlin.collections.ArrayList.set") or std.mem.eql(u8, name, "kotlin.collections.MutableList.set")) return .list_set;
    if (std.mem.eql(u8, name, "kotlin.collections.ArrayList.add") or std.mem.eql(u8, name, "kotlin.collections.MutableList.add")) return .list_add;
    if (std.mem.eql(u8, name, "kotlin.rotateLeft")) return .rotate_left;
    if (std.mem.eql(u8, name, "kotlin.rotateRight")) return .rotate_right;
    if (std.mem.eql(u8, name, "kotlin.countOneBits")) return .count_one_bits;
    inline for (.{ "HashMap", "LinkedHashMap", "MutableMap", "Map" }) |cls| {
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".get")) return .map_get;
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".size")) return .map_size;
    }
    inline for (.{ "HashMap", "LinkedHashMap", "MutableMap" }) |cls| {
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".put")) return .map_put;
    }
    if (std.mem.eql(u8, name, "kotlin.collections.MutableMap.set")) return .map_set;
    if (std.mem.eql(u8, name, "kotlin.text.StringBuilder.append")) return .sb_append;
    if (std.mem.eql(u8, name, "kotlin.text.StringBuilder.length")) return .sb_length;
    inline for (.{ "Iterator", "ListIterator", "MutableListIterator" }) |cls| {
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".hasNext")) return .iter_has_next;
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".next")) return .iter_next;
    }
    inline for (.{ "Map.Entry", "MutableMap.MutableEntry" }) |cls| {
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".key")) return .entry_key;
        if (std.mem.eql(u8, name, "kotlin.collections." ++ cls ++ ".value")) return .entry_value;
    }
    inline for (.{ "Byte", "Char", "Short", "Int", "Long", "Float", "Double", "Boolean" }) |p| {
        if (std.mem.eql(u8, name, "kotlin.collections." ++ p ++ "Iterator.next" ++ p)) return .iter_next;
    }
    const Kind = runtime.PrimitiveArrayKind;
    inline for (.{ Kind.Int, Kind.Long, Kind.Double, Kind.Float, Kind.Short, Kind.Byte, Kind.Boolean, Kind.Char }) |k| {
        if (std.mem.eql(u8, name, "kotlin." ++ @tagName(k) ++ "Array.size")) return .{ .array_size = @intFromEnum(k) + 1 };
    }
    return .none;
}

/// `of`, kept on the native after the first ask.
pub fn cached(module: *const ir.Module, nid: ir.NativeId) Intrinsic {
    const r = module.resolved orelse return .none;
    if (nid == .none or nid.int() >= r.natives.len) return .none;
    const slot = &@constCast(&r.natives[nid.int()]).intrinsic;
    const b = slot.load(.monotonic);
    if (b != 0) return Intrinsic.decode(b);
    const k = of(module, nid);
    slot.store(k.encode(), .monotonic);
    return k;
}

/// `k` over the call's arguments as its host function answers it, written to `out`; false
/// when the host function must run: another receiver, an index out of range, a list that is
/// a view or cannot change, a key that is an instance, a builder append of anything but a
/// string or a number. Only for the tracing collector, where a value is copied without
/// counting. The answer goes through `out` rather than an optional result, which a declined
/// call would build in memory and read back.
pub fn run(k: Intrinsic, a: std.mem.Allocator, module: *const ir.Module, args: []const Value, out: *Value) bool {
    out.* = answer(k, a, module, args) orelse return false;
    return true;
}

/// `run`'s answer, or null where the host function must run.
inline fn answer(k: Intrinsic, a: std.mem.Allocator, module: *const ir.Module, args: []const Value) ?Value {
    if (args.len < k.arity()) return null;
    const recv = args[0];
    switch (k) {
        .none => return null,
        .any_hash => {
            if (recv != .Instance) return null;
            return Value.newInt(@bitCast(recv.Instance.cell.data.identityOf()));
        },
        .long_hash => {
            if (recv != .Long) return null;
            const v: u64 = @bitCast(recv.Long);
            return .{ .Int = @bitCast(@as(u32, @truncate(v ^ (v >> 32)))) };
        },
        .array_size => |bits| {
            if (recv != .Array) return null;
            const arr = recv.Array;
            const want: ?runtime.PrimitiveArrayKind = if (bits == 0) null else @enumFromInt(bits - 1);
            if (arr.primKind() != want) return null;
            return Value.newInt(@intCast(arr.len()));
        },
        .list_size => {
            const l = plainList(recv) orelse return null;
            // One word, as compiled code reads it: a racing append's length or the one before.
            if (runtime.lockfreeReads()) return Value.newInt(@intCast(@atomicLoad(usize, &l.items.cell.data.items.len, .monotonic)));
            const g = l.items.borrow();
            defer g.deinit();
            return Value.newInt(@intCast(g.get().items.len));
        },
        .list_get => {
            const l = plainList(recv) orelse return null;
            if (args[1] != .Int or args[1].Int < 0) return null;
            const i: usize = @intCast(args[1].Int);
            if (runtime.lockfreeReads() and !runtime.reclaimEnabled()) {
                if (l.items.readAtMoving(i)) |elem| return elem;
            }
            const g = l.items.borrow();
            defer g.deinit();
            const items = g.get().items;
            if (i >= items.len) return null;
            return items[i];
        },
        .list_set => {
            const l = plainList(recv) orelse return null;
            if (!l.mutable) return null;
            if (l.mod_count.get()) |mc| if (mc.cell.data.frozen()) return null;
            if (args[1] != .Int or args[1].Int < 0) return null;
            const i: usize = @intCast(args[1].Int);
            const g = l.items.borrowMutAt(i);
            defer g.deinit();
            const items = g.get().items;
            if (i >= items.len) return null;
            const old = items[i];
            items[i] = args[2];
            return old;
        },
        .rotate_left, .rotate_right => {
            if (args[1] != .Int) return null;
            const n = args[1].Int;
            return switch (recv) {
                .Int => |x| .{ .Int = @bitCast(rotate(u32, @bitCast(x), n, k == .rotate_left)) },
                .Long => |x| .{ .Long = @bitCast(rotate(u64, @bitCast(x), n, k == .rotate_left)) },
                else => null,
            };
        },
        .count_one_bits => return switch (recv) {
            .Int => |x| .{ .Int = @popCount(@as(u32, @bitCast(x))) },
            .Long => |x| .{ .Int = @popCount(@as(u64, @bitCast(x))) },
            else => null,
        },
        .map_get => return mapGet(a, module, recv, &args[1]),
        .map_put => return mapPut(a, recv, &args[1], &args[2]),
        .map_set => return if (mapPut(a, recv, &args[1], &args[2]) != null) .Unit else null,
        .map_size => return mapSize(recv),
        // `add(index, element)` is not `add(element)`.
        .list_add => return if (args.len == 2) listAdd(a, recv, &args[1]) else null,
        // `append(s, start, end)` is not `append(s)`.
        .sb_append => return if (args.len == 2) sbAppend(a, recv, &args[1]) else null,
        .sb_length => return sbLength(recv),
        .iter_has_next => return iterHasNext(recv),
        .iter_next => return iterNext(recv),
        .entry_key => return entryKey(recv),
        .entry_value => return entryValue(recv),
    }
}

/// `entry_key`: a map entry's key, which never changes; null for any other receiver and for
/// a `buildMap` builder's entry, which the host function checks for a change first.
fn entryKey(recv: Value) ?Value {
    if (recv != .MapEntry or runtime.reclaimEnabled()) return null;
    const me = recv.MapEntry;
    if (me.backing.get()) |entries| if (@atomicLoad(bool, &entries.cell.data.builder, .monotonic)) return null;
    return me.key;
}

/// `entry_value`: a map entry's value, its node's while the node is in the map, its own
/// once it left (`MapEntryData.getValue`); null as `entryKey` answers it.
fn entryValue(recv: Value) ?Value {
    if (recv != .MapEntry or runtime.reclaimEnabled()) return null;
    const me = recv.MapEntry;
    if (me.backing.get()) |entries| if (@atomicLoad(bool, &entries.cell.data.builder, .monotonic)) return null;
    return me.getValue();
}

/// `iter_has_next`: whether a host iterator's position is before the end of its elements,
/// as `builtin_members.iteratorMember` answers; null for any other receiver, and for one
/// over a set whose list holds holes or was closed up since the iterator last stood.
fn iterHasNext(recv: Value) ?Value {
    if (recv != .Iterator) return null;
    const g = recv.Iterator.borrow();
    defer g.deinit();
    const cur = g.get();
    // As the host function answers: from the element `next` last gave.
    if (cur.map_kind != null or cur.set.isSome()) return .{ .Bool = !cur.ended };
    return .{ .Bool = cur.pos < itemsLen(cur.items) };
}

/// Where an iterator over a map stands in its store `st`, past any holes; null when the
/// entries moved since it last stood, which the host function finds again.
fn mapSlotAt(cur: *const runtime.IterCursor, st: *const runtime.MapStore) ?usize {
    if (st.epoch != cur.map_epoch) return null;
    var p = cur.pos;
    if (st.holes != 0) {
        while (p < st.slots.items.len and st.isHole(p)) p += 1;
    }
    return p;
}

/// `iter_next` of an iterator over a map (`IterCursor.map_kind`): the next slot's key or
/// value, or its node's entry object once the store made it; null where the host function
/// must answer (an entry object yet to make, the end, the entries moved).
fn mapCursorNext(cur: *runtime.IterCursor) ?Value {
    if (runtime.reclaimEnabled()) return null;
    const sg = cur.map_store.get().?.borrow();
    defer sg.deinit();
    const st = sg.get();
    const p = mapSlotAt(cur, st) orelse return null;
    if (p >= st.slots.items.len) return null;
    const kv = st.slots.items[p];
    const v: Value = switch (cur.map_kind.?) {
        .Keys => kv.key,
        .Values => kv.value,
        .Entries => blk: {
            if (!st.tracking) return null;
            const c = st.nodes.items[p] orelse return null;
            const me = &c.data;
            me.exp_mod = cur.exp_mod;
            me.at = @intCast(p);
            // The value the entry read last: the node's now.
            me.putValue(kv.value);
            break :blk .{ .MapEntry = me };
        },
    };
    cur.pos = p + 1;
    cur.last_ret = @intCast(p);
    cur.seen += 1;
    cur.ended = st.pastHoles(p + 1) >= st.slots.items.len;
    return v;
}

/// Whether an iterator over a set's own list reads it as a list does: no holes to pass
/// over and no compaction since it last stood. True for any other iterator.
fn setCursorPlain(cur: *const runtime.IterCursor) bool {
    const st = cur.set.get() orelse return true;
    const sd = &st.cell.data;
    return @atomicLoad(u32, &sd.holes, .monotonic) == 0 and @atomicLoad(u32, &sd.epoch, .monotonic) == cur.set_epoch;
}

/// `iter_next`: a host iterator's element at its position, the position moved past it, as
/// `builtin_members.iteratorMember` gives it; null, having done nothing, for any other
/// receiver, a structural change since the iterator was made, an iterator at its end
/// (the host function throws) and while `KLIO_ITER_TRACE` traces each step.
fn iterNext(recv: Value) ?Value {
    if (recv != .Iterator) return null;
    if (runtime.envSetOnce("KLIO_ITER_TRACE")) return null;
    const g = recv.Iterator.borrowMut();
    defer g.deinit();
    const cur = g.get();
    if (cur.mod_count.get()) |mc| if (mc.cell.data.load() != cur.exp_mod) return null;
    if (cur.map_kind != null) return mapCursorNext(cur);
    if (!setCursorPlain(cur)) return null;
    const v = itemAt(cur.items, cur.pos) orelse return null;
    // A live map entry is stamped as it is yielded, so it reads until the next change.
    if (v == .MapEntry) if (v.MapEntry.backing.get()) |entries| {
        const eg = entries.borrow();
        defer eg.deinit();
        v.MapEntry.exp_mod = if (eg.get().mod_count.get()) |mc| mc.cell.data.load() else 0;
    };
    cur.last_ret = @intCast(cur.pos);
    cur.pos += 1;
    if (cur.set.isSome()) {
        cur.seen += 1;
        // A plain set's list holds no holes.
        cur.ended = cur.pos >= itemsLen(cur.items);
    }
    return v;
}

fn itemsLen(items: runtime.ValueList) usize {
    if (runtime.lockfreeReads()) if (items.lenMoving()) |n| return n;
    const g = items.borrow();
    defer g.deinit();
    return g.get().items.len;
}

fn itemAt(items: runtime.ValueList, i: usize) ?Value {
    if (runtime.lockfreeReads()) if (items.readAtMoving(i)) |v| return v;
    const g = items.borrow();
    defer g.deinit();
    const xs = g.get().items;
    return if (i < xs.len) xs[i] else null;
}

/// `list_add`: `v` appended to list `recv`, a structural change its iterators see, as the
/// host function makes it; null for a view, a list that cannot change, or no memory.
pub fn listAdd(a: std.mem.Allocator, recv: Value, v: *const Value) ?Value {
    const l = plainList(recv) orelse return null;
    if (!l.mutable) return null;
    const mc = l.mod_count.get();
    if (mc) |m| if (m.cell.data.frozen()) return null;
    {
        const h = &l.items.cell.hdr;
        const g = l.items.borrowMutAppend(1);
        defer g.deinit();
        const list = g.get();
        const before = @intFromPtr(list.items.ptr);
        list.append(runtime.gc.bufferAllocatorFor(h, a), v.*) catch return null;
        runtime.gc.bufferMoved(h, before, @intFromPtr(list.items.ptr));
    }
    if (mc) |m| m.cell.data.bump();
    return .{ .Bool = true };
}

/// `map_put`: `value` stored under `key` in map `recv`, answering the value it replaced or
/// `null`, a new key a structural change its iterators see; null for a map that cannot
/// change, a key the store compares by more than its value (an instance, a collection),
/// or no memory.
pub fn mapPut(a: std.mem.Allocator, recv: Value, key: *const Value, value: *const Value) ?Value {
    if (recv != .Map or !recv.Map.mutable) return null;
    switch (key.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Bool, .Char, .Double, .Float, .Null, .String => {},
        else => return null,
    }
    // The exclusive borrow takes the write barrier, which a moved array needs too.
    const g = recv.Map.entries.borrowMut();
    defer g.deinit();
    const store = g.get();
    const mc = store.mod_count.get();
    if (mc) |m| if (m.cell.data.frozen()) return null;
    const ba = runtime.gc.bufferAllocatorFor(&recv.Map.entries.cell.hdr, a);
    if (store.find(ba, key) catch return null) |i| {
        const prev = store.slots.items[i].value;
        store.slots.items[i].value = value.*;
        return prev;
    }
    // A map below the index's size keeps no hashes.
    const small = store.slots.items.len + 1 < runtime.MapStore.index_threshold;
    store.appendHashed(ba, .{ .key = key.*, .value = value.* }, if (small) null else runtime.MapStore.keyHash(key)) catch return null;
    if (mc) |m| m.cell.data.bump();
    return .Null;
}

/// `map_size`: map `recv`'s entry count, with no lock where a list's size takes none.
pub fn mapSize(recv: Value) ?Value {
    if (recv != .Map) return null;
    const entries = recv.Map.entries;
    if (runtime.lockfreeReads()) if (runtime.mapLenNoLock(entries)) |n| return Value.newInt(@intCast(n));
    const g = entries.borrow();
    defer g.deinit();
    return Value.newInt(@intCast(g.get().len()));
}

/// `sb_append`: builder `recv` with the string or the digits of the number `v` after it.
pub fn sbAppend(a: std.mem.Allocator, recv: Value, v: *const Value) ?Value {
    if (recv != .StringBuilder) return null;
    const sb = recv.StringBuilder;
    var digits: [20]u8 = undefined;
    const sg = if (v.* == .String) v.String.borrow() else null;
    defer if (sg) |x| x.deinit();
    const piece: []const u8 = switch (v.*) {
        .Int => |x| runtime.decimal(&digits, x),
        .Long => |x| runtime.decimal(&digits, x),
        .String => sg.?.get().bytes,
        else => return null,
    };
    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    // Past `Int.MAX_VALUE` characters the host function throws.
    if (v.* == .String and buf.items.len + sg.?.get().u16_len > std.math.maxInt(i32)) return null;
    const before_ptr = buf.items.ptr;
    const before_len = buf.items.len;
    buf.appendSlice(runtime.gc.bufferAllocatorFor(&sb.cell.hdr, a), piece) catch return null;
    runtime.gc.bufferMoved(&sb.cell.hdr, @intFromPtr(before_ptr), @intFromPtr(buf.items.ptr));
    runtime.sbMemoAppended(@intFromPtr(sb.cell), before_ptr, before_len, buf.items, piece);
    return recv;
}

/// `sb_length`: builder `recv`'s length in UTF-16 units, with no scan while it is known ASCII.
pub fn sbLength(recv: Value) ?Value {
    if (recv != .StringBuilder) return null;
    const sb = recv.StringBuilder;
    const cell_addr = @intFromPtr(sb.cell);
    // Known ASCII needs no lock: two words, one writer's length or the one before it.
    if (runtime.lockfreeReads()) {
        const len = @atomicLoad(usize, &sb.cell.data.items.len, .monotonic);
        if (runtime.sbAsciiLen(cell_addr, len)) |n| return Value.newInt(@intCast(n));
    }
    const g = sb.borrow();
    defer g.deinit();
    const items = g.get().items;
    const n = runtime.sbAsciiLen(cell_addr, items.len) orelse runtime.sbMemoFor(cell_addr, items).u16_len;
    return Value.newInt(@intCast(n));
}

/// `map_get`: the value of `key` in map `recv`, with no lock for a number, a
/// string or an instance that keeps `Any`'s members.
pub fn mapGet(a: std.mem.Allocator, module: *const ir.Module, recv: Value, key: *const Value) ?Value {
    if (recv != .Map) return null;
    if (key.* == .Instance) return identityGet(module, recv.Map.entries, key);
    // A key the store compares by more than its value is the host's.
    if (key.hostKeyed()) return null;
    if (key.* == .Int and runtime.lockfreeReads()) {
        if (runtime.lookupIntNoLock(recv.Map.entries, key.Int)) |v| return v;
    } else if (runtime.lockfreeReads()) if (runtime.MapStore.keyHash(key)) |hsh| {
        const hit = if (key.isNumeric())
            runtime.lookupNoLock(recv.Map.entries, hsh, key, runtime.numericKeyEq, false)
        else
            runtime.lookupNoLock(recv.Map.entries, hsh, key, sameKey, true);
        if (hit) |v| return v;
    };
    {
        const g = recv.Map.entries.borrow();
        defer g.deinit();
        const store = g.get();
        if (store.findIndexed(key)) |found| return if (found) |i| store.slots.items[i].value else .Null;
    }
    const g = recv.Map.entries.borrowMut();
    defer g.deinit();
    const i = (g.get().find(a, key) catch return null) orelse return .Null;
    return g.get().slots.items[i].value;
}

/// The value of instance `key` in a map whose every entry is in its index, when
/// the key's class keeps `Any`'s `hashCode` and `equals`, so the map finds it
/// by identity: through the bucket of its identity's hash, as the host's
/// lookup does (`collections/map.zig`). Null leaves the lookup to the host: a
/// key of another class, a map not all indexed, a bucket holding a key whose
/// class answers `equals` itself.
fn identityGet(module: *const ir.Module, entries: runtime.MapEntries, key: *const Value) ?Value {
    if (!identityKeyed(module, key)) return null;
    const h = key.Instance.asPtrConst().identityOf();
    const hash = @as(u64, @as(u32, @truncate(h))) *% 0x9E3779B97F4A7C15;
    if (runtime.lockfreeReads()) {
        const Ctx = struct { module: *const ir.Module, key: *const Value };
        const same = struct {
            fn same(c: Ctx, k: *const Value) ?bool {
                if (k.* != .Instance) return false;
                if (k.Instance.cell == c.key.Instance.cell) return true;
                return if (identityKeyed(c.module, k)) false else null;
            }
        }.same;
        if (runtime.lookupNoLock(entries, hash, Ctx{ .module = module, .key = key }, same, true)) |v| return v;
    }
    const g = entries.borrow();
    defer g.deinit();
    const store = g.get();
    const n = store.slots.items.len;
    if (store.unhashable or n < runtime.MapStore.index_threshold or store.hashes.items.len != n or store.chain.items.len != n) return null;
    var slot = store.bucketHead(hash);
    while (slot != 0) : (slot = store.chain.items[slot - 1]) {
        if (store.hashes.items[slot - 1] != hash) continue;
        const k = &store.slots.items[slot - 1].key;
        if (k.* != .Instance) continue;
        if (k.Instance.cell == key.Instance.cell) return store.slots.items[slot - 1].value;
        if (!identityKeyed(module, k)) return null;
    }
    return .Null;
}

/// Whether stored key `k` is `key`, as `findIndexed` compares them.
fn sameKey(key: *const Value, k: *const Value) ?bool {
    return Value.structuralEqBoxed(k, key);
}

/// Whether instance `v`'s class keeps `Any`'s `hashCode` and `equals`, kept
/// on the class after the first ask.
fn identityKeyed(module: *const ir.Module, v: *const Value) bool {
    const r = module.resolved orelse return false;
    const cls = ir.resolved.classOf(r, v) orelse return false;
    if (cls.int() >= r.classes.len) return false;
    const rt = &r.classes[cls.int()];
    const b = rt.identity_keyed.load(.monotonic);
    if (b != 0) return b == 2;
    const yes = keepsAnyMembers(r, cls);
    rt.identity_keyed.store(if (yes) 2 else 1, .monotonic);
    return yes;
}

fn keepsAnyMembers(r: *const ir.resolved.Resolved, cls: ir.ClassId) bool {
    if (r.classes[cls.int()].host_slot != ir.resolved.NONE) return false;
    inline for (.{ .{ runtime.WellKnown.hash_code, "kotlin.Any.hashCode" }, .{ runtime.WellKnown.equals, "kotlin.Any.equals" } }) |p| {
        const slot = r.well_known.get(p[0]) orelse return false;
        const f = ir.resolved.slotTarget(r, cls, slot) orelse return false;
        if (f.int() >= r.func_native.len) return false;
        const n = r.func_native[f.int()];
        if (n == .none or n.int() >= r.natives.len) return false;
        if (!std.mem.eql(u8, r.natives[n.int()].name, p[1])) return false;
    }
    return true;
}

/// The list's data, when it is no view of another list or an array.
fn plainList(v: Value) ?*runtime.ListData {
    if (v != .List or v.List.backing != null) return null;
    return v.List;
}

/// `x` rotated by `n` taken modulo its width, as Kotlin's shifts take theirs.
fn rotate(comptime U: type, x: U, n: i32, left: bool) U {
    const bits = @bitSizeOf(U);
    const s: std.math.Log2Int(U) = @intCast(@mod(n, bits));
    return if (left) std.math.rotl(U, x, s) else std.math.rotr(U, x, s);
}

test "a native's intrinsic survives its cache's encoding" {
    const kinds = [_]Intrinsic{ .none, .any_hash, .long_hash, .{ .array_size = 0 }, .{ .array_size = 3 }, .list_size, .list_get, .list_set, .list_add, .rotate_left, .rotate_right, .count_one_bits, .map_get, .map_put, .map_set, .map_size, .sb_append, .sb_length };
    for (kinds) |k| try std.testing.expectEqual(k, Intrinsic.decode(k.encode()));
}

test "the interpreter's intrinsics answer as Kotlin's host functions" {
    const L: i64 = -0x0123_4567_89ab_cdef;
    const lu: u64 = @bitCast(L);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, @truncate(lu ^ (lu >> 32))))), answer(.long_hash, std.testing.allocator, undefined, &.{.{ .Long = L }}).?.Int);
    try std.testing.expectEqual(@as(i32, 0x2), answer(.rotate_left, std.testing.allocator, undefined, &.{ .{ .Int = 1 }, .{ .Int = 33 } }).?.Int);
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), answer(.rotate_right, std.testing.allocator, undefined, &.{ .{ .Int = 1 }, .{ .Int = -31 } }).?.Int);
    try std.testing.expectEqual(@as(i64, 1) << 63, answer(.rotate_right, std.testing.allocator, undefined, &.{ .{ .Long = 1 }, .{ .Int = 1 } }).?.Long);
    try std.testing.expectEqual(@as(i32, 64), answer(.count_one_bits, std.testing.allocator, undefined, &.{.{ .Long = -1 }}).?.Int);
    try std.testing.expect(answer(.count_one_bits, std.testing.allocator, undefined, &.{.{ .Double = 1.0 }}) == null);
    try std.testing.expect(answer(.rotate_left, std.testing.allocator, undefined, &.{ .{ .Int = 1 }, .{ .Long = 1 } }) == null);
}

test "a builder's append of a string and a number is the intrinsic's, and of a range the host function's" {
    const a = std.testing.allocator;
    const sb = try runtime.ObjRef(std.ArrayList(u8)).init(a, .empty);
    defer sb.deinit();
    const recv: Value = .{ .StringBuilder = sb };
    const text: Value = .{ .String = try runtime.strInit(a, "abcdef") };
    defer text.String.deinit();
    try std.testing.expect(answer(.sb_append, a, undefined, &.{ recv, text }) != null);
    try std.testing.expect(answer(.sb_append, a, undefined, &.{ recv, .{ .Int = -42 } }) != null);
    // `append(s, start, end)` appends part of `s`, which only the host function does.
    try std.testing.expect(answer(.sb_append, a, undefined, &.{ recv, text, .{ .Int = 1 }, .{ .Int = 3 } }) == null);
    try std.testing.expectEqualStrings("abcdef-42", sb.cell.data.items);
    try std.testing.expectEqual(@as(i32, 9), answer(.sb_length, a, undefined, &.{recv}).?.Int);
}

test "a list's append is the intrinsic's for a plain mutable list, and the host function's otherwise" {
    const a = std.testing.allocator;
    var data: runtime.ListData = .{
        .items = try runtime.ValueList.init(a, .empty),
        .mutable = true,
        .backing = null,
        .mod_count = .from(try runtime.ModCount.new(a)),
    };
    defer data.deinit(a);
    const recv: Value = .{ .List = &data };
    try std.testing.expect(answer(.list_add, a, undefined, &.{ recv, .{ .Int = 7 } }).?.Bool);
    try std.testing.expect(answer(.list_add, a, undefined, &.{ recv, .{ .Int = 8 } }).?.Bool);
    try std.testing.expectEqual(@as(usize, 2), data.items.cell.data.items.len);
    try std.testing.expectEqual(@as(i32, 8), data.items.cell.data.items[1].Int);
    // Each append is a structural change an iterator made before it sees.
    try std.testing.expectEqual(@as(u64, 2), data.mod_count.get().?.cell.data.load());
    // `add(index, element)` inserts, which only the host function does.
    try std.testing.expect(answer(.list_add, a, undefined, &.{ recv, .{ .Int = 0 }, .{ .Int = 9 } }) == null);
    data.mod_count.get().?.cell.data.freeze();
    try std.testing.expect(answer(.list_add, a, undefined, &.{ recv, .{ .Int = 9 } }) == null);
    _ = data.mod_count.get().?.cell.data.n.fetchAnd(~runtime.FROZEN_MOD_BIT, .monotonic);
    data.mutable = false;
    try std.testing.expect(answer(.list_add, a, undefined, &.{ recv, .{ .Int = 9 } }) == null);
    try std.testing.expectEqual(@as(usize, 2), data.items.cell.data.items.len);
}

test "a map's put, set and size are the intrinsics' for a key compared by its value" {
    const a = std.testing.allocator;
    const entries = try runtime.MapEntries.init(a, .{ .mod_count = .from(try runtime.ModCount.new(a)) });
    defer entries.deinit();
    var data: runtime.MapData = .{ .entries = entries, .mutable = true };
    const recv: Value = .{ .Map = &data };
    const mod = &entries.cell.data.mod_count.get().?.cell.data;
    // Past the index's size, so the index is kept as the host keeps it.
    var i: i32 = 0;
    while (i < 20) : (i += 1) try std.testing.expect(answer(.map_put, a, undefined, &.{ recv, .{ .Int = i }, .{ .Int = i * 10 } }).? == .Null);
    try std.testing.expectEqual(@as(u64, 20), mod.load());
    // A replaced value is answered, and a replacement is no structural change.
    try std.testing.expectEqual(@as(i32, 30), answer(.map_put, a, undefined, &.{ recv, .{ .Int = 3 }, .{ .Int = 33 } }).?.Int);
    try std.testing.expect(answer(.map_set, a, undefined, &.{ recv, .{ .Int = 4 }, .{ .Int = 44 } }).? == .Unit);
    try std.testing.expectEqual(@as(u64, 20), mod.load());
    try std.testing.expectEqual(@as(i32, 33), answer(.map_get, a, undefined, &.{ recv, .{ .Int = 3 } }).?.Int);
    try std.testing.expectEqual(@as(i32, 44), answer(.map_get, a, undefined, &.{ recv, .{ .Int = 4 } }).?.Int);
    try std.testing.expectEqual(@as(i32, 190), answer(.map_get, a, undefined, &.{ recv, .{ .Int = 19 } }).?.Int);
    try std.testing.expect(answer(.map_get, a, undefined, &.{ recv, .{ .Long = 4 } }).? == .Null);
    try std.testing.expectEqual(@as(i32, 20), answer(.map_size, a, undefined, &.{recv}).?.Int);
    // A frozen or read-only map throws from the host function.
    mod.freeze();
    try std.testing.expect(answer(.map_put, a, undefined, &.{ recv, .{ .Int = 99 }, .Null }) == null);
    _ = mod.n.fetchAnd(~runtime.FROZEN_MOD_BIT, .monotonic);
    data.mutable = false;
    try std.testing.expect(answer(.map_set, a, undefined, &.{ recv, .{ .Int = 99 }, .Null }) == null);
    try std.testing.expectEqual(@as(i32, 20), answer(.map_size, a, undefined, &.{recv}).?.Int);
}

test "run writes the answer through its pointer, and leaves it alone where the host function must run" {
    var out: Value = .{ .Int = -7 };
    try std.testing.expect(run(.count_one_bits, std.testing.allocator, undefined, &.{.{ .Int = 7 }}, &out));
    try std.testing.expectEqual(@as(i32, 3), out.Int);
    out = .{ .Int = -7 };
    try std.testing.expect(!run(.count_one_bits, std.testing.allocator, undefined, &.{.{ .Double = 1.0 }}, &out));
    try std.testing.expectEqual(@as(i32, -7), out.Int);
}
