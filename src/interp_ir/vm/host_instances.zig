//! `VmHost` instance construction: allocating a `Value.Instance` for a
//! `ClassId` (running primary/secondary ctors, init blocks, body-property
//! init, delegation), building anonymous-object instances, and the
//! inner-class outer-instance hint stack.
//!
//! Free functions over `*VmHost`, wired into the `ir.eval.Host` vtable
//! by `vmhost.zig`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../build.zig");

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

fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    return .{ .Type = try std.fmt.allocPrint(allocator, fmt, args) };
}

// -------------------------------------------------------------------------
// Per-thread constructor-shell recursion guard and inner-class outer
// hint stack. In Rust these were thread-locals on the `EXEC` struct read
// through `with_ctor_guard` / `with_inner_outer_hint`. The inner-outer
// hint's push/pop are wired into the host vtable through this file.
// -------------------------------------------------------------------------

threadlocal var ctor_guard: std.ArrayListUnmanaged([]const u8) = .empty;
threadlocal var inner_outer_hint: std.ArrayListUnmanaged(Value) = .empty;

/// Assert (Debug) the constructor-shell guard and inner-class outer hint are
/// clear at a run boundary and reset them so leaked-across-runs state is a
/// loud failure.
pub fn resetReceiverTls() void {
    std.debug.assert(ctor_guard.items.len == 0);
    std.debug.assert(inner_outer_hint.items.len == 0);
    ctor_guard.clearRetainingCapacity();
    inner_outer_hint.clearRetainingCapacity();
}

fn ctorGuardContains(name: []const u8) bool {
    for (ctor_guard.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn ctorGuardPush(name: []const u8) void {
    ctor_guard.append(std.heap.page_allocator, name) catch {};
}

fn ctorGuardPop() void {
    _ = ctor_guard.pop();
}

pub fn pushInnerOuterHint(self: *VmHost, v: *const Value) void {
    _ = self;
    inner_outer_hint.append(std.heap.page_allocator, v.*) catch {};
}

pub fn popInnerOuterHint(self: *VmHost) void {
    _ = self;
    _ = inner_outer_hint.pop();
}

fn innerOuterHintLast() ?Value {
    if (inner_outer_hint.items.len == 0) return null;
    return inner_outer_hint.items[inner_outer_hint.items.len - 1];
}

// -------------------------------------------------------------------------
// Small accessors mirroring the Rust borrows of `self.classes` and
// `self.prog`. Each returns a fresh handle / copy; the caller frees.
// -------------------------------------------------------------------------

/// Look up a runtime `ClassDef` by simple name, returning a fresh handle.
fn classDefByName(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    const g = self.classes.borrow();
    defer g.deinit();
    if (g.get().get(name)) |d| return d.clone();
    return null;
}

/// First concrete (non-abstract, non-interface) class sharing `name`.
fn concreteSibling(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    const g = self.classes.borrow();
    defer g.deinit();
    var it = g.get().valueIterator();
    while (it.next()) |d| {
        const dg = d.borrow();
        const cd = dg.get();
        const match = std.mem.eql(u8, cd.name, name) and !cd.is_abstract and !cd.is_interface;
        dg.deinit();
        if (match) return d.clone();
    }
    return null;
}

fn secondaryCtors(self: *VmHost, name: []const u8) []const root.build.SecondaryCtorEntry {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().secondary_ctors.get(name) orelse &.{};
}

fn parentCtorArgThunks(self: *VmHost, name: []const u8) ?[]const FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().parent_ctor_args.get(name);
}

fn primaryDefaultThunks(self: *VmHost, name: []const u8) ?[]const ?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().primary_ctor_default_thunks.get(name);
}

fn classDelegateThunks(self: *VmHost, name: []const u8) []const root.build.StrFunc {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().class_delegates.get(name) orelse &.{};
}

fn bodyPropInit(self: *VmHost, class_name: []const u8, prop_name: []const u8) ?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().body_prop_inits.get(.{ .a = class_name, .b = prop_name });
}

fn nextInstanceId(self: *VmHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

/// Materialise a `*const Func` for `fid` against the host module, or an
/// error result when the id is out of range.
fn funcAt(self: *VmHost, fid: FuncId, comptime ctx: []const u8) Allocator.Error!union(enum) { ok: *const ir.Func, err: EvalError } {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    if (fid.int() >= m.funcs.items.len) {
        return .{ .err = try typeErr(self.allocator, ctx ++ " FuncId {d} out of range", .{fid.int()}) };
    }
    return .{ .ok = &m.funcs.items[fid.int()] };
}

/// Evaluate `func` against `args`, returning its result. The module
/// handle is borrowed for the call's duration.
fn evalThunk(self: *VmHost, func: *const ir.Func, args: []const Value) Allocator.Error!EvalResult {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    var args_list: std.ArrayList(Value) = .empty;
    errdefer args_list.deinit(self.allocator);
    try args_list.appendSlice(self.allocator, args);
    var iface = self.hostInterface();
    // Ownership of `args_list` transfers into `evalWith`: the frame adopts
    // it as its `params` backing and frees it on `frame.deinit()`.
    return ir.eval.evalWith(self.allocator, mg.get(), func, args_list, &iface);
}

// -------------------------------------------------------------------------
// Free helpers ported from `lib.rs` — used only by the construction flow.
// -------------------------------------------------------------------------

fn simpleLiteral(allocator: Allocator, e: *const ast.Expr) Allocator.Error!?Value {
    switch (e.*) {
        .IntLit => |l| return Value.newInt(l.value),
        .FloatLit => |l| return Value{ .Double = l.value },
        .BoolLit => |l| return Value{ .Bool = l.value },
        .NullLit => return Value.Null,
        .CharLit => |l| return Value{ .Char = l.value },
        .StringTemplate => |t| {
            for (t.parts) |p| {
                if (p != .Text) return null;
            }
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (t.parts) |p| {
                try buf.appendSlice(allocator, p.Text);
            }
            const owned = try buf.toOwnedSlice(allocator);
            return Value{ .String = try ObjRef([]const u8).init(allocator, owned) };
        },
        else => return null,
    }
}

fn emptyList(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return Value{ .List = .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, .empty),
        .mutable = mutable,
        .enum_class = null,
        .backing = null,
    } };
}

fn emptySet(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return Value{ .Set = .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, .empty),
        .mutable = mutable,
        .backing = null,
    } };
}

fn emptyMap(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return Value{ .Map = .{
        .entries = try ObjRef(std.ArrayList(runtime.MapPair)).init(allocator, .empty),
        .mutable = mutable,
    } };
}

fn defaultValueForPrimary(allocator: Allocator, e: *const ast.Expr) Allocator.Error!?Value {
    if (try simpleLiteral(allocator, e)) |v| return v;
    if (e.* == .Call) {
        const c = e.Call;
        if (c.args.len != 0) return null;
        if (c.callee.* == .Path) {
            const segs = c.callee.Path.segments;
            if (segs.len == 1) {
                const nm = segs[0].name;
                const eq = std.mem.eql;
                if (eq(u8, nm, "mutableListOf") or eq(u8, nm, "arrayListOf") or eq(u8, nm, "ArrayList") or eq(u8, nm, "ArrayDeque")) {
                    return try emptyList(allocator, true);
                }
                if (eq(u8, nm, "listOf") or eq(u8, nm, "emptyList")) {
                    return try emptyList(allocator, false);
                }
                if (eq(u8, nm, "mutableSetOf") or eq(u8, nm, "hashSetOf") or eq(u8, nm, "linkedSetOf")) {
                    return try emptySet(allocator, true);
                }
                if (eq(u8, nm, "setOf") or eq(u8, nm, "emptySet")) {
                    return try emptySet(allocator, false);
                }
                if (eq(u8, nm, "mutableMapOf") or eq(u8, nm, "hashMapOf") or eq(u8, nm, "linkedMapOf")) {
                    return try emptyMap(allocator, true);
                }
                if (eq(u8, nm, "mapOf") or eq(u8, nm, "emptyMap")) {
                    return try emptyMap(allocator, false);
                }
            }
        }
    }
    return null;
}

/// Resolve a single-segment `Path` default against the const registry,
/// returning its `Value` when present.
fn pathConstDefault(self: *VmHost, e: *const ast.Expr) Allocator.Error!?Value {
    if (e.* != .Path) return null;
    const segs = e.Path.segments;
    if (segs.len != 1) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    if (m.registry.class_const_inits.get(.{ .a = "", .b = segs[0].name })) |c| {
        return try ir.eval.constToValue(self.allocator, &c);
    }
    return null;
}

/// Pack trailing positional args into the primary ctor's `vararg` slot.
fn packPrimaryCtorVarargs(self: *VmHost, class_name: []const u8, args: []Value) Allocator.Error![]Value {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const cid = m.classId(class_name) orelse return args;
    if (cid.int() >= m.classes.items.len) return args;
    const ir_cls = &m.classes.items[cid.int()];
    const params = ir_cls.primary_params;
    if (params.len == 0) return args;
    const last = params[params.len - 1];
    if (!last.is_vararg) return args;
    const fixed = if (params.len == 0) 0 else params.len - 1;
    if (args.len == params.len and args.len > 0 and args[args.len - 1] == .Array) {
        return args;
    }
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < fixed and i < args.len) : (i += 1) {
        try out.append(self.allocator, args[i]);
    }
    var rest: std.ArrayList(Value) = .empty;
    errdefer rest.deinit(self.allocator);
    var j: usize = fixed;
    while (j < args.len) : (j += 1) {
        try rest.append(self.allocator, args[j]);
    }
    try out.append(self.allocator, .{ .Array = .{
        .items = try ObjRef(std.ArrayList(Value)).init(self.allocator, rest),
        .prim = null,
    } });
    self.allocator.free(args);
    return out.toOwnedSlice(self.allocator);
}

// -------------------------------------------------------------------------
// `vmhost.rs` methods this flow depends on. Ported here (faithful) so the
// construction path is self-contained; they read shared `VmHost` state.
// -------------------------------------------------------------------------

fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |f| return f;
    }
    return stdlib.implementation(fqn);
}

fn dispatchIntrinsic(self: *VmHost, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
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
    }
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = ih.intrinsicHost(),
        .allocator = self.allocator,
    };
    const r = try func(&ctx);
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
            else => .{ .err = try typeErr(self.allocator, "{s}", .{@tagName(e)}) },
        },
    };
}

/// Permissive name take after the final `.` of a (possibly qualified)
/// type name.
fn lastSegment(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Subset of `overload_score_arg` sufficient for the factory pickers in
/// the construction flow. Returns `null` when the arg provably cannot
/// satisfy the parameter type.
fn overloadScoreArg(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) ?i32 {
    const nm = param_ty.name;
    var v_ty_buf: []const u8 = undefined;
    var owned_name: ?[]const u8 = null;
    if (arg.* == .Instance) {
        const g = arg.Instance.borrow();
        const cg = g.get().class.borrow();
        owned_name = cg.get().name;
        v_ty_buf = cg.get().name;
        cg.deinit();
        g.deinit();
    } else {
        const fqn = arg.typeFqn();
        v_ty_buf = lastSegment(fqn);
    }
    const v_ty = v_ty_buf;
    if (std.mem.eql(u8, nm, v_ty)) return 100;
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.* == .Null and param_ty.nullable) return 50;
    // Numeric widening.
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;
    // Callable arg against a function-typed param.
    var arg_arity: ?usize = null;
    switch (arg.*) {
        .Lambda => |l| {
            const g = l.params.borrow();
            arg_arity = g.get().*.len;
            g.deinit();
        },
        .IrClosure => |c| {
            if (self.closures.get(c.id)) |ci| arg_arity = ci.n_params;
        },
        else => {},
    }
    const is_callable = arg_arity != null or std.mem.startsWith(u8, arg.typeFqn(), "kotlin.Function");
    if (is_callable) {
        if (std.mem.startsWith(u8, nm, "Function")) {
            const want = std.fmt.parseInt(usize, nm["Function".len..], 10) catch {
                return 20;
            };
            if (arg_arity) |got| {
                return if (got == want or got == want + 1) 90 else 20;
            }
            return 20;
        }
        return 8;
    }
    // Subtype walk for instance args.
    if (arg.* == .Instance) {
        var queue: std.ArrayList(struct { name: []const u8, depth: i32 }) = .empty;
        defer queue.deinit(self.allocator);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(self.allocator);
        queue.append(self.allocator, .{ .name = v_ty, .depth = 0 }) catch return null;
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            var already = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, cur.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            seen.append(self.allocator, cur.name) catch return null;
            if (std.mem.eql(u8, cur.name, nm)) {
                const d = @min(cur.depth, 50);
                return 60 - d;
            }
            if (classDefByName(self, cur.name)) |def| {
                const dg = def.borrow();
                for (dg.get().supertype_names) |sup| {
                    queue.append(self.allocator, .{ .name = sup, .depth = cur.depth + 1 }) catch {};
                }
                dg.deinit();
                def.deinit();
            }
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Construction-chain helpers ported from `vmhost.rs`.
// -------------------------------------------------------------------------

fn isBuiltinThrowableName(name: []const u8) bool {
    const names = [_][]const u8{
        "Throwable",                "Exception",
        "RuntimeException",         "Error",
        "IllegalArgumentException", "IllegalStateException",
        "IndexOutOfBoundsException", "NullPointerException",
        "ClassCastException",       "ArithmeticException",
        "NumberFormatException",    "NoSuchElementException",
        "ConcurrentModificationException", "UnsupportedOperationException",
        "CancellationException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Whether the instance already carries a non-null field under `key`.
fn hasNonNullField(inst: ObjRef(InstanceData), key: []const u8) bool {
    const g = inst.borrow();
    defer g.deinit();
    for (g.get().fields.items) |f| {
        if (std.mem.eql(u8, f.name, key) and f.value != .Null) return true;
    }
    return false;
}

fn retainField(g: *InstanceData, allocator: Allocator, key: []const u8) void {
    var i: usize = 0;
    while (i < g.fields.items.len) {
        if (std.mem.eql(u8, g.fields.items[i].name, key)) {
            _ = g.fields.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    _ = allocator;
}

fn pushField(g: *InstanceData, allocator: Allocator, key: []const u8, v: Value) Allocator.Error!void {
    try g.fields.append(allocator, .{ .name = key, .value = v });
}

/// Bind the conventional `(message[, cause])` super-args onto a leaf
/// Throwable instance.
fn bindThrowableArgs(self: *VmHost, inst: ObjRef(InstanceData), args: []const Value, only_when_unset: bool) Allocator.Error!void {
    const g = inst.borrowMut();
    defer g.deinit();
    const i = g.get();
    if (args.len == 1) {
        const only = args[0];
        const is_cause = only == .Instance;
        const key: []const u8 = if (is_cause) "cause" else "message";
        if (only_when_unset and hasNonNullField(inst, key)) return;
        retainField(i, self.allocator, key);
        try pushField(i, self.allocator, key, only);
    } else if (args.len >= 2) {
        retainField(i, self.allocator, "message");
        retainField(i, self.allocator, "cause");
        try pushField(i, self.allocator, "message", args[0]);
        try pushField(i, self.allocator, "cause", args[1]);
    }
}

const UnitOrErr = union(enum) { ok: void, err: EvalError };

/// Dispatch the parent's matching secondary-ctor chain on the same leaf.
fn runSuperCtorChain(self: *VmHost, leaf: *const Value, class_name: []const u8, args: []const Value) Allocator.Error!UnitOrErr {
    if (isBuiltinThrowableName(class_name)) {
        if (leaf.* == .Instance) {
            try bindThrowableArgs(self, leaf.Instance, args, true);
        }
        return .{ .ok = {} };
    }
    const entries = secondaryCtors(self, class_name);
    var chosen: ?root.build.SecondaryCtorEntry = null;
    for (entries) |e| {
        if (e.param_count == args.len) {
            chosen = e;
            break;
        }
    }
    const entry = chosen orelse return .{ .ok = {} };

    var next_args: std.ArrayList(Value) = .empty;
    defer next_args.deinit(self.allocator);
    for (entry.delegation_arg_thunks) |fid| {
        const fr = try funcAt(self, fid, "secondary ctor arg");
        switch (fr) {
            .err => |e| return .{ .err = e },
            .ok => |func| {
                switch (try evalThunk(self, func, args)) {
                    .ok => |v| try next_args.append(self.allocator, v),
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    if (entry.is_this) {
        switch (try runSuperCtorChain(self, leaf, class_name, next_args.items)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    } else if (entry.is_super) {
        // The `super(...)` target is the parent of the class whose ctor
        // we're currently running.
        var parent_name: ?[]const u8 = null;
        if (classDefByName(self, class_name)) |def| {
            const dg = def.borrow();
            const pg = dg.get().parent.borrow();
            if (pg.get().*) |parent| {
                const pcg = parent.borrow();
                parent_name = pcg.get().name;
                pcg.deinit();
            }
            pg.deinit();
            dg.deinit();
            def.deinit();
        }
        if (parent_name) |p| {
            switch (try runSuperCtorChain(self, leaf, p, next_args.items)) {
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
                try all.appendSlice(self.allocator, args);
                switch (try evalThunk(self, body_func, all.items)) {
                    .ok => {},
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    return .{ .ok = {} };
}

const ChainEntry = struct { name: []const u8, args: []Value };

/// Run the class's `init { … }` blocks whose source position equals
/// `before_prop_idx`. Each block takes `this` plus the class's args.
fn runInitBlocksAt(
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
    const fids: []const FuncId = blk: {
        const g = self.prog.borrow();
        defer g.deinit();
        break :blk g.get().init_blocks.get(cls_name) orelse return .{ .ok = {} };
    };
    var cls_args: []const Value = fallback_args;
    for (chain) |c| {
        if (std.mem.eql(u8, c.name, cls_name)) {
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

// -------------------------------------------------------------------------
// `new_instance_named`
// -------------------------------------------------------------------------

pub fn newInstanceNamed(self: *VmHost, allocator: Allocator, class: ClassId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
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
                const first_is_array = args.len > 0 and args[0] == .Array and !std.mem.eql(u8, f, "kotlin.String");
                if (!first_is_array) {
                    if (lookupIntrinsic(self, f)) |intrinsic| {
                        return dispatchIntrinsic(self, intrinsic, args);
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
        return newInstance(self, allocator, class, args);
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
    // Primary param names, off the IR class.
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
    const class_def = classDefByName(self, class_name);
    defer if (class_def) |d| d.deinit();

    // Prefer the primary signature when every supplied name names a
    // primary param.
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
        var next_pos: usize = 0;
        var overflow = false;
        for (args, 0..) |v, i| {
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
            var final_args: std.ArrayList(Value) = .empty;
            defer final_args.deinit(allocator);
            for (reordered, 0..) |slot, idx| {
                if (slot) |v| {
                    try final_args.append(allocator, v);
                    continue;
                }
                var resolved: Value = .Null;
                if (class_def) |d| {
                    var dflt: ?*const ast.Expr = null;
                    {
                        const dg = d.borrow();
                        defer dg.deinit();
                        if (idx < dg.get().primary_params.len) {
                            dflt = dg.get().primary_params[idx].default;
                        }
                    }
                    if (dflt) |e| {
                        if (try defaultValueForPrimary(allocator, e)) |v| {
                            resolved = v;
                        } else if (try pathConstDefault(self, e)) |v| {
                            resolved = v;
                        }
                    }
                }
                try final_args.append(allocator, resolved);
            }
            return newInstance(self, allocator, class, final_args.items);
        }
    }

    // A named arg names a secondary-constructor parameter.
    const entries = secondaryCtors(self, class_name);
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
        return newInstance(self, allocator, class, full.items);
    }
    return newInstance(self, allocator, class, args);
}

fn isIntrinsicClass(fqn: []const u8) bool {
    const names = [_][]const u8{
        "kotlin.text.StringBuilder",      "kotlin.text.Regex",
        "kotlin.collections.HashMap",     "kotlin.collections.HashSet",
        "kotlin.collections.LinkedHashMap", "kotlin.collections.LinkedHashSet",
        "kotlin.collections.ArrayList",   "kotlin.collections.ArrayDeque",
        "kotlin.IntArray",                "kotlin.LongArray",
        "kotlin.ShortArray",              "kotlin.ByteArray",
        "kotlin.FloatArray",              "kotlin.DoubleArray",
        "kotlin.BooleanArray",            "kotlin.CharArray",
        "kotlin.Array",                   "kotlin.String",
    };
    for (names) |n| {
        if (std.mem.eql(u8, fqn, n)) return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// `new_instance`
// -------------------------------------------------------------------------

pub fn newInstance(self: *VmHost, allocator: Allocator, class: ClassId, args: []const Value) Allocator.Error!EvalResult {
    // IR class name / fqn (off the frozen module).
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
    // Builtin Throwable hierarchy: host-backed via the intrinsic.
    if (root.isBuiltinThrowableFqn(ir_fqn)) {
        if (lookupIntrinsic(self, ir_fqn)) |intrinsic| {
            return dispatchIntrinsic(self, intrinsic, args);
        }
    }
    // Builtin tuple classes (`kotlin.Pair` / `kotlin.Triple`) have a
    // distinct runtime `Value` representation and an intrinsic
    // constructor; route construction there so the result is a
    // `Value.Pair` / `Value.Triple` rather than a generic data-class
    // Instance (which would print as `Pair(first=…, second=…)`).
    if (std.mem.eql(u8, ir_fqn, "kotlin.Pair") or std.mem.eql(u8, ir_fqn, "kotlin.Triple")) {
        if (lookupIntrinsic(self, ir_fqn)) |intrinsic| {
            return dispatchIntrinsic(self, intrinsic, args);
        }
    }

    var class_def = classDefByName(self, ir_name) orelse {
        return .{ .err = .{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::new_instance: no runtime ClassDef registered for `{s}`", .{ir_name}) } };
    };
    defer class_def.deinit();

    // Abstract / interface collision redirect.
    if (classDefIsAbstract(class_def)) {
        if (concreteSibling(self, ir_name)) |d| {
            class_def.deinit();
            class_def = d;
        }
    }
    if (classDefIsInterface(class_def)) {
        if (concreteSibling(self, ir_name)) |d| {
            class_def.deinit();
            class_def = d;
        }
    }
    if (classDefIsAbstract(class_def)) {
        return throwInstantiation(self, allocator, "Cannot create an instance of an abstract class: {s}", classDefName(class_def));
    }
    if (classDefIsInterface(class_def)) {
        return try interfaceConstruct(self, allocator, class_def, args);
    }

    const class_name = classDefName(class_def);
    const n_primary_initial = classDefPrimaryParamCount(class_def);

    // Secondary-ctor dispatch.
    const zero_primary_secondary = n_primary_initial == 0 and blk: {
        for (secondaryCtors(self, class_name)) |e| {
            if (e.param_count == args.len) break :blk true;
        }
        break :blk false;
    };
    const shell_guarded = ctorGuardContains(class_name);
    if (!shell_guarded and (args.len != n_primary_initial or zero_primary_secondary)) {
        if (try dispatchSecondaryCtor(self, allocator, class, class_def, args)) |res| {
            return res;
        }
    }

    // Primary-ctor path.
    return primaryCtorPath(self, allocator, class_def, ir_name, args);
}

// --- ClassDef accessors (each takes a borrowed handle) ---

fn classDefName(d: ObjRef(ClassDef)) []const u8 {
    const g = d.borrow();
    defer g.deinit();
    return g.get().name;
}

fn classDefIsAbstract(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_abstract;
}

fn classDefIsInterface(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_interface;
}

fn classDefIsObject(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_object;
}

fn classDefIsInner(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_inner;
}

fn classDefIsFunInterface(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_fun_interface;
}

fn classDefPrimaryParamCount(d: ObjRef(ClassDef)) usize {
    const g = d.borrow();
    defer g.deinit();
    return g.get().primary_params.len;
}

fn throwInstantiation(self: *VmHost, allocator: Allocator, comptime fmt: []const u8, name: []const u8) Allocator.Error!EvalResult {
    _ = self;
    const msg = try std.fmt.allocPrint(allocator, fmt, .{name});
    return .{ .err = .{ .Throw = .{ .Exception = .{
        .fqn = try ObjRef([]const u8).init(allocator, try allocator.dupe(u8, "kotlin.InstantiationError")),
        .message = try ObjRef([]const u8).init(allocator, msg),
        .cause = null,
    } } } };
}

/// Interface "construction": `List(size){init}`, SAM conversion, or a
/// same-named factory function.
fn interfaceConstruct(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), args: []const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    // `List(size){init}` / `MutableList(size){init}`.
    if ((std.mem.eql(u8, class_name, "List") or std.mem.eql(u8, class_name, "MutableList")) and args.len == 2) {
        if (args[0].asI64()) |size| {
            const init = args[1];
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(allocator);
            var i: i64 = 0;
            while (i < size) : (i += 1) {
                var iface = self.hostInterface();
                const idx = Value.newInt(i);
                switch (try iface.callValue(allocator, &init, &.{idx})) {
                    .ok => |v| try items.append(allocator, v),
                    .err => |e| return .{ .err = e },
                }
            }
            return .{ .ok = .{ .List = .{
                .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
                .mutable = std.mem.eql(u8, class_name, "MutableList"),
                .enum_class = null,
                .backing = null,
            } } };
        }
    }
    // SAM conversion: `FunInterface(lambda)`.
    if (classDefIsFunInterface(class_def) and args.len == 1) {
        const identity = nextInstanceId(self);
        var fields: std.ArrayList(InstanceData.Field) = .empty;
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
    // Same-named factory function (best type-fit, arity-applicable).
    {
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        const mg = module_ref.borrow();
        defer mg.deinit();
        const m = mg.get();
        const provided = args.len;
        var best_fid: ?FuncId = null;
        var best_score: i64 = std.math.minInt(i64);
        for (m.funcsBySimpleName(class_name)) |fid| {
            if (fid.int() >= m.funcs.items.len) continue;
            const f = &m.funcs.items[fid.int()];
            if (f.blocks.len == 0) continue;
            if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
            const vararg = f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
            var arity_ok = vararg;
            if (!arity_ok and provided <= f.params.len) {
                arity_ok = true;
                var idx = provided;
                while (idx < f.params.len) : (idx += 1) {
                    if (!funcParamHasDefault(self, fid, idx)) {
                        arity_ok = false;
                        break;
                    }
                }
            }
            if (!arity_ok) continue;
            var score: i64 = 0;
            var viable = true;
            for (args, 0..) |a, i| {
                if (i < f.params.len) {
                    const p = &f.params[i];
                    if (overloadScoreArg(self, &p.ty, &a)) |s| {
                        score += @as(i64, s);
                    } else {
                        const pn = lastSegment(p.ty.name);
                        const generic = p.ty.nullable or
                            std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit") or
                            std.mem.startsWith(u8, pn, "Function") or
                            (pn.len <= 2 and isAllUpper(pn));
                        if (generic) {
                            score -= 2;
                        } else {
                            viable = false;
                            break;
                        }
                    }
                }
            }
            if (viable and (best_fid == null or score > best_score)) {
                best_fid = fid;
                best_score = score;
            }
        }
        if (best_fid) |fid| {
            var iface = self.hostInterface();
            return iface.callFunc(allocator, m, fid, args);
        }
    }
    return throwInstantiation(self, allocator, "Cannot create an instance of an interface: {s}", class_name);
}

fn isAllUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

fn funcParamHasDefault(self: *VmHost, fid: FuncId, idx: usize) bool {
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
fn dispatchSecondaryCtor(self: *VmHost, allocator: Allocator, class: ClassId, class_def: ObjRef(ClassDef), args: []const Value) Allocator.Error!?EvalResult {
    const class_name = classDefName(class_def);
    const entries = secondaryCtors(self, class_name);
    var chosen: ?root.build.SecondaryCtorEntry = null;
    for (entries) |e| {
        if (e.param_count == args.len) {
            chosen = e;
            break;
        }
    }
    if (chosen == null) {
        for (entries) |e| {
            if (e.param_count > args.len) {
                var all_default = true;
                var idx = args.len;
                while (idx < e.default_arg_thunks.len) : (idx += 1) {
                    if (e.default_arg_thunks[idx] == null) {
                        all_default = false;
                        break;
                    }
                }
                if (all_default) {
                    chosen = e;
                    break;
                }
            }
        }
    }
    const entry = chosen orelse return null;

    // Materialize the full positional argument list, filling trailing
    // params the caller omitted from their default thunks.
    var full_args: std.ArrayList(Value) = .empty;
    defer full_args.deinit(allocator);
    try full_args.appendSlice(allocator, args);
    {
        var idx = args.len;
        while (idx < entry.param_count) : (idx += 1) {
            if (idx >= entry.default_arg_thunks.len or entry.default_arg_thunks[idx] == null) {
                return EvalResult{ .err = try typeErr(allocator, "secondary ctor param {d} has no default to apply", .{idx}) };
            }
            const dfid = entry.default_arg_thunks[idx].?;
            const fr = try funcAt(self, dfid, "secondary ctor default");
            switch (fr) {
                .err => |e| return EvalResult{ .err = e },
                .ok => |func| {
                    var thunk_args: std.ArrayList(Value) = .empty;
                    defer thunk_args.deinit(allocator);
                    try thunk_args.appendSlice(allocator, full_args.items);
                    while (thunk_args.items.len < entry.param_count) {
                        try thunk_args.append(allocator, .Null);
                    }
                    switch (try evalThunk(self, func, thunk_args.items)) {
                        .ok => |v| try full_args.append(allocator, v),
                        .err => |e| return EvalResult{ .err = e },
                    }
                },
            }
        }
    }

    // Evaluate the delegation args.
    var target_args: std.ArrayList(Value) = .empty;
    defer target_args.deinit(allocator);
    for (entry.delegation_arg_thunks) |fid| {
        const fr = try funcAt(self, fid, "secondary ctor arg");
        switch (fr) {
            .err => |e| return EvalResult{ .err = e },
            .ok => |func| {
                switch (try evalThunk(self, func, full_args.items)) {
                    .ok => |v| try target_args.append(allocator, v),
                    .err => |e| return EvalResult{ .err = e },
                }
            },
        }
    }

    var inst_v: Value = undefined;
    if (entry.is_super) {
        switch (try superDelegation(self, allocator, class, class_def, target_args.items)) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    } else if (entry.is_this) {
        switch (try newInstance(self, allocator, class, target_args.items)) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    } else {
        // Implicit `super()`.
        ctorGuardPush(class_name);
        const shell = try newInstance(self, allocator, class, &.{});
        ctorGuardPop();
        switch (shell) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    }

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
fn superDelegation(self: *VmHost, allocator: Allocator, class: ClassId, class_def: ObjRef(ClassDef), target_args: []const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    // Resolve the parent def: prefer the resolved `parent`, else the
    // first supertype name.
    var parent_def: ?ObjRef(ClassDef) = null;
    {
        const dg = class_def.borrow();
        const pg = dg.get().parent.borrow();
        if (pg.get().*) |p| parent_def = p.clone();
        pg.deinit();
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
        ctorGuardPush(class_name);
        const leaf_res = try newInstance(self, allocator, class, &.{});
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
            while (k < pp.len and k < target_args.len) : (k += 1) {
                if (pp[k].property != null) {
                    retainField(inst, allocator, pp[k].name);
                    try pushField(inst, allocator, pp[k].name, target_args[k]);
                }
            }
            pg.deinit();
            g.deinit();
        }
        switch (try runSuperCtorChain(self, &leaf, pname, target_args)) {
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
    const leaf_res = try newInstance(self, allocator, class, &.{});
    const leaf = switch (leaf_res) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (leaf == .Instance) {
        try bindThrowableArgs(self, leaf.Instance, target_args, false);
    }
    return .{ .ok = leaf };
}

fn isBuiltinThrowableNameNoCancel(name: []const u8) bool {
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

fn primaryCtorPath(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, args_in: []const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    const n_primary = classDefPrimaryParamCount(class_def);

    var effective: std.ArrayList(Value) = .empty;
    defer effective.deinit(allocator);
    try effective.appendSlice(allocator, args_in);

    // Pack trailing positional args into the primary ctor's vararg slot.
    {
        const owned = try allocator.dupe(Value, effective.items);
        const packed_args = try packPrimaryCtorVarargs(self, class_name, owned);
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
                    if (overloadScoreArg(self, &ty, &a) == null) {
                        ctor_unsatisfiable = true;
                        break;
                    }
                }
            }
        }
        if (ctor_unsatisfiable) {
            if (try pickFactory(self, allocator, class_name, effective.items, true)) |fid| {
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                const mg = module_ref.borrow();
                defer mg.deinit();
                var iface = self.hostInterface();
                return iface.callFunc(allocator, mg.get(), fid, effective.items);
            }
        }
    }

    // Fill omitted trailing params from default thunks.
    if (effective.items.len < n_primary) {
        const default_thunks = primaryDefaultThunks(self, class_name);
        var idx = effective.items.len;
        while (idx < n_primary) : (idx += 1) {
            var dflt_expr: ?*const ast.Expr = null;
            {
                const dg = class_def.borrow();
                defer dg.deinit();
                if (idx < dg.get().primary_params.len) dflt_expr = dg.get().primary_params[idx].default;
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
                                    try thunk_args.append(allocator, .Null); // `this`
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
        if (try pickFactory(self, allocator, class_name, effective.items, false)) |fid| {
            const module_ref = self.module.clone();
            defer module_ref.deinit();
            const mg = module_ref.borrow();
            defer mg.deinit();
            var iface = self.hostInterface();
            return iface.callFunc(allocator, mg.get(), fid, effective.items);
        }
        return .{ .err = try typeErr(allocator, "{s}() expects {d} args, got {d}", .{ class_name, n_primary, effective.items.len }) };
    }

    return materializeInstance(self, allocator, class_def, ir_name, effective.items);
}

/// Among same-named factory overloads pick the best fit. `clean_only`
/// requires every supplied arg to cleanly type-match (used by the
/// ctor-unsatisfiable path); otherwise any arity-applicable factory.
fn pickFactory(self: *VmHost, allocator: Allocator, class_name: []const u8, args: []const Value, clean_only: bool) Allocator.Error!?FuncId {
    _ = allocator;
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const m = mg.get();
    const provided = args.len;
    var best_fid: ?FuncId = null;
    var best_score: i32 = std.math.minInt(i32);
    for (m.funcsBySimpleName(class_name)) |fid| {
        if (fid.int() >= m.funcs.items.len) continue;
        const f = &m.funcs.items[fid.int()];
        if (f.blocks.len == 0) continue;
        if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        const vararg = f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
        if (clean_only) {
            const arity_ok = f.params.len == provided or vararg;
            if (!arity_ok) continue;
            var score: i32 = 0;
            var clean = true;
            for (args, 0..) |a, i| {
                if (i < f.params.len) {
                    if (overloadScoreArg(self, &f.params[i].ty, &a)) |s| {
                        score += s;
                    } else {
                        clean = false;
                        break;
                    }
                }
            }
            if (clean and (best_fid == null or score > best_score)) {
                best_fid = fid;
                best_score = score;
            }
        } else {
            const arity_ok = f.params.len == provided or vararg;
            if (arity_ok) return fid;
        }
    }
    return best_fid;
}

fn materializeInstance(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    const identity = nextInstanceId(self);

    // Build the parent ctor-arg chain top-down.
    var chain: std.ArrayList(ChainEntry) = .empty;
    defer {
        for (chain.items) |c| allocator.free(c.args);
        chain.deinit(allocator);
    }
    {
        const owned = try allocator.dupe(Value, args);
        try chain.append(allocator, .{ .name = ir_name, .args = owned });
    }
    var cur_class = ir_name;
    var cur_args: []const Value = args;

    var throwable_message: ?Value = null;
    var throwable_cause: ?Value = null;

    // Direct-parent Throwable message/cause recovery.
    {
        const cur_def = classDefByName(self, cur_class);
        defer if (cur_def) |d| d.deinit();
        var parent_name: ?[]const u8 = null;
        if (cur_def) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            for (dg.get().supertype_names) |n| {
                const sd = classDefByName(self, n);
                const is_iface = if (sd) |s| classDefIsInterface(s) else false;
                if (sd) |s| s.deinit();
                if (!is_iface) {
                    parent_name = n;
                    break;
                }
            }
        }
        if (parent_name) |pname| {
            if (isThrowableDirectName(pname)) {
                if (parentCtorArgThunks(self, cur_class)) |thunks| {
                    for (thunks, 0..) |fid, idx| {
                        const fr = try funcAt(self, fid, "parent ctor arg");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                switch (try evalThunk(self, func, cur_args)) {
                                    .ok => |v| {
                                        if (idx == 0) throwable_message = v else if (idx == 1) throwable_cause = v;
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
    while (parentCtorArgThunks(self, cur_class)) |thunks| {
        const cur_def = classDefByName(self, cur_class);
        var parent_name: ?[]const u8 = null;
        if (cur_def) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |n| {
                const sd = classDefByName(self, n);
                const is_iface = if (sd) |s| classDefIsInterface(s) else false;
                if (sd) |s| s.deinit();
                if (!is_iface) {
                    parent_name = n;
                    break;
                }
            }
            dg.deinit();
            d.deinit();
        }
        const pname = parent_name orelse break;

        // Evaluate this level's super-args.
        var parent_args: std.ArrayList(Value) = .empty;
        for (thunks) |fid| {
            const fr = try funcAt(self, fid, "parent ctor arg");
            switch (fr) {
                .err => |e| {
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
                .ok => |func| {
                    switch (try evalThunk(self, func, cur_args)) {
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
            if (throwable_message == null and parent_args.items.len > 0) throwable_message = parent_args.items[0];
            if (throwable_cause == null and parent_args.items.len > 1) throwable_cause = parent_args.items[1];
            parent_args.deinit(allocator);
            break;
        }
        if (std.mem.eql(u8, pname, cur_class)) {
            parent_args.deinit(allocator);
            break;
        }
        const parent_def = classDefByName(self, pname);
        const parent_is_iface = if (parent_def) |d| classDefIsInterface(d) else true;
        if (parent_def) |d| d.deinit();
        if (parent_def == null or parent_is_iface) {
            parent_args.deinit(allocator);
            break;
        }
        // Pack the delegation args for the parent's vararg primary param.
        const packed_parent = try packPrimaryCtorVarargs(self, pname, try parent_args.toOwnedSlice(allocator));
        try chain.append(allocator, .{ .name = pname, .args = try allocator.dupe(Value, packed_parent) });
        cur_class = pname;
        cur_args = packed_parent;
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
            var cls_def = classDefByName(self, cls_name);
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
                        var fv = cls_args[k];
                        if (pp[k].declared_type != null and std.mem.eql(u8, pp[k].declared_type.?, "Long") and fv == .Int) {
                            const n: i64 = fv.Int;
                            fv = .{ .Long = n };
                        }
                        retainFieldList(&fields, allocator, pp[k].name);
                        try fields.append(allocator, .{ .name = pp[k].name, .value = fv });
                    }
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
            const pg = g.get().parent.borrow();
            const next: ?ObjRef(ClassDef) = if (pg.get().*) |p| p.clone() else null;
            pg.deinit();
            g.deinit();
            c.deinit();
            cur = next;
        }
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
                const g = inst.borrowMut();
                g.get().outer = o;
                g.deinit();
            }
        }
    }
    // Inner-class outer hint.
    if (classDefIsInner(class_def)) {
        const has_outer = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().outer != null;
        };
        if (!has_outer) {
            if (innerOuterHintLast()) |hint| {
                const g = inst.borrowMut();
                g.get().outer = hint;
                g.deinit();
            }
        }
    }

    // Publish object / companion singletons before init runs.
    if (classDefIsObject(class_def)) {
        const g = self.globals.borrowMut();
        g.get().define(class_name, inst_value) catch {};
        g.deinit();
    }

    // Evaluate class-delegation expressions.
    {
        const delegates = classDelegateThunks(self, class_name);
        for (delegates) |sf| {
            const fr = try funcAt(self, sf.func, "class delegate");
            switch (fr) {
                .err => {},
                .ok => |func| {
                    switch (try evalThunk(self, func, args)) {
                        .ok => |v| {
                            const key = try std.fmt.allocPrint(allocator, "__delegate__{s}", .{sf.name});
                            const g = inst.borrowMut();
                            try g.get().fields.append(allocator, .{ .name = key, .value = v });
                            g.deinit();
                        },
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
    }
    if (throwable_message) |m| {
        const g = inst.borrowMut();
        try g.get().fields.append(allocator, .{ .name = "message", .value = m });
        g.deinit();
    }
    if (throwable_cause) |c| {
        const g = inst.borrowMut();
        try g.get().fields.append(allocator, .{ .name = "cause", .value = c });
        g.deinit();
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
            const pg = g.get().parent.borrow();
            const next: ?ObjRef(ClassDef) = if (pg.get().*) |p| p.clone() else null;
            pg.deinit();
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
            const body_len = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().body_properties.len;
            };
            const cls_args: []const Value = blk: {
                for (chain.items) |c| {
                    if (std.mem.eql(u8, c.name, cls_name)) break :blk c.args;
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
                if (bodyPropInit(self, cls_name, prop_name)) |fid| {
                    const fr = try funcAt(self, fid, "body prop init");
                    switch (fr) {
                        .err => |e| return .{ .err = e },
                        .ok => |func| {
                            var all: std.ArrayList(Value) = .empty;
                            defer all.deinit(allocator);
                            try all.append(allocator, inst_value);
                            try all.appendSlice(allocator, cls_args);
                            var v = switch (try evalThunk(self, func, all.items)) {
                                .ok => |rv| rv,
                                .err => |e| return .{ .err = e },
                            };
                            v = try maybeProvideDelegate(self, allocator, cls_name, prop_name, &inst_value, v);
                            const g = inst.borrowMut();
                            try g.get().define(allocator, prop_name, v);
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
                        const v = (try simpleLiteral(allocator, ie)) orelse Value.Null;
                        const g = inst.borrowMut();
                        try g.get().define(allocator, prop_name, v);
                        g.deinit();
                    } else {
                        const skip = blk: {
                            const g = cls.borrow();
                            defer g.deinit();
                            const bp = g.get().body_properties[prop_idx];
                            break :blk bp.getter != null or bp.delegate != null;
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
        }
    }

    return .{ .ok = inst_value };
}

/// `provideDelegate` hook for a delegated body property.
fn maybeProvideDelegate(self: *VmHost, allocator: Allocator, cls_name: []const u8, prop_name: []const u8, inst_value: *const Value, v: Value) Allocator.Error!Value {
    if (v != .Instance) return v;
    const is_delegated = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().registry.delegated_body_props.contains(.{ .a = cls_name, .b = prop_name });
    };
    if (!is_delegated) return v;
    const dcls_name = blk: {
        const g = v.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const has_provide = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        for (m.classes.items) |*c| {
            if (!std.mem.eql(u8, c.name, dcls_name)) continue;
            for (c.methods) |fid| {
                if (fid.int() < m.funcs.items.len and std.mem.eql(u8, m.funcs.items[fid.int()].name, "provideDelegate")) {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };
    if (!has_provide) return v;
    const prop_ref = Value{ .PropertyRef = .{ .name = try ObjRef([]const u8).init(allocator, try allocator.dupe(u8, prop_name)) } };
    var iface = self.hostInterface();
    switch (try iface.callMember(allocator, &v, "provideDelegate", &.{ inst_value.*, prop_ref })) {
        .ok => |rep| return rep,
        .err => return v,
    }
}

fn retainFieldList(fields: *std.ArrayList(InstanceData.Field), allocator: Allocator, key: []const u8) void {
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

fn isThrowableDirectName(name: []const u8) bool {
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

fn isThrowableChainName(name: []const u8) bool {
    if (isBuiltinThrowableNameNoCancel(name)) return true;
    return std.mem.eql(u8, name, "CancellationException");
}

// -------------------------------------------------------------------------
// `build_object` lives in `host_classes.rs`; the vtable routes it here.
// -------------------------------------------------------------------------

/// `(class, member)` key for `anon_methods`, unit-separated. Must match
/// `run.zig`/`host_fields.zig`/`host_call_member.zig`.
fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

fn buildCapturePairs(allocator: Allocator, captured_names: []const []const u8, captures: []const Value) Allocator.Error![]NameValue {
    const n = @min(captured_names.len, captures.len);
    var pairs = try allocator.alloc(NameValue, n);
    for (0..n) |i| pairs[i] = .{ .name = captured_names[i], .value = captures[i] };
    return pairs;
}

fn findCapture(pairs: []const NameValue, name: []const u8) ?Value {
    for (pairs) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

/// Synthesize a body-less 0-arg getter/init thunk `Function` from an
/// accessor or expression body so it can be lowered as an anon method.
fn synthThunk(name: ast.Ident, body: ast.FunctionBody, return_type: ?ast.TypeRef, is_override: bool) ast.Function {
    return .{
        .name = name,
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = return_type,
        .body = body,
        .is_open = false,
        .is_override = is_override,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = name.span,
    };
}

pub fn buildObject(self: *VmHost, allocator: Allocator, expr: *const ast.Expr, captured_names: []const []const u8, captures: []const Value) Allocator.Error!EvalResult {
    if (expr.* != .ObjectExpr) {
        return .{ .err = try typeErr(allocator, "Vm::build_object: not an ObjectExpr AST node", .{}) };
    }
    const obj = expr.ObjectExpr;
    const members = obj.members;
    const supertypes = obj.supertypes;
    const supertype_args = obj.supertype_args;

    const capture_pairs = try buildCapturePairs(allocator, captured_names, captures);
    const identity = nextInstanceId(self);
    const synth_class_name = try std.fmt.allocPrint(allocator, "$anon${d}", .{identity});

    // Collect the anon object's own + inherited + enclosing member names so
    // bare identifiers inside method bodies resolve through `this`.
    var own_members = StringSet.init(allocator);
    defer own_members.deinit();
    for (members) |*m| {
        switch (m.*) {
            .Property => |*p| try own_members.put(p.name.name, {}),
            .Function => |*f| try own_members.put(f.name.name, {}),
            else => {},
        }
    }
    for (supertypes) |*sup| {
        const pdef = classDefByName(self, sup.name.name) orelse continue;
        defer pdef.deinit();
        const dg = pdef.borrow();
        defer dg.deinit();
        for (dg.get().primary_params) |p| try own_members.put(p.name, {});
        for (dg.get().body_properties) |p| try own_members.put(p.name, {});
        for (dg.get().methods) |me| try own_members.put(me.name, {});
    }
    if (findCapture(capture_pairs, "this")) |tv| {
        if (tv == .Instance) {
            const ig = tv.Instance.borrow();
            defer ig.deinit();
            const cg = ig.get().class.borrow();
            defer cg.deinit();
            for (cg.get().primary_params) |p| try own_members.put(p.name, {});
            for (cg.get().body_properties) |p| try own_members.put(p.name, {});
            for (cg.get().methods) |me| try own_members.put(me.name, {});
        }
    }

    // Names the object closes over that name a top-level *extension* fn
    // must NOT be value-captured; drop them so the body resolves them
    // through the global/member path.
    var anon_cap_set = StringSet.init(allocator);
    for (captured_names) |n| {
        var names_extension = false;
        const mg = self.module.borrow();
        const m = mg.get();
        for (m.funcsBySimpleName(n)) |fid| {
            const i = @intFromEnum(fid);
            if (i < m.funcs.items.len) {
                const f = &m.funcs.items[i];
                if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) {
                    names_extension = true;
                    break;
                }
            }
        }
        mg.deinit();
        if (!names_extension) try anon_cap_set.put(n, {});
    }
    ir.lower.setLowerAnonCaptures(anon_cap_set);
    // `setLowerAnonCaptures` takes ownership; clear it after lowering.

    // Lower each method + getter, and collect complex property-init thunks.
    const ComplexInit = struct { name: []const u8, module: ObjRef(Module), func: FuncId };
    var complex_prop_inits: std.ArrayList(ComplexInit) = .empty;
    for (members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (f.body == null) continue;
                const sub_ref = try ObjRef(Module).init(allocator, Module.default(allocator));
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, f, synth_class_name, &own_members);
                const fid = func.id;
                const tbl = self.anon_methods.borrowMut();
                const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ f.name.name, f.params.len });
                tbl.get().put(try anonKey(allocator, synth_class_name, arity_name), .{ .module = sub_ref, .func = fid, .captures = capture_pairs }) catch {};
                tbl.get().put(try anonKey(allocator, synth_class_name, f.name.name), .{ .module = sub_ref.clone(), .func = fid, .captures = capture_pairs }) catch {};
                tbl.deinit();
            },
            .Property => |*p| {
                if (p.getter) |*getter| {
                    const thunk = synthThunk(p.name, getter.body, getter.return_type, p.is_override);
                    const sub_ref = try ObjRef(Module).init(allocator, Module.default(allocator));
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                    const fid = func.id;
                    const key = try std.fmt.allocPrint(allocator, "$get${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    tbl.get().put(try anonKey(allocator, synth_class_name, key), .{ .module = sub_ref, .func = fid, .captures = capture_pairs }) catch {};
                    tbl.deinit();
                }
                const init_expr = if (p.init) |*e| e else continue;
                const is_bare_path = init_expr.* == .Path and init_expr.Path.segments.len == 1;
                const is_lit = (try simpleLiteral(allocator, init_expr)) != null;
                if (is_lit or is_bare_path) continue;
                const thunk_name: ast.Ident = .{
                    .name = try std.fmt.allocPrint(allocator, "$init${s}", .{p.name.name}),
                    .span = p.name.span,
                };
                const thunk = synthThunk(thunk_name, .{ .Expr = init_expr.* }, null, false);
                const sub_ref = try ObjRef(Module).init(allocator, Module.default(allocator));
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                try complex_prop_inits.append(allocator, .{ .name = p.name.name, .module = sub_ref, .func = func.id });
            },
            else => {},
        }
    }
    ir.lower.setLowerAnonCaptures(null);

    // Body-property defs from the object's own properties.
    var body_props: std.ArrayList(PropertyDef) = .empty;
    for (members) |*m| {
        if (m.* != .Property) continue;
        const p = &m.Property;
        try body_props.append(allocator, .{
            .name = p.name.name,
            .mutable = p.mutable,
            .init = if (p.init) |*e| e else null,
            .getter = if (p.getter) |*g| g else null,
            .setter = if (p.setter) |*s| s else null,
            .delegate = if (p.delegate) |*e| e else null,
            .is_abstract = p.is_abstract,
            .is_lateinit = p.is_lateinit,
            .primitive_zero = build.primitiveZeroFor(p),
        });
    }
    var supertype_names = try allocator.alloc([]const u8, supertypes.len);
    for (supertypes, 0..) |*t, i| supertype_names[i] = t.name.name;

    // First non-interface supertype as resolved parent class.
    var anon_parent: ?ObjRef(ClassDef) = null;
    for (supertype_names) |sn| {
        const def = classDefByName(self, sn) orelse continue;
        const is_iface = blk: {
            const dg = def.borrow();
            defer dg.deinit();
            break :blk dg.get().is_interface;
        };
        if (!is_iface) {
            anon_parent = def;
            break;
        }
        def.deinit();
    }

    const env = try ObjRef(Env).init(allocator, Env.init(allocator));
    const class_def = try ObjRef(ClassDef).init(allocator, .{
        .name = synth_class_name,
        .fqn = synth_class_name,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = try body_props.toOwnedSlice(allocator),
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = supertype_names,
        .parent = try ObjRef(?ObjRef(ClassDef)).init(allocator, anon_parent),
        .interfaces = try ObjRef(std.ArrayList(ObjRef(ClassDef))).init(allocator, .empty),
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = true,
        .secondary_ctors = &.{},
        .enum_entries = try ObjRef(std.ArrayList(ClassDef.EnumEntry)).init(allocator, .empty),
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = try ObjRef(std.ArrayList(ClassDef.NestedClass)).init(allocator, .empty),
        .captured_env = env,
        .supertype_delegates = try ObjRef(std.ArrayList(SupertypeDelegate)).init(allocator, .empty),
        .delegate_forwarders = try ObjRef(std.ArrayList(MethodDef)).init(allocator, .empty),
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });

    // Initialise body-property fields.
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    {
        const cg = class_def.borrow();
        defer cg.deinit();
        for (cg.get().body_properties) |p| {
            var v: Value = .Null;
            if (p.init) |init_expr| {
                if (try simpleLiteral(allocator, init_expr)) |lit| {
                    v = lit;
                } else if (init_expr.* == .Path and init_expr.Path.segments.len == 1) {
                    const nm = init_expr.Path.segments[0].name;
                    if (findCapture(capture_pairs, nm)) |cv| {
                        v = cv;
                    } else if (findCapture(capture_pairs, "this")) |tv| {
                        if (tv == .Instance) {
                            const ig = tv.Instance.borrow();
                            defer ig.deinit();
                            if (ig.get().get(nm)) |fv| v = fv;
                        }
                    }
                }
            } else if (p.primitive_zero) |pz| {
                v = pz;
            }
            try fields.append(allocator, .{ .name = p.name, .value = v });
        }
    }

    // Populate parent primary-param fields from supertype ctor args, and
    // stash each supertype's evaluated ctor args.
    var super_args_by_class = std.StringHashMap([]Value).init(allocator);
    for (supertypes, 0..) |*sup, idx| {
        const arg_exprs = if (idx < supertype_args.len) (supertype_args[idx] orelse continue) else continue;
        var vals = try allocator.alloc(Value, arg_exprs.len);
        for (arg_exprs, 0..) |*ae, ai| {
            vals[ai] = try evalSuperArg(self, allocator, ae, capture_pairs);
        }
        const parent_def = classDefByName(self, sup.name.name);
        if (parent_def) |pdef| {
            defer pdef.deinit();
            const dg = pdef.borrow();
            defer dg.deinit();
            for (dg.get().primary_params, 0..) |param, pi| {
                if (param.property == null) continue;
                if (pi < vals.len) try fields.append(allocator, .{ .name = param.name, .value = vals[pi] });
            }
        }
        try super_args_by_class.put(sup.name.name, vals);
    }

    // Register the anon ClassDef.
    {
        const g = self.classes.borrowMut();
        defer g.deinit();
        try g.get().put(synth_class_name, class_def.clone());
    }

    const outer: ?Value = findCapture(capture_pairs, "this");
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = class_def,
        .fields = fields,
        .outer = outer,
        .identity = identity,
        .native_state = null,
    });
    const inst_value: Value = .{ .Instance = inst.clone() };

    // Run the concrete superclass chain's body-property initializers.
    var parent_chain: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (parent_chain.items) |c| c.deinit();
        parent_chain.deinit(allocator);
    }
    {
        var cur: ?ObjRef(ClassDef) = blk: {
            const ig = inst.borrow();
            defer ig.deinit();
            const cg = ig.get().class.borrow();
            defer cg.deinit();
            const pg = cg.get().parent.borrow();
            defer pg.deinit();
            break :blk if (pg.get().*) |p| p.clone() else null;
        };
        var step: usize = 0;
        while (cur) |c| {
            if (step > 128) {
                c.deinit();
                break;
            }
            step += 1;
            const next = blk: {
                const cg = c.borrow();
                defer cg.deinit();
                const pg = cg.get().parent.borrow();
                defer pg.deinit();
                break :blk if (pg.get().*) |p| p.clone() else null;
            };
            try parent_chain.append(allocator, c);
            cur = next;
        }
    }
    // Bottom-up so a parent's field exists before a nearer ancestor.
    var ci: usize = parent_chain.items.len;
    while (ci > 0) {
        ci -= 1;
        const cls = parent_chain.items[ci];
        const cls_name = blk: {
            const cg = cls.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        };
        const cls_args: []Value = super_args_by_class.get(cls_name) orelse &.{};
        const props = blk: {
            const cg = cls.borrow();
            defer cg.deinit();
            break :blk try allocator.dupe(PropertyDef, cg.get().body_properties);
        };
        for (props) |p| {
            const fid = bodyPropInit(self, cls_name, p.name) orelse continue;
            const mg = self.module.borrow();
            const m = mg.get();
            if (@intFromEnum(fid) >= m.funcs.items.len) {
                mg.deinit();
                continue;
            }
            const func = m.funcs.items[@intFromEnum(fid)];
            mg.deinit();
            var all: std.ArrayList(Value) = .empty;
            try all.append(allocator, inst_value);
            try all.appendSlice(allocator, cls_args);
            var iface = self.hostInterface();
            const module_ref = self.module.clone();
            const r = try ir.eval.evalWith(allocator, module_ref.borrow().get(), &func, all, &iface);
            module_ref.deinit();
            switch (r) {
                .ok => |v| {
                    const already = blk: {
                        const ig = inst.borrow();
                        defer ig.deinit();
                        break :blk ig.get().get(p.name) != null;
                    };
                    if (!already) {
                        const ig = inst.borrowMut();
                        defer ig.deinit();
                        try ig.get().define(allocator, p.name, v);
                    }
                },
                .err => |e| return .{ .err = e },
            }
        }
    }

    // Run the anon object's own complex property inits.
    for (complex_prop_inits.items) |cpi| {
        const mref = cpi.module;
        const i = @intFromEnum(cpi.func);
        const mg = mref.borrow();
        const sub_mod = mg.get();
        if (i >= sub_mod.funcs.items.len) {
            mg.deinit();
            continue;
        }
        const func = sub_mod.funcs.items[i];
        const prev = self.globals.clone();
        if (capture_pairs.len != 0) {
            const scoped = try ObjRef(Env).init(allocator, Env.withParent(allocator, self.globals.clone()));
            const sg = scoped.borrowMut();
            for (capture_pairs) |nv| sg.get().define(nv.name, nv.value) catch {};
            sg.deinit();
            self.globals = scoped;
        }
        var cap_vec: std.ArrayList(Value) = .empty;
        for (func.capture_order) |cn| {
            if (std.mem.eql(u8, cn, "this")) {
                try cap_vec.append(allocator, inst_value);
            } else {
                try cap_vec.append(allocator, findCapture(capture_pairs, cn) orelse .Null);
            }
        }
        var all: std.ArrayList(Value) = .empty;
        try all.append(allocator, inst_value);
        var iface = self.hostInterface();
        const r = try ir.eval.evalWithCaptures(allocator, sub_mod, &func, all, cap_vec, &iface);
        mg.deinit();
        self.globals.deinit();
        self.globals = prev;
        switch (r) {
            .ok => |v| {
                const ig = inst.borrowMut();
                defer ig.deinit();
                try ig.get().define(allocator, cpi.name, v);
            },
            .err => |e| return .{ .err = e },
        }
    }

    return .{ .ok = inst_value };
}

/// Evaluate a supertype ctor-arg expression to a value: literals, then a
/// bare captured name, then a field reached through the captured outer
/// `this`.
fn evalSuperArg(self: *VmHost, allocator: Allocator, expr: *const ast.Expr, capture_pairs: []const NameValue) Allocator.Error!Value {
    _ = self;
    if (try simpleLiteral(allocator, expr)) |v| return v;
    if (expr.* == .Path and expr.Path.segments.len == 1) {
        const nm = expr.Path.segments[0].name;
        if (findCapture(capture_pairs, nm)) |v| return v;
        if (findCapture(capture_pairs, "this")) |tv| {
            if (tv == .Instance) {
                const ig = tv.Instance.borrow();
                defer ig.deinit();
                if (ig.get().get(nm)) |v| return v;
            }
        }
    }
    return .Null;
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}

test "isIntrinsicClass / isBuiltinThrowableName classification" {
    try testing.expect(isIntrinsicClass("kotlin.text.StringBuilder"));
    try testing.expect(isIntrinsicClass("kotlin.Array"));
    try testing.expect(!isIntrinsicClass("com.example.Widget"));
    try testing.expect(isBuiltinThrowableName("CancellationException"));
    try testing.expect(isBuiltinThrowableNameNoCancel("IOException"));
    try testing.expect(!isBuiltinThrowableNameNoCancel("CancellationException"));
}

test "simpleLiteral resolves literal expr forms" {
    const a = testing.allocator;
    const span = @import("span");
    const f = span.FileId.from(0);
    const s = span.Span.init(f, 0, 1);
    var int_expr = ast.Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = s } };
    const iv = (try simpleLiteral(a, &int_expr)).?;
    try testing.expectEqual(@as(i64, 7), iv.asI64().?);
    var bool_expr = ast.Expr{ .BoolLit = .{ .value = true, .span = s } };
    const bv = (try simpleLiteral(a, &bool_expr)).?;
    try testing.expect(bv.Bool);
    var null_expr = ast.Expr{ .NullLit = .{ .span = s } };
    const nv = (try simpleLiteral(a, &null_expr)).?;
    try testing.expect(nv == .Null);
}

test "ctor guard stack push/contains/pop" {
    try testing.expect(!ctorGuardContains("Foo"));
    ctorGuardPush("Foo");
    try testing.expect(ctorGuardContains("Foo"));
    ctorGuardPop();
    try testing.expect(!ctorGuardContains("Foo"));
}
