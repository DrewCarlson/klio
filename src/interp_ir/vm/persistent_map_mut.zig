//! Host fast path for the Compose-vendored persistent hash map BUILDER
//! mutation (`androidx.compose.runtime.external.kotlinx.collections.
//! immutable.implementations.immutableMap.PersistentHashMapBuilder`).
//!
//! `SnapshotStateMap.put` runs one `mutate { it.put(k, v) }` cycle per
//! write: `oldMap.builder()`, ONE builder.put, `builder.build()`. The
//! interpreted put walks the CHAMP trie through framed calls and copies
//! buffers через interpreted array helpers; the concurrent map stress
//! spends most of its budget there. The trie data is fully
//! host-readable (TrieNode {dataMap, nodeMap, buffer, ownedBy}), so the
//! host performs the exact `mutablePut` algorithm of the vendored
//! TrieNode.kt over the interpreted objects, and `build()`'s
//! node-identity check likewise.
//!
//! Exactness rules:
//! - Keys must be host-hashable scalars/strings whose `hashCode` and
//!   `equals` the host owns exactly (`Value.kotlinScalarHash`,
//!   same-tag structural equality). Float/Double keys bail (`equals`
//!   NaN semantics diverge from `==`), as do Null keys and any
//!   receiver/stored shape surprise.
//! - Mutations follow the vendored ownership discipline: in-place only
//!   when `node.ownedBy === builder.ownership` (instance identity),
//!   fresh TrieNode instances otherwise, minted from a template
//!   captured off live instances (exact field-name set verified; an
//!   unknown field bails before anything is touched).
//! - A bail can only happen BEFORE the first mutation: every in-place
//!   write sits at a success point after all shape checks on its path.

const std = @import("std");
const runtime = @import("runtime");

const vmhost = @import("vmhost.zig");
const host_instances = @import("host_instances.zig");

const VmHost = vmhost.VmHost;
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const ArrayData = runtime.ArrayData;

const PKG = "androidx.compose.runtime.external.kotlinx.collections.immutable.implementations.immutableMap.";
const BUILDER_FQN = PKG ++ "PersistentHashMapBuilder";
const MAP_FQN = PKG ++ "PersistentHashMap";
const NODE_FQN = PKG ++ "TrieNode";

const LOG_BRANCH = 5;
const MAX_SHIFT = 30;
const ENTRY_SIZE = 2;

var builder_class_hit = std.atomic.Value(usize).init(0);
var map_class_hit = std.atomic.Value(usize).init(0);
var node_class_hit = std.atomic.Value(usize).init(0);

var fn_map = std.atomic.Value(?[*]const u8).init(null);
var fn_ownership = std.atomic.Value(?[*]const u8).init(null);
var fn_node = std.atomic.Value(?[*]const u8).init(null);
var fn_opresult = std.atomic.Value(?[*]const u8).init(null);
var fn_modcount = std.atomic.Value(?[*]const u8).init(null);
var fn_size = std.atomic.Value(?[*]const u8).init(null);
var fn_datamap = std.atomic.Value(?[*]const u8).init(null);
var fn_nodemap = std.atomic.Value(?[*]const u8).init(null);
var fn_buffer = std.atomic.Value(?[*]const u8).init(null);
var fn_ownedby = std.atomic.Value(?[*]const u8).init(null);

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

pub fn isBuilderClass(inst: ObjRef(InstanceData)) bool {
    return classMatches(inst, &builder_class_hit, BUILDER_FQN);
}

/// Key shapes the host owns hashing AND equality for, at exactly
/// kotlinc's semantics. Float/Double stay out (`equals` treats NaN as
/// equal to itself and -0.0 as distinct from 0.0, unlike `==` which
/// structural equality mirrors); Null stays out (its hashCode is a
/// nullable-receiver dispatch, not a value property).
fn keyHostable(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .Char, .Bool, .UInt, .ULong, .UShort, .UByte, .String => true,
        else => false,
    };
}

/// `a == b` for two hostable keys: a differing runtime type is `false`
/// exactly as kotlinc's typed `equals` answers; same-tag values compare
/// structurally.
fn keyEq(a: *const Value, b: *const Value) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return Value.structuralEq(a, b);
}

/// The vendored `===` on a stored value, at klio's own identity
/// semantics: reference shapes by cell, scalars by tag + bits.
fn valueIdentical(a: *const Value, b: *const Value) bool {
    return switch (a.*) {
        .Instance => |x| b.* == .Instance and ObjRef(InstanceData).ptrEq(x, b.Instance),
        .String => |x| b.* == .String and runtime.StringRef.ptrEq(x, b.String),
        .Null => b.* == .Null,
        .Unit => b.* == .Unit,
        .Int, .Long, .Short, .Byte, .Char, .Bool, .UInt, .ULong, .UShort, .UByte => std.meta.activeTag(a.*) == std.meta.activeTag(b.*) and Value.structuralEq(a, b),
        else => false,
    };
}

/// TrieNode minting template: the class cell plus the four interned
/// field-name slices in the instance's declaration order. Captured per
/// thread from a live node; a node instance carrying any OTHER field
/// name refuses capture (and the serve bails).
const NodeTmpl = struct {
    gen: u32 = 0,
    class: ?ObjRef(ClassDef) = null,
    names: [4][]const u8 = .{ "", "", "", "" },
    order: [4]u8 = .{ 0, 0, 0, 0 },
};
threadlocal var node_tmpl: NodeTmpl = .{};

fn cacheGen() u32 {
    return @import("host_call_member.zig").dispatch_cache_gen.load(.monotonic);
}

/// Capture (or re-verify) the TrieNode template from a live node.
fn nodeTemplate(node: ObjRef(InstanceData)) ?*const NodeTmpl {
    const gen = cacheGen();
    if (node_tmpl.gen == gen) return &node_tmpl;
    if (node_tmpl.class) |c| c.deinit();
    node_tmpl.class = null;
    const g = node.borrow();
    defer g.deinit();
    const d = g.get();
    if (d.fields.items.len != 4) return null;
    var tmpl: NodeTmpl = .{ .gen = gen, .class = d.class.clone() };
    for (d.fields.items, 0..) |f, i| {
        tmpl.names[i] = f.name;
        if (std.mem.eql(u8, f.name, "dataMap")) {
            tmpl.order[i] = 0;
        } else if (std.mem.eql(u8, f.name, "nodeMap")) {
            tmpl.order[i] = 1;
        } else if (std.mem.eql(u8, f.name, "buffer")) {
            tmpl.order[i] = 2;
        } else if (std.mem.eql(u8, f.name, "ownedBy")) {
            tmpl.order[i] = 3;
        } else {
            tmpl.class.?.deinit();
            return null;
        }
    }
    node_tmpl = tmpl;
    return &node_tmpl;
}

/// The mutable view of one trie node the walk works over.
const NodeView = struct {
    inst: ObjRef(InstanceData),
    data_map: i32,
    node_map: i32,
    buffer: ArrayData,
    owned: bool,

    fn read(inst: ObjRef(InstanceData), owner: *const Value) ?NodeView {
        if (!classMatches(inst, &node_class_hit, NODE_FQN)) return null;
        const g = inst.borrow();
        defer g.deinit();
        const d = g.get();
        const dm = d.getCached(&fn_datamap, "dataMap") orelse return null;
        const nm = d.getCached(&fn_nodemap, "nodeMap") orelse return null;
        const buf = d.getCached(&fn_buffer, "buffer") orelse return null;
        const ob = d.getCached(&fn_ownedby, "ownedBy") orelse return null;
        if (dm != .Int or nm != .Int or buf != .Array) return null;
        if (buf.Array.prim != null) return null;
        const owned = ob == .Instance and owner.* == .Instance and
            ObjRef(InstanceData).ptrEq(ob.Instance, owner.Instance);
        return .{ .inst = inst, .data_map = dm.Int, .node_map = nm.Int, .buffer = buf.Array, .owned = owned };
    }
};

/// The builder-side effects a put accumulates; applied in one write-back
/// after the walk succeeds.
const PutCtx = struct {
    a: Allocator,
    self: *VmHost,
    owner: Value,
    tmpl: *const NodeTmpl,
    size_delta: i32 = 0,
    modcount_delta: i32 = 0,
    op_result: Value = .Null,
};

fn retainAll(items: []const Value) void {
    if (!runtime.reclaimEnabled()) return;
    for (items) |v| v.retain();
}

/// Mint a fresh TrieNode instance over `items` with the template's exact
/// field order. `owned_by` is the new node's owner slot value.
fn mintNode(ctx: *PutCtx, data_map: i32, node_map: i32, items: []const Value, owned_by: Value) Allocator.Error!Value {
    retainAll(items);
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacity(ctx.a, items.len);
    for (items) |v| list.appendAssumeCapacity(v);
    const buf_v = ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
    if (runtime.reclaimEnabled() and owned_by == .Instance) owned_by.retain();
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.ensureTotalCapacity(ctx.a, 4);
    const t = ctx.tmpl;
    for (t.names, t.order) |name, which| {
        const v: Value = switch (which) {
            0 => Value.newInt(data_map),
            1 => Value.newInt(node_map),
            2 => buf_v,
            else => owned_by,
        };
        fields.appendAssumeCapacity(.{ .name = name, .value = v });
    }
    const inst = try ObjRef(InstanceData).init(ctx.a, .{
        .class = t.class.?.clone(),
        .fields = fields,
        .outer = null,
        .identity = host_instances.mintInstanceId(ctx.self),
        .native_state = null,
    });
    return .{ .Instance = inst };
}

/// In-place store of the node's three mutable fields (the caller proved
/// ownership). `buffer` may be a NEW array value replacing the old slot.
fn storeNode(ctx: *PutCtx, view: *const NodeView, data_map: i32, node_map: i32, buffer: ?Value) Allocator.Error!void {
    const g = view.inst.borrowMut();
    defer g.deinit();
    const d = g.get();
    if (view.data_map != data_map) try d.define(ctx.a, "dataMap", Value.newInt(data_map));
    if (view.node_map != node_map) try d.define(ctx.a, "nodeMap", Value.newInt(node_map));
    if (buffer) |b| try d.define(ctx.a, "buffer", b);
}

// All bitmap arithmetic runs in the u32 domain: `mask - 1` on the i32
// spelling overflows (panics) when the mask is bit 31.
fn keyIndexOf(view: *const NodeView, mask: u32) usize {
    return ENTRY_SIZE * @as(usize, @popCount(@as(u32, @bitCast(view.data_map)) & (mask - 1)));
}

fn nodeIndexOf(view: *const NodeView, mask: u32) usize {
    return view.buffer.len() - 1 - @as(usize, @popCount(@as(u32, @bitCast(view.node_map)) & (mask - 1)));
}

/// `buffer.insertEntryAtIndex(keyIndex, key, value)` as a fresh snapshot.
fn bufferInsertEntry(ctx: *PutCtx, buffer: ArrayData, key_index: usize, key: *const Value, value: *const Value) Allocator.Error!Value {
    const n = buffer.len();
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacity(ctx.a, n + ENTRY_SIZE);
    var i: usize = 0;
    while (i < key_index) : (i += 1) list.appendAssumeCapacity(buffer.get(i));
    list.appendAssumeCapacity(key.*);
    list.appendAssumeCapacity(value.*);
    while (i < n) : (i += 1) list.appendAssumeCapacity(buffer.get(i));
    retainAll(list.items);
    return ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
}

/// `buffer.replaceEntryWithNode(keyIndex, nodeIndex, node)` as a fresh
/// snapshot: the two entry slots vanish, the node lands where the
/// vendored helper puts it (`nodeIndex - ENTRY_SIZE` of the old frame).
fn bufferReplaceEntryWithNode(ctx: *PutCtx, buffer: ArrayData, key_index: usize, node_index: usize, node: Value) Allocator.Error!Value {
    const n = buffer.len();
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacity(ctx.a, n - ENTRY_SIZE + 1);
    var i: usize = 0;
    while (i < key_index) : (i += 1) list.appendAssumeCapacity(buffer.get(i));
    i = key_index + ENTRY_SIZE;
    while (i < node_index) : (i += 1) list.appendAssumeCapacity(buffer.get(i));
    list.appendAssumeCapacity(node);
    while (i < n) : (i += 1) list.appendAssumeCapacity(buffer.get(i));
    retainAll(list.items);
    return ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
}

/// A whole-buffer copy with one slot replaced.
fn bufferCopyReplace(ctx: *PutCtx, buffer: ArrayData, index: usize, v: *const Value) Allocator.Error!Value {
    const n = buffer.len();
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacity(ctx.a, n);
    var i: usize = 0;
    while (i < n) : (i += 1) list.appendAssumeCapacity(if (i == index) v.* else buffer.get(i));
    retainAll(list.items);
    return ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
}

/// `makeNode`: a fresh subtree holding the two entries, recursing while
/// their hash segments collide, a collision node past MAX_SHIFT.
fn makeNode(ctx: *PutCtx, h1: i32, k1: *const Value, v1: *const Value, h2: i32, k2: *const Value, v2: *const Value, shift: u32, owned_by: Value) Allocator.Error!Value {
    if (shift > MAX_SHIFT) {
        return mintNode(ctx, 0, 0, &.{ k1.*, v1.*, k2.*, v2.* }, owned_by);
    }
    const s1: u5 = @truncate(@as(u32, @bitCast(h1)) >> @intCast(shift));
    const s2: u5 = @truncate(@as(u32, @bitCast(h2)) >> @intCast(shift));
    if (s1 != s2) {
        const items: [4]Value = if (s1 < s2)
            .{ k1.*, v1.*, k2.*, v2.* }
        else
            .{ k2.*, v2.*, k1.*, v1.* };
        const dm: i32 = @bitCast((@as(u32, 1) << s1) | (@as(u32, 1) << s2));
        return mintNode(ctx, dm, 0, items[0..], owned_by);
    }
    const child = try makeNode(ctx, h1, k1, v1, h2, k2, v2, shift + LOG_BRANCH, owned_by);
    const nm: i32 = @bitCast(@as(u32, 1) << s1);
    const parent = try mintNode(ctx, 0, nm, &.{child}, owned_by);
    // `mintNode` retained the child for its buffer; drop the local ref.
    if (runtime.reclaimEnabled()) child.release(ctx.a);
    return parent;
}

/// The exact `TrieNode.mutablePut` walk. Returns the (possibly same)
/// node as a Value; null bails to the interpreter — provably before any
/// mutation (every in-place write follows the last shape check on its
/// path, and recursion bails bottom-up before its parent touches
/// anything).
fn mutablePut(ctx: *PutCtx, node_inst: ObjRef(InstanceData), key_hash: i32, key: *const Value, value: *const Value, shift: u32) Allocator.Error!?Value {
    const view = NodeView.read(node_inst, &ctx.owner) orelse return null;
    if (shift > MAX_SHIFT) return mutableCollisionPut(ctx, &view, key, value);
    const seg: u5 = @truncate(@as(u32, @bitCast(key_hash)) >> @intCast(shift));
    const mask: u32 = @as(u32, 1) << seg;
    if (@as(u32, @bitCast(view.data_map)) & mask != 0) {
        const key_index = keyIndexOf(&view, mask);
        if (key_index + 1 >= view.buffer.len()) return null;
        const stored_key = view.buffer.get(key_index);
        if (!keyHostable(&stored_key)) return null;
        if (keyEq(key, &stored_key)) {
            const old = view.buffer.get(key_index + 1);
            ctx.op_result = old;
            if (valueIdentical(&old, value)) return .{ .Instance = node_inst };
            // mutableUpdateValueAtIndex (`set` retains the stored value).
            if (view.owned) {
                view.buffer.set(ctx.a, key_index + 1, value.*);
                return .{ .Instance = node_inst };
            }
            ctx.modcount_delta += 1;
            const new_buf = try bufferCopyReplace(ctx, view.buffer, key_index + 1, value);
            return try mintNodeFromBuf(ctx, view.data_map, view.node_map, new_buf);
        }
        // mutableMoveEntryToNode: the stored key's own hash drives the
        // subtree, so it must be host-hashable too.
        const stored_hash = Value.kotlinScalarHash(&stored_key) orelse return null;
        const stored_value = view.buffer.get(key_index + 1);
        ctx.size_delta += 1;
        const sub = try makeNode(ctx, stored_hash, &stored_key, &stored_value, key_hash, key, value, shift + LOG_BRANCH, ctx.owner);
        const node_index = nodeIndexOf(&view, mask) + 1;
        const new_buf = try bufferReplaceEntryWithNode(ctx, view.buffer, key_index, node_index, sub);
        if (runtime.reclaimEnabled()) sub.release(ctx.a);
        const new_dm: i32 = @bitCast(@as(u32, @bitCast(view.data_map)) ^ mask);
        const new_nm: i32 = @bitCast(@as(u32, @bitCast(view.node_map)) | mask);
        if (view.owned) {
            try storeNode(ctx, &view, new_dm, new_nm, new_buf);
            return .{ .Instance = node_inst };
        }
        return try mintNodeFromBuf(ctx, new_dm, new_nm, new_buf);
    }
    if (@as(u32, @bitCast(view.node_map)) & mask != 0) {
        const node_index = nodeIndexOf(&view, mask);
        if (node_index >= view.buffer.len()) return null;
        const target = view.buffer.get(node_index);
        if (target != .Instance) return null;
        const new_node = (try mutablePut(ctx, target.Instance, key_hash, key, value, shift + LOG_BRANCH)) orelse return null;
        if (new_node == .Instance and ObjRef(InstanceData).ptrEq(new_node.Instance, target.Instance)) {
            return .{ .Instance = node_inst };
        }
        // mutableUpdateNodeAtIndex, including the single-entry upping.
        if (view.buffer.len() == 1) {
            const nv = NodeView.read(new_node.Instance, &ctx.owner) orelse return null;
            if (nv.buffer.len() == ENTRY_SIZE and nv.node_map == 0) {
                try storeNode(ctx, &nv, view.node_map, nv.node_map, null);
                return new_node;
            }
        }
        if (view.owned) {
            // `set` retains for the slot; drop the walk's own ref to the
            // freshly minted child.
            view.buffer.set(ctx.a, node_index, new_node);
            if (runtime.reclaimEnabled()) new_node.release(ctx.a);
            return .{ .Instance = node_inst };
        }
        const new_buf = try bufferCopyReplace(ctx, view.buffer, node_index, &new_node);
        if (runtime.reclaimEnabled()) new_node.release(ctx.a);
        return try mintNodeFromBuf(ctx, view.data_map, view.node_map, new_buf);
    }
    // Key absent at this level: insert the entry.
    ctx.size_delta += 1;
    const key_index = keyIndexOf(&view, mask);
    const new_buf = try bufferInsertEntry(ctx, view.buffer, key_index, key, value);
    const new_dm: i32 = @bitCast(@as(u32, @bitCast(view.data_map)) | mask);
    if (view.owned) {
        try storeNode(ctx, &view, new_dm, view.node_map, new_buf);
        return .{ .Instance = node_inst };
    }
    return try mintNodeFromBuf(ctx, new_dm, view.node_map, new_buf);
}

/// Mint over an ALREADY-built buffer value (fresh, so no per-item
/// retain: `bufferInsertEntry`-family already retained the elements).
fn mintNodeFromBuf(ctx: *PutCtx, data_map: i32, node_map: i32, buf_v: Value) Allocator.Error!Value {
    if (runtime.reclaimEnabled() and ctx.owner == .Instance) ctx.owner.retain();
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.ensureTotalCapacity(ctx.a, 4);
    const t = ctx.tmpl;
    for (t.names, t.order) |name, which| {
        const v: Value = switch (which) {
            0 => Value.newInt(data_map),
            1 => Value.newInt(node_map),
            2 => buf_v,
            else => ctx.owner,
        };
        fields.appendAssumeCapacity(.{ .name = name, .value = v });
    }
    const inst = try ObjRef(InstanceData).init(ctx.a, .{
        .class = t.class.?.clone(),
        .fields = fields,
        .outer = null,
        .identity = host_instances.mintInstanceId(ctx.self),
        .native_state = null,
    });
    return .{ .Instance = inst };
}

/// `mutableCollisionPut`: flat unordered [k, v, ...] scan.
fn mutableCollisionPut(ctx: *PutCtx, view: *const NodeView, key: *const Value, value: *const Value) Allocator.Error!?Value {
    const n = view.buffer.len();
    var i: usize = 0;
    while (i + 1 < n) : (i += ENTRY_SIZE) {
        const stored_key = view.buffer.get(i);
        if (!keyHostable(&stored_key)) return null;
        if (keyEq(key, &stored_key)) {
            ctx.op_result = view.buffer.get(i + 1);
            if (view.owned) {
                view.buffer.set(ctx.a, i + 1, value.*);
                return .{ .Instance = view.inst };
            }
            ctx.modcount_delta += 1;
            const new_buf = try bufferCopyReplace(ctx, view.buffer, i + 1, value);
            return try mintNodeFromBuf(ctx, 0, 0, new_buf);
        }
    }
    ctx.size_delta += 1;
    const new_buf = try bufferInsertEntry(ctx, view.buffer, 0, key, value);
    return try mintNodeFromBuf(ctx, 0, 0, new_buf);
}

/// The builder's live fields for a put, in one borrow.
const BuilderState = struct {
    node: Value,
    ownership: Value,
    size: i32,
    modcount: i32,
};

fn readBuilder(inst: ObjRef(InstanceData)) ?BuilderState {
    const g = inst.borrow();
    defer g.deinit();
    const d = g.get();
    const node = d.getCached(&fn_node, "node") orelse return null;
    const ownership = d.getCached(&fn_ownership, "ownership") orelse return null;
    const size = d.getCached(&fn_size, "size") orelse return null;
    const modcount = d.getCached(&fn_modcount, "modCount") orelse return null;
    if (node != .Instance or ownership != .Instance) return null;
    if (size != .Int or modcount != .Int) return null;
    return .{ .node = node, .ownership = ownership, .size = size.Int, .modcount = modcount.Int };
}

/// Serve `builder.put(key, value)`. Returns the previous value (retained)
/// or Null; null bails to the interpreted body.
pub fn tryPut(self: *VmHost, a: Allocator, inst: ObjRef(InstanceData), key: *const Value, value: *const Value) Allocator.Error!?Value {
    if (!isBuilderClass(inst)) return null;
    if (!keyHostable(key)) return null;
    const key_hash = Value.kotlinScalarHash(key) orelse return null;
    const st = readBuilder(inst) orelse return null;
    const tmpl = nodeTemplate(st.node.Instance) orelse return null;
    var ctx: PutCtx = .{ .a = a, .self = self, .owner = st.ownership, .tmpl = tmpl };
    const new_node = (try mutablePut(&ctx, st.node.Instance, key_hash, key, value, 0)) orelse return null;
    // Write-back: node, size (its setter bumps modCount), operationResult.
    {
        const g = inst.borrowMut();
        defer g.deinit();
        const d = g.get();
        if (!(new_node == .Instance and ObjRef(InstanceData).ptrEq(new_node.Instance, st.node.Instance))) {
            // A non-identical result is freshly minted (owned); `define`
            // consumes it and releases the old node.
            try d.define(a, "node", new_node);
        }
        if (ctx.size_delta != 0) {
            try d.define(a, "size", Value.newInt(st.size + ctx.size_delta));
            ctx.modcount_delta += ctx.size_delta;
        }
        if (ctx.modcount_delta != 0) {
            try d.define(a, "modCount", Value.newInt(st.modcount + ctx.modcount_delta));
        }
        if (runtime.reclaimEnabled()) ctx.op_result.retain();
        try d.define(a, "operationResult", ctx.op_result);
    }
    if (runtime.reclaimEnabled()) ctx.op_result.retain();
    return ctx.op_result;
}

/// Serve `builder.build()`: the stored map when the node is unchanged,
/// else a fresh PersistentHashMap over (node, size) plus a fresh
/// ownership for the builder. Bails on any shape surprise.
pub fn tryBuild(self: *VmHost, a: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!?Value {
    if (!isBuilderClass(inst)) return null;
    const st = readBuilder(inst) orelse return null;
    const map_v: Value = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().getCached(&fn_map, "map") orelse return null;
    };
    if (map_v != .Instance) return null;
    if (!classMatches(map_v.Instance, &map_class_hit, MAP_FQN)) return null;
    const map_node: Value = blk: {
        const g = map_v.Instance.borrow();
        defer g.deinit();
        break :blk g.get().getCached(&fn_node, "node") orelse return null;
    };
    if (map_node == .Instance and ObjRef(InstanceData).ptrEq(map_node.Instance, st.node.Instance)) {
        if (runtime.reclaimEnabled()) map_v.retain();
        return map_v;
    }
    // node !== map.node: mint PersistentHashMap(node, size) + a fresh
    // MutabilityOwnership for the builder, exactly as the source does.
    // Field surface verified against the template map: node, size, and
    // AbstractMap's null-initialized view caches only.
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    {
        const g = map_v.Instance.borrow();
        defer g.deinit();
        const d = g.get();
        try fields.ensureTotalCapacity(a, d.fields.items.len);
        for (d.fields.items) |f| {
            const v: Value = if (std.mem.eql(u8, f.name, "node")) blk: {
                if (runtime.reclaimEnabled()) st.node.retain();
                break :blk st.node;
            } else if (std.mem.eql(u8, f.name, "size"))
                Value.newInt(st.size)
            else if (std.mem.eql(u8, f.name, "_keys") or std.mem.eql(u8, f.name, "_values"))
                Value.Null
            else {
                fields.deinit(a);
                return null;
            };
            fields.appendAssumeCapacity(.{ .name = f.name, .value = v });
        }
    }
    const map_class = blk: {
        const g = map_v.Instance.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    const new_map = try ObjRef(InstanceData).init(a, .{
        .class = map_class,
        .fields = fields,
        .outer = null,
        .identity = host_instances.mintInstanceId(self),
        .native_state = null,
    });
    // Fresh ownership: an empty instance of the ownership's own class.
    const new_owner: Value = blk: {
        if (st.ownership != .Instance) return null;
        const og = st.ownership.Instance.borrow();
        const n_fields = og.get().fields.items.len;
        const ocls = og.get().class.clone();
        og.deinit();
        if (n_fields != 0) {
            ocls.deinit();
            return null;
        }
        const oinst = try ObjRef(InstanceData).init(a, .{
            .class = ocls,
            .fields = .empty,
            .outer = null,
            .identity = host_instances.mintInstanceId(self),
            .native_state = null,
        });
        break :blk .{ .Instance = oinst };
    };
    const new_map_v: Value = .{ .Instance = new_map };
    {
        const g = inst.borrowMut();
        defer g.deinit();
        const d = g.get();
        try d.define(a, "map", new_map_v);
        try d.define(a, "ownership", new_owner);
    }
    if (runtime.reclaimEnabled()) new_map_v.retain();
    return new_map_v;
}
