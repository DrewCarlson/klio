//! Compose snapshot reads for the host's write fast paths: the global
//! snapshot's id and invalid set, and the record a write would reuse. Any
//! missing field, unexpected tag, or non-null `belowBound` overflow array
//! declines, and the Kotlin body runs.

const std = @import("std");
const runtime = @import("runtime");
const Value = runtime.Value;

fn asI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Long => |x| x,
        .Int => |x| @as(i64, x),
        else => null,
    };
}

const IdSet = struct { upper: i64, lower: i64, bound: i64 };

var fn_map = std.atomic.Value(?[*]const u8).init(null);
var fn_ref = std.atomic.Value(?[*]const u8).init(null);
var fn_value = std.atomic.Value(?[*]const u8).init(null);
var fn_size = std.atomic.Value(?[*]const u8).init(null);
var fn_keys = std.atomic.Value(?[*]const u8).init(null);
var fn_values = std.atomic.Value(?[*]const u8).init(null);
var fn_below = std.atomic.Value(?[*]const u8).init(null);
var fn_upper = std.atomic.Value(?[*]const u8).init(null);
var fn_lower = std.atomic.Value(?[*]const u8).init(null);
var fn_bound = std.atomic.Value(?[*]const u8).init(null);
var fn_sid = std.atomic.Value(?[*]const u8).init(null);
var fn_next = std.atomic.Value(?[*]const u8).init(null);
var fn_invalid = std.atomic.Value(?[*]const u8).init(null);
var fn_readobs = std.atomic.Value(?[*]const u8).init(null);

/// `GlobalSnapshot` alone keeps `snapshotId`/`invalid`/`readObserver` as plain
/// stored fields; subclasses override them as computed accessors while the base
/// ctor's slots go stale, so a stored-field read needs this exact-class gate.
var global_snap_hit = std.atomic.Value(usize).init(0);

fn isGlobalSnapshotClass(v: *const Value) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const id = g.get().class.identity();
    if (global_snap_hit.load(.monotonic) == id) return true;
    const cg = g.get().class.borrow();
    defer cg.deinit();
    if (!std.mem.eql(u8, cg.get().fqn, "androidx.compose.runtime.snapshots.GlobalSnapshot")) return false;
    global_snap_hit.store(id, .monotonic);
    return true;
}

const SnapFields = struct { id: i64, set: IdSet, read_observer_null: bool };

pub const WriteGate = struct { id: i64, set: IdSet };

/// Proves only the exact-GlobalSnapshot class and a null read observer.
/// GlobalSnapshot's `writeObserver` is never null, being the ctor lambda
/// draining `globalWriteObservers`, so the caller owes the write-side proof:
/// that list must be empty before `notifyWrite` counts as a no-op.
pub fn globalWriteGate(thread_snapshot: *const Value, global_snapshot: *const Value) ?WriteGate {
    const wtrace = runtime.envOnce("KLIO_SSMPUT_TRACE") != null;
    const snap = currentSnapshotRaw(thread_snapshot, global_snapshot) orelse {
        if (wtrace) std.debug.print("[wgate] no current snapshot\n", .{});
        return null;
    };
    const f = globalSnapFields(&snap) orelse {
        if (wtrace) std.debug.print("[wgate] fields/class\n", .{});
        return null;
    };
    if (!f.read_observer_null) {
        if (wtrace) std.debug.print("[wgate] read observer\n", .{});
        return null;
    }
    return .{ .id = f.id, .set = f.set };
}

/// Returns a borrowed value, not a retained one.
pub fn recordForWrite(first: *const Value, gate: WriteGate) ?Value {
    const c = readableWalk(first, gate.id, gate.set) orelse return null;
    if (c == .Null) return null;
    return c;
}

/// Null on a shape surprise or a receiver that is not exactly GlobalSnapshot.
fn globalSnapFields(snap: *const Value) ?SnapFields {
    if (!isGlobalSnapshotClass(snap)) return null;
    const g = snap.Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const idv = inst.getCached(&fn_sid, "snapshotId") orelse return null;
    const id = asI64(&idv) orelse return null;
    const invalid = inst.getCached(&fn_invalid, "invalid") orelse return null;
    const s = readIdSet(&invalid) orelse return null;
    const obs = inst.getCached(&fn_readobs, "readObserver") orelse return null;
    return .{ .id = id, .set = s, .read_observer_null = obs == .Null };
}

/// Null when the shape is unexpected or the overflow array is present.
fn readIdSet(v: *const Value) ?IdSet {
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const below = inst.getCached(&fn_below, "belowBound") orelse return null;
    if (below != .Null) return null;
    const upper = inst.getCached(&fn_upper, "upperSet") orelse return null;
    const lower = inst.getCached(&fn_lower, "lowerSet") orelse return null;
    const bound = inst.getCached(&fn_bound, "lowerBound") orelse return null;
    return .{
        .upper = asI64(&upper) orelse return null,
        .lower = asI64(&lower) orelse return null,
        .bound = asI64(&bound) orelse return null,
    };
}

fn idSetGet(s: IdSet, id: i64) bool {
    const offset = id - s.bound;
    if (offset >= 0 and offset < 64) {
        return (@as(i64, 1) << @as(u6, @intCast(offset))) & s.lower != 0;
    }
    if (offset >= 64 and offset < 128) {
        return (@as(i64, 1) << @as(u6, @intCast(offset - 64))) & s.upper != 0;
    }
    // Above the window: clear. A negative offset would consult belowBound,
    // which `readIdSet` already proved null.
    return false;
}

fn validId(current: i64, candidate: i64, s: IdSet) bool {
    return candidate != 0 and candidate <= current and !idSetGet(s, candidate);
}

/// Unretained: callers only read fields off the result while their own
/// globals keep it rooted.
fn currentSnapshotRaw(thread_snapshot: *const Value, global_snapshot: *const Value) ?Value {
    const tid: i64 = @bitCast(@as(u64, std.Thread.getCurrentId()));
    if (tid == -1) return null;
    if (thread_snapshot.* != .Instance) return null;
    const map_cell: Value = blk: {
        const g = thread_snapshot.Instance.borrow();
        defer g.deinit();
        break :blk g.get().getCached(&fn_map, "map") orelse return null;
    };
    if (map_cell != .Instance) return null;
    const ref_cell: Value = blk: {
        const g = map_cell.Instance.borrow();
        defer g.deinit();
        break :blk g.get().getCached(&fn_ref, "ref") orelse return null;
    };
    if (ref_cell != .Instance) return null;
    const tm: Value = blk: {
        const g = ref_cell.Instance.borrow();
        defer g.deinit();
        break :blk g.get().getCached(&fn_value, "value") orelse return null;
    };
    var found: Value = .Null;
    if (tm == .Instance) {
        const g = tm.Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        const size_v = inst.getCached(&fn_size, "size") orelse return null;
        const keys_v = inst.getCached(&fn_keys, "keys") orelse return null;
        const values_v = inst.getCached(&fn_values, "values") orelse return null;
        const n: usize = switch (size_v) {
            .Int => |x| if (x < 0) return null else @intCast(x),
            else => return null,
        };
        if (keys_v != .Array or values_v != .Array) return null;
        if (keys_v.Array.primKind() != .Long) return null;
        if (n > keys_v.Array.len() or n > values_v.Array.len()) return null;
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const kv = keys_v.Array.get(mid);
            const k: i64 = switch (kv) {
                .Long => |x| x,
                else => return null,
            };
            if (k < tid) {
                lo = mid + 1;
            } else if (k > tid) {
                hi = mid;
            } else {
                found = values_v.Array.get(mid);
                break;
            }
        }
    } else if (tm != .Null) {
        return null;
    }
    return if (found != .Null and found != .Unit) found else global_snapshot.*;
}

/// The valid record with the highest snapshotId, `.Null` when none, and Zig
/// null on a shape surprise, which falls back to the interpreter.
fn readableWalk(first: *const Value, id: i64, s: IdSet) ?Value {
    if (first.* != .Instance) return null;
    var current: Value = first.*;
    var candidate: Value = .Null;
    var cand_sid: i64 = std.math.minInt(i64);
    while (current == .Instance) {
        const g = current.Instance.borrow();
        const sv = g.get().getCached(&fn_sid, "snapshotId") orelse {
            g.deinit();
            return null;
        };
        const sid = asI64(&sv) orelse {
            g.deinit();
            return null;
        };
        const next = g.get().getCached(&fn_next, "next") orelse Value.Null;
        g.deinit();
        if (validId(id, sid, s) and sid > cand_sid) {
            candidate = current;
            cand_sid = sid;
        }
        current = next;
    }
    return candidate;
}

