//! Host fast path for the Compose-vendored persistent hash map builder mutation,
//! replacing the interpreted `builder()`/`put`/`build()` cycle `SnapshotStateMap.put`
//! runs per write. The trie is host-readable (TrieNode {dataMap, nodeMap, buffer,
//! ownedBy}), so the host runs the vendored `TrieNode.mutablePut` over it; keys must
//! be scalars or strings, and Float/Double, Null and shape surprises bail. A node
//! mutates in place only when `node.ownedBy === builder.ownership`, else a fresh one
//! is minted from a captured template; a bail can only happen before the first mutation.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir");

const vmhost = @import("vmhost.zig");
const host_resolved = @import("host_resolved.zig");
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

var fn_map = InstanceData.SlotCache.init(0);
var fn_ownership = InstanceData.SlotCache.init(0);
var fn_node = InstanceData.SlotCache.init(0);
var fn_modcount = InstanceData.SlotCache.init(0);
var fn_size = InstanceData.SlotCache.init(0);
var fn_datamap = InstanceData.SlotCache.init(0);
var fn_nodemap = InstanceData.SlotCache.init(0);
var fn_buffer = InstanceData.SlotCache.init(0);
var fn_ownedby = InstanceData.SlotCache.init(0);

/// The name the class's layout gives slot `i` of `d`.
fn slotName(d: *const InstanceData, i: usize) []const u8 {
    const layout = d.class.asPtrConst().layout_slots;
    return if (i < layout.len) layout[i].name else "";
}

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

/// Key shapes the host hashes at kotlinc's exact semantics; Float, Double and Null bail.
fn keyHostable(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .Char, .Bool, .UInt, .ULong, .UShort, .UByte, .String => true,
        else => false,
    };
}

/// `a == b` for two hostable keys: a differing runtime type is `false`, as kotlinc's
/// typed `equals` answers.
fn keyEq(a: *const Value, b: *const Value) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return Value.structuralEq(a, b);
}

/// The vendored `===`: reference shapes by cell, scalars by tag and bits.
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

/// TrieNode minting template: the class and the role of each of its four slots.
const NodeTmpl = struct {
    gen: u32 = 0,
    class: ?ObjRef(ClassDef) = null,
    order: [4]u8 = .{ 0, 0, 0, 0 },
};
threadlocal var node_tmpl: NodeTmpl = .{};

fn cacheGen() u32 {
    return @import("host_util.zig").dispatchCacheGen();
}

fn nodeTemplate(node: ObjRef(InstanceData)) ?*const NodeTmpl {
    const gen = cacheGen();
    if (node_tmpl.gen == gen) return &node_tmpl;
    if (node_tmpl.class) |c| c.deinit();
    node_tmpl.class = null;
    const g = node.borrow();
    defer g.deinit();
    const d = g.get();
    if (d.slots.len != 4) return null;
    var tmpl: NodeTmpl = .{ .gen = gen, .class = d.class.clone() };
    for (0..4) |i| {
        const name = slotName(d, i);
        if (std.mem.eql(u8, name, "dataMap")) {
            tmpl.order[i] = 0;
        } else if (std.mem.eql(u8, name, "nodeMap")) {
            tmpl.order[i] = 1;
        } else if (std.mem.eql(u8, name, "buffer")) {
            tmpl.order[i] = 2;
        } else if (std.mem.eql(u8, name, "ownedBy")) {
            tmpl.order[i] = 3;
        } else {
            tmpl.class.?.deinit();
            return null;
        }
    }
    node_tmpl = tmpl;
    return &node_tmpl;
}

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
        if (buf.Array.primKind() != null) return null;
        const owned = ob == .Instance and owner.* == .Instance and
            ObjRef(InstanceData).ptrEq(ob.Instance, owner.Instance);
        return .{ .inst = inst, .data_map = dm.Int, .node_map = nm.Int, .buffer = buf.Array, .owned = owned };
    }
};

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

fn mintNode(ctx: *PutCtx, data_map: i32, node_map: i32, items: []const Value, owned_by: Value) Allocator.Error!Value {
    retainAll(items);
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacity(ctx.a, items.len);
    for (items) |v| list.appendAssumeCapacity(v);
    const buf_v = ArrayData.fromBoxedList(try runtime.ValueList.init(ctx.a, list));
    if (runtime.reclaimEnabled() and owned_by == .Instance) owned_by.retain();
    const inst = try newNode(ctx, data_map, node_map, buf_v, owned_by);
    const v: Value = .{ .Instance = inst };
    // Collect-at-alloc: a fresh node reachable only from native locals is unrooted.
    runtime.keepalivePush(v);
    return v;
}

/// A trie node of the template's class with its slots filled by role.
fn newNode(ctx: *PutCtx, data_map: i32, node_map: i32, buf_v: Value, owned_by: Value) Allocator.Error!ObjRef(InstanceData) {
    const t = ctx.tmpl;
    var vals: [4]Value = undefined;
    for (t.order, &vals) |which, *slot| slot.* = switch (which) {
        0 => Value.newInt(data_map),
        1 => Value.newInt(node_map),
        2 => buf_v,
        else => owned_by,
    };
    return InstanceData.new(ctx.a, t.class.?.clone(), &vals, host_resolved.mintInstanceId(ctx.self));
}

/// In-place store of the node's mutable fields; the caller proved ownership.
fn storeNode(ctx: *PutCtx, view: *const NodeView, data_map: i32, node_map: i32, buffer: ?Value) Allocator.Error!void {
    const g = view.inst.borrowMut();
    defer g.deinit();
    const d = g.get();
    if (view.data_map != data_map) _ = d.store(ctx.a, "dataMap", Value.newInt(data_map));
    if (view.node_map != node_map) _ = d.store(ctx.a, "nodeMap", Value.newInt(node_map));
    if (buffer) |b| _ = d.store(ctx.a, "buffer", b);
}

// Bitmap arithmetic runs in the u32 domain: `mask - 1` on the i32 spelling overflows
// when the mask is bit 31.
fn keyIndexOf(view: *const NodeView, mask: u32) usize {
    return ENTRY_SIZE * @as(usize, @popCount(@as(u32, @bitCast(view.data_map)) & (mask - 1)));
}

fn nodeIndexOf(view: *const NodeView, mask: u32) usize {
    return view.buffer.len() - 1 - @as(usize, @popCount(@as(u32, @bitCast(view.node_map)) & (mask - 1)));
}

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

/// `buffer.replaceEntryWithNode` as a fresh snapshot; the node lands at
/// `nodeIndex - ENTRY_SIZE`.
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

/// The exact `TrieNode.mutablePut` walk; a null bail reaches the interpreter before any
/// mutation.
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
        // mutableMoveEntryToNode: the stored key's own hash drives the subtree, so it
        // must be hostable.
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
        if (view.buffer.len() == 1) {
            const nv = NodeView.read(new_node.Instance, &ctx.owner) orelse return null;
            if (nv.buffer.len() == ENTRY_SIZE and nv.node_map == 0) {
                try storeNode(ctx, &nv, view.node_map, nv.node_map, null);
                return new_node;
            }
        }
        if (view.owned) {
            // `set` retains for the slot; drop the walk's ref to the fresh child.
            view.buffer.set(ctx.a, node_index, new_node);
            if (runtime.reclaimEnabled()) new_node.release(ctx.a);
            return .{ .Instance = node_inst };
        }
        const new_buf = try bufferCopyReplace(ctx, view.buffer, node_index, &new_node);
        if (runtime.reclaimEnabled()) new_node.release(ctx.a);
        return try mintNodeFromBuf(ctx, view.data_map, view.node_map, new_buf);
    }
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

/// Mint over an already-built buffer whose elements the caller retained.
fn mintNodeFromBuf(ctx: *PutCtx, data_map: i32, node_map: i32, buf_v: Value) Allocator.Error!Value {
    if (runtime.reclaimEnabled() and ctx.owner == .Instance) ctx.owner.retain();
    const inst = try newNode(ctx, data_map, node_map, buf_v, ctx.owner);
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

const BuilderTmpl = struct {
    gen: u32 = 0,
    class: ?ObjRef(ClassDef) = null,
    owner_class: ?ObjRef(ClassDef) = null,
    count: u8 = 0,
    /// Slot roles: 0 map, 1 ownership, 2 node, 3 operationResult, 4 modCount,
    /// 5 size, 6 a null-initialized lazy view cache (`_keys`/`_values` and twins).
    order: [12]u8 = @splat(0),
};
threadlocal var builder_tmpl: BuilderTmpl = .{};

fn isViewCacheName(name: []const u8) bool {
    const last = if (std.mem.findScalarLast(u8, name, 0x1f)) |i| name[i + 1 ..] else name;
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
        std.debug.print("[mapmut] builder slots ({d}):", .{d.slots.len});
        for (0..d.slots.len) |i| std.debug.print(" {s}", .{slotName(d, i)});
        std.debug.print("\n", .{});
    }
    if (d.slots.len > 12) return;
    var tmpl: BuilderTmpl = .{ .gen = gen, .count = @intCast(d.slots.len) };
    var seen: u8 = 0;
    for (0..d.slots.len) |i| {
        const name = slotName(d, i);
        if (std.mem.eql(u8, name, "map")) {
            tmpl.order[i] = 0;
        } else if (std.mem.eql(u8, name, "ownership")) {
            tmpl.order[i] = 1;
        } else if (std.mem.eql(u8, name, "node")) {
            tmpl.order[i] = 2;
        } else if (std.mem.eql(u8, name, "operationResult")) {
            tmpl.order[i] = 3;
        } else if (std.mem.eql(u8, name, "modCount")) {
            tmpl.order[i] = 4;
        } else if (std.mem.eql(u8, name, "size")) {
            tmpl.order[i] = 5;
        } else if (isViewCacheName(name)) {
            // Lazy view caches, owner-qualified twins included (0x1f separator).
            tmpl.order[i] = 6;
            continue;
        } else {
            if (trace) std.debug.print("[mapmut] capture bail unknown slot {s} hex={x}\n", .{ name, name });
            return;
        }
        seen |= @as(u8, 1) << @intCast(tmpl.order[i]);
    }
    // All six declared fields must be present; a partial shape is never minted.
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
    if (og.get().slots.len != 0) {
        if (trace) std.debug.print("[mapmut] capture bail owner slots={d}\n", .{og.get().slots.len});
        return;
    }
    tmpl.class = d.class.clone();
    tmpl.owner_class = og.get().class.clone();
    builder_tmpl = tmpl;
    if (trace) std.debug.print("[mapmut] capture OK count={d} gen={d}\n", .{ tmpl.count, tmpl.gen });
}

/// Serve `map.builder()` with no interpreted ctor chain; bails until `tryPut` captured
/// the template.
pub fn tryBuilder(self: *VmHost, a: Allocator, map_inst: ObjRef(InstanceData)) Allocator.Error!?Value {
    if (!classMatches(map_inst, &map_class_hit, MAP_FQN)) return null;
    const km = self.ka.mark();
    defer self.ka.restore(km);
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
    const owner_inst = try InstanceData.new(a, t.owner_class.?.clone(), &.{}, host_resolved.mintInstanceId(self));
    self.ka.push(.{ .Instance = owner_inst });
    const map_v: Value = .{ .Instance = map_inst };
    var vals: [12]Value = undefined;
    for (t.order[0..t.count], vals[0..t.count]) |which, *slot| {
        slot.* = switch (which) {
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
    }
    const inst = try InstanceData.new(a, t.class.?.clone(), vals[0..t.count], host_resolved.mintInstanceId(self));
    return .{ .Instance = inst };
}

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

/// Serve `builder.put`: the previous value (retained) or Null; null bails.
pub fn tryPut(self: *VmHost, a: Allocator, inst: ObjRef(InstanceData), key: *const Value, value: *const Value) Allocator.Error!?Value {
    if (!isBuilderClass(inst)) return null;
    const km = self.ka.mark();
    defer self.ka.restore(km);
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
            // A non-identical result is freshly minted; `store` consumes it and releases
            // the old node.
            _ = d.store(a, "node", new_node);
        }
        if (ctx.size_delta != 0) {
            _ = d.store(a, "size", Value.newInt(st.size + ctx.size_delta));
            ctx.modcount_delta += ctx.size_delta;
        }
        if (ctx.modcount_delta != 0) {
            _ = d.store(a, "modCount", Value.newInt(st.modcount + ctx.modcount_delta));
        }
        if (runtime.reclaimEnabled()) ctx.op_result.retain();
        _ = d.store(a, "operationResult", ctx.op_result);
    }
    if (runtime.reclaimEnabled()) ctx.op_result.retain();
    return ctx.op_result;
}

// The steady-state write cycle (`mutate { it.put(key, value) }` under the observer-free
// GlobalSnapshot) replayed host-side: read the record under the map file's `sync` monitor,
// compute the new map fully persistently (owner = Null, so every trie path mints), then
// re-check `modification` under the monitor and assign, as `attemptUpdate` does.

const SSM_FQN = "androidx.compose.runtime.snapshots.SnapshotStateMap";
var ssm_class_hit = std.atomic.Value(usize).init(0);
var fn_first_rec = InstanceData.SlotCache.init(0);
var fn_rec_map = InstanceData.SlotCache.init(0);
var fn_rec_mod = InstanceData.SlotCache.init(0);
var fn_rec_sid = InstanceData.SlotCache.init(0);

pub fn isSnapshotMapClass(inst: ObjRef(InstanceData)) bool {
    return classMatches(inst, &ssm_class_hit, SSM_FQN);
}

/// Top-level property `w`'s value, its file initialized first; null when
/// the tables lack it or its initializer failed.
fn staticOf(self: *VmHost, a: Allocator, w: runtime.WellKnownStatic) Allocator.Error!?Value {
    const r = (try host_resolved.wellKnownStatic(self, a, w)) orelse return null;
    return switch (r) {
        .ok => |v| v,
        .err => null,
    };
}

fn snapshotMapSync(self: *VmHost, a: Allocator) Allocator.Error!?Value {
    const v = (try staticOf(self, a, .compose_snapshot_map_sync)) orelse return null;
    if (v != .Instance) return null;
    return v;
}

/// notifyWrite is a provable no-op only while `globalWriteObservers` (Snapshot.kt) is
/// empty.
fn globalWriteObserversEmpty(self: *VmHost, a: Allocator) Allocator.Error!bool {
    const v = (try staticOf(self, a, .compose_global_write_observers)) orelse {
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

/// Whether the page holding `addr` is mapped (`KLIO_SSMPUT=5` trie shape audit).
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
        const fslice = node.cell.data.slots;
        const fp = @intFromPtr(fslice.ptr);
        if (fslice.len > 64 or (fp >> 47) != 0 or (fslice.len != 0 and !pageMapped(fp))) {
            std.debug.print("[ssm-rot] node {x} slots ptr={x} len={d} depth={d}\n", .{ cp, fp, fslice.len, depth });
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

// Pre-sweep mark audit (`KLIO_SSMPUT=8`): re-walk a registered record's trie after
// marking, naming any cell the sweep would free.
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
    // Walk the whole record chain: commits and reads may target different records.
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
    var i: usize = 0;
    const n = view.buffer.len();
    while (i < n) : (i += 1) {
        const v = view.buffer.get(i);
        if (v == .Instance and classMatches(v.Instance, &node_class_hit, NODE_FQN)) {
            auditWalkNode(v.Instance, major, depth + 1, @intFromPtr(node.cell), @tagName(fate));
        }
    }
}

/// Post-sweep: a node that now reads poisoned or unmapped was freed this epoch despite
/// the pre-sweep walk.
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
    const fp = @intFromPtr(node.cell.data.slots.ptr);
    if ((fp >> 47) != 0 or node.cell.data.slots.len > 64) {
        std.debug.print("[post-sweep] POISONED node {x} slots={x}/{d} depth={d} parent={x} epoch={d}\n", .{ cp, fp, node.cell.data.slots.len, depth, parent, epoch });
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
        if (rec_fate == .white) continue; // the record itself died, so its map is gone
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
        // A tenured map is stale, so its unreferenced children are legitimately white.
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

/// The current-snapshot record with its map and modification count; null unless the
/// record was born in the gate's snapshot.
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

/// Serve `SnapshotStateMap.put(key, value)` end to end. Returns the previous
/// value (retained) or Null; null bails to the interpreted cycle, nothing mutated.
pub fn trySnapshotMapPut(self: *VmHost, a: Allocator, map_inst: ObjRef(InstanceData), key: *const Value, value: *const Value) Allocator.Error!?Value {
    // `KLIO_SSMPUT=0` restores the interpreted mutate cycle (bisect).
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
    const ts = (try staticOf(self, a, .compose_thread_snapshot)) orelse {
        ssmTrace("globals");
        return null;
    };
    const gs = (try staticOf(self, a, .compose_global_snapshot)) orelse {
        ssmTrace("globals");
        return null;
    };
    if (ts != .Instance or gs != .Instance) {
        ssmTrace("globals");
        return null;
    }
    const globals: struct { ts: Value, gs: Value } = .{ .ts = ts, .gs = gs };
    const sync_obj = (try snapshotMapSync(self, a)) orelse {
        ssmTrace("sync-global");
        return null;
    };
    const sync_key = sync_obj.lockIdentity() orelse {
        ssmTrace("sync-identity");
        return null;
    };
    if (!try globalWriteObserversEmpty(self, a)) {
        ssmTrace("write-observers");
        return null;
    }

    var attempts: u32 = 0;
    while (attempts < 64) : (attempts += 1) {
        // A concurrent committer replaces `record.map`, unrooting the map held only in
        // native locals: pin it.
        const km = self.ka.mark();
        defer self.ka.restore(km);
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
        self.ka.push(old_map);
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
        // Compute phase (unlocked): the interpreted cycle's builder()/put/build sequence.
        _ = old_size;
        const builder_v = (try tryBuilder(self, a, old_map.Instance)) orelse return null;
        if (builder_v != .Instance) return null;
        self.ka.push(builder_v);
        defer if (runtime.reclaimEnabled()) builder_v.release(a);
        const prev = (try tryPut(self, a, builder_v.Instance, key, value)) orelse return null;
        const new_map = (try tryBuild(self, a, builder_v.Instance)) orelse {
            if (runtime.reclaimEnabled()) prev.release(a);
            return null;
        };
        if (new_map == .Instance and ObjRef(InstanceData).ptrEq(new_map.Instance, old_map.Instance)) {
            // Node unchanged (identical value already present): mutate's `newMap ==
            // oldMap` break.
            if (runtime.reclaimEnabled()) new_map.release(a);
            return prev;
        }
        self.ka.push(new_map);
        ssmPhase("minted");

        // `KLIO_SSMPUT=2`: mint then bail without committing, for bisecting.
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
            // The record must hold both slots under their plain names, so no
            // partial write is made.
            if (d.slotIndex("map") == null or d.slotIndex("modification") == null) {
                _ = try concurrent.monitorExit(sync_key);
                if (runtime.reclaimEnabled()) {
                    new_map.release(a);
                    prev.release(a);
                }
                ssmTrace("record-field-names");
                return null;
            }
            const mode = runtime.envOnce("KLIO_SSMPUT") orelse "1";
            if (!std.mem.eql(u8, mode, "6")) _ = d.store(a, "map", new_map);
            if (!std.mem.eql(u8, mode, "7")) _ = d.store(a, "modification", Value.newInt(expected_mod + 1));
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
                    std.debug.print("[ssm-fields] record slots:", .{});
                    for (0..g8.get().slots.len) |i| {
                        std.debug.print(" <{f}>", .{std.zig.fmtString(slotName(g8.get(), i))});
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
    }
    return null;
}

/// Serve `builder.build()`: the stored map when the node is unchanged, else a fresh
/// PersistentHashMap plus ownership.
pub fn tryBuild(self: *VmHost, a: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!?Value {
    if (!isBuilderClass(inst)) return null;
    const km = self.ka.mark();
    defer self.ka.restore(km);
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
    var vals: [8]Value = undefined;
    const n_slots = blk: {
        const g = map_v.Instance.borrow();
        defer g.deinit();
        const d = g.get();
        if (d.slots.len > vals.len) return null;
        for (vals[0..d.slots.len], 0..) |*slot, i| {
            const name = slotName(d, i);
            slot.* = if (std.mem.eql(u8, name, "node")) node: {
                if (runtime.reclaimEnabled()) st.node.retain();
                break :node st.node;
            } else if (std.mem.eql(u8, name, "size"))
                Value.newInt(st.size)
            else if (std.mem.eql(u8, name, "_keys") or std.mem.eql(u8, name, "_values"))
                Value.Null
            else
                return null;
        }
        break :blk d.slots.len;
    };
    const new_map = try InstanceData.new(a, map_v.Instance.asPtrConst().class.clone(), vals[0..n_slots], host_resolved.mintInstanceId(self));
    self.ka.push(.{ .Instance = new_map });
    const new_owner: Value = blk: {
        if (st.ownership != .Instance) return null;
        const owner = st.ownership.Instance.asPtrConst();
        if (owner.slots.len != 0) return null;
        const oinst = try InstanceData.new(a, owner.class.clone(), &.{}, host_resolved.mintInstanceId(self));
        break :blk .{ .Instance = oinst };
    };
    const new_map_v: Value = .{ .Instance = new_map };
    {
        const g = inst.borrowMut();
        defer g.deinit();
        const d = g.get();
        _ = d.store(a, "map", new_map_v);
        _ = d.store(a, "ownership", new_owner);
    }
    if (runtime.reclaimEnabled()) new_map_v.retain();
    return new_map_v;
}
