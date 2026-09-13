//! Evaluator diagnostics: the wall-clock cap, the call/dispatch/frame
//! censuses, the profiling dumps, and stack-trace and throwable rendering.

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

const parent = @import("../eval.zig");
const ev_flow = @import("flow.zig");
const ev_state = @import("state.zig");

const EvalResult = ev_flow.EvalResult;
const captureStack = ev_state.captureStack;
const errResult = ev_flow.errResult;

/// Append a captured stack trace to `out` as Kotlin-style `\n    at <fqn>
/// (<file>:<line>)` lines, resolving each frame's position through the active
/// source map. Frames with no recorded position (or an unknown file) render
/// without the location suffix. Works uniformly for user, pack, and stdlib
/// frames — every source file is registered in the same map.
/// Render one captured frame as `<fqn> (<file>:<line>)`, or `<fqn> (native)`
/// when its position does not resolve (a runtime-internal / host dispatch point
/// — marked so the gap is intelligible rather than reading as a truncated line).
/// Caller owns the returned slice.
/// `KLIO_SPIN_TRACE=<seconds>` diagnostic: at block boundaries, when the
/// interval has elapsed, print the live frame chain (innermost first, with
/// resolved file:line) to stderr — an execution that never returns names its
/// loop. No effect when the env var is unset.
var spin_interval_s: ?i64 = null;

var spin_interval_read = false;

/// A wall-capped test must DIE, not cascade: without this, the deadline
/// error unwound one coroutine while its siblings kept being resumed
/// against half-torn state (each dying at its own next deadline check) —
/// a resume storm whose half-run `finally` blocks mutated shared state
/// and whose teardown interleavings crashed the process under the GC
/// profile. Raising the drain-everything abandonment stops every thread
/// and coroutine of the dying test at its next block or sleep slice; the
/// test runner clears the flags (after a short grace) before the next
/// test starts.
pub fn wallCapAbandon() void {
    runtime.requestAbandon();
    runtime.setRunBoundaryAbandon(true);
}

/// The wall-cap firing policy. FIRST fire: extend the deadline by an unwind
/// budget and unwind with a CATCHABLE Kotlin exception, so the test's
/// `catch`/`finally` (and the test infra's teardown — a compositionTest
/// disposing its recomposer, a runTest cancelling its children) actually
/// run; the hard `.Type` abort skipped them, and the dead test's globally
/// registered snapshot observers and live compositions contaminated every
/// later test in the class. SECOND fire (teardown itself hung past the
/// budget): the original hard abort + cohort abandonment.
pub fn wallCapFire(allocator: Allocator) Allocator.Error!EvalResult {
    if (!parent.wall_cap_thrown.swap(true, .acq_rel)) {
        const dl = parent.test_wall_deadline_ms.load(.monotonic);
        if (dl != 0) parent.test_wall_deadline_ms.store(dl + 20_000, .monotonic);
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

/// Whether dispatch caches may be populated. A wall-capped or abandoned
/// run produces walks that abort mid-probe; caching their outcomes (a
/// spurious METHOD_MISS, a global-skip note, a wrong field-read route)
/// poisoned every later execution of the same site — after one capped
/// test, whole classes failed `unresolved global` on names that resolve
/// fine in a fresh process (the cross-test contamination family).
/// The runner's per-test invariant probe: a nonzero depth between tests
/// is a leak in some unwind path.
pub fn evalDepthNow() usize {
    return ev_state.evtls.eval_depth;
}

pub fn dispatchCacheStable() bool {
    if (runtime.shouldAbandon()) return false;
    const dl = parent.test_wall_deadline_ms.load(.monotonic);
    return dl == 0 or nowMonotonicMs() <= dl;
}

pub fn nowMonotonicMs() i64 {
    return @intCast(@divTrunc(runtime.clockMonotonicNanos(), std.time.ns_per_ms));
}

/// Diagnostic: print the live frame chain (as the spin tracer does), for an
/// error site that raises a traceless Vm error. Gated by KLIO_ERR_TRACE.
/// KLIO_CALL_STATS: per-function invocation counters over the whole run.
/// `callStatsDump` prints the top entries — the workload census that
/// separates "the interpreter is slow per call" from "the program runs more
/// calls than the reference would" (missed skipping, repeated recompose).
var call_stats_state: u8 = 0;

var call_stats_mutex: runtime.SpinMutex = .{};

/// Serve an outer-hop stored-slot field route (tag 3): hop the receiver's
/// `outer` links, verify the destination's class identity (low 32 bits),
/// then read the indexed slot with the same name/Null/Delegate guards the
/// own-slot route applies. The returned value carries a retained ref.
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

var call_stats: ?std.StringHashMap(u64) = null;

fn callStatsBump(fqn: []const u8) void {
    callStatsBumpId(fqn, 0, null);
}

/// Census bump with the executing FuncId, so the anonymous-lambda mass
/// (every lambda's fqn is the literal "<lambda>") decomposes into
/// per-body counters under KLIO_CALL_STATS_LAMBDA — the id keys resolve
/// back to bodies via `dump-ir --func`.
pub fn callStatsBumpId(fqn: []const u8, fid: u32, module: ?*const Module) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var key: []const u8 = fqn;
    var buf: [160]u8 = undefined;
    if (fid != 0 and std.mem.eql(u8, fqn, "<lambda>") and lambdaStatsOn()) {
        key = blk: {
            // Name the body by its declaration site so the census reads
            // without a dump-ir id correlation step.
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
    // KLIO_CALL_STATS_CALLER=<substr>: a matching fqn additionally bumps
    // `<fqn>@<caller-fqn>`, attributing the frame to the interpreted frame
    // live at activation. This names the dispatch context of census residue
    // whose serve route is unknown.
    var cbuf: [256]u8 = undefined;
    var caller_key: ?[]const u8 = null;
    if (callerStatsFilter()) |substr| {
        if (std.mem.find(u8, key, substr) != null) {
            const cfqn: []const u8 = if (ev_state.evtls.frame_chain) |fr| fr.func.fqn else "<top>";
            // The caller's current span IS the call site — it names which
            // literal/site invoked this body without any id correlation.
            var site_buf: [64]u8 = undefined;
            var site: []const u8 = "";
            if (ev_state.evtls.frame_chain) |fr| {
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
    if (call_stats == null) call_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
    callStatsBumpKeyLocked(key);
    if (caller_key) |ck| callStatsBumpKeyLocked(ck);
}

/// Bump one census key with `call_stats_mutex` already held. The key may
/// point at a stack buffer: the first insertion re-keys with an owned dupe.
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

/// KLIO_CALL_STATS census tap for slow-ladder GetField executions: keys are
/// `<gf>Type.name`, so the dump separates the field-read workload from the
/// call workload.
pub fn gfStatsBump(recv: *const Value, name: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "<gf>{s}.{s}", .{ recv.typeFqn(), name }) catch return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

/// KLIO_CALL_STATS census tap for member calls that reached the slow name
/// ladder: keys are `<ladder>Type.name`, so the dump names exactly which
/// member dispatches are still unbound at runtime on a given workload.
pub fn ladderStatsBump(recv: *const Value, name: []const u8, in_fn: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var buf: [256]u8 = undefined;
    // An interpreted instance reports `<instance>` through `typeFqn`, which
    // names nothing — and the class is the whole point of a ladder split.
    const recv_name: []const u8 = if (recv.* == .Instance) blk: {
        const g = recv.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        const nm = cg.get().name;
        break :blk if (nm.len != 0) nm else recv.typeFqn();
    } else recv.typeFqn();
    // The enclosing function names the SITE: the ladder total is a few hot
    // unbound sites times their execution counts, and per-name rows alone
    // sent the analysis toward the wrong shape.
    const key = std.fmt.bufPrint(&buf, "<ladder>{s}.{s}@{s}", .{ recv_name, name, in_fn }) catch return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

/// Host-route sub-tag names for the op profiler (see `runtime.prof.opRoute`).
/// Order is the route index contract shared with the host dispatch stages.
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

/// KLIO_OP_PROF report: map the runtime sampler's per-tag counts to opcode
/// names and print the distribution. Lives here because only the IR layer
/// can name `Inst` tags.
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

/// Probe channel for the call census: host dispatch stages report the names
/// that miss their caches, prefixed per stage in a second map.
var probe_stats: ?std.StringHashMap(u64) = null;

pub fn callStatsProbe(name: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (probe_stats == null) probe_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
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

/// `KLIO_DISPATCH_STATS=1` — executed-instruction census over the call
/// forms, so the static-dispatch campaign can be planned from counts rather
/// than from the shape of the IR. Every counter is a plain relaxed add on a
/// process-global array; the gate is read once.
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
    call_super,
    ctx_call,
    /// Where a name-based member dispatch ended up, so the campaign knows
    /// whether static binding must target intrinsics or interpreted bodies.
    served_intrinsic,
    served_user_body,
    served_extension,
    /// Sub-tails of the name-based member arm, in the order it tries them.
    member_fast_subscript,
    member_prim_op,
    member_range_iter,
    member_flat_prepare,
    member_ladder,
    /// Slot-bound / lowering-resolved calls served as pushed activations on
    /// the flat driver instead of through the recursive invoker.
    virtual_flat_prepare,
    resolved_flat_prepare,
    /// Exact static calls fused by the cached fast plan, split by whether
    /// the widened receiver-carrying admission served them.
    static_flat_fuse,
    static_flat_fuse_ext,
    /// By-name member calls replayed from their instruction-site memo.
    member_site_flat,
    /// VM-plan P0 baseline: every interpreter frame constructed. P1's
    /// contiguous stack and P2's call fusion drive this denominator down
    /// per call; the compose margin is the external gauge.
    frame_push,
    /// VM-plan P2 coverage: frames whose Func the flattened engine's
    /// simple-inst subset can execute end to end. The ratio to
    /// `frame_push` is the engine's reachable share BEFORE it is built.
    frame_push_flattenable,
};

const DISPATCH_KINDS = @typeInfo(DispatchKind).@"enum".fields.len;

var dispatch_counts: [DISPATCH_KINDS]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));

pub var dispatch_stats_state: u8 = 0;

pub inline fn dispatchBump(comptime k: DispatchKind) void {
    if (dispatch_stats_state == 0) {
        dispatch_stats_state = if (runtime.envOnce("KLIO_DISPATCH_STATS") != null) 2 else 1;
    }
    if (dispatch_stats_state != 2) return;
    _ = dispatch_counts[@intFromEnum(k)].fetchAdd(1, .monotonic);
}

/// Public tap for the host's dispatch tails (see `DispatchKind`).
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
    const top = @min(list.items.len, 60);
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

/// `KLIO_FUSE_CENSUS`: the ceiling measurement for a fused native-bank
/// execution tier. Every activated body is classified once — could a walker
/// with C-stack registers, routed field access and pre-resolved calls run
/// it end to end? — and activations tally by verdict, with the blocking
/// instruction named for the near-misses.
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
        if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return 255;
        total += b.insts.len;
        if (total > 256) return 255;
        switch (b.terminator) {
            .Return, .Goto, .Branch, .Throw, .Unreachable, .Switch => {},
            else => return 255,
        }
        for (b.insts) |*inst| {
            switch (inst.*) {
                .Const, .Move, .LoadParam, .LoadCapture, .BinOp, .UnOp, .Not, .Trace,
                .GetField, .SetField, .Index, .IndexSet, .Cast, .InstanceOf,
                .NotNullAssert, .LateinitCheck, .Call, .MakeCell, .CellGet,
                .CellSet, .QualifiedThis, .EnclosingPush, .EnclosingPop => {},
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
    // Package split for the AOT scoping question: how many activations are
    // bodies an emitted compose set could own outright.
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
    const top = @min(list.items.len, 40);
    for (list.items[0..top]) |e| std.debug.print("[frames] {d:>9} {s}\n", .{ e.n, e.name });
}

/// The first source span an emitted body carries, for naming an anonymous
/// function in a profile.
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
        // A lambda's name says nothing; every one of them reads `<lambda>` and
        // the whole population lands in one bucket. Name it by id and its
        // source position, which is what makes a hot one findable.
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

/// Cached KLIO_ERR_TRACE presence — the flag is read on every dispatch-miss
/// diagnostic path, and `getenvSlice` takes a global mutex per call. The env
/// is set at launch; a mid-run change is not observed (benign data race:
/// both racers store the same verdict).
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

/// Declaring location of a func for the resume diagnostics.
pub const FuncLoc = struct { path: []const u8, line: u32 };

/// Declaring location of a func for the resume diagnostics: the span of
/// its first `Trace` instruction, resolved through the active source map.
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

/// Ungated frame-chain dump for name-filtered diagnostics that gate at
/// their own call site (e.g. `KLIO_MISS_TRACE`).
/// Install the runtime-layer frame-dump hook (idempotent; see
/// `runtime.debug_frame_dump`).
pub fn installDebugFrameDump() void {
    runtime.debug_frame_dump = &dumpFrameChainForDiagAlways;
}

pub fn dumpFrameChainForDiagAlways() void {
    std.debug.print("[errtrace] frame chain (innermost first):\n", .{});
    var cur = ev_state.evtls.frame_chain;
    var depth: usize = 0;
    while (cur) |f| : (cur = f.gc_link) {
        const label = if (f.func.fqn.len != 0) f.func.fqn else f.func.name;
        if (f.cur_span) |sp| {
            var printed = false;
            if (span.active_map) |m| {
                if (m.getChecked(sp.file)) |sf| {
                    const lc = sf.lineCol(sp.start);
                    std.debug.print("  {s} ({s}:{d})\n", .{ label, sf.path, lc.line });
                    printed = true;
                }
            }
            if (!printed) std.debug.print("  {s} (f{d}@{d})\n", .{ label, @intFromEnum(sp.file), sp.start });
        } else {
            std.debug.print("  {s}\n", .{label});
        }
        depth += 1;
        if (depth >= 40) break;
    }
}

/// The innermost frame's declared params with the runtime shape each is
/// bound to. Names an argument-misalignment (e.g. a generated `$composer`
/// slot holding an `Int`) directly instead of leaving it to be inferred
/// from a downstream receiver failure.
pub fn dumpCurrentFrameParamsForDiag() void {
    var cur = ev_state.evtls.frame_chain;
    var depth: usize = 0;
    while (cur) |fr| : (cur = fr.gc_link) {
        if (depth >= 3) break;
        depth += 1;
        const label = if (fr.func.fqn.len != 0) fr.func.fqn else fr.func.name;
        std.debug.print("[frame-params] {s} ({d} params, {d} bound):\n", .{
            label, fr.func.params.len, fr.params.items.len,
        });
        for (fr.func.params, 0..) |p, i| {
            if (i >= fr.params.items.len) break;
            const v = &fr.params.items[i];
            std.debug.print("  [{d}] {s} = {s} {s}\n", .{
                i, p.name, @tagName(std.meta.activeTag(v.*)), diagValueClassName(v),
            });
        }
        // Captures carry a closure's environment; a mis-captured callee
        // slot (`this.LocalFn(...)` binding an Any) is only visible here.
        for (fr.captures.items, 0..) |*cv, i| {
            std.debug.print("  [cap {d}] {s} {s}\n", .{
                i, @tagName(std.meta.activeTag(cv.*)), diagValueClassName(cv),
            });
        }
    }
}

/// The value's concrete runtime class name for diagnostics: an Instance
/// answers its class, everything else its type FQN. `typeFqn` alone prints
/// `<instance>` for interpreted objects, which hides exactly the fact a
/// wrong-receiver diagnosis needs.
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
    if (ev_state.evtls.spin_last_dump == 0) {
        ev_state.evtls.spin_last_dump = now;
        return;
    }
    if (now - ev_state.evtls.spin_last_dump < iv) return;
    ev_state.evtls.spin_last_dump = now;
    std.debug.print("[spin] frame chain (innermost first):\n", .{});
    // Innermost frames' scalar registers — live loop state (probe offsets,
    // masks, bit groups) for a loop that never terminates.
    {
        var rf = ev_state.evtls.frame_chain;
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
    var cur = ev_state.evtls.frame_chain;
    var depth: usize = 0;
    while (cur) |f| : (cur = f.gc_link) {
        const label = if (f.func.fqn.len != 0) f.func.fqn else f.func.name;
        if (f.cur_span) |sp| {
            var printed = false;
            if (span.active_map) |m| {
                if (m.getChecked(sp.file)) |sf| {
                    const lc = sf.lineCol(sp.start);
                    std.debug.print("  {s} ({s}:{d})\n", .{ label, sf.path, lc.line });
                    printed = true;
                }
            }
            if (!printed) std.debug.print("  {s} (f{d}@{d})\n", .{ label, @intFromEnum(sp.file), sp.start });
        } else {
            std.debug.print("  {s}\n", .{label});
        }
        depth += 1;
        if (depth >= 32) {
            std.debug.print("  ...\n", .{});
            break;
        }
    }
}

fn frameToString(allocator: Allocator, fr: runtime.StackFrame) Allocator.Error![]u8 {
    if (fr.has_pos) {
        if (span.active_map) |m| {
            if (m.getChecked(span.FileId.from(fr.file_id))) |sf| {
                const lc = sf.lineCol(fr.offset);
                return std.fmt.allocPrint(allocator, "{s} ({s}:{d})", .{ fr.fqn, sf.path, lc.line });
            }
        }
    }
    return std.fmt.allocPrint(allocator, "{s} (native)", .{fr.fqn});
}

pub fn formatStackTrace(allocator: Allocator, trace: *const runtime.StackTraceData, out: *std.ArrayList(u8)) Allocator.Error!void {
    return formatStackTraceIndented(allocator, trace, out, "");
}

fn formatStackTraceIndented(allocator: Allocator, trace: *const runtime.StackTraceData, out: *std.ArrayList(u8), indent: []const u8) Allocator.Error!void {
    for (trace.frames) |fr| {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "    at ");
        const s = try frameToString(allocator, fr);
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
}

/// Build the `Throwable.stackTrace` value: an `Array` whose elements are the
/// rendered frames (each a `String`, its `StackTraceElement.toString()` form).
/// Returns null for a receiver that carries no captured trace.
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

/// Render a throwable in the JVM `printStackTrace` shape — the
/// `type: message` header, captured frames, `Suppressed:` sections
/// (indented one tab per nesting level), and the `Caused by:` chain — into
/// `out`. A throwable already printed in this rendering appears as
/// `[CIRCULAR REFERENCE: <header>]` and is not walked again.
pub fn formatThrowable(allocator: Allocator, v: *const Value, out: *std.ArrayList(u8), is_cause: bool, depth: u8) Allocator.Error!void {
    _ = depth;
    if (is_cause) try out.appendSlice(allocator, "\nCaused by: ");
    var deja: std.ArrayList(u64) = .empty;
    defer deja.deinit(allocator);
    try formatThrowableEnclosed(allocator, v, out, "", &deja, 0);
}

/// Stable identity for the dejaVu set; 0 (host-created throwables without
/// one) opts out of cycle tracking and always prints in full.
fn throwableIdentity(v: *const Value) u64 {
    return switch (v.*) {
        .Exception => |e| e.identity,
        .Instance => |inst| inst.identity(),
        else => 0,
    };
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

fn formatThrowableEnclosed(
    allocator: Allocator,
    v: *const Value,
    out: *std.ArrayList(u8),
    indent: []const u8,
    deja: *std.ArrayList(u64),
    depth: u8,
) Allocator.Error!void {
    if (depth > 16) return;
    if (v.* != .Exception and v.* != .Instance) {
        try out.appendSlice(allocator, "<thrown value>");
        return;
    }
    const id = throwableIdentity(v);
    if (id != 0) {
        for (deja.items) |seen| {
            if (seen == id) {
                try out.appendSlice(allocator, "[CIRCULAR REFERENCE: ");
                try appendThrowableHeader(allocator, v, out);
                try out.appendSlice(allocator, "]");
                return;
            }
        }
        try deja.append(allocator, id);
    }
    try appendThrowableHeader(allocator, v, out);

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
    if (stk) |s| {
        const sg = s.borrow();
        defer sg.deinit();
        try formatStackTraceIndented(allocator, sg.get(), out, indent);
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
        const inner = try std.fmt.allocPrint(allocator, "{s}\t", .{indent});
        defer allocator.free(inner);
        for (suppressed.items) |*s| {
            try out.appendSlice(allocator, "\n");
            try out.appendSlice(allocator, inner);
            try out.appendSlice(allocator, "Suppressed: ");
            try formatThrowableEnclosed(allocator, s, out, inner, deja, depth + 1);
        }
    }

    if (cause) |c| {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "Caused by: ");
        try formatThrowableEnclosed(allocator, &c, out, indent, deja, depth + 1);
    }
}

/// Attach a freshly-captured stack trace to a throwable the first time it needs
/// one (`fillInStackTrace`): called at construction (matching the JVM) and again
/// at the throw seam as a fallback for host-created throwables. Attach-once, so
/// the construction-site trace wins and a re-throw keeps it. Only
/// `Throwable`-shaped values carry one — a builtin `Exception` value or a user
/// `Throwable`-subclass instance.
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
