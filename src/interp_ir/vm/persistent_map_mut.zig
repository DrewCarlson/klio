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
const ir = @import("ir");
const span_mod = @import("span");

const vmhost = @import("vmhost.zig");
const host_instances = @import("host_instances.zig");
const host_globals = @import("host_globals.zig");
const concurrent = @import("stdlib").implementations.concurrent;

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

pub fn isMapClass(inst: ObjRef(InstanceData)) bool {
    return classMatches(inst, &map_class_hit, MAP_FQN);
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
        if (runtime.gc.cellSweptPoisoned(&inst.cell.hdr)) {
            std.debug.print("[stale-edge] NodeView.read on SWEPT cell {x}\n", .{@intFromPtr(inst.cell)});
            runtime.trace.dumpCurrent(.{});
            return null;
        }
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
    const v: Value = .{ .Instance = inst };
    // Collect-at-alloc: the NEXT host allocation on this thread may run a
    // collection, and a freshly minted node referenced only by native
    // locals is invisible to the root walk — pin until the serve's
    // entry-mark restores.
    runtime.keepalivePush(v);
    return v;
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
    const bv = ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
    runtime.keepalivePush(bv);
    return bv;
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
    const bv = ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
    runtime.keepalivePush(bv);
    return bv;
}

/// A whole-buffer copy with one slot replaced.
fn bufferCopyReplace(ctx: *PutCtx, buffer: ArrayData, index: usize, v: *const Value) Allocator.Error!Value {
    const n = buffer.len();
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacity(ctx.a, n);
    var i: usize = 0;
    while (i < n) : (i += 1) list.appendAssumeCapacity(if (i == index) v.* else buffer.get(i));
    retainAll(list.items);
    const bv = ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
    runtime.keepalivePush(bv);
    return bv;
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
        if (runtime.gc.cellSweptPoisoned(&target.Instance.cell.hdr)) {
            const bufid: usize = switch (view.buffer.storage()) {
                .boxed => |vl| @intFromPtr(vl.cell),
                else => 0,
            };
            std.debug.print("[stale-edge] parent {x} (owned={}) buffer {x} idx={d} -> SWEPT child {x}\n", .{ @intFromPtr(node_inst.cell), view.owned, bufid, node_index, @intFromPtr(target.Instance.cell) });
            return null;
        }
        if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT_TRACE") orelse "", "3")) {
            const p = @intFromPtr(target.Instance.cell);
            if (p < 0x1000 or (p >> 47) != 0) {
                std.debug.print("[ssm-badchild] parent={x} idx={d} child={x} dm={x} nm={x} buflen={d}\n", .{ @intFromPtr(node_inst.cell), node_index, p, view.data_map, view.node_map, view.buffer.len() });
                return null;
            }
        }
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
    const v: Value = .{ .Instance = inst };
    runtime.keepalivePush(v);
    return v;
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

/// Builder minting template: the class cell plus the interned field
/// names in declaration order, captured from a live builder in `tryPut`.
/// A builder carrying any field outside the six known ones refuses
/// capture, so `tryBuilder` can only ever mint the exact shape the
/// interpreted constructor produces.
const BuilderTmpl = struct {
    gen: u32 = 0,
    class: ?ObjRef(ClassDef) = null,
    owner_class: ?ObjRef(ClassDef) = null,
    count: u8 = 0,
    names: [12][]const u8 = @splat(""),
    /// 0 map, 1 ownership, 2 node, 3 operationResult, 4 modCount,
    /// 5 size, 6 a null-initialized lazy view cache (`_keys`/`_values`
    /// from AbstractMap plus their owner-mangled AbstractMutableMap
    /// twins).
    order: [12]u8 = @splat(0),
};
threadlocal var builder_tmpl: BuilderTmpl = .{};

/// Whether a stored field name is one of the AbstractMap-family lazy
/// view caches (`_keys`/`_values`, possibly behind an owner-qualified
/// `<Owner>\x1f` prefix) whose constructor-initial value is null.
fn isViewCacheName(name: []const u8) bool {
    const last = if (std.mem.lastIndexOfScalar(u8, name, 0x1f)) |i| name[i + 1 ..] else name;
    return std.mem.eql(u8, last, "_keys") or std.mem.eql(u8, last, "_values");
}

fn captureBuilderTemplate(inst: ObjRef(InstanceData), ownership: *const Value) void {
    const gen = cacheGen();
    if (builder_tmpl.gen == gen and builder_tmpl.class != null) return;
    if (builder_tmpl.class) |c| c.deinit();
    if (builder_tmpl.owner_class) |c| c.deinit();
    builder_tmpl = .{};
    const trace = runtime.envOnce("KLIO_MAPMUT_TRACE") != null;
    const g = inst.borrow();
    defer g.deinit();
    const d = g.get();
    if (trace) {
        std.debug.print("[mapmut] builder fields ({d}):", .{d.fields.items.len});
        for (d.fields.items) |f| std.debug.print(" {s}", .{f.name});
        std.debug.print("\n", .{});
    }
    if (d.fields.items.len > 12) return;
    var tmpl: BuilderTmpl = .{ .gen = gen, .count = @intCast(d.fields.items.len) };
    var seen: u8 = 0;
    for (d.fields.items, 0..) |f, i| {
        tmpl.names[i] = f.name;
        if (std.mem.eql(u8, f.name, "map")) {
            tmpl.order[i] = 0;
        } else if (std.mem.eql(u8, f.name, "ownership")) {
            tmpl.order[i] = 1;
        } else if (std.mem.eql(u8, f.name, "node")) {
            tmpl.order[i] = 2;
        } else if (std.mem.eql(u8, f.name, "operationResult")) {
            tmpl.order[i] = 3;
        } else if (std.mem.eql(u8, f.name, "modCount")) {
            tmpl.order[i] = 4;
        } else if (std.mem.eql(u8, f.name, "size")) {
            tmpl.order[i] = 5;
        } else if (isViewCacheName(f.name)) {
            // Lazy view caches (AbstractMap's `_keys`/`_values` and their
            // owner-qualified `AbstractMutableMap\x1f_keys` twins —
            // owner-scoped storage names use the 0x1f separator):
            // ctor-initial null.
            tmpl.order[i] = 6;
            continue;
        } else {
            if (trace) std.debug.print("[mapmut] capture bail unknown field {s} hex={x}\n", .{ f.name, f.name });
            return;
        }
        seen |= @as(u8, 1) << @intCast(tmpl.order[i]);
    }
    // All six declared fields must be present, or the mint would build a
    // shape the interpreted constructor never produces.
    if (seen != 0b111111) {
        if (trace) std.debug.print("[mapmut] capture bail seen={b}\n", .{seen});
        return;
    }
    if (ownership.* != .Instance) {
        if (trace) std.debug.print("[mapmut] capture bail owner not instance\n", .{});
        return;
    }
    const og = ownership.Instance.borrow();
    defer og.deinit();
    if (og.get().fields.items.len != 0) {
        if (trace) std.debug.print("[mapmut] capture bail owner fields={d}\n", .{og.get().fields.items.len});
        return;
    }
    tmpl.class = d.class.clone();
    tmpl.owner_class = og.get().class.clone();
    builder_tmpl = tmpl;
    if (trace) std.debug.print("[mapmut] capture OK count={d} gen={d}\n", .{ tmpl.count, tmpl.gen });
}

/// Serve `map.builder()`: mint the PersistentHashMapBuilder + a fresh
/// MutabilityOwnership without the interpreted constructor chain. Bails
/// until `tryPut` has captured the builder template from a live builder
/// (the first cycle of a process runs interpreted).
pub fn tryBuilder(self: *VmHost, a: Allocator, map_inst: ObjRef(InstanceData)) Allocator.Error!?Value {
    if (!classMatches(map_inst, &map_class_hit, MAP_FQN)) return null;
    const km = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(km);
    if (builder_tmpl.gen != cacheGen() or builder_tmpl.class == null) {
        if (runtime.envOnce("KLIO_MAPMUT_TRACE") != null) {
            const S = struct {
                threadlocal var once: bool = false;
            };
            if (!S.once) {
                S.once = true;
                std.debug.print("[mapmut] tryBuilder bail no-template gen={d} want={d} class={}\n", .{ builder_tmpl.gen, cacheGen(), builder_tmpl.class != null });
            }
        }
        return null;
    }
    const t = &builder_tmpl;
    const map_node: Value, const map_size: Value = blk: {
        const g = map_inst.borrow();
        defer g.deinit();
        const node = g.get().getCached(&fn_node, "node") orelse return null;
        const size = g.get().getCached(&fn_size, "size") orelse return null;
        if (node != .Instance or size != .Int) return null;
        break :blk .{ node, size };
    };
    const owner_inst = try ObjRef(InstanceData).init(a, .{
        .class = t.owner_class.?.clone(),
        .fields = .empty,
        .outer = null,
        .identity = host_instances.mintInstanceId(self),
        .native_state = null,
    });
    runtime.keepalivePush(.{ .Instance = owner_inst });
    const map_v: Value = .{ .Instance = map_inst };
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.ensureTotalCapacity(a, t.count);
    for (t.names[0..t.count], t.order[0..t.count]) |name, which| {
        const v: Value = switch (which) {
            0 => blk: {
                if (runtime.reclaimEnabled()) map_v.retain();
                break :blk map_v;
            },
            1 => .{ .Instance = owner_inst },
            2 => blk: {
                if (runtime.reclaimEnabled()) map_node.retain();
                break :blk map_node;
            },
            3, 6 => Value.Null,
            4 => Value.newInt(0),
            else => map_size,
        };
        fields.appendAssumeCapacity(.{ .name = name, .value = v });
    }
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = t.class.?.clone(),
        .fields = fields,
        .outer = null,
        .identity = host_instances.mintInstanceId(self),
        .native_state = null,
    });
    return .{ .Instance = inst };
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
    const km = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(km);
    if (!keyHostable(key)) return null;
    const key_hash = Value.kotlinScalarHash(key) orelse return null;
    const st = readBuilder(inst) orelse return null;
    const tmpl = nodeTemplate(st.node.Instance) orelse return null;
    captureBuilderTemplate(inst, &st.ownership);
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

// ==== Whole-cycle SnapshotStateMap.put serve ====
//
// The steady-state write cycle (`mutate { it.put(key, value) }` when the
// current snapshot is the observer-free GlobalSnapshot and the record was
// born in it) replayed host-side: read the record under the map file's
// `sync` monitor, compute the new PersistentHashMap fully persistently
// (owner = Null: every trie path mints, nothing mutates in place), then
// re-check `modification` under the monitor and assign — exactly
// `attemptUpdate`'s protected section. No builder, no ownership, no
// build step, and an identical-value put allocates nothing. Every gate
// failure bails BEFORE any mutation, so the interpreted cycle serves the
// rest (record creation after a snapshot advance, nested snapshots,
// observers, non-scalar keys).

const SSM_FQN = "androidx.compose.runtime.snapshots.SnapshotStateMap";
var ssm_class_hit = std.atomic.Value(usize).init(0);
var fn_first_rec = std.atomic.Value(?[*]const u8).init(null);
var fn_rec_map = std.atomic.Value(?[*]const u8).init(null);
var fn_rec_mod = std.atomic.Value(?[*]const u8).init(null);
var fn_rec_sid = std.atomic.Value(?[*]const u8).init(null);

pub fn isSnapshotMapClass(inst: ObjRef(InstanceData)) bool {
    return classMatches(inst, &ssm_class_hit, SSM_FQN);
}

/// A file-private top-level global (`<prefix>$f<N>` where file N's path
/// ends in `file_base`), resolved by scanning the globals env once per
/// dispatch gen and re-LOOKED-UP by name per call (the cell may be a
/// `var`). The memo holds the mangled NAME.
const FpName = struct { gen: u32 = 0, ok: bool = false, buf: [64]u8 = undefined, len: usize = 0 };

fn filePrivateGlobal(self: *VmHost, memo: *FpName, comptime prefix: []const u8, comptime file_base: []const u8) ?Value {
    const gen = cacheGen();
    if (memo.gen != gen) {
        memo.gen = gen;
        memo.ok = false;
        var level: ?runtime.ObjRef(runtime.Env) = self.globals;
        outer: while (level) |lv| {
            const g = lv.borrow();
            var it = g.get().vars.iterator();
            while (it.next()) |ent| {
                const k = ent.key_ptr.*;
                if (!std.mem.startsWith(u8, k, prefix ++ "$f")) continue;
                const n = std.fmt.parseInt(u32, k[prefix.len + 2 ..], 10) catch continue;
                if (span_mod.active_map) |am| {
                    if (am.getChecked(span_mod.FileId.from(n))) |sf| {
                        if (std.mem.endsWith(u8, sf.path, file_base) and k.len <= memo.buf.len) {
                            @memcpy(memo.buf[0..k.len], k);
                            memo.len = k.len;
                            memo.ok = true;
                            g.deinit();
                            break :outer;
                        }
                    }
                }
            }
            const parent = g.get().parent;
            g.deinit();
            level = parent;
        }
    }
    if (!memo.ok) {
        // A file-private top-level only gets the `$f<N>` mangle on a
        // NAME COLLISION; a program-wide-unique one binds plain — and a
        // plain hit is unambiguous (a second declaration anywhere would
        // have forced both onto the mangled form).
        const g = self.globals.borrow();
        defer g.deinit();
        return g.get().lookup(prefix);
    }
    const g = self.globals.borrow();
    defer g.deinit();
    return g.get().lookup(memo.buf[0..memo.len]);
}

threadlocal var sync_name: FpName = .{};
threadlocal var gwo_name: FpName = .{};

fn snapshotMapSync(self: *VmHost) ?Value {
    const v = filePrivateGlobal(self, &sync_name, "sync", "SnapshotStateMap.kt") orelse return null;
    if (v != .Instance) return null;
    return v;
}

/// notifyWrite is a provable no-op only while the file-private
/// `globalWriteObservers` list (Snapshot.kt) is EMPTY — GlobalSnapshot's
/// writeObserver is the ctor lambda draining it.
fn globalWriteObserversEmpty(self: *VmHost) bool {
    const v = filePrivateGlobal(self, &gwo_name, "globalWriteObservers", "Snapshot.kt") orelse {
        ssmTrace("gwo-unresolved");
        return false;
    };
    switch (v) {
        .Array => |arr| return arr.len() == 0,
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            return g.get().items.len == 0;
        },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            if (std.mem.eql(u8, cg.get().name, "EmptyList")) return true;
            if (runtime.envOnce("KLIO_SSMPUT_TRACE") != null) {
                std.debug.print("[ssmput] gwo class={s}\n", .{cg.get().name});
            }
            return false;
        },
        else => {
            if (runtime.envOnce("KLIO_SSMPUT_TRACE") != null) {
                std.debug.print("[ssmput] gwo tag={s}\n", .{@tagName(std.meta.activeTag(v))});
            }
            return false;
        },
    }
}

/// Mint a PersistentHashMap over (node, size) from a live map's exact
/// field surface (`node`, `size`, AbstractMap's null view caches).
/// Consumes `node`'s reference on success; the caller releases it on a
/// null bail.
fn mintMapFrom(self: *VmHost, a: Allocator, proto: ObjRef(InstanceData), node: Value, size: i32) Allocator.Error!?Value {
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    {
        const g = proto.borrow();
        defer g.deinit();
        const d = g.get();
        try fields.ensureTotalCapacity(a, d.fields.items.len);
        for (d.fields.items) |f| {
            const v: Value = if (std.mem.eql(u8, f.name, "node"))
                node
            else if (std.mem.eql(u8, f.name, "size"))
                Value.newInt(size)
            else if (std.mem.eql(u8, f.name, "_keys") or std.mem.eql(u8, f.name, "_values"))
                Value.Null
            else {
                fields.deinit(a);
                return null;
            };
            fields.appendAssumeCapacity(.{ .name = f.name, .value = v });
        }
    }
    const cls = blk: {
        const g = proto.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = fields,
        .outer = null,
        .identity = host_instances.mintInstanceId(self),
        .native_state = null,
    });
    return .{ .Instance = inst };
}


/// Debug (KLIO_SSMPUT=5): recursively validate a trie's shape — every
/// reachable node must read as a well-formed TrieNode.
fn pageMapped(addr: usize) bool {
    const pg = std.heap.pageSize();
    const base = std.mem.alignBackward(usize, addr, pg);
    return std.os.linux.msync(@ptrFromInt(base), pg, std.os.linux.MSF.ASYNC) == 0;
}

fn validateTrie(node: ObjRef(InstanceData), depth: u32) bool {
    if (depth > 8) return false;
    {
        const cp = @intFromPtr(node.cell);
        if (!pageMapped(cp)) {
            std.debug.print("[ssm-rot] node cell UNMAPPED {x} depth={d}\n", .{ cp, depth });
            return false;
        }
        const fslice = node.cell.data.fields.items;
        const fp = @intFromPtr(fslice.ptr);
        if (fslice.len > 64 or (fp >> 47) != 0 or (fslice.len != 0 and !pageMapped(fp))) {
            std.debug.print("[ssm-rot] node {x} fields ptr={x} len={d} depth={d}\n", .{ cp, fp, fslice.len, depth });
            return false;
        }
    }
    const null_owner: Value = .Null;
    const view = NodeView.read(node, &null_owner) orelse {
        std.debug.print("[ssm-rot] node={x} unreadable at depth={d}\n", .{ @intFromPtr(node.cell), depth });
        return false;
    };
    var i: usize = 0;
    const n = view.buffer.len();
    _ = view.data_map;
    while (i < n) : (i += 1) {
        const v = view.buffer.get(i);
        if (v == .Instance and classMatches(v.Instance, &node_class_hit, NODE_FQN)) {
            if (!validateTrie(v.Instance, depth + 1)) return false;
        }
    }
    return true;
}

fn mapTrieValid(map_v: Value) bool {
    if (map_v != .Instance) return false;
    const node_v: Value = blk: {
        const g = map_v.Instance.borrow();
        defer g.deinit();
        break :blk g.get().getCached(&fn_node, "node") orelse return false;
    };
    if (node_v != .Instance) return false;
    return validateTrie(node_v.Instance, 0);
}

// ==== Pre-sweep mark audit (KLIO_SSMPUT=8) ====
// Commits register their record; the GC audit hook re-walks each
// registered record's map trie after marking and reports any cell the
// sweep would free — naming the broken edge before it becomes a UAF.
var audit_lock: runtime.SpinMutex = .{};
var audit_records: [64]?ObjRef(InstanceData) = @splat(null);
var audit_next: usize = 0;
var audit_commits = std.atomic.Value(usize).init(0);

fn auditRegisterOne(rec: ObjRef(InstanceData)) void {
    for (audit_records) |e| {
        if (e) |x| if (ObjRef(InstanceData).ptrEq(x, rec)) return;
    }
    audit_records[audit_next % audit_records.len] = rec;
    audit_next += 1;
}

fn auditRegisterRecord(rec: ObjRef(InstanceData)) void {
    audit_lock.lock();
    defer audit_lock.unlock();
    // The whole record chain: commits and reads may target different
    // records (readable walk vs the chain head).
    var cur: ?ObjRef(InstanceData) = rec;
    var hops: u32 = 0;
    while (cur) |c| : (hops += 1) {
        if (hops > 8) break;
        auditRegisterOne(c);
        const g = c.borrow();
        const nv = g.get().get("next");
        g.deinit();
        const n = nv orelse break;
        if (n != .Instance) break;
        cur = n.Instance;
    }
    if (runtime.gc.audit_hook == null) {
        runtime.gc.audit_hook = gcAudit;
        runtime.gc.post_sweep_hook = gcPostSweep;
    }
}

fn auditFate(inst: ObjRef(InstanceData), major: bool) []const u8 {
    return @tagName(runtime.gc.cellSweepFate(&inst.cell.hdr, major));
}

fn auditWalkNode(node: ObjRef(InstanceData), major: bool, depth: u32, parent: usize, parent_fate: []const u8) void {
    if (depth > 8) return;
    const fate = runtime.gc.cellSweepFate(&node.cell.hdr, major);
    if (fate == .white) {
        const ob: usize = blk: {
            const g = node.borrow();
            defer g.deinit();
            const v = g.get().getCached(&fn_ownedby, "ownedBy") orelse break :blk 1;
            break :blk if (v == .Instance) @intFromPtr(v.Instance.cell) else 0;
        };
        std.debug.print("[gc-audit] WHITE trie node {x} depth={d} ownedBy={x} parent={x}({s}) major={}\n", .{ @intFromPtr(node.cell), depth, ob, parent, parent_fate, major });
        return;
    }
    if (depth == 0) {
        const ob: usize = blk: {
            const g = node.borrow();
            defer g.deinit();
            const v = g.get().getCached(&fn_ownedby, "ownedBy") orelse break :blk 1;
            break :blk if (v == .Instance) @intFromPtr(v.Instance.cell) else 0;
        };
        std.debug.print("[gc-audit] root {x} ownedBy={x} fate={s}\n", .{ @intFromPtr(node.cell), ob, @tagName(fate) });
    }
    const null_owner: Value = .Null;
    const view = NodeView.read(node, &null_owner) orelse return;
    // The buffer cell's own fate.
    var i: usize = 0;
    const n = view.buffer.len();
    while (i < n) : (i += 1) {
        const v = view.buffer.get(i);
        if (v == .Instance and classMatches(v.Instance, &node_class_hit, NODE_FQN)) {
            auditWalkNode(v.Instance, major, depth + 1, @intFromPtr(node.cell), @tagName(fate));
        }
    }
}

/// Post-sweep: re-walk the audited records; a node that now reads as
/// poisoned/unmapped was freed THIS epoch despite the pre-sweep walk.
fn gcPostSweep(major: bool, epoch: usize) void {
    _ = major;
    audit_lock.lock();
    defer audit_lock.unlock();
    for (audit_records) |e| {
        const rec = e orelse continue;
        if (!pageMapped(@intFromPtr(rec.cell))) {
            std.debug.print("[post-sweep] record cell unmapped {x} epoch={d}\n", .{ @intFromPtr(rec.cell), epoch });
            continue;
        }
        const g = rec.borrow();
        const map_v = g.get().getCached(&fn_rec_map, "map");
        g.deinit();
        const mv = map_v orelse continue;
        if (mv != .Instance) continue;
        const node_v: Value = blk: {
            const g2 = mv.Instance.borrow();
            defer g2.deinit();
            break :blk g2.get().getCached(&fn_node, "node") orelse continue;
        };
        if (node_v != .Instance) continue;
        postWalk(node_v.Instance, 0, epoch, @intFromPtr(mv.Instance.cell));
    }
}

fn postWalk(node: ObjRef(InstanceData), depth: u32, epoch: usize, parent: usize) void {
    if (depth > 8) return;
    const cp = @intFromPtr(node.cell);
    if (!pageMapped(cp)) {
        std.debug.print("[post-sweep] SWEPT node {x} depth={d} parent={x} epoch={d}\n", .{ cp, depth, parent, epoch });
        return;
    }
    const fp = @intFromPtr(node.cell.data.fields.items.ptr);
    if ((fp >> 47) != 0 or node.cell.data.fields.items.len > 64) {
        std.debug.print("[post-sweep] POISONED node {x} fields={x}/{d} depth={d} parent={x} epoch={d}\n", .{ cp, fp, node.cell.data.fields.items.len, depth, parent, epoch });
        return;
    }
    const null_owner: Value = .Null;
    const view = NodeView.read(node, &null_owner) orelse return;
    var i: usize = 0;
    const n = view.buffer.len();
    while (i < n) : (i += 1) {
        const v = view.buffer.get(i);
        if (v == .Instance) postWalk(v.Instance, depth + 1, epoch, cp);
    }
}

fn gcAudit(major: bool, epoch: usize) void {
    _ = epoch;
    audit_lock.lock();
    defer audit_lock.unlock();
    std.debug.print("[gc-audit] commits={d} registered={d} major={}\n", .{ audit_commits.load(.monotonic), @min(audit_next, audit_records.len), major });
    for (audit_records) |e| {
        const rec = e orelse continue;
        const rec_fate = runtime.gc.cellSweepFate(&rec.cell.hdr, major);
        if (rec_fate == .white) continue; // the record itself died (map gone) — fine
        const g = rec.borrow();
        const map_v = g.get().getCached(&fn_rec_map, "map") orelse {
            g.deinit();
            continue;
        };
        g.deinit();
        if (map_v != .Instance) continue;
        const map_fate = runtime.gc.cellSweepFate(&map_v.Instance.cell.hdr, major);
        if (map_fate == .white) {
            std.debug.print("[gc-audit] WHITE map {x} under {s} record {x} major={}\n", .{ @intFromPtr(map_v.Instance.cell), @tagName(rec_fate), @intFromPtr(rec.cell), major });
            continue;
        }
        // A tenured map under a registered record is a STALE entry (a
        // finished round, or commits moved to another record in the
        // chain): its unreferenced children are legitimately white.
        // Audit only records whose map is CURRENT (marked this epoch).
        if (map_fate == .tenured and !major) continue;
        const node_v: Value = blk: {
            const g2 = map_v.Instance.borrow();
            defer g2.deinit();
            break :blk g2.get().getCached(&fn_node, "node") orelse continue;
        };
        if (node_v != .Instance) continue;
        std.debug.print("[gc-audit] rec {x}={s} map {x}={s} root {x}={s}\n", .{ @intFromPtr(rec.cell), @tagName(rec_fate), @intFromPtr(map_v.Instance.cell), @tagName(map_fate), @intFromPtr(node_v.Instance.cell), auditFate(node_v.Instance, major) });
        auditWalkNode(node_v.Instance, major, 0, @intFromPtr(map_v.Instance.cell), @tagName(map_fate));
    }
}

const RecordRead = struct { rec: ObjRef(InstanceData), map: Value, mod: i32 };

/// The current-snapshot record of `map_inst` with its stored map and
/// modification count; null unless the record was BORN in the gate's
/// snapshot (the writableRecord fast path — no record creation, no
/// recordModified).
fn currentBornRecord(map_inst: ObjRef(InstanceData), gate: ir.snapshot_fast.WriteGate) ?RecordRead {
    const first: Value = blk: {
        const g = map_inst.borrow();
        defer g.deinit();
        break :blk g.get().getCached(&fn_first_rec, "firstStateRecord") orelse return null;
    };
    if (first != .Instance) return null;
    const rec_v = ir.snapshot_fast.recordForWrite(&first, gate) orelse return null;
    if (rec_v != .Instance) return null;
    const g = rec_v.Instance.borrow();
    defer g.deinit();
    const d = g.get();
    const sid = d.getCached(&fn_rec_sid, "snapshotId") orelse return null;
    const sid_i: i64 = switch (sid) {
        .Int => |x| x,
        .Long => |x| x,
        else => return null,
    };
    if (sid_i != gate.id) return null;
    const map_v = d.getCached(&fn_rec_map, "map") orelse return null;
    const mod_v = d.getCached(&fn_rec_mod, "modification") orelse return null;
    if (map_v != .Instance or mod_v != .Int) return null;
    if (!classMatches(map_v.Instance, &map_class_hit, MAP_FQN)) return null;
    return .{ .rec = rec_v.Instance, .map = map_v, .mod = mod_v.Int };
}

/// Serve `SnapshotStateMap.put(key, value)` end to end. Returns the
/// previous value (retained) / Null; null bails to the interpreted
/// mutate cycle with nothing mutated.
fn ssmTrace(comptime why: []const u8) void {
    const S = struct {
        var state: u8 = 0;
    };
    if (S.state == 0) S.state = if (runtime.envOnce("KLIO_SSMPUT_TRACE") != null) 2 else 1;
    if (S.state == 2) std.debug.print("[ssmput] bail: " ++ why ++ "\n", .{});
}

fn ssmPhase(comptime tag: []const u8) void {
    const S = struct {
        var state: u8 = 0;
    };
    if (S.state == 0) {
        S.state = if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT_TRACE") orelse "", "3")) 3 else 1;
    }
    if (S.state == 3) std.debug.print("[ssm:{d}] " ++ tag ++ "\n", .{std.Thread.getCurrentId()});
}

pub fn trySnapshotMapPut(self: *VmHost, a: Allocator, map_inst: ObjRef(InstanceData), key: *const Value, value: *const Value) Allocator.Error!?Value {
    // KLIO_SSMPUT=0 restores the interpreted mutate cycle (bisect). The
    // GC crash that kept this opt-in was the perm-mint birth-edge hole
    // (worker mints are permanent; a host mint holds nursery references
    // from birth with no barrier) — fixed at gc.register.
    const S = struct {
        var state: u8 = 0;
    };
    if (S.state == 0) {
        S.state = if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT") orelse "1", "0")) 2 else 1;
    }
    if (S.state == 2) return null;
    if (!isSnapshotMapClass(map_inst)) return null;
    if (!keyHostable(key)) {
        ssmTrace("key");
        return null;
    }
    const globals = host_globals.composeSnapshotGlobals(self) orelse {
        ssmTrace("globals");
        return null;
    };
    const sync_obj = snapshotMapSync(self) orelse {
        ssmTrace("sync-global");
        return null;
    };
    const sync_key = sync_obj.lockIdentity() orelse {
        ssmTrace("sync-identity");
        return null;
    };
    if (!globalWriteObserversEmpty(self)) {
        ssmTrace("write-observers");
        return null;
    }

    var attempts: u32 = 0;
    while (attempts < 64) : (attempts += 1) {
        // A concurrent committer REPLACES record.map, unrooting the map
        // this attempt reads (and the previous value inside its buffers)
        // while they sit in native locals the collector cannot see — pin
        // for the attempt, and hold a reference under reclaim.
        const km = runtime.keepaliveMark();
        defer runtime.keepaliveRestore(km);
        // Read phase, mirroring mutate's `synchronized(sync) { ... }`.
        if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT_TRACE") orelse "", "3")) {
            std.debug.print("[ssm:{d}] enter gc={} reclaim={}\n", .{ std.Thread.getCurrentId(), runtime.gc.gc_enabled, runtime.reclaimEnabled() });
        } else ssmPhase("enter");
        if (!try concurrent.monitorEnter(sync_key)) return null;
        const gate = ir.snapshot_fast.globalWriteGate(&globals.ts, &globals.gs) orelse {
            _ = try concurrent.monitorExit(sync_key);
            ssmTrace("write-gate");
            return null;
        };
        const r0 = currentBornRecord(map_inst, gate) orelse {
            _ = try concurrent.monitorExit(sync_key);
            ssmTrace("record");
            return null;
        };
        const expected_mod = r0.mod;
        const old_map = r0.map;
        if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT") orelse "1", "5")) {
            if (!mapTrieValid(old_map)) {
                std.debug.print("[ssm-CORRUPT] old_map invalid at READ, map_inst={x} thread={d}\n", .{ @intFromPtr(map_inst.cell), std.Thread.getCurrentId() });
                _ = try concurrent.monitorExit(sync_key);
                return null;
            }
        }
        if (runtime.reclaimEnabled()) old_map.retain();
        defer if (runtime.reclaimEnabled()) old_map.release(a);
        runtime.keepalivePush(old_map);
        const old_size: i32 = blk: {
            const g = old_map.Instance.borrow();
            const sv = g.get().getCached(&fn_size, "size");
            g.deinit();
            const s = sv orelse {
                _ = try concurrent.monitorExit(sync_key);
                return null;
            };
            if (s != .Int) {
                _ = try concurrent.monitorExit(sync_key);
                return null;
            }
            break :blk s.Int;
        };
        const full_lock = std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT") orelse "1", "4");
        if (!full_lock) _ = try concurrent.monitorExit(sync_key);

        ssmPhase("read-done");
        // Compute phase (unlocked): the interpreted cycle's exact
        // builder()/put/build sequence, composed from the proven builder
        // serves. `old_size` is read above only to keep the read-phase
        // shape; the builder tracks size itself.
        _ = old_size;
        const builder_v = (try tryBuilder(self, a, old_map.Instance)) orelse return null;
        if (builder_v != .Instance) return null;
        runtime.keepalivePush(builder_v);
        defer if (runtime.reclaimEnabled()) builder_v.release(a);
        const prev = (try tryPut(self, a, builder_v.Instance, key, value)) orelse return null;
        const new_map = (try tryBuild(self, a, builder_v.Instance)) orelse {
            if (runtime.reclaimEnabled()) prev.release(a);
            return null;
        };
        if (new_map == .Instance and ObjRef(InstanceData).ptrEq(new_map.Instance, old_map.Instance)) {
            // Node unchanged (identical value already present): mutate's
            // `newMap == oldMap` break — no CAS.
            if (runtime.reclaimEnabled()) new_map.release(a);
            return prev;
        }
        runtime.keepalivePush(new_map);
        ssmPhase("minted");

        // KLIO_SSMPUT=2: compute-only bisect mode — mint then bail to the
        // interpreted cycle without ever committing.
        if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT") orelse "1", "2")) {
            if (runtime.reclaimEnabled()) {
                new_map.release(a);
                prev.release(a);
            }
            return null;
        }
        // CAS phase, mirroring `writable { attemptUpdate(mod, newMap) }`.
        if (!full_lock and !try concurrent.monitorEnter(sync_key)) {
            if (runtime.reclaimEnabled()) {
                new_map.release(a);
                prev.release(a);
            }
            return null;
        }
        const gate2 = ir.snapshot_fast.globalWriteGate(&globals.ts, &globals.gs) orelse {
            _ = try concurrent.monitorExit(sync_key);
            if (runtime.reclaimEnabled()) {
                new_map.release(a);
                prev.release(a);
            }
            return null;
        };
        const r2 = currentBornRecord(map_inst, gate2) orelse {
            _ = try concurrent.monitorExit(sync_key);
            if (runtime.reclaimEnabled()) {
                new_map.release(a);
                prev.release(a);
            }
            return null;
        };
        ssmPhase("cas");
        var committed = false;
        if (r2.mod == expected_mod) {
            const g = r2.rec.borrowMut();
            defer g.deinit();
            const d = g.get();
            // The record's storage names must be the plain spellings —
            // `define` CREATES a missing field, and an owner-qualified
            // twin surface would leave readers on the stale slot.
            if (d.get("map") == null or d.get("modification") == null) {
                _ = try concurrent.monitorExit(sync_key);
                if (runtime.reclaimEnabled()) {
                    new_map.release(a);
                    prev.release(a);
                }
                ssmTrace("record-field-names");
                return null;
            }
            const mode = runtime.envOnce("KLIO_SSMPUT") orelse "1";
            if (!std.mem.eql(u8, mode, "6")) try d.define(a, "map", new_map);
            if (!std.mem.eql(u8, mode, "7")) try d.define(a, "modification", Value.newInt(expected_mod + 1));
            committed = true;
        }
        _ = try concurrent.monitorExit(sync_key);
        if (committed) {
            ssmPhase("committed");
            if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT") orelse "0", "8")) {
                const c8n = audit_commits.load(.monotonic);
                if (c8n % 100 == 0) {
                    std.debug.print("[ssm-id] commit#{d} snap_id={d} rec={x}\n", .{ c8n, gate2.id, @intFromPtr(r2.rec.cell) });
                }
                _ = audit_commits.fetchAdd(1, .monotonic);
                auditRegisterRecord(r2.rec);
                const S8 = struct {
                    var once: bool = false;
                };
                if (!S8.once) {
                    S8.once = true;
                    const g8 = r2.rec.borrow();
                    defer g8.deinit();
                    std.debug.print("[ssm-fields] record fields:", .{});
                    for (g8.get().fields.items) |f| {
                        std.debug.print(" <{f}>", .{std.zig.fmtString(f.name)});
                    }
                    std.debug.print("\n", .{});
                }
            }
            if (std.mem.eql(u8, runtime.envOnce("KLIO_SSMPUT") orelse "1", "5")) {
                const root: usize = blk: {
                    const g2 = new_map.Instance.borrow();
                    defer g2.deinit();
                    const nv2 = g2.get().getCached(&fn_node, "node") orelse break :blk 0;
                    break :blk if (nv2 == .Instance) @intFromPtr(nv2.Instance.cell) else 0;
                };
                std.debug.print("[ssm-commit] map={x} newmap={x} root={x} t={d}\n", .{ @intFromPtr(map_inst.cell), @intFromPtr(new_map.Instance.cell), root, std.Thread.getCurrentId() });
                if (!mapTrieValid(new_map)) {
                    std.debug.print("[ssm-CORRUPT] new_map invalid at COMMIT, thread={d}\n", .{std.Thread.getCurrentId()});
                }
            }
            return prev;
        }
        if (runtime.reclaimEnabled()) {
            new_map.release(a);
            prev.release(a);
        }
        // Another writer moved `modification`: retry the whole cycle,
        // exactly as the interpreted mutate loop does.
    }
    return null;
}

/// Serve `builder.build()`: the stored map when the node is unchanged,
/// else a fresh PersistentHashMap over (node, size) plus a fresh
/// ownership for the builder. Bails on any shape surprise.
pub fn tryBuild(self: *VmHost, a: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!?Value {
    if (!isBuilderClass(inst)) return null;
    const km = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(km);
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
    runtime.keepalivePush(.{ .Instance = new_map });
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
