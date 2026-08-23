//! Host fast path for structural equality of the Compose-vendored
//! persistent vectors (`androidx.compose.runtime.external.kotlinx.
//! collections.immutable.implementations.immutableList.
//! SmallPersistentVector` / `PersistentVector`).
//!
//! Same motivation as persistent_map_eq.zig: `newList == oldList` in
//! `SnapshotStateList.mutate` dispatches an interpreted ordered walk on
//! every optimistic-retry attempt. The vector trie's node arrays are
//! immutable once built and a one-element update shares every untouched
//! subtree, so identity-pruned array comparison touches only the
//! changed path.
//!
//! Layout facts this depends on (PersistentVector.kt): a trie-based
//! vector always has size > 32 and a small vector size <= 32, so
//! content-equal lists are the same representation and a class mismatch
//! means a size mismatch; leaves under `root` are always full; `tail`
//! arrays carry capacity padding, so only the logical tail length
//! (size - rootSize, rootSize = (size-1) & ~31) is compared.
//!
//! Exactness rule matches the map path: any element the host does not
//! own equality for bails to the interpreted dispatch (null).

const std = @import("std");
const runtime = @import("runtime");
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ArrayData = runtime.ArrayData;

const PKG = "androidx.compose.runtime.external.kotlinx.collections.immutable.implementations.immutableList.";
const SMALL_FQN = PKG ++ "SmallPersistentVector";
const VEC_FQN = PKG ++ "PersistentVector";

const LOG_BRANCH = 5;

var small_class_hit = std.atomic.Value(usize).init(0);
var vec_class_hit = std.atomic.Value(usize).init(0);

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

fn sameArrayCell(a: ArrayData, b: ArrayData) bool {
    return a.cell == b.cell;
}

/// Ordered compare of the first `remaining` logical elements under a
/// pair of trie node arrays at `shift`. Slots past the used range are
/// capacity padding and never read.
fn nodeEq(a: ArrayData, b: ArrayData, shift: u32, remaining: usize) ?bool {
    if (sameArrayCell(a, b)) return true;
    if (shift == 0) {
        if (a.len() < remaining or b.len() < remaining) return null;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            const ea = a.get(i);
            const eb = b.get(i);
            if (!(eqVal(&ea, &eb) orelse return null)) return false;
        }
        return true;
    }
    const span = @as(usize, 1) << @intCast(shift);
    const used = (remaining + span - 1) / span;
    if (a.len() < used or b.len() < used) return null;
    var i: usize = 0;
    while (i < used) : (i += 1) {
        const ca = a.get(i);
        const cb = b.get(i);
        if (ca != .Array or cb != .Array) return null;
        const rem = @min(span, remaining - i * span);
        if (!(nodeEq(ca.Array, cb.Array, shift - LOG_BRANCH, rem) orelse return null)) return false;
    }
    return true;
}

/// Answer `a.equals(b)` for two vendored persistent-vector instances,
/// or null when either operand is another class or an element needs
/// dispatched equality.
pub fn tryEquals(a: ObjRef(InstanceData), b: ObjRef(InstanceData)) ?bool {
    const a_small = classMatches(a, &small_class_hit, SMALL_FQN);
    const a_vec = !a_small and classMatches(a, &vec_class_hit, VEC_FQN);
    if (!a_small and !a_vec) return null;
    const b_small = classMatches(b, &small_class_hit, SMALL_FQN);
    const b_vec = !b_small and classMatches(b, &vec_class_hit, VEC_FQN);
    if (!b_small and !b_vec) return null;
    if (ObjRef(InstanceData).ptrEq(a, b)) return true;
    // Small holds <= 32 elements and the trie vector > 32, so different
    // representations cannot be content-equal.
    if (a_small != b_small) return false;
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    if (a_small) {
        const ba = ga.get().get("buffer") orelse return null;
        const bb = gb.get().get("buffer") orelse return null;
        if (ba != .Array or bb != .Array) return null;
        if (sameArrayCell(ba.Array, bb.Array)) return true;
        const n = ba.Array.len();
        if (n != bb.Array.len()) return false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ea = ba.Array.get(i);
            const eb = bb.Array.get(i);
            if (!(eqVal(&ea, &eb) orelse return null)) return false;
        }
        return true;
    }
    const sa = ga.get().get("size") orelse return null;
    const sb = gb.get().get("size") orelse return null;
    if (sa != .Int or sb != .Int) return null;
    if (sa.Int != sb.Int) return false;
    const sha = ga.get().get("rootShift") orelse return null;
    const shb = gb.get().get("rootShift") orelse return null;
    if (sha != .Int or shb != .Int) return null;
    // Equal sizes fix the trie height; a mismatch here is malformed.
    if (sha.Int != shb.Int or sha.Int < 0) return null;
    const ta = ga.get().get("tail") orelse return null;
    const tb = gb.get().get("tail") orelse return null;
    const ra = ga.get().get("root") orelse return null;
    const rb = gb.get().get("root") orelse return null;
    if (ta != .Array or tb != .Array or ra != .Array or rb != .Array) return null;
    const size: usize = @intCast(sa.Int);
    if (size == 0) return null;
    const root_len: usize = (size - 1) & ~@as(usize, 31);
    const tail_len = size - root_len;
    if (!sameArrayCell(ta.Array, tb.Array)) {
        if (ta.Array.len() < tail_len or tb.Array.len() < tail_len) return null;
        var i: usize = 0;
        while (i < tail_len) : (i += 1) {
            const ea = ta.Array.get(i);
            const eb = tb.Array.get(i);
            if (!(eqVal(&ea, &eb) orelse return null)) return false;
        }
    }
    return nodeEq(ra.Array, rb.Array, @intCast(sha.Int), root_len);
}
