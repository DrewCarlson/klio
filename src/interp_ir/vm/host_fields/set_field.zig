//! The field-write ladder: the ordered resolution chain a property write
//! walks, and the setter evaluation behind it.

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
const UnitResult = ir.eval.UnitResult;

const host_fields = @import("../host_fields.zig");
const fldTls = host_fields.fldTls;
const missTraceEnvCached = host_fields.missTraceEnvCached;

const common = @import("common.zig");
const anonKey = common.anonKey;
const classFqnOf = common.classFqnOf;
const className = common.className;
const containsStr = common.containsStr;
const firstSupertype = common.firstSupertype;
const lastSegment = common.lastSegment;
const lookupPairFunc = common.lookupPairFunc;
const lookupPairFuncHop = common.lookupPairFuncHop;
const receiverLabel = common.receiverLabel;

const bound_ref = @import("bound_ref.zig");
const classDeclaresStoredProp = bound_ref.classDeclaresStoredProp;

const class_access = @import("class_access.zig");
const companionInstanceForClass = class_access.companionInstanceForClass;

const ext_props = @import("ext_props.zig");
const delegateCall = ext_props.delegateCall;
const delegatedPropRegistered = ext_props.delegatedPropRegistered;
const extPropDelegateInstance = ext_props.extPropDelegateInstance;
const resolveExtPropDelegate = ext_props.resolveExtPropDelegate;
const resolveExtensionPropSetter = ext_props.resolveExtensionPropSetter;
const runtimeClassDelegatesProp = ext_props.runtimeClassDelegatesProp;

const instance_field = @import("instance_field.zig");
const instanceDeclaresProperty = instance_field.instanceDeclaresProperty;

const field_cache = @import("field_cache.zig");
const fieldWriteCacheGet = field_cache.fieldWriteCacheGet;
const fieldWriteCachePut = field_cache.fieldWriteCachePut;
const storePlainField = field_cache.storePlainField;

pub fn setField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
    return setFieldInner(self, allocator, receiver, name, value);
}

pub fn setFieldFrom(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    value: Value,
    super_owner: ?[]const u8,
) Allocator.Error!UnitResult {
    if (super_owner == null) return setFieldInner(self, allocator, receiver, name, value);
    const prev = fldTls().super_write_owner;
    fldTls().super_write_owner = super_owner;
    defer fldTls().super_write_owner = prev;
    return setFieldInner(self, allocator, receiver, name, value);
}

pub fn setFieldInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
    // CONSUME the marker: it belongs to this write only. Writes made inside the
    // base setter we are about to reach are ordinary ones.
    const super_owner: ?[]const u8 = blk: {
        const o = self.tls.super_write_owner;
        self.tls.super_write_owner = null;
        break :blk o;
    };
    // Companion forwarding for writes: `Foo.count = 1` routes to the
    // companion singleton instance's field.
    if (receiver.* == .Class) {
        const cls_name = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk g.get().name;
        };
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cls_name);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
            if (singleton) |s| {
                if (s == .Instance) return setField(self, allocator, &s, name, value);
            }
        }
    }
    const bypass_setter = std.mem.startsWith(u8, name, "__klio_field__");
    const real_name = if (bypass_setter) name["__klio_field__".len..] else name;
    // Field-write memo: one probe replaces the whole ext-setter / delegated /
    // custom-setter / override-cell ladder below for a (class, name) pair the
    // ladder has already classified from class-static facts alone.
    const write_cache_ok = receiver.* == .Instance and !bypass_setter and
        super_owner == null and ir.eval.dispatchCacheStable();
    if (write_cache_ok) {
        const wclass_p = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class.identity();
        };
        const hit: ?root.ProgramImage.FieldWriteHit = blk: {
            const name_p = host_call_member.memberNameIdentity(self, real_name) orelse break :blk null;
            break :blk fieldWriteCacheGet(self, wclass_p, name_p);
        };
        if (hit) |h| {
            if (h.setter != root.ProgramImage.FieldWriteHit.NONE) {
                switch (try evalSetter(self, allocator, FuncId.from(h.setter), receiver.*, value)) {
                    .ok => return .{ .ok = {} },
                    .err => |e| return .{ .err = e },
                }
            }
            return storePlainField(self, allocator, receiver.Instance, h.store_name, value);
        }
    }
    var write_cacheable = write_cache_ok;
    var plain_recordable = false;
    // Extension-property setter — `var T.x set(value) {…}`. A member property
    // of the same name shadows the extension, so skip it when the receiver
    // declares its own `real_name` (else `this.x = …` recurses through the
    // extension setter).
    if (!bypass_setter and !instanceDeclaresProperty(self, receiver, real_name)) {
        // A `var X.Companion.x` setter registers under `X`'s simple name;
        // its `this` is `X`'s companion instance, not the class value.
        const recv_simple: []const u8 = switch (receiver.*) {
            .Instance => |i| className(i),
            .Class => |c| blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk lastSegment(g.get().name);
            },
            else => lastSegment(receiver.typeFqn()),
        };
        const fid: ?FuncId = try resolveExtensionPropSetter(self, allocator, receiver, recv_simple, real_name);
        if (fid) |f| {
            const mptr: *const Module = self.module.asPtr();
            if (f.int() >= mptr.funcCount()) {
                const msg = try std.fmt.allocPrint(allocator, "ext setter FuncId {d} out of range", .{f.int()});
                return .{ .err = .{ .Type = msg } };
            }
            var setter_recv = receiver.*;
            if (receiver.* == .Class) {
                if (try companionInstanceForClass(self, recv_simple)) |comp| setter_recv = comp;
            }
            // A member-extension property's setter body has its declaring
            // class's `this` in lexical scope; seed the setter frame with
            // the owner instance from the enclosing chain.
            var pushed_owner = false;
            if (mptr.registry.member_ext_owner_class.get(f)) |owner| {
                if (try host_call_member.memberExtOwnerInstance(self, allocator, &setter_recv, owner)) |inst| {
                    ir.eval.pushEnclosing(&inst);
                    pushed_owner = true;
                }
            }
            const r = try evalSetter(self, allocator, f, setter_recv, value);
            if (pushed_owner) ir.eval.popEnclosing();
            switch (r) {
                .ok => return .{ .ok = {} },
                .err => |e| return .{ .err = e },
            }
        }
        // Delegated extension property (`var R.x by expr`): write through
        // the cached delegate's `setValue(thisRef, property, value)`.
        if (try resolveExtPropDelegate(self, allocator, receiver, recv_simple, real_name)) |hit| {
            const d = try extPropDelegateInstance(self, allocator, hit.key, real_name, hit.fid);
            const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, real_name) } };
            const r = try delegateCall(self, allocator, &d, "setValue", &.{ receiver.*, prop_ref, value }, receiver);
            switch (r) {
                .ok => return .{ .ok = {} },
                .err => |e| return .{ .err = e },
            }
        }
    }
    if (receiver.* == .Instance) {
        const inst = receiver.Instance;
        const class_name = className(inst);
        if (!bypass_setter) {
            // Delegated body property -> route through `setValue`.
            const is_delegated: bool = runtimeClassDelegatesProp(inst, real_name) or blk: {
                var cur: ?[]const u8 = class_name;
                var seen: std.ArrayList([]const u8) = .empty;
                defer seen.deinit(allocator);
                while (cur) |cn| {
                    cur = null;
                    if (containsStr(seen.items, cn)) break;
                    try seen.append(allocator, cn);
                    if (delegatedPropRegistered(self, cn, real_name)) break :blk true;
                    cur = firstSupertype(self, cn);
                }
                break :blk false;
            };
            if (is_delegated) {
                write_cacheable = false;
                const raw: ?Value = blk: {
                    const g = inst.borrow();
                    defer g.deinit();
                    break :blk g.get().get(real_name);
                };
                if (raw) |d| {
                    const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, real_name) } };
                    switch (try delegateCall(self, allocator, &d, "setValue", &.{ receiver.*, prop_ref, value }, receiver)) {
                        .ok => return .{ .ok = {} },
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            // Custom property setter declared on the class or a base. Walk the
            // FULL transitive supertype set, not a single `firstSupertype`
            // chain: a class may inherit the setter from a base that is not its
            // first-declared supertype (`MeasurePassDelegate : Placeable(),
            // Measurable` — the `firstSupertype` chain follows the `Measurable`
            // interface and never reaches `Placeable`, so the custom
            // `measuredSize` setter was skipped and the write hit the backing
            // field directly, its side effects lost).
            const setter_fid: ?FuncId = blk: {
                // `super.prop = v`: the writing class's own setter is exactly the
                // one being overridden, so start the search at its SUPERTYPES. A
                // base whose property is field-backed has no setter at all, and
                // the store below writes the field — which is what `super.prop = v`
                // means.
                if (super_owner) |owner| {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    if (mg.get().registry.class_super_names.get(owner)) |chain| {
                        for (chain) |cn| {
                            const pg = self.prog.borrow();
                            const hit = lookupPairFuncHop(self, pg.get().instance_prop_setters, cn, real_name);
                            pg.deinit();
                            if (hit) |f| break :blk f;
                        }
                    }
                    break :blk null;
                }
                // FQN key first: distinct packs' same-simple-named classes
                // keep distinct FQN keys even when the shared SIMPLE-name
                // slot clobbers (kotlinx-coroutines-test's private `class
                // AtomicBoolean` vs atomicfu's).
                const rf = classFqnOf(inst);
                if (!std.mem.eql(u8, rf, class_name)) {
                    const pg = self.prog.borrow();
                    const hit = lookupPairFunc(pg.get().instance_prop_setters, rf, real_name);
                    pg.deinit();
                    if (hit) |f| break :blk f;
                }
                {
                    const pg = self.prog.borrow();
                    const hit = lookupPairFunc(pg.get().instance_prop_setters, class_name, real_name);
                    pg.deinit();
                    // The simple slot is shared program-wide: accept its fid
                    // for the receiver's OWN class only when the setter's
                    // declaring package matches the receiver class's package
                    // (a foreign namesake's accessor must not intercept a
                    // field-backed write on an unrelated class; the
                    // same-package hit keeps `var counter set(value)` custom
                    // setters over their backing field).
                    if (hit) |f| {
                        const mptr2: *const Module = self.module.asPtr();
                        const fp: []const u8 = if (mptr2.funcById(f)) |ff| ff.package else "";
                        const rpkg: []const u8 = if (std.mem.findScalarLast(u8, rf, '.')) |d| rf[0..d] else "";
                        if (rpkg.len == 0 or fp.len == 0 or std.mem.eql(u8, fp, rpkg)) break :blk f;
                    }
                }
                // The receiver's OWN class declaring the property as stored
                // (a field-backed `override var x = 0`) shadows any inherited
                // accessor: store the field directly, never reach a supertype's
                // custom setter.
                if (classDeclaresStoredProp(self, class_name, real_name)) break :blk null;
                const rf2 = classFqnOf(inst);
                if (!std.mem.eql(u8, rf2, class_name) and classDeclaresStoredProp(self, rf2, real_name)) break :blk null;
                const mg = self.module.borrow();
                defer mg.deinit();
                if (mg.get().registry.class_super_names.get(class_name)) |chain| {
                    for (chain) |cn| {
                        const pg = self.prog.borrow();
                        const hit = lookupPairFuncHop(self, pg.get().instance_prop_setters, cn, real_name);
                        pg.deinit();
                        if (hit) |f| break :blk f;
                        // A stored override shadows any further-up accessor: an
                        // `override var x = 0` on a middle class overrides a base
                        // `open var x set(...)`, so a write stores the field
                        // rather than reaching the base's custom setter.
                        if (classDeclaresStoredProp(self, cn, real_name)) break :blk null;
                    }
                }
                break :blk null;
            };
            if (setter_fid) |fid| {
                const mptr: *const Module = self.module.asPtr();
                if (fid.int() >= mptr.funcCount()) {
                    const msg = try std.fmt.allocPrint(allocator, "setter FuncId {d} out of range", .{fid.int()});
                    return .{ .err = .{ .Type = msg } };
                }
                if (write_cacheable) {
                    fieldWriteCachePut(self, inst, classFqnOf(inst), real_name, .{
                        .setter = fid.int(),
                        .store_name = "",
                    });
                }
                switch (try evalSetter(self, allocator, fid, receiver.*, value)) {
                    .ok => return .{ .ok = {} },
                    .err => |e| return .{ .err = e },
                }
            }
            // Anon-object / local-class custom setter: dispatch a `$set$<name>`
            // anon method when one is registered for the receiver's class —
            // the write-side mirror of the `$get$<name>` read path.
            {
                const setter_key = try std.fmt.allocPrint(allocator, "$set${s}", .{real_name});
                defer allocator.free(setter_key);
                const has_setter = blk: {
                    const g = self.anon_methods.borrow();
                    defer g.deinit();
                    break :blk g.get().contains(anonKey(class_name, setter_key));
                };
                if (has_setter) {
                    switch (try self.callMember(allocator, receiver, setter_key, &.{value})) {
                        .ok => return .{ .ok = {} },
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            // Companion / parent / outer fallback for a write whose name
            // is not an own member of this instance.
            const has_own = blk: {
                const g = inst.borrow();
                defer g.deinit();
                break :blk g.get().get(real_name) != null;
            };
            const is_own_member = blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                for (cg.get().primary_params) |p| {
                    if (std.mem.eql(u8, p.name, real_name)) break :blk true;
                }
                for (cg.get().body_properties) |p| {
                    if (std.mem.eql(u8, p.name, real_name)) break :blk true;
                }
                break :blk false;
            };
            if (is_own_member) plain_recordable = true;
            if (!has_own and !is_own_member) {
                // Interface-delegation forwarding for writes: a `var` the
                // delegated interface declares routes the write to the delegate
                // object (`class Scope(s) : MutableState by s` — `scope.value = x`
                // writes `s.value = x`). Mirrors the read-path forwarding; without
                // it the write would fabricate an own backing field, diverging the
                // delegator from its delegate.
                const deleg_target: ?Value = blk: {
                    const g = inst.borrow();
                    defer g.deinit();
                    for (g.get().fields.items) |f| {
                        if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
                        const iface = f.name["__delegate__".len..];
                        if (host_call_member.delegatedInterfaceDeclares(self, allocator, inst, iface, real_name) == true) {
                            break :blk f.value;
                        }
                    }
                    break :blk null;
                };
                if (deleg_target) |d| return setField(self, allocator, &d, real_name, value);
                if (try setCompanionParentWalk(self, allocator, inst, real_name, value)) |r| return r;
                const outer: ?Value = blk: {
                    const g = inst.borrow();
                    defer g.deinit();
                    break :blk g.get().outer;
                };
                if (outer) |o| return setField(self, allocator, &o, real_name, value);
            }
        }
        {
            // A stored `override val/var` keeps its own backing cell under the
            // owner-mangled key (JVM semantics); the read path resolves the
            // nearest such cell in the runtime chain. A plain write must target
            // that SAME cell — writing the base's plain `real_name` cell would
            // leave the override read (which addresses the mangled cell) stale.
            // `super.x = v` still targets the base's plain cell (super_owner
            // set), so keep the plain name then.
            const store_name: []const u8 = if (super_owner != null) real_name else blk: {
                const any_cell = pglobal: {
                    const pg = self.module.borrow();
                    defer pg.deinit();
                    break :pglobal pg.get().registry.override_cell_props.count() != 0;
                };
                if (!any_cell) break :blk real_name;
                var cur3: ?[]const u8 = className(inst);
                var hops3: u8 = 0;
                while (cur3) |cn3| : (hops3 += 1) {
                    if (hops3 > 16) break;
                    var kb3: [256]u8 = undefined;
                    const probe3 = std.fmt.bufPrint(&kb3, "{s}\x1f{s}", .{ cn3, real_name }) catch break;
                    const key = kblk: {
                        const pg = self.module.borrow();
                        defer pg.deinit();
                        break :kblk pg.get().registry.override_cell_props.getKey(probe3);
                    };
                    if (key) |k| break :blk k;
                    cur3 = firstSupertype(self, cn3);
                }
                break :blk real_name;
            };
            if (write_cacheable and plain_recordable) {
                fieldWriteCachePut(self, inst, classFqnOf(inst), real_name, .{
                    .setter = root.ProgramImage.FieldWriteHit.NONE,
                    .store_name = store_name,
                });
            }
            return storePlainField(self, allocator, inst, store_name, value);
        }
    }
    const tf = try allocator.dupe(u8, receiverLabel(receiver));
    if (missTraceEnvCached() != null) {
        std.debug.print("[setfield-miss] `{s}` on `{s}` span={any}\n", .{ name, tf, ir.eval.currentCallSiteSpan() });
        ir.eval.debugPrintFrames();
    }
    const msg = try std.fmt.allocPrint(allocator, "Vm::set_field `{s}` on `{s}`", .{ name, tf });
    allocator.free(tf);
    return .{ .err = .{ .Unimplemented = msg } };
}

/// Walk an instance's class chain (parents + interfaces) and write the
/// field through the first companion singleton that already declares it.
pub fn setCompanionParentWalk(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8, value: Value) Allocator.Error!?UnitResult {
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (queue.items) |c| c.deinit();
        queue.deinit(allocator);
    }
    {
        const g = inst.borrow();
        defer g.deinit();
        try queue.append(allocator, g.get().class.clone());
    }
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
                    const has = blk: {
                        const ig = s.Instance.borrow();
                        defer ig.deinit();
                        break :blk ig.get().get(name) != null;
                    };
                    if (has) {
                        cg.deinit();
                        return try setField(self, allocator, &s, name, value);
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

/// Run an IR-lowered setter `fid` with `(receiver, value)` bound.
pub fn evalSetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value, value: Value) Allocator.Error!UnitResult {
    const mptr: *const Module = self.module.asPtr();
    const func = mptr.funcById(fid) orelse return .{ .err = .{ .Type = "setter FuncId out of range" } };
    var args: std.ArrayList(Value) = .empty;
    try args.append(allocator, receiver);
    try args.append(allocator, value);
    vmhost.emitPath(allocator, "setter", func.fqn, fid, &receiver, &.{value});
    return switch (try ir.eval.evalWith(VmHost, allocator, mptr, func, args, self)) {
        .ok => .{ .ok = {} },
        .err => |e| .{ .err = e },
    };
}
