//! Field access on an instance receiver: stored/getter resolution, the companion
//! walks a bare name resolves through, and the inner-class outer-instance chain.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const root = @import("../../interp_ir.zig");
const host_globals = @import("../host_globals.zig");
const host_call_member = @import("../host_call_member.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const host_fields = @import("../host_fields.zig");
const getField = host_fields.getField;

const common = @import("common.zig");
const className = common.className;
const containsStr = common.containsStr;
const enclosingNameOf = common.enclosingNameOf;
const errRes = common.errRes;
const evalGetterTagged = common.evalGetterTagged;
const firstSupertype = common.firstSupertype;
const frozenList = common.frozenList;
const lookupPairFunc = common.lookupPairFunc;
const lookupPairFuncHop = common.lookupPairFuncHop;
const ok = common.ok;
const withFieldResolvePair = common.withFieldResolvePair;

const enum_static = @import("enum_static.zig");
const enumStaticNameHits = enum_static.enumStaticNameHits;
const enumTableClass = enum_static.enumTableClass;
const enumTableDef = enum_static.enumTableDef;

const ext_props = @import("ext_props.zig");
const delegateCall = ext_props.delegateCall;
const delegatedPropRegistered = ext_props.delegatedPropRegistered;
const memberExtOwnerRead = ext_props.memberExtOwnerRead;
const runtimeClassDelegatesProp = ext_props.runtimeClassDelegatesProp;

const field_cache = @import("field_cache.zig");
const fieldReadCacheGet = field_cache.fieldReadCacheGet;
const fieldReadCachePut = field_cache.fieldReadCachePut;
const lateinitReadError = field_cache.lateinitReadError;
const storedNullIsLateinit = field_cache.storedNullIsLateinit;

pub fn instanceField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, member_probe: bool) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    const class_name = className(inst);
    // Field-read memo: one probe replaces the delegate walk, the getter BFS and the
    // stored-slot scan; the stored index re-verifies by name, since instances add slots.
    const cache_fqn = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    // Delegated body property: route through the delegate's `getValue`.
    const delegate_owner: bool = runtimeClassDelegatesProp(inst, name) or blk: {
        // With no `by`-delegated body properties at all, skip the supertype walk.
        {
            const g = self.module.borrow();
            const none = g.get().registry.delegated_body_props.count() == 0;
            g.deinit();
            if (none) break :blk false;
        }
        // Exact FQN only: a simple-name probe lets a namesake's delegated prop intercept.
        if (blk2: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk2 g.get().registry.delegated_body_props.contains(.{ .a = cache_fqn, .b = name });
        }) break :blk true;
        var cur: ?[]const u8 = firstSupertype(self, class_name);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cn| {
            cur = null;
            if (containsStr(seen.items, cn)) break;
            try seen.append(allocator, cn);
            if (delegatedPropRegistered(self, cn, name)) break :blk true;
            cur = firstSupertype(self, cn);
        }
        break :blk false;
    };
    if (delegate_owner) {
        const raw: ?Value = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().get(name);
        };
        if (raw) |d| {
            const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
            return try delegateCall(self, allocator, &d, "getValue", &.{ receiver.*, prop_ref }, receiver);
        }
    }
    const recv_fqn = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    // Resolve the custom getter under the most-derived-stored-prop override rule.
    const getter_fid = try resolveInstanceGetter(self, allocator, inst, class_name, recv_fqn, name);
    if (getter_fid) |fid| {
        const mptr: *const Module = self.module.asPtr();
        if (fid.int() >= mptr.funcCount()) {
            const msg = try std.fmt.allocPrint(allocator, "getter FuncId {d} out of range", .{fid.int()});
            return errRes(.{ .Type = msg });
        }
        fieldReadCachePut(self, inst, cache_fqn, name, .{ .getter = fid.int(), .stored_idx = root.ProgramImage.FieldReadHit.NONE });
        return try evalGetterTagged(self, allocator, fid, receiver.*, "site2500");
    }
    // An initialized `override val/var` keeps its own backing cell under the owner-mangled
    // key: a read takes the nearest owner in the chain, while `super.x` reads the base cell.
    if (blk: {
        const pg = self.module.borrow();
        defer pg.deinit();
        break :blk pg.get().registry.override_cell_props.count() != 0;
    }) {
        var cur2: ?[]const u8 = blk: {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        };
        var hops: u8 = 0;
        while (cur2) |cn2| : (hops += 1) {
            if (hops > 16) break;
            var kb: [256]u8 = undefined;
            const probe = std.fmt.bufPrint(&kb, "{s}\x1f{s}", .{ cn2, name }) catch break;
            const is_cell = blk: {
                const pg = self.module.borrow();
                defer pg.deinit();
                break :blk pg.get().registry.override_cell_props.contains(probe);
            };
            if (is_cell) {
                const g = inst.borrow();
                const owned = g.get().get(probe);
                g.deinit();
                if (owned) |v| return ok(v);
            }
            cur2 = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                const d = cg.get().get(cn2) orelse break :blk null;
                const dg = d.borrow();
                defer dg.deinit();
                const sups = dg.get().supertype_names;
                break :blk if (sups.len != 0) sups[0] else null;
            };
        }
    }
    // Raw instance slot.
    const slot: ?Value = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const fields = g.get().fields.items;
        for (fields, 0..) |f, fi| {
            if (std.mem.eql(u8, f.name, name)) {
                fieldReadCachePut(self, inst, cache_fqn, name, .{ .getter = root.ProgramImage.FieldReadHit.NONE, .stored_idx = @intCast(fi) });
                break :blk f.value;
            }
        }
        break :blk null;
    };
    if (slot) |v| {
        if (v == .Null) {
            if (storedNullIsLateinit(inst, name)) {
                return try lateinitReadError(allocator, name);
            }
        }
        if (v == .Delegate) {
            return try unwrapDelegate(self, allocator, v.Delegate, name);
        }
        return ok(v);
    }
    // Companion / parent / interface walk; the member probe resolves those itself.
    if (!member_probe) {
        if (try companionParentWalk(self, allocator, inst, name)) |v| return v;
        if (try outerInstanceChain(self, allocator, inst, name)) |v| return v;
        if (try enclosingCompanionWalk(self, allocator, inst, name)) |v| return v;
    }
    // Enum entry bare name. An entry with a body is its own subclass, sharing the parent's table.
    {
        const table = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk enumTableDef(g.get().class);
        };
        defer table.deinit();
        if (enumStaticNameHits(table, name)) {
            if (try host_globals.ensureEnumInit(self, table)) |e| return .{ .err = e };
        }
    }
    {
        const g = inst.borrow();
        const cg = enumTableClass(g.get().class);
        const is_enum = cg.get().is_enum;
        if (is_enum) {
            for (cg.get().enum_entries) |e| {
                if (std.mem.eql(u8, e.name, name)) {
                    const v = e.value;
                    cg.deinit();
                    g.deinit();
                    return ok(v);
                }
            }
            if (std.mem.eql(u8, name, "entries")) {
                var items: std.ArrayList(Value) = .empty;
                errdefer items.deinit(allocator);
                for (cg.get().enum_entries) |e| {
                    e.value.retain();
                    try items.append(allocator, e.value);
                }
                cg.deinit();
                g.deinit();
                return ok(try frozenList(allocator, items, true));
            }
        }
        cg.deinit();
        g.deinit();
    }
    // A companion member on this class, supertype or enclosing-class chain is in scope
    // unqualified; `getFieldInner`'s walk resolves it, so no same-named global shadows it.
    if (!member_probe and try enclosingCompanionDeclares(self, allocator, class_name, name)) {
        return null;
    }
    // Nested-class fallback. An `object` named in value position is its singleton
    // instance, never the class value; first access constructs it through the gate.
    if (!member_probe) {
        const has_global_class = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            break :blk cg.get().get(name) != null;
        };
        // The receiver's own nested classifier (or an enclosing class's) outranks a
        // same-simple-name class elsewhere; `getFieldInner` resolves it after this null.
        if (has_global_class) {
            const own_nested = blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                const oid = mg.get().classId(class_name) orelse break :blk false;
                break :blk mg.get().classIdNestedIn(oid, name) != null;
            };
            if (own_nested) return null;
        }
        const is_object = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            const def = cg.get().get(name) orelse break :blk false;
            const dg = def.borrow();
            defer dg.deinit();
            break :blk dg.get().is_object;
        };
        if (is_object) {
            switch (try host_globals.ensureObjectSingleton(self, name)) {
                .ok => |maybe| if (maybe) |v| {
                    if (v == .Instance) return ok(v);
                },
                .err => |e| return errRes(e),
            }
        }
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| {
            // A runtime-registered local object publishes its singleton under its own name.
            const local_runtime = blk: {
                const dg = def.borrow();
                defer dg.deinit();
                break :blk dg.get().is_local_runtime;
            };
            if (local_runtime) {
                const gg = self.globals.borrow();
                defer gg.deinit();
                if (gg.get().lookup(name)) |v| {
                    if (v == .Instance) return ok(v);
                }
            }
            return ok(.{ .Class = def });
        }
    }
    // Top-level global fallback. An implicit receiver outranks a top-level name, so
    // the executing member extension's declaring class goes first.
    if (!member_probe) {
        if (try memberExtOwnerRead(self, allocator, receiver, name)) |r| return r;
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(name)) |v| return ok(v);
    }
    return null;
}

/// Whether a companion on `class_name`'s class, supertype or enclosing-class chain
/// declares `name`. Keeps the class/global fallback from shadowing such a member.
pub fn enclosingCompanionDeclares(self: *VmHost, allocator: Allocator, class_name: []const u8, name: []const u8) Allocator.Error!bool {
    var cur: ?[]const u8 = class_name;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    while (cur) |cn| {
        cur = null;
        if (containsStr(seen.items, cn)) break;
        try seen.append(allocator, cn);
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cn);
        };
        if (comp_name) |comp| {
            switch (try host_globals.objectSingletonForMember(self, comp, name)) {
                .ok => |maybe| if (maybe != null) return true,
                .err => return false,
            }
        }
        if (firstSupertype(self, cn)) |sup| {
            cur = sup;
        } else {
            const g = self.module.borrow();
            defer g.deinit();
            cur = g.get().registry.enclosing_class.get(cn);
        }
    }
    return false;
}

pub fn resolveInstanceGetter(
    self: *VmHost,
    allocator: Allocator,
    inst: ObjRef(InstanceData),
    class_name: []const u8,
    recv_fqn: []const u8,
    name: []const u8,
) Allocator.Error!?FuncId {
    const own_is_qualified = !std.mem.eql(u8, recv_fqn, class_name);
    // Own class stores the property -> skip the getter walk entirely.
    {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        if (declaresStored(cg.get(), name)) return null;
    }
    var found: ?FuncId = null;
    if (own_is_qualified) {
        const pg = self.prog.borrow();
        defer pg.deinit();
        found = lookupPairFunc(pg.get().instance_prop_getters, recv_fqn, name);
    }
    if (found != null) return found;
    // Breadth-first over the full supertype closure, nearest first: `class D : I, B()`
    // lists interface `I` first, so `supertype_names[0]` alone never reaches `B`.
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    // Seed with the receiver's own class; pre-pushing a supertype's supers inverts the order.
    try queue.append(allocator, class_name);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cn = queue.items[head];
        if (seen.contains(cn)) continue;
        try seen.put(cn, {});
        const cdef: ?ObjRef(ClassDef) = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            break :blk cg.get().get(cn);
        };
        // A class in the chain that stores `name` overrides any higher base getter.
        if (cdef) |d| {
            const dg = d.borrow();
            const stored = declaresStored(dg.get(), name);
            dg.deinit();
            if (stored) break;
        }
        {
            const pg = self.prog.borrow();
            const hit = lookupPairFuncHop(self, pg.get().instance_prop_getters, cn, name);
            // A private property never participates in inheritance: an inherited private
            // getter cannot shadow a subclass's stored field. `head == 0` is the own class.
            const inherited = head != 0;
            const private_here = lookupPairFunc(pg.get().instance_prop_private, cn, name) != null;
            // On an anonymous receiver class an inherited member getter is only a guess
            // from supertype matching; a shadowing extension property on this entry wins.
            const ext_shadows = inherited and hit != null and blk: {
                const ig = inst.borrow();
                defer ig.deinit();
                const icg = ig.get().class.borrow();
                defer icg.deinit();
                if (!icg.get().is_anonymous) break :blk false;
                for (icg.get().supertype_names) |sup| {
                    if (lookupPairFunc(pg.get().extension_props, sup, name) != null) break :blk true;
                }
                break :blk false;
            };
            pg.deinit();
            if (hit != null and !(private_here and inherited) and !ext_shadows) {
                found = hit.?;
                break;
            }
            if (ext_shadows) return null;
        }
        if (cdef) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            for (dg.get().supertype_names) |sn| queue.append(allocator, sn) catch {};
        }
    }
    return found;
}

/// True when `cdef` stores `name` as a ctor-param or backing-field body property
/// without a custom getter or delegate, overriding any inherited `open val ... get()`.
pub fn declaresStored(cdef: *const ClassDef, name: []const u8) bool {
    // An interface stores no state: its `val`/`var` members are abstract declarations.
    if (cdef.is_interface) return false;
    for (cdef.primary_params) |p| {
        if (std.mem.eql(u8, p.name, name) and p.property != null) return true;
    }
    for (cdef.body_properties) |p| {
        // Only a concrete property with no getter or delegate overrides an inherited getter.
        if (std.mem.eql(u8, p.name, name) and p.getter == null and p.delegate == null and !p.is_abstract) return true;
    }
    return false;
}

/// Resolve a built-in delegate read (`by lazy`, `observable`, `notNull`), caching `lazy`.
pub fn unwrapDelegate(self: *VmHost, allocator: Allocator, d: ObjRef(runtime.DelegateKind), name: []const u8) Allocator.Error!EvalResult {
    const state = blk: {
        const g = d.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    switch (state) {
        .Lazy => |lz| {
            if (lz.cached) |c| return ok(c);
            const result = switch (try self.callValue(allocator, &lz.producer, &.{})) {
                .ok => |v| v,
                .err => |e| return errRes(e),
            };
            {
                const g = d.borrowMut();
                defer g.deinit();
                if (g.get().* == .Lazy) g.get().Lazy.cached = result;
            }
            return ok(result);
        },
        .Observable => |obs| return ok(obs.value),
        .NotNull => |nn| {
            if (nn.value) |x| return ok(x);
            const m = try std.fmt.allocPrint(allocator, "Property {s} should be initialized before get.", .{name});
            return errRes(.{ .Throw = try Value.newException(allocator, .{
                .fqn = try runtime.strInit(allocator, "kotlin.IllegalStateException"),
                .message = .from(try runtime.strInitOwned(allocator, m)),
                .cause = null,
            }) });
        },
    }
}

/// Walk the instance's parent and interface chain for a companion singleton owning `name`.
pub fn companionParentWalk(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) Allocator.Error!?EvalResult {
    const seed = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    defer seed.deinit();
    return companionWalkSeeded(self, allocator, seed, name);
}

/// An object or companion nested in a class resolves a bare name against the companion
/// members of the enclosing class's superclass hierarchy, walked from that enclosing class.
pub fn enclosingCompanionWalk(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) Allocator.Error!?EvalResult {
    // The resolved `enclosing_class` link, else derived from the lift name (`Outer$Inner`).
    var encl: ?ObjRef(ClassDef) = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        const eg = cg.get().enclosing_class.borrow();
        defer eg.deinit();
        break :blk if (eg.get().*) |e| e.clone() else null;
    };
    if (encl == null) {
        const cls_name = className(inst);
        if (enclosingNameOf(cls_name)) |encl_name| {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(encl_name)) |d| encl = d;
        }
    }
    const seed = encl orelse return null;
    defer seed.deinit();
    return companionWalkSeeded(self, allocator, seed, name);
}

/// Walk `seed` and its parent/interface supertypes for the first companion field `name`.
pub fn companionWalkSeeded(self: *VmHost, allocator: Allocator, seed: ObjRef(ClassDef), name: []const u8) Allocator.Error!?EvalResult {
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (queue.items) |c| c.deinit();
        queue.deinit(allocator);
    }
    try queue.append(allocator, seed.clone());
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(allocator);
    while (queue.pop()) |c| {
        defer c.deinit();
        const cg = c.borrow();
        const cname = cg.get().name;
        if (containsStr(visited.items, cname)) {
            cg.deinit();
            continue;
        }
        try visited.append(allocator, cname);
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cname);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| {
                    cg.deinit();
                    return .{ .err = e };
                },
            };
            if (singleton) |s| {
                if (s == .Instance) {
                    const fv: ?Value = blk: {
                        const ig = s.Instance.borrow();
                        defer ig.deinit();
                        break :blk ig.get().get(name);
                    };
                    if (fv) |v| {
                        cg.deinit();
                        if (v == .Null and storedNullIsLateinit(s.Instance, name)) {
                            return try lateinitReadError(allocator, name);
                        }
                        return ok(v);
                    }
                }
            }
        }
        if (cg.get().parent) |p| try queue.append(allocator, p.clone());
        for (cg.get().interfaces) |ifc| try queue.append(allocator, ifc.clone());
        cg.deinit();
    }
    return null;
}

/// Outer-instance chain fallback: an inner-class body naming an enclosing-class member.
pub fn outerInstanceChain(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) Allocator.Error!?EvalResult {
    var cur_outer: ?Value = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().outer;
    };
    var hops: u8 = 1;
    while (cur_outer) |o| : (hops +|= 1) {
        switch (o) {
            .Instance => |outer_inst| {
                // Resolve through getFieldInner first so an overriding getter on the outer's
                // runtime class is invoked virtually, not bypassed by an inherited raw slot.
                const oid = outer_inst.identity();
                if (try withFieldResolvePair(self, allocator, oid, name, &o, false, false)) |r| {
                    if (r == .ok and r.ok != .Unit) {
                        // The outer read filled the outer class's memo; on a plain stored
                        // slot, propagate an outer-hop route onto the inner class.
                        if (hops <= 63) prop: {
                            const ocls_id: u64 = blk2: {
                                const g = outer_inst.borrow();
                                defer g.deinit();
                                break :blk2 @intCast(g.get().class.identity());
                            };
                            const name_p = host_call_member.memberNameIdentity(self, name) orelse break :prop;
                            const ohit = fieldReadCacheGet(self, ocls_id, name_p) orelse break :prop;
                            const NONE = root.ProgramImage.FieldReadHit.NONE;
                            if (ohit.getter != NONE or ohit.stored_idx == NONE) break :prop;
                            if (ohit.outer_hops != 0 or ohit.stored_idx > 0xFFFFFF) break :prop;
                            const inner_fqn = blk2: {
                                const ig = inst.borrow();
                                defer ig.deinit();
                                const cg = ig.get().class.borrow();
                                defer cg.deinit();
                                break :blk2 cg.get().fqn;
                            };
                            fieldReadCachePut(self, inst, inner_fqn, name, .{
                                .getter = NONE,
                                .stored_idx = ohit.stored_idx,
                                .outer_hops = hops,
                                .outer_cls = ocls_id,
                            });
                        }
                        return r;
                    }
                }
                {
                    const g = outer_inst.borrow();
                    defer g.deinit();
                    const b = g.get();
                    for (b.fields.items, 0..) |f, fi| {
                        if (!std.mem.eql(u8, f.name, name)) continue;
                        // Memoize the outer-hop slot route on the inner class; the outer's
                        // runtime class identity is verified at serve time.
                        if (fi <= 0xFFFFFF and hops <= 63) {
                            const inner_fqn = blk2: {
                                const ig = inst.borrow();
                                defer ig.deinit();
                                const cg = ig.get().class.borrow();
                                defer cg.deinit();
                                break :blk2 cg.get().fqn;
                            };
                            const ocls: u64 = @intCast(b.class.identity());
                            fieldReadCachePut(self, inst, inner_fqn, name, .{
                                .getter = root.ProgramImage.FieldReadHit.NONE,
                                .stored_idx = @intCast(fi),
                                .outer_hops = hops,
                                .outer_cls = ocls,
                            });
                        }
                        return ok(f.value);
                    }
                }
                cur_outer = blk: {
                    const g = outer_inst.borrow();
                    defer g.deinit();
                    break :blk g.get().outer;
                };
            },
            .Class => |cls| {
                switch (try getField(self, allocator, &o, name)) {
                    .ok => |v| return ok(v),
                    .err => {},
                }
                const cls_name = blk: {
                    const g = cls.borrow();
                    defer g.deinit();
                    break :blk g.get().name;
                };
                const encl: ?[]const u8 = blk: {
                    const g = self.module.borrow();
                    defer g.deinit();
                    break :blk g.get().registry.enclosing_class.get(cls_name);
                };
                cur_outer = if (encl) |n| blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    break :blk if (cg.get().get(n)) |c| Value{ .Class = c } else null;
                } else null;
            },
            else => cur_outer = null,
        }
    }
    return null;
}

/// Whether the receiver declares or stores a member property of this name anywhere in its
/// hierarchy. A member shadows a same-named extension, which would otherwise recurse.
pub fn instanceDeclaresProperty(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    if (receiver.* != .Instance) return false;
    const inst = receiver.Instance;
    {
        const g = inst.borrow();
        defer g.deinit();
        if (g.get().get(name) != null) return true;
    }
    var cur: ?[]const u8 = className(inst);
    var depth: usize = 0;
    while (cur) |cn| : (depth += 1) {
        if (depth > 64) break;
        var found = false;
        {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(cn)) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                for (dg.get().primary_params) |p| {
                    if (p.property != null and std.mem.eql(u8, p.name, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) for (dg.get().body_properties) |p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        found = true;
                        break;
                    }
                };
            }
        }
        if (found) return true;
        cur = firstSupertype(self, cn);
    }
    return false;
}
