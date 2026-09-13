//! The superclass constructor chain: intrinsic constructors, throwable argument
//! binding, the chain walk, and the init blocks a class or object runs.

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
const installCtorBounds = common.installCtorBounds;
const typeErr = common.typeErr;

const ctor_defaults = @import("ctor_defaults.zig");
const packPrimaryCtorVarargs = ctor_defaults.packPrimaryCtorVarargs;
const packSecondaryVarargs = ctor_defaults.packSecondaryVarargs;
const primaryCanTake = ctor_defaults.primaryCanTake;

const ctor_path = @import("ctor_path.zig");
const classDefFqn = ctor_path.classDefFqn;
const classDefIsInterface = ctor_path.classDefIsInterface;
const classDefName = ctor_path.classDefName;
const padParentCtorDefaults = ctor_path.padParentCtorDefaults;
const reorderNamedSuperArgs = ctor_path.reorderNamedSuperArgs;

const ctor_select = @import("ctor_select.zig");
const adoptDeclaredNumeric = ctor_select.adoptDeclaredNumeric;
const appendPrimaryCtorPropertyFields = ctor_select.appendPrimaryCtorPropertyFields;
const chooseSecondaryCtor = ctor_select.chooseSecondaryCtor;
const chooseSecondaryCtorDefaulted = ctor_select.chooseSecondaryCtorDefaulted;
const classDefByName = ctor_select.classDefByName;
const classDefByQualifiedSuffix = ctor_select.classDefByQualifiedSuffix;
const ctorThunkArgs = ctor_select.ctorThunkArgs;
const evalParentCtorThunk = ctor_select.evalParentCtorThunk;
const evalThunk = ctor_select.evalThunk;
const funcAt = ctor_select.funcAt;
const paramIndexByName = ctor_select.paramIndexByName;
const parentCtorArgNames = ctor_select.parentCtorArgNames;
const parentCtorArgThunks = ctor_select.parentCtorArgThunks;
const scalarRetag = ctor_select.scalarRetag;
const secondaryCtors = ctor_select.secondaryCtors;
const sideTableKey = ctor_select.sideTableKey;

pub fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only, so the published link flag
    // gates an unguarded read instead of two shared reader locks per lookup.
    {
        const img = self.prog.asPtrConst();
        if (@atomicLoad(bool, &img.resolved_linked, .acquire)) {
            if (img.installed_bindings.asPtrConst().resolve(fqn)) |f| return f;
            return stdlib.implementation(fqn);
        }
    }
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |f| return f;
    }
    return stdlib.implementation(fqn);
}

pub fn dispatchIntrinsic(self: *VmHost, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(self.allocator, "intrinsic_instances", fqn, null, null, args);
    const keepalive = self.ka.mark();
    defer self.ka.restore(keepalive);
    self.ka.pushSlice(args);
    var ih = VmIntrinsicHost{
        .module = self.module.clone(),
        .closures = self.closures.clone(),
        .globals = self.globals.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .object_states = self.object_states.clone(),
        .singletons_by_id = self.singletons_by_id.clone(),
        .allocator = self.allocator,
    };
    defer {
        ih.module.deinit();
        ih.closures.deinit();
        ih.globals.deinit();
        ih.classes.deinit();
        ih.prog.deinit();
        ih.anon_methods.deinit();
        ih.class_default_outer.deinit();
        ih.instance_id_counter.deinit();
        ih.out_sink.deinit();
        ih.threads.deinit();
        ih.object_states.deinit();
    }
    stdlib.implementations.string.clearRecvMemo();
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = ih.intrinsicHost(),
        .allocator = self.allocator,
    };
    const prev_fqn_lt = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn_lt;
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| switch (e) {
            .Thrown => |v| .{ .err = .{ .Throw = v } },
            .Return => |v| .{ .err = .{ .NonLocalReturn = v } },
            .Suspend => |wake| blk: {
                const st = try self.allocator.create(ir.eval.SuspendState);
                st.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
                break :blk .{ .err = .{ .Suspended = st } };
            },
            .Unbound => |m| .{ .err = .{ .Unbound = m } },
            .Type => |m| .{ .err = .{ .Type = m } },
            .Arity => |m| .{ .err = .{ .Arity = m } },
            .Unimplemented => |m| .{ .err = .{ .Unimplemented = m } },
            .CalleeFailed => |m| .{ .err = .{ .CalleeFailed = m } },
            else => .{ .err = try typeErr(self.allocator, "{s}", .{@tagName(e)}) },
        },
    };
}

pub fn isBuiltinThrowableName(name: []const u8) bool {
    const names = [_][]const u8{
        "Throwable",                       "Exception",
        "RuntimeException",                "Error",
        "IllegalArgumentException",        "IllegalStateException",
        "IndexOutOfBoundsException",       "NullPointerException",
        "ClassCastException",              "ArithmeticException",
        "NumberFormatException",           "NoSuchElementException",
        "ConcurrentModificationException", "UnsupportedOperationException",
        "CancellationException",           "ArrayIndexOutOfBoundsException",
        "StringIndexOutOfBoundsException", "UninitializedPropertyAccessException",
        "NoWhenBranchMatchedException",    "NegativeArraySizeException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

pub fn hasNonNullField(inst: ObjRef(InstanceData), key: []const u8) bool {
    const g = inst.borrow();
    defer g.deinit();
    for (g.get().fields.items) |f| {
        if (std.mem.eql(u8, f.name, key) and f.value != .Null) return true;
    }
    return false;
}

pub fn retainField(g: *InstanceData, allocator: Allocator, key: []const u8) void {
    var i: usize = 0;
    while (i < g.fields.items.len) {
        if (std.mem.eql(u8, g.fields.items[i].name, key)) {
            _ = g.fields.orderedRemove(i);
            g.invalidateShape();
        } else {
            i += 1;
        }
    }
    _ = allocator;
}

pub fn pushField(g: *InstanceData, allocator: Allocator, key: []const u8, v: Value) Allocator.Error!void {
    try g.ensureFieldsOwned(allocator, 1);
    try g.fields.append(allocator, .{ .name = key, .value = v });
    g.invalidateShape();
}

pub fn bindThrowableArgs(self: *VmHost, inst: ObjRef(InstanceData), args: []const Value, only_when_unset: bool) Allocator.Error!void {
    // The unset probe runs before the exclusive borrow below: the instance lock
    // is not reentrant. A sole throwable argument is the `cause`, and `message`
    // is its rendering, as the JVM constructor defines it.
    const single_cause = args.len == 1 and (args[0] == .Exception or
        (args[0] == .Instance and host_call_member.instanceIsThrowable(self, self.allocator, args[0].Instance)));
    const skip_single = only_when_unset and args.len == 1 and
        hasNonNullField(inst, if (single_cause) "cause" else "message");
    if (skip_single) return;
    const cause_message: ?Value = if (single_cause) blk: {
        break :blk switch (try host_call_member.callMember(self, self.allocator, &args[0], "toString", &.{})) {
            .ok => |s| s,
            .err => null,
        };
    } else null;
    const g = inst.borrowMut();
    defer g.deinit();
    const i = g.get();
    if (args.len == 1) {
        const only = args[0];
        const key: []const u8 = if (single_cause) "cause" else "message";
        retainField(i, self.allocator, key);
        try pushField(i, self.allocator, key, only);
        if (cause_message) |m| {
            retainField(i, self.allocator, "message");
            try pushField(i, self.allocator, "message", m);
        }
    } else if (args.len >= 2) {
        retainField(i, self.allocator, "message");
        retainField(i, self.allocator, "cause");
        try pushField(i, self.allocator, "message", args[0]);
        try pushField(i, self.allocator, "cause", args[1]);
    }
}

pub const UnitOrErr = union(enum) { ok: void, err: EvalError };

pub fn runSuperCtorChain(
    self: *VmHost,
    leaf: *const Value,
    class_fqn: ?[]const u8,
    class_name: []const u8,
    args_in: []const Value,
    arg_names: ?[]const ?[]const u8,
    outer_hint: ?*const Value,
) Allocator.Error!UnitOrErr {
    // An omitted trailing vararg is the empty array on this route too.
    const args: []const Value = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const cid = (if (class_fqn) |f| mg.get().classIdByFqn(f) else null) orelse mg.get().classId(class_name) orelse break :blk args_in;
        const irc = mg.get().classes.items[cid.int()];
        if (args_in.len >= irc.primary_params.len) break :blk args_in;
        var need = false;
        for (irc.primary_params[args_in.len..]) |ip| {
            if (ip.is_vararg) need = true;
        }
        if (!need) break :blk args_in;
        var padded: std.ArrayList(Value) = .empty;
        try padded.appendSlice(self.allocator, args_in);
        for (irc.primary_params[args_in.len..]) |ip| {
            if (!ip.is_vararg) break;
            try padded.append(self.allocator, try host_call_func.packVarargArray(self.allocator, ip.ty.name, .empty));
        }
        break :blk try padded.toOwnedSlice(self.allocator);
    };
    defer if (args.ptr != args_in.ptr) self.allocator.free(args);
    if (isBuiltinThrowableName(class_name)) {
        if (leaf.* == .Instance) {
            try bindThrowableArgs(self, leaf.Instance, args, true);
            // JVM order fills the stack trace at construction.
            var tv = leaf.*;
            try ir.eval.attachStackTrace(self.allocator, &tv);
        }
        return .{ .ok = {} };
    }
    const entries = secondaryCtors(self, class_fqn, class_name);
    const chain_def = classDefByName(self, sideTableKey(class_fqn, class_name));
    defer if (chain_def) |d| d.deinit();
    const prev_bounds = if (chain_def) |d| installCtorBounds(d) else common.ctor_bounds;
    defer common.ctor_bounds = prev_bounds;
    // A secondary ctor takes the call when the primary cannot, else exact fit.
    const primary_takes = if (chain_def) |d| primaryCanTake(self, d, args.len) else true;
    const chosen: ?root.build.SecondaryCtorEntry = if (primary_takes)
        chooseSecondaryCtor(self, entries, args)
    else
        chooseSecondaryCtorDefaulted(self, entries, args);
    const packed_args: ?[]Value = if (chosen) |e| try packSecondaryVarargs(self, self.allocator, e, args) else null;
    defer if (packed_args) |pk| self.allocator.free(pk);
    const sargs: []const Value = packed_args orelse args;
    // Declared numeric parameter types retag integer args as on the primary.
    var args_typed_list: std.ArrayList(Value) = .empty;
    defer args_typed_list.deinit(self.allocator);
    try args_typed_list.appendSlice(self.allocator, sargs);
    if (chosen) |e| {
        for (args_typed_list.items, 0..) |*arg, i| {
            if (i >= e.param_type_heads.len) break;
            if (arg.* != .Int) continue;
            if (scalarRetag(e.param_type_heads[i], arg.Int)) |rv| arg.* = rv;
        }
        var idx = args_typed_list.items.len;
        while (idx < e.param_count) : (idx += 1) {
            const dfid = (if (idx < e.default_arg_thunks.len) e.default_arg_thunks[idx] else null) orelse break;
            const fr = try funcAt(self, dfid, "secondary ctor default");
            switch (fr) {
                .err => |err| return .{ .err = err },
                .ok => |func| {
                    const thunk_args = try ctorThunkArgs(self.allocator, chain_def, outer_hint, args_typed_list.items, e.param_count);
                    defer self.allocator.free(thunk_args);
                    switch (try evalThunk(self, func, thunk_args)) {
                        .ok => |v| try args_typed_list.append(self.allocator, v),
                        .err => |err| return .{ .err = err },
                    }
                },
            }
        }
    }
    const args_typed: []Value = args_typed_list.items;
    const entry = chosen orelse {
        // No secondary ctor fits, so the class delegates through its primary:
        // bind its property params only where the leaf lacks them, child wins.
        const def = classDefByName(self, sideTableKey(class_fqn, class_name)) orelse return .{ .ok = {} };
        defer def.deinit();
        if (leaf.* == .Instance) {
            const dg = def.borrow();
            const pp = dg.get().primary_params;
            var k: usize = 0;
            while (k < args.len) : (k += 1) {
                // A named super-constructor argument binds to the base
                // parameter of that name; an unnamed one keeps its slot.
                const target: usize =
                    if (arg_names) |names|
                        (if (k < names.len) (if (names[k]) |nm| (paramIndexByName(pp, nm) orelse k) else k) else k)
                    else
                        k;
                if (target >= pp.len) continue;
                if (pp[target].property == null) continue;
                if (hasNonNullField(leaf.Instance, pp[target].name)) continue;
                const g = leaf.Instance.borrowMut();
                retainField(g.get(), self.allocator, pp[target].name);
                try pushField(g.get(), self.allocator, pp[target].name, adoptDeclaredNumeric(&pp[target], args[k]));
                g.deinit();
            }
            dg.deinit();
        }
        const thunks = parentCtorArgThunks(self, class_fqn, class_name) orelse return .{ .ok = {} };
        var parent_args: std.ArrayList(Value) = .empty;
        defer parent_args.deinit(self.allocator);
        for (thunks) |fid| {
            const fr = try funcAt(self, fid, "parent ctor arg");
            switch (fr) {
                .err => |e| return .{ .err = e },
                .ok => |func| {
                    switch (try evalParentCtorThunk(self, func, args, outer_hint)) {
                        .ok => |v| try parent_args.append(self.allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
        const pref = firstNonInterfaceSuper(self, def) orelse return .{ .ok = {} };
        if (std.mem.eql(u8, pref.name, class_name)) return .{ .ok = {} };
        // This class's super-call labels name the parent's parameters.
        const parent_names = parentCtorArgNames(self, class_fqn, class_name);
        return try runSuperCtorChain(self, leaf, pref.fqn, pref.name, parent_args.items, parent_names, outer_hint);
    };

    var next_args: std.ArrayList(Value) = .empty;
    defer next_args.deinit(self.allocator);
    const args_with_recv = try ctorThunkArgs(self.allocator, chain_def, outer_hint, args_typed, 0);
    defer self.allocator.free(args_with_recv);
    for (entry.delegation_arg_thunks) |fid| {
        const fr = try funcAt(self, fid, "secondary ctor arg");
        switch (fr) {
            .err => |e| return .{ .err = e },
            .ok => |func| {
                switch (try evalThunk(self, func, args_with_recv)) {
                    .ok => |v| try next_args.append(self.allocator, v),
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    if (entry.is_this) {
        switch (try runSuperCtorChain(self, leaf, class_fqn, class_name, next_args.items, null, outer_hint)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    } else if (entry.is_super) {
        // `super(...)` targets the parent of the class whose ctor is running.
        var parent_name: ?[]const u8 = null;
        var parent_fqn: ?[]const u8 = null;
        if (classDefByName(self, sideTableKey(class_fqn, class_name))) |def| {
            const dg = def.borrow();
            if (dg.get().parent) |parent| {
                const pcg = parent.borrow();
                parent_name = pcg.get().name;
                parent_fqn = pcg.get().fqn;
                pcg.deinit();
            }
            dg.deinit();
            def.deinit();
        }
        if (parent_name) |p| {
            switch (try runSuperCtorChain(self, leaf, parent_fqn, p, next_args.items, null, outer_hint)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
        }
    }
    if (entry.body) |body_fid| {
        const fr = try funcAt(self, body_fid, "secondary ctor body");
        switch (fr) {
            .err => {},
            .ok => |body_func| {
                var all: std.ArrayList(Value) = .empty;
                defer all.deinit(self.allocator);
                try all.append(self.allocator, leaf.*);
                try all.appendSlice(self.allocator, args_typed);
                switch (try evalThunk(self, body_func, all.items)) {
                    .ok => {},
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    return .{ .ok = {} };
}

pub const ChainEntry = struct { name: []const u8, fqn: ?[]const u8 = null, args: []Value };

/// Evaluates every class-to-class delegation below an object expression's direct
/// superclass, which the enclosing lexical scope already evaluated; the rest bind
/// against each class's primary-ctor parameters.
pub fn extendAnonymousParentCtorArgs(
    self: *VmHost,
    allocator: Allocator,
    direct_def: ObjRef(ClassDef),
    direct_args: []Value,
    outer_hint: ?*const Value,
    fields: *std.ArrayList(InstanceData.Field),
    args_by_class: *std.StringHashMap([]Value),
) Allocator.Error!UnitOrErr {
    var cur_def: ?ObjRef(ClassDef) = direct_def.clone();
    defer if (cur_def) |d| d.deinit();
    var cur_args: []const Value = direct_args;
    var depth: usize = 0;

    while (cur_def) |cdef| {
        if (depth >= 128) break;
        depth += 1;

        const cur_name = classDefName(cdef);
        const cur_fqn = classDefFqn(cdef);
        const thunks = parentCtorArgThunks(self, cur_fqn, cur_name) orelse break;
        const pref = firstNonInterfaceSuper(self, cdef) orelse break;
        if (std.mem.eql(u8, pref.name, cur_name)) break;

        var parent_args: std.ArrayList(Value) = .empty;
        for (thunks) |fid| {
            const fr = try funcAt(self, fid, "anonymous parent ctor arg");
            switch (fr) {
                .err => |e| {
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
                .ok => |func| switch (try evalParentCtorThunk(self, func, cur_args, outer_hint)) {
                    .ok => |v| try parent_args.append(allocator, v),
                    .err => |e| {
                        parent_args.deinit(allocator);
                        return .{ .err = e };
                    },
                },
            }
        }

        const parent_def = classDefByName(self, sideTableKey(pref.fqn, pref.name)) orelse {
            parent_args.deinit(allocator);
            break;
        };
        if (classDefIsInterface(parent_def)) {
            parent_def.deinit();
            parent_args.deinit(allocator);
            break;
        }
        switch (try reorderNamedSuperArgs(
            self,
            allocator,
            parent_def,
            pref.fqn,
            pref.name,
            parentCtorArgNames(self, cur_fqn, cur_name),
            &parent_args,
            outer_hint,
        )) {
            .ok => {},
            .err => |e| {
                parent_def.deinit();
                parent_args.deinit(allocator);
                return .{ .err = e };
            },
        }
        switch (try padParentCtorDefaults(self, allocator, parent_def, pref.fqn, pref.name, &parent_args, outer_hint)) {
            .ok => {},
            .err => |e| {
                parent_def.deinit();
                parent_args.deinit(allocator);
                return .{ .err = e };
            },
        }
        const packed_args = try packPrimaryCtorVarargs(self, pref.fqn, pref.name, try parent_args.toOwnedSlice(allocator));
        try appendPrimaryCtorPropertyFields(allocator, fields, parent_def, packed_args);
        try args_by_class.put(pref.name, packed_args);

        cur_def.?.deinit();
        cur_def = parent_def;
        cur_args = packed_args;
    }
    return .{ .ok = {} };
}

pub fn chainEntryIs(entry: *const ChainEntry, fqn: ?[]const u8, name: []const u8) bool {
    if (entry.fqn) |ef| {
        if (fqn) |f| return std.mem.eql(u8, ef, f);
    }
    return std.mem.eql(u8, entry.name, name);
}

/// Resolves a simple-name supertype from `child_fqn`: own package first, as
/// Kotlin scoping requires, then the program-wide simple-name view.
pub fn classDefForSuper(self: *VmHost, child_fqn: []const u8, child_name: []const u8, sup_name: []const u8) ?ObjRef(ClassDef) {
    const pkg = ir.packageOfFqn(child_fqn, child_name);
    if (pkg.len != 0) {
        const qualified = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pkg, sup_name }) catch
            return classDefByName(self, sup_name);
        defer self.allocator.free(qualified);
        if (classDefByName(self, qualified)) |d| return d;
    }
    return classDefByName(self, sup_name);
}

pub const SuperRef = struct { name: []const u8, fqn: ?[]const u8 };

/// First supertype of `def` that is not a known interface, the parent the ctor
/// chain delegates to. A name with no runtime def gets a null fqn, so a builtin
/// Throwable parent keeps its written name.
pub fn firstNonInterfaceSuper(self: *VmHost, def: ObjRef(ClassDef)) ?SuperRef {
    const dg = def.borrow();
    defer dg.deinit();
    // Single-fill memo over the immutable class graph; on every construction.
    switch (@atomicLoad(u8, @constCast(&dg.get().first_super_state), .acquire)) {
        1 => return null,
        2 => {
            const idx = dg.get().first_super_index;
            return .{
                .name = dg.get().supertype_names[idx],
                .fqn = dg.get().first_super_fqn,
            };
        },
        else => {},
    }
    const child_fqn = dg.get().fqn;
    const child_name = dg.get().name;
    const paths = dg.get().supertype_paths;
    for (dg.get().supertype_names, 0..) |n, i| {
        const qp: ?[]const u8 = if (i < paths.len) paths[i] else null;
        const sd = if (qp) |p| (classDefByQualifiedSuffix(self, p) orelse classDefForSuper(self, child_fqn, child_name, n)) else classDefForSuper(self, child_fqn, child_name, n);
        if (sd) |s| {
            const is_iface = classDefIsInterface(s);
            const sfqn = classDefFqn(s);
            s.deinit();
            if (is_iface) continue;
            if (i <= 255) {
                const d = @constCast(dg.get());
                d.first_super_index = @intCast(i);
                d.first_super_fqn = sfqn;
                @atomicStore(u8, &d.first_super_state, 2, .release);
            }
            return .{ .name = n, .fqn = sfqn };
        }
        // Unmemoized: the class table can still grow a later-registered parent.
        return .{ .name = n, .fqn = null };
    }
    // Every supertype resolved and none was a class, so this answer is stable.
    @atomicStore(u8, &@constCast(dg.get()).first_super_state, 1, .release);
    return null;
}

/// Runs the `init { }` blocks at position `before_prop_idx` over `this` + args.
pub fn runInitBlocksAt(
    self: *VmHost,
    cls: ObjRef(ClassDef),
    before_prop_idx: usize,
    inst_value: *const Value,
    chain: []const ChainEntry,
    fallback_args: []const Value,
) Allocator.Error!UnitOrErr {
    const cls_name = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    const cls_fqn = classDefFqn(cls);
    const fids: []const FuncId = blk: {
        const g = self.prog.borrow();
        defer g.deinit();
        break :blk g.get().init_blocks.get(sideTableKey(cls_fqn, cls_name)) orelse {
            // A runtime-registered local class has no build-time side-table
            // entry: its init blocks lowered as `$init$block$<idx>` thunks.
            return runAnonInitBlocksAt(self, cls, cls_name, before_prop_idx, inst_value, fallback_args);
        };
    };
    var cls_args: []const Value = fallback_args;
    for (chain) |*c| {
        if (chainEntryIs(c, cls_fqn, cls_name)) {
            cls_args = c.args;
            break;
        }
    }
    const body_len = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().body_properties.len;
    };
    for (fids, 0..) |fid, i| {
        const pos = blk: {
            const g = cls.borrow();
            defer g.deinit();
            const positions = g.get().init_block_property_positions;
            break :blk if (i < positions.len) positions[i] else std.math.maxInt(usize);
        };
        const effective = if (pos == std.math.maxInt(usize)) body_len else pos;
        if (effective != before_prop_idx) continue;
        const fr = try funcAt(self, fid, "init block");
        switch (fr) {
            .err => {},
            .ok => |f| {
                // An `init { }` block is class-body scope, so a lambda made
                // inside it snapshots the instance as enclosing receiver.
                var encl_v = inst_value.*;
                ir.eval.pushEnclosing(&encl_v);
                defer ir.eval.popEnclosing();
                var all: std.ArrayList(Value) = .empty;
                defer all.deinit(self.allocator);
                try all.append(self.allocator, inst_value.*);
                try all.appendSlice(self.allocator, cls_args);
                switch (try evalThunk(self, f, all.items)) {
                    .ok => {},
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    return .{ .ok = {} };
}

/// Runs a local class's `$init$block$<idx>` thunks declared at
/// `before_prop_idx`; `init_block_property_positions` holds each block's
/// body-property index, and a block after every property sits at
/// `body_properties.len`. `ctor_args` lets an `init` block read a ctor
/// parameter that is not a property, since the thunks declare the primary params.
pub fn runAnonInitBlocksAt(
    self: *VmHost,
    cls: ObjRef(ClassDef),
    cls_name: []const u8,
    before_prop_idx: usize,
    inst_value: *const Value,
    ctor_args: []const Value,
) Allocator.Error!UnitOrErr {
    const allocator = self.allocator;
    const n_blocks = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().init_block_property_positions.len;
    };
    if (n_blocks == 0) return .{ .ok = {} };
    for (0..n_blocks) |idx| {
        const pos = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().init_block_property_positions[idx];
        };
        if (pos != before_prop_idx) continue;
        const nm = try std.fmt.allocPrint(allocator, "$init$block${d}", .{idx});
        defer allocator.free(nm);
        const has = blk: {
            const key = try anonKey(allocator, cls_name, nm);
            defer allocator.free(key);
            const ag = self.anon_methods.borrow();
            defer ag.deinit();
            break :blk ag.get().contains(key);
        };
        if (!has) continue;
        switch (try host_call_member.callMember(self, allocator, inst_value, nm, ctor_args)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = {} };
}
