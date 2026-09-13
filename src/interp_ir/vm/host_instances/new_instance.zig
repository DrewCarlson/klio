//! The positional and named-argument entry points that allocate an instance for
//! a `ClassId`, and the factory and intrinsic shortcuts they take first.

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

const common = @import("common.zig");
const CTOR_HEADS_MAX = common.CTOR_HEADS_MAX;
const ctorGuardContains = common.ctorGuardContains;
const installCtorBounds = common.installCtorBounds;
const takeCtorStaticHeads = common.takeCtorStaticHeads;
const typeErr = common.typeErr;

const ctor_defaults = @import("ctor_defaults.zig");
const defaultValueForPrimary = ctor_defaults.defaultValueForPrimary;
const pathConstDefault = ctor_defaults.pathConstDefault;

const ctor_path = @import("ctor_path.zig");
const classDefFqn = ctor_path.classDefFqn;
const classDefIsAbstract = ctor_path.classDefIsAbstract;
const classDefIsInterface = ctor_path.classDefIsInterface;
const classDefName = ctor_path.classDefName;
const classDefPrimaryParamCount = ctor_path.classDefPrimaryParamCount;
const dispatchSecondaryCtor = ctor_path.dispatchSecondaryCtor;
const interfaceConstruct = ctor_path.interfaceConstruct;
const primaryCtorPath = ctor_path.primaryCtorPath;
const throwInstantiation = ctor_path.throwInstantiation;

const ctor_select = @import("ctor_select.zig");
const chooseSecondaryCtor = ctor_select.chooseSecondaryCtor;
const chooseSecondaryCtorDefaulted = ctor_select.chooseSecondaryCtorDefaulted;
const classDefByName = ctor_select.classDefByName;
const ctorThunkThisSlot = ctor_select.ctorThunkThisSlot;
const evalThunk = ctor_select.evalThunk;
const funcAt = ctor_select.funcAt;
const isCallableArg = ctor_select.isCallableArg;
const primaryDefaultThunks = ctor_select.primaryDefaultThunks;
const scoreCtorHeads = ctor_select.scoreCtorHeads;
const secondaryCtors = ctor_select.secondaryCtors;

const materialize = @import("materialize.zig");
const materializeInstance = materialize.materializeInstance;

const super_chain = @import("super_chain.zig");
const dispatchIntrinsic = super_chain.dispatchIntrinsic;
const lookupIntrinsic = super_chain.lookupIntrinsic;

/// `outer_hint` is the constructing frame's own `this`, threaded down to
/// `materializeInstance` so an inner-class instance captures it as `outer`.
/// Scoped to one construction dispatch: Kotlin admits no suspension point
/// inside ctor, init or default-param evaluation, so it cannot outlive a park.
pub fn newInstanceNamed(self: *VmHost, allocator: Allocator, class: ClassId, args: []const Value, arg_names: []const ?[]const u8, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    // KLIO_CTOR_TRAP=<fqn> prints the executing frame when that class builds.
    if (runtime.envOnce("KLIO_CTOR_TRAP")) |want| {
        const mg0 = self.module.borrow();
        const m0 = mg0.get();
        const fqn0: []const u8 = if (class.int() < m0.classes.items.len) m0.classes.items[class.int()].fqn else "";
        mg0.deinit();
        if (std.mem.eql(u8, fqn0, want)) {
            const cf0 = ir.eval.currentFrameFunc();
            std.debug.print("[ctor-trap] {s} nargs={d} in={s}\n", .{ want, args.len, if (cf0) |c| (if (c.fqn.len != 0) c.fqn else c.name) else "<none>" });
        }
    }
    // Intrinsic-backed classes route through the host ctor.
    {
        const mg = self.module.borrow();
        const m = mg.get();
        var fqn: ?[]const u8 = null;
        if (class.int() < m.classes.items.len) {
            fqn = m.classes.items[class.int()].fqn;
        }
        mg.deinit();
        if (fqn) |f| {
            if (isIntrinsicClass(f)) {
                // `UIntArray(intArray)` wraps the signed buffer as an unsigned
                // view, which a source value class cannot hold.
                const unsigned_wrap = std.mem.startsWith(u8, f, "kotlin.U") and std.mem.endsWith(u8, f, "Array");
                // A collection ctor legitimately takes a collection or array
                // argument; routing past the intrinsic builds a hollow shell.
                const collection_ctor = std.mem.startsWith(u8, f, "kotlin.collections.");
                const first_is_array = args.len > 0 and args[0] == .Array and
                    !unsigned_wrap and !collection_ctor and !std.mem.eql(u8, f, "kotlin.String");
                if (!first_is_array) {
                    if (lookupIntrinsic(self, f)) |intrinsic| {
                        return dispatchIntrinsic(self, f, intrinsic, args);
                    }
                }
            }
        }
    }

    var any_named = false;
    for (arg_names) |n| {
        if (n != null) {
            any_named = true;
            break;
        }
    }
    if (!any_named) {
        return newInstance(self, allocator, class, args, outer_hint);
    }

    const class_name = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (class.int() >= m.classes.items.len) {
            return .{ .err = try typeErr(allocator, "Vm::new_instance_named: ClassId {d} not found", .{class.int()}) };
        }
        break :blk m.classes.items[class.int()].name;
    };
    const class_fqn = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classes.items[class.int()].fqn;
    };
    var primary_names: std.ArrayList([]const u8) = .empty;
    defer primary_names.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        for (m.classes.items[class.int()].primary_params) |p| {
            try primary_names.append(allocator, p.name);
        }
    }
    var supplied_names: std.ArrayList([]const u8) = .empty;
    defer supplied_names.deinit(allocator);
    for (arg_names) |n| {
        if (n) |nm| try supplied_names.append(allocator, nm);
    }
    // FQN first, so the params come from the class the ClassId resolved.
    const class_def = classDefByName(self, class_fqn) orelse classDefByName(self, class_name);
    defer if (class_def) |d| d.deinit();

    // Prefer the primary signature when every supplied name is a primary param.
    var all_primary = true;
    for (supplied_names.items) |nm| {
        var found = false;
        for (primary_names.items) |p| {
            if (std.mem.eql(u8, p, nm)) {
                found = true;
                break;
            }
        }
        if (!found) {
            all_primary = false;
            break;
        }
    }
    if (all_primary) {
        const n = primary_names.items.len;
        var reordered = try allocator.alloc(?Value, n);
        defer allocator.free(reordered);
        for (reordered) |*slot| slot.* = null;
        // Kotlin binds a trailing lambda to the last parameter whatever gap the
        // named arguments leave; the positional walk below would take the first
        // free slot and shift everything after it.
        const trailing_slot: ?usize = blk: {
            if (n == 0 or args.len == 0) break :blk null;
            const last = args.len - 1;
            if (arg_names[last] != null) break :blk null;
            if (!isCallableArg(&args[last])) break :blk null;
            // The last parameter must be function-typed and unclaimed by name.
            for (arg_names) |an| {
                if (an) |nm| {
                    if (std.mem.eql(u8, nm, primary_names.items[n - 1])) break :blk null;
                }
            }
            // The lowered type comes off the IR class, always reachable and the
            // table `primary_names` came from.
            const mg2 = self.module.borrow();
            defer mg2.deinit();
            const irc = mg2.get().classes.items[class.int()];
            if (n - 1 >= irc.primary_params.len) break :blk null;
            if (!std.mem.startsWith(u8, irc.primary_params[n - 1].ty.name, "Function")) break :blk null;
            break :blk n - 1;
        };
        var next_pos: usize = 0;
        var overflow = false;
        for (args, 0..) |v, i| {
            if (trailing_slot) |ts| {
                if (i == args.len - 1) {
                    reordered[ts] = v;
                    continue;
                }
            }
            if (arg_names[i]) |nm| {
                for (primary_names.items, 0..) |p, idx| {
                    if (std.mem.eql(u8, p, nm)) {
                        reordered[idx] = v;
                        break;
                    }
                }
            } else {
                while (next_pos < n and reordered[next_pos] != null) next_pos += 1;
                if (next_pos >= n) {
                    overflow = true;
                    break;
                }
                reordered[next_pos] = v;
                next_pos += 1;
            }
        }
        var primary_satisfiable = !overflow;
        if (primary_satisfiable) {
            for (reordered, 0..) |slot, idx| {
                if (slot != null) continue;
                const has_default = blk: {
                    // The IR class is the authority for defaults; `ClassDef` is
                    // not reachable by name from every build path.
                    {
                        const mg2 = self.module.borrow();
                        defer mg2.deinit();
                        const irc = mg2.get().classes.items[class.int()];
                        if (idx < irc.primary_params.len and irc.primary_params[idx].has_default) break :blk true;
                    }
                    if (class_def) |d| {
                        const dg = d.borrow();
                        defer dg.deinit();
                        if (idx < dg.get().primary_params.len) {
                            break :blk dg.get().primary_params[idx].default != null;
                        }
                    }
                    break :blk false;
                };
                if (!has_default) {
                    primary_satisfiable = false;
                    break;
                }
            }
        }
        if (primary_satisfiable) {
            const default_thunks = primaryDefaultThunks(self, class_fqn, class_name);
            var final_args: std.ArrayList(Value) = .empty;
            defer final_args.deinit(allocator);
            for (reordered, 0..) |slot, idx| {
                if (slot) |v| {
                    try final_args.append(allocator, v);
                    continue;
                }
                var resolved: Value = .Null;
                var simple = false;
                if (class_def) |d| {
                    var dflt: ?*const ast.Expr = null;
                    {
                        const dg = d.borrow();
                        defer dg.deinit();
                        if (idx < dg.get().primary_params.len) {
                            if (dg.get().primary_params[idx].default) |ff| dflt = ff.get();
                        }
                    }
                    if (dflt) |e| {
                        if (try defaultValueForPrimary(allocator, e)) |v| {
                            resolved = v;
                            simple = true;
                        } else if (try pathConstDefault(self, e)) |v| {
                            resolved = v;
                            simple = true;
                        }
                    }
                }
                // A skipped parameter whose default is not a literal or path
                // constant runs its thunk, as the positional path does.
                if (!simple and default_thunks != null and idx < default_thunks.?.len) {
                    if (default_thunks.?[idx]) |dfid| {
                        const fr = try funcAt(self, dfid, "primary ctor default");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                var thunk_args: std.ArrayList(Value) = .empty;
                                defer thunk_args.deinit(allocator);
                                const tslot: Value = if (class_def) |d| ctorThunkThisSlot(d, outer_hint) else .Null;
                                try thunk_args.append(allocator, tslot); // `this`
                                try thunk_args.appendSlice(allocator, final_args.items);
                                while (thunk_args.items.len < primary_names.items.len + 1) {
                                    try thunk_args.append(allocator, .Null);
                                }
                                switch (try evalThunk(self, func, thunk_args.items)) {
                                    .ok => |rv| resolved = rv,
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
                try final_args.append(allocator, resolved);
            }
            return newInstance(self, allocator, class, final_args.items, outer_hint);
        }
    }

    const entries = secondaryCtors(self, class_fqn, class_name);
    var chosen: ?root.build.SecondaryCtorEntry = null;
    for (entries) |e| {
        if (e.param_count < args.len) continue;
        var all_named_match = true;
        for (supplied_names.items) |nm| {
            var found = false;
            for (e.param_names) |p| {
                if (std.mem.eql(u8, p, nm)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                all_named_match = false;
                break;
            }
        }
        if (all_named_match) {
            chosen = e;
            break;
        }
    }
    if (chosen) |entry| {
        var slots = try allocator.alloc(?Value, entry.param_count);
        defer allocator.free(slots);
        for (slots) |*s| s.* = null;
        var next_pos: usize = 0;
        for (args, 0..) |v, i| {
            if (arg_names[i]) |nm| {
                for (entry.param_names, 0..) |p, idx| {
                    if (std.mem.eql(u8, p, nm)) {
                        slots[idx] = v;
                        break;
                    }
                }
            } else {
                while (next_pos < slots.len and slots[next_pos] != null) next_pos += 1;
                if (next_pos < slots.len) {
                    slots[next_pos] = v;
                    next_pos += 1;
                }
            }
        }
        var full: std.ArrayList(Value) = .empty;
        defer full.deinit(allocator);
        for (slots, 0..) |slot, idx| {
            if (slot) |v| {
                try full.append(allocator, v);
                continue;
            }
            if (idx < entry.default_arg_thunks.len) {
                if (entry.default_arg_thunks[idx]) |dfid| {
                    const fr = try funcAt(self, dfid, "secondary ctor default");
                    switch (fr) {
                        .err => |e| return .{ .err = e },
                        .ok => |func| {
                            var targs: std.ArrayList(Value) = .empty;
                            defer targs.deinit(allocator);
                            try targs.appendSlice(allocator, full.items);
                            while (targs.items.len < entry.param_count) {
                                try targs.append(allocator, .Null);
                            }
                            switch (try evalThunk(self, func, targs.items)) {
                                .ok => |v| try full.append(allocator, v),
                                .err => |e| return .{ .err = e },
                            }
                        },
                    }
                    continue;
                }
            }
            try full.append(allocator, .Null);
        }
        return newInstance(self, allocator, class, full.items, outer_hint);
    }
    // A named-arg call to a same-named top-level factory reorders against the
    // factory's own parameters; binding by position would mis-score it.
    if (findNamedFactory(self, class_name, arg_names)) |fid| {
        const mg = self.module.borrow();
        defer mg.deinit();
        return self.callFuncNamed(allocator, mg.get(), fid, args, arg_names);
    }
    return newInstance(self, allocator, class, args, outer_hint);
}

/// A same-named top-level factory covering every supplied argument name, so
/// `Foo(name = v)` can target `fun Foo(name: T)` rather than a constructor.
/// Instance methods, extensions and bodyless declarations do not qualify.
pub fn findNamedFactory(self: *VmHost, class_name: []const u8, arg_names: []const ?[]const u8) ?FuncId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    for (m.funcsBySimpleName(class_name)) |fid| {
        const f = m.funcById(fid) orelse continue;
        if (!f.hasBody()) continue;
        if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        var all_match = true;
        for (arg_names) |an| {
            const nm = an orelse continue;
            var found = false;
            for (f.params) |p| {
                if (std.mem.eql(u8, p.name, nm)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                all_match = false;
                break;
            }
        }
        if (all_match) return fid;
    }
    return null;
}

pub fn isIntrinsicClass(fqn: []const u8) bool {
    const names = [_][]const u8{
        "kotlin.text.StringBuilder",        "kotlin.text.Regex",
        "kotlin.collections.HashMap",       "kotlin.collections.HashSet",
        "kotlin.collections.LinkedHashMap", "kotlin.collections.LinkedHashSet",
        "kotlin.collections.ArrayList",     "kotlin.IntArray",
        "kotlin.LongArray",                 "kotlin.ShortArray",
        "kotlin.ByteArray",                 "kotlin.FloatArray",
        "kotlin.DoubleArray",               "kotlin.BooleanArray",
        "kotlin.CharArray",                 "kotlin.UIntArray",
        "kotlin.ULongArray",                "kotlin.UShortArray",
        "kotlin.UByteArray",                "kotlin.Array",
        "kotlin.String",                    "kotlin.UByte",
        "kotlin.UShort",                    "kotlin.UInt",
        "kotlin.ULong",
    };
    for (names) |n| {
        if (std.mem.eql(u8, fqn, n)) return true;
    }
    return false;
}

pub fn newInstance(self: *VmHost, allocator: Allocator, class: ClassId, args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    var ir_name: []const u8 = undefined;
    var ir_fqn: []const u8 = undefined;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (class.int() >= m.classes.items.len) {
            return .{ .err = try typeErr(allocator, "Vm::new_instance: ClassId {d} not found in module", .{class.int()}) };
        }
        ir_name = m.classes.items[class.int()].name;
        ir_fqn = m.classes.items[class.int()].fqn;
    }
    // The builtin Throwable hierarchy is host-backed via the intrinsic.
    if (root.isBuiltinThrowableFqn(ir_fqn)) {
        if (lookupIntrinsic(self, ir_fqn)) |intrinsic| {
            // A builtin throwable captures its stack at construction.
            var r = try dispatchIntrinsic(self, ir_fqn, intrinsic, args);
            if (r == .ok) try ir.eval.attachStackTrace(allocator, &r.ok);
            return r;
        }
    }
    // `kotlin.Pair`/`kotlin.Triple` have their own runtime representation, so
    // the intrinsic returns `Value.Pair`/`Value.Triple`, not a data instance.
    if (std.mem.eql(u8, ir_fqn, "kotlin.Pair") or std.mem.eql(u8, ir_fqn, "kotlin.Triple")) {
        if (lookupIntrinsic(self, ir_fqn)) |intrinsic| {
            return dispatchIntrinsic(self, ir_fqn, intrinsic, args);
        }
    }

    // The ClassId carries the exact identity, so the runtime ClassDef resolves
    // by FQN and a same-named class from another package cannot swap in.
    // Simple name is the fallback for classes registered under that alone.
    var class_def = classDefByName(self, ir_fqn) orelse classDefByName(self, ir_name) orelse {
        return .{ .err = .{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::new_instance: no runtime ClassDef registered for `{s}`", .{ir_name}) } };
    };
    defer class_def.deinit();
    const prev_bounds = installCtorBounds(class_def);
    defer common.ctor_bounds = prev_bounds;

    if (classDefIsAbstract(class_def)) {
        return throwInstantiation(self, allocator, "Cannot create an instance of an abstract class: {s}", classDefName(class_def));
    }
    if (classDefIsInterface(class_def)) {
        return try interfaceConstruct(self, allocator, class_def, args);
    }

    const class_name = classDefName(class_def);
    const n_primary_initial = classDefPrimaryParamCount(class_def);

    // Kotlin initializes a companion at first instantiation unless direct
    // access already did, own companion before its ancestors'.
    {
        var cur: ?ObjRef(ClassDef) = class_def.clone();
        while (cur) |c| {
            const cname = classDefName(c);
            const comp_name: ?[]const u8 = blk: {
                if (common.enum_under_init) |ef| {
                    const g = c.borrow();
                    defer g.deinit();
                    if (std.mem.eql(u8, g.get().fqn, ef)) break :blk null;
                }
                const mg = self.module.borrow();
                defer mg.deinit();
                break :blk mg.get().registry.companion_singletons.get(cname);
            };
            if (comp_name) |cn| {
                switch (try host_globals.ensureObjectSingleton(self, cn)) {
                    .ok => {},
                    .err => |e| {
                        c.deinit();
                        return .{ .err = e };
                    },
                }
            }
            const next: ?ObjRef(ClassDef) = blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk if (g.get().parent) |pp| pp.clone() else null;
            };
            c.deinit();
            cur = next;
        }
    }

    // The site's static argument heads are consumed here and re-installed only
    // across the two ranking regions below, so a delegation or default
    // underneath cannot rank against this site's types. They snapshot into this
    // frame because a nested construction rewrites the thread's buffer.
    var site_heads_buf: [CTOR_HEADS_MAX]?[]const u8 = undefined;
    const site_heads: ?[]const ?[]const u8 = if (takeCtorStaticHeads()) |sh| blk: {
        @memcpy(site_heads_buf[0..sh.len], sh);
        break :blk site_heads_buf[0..sh.len];
    } else null;
    common.ctor_static_heads = site_heads;
    defer common.ctor_static_heads = null;
    // Without a primary ctor the arguments pick the secondary they fit.
    const zero_primary_secondary = n_primary_initial == 0 and blk: {
        const entries = secondaryCtors(self, classDefFqn(class_def), class_name);
        const declares_primary = blk2: {
            const dg = class_def.borrow();
            defer dg.deinit();
            break :blk2 dg.get().has_primary_ctor;
        };
        // A declared zero-parameter primary keeps `A()`.
        break :blk if (declares_primary)
            chooseSecondaryCtor(self, entries, args) != null
        else
            chooseSecondaryCtorDefaulted(self, entries, args) != null;
    };
    // A same-arity primary/secondary pair selects by type like any overload
    // set: the secondary wins when it scores strictly better than the primary's
    // heads, as a lambda does against FunctionN versus a SAM class.
    const same_arity_secondary_better = args.len == n_primary_initial and n_primary_initial != 0 and blk: {
        var best_sec: i32 = -1;
        for (secondaryCtors(self, classDefFqn(class_def), class_name)) |e| {
            if (e.param_count != args.len) continue;
            if (scoreCtorHeads(self, e.param_type_heads, args)) |sc| {
                if (sc > best_sec) best_sec = sc;
            }
        }
        if (best_sec < 0) break :blk false;
        const prim_score = blk2: {
            var heads: std.ArrayList([]const u8) = .empty;
            defer heads.deinit(allocator);
            const dg = class_def.borrow();
            defer dg.deinit();
            for (dg.get().primary_params) |*p| {
                heads.append(allocator, p.declared_type orelse "") catch break :blk2 @as(?i32, 0);
            }
            break :blk2 scoreCtorHeads(self, heads.items, args);
        };
        const prim = prim_score orelse break :blk true;
        break :blk best_sec > prim;
    };
    const shell_guarded = ctorGuardContains(class_name);
    if (!shell_guarded and (args.len != n_primary_initial or zero_primary_secondary or same_arity_secondary_better)) {
        common.ctor_static_heads = site_heads;
        if (try dispatchSecondaryCtor(self, allocator, class, class_def, args, outer_hint)) |res| {
            return res;
        }
    }

    return primaryCtorPath(self, allocator, class_def, ir_name, args, outer_hint);
}
