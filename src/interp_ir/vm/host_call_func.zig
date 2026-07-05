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
const overload_match = @import("overload_match.zig");
const compose = @import("compose.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
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
// Vararg packing (mirrors `pack_vararg_args` in lib.rs).
// -------------------------------------------------------------------------

/// Collapse the trailing positional args of a vararg call into a single
/// `Array` slot. Consumes `args` (an owned `ArrayList`), returning the
/// packed list. A `f(*arr)` spread (a lone `Array` already in the slot)
/// passes through untouched.
fn packVarargArgs(allocator: Allocator, func: *const Func, args: *std.ArrayList(Value)) Allocator.Error!std.ArrayList(Value) {
    if (!lastIsVararg(func.params)) return args.*;
    const n_params = func.params.len;
    const fixed = if (n_params == 0) 0 else n_params - 1;
    if (args.items.len == n_params and args.items[args.items.len - 1] == .Array) {
        return args.*;
    }
    var out: std.ArrayList(Value) = .empty;
    try out.ensureTotalCapacity(allocator, n_params);
    var i: usize = 0;
    while (i < fixed and i < args.items.len) : (i += 1) {
        out.appendAssumeCapacity(args.items[i]);
    }
    var rest: std.ArrayList(Value) = .empty;
    var j: usize = fixed;
    while (j < args.items.len) : (j += 1) {
        try rest.append(allocator, args.items[j]);
    }
    try out.append(allocator, runtime.ArrayData.fromBoxedList(try ValueList.init(allocator, rest)));
    args.deinit(allocator);
    return out;
}

// -------------------------------------------------------------------------
// Intrinsic resolution + dispatch (mirror `lookup_intrinsic` /
// `dispatch_intrinsic` in vmhost.rs).
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
// Overload scoring + selection (mirror `overload_score_arg`,
// `overload_score`, `pick_overload` in vmhost.rs).
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

    if (std.mem.eql(u8, nm, v_ty)) {
        const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
        return 100 + d;
    }
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.* == .Null and param_ty.nullable) return 50;

    // Numeric widening: Int → Long, Int → Double, Long → Double.
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;

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
            if (std.mem.eql(u8, cur.name, nm)) {
                const d: i32 = if (cur.depth > 50) 50 else cur.depth;
                return 60 - d;
            }
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(cur.name)) |def_ref| {
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

/// Build an `ArgShape` describing one runtime value for the shared applicability
/// scorer. Named args are not threaded into the positional `pickOverload`
/// path, so `named` stays null here.
fn shapeOfValue(self: *VmHost, v: *const Value) applicability.ArgShape {
    const arity: ?u8 = switch (v.*) {
        .IrClosure => |c| if (self.closures.get(c.id)) |info| std.math.cast(u8, info.n_params) else null,
        .Function => |f| std.math.cast(u8, f.decl.params.len),
        .Class => 0,
        else => null,
    };
    return .{
        .runtime_class = overload_match.runtimeHead(v),
        .is_null = v.* == .Null,
        .is_lambda = valueIsCallable(v),
        .lambda_arity = arity,
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

/// `applicability.ApplicabilityScope.subtype`: the instance-supertype BFS from
/// `overloadScoreArg`, returning the match depth (or null when the value is not
/// an instance or `target` is never reached).
fn applicSubtypeCb(ctx: *anyopaque, value: *const anyopaque, target: []const u8) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const arg: *const Value = @ptrCast(@alignCast(value));
    if (arg.* != .Instance) return null;
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
        if (std.mem.eql(u8, cur.name, target)) return cur.depth;
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(cur.name)) |def_ref| {
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

fn pickOverload(self: *VmHost, module: *const Module, func: FuncId, args: []const Value) ?FuncId {
    const f = funcAt(module, func) orelse return null;
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
    };

    var best_func: ?FuncId = null;
    var best_score: i32 = 0;
    if (positionalPoints(self, module, func, shapes, scope)) |s| {
        best_func = func;
        best_score = s;
    }
    for (candidates) |cand| {
        if (cand.int() == func.int()) continue;
        if (positionalPoints(self, module, cand, shapes, scope)) |total| {
            if (best_func == null or total > best_score) {
                best_func = cand;
                best_score = total;
            }
        }
    }

    return best_func;
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

pub fn callFunc(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args_in: []const Value) Allocator.Error!EvalResult {
    const f = funcAt(module, func) orelse
        return .{ .err = typeErr(allocator, "unknown FuncId {d}", .{func.int()}) };

    if (trace.enabled(f.name)) {
        trace.emit("call_func {s} fid={d} fqn={s} argc={d}", .{ f.name, func.int(), f.fqn, args_in.len });
    }

    linkAuditCheck(self, module, func, f, args_in);

    // A NON-final vararg (Kotlin allows `vararg` before trailing
    // defaulted / function-typed params) cannot bind by the simple
    // positional walk — the vararg must absorb the middle args while the
    // trailing params take the tail (`arrayData(vararg values,
    // toArray: ...)` called `("a", "b", "c") { ... }`). Route through the
    // reorder-aware named binder, which handles exactly this shape.
    if (args_in.len > f.params.len and hasNonFinalVararg(f.params) and f.hasBody()) {
        const no_names = try allocator.alloc(?[]const u8, args_in.len);
        defer allocator.free(no_names);
        @memset(no_names, null);
        return callFuncNamed(self, allocator, module, func, args_in, no_names);
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
            if (trace.enabled(f.name)) {
                const g = funcAt(module, cand);
                trace.emit("map=bodyless_sibling name={s} fqn={s}", .{ f.name, if (g) |gg| gg.fqn else "?" });
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
                    return .{ .ok = .Unit };
                }
            }
            return r;
        }
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
            if (lead < last_param) {
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
fn composableEval(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    f: *const Func,
    packed_args: std.ArrayList(Value),
) Allocator.Error!EvalResult {
    if (!compose.isComposable(f))
        return ir.eval.evalWith(VmHost, allocator, module, f, packed_args, self);
    const composer = compose.currentComposer() orelse
        return ir.eval.evalWith(VmHost, allocator, module, f, packed_args, self);

    const key_val = Value.newLong(@bitCast(compose.callSiteKey()));
    switch (try host_call_member.callMember(self, allocator, &composer, "startGroup", &.{key_val})) {
        .err => |e| {
            discardArgs(allocator, packed_args);
            return .{ .err = e };
        },
        .ok => {},
    }
    const args_hash = Value.newLong(compose.argsHash(packed_args.items));
    const run = switch (try host_call_member.callMember(self, allocator, &composer, "shouldRunGroup", &.{args_hash})) {
        .err => |e| {
            _ = host_call_member.callMember(self, allocator, &composer, "endGroup", &.{}) catch {};
            discardArgs(allocator, packed_args);
            return .{ .err = e };
        },
        .ok => |v| v == .Bool and v.Bool,
    };
    var res: EvalResult = .{ .ok = .{ .Unit = {} } };
    if (run) {
        res = try ir.eval.evalWith(VmHost, allocator, module, f, packed_args, self);
        // Cache the return value on the group so a later pass that skips this
        // group (args unchanged, not invalidated) can hand back the same value
        // — a value-returning @Composable (`collectAsState`, a passthrough)
        // must not collapse to Unit when skipped.
        if (res == .ok) {
            switch (try host_call_member.callMember(self, allocator, &composer, "setGroupReturn", &.{res.ok})) {
                .err => |e| {
                    _ = host_call_member.callMember(self, allocator, &composer, "endGroup", &.{}) catch {};
                    return .{ .err = e };
                },
                .ok => {},
            }
        }
    } else {
        discardArgs(allocator, packed_args);
        // Reuse the cached return value from when this group last composed.
        switch (try host_call_member.callMember(self, allocator, &composer, "groupReturn", &.{})) {
            .err => |e| {
                _ = host_call_member.callMember(self, allocator, &composer, "endGroup", &.{}) catch {};
                return .{ .err = e };
            },
            .ok => |v| res = .{ .ok = v },
        }
    }
    switch (try host_call_member.callMember(self, allocator, &composer, "endGroup", &.{})) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    return res;
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
pub fn pickNamedOverloadId(
    self: *VmHost,
    module: *const Module,
    func: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
    recv_external: bool,
) ?FuncId {
    const f0 = funcAt(module, func) orelse return null;
    const candidates = module.funcsBySimpleName(f0.name);
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
    };

    var best: ?FuncId = null;
    var best_score: i32 = std.math.minInt(i32);
    for (candidates) |cand| {
        const score = namedPoints(self, module, cand, shapes, scope) orelse continue;
        if (best == null or score > best_score) {
            best = cand;
            best_score = score;
        }
    }

    return best;
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
                            if (std.mem.eql(u8, p.name, arg_name)) {
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
                        continue;
                    }
                    try vararg_acc.append(allocator, a);
                    hit_vararg = true;
                    continue;
                }
                if (positional_idx < params.len) slots[positional_idx] = a;
                positional_idx += 1;
            }
            if (vararg_pos) |vp| {
                if (hit_vararg) {
                    var acc: std.ArrayList(Value) = .empty;
                    try acc.appendSlice(allocator, vararg_acc.items);
                    slots[vp] = runtime.ArrayData.fromBoxedList(try ValueList.init(allocator, acc));
                } else if (slots[vp] == null) {
                    const empty_acc: std.ArrayList(Value) = .empty;
                    slots[vp] = runtime.ArrayData.fromBoxedList(try ValueList.init(allocator, empty_acc));
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
            if (type_args.len > 0 and type_args[0].len != 0) {
                const tn = type_args[0];
                const cls_value: ?Value = blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(tn)) |c| break :blk Value{ .Class = c.clone() };
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
    }

    // Overload resolution. Skipped for an `exact` call: the lowering
    // already resolved the overload from an explicit argument cast.
    const resolved: FuncId = if (exact) func else (pickOverloadCached(self, module, func, args) orelse func);

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

pub fn callNamedOverload(self: *VmHost, allocator: Allocator, module: *const Module, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!MaybeValueResult {
    // Only intercept genuine overload sets: a single top-level function
    // keeps the plain global-value path.
    var candidates: std.ArrayList(FuncId) = .empty;
    defer candidates.deinit(allocator);
    for (module.func_index.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) try candidates.append(allocator, entry.id);
    }
    if (candidates.items.len < 2) return .{ .ok = null };

    // Pick the best body-carrying overload by runtime arg types through
    // the shared applicability engine (proven zero-divergence against the
    // legacy scorer over the full sweep before the flip).
    if (args.len > 24) return .{ .ok = null };
    var shapes_buf: [24]applicability.ArgShape = undefined;
    const shapes = shapes_buf[0..args.len];
    for (args, 0..) |*a, i| shapes[i] = shapeOfValue(self, a);
    const scope = applicability.ApplicabilityScope{
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
    };
    var best_func: ?FuncId = null;
    var best_score: i32 = 0;
    for (candidates.items) |cand| {
        // A receiver-taking candidate whose declared receiver names a
        // builtin shape the first arg definitely is not (UIntArray.fill
        // offered a plain Array) is disqualified outright.
        if (funcAt(module, cand)) |cf| {
            if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this") and args.len != 0 and
                host_call_member.builtinReceiverDisproven(&args[0], cf.params[0].ty.name)) continue;
        }
        if (positionalPoints(self, module, cand, shapes, scope)) |total| {
            if (best_func == null or total > best_score) {
                best_func = cand;
                best_score = total;
            }
        }
    }
    const func = best_func orelse return .{ .ok = null };

    if (trace.enabled(name)) {
        trace.emit("global-overload {s} -> fid={d} (of {d} candidates)", .{ name, func.int(), candidates.items.len });
    }

    const r = try callFuncTyped(self, allocator, module, func, args, arg_names, &.{}, false);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = e },
    };
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}
