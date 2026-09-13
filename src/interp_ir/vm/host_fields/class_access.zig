//! Field access on a `Value.Class` receiver: companion forwarding, nested
//! class / singleton resolution, and the `KClass` reflective surface.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const host_globals = @import("../host_globals.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const common = @import("common.zig");
const className = common.className;
const classSimpleName = common.classSimpleName;
const containsStr = common.containsStr;
const errRes = common.errRes;
const evalGetterTagged = common.evalGetterTagged;
const firstSupertype = common.firstSupertype;
const frozenList = common.frozenList;
const lookupPairFunc = common.lookupPairFunc;
const matchAny = common.matchAny;
const ok = common.ok;

const ext_props = @import("ext_props.zig");
const runtimeClassDelegatesProp = ext_props.runtimeClassDelegatesProp;

const field_cache = @import("field_cache.zig");
const lateinitReadError = field_cache.lateinitReadError;
const storedNullIsLateinit = field_cache.storedNullIsLateinit;

/// Companion forwarding + nested-class/singleton resolution on a
/// `Value::Class` receiver (the early companion path of `get_field`).
/// Resolve `name` from `class_name`'s own companion object — the companion
/// singleton itself for a `Foo.Companion` access, else a companion
/// `const`/`val`/getter member. Returns null when the class has no companion or
/// the companion has no such member (so a caller can keep walking the class
/// hierarchy); `.err` on an init failure.
pub fn companionMemberOfClass(self: *VmHost, allocator: Allocator, class_name: []const u8, name: []const u8) Allocator.Error!?EvalResult {
    const cn: []const u8 = blk: {
        const g = self.module.borrow();
        defer g.deinit();
        break :blk g.get().registry.companion_singletons.get(class_name) orelse return null;
    };
    // `Counter.Factory` — the companion name resolves to the singleton itself.
    const suffix = try std.fmt.allocPrint(allocator, "$Companion${s}", .{name});
    defer allocator.free(suffix);
    if (std.mem.endsWith(u8, cn, suffix)) {
        switch (try host_globals.ensureObjectSingleton(self, cn)) {
            .ok => |maybe| if (maybe) |s| return ok(s),
            .err => |e| return errRes(e),
        }
    }
    const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
        .ok => |maybe| maybe,
        .err => |e| return errRes(e),
    };
    if (singleton) |s| {
        if (s == .Instance) {
            // A property with a CUSTOM GETTER runs its getter, even when a
            // backing field is also present (`var p = 1; get() = field++`):
            // reading the stored slot directly would skip the getter's body
            // and its side effects. Only a property with no getter reads the
            // slot below.
            const comp_cls0 = className(s.Instance);
            const custom_getter: ?FuncId = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk lookupPairFunc(pg.get().instance_prop_getters, comp_cls0, name);
            };
            if (custom_getter) |fid| {
                const mptr0: *const Module = self.module.asPtr();
                if (fid.int() < mptr0.funcCount()) {
                    return try evalGetterTagged(self, allocator, fid, s, "companion-getter");
                }
            }
            const field_v: ?Value = blk: {
                const g = s.Instance.borrow();
                defer g.deinit();
                break :blk g.get().get(name);
            };
            if (field_v) |v| {
                if (v == .Null and storedNullIsLateinit(s.Instance, name)) {
                    return try lateinitReadError(allocator, name);
                }
                // A `by`-delegated companion property stores its delegate
                // in the slot; the read is the delegate's `getValue`.
                if (runtimeClassDelegatesProp(s.Instance, name)) {
                    const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
                    return try self.callMember(allocator, &v, "getValue", &.{ s, prop_ref });
                }
                return ok(v);
            }
            // No plain backing field — the companion member may be a
            // `val` with a custom getter.
            const comp_cls = className(s.Instance);
            const getter: ?FuncId = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk lookupPairFunc(pg.get().instance_prop_getters, comp_cls, name);
            };
            if (getter) |fid| {
                const mptr: *const Module = self.module.asPtr();
                if (fid.int() < mptr.funcCount()) {
                    return try evalGetterTagged(self, allocator, fid, s, "site1752");
                }
            }
        }
    }
    return null;
}

pub fn classReceiverField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const cls_name = blk: {
        const g = receiver.Class.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    // Companion member — the class's own companion first, then inherited ones
    // up the superclass chain: `Sub.MinId` binds `Base.Companion.MinId` when
    // `MinId` is a `const`/`val` on the superclass's companion.
    {
        var cur: ?[]const u8 = cls_name;
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cn| {
            if (containsStr(seen.items, cn)) break;
            try seen.append(allocator, cn);
            if (try companionMemberOfClass(self, allocator, cn, name)) |r| return r;
            cur = firstSupertype(self, cn);
        }
    }
    // A nested class registered under its enclosing-qualified FQN
    // (`Outer.Nested`): the exact declaration resolves before the
    // lifted-simple-name probes below. Those keys are ambiguous when two
    // packages declare same-named nested members (gapbuffer's vs
    // linkbuffer's `Operation.Ups` both lift as `Operation$Ups`), and the
    // name-keyed singleton gate would construct whichever twin registered
    // the name — so a nested object resolves its singleton BY CLASS ID.
    {
        const cls_fqn = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk g.get().fqn;
        };
        if (cls_fqn.len != 0) {
            // A classifier nested in the class's COMPANION is reachable
            // through the class name too (`A.Serializer` for
            // `class A { companion object { object Serializer } }`); probe
            // it here, before the bare-name fallbacks below can answer with
            // an unrelated imported classifier of the same simple name.
            const direct_fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name });
            defer allocator.free(direct_fqn);
            const companion_fqn = try std.fmt.allocPrint(allocator, "{s}.Companion.{s}", .{ cls_fqn, name });
            defer allocator.free(companion_fqn);
            var nested_fqn: []const u8 = direct_fqn;
            const nested: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                if (cg.get().get(direct_fqn)) |def| break :blk def.clone();
                if (cg.get().get(companion_fqn)) |def| {
                    nested_fqn = companion_fqn;
                    break :blk def.clone();
                }
                break :blk null;
            };
            if (nested) |def| {
                const obj_name: ?[]const u8 = blk: {
                    const dg = def.borrow();
                    defer dg.deinit();
                    if (dg.get().is_object) break :blk dg.get().name;
                    break :blk null;
                };
                if (obj_name) |n| {
                    const nested_cid: ?ir.ClassId = blk: {
                        const mg = self.module.borrow();
                        defer mg.deinit();
                        break :blk mg.get().classIdByFqn(nested_fqn);
                    };
                    const res = if (nested_cid) |cid|
                        try host_globals.ensureObjectSingletonById(self, cid)
                    else
                        try host_globals.ensureObjectSingleton(self, n);
                    switch (res) {
                        .ok => |maybe| if (maybe) |v| {
                            if (v == .Instance) {
                                def.deinit();
                                return ok(v);
                            }
                        },
                        .err => |e| {
                            def.deinit();
                            return errRes(e);
                        },
                    }
                }
                return ok(.{ .Class = def });
            }
        }
    }
    // A nested object lifted as `Outer$Name`: resolve the mangled
    // singleton (then class) for a qualified `Outer.Name` access. First
    // access constructs the singleton through the gate.
    const mangled = try std.fmt.allocPrint(allocator, "{s}${s}", .{ cls_name, name });
    defer allocator.free(mangled);
    switch (try host_globals.ensureObjectSingleton(self, mangled)) {
        .ok => |maybe| if (maybe) |v| {
            if (v == .Instance) return ok(v);
        },
        .err => |e| return errRes(e),
    }
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(mangled)) |def| return ok(.{ .Class = def });
    }
    // Nested singleton object (lifted under its simple name) wins over
    // the class.
    switch (try host_globals.ensureObjectSingleton(self, name)) {
        .ok => |maybe| if (maybe) |v| {
            if (v == .Instance) return ok(v);
        },
        .err => |e| return errRes(e),
    }
    {
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(name)) |v| {
            if (v == .Instance) return ok(v);
        }
    }
    // Nested-class access on a class receiver.
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| return ok(.{ .Class = def });
    }
    return null;
}

/// The simple name of the lexically-enclosing class of a nested-class
/// instance, derived from its FQN (`a.b.Outer.Inner` -> the class whose
/// FQN is `a.b.Outer`, returning `Outer`). Null when the receiver's FQN
/// has no parent class (a top-level class, whose parent segment is a
/// package). The FQN nesting is unambiguous where the simple-name
/// `enclosing_class` map collides for nested classes that share a simple
/// name across different enclosing classes.
pub fn enclosingSimpleFromFqn(self: *VmHost, inst: ObjRef(InstanceData)) ?[]const u8 {
    const fqn: []const u8 = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const last_dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return null;
    const parent_fqn = fqn[0..last_dot];
    const parent_simple = if (std.mem.lastIndexOfScalar(u8, parent_fqn, '.')) |d| parent_fqn[d + 1 ..] else parent_fqn;
    // Confirm the parent FQN names an actual class (not a package): the
    // class table is keyed by simple name, so verify the matching entry's
    // FQN equals the parent FQN before treating it as the enclosing class.
    const cg = self.classes.borrow();
    defer cg.deinit();
    const def = cg.get().get(parent_simple) orelse return null;
    const dg = def.borrow();
    defer dg.deinit();
    if (std.mem.eql(u8, dg.get().fqn, parent_fqn)) return parent_simple;
    return null;
}

/// Reflection-style accessors on a `Value::Class` value (`simpleName`,
/// `isData`, `members`, `supertypes`, `sealedSubclasses`, …).
/// The companion-object singleton instance for class `cls_simple`, or
/// null when the class has no companion. Used to seed a companion
/// extension property's getter `this`.
/// The companion for a class DEF: its fqn's dotted suffixes longest-first
/// (`a.b.Outer.C` -> `b.Outer.C`, `Outer.C`, `C`) so a nested class with a
/// same-named cousin in another outer finds its own companion.
pub fn companionInstanceForDef(self: *VmHost, fqn: []const u8, simple: []const u8) Allocator.Error!?Value {
    var start: usize = 0;
    while (true) {
        const cand = fqn[start..];
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cand);
        };
        if (comp_name) |cn| {
            if (runtime.envOnce("KLIO_COMPANION_TRACE") != null) std.debug.print("[companion] key -> {s}\n", .{cn});
            return switch (try host_globals.ensureObjectSingleton(self, cn)) {
                .ok => |maybe| maybe,
                .err => null,
            };
        }
        const dot = std.mem.indexOfScalarPos(u8, fqn, start, '.') orelse break;
        start = dot + 1;
        // Never the bare simple name: that key belongs to a top-level
        // class, and a nested class's own (mangled) name resolves below.
        if (std.mem.indexOfScalarPos(u8, fqn, start, '.') == null) break;
    }
    return companionInstanceForClass(self, simple);
}

pub fn companionInstanceForClass(self: *VmHost, cls_simple: []const u8) Allocator.Error!?Value {
    const comp_name: ?[]const u8 = blk: {
        const g = self.module.borrow();
        defer g.deinit();
        break :blk g.get().registry.companion_singletons.get(cls_simple);
    };
    const cn = comp_name orelse return null;
    return switch (try host_globals.ensureObjectSingleton(self, cn)) {
        .ok => |maybe| maybe,
        .err => null,
    };
}

/// The companion object (or object singleton) a CLASS value carries its
/// static members on: `X.serializer()` dispatches there. Null when the
/// class has neither.
pub fn companionOfClassValue(self: *VmHost, cls_val: *const Value) Allocator.Error!?Value {
    if (cls_val.* != .Class) return null;
    const g = cls_val.Class.borrow();
    defer g.deinit();
    const cd = g.get();
    if (cd.is_object) {
        return switch (try host_globals.ensureObjectSingleton(self, cd.name)) {
            .ok => |maybe| maybe,
            .err => null,
        };
    }
    if (try companionInstanceForDef(self, cd.fqn, cd.name)) |v| return v;
    if (try companionInstanceForClass(self, cd.name)) |v| return v;
    var cbuf: [192]u8 = undefined;
    if (std.fmt.bufPrint(&cbuf, "$companion:{s}", .{cd.name}) catch null) |ck| {
        if (host_globals.lookupGlobal(self, ck)) |v| return v;
    }
    return null;
}

pub fn classReflective(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    const g = cls.borrow();
    defer g.deinit();
    const cd = g.get();
    // `$companion`: the class's companion instance whatever it is named
    // (`companion object Named`), initialized on read — the lookup the
    // serialization runtime's KClass -> generated serializer path needs.
    if (std.mem.eql(u8, name, "$companion")) {
        if (runtime.envOnce("KLIO_COMPANION_TRACE") != null) std.debug.print("[companion] fqn={s} name={s}\n", .{ cd.fqn, cd.name });
        // A nested class registers under its lifted name and its
        // enclosing-chain-qualified name; the bare simple name belongs to
        // a top-level class and must never answer for a nested one
        // (`Tst$B` without a companion is not `pb.B`).
        if (try companionInstanceForDef(self, cd.fqn, cd.name)) |v| return ok(v);
        if (try companionInstanceForClass(self, cd.name)) |v| return ok(v);
        // A LOCAL class's companion is not in the build-time
        // `companion_singletons`; registerNestedClasses publishes it as the
        // runtime global `$companion:<class>` instead.
        var cbuf: [192]u8 = undefined;
        if (std.fmt.bufPrint(&cbuf, "$companion:{s}", .{cd.name}) catch null) |ck| {
            if (host_globals.lookupGlobal(self, ck)) |v| return ok(v);
        }
        return ok(.Null);
    }
    // An anonymous object's class has no name: both reflective names
    // are null, matching kotlinc.
    if (std.mem.eql(u8, name, "simpleName")) {
        if (cd.is_anonymous) return ok(.Null);
        return ok(.{ .String = try runtime.strInit(allocator, classSimpleName(cd.name)) });
    }
    if (std.mem.eql(u8, name, "qualifiedName")) {
        if (cd.is_anonymous) return ok(.Null);
        return ok(.{ .String = try runtime.strInit(allocator, cd.fqn) });
    }
    if (std.mem.eql(u8, name, "isData")) return ok(.{ .Bool = cd.is_data });
    if (std.mem.eql(u8, name, "isOpen")) return ok(.{ .Bool = cd.is_open });
    if (std.mem.eql(u8, name, "isAbstract")) return ok(.{ .Bool = cd.is_abstract });
    if (std.mem.eql(u8, name, "isSealed")) return ok(.{ .Bool = cd.is_sealed });
    if (std.mem.eql(u8, name, "isFinal")) return ok(.{ .Bool = !cd.is_open and !cd.is_abstract });
    if (std.mem.eql(u8, name, "isCompanion")) {
        const mg = self.module.borrow();
        defer mg.deinit();
        var it = mg.get().registry.companion_singletons.valueIterator();
        var found = false;
        while (it.next()) |v| {
            if (std.mem.eql(u8, v.*, cd.name)) {
                found = true;
                break;
            }
        }
        return ok(.{ .Bool = found });
    }
    if (std.mem.eql(u8, name, "isInner")) return ok(.{ .Bool = cd.is_inner });
    if (std.mem.eql(u8, name, "isInterface")) return ok(.{ .Bool = cd.is_interface });
    if (std.mem.eql(u8, name, "isFun")) return ok(.{ .Bool = cd.is_fun_interface });
    if (std.mem.eql(u8, name, "objectInstance")) {
        // Reading `objectInstance` initializes the object, matching the
        // JVM (the read reaches the INSTANCE static field through class
        // initialization).
        if (cd.is_object) {
            switch (try host_globals.ensureObjectSingleton(self, cd.name)) {
                .ok => |maybe| if (maybe) |v| return ok(v),
                .err => |e| return errRes(e),
            }
        }
        return ok(.Null);
    }
    if (matchAny(name, &.{ "members", "declaredMembers", "functions", "declaredFunctions", "memberFunctions", "memberProperties", "declaredMemberProperties" })) {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(allocator);
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            for (mg.get().classes.items) |c| {
                if (!std.mem.eql(u8, c.name, cd.name)) continue;
                for (c.methods) |fid| {
                    if (mg.get().funcById(fid)) |f| {
                        try items.append(allocator, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, f.name) } });
                    }
                }
                break;
            }
        }
        for (cd.primary_params) |p| {
            if (p.property != null) {
                try items.append(allocator, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, p.name) } });
            }
        }
        for (cd.body_properties) |p| {
            try items.append(allocator, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, p.name) } });
        }
        return ok(try frozenList(allocator, items, false));
    }
    if (std.mem.eql(u8, name, "supertypes")) {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(allocator);
        for (cd.supertype_names) |n| {
            const resolved: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                break :blk cg.get().get(n);
            };
            if (resolved) |c| {
                try items.append(allocator, .{ .Class = c });
            } else {
                try items.append(allocator, .{ .String = try runtime.strInit(allocator, n) });
            }
        }
        return ok(try frozenList(allocator, items, false));
    }
    if (std.mem.eql(u8, name, "sealedSubclasses")) {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(allocator);
        const cg = self.classes.borrow();
        defer cg.deinit();
        var it = cg.get().valueIterator();
        while (it.next()) |c| {
            const sg = c.borrow();
            defer sg.deinit();
            var matches = false;
            for (sg.get().supertype_names) |sn| {
                if (std.mem.eql(u8, sn, cd.name)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
            // The class table keys a lifted nested class under more than one
            // name, so the same definition can be reached twice; report each
            // subclass once.
            var seen = false;
            for (items.items) |prev| {
                const pg = prev.Class.borrow();
                defer pg.deinit();
                if (std.mem.eql(u8, pg.get().fqn, sg.get().fqn)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try items.append(allocator, .{ .Class = c.* });
        }
        return ok(try frozenList(allocator, items, false));
    }
    return null;
}
