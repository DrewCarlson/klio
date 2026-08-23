//! Host fast paths for the Compose snapshot validity walk.
//!
//! Every snapshot-state read and write resolves its record through the
//! private top-level `readable(r, id, invalid)` / `valid(...)` walk in
//! Snapshot.kt — a linked-list scan with a `SnapshotIdSet` bit-set
//! probe per record. Interpreted, that is ~16 framed calls per map
//! write; the data is host-readable (SnapshotId = Long in the engine
//! actuals, the set is two Longs + a bound), so the host serves the
//! whole walk.
//!
//! Exactness: any missing field, unexpected tag, or a set with a
//! non-null `belowBound` overflow array bails to the interpreted body.
//! The walk itself takes no references — the chain is rooted by the
//! caller's live arguments — and only the returned record is retained.

const std = @import("std");
const runtime = @import("runtime");
const Value = runtime.Value;

pub const Route = enum(u8) { unknown = 0, none = 1, readable = 2, valid = 3 };

/// Classify a Func for host service, memoized by the caller into
/// `Func.host_route`. Matched by fqn + the 3-arg shape whose last
/// parameter is a SnapshotIdSet (excludes the same-named record
/// extensions).
pub fn classify(fqn: []const u8, n_params: usize, last_param_ty: []const u8) Route {
    if (n_params != 3) return .none;
    if (!std.mem.endsWith(u8, last_param_ty, "SnapshotIdSet")) return .none;
    if (std.mem.eql(u8, fqn, "androidx.compose.runtime.snapshots.readable")) return .readable;
    if (std.mem.eql(u8, fqn, "androidx.compose.runtime.snapshots.valid")) return .valid;
    return .none;
}

fn asI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Long => |x| x,
        .Int => |x| @as(i64, x),
        else => null,
    };
}

const IdSet = struct { upper: i64, lower: i64, bound: i64 };

var fn_below = std.atomic.Value(?[*]const u8).init(null);
var fn_upper = std.atomic.Value(?[*]const u8).init(null);
var fn_lower = std.atomic.Value(?[*]const u8).init(null);
var fn_bound = std.atomic.Value(?[*]const u8).init(null);
var fn_sid = std.atomic.Value(?[*]const u8).init(null);
var fn_next = std.atomic.Value(?[*]const u8).init(null);

/// Read the three scalar fields of a SnapshotIdSet; null when the shape
/// is not the expected one or the overflow array is present.
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
    // offset > 0 above the window: clear. Negative offsets would consult
    // belowBound, which readIdSet already proved null (empty).
    return false;
}

fn validId(current: i64, candidate: i64, s: IdSet) bool {
    return candidate != 0 and candidate <= current and !idSetGet(s, candidate);
}

/// `valid(currentSnapshot, candidateSnapshot, invalid)` /
/// `valid(data, snapshot, invalid)` — discriminated by the first
/// argument's tag exactly as overload resolution would.
pub fn serveValid(args: []const Value) ?Value {
    if (args.len != 3) return null;
    const s = readIdSet(&args[2]) orelse return null;
    const snap = asI64(&args[1]) orelse return null;
    if (asI64(&args[0])) |cur| {
        return .{ .Bool = validId(cur, snap, s) };
    }
    if (args[0] != .Instance) return null;
    const sid = blk: {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        const v = g.get().getCached(&fn_sid, "snapshotId") orelse return null;
        break :blk asI64(&v) orelse return null;
    };
    return .{ .Bool = validId(snap, sid, s) };
}

/// `readable(r, id, invalid)` — the record-chain walk. Returns the
/// valid record with the highest snapshotId, or Null.
pub fn serveReadable(args: []const Value) ?Value {
    if (args.len != 3) return null;
    if (args[0] != .Instance) return null;
    const id = asI64(&args[1]) orelse return null;
    const s = readIdSet(&args[2]) orelse return null;
    var current: Value = args[0];
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
    candidate.retain();
    return candidate;
}
