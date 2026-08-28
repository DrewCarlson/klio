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
    /// `SlotReader.next()` — the hot had-a-slot branch only.
    sr_next = 22,
    /// `SlotReader.groupKey` getter / `groupKey(index)` / `isGroupEnd` /
    /// `nodeCount` getter / `nodeCount(index)`.
    sr_group_key_get = 23,
    sr_is_group_end_get = 24,
    sr_node_count_get = 25,
    sr_node_count_at = 26,
    sr_group_key_at = 27,
    /// Top-level `IntArray.parentAnchor(address)` (file-private, lowered as a
    /// package function).
    gap_parent_anchor = 28,
    /// `SlotWriter.dataIndex(index)` — gap-adjusted anchor arithmetic.
    sw_data_index = 29,
    /// `RecomposeScopeImpl.requiresRecompose` accessor pair — one bit of the
    /// packed `flags` field.
    rsi_req_recompose_set = 30,
    rsi_req_recompose_get = 31,
    /// `GapComposer.validateNodeNotExpected()` — a no-op unless it raises.
    gap_validate_node = 32,
    /// `SlotReader.startGroup()` / `endGroup()` — group cursor bookkeeping.
    sr_start_group = 33,
    sr_end_group = 34,
    /// `Operations.OpIterator.next/getInt/getObject` — the changelist drain
    /// cursor (identical bodies in both composers).
    op_iter_next = 35,
    op_iter_get_int = 36,
    op_iter_get_object = 37,
};

/// Classify once per `Func` (the caller memoizes into `func.host_route`).
pub fn classify(fqn: []const u8, n_params: usize) Route {
    if (n_params == 1) {
        if (std.mem.endsWith(u8, fqn, "gapbuffer.SlotReader.next")) return .sr_next;
        if (std.mem.endsWith(u8, fqn, "gapbuffer.SlotReader.startGroup")) return .sr_start_group;
        if (std.mem.endsWith(u8, fqn, "gapbuffer.SlotReader.endGroup")) return .sr_end_group;
        if (std.mem.endsWith(u8, fqn, ".changelist.Operations.OpIterator.next")) return .op_iter_next;
        if (std.mem.endsWith(u8, fqn, "GapComposer.validateNodeNotExpected")) return .gap_validate_node;
        if (std.mem.eql(u8, fqn, "__get_SlotReader_groupKey")) return .sr_group_key_get;
        if (std.mem.eql(u8, fqn, "__get_SlotReader_isGroupEnd")) return .sr_is_group_end_get;
        if (std.mem.eql(u8, fqn, "__get_SlotReader_nodeCount")) return .sr_node_count_get;
        if (std.mem.eql(u8, fqn, "__get_RecomposeScopeImpl_requiresRecompose")) return .rsi_req_recompose_get;
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
        if (std.mem.eql(u8, fqn, "androidx.compose.runtime.composer.gapbuffer.parentAnchor")) return .gap_parent_anchor;
        if (std.mem.endsWith(u8, fqn, "gapbuffer.SlotReader.nodeCount")) return .sr_node_count_at;
        if (std.mem.endsWith(u8, fqn, "gapbuffer.SlotReader.groupKey")) return .sr_group_key_at;
        if (std.mem.endsWith(u8, fqn, "gapbuffer.SlotWriter.dataIndex")) return .sw_data_index;
        if (std.mem.endsWith(u8, fqn, ".changelist.Operations.OpIterator.getInt")) return .op_iter_get_int;
        if (std.mem.endsWith(u8, fqn, ".changelist.Operations.OpIterator.getObject")) return .op_iter_get_object;
        if (std.mem.eql(u8, fqn, "__set_RecomposeScopeImpl_requiresRecompose")) return .rsi_req_recompose_set;
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

// ---- Slot-table reader / writer / changelist-iterator serves ----------------
//
// All of these are field-and-index math over the gap-buffer group table
// (five ints per group: key, info, parent anchor, size, data anchor) and the
// changelist's parallel arrays. Reads and validations run first under a
// shared borrow; writes run after, under a mutable borrow, and only once
// every written field has been proven present — a serve must never leave an
// instance half-mutated before declining.

threadlocal var fn_empty_count: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_cur_slot: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_cur_slot_end: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_had_next: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_slots_field: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_cur_group: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_cur_end: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_groups: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_parent_f: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_groups_size: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_slots_size: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_src_map: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_slot_stack: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_flags: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_node_expected: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_group_gap_start: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_group_gap_len: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_slots_gap_len: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_op_idx: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_int_idx: std.atomic.Value(?[*]const u8) = .init(null);
threadlocal var fn_obj_idx: std.atomic.Value(?[*]const u8) = .init(null);

const GROUP_FIELDS = 5;
const GROUP_INFO_OFF = 1;
const PARENT_ANCHOR_OFF = 2;
const SIZE_OFF = 3;
const DATA_ANCHOR_OFF = 4;
const NODE_COUNT_MASK: i32 = 0x03FF_FFFF;

fn groupField(arr: runtime.ArrayData, group: i32, off: i32) ?i32 {
    if (group < 0) return null;
    const idx = @as(i64, group) * GROUP_FIELDS + off;
    if (idx < 0 or idx >= @as(i64, @intCast(arr.len()))) return null;
    const v = arr.get(@intCast(idx));
    return asI32(&v);
}

fn intField(inst: anytype, slot: *std.atomic.Value(?[*]const u8), name: []const u8) ?i32 {
    const v = inst.getCached(slot, name) orelse return null;
    return asI32(&v);
}

fn intArrayField(inst: anytype, slot: *std.atomic.Value(?[*]const u8), name: []const u8) ?runtime.ArrayData {
    const v = inst.getCached(slot, name) orelse return null;
    if (v != .Array or v.Array.prim != .Int) return null;
    return v.Array;
}

fn objArrayField(inst: anytype, slot: *std.atomic.Value(?[*]const u8), name: []const u8) ?runtime.ArrayData {
    const v = inst.getCached(slot, name) orelse return null;
    if (v != .Array or v.Array.prim != null) return null;
    return v.Array;
}

/// `slots[currentSlot++]` on the had-a-slot branch; the empty/end branch
/// returns `Composer.Empty`, which only the interpreted body can name.
pub fn serveSlotReaderNext(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    var slot_v: Value = undefined;
    var cur: i32 = 0;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        const empty = intField(inst, &fn_empty_count, "emptyCount") orelse return null;
        cur = intField(inst, &fn_cur_slot, "currentSlot") orelse return null;
        const end = intField(inst, &fn_cur_slot_end, "currentSlotEnd") orelse return null;
        if (empty > 0 or cur >= end) return null;
        const slots = objArrayField(inst, &fn_slots_field, "slots") orelse return null;
        if (cur < 0 or @as(usize, @intCast(cur)) >= slots.len()) return null;
        _ = inst.getCached(&fn_had_next, "hadNext") orelse return null;
        slot_v = slots.get(@intCast(cur));
    }
    {
        const g = args[0].Instance.borrowMut();
        defer g.deinit();
        const inst = g.get();
        if (!inst.set("hadNext", .{ .Bool = true })) return null;
        if (!inst.set("currentSlot", .{ .Int = cur + 1 })) return null;
    }
    slot_v.retain();
    return slot_v;
}

pub fn serveSlotReaderGroupKeyGet(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const cur = intField(inst, &fn_cur_group, "currentGroup") orelse return null;
    const end = intField(inst, &fn_cur_end, "currentEnd") orelse return null;
    if (cur >= end) return .{ .Int = 0 };
    const groups = intArrayField(inst, &fn_groups, "groups") orelse return null;
    const k = groupField(groups, cur, 0) orelse return null;
    return .{ .Int = k };
}

pub fn serveSlotReaderGroupKeyAt(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const index = asI32(&args[1]) orelse return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const groups = intArrayField(g.get(), &fn_groups, "groups") orelse return null;
    const k = groupField(groups, index, 0) orelse return null;
    return .{ .Int = k };
}

pub fn serveSlotReaderIsGroupEnd(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const empty = intField(inst, &fn_empty_count, "emptyCount") orelse return null;
    const cur = intField(inst, &fn_cur_group, "currentGroup") orelse return null;
    const end = intField(inst, &fn_cur_end, "currentEnd") orelse return null;
    return .{ .Bool = empty > 0 or cur == end };
}

pub fn serveSlotReaderNodeCountGet(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const cur = intField(inst, &fn_cur_group, "currentGroup") orelse return null;
    const groups = intArrayField(inst, &fn_groups, "groups") orelse return null;
    const info = groupField(groups, cur, GROUP_INFO_OFF) orelse return null;
    return .{ .Int = info & NODE_COUNT_MASK };
}

pub fn serveSlotReaderNodeCountAt(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const index = asI32(&args[1]) orelse return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const groups = intArrayField(g.get(), &fn_groups, "groups") orelse return null;
    const info = groupField(groups, index, GROUP_INFO_OFF) orelse return null;
    return .{ .Int = info & NODE_COUNT_MASK };
}

pub fn serveGapParentAnchor(args: []const Value) ?Value {
    if (args[0] != .Array) return null;
    if (args[0].Array.prim != .Int) return null;
    const address = asI32(&args[1]) orelse return null;
    const v = groupField(args[0].Array, address, PARENT_ANCHOR_OFF) orelse return null;
    return .{ .Int = v };
}

/// `groups.dataIndex(groupIndexToAddress(index))` over the writer's gaps.
pub fn serveSlotWriterDataIndex(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const index = asI32(&args[1]) orelse return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const inst = g.get();
    const gap_start = intField(inst, &fn_group_gap_start, "groupGapStart") orelse return null;
    const gap_len = intField(inst, &fn_group_gap_len, "groupGapLen") orelse return null;
    const slots_gap_len = intField(inst, &fn_slots_gap_len, "slotsGapLen") orelse return null;
    const groups = intArrayField(inst, &fn_groups, "groups") orelse return null;
    const slots = objArrayField(inst, &fn_slots_field, "slots") orelse return null;
    const address: i32 = index + (if (index < gap_start) @as(i32, 0) else gap_len);
    const capacity: i64 = @intCast(groups.len() / GROUP_FIELDS);
    if (address >= capacity) {
        return .{ .Int = @as(i32, @intCast(@as(i64, @intCast(slots.len())) - slots_gap_len)) };
    }
    const anchor = groupField(groups, address, DATA_ANCHOR_OFF) orelse return null;
    if (anchor >= 0) return .{ .Int = anchor };
    const cap_slots: i32 = @intCast(slots.len());
    return .{ .Int = (cap_slots -% slots_gap_len) +% anchor +% 1 };
}

const REQUIRES_RECOMPOSE_FLAG: i32 = 0x008;

pub fn serveRsiRequiresRecomposeGet(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const flags = intField(g.get(), &fn_flags, "flags") orelse return null;
    return .{ .Bool = flags & REQUIRES_RECOMPOSE_FLAG != 0 };
}

pub fn serveRsiRequiresRecomposeSet(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const value = switch (args[1]) {
        .Bool => |b| b,
        else => return null,
    };
    var flags: i32 = 0;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        flags = intField(g.get(), &fn_flags, "flags") orelse return null;
    }
    const updated = if (value) flags | REQUIRES_RECOMPOSE_FLAG else flags & ~REQUIRES_RECOMPOSE_FLAG;
    const g = args[0].Instance.borrowMut();
    defer g.deinit();
    if (!g.get().set("flags", .{ .Int = updated })) return null;
    return .{ .Unit = {} };
}

/// `runtimeCheck(!nodeExpected)` — a no-op unless it must raise, and the
/// raising path belongs to the interpreted body.
pub fn serveValidateNodeNotExpected(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    const g = args[0].Instance.borrow();
    defer g.deinit();
    const v = g.get().getCached(&fn_node_expected, "nodeExpected") orelse return null;
    return switch (v) {
        .Bool => |b| if (b) null else .{ .Unit = {} },
        else => null,
    };
}

/// `startGroup()`: cursor bookkeeping plus one push onto the reader's
/// IntStack. Declines when the stack must grow, the precondition would
/// fail, or a source-information map is attached.
pub fn serveSlotReaderStartGroup(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    var stack_v: Value = undefined;
    var push_v: i32 = 0;
    var new_parent: i32 = 0;
    var new_end: i32 = 0;
    var new_group: i32 = 0;
    var new_slot: i32 = 0;
    var new_slot_end: i32 = 0;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        const empty = intField(inst, &fn_empty_count, "emptyCount") orelse return null;
        if (empty > 0) return .{ .Unit = {} };
        const src = inst.getCached(&fn_src_map, "sourceInformationMap") orelse return null;
        if (src != .Null) return null;
        const parent = intField(inst, &fn_parent_f, "parent") orelse return null;
        const cur = intField(inst, &fn_cur_group, "currentGroup") orelse return null;
        const groups = intArrayField(inst, &fn_groups, "groups") orelse return null;
        const pa = groupField(groups, cur, PARENT_ANCHOR_OFF) orelse return null;
        if (pa != parent) return null;
        const cur_slot = intField(inst, &fn_cur_slot, "currentSlot") orelse return null;
        const cur_slot_end = intField(inst, &fn_cur_slot_end, "currentSlotEnd") orelse return null;
        const groups_size = intField(inst, &fn_groups_size, "groupsSize") orelse return null;
        const slots_size = intField(inst, &fn_slots_size, "slotsSize") orelse return null;
        stack_v = inst.getCached(&fn_slot_stack, "currentSlotStack") orelse return null;
        if (stack_v != .Instance) return null;

        push_v = if (cur_slot == 0 and cur_slot_end == 0) -1 else cur_slot;
        const size = groupField(groups, cur, SIZE_OFF) orelse return null;
        const anchor = groupField(groups, cur, DATA_ANCHOR_OFF) orelse return null;
        const info = groupField(groups, cur, GROUP_INFO_OFF) orelse return null;
        new_parent = cur;
        new_end = cur +% size;
        new_group = cur + 1;
        new_slot = anchor +% @as(i32, @intCast(@popCount(@as(u32, @bitCast(info >> 28)))));
        new_slot_end = if (cur >= groups_size - 1)
            slots_size
        else
            groupField(groups, cur + 1, DATA_ANCHOR_OFF) orelse return null;
    }
    // The IntStack push first: it is the only step that can decline (a full
    // stack resizes on the interpreted path), and nothing is written before
    // it succeeds.
    const s = readStack(&stack_v) orelse return null;
    if (s.tos < 0 or @as(usize, @intCast(s.tos)) >= s.len) return null;
    s.slots.set(std.heap.page_allocator, @intCast(s.tos), .{ .Int = push_v });
    if (!writeTos(&stack_v, s.tos + 1)) return null;
    const g = args[0].Instance.borrowMut();
    defer g.deinit();
    const inst = g.get();
    if (!inst.set("parent", .{ .Int = new_parent })) return null;
    if (!inst.set("currentEnd", .{ .Int = new_end })) return null;
    if (!inst.set("currentGroup", .{ .Int = new_group })) return null;
    if (!inst.set("currentSlot", .{ .Int = new_slot })) return null;
    if (!inst.set("currentSlotEnd", .{ .Int = new_slot_end })) return null;
    return .{ .Unit = {} };
}

/// `endGroup()`: the inverse bookkeeping plus one IntStack pop.
pub fn serveSlotReaderEndGroup(args: []const Value) ?Value {
    if (args[0] != .Instance) return null;
    var stack_v: Value = undefined;
    var new_parent: i32 = 0;
    var new_end: i32 = 0;
    var groups_size: i32 = 0;
    var slots_size: i32 = 0;
    var groups: runtime.ArrayData = undefined;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        const empty = intField(inst, &fn_empty_count, "emptyCount") orelse return null;
        if (empty != 0) return .{ .Unit = {} };
        const cur = intField(inst, &fn_cur_group, "currentGroup") orelse return null;
        const end = intField(inst, &fn_cur_end, "currentEnd") orelse return null;
        if (cur != end) return null;
        const parent = intField(inst, &fn_parent_f, "parent") orelse return null;
        if (parent < 0) return null;
        groups = intArrayField(inst, &fn_groups, "groups") orelse return null;
        groups_size = intField(inst, &fn_groups_size, "groupsSize") orelse return null;
        slots_size = intField(inst, &fn_slots_size, "slotsSize") orelse return null;
        new_parent = groupField(groups, parent, PARENT_ANCHOR_OFF) orelse return null;
        if (new_parent < 0) {
            new_end = groups_size;
        } else {
            const psize = groupField(groups, new_parent, SIZE_OFF) orelse return null;
            new_end = new_parent +% psize;
        }
        _ = intField(inst, &fn_cur_slot, "currentSlot") orelse return null;
        _ = intField(inst, &fn_cur_slot_end, "currentSlotEnd") orelse return null;
        stack_v = inst.getCached(&fn_slot_stack, "currentSlotStack") orelse return null;
        if (stack_v != .Instance) return null;
    }
    const s = readStack(&stack_v) orelse return null;
    const popped = slotAt(s, s.tos - 1) orelse return null;
    var new_slot: i32 = 0;
    var new_slot_end: i32 = 0;
    if (popped >= 0) {
        new_slot = popped;
        new_slot_end = if (new_parent >= groups_size - 1)
            slots_size
        else
            groupField(groups, new_parent + 1, DATA_ANCHOR_OFF) orelse return null;
    }
    if (!writeTos(&stack_v, s.tos - 1)) return null;
    const g = args[0].Instance.borrowMut();
    defer g.deinit();
    const inst = g.get();
    if (!inst.set("parent", .{ .Int = new_parent })) return null;
    if (!inst.set("currentEnd", .{ .Int = new_end })) return null;
    if (!inst.set("currentSlot", .{ .Int = new_slot })) return null;
    if (!inst.set("currentSlotEnd", .{ .Int = new_slot_end })) return null;
    return .{ .Unit = {} };
}

/// The drain cursor over the changelist's parallel arrays. The iterator is
/// an inner class: its `Operations` lives in the instance's captured outer.
fn iterOuter(recv: *const Value) ?Value {
    if (recv.* != .Instance) return null;
    const g = recv.Instance.borrow();
    defer g.deinit();
    const outer = g.get().outer orelse return null;
    if (outer != .Instance) return null;
    return outer;
}

pub fn serveOpIterNext(args: []const Value) ?Value {
    const outer = iterOuter(&args[0]) orelse return null;
    var op_idx: i32 = 0;
    var int_idx: i32 = 0;
    var obj_idx: i32 = 0;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        op_idx = intField(inst, &fn_op_idx, "opIdx") orelse return null;
        int_idx = intField(inst, &fn_int_idx, "intIdx") orelse return null;
        obj_idx = intField(inst, &fn_obj_idx, "objIdx") orelse return null;
    }
    var op_size: i32 = 0;
    var op_v: Value = undefined;
    {
        const g = outer.Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        const os = inst.getCached(&fn_opcodes_size, "opCodesSize") orelse return null;
        op_size = asI32(&os) orelse return null;
        if (op_idx >= op_size) return .{ .Bool = false };
        const codes = objArrayField(inst, &fn_opcodes, "opCodes") orelse return null;
        if (op_idx < 0 or @as(usize, @intCast(op_idx)) >= codes.len()) return null;
        op_v = codes.get(@intCast(op_idx));
    }
    const counts = readOpCounts(&op_v) orelse return null;
    const g = args[0].Instance.borrowMut();
    defer g.deinit();
    const inst = g.get();
    if (!inst.set("intIdx", .{ .Int = int_idx +% counts.ints })) return null;
    if (!inst.set("objIdx", .{ .Int = obj_idx +% counts.objects })) return null;
    if (!inst.set("opIdx", .{ .Int = op_idx + 1 })) return null;
    return .{ .Bool = op_idx + 1 < op_size };
}

pub fn serveOpIterGetInt(args: []const Value) ?Value {
    const outer = iterOuter(&args[0]) orelse return null;
    const param = asI32(&args[1]) orelse return null;
    var int_idx: i32 = 0;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        int_idx = intField(g.get(), &fn_int_idx, "intIdx") orelse return null;
    }
    const g = outer.Instance.borrow();
    defer g.deinit();
    const ints = intArrayField(g.get(), &fn_int_args, "intArgs") orelse return null;
    const idx = int_idx +% param;
    if (idx < 0 or @as(usize, @intCast(idx)) >= ints.len()) return null;
    const v = ints.get(@intCast(idx));
    return .{ .Int = asI32(&v) orelse return null };
}

pub fn serveOpIterGetObject(args: []const Value) ?Value {
    const outer = iterOuter(&args[0]) orelse return null;
    const param = paramOffset(&args[1]) orelse return null;
    var obj_idx: i32 = 0;
    {
        const g = args[0].Instance.borrow();
        defer g.deinit();
        obj_idx = intField(g.get(), &fn_obj_idx, "objIdx") orelse return null;
    }
    const g = outer.Instance.borrow();
    defer g.deinit();
    const objs = objArrayField(g.get(), &fn_obj_args, "objectArgs") orelse return null;
    const idx = obj_idx +% param;
    if (idx < 0 or @as(usize, @intCast(idx)) >= objs.len()) return null;
    const v = objs.get(@intCast(idx));
    v.retain();
    return v;
}
