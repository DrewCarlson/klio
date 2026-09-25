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



const parent = @import("../eval.zig");
const ev_chain = @import("chain.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const EvalError = ev_state.EvalError;
const EvalTls = ev_state.EvalTls;
const FlatCallReq = ev_flow.FlatCallReq;
const PendingFinallyState = ev_snapshot.PendingFinallyState;
const acquireRegs = ev_state.acquireRegs;
const cvTraceOn = ev_flow.cvTraceOn;
const frameCensusBump = ev_diag.frameCensusBump;
const fuseCensusBump = ev_diag.fuseCensusBump;
const missTraceWant = ev_flow.missTraceWant;
const regsAlloc = ev_state.regsAlloc;
const releaseArgsIn = ev_state.releaseArgsIn;
const releaseRegs = ev_state.releaseRegs;
const stwAuditOn = ev_state.stwAuditOn;

/// Which register slots a frame has actually written. A no-fill frame keeps whatever its pooled buffer
/// last held, so the collector and anything that materializes the file must know which slots are live.
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

    /// A slot past the tracked range belongs to an eagerly filled frame, so it reads as written.
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

/// Per-call evaluation frame.
pub const Frame = struct {
    module: *const Module,
    func: *const Func,
    regs: std.ArrayList(Value),
    /// Which register slots hold a real value: all-ones for an eagerly Unit-filled file, one bit per write
    /// for a no-fill frame. The collector reads only set slots; `materializeRegs` fills the rest.
    wmask: RegMask,
    params: std.ArrayList(Value),
    captures: std.ArrayList(Value),
    /// The per-method sub-module this frame runs in (anonymous object, local or nested class), null in the
    /// main module. Carried into the snapshot so a suspended method resolves `FuncId` against that module.
    module_arc: ?*const Module,
    allocator: Allocator,
    /// A frame rebuilt by `resumeContinuation` adopts the values its snapshot retained: it owns one reference
    /// to each param and capture and releases them at teardown. A freshly-called frame borrows them.
    owns_params_caps: bool = false,
    /// Intrusive link onto the per-thread GC frame chain (see `evtlsPtr().frame_chain`).
    gc_link: ?*Frame = null,
    /// The closure side-table id when this frame runs a closure body. The body holds only a copy of its capture
    /// values, so the frame re-roots the slot through `markClosureHook`; otherwise a collection sweeps the store.
    closure_id: ?u64 = null,
    /// Out-of-band control-flow payload for `execInst`: it stashes an error, throw, return or suspend here and
    /// returns the one-byte `Step.raised` instead of an `EvalResult`. Read by the dispatch loop only on `.raised`.
    step_err: ?EvalError = null,
    /// Out-of-band payload for `Step.flat_call`, set and consumed within one dispatch step.
    flat_call: ?FlatCallReq = null,
    pending_finally: PendingFinallyState = .{},
    /// The per-thread evaluator state, resolved once when the frame is built: macOS reaches a thread-local
    /// through a call the compiler cannot hoist, so every access site would otherwise pay its own.
    tls: *EvalTls,
    /// Source span of the statement in progress, set by `Trace`, so a captured stack reports each frame's line.
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
            const caller = if (ev_state.evtlsPtr().frame_chain) |fr| (if (fr.func.fqn.len != 0) fr.func.fqn else fr.func.name) else "<none>";
            std.debug.print("[frame-short] fn={s} args={d} params={d} caller={s}\n", .{
                if (func.fqn.len != 0) func.fqn else func.name, params.items.len, func.params.len, caller,
            });
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
        // The reclaim backend releases a register's previous occupant on every write, so its frames stay filled.
        const no_fill = !runtime.reclaimEnabled() and func.frameNoFill();
        if (parent.frame_count_on) {
            frameCensusBump(func.id.int());
            fuseCensusBump(func);
            if (parent.frame_watch_want.len != 0 and std.mem.find(u8, func.name, parent.frame_watch_want) != null) {
                const caller: []const u8 = if (ev_state.evtlsPtr().frame_chain) |fr| fr.func.name else "<top>";
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
            .module_arc = null,
            .allocator = allocator,
            .tls = ev,
        };
    }

    pub fn deinit(self: *Frame) void {
        // `KLIO_GC_STW_AUDIT=1`: tearing a frame down while the world is stopped means the collector is walking
        // this thread's chain right now.
        if (stwAuditOn() and runtime.gc.worldStopped()) {
            const me = runtime.gc.currentTid();
            if (me != runtime.gc.collector_tid.load(.acquire)) {
                if (runtime.gc.blocking_safe_depth == 0) {
                    std.debug.print("[gc-stw] tid={d} collector={d} bs={d} park_depth={d} mut={} mutators={d} parked={d} cpark={d} func={s}\n", .{ me, runtime.gc.collector_tid.load(.acquire), runtime.gc.blocking_safe_depth, runtime.gc.park_depth, runtime.gc.is_mutator, runtime.gc.dbg_mutators.load(.acquire), runtime.gc.dbg_parked.load(.acquire), runtime.gc.dbg_collector_park.load(.acquire), self.func.name });
                    runtime.trace.dumpCurrent(.{});
                }
            }
        }
        // A register owns one reference to its value and releases it at teardown; an escaping value is retained out
        // first, and a suspension retains into the snapshot. `params`/`captures` are borrows, only buffers are freed.
        if (runtime.reclaimEnabled()) {
            for (self.regs.items) |v| v.release(self.allocator);
            if (self.owns_params_caps) {
                for (self.params.items) |v| v.release(self.allocator);
                for (self.captures.items) |v| v.release(self.allocator);
            }
            self.pending_finally.release(self.allocator);
        }
        // Args before regs: `releaseRegs` runs the depth-0 pool drain, so the outermost frame's own carriers must
        // already be pooled. The pools belong to the thread tearing the frame down, not the one that built it.
        const ev: *EvalTls = ev_state.evtlsPtr();
        releaseArgsIn(ev, self.allocator, &self.params);
        releaseArgsIn(ev, self.allocator, &self.captures);
        releaseRegs(ev, self.allocator, &self.regs);
    }

    pub fn read(self: *const Frame, r: Reg) Value {
        const idx = r.int();
        if (idx < self.regs.items.len) return self.regs.items[idx];
        return .Unit;
    }

    /// Store `v` into register `r`, taking ownership of one reference; the previous occupant is released.
    pub fn write(self: *Frame, r: Reg, v: Value) Allocator.Error!void {
        const idx = r.int();
        if (idx >= self.regs.items.len) {
            try self.regs.appendNTimes(regsAlloc(self.allocator), .Unit, idx + 1 - self.regs.items.len);
        }
        // An eagerly-filled frame's mask is already all-ones; a no-fill frame's indices are < 64 by `frameNoFill`.
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

    /// Fill every not-yet-written slot with `Unit` and saturate the mask before the file escapes the masked
    /// world (suspension snapshot, loop JIT, C-native surface, resume rebuild). No-op once saturated.
    pub fn materializeRegs(self: *Frame) void {
        if (self.wmask.isAll()) return;
        for (self.regs.items, 0..) |*v, i| {
            if (!self.wmask.has(i)) v.* = .Unit;
        }
        self.wmask.setAll();
    }
};

/// Pull `n` register values from `args_start` into a fresh slice. Caller frees.
pub fn readArgRun(allocator: Allocator, frame: *const Frame, args_start: Reg, n: u32) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        out[i] = frame.read(Reg.from(args_start.int() + i));
    }
    return out;
}
