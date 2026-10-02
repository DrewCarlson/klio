//! A `for` loop over a list, set, array or string the host holds, run as kotlinc runs a loop
//! over an array or a string: by position, over the live collection, where the loop would
//! otherwise make an iterator and call its `hasNext()` and `next()` for every element.
//! A list's or a set's loop fails fast as its JVM iterator does: an element read after a
//! structural change throws ConcurrentModificationException.
//!
//! `open` gives the loop a stamp: the low 32 bits of the collection's structural count (the
//! width of the JVM's `modCount`) above its size when the loop began. A list's iterator
//! (`ArrayList.Itr`) has another element while its position is not the list's size; a set's
//! (`LinkedHashMap.LinkedHashIterator`) while it held a next entry, which is while the
//! position is below the size the loop began with, since a change before then made the
//! read before it throw.
//!
//! A loop over a map (its entries) or one of its views (`MapViews.kt`) reads the map's slots
//! by position: `open` closes the map's holes up, so its entries stand at the first
//! positions until a structural change, which the count shows; a loop over entries has each
//! node's entry object made at `open`, so a read makes none.

const std = @import("std");
const objcell = @import("objcell.zig");
const value_mod = @import("value.zig");
const class_mod = @import("class.zig");

const Value = value_mod.Value;
const ValueList = value_mod.ValueList;
const ModCount = value_mod.ModCount;

/// The stamp a loop over `v` starts from, or null for a value whose loop calls `iterator()`:
/// a `subList` or an array's `asList()`, a user collection.
pub fn open(v: *const Value) ?i64 {
    return switch (v.*) {
        .List => |l| if (l.backing != null) null else stamp(l.mod_count, listLen(l.items)),
        .Set => |s| if (s.backing != null) null else stamp(s.mod_count, listLen(s.dense())),
        .Map => |m| openMap(m.entries, .Entries),
        .Instance => |inst| if (viewOf(inst)) |mv| openMap(mv.entries, mv.kind) else null,
        .Array, .String => 0,
        else => null,
    };
}

const MapView = struct { entries: value_mod.MapEntries, kind: value_mod.MapViewKind };

/// The map a `keys`, `values` or `entries` instance reads, and which view it is; null for
/// any other instance.
fn viewOf(inst: objcell.ObjRef(class_mod.InstanceData)) ?MapView {
    const mark = inst.asPtrConst().class.asPtrConst().map_view orelse return null;
    // Written by the constructor, before the view is handed out, and never again.
    const m = class_mod.InstanceData.slotGet(inst, mark.slot) orelse return null;
    if (m != .Map) return null;
    return .{ .entries = m.Map.entries, .kind = mark.kind };
}

fn openMap(entries: value_mod.MapEntries, kind: value_mod.MapViewKind) ?i64 {
    const g = entries.borrowMut();
    defer g.deinit();
    const st = g.get();
    st.compact();
    const n = st.slots.items.len;
    if (kind == .Entries) {
        const a = entries.cell.allocatorOf();
        const ba = objcell.gc.bufferAllocatorFor(&entries.cell.hdr, a);
        const now: u64 = if (st.mod_count.get()) |cell| cell.cell.data.load() else 0;
        for (0..n) |i| {
            const e = st.nodeEntry(ba, a, entries, i, now) catch return null;
            e.release(a);
        }
    }
    return stamp(st.mod_count, n);
}

/// Whether the loop over `v` that `open` stamped `at` has an element at position `idx`.
pub fn has(v: *const Value, idx: i64, at: i64) bool {
    const i: u64 = @bitCast(idx);
    return switch (v.*) {
        .List => |l| i != listLen(l.items),
        .Set, .Map, .Instance => i < sizeOf(at),
        .Array => |arr| i < arr.len(),
        .String => |s| i < s.cell.data.u16_len,
        else => false,
    };
}

pub const Got = union(enum) {
    elem: Value,
    /// A structural change since the loop began: ConcurrentModificationException.
    changed,
};

/// The element at `idx` of the loop over `v` that `open` stamped `at`, which `has` found;
/// owned by the caller where values are counted.
pub fn get(v: *const Value, idx: i64, at: i64) Got {
    const i: usize = @intCast(idx);
    switch (v.*) {
        .List => |l| return counted(l.items, l.mod_count, i, at),
        // Opened dense: a hole comes only with a removal, which the count shows.
        .Set => |s| return counted(s.elems, s.mod_count, i, at),
        .Map => |m| return mapGet(m.entries, .Entries, i, at),
        .Instance => |inst| return if (viewOf(inst)) |mv| mapGet(mv.entries, mv.kind, i, at) else .changed,
        .Array => |arr| switch (arr.storage()) {
            .scalars => |pb| {
                // As `ArrayGet` reads one: the buffer never moves and an element is a word.
                const buf = &pb.cell.data;
                if (i >= buf.len()) return .changed;
                return .{ .elem = buf.getAs(i, arr.primKind() orelse buf.kind) };
            },
            .boxed => |vl| {
                if (!objcell.reclaimEnabled()) if (vl.readAt(i)) |e| return .{ .elem = e };
                return if (lockedAt(vl, i)) |e| .{ .elem = e } else .changed;
            },
        },
        .String => |s| {
            const u = s.cell.data.utf16UnitAt(i) orelse return .changed;
            return .{ .elem = .{ .Char = u } };
        },
        else => return .changed,
    }
}

/// Slot `i` of a map's loop: its key, its value or its node's entry object, while the
/// structural count is the stamp's.
fn mapGet(entries: value_mod.MapEntries, kind: value_mod.MapViewKind, i: usize, at: i64) Got {
    const g = entries.borrow();
    defer g.deinit();
    const st = g.get();
    if (st.mod_count.get()) |cell| {
        const now: u32 = @truncate(cell.cell.data.load());
        if (now != @as(u32, @truncate(@as(u64, @bitCast(at)) >> 32))) return .changed;
    }
    if (i >= st.slots.items.len or st.isHole(i)) return .changed;
    const kv = st.slots.items[i];
    const elem: Value = switch (kind) {
        .Keys => kv.key,
        .Values => kv.value,
        .Entries => blk: {
            if (!st.tracking or i >= st.nodes.items.len) return .changed;
            const c = st.nodes.items[i] orelse return .changed;
            c.data.at = @intCast(i);
            const e: Value = .{ .MapEntry = &c.data };
            break :blk e;
        },
    };
    elem.retain();
    return .{ .elem = elem };
}

fn stamp(mc: objcell.OptRef(ModCount), size: usize) i64 {
    const n: u64 = if (mc.get()) |cell| cell.cell.data.load() else 0;
    return @bitCast((n << 32) | @as(u32, @truncate(size)));
}

fn sizeOf(at: i64) u64 {
    return @as(u32, @truncate(@as(u64, @bitCast(at))));
}

/// A list's or set's element: a structural count that moved since the stamp, or a position
/// past the end, which only a change the count missed reaches, is a change.
fn counted(items: ValueList, mc: objcell.OptRef(ModCount), i: usize, at: i64) Got {
    if (mc.get()) |cell| {
        const now: u32 = @truncate(cell.cell.data.load());
        if (now != @as(u32, @truncate(@as(u64, @bitCast(at)) >> 32))) return .changed;
    }
    if (objcell.lockfree_reads and !objcell.reclaimEnabled()) if (items.readAtMoving(i)) |e| return .{ .elem = e };
    return if (lockedAt(items, i)) |e| .{ .elem = e } else .changed;
}

fn lockedAt(items: ValueList, i: usize) ?Value {
    const g = items.borrow();
    defer g.deinit();
    const xs = g.get().items;
    if (i >= xs.len) return null;
    xs[i].retain();
    return xs[i];
}

fn listLen(items: ValueList) usize {
    if (objcell.lockfree_reads) if (items.lenMoving()) |n| return n;
    const g = items.borrow();
    defer g.deinit();
    return g.get().items.len;
}

const testing = std.testing;

fn testList(a: std.mem.Allocator, xs: []const i32, mutable: bool) !Value {
    var items: std.ArrayList(Value) = .empty;
    for (xs) |x| try items.append(a, .{ .Int = x });
    return Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = mutable,
        .backing = null,
        .mod_count = .from(try ModCount.new(a)),
    });
}

test "a loop over a list reads it by position, and a structural change since it began is a change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try testList(a, &.{ 10, 20, 30 }, true);
    const at = open(&list).?;
    var seen: [3]i32 = undefined;
    var i: i64 = 0;
    while (has(&list, i, at)) : (i += 1) seen[@intCast(i)] = get(&list, i, at).elem.Int;
    try testing.expectEqualSlices(i32, &.{ 10, 20, 30 }, &seen);
    // An element added after the loop began: the position is not the size, and the read throws.
    {
        const g = list.List.items.borrowMut();
        defer g.deinit();
        try g.get().append(a, .{ .Int = 40 });
    }
    list.List.mod_count.get().?.cell.data.bump();
    try testing.expect(has(&list, 3, at));
    try testing.expect(get(&list, 3, at) == .changed);
}

test "a loop over a set ends at the size it began with, and over an array or a string reads the live value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try testList(a, &.{ 1, 2, 3 }, true);
    const set = try Value.newSet(a, .{ .elems = l.List.items, .mutable = true, .backing = null, .mod_count = l.List.mod_count });
    const at = open(&set).?;
    {
        const g = set.Set.elems.borrowMut();
        defer g.deinit();
        _ = g.get().orderedRemove(0);
    }
    set.Set.mod_count.get().?.cell.data.bump();
    // At the last element, an earlier one removed: the loop ends, as a linked set's does.
    try testing.expect(!has(&set, 3, at));
    try testing.expect(has(&set, 1, at));
    try testing.expect(get(&set, 1, at) == .changed);

    const s: Value = .{ .String = try value_mod.strInit(a, "h\u{e9}!") };
    const sat = open(&s).?;
    try testing.expect(has(&s, 2, sat));
    try testing.expect(!has(&s, 3, sat));
    try testing.expectEqual(@as(u16, 0xE9), get(&s, 1, sat).elem.Char);
    const none: Value = .Null;
    try testing.expect(open(&none) == null);
}

test "a loop over a map's view reads the map by position: its keys, its values, or its nodes' entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try value_mod.MapEntries.init(a, .{ .mod_count = .from(try ModCount.new(a)) });
    for (0..3) |i| try entries.cell.data.append(a, .{ .key = .{ .Int = @intCast(i) }, .value = .{ .Int = @intCast(i * 10) } });
    const map = try Value.newMap(a, .{ .entries = entries, .mutable = true });
    var want = [_][3]i32{ .{ 0, 1, 2 }, .{ 0, 10, 20 }, .{ 0, 1, 2 } };
    for ([_]value_mod.MapViewKind{ .Keys, .Values, .Entries }, &want) |kind, *w| {
        const class = try class_mod.ClassDef.minimal(a, "View", "View", 0);
        class.asPtr().map_view = .{ .kind = kind, .slot = 1 };
        const inst = try class_mod.InstanceData.newTrailing(a, class, 0, 2);
        inst.cell.data.slots[0] = .Null;
        inst.cell.data.slots[1] = map;
        const view: Value = .{ .Instance = inst };
        const at = open(&view).?;
        var seen: [3]i32 = undefined;
        var i: i64 = 0;
        while (has(&view, i, at)) : (i += 1) {
            const e = get(&view, i, at).elem;
            seen[@intCast(i)] = if (kind == .Entries) e.MapEntry.key.Int else e.Int;
        }
        try testing.expectEqualSlices(i32, w, &seen);
    }
    // An instance of any other class runs its loop through `iterator()`.
    const plain = try class_mod.InstanceData.newTrailing(a, try class_mod.ClassDef.minimal(a, "C", "C", 1), 1, 2);
    plain.cell.data.slots[0] = .Null;
    plain.cell.data.slots[1] = map;
    try testing.expect(open(&Value{ .Instance = plain }) == null);
}
