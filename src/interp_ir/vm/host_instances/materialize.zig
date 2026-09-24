//! Materializing an instance: the builtin collection base a class extends, the
//! field table primary parameters and body properties produce, and `by` delegates.

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

const tables = @import("../../tables.zig");
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
const StringSet = runtime.NameHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

const anonKey = @import("../host_call_member/reflect_anon.zig").anonKey;

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

/// A stdlib collection class a user class extends, by resolved fqn: the header
/// is bodiless, so the host collection becomes that supertype's delegate.
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

/// Build the host collection for a builtin collection supertype from the
/// supertype call's arguments, through the stdlib factory of the same name.
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

    // A chain entry's resolved FQN keys the per-class side tables, not a twin.
    var chain: std.ArrayList(ChainEntry) = .empty;
    defer {
        for (chain.items) |c| allocator.free(c.args);
        chain.deinit(allocator);
    }
    {
        const owned = try allocator.dupe(Value, args);
        try chain.append(allocator, .{ .name = ir_name, .fqn = class_fqn, .args = owned, .cid = ctor_select.classIdOfDef(self, class_def) });
        self.ka.pushSlice(owned);
    }
    var cur_class = ir_name;
    var cur_fqn: ?[]const u8 = class_fqn;
    var cur_args: []const Value = args;

    var throwable_message: ?Value = null;
    var throwable_cause: ?Value = null;
    var is_throwable = false;

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

    var deferred_bodies: std.ArrayList(DeferredCtorBody) = .empty;
    defer {
        for (deferred_bodies.items) |d| allocator.free(d.args);
        deferred_bodies.deinit(allocator);
    }
    var pending_super_args: ?std.ArrayList(Value) = null;
    var builtin_base: ?BuiltinBase = null;
    // The class each iteration is at: the leaf to begin with, whose def the
    // caller passed in, and thereafter the parent the previous iteration
    // already resolved. Re-deriving it from `cur_class` was a name probe per
    // ancestor per construction for a handle the loop was holding a moment
    // before.
    var cur_def_carry: ?ObjRef(ClassDef) = class_def.clone();
    defer if (cur_def_carry) |d| d.deinit();
    while (true) {
        const thunks_opt = parentCtorArgThunks(self, cur_fqn, cur_class);
        if (thunks_opt == null and pending_super_args == null) break;
        const thunks: []const FuncId = thunks_opt orelse &.{};
        if (runtime.envOnce("KLIO_ENUM_INIT_TRACE") != null) {
            std.debug.print("[chain] class={s} fqn={s} key={s} thunks=", .{ cur_class, cur_fqn orelse "-", sideTableKey(cur_fqn, cur_class) });
            for (thunks) |t| std.debug.print("{d} ", .{t.int()});
            std.debug.print("\n", .{});
        }
        const cur_def = if (cur_def_carry) |d| blk: {
            cur_def_carry = null;
            break :blk d;
        } else classDefByName(self, sideTableKey(cur_fqn, cur_class));
        // Held past the parent lookup below: the parent's id is memoized on
        // the CHILD, so releasing the child here would cost the name probe
        // the memo exists to remove.
        defer if (cur_def) |d| d.deinit();
        var parent_ref: ?SuperRef = null;
        if (cur_def) |d| parent_ref = firstNonInterfaceSuper(self, d);
        const pref = parent_ref orelse break;
        const pname = pref.name;

        var parent_args: std.ArrayList(Value) = .empty;
        // A parent secondary ctor's `super(…)` already named these arguments.
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
        const parent_key = sideTableKey(pref.fqn, pname);
        const parent_def = if (cur_def) |cd|
            (ctor_select.superDefById(self, cd, parent_key) orelse classDefByName(self, parent_key))
        else
            classDefByName(self, parent_key);
        const parent_is_iface = if (parent_def) |d| classDefIsInterface(d) else true;
        // The next iteration is this parent; hand it the handle rather than
        // let it look the same class up by name again.
        if (parent_def) |d| {
            if (cur_def_carry) |old_carry| old_carry.deinit();
            cur_def_carry = d.clone();
        }
        if (parent_def == null or parent_is_iface) {
            if (parent_def) |d| d.deinit();
            parent_args.deinit(allocator);
            break;
        }
        switch (try expandParentSecondaryThisArgs(self, allocator, pref.fqn, pname, &parent_args, parentCtorArgNames(self, cur_fqn, cur_class), &deferred_bodies, &pending_super_args, parent_def)) {
            .ok => {},
            .err => |e| {
                if (parent_def) |d| d.deinit();
                parent_args.deinit(allocator);
                return .{ .err = e };
            },
        }
        // Reorder named super-ctor args before the positional field-binding.
        if (parent_def) |d| {
            switch (try reorderNamedSuperArgs(self, allocator, d, pref.fqn, pname, parentCtorArgNames(self, cur_fqn, cur_class), &parent_args, outer_hint)) {
                .ok => {},
                .err => |e| {
                    d.deinit();
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
            // The defaults-padding block below releases this handle on every path.
        }
        // Pad trailing primary-ctor params the subclass omitted from `super(...)`.
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
        const packed_parent = try packPrimaryCtorVarargs(self, pref.fqn, pname, try parent_args.toOwnedSlice(allocator));
        // `chain` owns the duped copy the next iteration reads; the packed dies.
        const chain_args = try allocator.dupe(Value, packed_parent);
        try chain.append(allocator, .{ .name = pname, .fqn = pref.fqn, .args = chain_args, .cid = if (cur_def_carry) |d| ctor_select.classIdOfDef(self, d) else null });
        self.ka.pushSlice(chain_args);
        if (runtime.freeScratch()) allocator.free(packed_parent);
        cur_class = pname;
        cur_fqn = pref.fqn;
        cur_args = chain_args;
    }

    // Every slot the class layout declares exists before construction fills
    // any of them, so a base class's slot index means the same thing in a
    // subclass. Initializers still run in source order; they overwrite the
    // slot the layout gave them instead of appending one. A class with no
    // static layout keeps the old append order.
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    errdefer fields.deinit(allocator);
    var reserved: usize = 0;
    {
        const lctx = layoutCtx(self, allocator);
        var pred = try root.class_layout.predict(&lctx, class_def);
        switch (pred) {
            .no_layout => {},
            .ok => |*p| {
                defer p.deinit(allocator);
                try fields.ensureTotalCapacity(allocator, p.slots.len);
                for (p.slots) |s| fields.appendAssumeCapacity(.{ .name = s.name, .value = s.seed });
                reserved = p.slots.len;
            },
        }
    }

    // Apply primary-param properties bottom-up so child overrides win.
    {
        var ci: usize = chain.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls_name = chain.items[ci].name;
            const cls_args = chain.items[ci].args;
            // The leaf of the chain IS the class being constructed and its
            // def was passed in. Looking it up again by name is a hash probe
            // on every construction for an answer already in hand — the arm
            // below even falls back to it, but only once the probe has run
            // and failed. Identity is by FQN, so a same-simple-name class in
            // another package cannot be mistaken for it.
            const entry_key = sideTableKey(chain.items[ci].fqn, cls_name);
            var cls_def: ?ObjRef(ClassDef) = if (std.mem.eql(u8, entry_key, classDefFqn(class_def)))
                class_def.clone()
            else if (chain.items[ci].cid) |c|
                ctor_select.classDefById(self, c)
            else
                classDefByName(self, entry_key);
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
                        // Dedup on the storage key: a private shadow of a base
                        // ctor property must not displace the plain cell.
                        const store_key = shadowFieldKey(self, cls_name, pp[k].name);
                        // The instance owns one ref to each primary-ctor field.
                        if (runtime.reclaimEnabled()) fv.retain();
                        if (reservedSlot(fields.items, reserved, store_key)) |si| {
                            if (runtime.reclaimEnabled()) fields.items[si].value.release(allocator);
                            fields.items[si].value = fv;
                        } else {
                            retainFieldList(&fields, allocator, store_key);
                            // An override with its own cell displaces the base's
                            // plain one, unless the layout reserved that too.
                            if (store_key.len != pp[k].name.len and !isPrivateShadowProp(self, cls_name, pp[k].name) and
                                reservedSlot(fields.items, reserved, pp[k].name) == null)
                            {
                                retainFieldList(&fields, allocator, pp[k].name);
                            }
                            try fields.append(allocator, .{ .name = store_key, .value = fv });
                        }
                    }
                }
                dg.deinit();
            }
        }
    }

    // Kotlin captures a plain primary-ctor parameter a member body reads as a
    // synthesized field; seed it only when no property already owns that name.
    {
        var ci: usize = chain.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls_name = chain.items[ci].name;
            const cls_args = chain.items[ci].args;
            // The leaf of the chain IS the class being constructed and its
            // def was passed in. Looking it up again by name is a hash probe
            // on every construction for an answer already in hand — the arm
            // below even falls back to it, but only once the probe has run
            // and failed. Identity is by FQN, so a same-simple-name class in
            // another package cannot be mistaken for it.
            const entry_key = sideTableKey(chain.items[ci].fqn, cls_name);
            var cls_def: ?ObjRef(ClassDef) = if (std.mem.eql(u8, entry_key, classDefFqn(class_def)))
                class_def.clone()
            else if (chain.items[ci].cid) |c|
                ctor_select.classDefById(self, c)
            else
                classDefByName(self, entry_key);
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
                    // The layout reserves one capture slot per name, at the
                    // level this walk reaches first, so filling an empty
                    // reserved slot is the same "first writer wins" the
                    // presence scan gave the append order.
                    const slot = reservedSlot(fields.items, reserved, pnm);
                    if (slot) |si| {
                        if (fields.items[si].value != .Null) continue;
                    } else {
                        var present = false;
                        for (fields.items) |f| {
                            if (std.mem.eql(u8, f.name, pnm)) {
                                present = true;
                                break;
                            }
                        }
                        if (present) continue;
                    }
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
                    if (slot) |si| fields.items[si].value = fv else try fields.append(allocator, .{ .name = pnm, .value = fv });
                }
                dg.deinit();
            }
        }
    }

    // Seed non-nullable primitive `var` fields with their type zero. A
    // reserved slot already holds it.
    {
        var cur: ?ObjRef(ClassDef) = class_def.clone();
        while (cur) |c| {
            const g = c.borrow();
            for (g.get().body_properties) |p| {
                if (p.init != null or p.getter != null or p.delegate != null) continue;
                if (reservedSlot(fields.items, reserved, shadowFieldKey(self, g.get().name, p.name)) != null) continue;
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
            try storeListField(&fields, allocator, reserved, "name", preset.name);
            try storeListField(&fields, allocator, reserved, "ordinal", preset.ordinal);
            entry_slot = preset.slot;
            common.enum_entry_preset = null;
        }
    }
    if (builtin_base) |bb| {
        if (runtime.reclaimEnabled()) bb.value.retain();
        try storeListField(&fields, allocator, reserved, bb.key, bb.value);
    }
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = class_def.clone(),
        .fields = fields,
        .outer = null,
        .identity = identity,
        .native_state = null,
        .reserved = @intCast(reserved),
    });
    const inst_value = Value{ .Instance = inst };
    // An enum entry's initializers may name the entry while it is under
    // construction, so the entry table holds the shell before any of them runs.
    if (entry_slot) |slot| {
        if (runtime.reclaimEnabled()) inst_value.retain();
        slot.* = inst_value;
    }
    // The half-built instance is reachable only through this host local and its
    // initializers cross safe points, so pin it against a sweep.
    const ka_inst = self.ka.mark();
    defer self.ka.restore(ka_inst);
    self.ka.push(inst_value);

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
                // `outer` is owned and the table value is a borrow, so retain.
                o.retain();
                const g = inst.borrowMut();
                g.get().outer = o;
                g.deinit();
            }
        }
    }
    if (classDefIsInner(class_def)) {
        const has_outer = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().outer != null;
        };
        if (!has_outer) {
            if (try selectInnerOuter(self, allocator, class_def, ir_name, outer_hint)) |outer_v| {
                // `selectInnerOuter` returns a borrow and `outer` is owned.
                outer_v.retain();
                const g = inst.borrowMut();
                g.get().outer = outer_v;
                g.deinit();
            }
        }
    }

    // Publish an object/companion shell before its init runs, so the constructing
    // thread's re-entrant reads see it while other threads wait.
    if (classDefIsObject(class_def)) {
        if (!host_globals.noteObjectInFlight(self, class_name, inst_value)) {
            host_globals.defineRootGlobal(self, class_name, inst_value);
        }
    }

    // Class-delegation expressions. A `by <expr>` on any class in the chain
    // forwards that interface's members against that level's super-args. Leaf
    // first, so a more-derived delegation wins; the leaf keys on its runtime name.
    {
        for (chain.items, 0..) |c, idx| {
            const lookup_name = if (idx == 0) class_name else c.name;
            const delegates = classDelegateThunks(self, c.fqn, lookup_name);
            for (delegates) |sf| {
                const fr = try funcAt(self, sf.func, "class delegate");
                // The delegation expression evaluates in the class body's scope,
                // so the instance must be an enclosing receiver for the thunk.
                var inst_v = Value{ .Instance = inst };
                ir.eval.pushEnclosing(&inst_v);
                defer ir.eval.popEnclosing();
                switch (fr) {
                    .err => {},
                    .ok => |func| {
                        switch (try evalThunk(self, func, c.args)) {
                            .ok => |v| {
                                const key = try delegateFieldKey(self, sf.name);
                                const g = inst.borrowMut();
                                // Leaf first: a more-derived delegation already
                                // filled the slot the layout reserved for it.
                                const cur = g.get().get(key);
                                if (cur == null or cur.? == .Null) try g.get().define(allocator, key, v);
                                g.deinit();
                            },
                            .err => |e| return .{ .err = e },
                        }
                    },
                }
            }
        }
    }
    // `Throwable(cause)`: the single argument is the cause and the message is
    // its rendering, as the JVM constructor defines it.
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
        try g.get().define(allocator, "message", m);
        g.deinit();
    }
    if (throwable_cause) |c| {
        const g = inst.borrowMut();
        try g.get().define(allocator, "cause", c);
        g.deinit();
    }
    // JVM order: fill in the stack trace at construction for a user Throwable.
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
                            // A lambda made in the initializer must see the
                            // instance as an enclosing receiver.
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
                            // A local class's complex initializer lowers to a thunk.
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
                        // A local class's delegate lowers to a `$init$` thunk;
                        // store it under the name getValue/setValue route on.
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
                            const store_key = shadowFieldKey(self, cls_name, prop_name);
                            const exists = blk: {
                                const g = inst.borrow();
                                defer g.deinit();
                                break :blk g.get().get(prop_name) != null or g.get().get(store_key) != null;
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
            // A parent secondary-ctor body runs after its class's initializers.
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

    // Parent secondary-ctor bodies run on the finished instance, ancestors first.
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
    auditLayout(self, allocator, inst_value);
    return .{ .ok = inst_value };
}

/// `KLIO_LAYOUT_AUDIT`: compare the instance just built against the layout its
/// class would have if storage were fixed at link time. Diagnostic only.
fn auditLayout(self: *VmHost, allocator: Allocator, inst_value: Value) void {
    if (!root.class_layout.auditOn()) return;
    if (inst_value != .Instance) return;
    const ctx = layoutCtx(self, allocator);
    root.class_layout.audit(&ctx, inst_value.Instance);
}

/// The view of the program `class_layout` predicts against: the storage key a
/// property shadows under, and the class-delegation slots the side table holds.
pub fn layoutCtx(self: *VmHost, allocator: Allocator) root.class_layout.Ctx {
    return .{
        .allocator = allocator,
        .shadow_key = &layoutShadowKey,
        .shadow_ctx = @ptrCast(self),
        .delegate_keys = &layoutDelegateKeys,
        .delegate_ctx = @ptrCast(self),
        .published = &layoutPublished,
        .published_ctx = @ptrCast(self),
    };
}

/// The layout the link composed for this class, when the module names one.
///
/// A class built at execution — a declaration inside a function body, an object
/// expression — carries no module identity: its `fqn` is a bare name that a
/// top-level class of the same name would answer to, so it never consults the
/// table and the walk describes it.
fn layoutPublished(ctx: ?*anyopaque, def: *const ClassDef) ?root.class_layout.Result {
    const self: *VmHost = @ptrCast(@alignCast(ctx orelse return null));
    if (def.is_local_runtime or def.is_anonymous) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const cid = module.classIdByFqn(def.fqn) orelse return null;
    const state = module.classFieldLayoutState(cid) orelse return null;
    if (root.class_layout.noLayoutOf(state)) |why| return .{ .no_layout = why };
    const entry = module.classFieldLayout(cid) orelse return null;
    const slots = self.allocator.alloc(root.class_layout.Slot, entry.slots.len) catch return null;
    for (entry.slots, slots) |src, *dst| {
        dst.* = .{ .name = src.name, .seed = root.class_layout.seedValue(src.seed) };
    }
    // The class memoizes what it is handed for the rest of the program, so the
    // materialised slots outlive every construction that reads them.
    return .{ .ok = .{ .slots = slots, .base_count = entry.base, .owned = false } };
}

fn layoutShadowKey(ctx: ?*anyopaque, cls: []const u8, prop: []const u8) []const u8 {
    const self: *VmHost = @ptrCast(@alignCast(ctx orelse return prop));
    return ctor_select.shadowFieldKey(self, cls, prop);
}

fn layoutDelegateKeys(
    ctx: ?*anyopaque,
    def: *const ClassDef,
    out: *std.ArrayList(root.class_layout.Slot),
    a: Allocator,
) Allocator.Error!void {
    const self: *VmHost = @ptrCast(@alignCast(ctx orelse return));
    next: for (classDelegateThunks(self, def.fqn, def.name)) |sf| {
        const key = try delegateFieldKey(self, sf.name);
        // A class delegating one interface from two levels stores one field,
        // the most derived expression's, so the layout holds one slot.
        for (out.items) |e| {
            if (std.mem.eql(u8, e.name, key)) continue :next;
        }
        try out.append(a, .{ .name = key, .seed = .Null });
    }
}

/// The `__delegate__<Iface>` field key, interned for the program's lifetime so
/// the reserved slot and the store agree on one name and no construction
/// allocates a fresh copy.
pub fn delegateFieldKey(self: *VmHost, iface_name: []const u8) Allocator.Error![]const u8 {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "__delegate__{s}", .{iface_name}) catch
        return std.fmt.allocPrint(self.allocator, "__delegate__{s}", .{iface_name});
    const canon = blk: {
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        break :blk pg.get().memberNameCanonical(key);
    };
    return canon orelse try self.allocator.dupe(u8, key);
}

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
    // A member or extension `provideDelegate` operator in scope supplies the
    // delegate; a plain `ReadOnlyProperty` has neither and keeps the value.
    const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInitOwned(allocator, try allocator.dupe(u8, prop_name)) } };
    return host_call_member.provideDelegateFor(self, allocator, inst_value.*, prop_ref, v);
}

/// The index of `key` among the slots the layout reserved, which a store must
/// keep in place: moving one to the tail would shift every slot after it.
pub fn reservedSlot(fields: []const InstanceData.Field, reserved: usize, key: []const u8) ?usize {
    for (fields[0..@min(reserved, fields.len)], 0..) |f, i| {
        if (f.name.ptr == key.ptr or std.mem.eql(u8, f.name, key)) return i;
    }
    return null;
}

/// Store `v` under `key`: into the reserved slot when the layout holds one,
/// appended otherwise.
fn storeListField(
    fields: *std.ArrayList(InstanceData.Field),
    allocator: Allocator,
    reserved: usize,
    key: []const u8,
    v: Value,
) Allocator.Error!void {
    if (reservedSlot(fields.items, reserved, key)) |si| {
        if (runtime.reclaimEnabled()) fields.items[si].value.release(allocator);
        fields.items[si].value = v;
        return;
    }
    try fields.append(allocator, .{ .name = key, .value = v });
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
