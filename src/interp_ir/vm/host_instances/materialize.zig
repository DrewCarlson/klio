//! Materializing an instance: the builtin collection base a class extends,
//! the field table its primary parameters and body properties produce, and
//! the delegate a `by` property provides.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../../interp_ir.zig");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const host_classes = @import("../host_classes.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_member = @import("../host_call_member.zig");
const host_fields = @import("../host_fields.zig");
const host_call_value = @import("../host_call_value.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../../build.zig");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const Env = runtime.Env;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const TypeShape = runtime.TypeShape;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const StrPair = ir.StrPair;
const StringSet = std.StringHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

const build_object = @import("build_object.zig");
const anonKey = build_object.anonKey;

const common = @import("common.zig");
const typeErr = common.typeErr;

const ctor_defaults = @import("ctor_defaults.zig");
const packPrimaryCtorVarargs = ctor_defaults.packPrimaryCtorVarargs;
const simpleLiteral = ctor_defaults.simpleLiteral;

const ctor_path = @import("ctor_path.zig");
const classDefFqn = ctor_path.classDefFqn;
const classDefIsInner = ctor_path.classDefIsInner;
const classDefIsInterface = ctor_path.classDefIsInterface;
const classDefIsObject = ctor_path.classDefIsObject;
const classDefName = ctor_path.classDefName;
const isBuiltinThrowableNameNoCancel = ctor_path.isBuiltinThrowableNameNoCancel;
const padParentCtorDefaults = ctor_path.padParentCtorDefaults;
const reorderNamedSuperArgs = ctor_path.reorderNamedSuperArgs;
const selectInnerOuter = ctor_path.selectInnerOuter;

const ctor_select = @import("ctor_select.zig");
const DeferredCtorBody = ctor_select.DeferredCtorBody;
const adoptDeclaredNumeric = ctor_select.adoptDeclaredNumeric;
const bodyPropInit = ctor_select.bodyPropInit;
const classDefByName = ctor_select.classDefByName;
const classDelegateThunks = ctor_select.classDelegateThunks;
const evalParentCtorThunk = ctor_select.evalParentCtorThunk;
const evalThunk = ctor_select.evalThunk;
const expandParentSecondaryThisArgs = ctor_select.expandParentSecondaryThisArgs;
const funcAt = ctor_select.funcAt;
const isPrivateShadowProp = ctor_select.isPrivateShadowProp;
const nextInstanceId = ctor_select.nextInstanceId;
const parentCtorArgNames = ctor_select.parentCtorArgNames;
const parentCtorArgThunks = ctor_select.parentCtorArgThunks;
const shadowFieldKey = ctor_select.shadowFieldKey;
const sideTableKey = ctor_select.sideTableKey;
const trivialInitServe = ctor_select.trivialInitServe;

const super_chain = @import("super_chain.zig");
const ChainEntry = super_chain.ChainEntry;
const SuperRef = super_chain.SuperRef;
const chainEntryIs = super_chain.chainEntryIs;
const firstNonInterfaceSuper = super_chain.firstNonInterfaceSuper;
const runInitBlocksAt = super_chain.runInitBlocksAt;

pub const BuiltinBase = struct { key: []const u8, value: Value };

pub const BuiltinBaseName = struct { name: []const u8, key: []const u8 };

/// A stdlib collection class a user class extends (`class N :
/// ArrayList<Any>()`), named by its resolved fqn. The stdlib declares it as
/// an `expect` header with no bodies and klio implements it as a host
/// value, so the supertype's constructor call builds the host collection
/// and the instance keeps it as the delegate for that supertype: members
/// the class does not declare forward to it and `super.add(x)` dispatches
/// on it.
pub fn builtinCollectionBase(fqn: []const u8) ?BuiltinBaseName {
    const pkg = "kotlin.collections.";
    if (!std.mem.startsWith(u8, fqn, pkg)) return null;
    var simple = fqn[pkg.len..];
    if (std.mem.findScalar(u8, simple, '<')) |lt| simple = simple[0..lt];
    const bases = [_]BuiltinBaseName{
        .{ .name = "ArrayList", .key = "__delegate__ArrayList" },
        .{ .name = "HashMap", .key = "__delegate__HashMap" },
        .{ .name = "LinkedHashMap", .key = "__delegate__LinkedHashMap" },
        .{ .name = "HashSet", .key = "__delegate__HashSet" },
        .{ .name = "LinkedHashSet", .key = "__delegate__LinkedHashSet" },
        .{ .name = "ArrayDeque", .key = "__delegate__ArrayDeque" },
    };
    for (bases) |b| {
        if (std.mem.eql(u8, simple, b.name)) return b;
    }
    return null;
}

/// Construct the host collection for a builtin collection supertype from
/// the supertype call's evaluated arguments, through the stdlib factory of
/// the same name (`ArrayList(initialCapacity)`, `HashMap(original)`).
pub fn buildBuiltinBase(self: *VmHost, allocator: Allocator, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    const factory = host_globals.lookupGlobal(self, name) orelse
        return .{ .err = try typeErr(allocator, "`{s}` has no constructor", .{name}) };
    return host_call_value.callValue(self, allocator, &factory, args);
}

pub fn materializeInstance(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    const class_fqn = classDefFqn(class_def);
    const identity = nextInstanceId(self);
    const ctor_keepalive = self.ka.mark();
    defer self.ka.restore(ctor_keepalive);

    // Build the parent ctor-arg chain top-down. Each entry carries the
    // resolved FQN alongside the written name, so every per-class side
    // table (ctor args, init blocks, body-prop inits) is read for the
    // exact class, never a same-simple-name twin.
    var chain: std.ArrayList(ChainEntry) = .empty;
    defer {
        for (chain.items) |c| allocator.free(c.args);
        chain.deinit(allocator);
    }
    {
        const owned = try allocator.dupe(Value, args);
        try chain.append(allocator, .{ .name = ir_name, .fqn = class_fqn, .args = owned });
        self.ka.pushSlice(owned);
    }
    var cur_class = ir_name;
    var cur_fqn: ?[]const u8 = class_fqn;
    var cur_args: []const Value = args;

    var throwable_message: ?Value = null;
    var throwable_cause: ?Value = null;
    var is_throwable = false;

    // Direct-parent Throwable message/cause recovery.
    {
        const parent_ref = firstNonInterfaceSuper(self, class_def);
        if (parent_ref) |pref| {
            if (isThrowableDirectName(pref.name)) {
                is_throwable = true;
                if (parentCtorArgThunks(self, cur_fqn, cur_class)) |thunks| {
                    for (thunks, 0..) |fid, idx| {
                        const fr = try funcAt(self, fid, "parent ctor arg");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                switch (try evalParentCtorThunk(self, func, cur_args, outer_hint)) {
                                    .ok => |v| {
                                        if (idx == 0) throwable_message = v else if (idx == 1) throwable_cause = v;
                                        self.ka.push(v);
                                    },
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
            }
        }
    }

    // Walk the parent ctor chain.
    var deferred_bodies: std.ArrayList(DeferredCtorBody) = .empty;
    defer {
        for (deferred_bodies.items) |d| allocator.free(d.args);
        deferred_bodies.deinit(allocator);
    }
    var pending_super_args: ?std.ArrayList(Value) = null;
    var builtin_base: ?BuiltinBase = null;
    while (true) {
        const thunks_opt = parentCtorArgThunks(self, cur_fqn, cur_class);
        if (thunks_opt == null and pending_super_args == null) break;
        const thunks: []const FuncId = thunks_opt orelse &.{};
        if (runtime.envOnce("KLIO_ENUM_INIT_TRACE") != null) {
            std.debug.print("[chain] class={s} fqn={s} key={s} thunks=", .{ cur_class, cur_fqn orelse "-", sideTableKey(cur_fqn, cur_class) });
            for (thunks) |t| std.debug.print("{d} ", .{t.int()});
            std.debug.print("\n", .{});
        }
        const cur_def = classDefByName(self, sideTableKey(cur_fqn, cur_class));
        var parent_ref: ?SuperRef = null;
        if (cur_def) |d| {
            parent_ref = firstNonInterfaceSuper(self, d);
            d.deinit();
        }
        const pref = parent_ref orelse break;
        const pname = pref.name;

        // Evaluate this level's super-args.
        var parent_args: std.ArrayList(Value) = .empty;
        // A parent secondary constructor's `super(…)` delegation named this
        // class's arguments already; the header thunks do not apply.
        const override = pending_super_args;
        pending_super_args = null;
        if (override) |o| parent_args = o;
        for (if (override != null) &[_]FuncId{} else thunks) |fid| {
            const fr = try funcAt(self, fid, "parent ctor arg");
            switch (fr) {
                .err => |e| {
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
                .ok => |func| {
                    const parent_keepalive = self.ka.mark();
                    self.ka.pushSlice(parent_args.items);
                    const evaluated = evalParentCtorThunk(self, func, cur_args, outer_hint);
                    self.ka.restore(parent_keepalive);
                    switch (try evaluated) {
                        .ok => |v| parent_args.append(allocator, v) catch {},
                        .err => |e| {
                            parent_args.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                },
            }
        }

        if (isThrowableChainName(pname)) {
            is_throwable = true;
            if (throwable_message == null and parent_args.items.len > 0) throwable_message = parent_args.items[0];
            if (throwable_cause == null and parent_args.items.len > 1) throwable_cause = parent_args.items[1];
            parent_args.deinit(allocator);
            break;
        }
        if (std.mem.eql(u8, pname, cur_class)) {
            parent_args.deinit(allocator);
            break;
        }
        if (builtinCollectionBase(pref.fqn orelse pname)) |base| {
            switch (try buildBuiltinBase(self, allocator, base.name, parent_args.items)) {
                .ok => |v| {
                    self.ka.push(v);
                    builtin_base = .{ .key = base.key, .value = v };
                },
                .err => |e| {
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
            parent_args.deinit(allocator);
            break;
        }
        const parent_def = classDefByName(self, sideTableKey(pref.fqn, pname));
        const parent_is_iface = if (parent_def) |d| classDefIsInterface(d) else true;
        if (parent_def == null or parent_is_iface) {
            if (parent_def) |d| d.deinit();
            parent_args.deinit(allocator);
            break;
        }
        switch (try expandParentSecondaryThisArgs(self, allocator, pref.fqn, pname, &parent_args, parentCtorArgNames(self, cur_fqn, cur_class), &deferred_bodies, &pending_super_args)) {
            .ok => {},
            .err => |e| {
                if (parent_def) |d| d.deinit();
                parent_args.deinit(allocator);
                return .{ .err = e };
            },
        }
        // Reorder any named super-constructor arguments into the parent's
        // parameter order before the positional field-binding below reads
        // them (`: Base(objects = 2)` must set `objects`, not the first slot).
        if (parent_def) |d| {
            switch (try reorderNamedSuperArgs(self, allocator, d, pref.fqn, pname, parentCtorArgNames(self, cur_fqn, cur_class), &parent_args, outer_hint)) {
                .ok => {},
                .err => |e| {
                    d.deinit();
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
            // The handle stays live for the defaults-padding block below,
            // which releases it on every path — a second deinit here
            // double-freed the class def under the reclaim profile.
        }
        // Fill any trailing primary-ctor params the subclass omitted from
        // its `super(...)` delegation with the parent's defaults.
        if (parent_def) |d| {
            switch (try padParentCtorDefaults(self, allocator, d, pref.fqn, pname, &parent_args, outer_hint)) {
                .ok => {},
                .err => |e| {
                    d.deinit();
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
            d.deinit();
        }
        // Pack the delegation args for the parent's vararg primary param.
        const packed_parent = try packPrimaryCtorVarargs(self, pref.fqn, pname, try parent_args.toOwnedSlice(allocator));
        // `chain` owns this duped copy (freed on chain teardown) and it
        // outlives the loop, so the next iteration reads its super-args from
        // it. The packed buffer is a dead full allocation once duped.
        const chain_args = try allocator.dupe(Value, packed_parent);
        try chain.append(allocator, .{ .name = pname, .fqn = pref.fqn, .args = chain_args });
        self.ka.pushSlice(chain_args);
        if (runtime.freeScratch()) allocator.free(packed_parent);
        cur_class = pname;
        cur_fqn = pref.fqn;
        cur_args = chain_args;
    }

    // Apply primary-param properties bottom-up so child overrides win.
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    errdefer fields.deinit(allocator);
    {
        var ci: usize = chain.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls_name = chain.items[ci].name;
            const cls_args = chain.items[ci].args;
            var cls_def = classDefByName(self, sideTableKey(chain.items[ci].fqn, cls_name));
            var use_def = false;
            if (cls_def) |d| {
                if (classDefIsInterface(d)) {
                    d.deinit();
                    cls_def = null;
                } else {
                    use_def = true;
                }
            }
            if (!use_def and std.mem.eql(u8, cls_name, class_name)) {
                cls_def = class_def.clone();
                use_def = true;
            }
            if (cls_def) |d| {
                defer d.deinit();
                const dg = d.borrow();
                const pp = dg.get().primary_params;
                var k: usize = 0;
                while (k < pp.len and k < cls_args.len) : (k += 1) {
                    if (pp[k].property != null) {
                        const fv = adoptDeclaredNumeric(&pp[k], cls_args[k]);
                        // Dedup on the STORAGE key: a subclass's private
                        // SHADOW of a base ctor property lives in its own
                        // owner-mangled cell and must not displace the base's
                        // plain cell (base-class code reads it by plain name).
                        // An OVERRIDE cell keeps the old behavior — the
                        // child's cell supersedes the plain one.
                        const store_key = shadowFieldKey(self, cls_name, pp[k].name);
                        retainFieldList(&fields, allocator, store_key);
                        if (store_key.len != pp[k].name.len and !isPrivateShadowProp(self, cls_name, pp[k].name)) {
                            retainFieldList(&fields, allocator, pp[k].name);
                        }
                        // The instance owns one ref to each primary-ctor field.
                        if (runtime.reclaimEnabled()) fv.retain();
                        try fields.append(allocator, .{ .name = store_key, .value = fv });
                    }
                }
                dg.deinit();
            }
        }
    }

    // A plain (non-property) primary-ctor parameter a member body reads is
    // captured by Kotlin as a synthesized field. Seed each under its name when
    // nothing else owns it: a property param (seeded above, own or inherited)
    // or a same-class body property (seeded from its initializer below) holds
    // the name instead, so skip those — else a duplicate/shadowing cell would
    // displace the real property. Runs after the whole property pass so an
    // inherited property (a base `val root` under a subclass's plain `root`
    // param) is already present and wins.
    {
        var ci: usize = chain.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls_name = chain.items[ci].name;
            const cls_args = chain.items[ci].args;
            var cls_def = classDefByName(self, sideTableKey(chain.items[ci].fqn, cls_name));
            var use_def = false;
            if (cls_def) |d| {
                if (classDefIsInterface(d)) {
                    d.deinit();
                    cls_def = null;
                } else {
                    use_def = true;
                }
            }
            if (!use_def and std.mem.eql(u8, cls_name, class_name)) {
                cls_def = class_def.clone();
                use_def = true;
            }
            if (cls_def) |d| {
                defer d.deinit();
                const dg = d.borrow();
                const pp = dg.get().primary_params;
                var k: usize = 0;
                while (k < pp.len and k < cls_args.len) : (k += 1) {
                    if (pp[k].property != null) continue;
                    const pnm = pp[k].name;
                    var present = false;
                    for (fields.items) |f| {
                        if (std.mem.eql(u8, f.name, pnm)) {
                            present = true;
                            break;
                        }
                    }
                    if (present) continue;
                    var owned_by_body = false;
                    for (dg.get().body_properties) |bp| {
                        if (std.mem.eql(u8, bp.name, pnm)) {
                            owned_by_body = true;
                            break;
                        }
                    }
                    if (owned_by_body) continue;
                    const fv = cls_args[k];
                    if (runtime.reclaimEnabled()) fv.retain();
                    try fields.append(allocator, .{ .name = pnm, .value = fv });
                }
                dg.deinit();
            }
        }
    }

    // Seed non-nullable primitive `var` fields with their type zero.
    {
        var cur: ?ObjRef(ClassDef) = class_def.clone();
        while (cur) |c| {
            const g = c.borrow();
            for (g.get().body_properties) |p| {
                if (p.init != null or p.getter != null or p.delegate != null) continue;
                if (p.primitive_zero) |zv| {
                    var exists = false;
                    for (fields.items) |f| {
                        if (std.mem.eql(u8, f.name, p.name)) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) try fields.append(allocator, .{ .name = p.name, .value = zv });
                }
            }
            const next: ?ObjRef(ClassDef) = if (g.get().parent) |p| p.clone() else null;
            g.deinit();
            c.deinit();
            cur = next;
        }
    }

    var entry_slot: ?*Value = null;
    if (common.enum_entry_preset) |preset| {
        if (std.mem.eql(u8, preset.class_fqn, class_fqn)) {
            try fields.append(allocator, .{ .name = "name", .value = preset.name });
            try fields.append(allocator, .{ .name = "ordinal", .value = preset.ordinal });
            entry_slot = preset.slot;
            common.enum_entry_preset = null;
        }
    }
    if (builtin_base) |bb| {
        if (runtime.reclaimEnabled()) bb.value.retain();
        try fields.append(allocator, .{ .name = bb.key, .value = bb.value });
    }
    // Materialise the instance.
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = class_def.clone(),
        .fields = fields,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    const inst_value = Value{ .Instance = inst };
    // An enum entry's own initializers (its inner classes included) may
    // name the entry while it is under construction; kotlinc binds that
    // reference to the instance itself, so the entry table holds the shell
    // before any of them runs.
    if (entry_slot) |slot| {
        if (runtime.reclaimEnabled()) inst_value.retain();
        slot.* = inst_value;
    }
    // The instance under construction is reachable only through this host local
    // until it is returned and bound; its body-property/init-block initializers
    // run user code (safe points), so pin it across construction or a collection
    // there sweeps the half-built shell and frees its field list out from under
    // us. (Object/companion singletons are additionally pinned via the in-flight
    // object-state table, but regular instances have no such anchor.)
    const ka_inst = self.ka.mark();
    defer self.ka.restore(ka_inst);
    self.ka.push(inst_value);

    // Attach a stored default-outer.
    {
        const has_outer = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().outer != null;
        };
        if (!has_outer) {
            const og = self.class_default_outer.borrow();
            const default_outer = og.get().get(class_name);
            og.deinit();
            if (default_outer) |o| {
                // `outer` is an owned field (teardown releases it); the value
                // read from the default-outer table is a borrow, so retain.
                o.retain();
                const g = inst.borrowMut();
                g.get().outer = o;
                g.deinit();
            }
        }
    }
    // Inner-class outer selection.
    if (classDefIsInner(class_def)) {
        const has_outer = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().outer != null;
        };
        if (!has_outer) {
            if (try selectInnerOuter(self, allocator, class_def, ir_name, outer_hint)) |outer_v| {
                // `selectInnerOuter` hands back a borrow of the outer-hint /
                // capture; `outer` is an owned field, so retain before storing.
                outer_v.retain();
                const g = inst.borrowMut();
                g.get().outer = outer_v;
                g.deinit();
            }
        }
    }

    // Make an object / companion singleton shell visible before its init
    // runs. A gate-driven construction records the in-flight instance in
    // the shared object-init table, so re-entrant reads from the
    // constructing thread (the object referencing itself during its own
    // init) observe it while other threads keep waiting — the singleton
    // only publishes into `globals` after construction completes. A
    // construction NOT driven through the gate (a runtime-registered
    // local object) publishes directly, as before.
    if (classDefIsObject(class_def)) {
        if (!host_globals.noteObjectInFlight(self, class_name, inst_value)) {
            const g = self.globals.borrowMut();
            g.get().define(class_name, inst_value) catch {};
            g.deinit();
        }
    }

    // Evaluate class-delegation expressions. A `by <expr>` interface
    // delegation declared on any class in the chain forwards the
    // delegated interface's members, so each level's delegate thunks run
    // against that level's resolved super-args — not only the leaf's, so a
    // subclass of a delegating base inherits its delegate fields. Leaf
    // first: a more-derived class's delegation for an interface overrides
    // a base's, so the first delegate field for a given interface wins and
    // a later (base-level) one is skipped. The leaf is keyed on its
    // runtime `class_name` (the side table's key), not the IR name the
    // chain records, which can differ when the def was resolved through a
    // sibling/fqn lookup.
    {
        for (chain.items, 0..) |c, idx| {
            const lookup_name = if (idx == 0) class_name else c.name;
            const delegates = classDelegateThunks(self, c.fqn, lookup_name);
            for (delegates) |sf| {
                const fr = try funcAt(self, sf.func, "class delegate");
                // The delegation expression evaluates in the class body's
                // scope: an inner class's `Density by this@Outer` reaches
                // the enclosing instance through the under-construction
                // instance's outer link. Make the instance an enclosing
                // receiver for the thunk so the labeled-this walk finds it.
                var inst_v = Value{ .Instance = inst };
                ir.eval.pushEnclosing(&inst_v);
                defer ir.eval.popEnclosing();
                switch (fr) {
                    .err => {},
                    .ok => |func| {
                        switch (try evalThunk(self, func, c.args)) {
                            .ok => |v| {
                                const key = try std.fmt.allocPrint(allocator, "__delegate__{s}", .{sf.name});
                                const g = inst.borrowMut();
                                const already = g.get().get(key) != null;
                                if (!already) {
                                    try g.get().ensureFieldsOwned(allocator, 1);
                                    try g.get().fields.append(allocator, .{ .name = key, .value = v });
                                    g.get().invalidateShape();
                                }
                                g.deinit();
                            },
                            .err => |e| return .{ .err = e },
                        }
                    },
                }
            }
        }
    }
    // `Throwable(cause)`: the single argument is the cause and the message
    // is its rendering, as the JVM constructor defines it.
    if (throwable_cause == null) {
        if (throwable_message) |m| {
            const is_cause = m == .Exception or (m == .Instance and host_call_member.instanceIsThrowable(self, allocator, m.Instance));
            if (is_cause) {
                throwable_cause = m;
                throwable_message = switch (try host_call_member.callMember(self, allocator, &m, "toString", &.{})) {
                    .ok => |s| s,
                    .err => |e| return .{ .err = e },
                };
            }
        }
    }
    if (throwable_message) |m| {
        const g = inst.borrowMut();
        try g.get().fields.append(allocator, .{ .name = "message", .value = m });
        g.get().invalidateShape();
        g.deinit();
    }
    if (throwable_cause) |c| {
        const g = inst.borrowMut();
        try g.get().fields.append(allocator, .{ .name = "cause", .value = c });
        g.get().invalidateShape();
        g.deinit();
    }
    // fillInStackTrace at construction (JVM order) for a user Throwable
    // subclass: its parent chain bottomed out at a builtin Throwable.
    if (is_throwable) {
        var tv = Value{ .Instance = inst };
        try ir.eval.attachStackTrace(allocator, &tv);
    }

    // Body properties: walk the parent chain bottom-up.
    var chain_classes: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (chain_classes.items) |c| c.deinit();
        chain_classes.deinit(allocator);
    }
    {
        var cur: ?ObjRef(ClassDef) = class_def.clone();
        while (cur) |c| {
            try chain_classes.append(allocator, c.clone());
            const g = c.borrow();
            const next: ?ObjRef(ClassDef) = if (g.get().parent) |p| p.clone() else null;
            g.deinit();
            c.deinit();
            cur = next;
        }
    }
    {
        var ci: usize = chain_classes.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls = chain_classes.items[ci];
            const cls_name = classDefName(cls);
            const cls_fqn = classDefFqn(cls);
            const body_len = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().body_properties.len;
            };
            const cls_args: []const Value = blk: {
                for (chain.items) |*c| {
                    if (chainEntryIs(c, cls_fqn, cls_name)) break :blk c.args;
                }
                break :blk args;
            };
            var prop_idx: usize = 0;
            while (prop_idx < body_len) : (prop_idx += 1) {
                switch (try runInitBlocksAt(self, cls, prop_idx, &inst_value, chain.items, args)) {
                    .ok => {},
                    .err => |e| return .{ .err = e },
                }
                const prop_name = blk: {
                    const g = cls.borrow();
                    defer g.deinit();
                    break :blk g.get().body_properties[prop_idx].name;
                };
                if (bodyPropInit(self, cls_fqn, cls_name, prop_name)) |fid| {
                    const fr = try funcAt(self, fid, "body prop init");
                    switch (fr) {
                        .err => |e| return .{ .err = e },
                        .ok => |func| {
                            // The initializer runs in the class body's
                            // scope, so a lambda created inside it must see
                            // the instance as an enclosing receiver — a
                            // closure snapshots the chain at creation, and
                            // without this a bare name inside
                            // `Job(..).apply { invokeOnCompletion { stateLock } }`
                            // saw only the `apply` receiver and fell through to
                            // the global. Same treatment the class DELEGATE
                            // thunk already gets below; the instance is passed
                            // as the thunk's `this` PARAMETER, which is not the
                            // same as being on the enclosing chain.
                            var encl_v = inst_value;
                            ir.eval.pushEnclosing(&encl_v);
                            defer ir.eval.popEnclosing();
                            var all: std.ArrayList(Value) = .empty;
                            defer all.deinit(allocator);
                            try all.append(allocator, inst_value);
                            try all.appendSlice(allocator, cls_args);
                            var v = blk_v: {
                                const mg3 = self.module.borrow();
                                defer mg3.deinit();
                                if (try trivialInitServe(allocator, mg3.get(), func, all.items)) |sv| break :blk_v sv;
                                break :blk_v switch (try evalThunk(self, func, all.items)) {
                                    .ok => |rv| rv,
                                    .err => |e| return .{ .err = e },
                                };
                            };
                            v = switch (try maybeProvideDelegate(self, allocator, cls_name, prop_name, &inst_value, v)) {
                                .ok => |pv| pv,
                                .err => |e| return .{ .err = e },
                            };
                            const g = inst.borrowMut();
                            try g.get().define(allocator, shadowFieldKey(self, cls_name, prop_name), v);
                            g.deinit();
                        },
                    }
                } else {
                    const init_expr = blk: {
                        const g = cls.borrow();
                        defer g.deinit();
                        break :blk g.get().body_properties[prop_idx].init;
                    };
                    if (init_expr) |ie| {
                        const v = (try simpleLiteral(allocator, ie.get())) orelse blk: {
                            // A local class's complex initializer was lowered
                            // as a runtime `$init$` thunk at registration.
                            const init_name = try std.fmt.allocPrint(allocator, "$init${s}", .{prop_name});
                            defer allocator.free(init_name);
                            const has = hblk: {
                                const key = try anonKey(allocator, cls_name, init_name);
                                defer allocator.free(key);
                                const ag = self.anon_methods.borrow();
                                defer ag.deinit();
                                break :hblk ag.get().contains(key);
                            };
                            if (has) {
                                switch (try host_call_member.callMember(self, allocator, &inst_value, init_name, cls_args)) {
                                    .ok => |rv| break :blk rv,
                                    .err => |e| return .{ .err = e },
                                }
                            }
                            break :blk Value.Null;
                        };
                        const g = inst.borrowMut();
                        try g.get().define(allocator, shadowFieldKey(self, cls_name, prop_name), v);
                        g.deinit();
                    } else {
                        // A local class's delegated property: the delegate
                        // expression was lowered as a `$init$` thunk at
                        // registration; evaluate it and store the delegate
                        // under the property name (the shape the getValue/
                        // setValue read/write routes expect).
                        const has_delegate = blk: {
                            const g = cls.borrow();
                            defer g.deinit();
                            break :blk g.get().body_properties[prop_idx].delegate != null;
                        };
                        if (has_delegate) {
                            const init_name = try std.fmt.allocPrint(allocator, "$init${s}", .{prop_name});
                            defer allocator.free(init_name);
                            const has_thunk = hblk: {
                                const key = try anonKey(allocator, cls_name, init_name);
                                defer allocator.free(key);
                                const ag = self.anon_methods.borrow();
                                defer ag.deinit();
                                break :hblk ag.get().contains(key);
                            };
                            if (has_thunk) {
                                switch (try host_call_member.callMember(self, allocator, &inst_value, init_name, cls_args)) {
                                    .ok => |rv| {
                                        const g = inst.borrowMut();
                                        try g.get().define(allocator, shadowFieldKey(self, cls_name, prop_name), rv);
                                        g.deinit();
                                    },
                                    .err => |e| return .{ .err = e },
                                }
                            }
                        }
                        const skip = blk: {
                            const g = cls.borrow();
                            defer g.deinit();
                            const bp = g.get().body_properties[prop_idx];
                            break :blk bp.getter != null or bp.delegate != null or bp.is_abstract;
                        };
                        if (!skip) {
                            const exists = blk: {
                                const g = inst.borrow();
                                defer g.deinit();
                                break :blk g.get().get(prop_name) != null;
                            };
                            if (!exists) {
                                const g = inst.borrowMut();
                                try g.get().fields.append(allocator, .{ .name = prop_name, .value = .Null });
                                g.get().invalidateShape();
                                g.deinit();
                            }
                        }
                    }
                }
            }
            switch (try runInitBlocksAt(self, cls, body_len, &inst_value, chain.items, args)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            // A parent secondary-constructor body chosen for the header chain
            // runs here, after its class's initializers and before the
            // subclass's.
            for (deferred_bodies.items) |*d| {
                if (d.body.int() == 0 and d.args.len == 0) continue;
                if (!std.mem.eql(u8, d.name, cls_name)) continue;
                if (d.fqn != null and !std.mem.eql(u8, d.fqn.?, cls_fqn)) continue;
                const fr = try funcAt(self, d.body, "secondary ctor body");
                switch (fr) {
                    .err => {},
                    .ok => |body_func| {
                        var all: std.ArrayList(Value) = .empty;
                        defer all.deinit(allocator);
                        try all.append(allocator, inst_value);
                        try all.appendSlice(allocator, d.args);
                        switch (try evalThunk(self, body_func, all.items)) {
                            .ok => {},
                            .err => |e| return .{ .err = e },
                        }
                    },
                }
                d.body = @enumFromInt(0);
                allocator.free(d.args);
                d.args = &.{};
            }
        }
    }

    // The parent secondary-constructor bodies chosen for the header chain
    // run on the finished instance, ancestors first.
    {
        var bi: usize = deferred_bodies.items.len;
        while (bi > 0) {
            bi -= 1;
            const d = deferred_bodies.items[bi];
            if (d.body.int() == 0 and d.args.len == 0) continue;
            const fr = try funcAt(self, d.body, "secondary ctor body");
            switch (fr) {
                .err => {},
                .ok => |body_func| {
                    var all: std.ArrayList(Value) = .empty;
                    defer all.deinit(allocator);
                    try all.append(allocator, inst_value);
                    try all.appendSlice(allocator, d.args);
                    switch (try evalThunk(self, body_func, all.items)) {
                        .ok => {},
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
    }
    return .{ .ok = inst_value };
}

/// `provideDelegate` hook for a delegated body property.
pub fn maybeProvideDelegate(self: *VmHost, allocator: Allocator, cls_name: []const u8, prop_name: []const u8, inst_value: *const Value, v: Value) Allocator.Error!EvalResult {
    const is_delegated = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (mod.registry.delegated_body_props.contains(.{ .a = cls_name, .b = prop_name })) break :blk true;
        if (mod.classId(cls_name)) |cid| {
            if (cid.int() < mod.classes.items.len) {
                const fqn = mod.classes.items[cid.int()].fqn;
                if (mod.registry.delegated_body_props.contains(.{ .a = fqn, .b = prop_name })) break :blk true;
            }
        }
        break :blk false;
    };
    if (!is_delegated) return .{ .ok = v };
    // A member operator (including a SAM-converted `PropertyDelegateProvider`)
    // or an extension operator in scope provides the delegate; a plain
    // `ReadOnlyProperty` has neither and keeps the value.
    const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInitOwned(allocator, try allocator.dupe(u8, prop_name)) } };
    return host_call_member.provideDelegateFor(self, allocator, inst_value.*, prop_ref, v);
}

pub fn retainFieldList(fields: *std.ArrayList(InstanceData.Field), allocator: Allocator, key: []const u8) void {
    _ = allocator;
    var i: usize = 0;
    while (i < fields.items.len) {
        if (std.mem.eql(u8, fields.items[i].name, key)) {
            _ = fields.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn isThrowableDirectName(name: []const u8) bool {
    const names = [_][]const u8{
        "Throwable",                       "Exception",
        "RuntimeException",                "Error",
        "IllegalArgumentException",        "IllegalStateException",
        "IndexOutOfBoundsException",       "NullPointerException",
        "ClassCastException",              "ArithmeticException",
        "NumberFormatException",           "NoSuchElementException",
        "ConcurrentModificationException", "UnsupportedOperationException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

pub fn isThrowableChainName(name: []const u8) bool {
    if (isBuiltinThrowableNameNoCancel(name)) return true;
    return std.mem.eql(u8, name, "CancellationException");
}
