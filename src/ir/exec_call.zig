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
const cmgTraceWant = eval.cmgTraceWant;
const dispatchBump = eval.dispatchBump;
const dispatchCacheStable = eval.dispatchCacheStable;
const dumpFrameChainForDiag = eval.dumpFrameChainForDiag;
const enclosingEntriesAlloc = eval.enclosingEntriesAlloc;
const errResult = eval.errResult;
const flatEnabled = eval.flatEnabled;
const missTraceWant = eval.missTraceWant;
const ok = eval.ok;
const popEnclosing = eval.popEnclosing;
const pushDispatch = eval.pushDispatch;
const pushEnclosingAccess = eval.pushEnclosingAccess;
const raiseStep = eval.raiseStep;
const takeHostFlatArm = eval.takeHostFlatArm;

pub fn envVarSet(name: []const u8) bool {
    return runtime.procEnvIsSet(std.heap.page_allocator, name);
}

pub fn constStr(module: *const Module, id: ConstId) ?[]const u8 {
    return switch (module.consts.items[id.int()]) {
        .String => |s| s,
        else => null,
    };
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

pub fn sameReceiver(a: Value, b: Value) bool {
    if (a == .Instance and b == .Instance) return ObjRef(InstanceData).ptrEq(a.Instance, b.Instance);
    return false;
}

/// `KLIO_OR_AUDIT` logs which arm bound the name on every `*OrGlobal` execution:
/// `member@<depth>` with the winning receiver's type, `overload`, `global_id` for
/// the lowering-resolved identity, `global` for the name lookup, or a store variant.
var route_trace_init: bool = false;
var route_trace_val: ?[]const u8 = null;

fn routeTraceOn(name: []const u8) bool {
    if (!route_trace_init) {
        route_trace_val = runtime.envOnce("KLIO_ROUTE");
        route_trace_init = true;
    }
    const w = route_trace_val orelse return false;
    return std.mem.eql(u8, w, name);
}

/// The declaration an arm actually entered, captured only while the XOrY audit
/// is measuring one. FIRST wins: the arm's own callee is entered before
/// anything that callee calls.
threadlocal var arm_fid_capture: bool = false;
threadlocal var arm_fid: u32 = 0xFFFF_FFFF;

pub fn armFidCaptureOn() bool {
    return arm_fid_capture;
}

pub fn noteArmFid(fid: u32) void {
    if (arm_fid == 0xFFFF_FFFF) arm_fid = fid;
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

