//! Call-shaped IR exec arms and the member/global dispatch route.
//!
//! Everything `runFrameExec` dispatches for an instruction that names a
//! callee or a receiver: the call arms (plain, value, spread, super,
//! virtual, member-or-value, context), the instance/lambda/class arms that
//! build a receiver, the implicit-`this` and global load/store arms, and
//! `execCallMemberOrGlobal` — the route that decides whether a bare name is
//! a member on an implicit receiver, a companion member, a SAM invoke or a
//! top-level function, and the candidate walk that feeds it. The argument
//! readers and the index / subscript / primitive-member fast paths the arms
//! share live here too.
//!
//! The frame register file, the activation and resume machinery, and the
//! evaluator's threadlocal state all stay in `eval.zig`; this file holds no
//! module state of its own beyond its two trace/audit gates and reaches the
//! parent's only through the alias block below.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

const Const = ir.Const;
const Func = ir.Func;
const FuncId = ir.FuncId;
const ConstId = ir.ConstId;
const Module = ir.Module;
const Reg = ir.Reg;
const TypeRef = ir.TypeRef;

const eval = @import("eval.zig");

const EnclosingEntry = eval.EnclosingEntry;
const EvalError = eval.EvalError;
const EvalResult = eval.EvalResult;
const FlatCallReq = eval.FlatCallReq;
const Frame = eval.Frame;
const Step = eval.Step;
const acquireArgsCap = eval.acquireArgsCap;
const armHostFlatReq = eval.armHostFlatReq;
const cmgTraceWant = eval.cmgTraceWant;
const dispatchBump = eval.dispatchBump;
const dispatchCacheStable = eval.dispatchCacheStable;
const dumpFrameChainForDiag = eval.dumpFrameChainForDiag;
const enclosingEntriesAlloc = eval.enclosingEntriesAlloc;
const errResult = eval.errResult;
const flatEnabled = eval.flatEnabled;
const missTraceWant = eval.missTraceWant;
const nuTraceWant = eval.nuTraceWant;
const ok = eval.ok;
const popEnclosing = eval.popEnclosing;
const pushEnclosing = eval.pushEnclosing;
const pushEnclosingAccess = eval.pushEnclosingAccess;
const raiseStep = eval.raiseStep;
const takeHostFlatArm = eval.takeHostFlatArm;
const takeHostFlatReq = eval.takeHostFlatReq;
const vcallFlatEnabled = eval.vcallFlatEnabled;

/// Whether a prepared direct call is a plain one the leaf serve may take: no
/// closure captures, no seeded receiver chain, no coroutine boundary, no
/// type arguments, nothing the activation's open/teardown would have to
/// carry. Anything the prepare pushed for the callee stays on the frame path.
/// A flat request that carries nothing beyond its callee and arguments — no
/// captures, receiver chain, closure identity, type arguments, keepalive,
/// context mark, scope guard, composer push or coroutine boundary. Such a
/// request is reproducible from the call site alone.
fn leafPlainReq(req: FlatCallReq) bool {
    return req.captures.items.len == 0 and
        req.chain.len == 0 and
        req.closure_id == null and
        req.type_args.len == 0 and
        req.keepalive == null and
        req.typed_saved == null and
        req.ctx_mark_override == null and
        req.pop_enclosing_n == 0 and
        req.scope_guard_ident == 0 and
        !req.composer_pushed and
        !req.suspend_barrier and
        !req.root_pump and
        req.owning == null;
}

/// Whether the named environment variable is present. Used only by the
/// optional throw-trace diagnostic. Reads the process environment portably
/// (see `runtime.procEnvIsSet`).
pub fn envVarSet(name: []const u8) bool {
    return runtime.procEnvIsSet(std.heap.page_allocator, name);
}

/// Fetch the string text of a `Const.String` const, or `null` when the
/// const is not a string.
pub fn constStr(module: *const Module, id: ConstId) ?[]const u8 {
    return switch (module.consts.items[id.int()]) {
        .String => |s| s,
        else => null,
    };
}

/// A callable reference (`Long::toByte`, `recv::method`) is represented as a
/// synth `Instance` whose class name is `$bound_ref$<name>`. Such a value is
/// invocable even though it carries no `invoke` member declaration.
fn isBoundRefInstance(v: *const Value) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.startsWith(u8, cg.get().name, "$bound_ref$");
}

/// Outlined `execInst` arm — see `execInst`.
/// `allow_flat = false` masks the three flat-driver parks, forcing the
/// recursive serving path (`KLIO_FLAT=0` semantics) for that site. A flat
/// park is CORRECT from a transpiled native body — `afterStep` routes it
/// and the driver serves the callee — but it unwinds the native function
/// off the C stack on every call and resumes it through the stream; the
/// transpiler's call op serves recursively instead so the native caller
/// stays put, until `NATIVE_RECURSE_MAX_DEPTH`, where it reverts to the
/// flat park to bound the C stack.
const snapshot_fast = @import("snapshot_fast.zig");
const compose_fast = @import("compose_fast.zig");

/// Classify `f` for host service (memoized on `Func.host_route`) and
/// serve `args` on a routed hit. The shared core behind the static-call
/// arm and the CMG global-replay arm — any dispatch path that has
/// resolved a plain global target and its positional arguments can
/// consult it.
pub fn hostRouteServe(comptime H: type, allocator: Allocator, f: *const ir.Func, args: []const Value, host: *H) ?Value {
    if (f.host_route == 0) {
        const route: snapshot_fast.Route = blk: {
            if (f.params.len > 3) break :blk .none;
            const last_ty: []const u8 = if (f.params.len == 0) "" else f.params[f.params.len - 1].ty.name;
            break :blk snapshot_fast.classify(f.fqn, f.params.len, last_ty);
        };
        @constCast(f).host_route = @intFromEnum(route);
    }
    if (f.host_route <= @intFromEnum(snapshot_fast.Route.none)) return composeRouteServe(allocator, f, args);
    switch (@as(snapshot_fast.Route, @enumFromInt(f.host_route))) {
        .readable => {
            if (args.len != 3) return null;
            return snapshot_fast.serveReadable(args);
        },
        .valid => {
            if (args.len != 3) return null;
            return snapshot_fast.serveValid(args);
        },
        .current_snapshot => {
            if (args.len != 0) return null;
            if (comptime !@hasDecl(H, "composeSnapshotGlobals")) return null;
            const g = host.composeSnapshotGlobals() orelse return null;
            return snapshot_fast.serveCurrentSnapshot(&g.ts, &g.gs);
        },
        .readable_state => {
            if (args.len != 2) return null;
            if (comptime !@hasDecl(H, "composeSnapshotGlobals")) return null;
            const g = host.composeSnapshotGlobals() orelse return null;
            return snapshot_fast.serveReadableState(args, &g.ts, &g.gs);
        },
        .current_record => {
            if (args.len != 1) return null;
            if (comptime !@hasDecl(H, "composeSnapshotGlobals")) return null;
            const g = host.composeSnapshotGlobals() orelse return null;
            return snapshot_fast.serveCurrentRecord(args, &g.ts, &g.gs);
        },
        .current_with_snapshot => {
            if (args.len != 2) return null;
            return snapshot_fast.serveCurrentWithSnapshot(args);
        },
        else => return null,
    }
}

/// Compose's one-line helpers (`IntStack`, the composite-key rotation)
/// answered by the host at the same seam. Classified once per body, and any
/// shape the serve cannot prove falls through to the interpreted body.
var compose_fast_state: u8 = 0;
var compose_fast_mask: u8 = 255;

/// `KLIO_COMPOSE_FAST` is a bisect mask over the compose serves: bit0 the
/// stack/key helpers (IntStack and the generic `Stack<T>` family), bit1 the
/// changelist push, bit2 its argument assertion, bit3 the write scope, bit4
/// the slot-table index math, bit5 the reader / writer / drain-cursor
/// family (and the observer-holder refresh), bit6 the throw-capable
/// changelist wrapper serve, bit7 the whole `Operations.push(op) { args }`
/// serve (boxed WriteScope receiver). 0 keeps every helper interpreted.
fn composeFastMask() u8 {
    if (compose_fast_state == 0) {
        const raw = runtime.envOnce("KLIO_COMPOSE_FAST") orelse "255";
        compose_fast_mask = std.fmt.parseInt(u8, raw, 10) catch 255;
        compose_fast_state = 1;
    }
    return compose_fast_mask;
}

/// Serves that can RAISE — reached from the same seams as `hostRouteServe`
/// but with the full result channel. Null = decline (the framed body runs).
/// One resident: the changelist wrapper `executeWithComposeStackTrace`,
/// whose body with a NULL errorContext is exactly
/// `getGroupAnchor(slots); execute(applier, slots, rememberManager, null)`
/// with a catch that RETHROWS UNCHANGED (`attachComposeStackTrace` returns
/// `this` for a null context) — so forwarding the two member dispatches
/// preserves semantics while dropping the wrapper's frame. Both dispatches
/// re-resolve against the live enclosing chain (the operation object the
/// wrapper's own dispatch pushed), exactly as the interpreted body's
/// CallMemberOrGlobal arms would. A non-null errorContext declines.
pub fn hostRouteServeThrowing(comptime H: type, allocator: Allocator, module: *const Module, f: *const ir.Func, args: []const Value, host: *H) Allocator.Error!?EvalResult {
    if (comptime !@hasDecl(H, "callMemberNamed")) return null;
    const mask = composeFastMask();
    if (mask & (64 | 128 | 32 | 1) == 0) return null;
    if (f.throw_route == 0) {
        const r: u8 = blk: {
            if (f.params.len == 5) {
                if (std.mem.endsWith(u8, f.fqn, "gapbuffer.changelist.Operation.executeWithComposeStackTrace"))
                    break :blk 2;
                if (std.mem.endsWith(u8, f.fqn, "linkbuffer.changelist.Operation.executeWithComposeStackTrace"))
                    break :blk 3;
            }
            if (f.params.len == 3) {
                if (std.mem.endsWith(u8, f.fqn, "gapbuffer.changelist.Operations.push")) break :blk 4;
                // The link-buffer push additionally aggregates the op's
                // visibility into `requiresApplication` — it must ride its
                // own pure serve, never the gap one (the recorded
                // MovableContentTests trap).
                if (std.mem.endsWith(u8, f.fqn, "linkbuffer.changelist.Operations.push")) break :blk 5;
            }
            if (f.params.len == 1) {
                if (std.mem.endsWith(u8, f.fqn, ".CompositionObserverHolder.current")) break :blk 6;
                if (std.mem.eql(u8, f.fqn, "androidx.compose.runtime.Stack.pop")) break :blk 8;
            }
            if (f.params.len == 2) {
                if (std.mem.eql(u8, f.fqn, "androidx.compose.runtime.Stack.push")) break :blk 7;
            }
            break :blk 1;
        };
        @constCast(f).throw_route = r;
    }
    switch (f.throw_route) {
        2, 3 => {
            if (mask & 64 == 0) return null;
            if (args.len != 5) return null;
            if (args[4] != .Null) return null;
            if (args[0] != .Instance) return null;
            const anchor_name: []const u8 = if (f.throw_route == 2) "getGroupAnchor" else "getGroupHandle";
            switch (try host.callMemberNamed(allocator, &args[0], anchor_name, args[2..3], &.{})) {
                .ok => |anchor| anchor.release(allocator),
                .err => |e| return .{ .err = e },
            }
            return try host.callMemberNamed(allocator, &args[0], "execute", args[1..5], &.{});
        },
        4, 5 => {
            // `Operations.push(operation) { args }` with the upstream debug
            // checks compiled out is exactly `pushOp(operation);
            // WriteScope(this).args()`. The pushOp half is the pure serve
            // (which declines, side-effect free, when a stack must grow) —
            // the LINK-buffer variant, which also aggregates the op's
            // visibility into `requiresApplication`; the block then runs
            // against a BOXED WriteScope — value-class member dispatch
            // resolves on the instance, not on the wrapped Operations — so
            // `setObject`/`setInt` inside it route to their own serves. A
            // block throw propagates exactly as the inline body's would.
            if (comptime !(@hasDecl(H, "callValueWithThis") and @hasDecl(H, "newInstanceNamed"))) return null;
            if (mask & 128 == 0) return null;
            if (args.len != 3) return null;
            if (args[0] != .Instance) return null;
            var fqn_buf: [256]u8 = undefined;
            const base = f.fqn[0 .. f.fqn.len - "push".len];
            if (base.len + "WriteScope".len > fqn_buf.len) return null;
            @memcpy(fqn_buf[0..base.len], base);
            @memcpy(fqn_buf[base.len..][0.."WriteScope".len], "WriteScope");
            const ws_fqn = fqn_buf[0 .. base.len + "WriteScope".len];
            const ws_cid = module.classIdByFqn(ws_fqn) orelse return null;
            const pushed = if (f.throw_route == 4)
                compose_fast.servePushOp(allocator, args[0..2])
            else
                compose_fast.servePushOpLink(allocator, args[0..2]);
            if (pushed == null) return null;
            // The op is already pushed; from here nothing may decline —
            // fail loud through the error channel instead.
            const ws = switch (try host.newInstanceNamed(allocator, ws_cid, args[0..1], &.{}, null)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            defer ws.release(allocator);
            switch (try host.callValueWithThis(allocator, &args[2], &ws, &.{}, &.{})) {
                .ok => |v| v.release(allocator),
                .err => |e| return .{ .err = e },
            }
            return .{ .ok = .{ .Unit = {} } };
        },
        6 => {
            // Non-root `CompositionObserverHolder.current()`: the parent
            // context's `observerHolder` is usually the base class's
            // COMPUTED null (the pure serve declines on field absence), so
            // read it through the host's getter ladder, refresh the cached
            // observer on change, and answer the parent's observer. The
            // root arm is the pure serve's.
            if (comptime !@hasDecl(H, "getField")) return null;
            if (mask & 32 == 0) return null;
            if (args.len != 1) return null;
            if (args[0] != .Instance) return null;
            var observer: Value = .Null;
            var parent: Value = .Null;
            {
                const g = args[0].Instance.borrow();
                defer g.deinit();
                const inst = g.get();
                const root_v = inst.get("root") orelse return null;
                if (root_v != .Bool or root_v.Bool) return null;
                observer = inst.get("observer") orelse return null;
                parent = inst.get("parent") orelse return null;
            }
            if (parent != .Instance) return null;
            const ph = switch (try host.getField(allocator, &parent, "observerHolder")) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            defer ph.release(allocator);
            var parent_obs: Value = .Null;
            if (ph == .Instance) {
                const pg = ph.Instance.borrow();
                defer pg.deinit();
                parent_obs = pg.get().get("observer") orelse .Null;
            } else if (ph != .Null) return null;
            const same = (parent_obs == .Null and observer == .Null) or
                (parent_obs == .Instance and observer == .Instance and
                    parent_obs.Instance.cell == observer.Instance.cell);
            if (!same) {
                parent_obs.retain();
                const g = args[0].Instance.borrowMut();
                defer g.deinit();
                g.get().define(allocator, "observer", parent_obs) catch {
                    parent_obs.release(allocator);
                    return .{ .err = .{ .Type = "compose observer serve: refresh failed" } };
                };
            }
            parent_obs.retain();
            return .{ .ok = parent_obs };
        },
        7, 8 => {
            // `Stack<T>.push` / `Stack<T>.pop` forward to the backing
            // MutableList's own `add` / `removeAt` intrinsic, dropping the
            // wrapper frame while keeping every list-mutation guard
            // (read-only, view, comodification, mod-count) exactly as the
            // interpreted body would hit them.
            if (mask & 1 == 0) return null;
            const want_args: usize = if (f.throw_route == 7) 2 else 1;
            if (args.len != want_args) return null;
            const backing = compose_fast.stackTBacking(&args[0]) orelse return null;
            if (f.throw_route == 7) {
                return try host.callMemberNamed(allocator, &backing, "add", args[1..2], &.{});
            }
            const idx: i64 = blk: {
                const g = backing.List.items.borrow();
                defer g.deinit();
                break :blk @as(i64, @intCast(g.get().items.len)) - 1;
            };
            const idx_v: Value = if (idx >= 0 and idx <= std.math.maxInt(i32))
                .{ .Int = @intCast(idx) }
            else
                .{ .Int = -1 };
            return try host.callMemberNamed(allocator, &backing, "removeAt", &.{idx_v}, &.{});
        },
        else => return null,
    }
}

fn composeRouteServe(allocator: Allocator, f: *const ir.Func, args: []const Value) ?Value {
    const mask = composeFastMask();
    if (mask == 0) return null;
    if (f.compose_route == 0) {
        @constCast(f).compose_route = @intFromEnum(compose_fast.classify(f.fqn, f.params.len));
    }
    if (f.compose_route <= @intFromEnum(compose_fast.Route.none)) return null;
    if (args.len != f.params.len) return null;
    const route: compose_fast.Route = @enumFromInt(f.compose_route);
    const bit: u8 = switch (route) {
        .slot_anchor, .data_anchor_to_index => 16,
        .sr_next, .sr_group_key_get, .sr_group_key_at, .sr_is_group_end_get, .sr_node_count_get, .sr_node_count_at, .gap_parent_anchor, .sw_data_index, .rsi_req_recompose_get, .rsi_req_recompose_set, .gap_validate_node, .sr_start_group, .sr_end_group, .op_iter_next, .op_iter_get_int, .op_iter_get_object, .sr_object_key, .sr_group_object_key, .obs_holder_current, .sw_slot_index => 32,
        .ops_push_op, .ops_push_op_link => 2,
        .ops_ensure_args => 4,
        .ops_set_int, .ops_set_object => 8,
        else => 1,
    };
    if (mask & bit == 0) return null;
    return switch (route) {
        .compound_with => compose_fast.serveCompoundWith(args),
        .uncompound_with => compose_fast.serveUnCompoundWith(args),
        .int_stack_push => compose_fast.servePush(allocator, args),
        .int_stack_pop => compose_fast.servePop(args),
        .int_stack_pop_or => compose_fast.servePopOr(args),
        .int_stack_peek => compose_fast.servePeek(args),
        .int_stack_peek2 => compose_fast.servePeek2(args),
        .int_stack_peek_at => compose_fast.servePeekAt(args),
        .int_stack_peek_or => compose_fast.servePeekOr(args),
        .int_stack_is_empty => compose_fast.serveIsEmpty(args),
        .int_stack_is_not_empty => compose_fast.serveIsNotEmpty(args),
        .int_stack_clear => compose_fast.serveClear(args),
        .int_stack_size => compose_fast.serveSize(args),
        .ops_push_op => compose_fast.servePushOp(allocator, args),
        .ops_push_op_link => compose_fast.servePushOpLink(allocator, args),
        .ops_ensure_args => compose_fast.serveEnsureArgs(args),
        .ops_set_int => compose_fast.serveSetInt(allocator, args),
        .ops_set_object => compose_fast.serveSetObject(allocator, args),
        .slot_anchor => compose_fast.serveSlotAnchor(args),
        .data_anchor_to_index => compose_fast.serveDataAnchorToDataIndex(args),
        .sr_next => compose_fast.serveSlotReaderNext(args),
        .sr_group_key_get => compose_fast.serveSlotReaderGroupKeyGet(args),
        .sr_group_key_at => compose_fast.serveSlotReaderGroupKeyAt(args),
        .sr_is_group_end_get => compose_fast.serveSlotReaderIsGroupEnd(args),
        .sr_node_count_get => compose_fast.serveSlotReaderNodeCountGet(args),
        .sr_node_count_at => compose_fast.serveSlotReaderNodeCountAt(args),
        .gap_parent_anchor => compose_fast.serveGapParentAnchor(args),
        .sw_data_index => compose_fast.serveSlotWriterDataIndex(args),
        .rsi_req_recompose_get => compose_fast.serveRsiRequiresRecomposeGet(args),
        .rsi_req_recompose_set => compose_fast.serveRsiRequiresRecomposeSet(args),
        .gap_validate_node => compose_fast.serveValidateNodeNotExpected(args),
        .sr_start_group => compose_fast.serveSlotReaderStartGroup(args),
        .sr_end_group => compose_fast.serveSlotReaderEndGroup(args),
        .op_iter_next => compose_fast.serveOpIterNext(args),
        .op_iter_get_int => compose_fast.serveOpIterGetInt(args),
        .op_iter_get_object => compose_fast.serveOpIterGetObject(args),
        .sr_object_key => compose_fast.serveSlotReaderObjectKey(args),
        .obs_holder_current => compose_fast.serveObserverHolderCurrent(allocator, args),
        .sw_slot_index => compose_fast.serveSlotWriterSlotIndex(args),
        .sr_group_object_key => compose_fast.serveSlotReaderGroupObjectKey(args),
        .stack_t_is_empty => compose_fast.serveStackTIsEmpty(args),
        .stack_t_is_not_empty => compose_fast.serveStackTIsNotEmpty(args),
        .stack_t_peek => compose_fast.serveStackTPeek(args, null),
        .stack_t_peek_at => if (args[1] == .Int) compose_fast.serveStackTPeek(args, args[1].Int) else null,
        else => null,
    };
}

/// Host-served static fns (the snapshot validity walk): classify once
/// per Func, serve without any call machinery on a hit.
inline fn hostStaticServe(comptime H: type, allocator: Allocator, frame: *Frame, call: anytype, host: *H) Allocator.Error!?Value {
    const cf = frame.module.funcById(call.func) orelse return null;
    if (call.type_args.len != 0 or !argNamesAllNull(call.arg_names)) return null;
    var args: [3]Value = undefined;
    if (call.n_args > 3) return null;
    for (0..call.n_args) |i| args[i] = frame.read(ir.Reg.from(call.args.int() + @as(u32, @intCast(i))));
    return hostRouteServe(H, allocator, cf, args[0..call.n_args], host);
}

pub noinline fn execArmCall(comptime H: type, allocator: Allocator, frame: *Frame, call: anytype, host: *H, allow_flat: bool) Allocator.Error!Step {
    if (cmgTraceWant()) |w| {
        if (frame.module.funcById(call.func)) |cf| if (std.mem.eql(u8, w, cf.name)) {
            std.debug.print("[call-inst] {s}#{d} n_args={d} n_names={d} exact={} caller={s}", .{ cf.name, call.func.int(), call.n_args, call.arg_names.len, call.exact, frame.func.name });
            const base = call.args.int();
            var i: usize = 0;
            while (i < call.n_args and i < 4) : (i += 1) {
                if (base + i < frame.regs.items.len) {
                    const v = &frame.regs.items[base + i];
                    switch (v.*) {
                        .Int => |x| std.debug.print(" a{d}=i{d}", .{ i, x }),
                        .Long => |x| std.debug.print(" a{d}=L{d}", .{ i, x }),
                        .Instance => |inst| {
                            const g = inst.borrow();
                            const cg = g.get().class.borrow();
                            std.debug.print(" a{d}={s}@{x}", .{ i, cg.get().name, inst.identity() });
                            cg.deinit();
                            g.deinit();
                        },
                        else => std.debug.print(" a{d}={s}", .{ i, @tagName(std.meta.activeTag(v.*)) }),
                    }
                }
            }
            std.debug.print("\n", .{});
        };
    }
    dispatchBump(.call_static);
    if (try hostStaticServe(H, allocator, frame, call, host)) |served| {
        try frame.write(call.dst, served);
        return .cont;
    }
    // Scalar-replay leaf (`kl_`): when a leaf library is registered
    // (KLIO_LEAVES), a pure scalar callee runs as direct C — bail is a
    // pure no-op and the ordinary paths below re-run the call exactly.
    if (try eval.tryLeafCall(H, allocator, frame, call, host, null)) |st| return st;
    // Monomorphic fast path: a plain top-level user function (single
    // overload, has body, non-extension, no varargs / defaults / type
    // params / native binding) called positionally at exact arity needs
    // none of the overload re-resolution, extension-receiver handling,
    // reified-type binding, or redundant arg copying below. Dispatch it
    // straight to the body with the arg buffer transferred as params.
    if (comptime @hasDecl(H, "callFuncFast")) {
        if (call.type_args.len == 0 and argNamesAllNull(call.arg_names)) {
            if (frame.module.funcById(call.func)) |cf| {
                var plan = cf.fast_call;
                if (plan == 0) {
                    plan = host.fastCallPlan(frame.module, call.func);
                    @constCast(cf).fast_call = plan;
                }
                // The low bits carry the eligible arity + 2; a positional,
                // exact-arity call dispatches straight to the body.
                const plan_arity = plan & 0x1FFF;
                // Same-name, same-arity peers: only this SITE's scope can say
                // whether the baked target is the one resolution picks, so ask
                // once and keep the verdict on the instruction.
                var ambig_ok = true;
                if (plan & ir.FAST_CALL_AMBIG_FLAG != 0) {
                    if (comptime @hasDecl(H, "fuseSiteBinds")) {
                        var verdict = @atomicLoad(u8, @constCast(&call.fuse_site), .acquire);
                        if (verdict == 0) {
                            const cfile: ?ir.FileId = if (frame.cur_span) |sp| sp.file else null;
                            verdict = if (host.fuseSiteBinds(frame.module, call.func, frame.func.package, cfile)) 2 else 1;
                            @atomicStore(u8, @constCast(&call.fuse_site), verdict, .release);
                        }
                        ambig_ok = verdict == 2;
                    } else {
                        ambig_ok = false;
                    }
                }
                if (ambig_ok and plan_arity >= 2 and plan_arity - 2 == call.n_args) {
                    const args_list = try readArgList(allocator, frame, call.args, call.n_args);
                    // A receiver-carrying body: seed the caller's instance
                    // `this` as the enclosing receiver exactly as the full
                    // path below does (lexical scope for a member extension,
                    // dispatch visibility for anything else).
                    var pushed_enclosing = false;
                    if (plan & ir.FAST_CALL_EXT_FLAG != 0) {
                        if (frameThisParam(frame)) |ct_idx| {
                            const p = frame.params.items[ct_idx];
                            if (p == .Instance) {
                                const same = args_list.items.len > 0 and args_list.items[0] == .Instance and
                                    ObjRef(InstanceData).ptrEq(p.Instance, args_list.items[0].Instance);
                                if (!same) {
                                    if (cf.kind == .member_extension) {
                                        pushEnclosing(&frame.params.items[ct_idx]);
                                    } else {
                                        pushEnclosingAccess(&frame.params.items[ct_idx]);
                                    }
                                    pushed_enclosing = true;
                                }
                            }
                        }
                    }
                    if (plan & ir.FAST_CALL_EXT_FLAG != 0) dispatchBump(.static_flat_fuse_ext) else dispatchBump(.static_flat_fuse);
                    // The flat driver runs the body as a pushed activation in
                    // the same dispatch loop — no native recursion per call.
                    if (allow_flat and flatEnabled()) {
                        const composer_pushed = if (comptime @hasDecl(H, "flatPlainCallOpen"))
                            host.flatPlainCallOpen(cf, args_list.items)
                        else
                            false;
                        frame.flat_call = .{
                            .func = cf,
                            .args = args_list,
                            .composer_pushed = composer_pushed,
                            .dst = call.dst,
                            .pop_enclosing_n = if (pushed_enclosing) 1 else 0,
                        };
                        return .flat_call;
                    }
                    const fast_res = try host.callFuncFast(allocator, frame.module, call.func, args_list);
                    if (pushed_enclosing) popEnclosing();
                    switch (fast_res) {
                        .ok => |result| try frame.write(call.dst, result),
                        .err => |e| return raiseStep(frame, e),
                    }
                    return .cont;
                }
            }
        }
    }
    var arg_values = try readArgRun(allocator, frame, call.args, call.n_args);
    defer allocator.free(arg_values);
    var names = try resolveArgNames(allocator, frame.module, call.arg_names);
    defer freeArgNames(allocator, names);
    var ta: std.ArrayList([]const u8) = .empty;
    defer ta.deinit(allocator);
    for (call.type_args) |c| {
        try ta.append(allocator, constStr(frame.module, c) orelse "");
    }

    // Undispatched-start boundary (`__klio_co_startRootOrSuspended` under
    // an enclosing pump): run the block as a BARRIER activation on this
    // driver — a suspension parks the segment into the pump and this frame
    // continues with COROUTINE_SUSPENDED, with no native pump entry and no
    // frame snapshots per call.
    if (comptime @hasDecl(H, "prepareUndispatchedStartFlatCall")) {
        if (allow_flat and flatEnabled() and argNamesAllNull(call.arg_names)) {
            if (try host.prepareUndispatchedStartFlatCall(allocator, frame.module, call.func, arg_values)) |prep0| {
                var prep = prep0;
                prep.dst = call.dst;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }

    const bakedExt = struct {
        fn f(m: *const Module, id: FuncId) bool {
            const ff = m.funcById(id) orelse return false;
            const fp = ff.params;
            return fp.len > 0 and std.mem.eql(u8, fp[0].name, "this");
        }
    }.f;
    const baked_is_ext = bakedExt(frame.module, call.func);

    // Named-argument overload re-resolution. The lowerer baked the
    // call to a positional-arity heuristic FuncId; a named call may
    // really target a sibling overload (Kotlin resolves named calls
    // by parameter name). The receiver is reachable here, so an
    // implicit extension receiver can be supplied before dispatch.
    var eff_func = call.func;
    if (!call.exact) {
        var any_named = false;
        for (names) |n| {
            if (n != null) any_named = true;
        }
        if (any_named) {
            // The implicit extension receiver is in scope (a bare
            // call inside an extension/method body) but absent from
            // `args` only when the baked target is not itself an
            // extension — otherwise the lowerer already prepended it.
            const caller_this = frameThisParam(frame);
            const recv_external = caller_this != null and !baked_is_ext;
            const recv_val: ?*const Value = if (recv_external) blk: {
                const ct_idx = caller_this orelse break :blk null;
                break :blk &frame.params.items[ct_idx];
            } else null;
            const named_pick: ?FuncId = if (comptime @hasDecl(H, "pickNamedOverloadIdRecv"))
                host.pickNamedOverloadIdRecv(frame.module, call.func, arg_values, names, recv_external, recv_val)
            else
                host.pickNamedOverloadId(frame.module, call.func, arg_values, names, recv_external);
            if (named_pick) |picked| {
                eff_func = picked;
                const picked_is_ext = bakedExt(frame.module, picked);
                if (picked_is_ext and !baked_is_ext) {
                    if (caller_this) |ct_idx| {
                        // Supply the enclosing `this` as the leading
                        // (unnamed) receiver argument the chosen
                        // extension overload expects.
                        const recv = frame.params.items[ct_idx];
                        const na = try allocator.alloc(Value, arg_values.len + 1);
                        na[0] = recv;
                        @memcpy(na[1..], arg_values);
                        // `arg_values`/`names` are owned by the
                        // single `defer allocator.free(...)` above;
                        // free the original buffers before replacing
                        // the pointers so each is freed exactly once.
                        allocator.free(arg_values);
                        arg_values = na;
                        const nn = try allocator.alloc(?[]const u8, names.len + 1);
                        nn[0] = null;
                        @memcpy(nn[1..], names);
                        freeArgNames(allocator, names);
                        names = nn;
                    }
                }
            }
        }
    }

    // Invoking an extension / member-extension function from
    // inside a method: keep the caller's instance `this`
    // reachable as the enclosing receiver.
    const callee_fn: ?*const Func = frame.module.funcById(eff_func);
    const callee_is_ext = callee_fn != null and callee_fn.?.params.len > 0 and
        std.mem.eql(u8, callee_fn.?.params[0].name, "this");
    var pushed_enclosing = false;
    if (callee_is_ext) {
        const caller_this = frameThisParam(frame);
        if (caller_this) |ct_idx| {
            const p = frame.params.items[ct_idx];
            if (p == .Instance) {
                const same = arg_values.len > 0 and arg_values[0] == .Instance and
                    ObjRef(InstanceData).ptrEq(p.Instance, arg_values[0].Instance);
                if (!same) {
                    // A member-extension's body has its declaring
                    // class's `this` in lexical scope (the
                    // dispatch receiver); a plain extension's body
                    // does not — the push is then dispatch
                    // visibility only.
                    if (callee_fn.?.kind == .member_extension) {
                        pushEnclosing(&frame.params.items[ct_idx]);
                    } else {
                        pushEnclosingAccess(&frame.params.items[ct_idx]);
                    }
                    pushed_enclosing = true;
                }
            }
        }
    }
    // Flat typed call: the resolved plain shape runs as a pushed
    // activation carrying its reified type-name bindings (restored at
    // teardown/park) and the call's type args for the boundary
    // transform. Special shapes decline to the recursive path.
    if (comptime @hasDecl(H, "prepareTypedFlatCall")) {
        if (allow_flat and flatEnabled() and ta.items.len > 0 and argNamesAllNull(call.arg_names)) {
            if (try host.prepareTypedFlatCall(allocator, frame.module, eff_func, arg_values, ta.items, call.exact)) |prep0| {
                var prep = prep0;
                prep.dst = call.dst;
                prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    if (call.trailing_lambda) {
        if (comptime @hasDecl(H, "setTrailingLambdaCall")) H.setTrailingLambdaCall(true);
    }
    const res = host.callFuncTyped(allocator, frame.module, eff_func, arg_values, names, ta.items, call.exact);
    if (call.trailing_lambda) {
        if (comptime @hasDecl(H, "setTrailingLambdaCall")) H.setTrailingLambdaCall(false);
    }
    if (pushed_enclosing) popEnclosing();
    switch (try res) {
        .ok => |result| try frame.write(call.dst, result),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCallValue(comptime H: type, allocator: Allocator, frame: *Frame, cv: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_value);
    const callee_v = frame.read(cv.callee);
    if (runtime.envOnce("KLIO_TRACE_PATH") != null) {
        if (callee_v == .IrClosure) {
            std.debug.print("[cv-callee] in={s} kind=IrClosure id={d}\n", .{ frame.func.name, callee_v.IrClosure.id });
        } else {
            std.debug.print("[cv-callee] in={s} kind={s}\n", .{ frame.func.name, @tagName(std.meta.activeTag(callee_v)) });
        }
    }
    var arg_values_list: std.ArrayList(Value) = .empty;
    defer arg_values_list.deinit(allocator);
    {
        const tmp = try readArgRun(allocator, frame, cv.args, cv.n_args);
        defer allocator.free(tmp);
        try arg_values_list.appendSlice(allocator, tmp);
    }
    var names_list: std.ArrayList(?[]const u8) = .empty;
    defer names_list.deinit(allocator);
    {
        const tmp = try resolveArgNames(allocator, frame.module, cv.arg_names);
        defer freeArgNames(allocator, tmp);
        try names_list.appendSlice(allocator, tmp);
    }
    if (runtime.envOnce("KLIO_TRACE_PATH") != null) {
        for (arg_values_list.items, 0..) |*av, ai| {
            std.debug.print("[cv-arg] in={s} #{d} kind={s}\n", .{ frame.func.name, ai, @tagName(std.meta.activeTag(av.*)) });
        }
    }
    // Receiver-typed lambda bare invocation: prepend the calling
    // frame's `this` when the closure expects a leading `this`.
    const caller_this = callerThisValue(frame);
    if (host.callableReceiverShape(&callee_v)) |shape| {
        if (shape.first_is_this and arg_values_list.items.len + 1 == shape.n_params) {
            if (caller_this) |ct| {
                try arg_values_list.insert(allocator, 0, ct);
                try names_list.insert(allocator, 0, null);
            }
        }
    }
    // Receiver lambda whose `this` arrives via a captured slot.
    if (host.closureNeedsThisCapture(&callee_v)) {
        if (caller_this) |ct| {
            host.overrideClosureThis(&callee_v, &ct);
        }
    }
    // No caller-`this` push here: a closure's body resolves bare
    // names against its creation-time receiver chain (lexical
    // scope); a receiver-typed lambda gets its subject through the
    // receiver-split / `this`-capture binding above. Pushing the
    // dynamic caller's `this` would hand the body a receiver it
    // never lexically saw.
    //
    // Flat closure dispatch: a plain positional exact-arity closure call
    // runs as a pushed activation in the flat driver. The host performs the
    // same resolution and binding the recursive path would, then hands back
    // the ready call instead of invoking the evaluator itself.
    if (comptime @hasDecl(H, "prepareClosureFlatCall")) {
        if (flatEnabled() and callee_v == .IrClosure and cv.type_args.len == 0 and argNamesAllNull(cv.arg_names)) {
            if (try host.prepareClosureFlatCall(allocator, &callee_v, arg_values_list.items)) |prep0| {
                var prep = prep0;
                prep.dst = cv.dst;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    const result = blk: {
        // Explicit call-site type args reach the host so an
        // unsigned element-type argument can coerce integral
        // literals before the intrinsic (`arrayOf<ULong>(1u)`).
        if (cv.type_args.len != 0) {
            var ta_buf: [4][]const u8 = undefined;
            const n_ta = @min(cv.type_args.len, ta_buf.len);
            for (cv.type_args[0..n_ta], ta_buf[0..n_ta]) |cid, *slot| {
                slot.* = constStr(frame.module, cid) orelse "";
            }
            break :blk host.callValueNamedTyped(allocator, &callee_v, arg_values_list.items, names_list.items, ta_buf[0..n_ta]);
        }
        break :blk host.callValueNamed(allocator, &callee_v, arg_values_list.items, names_list.items);
    };
    switch (try result) {
        .ok => |rv| {
            var out = rv;
            // A stdlib container creator dispatched as an
            // intrinsic value records its call-site type-argument
            // heads on the built container.
            if (cv.type_args.len != 0 and callee_v == .Intrinsic) {
                var ta: std.ArrayList([]const u8) = .empty;
                defer ta.deinit(allocator);
                for (cv.type_args) |c| {
                    try ta.append(allocator, constStr(frame.module, c) orelse "");
                }
                runtime.attachDeclaredElemTypes(callee_v.Intrinsic.fqn, ta.items, &out);
            }
            try frame.write(cv.dst, out);
        },
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCallSpread(comptime H: type, allocator: Allocator, frame: *Frame, cs: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_spread);
    const callee_v = frame.read(cs.callee);
    var arg_values: std.ArrayList(Value) = .empty;
    defer arg_values.deinit(allocator);
    var effective_names: std.ArrayList(?[]const u8) = .empty;
    defer effective_names.deinit(allocator);
    var effective_params: std.ArrayList(u32) = .empty;
    defer effective_params.deinit(allocator);
    const in_names = try resolveArgNames(allocator, frame.module, cs.arg_names);
    defer freeArgNames(allocator, in_names);
    for (cs.parts, 0..) |part, i| {
        const v = frame.read(part.reg);
        const name: ?[]const u8 = if (i < in_names.len) in_names[i] else null;
        const param: ?u32 = if (cs.arg_params) |params|
            (if (i < params.len) params[i] else null)
        else
            null;
        if (part.is_spread) {
            switch (try spreadItems(allocator, &v)) {
                .ok => |items| {
                    defer allocator.free(items);
                    for (items) |item| {
                        try arg_values.append(allocator, item);
                        try effective_names.append(allocator, null);
                        if (param) |index| try effective_params.append(allocator, index);
                    }
                },
                .err => |e| return raiseStep(frame, e),
            }
        } else {
            try arg_values.append(allocator, v);
            try effective_names.append(allocator, name);
            if (param) |index| try effective_params.append(allocator, index);
        }
    }
    if (cs.virtual_slot) |slot| {
        if (comptime !@hasDecl(H, "invokeVirtualMember")) {
            return raiseStep(frame, .{ .Type = "virtual CallSpread is unsupported by this host" });
        }
        if (cs.arg_params == null or effective_params.items.len != arg_values.items.len) {
            return raiseStep(frame, .{ .Type = "virtual CallSpread has an invalid parameter map" });
        }
        callee_v.retain();
        defer callee_v.release(allocator);
        const prev_tl = if (cs.trailing_lambda and comptime @hasDecl(H, "setTrailingMemberCall"))
            H.setTrailingMemberCall(true)
        else
            false;
        const result = host.invokeVirtualMember(
            allocator,
            &callee_v,
            slot,
            arg_values.items,
            &.{},
            effective_params.items,
            null,
        );
        if (cs.trailing_lambda) {
            if (comptime @hasDecl(H, "setTrailingMemberCall")) _ = H.setTrailingMemberCall(prev_tl);
        }
        switch (try result) {
            .ok => |rv| try frame.write(cs.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else if (cs.member) |mid| {
        const mname = constStr(frame.module, mid) orelse
            return raiseStep(frame, .{ .Type = "CallSpread: member not a string const" });
        // The receiver is borrowed for the call's whole duration;
        // pin it across dispatch (the body may drop other refs).
        callee_v.retain();
        defer callee_v.release(allocator);
        switch (try host.callMemberNamed(allocator, &callee_v, mname, arg_values.items, effective_names.items)) {
            .ok => |rv| try frame.write(cs.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else if (cs.candidates != null) {
        const name_id = cs.name orelse
            return raiseStep(frame, .{ .Type = "CallSpread: bounded call has no name" });
        const name = constStr(frame.module, name_id) orelse
            return raiseStep(frame, .{ .Type = "CallSpread: name not a string const" });
        const anchor_pkg = if (cs.anchor_pkg) |pkg_id|
            constStr(frame.module, pkg_id) orelse ""
        else
            "";
        const caller_file: ?ir.FileId = if (frame.cur_span) |sp| sp.file else null;
        const overload = switch (try host.callNamedOverload(
            allocator,
            frame.module,
            cs.candidates,
            name,
            arg_values.items,
            effective_names.items,
            null,
            false,
            frame.func.package,
            caller_file,
            anchor_pkg,
        )) {
            .ok => |maybe| maybe,
            .err => |e| return raiseStep(frame, e),
        };
        if (overload) |rv| {
            try frame.write(cs.dst, rv);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "unresolved spread overload `{s}`", .{name});
            return raiseStep(frame, .{ .Type = msg });
        }
    } else {
        switch (try host.callValueNamed(allocator, &callee_v, arg_values.items, effective_names.items)) {
            .ok => |rv| try frame.write(cs.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCallSuper(comptime H: type, allocator: Allocator, frame: *Frame, csup: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_super);
    const recv = frame.read(csup.receiver);
    recv.retain();
    defer recv.release(allocator);
    const owner_str = constStr(frame.module, csup.owner_class) orelse
        return raiseStep(frame, .{ .Type = "CallSuper: owner not a string const" });
    const qual_str: ?[]const u8 = if (csup.qualifier) |id| constStr(frame.module, id) else null;
    const name_str = constStr(frame.module, csup.name) orelse
        return raiseStep(frame, .{ .Type = "CallSuper: name not a string const" });
    const arg_values = try readArgRun(allocator, frame, csup.args, csup.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, csup.arg_names);
    defer freeArgNames(allocator, names);
    switch (try host.callSuper(allocator, &recv, owner_str, qual_str, name_str, arg_values, names)) {
        .ok => |rv| try frame.write(csup.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Execute a statically selected virtual slot. Unlike `CallMember`, this arm
/// has no name-based fallback: a missing slot is a link error in the program
/// image and is reported by the host.
pub noinline fn execArmCallVirtual(comptime H: type, allocator: Allocator, frame: *Frame, cv: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_virtual_slot);
    if (comptime !@hasDecl(H, "invokeVirtualMember")) {
        return raiseStep(frame, .{ .Type = "CallVirtual is unsupported by this host" });
    }
    const recv = frame.read(cv.receiver);
    recv.retain();
    defer recv.release(allocator);
    const args = try readArgRun(allocator, frame, cv.args, cv.n_args);
    defer allocator.free(args);
    // Flat virtual dispatch: a slot resolved against a named receiver class
    // to an interpreted body at the fully-applied no-vararg shape runs as a
    // pushed activation on this driver, skipping the recursive invoker's
    // per-call frame ceremony. Everything else falls through unchanged.
    if (comptime @hasDecl(H, "prepareVirtualFlatCall")) {
        if (flatEnabled() and vcallFlatEnabled() and cv.arg_params == null and argNamesAllNull(cv.arg_names)) {
            if (try host.prepareVirtualFlatCall(allocator, &recv, cv.slot, args)) |prep0| {
                dispatchBump(.virtual_flat_prepare);
                var prep = prep0;
                prep.dst = cv.dst;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    const names = try resolveArgNames(allocator, frame.module, cv.arg_names);
    defer freeArgNames(allocator, names);
    const prev_tl = if (cv.trailing_lambda and comptime @hasDecl(H, "setTrailingMemberCall"))
        H.setTrailingMemberCall(true)
    else
        false;
    // Host-receiver site memo handles: only a plain positional call may
    // stamp or replay (the memoized direct dispatch binds positionally).
    const site: ?ir.VirtNativeSite = if (cv.arg_params == null and argNamesAllNull(cv.arg_names))
        .{
            .cls = @constCast(&cv.site_cls),
            .native = @constCast(&cv.site_native),
            .name_ptr = @constCast(&cv.site_name_ptr),
            .name_len = @constCast(&cv.site_name_len),
        }
    else
        null;
    const result = host.invokeVirtualMember(allocator, &recv, cv.slot, args, names, cv.arg_params, site);
    if (cv.trailing_lambda) {
        if (comptime @hasDecl(H, "setTrailingMemberCall")) _ = H.setTrailingMemberCall(prev_tl);
    }
    switch (try result) {
        .ok => |value| try frame.write(cv.dst, value),
        .err => |err| return raiseStep(frame, err),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCallMemberOrValue(comptime H: type, allocator: Allocator, frame: *Frame, cmv: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_member_or_value);
    const recv = frame.read(cmv.receiver);
    recv.retain();
    defer recv.release(allocator);
    const user_args = try readArgRun(allocator, frame, cmv.args, cmv.n_args);
    defer allocator.free(user_args);
    const names = try resolveArgNames(allocator, frame.module, cmv.arg_names);
    defer freeArgNames(allocator, names);
    const name_str = constStr(frame.module, cmv.name) orelse
        return raiseStep(frame, .{ .Type = "CallMemberOrValue: name not a string const" });
    var fb = frame.read(cmv.fallback);
    // A boxed capture holds the callable in a cell (a captured local fn's
    // shared binding); classify and invoke the CONTENT — the sibling
    // CallValueOrMember arm unwraps identically. Without this a captured
    // `fun MockViewValidator.Composition()` fallback read as `.Cell`,
    // was judged non-invocable, and the member miss surfaced.
    if (fb == .Cell) {
        const cg = fb.Cell.borrow();
        fb = cg.get().*;
        cg.deinit();
    }
    if (nuTraceWant() != null and std.mem.eql(u8, name_str, "placementBlock")) {
        const rcls: []const u8 = if (recv == .Instance) blk: {
            const g = recv.Instance.borrow();
            const cg = g.get().class.borrow();
            const n = cg.get().name;
            cg.deinit();
            g.deinit();
            break :blk n;
        } else @tagName(recv);
        std.debug.print("[pb] in={s}#{d} recv={s} fb={s}\n", .{ frame.func.name, frame.func.id.int(), rcls, @tagName(fb) });
    }
    // The local/captured fallback only wins when the receiver has no
    // such member AND the fallback is actually invocable (a function
    // value or callable reference). A same-named non-callable local
    // (e.g. a captured `info` next to `logger.info(...)`) must not
    // shadow the real member.
    const fb_invocable = switch (fb) {
        .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
        // A class value is its constructor (`::Char` bound to an
        // `Int.() -> Char` param): invocable, receiver becomes the
        // first positional argument below.
        .Class => true,
        // A bound/unbound callable reference (`Long::toByte`,
        // `recv::method`) is a `$bound_ref$<name>` synth instance: it
        // is invocable, so `recv.refParam()` invokes the reference
        // with `recv` as its receiver rather than dispatching a member
        // named `refParam` on `recv`.
        .Instance => isBoundRefInstance(&fb) or host.hostHasMember(&fb, "invoke") or host.callableReceiverShape(&fb) != null,
        else => false,
    };
    // A local callable whose declared arity provably cannot take
    // the supplied args is not the primary candidate — Kotlin
    // resolves the member/extension instead
    // (`subList(..).sortDescending()` next to a
    // `sortDescending: TArray.(Int, Int) -> Unit` param must
    // dispatch the extension, not Null-pad the local). The proof
    // is conservative (closure shapes without a DeclSig can hide
    // defaults), so a canonical member MISS still falls back to
    // invoking the local.
    const fb_misfit = fb_invocable and
        (host.callableAcceptsCall(&fb, &recv, user_args, names) orelse true) == false;
    // A receiver whose STATIC type is an unbounded type parameter has no
    // members to shadow the local: Kotlin compiles the body once against
    // the bound (`Any?`), so `receiver.block()` inside
    // `fun <T, R> with(receiver: T, block: T.() -> R)` always binds the
    // `block` PARAMETER. Consulting the runtime class instead let a
    // same-named member hijack it — `with(node) { … }` on a node owning a
    // `block` field ran that field and skipped the whole with-body.
    const members_visible = !cmv.recv_erased and host.hostHasMember(&recv, name_str);
    if (fb_invocable and (!fb_misfit or cmv.recv_erased) and !members_visible) {
        orAudit("CallMemberOrValue", name_str, "value", -1, &recv);
        // Flat dispatch for the closure fallback: the shape-known route is
        // a plain value call, the shape-unknown route the with-this bind;
        // the declared-receiver (`fallback_takes_receiver`) route keeps
        // the recursive path.
        if (comptime @hasDecl(H, "prepareClosureWithThisFlatCall")) {
            if (flatEnabled() and fb == .IrClosure and !cmv.fallback_takes_receiver and argNamesAllNull(cmv.arg_names)) {
                const maybe = if (cmv.fallback_receiver_shape_known)
                    try host.prepareClosureFlatCall(allocator, &fb, user_args)
                else
                    try host.prepareClosureWithThisFlatCall(allocator, &fb, &recv, user_args);
                if (maybe) |prep0| {
                    var prep = prep0;
                    prep.dst = cmv.dst;
                    frame.flat_call = prep;
                    return .flat_call;
                }
            }
        }
        if (fb == .Class) {
            // Constructors take no receiver: `65.f()` with
            // `f = ::Char` is `Char(65)`.
            const adapted = try allocator.alloc(Value, user_args.len + 1);
            defer allocator.free(adapted);
            adapted[0] = recv;
            @memcpy(adapted[1..], user_args);
            const nn = try allocator.alloc(?[]const u8, names.len + 1);
            defer allocator.free(nn);
            nn[0] = null;
            @memcpy(nn[1..], names);
            switch (try host.callValueNamed(allocator, &fb, adapted, nn)) {
                .ok => |rv| try frame.write(cmv.dst, rv),
                .err => |e| return raiseStep(frame, e),
            }
        } else switch (if (cmv.fallback_takes_receiver)
            try host.callValueWithThisExact(allocator, &fb, &recv, user_args, names)
        else if (cmv.fallback_receiver_shape_known)
            try host.callValueNamed(allocator, &fb, user_args, names)
        else
            try host.callValueWithThis(allocator, &fb, &recv, user_args, names)) {
            .ok => |rv| try frame.write(cmv.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else {
        orAudit("CallMemberOrValue", name_str, "member", 0, &recv);
        const r = try host.callMemberNamed(allocator, &recv, name_str, user_args, names);
        const member_missed = r == .err and r.err == .Unimplemented and
            std.mem.indexOf(u8, r.err.Unimplemented, "Vm::") != null;
        // The member exists by name but no overload serves this call
        // (arity/type). When the same-named local is an invocable
        // function value, it is the intended target — Kotlin resolves
        // `up.update()` to a `Up.() -> Unit` param over the 2-arg member
        // `update(value, block)`. Discard the member miss and invoke the
        // value (its receiver is the call receiver).
        if (member_missed and fb_invocable) {
            freeDispatchMissMsg(allocator, r.err.Unimplemented);
            orAudit("CallMemberOrValue", name_str, "value_after_miss", -1, &recv);
            if (fb == .Class) {
                const adapted = try allocator.alloc(Value, user_args.len + 1);
                defer allocator.free(adapted);
                adapted[0] = recv;
                @memcpy(adapted[1..], user_args);
                const nn = try allocator.alloc(?[]const u8, names.len + 1);
                defer allocator.free(nn);
                nn[0] = null;
                @memcpy(nn[1..], names);
                switch (try host.callValueNamed(allocator, &fb, adapted, nn)) {
                    .ok => |rv| try frame.write(cmv.dst, rv),
                    .err => |e| return raiseStep(frame, e),
                }
            } else switch (if (cmv.fallback_takes_receiver)
                try host.callValueWithThisExact(allocator, &fb, &recv, user_args, names)
            else if (cmv.fallback_receiver_shape_known)
                try host.callValueNamed(allocator, &fb, user_args, names)
            else
                try host.callValueWithThis(allocator, &fb, &recv, user_args, names)) {
                .ok => |rv| try frame.write(cmv.dst, rv),
                .err => |e| return raiseStep(frame, e),
            }
        } else switch (r) {
            .ok => |rv| try frame.write(cmv.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Whether a value can serve as the callee of a call: closures, function
/// references, intrinsics, classes (constructor call), bound references, and
/// instances whose class hierarchy declares `invoke`.
fn valueInvocable(module: *const Module, callee_v: Value) bool {
    return switch (callee_v) {
        .Intrinsic, .IrClosure, .BoundMethod => true,
        // A class value invoked bare is a constructor call.
        .Class, .PropertyRef => true,
        .Instance => |i| blk: {
            {
                const g = i.borrow();
                defer g.deinit();
                // A bound member/constructor reference synth
                // (`val lit = Expr::Lit`) is a callable value.
                if (g.get().get("__bound_name__") != null) break :blk true;
            }
            const g = i.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            const cls = cg.get().name;
            if (module.registry.hierarchy_methods.get(cls)) |mset| {
                break :blk mset.contains("invoke");
            }
            break :blk false;
        },
        else => false,
    };
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCallValueOrMember(comptime H: type, allocator: Allocator, frame: *Frame, cvm: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_value_or_member);
    var callee_v = frame.read(cvm.callee);
    // A boxed capture holds the callable in a cell; classify the
    // CONTENT (a captured local fn in a `var` slot is invokable).
    if (callee_v == .Cell) {
        const cg = callee_v.Cell.borrow();
        callee_v = cg.get().*;
        cg.deinit();
    }
    const arg_values = try readArgRun(allocator, frame, cvm.args, cvm.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cvm.arg_names);
    defer freeArgNames(allocator, names);
    const invocable = valueInvocable(frame.module, callee_v);
    // A callable whose DECLARED params definitely refute the runtime
    // args is not the target — Kotlin resolved the call to the
    // same-named enclosing member overload; fall to the member arm.
    const refuted = invocable and (comptime @hasDecl(H, "closureParamsDisproven")) and
        host.closureParamsDisproven(&callee_v, arg_values);
    if (invocable and !refuted) {
        if (orAuditOn()) {
            const name_str = constStr(frame.module, cvm.name) orelse "?";
            orAudit("CallValueOrMember", name_str, "value", -1, null);
        }
        // The member-fallback receiver is also the call site's
        // innermost implicit receiver; a receiver-typed closure
        // invoked bare binds it as dispatch context.
        const recv_ctx = frame.read(cvm.this_recv);
        // Flat dispatch: the plain closure shapes run as a pushed
        // activation; the host mirrors `callValueNamedRecvCtx`'s routing
        // and declines every special shape to the recursive path.
        if (comptime @hasDecl(H, "prepareValueRecvCtxFlatCall")) {
            if (flatEnabled() and callee_v == .IrClosure and argNamesAllNull(cvm.arg_names)) {
                if (try host.prepareValueRecvCtxFlatCall(allocator, &callee_v, &recv_ctx, arg_values)) |prep0| {
                    var prep = prep0;
                    prep.dst = cvm.dst;
                    frame.flat_call = prep;
                    return .flat_call;
                }
            }
        }
        const r = if (comptime @hasDecl(H, "callValueNamedRecvCtx"))
            try host.callValueNamedRecvCtx(allocator, &callee_v, &recv_ctx, arg_values, names)
        else
            try host.callValueNamed(allocator, &callee_v, arg_values, names);
        switch (r) {
            .ok => |rv| try frame.write(cvm.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else {
        const recv = frame.read(cvm.this_recv);
        const name_str = constStr(frame.module, cvm.name) orelse
            return raiseStep(frame, .{ .Type = "CallValueOrMember: name not a string const" });
        orAudit("CallValueOrMember", name_str, "member", 0, &recv);
        var r = try host.callMemberNamed(allocator, &recv, name_str, arg_values, names);
        // A NON-callable capture is not a resolution candidate at all in
        // Kotlin: `val pipeline = pipeline()` captured by a receiver lambda
        // must not stop `pipeline()` from binding the ENCLOSING class's
        // member. On the canonical member miss for the innermost receiver,
        // walk the outer implicit receivers before giving up.
        if (r == .err and r.err == .Unimplemented and
            std.mem.indexOf(u8, r.err.Unimplemented, "Vm::call_member") != null)
        {
            const entries = try enclosingEntriesAlloc(allocator);
            defer allocator.free(entries);
            var i = entries.len;
            while (i > 0) {
                i -= 1;
                const e = &entries[i];
                if (e.v != .Instance) continue;
                if (e.v == .Instance and recv == .Instance and
                    ObjRef(InstanceData).ptrEq(e.v.Instance, recv.Instance)) continue;
                const r2 = try host.callMemberNamed(allocator, &e.v, name_str, arg_values, names);
                if (r2 == .err and r2.err == .Unimplemented and
                    std.mem.indexOf(u8, r2.err.Unimplemented, "Vm::call_member") != null)
                {
                    freeMissErr(allocator, r2.err);
                    continue;
                }
                freeMissErr(allocator, r.err);
                r = r2;
                break;
            }
        }
        switch (r) {
            .ok => |rv| try frame.write(cvm.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmNewInstance(comptime H: type, allocator: Allocator, frame: *Frame, ni: anytype, host: *H) Allocator.Error!Step {
    const arg_values = try readArgRun(allocator, frame, ni.args, ni.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, ni.arg_names);
    defer freeArgNames(allocator, names);
    // A bare `Inner(args)` inside a member of the enclosing
    // class is `this@Outer.Inner(args)`: pass the frame's own
    // `this` — a method's `this` param or a lambda's `this`
    // capture — as the outer hint for the construction dispatch.
    // The host's outer selection is class-keyed, so a receiver
    // lambda whose `this` slot was overridden with an unrelated
    // subject falls through to the enclosing-receiver chain.
    var outer_hint: ?Value = callerThisValue(frame);
    const hint_ptr: ?*const Value = if (outer_hint) |*h| h else null;
    // Kotlin selects the constructor overload from the arguments' STATIC
    // types. Hand them to the host for this construction only; it consumes
    // them once, so a delegation or default thunk that constructs further
    // instances underneath ranks on its own terms.
    const static_heads = try resolveArgNames(allocator, frame.module, ni.arg_static_heads);
    defer freeArgNames(allocator, static_heads);
    if (comptime @hasDecl(H, "setCtorArgStaticHeads")) {
        host.setCtorArgStaticHeads(static_heads);
    }
    const result = switch (try host.newInstanceNamed(allocator, ni.class, arg_values, names, hint_ptr)) {
        .ok => |v| v,
        .err => |e| return raiseStep(frame, e),
    };
    if (result == .Instance) {
        const inst_ref = result.Instance;
        const needs_outer = blk: {
            const g = inst_ref.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().is_inner and g.get().outer == null;
        };
        if (needs_outer and outer_hint != null) {
            // The instance's `outer` is an owned field (its teardown
            // releases it); `outer_hint` is the caller's borrow, so
            // retain before storing. No-op under the arena.
            outer_hint.?.retain();
            const g = inst_ref.borrowMut();
            defer g.deinit();
            g.get().outer = outer_hint.?;
        }
    }
    try frame.write(ni.dst, result);
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmInstanceOf(comptime H: type, allocator: Allocator, frame: *Frame, io: anytype, host: *H) Allocator.Error!Step {
    _ = allocator;
    const v = frame.read(io.src);
    const is = host.instanceOf(&v, io.ty);
    try frame.write(io.dst, .{ .Bool = is });
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCtxScope(comptime H: type, allocator: Allocator, frame: *Frame, cs: anytype, host: *H) Allocator.Error!Step {
    if (comptime !@hasDecl(H, "ctxPush")) {
        try frame.write(cs.dst, .Null);
        return .cont;
    }
    const mark = host.ctxStackLen();
    var i: u32 = 0;
    while (i < cs.n_ctx) : (i += 1) {
        const v = frame.read(Reg.from(cs.ctx_args.int() + i));
        try host.ctxPush(v);
    }
    var block = frame.read(cs.block);
    const res = host.callValue(allocator, &block, &.{});
    host.ctxStackTruncate(mark);
    switch (try res) {
        .ok => |rv| try frame.write(cs.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCtxCall(comptime H: type, allocator: Allocator, frame: *Frame, cc: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.ctx_call);
    if (comptime !@hasDecl(H, "ctxPush")) {
        try frame.write(cc.dst, .Null);
        return .cont;
    }
    const mark = host.ctxStackLen();
    var i: u32 = 0;
    while (i < cc.n_ctx) : (i += 1) {
        const v = frame.read(Reg.from(cc.args.int() + i));
        try host.ctxPush(v);
    }
    const call_n = cc.n_args - cc.n_ctx;
    const call_args = try readArgRun(allocator, frame, Reg.from(cc.args.int() + cc.n_ctx), call_n);
    defer allocator.free(call_args);
    var callee_v = frame.read(cc.callee);
    const res = host.callValue(allocator, &callee_v, call_args);
    host.ctxStackTruncate(mark);
    switch (try res) {
        .ok => |rv| try frame.write(cc.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmCast(comptime H: type, allocator: Allocator, frame: *Frame, cast: anytype, host: *H) Allocator.Error!Step {
    const v = frame.read(cast.src);
    if (host.instanceOf(&v, cast.ty)) {
        v.retain();
        try frame.write(cast.dst, v);
    } else if (typeParamCastPasses(H, frame, cast.ty, host)) {
        v.retain();
        try frame.write(cast.dst, v);
    } else if (cast.safe) {
        try frame.write(cast.dst, .Null);
    } else {
        // A failed cast raises without passing through the
        // `Throw` terminator, so trace it here too or
        // KLIO_THROW_TRACE never sees ClassCastExceptions.
        if (envVarSet("KLIO_THROW_TRACE")) {
            std.debug.print("[throw-trace] from fn {s} (fqn={s}): ClassCastException cast to {s} (value tag {s})\n", .{ frame.func.name, frame.func.fqn, cast.ty.name, @tagName(v) });
        }
        const msg = try std.fmt.allocPrint(allocator, "cast to `{s}` failed", .{cast.ty.name});
        const exc = try Value.newException(allocator, .{
            .fqn = try runtime.strInit(allocator, "kotlin.ClassCastException"),
            .message = .from(try runtime.strInitOwned(allocator, msg)),
            .cause = null,
        });
        return raiseStep(frame, .{ .Throw = exc });
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmLambda(comptime H: type, allocator: Allocator, frame: *Frame, lam: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, lam.captures);
    defer allocator.free(cap_values);
    switch (try host.buildClosure(allocator, frame.module, lam.body_func, cap_values)) {
        .ok => |v| try frame.write(lam.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmAstLambda(comptime H: type, allocator: Allocator, frame: *Frame, al: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, al.captures);
    defer allocator.free(cap_values);
    switch (try host.buildAstLambdaWithFlagFuncid(allocator, frame.module, al.params, &al.body_ast, al.captured_names, cap_values, al.absorb_return, al.body_func)) {
        .ok => |v| try frame.write(al.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmRegisterClass(comptime H: type, allocator: Allocator, frame: *Frame, rc: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, rc.captures);
    defer allocator.free(cap_values);
    switch (try host.registerClassCaptured(allocator, rc.class.get(), rc.captured_names, cap_values)) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    // Bind the declaration name to the registered class value so a call
    // to the local class in scope constructs it (shadowing a same-named
    // top-level function). Only hosts that model a class table produce a
    // value; others leave the slot at its default.
    if (rc.dst) |d| {
        if (@hasDecl(H, "localClassValue")) {
            switch (try host.localClassValue(allocator, rc.class.get().name.name)) {
                .ok => |maybe| if (maybe) |v| try frame.write(d, v),
                .err => |e| return raiseStep(frame, e),
            }
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmBuildObject(comptime H: type, allocator: Allocator, frame: *Frame, bobj: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, bobj.captures);
    defer allocator.free(cap_values);
    switch (try host.buildObject(allocator, bobj.ast.get(), bobj.captured_names, cap_values, bobj.scope_renames, bobj.scope_classes)) {
        .ok => |v| try frame.write(bobj.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmStoreToThisOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, stg: anytype, host: *H) Allocator.Error!Step {
    const name_str = constStr(frame.module, stg.name) orelse
        return raiseStep(frame, .{ .Type = "StoreToThisOrGlobal: name not a string const" });
    const v = frame.read(stg.value);
    // Kotlin scoping for a bare-name write mirrors the read side:
    // the innermost implicit receiver owning a *property* of this
    // name takes the write; only when no receiver owns one does
    // the write land on the top-level binding (pinned by the
    // `bare_write_*` kotlinc parity fixtures). An assignment LHS
    // can only resolve to a property or variable — a member
    // *function* of the name never captures the write.
    var routed = false;
    // The statically supplied receiver is the innermost one, so it gets first
    // refusal. Same ownership test as the walk: a receiver that declares
    // neither a property nor an extension-property setter of this name does
    // not take the write, and the walk (then the global) still runs.
    if (stg.recv) |rr| {
        const rv = frame.read(rr);
        if (rv == .Instance and
            (host.hostHasProperty(&rv, name_str) or
                host.hostHasExtPropSetter(allocator, &rv, name_str)))
        {
            orAudit("StoreToThisOrGlobal", name_str, "recv-reg", 0, &rv);
            switch (try host.setField(allocator, &rv, name_str, v)) {
                .ok => {},
                .err => |e| return raiseStep(frame, e),
            }
            routed = true;
        }
    }
    if (!routed) {
        // `consult_param = true`: the implicit receiver owning the
        // written property may be the frame's `this` *parameter* (a
        // bare `receiveType = …` inside an interface/extension method),
        // not a capture — matching the read side. A bare write also
        // resolves to an extension-property *setter* (`var T.x set(…)`)
        // declared on the receiver's type or a supertype, not only a
        // stored member; `setField` dispatches both.
        var cands_l = try implicitCandidatesAlloc(H, allocator, frame, stg.this_idx, true, host, name_str, null);
        defer releaseCands(allocator, &cands_l);
        const cands = cands_l.items;
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        // Mirror the read side's capture shadow: a captured enclosing
        // local (scoped-global layer) takes the write over any non-OWN
        // receiver's property — `count++` inside a local class must
        // mutate the captured `count`, not a same-named property on a
        // dispatch-published chain receiver. `storeGlobal` then writes
        // through the capture's Cell.
        var w_capture_shadows = false;
        if (comptime @hasDecl(H, "scopedLocalBinds")) {
            w_capture_shadows = host.scopedLocalBinds(name_str);
        }
        for (cands) |c| {
            if (c.v != .Instance) continue;
            if (w_capture_shadows and !c.own) continue;
            if (!host.hostHasProperty(&c.v, name_str) and
                !host.hostHasExtPropSetter(allocator, &c.v, name_str)) continue;
            orAudit("StoreToThisOrGlobal", name_str, "member", c.depth, &c.v);
            switch (try host.setField(allocator, &c.v, name_str, v)) {
                .ok => {},
                .err => |e| return raiseStep(frame, e),
            }
            routed = true;
            break;
        }
    }
    if (!routed) {
        orAudit("StoreToThisOrGlobal", name_str, "global", -1, null);
        switch (try host.storeGlobal(allocator, name_str, v)) {
            .ok => {},
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmLoadFromThisOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, lt: anytype, host: *H) Allocator.Error!Step {
    const name_str = constStr(frame.module, lt.name) orelse
        return raiseStep(frame, .{ .Type = "LoadFromThisOrGlobal: name not a string const" });
    var resolved: ?Value = null;
    {
        // `consult_param = true`: in a method / extension body the
        // implicit receiver is the frame's `this` *parameter*, not
        // a capture slot.
        runtime.prof.opRoute(11);
        var cands_l = try implicitCandidatesAlloc(H, allocator, frame, lt.this_idx, true, host, stripScopeGetter(name_str), null);
        defer releaseCands(allocator, &cands_l);
        const cands = cands_l.items;
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        // Per-candidate probes are member-only (`getMemberField`):
        // a candidate must not "resolve" a global or an outer
        // receiver's member and shadow a receiver further out —
        // the walk's own order decides precedence, and the global
        // tiers below decide the fallback. A probe hit is a hit
        // even when the member's value IS `Unit` (`var u: Unit`):
        // the strict probe reports misses as errors, never as a
        // spurious `Unit`.
        //
        // The instruction's site memo short-circuits the walk when the
        // candidate shape matches a prior execution: a member's presence
        // on a candidate is a function of its class graph and stored
        // field set, both folded into the shape word, so under an equal
        // shape the recorded misses still miss and only the recorded
        // winner (if any) needs its probe re-run.
        runtime.prof.opRoute(12);
        // Kotlin lexical scoping: a captured enclosing local — materialized
        // for a runtime-lowered method body as a scoped-global layer — is a
        // NEARER binding than any implicit receiver's EXTENSION property.
        // Real members stay nearer than the capture (the class-body scope
        // encloses it), so the receiver walk is skipped only when every
        // candidate is an Instance and none of their classes declares the
        // name. Without this, AwaiterQueue's `private inline val Int.count`
        // hijacked a captured `count` through any receiver chain holding an
        // Int, and the read never reached the capture's cell.
        var capture_shadows = false;
        if (comptime @hasDecl(H, "scopedLocalBinds") and @hasDecl(H, "hostHasMember")) {
            const bare0 = stripScopeGetter(name_str);
            if (host.scopedLocalBinds(bare0)) {
                capture_shadows = true;
                for (cands) |c| {
                    // Only the OWN receiver run's members outrank the
                    // capture: the class body encloses the captured
                    // local's scope, but a dispatch-published chain
                    // receiver's members do not — the local was declared
                    // lexically inside/after those receivers' scopes
                    // (`var count = 0; class C { init { count++ } }`
                    // binds the local even when a chain instance owns a
                    // `count` member).
                    if (c.v != .Instance or (c.own and host.hostHasMember(&c.v, bare0))) {
                        capture_shadows = false;
                        break;
                    }
                }
            }
        }
        const shape = implicitSiteShape(cands);
        var full_walk = !capture_shadows;
        // The site memo may hold an extension-property winner recorded in a
        // context without the capture layer; skip it when shadowed.
        if (shape) |sh| {
            const cached = @atomicLoad(u64, @constCast(&lt.site_cache), .monotonic);
            if (cached != 0 and !capture_shadows and (cached ^ sh) & SITE_SHAPE_MASK == 0) {
                const verdict = cached & 3;
                if (verdict == SITE_MISS) {
                    full_walk = false;
                } else if (verdict == SITE_WIN) {
                    const w: usize = @intCast((cached >> 2) & 0xFF);
                    if (w < cands.len) {
                        switch (try host.getMemberField(allocator, &cands[w].v, name_str)) {
                            .ok => |v| {
                                orAudit("LoadFromThisOrGlobal", name_str, "member", cands[w].depth, &cands[w].v);
                                resolved = v;
                                full_walk = false;
                            },
                            .err => |e| {
                                if (e == .Unimplemented) {
                                    freeMissErr(allocator, e);
                                } else {
                                    return raiseStep(frame, e);
                                }
                            },
                        }
                    }
                }
            }
        }
        if (full_walk and resolved == null) {
            var winner: ?usize = null;
            // Two passes, Kotlin's lexical rule: an outer receiver's MEMBER
            // outranks an inner receiver's IMPORTED extension property
            // (imports are the outermost scope), so pass 1 probes members
            // only; extensions serve in pass 2 only when no member answered
            // anywhere on the chain (`job` inside a CoroutineScope lambda of
            // a class declaring `val job` reads the field, not
            // kotlinx.coroutines' CoroutineScope.job).
            var pass: u8 = 0;
            walk: while (pass < 2) : (pass += 1) {
            for (cands, 0..) |c, ci| {
                if (missTraceWant()) |w| if (std.mem.eql(u8, w, name_str)) {
                    std.debug.print("[ltg-cand] name={s} pass={d} ci={d} depth={d} tag={s} in_fn={s}\n", .{ name_str, pass, ci, c.depth, @tagName(std.meta.activeTag(c.v)), frame.func.name });
                };
                switch (try (if (pass == 0)
                    host.getMemberFieldNoExt(allocator, &c.v, name_str)
                else
                    host.getMemberField(allocator, &c.v, name_str)))
                {
                    .ok => |v| {
                        orAudit("LoadFromThisOrGlobal", name_str, "member", c.depth, &c.v);
                        resolved = v;
                        winner = ci;
                        break :walk;
                    },
                    // Only the dispatch-miss sentinel (`Unimplemented`)
                    // means "this candidate has no such member" — discard
                    // its `Vm::get_field` message and walk to the next
                    // candidate / global tier. Any other error is a member
                    // that resolved and whose accessor actually ran: a
                    // throw from a delegated property's `getValue`
                    // (`NoSuchElementException` on a missing map key), a
                    // `CalleeFailed`, a `StackOverflow`. Those propagate —
                    // swallowing them would mask the throw and fall through
                    // to a spurious `unresolved global`.
                    .err => |e| {
                        if (e == .Unimplemented) {
                            freeMissErr(allocator, e);
                        } else {
                            return raiseStep(frame, e);
                        }
                    },
                }
            }
            }
            if (shape) |sh| {
                const entry: u64 = if (winner) |w|
                    (if (w <= 0xFF) (sh & SITE_SHAPE_MASK) | (@as(u64, @intCast(w)) << 2) | SITE_WIN else 0)
                else
                    (sh & SITE_SHAPE_MASK) | SITE_MISS;
                if (entry != 0) @atomicStore(u64, @constCast(&lt.site_cache), entry, .monotonic);
            }
        }
    }
    // The scope-qualified form carries the lexical owner only for
    // the getter reads above; the global fallback uses the bare
    // name.
    runtime.prof.opRoute(13);
    const bare_name = stripScopeGetter(name_str);
    // A lowering-resolved identity binds that exact declaration;
    // the name string remains the unresolved-shape fallback. A
    // runtime-scoped shadowing capture (a closed-over callable
    // materialized as a scoped-global layer) outranks the static
    // pick, mirroring the call form's shadow gate.
    const by_id: ?Value = if (resolved == null and (lt.func != null or lt.class != null) and
        !host.isShadowingCapture(bare_name))
        host.lookupGlobalById(allocator, lt.func, lt.class, false)
    else
        null;
    var v: Value = undefined;
    if (resolved) |rv| {
        v = rv;
    } else if (by_id) |gv| {
        orAudit("LoadFromThisOrGlobal", bare_name, "global_id", -1, null);
        v = gv;
    } else {
        switch (try host.lookupGlobalThrowing(allocator, bare_name)) {
            .ok => |maybe| {
                if (maybe) |gv| {
                    orAudit("LoadFromThisOrGlobal", bare_name, "global", -1, null);
                    v = gv;
                } else {
                    // A top-level `val` declared with only a custom getter
                    // has no global binding; re-run its 0-arg getter, as
                    // the plain LoadGlobal tail does — a receiver-context
                    // read of `currentRecomposeScope` must resolve exactly
                    // like a top-level one.
                    if (comptime @hasDecl(H, "callFunc")) {
                        if (frame.module.registry.top_level_prop_getters.get(bare_name)) |getter_fid| {
                            switch (try host.callFunc(allocator, frame.module, getter_fid, &.{})) {
                                .ok => |gv2| {
                                    orAudit("LoadFromThisOrGlobal", bare_name, "toplevel_getter", -1, null);
                                    try frame.write(lt.dst, gv2);
                                    return .cont;
                                },
                                .err => |e| return raiseStep(frame, e),
                            }
                        }
                    }
                    // The scope-qualified read's lexical-owner premise can be
                    // wrong for a lambda in a companion/static context (its
                    // `$sgetter` owner names the OUTER class, which no live
                    // subject owns — ktor's engine intercept lambda reading
                    // `call`, a member of its own pipeline receiver). With
                    // the lexical claim exhausted and the global tier empty,
                    // an implicit receiver's own member is the only
                    // Kotlin-legal binding left: retry the candidates with
                    // the PLAIN property name before failing.
                    if (!std.mem.eql(u8, bare_name, constStr(frame.module, lt.name) orelse bare_name)) {
                        var cands2_l = try implicitCandidatesAlloc(H, allocator, frame, lt.this_idx, true, host, bare_name, null);
                        defer releaseCands(allocator, &cands2_l);
                        const cands2 = cands2_l.items;
                        const ka2 = pinImplicitCandidates(cands2);
                        defer runtime.keepaliveRestore(ka2);
                        for (cands2) |c2| {
                            switch (try host.getMemberField(allocator, &c2.v, bare_name)) {
                                .ok => |v2| {
                                    orAudit("LoadFromThisOrGlobal", bare_name, "plain_retry", c2.depth, &c2.v);
                                    try frame.write(lt.dst, v2);
                                    return .cont;
                                },
                                .err => |e2| {
                                    if (e2 == .Unimplemented) {
                                        freeMissErr(allocator, e2);
                                    } else {
                                        return raiseStep(frame, e2);
                                    }
                                },
                            }
                        }
                    }
                    // A scope-qualified read whose owner's property is a
                    // MEMBER-EXTENSION property (`private val
                    // Density.targetConstraints` inside SizeNode, read bare
                    // in `MeasureScope.measure`) binds TWO receivers: the
                    // owning candidate dispatches, and the innermost
                    // candidate satisfying the getter's declared receiver
                    // is `this`. Same bind as the bare member-extension
                    // call arm, at arity zero.
                    if (comptime @hasDecl(H, "memberExtOverridesFor") and @hasDecl(H, "receiverImplementsType")) {
                        var cands3_l = try implicitCandidatesAlloc(H, allocator, frame, lt.this_idx, true, host, bare_name, null);
                        defer releaseCands(allocator, &cands3_l);
                        const cands3 = cands3_l.items;
                        const ka3 = pinImplicitCandidates(cands3);
                        defer runtime.keepaliveRestore(ka3);
                        for (cands3) |c3| {
                            if (c3.v != .Instance) continue;
                            var fids3: [4]ir.FuncId = @splat(@enumFromInt(0));
                            const nf3 = host.memberExtOverridesFor(&c3.v, bare_name, 1, &fids3);
                            for (fids3[0..nf3]) |gfid| {
                                const gf = frame.module.funcById(gfid) orelse continue;
                                var er3: ?Value = null;
                                for (cands3) |c4| {
                                    if (c4.v != .Instance) continue;
                                    if (host.receiverImplementsType(&c4.v, gf.params[0].ty.name)) {
                                        er3 = c4.v;
                                        break;
                                    }
                                }
                                const ev3 = er3 orelse continue;
                                pushEnclosing(&c3.v);
                                defer popEnclosing();
                                orAudit("LoadFromThisOrGlobal", bare_name, "member_ext_prop", c3.depth, &ev3);
                                switch (try host.callFuncNamed(allocator, frame.module, gfid, &.{ev3}, &.{})) {
                                    .ok => |v3| {
                                        try frame.write(lt.dst, v3);
                                        return .cont;
                                    },
                                    .err => |e3| return raiseStep(frame, e3),
                                }
                            }
                        }
                    }
                    const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{bare_name});
                    if (missTraceWant()) |w| {
                        if (std.mem.eql(u8, w, bare_name)) {
                            std.debug.print("[ltg-tail] name={s} raw={s} func={?} class={?} shadow={} span={d}:{d} in_fn={s}#{d}\n", .{
                                bare_name,
                                name_str,
                                if (lt.func) |f| f.int() else null,
                                if (lt.class) |c| c.int() else null,
                                host.isShadowingCapture(bare_name),
                                if (frame.cur_span) |sp| sp.file.int() else 0,
                                if (frame.cur_span) |sp| sp.start else 0,
                                frame.func.name,
                                frame.func.id.int(),
                            });
                        }
                    }
                    dumpFrameChainForDiag();
                    return raiseStep(frame, .{ .Unbound = msg });
                }
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // A boxed capture surfaced by the member walk (an anon-object
    // method's captured outer `var` lands in the instance's capture
    // env as a shared Cell) reads through the cell.
    if (v == .Cell) {
        const cg = v.Cell.borrow();
        v = cg.get().*;
        cg.deinit();
    }
    v.retain();
    try frame.write(lt.dst, v);
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmIndex(comptime H: type, allocator: Allocator, frame: *Frame, ix: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(ix.receiver);
    const i = frame.read(ix.index);
    if (fastIndexGet(&recv, &i)) |rv| {
        try frame.write(ix.dst, rv);
        return .cont;
    }
    switch (try host.callMember(allocator, &recv, "get", &.{i})) {
        .ok => |rv| try frame.write(ix.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmIndexSet(comptime H: type, allocator: Allocator, frame: *Frame, ixs: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(ixs.receiver);
    const i = frame.read(ixs.index);
    const v = frame.read(ixs.value);
    if (fastIndexSet(allocator, &recv, &i, v)) |expr_val| {
        // The assignment form discards the expression value; a List's
        // returned PREVIOUS element carries ownership and must release.
        if (runtime.reclaimEnabled()) expr_val.release(allocator);
        return .cont;
    }
    switch (try host.callMember(allocator, &recv, "set", &.{ i, v })) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmNewList(comptime H: type, allocator: Allocator, frame: *Frame, nl: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const items = try readArgRun(allocator, frame, nl.args, nl.n_args);
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(allocator, items);
    allocator.free(items);
    // The list owns one reference to each element (its teardown
    // releases them); `readArgRun` handed back borrows of the source
    // registers, so retain each. No-op under the arena fast path.
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    try frame.write(nl.dst, try Value.newList(allocator, .{
        .items = try ValueList.init(allocator, list),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmQualifiedThis(comptime H: type, allocator: Allocator, frame: *Frame, qt: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(qt.receiver);
    const qual_str = constStr(frame.module, qt.qualifier) orelse
        return raiseStep(frame, .{ .Type = "QualifiedThis: qualifier not a string const" });
    switch (try host.qualifiedThis(allocator, &recv, qual_str)) {
        .ok => |v| {
            v.retain();
            try frame.write(qt.dst, v);
        },
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmPropertyRef(comptime H: type, allocator: Allocator, frame: *Frame, pr: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const name_str = constStr(frame.module, pr.name) orelse
        return raiseStep(frame, .{ .Type = "PropertyRef: name not a string const" });
    try frame.write(pr.dst, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name_str) } });
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
pub noinline fn execArmMemberRef(comptime H: type, allocator: Allocator, frame: *Frame, mr: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(mr.receiver);
    const name_str = constStr(frame.module, mr.name) orelse
        return raiseStep(frame, .{ .Type = "MemberRef: name not a string const" });
    const result = if (mr.func) |func|
        if (comptime @hasDecl(H, "memberRefExact"))
            try host.memberRefExact(allocator, &recv, name_str, func)
        else
            try host.memberRef(allocator, &recv, name_str)
    else
        try host.memberRef(allocator, &recv, name_str);
    switch (result) {
        .ok => |v| try frame.write(mr.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// `name(args)` where lowering could not classify the bare callee as
/// member-vs-global. Mirrors Kotlin's call resolution for an implicit
/// receiver: each candidate receiver is searched innermost-first, members
/// and applicable extensions per receiver (pinned by the
/// `inner_ext_over_outer_member` kotlinc parity fixture), then the
/// top-level tiers — runtime overload selection, the lowering-resolved
/// constructor class, the global by name — and only then an error.
/// Free a discarded member-dispatch-miss message (the host allocates a
/// `Vm::call_member …` string on a total miss; the resolver discards it while
/// walking to the next candidate / a global). Recognizable by its prefix, so a
/// static `.Unimplemented` literal is never freed. No-op unless a freeing
/// backend is active.
pub fn freeDispatchMissMsg(allocator: Allocator, msg: []const u8) void {
    if (!runtime.freeScratch()) return;
    // Every host dispatch-miss message is `allocPrint`-built with a `Vm::`
    // prefix (`Vm::call_member`, `Vm::get_field`, …); static `.Unimplemented`
    // literals never carry that prefix, so this frees only owned messages.
    if (std.mem.startsWith(u8, msg, "Vm::")) allocator.free(msg);
}

/// Free a discarded host dispatch-miss `EvalError` (the resolver tries many
/// receiver candidates / fallback tiers and drops each miss). Only the
/// `Unimplemented` arm carries an owned message.
fn freeMissErr(allocator: Allocator, e: EvalError) void {
    if (e == .Unimplemented) freeDispatchMissMsg(allocator, e.Unimplemented);
}

pub fn execCallMemberOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, cmg: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_member_or_global);
    const name_str = constStr(frame.module, cmg.name) orelse
        return raiseStep(frame, .{ .Type = "CallMemberOrGlobal: name not a string const" });
    const prev_tl = if (comptime @hasDecl(H, "setTrailingMemberCall"))
        H.setTrailingMemberCall(cmg.trailing_lambda)
    else
        false;
    defer if (comptime @hasDecl(H, "setTrailingMemberCall")) {
        _ = H.setTrailingMemberCall(prev_tl);
    };
    const arg_values = try readArgRun(allocator, frame, cmg.args, cmg.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cmg.arg_names);
    defer freeArgNames(allocator, names);
    // A direct splice receiver (a bound `this` register) is the innermost
    // implicit receiver when present; otherwise the lambda capture slot, or —
    // when that is empty — the enclosing function's `this` *parameter*.
    const direct_this: ?Value = if (cmg.recv) |r| frame.read(r) else null;
    const this_val = if (direct_this) |dt| dt else implicitThisValue(frame, cmg.this_idx, true);
    // A lowering-committed INLINE INSTANCE METHOD with inferred reified
    // type arguments: bind the stamped type-argument names as globals
    // for the call's duration (the same channel the inline splice and
    // `callFuncTyped` use), then let the NORMAL member walk dispatch —
    // its enclosing-receiver pushes are what nested semantics blocks
    // resolve against. `c.visitNodes(Kinds.OnRe) { … }` runs with
    // `T = Lw` live so the framed body's `is T` checks the real class.
    var mit_saved: std.ArrayList(struct { name: []const u8, prev: ?Value }) = .empty;
    defer mit_saved.deinit(allocator);
    defer {
        var ri: usize = mit_saved.items.len;
        while (ri > 0) {
            ri -= 1;
            const sv = mit_saved.items[ri];
            if (comptime @hasDecl(H, "restoreGlobalBinding")) {
                host.restoreGlobalBinding(sv.name, sv.prev);
            }
        }
    }
    if (cmg.func != null and cmg.type_args.len != 0 and comptime @hasDecl(H, "bindTypeParamGlobal")) {
        if (frame.module.funcById(cmg.func.?)) |tf| {
            if (tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this")) {
                const tp_list = frame.module.registry.func_type_params.get(cmg.func.?);
                const tp_names: []const []const u8 = if (tp_list) |l| l.items else &.{};
                orAudit("CallMemberOrGlobal", name_str, "member_inline_typed", -1, null);
                for (tp_names, 0..) |tpn, ti| {
                    if (ti >= cmg.type_args.len) break;
                    const arg_name = constStr(frame.module, cmg.type_args[ti]) orelse continue;
                    if (arg_name.len == 0) continue;
                    const prev = host.bindTypeParamGlobal(tpn, arg_name);
                    try mit_saved.append(allocator, .{ .name = tpn, .prev = prev });
                    if (comptime @hasDecl(H, "bindTypeParamSpelling")) {
                        if (host.bindTypeParamSpelling(allocator, tpn, arg_name)) |sp| {
                            try mit_saved.append(allocator, .{ .name = sp.key, .prev = sp.prev });
                        }
                    }
                }
            }
        }
    }
    // A bare callee whose name starts uppercase is usually a constructor /
    // type — but only when such a type exists. Kotlin has no capitalization
    // rule: DSL-style functions are capitalized (ktor's
    // `HttpResponseValidator { … }` is an extension on HttpClientConfig), so
    // the member/extension passes are skipped only when the name really
    // names a class.
    var is_ctor_name = name_str.len > 0 and std.ascii.isUpper(name_str[0]) and
        cmg.class != null;
    // An INAPPLICABLE constructor is not a candidate at all: Kotlin filters
    // by applicability before scope rank, so `Point(it)` against `data class
    // Point(x: Int, y: Int)` never means construction — the member/extension
    // walk must run and bind the receiver's `MockViewValidator.Point`
    // extension. The class-carrying ctor tail stays the fallback for calls
    // nothing else serves, so a bindable secondary constructor is still
    // reachable when the walk misses.
    if (is_ctor_name) applicable: {
        const cid = cmg.class.?;
        if (cid.int() >= frame.module.classes.items.len) break :applicable;
        const cls = &frame.module.classes.items[cid.int()];
        var required: usize = 0;
        var has_vararg = false;
        for (cls.primary_params) |*p| {
            if (p.is_vararg) {
                has_vararg = true;
                continue;
            }
            if (!p.has_default) required += 1;
        }
        const n = arg_values.len;
        if (n >= required and (has_vararg or n <= cls.primary_params.len)) break :applicable;
        if (comptime @hasDecl(H, "classSecondaryCtorCanBind")) {
            if (host.classSecondaryCtorCanBind(cls.fqn, cls.name, n)) break :applicable;
        }
        is_ctor_name = false;
    }
    // A capitalized name that is ALSO a method of the implicit receiver is a
    // nearer-scope member call, not a constructor (`Test(...)` inside a class
    // declaring `fun Test(...)` next to an imported `kotlin.test.Test`): run
    // the member passes; the constructor stays the fallback when no member
    // binds.
    if (is_ctor_name and this_val != .Null and this_val != .Unit) refine: {
        // The nearest receiver carrying the member may sit deeper in the
        // implicit chain than the innermost `this` (a suspend block's
        // innermost receiver is the coroutine, not the declaring class).
        var rcands_l = try implicitCandidatesAlloc(H, allocator, frame, cmg.this_idx, true, host, name_str, direct_this);
        defer releaseCands(allocator, &rcands_l);
        const rcands = rcands_l.items;
        const rcands_keepalive = pinImplicitCandidates(rcands);
        defer runtime.keepaliveRestore(rcands_keepalive);
        for (rcands) |c| {
            if (c.v != .Null and c.v != .Unit and host.hostHasMember(&c.v, name_str)) {
                is_ctor_name = false;
                break :refine;
            }
        }
    }
    if (cmgTraceWant()) |w| {
        if (std.mem.eql(u8, w, name_str)) {
            const dtc: []const u8 = if (direct_this != null and comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&direct_this.?) else "-";
            std.debug.print("[cmg] {s} this_tag={s} ctor_name={} in_fn={s}#{d} this_idx={d} ncaps={d} recv_reg={?d} direct_cls={s}\n", .{ name_str, @tagName(std.meta.activeTag(this_val)), is_ctor_name, frame.func.name, frame.func.id.int(), cmg.this_idx, frame.captures.items.len, if (cmg.recv) |r| r.int() else null, dtc });
            for (frame.captures.items, 0..) |cv, cvi| {
                const cn: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&cv) else "-";
                const nm: []const u8 = if (cvi < frame.func.capture_order.len) frame.func.capture_order[cvi] else "?";
                std.debug.print("[cmg-cap] [{d}] {s} = {s} {s}\n", .{ cvi, nm, @tagName(std.meta.activeTag(cv)), cn });
            }
        }
    }
    if (routeTraceOn(name_str)) std.debug.print("[cmgsec] enter frame={s}\n", .{frame.func.fqn});
    var committed_ext_h: ?FuncId = null;
    var committed_recv_h: ?Value = null;
    var resolved: ?Value = null;
    var first_real_err: ?EvalError = null;
    // A bare `name` bound to a captured callable in the innermost
    // scoped-global layer is a closed-over parameter/local that shadows
    // a same-named member, but a genuine member of the implicit receiver
    // still wins over an over-captured scoped global.
    const shadow_capture = host.isShadowingCapture(name_str) and
        ((this_val == .Null or this_val == .Unit) or !host.hostHasMember(&this_val, name_str));

    // A prior call from this site with this receiver class resolved to a
    // global (single candidate, no member/extension): skip the member passes.
    const func_p = @intFromPtr(frame.func);
    const cmg_skip = comptime @hasDecl(H, "cmgGlobalSkip");
    // The site's own memo answers first: a u64 compare against the receiver's
    // class identity, with no receiver borrow and no hash of the key. The
    // host's map stays the general answer (it survives across sites).
    const site_key: ?struct { cls: u64, sig: u64 } = blk: {
        if (!cmg_skip or is_ctor_name or shadow_capture) break :blk null;
        if (this_val != .Instance) break :blk null;
        if (comptime !@hasDecl(H, "memberSiteSig")) break :blk null;
        const sig = host.memberSiteSig(arg_values) orelse break :blk null;
        const cls: u64 = c: {
            const g = this_val.Instance.borrow();
            defer g.deinit();
            break :c @intCast(g.get().class.identity());
        };
        if (cls == 0) break :blk null;
        break :blk .{ .cls = cls, .sig = sig };
    };
    const site_skip = if (site_key) |k|
        @atomicLoad(u64, @constCast(&cmg.skip_cls), .acquire) == k.cls and
            @atomicLoad(u64, @constCast(&cmg.skip_sig), .monotonic) == k.sig
    else
        false;
    const skip_member = site_skip or (cmg_skip and !is_ctor_name and !shadow_capture and
        host.cmgGlobalSkip(func_p, &this_val, name_str, arg_values)) or
        // Call-site evidence PINNED the overload (`func_final`): a genuine
        // member of the receiver still shadows, but the member leg's
        // extension-fallback re-rank must not run the first-declared
        // variant past the pin.
        (cmg.func_final and !is_ctor_name and
            ((this_val == .Null or this_val == .Unit) or !host.hostHasMember(&this_val, name_str)));
    // A pinned EXTENSION dispatches directly with the receiver prepended:
    // the global leg cannot prepend a receiver, and the member leg's
    // fallback would re-rank past the pin (the genuine-member shadow was
    // judged just above).
    if (cmg.func_final and skip_member and !is_ctor_name and
        this_val != .Null and this_val != .Unit)
    direct: {
        const pf = cmg.func orelse break :direct;
        const pfd = frame.module.funcById(pf) orelse break :direct;
        if (pfd.params.len == 0 or !std.mem.eql(u8, pfd.params[0].name, "this")) break :direct;
        const all_args = try allocator.alloc(Value, arg_values.len + 1);
        defer allocator.free(all_args);
        all_args[0] = this_val;
        for (arg_values, 0..) |v, i| all_args[i + 1] = v;
        const padded_names = try allocator.alloc(?[]const u8, names.len + 1);
        defer allocator.free(padded_names);
        padded_names[0] = null;
        for (names, 0..) |n2, i| padded_names[i + 1] = n2;
        orAudit("CallMemberOrGlobal", name_str, "pinned_ext_direct", -1, null);
        switch (try host.callFuncNamed(allocator, frame.module, pf, all_args, padded_names)) {
            .ok => |result| {
                try frame.write(cmg.dst, result);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // Full replay: this site already resolved, for this receiver class and
    // argument shape, to a plain global whose dispatch was a fused
    // activation. Rebuild that activation and skip both the member walk and
    // the overload ranking.
    if (site_skip and cmg.type_args.len == 0 and argNamesAllNull(cmg.arg_names)) {
        const claimed = @atomicLoad(u32, @constCast(&cmg.global_fid), .acquire);
        if (claimed != 0 and flatEnabled()) {
            const fid = FuncId.from(claimed - 1);
            if (frame.module.funcById(fid)) |gf| {
                if (gf.params.len == arg_values.len) {
                    // The claimed global may be a host-routed serve target
                    // (the snapshot walk family): the write path's bare
                    // `readable(...)` inside sync blocks reaches it through
                    // this replay, never through the static-call arm.
                    if (hostRouteServe(H, allocator, gf, arg_values, host)) |served| {
                        try frame.write(cmg.dst, served);
                        return .cont;
                    }
                    // Scalar-replay leaf on the claimed global: a bail
                    // falls through to the flat activation, which re-runs
                    // the pure body exactly.
                    if (try eval.tryLeafValues(H, allocator, frame.module, gf, arg_values, host, null)) |lo| switch (lo) {
                        .val => |v| {
                            try frame.write(cmg.dst, v);
                            return .cont;
                        },
                        .raise => |e| return raiseStep(frame, e),
                    };
                    var args_list = try acquireArgsCap(allocator, arg_values.len);
                    args_list.appendSliceAssumeCapacity(arg_values);
                    frame.flat_call = .{
                        .func = gf,
                        .args = args_list,
                        .dst = cmg.dst,
                    };
                    orAudit("CallMemberOrGlobal", name_str, "site_global_replay", -1, null);
                    return .flat_call;
                }
            }
        }
    }
    var single_cand = false;

    if (routeTraceOn(name_str)) std.debug.print("[cmgsec] member-gate ctor={} shadow={} skip={}\n", .{ is_ctor_name, shadow_capture, skip_member });
    if (!is_ctor_name and !shadow_capture and !skip_member) {
        var cands_l = try implicitCandidatesAlloc(H, allocator, frame, cmg.this_idx, true, host, name_str, direct_this);
        defer releaseCands(allocator, &cands_l);
        const cands = cands_l.items;
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        single_cand = cands.len == 1;
        // A bare MEMBER-EXTENSION call takes its two receivers from the
        // implicit tower independently: the extension receiver is the
        // innermost candidate satisfying the target's DECLARED receiver
        // type, the dispatch receiver the innermost candidate whose class
        // owns a member extension of this name. `with(node) { measure(m, c) }`
        // otherwise landed the owner in `params[0]` — the coordinator that
        // IS the `MeasureScope` never reached the callee — and a nested
        // `with(other) { f() }` inside `f` re-entered the ENCLOSING
        // declaration instead of `other`'s override, recursing forever.
        if (comptime @hasDecl(H, "receiverImplementsType")) mext: {
            if (!mextArmEnabled()) break :mext;
            if (!argNamesAllNull(cmg.arg_names)) break :mext;
            // A committed target names the declared receiver outright; an
            // interface call arrives uncommitted and each candidate's own
            // declaration supplies it.
            var committed_rt: ?[]const u8 = null;
            if (cmg.func) |cfid| {
                if (frame.module.funcById(cfid)) |cf| {
                    if (cf.kind != .member_extension) break :mext;
                    if (cf.params.len != arg_values.len + 1) break :mext;
                    if (cf.params.len == 0 or !std.mem.eql(u8, cf.params[0].name, "this")) break :mext;
                    committed_rt = cf.params[0].ty.name;
                }
            }
            // Cheap early-out before any candidate scanning: when the
            // innermost receiver already satisfies the committed target's
            // declared receiver, the ordinary walk binds it correctly.
            if (committed_rt) |crt| {
                if (cands.len != 0 and cands[0].v == .Instance and
                    host.receiverImplementsType(&cands[0].v, crt)) break :mext;
            }
            var owner: ?Value = null;
            var target: ?ir.FuncId = null;
            var ext_recv: ?Value = null;
            for (cands) |c| {
                if (c.v != .Instance) continue;
                // The receiver's own class index answers "does this class
                // declare or inherit a member extension of this name", so a
                // dispatch costs a supertype walk instead of a scan over
                // every same-named declaration in the program.
                if (comptime !@hasDecl(H, "memberExtOverridesFor")) break :mext;
                var fids: [4]ir.FuncId = @splat(@enumFromInt(0));
                const nf = host.memberExtOverridesFor(&c.v, name_str, arg_values.len + 1, &fids);
                if (nf == 0) continue;
                for (fids[0..nf]) |fid| {
                    const f = frame.module.funcById(fid) orelse continue;
                    const frt = committed_rt orelse f.params[0].ty.name;
                    var er_here: ?Value = null;
                    for (cands) |c2| {
                        if (c2.v != .Instance) continue;
                        if (host.receiverImplementsType(&c2.v, frt)) {
                            er_here = c2.v;
                            break;
                        }
                    }
                    const ev = er_here orelse continue;
                    owner = c.v;
                    target = fid;
                    ext_recv = ev;
                    break;
                }
                if (target != null) break;
            }
            const t = target orelse break :mext;
            const er = ext_recv orelse break :mext;
            const tf = frame.module.funcById(t) orelse break :mext;
            // Only a genuine mismatch is corrected: when the innermost
            // candidate already satisfies the declared receiver the ordinary
            // walk binds it correctly.
            if (cands.len != 0 and cands[0].v == .Instance and
                host.receiverImplementsType(&cands[0].v, tf.params[0].ty.name)) break :mext;
            const all = try allocator.alloc(Value, arg_values.len + 1);
            defer allocator.free(all);
            all[0] = er;
            for (arg_values, 0..) |v, i| all[i + 1] = v;
            if (owner) |o| pushEnclosing(&o);
            defer if (owner != null) popEnclosing();
            orAudit("CallMemberOrGlobal", name_str, "member_ext_recv", -1, &er);
            switch (try host.callFuncNamed(allocator, frame.module, t, all, &.{})) {
                .ok => |v| {
                    try frame.write(cmg.dst, v);
                    return .cont;
                },
                .err => |e| return raiseStep(frame, e),
            }
        }
        // Inside an extension body, the implicit `this` has the
        // extension's DECLARED receiver type, and Kotlin resolves a bare
        // extension call against that static type — not the runtime
        // value's type, which may be a subtype carrying its own
        // same-name extension. Hand the declared head to the strict
        // probe for exactly that candidate.
        var static_from_instr = false;
        const static_recv_ty: ?[]const u8 = blk: {
            // The lowering-recorded declared receiver wins: the executing
            // frame may be a synthesized closure (a suspend body) whose own
            // kind says nothing about the extension receiver.
            if (cmg.static_recv) |sc| {
                if (constStr(frame.module, sc)) |sname| {
                    static_from_instr = true;
                    break :blk sname;
                }
            }
            // Extension bodies resolve a bare call against the extension's
            // DECLARED receiver type.
            switch (frame.func.kind) {
                .top_level_extension, .member_extension => {
                    const idx = frameThisParam(frame) orelse break :blk null;
                    break :blk frame.func.params[idx].ty.name;
                },
                .instance_method => {
                    // A plain instance method resolves a bare (implicit-`this`)
                    // call against its DECLARING class's static member scope,
                    // the same way: a runtime subtype's own same-name overload
                    // that the declaring type cannot see must not shadow the
                    // statically-bound member. `AbstractMap.containsEntry`'s
                    // `get(key)` binds `Map.get(K): V?`, never a
                    // `PersistentCompositionLocalHashMap.get<T>(
                    // CompositionLocal<T>)` the subtype introduces (a read-value
                    // overload that breaks the structural map `equals`). The
                    // this-param's nominal type is a placeholder for stdlib
                    // methods, so the declaring class is found by identity
                    // (memoized per function by the host).
                    break :blk host.declaringClassSimpleName(frame.module, frame.func.id);
                },
                else => break :blk null,
            }
        };
        // A lowering-committed EXTENSION target: Kotlin selects extensions
        // statically, so the runtime walk may only let true MEMBERS shadow
        // it — the by-name extension fallback and the overload re-pick must
        // not re-select a sibling the static evidence excluded (ktor's
        // deprecated P.install delegates to its cast-picked sibling; a
        // by-runtime-type re-pick binds the deprecated overload again and
        // recurses without bound).
        const committed_ext: ?FuncId = blk: {
            const fid = cmg.func orelse break :blk null;
            // Engage the static commitment only for the self-name shape: a
            // bare call to the very name of the function it sits in, where
            // the by-name extension re-pick can re-enter the caller instead
            // of the sibling the lowering (cast evidence, receiver match)
            // committed — ktor's deprecated P.install delegating to its
            // Pipeline sibling recursed without bound. Every other deferred
            // call keeps the runtime walk's full re-selection.
            if (!std.mem.eql(u8, frame.func.name, name_str)) break :blk null;
            if (fid.int() == frame.func.id.int()) break :blk null;
            const cf = frame.module.funcById(fid) orelse break :blk null;
            if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) break :blk fid;
            break :blk null;
        };
        // The committed target binds the FIRST candidate receiver (walk
        // order, innermost first) its declared receiver does not exclude —
        // a bare call inside a companion-scoped context must skip the
        // companion and land on the outer instance exactly like the
        // name-based walk would. No fitting receiver: fall back to the
        // name-based resolution entirely (the lowering pick can be wrong;
        // the runtime walk corrects it).
        committed_ext_h = null;
        if (committed_ext) |fid| {
            for (cands) |c| {
                if (host.committedExtReceiverProven(allocator, fid, &c.v)) {
                    committed_ext_h = fid;
                    committed_recv_h = c.v;
                    break;
                }
            }
            if (committed_ext_h == null) {
                for (cands) |c| {
                    if (!host.committedExtReceiverDisproven(fid, &c.v)) {
                        committed_ext_h = fid;
                        committed_recv_h = c.v;
                        break;
                    }
                }
            }
            if (committed_ext_h == null) {
                // Every receiver disproves the committed target. The static
                // commitment still LOCKS this self-name walk to members-only:
                // unlocking the by-name extension re-pick is what let a body
                // re-select ITSELF once bound refutation disproved its
                // committed sibling on every receiver (`Iterable.contains`'s
                // smart-cast `contains(element)` on a List). Members serve
                // exactly as when the commitment merely failed its positive
                // proof, and the terminal committed invoke keeps the
                // pre-refuter fallback shape.
                committed_ext_h = fid;
            }
        }
        // Strict pass: members and receiver-compatible extensions of each
        // candidate, innermost first — the kotlinc candidate order.
        for (cands, 0..) |c, ci| {
            if (cmgTraceWant()) |w| {
                if (std.mem.eql(u8, w, name_str)) {
                    const cn: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&c.v) else @tagName(std.meta.activeTag(c.v));
                    std.debug.print("[cmg-cand] {s} ci={d} depth={d} tag={s} class={s}\n", .{ name_str, ci, c.depth, @tagName(std.meta.activeTag(c.v)), cn });
                }
            }
            // The lowering-recorded receiver type describes the innermost
            // implicit receiver — the first candidate — regardless of the
            // wrapper identity a suspend transform gave the value. A
            // FRAME-derived hint (the enclosing extension's declared
            // receiver) describes only the frame's own `this`: applying it
            // to an inner receiver-lambda subject (`apply { minusAssign(k) }`
            // inside `Map.minus`) refutes the very candidates the subject
            // satisfies.
            // With a DIRECT SPLICE RECEIVER on the instruction, `this_val`
            // is the spliced SUBJECT — the frame-derived head must anchor to
            // the frame's own `this` (a `with(period)` subject inside
            // `Instant.plus` must not inherit the extension's `Instant`
            // proof, or the strict probe binds the Instant extension to the
            // period and its body reads the wrong fields).
            const hint_anchor: Value = if (!static_from_instr and cmg.recv != null)
                implicitThisValue(frame, cmg.this_idx, true)
            else
                this_val;
            const hint: ?[]const u8 = if (static_recv_ty != null and
                (sameReceiver(c.v, hint_anchor) or (static_from_instr and ci == 0)))
                static_recv_ty
            else
                null;
            // A bare `invoke()` on a callable candidate is a fun-interface
            // dispatch (`with(pointerInputEventHandler) { invoke() }`): the
            // interface method may declare an extension receiver, which
            // Kotlin resolves from the ENCLOSING implicit receivers — the
            // plain invoke arm would run the lambda with no receiver at
            // all and strand its bare-member calls. Route it through the
            // receiver-carrying bridge below.
            if ((c.v == .IrClosure) and std.mem.eql(u8, name_str, "invoke")) {
                if (try samCandidateInvoke(H, allocator, frame, host, cands, ci, name_str, arg_values, names)) |sr| switch (sr) {
                    .done => |v| {
                        resolved = v;
                        break;
                    },
                    .raised => |e| return raiseStep(frame, e),
                };
                continue;
            }
            // Flat bare-member dispatch: when this candidate's resolved-method
            // cache already names the target (the same entry the strict
            // probe's ladder would fire-and-run first), run it as a pushed
            // activation. The reified-type-binding shape keeps globals bound
            // for the call's duration through this arm's defers, so it stays
            // on the recursive path.
            if (comptime @hasDecl(H, "prepareMemberFlatCall")) {
                if (flatEnabled() and mit_saved.items.len == 0 and argNamesAllNull(cmg.arg_names)) {
                    if (try host.prepareMemberFlatCall(allocator, &c.v, name_str, arg_values, hint, null, false)) |prep0| {
                        var prep = prep0;
                        prep.dst = cmg.dst;
                        orAudit("CallMemberOrGlobal", name_str, "member", c.depth, &c.v);
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            switch (if (committed_ext_h != null)
                try host.callMemberMembersOnly(allocator, &c.v, name_str, arg_values, names, hint)
            else
                try host.callMemberStrictExt(allocator, &c.v, name_str, arg_values, names, hint)) {
                .ok => |v| {
                    orAudit("CallMemberOrGlobal", name_str, "member", c.depth, &c.v);
                    resolved = v;
                    break;
                },
                .err => |e| switch (e) {
                    .Suspended, .CalleeFailed => return raiseStep(frame, e),
                    // Control flow out of a body that RAN: the candidate
                    // was the real callee (a `synchronized { return x }`
                    // non-local return, a thrown exception). Walking on
                    // would re-execute its side effects on an outer
                    // receiver — same doctrine as `CalleeFailed`.
                    .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                    .Unimplemented => |m| {
                        freeDispatchMissMsg(allocator, m);
                        // A callable candidate is an unwrapped fun-interface
                        // value: the bare name dispatches its single abstract
                        // method to the lambda (`with(layoutNode.measurePolicy)
                        // { measure(measurables, constraints) }` stores the
                        // conversion-site lambda). Kotlin binds the INNERMOST
                        // receiver, so the interface dispatch must win here —
                        // before an outer receiver's same-name member (the
                        // coordinator's 1-arg `measure`) grabs the call. A
                        // closure has no real members, so nothing is shadowed.
                        if (c.v == .IrClosure) {
                            if (try samCandidateInvoke(H, allocator, frame, host, cands, ci, name_str, arg_values, names)) |sr| switch (sr) {
                                .done => |v| resolved = v,
                                .raised => |re| return raiseStep(frame, re),
                            };
                            if (resolved != null) break;
                        }
                    },
                    else => if (first_real_err == null) {
                        first_real_err = e;
                    },
                },
            }
        }
        // Lenient pass: receivers whose runtime type cannot prove the
        // extension-receiver match. Runs only after every receiver missed
        // strictly, so an unprovable pick never outranks a real member.
        if (resolved == null) {
            for (cands, 0..) |c, ci| {
                const lhint: ?[]const u8 = if (static_recv_ty != null and
                    (sameReceiver(c.v, this_val) or (static_from_instr and ci == 0)))
                    static_recv_ty
                else
                    null;
                switch (if (committed_ext_h != null)
                    try host.callMemberMembersOnlyLenient(allocator, &c.v, name_str, arg_values, names, lhint)
                else if (lhint) |sn|
                    try host.callMemberNamedStatic(allocator, &c.v, name_str, arg_values, names, sn)
                else
                    try host.callMemberNamed(allocator, &c.v, name_str, arg_values, names)) {
                    .ok => |v| {
                        orAudit("CallMemberOrGlobal", name_str, "member_lenient", c.depth, &c.v);
                        resolved = v;
                        break;
                    },
                    .err => |e| switch (e) {
                        .Suspended, .CalleeFailed => return raiseStep(frame, e),
                        // Same as the strict pass: a body that ran owns
                        // its control flow; never re-probe.
                        .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                        .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
                        else => if (first_real_err == null) {
                            first_real_err = e;
                        },
                    },
                }
            }
        }
        // Smart-cast pass: a DEFERRED bare extension call (no committed target)
        // inside an extension body pinned the DECLARED receiver type for the
        // strict/lenient probes. When those found nothing, the receiver value
        // may be a subtype the receiver was narrowed to by a smart-cast
        // (`fun Source.f() { if (this is Buffer) commonReadUtf8CodePoint() }`,
        // whose target is `fun Buffer.commonReadUtf8CodePoint()`), so retry by
        // the receiver's RUNTIME type. Guarded to `resolved == null` and no
        // committed extension: there is no static candidate to conflict with,
        // so this cannot re-pick a sibling the static evidence excluded.
        if (resolved == null and static_recv_ty != null and committed_ext_h == null) {
            for (cands) |c| {
                switch (try host.callMemberStrictExt(allocator, &c.v, name_str, arg_values, names, null)) {
                    .ok => |v| {
                        orAudit("CallMemberOrGlobal", name_str, "smartcast_ext", c.depth, &c.v);
                        resolved = v;
                        break;
                    },
                    .err => |e| switch (e) {
                        .Suspended, .CalleeFailed, .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                        .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
                        else => if (first_real_err == null) {
                            first_real_err = e;
                        },
                    },
                }
            }
        }
    }
    if (resolved == null and if (nuTraceWant()) |w| std.mem.eql(u8, name_str, w) else false) {
        var cands2_l = try implicitCandidatesAlloc(H, allocator, frame, cmg.this_idx, true, host, name_str, direct_this);
        defer releaseCands(allocator, &cands2_l);
        const cands2 = cands2_l.items;
        const cands_keepalive = pinImplicitCandidates(cands2);
        defer runtime.keepaliveRestore(cands_keepalive);
        const dbg_srt: []const u8 = blk: {
            if (cmg.static_recv) |sc| {
                if (constStr(frame.module, sc)) |sname| break :blk sname;
            }
            break :blk "-";
        };
        std.debug.print("[par-miss] in={s}#{d} static_recv={s} skip={} ncands={d}:", .{ frame.func.name, frame.func.id.int(), dbg_srt, skip_member, cands2.len });
        for (cands2) |c| {
            if (c.v == .Instance) {
                const ig = c.v.Instance.borrow();
                const cg = ig.get().class.borrow();
                std.debug.print(" {s}", .{cg.get().name});
                cg.deinit();
                ig.deinit();
            } else std.debug.print(" {s}", .{@tagName(c.v)});
        }
        std.debug.print("\n", .{});
        {
            var anc = frame.gc_link;
            var ai: usize = 0;
            std.debug.print("[par-anc]", .{});
            while (anc) |af| : (anc = af.gc_link) {
                std.debug.print(" <-{s}#{d}", .{ af.func.name, af.func.id.int() });
                ai += 1;
                if (ai >= 6) break;
            }
            std.debug.print("\n", .{});
        }
        {
            const ents = try enclosingEntriesAlloc(allocator);
            defer allocator.free(ents);
            std.debug.print("[par-enc] n={d}:", .{ents.len});
            for (ents) |e| {
                if (e.v == .Instance) {
                    const ig = e.v.Instance.borrow();
                    const cg = ig.get().class.borrow();
                    std.debug.print(" {s}{s}", .{ cg.get().name, if (e.isSubject()) @as([]const u8, "*") else "" });
                    cg.deinit();
                    ig.deinit();
                } else std.debug.print(" {s}", .{@tagName(e.v)});
            }
            std.debug.print("\n", .{});
        }
    }
    var result: Value = undefined;
    if (resolved == null) {
        if (committed_ext_h) |fid| {
            var ext_args = try allocator.alloc(Value, arg_values.len + 1);
            defer allocator.free(ext_args);
            ext_args[0] = committed_recv_h orelse this_val;
            for (arg_values, 0..) |av, i| ext_args[i + 1] = av;
            switch (try host.callFunc(allocator, frame.module, fid, ext_args)) {
                .ok => |v| {
                    if (routeTraceOn(name_str)) std.debug.print("[evroute] committed_ext\n", .{});
                    orAudit("CallMemberOrGlobal", name_str, "committed_ext", -1, null);
                    try frame.write(cmg.dst, v);
                    return .cont;
                },
                .err => |e| return raiseStep(frame, e),
            }
        }
    }
    if (routeTraceOn(name_str)) std.debug.print("[cmgsec] resolved={}\n", .{resolved != null});
    if (resolved) |v| {
        result = v;
    } else {
        // The member passes all missed on a single implicit-receiver
        // candidate: record so a repeat call skips straight here. A pass
        // that FAILED (first_real_err — an abort, a callee error) is not a
        // miss: recording it taught the site to skip the member walk
        // forever, so after one wall-capped test every later
        // `removeKnownCompositionLocked` in the same process resolved as
        // an unresolved global (the contamination cluster).
        if (cmg_skip and single_cand and !is_ctor_name and !shadow_capture and first_real_err == null) {
            host.cmgGlobalRecord(func_p, &this_val, name_str, arg_values);
            // Claim the site's own shortcut for the same verdict, under the
            // same stability gate the host cache uses.
            if (site_key) |k| {
                if (dispatchCacheStable() and
                    @cmpxchgStrong(u64, @constCast(&cmg.skip_cls), 0, k.cls, .acq_rel, .monotonic) == null)
                {
                    @atomicStore(u64, @constCast(&cmg.skip_sig), k.sig, .release);
                }
            }
        }
        // Overloaded top-level function: select by runtime arg types
        // before falling back to the single global value baked in at
        // lower time.
        const cno_file: ?ir.FileId = if (frame.cur_span) |sp| sp.file else null;
        // A synthesized lambda/closure frame carries no declared package, so
        // the overload re-pick runs with an empty caller scope and a same-name
        // CROSS-PACKAGE twin can win a first-seen tie (the wrong same-signature
        // `internal fun` binds). The lowering-resolved target (`cmg.func`)
        // already settled scope; pass its package as a fallback anchor so the
        // re-pick can exclude the out-of-scope twin. Only consulted when the
        // frame package is empty, so the ordinary packaged-caller path is
        // untouched.
        const cno_anchor: []const u8 = if (frame.func.package.len == 0) blk: {
            if (cmg.func) |bf| {
                if (frame.module.funcById(bf)) |bfd| {
                    if (bfd.package.len != 0) break :blk bfd.package;
                }
            }
            // A ctor-name call resolved to a class carries no func hint; the
            // class's package anchors the scope the same way (a property-init
            // thunk calling `Color(red = …)` must see the ui.graphics
            // factories as import-tier candidates, not other-package noise).
            if (cmg.class) |cid| {
                if (cid.int() < frame.module.classes.items.len) {
                    break :blk frame.module.classes.items[cid.int()].package;
                }
            }
            break :blk "";
        } else "";
        // Arm the host→driver flat handoff: the overload terminal may
        // stash a prepared flat request instead of dispatching natively.
        // Honour KLIO_FLAT: this lane bypasses every instrumented dispatch
        // route, and an un-gated arm made the flat kill-switch a no-op for
        // exactly the calls it exists to bisect.
        if (flatEnabled()) armHostFlatReq();
        // A pinned overload family: call-site evidence committed cmg.func;
        // the candidate slice narrows to it (the slice is authoritative by
        // contract, so the value re-rank cannot widen back out).
        var pin_buf: [1]FuncId = undefined;
        const eff_candidates: ?[]const FuncId = blk: {
            if (cmg.func_final) if (cmg.func) |pf| {
                pin_buf[0] = pf;
                break :blk pin_buf[0..1];
            };
            break :blk cmg.candidates;
        };
        const cno_res = try host.callNamedOverload(allocator, frame.module, eff_candidates, name_str, arg_values, names, cmg.class, is_ctor_name, frame.func.package, cno_file, cno_anchor);
        _ = takeHostFlatArm();
        if (takeHostFlatReq()) |req0| {
            var prep = req0;
            prep.dst = cmg.dst;
            // Claim the site's global target when this dispatch was a plain
            // one: nothing pushed, nothing rebound, no receiver prepended.
            if (site_key) |k| {
                if (!is_ctor_name and !shadow_capture and first_real_err == null and
                    cmg.type_args.len == 0 and mit_saved.items.len == 0 and
                    prep.args.items.len == arg_values.len and
                    prep.run_module == null and leafPlainReq(prep) and
                    dispatchCacheStable() and
                    @atomicLoad(u64, @constCast(&cmg.skip_cls), .acquire) == k.cls and
                    @atomicLoad(u64, @constCast(&cmg.skip_sig), .monotonic) == k.sig)
                {
                    _ = @cmpxchgStrong(u32, @constCast(&cmg.global_fid), 0, prep.func.id.int() + 1, .acq_rel, .monotonic);
                }
            }
            frame.flat_call = prep;
            return .flat_call;
        }
        const overload = switch (cno_res) {
            .ok => |maybe| maybe,
            .err => |e| return raiseStep(frame, e),
        };
        if (overload) |v| {
            if (routeTraceOn(name_str)) std.debug.print("[evroute] overload\n", .{});
            orAudit("CallMemberOrGlobal", name_str, "overload", -1, null);
            result = v;
        } else {
            // A lowering-resolved identity (constructor class or
            // shadowable top-level function) binds exactly; the
            // simple-name lookup remains the unresolved fallback. A
            // runtime-scoped shadowing capture outranks the static pick,
            // as on the load form.
            // A committed EXTENSION func is not a plain global value — it
            // needs its receiver prepended, which the committed-ext leg
            // above handles (or declines). Only a non-extension func (or a
            // class) may bind by id here; a receiverless value invocation
            // of an extension misbinds every parameter.
            const by_id_func: ?FuncId = blk: {
                // A bounded candidate set blocks the NAME fallback below, but
                // not the lowering's own committed id: the restart lambda's
                // `Defaults($rc, $changed or 1)` carries both a Unit-receiver
                // candidate (which misses) and the committed global — the id
                // is the lowering's resolution, not a same-simple-name
                // widening, and the name/arity guards below still validate it.
                const fid = cmg.func orelse break :blk null;
                const cf = frame.module.funcById(fid) orelse break :blk null;
                // A committed id can belong to the MAIN module's table while
                // this frame runs sub-module code (the same integer names an
                // unrelated function there — a restart lambda served a
                // CompositionLocalProvider call). A name mismatch in the
                // frame's table re-validates against the main module, whose
                // id space the host's by-id lookup resolves.
                if (!std.mem.eql(u8, cf.name, name_str)) {
                    if (comptime @hasDecl(H, "mainFuncNameMatches")) {
                        if (host.mainFuncNameMatches(fid, name_str)) break :blk fid;
                    }
                    break :blk null;
                }
                if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) break :blk null;
                // First-wins commit vs overloads: a committed fn the call's
                // ARITY cannot bind (a same-file private 3-arg picked for a
                // 2-arg call whose true target is a public overload in
                // another file) must not serve by id — decline so the
                // overload leg ranks the full same-name set.
                if (!frame.module.globalArityCanBind(fid, cf, arg_values.len)) break :blk null;
                break :blk fid;
            };
            // A constructor-name call (`Foo(args)` where `Foo` is a class) must
            // bind the class for construction — never a published companion
            // singleton. Pass `is_ctor_name` as `ctor_ref` so `lookupGlobalById`
            // skips the class's companion-object singleton (which it otherwise
            // returns for a class-value read); otherwise, once the companion has
            // been published (e.g. a prior `Foo.member` access), `Foo(args)`
            // resolves to `Companion.invoke` instead of constructing.
            // A committed class that cannot CONSTRUCT (an interface/abstract
            // classifier sharing the name with a callable — the pack's
            // `interface Composition` vs a local `@Composable fun
            // Composition`) never wins the by-id serve for a non-SAM call;
            // the lexical name lookup and the overload leg resolve the real
            // callable instead.
            const ctor_class: ?ir.ClassId = blk: {
                const cid = cmg.class orelse break :blk null;
                if (cid.int() < frame.module.classes.items.len) {
                    const cls = &frame.module.classes.items[cid.int()];
                    if ((cls.is_interface or cls.is_abstract) and
                        !(arg_values.len == 1 and valueInvocable(frame.module, arg_values[0])))
                    {
                        break :blk null;
                    }
                }
                break :blk cid;
            };
            // Binding by CLASS id with no function to bind IS a construction,
            // even when the lowering did not classify the call as a
            // ctor-name one: `Stamp(a, b, c, d, e)` reaches here after the
            // overload leg declined in favour of the constructor
            // (`ctor-decline ctor_pts=500 best=499`). Without treating it as
            // a ctor reference, `lookupGlobalById` returns the class's
            // published companion singleton and the call lands on
            // `Companion.invoke` — exactly what the comment above warns
            // about, which kotlinx-datetime's TimeZoneTest hits through its
            // own `LocalDateTime(year, month, day)` helper.
            const binding_ctor = is_ctor_name or (ctor_class != null and by_id_func == null);
            const by_id: ?Value = if ((ctor_class != null or by_id_func != null) and
                !host.isShadowingCapture(name_str))
                host.lookupGlobalById(allocator, by_id_func, ctor_class, binding_ctor)
            else
                null;
            // A bounded candidate set is authoritative. Once lowering has
            // supplied it, a miss may not widen back to an unrelated
            // same-simple-name global; only a runtime shadowing capture keeps
            // the lexical name lookup. Host-only/incomplete-header symbols
            // carry null and retain legacy lookup until their declarations
            // are complete enough to rank.
            const allow_name_global = cmg.candidates == null or shadow_capture;
            if (routeTraceOn(name_str)) std.debug.print("[evroute] by_id={} allow_name={}\n", .{ by_id != null, allow_name_global });
            const global = if (by_id != null)
                by_id
            else if (allow_name_global)
                switch (try host.lookupGlobalThrowing(allocator, name_str)) {
                    .ok => |maybe| maybe,
                    .err => |e| return raiseStep(frame, e),
                }
            else
                null;
            if (global) |found_callee| {
                var callee = found_callee;
                // Import rank for the by-name CLASS tier: the globals map
                // holds ONE entry per simple name — whichever same-named
                // class registered under the bake order in effect — while
                // kotlinc scopes the pick to the call site's imports. A
                // classifier serve whose fqn disagrees with an explicit
                // import of this name in the executing file re-resolves
                // through the imported fqn (functions got this rule in the
                // explicit-import-wins fix; the class tier lacked it, and a
                // bare `Size(w, h)` in ui-unit bound androidx.annotation.Size
                // over the imported geometry factory's Size on some bakes).
                if (callee == .Class) reclass: {
                    const site_file = (frame.module.decl_span.get(frame.func.id.int()) orelse break :reclass).file;
                    const cur_fqn = blk_f: {
                        const g = callee.Class.borrow();
                        defer g.deinit();
                        break :blk_f g.get().fqn;
                    };
                    for (frame.module.importAliasPathsIn(site_file, name_str)) |path| {
                        if (std.mem.eql(u8, path.fqn, cur_fqn)) break :reclass;
                    }
                    for (frame.module.importAliasPathsIn(site_file, name_str)) |path| {
                        // The imported declaration may be a top-level
                        // FACTORY FUNCTION sharing the class's name
                        // (geometry's `fun Size(width, height)`): call it
                        // directly — kotlinc's pick for this site.
                        for (frame.module.funcsBySimpleName(name_str)) |ifid| {
                            const inf = frame.module.funcById(ifid) orelse continue;
                            if (!std.mem.eql(u8, inf.fqn, path.fqn)) continue;
                            if (inf.params.len != arg_values.len) continue;
                            if (inf.params.len != 0 and std.mem.eql(u8, inf.params[0].name, "this")) continue;
                            switch (try host.callFuncNamed(allocator, frame.module, ifid, arg_values, names)) {
                                .ok => |rv| {
                                    try frame.write(cmg.dst, rv);
                                    return .cont;
                                },
                                .err => |e| return raiseStep(frame, e),
                            }
                        }
                        switch (try host.lookupGlobalThrowing(allocator, path.fqn)) {
                            .ok => |maybe| if (maybe) |v| {
                                callee = v;
                                break :reclass;
                            },
                            .err => |e| return raiseStep(frame, e),
                        }
                    }
                }
                // A CALL is not served by a non-callable name binding: a
                // captured `var key = 0` beside the `key(...) { }` composable
                // does not shadow the function for an invocation — Kotlin
                // binds the function; the scoped-global walk merely found the
                // nearer non-callable capture. Re-bind through the function
                // index before invoking the value.
                if (!valueInvocable(frame.module, callee) and cmg.candidates == null) {
                    if (frame.module.funcId(name_str)) |fid| {
                        if (host.lookupGlobalById(allocator, fid, null, false)) |fv| {
                            orAudit("CallMemberOrGlobal", name_str, "noncallable_rebind", -1, null);
                            callee = fv;
                        }
                    }
                }
                orAudit("CallMemberOrGlobal", name_str, if (by_id != null) "global_id" else "global", -1, null);
                // Explicit call-site type args survive the deferred form;
                // a typed value dispatch lets the host coerce unsigned
                // literals / serve reified intrinsics by them.
                if (cmg.type_args.len != 0) {
                    var ta_buf: [4][]const u8 = undefined;
                    const n_ta = @min(cmg.type_args.len, ta_buf.len);
                    for (cmg.type_args[0..n_ta], ta_buf[0..n_ta]) |cid, *slot| {
                        slot.* = constStr(frame.module, cid) orelse "";
                    }
                    switch (try host.callValueNamedTyped(allocator, &callee, arg_values, names, ta_buf[0..n_ta])) {
                        .ok => |v| result = v,
                        .err => |e| return raiseStep(frame, e),
                    }
                } else switch (try host.callValueNamed(allocator, &callee, arg_values, names)) {
                    .ok => |v| {
                        if (missTraceWant()) |w| {
                            if (std.mem.eql(u8, w, name_str)) {
                                std.debug.print("[gid-result] {s} in_fn={s} callee={s} nargs={d} -> {s}", .{
                                    name_str,
                                    frame.func.name,
                                    @tagName(std.meta.activeTag(callee)),
                                    arg_values.len,
                                    @tagName(std.meta.activeTag(v)),
                                });
                                if (arg_values.len == 1 and arg_values[0] == .ULong)
                                    std.debug.print(" arg={x}", .{arg_values[0].ULong});
                                if (v == .ULong) std.debug.print(" {x}", .{v.ULong});
                                if (v == .Long) std.debug.print(" {x}", .{v.Long});
                                std.debug.print("\n", .{});
                            }
                        }
                        result = v;
                    },
                    .err => |e| return raiseStep(frame, e),
                }
            } else {
                if (first_real_err) |fre| return raiseStep(frame, fre);
                // A committed header carrying reified type args serves
                // through the typed func dispatch (the reified intrinsics
                // live there) before the unsettled-header no-op —
                // `enumEntriesIntrinsic()` spliced into a lambda body.
                if (cmg.func != null and cmg.type_args.len != 0 and comptime @hasDecl(H, "callFuncTyped")) {
                    var ta_buf: [4][]const u8 = undefined;
                    const n_ta = @min(cmg.type_args.len, ta_buf.len);
                    for (cmg.type_args[0..n_ta], ta_buf[0..n_ta]) |tcid, *slot| {
                        slot.* = constStr(frame.module, tcid) orelse "";
                    }
                    orAudit("CallMemberOrGlobal", name_str, "typed_header", -1, null);
                    switch (try host.callFuncTyped(allocator, frame.module, cmg.func.?, arg_values, names, ta_buf[0..n_ta], false)) {
                        .ok => |v| {
                            try frame.write(cmg.dst, v);
                            return .cont;
                        },
                        .err => |e| return raiseStep(frame, e),
                    }
                }
                // Every arm missed, but the name is a declared header the
                // link could not settle (an `expect` with no compiled
                // `actual`): the call is a no-op, the shape its
                // manufactured empty body produced before header-only
                // declarations stayed bodyless.
                if (host.bareUnsettledHeaderNoOp(frame.module, name_str, arg_values.len)) {
                    orAudit("CallMemberOrGlobal", name_str, "unsettled_header_noop", -1, null);
                    result = .Unit;
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                    if (missTraceWant()) |w| {
                        if (std.mem.eql(u8, w, name_str)) {
                            std.debug.print("[cmg-tail] name={s} func={?} class={?} this_tag={s} n_seen_err={} span={d}:{d} cands={d} in_fn={s} recvp={} np={d} p0={s} nparams_vals={d} this_idx={d} ncaps={d}\n", .{
                                name_str,
                                if (cmg.func) |f| f.int() else null,
                                if (cmg.class) |c| c.int() else null,
                                @tagName(std.meta.activeTag(this_val)),
                                first_real_err != null,
                                if (frame.cur_span) |sp| sp.file.int() else 0,
                                if (frame.cur_span) |sp| sp.start else 0,
                                if (cmg.candidates) |c| c.len else 0,
                                frame.func.name,
                                frame.func.has_receiver_param,
                                frame.func.params.len,
                                if (frame.func.params.len > 0) frame.func.params[0].name else "-",
                                frame.params.items.len,
                                cmg.this_idx,
                                frame.captures.items.len,
                            });
                        }
                    }
                    dumpFrameChainForDiag();
                    return raiseStep(frame, .{ .Unbound = msg });
                }
            }
        }
    }
    try frame.write(cmg.dst, result);
    return .cont;
}

/// The enclosing-chain entry a method / extension frame contributes for
/// its own bound receiver: a dispatch receiver carries its class-nesting
/// tower and companion (`receiver`); an extension receiver brings only
/// itself (`subject`). `null` for plain functions, lambdas (their
/// receiver scope is the creation-time chain), and unbound frames.
pub fn ownReceiverEntry(func: *const Func, params: []const Value) ?EnclosingEntry {
    const kind: EnclosingEntry.Kind = switch (func.kind) {
        .instance_method => .receiver,
        .top_level_extension, .member_extension => .subject,
        .plain => return null,
    };
    if (func.is_lambda) return null;
    if (func.params.len == 0 or !std.mem.eql(u8, func.params[0].name, "this")) return null;
    if (params.len == 0) return null;
    const v = params[0];
    if (v == .Null or v == .Unit) return null;
    return .{ .v = v, .kind = kind };
}

/// The captured/parameter outer link of an `Instance` value.
fn instanceOuter(v: *const Value) ?Value {
    return switch (v.*) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            break :blk g.get().outer;
        },
        else => null,
    };
}

/// Index of the frame's *synthesized* `this` receiver parameter, if any.
/// A leading `this` param is the frame's own dispatch receiver only when
/// the lowerer injected it (`has_receiver_param`): a method / extension /
/// local-extension receiver, or a constructor / init thunk's instance
/// under construction. A user parameter that merely spells its name `this`
/// (`fun f(\`this\`: T)`, written with backticks since `this` is a hard
/// keyword) is NOT a dispatch receiver, so a bare call in its body
/// resolves no implicit receiver — matching kotlinc, which rejects such a
/// call. The synthesized receiver is always at index 0.
fn frameThisParam(frame: *const Frame) ?usize {
    if (!frame.func.has_receiver_param) return null;
    if (frame.func.params.len != 0 and std.mem.eql(u8, frame.func.params[0].name, "this")) {
        return 0;
    }
    return null;
}

/// Simple name of the class that DECLARES `fid` as one of its methods, found
/// by identity in `module`'s class table (the this-param's nominal type is a
/// placeholder for stdlib methods, so it cannot serve here). Used to give an
/// instance method's implicit-`this` call the static receiver type Kotlin
/// resolves it against — its declaring class. `null` when no class owns it
/// (a top-level / local function reached with an injected receiver).
/// The head of a dotted class name (`a.b.C` -> `C`).
fn simpleClassHead(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// The class that declares `fid`, over a lazily built reverse index. The
/// linear scan this replaces is O(classes x methods) per lookup, which a
/// dispatch arm consulting several candidate fids per call turned into the
/// dominant cost of a compose recomposition (63% of one profile).
var decl_class_cache: ?std.AutoHashMap(u32, []const u8) = null;
var decl_class_module: ?*const Module = null;
var decl_class_mutex: runtime.SpinMutex = .{};

pub fn declaringClassName(module: *const Module, fid: ir.FuncId) ?[]const u8 {
    decl_class_mutex.lock();
    defer decl_class_mutex.unlock();
    if (decl_class_module != module or decl_class_cache == null) {
        if (decl_class_cache) |*old_map| old_map.deinit();
        var map = std.AutoHashMap(u32, []const u8).init(std.heap.page_allocator);
        for (module.classes.items) |*c| {
            for (c.methods) |mfid| {
                map.put(@intFromEnum(mfid), c.name) catch {};
            }
        }
        decl_class_cache = map;
        decl_class_module = module;
    }
    return decl_class_cache.?.get(@intFromEnum(fid));
}

/// The calling frame's receiver, an Instance from either a `this`-named
/// param or a `this`-named capture. `null` otherwise.
pub fn callerThisValue(frame: *const Frame) ?Value {
    if (frameThisParam(frame)) |i| {
        if (i < frame.params.items.len and frame.params.items[i] == .Instance) {
            return frame.params.items[i];
        }
    }
    var idx = frame.func.this_cap_idx;
    if (idx == -2) {
        idx = -1;
        for (frame.func.capture_order, 0..) |n, i| {
            if (std.mem.eql(u8, n, "this")) {
                idx = @intCast(i);
                break;
            }
        }
        @constCast(frame.func).this_cap_idx = idx;
    }
    if (idx >= 0) {
        const ui: usize = @intCast(idx);
        if (ui < frame.captures.items.len and frame.captures.items[ui] == .Instance) {
            return frame.captures.items[ui];
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Implicit-receiver resolution choke point.
//
// The `*OrGlobal` instructions (`LoadFromThisOrGlobal`, `StoreToThisOrGlobal`,
// `CallMemberOrGlobal`) all resolve a bare name against the *implicit*
// receivers in scope — the lambda/method's own `this`, each
// lexically-enclosing `this@…`, and (for dispatch receivers) the class-nesting
// tower of `outer` links — before falling back to a top-level global. The
// candidate list and its order are derived in exactly one place
// (`implicitCandidatesAlloc`); the three handlers differ only in their
// terminal operation (field read / member write / member call) and in the
// call form's shadow/constructor gates. Kotlin's precedence, pinned by the
// kotlinc parity fixtures (`receiver_lambda_*`, `bare_write_*`,
// `inner_ext_over_outer_member`): candidates are searched innermost-first,
// and *all* of a receiver's candidates — members first, then applicable
// extensions — outrank any candidate of the next receiver out.
// -------------------------------------------------------------------------

/// Recover the implicit receiver for an `*OrGlobal` instruction:
/// The synthesized `this` parameter when this frame has one; otherwise
/// `captures[this_idx]` if in range, else `Null`. A method/init/extension
/// frame's receiver parameter is authoritative: its capture slot can hold an
/// unrelated boxed local at the same numeric index, and treating that Cell as
/// `this` both misresolves the bare name and leaves the real receiver behind it.
fn implicitThisValue(frame: *const Frame, this_idx: usize, consult_param: bool) Value {
    if (consult_param) {
        if (frameThisParam(frame)) |idx| {
            if (idx < frame.params.items.len) return frame.params.items[idx];
        }
    }
    // The baked capture index is only trusted when it actually names the
    // `this` capture: several emit arms bake `0` as a placeholder (the
    // direct receiver register carries the real value), and `captures[0]`
    // is then whatever capture happens to be first — a non-receiver local
    // (`scope`) that must never enter the implicit-receiver walk. When the
    // index does not name `this`, locate the real `this` capture by name;
    // a frame with no `this` capture has no capture-borne receiver at all.
    var idx = this_idx;
    const order = frame.func.capture_order;
    if (order.len != 0 and
        !(this_idx < order.len and std.mem.eql(u8, order[this_idx], "this")))
    {
        var found: ?usize = null;
        for (order, 0..) |n, i| {
            if (std.mem.eql(u8, n, "this")) {
                found = i;
                break;
            }
        }
        idx = found orelse return Value.Null;
    }
    const this_val: Value = if (idx < frame.captures.items.len)
        frame.captures.items[idx]
    else
        Value.Null;
    return this_val;
}

/// One candidate receiver for a bare-name `*OrGlobal` resolution. `depth`
/// is the candidate's position in the search order (0 = the frame's own
/// implicit `this`), recorded for the KLIO_OR_AUDIT readout.
const ImplicitCandidate = struct {
    v: Value,
    depth: u16,
    /// True when this candidate belongs to the frame's OWN receiver run
    /// (the dispatch `this`, its companion, its class-nesting tower):
    /// the one run whose class-body scope lexically encloses the
    /// executing body. Chain entries published by dispatch context are
    /// not `own` — their members do not outrank a captured local.
    own: bool = false,
};

/// Low bits of a `site_cache` word: 2-bit verdict + 8-bit winner index;
/// the rest is the shape hash.
const SITE_SHAPE_MASK: u64 = ~@as(u64, 0x3FF);
const SITE_MISS: u64 = 1;
const SITE_WIN: u64 = 2;

/// Fold the candidate list into a stable shape word for the bare-name
/// site memo: an Instance contributes its class identity and stored
/// field count (a dynamically defined field flips the shape), every
/// other value contributes its tag. Null disables the memo for this
/// execution — a candidate carrying lexical `this@` captures probes
/// foreign receivers whose state the shape cannot cover.
fn implicitSiteShape(cands: []const ImplicitCandidate) ?u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (cands) |c| {
        var k: u64 = undefined;
        if (c.v == .Instance) {
            const g = c.v.Instance.borrow();
            defer g.deinit();
            const b = g.get();
            if (b.anon_captures.len != 0) return null;
            k = @as(u64, @intCast(b.class.identity())) ^ (@as(u64, b.fields.items.len) *% 0x9e3779b97f4a7c15);
        } else {
            k = @as(u64, @intFromEnum(std.meta.activeTag(c.v))) +% 0x51ed270b;
        }
        h = (h ^ k) *% 0x100000001b3;
    }
    // Zero means "no entry"; nudge a colliding shape off it.
    if (h & SITE_SHAPE_MASK == 0) h = 0x400;
    return h;
}

/// Candidate walks are assembled in host scratch memory, but probing a
/// property/getter or member can re-enter interpreted code and collect. Keep
/// every receiver alive for the whole walk, including transient Cell and
/// companion candidates that are not independently present in a frame.
fn pinImplicitCandidates(cands: []const ImplicitCandidate) usize {
    const mark = runtime.keepaliveMark();
    for (cands) |c| runtime.keepalivePush(c.v);
    return mark;
}

/// The ordered implicit-receiver candidates a bare name is resolved
/// against, innermost first: the frame's own implicit `this` (when
/// present), then each lexically-enclosing `this@…`. A receiver that
/// entered scope by dispatch (a method receiver or a displaced lexical
/// `this`) is followed by its class's companion object (when that
/// companion owns a member of the searched name — Kotlin puts the
/// companion in scope at the class's own depth, below the instance
/// receiver) and by its class-nesting tower of `outer` links — inside a
/// member of `Inner`, `this@Outer` is in scope through `this@Inner` —
/// while a `with`/`run`/`apply` subject brings only itself
/// (`with(x) { … }` never puts `x`'s enclosing instances or companion in
/// scope). Caller frees the returned slice.
const SamInvokeOutcome = union(enum) { done: Value, raised: EvalError };

/// Dispatch a bare name that missed (or is `invoke`) on a CALLABLE walk
/// candidate as a fun-interface method: run the lambda with the next
/// implicit receiver out handed as `this` (the interface method may be a
/// member extension — `MeasurePolicy`'s `MeasureScope.measure` — whose
/// body resolves bare names against that receiver). Returns null when the
/// invocation itself reports a non-control-flow error, letting the walk
/// continue.
fn samCandidateInvoke(
    comptime H: type,
    allocator: Allocator,
    frame: *Frame,
    host: *H,
    cands: []const ImplicitCandidate,
    ci: usize,
    name_str: []const u8,
    arg_values: []const Value,
    names: []const ?[]const u8,
) Allocator.Error!?SamInvokeOutcome {
    // For any name other than `invoke`, the interface-method reading is
    // only plausible when the callable's declared parameter count matches
    // the call exactly, AND no top-level non-extension function serves
    // the name — kotlinc resolves `probeCoroutineResumed(completion)` to
    // the top-level helper even inside an extension on a function type,
    // where the implicit `this` IS the coroutine block; invoking the
    // block ran every UNDISPATCHED launch body twice. Names with only
    // member/extension forms (`measure`, `emit`) keep the dispatch.
    if (!std.mem.eql(u8, name_str, "invoke")) {
        if (comptime @hasDecl(H, "callableFieldArity")) {
            const n = host.callableFieldArity(&cands[ci].v) orelse return null;
            if (n != arg_values.len) return null;
        }
        for (frame.module.funcsBySimpleName(name_str)) |fid| {
            const f = frame.module.funcById(fid) orelse continue;
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
            return null;
        }
        // A DEEPER implicit receiver that can serve the name (a member of
        // its hierarchy or an applicable extension) outranks the
        // interface-method reading of this callable: `collect(this)`
        // inside an `unsafeFlow { }` block binds the outer Flow receiver's
        // `collect`, never the captured action lambda. Decline so the walk
        // reaches that receiver.
        if (comptime @hasDecl(H, "valueCouldServeName")) {
            var j = ci + 1;
            while (j < cands.len) : (j += 1) {
                if (host.valueCouldServeName(allocator, &cands[j].v, name_str, arg_values.len)) return null;
            }
        }
    }
    var sam_recv = cands[ci].v;
    if (runtime.envOnce("KLIO_SAM_TRACE") != null) {
        std.debug.print("[sam-walk] name={s} nargs={d} ci={d} n={d} tags:", .{ name_str, arg_values.len, ci, cands.len });
        for (cands, 0..) |c, k| {
            const served = if (comptime @hasDecl(H, "valueCouldServeName")) host.valueCouldServeName(allocator, &c.v, name_str, arg_values.len) else false;
            const cls: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&c.v) else "?";
            std.debug.print(" [{d}]{s}({s})/serve={}", .{ k, @tagName(c.v), cls, served });
        }
        std.debug.print("\n", .{});
    }
    const sam_this: ?Value = if (ci + 1 < cands.len) cands[ci + 1].v else null;
    const sam_res = if (comptime @hasDecl(H, "callValueWithThis")) blk: {
        if (sam_this) |st| break :blk try host.callValueWithThis(allocator, &sam_recv, &st, arg_values, names);
        break :blk try host.callValueNamed(allocator, &sam_recv, arg_values, names);
    } else try host.callValueNamed(allocator, &sam_recv, arg_values, names);
    switch (sam_res) {
        .ok => |v| {
            orAudit("CallMemberOrGlobal", name_str, "sam_receiver_invoke", cands[ci].depth, &cands[ci].v);
            return .{ .done = v };
        },
        .err => |se| switch (se) {
            .Suspended, .CalleeFailed, .Throw, .NonLocalReturn, .LabeledReturn => return .{ .raised = se },
            else => {
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[sam-inv] {s} swallowed err={s}\n", .{ name_str, @tagName(se) });
                }
                return null;
            },
        },
    }
}

/// Free-list of candidate buffers: the walk runs on every dynamic member
/// dispatch and its alloc/free pair showed in the gate's heaviest test.
/// Buffers are allocator-owned (growth past the class frees them into the
/// allocator exactly as the args pool's carriers do); release retains
/// only exact-class capacities.
const CAND_POOL_CAP = 32;
const CAND_POOL_MAX = 8;
threadlocal var cand_pool: struct { bufs: [CAND_POOL_MAX][]ImplicitCandidate, len: usize } = .{ .bufs = undefined, .len = 0 };

fn acquireCands(allocator: Allocator) Allocator.Error!std.ArrayList(ImplicitCandidate) {
    if (cand_pool.len > 0) {
        cand_pool.len -= 1;
        const b = cand_pool.bufs[cand_pool.len];
        return .{ .items = b[0..0], .capacity = b.len };
    }
    var l: std.ArrayList(ImplicitCandidate) = .empty;
    try l.ensureTotalCapacityPrecise(allocator, CAND_POOL_CAP);
    return l;
}

fn releaseCands(allocator: Allocator, l: *std.ArrayList(ImplicitCandidate)) void {
    if (l.capacity == CAND_POOL_CAP and cand_pool.len < CAND_POOL_MAX) {
        cand_pool.bufs[cand_pool.len] = l.items.ptr[0..l.capacity];
        cand_pool.len += 1;
        l.* = .empty;
        return;
    }
    l.deinit(allocator);
}

fn implicitCandidatesAlloc(comptime H: type, allocator: Allocator, frame: *const Frame, this_idx: usize, consult_param: bool, host: *H, bare_name: []const u8, direct_this: ?Value) Allocator.Error!std.ArrayList(ImplicitCandidate) {
    var out: std.ArrayList(ImplicitCandidate) = try acquireCands(allocator);
    errdefer releaseCands(allocator, &out);
    var depth: u16 = 0;
    const entries = try enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    // IN-FLIGHT chain pushes — entries this frame pushed DURING execution
    // (a spliced `with`/`apply` subject via `EnclosingPush`, a dispatch
    // access push) — are lexically INNER to the frame's own receiver: the
    // subject of `toTypedArray().apply { sort() }` inside `List.sorted`
    // outranks the extension's List `this`, exactly as the framed route's
    // closure receiver would. `enclosingEntriesAlloc` reverses the chain,
    // so the in-flight region is its PREFIX; rank it ahead of `inner`.
    const in_flight: usize = blk: {
        if (frame.tls.active_chain != &frame.enclosing_this) break :blk 0;
        const total = frame.enclosing_this.items.len;
        const base = frame.tls.active_chain_base;
        break :blk if (total > base) total - base else 0;
    };
    for (entries[0..@min(in_flight, entries.len)]) |e| {
        try appendCandidateRun(H, allocator, &out, e.v, e.isSubject(), false, &depth, host, bare_name);
    }
    // The innermost candidate is the inline-splice's bound receiver when
    // supplied (it lives in a local register, invisible to the frame `this`
    // slot / capture lookup), otherwise the frame's own `this`. A supplied
    // direct receiver is subject-like (its own value only, no class-nesting
    // tower); it replaces, rather than precedes, the frame `this`.
    const inner: ?Value = if (direct_this) |dt|
        dt
    else blk: {
        const tv = implicitThisValue(frame, this_idx, consult_param);
        break :blk if (tv == .Null or tv == .Unit) null else tv;
    };
    if (inner) |iv| {
        if (iv != .Unit) {
            // When the innermost receiver is also the innermost chain entry
            // (a seeded method/extension receiver, or a receiver-split
            // subject), the entry's own run covers it with the right kind.
            // A subject-kind duplicate must not suppress a REAL receiver
            // param's own run (the inner IteratorImpl's `remove` reaches
            // the OUTER list only through its dispatch tower) — but a
            // capture-received lambda `this` IS the subject (a `with`
            // block's bare call must NOT see the subject's enclosing
            // instances; kotlinc rejects `describe()` in
            // `with(outer.Inner())`).
            const own_dispatch_shape = frame.func.params.len != 0 and
                std.mem.eql(u8, frame.func.params[0].name, "this");
            const dup = entries.len > in_flight and sameReceiver(entries[in_flight].v, iv) and
                (!entries[in_flight].isSubject() or !own_dispatch_shape);
            if (!dup) {
                // The frame's own `this` brings its class-nesting tower (and
                // companion) only when it is a *dispatch* receiver. An
                // extension receiver — or a supplied splice receiver — is
                // subject-like: `fun Owner.Inner.f()` does not put `Inner`'s
                // enclosing `Owner` instance or companion in scope.
                // A direct receiver that IS the frame's own `this` param
                // is a dispatch receiver (an init-block/accessor thunk
                // carries `this` explicitly), so its nesting tower and
                // companion stay in scope; only a FOREIGN direct receiver
                // (a splice/extension subject) suppresses them.
                const direct_is_frame_recv = if (direct_this) |dt| blk: {
                    if (frameThisParam(frame)) |ti| {
                        if (ti < frame.params.items.len and sameReceiver(frame.params.items[ti], dt)) break :blk true;
                    }
                    // An INSTANCE METHOD's `this` param has no
                    // has_receiver_param bit, and a flat activation may
                    // route it through the capture slot: compare against
                    // whatever the non-direct path would have used, so a
                    // splice-bound register that holds the frame's OWN
                    // dispatch receiver keeps its class-nesting tower
                    // (`removeAt(...)` inside AbstractMutableList's inner
                    // IteratorImpl.remove reaches the OUTER list).
                    const tv = implicitThisValue(frame, this_idx, consult_param);
                    if (tv != .Null and tv != .Unit and sameReceiver(tv, dt)) break :blk true;
                    break :blk false;
                } else false;
                const own_is_subject = (direct_this != null and !direct_is_frame_recv) or switch (frame.func.kind) {
                    .top_level_extension, .member_extension => true,
                    else => false,
                };
                // The same value may already sit on the chain as a spliced
                // SUBJECT (an `iterator().apply { ... remove() }` splice
                // pushes the iterator; `remove`'s own frame then re-sees it
                // as its dispatch receiver). The subject entry's run has no
                // class-nesting tower, so it must not suppress the own
                // dispatch run — `removeAt(...)` inside the inner
                // IteratorImpl reaches the OUTER list only through the own
                // run's tower. The own kind still decides subject-ness.
                try appendCandidateRun(H, allocator, &out, iv, own_is_subject, true, &depth, host, bare_name);
            }
        }
    }
    // A supplied direct receiver normally REPLACES the frame `this` — but
    // when the frame carries its OWN receiver param bound to a DIFFERENT
    // value, dropping the param strands every bare member of the declared
    // receiver: the pausable pause/resume path was observed leaving a stale
    // ComposableLambdaImpl in the lowered recv register (which then deduped
    // against a leaked subject entry) while the receiver PARAM still held
    // the real MockViewValidator. The param is dispatch truth for the
    // declared receiver type; keep it in the walk between the direct
    // receiver and the ambient chain.
    if (direct_this != null and consult_param) {
        const pv = implicitThisValue(frame, this_idx, true);
        if (pv != .Null and pv != .Unit and !sameReceiver(pv, direct_this.?)) {
            var already = false;
            for (out.items) |c| {
                if (sameReceiver(c.v, pv)) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                const own_subject = switch (frame.func.kind) {
                    .top_level_extension, .member_extension => true,
                    else => false,
                };
                try appendCandidateRun(H, allocator, &out, pv, own_subject, true, &depth, host, bare_name);
            }
        }
    }
    for (entries[@min(in_flight, entries.len)..], 0..) |e, ei| {
        // The innermost chain entry is often the frame's own dispatch
        // receiver seeded by the invoke path (the dup check above then
        // skipped the frame-`this` run); it is still the OWN run.
        const e_own = ei == 0 and inner != null and sameReceiver(e.v, inner.?);
        try appendCandidateRun(H, allocator, &out, e.v, e.isSubject(), e_own, &depth, host, bare_name);
    }
    return out;
}

/// Append `v` and, unless it entered scope as a `with`/`run` subject, its
/// class's member-owning companion and its class-nesting tower (`outer`
/// links, each with its own companion). Consecutive duplicates collapse:
/// a receiver-split invoke records the receiver both in the capture slot
/// and as the innermost chain entry.
fn appendCandidateRun(
    comptime H: type,
    allocator: Allocator,
    out: *std.ArrayList(ImplicitCandidate),
    v: Value,
    is_subject: bool,
    own: bool,
    depth: *u16,
    host: *H,
    bare_name: []const u8,
) Allocator.Error!void {
    if (cmgTraceWant()) |w| {
        if (std.mem.eql(u8, w, bare_name)) {
            const cn: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&v) else "-";
            std.debug.print("[icand-append] {s} tag={s} class={s} subject={} depth={d}\n", .{ bare_name, @tagName(std.meta.activeTag(v)), cn, is_subject, depth.* });
        }
    }
    if (v == .Unit) return;
    // A null `with`/`run` subject is a real receiver candidate — a
    // nullable-receiver extension applies to it — but a null dispatch
    // receiver just means "nothing bound".
    if (v == .Null and !is_subject) return;
    if (v == .Null) {
        try out.append(allocator, .{ .v = v, .depth = depth.*, .own = own });
        depth.* +|= 1;
        return;
    }
    if (out.items.len == 0 or !sameReceiver(out.items[out.items.len - 1].v, v)) {
        try out.append(allocator, .{ .v = v, .depth = depth.*, .own = own });
    }
    depth.* +|= 1;
    if (is_subject) return;
    try appendCompanionCandidate(H, allocator, out, &v, own, depth, host, bare_name);
    var cur: ?Value = instanceOuter(&v);
    while (cur) |o| {
        if (o == .Null or o == .Unit) break;
        try out.append(allocator, .{ .v = o, .depth = depth.*, .own = own });
        depth.* +|= 1;
        try appendCompanionCandidate(H, allocator, out, &o, own, depth, host, bare_name);
        cur = instanceOuter(&o);
    }
}

/// Append the companion-object singleton of `v`'s class as a candidate at
/// the class's own depth, when that companion owns a member named
/// `bare_name`.
fn appendCompanionCandidate(
    comptime H: type,
    allocator: Allocator,
    out: *std.ArrayList(ImplicitCandidate),
    v: *const Value,
    own: bool,
    depth: *u16,
    host: *H,
    bare_name: []const u8,
) Allocator.Error!void {
    const comp = (try host.companionWithMember(allocator, v, bare_name)) orelse return;
    if (sameReceiver(comp, v.*)) return;
    try out.append(allocator, .{ .v = comp, .depth = depth.*, .own = own });
    depth.* +|= 1;
}

/// Two receiver values denote the same instance.
pub fn sameReceiver(a: Value, b: Value) bool {
    if (a == .Instance and b == .Instance) return ObjRef(InstanceData).ptrEq(a.Instance, b.Instance);
    return false;
}

var or_audit_checked: bool = false;
var or_audit_enabled: bool = false;

/// Opt-in arm-audit detector for the `*OrGlobal` instructions
/// (`KLIO_OR_AUDIT`, same pattern as `KLIO_RESOLVE_AUDIT` /
/// `KLIO_LINK_AUDIT`): every execution logs which arm bound the name —
/// `member@<depth>` (with the winning receiver's type), `overload`,
/// `global_id` (the lowering-resolved identity), `global` (name lookup),
/// or the store/global-fallback variants — so a corpus sweep proves which
/// runtime arms are live before an emit site is statically classified.
var route_trace_init: bool = false;
var route_trace_val: ?[]const u8 = null;
/// KLIO_MEXT_ARM=0 disables the bare member-extension receiver arm, for
/// single-binary A/B of its cost.
fn mextArmEnabled() bool {
    const S = struct {
        var state: u8 = 0;
    };
    if (S.state == 0) {
        const v = runtime.envOnce("KLIO_MEXT_ARM") orelse "1";
        S.state = if (std.mem.eql(u8, v, "0")) 1 else 2;
    }
    return S.state == 2;
}

fn routeTraceOn(name: []const u8) bool {
    if (!route_trace_init) {
        route_trace_val = if (std.c.getenv("KLIO_ROUTE")) |w| std.mem.span(w) else null;
        route_trace_init = true;
    }
    const w = route_trace_val orelse return false;
    return std.mem.eql(u8, w, name);
}

fn orAuditOn() bool {
    if (!or_audit_checked) {
        or_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_OR_AUDIT") catch null) |v| {
            defer a.free(v);
            or_audit_enabled = v.len != 0 and !std.mem.eql(u8, v, "0");
        }
    }
    return or_audit_enabled;
}

fn orAudit(inst_tag: []const u8, name: []const u8, arm: []const u8, depth: i32, recv: ?*const Value) void {
    if (!orAuditOn()) return;
    const recv_tag: []const u8 = if (recv) |r| r.typeFqn() else "-";
    std.debug.print(
        "[KLIO_OR_AUDIT] run inst={s} name={s} arm={s} depth={d} recv={s}\n",
        .{ inst_tag, name, arm, depth, recv_tag },
    );
}

fn stripScopeGetter(name: []const u8) []const u8 {
    const prefix = "$sgetter$";
    if (std.mem.startsWith(u8, name, prefix)) {
        const rest = name[prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '\u{1f}')) |sep| {
            return rest[sep + 1 ..];
        }
    }
    return name;
}

/// Pull `n_args` register values starting at `args_start` into a fresh
/// owned slice. Caller frees.
/// A positional call: no entry carries an argument name.
pub fn argNamesAllNull(names: []const ?ConstId) bool {
    for (names) |n| if (n != null) return false;
    return true;
}

/// A call's argument run in a carrier list. The fused static-call site hands
/// the list straight to the activation as its params, so the carrier follows
/// the same acquire/release discipline as every other frame buffer.
fn readArgList(allocator: Allocator, frame: *const Frame, args_start: Reg, n: u32) Allocator.Error!std.ArrayList(Value) {
    var list = try acquireArgsCap(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        list.appendAssumeCapacity(frame.read(Reg.from(args_start.int() + i)));
    }
    return list;
}

pub fn readArgRun(allocator: Allocator, frame: *const Frame, args_start: Reg, n: u32) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        out[i] = frame.read(Reg.from(args_start.int() + i));
    }
    return out;
}

/// Indexed-load fast path shared by the `get` subscript forms. Serves the
/// in-bounds, `Int`-index read on an `Array`/`List` directly — a plain indexed
/// load with the intrinsics' ownership (`coll_array_get`/`coll_list_get`:
/// retain the borrowed element). Returns `null` (fall through to the slow path,
/// which reproduces the exact diagnostic) for any other shape.
/// The element Value for a range cursor (mirrors the interp_ir `rangeElem`,
/// kept here so the for-loop fast path needs no host round-trip).
inline fn rangeElemEval(cur: i64, kind: runtime.RangeKind) Value {
    return switch (kind) {
        .Int => Value.newInt(cur),
        .Long => .{ .Long = cur },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(cur))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(cur))) },
        .ULong => .{ .ULong = @bitCast(cur) },
    };
}

/// Inline `hasNext()` / `next()` for a `.RangeIter` receiver. The for-loop over
/// any integer/char range desugars to `iterator()` + per-iteration
/// `hasNext()`/`next()` member calls; handling them here skips the full member
/// dispatch (and its per-call hashmap probes), which dominates tight loops.
/// Returns the result for hasNext/next, or null to fall through for any other
/// method. Mirrors `builtin_members.rangeIterMember`.
pub inline fn rangeIterFast(allocator: Allocator, recv: *const Value, name: []const u8, n_args: u32) ?EvalResult {
    if (n_args != 0) return null;
    const is_has_next = std.mem.eql(u8, name, "hasNext");
    const is_next = std.mem.eql(u8, name, "next");
    if (!is_has_next and !is_next) return null;
    const ri = recv.RangeIter;
    const snap = blk: {
        const sg = ri.borrow();
        defer sg.deinit();
        break :blk sg.get().*;
    };
    const cur = snap.cur;
    const more = !snap.done and snap.step != 0 and snap.kind.inBounds(cur, snap.end, snap.step);
    if (is_has_next) return ok(.{ .Bool = more });
    // next()
    if (!more) {
        const exc = Value.newException(allocator, .{
            .fqn = runtime.strInit(allocator, "kotlin.NoSuchElementException") catch return null,
            .message = if (runtime.strInit(allocator, "iterator exhausted")) |m| .from(m) else |_| .{},
            .cause = null,
        }) catch return null;
        return errResult(.{ .Throw = exc });
    }
    const adv = cur +| snap.step;
    const sg = ri.borrowMut();
    if (cur == snap.end or adv == cur) {
        sg.get().done = true;
    } else {
        sg.get().cur = adv;
    }
    sg.deinit();
    return ok(rangeElemEval(cur, snap.kind));
}

pub inline fn fastIndexGet(recv: *const Value, idx_v: *const Value) ?Value {
    if (idx_v.* != .Int) return null;
    const idx = idx_v.Int;
    if (idx < 0) return null;
    const ui: usize = @intCast(idx);
    switch (recv.*) {
        .Array => |arr| switch (arr.storage()) {
            .scalars => |pb| {
                const g = pb.borrow();
                defer g.deinit();
                if (ui >= g.get().len()) return null;
                // View-aware: an unsigned array over signed backing
                // (`UIntArray(intArray)`) tags elements by `arr.prim`,
                // not the buffer's storage kind.
                return g.get().getAs(ui, arr.prim orelse g.get().kind); // fresh scalar
            },
            .boxed => |vl| {
                const g = vl.borrow();
                defer g.deinit();
                const items = g.get().items;
                if (ui >= items.len) return null;
                const elem = items[ui];
                elem.retain();
                return elem;
            },
        },
        .List => |l| {
            // A stale subList view must fail fast — leave it to the slow
            // path, whose read guard throws ConcurrentModificationException.
            if (recv.sublistViewStale()) return null;
            // An array `.asList()` view re-reads its scalar source so a later
            // array write shows through on this indexed load.
            recv.refreshArrayView();
            recv.refreshSublistView();
            const g = l.items.borrow();
            defer g.deinit();
            const items = g.get().items;
            if (ui >= items.len) return null;
            const elem = items[ui];
            elem.retain();
            return elem;
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            const sd = g.get();
            // ASCII in-bounds only: the UTF-16 unit at `ui` is byte `ui`.
            // Multi-byte strings and out-of-bounds decline to the native,
            // whose UTF-16 walk and IndexOutOfBoundsException are the
            // contract.
            if (!sd.ascii or ui >= sd.bytes.len) return null;
            return .{ .Char = sd.bytes[ui] };
        },
        else => return null,
    }
}

/// Indexed-store fast path for `a[i] = v` on an `Array` or a plain mutable
/// `List` (mirrors the `coll_array_set` / `coll_mut_list_set` intrinsics:
/// release the overwritten element, retain the incoming one under a
/// reclaiming backend). Returns the SET-EXPRESSION's value — `Unit` for an
/// array, the PREVIOUS element for a list (Kotlin's `MutableList.set`
/// contract; the assignment arm discards it, the member-call arm writes it).
/// Null when not handled: out-of-bounds, an immutable receiver, and a live
/// view (subList / map-values / asList backing) all decline to the full
/// member path, whose guards throw the right exceptions and write through.
pub inline fn fastIndexSet(allocator: Allocator, recv: *const Value, idx_v: *const Value, new_val: Value) ?Value {
    if (idx_v.* != .Int) return null;
    const idx = idx_v.Int;
    if (idx < 0) return null;
    const ui: usize = @intCast(idx);
    switch (recv.*) {
        .Array => |arr| switch (arr.storage()) {
            .scalars => |pb| {
                const g = pb.borrowMut();
                defer g.deinit();
                if (ui >= g.get().len()) return null;
                g.get().setAs(ui, new_val, arr.prim orelse g.get().kind);
                return Value.Unit;
            },
            .boxed => |vl| {
                const g = vl.borrowMut();
                defer g.deinit();
                const items = g.get().items;
                if (ui >= items.len) return null;
                if (runtime.reclaimEnabled()) {
                    items[ui].release(allocator);
                    new_val.retain();
                }
                items[ui] = new_val;
                return Value.Unit;
            },
        },
        .List => |l| {
            if (!l.mutable or l.backing != null) return null;
            const g = l.items.borrowMut();
            defer g.deinit();
            const items = g.get().items;
            if (ui >= items.len) return null;
            if (runtime.reclaimEnabled()) new_val.retain();
            const prev = items[ui];
            items[ui] = new_val;
            return prev;
        },
        else => return null,
    }
}

/// Subscript fast path: `a[i]` / `a[i] = v` lower to `a.get(i)` / `a.set(i, v)`
/// member calls. Dispatching those through the full member-call machinery for
/// every array element dominates the cost of any loop-heavy program, so the
/// common case is served by the indexed-load/store primitives above. Returns
/// the value to write to `dst`, or `null` when not handled.
/// The bitwise and conversion MEMBERS of `Int` / `Long`, served inline.
///
/// `a shl b`, `a and b` and friends are ordinary infix member functions, not
/// operators, so they lower to a member call and — with no static receiver
/// type at the site — reach the name ladder on every execution. Bit math is
/// the inner loop of the snapshot id sets and the persistent-map trie, where
/// this was four out of every five slow-ladder dispatches.
///
/// A member always wins over an extension in Kotlin, so an `Int` receiver
/// with an `Int` argument and one of these names can only mean the builtin;
/// any other receiver/argument shape declines to the ladder unchanged.
pub inline fn primitiveMemberFast(frame: *const Frame, cm: anytype) ?Value {
    if (cm.arg_names.len != 0 or cm.n_args > 1) return null;
    const recv = frame.read(cm.receiver);
    const nm = constStr(frame.module, cm.name) orelse return null;
    const arg: ?Value = if (cm.n_args == 1) frame.read(Reg.from(cm.args.int())) else null;
    return primitiveMemberOp(&recv, nm, arg);
}

/// The value-level core of `primitiveMemberFast`, shared with the frameless
/// leaf walk: a pure function of the receiver, the member name and at most one
/// argument, so it needs no frame at all.
pub fn primitiveMemberOp(recv_in: *const Value, nm: []const u8, arg_in: ?Value) ?Value {
    const recv = recv_in.*;
    // `compareTo` on two same-kind primitives is a pure comparison, and it
    // was the single hottest entry in the runtime member LADDER
    // (`Char.compareTo` alone, 84,595 of 113,980) — a primitive has no
    // vtable slot, so a `Comparable` receiver dispatched by name every time.
    // Returns exactly what the host intrinsic does: the CODE DIFFERENCE for
    // `Char` (kotlinc emits `Character.compare`), and -1/0/1 for `Int`/`Long`
    // (`Integer.compare` / `Long.compare`).
    if (arg_in) |cmp_arg| {
        if (std.mem.eql(u8, nm, "compareTo")) {
            const ord: ?i64 = switch (recv) {
                .Char => |c| if (cmp_arg == .Char)
                    @as(i64, @intCast(c)) - @as(i64, @intCast(cmp_arg.Char))
                else
                    null,
                .Int => |i| if (cmp_arg == .Int)
                    (if (i < cmp_arg.Int) @as(i64, -1) else if (i > cmp_arg.Int) @as(i64, 1) else 0)
                else
                    null,
                .Long => |l| if (cmp_arg == .Long)
                    (if (l < cmp_arg.Long) @as(i64, -1) else if (l > cmp_arg.Long) @as(i64, 1) else 0)
                else
                    null,
                else => null,
            };
            if (ord) |o| return Value.newInt(o);
        }
    }
    // Backing-free container `isEmpty`, exactly the host member
    // intrinsic's answer; a live view (`backing != null`) computes its
    // length in the view machinery and stays on the framed path. Member
    // only — `isNotEmpty` is a SHADOWABLE extension, but its `!isEmpty()`
    // body leaf-serves through this arm anyway.
    if (arg_in == null) {
        switch (recv) {
            .List => |l| if (l.backing == null) {
                const n = blk: {
                    const g = l.items.borrow();
                    defer g.deinit();
                    break :blk g.get().items.len;
                };
                if (std.mem.eql(u8, nm, "isEmpty")) return .{ .Bool = n == 0 };
                return null;
            },
            .Set => |st| if (st.backing == null) {
                const n = blk: {
                    const g = st.items.borrow();
                    defer g.deinit();
                    break :blk g.get().items.len;
                };
                if (std.mem.eql(u8, nm, "isEmpty")) return .{ .Bool = n == 0 };
                return null;
            },
            else => {},
        }
    }
    if (recv != .Int and recv != .Long) return null;
    if (arg_in == null) {
        const wide: i64 = switch (recv) {
            .Int => |i| i,
            .Long => |l| l,
            else => unreachable,
        };
        if (std.mem.eql(u8, nm, "toInt")) return Value.newInt(@truncate(wide));
        if (std.mem.eql(u8, nm, "toLong")) return .{ .Long = wide };
        if (std.mem.eql(u8, nm, "inv")) return switch (recv) {
            .Int => |i| Value.newInt(~i),
            .Long => |l| .{ .Long = ~l },
            else => unreachable,
        };
        return null;
    }
    const arg = arg_in.?;
    // Shifts take an `Int` count on both receivers; the logical operations
    // take the receiver's own width.
    const shift: ?u6 = switch (arg) {
        .Int => |i| blk: {
            const width: i64 = if (recv == .Int) 32 else 64;
            break :blk @intCast(@mod(i, width));
        },
        else => null,
    };
    if (shift) |s| {
        if (std.mem.eql(u8, nm, "shl")) return switch (recv) {
            .Int => |i| Value.newInt(@as(i32, @bitCast(@as(u32, @bitCast(i)) << @truncate(s)))),
            .Long => |l| .{ .Long = @bitCast(@as(u64, @bitCast(l)) << s) },
            else => unreachable,
        };
        if (std.mem.eql(u8, nm, "shr")) return switch (recv) {
            .Int => |i| Value.newInt(i >> @truncate(s)),
            .Long => |l| .{ .Long = l >> s },
            else => unreachable,
        };
        if (std.mem.eql(u8, nm, "ushr")) return switch (recv) {
            .Int => |i| Value.newInt(@as(i32, @bitCast(@as(u32, @bitCast(i)) >> @truncate(s)))),
            .Long => |l| .{ .Long = @bitCast(@as(u64, @bitCast(l)) >> s) },
            else => unreachable,
        };
    }
    // `and` / `or` / `xor` are same-width members: `Int.and(Int)` and
    // `Long.and(Long)`. A mixed pair is some other declaration.
    const pair: ?struct { a: i64, b: i64 } = switch (recv) {
        .Int => |i| if (arg == .Int) .{ .a = i, .b = arg.Int } else null,
        .Long => |l| if (arg == .Long) .{ .a = l, .b = arg.Long } else null,
        else => null,
    };
    const p = pair orelse return null;
    const wrap = struct {
        fn f(is_int: bool, v: i64) Value {
            return if (is_int) Value.newInt(@truncate(v)) else .{ .Long = v };
        }
    }.f;
    const is_int = recv == .Int;
    if (std.mem.eql(u8, nm, "and")) return wrap(is_int, p.a & p.b);
    if (std.mem.eql(u8, nm, "or")) return wrap(is_int, p.a | p.b);
    if (std.mem.eql(u8, nm, "xor")) return wrap(is_int, p.a ^ p.b);
    return null;
}

/// Whether this site may serve a NULL stored slot. Asked of the host once and
/// kept on the instruction: it is a property of the claiming class, which the
/// site memo has already pinned.
pub inline fn nullSiteOk(comptime H: type, host: *H, recv: *const Value, name: []const u8, slot: *u8) bool {
    const cached = @atomicLoad(u8, slot, .acquire);
    if (cached != 0) return cached == 2;
    const ok_now = host.storedNullServable(recv, name);
    @atomicStore(u8, slot, if (ok_now) @as(u8, 2) else 1, .release);
    return ok_now;
}

pub inline fn fastSubscript(allocator: Allocator, frame: *const Frame, cm: anytype) ?Value {
    if (cm.arg_names.len != 0 or cm.n_args == 0) return null;
    const nm = constStr(frame.module, cm.name) orelse return null;
    const is_get = cm.n_args == 1 and std.mem.eql(u8, nm, "get");
    const is_set = cm.n_args == 2 and std.mem.eql(u8, nm, "set");
    if (!is_get and !is_set) return null;
    const idx_v = frame.read(Reg.from(cm.args.int()));
    const recv = frame.read(cm.receiver);
    if (is_get) return fastIndexGet(&recv, &idx_v);
    const new_val = frame.read(Reg.from(cm.args.int() + 1));
    // The member-call form USES the expression value: Unit for an array,
    // the previous element for a list.
    return fastIndexSet(allocator, &recv, &idx_v, new_val);
}

/// Snapshot the live values of a `[]Reg`. Caller frees.
fn readRegSlice(allocator: Allocator, frame: *const Frame, regs: []const Reg) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, regs.len);
    for (regs, out) |r, *dst| dst.* = frame.read(r);
    return out;
}

/// Flatten an array / list / set into a slice of its items for
/// spread-arg dispatch. Caller frees the returned slice.
fn spreadItems(allocator: Allocator, v: *const Value) Allocator.Error!union(enum) { ok: []Value, err: EvalError } {
    switch (v.*) {
        .Array => |a| return .{ .ok = try a.snapshot(allocator) },
        .List, .Set => {
            const items_ref = switch (v.*) {
                .List => |l| l.items,
                .Set => |s| s.items,
                else => unreachable,
            };
            const g = items_ref.borrow();
            defer g.deinit();
            const src = g.get().items;
            return .{ .ok = try allocator.dupe(Value, src) };
        },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "spread argument: expected an array/list, got `{s}`", .{v.typeFqn()});
            return .{ .err = .{ .Type = msg } };
        },
    }
}

/// Resolve a per-call `arg_names: []?ConstId` into a parallel
/// `[]?[]const u8`. Empty input yields an empty output. Caller frees.
/// All-null name runs for the positional shape, which is the overwhelming
/// majority of calls: they carry no information beyond their length, so one
/// shared constant run serves every arity up to the bound and the per-call
/// allocation disappears. `freeArgNames` recognizes it and frees nothing.
const ARG_NAMES_NULL_MAX: usize = 32;
const arg_names_null: [ARG_NAMES_NULL_MAX]?[]const u8 = @splat(null);

pub fn resolveArgNames(allocator: Allocator, module: *const Module, names: []const ?ConstId) Allocator.Error![]?[]const u8 {
    if (names.len <= ARG_NAMES_NULL_MAX and argNamesAllNull(names)) {
        return @constCast(arg_names_null[0..names.len]);
    }
    const out = try allocator.alloc(?[]const u8, names.len);
    for (names, out) |opt, *dst| {
        dst.* = if (opt) |id| constStr(module, id) else null;
    }
    return out;
}

/// Release a run from `resolveArgNames`. The shared all-null run is static.
pub fn freeArgNames(allocator: Allocator, names: []?[]const u8) void {
    if (names.len != 0 and names.ptr == @constCast(&arg_names_null).ptr) return;
    allocator.free(names);
}

/// Heuristic for an erased generic type-parameter name (`T`, `R`, `E`,
/// `K`, `V`, `TT`, …): a one- or two-character all-uppercase
/// identifier.
fn isErasedTypeParamName(name: []const u8) bool {
    const n = std.mem.trimEnd(u8, name, "?");
    if (n.len == 0 or n.len > 2) return false;
    for (n) |c| {
        if (!(c >= 'A' and c <= 'Z')) return false;
    }
    return true;
}

/// Whether a non-`instance_of` cast still passes because the target is
/// an erased type parameter (unchecked cast on the JVM).
fn typeParamCastPasses(comptime H: type, frame: *const Frame, ty: TypeRef, host: *H) bool {
    return typeParamCastPassesIn(H, frame.module, frame.func, ty, host);
}

/// Frame-free core of `typeParamCastPasses`, shared with the fused walker's
/// Cast arm — the leniency for erased/type-parameter cast targets is part of
/// Cast semantics, not of having a frame.
pub fn typeParamCastPassesIn(comptime H: type, module: *const Module, func: *const ir.Func, ty: TypeRef, host: *H) bool {
    if (module.registry.func_type_params.get(func.id)) |tps| {
        for (tps.items) |t| {
            if (std.mem.eql(u8, t, ty.name)) return true;
        }
    }
    if (isErasedTypeParamName(ty.name)) return true;
    if (!host.isConcreteCastTarget(ty.name)) return true;
    return false;
}
