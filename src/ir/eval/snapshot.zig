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
    /// Try body entry block; matches pop and pending return/rethrow against `Block.finally_done_for`.
    body: BlockId,
    /// The frame's enclosing-receiver chain length at try entry. An exception unwinding out of a spliced
    /// receiver-lambda region skips its `EnclosingPop`, so catch restores the chain to this length.
    chain_len: usize = 0,
    catches: []ir.CatchHandler,
    /// Where to jump to start the finally or first catch; null for a try with only catches.
    finally_entry: ?BlockId,
    /// Post-finally sentinel block; pop and pending return/rethrow key off this, not `finally_entry`.
    finally_done: ?BlockId,
    /// Labeled-return absorption for a splice region (see `ir.LrAbsorb`).
    lr_absorb: ?ir.LrAbsorb = null,
};

const PendingRethrow = struct { key: BlockId, exc: Value, depth: usize };

const PendingReturn = struct { key: BlockId, val: Value, depth: usize };

const PendingUnwind = struct { key: BlockId, err: EvalError, depth: usize };

/// Control flow paused while a `finally` body runs. The active frame owns it so the GC can trace it,
/// and it moves into and out of a frame snapshot when that finally body suspends.
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

/// One paused `evalWithCaptures` activation: enough to re-enter the block loop where it left off.
pub const FrameSnapshot = struct {
    func: FuncId,
    /// The sub-module `func` was lowered into, null for the main module; resume resolves `FuncId` against it.
    module: ?*const Module,
    block: BlockId,
    /// Index of the *next* instruction to run within `block.insts`.
    inst_idx: usize,
    /// Registers live after the suspension point; resume recreates the full file, filling dead slots with Unit.
    regs: SnapshotRegisters,
    params: []Value,
    captures: []Value,
    /// The frame's enclosing-`this` chain (innermost last) at the suspension point, restored verbatim so a
    /// bare member or `this@Outer` inside the body resolves to the same receivers after the park.
    enclosing_this: []EnclosingEntry,
    try_stack: []TryFrame,
    pending_finally: PendingFinallyState = .{},
    is_lambda: bool,
    /// Register the resumed value is written into before execution continues (the suspending call's destination).
    resume_reg: ?Reg,
    /// Closure side-table id of a suspended closure body, rooting the slot and its captures while parked.
    closure_id: ?u64 = null,
    /// A LIVE-parked flat activation, moved by pointer with no copies or retains, so its ownership graph is
    /// what execution left. The slice fields above are then empty and resume goes through `resumeLiveActivation`.
    live: ?*Activation = null,
    /// A COMPILED continuation: the emitted resume function and the heap frame it resumes into. Resuming
    /// calls the function, which answers with the result or `CoroutineSuspended` if it suspended again.
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

/// Per-thread because evaluation and its suspend/resume chain stay on one mutator until an explicit
/// dispatcher handoff. Cleared at the program boundary, before its `Func` pointers can expire.
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

/// Registers readable after `inst_idx` in `block`, by backwards dataflow over the normal CFG. A frame with
/// active catch/finally takes a dense snapshot: exceptional successors are the try stack, not CFG edges.
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

    var ids: std.ArrayList(u32) = .empty;
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

/// One inherited segment of not-yet-resumed outer frame snapshots. A re-suspending activation links its
/// remaining outer snapshots here in O(1) rather than copying them; the next resume consumes the segment.
pub const TailSeg = struct {
    frames: std.ArrayList(FrameSnapshot),
    /// First unconsumed index into `frames`.
    head: usize,
    next: ?*TailSeg,
    /// Fully traced by a prior collection and frozen while parked, so a minor mark skips it; cleared on resume.
    gc_quiesced: bool = false,
};

/// A parked activation: the stack of frame snapshots (outermost first) plus the token that resumes it.
pub const SuspendState = struct {
    token: u64,
    frames: std.ArrayList(FrameSnapshot) = .empty,
    /// Inherited outer segments, innermost-first (resumed after `frames`).
    tails: ?*TailSeg = null,
    /// Opaque resume directive, set by the suspending API and read only by the interceptor. The default
    /// cooperative one reads virtual-time millis: `>= 0` resumes after that long, `< 0` parks until resumed.
    wake_in_millis: i64 = 0,
    /// Set by the suspending call to its destination register; null once a frame snapshot has been pushed.
    pending_resume_reg: ?Reg = null,
    /// Set by the GC once a collection has fully traced this parked state: it is frozen until resume, so a minor
    /// mark skips it. Cleared on every path handing it back to a mutator (take/adopt/resume); majors retrace.
    gc_quiesced: bool = false,

    /// Release every value reference these snapshots retained on suspend and free their slice buffers. Call it
    /// exactly once for a state dropped without resuming; a resume transfers the references into rebuilt frames.
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

    /// Drop one parked entry without resuming it; a live activation owns its registers and is destroyed outright.
    fn dropSnapshot(snap: FrameSnapshot, allocator: Allocator) void {
        // A compiled continuation owns nothing the interpreter allocated; the park registry releases its frame.
        if (snap.native != null) return;
        if (snap.live) |act| {
            destroyParkedActivation(allocator, act);
            return;
        }
        if (runtime.reclaimEnabled()) releaseSnapshotValues(snap, allocator);
        freeSnapshotBuffers(snap, allocator);
    }
};

/// Retain the value references a fresh snapshot copies out of a suspending frame: regs, params and captures,
/// all released by the unwinding stack. The receiver chain is a borrow kept alive by those owners.
pub fn retainSnapshotValues(snap: FrameSnapshot) void {
    if (!runtime.reclaimEnabled()) return;
    switch (snap.regs) {
        .dense => |values| for (values) |v| v.retain(),
        .sparse => |entries| for (entries) |entry| entry.value.retain(),
    }
    for (snap.params) |v| v.retain();
    for (snap.captures) |v| v.retain();
}

/// GC: mark each frame snapshot's `retainSnapshotValues` set plus the receiver chain the parked state keeps.
pub fn gcMarkSuspendState(state: *SuspendState, m: *runtime.gc.Marker) void {
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

/// `runtime.gc.markSuspendHook` thunk: mark a builder continuation held as an opaque `*SuspendState`.
pub fn gcMarkSuspendStateOpaque(cont: *anyopaque, m: *runtime.gc.Marker) void {
    const st: *SuspendState = @ptrCast(@alignCast(cont));
    gcMarkSuspendState(st, m);
}

/// `runtime.gc.freeSuspendHook` thunk: release and free an abandoned builder continuation box.
pub fn freeSuspendStateOpaque(cont: *anyopaque, allocator: Allocator) void {
    const st: *SuspendState = @ptrCast(@alignCast(cont));
    st.deinit(allocator);
    allocator.destroy(st);
}

/// Release what `retainSnapshotValues` retained, mirroring that set exactly.
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

/// The slice buffers a snapshot owns are raw host arrays, not GC cells, so a freeing allocator must free them.
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
