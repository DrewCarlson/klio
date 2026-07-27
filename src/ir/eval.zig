//! IR evaluator.
//!
//! Walks a `Func`'s `[]Block` and produces a `Value`. Today
//! supports the subset of `Inst`s the lowering pass emits: `Const`,
//! `BinOp`, `UnOp`, `Not`, `Move`, plus `Goto` / `Branch` / `Return`
//! / `Throw` / `Unreachable` terminators. Other ops trap as
//! `EvalError.Unsupported`.
//!
//! The evaluator does not yet replace the tree-walking interpreter.
//! It exists so the IR shape can be exercised end-to-end on
//! hand-built or lowered modules; as the lowering pass grows, the
//! evaluator grows alongside it, and the cutover lands once parity
//! holds across the corpus.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");
const span = @import("span");
const jit_loop = @import("jit_loop.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const RangeKind = runtime.RangeKind;
const InstanceData = runtime.InstanceData;

const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const Const = ir.Const;
const Func = ir.Func;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const ConstId = ir.ConstId;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const Terminator = ir.Terminator;
const TypeRef = ir.TypeRef;
const UnOp = ir.UnOp;

/// Make a heap `StringRef` from a borrowed slice (mirrors `Arc<String>`).
fn strVal(allocator: Allocator, s: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInit(allocator, s) };
}

fn displayThrow(allocator: Allocator, v: *const Value) Allocator.Error![]u8 {
    switch (v.*) {
        .Exception => |e| {
            const fg = e.fqn.borrow();
            defer fg.deinit();
            const fqn = fg.get().bytes;
            if (e.message) |m| {
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

/// Errors surfaced by the IR evaluator. Data, not Zig `error` values —
/// `Allocator.Error` is the only true Zig error the evaluator raises.
pub const EvalError = union(enum) {
    /// IR evaluator does not yet support: {0}
    Unsupported: []const u8,
    /// IR type error: {0}
    Type: []const u8,
    /// uncaught throw inside IR evaluator
    Throw: Value,
    /// `return` from a nested lambda whose target is an enclosing IR
    /// function frame. `evalWith` catches this at the matching fn
    /// boundary and converts it to a normal return value.
    NonLocalReturn: Value,
    /// `return@label value` whose target is a named function/lambda
    /// frame. `evalWithCaptures` catches this when the active frame's
    /// `func.name` matches the label.
    LabeledReturn: struct { label: []const u8, value: Value },
    /// Arity mismatch — caller passed wrong number of args.
    Arity: []const u8,
    /// Unbound identifier reachable through the IR.
    Unbound: []const u8,
    /// Operation not yet implemented on this value. Doubles as the
    /// dispatch-miss sentinel: a candidate probe that does not apply
    /// reports `Unimplemented` and the resolver walks on.
    Unimplemented: []const u8,
    /// A function body was entered and its execution failed to resolve an
    /// operation (an `Unimplemented` escaping the body's own frame).
    /// Distinct from `Unimplemented` so no dispatch fallback ever treats
    /// a candidate that ran — possibly with side effects — as a candidate
    /// that did not apply; this error always propagates.
    CalleeFailed: []const u8,
    /// A suspension point fired (`delay` / `yield` / `suspendCoroutine`).
    /// Each `evalWithCaptures` frame on the unwind path pushes its
    /// `FrameSnapshot` onto `state.frames` (innermost last) and
    /// re-propagates; the coroutine driver parks the resulting
    /// `SuspendState` and resumes it later via `resumeContinuation`.
    Suspended: *SuspendState,
    /// Evaluation recursion exceeded the configured depth cap. Surfaced as a
    /// Kotlin `StackOverflowError` rather than letting an unbounded recursion
    /// run the native stack into a segfault. Carries the message text.
    StackOverflow: []const u8,
};

/// Maximum evaluator activation depth before a recursion is treated as
/// non-terminating and converted to a `StackOverflow` data error. Each Kotlin
/// function/method/closure call re-enters `runFrame`, so this bounds the
/// native recursion. Set well above the deepest legitimate non-tail recursion
/// in the corpus (which is in the low hundreds; `tailrec` loops do not grow
/// the stack) yet below the frame ceiling of the 256 MiB interpret worker
/// stack (which faults near ~2400 of these deep evaluator frames), so the cap
/// trips with a clean error before the native stack overflows. Overridable via
/// `KLIO_MAX_EVAL_DEPTH`.
const DEFAULT_MAX_EVAL_DEPTH: usize = 2_000;

/// Per-thread evaluator activation depth. Incremented on entry to each
/// `runFrame` and decremented on exit, so it counts native recursion across
/// the host call-back boundary (every nested Kotlin call re-enters here).
threadlocal var evtls: EvalTls = .{};

/// The evaluator's per-thread hot state, batched into ONE threadlocal so a
/// function touching several of these fields pays one dyld TLV address
/// lookup instead of one per variable (separate threadlocals each cost
/// their own `_tlv_get_addr` per access site; the compiler only CSEs
/// repeated reads of the same variable).
const EvalTls = struct {
    /// Per-thread evaluator activation depth (native recursion across the
    /// host call-back boundary).
    eval_depth: usize = 0,
    /// Native-recursion depth for the whole-function JIT (see
    /// JIT_NATIVE_DEPTH_LIMIT).
    jit_native_depth: usize = 0,
    /// Resolved depth cap; `0` = not yet read from the env.
    eval_depth_cap: usize = 0,
    /// The enclosing-`this` chain of the currently executing frame (always
    /// points at a live Frame's `enclosing_this`, or null between runs).
    active_chain: ?*std.ArrayList(EnclosingEntry) = null,
    /// Length of the active chain's seeded (frame-entry) prefix.
    active_chain_base: usize = 0,
    /// Innermost-first chain of active interpreter frames (GC root seed).
    frame_chain: ?*Frame = null,
    /// Innermost in-flight resume node chain (GC root seed).
    resuming: ?*ResumeFrames = null,
};
/// Native-recursion depth for the whole-function JIT: a compiled body recursing
/// into a compiled callee runs it frameless (no interpreter frame), so each level
/// costs a few C-stack frames. Bounded so deep recursion falls back to the
/// frame-based path (whose `evtls.eval_depth` bound raises a catchable StackOverflow)
/// before the native stack faults.
const JIT_NATIVE_DEPTH_LIMIT: usize = 1500;

/// Resolved depth cap for the current thread. `0` means "not yet read"; the
/// first `runFrame` reads the env once and caches the result.

/// One implicit receiver on the enclosing-`this` chain.
///
/// `kind` records how the value entered scope, because the three ways
/// carry different scope rights. A dispatch receiver or a displaced
/// lexical `this` (`receiver`) carries its whole class-nesting tower:
/// inside a member of `Inner`, `this@Outer` is in scope precisely because
/// it is reachable through `this@Inner`'s `outer` link. A
/// `with`/`run`/`apply` subject (`subject`) brings only itself —
/// `with(x) { … }` never puts `x`'s enclosing instances in scope. An
/// `access` entry exists only for the duration of one host dispatch (the
/// member-extension visibility filter consults it); it is never part of
/// any frame's lexical receiver scope, so it neither transfers into a
/// callee frame nor survives into a closure's creation-chain snapshot.
pub const EnclosingEntry = runtime.ImplicitReceiver;

/// The enclosing-`this` chain of the *currently executing* frame.
///
/// This is NOT receiver state of its own: it always points at a live `Frame`'s
/// `enclosing_this` field (or is `null` between runs / before the first
/// frame). On frame entry it is repointed at the new frame's chain and restored
/// to the caller's chain on exit, so the chain a frame reads is its own
/// frame-scoped data, snapshotted into `FrameSnapshot.enclosing_this` on
/// suspend and restored verbatim on resume.
///
/// Kotlin receiver scope is LEXICAL, so a frame's chain is seeded from
/// what the code it runs could lexically see — a closure body's chain
/// comes from the closure's creation-time snapshot, a member/extension
/// body's receiver tower comes from its dispatch — never inherited
/// wholesale from the dynamic caller. The only entries that cross a frame
/// boundary at entry are the ones the dispatch just pushed for this very
/// call (a bound receiver-lambda subject, a displaced `this`, a
/// member-extension owner): the in-flight suffix beyond the caller's
/// `evtls.active_chain_base`, minus `access` entries. Because the chain lives on
/// the frame, it travels with a parked continuation and cannot leak past
/// the frame or across a `run` boundary.

/// Length of the active chain's seeded (frame-entry) prefix. Entries at
/// `>= evtls.active_chain_base` are in-flight pushes made by the currently
/// executing frame around a dispatch; only those transfer into the next
/// frame entered.

// -------------------------------------------------------------------------
// GC roots: the per-thread chain of active interpreter frames. The tracing
// collector (runtime.gc) seeds its mark phase from every active frame's
// registers/params/captures/enclosing-`this`. Frames are Zig-stack locals, so
// each `evalWithCapturesChained`/`resumeContinuation` activation links its
// frame onto this innermost-first chain for its lifetime. Registered once.
// -------------------------------------------------------------------------

/// The source span of the statement the innermost active frame is currently
/// executing — i.e. the call site of a call being dispatched from that frame.
/// The compose `@Composable` hook reads this to derive a stable positional
/// group key per call site (set per-statement by the `.Trace` instruction).
pub fn currentCallSiteSpan() ?ir.Span {
    return if (evtls.frame_chain) |fr| fr.cur_span else null;
}

/// The declaring package of the innermost executing frame's function.
/// Null-receiver extension-property dispatch keys on it: same-name
/// nullable extension properties in different packages resolve to the
/// one the executing code can see.
pub fn currentFramePackage() ?[]const u8 {
    const fr = evtls.frame_chain orelse return null;
    const pkg = fr.func.package;
    return if (pkg.len == 0) null else pkg;
}

/// Every executing frame's bound `this` (the this param, or the closure's
/// captured `this` slot), innermost first — the lexical receiver tower of
/// the current call stack. The member-extension owner walk consults it
/// when the dynamic enclosing chain has no matching entry (a property
/// read inside nested lambdas whose frames never pushed the chain).
pub fn frameThisChainAlloc(allocator: Allocator) Allocator.Error![]Value {
    var out: std.ArrayList(Value) = .empty;
    var cur = evtls.frame_chain;
    var steps: usize = 0;
    while (cur) |f| : (cur = f.gc_link) {
        if (steps > 256) break;
        steps += 1;
        if (callerThisValue(f)) |v| {
            const dup = out.items.len > 0 and out.items[out.items.len - 1] == .Instance and
                v == .Instance and ObjRef(InstanceData).ptrEq(out.items[out.items.len - 1].Instance, v.Instance);
            if (!dup) try out.append(allocator, v);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// The nearest enclosing frame's declaring package, walking outward past
/// frames without one (synthesized accessors / init thunks carry no
/// package of their own; their lexical home is the calling frame's).
pub fn nearestFramePackage() ?[]const u8 {
    var cur = evtls.frame_chain;
    while (cur) |f| : (cur = f.gc_link) {
        if (f.func.package.len != 0) return f.func.package;
    }
    return null;
}

/// Lexical-origin override for file-private visibility. Kotlin resolves a
/// callable reference where it is WRITTEN: `.map(String::indentWidth)`
/// referencing a file-private extension is legal in its declaring file even
/// though `map` invokes it from another file. While a bound reference
/// dispatches, the visibility file is the reference's creation site, not
/// the dynamic caller. Scoped to the frame that was innermost at push: a
/// candidate body run during dispatch executes in a DEEPER frame, so its
/// own dispatches ignore the override and see their own files.
pub const RefSiteOverride = struct { file: ir.FileId, frame: *const Frame };
threadlocal var ref_site_override: ?RefSiteOverride = null;

/// The active reference-site file, when the innermost frame is still the
/// one the override was pushed under.
pub fn refSiteFile() ?ir.FileId {
    const o = ref_site_override orelse return null;
    const fr = evtls.frame_chain orelse return null;
    return if (fr == o.frame) o.file else null;
}

/// Install a reference-site override on the current innermost frame.
/// Returns the previous override; the caller restores it via
/// `popRefSiteFile` when its dispatch completes.
pub fn pushRefSiteFile(file: ir.FileId) ?RefSiteOverride {
    const prev = ref_site_override;
    if (evtls.frame_chain) |fr| ref_site_override = .{ .file = file, .frame = fr };
    return prev;
}

pub fn popRefSiteFile(prev: ?RefSiteOverride) void {
    ref_site_override = prev;
}

/// Simple name of the function the innermost active frame is executing.
pub fn currentFuncName() ?[]const u8 {
    return if (evtls.frame_chain) |fr| fr.func.name else null;
}

/// The function the innermost active frame is executing. A bare-name field read
/// consults it to learn whether the reader is a member-extension body, whose
/// declaring class is an implicit receiver the read must prefer.
pub fn currentFrameFunc() ?*const ir.Func {
    return if (evtls.frame_chain) |fr| fr.func else null;
}

/// Per-thread free-list of register buffers, reused across calls so a freeing
/// backend pays no per-call alloc/free for the `regs` array. Only used under the
/// reference-counting (freeing) backends: under the tracing GC the buffer memory
/// is GC-owned and must not be hand-recycled; under the arena nothing is freed.
/// Bounded so a deep-then-shallow call profile cannot retain buffers unboundedly.
threadlocal var regs_pool: std.ArrayListUnmanaged([]Value) = .empty;
const REGS_POOL_MAX: usize = 128;

/// Take a zeroed (`.Unit`) register buffer of length `n`, reusing a pooled
/// buffer when one is large enough. The returned list owns its backing. Pooled
/// buffers only ever come from the current top-level evaluation (drained when it
/// unwinds), so they share its allocator.
/// Allocator for frame REGISTER BUFFERS. Under the tracing GC the buffers
/// live outside the GC heap (libc): the collector traces the VALUES through
/// the frame chain but must never sweep the buffer storage, which lets the
/// buffer pool work under GC too — previously every interpreted call
/// allocated a fresh GC-heap buffer and abandoned it, the dominant
/// allocation churn on call-heavy code. Other profiles keep the run
/// allocator (the arena never frees; refcount pools as before).
inline fn regsAlloc(fallback: Allocator) Allocator {
    if (!runtime.reclaimEnabled() and runtime.gc.gc_enabled) return std.heap.c_allocator;
    return fallback;
}

fn acquireRegs(allocator: Allocator, n: u32) Allocator.Error!std.ArrayList(Value) {
    const ra = regsAlloc(allocator);
    if (regs_pool.items.len > 0) {
        const buf = regs_pool.items[regs_pool.items.len - 1];
        if (buf.len >= n) {
            regs_pool.items.len -= 1;
            var list: std.ArrayList(Value) = .{ .items = buf[0..0], .capacity = buf.len };
            list.appendNTimes(ra, .Unit, n) catch unreachable; // capacity already fits
            // Re-enters the traced set (see releaseRegs).
            if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting) runtime.gc.noteExternalBytes(buf.len * @sizeOf(Value));
            return list;
        }
    }
    var regs: std.ArrayList(Value) = .empty;
    try regs.appendNTimes(ra, .Unit, n);
    // Fresh (non-pooled) buffer: advance the collector's Appel trigger.
    // These bytes live outside the sweep registry but are traced through
    // the frame chain; without this a deep suspended chain keeps the
    // trigger at its floor and every collection re-marks the whole chain.
    if (runtime.gc.gc_enabled and runtime.gc.external_accounting) runtime.gc.noteExternalBytes(regs.capacity * @sizeOf(Value));
    return regs;
}

/// Return a frame's register buffer. A nested frame's buffer (`evtls.eval_depth > 0`)
/// is recycled into the pool for a sibling call; the outermost frame's teardown
/// (`evtls.eval_depth == 0`) frees its own buffer and drains the pool, so no recycled
/// buffer ever outlives the top-level evaluation that produced it (or crosses an
/// allocator). Only under a freeing backend — the tracing GC owns this memory and
/// the arena never frees, so neither pools.
fn releaseRegs(allocator: Allocator, regs: *std.ArrayList(Value)) void {
    const ra = regsAlloc(allocator);
    const gc_pool = !runtime.reclaimEnabled() and runtime.gc.gc_enabled;
    const pool_ok = (gc_pool or (runtime.reclaimEnabled() and evtls.eval_depth > 0)) and
        regs.capacity > 0 and regs_pool.items.len < REGS_POOL_MAX;
    if (pool_ok) {
        const buf = regs.allocatedSlice();
        regs.* = .empty;
        // Leaves the traced set (pooled, no live values) — shrink the
        // collector's external-live estimate to match.
        if (gc_pool and runtime.gc.external_accounting) runtime.gc.noteExternalFreed(buf.len * @sizeOf(Value));
        regs_pool.append(ra, buf) catch {
            ra.free(buf);
        };
        return;
    }
    regs.deinit(ra);
    if (!gc_pool and evtls.eval_depth == 0 and regs_pool.items.len > 0) drainRegsPool(allocator);
}

/// Free every pooled register buffer. Called when the outermost frame unwinds
/// (never under the GC pool, whose libc buffers persist for the process).
fn drainRegsPool(allocator: Allocator) void {
    const ra = regsAlloc(allocator);
    for (regs_pool.items) |buf| ra.free(buf);
    regs_pool.clearRetainingCapacity();
}

/// An in-flight `resumeContinuation` on this thread: while it rebuilds a parked
/// activation one frame at a time, the not-yet-rebuilt snapshots live only in
/// its Zig-local `frames` list (already taken out of the park registry, not yet
/// on `evtls.frame_chain`), so a collection during an inner frame's eval would sweep
/// them. Each resume links a node here; the GC marks `frames.items[head..]`.
/// Resumes nest (a resumed frame can suspend/resume again), so it is a chain.
const ResumeFrames = struct {
    prev: ?*ResumeFrames,
    frames: *const std.ArrayList(FrameSnapshot),
    head: *const usize,
    /// Unconsumed inherited segments of the in-flight resume.
    tails: *const ?*TailSeg,
};

/// The per-thread root anchor: stable addresses of this thread's frame chain
/// and in-flight-resume chain. `frame_troot.ctx` points at this.
const FrameAnchor = struct {
    chain: *const ?*Frame,
    resuming: *const ?*ResumeFrames,
};
threadlocal var frame_anchor: FrameAnchor = undefined;
/// This thread's GC root node. Its `ctx` is `&frame_anchor`, so the collector
/// can mark this thread's frames from any thread while it is parked at a safe
/// point. Registered lazily on first frame push; unlinked at the thread's exit
/// seam (its threadlocal storage dies with it).
threadlocal var frame_troot: runtime.gc.ThreadRoot = undefined;
threadlocal var frame_troot_inited: bool = false;

inline fn gcPushFrame(f: *Frame) void {
    // The chain is maintained in every allocator mode (it backs stack-trace
    // capture, not only GC marking); only the GC root registration is gated on
    // the collector being active.
    if (runtime.gc.gc_enabled) gcInstallFrameRoot();
    f.gc_link = evtls.frame_chain;
    evtls.frame_chain = f;
}
inline fn gcPopFrame(f: *Frame) void {
    evtls.frame_chain = f.gc_link;
}

/// Mark every live Value reachable from the `ctx` thread's frame chain and any
/// in-flight resume. `ctx` is that thread's `&frame_anchor`.
fn gcMarkFramesCtx(ctx: *anyopaque, m: *runtime.gc.Marker) void {
    const anchor: *const FrameAnchor = @ptrCast(@alignCast(ctx));
    var cur = anchor.chain.*;
    while (cur) |f| : (cur = f.gc_link) {
        for (f.regs.items) |v| v.gcMark(m);
        for (f.params.items) |v| v.gcMark(m);
        for (f.captures.items) |v| v.gcMark(m);
        for (f.enclosing_this.items) |e| e.v.gcMark(m);
        f.pending_finally.gcMark(m);
        markFrameClosure(f.closure_id, m);
    }
    // Not-yet-rebuilt snapshots of every in-flight resume on this thread.
    var r = anchor.resuming.*;
    while (r) |node| : (r = node.prev) {
        var seg = node.tails.*;
        while (seg) |t| : (seg = t.next) {
            if (m.minor and t.gc_quiesced) continue;
            for (t.frames.items[t.head..]) |snap| gcMarkSnapshot(snap, m);
            t.gc_quiesced = true;
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

/// Keep the side-table slot of a closure whose body is currently on the stack
/// (or parked) alive: marking it live spares it from `reclaimDead`'s id reuse
/// and shades its capture-store cell + receiver chain. The running frame only
/// holds a copy of the capture *values*, so this is the sole thing that roots
/// the slot for a body that outlives the collection that fires during it.
inline fn markFrameClosure(closure_id: ?u64, m: *runtime.gc.Marker) void {
    if (closure_id) |id| {
        if (runtime.gc.markClosureHook) |hook| hook(id, m);
    }
}

/// Link this thread's frame-chain root node (idempotent per thread).
pub fn gcInstallFrameRoot() void {
    if (frame_troot_inited) return;
    frame_troot_inited = true;
    frame_anchor = .{ .chain = &evtls.frame_chain, .resuming = &evtls.resuming };
    frame_troot = .{ .ctx = @ptrCast(&frame_anchor), .mark = gcMarkFramesCtx };
    runtime.gc.registerThreadRoot(&frame_troot);
}

/// Unlink this thread's frame-chain root node at its exit seam and release the
/// libc-backed register buffers cached by this thread.  Big-stack test and
/// intrinsic workers are short-lived, so process-lifetime pooling would leak
/// one cache per completed worker.
pub fn gcUninstallFrameRoot() void {
    if (frame_troot_inited) {
        runtime.gc.unregisterThreadRoot(&frame_troot);
        frame_troot_inited = false;
    }
    if (runtime.gc.gc_enabled and regs_pool.items.len > 0) {
        drainRegsPool(std.heap.c_allocator);
        regs_pool.deinit(std.heap.c_allocator);
    }
}

/// Capture the live call stack (innermost-first) as `StackFrame`s. Each entry
/// records the running function's display label and the source position it is
/// executing (the per-statement `Trace`). Returns null when there is no active
/// frame. The labels borrow program-lifetime module memory; only the frame
/// slice is owned by the returned cell.
fn captureStack(allocator: Allocator) Allocator.Error!?runtime.StackRef {
    var n: usize = 0;
    var cur = evtls.frame_chain;
    while (cur) |f| : (cur = f.gc_link) n += 1;
    if (n == 0) return null;
    const frames = try allocator.alloc(runtime.StackFrame, n);
    var i: usize = 0;
    cur = evtls.frame_chain;
    while (cur) |f| : (cur = f.gc_link) {
        const label = if (f.func.fqn.len != 0) f.func.fqn else f.func.name;
        if (f.cur_span) |sp| {
            frames[i] = .{ .fqn = label, .file_id = @intFromEnum(sp.file), .offset = sp.start, .has_pos = true };
        } else {
            frames[i] = .{ .fqn = label, .file_id = 0, .offset = 0, .has_pos = false };
        }
        i += 1;
    }
    return try runtime.StackRef.init(allocator, .{ .frames = frames });
}

/// Debug helper: print the active frame chain (fqn + current span) to
/// stderr. Env-gated call sites only.
pub fn debugPrintFrames() void {
    var cur = evtls.frame_chain;
    while (cur) |f| : (cur = f.gc_link) {
        var path: []const u8 = "?";
        var line: u32 = 0;
        if (f.cur_span) |sp| {
            if (span.active_map) |m| {
                if (m.getChecked(sp.file)) |sf| {
                    path = sf.path;
                    line = sf.lineCol(sp.start).line;
                }
            }
        }
        std.debug.print("  at {s} ({s}:{d}) span={any}\n", .{ if (f.func.fqn.len != 0) f.func.fqn else f.func.name, path, line, f.cur_span });
    }
}

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

/// Per-test wall-clock deadline (monotonic milliseconds), 0 = disarmed.
/// The test runner arms it before each test phase and clears it after;
/// the eval loop's counter gate checks it on every thread, so a wedged
/// pump or a real-thread deadlock unwinds as a test failure instead of
/// hanging the whole class. Deliberately NOT cleared on fire: a lenient
/// dispatch arm that swallows the first error meets the deadline again
/// at the next gate, so retry ladders cannot absorb it.
pub var test_wall_deadline_ms = std.atomic.Value(i64).init(0);

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

/// Whether dispatch caches may be populated. A wall-capped or abandoned
/// run produces walks that abort mid-probe; caching their outcomes (a
/// spurious METHOD_MISS, a global-skip note, a wrong field-read route)
/// poisoned every later execution of the same site — after one capped
/// test, whole classes failed `unresolved global` on names that resolve
/// fine in a fresh process (the cross-test contamination family).
/// The runner's per-test invariant probe: a nonzero depth between tests
/// is a leak in some unwind path.
pub fn evalDepthNow() usize {
    return evtls.eval_depth;
}

pub fn dispatchCacheStable() bool {
    if (runtime.shouldAbandon()) return false;
    const dl = test_wall_deadline_ms.load(.monotonic);
    return dl == 0 or nowMonotonicMs() <= dl;
}

pub fn nowMonotonicMs() i64 {
    return @intCast(@divTrunc(runtime.clockMonotonicNanos(), std.time.ns_per_ms));
}
threadlocal var spin_last_dump: i64 = 0;
threadlocal var spin_check_counter: u64 = 0;

/// Diagnostic: print the live frame chain (as the spin tracer does), for an
/// error site that raises a traceless Vm error. Gated by KLIO_ERR_TRACE.
pub fn dumpFrameChainForDiag() void {
    if (runtime.getenvSlice("KLIO_ERR_TRACE") == null) return;
    dumpCurrentFrameParamsForDiag();
    dumpFrameChainForDiagAlways();
}

/// Delivery-route tag for KLIO_RESUME_TRACE: which host path drove the
/// current resume (park slot, persisted take, adopt, inline claim...).
pub threadlocal var resume_route: []const u8 = "?";

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
pub fn dumpFrameChainForDiagAlways() void {
    std.debug.print("[errtrace] frame chain (innermost first):\n", .{});
    var cur = evtls.frame_chain;
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
    var cur = evtls.frame_chain;
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
                i, p.name, @tagName(std.meta.activeTag(v.*)), v.typeFqn(),
            });
        }
        // Captures carry a closure's environment; a mis-captured callee
        // slot (`this.LocalFn(...)` binding an Any) is only visible here.
        for (fr.captures.items, 0..) |*cv, i| {
            std.debug.print("  [cap {d}] {s} {s}\n", .{
                i, @tagName(std.meta.activeTag(cv.*)), cv.typeFqn(),
            });
        }
    }
}

fn spinDumpMaybe() void {
    if (!spin_interval_read) {
        spin_interval_read = true;
        if (runtime.getenvSlice("KLIO_SPIN_TRACE")) |v| {
            spin_interval_s = std.fmt.parseInt(i64, v, 10) catch 30;
        }
    }
    const iv = spin_interval_s orelse return;
    const now: i64 = @intCast(runtime.clockMonotonicNanos() / std.time.ns_per_s);
    if (spin_last_dump == 0) {
        spin_last_dump = now;
        return;
    }
    if (now - spin_last_dump < iv) return;
    spin_last_dump = now;
    std.debug.print("[spin] frame chain (innermost first):\n", .{});
    // Innermost frames' scalar registers — live loop state (probe offsets,
    // masks, bit groups) for a loop that never terminates.
    {
        var rf = evtls.frame_chain;
        var fi: usize = 0;
        while (rf) |f0| : (rf = f0.gc_link) {
            if (fi >= 3) break;
            const n = @min(f0.regs.items.len, 60);
            std.debug.print("  [regs#{d} {s}]", .{ fi, f0.func.name });
            for (f0.regs.items[0..n], 0..) |*v, i| {
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
    var cur = evtls.frame_chain;
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
            if (e.message) |m| {
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
        .Exception => |*e| {
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

/// Push `v` as an enclosing implicit receiver for the about-to-be-invoked
/// callable. Appends to the current frame's chain; the invoked frame picks
/// it up at entry. A no-op (silently dropped) when no frame is active.
pub fn pushEnclosing(v: *const Value) void {
    const chain = evtls.active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .receiver }) catch {};
}

/// Push a receiver-lambda subject (`with(x) { … }`'s `x`). The subject is a
/// receiver inside the lambda body, but its `outer` links are not.
pub fn pushEnclosingSubject(v: *const Value) void {
    const chain = evtls.active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .subject }) catch {};
}

/// Push `v` for dispatch-time visibility only (the member-extension
/// visibility filter and field-resolution fallbacks consult the chain
/// while resolving one call). The entry never becomes part of a callee
/// frame's lexical receiver scope.
pub fn pushEnclosingAccess(v: *const Value) void {
    const chain = evtls.active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .access }) catch {};
}

/// Pop the most recent `pushEnclosing`/`pushEnclosingSubject`. A no-op when no
/// frame is active or the chain is empty.
pub fn popEnclosing() void {
    const chain = evtls.active_chain orelse return;
    if (chain.items.len > 0) _ = chain.pop();
}

/// The innermost enclosing `this`, or `null` when the chain is empty.
pub fn enclosingThisLast() ?Value {
    const chain = evtls.active_chain orelse return null;
    if (chain.items.len == 0) return null;
    return chain.items[chain.items.len - 1].v;
}

/// The enclosing-`this` chain, innermost first. Caller owns the returned slice.
pub fn enclosingThisChainAlloc(allocator: Allocator) Allocator.Error![]Value {
    const chain = evtls.active_chain orelse return allocator.alloc(Value, 0);
    var out = try allocator.alloc(Value, chain.items.len);
    var i: usize = 0;
    while (i < chain.items.len) : (i += 1) {
        out[i] = chain.items[chain.items.len - 1 - i].v;
    }
    return out;
}

/// The enclosing-`this` chain with subject tags, innermost first. Caller owns
/// the returned slice.
pub fn enclosingEntriesAlloc(allocator: Allocator) Allocator.Error![]EnclosingEntry {
    const chain = evtls.active_chain orelse return allocator.alloc(EnclosingEntry, 0);
    var out = try allocator.alloc(EnclosingEntry, chain.items.len);
    var i: usize = 0;
    while (i < chain.items.len) : (i += 1) {
        out[i] = chain.items[chain.items.len - 1 - i];
    }
    return out;
}

/// Snapshot the receiver chain a closure created *right here* lexically
/// sees (storage order, innermost last). Kotlin closures resolve bare
/// names against the receivers in scope at their creation site, so the
/// snapshot is taken once at `Lambda`/`AstLambda` execution and seeds the
/// body frame's chain at every later invocation — wherever (and on
/// whichever thread) that happens. `access` entries are dispatch-transient
/// and excluded. Caller owns the returned slice.
pub fn captureChainAlloc(allocator: Allocator) Allocator.Error![]EnclosingEntry {
    const chain = evtls.active_chain orelse return allocator.alloc(EnclosingEntry, 0);
    var out: std.ArrayList(EnclosingEntry) = .empty;
    errdefer out.deinit(allocator);
    for (chain.items) |e| {
        if (e.kind == .access) continue;
        try out.append(allocator, e);
    }
    return out.toOwnedSlice(allocator);
}

fn traceEnclosingEntries(label: []const u8, entries: []const EnclosingEntry) void {
    std.debug.print("[{s}]", .{label});
    for (entries, 0..) |e, i| {
        if (e.v == .Instance) {
            const ig = e.v.Instance.borrow();
            const cg = ig.get().class.borrow();
            std.debug.print(" [{d}]{s}/{s}", .{ i, cg.get().name, @tagName(e.kind) });
            cg.deinit();
            ig.deinit();
        } else {
            std.debug.print(" [{d}]{s}/{s}", .{ i, @tagName(e.v), @tagName(e.kind) });
        }
    }
    std.debug.print("\n", .{});
}

/// Backing allocator for a frame's `enclosing_this` chain. The chain is
/// frame-scoped (created and torn down with the frame, or copied verbatim into
/// a `FrameSnapshot` on suspend), so it is backed by the same per-call
/// allocator the frame's regs/params/captures use.
fn chainAllocator() Allocator {
    // The process-wide slab (NOT `page_allocator`): the enclosing-`this` chain is
    // (re)allocated on every method/extension call that seeds its own receiver,
    // and `page_allocator` would mmap+munmap a page per call — a syscall pair
    // that dominated instance-method dispatch. The slab is global and stable
    // (the chain can outlive a per-call arena via a suspend snapshot) yet fast.
    return runtime.slab.allocator;
}

fn maxEvalDepth() usize {
    if (evtls.eval_depth_cap != 0) return evtls.eval_depth_cap;
    // `procEnvGetVar` reads the whole environment block into a scratch
    // allocator, so a tiny fixed buffer would fail; use the page allocator.
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
    evtls.eval_depth_cap = cap;
    return cap;
}

/// `Result<Value, EvalError>` as data. OOM stays a Zig `error`; this
/// carries the `EvalError` data path.
pub const EvalResult = union(enum) {
    ok: Value,
    err: EvalError,
};

/// Per-instruction control signal from `execInst`. `cont` = the instruction
/// completed (its result, if any, was written to a register); `raised` = a
/// control-flow event occurred and its `EvalError` is in `frame.step_err`;
/// `flat_call` = the instruction is a direct interpreted call the flat driver
/// should run as a pushed activation (request in `frame.flat_call`).
/// A 1-byte return keeps the hot dispatch loop from copying an `EvalResult` per
/// instruction (whose `.ok` is always the ignored `.Unit`).
pub const Step = enum { cont, raised, flat_call };

/// A direct interpreted call the flat driver runs by pushing an activation
/// instead of recursing natively. Carries the resolved callee and the arg
/// buffer (ownership transfers to the new frame's params, exactly as the
/// host fast path transferred it). A closure invocation additionally carries
/// its capture vector, creation-time receiver chain, owning sub-module and
/// closure id — the exact seed `evalWithCapturesChained` would receive.
pub const FlatCallReq = struct {
    func: *const Func,
    /// The module the body resolves against (a closure body always resolves
    /// against its creation module, never the caller's). Null = the calling
    /// frame's module (a same-module direct call).
    run_module: ?*const Module = null,
    /// Owning sub-module for a body lowered into one (anon object / local
    /// class); null for a main-module body. Recorded as the frame's
    /// `module_arc` so a suspension resumes against the right module.
    owning: ?*const Module = null,
    args: std.ArrayList(Value),
    captures: std.ArrayList(Value) = .empty,
    /// Creation-time receiver-chain seed (borrowed; copied into the frame's
    /// chain at activation open).
    chain: []const EnclosingEntry = &.{},
    closure_id: ?u64 = null,
    /// The host pushed an ambient composer for this call; the activation's
    /// teardown must pop it.
    composer_pushed: bool = false,
    /// Access-enclosing entries the call site / prepare pushed for the
    /// dispatch (the caller's `this`, a displaced prior receiver, the
    /// receiver subject); the activation's teardown pops them LIFO after
    /// the frame unwinds, when the caller's chain is active again.
    pop_enclosing_n: u8 = 0,
    /// The context-parameter mark taken BEFORE the prepare pushed a
    /// receiver as a context source (`callValueWithThis` feeds the
    /// receiver into the context stack for the block's duration); the
    /// activation adopts it so its close truncates the push away. Null =
    /// the activation reads the stack length itself at open.
    ctx_mark_override: ?usize = null,
    /// A value the activation must keep alive for its whole life (the
    /// receiver-BOUND closure a with-this prepare builds: the frame's
    /// captures borrow its capture vector). Released at teardown or
    /// parked-drop; GC-marked while live-parked.
    keepalive: ?Value = null,
    /// Undispatched-start boundary (`startCoroutineUninterceptedOrReturn`
    /// under an enclosing pump): a suspension crossing this activation
    /// parks the segment into the pump via the host hook and the CALLER
    /// continues with the hook's value instead of unwinding.
    suspend_barrier: bool = false,
    /// The active-scope depth captured BEFORE the prepare's scope push;
    /// the barrier park hands it to the pump so the scope delta travels
    /// with the parked segment.
    barrier_scope_base: usize = 0,
    /// Identity of the active-scope entry the prepare pushed (0 = none);
    /// teardown removes it by identity. Cleared at park — the parked
    /// delta owns the entry from then on.
    scope_guard_ident: usize = 0,
    /// This barrier activation owns a fresh pump (the no-driver root
    /// branch): its completion or suspension must run the pump loop and
    /// exit through the host hooks. `keepalive` carries the scope value
    /// the pump drives under.
    root_pump: bool = false,
    /// Reified type-name globals the typed-call prepare bound for the
    /// call's duration (opaque host payload); restored via the host hook
    /// at teardown or park, exactly where the recursive path's restore
    /// loop ran (including across a suspension).
    typed_saved: ?*anyopaque = null,
    /// The call site's type arguments (module-owned strings) for the
    /// result transform at the frame boundary (`attachDeclaredElemTypes`).
    type_args: []const []const u8 = &.{},
    dst: Reg,
};

/// A `FlatCallReq` plus the caller's resume point: the block/instruction the
/// caller continues at once the callee's result lands in `req.dst`.
const FlatCallSite = struct {
    req: FlatCallReq,
    ret_block: BlockId,
    ret_idx: usize,
};

/// The suspension point of the frame a `Suspended` escape left: where the
/// frame resumes and which register receives the resume value. Set by the
/// executor for the driver, which parks the frame (live for a flat
/// activation, snapshot for a native root).
const ParkPoint = struct {
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
};

/// One interpreted activation on the flat driver's call stack. Heap-allocated
/// (`allocator.create`) so the Frame's address stays stable on the GC frame
/// chain while the stack list grows. `ret_*` is the resume point in the
/// CALLER frame where this activation's result is delivered.
const Activation = struct {
    frame: Frame,
    try_stack: std.ArrayList(TryFrame),
    ctx_mark: usize,
    /// The context-parameter mark is live and must be truncated when this
    /// activation unwinds or parks. Cleared at the first park — a resumed
    /// activation has no host-entry effects left to unwind.
    ctx_armed: bool,
    composer_pushed: bool,
    pop_enclosing_n: u8,
    keepalive: ?Value,
    suspend_barrier: bool,
    barrier_scope_base: usize,
    scope_guard_ident: usize,
    root_pump: bool,
    typed_saved: ?*anyopaque,
    type_args: []const []const u8,
    ret_block: BlockId,
    ret_idx: usize,
    ret_dst: Reg,
};

/// `KLIO_FLAT=0` falls back to native recursion for every call — the bisect
/// switch for the flat driver.
var flat_enabled_cached: ?bool = null;
fn flatEnabled() bool {
    if (flat_enabled_cached) |b| return b;
    const raw = runtime.getenvSlice("KLIO_FLAT");
    const b = !(raw != null and std.mem.eql(u8, raw.?, "0"));
    flat_enabled_cached = b;
    return b;
}

/// Cached hot-path trace gates: the memoized `getenvSlice` still takes a
/// lock + hashmap probe per consult, which prices every dispatch arm when
/// consulted per executed instruction. The env never changes mid-run.
var cv_trace_cached: ?bool = null;
fn cvTraceOn() bool {
    if (cv_trace_cached) |b| return b;
    const b = runtime.getenvSlice("KLIO_CALLVALUE_TRACE") != null;
    cv_trace_cached = b;
    return b;
}
var lr_trace_cached: ?bool = null;
fn lrTraceOn() bool {
    if (lr_trace_cached) |b| return b;
    const b = runtime.getenvSlice("KLIO_LR_TRACE") != null;
    lr_trace_cached = b;
    return b;
}
var resume_trace_cached: ?bool = null;
fn resumeTraceOn() bool {
    if (resume_trace_cached) |b| return b;
    const b = runtime.getenvSlice("KLIO_RESUME_TRACE") != null;
    resume_trace_cached = b;
    return b;
}
var miss_trace_init: bool = false;
var miss_trace_val: ?[]const u8 = null;
fn missTraceWant() ?[]const u8 {
    if (!miss_trace_init) {
        miss_trace_val = runtime.getenvSlice("KLIO_MISS_TRACE");
        miss_trace_init = true;
    }
    return miss_trace_val;
}
var cmg_trace_init: bool = false;
var cmg_trace_val: ?[]const u8 = null;
fn cmgTraceWant() ?[]const u8 {
    if (!cmg_trace_init) {
        cmg_trace_val = runtime.getenvSlice("KLIO_CMG_TRACE");
        cmg_trace_init = true;
    }
    return cmg_trace_val;
}
var nu_trace_init: bool = false;
var nu_trace_val: ?[]const u8 = null;
fn nuTraceWant() ?[]const u8 {
    if (!nu_trace_init) {
        nu_trace_val = runtime.getenvSlice("KLIO_NU_TRACE");
        nu_trace_init = true;
    }
    return nu_trace_val;
}

/// Host→driver flat-call handoff for resolution ladders whose PICK lives
/// deep in host code (the CMG global-overload terminal): the exec arm arms
/// the slot, the host's terminal takes the arm (one-shot — inner calls see
/// it disarmed), prepares the flat request instead of dispatching, and
/// stashes it here; the arm consumes the stash and pushes the activation.
threadlocal var host_flat_armed: bool = false;
threadlocal var host_flat_req: ?FlatCallReq = null;
pub fn armHostFlatReq() void {
    host_flat_armed = true;
}
pub fn takeHostFlatArm() bool {
    const a = host_flat_armed;
    host_flat_armed = false;
    return a;
}
pub fn stashHostFlatReq(req: FlatCallReq) void {
    host_flat_req = req;
}
fn takeHostFlatReq() ?FlatCallReq {
    const r = host_flat_req;
    host_flat_req = null;
    return r;
}

/// Stash a control-flow `EvalError` on the frame and signal `Step.raised`.
inline fn raiseStep(frame: *Frame, e: EvalError) Step {
    frame.step_err = e;
    return .raised;
}

inline fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

inline fn errResult(e: EvalError) EvalResult {
    return .{ .err = e };
}

/// One active try-region recorded on the eval's try-stack. Separates
/// the *entry* (where to jump to start running finally / catch) from
/// the *done sentinel* (the synthesized block whose entry signals
/// the finally body has run to completion regardless of any internal
/// control flow in the user finally body).
pub const TryFrame = struct {
    /// The try body's entry block — the key for matching pop /
    /// pending-return / pending-rethrow against `Block.finally_done_for`.
    body: BlockId,
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
};

const PendingRethrow = struct { key: BlockId, exc: Value, depth: usize };
const PendingReturn = struct { key: BlockId, val: Value, depth: usize };
const PendingUnwind = struct { key: BlockId, err: EvalError, depth: usize };

/// Control flow paused while a `finally` body runs. It belongs to the active
/// frame so the GC can trace it, and moves into/out of a frame snapshot when
/// that finally body suspends.
const PendingFinallyState = struct {
    rethrow: ?PendingRethrow = null,
    return_value: ?PendingReturn = null,
    unwind: ?PendingUnwind = null,

    fn tryDepth(self: PendingFinallyState) ?usize {
        if (self.rethrow) |p| return p.depth;
        if (self.return_value) |p| return p.depth;
        if (self.unwind) |p| return p.depth;
        return null;
    }

    fn payloadOfError(err: EvalError) ?Value {
        return switch (err) {
            .Throw => |v| v,
            .NonLocalReturn => |v| v,
            .LabeledReturn => |lr| lr.value,
            else => null,
        };
    }

    fn gcMark(self: PendingFinallyState, marker: *runtime.gc.Marker) void {
        if (self.rethrow) |p| p.exc.gcMark(marker);
        if (self.return_value) |p| p.val.gcMark(marker);
        if (self.unwind) |p| if (payloadOfError(p.err)) |v| v.gcMark(marker);
    }

    fn release(self: *PendingFinallyState, allocator: Allocator) void {
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

    fn savedLen(self: SnapshotRegisters) usize {
        return switch (self) {
            .dense => |values| values.len,
            .sparse => |entries| entries.len,
        };
    }

    fn isDense(self: SnapshotRegisters) bool {
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

fn noteSuspendSnapshot(dense: bool, total: usize, saved: usize, params: usize, captures: usize, receivers: usize) void {
    const enabled = suspend_stats_enabled orelse blk: {
        const on = runtime.getenvSlice("KLIO_SUSPEND_STATS") != null;
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
fn suspendLiveRegs(func: *const Func, block: BlockId, inst_idx: usize) Allocator.Error![]const u32 {
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

fn snapshotRegisters(
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
fn retainSnapshotValues(snap: FrameSnapshot) void {
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

fn gcMarkSnapshot(snap: FrameSnapshot, m: *runtime.gc.Marker) void {
    if (snap.live) |act| {
        for (act.frame.regs.items) |v| v.gcMark(m);
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
fn freeSnapshotBuffers(snap: FrameSnapshot, allocator: Allocator) void {
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

/// Per-call evaluation frame.
const Frame = struct {
    module: *const Module,
    func: *const Func,
    regs: std.ArrayList(Value),
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
    /// Source span of the statement this frame is currently executing, set by
    /// the `Trace` instruction the lowerer emits per statement. Read when a
    /// throw captures the call stack so each frame reports its in-progress
    /// source position (file + line) rather than only its declaration site.
    cur_span: ?ir.Span = null,

    fn newWithCaptures(
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
            const caller = if (evtls.frame_chain) |fr| (if (fr.func.fqn.len != 0) fr.func.fqn else fr.func.name) else "<none>";
            std.debug.print("[frame-short] fn={s} args={d} params={d} caller={s}\n", .{
                if (func.fqn.len != 0) func.fqn else func.name, params.items.len, func.params.len, caller,
            });
        }
        coerceIntArgsToLong(func, params.items);
        coerceGenericIntPeersToLong(module, func, params.items);
        const regs = try acquireRegs(allocator, func.n_locals);
        return .{
            .module = module,
            .func = func,
            .regs = regs,
            .params = params,
            .captures = captures,
            .enclosing_this = .empty,
            .prev_chain = null,
            .prev_chain_base = 0,
            .module_arc = null,
            .allocator = allocator,
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
    fn activateChain(self: *Frame, seed: []const EnclosingEntry) Allocator.Error!void {
        for (seed) |e| {
            if (e.kind == .access) continue;
            try self.enclosing_this.append(chainAllocator(), e);
        }
        if (evtls.active_chain) |caller| {
            for (caller.items[@min(evtls.active_chain_base, caller.items.len)..]) |e| {
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
    fn activateChainFrom(self: *Frame, saved: []const EnclosingEntry) Allocator.Error!void {
        try self.enclosing_this.appendSlice(chainAllocator(), saved);
        self.activateAs();
    }

    fn activateAs(self: *Frame) void {
        self.prev_chain = evtls.active_chain;
        self.prev_chain_base = evtls.active_chain_base;
        evtls.active_chain = &self.enclosing_this;
        evtls.active_chain_base = self.enclosing_this.items.len;
    }

    fn deactivateChain(self: *Frame) void {
        evtls.active_chain = self.prev_chain;
        evtls.active_chain_base = self.prev_chain_base;
    }

    fn deinit(self: *Frame) void {
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
        releaseRegs(self.allocator, &self.regs);
        self.params.deinit(self.allocator);
        self.captures.deinit(self.allocator);
        self.enclosing_this.deinit(chainAllocator());
    }

    fn read(self: *const Frame, r: Reg) Value {
        const idx = r.int();
        if (idx < self.regs.items.len) return self.regs.items[idx];
        return .Unit;
    }

    /// Store `v` into register `r`, taking ownership of one reference to `v`.
    /// The previous occupant is released. No refcount traffic under the arena.
    fn write(self: *Frame, r: Reg, v: Value) Allocator.Error!void {
        const idx = r.int();
        if (idx >= self.regs.items.len) {
            try self.regs.appendNTimes(regsAlloc(self.allocator), .Unit, idx + 1 - self.regs.items.len);
        }
        if (runtime.reclaimEnabled()) {
            const old = self.regs.items[idx];
            self.regs.items[idx] = v;
            old.release(self.allocator);
        } else {
            self.regs.items[idx] = v;
        }
    }

    fn block(self: *const Frame, b: BlockId) *const ir.Block {
        return &self.func.blocks[b.int()];
    }
};

/// Normalize an `Int` value occupying a non-nullable `Long` slot to a
/// `Long`. Kotlin types an integer literal by its expected type, so a
/// bare `0` flowing into a `Long` parameter / return slot is a `Long`,
/// not an `Int`; without this the value keeps its `Int` tag and later
/// `Long`-vs-`Int` equality / division on it misbehaves. Only `Int`
/// values are touched, so a genuine `Int` in an `Int` slot is left
/// exactly as produced.
fn coerceIntToLongTy(ty: TypeRef, v: *Value) void {
    if (v.* == .Int and !ty.nullable and std.mem.eql(u8, ty.name, "Long")) {
        const n = v.Int;
        v.* = .{ .Long = @as(i64, n) };
    }
}

/// Apply `coerceIntToLongTy` to each argument against its declared
/// parameter type (e.g. `safeMultiply(a: Long, b: Long)` seeing an
/// `Int` `a` would make `r / b != a` spuriously true). `vararg` slots
/// are skipped — their bound value is the packed array, not an element.
fn coerceIntArgsToLong(func: *const Func, params: []Value) void {
    var i: usize = 0;
    while (i < params.len and i < func.params.len) : (i += 1) {
        if (!func.params[i].is_vararg) {
            coerceIntToLongTy(func.params[i].ty, &params[i]);
        }
    }
}

/// Whether `name` is one of the function's declared type-parameter names
/// (`T` of a `fun <T> f(...)`). A param typed by a bare type variable holds
/// whatever the call-site type argument resolved to.
fn isFuncTypeParam(module: *const Module, func: *const Func, name: []const u8) bool {
    if (module.registry.func_type_params.get(func.id)) |tps| {
        for (tps.items) |t| if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// Kotlin types an integer literal by the type it flows into, so a bare `0`
/// passed to a type-variable param (`T`) whose call-site argument is `Long`
/// becomes a `Long` (e.g. `assertEquals(0, longValue)` infers `T = Long`).
/// At runtime a literal `Int` flowing into a shared `T` slot keeps its `Int`
/// tag; when a peer param bound to the same `T` is a `Long`, widen it so the
/// generic body's boxed `T == T` comparison sees two `Long`s. Only the
/// literal-coercion shape this captures can produce an `Int`/`Long` mix in a
/// shared type variable in valid Kotlin, so the widen is always safe.
fn coerceGenericIntPeersToLong(module: *const Module, func: *const Func, params: []Value) void {
    const n = @min(params.len, func.params.len);
    if (n < 2) return;
    var has_tparam = false;
    for (func.params[0..n]) |*p| {
        if (!p.ty.nullable and isFuncTypeParam(module, func, p.ty.name)) {
            has_tparam = true;
            break;
        }
    }
    if (!has_tparam) return;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const iv = params[i];
        if (iv != .Int) continue;
        const ti = func.params[i].ty;
        if (ti.nullable or !isFuncTypeParam(module, func, ti.name)) continue;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (j == i or params[j] != .Long) continue;
            if (std.mem.eql(u8, func.params[j].ty.name, ti.name)) {
                params[i] = .{ .Long = @as(i64, iv.Int) };
                break;
            }
        }
    }
}

/// Run a function body with the given positional arguments. Returns the
/// value carried by the terminating `Return`, or `Unit` for a
/// fall-off. Uses `nullHost` for delegated calls.
///
/// `args` ownership transfers in (it is the frame's params backing).
pub fn eval(allocator: Allocator, module: *const Module, func: *const Func, args: std.ArrayList(Value)) Allocator.Error!EvalResult {
    var host = nullHost();
    return evalWith(NullHost, allocator, module, func, args, &host);
}

/// Run a function body, routing non-trivial dispatch (`CallValue` /
/// `CallMember` / `NewInstance` / `InstanceOf`) through the supplied
/// host implementation. `H` is the concrete host type, supplied at the
/// call site (`VmHost` in the interpreter, `NullHost` in ir's own tests);
/// every `host.method(...)` is a comptime-duck-typed direct call.
pub fn evalWith(comptime H: type, allocator: Allocator, module: *const Module, func: *const Func, args: std.ArrayList(Value), host: *H) Allocator.Error!EvalResult {
    dumpFnIfRequested(module, func);
    return evalWithCaptures(H, allocator, module, func, args, .empty, host);
}

/// `KLIO_DUMP_FN=<name>`: print the named function's lowered instruction
/// stream (tag + key operands) the first time it runs. The only way to see
/// what an emit path actually produced for a body inside a baked pack.
var dump_fn_done: bool = false;
/// Cached `KLIO_DUMP_FN` value; empty slice = unset.
var dump_fn_want: ?[]const u8 = null;
pub fn dumpFnIfRequested(module: *const Module, func: *const Func) void {
    const want = dump_fn_want orelse blk: {
        // Consulted per frame creation on the hot call path: even the
        // memoized env probe costs a spinlock + hashmap probe, so cache
        // the answer in a file-local once.
        const w = runtime.getenvSlice("KLIO_DUMP_FN") orelse "";
        dump_fn_want = w;
        break :blk w;
    };
    if (want.len == 0) return;
    if (dump_fn_done) return;
    // `#<id>` selects by FuncId — the only handle for synthetic names
    // (`<lambda>`) that dozens of functions share.
    if (want.len > 1 and want[0] == '#') {
        const id = std.fmt.parseInt(u32, want[1..], 10) catch return;
        if (func.id.int() != id) return;
    } else if (!std.mem.eql(u8, func.name, want)) return;
    // A deferred body has no blocks yet; wait for the post-materialize call.
    if (func.blocks.len == 0) return;
    dump_fn_done = true;
    std.debug.print("[dump-fn] {s}#{d} params={d} blocks={d} recv_ty={?s} caps=", .{ func.name, func.id.int(), func.params.len, func.blocks.len, func.lambda_receiver_ty });
    for (func.capture_order) |cn| std.debug.print("{s},", .{cn});
    std.debug.print("\n", .{});
    for (func.blocks, 0..) |*blk, bi| {
        std.debug.print("  block {d}:\n", .{bi});
        for (blk.insts, 0..) |*inst, ii| {
            std.debug.print("    {d}: {s}", .{ ii, @tagName(std.meta.activeTag(inst.*)) });
            switch (inst.*) {
                .LoadGlobal => |x| std.debug.print(" name={s} func={?}", .{ constStr(module, x.name) orelse "?", if (x.func) |f| f.int() else null }),
                .GetField => |x| std.debug.print(" field={s}", .{constStr(module, x.field) orelse "?"}),
                .LoadFromThisOrGlobal => |x| std.debug.print(" name={s} func={?}", .{ constStr(module, x.name) orelse "?", if (x.func) |f| f.int() else null }),
                .CallMemberOrGlobal => |x| std.debug.print(" name={s} recv={?d} this_idx={d} dst=r{d}", .{ constStr(module, x.name) orelse "?", if (x.recv) |r| r.int() else null, x.this_idx, x.dst.int() }),
                .CallMember => |x| std.debug.print(" name={s} recv=r{d}", .{ constStr(module, x.name) orelse "?", x.receiver.int() }),
                .LoadCapture => |x| std.debug.print(" idx={d} dst=r{d}", .{ x.idx, x.dst.int() }),
                .Move => |x| std.debug.print(" dst=r{d} src=r{d}", .{ x.dst.int(), x.src.int() }),
                else => {},
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("    term: {s}\n", .{@tagName(std.meta.activeTag(blk.terminator))});
    }
}

/// Like `evalWith` but seeds the frame with a captured-values vector.
/// Used by closure invocation so `Inst.LoadCapture` reads from the
/// closure's snapshotted env rather than the call args.
pub fn evalWithCaptures(comptime H: type, allocator: Allocator, module: *const Module, func: *const Func, args: std.ArrayList(Value), captures: std.ArrayList(Value), host: *H) Allocator.Error!EvalResult {
    return evalWithCapturesIn(H, allocator, module, null, func, args, captures, host);
}

/// Run a method/closure that was lowered into a per-method *sub-module*
/// (anonymous object / local class / nested class). `owning` is the
/// handle to that sub-module; the frame records it so a suspension
/// inside the body resumes by resolving its `FuncId` against this
/// module, not the main one. `module` must be `owning` when `owning` is
/// non-null.
pub fn evalWithCapturesIn(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    owning: ?*const Module,
    func: *const Func,
    args: std.ArrayList(Value),
    captures: std.ArrayList(Value),
    host: *H,
) Allocator.Error!EvalResult {
    return evalWithCapturesChained(H, allocator, module, owning, func, args, captures, &.{}, null, host);
}

/// A `return@label` targets a frame when the frame's function carries
/// that name directly or as its implicit lambda label. A lambda's body
/// func is named synthetically, so an explicit/implicit label (`sc@`,
/// `with`, …) only ever matches through `implicit_label` — used when a
/// labeled return is spliced out of an inlined argument lambda as a
/// `LabeledReturn` and must unwind to the labeled lambda's frame.
/// Pop try frames until one with a finally is found (skipping the frame whose
/// finally body is currently executing, `cur`); catch clauses never intercept
/// a non-local return. Null when no finally remains armed.
fn nearestFinally(try_stack: *std.ArrayList(TryFrame), cur: BlockId) ?struct { jump: BlockId, key: BlockId } {
    while (try_stack.pop()) |tf| {
        if (tf.finally_entry) |fin| {
            if (std.meta.eql(fin, cur)) continue;
            const key = tf.finally_done orelse fin;
            return .{ .jump = fin, .key = key };
        }
    }
    return null;
}

/// Where a non-local return goes once this frame's finallys have run: a
/// labeled return is absorbed by the frame carrying its label, an untargeted
/// one by the nearest non-lambda non-inline frame; anything else keeps
/// unwinding as an error the caller frame routes the same way.
fn unwindTerminal(frame: *Frame, e: EvalError) EvalResult {
    switch (e) {
        .NonLocalReturn => |v| {
            if (frame.func.is_lambda or frame.func.is_inline) {
                return errResult(.{ .NonLocalReturn = v });
            }
            return ok(v);
        },
        .LabeledReturn => |lr| {
            if (frameMatchesLabel(frame.func, lr.label)) {
                return ok(lr.value);
            }
            return errResult(e);
        },
        else => return errResult(e),
    }
}

fn frameMatchesLabel(func: *const Func, label: []const u8) bool {
    if (std.mem.eql(u8, func.name, label)) return true;
    // A collision-mangled declaration (`makePending$f172`, a file-private
    // or internal rename) still answers its SOURCE-name label: the
    // lambda's non-local `return` was lowered against the declared name
    // before the lift renamed the function.
    if (func.name.len > label.len and func.name[label.len] == '$' and
        std.mem.startsWith(u8, func.name, label))
    {
        return true;
    }
    if (func.implicit_label) |il| return std.mem.eql(u8, il, label);
    return false;
}

/// Like `evalWithCapturesIn` but additionally seeds the frame's
/// enclosing-`this` chain with `chain_seed` (storage order, innermost
/// last). This is the closure-invocation entry: the seed is the closure's
/// creation-time receiver snapshot, so the body resolves bare names
/// against the receivers it lexically closed over, not whatever the
/// dynamic caller happens to have in scope.
pub fn evalWithCapturesChained(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    owning: ?*const Module,
    func: *const Func,
    args: std.ArrayList(Value),
    captures: std.ArrayList(Value),
    chain_seed: []const EnclosingEntry,
    closure_id: ?u64,
    host: *H,
) Allocator.Error!EvalResult {
    dumpFnIfRequested(module, func);
    var try_stack: std.ArrayList(TryFrame) = .empty;
    defer try_stack.deinit(allocator);
    var frame = try Frame.newWithCaptures(allocator, module, func, args, captures);
    frame.closure_id = closure_id;
    defer frame.deinit();
    gcPushFrame(&frame);
    defer gcPopFrame(&frame);
    frame.module_arc = owning;
    try frame.activateChain(chain_seed);
    defer frame.deactivateChain();
    // Context-parameter resolution: a contextual program feeds each frame's
    // dispatch/extension receiver into the context stack so a contextual
    // callee resolves it as a context argument (KEEP: receivers are context
    // sources). The frame's pushes unwind on any exit, including errors.
    const ctx_mark: usize = if (comptime @hasDecl(H, "ctxStackLen")) host.ctxStackLen() else 0;
    if (comptime @hasDecl(H, "ctxPush")) {
        if (module.has_context_decls) {
            if (comptime @hasDecl(H, "ctxActivate")) host.ctxActivate(true);
            if (func.has_receiver_param and frame.params.items.len > 0) {
                host.ctxPush(frame.params.items[0]) catch {};
            }
        }
    }
    defer if (comptime @hasDecl(H, "ctxStackTruncate")) host.ctxStackTruncate(ctx_mark);
    const cur = func.entry;
    const result = try runFrame(H, allocator, module, &frame, &try_stack, cur, 0, host);
    return frameBoundary(func, result);
}

/// The transforms every interpreted frame's result crosses at its callee
/// boundary, whether the frame ran via native recursion or as a flat
/// activation: absorb a labeled return this function owns, normalize an
/// `Int` literal in a `Long` return slot, and re-tag resolution-class
/// escapes of a RAN body as `CalleeFailed` so no enclosing candidate walk
/// retries (and re-executes) a body that already performed side effects.
fn frameBoundary(func: *const Func, result_in: EvalResult) EvalResult {
    var result = result_in;
    // A labeled return whose target is this function exits it as a
    // normal return. Other labels propagate further outward until the
    // matching frame catches them.
    if (result == .err and result.err == .LabeledReturn) {
        if (lrTraceOn()) {
            std.debug.print("[lr-exit] label={s} func={s} match={}\n", .{ result.err.LabeledReturn.label, func.name, frameMatchesLabel(func, result.err.LabeledReturn.label) });
        }
    }
    if (result == .err and result.err == .LabeledReturn and
        frameMatchesLabel(func, result.err.LabeledReturn.label))
    {
        result = ok(result.err.LabeledReturn.value);
    }
    if (result == .err and result.err == .LabeledReturn) {
        if (lrTraceOn()) {
            std.debug.print("[lr] label={s} passed_frame={s} implicit={s}\n", .{ result.err.LabeledReturn.label, func.name, func.implicit_label orelse "-" });
        }
    }
    // A bare integer literal returned where the declared return type is
    // `Long` (`fun f(): Long = 0`) carries an `Int` tag out of the
    // body; normalize it so the caller's `Long` binding observes a
    // `Long`.
    if (result == .ok) {
        coerceIntToLongTy(func.return_ty, &result.ok);
    }
    if (result == .err) {
        switch (result.err) {
            .Unimplemented, .Unbound, .Type, .Unsupported, .Arity => |m| {
                // `KLIO_AMP_TRACE=<substr>` names the RUN body whose escape
                // is being re-tagged — the frames are gone by the time the
                // error surfaces, so this is the only record of the failing
                // function.
                if (runtime.getenvSlice("KLIO_AMP_TRACE")) |w| {
                    if (std.mem.indexOf(u8, m, w) != null) {
                        std.debug.print("[amp] body={s} fqn={s} err={s} msg={s}\n", .{ func.name, func.fqn, @tagName(std.meta.activeTag(result.err)), m });
                        dumpFrameChainForDiagAlways();
                    }
                }
                result = errResult(.{ .CalleeFailed = m });
            },
            else => {},
        }
    }
    return result;
}

/// Resume a parked coroutine. `resume_value` is written into the
/// innermost frame's resume register, then that frame runs to
/// completion (or re-suspends). When it returns, its value feeds the
/// next-outer frame's resume register, and so on up the stack.
pub fn resumeContinuation(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    state: *SuspendState,
    resume_value: Value,
    host: *H,
) Allocator.Error!EvalResult {
    var carry = resume_value;
    // `frames` is innermost-first (the deepest activation snapshots
    // itself first as `Suspended` unwinds). Resume the innermost, then
    // feed its return value to the next-outer frame, and so on. When the
    // fresh list is drained, consumption continues through the inherited
    // `tails` segments (see `TailSeg`) — one segment at a time, promoting
    // each into `frames`/`head` so the loop and the GC root see one shape.
    var frames = state.frames;
    var tails: ?*TailSeg = state.tails;
    // Ownership of both moves into this resume; the state must not tear
    // them down (or double-free segments a re-suspend hands to the inner
    // continuation).
    state.tails = null;
    // The state is live again: resume writes carry values into its frames,
    // so it no longer qualifies for the minor-mark quiescent skip.
    state.gc_quiesced = false;
    defer frames.deinit(allocator);
    defer {
        var seg = tails;
        while (seg) |t| {
            const next = t.next;
            t.frames.deinit(allocator);
            allocator.destroy(t);
            seg = next;
        }
    }
    var head: usize = 0;
    // Root the not-yet-rebuilt outer snapshots (`frames.items[head..]` and
    // the unconsumed tail segments) for the duration of the resume: they are
    // out of the park registry and not yet on the frame chain, so an inner
    // frame's collection would otherwise sweep them.
    var resume_node = ResumeFrames{ .prev = evtls.resuming, .frames = &frames, .head = &head, .tails = &tails };
    if (runtime.gc.gc_enabled) {
        gcInstallFrameRoot();
        evtls.resuming = &resume_node;
    }
    defer if (runtime.gc.gc_enabled) {
        evtls.resuming = resume_node.prev;
    };
    var first = true;
    var pending_throw_from_inner: ?Value = null;
    var pending_unwind_from_inner: ?EvalError = null;
    _ = &resume_route;
    while (true) {
        if (head >= frames.items.len) {
            // Promote the next inherited segment.
            const seg = tails orelse break;
            tails = seg.next;
            frames.deinit(allocator);
            frames = seg.frames;
            head = seg.head;
            allocator.destroy(seg);
            continue;
        }
        const snap = frames.items[head];
        head += 1;
        // A live-parked flat activation resumes by reinstalling the intact
        // frame — no rebuild, no copies. Its result routes exactly like a
        // rebuilt frame's.
        if (snap.live) |act| {
            var resume_throw: ?Value = null;
            var resume_unwind: ?EvalError = null;
            if (pending_throw_from_inner) |exc| {
                pending_throw_from_inner = null;
                resume_throw = exc;
            } else if (pending_unwind_from_inner) |e| {
                pending_unwind_from_inner = null;
                resume_unwind = e;
            } else if (first) {
                if (carry == .Result and !carry.Result.ok) {
                    resume_throw = carry.Result.payload.asPtr().*;
                }
            }
            first = false;
            if (resumeTraceOn()) {
                std.debug.print("[resume-frame] {s}#{d} LIVE at={d}:{d} throw={} via={s}\n", .{
                    act.frame.func.name,
                    act.frame.func.id.int(),
                    snap.block.int(),
                    snap.inst_idx,
                    resume_throw != null,
                    resume_route,
                });
            }
            const r = try resumeLiveActivation(H, allocator, act, carry, snap.block, snap.inst_idx, snap.resume_reg, resume_throw, resume_unwind, host);
            switch (try routeResumedResult(allocator, r, &frames, head, &tails, &carry, &pending_throw_from_inner, &pending_unwind_from_inner)) {
                .next => continue,
                .done => |out| return out,
            }
        }
        // Resolve the frame's `FuncId` against the module it was lowered
        // into — a per-method sub-module for an anon-object / local /
        // nested class, the passed-in (main) module otherwise.
        const snap_module = snap.module;
        const m: *const Module = snap_module orelse module;
        const func = m.funcById(snap.func).?;
        // KLIO_RESUME_TRACE: name every frame a resume drive re-runs — the
        // instrument that finds a tail executing twice in one unwind. The
        // route tag says which delivery path drove it (set by the host's
        // resumeRaw call sites).
        if (resumeTraceOn()) {
            const loc = funcFirstLoc(func);
            std.debug.print("[resume-frame] {s}#{d} ({s}:{d}) at={d}:{d} throw={} pending={}/{}/{} caps={d} enc={d} via={s} id={x}\n", .{
                func.name,
                func.id.int(),
                loc.path,
                loc.line,
                snap.block.int(),
                snap.inst_idx,
                pending_throw_from_inner != null,
                snap.pending_finally.rethrow != null,
                snap.pending_finally.return_value != null,
                snap.pending_finally.unwind != null,
                snap.captures.len,
                snap.enclosing_this.len,
                resume_route,
                snap.regs.ptrIdentity(),
            });
            traceEnclosingEntries("resume-enclosing", snap.enclosing_this);
        }
        var params: std.ArrayList(Value) = .empty;
        try params.appendSlice(allocator, snap.params);
        var caps: std.ArrayList(Value) = .empty;
        try caps.appendSlice(allocator, snap.captures);
        var frame = try Frame.newWithCaptures(allocator, m, func, params, caps);
        frame.closure_id = snap.closure_id;
        frame.pending_finally = snap.pending_finally;
        defer frame.deinit();
        gcPushFrame(&frame);
        defer gcPopFrame(&frame);
        frame.module_arc = snap_module;
        // This frame adopts the references the snapshot retained on suspend:
        // its params/captures (and regs, always owned) are released by its
        // teardown, balancing the suspend-time retain.
        frame.owns_params_caps = true;
        // Restore the frame's enclosing-`this` chain verbatim so implicit
        // receivers resolved before the park resolve identically after it.
        try frame.activateChainFrom(snap.enclosing_this);
        defer frame.deactivateChain();
        switch (snap.regs) {
            .sparse => |entries| {
                for (entries) |entry| {
                    if (entry.id < frame.regs.items.len) frame.regs.items[entry.id] = entry.value;
                }
            },
            .dense => |values| {
                frame.regs.clearRetainingCapacity();
                try frame.regs.appendSlice(regsAlloc(allocator), values);
            },
        }
        // Kotlin `Continuation.resumeWith(Result.failure(e))` means
        // "resume by throwing `e` at the suspension point". Only the
        // innermost (suspending) frame sees the raw failure Result;
        // route it as a throw there instead of delivering it as the
        // suspending call's value, so a cancellation preempts a parked
        // `delay`/acquire rather than letting it complete.
        var resume_throw: ?Value = null;
        var resume_unwind: ?EvalError = null;
        if (pending_throw_from_inner) |exc| {
            pending_throw_from_inner = null;
            resume_throw = exc;
        } else if (pending_unwind_from_inner) |e| {
            pending_unwind_from_inner = null;
            resume_unwind = e;
        } else if (first) {
            if (carry == .Result and !carry.Result.ok) {
                resume_throw = carry.Result.payload.asPtr().*;
            }
        }
        first = false;
        if (resume_throw == null) {
            if (snap.resume_reg) |r| {
                try frame.write(r, carry);
            }
        }
        var try_stack: std.ArrayList(TryFrame) = .empty;
        defer try_stack.deinit(allocator);
        try try_stack.appendSlice(allocator, snap.try_stack);
        // Everything the snapshot held is now copied into frame-owned buffers
        // (regs/params/captures/chain/try-stack); the frame owns the value
        // references (released by its teardown). Free the snapshot's own slice
        // buffers — but not its values, which moved into the frame.
        freeSnapshotBuffers(snap, allocator);
        const r = try runFrameInner(
            H,
            allocator,
            m,
            &frame,
            &try_stack,
            snap.block,
            snap.inst_idx,
            resume_throw,
            resume_unwind,
            host,
        );
        switch (try routeResumedResult(allocator, r, &frames, head, &tails, &carry, &pending_throw_from_inner, &pending_unwind_from_inner)) {
            .next => {},
            .done => |out| return out,
        }
    }
    return ok(carry);
}

const ResumeRoute = union(enum) { next, done: EvalResult };

/// Route one resumed frame's result within `resumeContinuation`'s drive
/// loop: a value carries outward; a re-suspension links the still-pending
/// outer snapshots as an inherited segment in O(1) (copying them made deep
/// recursion quadratic in the parked depth); a throw / non-local return
/// re-enters the next-outer frame so its restored try-stack (and label
/// match) can take it; a resolution-class failure of a RAN frame re-tags as
/// `CalleeFailed` so no walker retries it.
fn routeResumedResult(
    allocator: Allocator,
    r: EvalResult,
    frames: *std.ArrayList(FrameSnapshot),
    head: usize,
    tails: *?*TailSeg,
    carry: *Value,
    pending_throw_from_inner: *?Value,
    pending_unwind_from_inner: *?EvalError,
) Allocator.Error!ResumeRoute {
    switch (r) {
        .ok => |v| carry.* = v,
        .err => |e| switch (e) {
            .Suspended => |inner| {
                if (head < frames.items.len or tails.* != null) {
                    const seg = try allocator.create(TailSeg);
                    seg.* = .{ .frames = frames.*, .head = head, .next = tails.* };
                    frames.* = .empty;
                    tails.* = null;
                    // Append to the END of inner's (short) existing chain:
                    // inner's own inherited segments are deeper (inner-more)
                    // than ours.
                    var slot: *?*TailSeg = &inner.tails;
                    while (slot.*) |t| slot = &t.next;
                    slot.* = seg;
                }
                return .{ .done = errResult(.{ .Suspended = inner }) };
            },
            .Throw => |exc| {
                if (head >= frames.items.len and tails.* == null) {
                    return .{ .done = errResult(.{ .Throw = exc }) };
                }
                pending_throw_from_inner.* = exc;
            },
            .NonLocalReturn, .LabeledReturn => {
                if (head >= frames.items.len and tails.* == null) {
                    return .{ .done = errResult(e) };
                }
                pending_unwind_from_inner.* = e;
            },
            .Unimplemented => |msg| return .{ .done = errResult(.{ .CalleeFailed = msg }) },
            else => return .{ .done = errResult(e) },
        },
    }
    return .next;
}

/// Run (or resume) a single activation's block loop. `resume_idx` is the
/// instruction index to begin at within `cur` (0 for a fresh call, the
/// post-suspension index on resume).
fn runFrame(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur: BlockId,
    resume_idx: usize,
    host: *H,
) Allocator.Error!EvalResult {
    // Every nested Kotlin call re-enters here (the host invokes a callable by
    // calling back into the evaluator). Bounding this depth converts an
    // unbounded recursion into a catchable `StackOverflowError` before the
    // native stack faults.
    if (evtls.eval_depth >= maxEvalDepth()) {
        dumpFrameChainForDiag();
        return errResult(.{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" });
    }
    evtls.eval_depth += 1;
    defer {
        evtls.eval_depth -= 1;
        // Safe point: back at the outermost activation, no native JIT frame is on
        // the stack, so the JIT cache can be trimmed if it has grown past its cap.
        if (evtls.eval_depth == 0) jit_loop.evictIfOverBudget();
    }
    return runFrameInner(H, allocator, module, frame, try_stack, cur, resume_idx, null, null, host);
}

/// Snapshot `frame` (evtls.resuming at `block`:`inst_idx`, resume value delivered
/// into `resume_reg`) and append it to `state`'s frame list. Ownership of the
/// frame's pending-finally payload moves into the snapshot; the frame's own
/// teardown must then run (it releases regs the snapshot has retained).
fn snapshotSuspendedFrame(
    allocator: Allocator,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    state: *SuspendState,
) Allocator.Error!void {
    const saved_regs = try snapshotRegisters(
        allocator,
        frame.func,
        block,
        inst_idx,
        resume_reg,
        frame.regs.items,
        try_stack.items.len == 0,
    );
    noteSuspendSnapshot(
        saved_regs.isDense(),
        frame.regs.items.len,
        saved_regs.savedLen(),
        frame.params.items.len,
        frame.captures.items.len,
        frame.enclosing_this.items.len,
    );
    const snap: FrameSnapshot = .{
        .func = frame.func.id,
        .module = frame.module_arc,
        .block = block,
        .inst_idx = inst_idx,
        .regs = saved_regs,
        .params = blk: {
            if (runtime.gc.gc_enabled and runtime.gc.external_accounting) runtime.gc.noteExternalBytes((frame.params.items.len + frame.captures.items.len) * @sizeOf(Value));
            break :blk try allocator.dupe(Value, frame.params.items);
        },
        .captures = try allocator.dupe(Value, frame.captures.items),
        .enclosing_this = try allocator.dupe(EnclosingEntry, frame.enclosing_this.items),
        .try_stack = try allocator.dupe(TryFrame, try_stack.items),
        .pending_finally = frame.pending_finally,
        .is_lambda = frame.func.is_lambda,
        .resume_reg = resume_reg,
        .closure_id = frame.closure_id,
    };
    if (resumeTraceOn()) {
        std.debug.print("[suspend-frame] {s}#{d} at={d}:{d} pending={}/{}/{} caps={d} enc={d}\n", .{
            frame.func.name,
            frame.func.id.int(),
            block.int(),
            inst_idx,
            frame.pending_finally.rethrow != null,
            frame.pending_finally.return_value != null,
            frame.pending_finally.unwind != null,
            frame.captures.items.len,
            frame.enclosing_this.items.len,
        });
        traceEnclosingEntries("suspend-enclosing", frame.enclosing_this.items);
    }
    // The snapshot now holds the only references that will survive this
    // frame's teardown (its regs are released as the stack unwinds; its
    // params/captures alias caller regs / closure captures the unwind also
    // releases).
    retainSnapshotValues(snap);
    try state.frames.append(allocator, snap);
    // Ownership of the pending control-flow payload moved into `snap`;
    // frame teardown must not release it.
    frame.pending_finally = .{};
}

/// Open a flat activation for a direct interpreted call: the same entry
/// sequence `evalWithCapturesChained` performs for a recursive call (frame
/// construction with the arg buffer transferred as params, GC chain push,
/// lexical receiver-chain activation, context-parameter seeding).
fn openActivation(comptime H: type, allocator: Allocator, caller_module: *const Module, req: FlatCallReq, host: *H) Allocator.Error!*Activation {
    const module = req.run_module orelse caller_module;
    dumpFnIfRequested(module, req.func);
    const act = try allocator.create(Activation);
    errdefer allocator.destroy(act);
    act.* = .{
        .frame = try Frame.newWithCaptures(allocator, module, req.func, req.args, req.captures),
        .try_stack = .empty,
        .ctx_mark = 0,
        .ctx_armed = true,
        .composer_pushed = req.composer_pushed,
        .pop_enclosing_n = req.pop_enclosing_n,
        .keepalive = req.keepalive,
        .suspend_barrier = req.suspend_barrier,
        .barrier_scope_base = req.barrier_scope_base,
        .scope_guard_ident = req.scope_guard_ident,
        .root_pump = req.root_pump,
        .typed_saved = req.typed_saved,
        .type_args = req.type_args,
        .ret_block = undefined,
        .ret_idx = 0,
        .ret_dst = req.dst,
    };
    act.frame.closure_id = req.closure_id;
    gcPushFrame(&act.frame);
    act.frame.module_arc = req.owning;
    try act.frame.activateChain(req.chain);
    act.ctx_mark = req.ctx_mark_override orelse
        (if (comptime @hasDecl(H, "ctxStackLen")) host.ctxStackLen() else 0);
    if (comptime @hasDecl(H, "ctxPush")) {
        if (module.has_context_decls) {
            if (comptime @hasDecl(H, "ctxActivate")) host.ctxActivate(true);
            if (req.func.has_receiver_param and act.frame.params.items.len > 0) {
                host.ctxPush(act.frame.params.items[0]) catch {};
            }
        }
    }
    return act;
}

/// Tear down a flat activation: the exact exit sequence of
/// `evalWithCapturesChained`'s defers, in their LIFO order, then the host's
/// post-call unwinds (ambient composer pop) that wrapped the recursive call.
/// A previously-parked activation carries no live host-entry effects (its
/// flags were cleared at park), so only the frame itself unwinds.
fn teardownActivation(comptime H: type, allocator: Allocator, act: *Activation, host: *H) void {
    if (act.ctx_armed) {
        if (comptime @hasDecl(H, "ctxStackTruncate")) host.ctxStackTruncate(act.ctx_mark);
        act.ctx_armed = false;
    }
    act.frame.deactivateChain();
    gcPopFrame(&act.frame);
    act.frame.deinit();
    act.try_stack.deinit(allocator);
    if (act.composer_pushed) {
        if (comptime @hasDecl(H, "flatCallClosed")) host.flatCallClosed();
        act.composer_pushed = false;
    }
    while (act.pop_enclosing_n > 0) : (act.pop_enclosing_n -= 1) popEnclosing();
    if (act.keepalive) |ka| {
        if (runtime.reclaimEnabled()) ka.release(allocator);
        act.keepalive = null;
    }
    if (act.scope_guard_ident != 0) {
        if (comptime @hasDecl(H, "undispatchedScopeLeave")) host.undispatchedScopeLeave(act.scope_guard_ident);
        act.scope_guard_ident = 0;
    }
    if (act.typed_saved) |ts| {
        if (comptime @hasDecl(H, "typedBindingsRestore")) host.typedBindingsRestore(allocator, ts);
        act.typed_saved = null;
    }
    if (act.type_args.len > 0) {
        allocator.free(act.type_args);
        act.type_args = &.{};
    }
}

/// Park a flat activation live: unwind its host-entry effects and thread
/// links, then hand the intact activation (frame, registers, try-stack,
/// receiver chain — no copies, no retains) to the suspend state. Ownership
/// moves to the state; `resumeLiveActivation` reinstalls it, and
/// `SuspendState.deinit` destroys it if the coroutine is dropped unresumed.
fn liveParkActivation(
    comptime H: type,
    allocator: Allocator,
    act: *Activation,
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    state: *SuspendState,
    host: *H,
) Allocator.Error!void {
    if (act.ctx_armed) {
        if (comptime @hasDecl(H, "ctxStackTruncate")) host.ctxStackTruncate(act.ctx_mark);
        act.ctx_armed = false;
    }
    if (act.composer_pushed) {
        if (comptime @hasDecl(H, "flatCallClosed")) host.flatCallClosed();
        act.composer_pushed = false;
    }
    act.frame.deactivateChain();
    gcPopFrame(&act.frame);
    while (act.pop_enclosing_n > 0) : (act.pop_enclosing_n -= 1) popEnclosing();
    // The park's scope-delta capture owns the guard entry from here on.
    act.scope_guard_ident = 0;
    // Reified bindings restore across a suspension exactly as the
    // recursive path's unconditional restore loop did; the resumed body
    // reads no type-name globals (its reified reads were lowering-bound).
    if (act.typed_saved) |ts| {
        if (comptime @hasDecl(H, "typedBindingsRestore")) host.typedBindingsRestore(allocator, ts);
        act.typed_saved = null;
    }
    if (resumeTraceOn()) {
        std.debug.print("[suspend-frame] {s}#{d} at={d}:{d} LIVE caps={d} enc={d}\n", .{
            act.frame.func.name,
            act.frame.func.id.int(),
            block.int(),
            inst_idx,
            act.frame.captures.items.len,
            act.frame.enclosing_this.items.len,
        });
    }
    try state.frames.append(allocator, .{
        .live = act,
        .func = act.frame.func.id,
        .module = act.frame.module_arc,
        .block = block,
        .inst_idx = inst_idx,
        .regs = .{ .sparse = &.{} },
        .params = &.{},
        .captures = &.{},
        .enclosing_this = &.{},
        .try_stack = &.{},
        .pending_finally = .{},
        .is_lambda = act.frame.func.is_lambda,
        .resume_reg = resume_reg,
        .closure_id = act.frame.closure_id,
    });
}

/// Destroy a live-parked activation that is being dropped without a resume
/// (a cancelled or abandoned coroutine). The frame owns its register
/// references; params/captures are borrows, exactly as during execution.
fn destroyParkedActivation(allocator: Allocator, act: *Activation) void {
    act.frame.deinit();
    act.try_stack.deinit(allocator);
    if (act.keepalive) |ka| {
        if (runtime.reclaimEnabled()) ka.release(allocator);
    }
    if (act.type_args.len > 0) allocator.free(act.type_args);
    allocator.destroy(act);
}

/// Reinstall a live-parked activation and run it to its next completion or
/// suspension. `block`/`inst_idx`/`resume_reg` come from the park entry.
/// On suspension the driver has already re-parked the activation into the
/// new state (ownership moved); on completion the activation is torn down
/// here and the boundary-transformed result returned.
fn resumeLiveActivation(
    comptime H: type,
    allocator: Allocator,
    act: *Activation,
    carry: Value,
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    resume_throw: ?Value,
    resume_unwind: ?EvalError,
    host: *H,
) Allocator.Error!EvalResult {
    gcPushFrame(&act.frame);
    act.frame.activateAs();
    if (resume_throw == null) {
        if (resume_reg) |r| try act.frame.write(r, carry);
    }
    const res = try runFlatLoop(H, allocator, &act.frame, &act.try_stack, block, inst_idx, resume_throw, resume_unwind, act, host);
    if (res == .err and res.err == .Suspended) return res;
    const out = frameBoundary(act.frame.func, res);
    teardownActivation(H, allocator, act, host);
    allocator.destroy(act);
    return out;
}

/// Discard a flat call request without running it (depth-cap rejection):
/// free the transferred buffers (values are borrows) and unwind any host
/// side effect the prepare step applied.
fn discardFlatReq(comptime H: type, allocator: Allocator, req: FlatCallReq, host: *H) void {
    var args = req.args;
    args.deinit(allocator);
    var caps = req.captures;
    caps.deinit(allocator);
    if (req.composer_pushed) {
        if (comptime @hasDecl(H, "flatCallClosed")) host.flatCallClosed();
    }
    var n = req.pop_enclosing_n;
    while (n > 0) : (n -= 1) popEnclosing();
    if (req.keepalive) |ka| {
        if (runtime.reclaimEnabled()) ka.release(allocator);
    }
    if (req.scope_guard_ident != 0) {
        if (comptime @hasDecl(H, "undispatchedScopeLeave")) host.undispatchedScopeLeave(req.scope_guard_ident);
    }
    if (req.typed_saved) |ts| {
        if (comptime @hasDecl(H, "typedBindingsRestore")) host.typedBindingsRestore(allocator, ts);
    }
    if (req.type_args.len > 0) allocator.free(req.type_args);
}

/// The flat call driver. Runs `frame` through `runFrameExec`; when the
/// executor surfaces a direct interpreted call, pushes the callee as a new
/// heap activation and continues in the same loop instead of recursing
/// natively. Results, throws, non-local returns and suspensions re-enter the
/// calling frame through the executor's resume machinery — the same routes a
/// coroutine resume uses — so control-flow semantics are identical to the
/// recursive path.
fn runFrameInner(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    host: *H,
) Allocator.Error!EvalResult {
    _ = module;
    return runFlatLoop(H, allocator, frame, try_stack, cur_in, resume_idx_in, resume_throw_in, resume_unwind_in, null, host);
}

/// The driver core. `root_act` is set when the root frame is itself a
/// resumed live activation — a suspension then live-parks the root too
/// instead of snapshotting it (the caller relinquished ownership).
fn runFlatLoop(
    comptime H: type,
    allocator: Allocator,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    root_act: ?*Activation,
    host: *H,
) Allocator.Error!EvalResult {
    var stack: std.ArrayList(*Activation) = .empty;
    defer stack.deinit(allocator);
    // On an allocation failure, unwind every open activation so no frame is
    // left dangling on the GC chain.
    errdefer while (stack.pop()) |act| {
        evtls.eval_depth -= 1;
        teardownActivation(H, allocator, act, host);
        allocator.destroy(act);
    };
    var cur = cur_in;
    var ridx = resume_idx_in;
    var rthrow = resume_throw_in;
    var runwind = resume_unwind_in;
    while (true) {
        const f: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
        const ts: *std.ArrayList(TryFrame) = if (stack.items.len > 0) &stack.items[stack.items.len - 1].try_stack else try_stack;
        var flat_site: ?FlatCallSite = null;
        var park_out: ?ParkPoint = null;
        var res = try runFrameExec(H, allocator, f.module, f, ts, cur, ridx, rthrow, runwind, &flat_site, &park_out, host);
        rthrow = null;
        runwind = null;
        if (flat_site) |site| {
            // Same depth bound as the recursive path: an unbounded interpreted
            // recursion becomes a catchable StackOverflowError at the caller.
            if (evtls.eval_depth >= maxEvalDepth()) {
                dumpFrameChainForDiag();
                discardFlatReq(H, allocator, site.req, host);
                runwind = .{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" };
                cur = site.ret_block;
                ridx = site.ret_idx;
                continue;
            }
            evtls.eval_depth += 1;
            const act = openActivation(H, allocator, f.module, site.req, host) catch |e| {
                evtls.eval_depth -= 1;
                return e;
            };
            act.ret_block = site.ret_block;
            act.ret_idx = site.ret_idx;
            stack.append(allocator, act) catch |e| {
                evtls.eval_depth -= 1;
                teardownActivation(H, allocator, act, host);
                allocator.destroy(act);
                return e;
            };
            cur = site.req.func.entry;
            ridx = 0;
            continue;
        }
        // A suspension: park the current frame at its own suspension point,
        // then every outer activation at its recorded call-return point,
        // preserving the innermost-first order of the recursive path. Flat
        // activations park LIVE — the intact frame moves into the state by
        // pointer, no copies — and only a native root frame snapshots.
        if (park_out) |pp| {
            const state = res.err.Suspended;
            var pb = pp.block;
            var pi = pp.inst_idx;
            var pd = pp.resume_reg;
            var barrier_hit = false;
            while (stack.pop()) |a| {
                evtls.eval_depth -= 1;
                const is_barrier = a.suspend_barrier;
                const is_root_pump = a.root_pump;
                const scope_base = a.barrier_scope_base;
                const scope_keep: Value = a.keepalive orelse .Unit;
                const rb = a.ret_block;
                const rix = a.ret_idx;
                const rd = a.ret_dst;
                try liveParkActivation(H, allocator, a, pb, pi, pd, state, host);
                if (is_root_pump) {
                    // No-driver root: park the root into ITS OWN pump,
                    // drain the pump to quiescence (persisting an
                    // unresumed root), and continue the caller with the
                    // resumed value or COROUTINE_SUSPENDED.
                    if (comptime @hasDecl(H, "rootPumpBarrierPark")) {
                        const r = try host.rootPumpBarrierPark(allocator, state, scope_keep, scope_base);
                        const pf2: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
                        switch (r) {
                            .ok => |v| try pf2.write(rd, v),
                            .err => |e| switch (e) {
                                .Throw => |v| rthrow = v,
                                else => runwind = e,
                            },
                        }
                        cur = rb;
                        ridx = rix;
                        barrier_hit = true;
                        break;
                    }
                }
                if (is_barrier) {
                    // The undispatched-start boundary: the parked segment
                    // belongs to the enclosing pump, and the CALLER
                    // continues with the hook's value (COROUTINE_SUSPENDED)
                    // — the defining startCoroutineUninterceptedOrReturn
                    // split. Ownership of `state` moves to the pump.
                    const v: Value = if (comptime @hasDecl(H, "undispatchedBarrierPark"))
                        try host.undispatchedBarrierPark(allocator, state, scope_base)
                    else
                        Value.CoroutineSuspended;
                    const pf2: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
                    try pf2.write(rd, v);
                    cur = rb;
                    ridx = rix;
                    barrier_hit = true;
                    break;
                }
                pb = rb;
                pi = rix;
                pd = rd;
            }
            if (barrier_hit) continue;
            if (root_act) |ra| {
                try liveParkActivation(H, allocator, ra, pb, pi, pd, state, host);
            } else {
                try snapshotSuspendedFrame(allocator, frame, try_stack, pb, pi, pd, state);
            }
            return res;
        }
        // The current frame exited; deliver its result to the calling
        // activation, applying the callee-boundary transforms each popped
        // frame's result crosses.
        deliver: while (true) {
            if (stack.items.len == 0) return res;
            const act = stack.pop().?;
            evtls.eval_depth -= 1;
            res = frameBoundary(act.frame.func, res);
            // A no-driver root's completion runs its pump to quiescence
            // (launched children, timers) before the caller sees the
            // result — the recursive branch's tail, guard still pushed.
            if (act.root_pump) {
                if (comptime @hasDecl(H, "rootPumpFlatComplete")) {
                    res = try host.rootPumpFlatComplete(allocator, res, act.keepalive orelse .Unit, act.barrier_scope_base);
                }
            }
            if (act.type_args.len > 0) {
                if (comptime @hasDecl(H, "typedCallBoundary")) host.typedCallBoundary(act.frame.module, act.frame.func, act.type_args, &res);
            }
            const rb = act.ret_block;
            const rix = act.ret_idx;
            const rd = act.ret_dst;
            teardownActivation(H, allocator, act, host);
            allocator.destroy(act);
            const pf: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
            switch (res) {
                .ok => |v| {
                    try pf.write(rd, v);
                    cur = rb;
                    ridx = rix;
                    break :deliver;
                },
                .err => |e| switch (e) {
                    .Throw => |v| {
                        rthrow = v;
                        cur = rb;
                        ridx = rix;
                        break :deliver;
                    },
                    .NonLocalReturn, .LabeledReturn, .CalleeFailed, .StackOverflow => {
                        runwind = e;
                        cur = rb;
                        ridx = rix;
                        break :deliver;
                    },
                    // Anything else exits the calling frame as-is (matching
                    // the recursive raised-switch's default arm); keep
                    // popping so each crossed frame's boundary applies.
                    else => {},
                },
            }
        }
    }
}

fn typeRefName(name: []const u8) TypeRef {
    return .{ .name = name, .nullable = false, .args = &.{} };
}

/// The loop JIT's call trampoline, specialized per host. A compiled loop's native
/// call site invokes `call` with the loop's `TrampCtx` and a site index; it reboxes
/// the scalar args from the slot file, runs the callee through `host.callFunc`, and
/// reboxes a scalar result back into the dst slot. Returns 0 to continue the native
/// loop, or `THROW_INST`'s resume code with the error stashed in `Ctx.pending` for
/// the interpreter to re-raise (a throw routes through the try-stack; any other
/// error propagates out of the frame, matching the interpreted call exactly).
fn LoopTramp(comptime H: type) type {
    return struct {
        const Ctx = struct {
            host: *H,
            allocator: Allocator,
            module: *const Module,
            frame: *Frame,
            pending: ?EvalError = null,
            pending_deopt_inst: u32 = 0,
        };

        /// The trampoline's BULKY non-call sites (field write, subscript, value call,
        /// map get/set). Zig does not reclaim block-scoped stack allocations
        /// (ziglang/zig#23475), so their locals sat in `call`'s frame — and `call` is
        /// the frame held LIVE across the interpreter's recursion (once a function is
        /// JIT'd the recursive call runs native code -> this trampoline -> `callFunc`,
        /// so `runFrameInner` is not even on the path). Outlining them lifted the
        /// recursion ceiling ~13%.
        ///
        /// The three TINY hot sites (object move, null test, field read) deliberately
        /// stay inline in `call`: they fire once per JIT'd loop iteration, and
        /// outlining them too cost ~3% throughput for no extra depth.
        noinline fn bulkySite(tctx: *jit_loop.TrampCtx, lc: *Ctx, cl: anytype, site: anytype) ?u64 {
            if (site.is_field_set) {
                const recv = lc.frame.regs.items[site.recv_reg];
                if (recv != .Instance or (site.recv_varies and jit_loop.instanceClassIdentity(recv) != site.recv_class)) {
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                const v = switch (cl.reg_types[site.src_reg]) {
                    .object => lc.frame.regs.items[site.src_reg],
                    .null_ => Value.Null,
                    else => jit_loop.valueFromSlot(cl.reg_types[site.src_reg], tctx.slots[site.src_reg]),
                };
                const g = recv.Instance.borrowMut();
                if (site.field_idx < g.get().fields.items.len) {
                    const old = g.get().fields.items[site.field_idx].value;
                    g.get().fields.items[site.field_idx].value = v;
                    g.deinit();
                    old.release(lc.allocator);
                } else {
                    g.deinit();
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                return 0;
            }
            // Object collection subscript: read element `recv[idx]` directly (no
            // `get` dispatch) and write it into the register. Out-of-range or an
            // unsupported container deopts; the interpreter re-runs the subscript
            // (a side-effect-free read) and raises the proper exception on OOB.
            if (site.is_obj_index) {
                const recv = lc.frame.regs.items[site.recv_reg];
                const idx_v = jit_loop.valueFromSlot(cl.reg_types[site.args_reg], tctx.slots[site.args_reg]);
                const idx: i64 = switch (idx_v) {
                    .Int => |x| x,
                    .Long => |x| x,
                    else => {
                        lc.pending_deopt_inst = site.inst;
                        return jit_loop.deoptCode(site.block);
                    },
                };
                if (jit_loop.liveElementAt(recv, idx)) |v| {
                    v.retain();
                    lc.frame.write(Reg.from(site.dst_reg), v) catch {
                        lc.pending = .{ .Type = "out of memory in JIT subscript" };
                        return jit_loop.throwCode(site.block);
                    };
                    return 0;
                }
                lc.pending_deopt_inst = site.inst;
                return jit_loop.deoptCode(site.block);
            }
            // Invoke a loop-invariant callable value; the result is discarded.
            if (site.is_call_value) {
                if (comptime !@hasDecl(H, "callValue")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const callee = lc.frame.regs.items[site.recv_reg];
                var argbuf2: [3]Value = undefined;
                var k2: usize = 0;
                while (k2 < site.n_args) : (k2 += 1) {
                    const ar = @as(usize, site.args_reg) + k2;
                    argbuf2[k2] = switch (cl.reg_types[ar]) {
                        .object => lc.frame.regs.items[ar],
                        .null_ => .Null,
                        else => jit_loop.valueFromSlot(cl.reg_types[ar], tctx.slots[ar]),
                    };
                }
                // Plain exact-arity closure: skip the value-dispatch preamble
                // and run the resolved body directly; a declined shape falls
                // through to the full route below.
                if (comptime @hasDecl(H, "callClosureFast")) {
                    if (callee == .IrClosure) {
                        const fr = lc.host.callClosureFast(lc.allocator, &callee, argbuf2[0..site.n_args]) catch {
                            lc.pending = .{ .Type = "out of memory in JIT value call" };
                            return jit_loop.throwCode(site.block);
                        };
                        if (fr) |r2| switch (r2) {
                            .ok => return 0,
                            .err => |e| {
                                lc.pending = e;
                                return jit_loop.throwCode(site.block);
                            },
                        };
                    }
                }
                const r = lc.host.callValue(lc.allocator, &callee, argbuf2[0..site.n_args]) catch {
                    lc.pending = .{ .Type = "out of memory in JIT value call" };
                    return jit_loop.throwCode(site.block);
                };
                switch (r) {
                    .ok => return 0,
                    .err => |e| {
                        lc.pending = e;
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            // Map store `map[key] = value`; result discarded.
            if (site.is_map_set) {
                if (comptime !@hasDecl(H, "callMemberNamed")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const m = lc.frame.regs.items[site.recv_reg];
                const key = jit_loop.valueFromSlot(cl.reg_types[site.args_reg], tctx.slots[site.args_reg]);
                const val = jit_loop.valueFromSlot(cl.reg_types[site.src_reg], tctx.slots[site.src_reg]);
                var names: [2]?[]const u8 = .{ null, null };
                const r = lc.host.callMemberNamed(lc.allocator, &m, "set", &.{ key, val }, names[0..2]) catch {
                    lc.pending = .{ .Type = "out of memory in JIT map store" };
                    return jit_loop.throwCode(site.block);
                };
                switch (r) {
                    .ok => return 0,
                    .err => |e| {
                        lc.pending = e;
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            // Map load `map[key]` -> nullable scalar (value slot + flag slot).
            if (site.is_map_get) {
                if (comptime !@hasDecl(H, "callMemberNamed")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const m = lc.frame.regs.items[site.recv_reg];
                const key = jit_loop.valueFromSlot(cl.reg_types[site.args_reg], tctx.slots[site.args_reg]);
                var names: [1]?[]const u8 = .{null};
                const r = lc.host.callMemberNamed(lc.allocator, &m, "get", &.{key}, names[0..1]) catch {
                    lc.pending = .{ .Type = "out of memory in JIT map load" };
                    return jit_loop.throwCode(site.block);
                };
                switch (r) {
                    .ok => |v| {
                        if (v == .Null) {
                            tctx.slots[site.dst_reg] = 0;
                            tctx.slots[site.map_flag_slot] = 1;
                        } else if (jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], v)) |sv| {
                            tctx.slots[site.dst_reg] = sv;
                            tctx.slots[site.map_flag_slot] = 0;
                        } else {
                            // Value is not the cached scalar kind: deopt and re-read.
                            lc.pending_deopt_inst = site.inst;
                            return jit_loop.deoptCode(site.block);
                        }
                        return 0;
                    },
                    .err => |e| {
                        lc.pending = e;
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            return null;
        }

        fn call(ctx_opaque: *anyopaque, site_idx: u64) callconv(.c) u64 {
            const tctx: *jit_loop.TrampCtx = @ptrCast(@alignCast(ctx_opaque));
            const lc: *Ctx = @ptrCast(@alignCast(tctx.user));
            const cl = tctx.compiled;
            const site = cl.call_sites[@intCast(site_idx)];
            // Object move: copy one boxed register into another (both in `regs`).
            // A `.null_`-typed source is the null literal, not a live register, so
            // write `.Null` directly (its slot-backed register is not maintained
            // during the native run).
            if (site.is_obj_move) {
                const v = if (cl.reg_types[site.src_reg] == .null_) Value.Null else lc.frame.regs.items[site.src_reg];
                v.retain();
                lc.frame.write(Reg.from(site.dst_reg), v) catch {
                    lc.pending = .{ .Type = "out of memory in JIT object move" };
                    return jit_loop.throwCode(site.block);
                };
                return 0;
            }
            if (site.is_load_global) {
                if (site.span) |sp| lc.frame.cur_span = sp;
                const loaded = lc.host.lookupGlobalThrowing(lc.allocator, site.name) catch {
                    lc.pending = .{ .Type = "out of memory in JIT global read" };
                    return jit_loop.throwCode(site.block);
                };
                switch (loaded) {
                    .ok => |maybe| if (maybe) |v| {
                        v.retain();
                        lc.frame.write(Reg.from(site.dst_reg), v) catch {
                            lc.pending = .{ .Type = "out of memory in JIT global read" };
                            return jit_loop.throwCode(site.block);
                        };
                        return 0;
                    },
                    .err => |e| {
                        lc.pending = e;
                        return jit_loop.throwCode(site.block);
                    },
                }
                lc.pending_deopt_inst = site.inst;
                return jit_loop.deoptCode(site.block);
            }
            // Boxed structural/reference comparison: write a boolean to the
            // scalar destination while both values remain GC-rooted in regs.
            if (site.is_null_check) {
                const lhs = if (cl.reg_types[site.recv_reg] == .null_) Value.Null else lc.frame.regs.items[site.recv_reg];
                const rhs = if (cl.reg_types[site.src_reg] == .null_) Value.Null else lc.frame.regs.items[site.src_reg];
                const equal = if (site.identity) Value.referenceEq(&lhs, &rhs) else Value.structuralEq(&lhs, &rhs);
                const r = if (site.neg) !equal else equal;
                tctx.slots[site.dst_reg] = if (r) 1 else 0;
                return 0;
            }
            // A field read is a direct stored-field load — no host call, no side
            // effect, so a deopt is safe (the interpreter re-reads).
            if (site.is_field) {
                const recv = lc.frame.regs.items[site.recv_reg];
                // A varying boxed receiver may be a different class this iteration
                // (or null after a `?.` chain step); deopt unless it matches.
                if (recv != .Instance or (site.recv_varies and jit_loop.instanceClassIdentity(recv) != site.recv_class)) {
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                const g = recv.Instance.borrow();
                const fv: ?Value = if (site.field_idx < g.get().fields.items.len) g.get().fields.items[site.field_idx].value else null;
                g.deinit();
                if (cl.reg_types[site.dst_reg] == .object) {
                    // Object field: write the boxed value straight into the frame.
                    const v = fv orelse .Null;
                    v.retain();
                    lc.frame.write(Reg.from(site.dst_reg), v) catch {
                        lc.pending = .{ .Type = "out of memory in JIT field read" };
                        return jit_loop.throwCode(site.block);
                    };
                    return 0;
                }
                const s = if (fv) |v| jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], v) else null;
                if (s) |sv| {
                    tctx.slots[site.dst_reg] = sv;
                    return 0;
                }
                // Field no longer the cached scalar (e.g. a nullable field went
                // null): deopt and let the interpreter re-read it.
                lc.pending_deopt_inst = site.inst;
                return jit_loop.deoptCode(site.block);
            }
            // Scalar field store: write the value directly into the boxed receiver's
            // stored field (a plain stored property — no custom setter).
            // Gate on the tag before CALLING the outlined helper: a member/func site
            // must not pay a call just to be told the site is not one of these.
            if (site.is_field_set or site.is_obj_index or site.is_call_value or
                site.is_map_set or site.is_map_get)
            {
                if (bulkySite(tctx, lc, cl, site)) |code| return code;
            }
            // The native loop does not run `.Trace`; refresh the calling frame's
            // position so a throw from the callee reports this call's line.
            if (site.span) |sp| lc.frame.cur_span = sp;
            var argbuf: [3]Value = undefined;
            var k: usize = 0;
            while (k < site.n_args) : (k += 1) {
                const ar = @as(usize, site.args_reg) + k;
                argbuf[k] = switch (cl.reg_types[ar]) {
                    .object => lc.frame.regs.items[ar],
                    .null_ => .Null,
                    else => jit_loop.valueFromSlot(cl.reg_types[ar], tctx.slots[ar]),
                };
            }
            // Native recursion: a compiled body calling a compiled (scalar)
            // callee runs its body directly — no interpreter frame, no dispatch.
            // The callee is pure (scalar in, scalar out), so a deopt/throw can
            // safely fall back to the frame-based path by re-running it below.
            if (!site.is_member and !runtime.shouldAbandon()) {
                if (lc.module.funcById(site.func)) |callee| {
                    if (jit_loop.compiledFunc(callee)) |callee_cl| {
                        if (evtls.jit_native_depth < JIT_NATIVE_DEPTH_LIMIT and callee_cl.n_slots <= 192) {
                            var fslots: [192]i64 = undefined;
                            evtls.jit_native_depth += 1;
                            const fo = jit_loop.runFunc(callee_cl, &.{}, argbuf[0..site.n_args], fslots[0..callee_cl.n_slots], &call, tctx.user);
                            evtls.jit_native_depth -= 1;
                            if (fo) |o| {
                                if (o.code.inst == jit_loop.RETURN_INST) {
                                    if (site.has_result) {
                                        tctx.slots[site.dst_reg] = jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], o.value) orelse {
                                            lc.pending = .{ .Type = "JIT function returned a non-scalar result" };
                                            return jit_loop.throwCode(site.block);
                                        };
                                    }
                                    return 0;
                                }
                                // A deeper call threw: `lc.pending` is already set —
                                // propagate it out (do NOT re-run; the callee may have
                                // had effects), unwinding this native frame too.
                                if (o.code.inst == jit_loop.THROW_INST) return jit_loop.throwCode(site.block);
                            }
                            // Not run (param-kind mismatch / depth / oversized): the
                            // callee never executed, so the frame path runs it once.
                        }
                    }
                }
            }
            const res = if (site.is_member) member: {
                var recv = switch (cl.reg_types[site.recv_reg]) {
                    .object, .unknown => lc.frame.regs.items[site.recv_reg],
                    .null_ => Value.Null,
                    else => jit_loop.valueFromSlot(
                        cl.reg_types[site.recv_reg],
                        tctx.slots[site.recv_reg],
                    ),
                };
                // A varying boxed receiver may be a different class this iteration;
                // deopt unless it matches the class the return type was resolved for.
                if (site.recv_class != 0 and site.recv_varies and (recv != .Instance or jit_loop.instanceClassIdentity(recv) != site.recv_class)) {
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                recv.retain();
                defer recv.release(lc.allocator);
                if (site.resolved_member) |fid| {
                    if (comptime !@hasDecl(H, "invokeResolvedMember")) {
                        break :member EvalResult{ .err = .{
                            .Type = "host cannot invoke resolved member calls",
                        } };
                    }
                    var dispatch: ?Value = if (site.dispatch_recv_reg) |reg|
                        switch (cl.reg_types[reg]) {
                            .object, .unknown => lc.frame.regs.items[reg],
                            .null_ => Value.Null,
                            else => jit_loop.valueFromSlot(
                                cl.reg_types[reg],
                                tctx.slots[reg],
                            ),
                        }
                    else
                        null;
                    if (dispatch) |value| value.retain();
                    defer if (dispatch) |value| value.release(lc.allocator);
                    const dispatch_ptr: ?*const Value = if (dispatch) |*value|
                        value
                    else
                        null;
                    break :member lc.host.invokeResolvedMember(
                        lc.allocator,
                        dispatch_ptr,
                        &recv,
                        fid,
                        argbuf[0..site.n_args],
                    ) catch {
                        lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                        return jit_loop.throwCode(site.block);
                    };
                }
                if (comptime !@hasDecl(H, "callMemberNamed")) {
                    break :member EvalResult{ .err = .{
                        .Type = "host cannot dispatch member calls",
                    } };
                }
                // Keep the caller's instance `this` reachable for member-extension
                // visibility, exactly as the interpreted CallMember path does.
                var pushed = false;
                if (lc.frame.params.items.len > 0 and lc.frame.params.items[0] == .Instance) {
                    const pi = lc.frame.params.items[0].Instance;
                    const same = recv == .Instance and ObjRef(InstanceData).ptrEq(pi, recv.Instance);
                    if (!same) {
                        pushEnclosingAccess(&lc.frame.params.items[0]);
                        pushed = true;
                    }
                }
                var names: [3]?[]const u8 = .{ null, null, null };
                const r = lc.host.callMemberNamed(lc.allocator, &recv, site.name, argbuf[0..site.n_args], names[0..site.n_args]) catch {
                    if (pushed) popEnclosing();
                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                    return jit_loop.throwCode(site.block);
                };
                if (pushed) popEnclosing();
                break :member r;
            } else lc.host.callFunc(lc.allocator, lc.module, site.func, argbuf[0..site.n_args]) catch {
                lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                return jit_loop.throwCode(site.block);
            };
            switch (res) {
                .ok => |v| {
                    if (site.has_result) {
                        if (cl.reg_types[site.dst_reg] == .object) {
                            v.retain();
                            lc.frame.write(Reg.from(site.dst_reg), v) catch {
                                lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                                return jit_loop.throwCode(site.block);
                            };
                        } else {
                            const s = jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], v) orelse {
                                lc.pending_deopt_inst = site.inst;
                                return jit_loop.deoptCode(site.block);
                            };
                            tctx.slots[site.dst_reg] = s;
                        }
                    }
                    return 0;
                },
                .err => |e| {
                    lc.pending = e;
                    return jit_loop.throwCode(site.block);
                },
            }
        }

        /// Compile-time member resolver: resolve `receiver.name(args)` to the
        /// method `FuncId` so the loop JIT can learn its return type. Run time
        /// still dispatches through `callMemberNamed`, so this never alters
        /// behavior — it only informs the slot's static type.
        fn resolveMember(user: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value) ?FuncId {
            if (comptime !@hasDecl(H, "resolveMemberFuncId")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.resolveMemberFuncId(lc.allocator, receiver, name, args);
        }

        /// Compile-time field resolver: the stored-field index of `name` on the
        /// receiver, or null if it is not a plain stored property (so the read
        /// stays interpreted).
        fn resolveField(user: *anyopaque, receiver: *const Value, name: []const u8) ?u32 {
            if (comptime !@hasDecl(H, "plainStoredFieldIndex")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.plainStoredFieldIndex(lc.allocator, receiver, name);
        }

        /// Like `resolveField`, but only for a non-nullable scalar stored field —
        /// the index where a member-inlined field read can never observe null (so
        /// the loop can inline a method that also writes a field).
        fn resolveFieldNN(user: *anyopaque, receiver: *const Value, name: []const u8) ?u32 {
            if (comptime !@hasDecl(H, "plainStoredScalarFieldNN")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.plainStoredScalarFieldNN(lc.allocator, receiver, name);
        }
    };
}

/// `resume_throw`: when a continuation is resumed with
/// `Result.failure(e)` (Kotlin's `resumeWith(failure)` = "resume by
/// throwing at the suspension point"), the exception is routed through
/// this frame's restored try-stack instead of being delivered as the
/// suspending call's value. This makes a cancellation actually preempt
/// a parked `delay` / acquire.
/// `resume_unwind` is the corresponding path for a non-local return raised
/// by a resumed inner frame; it crosses the restored frame's finally stack
/// and is absorbed when this frame carries its target label.
/// `flat_out`: when the frame hits a direct interpreted call the flat driver
/// can run, the executor parks the request there and returns; the returned
/// `EvalResult` is meaningless in that case (the driver checks `flat_out`
/// first).
fn runFrameExec(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    flat_out: *?FlatCallSite,
    park_out: *?ParkPoint,
    host: *H,
) Allocator.Error!EvalResult {
    var cur = cur_in;
    var resume_idx = resume_idx_in;
    var resume_throw = resume_throw_in;
    var resume_unwind = resume_unwind_in;
    // Pending throw/return state lives on `frame`: a finally body may suspend,
    // and the frame snapshot must carry both its continuation point and the
    // control flow that caused the finally to run.
    const func: *const Func = frame.func;
    // Lazy IR: materialise a deferred function's blocks before the dispatch
    // loop reads them. `TailCallFunc` is self-recursive (same func), so `func`
    // stays current for the whole loop.
    if (func.blocks.len == 0 and !frame.module.ensureFuncBody(@constCast(func))) {
        return errResult(.{ .Type = "virtual method target is not executable" });
    }
    dumpFnIfRequested(frame.module, func);
    const jit_on = jit_loop.enabled();
    // Loop-JIT call trampoline wiring (only hosts that can run a callee qualify).
    const tramp_ok = comptime @hasDecl(H, "callFunc");
    var loop_ctx: if (tramp_ok) LoopTramp(H).Ctx else void =
        if (tramp_ok) .{ .host = host, .allocator = allocator, .module = frame.module, .frame = frame } else {};
    const tramp_fn: ?jit_loop.TrampFn = if (comptime tramp_ok) &LoopTramp(H).call else null;
    const tramp_user: ?*anyopaque = if (comptime tramp_ok) @ptrCast(&loop_ctx) else null;
    const member_resolver: ?jit_loop.MemberResolver =
        if (comptime tramp_ok and @hasDecl(H, "resolveMemberFuncId")) &LoopTramp(H).resolveMember else null;
    const field_resolver: ?jit_loop.FieldResolver =
        if (comptime tramp_ok and @hasDecl(H, "plainStoredFieldIndex")) &LoopTramp(H).resolveField else null;
    const field_nn_resolver: ?jit_loop.FieldResolver =
        if (comptime tramp_ok and @hasDecl(H, "plainStoredScalarFieldNN")) &LoopTramp(H).resolveFieldNN else null;
    while (true) {
        // Daemon abandonment: a dispatcher pool task still running at the
        // run boundary stops at its next block instead of completing (or
        // looping forever). The unwind bypasses user catch/finally frames
        // deliberately — the task is being torn down, not failing.
        if (runtime.shouldAbandon()) {
            return errResult(.{ .Type = "daemon task abandoned at run boundary" });
        }
        // Spin diagnostic (KLIO_SPIN_TRACE): cheap counter gate, then a
        // wall-clock check inside.
        spin_check_counter +%= 1;
        if (spin_check_counter & 0xFFFF == 0) {
            spinDumpMaybe();
            const wall_dl = test_wall_deadline_ms.load(.monotonic);
            if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
                // A caught hang should say WHERE it looped, not just that it did.
                // Dump the live frame chain (innermost first, with file:line) so
                // the culprit function/recursion is named at the abort point.
                std.debug.print("[wall-cap] test wall-clock deadline exceeded — hang location follows:\n", .{});
                dumpFrameChainForDiagAlways();
                wallCapAbandon();
                return errResult(.{ .Type = "test wall-clock deadline exceeded" });
            }
        }
        // GC safe point: at an opcode boundary all live Values are in registered
        // frames/globals (no host op mid-flight), so the collector can run.
        // A resumed throw/return payload is transiently held by this native
        // activation until it is moved into a frame register or pending-finally
        // state. Route it before collecting so the payload remains rooted.
        if (runtime.gc.gc_enabled and runtime.gc.pending() and
            resume_throw == null and resume_unwind == null)
        {
            runtime.gc.safePoint();
        }
        // Loop JIT (KLIO_JIT): a hot loop header compiles to native code; on
        // success the loop runs natively and we resume at its exit block with
        // registers reboxed. Only at a fresh, non-resumed block entry.
        if (jit_on and resume_idx == 0 and resume_throw == null and resume_unwind == null) {
            if (jit_loop.maybeRunHot(frame.module, func, &frame.regs, allocator, cur, tramp_fn, tramp_user, member_resolver, field_resolver, field_nn_resolver)) |res| {
                if (res.inst == jit_loop.THROW_INST) {
                    // A trampolined call left an error pending: re-raise it. A
                    // throw resumes through the try-stack at the call's block;
                    // any other error propagates straight out of the frame.
                    if (comptime tramp_ok) {
                        const e = loop_ctx.pending.?;
                        loop_ctx.pending = null;
                        switch (e) {
                            .Throw => |exc| {
                                resume_throw = exc;
                                cur = res.block;
                                continue;
                            },
                            else => return errResult(e),
                        }
                    } else unreachable;
                }
                if (res.inst == jit_loop.DEOPT_INST) {
                    // A field read deopted: re-execute it in the interpreter.
                    if (comptime tramp_ok) {
                        cur = res.block;
                        resume_idx = loop_ctx.pending_deopt_inst;
                        continue;
                    } else unreachable;
                }
                cur = res.block;
                resume_idx = res.inst;
                continue;
            }
            // Whole-function JIT: at the function entry, run the entire body
            // natively (scalar functions; recursion stays native through the call
            // trampoline). A `Return` yields the value; a callee throw / div-by-
            // zero deopt resumes interpretation with registers reboxed.
            if (comptime tramp_ok) {
                if (cur.int() == func.entry.int()) {
                    if (jit_loop.maybeRunHotFunc(frame.module, func, &frame.regs, frame.params.items, allocator, tramp_fn, tramp_user, member_resolver, field_resolver, field_nn_resolver)) |fo| {
                        if (fo.code.inst == jit_loop.RETURN_INST) return ok(fo.value);
                        if (fo.code.inst == jit_loop.THROW_INST) {
                            const e = loop_ctx.pending.?;
                            loop_ctx.pending = null;
                            switch (e) {
                                .Throw => |exc| {
                                    resume_throw = exc;
                                    cur = fo.code.block;
                                    continue;
                                },
                                else => return errResult(e),
                            }
                        }
                        // A div-by-zero deopt: re-execute that instruction.
                        cur = fo.code.block;
                        resume_idx = fo.code.inst;
                        continue;
                    }
                }
            }
        }
        const block = &func.blocks[cur.int()];
        // Normal flow into a catch-only try's join: pop the body's
        // entry (a throw path already consumed it — the scan then finds
        // nothing). See `Block.catch_done_for`.
        if (block.catch_done_for) |body| {
            if (rpositionByBody(try_stack.items, body)) |p| {
                _ = try_stack.orderedRemove(p);
            }
        }
        // Control entering a finally body disarms its try-frame: once the
        // finally has begun, the region's catches and the finally itself must
        // not capture anything raised inside it (a throw or return in the
        // finally would otherwise re-enter and run the block twice). The
        // exception/return entry paths pop the frame before jumping here, so
        // a frame still armed at this point is the normal-completion entry.
        // Keyed on block entry (not the entry block's Goto exit) because a
        // multi-block finally — a Branch terminator, a suspension — leaves
        // the exit-side pop unreached while later blocks run.
        if (resume_idx == 0) {
            if (rpositionByFinallyEntry(try_stack.items, cur)) |p| {
                _ = try_stack.orderedRemove(p);
            }
        }
        const insts: []const Inst = block.insts;
        const term = block.terminator;
        const finally = block.finally;
        const finally_done = block.finally_done;
        const has_catches = block.catches.len != 0;
        if (resume_idx == 0 and (has_catches or finally != null)) {
            try try_stack.append(allocator, .{
                .body = cur,
                .catches = block.catches,
                .finally_entry = finally,
                .finally_done = finally_done,
            });
        }
        var thrown: ?Value = null;
        var unwound: ?EvalError = null;
        var start_idx = resume_idx;
        resume_idx = 0;
        if (resume_throw) |exc| {
            resume_throw = null;
            // Resumed with an exception: skip the remaining instructions
            // of the suspending block and route the throw through the
            // restored try-stack exactly as a mid-block throw would.
            thrown = exc;
            start_idx = insts.len;
        } else if (resume_unwind) |e| {
            resume_unwind = null;
            // Resume the caller as though its suspending call instruction
            // raised this non-local return. Catch clauses do not intercept it;
            // the ordinary unwind path below runs finally blocks and checks
            // whether this frame owns the label.
            unwound = e;
            start_idx = insts.len;
        }
        var idx: usize = 0;
        while (idx < insts.len) : (idx += 1) {
            if (idx < start_idx) continue;
            const inst = &insts[idx];
            const r = try execInst(H, allocator, frame, inst, host);
            if (r == .flat_call) {
                // Hand the resolved direct call to the flat driver: it pushes
                // the callee as a new activation and re-enters this frame at
                // the next instruction once the result is in `req.dst`.
                const req = frame.flat_call.?;
                frame.flat_call = null;
                flat_out.* = .{ .req = req, .ret_block = cur, .ret_idx = idx + 1 };
                return ok(.Unit);
            }
            if (r == .raised) {
                const e = frame.step_err.?;
                frame.step_err = null;
                switch (e) {
                    .Throw => |v| {
                        // Capture the call stack at the throw seam: the
                        // innermost frame to surface this value records the
                        // full chain (evtls.frame_chain is intact and innermost-first
                        // here); the attach is once-only, so the outward unwind
                        // through enclosing frames leaves it untouched.
                        var tv = v;
                        try attachStackTrace(allocator, &tv);
                        thrown = tv;
                        break;
                    },
                    .NonLocalReturn, .LabeledReturn => {
                        // A non-local return (labeled or untargeted) unwinds
                        // through the lambda frame *and* through any
                        // inline-function frames it was passed into, landing
                        // in the function that wrote the lambda (Kotlin allows
                        // non-local return only via inline functions). Like a
                        // throw, it runs the finally blocks of every armed try
                        // region it crosses -- but no catch clause takes it.
                        unwound = e;
                        break;
                    },
                    .CalleeFailed, .StackOverflow => {
                        // An interpreter-level failure from a body that RAN
                        // (the callee boundary re-tags resolution-class
                        // escapes to `CalleeFailed` exactly so walkers never
                        // retry it) unwinds like a throw for `finally`
                        // purposes: Kotlin guarantees finally on every
                        // unwind, and skipping it left global state behind
                        // (a dying compose test's un-run `finally` leaked a
                        // stale recomposer flag/scope into later tests — the
                        // cross-test no-changes contamination family). No
                        // catch clause takes it: it is not a Kotlin
                        // Throwable. Probe-class misses (`Unimplemented`)
                        // stay on the immediate path below — they are
                        // dispatch control flow, and running user finallys
                        // per candidate probe would corrupt state.
                        unwound = e;
                        break;
                    },
                    .Suspended => |state| {
                        // Report the suspension point so the driver can park
                        // this frame — live for a flat activation, snapshot
                        // for a native root. The resume value lands in the
                        // suspending call's destination register (or one a
                        // binding set explicitly via `pending_resume_reg`).
                        const resume_reg = if (state.pending_resume_reg) |rr| blk: {
                            state.pending_resume_reg = null;
                            break :blk rr;
                        } else instDst(inst);
                        park_out.* = .{ .block = cur, .inst_idx = idx + 1, .resume_reg = resume_reg };
                        return errResult(.{ .Suspended = state });
                    },
                    else => return errResult(e),
                }
            }
        }
        if (unwound) |e| {
            // Mid-block non-local return -- route through the armed finally
            // blocks only (never a catch), then keep unwinding.
            frame.pending_finally.release(allocator);
            var routed = false;
            while (try_stack.pop()) |tf| {
                if (tf.finally_entry) |fin| {
                    if (std.meta.eql(fin, cur)) continue;
                    const key = tf.finally_done orelse fin;
                    frame.pending_finally.unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                    cur = fin;
                    routed = true;
                    break;
                }
            }
            if (!routed) return unwindTerminal(frame, e);
            continue;
        }
        if (thrown) |exc| {
            // Mid-block throw — same try-stack walk as Terminator.Throw.
            const pending_depth = frame.pending_finally.tryDepth();
            var routed = false;
            while (try_stack.pop()) |tf| {
                // A throw raised inside this frame's own finally body must not
                // route back into that finally, nor into the frame's catches:
                // control already left the try region when the finally began.
                // The frame is still armed here only on the normal-completion
                // entry (the symmetric pop runs when the entry block exits).
                if (tf.finally_entry) |fin0| {
                    if (std.meta.eql(fin0, cur)) continue;
                }
                if (findCatch(H, host, &exc, tf.catches)) |h| {
                    // A catch belonging to a try nested inside the active
                    // finally handles the new throw without replacing the
                    // exception / return that caused the finally to run.
                    // Once the scan crosses the saved stack depth, the throw
                    // is escaping that finally and Kotlin replaces the prior
                    // control flow with it.
                    if (pending_depth) |depth| {
                        if (try_stack.items.len < depth) frame.pending_finally.release(allocator);
                    }
                    try frame.write(h.exception_reg, exc);
                    cur = h.handler;
                    routed = true;
                    break;
                } else if (tf.finally_entry) |fin| {
                    // An uncaught throw entering a nested finally will escape
                    // its surrounding finally (or itself be replaced there),
                    // so it supersedes the already-pending control flow.
                    frame.pending_finally.release(allocator);
                    const key = tf.finally_done orelse fin;
                    frame.pending_finally.rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                    cur = fin;
                    routed = true;
                    break;
                }
            }
            if (!routed) {
                frame.pending_finally.release(allocator);
                return errResult(.{ .Throw = exc });
            }
            continue;
        }
        // Symmetric try-stack pop on normal flow through finally.
        if (term == .Goto and frame.pending_finally.rethrow == null and frame.pending_finally.return_value == null and frame.pending_finally.unwind == null) {
            const done_for = frame.block(cur).finally_done_for;
            const pos: ?usize = if (done_for) |body|
                rpositionByBody(try_stack.items, body)
            else
                rpositionByFinallyEntry(try_stack.items, cur);
            if (pos) |p| {
                _ = try_stack.orderedRemove(p);
            }
        }
        // An inline `return` that replayed its enclosing finallys inline and
        // is jumping to its join bypasses the finally sentinel, so pop the
        // try-region frames it just unwound (`Block.pop_on_exit`) here — else
        // they linger and a later plain return re-enters the finally.
        if (term == .Goto) {
            for (block.pop_on_exit) |body| {
                if (rpositionByBody(try_stack.items, body)) |p| {
                    _ = try_stack.orderedRemove(p);
                }
            }
        }
        // Finally exit with a pending return: replay the return through
        // any outer finally, otherwise complete it. The key pinned in
        // `pending_finally.return_value` is the *done sentinel* — the synthesized exit
        // block of the user finally body, so an `if`/`when` inside the
        // finally still resolves here once its join reaches the sentinel.
        if (frame.pending_finally.return_value) |pr| {
            if (std.meta.eql(pr.key, cur) and term == .Goto) {
                const v = pr.val;
                frame.pending_finally.return_value = null;
                var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                var i: usize = try_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (try_stack.items[i].finally_entry) |fin2| {
                        const key = try_stack.items[i].finally_done orelse fin2;
                        chosen = .{ .i = i, .jump = fin2, .key = key };
                        break;
                    }
                }
                if (chosen) |c| {
                    try_stack.shrinkRetainingCapacity(c.i);
                    frame.pending_finally.return_value = .{ .key = c.key, .val = v, .depth = try_stack.items.len };
                    cur = c.jump;
                    continue;
                }
                return ok(v);
            }
            if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                pr.val.release(allocator);
                frame.pending_finally.return_value = null;
            }
        }
        // Finally re-throw: if we entered the current block as a finally
        // on the uncaught-throw path, and the block exits via a plain
        // Goto (no `return` / `throw` swallowed the pending exception),
        // re-raise the saved exception through the enclosing try-stack
        // just like a fresh throw.
        if (frame.pending_finally.rethrow) |pr| {
            if (std.meta.eql(pr.key, cur) and term == .Goto) {
                const exc = pr.exc;
                frame.pending_finally.rethrow = null;
                // Drop any try-frames the finally body pushed (and did not pop)
                // so they cannot intercept the re-raised exception.
                if (try_stack.items.len > pr.depth) try_stack.shrinkRetainingCapacity(pr.depth);
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (findCatch(H, host, &exc, tf.catches)) |h| {
                        try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin2| {
                        const key = tf.finally_done orelse fin2;
                        frame.pending_finally.rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                        cur = fin2;
                        routed = true;
                        break;
                    }
                }
                if (!routed) {
                    return errResult(.{ .Throw = exc });
                }
                continue;
            }
            // A `return` / `throw` inside finally clears the pending
            // re-throw (Kotlin: finally's exit replaces the original).
            if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                pr.exc.release(allocator);
                frame.pending_finally.rethrow = null;
            }
        }
        // Finally exit with a pending non-local return: replay it through any
        // outer finally, otherwise resume the unwind out of this frame.
        if (frame.pending_finally.unwind) |pu| {
            if (std.meta.eql(pu.key, cur) and term == .Goto) {
                const e = pu.err;
                frame.pending_finally.unwind = null;
                if (try_stack.items.len > pu.depth) try_stack.shrinkRetainingCapacity(pu.depth);
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (tf.finally_entry) |fin2| {
                        const key = tf.finally_done orelse fin2;
                        frame.pending_finally.unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                        cur = fin2;
                        routed = true;
                        break;
                    }
                }
                if (!routed) return unwindTerminal(frame, e);
                continue;
            }
            // A `return` / `throw` inside the finally replaces the pending
            // non-local return.
            if (std.meta.eql(pu.key, cur) and isReturnLike(term)) {
                if (PendingFinallyState.payloadOfError(pu.err)) |v| v.release(allocator);
                frame.pending_finally.unwind = null;
            }
        }
        // A return/throw written inside a finally replaces the control flow
        // that entered it, even when the finally spans several IR blocks and
        // the exit is not its synthesized done sentinel.
        if (replacesPendingBeforeRouting(term)) frame.pending_finally.release(allocator);
        switch (term) {
            .Goto => |next| cur = next,
            .Branch => |br| {
                const v = frame.read(br.cond);
                switch (try valueTruthy(allocator, &v)) {
                    .ok => |b| cur = if (b) br.t else br.f,
                    .err => |e| return errResult(e),
                }
            },
            .Return => |maybe_r| {
                const v = if (maybe_r) |r| frame.read(r) else Value.Unit;
                // The value escapes this frame; retain so frame teardown does
                // not free it from under the caller.
                v.retain();
                // Walk the try-stack for the nearest finally; route the
                // return through it.
                var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                var i: usize = try_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (try_stack.items[i].finally_entry) |fin| {
                        // A return from inside this frame's own finally body
                        // exits through OUTER finallys only; re-entering its
                        // own finally would run the block twice.
                        if (std.meta.eql(fin, cur)) continue;
                        const key = try_stack.items[i].finally_done orelse fin;
                        chosen = .{ .i = i, .jump = fin, .key = key };
                        break;
                    }
                }
                if (chosen) |c| {
                    try_stack.shrinkRetainingCapacity(c.i);
                    frame.pending_finally.return_value = .{ .key = c.key, .val = v, .depth = try_stack.items.len };
                    cur = c.jump;
                    continue;
                }
                return ok(v);
            },
            .NonLocalReturn => |maybe_r| {
                const v = if (maybe_r) |r| frame.read(r) else Value.Unit;
                v.retain();
                const e = EvalError{ .NonLocalReturn = v };
                if (nearestFinally(try_stack, cur)) |c| {
                    frame.pending_finally.unwind = .{ .key = c.key, .err = e, .depth = try_stack.items.len };
                    cur = c.jump;
                    continue;
                }
                return unwindTerminal(frame, e);
            },
            .LabeledReturn => |lr| {
                if (lrTraceOn()) {
                    if (frame.cur_span) |sp| std.debug.print("[lr-raise] label={s} span={d}:{d} in_fn={s}\n", .{ lr.label, sp.file.int(), sp.start, frame.func.name });
                    dumpFrameChainForDiagAlways();
                }
                const v = if (lr.value) |r| frame.read(r) else Value.Unit;
                v.retain();
                const e = EvalError{ .LabeledReturn = .{ .label = lr.label, .value = v } };
                if (nearestFinally(try_stack, cur)) |c| {
                    frame.pending_finally.unwind = .{ .key = c.key, .err = e, .depth = try_stack.items.len };
                    cur = c.jump;
                    continue;
                }
                return unwindTerminal(frame, e);
            },
            .Throw => |r| {
                var exc = frame.read(r);
                exc.retain();
                // Capture the call stack here, in the throwing frame, before it
                // unwinds (`fillInStackTrace`): the instruction-loop seam only
                // sees the value once it has already surfaced into the caller,
                // by which point this frame is gone. Attach-once, so a re-throw
                // keeps the original trace.
                try attachStackTrace(allocator, &exc);
                if (envVarSet("KLIO_THROW_TRACE")) {
                    const s = displayThrow(allocator, &exc) catch "";
                    std.debug.print("[throw-trace] from fn {s} (fqn={s}): {s}\n", .{ frame.func.name, frame.func.fqn, s });
                    if (envVarSet("KLIO_THROW_STACK")) dumpFrameChainForDiagAlways();
                }
                // Walk the try stack for a matching handler.
                const pending_depth = frame.pending_finally.tryDepth();
                var routed = false;
                while (try_stack.pop()) |tf| {
                    // Same own-finally guard as the mid-block walk: a throw
                    // from inside this frame's finally body skips the frame.
                    if (tf.finally_entry) |fin0| {
                        if (std.meta.eql(fin0, cur)) continue;
                    }
                    if (findCatch(H, host, &exc, tf.catches)) |h| {
                        if (pending_depth) |depth| {
                            if (try_stack.items.len < depth) frame.pending_finally.release(allocator);
                        }
                        try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin| {
                        frame.pending_finally.release(allocator);
                        const key = tf.finally_done orelse fin;
                        frame.pending_finally.rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                        cur = fin;
                        routed = true;
                        break;
                    }
                }
                if (!routed) {
                    frame.pending_finally.release(allocator);
                    return errResult(.{ .Throw = exc });
                }
            },
            .Unreachable => {
                return errResult(.{ .Type = "reached Terminator.Unreachable" });
            },
            .TailJump => |tj| {
                var new_params: std.ArrayList(Value) = .empty;
                var k: u8 = 0;
                while (k < tj.n_args) : (k += 1) {
                    try new_params.append(allocator, frame.read(Reg.from(tj.args.int() + @as(u32, k))));
                }
                coerceIntArgsToLong(frame.func, new_params.items);
                frame.params.deinit(allocator);
                frame.params = new_params;
                const n = frame.regs.items.len;
                frame.regs.clearRetainingCapacity();
                try frame.regs.appendNTimes(regsAlloc(allocator), .Unit, n);
                try_stack.clearRetainingCapacity();
                cur = frame.func.entry;
            },
            .TailCallFunc => |tc| {
                var new_params: std.ArrayList(Value) = .empty;
                var k: u8 = 0;
                while (k < tc.n_args) : (k += 1) {
                    try new_params.append(allocator, frame.read(Reg.from(tc.args.int() + @as(u32, k))));
                }
                const new_func = module.funcById(tc.func).?;
                coerceIntArgsToLong(@constCast(new_func), new_params.items);
                frame.func = new_func;
                frame.params.deinit(allocator);
                frame.params = new_params;
                frame.regs.clearRetainingCapacity();
                try frame.regs.appendNTimes(regsAlloc(allocator), .Unit, new_func.n_locals);
                try_stack.clearRetainingCapacity();
                cur = new_func.entry;
            },
            .Switch => |sw| {
                const v = frame.read(sw.reg);
                var next = sw.default;
                for (sw.arms) |arm| {
                    if (constMatches(frame.module, arm.key, &v)) {
                        next = arm.target;
                        break;
                    }
                }
                cur = next;
            },
        }
    }
}

/// Whether the named environment variable is present. Used only by the
/// optional throw-trace diagnostic. Reads the process environment portably
/// (see `runtime.procEnvIsSet`).
fn envVarSet(name: []const u8) bool {
    return runtime.procEnvIsSet(std.heap.page_allocator, name);
}

fn isReturnLike(term: Terminator) bool {
    return switch (term) {
        .Return, .NonLocalReturn, .LabeledReturn, .Throw => true,
        else => false,
    };
}

fn replacesPendingBeforeRouting(term: Terminator) bool {
    return switch (term) {
        .Return, .NonLocalReturn, .LabeledReturn => true,
        else => false,
    };
}

fn rpositionByBody(items: []const TryFrame, body: BlockId) ?usize {
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (std.meta.eql(items[i].body, body)) return i;
    }
    return null;
}

fn rpositionByFinallyEntry(items: []const TryFrame, cur: BlockId) ?usize {
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i].finally_entry) |b| {
            if (std.meta.eql(b, cur)) return i;
        }
    }
    return null;
}

fn findCatch(comptime H: type, host: *H, exc: *const Value, catches: []const ir.CatchHandler) ?ir.CatchHandler {
    for (catches) |h| {
        if (host.instanceOf(exc, typeRefName(h.type_name))) return h;
    }
    return null;
}

/// Destination register of a value-producing instruction, used to route
/// a coroutine resume value back to the suspending call site.
fn instDst(inst: *const Inst) ?Reg {
    return switch (inst.*) {
        .Call => |x| x.dst,
        .CallValue => |x| x.dst,
        .CallValueWithThis => |x| x.dst,
        .CallSpread => |x| x.dst,
        .CallSuper => |x| x.dst,
        .CallMember => |x| x.dst,
        .CallVirtual => |x| x.dst,
        .CallMemberOrGlobal => |x| x.dst,
        .CallValueOrMember => |x| x.dst,
        .CallMemberOrValue => |x| x.dst,
        .NewInstance => |x| x.dst,
        .CtxScope => |x| x.dst,
        .CtxCall => |x| x.dst,
        else => null,
    };
}

/// Fetch the string text of a `Const.String` const, or `null` when the
/// const is not a string.
fn constStr(module: *const Module, id: ConstId) ?[]const u8 {
    return switch (module.consts.items[id.int()]) {
        .String => |s| s,
        else => null,
    };
}

/// A callable reference (`Long::toByte`, `recv::method`) is represented as a
/// synth `Instance` whose class name is `$bound_ref$<name>`. Such a value is
/// invocable even though it carries no `invoke` member declaration.
fn isBoundRefInstance(v: *const Value) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.startsWith(u8, cg.get().name, "$bound_ref$");
}

/// Every arm is OUTLINED and `execInst` itself stays `noinline`. Zig does not
/// reclaim block-scoped stack allocations (ziglang/zig#23475), so all 49 arms'
/// locals lived in ONE frame — the SUM, not the max — held live across the
/// interpreter's recursion. On the INTERPRETED path (the JIT off, or any
/// function not yet hot) that was 35,834 bytes of native stack per call; it is
/// 14,299 now, and the recursion ceiling went 7.5k -> 18.8k frames.
///
/// `noinline` is required, not cosmetic: outlining the arms alone lets LLVM
/// inline `execInst` into `runFrameInner`, so the arm frame is ADDED rather than
/// substituted and the ceiling gets WORSE.
///
/// This does nothing for the JIT'd path — once a function is hot the recursive
/// call runs native code -> `LoopTramp.call` -> `callFunc` and never reaches
/// here. That path is served by outlining the trampoline's bulky sites.
noinline fn execInst(comptime H: type, allocator: Allocator, frame: *Frame, inst: *const Inst, host: *H) Allocator.Error!Step {
    switch (inst.*) {
        .SuspendResumePoint => {
            // No runtime effect on its own.
        },
        .Const => |c| {
            const v = try constToValue(allocator, &frame.module.consts.items[c.value.int()]);
            try frame.write(c.dst, v);
        },
        .Move => |mv| {
            const v = frame.read(mv.src);
            v.retain();
            try frame.write(mv.dst, v);
        },
        .MakeCell => |mc| {
            const v = frame.read(mc.src);
            v.retain();
            try frame.write(mc.dst, try Value.newCell(allocator, v));
        },
        .CellGet => |cg| {
            const v = switch (frame.read(cg.cell)) {
                .Cell => |c| blk: {
                    const g = c.borrow();
                    defer g.deinit();
                    break :blk g.get().*;
                },
                else => |other| other,
            };
            v.retain();
            try frame.write(cg.dst, v);
        },
        .CellSet => |cs| return execArmCellSet(H, allocator, frame, cs, host),
        .Not => |n| {
            const v = frame.read(n.src);
            // User-defined `operator fun not(): T` overrides the builtin
            // Bool inversion; route through call_member.
            if (v == .Instance) {
                const result = host.callMember(allocator, &v, "not", &.{});
                switch (try result) {
                    .ok => |rv| {
                        try frame.write(n.dst, rv);
                        return .cont;
                    },
                    .err => |e| return raiseStep(frame, e),
                }
            }
            const b = switch (v) {
                .Bool => |bv| !bv,
                else => return raiseStep(frame, .{ .Type = "Not on non-bool" }),
            };
            try frame.write(n.dst, .{ .Bool = b });
        },
        .UnOp => |u| return execArmUnOp(H, allocator, frame, u, host),
        .BinOp => |bo| return execArmBinOp(H, allocator, frame, bo, host),
        .Trace => |t| frame.cur_span = t.span,
        .LoadParam => |lp| {
            const v = if (lp.idx < frame.params.items.len) frame.params.items[lp.idx] else Value.Unit;
            v.retain();
            try frame.write(lp.dst, v);
        },
        .NotNullAssert => |nn| {
            const v = frame.read(nn.src);
            if (v == .Null) {
                const exc = Value{ .Exception = .{
                    .fqn = try runtime.strInit(allocator, "kotlin.NullPointerException"),
                    .message = null,
                    .cause = null,
                } };
                return raiseStep(frame, .{ .Throw = exc });
            }
            v.retain();
            try frame.write(nn.dst, v);
        },
        .GetField => |gf| return execArmGetField(H, allocator, frame, gf, host),
        .SetField => |sf| return execArmSetField(H, allocator, frame, sf, host),
        .CompoundField => |cf| return execArmCompoundField(H, allocator, frame, cf, host),
        .Call => |call| return execArmCall(H, allocator, frame, call, host),
        .CallValue => |cv| return execArmCallValue(H, allocator, frame, cv, host),
        .CallValueWithThis => |cvt| {
            const callee_v = frame.read(cvt.callee);
            const recv = frame.read(cvt.receiver);
            const arg_values = try readArgRun(allocator, frame, cvt.args, cvt.n_args);
            defer allocator.free(arg_values);
            const names = try resolveArgNames(allocator, frame.module, cvt.arg_names);
            defer allocator.free(names);
            if (cvTraceOn()) {
                std.debug.print("[cvt-instr] exact={} recv={s} n_args={d} caller={s}", .{
                    cvt.receiver_shape_exact, @tagName(std.meta.activeTag(recv)), arg_values.len, frame.func.name,
                });
                for (arg_values) |*av| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(av.*))});
                std.debug.print("\n", .{});
            }
            // Flat receiver-lambda dispatch: the plain bound shape (a
            // `this`-capture closure at exact arity) runs as a pushed
            // activation; the host performs the same receiver selection and
            // capture binding the recursive path would, then hands back the
            // ready call. The special shapes (local named fn,
            // receiver-fills-param, pass-threaded composable, explicit
            // receiver overflow) decline and keep the recursive path.
            if (comptime @hasDecl(H, "prepareClosureWithThisFlatCall")) {
                if (flatEnabled() and callee_v == .IrClosure and argNamesAllNull(cvt.arg_names)) {
                    if (try host.prepareClosureWithThisFlatCall(allocator, &callee_v, &recv, arg_values)) |prep0| {
                        var prep = prep0;
                        prep.dst = cvt.dst;
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            const result = if (cvt.receiver_shape_exact)
                try host.callValueWithThisExact(allocator, &callee_v, &recv, arg_values, names)
            else
                try host.callValueWithThis(allocator, &callee_v, &recv, arg_values, names);
            switch (result) {
                .ok => |rv| try frame.write(cvt.dst, rv),
                .err => |e| return raiseStep(frame, e),
            }
        },
        .CallSpread => |cs| return execArmCallSpread(H, allocator, frame, cs, host),
        .CallSuper => |csup| return execArmCallSuper(H, allocator, frame, csup, host),
        .CallMemberOrGlobal => |cmg| return execCallMemberOrGlobal(H, allocator, frame, cmg, host),
        .CallMember => |cm| return execArmCallMember(H, allocator, frame, cm, host),
        .CallVirtual => |cv| return execArmCallVirtual(H, allocator, frame, cv, host),
        .CallMemberOrValue => |cmv| return execArmCallMemberOrValue(H, allocator, frame, cmv, host),
        .CallValueOrMember => |cvm| return execArmCallValueOrMember(H, allocator, frame, cvm, host),
        .NewInstance => |ni| return execArmNewInstance(H, allocator, frame, ni, host),
        .InstanceOf => |io| return execArmInstanceOf(H, allocator, frame, io, host),
        .CtxLoad => |cl| {
            if (comptime !@hasDecl(H, "ctxResolve")) {
                try frame.write(cl.dst, .Null);
                return .cont;
            }
            const ty_name = constStr(frame.module, cl.ty) orelse "";
            const v = host.ctxResolve(ty_name, cl.erased) orelse Value.Null;
            v.retain();
            try frame.write(cl.dst, v);
        },
        .CtxScope => |cs| return execArmCtxScope(H, allocator, frame, cs, host),
        .CtxCall => |cc| return execArmCtxCall(H, allocator, frame, cc, host),
        .Cast => |cast| return execArmCast(H, allocator, frame, cast, host),
        .Lambda => |lam| return execArmLambda(H, allocator, frame, lam, host),
        .AstLambda => |al| return execArmAstLambda(H, allocator, frame, al, host),
        .RegisterClass => |rc| return execArmRegisterClass(H, allocator, frame, rc, host),
        .BuildObject => |bobj| return execArmBuildObject(H, allocator, frame, bobj, host),
        .StoreGlobal => |sg| {
            const name_str = constStr(frame.module, sg.name) orelse
                return raiseStep(frame, .{ .Type = "StoreGlobal: name not a string const" });
            const v = frame.read(sg.value);
            switch (try host.storeGlobal(allocator, name_str, v)) {
                .ok => {},
                .err => |e| return raiseStep(frame, e),
            }
        },
        .StoreToThisOrGlobal => |stg| return execArmStoreToThisOrGlobal(H, allocator, frame, stg, host),
        .LoadGlobal => |lg| {
            const name_str = constStr(frame.module, lg.name) orelse
                return raiseStep(frame, .{ .Type = "LoadGlobal: name not a string const" });
            // A lowering-resolved identity binds that exact declaration;
            // the name string is only the unresolved-shape fallback.
            const by_id: ?Value = if (lg.func != null or lg.class != null)
                host.lookupGlobalById(allocator, lg.func, lg.class, lg.ctor_ref)
            else
                null;
            const lg_r: MaybeValueResult = if (by_id != null) .{ .ok = by_id } else try host.lookupGlobalThrowing(allocator, name_str);
            const found = switch (lg_r) {
                .ok => |maybe| maybe,
                .err => |e| return raiseStep(frame, e),
            };
            // No receiver probe here: a `LoadGlobal` is emitted only where
            // no implicit receiver can shadow the name, and kotlinc
            // rejects resolving it against a *caller's* receiver (dynamic
            // scope), so a miss is a hard unresolved reference.
            var v: Value = undefined;
            if (found) |fv| {
                v = fv;
            } else if (comptime @hasDecl(H, "callFunc")) {
                // A top-level `val`/`var` declared with only a custom getter
                // has no global binding; re-run its 0-arg getter on each read.
                if (frame.module.registry.top_level_prop_getters.get(name_str)) |getter_fid| {
                    switch (try host.callFunc(allocator, frame.module, getter_fid, &.{})) {
                        .ok => |gv| {
                            try frame.write(lg.dst, gv);
                            return .cont;
                        },
                        .err => |e| return raiseStep(frame, e),
                    }
                }
                // A qualified class/companion member the lowering flattened to
                // one global name (`import X.Companion.Y` baked as the FQN
                // `pkg.X.Y`): no such global binding exists, but the owner
                // class does — split at the last dot and read the member off
                // the class value (which serves companion fields), so the
                // import aliases the SAME value `X.Y` reads.
                if (std.mem.lastIndexOfScalar(u8, name_str, '.')) |dot| {
                    if (dot != 0 and dot + 1 < name_str.len) {
                        const owner_v: ?Value = switch (try host.lookupGlobalThrowing(allocator, name_str[0..dot])) {
                            .ok => |maybe| maybe,
                            .err => null,
                        };
                        if (owner_v) |ov| {
                            if (ov == .Class or ov == .Instance) {
                                switch (try host.getField(allocator, &ov, name_str[dot + 1 ..])) {
                                    .ok => |fv| {
                                        fv.retain();
                                        try frame.write(lg.dst, fv);
                                        return .cont;
                                    },
                                    .err => {},
                                }
                            }
                        }
                    }
                }
                if (envVarSet("KLIO_UNRESOLVED_TRACE")) {
                    std.debug.print("[unresolved] `{s}` in fn {s} (fqn={s}) span={any}\n", .{ name_str, frame.func.name, frame.func.fqn, frame.cur_span });
                }
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[lg-tail-a] name={s} func={?} class={?} span={d}:{d} in_fn={s}\n", .{ name_str, if (lg.func) |f| f.int() else null, if (lg.class) |c| c.int() else null, if (frame.cur_span) |sp| sp.file.int() else 0, if (frame.cur_span) |sp| sp.start else 0, frame.func.name });
                }
                dumpFrameChainForDiag();
                return raiseStep(frame, .{ .Unbound = msg });
            } else {
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[lg-tail-b] name={s} func={?} class={?}\n", .{ name_str, if (lg.func) |f| f.int() else null, if (lg.class) |c| c.int() else null });
                }
                dumpFrameChainForDiag();
                return raiseStep(frame, .{ .Unbound = msg });
            }
            v.retain();
            try frame.write(lg.dst, v);
        },
        .LoadCapture => |lc| {
            const v = if (lc.idx < frame.captures.items.len) frame.captures.items[lc.idx] else Value.Unit;
            v.retain();
            try frame.write(lc.dst, v);
        },
        .LoadFromThisOrGlobal => |lt| return execArmLoadFromThisOrGlobal(H, allocator, frame, lt, host),
        .Index => |ix| return execArmIndex(H, allocator, frame, ix, host),
        .IndexSet => |ixs| return execArmIndexSet(H, allocator, frame, ixs, host),
        .NewList => |nl| return execArmNewList(H, allocator, frame, nl, host),
        .QualifiedThis => |qt| return execArmQualifiedThis(H, allocator, frame, qt, host),
        .PropertyRef => |pr| return execArmPropertyRef(H, allocator, frame, pr, host),
        .MemberRef => |mr| return execArmMemberRef(H, allocator, frame, mr, host),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCellSet(comptime H: type, allocator: Allocator, frame: *Frame, cs: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const v = frame.read(cs.value);
    v.retain();
    switch (frame.read(cs.cell)) {
        .Cell => |c| {
            const g = c.borrowMut();
            defer g.deinit();
            const old = g.get().*;
            g.get().* = v;
            if (runtime.reclaimEnabled()) old.release(allocator);
        },
        else => {
            try frame.write(cs.cell, v);
        },
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmUnOp(comptime H: type, allocator: Allocator, frame: *Frame, u: anytype, host: *H) Allocator.Error!Step {
    const v = frame.read(u.operand);
    // Builtin scalar fast path: outside any class scope a scalar's
    // unary operators are its builtin members and no extension can
    // shadow them, so the string-keyed probe below (a full member
    // dispatch per `i++` in every counting loop) is semantically
    // dead. Inside a class scope a MEMBER EXTENSION operator can
    // apply (`operator fun Int.unaryPlus()` in a DSL builder —
    // kotlinc resolves `+1` to it), so any enclosing instance
    // keeps the probe.
    const enclosing_possible = frame.enclosing_this.items.len != 0 or
        (frame.params.items.len > 0 and frame.params.items[0] == .Instance);
    if (!enclosing_possible) {
        switch (v) {
            .Int, .Long, .Double, .Float, .Short, .Byte, .Char, .UInt, .ULong, .UShort, .UByte => {
                switch (try applyUnop(allocator, u.op, &v)) {
                    .ok => |out| {
                        try frame.write(u.dst, out);
                        return .cont;
                    },
                    .err => {},
                }
            },
            else => {},
        }
    }
    const method = switch (u.op) {
        .Neg => "unaryMinus",
        .Plus => "unaryPlus",
        .Inc => "inc",
        .Dec => "dec",
    };
    // User-class operator dispatch for unary +/-/inc/dec on an
    // Instance always wins.
    if (v == .Instance) {
        switch (try host.callMember(allocator, &v, method, &.{})) {
            .ok => |rv| {
                try frame.write(u.dst, rv);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // Member-extension operator on a primitive receiver. The
    // calling frame's `this` carries the enclosing class —
    // surface it as enclosing-this so the extension-fallback
    // visibility filter accepts the member-ext owner.
    var pushed_enclosing = false;
    if (frame.params.items.len > 0 and frame.params.items[0] == .Instance) {
        pushEnclosingAccess(&frame.params.items[0]);
        pushed_enclosing = true;
    }
    const extension_result = try host.callMember(allocator, &v, method, &.{});
    if (pushed_enclosing) popEnclosing();
    switch (extension_result) {
        .ok => |rv| {
            try frame.write(u.dst, rv);
            return .cont;
        },
        .err => |e| switch (e) {
            .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
            else => return raiseStep(frame, e),
        },
    }
    switch (try applyUnop(allocator, u.op, &v)) {
        .ok => |out| try frame.write(u.dst, out),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmBinOp(comptime H: type, allocator: Allocator, frame: *Frame, bo: anytype, host: *H) Allocator.Error!Step {
    var l = frame.read(bo.lhs);
    var r = frame.read(bo.rhs);
    // A boxed capture is transparent to every operator: the Cell
    // is a carrier (an anon-object method's captured outer `var`),
    // never a user value — `result == null` must compare the
    // content.
    while (l == .Cell) {
        const cg = l.Cell.borrow();
        l = cg.get().*;
        cg.deinit();
    }
    while (r == .Cell) {
        const cg = r.Cell.borrow();
        r = cg.get().*;
        cg.deinit();
    }
    // StringConcat over a Value.Instance routes the instance
    // through toString so user-defined overrides fire.
    if (bo.op == .StringConcat) {
        const ls = switch (try stringify(H, allocator, host, &l)) {
            .ok => |s| s,
            .err => |e| return raiseStep(frame, e),
        };
        const rs = switch (try stringify(H, allocator, host, &r)) {
            .ok => |s| s,
            .err => |e| return raiseStep(frame, e),
        };
        const combined = try std.mem.concat(allocator, u8, &.{ ls, rs });
        // `ls`/`rs` are owned renderings (stringify/renderValue allocate
        // a private copy); `combined` is adopted by the StringRef cell.
        // Free the two now-dead pieces under a freeing allocator.
        if (runtime.freeScratch()) {
            allocator.free(ls);
            allocator.free(rs);
        }
        try frame.write(bo.dst, .{ .String = try runtime.strInitOwned(allocator, combined) });
        return .cont;
    }
    // Collection `+` / `-` operators are stdlib operator
    // functions on the left collection.
    if ((bo.op == .Add or bo.op == .Sub) and switch (l) {
        .Map, .List, .Set, .Sequence, .Range => true,
        else => false,
    }) {
        // A compound assign (`xs += y`) onto a mutable collection
        // dispatches the in-place `plusAssign` / `minusAssign`
        // (Kotlin prefers `MutableCollection.plusAssign`), so the
        // collection stays mutable. A read-only collection (or a
        // plain `xs + y`) takes the `plus` / `minus` path below,
        // producing a fresh read-only result.
        if (bo.compound) {
            const mutable = switch (l) {
                .List => |c| c.mutable,
                .Set => |c| c.mutable,
                .Map => |c| c.mutable,
                else => false,
            };
            if (mutable) {
                const assign = if (bo.op == .Add) "plusAssign" else "minusAssign";
                switch (try host.callMember(allocator, &l, assign, &.{r})) {
                    .ok => {
                        l.retain();
                        try frame.write(bo.dst, l);
                        return .cont;
                    },
                    .err => |e| return raiseStep(frame, e),
                }
            }
        }
        const method = if (bo.op == .Add) "plus" else "minus";
        switch (try host.callMember(allocator, &l, method, &.{r})) {
            .ok => |rv| {
                try frame.write(bo.dst, rv);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // Arrays define `+` (`plus`) but no `-`.
    if (bo.op == .Add and l == .Array) {
        switch (try host.callMember(allocator, &l, "plus", &.{r})) {
            .ok => |rv| {
                try frame.write(bo.dst, rv);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // Referential identity (`===` / `!==`): pure pointer
    // identity, never a user `equals` dispatch.
    if (bo.op == .IdentEq or bo.op == .IdentNeq) {
        const same = Value.referenceEq(&l, &r);
        const b = if (bo.op == .IdentNeq) !same else same;
        try frame.write(bo.dst, .{ .Bool = b });
        return .cont;
    }
    // Result wrappers have no user `equals` surface of their own, but their
    // payload equality still follows Kotlin `==`. This matters for value-class
    // wrappers such as ChannelResult, whose closed holder defines `equals`.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .Result or r == .Result))
    {
        const eq = if (l == .Result and r == .Result and l.Result.ok == r.Result.ok)
            if (comptime @hasDecl(H, "deepValueEquals"))
                try host.deepValueEquals(allocator, l.Result.payload.asPtr(), r.Result.payload.asPtr())
            else
                Value.structuralEq(l.Result.payload.asPtr(), r.Result.payload.asPtr())
        else
            false;
        const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
        try frame.write(bo.dst, .{ .Bool = b });
        return .cont;
    }
    // The suspension marker has identity-only equality and no member surface.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .CoroutineSuspended or r == .CoroutineSuspended))
    {
        const eq = Value.structuralEq(&l, &r);
        const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
        try frame.write(bo.dst, .{ .Bool = b });
        return .cont;
    }
    // `x == null` / `x != null` is a null check, never a user `equals`
    // dispatch (Kotlin compares against the null literal by identity).
    // Without this, every `?.` safe-call's null guard dispatched
    // `x.equals(null)` — a full member resolution per access.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .Null or r == .Null))
    {
        const both_null = l == .Null and r == .Null;
        const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !both_null else both_null;
        try frame.write(bo.dst, .{ .Bool = b });
        return .cont;
    }
    // Collection `==` / `!=`: compare element/entry-wise so a user
    // `equals` override fires (bare structural equality treats a
    // non-data Instance by identity, so `setOf(P)==setOf(P)`, map value
    // equality, and nested collections would be wrong).
    // Set/Map `==` / `!=`: compare element/entry-wise so a user
    // `equals` override fires (bare structural equality treats a
    // non-data Instance by identity, so `setOf(P)==setOf(P)` and map
    // value equality would be wrong). Restricted to a Set/Map operand:
    // List equality already dispatches element `equals` via
    // `collectionsEqualHostAware` and its array/sublist views need the
    // established path.
    // A native-collection LEFT operand against a user Instance also
    // routes here: Kotlin dispatches `a.equals(b)` on the LEFT, and a
    // native Set/List/Map's equals is the collection contract — the
    // instance need not override `equals` for `setOf(x) == wrapper`.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        ((isSetOrMap(&l) and isSetOrMap(&r)) or
            ((isSetOrMap(&l) or l == .List) and r == .Instance) or
            (l == .Pair and r == .Pair) or (l == .Triple and r == .Triple)))
    {
        if (comptime @hasDecl(H, "deepValueEquals")) {
            const eq = try host.deepValueEquals(allocator, &l, &r);
            const neg = bo.op == .NotEq or bo.op == .BoxedNotEq;
            try frame.write(bo.dst, .{ .Bool = if (neg) !eq else eq });
            return .cont;
        }
    }
    if (operatorMethod(bo.op)) |method| {
        if (l == .Instance or r == .Instance) {
            // `a == b` dispatches `a.equals(b)`, but a builtin
            // collection carries only structural equality; when the
            // left operand is a builtin and the right is a user
            // Instance (a class implementing Set/List/Map with its own
            // `equals`), dispatch on the Instance instead. Structural
            // equality is symmetric, so the result is identical and a
            // builtin receiver need not implement `equals(Instance)`.
            const swap = (bo.op == .Eq or bo.op == .BoxedEq or bo.op == .NotEq or bo.op == .BoxedNotEq) and l != .Instance and r == .Instance;
            const recv_ptr = if (swap) &r else &l;
            const arg_val = if (swap) l else r;
            // Strict extension dispatch: an operator extension whose
            // declared receiver doesn't accept `l` is not a candidate
            // (kotlinc drops it), so `Unimplemented` surfaces and the
            // `<op>Assign` fallback below can fire — `config += other`
            // on a type declaring only `plusAssign` must not bind a
            // receiver-incompatible `plus` like `String?.plus(Any?)`.
            var result: Value = undefined;
            switch (try host.callMemberStrictExt(allocator, recv_ptr, method, &.{arg_val}, &.{null}, null)) {
                .ok => |v| result = v,
                .err => |e| switch (e) {
                    // `a OP= b` lowers to `a = a.OP(b)`, but the
                    // type may declare only the in-place form.
                    .Unimplemented => {
                        if (l == .Instance and compoundAssignMethod(bo.op) != null) {
                            const assign = compoundAssignMethod(bo.op).?;
                            switch (try host.callMember(allocator, &l, assign, &.{r})) {
                                .ok => {},
                                .err => |e2| return raiseStep(frame, e2),
                            }
                            result = l;
                        } else if (bo.op == .Eq or bo.op == .BoxedEq or bo.op == .NotEq or bo.op == .BoxedNotEq) {
                            // No user `equals` surface: Kotlin's
                            // default is structural/identity equality
                            // (`!=` negates it below).
                            const boxed = bo.op == .BoxedEq or bo.op == .BoxedNotEq;
                            result = .{ .Bool = if (boxed)
                                Value.structuralEqBoxed(&l, &r)
                            else
                                Value.structuralEq(&l, &r) };
                        } else {
                            return raiseStep(frame, e);
                        }
                    },
                    else => return raiseStep(frame, e),
                },
            }
            // compareTo wrappers need to be reduced to a Bool.
            const final_val: Value = switch (bo.op) {
                .Less => .{ .Bool = if (valueToI64(&result)) |i| i < 0 else false },
                .LessEq => .{ .Bool = if (valueToI64(&result)) |i| i <= 0 else false },
                .Greater => .{ .Bool = if (valueToI64(&result)) |i| i > 0 else false },
                .GreaterEq => .{ .Bool = if (valueToI64(&result)) |i| i >= 0 else false },
                // `!=`: negate the `equals` result.
                .NotEq, .BoxedNotEq => if (result == .Bool) Value{ .Bool = !result.Bool } else result,
                else => result,
            };
            try frame.write(bo.dst, final_val);
            return .cont;
        }
    }
    // A `..` / `..<` over operands the i64-backed `Range` value cannot
    // represent — floating point (`ClosedFloatingPointRange`), strings,
    // or any other `Comparable` (`ClosedRange` via `Comparable.rangeTo`)
    // — routes to the stdlib `rangeTo`/`rangeUntil` operator. Integer,
    // Char and unsigned operands are handled by `applyBinop` below.
    if ((bo.op == .RangeTo or bo.op == .RangeUntil) and
        (l == .Double or l == .Float or r == .Double or r == .Float or
            l == .String or r == .String or l == .Instance or r == .Instance))
    {
        const method = if (bo.op == .RangeUntil) "rangeUntil" else "rangeTo";
        switch (try host.callMember(allocator, &l, method, &.{r})) {
            .ok => |rv| {
                try frame.write(bo.dst, rv);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // Builtin-collection equality whose ELEMENTS include user
    // instances (a windowed tail yields the raw RingBuffer — a
    // List on the JVM): pure structural comparison cannot
    // dispatch the element's `equals`, so ask the host for an
    // element-wise compare before falling back.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .List or r == .List))
    {
        if (host.collectionsEqualHostAware(allocator, &l, &r)) |eq| {
            const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
            try frame.write(bo.dst, .{ .Bool = b });
            return .cont;
        }
    }
    switch (try applyBinop(allocator, bo.op, &l, &r)) {
        .ok => |out| try frame.write(bo.dst, out),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmGetField(comptime H: type, allocator: Allocator, frame: *Frame, gf: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(gf.receiver);
    const name = constStr(frame.module, gf.field) orelse
        return raiseStep(frame, .{ .Type = "GetField: name not a string const" });
    // Keep the executing function's receiver reachable as the
    // enclosing `this` while the field/property is resolved. Inside
    // a lambda the receiver rides the closure's captured `this`
    // slot rather than params[0] (`placeable.mainAxisSize` in a
    // `repeat { }` body needs the enclosing item as the
    // member-extension property's owner) — `callerThisValue`
    // resolves both forms.
    var pushed_enclosing = false;
    if (callerThisValue(frame)) |ct_v| {
        var ct = ct_v;
        const same = recv == .Instance and ct == .Instance and
            ObjRef(InstanceData).ptrEq(ct.Instance, recv.Instance);
        if (!same) {
            pushEnclosingAccess(&ct);
            pushed_enclosing = true;
        }
    }
    const got = host.getField(allocator, &recv, name);
    if (pushed_enclosing) popEnclosing();
    switch (try got) {
        // host.getField returns a borrowed field value; the register owns its ref.
        .ok => |v| {
            v.retain();
            try frame.write(gf.dst, v);
        },
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmSetField(comptime H: type, allocator: Allocator, frame: *Frame, sf: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(sf.receiver);
    const v = frame.read(sf.value);
    const name = constStr(frame.module, sf.field) orelse
        return raiseStep(frame, .{ .Type = "SetField: name not a string const" });
    const super_owner: ?[]const u8 = if (sf.super_owner) |c| constStr(frame.module, c) else null;
    switch (try host.setFieldFrom(allocator, &recv, name, v, super_owner)) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
fn modCountFrozenEval(mc: ?runtime.ObjRef(u64)) bool {
    const cell = mc orelse return false;
    const g = cell.borrow();
    defer g.deinit();
    return (g.get().* & runtime.FROZEN_MOD_BIT) != 0;
}

noinline fn execArmCompoundField(comptime H: type, allocator: Allocator, frame: *Frame, cf: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(cf.receiver);
    const v = frame.read(cf.value);
    const name = constStr(frame.module, cf.field) orelse
        return raiseStep(frame, .{ .Type = "CompoundField: name not a string const" });
    const cur = switch (try host.getField(allocator, &recv, name)) {
        .ok => |fv| fv,
        .err => |e| return raiseStep(frame, e),
    };
    // A collection-typed property compound-assigns in place: Kotlin
    // dispatches `<op>Assign` on the field value and never reassigns
    // the property. A mutable collection mutates; a read-only view
    // (`map.entries`, `keys`, `values`) raises UnsupportedOperationException
    // from its `add`. Either way there is NO write-back to the
    // (read-only) property.
    // A READ-ONLY collection value cannot inhabit a Mutable*-typed
    // property in well-typed Kotlin, so its `+=` resolved to the binary
    // `plus` with a property write-back (`var invalidations: List<...>;
    // reference.invalidations += pair` builds a NEW list) — never the
    // in-place `plusAssign` (which the intrinsic guard would refuse).
    const is_collection = switch (cur) {
        .List => |l| l.mutable and !modCountFrozenEval(l.mod_count),
        .Set => |st| st.mutable and !modCountFrozenEval(st.mod_count),
        .Map => |m| m.mutable,
        else => false,
    };
    const assign = compoundAssignMethod(cf.op);
    if (is_collection and assign != null) {
        switch (try host.callMember(allocator, &cur, assign.?, &.{v})) {
            .ok => {},
            .err => |e| return raiseStep(frame, e),
        }
        return .cont;
    }
    // A user instance may declare the in-place operator
    // (`operator fun plusAssign`); prefer it, mutating in place with no
    // write-back. Fall through to read-modify-write only when the type
    // has no `<op>Assign`.
    if (cur == .Instance and assign != null) {
        switch (try host.callMember(allocator, &cur, assign.?, &.{v})) {
            .ok => return .cont,
            .err => |e| switch (e) {
                .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
                else => return raiseStep(frame, e),
            },
        }
    }
    // Read-modify-write: compute `cur.<op>(value)` and reassign the
    // property. Scalars and strings combine via `applyBinop`; a user
    // type with only the binary operator (`operator fun plus`) routes
    // through `callMember`.
    const combined: Value = blk: {
        if (cur == .Instance) {
            if (operatorMethod(cf.op)) |method| {
                switch (try host.callMember(allocator, &cur, method, &.{v})) {
                    .ok => |rv| break :blk rv,
                    .err => |e| return raiseStep(frame, e),
                }
            }
        }
        // A read-only collection combines through its binary operator
        // intrinsic (`List + element`, `Map + Pair`), producing the fresh
        // value the property write-back stores.
        switch (cur) {
            .List, .Set, .Map => {
                if (operatorMethod(cf.op)) |method| {
                    switch (try host.callMember(allocator, &cur, method, &.{v})) {
                        .ok => |rv| break :blk rv,
                        .err => |e| return raiseStep(frame, e),
                    }
                }
            },
            else => {},
        }
        switch (try applyBinop(allocator, cf.op, &cur, &v)) {
            .ok => |rv| break :blk rv,
            .err => |e| return raiseStep(frame, e),
        }
    };
    // `combined` is an owned value (applyBinop / a user operator both
    // hand back a fresh reference); `setField` retains its own copy, so
    // drop ours now to balance.
    const r = try host.setField(allocator, &recv, name, combined);
    combined.release(allocator);
    switch (r) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCall(comptime H: type, allocator: Allocator, frame: *Frame, call: anytype, host: *H) Allocator.Error!Step {
    // Monomorphic fast path: a plain top-level user function (single
    // overload, has body, non-extension, no varargs / defaults / type
    // params / native binding) called positionally at exact arity needs
    // none of the overload re-resolution, extension-receiver handling,
    // reified-type binding, or redundant arg copying below. Dispatch it
    // straight to the body with the arg buffer transferred as params.
    if (comptime @hasDecl(H, "callFuncFast")) {
        if (call.type_args.len == 0 and argNamesAllNull(call.arg_names)) {
            if (frame.module.funcById(call.func)) |cf| {
                var plan = cf.fast_call;
                if (plan == 0) {
                    plan = host.fastCallPlan(frame.module, call.func);
                    @constCast(cf).fast_call = plan;
                }
                // `plan - 2` is the eligible arity; a positional, exact-arity
                // call dispatches straight to the body.
                if (plan >= 2 and plan - 2 == call.n_args) {
                    const buf = try readArgRun(allocator, frame, call.args, call.n_args);
                    const args_list: std.ArrayList(Value) = .{ .items = buf, .capacity = buf.len };
                    // The flat driver runs the body as a pushed activation in
                    // the same dispatch loop — no native recursion per call.
                    if (flatEnabled()) {
                        const composer_pushed = if (comptime @hasDecl(H, "flatPlainCallOpen"))
                            host.flatPlainCallOpen(cf, args_list.items)
                        else
                            false;
                        frame.flat_call = .{ .func = cf, .args = args_list, .composer_pushed = composer_pushed, .dst = call.dst };
                        return .flat_call;
                    }
                    switch (try host.callFuncFast(allocator, frame.module, call.func, args_list)) {
                        .ok => |result| try frame.write(call.dst, result),
                        .err => |e| return raiseStep(frame, e),
                    }
                    return .cont;
                }
            }
        }
    }
    var arg_values = try readArgRun(allocator, frame, call.args, call.n_args);
    defer allocator.free(arg_values);
    var names = try resolveArgNames(allocator, frame.module, call.arg_names);
    defer allocator.free(names);
    var ta: std.ArrayList([]const u8) = .empty;
    defer ta.deinit(allocator);
    for (call.type_args) |c| {
        try ta.append(allocator, constStr(frame.module, c) orelse "");
    }

    // Undispatched-start boundary (`__klio_co_startRootOrSuspended` under
    // an enclosing pump): run the block as a BARRIER activation on this
    // driver — a suspension parks the segment into the pump and this frame
    // continues with COROUTINE_SUSPENDED, with no native pump entry and no
    // frame snapshots per call.
    if (comptime @hasDecl(H, "prepareUndispatchedStartFlatCall")) {
        if (flatEnabled() and argNamesAllNull(call.arg_names)) {
            if (try host.prepareUndispatchedStartFlatCall(allocator, frame.module, call.func, arg_values)) |prep0| {
                var prep = prep0;
                prep.dst = call.dst;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }

    const bakedExt = struct {
        fn f(m: *const Module, id: FuncId) bool {
            const ff = m.funcById(id) orelse return false;
            const fp = ff.params;
            return fp.len > 0 and std.mem.eql(u8, fp[0].name, "this");
        }
    }.f;
    const baked_is_ext = bakedExt(frame.module, call.func);

    // Named-argument overload re-resolution. The lowerer baked the
    // call to a positional-arity heuristic FuncId; a named call may
    // really target a sibling overload (Kotlin resolves named calls
    // by parameter name). The receiver is reachable here, so an
    // implicit extension receiver can be supplied before dispatch.
    var eff_func = call.func;
    if (!call.exact) {
        var any_named = false;
        for (names) |n| {
            if (n != null) any_named = true;
        }
        if (any_named) {
            // The implicit extension receiver is in scope (a bare
            // call inside an extension/method body) but absent from
            // `args` only when the baked target is not itself an
            // extension — otherwise the lowerer already prepended it.
            const caller_this = frameThisParam(frame);
            const recv_external = caller_this != null and !baked_is_ext;
            const recv_val: ?*const Value = if (recv_external) blk: {
                const ct_idx = caller_this orelse break :blk null;
                break :blk &frame.params.items[ct_idx];
            } else null;
            const named_pick: ?FuncId = if (comptime @hasDecl(H, "pickNamedOverloadIdRecv"))
                host.pickNamedOverloadIdRecv(frame.module, call.func, arg_values, names, recv_external, recv_val)
            else
                host.pickNamedOverloadId(frame.module, call.func, arg_values, names, recv_external);
            if (named_pick) |picked| {
                eff_func = picked;
                const picked_is_ext = bakedExt(frame.module, picked);
                if (picked_is_ext and !baked_is_ext) {
                    if (caller_this) |ct_idx| {
                        // Supply the enclosing `this` as the leading
                        // (unnamed) receiver argument the chosen
                        // extension overload expects.
                        const recv = frame.params.items[ct_idx];
                        const na = try allocator.alloc(Value, arg_values.len + 1);
                        na[0] = recv;
                        @memcpy(na[1..], arg_values);
                        // `arg_values`/`names` are owned by the
                        // single `defer allocator.free(...)` above;
                        // free the original buffers before replacing
                        // the pointers so each is freed exactly once.
                        allocator.free(arg_values);
                        arg_values = na;
                        const nn = try allocator.alloc(?[]const u8, names.len + 1);
                        nn[0] = null;
                        @memcpy(nn[1..], names);
                        allocator.free(names);
                        names = nn;
                    }
                }
            }
        }
    }

    // Invoking an extension / member-extension function from
    // inside a method: keep the caller's instance `this`
    // reachable as the enclosing receiver.
    const callee_fn: ?*const Func = frame.module.funcById(eff_func);
    const callee_is_ext = callee_fn != null and callee_fn.?.params.len > 0 and
        std.mem.eql(u8, callee_fn.?.params[0].name, "this");
    var pushed_enclosing = false;
    if (callee_is_ext) {
        const caller_this = frameThisParam(frame);
        if (caller_this) |ct_idx| {
            const p = frame.params.items[ct_idx];
            if (p == .Instance) {
                const same = arg_values.len > 0 and arg_values[0] == .Instance and
                    ObjRef(InstanceData).ptrEq(p.Instance, arg_values[0].Instance);
                if (!same) {
                    // A member-extension's body has its declaring
                    // class's `this` in lexical scope (the
                    // dispatch receiver); a plain extension's body
                    // does not — the push is then dispatch
                    // visibility only.
                    if (callee_fn.?.kind == .member_extension) {
                        pushEnclosing(&frame.params.items[ct_idx]);
                    } else {
                        pushEnclosingAccess(&frame.params.items[ct_idx]);
                    }
                    pushed_enclosing = true;
                }
            }
        }
    }
    // Flat typed call: the resolved plain shape runs as a pushed
    // activation carrying its reified type-name bindings (restored at
    // teardown/park) and the call's type args for the boundary
    // transform. Special shapes decline to the recursive path.
    if (comptime @hasDecl(H, "prepareTypedFlatCall")) {
        if (flatEnabled() and ta.items.len > 0 and argNamesAllNull(call.arg_names)) {
            if (try host.prepareTypedFlatCall(allocator, frame.module, eff_func, arg_values, ta.items, call.exact)) |prep0| {
                var prep = prep0;
                prep.dst = call.dst;
                prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    if (call.trailing_lambda) {
        if (comptime @hasDecl(H, "setTrailingLambdaCall")) H.setTrailingLambdaCall(true);
    }
    const res = host.callFuncTyped(allocator, frame.module, eff_func, arg_values, names, ta.items, call.exact);
    if (call.trailing_lambda) {
        if (comptime @hasDecl(H, "setTrailingLambdaCall")) H.setTrailingLambdaCall(false);
    }
    if (pushed_enclosing) popEnclosing();
    switch (try res) {
        .ok => |result| try frame.write(call.dst, result),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCallValue(comptime H: type, allocator: Allocator, frame: *Frame, cv: anytype, host: *H) Allocator.Error!Step {
    const callee_v = frame.read(cv.callee);
    var arg_values_list: std.ArrayList(Value) = .empty;
    defer arg_values_list.deinit(allocator);
    {
        const tmp = try readArgRun(allocator, frame, cv.args, cv.n_args);
        defer allocator.free(tmp);
        try arg_values_list.appendSlice(allocator, tmp);
    }
    var names_list: std.ArrayList(?[]const u8) = .empty;
    defer names_list.deinit(allocator);
    {
        const tmp = try resolveArgNames(allocator, frame.module, cv.arg_names);
        defer allocator.free(tmp);
        try names_list.appendSlice(allocator, tmp);
    }
    // Receiver-typed lambda bare invocation: prepend the calling
    // frame's `this` when the closure expects a leading `this`.
    const caller_this = callerThisValue(frame);
    if (host.callableReceiverShape(&callee_v)) |shape| {
        if (shape.first_is_this and arg_values_list.items.len + 1 == shape.n_params) {
            if (caller_this) |ct| {
                try arg_values_list.insert(allocator, 0, ct);
                try names_list.insert(allocator, 0, null);
            }
        }
    }
    // Receiver lambda whose `this` arrives via a captured slot.
    if (host.closureNeedsThisCapture(&callee_v)) {
        if (caller_this) |ct| {
            host.overrideClosureThis(&callee_v, &ct);
        }
    }
    // No caller-`this` push here: a closure's body resolves bare
    // names against its creation-time receiver chain (lexical
    // scope); a receiver-typed lambda gets its subject through the
    // receiver-split / `this`-capture binding above. Pushing the
    // dynamic caller's `this` would hand the body a receiver it
    // never lexically saw.
    //
    // Flat closure dispatch: a plain positional exact-arity closure call
    // runs as a pushed activation in the flat driver. The host performs the
    // same resolution and binding the recursive path would, then hands back
    // the ready call instead of invoking the evaluator itself.
    if (comptime @hasDecl(H, "prepareClosureFlatCall")) {
        if (flatEnabled() and callee_v == .IrClosure and cv.type_args.len == 0 and argNamesAllNull(cv.arg_names)) {
            if (try host.prepareClosureFlatCall(allocator, &callee_v, arg_values_list.items)) |prep0| {
                var prep = prep0;
                prep.dst = cv.dst;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    const result = blk: {
        // Explicit call-site type args reach the host so an
        // unsigned element-type argument can coerce integral
        // literals before the intrinsic (`arrayOf<ULong>(1u)`).
        if (cv.type_args.len != 0) {
            var ta_buf: [4][]const u8 = undefined;
            const n_ta = @min(cv.type_args.len, ta_buf.len);
            for (cv.type_args[0..n_ta], ta_buf[0..n_ta]) |cid, *slot| {
                slot.* = constStr(frame.module, cid) orelse "";
            }
            break :blk host.callValueNamedTyped(allocator, &callee_v, arg_values_list.items, names_list.items, ta_buf[0..n_ta]);
        }
        break :blk host.callValueNamed(allocator, &callee_v, arg_values_list.items, names_list.items);
    };
    switch (try result) {
        .ok => |rv| {
            var out = rv;
            // A stdlib container creator dispatched as an
            // intrinsic value records its call-site type-argument
            // heads on the built container.
            if (cv.type_args.len != 0 and callee_v == .Intrinsic) {
                var ta: std.ArrayList([]const u8) = .empty;
                defer ta.deinit(allocator);
                for (cv.type_args) |c| {
                    try ta.append(allocator, constStr(frame.module, c) orelse "");
                }
                runtime.attachDeclaredElemTypes(callee_v.Intrinsic.fqn, ta.items, &out);
            }
            try frame.write(cv.dst, out);
        },
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCallSpread(comptime H: type, allocator: Allocator, frame: *Frame, cs: anytype, host: *H) Allocator.Error!Step {
    const callee_v = frame.read(cs.callee);
    var arg_values: std.ArrayList(Value) = .empty;
    defer arg_values.deinit(allocator);
    var effective_names: std.ArrayList(?[]const u8) = .empty;
    defer effective_names.deinit(allocator);
    var effective_params: std.ArrayList(u32) = .empty;
    defer effective_params.deinit(allocator);
    const in_names = try resolveArgNames(allocator, frame.module, cs.arg_names);
    defer allocator.free(in_names);
    for (cs.parts, 0..) |part, i| {
        const v = frame.read(part.reg);
        const name: ?[]const u8 = if (i < in_names.len) in_names[i] else null;
        const param: ?u32 = if (cs.arg_params) |params|
            (if (i < params.len) params[i] else null)
        else
            null;
        if (part.is_spread) {
            switch (try spreadItems(allocator, &v)) {
                .ok => |items| {
                    defer allocator.free(items);
                    for (items) |item| {
                        try arg_values.append(allocator, item);
                        try effective_names.append(allocator, null);
                        if (param) |index| try effective_params.append(allocator, index);
                    }
                },
                .err => |e| return raiseStep(frame, e),
            }
        } else {
            try arg_values.append(allocator, v);
            try effective_names.append(allocator, name);
            if (param) |index| try effective_params.append(allocator, index);
        }
    }
    if (cs.virtual_slot) |slot| {
        if (comptime !@hasDecl(H, "invokeVirtualMember")) {
            return raiseStep(frame, .{ .Type = "virtual CallSpread is unsupported by this host" });
        }
        if (cs.arg_params == null or effective_params.items.len != arg_values.items.len) {
            return raiseStep(frame, .{ .Type = "virtual CallSpread has an invalid parameter map" });
        }
        callee_v.retain();
        defer callee_v.release(allocator);
        const prev_tl = if (cs.trailing_lambda and comptime @hasDecl(H, "setTrailingMemberCall"))
            H.setTrailingMemberCall(true)
        else
            false;
        const result = host.invokeVirtualMember(
            allocator,
            &callee_v,
            slot,
            arg_values.items,
            &.{},
            effective_params.items,
        );
        if (cs.trailing_lambda) {
            if (comptime @hasDecl(H, "setTrailingMemberCall")) _ = H.setTrailingMemberCall(prev_tl);
        }
        switch (try result) {
            .ok => |rv| try frame.write(cs.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else if (cs.member) |mid| {
        const mname = constStr(frame.module, mid) orelse
            return raiseStep(frame, .{ .Type = "CallSpread: member not a string const" });
        // The receiver is borrowed for the call's whole duration;
        // pin it across dispatch (the body may drop other refs).
        callee_v.retain();
        defer callee_v.release(allocator);
        switch (try host.callMemberNamed(allocator, &callee_v, mname, arg_values.items, effective_names.items)) {
            .ok => |rv| try frame.write(cs.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else if (cs.candidates != null) {
        const name_id = cs.name orelse
            return raiseStep(frame, .{ .Type = "CallSpread: bounded call has no name" });
        const name = constStr(frame.module, name_id) orelse
            return raiseStep(frame, .{ .Type = "CallSpread: name not a string const" });
        const anchor_pkg = if (cs.anchor_pkg) |pkg_id|
            constStr(frame.module, pkg_id) orelse ""
        else
            "";
        const caller_file: ?ir.FileId = if (frame.cur_span) |sp| sp.file else null;
        const overload = switch (try host.callNamedOverload(
            allocator,
            frame.module,
            cs.candidates,
            name,
            arg_values.items,
            effective_names.items,
            null,
            false,
            frame.func.package,
            caller_file,
            anchor_pkg,
        )) {
            .ok => |maybe| maybe,
            .err => |e| return raiseStep(frame, e),
        };
        if (overload) |rv| {
            try frame.write(cs.dst, rv);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "unresolved spread overload `{s}`", .{name});
            return raiseStep(frame, .{ .Type = msg });
        }
    } else {
        switch (try host.callValueNamed(allocator, &callee_v, arg_values.items, effective_names.items)) {
            .ok => |rv| try frame.write(cs.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCallSuper(comptime H: type, allocator: Allocator, frame: *Frame, csup: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(csup.receiver);
    recv.retain();
    defer recv.release(allocator);
    const owner_str = constStr(frame.module, csup.owner_class) orelse
        return raiseStep(frame, .{ .Type = "CallSuper: owner not a string const" });
    const qual_str: ?[]const u8 = if (csup.qualifier) |id| constStr(frame.module, id) else null;
    const name_str = constStr(frame.module, csup.name) orelse
        return raiseStep(frame, .{ .Type = "CallSuper: name not a string const" });
    const arg_values = try readArgRun(allocator, frame, csup.args, csup.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, csup.arg_names);
    defer allocator.free(names);
    switch (try host.callSuper(allocator, &recv, owner_str, qual_str, name_str, arg_values, names)) {
        .ok => |rv| try frame.write(csup.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Execute a statically selected virtual slot. Unlike `CallMember`, this arm
/// has no name-based fallback: a missing slot is a link error in the program
/// image and is reported by the host.
noinline fn execArmCallVirtual(comptime H: type, allocator: Allocator, frame: *Frame, cv: anytype, host: *H) Allocator.Error!Step {
    if (comptime !@hasDecl(H, "invokeVirtualMember")) {
        return raiseStep(frame, .{ .Type = "CallVirtual is unsupported by this host" });
    }
    const recv = frame.read(cv.receiver);
    recv.retain();
    defer recv.release(allocator);
    const args = try readArgRun(allocator, frame, cv.args, cv.n_args);
    defer allocator.free(args);
    const names = try resolveArgNames(allocator, frame.module, cv.arg_names);
    defer allocator.free(names);
    const prev_tl = if (cv.trailing_lambda and comptime @hasDecl(H, "setTrailingMemberCall"))
        H.setTrailingMemberCall(true)
    else
        false;
    const result = host.invokeVirtualMember(allocator, &recv, cv.slot, args, names, cv.arg_params);
    if (cv.trailing_lambda) {
        if (comptime @hasDecl(H, "setTrailingMemberCall")) _ = H.setTrailingMemberCall(prev_tl);
    }
    switch (try result) {
        .ok => |value| try frame.write(cv.dst, value),
        .err => |err| return raiseStep(frame, err),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCallMember(comptime H: type, allocator: Allocator, frame: *Frame, cm: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(cm.receiver);
    // Complete lowering evidence selected this declaration. Execute that
    // identity before representation-specific member fast paths; an invalid
    // identity is an image/link error, never permission to reinterpret the
    // call through name-based dispatch.
    if (cm.resolved) |fid| {
        if (comptime @hasDecl(H, "invokeResolvedMember")) {
            recv.retain();
            defer recv.release(allocator);
            var dispatch_recv: ?Value = if (cm.dispatch_receiver) |reg|
                frame.read(reg)
            else
                null;
            if (dispatch_recv) |value| value.retain();
            defer if (dispatch_recv) |value| value.release(allocator);
            const ra = try readArgRun(allocator, frame, cm.args, cm.n_args);
            defer allocator.free(ra);
            const dispatch_ptr: ?*const Value = if (dispatch_recv) |*value|
                value
            else
                null;
            switch (try host.invokeResolvedMember(
                allocator,
                dispatch_ptr,
                &recv,
                fid,
                ra,
            )) {
                .ok => |rv| {
                    try frame.write(cm.dst, rv);
                    return .cont;
                },
                .err => |e| return raiseStep(frame, e),
            }
        }
        return raiseStep(frame, .{ .Type = "resolved member calls are unsupported by this host" });
    }
    if (fastSubscript(allocator, frame, cm)) |rv| {
        try frame.write(cm.dst, rv);
        return .cont;
    }
    // Fast path: a range iterator's `hasNext()`/`next()`. The universal
    // `for (x in range)` desugaring calls these once per element; the
    // inline handler avoids the member-dispatch hashmap probes that
    // otherwise dominate tight integer loops.
    if (recv == .RangeIter) {
        if (constStr(frame.module, cm.name)) |nm| {
            if (rangeIterFast(allocator, &recv, nm, cm.n_args)) |r| {
                switch (r) {
                    .ok => |rv| {
                        try frame.write(cm.dst, rv);
                        return .cont;
                    },
                    .err => |e| return raiseStep(frame, e),
                }
            }
        }
    }
    // A method borrows its receiver for the call's whole duration.
    // Pin it: the dispatched body may, via the coroutine machinery,
    // drop every other reference to the receiver (e.g. a job
    // completing inside `runBlocking.joinBlocking`), and the register
    // read is only a borrow. Retain across the dispatch so the
    // receiver outlives the call regardless. No-op under the arena.
    recv.retain();
    defer recv.release(allocator);
    const name_str = constStr(frame.module, cm.name) orelse
        return raiseStep(frame, .{ .Type = "CallMember: name not a string const" });
    const arg_values = try readArgRun(allocator, frame, cm.args, cm.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cm.arg_names);
    defer allocator.free(names);
    // Keep the caller's instance `this` reachable while the
    // `recv.member(...)` dispatch resolves (the member-extension
    // visibility filter consults the chain); the callee's own
    // lexical scope is its dispatch receiver, so the entry is
    // access-only.
    var pushed_enclosing = false;
    if (frame.params.items.len > 0 and frame.params.items[0] == .Instance) {
        const pi = frame.params.items[0].Instance;
        const same = recv == .Instance and ObjRef(InstanceData).ptrEq(pi, recv.Instance);
        if (!same) {
            pushEnclosingAccess(&frame.params.items[0]);
            pushed_enclosing = true;
        }
    }
    const static_recv: ?[]const u8 = if (cm.static_recv) |sid| constStr(frame.module, sid) else null;
    const declared_recv: ?[]const u8 = if (cm.declared_recv) |did| constStr(frame.module, did) else null;
    // Flat member dispatch: a previously-resolved user method (or cached
    // top-level extension) at the fully-applied no-vararg shape runs as a
    // pushed activation. The host consults the same caches the recursive
    // ladder's entry consults; anything else falls through to the ladder.
    if (comptime @hasDecl(H, "prepareMemberFlatCall")) {
        if (flatEnabled() and argNamesAllNull(cm.arg_names)) {
            if (try host.prepareMemberFlatCall(allocator, &recv, name_str, arg_values, static_recv, declared_recv, true)) |prep0| {
                var prep = prep0;
                prep.dst = cm.dst;
                prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                frame.flat_call = prep;
                return .flat_call;
            }
        }
    }
    const prev_tl = if (cm.trailing_lambda and comptime @hasDecl(H, "setTrailingMemberCall"))
        H.setTrailingMemberCall(true)
    else
        false;
    const tl_touched = cm.trailing_lambda;
    const res = if (static_recv) |sname|
        host.callMemberNamedStatic(allocator, &recv, name_str, arg_values, names, sname)
    else if (declared_recv != null)
        host.callMemberNamedDeclared(allocator, &recv, name_str, arg_values, names, declared_recv)
    else
        host.callMemberNamed(allocator, &recv, name_str, arg_values, names);
    if (tl_touched) {
        if (comptime @hasDecl(H, "setTrailingMemberCall")) _ = H.setTrailingMemberCall(prev_tl);
    }
    if (pushed_enclosing) popEnclosing();
    switch (try res) {
        .ok => |rv| try frame.write(cm.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCallMemberOrValue(comptime H: type, allocator: Allocator, frame: *Frame, cmv: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(cmv.receiver);
    recv.retain();
    defer recv.release(allocator);
    const user_args = try readArgRun(allocator, frame, cmv.args, cmv.n_args);
    defer allocator.free(user_args);
    const names = try resolveArgNames(allocator, frame.module, cmv.arg_names);
    defer allocator.free(names);
    const name_str = constStr(frame.module, cmv.name) orelse
        return raiseStep(frame, .{ .Type = "CallMemberOrValue: name not a string const" });
    var fb = frame.read(cmv.fallback);
    // A boxed capture holds the callable in a cell (a captured local fn's
    // shared binding); classify and invoke the CONTENT — the sibling
    // CallValueOrMember arm unwraps identically. Without this a captured
    // `fun MockViewValidator.Composition()` fallback read as `.Cell`,
    // was judged non-invocable, and the member miss surfaced.
    if (fb == .Cell) {
        const cg = fb.Cell.borrow();
        fb = cg.get().*;
        cg.deinit();
    }
    if (nuTraceWant() != null and std.mem.eql(u8, name_str, "placementBlock")) {
        const rcls: []const u8 = if (recv == .Instance) blk: {
            const g = recv.Instance.borrow();
            const cg = g.get().class.borrow();
            const n = cg.get().name;
            cg.deinit();
            g.deinit();
            break :blk n;
        } else @tagName(recv);
        std.debug.print("[pb] in={s}#{d} recv={s} fb={s}\n", .{ frame.func.name, frame.func.id.int(), rcls, @tagName(fb) });
    }
    // The local/captured fallback only wins when the receiver has no
    // such member AND the fallback is actually invocable (a function
    // value or callable reference). A same-named non-callable local
    // (e.g. a captured `info` next to `logger.info(...)`) must not
    // shadow the real member.
    const fb_invocable = switch (fb) {
        .IrClosure, .Function, .Intrinsic, .BoundMethod, .BoundUserMethod, .PropertyRef => true,
        // A class value is its constructor (`::Char` bound to an
        // `Int.() -> Char` param): invocable, receiver becomes the
        // first positional argument below.
        .Class => true,
        // A bound/unbound callable reference (`Long::toByte`,
        // `recv::method`) is a `$bound_ref$<name>` synth instance: it
        // is invocable, so `recv.refParam()` invokes the reference
        // with `recv` as its receiver rather than dispatching a member
        // named `refParam` on `recv`.
        .Instance => isBoundRefInstance(&fb) or host.hostHasMember(&fb, "invoke") or host.callableReceiverShape(&fb) != null,
        else => false,
    };
    // A local callable whose declared arity provably cannot take
    // the supplied args is not the primary candidate — Kotlin
    // resolves the member/extension instead
    // (`subList(..).sortDescending()` next to a
    // `sortDescending: TArray.(Int, Int) -> Unit` param must
    // dispatch the extension, not Null-pad the local). The proof
    // is conservative (closure shapes without a DeclSig can hide
    // defaults), so a canonical member MISS still falls back to
    // invoking the local.
    const fb_misfit = fb_invocable and
        (host.callableAcceptsCall(&fb, &recv, user_args, names) orelse true) == false;
    // A receiver whose STATIC type is an unbounded type parameter has no
    // members to shadow the local: Kotlin compiles the body once against
    // the bound (`Any?`), so `receiver.block()` inside
    // `fun <T, R> with(receiver: T, block: T.() -> R)` always binds the
    // `block` PARAMETER. Consulting the runtime class instead let a
    // same-named member hijack it — `with(node) { … }` on a node owning a
    // `block` field ran that field and skipped the whole with-body.
    const members_visible = !cmv.recv_erased and host.hostHasMember(&recv, name_str);
    if (fb_invocable and (!fb_misfit or cmv.recv_erased) and !members_visible) {
        orAudit("CallMemberOrValue", name_str, "value", -1, &recv);
        // Flat dispatch for the closure fallback: the shape-known route is
        // a plain value call, the shape-unknown route the with-this bind;
        // the declared-receiver (`fallback_takes_receiver`) route keeps
        // the recursive path.
        if (comptime @hasDecl(H, "prepareClosureWithThisFlatCall")) {
            if (flatEnabled() and fb == .IrClosure and !cmv.fallback_takes_receiver and argNamesAllNull(cmv.arg_names)) {
                const maybe = if (cmv.fallback_receiver_shape_known)
                    try host.prepareClosureFlatCall(allocator, &fb, user_args)
                else
                    try host.prepareClosureWithThisFlatCall(allocator, &fb, &recv, user_args);
                if (maybe) |prep0| {
                    var prep = prep0;
                    prep.dst = cmv.dst;
                    frame.flat_call = prep;
                    return .flat_call;
                }
            }
        }
        if (fb == .Class) {
            // Constructors take no receiver: `65.f()` with
            // `f = ::Char` is `Char(65)`.
            const adapted = try allocator.alloc(Value, user_args.len + 1);
            defer allocator.free(adapted);
            adapted[0] = recv;
            @memcpy(adapted[1..], user_args);
            const nn = try allocator.alloc(?[]const u8, names.len + 1);
            defer allocator.free(nn);
            nn[0] = null;
            @memcpy(nn[1..], names);
            switch (try host.callValueNamed(allocator, &fb, adapted, nn)) {
                .ok => |rv| try frame.write(cmv.dst, rv),
                .err => |e| return raiseStep(frame, e),
            }
        } else switch (if (cmv.fallback_takes_receiver)
            try host.callValueWithThisExact(allocator, &fb, &recv, user_args, names)
        else if (cmv.fallback_receiver_shape_known)
            try host.callValueNamed(allocator, &fb, user_args, names)
        else
            try host.callValueWithThis(allocator, &fb, &recv, user_args, names)) {
            .ok => |rv| try frame.write(cmv.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else {
        orAudit("CallMemberOrValue", name_str, "member", 0, &recv);
        const r = try host.callMemberNamed(allocator, &recv, name_str, user_args, names);
        const member_missed = r == .err and r.err == .Unimplemented and
            std.mem.indexOf(u8, r.err.Unimplemented, "Vm::") != null;
        // The member exists by name but no overload serves this call
        // (arity/type). When the same-named local is an invocable
        // function value, it is the intended target — Kotlin resolves
        // `up.update()` to a `Up.() -> Unit` param over the 2-arg member
        // `update(value, block)`. Discard the member miss and invoke the
        // value (its receiver is the call receiver).
        if (member_missed and fb_invocable) {
            freeDispatchMissMsg(allocator, r.err.Unimplemented);
            orAudit("CallMemberOrValue", name_str, "value_after_miss", -1, &recv);
            if (fb == .Class) {
                const adapted = try allocator.alloc(Value, user_args.len + 1);
                defer allocator.free(adapted);
                adapted[0] = recv;
                @memcpy(adapted[1..], user_args);
                const nn = try allocator.alloc(?[]const u8, names.len + 1);
                defer allocator.free(nn);
                nn[0] = null;
                @memcpy(nn[1..], names);
                switch (try host.callValueNamed(allocator, &fb, adapted, nn)) {
                    .ok => |rv| try frame.write(cmv.dst, rv),
                    .err => |e| return raiseStep(frame, e),
                }
            } else switch (if (cmv.fallback_takes_receiver)
                try host.callValueWithThisExact(allocator, &fb, &recv, user_args, names)
            else if (cmv.fallback_receiver_shape_known)
                try host.callValueNamed(allocator, &fb, user_args, names)
            else
                try host.callValueWithThis(allocator, &fb, &recv, user_args, names)) {
                .ok => |rv| try frame.write(cmv.dst, rv),
                .err => |e| return raiseStep(frame, e),
            }
        } else switch (r) {
            .ok => |rv| try frame.write(cmv.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Whether a value can serve as the callee of a call: closures, function
/// references, intrinsics, classes (constructor call), bound references, and
/// instances whose class hierarchy declares `invoke`.
fn valueInvocable(module: *const Module, callee_v: Value) bool {
    return switch (callee_v) {
        .Function, .Intrinsic, .IrClosure, .BoundMethod, .BoundUserMethod => true,
        // A class value invoked bare is a constructor call.
        .Class, .BoundInnerClass, .PropertyRef => true,
        .Instance => |i| blk: {
            {
                const g = i.borrow();
                defer g.deinit();
                // A bound member/constructor reference synth
                // (`val lit = Expr::Lit`) is a callable value.
                if (g.get().get("__bound_name__") != null) break :blk true;
            }
            const g = i.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            const cls = cg.get().name;
            if (module.registry.hierarchy_methods.get(cls)) |mset| {
                break :blk mset.contains("invoke");
            }
            break :blk false;
        },
        else => false,
    };
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCallValueOrMember(comptime H: type, allocator: Allocator, frame: *Frame, cvm: anytype, host: *H) Allocator.Error!Step {
    var callee_v = frame.read(cvm.callee);
    // A boxed capture holds the callable in a cell; classify the
    // CONTENT (a captured local fn in a `var` slot is invokable).
    if (callee_v == .Cell) {
        const cg = callee_v.Cell.borrow();
        callee_v = cg.get().*;
        cg.deinit();
    }
    const arg_values = try readArgRun(allocator, frame, cvm.args, cvm.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cvm.arg_names);
    defer allocator.free(names);
    const invocable = valueInvocable(frame.module, callee_v);
    // A callable whose DECLARED params definitely refute the runtime
    // args is not the target — Kotlin resolved the call to the
    // same-named enclosing member overload; fall to the member arm.
    const refuted = invocable and (comptime @hasDecl(H, "closureParamsDisproven")) and
        host.closureParamsDisproven(&callee_v, arg_values);
    if (invocable and !refuted) {
        if (orAuditOn()) {
            const name_str = constStr(frame.module, cvm.name) orelse "?";
            orAudit("CallValueOrMember", name_str, "value", -1, null);
        }
        // The member-fallback receiver is also the call site's
        // innermost implicit receiver; a receiver-typed closure
        // invoked bare binds it as dispatch context.
        const recv_ctx = frame.read(cvm.this_recv);
        // Flat dispatch: the plain closure shapes run as a pushed
        // activation; the host mirrors `callValueNamedRecvCtx`'s routing
        // and declines every special shape to the recursive path.
        if (comptime @hasDecl(H, "prepareValueRecvCtxFlatCall")) {
            if (flatEnabled() and callee_v == .IrClosure and argNamesAllNull(cvm.arg_names)) {
                if (try host.prepareValueRecvCtxFlatCall(allocator, &callee_v, &recv_ctx, arg_values)) |prep0| {
                    var prep = prep0;
                    prep.dst = cvm.dst;
                    frame.flat_call = prep;
                    return .flat_call;
                }
            }
        }
        const r = if (comptime @hasDecl(H, "callValueNamedRecvCtx"))
            try host.callValueNamedRecvCtx(allocator, &callee_v, &recv_ctx, arg_values, names)
        else
            try host.callValueNamed(allocator, &callee_v, arg_values, names);
        switch (r) {
            .ok => |rv| try frame.write(cvm.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    } else {
        const recv = frame.read(cvm.this_recv);
        const name_str = constStr(frame.module, cvm.name) orelse
            return raiseStep(frame, .{ .Type = "CallValueOrMember: name not a string const" });
        orAudit("CallValueOrMember", name_str, "member", 0, &recv);
        switch (try host.callMemberNamed(allocator, &recv, name_str, arg_values, names)) {
            .ok => |rv| try frame.write(cvm.dst, rv),
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmNewInstance(comptime H: type, allocator: Allocator, frame: *Frame, ni: anytype, host: *H) Allocator.Error!Step {
    const arg_values = try readArgRun(allocator, frame, ni.args, ni.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, ni.arg_names);
    defer allocator.free(names);
    // A bare `Inner(args)` inside a member of the enclosing
    // class is `this@Outer.Inner(args)`: pass the frame's own
    // `this` — a method's `this` param or a lambda's `this`
    // capture — as the outer hint for the construction dispatch.
    // The host's outer selection is class-keyed, so a receiver
    // lambda whose `this` slot was overridden with an unrelated
    // subject falls through to the enclosing-receiver chain.
    var outer_hint: ?Value = callerThisValue(frame);
    const hint_ptr: ?*const Value = if (outer_hint) |*h| h else null;
    const result = switch (try host.newInstanceNamed(allocator, ni.class, arg_values, names, hint_ptr)) {
        .ok => |v| v,
        .err => |e| return raiseStep(frame, e),
    };
    if (result == .Instance) {
        const inst_ref = result.Instance;
        const needs_outer = blk: {
            const g = inst_ref.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().is_inner and g.get().outer == null;
        };
        if (needs_outer and outer_hint != null) {
            // The instance's `outer` is an owned field (its teardown
            // releases it); `outer_hint` is the caller's borrow, so
            // retain before storing. No-op under the arena.
            outer_hint.?.retain();
            const g = inst_ref.borrowMut();
            defer g.deinit();
            g.get().outer = outer_hint.?;
        }
    }
    try frame.write(ni.dst, result);
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmInstanceOf(comptime H: type, allocator: Allocator, frame: *Frame, io: anytype, host: *H) Allocator.Error!Step {
    _ = allocator;
    const v = frame.read(io.src);
    const is = host.instanceOf(&v, io.ty);
    try frame.write(io.dst, .{ .Bool = is });
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCtxScope(comptime H: type, allocator: Allocator, frame: *Frame, cs: anytype, host: *H) Allocator.Error!Step {
    if (comptime !@hasDecl(H, "ctxPush")) {
        try frame.write(cs.dst, .Null);
        return .cont;
    }
    const mark = host.ctxStackLen();
    var i: u32 = 0;
    while (i < cs.n_ctx) : (i += 1) {
        const v = frame.read(Reg.from(cs.ctx_args.int() + i));
        try host.ctxPush(v);
    }
    var block = frame.read(cs.block);
    const res = host.callValue(allocator, &block, &.{});
    host.ctxStackTruncate(mark);
    switch (try res) {
        .ok => |rv| try frame.write(cs.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCtxCall(comptime H: type, allocator: Allocator, frame: *Frame, cc: anytype, host: *H) Allocator.Error!Step {
    if (comptime !@hasDecl(H, "ctxPush")) {
        try frame.write(cc.dst, .Null);
        return .cont;
    }
    const mark = host.ctxStackLen();
    var i: u32 = 0;
    while (i < cc.n_ctx) : (i += 1) {
        const v = frame.read(Reg.from(cc.args.int() + i));
        try host.ctxPush(v);
    }
    const call_n = cc.n_args - cc.n_ctx;
    const call_args = try readArgRun(allocator, frame, Reg.from(cc.args.int() + cc.n_ctx), call_n);
    defer allocator.free(call_args);
    var callee_v = frame.read(cc.callee);
    const res = host.callValue(allocator, &callee_v, call_args);
    host.ctxStackTruncate(mark);
    switch (try res) {
        .ok => |rv| try frame.write(cc.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmCast(comptime H: type, allocator: Allocator, frame: *Frame, cast: anytype, host: *H) Allocator.Error!Step {
    const v = frame.read(cast.src);
    if (host.instanceOf(&v, cast.ty)) {
        v.retain();
        try frame.write(cast.dst, v);
    } else if (typeParamCastPasses(H, frame, cast.ty, host)) {
        v.retain();
        try frame.write(cast.dst, v);
    } else if (cast.safe) {
        try frame.write(cast.dst, .Null);
    } else {
        // A failed cast raises without passing through the
        // `Throw` terminator, so trace it here too or
        // KLIO_THROW_TRACE never sees ClassCastExceptions.
        if (envVarSet("KLIO_THROW_TRACE")) {
            std.debug.print("[throw-trace] from fn {s} (fqn={s}): ClassCastException cast to {s} (value tag {s})\n", .{ frame.func.name, frame.func.fqn, cast.ty.name, @tagName(v) });
        }
        const msg = try std.fmt.allocPrint(allocator, "cast to `{s}` failed", .{cast.ty.name});
        const exc = Value{ .Exception = .{
            .fqn = try runtime.strInit(allocator, "kotlin.ClassCastException"),
            .message = try runtime.strInitOwned(allocator, msg),
            .cause = null,
        } };
        return raiseStep(frame, .{ .Throw = exc });
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmLambda(comptime H: type, allocator: Allocator, frame: *Frame, lam: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, lam.captures);
    defer allocator.free(cap_values);
    switch (try host.buildClosure(allocator, frame.module, lam.body_func, cap_values)) {
        .ok => |v| try frame.write(lam.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmAstLambda(comptime H: type, allocator: Allocator, frame: *Frame, al: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, al.captures);
    defer allocator.free(cap_values);
    switch (try host.buildAstLambdaWithFlagFuncid(allocator, frame.module, al.params, &al.body_ast, al.captured_names, cap_values, al.absorb_return, al.body_func)) {
        .ok => |v| try frame.write(al.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmRegisterClass(comptime H: type, allocator: Allocator, frame: *Frame, rc: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, rc.captures);
    defer allocator.free(cap_values);
    switch (try host.registerClassCaptured(allocator, rc.class.get(), rc.captured_names, cap_values)) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    // Bind the declaration name to the registered class value so a call
    // to the local class in scope constructs it (shadowing a same-named
    // top-level function). Only hosts that model a class table produce a
    // value; others leave the slot at its default.
    if (rc.dst) |d| {
        if (@hasDecl(H, "localClassValue")) {
            switch (try host.localClassValue(allocator, rc.class.get().name.name)) {
                .ok => |maybe| if (maybe) |v| try frame.write(d, v),
                .err => |e| return raiseStep(frame, e),
            }
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmBuildObject(comptime H: type, allocator: Allocator, frame: *Frame, bobj: anytype, host: *H) Allocator.Error!Step {
    const cap_values = try readRegSlice(allocator, frame, bobj.captures);
    defer allocator.free(cap_values);
    switch (try host.buildObject(allocator, bobj.ast.get(), bobj.captured_names, cap_values, bobj.scope_renames, bobj.scope_classes)) {
        .ok => |v| try frame.write(bobj.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmStoreToThisOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, stg: anytype, host: *H) Allocator.Error!Step {
    const name_str = constStr(frame.module, stg.name) orelse
        return raiseStep(frame, .{ .Type = "StoreToThisOrGlobal: name not a string const" });
    const v = frame.read(stg.value);
    // Kotlin scoping for a bare-name write mirrors the read side:
    // the innermost implicit receiver owning a *property* of this
    // name takes the write; only when no receiver owns one does
    // the write land on the top-level binding (pinned by the
    // `bare_write_*` kotlinc parity fixtures). An assignment LHS
    // can only resolve to a property or variable — a member
    // *function* of the name never captures the write.
    var routed = false;
    {
        // `consult_param = true`: the implicit receiver owning the
        // written property may be the frame's `this` *parameter* (a
        // bare `receiveType = …` inside an interface/extension method),
        // not a capture — matching the read side. A bare write also
        // resolves to an extension-property *setter* (`var T.x set(…)`)
        // declared on the receiver's type or a supertype, not only a
        // stored member; `setField` dispatches both.
        const cands = try implicitCandidatesAlloc(H, allocator, frame, stg.this_idx, true, host, name_str, null);
        defer allocator.free(cands);
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        for (cands) |c| {
            if (c.v != .Instance) continue;
            if (!host.hostHasProperty(&c.v, name_str) and
                !host.hostHasExtPropSetter(allocator, &c.v, name_str)) continue;
            orAudit("StoreToThisOrGlobal", name_str, "member", c.depth, &c.v);
            switch (try host.setField(allocator, &c.v, name_str, v)) {
                .ok => {},
                .err => |e| return raiseStep(frame, e),
            }
            routed = true;
            break;
        }
    }
    if (!routed) {
        orAudit("StoreToThisOrGlobal", name_str, "global", -1, null);
        switch (try host.storeGlobal(allocator, name_str, v)) {
            .ok => {},
            .err => |e| return raiseStep(frame, e),
        }
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmLoadFromThisOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, lt: anytype, host: *H) Allocator.Error!Step {
    const name_str = constStr(frame.module, lt.name) orelse
        return raiseStep(frame, .{ .Type = "LoadFromThisOrGlobal: name not a string const" });
    var resolved: ?Value = null;
    {
        // `consult_param = true`: in a method / extension body the
        // implicit receiver is the frame's `this` *parameter*, not
        // a capture slot.
        const cands = try implicitCandidatesAlloc(H, allocator, frame, lt.this_idx, true, host, stripScopeGetter(name_str), null);
        defer allocator.free(cands);
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        // Per-candidate probes are member-only (`getMemberField`):
        // a candidate must not "resolve" a global or an outer
        // receiver's member and shadow a receiver further out —
        // the walk's own order decides precedence, and the global
        // tiers below decide the fallback. A probe hit is a hit
        // even when the member's value IS `Unit` (`var u: Unit`):
        // the strict probe reports misses as errors, never as a
        // spurious `Unit`.
        for (cands) |c| {
            switch (try host.getMemberField(allocator, &c.v, name_str)) {
                .ok => |v| {
                    orAudit("LoadFromThisOrGlobal", name_str, "member", c.depth, &c.v);
                    resolved = v;
                    break;
                },
                // Only the dispatch-miss sentinel (`Unimplemented`)
                // means "this candidate has no such member" — discard
                // its `Vm::get_field` message and walk to the next
                // candidate / global tier. Any other error is a member
                // that resolved and whose accessor actually ran: a
                // throw from a delegated property's `getValue`
                // (`NoSuchElementException` on a missing map key), a
                // `CalleeFailed`, a `StackOverflow`. Those propagate —
                // swallowing them would mask the throw and fall through
                // to a spurious `unresolved global`.
                .err => |e| {
                    if (e == .Unimplemented) {
                        freeMissErr(allocator, e);
                    } else {
                        return raiseStep(frame, e);
                    }
                },
            }
        }
    }
    // The scope-qualified form carries the lexical owner only for
    // the getter reads above; the global fallback uses the bare
    // name.
    const bare_name = stripScopeGetter(name_str);
    // A lowering-resolved identity binds that exact declaration;
    // the name string remains the unresolved-shape fallback. A
    // runtime-scoped shadowing capture (a closed-over callable
    // materialized as a scoped-global layer) outranks the static
    // pick, mirroring the call form's shadow gate.
    const by_id: ?Value = if (resolved == null and (lt.func != null or lt.class != null) and
        !host.isShadowingCapture(bare_name))
        host.lookupGlobalById(allocator, lt.func, lt.class, false)
    else
        null;
    var v: Value = undefined;
    if (resolved) |rv| {
        v = rv;
    } else if (by_id) |gv| {
        orAudit("LoadFromThisOrGlobal", bare_name, "global_id", -1, null);
        v = gv;
    } else {
        switch (try host.lookupGlobalThrowing(allocator, bare_name)) {
            .ok => |maybe| {
                if (maybe) |gv| {
                    orAudit("LoadFromThisOrGlobal", bare_name, "global", -1, null);
                    v = gv;
                } else {
                    // A top-level `val` declared with only a custom getter
                    // has no global binding; re-run its 0-arg getter, as
                    // the plain LoadGlobal tail does — a receiver-context
                    // read of `currentRecomposeScope` must resolve exactly
                    // like a top-level one.
                    if (comptime @hasDecl(H, "callFunc")) {
                        if (frame.module.registry.top_level_prop_getters.get(bare_name)) |getter_fid| {
                            switch (try host.callFunc(allocator, frame.module, getter_fid, &.{})) {
                                .ok => |gv2| {
                                    orAudit("LoadFromThisOrGlobal", bare_name, "toplevel_getter", -1, null);
                                    try frame.write(lt.dst, gv2);
                                    return .cont;
                                },
                                .err => |e| return raiseStep(frame, e),
                            }
                        }
                    }
                    const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{bare_name});
                    if (missTraceWant()) |w| {
                        if (std.mem.eql(u8, w, bare_name)) {
                            std.debug.print("[ltg-tail] name={s} raw={s} func={?} class={?} shadow={} span={d}:{d} in_fn={s}\n", .{
                                bare_name,
                                name_str,
                                if (lt.func) |f| f.int() else null,
                                if (lt.class) |c| c.int() else null,
                                host.isShadowingCapture(bare_name),
                                if (frame.cur_span) |sp| sp.file.int() else 0,
                                if (frame.cur_span) |sp| sp.start else 0,
                                frame.func.name,
                            });
                        }
                    }
                    dumpFrameChainForDiag();
                    return raiseStep(frame, .{ .Unbound = msg });
                }
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // A boxed capture surfaced by the member walk (an anon-object
    // method's captured outer `var` lands in the instance's capture
    // env as a shared Cell) reads through the cell.
    if (v == .Cell) {
        const cg = v.Cell.borrow();
        v = cg.get().*;
        cg.deinit();
    }
    v.retain();
    try frame.write(lt.dst, v);
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmIndex(comptime H: type, allocator: Allocator, frame: *Frame, ix: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(ix.receiver);
    const i = frame.read(ix.index);
    if (fastIndexGet(&recv, &i)) |rv| {
        try frame.write(ix.dst, rv);
        return .cont;
    }
    switch (try host.callMember(allocator, &recv, "get", &.{i})) {
        .ok => |rv| try frame.write(ix.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmIndexSet(comptime H: type, allocator: Allocator, frame: *Frame, ixs: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(ixs.receiver);
    const i = frame.read(ixs.index);
    const v = frame.read(ixs.value);
    if (fastIndexSet(allocator, &recv, &i, v)) {
        return .cont;
    }
    switch (try host.callMember(allocator, &recv, "set", &.{ i, v })) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmNewList(comptime H: type, allocator: Allocator, frame: *Frame, nl: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const items = try readArgRun(allocator, frame, nl.args, nl.n_args);
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(allocator, items);
    allocator.free(items);
    // The list owns one reference to each element (its teardown
    // releases them); `readArgRun` handed back borrows of the source
    // registers, so retain each. No-op under the arena fast path.
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    try frame.write(nl.dst, .{ .List = .{
        .items = try ValueList.init(allocator, list),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    } });
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmQualifiedThis(comptime H: type, allocator: Allocator, frame: *Frame, qt: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(qt.receiver);
    const qual_str = constStr(frame.module, qt.qualifier) orelse
        return raiseStep(frame, .{ .Type = "QualifiedThis: qualifier not a string const" });
    switch (try host.qualifiedThis(allocator, &recv, qual_str)) {
        .ok => |v| {
            v.retain();
            try frame.write(qt.dst, v);
        },
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmPropertyRef(comptime H: type, allocator: Allocator, frame: *Frame, pr: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const name_str = constStr(frame.module, pr.name) orelse
        return raiseStep(frame, .{ .Type = "PropertyRef: name not a string const" });
    try frame.write(pr.dst, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name_str) } });
    return .cont;
}

/// Outlined `execInst` arm — see `execInst`.
noinline fn execArmMemberRef(comptime H: type, allocator: Allocator, frame: *Frame, mr: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(mr.receiver);
    const name_str = constStr(frame.module, mr.name) orelse
        return raiseStep(frame, .{ .Type = "MemberRef: name not a string const" });
    const result = if (mr.func) |func|
        if (comptime @hasDecl(H, "memberRefExact"))
            try host.memberRefExact(allocator, &recv, name_str, func)
        else
            try host.memberRef(allocator, &recv, name_str)
    else
        try host.memberRef(allocator, &recv, name_str);
    switch (result) {
        .ok => |v| try frame.write(mr.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// `name(args)` where lowering could not classify the bare callee as
/// member-vs-global. Mirrors Kotlin's call resolution for an implicit
/// receiver: each candidate receiver is searched innermost-first, members
/// and applicable extensions per receiver (pinned by the
/// `inner_ext_over_outer_member` kotlinc parity fixture), then the
/// top-level tiers — runtime overload selection, the lowering-resolved
/// constructor class, the global by name — and only then an error.
/// Free a discarded member-dispatch-miss message (the host allocates a
/// `Vm::call_member …` string on a total miss; the resolver discards it while
/// walking to the next candidate / a global). Recognizable by its prefix, so a
/// static `.Unimplemented` literal is never freed. No-op unless a freeing
/// backend is active.
fn freeDispatchMissMsg(allocator: Allocator, msg: []const u8) void {
    if (!runtime.freeScratch()) return;
    // Every host dispatch-miss message is `allocPrint`-built with a `Vm::`
    // prefix (`Vm::call_member`, `Vm::get_field`, …); static `.Unimplemented`
    // literals never carry that prefix, so this frees only owned messages.
    if (std.mem.startsWith(u8, msg, "Vm::")) allocator.free(msg);
}

/// Free a discarded host dispatch-miss `EvalError` (the resolver tries many
/// receiver candidates / fallback tiers and drops each miss). Only the
/// `Unimplemented` arm carries an owned message.
fn freeMissErr(allocator: Allocator, e: EvalError) void {
    if (e == .Unimplemented) freeDispatchMissMsg(allocator, e.Unimplemented);
}

fn execCallMemberOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, cmg: anytype, host: *H) Allocator.Error!Step {
    const name_str = constStr(frame.module, cmg.name) orelse
        return raiseStep(frame, .{ .Type = "CallMemberOrGlobal: name not a string const" });
    const prev_tl = if (comptime @hasDecl(H, "setTrailingMemberCall"))
        H.setTrailingMemberCall(cmg.trailing_lambda)
    else
        false;
    defer if (comptime @hasDecl(H, "setTrailingMemberCall")) {
        _ = H.setTrailingMemberCall(prev_tl);
    };
    const arg_values = try readArgRun(allocator, frame, cmg.args, cmg.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cmg.arg_names);
    defer allocator.free(names);
    // A direct splice receiver (a bound `this` register) is the innermost
    // implicit receiver when present; otherwise the lambda capture slot, or —
    // when that is empty — the enclosing function's `this` *parameter*.
    const direct_this: ?Value = if (cmg.recv) |r| frame.read(r) else null;
    const this_val = if (direct_this) |dt| dt else implicitThisValue(frame, cmg.this_idx, true);
    // A lowering-committed INLINE INSTANCE METHOD with inferred reified
    // type arguments: bind the stamped type-argument names as globals
    // for the call's duration (the same channel the inline splice and
    // `callFuncTyped` use), then let the NORMAL member walk dispatch —
    // its enclosing-receiver pushes are what nested semantics blocks
    // resolve against. `c.visitNodes(Kinds.OnRe) { … }` runs with
    // `T = Lw` live so the framed body's `is T` checks the real class.
    var mit_saved: std.ArrayList(struct { name: []const u8, prev: ?Value }) = .empty;
    defer mit_saved.deinit(allocator);
    defer {
        var ri: usize = mit_saved.items.len;
        while (ri > 0) {
            ri -= 1;
            const sv = mit_saved.items[ri];
            if (comptime @hasDecl(H, "restoreGlobalBinding")) {
                host.restoreGlobalBinding(sv.name, sv.prev);
            }
        }
    }
    if (cmg.func != null and cmg.type_args.len != 0 and comptime @hasDecl(H, "bindTypeParamGlobal")) {
        if (frame.module.funcById(cmg.func.?)) |tf| {
            if (tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this")) {
                const tp_list = frame.module.registry.func_type_params.get(cmg.func.?);
                const tp_names: []const []const u8 = if (tp_list) |l| l.items else &.{};
                orAudit("CallMemberOrGlobal", name_str, "member_inline_typed", -1, null);
                for (tp_names, 0..) |tpn, ti| {
                    if (ti >= cmg.type_args.len) break;
                    const arg_name = constStr(frame.module, cmg.type_args[ti]) orelse continue;
                    if (arg_name.len == 0) continue;
                    const prev = host.bindTypeParamGlobal(tpn, arg_name);
                    try mit_saved.append(allocator, .{ .name = tpn, .prev = prev });
                }
            }
        }
    }
    // A bare callee whose name starts uppercase is usually a constructor /
    // type — but only when such a type exists. Kotlin has no capitalization
    // rule: DSL-style functions are capitalized (ktor's
    // `HttpResponseValidator { … }` is an extension on HttpClientConfig), so
    // the member/extension passes are skipped only when the name really
    // names a class.
    var is_ctor_name = name_str.len > 0 and std.ascii.isUpper(name_str[0]) and
        cmg.class != null;
    // An INAPPLICABLE constructor is not a candidate at all: Kotlin filters
    // by applicability before scope rank, so `Point(it)` against `data class
    // Point(x: Int, y: Int)` never means construction — the member/extension
    // walk must run and bind the receiver's `MockViewValidator.Point`
    // extension. The class-carrying ctor tail stays the fallback for calls
    // nothing else serves, so a bindable secondary constructor is still
    // reachable when the walk misses.
    if (is_ctor_name) applicable: {
        const cid = cmg.class.?;
        if (cid.int() >= frame.module.classes.items.len) break :applicable;
        const cls = &frame.module.classes.items[cid.int()];
        var required: usize = 0;
        var has_vararg = false;
        for (cls.primary_params) |*p| {
            if (p.is_vararg) {
                has_vararg = true;
                continue;
            }
            if (!p.has_default) required += 1;
        }
        const n = arg_values.len;
        if (n >= required and (has_vararg or n <= cls.primary_params.len)) break :applicable;
        if (comptime @hasDecl(H, "classSecondaryCtorCanBind")) {
            if (host.classSecondaryCtorCanBind(cls.fqn, cls.name, n)) break :applicable;
        }
        is_ctor_name = false;
    }
    // A capitalized name that is ALSO a method of the implicit receiver is a
    // nearer-scope member call, not a constructor (`Test(...)` inside a class
    // declaring `fun Test(...)` next to an imported `kotlin.test.Test`): run
    // the member passes; the constructor stays the fallback when no member
    // binds.
    if (is_ctor_name and this_val != .Null and this_val != .Unit) refine: {
        // The nearest receiver carrying the member may sit deeper in the
        // implicit chain than the innermost `this` (a suspend block's
        // innermost receiver is the coroutine, not the declaring class).
        const rcands = try implicitCandidatesAlloc(H, allocator, frame, cmg.this_idx, true, host, name_str, direct_this);
        defer allocator.free(rcands);
        const rcands_keepalive = pinImplicitCandidates(rcands);
        defer runtime.keepaliveRestore(rcands_keepalive);
        for (rcands) |c| {
            if (c.v != .Null and c.v != .Unit and host.hostHasMember(&c.v, name_str)) {
                is_ctor_name = false;
                break :refine;
            }
        }
    }
    if (cmgTraceWant()) |w| {
        if (std.mem.eql(u8, w, name_str)) {
            const dtc: []const u8 = if (direct_this != null and comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&direct_this.?) else "-";
            std.debug.print("[cmg] {s} this_tag={s} ctor_name={} in_fn={s}#{d} this_idx={d} ncaps={d} recv_reg={?d} direct_cls={s}\n", .{ name_str, @tagName(std.meta.activeTag(this_val)), is_ctor_name, frame.func.name, frame.func.id.int(), cmg.this_idx, frame.captures.items.len, if (cmg.recv) |r| r.int() else null, dtc });
            for (frame.captures.items, 0..) |cv, cvi| {
                const cn: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&cv) else "-";
                const nm: []const u8 = if (cvi < frame.func.capture_order.len) frame.func.capture_order[cvi] else "?";
                std.debug.print("[cmg-cap] [{d}] {s} = {s} {s}\n", .{ cvi, nm, @tagName(std.meta.activeTag(cv)), cn });
            }
        }
    }
    var committed_ext_h: ?FuncId = null;
    var committed_recv_h: ?Value = null;
    var resolved: ?Value = null;
    var first_real_err: ?EvalError = null;
    // A bare `name` bound to a captured callable in the innermost
    // scoped-global layer is a closed-over parameter/local that shadows
    // a same-named member, but a genuine member of the implicit receiver
    // still wins over an over-captured scoped global.
    const shadow_capture = host.isShadowingCapture(name_str) and
        ((this_val == .Null or this_val == .Unit) or !host.hostHasMember(&this_val, name_str));

    // A prior call from this site with this receiver class resolved to a
    // global (single candidate, no member/extension): skip the member passes.
    const func_p = @intFromPtr(frame.func);
    const cmg_skip = comptime @hasDecl(H, "cmgGlobalSkip");
    const skip_member = cmg_skip and !is_ctor_name and !shadow_capture and
        host.cmgGlobalSkip(func_p, &this_val, name_str, arg_values);
    var single_cand = false;

    if (!is_ctor_name and !shadow_capture and !skip_member) {
        const cands = try implicitCandidatesAlloc(H, allocator, frame, cmg.this_idx, true, host, name_str, direct_this);
        defer allocator.free(cands);
        const cands_keepalive = pinImplicitCandidates(cands);
        defer runtime.keepaliveRestore(cands_keepalive);
        single_cand = cands.len == 1;
        // Inside an extension body, the implicit `this` has the
        // extension's DECLARED receiver type, and Kotlin resolves a bare
        // extension call against that static type — not the runtime
        // value's type, which may be a subtype carrying its own
        // same-name extension. Hand the declared head to the strict
        // probe for exactly that candidate.
        var static_from_instr = false;
        const static_recv_ty: ?[]const u8 = blk: {
            // The lowering-recorded declared receiver wins: the executing
            // frame may be a synthesized closure (a suspend body) whose own
            // kind says nothing about the extension receiver.
            if (cmg.static_recv) |sc| {
                if (constStr(frame.module, sc)) |sname| {
                    static_from_instr = true;
                    break :blk sname;
                }
            }
            // Extension bodies resolve a bare call against the extension's
            // DECLARED receiver type.
            switch (frame.func.kind) {
                .top_level_extension, .member_extension => {
                    const idx = frameThisParam(frame) orelse break :blk null;
                    break :blk frame.func.params[idx].ty.name;
                },
                .instance_method => {
                    // A plain instance method resolves a bare (implicit-`this`)
                    // call against its DECLARING class's static member scope,
                    // the same way: a runtime subtype's own same-name overload
                    // that the declaring type cannot see must not shadow the
                    // statically-bound member. `AbstractMap.containsEntry`'s
                    // `get(key)` binds `Map.get(K): V?`, never a
                    // `PersistentCompositionLocalHashMap.get<T>(
                    // CompositionLocal<T>)` the subtype introduces (a read-value
                    // overload that breaks the structural map `equals`). The
                    // this-param's nominal type is a placeholder for stdlib
                    // methods, so the declaring class is found by identity
                    // (memoized per function by the host).
                    break :blk host.declaringClassSimpleName(frame.module, frame.func.id);
                },
                else => break :blk null,
            }
        };
        // A lowering-committed EXTENSION target: Kotlin selects extensions
        // statically, so the runtime walk may only let true MEMBERS shadow
        // it — the by-name extension fallback and the overload re-pick must
        // not re-select a sibling the static evidence excluded (ktor's
        // deprecated P.install delegates to its cast-picked sibling; a
        // by-runtime-type re-pick binds the deprecated overload again and
        // recurses without bound).
        const committed_ext: ?FuncId = blk: {
            const fid = cmg.func orelse break :blk null;
            // Engage the static commitment only for the self-name shape: a
            // bare call to the very name of the function it sits in, where
            // the by-name extension re-pick can re-enter the caller instead
            // of the sibling the lowering (cast evidence, receiver match)
            // committed — ktor's deprecated P.install delegating to its
            // Pipeline sibling recursed without bound. Every other deferred
            // call keeps the runtime walk's full re-selection.
            if (!std.mem.eql(u8, frame.func.name, name_str)) break :blk null;
            if (fid.int() == frame.func.id.int()) break :blk null;
            const cf = frame.module.funcById(fid) orelse break :blk null;
            if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) break :blk fid;
            break :blk null;
        };
        // The committed target binds the FIRST candidate receiver (walk
        // order, innermost first) its declared receiver does not exclude —
        // a bare call inside a companion-scoped context must skip the
        // companion and land on the outer instance exactly like the
        // name-based walk would. No fitting receiver: fall back to the
        // name-based resolution entirely (the lowering pick can be wrong;
        // the runtime walk corrects it).
        committed_ext_h = null;
        if (committed_ext) |fid| {
            for (cands) |c| {
                if (host.committedExtReceiverProven(allocator, fid, &c.v)) {
                    committed_ext_h = fid;
                    committed_recv_h = c.v;
                    break;
                }
            }
            if (committed_ext_h == null) {
                for (cands) |c| {
                    if (!host.committedExtReceiverDisproven(fid, &c.v)) {
                        committed_ext_h = fid;
                        committed_recv_h = c.v;
                        break;
                    }
                }
            }
        }
        // Strict pass: members and receiver-compatible extensions of each
        // candidate, innermost first — the kotlinc candidate order.
        for (cands, 0..) |c, ci| {
            if (cmgTraceWant()) |w| {
                if (std.mem.eql(u8, w, name_str)) {
                    const cn: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&c.v) else @tagName(std.meta.activeTag(c.v));
                    std.debug.print("[cmg-cand] {s} ci={d} depth={d} tag={s} class={s}\n", .{ name_str, ci, c.depth, @tagName(std.meta.activeTag(c.v)), cn });
                }
            }
            // The lowering-recorded receiver type describes the innermost
            // implicit receiver — the first candidate — regardless of the
            // wrapper identity a suspend transform gave the value. A
            // FRAME-derived hint (the enclosing extension's declared
            // receiver) describes only the frame's own `this`: applying it
            // to an inner receiver-lambda subject (`apply { minusAssign(k) }`
            // inside `Map.minus`) refutes the very candidates the subject
            // satisfies.
            const hint: ?[]const u8 = if (static_recv_ty != null and
                (sameReceiver(c.v, this_val) or (static_from_instr and ci == 0)))
                static_recv_ty
            else
                null;
            // A bare `invoke()` on a callable candidate is a fun-interface
            // dispatch (`with(pointerInputEventHandler) { invoke() }`): the
            // interface method may declare an extension receiver, which
            // Kotlin resolves from the ENCLOSING implicit receivers — the
            // plain invoke arm would run the lambda with no receiver at
            // all and strand its bare-member calls. Route it through the
            // receiver-carrying bridge below.
            if ((c.v == .IrClosure or c.v == .Function) and std.mem.eql(u8, name_str, "invoke")) {
                if (try samCandidateInvoke(H, allocator, frame, host, cands, ci, name_str, arg_values, names)) |sr| switch (sr) {
                    .done => |v| {
                        resolved = v;
                        break;
                    },
                    .raised => |e| return raiseStep(frame, e),
                };
                continue;
            }
            // Flat bare-member dispatch: when this candidate's resolved-method
            // cache already names the target (the same entry the strict
            // probe's ladder would fire-and-run first), run it as a pushed
            // activation. The reified-type-binding shape keeps globals bound
            // for the call's duration through this arm's defers, so it stays
            // on the recursive path.
            if (comptime @hasDecl(H, "prepareMemberFlatCall")) {
                if (flatEnabled() and mit_saved.items.len == 0 and argNamesAllNull(cmg.arg_names)) {
                    if (try host.prepareMemberFlatCall(allocator, &c.v, name_str, arg_values, hint, null, false)) |prep0| {
                        var prep = prep0;
                        prep.dst = cmg.dst;
                        orAudit("CallMemberOrGlobal", name_str, "member", c.depth, &c.v);
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            switch (if (committed_ext_h != null)
                try host.callMemberMembersOnly(allocator, &c.v, name_str, arg_values, names, hint)
            else
                try host.callMemberStrictExt(allocator, &c.v, name_str, arg_values, names, hint)) {
                .ok => |v| {
                    orAudit("CallMemberOrGlobal", name_str, "member", c.depth, &c.v);
                    resolved = v;
                    break;
                },
                .err => |e| switch (e) {
                    .Suspended, .CalleeFailed => return raiseStep(frame, e),
                    // Control flow out of a body that RAN: the candidate
                    // was the real callee (a `synchronized { return x }`
                    // non-local return, a thrown exception). Walking on
                    // would re-execute its side effects on an outer
                    // receiver — same doctrine as `CalleeFailed`.
                    .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                    .Unimplemented => |m| {
                        freeDispatchMissMsg(allocator, m);
                        // A callable candidate is an unwrapped fun-interface
                        // value: the bare name dispatches its single abstract
                        // method to the lambda (`with(layoutNode.measurePolicy)
                        // { measure(measurables, constraints) }` stores the
                        // conversion-site lambda). Kotlin binds the INNERMOST
                        // receiver, so the interface dispatch must win here —
                        // before an outer receiver's same-name member (the
                        // coordinator's 1-arg `measure`) grabs the call. A
                        // closure has no real members, so nothing is shadowed.
                        if (c.v == .IrClosure or c.v == .Function) {
                            if (try samCandidateInvoke(H, allocator, frame, host, cands, ci, name_str, arg_values, names)) |sr| switch (sr) {
                                .done => |v| resolved = v,
                                .raised => |re| return raiseStep(frame, re),
                            };
                            if (resolved != null) break;
                        }
                    },
                    else => if (first_real_err == null) {
                        first_real_err = e;
                    },
                },
            }
        }
        // Lenient pass: receivers whose runtime type cannot prove the
        // extension-receiver match. Runs only after every receiver missed
        // strictly, so an unprovable pick never outranks a real member.
        if (resolved == null) {
            for (cands, 0..) |c, ci| {
                const lhint: ?[]const u8 = if (static_recv_ty != null and
                    (sameReceiver(c.v, this_val) or (static_from_instr and ci == 0)))
                    static_recv_ty
                else
                    null;
                switch (if (committed_ext_h != null)
                    try host.callMemberMembersOnlyLenient(allocator, &c.v, name_str, arg_values, names, lhint)
                else if (lhint) |sn|
                    try host.callMemberNamedStatic(allocator, &c.v, name_str, arg_values, names, sn)
                else
                    try host.callMemberNamed(allocator, &c.v, name_str, arg_values, names)) {
                    .ok => |v| {
                        orAudit("CallMemberOrGlobal", name_str, "member_lenient", c.depth, &c.v);
                        resolved = v;
                        break;
                    },
                    .err => |e| switch (e) {
                        .Suspended, .CalleeFailed => return raiseStep(frame, e),
                        // Same as the strict pass: a body that ran owns
                        // its control flow; never re-probe.
                        .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                        .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
                        else => if (first_real_err == null) {
                            first_real_err = e;
                        },
                    },
                }
            }
        }
        // Smart-cast pass: a DEFERRED bare extension call (no committed target)
        // inside an extension body pinned the DECLARED receiver type for the
        // strict/lenient probes. When those found nothing, the receiver value
        // may be a subtype the receiver was narrowed to by a smart-cast
        // (`fun Source.f() { if (this is Buffer) commonReadUtf8CodePoint() }`,
        // whose target is `fun Buffer.commonReadUtf8CodePoint()`), so retry by
        // the receiver's RUNTIME type. Guarded to `resolved == null` and no
        // committed extension: there is no static candidate to conflict with,
        // so this cannot re-pick a sibling the static evidence excluded.
        if (resolved == null and static_recv_ty != null and committed_ext_h == null) {
            for (cands) |c| {
                switch (try host.callMemberStrictExt(allocator, &c.v, name_str, arg_values, names, null)) {
                    .ok => |v| {
                        orAudit("CallMemberOrGlobal", name_str, "smartcast_ext", c.depth, &c.v);
                        resolved = v;
                        break;
                    },
                    .err => |e| switch (e) {
                        .Suspended, .CalleeFailed, .Throw, .NonLocalReturn, .LabeledReturn => return raiseStep(frame, e),
                        .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
                        else => if (first_real_err == null) {
                            first_real_err = e;
                        },
                    },
                }
            }
        }
    }
    if (resolved == null and if (nuTraceWant()) |w| std.mem.eql(u8, name_str, w) else false) {
        const cands2 = try implicitCandidatesAlloc(H, allocator, frame, cmg.this_idx, true, host, name_str, direct_this);
        defer allocator.free(cands2);
        const cands_keepalive = pinImplicitCandidates(cands2);
        defer runtime.keepaliveRestore(cands_keepalive);
        const dbg_srt: []const u8 = blk: {
            if (cmg.static_recv) |sc| {
                if (constStr(frame.module, sc)) |sname| break :blk sname;
            }
            break :blk "-";
        };
        std.debug.print("[par-miss] in={s}#{d} static_recv={s} skip={} ncands={d}:", .{ frame.func.name, frame.func.id.int(), dbg_srt, skip_member, cands2.len });
        for (cands2) |c| {
            if (c.v == .Instance) {
                const ig = c.v.Instance.borrow();
                const cg = ig.get().class.borrow();
                std.debug.print(" {s}", .{cg.get().name});
                cg.deinit();
                ig.deinit();
            } else std.debug.print(" {s}", .{@tagName(c.v)});
        }
        std.debug.print("\n", .{});
        {
            var anc = frame.gc_link;
            var ai: usize = 0;
            std.debug.print("[par-anc]", .{});
            while (anc) |af| : (anc = af.gc_link) {
                std.debug.print(" <-{s}#{d}", .{ af.func.name, af.func.id.int() });
                ai += 1;
                if (ai >= 6) break;
            }
            std.debug.print("\n", .{});
        }
        {
            const ents = try enclosingEntriesAlloc(allocator);
            defer allocator.free(ents);
            std.debug.print("[par-enc] n={d}:", .{ents.len});
            for (ents) |e| {
                if (e.v == .Instance) {
                    const ig = e.v.Instance.borrow();
                    const cg = ig.get().class.borrow();
                    std.debug.print(" {s}{s}", .{ cg.get().name, if (e.isSubject()) @as([]const u8, "*") else "" });
                    cg.deinit();
                    ig.deinit();
                } else std.debug.print(" {s}", .{@tagName(e.v)});
            }
            std.debug.print("\n", .{});
        }
    }
    var result: Value = undefined;
    if (resolved == null) {
        if (committed_ext_h) |fid| {
            var ext_args = try allocator.alloc(Value, arg_values.len + 1);
            defer allocator.free(ext_args);
            ext_args[0] = committed_recv_h orelse this_val;
            for (arg_values, 0..) |av, i| ext_args[i + 1] = av;
            switch (try host.callFunc(allocator, frame.module, fid, ext_args)) {
                .ok => |v| {
                    orAudit("CallMemberOrGlobal", name_str, "committed_ext", -1, null);
                    try frame.write(cmg.dst, v);
                    return .cont;
                },
                .err => |e| return raiseStep(frame, e),
            }
        }
    }
    if (resolved) |v| {
        result = v;
    } else {
        // The member passes all missed on a single implicit-receiver
        // candidate: record so a repeat call skips straight here. A pass
        // that FAILED (first_real_err — an abort, a callee error) is not a
        // miss: recording it taught the site to skip the member walk
        // forever, so after one wall-capped test every later
        // `removeKnownCompositionLocked` in the same process resolved as
        // an unresolved global (the contamination cluster).
        if (cmg_skip and single_cand and !is_ctor_name and !shadow_capture and first_real_err == null)
            host.cmgGlobalRecord(func_p, &this_val, name_str, arg_values);
        // Overloaded top-level function: select by runtime arg types
        // before falling back to the single global value baked in at
        // lower time.
        const cno_file: ?ir.FileId = if (frame.cur_span) |sp| sp.file else null;
        // A synthesized lambda/closure frame carries no declared package, so
        // the overload re-pick runs with an empty caller scope and a same-name
        // CROSS-PACKAGE twin can win a first-seen tie (the wrong same-signature
        // `internal fun` binds). The lowering-resolved target (`cmg.func`)
        // already settled scope; pass its package as a fallback anchor so the
        // re-pick can exclude the out-of-scope twin. Only consulted when the
        // frame package is empty, so the ordinary packaged-caller path is
        // untouched.
        const cno_anchor: []const u8 = if (frame.func.package.len == 0) blk: {
            if (cmg.func) |bf| {
                if (frame.module.funcById(bf)) |bfd| {
                    if (bfd.package.len != 0) break :blk bfd.package;
                }
            }
            // A ctor-name call resolved to a class carries no func hint; the
            // class's package anchors the scope the same way (a property-init
            // thunk calling `Color(red = …)` must see the ui.graphics
            // factories as import-tier candidates, not other-package noise).
            if (cmg.class) |cid| {
                if (cid.int() < frame.module.classes.items.len) {
                    break :blk frame.module.classes.items[cid.int()].package;
                }
            }
            break :blk "";
        } else "";
        // Arm the host→driver flat handoff: the overload terminal may
        // stash a prepared flat request instead of dispatching natively.
        armHostFlatReq();
        const cno_res = try host.callNamedOverload(allocator, frame.module, cmg.candidates, name_str, arg_values, names, cmg.class, is_ctor_name, frame.func.package, cno_file, cno_anchor);
        _ = takeHostFlatArm();
        if (takeHostFlatReq()) |req0| {
            var prep = req0;
            prep.dst = cmg.dst;
            frame.flat_call = prep;
            return .flat_call;
        }
        const overload = switch (cno_res) {
            .ok => |maybe| maybe,
            .err => |e| return raiseStep(frame, e),
        };
        if (overload) |v| {
            orAudit("CallMemberOrGlobal", name_str, "overload", -1, null);
            result = v;
        } else {
            // A lowering-resolved identity (constructor class or
            // shadowable top-level function) binds exactly; the
            // simple-name lookup remains the unresolved fallback. A
            // runtime-scoped shadowing capture outranks the static pick,
            // as on the load form.
            // A committed EXTENSION func is not a plain global value — it
            // needs its receiver prepended, which the committed-ext leg
            // above handles (or declines). Only a non-extension func (or a
            // class) may bind by id here; a receiverless value invocation
            // of an extension misbinds every parameter.
            const by_id_func: ?FuncId = blk: {
                if (cmg.candidates != null) break :blk null;
                const fid = cmg.func orelse break :blk null;
                const cf = frame.module.funcById(fid) orelse break :blk null;
                // A committed id can belong to the MAIN module's table while
                // this frame runs sub-module code (the same integer names an
                // unrelated function there — a restart lambda served a
                // CompositionLocalProvider call). A name mismatch in the
                // frame's table re-validates against the main module, whose
                // id space the host's by-id lookup resolves.
                if (!std.mem.eql(u8, cf.name, name_str)) {
                    if (comptime @hasDecl(H, "mainFuncNameMatches")) {
                        if (host.mainFuncNameMatches(fid, name_str)) break :blk fid;
                    }
                    break :blk null;
                }
                if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) break :blk null;
                // First-wins commit vs overloads: a committed fn the call's
                // ARITY cannot bind (a same-file private 3-arg picked for a
                // 2-arg call whose true target is a public overload in
                // another file) must not serve by id — decline so the
                // overload leg ranks the full same-name set.
                if (!frame.module.globalArityCanBind(fid, cf, arg_values.len)) break :blk null;
                break :blk fid;
            };
            // A constructor-name call (`Foo(args)` where `Foo` is a class) must
            // bind the class for construction — never a published companion
            // singleton. Pass `is_ctor_name` as `ctor_ref` so `lookupGlobalById`
            // skips the class's companion-object singleton (which it otherwise
            // returns for a class-value read); otherwise, once the companion has
            // been published (e.g. a prior `Foo.member` access), `Foo(args)`
            // resolves to `Companion.invoke` instead of constructing.
            // A committed class that cannot CONSTRUCT (an interface/abstract
            // classifier sharing the name with a callable — the pack's
            // `interface Composition` vs a local `@Composable fun
            // Composition`) never wins the by-id serve for a non-SAM call;
            // the lexical name lookup and the overload leg resolve the real
            // callable instead.
            const ctor_class: ?ir.ClassId = blk: {
                const cid = cmg.class orelse break :blk null;
                if (cid.int() < frame.module.classes.items.len) {
                    const cls = &frame.module.classes.items[cid.int()];
                    if ((cls.is_interface or cls.is_abstract) and
                        !(arg_values.len == 1 and valueInvocable(frame.module, arg_values[0])))
                    {
                        break :blk null;
                    }
                }
                break :blk cid;
            };
            const by_id: ?Value = if ((ctor_class != null or by_id_func != null) and
                !host.isShadowingCapture(name_str))
                host.lookupGlobalById(allocator, by_id_func, ctor_class, is_ctor_name)
            else
                null;
            // A bounded candidate set is authoritative. Once lowering has
            // supplied it, a miss may not widen back to an unrelated
            // same-simple-name global; only a runtime shadowing capture keeps
            // the lexical name lookup. Host-only/incomplete-header symbols
            // carry null and retain legacy lookup until their declarations
            // are complete enough to rank.
            const allow_name_global = cmg.candidates == null or shadow_capture;
            const global = if (by_id != null)
                by_id
            else if (allow_name_global)
                switch (try host.lookupGlobalThrowing(allocator, name_str)) {
                    .ok => |maybe| maybe,
                    .err => |e| return raiseStep(frame, e),
                }
            else
                null;
            if (global) |found_callee| {
                var callee = found_callee;
                // A CALL is not served by a non-callable name binding: a
                // captured `var key = 0` beside the `key(...) { }` composable
                // does not shadow the function for an invocation — Kotlin
                // binds the function; the scoped-global walk merely found the
                // nearer non-callable capture. Re-bind through the function
                // index before invoking the value.
                if (!valueInvocable(frame.module, callee) and cmg.candidates == null) {
                    if (frame.module.funcId(name_str)) |fid| {
                        if (host.lookupGlobalById(allocator, fid, null, false)) |fv| {
                            orAudit("CallMemberOrGlobal", name_str, "noncallable_rebind", -1, null);
                            callee = fv;
                        }
                    }
                }
                orAudit("CallMemberOrGlobal", name_str, if (by_id != null) "global_id" else "global", -1, null);
                // Explicit call-site type args survive the deferred form;
                // a typed value dispatch lets the host coerce unsigned
                // literals / serve reified intrinsics by them.
                if (cmg.type_args.len != 0) {
                    var ta_buf: [4][]const u8 = undefined;
                    const n_ta = @min(cmg.type_args.len, ta_buf.len);
                    for (cmg.type_args[0..n_ta], ta_buf[0..n_ta]) |cid, *slot| {
                        slot.* = constStr(frame.module, cid) orelse "";
                    }
                    switch (try host.callValueNamedTyped(allocator, &callee, arg_values, names, ta_buf[0..n_ta])) {
                        .ok => |v| result = v,
                        .err => |e| return raiseStep(frame, e),
                    }
                } else switch (try host.callValueNamed(allocator, &callee, arg_values, names)) {
                    .ok => |v| {
                        if (missTraceWant()) |w| {
                            if (std.mem.eql(u8, w, name_str)) {
                                std.debug.print("[gid-result] {s} in_fn={s} callee={s} nargs={d} -> {s}", .{
                                    name_str,
                                    frame.func.name,
                                    @tagName(std.meta.activeTag(callee)),
                                    arg_values.len,
                                    @tagName(std.meta.activeTag(v)),
                                });
                                if (arg_values.len == 1 and arg_values[0] == .ULong)
                                    std.debug.print(" arg={x}", .{arg_values[0].ULong});
                                if (v == .ULong) std.debug.print(" {x}", .{v.ULong});
                                if (v == .Long) std.debug.print(" {x}", .{v.Long});
                                std.debug.print("\n", .{});
                            }
                        }
                        result = v;
                    },
                    .err => |e| return raiseStep(frame, e),
                }
            } else {
                if (first_real_err) |fre| return raiseStep(frame, fre);
                // A committed header carrying reified type args serves
                // through the typed func dispatch (the reified intrinsics
                // live there) before the unsettled-header no-op —
                // `enumEntriesIntrinsic()` spliced into a lambda body.
                if (cmg.func != null and cmg.type_args.len != 0 and comptime @hasDecl(H, "callFuncTyped")) {
                    var ta_buf: [4][]const u8 = undefined;
                    const n_ta = @min(cmg.type_args.len, ta_buf.len);
                    for (cmg.type_args[0..n_ta], ta_buf[0..n_ta]) |tcid, *slot| {
                        slot.* = constStr(frame.module, tcid) orelse "";
                    }
                    orAudit("CallMemberOrGlobal", name_str, "typed_header", -1, null);
                    switch (try host.callFuncTyped(allocator, frame.module, cmg.func.?, arg_values, names, ta_buf[0..n_ta], false)) {
                        .ok => |v| {
                            try frame.write(cmg.dst, v);
                            return .cont;
                        },
                        .err => |e| return raiseStep(frame, e),
                    }
                }
                // Every arm missed, but the name is a declared header the
                // link could not settle (an `expect` with no compiled
                // `actual`): the call is a no-op, the shape its
                // manufactured empty body produced before header-only
                // declarations stayed bodyless.
                if (host.bareUnsettledHeaderNoOp(frame.module, name_str, arg_values.len)) {
                    orAudit("CallMemberOrGlobal", name_str, "unsettled_header_noop", -1, null);
                    result = .Unit;
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                    if (missTraceWant()) |w| {
                        if (std.mem.eql(u8, w, name_str)) {
                            std.debug.print("[cmg-tail] name={s} func={?} class={?} this_tag={s} n_seen_err={} span={d}:{d} cands={d} in_fn={s} recvp={} np={d} p0={s} nparams_vals={d} this_idx={d} ncaps={d}\n", .{
                                name_str,
                                if (cmg.func) |f| f.int() else null,
                                if (cmg.class) |c| c.int() else null,
                                @tagName(std.meta.activeTag(this_val)),
                                first_real_err != null,
                                if (frame.cur_span) |sp| sp.file.int() else 0,
                                if (frame.cur_span) |sp| sp.start else 0,
                                if (cmg.candidates) |c| c.len else 0,
                                frame.func.name,
                                frame.func.has_receiver_param,
                                frame.func.params.len,
                                if (frame.func.params.len > 0) frame.func.params[0].name else "-",
                                frame.params.items.len,
                                cmg.this_idx,
                                frame.captures.items.len,
                            });
                        }
                    }
                    dumpFrameChainForDiag();
                    return raiseStep(frame, .{ .Unbound = msg });
                }
            }
        }
    }
    try frame.write(cmg.dst, result);
    return .cont;
}

/// The enclosing-chain entry a method / extension frame contributes for
/// its own bound receiver: a dispatch receiver carries its class-nesting
/// tower and companion (`receiver`); an extension receiver brings only
/// itself (`subject`). `null` for plain functions, lambdas (their
/// receiver scope is the creation-time chain), and unbound frames.
fn ownReceiverEntry(func: *const Func, params: []const Value) ?EnclosingEntry {
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

/// The captured/parameter outer link of an `Instance` value.
fn instanceOuter(v: *const Value) ?Value {
    return switch (v.*) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            break :blk g.get().outer;
        },
        else => null,
    };
}

/// Index of the frame's *synthesized* `this` receiver parameter, if any.
/// A leading `this` param is the frame's own dispatch receiver only when
/// the lowerer injected it (`has_receiver_param`): a method / extension /
/// local-extension receiver, or a constructor / init thunk's instance
/// under construction. A user parameter that merely spells its name `this`
/// (`fun f(\`this\`: T)`, written with backticks since `this` is a hard
/// keyword) is NOT a dispatch receiver, so a bare call in its body
/// resolves no implicit receiver — matching kotlinc, which rejects such a
/// call. The synthesized receiver is always at index 0.
fn frameThisParam(frame: *const Frame) ?usize {
    if (!frame.func.has_receiver_param) return null;
    if (frame.func.params.len != 0 and std.mem.eql(u8, frame.func.params[0].name, "this")) {
        return 0;
    }
    return null;
}

/// Simple name of the class that DECLARES `fid` as one of its methods, found
/// by identity in `module`'s class table (the this-param's nominal type is a
/// placeholder for stdlib methods, so it cannot serve here). Used to give an
/// instance method's implicit-`this` call the static receiver type Kotlin
/// resolves it against — its declaring class. `null` when no class owns it
/// (a top-level / local function reached with an injected receiver).
fn declaringClassName(module: *const Module, fid: ir.FuncId) ?[]const u8 {
    for (module.classes.items) |*c| {
        for (c.methods) |mfid| {
            if (@intFromEnum(mfid) == @intFromEnum(fid)) return c.name;
        }
    }
    return null;
}

/// The calling frame's receiver, an Instance from either a `this`-named
/// param or a `this`-named capture. `null` otherwise.
fn callerThisValue(frame: *const Frame) ?Value {
    if (frameThisParam(frame)) |i| {
        if (i < frame.params.items.len and frame.params.items[i] == .Instance) {
            return frame.params.items[i];
        }
    }
    var idx = frame.func.this_cap_idx;
    if (idx == -2) {
        idx = -1;
        for (frame.func.capture_order, 0..) |n, i| {
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

// -------------------------------------------------------------------------
// Implicit-receiver resolution choke point.
//
// The `*OrGlobal` instructions (`LoadFromThisOrGlobal`, `StoreToThisOrGlobal`,
// `CallMemberOrGlobal`) all resolve a bare name against the *implicit*
// receivers in scope — the lambda/method's own `this`, each
// lexically-enclosing `this@…`, and (for dispatch receivers) the class-nesting
// tower of `outer` links — before falling back to a top-level global. The
// candidate list and its order are derived in exactly one place
// (`implicitCandidatesAlloc`); the three handlers differ only in their
// terminal operation (field read / member write / member call) and in the
// call form's shadow/constructor gates. Kotlin's precedence, pinned by the
// kotlinc parity fixtures (`receiver_lambda_*`, `bare_write_*`,
// `inner_ext_over_outer_member`): candidates are searched innermost-first,
// and *all* of a receiver's candidates — members first, then applicable
// extensions — outrank any candidate of the next receiver out.
// -------------------------------------------------------------------------

/// Recover the implicit receiver for an `*OrGlobal` instruction:
/// The synthesized `this` parameter when this frame has one; otherwise
/// `captures[this_idx]` if in range, else `Null`. A method/init/extension
/// frame's receiver parameter is authoritative: its capture slot can hold an
/// unrelated boxed local at the same numeric index, and treating that Cell as
/// `this` both misresolves the bare name and leaves the real receiver behind it.
fn implicitThisValue(frame: *const Frame, this_idx: usize, consult_param: bool) Value {
    if (consult_param) {
        if (frameThisParam(frame)) |idx| {
            if (idx < frame.params.items.len) return frame.params.items[idx];
        }
    }
    // The baked capture index is only trusted when it actually names the
    // `this` capture: several emit arms bake `0` as a placeholder (the
    // direct receiver register carries the real value), and `captures[0]`
    // is then whatever capture happens to be first — a non-receiver local
    // (`scope`) that must never enter the implicit-receiver walk. When the
    // index does not name `this`, locate the real `this` capture by name;
    // a frame with no `this` capture has no capture-borne receiver at all.
    var idx = this_idx;
    const order = frame.func.capture_order;
    if (order.len != 0 and
        !(this_idx < order.len and std.mem.eql(u8, order[this_idx], "this")))
    {
        var found: ?usize = null;
        for (order, 0..) |n, i| {
            if (std.mem.eql(u8, n, "this")) {
                found = i;
                break;
            }
        }
        idx = found orelse return Value.Null;
    }
    const this_val: Value = if (idx < frame.captures.items.len)
        frame.captures.items[idx]
    else
        Value.Null;
    return this_val;
}

/// One candidate receiver for a bare-name `*OrGlobal` resolution. `depth`
/// is the candidate's position in the search order (0 = the frame's own
/// implicit `this`), recorded for the KLIO_OR_AUDIT readout.
const ImplicitCandidate = struct {
    v: Value,
    depth: u16,
};

/// Candidate walks are assembled in host scratch memory, but probing a
/// property/getter or member can re-enter interpreted code and collect. Keep
/// every receiver alive for the whole walk, including transient Cell and
/// companion candidates that are not independently present in a frame.
fn pinImplicitCandidates(cands: []const ImplicitCandidate) usize {
    const mark = runtime.keepaliveMark();
    for (cands) |c| runtime.keepalivePush(c.v);
    return mark;
}

/// The ordered implicit-receiver candidates a bare name is resolved
/// against, innermost first: the frame's own implicit `this` (when
/// present), then each lexically-enclosing `this@…`. A receiver that
/// entered scope by dispatch (a method receiver or a displaced lexical
/// `this`) is followed by its class's companion object (when that
/// companion owns a member of the searched name — Kotlin puts the
/// companion in scope at the class's own depth, below the instance
/// receiver) and by its class-nesting tower of `outer` links — inside a
/// member of `Inner`, `this@Outer` is in scope through `this@Inner` —
/// while a `with`/`run`/`apply` subject brings only itself
/// (`with(x) { … }` never puts `x`'s enclosing instances or companion in
/// scope). Caller frees the returned slice.
const SamInvokeOutcome = union(enum) { done: Value, raised: EvalError };

/// Dispatch a bare name that missed (or is `invoke`) on a CALLABLE walk
/// candidate as a fun-interface method: run the lambda with the next
/// implicit receiver out handed as `this` (the interface method may be a
/// member extension — `MeasurePolicy`'s `MeasureScope.measure` — whose
/// body resolves bare names against that receiver). Returns null when the
/// invocation itself reports a non-control-flow error, letting the walk
/// continue.
fn samCandidateInvoke(
    comptime H: type,
    allocator: Allocator,
    frame: *Frame,
    host: *H,
    cands: []const ImplicitCandidate,
    ci: usize,
    name_str: []const u8,
    arg_values: []const Value,
    names: []const ?[]const u8,
) Allocator.Error!?SamInvokeOutcome {
    // For any name other than `invoke`, the interface-method reading is
    // only plausible when the callable's declared parameter count matches
    // the call exactly, AND no top-level non-extension function serves
    // the name — kotlinc resolves `probeCoroutineResumed(completion)` to
    // the top-level helper even inside an extension on a function type,
    // where the implicit `this` IS the coroutine block; invoking the
    // block ran every UNDISPATCHED launch body twice. Names with only
    // member/extension forms (`measure`, `emit`) keep the dispatch.
    if (!std.mem.eql(u8, name_str, "invoke")) {
        if (comptime @hasDecl(H, "callableFieldArity")) {
            const n = host.callableFieldArity(&cands[ci].v) orelse return null;
            if (n != arg_values.len) return null;
        }
        for (frame.module.funcsBySimpleName(name_str)) |fid| {
            const f = frame.module.funcById(fid) orelse continue;
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
            return null;
        }
        // A DEEPER implicit receiver that can serve the name (a member of
        // its hierarchy or an applicable extension) outranks the
        // interface-method reading of this callable: `collect(this)`
        // inside an `unsafeFlow { }` block binds the outer Flow receiver's
        // `collect`, never the captured action lambda. Decline so the walk
        // reaches that receiver.
        if (comptime @hasDecl(H, "valueCouldServeName")) {
            var j = ci + 1;
            while (j < cands.len) : (j += 1) {
                if (host.valueCouldServeName(allocator, &cands[j].v, name_str)) return null;
            }
        }
    }
    var sam_recv = cands[ci].v;
    if (runtime.getenvSlice("KLIO_SAM_TRACE") != null) {
        std.debug.print("[sam-walk] name={s} nargs={d} ci={d} n={d} tags:", .{ name_str, arg_values.len, ci, cands.len });
        for (cands, 0..) |c, k| {
            const served = if (comptime @hasDecl(H, "valueCouldServeName")) host.valueCouldServeName(allocator, &c.v, name_str) else false;
            const cls: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&c.v) else "?";
            std.debug.print(" [{d}]{s}({s})/serve={}", .{ k, @tagName(c.v), cls, served });
        }
        std.debug.print("\n", .{});
    }
    const sam_this: ?Value = if (ci + 1 < cands.len) cands[ci + 1].v else null;
    const sam_res = if (comptime @hasDecl(H, "callValueWithThis")) blk: {
        if (sam_this) |st| break :blk try host.callValueWithThis(allocator, &sam_recv, &st, arg_values, names);
        break :blk try host.callValueNamed(allocator, &sam_recv, arg_values, names);
    } else try host.callValueNamed(allocator, &sam_recv, arg_values, names);
    switch (sam_res) {
        .ok => |v| {
            orAudit("CallMemberOrGlobal", name_str, "sam_receiver_invoke", cands[ci].depth, &cands[ci].v);
            return .{ .done = v };
        },
        .err => |se| switch (se) {
            .Suspended, .CalleeFailed, .Throw, .NonLocalReturn, .LabeledReturn => return .{ .raised = se },
            else => {
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[sam-inv] {s} swallowed err={s}\n", .{ name_str, @tagName(se) });
                }
                return null;
            },
        },
    }
}

fn implicitCandidatesAlloc(comptime H: type, allocator: Allocator, frame: *const Frame, this_idx: usize, consult_param: bool, host: *H, bare_name: []const u8, direct_this: ?Value) Allocator.Error![]ImplicitCandidate {
    var out: std.ArrayList(ImplicitCandidate) = .empty;
    errdefer out.deinit(allocator);
    var depth: u16 = 0;
    const entries = try enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    // The innermost candidate is the inline-splice's bound receiver when
    // supplied (it lives in a local register, invisible to the frame `this`
    // slot / capture lookup), otherwise the frame's own `this`. A supplied
    // direct receiver is subject-like (its own value only, no class-nesting
    // tower); it replaces, rather than precedes, the frame `this`.
    const inner: ?Value = if (direct_this) |dt|
        dt
    else blk: {
        const tv = implicitThisValue(frame, this_idx, consult_param);
        break :blk if (tv == .Null or tv == .Unit) null else tv;
    };
    if (inner) |iv| {
        if (iv != .Unit) {
            // When the innermost receiver is also the innermost chain entry
            // (a seeded method/extension receiver, or a receiver-split
            // subject), the entry's own run covers it with the right kind.
            const dup = entries.len > 0 and sameReceiver(entries[0].v, iv);
            if (!dup) {
                // The frame's own `this` brings its class-nesting tower (and
                // companion) only when it is a *dispatch* receiver. An
                // extension receiver — or a supplied splice receiver — is
                // subject-like: `fun Owner.Inner.f()` does not put `Inner`'s
                // enclosing `Owner` instance or companion in scope.
                // A direct receiver that IS the frame's own `this` param
                // is a dispatch receiver (an init-block/accessor thunk
                // carries `this` explicitly), so its nesting tower and
                // companion stay in scope; only a FOREIGN direct receiver
                // (a splice/extension subject) suppresses them.
                const direct_is_frame_recv = if (direct_this) |dt| blk: {
                    const ti = frameThisParam(frame) orelse break :blk false;
                    if (ti >= frame.params.items.len) break :blk false;
                    break :blk sameReceiver(frame.params.items[ti], dt);
                } else false;
                const own_is_subject = (direct_this != null and !direct_is_frame_recv) or switch (frame.func.kind) {
                    .top_level_extension, .member_extension => true,
                    else => false,
                };
                try appendCandidateRun(H, allocator, &out, iv, own_is_subject, &depth, host, bare_name);
            }
        }
    }
    // A supplied direct receiver normally REPLACES the frame `this` — but
    // when the frame carries its OWN receiver param bound to a DIFFERENT
    // value, dropping the param strands every bare member of the declared
    // receiver: the pausable pause/resume path was observed leaving a stale
    // ComposableLambdaImpl in the lowered recv register (which then deduped
    // against a leaked subject entry) while the receiver PARAM still held
    // the real MockViewValidator. The param is dispatch truth for the
    // declared receiver type; keep it in the walk between the direct
    // receiver and the ambient chain.
    if (direct_this != null and consult_param) {
        const pv = implicitThisValue(frame, this_idx, true);
        if (pv != .Null and pv != .Unit and !sameReceiver(pv, direct_this.?)) {
            var already = false;
            for (out.items) |c| {
                if (sameReceiver(c.v, pv)) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                const own_subject = switch (frame.func.kind) {
                    .top_level_extension, .member_extension => true,
                    else => false,
                };
                try appendCandidateRun(H, allocator, &out, pv, own_subject, &depth, host, bare_name);
            }
        }
    }
    for (entries) |e| try appendCandidateRun(H, allocator, &out, e.v, e.isSubject(), &depth, host, bare_name);
    return out.toOwnedSlice(allocator);
}

/// Append `v` and, unless it entered scope as a `with`/`run` subject, its
/// class's member-owning companion and its class-nesting tower (`outer`
/// links, each with its own companion). Consecutive duplicates collapse:
/// a receiver-split invoke records the receiver both in the capture slot
/// and as the innermost chain entry.
fn appendCandidateRun(
    comptime H: type,
    allocator: Allocator,
    out: *std.ArrayList(ImplicitCandidate),
    v: Value,
    is_subject: bool,
    depth: *u16,
    host: *H,
    bare_name: []const u8,
) Allocator.Error!void {
    if (cmgTraceWant()) |w| {
        if (std.mem.eql(u8, w, bare_name)) {
            const cn: []const u8 = if (comptime @hasDecl(H, "debugClassNameOf")) host.debugClassNameOf(&v) else "-";
            std.debug.print("[icand-append] {s} tag={s} class={s} subject={} depth={d}\n", .{ bare_name, @tagName(std.meta.activeTag(v)), cn, is_subject, depth.* });
        }
    }
    if (v == .Unit) return;
    // A null `with`/`run` subject is a real receiver candidate — a
    // nullable-receiver extension applies to it — but a null dispatch
    // receiver just means "nothing bound".
    if (v == .Null and !is_subject) return;
    if (v == .Null) {
        try out.append(allocator, .{ .v = v, .depth = depth.* });
        depth.* +|= 1;
        return;
    }
    if (out.items.len == 0 or !sameReceiver(out.items[out.items.len - 1].v, v)) {
        try out.append(allocator, .{ .v = v, .depth = depth.* });
    }
    depth.* +|= 1;
    if (is_subject) return;
    try appendCompanionCandidate(H, allocator, out, &v, depth, host, bare_name);
    var cur: ?Value = instanceOuter(&v);
    while (cur) |o| {
        if (o == .Null or o == .Unit) break;
        try out.append(allocator, .{ .v = o, .depth = depth.* });
        depth.* +|= 1;
        try appendCompanionCandidate(H, allocator, out, &o, depth, host, bare_name);
        cur = instanceOuter(&o);
    }
}

/// Append the companion-object singleton of `v`'s class as a candidate at
/// the class's own depth, when that companion owns a member named
/// `bare_name`.
fn appendCompanionCandidate(
    comptime H: type,
    allocator: Allocator,
    out: *std.ArrayList(ImplicitCandidate),
    v: *const Value,
    depth: *u16,
    host: *H,
    bare_name: []const u8,
) Allocator.Error!void {
    const comp = (try host.companionWithMember(allocator, v, bare_name)) orelse return;
    if (sameReceiver(comp, v.*)) return;
    try out.append(allocator, .{ .v = comp, .depth = depth.* });
    depth.* +|= 1;
}

/// Two receiver values denote the same instance.
fn sameReceiver(a: Value, b: Value) bool {
    if (a == .Instance and b == .Instance) return ObjRef(InstanceData).ptrEq(a.Instance, b.Instance);
    return false;
}

var or_audit_checked: bool = false;
var or_audit_enabled: bool = false;

/// Opt-in arm-audit detector for the `*OrGlobal` instructions
/// (`KLIO_OR_AUDIT`, same pattern as `KLIO_RESOLVE_AUDIT` /
/// `KLIO_LINK_AUDIT`): every execution logs which arm bound the name —
/// `member@<depth>` (with the winning receiver's type), `overload`,
/// `global_id` (the lowering-resolved identity), `global` (name lookup),
/// or the store/global-fallback variants — so a corpus sweep proves which
/// runtime arms are live before an emit site is statically classified.
fn orAuditOn() bool {
    if (!or_audit_checked) {
        or_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_OR_AUDIT") catch null) |v| {
            defer a.free(v);
            or_audit_enabled = v.len != 0 and !std.mem.eql(u8, v, "0");
        }
    }
    return or_audit_enabled;
}

fn orAudit(inst_tag: []const u8, name: []const u8, arm: []const u8, depth: i32, recv: ?*const Value) void {
    if (!orAuditOn()) return;
    const recv_tag: []const u8 = if (recv) |r| r.typeFqn() else "-";
    std.debug.print(
        "[KLIO_OR_AUDIT] run inst={s} name={s} arm={s} depth={d} recv={s}\n",
        .{ inst_tag, name, arm, depth, recv_tag },
    );
}

fn stripScopeGetter(name: []const u8) []const u8 {
    const prefix = "$sgetter$";
    if (std.mem.startsWith(u8, name, prefix)) {
        const rest = name[prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '\u{1f}')) |sep| {
            return rest[sep + 1 ..];
        }
    }
    return name;
}

/// Pull `n_args` register values starting at `args_start` into a fresh
/// owned slice. Caller frees.
/// A positional call: no entry carries an argument name.
fn argNamesAllNull(names: []const ?ConstId) bool {
    for (names) |n| if (n != null) return false;
    return true;
}

fn readArgRun(allocator: Allocator, frame: *const Frame, args_start: Reg, n: u32) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        out[i] = frame.read(Reg.from(args_start.int() + i));
    }
    return out;
}

/// Indexed-load fast path shared by the `get` subscript forms. Serves the
/// in-bounds, `Int`-index read on an `Array`/`List` directly — a plain indexed
/// load with the intrinsics' ownership (`coll_array_get`/`coll_list_get`:
/// retain the borrowed element). Returns `null` (fall through to the slow path,
/// which reproduces the exact diagnostic) for any other shape.
/// The element Value for a range cursor (mirrors the interp_ir `rangeElem`,
/// kept here so the for-loop fast path needs no host round-trip).
inline fn rangeElemEval(cur: i64, kind: runtime.RangeKind) Value {
    return switch (kind) {
        .Int => Value.newInt(cur),
        .Long => .{ .Long = cur },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(cur))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(cur))) },
        .ULong => .{ .ULong = @bitCast(cur) },
    };
}

/// Inline `hasNext()` / `next()` for a `.RangeIter` receiver. The for-loop over
/// any integer/char range desugars to `iterator()` + per-iteration
/// `hasNext()`/`next()` member calls; handling them here skips the full member
/// dispatch (and its per-call hashmap probes), which dominates tight loops.
/// Returns the result for hasNext/next, or null to fall through for any other
/// method. Mirrors `host_call_member.rangeIterMember`.
inline fn rangeIterFast(allocator: Allocator, recv: *const Value, name: []const u8, n_args: u32) ?EvalResult {
    if (n_args != 0) return null;
    const is_has_next = std.mem.eql(u8, name, "hasNext");
    const is_next = std.mem.eql(u8, name, "next");
    if (!is_has_next and !is_next) return null;
    const ri = recv.RangeIter;
    const done = blk: {
        const dg = ri.done.borrow();
        defer dg.deinit();
        break :blk dg.get().*;
    };
    const cur = blk: {
        const cg = ri.cur.borrow();
        defer cg.deinit();
        break :blk cg.get().*;
    };
    const more = !done and ri.step != 0 and ri.kind.inBounds(cur, ri.end, ri.step);
    if (is_has_next) return ok(.{ .Bool = more });
    // next()
    if (!more) {
        const exc = Value{ .Exception = .{
            .fqn = runtime.strInit(allocator, "kotlin.NoSuchElementException") catch return null,
            .message = runtime.strInit(allocator, "iterator exhausted") catch null,
            .cause = null,
        } };
        return errResult(.{ .Throw = exc });
    }
    const adv = cur +| ri.step;
    if (cur == ri.end or adv == cur) {
        const dg = ri.done.borrowMut();
        dg.get().* = true;
        dg.deinit();
    } else {
        const cg = ri.cur.borrowMut();
        cg.get().* = adv;
        cg.deinit();
    }
    return ok(rangeElemEval(cur, ri.kind));
}

inline fn fastIndexGet(recv: *const Value, idx_v: *const Value) ?Value {
    if (idx_v.* != .Int) return null;
    const idx = idx_v.Int;
    if (idx < 0) return null;
    const ui: usize = @intCast(idx);
    switch (recv.*) {
        .Array => |arr| switch (arr.storage) {
            .scalars => |pb| {
                const g = pb.borrow();
                defer g.deinit();
                if (ui >= g.get().len()) return null;
                // View-aware: an unsigned array over signed backing
                // (`UIntArray(intArray)`) tags elements by `arr.prim`,
                // not the buffer's storage kind.
                return g.get().getAs(ui, arr.prim orelse g.get().kind); // fresh scalar
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
            // A stale subList view must fail fast — leave it to the slow
            // path, whose read guard throws ConcurrentModificationException.
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
        else => return null,
    }
}

/// Indexed-store fast path for `a[i] = v` on an `Array` (mirrors the
/// `coll_array_set` intrinsic: release the overwritten element, retain the
/// incoming one under a reclaiming backend). `List.set` returns the previous
/// element, so it is left to the slow path. Returns `true` when handled.
inline fn fastIndexSet(allocator: Allocator, recv: *const Value, idx_v: *const Value, new_val: Value) bool {
    if (idx_v.* != .Int) return false;
    const idx = idx_v.Int;
    if (idx < 0) return false;
    const ui: usize = @intCast(idx);
    switch (recv.*) {
        .Array => |arr| switch (arr.storage) {
            .scalars => |pb| {
                const g = pb.borrowMut();
                defer g.deinit();
                if (ui >= g.get().len()) return false;
                g.get().setAs(ui, new_val, arr.prim orelse g.get().kind);
                return true;
            },
            .boxed => |vl| {
                const g = vl.borrowMut();
                defer g.deinit();
                const items = g.get().items;
                if (ui >= items.len) return false;
                if (runtime.reclaimEnabled()) {
                    items[ui].release(allocator);
                    new_val.retain();
                }
                items[ui] = new_val;
                return true;
            },
        },
        else => return false,
    }
}

/// Subscript fast path: `a[i]` / `a[i] = v` lower to `a.get(i)` / `a.set(i, v)`
/// member calls. Dispatching those through the full member-call machinery for
/// every array element dominates the cost of any loop-heavy program, so the
/// common case is served by the indexed-load/store primitives above. Returns
/// the value to write to `dst`, or `null` when not handled.
inline fn fastSubscript(allocator: Allocator, frame: *const Frame, cm: anytype) ?Value {
    if (cm.arg_names.len != 0 or cm.n_args == 0) return null;
    const nm = constStr(frame.module, cm.name) orelse return null;
    const is_get = cm.n_args == 1 and std.mem.eql(u8, nm, "get");
    const is_set = cm.n_args == 2 and std.mem.eql(u8, nm, "set");
    if (!is_get and !is_set) return null;
    const idx_v = frame.read(Reg.from(cm.args.int()));
    const recv = frame.read(cm.receiver);
    if (is_get) return fastIndexGet(&recv, &idx_v);
    const new_val = frame.read(Reg.from(cm.args.int() + 1));
    if (fastIndexSet(allocator, &recv, &idx_v, new_val)) return Value.Unit;
    return null;
}

/// Snapshot the live values of a `[]Reg`. Caller frees.
fn readRegSlice(allocator: Allocator, frame: *const Frame, regs: []const Reg) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, regs.len);
    for (regs, out) |r, *dst| dst.* = frame.read(r);
    return out;
}

/// Flatten an array / list / set into a slice of its items for
/// spread-arg dispatch. Caller frees the returned slice.
fn spreadItems(allocator: Allocator, v: *const Value) Allocator.Error!union(enum) { ok: []Value, err: EvalError } {
    switch (v.*) {
        .Array => |a| return .{ .ok = try a.snapshot(allocator) },
        .List, .Set => {
            const items_ref = switch (v.*) {
                .List => |l| l.items,
                .Set => |s| s.items,
                else => unreachable,
            };
            const g = items_ref.borrow();
            defer g.deinit();
            const src = g.get().items;
            return .{ .ok = try allocator.dupe(Value, src) };
        },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "spread argument: expected an array/list, got `{s}`", .{v.typeFqn()});
            return .{ .err = .{ .Type = msg } };
        },
    }
}

/// Resolve a per-call `arg_names: []?ConstId` into a parallel
/// `[]?[]const u8`. Empty input yields an empty output. Caller frees.
fn resolveArgNames(allocator: Allocator, module: *const Module, names: []const ?ConstId) Allocator.Error![]?[]const u8 {
    const out = try allocator.alloc(?[]const u8, names.len);
    for (names, out) |opt, *dst| {
        dst.* = if (opt) |id| constStr(module, id) else null;
    }
    return out;
}

fn valueTruthy(allocator: Allocator, v: *const Value) Allocator.Error!union(enum) { ok: bool, err: EvalError } {
    switch (v.*) {
        .Bool => |b| return .{ .ok = b },
        else => {
            const s = v.display(allocator) catch "?";
            const msg = try std.fmt.allocPrint(allocator, "non-bool in branch: {s}", .{s});
            return .{ .err = .{ .Type = msg } };
        },
    }
}

fn constMatches(module: *const Module, id: ConstId, v: *const Value) bool {
    const c = &module.consts.items[id.int()];
    // String switch keys (`when (s) { "lit" -> … }`) compare by content
    // against the subject without allocating a StringRef for the key.
    if (c.* == .String) {
        if (v.* != .String) return false;
        const g = v.String.borrow();
        defer g.deinit();
        return std.mem.eql(u8, c.String, g.get().bytes);
    }
    var lhs = constToValueNoAlloc(c);
    return Value.structuralEq(&lhs, v);
}

/// `const_to_value` for non-String consts: avoids an allocator when the
/// caller only compares structurally. String consts are handled directly
/// in `constMatches`, so this maps them to `.Null`.
fn constToValueNoAlloc(c: *const Const) Value {
    return switch (c.*) {
        .Unit => .Unit,
        .Int => |i| .{ .Int = i },
        .Long => |l| .{ .Long = l },
        .UInt => |v| .{ .UInt = v },
        .ULong => |v| .{ .ULong = v },
        .UShort => |v| .{ .UShort = v },
        .UByte => |v| .{ .UByte = v },
        .Short => |v| .{ .Short = v },
        .Byte => |v| .{ .Byte = v },
        .Double => |d| .{ .Double = d },
        .Float => |f| .{ .Float = f },
        .Bool => |b| .{ .Bool = b },
        .Char => |c2| .{ .Char = c2 },
        .String => .Null, // handled by constToValue; never a switch key
        .Null => .Null,
    };
}

pub fn constToValue(allocator: Allocator, c: *const Const) Allocator.Error!Value {
    return switch (c.*) {
        .Unit => .Unit,
        .Int => |i| .{ .Int = i },
        .Long => |l| .{ .Long = l },
        .UInt => |v| .{ .UInt = v },
        .ULong => |v| .{ .ULong = v },
        .UShort => |v| .{ .UShort = v },
        .UByte => |v| .{ .UByte = v },
        .Short => |v| .{ .Short = v },
        .Byte => |v| .{ .Byte = v },
        .Double => |d| .{ .Double = d },
        .Float => |f| .{ .Float = f },
        .Bool => |b| .{ .Bool = b },
        .Char => |c2| .{ .Char = c2 },
        .String => |s| try strVal(allocator, s),
        .Null => .Null,
    };
}

fn applyUnop(allocator: Allocator, op: UnOp, v: *const Value) Allocator.Error!EvalResult {
    switch (op) {
        .Neg => switch (v.*) {
            .Int => |i| return ok(.{ .Int = -%i }),
            .Long => |l| return ok(.{ .Long = -%l }),
            // Negating NaN keeps the canonical quiet NaN instead of the
            // IEEE sign-bit flip: `Double.NaN` is declared upstream as
            // `-(0.0/0.0)` and every platform's constant evaluation yields
            // the canonical positive NaN (the commonTest pins
            // `Double.NaN.toRawBits() == 0x7FF8000000000000`).
            .Double => |d| return ok(.{ .Double = if (std.math.isNan(d)) std.math.nan(f64) else -d }),
            .Float => |f| return ok(.{ .Float = if (std.math.isNan(f)) std.math.nan(f32) else -f }),
            // `Byte`/`Short.unaryMinus()` widen to `Int` (Kotlin).
            .Byte => |b| return ok(.{ .Int = -@as(i32, b) }),
            .Short => |s| return ok(.{ .Int = -@as(i32, s) }),
            else => {},
        },
        .Plus => return ok(v.*),
        .Inc => switch (v.*) {
            .Int => |i| return ok(.{ .Int = i +% 1 }),
            .Long => |l| return ok(.{ .Long = l +% 1 }),
            .Float => |f| return ok(.{ .Float = f + 1.0 }),
            .Double => |d| return ok(.{ .Double = d + 1.0 }),
            .Char => |c| return ok(.{ .Char = c +% 1 }),
            // `inc()`/`dec()` keep the receiver's type.
            .Byte => |b| return ok(.{ .Byte = b +% 1 }),
            .Short => |s| return ok(.{ .Short = s +% 1 }),
            .UByte => |b| return ok(.{ .UByte = b +% 1 }),
            .UShort => |s| return ok(.{ .UShort = s +% 1 }),
            .UInt => |x| return ok(.{ .UInt = x +% 1 }),
            .ULong => |x| return ok(.{ .ULong = x +% 1 }),
            else => {},
        },
        .Dec => switch (v.*) {
            .Int => |i| return ok(.{ .Int = i -% 1 }),
            .Long => |l| return ok(.{ .Long = l -% 1 }),
            .Float => |f| return ok(.{ .Float = f - 1.0 }),
            .Double => |d| return ok(.{ .Double = d - 1.0 }),
            .Char => |c| return ok(.{ .Char = c -% 1 }),
            .Byte => |b| return ok(.{ .Byte = b -% 1 }),
            .Short => |s| return ok(.{ .Short = s -% 1 }),
            .UByte => |b| return ok(.{ .UByte = b -% 1 }),
            .UShort => |s| return ok(.{ .UShort = s -% 1 }),
            .UInt => |x| return ok(.{ .UInt = x -% 1 }),
            .ULong => |x| return ok(.{ .ULong = x -% 1 }),
            else => {},
        },
    }
    const s = v.display(allocator) catch "?";
    const msg = try std.fmt.allocPrint(allocator, "UnOp.{s} on {s} ({s})", .{ @tagName(op), s, @tagName(v.*) });
    return errResult(.{ .Type = msg });
}

/// Render a Value to its Kotlin string representation. For
/// `Value.Instance`, dispatches `toString()` through the host so
/// user-defined overrides fire; primitives use `renderValue`'s fast
/// path. Caller owns the returned string.
fn stringify(comptime H: type, allocator: Allocator, host: *H, v: *const Value) Allocator.Error!union(enum) { ok: []const u8, err: EvalError } {
    // Instances dispatch their `toString()` override; List/Set/Map dispatch too
    // so their element `toString()` fires (the fast `renderValue`/`display`
    // formatter prints `ClassName@id` for a user element). Arrays keep Kotlin's
    // identity `toString`, so they are not included.
    if (v.* == .Instance or v.* == .List or v.* == .Set or v.* == .Map) {
        switch (try host.callMember(allocator, v, "toString", &.{})) {
            .ok => |result| {
                if (result == .String) {
                    const g = result.String.borrow();
                    defer g.deinit();
                    return .{ .ok = try allocator.dupe(u8, g.get().bytes) };
                }
                return .{ .ok = try renderValue(allocator, &result) };
            },
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = try renderValue(allocator, v) };
}

fn valueToI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Int => |i| @as(i64, i),
        .Long => |l| l,
        else => null,
    };
}

/// Heuristic for an erased generic type-parameter name (`T`, `R`, `E`,
/// `K`, `V`, `TT`, …): a one- or two-character all-uppercase
/// identifier.
fn isErasedTypeParamName(name: []const u8) bool {
    const n = std.mem.trimEnd(u8, name, "?");
    if (n.len == 0 or n.len > 2) return false;
    for (n) |c| {
        if (!(c >= 'A' and c <= 'Z')) return false;
    }
    return true;
}

/// Whether a non-`instance_of` cast still passes because the target is
/// an erased type parameter (unchecked cast on the JVM).
fn typeParamCastPasses(comptime H: type, frame: *const Frame, ty: TypeRef, host: *H) bool {
    if (frame.module.registry.func_type_params.get(frame.func.id)) |tps| {
        for (tps.items) |t| {
            if (std.mem.eql(u8, t, ty.name)) return true;
        }
    }
    if (isErasedTypeParamName(ty.name)) return true;
    if (!host.isConcreteCastTarget(ty.name)) return true;
    return false;
}

fn isSetOrMap(v: *const Value) bool {
    return v.* == .Set or v.* == .Map;
}

fn operatorMethod(op: BinOp) ?[]const u8 {
    return switch (op) {
        .Add => "plus",
        .Sub => "minus",
        .Mul => "times",
        .Div => "div",
        .Mod => "rem",
        .Eq, .BoxedEq => "equals",
        // `!=` dispatches `equals` too, then negates (see the operator-method
        // caller); without this a user `!=` fell through to structural/identity
        // comparison and `a != b` was true even when `a == b`.
        .NotEq, .BoxedNotEq => "equals",
        .Less, .LessEq, .Greater, .GreaterEq => "compareTo",
        .RangeTo => "rangeTo",
        .RangeUntil => "rangeUntil",
        else => null,
    };
}

/// The in-place compound-assign operator (`plusAssign` family) paired
/// with a binary arithmetic op.
fn compoundAssignMethod(op: BinOp) ?[]const u8 {
    return switch (op) {
        .Add => "plusAssign",
        .Sub => "minusAssign",
        .Mul => "timesAssign",
        .Div => "divAssign",
        .Mod => "remAssign",
        else => null,
    };
}

/// Render a value into an owned string the way Kotlin's `toString` /
/// string templates do.
fn renderValue(allocator: Allocator, v: *const Value) Allocator.Error![]const u8 {
    return switch (v.*) {
        .Unit => allocator.dupe(u8, "kotlin.Unit"),
        .Int => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .Long => |l| std.fmt.allocPrint(allocator, "{d}", .{l}),
        .Short => |s| std.fmt.allocPrint(allocator, "{d}", .{s}),
        .Byte => |b| std.fmt.allocPrint(allocator, "{d}", .{b}),
        .UInt => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .ULong => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .UShort => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .UByte => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .Double => |d| runtime.kotlinDoubleToString(allocator, d),
        .Float => |f| runtime.kotlinFloatToString(allocator, f),
        .Bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk allocator.dupe(u8, g.get().bytes);
        },
        .Char => |c| runtime.charUnitToString(allocator, c),
        .Null => allocator.dupe(u8, "null"),
        else => v.display(allocator),
    };
}

/// Streaming UTF-16 code-unit cursor over a UTF-8 slice. Astral
/// codepoints yield a high surrogate then a low one on the next call.
const Utf16Cursor = struct {
    it: std.unicode.Utf8Iterator,
    pending_low: ?u16 = null,

    fn init(s: []const u8) Utf16Cursor {
        return .{ .it = std.unicode.Utf8View.initUnchecked(s).iterator() };
    }

    fn next(self: *Utf16Cursor) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        const cp = self.it.nextCodepoint() orelse return null;
        if (cp <= 0xFFFF) return @intCast(cp);
        const adjusted = cp - 0x10000;
        const high: u16 = @intCast(0xD800 + (adjusted >> 10));
        self.pending_low = @intCast(0xDC00 + (adjusted & 0x3FF));
        return high;
    }
};

/// Lexicographic compare in UTF-16 code units to match Kotlin's
/// `String.compareTo`.
fn utf16Cmp(left: []const u8, right: []const u8) std.math.Order {
    var lc = Utf16Cursor.init(left);
    var rc = Utf16Cursor.init(right);
    while (true) {
        const lu = lc.next();
        const ru = rc.next();
        if (lu == null and ru == null) return .eq;
        if (lu == null) return .lt;
        if (ru == null) return .gt;
        if (lu.? < ru.?) return .lt;
        if (lu.? > ru.?) return .gt;
    }
}

fn arithExc(allocator: Allocator, msg: []const u8) Allocator.Error!EvalError {
    return .{ .Throw = .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, "kotlin.ArithmeticException"),
        .message = try runtime.strInit(allocator, msg),
        .cause = null,
    } } };
}

/// Kotlin's defined numeric conversions and operator semantics.
pub fn applyBinop(allocator: Allocator, op: BinOp, l: *const Value, r: *const Value) Allocator.Error!EvalResult {
    // Kotlin promotes `Byte`/`Short` to `Int` in arithmetic and
    // comparison. Widen and re-dispatch.
    if ((promoteByteShort(l) != null or promoteByteShort(r) != null) and op != .StringConcat) {
        const nl = promoteByteShort(l) orelse l.*;
        const nr = promoteByteShort(r) orelse r.*;
        return applyBinop(allocator, op, &nl, &nr);
    }
    // Kotlin promotes UByte/UShort to UInt in arithmetic and comparison.
    if ((promoteUByteUShort(l) != null or promoteUByteUShort(r) != null) and op != .StringConcat) {
        const nl = promoteUByteUShort(l) orelse l.*;
        const nr = promoteUByteUShort(r) orelse r.*;
        return applyBinop(allocator, op, &nl, &nr);
    }
    // Float comparisons widen the Float operand to Double and
    // re-dispatch.
    if ((op == .Less or op == .LessEq or op == .Greater or op == .GreaterEq) and
        (l.* == .Float or r.* == .Float))
    {
        const nl = widenFloat(l);
        const nr = widenFloat(r);
        return applyBinop(allocator, op, &nl, &nr);
    }
    switch (op) {
        .Add => {
            if (l.* == .Int and r.* == .Int) return ok(.{ .Int = l.Int +% r.Int });
            if (l.* == .Char and r.* == .Int) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) +% @as(i64, r.Int)))) });
            if (l.* == .Char and r.* == .Long) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) +% r.Long))) });
            if (l.* == .Long and r.* == .Long) return ok(.{ .Long = l.Long +% r.Long });
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = l.Long +% @as(i64, r.Int) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = @as(i64, l.Int) +% r.Long });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double + @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) + r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double + @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) + r.Double });
            if (l.* == .UInt and r.* == .UInt) return ok(.{ .UInt = l.UInt +% r.UInt });
            if (l.* == .ULong and r.* == .ULong) return ok(.{ .ULong = l.ULong +% r.ULong });
            if (l.* == .ULong and r.* == .UInt) return ok(.{ .ULong = l.ULong +% @as(u64, r.UInt) });
            if (l.* == .UInt and r.* == .ULong) return ok(.{ .ULong = @as(u64, l.UInt) +% r.ULong });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float + r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) + r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double + @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) + r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float + @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) + r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float + @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double + r.Double });
            if (l.* == .String) {
                const g = l.String.borrow();
                defer g.deinit();
                const rs = try renderValue(allocator, r);
                defer allocator.free(rs);
                const s = try std.mem.concat(allocator, u8, &.{ g.get().bytes, rs });
                return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
            }
            if (r.* == .String) {
                const ls = try renderValue(allocator, l);
                defer allocator.free(ls);
                const g = r.String.borrow();
                defer g.deinit();
                const s = try std.mem.concat(allocator, u8, &.{ ls, g.get().bytes });
                return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
            }
        },
        .Sub => {
            if (l.* == .Int and r.* == .Int) return ok(.{ .Int = l.Int -% r.Int });
            if (l.* == .Char and r.* == .Char) return ok(.{ .Int = @as(i32, l.Char) - @as(i32, r.Char) });
            if (l.* == .Char and r.* == .Int) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) -% @as(i64, r.Int)))) });
            if (l.* == .Char and r.* == .Long) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) -% r.Long))) });
            if (l.* == .Long and r.* == .Long) return ok(.{ .Long = l.Long -% r.Long });
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = l.Long -% @as(i64, r.Int) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = @as(i64, l.Int) -% r.Long });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double - @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) - r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double - @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) - r.Double });
            if (l.* == .UInt and r.* == .UInt) return ok(.{ .UInt = l.UInt -% r.UInt });
            if (l.* == .ULong and r.* == .ULong) return ok(.{ .ULong = l.ULong -% r.ULong });
            if (l.* == .ULong and r.* == .UInt) return ok(.{ .ULong = l.ULong -% @as(u64, r.UInt) });
            if (l.* == .UInt and r.* == .ULong) return ok(.{ .ULong = @as(u64, l.UInt) -% r.ULong });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float - r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) - r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double - @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) - r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float - @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) - r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float - @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double - r.Double });
        },
        .Mul => {
            if (l.* == .Int and r.* == .Int) return ok(.{ .Int = l.Int *% r.Int });
            if (l.* == .Long and r.* == .Long) return ok(.{ .Long = l.Long *% r.Long });
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = l.Long *% @as(i64, r.Int) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = @as(i64, l.Int) *% r.Long });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double * @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) * r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double * @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) * r.Double });
            if (l.* == .UInt and r.* == .UInt) return ok(.{ .UInt = l.UInt *% r.UInt });
            if (l.* == .ULong and r.* == .ULong) return ok(.{ .ULong = l.ULong *% r.ULong });
            if (l.* == .ULong and r.* == .UInt) return ok(.{ .ULong = l.ULong *% @as(u64, r.UInt) });
            if (l.* == .UInt and r.* == .ULong) return ok(.{ .ULong = @as(u64, l.UInt) *% r.ULong });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float * r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) * r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double * @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) * r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float * @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) * r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float * @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double * r.Double });
        },
        .Div => {
            if (l.* == .Long and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = divTruncI64(l.Long, r.Long) });
            }
            if (l.* == .Int and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Int = divTruncI32(l.Int, r.Int) });
            }
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = divTruncI64(l.Long, @as(i64, r.Int)) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = divTruncI64(@as(i64, l.Int), r.Long) });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double / @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) / r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double / @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) / r.Double });
            if (l.* == .UInt and r.* == .UInt) {
                if (r.UInt == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .UInt = l.UInt / r.UInt });
            }
            if (l.* == .ULong and r.* == .ULong) {
                if (r.ULong == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .ULong = l.ULong / r.ULong });
            }
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float / r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) / r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double / @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) / r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float / @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) / r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float / @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double / r.Double });
        },
        .Mod => {
            if (l.* == .Long and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = remTruncI64(l.Long, r.Long) });
            }
            if (l.* == .Int and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Int = remTruncI32(l.Int, r.Int) });
            }
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = remTruncI64(l.Long, @as(i64, r.Int)) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = remTruncI64(@as(i64, l.Int), r.Long) });
            if (l.* == .UInt and r.* == .UInt) {
                if (r.UInt == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .UInt = l.UInt % r.UInt });
            }
            if (l.* == .ULong and r.* == .ULong) {
                if (r.ULong == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .ULong = l.ULong % r.ULong });
            }
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = @rem(l.Double, @as(f64, @floatFromInt(r.Long))) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @rem(@as(f64, @floatFromInt(l.Long)), r.Double) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = @rem(l.Double, r.Double) });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = @rem(l.Double, @as(f64, @floatFromInt(r.Int))) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @rem(@as(f64, @floatFromInt(l.Int)), r.Double) });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = @rem(l.Float, r.Float) });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @rem(@as(f64, l.Float), r.Double) });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = @rem(l.Double, @as(f64, r.Float)) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @rem(@as(f32, @floatFromInt(l.Int)), r.Float) });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = @rem(l.Float, @as(f32, @floatFromInt(r.Int))) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @rem(@as(f32, @floatFromInt(l.Long)), r.Float) });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = @rem(l.Float, @as(f32, @floatFromInt(r.Long))) });
        },
        .Eq, .NotEq, .BoxedEq, .BoxedNotEq => {
            // A boxed capture compares by its CONTENT: the Cell is a
            // carrier (an anon-object method's captured outer `var`),
            // never a user value.
            var lc = l.*;
            while (lc == .Cell) {
                const cg = lc.Cell.borrow();
                lc = cg.get().*;
                cg.deinit();
            }
            var rc = r.*;
            while (rc == .Cell) {
                const cg = rc.Cell.borrow();
                rc = cg.get().*;
                cg.deinit();
            }

            // Mixed-width unsigned equality compares by magnitude
            // (`0u == 0uL`); same-tag and signed paths keep structural equality.
            // Mirrors the relational `compareValues` unsigned reconciliation.
            if (std.meta.activeTag(lc) != std.meta.activeTag(rc)) {
                if (asUnsigned(&lc)) |lu| {
                    if (asUnsigned(&rc)) |ru| {
                        const eq = lu == ru;
                        const neg = op == .NotEq or op == .BoxedNotEq;
                        return ok(.{ .Bool = if (neg) !eq else eq });
                    }
                }
                // Mixed-width SIGNED integer equality compares by numeric value:
                // Kotlin promotes `1 == 1L`. This also reconciles a value whose
                // Long type came from a widened Int literal against a real Long
                // (`const val X: LongAlias = -1` vs a Long `-1`). Boxed `Any`
                // equality is EXCLUDED: `(1 as Any) != (1L as Any)` in Kotlin,
                // so those keep the tag-sensitive structural comparison.
                if (op == .Eq or op == .NotEq) {
                    if (asSignedI64(&lc)) |ls| {
                        if (asSignedI64(&rc)) |rs| {
                            const eq = ls == rs;
                            return ok(.{ .Bool = if (op == .NotEq) !eq else eq });
                        }
                    }
                }
            }
            const eq = if (op == .BoxedEq or op == .BoxedNotEq)
                Value.structuralEqBoxed(&lc, &rc)
            else
                Value.structuralEq(&lc, &rc);
            const neg = op == .NotEq or op == .BoxedNotEq;
            return ok(.{ .Bool = if (neg) !eq else eq });
        },
        .Less, .LessEq, .Greater, .GreaterEq => {
            if (try compareValues(op, l, r)) |b| return ok(.{ .Bool = b });
        },
        .And => {
            if (l.* == .Bool and r.* == .Bool) return ok(.{ .Bool = l.Bool and r.Bool });
        },
        .Or => {
            if (l.* == .Bool and r.* == .Bool) return ok(.{ .Bool = l.Bool or r.Bool });
        },
        .RangeTo, .RangeUntil => {
            if (rangeValue(op, l, r)) |v| return ok(v);
        },
        .StringConcat => {
            const ls = try renderValue(allocator, l);
            defer allocator.free(ls);
            const rs = try renderValue(allocator, r);
            defer allocator.free(rs);
            const s = try std.mem.concat(allocator, u8, &.{ ls, rs });
            return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
        },
        else => {},
    }
    const lstr = l.display(allocator) catch "?";
    const rstr = r.display(allocator) catch "?";
    const msg = try std.fmt.allocPrint(allocator, "BinOp.{s} on {s} and {s}", .{ @tagName(op), lstr, rstr });
    return errResult(.{ .Type = msg });
}

/// Comparison dispatch for `<`, `<=`, `>`, `>=`. Returns `null` for an
/// unhandled operand pairing.
fn asUnsigned(v: *const Value) ?u64 {
    return switch (v.*) {
        .UByte => |x| x,
        .UShort => |x| x,
        .UInt => |x| x,
        .ULong => |x| x,
        else => null,
    };
}

fn asSignedI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Byte => |x| x,
        .Short => |x| x,
        .Int => |x| x,
        .Long => |x| x,
        else => null,
    };
}

/// Order an unsigned `u` against a signed `s`: any negative `s` is below `u`.
fn cmpU64I64(u: u64, s: i64) std.math.Order {
    if (s < 0) return .gt;
    return std.math.order(u, @as(u64, @intCast(s)));
}

fn invertOrder(o: std.math.Order) std.math.Order {
    return switch (o) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

fn compareValues(op: BinOp, l: *const Value, r: *const Value) Allocator.Error!?bool {
    const Pair = struct {
        fn cmpOrder(o: BinOp, order: std.math.Order) bool {
            return switch (o) {
                .Less => order == .lt,
                .LessEq => order != .gt,
                .Greater => order == .gt,
                .GreaterEq => order != .lt,
                else => unreachable,
            };
        }
        // The relational operators `<` `<=` `>` `>=` on concrete Double/Float
        // follow IEEE-754: any comparison involving a NaN is false. Zig's
        // native float operators already honor this, so compare directly
        // instead of going through `std.math.order` (which asserts non-NaN).
        fn cmpFloat(o: BinOp, a: f64, b: f64) bool {
            return switch (o) {
                .Less => a < b,
                .LessEq => a <= b,
                .Greater => a > b,
                .GreaterEq => a >= b,
                else => unreachable,
            };
        }
    };
    if (l.* == .Int and r.* == .Int) return Pair.cmpOrder(op, std.math.order(l.Int, r.Int));
    if (l.* == .Long and r.* == .Long) return Pair.cmpOrder(op, std.math.order(l.Long, r.Long));
    if (l.* == .Double and r.* == .Double) return Pair.cmpFloat(op, l.Double, r.Double);
    if (l.* == .Float and r.* == .Float) return Pair.cmpFloat(op, @as(f64, l.Float), @as(f64, r.Float));
    if (l.* == .Char and r.* == .Char) return Pair.cmpOrder(op, std.math.order(l.Char, r.Char));
    // `Boolean` is `Comparable`: `false < true` (compareTo ordinal order).
    if (l.* == .Bool and r.* == .Bool) return Pair.cmpOrder(op, std.math.order(@intFromBool(l.Bool), @intFromBool(r.Bool)));
    if (l.* == .UInt and r.* == .UInt) return Pair.cmpOrder(op, std.math.order(l.UInt, r.UInt));
    if (l.* == .ULong and r.* == .ULong) return Pair.cmpOrder(op, std.math.order(l.ULong, r.ULong));
    if (l.* == .UShort and r.* == .UShort) return Pair.cmpOrder(op, std.math.order(l.UShort, r.UShort));
    if (l.* == .UByte and r.* == .UByte) return Pair.cmpOrder(op, std.math.order(l.UByte, r.UByte));
    // Mixed Int/Long.
    if (l.* == .Int and r.* == .Long) return Pair.cmpOrder(op, std.math.order(@as(i64, l.Int), r.Long));
    if (l.* == .Long and r.* == .Int) return Pair.cmpOrder(op, std.math.order(l.Long, @as(i64, r.Int)));
    // Mixed-width unsigned (`ULong` vs `UInt`, etc.) compare by magnitude.
    if (asUnsigned(l)) |lu| {
        if (asUnsigned(r)) |ru| return Pair.cmpOrder(op, std.math.order(lu, ru));
        // Mixed unsigned / signed: a negative signed value is below every
        // unsigned value; otherwise compare magnitudes. (kotlinc coerces the
        // literal, but a bare pairing still has a well-defined numeric order.)
        if (asSignedI64(r)) |ri| return Pair.cmpOrder(op, cmpU64I64(lu, ri));
    }
    if (asUnsigned(r)) |ru| {
        if (asSignedI64(l)) |li| return Pair.cmpOrder(op, invertOrder(cmpU64I64(ru, li)));
    }
    // Mixed with Double (IEEE relational semantics: the Double side may be NaN).
    if (l.* == .Int and r.* == .Double) return Pair.cmpFloat(op, @as(f64, @floatFromInt(l.Int)), r.Double);
    if (l.* == .Double and r.* == .Int) return Pair.cmpFloat(op, l.Double, @as(f64, @floatFromInt(r.Int)));
    if (l.* == .Long and r.* == .Double) return Pair.cmpFloat(op, @as(f64, @floatFromInt(l.Long)), r.Double);
    if (l.* == .Double and r.* == .Long) return Pair.cmpFloat(op, l.Double, @as(f64, @floatFromInt(r.Long)));
    if (l.* == .String and r.* == .String) {
        const lg = l.String.borrow();
        defer lg.deinit();
        const rg = r.String.borrow();
        defer rg.deinit();
        return Pair.cmpOrder(op, utf16Cmp(lg.get().bytes, rg.get().bytes));
    }
    return null;
}

/// Build a `Range` value for `..` / `..<`. Returns `null` for unhandled
/// operand pairings.
fn rangeValue(op: BinOp, l: *const Value, r: *const Value) ?Value {
    // Resolve the operand pairing to (start, end-bound, kind). UByte/UShort
    // promote to a UInt range, mirroring Kotlin's `UByte.rangeTo` etc.
    var start: i64 = undefined;
    var bound: i64 = undefined;
    var kind: RangeKind = undefined;
    if (l.* == .Int and r.* == .Int) {
        start = l.Int;
        bound = r.Int;
        kind = .Int;
    } else if (l.* == .Char and r.* == .Char) {
        start = l.Char;
        bound = r.Char;
        kind = .Char;
    } else if (l.* == .Long and r.* == .Long) {
        start = l.Long;
        bound = r.Long;
        kind = .Long;
    } else if (l.* == .Int and r.* == .Long) {
        start = l.Int;
        bound = r.Long;
        kind = .Long;
    } else if (l.* == .Long and r.* == .Int) {
        start = l.Long;
        bound = r.Int;
        kind = .Long;
    } else if (l.* == .ULong and r.* == .ULong) {
        start = @bitCast(l.ULong);
        bound = @bitCast(r.ULong);
        kind = .ULong;
    } else if (smallUnsigned(l)) |lu| {
        const ru = smallUnsigned(r) orelse return null;
        start = lu;
        bound = ru;
        kind = .UInt;
    } else return null;

    if (op == .RangeUntil) {
        // `a ..< MIN_VALUE` is empty -> the kind's EMPTY range; otherwise the
        // inclusive end is one before the exclusive bound.
        if (kind.untilEmpty(bound)) {
            const e = kind.emptyBounds();
            return .{ .Range = .{ .start = e[0], .end = e[1], .step = 1, .kind = kind } };
        }
        bound -= 1;
    }
    return .{ .Range = .{ .start = start, .end = bound, .step = 1, .kind = kind } };
}

/// A UByte/UShort/UInt value as an i64 (for forming a UInt range), else null.
fn smallUnsigned(v: *const Value) ?i64 {
    return switch (v.*) {
        .UByte => |x| @as(i64, x),
        .UShort => |x| @as(i64, x),
        .UInt => |x| @as(i64, x),
        else => null,
    };
}

fn promoteByteShort(v: *const Value) ?Value {
    return switch (v.*) {
        .Byte => |b| .{ .Int = @as(i32, b) },
        .Short => |s| .{ .Int = @as(i32, s) },
        else => null,
    };
}

fn promoteUByteUShort(v: *const Value) ?Value {
    return switch (v.*) {
        .UByte => |b| .{ .UInt = @as(u32, b) },
        .UShort => |s| .{ .UInt = @as(u32, s) },
        else => null,
    };
}

fn widenFloat(v: *const Value) Value {
    return switch (v.*) {
        .Float => |f| .{ .Double = @as(f64, f) },
        else => v.*,
    };
}

/// Truncating integer division with `MIN / -1` wrapping to `MIN`.
fn divTruncI64(a: i64, b: i64) i64 {
    if (a == std.math.minInt(i64) and b == -1) return std.math.minInt(i64);
    return @divTrunc(a, b);
}

fn divTruncI32(a: i32, b: i32) i32 {
    if (a == std.math.minInt(i32) and b == -1) return std.math.minInt(i32);
    return @divTrunc(a, b);
}

fn remTruncI64(a: i64, b: i64) i64 {
    if (a == std.math.minInt(i64) and b == -1) return 0;
    return @rem(a, b);
}

fn remTruncI32(a: i32, b: i32) i32 {
    if (a == std.math.minInt(i32) and b == -1) return 0;
    return @rem(a, b);
}

// -------------------------------------------------------------------------
// Host — the pluggable dispatch trait the evaluator delegates through.
// -------------------------------------------------------------------------

/// `Result<Option<Value>, EvalError>` for `lookup_global_throwing` /
/// `call_named_overload`.
pub const MaybeValueResult = union(enum) {
    ok: ?Value,
    err: EvalError,
};

/// `Result<(), EvalError>` for the side-effecting host calls.
pub const UnitResult = union(enum) {
    ok: void,
    err: EvalError,
};

/// `(n_params, first_param_is_this)` shape report for a callable.
pub const ReceiverShape = struct { n_params: usize, first_is_this: bool };

/// No-op host for ir's own unit tests and IR-shape exercises, and the
/// default host for the bare `eval` entry. A concrete second host type
/// alongside the interpreter's `VmHost`: every method is the trait-default
/// the old vtable returned when a slot was `null`
/// (`Unsupported`/`null`/`false`/empty). The evaluator is generic over the
/// host type and calls these as plain comptime-duck-typed methods.
pub const NullHost = struct {
    pub fn callValue(self: *NullHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, callee, args };
        return errResult(.{ .Unsupported = "Host.call_value" });
    }

    pub fn callValueNamed(self: *NullHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = arg_names;
        return self.callValue(allocator, callee, args);
    }

    pub fn callMember(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, name, args };
        return errResult(.{ .Unsupported = "Host.call_member" });
    }

    pub fn callMemberNamed(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = arg_names;
        return self.callMember(allocator, receiver, name, args);
    }

    pub fn committedExtReceiverProven(self: *NullHost, allocator: Allocator, fid: FuncId, recv: *const Value) bool {
        _ = self;
        _ = allocator;
        _ = fid;
        _ = recv;
        return false;
    }
    pub fn committedExtReceiverDisproven(self: *NullHost, fid: FuncId, recv: *const Value) bool {
        _ = self;
        _ = fid;
        _ = recv;
        return true;
    }
    pub fn callMemberMembersOnlyLenient(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }
    pub fn callMemberMembersOnly(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }
    pub fn callMemberStrictExt(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }

    pub fn callMemberNamedDeclared(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = declared_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }
    pub fn callMemberNamedStatic(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }

    pub fn hostHasMember(self: *NullHost, receiver: *const Value, name: []const u8) bool {
        _ = .{ self, receiver, name };
        return false;
    }

    pub fn hostHasProperty(self: *NullHost, receiver: *const Value, name: []const u8) bool {
        _ = .{ self, receiver, name };
        return false;
    }

    pub fn hostHasExtPropSetter(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) bool {
        _ = .{ self, allocator, receiver, name };
        return false;
    }

    pub fn companionWithMember(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?Value {
        _ = .{ self, allocator, receiver, name };
        return null;
    }

    pub fn declaringClassSimpleName(self: *NullHost, module: *const Module, fid: ir.FuncId) ?[]const u8 {
        _ = self;
        return declaringClassName(module, fid);
    }

    pub fn newInstance(self: *NullHost, allocator: Allocator, class: ClassId, args: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, class, args };
        return errResult(.{ .Unsupported = "Host.new_instance" });
    }

    pub fn newInstanceNamed(self: *NullHost, allocator: Allocator, class: ClassId, args: []const Value, arg_names: []const ?[]const u8, outer_hint: ?*const Value) Allocator.Error!EvalResult {
        _ = .{ arg_names, outer_hint };
        return self.newInstance(allocator, class, args);
    }

    pub fn getMemberField(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
        _ = self;
        // Strict probe contract: a miss is an error, never a spurious
        // `Null`/`Unit` value, so the walk's candidate order stays honest.
        if (receiver.* == .Instance) {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            if (g.get().get(name)) |v| return ok(v);
        }
        const msg = try std.fmt.allocPrint(allocator, "no member `{s}`", .{name});
        return errResult(.{ .Unimplemented = msg });
    }

    pub fn getField(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
        _ = self;
        switch (receiver.*) {
            .Instance => |inst| {
                const g = inst.borrow();
                defer g.deinit();
                return ok(g.get().get(name) orelse Value.Null);
            },
            else => {
                const s = receiver.display(allocator) catch "?";
                const msg = try std.fmt.allocPrint(allocator, "GetField on non-instance: {s}", .{s});
                return errResult(.{ .Type = msg });
            },
        }
    }

    /// The bare-IR host has no class table, so a `super.prop = v` write has
    /// nothing to walk past: store the field.
    pub fn setFieldFrom(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value, super_owner: ?[]const u8) Allocator.Error!UnitResult {
        _ = super_owner;
        return setField(self, allocator, receiver, name, value);
    }

    pub fn setField(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
        _ = self;
        switch (receiver.*) {
            .Instance => |inst| {
                const g = inst.borrowMut();
                defer g.deinit();
                try g.get().define(allocator, name, value);
                return .{ .ok = {} };
            },
            .Null => return .{ .ok = {} },
            else => {
                const s = receiver.display(allocator) catch "?";
                const msg = try std.fmt.allocPrint(allocator, "SetField on non-instance: {s}", .{s});
                return .{ .err = .{ .Type = msg } };
            },
        }
    }

    pub fn instanceOf(self: *NullHost, value: *const Value, ty: TypeRef) bool {
        _ = self;
        const nominal = value.typeFqn();
        if (std.mem.eql(u8, nominal, ty.name)) return true;
        // nominal.ends_with(".{ty.name}")
        if (nominal.len > ty.name.len + 1 and
            nominal[nominal.len - ty.name.len - 1] == '.' and
            std.mem.eql(u8, nominal[nominal.len - ty.name.len ..], ty.name))
        {
            return true;
        }
        return false;
    }

    pub fn isConcreteCastTarget(self: *NullHost, name: []const u8) bool {
        _ = .{ self, name };
        return true;
    }

    pub fn lookupGlobal(self: *NullHost, name: []const u8) ?Value {
        _ = .{ self, name };
        return null;
    }

    pub fn lookupGlobalThrowing(self: *NullHost, allocator: Allocator, name: []const u8) Allocator.Error!MaybeValueResult {
        _ = allocator;
        return .{ .ok = self.lookupGlobal(name) };
    }

    pub fn lookupGlobalById(self: *NullHost, allocator: Allocator, func: ?FuncId, class: ?ClassId, ctor_ref: bool) ?Value {
        _ = ctor_ref;
        _ = .{ self, allocator, func, class };
        return null;
    }

    pub fn storeGlobal(self: *NullHost, allocator: Allocator, name: []const u8, value: Value) Allocator.Error!UnitResult {
        _ = .{ self, allocator, name, value };
        return .{ .err = .{ .Unsupported = "Host.store_global" } };
    }

    pub fn registerClass(self: *NullHost, allocator: Allocator, class: *const @import("ast").Class) Allocator.Error!UnitResult {
        _ = .{ self, allocator, class };
        return .{ .err = .{ .Unsupported = "Host.register_class" } };
    }

    pub fn registerClassCaptured(self: *NullHost, allocator: Allocator, class: *const @import("ast").Class, captured_names: []const []const u8, captures: []const Value) Allocator.Error!UnitResult {
        _ = .{ captured_names, captures };
        return self.registerClass(allocator, class);
    }

    pub fn buildObject(self: *NullHost, allocator: Allocator, ast: *const @import("ast").Expr, captured_names: []const []const u8, captures: []const Value, scope_renames: []const ir.ScopeRename, scope_classes: []const ir.ScopeClassRef) Allocator.Error!EvalResult {
        _ = .{ self, allocator, ast, captured_names, captures, scope_renames, scope_classes };
        return errResult(.{ .Unsupported = "Host.build_object" });
    }

    pub fn callValueWithThis(self: *NullHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, callee, this_value, args, arg_names };
        return errResult(.{ .Unsupported = "Host.call_value_with_this" });
    }

    pub fn callValueWithThisExact(self: *NullHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        return self.callValueWithThis(allocator, callee, this_value, args, arg_names);
    }

    pub fn callSuper(self: *NullHost, allocator: Allocator, receiver: *const Value, owner_class: []const u8, qualifier: ?[]const u8, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, owner_class, qualifier, name, args, arg_names };
        return errResult(.{ .Unsupported = "Host.call_super" });
    }

    pub fn qualifiedThis(self: *NullHost, allocator: Allocator, receiver: *const Value, qualifier: []const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, qualifier };
        return errResult(.{ .Unsupported = "Host.qualified_this" });
    }

    pub fn memberRef(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, name };
        return errResult(.{ .Unsupported = "Host.member_ref" });
    }

    pub fn memberRefExact(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, func: FuncId) Allocator.Error!EvalResult {
        _ = func;
        return self.memberRef(allocator, receiver, name);
    }

    pub fn buildClosure(self: *NullHost, allocator: Allocator, module: *const Module, body_func: FuncId, captures: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, module, body_func, captures };
        return errResult(.{ .Unsupported = "Host.build_closure" });
    }

    pub fn buildAstLambda(self: *NullHost, allocator: Allocator, params: []const []const u8, body: *const @import("ast").Block, captured_names: []const []const u8, captures: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, params, body, captured_names, captures };
        return errResult(.{ .Unsupported = "Host.build_ast_lambda" });
    }

    pub fn buildAstLambdaWithFlag(self: *NullHost, allocator: Allocator, params: []const []const u8, body: *const @import("ast").Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool) Allocator.Error!EvalResult {
        _ = absorb_return;
        return self.buildAstLambda(allocator, params, body, captured_names, captures);
    }

    pub fn buildAstLambdaWithFlagFuncid(self: *NullHost, allocator: Allocator, module: *const Module, params: []const []const u8, body: *const @import("ast").Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool, body_func: ?FuncId) Allocator.Error!EvalResult {
        _ = .{ module, body_func };
        return self.buildAstLambdaWithFlag(allocator, params, body, captured_names, captures, absorb_return);
    }

    pub fn callFunc(self: *NullHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value) Allocator.Error!EvalResult {
        _ = self;
        const f = module.funcById(func) orelse {
            const msg = try std.fmt.allocPrint(allocator, "unknown FuncId {d}", .{func.int()});
            return errResult(.{ .Type = msg });
        };
        var args_list: std.ArrayList(Value) = .empty;
        try args_list.appendSlice(allocator, args);
        return eval(allocator, module, f, args_list);
    }

    pub fn callFuncNamed(self: *NullHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = arg_names;
        return self.callFunc(allocator, module, func, args);
    }

    pub fn callFuncTyped(self: *NullHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
        _ = .{ type_args, exact };
        return self.callFuncNamed(allocator, module, func, args, arg_names);
    }

    pub fn callNamedOverload(self: *NullHost, allocator: Allocator, module: *const Module, candidates: ?[]const FuncId, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, ctor_class: ?ir.ClassId, ctor_name: bool, caller_pkg: []const u8, caller_file: ?ir.FileId, synth_anchor_pkg: []const u8) Allocator.Error!MaybeValueResult {
        _ = caller_pkg;
        _ = caller_file;
        _ = synth_anchor_pkg;
        _ = .{ self, allocator, module, candidates, name, args, arg_names, ctor_class, ctor_name };
        return .{ .ok = null };
    }

    pub fn pickNamedOverloadId(self: *NullHost, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, recv_external: bool) ?FuncId {
        _ = .{ self, module, args, arg_names, recv_external };
        _ = func;
        return null;
    }

    pub fn bareUnsettledHeaderNoOp(self: *NullHost, module: *const Module, name: []const u8, argc: usize) bool {
        _ = .{ self, module, name, argc };
        return false;
    }

    pub fn callableAcceptsCall(self: *NullHost, v: *const Value, recv: *const Value, args2: []const Value, arg_names2: []const ?[]const u8) ?bool {
        _ = .{ self, v, recv, args2, arg_names2 };
        return null;
    }

    pub fn callableAcceptsArgs(self: *NullHost, v: *const Value, n_args: usize) ?bool {
        _ = .{ self, v, n_args };
        return null;
    }

    pub fn callValueNamedTyped(self: *NullHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8) Allocator.Error!EvalResult {
        _ = type_args;
        return self.callValueNamed(allocator, callee, args, arg_names);
    }

    pub fn collectionsEqualHostAware(self: *NullHost, allocator: Allocator, a: *const Value, b: *const Value) ?bool {
        _ = .{ self, allocator, a, b };
        return null;
    }

    pub fn callableReceiverShape(self: *NullHost, v: *const Value) ?ReceiverShape {
        _ = .{ self, v };
        return null;
    }

    pub fn closureNeedsThisCapture(self: *NullHost, v: *const Value) bool {
        _ = .{ self, v };
        return false;
    }

    pub fn overrideClosureThis(self: *NullHost, v: *const Value, new_this: *const Value) void {
        _ = .{ self, v, new_this };
    }

    pub fn isShadowingCapture(self: *NullHost, name: []const u8) bool {
        _ = .{ self, name };
        return false;
    }
};

pub fn nullHost() NullHost {
    return .{};
}

const testing = std.testing;
const FuncBuilder = ir.build.FuncBuilder;

/// Free a `Func` produced by `finish` in a test.
fn freeFunc(func: Func) void {
    for (func.blocks) |b| {
        if (b.insts.len != 0) testing.allocator.free(b.insts);
        if (b.catches.len != 0) testing.allocator.free(b.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

fn lit(b: *FuncBuilder, v: i32) Allocator.Error!Reg {
    return b.emitConst(.{ .Int = v });
}

test "eval_int_const" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = try lit(&b, 7);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    const res = try eval(testing.allocator, &m, &func, .empty);
    try testing.expect(res == .ok);
    try testing.expect(res.ok == .Int and res.ok.Int == 7);
}

test "eval reports a bodyless function instead of indexing empty blocks" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = try lit(&b, 7);
    b.terminate(.{ .Return = r });
    var func = try b.finish("missing", "test.missing", ir.build.typeInt());
    const blocks = func.blocks;
    defer {
        func.blocks = blocks;
        freeFunc(func);
    }
    func.blocks = &.{};

    const result = try eval(testing.allocator, &m, &func, .empty);
    try testing.expect(result == .err);
    try testing.expect(result.err == .CalleeFailed);
    try testing.expectEqualStrings("virtual method target is not executable", result.err.CalleeFailed);
}

test "eval_int_add" {
    var module = Module.default(testing.allocator);
    defer module.deinit(testing.allocator);
    var builder = try FuncBuilder.init(testing.allocator, &module);
    defer builder.deinit();
    const lhs = try lit(&builder, 2);
    const rhs = try lit(&builder, 40);
    const dst = builder.allocReg();
    try builder.push(.{ .BinOp = .{ .dst = dst, .op = .Add, .lhs = lhs, .rhs = rhs } });
    builder.terminate(.{ .Return = dst });
    const func = try builder.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    const result = try eval(testing.allocator, &module, &func, .empty);
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .Int and result.ok.Int == 42);
}

test "eval_load_param" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const p = b.allocReg();
    try b.push(.{ .LoadParam = .{ .dst = p, .idx = 0 } });
    b.terminate(.{ .Return = p });
    const func = try b.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    var args: std.ArrayList(Value) = .empty;
    try args.append(testing.allocator, .{ .Int = 99 });
    const v = try eval(testing.allocator, &m, &func, args);
    try testing.expect(v == .ok);
    try testing.expect(v.ok == .Int and v.ok.Int == 99);
}

test "eval_branch" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const cond = try b.emitConst(.{ .Bool = true });
    const t_blk = try b.allocBlock();
    const f_blk = try b.allocBlock();
    b.terminate(.{ .Branch = .{ .cond = cond, .t = t_blk, .f = f_blk } });

    b.switchTo(t_blk);
    const t_val = try lit(&b, 1);
    b.terminate(.{ .Return = t_val });

    b.switchTo(f_blk);
    const f_val = try lit(&b, 0);
    b.terminate(.{ .Return = f_val });

    const func = try b.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    const v = try eval(testing.allocator, &m, &func, .empty);
    try testing.expect(v == .ok);
    try testing.expect(v.ok == .Int and v.ok.Int == 1);
}

test "suspend liveness keeps only values read on reachable resume paths" {
    resetSuspendLivenessCache();
    defer resetSuspendLivenessCache();

    const entry_insts = [_]Inst{
        .{ .Const = .{ .dst = .from(0), .value = .from(0) } },
        .{ .Const = .{ .dst = .from(1), .value = .from(1) } },
        .{ .Move = .{ .dst = .from(2), .src = .from(0) } },
        .{ .Const = .{ .dst = .from(3), .value = .from(2) } },
    };
    const blocks = [_]ir.Block{
        .{
            .id = .from(0),
            .insts = @constCast(&entry_insts),
            .terminator = .{ .Branch = .{ .cond = .from(2), .t = .from(1), .f = .from(2) } },
        },
        .{ .id = .from(1), .insts = &.{}, .terminator = .{ .Return = .from(0) } },
        .{ .id = .from(2), .insts = &.{}, .terminator = .{ .Return = .from(1) } },
    };
    const func: Func = .{
        .id = .from(0),
        .name = "resumePaths",
        .fqn = "test.resumePaths",
        .params = &.{},
        .return_ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .n_locals = 4,
        .blocks = @constCast(&blocks),
        .entry = .from(0),
        .is_suspend = true,
    };

    // Resuming before the move needs both branch results, but neither the
    // move's destination nor the dead fourth register.
    const before_move = try suspendLiveRegs(&func, .from(0), 2);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, before_move);
    // At the terminator the branch condition is also live.
    const before_term = try suspendLiveRegs(&func, .from(0), entry_insts.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, before_term);
}

test "resumed labeled return reaches its snapshotted target frame" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);

    const inner_blocks = [_]ir.Block{.{
        .id = .from(0),
        .insts = &.{},
        .terminator = .{ .LabeledReturn = .{
            .label = "hasNext",
            .value = .from(0),
        } },
    }};
    const outer_blocks = [_]ir.Block{.{
        .id = .from(0),
        .insts = &.{},
        .terminator = .{ .Return = .from(0) },
    }};
    try m.funcs.append(testing.allocator, .{
        .id = .from(0),
        .name = "<lambda>",
        .fqn = "test.hasNext.<lambda>",
        .params = &.{},
        .return_ty = ir.build.typeBool(),
        .n_locals = 1,
        .blocks = @constCast(&inner_blocks),
        .entry = .from(0),
        .is_suspend = false,
        .is_lambda = true,
    });
    try m.funcs.append(testing.allocator, .{
        .id = .from(1),
        .name = "hasNext",
        .fqn = "test.hasNext",
        .params = &.{},
        .return_ty = ir.build.typeBool(),
        .n_locals = 1,
        .blocks = @constCast(&outer_blocks),
        .entry = .from(0),
        .is_suspend = true,
    });

    var state = SuspendState{ .token = 1 };
    const inner_regs = try testing.allocator.dupe(Value, &.{.{ .Bool = true }});
    const outer_regs = try testing.allocator.dupe(Value, &.{Value.Unit});
    const inner_params = try testing.allocator.alloc(Value, 0);
    const inner_captures = try testing.allocator.alloc(Value, 0);
    const inner_enclosing = try testing.allocator.alloc(EnclosingEntry, 0);
    const inner_try = try testing.allocator.alloc(TryFrame, 0);
    const outer_params = try testing.allocator.alloc(Value, 0);
    const outer_captures = try testing.allocator.alloc(Value, 0);
    const outer_enclosing = try testing.allocator.alloc(EnclosingEntry, 0);
    const outer_try = try testing.allocator.alloc(TryFrame, 0);
    try state.frames.append(testing.allocator, .{
        .func = .from(0),
        .module = null,
        .block = .from(0),
        .inst_idx = 0,
        .regs = .{ .dense = inner_regs },
        .params = inner_params,
        .captures = inner_captures,
        .enclosing_this = inner_enclosing,
        .try_stack = inner_try,
        .is_lambda = true,
        .resume_reg = null,
    });
    try state.frames.append(testing.allocator, .{
        .func = .from(1),
        .module = null,
        .block = .from(0),
        .inst_idx = 0,
        .regs = .{ .dense = outer_regs },
        .params = outer_params,
        .captures = outer_captures,
        .enclosing_this = outer_enclosing,
        .try_stack = outer_try,
        .is_lambda = false,
        .resume_reg = .from(0),
    });

    var host = nullHost();
    const result = try resumeContinuation(
        NullHost,
        testing.allocator,
        &m,
        &state,
        Value.Unit,
        &host,
    );
    // `resumeContinuation` consumes the frame list; clear the moved handle.
    state.frames = .empty;
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .Bool and result.ok.Bool);
}

test "enclosing chain tags subjects and projects innermost-first" {
    var chain: std.ArrayList(EnclosingEntry) = .empty;
    defer chain.deinit(chainAllocator());
    const prev = evtls.active_chain;
    evtls.active_chain = &chain;
    defer evtls.active_chain = prev;

    const receiver = Value{ .Int = 1 };
    const subject = Value{ .Int = 2 };
    pushEnclosing(&receiver);
    pushEnclosingSubject(&subject);

    // Value projection: innermost first, tags invisible.
    const vals = try enclosingThisChainAlloc(testing.allocator);
    defer testing.allocator.free(vals);
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expect(vals[0] == .Int and vals[0].Int == 2);
    try testing.expect(vals[1] == .Int and vals[1].Int == 1);
    try testing.expect(enclosingThisLast().? == .Int and enclosingThisLast().?.Int == 2);

    // Tagged projection: same order, push-site tags preserved.
    const entries = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expect(entries[0].isSubject() and entries[0].v.Int == 2);
    try testing.expect(!entries[1].isSubject() and entries[1].v.Int == 1);

    popEnclosing();
    const rest = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(rest);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expect(!rest[0].isSubject() and rest[0].v.Int == 1);
    popEnclosing();
    try testing.expectEqual(@as(usize, 0), chain.items.len);
}

test "enclosing chain pushes are dropped with no active frame" {
    const prev = evtls.active_chain;
    evtls.active_chain = null;
    defer evtls.active_chain = prev;

    const v = Value{ .Int = 7 };
    pushEnclosing(&v);
    pushEnclosingSubject(&v);
    popEnclosing();
    try testing.expect(enclosingThisLast() == null);
    const entries = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test {
    testing.refAllDecls(@This());
}
