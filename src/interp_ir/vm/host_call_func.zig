//! `VmHost` top-level / named-function dispatch: resolving and invoking
//! a `FuncId` (with named args, type args, and overload selection) plus
//! the `call_named_overload` probe the IR evaluator uses for bare-name
//! calls.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const trace = @import("trace.zig");
const host_call_member = @import("host_call_member.zig");
const host_globals = @import("host_globals.zig");
const intrinsic_host = @import("intrinsic_host.zig");
const overload_match = @import("overload_match.zig");
const compose = @import("compose.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const InstanceData = runtime.InstanceData;
const RuntimeError = runtime.RuntimeError;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;

const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;
const MaybeValueResult = ir.eval.MaybeValueResult;
const SuspendState = ir.eval.SuspendState;

// -------------------------------------------------------------------------
// Small data-error / args helpers.
// -------------------------------------------------------------------------

fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) EvalError {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "IR type error";
    return .{ .Type = msg };
}

/// Move a slice of `Value`s into a freshly allocated `std.ArrayList`
/// the IR evaluator can take ownership of. The `Value`s themselves are
/// shallow-copied (their `ObjRef` handles stay shared), matching the Vm's
/// `Vec<Value>` hand-off discipline.
fn argsFromSlice(allocator: Allocator, items: []const Value) Allocator.Error!std.ArrayList(Value) {
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, items);
    return out;
}

/// Look up a `Func` by id, returning a borrowed pointer into the module's
/// `funcs` (the module outlives the call). `null` when out of range.
fn funcAt(module: *const Module, id: FuncId) ?*const Func {
    return module.funcById(id);
}

fn paramIsThis(params: []const ir.Param) bool {
    return params.len > 0 and std.mem.eql(u8, params[0].name, "this");
}

fn lastIsVararg(params: []const ir.Param) bool {
    return params.len > 0 and params[params.len - 1].is_vararg;
}

/// A `vararg` parameter that is NOT the last parameter (Kotlin allows a vararg
/// before trailing defaulted / named-only parameters). An all-positional call
/// to such a function cannot be bound by the simple trailing-collapse path
/// (`packVarargArgs`): the vararg must consume the positional args at its own
/// position while the trailing parameters take their defaults. Such calls are
/// routed through the reorder-aware binder in `callFuncNamed`.
fn hasNonFinalVararg(params: []const ir.Param) bool {
    if (params.len == 0) return false;
    for (params[0 .. params.len - 1]) |p| {
        if (p.is_vararg) return true;
    }
    return false;
}

/// `func.params.last()` default thunk lookup for `func`.
fn funcDefaults(self: *VmHost, func: FuncId) ?[]?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().func_defaults.get(func.int());
}

// -------------------------------------------------------------------------
// Vararg packing.
// -------------------------------------------------------------------------

/// The primitive-array kind for a vararg element type, or null for a reference
/// element (which stays a boxed `Array`). Kotlin materializes `vararg Byte` AS
/// a `ByteArray`, so the packed value must carry the primitive kind — otherwise
/// a plain `Array` fails to match a `ByteArray`/`IntArray`/… parameter at a
/// later call (a `fun f(vararg b: Byte) = g(b)` would then miss `g(ByteArray)`).
fn varargPrimKind(elem: []const u8) ?runtime.PrimitiveArrayKind {
    const K = runtime.PrimitiveArrayKind;
    const table = [_]struct { n: []const u8, k: K }{
        .{ .n = "Byte", .k = .Byte },       .{ .n = "Int", .k = .Int },
        .{ .n = "Long", .k = .Long },       .{ .n = "Short", .k = .Short },
        .{ .n = "Double", .k = .Double },   .{ .n = "Float", .k = .Float },
        .{ .n = "Boolean", .k = .Boolean }, .{ .n = "Char", .k = .Char },
        .{ .n = "UByte", .k = .UByte },     .{ .n = "UInt", .k = .UInt },
        .{ .n = "ULong", .k = .ULong },     .{ .n = "UShort", .k = .UShort },
    };
    for (table) |e| {
        if (std.mem.eql(u8, elem, e.n)) return e.k;
    }
    return null;
}

/// Build the packed vararg value from an owned list of element values: a
/// primitive `ByteArray`/`IntArray`/… when `elem_ty` is a primitive, else a
/// boxed `Array`. Mirrors `collections.makeArrayFromArrayList`'s ownership.
fn packVarargArray(allocator: Allocator, elem_ty: []const u8, list: std.ArrayList(Value)) Allocator.Error!Value {
    if (varargPrimKind(elem_ty)) |k| {
        var l = list;
        const v = try runtime.ArrayData.initPacked(allocator, k, l.items);
        if (runtime.reclaimEnabled()) for (l.items) |e| e.release(allocator);
        l.deinit(allocator);
        return v;
    }
    return runtime.ArrayData.fromBoxedList(try ValueList.init(allocator, list));
}

/// Collapse the trailing positional args of a vararg call into a single
/// `Array` slot. Consumes `args` (an owned `ArrayList`), returning the
/// packed list. A `f(*arr)` spread (a lone `Array` already in the slot)
/// passes through untouched.
fn packVarargArgs(allocator: Allocator, func: *const Func, args: *std.ArrayList(Value)) Allocator.Error!std.ArrayList(Value) {
    const n_params = func.params.len;
    // The vararg may sit before trailing fixed params (Kotlin allows it;
    // `remember(vararg keys, calculation)` — and the compose plugin appends
    // `$composer`/`$changed` after that). The vararg absorbs the middle
    // positional args, leaving exactly the trailing fixed params' worth at
    // the end.
    var vararg_pos: ?usize = null;
    for (func.params, 0..) |p, i| {
        if (p.is_vararg) {
            vararg_pos = i;
            break;
        }
    }
    const vp = vararg_pos orelse return args.*;
    const tail_fixed = n_params - vp - 1;
    // Already packed: an Array sits at the vararg slot of a slot-exact list.
    if (args.items.len == n_params and args.items[vp] == .Array) {
        return args.*;
    }
    // Underfilled before the trailing fixed params: leave for the defaults
    // machinery (only reachable through named/defaulted shapes).
    if (tail_fixed != 0 and args.items.len < vp + tail_fixed) return args.*;
    const n_var = if (args.items.len > vp + tail_fixed) args.items.len - vp - tail_fixed else 0;
    var out: std.ArrayList(Value) = .empty;
    try out.ensureTotalCapacity(allocator, n_params);
    var i: usize = 0;
    while (i < vp and i < args.items.len) : (i += 1) {
        out.appendAssumeCapacity(args.items[i]);
    }
    var rest: std.ArrayList(Value) = .empty;
    var j: usize = vp;
    while (j < vp + n_var and j < args.items.len) : (j += 1) {
        try rest.append(allocator, args.items[j]);
    }
    const velem = func.params[vp].ty.name;
    try out.append(allocator, try packVarargArray(allocator, velem, rest));
    j = vp + n_var;
    while (j < args.items.len) : (j += 1) {
        try out.append(allocator, args.items[j]);
    }
    args.deinit(allocator);
    return out;
}

// -------------------------------------------------------------------------
// Intrinsic resolution + dispatch.
// -------------------------------------------------------------------------

/// Look up an intrinsic by FQN. Probes the pack-supplied
/// `installed_bindings` overlay first so a loaded pack's binding shadows
/// the stdlib's default implementation.
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

/// See the call site in `callFuncTypedInner`: retag a List of Ints IN
/// PLACE to Short/Byte when the declared parameter is an iterable of
/// that narrow kind and every element fits. The literal-typed list is
/// the only way such a value reaches the param under Kotlin's static
/// typing, so the retag is faithful.
fn narrowIntListArg(param_ty: *const TypeRef, arg: *const Value) void {
    if (arg.* != .List) return;
    const pn = param_ty.name;
    const iterable_like = std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "Collection") or
        std.mem.eql(u8, pn, "List") or std.mem.eql(u8, pn, "MutableList") or std.mem.eql(u8, pn, "Set");
    if (!iterable_like or param_ty.args.len != 1) return;
    const en = param_ty.args[0].name;
    const to_short = std.mem.eql(u8, en, "Short");
    const to_byte = std.mem.eql(u8, en, "Byte");
    if (!to_short and !to_byte) return;
    const g = arg.List.items.borrowMut();
    defer g.deinit();
    for (g.get().items) |*v| {
        if (v.* != .Int) return;
        const x = v.Int;
        if (to_short and (x < std.math.minInt(i16) or x > std.math.maxInt(i16))) return;
        if (to_byte and (x < std.math.minInt(i8) or x > std.math.maxInt(i8))) return;
    }
    for (g.get().items) |*v| {
        const x = v.Int;
        v.* = if (to_short) .{ .Short = @intCast(x) } else .{ .Byte = @intCast(x) };
    }
}

/// Synthetic `KType` instance for a reified type name: `classifier` is the
/// registered class when one exists (else a minimal KClass), `arguments` is
/// the empty list, `isMarkedNullable` mirrors a trailing `?`.
fn makeKTypeValue(self: *VmHost, allocator: Allocator, type_name: []const u8) Allocator.Error!Value {
    const nullable = std.mem.endsWith(u8, type_name, "?");
    const base = if (nullable) type_name[0 .. type_name.len - 1] else type_name;
    const classifier: Value = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(base)) |c| break :blk Value{ .Class = c.clone() };
        break :blk try host_call_member.syntheticClassFromFqn(allocator, base);
    };
    const empty_args: Value = .{ .List = .{
        .items = try ValueList.init(allocator, .empty),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    } };
    var view = VmIntrinsicHost.borrowed(vmhost.SharedHandles.fromHost(self));
    const id = intrinsic_host.allocInstanceId(&view);
    const fields = [_]InstanceData.Field{
        .{ .name = "classifier", .value = classifier },
        .{ .name = "arguments", .value = empty_args },
        .{ .name = "isMarkedNullable", .value = .{ .Bool = nullable } },
    };
    return intrinsic_host.newSynthInstance(&view, "kotlin.reflect.KType", id, &fields);
}

/// Build a `VmIntrinsicHost` mirroring `dispatch_intrinsic`'s, drive the
/// intrinsic through a `CallCtx`, and convert any `RuntimeError` back into
/// the IR evaluator's `EvalError` data path.
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(allocator, "intrinsic_call_func", fqn, null, null, args);
    var intrinsic = VmIntrinsicHost{
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
        intrinsic.module.deinit();
        intrinsic.closures.deinit();
        intrinsic.globals.deinit();
        intrinsic.classes.deinit();
        intrinsic.prog.deinit();
        intrinsic.anon_methods.deinit();
        intrinsic.class_default_outer.deinit();
        intrinsic.instance_id_counter.deinit();
        intrinsic.out_sink.deinit();
        intrinsic.threads.deinit();
        intrinsic.object_states.deinit();
        intrinsic.singletons_by_id.deinit();
    }
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = allocator,
    };
    const prev_fqn_lt = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn_lt;
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = runtimeErrorToEval(allocator, e) },
    };
}

/// Map a `runtime.RuntimeError` raised by an intrinsic into the IR
/// evaluator's `EvalError`, preserving thrown values and control flow.
fn runtimeErrorToEval(allocator: Allocator, e: RuntimeError) EvalError {
    return switch (e) {
        // Preserve the thrown Value so the IR evaluator's try/catch can
        // match the handler against the exception class.
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        // A suspending primitive (`delay` / `yield`) asked to park. Seed a
        // fresh SuspendState; each enclosing `eval` frame snapshots itself
        // as it unwinds, and the coroutine driver parks the result.
        .Suspend => |wake| blk: {
            const st = allocator.create(SuspendState) catch break :blk EvalError{ .Type = "out of memory seeding suspend" };
            st.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
            break :blk EvalError{ .Suspended = st };
        },
        .Unbound => |s| .{ .Unbound = s },
        .Type => |s| .{ .Type = s },
        .Arity => |s| .{ .Arity = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .CalleeFailed => |s| .{ .CalleeFailed = s },
        // A labeled return crossing a host intrinsic (`synchronized`'s
        // block invoked through `invokeCallable`) keeps unwinding to its
        // target frame — flattening it to a Type error stranded
        // `return@fn` from inside kotlinx's synchronized blocks.
        .LabeledReturn => |lr| .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } },
        else => typeErr(allocator, "{s}", .{@tagName(e)}),
    };
}

// -------------------------------------------------------------------------
// Link-time resolved executable form (one form per symbol).
// -------------------------------------------------------------------------

/// The single executable native form bound to `func` at link time, or
/// `null` when the symbol's form is its lowered body. This replaces the
/// per-call `installed_bindings.resolve(func.fqn)` short-circuit that
/// `callFunc`/`callValue` used to run on every dispatch: the form is now
/// settled once by `ProgramImage.linkResolvedForms` and consulted here by
/// `FuncId` against the resolved table.
pub fn resolvedNativeForm(self: *VmHost, func: FuncId) ?StdlibFn {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().resolvedNativeForm(func);
}

/// Whether `func` can actually run: it has a lowered body, or the link
/// settled an executable form for it (native binding, same-FQN host
/// intrinsic, or a body-sibling redirect at this arity). An unsettled
/// header is not executable — a by-name walk that selects one re-enters
/// `callFunc`'s bodyless ladder and cycles.
pub fn executableForm(self: *VmHost, module: *const Module, func: FuncId, argc: usize) bool {
    const f = funcAt(module, func) orelse return false;
    if (f.hasBody()) return true;
    if (resolvedNativeForm(self, func) != null) return true;
    if (lookupIntrinsic(self, f.fqn) != null) return true;
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().resolvedRedirectTarget(module, func, argc) != null;
}

/// Whether a deferred bare call that missed every dispatch arm names a
/// declared-but-unsettled header (an `expect` whose platform `actual` is
/// outside the compiled source set, e.g. ktor's
/// `HttpClient.platformResponseDefaultTransformers`). Such a call is a
/// no-op returning Unit — the shape the manufactured empty bodies
/// produced before header-only declarations stayed bodyless — instead of
/// an unresolved-global error. Consulted only at the very end of the
/// deferred-call ladder, so any real serving wins first.
pub fn bareUnsettledHeaderNoOp(self: *VmHost, module: *const Module, name: []const u8, argc: usize) bool {
    for (module.funcsBySimpleName(name)) |fid| {
        const f = funcAt(module, fid) orelse continue;
        if (f.hasBody()) continue;
        const receiver_formed = paramIsThis(f.params);
        const want = if (receiver_formed) argc + 1 else argc;
        if (f.params.len < want) continue;
        if (executableForm(self, module, fid, want)) continue;
        if (trace.enabled(name)) {
            trace.emit("map=bare_unsettled_noop name={s} fqn={s}", .{ name, f.fqn });
        }
        return true;
    }
    return false;
}

/// The prefix sequence the DELETED `callFunc` bodyless ladder probed, in
/// its exact order. This list intentionally differs from
/// `ProgramImage.bare_probe_packages` (the deleted `lookupGlobal` ladder's
/// order, which the link-time map unified onto): io/math, text/collections
/// and ranges/comparisons are transposed between the two. The audit
/// re-derives THIS order independently so a future binding registered
/// under two of the transposed packages — where the unified map's pick
/// would diverge from the deleted dispatch — is flagged, not silently
/// absorbed.
const deleted_bodyless_prefixes = [_][]const u8{
    "kotlin.",
    "kotlin.io.",
    "kotlin.math.",
    "kotlin.text.",
    "kotlin.collections.",
    "kotlin.ranges.",
    "kotlin.comparisons.",
    "kotlin.concurrent.",
    "kotlin.coroutines.",
    "kotlin.coroutines.intrinsics.",
    "kotlin.internal.",
};

/// Overlay-then-embedded probe for one FQN — the deleted ladder's
/// `lookupIntrinsic` rung, re-derived here so the audit never consults
/// the link-built tables it is checking.
fn auditIntrinsicProbe(self: *VmHost, fqn: []const u8) ?StdlibFn {
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |i| return i;
    }
    return stdlib.implementation(fqn);
}

/// Opt-in audit (`KLIO_LINK_AUDIT`): re-derive what the DELETED per-call
/// dispatch would have done for `func` and assert the link-settled tables
/// agree. For a body-bearing func that is the
/// `installed_bindings.resolve(fqn)` short-circuit. For a bodyless decl
/// the deleted ladder ran, in order: the per-call same-simple-name
/// body-sibling scan (first arity-fitting candidate), the declared FQN
/// against the overlay then the embedded registry, then the
/// `deleted_bodyless_prefixes` probes — re-computed here from the raw
/// sources (never from `resolved_redirect` / `default_import_globals`,
/// which are the tables under audit), so a divergence between the deleted
/// algorithm and the link-time replacement is detectable. Logs every
/// divergence; a clean corpus run proves zero.
pub fn linkAuditCheck(self: *VmHost, module: *const Module, func: FuncId, f: *const ir.Func, args_in: []const Value) void {
    if (!linkAuditOn()) return;
    if (f.hasBody()) {
        const per_call: ?StdlibFn = blk: {
            const g = self.prog.borrow();
            defer g.deinit();
            const bg = g.get().installed_bindings.borrow();
            defer bg.deinit();
            break :blk bg.get().resolve(f.fqn);
        };
        const linked = resolvedNativeForm(self, func);
        if (per_call != linked) {
            std.debug.print(
                "[KLIO_LINK_AUDIT] divergence: fid={d} fqn={s} per_call={s} linked={s}\n",
                .{ func.int(), f.fqn, if (per_call != null) "native" else "body", if (linked != null) "native" else "body" },
            );
        }
        return;
    }

    // Deleted rung 1: per-call sibling scan, first body-bearing
    // arity-fitting same-simple-name candidate.
    const per_call_sibling: ?FuncId = blk: {
        for (module.funcsBySimpleName(f.name)) |cand| {
            if (cand.int() == func.int()) continue;
            const g = funcAt(module, cand) orelse continue;
            if (!g.hasBody()) continue;
            const g_user = if (paramIsThis(g.params)) g.params.len - 1 else g.params.len;
            if (g_user != args_in.len and !lastIsVararg(g.params)) continue;
            break :blk cand;
        }
        break :blk null;
    };
    // The replacement's pick: exactly what dispatch consults.
    const linked_sibling: ?FuncId = blk: {
        const g = self.prog.borrow();
        defer g.deinit();
        break :blk g.get().resolvedRedirectTarget(module, func, args_in.len);
    };
    if ((per_call_sibling == null) != (linked_sibling == null) or
        (per_call_sibling != null and per_call_sibling.?.int() != linked_sibling.?.int()))
    {
        std.debug.print(
            "[KLIO_LINK_AUDIT] divergence: fid={d} fqn={s} sibling per_call={?} linked={?}\n",
            .{ func.int(), f.fqn, per_call_sibling, linked_sibling },
        );
    }
    if (per_call_sibling != null) return;

    // Deleted rungs 2+3: declared FQN, then the old prefix sequence.
    const per_call_native: ?StdlibFn = blk: {
        if (auditIntrinsicProbe(self, f.fqn)) |i| break :blk i;
        var buf: [128]u8 = undefined;
        for (deleted_bodyless_prefixes) |pfx| {
            if (pfx.len + f.name.len > buf.len) continue;
            const probe = std.fmt.bufPrint(&buf, "{s}{s}", .{ pfx, f.name }) catch continue;
            if (auditIntrinsicProbe(self, probe)) |i| break :blk i;
        }
        break :blk null;
    };
    const linked_native = resolvedNativeForm(self, func);
    if (per_call_native != linked_native) {
        std.debug.print(
            "[KLIO_LINK_AUDIT] divergence: fid={d} fqn={s} per_call={s} linked={s}\n",
            .{ func.int(), f.fqn, if (per_call_native != null) "native" else "body", if (linked_native != null) "native" else "body" },
        );
    }
}

var link_audit_checked: bool = false;
var link_audit_enabled: bool = false;

fn linkAuditOn() bool {
    if (!link_audit_checked) {
        link_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_LINK_AUDIT") catch null) |v| {
            a.free(v);
            link_audit_enabled = true;
        }
    }
    return link_audit_enabled;
}

// -------------------------------------------------------------------------
// Overload scoring + selection.
// -------------------------------------------------------------------------

fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// Score an arg/param compatibility for overload resolution. Higher is
/// better; `null` disqualifies the candidate.
fn overloadScoreArg(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) ?i32 {
    const nm = param_ty.name;
    // Runtime type-simple-name of the argument.
    var inst_name_buf: ?[]const u8 = null;
    const v_ty: []const u8 = switch (arg.*) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            inst_name_buf = cg.get().name;
            break :blk cg.get().name;
        },
        else => blk: {
            const fqn = arg.typeFqn();
            break :blk simpleName(fqn);
        },
    };

    // A dotted nested param type whose class lifted under a mangled key
    // (`Modifier.Node` when several `Node`s exist) compares by that key, so
    // it matches the argument's registered class name exactly.
    const nm_mangled = host_call_member.mangledClassKeyOf(self, nm);
    if (std.mem.eql(u8, nm, v_ty) or
        (nm_mangled != null and std.mem.eql(u8, nm_mangled.?, v_ty)))
    {
        const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
        return 100 + d;
    }
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.* == .Null and param_ty.nullable) return 50;

    // Numeric widening: Int → Long, Int → Double, Long → Double.
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;
    // Float values are stored Double-tagged (and vice versa after arithmetic):
    // the two float widths are one value domain at runtime, so either width's
    // parameter accepts either tag — `Density(density = 1f)` must bind the
    // `density: Float` factory when the value arrives as a Double.
    if ((std.mem.eql(u8, nm, "Float") and std.mem.eql(u8, v_ty, "Double")) or
        (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Float"))) return 60;

    // A callable argument against a function-typed parameter. A `::name`
    // member reference loads as a `.Function`; a constructor reference loads
    // as a `.Class`. Both must score by arity against a `FunctionN` param.
    const arg_arity: ?usize = switch (arg.*) {
        .IrClosure => |c| if (self.closures.get(c.id)) |info| info.n_params else null,
        .Function => |f| f.decl.params.len,
        .Class => 0,
        else => null,
    };
    // A bound callable reference (`recv::method`, `Enum::values`) is a
    // synth `Instance` whose class name is `$bound_ref$<name>`; it is
    // callable, so it satisfies a function-typed parameter even though its
    // typeFqn is a plain `<instance>`.
    const is_bound_ref = arg.* == .Instance and std.mem.startsWith(u8, v_ty, "$bound_ref$");
    const is_callable = arg_arity != null or is_bound_ref or std.mem.startsWith(u8, arg.typeFqn(), "kotlin.Function");
    if (is_callable) {
        // `FunctionN` carries the expected lambda arity.
        if (std.mem.startsWith(u8, nm, "Function")) {
            const expected = nm["Function".len..];
            if (std.fmt.parseInt(usize, expected, 10)) |want| {
                if (arg_arity) |got| {
                    if (got == want or got == want + 1) {
                        const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
                        return 90 + d;
                    }
                    return 20;
                }
                return 20;
            } else |_| {}
        }
        // SAM conversion / receiver-style function types: low, but scored.
        return 8;
    }

    // Subtype: an instance argument whose class transitively extends /
    // implements the parameter's nominal type matches (distance-weighted).
    if (arg.* == .Instance) {
        var queue: std.ArrayList(QItem) = .empty;
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
            const cur_key = host_call_member.mangledClassKeyOf(self, cur.name) orelse cur.name;
            if (host_call_member.classHeadsMatch(self, cur.name, nm)) {
                const d: i32 = if (cur.depth > 50) 50 else cur.depth;
                return 60 - d;
            }
            const cg = self.classes.borrow();
            defer cg.deinit();
            // A dotted supertype ascends through its mangled entry.
            const def_hit = cg.get().get(cur.name) orelse cg.get().get(cur_key);
            if (def_hit) |def_ref| {
                const dg = def_ref.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |sup| {
                    queue.append(self.allocator, .{ .name = sup, .depth = cur.depth + 1 }) catch return null;
                }
            }
        }
    }

    // Builtin runtime types satisfy their nominal supertypes.
    const builtin_supers: []const []const u8 = applicability.builtinSupersOf(v_ty);
    const nm_simple = simpleName(nm);
    for (builtin_supers, 0..) |s, pos| {
        if (std.mem.eql(u8, s, nm) or std.mem.eql(u8, s, nm_simple)) {
            const dist: i32 = if (pos > 20) 20 else @intCast(pos);
            const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
            return 75 - dist + d;
        }
    }

    // Generic single-letter type-parameter — accept any.
    if (nm.len <= 2 and allAsciiUpper(nm)) return 5;
    // Unit param type (no info preserved at lower time) — accept anything
    // but rank lowest.
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    return null;
}

const QItem = struct { name: []const u8, depth: i32 };



/// When the target function shares its name with siblings, pick the best
/// match for the runtime arg types. `null` when there is nothing better.
/// Pack each arg's primitive scalar tag into a 64-bit signature (4 bits/arg,
/// arity in the top byte), or null if any arg is not a primitive scalar (or there
/// are too many). For primitive args the tag fully determines overload selection,
/// so `(module, func, sig)` is a sound key for memoizing `pickOverload`.
fn argSigPrimitive(args: []const Value) ?u64 {
    if (args.len > 12) return null;
    var sig: u64 = @as(u64, args.len) << 56;
    for (args, 0..) |*a, i| {
        const tag: u64 = switch (a.*) {
            .Int => 1,
            .Long => 2,
            .Double => 3,
            .Float => 4,
            .Short => 5,
            .Byte => 6,
            .Char => 7,
            .Bool => 8,
            .UInt => 9,
            .ULong => 10,
            .UShort => 11,
            .UByte => 12,
            else => return null,
        };
        sig |= tag << @intCast(i * 4);
    }
    return sig;
}

fn overloadCacheGet(self: *VmHost, key: root.ProgramImage.OverloadKey) ?FuncId {
    const pg = self.prog.borrow();
    defer pg.deinit();
    if (pg.get().overload_cache.get(key)) |raw| return @enumFromInt(raw);
    return null;
}

fn overloadCachePut(self: *VmHost, key: root.ProgramImage.OverloadKey, fid: FuncId) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().overload_cache.put(key, @intFromEnum(fid)) catch {};
}

/// `pickOverload` with a `(module, func, primitive-arg-signature)` memo, consulted
/// only for all-primitive args (where the result is invariant).
fn pickOverloadCached(self: *VmHost, module: *const Module, func: FuncId, args: []const Value) ?FuncId {
    if (argSigPrimitive(args)) |sig| {
        const key = root.ProgramImage.OverloadKey{ .module_p = @intFromPtr(module), .func_p = func.int(), .sig = sig };
        if (overloadCacheGet(self, key)) |cached| return cached;
        const r = pickOverload(self, module, func, args);
        // Memoize the effective target (base func when no better overload won) so
        // repeat calls skip the candidate scan entirely.
        overloadCachePut(self, key, r orelse func);
        return r;
    }
    return pickOverload(self, module, func, args);
}

/// A closure's SOURCE-level param count: the compose plugin threads
/// composable lambdas before lowering, appending `($composer, $changed)`.
/// Overload selection must rank by the declared header, or the +2 shift
/// binds a `{ d -> }` argument to a 3-param functional overload.
pub fn closureUserParams(self: *VmHost, info: anytype) usize {
    return closureUserParamsChecked(self, info).n;
}

/// As `closureUserParams`, also reporting whether the composer pair was
/// stripped. A stripped count came from the transformed literal's own
/// header, so it is AUTHORITATIVE for overload ranking — without that,
/// `movableContentOf { key: Int -> … }` re-picked at runtime ties the
/// 1-param closure between the `(P) -> Unit` and `() -> Unit` overloads
/// (flat want/want+1 parity) and the first overload wins arbitrarily.
pub fn closureUserParamsChecked(self: *VmHost, info: anytype) struct { n: usize, stripped: bool } {
    var n: usize = info.n_params;
    var stripped = false;
    if (n >= 2) {
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        const module = info.module orelse module_ref.asPtr();
        if (module.funcById(info.body_func)) |bf| {
            const p = bf.params;
            if (p.len >= 2 and std.mem.eql(u8, p[p.len - 1].name, "$changed") and
                std.mem.eql(u8, p[p.len - 2].name, "$composer"))
            {
                n -= 2;
                stripped = true;
            }
        }
    }
    return .{ .n = n, .stripped = stripped };
}

/// A ComposableLambdaImpl argument ranks by its wrapped `_block` closure's
/// source arity: the wrapper's invoke family serves every arity, so the
/// instance itself says nothing — but overload families keyed on the
/// functional param's arity (`movableContentOf`'s five overloads) must
/// still bind exactly, as they do for the raw literal the wrap replaced.
pub fn composableLambdaBlockArity(self: *VmHost, v: *const Value) ?struct { n: u8, authoritative: bool } {
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    {
        const cg = g.get().class.borrow();
        defer cg.deinit();
        if (!std.mem.eql(u8, cg.get().fqn, "androidx.compose.runtime.internal.ComposableLambdaImpl")) return null;
    }
    const blk = g.get().get("_block") orelse return null;
    if (blk != .IrClosure) return null;
    const info = self.closures.get(@intCast(blk.IrClosure.id)) orelse return null;
    const up = closureUserParamsChecked(self, info);
    const n = std.math.cast(u8, up.n) orelse return null;
    return .{ .n = n, .authoritative = up.stripped };
}

/// Build an `ArgShape` describing one runtime value for the shared applicability
/// scorer. Named args are not threaded into the positional `pickOverload`
/// path, so `named` stays null here.
fn shapeOfValue(self: *VmHost, v: *const Value) applicability.ArgShape {
    var arity_authoritative = false;
    const arity: ?u8 = switch (v.*) {
        .IrClosure => |c| blk: {
            const info = self.closures.get(c.id) orelse break :blk null;
            const up = closureUserParamsChecked(self, info);
            arity_authoritative = up.stripped;
            break :blk std.math.cast(u8, up.n);
        },
        .Function => |f| std.math.cast(u8, f.decl.params.len),
        .Class => 0,
        .Instance => blk: {
            const cli = composableLambdaBlockArity(self, v) orelse break :blk null;
            arity_authoritative = cli.authoritative;
            break :blk cli.n;
        },
        else => null,
    };
    return .{
        .runtime_class = overload_match.runtimeHead(v),
        .is_null = v.* == .Null,
        .is_lambda = valueIsCallable(v),
        .lambda_arity = arity,
        .lambda_is_literal = arity_authoritative,
        .func_typed = std.mem.startsWith(u8, v.typeFqn(), "kotlin.Function"),
        .value = @ptrCast(v),
    };
}

/// `applicability.ApplicabilityScope.refine`: wraps `refineByDeclaredArgs`.
fn applicRefineCb(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return overload_match.refineByDeclaredArgs(self, param_ty, v);
}

/// `applicability.ApplicabilityScope.identity_conflict`: wraps the cross-package
/// class-identity disproof so the exact-name overload tier rejects a
/// same-simple-name argument from a different package.
fn applicIdentityConflictCb(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return overload_match.crossPackageIdentityConflict(self, param_ty, v);
}

/// `applicability.ApplicabilityScope.subtype`: the instance-supertype BFS from
/// `overloadScoreArg`, returning the match depth (or null when the value is not
/// an instance or `target` is never reached).
fn applicSubtypeCb(ctx: *anyopaque, value: *const anyopaque, target: []const u8) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const arg: *const Value = @ptrCast(@alignCast(value));
    const strace = if (runtime.getenvSlice("KLIO_SUBTYPE_TRACE")) |w| (std.mem.indexOf(u8, target, w) != null) else false;
    if (arg.* != .Instance) {
        if (strace) std.debug.print("[sub] target={s} arg-tag={s} -> null\n", .{ target, @tagName(std.meta.activeTag(arg.*)) });
        return null;
    }
    if (strace) std.debug.print("[sub] target={s} head={s}\n", .{ target, overload_match.runtimeHead(arg) });
    var queue: std.ArrayList(QItem) = .empty;
    defer queue.deinit(self.allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.allocator);
    queue.append(self.allocator, .{ .name = overload_match.runtimeHead(arg), .depth = 0 }) catch return null;
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
        const cur_key = host_call_member.mangledClassKeyOf(self, cur.name) orelse cur.name;
        if (host_call_member.classHeadsMatch(self, cur.name, target)) {
            return cur.depth;
        }
        const cg = self.classes.borrow();
        defer cg.deinit();
        // A dotted supertype ascends through its mangled entry.
        if (cg.get().get(cur.name) orelse cg.get().get(cur_key)) |def_ref| {
            const dg = def_ref.borrow();
            defer dg.deinit();
            for (dg.get().supertype_names) |sup| {
                queue.append(self.allocator, .{ .name = sup, .depth = cur.depth + 1 }) catch return null;
            }
        }
    }
    return null;
}

/// Per-candidate `SigView` for the shared applicability scorer, read straight
/// off the `Func` (the same sources the legacy `overloadScore` reads).
fn sigViewOfFunc(self: *VmHost, module: *const Module, cand: FuncId) ?applicability.SigView {
    const f = funcAt(module, cand) orelse return null;
    return .{
        .params = f.params,
        .defaults = funcDefaults(self, cand),
        .has_body = f.hasBody(),
        .low_priority = f.low_priority,
    };
}

/// Applicability points for one positional candidate via the shared scorer, or
/// null when it does not bind. The `-1` under-application penalty is folded into
/// `points` by `applicable()`, so the caller keys directly on the result.
fn positionalPoints(self: *VmHost, module: *const Module, cand: FuncId, shapes: []const applicability.ArgShape, scope: applicability.ApplicabilityScope) ?i32 {
    const sig = sigViewOfFunc(self, module, cand) orelse return null;
    const sc = applicability.applicable(&sig, shapes, scope) orelse return null;
    return sc.points;
}

/// Declared arity of a function-TYPE reference: `Function2` -> 2, an
/// arrow-form name by counting its generic args (`args.len - 1`, the last
/// being the return type). Null when the shape carries no arity.
fn fnTypeArity(ty: *const TypeRef) ?usize {
    const n = applicability.simpleName(ty.name);
    if (std.mem.startsWith(u8, n, "Function")) {
        const digits = n["Function".len..];
        if (digits.len != 0) {
            if (std.fmt.parseInt(usize, digits, 10)) |k| {
                return k;
            } else |_| {}
        }
    }
    if (std.mem.indexOf(u8, ty.name, "->") != null and ty.args.len != 0) {
        return ty.args.len - 1;
    }
    return null;
}

/// Declared parameter count of a callable VALUE, when known.
fn callableDeclaredArity(self: *VmHost, v: *const Value) ?usize {
    return switch (v.*) {
        .IrClosure => |c| if (self.closures.get(c.id)) |info| info.n_params else null,
        .Function => |fv| fv.decl.params.len,
        else => null,
    };
}

/// Whether `cand` is outside the baked target's overload set because it is
/// declared in a different package, and the target — having no body — cannot
/// score against it.
///
/// The re-pick ranks the candidates the lowering could not tell apart from the
/// argument SHAPES alone; it is not a second scope resolution. Lowering already
/// settled scope (an explicit import outranks the caller's own package, which
/// outranks a star/default import), so a same-simple-name function in another
/// package is not an overload of the committed target at all. That normally does
/// no harm, because the target scores too and defends its own binding — but a
/// BODYLESS target (an `expect` with no `actual` here, a header stub) has no
/// signature to score, so any body-bearing namesake anywhere in the program won
/// by default: `import p1.getStr` silently ran `p2.getStr`.
fn crossPackageNonCandidate(module: *const Module, f: *const Func, cand: FuncId) bool {
    if (f.hasBody()) return false;
    const cf = funcAt(module, cand) orelse return false;
    return !std.mem.eql(u8, cf.package, f.package);
}

fn pickOverload(self: *VmHost, module: *const Module, func: FuncId, args: []const Value) ?FuncId {
    const f = funcAt(module, func) orelse return null;
    // A statically-bound INSTANCE METHOD is not in the top-level overload
    // set: the lowering resolved it by scope (a private member wins over
    // every top-level namesake for a bare call in its class), and the
    // simple-name candidates here are top-level functions/extensions. A
    // re-pick would swap SnapshotStateMap's private `withCurrent` member
    // for the unrelated `T : StateRecord`.withCurrent extension.
    if (f.kind == .instance_method or f.kind == .member_extension) return null;
    const name = f.name;
    const candidates = module.funcsBySimpleName(name);
    if (candidates.len < 2) return null;

    var shapes_buf: [24]applicability.ArgShape = undefined;
    var shapes_heap: ?[]applicability.ArgShape = null;
    defer if (shapes_heap) |h| self.allocator.free(h);
    const shapes: []applicability.ArgShape = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else blk: {
        const h = self.allocator.alloc(applicability.ArgShape, args.len) catch return null;
        shapes_heap = h;
        break :blk h;
    };
    for (args, 0..) |*a, i| shapes[i] = shapeOfValue(self, a);
    const scope = applicability.ApplicabilityScope{
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
        .identity_conflict = applicIdentityConflictCb,
    };

    // A `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`
    // overload is not a source-level candidate: score ordinary and low-priority
    // candidates apart so an applicable ordinary overload always wins. Without
    // this a hidden binary-compat form whose arity exactly matches the call
    // (`f(a)` over `f(a, b = …)`) outscores the real overload here on the
    // positional re-pick — the last picker in the chain — and, when it
    // delegates to the real overload by name, self-recurses.
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = std.math.minInt(i32);
    var best_low: ?FuncId = null;
    var best_low_score: i32 = std.math.minInt(i32);
    if (positionalPoints(self, module, func, shapes, scope)) |s| {
        if (f.low_priority) {
            best_low = func;
            best_low_score = s;
        } else {
            best_ord = func;
            best_ord_score = s;
        }
    }
    for (candidates) |cand| {
        if (cand.int() == func.int()) continue;
        if (crossPackageNonCandidate(module, f, cand)) continue;
        const total = positionalPoints(self, module, cand, shapes, scope) orelse continue;
        const is_low = if (funcAt(module, cand)) |cf| cf.low_priority else false;
        if (is_low) {
            if (best_low == null or total > best_low_score) {
                best_low = cand;
                best_low_score = total;
            }
        } else if (best_ord == null or total > best_ord_score) {
            best_ord = cand;
            best_ord_score = total;
        }
    }

    return best_ord orelse best_low;
}

// Function-type / callability helpers shared with the root module.
const isFunctionType = root.isFunctionType;
const valueIsCallable = root.valueIsCallable;
const primitiveParamAccepts = root.primitiveParamAccepts;
const extDeclRecvIsUserClass = root.extDeclRecvIsUserClass;
const valueIsBuiltin = root.valueIsBuiltin;

// -------------------------------------------------------------------------
// Public dispatch entry points.
// -------------------------------------------------------------------------

/// Single function-call dispatch flow.
/// Compute the monomorphic call fast-path plan for `func`, encoded for caching on
/// the `Func`: `1` = ineligible (use full dispatch), `n_params + 2` = eligible. A
/// plain top-level user function a call site can dispatch straight to its body.
/// Excludes anything needing the slow path's per-call work — bodyless /
/// native-bound / suspend / inline funcs, extensions and receiver methods,
/// varargs, default args, reified type params, and any name with sibling
/// overloads (which need runtime re-resolution). The evaluator caches the result
/// on the `Func` and consults the host only once per function.
pub fn fastCallPlan(self: *VmHost, module: *const Module, func: FuncId) u16 {
    const f = funcAt(module, func) orelse return 1;
    if (!f.hasBody()) return 1;
    if (f.is_suspend or f.is_inline) return 1;
    // A `@Composable` call must route through `callFunc` so its body is
    // bracketed with the composer group push/pop; never take the fast path.
    if (compose.isComposable(f)) return 1;
    if (f.params.len > 253) return 1;
    if (paramIsThis(f.params) or f.has_receiver_param) return 1;
    if (lastIsVararg(f.params)) return 1;
    if (hasNonFinalVararg(f.params)) return 1;
    if (funcDefaults(self, func) != null) return 1;
    if (resolvedNativeForm(self, func) != null) return 1;
    if (module.funcsBySimpleName(f.name).len != 1) return 1;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.func_type_params.get(func) != null) return 1;
    }
    return @as(u16, @intCast(f.params.len)) + 2;
}

/// Lean dispatch for a fast-path call: run the body directly with `args_list`
/// transferred as the frame's params (one buffer, no copy). The eligibility
/// guarantees no overload re-resolution, extension push, reified binding, or
/// vararg/default handling is needed.
pub fn callFuncFast(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args_list: std.ArrayList(Value)) Allocator.Error!EvalResult {
    const f = funcAt(module, func).?;
    return ir.eval.evalWith(VmHost, allocator, module, f, args_list, self);
}

/// Trailing-lambda syntax bit for the next `callFunc` bind (see
/// `Inst.Call.trailing_lambda`): the `Call` exec sets it just before
/// dispatch and clears it after; `callFunc` consumes it once at entry.
/// Kotlin binds a trailing lambda to the LAST parameter regardless of
/// arity fit, which the positional heuristic below cannot know alone.
threadlocal var trailing_lambda_call: bool = false;

pub fn setTrailingLambdaCall(on: bool) void {
    trailing_lambda_call = on;
}

/// Active receiver-formed bodyless redirects: (fid, receiver identity)
/// pairs currently on the dispatch stack. Bounded — overflow entries are
/// dropped (the guard then simply cannot fire for them).
threadlocal var bodyless_active: [32]struct { fid: u32, ident: u64 } = undefined;
threadlocal var bodyless_active_len: usize = 0;

/// Whether `class_name` is a registered `fun interface`, so a lambda SAM-converts
/// to it and stands in for its single abstract method.
fn ownerIsFunInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_fun_interface;
}

/// Serve a bodyless member-extension of a `fun interface` from the SAM lambda on
/// the enclosing receiver tower: the innermost callable of the right arity runs
/// with `args_in[0]` -- the extension receiver -- bound as its `this`.
///
/// The lambda is only a candidate because the abstract slot it fills belongs to a
/// fun interface: nothing else can put a callable in a dispatch-receiver position
/// for a member extension.
fn samLambdaOnTower(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, f: *const ir.Func, args_in: []const Value) Allocator.Error!?EvalResult {
    if (f.kind != .member_extension) return null;
    const owner = module.registry.member_ext_owner_class.get(func) orelse return null;
    if (!ownerIsFunInterface(self, owner)) return null;
    const want = args_in.len - 1;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        const arity: usize = switch (e.v) {
            .IrClosure => |c| blk: {
                const info = self.closures.get(@intCast(c.id)) orelse continue;
                break :blk info.n_params;
            },
            else => continue,
        };
        if (arity != want) continue;
        return try @import("host_call_value.zig").callValueWithThis(self, allocator, &e.v, &args_in[0], args_in[1..], &.{});
    }
    return null;
}

fn bodylessRedirectActive(func: FuncId, ident: u64) bool {
    for (bodyless_active[0..bodyless_active_len]) |e| {
        if (e.fid == func.int() and e.ident == ident) return true;
    }
    return false;
}

fn bodylessRedirectPush(func: FuncId, ident: u64) void {
    if (bodyless_active_len < bodyless_active.len) {
        bodyless_active[bodyless_active_len] = .{ .fid = @intCast(func.int()), .ident = ident };
        bodyless_active_len += 1;
    }
}

fn bodylessRedirectPop() void {
    if (bodyless_active_len > 0) bodyless_active_len -= 1;
}

/// An `expect` reached with no `actual` and no klio intrinsic behind it. Before
/// this the call returned `Unit` and the program limped on with a wrong value —
/// the failure mode `klio check --unimplemented` exists to catch statically, and
/// by far the most confusing one klio can produce. Name the declaration and say
/// what to run to list every other one in the same program.
fn missingActual(allocator: Allocator, f: *const Func) EvalResult {
    return .{ .err = typeErr(
        allocator,
        "`{s}` is an `expect` with no `actual` on this platform, and no klio intrinsic backs it. " ++
            "Run `klio check --unimplemented <file>` to list every unimplemented declaration this program reaches.",
        .{f.fqn},
    ) };
}

pub fn callFunc(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args_in: []const Value) Allocator.Error!EvalResult {
    const trailing_syntax = trailing_lambda_call;
    trailing_lambda_call = false;
    const f = funcAt(module, func) orelse
        return .{ .err = typeErr(allocator, "unknown FuncId {d}", .{func.int()}) };

    if (trace.enabled(f.name)) {
        trace.emit("call_func {s} fid={d} fqn={s} argc={d}", .{ f.name, func.int(), f.fqn, args_in.len });
    }

    // Expected-type literal narrowing at the callee boundary (see
    // `narrowIntListArg`).
    for (f.params, 0..) |*p, i| {
        if (i >= args_in.len) break;
        narrowIntListArg(&p.ty, &args_in[i]);
    }

    linkAuditCheck(self, module, func, f, args_in);

    // A NON-final vararg (Kotlin allows `vararg` before trailing
    // defaulted / function-typed params) cannot bind by the simple
    // positional walk — the vararg must absorb the middle args while the
    // trailing params take the tail (`arrayData(vararg values,
    // toArray: ...)` called `("a", "b", "c") { ... }`), at ANY supplied
    // arity: at-or-under declared arity the positional walk would put a
    // raw element in the vararg slot and spill the next arg into the
    // trailing param. Route through the reorder-aware named binder —
    // except a pre-packed re-dispatch (the vararg slot already holds an
    // Array at its positional index), which is already bound.
    if (hasNonFinalVararg(f.params) and f.hasBody()) {
        const prepacked = blk: {
            // A prefix shorter than the param list also counts as pre-packed
            // when its vararg slot already holds an Array: the named binder
            // hands exactly that shape back when a post-vararg param has no
            // value and no default ("hand the prefix to call_func, whose own
            // padding finishes the job"). Re-routing it through the named
            // binder would re-produce the same prefix forever.
            if (args_in.len > f.params.len) break :blk false;
            for (f.params, 0..) |*p, i| {
                if (p.is_vararg) break :blk i < args_in.len and args_in[i] == .Array;
            }
            break :blk false;
        };
        if (!prepacked) {
            const no_names = try allocator.alloc(?[]const u8, args_in.len);
            defer allocator.free(no_names);
            @memset(no_names, null);
            return callFuncNamed(self, allocator, module, func, args_in, no_names);
        }
    }

    // The abstract member-extension of a `fun interface`, called with a LAMBDA
    // in the dispatch-receiver position (`with(measurePolicy) { measure(…) }`
    // where the policy came from `Layout(modifier, content) { measurables,
    // constraints -> … }`). The lambda IS the method body.
    //
    // Only the EXTENSION receiver rides in `args_in[0]` (the `MeasureScope`), so
    // the sibling redirect below -- which settles a bodyless decl by arity alone
    // -- cannot see the dispatch receiver at all and picks whichever same-named
    // implementation was declared first. Every SAM-lambda layout ran `BasicText`'s
    // private `EmptyMeasurePolicy`, which sizes to the incoming constraints, so a
    // text field measured itself to the unbounded scroll height of its own scroll
    // modifier. The lambda on the enclosing receiver tower is the answer.
    if (!f.hasBody() and args_in.len != 0) {
        if (try samLambdaOnTower(self, allocator, module, func, f, args_in)) |r| return r;
    }

    // Bodyless `expect` / header-only decl: the link step settled its
    // body siblings (declaration order); the first whose arity fits the
    // call runs. Settled once by `linkResolvedForms` — no per-call
    // `funcsBySimpleName` scan.
    if (!f.hasBody()) {
        const target: ?FuncId = blk: {
            const g = self.prog.borrow();
            defer g.deinit();
            break :blk g.get().resolvedRedirectTarget(module, func, args_in.len);
        };
        if (target) |cand| {
            // Re-entrancy guard for RECEIVER-formed headers: an abstract
            // member (`Comparable.compareTo`) re-entered through its own
            // redirect with the SAME receiver has no implementation for
            // that value — kotlinc would never compile the call. Without
            // the guard the sibling's body re-misses on the receiver and
            // the pair recurses to a native stack overflow (two lambdas
            // compared via `Comparable.compareTo` under a same-named
            // pack member). Value-recursion through a receiverless
            // `expect` header stays untouched.
            const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
            const recv_ident: u64 = if (has_this and args_in.len != 0) blk: {
                const v = args_in[0];
                break :blk switch (v) {
                    .Instance => |i| @intFromPtr(i.cell),
                    .IrClosure => |c| @as(u64, @intCast(c.id)),
                    .Int => |x| @as(u64, @bitCast(@as(i64, x))),
                    .Long => |x| @as(u64, @bitCast(x)),
                    else => @as(u64, @intFromEnum(std.meta.activeTag(v))),
                };
            } else 0;
            if (has_this and bodylessRedirectActive(func, recv_ident)) {
                return .{ .err = typeErr(allocator, "abstract `{s}` has no implementation applicable to this receiver", .{f.name}) };
            }
            if (trace.enabled(f.name)) {
                const g = funcAt(module, cand);
                trace.emit("map=bodyless_sibling name={s} fqn={s}", .{ f.name, if (g) |gg| gg.fqn else "?" });
            }
            if (has_this) {
                bodylessRedirectPush(func, recv_ident);
                defer bodylessRedirectPop();
                return callFunc(self, allocator, module, cand, args_in);
            }
            return callFunc(self, allocator, module, cand, args_in);
        }
    }

    // One executable form per symbol: a top-level function whose single
    // form was resolved to a native binding at link time dispatches that
    // binding instead of running its lowered shim body. The form was
    // settled once by `linkResolvedForms`; this consults it by `FuncId`
    // with no per-call FQN probe.
    if (resolvedNativeForm(self, func)) |intrinsic| {
        if (!f.hasBody() and trace.enabled(f.name)) {
            trace.emit("map=bodyless_native name={s} fqn={s}", .{ f.name, f.fqn });
        }
        return dispatchIntrinsic(self, allocator, f.fqn, intrinsic, args_in);
    }

    // A bodyless declaration the link could NOT settle. A receiver-formed
    // one is a member-form intrinsic's header (`Array<T>.fill` is served
    // under the receiver type's member surface, not a package-level FQN):
    // dispatch it through the member walk on its bound receiver. A walk
    // MISS (the canonical `Vm::call_member` message — nothing serves the
    // name, e.g. an `expect` whose platform `actual` is outside the pack's
    // source set) is a no-op returning Unit, the shape the manufactured
    // empty bodies produced before header-only declarations stayed
    // bodyless. A receiverless one returns Unit the same way.
    if (!f.hasBody()) {
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this") and args_in.len != 0) {
            if (trace.enabled(f.name)) {
                trace.emit("map=bodyless_member name={s} fqn={s}", .{ f.name, f.fqn });
            }
            const r = try host_call_member.callMember(self, allocator, &args_in[0], f.name, args_in[1..]);
            if (r == .err and r.err == .Unimplemented) {
                const m = r.err.Unimplemented;
                if (std.mem.indexOf(u8, m, "Vm::call_member") != null) {
                    if (runtime.freeScratch()) allocator.free(m);
                    if (f.is_expect) return missingActual(allocator, f);
                    return .{ .ok = .Unit };
                }
            }
            return r;
        }
        if (f.is_expect) return missingActual(allocator, f);
        return .{ .ok = .Unit };
    }

    // Mis-bound type-specialized overload fallback. A bare call is lowered
    // to a single FuncId with no argument-type information, so it can bind
    // to the wrong type-specialized overload. When the resolved body's
    // concrete primitive parameter types definitely mismatch the runtime
    // arguments and a same-FQN intrinsic exists, dispatch the intrinsic.
    if (f.hasBody() and args_in.len != 0) {
        const user_offset: usize = if (paramIsThis(f.params)) 1 else 0;
        var mismatch = false;
        for (args_in, 0..) |*v, i| {
            const pidx = user_offset + i;
            if (pidx < f.params.len) {
                const p = &f.params[pidx];
                if (!p.is_vararg and !primitiveParamAccepts(p.ty.name, v)) {
                    mismatch = true;
                    break;
                }
            }
        }
        if (mismatch) {
            if (lookupIntrinsic(self, f.fqn)) |intrinsic| {
                return dispatchIntrinsic(self, allocator, f.fqn, intrinsic, args_in);
            }
        }
    }

    // Pad missing positional args with each param's default value.
    var args = try argsFromSlice(allocator, args_in);
    defer args.deinit(allocator);

    // Kotlin trailing-lambda rule: when fewer args are supplied than
    // params and the last param is a function type while a default-valued
    // param sits before it, the final supplied callable binds the LAST
    // param; the gap params fall back to their defaults.
    if (args.items.len < f.params.len and args.items.len != 0) {
        const last_is_fn = f.params.len > 0 and isFunctionType(&f.params[f.params.len - 1].ty);
        const trailing_is_callable = valueIsCallable(&args.items[args.items.len - 1]);
        if (last_is_fn and trailing_is_callable) {
            const lead = args.items.len - 1;
            const last_param = f.params.len - 1;
            // The syntax bit (trailing lambda vs a plain positional lambda)
            // does not survive lowering, so gate the shift on fit: when the
            // callable's declared arity matches the POSITIONAL slot's
            // function-type arity, the call is a positional bind and the
            // gap params after it take their defaults — `render({ n -> },
            // { a, b -> })` with a defaulted third lambda param binds the
            // second lambda to the second param, never the third.
            const positional_fits = lead < f.params.len and
                isFunctionType(&f.params[lead].ty) and blk: {
                    const pa = fnTypeArity(&f.params[lead].ty) orelse break :blk true;
                    const ca = callableDeclaredArity(self, &args.items[args.items.len - 1]) orelse break :blk true;
                    break :blk pa == ca;
                };
            if (lead < last_param and (trailing_syntax or !positional_fits)) {
                if (funcDefaults(self, func)) |defaults| {
                    const trailing = args.items[args.items.len - 1];
                    args.items.len -= 1;
                    var idx = lead;
                    while (idx < last_param) : (idx += 1) {
                        if (idx < defaults.len and defaults[idx] != null) {
                            const dfid = defaults[idx].?;
                            const dfunc = funcAt(module, dfid) orelse
                                return .{ .err = typeErr(allocator, "default-arg FuncId {d} out of range", .{dfid.int()}) };
                            var thunk_args = try argsFromSlice(allocator, args.items);
                            vmhost.emitPath(allocator, "call_func_default_thunk", dfunc.fqn, dfid, null, args.items);
                            const r = try ir.eval.evalWith(VmHost, allocator, module, dfunc, thunk_args, self);
                            switch (r) {
                                .ok => |v| try args.append(allocator, v),
                                .err => |e| return .{ .err = e },
                            }
                            _ = &thunk_args;
                        } else {
                            try args.append(allocator, .Null);
                        }
                    }
                    try args.append(allocator, trailing);
                }
            }
        }
    }

    if (args.items.len < f.params.len) {
        if (funcDefaults(self, func)) |defaults| {
            var idx = args.items.len;
            while (idx < f.params.len) : (idx += 1) {
                if (idx < defaults.len and defaults[idx] != null) {
                    const dfid = defaults[idx].?;
                    const dfunc = funcAt(module, dfid) orelse
                        return .{ .err = typeErr(allocator, "default-arg FuncId {d} out of range", .{dfid.int()}) };
                    // A thunk lowered inside an extension fn body that
                    // references the receiver records `this` as a capture,
                    // not a param — seed capture[0] with the receiver.
                    var captures: std.ArrayList(Value) = .empty;
                    if (args.items.len != 0) try captures.append(allocator, args.items[0]);
                    var thunk_args = try argsFromSlice(allocator, args.items);
                    vmhost.emitPath(allocator, "call_func_default_thunk", dfunc.fqn, dfid, null, args.items);
                    const r = try ir.eval.evalWithCaptures(VmHost, allocator, module, dfunc, thunk_args, captures, self);
                    _ = &thunk_args;
                    switch (r) {
                        .ok => |v| try args.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                } else {
                    try args.append(allocator, .Null);
                }
            }
        }
    }

    const packed_args = try packVarargArgs(allocator, f, &args);
    // `packVarargArgs` either returns `args` itself or a fresh list after
    // deiniting `args`; the outer `defer args.deinit` would then double
    // free. Take ownership of the final list and disarm the defer.
    args = .empty;
    vmhost.emitPath(allocator, "call_func", f.fqn, func, null, args_in);
    return composableEval(self, allocator, module, f, packed_args);
}

/// Free the packed argument list backing without running the body. Mirrors how
/// `evalWith` consumes the list (its elements are borrowed from the caller's
/// `args_in`, so only the list itself is freed).
fn discardArgs(allocator: Allocator, packed_args: std.ArrayList(Value)) void {
    var list = packed_args;
    list.deinit(allocator);
}

/// Run `f`'s body, bracketing a `@Composable` call with the current composer's
/// group: `startGroup(key)` opens the positional group; `shouldRunGroup()`
/// decides whether to (re)compose it — a group that was composed before and is
/// not on an invalidated path is skipped (its slots/children reused, body not
/// run), which is how a sibling that did not read the changed state avoids
/// re-running. Plain calls, or a `@Composable` invoked with no active composer
/// (e.g. directly from `main`), run the body unwrapped.
/// Cached `KLIO_COMPOSE_PLUGIN` gate. When the lowering plugin is enabled the
/// pass threads the real `$composer` through composable bodies, so the implicit
/// composer hook must stand down entirely — otherwise it re-brackets every
/// composable call and recurses without bound.
/// The `@Composable` lowering plugin + upstream engine runtime is the only
/// compose path; there is no implicit-composer fallback to switch to, so this
/// is unconditionally true. Kept as a predicate because the compose threading
/// sites read it and the image/pack cache key salts on it.
pub fn composePluginEnabled() bool {
    return true;
}

fn composableEval(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    f: *const Func,
    packed_args: std.ArrayList(Value),
) Allocator.Error!EvalResult {
    // Plugin path: the pass already lowered composition into the body; run it
    // directly with no implicit-composer bracketing — but publish the threaded
    // `$composer` argument as the ambient composer for the call. A
    // `@Composable` property getter reached from this body has no composer
    // param of its own; the pass compiles its composer references to the
    // `__compose_currentComposer` intrinsic (upstream's "implemented as an
    // intrinsic" contract), which reads this stack.
    // The `@Composable` lowering plugin has already rewritten composition into
    // the body; run it directly and publish the threaded `$composer` argument as
    // the ambient composer so a `@Composable` property getter reached from this
    // body (compiled to the `__compose_currentComposer` intrinsic) reads it.
    if (compose.threadedComposerArg(f.params, packed_args.items)) |c| {
        compose.pushComposer(c);
        defer compose.popComposer();
        return ir.eval.evalWith(VmHost, allocator, module, f, packed_args, self);
    }
    return ir.eval.evalWith(VmHost, allocator, module, f, packed_args, self);
}

/// Per-candidate `SigView` for the shared applicability scorer on the NAMED
/// path. Unlike `sigViewOfFunc`, a bodyless declaration backed by a native
/// intrinsic (a resolved-native form or a same-FQN host intrinsic) is
/// selectable, so `has_body` folds that predicate in (mirroring the named
/// scorer's leading bodyless guard).
fn sigViewOfNamed(self: *VmHost, module: *const Module, cand: FuncId) ?applicability.SigView {
    const f = funcAt(module, cand) orelse return null;
    const selectable = f.hasBody() or resolvedNativeForm(self, cand) != null or lookupIntrinsic(self, f.fqn) != null;
    return .{
        .params = f.params,
        .defaults = funcDefaults(self, cand),
        .has_body = selectable,
        .low_priority = f.low_priority,
    };
}

/// Applicability points for one named-call candidate via the shared scorer, or
/// null when it does not bind. Binding output is not needed at pick time, so no
/// `arg_to_param_buf` is threaded.
fn namedPoints(self: *VmHost, module: *const Module, cand: FuncId, shapes: []const applicability.ArgShape, scope: applicability.ApplicabilityScope) ?i32 {
    const sig = sigViewOfNamed(self, module, cand) orelse return null;
    const sc = applicability.applicable(&sig, shapes, scope) orelse return null;
    return sc.points;
}

/// Re-pick the overload for a named call. The IR resolves the call site to one
/// FuncId by a positional-arity heuristic, but with named arguments a sibling
/// overload that carries the named parameters is the real target (Kotlin
/// resolves named calls by parameter name). Without this, a named arg whose
/// name is absent from the resolved func is silently dropped and the wrong
/// sibling is kept — e.g. a delegating `embeddedServer(connectors = …)`
/// resolves back to its `port`-taking caller and recurses forever.
///
/// `recv_external` is true when the call site has an implicit extension
/// receiver in scope (the bare call sits inside an extension/method body) that
/// the lowerer did not bake into `args`; an extension overload is then a valid
/// target with its `this` receiver-supplied. Returns `null` when no sibling
/// outscores the resolved func (or there is no overload set), leaving the
/// caller's pick in place.
/// Whether the candidate extension's declared receiver head names a class
/// this program KNOWS and the value provably does not implement. Unknown
/// heads (type params, aliases, function types) never disqualify.
fn extRecvDisprovenByValue(self: *VmHost, ty: *const TypeRef, v: *const Value) bool {
    var head = applicability.simpleName(ty.name);
    head = std.mem.trimEnd(u8, head, "?");
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0 or std.mem.eql(u8, head, "Any")) return false;
    if (std.mem.startsWith(u8, head, "Function")) return false;
    if (v.* != .Instance) return false;
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(head) == null) return false;
    }
    return !host_call_member.receiverImplementsHead(self, v, head);
}

pub fn pickNamedOverloadId(
    self: *VmHost,
    module: *const Module,
    func: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
    recv_external: bool,
) ?FuncId {
    return pickNamedOverloadIdRecv(self, module, func, args, arg_names, recv_external, null);
}

/// As `pickNamedOverloadId`, with the caller's implicit `this` value when
/// the baked target is NOT an extension. A re-pick onto an EXTENSION
/// candidate would prepend that receiver, so a candidate whose declared
/// receiver names a class the value provably does not implement
/// (`TestScope.runTest` against a plain test-class instance) is excluded.
pub fn pickNamedOverloadIdRecv(
    self: *VmHost,
    module: *const Module,
    func: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
    recv_external: bool,
    external_recv: ?*const Value,
) ?FuncId {
    const f0 = funcAt(module, func) orelse return null;
    const candidates = module.funcsBySimpleName(f0.name);
    if (candidates.len < 2) return null;
    const baked_is_ext = paramIsThis(f0.params);

    var shapes_buf: [24]applicability.ArgShape = undefined;
    var shapes_heap: ?[]applicability.ArgShape = null;
    defer if (shapes_heap) |h| self.allocator.free(h);
    const shapes: []applicability.ArgShape = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else blk: {
        const h = self.allocator.alloc(applicability.ArgShape, args.len) catch return null;
        shapes_heap = h;
        break :blk h;
    };
    for (args, 0..) |*a, i| {
        shapes[i] = shapeOfValue(self, a);
        shapes[i].named = if (i < arg_names.len) arg_names[i] else null;
    }
    const scope = applicability.ApplicabilityScope{
        .named = true,
        .recv_external = recv_external,
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
        .identity_conflict = applicIdentityConflictCb,
    };

    // A `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`
    // overload is not a source-level candidate: it is chosen only when no
    // ordinary overload applies. Score ordinary and low-priority candidates
    // apart so an applicable ordinary overload always wins — otherwise a hidden
    // binary-compat form whose leading params exactly match the call
    // (`lightColorScheme(primary = c)`) outscores the real overload (whose
    // extra roles are defaulted) and, when it delegates to the real one by
    // name, self-recurses.
    const pno_trace = if (runtime.getenvSlice("KLIO_MISS_TRACE")) |w| std.mem.eql(u8, w, f0.name) else false;
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = std.math.minInt(i32);
    var best_low: ?FuncId = null;
    var best_low_score: i32 = std.math.minInt(i32);
    for (candidates) |cand| {
        if (!baked_is_ext) {
            if (external_recv) |rv| {
                if (funcAt(module, cand)) |cf| {
                    if (paramIsThis(cf.params) and
                        extRecvDisprovenByValue(self, &cf.params[0].ty, rv)) continue;
                }
            }
        }
        const score = namedPoints(self, module, cand, shapes, scope);
        if (pno_trace) {
            const cf0 = funcAt(module, cand);
            std.debug.print("[pno] {s} cand={d} nparams={d} score={?}\n", .{ f0.name, cand.int(), if (cf0) |cf| cf.params.len else 0, score });
        }
        const sc = score orelse continue;
        const is_low = if (funcAt(module, cand)) |cf| cf.low_priority else false;
        if (is_low) {
            if (best_low == null or sc > best_low_score) {
                best_low = cand;
                best_low_score = sc;
            }
        } else if (best_ord == null or sc > best_ord_score) {
            best_ord = cand;
            best_ord_score = sc;
        }
    }
    if (pno_trace) std.debug.print("[pno] {s} baked={d} -> best_ord={?} best_low={?}\n", .{ f0.name, func.int(), if (best_ord) |b0| b0.int() else null, if (best_low) |b0| b0.int() else null });

    return best_ord orelse best_low;
}

pub fn callFuncNamed(self: *VmHost, allocator: Allocator, module: *const Module, func_in: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) {
            any_named = true;
            break;
        }
    }
    // The caller (the `.Call` evaluator path) has already re-picked the
    // overload by parameter name and supplied any implicit extension
    // receiver, so bind against `func_in` as given.
    const func = func_in;
    if (funcAt(module, func)) |f| {
        if (any_named or hasNonFinalVararg(f.params)) {
            const params = f.params;
            // Reorder named args against the declared parameter list.
            var slots = try allocator.alloc(?Value, params.len);
            defer allocator.free(slots);
            for (slots) |*s| s.* = null;

            // Bind named arguments first.
            for (args, 0..) |a, i| {
                if (i < arg_names.len) {
                    if (arg_names[i]) |arg_name| {
                        for (params, 0..) |p, pos| {
                            if (applicability.paramNameMatchesArg(p.name, arg_name)) {
                                slots[pos] = a;
                                break;
                            }
                        }
                    }
                }
            }

            // A trailing positional callable binds to the last function-typed
            // parameter (the `f(a, …) { lambda }` block), out of sequence, so
            // the intervening defaulted parameters are not consumed by it.
            var trailing_lambda: ?usize = null;
            if (args.len > 0 and params.len > 0) {
                const last = args.len - 1;
                const last_named = last < arg_names.len and arg_names[last] != null;
                const last_param = params.len - 1;
                if (!last_named and slots[last_param] == null and
                    isFunctionType(&params[last_param].ty) and valueIsCallable(&args[last]))
                {
                    slots[last_param] = args[last];
                    trailing_lambda = last;
                }
            }

            // Vararg-aware positional walk.
            var vararg_pos: ?usize = null;
            for (params, 0..) |p, pi| {
                if (p.is_vararg) {
                    vararg_pos = pi;
                    break;
                }
            }
            const walk_defaults = funcDefaults(self, func);
            var n_pos_total: usize = 0;
            for (args, 0..) |_, i| {
                const is_named = i < arg_names.len and arg_names[i] != null;
                if (is_named) continue;
                if (trailing_lambda != null and i == trailing_lambda.?) continue;
                n_pos_total += 1;
            }
            var pos_seen: usize = 0;
            var positional_idx: usize = 0;
            var vararg_acc: std.ArrayList(Value) = .empty;
            defer vararg_acc.deinit(allocator);
            var hit_vararg = false;
            for (args, 0..) |a, i| {
                const is_named = i < arg_names.len and arg_names[i] != null;
                if (is_named) continue;
                if (trailing_lambda != null and i == trailing_lambda.?) continue;
                while (positional_idx < params.len and slots[positional_idx] != null) positional_idx += 1;
                if (vararg_pos != null and positional_idx == vararg_pos.?) {
                    if (a == .Array and vararg_acc.items.len == 0) {
                        // Spread case: a single Array at the vararg position
                        // passes through untouched.
                        slots[positional_idx] = a;
                        positional_idx += 1;
                        pos_seen += 1;
                        continue;
                    }
                    // The vararg absorbs an arg only while more positional args
                    // remain than the unfilled NON-defaulted params after it
                    // strictly need. Those params cannot default and (in source
                    // Kotlin) could only have been supplied positionally by a
                    // slot-exact generated call — `CompositionLocalProvider(
                    // value, content, $composer, $changed)` from the compose
                    // plugin — so the tail args are theirs. Defaulted params
                    // never claim a tail arg: a source call can only pass them
                    // by name, and absorbing through them is the pre-existing
                    // behaviour.
                    var required_tail: usize = 0;
                    for (params[vararg_pos.? + 1 ..], vararg_pos.? + 1 ..) |_, j| {
                        if (slots[j] != null) continue;
                        const has_default = walk_defaults != null and j < walk_defaults.?.len and walk_defaults.?[j] != null;
                        if (!has_default) required_tail += 1;
                    }
                    if (n_pos_total - pos_seen > required_tail) {
                        try vararg_acc.append(allocator, a);
                        hit_vararg = true;
                        pos_seen += 1;
                        continue;
                    }
                    positional_idx = vararg_pos.? + 1;
                    while (positional_idx < params.len and slots[positional_idx] != null) positional_idx += 1;
                }
                if (positional_idx < params.len) slots[positional_idx] = a;
                positional_idx += 1;
                pos_seen += 1;
            }
            if (vararg_pos) |vp| {
                const velem = params[vp].ty.name;
                if (hit_vararg) {
                    var acc: std.ArrayList(Value) = .empty;
                    try acc.appendSlice(allocator, vararg_acc.items);
                    slots[vp] = try packVarargArray(allocator, velem, acc);
                } else if (slots[vp] == null) {
                    const empty_acc: std.ArrayList(Value) = .empty;
                    slots[vp] = try packVarargArray(allocator, velem, empty_acc);
                }
            }

            // Fill omitted slots from the function's default-arg thunks.
            const defaults = funcDefaults(self, func);
            var reordered: std.ArrayList(Value) = .empty;
            defer reordered.deinit(allocator);
            for (slots, 0..) |slot, i| {
                if (slot) |v| {
                    try reordered.append(allocator, v);
                    continue;
                }
                const dfid: ?FuncId = if (defaults != null and i < defaults.?.len) defaults.?[i] else null;
                if (dfid) |id| {
                    const dfunc = funcAt(module, id) orelse
                        return .{ .err = typeErr(allocator, "default-arg FuncId {d} out of range", .{id.int()}) };
                    var thunk_args = try argsFromSlice(allocator, reordered.items);
                    vmhost.emitPath(allocator, "call_func_named_thunk", dfunc.fqn, id, null, reordered.items);
                    const r = try ir.eval.evalWith(VmHost, allocator, module, dfunc, thunk_args, self);
                    _ = &thunk_args;
                    switch (r) {
                        .ok => |v| try reordered.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                } else {
                    // No value and no default: a trailing omitted param.
                    // Hand the prefix to call_func, whose own padding
                    // finishes the job. An explicitly supplied trailing
                    // `null` stays in place — `f(cause = null)` must bind
                    // Null, not re-default or pad as Unit.
                    break;
                }
            }
            return callFunc(self, allocator, module, func, reordered.items);
        }
    }
    return callFunc(self, allocator, module, func, args);
}

pub fn callFuncTyped(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
    // `arrayOf<ULong>(1u, 2u)` — an unsigned literal carries its DEFAULT
    // tag (UInt) and the explicit element-type argument must coerce it,
    // exactly as kotlinc types the literal by its expected type. Retag
    // integral args to the requested unsigned width before dispatch.
    if (type_args.len == 1 and funcAt(module, func) != null) {
        const f = funcAt(module, func).?;
        if (std.mem.eql(u8, f.name, "arrayOf") and std.mem.startsWith(u8, f.fqn, "kotlin")) {
            const want: ?Value = switch (type_args[0].len) {
                0 => null,
                else => if (std.mem.eql(u8, type_args[0], "ULong"))
                    Value{ .ULong = 0 }
                else if (std.mem.eql(u8, type_args[0], "UInt"))
                    Value{ .UInt = 0 }
                else if (std.mem.eql(u8, type_args[0], "UShort"))
                    Value{ .UShort = 0 }
                else if (std.mem.eql(u8, type_args[0], "UByte"))
                    Value{ .UByte = 0 }
                else
                    null,
            };
            if (want) |w| {
                const retagged = try allocator.alloc(Value, args.len);
                defer if (runtime.freeScratch()) allocator.free(retagged);
                for (args, retagged) |v, *slot| {
                    slot.* = if (v.asU64()) |u| switch (w) {
                        .ULong => Value{ .ULong = u },
                        .UInt => Value{ .UInt = @truncate(u) },
                        .UShort => Value{ .UShort = @truncate(u) },
                        .UByte => Value{ .UByte = @truncate(u) },
                        else => v,
                    } else v;
                }
                return callFuncTypedInner(self, allocator, module, func, retagged, arg_names, type_args, exact);
            }
        }
    }
    return callFuncTypedInner(self, allocator, module, func, args, arg_names, type_args, exact);
}

fn callFuncTypedInner(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
    // Reified enum reflection: `enumValues<T>()` / `enumValueOf<T>(name)` /
    // `enumEntries<T>()` (whose inline body survives as the
    // `enumEntriesIntrinsic` header — an `expect` with no compiled
    // `actual`, served here from the reified type argument).
    if (funcAt(module, func)) |f| {
        if (std.mem.startsWith(u8, f.fqn, "kotlin") and
            (std.mem.eql(u8, f.name, "enumValues") or std.mem.eql(u8, f.name, "enumValueOf") or
                std.mem.eql(u8, f.name, "enumEntries") or std.mem.eql(u8, f.name, "enumEntriesIntrinsic")))
        {
            if (runtime.getenvSlice("KLIO_NU_TRACE") != null) {
                std.debug.print("[eev] fn={s} nta={d} ta0={s}\n", .{ f.name, type_args.len, if (type_args.len > 0) type_args[0] else "-" });
            }
            if (type_args.len > 0 and type_args[0].len != 0) {
                const tn = type_args[0];
                const cls_value: ?Value = blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(tn)) |c| break :blk Value{ .Class = c.clone() };
                    // An owner-qualified reified name (`Outer.Nested`): the
                    // name-keyed table holds one same-simple-name winner, so
                    // resolve by FQN suffix across the table (cold path —
                    // reified enum serving only).
                    if (std.mem.indexOfScalar(u8, tn, '.') != null) {
                        var it = cg.get().iterator();
                        while (it.next()) |e| {
                            const dg = e.value_ptr.borrow();
                            const fqn = dg.get().fqn;
                            const hit = std.mem.eql(u8, fqn, tn) or
                                (fqn.len > tn.len and std.mem.endsWith(u8, fqn, tn) and fqn[fqn.len - tn.len - 1] == '.');
                            dg.deinit();
                            if (hit) break :blk Value{ .Class = e.value_ptr.clone() };
                        }
                        if (cg.get().get(tn[std.mem.lastIndexOfScalar(u8, tn, '.').? + 1 ..])) |c| break :blk Value{ .Class = c.clone() };
                    }
                    break :blk host_globals.lookupGlobal(self, tn);
                };
                if (cls_value) |cv| {
                    if (cv == .Class) {
                        const cls = cv.Class;
                        const cd = cls.borrow();
                        const is_enum = cd.get().is_enum;
                        if (is_enum) {
                            if (std.mem.eql(u8, f.name, "enumValues") or
                                std.mem.eql(u8, f.name, "enumEntries") or
                                std.mem.eql(u8, f.name, "enumEntriesIntrinsic"))
                            {
                                var items: std.ArrayList(Value) = .empty;
                                for (cd.get().enum_entries) |entry| {
                                    // The List owns one reference per element;
                                    // `enum_entries` keeps its own. Retain so
                                    // the List teardown does not free the shared
                                    // singleton out from under the ClassDef.
                                    entry.value.retain();
                                    items.append(allocator, entry.value) catch {};
                                }
                                cd.deinit();
                                return .{ .ok = .{ .List = .{
                                    .items = try ValueList.init(allocator, items),
                                    .mutable = false,
                                    .enum_entries = true,
                                    .backing = null,
                                } } };
                            }
                            // enumValueOf<T>(name)
                            if (args.len > 0 and args[0] == .String) {
                                const sg = args[0].String.borrow();
                                const want = sg.get().bytes;
                                for (cd.get().enum_entries) |entry| {
                                    if (std.mem.eql(u8, entry.name, want)) {
                                        const out = entry.value;
                                        // host-returns-owned: the singleton is owned
                                        // by the immutable ClassDef; retain.
                                        out.retain();
                                        sg.deinit();
                                        cd.deinit();
                                        return .{ .ok = out };
                                    }
                                }
                                const fqn = try runtime.strInit(allocator, "kotlin.IllegalArgumentException");
                                const msg = try runtime.strInitOwned(allocator, try std.fmt.allocPrint(allocator, "No enum constant {s}.{s}", .{ cd.get().fqn, want }));
                                sg.deinit();
                                cd.deinit();
                                return .{ .err = .{ .Throw = .{ .Exception = .{ .fqn = fqn, .message = msg, .cause = null } } } };
                            }
                        }
                        cd.deinit();
                    }
                }
            }
        }
        // Reified `kotlin.reflect.typeOf<T>()`: served from the call's
        // reified type argument as a synthetic `KType` (classifier + empty
        // arguments + nullability) instead of executing the stdlib body's
        // placeholder throw.
        if (std.mem.eql(u8, f.name, "typeOf") and std.mem.startsWith(u8, f.fqn, "kotlin.reflect") and
            type_args.len == 1 and type_args[0].len != 0)
        {
            return .{ .ok = try makeKTypeValue(self, allocator, type_args[0]) };
        }
    }

    // Overload resolution. Skipped for an `exact` call: the lowering
    // already resolved the overload from an explicit argument cast. A call
    // with NAMED arguments re-picks name-aware — the positional cache pick
    // would re-route to a sibling that lacks the supplied names, silently
    // defaulting the mismatched parameters (`ParagraphIntrinsics(
    // annotations = …)` bound the deprecated spanStyles overload).
    const has_named = blk: {
        for (arg_names) |n| {
            if (n != null) break :blk true;
        }
        break :blk false;
    };
    const resolved: FuncId = if (exact)
        func
    else if (has_named)
        (pickNamedOverloadId(self, module, func, args, arg_names, false) orelse func)
    else
        (pickOverloadCached(self, module, func, args) orelse func);

    // Incompatible-receiver guard: a bare call baked to a top-level
    // extension whose declared receiver is a user/pack class, with an
    // actual receiver that is a builtin value, cannot be correct.
    // Re-dispatch as a member call so the builtin member wins.
    if (funcAt(module, resolved)) |f| {
        if (paramIsThis(f.params) and args.len != 0 and
            extDeclRecvIsUserClass(f.params[0].ty.name) and valueIsBuiltin(&args[0]))
        {
            const fname = f.name;
            const recv = args[0];
            const rest = args[1..];
            return host_call_member.callMember(self, allocator, &recv, fname, rest);
        }
    }

    // Expected-type literal narrowing at the callee boundary: kotlinc
    // types `listOf(5)` as `List<Short>` against a declared
    // `Iterable<Short>` parameter, so a klio list still carrying the
    // default Int tags retags its fitting elements to the declared
    // narrow kind (`shortArrayOf(...).intersect(listOf(5))`). Same
    // discipline as the `arrayOf<ULong>` retag above.
    if (funcAt(module, resolved)) |f| {
        for (f.params, 0..) |*p, i| {
            if (i >= args.len) break;
            narrowIntListArg(&p.ty, &args[i]);
        }
    }

    // Bind each call-site type-arg name to a synth `Value::Class` global
    // for the duration of the call so reified type-param reads resolve.
    var names: []const []const u8 = &.{};
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.func_type_params.get(resolved)) |list| {
            names = list.items;
        }
    }
    const Saved = struct { name: []const u8, prev: ?Value };
    var saved: std.ArrayList(Saved) = .empty;
    defer saved.deinit(allocator);
    for (names, 0..) |type_name, idx| {
        const arg_name: []const u8 = if (idx < type_args.len) type_args[idx] else "";
        if (arg_name.len == 0) continue;
        // Class table first: a type argument names a type, so it binds the
        // `.Class` value even when the bare name's global is a constructor
        // intrinsic (exception classes). This is the same identity the
        // inline splice resolves for its reified binding.
        const cls_value: ?Value = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(arg_name)) |c| break :blk Value{ .Class = c.clone() };
            break :blk host_globals.lookupGlobal(self, arg_name);
        };
        const prev = blk: {
            const g = self.globals.borrow();
            defer g.deinit();
            break :blk g.get().lookup(type_name);
        };
        try saved.append(allocator, .{ .name = type_name, .prev = prev });
        if (cls_value) |v| {
            const g = self.globals.borrowMut();
            defer g.deinit();
            g.get().define(type_name, v) catch {};
        }
    }

    var result = try callFuncNamed(self, allocator, module, resolved, args, arg_names);

    var ri: usize = saved.items.len;
    while (ri > 0) {
        ri -= 1;
        const s = saved.items[ri];
        const g = self.globals.borrowMut();
        defer g.deinit();
        if (s.prev) |v| {
            g.get().define(s.name, v) catch {};
        } else {
            g.get().removeLocal(s.name);
        }
    }
    attachDeclaredElemTypes(module, resolved, type_args, &result);
    return result;
}

/// Record the call-site type-argument heads on a container a stdlib
/// creator just built (`listOf<String>()`); shared with the `CallValue`
/// intrinsic path in the evaluator.
fn attachDeclaredElemTypes(module: *const Module, func: FuncId, type_args: []const []const u8, result: *EvalResult) void {
    if (type_args.len == 0) return;
    if (result.* != .ok) return;
    const f = funcAt(module, func) orelse return;
    runtime.attachDeclaredElemTypes(f.fqn, type_args, &result.ok);
}

pub fn callNamedOverload(self: *VmHost, allocator: Allocator, module: *const Module, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, ctor_name: bool, caller_pkg: []const u8, caller_file: ?ir.FileId, synth_anchor_pkg: []const u8) Allocator.Error!MaybeValueResult {
    // An anon-object/side-module frame carries no top-level func index;
    // the overload set lives in the main module, so collect there.
    const mg = self.module.borrow();
    defer mg.deinit();
    const eff: *const Module = if (module.func_index.items.len == 0) mg.get() else module;
    // The package the visibility filter scopes against. For an ordinary
    // packaged caller this is `caller_pkg`, so the filter and the dispatch
    // below behave exactly as before. Only when the caller frame is a
    // synthesized closure with no package does the anchor (the
    // lowering-resolved target's package, supplied by the evaluator) fill in —
    // otherwise the empty scope leaves a same-name cross-package twin free to
    // win the tie.
    const scope_pkg: []const u8 = if (caller_pkg.len != 0) caller_pkg else synth_anchor_pkg;
    const anchored = caller_pkg.len == 0 and synth_anchor_pkg.len != 0;
    var excluded_xpkg = false;
    // Only intercept genuine overload sets: a single top-level function
    // keeps the plain global-value path. The name index is the same
    // authority as `func_index` (every append pairs with a name-index
    // push); the old per-call linear scan of the whole index was the
    // hottest frame in the interpreter profile.
    const candidates = eff.funcsBySimpleName(name);
    const ntrace = if (runtime.getenvSlice("KLIO_MISS_TRACE")) |w| std.mem.eql(u8, w, name) else false;
    if (candidates.len < 2) {
        if (ntrace) std.debug.print("[cno] {s} cands={d} -> decline\n", .{ name, candidates.len });
        return .{ .ok = null };
    }

    // Pick the best body-carrying overload by runtime arg types through
    // the shared applicability engine (proven zero-divergence against the
    // legacy scorer over the full sweep before the flip). Named arguments
    // participate: an overload that lacks a supplied arg name is
    // INAPPLICABLE (kotlinc's rule) — without this, a named call binds a
    // positional namesake and silently defaults the mismatched parameter
    // (`ParagraphIntrinsics(annotations = …)` picked the deprecated
    // `spanStyles` overload and dropped the annotations).
    if (args.len > 24) return .{ .ok = null };
    var any_named = false;
    var shapes_buf: [24]applicability.ArgShape = undefined;
    const shapes = shapes_buf[0..args.len];
    for (args, 0..) |*a, i| {
        shapes[i] = shapeOfValue(self, a);
        shapes[i].named = if (i < arg_names.len) arg_names[i] else null;
        if (shapes[i].named != null) any_named = true;
    }
    const scope = applicability.ApplicabilityScope{
        .named = any_named,
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
    };
    // `@LowPriorityInOverloadResolution` / deprecated-ERROR|HIDDEN overloads are
    // only chosen when nothing ordinary applies, and a same-named class
    // constructor outranks them (kotlinc). Score ordinary and low-priority
    // candidates apart: an applicable ordinary overload always wins; a
    // low-priority one is used only when no ordinary applies AND no same-named
    // constructor exists — otherwise decline so the caller's constructor path
    // binds. Without this a deprecated stub `fun LocalDate(...) = LocalDate(...)`
    // re-picks itself across the two low-priority overloads and self-recurses.
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = 0;
    var best_low: ?FuncId = null;
    var best_low_score: i32 = 0;
    for (candidates) |cand| {
        // A receiver-taking candidate whose declared receiver names a
        // builtin shape the first arg definitely is not (UIntArray.fill
        // offered a plain Array) is disqualified outright.
        var is_low = false;
        if (funcAt(eff, cand)) |cf| {
            if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this") and args.len != 0 and
                host_call_member.builtinReceiverDisproven(&args[0], cf.params[0].ty.name)) continue;
            is_low = cf.low_priority;
            // A plain top-level candidate in a package the reference site
            // cannot see is not a Kotlin resolution target — an unimported
            // pack's `max(Dp, Dp)` must not swallow `kotlin.math.max(Int,
            // Int)` just because the intrinsic carries no rankable body.
            // Extensions stay: receiver narrowing is their discriminator.
            if (scope_pkg.len != 0 and
                !(cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")))
            {
                const cfile = caller_file orelse ir.FileId.from(std.math.maxInt(u32));
                if (eff.scopeTier(cf.fqn, cf.package, name, scope_pkg, cfile) == ir.Module.other_package_tier) {
                    excluded_xpkg = true;
                    continue;
                }
            }
        }
        const pts = positionalPoints(self, eff, cand, shapes, scope);
        if (ntrace) std.debug.print("[cno] {s} cand={d} pts={?}\n", .{ name, cand.int(), pts });
        if (pts) |total| {
            if (is_low) {
                if (best_low == null or total > best_low_score) {
                    best_low = cand;
                    best_low_score = total;
                }
            } else if (best_ord == null or total > best_ord_score) {
                best_ord = cand;
                best_ord_score = total;
            }
        }
    }

    // A same-named class constructor belongs to the same overload set as the
    // top-level factory functions (Kotlin resolves them together, most-specific
    // wins). Score the primary constructor with the same engine; when it binds
    // STRICTLY better than the best factory, decline so the caller's ctor path
    // constructs. Strict-better keeps the common factory-wraps-ctor pattern
    // (equal signatures -> the factory still wins), while an exact-match
    // constructor outranks a factory whose parameter only loosely accepts the
    // args (a `List<Feature>` reaching a `FloatArray` param). Without this a
    // factory that delegates `Foo(features, center)` back into the set — which
    // should reach the constructor — re-picks a sibling factory and self-recurses.
    if (best_ord != null) {
        if (mg.get().classId(name)) |ccid| {
            if (ccid.int() < mg.get().classes.items.len) {
                const ctor_sig = applicability.SigView{
                    .params = mg.get().classes.items[ccid.int()].primary_params,
                    .has_body = true,
                };
                if (applicability.applicable(&ctor_sig, shapes, scope)) |csc| {
                    if (csc.points > best_ord_score) return .{ .ok = null };
                }
            }
        }
    }

    const func = best_ord orelse fallback: {
        // Only fall to a low-priority overload when nothing better can bind: no
        // ordinary overload applied AND no same-name class constructor exists
        // (the caller's `ctor_name` — a lowering-resolved class — is the
        // reliable signal; `classId` can miss across a pack boundary). Declining
        // lets the caller's constructor path win, so a deprecated stub that
        // calls the constructor by name cannot re-pick itself and recurse.
        if (best_low) |low| {
            // Check the MAIN module for a same-name class (the pack's classes
            // live there; `eff` may be a side module whose class index misses
            // them). A class means a constructor the caller will bind.
            const has_class = ctor_name or mg.get().classId(name) != null;
            if (!has_class) break :fallback low;
        }
        return .{ .ok = null };
    };

    if (trace.enabled(name)) {
        trace.emit("global-overload {s} -> fid={d} (of {d} candidates)", .{ name, func.int(), candidates.len });
    }

    // `func` is the scope-correct pick this call already resolved by argument
    // shapes. Normally `callFuncTyped` re-picks the overload again — harmless
    // for a packaged caller. But when the anchor excluded a cross-package twin
    // (a synthesized empty-package frame), that re-pick runs without scope and
    // would re-cross to the twin; dispatch `func` exactly to hold the pick.
    // The narrow condition keeps every ordinary call on the re-pick path.
    const exact_dispatch = anchored and excluded_xpkg;
    const r = try callFuncTyped(self, allocator, eff, func, args, arg_names, &.{}, exact_dispatch);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = e },
    };
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}
