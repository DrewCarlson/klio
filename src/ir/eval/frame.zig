//! The evaluator frame: a header over a register window and parameter views.

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

/// Which register slots a frame has actually written. A no-fill frame's window keeps whatever an
/// earlier frame left in it, so the collector and anything that materializes the file must know
/// which slots are live. One byte per register holding the use of the frame that wrote it, so a
/// write marks its slot with one store, and a new use of a pooled frame starts with nothing
/// written by taking the next use instead of clearing the bytes.
pub const RegMask = struct {
    pub const CAP: usize = ir.FRAME_FILL_WORDS * 64;

    /// `use` once register `i` is written in this use; an older use's mark otherwise.
    b: [CAP]u8 = undefined,
    /// The mark this use's writes leave, never 0; the bytes hold no mark above it.
    use: u8 = 0,
    /// Every slot holds a value: the window was filled, or its file was materialized.
    filled: bool = true,

    /// A mask whose bytes may hold anything, as a frame fresh from an allocation has: no use has
    /// written any.
    pub fn clear(self: *RegMask) void {
        @memset(&self.b, 0);
        self.use = 0;
    }

    /// The next use of the frame, over a window filled or not: when the use counter wraps, the
    /// bytes are cleared, so none holds the new mark.
    pub inline fn reset(self: *RegMask, filled: bool) void {
        self.filled = filled;
        if (filled) return;
        self.use +%= 1;
        if (self.use == 0) {
            @memset(&self.b, 0);
            self.use = 1;
        }
    }

    pub inline fn isAll(self: *const RegMask) bool {
        return self.filled;
    }

    /// A slot past the tracked range belongs to an eagerly filled frame, so it reads as written.
    pub inline fn has(self: *const RegMask, i: usize) bool {
        return self.filled or i >= CAP or self.b[i] == self.use;
    }

    pub inline fn set(self: *RegMask, i: usize) void {
        if (i < CAP) self.b[i] = self.use;
    }

    /// `set` for an index below the frame function's register count. A function with more
    /// than `CAP` registers gets a filled frame, so the byte a larger index wraps to is unread.
    pub inline fn setInWindow(self: *RegMask, i: usize) void {
        self.b[i & (CAP - 1)] = self.use;
    }

    pub inline fn setAll(self: *RegMask) void {
        self.filled = true;
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
    regs: []Value,
    /// Which register slots hold a real value: all-ones for an eagerly Unit-filled window, one bit per write
    /// for a no-fill frame. The collector reads only set slots; `materializeRegs` fills the rest.
    wmask: RegMask = .{},
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
    /// The span a block exit left in effect: the last `Trace` of a block that completed.
    cur_span: ?ir.Span = null,
    /// Where the frame stands at the instruction that may observe a span: an escape, a call or a throw.
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
        // The reclaim backend releases a register's previous occupant on every write, so its frames stay filled.
        const no_fill = !runtime.reclaimEnabled() and noFill(module, func);
        const n = func.n_locals;
        const window = ev.vstack.push(ev, n) catch |e| {
            ev.vstack.restore(mark);
            return e;
        };
        if (!no_fill) {
            @memset(window, .Unit);
            if (parent.frame_count_on) {
                parent.regs_fill_slots += n;
                fillCensusBump(func.id.int(), n);
            }
        }
        // A frame built here may be fresh from the Zig stack or an allocation, its mask anything.
        self.wmask.clear();
        self.init(ev, allocator, module, func, window, params, captures, mark, !no_fill);
    }

    /// `enter` for a call the stream loop opens, on an activation whose mask a use has set up: the loop has checked the diagnostic hooks, and
    /// the run's reclaim flag is known where it is compiled.
    pub inline fn enterStream(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        params: []const Value,
        captures: []const Value,
        area: ?VsMark,
        func_no_fill: bool,
        comptime reclaim: bool,
    ) Allocator.Error!void {
        const mark = area orelse ev.vstack.mark();
        const no_fill = !reclaim and func_no_fill;
        const window = ev.vstack.push(ev, func.n_locals) catch |e| {
            ev.vstack.restore(mark);
            return e;
        };
        if (!no_fill) @memset(window, .Unit);
        self.init(ev, allocator, module, func, window, params, captures, mark, !no_fill);
    }

    /// `enterStream` over a `window` the caller took from the value stack, on a frame whose mask's
    /// use counter is below its last value: nothing here can fail, allocate or clear the mask.
    /// A function not shown to write each register before reading it gets its window filled with
    /// `Unit`, one tag at a time, which compiles to stores rather than a call.
    pub inline fn enterWindow(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        window: []Value,
        params: []const Value,
        captures: []const Value,
        mark: VsMark,
        no_fill: bool,
    ) void {
        std.debug.assert(self.wmask.use != std.math.maxInt(u8));
        self.initFields(ev, allocator, module, func, window, params, captures, mark);
        if (no_fill) {
            self.wmask.filled = false;
            self.wmask.use += 1;
        } else {
            for (window) |*v| v.* = .Unit;
            self.wmask.filled = true;
        }
    }

    /// Every field of a fresh frame over `window`. Written one by one: a struct literal would copy
    /// the mask's bytes, which only the registers a no-fill window writes are read from.
    inline fn init(
        self: *Frame,
        ev: *EvalTls,
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        window: []Value,
        params: []const Value,
        captures: []const Value,
        mark: VsMark,
        filled: bool,
    ) void {
        self.initFields(ev, allocator, module, func, window, params, captures, mark);
        self.wmask.reset(filled);
    }

    /// `init` but for the mask.
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
        comptime std.debug.assert(std.meta.fields(Frame).len == 18);
        self.module = module;
        self.func = func;
        self.regs = window;
        self.params = params;
        self.captures = captures;
        self.vs_mark = mark;
        self.heap = &.{};
        self.module_arc = null;
        self.allocator = allocator;
        self.owns_params_caps = false;
        self.gc_link = null;
        self.closure = null;
        self.pending = null;
        self.tls = ev;
        self.cur_span = null;
        self.at_block = 0;
        self.at_idx = 0;
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
        // A no-fill frame's indices are below `RegMask.CAP` by `frameDefBeforeUse`.
        self.wmask.set(idx);
        if (runtime.reclaimEnabled()) {
            const old = self.regs[idx];
            self.regs[idx] = v;
            old.release(self.allocator);
        } else {
            self.regs[idx] = v;
        }
    }

    /// A write past the window: the registers move to the heap, the new slots Unit and written.
    fn growRegs(self: *Frame, idx: usize) Allocator.Error!void {
        const old_len = self.regs.len;
        try self.toHeap(self.tls, idx + 1);
        var i = old_len;
        while (i < self.regs.len) : (i += 1) self.wmask.set(i);
    }

    /// Record the frame's position before an instruction that may observe a span.
    pub inline fn at(self: *Frame, b: BlockId, idx: usize) void {
        self.at_block = b.int();
        self.at_idx = @intCast(idx);
    }

    /// The span of the statement the frame stands in: the last `Trace` before its position in its
    /// block, else the one the blocks before it left in effect.
    pub fn span(self: *const Frame) ?ir.Span {
        if (self.at_block < self.func.blocks.len) {
            const insts = self.func.blocks[self.at_block].insts;
            var i: usize = @min(self.at_idx, insts.len);
            while (i > 0) {
                i -= 1;
                switch (insts[i]) {
                    .Trace => |t| return t.span,
                    else => {},
                }
            }
        }
        return self.cur_span;
    }

    pub fn block(self: *const Frame, b: BlockId) *const ir.Block {
        return &self.func.blocks[b.int()];
    }

    /// Fill every not-yet-written slot with `Unit` and saturate the mask before the file escapes the masked
    /// world (suspension snapshot, C-native surface, resume rebuild). No-op once saturated.
    pub fn materializeRegs(self: *Frame) void {
        if (self.wmask.isAll()) return;
        for (self.regs, 0..) |*v, i| {
            if (!self.wmask.has(i)) v.* = .Unit;
        }
        self.wmask.setAll();
    }
};

/// Whether a frame of `func` may start unfilled, from its code table; a function with none
/// (a body not decoded yet, an allocation that failed) is filled.
fn noFill(module: *const Module, func: *const Func) bool {
    const fs = ir.bc.funcStreams(func, module.consts.items) orelse return false;
    return fs.no_fill;
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

test "a window write marks its register, and a filled window reads as written past its range" {
    var m: RegMask = .{};
    m.clear();
    m.reset(false);
    try std.testing.expect(!m.isAll());
    m.setInWindow(0);
    m.setInWindow(70);
    m.setInWindow(RegMask.CAP - 1);
    try std.testing.expect(m.has(0) and m.has(70) and m.has(RegMask.CAP - 1));
    try std.testing.expect(!m.has(1) and !m.has(69) and !m.has(71));
    try std.testing.expect(m.has(RegMask.CAP + 3));
    m.setAll();
    try std.testing.expect(m.isAll() and m.has(1));
    var filled: RegMask = .{};
    filled.clear();
    filled.reset(true);
    filled.setInWindow(RegMask.CAP + 5);
    try std.testing.expect(filled.isAll() and filled.has(3));
}

test "a pooled frame's next use sees none of an earlier use's writes, the counter's wrap included" {
    var m: RegMask = .{};
    m.clear();
    m.reset(false);
    m.setInWindow(4);
    m.reset(false);
    try std.testing.expect(!m.has(4));
    m.setInWindow(5);
    // Through every other mark and the wrap: no write of an earlier use reads as this one's.
    var k: usize = 0;
    while (k < 300) : (k += 1) {
        m.reset(false);
        try std.testing.expect(!m.has(4) and !m.has(5));
    }
    m.setInWindow(4);
    try std.testing.expect(m.has(4) and !m.has(5));
}
