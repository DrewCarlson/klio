//! Call-shaped IR exec arms and the member/global dispatch route: the call arms,
//! the arms that build a receiver, the implicit-`this` and global load/store
//! arms, and `execCallMemberOrGlobal`, which decides whether a bare name is a
//! member on an implicit receiver, a companion member, a SAM invoke or a
//! top-level function. The shared argument readers and fast paths live here too.
//!
//! The frame register file, the activation and resume machinery, and the
//! evaluator's threadlocal state stay in `eval.zig`.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

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
const pushDispatch = eval.pushDispatch;
const pushEnclosingAccess = eval.pushEnclosingAccess;
const raiseStep = eval.raiseStep;
const takeHostFlatArm = eval.takeHostFlatArm;
const takeHostFlatReq = eval.takeHostFlatReq;
const vcallFlatEnabled = eval.vcallFlatEnabled;

/// Whether a flat request carries nothing beyond its callee and arguments, so
/// the call is reproducible from the call site alone.
fn leafPlainReq(req: FlatCallReq) bool {
    return req.captures.items.len == 0 and
        req.chain.len == 0 and
        req.closure_id == null and
        req.type_args.len == 0 and
        req.keepalive == null and
        req.typed_saved == null and
        req.pop_enclosing_n == 0 and
        req.scope_guard_ident == 0 and
        !req.composer_pushed and
        !req.suspend_barrier and
        !req.root_pump and
        req.owning == null;
}

/// The class of an instance that failed a cast, else its value tag, for the
/// throw trace.
pub fn castTraceLabel(v: *const Value) []const u8 {
    if (v.* == .Instance) {
        const g = v.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        return cg.get().fqn;
    }
    return @tagName(v.*);
}

pub fn envVarSet(name: []const u8) bool {
    return runtime.procEnvIsSet(std.heap.page_allocator, name);
}

pub fn constStr(module: *const Module, id: ConstId) ?[]const u8 {
    return switch (module.consts.items[id.int()]) {
        .String => |s| s,
        else => null,
    };
}

/// A callable reference (`Long::toByte`, `recv::method`) is a synth `Instance`
/// whose class name is `$bound_ref$<name>`, invocable with no `invoke` member.
fn isBoundRefInstance(v: *const Value) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.startsWith(u8, cg.get().name, "$bound_ref$");
}

/// `allow_flat = false` masks the flat-driver parks, forcing the recursive path.
/// A flat park unwinds a transpiled native body off the C stack on every call, so
/// the transpiler serves recursively until `NATIVE_RECURSE_MAX_DEPTH`.
const snapshot_fast = @import("snapshot_fast.zig");
const compose_fast = @import("compose_fast.zig");

/// Classify `f` for host service, memoized on `Func.host_route`, and serve `args`
/// on a routed hit.
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

var compose_fast_state: u8 = 0;
var compose_fast_mask: u8 = 255;

/// `KLIO_COMPOSE_FAST` is a bisect mask over the compose serves: bit0 the
/// stack/key helpers, bit1 the changelist push, bit2 its argument assertion, bit3
/// the write scope, bit4 the slot-table index math, bit5 the reader/writer/drain
/// family, bit6 the changelist wrapper, bit7 `Operations.push(op) { args }`.
fn composeFastMask() u8 {
    if (compose_fast_state == 0) {
        const raw = runtime.envOnce("KLIO_COMPOSE_FAST") orelse "255";
        compose_fast_mask = std.fmt.parseInt(u8, raw, 10) catch 255;
        compose_fast_state = 1;
    }
    return compose_fast_mask;
}

/// Serves that can RAISE, from the same seams as `hostRouteServe` but with the
/// full result channel. Null declines and the framed body runs.
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
                // The link-buffer push aggregates the op's visibility into
                // `requiresApplication`, so it rides its own serve, never the gap one.
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
            // `Operations.push(op) { args }` is `pushOp(op); WriteScope(this)
            // .args()`, whose BOXED receiver resolves `setObject` on the instance.
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
            // The op is already pushed, so nothing below may decline.
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
            // The parent's `observerHolder` is usually a computed null, so it
            // needs the host's getter ladder. The root arm is the pure serve's.
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

/// Host-served static fns: classify once per Func, serve without call machinery.
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
    // With a leaf library registered (`KLIO_LEAVES`) a pure scalar callee runs
    // as direct C; a bail is a no-op and the paths below re-run the call.
    if (try eval.tryLeafCall(H, allocator, frame, call, host, null)) |st| return st;
    // Monomorphic fast path: a single-overload non-extension top-level function
    // with a body and no varargs, defaults, type params or native binding.
    if (comptime @hasDecl(H, "callFuncFast")) {
        if (call.type_args.len != 0 or !argNamesAllNull(call.arg_names)) {
            dispatchBump(.static_decline_named);
        }
        if (call.type_args.len == 0 and argNamesAllNull(call.arg_names)) {
            if (frame.module.funcById(call.func)) |cf| {
                var plan = cf.fast_call;
                if (plan == 0) {
                    plan = host.fastCallPlan(frame.module, call.func);
                    @constCast(cf).fast_call = plan;
                }
                // The low bits carry the eligible arity plus 2.
                const plan_arity = plan & 0x1FFF;
                if (plan_arity < 2) {
                    dispatchBump(.static_decline_plan);
                    if (runtime.envOnce("KLIO_FASTPLAN_TRACE")) |w| {
                        if (w.len == 1 and w[0] == '*') std.debug.print("[fastplan-decline] {s}\n", .{cf.name});
                    }
                }
                // Same-name, same-arity peers: only this site's scope can say
                // whether the baked target is the one resolution picks.
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
                if (!ambig_ok) dispatchBump(.static_decline_ambig);
                if (ambig_ok and plan_arity >= 2 and plan_arity - 2 != call.n_args) dispatchBump(.static_decline_arity);
                if (ambig_ok and plan_arity >= 2 and plan_arity - 2 == call.n_args) {
                    // The caller's `this` seeds the enclosing receiver: lexical
                    // scope for a member extension, dispatch visibility else.
                    var pushed_enclosing = false;
                    if (plan & ir.FAST_CALL_EXT_FLAG != 0) {
                        if (frameThisParam(frame)) |ct_idx| {
                            const p = frame.params.items[ct_idx];
                            if (p == .Instance) {
                                const a0 = if (call.n_args > 0) frame.read(Reg.from(call.args.int())) else Value.Unit;
                                const same = a0 == .Instance and
                                    ObjRef(InstanceData).ptrEq(p.Instance, a0.Instance);
                                if (!same) {
                                    if (cf.kind == .member_extension) {
                                        // A member-extension caller forwards
                                        // its own dispatch receiver, not its
                                        // extension receiver.
                                        if (frame.func.kind == .member_extension and frame.dispatch_this != .Null)
                                            pushDispatch(&frame.dispatch_this)
                                        else
                                            pushDispatch(&frame.params.items[ct_idx]);
                                    } else {
                                        pushEnclosingAccess(&frame.params.items[ct_idx]);
                                    }
                                    pushed_enclosing = true;
                                }
                            }
                        }
                    }
                    if (plan & ir.FAST_CALL_EXT_FLAG != 0) dispatchBump(.static_flat_fuse_ext) else dispatchBump(.static_flat_fuse);
                    // A fully fusable callee runs from the caller's own register
                    // run: no carrier to acquire and release, no flat request, and
                    // no second pass through the activation seam to ask the same
                    // question. The values stay the caller's, reachable in its
                    // registers, exactly as the fused tier's own call arm borrows
                    // them. A decline here has run nothing, so the carrier path
                    // below still sees an untouched call.
                    // The verdict byte the activation seam already memoized on the
                    // callee: only a FULLY fusable body takes this path, so a
                    // callee that would decline pays one byte read rather than an
                    // argument copy and a round trip that ends in a decline. An
                    // unasked callee (0) goes the ordinary way and is classified
                    // there, so the memo is warm by its second call.
                    if (call.n_args <= FUSED_ARGV_MAX and cf.fuse_state == 1) {
                        var argv: [FUSED_ARGV_MAX]Value = undefined;
                        {
                            var ai: u32 = 0;
                            while (ai < call.n_args) : (ai += 1) {
                                argv[ai] = frame.read(Reg.from(call.args.int() + ai));
                            }
                            const av = argv[0..call.n_args];
                            const composer_pushed = if (comptime @hasDecl(H, "flatPlainCallOpen"))
                                host.flatPlainCallOpen(cf, av)
                            else
                                false;
                            // The close runs before the error is propagated, so a
                            // failure inside the body cannot leave the composer it
                            // published on the stack. On a decline it also balances
                            // the push before the carrier path makes its own.
                            const attempt = eval.fusedServeArgs(H, allocator, frame.module, cf, av, host);
                            if (composer_pushed) {
                                if (comptime @hasDecl(H, "flatCallClosed")) host.flatCallClosed();
                            }
                            const served = try attempt;
                            if (served) |res| {
                                if (pushed_enclosing) popEnclosing();
                                switch (res) {
                                    .ok => |v| try frame.write(call.dst, v),
                                    .err => |e| return raiseStep(frame, e),
                                }
                                return .cont;
                            }
                        }
                    }
                    const args_list = try readArgList(allocator, frame, call.args, call.n_args);
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

    // Undispatched start under an enclosing pump: a barrier activation parks a
    // suspension into the pump and this frame gets COROUTINE_SUSPENDED.
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

    // Kotlin resolves named calls by parameter name, so a sibling of the
    // lowerer's positional-arity FuncId may be the real target.
    var eff_func = call.func;
    if (!call.exact) {
        var any_named = false;
        for (names) |n| {
            if (n != null) any_named = true;
        }
        if (any_named) {
            // The implicit extension receiver is absent from `args` only when
            // the baked target is not itself an extension.
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
                        const recv = frame.params.items[ct_idx];
                        const na = try allocator.alloc(Value, arg_values.len + 1);
                        na[0] = recv;
                        @memcpy(na[1..], arg_values);
                        // The defers above free `arg_values`/`names`: free the
                        // originals before replacing the pointers.
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
                    // A member-extension's body has its declaring class's `this` in
                    // lexical scope; for a plain extension the push is visibility.
                    if (callee_fn.?.kind == .member_extension) {
                        if (frame.func.kind == .member_extension and frame.dispatch_this != .Null)
                            pushDispatch(&frame.dispatch_this)
                        else
                            pushDispatch(&frame.params.items[ct_idx]);
                    } else {
                        pushEnclosingAccess(&frame.params.items[ct_idx]);
                    }
                    pushed_enclosing = true;
                }
            }
        }
    }
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

pub noinline fn execArmCallValue(comptime H: type, allocator: Allocator, frame: *Frame, cv: anytype, host: *H) Allocator.Error!Step {
    dispatchBump(.call_value);
    const callee_v = frame.read(cv.callee);
    if (runtime.envOnce("KLIO_TRACE_PATH") != null) {
        if (callee_v == .IrClosure) {
            std.debug.print("[cv-callee] in={s} kind=IrClosure id={d}\n", .{ frame.func.name, callee_v.IrClosure.asPtr().id });
        } else {
            std.debug.print("[cv-callee] in={s} kind={s}\n", .{ frame.func.name, @tagName(std.meta.activeTag(callee_v)) });
        }
    }
    // The argument run and the resolved names are already owned slices; a
    // closure call is one of the hottest arms in a compose frame, so they are
    // passed through as they are and only copied for the receiver prepend.
    const args_run = try readArgRun(allocator, frame, cv.args, cv.n_args);
    defer allocator.free(args_run);
    const names_run = try resolveArgNames(allocator, frame.module, cv.arg_names);
    defer freeArgNames(allocator, names_run);
    var call_args: []const Value = args_run;
    var call_names: []const ?[]const u8 = names_run;
    var prepend_args: ?[]Value = null;
    var prepend_names: ?[]?[]const u8 = null;
    defer {
        if (prepend_args) |a| allocator.free(a);
        if (prepend_names) |n| allocator.free(n);
    }
    if (runtime.envOnce("KLIO_TRACE_PATH") != null) {
        for (call_args, 0..) |*av, ai| {
            std.debug.print("[cv-arg] in={s} #{d} kind={s}\n", .{ frame.func.name, ai, @tagName(std.meta.activeTag(av.*)) });
        }
    }
    const caller_this = callerThisValue(frame);
    if (host.callableReceiverShape(&callee_v)) |shape| {
        if (shape.first_is_this and call_args.len + 1 == shape.n_params) {
            if (caller_this) |ct| {
                const a = try allocator.alloc(Value, call_args.len + 1);
                prepend_args = a;
                a[0] = ct;
                @memcpy(a[1..], call_args);
                call_args = a;
                const n = try allocator.alloc(?[]const u8, call_names.len + 1);
                prepend_names = n;
                n[0] = null;
                @memcpy(n[1..], call_names);
                call_names = n;
            }
        }
    }
    if (host.closureNeedsThisCapture(&callee_v)) {
        if (caller_this) |ct| {
            host.overrideClosureThis(&callee_v, &ct);
        }
    }
    // No caller-`this` push: a closure's body resolves bare names against its
    // creation-time receiver chain, which the dynamic caller's `this` is not on.
    if (comptime @hasDecl(H, "prepareClosureFlatCall")) {
        if (flatEnabled() and callee_v == .IrClosure and cv.type_args.len == 0 and argNamesAllNull(cv.arg_names)) {
            if (try host.prepareClosureFlatCall(allocator, &callee_v, call_args)) |prep0| {
                var prep = prep0;
                prep.dst = cv.dst;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    const result = blk: {
        // Call-site type args reach the host so an unsigned element type
        // coerces integral literals before the intrinsic (`arrayOf<ULong>(1u)`).
        if (cv.type_args.len != 0) {
            var ta_buf: [4][]const u8 = undefined;
            const n_ta = @min(cv.type_args.len, ta_buf.len);
            for (cv.type_args[0..n_ta], ta_buf[0..n_ta]) |cid, *slot| {
                slot.* = constStr(frame.module, cid) orelse "";
            }
            break :blk host.callValueNamedTyped(allocator, &callee_v, call_args, call_names, ta_buf[0..n_ta]);
        }
        break :blk host.callValueNamed(allocator, &callee_v, call_args, call_names);
    };
    switch (try result) {
        .ok => |rv| {
            var out = rv;
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
        // Pin the borrowed receiver: the body may drop other references.
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

/// Execute a statically selected virtual slot. Unlike `CallMember` this arm has
/// no name-based fallback: a missing slot is a link error the host reports.
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
    if (comptime @hasDecl(H, "prepareVirtualFlatCall")) {
        if (flatEnabled() and vcallFlatEnabled() and cv.x().arg_params == null and argNamesAllNull(cv.x().arg_names)) {
            if (try host.prepareVirtualFlatCall(allocator, &recv, cv.slot, args)) |prep0| {
                dispatchBump(.virtual_flat_prepare);
                var prep = prep0;
                prep.dst = cv.dst;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    const names = try resolveArgNames(allocator, frame.module, cv.x().arg_names);
    defer freeArgNames(allocator, names);
    const prev_tl = if (cv.x().trailing_lambda and comptime @hasDecl(H, "setTrailingMemberCall"))
        H.setTrailingMemberCall(true)
    else
        false;
    // Only a plain positional call may stamp or replay the site memo, whose
    // memoized direct dispatch binds positionally.
    const site: ?ir.VirtNativeSite = if (cv.x().arg_params == null and argNamesAllNull(cv.x().arg_names))
        .{
            .cls = @constCast(&cv.site_cls),
            .native = @constCast(&cv.site_native),
            .name_ptr = @constCast(&cv.site_name_ptr),
            .name_len = @constCast(&cv.site_name_len),
        }
    else
        null;
    const result = host.invokeVirtualMember(allocator, &recv, cv.slot, args, names, cv.x().arg_params, site);
    if (cv.x().trailing_lambda) {
        if (comptime @hasDecl(H, "setTrailingMemberCall")) _ = H.setTrailingMemberCall(prev_tl);
    }
    switch (try result) {
        .ok => |value| try frame.write(cv.dst, value),
        .err => |err| return raiseStep(frame, err),
    }
    return .cont;
}

pub noinline fn execArmCallMemberOrValue(comptime H: type, allocator: Allocator, frame: *Frame, cmv: anytype, host: *H) Allocator.Error!Step {
    const or_prev = orSiteEnter(frame, cmv.name);
    defer or_site = or_prev;
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
    // A boxed capture holds the callable in a cell; classify the CONTENT.
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
    // The fallback wins only when the receiver has no such member and the
    // fallback is invocable: a non-callable local never shadows a real member.
    const fb_invocable = switch (fb) {
        .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
        // A class value is its constructor (`::Char` bound to an
        // `Int.() -> Char` param); the receiver becomes its first argument.
        .Class => true,
        // A callable reference is invocable, so `recv.refParam()` invokes it
        // with `recv` as receiver rather than dispatching a member.
        .Instance => isBoundRefInstance(&fb) or host.hostHasMember(&fb, "invoke") or host.callableReceiverShape(&fb) != null,
        else => false,
    };
    // A local callable whose declared arity provably cannot take the supplied
    // args is not the primary candidate; Kotlin resolves the member instead.
    const fb_misfit = fb_invocable and
        (host.callableAcceptsCall(&fb, &recv, user_args, names) orelse true) == false;
    // A receiver whose STATIC type is an unbounded type parameter has no members
    // to shadow the local: Kotlin compiles the body against the bound (`Any?`).
    const members_visible = !cmv.recv_erased and host.hostHasMember(&recv, name_str);
    if (fb_invocable and (!fb_misfit or cmv.recv_erased) and !members_visible) {
        orAudit("CallMemberOrValue", name_str, "value", -1, &recv);
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
            // Constructors take no receiver: `65.f()` with `f = ::Char` is
            // `Char(65)`.
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
            std.mem.find(u8, r.err.Unimplemented, "Vm::") != null;
        // The member exists by name but no overload serves this call, so Kotlin
        // resolves to the same-named invocable local instead.
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

/// Whether a value can serve as a callee: closures, function references,
/// intrinsics, classes, bound references, and instances declaring `invoke`.
fn valueInvocable(module: *const Module, callee_v: Value) bool {
    return switch (callee_v) {
        .Intrinsic, .IrClosure, .BoundMethod => true,
        // A class value invoked bare is a constructor call.
        .Class, .PropertyRef => true,
        .Instance => |i| blk: {
            {
                const g = i.borrow();
                defer g.deinit();
                // A bound reference synth (`val lit = Expr::Lit`) is callable.
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

pub noinline fn execArmCallValueOrMember(comptime H: type, allocator: Allocator, frame: *Frame, cvm: anytype, host: *H) Allocator.Error!Step {
    const or_prev = orSiteEnter(frame, cvm.name);
    defer or_site = or_prev;
    dispatchBump(.call_value_or_member);
    var callee_v = frame.read(cvm.callee);
    // A boxed capture holds the callable in a cell; classify the CONTENT.
    if (callee_v == .Cell) {
        const cg = callee_v.Cell.borrow();
        callee_v = cg.get().*;
        cg.deinit();
    }
    const arg_values = try readArgRun(allocator, frame, cvm.args, cvm.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cvm.arg_names);
    defer freeArgNames(allocator, names);
    var invocable = valueInvocable(frame.module, callee_v);
    // A runtime-registered class extending a function type keeps its `invoke`
    // outside the module registry; the gate is the function-type supertype.
    if (!invocable and callee_v == .Instance) {
        if (comptime @hasDecl(H, "instanceExtendsFunctionType")) {
            invocable = host.instanceExtendsFunctionType(&callee_v);
        }
    }
    // A callable whose declared params refute the runtime args is not the
    // target: Kotlin resolved the call to the same-named enclosing member.
    const refuted = invocable and (comptime @hasDecl(H, "closureParamsDisproven")) and
        host.closureParamsDisproven(&callee_v, arg_values);
    if (invocable and !refuted) {
        if (orAuditOn()) {
            const name_str = constStr(frame.module, cvm.name) orelse "?";
            orAudit("CallValueOrMember", name_str, "value", -1, null);
        }
        const recv_ctx = frame.read(cvm.this_recv);
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
        // A non-callable capture is not a resolution candidate in Kotlin, so the
        // innermost receiver's canonical miss walks the outer receivers.
        if (r == .err and r.err == .Unimplemented and
            std.mem.find(u8, r.err.Unimplemented, "Vm::call_member") != null)
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
                    std.mem.find(u8, r2.err.Unimplemented, "Vm::call_member") != null)
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

pub noinline fn execArmNewInstance(comptime H: type, allocator: Allocator, frame: *Frame, ni: anytype, host: *H) Allocator.Error!Step {
    const arg_values = try readArgRun(allocator, frame, ni.args, ni.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, ni.arg_names);
    defer freeArgNames(allocator, names);
    // A bare `Inner(args)` inside a member of the enclosing class is
    // `this@Outer.Inner(args)`, so the frame's own `this` is the outer hint.
    var outer_hint: ?Value = callerThisValue(frame);
    const hint_ptr: ?*const Value = if (outer_hint) |*h| h else null;
    // Kotlin selects the constructor overload from the arguments' STATIC types.
    // The host consumes the heads once, so a nested construction ranks on its own.
    const static_heads = try resolveArgNames(allocator, frame.module, ni.arg_static_heads);
    defer freeArgNames(allocator, static_heads);
    if (comptime @hasDecl(H, "setCtorArgStaticHeads")) {
        host.setCtorArgStaticHeads(static_heads);
    }
    // The constructor lowering named for this site, travelling the same way
    // the heads do and consumed by the same construction.
    if (comptime @hasDecl(H, "setCtorSitePick")) {
        host.setCtorSitePick(if (ni.ctor_pick == ir.CTOR_PICK_NONE) null else ni.ctor_pick, ni.n_args);
    }
    // Cleared on every exit: the slice above is freed, and no construction path
    // may leave this thread pointing at it.
    defer if (comptime @hasDecl(H, "clearCtorArgStaticHeads")) host.clearCtorArgStaticHeads();
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
            // `outer` is an owned field and `outer_hint` a caller borrow, so
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

pub noinline fn execArmInstanceOf(comptime H: type, allocator: Allocator, frame: *Frame, io: anytype, host: *H) Allocator.Error!Step {
    _ = allocator;
    const v = frame.read(io.src);
    // The site named the class, so the question is whether the receiver's own
    // class is at or below it — an id comparison against a sorted ancestor
    // list. Only an interpreted instance can answer it: a host-backed value
    // carries no module class, and a wrong `false` there is a wrong answer,
    // so those fall to the walk.
    if (io.cls) |want| serve: {
        if (v == .Instance and isCheckServeOn()) {
            if (instanceClassId(frame, v.Instance)) |have| {
                // Null where this module never built a closure for the class:
                // answering `false` from an absent table would say "not a
                // subtype" about every class the program has.
                const is_by_id = frame.module.classIsAKnown(have, want) orelse
                    break :serve;
                if (isCheckAuditOn()) {
                    const walked = host.instanceOf(&v, io.ty);
                    if (walked != is_by_id) {
                        const g = v.Instance.borrow();
                        defer g.deinit();
                        const cg = g.get().class.borrow();
                        defer cg.deinit();
                        const anc: usize = if (have.int() < frame.module.class_ancestors.items.len)
                            frame.module.class_ancestors.items[have.int()].len
                        else
                            0;
                        const sups: usize = if (have.int() < frame.module.classes.items.len)
                            frame.module.classes.items[have.int()].supertypes.len
                        else
                            0;
                        const c2 = &frame.module.classes.items[have.int()];
                        std.debug.print("[ischeck-audit] {s} is {s}: id={} walk={} have={d} want={d} anc={d} sups={d} refs={d} ref0={s} rtparent={s}\n", .{
                            cg.get().fqn,       io.ty.name, is_by_id,          walked,
                            have.int(),         want.int(), anc,               sups,
                            c2.supertype_refs.len,
                            if (c2.supertype_refs.len != 0) c2.supertype_refs[0].name else "-",
                            if (cg.get().supertype_names.len != 0) cg.get().supertype_names[0] else "-",
                        });
                    }
                }
                dispatchBump(.type_instanceof_class);
                try frame.write(io.dst, .{ .Bool = is_by_id });
                return .cont;
            }
        }
    }
    const is = host.instanceOf(&v, io.ty);
    try frame.write(io.dst, .{ .Bool = is });
    return .cont;
}

/// `KLIO_ISCHECK_SERVE=0` leaves the named class untested so a wrong answer
/// can be told from a wrong naming; `audit` walks by name as well and reports
/// every test where the two disagree.
var ischeck_serve_state: u8 = 0;
fn isCheckServeOn() bool {
    if (ischeck_serve_state == 0) {
        const val = runtime.envOnce("KLIO_ISCHECK_SERVE") orelse "1";
        ischeck_serve_state = if (std.mem.eql(u8, val, "0"))
            1
        else if (std.mem.eql(u8, val, "audit"))
            3
        else
            2;
    }
    return ischeck_serve_state != 1;
}

fn isCheckAuditOn() bool {
    _ = isCheckServeOn();
    return ischeck_serve_state == 3;
}

/// `KLIO_BUILTIN_AUDIT=1`: report every site the link pass called proven that
/// still reached the by-name walk. The bit is what lets the census count such
/// a site resolved, so it has to be checked against what runs.
var builtin_audit_state: u8 = 0;
pub fn builtinProvenAuditOn() bool {
    if (builtin_audit_state == 0) {
        builtin_audit_state = if (runtime.envOnce("KLIO_BUILTIN_AUDIT") != null) 2 else 1;
    }
    return builtin_audit_state == 2;
}

/// `KLIO_CAST_SERVE=0` leaves the named class untested; `audit` walks by name
/// as well and reports every cast the id served that the walk would refuse.
var cast_serve_state: u8 = 0;
fn castServeOn() bool {
    if (cast_serve_state == 0) {
        const val = runtime.envOnce("KLIO_CAST_SERVE") orelse "1";
        cast_serve_state = if (std.mem.eql(u8, val, "0"))
            1
        else if (std.mem.eql(u8, val, "audit"))
            3
        else
            2;
    }
    return cast_serve_state != 1;
}

fn castAuditOn() bool {
    _ = castServeOn();
    return cast_serve_state == 3;
}

/// The module `ClassId` behind an instance's runtime class, through the def's
/// own memo so the string-keyed probe runs once per class.
fn instanceClassId(frame: *Frame, inst: runtime.ObjRef(runtime.InstanceData)) ?ir.ClassId {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const cdef = cg.get();
    const mod_key = @intFromPtr(frame.module);
    if (cdef.resolve_mod.load(.monotonic) == mod_key) {
        const plus1 = cdef.resolve_cid.load(.acquire);
        if (plus1 != 0) return ir.ClassId.from(plus1 - 1);
    }
    const found = frame.module.classIdByFqn(cdef.fqn) orelse return null;
    const mut = @constCast(cdef);
    if (mut.resolve_mod.cmpxchgStrong(0, mod_key, .acq_rel, .monotonic) == null) {
        mut.resolve_cid.store(found.int() + 1, .release);
    }
    return found;
}

pub noinline fn execArmCast(comptime H: type, allocator: Allocator, frame: *Frame, cast: anytype, host: *H) Allocator.Error!Step {
    const v = frame.read(cast.src);
    // A resolved cast answers the positive only. Where the value's class is at
    // or below the one the site names, the cast succeeds and the by-name walk
    // has nothing to add. Everything else falls through to it: a false, a
    // module with no closure for the class, a value carrying no module class.
    // Every path that can throw is down there, so a missing ancestor edge can
    // cost the serve but can never turn a passing cast into a raise.
    if (cast.cls()) |want| serve: {
        if (v != .Instance or !castServeOn()) break :serve;
        const have = instanceClassId(frame, v.Instance) orelse break :serve;
        if (frame.module.classIsAKnown(have, want) != true) break :serve;
        if (castAuditOn() and !host.instanceOf(&v, cast.ty)) {
            const g = v.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            std.debug.print("[cast-audit] {s} as {s}: id=true walk=false have={d} want={d}\n", .{
                cg.get().fqn, cast.ty.name, have.int(), want.int(),
            });
        }
        dispatchBump(.type_cast_class);
        v.retain();
        try frame.write(cast.dst, v);
        return .cont;
    }
    if (host.instanceOf(&v, cast.ty)) {
        v.retain();
        try frame.write(cast.dst, v);
    } else if (typeParamCastPasses(H, frame, cast.ty, host)) {
        v.retain();
        try frame.write(cast.dst, v);
    } else if (v == .Null and !cast.ty.nullable and !cast.safe) {
        // `null as T` for a concrete non-null `T` is a NullPointerException,
        // not a ClassCastException (an erased parameter passed above).
        const exc = try Value.newException(allocator, .{
            .fqn = try runtime.strInit(allocator, "kotlin.NullPointerException"),
            .message = .from(try runtime.strInit(allocator, "null cannot be cast to non-null type")),
            .cause = null,
        });
        return raiseStep(frame, .{ .Throw = exc });
    } else if (cast.safe) {
        try frame.write(cast.dst, .Null);
    } else {
        // A failed cast raises without passing through the `Throw` terminator,
        // so KLIO_THROW_TRACE needs its own trace here.
        if (envVarSet("KLIO_THROW_TRACE")) {
            std.debug.print("[throw-trace] from fn {s} (fqn={s}): ClassCastException cast to {s} (value {s})\n", .{ frame.func.name, frame.func.fqn, cast.ty.name, castTraceLabel(&v) });
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

pub noinline fn execArmLambda(comptime H: type, allocator: Allocator, frame: *Frame, lam: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, lam.captures);
    defer allocator.free(cap_values);
    switch (try host.buildClosure(allocator, frame.module, lam.body_func, cap_values)) {
        .ok => |v| try frame.write(lam.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

pub noinline fn execArmStoreToThisOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, stg: anytype, host: *H) Allocator.Error!Step {
    const or_prev = orSiteEnter(frame, stg.name);
    defer or_site = or_prev;
    dispatchBump(.store_this_or_global);
    const name_str = constStr(frame.module, stg.name) orelse
        return raiseStep(frame, .{ .Type = "StoreToThisOrGlobal: name not a string const" });
    const v = frame.read(stg.value);
    // Kotlin scoping for a bare-name write mirrors the read side: the innermost
    // implicit receiver owning a PROPERTY of this name takes it, and only with no
    // such receiver does it land on the top-level binding.
    var routed = false;
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
        // `consult_param = true`: the written property's receiver may be the
        // frame's `this` PARAMETER, and a bare write also binds a setter.
        var cands_l = try implicitCandidatesAlloc(H, allocator, frame, stg.this_idx, true, host, name_str, null);
        defer releaseCands(allocator, &cands_l);
        const cands = cands_l.items;
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        // Mirroring the read side: a captured enclosing local takes the write over
        // any non-OWN receiver's property, writing through the capture's Cell.
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

pub noinline fn execArmLoadFromThisOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, lt: anytype, host: *H) Allocator.Error!Step {
    const or_prev = orSiteEnter(frame, lt.name);
    defer or_site = or_prev;
    dispatchBump(.load_this_or_global);
    const name_str = constStr(frame.module, lt.name) orelse
        return raiseStep(frame, .{ .Type = "LoadFromThisOrGlobal: name not a string const" });
    var resolved: ?Value = null;
    {
        // `consult_param = true`: in a method or extension body the implicit
        // receiver is the frame's `this` PARAMETER, not a capture slot.
        runtime.prof.opRoute(11);
        var cands_l = try implicitCandidatesAlloc(H, allocator, frame, lt.this_idx, true, host, stripScopeGetter(name_str), null);
        defer releaseCands(allocator, &cands_l);
        const cands = cands_l.items;
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        // Per-candidate probes are member-only: a candidate must not resolve a
        // global or an outer receiver's member and shadow a receiver further out.
        // A member's presence is a function of the class graph and stored field
        // set, both folded into the shape word, so an equal shape still misses.
        runtime.prof.opRoute(12);
        // Kotlin lexical scoping: a captured enclosing local is a NEARER binding
        // than any implicit receiver's EXTENSION property, but a real member is
        // nearer still, so the walk is skipped only when no class declares it.
        var capture_shadows = false;
        if (comptime @hasDecl(H, "scopedLocalBinds") and @hasDecl(H, "hostHasMember")) {
            const bare0 = stripScopeGetter(name_str);
            if (host.scopedLocalBinds(bare0)) {
                capture_shadows = true;
                for (cands) |c| {
                    // Only the OWN receiver run's members outrank the capture:
                    // its class body encloses the captured local's scope.
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
            // Kotlin's lexical rule: an outer receiver's MEMBER outranks an inner
            // receiver's IMPORTED extension property. Pass 0 probes members.
            var pass: u8 = 0;
            walk: while (pass < 2) : (pass += 1) {
                for (cands, 0..) |c, ci| {
                    if (missTraceWant()) |w| if (std.mem.eql(u8, w, name_str)) {
                        std.debug.print("[ltg-cand] name={s} pass={d} ci={d} depth={d} tag={s} in_fn={s}\n", .{ name_str, pass, ci, c.depth, @tagName(std.meta.activeTag(c.v)), frame.func.name });
                    };
                    switch (try (if (pass == 0)
                        host.getMemberFieldNoExt(allocator, &c.v, name_str)
                    else
                        host.getMemberField(allocator, &c.v, name_str))) {
                        .ok => |v| {
                            orAudit("LoadFromThisOrGlobal", name_str, "member", c.depth, &c.v);
                            resolved = v;
                            winner = ci;
                            break :walk;
                        },
                        // Only `Unimplemented` means this candidate has no such member;
                        // any other error came from an accessor that RAN.
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
            // The enum's static scope encloses its companion, nested objects
            // and entry bodies: a bare entry name read there is the entry.
            if (resolved == null and comptime @hasDecl(H, "enclosingEnumEntry")) {
                for (cands) |c| {
                    if (host.enclosingEnumEntry(&c.v, stripScopeGetter(name_str))) |ev| {
                        if (runtime.reclaimEnabled()) ev.retain();
                        orAudit("LoadFromThisOrGlobal", name_str, "enum_entry", c.depth, &c.v);
                        resolved = ev;
                        break;
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
    runtime.prof.opRoute(13);
    const bare_name = stripScopeGetter(name_str);
    // A lowering-resolved identity binds that exact declaration; a
    // runtime-scoped shadowing capture outranks it, as on the call form.
    const by_id: ?Value = if (resolved == null and (lt.func != null or lt.class != null) and
        !host.isShadowingCapture(bare_name))
        host.lookupGlobalById(allocator, lt.func, lt.class, false, false)
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
                    // A top-level `val` with only a custom getter has no global
                    // binding, so re-run its 0-arg getter.
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
                    // A read lowered inside an enum's entry body, companion or
                    // nested object reaches the enum's entries with no live receiver.
                    if (comptime @hasDecl(H, "enclosingEnumEntryByOwner")) {
                        if (scopeGetterOwner(constStr(frame.module, lt.name) orelse bare_name)) |owner| {
                            if (host.enclosingEnumEntryByOwner(owner, bare_name)) |ev| {
                                if (runtime.reclaimEnabled()) ev.retain();
                                orAudit("LoadFromThisOrGlobal", bare_name, "enum_entry_owner", -1, null);
                                try frame.write(lt.dst, ev);
                                return .cont;
                            }
                        }
                    }
                    // The scope-qualified read's lexical-owner premise can be wrong
                    // for a lambda in a companion or static context.
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
                    // A scope-qualified read of a MEMBER-EXTENSION property binds TWO
                    // receivers: the owner dispatches, `this` is the innermost fit.
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
                                pushDispatch(&c3.v);
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
                    // A member of an enclosing class's companion, or an inherited
                    // one, read from a nested class's body.
                    if (comptime @hasDecl(H, "enclosingCompanionMember")) {
                        var cands5_l = try implicitCandidatesAlloc(H, allocator, frame, lt.this_idx, true, host, bare_name, null);
                        defer releaseCands(allocator, &cands5_l);
                        const ka5 = pinImplicitCandidates(cands5_l.items);
                        defer runtime.keepaliveRestore(ka5);
                        for (cands5_l.items) |c5| {
                            if (c5.v != .Instance) continue;
                            if (try host.enclosingCompanionMember(allocator, &c5.v, bare_name, null)) |r5| {
                                switch (r5) {
                                    .ok => |v5| {
                                        orAudit("LoadFromThisOrGlobal", bare_name, "enclosing_companion", c5.depth, &c5.v);
                                        try frame.write(lt.dst, v5);
                                        return .cont;
                                    },
                                    .err => |e5| return raiseStep(frame, e5),
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
    // A boxed capture surfaced by the member walk reads through its cell.
    if (v == .Cell) {
        const cg = v.Cell.borrow();
        v = cg.get().*;
        cg.deinit();
    }
    v.retain();
    try frame.write(lt.dst, v);
    return .cont;
}

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

pub noinline fn execArmIndexSet(comptime H: type, allocator: Allocator, frame: *Frame, ixs: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(ixs.receiver);
    const i = frame.read(ixs.index);
    const v = frame.read(ixs.value);
    if (fastIndexSet(allocator, &recv, &i, v)) |expr_val| {
        // A List's returned PREVIOUS element carries ownership, and the
        // assignment form discards it.
        if (runtime.reclaimEnabled()) expr_val.release(allocator);
        return .cont;
    }
    switch (try host.callMember(allocator, &recv, "set", &.{ i, v })) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

pub noinline fn execArmNewList(comptime H: type, allocator: Allocator, frame: *Frame, nl: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const items = try readArgRun(allocator, frame, nl.args, nl.n_args);
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(allocator, items);
    allocator.free(items);
    // The list owns one reference to each element, and `readArgRun` handed back
    // borrows of the source registers. No-op under the arena fast path.
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    try frame.write(nl.dst, try Value.newList(allocator, .{
        .items = try ValueList.init(allocator, list),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
    return .cont;
}

pub noinline fn execArmQualifiedThis(comptime H: type, allocator: Allocator, frame: *Frame, qt: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(qt.receiver);
    const qual_str = constStr(frame.module, qt.qualifier) orelse
        return raiseStep(frame, .{ .Type = "QualifiedThis: qualifier not a string const" });
    switch (try host.qualifiedThis(allocator, &recv, qual_str)) {
        .ok => |v| {
            v.retain();
            try frame.write(qt.dst, v);
        },
        .err => |e| {
            if (!qt.soft) return raiseStep(frame, e);
            try frame.write(qt.dst, .Null);
        },
    }
    return .cont;
}

/// The frame's dispatch receiver. A caller that bound the call statically
/// handed it over as a `dispatch` chain entry; a by-name caller derived it
/// from the chain before the call and handed over the same. Neither having
/// run, the frame derives it once from its own chain, which is what every
/// by-name arm inside the body did per read, and says so under
/// `KLIO_DISPATCH_TRACE`.
pub noinline fn execArmLoadDispatchThis(comptime H: type, allocator: Allocator, frame: *Frame, ld: anytype, host: *H) Allocator.Error!Step {
    if (frame.dispatch_this == .Null) {
        if (comptime @hasDecl(H, "memberExtOwnerInstanceFor")) {
            if (try host.memberExtOwnerInstanceFor(allocator, frame.module, frame.func, frame.params.items)) |v| frame.dispatch_this = v;
        }
        if (runtime.envOnce("KLIO_DISPATCH_TRACE") != null) {
            std.debug.print("[dispatch-fallback] fn={s} found={}\n", .{ frame.func.fqn, frame.dispatch_this != .Null });
        }
    }
    const v = frame.dispatch_this;
    if (v == .Null) return raiseStep(frame, .{ .Type = "member extension frame has no dispatch receiver" });
    v.retain();
    try frame.write(ld.dst, v);
    return .cont;
}

/// The outer instance of the inner-class instance at `src`: the instance the
/// constructing frame's `this` was, linked at construction.
pub noinline fn execArmLoadOuterThis(comptime H: type, allocator: Allocator, frame: *Frame, lo: anytype, host: *H) Allocator.Error!Step {
    _ = allocator;
    _ = host;
    const v = frame.read(lo.src);
    const outer: ?Value = switch (v) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            break :blk g.get().outer;
        },
        else => null,
    };
    const o = outer orelse return raiseStep(frame, .{ .Type = "inner class instance has no outer instance" });
    if (o == .Null or o == .Unit) return raiseStep(frame, .{ .Type = "inner class instance has no outer instance" });
    o.retain();
    try frame.write(lo.dst, o);
    return .cont;
}

/// The frame's `idx`th context parameter. A caller that bound the call
/// statically handed the values over as `context` chain entries; a frame no
/// caller served derives the value once from its chain by the declared type,
/// the innermost receiver or context value that is one, which is what every
/// by-name arm inside the body did per read.
pub noinline fn execArmLoadContextParam(comptime H: type, allocator: Allocator, frame: *Frame, lc: anytype, host: *H) Allocator.Error!Step {
    if (lc.idx < frame.ctx_values.items.len) {
        const v = frame.ctx_values.items[lc.idx];
        v.retain();
        try frame.write(lc.dst, v);
        return .cont;
    }
    const types = frame.func.x().ctx_types;
    const ty_name: []const u8 = if (lc.idx < types.len) types[lc.idx] else "";
    if (comptime @hasDecl(H, "contextValueOfType")) {
        if (try host.contextValueOfType(allocator, ty_name)) |v| {
            if (runtime.envOnce("KLIO_DISPATCH_TRACE") != null) {
                std.debug.print("[context-fallback] fn={s} idx={d} ty={s} found=true\n", .{ frame.func.fqn, lc.idx, ty_name });
            }
            v.retain();
            try frame.write(lc.dst, v);
            return .cont;
        }
    }
    if (runtime.envOnce("KLIO_DISPATCH_TRACE") != null) {
        std.debug.print("[context-fallback] fn={s} idx={d} ty={s} found=false\n", .{ frame.func.fqn, lc.idx, ty_name });
    }
    return raiseStep(frame, .{ .Type = "contextual frame has no context value in scope" });
}

pub noinline fn execArmPropertyRef(comptime H: type, allocator: Allocator, frame: *Frame, pr: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const name_str = constStr(frame.module, pr.name) orelse
        return raiseStep(frame, .{ .Type = "PropertyRef: name not a string const" });
    try frame.write(pr.dst, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name_str) } });
    return .cont;
}

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
        .ok => |v| {
            if (comptime @hasDecl(H, "stampRefAdaptation")) {
                if (mr.adapt_arity >= 0) {
                    const heads: ?[]const u8 = if (mr.adapt_heads) |hc| constStr(frame.module, hc) else null;
                    try host.stampRefAdaptation(allocator, &v, name_str, mr.func, mr.adapt_arity, mr.adapt_unit, heads);
                }
            }
            try frame.write(mr.dst, v);
        },
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Free a discarded member-dispatch-miss message. The host allocPrints a
/// `Vm::`-prefixed string on a miss; a static literal never carries that prefix.
pub fn freeDispatchMissMsg(allocator: Allocator, msg: []const u8) void {
    if (!runtime.freeScratch()) return;
    if (std.mem.startsWith(u8, msg, "Vm::")) allocator.free(msg);
}

/// Free a discarded host dispatch-miss `EvalError`. Only the `Unimplemented`
/// arm carries an owned message.
fn freeMissErr(allocator: Allocator, e: EvalError) void {
    if (e == .Unimplemented) freeDispatchMissMsg(allocator, e.Unimplemented);
}

/// `name(args)` where lowering could not classify the bare callee as
/// member-vs-global. Mirrors Kotlin's resolution for an implicit receiver: the
/// candidates innermost-first, members then extensions, then the global tiers.
pub fn execCallMemberOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, cmg: anytype, host: *H) Allocator.Error!Step {
    const or_prev = orSiteEnter(frame, cmg.name);
    defer or_site = or_prev;
    const go_prev = or_global_only;
    const gn_prev = or_global_only_name;
    const gf_prev = or_global_only_func;
    or_global_only = cmg.global_only;
    or_global_only_name = constStr(frame.module, cmg.name) orelse "";
    or_global_only_func = if (cmg.func) |fid| fid.int() else 0xFFFF_FFFF;
    defer {
        or_global_only = go_prev;
        or_global_only_name = gn_prev;
        or_global_only_func = gf_prev;
    }
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
    // A direct splice receiver is the innermost implicit receiver when present;
    // otherwise the lambda capture slot, or the enclosing `this` PARAMETER.
    const direct_this: ?Value = if (cmg.recv) |r| frame.read(r) else null;
    const this_val = if (direct_this) |dt| dt else implicitThisValue(frame, cmg.this_idx, true);
    // A lowering-committed inline instance method with inferred reified type args
    // binds the stamped names as globals for the call, then walks members normally.
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
    // Kotlin has no capitalization rule and DSL-style functions are capitalized,
    // so an uppercase bare callee skips the member passes only when it is a class.
    var is_ctor_name = name_str.len > 0 and std.ascii.isUpper(name_str[0]) and
        cmg.class != null;
    // Kotlin filters by applicability before scope rank, so an inapplicable
    // constructor is no candidate at all and the walk runs.
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
    // nearer-scope member call; the constructor stays the fallback.
    if (is_ctor_name and this_val != .Null and this_val != .Unit) refine: {
        // The nearest receiver carrying the member may sit deeper than `this`.
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
                const nm: []const u8 = if (cvi < frame.func.x().capture_order.len) frame.func.x().capture_order[cvi] else "?";
                std.debug.print("[cmg-cap] [{d}] {s} = {s} {s}\n", .{ cvi, nm, @tagName(std.meta.activeTag(cv)), cn });
            }
        }
    }
    if (routeTraceOn(name_str)) std.debug.print("[cmgsec] enter frame={s}\n", .{frame.func.fqn});
    var committed_ext_h: ?FuncId = null;
    var committed_recv_h: ?Value = null;
    var resolved: ?Value = null;
    var first_real_err: ?EvalError = null;
    // A bare name bound to a captured callable in the innermost scoped-global
    // layer shadows a same-named member, but a genuine member still wins.
    const shadow_capture = host.isShadowingCapture(name_str) and
        ((this_val == .Null or this_val == .Unit) or !host.hostHasMember(&this_val, name_str));

    const func_p = @intFromPtr(frame.func);
    const cmg_skip = comptime @hasDecl(H, "cmgGlobalSkip");
    // A prior call from this site with this receiver class that resolved to a
    // global skips the member passes; the site memo answers with a u64 compare.
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
        // Call-site evidence PINNED the overload: a genuine member still shadows,
        // but the extension-fallback re-rank must not run past the pin.
        (cmg.func_final and !is_ctor_name and
            ((this_val == .Null or this_val == .Unit) or !host.hostHasMember(&this_val, name_str)));
    // The link pass proved no receiver in scope can answer the name, so the
    // member walk is a longer route to the declaration the site already
    // names. `KLIO_XORY_SERVE=0` withdraws the serve and leaves the walk.
    if (cmg.global_only and !is_ctor_name and xoryServeOn()) go: {
        const gf = cmg.func orelse break :go;
        const gfd = frame.module.funcById(gf) orelse break :go;
        // An extension needs its receiver prepended, which the global leg
        // cannot do; the claim is about a name no receiver answers, so a
        // receiver-taking target is not the one it named.
        if (gfd.params.len != 0 and std.mem.eql(u8, gfd.params[0].name, "this")) break :go;
        dispatchBump(.call_member_or_global_static);
        switch (try host.callFuncNamed(allocator, frame.module, gf, arg_values, names)) {
            .ok => |result| {
                try frame.write(cmg.dst, result);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // A pinned EXTENSION dispatches directly with the receiver prepended: the
    // global leg cannot prepend one, and the member leg would re-rank past it.
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
    // argument shape, to a plain global dispatched as a fused activation.
    if (site_skip and cmg.type_args.len == 0 and argNamesAllNull(cmg.arg_names)) {
        const claimed = @atomicLoad(u32, @constCast(&cmg.global_fid), .acquire);
        if (claimed != 0 and flatEnabled()) {
            const fid = FuncId.from(claimed - 1);
            if (frame.module.funcById(fid)) |gf| {
                if (gf.params.len == arg_values.len) {
                    // The claimed global may be a host-routed serve target, which
                    // this replay reaches instead of the static-call arm.
                    if (hostRouteServe(H, allocator, gf, arg_values, host)) |served| {
                        try frame.write(cmg.dst, served);
                        return .cont;
                    }
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
        // A bare MEMBER-EXTENSION call takes its two receivers from the implicit
        // tower independently: the extension receiver is the innermost candidate
        // satisfying the DECLARED type, the dispatch receiver the innermost owner.
        if (comptime @hasDecl(H, "receiverImplementsType")) mext: {
            if (!mextArmEnabled()) break :mext;
            if (!argNamesAllNull(cmg.arg_names)) break :mext;
            // A committed target names the declared receiver; an interface call
            // arrives uncommitted, so each candidate supplies its own.
            var committed_rt: ?[]const u8 = null;
            if (cmg.func) |cfid| {
                if (frame.module.funcById(cfid)) |cf| {
                    if (cf.kind != .member_extension) break :mext;
                    if (cf.params.len != arg_values.len + 1) break :mext;
                    if (cf.params.len == 0 or !std.mem.eql(u8, cf.params[0].name, "this")) break :mext;
                    committed_rt = cf.params[0].ty.name;
                }
            }
            // When the innermost receiver already satisfies the committed
            // target's receiver, the ordinary walk binds it correctly.
            if (committed_rt) |crt| {
                if (cands.len != 0 and cands[0].v == .Instance and
                    host.receiverImplementsType(&cands[0].v, crt)) break :mext;
            }
            var owner: ?Value = null;
            var target: ?ir.FuncId = null;
            var ext_recv: ?Value = null;
            for (cands) |c| {
                if (c.v != .Instance) continue;
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
            if (cands.len != 0 and cands[0].v == .Instance and
                host.receiverImplementsType(&cands[0].v, tf.params[0].ty.name)) break :mext;
            const all = try allocator.alloc(Value, arg_values.len + 1);
            defer allocator.free(all);
            all[0] = er;
            for (arg_values, 0..) |v, i| all[i + 1] = v;
            if (owner) |o| pushDispatch(&o);
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
        // Inside an extension body the implicit `this` has the extension's DECLARED
        // receiver type, which a bare call resolves against, not the runtime type.
        var static_from_instr = false;
        const static_recv_ty: ?[]const u8 = blk: {
            // The lowering-recorded receiver wins: the executing frame may be a
            // synthesized closure whose kind says nothing about it.
            if (cmg.static_recv) |sc| {
                if (constStr(frame.module, sc)) |sname| {
                    static_from_instr = true;
                    break :blk sname;
                }
            }
            switch (frame.func.kind) {
                .top_level_extension, .member_extension => {
                    const idx = frameThisParam(frame) orelse break :blk null;
                    break :blk frame.func.params[idx].ty.name;
                },
                .instance_method => {
                    // A plain instance method resolves a bare call against its
                    // DECLARING class's scope, so no subtype overload shadows it.
                    break :blk host.declaringClassSimpleName(frame.module, frame.func.id);
                },
                else => break :blk null,
            }
        };
        // Kotlin selects extensions statically, so a lowering-committed EXTENSION
        // target may be shadowed only by true MEMBERS, never by a re-picked sibling.
        const committed_ext: ?FuncId = blk: {
            const fid = cmg.func orelse break :blk null;
            // The commitment engages only for the self-name shape, a bare call to
            // the name of its own function, where a re-pick could re-enter it.
            if (!std.mem.eql(u8, frame.func.name, name_str)) break :blk null;
            if (fid.int() == frame.func.id.int()) break :blk null;
            const cf = frame.module.funcById(fid) orelse break :blk null;
            if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) break :blk fid;
            break :blk null;
        };
        // The committed target binds the first candidate receiver, innermost first,
        // its declared receiver does not exclude; with none, the name walk decides.
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
                // Every receiver disproves the committed target, yet the commitment
                // still locks this walk to members: a re-pick would re-select ITSELF.
                committed_ext_h = fid;
            }
        }
        // Strict pass in kotlinc candidate order: members, then
        // receiver-compatible extensions, of each candidate innermost first.
        for (cands, 0..) |c, ci| {
            if (cmgTraceWant()) |w| {
                if (std.mem.eql(u8, w, name_str)) {
                    const cn: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&c.v) else @tagName(std.meta.activeTag(c.v));
                    std.debug.print("[cmg-cand] {s} ci={d} depth={d} tag={s} class={s}\n", .{ name_str, ci, c.depth, @tagName(std.meta.activeTag(c.v)), cn });
                }
            }
            // The lowering-recorded receiver type describes the first candidate; a
            // FRAME-derived hint describes only the frame's own `this`.
            const hint_anchor: Value = if (!static_from_instr and cmg.recv != null)
                implicitThisValue(frame, cmg.this_idx, true)
            else
                this_val;
            const hint: ?[]const u8 = if (static_recv_ty != null and
                (sameReceiver(c.v, hint_anchor) or (static_from_instr and ci == 0)))
                static_recv_ty
            else
                null;
            // A bare `invoke()` on a callable candidate is a fun-interface dispatch
            // whose method may declare a receiver, from the ENCLOSING implicit ones.
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
            // Flat bare-member dispatch when this candidate's resolved-method cache
            // already names the target. The reified-type-binding shape keeps its
            // globals bound through this arm's defers, so it stays recursive.
            if (comptime @hasDecl(H, "prepareMemberFlatCall")) {
                if (flatEnabled() and mit_saved.items.len == 0 and argNamesAllNull(cmg.arg_names)) {
                    if (try host.prepareMemberFlatCall(allocator, &c.v, name_str, arg_values, hint, null, false)) |prep0| {
                        var prep = prep0;
                        prep.dst = cmg.dst;
                        arm_took_fid = prep.func.id.int();
                        orAudit("CallMemberOrGlobal", name_str, "member", c.depth, &c.v);
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            if (or_global_only and xoryAuditOn()) armFidBegin();
            switch (if (committed_ext_h != null)
                try host.callMemberMembersOnly(allocator, &c.v, name_str, arg_values, names, hint)
            else
                try host.callMemberStrictExt(allocator, &c.v, name_str, arg_values, names, hint)) {
                .ok => |v| {
                    if (or_global_only and xoryAuditOn()) arm_took_fid = armFidEnd();
                    orAudit("CallMemberOrGlobal", name_str, "member", c.depth, &c.v);
                    resolved = v;
                    break;
                },
                .err => |e| switch (e) {
                    .Suspended, .CalleeFailed => return raiseStep(frame, e),
                    // Control flow out of a body that RAN means the candidate was
                    // the real callee; walking on would re-execute its effects.
                    .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                    .Unimplemented => |m| {
                        freeDispatchMissMsg(allocator, m);
                        // A callable candidate is an unwrapped fun-interface value,
                        // so the bare name dispatches its single abstract method to
                        // the lambda. Kotlin binds the INNERMOST receiver.
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
        // extension-receiver match. It runs only after every receiver missed.
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
                        // As in the strict pass, a body that ran owns its control.
                        .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                        .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
                        else => if (first_real_err == null) {
                            first_real_err = e;
                        },
                    },
                }
            }
        }
        // Smart-cast pass: the probes above pinned the DECLARED receiver type, but a
        // smart cast may have narrowed it to a subtype, so retry by RUNTIME type.
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
        // Every member pass missed on a single implicit-receiver candidate, so
        // record it and let a repeat call skip here. A pass that FAILED is no miss.
        if (cmg_skip and single_cand and !is_ctor_name and !shadow_capture and first_real_err == null) {
            host.cmgGlobalRecord(func_p, &this_val, name_str, arg_values);
            if (site_key) |k| {
                if (dispatchCacheStable() and
                    @cmpxchgStrong(u64, @constCast(&cmg.skip_cls), 0, k.cls, .acq_rel, .monotonic) == null)
                {
                    @atomicStore(u64, @constCast(&cmg.skip_sig), k.sig, .release);
                }
            }
        }
        const cno_file: ?ir.FileId = if (frame.cur_span) |sp| sp.file else null;
        // A synthesized lambda frame carries no declared package, so the re-pick
        // would run with an empty caller scope and a same-name CROSS-PACKAGE twin
        // could win a first-seen tie; the committed target's package anchors it.
        const cno_anchor: []const u8 = if (frame.func.package.len == 0) blk: {
            if (cmg.func) |bf| {
                if (frame.module.funcById(bf)) |bfd| {
                    if (bfd.package.len != 0) break :blk bfd.package;
                }
            }
            // A ctor-name call carries no func hint, so the class's package
            // anchors the scope the same way.
            if (cmg.class) |cid| {
                if (cid.int() < frame.module.classes.items.len) {
                    break :blk frame.module.classes.items[cid.int()].package;
                }
            }
            break :blk "";
        } else "";
        // Arm the host-to-driver flat handoff: the overload terminal may stash a
        // prepared flat request instead of dispatching natively. This lane bypasses
        // every instrumented route, so it honours KLIO_FLAT itself.
        if (flatEnabled()) armHostFlatReq();
        // Call-site evidence committed `cmg.func`, so the candidate slice narrows
        // to it; the slice is authoritative and the re-rank cannot widen it out.
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
            // Claim the site's global target only for a plain dispatch: nothing
            // pushed, rebound, or prepended.
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
            // A lowering-resolved identity binds exactly, with the simple-name
            // lookup as the fallback and a shadowing capture outranking it. Only a
            // non-extension func or a class may bind by id.
            const by_id_func: ?FuncId = blk: {
                // A bounded candidate set blocks the NAME fallback below, but not
                // the lowering's own committed id, which is a resolution rather
                // than a same-simple-name widening.
                const fid = cmg.func orelse break :blk null;
                const cf = frame.module.funcById(fid) orelse break :blk null;
                // A committed id can belong to the MAIN module's table while this
                // frame runs sub-module code, so a name mismatch re-validates there.
                if (!std.mem.eql(u8, cf.name, name_str)) {
                    if (comptime @hasDecl(H, "mainFuncNameMatches")) {
                        if (host.mainFuncNameMatches(fid, name_str)) break :blk fid;
                    }
                    break :blk null;
                }
                if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) break :blk null;
                // A committed fn the call's ARITY cannot bind must not serve by
                // id: decline so the overload leg ranks the full same-name set.
                if (!frame.module.globalArityCanBind(fid, cf, arg_values.len)) break :blk null;
                break :blk fid;
            };
            // A committed class that cannot CONSTRUCT, an interface or abstract
            // classifier sharing its name with a callable, never wins the by-id
            // serve for a non-SAM call; the name lookup resolves the callable.
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
            // Binding by CLASS id with no function to bind IS a construction, even
            // when lowering did not classify the call as a ctor-name one. `ctor_ref`
            // makes `lookupGlobalById` skip the published companion singleton.
            const binding_ctor = is_ctor_name or (ctor_class != null and by_id_func == null);
            const by_id: ?Value = if ((ctor_class != null or by_id_func != null) and
                !host.isShadowingCapture(name_str))
                host.lookupGlobalById(allocator, by_id_func, ctor_class, binding_ctor, false)
            else
                null;
            // A bounded candidate set is authoritative: a miss may not widen back
            // to an unrelated same-simple-name global, and only a runtime shadowing
            // capture keeps the lexical name lookup. Host-only and
            // incomplete-header symbols carry null and keep that lookup.
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
                // The globals map holds one entry per simple name, whichever
                // same-named class the bake order registered, while kotlinc scopes
                // the pick to the call site's imports, so a classifier serve
                // disagreeing with an explicit import re-resolves through its fqn.
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
                        // The imported declaration may be a top-level FACTORY
                        // FUNCTION sharing the class's name, which kotlinc picks.
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
                // A CALL is not served by a non-callable name binding: a captured
                // `var key = 0` beside the `key(...) { }` composable does not shadow
                // the function, so re-bind through the function index first.
                if (!valueInvocable(frame.module, callee) and cmg.candidates == null) {
                    if (frame.module.funcId(name_str)) |fid| {
                        if (host.lookupGlobalById(allocator, fid, null, false, false)) |fv| {
                            orAudit("CallMemberOrGlobal", name_str, "noncallable_rebind", -1, null);
                            callee = fv;
                        }
                    }
                }
                orAudit("CallMemberOrGlobal", name_str, if (by_id != null) "global_id" else "global", -1, null);
                // Explicit call-site type args survive the deferred form, so a typed
                // value dispatch can coerce unsigned literals by them.
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
                // A committed header carrying reified type args serves through the
                // typed func dispatch, where the reified intrinsics live.
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
                // Every arm missed and the name is a declared header the link could
                // not settle (an `expect` with no `actual`), so the call is a no-op.
                if (host.bareUnsettledHeaderNoOp(frame.module, name_str, arg_values.len)) {
                    orAudit("CallMemberOrGlobal", name_str, "unsettled_header_noop", -1, null);
                    result = .Unit;
                } else if (enclosing_companion: {
                    // A member of an enclosing class's companion, called from a
                    // nested class's body.
                    if (comptime !@hasDecl(H, "enclosingCompanionMember")) break :enclosing_companion false;
                    if (this_val != .Instance) break :enclosing_companion false;
                    const r6 = (try host.enclosingCompanionMember(allocator, &this_val, name_str, arg_values)) orelse break :enclosing_companion false;
                    switch (r6) {
                        .ok => |v6| {
                            orAudit("CallMemberOrGlobal", name_str, "enclosing_companion", -1, &this_val);
                            result = v6;
                        },
                        .err => |e6| return raiseStep(frame, e6),
                    }
                    break :enclosing_companion true;
                }) {} else {
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

/// The enclosing-chain entry a method or extension frame contributes for its own
/// bound receiver: a dispatch receiver carries its class-nesting tower and
/// companion (`receiver`), an extension receiver brings only itself (`subject`).
/// Null for plain functions, lambdas, and unbound frames.
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

/// Index of the frame's SYNTHESIZED `this` receiver parameter, always 0 when
/// present. A leading `this` param is a dispatch receiver only when the lowerer
/// injected it (`has_receiver_param`); a user parameter spelled ``this`` with
/// backticks is not, so a bare call in its body resolves no implicit receiver.
fn frameThisParam(frame: *const Frame) ?usize {
    if (!frame.func.has_receiver_param) return null;
    if (frame.func.params.len != 0 and std.mem.eql(u8, frame.func.params[0].name, "this")) {
        return 0;
    }
    return null;
}

/// The head of a dotted class name (`a.b.C` -> `C`).
fn simpleClassHead(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Simple name of the class that declares `fid`, over a lazily built reverse
/// index; a linear scan would be O(classes x methods) per lookup. Gives an
/// instance method's implicit-`this` call the static receiver type Kotlin uses.
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

/// The calling frame's receiver, an Instance from a `this`-named param or
/// capture, else null.
pub fn callerThisValue(frame: *const Frame) ?Value {
    if (frameThisParam(frame)) |i| {
        if (i < frame.params.items.len and frame.params.items[i] == .Instance) {
            return frame.params.items[i];
        }
    }
    var idx = frame.func.this_cap_idx;
    if (idx == -2) {
        idx = -1;
        for (frame.func.x().capture_order, 0..) |n, i| {
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

// Implicit-receiver resolution choke point. The `*OrGlobal` instructions resolve
// a bare name against the implicit receivers in scope (the lambda or method's own
// `this`, each lexically-enclosing `this@…`, and, for dispatch receivers, the
// class-nesting tower of `outer` links) before falling back to a top-level global;
// `implicitCandidatesAlloc` derives the candidate list and its order for all
// three. Kotlin's precedence: innermost-first, and ALL of a receiver's candidates,
// members then applicable extensions, outrank the next receiver out.

/// The implicit receiver for an `*OrGlobal` instruction: the synthesized `this`
/// parameter when this frame has one, else `captures[this_idx]` if in range, else
/// `Null`. The parameter is authoritative, since the capture slot can hold an
/// unrelated boxed local at the same numeric index.
fn implicitThisValue(frame: *const Frame, this_idx: usize, consult_param: bool) Value {
    if (consult_param) {
        if (frameThisParam(frame)) |idx| {
            if (idx < frame.params.items.len) return frame.params.items[idx];
        }
    }
    // The baked capture index is trusted only when it actually names the `this`
    // capture: several emit arms bake 0 as a placeholder, and `captures[0]` is then
    // whatever capture came first, which must never enter the walk.
    var idx = this_idx;
    const order = frame.func.x().capture_order;
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

/// One candidate receiver for a bare-name `*OrGlobal` resolution. `depth` is
/// the candidate's position in the search order, 0 being the frame's own
/// implicit `this`.
const ImplicitCandidate = struct {
    v: Value,
    depth: u16,
    /// True when this candidate belongs to the frame's OWN receiver run (the
    /// dispatch `this`, its companion, its class-nesting tower), the one run whose
    /// class-body scope lexically encloses the executing body. Entries published by
    /// dispatch context are not `own`, so they do not outrank a captured local.
    own: bool = false,
};

/// Low bits of a `site_cache` word: 2-bit verdict + 8-bit winner index;
/// the rest is the shape hash.
const SITE_SHAPE_MASK: u64 = ~@as(u64, 0x3FF);
const SITE_MISS: u64 = 1;
const SITE_WIN: u64 = 2;

/// Fold the candidate list into a stable shape word for the bare-name site memo:
/// an Instance contributes its class identity and stored field count, any other
/// value its tag. Null disables the memo, since a candidate carrying lexical
/// `this@` captures probes receivers whose state the shape cannot cover.
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

/// Keep every receiver alive for the whole walk, including transient Cell and
/// companion candidates no frame holds: candidate walks live in host scratch
/// memory, and probing a property or member can re-enter interpreted code.
fn pinImplicitCandidates(cands: []const ImplicitCandidate) usize {
    const mark = runtime.keepaliveMark();
    for (cands) |c| runtime.keepalivePush(c.v);
    return mark;
}

const SamInvokeOutcome = union(enum) { done: Value, raised: EvalError };

/// Dispatch a bare name that missed, or is `invoke`, on a CALLABLE walk candidate
/// as a fun-interface method, running the lambda with the next implicit receiver
/// out as `this`: the interface method may be a member extension whose body
/// resolves bare names against it. Null on a non-control-flow error.
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
    // For any name other than `invoke`, the interface-method reading holds only
    // when the callable's declared parameter count matches the call exactly and no
    // top-level non-extension function serves the name, which kotlinc binds first.
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
        // A deeper implicit receiver that can serve the name outranks the
        // interface-method reading of this callable, so decline and let it through.
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

/// Free-list of candidate buffers for the walk, which runs on every dynamic
/// member dispatch. Buffers are allocator-owned, growth past the size class frees
/// them back into the allocator, and release retains only exact capacities.
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
    // In-flight chain pushes, entries this frame pushed DURING execution, are
    // lexically INNER to the frame's own receiver, so they rank ahead of `inner`.
    // `enclosingEntriesAlloc` reverses the chain, so they are its prefix.
    const in_flight: usize = blk: {
        if (frame.tls.active_chain != &frame.enclosing_this) break :blk 0;
        const total = frame.enclosing_this.items.len;
        const base = frame.tls.active_chain_base;
        break :blk if (total > base) total - base else 0;
    };
    for (entries[0..@min(in_flight, entries.len)]) |e| {
        try appendCandidateRun(H, allocator, &out, e.v, e.isSubject(), false, &depth, host, bare_name);
    }
    // The innermost candidate is the inline splice's bound receiver when
    // supplied, otherwise the frame's own `this`. A supplied direct receiver is
    // subject-like, its own value only with no class-nesting tower, and it
    // replaces rather than precedes the frame `this`.
    const inner: ?Value = if (direct_this) |dt|
        dt
    else blk: {
        const tv = implicitThisValue(frame, this_idx, consult_param);
        break :blk if (tv == .Null or tv == .Unit) null else tv;
    };
    if (inner) |iv| {
        if (iv != .Unit) {
            // When the innermost receiver is also the innermost chain entry, that
            // entry's run already covers it. A subject-kind duplicate must not
            // suppress a REAL receiver param's own run, but a capture-received
            // lambda `this` IS the subject: a `with` block's bare call must not
            // see the subject's enclosing instances, as kotlinc also rejects.
            const own_dispatch_shape = frame.func.params.len != 0 and
                std.mem.eql(u8, frame.func.params[0].name, "this");
            const dup = entries.len > in_flight and sameReceiver(entries[in_flight].v, iv) and
                (!entries[in_flight].isSubject() or !own_dispatch_shape);
            if (!dup) {
                // The frame's own `this` brings its class-nesting tower and
                // companion only as a DISPATCH receiver: `fun Owner.Inner.f()` does
                // not put `Inner`'s enclosing `Owner` in scope. A direct receiver
                // that IS the frame's `this` param is one; a foreign one is not.
                const direct_is_frame_recv = if (direct_this) |dt| blk: {
                    if (frameThisParam(frame)) |ti| {
                        if (ti < frame.params.items.len and sameReceiver(frame.params.items[ti], dt)) break :blk true;
                    }
                    // An instance method's `this` param has no `has_receiver_param`
                    // bit, and a flat activation may route it through the capture
                    // slot, so compare against what the non-direct path would use.
                    const tv = implicitThisValue(frame, this_idx, consult_param);
                    if (tv != .Null and tv != .Unit and sameReceiver(tv, dt)) break :blk true;
                    break :blk false;
                } else false;
                const own_is_subject = (direct_this != null and !direct_is_frame_recv) or switch (frame.func.kind) {
                    .top_level_extension, .member_extension => true,
                    else => false,
                };
                // The same value may already sit on the chain as a spliced SUBJECT
                // whose run has no class-nesting tower, so it must not suppress the
                // own dispatch run; the own kind still decides subject-ness.
                try appendCandidateRun(H, allocator, &out, iv, own_is_subject, true, &depth, host, bare_name);
            }
        }
    }
    // A supplied direct receiver replaces the frame `this`, but when the frame
    // carries its OWN receiver param bound to a different value, dropping the param
    // strands every bare member of the declared receiver, so it stays in the walk.
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
        const e_own = ei == 0 and inner != null and sameReceiver(e.v, inner.?);
        try appendCandidateRun(H, allocator, &out, e.v, e.isSubject(), e_own, &depth, host, bare_name);
    }
    return out;
}

/// Append `v` and, unless it entered scope as a `with`/`run` subject, its
/// class's member-owning companion and its class-nesting tower of `outer`
/// links, each with its own companion. Consecutive duplicates collapse.
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
    // A null `with`/`run` subject is a real receiver candidate, since a
    // nullable-receiver extension applies to it; a null dispatch receiver just
    // means nothing is bound.
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

/// Append the companion-object singleton of `v`'s class as a candidate at the
/// class's own depth, when that companion owns a member named `bare_name`.
/// Kotlin scopes the companion below the instance receiver, at that depth.
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

pub fn sameReceiver(a: Value, b: Value) bool {
    if (a == .Instance and b == .Instance) return ObjRef(InstanceData).ptrEq(a.Instance, b.Instance);
    return false;
}

var or_audit_checked: bool = false;
var or_audit_enabled: bool = false;

/// `KLIO_OR_AUDIT` logs which arm bound the name on every `*OrGlobal` execution:
/// `member@<depth>` with the winning receiver's type, `overload`, `global_id` for
/// the lowering-resolved identity, `global` for the name lookup, or a store variant.
var route_trace_init: bool = false;
var route_trace_val: ?[]const u8 = null;
/// `KLIO_MEXT_ARM=0` disables the bare member-extension receiver arm.
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
        route_trace_val = runtime.envOnce("KLIO_ROUTE");
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

/// The instruction currently being served, so an audit row names the SITE and
/// not just the name. Whether an XOrY site ever takes both arms is the question
/// that decides which of them lowering can settle, and a per-name tally cannot
/// answer it: one name is many sites.
threadlocal var or_site: usize = 0;

/// A site key the arms can all produce: the executing function and the name
/// constant. Two sites for one name in one function merge, which can only make
/// a site look like it takes both arms when it does not — the safe direction
/// for a question about what lowering may settle.
fn orSiteEnter(frame: *Frame, name: anytype) usize {
    const prev = or_site;
    or_site = (@as(usize, frame.func.id.int()) << 24) | @as(usize, name.int());
    return prev;
}

/// Whether the site being served said only its global leg can win, and the
/// name it said it about. A resolution nests — a field read inside the call
/// reports its own arms through the same audit — so the flag alone would
/// blame this site for a decision another instruction made.
threadlocal var or_global_only: bool = false;
threadlocal var or_global_only_name: []const u8 = "";
/// The global leg's target at the claimed site, so the audit can say whether a
/// "member" win called the very declaration the site already named.
threadlocal var or_global_only_func: u32 = 0xFFFF_FFFF;

/// The declaration an arm actually entered, captured only while the XOrY audit
/// is measuring one. FIRST wins: the arm's own callee is entered before
/// anything that callee calls.
threadlocal var arm_fid_capture: bool = false;
threadlocal var arm_fid: u32 = 0xFFFF_FFFF;
threadlocal var arm_took_fid: u32 = 0xFFFF_FFFF;

var xory_serve_state: u8 = 0;

/// Whether a site the link pass called global-only takes its named target
/// directly. Off leaves every one on the member walk, which is what the
/// corpus diff compares against.
pub fn xoryServeOn() bool {
    if (xory_serve_state == 0) {
        xory_serve_state = if (std.mem.eql(u8, runtime.envOnce("KLIO_XORY_SERVE") orelse "1", "0")) 1 else 2;
    }
    return xory_serve_state == 2;
}

pub fn armFidCaptureOn() bool {
    return arm_fid_capture;
}

pub fn noteArmFid(fid: u32) void {
    if (arm_fid == 0xFFFF_FFFF) arm_fid = fid;
}

fn armFidBegin() void {
    arm_fid_capture = true;
    arm_fid = 0xFFFF_FFFF;
}

fn armFidEnd() u32 {
    arm_fid_capture = false;
    return arm_fid;
}

/// Which audit arms mean a RECEIVER answered, as opposed to one of the global
/// tiers. `overload` and `global_id` are global-side picks among same-named
/// top-level declarations, not a member win — counting them would make the
/// audit report noise instead of the one thing it is for.
fn armIsReceiverWin(arm: []const u8) bool {
    const receiver_arms = [_][]const u8{
        "member",              "member_lenient",  "member_ext_recv",
        "smartcast_ext",       "committed_ext",   "pinned_ext_direct",
        "enclosing_companion", "member_inline_typed", "sam_receiver_invoke",
    };
    for (receiver_arms) |a| {
        if (std.mem.eql(u8, arm, a)) return true;
    }
    return false;
}

var xory_audit_state: u8 = 0;
fn xoryAuditOn() bool {
    if (xory_audit_state == 0) {
        xory_audit_state = if (runtime.envOnce("KLIO_XORY_AUDIT") != null) 2 else 1;
    }
    return xory_audit_state == 2;
}

fn orAudit(inst_tag: []const u8, name: []const u8, arm: []const u8, depth: i32, recv: ?*const Value) void {
    // A site the link pass called global-only claims no receiver in scope can
    // answer the name. Every arm reports which leg won, so the claim is
    // checkable against what runs rather than assumed.
    if (or_global_only and xoryAuditOn() and armIsReceiverWin(arm) and
        std.mem.eql(u8, inst_tag, "CallMemberOrGlobal") and
        std.mem.eql(u8, name, or_global_only_name))
    {
        // A member arm that entered the very declaration the global leg names
        // is not a refutation: the walk reached the same function by a longer
        // route. Only a DIFFERENT target says the claim was wrong.
        if (arm_took_fid != or_global_only_func) {
            std.debug.print("[xory-audit] name={s} arm={s} depth={d} recv={s} took={d} site_global={d} in={s} site={x}\n", .{
                name,
                arm,
                depth,
                if (recv) |r| r.typeFqn() else "-",
                arm_took_fid,
                or_global_only_func,
                if (ir.eval.currentFrameFunc()) |c| (if (c.fqn.len != 0) c.fqn else c.name) else "-",
                or_site,
            });
        }
    }
    if (!orAuditOn()) return;
    const recv_tag: []const u8 = if (recv) |r| r.typeFqn() else "-";
    std.debug.print(
        "[KLIO_OR_AUDIT] run inst={s} name={s} arm={s} depth={d} recv={s} site={x}\n",
        .{ inst_tag, name, arm, depth, recv_tag, or_site },
    );
}

/// The owner class a scope-qualified getter name carries, else null.
fn scopeGetterOwner(name: []const u8) ?[]const u8 {
    const prefix = "$sgetter$";
    if (std.mem.startsWith(u8, name, prefix)) {
        const rest = name[prefix.len..];
        if (std.mem.findScalar(u8, rest, '\u{1f}')) |sep| {
            return rest[0..sep];
        }
    }
    return null;
}

fn stripScopeGetter(name: []const u8) []const u8 {
    const prefix = "$sgetter$";
    if (std.mem.startsWith(u8, name, prefix)) {
        const rest = name[prefix.len..];
        if (std.mem.findScalar(u8, rest, '\u{1f}')) |sep| {
            return rest[sep + 1 ..];
        }
    }
    return name;
}

/// A positional call: no entry carries an argument name.
/// Stack argv bound for the frameless static-call shortcut. Sized to cover the
/// arities that occur, not the frameless tier's register maximum, so the frame
/// this sits in stays small.
const FUSED_ARGV_MAX: usize = 12;

pub fn argNamesAllNull(names: []const ?ConstId) bool {
    for (names) |n| if (n != null) return false;
    return true;
}

/// A call's argument run in a carrier list. The fused static-call site hands the
/// list straight to the activation as its params, so the carrier follows the
/// same acquire/release discipline as every other frame buffer.
fn readArgList(allocator: Allocator, frame: *const Frame, args_start: Reg, n: u32) Allocator.Error!std.ArrayList(Value) {
    var list = try acquireArgsCap(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        list.appendAssumeCapacity(frame.read(Reg.from(args_start.int() + i)));
    }
    return list;
}

/// Pull `n` register values from `args_start` into a fresh slice. Caller frees.
pub fn readArgRun(allocator: Allocator, frame: *const Frame, args_start: Reg, n: u32) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        out[i] = frame.read(Reg.from(args_start.int() + i));
    }
    return out;
}

/// The element Value for a range cursor. Mirrors the interp_ir `rangeElem`.
inline fn rangeElemEval(cur: i64, kind: runtime.RangeKind) Value {
    return switch (kind) {
        .Int => Value.newInt(cur),
        .Long => .{ .Long = cur },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(cur))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(cur))) },
        .ULong => .{ .ULong = @bitCast(cur) },
    };
}

/// Inline `hasNext()`/`next()` for a `.RangeIter` receiver, skipping the member
/// dispatch a desugared for-loop over an integer or char range would pay per
/// iteration. Null for any other method; mirrors `builtin_members.rangeIterMember`.
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
                // An unsigned array over signed backing (`UIntArray(intArray)`)
                // tags elements by `arr.prim`, not the buffer's storage kind.
                return g.get().getAs(ui, arr.primKind() orelse g.get().kind); // fresh scalar
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
            // A stale subList view must fail fast: the slow path's read guard
            // throws ConcurrentModificationException.
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
            // The UTF-16 unit at `ui` is byte `ui` when every byte is ASCII;
            // otherwise the cursor-resumed walk answers, so an in-bounds index
            // is served here whatever the string holds. Out of bounds is the
            // one case left, and the caller raises it.
            if (sd.ascii) return if (ui < sd.bytes.len) .{ .Char = sd.bytes[ui] } else null;
            return if (sd.utf16UnitAt(ui)) |u| .{ .Char = u } else null;
        },
        // A builder carries no immutable header, so its ASCII-ness, length and
        // cursor live in the reader memo every mutating builtin invalidates.
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            const items = g.get().items;
            const m = runtime.sbMemoFor(@intFromPtr(sb.cell), items);
            if (m.ascii) return if (ui < items.len) .{ .Char = items[ui] } else null;
            return if (runtime.sbUnitAt(m, items, ui)) |u| .{ .Char = u } else null;
        },
        else => return null,
    }
}

/// Indexed-store fast path for `a[i] = v` on an `Array` or a plain mutable
/// `List`, with the `coll_array_set` ownership: release the overwritten element,
/// retain the incoming one. Returns the set-EXPRESSION's value, `Unit` for an
/// array and the PREVIOUS element for a list per Kotlin's `MutableList.set`.
/// Out-of-bounds, an immutable receiver and a live view return null.
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
                g.get().setAs(ui, new_val, arr.primKind() orelse g.get().kind);
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

/// The bitwise and conversion MEMBERS of `Int`/`Long`, served inline: `a shl b`
/// and friends are infix member functions, not operators, so they lower to a member
/// call and reach the name ladder on every execution. A member always wins over an
/// extension in Kotlin, so these names on an `Int` pair mean the builtin.
/// `toString()` on the two host-backed text shapes, which is a total path:
/// a string IS its own `toString`, and a builder's is its buffer decoded.
/// Everything else declines, so a user override is never shadowed.
pub fn fastToString(allocator: Allocator, recv: *const Value) ?Value {
    switch (recv.*) {
        .String => {
            recv.retain();
            return recv.*;
        },
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            const dup = runtime.coalesceSurrogates(allocator, g.get().items) catch return null;
            return .{ .String = runtime.strInitOwned(allocator, dup) catch return null };
        },
        else => return null,
    }
}

pub inline fn primitiveMemberFast(frame: *const Frame, cm: anytype) ?Value {
    if (cm.x().arg_names.len != 0 or cm.n_args > 1) return null;
    // The site names the operation, so the ladder below is a switch rather
    // than up to a dozen string comparisons per member call.
    const op = cm.builtin;
    if (op == .none) return null;
    const recv = frame.read(cm.receiver);
    const arg: ?Value = if (cm.n_args == 1) frame.read(Reg.from(cm.args.int())) else null;
    return primitiveMemberOpOf(&recv, op, arg);
}

/// The value-level core of `primitiveMemberFast`, shared with the frameless leaf
/// walk: a pure function of the receiver, name and at most one argument. The
/// leaf walk holds a name and no site, so it converts once here.
pub fn primitiveMemberOp(recv_in: *const Value, nm: []const u8, arg_in: ?Value) ?Value {
    const n_args: u32 = if (arg_in != null) 1 else 0;
    return primitiveMemberOpOf(recv_in, ir.BuiltinMember.of(nm, n_args), arg_in);
}

pub fn primitiveMemberOpOf(recv_in: *const Value, op: ir.BuiltinMember, arg_in: ?Value) ?Value {
    // No instance is a primitive, and an instance is the receiver this is asked
    // about most; deciding it here spares the name compares below.
    if (recv_in.* == .Instance) return null;
    const recv = recv_in.*;
    // `compareTo` on two same-kind primitives answers what the host intrinsic does:
    // the CODE DIFFERENCE for `Char`, and -1/0/1 for `Int`/`Long`.
    if (arg_in) |cmp_arg| {
        if (op == .compare_to) {
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
    // Backing-free container `isEmpty` only: a live view computes its length in the
    // view machinery. `isNotEmpty` is a SHADOWABLE extension, so it is not served.
    if (arg_in == null) {
        switch (recv) {
            .List => |l| if (l.backing == null) {
                const n = blk: {
                    const g = l.items.borrow();
                    defer g.deinit();
                    break :blk g.get().items.len;
                };
                if (op == .is_empty) return .{ .Bool = n == 0 };
                return null;
            },
            .Set => |st| if (st.backing == null) {
                const n = blk: {
                    const g = st.items.borrow();
                    defer g.deinit();
                    break :blk g.get().items.len;
                };
                if (op == .is_empty) return .{ .Bool = n == 0 };
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
        if (op == .to_int) return Value.newInt(@truncate(wide));
        if (op == .to_long) return .{ .Long = wide };
        if (op == .inv) return switch (recv) {
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
        if (op == .shl) return switch (recv) {
            .Int => |i| Value.newInt(@as(i32, @bitCast(@as(u32, @bitCast(i)) << @truncate(s)))),
            .Long => |l| .{ .Long = @bitCast(@as(u64, @bitCast(l)) << s) },
            else => unreachable,
        };
        if (op == .shr) return switch (recv) {
            .Int => |i| Value.newInt(i >> @truncate(s)),
            .Long => |l| .{ .Long = l >> s },
            else => unreachable,
        };
        if (op == .ushr) return switch (recv) {
            .Int => |i| Value.newInt(@as(i32, @bitCast(@as(u32, @bitCast(i)) >> @truncate(s)))),
            .Long => |l| .{ .Long = @bitCast(@as(u64, @bitCast(l)) >> s) },
            else => unreachable,
        };
    }
    // `and`/`or`/`xor` are same-width members; a mixed pair is another decl.
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
    if (op == .bit_and) return wrap(is_int, p.a & p.b);
    if (op == .bit_or) return wrap(is_int, p.a | p.b);
    if (op == .bit_xor) return wrap(is_int, p.a ^ p.b);
    return null;
}

/// Whether this site may serve a NULL stored slot. Asked of the host once and kept
/// on the instruction: it is a property of the class the site memo pinned.
pub inline fn nullSiteOk(comptime H: type, host: *H, recv: *const Value, name: []const u8, slot: *u8) bool {
    const cached = @atomicLoad(u8, slot, .acquire);
    if (cached != 0) return cached == 2;
    const ok_now = host.storedNullServable(recv, name);
    @atomicStore(u8, slot, if (ok_now) @as(u8, 2) else 1, .release);
    return ok_now;
}

/// What the subscript path produced. An ARRAY receiver never declines, and
/// neither does a STRING read: an index outside either is an error, and
/// raising it here is what makes the path total. A path that can decline
/// sends the site back to the by-name walk, which is the whole reason a site
/// naming its operation still could not be called resolved.
pub const SubscriptResult = union(enum) { value: Value, err: EvalError, decline };

pub inline fn fastSubscript(allocator: Allocator, frame: *const Frame, cm: anytype) SubscriptResult {
    if (cm.x().arg_names.len != 0 or cm.n_args == 0) return .decline;
    // The indexed shapes are arrays, lists, maps and strings; an instance
    // receiver reaches neither serve, so its tag answers before the names do.
    const recv = frame.read(cm.receiver);
    if (recv == .Instance) return .decline;
    // The operation is on the instruction: the name and the argument count
    // decided it at lowering, and neither changes per execution.
    const op = cm.builtin;
    // `KLIO_SUBSCRIPT_AUDIT=1`: the site's operation against the name it was
    // bound from. A site whose name was not yet a string constant when it was
    // pushed would bind `.none` and quietly lose the fast path rather than
    // answer wrongly, which is the failure this reports.
    if (runtime.envOnce("KLIO_SUBSCRIPT_AUDIT") != null) {
        const nm = constStr(frame.module, cm.name) orelse "";
        const walked = ir.BuiltinMember.of(nm, cm.n_args);
        if (walked != op) {
            std.debug.print("[subscript-audit] name={s} nargs={d} site={s} walk={s}\n", .{
                nm, cm.n_args, @tagName(op), @tagName(walked),
            });
        }
    }
    if (op == .none) return .decline;
    const idx_v = frame.read(Reg.from(cm.args.int()));
    const served: ?Value = if (op == .get)
        fastIndexGet(&recv, &idx_v)
    else
        fastIndexSet(allocator, &recv, &idx_v, frame.read(Reg.from(cm.args.int() + 1)));
    if (served) |v| return .{ .value = v };
    // An array with an `Int` index declines for one reason only, and that
    // reason is an exception the walk would raise anyway. Raising it here
    // keeps the path total, which is what lets the site be called resolved.
    if (recv == .Array and idx_v == .Int and arrayIndexOob(&recv, idx_v.Int)) {
        const msg = std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{
            idx_v.Int, arrayLen(&recv),
        }) catch return .decline;
        const exc = Value.newException(allocator, .{
            .fqn = runtime.strInit(allocator, "java.lang.ArrayIndexOutOfBoundsException") catch return .decline,
            .message = .from(runtime.strInitOwned(allocator, msg) catch return .decline),
            .cause = null,
        }) catch return .decline;
        return .{ .err = .{ .Throw = exc } };
    }
    // A builder read declines for the same one reason, and its native words
    // the exception differently from the string's.
    if (op == .get and recv == .StringBuilder and idx_v == .Int) {
        const n: usize = blk: {
            const g = recv.StringBuilder.borrow();
            defer g.deinit();
            const items = g.get().items;
            break :blk runtime.sbMemoFor(@intFromPtr(recv.StringBuilder.cell), items).u16_len;
        };
        const msg = std.fmt.allocPrint(allocator, "index: {d}, length: {d}", .{ idx_v.Int, n }) catch return .decline;
        const exc = Value.newException(allocator, .{
            .fqn = runtime.strInit(allocator, "kotlin.IndexOutOfBoundsException") catch return .decline,
            .message = .from(runtime.strInitOwned(allocator, msg) catch return .decline),
            .cause = null,
        }) catch return .decline;
        return .{ .err = .{ .Throw = exc } };
    }
    // A string subscript with an `Int` index declines for one reason too, and
    // the native raises exactly this for it.
    if (op == .get and recv == .String and idx_v == .Int) {
        const u16_len: usize = blk: {
            const g = recv.String.borrow();
            defer g.deinit();
            break :blk g.get().u16_len;
        };
        const msg = if (idx_v.Int < 0)
            std.fmt.allocPrint(allocator, "index {d} out of bounds", .{idx_v.Int}) catch return .decline
        else
            std.fmt.allocPrint(allocator, "index {d} out of bounds (length {d})", .{ idx_v.Int, u16_len }) catch return .decline;
        const exc = Value.newException(allocator, .{
            .fqn = runtime.strInit(allocator, "kotlin.IndexOutOfBoundsException") catch return .decline,
            .message = .from(runtime.strInitOwned(allocator, msg) catch return .decline),
            .cause = null,
        }) catch return .decline;
        return .{ .err = .{ .Throw = exc } };
    }
    return .decline;
}

fn arrayLen(recv: *const Value) usize {
    return switch (recv.*) {
        .Array => |arr| switch (arr.storage()) {
            .scalars => |pb| blk: {
                const g = pb.borrow();
                defer g.deinit();
                break :blk g.get().len();
            },
            .boxed => |vl| blk: {
                const g = vl.borrow();
                defer g.deinit();
                break :blk g.get().items.len;
            },
        },
        else => 0,
    };
}

/// Whether `idx` is outside the array, which is the only reason an array
/// subscript with an `Int` index declines.
fn arrayIndexOob(recv: *const Value, idx: i64) bool {
    if (idx < 0) return true;
    return @as(usize, @intCast(idx)) >= arrayLen(recv);
}

/// Snapshot the live values of a `[]Reg`. Caller frees.
fn readRegSlice(allocator: Allocator, frame: *const Frame, regs: []const Reg) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, regs.len);
    for (regs, out) |r, *dst| dst.* = frame.read(r);
    return out;
}

/// Flatten an array, list or set into its items for spread-arg dispatch.
/// Caller frees the returned slice.
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

/// An all-null name run carries no information beyond its length, so one shared
/// constant run serves every positional call up to this arity, and is never freed.
const ARG_NAMES_NULL_MAX: usize = 32;
const arg_names_null: [ARG_NAMES_NULL_MAX]?[]const u8 = @splat(null);

/// Resolve `arg_names` into a parallel `[]?[]const u8`. Freed by `freeArgNames`.
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

/// Heuristic for an erased type-parameter name: one or two uppercase letters.
fn isErasedTypeParamName(name: []const u8) bool {
    const n = std.mem.trimEnd(u8, name, "?");
    if (n.len == 0 or n.len > 2) return false;
    for (n) |c| {
        if (!(c >= 'A' and c <= 'Z')) return false;
    }
    return true;
}

/// Whether a non-`instance_of` cast still passes because the target is an erased
/// type parameter, which the JVM leaves unchecked.
fn typeParamCastPasses(comptime H: type, frame: *const Frame, ty: TypeRef, host: *H) bool {
    return typeParamCastPassesIn(H, frame.module, frame.func, ty, host);
}

/// Frame-free core of `typeParamCastPasses`, shared with the fused walker's Cast
/// arm: the leniency for erased targets is part of Cast semantics, not of a frame.
pub fn typeParamCastPassesIn(comptime H: type, module: *const Module, func: *const ir.Func, ty: TypeRef, host: *H) bool {
    if (module.registry.func_type_params.get(func.id)) |tps| {
        for (tps.items) |t| {
            if (std.mem.eql(u8, t, ty.name)) return true;
        }
    }
    // A short uppercase name is an erased parameter unless the program DECLARES
    // a class of that name; a reified binding published under it still erases.
    const declared = if (comptime @hasDecl(H, "isDeclaredClassNameFrom")) host.isDeclaredClassNameFrom(ty.name, func.package) else false;
    if (isErasedTypeParamName(ty.name) and !declared) return true;
    if (!host.isConcreteCastTarget(ty.name)) return true;
    return false;
}
