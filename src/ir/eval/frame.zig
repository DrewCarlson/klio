//! The evaluator frame: a header over a register window and parameter views.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

/// A frame's position at a block's start, before anything in it has run.
pub const block_start = ir.framemap.block_start;

const BlockId = ir.BlockId;
const Func = ir.Func;
const Module = ir.Module;
const Reg = ir.Reg;

const parent = @import("../eval.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const EvalTls = ev_state.EvalTls;
const PendingFinallyState = ev_snapshot.PendingFinallyState;
const VsMark = ev_state.VsMark;
const cvTraceOn = ev_flow.cvTraceOn;
const fillCensusBump = ev_state.fillCensusBump;
const frameCensusBump = ev_diag.frameCensusBump;
const missTraceWant = ev_flow.missTraceWant;
const noteExt = ev_state.noteExt;
const regsAlloc = ev_state.regsAlloc;
const stwAuditOn = ev_state.stwAuditOn;

/// What a frame writes `Unit` to as it opens (`bc.FuncStreams.fill`): the registers a read
/// may find unwritten on some path to it, so that every register live where the frame stands
/// holds a value there; every register for a function no frame map covers, and under the
/// reclaim backend, which releases a register's old occupant on every write.
pub const Fill = struct {
    all: bool,
    regs: []const u32 = &.{},

    pub const everything: Fill = .{ .all = true };

    pub inline fn of(fs: *const ir.bc.FuncStreams) Fill {
        return .{ .all = fs.open.fill_all, .regs = fs.fill };
    }

    pub inline fn apply(self: Fill, window: []Value) void {
        if (self.all) {
            for (window) |*v| v.* = .Unit;
            return;
        }
        for (self.regs) |r| window[r] = .Unit;
    }
};

/// Per-call evaluation frame: a header over its register window and its parameter and capture
/// views. A running frame's window is on its thread's value stack, above the argument area its
/// call pushed if it pushed one; its parameters are a run of its caller's registers or that area.
/// A frame that leaves the stack (a live park, a register write past the window) moves what it
/// uses into one heap block it owns.
pub const Frame = struct {
    module: *const Module,
    func: *const Func,
    /// The registers: those live where the frame stands hold values (`at_block`, `at_idx`);
    /// the rest may hold anything an earlier frame left in the window.
    regs: []Value,
    params: []const Value,
    captures: []const Value,
    /// Where this thread's value stack stood before the frame's argument area and window were pushed;
    /// restoring it pops them. Null once the frame no longer uses the stack.
    vs_mark: ?VsMark,
    /// The heap block holding the parameters, captures and registers of a frame off the stack.
    heap: []Value = &.{},
    /// The per-method sub-module this frame runs in (anonymous object, local or nested class), null in the
    /// main module. Carried into the snapshot so a suspended method resolves `FuncId` against that module.
    module_arc: ?*const Module,
    allocator: Allocator,
    /// A frame rebuilt by `resumeContinuation` adopts the values its snapshot retained: it owns one reference
    /// to each param and capture and releases them at teardown. A freshly-called frame borrows them.
    owns_params_caps: bool = false,
    /// Intrusive link onto the per-thread GC frame chain (see `evtlsPtr().frame_chain`).
    gc_link: ?*Frame = null,
    /// The closure whose body this frame runs. The body holds only a copy of its capture values, and the
    /// closure's cell is its table slot's one holder: the frame roots the cell, so neither the slot nor its
    /// capture store is freed while the body runs, even when nothing else references the closure.
    closure: ?runtime.IrClosureRef = null,
    /// The control flow a running `finally` paused, allocated the first time the frame enters a
    /// finally with one; most frames never do.
    pending: ?*PendingFinallyState = null,
    /// The per-thread evaluator state, resolved once when the frame is built: macOS reaches a thread-local
    /// through a call the compiler cannot hoist, so every access site would otherwise pay its own.
    tls: *EvalTls,
    /// The span the frame's block found as it was entered, for a block whose entry span
    /// differs by path (`spanmap.EntrySpan.dyn`): the edges into such a block, and the frame
    /// loop's routes into a catch or a finally, leave it here.
    cur_span: ?ir.Span = null,
    /// Where the frame stands: the instruction a call, a throw, a host call or a safe point
    /// observes it at, recorded before any of them can, or `block_start`. A collection, a
    /// stack capture and a suspension read what they need from the function's tables at this
    /// position (`FuncStreams.frameMap`); a fresh frame stands at its entry block's start.
    at_block: u32 = 0,
    at_idx: u32 = 0,

    /// Build the frame in place: push its register window on `ev`'s value stack and view `params` and
    /// `captures`, which live in the caller's registers or in the argument area pushed at `area`. The
    /// frame pops back to `area` (or to where the stack stood) when it is torn down.
    pub fn enter(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        params: []const Value,
        captures: []const Value,
        area: ?VsMark,
    ) Allocator.Error!void {
        if (parent.call_hooks_on and (missTraceWant() != null or cvTraceOn() or parent.frame_count_on)) entryDiag(ev, func, params);
        const mark = area orelse ev.vstack.mark();
        const fill = if (runtime.reclaimEnabled()) Fill.everything else fillOf(module, func);
        const n = func.n_locals;
        const window = ev.vstack.push(ev, n) catch |e| {
            ev.vstack.restore(mark);
            return e;
        };
        fill.apply(window);
        if (parent.frame_count_on) {
            const k: u32 = if (fill.all) n else @intCast(fill.regs.len);
            parent.regs_fill_slots += k;
            fillCensusBump(func.id.int(), k);
        }
        self.initFields(ev, allocator, module, func, window, params, captures, mark);
    }

    /// `enter` for a call the stream loop opens: the loop has checked the diagnostic hooks,
    /// and the run's reclaim flag is known where it is compiled.
    pub inline fn enterStream(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        params: []const Value,
        captures: []const Value,
        area: ?VsMark,
        fill: Fill,
        comptime reclaim: bool,
    ) Allocator.Error!void {
        const mark = area orelse ev.vstack.mark();
        const window = ev.vstack.push(ev, func.n_locals) catch |e| {
            ev.vstack.restore(mark);
            return e;
        };
        (if (reclaim) Fill.everything else fill).apply(window);
        self.initFields(ev, allocator, module, func, window, params, captures, mark);
    }

    /// `enterStream` for the frame of an activation the thread's pool gave back, over a
    /// `window` the caller took from the value stack: nothing here can fail or allocate. A
    /// pooled frame has no heap block and no finally pending (every return that pools one
    /// tears them down first, and a fresh activation starts without them), owns none of its
    /// parameters (only a frame rebuilt on a resume does, and none is pooled) and is its
    /// pool's thread's (`actFree`), so those fields stand as they are; the span only a
    /// function whose entry block reads it (`clear_span`) needs cleared. The call's closure,
    /// owning module and the frame below it come in here rather than after, so no field is
    /// written twice.
    pub inline fn enterPooledWindow(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        window: []Value,
        params: []const Value,
        captures: []const Value,
        mark: VsMark,
        fill: Fill,
        closure: ?runtime.IrClosureRef,
        module_arc: ?*const Module,
        gc_link: ?*Frame,
        clear_span: bool,
    ) void {
        std.debug.assert(self.heap.len == 0 and self.pending == null and !self.owns_params_caps and self.tls == ev);
        // A field added to `Frame` is set here too, or stands as a pooled frame leaves it.
        comptime std.debug.assert(std.meta.fields(Frame).len == 17);
        self.module = module;
        self.func = func;
        self.regs = window;
        self.params = params;
        self.captures = captures;
        self.vs_mark = mark;
        self.module_arc = module_arc;
        self.allocator = allocator;
        self.gc_link = gc_link;
        self.closure = closure;
        if (clear_span) self.cur_span = null;
        self.at_block = func.entry.int();
        self.at_idx = block_start;
        fill.apply(window);
    }

    /// `enterPooledWindow` for a call whose shape a compiled site recorded: no captures,
    /// closure or owning module, no register filled, the span left as it stands, and the
    /// entry block given rather than read from `func`.
    pub inline fn enterPooledShaped(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        window: []Value,
        params: []const Value,
        mark: VsMark,
        gc_link: ?*Frame,
        entry_block: u32,
    ) void {
        std.debug.assert(self.heap.len == 0 and self.pending == null and !self.owns_params_caps and self.tls == ev);
        // A field added to `Frame` is set here too, or stands as a pooled frame leaves it.
        comptime std.debug.assert(std.meta.fields(Frame).len == 17);
        self.module = module;
        self.func = func;
        self.regs = window;
        self.params = params;
        self.captures = &.{};
        self.vs_mark = mark;
        self.module_arc = null;
        self.allocator = allocator;
        self.gc_link = gc_link;
        self.closure = null;
        self.at_block = entry_block;
        self.at_idx = block_start;
    }

    /// Every field of a fresh frame over `window`.
    inline fn initFields(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        window: []Value,
        params: []const Value,
        captures: []const Value,
        mark: VsMark,
    ) void {
        // A field added to `Frame` is set here too.
        comptime std.debug.assert(std.meta.fields(Frame).len == 17);
        self.* = .{
            .module = module,
            .func = func,
            .regs = window,
            .params = params,
            .captures = captures,
            .vs_mark = mark,
            .heap = &.{},
            .module_arc = null,
            .allocator = allocator,
            .owns_params_caps = false,
            .gc_link = null,
            .closure = null,
            .pending = null,
            .tls = ev,
            .cur_span = null,
            .at_block = func.entry.int(),
            .at_idx = block_start,
        };
    }

    /// `deinitIn` for a frame the stream loop closes, on the stack of `ev`.
    pub inline fn deinitStream(self: *Frame, ev: *EvalTls, comptime reclaim: bool) void {
        if (reclaim or parent.call_hooks_on) return self.deinitIn(ev);
        self.freePending();
        self.freeHeap(ev);
        if (self.vs_mark) |m| ev.vstack.restore(m);
        self.vs_mark = null;
    }

    /// The tracing knobs a frame entry answers: KLIO_MISS_TRACE, KLIO_CALLVALUE_TRACE, KLIO_FRAME_COUNT.
    noinline fn entryDiag(ev: *EvalTls, func: *const Func, params: []const Value) void {
        if (missTraceWant()) |w| {
            if (std.mem.eql(u8, w, func.name) and params.len == 4 and func.params.len == 4) {
                std.debug.print("[frame-entry] {s}:", .{func.fqn});
                for (func.params, 0..) |p, i| {
                    const v = &params[i];
                    std.debug.print(" {s}={s}", .{ p.name, @tagName(std.meta.activeTag(v.*)) });
                    if (v.* == .Int) std.debug.print(":{d}", .{v.Int});
                    if (v.* == .Long) std.debug.print(":{d}", .{v.Long});
                }
                std.debug.print("\n", .{});
            }
        }
        if (cvTraceOn() and params.len < func.params.len) {
            const caller = if (ev.frame_chain) |fr| (if (fr.func.fqn.len != 0) fr.func.fqn else fr.func.name) else "<none>";
            std.debug.print("[frame-short] fn={s} args={d} params={d} caller={s}\n", .{
                if (func.fqn.len != 0) func.fqn else func.name, params.len, func.params.len, caller,
            });
        }
        if (parent.frame_count_on) {
            parent.frame_alloc_total += 1;
            frameCensusBump(func.id.int());
            if (parent.frame_watch_want.len != 0 and std.mem.find(u8, func.name, parent.frame_watch_want) != null) {
                const caller: []const u8 = if (ev.frame_chain) |fr| fr.func.name else "<top>";
                std.debug.print("[framewatch] {s} <- {s}\n", .{ func.name, caller });
            }
        }
    }

    pub fn deinit(self: *Frame) void {
        self.deinitIn(ev_state.evtlsPtr());
    }

    /// `deinit` against `ev`, the running thread's state: a frame on the value stack is on the stack
    /// of the thread tearing it down.
    pub fn deinitIn(self: *Frame, ev: *EvalTls) void {
        // `KLIO_GC_STW_AUDIT=1`: tearing a frame down while the world is stopped means the collector is walking
        // this thread's chain right now.
        if (parent.call_hooks_on and stwAuditOn() and runtime.gc.worldStopped()) {
            const me = runtime.gc.currentTid();
            if (me != runtime.gc.collector_tid.load(.acquire)) {
                if (runtime.gc.blocking_safe_depth == 0) {
                    std.debug.print("[gc-stw] tid={d} collector={d} bs={d} park_depth={d} mut={} mutators={d} parked={d} cpark={d} func={s}\n", .{ me, runtime.gc.collector_tid.load(.acquire), runtime.gc.blocking_safe_depth, runtime.gc.park_depth, runtime.gc.is_mutator, runtime.gc.dbg_mutators.load(.acquire), runtime.gc.dbg_parked.load(.acquire), runtime.gc.dbg_collector_park.load(.acquire), self.func.name });
                    runtime.trace.dumpCurrent(.{});
                }
            }
        }
        // A register owns one reference to its value and releases it at teardown; an escaping value is retained out
        // first, and a suspension retains into the snapshot. Params and captures are borrows unless adopted.
        if (runtime.reclaimEnabled()) {
            for (self.regs) |v| v.release(self.allocator);
            if (self.owns_params_caps) {
                for (self.params) |v| v.release(self.allocator);
                for (self.captures) |v| v.release(self.allocator);
            }
            self.pfRelease(self.allocator);
        }
        self.owns_params_caps = false;
        self.freePending();
        self.freeHeap(ev);
        if (self.vs_mark) |m| ev.vstack.restore(m);
        self.vs_mark = null;
    }

    /// The paused finally flow, or none.
    pub inline fn pf(self: *const Frame) PendingFinallyState {
        return if (self.pending) |p| p.* else .{};
    }

    /// The paused finally flow to write, its box allocated if the frame has none yet.
    pub fn pfMut(self: *Frame) Allocator.Error!*PendingFinallyState {
        if (self.pending) |p| return p;
        const p = try std.heap.c_allocator.create(PendingFinallyState);
        p.* = .{};
        self.pending = p;
        return p;
    }

    /// Release the paused flow's payloads and clear it; the box stays.
    pub inline fn pfRelease(self: *Frame, allocator: Allocator) void {
        if (self.pending) |p| p.release(allocator);
    }

    /// Adopt a paused flow a snapshot carried.
    pub fn pfSet(self: *Frame, v: PendingFinallyState) Allocator.Error!void {
        if (v.tryDepth() == null and self.pending == null) return;
        (try self.pfMut()).* = v;
    }

    /// Clear the paused flow without releasing it: its payloads moved elsewhere.
    pub inline fn pfForget(self: *Frame) void {
        if (self.pending) |p| p.* = .{};
    }

    inline fn freePending(self: *Frame) void {
        if (self.pending) |p| {
            std.heap.c_allocator.destroy(p);
            self.pending = null;
        }
    }

    inline fn freeHeap(self: *Frame, ev: *EvalTls) void {
        if (self.heap.len != 0) self.freeHeapBlock(ev);
    }

    fn freeHeapBlock(self: *Frame, ev: *EvalTls) void {
        if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting)
            noteExt(ev, -@as(isize, @intCast(self.heap.len * @sizeOf(Value))));
        regsAlloc(self.allocator).free(self.heap);
        self.heap = &.{};
    }

    /// Move the parameters, captures and registers into one heap block the frame owns, so it can
    /// outlive its place on the value stack (a live park), with `n_regs` register slots.
    fn toHeap(self: *Frame, ev: *EvalTls, n_regs: usize) Allocator.Error!void {
        const np = self.params.len;
        const nc = self.captures.len;
        const blk = try regsAlloc(self.allocator).alloc(Value, np + nc + n_regs);
        if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting)
            noteExt(ev, @intCast(blk.len * @sizeOf(Value)));
        @memcpy(blk[0..np], self.params);
        @memcpy(blk[np..][0..nc], self.captures);
        const regs = blk[np + nc ..];
        const keep = @min(self.regs.len, n_regs);
        @memcpy(regs[0..keep], self.regs[0..keep]);
        @memset(regs[keep..], .Unit);
        self.freeHeap(ev);
        self.heap = blk;
        self.params = blk[0..np];
        self.captures = blk[np..][0..nc];
        self.regs = regs;
    }

    /// Take the frame off `ev`'s value stack before the slots it used there are reused. Everything
    /// pushed after it must already be gone. No-op for a frame already off the stack.
    pub fn leaveStack(self: *Frame, ev: *EvalTls) Allocator.Error!void {
        const m = self.vs_mark orelse return;
        if (self.heap.len == 0) try self.toHeap(ev, self.regs.len);
        ev.vstack.restore(m);
        self.vs_mark = null;
    }

    pub inline fn read(self: *const Frame, r: Reg) Value {
        const idx = r.int();
        if (idx < self.regs.len) return self.regs[idx];
        return .Unit;
    }

    /// Store `v` into register `r`, taking ownership of one reference; the previous occupant is released.
    pub inline fn write(self: *Frame, r: Reg, v: Value) Allocator.Error!void {
        const idx = r.int();
        if (idx >= self.regs.len) try self.growRegs(idx);
        if (runtime.reclaimEnabled()) {
            const old = self.regs[idx];
            self.regs[idx] = v;
            old.release(self.allocator);
        } else {
            self.regs[idx] = v;
        }
    }

    /// A write past the window: the registers move to the heap, the new slots Unit.
    fn growRegs(self: *Frame, idx: usize) Allocator.Error!void {
        try self.toHeap(self.tls, idx + 1);
    }

    /// Record the frame's position before an instruction that may observe a span.
    pub inline fn at(self: *Frame, b: BlockId, idx: usize) void {
        self.at_block = b.int();
        self.at_idx = @intCast(idx);
    }

    /// The span of the statement the frame stands in.
    pub fn span(self: *const Frame) ?ir.Span {
        if (self.at_block >= self.func.blocks.len) return self.cur_span;
        return self.spanAt(self.at_block, self.at_idx);
    }

    /// The span of a frame standing at instruction `idx` of block `blk` (or its start): the
    /// last `Trace` before it in the block, else the block's entry span.
    pub fn spanAt(self: *const Frame, blk: u32, idx: u32) ?ir.Span {
        const insts = self.func.blocks[blk].insts;
        var i: usize = if (idx == block_start) 0 else @min(idx, insts.len);
        while (i > 0) {
            i -= 1;
            switch (insts[i]) {
                .Trace => |t| return t.span,
                else => {},
            }
        }
        return self.entrySpan(blk);
    }

    /// The span block `blk`'s entry finds (`FuncStreams.entry_spans`): the one every path
    /// into it leaves, the first statement of one that opens with it, else the one its
    /// entering edge left in the frame.
    pub fn entrySpan(self: *const Frame, blk: u32) ?ir.Span {
        const memo = self.func.bc_memo.load(.acquire);
        if (memo > 1) {
            const fs: *const ir.bc.FuncStreams = @ptrFromInt(memo);
            if (blk < fs.entry_spans.len) switch (fs.entry_spans[blk]) {
                .known => |sp| return sp,
                .opens => return self.func.blocks[blk].insts[0].Trace.span,
                .dyn => {},
            };
        }
        return self.cur_span;
    }

    /// Leaves in `cur_span` the span a block the frame loop routes to from block `blk` (a
    /// throw's handler, a finally) finds: the one where the frame stands in `blk`.
    pub fn leaveSpanFrom(self: *Frame, blk: u32) void {
        self.cur_span = if (self.at_block == blk) self.spanAt(blk, self.at_idx) else self.entrySpan(blk);
    }

    pub fn block(self: *const Frame, b: BlockId) *const ir.Block {
        return &self.func.blocks[b.int()];
    }

    /// `Unit` in every register not live where the frame stands, so a copy of the whole file
    /// (a suspension's snapshot) holds only values: a register not live there may hold
    /// anything, and the frame reads none of them before writing it.
    pub fn materializeRegs(self: *Frame) void {
        const n = @min(self.regs.len, @as(usize, self.func.n_locals));
        var buf: [16]u64 = undefined;
        const live = self.liveSet(&buf) orelse return;
        for (self.regs[0..n], 0..) |*v, i| {
            if (live[i >> 6] & (@as(u64, 1) << @as(u6, @truncate(i))) == 0) v.* = .Unit;
        }
    }

    /// The registers live where the frame stands (`FuncStreams.frameMap`), in `buf` or, for a
    /// frame of more than 512 registers, the heap (which the next call frees; the collector
    /// asks once per frame). Null for a function no map covers, whose frames are filled whole
    /// and hold values in every register.
    pub fn liveSet(self: *const Frame, buf: *[16]u64) ?[]const u64 {
        return self.liveAt(self.at_block, self.at_idx, buf);
    }

    /// `liveSet` at instruction `idx` of block `blk` (or its start, `block_start`).
    pub fn liveAt(self: *const Frame, blk: u32, idx: u32, buf: *[16]u64) ?[]const u64 {
        const memo = self.func.bc_memo.load(.acquire);
        if (memo <= 1) return null;
        const fs: *const ir.bc.FuncStreams = @ptrFromInt(memo);
        if (fs.open.fill_all) return null;
        const fm = fs.frameMap() orelse return null;
        const w = fm.words;
        const set = if (2 * w <= buf.len) buf[0 .. 2 * w] else big: {
            if (live_heap.len < 2 * w) {
                std.heap.c_allocator.free(live_heap);
                live_heap = std.heap.c_allocator.alloc(u64, 2 * w) catch return null;
            }
            break :big live_heap[0 .. 2 * w];
        };
        const blocks = self.func.blocks;
        if (blk >= blocks.len) return null;
        const pos = if (idx == block_start) block_start else @min(idx, @as(u32, @intCast(blocks[blk].insts.len)));
        fm.liveBefore(blocks, blk, pos, set[0..w], set[w..]);
        return set[0..w];
    }
};

/// `Frame.liveSet`'s buffer for frames past 512 registers, per thread.
threadlocal var live_heap: []u64 = &.{};

/// What a frame of `func` fills as it opens, from its code table; a function with none (a
/// body not decoded yet, an allocation that failed) is filled whole.
fn fillOf(module: *const Module, func: *const Func) Fill {
    const fs = ir.bc.funcStreams(func, module.consts.items) orelse return Fill.everything;
    return Fill.of(fs);
}

/// The run `args[0..n]` of `frame`'s registers, read in place.
pub inline fn argRun(frame: *const Frame, args: Reg, n: u32) []const Value {
    const lo: usize = args.int();
    if (lo + n <= frame.regs.len) return frame.regs[lo..][0..n];
    return argRunShort(frame, lo, n);
}

/// A run reaching past the window reads as `Unit` there, as `Frame.read` does; the registers
/// are grown so the run is still read in place.
fn argRunShort(frame: *const Frame, lo: usize, n: u32) []const Value {
    const f: *Frame = @constCast(frame);
    f.growRegs(lo + n - 1) catch return &.{};
    return f.regs[lo..][0..n];
}

/// An argument area on the value stack of `ev` holding `prefix` and then `rest`, for a callee whose
/// parameters are not a run of its caller's registers. `mark` pops it.
pub const ArgArea = struct {
    vals: []Value,
    mark: VsMark,

    pub fn push(ev: *EvalTls, prefix: []const Value, rest: []const Value) Allocator.Error!ArgArea {
        const mark = ev.vstack.mark();
        const vals = try ev.vstack.push(ev, prefix.len + rest.len);
        @memcpy(vals[0..prefix.len], prefix);
        @memcpy(vals[prefix.len..], rest);
        return .{ .vals = vals, .mark = mark };
    }
};
