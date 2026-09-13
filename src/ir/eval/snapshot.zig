//! Suspend state: register liveness at a suspension point, the frame
//! snapshots a parked coroutine carries, and their GC marking.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BlockId = ir.BlockId;
const Func = ir.Func;
const FuncId = ir.FuncId;
const Module = ir.Module;
const Reg = ir.Reg;

const ev_activation = @import("activation.zig");
const ev_flow = @import("flow.zig");
const ev_state = @import("state.zig");

const Activation = ev_flow.Activation;
const EnclosingEntry = ev_state.EnclosingEntry;
const EvalError = ev_state.EvalError;
const destroyParkedActivation = ev_activation.destroyParkedActivation;
const gcMarkFrameRegs = ev_state.gcMarkFrameRegs;
const markFrameClosure = ev_state.markFrameClosure;

pub const TryFrame = struct {
    /// The try body's entry block — the key for matching pop /
    /// pending-return / pending-rethrow against `Block.finally_done_for`.
    body: BlockId,
    /// The frame's enclosing-receiver chain length at try entry: an
    /// exception unwinding out of a spliced receiver-lambda region skips
    /// its `EnclosingPop`, and a caught throw would otherwise leave the
    /// stale subject on the chain for everything after the catch
    /// (`assertFails { ... }` inside a spliced test-DSL region polluted
    /// every later test in the runner's frame). Restored on catch.
    chain_len: usize = 0,
    catches: []ir.CatchHandler,
    /// Where to jump to start running the finally / first catch.
    /// `null` for a try with only catches and no finally.
    finally_entry: ?BlockId,
    /// The post-finally sentinel block: control reaches this only
    /// after the user finally body has finished, no matter what its
    /// internal control flow looked like. The eval keys its pop /
    /// pending-return / pending-rethrow checks against this rather
    /// than `finally_entry`.
    finally_done: ?BlockId,
    /// Labeled-return absorption for a splice region (see `ir.LrAbsorb`).
    lr_absorb: ?ir.LrAbsorb = null,
};

const PendingRethrow = struct { key: BlockId, exc: Value, depth: usize };

const PendingReturn = struct { key: BlockId, val: Value, depth: usize };

const PendingUnwind = struct { key: BlockId, err: EvalError, depth: usize };

/// Control flow paused while a `finally` body runs. It belongs to the active
/// frame so the GC can trace it, and moves into/out of a frame snapshot when
/// that finally body suspends.
pub const PendingFinallyState = struct {
    rethrow: ?PendingRethrow = null,
    return_value: ?PendingReturn = null,
    unwind: ?PendingUnwind = null,

    pub fn tryDepth(self: PendingFinallyState) ?usize {
        if (self.rethrow) |p| return p.depth;
        if (self.return_value) |p| return p.depth;
        if (self.unwind) |p| return p.depth;
        return null;
    }

    pub fn payloadOfError(err: EvalError) ?Value {
        return switch (err) {
            .Throw => |v| v,
            .NonLocalReturn => |v| v,
            .LabeledReturn => |lr| lr.value,
            else => null,
        };
    }

    pub fn gcMark(self: PendingFinallyState, marker: *runtime.gc.Marker) void {
        if (self.rethrow) |p| p.exc.gcMark(marker);
        if (self.return_value) |p| p.val.gcMark(marker);
        if (self.unwind) |p| if (payloadOfError(p.err)) |v| v.gcMark(marker);
    }

    pub fn release(self: *PendingFinallyState, allocator: Allocator) void {
        if (self.rethrow) |p| p.exc.release(allocator);
        if (self.return_value) |p| p.val.release(allocator);
        if (self.unwind) |p| if (payloadOfError(p.err)) |v| v.release(allocator);
        self.* = .{};
    }
};

/// One paused `evalWithCaptures` activation. Enough to re-enter the
/// block loop exactly where it left off.
pub const FrameSnapshot = struct {
    func: FuncId,
    /// The sub-module this frame's `func` was lowered into, when it is a
    /// per-method sub-module (anonymous object / local / nested class).
    /// `null` for the main module. On resume the `FuncId` is resolved
    /// against this module so the right function body re-enters.
    module: ?*const Module,
    block: BlockId,
    /// Index of the *next* instruction to run within `block.insts`.
    inst_idx: usize,
    /// Register values needed after the suspension point. The resume path
    /// always recreates the full register file, filling dead slots with Unit.
    regs: SnapshotRegisters,
    params: []Value,
    captures: []Value,
    /// The frame's enclosing-`this` chain (innermost last) at the suspension
    /// point. Restored verbatim on resume so implicit-receiver resolution
    /// (bare member / `this@Outer`) inside a receiver-lambda / `with` /
    /// member-extension body sees the same receivers after the park that it saw
    /// before: the chain travels with the parked continuation instead of being
    /// recovered from process-global state the evtls.resuming thread happens to hold.
    enclosing_this: []EnclosingEntry,
    try_stack: []TryFrame,
    pending_finally: PendingFinallyState = .{},
    is_lambda: bool,
    /// Register the resumed value is written into before execution
    /// continues (the destination of the suspending call site).
    resume_reg: ?Reg,
    /// The closure side-table id when the suspended frame is a closure body
    /// (mirrors `Frame.closure_id`). A parked coroutine keeps its closure slot
    /// rooted through this so a collection while it sleeps cannot reclaim the
    /// slot or sweep its capture store.
    closure_id: ?u64 = null,
    /// A LIVE-parked flat activation: the intact frame (registers, params,
    /// captures, try-stack, receiver chain) parked by pointer move with no
    /// copies or retains — the frame's ownership graph is exactly what it was
    /// during execution. When set, the slice fields above are empty and
    /// `block`/`inst_idx`/`resume_reg` describe the resume point; the entry
    /// resumes through `resumeLiveActivation` instead of a frame rebuild.
    live: ?*Activation = null,
    /// A COMPILED continuation: the emitted resume function and the heap frame
    /// it resumes into. A compiled program has no interpreter frames, so when
    /// one of its suspend functions parks it pushes this instead. Resuming it
    /// calls the function; the answer is the result or `CoroutineSuspended`
    /// when it suspended again. Everything above — the driver, the scheduler,
    /// the clock, the Job graph — is shared with the interpreter.
    native: ?runtime.NativeResume = null,
};

const SavedReg = struct {
    id: u32,
    value: Value,
};

pub const SnapshotRegisters = union(enum) {
    dense: []Value,
    sparse: []SavedReg,

    fn byteLen(self: SnapshotRegisters) usize {
        return switch (self) {
            .dense => |values| values.len * @sizeOf(Value),
            .sparse => |entries| entries.len * @sizeOf(SavedReg),
        };
    }

    pub fn ptrIdentity(self: SnapshotRegisters) usize {
        return switch (self) {
            .dense => |values| @intFromPtr(values.ptr),
            .sparse => |entries| @intFromPtr(entries.ptr),
        };
    }

    pub fn savedLen(self: SnapshotRegisters) usize {
        return switch (self) {
            .dense => |values| values.len,
            .sparse => |entries| entries.len,
        };
    }

    pub fn isDense(self: SnapshotRegisters) bool {
        return self == .dense;
    }
};

const SuspendLiveKey = struct {
    func: *const Func,
    block: u32,
    inst_idx: usize,
};

/// Per-thread because evaluation and its suspend/resume chain stay on one
/// mutator until an explicit dispatcher handoff. Each site is analysed once;
/// the cache is cleared at the program boundary before its Func pointers can
/// expire.
threadlocal var suspend_live_cache: std.AutoHashMapUnmanaged(SuspendLiveKey, []u32) = .empty;

threadlocal var suspend_stats_enabled: ?bool = null;

threadlocal var suspend_stats_total: usize = 0;

threadlocal var suspend_stats_dense: usize = 0;

threadlocal var suspend_stats_slots: usize = 0;

threadlocal var suspend_stats_saved: usize = 0;

threadlocal var suspend_stats_params: usize = 0;

threadlocal var suspend_stats_captures: usize = 0;

threadlocal var suspend_stats_receivers: usize = 0;

pub fn noteSuspendSnapshot(dense: bool, total: usize, saved: usize, params: usize, captures: usize, receivers: usize) void {
    const enabled = suspend_stats_enabled orelse blk: {
        const on = runtime.envOnce("KLIO_SUSPEND_STATS") != null;
        suspend_stats_enabled = on;
        break :blk on;
    };
    if (!enabled) return;
    suspend_stats_total += 1;
    suspend_stats_dense += @intFromBool(dense);
    suspend_stats_slots += total;
    suspend_stats_saved += saved;
    suspend_stats_params += params;
    suspend_stats_captures += captures;
    suspend_stats_receivers += receivers;
    if (suspend_stats_total % 50_000 == 0) {
        std.debug.print("[suspend-stats] snapshots={d} dense={d} slots={d} saved={d} params={d} captures={d} receivers={d}\n", .{
            suspend_stats_total,
            suspend_stats_dense,
            suspend_stats_slots,
            suspend_stats_saved,
            suspend_stats_params,
            suspend_stats_captures,
            suspend_stats_receivers,
        });
    }
}

pub fn resetSuspendLivenessCache() void {
    const a = std.heap.c_allocator;
    var it = suspend_live_cache.valueIterator();
    while (it.next()) |ids| a.free(ids.*);
    suspend_live_cache.deinit(a);
    suspend_live_cache = .empty;
    suspend_stats_enabled = null;
    suspend_stats_total = 0;
    suspend_stats_dense = 0;
    suspend_stats_slots = 0;
    suspend_stats_saved = 0;
    suspend_stats_params = 0;
    suspend_stats_captures = 0;
    suspend_stats_receivers = 0;
}

const RegUseDef = struct {
    uses: []bool,
    defs: []bool,

    fn visit(self: *RegUseDef, reg: Reg, is_def: bool) void {
        const i = reg.int();
        if (i >= self.uses.len) return;
        if (is_def) self.defs[i] = true else self.uses[i] = true;
    }

    fn clear(self: *RegUseDef) void {
        @memset(self.uses, false);
        @memset(self.defs, false);
    }
};

fn blockSuccessorLive(func: *const Func, block: *const ir.Block, reg: usize, live_in: []const bool, n_regs: usize) bool {
    const liveAt = struct {
        fn get(bits: []const bool, n: usize, bid: BlockId, r: usize, n_blocks: usize) bool {
            const bi = bid.int();
            return bi < n_blocks and bits[bi * n + r];
        }
    }.get;
    return switch (block.terminator) {
        .Goto => |bid| liveAt(live_in, n_regs, bid, reg, func.blocks.len),
        .Branch => |br| liveAt(live_in, n_regs, br.t, reg, func.blocks.len) or
            liveAt(live_in, n_regs, br.f, reg, func.blocks.len),
        .Switch => |sw| blk: {
            if (liveAt(live_in, n_regs, sw.default, reg, func.blocks.len)) break :blk true;
            for (sw.arms) |arm| {
                if (liveAt(live_in, n_regs, arm.target, reg, func.blocks.len)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Registers whose current values can be read after `inst_idx` in `block`.
/// This is ordinary backwards dataflow over the complete normal CFG. A frame
/// with active catch/finally state deliberately uses a dense snapshot instead:
/// exceptional successors are represented by the runtime try stack rather than
/// explicit CFG edges, so retaining all registers there is the exact fallback.
pub fn suspendLiveRegs(func: *const Func, block: BlockId, inst_idx: usize) Allocator.Error![]const u32 {
    const key: SuspendLiveKey = .{ .func = func, .block = block.int(), .inst_idx = inst_idx };
    if (suspend_live_cache.get(key)) |ids| return ids;

    const a = std.heap.c_allocator;
    const n_blocks = func.blocks.len;
    const n_regs: usize = func.n_locals;
    if (block.int() >= n_blocks or n_regs == 0) {
        const empty = try a.alloc(u32, 0);
        try suspend_live_cache.put(a, key, empty);
        return empty;
    }

    const cells = std.math.mul(usize, n_blocks, n_regs) catch return error.OutOfMemory;
    const use = try a.alloc(bool, cells);
    defer a.free(use);
    const defs = try a.alloc(bool, cells);
    defer a.free(defs);
    const live_in = try a.alloc(bool, cells);
    defer a.free(live_in);
    const live_out = try a.alloc(bool, cells);
    defer a.free(live_out);
    @memset(use, false);
    @memset(defs, false);
    @memset(live_in, false);
    @memset(live_out, false);

    const inst_uses = try a.alloc(bool, n_regs);
    defer a.free(inst_uses);
    const inst_defs = try a.alloc(bool, n_regs);
    defer a.free(inst_defs);
    var ud = RegUseDef{ .uses = inst_uses, .defs = inst_defs };

    for (func.blocks, 0..) |*blk, bi| {
        const base = bi * n_regs;
        for (blk.insts) |*inst| {
            ud.clear();
            ir.visitInstRegs(inst, &ud, RegUseDef.visit);
            for (0..n_regs) |r| {
                if (ud.uses[r] and !defs[base + r]) use[base + r] = true;
                if (ud.defs[r]) defs[base + r] = true;
            }
        }
        ud.clear();
        ir.visitTerminatorRegs(&blk.terminator, &ud, RegUseDef.visit);
        for (0..n_regs) |r| {
            if (ud.uses[r] and !defs[base + r]) use[base + r] = true;
            if (ud.defs[r]) defs[base + r] = true;
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        var bi = n_blocks;
        while (bi > 0) {
            bi -= 1;
            const blk = &func.blocks[bi];
            const base = bi * n_regs;
            for (0..n_regs) |r| {
                const out = blockSuccessorLive(func, blk, r, live_in, n_regs);
                const in = use[base + r] or (out and !defs[base + r]);
                if (live_out[base + r] != out) {
                    live_out[base + r] = out;
                    changed = true;
                }
                if (live_in[base + r] != in) {
                    live_in[base + r] = in;
                    changed = true;
                }
            }
        }
    }

    const live = try a.dupe(bool, live_out[block.int() * n_regs ..][0..n_regs]);
    defer a.free(live);
    const site_block = &func.blocks[block.int()];
    ud.clear();
    ir.visitTerminatorRegs(&site_block.terminator, &ud, RegUseDef.visit);
    for (0..n_regs) |r| {
        if (ud.defs[r]) live[r] = false;
        if (ud.uses[r]) live[r] = true;
    }
    const insts = site_block.insts;
    var i = insts.len;
    const stop = @min(inst_idx, insts.len);
    while (i > stop) {
        i -= 1;
        ud.clear();
        ir.visitInstRegs(&insts[i], &ud, RegUseDef.visit);
        for (0..n_regs) |r| {
            if (ud.defs[r]) live[r] = false;
            if (ud.uses[r]) live[r] = true;
        }
    }

    var ids: std.ArrayListUnmanaged(u32) = .empty;
    errdefer ids.deinit(a);
    for (live, 0..) |is_live, r| {
        if (is_live) try ids.append(a, @intCast(r));
    }
    const owned = try ids.toOwnedSlice(a);
    errdefer a.free(owned);
    try suspend_live_cache.put(a, key, owned);
    return owned;
}

pub fn snapshotRegisters(
    allocator: Allocator,
    func: *const Func,
    block: BlockId,
    next_inst: usize,
    resume_reg: ?Reg,
    regs: []const Value,
    sparse_ok: bool,
) Allocator.Error!SnapshotRegisters {
    if (sparse_ok) {
        const live_ids = try suspendLiveRegs(func, block, next_inst);
        var count: usize = 0;
        for (live_ids) |id| {
            if (id >= regs.len) continue;
            if (resume_reg) |rr| if (id == rr.int()) continue;
            count += 1;
        }
        if (count * @sizeOf(SavedReg) < regs.len * @sizeOf(Value)) {
            const entries = try allocator.alloc(SavedReg, count);
            errdefer allocator.free(entries);
            var out: usize = 0;
            for (live_ids) |id| {
                if (id >= regs.len) continue;
                if (resume_reg) |rr| if (id == rr.int()) continue;
                entries[out] = .{ .id = id, .value = regs[id] };
                out += 1;
            }
            if (runtime.gc.gc_enabled and runtime.gc.external_accounting) {
                runtime.gc.noteExternalBytes(entries.len * @sizeOf(SavedReg));
            }
            return .{ .sparse = entries };
        }
    }

    const values = try allocator.dupe(Value, regs);
    if (runtime.gc.gc_enabled and runtime.gc.external_accounting) {
        runtime.gc.noteExternalBytes(values.len * @sizeOf(Value));
    }
    return .{ .dense = values };
}

/// Layer 1 — a parked activation: a stack of frame snapshots
/// (outermost first, innermost last) plus the token the interceptor
/// uses to resume it. Pure suspend mechanism: it carries no thread,
/// dispatcher, or timing policy of its own.
/// One inherited segment of not-yet-resumed outer frame snapshots. When a
/// resumed activation re-suspends, the remaining outer snapshots are NOT
/// copied into the new state (that copy made deep recursion quadratic —
/// every DeepRecursive level re-copied the whole parked chain); the
/// segment is linked here in O(1) and consumed by the next resume.
pub const TailSeg = struct {
    frames: std.ArrayList(FrameSnapshot),
    /// First unconsumed index into `frames`.
    head: usize,
    next: ?*TailSeg,
    /// Set by the GC after a collection has fully traced this segment: every
    /// cell it references is tenured from then on, and the segment is frozen
    /// (no Value slot is written while parked), so a minor mark skips it.
    /// Cleared whenever the segment becomes live again (promotion into a
    /// resume). Majors always retrace.
    gc_quiesced: bool = false,
};

pub const SuspendState = struct {
    token: u64,
    frames: std.ArrayList(FrameSnapshot) = .empty,
    /// Inherited outer segments, innermost-first (resumed after `frames`).
    tails: ?*TailSeg = null,
    /// Opaque Layer-2 resume directive, set by the suspending API and
    /// interpreted only by the interceptor — never by Layer 1. The
    /// default cooperative interceptor reads it as virtual-time
    /// millis: `>= 0` resumes after that much virtual time, `< 0`
    /// parks indefinitely until an explicit resume.
    wake_in_millis: i64 = 0,
    /// Transient: set by the suspending call instruction to its
    /// destination register, consumed by the enclosing block loop when
    /// it records the frame snapshot. Always `null` once a frame has
    /// been pushed.
    pending_resume_reg: ?Reg = null,
    /// Set by the GC once a collection has fully traced this parked state:
    /// every cell it references is tenured from then on, and the snapshots
    /// are frozen while parked (no Value slot is written until resume), so a
    /// minor mark skips the whole state. Cleared on every path that hands the
    /// state back to a mutator (take/adopt/resume). Majors always retrace.
    gc_quiesced: bool = false,

    /// Release every value reference this state's snapshots retained on
    /// suspend and free the snapshot slice buffers. Call this exactly once
    /// when a parked state is dropped *without* being resumed (a cancelled
    /// or abandoned coroutine) — `resumeContinuation` instead transfers the
    /// retained references into the rebuilt frames. No-op under the arena.
    /// The caller still owns the `frames` ArrayList itself.
    pub fn deinit(self: *SuspendState, allocator: Allocator) void {
        for (self.frames.items) |snap| dropSnapshot(snap, allocator);
        self.frames.deinit(allocator);
        var seg = self.tails;
        self.tails = null;
        while (seg) |t| {
            const next = t.next;
            for (t.frames.items[t.head..]) |snap| dropSnapshot(snap, allocator);
            t.frames.deinit(allocator);
            allocator.destroy(t);
            seg = next;
        }
    }

    /// Drop one parked frame entry without evtls.resuming it: destroy a live
    /// activation outright (it owns its register references), or release
    /// and free a copied snapshot.
    fn dropSnapshot(snap: FrameSnapshot, allocator: Allocator) void {
        // A compiled continuation owns nothing the interpreter allocated: its
        // frame is the native runtime's, released when the park registry drops
        // it.
        if (snap.native != null) return;
        if (snap.live) |act| {
            destroyParkedActivation(allocator, act);
            return;
        }
        if (runtime.reclaimEnabled()) releaseSnapshotValues(snap, allocator);
        freeSnapshotBuffers(snap, allocator);
    }
};

/// Retain the value references a freshly-built snapshot copies out of a
/// suspending frame: regs (the frame owns them and releases them as it
/// unwinds), and params/captures (aliases of caller registers / closure
/// captures that the unwinding stack will release). The receiver chain is a
/// borrow kept alive by those owners, so it is not retained here. No-op
/// under the arena.
pub fn retainSnapshotValues(snap: FrameSnapshot) void {
    if (!runtime.reclaimEnabled()) return;
    switch (snap.regs) {
        .dense => |values| for (values) |v| v.retain(),
        .sparse => |entries| for (entries) |entry| entry.value.retain(),
    }
    for (snap.params) |v| v.retain();
    for (snap.captures) |v| v.retain();
}

/// GC: mark every Value a parked suspend state keeps live — each frame
/// snapshot's regs, params, captures, and enclosing-receiver chain. Mirrors the
/// `retainSnapshotValues` set plus the receiver chain (the GC owns the view of
/// it: a parked continuation is the chain's sole keeper while parked). Driven by
/// the coroutine root provider for every persisted/active parked activation.
pub fn gcMarkSuspendState(state: *SuspendState, m: *runtime.gc.Marker) void {
    // Quiescent skip: a state a prior collection fully traced references only
    // tenured cells and is frozen while parked, so a minor mark has nothing to
    // find in it. A major must retrace (tenured cells are sweep candidates).
    if (m.minor and state.gc_quiesced) return;
    for (state.frames.items) |snap| gcMarkSnapshot(snap, m);
    var seg = state.tails;
    while (seg) |t| : (seg = t.next) {
        if (m.minor and t.gc_quiesced) continue;
        for (t.frames.items[t.head..]) |snap| gcMarkSnapshot(snap, m);
        t.gc_quiesced = true;
    }
    state.gc_quiesced = true;
}

pub fn gcMarkSnapshot(snap: FrameSnapshot, m: *runtime.gc.Marker) void {
    if (snap.live) |act| {
        gcMarkFrameRegs(&act.frame, m);
        for (act.frame.params.items) |v| v.gcMark(m);
        for (act.frame.captures.items) |v| v.gcMark(m);
        for (act.frame.enclosing_this.items) |e| e.v.gcMark(m);
        act.frame.pending_finally.gcMark(m);
        markFrameClosure(act.frame.closure_id, m);
        if (act.keepalive) |ka| ka.gcMark(m);
        return;
    }
    switch (snap.regs) {
        .dense => |values| for (values) |v| v.gcMark(m),
        .sparse => |entries| for (entries) |entry| entry.value.gcMark(m),
    }
    for (snap.params) |v| v.gcMark(m);
    for (snap.captures) |v| v.gcMark(m);
    for (snap.enclosing_this) |e| e.v.gcMark(m);
    snap.pending_finally.gcMark(m);
    markFrameClosure(snap.closure_id, m);
}

/// `runtime.gc.markSuspendHook` thunk: mark a builder continuation held as an
/// opaque `*SuspendState` by a `Sequence`'s `Builder` source.
pub fn gcMarkSuspendStateOpaque(cont: *anyopaque, m: *runtime.gc.Marker) void {
    const st: *SuspendState = @ptrCast(@alignCast(cont));
    gcMarkSuspendState(st, m);
}

/// `runtime.gc.freeSuspendHook` thunk: release and free an abandoned builder
/// continuation box. The frames were never resumed, so their retained snapshot
/// values must be released and the slice buffers freed before the box itself.
pub fn freeSuspendStateOpaque(cont: *anyopaque, allocator: Allocator) void {
    const st: *SuspendState = @ptrCast(@alignCast(cont));
    st.deinit(allocator);
    allocator.destroy(st);
}

/// Release what `retainSnapshotValues` retained (the drop-without-resume
/// path). Mirrors the retain set exactly.
fn releaseSnapshotValues(snap: FrameSnapshot, allocator: Allocator) void {
    switch (snap.regs) {
        .dense => |values| for (values) |v| v.release(allocator),
        .sparse => |entries| for (entries) |entry| entry.value.release(allocator),
    }
    for (snap.params) |v| v.release(allocator);
    for (snap.captures) |v| v.release(allocator);
    var pending = snap.pending_finally;
    pending.release(allocator);
}

/// Free the dupe'd slice buffers a snapshot owns. These are raw host arrays
/// (not GC cells), so the tracing collector never reclaims them — they must be
/// freed explicitly whenever a real freeing allocator is active. Gated on
/// `freeScratch` (reclaim mode or GC on); only the legacy arena fast path,
/// where `free` would rewind a bump pointer, leaves them.
pub fn freeSnapshotBuffers(snap: FrameSnapshot, allocator: Allocator) void {
    if (!runtime.freeScratch()) return;
    if (runtime.gc.gc_enabled and runtime.gc.external_accounting) {
        runtime.gc.noteExternalFreed(snap.regs.byteLen() + (snap.params.len + snap.captures.len) * @sizeOf(Value));
    }
    switch (snap.regs) {
        .dense => |values| allocator.free(values),
        .sparse => |entries| allocator.free(entries),
    }
    allocator.free(snap.params);
    allocator.free(snap.captures);
    allocator.free(snap.enclosing_this);
    allocator.free(snap.try_stack);
}
