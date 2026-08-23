//! Host fast path for structural equality of the Compose-vendored
//! persistent hash map (`androidx.compose.runtime.external.kotlinx.
//! collections.immutable.implementations.immutableMap.PersistentHashMap`).
//!
//! The vendored class has no `equals` override, so `newMap == oldMap`
//! dispatches `AbstractMap.equals` — an interpreted walk that re-gets
//! every entry through the trie. `SnapshotStateMap.mutate` runs that
//! compare on every optimistic-retry attempt, and a replace keeps the
//! sizes equal so it never short-circuits; under concurrent writers the
//! walk dominates the whole workload.
//!
//! CHAMP tries are canonical: content-equal maps have identical node
//! structure, and a one-key update shares every untouched subtree with
//! its parent map. Comparing the tries directly with node-identity
//! pruning gives the same structural-equality answer while touching
//! only the changed path. Collision nodes (past MAX_SHIFT) hold their
//! entries in insertion order, so they compare unordered.
//!
//! Exactness rule: the fast path answers only when every compared key
//! and value is a scalar/string/null — values the host owns equality
//! for. Any other element (an instance whose `equals` could be
//! user-defined) bails to the interpreted dispatch by returning null.

const std = @import("std");
const runtime = @import("runtime");
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

const PKG = "androidx.compose.runtime.external.kotlinx.collections.immutable.implementations.immutableMap.";
const MAP_FQN = PKG ++ "PersistentHashMap";
const NODE_FQN = PKG ++ "TrieNode";

/// Bits of hash consumed per trie level; a child of a MAX_SHIFT-level
/// node is a collision node (mirrors the vendored LOG_MAX_BRANCHING_
/// FACTOR = 5, MAX_SHIFT = 30).
const LOG_BRANCH = 5;
const MAX_SHIFT = 30;

var map_class_hit = std.atomic.Value(usize).init(0);
var node_class_hit = std.atomic.Value(usize).init(0);

var fn_datamap = std.atomic.Value(?[*]const u8).init(null);
var fn_nodemap = std.atomic.Value(?[*]const u8).init(null);
var fn_buffer = std.atomic.Value(?[*]const u8).init(null);
var fn_size = std.atomic.Value(?[*]const u8).init(null);
var fn_node = std.atomic.Value(?[*]const u8).init(null);

fn classMatches(inst: ObjRef(InstanceData), hit: *std.atomic.Value(usize), fqn: []const u8) bool {
    const g = inst.borrow();
    defer g.deinit();
    const id = g.get().class.identity();
    if (hit.load(.monotonic) == id) return true;
    const cg = g.get().class.borrow();
    defer cg.deinit();
    if (!std.mem.eql(u8, cg.get().fqn, fqn)) return false;
    hit.store(id, .monotonic);
    return true;
}

/// Equality the host can answer exactly without dispatch: scalars,
/// strings, null, unit. Anything else returns null and the caller bails
/// to interpreted `equals`.
fn eqVal(a: *const Value, b: *const Value) ?bool {
    const hostable = switch (a.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char, .String, .Null, .Unit => switch (b.*) {
            .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char, .String, .Null, .Unit => true,
            else => false,
        },
        else => false,
    };
    if (!hostable) return null;
    return Value.structuralEq(a, b);
}

fn nodeEq(a: ObjRef(InstanceData), b: ObjRef(InstanceData), shift: u32) ?bool {
    if (ObjRef(InstanceData).ptrEq(a, b)) return true;
    if (!classMatches(a, &node_class_hit, NODE_FQN)) return null;
    if (!classMatches(b, &node_class_hit, NODE_FQN)) return null;
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const da = ga.get().getCached(&fn_datamap, "dataMap") orelse return null;
    const db = gb.get().getCached(&fn_datamap, "dataMap") orelse return null;
    const na = ga.get().getCached(&fn_nodemap, "nodeMap") orelse return null;
    const nb = gb.get().getCached(&fn_nodemap, "nodeMap") orelse return null;
    if (da != .Int or db != .Int or na != .Int or nb != .Int) return null;
    const ba = ga.get().getCached(&fn_buffer, "buffer") orelse return null;
    const bb = gb.get().getCached(&fn_buffer, "buffer") orelse return null;
    if (ba != .Array or bb != .Array) return null;
    const abuf = ba.Array;
    const bbuf = bb.Array;
    if (shift > MAX_SHIFT) {
        // Collision nodes: flat [k, v, k, v, ...] with insertion order,
        // so match pairs unordered.
        if (abuf.len() != bbuf.len()) return false;
        var i: usize = 0;
        while (i < abuf.len()) : (i += 2) {
            const ka = abuf.get(i);
            const va = abuf.get(i + 1);
            var matched = false;
            var j: usize = 0;
            while (j < bbuf.len()) : (j += 2) {
                const kb = bbuf.get(j);
                if (eqVal(&ka, &kb) orelse return null) {
                    const vb = bbuf.get(j + 1);
                    if (!(eqVal(&va, &vb) orelse return null)) return false;
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        return true;
    }
    // Canonical shape: content-equal maps agree on both bitmaps; a
    // disagreement means the key sets differ.
    if (da.Int != db.Int or na.Int != nb.Int) return false;
    if (abuf.len() != bbuf.len()) return false;
    const entries: usize = 2 * @as(usize, @popCount(@as(u32, @bitCast(da.Int))));
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        const ea = abuf.get(i);
        const eb = bbuf.get(i);
        if (!(eqVal(&ea, &eb) orelse return null)) return false;
    }
    while (i < abuf.len()) : (i += 1) {
        const ca = abuf.get(i);
        const cb = bbuf.get(i);
        if (ca != .Instance or cb != .Instance) return null;
        if (!(nodeEq(ca.Instance, cb.Instance, shift + LOG_BRANCH) orelse return null)) return false;
    }
    return true;
}

/// Answer `a.equals(b)` for two vendored PersistentHashMap instances, or
/// null when either operand is not that class or an element needs
/// dispatched equality.
pub fn tryEquals(a: ObjRef(InstanceData), b: ObjRef(InstanceData)) ?bool {
    if (!classMatches(a, &map_class_hit, MAP_FQN)) return null;
    if (!classMatches(b, &map_class_hit, MAP_FQN)) return null;
    if (ObjRef(InstanceData).ptrEq(a, b)) return true;
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const sa = ga.get().getCached(&fn_size, "size") orelse return null;
    const sb = gb.get().getCached(&fn_size, "size") orelse return null;
    if (sa != .Int or sb != .Int) return null;
    if (sa.Int != sb.Int) return false;
    const na = ga.get().getCached(&fn_node, "node") orelse return null;
    const nb = gb.get().getCached(&fn_node, "node") orelse return null;
    if (na != .Instance or nb != .Instance) return null;
    return nodeEq(na.Instance, nb.Instance, 0);
}
