//! Per-thread evaluator state: frame chain, register/argument pools, GC roots.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const Func = ir.Func;
const Module = ir.Module;


const parent = @import("../eval.zig");
const ev_activation = @import("activation.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_snapshot = @import("snapshot.zig");

const ACT_POOL_MAX = ev_activation.ACT_POOL_MAX;
const Activation = ev_flow.Activation;
const FRAME_CENSUS_SLOTS = ev_diag.FRAME_CENSUS_SLOTS;
const FlatCallReq = ev_flow.FlatCallReq;
const Frame = ev_frame.Frame;
const FrameSnapshot = ev_snapshot.FrameSnapshot;
const SuspendState = ev_snapshot.SuspendState;
const TailSeg = ev_snapshot.TailSeg;
const cmgTraceWant = ev_flow.cmgTraceWant;
const gcMarkSnapshot = ev_snapshot.gcMarkSnapshot;

pub fn strVal(allocator: Allocator, s: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInit(allocator, s) };
}

pub fn displayThrow(allocator: Allocator, v: *const Value) Allocator.Error![]u8 {
    switch (v.*) {
        .Exception => |e| {
            const fg = e.fqn.borrow();
            defer fg.deinit();
            const fqn = fg.get().bytes;
            if (e.message.get()) |m| {
                const mg = m.borrow();
                defer mg.deinit();
                return std.fmt.allocPrint(allocator, "{s}({s})", .{ fqn, mg.get().bytes });
            }
            return allocator.dupe(u8, fqn);
        },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const b = g.get();
            const cg = b.class.borrow();
            defer cg.deinit();
            const name = cg.get().name;
            if (b.get("message")) |mv| {
                if (mv == .String) {
                    const sg = mv.String.borrow();
                    defer sg.deinit();
                    return std.fmt.allocPrint(allocator, "{s}({s})", .{ name, sg.get().bytes });
                }
            }
            return allocator.dupe(u8, name);
        },
        else => return v.display(allocator),
    }
}

/// Evaluator errors as data; `Allocator.Error` is the only Zig error it raises.
pub const EvalError = union(enum) {
    Unsupported: []const u8,
    Type: []const u8,
    Throw: Value,
    /// `return` from a nested lambda targeting an enclosing IR function frame;
    /// `evalWith` catches it at that fn boundary and turns it into a return value.
    NonLocalReturn: Value,
    /// `return@label value` targeting a named function/lambda frame, caught where
    /// the active frame's `func.name` matches the label.
    LabeledReturn: struct { label: []const u8, value: Value },
    Arity: []const u8,
    Unbound: []const u8,
    /// Doubles as the dispatch-miss sentinel: a candidate probe that does not
    /// apply reports `Unimplemented` and the resolver walks on.
    Unimplemented: []const u8,
    /// An `Unimplemented` that escaped a body which already ran: always
    /// propagates, so no fallback retries a candidate whose side effects landed.
    CalleeFailed: []const u8,
    /// A suspension fired. Each frame on the unwind path appends its
    /// `FrameSnapshot` to `state.frames`, innermost last, before re-propagating.
    Suspended: *SuspendState,
    /// Recursion past the depth cap, surfaced as a Kotlin `StackOverflowError`.
    StackOverflow: []const u8,
};

/// Activation-depth cap that turns runaway recursion into a
/// `StackOverflowError`. A call the evaluator makes itself keeps its frame on
/// the heap, so this bounds a runaway program's time and memory, not the
/// native stack (`runtime.stackLow` guards that). It sits above the depth a
/// JVM reaches at its default 2 MiB stack, about 40,000 small frames.
/// `KLIO_MAX_EVAL_DEPTH` overrides.
pub const DEFAULT_MAX_EVAL_DEPTH: usize = 100_000;

/// The evaluator's per-thread state, held off the thread-local block. Darwin
/// resolves every `threadlocal` access through a call into dyld, and the
/// evaluator touches this state in every frame push, every register pool take
/// and every free: on a recomposer profile those calls were a larger block
/// than the instruction dispatch they served. The thread that runs the program
/// reads an ordinary global; any other thread keeps a copy of its own.
const EvalTlsStore = runtime.tls_fast.PerThread(EvalTls);

pub inline fn evtlsPtr() *EvalTls {
    return EvalTlsStore.get();
}

/// The evaluator's per-thread hot state in ONE threadlocal, so a function that
/// touches several fields pays one TLV address lookup instead of one per field.
pub const EvalTls = struct {
    /// Activation depth: native recursion across the host call-back boundary.
    eval_depth: usize = 0,
    /// Resolved depth cap; `0` = not yet read from the env.
    eval_depth_cap: usize = 0,
    /// Net external bytes of carriers and register buffers taken and returned
    /// on this thread, handed to the collector `EXT_BATCH` at a time.
    ext_delta: isize = 0,
    /// Whether this thread's frame chain is registered as a collector root.
    frame_root_installed: bool = false,
    /// The suspension a COMPILED body builds as it unwinds: compiled code cannot
    /// return an error union, so it answers `CoroutineSuspended` and leaves it here.
    in_flight_suspend: ?*SuspendState = null,
    /// Innermost-first chain of active interpreter frames (GC root seed).
    frame_chain: ?*Frame = null,
    /// Innermost in-flight resume node chain (GC root seed).
    resuming: ?*ResumeFrames = null,

    /// The argument areas and register windows of this thread's frames.
    vstack: ValueStack = .{},
    /// The error an instruction raised with `Step.raised`, read by the dispatch loop.
    step_err: ?EvalError = null,
    /// The call an instruction left with `Step.flat_call`, read by the dispatch loop.
    flat_call: ?FlatCallReq = null,
    act_pool_len: usize = 0,
    act_pool: [ACT_POOL_MAX]*Activation = undefined,
    /// `KLIO_SPIN_TRACE` bookkeeping.
    spin_last_dump: i64 = 0,
    spin_check_counter: u64 = 0,
};

/// The evaluation depth cap of the thread whose state `ev` is. The first
/// read on a thread takes `KLIO_MAX_EVAL_DEPTH`.
pub inline fn evalDepthCap(ev: *EvalTls) usize {
    if (ev.eval_depth_cap != 0) return ev.eval_depth_cap;
    return evalDepthCapInit(ev);
}

fn evalDepthCapInit(ev: *EvalTls) usize {
    // `procEnvGetVar` reads the whole environment block into the scratch allocator, so a fixed buffer would fail.
    const a = std.heap.page_allocator;
    const cap = blk: {
        const raw = runtime.procEnvGetVar(a, "KLIO_MAX_EVAL_DEPTH") catch break :blk DEFAULT_MAX_EVAL_DEPTH;
        const v = raw orelse break :blk DEFAULT_MAX_EVAL_DEPTH;
        defer a.free(v);
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        const parsed = std.fmt.parseInt(usize, trimmed, 10) catch break :blk DEFAULT_MAX_EVAL_DEPTH;
        if (parsed == 0) break :blk DEFAULT_MAX_EVAL_DEPTH;
        break :blk parsed;
    };
    ev.eval_depth_cap = cap;
    return cap;
}

/// The innermost executing function: the innermost frame's.
pub fn currentFrameFunc() ?*const ir.Func {
    return if (evtlsPtr().frame_chain) |fr| fr.func else null;
}

/// Allocator for the heap block of a frame off the value stack. Under the
/// tracing GC it lives outside the GC heap (libc): the frame's values are traced
/// through the frame, the storage never swept.
pub inline fn regsAlloc(fallback: Allocator) Allocator {
    if (!runtime.reclaimEnabled() and runtime.gc.gc_enabled) return std.heap.c_allocator;
    return fallback;
}

pub var fill_census: [FRAME_CENSUS_SLOTS]u32 = @splat(0);

pub fn fillCensusBump(fid: u32, n: u32) void {
    if (!ev_diag.frame_census_on) return;
    fill_census[fid & (FRAME_CENSUS_SLOTS - 1)] +%= n;
}

const EXT_BATCH: isize = 256 * 1024;

/// Batches external bytes on the thread's evaluator state.
pub inline fn noteExt(ev: *EvalTls, delta: isize) void {
    ev.ext_delta += delta;
    if (ev.ext_delta >= EXT_BATCH or ev.ext_delta <= -EXT_BATCH) {
        runtime.gc.noteExternalNet(ev.ext_delta);
        ev.ext_delta = 0;
    }
}

/// Values in one segment of a thread's value stack.
const VS_SEGMENT_VALUES: usize = 16 * 1024;

const VsSegment = struct {
    prev: ?*VsSegment,
    next: ?*VsSegment,
    buf: []Value,
};

/// A position on a value stack: taken before a push, restored to pop everything
/// pushed after it.
pub const VsMark = struct {
    seg: ?*VsSegment,
    top: usize,
};

/// A thread's value stack: every frame's argument area and register window,
/// pushed at the call and popped at the return. Segments stay chained once
/// allocated, so a call pays two stores. The collector reaches the values
/// through the frames owning the windows, whose written masks say which slots
/// hold values: a window's other slots keep what an earlier frame left.
pub const ValueStack = struct {
    seg: ?*VsSegment = null,
    top: usize = 0,
    first: ?*VsSegment = null,

    pub inline fn mark(self: *const ValueStack) VsMark {
        return .{ .seg = self.seg, .top = self.top };
    }

    pub inline fn restore(self: *ValueStack, m: VsMark) void {
        self.seg = m.seg;
        self.top = m.top;
    }

    /// `n` slots on top of the stack, holding whatever they last held.
    pub inline fn push(self: *ValueStack, ev: *EvalTls, n: usize) Allocator.Error![]Value {
        if (self.seg) |s| {
            if (s.buf.len - self.top >= n) {
                const w = s.buf[self.top..][0..n];
                self.top += n;
                return w;
            }
        }
        return self.pushSegment(ev, n);
    }

    /// A push that starts the next segment, allocating it the first time the
    /// stack reaches it or when the one cached there is too small for `n`.
    fn pushSegment(self: *ValueStack, ev: *EvalTls, n: usize) Allocator.Error![]Value {
        const cached: ?*VsSegment = if (self.seg) |s| s.next else self.first;
        const seg: *VsSegment = if (cached != null and cached.?.buf.len >= n) cached.? else blk: {
            const a = std.heap.c_allocator;
            const fresh = try a.create(VsSegment);
            errdefer a.destroy(fresh);
            const buf = try a.alloc(Value, @max(VS_SEGMENT_VALUES, n));
            @memset(buf, .Unit);
            fresh.* = .{ .prev = self.seg, .next = cached, .buf = buf };
            if (cached) |c| c.prev = fresh;
            if (self.seg) |p| p.next = fresh else self.first = fresh;
            if (runtime.gc.gc_enabled and runtime.gc.external_accounting) noteExt(ev, @intCast(buf.len * @sizeOf(Value)));
            break :blk fresh;
        };
        self.seg = seg;
        self.top = n;
        return seg.buf[0..n];
    }

    /// Free every segment of an empty stack, when its thread stops running Kotlin.
    pub fn deinit(self: *ValueStack) void {
        if (self.seg != null and self.top != 0) return;
        var cur = self.first;
        while (cur) |seg| {
            cur = seg.next;
            std.heap.c_allocator.free(seg.buf);
            std.heap.c_allocator.destroy(seg);
        }
        self.* = .{};
    }
};

/// Snapshots of an in-flight `resumeContinuation`: off the park registry and
/// not yet on `frame_chain`, so the GC marks `frames.items[head..]` through here.
pub const ResumeFrames = struct {
    prev: ?*ResumeFrames,
    frames: *const std.ArrayList(FrameSnapshot),
    head: *const usize,
    /// Unconsumed inherited segments of the in-flight resume.
    tails: *const ?*TailSeg,
};

/// Stable addresses of this thread's root chains, held by `frame_troot.ctx`.
const FrameAnchor = struct {
    chain: *const ?*Frame,
    resuming: *const ?*ResumeFrames,
    /// Owning thread, for `KLIO_GC_FRAME_AUDIT`: a collector marking another
    /// thread's chain must find it parked, so a torn frame names an unparked mutator.
    tid: runtime.gc.Tid = 0,
};

threadlocal var frame_anchor: FrameAnchor = undefined;

/// This thread's GC root node; `ctx` is `&frame_anchor`, so any thread can mark
/// these frames while this one is parked. Registered on first frame push.
threadlocal var frame_troot: runtime.gc.ThreadRoot = undefined;

threadlocal var frame_troot_inited: bool = false;

/// Links `f` onto its thread's frame chain; `f.tls` is the running thread's state.
pub inline fn gcPushFrame(f: *Frame) void {
    // The chain is maintained in every allocator mode (it backs stack-trace
    // capture too); only the root registration is gated on the collector.
    if (runtime.gc.gc_enabled and !f.tls.frame_root_installed) gcInstallFrameRoot();
    if (parent.call_hooks_on) framePushTrace(f);
    f.gc_link = f.tls.frame_chain;
    f.tls.frame_chain = f;
}

/// KLIO_CMG_TRACE: a frame push of the named function, with its first parameters.
fn framePushTrace(f: *const Frame) void {
    if (cmgTraceWant()) |w| {
        if (std.mem.eql(u8, w, f.func.name)) {
            std.debug.print("[frame-push] {s}#{d}", .{ f.func.name, f.func.id.int() });
            for (f.params, 0..) |*v, i| {
                if (i >= 4) break;
                switch (v.*) {
                    .Int => |x| std.debug.print(" p{d}=i{d}", .{ i, x }),
                    .Long => |x| std.debug.print(" p{d}=L{d}", .{ i, x }),
                    .Instance => |inst| std.debug.print(" p{d}=@{x}", .{ i, inst.identity() }),
                    else => std.debug.print(" p{d}={s}", .{ i, @tagName(std.meta.activeTag(v.*)) }),
                }
            }
            std.debug.print("\n", .{});
        }
    }
}

pub inline fn gcPopFrame(f: *Frame) void {
    f.tls.frame_chain = f.gc_link;
}

/// Mark a frame's register file, skipping slots the written mask says were
/// never written: an unfilled slot holds whatever the pooled buffer last carried.
pub fn gcMarkFrameRegs(f: *const Frame, m: *runtime.gc.Marker) void {
    runtime.gc.poison_ctx_name = f.func.name;
    const mask = &f.wmask;
    if (mask.isAll()) {
        for (f.regs, 0..) |v, i| {
            runtime.gc.poison_ctx_idx = i;
            v.gcMark(m);
        }
        return;
    }
    for (f.regs, 0..) |v, i| {
        runtime.gc.poison_ctx_idx = i;
        if (mask.has(i)) v.gcMark(m);
    }
}

var stw_audit_state: u8 = 0;

pub inline fn stwAuditOn() bool {
    if (stw_audit_state == 0) stwAuditInit();
    return stw_audit_state == 2;
}

fn stwAuditInit() void {
    stw_audit_state = if (runtime.envOnce("KLIO_GC_STW_AUDIT") != null) 2 else 1;
}

/// Mark every Value reachable from the `ctx` thread's frames and resumes.
fn gcMarkFramesCtx(ctx: *anyopaque, m: *runtime.gc.Marker) void {
    const anchor: *const FrameAnchor = @ptrCast(@alignCast(ctx));
    const audit = runtime.envOnce("KLIO_GC_FRAME_AUDIT") != null;
    var cur = anchor.chain.*;
    var fi: usize = 0;
    while (cur) |f| : ({
        cur = f.gc_link;
        fi += 1;
    }) {
        if (audit) {
            const me = runtime.gc.currentTid();
            const bad = @intFromPtr(f) < 0x1000 or (@intFromPtr(f) >> 47) != 0 or
                f.captures.len > 4096 or f.params.len > 4096 or
                f.regs.len > 65536;
            if (bad) {
                std.debug.print("[gc-frame] TORN anchor_tid={d} marker_tid={d} idx={d} f={x} caps={d} params={d} regs={d}\n", .{ anchor.tid, me, fi, @intFromPtr(f), f.captures.len, f.params.len, f.regs.len });
                return;
            }
        }
        gcMarkFrameRegs(f, m);
        for (f.params) |v| v.gcMark(m);
        for (f.captures) |v| v.gcMark(m);
        if (f.pending) |p| p.gcMark(m);
        markFrameClosure(f.closure_id, m);
    }
    // Not-yet-rebuilt snapshots of every in-flight resume on this thread.
    var r = anchor.resuming.*;
    while (r) |node| : (r = node.prev) {
        var seg = node.tails.*;
        while (seg) |t| : (seg = t.next) {
            if (m.minor and t.gc_quiesced) continue;
            for (t.frames.items[t.head..]) |snap| gcMarkSnapshot(snap, m);
            if (m.marksWhole()) t.gc_quiesced = true;
        }
        const head = node.head.*;
        const items = node.frames.items;
        var i = head;
        while (i < items.len) : (i += 1) {
            const snap = items[i];
            gcMarkSnapshot(snap, m);
        }
    }
}

/// Root the side-table slot of a closure whose body is on the stack or parked:
/// the frame holds only copies of the captures, so nothing else spares the slot.
pub inline fn markFrameClosure(closure_id: ?u64, m: *runtime.gc.Marker) void {
    if (closure_id) |id| {
        if (runtime.gc.markClosureHook) |hook| hook(id, m);
    }
}

/// Link this thread's frame-chain root node (idempotent per thread).
pub fn gcInstallFrameRoot() void {
    evtlsPtr().frame_root_installed = true;
    if (frame_troot_inited) return;
    frame_troot_inited = true;
    frame_anchor = .{ .chain = &evtlsPtr().frame_chain, .resuming = &evtlsPtr().resuming, .tid = runtime.gc.currentTid() };
    frame_troot = .{ .ctx = @ptrCast(&frame_anchor), .mark = gcMarkFramesCtx };
    runtime.gc.registerThreadRoot(&frame_troot);
}

/// Unlink this thread's frame-chain root and free its value stack; short-lived
/// workers would otherwise leak one each.
pub fn gcUninstallFrameRoot() void {
    evtlsPtr().frame_root_installed = false;
    if (frame_troot_inited) {
        runtime.gc.unregisterThreadRoot(&frame_troot);
        frame_troot_inited = false;
    }
    evtlsPtr().vstack.deinit();
}

/// The most frames a captured stack keeps, the innermost ones, as the JVM
/// keeps at most `-XX:MaxJavaStackTraceDepth` (1024).
pub const MAX_STACK_TRACE_DEPTH: usize = 1024;

/// Capture the live call stack, innermost first, at most
/// `MAX_STACK_TRACE_DEPTH` frames of it. Labels borrow program-lifetime
/// module memory; only the frame slice is owned by the returned cell.
pub fn captureStack(allocator: Allocator) Allocator.Error!?runtime.StackRef {
    var total: usize = 0;
    {
        var cur = evtlsPtr().frame_chain;
        while (cur) |f| : (cur = f.gc_link) {
            total += 1;
            if (total >= MAX_STACK_TRACE_DEPTH) break;
        }
    }
    if (total == 0) return null;
    const frames = try allocator.alloc(runtime.StackFrame, total);
    errdefer allocator.free(frames);
    var i: usize = 0;
    var fr = evtlsPtr().frame_chain;
    while (i < total) : (i += 1) {
        const f = fr.?;
        frames[i] = stackFrame(f.module, f.func, f.span());
        fr = f.gc_link;
    }
    return try runtime.StackRef.init(allocator, .{ .frames = frames });
}

/// One captured frame: its function by its Kotlin name (the module's
/// `frame_namer`, else its FQN) and where it is. A frame that has not
/// reached a position yet stands at its function's first one.
fn stackFrame(module: *const Module, func: *const ir.Func, at: ?ir.Span) runtime.StackFrame {
    var label = if (func.fqn.len != 0) func.fqn else func.name;
    if (module.resolved) |r| if (r.frame_namer) |fnm| {
        if (fnm.name(fnm.ctx, func.id)) |n| label = n;
    };
    const sp = at orelse firstSpan(func) orelse return .{ .fqn = label, .file_id = 0, .offset = 0, .has_pos = false };
    return .{ .fqn = label, .file_id = @intFromEnum(sp.file), .offset = sp.start, .has_pos = true };
}

/// The span of `func`'s first positioned instruction.
fn firstSpan(func: *const ir.Func) ?ir.Span {
    for (func.blocks) |*b| {
        for (b.insts) |*inst| {
            if (inst.* == .Trace) return inst.Trace.span;
        }
    }
    return null;
}

