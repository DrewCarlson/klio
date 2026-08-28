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
    /// `Operations.pushOp(op)` and its checked wrapper `push(op)`: record the
    /// operation and advance the argument cursors.
    ops_push_op = 15,
    /// `Operations.ensureAllArgumentsPushedFor(op)`: a debug-only assertion
    /// that this build compiles out (`EnableDebugRuntimeChecks = false`), so
    /// its whole body is dead.
    ops_ensure_args = 16,
    /// `Operations.WriteScope.setInt(parameter, value)`
    ops_set_int = 17,
    /// `Operations.WriteScope.setObject(parameter, value)`
    ops_set_object = 18,
    /// `IntArray.slotAnchor(address)` — the gap-buffer group table's data
    /// anchor plus the slot bits above it.
    slot_anchor = 19,
    /// `SlotWriter.dataAnchorToDataIndex(anchor, gapLen, capacity)` — pure
    /// arithmetic that reads none of the writer's state.
    data_anchor_to_index = 20,
    /// The link-buffer changelist's `pushOp`/`push`: the gap-buffer body plus
    /// `requiresApplication` raised from the operation's visibility, which is
    /// a stored constructor property there.
    ops_push_op_link = 21,
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
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.composer.gapbuffer.slotAnchor")) return .slot_anchor;
        if (std.mem.endsWith(u8, fqn, "gapbuffer.changelist.Operations.pushOp") or
            std.mem.endsWith(u8, fqn, "gapbuffer.changelist.Operations.push")) return .ops_push_op;
        if (std.mem.endsWith(u8, fqn, "linkbuffer.changelist.Operations.pushOp") or
            std.mem.endsWith(u8, fqn, "linkbuffer.changelist.Operations.push")) return .ops_push_op_link;
        if (std.mem.endsWith(u8, fqn, "changelist.Operations.ensureAllArgumentsPushedFor")) return .ops_ensure_args;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.push")) return .int_stack_push;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.peekOr")) return .int_stack_peek_or;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.popOr")) return .int_stack_pop_or;
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.IntStack.peek")) return .int_stack_peek_at;
        return .none;
    }
    if (n_params == 4) {
        if (std.mem.endsWith(u8, fqn, "gapbuffer.SlotWriter.dataAnchorToDataIndex")) return .data_anchor_to_index;
        return .none;
    }
    if (n_params == 3) {
        if (std.mem.endsWith(u8, fqn, "Operations.WriteScope.setInt")) return .ops_set_int;
        if (std.mem.endsWith(u8, fqn, "Operations.WriteScope.setObject")) return .ops_set_object;
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

pub fn servePush(allocator: std.mem.Allocator, args: []const Value) ?Value {
    const s = readStack(&args[0]) orelse return null;
    const value = asI32(&args[1]) orelse return null;
    // A full stack takes the interpreted `resize()` path.
    if (s.tos < 0 or @as(usize, @intCast(s.tos)) >= s.len) return null;
    s.slots.set(allocator, @intCast(s.tos), .{ .Int = value });
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

threadlocal var fn_opcodes: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_opcodes_size: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_int_args: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_int_args_size: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_obj_args: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_obj_args_size: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_ints: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_objects: std.atomic.Value(?[*]const u8) = .init(null);

const OpCounts = struct { ints: i32, objects: i32 };

fn readOpCounts(op: *const Value) ?OpCounts {
    if (op.* != .Instance) return null;
    const g = op.Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const iv = inst.getCached(&fn_ints, "ints") orelse return null;
    const ov = inst.getCached(&fn_objects, "objects") orelse return null;
    return .{ .ints = asI32(&iv) orelse return null, .objects = asI32(&ov) orelse return null };
}

/// `Operations.pushOp`: bounds-check the three parallel stores the upstream
/// body performs, then record the operation and advance the cursors. Any
/// stack that must grow bails to the interpreted body, which resizes.
pub fn servePushOp(allocator: std.mem.Allocator, args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const counts = readOpCounts(&args[1]) orelse return null;
    if (counts.ints < 0 or counts.objects < 0) return null;

    var op_codes: runtime.ArrayData = undefined;
    var op_size: i32 = 0;
    var int_size: i32 = 0;
    var obj_size: i32 = 0;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        const codes_v = inst.getCached(&fn_opcodes, "opCodes") orelse return null;
        if (codes_v != .Array or codes_v.Array.prim != null) return null;
        const int_args_v = inst.getCached(&fn_int_args, "intArgs") orelse return null;
        if (int_args_v != .Array or int_args_v.Array.prim != .Int) return null;
        const obj_args_v = inst.getCached(&fn_obj_args, "objectArgs") orelse return null;
        if (obj_args_v != .Array or obj_args_v.Array.prim != null) return null;

        const os = inst.getCached(&fn_opcodes_size, "opCodesSize") orelse return null;
        const is = inst.getCached(&fn_int_args_size, "intArgsSize") orelse return null;
        const bs = inst.getCached(&fn_obj_args_size, "objectArgsSize") orelse return null;
        op_size = asI32(&os) orelse return null;
        int_size = asI32(&is) orelse return null;
        obj_size = asI32(&bs) orelse return null;

        if (op_size < 0 or int_size < 0 or obj_size < 0) return null;
        if (@as(usize, @intCast(op_size)) >= codes_v.Array.len()) return null;
        if (@as(i64, int_size) + counts.ints > @as(i64, @intCast(int_args_v.Array.len()))) return null;
        if (@as(i64, obj_size) + counts.objects > @as(i64, @intCast(obj_args_v.Array.len()))) return null;
        op_codes = codes_v.Array;
    }
    // The boxed store retains through `ArrayData.set` and its mutable borrow
    // raises the generational write barrier.
    op_codes.set(allocator, @intCast(op_size), args[1]);
    const g = args[0].Instance.borrowMut();
    defer g.deinit();
    const inst = g.get();
    if (!inst.set("opCodesSize", .{ .Int = op_size + 1 })) return null;
    if (!inst.set("intArgsSize", .{ .Int = int_size + counts.ints })) return null;
    if (!inst.set("objectArgsSize", .{ .Int = obj_size + counts.objects })) return null;
    return .{ .Unit = {} };
}

threadlocal var fn_stack: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_offset: std.atomic.Value(?[*]const u8) = .init(null);

/// The `WriteScope` value class wraps the `Operations` it writes into. A
/// boxed scope carries it in `stack`; an unboxed one IS the stack.
fn scopeStack(recv: *const Value) ?Value {
    if (recv.* != .Instance) return null;
    const g = recv.Instance.borrow();
    defer g.deinit();
    if (g.get().getCached(&fn_stack, "stack")) |st| {
        if (st == .Instance) return st;
        return null;
    }
    return recv.*;
}

/// The offset of an `ObjectParameter`, boxed or not.
fn paramOffset(v: *const Value) ?i32 {
    if (asI32(v)) |i| return i;
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    const off = g.get().getCached(&fn_offset, "offset") orelse return null;
    return asI32(&off);
}

const TopArgs = struct { arr: runtime.ArrayData, index: i32 };

/// `intArgs[intArgsSize - peekOperation().ints + parameter]`, or the object
/// equivalent. Declines whenever the stack is empty or the index escapes.
fn topSlot(stack: *const Value, parameter: i32, comptime objects: bool) ?TopArgs {
    const g = stack.Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const codes_v = inst.getCached(&fn_opcodes, "opCodes") orelse return null;
    if (codes_v != .Array or codes_v.Array.prim != null) return null;
    const os = inst.getCached(&fn_opcodes_size, "opCodesSize") orelse return null;
    const op_size = asI32(&os) orelse return null;
    if (op_size <= 0 or @as(usize, @intCast(op_size)) > codes_v.Array.len()) return null;
    const op = codes_v.Array.get(@intCast(op_size - 1));
    const counts = readOpCounts(&op) orelse return null;

    const arr_v = inst.getCached(
        if (objects) &fn_obj_args else &fn_int_args,
        if (objects) "objectArgs" else "intArgs",
    ) orelse return null;
    if (arr_v != .Array) return null;
    if (objects) {
        if (arr_v.Array.prim != null) return null;
    } else {
        if (arr_v.Array.prim != .Int) return null;
    }
    const sv = inst.getCached(
        if (objects) &fn_obj_args_size else &fn_int_args_size,
        if (objects) "objectArgsSize" else "intArgsSize",
    ) orelse return null;
    const size = asI32(&sv) orelse return null;
    const used = if (objects) counts.objects else counts.ints;
    const idx = size - used + parameter;
    if (idx < 0 or @as(usize, @intCast(idx)) >= arr_v.Array.len()) return null;
    return .{ .arr = arr_v.Array, .index = idx };
}

pub fn serveSetInt(allocator: std.mem.Allocator, args: []const Value) ?Value {
    const stack = scopeStack(&args[0]) orelse return null;
    const parameter = asI32(&args[1]) orelse return null;
    const value = asI32(&args[2]) orelse return null;
    const slot = topSlot(&stack, parameter, false) orelse return null;
    slot.arr.set(allocator, @intCast(slot.index), .{ .Int = value });
    return .{ .Unit = {} };
}

pub fn serveSetObject(allocator: std.mem.Allocator, args: []const Value) ?Value {
    const stack = scopeStack(&args[0]) orelse return null;
    const parameter = paramOffset(&args[1]) orelse return null;
    const slot = topSlot(&stack, parameter, true) orelse return null;
    slot.arr.set(allocator, @intCast(slot.index), args[2]);
    return .{ .Unit = {} };
}

threadlocal var fn_visible: std.atomic.Value(?[*]const u8) = .init(null);

/// The link-buffer changelist additionally aggregates the operation's
/// visibility into `requiresApplication`. That flag is a stored constructor
/// property of `Operation`, so the host reads it directly.
pub fn servePushOpLink(allocator: std.mem.Allocator, args: []const Value) ?Value {
    if (args[1] != .Instance) return null;
    const visible = blk: {
        const g = args[1].Instance.borrow();
        defer g.deinit();
        const v = g.get().getCached(&fn_visible, "isExternallyVisible") orelse return null;
        break :blk switch (v) {
            .Bool => |b| b,
            else => return null,
        };
    };
    const pushed = servePushOp(allocator, args) orelse return null;
    if (visible) {
        const g = args[0].Instance.borrowMut();
        defer g.deinit();
        if (!g.get().set("requiresApplication", .{ .Bool = true })) return null;
    }
    return pushed;
}

/// `groups[address * 5 + 4] + countOneBits(groups[address * 5 + 1] shr 28)`.
/// Kotlin's `shr` is arithmetic and `countOneBits` counts the 32-bit pattern,
/// so the shift is signed and the population count unsigned.
pub fn serveSlotAnchor(args: []const Value) ?Value {
    if (args[0] != .Array) return null;
    const arr = args[0].Array;
    if (arr.prim != .Int) return null;
    const address = asI32(&args[1]) orelse return null;
    if (address < 0) return null;
    const slot = @as(i64, address) * 5;
    if (slot + 4 >= @as(i64, @intCast(arr.len()))) return null;
    const anchor_v = arr.get(@intCast(slot + 4));
    const info_v = arr.get(@intCast(slot + 1));
    const anchor = asI32(&anchor_v) orelse return null;
    const info = asI32(&info_v) orelse return null;
    const shifted: i32 = info >> 28;
    const bits: i32 = @intCast(@popCount(@as(u32, @bitCast(shifted))));
    return .{ .Int = anchor +% bits };
}

/// `if (anchor < 0) (capacity - gapLen) + anchor + 1 else anchor`
pub fn serveDataAnchorToDataIndex(args: []const Value) ?Value {
    const anchor = asI32(&args[1]) orelse return null;
    if (anchor >= 0) return .{ .Int = anchor };
    const gap_len = asI32(&args[2]) orelse return null;
    const capacity = asI32(&args[3]) orelse return null;
    return .{ .Int = (capacity -% gap_len) +% anchor +% 1 };
}

/// The argument-completeness assertion compiles out in this build, so the
/// call has no effect at all.
pub fn serveEnsureArgs(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
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
