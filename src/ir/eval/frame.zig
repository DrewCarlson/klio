//! The evaluator frame: register file, try stack, and frame-local caches.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BlockId = ir.BlockId;
const Func = ir.Func;
const Module = ir.Module;
const Reg = ir.Reg;

const exec_call = @import("../exec_call.zig");

const ownReceiverEntry = exec_call.ownReceiverEntry;
const sameReceiver = exec_call.sameReceiver;

const parent = @import("../eval.zig");
const ev_chain = @import("chain.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const EnclosingEntry = ev_state.EnclosingEntry;
const EvalError = ev_state.EvalError;
const EvalTls = ev_state.EvalTls;
const FlatCallReq = ev_flow.FlatCallReq;
const PendingFinallyState = ev_snapshot.PendingFinallyState;
const acquireRegs = ev_state.acquireRegs;
const chainAcquire = ev_chain.chainAcquire;
const chainAllocator = ev_chain.chainAllocator;
const chainRelease = ev_chain.chainRelease;
const chainTraceOn = ev_flow.chainTraceOn;
const classifyFlattenable = ev_state.classifyFlattenable;
const coerceGenericIntPeersToLong = ev_enter.coerceGenericIntPeersToLong;
const coerceIntArgsToLong = ev_enter.coerceIntArgsToLong;
const coercePlanFor = ev_enter.coercePlanFor;
const cvTraceOn = ev_flow.cvTraceOn;
const dispatchBump = ev_diag.dispatchBump;
const frameCensusBump = ev_diag.frameCensusBump;
const fuseCensusBump = ev_diag.fuseCensusBump;
const missTraceWant = ev_flow.missTraceWant;
const regsAlloc = ev_state.regsAlloc;
const releaseArgsIn = ev_state.releaseArgsIn;
const releaseRegs = ev_state.releaseRegs;
const stwAuditOn = ev_state.stwAuditOn;

/// Per-call evaluation frame.
/// Which register slots a frame has actually written. A no-fill frame keeps
/// whatever its pooled buffer last held, so the collector — and any consumer
/// that materializes the file — must know which slots are live. Four words
/// cover every frame the def-before-use analysis admits.
pub const RegMask = struct {
    pub const WORDS = ir.FRAME_FILL_WORDS;
    pub const CAP: usize = WORDS * 64;

    w: [WORDS]u64,

    pub const none: RegMask = .{ .w = @splat(0) };
    pub const all: RegMask = .{ .w = @splat(~@as(u64, 0)) };

    pub inline fn isAll(self: RegMask) bool {
        for (self.w) |x| {
            if (x != ~@as(u64, 0)) return false;
        }
        return true;
    }

    /// A slot past the tracked range belongs to an eagerly filled frame, so
    /// it reads as written.
    pub inline fn has(self: RegMask, i: usize) bool {
        if (i >= CAP) return true;
        return (self.w[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0;
    }

    pub inline fn set(self: *RegMask, i: usize) void {
        if (i >= CAP) return;
        self.w[i >> 6] |= @as(u64, 1) << @as(u6, @truncate(i));
    }

    pub inline fn setAll(self: *RegMask) void {
        self.w = @splat(~@as(u64, 0));
    }
};

pub const Frame = struct {
    module: *const Module,
    func: *const Func,
    regs: std.ArrayList(Value),
    /// Which register slots hold a real value. All-ones for an eagerly
    /// Unit-filled file (any func without a `frameNoFill` proof, every
    /// reclaim-backend frame, n_locals > 64); for a no-fill frame each
    /// write sets its slot's bit. The collector's frame walk and the spin
    /// dump mark/read only set slots, and `materializeRegs` fills the rest
    /// with `Unit` before the file escapes the masked world (suspension
    /// snapshot, loop JIT, C-native surface, resume rebuild).
    wmask: RegMask,
    params: std.ArrayList(Value),
    captures: std.ArrayList(Value),
    /// The enclosing-`this` chain this frame runs with, innermost last. Seeded
    /// at frame entry from the frame's *lexical* receivers — a closure body's
    /// creation-time snapshot plus whatever the dispatch just pushed for this
    /// call (subject / displaced `this` / member-extension owner) — and
    /// extended by this frame's own pushes for the duration of a sub-call.
    /// Backed by `page_allocator` so any push site (`execInst` here or host
    /// dispatch through `pushAccessEnclosing`) appends through one allocator.
    /// Snapshotted into `FrameSnapshot.enclosing_this` on suspend and restored
    /// verbatim on resume.
    enclosing_this: std.ArrayList(EnclosingEntry),
    /// The `evtls.active_chain` pointer to restore when this frame exits, so a frame
    /// running under a caller frame returns enclosing-`this` resolution to the
    /// caller's chain rather than leaving a dangling pointer.
    prev_chain: ?*std.ArrayList(EnclosingEntry),
    /// The caller's `evtls.active_chain_base`, restored on exit alongside
    /// `prev_chain`.
    prev_chain_base: usize,
    /// The owning module handle when this frame runs in a per-method
    /// *sub-module* (anonymous object / local class / nested
    /// `private`/member class — each lowered into its own `Module`).
    /// `null` for a frame in the main module. Captured into the
    /// frame's `FrameSnapshot` so a suspended sub-module method resumes
    /// by resolving its `FuncId` against the correct module rather than
    /// the main one (which would index a different, wrong function).
    module_arc: ?*const Module,
    allocator: Allocator,
    /// A frame rebuilt by `resumeContinuation` *adopts* the values its
    /// `SuspendState` snapshot retained: it owns one reference to each
    /// param/capture (not just the regs), so its teardown must release them
    /// to balance the retain the snapshot took on suspend. A freshly-called
    /// frame leaves this false — its params/captures are borrows.
    owns_params_caps: bool = false,
    /// Intrusive link onto the per-thread GC frame chain (see `evtls.frame_chain`).
    gc_link: ?*Frame = null,
    /// The closure side-table id when this frame is executing a closure body
    /// (`null` for a plain function / method body). A running closure body holds
    /// only a *copy* of its capture values, not the `IrClosure` value, so without
    /// this the collector would never mark the closure's slot — `reclaimDead`
    /// would recycle its id and its capture-store cell would be swept out from
    /// under a body that spans a collection (a long-running coroutine). The frame
    /// re-roots the slot via `markClosureHook` for as long as it runs.
    closure_id: ?u64 = null,
    /// Out-of-band control-flow payload for the per-instruction executor (see
    /// `Step`): `execInst` stashes any error/throw/return/suspend here and
    /// returns the 1-byte `Step.raised`, instead of returning the ~80-byte
    /// `EvalResult` by value on every instruction (its `.ok` is always the
    /// ignored `.Unit`). Read by the dispatch loop only on `.raised`.
    step_err: ?EvalError = null,
    /// Out-of-band payload for `Step.flat_call`: the resolved direct call the
    /// flat driver should push. Set and consumed within one dispatch step.
    flat_call: ?FlatCallReq = null,
    pending_finally: PendingFinallyState = .{},
    /// The per-thread evaluator state, resolved once when the frame is built.
    /// macOS resolves a thread-local address through a `_tlv_get_addr` call
    /// that the compiler cannot hoist across any other call, so every access
    /// site in a frame-carrying function would otherwise pay its own; the
    /// frame already threads everywhere the state is needed.
    tls: *EvalTls,
    /// Source span of the statement this frame is currently executing, set by
    /// the `Trace` instruction the lowerer emits per statement. Read when a
    /// throw captures the call stack so each frame reports its in-progress
    /// source position (file + line) rather than only its declaration site.
    cur_span: ?ir.Span = null,

    pub fn newWithCaptures(
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        params_in: std.ArrayList(Value),
        captures: std.ArrayList(Value),
    ) Allocator.Error!Frame {
        const params = params_in;
        if (missTraceWant()) |w| {
            if (std.mem.eql(u8, w, func.name) and params.items.len == 4 and func.params.len == 4) {
                std.debug.print("[frame-entry] {s}:", .{func.fqn});
                for (func.params, 0..) |p, i| {
                    const v = &params.items[i];
                    std.debug.print(" {s}={s}", .{ p.name, @tagName(std.meta.activeTag(v.*)) });
                    if (v.* == .Int) std.debug.print(":{d}", .{v.Int});
                    if (v.* == .Long) std.debug.print(":{d}", .{v.Long});
                }
                std.debug.print("\n", .{});
            }
        }
        if (cvTraceOn() and
            params.items.len < func.params.len)
        {
            const caller = if (ev_state.evtls.frame_chain) |fr| (if (fr.func.fqn.len != 0) fr.func.fqn else fr.func.name) else "<none>";
            std.debug.print("[frame-short] fn={s} args={d} params={d} caller={s}\n", .{
                if (func.fqn.len != 0) func.fqn else func.name, params.items.len, func.params.len, caller,
            });
        }
        // The coercion walks trigger only on specific declared param shapes;
        // compute once per func which can ever apply (filled in place under
        // the same benign-race convention as `fast_call`).
        const plan = coercePlanFor(module, func);
        if (plan & 2 != 0) coerceIntArgsToLong(func, params.items);
        if (plan & 4 != 0) coerceGenericIntPeersToLong(module, func, params.items);
        dispatchBump(.frame_push);
        if (ev_diag.dispatch_stats_state == 2) {
            if (func.flat_class == 0) {
                @constCast(func).flat_class = classifyFlattenable(func);
            }
            if (func.flat_class == 1) dispatchBump(.frame_push_flattenable);
        }
        if (runtime.envOnce("KLIO_TRACE_PATH") != null) {
            for (params.items, 0..) |*pv, pi| {
                const payload: i64 = switch (pv.*) {
                    .Int => |x| @as(i64, x),
                    .Char => |x| @as(i64, x),
                    else => -1,
                };
                std.debug.print("[frame-bind] fn={s}#{d} #{d} kind={s} payload={d}\n", .{
                    if (func.fqn.len != 0) func.fqn else func.name,
                    func.id.int(),
                    pi,
                    @tagName(std.meta.activeTag(pv.*)),
                    payload,
                });
            }
        }
        // The reclaim backend releases a register's previous occupant on
        // every write and every slot at teardown, so its frames stay
        // eagerly filled (exactly the leaf serve's rule).
        const no_fill = !runtime.reclaimEnabled() and func.frameNoFill();
        if (parent.frame_count_on) {
            frameCensusBump(func.id.int());
            fuseCensusBump(func);
            if (parent.frame_watch_want.len != 0 and std.mem.find(u8, func.name, parent.frame_watch_want) != null) {
                const caller: []const u8 = if (ev_state.evtls.frame_chain) |fr| fr.func.name else "<top>";
                std.debug.print("[framewatch] {s} <- {s}\n", .{ func.name, caller });
            }
        }
        const regs = try acquireRegs(ev, allocator, func.n_locals, no_fill, func.id.int());
        return .{
            .module = module,
            .func = func,
            .regs = regs,
            .wmask = if (no_fill) RegMask.none else RegMask.all,
            .params = params,
            .captures = captures,
            .enclosing_this = chainAcquire(ev),
            .prev_chain = null,
            .prev_chain_base = 0,
            .module_arc = null,
            .allocator = allocator,
            .tls = ev,
        };
    }

    /// Seed this frame's enclosing-`this` chain and make it the active chain
    /// for the frame's lifetime. Kotlin receiver scope is lexical, so the
    /// seed is NOT the caller's chain: it is `seed` (a closure body's
    /// creation-time snapshot; empty for everything else) followed by the
    /// caller's in-flight pushes — the entries the dispatch placed for this
    /// very call (a receiver-lambda subject, a displaced `this`, a
    /// member-extension owner). `access` entries are dispatch-transient and
    /// never cross the frame boundary.
    pub fn activateChain(self: *Frame, seed: []const EnclosingEntry) Allocator.Error!void {
        if (chainTraceOn()) {
            std.debug.print("[chain] enter tid={d} tls={*} frame={*} caller={*} base={d} fn={s}\n", .{
                std.Thread.getCurrentId(), self.tls, self, self.tls.active_chain, self.tls.active_chain_base, self.func.name,
            });
        }
        for (seed) |e| {
            if (e.kind == .access) continue;
            try self.enclosing_this.append(chainAllocator(), e);
        }
        if (self.tls.active_chain) |caller| {
            for (caller.items[@min(self.tls.active_chain_base, caller.items.len)..]) |e| {
                if (e.kind == .access) continue;
                try self.enclosing_this.append(chainAllocator(), e);
            }
        }
        // A method / extension body's own receiver is the innermost
        // lexical receiver of everything written inside it — seed it onto
        // the frame's chain so a closure created in the body snapshots it
        // (and so dispatch-time visibility filters see it without a
        // per-site push). It is part of the seeded base, never an
        // in-flight push, so it does not leak into callees.
        if (ownReceiverEntry(self.func, self.params.items)) |own| {
            const items = self.enclosing_this.items;
            const dup = items.len > 0 and sameReceiver(items[items.len - 1].v, own.v);
            if (!dup) try self.enclosing_this.append(chainAllocator(), own);
        }
        self.activateAs();
    }

    /// Seed this frame's chain from a saved snapshot slice (resume path) and
    /// make it active.
    pub fn activateChainFrom(self: *Frame, saved: []const EnclosingEntry) Allocator.Error!void {
        try self.enclosing_this.appendSlice(chainAllocator(), saved);
        self.activateAs();
    }

    pub fn activateAs(self: *Frame) void {
        if (chainTraceOn()) {
            std.debug.print("[chain] act tid={d} tls={*} frame={*} list={*} prev={*} base={d} fn={s}\n", .{
                std.Thread.getCurrentId(), self.tls, self, &self.enclosing_this, self.tls.active_chain, self.tls.active_chain_base, self.func.name,
            });
        }
        self.prev_chain = self.tls.active_chain;
        self.prev_chain_base = self.tls.active_chain_base;
        self.tls.active_chain = &self.enclosing_this;
        self.tls.active_chain_base = self.enclosing_this.items.len;
    }

    pub fn deactivateChain(self: *Frame) void {
        if (chainTraceOn()) {
            std.debug.print("[chain] deact tid={d} tls={*} frame={*} restore={*} fn={s}\n", .{
                std.Thread.getCurrentId(), self.tls, self, self.prev_chain, self.func.name,
            });
        }
        self.tls.active_chain = self.prev_chain;
        self.tls.active_chain_base = self.prev_chain_base;
    }

    pub fn deinit(self: *Frame) void {
        // Tripwire (`KLIO_GC_STW_AUDIT=1`): tearing a frame down while the
        // world is stopped means the collector is walking this thread's
        // chain right now — a rendezvous hole, and exactly the shape that
        // makes a mark walk read freed frame buffers.
        if (stwAuditOn() and runtime.gc.worldStopped()) {
            const me = runtime.gc.currentTid();
            if (me != runtime.gc.collector_tid.load(.acquire)) {
                if (runtime.gc.blocking_safe_depth == 0) {
                    std.debug.print("[gc-stw] tid={d} collector={d} bs={d} park_depth={d} mut={} mutators={d} parked={d} cpark={d} func={s}\n", .{ me, runtime.gc.collector_tid.load(.acquire), runtime.gc.blocking_safe_depth, runtime.gc.park_depth, runtime.gc.is_mutator, runtime.gc.dbg_mutators.load(.acquire), runtime.gc.dbg_parked.load(.acquire), runtime.gc.dbg_collector_park.load(.acquire), self.func.name });
                    runtime.trace.dumpCurrent(.{});
                }
            }
        }
        // A register owns one reference to its value; release them all on
        // teardown. The return/escaping value is retained out before this runs,
        // and a suspended frame's registers are retained into its snapshot.
        // `params`/`captures` are borrows — only their buffers are freed here.
        // No-op under the arena fast path.
        if (runtime.reclaimEnabled()) {
            for (self.regs.items) |v| v.release(self.allocator);
            if (self.owns_params_caps) {
                for (self.params.items) |v| v.release(self.allocator);
                for (self.captures.items) |v| v.release(self.allocator);
            }
            self.pending_finally.release(self.allocator);
        }
        // Args before regs: `releaseRegs` runs the depth-0 pool drain, so
        // the outermost frame's own carriers must already be pooled (or
        // they leak past the drain).
        // The pools belong to the thread tearing the frame down, not to the
        // one that built it (see `acquireRegs`): read the running thread once
        // and hand it to each pool.
        const ev: *EvalTls = &ev_state.evtls;
        releaseArgsIn(ev, self.allocator, &self.params);
        releaseArgsIn(ev, self.allocator, &self.captures);
        releaseRegs(ev, self.allocator, &self.regs);
        chainRelease(ev, &self.enclosing_this);
    }

    pub fn read(self: *const Frame, r: Reg) Value {
        const idx = r.int();
        if (idx < self.regs.items.len) return self.regs.items[idx];
        return .Unit;
    }

    /// Store `v` into register `r`, taking ownership of one reference to `v`.
    /// The previous occupant is released. No refcount traffic under the arena.
    pub fn write(self: *Frame, r: Reg, v: Value) Allocator.Error!void {
        const idx = r.int();
        if (idx >= self.regs.items.len) {
            try self.regs.appendNTimes(regsAlloc(self.allocator), .Unit, idx + 1 - self.regs.items.len);
        }
        // For an eagerly-filled frame the mask is already all-ones and the
        // (wrapped) bit is a no-op; a no-fill frame's indices are < 64 by
        // the `frameNoFill` gate.
        self.wmask.set(idx);
        if (runtime.reclaimEnabled()) {
            const old = self.regs.items[idx];
            self.regs.items[idx] = v;
            old.release(self.allocator);
        } else {
            self.regs.items[idx] = v;
        }
    }

    pub fn block(self: *const Frame, b: BlockId) *const ir.Block {
        return &self.func.blocks[b.int()];
    }

    /// Fill every not-yet-written register slot with `Unit` and saturate
    /// the written mask. Called before the register file escapes the
    /// masked world — a suspension snapshot, the loop JIT, the C-native
    /// surface, a resume rebuild — so those consumers see exactly the file
    /// an eagerly-filled frame would carry. No-op once saturated.
    pub fn materializeRegs(self: *Frame) void {
        if (self.wmask.isAll()) return;
        for (self.regs.items, 0..) |*v, i| {
            if (!self.wmask.has(i)) v.* = .Unit;
        }
        self.wmask.setAll();
    }
};
