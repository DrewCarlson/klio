//! Live map-view (`keys`/`values`/`entries`) and `subList`
//! write-through synchronisation.

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

// =====================================================================
// Map-view sync (keys/values/entries live views)
// =====================================================================

const MapView = struct { entries: MapEntries, kind: MapViewKind };
const MapViewRef = struct { items: ValueList, backing: MapView };

/// Resolve a view value to its map-backing, or null when it is not a live map
/// view (a plain collection, a `subList`, or an array `.asList()`).
fn mapBackingOf(receiver: Value) ?MapView {
    const cell = switch (receiver) {
        .Set => |s| s.backing,
        .List => |l| l.backing,
        else => null,
    } orelse return null;
    return switch (cell.data) {
        .map => |m| .{ .entries = m.entries, .kind = m.kind },
        else => null,
    };
}

/// After a live `MutableMap.keys`/`.values`/`.entries` view mutated its
/// `items`, rebuild the backing map's entries to mirror the survivors.
/// Order-preserving subsequence match.
pub fn syncMapView(a: Allocator, receiver: Value) void {
    _ = a;
    const backing = mapBackingOf(receiver) orelse return;
    const items_vl = switch (receiver) {
        .Set => |s| s.items,
        .List => |l| l.items,
        else => return,
    };
    const view: MapViewRef = .{ .items = items_vl, .backing = backing };
    const items_g = view.items.borrow();
    defer items_g.deinit();
    const items = items_g.get().items;
    const kind = view.backing.kind;
    const entries_g = view.backing.entries.borrowMut();
    defer entries_g.deinit();
    const entries = entries_g.get();
    var j: usize = 0;
    var w: usize = 0;
    var r: usize = 0;
    while (r < entries.pairs.items.len) : (r += 1) {
        const kv = entries.pairs.items[r];
        const proj = switch (kind) {
            .Values => kv.value,
            else => kv.key,
        };
        var matched = false;
        if (j < items.len) {
            const it = items[j];
            const target = switch (kind) {
                .Entries => if (it == .MapEntry) it.MapEntry.key.asPtr().* else it,
                else => it,
            };
            matched = eqBoxed(&proj, &target);
        }
        if (matched) {
            entries.pairs.items[w] = kv;
            w += 1;
            j += 1;
        }
    }
    entries.pairs.shrinkRetainingCapacity(w);
    entries.invalidate();
}

// =====================================================================
// subList live-view write-through
// =====================================================================

/// Resolve a value to its live `subList` backing cell, or null when it is not a
/// `subList` view (a plain list, a map view, or an array `.asList()`).
pub fn sublistBackingOf(receiver: Value) ?*runtime.CollBackingRef.Cell {
    if (receiver != .List) return null;
    const cell = receiver.List.backing orelse return null;
    if (cell.data != .sublist) return null;
    return cell;
}

/// After a `subList` view mutated its own `items`, splice the new window back
/// into the parent list so the change shows through, and record the window's
/// new length. A no-op for any receiver that is not a live `subList`. Declared
/// as the *first* `defer` of every list mutator so it runs after the mutator's
/// own item-borrow guard has been released (no nested borrow of `items`).
pub fn syncSublist(a: Allocator, receiver: Value) void {
    const cell = sublistBackingOf(receiver) orelse return;
    const cur = counterNowOf(receiver.List.mod_count);
    syncSublistChain(a, cell, receiver.List.items, cur);
}

/// Splice a mutated view's cache into its parent window and recurse up
/// the ancestor chain, growing/shrinking each window and re-stamping each
/// ancestor's comod expectation. Siblings keep their stale stamp and fail
/// fast on their next access.
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

/// Current value of a shared structural counter (0 when uncounted).
pub fn counterNowOf(mc: runtime.OptRef(u64)) u64 {
    const cell = mc.get() orelse return 0;
    const g = cell.borrow();
    defer g.deinit();
    return g.get().*;
}

/// Whether a live `subList` view's backing changed structurally not
/// through the view (or a descendant) — the CME predicate. The freeze bit
/// is masked so a leaked-but-unmodified builder view still reads after
/// `build()`.
pub fn sublistViewStale(v: *const Value) bool {
    return v.sublistViewStale();
}

/// ConcurrentModificationException when `sublistViewStale`; read choke
/// points call this before serving.
pub fn sublistComodGuard(a: Allocator, v: *const Value) Error!?EvalResult {
    if (!sublistViewStale(v)) return null;
    return try thrown(a, "kotlin.ConcurrentModificationException", null);
}

/// Live-entry prologue shared by the `Map.Entry` intrinsics: after a
/// structural map change every access throws CME; before that, the value
/// box is refreshed from the live pair so non-structural updates show
/// through.
pub fn mapEntryViewGuard(a: Allocator, v: *const Value) Error!?EvalResult {
    if (v.* != .MapEntry) return null;
    const me = v.MapEntry;
    const entries = me.backing.get() orelse return null;
    var stale = false;
    {
        const g = entries.borrow();
        defer g.deinit();
        if (g.get().mod_count.get()) |cell| {
            const cg = cell.borrow();
            stale = cg.get().* != me.exp_mod;
            cg.deinit();
        }
        if (!stale) {
            for (g.get().pairs.items) |*slot| {
                if (Value.structuralEq(&slot.key, me.key.asPtr())) {
                    const live = slot.value;
                    if (!Value.structuralEq(me.value.asPtr(), &live)) {
                        if (runtime.reclaimEnabled()) {
                            live.retain();
                            me.value.asPtr().release(a);
                        }
                        me.value.asPtr().* = live;
                    }
                    break;
                }
            }
        }
    }
    if (stale) return try thrown(a, "kotlin.ConcurrentModificationException", null);
    return null;
}
