//! Map iterators, and `subList` write-through synchronisation.

const std = @import("std");
const runtime = @import("runtime");
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const MapViewKind = runtime.MapViewKind;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common_mod = @import("common.zig");
const eqBoxed = common_mod.eqBoxed;
const thrown = common_mod.thrown;

/// An iterator that walks map store `entries`'s slots, yielding `kind` of each entry: its
/// keys, its values, or its nodes' entry objects. A mutable map's (`mutable`, not frozen by a
/// builder) removes through `remove` and fails fast once the map changes otherwise.
pub fn mapIterator(a: Allocator, entries: MapEntries, kind: MapViewKind, mutable: bool) Error!Value {
    const at = blk: {
        const g = entries.borrow();
        defer g.deinit();
        const st = g.get();
        break :blk .{ st.head, st.epoch, st.mod_count, st.len() == 0 };
    };
    const mc = at[2].get();
    const live = mutable and !(if (mc) |c| c.cell.data.frozen() else false);
    return Value.newIterator(a, .{
        .items = try runtime.ObjRef(std.ArrayList(Value)).init(a, .empty),
        .prim = null,
        .mod_count = .from(if (mc) |c| c.clone() else null),
        .mutable = live,
        .pos = at[0],
        .exp_mod = if (mc) |c| c.cell.data.load() else 0,
        .map_store = .from(entries.clone()),
        .source = .collection,
        .map_kind = kind,
        .map_epoch = at[1],
        .ended = at[3],
    });
}

pub fn sublistBackingOf(receiver: Value) ?*runtime.CollBackingRef.Cell {
    if (receiver != .List) return null;
    const cell = receiver.List.backing orelse return null;
    if (cell.data != .sublist) return null;
    return cell;
}

/// Splice a mutated `subList` window back into the parent list. Declared as the
/// first `defer` of every list mutator so it runs once the mutator's own
/// item-borrow guard is released.
pub fn syncSublist(a: Allocator, receiver: Value) void {
    const cell = sublistBackingOf(receiver) orelse return;
    const cur = counterNowOf(receiver.List.mod_count);
    syncSublistChain(a, cell, receiver.List.items, cur);
}

/// Recurse up the ancestor chain, re-stamping each ancestor's comod
/// expectation. Siblings keep their stale stamp and fail fast on next access.
fn syncSublistChain(a: Allocator, cell: *runtime.CollBackingRef.Cell, view_items: ValueList, cur: u64) void {
    if (cell.data != .sublist) return;
    const sb = &cell.data.sublist;
    const from = sb.from;
    const old_len = sb.len;
    {
        const view_g = view_items.borrow();
        defer view_g.deinit();
        const new_items = view_g.get().items;
        const pg = sb.parent.borrowMut();
        defer pg.deinit();
        const plist = pg.get();
        if (from > plist.items.len) {
            sb.len = 0;
            return;
        }
        const span = @min(from + old_len, plist.items.len) - from;
        if (runtime.reclaimEnabled()) {
            for (plist.items[from .. from + span]) |v| v.release(a);
            for (new_items) |v| v.retain();
        }
        plist.replaceRange(a, from, span, new_items) catch return;
        sb.len = new_items.len;
        sb.exp_mod = cur;
    }
    if (sb.parent_backing) |pb| syncSublistChain(a, pb, sb.parent, cur);
}

pub fn counterNowOf(mc: runtime.OptRef(runtime.ModCount)) u64 {
    const cell = mc.get() orelse return 0;
    return cell.cell.data.load();
}

/// The CME predicate: the backing changed structurally other than through this
/// view or a descendant. The freeze bit is masked so a leaked but unmodified
/// builder view still reads after `build()`.
pub fn sublistViewStale(v: *const Value) bool {
    return v.sublistViewStale();
}

pub fn sublistComodGuard(a: Allocator, v: *const Value) Error!?EvalResult {
    if (!sublistViewStale(v)) return null;
    return try thrown(a, "kotlin.ConcurrentModificationException", null);
}

/// A live `Map.Entry` read: its value box brought up to its node's value while the node is in
/// the map, so a change through the map shows; a `buildMap` builder's entry throws CME once
/// the map changed structurally (`MapEntryData.read`).
pub fn mapEntryViewGuard(a: Allocator, v: *const Value) Error!?EvalResult {
    if (v.* != .MapEntry) return null;
    const me = v.MapEntry;
    const entries = me.backing.get() orelse return null;
    const r = blk: {
        const g = entries.borrow();
        defer g.deinit();
        break :blk me.read(g.get());
    };
    const live: ?Value = switch (r) {
        .stale => return try thrown(a, "kotlin.ConcurrentModificationException", null),
        .live => |x| x,
        .detached => null,
    };
    if (live) |lv| me.putValue(lv);
    return null;
}
