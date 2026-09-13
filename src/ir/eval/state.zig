//! Per-thread evaluator state: frame chain, register/argument pools, GC roots.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

const BinOp = ir.BinOp;
const Const = ir.Const;
const Func = ir.Func;
const Module = ir.Module;
const UnOp = ir.UnOp;

const exec_call = @import("../exec_call.zig");

const callerThisValue = exec_call.callerThisValue;

const parent = @import("../eval.zig");
const ev_activation = @import("activation.zig");
const ev_chain = @import("chain.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_fused = @import("fused.zig");
const ev_snapshot = @import("snapshot.zig");

const ACT_POOL_MAX = ev_activation.ACT_POOL_MAX;
const Activation = ev_flow.Activation;
const CHAIN_POOL_MAX = ev_chain.CHAIN_POOL_MAX;
const FRAME_CENSUS_SLOTS = ev_diag.FRAME_CENSUS_SLOTS;
const FUSED_BANK_DEPTH = ev_fused.FUSED_BANK_DEPTH;
const FlatCallReq = ev_flow.FlatCallReq;
const Frame = ev_frame.Frame;
const FrameSnapshot = ev_snapshot.FrameSnapshot;
const SuspendState = ev_snapshot.SuspendState;
const TailSeg = ev_snapshot.TailSeg;
const cmgTraceWant = ev_flow.cmgTraceWant;
const fusedTls = ev_fused.fusedTls;
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

/// Activation-depth cap that turns runaway recursion into `StackOverflow`
/// before the 256 MiB interpret stack faults. `KLIO_MAX_EVAL_DEPTH` overrides.
pub const DEFAULT_MAX_EVAL_DEPTH: usize = 2_000;

pub threadlocal var evtls: EvalTls = .{};

/// The evaluator's per-thread hot state in ONE threadlocal, so a function that
/// touches several fields pays one TLV address lookup instead of one per field.
pub const EvalTls = struct {
    /// Activation depth: native recursion across the host call-back boundary.
    eval_depth: usize = 0,
    /// Native-recursion depth for the JIT (see `NATIVE_SLOT_BANK_DEPTH`).
    jit_native_depth: usize = 0,
    /// Resolved depth cap; `0` = not yet read from the env.
    eval_depth_cap: usize = 0,
    /// The executing frame's chain: always a live Frame's `enclosing_this`,
    /// repointed on entry and restored on exit, so it parks and resumes with it.
    active_chain: ?*std.ArrayList(EnclosingEntry) = null,
    /// Length of the seeded (frame-entry) prefix. Entries at or past it are the
    /// dispatch's in-flight pushes, the only ones transferred into the next frame.
    active_chain_base: usize = 0,
    /// The suspension a COMPILED body builds as it unwinds: compiled code cannot
    /// return an error union, so it answers `CoroutineSuspended` and leaves it here.
    in_flight_suspend: ?*SuspendState = null,
    /// Innermost-first chain of active interpreter frames (GC root seed).
    frame_chain: ?*Frame = null,
    /// Innermost in-flight resume node chain (GC root seed).
    resuming: ?*ResumeFrames = null,

    regs_pool: std.ArrayList([]Value) = .empty,
    args_pool: std.ArrayList([]Value) = .empty,
    /// Size-classed arg/capture carriers, one bucket per `ARGS_CLASS_CAPS` entry.
    args_class_pool: [ARGS_CLASS_CAPS.len]ArgsBucket = @splat(.{}),
    /// Lexical-origin override for file-private visibility (see `RefSiteOverride`).
    ref_site_override: ?RefSiteOverride = null,
    /// A direct call the host prepared for the flat driver to pick up.
    host_flat_armed: bool = false,
    host_flat_req: ?FlatCallReq = null,
    act_pool_len: usize = 0,
    act_pool: [ACT_POOL_MAX]*Activation = undefined,
    /// `KLIO_SPIN_TRACE` bookkeeping.
    spin_last_dump: i64 = 0,
    spin_check_counter: u64 = 0,
    /// Current leaf-serve nesting level, indexing `leaf_bank`.
    leaf_depth: usize = 0,
    chain_pool: [CHAIN_POOL_MAX][]EnclosingEntry = undefined,
    chain_pool_len: usize = 0,
};

/// Nesting levels of the native-to-native JIT slot/tag banks. Deeper recursion
/// falls back to the frame path, whose `eval_depth` bound raises StackOverflow.
pub const NATIVE_SLOT_BANK_DEPTH: usize = 192;

/// One disjoint slot/tag row per nesting level, so re-entrancy is safe.
/// Thread-local statics zero once; a stack buffer is 0xaa-filled per call.
pub threadlocal var native_slot_bank: [NATIVE_SLOT_BANK_DEPTH][192]i64 = @splat(@splat(0));

pub threadlocal var native_tag_bank: [NATIVE_SLOT_BANK_DEPTH][192]u8 = @splat(@splat(0));

/// One implicit receiver on the enclosing-`this` chain. A `receiver` carries
/// its whole class-nesting tower, a `subject` only itself, an `access` one dispatch.
pub const EnclosingEntry = runtime.ImplicitReceiver;

/// Source span of the statement the innermost active frame is executing, set
/// per statement by `.Trace`; compose keys its positional group on it.
pub fn currentCallSiteSpan() ?ir.Span {
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain) {
        // The walker records each Trace span on its mark just as a frame tracks
        // cur_span, null included: gates read the innermost site, never the caller's.
        return fusedTls().marks[fusedTls().depth - 1].span;
    }
    return if (evtls.frame_chain) |fr| fr.cur_span else null;
}

/// Declaring package of the innermost executing frame. Null-receiver extension
/// property dispatch keys on it, so same-name extensions resolve per visibility.
pub fn currentFramePackage() ?[]const u8 {
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain) {
        const pkg = fusedTls().marks[fusedTls().depth - 1].func.package;
        if (pkg.len != 0) return pkg;
    }
    const fr = evtls.frame_chain orelse return null;
    const pkg = fr.func.package;
    return if (pkg.len == 0) null else pkg;
}

/// Every executing frame's bound `this`, innermost first with adjacent
/// duplicates suppressed: the tower the member-extension owner walk falls back to.
pub const ThisChainIter = struct {
    cur: ?*Frame,
    steps: usize = 0,
    prev: ?Value = null,
    /// Active fused walkers' receivers, yielded before the frames: a fused body
    /// binds its receiver in the walker's args, never in a frame.
    fused_i: usize = 0,

    pub fn next(self: *ThisChainIter) ?Value {
        while (self.fused_i > 0) {
            self.fused_i -= 1;
            const v = fusedTls().marks[self.fused_i].recv orelse continue;
            if (self.prev) |p| {
                if (p == .Instance and v == .Instance and
                    ObjRef(InstanceData).ptrEq(p.Instance, v.Instance)) continue;
            }
            self.prev = v;
            return v;
        }
        while (self.cur) |f| {
            self.cur = f.gc_link;
            if (self.steps > 256) return null;
            self.steps += 1;
            const v = callerThisValue(f) orelse continue;
            if (self.prev) |p| {
                if (p == .Instance and v == .Instance and
                    ObjRef(InstanceData).ptrEq(p.Instance, v.Instance)) continue;
            }
            self.prev = v;
            return v;
        }
        return null;
    }
};

pub fn frameThisChainIter() ThisChainIter {
    return .{ .cur = evtls.frame_chain, .fused_i = fusedTls().depth };
}

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

/// Nearest enclosing frame's package, walking past accessors and init thunks.
pub fn nearestFramePackage() ?[]const u8 {
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain) {
        const pkg = fusedTls().marks[fusedTls().depth - 1].func.package;
        if (pkg.len != 0) return pkg;
    }
    var cur = evtls.frame_chain;
    while (cur) |f| : (cur = f.gc_link) {
        if (f.func.package.len != 0) return f.func.package;
    }
    return null;
}

/// A callable reference resolves file-private visibility at its WRITE site, not
/// the caller's. Scoped to the frame innermost at push, so deeper bodies opt out.
pub const RefSiteOverride = struct { file: ir.FileId, frame: *const Frame };

/// The reference-site file, while the frame it was pushed under is innermost.
pub fn refSiteFile() ?ir.FileId {
    const o = evtls.ref_site_override orelse return null;
    const fr = evtls.frame_chain orelse return null;
    return if (fr == o.frame) o.file else null;
}

/// Install a reference-site override on the innermost frame, returning the
/// previous one for `popRefSiteFile` to restore when the dispatch completes.
pub fn pushRefSiteFile(file: ir.FileId) ?RefSiteOverride {
    const prev = evtls.ref_site_override;
    if (evtls.frame_chain) |fr| evtls.ref_site_override = .{ .file = file, .frame = fr };
    return prev;
}

pub fn popRefSiteFile(prev: ?RefSiteOverride) void {
    evtls.ref_site_override = prev;
}

pub fn currentFuncName() ?[]const u8 {
    return if (evtls.frame_chain) |fr| fr.func.name else null;
}

/// The innermost frame's i-th bound parameter, borrowed. Reified type-variable
/// reads resolve through it: a type param naming a value param binds that class.
pub fn currentFrameParam(i: usize) ?Value {
    const fr = evtls.frame_chain orelse return null;
    if (i >= fr.params.items.len) return null;
    return fr.params.items[i];
}

/// The module the innermost frame's body is read against: a side module for an
/// anonymous-object or local-class member, else the main module.
pub fn currentFrameModule() ?*const Module {
    const fr = evtls.frame_chain orelse return null;
    return fr.module;
}

/// The innermost EXECUTING function: the fused walker's body while no frame
/// sits above the chain head it recorded, else the innermost frame's.
pub fn currentFrameFunc() ?*const ir.Func {
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain)
        return fusedTls().marks[fusedTls().depth - 1].func;
    return if (evtls.frame_chain) |fr| fr.func else null;
}

pub const FusedMark = struct { func: *const ir.Func, mod: *const Module, head: ?*Frame, recv: ?Value, span: ?ir.Span = null };

/// Type-parameter names the innermost frame's function declares; an `object`
/// expression lowered at run time inherits them as its members' type variables.
pub fn currentFrameTypeParams() []const []const u8 {
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain) {
        const mk = &fusedTls().marks[fusedTls().depth - 1];
        const tps = mk.mod.registry.func_type_params.get(mk.func.id) orelse return &.{};
        return tps.items;
    }
    const fr = evtls.frame_chain orelse return &.{};
    const tps = fr.module.registry.func_type_params.get(fr.func.id) orelse return &.{};
    return tps.items;
}

/// Bound on the per-thread register-buffer free list.
const REGS_POOL_MAX: usize = 128;

/// Allocator for frame REGISTER BUFFERS. Under the tracing GC they live outside
/// the GC heap (libc): values are traced via the frame chain, storage never swept.
pub inline fn regsAlloc(fallback: Allocator) Allocator {
    if (!runtime.reclaimEnabled() and runtime.gc.gc_enabled) return std.heap.c_allocator;
    return fallback;
}

/// Whether every instruction of `f` is in the flattened engine's simple subset
/// (moves, consts, arithmetic, branches, returns, exact calls), no catch/finally.
pub fn classifyFlattenable(f: *const Func) u8 {
    for (f.blocks) |*blk| {
        if (blk.catches.len != 0 or blk.finally != null or blk.lr_absorb != null) return 2;
        for (blk.insts) |*inst| {
            switch (inst.*) {
                .Move,
                .Const,
                .BinOp,
                .UnOp,
                .Not,
                .Trace,
                .LoadParam,
                .LoadCapture,
                .MakeCell,
                .CellGet,
                .CellSet,
                .GetField,
                .SetField,
                .Index,
                .IndexSet,
                .CallValue,
                .CallValueOrMember,
                .CallMemberOrValue,
                .CallMember,
                .CallVirtual,
                .CallMemberOrGlobal,
                .NewInstance,
                .NewList,
                .Cast,
                .InstanceOf,
                .NotNullAssert,
                .LateinitCheck,
                .LoadGlobal,
                .LoadFromThisOrGlobal,
                .StoreToThisOrGlobal,
                .StoreGlobal,
                .Lambda,
                .AstLambda,
                .PropertyRef,
                .MemberRef,
                .QualifiedThis,
                => {},
                .Call => {},
                else => return 2,
            }
        }
        switch (blk.terminator) {
            .Goto, .Branch, .Return => {},
            else => return 2,
        }
    }
    return 1;
}

pub var fill_census: [FRAME_CENSUS_SLOTS]u32 = @splat(0);

pub fn fillCensusBump(fid: u32, n: u32) void {
    if (!ev_diag.frame_census_on) return;
    fill_census[fid & (FRAME_CENSUS_SLOTS - 1)] +%= n;
}

/// Take a register buffer of length `n`, `.Unit`-filled unless `no_fill`,
/// reusing a pooled buffer that fits; pooled ones share the run's allocator.
pub fn acquireRegs(ev: *EvalTls, allocator: Allocator, n: u32, no_fill: bool, fid: u32) Allocator.Error!std.ArrayList(Value) {
    if (parent.frame_count_on) parent.frame_alloc_total += 1;
    const ra = regsAlloc(allocator);
    if (ev.regs_pool.items.len > 0) {
        const buf = ev.regs_pool.items[ev.regs_pool.items.len - 1];
        if (buf.len >= n) {
            ev.regs_pool.items.len -= 1;
            const list: std.ArrayList(Value) = .{ .items = buf[0..n], .capacity = buf.len };
            // No-fill keeps the buffer's stale slots; the written mask gates readers.
            if (!no_fill) @memset(list.items, .Unit);
            if (parent.frame_count_on) {
                parent.regs_pool_hit += 1;
                if (!no_fill) {
                    parent.regs_fill_slots += n;
                    fillCensusBump(fid, n);
                }
            }
            // Re-enters the traced set (see releaseRegs).
            if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting) runtime.gc.noteExternalBytes(buf.len * @sizeOf(Value));
            return list;
        }
    }
    if (parent.frame_count_on) {
        parent.regs_pool_miss += 1;
        if (!no_fill) {
            parent.regs_fill_slots += n;
            fillCensusBump(fid, n);
        }
    }
    var regs: std.ArrayList(Value) = .empty;
    if (no_fill) {
        try regs.ensureTotalCapacityPrecise(ra, n);
        regs.items.len = n;
    } else {
        try regs.appendNTimes(ra, .Unit, n);
    }
    // Fresh buffer: traced through the frame chain but outside the sweep
    // registry, so the collector's Appel trigger must count these bytes.
    if (runtime.gc.gc_enabled and runtime.gc.external_accounting) runtime.gc.noteExternalBytes(regs.capacity * @sizeOf(Value));
    return regs;
}

/// Recycle a frame's register buffer into this thread's pool. The outermost
/// teardown (`eval_depth == 0`) frees and drains instead: nothing outlives its run.
pub fn releaseRegs(ev: *EvalTls, allocator: Allocator, regs: *std.ArrayList(Value)) void {
    const ra = regsAlloc(allocator);
    // Size-classed arg carriers come from the RUN allocator, so draining at depth
    // 0 bounds them to one evaluation. Must precede the pooled-register return.
    if (ev.eval_depth == 0 and argsClassPooled(ev)) drainArgsClassPool(ev, allocator);
    const gc_pool = !runtime.reclaimEnabled() and runtime.gc.gc_enabled;
    const pool_ok = (gc_pool or (runtime.reclaimEnabled() and ev.eval_depth > 0)) and
        regs.capacity > 0 and ev.regs_pool.items.len < REGS_POOL_MAX;
    if (pool_ok) {
        const buf = regs.allocatedSlice();
        regs.* = .empty;
        // Leaves the traced set; shrink the external-live estimate to match.
        if (gc_pool and runtime.gc.external_accounting) runtime.gc.noteExternalFreed(buf.len * @sizeOf(Value));
        ev.regs_pool.append(ra, buf) catch {
            ra.free(buf);
        };
        return;
    }
    regs.deinit(ra);
    if (!gc_pool and ev.eval_depth == 0 and
        (ev.regs_pool.items.len > 0 or ev.args_pool.items.len > 0 or argsClassPooled(ev))) drainRegsPool(ev, allocator);
}

/// Free every pooled register buffer when the outermost frame unwinds.
fn drainRegsPool(ev: *EvalTls, allocator: Allocator) void {
    const ra = regsAlloc(allocator);
    for (ev.regs_pool.items) |buf| ra.free(buf);
    ev.regs_pool.clearRetainingCapacity();
    for (ev.args_pool.items) |buf| allocator.free(buf);
    ev.args_pool.deinit(allocator);
    ev.args_pool = .empty;
    drainArgsClassPool(ev, allocator);
}

/// Free every pooled size-classed arg carrier.
fn drainArgsClassPool(ev: *EvalTls, allocator: Allocator) void {
    for (&ev.args_class_pool) |*bucket| {
        for (bucket.bufs[0..bucket.len]) |buf| allocator.free(buf);
        bucket.len = 0;
    }
}

/// Whether any size-classed carrier is pooled; the run's allocator owns them.
fn argsClassPooled(ev: *const EvalTls) bool {
    for (ev.args_class_pool) |bucket| {
        if (bucket.len != 0) return true;
    }
    return false;
}

/// Bound on the per-thread arg-carrier free list.
const ARGS_POOL_MAX: usize = 64;

/// One size class's buffers; a fixed array, since recycling must never allocate.
const ArgsBucket = struct {
    bufs: [ARGS_CLASS_MAX][]Value = undefined,
    len: usize = 0,
};

/// Exact capacities for arg/capture carriers: every acquire is an exact-size
/// pop or a fresh allocation, so no fit check thrashes on mixed sizes.
const ARGS_CLASS_CAPS = [_]usize{ 4, 8, 16, 32 };

const ARGS_CLASS_MAX: usize = 32;

fn argsClassOf(cap: usize) ?usize {
    for (ARGS_CLASS_CAPS, 0..) |c, i| {
        if (cap <= c) return i;
    }
    return null;
}

fn argsClassOfExact(len: usize) ?usize {
    for (ARGS_CLASS_CAPS, 0..) |c, i| {
        if (len == c) return i;
    }
    return null;
}

pub fn acquireArgsCap(allocator: Allocator, cap: usize) Allocator.Error!std.ArrayList(Value) {
    const ev = &evtls;
    if (argsClassOf(cap)) |ci| {
        const bucket = &ev.args_class_pool[ci];
        if (bucket.len > 0) {
            bucket.len -= 1;
            const buf = bucket.bufs[bucket.len];
            // Re-enters the traced set (see releaseArgs).
            if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting)
                runtime.gc.noteExternalBytes(buf.len * @sizeOf(Value));
            return .{ .items = buf[0..0], .capacity = buf.len };
        }
        var list: std.ArrayList(Value) = .empty;
        try list.ensureTotalCapacityPrecise(allocator, ARGS_CLASS_CAPS[ci]);
        // A fresh carrier enters the traced set here, as a pooled one does above.
        if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting)
            runtime.gc.noteExternalBytes(list.capacity * @sizeOf(Value));
        return list;
    }
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacityPrecise(allocator, @max(cap, 4));
    return list;
}

/// Recycle or free an arg/capture carrier; the values inside stay the caller's.
pub fn releaseArgs(allocator: Allocator, list: *std.ArrayList(Value)) void {
    releaseArgsIn(&evtls, allocator, list);
}

/// `releaseArgs` with the running thread's `&evtls` resolved once; it must be
/// read fresh at the call, since a resumed coroutine can land on any thread.
pub fn releaseArgsIn(ev: *EvalTls, allocator: Allocator, list: *std.ArrayList(Value)) void {
    if (list.capacity != 0) {
        if (argsClassOfExact(list.capacity)) |ci| {
            const bucket = &ev.args_class_pool[ci];
            if (bucket.len < ARGS_CLASS_MAX) {
                const buf = list.allocatedSlice();
                list.* = .empty;
                // Leaves the traced set; shrink the external-live estimate to match.
                if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting)
                    runtime.gc.noteExternalFreed(buf.len * @sizeOf(Value));
                bucket.bufs[bucket.len] = buf;
                bucket.len += 1;
                return;
            }
        }
    }
    list.deinit(allocator);
}

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
    /// The fused walker's chain windows: an entry can be an object's only
    /// reference once its register is overwritten, so mark it like `enclosing_this`.
    fused_chains: *const [FUSED_BANK_DEPTH]std.ArrayList(EnclosingEntry),
    fused_depth: *const usize,
    /// Owning thread, for `KLIO_GC_FRAME_AUDIT`: a collector marking another
    /// thread's chain must find it parked, so a torn frame names an unparked mutator.
    tid: runtime.gc.Tid = 0,
};

threadlocal var frame_anchor: FrameAnchor = undefined;

/// This thread's GC root node; `ctx` is `&frame_anchor`, so any thread can mark
/// these frames while this one is parked. Registered on first frame push.
threadlocal var frame_troot: runtime.gc.ThreadRoot = undefined;

threadlocal var frame_troot_inited: bool = false;

pub inline fn gcPushFrame(f: *Frame) void {
    // The chain is maintained in every allocator mode (it backs stack-trace
    // capture too); only the root registration is gated on the collector.
    if (runtime.gc.gc_enabled) gcInstallFrameRoot();
    if (cmgTraceWant()) |w| {
        if (std.mem.eql(u8, w, f.func.name)) {
            std.debug.print("[frame-push] {s}#{d}", .{ f.func.name, f.func.id.int() });
            for (f.params.items, 0..) |*v, i| {
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
    f.gc_link = evtls.frame_chain;
    evtls.frame_chain = f;
}

pub inline fn gcPopFrame(f: *Frame) void {
    evtls.frame_chain = f.gc_link;
}

/// Mark a frame's register file, skipping slots the written mask says were
/// never written: an unfilled slot holds whatever the pooled buffer last carried.
pub fn gcMarkFrameRegs(f: *const Frame, m: *runtime.gc.Marker) void {
    runtime.gc.poison_ctx_name = f.func.name;
    const mask = f.wmask;
    if (mask.isAll()) {
        for (f.regs.items, 0..) |v, i| {
            runtime.gc.poison_ctx_idx = i;
            v.gcMark(m);
        }
        return;
    }
    for (f.regs.items, 0..) |v, i| {
        runtime.gc.poison_ctx_idx = i;
        if (mask.has(i)) v.gcMark(m);
    }
}

var stw_audit_state: u8 = 0;

pub fn stwAuditOn() bool {
    if (stw_audit_state == 0)
        stw_audit_state = if (runtime.envOnce("KLIO_GC_STW_AUDIT") != null) 2 else 1;
    return stw_audit_state == 2;
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
                f.captures.items.len > 4096 or f.params.items.len > 4096 or
                f.regs.items.len > 65536;
            if (bad) {
                std.debug.print("[gc-frame] TORN anchor_tid={d} marker_tid={d} idx={d} f={x} caps={d} params={d} regs={d}\n", .{ anchor.tid, me, fi, @intFromPtr(f), f.captures.items.len, f.params.items.len, f.regs.items.len });
                return;
            }
        }
        gcMarkFrameRegs(f, m);
        for (f.params.items) |v| v.gcMark(m);
        for (f.captures.items) |v| v.gcMark(m);
        for (f.enclosing_this.items) |e| e.v.gcMark(m);
        f.pending_finally.gcMark(m);
        markFrameClosure(f.closure_id, m);
    }
    for (anchor.fused_chains[0..@min(anchor.fused_depth.*, FUSED_BANK_DEPTH)]) |*w| {
        for (w.items) |e| e.v.gcMark(m);
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

/// Root the side-table slot of a closure whose body is on the stack or parked:
/// the frame holds only copies of the captures, so nothing else spares the slot.
pub inline fn markFrameClosure(closure_id: ?u64, m: *runtime.gc.Marker) void {
    if (closure_id) |id| {
        if (runtime.gc.markClosureHook) |hook| hook(id, m);
    }
}

/// Link this thread's frame-chain root node (idempotent per thread).
pub fn gcInstallFrameRoot() void {
    if (frame_troot_inited) return;
    frame_troot_inited = true;
    frame_anchor = .{ .chain = &evtls.frame_chain, .resuming = &evtls.resuming, .fused_chains = &fusedTls().chain, .fused_depth = &fusedTls().depth, .tid = runtime.gc.currentTid() };
    frame_troot = .{ .ctx = @ptrCast(&frame_anchor), .mark = gcMarkFramesCtx };
    runtime.gc.registerThreadRoot(&frame_troot);
}

/// Unlink this thread's frame-chain root and free its libc-backed register
/// buffers; short-lived workers would otherwise leak one cache each.
pub fn gcUninstallFrameRoot() void {
    if (frame_troot_inited) {
        runtime.gc.unregisterThreadRoot(&frame_troot);
        frame_troot_inited = false;
    }
    if (runtime.gc.gc_enabled and evtls.regs_pool.items.len > 0) {
        drainRegsPool(&evtls, std.heap.c_allocator);
        evtls.regs_pool.deinit(std.heap.c_allocator);
        // `deinit` leaves the list undefined, and the interpreter runs on the main
        // thread, whose threadlocals outlive this seam and would read a garbage length.
        evtls.regs_pool = .empty;
    }
}

/// Capture the live call stack, innermost first. Labels borrow program-lifetime
/// module memory; only the frame slice is owned by the returned cell.
pub fn captureStack(allocator: Allocator) Allocator.Error!?runtime.StackRef {
    // The live stack is the frame chain with fused activations layered on: a
    // fused body opens no Frame, and each mark records the chain head it sits on.
    var frame_n: usize = 0;
    {
        var cur = evtls.frame_chain;
        while (cur) |f| : (cur = f.gc_link) frame_n += 1;
    }
    const total = fusedTls().depth + frame_n;
    if (total == 0) return null;
    const frames = try allocator.alloc(runtime.StackFrame, total);
    errdefer allocator.free(frames);
    var i: usize = 0;
    var fi: usize = fusedTls().depth;
    var fr = evtls.frame_chain;
    while (true) {
        while (fi > 0 and fusedTls().marks[fi - 1].head == fr) {
            const mk = &fusedTls().marks[fi - 1];
            const label = if (mk.func.fqn.len != 0) mk.func.fqn else mk.func.name;
            if (mk.span) |sp| {
                frames[i] = .{ .fqn = label, .file_id = @intFromEnum(sp.file), .offset = sp.start, .has_pos = true };
            } else {
                frames[i] = .{ .fqn = label, .file_id = 0, .offset = 0, .has_pos = false };
            }
            i += 1;
            fi -= 1;
        }
        const f = fr orelse break;
        const label = if (f.func.fqn.len != 0) f.func.fqn else f.func.name;
        if (f.cur_span) |sp| {
            frames[i] = .{ .fqn = label, .file_id = @intFromEnum(sp.file), .offset = sp.start, .has_pos = true };
        } else {
            frames[i] = .{ .fqn = label, .file_id = 0, .offset = 0, .has_pos = false };
        }
        i += 1;
        fr = f.gc_link;
    }
    // Every fused mark's head is a live frame or null, so `i == total` here.
    if (i != total) {
        const shrunk = try allocator.realloc(frames, i);
        return try runtime.StackRef.init(allocator, .{ .frames = shrunk });
    }
    return try runtime.StackRef.init(allocator, .{ .frames = frames });
}

/// Print the active frame chain to stderr; env-gated call sites only.
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
