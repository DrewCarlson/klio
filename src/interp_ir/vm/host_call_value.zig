//! `VmHost` value-call dispatch: invoking callable `Value`s (closures,
//! lambdas, intrinsics, bound methods), lambda construction, and the
//! capture-read / receiver-shape helpers the IR evaluator consults.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const host_call_func = @import("host_call_func.zig");
const compose = @import("compose.zig");
const host_call_member = @import("host_call_member.zig");
const overload_match = @import("overload_match.zig");
const host_fields = @import("host_fields.zig");
const host_globals = @import("host_globals.zig");
const host_instances = @import("host_instances.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ValueList = runtime.ValueList;
const ValueSlice = runtime.ValueSlice;
const InstanceData = runtime.InstanceData;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const RuntimeError = runtime.RuntimeError;

const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const ReceiverShape = ir.eval.ReceiverShape;
const SuspendState = ir.eval.SuspendState;

fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

/// Whether `v` is a companion-object singleton instance. Its lift name
/// carries the `$Companion$` marker and its FQN ends in `.Companion`.
fn isCompanionInstance(v: Value) bool {
    if (v != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.indexOf(u8, cg.get().name, "$Companion$") != null or
        std.mem.endsWith(u8, cg.get().fqn, ".Companion");
}

/// Whether the companion surface itself serves `name`, so a
/// `Type::name` reference stays BOUND to the companion instead of
/// consuming its first argument as the receiver. A real IR member, a
/// companion-FQN intrinsic (`kotlin.Double.Companion.fromBits`), or a
/// declared companion-receiver extension header all count — the last
/// two are what `hostHasMember` alone cannot see, which mis-classified
/// `Double.Companion::fromBits` as an unbound instance-method ref.
fn companionServesName(self: *VmHost, rv: *const Value, name: []const u8) bool {
    if (host_call_member.hostHasMember(self, rv, name)) return true;
    if (rv.* != .Instance) return false;
    var fqn_buf: [256]u8 = undefined;
    var simple_buf: [128]u8 = undefined;
    const probes: ?struct { fqn: []const u8, recv: []const u8 } = blk: {
        const g = rv.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        const cls_fqn = cg.get().fqn;
        if (!std.mem.endsWith(u8, cls_fqn, ".Companion")) break :blk null;
        const fqn = std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ cls_fqn, name }) catch break :blk null;
        // The declared receiver form is the FQN's `Type.Companion` tail
        // (`kotlin.Double.Companion` -> `Double.Companion`).
        const owner = cls_fqn[0 .. cls_fqn.len - ".Companion".len];
        const owner_simple = if (std.mem.lastIndexOfScalar(u8, owner, '.')) |d| owner[d + 1 ..] else owner;
        const recv = std.fmt.bufPrint(&simple_buf, "{s}.Companion", .{owner_simple}) catch break :blk null;
        break :blk .{ .fqn = fqn, .recv = recv };
    };
    const p = probes orelse return false;
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        const bg = pg.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(p.fqn) != null) return true;
    }
    if (stdlib.implementation(p.fqn) != null) return true;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |fid| {
            const sig = mod.decl_sigs.get(fid.int()) orelse continue;
            const rt = sig.receiver_ty orelse continue;
            if (std.mem.eql(u8, rt.name, p.recv)) return true;
        }
    }
    return false;
}

/// The declared receiver head captured by an unbound type reference. A
/// `String?::plus` reference carries the String class value even when its
/// eventual receiver is null; invocation must continue resolving against
/// that static type instead of widening to every extension named `plus`.
fn typeReferenceStaticReceiver(v: *const Value) ?[]const u8 {
    if (v.* == .Class) {
        const g = v.Class.borrow();
        defer g.deinit();
        return g.get().fqn;
    }
    return null;
}

fn boundReferenceStaticReceiver(callee: *const Value) ?[]const u8 {
    if (callee.* != .Instance) return null;
    const g = callee.Instance.borrow();
    defer g.deinit();
    const recv = g.get().get("__bound_receiver__") orelse return null;
    return typeReferenceStaticReceiver(&recv);
}

fn boundReferenceFunc(callee: *const Value) ?FuncId {
    if (callee.* != .Instance) return null;
    const g = callee.Instance.borrow();
    defer g.deinit();
    const value = g.get().get("__bound_func__") orelse return null;
    if (value != .Int or value.Int < 0) return null;
    return FuncId.from(@intCast(value.Int));
}

/// Single callable-value dispatch over the value variants.
/// Resolve a plain positional exact-arity closure invocation into a ready
/// flat-call request, or null when any of the value-call ladder's special
/// shapes applies (receiver rebind, defaults padding, varargs, resolved
/// native form, composer arg completion) — those fall back to the recursive
/// path unchanged. Mirrors the `IrClosure` branch of `callValue` up to its
/// `evalWithCapturesChained` terminal, including the ambient-composer push,
/// which the flat activation's teardown undoes via `flatCallClosed`.
pub fn prepareClosureFlatCall(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    return prepareClosureFlatCallSlots(self, allocator, callee.IrClosure.id, callee.IrClosure.captures, null, args);
}

/// JIT call-out fast path. A trampoline's loop-invariant `CallValue` site
/// re-enters the interpreter through the full `callValue` preamble every
/// iteration; when the callee is a plain exact-arity closure, the same
/// prepare `execArmCallValue`'s flat hook uses resolves it, and the body
/// runs on the recursive nested entry directly. Null = shape declined
/// (arity mismatch, vararg, native form, unknown id); the caller falls
/// back to `callValue`, which owns every special case.
pub fn callClosureFast(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!?EvalResult {
    if (callee.* != .IrClosure) return null;
    const prep = (try prepareClosureFlatCallSlots(self, allocator, callee.IrClosure.id, callee.IrClosure.captures, null, args)) orelse return null;
    defer if (prep.composer_pushed) compose.popComposer();
    // `prepareClosureFlatCallSlots` always resolves and records the body's
    // module in the request.
    return try ir.eval.evalWithCapturesChained(VmHost, allocator, prep.run_module.?, prep.owning, prep.func, prep.args, prep.captures, prep.chain, prep.closure_id, self);
}

/// One capture slot replaced at activation open — the receiver bind of a
/// with-this call, applied to the COPIED capture vector so no bound closure
/// value is materialized per call.
const ThisOverride = struct { idx: usize, val: Value };

/// `KLIO_CALLVALUE_TRACE` gate, cached: the memoized `getenvSlice` still
/// takes a lock + hashmap probe per consult, which shows up when consulted
/// per call on the flat dispatch path.
var cvt_trace_cached: ?bool = null;
fn callValueTraceOn() bool {
    if (cvt_trace_cached) |v| return v;
    const on = runtime.envOnce("KLIO_CALLVALUE_TRACE") != null;
    cvt_trace_cached = on;
    return on;
}

fn prepareClosureFlatCallSlots(self: *VmHost, allocator: Allocator, id: u64, captures: ValueSlice, this_override: ?ThisOverride, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    const info = self.closures.get(@intCast(id)) orelse return null;
    if (args.len != info.n_params) return null;
    const module: *const Module = blk: {
        if (info.module) |m| break :blk m;
        // Pointer read only: the host's own reference keeps the main module
        // alive for the whole run, so the activation may hold the pointer.
        const g = self.module.clone();
        defer g.deinit();
        break :blk g.asPtr();
    };
    const func = module.funcById(info.body_func) orelse return null;
    for (func.params) |*p| {
        if (p.is_vararg) return null;
    }
    if (info.module == null) {
        host_call_func.linkAuditCheck(self, module, func.id, func, args);
        if (host_call_func.resolvedNativeForm(self, func.id)) |_| return null;
    }
    // Pooled carrier: the closure's params and captures are frame buffers
    // like any other, released through the frame's teardown.
    var call_args = try ir.eval.acquireArgsCap(allocator, args.len);
    if (call_args.capacity >= args.len) call_args.appendSliceAssumeCapacity(args) else try call_args.appendSlice(allocator, args);
    if (callValueTraceOn()) {
        for (call_args.items, 0..) |*av, ai| {
            std.debug.print("[flat-prep] body=#{d} #{d} kind={s}\n", .{ info.body_func.int(), ai, @tagName(std.meta.activeTag(av.*)) });
        }
    }
    var capture_values: std.ArrayList(Value) = .empty;
    {
        const g = captures.borrow();
        defer g.deinit();
        const src = g.get().*;
        capture_values = try ir.eval.acquireArgsCap(allocator, src.len);
        if (capture_values.capacity >= src.len) capture_values.appendSliceAssumeCapacity(src) else try capture_values.appendSlice(allocator, src);
    }
    if (this_override) |ov| {
        if (ov.idx >= capture_values.items.len) {
            try capture_values.appendNTimes(allocator, Value.Null, ov.idx + 1 - capture_values.items.len);
        }
        capture_values.items[ov.idx] = ov.val;
    }
    vmhost.emitPath(allocator, "call_value_closure", func.fqn, func.id, null, args);
    var composer_pushed = false;
    {
        if (compose.threadedComposerArgFor(func.fqn, func.params, call_args.items)) |c| {
            compose.pushComposer(c);
            composer_pushed = true;
        }
    }
    return .{
        .func = func,
        .run_module = module,
        .owning = info.module,
        .args = call_args,
        .captures = capture_values,
        .chain = info.chain,
        .closure_id = @intCast(id),
        .composer_pushed = composer_pushed,
        .dst = undefined,
    };
}

/// Flat-activation close hook: unwind the ambient-composer push
/// `prepareClosureFlatCall` applied for the call's duration.
pub fn flatCallClosed(self: *VmHost) void {
    _ = self;
    compose.popComposer();
}

/// Resolve a plain receiver-lambda invocation (`recv.block()` /
/// `block(recv, …)` lowered as CallValueWithThis) into a ready flat-call
/// request: the same receiver head-match, context-source push, capture
/// bind, and enclosing pushes `callValueWithThis` performs up to its
/// `callValue(&bound, …)` terminal, with the receiver bind applied as a
/// slot override on the activation's capture copy. The special shapes —
/// local named fn, receiver-fills-param, pass-threaded composable,
/// explicit-receiver overflow, varargs — decline and keep the recursive
/// path.
pub fn prepareClosureWithThisFlatCall(self: *VmHost, allocator: Allocator, callee: *const Value, this_value_in: *const Value, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    if (callee.* != .IrClosure) return null;
    const id = callee.IrClosure.id;
    const captures = callee.IrClosure.captures;
    const info = self.closures.get(@intCast(id)) orelse return null;
    if (args.len != info.n_params) return null;
    var selected_this = this_value_in.*;
    {
        const module_g = self.module.borrow();
        defer module_g.deinit();
        const m = info.module orelse module_g.get();
        const f = m.funcById(info.body_func) orelse return null;
        for (f.params) |*p| {
            if (p.is_vararg) return null;
        }
        // A named LOCAL FUNCTION lowered as a closure is not a receiver
        // lambda; a body with a declared leading `this` param binds the
        // receiver positionally — both keep the recursive path.
        const takes_receiver = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (takes_receiver) return null;
        if (!std.mem.eql(u8, f.name, "<lambda>")) return null;
        if (f.lambda_receiver_ty) |head| {
            if (callValueTraceOn()) std.debug.print("[cvt-head] id={d} head={s}\n", .{ id, head });
            if (try host_call_member.implicitReceiverForHead(self, allocator, this_value_in, head)) |matched| {
                selected_this = matched;
            }
        }
    }
    var this_idx: ?usize = null;
    for (info.capture_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "this")) {
            this_idx = i;
            break;
        }
    }
    // The receiver is an implicit receiver, hence a context-argument
    // source for a contextual callee inside the block. The mark is taken
    // BEFORE the push so the activation's close truncates it away.
    const ctx_mark = self.ctxStackLen();
    if (self.ctxIsActive()) self.ctxPush(selected_this) catch {};
    // With a `this` capture, the receiver binds into that slot exactly as
    // the recursive bind does, and the displaced prior `this` stays
    // reachable as an outer implicit receiver. Without one, the body takes
    // no receiver and the receiver is only the innermost subject — the
    // recursive path's plain terminal.
    const prior_this: ?Value = blk: {
        const ti = this_idx orelse break :blk null;
        const g = captures.borrow();
        defer g.deinit();
        const slice = g.get().*;
        if (ti < slice.len) break :blk slice[ti];
        break :blk null;
    };
    // The same pushes (and LIFO pop order at activation close) as the
    // recursive bind.
    var pushes: u8 = 0;
    const pushed_outer = po: {
        if (this_idx == null) break :po false;
        const pt = prior_this orelse break :po false;
        if (pt == .Null or pt == .Unit) break :po false;
        if (pt == .Instance and selected_this == .Instance) {
            break :po !ObjRef(InstanceData).ptrEq(pt.Instance, selected_this.Instance);
        }
        break :po true;
    };
    if (pushed_outer) {
        if (prior_this) |p| host_call_member.pushAccessEnclosing(self, &p);
        pushes += 1;
    }
    if (selected_this == .Instance or selected_this == .Null) {
        host_call_member.pushAccessEnclosingSubject(self, &selected_this);
        pushes += 1;
    }
    // The receiver bind is a slot override on the activation's COPIED
    // capture vector; the receiver stays rooted by the caller's registers
    // (or the context stack) for the call's duration, so no bound closure
    // value or keepalive is needed.
    const override: ?ThisOverride = if (this_idx) |ti| .{ .idx = ti, .val = selected_this } else null;
    var req = (try prepareClosureFlatCallSlots(self, allocator, id, captures, override, args)) orelse {
        // Declined at the terminal (native form): undo everything and let
        // the recursive path run.
        while (pushes > 0) : (pushes -= 1) host_call_member.popAccessEnclosing(self);
        self.ctxStackTruncate(ctx_mark);
        return null;
    };
    req.ctx_mark_override = ctx_mark;
    req.pop_enclosing_n = pushes;
    if (callValueTraceOn()) {
        std.debug.print("[cvt-flat] id={d} pushes={d} this_idx={?d} ncaps={d} sel_tag={s}\n", .{ id, pushes, this_idx, info.capture_names.len, @tagName(std.meta.activeTag(selected_this)) });
    }
    return req;
}

/// Resolve an undispatched coroutine start (`__klio_co_startRootOrSuspended`
/// under an enclosing pump) into a BARRIER flat-call request: the block runs
/// as an activation on the caller's driver, a suspension parks the segment
/// into the pump (`undispatchedFlatPark`) and the caller continues with
/// COROUTINE_SUSPENDED. Mirrors `coroutineStartRootOrSuspended`'s
/// enclosing-driver branch up to its `evalClosureRaw` terminal: scope-guard
/// push, empty call args (the block declares none), live captures with
/// every-`this` override by the scope value. The no-driver root branch
/// (pump construction) and every non-plain shape decline to the recursive
/// path.
pub fn prepareUndispatchedStartFlatCall(self: *VmHost, allocator: Allocator, module: *const Module, fid: FuncId, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    if (args.len != 2) return null;
    const f = module.funcById(fid) orelse return null;
    if (!std.mem.eql(u8, f.name, "__klio_co_startRootOrSuspended")) return null;
    // Without the registered native form the Kotlin fallback body serves
    // the call; without an enclosing pump the root branch's pump machinery
    // must run.
    if (host_call_func.resolvedNativeForm(self, fid) == null) return null;
    const has_driver = vmhost.coroutines.coroutineHasDriver();
    const scope_v = args[0];
    const block = args[1];
    if (block != .IrClosure) return null;
    const id = block.IrClosure.id;
    const captures = block.IrClosure.captures;
    const info = self.closures.get(@intCast(id)) orelse return null;
    if (info.n_params != 0) return null;
    // `evalClosureRaw` falls back to the ClosureInfo cell when the live
    // vector's length mismatches; that shape declines here.
    {
        const g = captures.borrow();
        defer g.deinit();
        if (g.get().*.len != info.capture_names.len) return null;
    }
    // `evalClosureRaw` overrides EVERY capture named `this`; the slot
    // override binds one, so a multi-`this` shape declines.
    var this_idx: ?usize = null;
    for (info.capture_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "this")) {
            if (this_idx != null) return null;
            this_idx = i;
        }
    }
    const override: ?ThisOverride = if (this_idx) |ti| .{ .idx = ti, .val = scope_v } else null;
    var req = (try prepareClosureFlatCallSlots(self, allocator, id, captures, override, &.{})) orelse return null;
    if (has_driver) {
        const enter = vmhost.coroutines.undispatchedFlatEnter(&scope_v);
        req.suspend_barrier = true;
        req.barrier_scope_base = enter.base;
        req.scope_guard_ident = enter.ident;
    } else {
        // No enclosing pump: this activation becomes its own root pump —
        // completion and suspension run the pump loop through the host
        // hooks. The scope value rides as the keepalive for the hooks.
        const enter = (try vmhost.coroutines.rootPumpFlatEnter(allocator, &scope_v)).?;
        req.suspend_barrier = true;
        req.root_pump = true;
        req.barrier_scope_base = enter.base;
        req.scope_guard_ident = enter.ident;
        if (runtime.reclaimEnabled()) scope_v.retain();
        req.keepalive = scope_v;
    }
    return req;
}

/// Driver hook: no-driver root suspension — park the root into its own
/// pump, drain it, exit it, and hand back the resumed value or
/// COROUTINE_SUSPENDED.
pub fn rootPumpBarrierPark(self: *VmHost, allocator: Allocator, st: *SuspendState, scope: Value, base: usize) Allocator.Error!EvalResult {
    var sink = self.out_sink.clone();
    defer sink.deinit();
    var intrinsic = makeIntrinsicHost(self);
    defer intrinsicHostDeinit(&intrinsic);
    const r = try vmhost.coroutines.rootPumpFlatPark(&intrinsic, allocator, sink.output(), st, &scope, base);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| try runtimeErrToEval(allocator, e),
    };
}

/// Driver hook: no-driver root completion — run the pump to quiescence
/// with the body's result as the root value (or just exit the pump when
/// the body raised), the recursive branch's tail.
pub fn rootPumpFlatComplete(self: *VmHost, allocator: Allocator, res: EvalResult, scope: Value, base: usize) Allocator.Error!EvalResult {
    var sink = self.out_sink.clone();
    defer sink.deinit();
    var intrinsic = makeIntrinsicHost(self);
    defer intrinsicHostDeinit(&intrinsic);
    if (res == .ok) {
        const r = try vmhost.coroutines.rootPumpFlatFinish(&intrinsic, sink.output(), &scope, res.ok, base, false);
        return switch (r) {
            .ok => |v| .{ .ok = v },
            .err => |e| try runtimeErrToEval(allocator, e),
        };
    }
    _ = try vmhost.coroutines.rootPumpFlatFinish(&intrinsic, sink.output(), &scope, null, base, true);
    return res;
}

/// Driver hook: barrier park for a flat undispatched-start activation.
pub fn undispatchedBarrierPark(self: *VmHost, allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!Value {
    _ = self;
    return vmhost.coroutines.undispatchedFlatPark(allocator, st, scope_base);
}

/// Driver hook: remove the scope entry a barrier prepare pushed, by
/// identity, at activation teardown.
pub fn undispatchedScopeLeave(self: *VmHost, ident: usize) void {
    _ = self;
    vmhost.coroutines.undispatchedFlatLeaveIdent(ident);
}

/// Flat counterpart of `callValueNamedRecvCtx`: the receiver-context
/// dispatch (a no-this-capture exact-arity closure invoked bare with an
/// Instance implicit receiver at the call site) prepares through the
/// with-this path; every other closure shape prepares as a plain value
/// call, mirroring the recursive routing exactly.
pub fn prepareValueRecvCtxFlatCall(self: *VmHost, allocator: Allocator, callee: *const Value, recv: *const Value, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    if (callee.* != .IrClosure) return null;
    if (recv.* == .Instance) {
        if (self.closures.get(@intCast(callee.IrClosure.id))) |info| {
            var has_this = false;
            for (info.capture_names) |n| {
                if (std.mem.eql(u8, n, "this")) {
                    has_this = true;
                    break;
                }
            }
            const receiver_lambda = blk: {
                if (!has_this) break :blk false;
                const module_g = self.module.borrow();
                defer module_g.deinit();
                const m = info.module orelse module_g.get();
                const f = m.funcById(info.body_func) orelse break :blk false;
                break :blk f.lambda_receiver_ty != null;
            };
            if ((!has_this or receiver_lambda) and args.len == info.n_params) {
                return prepareClosureWithThisFlatCall(self, allocator, callee, recv, args);
            }
        }
    }
    return prepareClosureFlatCall(self, allocator, callee, args);
}

var rsel_trace_init: bool = false;
var rsel_trace_on: bool = false;
fn rselTraceOn() bool {
    if (!rsel_trace_init) {
        rsel_trace_on = std.c.getenv("KLIO_RSEL_TRACE") != null;
        rsel_trace_init = true;
    }
    return rsel_trace_on;
}

pub fn callValue(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    // A captured-and-written local is BOXED into a shared cell at its binding
    // site, so a function-typed one arrives here as the cell, not the closure.
    // `block(i)` on such a binding calls what the cell holds.
    if (callee.* == .Cell) {
        const cg = callee.Cell.borrow();
        const inner = cg.get().*;
        inner.retain();
        cg.deinit();
        defer inner.release(allocator);
        return callValue(self, allocator, &inner, args);
    }
    if (callee.* == .Intrinsic) {
        return dispatchIntrinsic(self, callee.Intrinsic.fqn, callee.Intrinsic.func, args);
    }
    // `instance()` — bound-member-reference invocation
    // (`recv::method`, `String::plus`) wins over `operator fun
    // invoke`. A `$bound_ref$` synth carries `__bound_receiver__`
    // and `__bound_name__`; dispatch through them so an unbound
    // class-method ref consumes its first arg as the receiver.
    if (callee.* == .Instance) {
        var recv: ?Value = null;
        var name_v: ?Value = null;
        {
            const snap = callee.Instance.borrow();
            defer snap.deinit();
            recv = snap.get().get("__bound_receiver__");
            name_v = snap.get().get("__bound_name__");
        }
        if (recv != null and name_v != null and name_v.? == .String) {
            const rv = recv.?;
            const name = blk: {
                const g = name_v.?.String.borrow();
                defer g.deinit();
                break :blk g.get().bytes;
            };
            // Dispatch under the reference's creation-site file: a
            // file-private target is visible to the reference where it
            // was written, not where a combinator invokes it.
            var ref_pushed = false;
            var ref_prev: ?ir.eval.RefSiteOverride = null;
            if (host_call_member.boundRefFile(callee)) |bf| {
                ref_prev = ir.eval.pushRefSiteFile(bf);
                ref_pushed = true;
            }
            defer if (ref_pushed) ir.eval.popRefSiteFile(ref_prev);
            if (boundReferenceFunc(callee)) |func| {
                var exact_args: std.ArrayList(Value) = .empty;
                defer exact_args.deinit(allocator);
                // A TYPE-form reference is unbound — the first call argument
                // is the receiver. The type value is a `.Class`, but for a
                // companion-carrying class (`Int` declares one) the name in
                // value position is the COMPANION INSTANCE; prepending it
                // shifted every argument (`map(Int::toUInt)` ran `toUInt`
                // with the companion as `this`). Same predicate as the
                // by-name path below.
                const fid_type_like = (rv == .Class) or
                    (rv == .Instance and isCompanionInstance(rv) and
                        !companionServesName(self, &rv, name));
                if (fid_type_like) {
                    try exact_args.appendSlice(allocator, args);
                } else {
                    try exact_args.append(allocator, rv);
                    try exact_args.appendSlice(allocator, args);
                }
                const mg = self.module.borrow();
                defer mg.deinit();
                return host_call_func.callFunc(
                    self,
                    allocator,
                    mg.get(),
                    func,
                    exact_args.items,
                );
            }
            // An unbound class-method reference (`Long::toByte`, `String::plus`)
            // consumes its first argument as the receiver. The reference's
            // captured receiver is the type itself: a `.Class` value, or — when
            // a companion object is in scope for the type — that companion's
            // instance. Both are type-like; route the first argument as the
            // receiver when the named member is an instance method rather than a
            // companion member.
            // An unsigned-array type name in value position lowers to its
            const type_like = (rv == .Class) or
                (rv == .Instance and isCompanionInstance(rv) and
                    !companionServesName(self, &rv, name));
            if (type_like and args.len != 0) {
                const first = args[0];
                const rest = args[1..];
                if (rest.len == 0 and root.memberIsProperty(allocator, &self.classes, &first, name)) {
                    return host_fields.getField(self, allocator, &first, name);
                }
                const mr = try host_call_member.callMemberNamedStatic(
                    self,
                    allocator,
                    &first,
                    name,
                    rest,
                    &.{},
                    typeReferenceStaticReceiver(&rv),
                );
                // `JsonPrimitive::booleanOrNull` names an EXTENSION
                // property: no member takes the call, so the reference
                // reads the property on its receiver (the field-read path
                // resolves extension getters).
                if (rest.len == 0 and mr == .err and mr.err == .Unimplemented) {
                    const pr = try host_fields.getField(self, allocator, &first, name);
                    if (pr == .ok) return pr;
                }
                return mr;
            }
            if (args.len == 0 and root.memberIsProperty(allocator, &self.classes, &rv, name)) {
                return host_fields.getField(self, allocator, &rv, name);
            }
            const r = try host_call_member.callMember(self, allocator, &rv, name, args);
            // Fallback: a bare `::name` the lowerer bound to the enclosing
            // `this` may actually target a *top-level function* — the
            // binding is lowered before the function is registered (e.g. a
            // method default-arg thunk's `::shout`), so it can't be
            // distinguished at lower time. Only when member dispatch finds
            // no such member do we retry the global callable, so a genuine
            // bound member ref (`obj::method`, even one whose name matches
            // a top-level fn) keeps dispatching the member.
            if (r == .err and r.err == .Unimplemented) {
                if (host_globals.lookupGlobal(self, name)) |callable| {
                    if (callable == .IrClosure) {
                        return callValue(self, allocator, &callable, args);
                    }
                }
            }
            return r;
        }
        const inv = try host_call_member.callMember(self, allocator, callee, "invoke", args);
        const callee_is_cli = blk: {
            if (callee.* != .Instance) break :blk false;
            const g = callee.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk std.mem.eql(u8, cg.get().fqn, "androidx.compose.runtime.internal.ComposableLambdaImpl");
        };
        // Compose-plugin arg completion, instance side: a
        // ComposableLambdaImpl invoked through a typeless route
        // (`arr[i]()`, forEach's `it()`) misses its `invoke` because the
        // call lacks the trailing `(composer, changed)` the wrapper's
        // overloads declare. With a composer ambient, complete the pair
        // and retry — the type-directed emission kotlinc performs from the
        // value's declared `@Composable` fn type.
        if (inv == .err and inv.err == .Unimplemented and callee_is_cli) {
            if (compose.currentComposer()) |comp| {
                if (runtime.freeScratch()) {
                    const m = inv.err.Unimplemented;
                    if (std.mem.indexOf(u8, m, "Vm::call_member") != null) allocator.free(m);
                }
                const buf = try allocator.alloc(Value, args.len + 2);
                defer allocator.free(buf);
                @memcpy(buf[0..args.len], args);
                buf[args.len] = comp;
                buf[args.len + 1] = .{ .Int = 0 };
                return host_call_member.callMember(self, allocator, callee, "invoke", buf);
            }
        }
        // A `fun interface` instance with a single abstract method that is NOT
        // `invoke` — notably `kotlinx.coroutines.Runnable { fun run() }` — is
        // invoked as a function value by the dispatcher resume path
        // (`block()`); route it to `run()`. Only on the `invoke` dispatch miss,
        // so an `operator fun invoke` or a SAM whose method IS `invoke` is
        // unaffected.
        if (inv == .err and inv.err == .Unimplemented and callee.* == .Instance and
            host_call_member.hostHasMember(self, callee, "run"))
        {
            if (runtime.freeScratch()) {
                const m = inv.err.Unimplemented;
                if (std.mem.indexOf(u8, m, "Vm::call_member") != null) allocator.free(m);
            }
            return host_call_member.callMember(self, allocator, callee, "run", args);
        }
        return inv;
    }
    // Constructor-like call on a user class value
    // (`val ctor = ::Foo; ctor(1, 2)`). Falls through to a
    // direct ClassDef-based allocation when the class isn't
    // in the IR module's class_index — covers local classes
    // declared inside a fn body and registered via
    // Inst::RegisterClass.
    if (callee.* == .Class) {
        const cls = callee.Class;
        // SAM conversion: `FunInterface { lambda }` constructs a
        // synthetic instance whose single abstract method
        // dispatches the lambda body. We allocate a thin
        // InstanceData whose `fields` carry the lambda under
        // `__sam_target__`; call_member on this instance routes
        // any method call back through the lambda.
        const is_fun_interface = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().is_fun_interface;
        };
        if (is_fun_interface and args.len == 1) {
            const identity = nextInstanceId(self);
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            // The SAM instance owns one ref to its target; `args[0]` is a borrow
            // of the caller's register, so retain (instance teardown releases it).
            if (runtime.reclaimEnabled()) args[0].retain();
            try fields.append(allocator, .{ .name = "__sam_target__", .value = args[0] });
            const inst = try ObjRef(InstanceData).init(allocator, .{
                .class = cls.clone(),
                .fields = fields,
                .outer = null,
                .identity = identity,
                .native_state = null,
            });
            return .{ .ok = .{ .Instance = inst } };
        }
        const cls_name = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().name;
        };
        const cls_fqn = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().fqn;
        };
        // The bound ClassDef carries the resolved FQN; the module class
        // resolves by it, so `(::Ctor)(args)` constructs the referenced
        // class even when another package declares the same simple name.
        // A runtime-registered LOCAL class def IS the class: never redirect
        // it through the module index, where an unrelated same-simple-name
        // class (a nested class of another owner) can shadow it.
        const is_local_runtime = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().is_local_runtime;
        };
        const class_id: ?ir.ClassId = if (is_local_runtime) null else blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().classIdByFqn(cls_fqn)) |cid| break :blk cid;
            for (mg.get().class_index.items) |entry| {
                if (std.mem.eql(u8, entry.name, cls_name)) break :blk entry.id;
            }
            break :blk null;
        };
        if (class_id) |cid| {
            return host_instances.newInstance(self, allocator, cid, args, null);
        }
        // Direct allocation for classes that aren't in the IR
        // module index. The runtime ClassDef carries enough to
        // bind primary-param properties; init blocks + custom
        // getters land when local-class lowering grows them.
        const identity = nextInstanceId(self);
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        {
            const g = cls.borrow();
            defer g.deinit();
            const cdef = g.get();
            var i: usize = 0;
            while (i < cdef.primary_params.len) : (i += 1) {
                if (cdef.primary_params[i].property == null) continue;
                if (i < args.len) {
                    // The instance owns one ref per primary-ctor field; `args[i]`
                    // is a borrow of the caller's register, so retain.
                    if (runtime.reclaimEnabled()) args[i].retain();
                    try fields.append(allocator, .{ .name = cdef.primary_params[i].name, .value = args[i] });
                } else {
                    // An omitted trailing parameter takes its (literal) default;
                    // without this the field is simply absent (a later access
                    // fails "get_field" instead of reading the default value).
                    const dv: Value = if (cdef.primary_params[i].default) |e|
                        (simpleLiteral(allocator, e.get()) orelse Value.Null)
                    else
                        Value.Null;
                    try fields.append(allocator, .{ .name = cdef.primary_params[i].name, .value = dv });
                }
            }
            // Body-property defaults for runtime-registered local
            // classes. Literal inits evaluate inline; complex inits were
            // lowered as `$init$` thunks at class registration and run
            // below once the instance exists (they may read `this`).
            for (cdef.body_properties) |p| {
                if (p.init) |init_field| {
                    const v = simpleLiteral(allocator, init_field.get()) orelse Value.Null;
                    try fields.append(allocator, .{ .name = p.name, .value = v });
                } else if (p.getter == null and p.delegate == null) {
                    const v = p.primitive_zero orelse Value.Null;
                    try fields.append(allocator, .{ .name = p.name, .value = v });
                }
            }
        }
        const default_outer: ?Value = blk: {
            const g = self.class_default_outer.borrow();
            defer g.deinit();
            break :blk g.get().get(cls_name);
        };
        const inst = try ObjRef(InstanceData).init(allocator, .{
            .class = cls.clone(),
            .fields = fields,
            .outer = default_outer,
            .identity = identity,
            .native_state = null,
        });
        const inst_value: Value = .{ .Instance = inst };
        // A MODULE parent chain (`class MyApplier : AbstractApplier<T>(root)`)
        // binds its primary-param fields and runs its body-property inits
        // through the registered `$super$arg$<i>` thunks and the static
        // per-class init maps.
        if (try host_instances.initLocalParentChain(self, allocator, inst, inst_value, cls, cls_name, args)) |e| {
            return .{ .err = e };
        }
        // Interleave `init { … }` blocks (lowered as `$init$block$<idx>` anon
        // thunks at registration, with the enclosing scope's captured cells
        // bound) with the complex property initializers in declaration order.
        const n_props = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().body_properties.len;
        };
        var prop_idx: usize = 0;
        while (prop_idx < n_props) : (prop_idx += 1) {
            switch (try host_instances.runAnonInitBlocksAt(self, cls, cls_name, prop_idx, &inst_value, args)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            const pname: []const u8 = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().body_properties[prop_idx].name;
            };
            const is_delegate = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().body_properties[prop_idx].delegate != null;
            };
            const complex = is_delegate or blk: {
                const g = cls.borrow();
                defer g.deinit();
                const init_field = g.get().body_properties[prop_idx].init orelse break :blk false;
                break :blk simpleLiteral(allocator, init_field.get()) == null;
            };
            if (!complex) continue;
            const init_name = try std.fmt.allocPrint(allocator, "$init${s}", .{pname});
            defer allocator.free(init_name);
            const has = blk: {
                const key = try std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ cls_name, init_name });
                defer allocator.free(key);
                const ag = self.anon_methods.borrow();
                defer ag.deinit();
                break :blk ag.get().contains(key);
            };
            if (!has) continue;
            // Both delegate and plain-initializer thunks declare the primary
            // params so the expression can read plain ctor params — including
            // one the property itself shadows (`class N(property: String) {
            // var property = property }`). Pass the args, filling omitted
            // trailing params from their literal defaults.
            var eff_args: std.ArrayList(Value) = .empty;
            defer eff_args.deinit(allocator);
            {
                const g = cls.borrow();
                defer g.deinit();
                const pps = g.get().primary_params;
                for (pps, 0..) |*pp, ai| {
                    if (ai < args.len) {
                        try eff_args.append(allocator, args[ai]);
                    } else {
                        const dv: Value = if (pp.default) |e|
                            (simpleLiteral(allocator, e.get()) orelse Value.Null)
                        else
                            Value.Null;
                        try eff_args.append(allocator, dv);
                    }
                }
            }
            const thunk_args: []const Value = eff_args.items;
            switch (try host_call_member.callMember(self, allocator, &inst_value, init_name, thunk_args)) {
                .ok => |rv| {
                    const ig = inst.borrowMut();
                    defer ig.deinit();
                    if (is_delegate) {
                        try ig.get().define(allocator, pname, rv);
                    } else {
                        _ = ig.get().set(pname, rv);
                    }
                },
                .err => |e| return .{ .err = e },
            }
        }
        switch (try host_instances.runAnonInitBlocksAt(self, cls, cls_name, n_props, &inst_value, args)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
        return .{ .ok = inst_value };
    }
    // Invoking a `Value::PropertyRef` (`::name`). A callable reference
    // to a top-level function (`::tag`) calls that function with the
    // args — preferred over the property reading, since a default-arg
    // thunk lowered before the function was registered records the
    // reference as a `PropertyRef` rather than a `LoadGlobal`. A
    // genuine property reference (`::prop`) invoked with one arg reads
    // the named field from that arg (`KProperty1.get(receiver)`).
    if (callee.* == .PropertyRef) {
        const name = blk: {
            const g = callee.PropertyRef.name.borrow();
            defer g.deinit();
            break :blk g.get().bytes;
        };
        const is_fn = blk: {
            {
                const mg = self.module.borrow();
                defer mg.deinit();
                if (mg.get().hasFuncNamed(name)) break :blk true;
            }
            if (host_globals.lookupGlobal(self, name)) |g| {
                break :blk (g == .IrClosure);
            }
            break :blk false;
        };
        if (is_fn) {
            if (host_globals.lookupGlobal(self, name)) |callable| {
                return callValue(self, allocator, &callable, args);
            }
        }
        if (args.len == 1) {
            return host_fields.getField(self, allocator, &args[0], name);
        }
    }
    // Bound method/property reference: synthetic instance
    // carrying a receiver + method name. Invocation forwards
    // through the captured receiver (or reads the property on
    // the first arg for unbound property refs).
    if (callee.* == .Instance) {
        var recv: ?Value = null;
        var name_v: ?Value = null;
        {
            const snap = callee.Instance.borrow();
            defer snap.deinit();
            recv = snap.get().get("__bound_receiver__");
            name_v = snap.get().get("__bound_name__");
        }
        if (recv != null and name_v != null and name_v.? == .String) {
            const rv = recv.?;
            const name = blk: {
                const g = name_v.?.String.borrow();
                defer g.deinit();
                break :blk g.get().bytes;
            };
            var ref_pushed = false;
            var ref_prev: ?ir.eval.RefSiteOverride = null;
            if (host_call_member.boundRefFile(callee)) |bf| {
                ref_prev = ir.eval.pushRefSiteFile(bf);
                ref_pushed = true;
            }
            defer if (ref_pushed) ir.eval.popRefSiteFile(ref_prev);
            if (rv == .Class and args.len == 1) {
                return host_fields.getField(self, allocator, &args[0], name);
            }
            return host_call_member.callMember(self, allocator, &rv, name, args);
        }
    }
    if (callee.* == .IrClosure) {
        const id = callee.IrClosure.id;
        const captures = callee.IrClosure.captures;
        // Closure id indexes the closure table.
        const info = self.closures.get(@intCast(id)) orelse {
            const msg = try std.fmt.allocPrint(allocator, "unknown IrClosure id {d}", .{id});
            return .{ .err = .{ .Type = msg } };
        };
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        // A closure created inside a sub-module-lowered body resolves its
        // `FuncId` against that sub-module, never the main func table.
        const module = info.module orelse module_ref.asPtr();
        const func = module.funcById(info.body_func) orelse {
            const msg = try std.fmt.allocPrint(allocator, "closure body FuncId {d} out of range", .{info.body_func.int()});
            return .{ .err = .{ .Type = msg } };
        };
        // Compose-plugin arg completion: a pass-threaded composable value
        // invoked through a TYPELESS route (`arr[i]()`, forEach's `it()`)
        // has no static site the pass could append the pair to — kotlinc
        // knows the value's `@Composable` fn type, the interpreter only
        // sees the value. When the closure's protocol wants exactly the
        // trailing `($composer, $changed)` more than the call supplied and
        // a composer is ambient, complete the pair and re-enter, exactly
        // as the type-directed emission would have.
        // A pair-tailed composable local fn called WITH the pair but fewer
        // user args than declared (`useA()` lowered as useA($composer,
        // $changed) against `useA(a: A = A(), $composer, $changed)`): keep
        // the pair in the trailing slots and fill the defaulted gap from
        // the registered local-fn default thunks — positional Null-padding
        // shoved the composer into `a` and the changed flags into
        // `$composer`.
        if (func.params.len >= 2 and
            args.len >= 2 and args.len < info.n_params and
            std.mem.eql(u8, func.params[func.params.len - 1].name, "$changed") and
            std.mem.eql(u8, func.params[func.params.len - 2].name, "$composer") and
            args[args.len - 1] == .Int and args[args.len - 2] == .Instance and blk: {
            const ig = args[args.len - 2].Instance.borrow();
            defer ig.deinit();
            const cg = ig.get().class.borrow();
            defer cg.deinit();
            break :blk std.mem.indexOf(u8, cg.get().name, "Composer") != null;
        }) {
            const n_user = args.len - 2;
            var re: std.ArrayList(Value) = .empty;
            defer re.deinit(allocator);
            try re.appendSlice(allocator, args[0..n_user]);
            const dslots: ?[]const ?FuncId = dblk: {
                const mg2 = self.module.borrow();
                defer mg2.deinit();
                if (mg2.get().registry.local_fn_defaults.get(info.body_func)) |slots| break :dblk slots.items;
                break :dblk null;
            };
            var gap_i: usize = n_user;
            while (gap_i < info.n_params - 2) : (gap_i += 1) {
                var filled = false;
                if (dslots) |slots| {
                    if (gap_i < slots.len) {
                        if (slots[gap_i]) |dfid| {
                            switch (try self.callFunc(allocator, module, dfid, re.items[0..gap_i])) {
                                .ok => |dv| {
                                    try re.append(allocator, dv);
                                    filled = true;
                                },
                                .err => |e| return .{ .err = e },
                            }
                        }
                    }
                }
                if (!filled) try re.append(allocator, .Null);
            }
            try re.append(allocator, args[args.len - 2]);
            try re.append(allocator, args[args.len - 1]);
            return callValue(self, allocator, callee, re.items);
        }
        if (func.params.len >= 2 and
            args.len + 2 == info.n_params and
            std.mem.eql(u8, func.params[func.params.len - 1].name, "$changed") and
            std.mem.eql(u8, func.params[func.params.len - 2].name, "$composer"))
        {
            if (compose.currentComposer()) |comp| {
                const buf = try allocator.alloc(Value, args.len + 2);
                defer allocator.free(buf);
                @memcpy(buf[0..args.len], args);
                buf[args.len] = comp;
                buf[args.len + 1] = .{ .Int = 0 };
                return callValue(self, allocator, callee, buf);
            }
        }
        // One executable form per symbol: when the wrapped top-level fn's
        // single form was resolved to a native binding at link time
        // (e.g. a closure-of `kotlinx.datetime.__kxdt_*`), dispatch that
        // binding instead of running the shim placeholder body. The form
        // was settled once by `linkResolvedForms`; this consults it by
        // `FuncId` with no per-call FQN probe. Link tables are keyed by
        // main-module ids, so sub-module closures never consult them.
        if (info.module == null) {
            host_call_func.linkAuditCheck(self, module, func.id, func, args);
            if (host_call_func.resolvedNativeForm(self, func.id)) |intrinsic| {
                return dispatchIntrinsic(self, func.fqn, intrinsic, args);
            }
            // A closure published for an OVERLOADED top-level name carries
            // only ONE signature (first-wins). A call its arity cannot bind
            // belongs to a same-name sibling (a same-file private 3-arg
            // published over the public 2-arg overload in another file);
            // padding it with Nulls runs the wrong body. Re-rank the full
            // same-name set through the overload binder.
            // The SOURCE-level simple name: a file-private top-level fn is
            // registered under a per-file rename (`over$f220`); its overload
            // siblings live under the plain name.
            const src_name = blk: {
                const n = func.name;
                const i = std.mem.lastIndexOfScalar(u8, n, '$') orelse break :blk n;
                if (i + 2 > n.len or n[i + 1] != 'f') break :blk n;
                for (n[i + 2 ..]) |c| {
                    if (!std.ascii.isDigit(c)) break :blk n;
                }
                break :blk n[0..i];
            };
            const sibling_count = module.funcsBySimpleName(src_name).len +
                @intFromBool(src_name.len != func.name.len);
            // A LOCAL fn's defaults live only as registered thunks — its
            // lowered params carry no `has_default` flag and it has no
            // DeclSig — so `globalArityCanBind` under-counts and the
            // sibling redirect stole `check(1)` on a local
            // `check(a, b = 5)` for `kotlin.check`. The same thunk table
            // `padArgsWithDefaults` pads from decides bindability here.
            const binds_with_defaults = blk: {
                if (module.globalArityCanBind(func.id, func, args.len)) break :blk true;
                const pg = self.prog.borrow();
                defer pg.deinit();
                const defs = pg.get().func_defaults.get(func.id.int()) orelse break :blk false;
                var required: usize = 0;
                var has_vararg = false;
                for (func.params, 0..) |p, i| {
                    if (p.is_vararg) {
                        has_vararg = true;
                        continue;
                    }
                    const has_thunk = i < defs.len and defs[i] != null;
                    if (!has_thunk) required += 1;
                }
                break :blk args.len >= required and (has_vararg or args.len <= func.params.len);
            };
            if (args.len != info.n_params and info.capture_names.len == 0 and
                !binds_with_defaults and
                sibling_count > 1)
            {
                if (module.funcsBySimpleName(src_name).len > 1) {
                    switch (try host_call_func.callNamedOverload(self, allocator, module, null, src_name, args, &.{}, null, false, func.package, null, "")) {
                        .ok => |maybe| if (maybe) |v2| return .{ .ok = v2 },
                        .err => |e| return .{ .err = e },
                    }
                }
                // A single plain-named sibling of a renamed file-private fn:
                // dispatch it directly when the arity fits.
                for (module.funcsBySimpleName(src_name)) |sib_id| {
                    if (sib_id.int() == func.id.int()) continue;
                    const sib = module.funcById(sib_id) orelse continue;
                    if (!sib.hasBody()) continue;
                    if (!module.globalArityCanBind(sib_id, sib, args.len)) continue;
                    return self.callFunc(allocator, module, sib_id, args);
                }
            }
        }
        if (callValueTraceOn() and args.len < info.n_params) {
            std.debug.print("[callvalue-short] id={d} fn={s} args={d} params={d} recv_shape={}/{} caller={s}\n", .{
                id,
                func.fqn,
                args.len,
                info.n_params,
                info.receiver_shape_known,
                info.has_receiver,
                if (ir.eval.currentFrameFunc()) |cf| cf.fqn else "<none>",
            });
        }
        // Value-style invocation of a receiver lambda
        // (`block.invoke(receiver, p)` / `block(receiver, p)` for a
        // `R.(P) -> T`): the lambda's value params are `[p]`, so being
        // called with exactly one *extra* leading arg means arg0 is the
        // extension receiver when the lowered callable explicitly carries
        // receiver shape. Bind it into the closure's `this` capture
        // and re-run on this same (main-evaluator) path — which snapshots
        // frames so a suspension inside the body (`delay`) parks
        // correctly, unlike the intrinsic-host invoke. The body resolves
        // its receiver through the `this` capture slot
        // (`func.capture_order`), so overriding the closure value's
        // captures (not the side-table `info.captures`, which this path
        // ignores) is what reaches the evaluator. Valid Kotlin never
        // over-supplies a non-receiver lambda, and receiver-ness is never
        // inferred from a `this` capture (which may instead be lexical).
        // Vararg targets (legitimately variadic) are excluded.
        // ANY vararg param (not only a final one): a variadic function
        // legitimately takes more arguments than its parameter count, so the
        // receiver-overflow inference below must never consume its first
        // argument (`report("A", 1, 2, 3)` on `(title, vararg items,
        // footer = …)` lost "A" to a phantom receiver).
        const last_vararg = blk: {
            for (func.params) |*p| {
                if (p.is_vararg) break :blk true;
            }
            break :blk false;
        };
        const this_cap_idx: ?usize = blk: {
            for (info.capture_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, "this")) break :blk i;
            }
            break :blk null;
        };
        // A pass-wrapped composable block loses its receiver shape when the
        // compose pass moves the literal into `composableLambdaInstance(...)`
        // (the wrapper's param carries no function type for the lowering to
        // read). The compose ABI is the one caller of such a block with an
        // extra leading arg (`ComposableLambdaImpl.invoke(p1, c, changed)`
        // feeding an `R.()` block), so a pair-tailed closure with a `this`
        // capture infers the receiver there; padding the receiver into the
        // `$composer` slot is never right.
        const pair_tailed =
            func.params.len >= 2 and
            std.mem.eql(u8, func.params[func.params.len - 1].name, "$changed") and
            std.mem.eql(u8, func.params[func.params.len - 2].name, "$composer");
        const compose_recv_infer = !info.receiver_shape_known and
            this_cap_idx != null and pair_tailed;
        // Receiver-first shapes: the full one (`f(recv, a…)` with every
        // declared param supplied) and the pair-less composable one
        // (`content.item(itemScope, i)` against `(index, $composer,
        // $changed)`) — the recursion below re-enters `callValue` on
        // `args[1..]`, whose ambient-composer completion supplies the pair.
        const recv_first_shape = args.len == info.n_params + 1 or
            (pair_tailed and args.len + 2 == info.n_params + 1);
        // Shape UNKNOWN (a handler stored through a generic hook slot —
        // ktor's `on(Send)` block replayed as `handler(Sender(…), request)`)
        // with one arg MORE than the declared params can only be the
        // explicit-receiver form: Kotlin function types with and without
        // receivers are interchangeable, and no legal call supplies a plain
        // closure an extra argument. A HEADERLESS block is excluded — its
        // lone param is the lowering's speculative `it`, and a suspend
        // lambda's start supplies (receiver, completion), which this split
        // would corrupt by feeding the completion into `it`.
        const unknown_recv_infer = !info.receiver_shape_known and
            args.len == info.n_params + 1 and
            !(func.params.len != 0 and std.mem.eql(u8, func.params[0].name, "it"));
        if ((info.has_receiver or compose_recv_infer or unknown_recv_infer) and !last_vararg and recv_first_shape) {
            if (runtime.envOnce("KLIO_REBIND_AUDIT") != null) {
                std.debug.print("[REBIND] fn={s} n_params={d}\n", .{ func.name, info.n_params });
            }
            // A receiver lambda need not read its receiver. Such a body has
            // no `this` capture, but the leading receiver argument must still
            // be removed before its value parameters are bound.
            if (this_cap_idx == null) {
                const receiver = args[0];
                const pushed = receiver == .Instance or receiver == .Null;
                if (pushed) host_call_member.pushAccessEnclosingSubject(self, &receiver);
                const r = try callValue(self, allocator, callee, args[1..]);
                if (pushed) host_call_member.popAccessEnclosing(self);
                return r;
            }
            const this_idx = this_cap_idx.?;
            // The closure's captured `this` (before the explicit
            // receiver overrides it) is the lexically-enclosing
            // receiver the body closed over — e.g. ktor's engine
            // interceptor lambda closes over `this@install` (the
            // `HttpClientEngine`) yet is invoked by the pipeline as
            // `interceptor.invoke(pipelineContext, subject)`. Push it
            // as an enclosing receiver so the body can still resolve
            // the engine's members, mirroring `invoke_callable_with_this`.
            const prior_this: ?Value = blk: {
                const g = captures.borrow();
                defer g.deinit();
                const slice = g.get().*;
                if (this_idx < slice.len) break :blk slice[this_idx];
                break :blk null;
            };
            const bound = bnd: {
                var new_caps: std.ArrayList(Value) = .empty;
                {
                    const g = captures.borrow();
                    defer g.deinit();
                    try new_caps.appendSlice(allocator, g.get().*);
                }
                if (this_idx >= new_caps.items.len) {
                    try new_caps.appendNTimes(allocator, Value.Null, this_idx + 1 - new_caps.items.len);
                }
                new_caps.items[this_idx] = args[0];
                // The bound closure owns one ref to each capture (its teardown
                // releases them); the copied originals and the bound receiver
                // are borrows, so retain. No-op under the arena fast path.
                if (runtime.reclaimEnabled()) for (new_caps.items) |c| c.retain();
                const slice = try new_caps.toOwnedSlice(allocator);
                const caps_ref = try ValueSlice.init(allocator, slice);
                break :bnd Value{ .IrClosure = .{ .id = id, .captures = caps_ref } };
            };
            const rest = args[1..];
            const pushed_outer = po: {
                const a0 = args[0];
                if (prior_this == null) break :po false;
                const pt = prior_this.?;
                if (pt == .Null or pt == .Unit) break :po false;
                if (pt == .Instance and a0 == .Instance) {
                    break :po !ObjRef(InstanceData).ptrEq(pt.Instance, a0.Instance);
                }
                break :po true;
            };
            if (pushed_outer) {
                if (prior_this) |p| host_call_member.pushAccessEnclosing(self, &p);
            }
            const pushed_receiver = args[0] == .Instance;
            if (pushed_receiver) {
                host_call_member.pushAccessEnclosingSubject(self, &args[0]);
            }
            const r = try callValue(self, allocator, &bound, rest);
            if (pushed_receiver) host_call_member.popAccessEnclosing(self);
            if (pushed_outer) host_call_member.popAccessEnclosing(self);
            return r;
        }
        // Fill missing positional args from the target's
        // registered default-arg thunks (an implicit-`it` lambda
        // invoked with zero args still gets its slot as Null).
        // Pack trailing vararg args into an Array when the
        // target's last param is marked vararg. The defaults table is
        // keyed by main-module ids, so sub-module closures skip it.
        const defaults: ?[]?FuncId = blk: {
            if (info.module != null) break :blk null;
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().func_defaults.get(info.body_func.int());
        };
        // Trailing-lambda rule for a value call: `f { … }` where `f`'s last
        // parameter is function-typed and the omitted leading parameters are
        // defaulted (e.g. `runBlocking(context = …) { block }`) binds the
        // lambda to the LAST parameter, not the first. Without this the
        // closure lands in `context` and a later `context[Key]` misdispatches.
        var call_args = blk: {
            const np = info.n_params;
            if (np >= 2 and args.len < np and args.len > 0 and func.params.len >= np) {
                const last_p = &func.params[np - 1];
                if (root.isFunctionType(&last_p.ty) and root.valueIsCallable(&args[args.len - 1])) {
                    const leading = args[0 .. args.len - 1];
                    var ca = switch (try padArgsWithDefaults(self, allocator, module_ref, np, leading, defaults)) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    ca.items[np - 1] = args[args.len - 1];
                    break :blk ca;
                }
            }
            break :blk switch (try padArgsWithDefaults(self, allocator, module_ref, info.n_params, args, defaults)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
        };
        // Non-final vararg (Kotlin allows `vararg` before a trailing
        // function param): positionally, the declared params AFTER the
        // vararg take the LAST args and everything between the fixed
        // prefix and them packs into the vararg's Array. The static call
        // path binds this shape through the reorder-aware binder; a value
        // call must bind it identically.
        nonfinal: {
            if (func.params.len < 2) break :nonfinal;
            var vi: usize = func.params.len;
            for (func.params, 0..) |*pp, i| {
                if (pp.is_vararg) {
                    vi = i;
                    break;
                }
            }
            if (vi >= func.params.len - 1) break :nonfinal;
            // A post-vararg param claims a positional tail arg only when it
            // cannot default (a generated slot-exact call) or through
            // trailing-lambda syntax; a defaulted tail (`footer: String =
            // "end"`) never claims one — `report("A", 1, 2, 3)` packs all
            // three ints and the footer defaults. Mirrors the reorder-aware
            // named binder's rule.
            const trailing = blk: {
                const tail_defaults: ?[]?FuncId = dblk: {
                    const pg = self.prog.borrow();
                    defer pg.deinit();
                    break :dblk pg.get().func_defaults.get(func.id.int());
                };
                const last_idx = func.params.len - 1;
                const lambda_claim = std.mem.startsWith(u8, func.params[last_idx].ty.name, "Function") and
                    args.len > 0 and
                    (args[args.len - 1] == .IrClosure or
                        args[args.len - 1] == .BoundMethod);
                var n: usize = 0;
                for (vi + 1..func.params.len) |j| {
                    const has_default = tail_defaults != null and j < tail_defaults.?.len and tail_defaults.?[j] != null;
                    if (!has_default or (j == last_idx and lambda_claim)) n += 1;
                }
                break :blk n;
            };
            if (trailing == 0) {
                if (args.len > vi and !(args.len == vi + 1 and args[vi] == .Array)) {
                    var packed_args: std.ArrayList(Value) = .empty;
                    try packed_args.appendSlice(allocator, args[vi..]);
                    const items = try ValueList.init(allocator, packed_args);
                    var prefix: std.ArrayList(Value) = .empty;
                    defer prefix.deinit(allocator);
                    try prefix.appendSlice(allocator, args[0..vi]);
                    try prefix.append(allocator, runtime.ArrayData.fromBoxedList(items));
                    call_args.deinit(allocator);
                    call_args = switch (try padArgsWithDefaults(self, allocator, module_ref, info.n_params, prefix.items, defaults)) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                }
                break :nonfinal;
            }
            if (args.len < vi + trailing) break :nonfinal;
            const var_count = args.len - vi - trailing;
            if (var_count == 1 and args[vi] == .Array) break :nonfinal;
            var packed_args: std.ArrayList(Value) = .empty;
            try packed_args.appendSlice(allocator, args[vi .. vi + var_count]);
            const items = try ValueList.init(allocator, packed_args);
            call_args.deinit(allocator);
            call_args = .empty;
            try call_args.appendSlice(allocator, args[0..vi]);
            try call_args.append(allocator, runtime.ArrayData.fromBoxedList(items));
            try call_args.appendSlice(allocator, args[vi + var_count ..]);
        }
        if (func.params.len != 0) {
            const last = func.params[func.params.len - 1];
            if (last.is_vararg and args.len > info.n_params) {
                var packed_args: std.ArrayList(Value) = .empty;
                const fixed = info.n_params -| 1;
                try packed_args.appendSlice(allocator, args[fixed..]);
                const items = try ValueList.init(allocator, packed_args);
                call_args.items[info.n_params - 1] = runtime.ArrayData.fromBoxedList(items);
            } else if (last.is_vararg and !(call_args.items.len != 0 and call_args.items[call_args.items.len - 1] == .Array)) {
                const fixed = info.n_params -| 1;
                var packed_args: std.ArrayList(Value) = .empty;
                if (args.len > fixed) {
                    try packed_args.appendSlice(allocator, args[fixed..]);
                }
                const items = try ValueList.init(allocator, packed_args);
                call_args.items[info.n_params - 1] = runtime.ArrayData.fromBoxedList(items);
            }
        }
        var capture_values: std.ArrayList(Value) = .empty;
        {
            const g = captures.borrow();
            defer g.deinit();
            try capture_values.appendSlice(allocator, g.get().*);
        }
        vmhost.emitPath(allocator, "call_value_closure", func.fqn, func.id, null, args);
        // A pass-threaded composable invoked as a value (a restart-scope
        // re-invocation is a positional closure call) must publish its
        // `$composer` argument as the ambient composer, exactly like the
        // named-call path: a `@Composable` property getter reached from the
        // body reads it via `__compose_currentComposer`.
        {
            if (compose.threadedComposerArgFor(func.fqn, func.params, call_args.items)) |c| {
                compose.pushComposer(c);
                defer compose.popComposer();
                return ir.eval.evalWithCapturesChained(VmHost, allocator, module, info.module, func, call_args, capture_values, info.chain, @intCast(id), self);
            }
        }
        return ir.eval.evalWithCapturesChained(VmHost, allocator, module, info.module, func, call_args, capture_values, info.chain, @intCast(id), self);
    }
    // `Comparator` is a `fun interface`: invoking it as a value
    // (`comparator(a, b)`) calls `compare`.
    if (callee.* == .Comparator and args.len == 2) {
        return self.callMember(allocator, callee, "compare", args);
    }
    if (runtime.envOnce("KLIO_ERR_TRACE") != null)
        std.debug.print("[callvalue-miss] callee={s} args={d}\n", .{ callee.typeFqn(), args.len });
    ir.eval.dumpFrameChainForDiag();
    const msg = try std.fmt.allocPrint(allocator, "Vm::call_value on `{s}`", .{callee.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

/// `callValueNamed` with explicit call-site type arguments preserved
/// through a deferred bare-call form. One consumer today: an unsigned
/// element-type argument coerces integral args before the intrinsic
/// (`arrayOf<ULong>(1u, 2u)` — the literal's default tag is UInt and
/// kotlinc types it by its expected type).
pub fn callValueNamedTyped(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8) Allocator.Error!EvalResult {
    if (type_args.len == 1 and args.len != 0) {
        const tn = type_args[0];
        const is_intrinsic_array = callee.* == .Intrinsic and std.mem.endsWith(u8, callee.Intrinsic.fqn, "arrayOf");
        if (is_intrinsic_array) {
            const kind: u2 = if (std.mem.eql(u8, tn, "ULong"))
                0
            else if (std.mem.eql(u8, tn, "UInt"))
                1
            else if (std.mem.eql(u8, tn, "UShort"))
                2
            else if (std.mem.eql(u8, tn, "UByte"))
                3
            else {
                return callValueNamed(self, allocator, callee, args, arg_names);
            };
            const retagged = try allocator.alloc(Value, args.len);
            defer if (runtime.freeScratch()) allocator.free(retagged);
            for (args, retagged) |v, *slot| {
                slot.* = if (v.asU64()) |u| switch (kind) {
                    0 => Value{ .ULong = u },
                    1 => Value{ .UInt = @truncate(u) },
                    2 => Value{ .UShort = @truncate(u) },
                    3 => Value{ .UByte = @truncate(u) },
                } else v;
            }
            return callValueNamed(self, allocator, callee, retagged, arg_names);
        }
    }
    return callValueNamed(self, allocator, callee, args, arg_names);
}

/// `callValueNamed` with the call site's member-fallback receiver as
/// dispatch context: a receiver-typed closure with no `this` capture
/// invoked bare (`block()` for an `R.() -> T` field/local inside a
/// spliced scope function) rides the receiver along as its innermost
/// subject so the body's member-extension dispatch sees it. The exact
/// arity and missing `this` slot guarantee no positional or capture
/// binding changes; every other callee shape dispatches as before.
pub fn callValueNamedRecvCtx(self: *VmHost, allocator: Allocator, callee: *const Value, recv: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    if (callee.* == .IrClosure and recv.* == .Instance) {
        if (self.closures.get(@intCast(callee.IrClosure.id))) |info| {
            var has_this = false;
            for (info.capture_names) |n| {
                if (std.mem.eql(u8, n, "this")) {
                    has_this = true;
                    break;
                }
            }
            // A RECEIVER LAMBDA invoked bare binds the call site's
            // implicit receiver through the invoke convention regardless
            // of its `this` capture: a `Box.(Int) -> Int` local called as
            // `add(n)` inside a Box scope runs against that scope's
            // receiver — the capture only holds the creation-site
            // leftover, values never carry receivers in Kotlin.
            const receiver_lambda = blk: {
                if (!has_this) break :blk false;
                const module_g = self.module.borrow();
                defer module_g.deinit();
                const m = info.module orelse module_g.get();
                const f = m.funcById(info.body_func) orelse break :blk false;
                break :blk f.lambda_receiver_ty != null;
            };
            if ((!has_this or receiver_lambda) and args.len == info.n_params) {
                if (runtime.envOnce("KLIO_CVNRC") != null) {
                    const tn = blk: {
                        const g = recv.Instance.borrow();
                        defer g.deinit();
                        const cg = g.get().class.borrow();
                        defer cg.deinit();
                        break :blk cg.get().name;
                    };
                    std.debug.print("[cvnrc] id={d} recv={s}\n", .{ callee.IrClosure.id, tn });
                }
                return callValueWithThis(self, allocator, callee, recv, args, arg_names);
            }
        }
    }
    return callValueNamed(self, allocator, callee, args, arg_names);
}

pub fn callValueNamed(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    // A Class callee constructed with named arguments (e.g. a local class
    // `Box(bb = true)` that skips a defaulted parameter) must reorder + default-
    // fill; callValue constructs positionally and would shift values into the
    // wrong fields.
    if (callee.* == .Class) {
        var any_named = false;
        for (arg_names) |n| {
            if (n != null) {
                any_named = true;
                break;
            }
        }
        if (any_named) {
            const cls = callee.Class;
            const cls_name = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().name;
            };
            const cls_fqn = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().fqn;
            };
            // Same local-runtime guard as the positional arm: the def in
            // hand is the class; the index scan can only mis-resolve it.
            const is_local_runtime = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().is_local_runtime;
            };
            const class_id: ?ir.ClassId = if (is_local_runtime) null else blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                if (mg.get().classIdByFqn(cls_fqn)) |cid| break :blk cid;
                for (mg.get().class_index.items) |entry| {
                    if (std.mem.eql(u8, entry.name, cls_name)) break :blk entry.id;
                }
                break :blk null;
            };
            if (class_id) |cid| {
                return host_instances.newInstanceNamed(self, allocator, cid, args, arg_names, null);
            }
            // Local class (not in the module index): reorder named args and fill
            // literal defaults into a positional vector, then construct through
            // callValue's positional direct-allocation path.
            var positional: []Value = &.{};
            {
                const g = cls.borrow();
                defer g.deinit();
                const pp = g.get().primary_params;
                const n = pp.len;
                var reordered = try allocator.alloc(?Value, n);
                defer allocator.free(reordered);
                for (reordered) |*s| s.* = null;
                for (args, 0..) |v, i| {
                    if (i < arg_names.len and arg_names[i] != null) {
                        const nm = arg_names[i].?;
                        for (pp, 0..) |p, idx| {
                            if (std.mem.eql(u8, p.name, nm)) {
                                reordered[idx] = v;
                                break;
                            }
                        }
                    }
                }
                // A trailing positional callable binds the last ctor param
                // when it is still unfilled (`LocalClass(a = 1) { ... }`),
                // mirroring the fn-call trailing-lambda rule.
                var trailing_lambda: ?usize = null;
                if (args.len > 0 and n > 0) {
                    const last = args.len - 1;
                    const last_named = last < arg_names.len and arg_names[last] != null;
                    const last_p_fn_shaped = blk: {
                        const dt = pp[n - 1].declared_type orelse break :blk true;
                        break :blk std.mem.eql(u8, dt, "<function>") or std.mem.startsWith(u8, dt, "Function");
                    };
                    if (!last_named and last_p_fn_shaped and reordered[n - 1] == null and root.valueIsCallable(&args[last])) {
                        reordered[n - 1] = args[last];
                        trailing_lambda = last;
                    }
                }
                var next_pos: usize = 0;
                for (args, 0..) |v, i| {
                    if (i < arg_names.len and arg_names[i] != null) continue;
                    if (trailing_lambda != null and i == trailing_lambda.?) continue;
                    while (next_pos < n and reordered[next_pos] != null) next_pos += 1;
                    if (next_pos < n) {
                        reordered[next_pos] = v;
                        next_pos += 1;
                    }
                }
                positional = try allocator.alloc(Value, n);
                for (reordered, 0..) |slot, idx| {
                    positional[idx] = if (slot) |v|
                        v
                    else if (pp[idx].default) |e|
                        (simpleLiteral(allocator, e.get()) orelse Value.Null)
                    else
                        Value.Null;
                }
            }
            defer allocator.free(positional);
            return callValue(self, allocator, callee, positional);
        }
    }
    // A local function / lambda value (`IrClosure`) called with named arguments
    // that skip a defaulted parameter must reorder + default-fill against the
    // closure body's value parameters; callValue binds positionally and would
    // otherwise land a named arg in the wrong slot (`check(a, b, expectedMod = x)`
    // dropping `x` into `expectedFd`). Mirrors the direct-FuncId path in
    // callFuncNamed.
    if (callee.* == .IrClosure) {
        var any_named = false;
        for (arg_names) |n| {
            if (n != null) {
                any_named = true;
                break;
            }
        }
        if (any_named) {
            if (self.closures.get(@intCast(callee.IrClosure.id))) |info| {
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                const module = info.module orelse module_ref.asPtr();
                if (module.funcById(info.body_func)) |func| {
                    const np = info.n_params;
                    // Named args address the value parameters (`params[0..np]`);
                    // a vararg among them keeps the positional path below, whose
                    // callValue vararg packing is already correct.
                    var has_vararg = false;
                    for (func.params[0..@min(np, func.params.len)]) |p| {
                        if (p.is_vararg) {
                            has_vararg = true;
                            break;
                        }
                    }
                    if (np != 0 and func.params.len >= np and !has_vararg) {
                        const params = func.params[0..np];
                        var slots = try allocator.alloc(?Value, np);
                        defer allocator.free(slots);
                        for (slots) |*s| s.* = null;
                        // Bind named arguments to their declared slots.
                        for (args, 0..) |a, i| {
                            if (i < arg_names.len) {
                                if (arg_names[i]) |nm| {
                                    for (params, 0..) |p, pos| {
                                        if (std.mem.eql(u8, p.name, nm)) {
                                            slots[pos] = a;
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                        // A trailing positional callable binds to the last
                        // function-typed parameter, out of sequence, so the
                        // intervening defaulted parameters are not consumed
                        // by it (mirrors callFuncNamed's rule).
                        var trailing_lambda: ?usize = null;
                        if (args.len > 0) {
                            const last = args.len - 1;
                            const last_named = last < arg_names.len and arg_names[last] != null;
                            const last_param = np - 1;
                            if (!last_named and slots[last_param] == null and
                                root.isFunctionType(&params[last_param].ty) and root.valueIsCallable(&args[last]))
                            {
                                slots[last_param] = args[last];
                                trailing_lambda = last;
                            }
                        }
                        // Fill unnamed positional args into the remaining slots.
                        var pidx: usize = 0;
                        for (args, 0..) |a, i| {
                            const is_named = i < arg_names.len and arg_names[i] != null;
                            if (is_named) continue;
                            if (trailing_lambda != null and i == trailing_lambda.?) continue;
                            while (pidx < np and slots[pidx] != null) pidx += 1;
                            if (pidx < np) {
                                slots[pidx] = a;
                                pidx += 1;
                            }
                        }
                        // Materialize a full positional vector, evaluating each
                        // omitted slot's default-arg thunk (holes as well as the
                        // tail). Keyed by main-module ids, so a sub-module closure
                        // has no defaults table.
                        const defaults: ?[]?FuncId = blk: {
                            if (info.module != null) break :blk null;
                            const pg = self.prog.borrow();
                            defer pg.deinit();
                            break :blk pg.get().func_defaults.get(info.body_func.int());
                        };
                        var positional: std.ArrayList(Value) = .empty;
                        defer positional.deinit(allocator);
                        for (slots, 0..) |slot, i| {
                            if (slot) |v| {
                                try positional.append(allocator, v);
                                continue;
                            }
                            const dfid: ?FuncId = if (defaults) |d| (if (i < d.len) d[i] else null) else null;
                            if (dfid) |fid| {
                                const dfunc = module.funcById(fid) orelse {
                                    const msg = try std.fmt.allocPrint(allocator, "default-arg FuncId {d} out of range", .{fid.int()});
                                    return .{ .err = .{ .Type = msg } };
                                };
                                // Seed the first bound arg as a capture so a
                                // receiver-referencing default thunk resolves,
                                // mirroring padArgsWithDefaults.
                                var captures: std.ArrayList(Value) = .empty;
                                if (positional.items.len != 0) {
                                    try captures.append(allocator, positional.items[0]);
                                }
                                var args_copy: std.ArrayList(Value) = .empty;
                                try args_copy.appendSlice(allocator, positional.items);
                                const r = try ir.eval.evalWithCaptures(VmHost, allocator, module, dfunc, args_copy, captures, self);
                                switch (r) {
                                    .ok => |v| try positional.append(allocator, v),
                                    .err => |e| return .{ .err = e },
                                }
                            } else {
                                try positional.append(allocator, Value.Null);
                            }
                        }
                        return callValue(self, allocator, callee, positional.items);
                    }
                }
            }
        }
    }
    return callValue(self, allocator, callee, args);
}

/// Whether a closure's DECLARED value-parameter types definitely refute
/// the runtime arguments (arity aside — a mismatch there is handled by
/// binding). Used by `CallValueOrMember`: a captured local fn whose
/// params refute the args is not the target, so the call falls to the
/// same-named enclosing member (Kotlin picked the member overload).
pub fn closureParamsDisproven(self: *VmHost, callee: *const Value, args: []const Value) bool {
    var v = callee.*;
    if (v == .Cell) {
        const cg = v.Cell.borrow();
        v = cg.get().*;
        cg.deinit();
    }
    if (v != .IrClosure) return false;
    const info = self.closures.get(@intCast(v.IrClosure.id)) orelse return false;
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const module = info.module orelse module_ref.asPtr();
    const func = module.funcById(info.body_func) orelse return false;
    const np = @min(info.n_params, func.params.len);
    for (func.params[0..np], 0..) |*p, i| {
        if (i >= args.len) break;
        if (p.is_vararg) continue;
        if (host_call_member.argDefinitelyNotParamType(self, &p.ty, &args[i])) return true;
        // An array argument on a definite non-array builtin param is a
        // mismatch the shared helper declines to adjudicate (vararg /
        // spread ambiguity); a declared non-vararg scalar param is safe.
        if (args[i] == .Array) {
            if (overload_match.builtinParamKind(overload_match.simpleName(p.ty.name))) |pk| {
                if (pk != .array) return true;
            }
        }
    }
    return false;
}

pub fn callValueWithThis(self: *VmHost, allocator: Allocator, callee: *const Value, this_value_in: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return callValueWithThisSel(self, allocator, callee, this_value_in, args, arg_names, true);
}

/// `callValueWithThis` with the receiver re-selected by the DECLARED head
/// the call site carried (a receiver-lambda param's declared receiver
/// type). The passed register can be a coroutine that rebound the
/// enclosing block's `this` capture; Kotlin binds the innermost implicit
/// receiver OF THE DECLARED TYPE. Re-selection already applied, so the
/// compatibility resel stays off.
pub fn callValueWithThisHead(self: *VmHost, allocator: Allocator, callee: *const Value, this_value_in: *const Value, args: []const Value, arg_names: []const ?[]const u8, head: []const u8) Allocator.Error!EvalResult {
    var selected = this_value_in.*;
    if (head.len != 0) {
        if (try host_call_member.implicitReceiverForHead(self, allocator, this_value_in, head)) |m| selected = m;
    }
    if (runtime.envOnce("KLIO_HEAD_TRACE") != null)
        std.debug.print("[cvth] head={s} passed={s} selected={s}\n", .{ head, this_value_in.typeFqn(), selected.typeFqn() });
    return callValueWithThisSel(self, allocator, callee, &selected, args, arg_names, false);
}

/// `callValueWithThis` with the compatibility receiver RE-SELECTION gated:
/// a caller that PROVED the receiver (the lowering's
/// fallback_takes_receiver contract) passes `allow_resel = false` — the
/// recorded receiver head can be WRONG (a placement block nested in a
/// measure lambda carried the enclosing "MeasureScope" head, and
/// re-selection swapped the real PlacementScope for the coordinator), and
/// an explicitly supplied receiver is authoritative.
pub fn callValueWithThisSel(self: *VmHost, allocator: Allocator, callee: *const Value, this_value_in: *const Value, args: []const Value, arg_names: []const ?[]const u8, allow_resel: bool) Allocator.Error!EvalResult {
    _ = arg_names;
    var selected_this = this_value_in.*;
    if (allow_resel and callee.* == .IrClosure) {
        const id = callee.IrClosure.id;
        if (self.closures.get(@intCast(id))) |info| {
            const module_g = self.module.borrow();
            defer module_g.deinit();
            const m = info.module orelse module_g.get();
            if (m.funcById(info.body_func)) |f| {
                if (f.lambda_receiver_ty) |head| {
                    if (try host_call_member.implicitReceiverForHead(self, allocator, this_value_in, head)) |matched| {
                        selected_this = matched;
                    }
                    if (rselTraceOn()) {
                        std.debug.print("[rsel] head={s} passed={s} selected={s}\n", .{ head, this_value_in.typeFqn(), selected_this.typeFqn() });
                    }
                }
            }
        }
    }
    const this_value = &selected_this;
    // A receiver-lambda's receiver (`with(r) { … }`, `r.apply { … }`) is an
    // implicit receiver, hence a context-argument source for a contextual
    // callee inside the block. Feed it into the context stack for the
    // block's duration; the push unwinds on every return path.
    const ctx_mark = self.ctxStackLen();
    defer self.ctxStackTruncate(ctx_mark);
    if (self.ctxIsActive()) self.ctxPush(this_value.*) catch {};
    // Explicit-receiver receiver-lambda call (`block(receiver, p)` for a
    // `R.(P) -> T`, exactly one extra leading arg): bind `this_value`
    // into the `this` capture as a fallback and dispatch on the MAIN
    // evaluator path (`call_value`). That path applies the receiver-split
    // — arg0 is the explicit receiver and overrides `this` — and snapshots
    // frames so a suspension inside a `suspend` body parks correctly. The
    // intrinsic-host invoke below does neither, which strands a captured
    // receiver-lambda call such as ktor's on(Send) handler
    // `handler(Sender(this, …), request)` (the body's bare `proceed`
    // resolves against the receiver only when it reaches the body as the
    // closure's `this`).
    if (callee.* == .IrClosure) {
        const id = callee.IrClosure.id;
        const captures = callee.IrClosure.captures;
        if (self.closures.get(@intCast(id))) |info| {
            if (callValueTraceOn()) {
                const module_g = self.module.borrow();
                defer module_g.deinit();
                const m = info.module orelse module_g.get();
                const f = m.funcById(info.body_func);
                var prior_this: ?Value = null;
                var has_this_capture = false;
                for (info.capture_names, 0..) |capture_name, i| {
                    if (!std.mem.eql(u8, capture_name, "this")) continue;
                    has_this_capture = true;
                    const captures_g = captures.borrow();
                    defer captures_g.deinit();
                    if (i < captures_g.get().*.len) prior_this = captures_g.get().*[i];
                    break;
                }
                const prior_name = if (prior_this) |*v| host_call_member.debugClassNameOf(self, v) else "-";
                std.debug.print(
                    "[callvalue-this] id={d} fn={s} recv={s}/{s} prior={s}/{s} args={d} params={d} param0={s} shape_known={} shape_recv={} recv_ty={s} this_cap={}\n",
                    .{
                        id,
                        if (f) |func| func.fqn else "<unknown>",
                        host_call_member.debugClassNameOf(self, this_value),
                        @tagName(this_value.*),
                        prior_name,
                        if (prior_this) |v| @tagName(v) else "-",
                        args.len,
                        info.n_params,
                        if (f) |func| if (func.params.len != 0) func.params[0].name else "-" else "-",
                        info.receiver_shape_known,
                        info.has_receiver,
                        if (f) |func| func.lambda_receiver_ty orelse "-" else "-",
                        has_this_capture,
                    },
                );
            }
            // A named LOCAL FUNCTION lowers as a closure but is not a
            // receiver lambda: the caller's `this` reaches its body
            // lexically (captures), never as an argument. The
            // receiver-binding heuristics below would corrupt its
            // positional args (a `vararg values + trailing lambda`
            // local fn got the test instance spliced in). Dispatch it
            // as a plain value call.
            {
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                const module = info.module orelse module_ref.asPtr();
                if (module.funcById(info.body_func)) |bf| {
                    const takes_receiver = bf.params.len != 0 and std.mem.eql(u8, bf.params[0].name, "this");
                    // …unless the reference is being INVOKED as a
                    // receiver-function: a `::localFn` value in a
                    // `T.() -> R` slot declares exactly one parameter more
                    // than the call supplies, and the receiver fills it
                    // (`obj.allSubFormatsNegative()` is
                    // `checkIfAllNegative(obj)`). Dropping the receiver
                    // there passed the body a null argument.
                    const receiver_fills_slot = bf.params.len == args.len + 1;
                    if (!std.mem.eql(u8, bf.name, "<lambda>") and !takes_receiver and
                        !receiver_fills_slot)
                    {
                        return callValue(self, allocator, callee, args);
                    }
                    // A pass-threaded composable lambda declaring one param
                    // MORE than the call supplies, with no leading `this`
                    // param, takes the bound receiver as that leading
                    // positional slot regardless of its captures — the compose
                    // pass flattens a composable `R.() -> T` literal's
                    // receiver into exactly this shape
                    // (`[it, $composer, $changed]`). Binding the receiver into
                    // a `this` capture instead leaves the params one short and
                    // shifts the composer pair left. The trailing pair is the
                    // discriminator: a plain headerless lambda lowered with a
                    // speculative `it` (an `apply { }` block) has no pair, and
                    // its receiver must keep binding through the `this`
                    // capture below. Keep the receiver reachable as the
                    // innermost subject so the body's bare member calls still
                    // dispatch against it.
                    const pass_threaded = bf.params.len >= 3 and
                        std.mem.eql(u8, bf.params[bf.params.len - 2].name, "$composer") and
                        std.mem.eql(u8, bf.params[bf.params.len - 1].name, "$changed");
                    if (std.mem.eql(u8, bf.name, "<lambda>") and !takes_receiver and
                        pass_threaded and args.len + 1 == info.n_params)
                    {
                        if (callValueTraceOn()) {
                            std.debug.print("[recv-fill] id={d} params={d} args={d} caller={s}\n", .{
                                id, info.n_params, args.len,
                                if (ir.eval.currentFrameFunc()) |cf| cf.fqn else "<none>",
                            });
                        }
                        const with_recv = try allocator.alloc(Value, args.len + 1);
                        defer if (runtime.freeScratch()) allocator.free(with_recv);
                        with_recv[0] = this_value.*;
                        @memcpy(with_recv[1..], args);
                        const pushed = this_value.* == .Instance or this_value.* == .Null;
                        if (pushed) host_call_member.pushAccessEnclosingSubject(self, this_value);
                        const r = try callValue(self, allocator, callee, with_recv);
                        if (pushed) host_call_member.popAccessEnclosing(self);
                        return r;
                    }
                    // Shape UNKNOWN (a lambda stored through a generic-typed
                    // slot — ktor's `plugins[key] = { scope -> … }` map keeps
                    // no function shape) with one declared param MORE than
                    // the supplied args, and no adapted receiver-`this`
                    // leading param: the receiver rides positionally in that
                    // slot, whichever way the source spelled the block. A
                    // parameterless receiver lambda declares no extra param
                    // and keeps the receiver-binding path below — and so does
                    // a HEADERLESS block, whose lone param is the lowering's
                    // speculative `it` (an `apply { }` body reads `this`, not
                    // `it`; a source-written `{ it -> }` loses this call shape
                    // but a named parameter keeps it).
                    if (std.mem.eql(u8, bf.name, "<lambda>") and !takes_receiver and
                        !info.receiver_shape_known and args.len + 1 == info.n_params and
                        !(bf.params.len != 0 and std.mem.eql(u8, bf.params[0].name, "it")))
                    {
                        const with_recv = try allocator.alloc(Value, args.len + 1);
                        defer if (runtime.freeScratch()) allocator.free(with_recv);
                        with_recv[0] = this_value.*;
                        @memcpy(with_recv[1..], args);
                        const pushed = this_value.* == .Instance or this_value.* == .Null;
                        if (pushed) host_call_member.pushAccessEnclosingSubject(self, this_value);
                        const r = try callValue(self, allocator, callee, with_recv);
                        if (pushed) host_call_member.popAccessEnclosing(self);
                        return r;
                    }
                }
            }
            // Kotlin function types with and without receivers are
            // interchangeable: an ordinary `(R, P) -> T` closure used as
            // `R.(P) -> T` receives the call receiver as its first positional
            // argument. Its captured `this` remains the lexical receiver and
            // must not be rebound to `R`.
            if (info.receiver_shape_known and !info.has_receiver and args.len + 1 == info.n_params) {
                const with_recv = try allocator.alloc(Value, args.len + 1);
                defer if (runtime.freeScratch()) allocator.free(with_recv);
                with_recv[0] = this_value.*;
                @memcpy(with_recv[1..], args);
                return callValue(self, allocator, callee, with_recv);
            }
            const this_idx: ?usize = blk: {
                for (info.capture_names, 0..) |n, i| {
                    if (std.mem.eql(u8, n, "this")) break :blk i;
                }
                break :blk null;
            };
            if (this_idx) |idx| {
                // Two receiver-lambda shapes reach here, both dispatched on
                // the MAIN evaluator path (`call_value`) so a suspension
                // inside a `suspend` body snapshots frames and parks:
                //   * explicit-receiver call (`block(receiver, p)` for a
                //     `R.(P) -> T`): arg0 is the receiver and overrides
                //     `this`, the body's value params follow.
                //   * receiver-bound call (`recv.block()` where `block` is a
                //     `suspend R.() -> Unit` param/property): the receiver
                //     arrives via `this_value`, the body's value params are
                //     `args` unchanged.
                // The intrinsic-host invoke below does neither, which would
                // both strand a captured receiver-lambda's bare-member
                // resolution and flatten an `EvalError.Suspended` into a
                // "suspended outside a driver" runtime error.
                // One arg MORE than the declared params, on a closure that has a
                // genuine `this` capture (checked above): arg0 is the extension
                // receiver. This holds at zero params too — a `R.() -> T` field
                // invoked as `holder.block(r)` (Kotlin's `Function1<R, T>` form,
                // e.g. `getOrBuildCachedDrawBlock(this).block(this)`) supplies
                // its receiver positionally, and the value-call path
                // (`callValueRec`) already splits it that way.
                const explicit_receiver = info.has_receiver and args.len == info.n_params + 1;
                const receiver: Value = if (explicit_receiver) args[0] else this_value.*;
                const body_args: []const Value = if (explicit_receiver) args[1..] else args;

                // Bind the receiver into a fresh captures cell's `this` slot
                // (the evaluator reads the closure value's captures, not the
                // side-table). Snapshot the prior `this` to keep it reachable
                // as an enclosing receiver for the body's bare-member /
                // member-extension resolution.
                var new_caps: std.ArrayList(Value) = .empty;
                {
                    const g = captures.borrow();
                    defer g.deinit();
                    try new_caps.appendSlice(allocator, g.get().*);
                }
                const prior_this: ?Value = if (idx < new_caps.items.len) new_caps.items[idx] else null;
                if (idx >= new_caps.items.len) {
                    try new_caps.appendNTimes(allocator, Value.Null, idx + 1 - new_caps.items.len);
                }
                new_caps.items[idx] = receiver;
                // The bound closure owns one ref to each capture (its teardown
                // releases them); the copied originals and the bound receiver
                // are borrows, so retain. No-op under the arena fast path.
                if (runtime.reclaimEnabled()) for (new_caps.items) |c| c.retain();
                const slice = try new_caps.toOwnedSlice(allocator);
                const caps_ref = try ValueSlice.init(allocator, slice);
                const bound = Value{ .IrClosure = .{ .id = id, .captures = caps_ref } };

                // Keep the displaced prior `this` reachable as an outer
                // implicit receiver, and push the new receiver so a body
                // calling a member-extension declared on its class sees the
                // owner as visible — mirroring `invoke_callable_with_this`.
                const pushed_outer = po: {
                    const pt = prior_this orelse break :po false;
                    if (pt == .Null or pt == .Unit) break :po false;
                    if (pt == .Instance and receiver == .Instance) {
                        break :po !ObjRef(InstanceData).ptrEq(pt.Instance, receiver.Instance);
                    }
                    break :po true;
                };
                if (pushed_outer) {
                    if (prior_this) |p| host_call_member.pushAccessEnclosing(self, &p);
                }
                // A null subject is pushed too: it is a real receiver
                // candidate for nullable-receiver extensions
                // (`fun Thing?.show()` inside `with(t)` where `t == null`).
                const pushed_receiver = receiver == .Instance or receiver == .Null;
                if (pushed_receiver) {
                    host_call_member.pushAccessEnclosingSubject(self, &receiver);
                }
                const r = try callValue(self, allocator, &bound, body_args);
                if (pushed_receiver) host_call_member.popAccessEnclosing(self);
                if (pushed_outer) host_call_member.popAccessEnclosing(self);
                return r;
            }
            // No `this` capture: the receiver binds as the leading
            // declared `this` param when the body has one (a local
            // extension function lowered as a closure); otherwise the
            // body takes no receiver. Either way the call runs on the
            // MAIN evaluator path (the intrinsic invoke below flattens a
            // suspension into a hard error), with the receiver reachable
            // as the innermost subject for dispatch-time resolution.
            const takes_this_param = blk: {
                const module_g = self.module.borrow();
                defer module_g.deinit();
                const m = info.module orelse module_g.get();
                const f = m.funcById(info.body_func) orelse break :blk false;
                const fp = f.params;
                break :blk fp.len != 0 and std.mem.eql(u8, fp[0].name, "this");
            };
            // Explicit-receiver call shape on a body that never captured
            // `this` (`handler(Context(), a, b, c)` for a
            // `Context.(A, B, C) -> R` whose body reads no receiver
            // member): arg0 is the receiver, not a positional param —
            // split it off and keep it reachable as the innermost subject.
            if (info.has_receiver and !takes_this_param and args.len == info.n_params + 1) {
                const recv0 = args[0];
                const pushed = recv0 == .Instance or recv0 == .Null;
                if (pushed) host_call_member.pushAccessEnclosingSubject(self, &recv0);
                const r = try callValue(self, allocator, callee, args[1..]);
                if (pushed) host_call_member.popAccessEnclosing(self);
                return r;
            }
            // A plain `(T, …) -> R` lambda used where a `T.(…) -> R` is
            // expected declares one more positional param than the call
            // supplies; the receiver fills it (kotlinc: the receiver IS
            // the underlying function's first param).
            const recv_fills_param = !info.has_receiver and !takes_this_param and args.len + 1 == info.n_params;
            var all_args: std.ArrayList(Value) = .empty;
            defer all_args.deinit(allocator);
            if (takes_this_param or recv_fills_param) try all_args.append(allocator, this_value.*);
            try all_args.appendSlice(allocator, args);
            const pushed_receiver = this_value.* == .Instance or this_value.* == .Null;
            if (pushed_receiver) {
                host_call_member.pushAccessEnclosingSubject(self, this_value);
            }
            const r = try callValue(self, allocator, callee, all_args.items);
            if (pushed_receiver) host_call_member.popAccessEnclosing(self);
            return r;
        }
    }
    // A member-reference value (`Type::method`, `obj::method`) invoked
    // with an explicit receiver — an extension-function-typed parameter
    // (`sortDescending: TArray.(Int, Int) -> Unit` fed
    // `ULongArray::sortDescending`, then `array.sortDescending(from, to)`).
    // The explicit receiver dispatches the member walk with the args
    // passed through; the intrinsic-host fallback below drops them.
    if (callee.* == .Instance) {
        var name_v: ?Value = null;
        var bound_recv: ?Value = null;
        {
            const snap = callee.Instance.borrow();
            defer snap.deinit();
            name_v = snap.get().get("__bound_name__");
            bound_recv = snap.get().get("__bound_receiver__");
        }
        // A BOUND reference (`predicate::test` on an instance / object
        // singleton) already carries its receiver. Converted to a
        // receiver-function type (`T.() -> Boolean`), the supplied `this`
        // is its ARGUMENT — `obj.condition()` means `predicate.test(obj)`,
        // never `obj.test()`. A TYPE-form reference (`String::plus`) is
        // unbound and keeps the receiver-dispatch route below.
        if (name_v != null and name_v.? == .String) {
            if (bound_recv) |rv| {
                const name0 = blk: {
                    const g = name_v.?.String.borrow();
                    defer g.deinit();
                    break :blk g.get().bytes;
                };
                const type_like = (rv == .Class) or
                    (rv == .Instance and isCompanionInstance(rv) and
                        !companionServesName(self, &rv, name0));
                if (!type_like) {
                    var all: std.ArrayList(Value) = .empty;
                    defer all.deinit(allocator);
                    try all.append(allocator, this_value.*);
                    try all.appendSlice(allocator, args);
                    return callValue(self, allocator, callee, all.items);
                }
            }
        }
        if (name_v != null and name_v.? == .String) {
            const name = blk: {
                const g = name_v.?.String.borrow();
                defer g.deinit();
                break :blk g.get().bytes;
            };
            var ref_pushed = false;
            var ref_prev: ?ir.eval.RefSiteOverride = null;
            if (host_call_member.boundRefFile(callee)) |bf| {
                ref_prev = ir.eval.pushRefSiteFile(bf);
                ref_pushed = true;
            }
            defer if (ref_pushed) ir.eval.popRefSiteFile(ref_prev);
            const mr = try host_call_member.callMemberNamedStatic(
                self,
                allocator,
                this_value,
                name,
                args,
                &.{},
                boundReferenceStaticReceiver(callee),
            );
            // `JsonPrimitive::booleanOrNull` as a receiver function names
            // an EXTENSION property: no member takes the call, so the
            // reference reads the property on the supplied receiver.
            if (args.len == 0 and mr == .err and mr.err == .Unimplemented) {
                const pr = try host_fields.getField(self, allocator, this_value, name);
                if (pr == .ok) return pr;
            }
            return mr;
        }
    }
    var sink = self.out_sink.clone();
    defer sink.deinit();
    var intrinsic = makeIntrinsicHost(self);
    defer intrinsicHostDeinit(&intrinsic);
    var host = intrinsic.intrinsicHost();
    const r = try host.invokeCallableWithThis(callee, args, this_value, sink.output());
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| try runtimeErrToEval(allocator, e),
    };
}

/// Receiver-function invocation from an IR site whose declared callable shape
/// is known. A plain function adapted to a receiver type receives the receiver
/// positionally even when its body is a named local function; genuine receiver
/// lambdas keep the receiver-binding path.
pub fn callValueWithThisExact(self: *VmHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    if (callee.* == .IrClosure) {
        if (self.closures.get(@intCast(callee.IrClosure.id))) |info| {
            // Shape UNKNOWN (a lambda stored through a generic-typed slot —
            // ktor's `plugins[key] = { scope -> … }` map keeps no function
            // shape) falls back to the declared arity: a body declaring
            // exactly one more parameter than the supplied arguments wants
            // the receiver in that slot, whichever way the source spelled
            // it. A parameterless receiver lambda declares no extra param,
            // so it never matches — and a headerless block's lone
            // speculative `it` param keeps the receiver-binding path (see
            // callValueWithThisSel).
            const speculative_it = blk: {
                if (info.receiver_shape_known) break :blk false;
                const module_g = self.module.borrow();
                defer module_g.deinit();
                const m = info.module orelse module_g.get();
                const bf = m.funcById(info.body_func) orelse break :blk false;
                break :blk bf.params.len != 0 and std.mem.eql(u8, bf.params[0].name, "it");
            };
            const positional_fit = args.len + 1 == info.n_params and
                (info.receiver_shape_known and !info.has_receiver or
                    (!info.receiver_shape_known and !speculative_it));
            if (positional_fit) {
                const with_recv = try allocator.alloc(Value, args.len + 1);
                defer if (runtime.freeScratch()) allocator.free(with_recv);
                with_recv[0] = this_value.*;
                @memcpy(with_recv[1..], args);
                // The receiver rides positionally, but it is still the
                // block's innermost IMPLICIT receiver: publish it on the
                // enclosing chain so member-extension dispatch inside the
                // body sees its owner (`placeable.place(x, y)` inside a
                // `Placeable.PlacementScope.() -> Unit` placement block —
                // the owner-visibility set was missing the scope and every
                // window placement pass died on it).
                const push_subject = this_value.* == .Instance or this_value.* == .Null;
                if (push_subject) host_call_member.pushAccessEnclosingSubject(self, this_value);
                defer if (push_subject) host_call_member.popAccessEnclosing(self);
                return callValue(self, allocator, callee, with_recv);
            }
        }
    }
    return callValueWithThisSel(self, allocator, callee, this_value, args, arg_names, false);
}

pub fn buildClosure(self: *VmHost, allocator: Allocator, module: *const Module, body_func: FuncId, captures: []const Value) Allocator.Error!EvalResult {
    // Derive the lambda's param count + capture-name list from the body
    // func so `LoadCapture` reads the right snapshot per closure.
    var n_params: usize = 0;
    var receiver_shape_known = false;
    var has_receiver = false;
    var capture_names: [][]const u8 = &.{};
    if (module.funcById(body_func)) |f| {
        n_params = f.params.len;
        receiver_shape_known = f.lambda_receiver_shape_known;
        has_receiver = f.lambda_has_receiver;
        capture_names = try allocator.dupe([]const u8, f.capture_order);
    }
    // Canonical capture store for this closure (read by the HOF invoke
    // path). A captured `var` a nested closure writes is itself a shared
    // `Value.Cell` carried here, so its mutation is visible by reference.
    var cell_list: std.ArrayList(Value) = .empty;
    try cell_list.appendSlice(allocator, captures);
    const cell = try ObjRef(std.ArrayList(Value)).init(allocator, cell_list);
    const id = try self.closures.push(.{
        .body_func = body_func,
        .module = if (module == self.module.asPtr()) null else module,
        .n_params = n_params,
        .receiver_shape_known = receiver_shape_known,
        .has_receiver = has_receiver,
        .capture_names = capture_names,
        .captures = cell,
        .chain = try ir.eval.captureChainAlloc(allocator),
    });
    // The IrClosure owns one ref to each capture (its `release` recursively
    // frees them); the registry `cell` above is a non-owning view.
    if (runtime.reclaimEnabled()) for (captures) |c| c.retain();
    const caps_ref = try ValueSlice.init(allocator, try allocator.dupe(Value, captures));
    return .{ .ok = .{ .IrClosure = .{ .id = id, .captures = caps_ref } } };
}

pub fn buildAstLambdaWithFlagFuncid(self: *VmHost, allocator: Allocator, module: *const Module, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool, body_func: ?FuncId) Allocator.Error!EvalResult {
    _ = body;
    _ = absorb_return;
    const fid = body_func orelse return .{ .err = .{ .Unimplemented = "Vm: lambda lower did not provide body_func" } };
    // Canonical capture store for this closure (read by the HOF invoke
    // path). A captured `var` a nested closure writes is itself a shared
    // `Value.Cell` carried here, so its mutation is visible by reference.
    var cell_list: std.ArrayList(Value) = .empty;
    try cell_list.appendSlice(allocator, captures);
    const cell = try ObjRef(std.ArrayList(Value)).init(allocator, cell_list);
    var chain = try ir.eval.captureChainAlloc(allocator);
    // A closure that captures `this` but whose creation-time chain is empty
    // (a `sequence { … }` / `iterator { … }` AstLambda created in a property
    // getter — the accessor frame binds its receiver only as a parameter, not
    // on the lexical receiver chain a member call publishes) would resolve
    // `this@Class` against nothing. Seed the captured `this` as the chain's
    // receiver so the enclosing receiver survives into the coroutine body.
    // Method/lambda closures already carry a chain receiver and are untouched.
    if (chain.len == 0) {
        for (captured_names, 0..) |cn, i| {
            if (std.mem.eql(u8, cn, "this") and i < captures.len and captures[i] == .Instance) {
                const seeded = try allocator.alloc(ir.eval.EnclosingEntry, 1);
                seeded[0] = .{ .v = captures[i], .kind = .receiver };
                allocator.free(chain);
                chain = seeded;
                break;
            }
        }
    }
    const id = try self.closures.push(.{
        .body_func = fid,
        .module = if (module == self.module.asPtr()) null else module,
        .n_params = params.len,
        .receiver_shape_known = if (module.funcById(fid)) |f| f.lambda_receiver_shape_known else false,
        .has_receiver = if (module.funcById(fid)) |f| f.lambda_has_receiver else false,
        .capture_names = try allocator.dupe([]const u8, captured_names),
        .captures = cell,
        .chain = chain,
    });
    if (runtime.reclaimEnabled()) for (captures) |c| c.retain();
    const caps_ref = try ValueSlice.init(allocator, try allocator.dupe(Value, captures));
    return .{ .ok = .{ .IrClosure = .{ .id = id, .captures = caps_ref } } };
}

pub fn callableReceiverShape(self: *VmHost, v: *const Value) ?ReceiverShape {
    _ = self;
    _ = v;
    return null;
}

/// The declared positional-parameter count of a callable value, or null
/// when the shape is unknown (intrinsics, bound refs). Consulted by the
/// `CallMemberOrValue` value arm: a local callable that cannot take the
/// call's args (a `TArray.(Int, Int) -> Unit` param invoked as
/// `receiver.name()`) is not a candidate — Kotlin resolves the
/// extension instead of Null-padding the local's parameters.
pub fn callableAcceptsArgs(self: *VmHost, v: *const Value, n_args: usize) ?bool {
    switch (v.*) {
        .IrClosure => |c| {
            const info = self.closures.get(@intCast(c.id)) orelse return null;
            // A local FUNCTION lowers as a closure too and may carry
            // defaults or a vararg; its body func's declared arity is
            // authoritative (`String.endsWithCs(suffix, ignoreCase =
            // false)` accepts one arg). A plain lambda has no DeclSig —
            // its param count is exact.
            var required: usize = info.n_params;
            var total: usize = info.n_params;
            var has_vararg = false;
            {
                const mg = self.module.borrow();
                defer mg.deinit();
                if (mg.get().decl_sigs.get(info.body_func.int())) |sig| {
                    required = sig.arity.required;
                    total = sig.arity.total;
                    has_vararg = sig.arity.has_vararg;
                }
            }
            // The receiver may arrive through `this` (args bind the
            // params directly) or fill the first param (args + 1).
            inline for ([_]usize{ 0, 1 }) |extra| {
                const k = n_args + extra;
                if (k >= required and (k <= total or has_vararg)) return true;
            }
            return false;
        },
        // Function declarations, intrinsics, and bound refs are opaque
        // here; the value arm stays unguarded for them.
        else => return null,
    }
}

/// True when a declared parameter type positively excludes `null` — the
/// "Unit" name is the unannotated-param placeholder, which carries no
/// information.
fn nonNullDeclared(t: ir.TypeRef) bool {
    return !t.nullable and t.name.len != 0 and !std.mem.eql(u8, t.name, "Unit");
}

/// Whether a callable value can bind this exact call: receiver-aware
/// declared arity, named arguments, and null arguments against
/// non-nullable declared parameter types. Returns null when the shape is
/// unknown (intrinsics, bound refs). Consulted by the `CallMemberOrValue`
/// value arm: a local callable that cannot take the call is not a
/// candidate — Kotlin resolves the member/extension instead.
pub fn callableAcceptsCall(self: *VmHost, v: *const Value, recv: *const Value, args: []const Value, arg_names: []const ?[]const u8) ?bool {
    switch (v.*) {
        .IrClosure => |c| {
            const info = self.closures.get(@intCast(c.id)) orelse return null;
            var required: usize = info.n_params;
            var total: usize = info.n_params;
            var has_vararg = false;
            var has_decl_sig = false;
            var exact: ?bool = null;
            {
                const mg = self.module.borrow();
                defer mg.deinit();
                const m = info.module orelse mg.get();
                if (mg.get().decl_sigs.get(info.body_func.int())) |sig| {
                    required = sig.arity.required;
                    total = sig.arity.total;
                    has_vararg = sig.arity.has_vararg;
                    has_decl_sig = true;
                }
                if (m.funcById(info.body_func)) |bf| {
                    const receiver_param = bf.params.len != 0 and std.mem.eql(u8, bf.params[0].name, "this");
                    const shift: usize = @intFromBool(receiver_param);
                    // A named argument that names no declared parameter
                    // disqualifies the candidate.
                    for (arg_names) |maybe| {
                        const nm = maybe orelse continue;
                        var found = false;
                        for (bf.params[shift..]) |*p| {
                            if (std.mem.eql(u8, p.name, nm)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) return false;
                    }
                    // A null receiver cannot bind a non-nullable declared receiver.
                    if (receiver_param and recv.* == .Null and nonNullDeclared(bf.params[0].ty)) return false;
                    // A null argument cannot bind a non-nullable declared param.
                    for (args, 0..) |a, i| {
                        if (a != .Null) continue;
                        var pt: ?ir.TypeRef = null;
                        if (i < arg_names.len and arg_names[i] != null) {
                            for (bf.params[shift..]) |*p| {
                                if (std.mem.eql(u8, p.name, arg_names[i].?)) pt = p.ty;
                            }
                        } else if (shift + i < bf.params.len) {
                            pt = bf.params[shift + i].ty;
                        }
                        if (pt) |t| if (nonNullDeclared(t)) return false;
                    }
                    // A local fn closure without a DeclSig: its declared
                    // shape is the body func itself; the receiver always
                    // fills a leading `this` param, so user args bind the
                    // rest exactly (minus registered defaults).
                    if (!has_decl_sig) {
                        var n_def: usize = 0;
                        if (mg.get().registry.local_fn_defaults.get(info.body_func)) |slots| {
                            for (slots.items) |slot| {
                                if (slot != null) n_def += 1;
                            }
                        }
                        for (bf.params) |*p| {
                            if (p.is_vararg) has_vararg = true;
                        }
                        if (receiver_param) {
                            const utotal = total - 1;
                            const ureq = utotal -| n_def;
                            exact = args.len >= ureq and (args.len <= utotal or has_vararg);
                        } else {
                            required -|= n_def;
                        }
                    }
                }
            }
            if (exact) |ok_exact| return ok_exact;
            // The receiver may arrive through `this` (args bind the
            // params directly) or fill the first param (args + 1).
            inline for ([_]usize{ 0, 1 }) |extra| {
                const k = args.len + extra;
                if (k >= required and (k <= total or has_vararg)) return true;
            }
            return false;
        },
        // Function declarations, intrinsics, and bound refs are opaque
        // here; the value arm stays unguarded for them.
        else => return null,
    }
}

/// Whether `v` is a receiver lambda whose `this` arrives through a capture
/// slot: its body declares a receiver type and carries a `this` capture,
/// so a bare invocation (`proc()`) must bind the caller's implicit
/// receiver into that slot before the body runs. Without the bind the slot
/// keeps the creation-time lexical `this`, and every bare call in the body
/// resolves against the WRONG scope — `createTestResult { launch {…} }`
/// launched the runTest work runner on the outer TestScope, whose
/// dispatcher queues onto the very scheduler only that runner pumps.
pub fn closureNeedsThisCapture(self: *VmHost, v: *const Value) bool {
    if (v.* != .IrClosure) return false;
    const info = self.closures.get(@intCast(v.IrClosure.id)) orelse return false;
    if (callValueTraceOn()) {
        std.debug.print("[needs-this] id={d} has_recv={} caps={d}\n", .{ v.IrClosure.id, info.has_receiver, info.capture_names.len });
    }
    if (!info.has_receiver) return false;
    for (info.capture_names) |n| {
        if (std.mem.eql(u8, n, "this")) return true;
    }
    return false;
}

/// Bind `new_this` into the closure's `this` capture slot (see
/// `closureNeedsThisCapture`). The slot is written in place through the
/// captures cell: the invocation is about to run and the binding is the
/// receiver for exactly this call, the same in-place channel the
/// receiver-split paths use.
pub fn overrideClosureThis(self: *VmHost, v: *const Value, new_this: *const Value) void {
    if (v.* != .IrClosure) return;
    const info = self.closures.get(@intCast(v.IrClosure.id)) orelse return;
    var this_idx: ?usize = null;
    for (info.capture_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "this")) {
            this_idx = i;
            break;
        }
    }
    const ti = this_idx orelse return;
    const g = v.IrClosure.captures.borrowMut();
    defer g.deinit();
    const slice = g.get().*;
    if (ti < slice.len) {
        if (runtime.reclaimEnabled()) {
            new_this.retain();
            slice[ti].release(self.allocator);
        }
        slice[ti] = new_this.*;
    }
}

// -------------------------------------------------------------------------
// Internal helpers used by the value-call paths above. They live here so
// the value-call logic is self-contained.
// -------------------------------------------------------------------------

/// Monotonic instance identity, mirroring `instance_id_counter.fetch_add(_, Relaxed) + 1`.
fn nextInstanceId(self: *VmHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

/// Build an `IntrinsicHost` adapter sharing this host's state, so HOF
/// stdlib bindings can recursively invoke lambdas via the closure table.
fn makeIntrinsicHost(self: *VmHost) VmIntrinsicHost {
    return .{
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
}

fn intrinsicHostDeinit(h: *VmIntrinsicHost) void {
    h.object_states.deinit();
    h.singletons_by_id.deinit();
    h.module.deinit();
    h.closures.deinit();
    h.globals.deinit();
    h.classes.deinit();
    h.prog.deinit();
    h.anon_methods.deinit();
    h.class_default_outer.deinit();
    h.instance_id_counter.deinit();
    h.out_sink.deinit();
    h.threads.deinit();
}

/// Invoke a native stdlib intrinsic, mapping its `RuntimeError`
/// control-flow signals back into the IR evaluator's `EvalError`.
fn dispatchIntrinsic(self: *VmHost, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(self.allocator, "intrinsic_call_value", fqn, null, null, args);
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(args);
    var intrinsic = makeIntrinsicHost(self);
    defer intrinsicHostDeinit(&intrinsic);
    stdlib.implementations.string.clearRecvMemo();
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = self.allocator,
    };
    const prev_fqn_lt = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn_lt;
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| try runtimeErrToEval(self.allocator, e),
    };
}

/// Map a stdlib `RuntimeError` onto an `EvalError`, preserving thrown
/// values, non-local returns, and suspension requests.
fn runtimeErrToEval(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalResult {
    switch (e) {
        // Preserve the thrown Value so the IR evaluator's try/catch can
        // match the handler against the exception class.
        .Thrown => |v| return .{ .err = .{ .Throw = v } },
        .Return => |v| return .{ .err = .{ .NonLocalReturn = v } },
        // A suspending primitive (`delay` / `yield`) asked to park. Seed
        // a fresh SuspendState; each enclosing `eval` frame snapshots
        // itself as it unwinds, and the coroutine driver parks the
        // result under a token.
        .Suspend => |wake| {
            const st = try allocator.create(SuspendState);
            st.* = .{
                .token = 0,
                .frames = .empty,
                .wake_in_millis = wake,
                .pending_resume_reg = null,
            };
            return .{ .err = .{ .Suspended = st } };
        },
        // Map each error kind back to its `EvalError` counterpart, keeping
        // the carried message as the same string (the inverse of
        // `runtimeErrorFromEval`). Formatting the whole `RuntimeError` with
        // `{any}` would print its `[]const u8` payload as a raw byte array
        // and re-wrap an already-rendered message inside a second `.Type`.
        .Unbound => |s| return .{ .err = .{ .Unbound = s } },
        .Type => |s| return .{ .err = .{ .Type = s } },
        .Arity => |s| return .{ .err = .{ .Arity = s } },
        .Unimplemented => |s| return .{ .err = .{ .Unimplemented = s } },
        .CalleeFailed => |s| return .{ .err = .{ .CalleeFailed = s } },
        .LabeledReturn => |lr| return .{ .err = .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } } },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(e)});
            return .{ .err = .{ .Type = msg } };
        },
    }
}

/// `Result<std.ArrayList(Value), EvalError>` for `padArgsWithDefaults`.
const PadResult = union(enum) { ok: std.ArrayList(Value), err: EvalError };

/// Pad `provided` to `n_params`, evaluating each missing slot's default
/// thunk. A default-arg thunk that references the receiver records `this`
/// as a capture, so the first already-bound arg seeds the capture slot.
fn padArgsWithDefaults(
    self: *VmHost,
    allocator: Allocator,
    module_ref: ObjRef(Module),
    n_params: usize,
    provided: []const Value,
    defaults: ?[]?FuncId,
) Allocator.Error!PadResult {
    var call_args: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < n_params) : (i += 1) {
        if (i < provided.len) {
            try call_args.append(allocator, provided[i]);
            continue;
        }
        const dfid: ?FuncId = if (defaults) |d| (if (i < d.len) d[i] else null) else null;
        if (dfid) |fid| {
            // A default-arg thunk lowered inside an extension fn body that
            // references the receiver (`toIndex = size` on `IntArray.fill`)
            // records `this` as a capture, not a param. Seed the capture
            // slot with the receiver so the bare `size` resolves through it
            // instead of failing as an unresolved global.
            var captures: std.ArrayList(Value) = .empty;
            if (call_args.items.len != 0) {
                try captures.append(allocator, call_args.items[0]);
            }
            var args_copy: std.ArrayList(Value) = .empty;
            try args_copy.appendSlice(allocator, call_args.items);
            const module = module_ref.asPtr();
            const dfunc = module.funcById(fid) orelse {
                args_copy.deinit(allocator);
                captures.deinit(allocator);
                call_args.deinit(allocator);
                const msg = try std.fmt.allocPrint(allocator, "default-arg FuncId {d} out of range", .{fid.int()});
                return .{ .err = .{ .Type = msg } };
            };
            vmhost.emitPath(allocator, "default_thunk", dfunc.fqn, fid, null, provided);
            const r = try ir.eval.evalWithCaptures(VmHost, allocator, module, dfunc, args_copy, captures, self);
            switch (r) {
                .ok => |v| try call_args.append(allocator, v),
                .err => |e| {
                    call_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
        } else {
            try call_args.append(allocator, Value.Null);
        }
    }
    return .{ .ok = call_args };
}

/// Literal-only constant folder for a body-property initializer on a
/// runtime-registered local class (no lowered init thunk available).
fn simpleLiteral(allocator: Allocator, e: *const ast.Expr) ?Value {
    switch (e.*) {
        .IntLit => |x| return Value.newInt(x.value),
        .FloatLit => |x| return .{ .Double = x.value },
        .BoolLit => |x| return .{ .Bool = x.value },
        .NullLit => return Value.Null,
        .CharLit => |x| return .{ .Char = x.value },
        .StringTemplate => |x| {
            for (x.parts) |p| {
                if (p != .Text) return null;
            }
            var buf: std.ArrayList(u8) = .empty;
            for (x.parts) |p| {
                buf.appendSlice(allocator, p.Text) catch return null;
            }
            const owned = buf.toOwnedSlice(allocator) catch return null;
            const ref = runtime.strInitOwned(allocator, owned) catch return null;
            return .{ .String = ref };
        },
        else => return null,
    }
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}
