//! Host fast path for structural equality of the Compose-vendored persistent vectors,
//! which `SnapshotStateList.mutate` otherwise walks interpreted on every optimistic
//! retry. Node arrays are immutable once built and an update shares every untouched
//! subtree, so identity-pruned comparison touches only the changed path. A trie vector
//! always has size > 32 and a small vector <= 32, so a class mismatch means a size
//! mismatch; leaves under `root` are full and only `tail`'s logical length
//! (size - rootSize, rootSize = (size-1) & ~31) is compared, never its padding.

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

var fn_buffer = std.atomic.Value(?[*]const u8).init(null);
var fn_size = std.atomic.Value(?[*]const u8).init(null);
var fn_shift = std.atomic.Value(?[*]const u8).init(null);
var fn_tail = std.atomic.Value(?[*]const u8).init(null);
var fn_root = std.atomic.Value(?[*]const u8).init(null);

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
    return a.cellPtr() == b.cellPtr();
}

/// Ordered compare of the first `remaining` elements; padding past them is never read.
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

/// The gate a flat-call preparer uses to stand aside.
pub fn isVectorClass(inst: ObjRef(InstanceData)) bool {
    if (classMatches(inst, &small_class_hit, SMALL_FQN)) return true;
    return classMatches(inst, &vec_class_hit, VEC_FQN);
}

/// Ordered host scan for `element`: its first index, -1 when absent, null when an
/// element needs dispatched equality.
pub fn tryIndexOf(a: ObjRef(InstanceData), element: *const Value) ?i64 {
    const hostable = switch (element.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char, .String, .Null, .Unit => true,
        else => false,
    };
    if (!hostable) return null;
    const a_small = classMatches(a, &small_class_hit, SMALL_FQN);
    const a_vec = !a_small and classMatches(a, &vec_class_hit, VEC_FQN);
    if (!a_small and !a_vec) return null;
    const ga = a.borrow();
    defer ga.deinit();
    if (a_small) {
        const ba = ga.get().getCached(&fn_buffer, "buffer") orelse return null;
        if (ba != .Array) return null;
        const n = ba.Array.len();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = ba.Array.get(i);
            if (eqVal(&e, element) orelse return null) return @intCast(i);
        }
        return -1;
    }
    const sa = ga.get().getCached(&fn_size, "size") orelse return null;
    if (sa != .Int) return null;
    const size: usize = @intCast(sa.Int);
    if (size == 0) return -1;
    const sha = ga.get().getCached(&fn_shift, "rootShift") orelse return null;
    if (sha != .Int or sha.Int < 0) return null;
    const ta = ga.get().getCached(&fn_tail, "tail") orelse return null;
    const ra = ga.get().getCached(&fn_root, "root") orelse return null;
    if (ta != .Array or ra != .Array) return null;
    const root_len: usize = (size - 1) & ~@as(usize, 31);
    const found = nodeIndexOf(ra.Array, @intCast(sha.Int), root_len, 0, element) orelse return null;
    if (found >= 0) return found;
    const tail_len = size - root_len;
    if (ta.Array.len() < tail_len) return null;
    var i: usize = 0;
    while (i < tail_len) : (i += 1) {
        const e = ta.Array.get(i);
        if (eqVal(&e, element) orelse return null) return @intCast(root_len + i);
    }
    return -1;
}

/// First index under a node covering `remaining` elements from `base`; -1 absent.
fn nodeIndexOf(arr: ArrayData, shift: u32, remaining: usize, base: usize, element: *const Value) ?i64 {
    if (remaining == 0) return -1;
    if (shift == 0) {
        if (arr.len() < remaining) return null;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            const e = arr.get(i);
            if (eqVal(&e, element) orelse return null) return @intCast(base + i);
        }
        return -1;
    }
    const span = @as(usize, 1) << @intCast(shift);
    const used = (remaining + span - 1) / span;
    if (arr.len() < used) return null;
    var i: usize = 0;
    while (i < used) : (i += 1) {
        const ca = arr.get(i);
        if (ca != .Array) return null;
        const rem = @min(span, remaining - i * span);
        const r = nodeIndexOf(ca.Array, shift - LOG_BRANCH, rem, base + i * span, element) orelse return null;
        if (r >= 0) return r;
    }
    return -1;
}

/// Null when either is another class or needs dispatched equality.
pub fn tryEquals(a: ObjRef(InstanceData), b: ObjRef(InstanceData)) ?bool {
    const a_small = classMatches(a, &small_class_hit, SMALL_FQN);
    const a_vec = !a_small and classMatches(a, &vec_class_hit, VEC_FQN);
    if (!a_small and !a_vec) return null;
    const b_small = classMatches(b, &small_class_hit, SMALL_FQN);
    const b_vec = !b_small and classMatches(b, &vec_class_hit, VEC_FQN);
    if (!b_small and !b_vec) return null;
    if (ObjRef(InstanceData).ptrEq(a, b)) return true;
    // Small holds <= 32 elements and the trie vector > 32, so the two cannot agree.
    if (a_small != b_small) return false;
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    if (a_small) {
        const ba = ga.get().getCached(&fn_buffer, "buffer") orelse return null;
        const bb = gb.get().getCached(&fn_buffer, "buffer") orelse return null;
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
    const sa = ga.get().getCached(&fn_size, "size") orelse return null;
    const sb = gb.get().getCached(&fn_size, "size") orelse return null;
    if (sa != .Int or sb != .Int) return null;
    if (sa.Int != sb.Int) return false;
    const sha = ga.get().getCached(&fn_shift, "rootShift") orelse return null;
    const shb = gb.get().getCached(&fn_shift, "rootShift") orelse return null;
    if (sha != .Int or shb != .Int) return null;
    // Equal sizes fix the trie height; a mismatch here is malformed.
    if (sha.Int != shb.Int or sha.Int < 0) return null;
    const ta = ga.get().getCached(&fn_tail, "tail") orelse return null;
    const tb = gb.get().getCached(&fn_tail, "tail") orelse return null;
    const ra = ga.get().getCached(&fn_root, "root") orelse return null;
    const rb = gb.get().getCached(&fn_root, "root") orelse return null;
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
