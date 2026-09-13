//! Host fast path for bulk mutation on the Compose-vendored `PersistentVectorBuilder`,
//! rebuilding the trie in place of the interpreted one-`removeAt`-per-element shift.
//! Every builder invariant holds: leaves under `root` full, `tail` holding
//! `size - rootSize` elements, `rootShift` matching the trie height, 33-slot buffers
//! with the `ownership` marker last, `modCount` advanced once per removed element.
//! Fresh buffers are never shared with a published vector; a structural surprise bails.

const std = @import("std");
const runtime = @import("runtime");
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ArrayData = runtime.ArrayData;
const Allocator = std.mem.Allocator;

const PKG = "androidx.compose.runtime.external.kotlinx.collections.immutable.implementations.immutableList.";
const BUILDER_FQN = PKG ++ "PersistentVectorBuilder";

const LOG_BRANCH = 5;
const BRANCH = 32;
const MUTABLE_BUFFER_SIZE = 33;

var builder_class_hit = std.atomic.Value(usize).init(0);

var fn_root = std.atomic.Value(?[*]const u8).init(null);
var fn_tail = std.atomic.Value(?[*]const u8).init(null);
var fn_size = std.atomic.Value(?[*]const u8).init(null);
var fn_shift = std.atomic.Value(?[*]const u8).init(null);
var fn_owner = std.atomic.Value(?[*]const u8).init(null);
var fn_modc = std.atomic.Value(?[*]const u8).init(null);

pub fn isBuilderClass(inst: ObjRef(InstanceData)) bool {
    const g = inst.borrow();
    defer g.deinit();
    const id = g.get().class.identity();
    if (builder_class_hit.load(.monotonic) == id) return true;
    const cg = g.get().class.borrow();
    defer cg.deinit();
    if (!std.mem.eql(u8, cg.get().fqn, BUILDER_FQN)) return false;
    builder_class_hit.store(id, .monotonic);
    return true;
}

/// Append as borrowed copies; false means a structural bail.
fn collectNode(a: Allocator, arr: ArrayData, shift: u32, remaining: usize, out: *std.ArrayList(Value)) Allocator.Error!bool {
    if (remaining == 0) return true;
    if (shift == 0) {
        if (arr.len() < remaining) return false;
        var i: usize = 0;
        while (i < remaining) : (i += 1) try out.append(a, arr.get(i));
        return true;
    }
    const span = @as(usize, 1) << @intCast(shift);
    const used = (remaining + span - 1) / span;
    if (arr.len() < used) return false;
    var i: usize = 0;
    while (i < used) : (i += 1) {
        const child = arr.get(i);
        if (child != .Array) return false;
        const rem = @min(span, remaining - i * span);
        if (!try collectNode(a, child.Array, shift - LOG_BRANCH, rem, out)) return false;
    }
    return true;
}

/// A fresh 33-slot mutable buffer: `items` retained into the leading slots, Null
/// padding, ownership marker last.
fn packBuffer(a: Allocator, items: []const Value, owner: *const Value) Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacity(a, MUTABLE_BUFFER_SIZE);
    for (items) |v| {
        if (runtime.reclaimEnabled()) v.retain();
        list.appendAssumeCapacity(v);
    }
    while (list.items.len < MUTABLE_BUFFER_SIZE - 1) list.appendAssumeCapacity(Value.Null);
    if (runtime.reclaimEnabled()) owner.retain();
    list.appendAssumeCapacity(owner.*);
    return ArrayData.fromBoxedList(try runtime.ValueList.init(a, list));
}

fn asIntIndex(v: *const Value) ?i64 {
    return switch (v.*) {
        .Int => |x| @as(i64, x),
        else => null,
    };
}

const BuilderState = struct {
    root: Value,
    tail: Value,
    owner: Value,
    total: usize,
    shift: u32,
    modc: i64,

    fn rootLen(self: *const BuilderState) usize {
        return if (self.total <= BRANCH) 0 else (self.total - 1) & ~@as(usize, BRANCH - 1);
    }
};

fn readState(inst: ObjRef(InstanceData)) ?BuilderState {
    const g = inst.borrow();
    defer g.deinit();
    const d = g.get();
    const sv = d.getCached(&fn_size, "size") orelse return null;
    if (sv != .Int or sv.Int < 0) return null;
    const shv = d.getCached(&fn_shift, "rootShift") orelse return null;
    if (shv != .Int or shv.Int < 0 or shv.Int > 30 or @mod(shv.Int, 5) != 0) return null;
    const root_val = d.getCached(&fn_root, "root") orelse return null;
    if (root_val != .Array and root_val != .Null) return null;
    const tail_val = d.getCached(&fn_tail, "tail") orelse return null;
    if (tail_val != .Array) return null;
    const owner_val = d.getCached(&fn_owner, "ownership") orelse return null;
    if (owner_val != .Instance) return null;
    const mv = d.getCached(&fn_modc, "modCount") orelse return null;
    if (mv != .Int) return null;
    return .{
        .root = root_val,
        .tail = tail_val,
        .owner = owner_val,
        .total = @intCast(sv.Int),
        .shift = @intCast(shv.Int),
        .modc = mv.Int,
    };
}

fn collectAll(a: Allocator, st: *const BuilderState, out: *std.ArrayList(Value)) Allocator.Error!bool {
    const root_len = st.rootLen();
    const tail_len = st.total - root_len;
    if (st.tail.Array.len() < tail_len) return false;
    if (root_len > 0) {
        if (st.root != .Array) return false;
        if (!try collectNode(a, st.root.Array, st.shift, root_len, out)) return false;
    }
    var i: usize = 0;
    while (i < tail_len) : (i += 1) try out.append(a, st.tail.Array.get(i));
    return true;
}

/// Rebuild root/tail/size/rootShift from `items` in fresh owned buffers; set `modCount`.
fn writeState(a: Allocator, inst: ObjRef(InstanceData), items: []const Value, owner: *const Value, new_modc: i64) Allocator.Error!void {
    const new_size = items.len;
    var new_root: Value = .Null;
    var new_tail: Value = undefined;
    var new_shift: i64 = 0;
    if (new_size == 0) {
        new_tail = ArrayData.fromBoxedList(try runtime.ValueList.init(a, .empty));
    } else {
        const new_root_len: usize = if (new_size <= BRANCH) 0 else (new_size - 1) & ~@as(usize, BRANCH - 1);
        new_tail = try packBuffer(a, items[new_root_len..], owner);
        if (new_root_len > 0) {
            // Full leaves, then parent levels of 32 until one node remains.
            var nodes: std.ArrayList(Value) = .empty;
            defer nodes.deinit(a);
            var off: usize = 0;
            while (off < new_root_len) : (off += BRANCH) {
                try nodes.append(a, try packBuffer(a, items[off .. off + BRANCH], owner));
            }
            while (nodes.items.len > 1) {
                new_shift += LOG_BRANCH;
                var parents: std.ArrayList(Value) = .empty;
                var j: usize = 0;
                while (j < nodes.items.len) : (j += BRANCH) {
                    const end = @min(j + BRANCH, nodes.items.len);
                    try parents.append(a, try packBuffer(a, nodes.items[j..end], owner));
                }
                // Parents retained the children on store; drop the build list's refs.
                if (runtime.reclaimEnabled()) for (nodes.items) |n| n.release(a);
                nodes.deinit(a);
                nodes = parents;
            }
            new_root = nodes.items[0];
            nodes.clearRetainingCapacity();
        }
    }
    const g = inst.borrowMut();
    defer g.deinit();
    const d = g.get();
    try d.define(a, "root", new_root);
    try d.define(a, "tail", new_tail);
    try d.define(a, "size", Value.newInt(@intCast(new_size)));
    try d.define(a, "rootShift", Value.newInt(new_shift));
    try d.define(a, "modCount", Value.newInt(new_modc));
}

/// Serve `builder.removeRange(from, to)`: Unit on success, null bails to the body.
pub fn tryRemoveRange(a: Allocator, inst: ObjRef(InstanceData), from_v: *const Value, to_v: *const Value) Allocator.Error!?Value {
    const from_i = asIntIndex(from_v) orelse return null;
    const to_i = asIntIndex(to_v) orelse return null;
    if (!isBuilderClass(inst)) return null;
    const st = readState(inst) orelse return null;
    if (from_i < 0 or to_i > st.total or from_i > to_i) return null;
    const from: usize = @intCast(from_i);
    const to: usize = @intCast(to_i);
    const count = to - from;
    if (count == 0) return Value.Unit;

    var all: std.ArrayList(Value) = .empty;
    defer all.deinit(a);
    try all.ensureTotalCapacity(a, st.total);
    if (!try collectAll(a, &st, &all)) return null;
    if (all.items.len != st.total) return null;

    var kept: std.ArrayList(Value) = .empty;
    defer kept.deinit(a);
    try kept.ensureTotalCapacity(a, st.total - count);
    kept.appendSliceAssumeCapacity(all.items[0..from]);
    kept.appendSliceAssumeCapacity(all.items[to..]);
    try writeState(a, inst, kept.items, &st.owner, st.modc + @as(i64, @intCast(count)));
    return Value.Unit;
}

fn collectionItems(a: Allocator, v: *const Value, out: *std.ArrayList(Value)) Allocator.Error!bool {
    switch (v.*) {
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            try out.appendSlice(a, g.get().items);
            return true;
        },
        .Array => |arr| {
            const n = arr.len();
            try out.ensureUnusedCapacity(a, n);
            var i: usize = 0;
            while (i < n) : (i += 1) out.appendAssumeCapacity(arr.get(i));
            return true;
        },
        else => return false,
    }
}

/// Serve the append-at-end `builder.addAll(elements)`: Bool on success, null bails.
pub fn tryAddAll(a: Allocator, inst: ObjRef(InstanceData), elements: *const Value) Allocator.Error!?Value {
    if (elements.* != .List and elements.* != .Array) return null;
    if (!isBuilderClass(inst)) return null;
    const st = readState(inst) orelse return null;

    var added: std.ArrayList(Value) = .empty;
    defer added.deinit(a);
    if (!try collectionItems(a, elements, &added)) return null;
    const k = added.items.len;
    if (k == 0) return .{ .Bool = false };

    const root_len = st.rootLen();
    const tail_len = st.total - root_len;
    if (st.tail.Array.len() < tail_len) return null;

    if (tail_len + k <= BRANCH) {
        // Fits in the tail: fresh owned tail, root untouched.
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(a);
        try items.ensureTotalCapacity(a, tail_len + k);
        var i: usize = 0;
        while (i < tail_len) : (i += 1) items.appendAssumeCapacity(st.tail.Array.get(i));
        items.appendSliceAssumeCapacity(added.items);
        const new_tail = try packBuffer(a, items.items, &st.owner);
        const g = inst.borrowMut();
        defer g.deinit();
        const d = g.get();
        try d.define(a, "tail", new_tail);
        try d.define(a, "size", Value.newInt(@intCast(st.total + k)));
        try d.define(a, "modCount", Value.newInt(st.modc + 1));
        return .{ .Bool = true };
    }

    // Rebuilding walks the whole list, so a tiny append onto a huge list stays on the
    // O(append) interpreted path.
    if (st.total > 1024 and k * 8 < st.total) return null;
    var all: std.ArrayList(Value) = .empty;
    defer all.deinit(a);
    try all.ensureTotalCapacity(a, st.total + k);
    if (!try collectAll(a, &st, &all)) return null;
    if (all.items.len != st.total) return null;
    try all.appendSlice(a, added.items);
    try writeState(a, inst, all.items, &st.owner, st.modc + 1);
    return .{ .Bool = true };
}
