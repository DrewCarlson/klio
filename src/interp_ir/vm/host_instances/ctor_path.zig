//! Choosing a construction path for a class: the `ClassDef` accessors the
//! choice reads, SAM conversion, interface and companion construction,
//! secondary-constructor dispatch, super delegation, the primary constructor
//! path, and the outer instance an inner class captures.

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
const ctorGuardContains = common.ctorGuardContains;
const ctorGuardPop = common.ctorGuardPop;
const ctorGuardPush = common.ctorGuardPush;
const installCtorBounds = common.installCtorBounds;
const typeErr = common.typeErr;

const ctor_defaults = @import("ctor_defaults.zig");
const defaultValueForPrimary = ctor_defaults.defaultValueForPrimary;
const packPrimaryCtorVarargs = ctor_defaults.packPrimaryCtorVarargs;
const packSecondaryVarargs = ctor_defaults.packSecondaryVarargs;
const pathConstDefault = ctor_defaults.pathConstDefault;
const primaryCanTake = ctor_defaults.primaryCanTake;
const primaryVarargParam = ctor_defaults.primaryVarargParam;

const ctor_select = @import("ctor_select.zig");
const chooseSecondaryCtor = ctor_select.chooseSecondaryCtor;
const chooseSecondaryCtorDefaulted = ctor_select.chooseSecondaryCtorDefaulted;
const classDefByName = ctor_select.classDefByName;
const ctorThunkArgs = ctor_select.ctorThunkArgs;
const ctorThunkThisSlot = ctor_select.ctorThunkThisSlot;
const evalThunk = ctor_select.evalThunk;
const funcAt = ctor_select.funcAt;
const nextInstanceId = ctor_select.nextInstanceId;
const paramAcceptsArg = ctor_select.paramAcceptsArg;
const paramIndexByName = ctor_select.paramIndexByName;
const parentCtorArgNames = ctor_select.parentCtorArgNames;
const primaryDefaultThunks = ctor_select.primaryDefaultThunks;
const secondaryCtors = ctor_select.secondaryCtors;

const materialize = @import("materialize.zig");
const materializeInstance = materialize.materializeInstance;

const new_instance = @import("new_instance.zig");
const newInstance = new_instance.newInstance;

const super_chain = @import("super_chain.zig");
const UnitOrErr = super_chain.UnitOrErr;
const bindThrowableArgs = super_chain.bindThrowableArgs;
const pushField = super_chain.pushField;
const retainField = super_chain.retainField;
const runSuperCtorChain = super_chain.runSuperCtorChain;

// --- ClassDef accessors (each takes a borrowed handle) ---

pub fn classDefName(d: ObjRef(ClassDef)) []const u8 {
    const g = d.borrow();
    defer g.deinit();
    return g.get().name;
}

pub fn classDefFqn(d: ObjRef(ClassDef)) []const u8 {
    const g = d.borrow();
    defer g.deinit();
    return g.get().fqn;
}

pub fn classDefIsAbstract(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_abstract;
}

pub fn classDefIsInterface(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_interface;
}

pub fn classDefIsObject(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_object;
}

pub fn classDefIsInner(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_inner;
}

/// Wrap a callable into an instance of the `fun interface` named by a
/// parameter's declared type — Kotlin's SAM conversion, which happens at the
/// call boundary, so the value the callee sees IS an instance of the
/// interface. The caller's reference MOVES into the wrapper (the argument slot
/// it came from is overwritten with the wrapper), so nothing is retained here.
///
/// Null when no conversion applies: not a callable, a `Function` slot, a type
/// parameter, or a name that is not a `fun interface`.
pub fn samWrapForParamType(self: *VmHost, allocator: Allocator, v: *const Value, ty_name: []const u8) Allocator.Error!?Value {
    if (v.* != .IrClosure) return null;
    if (ty_name.len <= 2 or std.mem.startsWith(u8, ty_name, "Function")) return null;
    const bare = std.mem.trimEnd(u8, ty_name, "?");
    const simple = blk: {
        const dot = std.mem.findScalarLast(u8, bare, '.') orelse break :blk bare;
        break :blk bare[dot + 1 ..];
    };
    const pd = classDefByName(self, simple) orelse return null;
    defer pd.deinit();
    if (!classDefIsFunInterface(pd)) return null;
    if (runtime.envOnce("KLIO_SAM_WRAP_TRACE") != null) {
        std.debug.print("[sam-wrap] ty={s} simple={s}\n", .{ ty_name, simple });
    }
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(allocator, .{ .name = "__sam_target__", .value = v.* });
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = pd.clone(),
        .fields = fields,
        .outer = null,
        .identity = nextInstanceId(self),
        .native_state = null,
    });
    return .{ .Instance = inst };
}

/// Whether `ty_name` names a `fun interface`, for the per-func mask below.
pub fn paramTypeIsFunInterface(self: *VmHost, ty_name: []const u8) bool {
    if (ty_name.len <= 2 or std.mem.startsWith(u8, ty_name, "Function")) return false;
    const bare = std.mem.trimEnd(u8, ty_name, "?");
    const simple = blk: {
        const dot = std.mem.findScalarLast(u8, bare, '.') orelse break :blk bare;
        break :blk bare[dot + 1 ..];
    };
    const pd = classDefByName(self, simple) orelse return false;
    defer pd.deinit();
    return classDefIsFunInterface(pd);
}

pub fn classDefIsFunInterface(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_fun_interface;
}

pub fn classDefPrimaryParamCount(d: ObjRef(ClassDef)) usize {
    const g = d.borrow();
    defer g.deinit();
    return g.get().primary_params.len;
}

pub fn throwInstantiation(self: *VmHost, allocator: Allocator, comptime fmt: []const u8, name: []const u8) Allocator.Error!EvalResult {
    _ = self;
    const msg = try std.fmt.allocPrint(allocator, fmt, .{name});
    return .{ .err = .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInitOwned(allocator, try allocator.dupe(u8, "kotlin.InstantiationError")),
        .message = .from(try runtime.strInitOwned(allocator, msg)),
        .cause = null,
    }) } };
}

/// Interface "construction": `List(size){init}`, SAM conversion, or a
/// same-named factory function.
pub fn interfaceConstruct(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), args: []const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    // `List(size){init}` / `MutableList(size){init}`.
    if ((std.mem.eql(u8, class_name, "List") or std.mem.eql(u8, class_name, "MutableList")) and args.len == 2) {
        if (args[0].asI64()) |size| {
            const init = args[1];
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(allocator);
            var i: i64 = 0;
            while (i < size) : (i += 1) {
                const idx = Value.newInt(i);
                switch (try self.callValue(allocator, &init, &.{idx})) {
                    .ok => |v| try items.append(allocator, v),
                    .err => |e| return .{ .err = e },
                }
            }
            return .{ .ok = try Value.newList(allocator, .{
                .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
                .mutable = std.mem.eql(u8, class_name, "MutableList"),
                .enum_entries = false,
                .backing = null,
            }) };
        }
    }
    // SAM conversion: `FunInterface(lambda)`.
    if (classDefIsFunInterface(class_def) and args.len == 1) {
        const identity = nextInstanceId(self);
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        // The SAM instance owns one ref to its target; `args[0]` is a borrow.
        if (runtime.reclaimEnabled()) args[0].retain();
        try fields.append(allocator, .{ .name = "__sam_target__", .value = args[0] });
        const inst = try ObjRef(InstanceData).init(allocator, .{
            .class = class_def.clone(),
            .fields = fields,
            .outer = null,
            .identity = identity,
            .native_state = null,
        });
        return .{ .ok = .{ .Instance = inst } };
    }
    // Same-named factory function.
    if (try pickFactory(self, allocator, class_name, args)) |fid| {
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        const mg = module_ref.borrow();
        defer mg.deinit();
        return self.callFunc(allocator, mg.get(), fid, args);
    }
    {
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        const mg = module_ref.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (runtime.envOnce("KLIO_NU_TRACE") != null) {
            std.debug.print("[ifact] {s} nargs={d} cands={d} tags:", .{ class_name, args.len, m.funcsBySimpleName(class_name).len });
            for (args) |*av| std.debug.print(" {s}", .{@tagName(av.*)});
            std.debug.print("\n", .{});
            for (m.funcsBySimpleName(class_name)) |fid2| {
                const f2 = m.funcById(fid2) orelse continue;
                std.debug.print("[ifact] fid={d} body={} np={d} p0={s} def1={}\n", .{ fid2.int(), f2.hasBody(), f2.params.len, if (f2.params.len > 0) f2.params[0].name else "-", funcParamHasDefault(self, fid2, 1) });
            }
        }
    }
    return throwInstantiation(self, allocator, "Cannot create an instance of an interface: {s}", class_name);
}

pub fn isAllUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

pub fn funcParamHasDefault(self: *VmHost, fid: FuncId, idx: usize) bool {
    const g = self.prog.borrow();
    defer g.deinit();
    if (g.get().func_defaults.get(fid.int())) |slots| {
        if (idx < slots.len) {
            return slots[idx] != null;
        }
    }
    return false;
}

/// Returns the constructed instance value, or `null` to fall through to
/// the primary-ctor path.
pub fn dispatchSecondaryCtor(self: *VmHost, allocator: Allocator, class: ClassId, class_def: ObjRef(ClassDef), args: []const Value, outer_hint: ?*const Value) Allocator.Error!?EvalResult {
    const ctor_keepalive = self.ka.mark();
    defer self.ka.restore(ctor_keepalive);
    self.ka.pushSlice(args);
    const prev_bounds = installCtorBounds(class_def);
    defer common.ctor_bounds = prev_bounds;
    const class_name = classDefName(class_def);
    const entries = secondaryCtors(self, classDefFqn(class_def), class_name);
    // A defaulted secondary is a candidate only when the primary cannot
    // take the call (a class without a primary, or an arity the primary and
    // its own defaults do not cover).
    const primary_takes = primaryCanTake(self, class_def, args.len);
    var chosen: ?root.build.SecondaryCtorEntry = if (primary_takes)
        chooseSecondaryCtor(self, entries, args)
    else
        chooseSecondaryCtorDefaulted(self, entries, args);
    // Everything below constructs further values; the site's static heads
    // describe THIS call's arguments only.
    common.ctor_static_heads = null;
    if (chosen == null) {
        for (entries) |e| {
            // A hidden binary-compat constructor must not swallow an
            // under-applied call the PRIMARY constructor serves:
            // `KeyboardOptions()` was picking the hidden
            // `constructor(autoCorrect: Boolean = Default.autoCorrectOrDefault, …)`
            // over the primary, and then evaluating its default expressions.
            if (e.low_priority) continue;
            if (e.param_count > args.len) {
                var all_default = true;
                var idx = args.len;
                while (idx < e.default_arg_thunks.len) : (idx += 1) {
                    if (e.default_arg_thunks[idx] == null) {
                        all_default = false;
                        break;
                    }
                }
                if (!all_default) continue;
                // The provided args must type-match this larger candidate's
                // params (same subtype guard as chooseSecondaryCtor), so the
                // fallback does not bind a class value to a mismatched slot and
                // re-select the wrong ctor a `this(...)` delegation should skip.
                var typ_ok = true;
                var j: usize = 0;
                while (j < args.len and j < e.param_type_heads.len) : (j += 1) {
                    if (!paramAcceptsArg(self, e.param_type_heads[j], &args[j])) {
                        typ_ok = false;
                        break;
                    }
                }
                if (!typ_ok) continue;
                chosen = e;
                break;
            }
        }
    }
    const entry = chosen orelse return null;
    const packed_args: ?[]Value = try packSecondaryVarargs(self, allocator, entry, args);
    defer if (packed_args) |pk| allocator.free(pk);
    const sargs: []const Value = packed_args orelse args;

    // Materialize the full positional argument list, filling trailing
    // params the caller omitted from their default thunks.
    var full_args: std.ArrayList(Value) = .empty;
    defer full_args.deinit(allocator);
    try full_args.appendSlice(allocator, sargs);
    {
        var idx = sargs.len;
        while (idx < entry.param_count) : (idx += 1) {
            if (idx >= entry.default_arg_thunks.len or entry.default_arg_thunks[idx] == null) {
                return EvalResult{ .err = try typeErr(allocator, "secondary ctor param {d} has no default to apply", .{idx}) };
            }
            const dfid = entry.default_arg_thunks[idx].?;
            if (runtime.envOnce("KLIO_CTOR_TRACE") != null) std.debug.print("[ctor-default] class={s} param={d}/{d} fid={d} args={d}\n", .{ class_name, idx, entry.param_count, dfid.int(), args.len });
            const fr = try funcAt(self, dfid, "secondary ctor default");
            switch (fr) {
                .err => |e| return EvalResult{ .err = e },
                .ok => |func| {
                    const thunk_args = try ctorThunkArgs(allocator, class_def, outer_hint, full_args.items, entry.param_count);
                    defer allocator.free(thunk_args);
                    const full_keepalive = self.ka.mark();
                    self.ka.pushSlice(full_args.items);
                    const evaluated = evalThunk(self, func, thunk_args);
                    self.ka.restore(full_keepalive);
                    switch (try evaluated) {
                        .ok => |v| try full_args.append(allocator, v),
                        .err => |e| return EvalResult{ .err = e },
                    }
                },
            }
        }
    }
    self.ka.pushSlice(full_args.items);

    // Evaluate the delegation args.
    var target_args: std.ArrayList(Value) = .empty;
    defer target_args.deinit(allocator);
    const full_with_recv = try ctorThunkArgs(allocator, class_def, outer_hint, full_args.items, 0);
    defer allocator.free(full_with_recv);
    for (entry.delegation_arg_thunks) |fid| {
        const fr = try funcAt(self, fid, "secondary ctor arg");
        switch (fr) {
            .err => |e| return EvalResult{ .err = e },
            .ok => |func| {
                const target_keepalive = self.ka.mark();
                self.ka.pushSlice(target_args.items);
                const evaluated = evalThunk(self, func, full_with_recv);
                self.ka.restore(target_keepalive);
                switch (try evaluated) {
                    .ok => |v| try target_args.append(allocator, v),
                    .err => |e| return EvalResult{ .err = e },
                }
            },
        }
    }
    self.ka.pushSlice(target_args.items);

    var inst_v: Value = undefined;
    if (entry.is_super) {
        switch (try superDelegation(self, allocator, class, class_def, target_args.items, outer_hint)) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    } else if (entry.is_this) {
        switch (try newInstance(self, allocator, class, target_args.items, outer_hint)) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    } else {
        // Implicit `super()`.
        ctorGuardPush(class_name);
        const shell = try newInstance(self, allocator, class, &.{}, outer_hint);
        ctorGuardPop();
        switch (shell) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    }
    self.ka.push(inst_v);

    // Body block.
    if (entry.body) |body_fid| {
        const fr = try funcAt(self, body_fid, "secondary ctor body");
        switch (fr) {
            .err => {},
            .ok => |body_func| {
                var all: std.ArrayList(Value) = .empty;
                defer all.deinit(allocator);
                try all.append(allocator, inst_v);
                try all.appendSlice(allocator, full_args.items);
                switch (try evalThunk(self, body_func, all.items)) {
                    .ok => {},
                    .err => |e| return EvalResult{ .err = e },
                }
            },
        }
    }
    return EvalResult{ .ok = inst_v };
}

/// The `: super(...)` arm. Returns the constructed leaf instance, or an
/// error (including `Unimplemented` when no parent class def exists for a
/// non-Throwable parent).
pub fn superDelegation(self: *VmHost, allocator: Allocator, class: ClassId, class_def: ObjRef(ClassDef), target_args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    // Resolve the parent def: prefer the resolved `parent`, else the
    // first supertype name.
    var parent_def: ?ObjRef(ClassDef) = null;
    {
        const dg = class_def.borrow();
        if (dg.get().parent) |p| parent_def = p.clone();
        if (parent_def == null) {
            if (dg.get().supertype_names.len > 0) {
                parent_def = classDefByName(self, dg.get().supertype_names[0]);
            }
        }
        dg.deinit();
    }
    defer if (parent_def) |p| p.deinit();

    if (parent_def) |pdef| {
        const pname = classDefName(pdef);
        // The labels of this class's super-constructor call apply to the
        // parent's parameters, so a named argument binds by parameter name.
        const cur_names = parentCtorArgNames(self, classDefFqn(class_def), class_name);
        ctorGuardPush(class_name);
        const leaf_res = try newInstance(self, allocator, class, &.{}, outer_hint);
        ctorGuardPop();
        const leaf = switch (leaf_res) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        if (leaf == .Instance) {
            const g = leaf.Instance.borrowMut();
            const inst = g.get();
            const pg = pdef.borrow();
            const pp = pg.get().primary_params;
            var k: usize = 0;
            while (k < target_args.len) : (k += 1) {
                const target: usize =
                    if (cur_names) |names|
                        (if (k < names.len) (if (names[k]) |nm| (paramIndexByName(pp, nm) orelse k) else k) else k)
                    else
                        k;
                if (target >= pp.len) continue;
                if (pp[target].property != null) {
                    retainField(inst, allocator, pp[target].name);
                    try pushField(inst, allocator, pp[target].name, target_args[k]);
                }
            }
            pg.deinit();
            g.deinit();
        }
        switch (try runSuperCtorChain(self, &leaf, classDefFqn(pdef), pname, target_args, cur_names, outer_hint)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
        return .{ .ok = leaf };
    }

    // No user ClassDef for the parent — a builtin (Throwable hierarchy).
    var parent_name: []const u8 = "";
    {
        const dg = class_def.borrow();
        if (dg.get().supertype_names.len > 0) parent_name = dg.get().supertype_names[0];
        dg.deinit();
    }
    const is_throwable_name = isBuiltinThrowableNameNoCancel(parent_name);
    if (!is_throwable_name) {
        return .{ .err = .{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::new_instance: secondary ctor super-delegation for `{s}` (no parent class def)", .{class_name}) } };
    }
    const leaf_res = try newInstance(self, allocator, class, &.{}, outer_hint);
    const leaf = switch (leaf_res) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (leaf == .Instance) {
        try bindThrowableArgs(self, leaf.Instance, target_args, false);
    }
    return .{ .ok = leaf };
}

pub fn isBuiltinThrowableNameNoCancel(name: []const u8) bool {
    const names = [_][]const u8{
        "Throwable",                       "Exception",
        "RuntimeException",                "Error",
        "IOException",                     "EOFException",
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

pub fn primaryCtorPath(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, args_in: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    const n_primary = classDefPrimaryParamCount(class_def);

    var effective: std.ArrayList(Value) = .empty;
    defer effective.deinit(allocator);
    try effective.appendSlice(allocator, args_in);

    // Pack trailing positional args into the primary ctor's vararg slot.
    {
        const owned = try allocator.dupe(Value, effective.items);
        const packed_args = try packPrimaryCtorVarargs(self, classDefFqn(class_def), class_name, owned);
        effective.clearRetainingCapacity();
        try effective.appendSlice(allocator, packed_args);
        allocator.free(packed_args);
    }

    // Same-named factory wins when the ctor definitely cannot take args.
    {
        const provided = effective.items.len;
        var ctor_unsatisfiable = provided > n_primary;
        if (!ctor_unsatisfiable) {
            var idx = provided;
            while (idx < n_primary) : (idx += 1) {
                const dg = class_def.borrow();
                const no_default = idx < dg.get().primary_params.len and dg.get().primary_params[idx].default == null;
                dg.deinit();
                if (no_default) {
                    ctor_unsatisfiable = true;
                    break;
                }
            }
        }
        if (!ctor_unsatisfiable) {
            for (effective.items, 0..) |a, i| {
                const declared: ?[]const u8 = blk: {
                    const dg = class_def.borrow();
                    defer dg.deinit();
                    if (i < dg.get().primary_params.len) break :blk dg.get().primary_params[i].declared_type;
                    break :blk null;
                };
                if (declared) |t| {
                    const ty = TypeRef{ .name = t, .nullable = true, .args = &.{} };
                    if (host_call_func.runtimeParamPoints(self, &ty, &a) == null) {
                        ctor_unsatisfiable = true;
                        break;
                    }
                }
            }
        }
        if (ctor_unsatisfiable) {
            // The primary ctor cannot take these argument TYPES, but a
            // secondary ctor might: `LocalDate(Int, Month, Int)` matches the
            // secondary `(year, month: Month, day)`, not the primary
            // `(year, monthNumber: Int, day)`. Dispatch the secondary BEFORE
            // falling to a same-named factory function — a deprecated
            // `@LowPriorityInOverloadResolution fun Name(...) = Name(...)`
            // factory would otherwise self-recurse without bound.
            if (!ctorGuardContains(class_name)) {
                const cid: ?ClassId = blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    break :blk mg.get().classIdByFqn(classDefFqn(class_def));
                };
                if (cid) |c| {
                    if (try dispatchSecondaryCtor(self, allocator, c, class_def, effective.items, outer_hint)) |res| return res;
                }
            }
            if (try pickFactory(self, allocator, class_name, effective.items)) |fid| {
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                const mg = module_ref.borrow();
                defer mg.deinit();
                return self.callFunc(allocator, mg.get(), fid, effective.items);
            }
            if (try companionInvoke(self, allocator, class_def, effective.items)) |r| return r;
        }
    }

    // Fill omitted trailing params from default thunks.
    if (effective.items.len < n_primary) {
        const default_thunks = primaryDefaultThunks(self, classDefFqn(class_def), class_name);
        var idx = effective.items.len;
        while (idx < n_primary) : (idx += 1) {
            var dflt_expr: ?*const ast.Expr = null;
            {
                const dg = class_def.borrow();
                defer dg.deinit();
                if (idx < dg.get().primary_params.len) {
                    if (dg.get().primary_params[idx].default) |ff| dflt_expr = ff.get();
                }
            }
            var v: Value = .Null;
            var resolved = false;
            if (dflt_expr) |e| {
                if (try defaultValueForPrimary(allocator, e)) |lv| {
                    v = lv;
                    resolved = true;
                } else if (try pathConstDefault(self, e)) |lv| {
                    v = lv;
                    resolved = true;
                }
            }
            if (!resolved) {
                if (default_thunks) |slots| {
                    if (idx < slots.len) {
                        if (slots[idx]) |dfid| {
                            const fr = try funcAt(self, dfid, "primary ctor default");
                            switch (fr) {
                                .err => {},
                                .ok => |func| {
                                    var thunk_args: std.ArrayList(Value) = .empty;
                                    defer thunk_args.deinit(allocator);
                                    try thunk_args.append(allocator, ctorThunkThisSlot(class_def, outer_hint)); // `this`
                                    try thunk_args.appendSlice(allocator, effective.items);
                                    while (thunk_args.items.len < n_primary + 1) {
                                        try thunk_args.append(allocator, .Null);
                                    }
                                    switch (try evalThunk(self, func, thunk_args.items)) {
                                        .ok => |rv| v = rv,
                                        .err => |e| return .{ .err = e },
                                    }
                                },
                            }
                        }
                    }
                }
            }
            try effective.append(allocator, v);
        }
    }

    if (effective.items.len != n_primary) {
        // Same-named factory with matching arity.
        if (try pickFactory(self, allocator, class_name, effective.items)) |fid| {
            const module_ref = self.module.clone();
            defer module_ref.deinit();
            const mg = module_ref.borrow();
            defer mg.deinit();
            return self.callFunc(allocator, mg.get(), fid, effective.items);
        }
        // Compose ABI completion: a same-named COMPOSABLE factory (a
        // file-private `@Composable fun Stack(...)` shadowed by a pack's
        // internal `class Stack`) carries the pass-appended ($composer,
        // $changed) pair the ctor-shaped call site never wrote. With a
        // composer ambient, complete the pair and re-pick.
        {
            if (@import("../compose.zig").currentComposer()) |c| {
                var ext: std.ArrayList(Value) = .empty;
                defer ext.deinit(allocator);
                try ext.appendSlice(allocator, effective.items);
                try ext.append(allocator, c);
                try ext.append(allocator, .{ .Int = 0 });
                if (try pickFactory(self, allocator, class_name, ext.items)) |fid| {
                    const module_ref = self.module.clone();
                    defer module_ref.deinit();
                    const mg = module_ref.borrow();
                    defer mg.deinit();
                    return self.callFunc(allocator, mg.get(), fid, ext.items);
                }
            }
        }
        // A same-named member EXTENSION on an enclosing implicit receiver is
        // Kotlin's target when the ctor shape does not fit: `validate {
        // Stack(h) { ... } }` calls the file's `MockViewValidator.Stack`,
        // never the pack's internal `class Stack` constructor.
        {
            const encl = ir.eval.enclosingEntriesAlloc(allocator) catch &.{};
            defer allocator.free(@constCast(encl));
            for (encl) |e| {
                if (e.v != .Instance) continue;
                const r = try host_call_member.callMember(self, allocator, &e.v, class_name, effective.items);
                if (!(r == .err and r.err == .Unimplemented)) return r;
                if (r.err == .Unimplemented) {
                    const m3 = r.err.Unimplemented;
                    if (std.mem.find(u8, m3, "Vm::call_member") != null and runtime.freeScratch()) {
                        allocator.free(m3);
                    }
                }
            }
        }
        if (try companionInvoke(self, allocator, class_def, effective.items)) |r| return r;
        if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
            std.debug.print("[ctor-arity-miss] class={s} fqn={s} n_primary={d} got={d}\n", .{ class_name, classDefFqn(class_def), n_primary, effective.items.len });
            ir.eval.dumpFrameChainForDiagAlways();
        }
        return .{ .err = try typeErr(allocator, "{s}() expects {d} args, got {d}", .{ class_name, n_primary, effective.items.len }) };
    }

    // Implicit SAM conversion at the constructor boundary: a raw callable
    // bound to a parameter whose declared type is a fun interface wraps
    // into a SAM instance, exactly as the explicit `Iface { … }` form
    // does. The wrapped value is what dispatch relies on for the
    // interface's method identity — a receiver-typed single method
    // (`PointerInputEventHandler`'s `PointerInputScope.invoke()`) can
    // only bind its extension receiver through the instance's class.
    for (effective.items, 0..) |a, i| {
        if (a != .IrClosure) continue;
        const declared: ?[]const u8 = blk: {
            const dg = class_def.borrow();
            defer dg.deinit();
            if (i < dg.get().primary_params.len) break :blk dg.get().primary_params[i].declared_type;
            break :blk null;
        };
        const dt = declared orelse continue;
        if (dt.len == 0 or std.mem.startsWith(u8, dt, "Function")) continue;
        const pd = classDefByName(self, dt) orelse continue;
        defer pd.deinit();
        if (!classDefIsFunInterface(pd)) continue;
        const identity = nextInstanceId(self);
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        if (runtime.reclaimEnabled()) a.retain();
        try fields.append(allocator, .{ .name = "__sam_target__", .value = a });
        const inst = try ObjRef(InstanceData).init(allocator, .{
            .class = pd.clone(),
            .fields = fields,
            .outer = null,
            .identity = identity,
            .native_state = null,
        });
        effective.items[i] = .{ .Instance = inst };
    }

    return materializeInstance(self, allocator, class_def, ir_name, effective.items, outer_hint);
}

/// Reorder a named super-constructor call's arguments (`: Base(objects = 2)`)
/// into the parent's declared parameter order. `arg_names[k]`, when non-null,
/// names the base parameter argument `k` binds to; unnamed arguments keep
/// their position. Gaps opened by named binding are filled with the
/// parameter default so the downstream positional field-binding is correct.
/// No-op when nothing is named. `args` is rewritten in place to length
/// `n_primary`.
pub fn reorderNamedSuperArgs(
    self: *VmHost,
    allocator: Allocator,
    parent_def: ObjRef(ClassDef),
    fqn: ?[]const u8,
    name: []const u8,
    arg_names: ?[]const ?[]const u8,
    args: *std.ArrayList(Value),
    outer_hint: ?*const Value,
) Allocator.Error!UnitOrErr {
    const names = arg_names orelse return .{ .ok = {} };
    var any_named = false;
    for (names) |n| {
        if (n != null) {
            any_named = true;
            break;
        }
    }
    if (!any_named) return .{ .ok = {} };
    const n_primary = classDefPrimaryParamCount(parent_def);
    if (n_primary == 0) return .{ .ok = {} };

    var ordered = try allocator.alloc(?Value, n_primary);
    defer allocator.free(ordered);
    for (ordered) |*o| o.* = null;
    for (args.items, 0..) |v, k| {
        var target = k;
        if (k < names.len) {
            if (names[k]) |nm| {
                const dg = parent_def.borrow();
                if (paramIndexByName(dg.get().primary_params, nm)) |ti| target = ti;
                dg.deinit();
            }
        }
        if (target < n_primary) ordered[target] = v;
    }

    const default_thunks = primaryDefaultThunks(self, fqn, name);
    var filled: std.ArrayList(Value) = .empty;
    errdefer filled.deinit(allocator);
    var i: usize = 0;
    while (i < n_primary) : (i += 1) {
        if (ordered[i]) |v| {
            try filled.append(allocator, v);
            continue;
        }
        var dflt_expr: ?*const ast.Expr = null;
        {
            const dg = parent_def.borrow();
            defer dg.deinit();
            if (i < dg.get().primary_params.len) {
                if (dg.get().primary_params[i].default) |ff| dflt_expr = ff.get();
            }
        }
        var v: Value = .Null;
        if (dflt_expr) |de| {
            if (try defaultValueForPrimary(allocator, de)) |lv| {
                v = lv;
            } else if (try pathConstDefault(self, de)) |lv| {
                v = lv;
            } else if (default_thunks) |slots| {
                if (i < slots.len) {
                    if (slots[i]) |dfid| {
                        const fr = try funcAt(self, dfid, "parent primary ctor default");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                var thunk_args: std.ArrayList(Value) = .empty;
                                defer thunk_args.deinit(allocator);
                                try thunk_args.append(allocator, ctorThunkThisSlot(parent_def, outer_hint));
                                try thunk_args.appendSlice(allocator, filled.items);
                                while (thunk_args.items.len < n_primary + 1) {
                                    try thunk_args.append(allocator, .Null);
                                }
                                switch (try evalThunk(self, func, thunk_args.items)) {
                                    .ok => |rv| v = rv,
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
            }
        }
        try filled.append(allocator, v);
    }

    args.clearRetainingCapacity();
    try args.appendSlice(allocator, filled.items);
    filled.deinit(allocator);
    return .{ .ok = {} };
}

/// Pad a parent class's super-delegation args with the defaults for any
/// trailing primary-ctor params the subclass omitted. A subclass that writes
/// `: Base(a)` for `Base(a, b = default)` delegates only `a`; without this the
/// `b` slot would materialize as Unit instead of running its default. Mirrors
/// the direct-construction default fill. `args` is grown in place.
pub fn padParentCtorDefaults(
    self: *VmHost,
    allocator: Allocator,
    parent_def: ObjRef(ClassDef),
    fqn: ?[]const u8,
    name: []const u8,
    args: *std.ArrayList(Value),
    outer_hint: ?*const Value,
) Allocator.Error!UnitOrErr {
    const n_primary = classDefPrimaryParamCount(parent_def);
    if (args.items.len >= n_primary) return .{ .ok = {} };
    const default_thunks = primaryDefaultThunks(self, fqn, name);
    // An omitted `vararg` parameter is the empty array, not a default.
    const vararg_at: ?usize, const vararg_elem: []const u8 = primaryVarargParam(self, fqn, name);
    var idx = args.items.len;
    while (idx < n_primary) : (idx += 1) {
        if (vararg_at != null and vararg_at.? == idx) {
            try args.append(allocator, try host_call_func.packVarargArray(allocator, vararg_elem, .empty));
            continue;
        }
        var dflt_expr: ?*const ast.Expr = null;
        {
            const dg = parent_def.borrow();
            defer dg.deinit();
            if (idx < dg.get().primary_params.len) {
                if (dg.get().primary_params[idx].default) |ff| dflt_expr = ff.get();
            }
        }
        var v: Value = .Null;
        var resolved = false;
        if (dflt_expr) |e| {
            if (try defaultValueForPrimary(allocator, e)) |lv| {
                v = lv;
                resolved = true;
            } else if (try pathConstDefault(self, e)) |lv| {
                v = lv;
                resolved = true;
            }
        }
        if (!resolved) {
            if (default_thunks) |slots| {
                if (idx < slots.len) {
                    if (slots[idx]) |dfid| {
                        const fr = try funcAt(self, dfid, "parent primary ctor default");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                var thunk_args: std.ArrayList(Value) = .empty;
                                defer thunk_args.deinit(allocator);
                                try thunk_args.append(allocator, ctorThunkThisSlot(parent_def, outer_hint)); // `this`
                                try thunk_args.appendSlice(allocator, args.items);
                                while (thunk_args.items.len < n_primary + 1) {
                                    try thunk_args.append(allocator, .Null);
                                }
                                switch (try evalThunk(self, func, thunk_args.items)) {
                                    .ok => |rv| v = rv,
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
            }
        }
        try args.append(allocator, v);
    }
    return .{ .ok = {} };
}

/// The companion's `operator fun invoke` is a constructor-shaped call's
/// target when neither a constructor nor a same-named function fits:
/// `A(42)` beside `class A { companion object { operator fun invoke(i: Int) } }`.
/// Null when the class has no companion or the companion's `invoke` misses.
pub fn companionInvoke(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), args: []const Value) Allocator.Error!?EvalResult {
    const cls_val = Value{ .Class = class_def };
    const comp = (try host_fields.companionOfClassValue(self, &cls_val)) orelse return null;
    if (comp != .Instance) return null;
    const r = try host_call_member.callMember(self, allocator, &comp, "invoke", args);
    if (!host_call_member.isDispatchMissFor(r, "invoke")) return r;
    host_call_member.freeDispatchMiss(allocator, r);
    return null;
}

/// Among same-named factory overloads pick the best applicable declaration.
pub fn pickFactory(self: *VmHost, allocator: Allocator, class_name: []const u8, args: []const Value) Allocator.Error!?FuncId {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const m = mg.get();
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = std.math.minInt(i32);
    var best_low: ?FuncId = null;
    var best_low_score: i32 = std.math.minInt(i32);
    for (m.funcsBySimpleName(class_name)) |fid| {
        const f = m.funcById(fid) orelse continue;
        if (!f.hasBody()) continue;
        if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        const score = (try host_call_func.runtimeFuncApplicability(self, allocator, m, fid, args)) orelse {
            if (runtime.envOnce("KLIO_FACTORY_TRACE") != null) std.debug.print("[factory] {s}#{d} params={d} inapplicable\n", .{ f.fqn, fid.int(), f.params.len });
            continue;
        };
        if (runtime.envOnce("KLIO_FACTORY_TRACE") != null) std.debug.print("[factory] {s}#{d} points={d} low={}\n", .{ f.fqn, fid.int(), score.points, score.low_priority });
        if (score.low_priority) {
            if (best_low == null or score.points > best_low_score) {
                best_low = fid;
                best_low_score = score.points;
            }
        } else if (best_ord == null or score.points > best_ord_score) {
            best_ord = fid;
            best_ord_score = score.points;
        }
    }
    return best_ord orelse best_low;
}

/// The lexically enclosing class name for an inner/nested class: the
/// build registry's `enclosing_class` map (filled when nested classes are
/// lifted to the top level), falling back to the runtime def's resolved
/// enclosing-class handle.
pub fn enclosingClassNameOf(self: *VmHost, class_def: ObjRef(ClassDef), ir_name: []const u8) ?[]const u8 {
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const reg = &mg.get().registry;
        if (reg.enclosing_class.get(ir_name)) |n| return n;
        const def_name = classDefName(class_def);
        if (!std.mem.eql(u8, def_name, ir_name)) {
            if (reg.enclosing_class.get(def_name)) |n| return n;
        }
    }
    const g = class_def.borrow();
    defer g.deinit();
    const eg = g.get().enclosing_class.borrow();
    defer eg.deinit();
    if (eg.get().*) |e| {
        const ng = e.borrow();
        defer ng.deinit();
        return ng.get().name;
    }
    return null;
}

/// True when `v` is an `Instance` whose class is `want` or a subtype of it
/// (simple name or FQN, walking the resolved parent chain and each class's
/// transitive interface supertypes).
pub fn instanceOfClassName(v: *const Value, want: []const u8) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    var cur: ?ObjRef(ClassDef) = g.get().class.clone();
    while (cur) |c| {
        const cg = c.borrow();
        const matched = std.mem.eql(u8, cg.get().name, want) or
            std.mem.eql(u8, cg.get().fqn, want) or
            classDefImplements(cg.get(), want, 0);
        const next: ?ObjRef(ClassDef) = if (cg.get().parent) |p| p.clone() else null;
        cg.deinit();
        c.deinit();
        if (matched) {
            if (next) |n| n.deinit();
            return true;
        }
        cur = next;
    }
    return false;
}

/// Whether `d` names `want` among its (transitive) interface supertypes.
/// Walks resolved `interfaces` refs recursively and falls back to the raw
/// `supertype_names` for interfaces never resolved into refs (builtin or
/// cross-pack names) — an interface-typed parameter must accept a class
/// implementing it (`TweenSpec` for `AnimationSpec<T>`).
pub fn classDefImplements(d: *const ClassDef, want: []const u8, depth: u32) bool {
    if (depth > 16) return false;
    for (d.supertype_names) |sn| {
        if (std.mem.eql(u8, sn, want)) return true;
    }
    for (d.interfaces) |iface| {
        const fg = iface.borrow();
        defer fg.deinit();
        const idef = fg.get();
        if (std.mem.eql(u8, idef.name, want) or std.mem.eql(u8, idef.fqn, want)) return true;
        if (classDefImplements(idef, want, depth + 1)) return true;
    }
    return false;
}

/// The `outer` link of an `Instance` value, `null` otherwise.
pub fn instanceOuterOf(v: *const Value) ?Value {
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    return g.get().outer;
}

/// First instance of `want` reachable through `v`'s `outer` links,
/// excluding `v` itself. The walk is Kotlin's class-nesting rule: inside a
/// member of `Inner`, `this@Outer` is in scope as the receiver reachable
/// through the dispatch receiver's captured outer.
pub fn outerWalkMatch(v: *const Value, want: []const u8) ?Value {
    var cur = instanceOuterOf(v);
    while (cur) |c| {
        if (instanceOfClassName(&c, want)) return c;
        cur = instanceOuterOf(&c);
    }
    return null;
}

/// Pick the outer instance a freshly-materialized inner-class instance
/// captures, keyed on the inner class's lexically enclosing class. The
/// receivers in scope at the construction site are, innermost first: the
/// constructing frame's own `this` (the hint) with its class-nesting tower
/// (`this`, `this.outer`, …), then the enclosing-receiver chain, where each
/// dispatch-receiver entry carries its own tower but a `with`/`run` subject
/// contributes only itself. The first receiver that is an instance of the
/// enclosing class (or a subtype) supplies the outer:
///
/// 1. the hint itself — the bare `Inner()`-inside-a-member case, and the
///    receiver-lambda case where the subject is of the enclosing class
///    (`with(other) { Inner() }` constructs `other.Inner()`);
/// 2. the hint's outer walk — a member of `Inner` constructing a sibling
///    `Inner()` reaches `this@Outer` through its own outer link, never
///    through an unrelated receiver inherited from a caller frame. Skipped
///    when the hint IS the innermost receiver-lambda subject: a displaced
///    `with(x) { … }` subject brings only itself into scope, and the
///    lambda's lexical tower continues on the chain (the displaced `this`);
/// 3. the chain, innermost first, each entry checked directly and — for
///    non-subject entries — through its outer walk;
/// 4. else the explicit hint as given (no class data, or no candidate of
///    the enclosing class — matches the pre-class-keyed behavior).
pub fn selectInnerOuter(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, outer_hint: ?*const Value) Allocator.Error!?Value {
    const want = enclosingClassNameOf(self, class_def, ir_name) orelse {
        if (runtime.envOnce("KLIO_OUTER_TRACE")) |w| {
            if (std.mem.find(u8, ir_name, w) != null) std.debug.print("[outer] {s}: no enclosing-class record, hint={}\n", .{ ir_name, outer_hint != null });
        }
        if (outer_hint) |h| return h.*;
        return null;
    };
    if (runtime.envOnce("KLIO_OUTER_TRACE")) |w| {
        if (std.mem.find(u8, ir_name, w) != null) std.debug.print("[outer] {s}: want={s} hint={}\n", .{ ir_name, want, outer_hint != null });
    }
    if (outer_hint) |h| {
        if (instanceOfClassName(h, want)) return h.*;
    }
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    const hint_is_subject = blk: {
        const h = outer_hint orelse break :blk false;
        if (h.* != .Instance) break :blk false;
        for (entries) |*e| {
            if (!e.isSubject()) continue;
            break :blk e.v == .Instance and
                ObjRef(InstanceData).ptrEq(h.Instance, e.v.Instance);
        }
        break :blk false;
    };
    if (!hint_is_subject) {
        if (outer_hint) |h| {
            if (outerWalkMatch(h, want)) |m| return m;
        }
    }
    for (entries) |*e| {
        if (instanceOfClassName(&e.v, want)) return e.v;
        if (!e.isSubject()) {
            if (outerWalkMatch(&e.v, want)) |m| return m;
        }
    }
    if (outer_hint) |h| return h.*;
    return null;
}
