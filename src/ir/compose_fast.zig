//! Host fast paths for the Compose runtime's smallest hot helpers.
//!
//! A recomposition spends most of its calls in one-line library machinery:
//! the composer's `IntStack` of group offsets, the composite-key rotation,
//! and the changelist's stacks. Interpreted, each of those is a resolved
//! call plus a frame to run three instructions. The data is host-readable
//! (an `IntArray` and an `Int` on the receiver; a `Long` and two `Int`s for
//! the key math), so the host answers them outright.
//!
//! Exactness: every serve reproduces the upstream body, and any shape it
//! cannot prove — a missing field, a non-`Int` slot, a stack that must grow,
//! an out-of-range index — bails to the interpreted body, which then raises
//! or resizes exactly as Kotlin does.

const std = @import("std");
const runtime = @import("runtime");
const Value = runtime.Value;

pub const Route = enum(u8) {
    unknown = 0,
    none = 1,
    /// `CompositeKeyHashCode.compoundWith(segment: Int, shift: Int)`
    compound_with = 2,
    /// `CompositeKeyHashCode.unCompoundWith(segment: Int, shift: Int)`
    uncompound_with = 3,
    int_stack_push = 4,
    int_stack_pop = 5,
    int_stack_peek = 6,
    int_stack_peek2 = 7,
    int_stack_peek_at = 8,
    int_stack_peek_or = 9,
    int_stack_pop_or = 10,
    int_stack_is_empty = 11,
    int_stack_is_not_empty = 12,
    int_stack_clear = 13,
    int_stack_size = 14,
};

/// Classify once per `Func` (the caller memoizes into `func.host_route`).
pub fn classify(fqn: []const u8, n_params: usize) Route {
    if (n_params == 1) {
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.pop")) return .int_stack_pop;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.peek")) return .int_stack_peek;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.peek2")) return .int_stack_peek2;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.isEmpty")) return .int_stack_is_empty;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.isNotEmpty")) return .int_stack_is_not_empty;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.clear")) return .int_stack_clear;
        if (std.mem.eql(u8, fqn, "__get_IntStack_size")) return .int_stack_size;
        return .none;
    }
    if (n_params == 2) {
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.push")) return .int_stack_push;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.peekOr")) return .int_stack_peek_or;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.popOr")) return .int_stack_pop_or;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.peek")) return .int_stack_peek_at;
        return .none;
    }
    if (n_params == 3) {
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.compoundWith")) return .compound_with;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.unCompoundWith")) return .uncompound_with;
        return .none;
    }
    return .none;
}

fn asI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Long => |x| x,
        .Int => |x| @as(i64, x),
        else => null,
    };
}

fn asI32(v: *const Value) ?i32 {
    return switch (v.*) {
        .Int => |x| x,
        .Long => |x| if (x >= std.math.minInt(i32) and x <= std.math.maxInt(i32)) @intCast(x) else null,
        else => null,
    };
}

/// The composite key rotation. `CompositeKeyHashCode` is `Long` in the
/// engine's actuals, and `rotateLeft`/`rotateRight` take the shift mod 64.
pub fn serveCompoundWith(args: []const Value) ?Value {
    const base = asI64(&args[0]) orelse return null;
    const segment = asI32(&args[1]) orelse return null;
    const shift = asI32(&args[2]) orelse return null;
    const amount: u6 = @truncate(@as(u64, @bitCast(@as(i64, shift))));
    const rotated: i64 = @bitCast(std.math.rotl(u64, @bitCast(base), amount));
    return .{ .Long = rotated ^ @as(i64, segment) };
}

pub fn serveUnCompoundWith(args: []const Value) ?Value {
    const base = asI64(&args[0]) orelse return null;
    const segment = asI32(&args[1]) orelse return null;
    const shift = asI32(&args[2]) orelse return null;
    const amount: u6 = @truncate(@as(u64, @bitCast(@as(i64, shift))));
    const xored: u64 = @bitCast(base ^ @as(i64, segment));
    return .{ .Long = @bitCast(std.math.rotr(u64, xored, amount)) };
}

const Stack = struct {
    slots: runtime.ArrayData,
    tos: i32,
    len: usize,
};

threadlocal var fn_slots: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_tos: std.atomic.Value(?[*]const u8) = .init(null);

fn readStack(recv: *const Value) ?Stack {
    if (recv.* != .Instance) return null;
    const g = recv.Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const slots_v = inst.getCached(&fn_slots, "slots") orelse return null;
    if (slots_v != .Array) return null;
    if (slots_v.Array.prim != .Int) return null;
    const tos_v = inst.getCached(&fn_tos, "tos") orelse return null;
    const tos = asI32(&tos_v) orelse return null;
    return .{ .slots = slots_v.Array, .tos = tos, .len = slots_v.Array.len() };
}

fn slotAt(s: Stack, i: i32) ?i32 {
    if (i < 0 or @as(usize, @intCast(i)) >= s.len) return null;
    const v = s.slots.get(@intCast(i));
    return asI32(&v);
}

fn writeTos(recv: *const Value, tos: i32) bool {
    const g = recv.Instance.borrowMut();
    defer g.deinit();
    return g.get().set("tos", .{ .Int = tos });
}

pub fn servePush(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    const value = asI32(&args[1]) orelse return null;
    // A full stack takes the interpreted `resize()` path.
    if (s.tos < 0 or @as(usize, @intCast(s.tos)) >= s.len) return null;
    // A packed `IntArray` slot holds a scalar, so the store never releases
    // a previous reference and the allocator argument goes unused.
    s.slots.set(std.heap.page_allocator, @intCast(s.tos), .{ .Int = value });
    if (!writeTos(&args[0], s.tos + 1)) return null;
    return .{ .Unit = {} };
}

pub fn servePop(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    const v = slotAt(s, s.tos - 1) orelse return null;
    if (!writeTos(&args[0], s.tos - 1)) return null;
    return .{ .Int = v };
}

pub fn servePopOr(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    if (s.tos <= 0) return args[1];
    const v = slotAt(s, s.tos - 1) orelse return null;
    if (!writeTos(&args[0], s.tos - 1)) return null;
    return .{ .Int = v };
}

pub fn servePeek(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    const v = slotAt(s, s.tos - 1) orelse return null;
    return .{ .Int = v };
}

pub fn servePeek2(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    const v = slotAt(s, s.tos - 2) orelse return null;
    return .{ .Int = v };
}

pub fn servePeekAt(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    const i = asI32(&args[1]) orelse return null;
    const v = slotAt(s, i) orelse return null;
    return .{ .Int = v };
}

pub fn servePeekOr(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    const index = s.tos - 1;
    if (index < 0) return args[1];
    const v = slotAt(s, index) orelse return null;
    return .{ .Int = v };
}

pub fn serveIsEmpty(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    return .{ .Bool = s.tos == 0 };
}

pub fn serveIsNotEmpty(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    return .{ .Bool = s.tos != 0 };
}

pub fn serveClear(args: []const Value) ?Value {
    _ = readStack(&args[0]) orelse return null;
    if (!writeTos(&args[0], 0)) return null;
    return .{ .Unit = {} };
}

pub fn serveSize(args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    return .{ .Int = s.tos };
}

test "compoundWith round-trips through unCompoundWith" {
    const base: Value = .{ .Long = 0x0123_4567_89AB_CDEF };
    const seg: Value = .{ .Int = 12345 };
    const shift: Value = .{ .Int = 3 };
    const c = serveCompoundWith(&.{ base, seg, shift }).?;
    const back = serveUnCompoundWith(&.{ c, seg, shift }).?;
    try std.testing.expectEqual(base.Long, back.Long);
}

test "compoundWith matches rotateLeft xor" {
    const c = serveCompoundWith(&.{ .{ .Long = 1 }, .{ .Int = 7 }, .{ .Int = 3 } }).?;
    try std.testing.expectEqual(@as(i64, 8 ^ 7), c.Long);
}
