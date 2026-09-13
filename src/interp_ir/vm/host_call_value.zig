//! `VmHost` value-call dispatch: invoking callable `Value`s (closures, lambdas,
//! intrinsics, bound methods), lambda construction, and receiver-shape helpers.
//! Free functions over `*VmHost`, aliased as methods by `vmhost.zig`.

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
const IrClosureRef = runtime.IrClosureRef;
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

fn isCompanionInstance(v: Value) bool {
    if (v != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.indexOf(u8, cg.get().name, "$Companion$") != null or
        std.mem.endsWith(u8, cg.get().fqn, ".Companion");
}

/// Whether the companion surface serves `name`, so `Type::name` stays bound to it
/// rather than taking its first argument as the receiver.
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
        // Declared receiver form: the FQN's tail, `kotlin.Double.Companion` ->
        // `Double.Companion`.
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

/// Declared receiver head of an unbound type reference: invocation resolves
/// against it, never every extension of the name.
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

/// Resolve a plain positional exact-arity closure invocation into a flat-call
/// request; null for a special shape (receiver rebind, defaults, varargs, native
/// form, composer completion). Pushes the composer that `flatCallClosed` pops.
pub fn prepareClosureFlatCall(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    return prepareClosureFlatCallSlots(self, allocator, callee.IrClosure.asPtr().id, callee.IrClosure, null, args);
}

/// JIT fast path for a plain exact-arity closure; null when the shape declined.
pub fn callClosureFast(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!?EvalResult {
    if (callee.* != .IrClosure) return null;
    const prep = (try prepareClosureFlatCallSlots(self, allocator, callee.IrClosure.asPtr().id, callee.IrClosure, null, args)) orelse return null;
    defer if (prep.composer_pushed) compose.popComposer();
    // `prepareClosureFlatCallSlots` always records the body's module.
    return try ir.eval.evalWithCapturesChained(VmHost, allocator, prep.run_module.?, prep.owning, prep.func, prep.args, prep.captures, prep.chain, prep.closure_id, self);
}

const ThisOverride = struct { idx: usize, val: Value };

/// `KLIO_CALLVALUE_TRACE` gate, cached: `getenvSlice` costs a lock and a probe.
var cvt_trace_cached: ?bool = null;
fn callValueTraceOn() bool {
    if (cvt_trace_cached) |v| return v;
    const on = runtime.envOnce("KLIO_CALLVALUE_TRACE") != null;
    cvt_trace_cached = on;
    return on;
}

fn prepareClosureFlatCallSlots(self: *VmHost, allocator: Allocator, id: u64, captures: IrClosureRef, this_override: ?ThisOverride, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    const info = self.closures.get(@intCast(id)) orelse return null;
    if (args.len != info.n_params) return null;
    const module: *const Module = blk: {
        if (info.module) |m| break :blk m;
        // The host's reference keeps the main module alive for the run.
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
    // Pooled carrier: frame buffers released by the frame's teardown.
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
        const src = g.get().captures;
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

pub fn flatCallClosed(self: *VmHost) void {
    _ = self;
    compose.popComposer();
}

/// Resolve a plain receiver-lambda invocation (`recv.block()` lowered as
/// CallValueWithThis) into a flat-call request, receiver applied as a slot
/// override on the capture copy. Non-plain shapes decline.
pub fn prepareClosureWithThisFlatCall(self: *VmHost, allocator: Allocator, callee: *const Value, this_value_in: *const Value, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    if (callee.* != .IrClosure) return null;
    const id = callee.IrClosure.asPtr().id;
    const captures = callee.IrClosure;
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
        // A named local fn, and a leading declared `this` param, both decline.
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
    // The receiver is a context-argument source for a contextual callee in the
    // block; the mark predates the push so activation close truncates it.
    const ctx_mark = self.ctxStackLen();
    if (self.ctxIsActive()) self.ctxPush(selected_this) catch {};
    // The receiver binds into the `this` slot; the displaced prior stays outer.
    const prior_this: ?Value = blk: {
        const ti = this_idx orelse break :blk null;
        const g = captures.borrow();
        defer g.deinit();
        const slice = g.get().captures;
        if (ti < slice.len) break :blk slice[ti];
        break :blk null;
    };
    // These pushes unwind LIFO at activation close.
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
    // Slot override on the copied vector; the caller's registers root the receiver.
    const override: ?ThisOverride = if (this_idx) |ti| .{ .idx = ti, .val = selected_this } else null;
    var req = (try prepareClosureFlatCallSlots(self, allocator, id, captures, override, args)) orelse {
        // Declined at the terminal (native form): undo the pushes.
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

/// Resolve an undispatched coroutine start into a barrier flat-call request: the
/// block runs on the caller's driver, a suspension parks the segment into the
/// pump, and the caller gets COROUTINE_SUSPENDED.
pub fn prepareUndispatchedStartFlatCall(self: *VmHost, allocator: Allocator, module: *const Module, fid: FuncId, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    if (args.len != 2) return null;
    const f = module.funcById(fid) orelse return null;
    if (!std.mem.eql(u8, f.name, "__klio_co_startRootOrSuspended")) return null;
    // Without the registered native form the Kotlin fallback body serves.
    if (host_call_func.resolvedNativeForm(self, fid) == null) return null;
    const has_driver = vmhost.coroutines.coroutineHasDriver();
    const scope_v = args[0];
    const block = args[1];
    if (block != .IrClosure) return null;
    const id = block.IrClosure.asPtr().id;
    const captures = block.IrClosure;
    const info = self.closures.get(@intCast(id)) orelse return null;
    if (info.n_params != 0) return null;
    // `evalClosureRaw` falls back to the ClosureInfo cell on a length mismatch.
    {
        const g = captures.borrow();
        defer g.deinit();
        if (g.get().captures.len != info.capture_names.len) return null;
    }
    // `evalClosureRaw` overrides every `this` capture, a slot override only one.
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
        // No enclosing pump: this activation becomes its own, scope as keepalive.
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

/// Driver hook: park the root into its own pump, drain and exit it, and return
/// the resumed value or COROUTINE_SUSPENDED.
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

/// Driver hook: run the pump to quiescence with the body's result as the root
/// value, or just exit it when the body raised.
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

pub fn undispatchedBarrierPark(self: *VmHost, allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!Value {
    _ = self;
    return vmhost.coroutines.undispatchedFlatPark(allocator, st, scope_base);
}

/// Driver hook: remove the scope entry the prepare pushed, by identity.
pub fn undispatchedScopeLeave(self: *VmHost, ident: usize) void {
    _ = self;
    vmhost.coroutines.undispatchedFlatLeaveIdent(ident);
}

/// Flat counterpart of `callValueNamedRecvCtx`: an exact-arity closure with no
/// `this` capture (or a receiver lambda) prepares with-this, any other shape as
/// a plain call.
pub fn prepareValueRecvCtxFlatCall(self: *VmHost, allocator: Allocator, callee: *const Value, recv: *const Value, args: []const Value) Allocator.Error!?ir.eval.FlatCallReq {
    if (callee.* != .IrClosure) return null;
    if (recv.* == .Instance) {
        if (self.closures.get(@intCast(callee.IrClosure.asPtr().id))) |info| {
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

/// Whether a declaration named `name` is an extension fn, so the name is not a
/// property.
pub fn extensionFnNamed(self: *VmHost, name: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    for (mg.get().funcsBySimpleName(name)) |fid| {
        const f = mg.get().funcById(fid) orelse continue;
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) return true;
    }
    return false;
}

pub fn callValue(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    // A captured-and-written local is boxed, so a function-typed one is a cell.
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
    // Bound-member-reference invocation (`recv::method`) beats `operator fun
    // invoke`: dispatch through `__bound_receiver__` and `__bound_name__`.
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
            // Dispatch under the creation-site file, where a private target is visible.
            var ref_pushed = false;
            var ref_prev: ?ir.eval.RefSiteOverride = null;
            if (host_call_member.boundRefFile(callee)) |bf| {
                ref_prev = ir.eval.pushRefSiteFile(bf);
                ref_pushed = true;
            }
            defer if (ref_pushed) ir.eval.popRefSiteFile(ref_prev);
            // `A::Inner` unbound: arg0 is the outer, so `(A::Inner)(a)` is `a.Inner()`.
            if (rv == .Class and args.len != 0 and classHasInnerNamed(self, &rv, name)) {
                return host_call_member.callMemberNamedStatic(self, allocator, &args[0], name, args[1..], &.{}, null);
            }
            if (rv == .Instance and instanceHasInnerNamed(self, &rv, name)) {
                return host_call_member.callMemberNamedStatic(self, allocator, &rv, name, args, &.{}, null);
            }
            if (boundReferenceFunc(callee)) |func| {
                var exact_args: std.ArrayList(Value) = .empty;
                defer exact_args.deinit(allocator);
                // A type-form reference is unbound: arg0 is the receiver. For a
                // class declaring a companion, the name in value position is that
                // companion, never prepended.
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
            // `valueOf`/`values`/`entries` are enum statics: no receiver.
            if (rv == .Class and (std.mem.eql(u8, name, "valueOf") or std.mem.eql(u8, name, "values") or
                std.mem.eql(u8, name, "entries")))
            {
                return host_call_member.callMember(self, allocator, &rv, name, args);
            }
            const type_like = (rv == .Class) or
                (rv == .Instance and isCompanionInstance(rv) and
                    !companionServesName(self, &rv, name));
            if (type_like and args.len != 0) {
                const first = args[0];
                const rest = args[1..];
                if (rest.len == 0 and (root.memberIsProperty(allocator, &self.classes, &first, name) or
                    (!extensionFnNamed(self, name) and host_fields.hostHasExtProp(self, allocator, &first, name))))
                {
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
                // An extension property takes no member call; read it as a field.
                if (rest.len == 0 and mr == .err and mr.err == .Unimplemented) {
                    const pr = try host_fields.getField(self, allocator, &first, name);
                    if (runtime.envOnce("KLIO_ERR_TRACE") != null) std.debug.print("[boundref-typelike] {s} on {s}: field read {s}\n", .{ name, first.typeFqn(), if (pr == .ok) "ok" else "miss" });
                    if (pr == .ok) return pr;
                }
                if (runtime.envOnce("KLIO_ERR_TRACE") != null) std.debug.print("[boundref-typelike] {s} on {s}: forward {s}\n", .{ name, first.typeFqn(), if (mr == .ok) "ok" else "err" });
                return mr;
            }
            if (args.len == 0 and root.memberIsProperty(allocator, &self.classes, &rv, name)) {
                return host_fields.getField(self, allocator, &rv, name);
            }
            const r = try host_call_member.callMember(self, allocator, &rv, name, args);
            // A bound extension-property reference reads it, after a name miss.
            if (args.len == 0 and host_call_member.isDispatchMissFor(r, name)) {
                const pr = try host_fields.getField(self, allocator, &rv, name);
                if (pr == .ok) {
                    host_call_member.freeDispatchMiss(allocator, r);
                    return pr;
                }
            }
            // A bare `::name` bound to the enclosing `this` may target a top-level
            // function lowered after the binding; retry the global on a member miss.
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
        // Compose arg completion, instance side: a ComposableLambdaImpl invoked
        // typelessly misses `invoke` without the trailing `(composer, changed)`.
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
        // A `fun interface` whose lone method is not `invoke` routes to `run()`.
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
    // Constructor-like call on a class value (`val ctor = ::Foo; ctor(1, 2)`); a
    // class absent from the module's class_index falls to direct allocation below.
    if (callee.* == .Class) {
        const cls = callee.Class;
        // SAM conversion: `FunInterface { lambda }` builds a thin InstanceData
        // holding the lambda under `__sam_target__`, which member dispatch routes to.
        const is_fun_interface = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().is_fun_interface;
        };
        if (is_fun_interface and args.len == 1) {
            const identity = nextInstanceId(self);
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            // The instance owns one ref to its target; `args[0]` is a borrow.
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
        // The bound ClassDef carries the resolved FQN, so `(::Ctor)(args)` builds
        // the referenced class even when another package shares the simple name.
        // A runtime-registered local class def IS the class, never re-indexed.
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
            // `Outer::Inner` unbound: arg0 is the outer instance, the rest the ctor's.
            const inner = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().is_inner;
            };
            if (inner and args.len != 0 and args[0] == .Instance) {
                const n_primary = blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    break :blk if (cid.int() < mg.get().classes.items.len) mg.get().classes.items[cid.int()].primary_params.len else 0;
                };
                if (args.len == n_primary + 1) {
                    return host_instances.newInstance(self, allocator, cid, args[1..], &args[0]);
                }
            }
            return host_instances.newInstance(self, allocator, cid, args, null);
        }
        const identity = nextInstanceId(self);
        const default_outer: ?Value = blk: {
            const g = self.class_default_outer.borrow();
            defer g.deinit();
            break :blk g.get().get(cls_name);
        };
        // An omitted trailing primary parameter takes its default: a literal inline,
        // anything else through the class's registered `$default$<i>` thunk.
        var full_args: std.ArrayList(Value) = .empty;
        defer full_args.deinit(allocator);
        try full_args.appendSlice(allocator, args);
        {
            const n_primary = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().primary_params.len;
            };
            var pi: usize = args.len;
            while (pi < n_primary) : (pi += 1) {
                const dflt: ?*const ast.Expr = blk: {
                    const g = cls.borrow();
                    defer g.deinit();
                    break :blk if (g.get().primary_params[pi].default) |e| e.get() else null;
                };
                const e = dflt orelse {
                    try full_args.append(allocator, .Null);
                    continue;
                };
                if (simpleLiteral(allocator, e)) |v| {
                    try full_args.append(allocator, v);
                    continue;
                }
                const thunk_name = try std.fmt.allocPrint(allocator, "$default${d}", .{pi});
                defer allocator.free(thunk_name);
                // The thunk's `this` is the captured enclosing instance, else the
                // innermost receiver in scope.
                const recv: Value = default_outer orelse blk: {
                    const g = cls.borrow();
                    defer g.deinit();
                    const encl = g.get().local_enclosing;
                    var k: usize = encl.len;
                    while (k > 0) {
                        k -= 1;
                        if (encl[k].kind == .receiver or encl[k].kind == .subject) break :blk encl[k].v;
                    }
                    break :blk .Null;
                };
                switch (try host_call_member.invokeLocalClassThunk(self, allocator, cls, thunk_name, &recv, full_args.items)) {
                    .ok => |v| try full_args.append(allocator, v),
                    .err => |err| return .{ .err = err },
                }
            }
        }
        const ctor_args: []const Value = full_args.items;
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        {
            const g = cls.borrow();
            defer g.deinit();
            const cdef = g.get();
            var i: usize = 0;
            while (i < cdef.primary_params.len) : (i += 1) {
                if (cdef.primary_params[i].property == null) continue;
                if (i < ctor_args.len) {
                    // The instance owns one ref per primary-ctor field.
                    if (runtime.reclaimEnabled()) ctor_args[i].retain();
                    try fields.append(allocator, .{ .name = cdef.primary_params[i].name, .value = ctor_args[i] });
                } else {
                    try fields.append(allocator, .{ .name = cdef.primary_params[i].name, .value = Value.Null });
                }
            }
            // Literal body-property inits evaluate inline; complex ones run below
            // as `$init$` thunks once the instance exists, since they read `this`.
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
        const inst = try ObjRef(InstanceData).init(allocator, .{
            .class = cls.clone(),
            .fields = fields,
            .outer = default_outer,
            .identity = identity,
            .native_state = null,
        });
        const inst_value: Value = .{ .Instance = inst };
        // A module parent chain binds its primary-param fields and runs its
        // body-property inits through the `$super$arg$<i>` thunks.
        if (try host_instances.initLocalParentChain(self, allocator, inst, inst_value, cls, cls_name, ctor_args)) |e| {
            return .{ .err = e };
        }
        // Kotlin runs `init { … }` blocks and property initializers in declaration
        // order; the blocks are `$init$block$<idx>` anon thunks.
        const n_props = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().body_properties.len;
        };
        var prop_idx: usize = 0;
        while (prop_idx < n_props) : (prop_idx += 1) {
            switch (try host_instances.runAnonInitBlocksAt(self, cls, cls_name, prop_idx, &inst_value, ctor_args)) {
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
            // The thunks declare the primary params, so a shadowed one stays read.
            switch (try host_call_member.callMember(self, allocator, &inst_value, init_name, ctor_args)) {
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
        switch (try host_instances.runAnonInitBlocksAt(self, cls, cls_name, n_props, &inst_value, ctor_args)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
        return .{ .ok = inst_value };
    }
    // Invoking a `PropertyRef` (`::name`): a reference to a top-level function
    // calls it, winning over the property read because a thunk lowered before that
    // function registered records it as a `PropertyRef`.
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
        // `(::topLevel)()` reads the property through its getter.
        if (args.len == 0) {
            if (try host_call_member.topLevelPropertyGet(self, allocator, name)) |r| return r;
        }
        if (args.len == 1) {
            return host_fields.getField(self, allocator, &args[0], name);
        }
    }
    // Bound method/property reference: a synthetic instance carrying receiver and
    // name; invocation forwards through it, or reads the property on arg0 unbound.
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
            const r = try host_call_member.callMember(self, allocator, &rv, name, args);
            // A bound property reference reads the property, after a name miss.
            if (args.len == 0 and host_call_member.isDispatchMissFor(r, name)) {
                host_call_member.freeDispatchMiss(allocator, r);
                return host_fields.getField(self, allocator, &rv, name);
            }
            return r;
        }
    }
    if (callee.* == .IrClosure) {
        const id = callee.IrClosure.asPtr().id;
        const captures = callee.IrClosure;
        const info = self.closures.get(@intCast(id)) orelse {
            const msg = try std.fmt.allocPrint(allocator, "unknown IrClosure id {d}", .{id});
            return .{ .err = .{ .Type = msg } };
        };
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        // A sub-module closure resolves its `FuncId` against that sub-module.
        const module = info.module orelse module_ref.asPtr();
        const func = module.funcById(info.body_func) orelse {
            const msg = try std.fmt.allocPrint(allocator, "closure body FuncId {d} out of range", .{info.body_func.int()});
            return .{ .err = .{ .Type = msg } };
        };
        // Compose arg completion: a composable invoked through a typeless route
        // reaches no static site the pass could append `($composer, $changed)` to.
        // A pair-tailed local fn called with the pair but fewer user args keeps
        // the pair in the trailing slots and fills the gap from the default
        // thunks; Null-padding would shove the composer into a user param.
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
        // One executable form per symbol: when `linkResolvedForms` bound this fn to
        // a native form, dispatch that. Link tables are keyed by main-module ids.
        if (info.module == null) {
            host_call_func.linkAuditCheck(self, module, func.id, func, args);
            if (host_call_func.resolvedNativeForm(self, func.id)) |intrinsic| {
                return dispatchIntrinsic(self, func.fqn, intrinsic, args);
            }
            // A closure published for an overloaded top-level name carries one
            // signature (first wins), so a call its arity cannot bind belongs to a
            // same-name sibling; re-rank through the overload binder. The
            // source-level name strips a file-private fn's rename (`over$f220`).
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
            // A local fn's defaults live only as registered thunks (no `has_default`
            // flag, no DeclSig), so decide bindability from that thunk table.
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
        // Value-style invocation of a receiver lambda (`block(receiver, p)` for an
        // `R.(P) -> T`): one extra leading arg means arg0 is the extension
        // receiver. Bind it into the closure VALUE's `this` capture, which is what
        // the evaluator reads, and re-run on the main evaluator path, which
        // snapshots frames so a suspension parks. Any vararg excludes this.
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
        // A block the compose pass moved into `composableLambdaInstance(...)` loses
        // its receiver shape, and the compose ABI is the only caller passing one an
        // extra leading arg, so a pair-tailed closure infers its receiver there.
        const pair_tailed =
            func.params.len >= 2 and
            std.mem.eql(u8, func.params[func.params.len - 1].name, "$changed") and
            std.mem.eql(u8, func.params[func.params.len - 2].name, "$composer");
        const compose_recv_infer = !info.receiver_shape_known and
            this_cap_idx != null and pair_tailed;
        // Receiver-first shapes: every declared param supplied, or the pair-less
        // composable one whose `($composer, $changed)` the re-entry supplies.
        const recv_first_shape = args.len == info.n_params + 1 or
            (pair_tailed and args.len + 2 == info.n_params + 1);
        // Unknown shape with one arg more than the declared params can only be the
        // explicit-receiver form: Kotlin function types with and without receivers
        // are interchangeable and no legal call over-supplies a plain closure. A
        // headerless block, whose lone param is a speculative `it`, is excluded.
        const unknown_recv_infer = !info.receiver_shape_known and
            args.len == info.n_params + 1 and
            !(func.params.len != 0 and std.mem.eql(u8, func.params[0].name, "it"));
        if ((info.has_receiver or compose_recv_infer or unknown_recv_infer) and !last_vararg and recv_first_shape) {
            if (runtime.envOnce("KLIO_REBIND_AUDIT") != null) {
                std.debug.print("[REBIND] fn={s} n_params={d}\n", .{ func.name, info.n_params });
            }
            // A receiver lambda need not read it; arg0 is still removed.
            if (this_cap_idx == null) {
                const receiver = args[0];
                const pushed = receiver == .Instance or receiver == .Null;
                if (pushed) host_call_member.pushAccessEnclosingSubject(self, &receiver);
                const r = try callValue(self, allocator, callee, args[1..]);
                if (pushed) host_call_member.popAccessEnclosing(self);
                return r;
            }
            const this_idx = this_cap_idx.?;
            // The displaced capture is the body's lexically enclosing receiver.
            const prior_this: ?Value = blk: {
                const g = captures.borrow();
                defer g.deinit();
                const slice = g.get().captures;
                if (this_idx < slice.len) break :blk slice[this_idx];
                break :blk null;
            };
            const bound = bnd: {
                var new_caps: std.ArrayList(Value) = .empty;
                {
                    const g = captures.borrow();
                    defer g.deinit();
                    try new_caps.appendSlice(allocator, g.get().captures);
                }
                if (this_idx >= new_caps.items.len) {
                    try new_caps.appendNTimes(allocator, Value.Null, this_idx + 1 - new_caps.items.len);
                }
                new_caps.items[this_idx] = args[0];
                // The bound closure owns one ref per capture; the copies are borrows.
                if (runtime.reclaimEnabled()) for (new_caps.items) |c| c.retain();
                const slice = try new_caps.toOwnedSlice(allocator);
                const caps_ref = try IrClosureRef.init(allocator, .{ .id = id, .captures = slice });
                break :bnd Value{ .IrClosure = caps_ref };
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
        // Fill missing positional args from registered default-arg thunks, then pack
        // trailing varargs into an Array. Keyed by main-module ids: sub-modules skip.
        const defaults: ?[]?FuncId = blk: {
            if (info.module != null) break :blk null;
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().func_defaults.get(info.body_func.int());
        };
        // Trailing-lambda rule: `f { … }` with a function-typed last parameter and
        // defaulted omitted leading ones binds the lambda to that last parameter.
        var call_args = blk: {
            const np = info.n_params;
            if (np >= 2 and args.len < np and args.len > 0 and func.params.len >= np) {
                const last_p = &func.params[np - 1];
                if (root.isFunctionType(&last_p.ty) and root.valueIsCallable(&args[args.len - 1])) {
                    const leading = args[0 .. args.len - 1];
                    var ca = switch (try padArgsWithDefaultsFor(self, allocator, module_ref, np, leading, defaults, func.params)) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    ca.items[np - 1] = args[args.len - 1];
                    break :blk ca;
                }
            }
            break :blk switch (try padArgsWithDefaultsFor(self, allocator, module_ref, info.n_params, args, defaults, func.params)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
        };
        // Non-final vararg (Kotlin allows `vararg` before a trailing function param):
        // the params after it take the last args, the middle packs into its Array.
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
            // A post-vararg param claims a tail arg only when it cannot default.
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
                    call_args = switch (try padArgsWithDefaultsFor(self, allocator, module_ref, info.n_params, prefix.items, defaults, func.params)) {
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
            try capture_values.appendSlice(allocator, g.get().captures);
        }
        vmhost.emitPath(allocator, "call_value_closure", func.fqn, func.id, null, args);
        // A composable invoked as a value publishes its `$composer` argument as the
        // ambient composer, which `__compose_currentComposer` in the body reads.
        {
            if (compose.threadedComposerArgFor(func.fqn, func.params, call_args.items)) |c| {
                compose.pushComposer(c);
                defer compose.popComposer();
                return ir.eval.evalWithCapturesChained(VmHost, allocator, module, info.module, func, call_args, capture_values, info.chain, @intCast(id), self);
            }
        }
        return ir.eval.evalWithCapturesChained(VmHost, allocator, module, info.module, func, call_args, capture_values, info.chain, @intCast(id), self);
    }
    // `Comparator` is a `fun interface`: calling it as a value calls `compare`.
    if (callee.* == .Comparator and args.len == 2) {
        return self.callMember(allocator, callee, "compare", args);
    }
    if (runtime.envOnce("KLIO_ERR_TRACE") != null)
        std.debug.print("[callvalue-miss] callee={s} args={d}\n", .{ callee.typeFqn(), args.len });
    ir.eval.dumpFrameChainForDiag();
    const msg = try std.fmt.allocPrint(allocator, "Vm::call_value on `{s}`", .{callee.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

/// `callValueNamed` with call-site type arguments preserved: an unsigned element
/// type retags integral args, as kotlinc types literals by expected type.
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

/// `callValueNamed` with the call site's member-fallback receiver as dispatch
/// context: a receiver-typed closure invoked bare rides it as innermost subject.
pub fn callValueNamedRecvCtx(self: *VmHost, allocator: Allocator, callee: *const Value, recv: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    if (callee.* == .IrClosure and recv.* == .Instance) {
        if (self.closures.get(@intCast(callee.IrClosure.asPtr().id))) |info| {
            var has_this = false;
            for (info.capture_names) |n| {
                if (std.mem.eql(u8, n, "this")) {
                    has_this = true;
                    break;
                }
            }
            // A receiver lambda invoked bare binds the call site's implicit receiver
            // whatever its `this` capture: Kotlin values never carry receivers.
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
                    std.debug.print("[cvnrc] id={d} recv={s}\n", .{ callee.IrClosure.asPtr().id, tn });
                }
                return callValueWithThis(self, allocator, callee, recv, args, arg_names);
            }
        }
    }
    return callValueNamed(self, allocator, callee, args, arg_names);
}

pub fn callValueNamed(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    // Named args skipping a default must reorder; `callValue` is positional.
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
                // A trailing callable binds the last ctor param while unfilled.
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
    // Named args skipping a default reorder and fill, as `callFuncNamed` does.
    if (callee.* == .IrClosure) {
        var any_named = false;
        for (arg_names) |n| {
            if (n != null) {
                any_named = true;
                break;
            }
        }
        if (any_named) {
            if (self.closures.get(@intCast(callee.IrClosure.asPtr().id))) |info| {
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                const module = info.module orelse module_ref.asPtr();
                if (module.funcById(info.body_func)) |func| {
                    const np = info.n_params;
                    // Named args address the value parameters; a vararg does not.
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
                        // A trailing callable binds the last function-typed param.
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
                        // Evaluate each omitted slot's default thunk, holes and
                        // tail; a sub-module closure has none.
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
                                // The first bound arg seeds the receiver capture.
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

/// Whether a closure's declared value-parameter types refute the runtime
/// arguments, arity aside. A captured local fn whose params refute them is not the
/// target, so `CallValueOrMember` falls to the same-named enclosing member.
pub fn closureParamsDisproven(self: *VmHost, callee: *const Value, args: []const Value) bool {
    var v = callee.*;
    if (v == .Cell) {
        const cg = v.Cell.borrow();
        v = cg.get().*;
        cg.deinit();
    }
    if (v != .IrClosure) return false;
    const info = self.closures.get(@intCast(v.IrClosure.asPtr().id)) orelse return false;
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const module = info.module orelse module_ref.asPtr();
    const func = module.funcById(info.body_func) orelse return false;
    const np = @min(info.n_params, func.params.len);
    for (func.params[0..np], 0..) |*p, i| {
        if (i >= args.len) break;
        if (p.is_vararg) continue;
        if (host_call_member.argDefinitelyNotParamType(self, &p.ty, &args[i])) return true;
        // The shared helper declines array-against-scalar (vararg/spread ambiguity),
        // but a declared non-vararg builtin scalar param refutes it.
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

/// `callValueWithThis` with the receiver re-selected by the head the call site
/// declared: Kotlin binds the innermost implicit receiver of that type.
pub fn callValueWithThisHead(self: *VmHost, allocator: Allocator, callee: *const Value, this_value_in: *const Value, args: []const Value, arg_names: []const ?[]const u8, head: []const u8) Allocator.Error!EvalResult {
    var selected = this_value_in.*;
    if (head.len != 0) {
        if (try host_call_member.implicitReceiverForHead(self, allocator, this_value_in, head)) |m| selected = m;
    }
    if (runtime.envOnce("KLIO_HEAD_TRACE") != null)
        std.debug.print("[cvth] head={s} passed={s} selected={s}\n", .{ head, this_value_in.typeFqn(), selected.typeFqn() });
    return callValueWithThisSel(self, allocator, callee, &selected, args, arg_names, false);
}

/// `callValueWithThis` with receiver re-selection gated: a caller that proved the
/// receiver passes `allow_resel = false`, since a recorded head can name an
/// enclosing scope while a supplied receiver is authoritative.
pub fn callValueWithThisSel(self: *VmHost, allocator: Allocator, callee: *const Value, this_value_in: *const Value, args: []const Value, arg_names: []const ?[]const u8, allow_resel: bool) Allocator.Error!EvalResult {
    _ = arg_names;
    var selected_this = this_value_in.*;
    if (allow_resel and callee.* == .IrClosure) {
        const id = callee.IrClosure.asPtr().id;
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
    // A receiver-lambda's receiver is a context-argument source in that block.
    const ctx_mark = self.ctxStackLen();
    defer self.ctxStackTruncate(ctx_mark);
    if (self.ctxIsActive()) self.ctxPush(this_value.*) catch {};
    // Explicit-receiver receiver-lambda call (`block(receiver, p)` for an
    // `R.(P) -> T`): bind `this_value` into the `this` capture and dispatch on the
    // main evaluator path, which splits the receiver and snapshots frames so a
    // suspension parks; the intrinsic-host invoke does neither.
    if (callee.* == .IrClosure) {
        const id = callee.IrClosure.asPtr().id;
        const captures = callee.IrClosure;
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
                    if (i < captures_g.get().captures.len) prior_this = captures_g.get().captures[i];
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
            // A named local function lowers as a closure but is not a receiver
            // lambda: its `this` comes from captures, so the binds below corrupt it.
            {
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                const module = info.module orelse module_ref.asPtr();
                if (module.funcById(info.body_func)) |bf| {
                    const takes_receiver = bf.params.len != 0 and std.mem.eql(u8, bf.params[0].name, "this");
                    // Unless invoked as a receiver fn, whose extra param takes it.
                    const receiver_fills_slot = bf.params.len == args.len + 1;
                    if (!std.mem.eql(u8, bf.name, "<lambda>") and !takes_receiver and
                        !receiver_fills_slot)
                    {
                        return callValue(self, allocator, callee, args);
                    }
                    // The compose pass flattens a composable `R.() -> T` literal's
                    // receiver into a leading slot (`[it, $composer, $changed]`),
                    // so such a lambda takes the bound receiver there whatever its
                    // captures; the trailing pair tells it from a headerless one.
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
                    // Unknown shape with one declared param more than the supplied
                    // args and no leading `this`: the receiver rides positionally
                    // there. A parameterless receiver lambda and a headerless
                    // block's `it` keep the bind below.
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
            // Kotlin function types with and without receivers are interchangeable:
            // an `(R, P) -> T` takes the receiver positionally, keeping its `this`.
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
                // Two receiver-lambda shapes reach here, both on the main evaluator
                // path so a suspension snapshots frames and parks: an
                // explicit-receiver call, where arg0 is the receiver, and a
                // receiver-bound call, where it arrives via `this_value`.
                const explicit_receiver = info.has_receiver and args.len == info.n_params + 1;
                const receiver: Value = if (explicit_receiver) args[0] else this_value.*;
                const body_args: []const Value = if (explicit_receiver) args[1..] else args;

                // Bind into a fresh captures cell's `this` slot: the evaluator reads
                // the closure value's captures, not the side-table.
                var new_caps: std.ArrayList(Value) = .empty;
                {
                    const g = captures.borrow();
                    defer g.deinit();
                    try new_caps.appendSlice(allocator, g.get().captures);
                }
                const prior_this: ?Value = if (idx < new_caps.items.len) new_caps.items[idx] else null;
                if (idx >= new_caps.items.len) {
                    try new_caps.appendNTimes(allocator, Value.Null, idx + 1 - new_caps.items.len);
                }
                new_caps.items[idx] = receiver;
                // The bound closure owns one ref per capture; the copies are borrows.
                if (runtime.reclaimEnabled()) for (new_caps.items) |c| c.retain();
                const slice = try new_caps.toOwnedSlice(allocator);
                const caps_ref = try IrClosureRef.init(allocator, .{ .id = id, .captures = slice });
                const bound = Value{ .IrClosure = caps_ref };

                // Keep the displaced prior `this` as an outer implicit receiver, and
                // push the new one so a member-extension on its class sees the owner.
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
                // A null subject is a real candidate for `fun Thing?.show()`.
                const pushed_receiver = receiver == .Instance or receiver == .Null;
                if (pushed_receiver) {
                    host_call_member.pushAccessEnclosingSubject(self, &receiver);
                }
                const r = try callValue(self, allocator, &bound, body_args);
                if (pushed_receiver) host_call_member.popAccessEnclosing(self);
                if (pushed_outer) host_call_member.popAccessEnclosing(self);
                return r;
            }
            // No `this` capture: the receiver binds as a leading declared `this` param
            // when the body has one, otherwise it is only the innermost subject.
            const takes_this_param = blk: {
                const module_g = self.module.borrow();
                defer module_g.deinit();
                const m = info.module orelse module_g.get();
                const f = m.funcById(info.body_func) orelse break :blk false;
                const fp = f.params;
                break :blk fp.len != 0 and std.mem.eql(u8, fp[0].name, "this");
            };
            // On a body that never captured `this`, arg0 is still the receiver.
            if (info.has_receiver and !takes_this_param and args.len == info.n_params + 1) {
                const recv0 = args[0];
                const pushed = recv0 == .Instance or recv0 == .Null;
                if (pushed) host_call_member.pushAccessEnclosingSubject(self, &recv0);
                const r = try callValue(self, allocator, callee, args[1..]);
                if (pushed) host_call_member.popAccessEnclosing(self);
                return r;
            }
            // A plain lambda used as `T.(…) -> R` takes the receiver as its extra param.
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
    // A member-reference value invoked with an explicit receiver (an
    // extension-function-typed parameter fed `ULongArray::sortDescending`) drives
    // the member walk with the args passed through, which the fallback drops.
    if (callee.* == .Instance) {
        var name_v: ?Value = null;
        var bound_recv: ?Value = null;
        {
            const snap = callee.Instance.borrow();
            defer snap.deinit();
            name_v = snap.get().get("__bound_name__");
            bound_recv = snap.get().get("__bound_receiver__");
        }
        // A bound reference (`predicate::test`) already carries its receiver, so
        // under a receiver-function type the supplied `this` is its ARGUMENT:
        // `obj.condition()` means `predicate.test(obj)`. A type form is unbound.
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
            // A reference naming an extension property takes no member call.
            if (args.len == 0 and mr == .err and mr.err == .Unimplemented) {
                const pr = try host_fields.getField(self, allocator, this_value, name);
                if (pr == .ok) return pr;
            }
            return mr;
        }
        // An instance of a class EXTENDING a function type takes the args through
        // `invoke`, receiver first; a mere `invoke` member is not such a subtype.
        if (name_v == null and host_call_member.instanceExtendsFunctionType(self, callee)) {
            const direct = try host_call_member.callMemberNamed(self, allocator, callee, "invoke", args, &.{});
            if (!host_call_member.isDispatchMissFor(direct, "invoke")) return direct;
            host_call_member.freeDispatchMiss(allocator, direct);
            var all: std.ArrayList(Value) = .empty;
            defer all.deinit(allocator);
            try all.append(allocator, this_value.*);
            try all.appendSlice(allocator, args);
            return host_call_member.callMemberNamed(self, allocator, callee, "invoke", all.items, &.{});
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

/// Receiver-function invocation from an IR site whose callable shape is known: a
/// plain function adapted to a receiver type takes it positionally, a receiver
/// lambda keeps the bind path.
pub fn callValueWithThisExact(self: *VmHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    if (callee.* == .IrClosure) {
        if (self.closures.get(@intCast(callee.IrClosure.asPtr().id))) |info| {
            // Unknown shape falls back to declared arity: one param more than the
            // supplied args wants the receiver there, unless it is a speculative `it`.
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
                // The receiver rides positionally but is still published innermost.
                const push_subject = this_value.* == .Instance or this_value.* == .Null;
                if (push_subject) host_call_member.pushAccessEnclosingSubject(self, this_value);
                defer if (push_subject) host_call_member.popAccessEnclosing(self);
                return callValue(self, allocator, callee, with_recv);
            }
        }
    }
    return callValueWithThisSel(self, allocator, callee, this_value, args, arg_names, false);
}

fn classHasInnerNamed(self: *VmHost, cv: *const Value, name: []const u8) bool {
    const fqn = blk: {
        const g = cv.Class.borrow();
        defer g.deinit();
        break :blk if (g.get().fqn.len != 0) g.get().fqn else g.get().name;
    };
    return classFqnHasInnerNamed(self, fqn, name);
}

fn instanceHasInnerNamed(self: *VmHost, iv: *const Value, name: []const u8) bool {
    const fqn = blk: {
        const g = iv.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk if (cg.get().fqn.len != 0) cg.get().fqn else cg.get().name;
    };
    return classFqnHasInnerNamed(self, fqn, name);
}

fn classFqnHasInnerNamed(self: *VmHost, fqn: []const u8, name: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const owner = mg.get().classIdByFqn(fqn) orelse mg.get().classId(fqn);
    const nested = if (owner) |o| mg.get().classIdNestedIn(o, name) else null;
    const n = nested orelse return false;
    if (n.int() >= mg.get().classes.items.len) return false;
    return mg.get().classes.items[n.int()].is_inner;
}

pub fn buildClosure(self: *VmHost, allocator: Allocator, module: *const Module, body_func: FuncId, captures: []const Value) Allocator.Error!EvalResult {
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
    // Canonical capture store for the HOF invoke path; a captured `var` is a
    // shared `Value.Cell`, so writes are visible by reference.
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
    // The IrClosure owns one ref per capture, freed in `release`; the registry cell
    // is a non-owning view.
    if (runtime.reclaimEnabled()) for (captures) |c| c.retain();
    const caps_ref = try IrClosureRef.init(allocator, .{ .id = id, .captures = try allocator.dupe(Value, captures) });
    return .{ .ok = .{ .IrClosure = caps_ref } };
}

pub fn buildAstLambdaWithFlagFuncid(self: *VmHost, allocator: Allocator, module: *const Module, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool, body_func: ?FuncId) Allocator.Error!EvalResult {
    _ = body;
    _ = absorb_return;
    const fid = body_func orelse return .{ .err = .{ .Unimplemented = "Vm: lambda lower did not provide body_func" } };
    // Canonical capture store for the HOF invoke path; a captured `var` is a
    // shared `Value.Cell`, so writes are visible by reference.
    var cell_list: std.ArrayList(Value) = .empty;
    try cell_list.appendSlice(allocator, captures);
    const cell = try ObjRef(std.ArrayList(Value)).init(allocator, cell_list);
    var chain = try ir.eval.captureChainAlloc(allocator);
    // A closure capturing `this` whose creation-time chain is empty (an AstLambda
    // in a property getter, whose accessor frame binds the receiver only as a
    // parameter) resolves `this@Class` against nothing, so seed the chain.
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
    const caps_ref = try IrClosureRef.init(allocator, .{ .id = id, .captures = try allocator.dupe(Value, captures) });
    return .{ .ok = .{ .IrClosure = caps_ref } };
}

pub fn callableReceiverShape(self: *VmHost, v: *const Value) ?ReceiverShape {
    _ = self;
    _ = v;
    return null;
}

/// Whether a callable value's declared arity accepts `n_args`, or null when the
/// shape is unknown (intrinsics, bound refs). `CallMemberOrValue` drops a local
/// callable that cannot take the args: Kotlin resolves the extension instead.
pub fn callableAcceptsArgs(self: *VmHost, v: *const Value, n_args: usize) ?bool {
    switch (v.*) {
        .IrClosure => |c| {
            const info = self.closures.get(@intCast(c.asPtr().id)) orelse return null;
            // A local function lowers as a closure too and may carry defaults or a
            // vararg, so its DeclSig arity is authoritative; a lambda's is exact.
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
            // The receiver may arrive through `this` or fill the first param.
            inline for ([_]usize{ 0, 1 }) |extra| {
                const k = n_args + extra;
                if (k >= required and (k <= total or has_vararg)) return true;
            }
            return false;
        },
        // Declarations, intrinsics and bound refs are opaque; unguarded.
        else => return null,
    }
}

/// True when a declared parameter type excludes `null`; "Unit" is the
/// unannotated-param placeholder and carries no information.
fn nonNullDeclared(t: ir.TypeRef) bool {
    return !t.nullable and t.name.len != 0 and !std.mem.eql(u8, t.name, "Unit");
}

/// Whether a callable value can bind this exact call: receiver-aware declared
/// arity, named arguments, and null arguments against non-nullable declared
/// parameter types. Null when the shape is unknown.
pub fn callableAcceptsCall(self: *VmHost, v: *const Value, recv: *const Value, args: []const Value, arg_names: []const ?[]const u8) ?bool {
    switch (v.*) {
        .IrClosure => |c| {
            const info = self.closures.get(@intCast(c.asPtr().id)) orelse return null;
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
                    // Without a DeclSig the body func is the declared shape: the
                    // receiver fills a leading `this`, user args bind the rest.
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
            // The receiver may arrive through `this` or fill the first param.
            inline for ([_]usize{ 0, 1 }) |extra| {
                const k = args.len + extra;
                if (k >= required and (k <= total or has_vararg)) return true;
            }
            return false;
        },
        // Declarations, intrinsics and bound refs are opaque; unguarded.
        else => return null,
    }
}

/// Whether `v` is a receiver lambda whose `this` arrives through a capture slot,
/// so a bare invocation (`proc()`) must bind the caller's implicit receiver into
/// that slot first, or the body resolves against the creation-time `this`.
pub fn closureNeedsThisCapture(self: *VmHost, v: *const Value) bool {
    if (v.* != .IrClosure) return false;
    const info = self.closures.get(@intCast(v.IrClosure.asPtr().id)) orelse return false;
    if (callValueTraceOn()) {
        std.debug.print("[needs-this] id={d} has_recv={} caps={d}\n", .{ v.IrClosure.asPtr().id, info.has_receiver, info.capture_names.len });
    }
    if (!info.has_receiver) return false;
    for (info.capture_names) |n| {
        if (std.mem.eql(u8, n, "this")) return true;
    }
    return false;
}

/// Bind `new_this` into the closure's `this` capture slot, in place through the
/// captures cell, the binding being the receiver for exactly this call.
pub fn overrideClosureThis(self: *VmHost, v: *const Value, new_this: *const Value) void {
    if (v.* != .IrClosure) return;
    const info = self.closures.get(@intCast(v.IrClosure.asPtr().id)) orelse return;
    var this_idx: ?usize = null;
    for (info.capture_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "this")) {
            this_idx = i;
            break;
        }
    }
    const ti = this_idx orelse return;
    const g = v.IrClosure.borrowMut();
    defer g.deinit();
    const slice = g.get().captures;
    if (ti < slice.len) {
        if (runtime.reclaimEnabled()) {
            new_this.retain();
            slice[ti].release(self.allocator);
        }
        slice[ti] = new_this.*;
    }
}

/// Monotonic instance identity, counting from 1.
fn nextInstanceId(self: *VmHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

/// An `IntrinsicHost` over this host's state, so HOF bindings reach the closures.
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

/// Invoke a native stdlib intrinsic, mapping `RuntimeError` signals to `EvalError`.
fn dispatchIntrinsic(self: *VmHost, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(self.allocator, "intrinsic_call_value", fqn, null, null, args);
    const keepalive = self.ka.mark();
    defer self.ka.restore(keepalive);
    self.ka.pushSlice(args);
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

/// Map a `RuntimeError` onto an `EvalError`, preserving throws, returns, suspends.
fn runtimeErrToEval(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalResult {
    switch (e) {
        // Preserve the thrown Value so try/catch can match the exception class.
        .Thrown => |v| return .{ .err = .{ .Throw = v } },
        .Return => |v| return .{ .err = .{ .NonLocalReturn = v } },
        // A suspending primitive asked to park: seed a fresh SuspendState. Each
        // enclosing `eval` frame snapshots itself as it unwinds.
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
        // Each kind maps to its `EvalError` counterpart, message carried through;
        // `{any}` would print the payload raw and re-wrap it in a second `.Type`.
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

const PadResult = union(enum) { ok: std.ArrayList(Value), err: EvalError };

/// Pad `provided` to `n_params`, evaluating each missing slot's default thunk. A
/// thunk referencing the receiver takes it from the first already-bound arg.
fn padArgsWithDefaults(
    self: *VmHost,
    allocator: Allocator,
    module_ref: ObjRef(Module),
    n_params: usize,
    provided: []const Value,
    defaults: ?[]?FuncId,
) Allocator.Error!PadResult {
    return padArgsWithDefaultsFor(self, allocator, module_ref, n_params, provided, defaults, &.{});
}

/// `padArgsWithDefaults` with the callee's parameters: an omitted `vararg` takes an
/// empty array, so the default thunks after it find their slots in place.
fn padArgsWithDefaultsFor(
    self: *VmHost,
    allocator: Allocator,
    module_ref: ObjRef(Module),
    n_params: usize,
    provided: []const Value,
    defaults: ?[]?FuncId,
    params: []const ir.Param,
) Allocator.Error!PadResult {
    var call_args: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < n_params) : (i += 1) {
        if (i < provided.len) {
            try call_args.append(allocator, provided[i]);
            continue;
        }
        const dfid: ?FuncId = if (defaults) |d| (if (i < d.len) d[i] else null) else null;
        // An omitted vararg with no default of its own is the empty array.
        if (dfid == null and i < params.len and params[i].is_vararg) {
            const empty: std.ArrayList(Value) = .empty;
            const items = try ValueList.init(allocator, empty);
            try call_args.append(allocator, runtime.ArrayData.fromBoxedList(items));
            continue;
        }
        if (dfid) |fid| {
            // A default-arg thunk in an extension body records a receiver reference
            // (`toIndex = size`) as a capture, so seed the capture slot.
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

/// Literal-only folder for a local class's body-property initializer (no thunk).
pub fn simpleLiteral(allocator: Allocator, e: *const ast.Expr) ?Value {
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
