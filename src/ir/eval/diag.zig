//! Evaluator diagnostics: wall cap, profiling dumps, trace and throwable rendering.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const ValueList = runtime.ValueList;

const BinOp = ir.BinOp;
const Const = ir.Const;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const UnOp = ir.UnOp;
const FuncId = ir.FuncId;

const parent = @import("../eval.zig");
const ev_flow = @import("flow.zig");
const ev_state = @import("state.zig");

const EvalResult = ev_flow.EvalResult;
const captureStack = ev_state.captureStack;
const errResult = ev_flow.errResult;

/// `KLIO_SPIN_TRACE=<seconds>`: interval for the live frame-chain dump; null = off.
var spin_interval_s: ?i64 = null;

var spin_interval_read = false;

/// Abandon the cohort: a wall-capped test must die rather than let its siblings
/// resume against half-torn state. The runner clears the flags before the next.
pub fn wallCapAbandon() void {
    runtime.requestAbandon();
    runtime.setRunBoundaryAbandon(true);
}

/// Each of the first `wall_cap_catchable_fires` fires extends the deadline by an
/// unwind budget and throws a CATCHABLE exception, so the test ends through its
/// own teardown even when it catches one; after them, a hard abort plus cohort
/// abandonment, which runs no `finally`.
pub fn wallCapFire(allocator: Allocator) Allocator.Error!EvalResult {
    if (parent.wall_cap_fires.fetchAdd(1, .acq_rel) < parent.wall_cap_catchable_fires) {
        const dl = parent.test_wall_deadline_ms.load(.monotonic);
        if (dl != 0) parent.test_wall_deadline_ms.store(dl + parent.wall_cap_unwind_ms.load(.monotonic), .monotonic);
        std.debug.print("[wall-cap] test wall-clock deadline exceeded — throwing; hang location follows:\n", .{});
        dumpFrameChainForDiagAlways();
        return errResult(.{ .Throw = try Value.newException(allocator, .{
            .fqn = try runtime.strInit(allocator, "kotlin.RuntimeException"),
            .message = .from(try runtime.strInit(allocator, "test wall-clock deadline exceeded")),
            .cause = null,
        }) });
    }
    std.debug.print("[wall-cap] deadline exceeded again during unwind — hard abort:\n", .{});
    dumpFrameChainForDiagAlways();
    wallCapAbandon();
    return errResult(.{ .Type = "test wall-clock deadline exceeded" });
}

/// Per-test invariant probe: a nonzero depth between tests is an unwind leak.
pub fn evalDepthNow() usize {
    return ev_state.evtlsPtr().eval_depth;
}

/// Whether dispatch caches may be populated: a capped or abandoned run aborts
/// walks mid-probe, and caching those outcomes poisons every later execution.
pub fn dispatchCacheStable() bool {
    if (runtime.shouldAbandon()) return false;
    const dl = parent.test_wall_deadline_ms.load(.monotonic);
    return dl == 0 or nowMonotonicMs() <= dl;
}

pub fn nowMonotonicMs() i64 {
    return @intCast(@divTrunc(runtime.clockMonotonicNanos(), std.time.ns_per_ms));
}

/// `KLIO_CALL_STATS`: per-function invocation counters over the whole run.
var call_stats_state: u8 = 0;

var call_stats_mutex: runtime.SpinMutex = .{};

/// Outer-hop stored-slot field route (tag 3): hop `outer` links, check the
/// destination class identity (low 32 bits), read the slot; returns a retained ref.
pub fn serveOuterSlotRoute(recv: *const Value, name: []const u8, route: u64) ?Value {
    const hops: u64 = (route >> 2) & 63;
    const idx: usize = @intCast((route >> 8) & 0xFFFFFF);
    const want_cls: u32 = @intCast(route >> 32);
    var cur: Value = recv.*;
    var h: u64 = 0;
    while (h < hops) : (h += 1) {
        if (cur != .Instance) return null;
        const g = cur.Instance.borrow();
        const o = g.get().outer;
        g.deinit();
        cur = o orelse return null;
    }
    if (cur != .Instance) return null;
    const g = cur.Instance.borrow();
    defer g.deinit();
    const b = g.get();
    if (@as(u32, @truncate(@as(u64, @intCast(b.class.identity())))) != want_cls) return null;
    if (idx >= b.fields.items.len) return null;
    const f = &b.fields.items[idx];
    if (!std.mem.eql(u8, f.name, name)) return null;
    const v = f.value;
    if (v == .Null or v == .Delegate) return null;
    v.retain();
    return v;
}

var call_stats: ?runtime.NameHashMap(u64) = null;

fn callStatsBump(fqn: []const u8) void {
    callStatsBumpId(fqn, 0, null);
}

/// Census bump keyed by FuncId, so `KLIO_CALL_STATS_LAMBDA` splits `<lambda>`.
pub fn callStatsBumpId(fqn: []const u8, fid: u32, module: ?*const Module) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var key: []const u8 = fqn;
    var buf: [160]u8 = undefined;
    if (fid != 0 and std.mem.eql(u8, fqn, "<lambda>") and lambdaStatsOn()) {
        key = blk: {
            if (module) |m| {
                if (@constCast(m).decl_span.get(fid)) |sp| {
                    if (span.active_map) |am| {
                        if (am.getChecked(sp.file)) |sf| {
                            const lc = sf.lineCol(sp.start);
                            const base = if (std.mem.findScalarLast(u8, sf.path, '/')) |ix| sf.path[ix + 1 ..] else sf.path;
                            break :blk std.fmt.bufPrint(&buf, "<lambda>#{d}[{s}:{d}]", .{ fid, base, lc.line }) catch fqn;
                        }
                    }
                }
            }
            break :blk std.fmt.bufPrint(&buf, "<lambda>#{d}", .{fid}) catch fqn;
        };
    }
    // `KLIO_CALL_STATS_CALLER=<substr>`: a matching fqn also bumps
    // `<fqn>@<caller-fqn>`, attributing the frame to the live interpreted caller.
    var cbuf: [256]u8 = undefined;
    var caller_key: ?[]const u8 = null;
    if (callerStatsFilter()) |substr| {
        if (std.mem.find(u8, key, substr) != null) {
            const cfqn: []const u8 = if (ev_state.evtlsPtr().frame_chain) |fr| fr.func.fqn else "<top>";
            var site_buf: [64]u8 = undefined;
            var site: []const u8 = "";
            if (ev_state.evtlsPtr().frame_chain) |fr| {
                if (fr.cur_span) |sp| {
                    if (span.active_map) |am| {
                        if (am.getChecked(sp.file)) |sf| {
                            const lc = sf.lineCol(sp.start);
                            const base = if (std.mem.findScalarLast(u8, sf.path, '/')) |ix| sf.path[ix + 1 ..] else sf.path;
                            site = std.fmt.bufPrint(&site_buf, "[{s}:{d}]", .{ base, lc.line }) catch "";
                        }
                    }
                }
            }
            caller_key = std.fmt.bufPrint(&cbuf, "{s}@{s}{s}", .{ key, cfqn, site }) catch null;
        }
    }
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = runtime.NameHashMap(u64).init(std.heap.page_allocator);
    callStatsBumpKeyLocked(key);
    if (caller_key) |ck| callStatsBumpKeyLocked(ck);
}

/// Bump one key with the mutex held; a stack-buffer key is duped on insertion.
fn callStatsBumpKeyLocked(key: []const u8) void {
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

fn callerStatsFilter() ?[]const u8 {
    const S = struct {
        var state: u8 = 0;
        var val: []const u8 = "";
    };
    if (S.state == 0) {
        if (runtime.envOnce("KLIO_CALL_STATS_CALLER")) |v| {
            S.val = v;
            S.state = 2;
        } else S.state = 1;
    }
    return if (S.state == 2) S.val else null;
}

fn lambdaStatsOn() bool {
    const S = struct {
        var state: u8 = 0;
    };
    if (S.state == 0) S.state = if (runtime.envOnce("KLIO_CALL_STATS_LAMBDA") != null) 2 else 1;
    return S.state == 2;
}

/// `KLIO_CALL_STATS` tap for slow-ladder GetField; keys are `<gf>Type.name`.
pub fn gfStatsBump(recv: *const Value, name: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "<gf>{s}.{s}", .{ recv.typeFqn(), name }) catch return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = runtime.NameHashMap(u64).init(std.heap.page_allocator);
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

/// `KLIO_CALL_STATS` tap for the slow name ladder; keys `<ladder>Type.name@fn`.
pub fn ladderStatsBump(recv: *const Value, name: []const u8, in_fn: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var buf: [256]u8 = undefined;
    // `typeFqn` reports `<instance>` for an interpreted object, naming nothing.
    const recv_name: []const u8 = if (recv.* == .Instance) blk: {
        const g = recv.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        const nm = cg.get().name;
        break :blk if (nm.len != 0) nm else recv.typeFqn();
    } else recv.typeFqn();
    const key = std.fmt.bufPrint(&buf, "<ladder>{s}.{s}@{s}", .{ recv_name, name, in_fn }) catch return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = runtime.NameHashMap(u64).init(std.heap.page_allocator);
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

/// Host-route sub-tag names for the op profiler; order is the route-index contract.
pub const op_route_names = [_][]const u8{
    "route:member-arg-prep", // 0
    "route:member-flat-prep", // 1
    "route:member-ladder", // 2
    "route:member-ext-fallback", // 3
    "route:member-invoke-fid", // 4
    "route:flat-activation", // 5
    "route:member-stdlib-dispatch", // 6
    "route:recv-fn-field", // 7
    "route:vararg-shadow", // 8
    "route:ir-method-walk", // 9
    "route:member-named-inner", // 10
    "route:ltg-cands", // 11
    "route:ltg-probe", // 12
    "route:ltg-global", // 13
    "route:gf-slow", // 14
    "route:member-cache-probe", // 15
    "route:member-post-stdlib", // 16
    "route:member-positional", // 17
    "route:member-miss-tail", // 18
};

/// `KLIO_OP_PROF` report: map the sampler's per-tag counts to opcode names.
pub fn opProfDump() void {
    const counts = runtime.prof.opProfCounts() orelse return;
    const Entry = struct { name: []const u8, n: u64 };
    var list: [512]Entry = undefined;
    var used: usize = 0;
    var total: u64 = 0;
    const n_tags = @typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields.len;
    for (counts, 0..) |*slot, i| {
        const n = slot.load(.monotonic);
        if (n == 0) continue;
        total += n;
        const name: []const u8 = if (i == runtime.prof.OP_OUTSIDE)
            "<outside-eval>"
        else if (i < n_tags)
            @tagName(@as(@typeInfo(Inst).@"union".tag_type.?, @enumFromInt(i)))
        else if (i >= runtime.prof.OP_ROUTE_BASE and
            i - runtime.prof.OP_ROUTE_BASE < op_route_names.len)
            op_route_names[i - runtime.prof.OP_ROUTE_BASE]
        else
            "<unknown>";
        list[used] = .{ .name = name, .n = n };
        used += 1;
    }
    if (total == 0) return;
    std.mem.sort(Entry, list[0..used], {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[op-prof] {d} samples by opcode:\n", .{total});
    const ft: f64 = @floatFromInt(total);
    for (list[0..used]) |e| {
        const pct = 100.0 * @as(f64, @floatFromInt(e.n)) / ft;
        if (pct < 0.3) break;
        std.debug.print("[op-prof] {d:>6.2}%  {d:>9}  {s}\n", .{ pct, e.n, e.name });
    }
}

/// Probe channel: host dispatch stages report names that miss their caches.
var probe_stats: ?runtime.NameHashMap(u64) = null;

pub fn callStatsProbe(name: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (probe_stats == null) probe_stats = runtime.NameHashMap(u64).init(std.heap.page_allocator);
    const gop = probe_stats.?.getOrPut(name) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

pub fn probeStatsDump() void {
    if (call_stats_state != 2) return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    const stats = &(probe_stats orelse return);
    const Entry = struct { fqn: []const u8, n: u64 };
    var list = std.ArrayList(Entry).initCapacity(std.heap.page_allocator, stats.count()) catch return;
    defer list.deinit(std.heap.page_allocator);
    var it = stats.iterator();
    var total: u64 = 0;
    while (it.next()) |e| {
        list.appendAssumeCapacity(.{ .fqn = e.key_ptr.*, .n = e.value_ptr.* });
        total += e.value_ptr.*;
    }
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[probe-stats] total={d} distinct={d}\n", .{ total, list.items.len });
    const top = @min(list.items.len, 40);
    for (list.items[0..top]) |e| std.debug.print("[probe-stats] {d:>10} {s}\n", .{ e.n, e.fqn });
}

/// `KLIO_DISPATCH_STATS=1`: executed-instruction census over the call forms.
pub const DispatchKind = enum(u8) {
    call_static,
    call_member_resolved,
    call_member_virtual,
    call_virtual_slot,
    call_member_or_global,
    call_value,
    call_member_or_value,
    call_value_or_member,
    call_spread,
    /// Where a name-based member dispatch ended up.
    served_intrinsic,
    served_user_body,
    served_extension,
    /// Sub-tails of the name-based member arm, in the order it tries them.
    member_fast_subscript,
    member_prim_op,
    member_range_iter,
    member_flat_prepare,
    member_ladder,
    /// Slot-bound / lowering-resolved calls served as pushed flat activations.
    virtual_flat_prepare,
    resolved_flat_prepare,
    /// Exact static calls fused by the cached fast plan, split by admission.
    static_flat_fuse,
    static_flat_fuse_ext,
    /// Why an exact static call did NOT reach the fused plan.
    static_decline_named,
    static_decline_plan,
    static_decline_ambig,
    static_decline_arity,
    /// By-name member calls replayed from their instruction-site memo.
    member_site_flat,
    /// Name reads and writes that search the implicit receivers before the global.
    load_this_or_global,
    store_this_or_global,
    /// A field read served from the slot lowering claimed, on its first
    /// execution, without the discovery ladder.
    field_read_claimed_slot,
    /// A read served through the accessor lowering named.
    field_read_getter_named,
    field_read_prop_slot,
    type_instanceof_class,
    type_cast_class,
    /// `EnumClass.Entry` served by the index lowering named.
    field_read_enum_entry,
    /// A write served from the declared slot lowering named, the mirror of
    /// `field_read_claimed_slot`: a plain slot has no setter, so the store is it.
    field_write_claimed_slot,
    /// A field read that reached the host by name, past the site memo.
    field_read_host_by_name,
    /// A builtin property the site named, served from the receiver's tag.
    field_read_builtin,
    /// A member-or-global site whose global leg the link pass proved is the
    /// only one that can win, taken directly.
    call_member_or_global_static,
    /// Every interpreter frame constructed: the denominator for the rest.
    frame_push,
    /// Frames the flattened engine's simple-inst subset can execute end to end.
    frame_push_flattenable,
};

const DISPATCH_KINDS = @typeInfo(DispatchKind).@"enum".fields.len;

/// What each executed dispatch says about resolution. This is the runtime half
/// of the static verdict in `ir/site_census.zig`: the static census says how
/// many SITES re-derive their target, this says how many TIMES one did.
///
/// `bookkeeping` covers counters that are not themselves a dispatch decision —
/// the tails downstream of one, the fusion admissions and declines, and the
/// frame denominators. Counting them in the split would count the same call
/// twice.
pub const DispatchVerdict = enum(u8) { resolved, unresolved, dynamic_by_design, bookkeeping };

const dispatch_verdicts: [DISPATCH_KINDS]DispatchVerdict = blk: {
    var t: [DISPATCH_KINDS]DispatchVerdict = @splat(.bookkeeping);
    const K = DispatchKind;
    t[@intFromEnum(K.call_static)] = .resolved;
    t[@intFromEnum(K.call_member_resolved)] = .resolved;
    t[@intFromEnum(K.call_virtual_slot)] = .resolved;
    t[@intFromEnum(K.call_member_virtual)] = .unresolved;
    t[@intFromEnum(K.call_member_or_global)] = .unresolved;
    t[@intFromEnum(K.call_member_or_value)] = .unresolved;
    t[@intFromEnum(K.call_value_or_member)] = .unresolved;
    // Every `CallSpread` form but the slot-bound one dispatches by name, and the
    // counter does not separate them; the static census does.
    t[@intFromEnum(K.call_spread)] = .unresolved;
    t[@intFromEnum(K.load_this_or_global)] = .unresolved;
    t[@intFromEnum(K.store_this_or_global)] = .unresolved;
    t[@intFromEnum(K.field_read_host_by_name)] = .unresolved;
    t[@intFromEnum(K.field_read_claimed_slot)] = .resolved;
    t[@intFromEnum(K.field_read_getter_named)] = .resolved;
    t[@intFromEnum(K.field_read_prop_slot)] = .resolved;
    t[@intFromEnum(K.type_instanceof_class)] = .resolved;
    t[@intFromEnum(K.type_cast_class)] = .resolved;
    t[@intFromEnum(K.field_read_enum_entry)] = .resolved;
    t[@intFromEnum(K.field_read_builtin)] = .resolved;
    t[@intFromEnum(K.call_member_or_global_static)] = .resolved;
    t[@intFromEnum(K.field_write_claimed_slot)] = .resolved;
    t[@intFromEnum(K.call_value)] = .dynamic_by_design;
    break :blk t;
};

pub fn dispatchVerdictOf(k: DispatchKind) DispatchVerdict {
    return dispatch_verdicts[@intFromEnum(k)];
}

var dispatch_counts: [DISPATCH_KINDS]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));

pub var dispatch_stats_state: u8 = 0;

pub inline fn dispatchBump(comptime k: DispatchKind) void {
    if (dispatch_stats_state == 0) {
        dispatch_stats_state = if (runtime.envOnce("KLIO_DISPATCH_STATS") != null) 2 else 1;
    }
    if (dispatch_stats_state != 2) return;
    _ = dispatch_counts[@intFromEnum(k)].fetchAdd(1, .monotonic);
}

pub fn dispatchNote(comptime k: DispatchKind) void {
    dispatchBump(k);
}

pub fn dispatchStatsDump() void {
    if (dispatch_stats_state != 2) return;
    if (parent.ext_fb_counts) |f| {
        const c = f();
        if (c[0] != 0) std.debug.print(
            "[ext-fb] total={d} plain-hit={d} chain-hit={d} walk={d}\n",
            .{ c[0], c[1], c[2], c[3] },
        );
    }
    var total: u64 = 0;
    for (&dispatch_counts) |*c| total += c.load(.monotonic);
    if (total == 0) return;
    std.debug.print("[dispatch-stats] total={d}\n", .{total});
    if (parent.dispatch_replay_hits) |f| std.debug.print("[dispatch-stats] replay-hits={d}\n", .{f()});
    {
        var by_verdict: [4]u64 = @splat(0);
        inline for (@typeInfo(DispatchKind).@"enum".fields) |f| {
            by_verdict[@intFromEnum(dispatch_verdicts[f.value])] += dispatch_counts[f.value].load(.monotonic);
        }
        var decided: u64 = 0;
        for (by_verdict[0..3]) |n| decided += n;
        inline for (@typeInfo(DispatchVerdict).@"enum".fields) |f| {
            if (f.value < 3) {
                const n = by_verdict[f.value];
                std.debug.print("[dispatch-verdict] {s}={d} ({d:.2}% of {d} decided)\n", .{
                    f.name, n,
                    if (decided == 0) @as(f64, 0) else @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(decided)),
                    decided,
                });
            }
        }
    }
    inline for (@typeInfo(DispatchKind).@"enum".fields) |f| {
        const n = dispatch_counts[f.value].load(.monotonic);
        if (n != 0) std.debug.print("[dispatch-stats] {d:>12} {d:>6.2}%  {s}\n", .{ n, @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total)), f.name });
    }
}

pub fn callStatsDump() void {
    if (call_stats_state != 2) return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    const stats = &(call_stats orelse return);
    const Entry = struct { fqn: []const u8, n: u64 };
    var list = std.ArrayList(Entry).initCapacity(std.heap.page_allocator, stats.count()) catch return;
    defer list.deinit(std.heap.page_allocator);
    var it = stats.iterator();
    var total: u64 = 0;
    while (it.next()) |e| {
        list.appendAssumeCapacity(.{ .fqn = e.key_ptr.*, .n = e.value_ptr.* });
        total += e.value_ptr.*;
    }
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[call-stats] total={d} distinct={d}\n", .{ total, list.items.len });
    const top = @min(list.items.len, 400);
    for (list.items[0..top]) |e| std.debug.print("[call-stats] {d:>10} {s}\n", .{ e.n, e.fqn });
}

pub const FRAME_CENSUS_SLOTS: usize = 1 << 21;

var frame_census: [FRAME_CENSUS_SLOTS]u32 = @splat(0);

pub var frame_census_on: bool = false;

pub fn frameCountInit() void {
    parent.frame_count_on = runtime.envOnce("KLIO_FRAME_COUNT") != null;
    fuse_census_on = runtime.envOnce("KLIO_FUSE_CENSUS") != null;
    if (fuse_census_on) parent.frame_count_on = true;
    if (runtime.envOnce("KLIO_FRAME_WATCH")) |w| {
        parent.frame_watch_want = w;
        parent.frame_count_on = true;
    }
    frame_census_on = runtime.envOnce("KLIO_FRAME_CENSUS") != null;
    if (frame_census_on) parent.frame_count_on = true;
}

pub inline fn frameCensusBump(fid: u32) void {
    if (!frame_census_on) return;
    frame_census[fid & (FRAME_CENSUS_SLOTS - 1)] +%= 1;
}

/// `KLIO_FUSE_CENSUS`: classify every activated body once and tally by verdict.
var fuse_census_on: bool = false;

var fuse_ok_acts: u64 = 0;

var fuse_blocked_acts: u64 = 0;

var fuse_structural_acts: u64 = 0;

var fuse_block_by_tag: [64]u64 = @splat(0);

const FUSE_VERDICT_SLOTS: usize = 1 << 21;

/// 0 = unclassified, 1 = ok, 2 + tag = blocked by that instruction tag,
/// 255 = structural (suspend / catches / too big).
var fuse_verdict: [FUSE_VERDICT_SLOTS]u8 = @splat(0);

fn fuseClassify(func: *const Func) u8 {
    if (func.is_suspend) return 255;
    if (func.blocks.len == 0 or func.blocks.len > 64) return 255;
    if (func.n_locals > 128) return 255;
    var total: usize = 0;
    for (func.blocks) |*b| {
        if (b.h().catches.len != 0 or b.h().finally != null or b.h().lr_absorb != null) return 255;
        total += b.insts.len;
        if (total > 256) return 255;
        switch (b.terminator) {
            .Return, .Goto, .Branch, .Throw, .Unreachable, .Switch => {},
            else => return 255,
        }
        for (b.insts) |*inst| {
            switch (inst.*) {
                .Const, .Move, .LoadParam, .LoadCapture, .BinOp, .UnOp, .Not, .Trace, .GetField, .SetField, .Index, .IndexSet, .Cast, .InstanceOf, .NotNullAssert, .LateinitCheck, .Call, .MakeCell, .CellGet, .CellSet, .QualifiedThis, .EnclosingPush, .EnclosingPop => {},
                else => return 2 + @as(u8, @intFromEnum(std.meta.activeTag(inst.*))),
            }
        }
    }
    return 1;
}

pub inline fn fuseCensusBump(func: *const Func) void {
    if (!fuse_census_on) return;
    const slot = func.id.int() & (FUSE_VERDICT_SLOTS - 1);
    if (fuse_verdict[slot] == 0) fuse_verdict[slot] = fuseClassify(func);
    switch (fuse_verdict[slot]) {
        1 => fuse_ok_acts += 1,
        255 => fuse_structural_acts += 1,
        else => |v| {
            fuse_blocked_acts += 1;
            if (v >= 2 and v - 2 < fuse_block_by_tag.len) fuse_block_by_tag[v - 2] += 1;
        },
    }
}

pub fn frameCountDump(module: *const Module) void {
    if (!parent.frame_count_on) return;
    std.debug.print("[frames] entries={d} activations={d} insts={d}\n", .{ parent.frame_count_total, parent.frame_alloc_total, parent.inst_count_all.load(.monotonic) + parent.inst_count });
    std.debug.print("[call] pre_ms={d} args_ms={d} replay_ms={d} prep_ms={d} probe_ms={d}\n", .{ parent.cm_pre_ns / 1_000_000, parent.cm_args_ns / 1_000_000, parent.cm_replay_ns / 1_000_000, parent.cm_prep_ns / 1_000_000, parent.cm_probe_ns / 1_000_000 });
    std.debug.print("[call] member_arms={d}\n", .{parent.cm_calls});
    std.debug.print("[regs] pool_hit={d} pool_miss={d} filled_slots={d}\n", .{ parent.regs_pool_hit, parent.regs_pool_miss, parent.regs_fill_slots });
    if (frame_census_on) {
        const FE = struct { name: []const u8, n: u32 };
        var fl: std.ArrayList(FE) = .empty;
        defer fl.deinit(std.heap.page_allocator);
        var fid: u32 = 0;
        while (fid < ev_state.fill_census.len) : (fid += 1) {
            const n = ev_state.fill_census[fid];
            if (n == 0) continue;
            const f = module.funcById(@enumFromInt(fid));
            const nm: []const u8 = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "<unknown>";
            fl.append(std.heap.page_allocator, .{ .name = nm, .n = n }) catch break;
        }
        std.mem.sort(FE, fl.items, {}, struct {
            fn gt(_: void, a: FE, b: FE) bool {
                return a.n > b.n;
            }
        }.gt);
        for (fl.items[0..@min(fl.items.len, 12)]) |e| {
            std.debug.print("[fill] {d:>10} {s}\n", .{ e.n, e.name });
        }
    }
    if (fuse_census_on) {
        std.debug.print("[fuse] ok={d} blocked={d} structural={d}\n", .{ fuse_ok_acts, fuse_blocked_acts, fuse_structural_acts });
        const tag_fields = @typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields;
        inline for (tag_fields) |f| {
            if (f.value < fuse_block_by_tag.len and fuse_block_by_tag[f.value] != 0) {
                std.debug.print("[fuse-block] {d:>10} {s}\n", .{ fuse_block_by_tag[f.value], f.name });
            }
        }
    }
    std.debug.print("[getfield] mono={d} getter={d} poly={d} total={d} getter_ms={d} slow_ms={d}\n", .{ parent.gf_mono, parent.gf_getter, parent.gf_poly, parent.gf_slow, parent.gf_getter_ns / 1_000_000, parent.gf_slow_ns / 1_000_000 });
    if (!frame_census_on) return;
    const Entry = struct { name: []const u8, n: u32 };
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(std.heap.page_allocator);
    var fid: u32 = 0;
    while (fid < frame_census.len) : (fid += 1) {
        const n = frame_census[fid];
        if (n == 0) continue;
        const f = module.funcById(@enumFromInt(fid));
        const nm: []const u8 = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "<unknown>";
        list.append(std.heap.page_allocator, .{ .name = nm, .n = n }) catch return;
    }
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    // Package split: how many activations belong to each library group.
    var in_compose: u64 = 0;
    var in_coroutines: u64 = 0;
    var in_accessor: u64 = 0;
    var in_lambda: u64 = 0;
    var in_other: u64 = 0;
    for (list.items) |e| {
        if (std.mem.startsWith(u8, e.name, "androidx.compose")) {
            in_compose += e.n;
        } else if (std.mem.startsWith(u8, e.name, "kotlinx.coroutines")) {
            in_coroutines += e.n;
        } else if (std.mem.startsWith(u8, e.name, "__get_") or
            std.mem.startsWith(u8, e.name, "__set_") or
            std.mem.startsWith(u8, e.name, "__init_prop_") or
            std.mem.startsWith(u8, e.name, "__ext_get_"))
        {
            in_accessor += e.n;
        } else if (std.mem.startsWith(u8, e.name, "<lambda>")) {
            in_lambda += e.n;
        } else {
            in_other += e.n;
        }
    }
    std.debug.print("[census-split] compose={d} accessor={d} lambda={d} coroutines={d} other={d}\n", .{ in_compose, in_accessor, in_lambda, in_coroutines, in_other });
    const top = @min(list.items.len, 300);
    for (list.items[0..top]) |e| std.debug.print("[frames] {d:>9} {s}\n", .{ e.n, e.name });
}

/// First source span of an emitted body, for naming an anonymous function.
fn funcFirstSpan(f: *const ir.Func) ?ir.Span {
    for (f.blocks) |*b| {
        for (b.insts) |*inst| {
            if (inst.* == .Trace) return inst.Trace.span;
        }
    }
    return null;
}

pub fn fnProfDump(module: *const Module) void {
    const counts = runtime.prof.fnProfCounts() orelse return;
    const Entry = struct { name: []const u8, n: u32 };
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(std.heap.page_allocator);
    var total: u64 = 0;
    var fid: u32 = 0;
    while (fid < counts.len) : (fid += 1) {
        const n = counts[fid].load(.monotonic);
        if (n == 0) continue;
        total += n;
        const f = module.funcById(@enumFromInt(fid));
        var nm: []const u8 = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "<unknown>";
        // Every lambda reads `<lambda>`; name it by id and source position instead.
        if (f) |ff| {
            if (std.mem.eql(u8, nm, "<lambda>")) {
                const buf = std.heap.page_allocator.alloc(u8, 160) catch return;
                var site: []const u8 = "";
                var site_buf: [96]u8 = undefined;
                if (ff.blocks.len != 0 and ff.blocks[0].insts.len != 0) {
                    if (funcFirstSpan(ff)) |sp| {
                        if (span.active_map) |am| {
                            if (am.getChecked(sp.file)) |sf| {
                                const lc = sf.lineCol(sp.start);
                                const base = if (std.mem.findScalarLast(u8, sf.path, '/')) |ix| sf.path[ix + 1 ..] else sf.path;
                                site = std.fmt.bufPrint(&site_buf, " {s}:{d}", .{ base, lc.line }) catch "";
                            }
                        }
                    }
                }
                nm = std.fmt.bufPrint(buf, "<lambda>#{d}{s}", .{ fid, site }) catch nm;
            }
        }
        list.append(std.heap.page_allocator, .{ .name = nm, .n = n }) catch return;
    }
    if (total == 0) return;
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[fn-prof] samples={d} distinct={d} (names resolve through ONE module; a pack/anon-module body with the same numeric id reports under the wrong name — verify a surprising item with KLIO_TRACE_PATH or a frame-push count before chasing it)\n", .{ total, list.items.len });
    const top = @min(list.items.len, 40);
    for (list.items[0..top]) |e| {
        const pct = @as(f64, @floatFromInt(e.n)) * 100.0 / @as(f64, @floatFromInt(total));
        std.debug.print("[fn-prof] {d:>7.2}% {d:>8} {s}\n", .{ pct, e.n, e.name });
    }
}

/// Cached `KLIO_ERR_TRACE` presence; racers store the same verdict.
var err_trace_state: u8 = 0;

pub fn errTraceOn() bool {
    if (err_trace_state == 0)
        err_trace_state = if (runtime.envOnce("KLIO_ERR_TRACE") != null) 2 else 1;
    return err_trace_state == 2;
}

pub fn dumpFrameChainForDiag() void {
    if (!errTraceOn()) return;
    dumpCurrentFrameParamsForDiag();
    dumpFrameChainForDiagAlways();
}

pub const FuncLoc = struct { path: []const u8, line: u32 };

/// Declaring location: the span of the func's first `Trace`, via the source map.
pub fn funcFirstLoc(func: *const ir.Func) FuncLoc {
    const fallback: FuncLoc = .{ .path = "?", .line = 0 };
    if (func.blocks.len == 0) return fallback;
    for (func.blocks) |*b| {
        for (b.insts) |*inst| {
            if (inst.* == .Trace) {
                const sp = inst.Trace.span;
                if (span.active_map) |sm| {
                    if (sm.getChecked(sp.file)) |sf| {
                        return .{ .path = sf.path, .line = sf.lineCol(sp.start).line };
                    }
                }
                return fallback;
            }
        }
    }
    return fallback;
}

/// Install the runtime-layer frame-dump hook (idempotent).
pub fn installDebugFrameDump() void {
    runtime.debug_frame_dump = &dumpFrameChainForDiagAlways;
}

/// Ungated frame-chain dump for diagnostics that gate at their own call site.
pub fn dumpFrameChainForDiagAlways() void {
    std.debug.print("[errtrace] frame chain (innermost first):\n", .{});
    var cur = ev_state.evtlsPtr().frame_chain;
    var depth: usize = 0;
    while (cur) |f| : (cur = f.gc_link) {
        const label = if (f.func.fqn.len != 0) f.func.fqn else f.func.name;
        if (f.cur_span) |sp| {
            var printed = false;
            if (span.active_map) |m| {
                if (m.getChecked(sp.file)) |sf| {
                    const lc = sf.lineCol(sp.start);
                    std.debug.print("  {s}#{d} ({s}:{d})\n", .{ label, f.func.id.int(), sf.path, lc.line });
                    printed = true;
                }
            }
            if (!printed) std.debug.print("  {s}#{d} (f{d}@{d})\n", .{ label, f.func.id.int(), @intFromEnum(sp.file), sp.start });
        } else {
            std.debug.print("  {s}#{d}\n", .{ label, f.func.id.int() });
        }
        depth += 1;
        if (depth >= 40) break;
    }
}

/// The innermost frames' declared params with the runtime shape each is bound to.
pub fn dumpCurrentFrameParamsForDiag() void {
    var cur = ev_state.evtlsPtr().frame_chain;
    var depth: usize = 0;
    while (cur) |fr| : (cur = fr.gc_link) {
        if (depth >= 12) break;
        depth += 1;
        const label = if (fr.func.fqn.len != 0) fr.func.fqn else fr.func.name;
        std.debug.print("[frame-params] {s}#{d} ({d} params, {d} bound):\n", .{
            label, fr.func.id.int(), fr.func.params.len, fr.params.items.len,
        });
        for (fr.func.params, 0..) |p, i| {
            if (i >= fr.params.items.len) break;
            const v = &fr.params.items[i];
            std.debug.print("  [{d}] {s} = {s} {s}{s}\n", .{
                i, p.name, @tagName(std.meta.activeTag(v.*)), diagValueClassName(v), diagIdentity(v),
            });
        }
        // A mis-captured callee slot is only visible in the closure environment.
        for (fr.captures.items, 0..) |*cv, i| {
            std.debug.print("  [cap {d}] {s} {s}{s}\n", .{
                i, @tagName(std.meta.activeTag(cv.*)), diagValueClassName(cv), diagIdentity(cv),
            });
        }
    }
}

/// ` @<address>` of an instance, so two frames' receivers can be told apart.
fn diagIdentity(v: *const Value) []const u8 {
    if (v.* != .Instance) return "";
    const S = struct {
        threadlocal var buf: [24]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, " @{x}", .{@intFromPtr(v.Instance.asPtr())}) catch "";
}

/// Concrete runtime class for diagnostics; `typeFqn` alone prints `<instance>`.
fn diagValueClassName(v: *const Value) []const u8 {
    if (v.* == .Instance) {
        const ig = v.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        return cg.get().name;
    }
    return v.typeFqn();
}

pub fn spinDumpMaybe() void {
    if (!spin_interval_read) {
        spin_interval_read = true;
        if (runtime.envOnce("KLIO_SPIN_TRACE")) |v| {
            spin_interval_s = std.fmt.parseInt(i64, v, 10) catch 30;
        }
    }
    const iv = spin_interval_s orelse return;
    const now: i64 = @intCast(runtime.clockMonotonicNanos() / std.time.ns_per_s);
    if (ev_state.evtlsPtr().spin_last_dump == 0) {
        ev_state.evtlsPtr().spin_last_dump = now;
        return;
    }
    if (now - ev_state.evtlsPtr().spin_last_dump < iv) return;
    ev_state.evtlsPtr().spin_last_dump = now;
    std.debug.print("[spin] frame chain (innermost first):\n", .{});
    // Innermost frames' scalar registers: live state of a loop that never ends.
    {
        var rf = ev_state.evtlsPtr().frame_chain;
        var fi: usize = 0;
        while (rf) |f0| : (rf = f0.gc_link) {
            if (fi >= 3) break;
            const n = @min(f0.regs.items.len, 60);
            std.debug.print("  [regs#{d} {s}]", .{ fi, f0.func.name });
            for (f0.regs.items[0..n], 0..) |*v, i| {
                if (!f0.wmask.has(i)) continue;
                switch (v.*) {
                    .Int => |x| std.debug.print(" r{d}=i{d}", .{ i, x }),
                    .Long => |x| std.debug.print(" r{d}=L{d}", .{ i, x }),
                    .Bool => |x| std.debug.print(" r{d}={}", .{ i, x }),
                    else => {},
                }
            }
            std.debug.print("\n", .{});
            fi += 1;
        }
    }
    var cur = ev_state.evtlsPtr().frame_chain;
    var depth: usize = 0;
    while (cur) |f| : (cur = f.gc_link) {
        const label = if (f.func.fqn.len != 0) f.func.fqn else f.func.name;
        if (f.cur_span) |sp| {
            var printed = false;
            if (span.active_map) |m| {
                if (m.getChecked(sp.file)) |sf| {
                    const lc = sf.lineCol(sp.start);
                    std.debug.print("  {s}#{d} ({s}:{d})\n", .{ label, f.func.id.int(), sf.path, lc.line });
                    printed = true;
                }
            }
            if (!printed) std.debug.print("  {s}#{d} (f{d}@{d})\n", .{ label, f.func.id.int(), @intFromEnum(sp.file), sp.start });
        } else {
            std.debug.print("  {s}#{d}\n", .{ label, f.func.id.int() });
        }
        depth += 1;
        if (depth >= 32) {
            std.debug.print("  ...\n", .{});
            break;
        }
    }
}

/// One frame as a trace prints it, its function's Kotlin name and where it
/// is, `pkg.Outer.f(<File>.kt:<line>)`, or `(Unknown Source)` when the
/// position does not resolve. Caller owns the returned slice.
fn frameToString(allocator: Allocator, fr: runtime.StackFrame) Allocator.Error![]u8 {
    if (fr.has_pos) {
        if (span.active_map) |m| {
            if (m.getChecked(span.FileId.from(fr.file_id))) |sf| {
                const file = std.fs.path.basename(sf.path);
                const lc = sf.lineCol(fr.offset);
                return std.fmt.allocPrint(allocator, "{s}({s}:{d})", .{ fr.fqn, file, lc.line });
            }
        }
    }
    return std.fmt.allocPrint(allocator, "{s}(Unknown Source)", .{fr.fqn});
}

pub fn formatStackTrace(allocator: Allocator, trace: *const runtime.StackTraceData, out: *std.ArrayList(u8)) Allocator.Error!void {
    return formatFrames(allocator, trace.frames, out, "");
}

/// `frames`, one per line as `printStackTrace` prints them: `<prefix>\tat
/// <frame>`.
fn formatFrames(allocator: Allocator, frames: []const runtime.StackFrame, out: *std.ArrayList(u8), prefix: []const u8) Allocator.Error!void {
    for (frames) |fr| {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, "\tat ");
        const s = try frameToString(allocator, fr);
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
}

/// The frame's source line, 0 without one.
fn frameLine(fr: runtime.StackFrame) u32 {
    if (!fr.has_pos) return 0;
    const m = span.active_map orelse return 0;
    const sf = m.getChecked(span.FileId.from(fr.file_id)) orelse return 0;
    return sf.lineCol(fr.offset).line;
}

/// Whether two frames are one call site, as `StackTraceElement.equals`
/// compares them: the function, the file and the line.
fn sameFrame(x: runtime.StackFrame, y: runtime.StackFrame) bool {
    if (!std.mem.eql(u8, x.fqn, y.fqn) or x.has_pos != y.has_pos) return false;
    if (!x.has_pos) return true;
    return x.file_id == y.file_id and frameLine(x) == frameLine(y);
}

/// `Throwable.stackTrace`: an `Array` of rendered frames, null when none captured.
pub fn stackTraceArray(allocator: Allocator, v: *const Value) Allocator.Error!?Value {
    const stk: ?runtime.StackRef = switch (v.*) {
        .Exception => |e| if (e.stack) |c| runtime.StackRef{ .cell = c } else null,
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().stack;
        },
        else => null,
    };
    const s = stk orelse return null;
    const sg = s.borrow();
    defer sg.deinit();
    const frames = sg.get().frames;
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(allocator);
    for (frames) |fr| {
        const str = try frameToString(allocator, fr);
        list.append(allocator, .{ .String = try runtime.strInitOwned(allocator, str) }) catch {
            allocator.free(str);
            return error.OutOfMemory;
        };
    }
    return runtime.ArrayData.fromBoxedList(try runtime.ValueList.initOwned(allocator, list));
}

/// Render a throwable in the JVM `printStackTrace` shape: header, frames,
/// `Suppressed:` sections, `Caused by:` chain. A repeat prints CIRCULAR REFERENCE.
pub fn formatThrowable(allocator: Allocator, v: *const Value, out: *std.ArrayList(u8), is_cause: bool, depth: u8) Allocator.Error!void {
    _ = depth;
    if (is_cause) try out.appendSlice(allocator, "\nCaused by: ");
    try formatThrowableWith(allocator, v, out, null);
}

/// Renders a throwable's header line, its `toString()`, for a caller that
/// can run program code; null leaves the class and message.
pub const HeaderRenderer = struct {
    ctx: *anyopaque,
    render: *const fn (ctx: *anyopaque, allocator: Allocator, v: *const Value) Allocator.Error!?[]const u8,
};

/// `formatThrowable`, each header line rendered by `header` when given. A
/// cause's or a suppressed throwable's frames that end the same as its
/// enclosing throwable's print as `... n more`, as the JVM prints them.
pub fn formatThrowableWith(allocator: Allocator, v: *const Value, out: *std.ArrayList(u8), header: ?HeaderRenderer) Allocator.Error!void {
    var deja: std.ArrayList(u64) = .empty;
    defer deja.deinit(allocator);
    try formatThrowableEnclosed(allocator, v, out, .{ .deja = &deja, .header = header }, "", "", &.{}, 0);
}

/// Identity for the dejaVu set; `0` opts out of cycle tracking and prints in full.
fn throwableIdentity(v: *const Value) u64 {
    return switch (v.*) {
        .Exception => |e| e.identity,
        .Instance => |inst| inst.identity(),
        else => 0,
    };
}

fn appendHeader(allocator: Allocator, v: *const Value, out: *std.ArrayList(u8), header: ?HeaderRenderer) Allocator.Error!void {
    if (header) |h| if (try h.render(h.ctx, allocator, v)) |text| {
        try out.appendSlice(allocator, text);
        return;
    };
    try appendThrowableHeader(allocator, v, out);
}

fn appendThrowableHeader(allocator: Allocator, v: *const Value, out: *std.ArrayList(u8)) Allocator.Error!void {
    switch (v.*) {
        .Exception => |e| {
            {
                const fg = e.fqn.borrow();
                defer fg.deinit();
                try out.appendSlice(allocator, fg.get().bytes);
            }
            if (e.message.get()) |m| {
                const mg = m.borrow();
                defer mg.deinit();
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, mg.get().bytes);
            }
        },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            {
                const cg = g.get().class.borrow();
                defer cg.deinit();
                try out.appendSlice(allocator, cg.get().fqn);
            }
            if (g.get().get("message")) |mv| {
                if (mv == .String) {
                    const sg = mv.String.borrow();
                    defer sg.deinit();
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, sg.get().bytes);
                }
            }
        },
        else => try out.appendSlice(allocator, "<thrown value>"),
    }
}

const Rendering = struct {
    deja: *std.ArrayList(u64),
    header: ?HeaderRenderer,
};

/// `<prefix><caption><header>`, then the frames `enclosing` does not end
/// with, then the suppressed throwables and the cause.
fn formatThrowableEnclosed(
    allocator: Allocator,
    v: *const Value,
    out: *std.ArrayList(u8),
    how: Rendering,
    prefix: []const u8,
    caption: []const u8,
    enclosing: []const runtime.StackFrame,
    depth: u8,
) Allocator.Error!void {
    if (depth > 16) return;
    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, caption);
    if (v.* != .Exception and v.* != .Instance) {
        try out.appendSlice(allocator, "<thrown value>");
        return;
    }
    const id = throwableIdentity(v);
    if (id != 0) {
        for (how.deja.items) |seen| {
            if (seen == id) {
                try out.appendSlice(allocator, "[CIRCULAR REFERENCE: ");
                try appendHeader(allocator, v, out, how.header);
                try out.appendSlice(allocator, "]");
                return;
            }
        }
        try how.deja.append(allocator, id);
    }
    try appendHeader(allocator, v, out, how.header);

    var stk: ?runtime.StackRef = null;
    var cause: ?Value = null;
    switch (v.*) {
        .Exception => |e| {
            stk = if (e.stack) |c| runtime.StackRef{ .cell = c } else null;
            if (e.cause) |c| {
                const cg = (runtime.ValueBox{ .cell = c }).borrow();
                defer cg.deinit();
                cause = cg.get().*;
            }
        },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            stk = g.get().stack;
            if (g.get().get("cause")) |cv| {
                if (cv != .Null) cause = cv;
            }
        },
        else => unreachable,
    }
    const sg = if (stk) |st| st.borrow() else null;
    defer if (sg) |g| g.deinit();
    const frames: []const runtime.StackFrame = if (sg) |g| g.get().frames else &.{};
    var m = frames.len;
    var n = enclosing.len;
    while (m > 0 and n > 0 and sameFrame(frames[m - 1], enclosing[n - 1])) {
        m -= 1;
        n -= 1;
    }
    try formatFrames(allocator, frames[0..m], out, prefix);
    if (m != frames.len) {
        const more = try std.fmt.allocPrint(allocator, "\n{s}\t... {d} more", .{ prefix, frames.len - m });
        defer allocator.free(more);
        try out.appendSlice(allocator, more);
    }

    // Suppressed sections, one tab deeper than this throwable.
    var suppressed: std.ArrayList(Value) = .empty;
    defer suppressed.deinit(allocator);
    if (v.* == .Exception) {
        if (v.Exception.suppressed) |sl_cell| {
            const sl = runtime.ValueList{ .cell = sl_cell };
            const g = sl.borrow();
            defer g.deinit();
            for (g.get().items) |s| try suppressed.append(allocator, s);
        }
    }
    if (suppressed.items.len != 0) {
        const inner = try std.fmt.allocPrint(allocator, "{s}\t", .{prefix});
        defer allocator.free(inner);
        for (suppressed.items) |*s| {
            try out.appendSlice(allocator, "\n");
            try formatThrowableEnclosed(allocator, s, out, how, inner, "Suppressed: ", frames, depth + 1);
        }
    }

    if (cause) |c| {
        try out.appendSlice(allocator, "\n");
        try formatThrowableEnclosed(allocator, &c, out, how, prefix, "Caused by: ", frames, depth + 1);
    }
}

/// Attach a captured trace the first time a throwable needs one
/// (`fillInStackTrace`): attach-once, so the construction site survives a re-throw.
pub fn attachStackTrace(allocator: Allocator, v: *Value) Allocator.Error!void {
    switch (v.*) {
        .Exception => |e| {
            if (e.stack != null) return;
            if (try captureStack(allocator)) |s| e.stack = s.cell;
        },
        .Instance => |inst| {
            const g = inst.borrowMut();
            defer g.deinit();
            if (g.get().stack != null) return;
            g.get().stack = try captureStack(allocator);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// The resolution ratchet.
//
// A dispatch that re-derives its target from a name is a site lowering did not
// bind. `KLIO_REQUIRE_RESOLVED` turns that from a cost into a failure, so a
// construct that has been resolved once stays resolved.
//
//   KLIO_REQUIRE_RESOLVED=1      count every name-based resolution, name the
//                                responsible sites, and exit non-zero
//   KLIO_REQUIRE_RESOLVED=raise  raise at the first one instead of serving it
//
// Under `KLIO_DISPATCH_STATS` (or `KLIO_UNRESOLVED_SITES`) the site table is
// collected without failing the run, which is the executed half of the census:
// which name, in which function, re-derived its target and how often.
// ---------------------------------------------------------------------------

/// 0 unread, 1 off, 2 record only, 3 record and fail at exit, 4 raise.
pub var require_resolved_state: u8 = 0;

fn requireResolvedInit() void {
    if (runtime.envOnce("KLIO_REQUIRE_RESOLVED")) |v| {
        if (std.mem.eql(u8, v, "raise")) {
            require_resolved_state = 4;
            return;
        }
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) {
            require_resolved_state = 3;
            return;
        }
    }
    const recording = runtime.envOnce("KLIO_UNRESOLVED_SITES") != null or
        runtime.envOnce("KLIO_DISPATCH_STATS") != null;
    require_resolved_state = if (recording) 2 else 1;
}

/// Whether anything at all wants to hear about a name-based resolution: the
/// single predictable compare the by-name paths pay when nothing does.
pub inline fn ratchetArmed() bool {
    return require_resolved_state != 1;
}

/// Whether a run that resolved anything by name must exit non-zero. Both
/// `KLIO_REQUIRE_RESOLVED` settings fail the run; the recording-only modes that
/// `KLIO_DISPATCH_STATS` turns on do not.
pub fn requireResolvedFails() bool {
    if (require_resolved_state == 0) requireResolvedInit();
    return require_resolved_state >= 3;
}

/// Whether an unresolved dispatch must raise rather than serve the call.
pub fn requireResolvedRaises() bool {
    if (require_resolved_state == 0) requireResolvedInit();
    return require_resolved_state == 4;
}

var unresolved_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var unresolved_sites: ?runtime.NameHashMap(u64) = null;
var unresolved_mutex: runtime.SpinMutex = .{};

/// Count one execution of an unresolved site, and record the site that caused
/// it. `kind` names the site class (a `site_census.SiteKind` tag), `name` the
/// identifier being resolved, `in_fn` the function whose body holds the site,
/// `recv` the receiver's runtime type where there is one.
pub fn unresolvedNoteSlow(kind: []const u8, name: []const u8, in_fn: []const u8, recv: []const u8) void {
    if (require_resolved_state == 0) requireResolvedInit();
    if (require_resolved_state == 1) return;
    _ = unresolved_total.fetchAdd(1, .monotonic);
    var buf: [320]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s} {s}.{s} @{s}", .{ kind, recv, name, in_fn }) catch return;
    unresolved_mutex.lock();
    defer unresolved_mutex.unlock();
    if (unresolved_sites == null) unresolved_sites = runtime.NameHashMap(u64).init(std.heap.page_allocator);
    const gop = unresolved_sites.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

/// One tier's gate on an executing instruction: report an unresolved site and
/// say whether the tier must refuse to serve it. `recv` is the receiver's
/// runtime type where the tier can read it.
///
/// Every interpreter tier calls this over the same classifier, so the executed
/// census covers the tiers by construction rather than by a list of hand-placed
/// hooks that a new tier could miss.
pub fn unresolvedGate(module: *const Module, inst: *const Inst, in_fn: []const u8, recv: []const u8) bool {
    // The first instruction of a run reaches here with the switch unread, since
    // `ratchetArmed` reads one byte and does not pay for the env probe.
    if (require_resolved_state == 0) requireResolvedInit();
    if (require_resolved_state == 1) return false;
    const kind = ir.site_census.refine(module, inst);
    if (ir.site_census.verdictOf(kind) != .unresolved) return false;
    unresolvedNoteSlow(@tagName(kind), ir.site_census.siteName(module, inst), in_fn, recv);
    return requireResolvedRaises();
}

/// The class table refines two site kinds, so a caller that skips it reports a
/// resolved site as unresolved: a construction of a class with one constructor
/// names its target as exactly as a `Call` does.
pub fn isUnresolvedSite(module: *const Module, inst: *const Inst) bool {
    return ir.site_census.verdictOf(ir.site_census.refine(module, inst)) == .unresolved;
}

/// The same gate for a tier that cannot raise. It records and serves when the
/// ratchet is only counting; in raise mode it records nothing and answers true,
/// so the tier declines and the framed walker reports the site exactly once.
pub fn unresolvedTierGate(module: *const Module, inst: *const Inst, in_fn: []const u8, recv: []const u8) bool {
    if (require_resolved_state == 0) requireResolvedInit();
    if (require_resolved_state == 1) return false;
    if (!isUnresolvedSite(module, inst)) return false;
    if (requireResolvedRaises()) return true;
    unresolvedNoteSlow(@tagName(ir.site_census.refine(module, inst)), ir.site_census.siteName(module, inst), in_fn, recv);
    return false;
}

pub fn unresolvedCount() u64 {
    return unresolved_total.load(.monotonic);
}

/// Report the sites that re-derived a target, most frequent first. Returns the
/// total, so a caller can turn `KLIO_REQUIRE_RESOLVED=1` into an exit code.
pub fn unresolvedDump() u64 {
    if (require_resolved_state == 0) requireResolvedInit();
    if (require_resolved_state == 1) return 0;
    const total = unresolved_total.load(.monotonic);
    unresolved_mutex.lock();
    defer unresolved_mutex.unlock();
    const sites = &(unresolved_sites orelse {
        std.debug.print("[unresolved] total=0\n", .{});
        return 0;
    });
    const Entry = struct { key: []const u8, n: u64 };
    var list = std.ArrayList(Entry).initCapacity(std.heap.page_allocator, sites.count()) catch return total;
    defer list.deinit(std.heap.page_allocator);
    var it = sites.iterator();
    while (it.next()) |e| list.appendAssumeCapacity(.{ .key = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(Entry, list.items, {}, struct {
        fn gt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.gt);
    std.debug.print("[unresolved] total={d} distinct={d}\n", .{ total, list.items.len });
    const top = @min(list.items.len, unresolvedTopN());
    for (list.items[0..top]) |e| std.debug.print("[unresolved] {d:>12}  {s}\n", .{ e.n, e.key });
    return total;
}

/// How many site rows `unresolvedDump` prints; `KLIO_UNRESOLVED_SITES=<n>` widens it.
fn unresolvedTopN() usize {
    const S = struct {
        var n: ?usize = null;
    };
    if (S.n) |n| return n;
    var n: usize = 40;
    if (runtime.envOnce("KLIO_UNRESOLVED_SITES")) |v| {
        n = std.fmt.parseInt(usize, v, 10) catch 40;
    }
    S.n = n;
    return n;
}

/// Test hook: force the ratchet's state, bypassing the environment read.
pub fn setRequireResolvedForTest(state: u8) void {
    require_resolved_state = state;
}

test "the ratchet is inert when off" {
    setRequireResolvedForTest(1);
    defer setRequireResolvedForTest(0);
    const before = unresolvedCount();
    unresolvedNoteSlow("call_member_by_name", "size", "kotlin.collections.foo", "List");
    try std.testing.expectEqual(before, unresolvedCount());
    try std.testing.expect(!requireResolvedRaises());
}

test "recording names the site that re-derived a target" {
    setRequireResolvedForTest(2);
    defer {
        setRequireResolvedForTest(0);
        unresolved_total.store(0, .monotonic);
        if (unresolved_sites) |*m| m.clearRetainingCapacity();
    }
    unresolved_total.store(0, .monotonic);
    if (unresolved_sites) |*m| m.clearRetainingCapacity();
    unresolvedNoteSlow("call_member_by_name", "size", "pkg.caller", "List");
    unresolvedNoteSlow("call_member_by_name", "size", "pkg.caller", "List");
    unresolvedNoteSlow("call_member_or_global", "helper", "pkg.caller", "-");
    try std.testing.expectEqual(@as(u64, 3), unresolvedCount());
    unresolved_mutex.lock();
    defer unresolved_mutex.unlock();
    try std.testing.expectEqual(@as(usize, 2), unresolved_sites.?.count());
    try std.testing.expectEqual(@as(u64, 2), unresolved_sites.?.get("call_member_by_name List.size @pkg.caller").?);
}

test "raise mode is distinguishable from counting" {
    setRequireResolvedForTest(4);
    defer setRequireResolvedForTest(0);
    try std.testing.expect(requireResolvedRaises());
    setRequireResolvedForTest(3);
    try std.testing.expect(!requireResolvedRaises());
}

var require_resolved_messages: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// The message a ratchet violation raises with. The throwable borrows the slice,
/// so it is duped; raise mode is a diagnostic run and a program that catches its
/// way past a thousand of them has already answered the question, so past that
/// the message degrades to a shared one rather than growing without bound.
pub fn requireResolvedSiteMessage(module: *const Module, inst: *const Inst, in_fn: []const u8, recv: []const u8) []const u8 {
    return requireResolvedMessage(
        @tagName(ir.site_census.refine(module, inst)),
        ir.site_census.siteName(module, inst),
        recv,
        in_fn,
    );
}

pub fn requireResolvedMessage(what: []const u8, name: []const u8, recv: []const u8, in_fn: []const u8) []const u8 {
    const fixed = "a target resolved by name at run time; bind it at lowering or clear KLIO_REQUIRE_RESOLVED";
    if (require_resolved_messages.fetchAdd(1, .monotonic) >= 1000) return fixed;
    var buf: [384]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{s} `{s}` on {s} in {s} resolved by name at run time; bind it at lowering or clear KLIO_REQUIRE_RESOLVED",
        .{ what, name, recv, in_fn },
    ) catch return fixed;
    return std.heap.page_allocator.dupe(u8, msg) catch fixed;
}

test "every dispatch kind that the ratchet hooks is an unresolved verdict" {
    // The hooks and the verdict table must agree: a kind the by-name paths
    // report must not be counted as resolved work.
    const hooked = [_]DispatchKind{
        .call_member_virtual, .call_member_or_global, .call_member_or_value,
        .call_value_or_member, .load_this_or_global,
        .store_this_or_global, .field_read_host_by_name,
    };
    for (hooked) |k| try std.testing.expectEqual(DispatchVerdict.unresolved, dispatchVerdictOf(k));
    try std.testing.expectEqual(DispatchVerdict.resolved, dispatchVerdictOf(.call_member_resolved));
    try std.testing.expectEqual(DispatchVerdict.resolved, dispatchVerdictOf(.call_virtual_slot));
    try std.testing.expectEqual(DispatchVerdict.resolved, dispatchVerdictOf(.call_static));
    // The tails downstream of a by-name member call are bookkeeping, or the
    // split would count one call as several.
    for ([_]DispatchKind{ .member_ladder, .member_site_flat, .member_fast_subscript, .frame_push }) |k|
        try std.testing.expectEqual(DispatchVerdict.bookkeeping, dispatchVerdictOf(k));
}

/// A one-line rendering of a value for a diagnostic: the tag, plus the payload
/// for the scalars a divergence is usually about.
///
/// `slot` picks one of two per-thread buffers, because the caller that needs
/// this is comparing two values in ONE `print` — with a single buffer the
/// second call overwrites the first and both arguments render the same, which
/// turned a real divergence into "these two identical values differ".
pub fn shortValue(v: *const Value, comptime slot: usize) []const u8 {
    const S = struct {
        threadlocal var bufs: [2][96]u8 = undefined;
    };
    const buf = &S.bufs[slot];
    return switch (v.*) {
        .Int => |x| std.fmt.bufPrint(buf, "Int:{d}", .{x}) catch "Int",
        .Long => |x| std.fmt.bufPrint(buf, "Long:{d}", .{x}) catch "Long",
        .Short => |x| std.fmt.bufPrint(buf, "Short:{d}", .{x}) catch "Short",
        .Byte => |x| std.fmt.bufPrint(buf, "Byte:{d}", .{x}) catch "Byte",
        .Bool => |x| if (x) "Bool:true" else "Bool:false",
        .Double => |x| std.fmt.bufPrint(buf, "Double:{d}", .{x}) catch "Double",
        .Float => |x| std.fmt.bufPrint(buf, "Float:{d}", .{x}) catch "Float",
        .Char => |x| std.fmt.bufPrint(buf, "Char:{d}", .{x}) catch "Char",
        else => @tagName(std.meta.activeTag(v.*)),
    };
}

// ---------------------------------------------------------------------------
// `KLIO_EXT_AUDIT`, per site. The aggregated form of this audit keys on
// (name, receiver head), which merges call sites that see different candidate
// sets: a divergence there proves a commit criterion unsound, but an absence of
// divergence proves nothing. This channel carries the resolver's withheld pick
// from the instruction to the moment the by-name walk serves it, so every
// executed site reports for itself.
// ---------------------------------------------------------------------------

/// The pick the executing tier published for the site it is about to serve, as
/// `FuncId + 1`; 0 means the site carried no stamp. Identity, not the qualified
/// name: `kotlin.time.toDuration` is three declarations under one name, and a
/// comparison by name reports the wrong overload as agreement. The name rides
/// along only so a stamp nothing served can still name itself.
threadlocal var ext_audit_pick: u32 = 0;
threadlocal var ext_audit_fqn: []const u8 = "";
threadlocal var ext_audit_name: []const u8 = "";
threadlocal var ext_audit_in_fn: []const u8 = "";
threadlocal var ext_audit_kind: u8 = 0;

var ext_audit_state: u8 = 0;

/// Whether the per-site extension audit is on. One cached compare, which the
/// member-call arm and each extension serve pay on every call.
pub inline fn extAuditArmed() bool {
    if (ext_audit_state == 0)
        ext_audit_state = if (runtime.envOnce("KLIO_EXT_AUDIT") != null) 2 else 1;
    return ext_audit_state == 2;
}

/// Announce the stamped pick for the call about to be dispatched. A stamp still
/// standing here was never served: the site resolved as a member, a builtin or a
/// host intrinsic instead, which is a fact about coverage rather than a
/// divergence, so it gets its own row.
pub fn extAuditPublish(module: *const Module, pick: ?FuncId, kind: u8, name: []const u8, in_fn: []const u8) void {
    if (ext_audit_pick != 0)
        extAuditRow(ext_audit_name, "not-served", ext_audit_fqn, "-", ext_audit_kind, ext_audit_in_fn);
    const fid = pick orelse {
        ext_audit_pick = 0;
        return;
    };
    ext_audit_pick = fid.int() + 1;
    ext_audit_fqn = if (module.funcById(fid)) |f| f.fqn else "?";
    ext_audit_name = name;
    ext_audit_in_fn = in_fn;
    ext_audit_kind = kind;
}

pub const ExtAuditExpect = struct { fid: FuncId, fqn: []const u8, kind: u8, in_fn: []const u8 };

/// Take the published pick if it was published for this name. Taking clears it:
/// the extension body this serve is about to run resolves extensions of its own,
/// and those belong to their own sites.
pub fn extAuditTake(name: []const u8) ?ExtAuditExpect {
    if (ext_audit_pick == 0) return null;
    if (!std.mem.eql(u8, ext_audit_name, name)) return null;
    const out: ExtAuditExpect = .{
        .fid = @enumFromInt(ext_audit_pick - 1),
        .fqn = ext_audit_fqn,
        .kind = ext_audit_kind,
        .in_fn = ext_audit_in_fn,
    };
    ext_audit_pick = 0;
    return out;
}

/// Compare one serve against the site's stamp. Every route that produces a
/// target for a stamped call reports here, the by-name walk and the memos that
/// replay its verdict alike: the question is whether committing the pick would
/// run the same declaration, not which mechanism found it.
pub fn extAuditServed(module: *const Module, fid: FuncId, name: []const u8) void {
    const exp = extAuditTake(name) orelse return;
    const agree = exp.fid.int() == fid.int();
    const served = if (module.funcById(fid)) |f| f.fqn else "?";
    // Two overloads of one name print the same, so say which declaration when
    // the names collide, by id and by the receiver that separates them;
    // otherwise the row reads as a divergence with no difference in it.
    var buf_w: [256]u8 = undefined;
    var buf_s: [256]u8 = undefined;
    const collide = !agree and std.mem.eql(u8, exp.fqn, served);
    const want = if (collide)
        (std.fmt.bufPrint(&buf_w, "{s}#{d}({s})", .{ exp.fqn, exp.fid.int(), declaredRecvName(module, exp.fid) }) catch exp.fqn)
    else
        exp.fqn;
    const got = if (collide)
        (std.fmt.bufPrint(&buf_s, "{s}#{d}({s})", .{ served, fid.int(), declaredRecvName(module, fid) }) catch served)
    else
        served;
    extAuditRow(name, if (agree) "agree" else "diverge", want, got, exp.kind, exp.in_fn);
}

fn declaredRecvName(module: *const Module, fid: FuncId) []const u8 {
    const f = module.funcById(fid) orelse return "?";
    if (f.params.len == 0) return "-";
    return f.params[0].ty.name;
}

/// One row for one executed site. No join and no aggregation: the sweep counts
/// the verdicts and prints the divergent rows.
pub fn extAuditRow(name: []const u8, verdict: []const u8, lowering: []const u8, served: []const u8, kind: u8, in_fn: []const u8) void {
    std.debug.print("[KLIO_EXT_AUDIT] site name={s} {s} lowering={s} runtime={s} kind={d} in={s}\n", .{
        name, verdict, lowering, served, kind, in_fn,
    });
}
