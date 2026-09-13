//! Per-thread evaluator state: the frame chain, the register and argument
//! pools, and the GC frame roots.

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

/// Make a heap `StringRef` from a borrowed slice (mirrors `Arc<String>`).
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
pub const DEFAULT_MAX_EVAL_DEPTH: usize = 2_000;

/// Per-thread evaluator activation depth. Incremented on entry to each
/// `runFrame` and decremented on exit, so it counts native recursion across
/// the host call-back boundary (every nested Kotlin call re-enters here).
/// Left as a plain threadlocal on purpose. The owner fast path that pays for
/// itself on the walker banks and field caches LOSES here: this state is read
/// on the JIT's per-call seam, where the extra atomic load and branch cost more
/// than the `_tlv_get_addr` they replace (a member-call loop measured 1173ms
/// with the threadlocal against 1277ms behind the fast path, while the
/// interpreter-only path moved 1785ms -> 1770ms — a bad trade either way).
pub threadlocal var evtls: EvalTls = .{};

/// The evaluator's per-thread hot state, batched into ONE threadlocal so a
/// function touching several of these fields pays one dyld TLV address
/// lookup instead of one per variable (separate threadlocals each cost
/// their own `_tlv_get_addr` per access site; the compiler only CSEs
/// repeated reads of the same variable).
pub const EvalTls = struct {
    /// Per-thread evaluator activation depth (native recursion across the
    /// host call-back boundary).
    eval_depth: usize = 0,
    /// Native-recursion depth for the whole-function JIT (see
    /// NATIVE_SLOT_BANK_DEPTH).
    jit_native_depth: usize = 0,
    /// Resolved depth cap; `0` = not yet read from the env.
    eval_depth_cap: usize = 0,
    /// The enclosing-`this` chain of the currently executing frame (always
    /// points at a live Frame's `enclosing_this`, or null between runs).
    active_chain: ?*std.ArrayList(EnclosingEntry) = null,
    /// Length of the active chain's seeded (frame-entry) prefix.
    active_chain_base: usize = 0,
    /// The suspension a COMPILED body is building as it unwinds. Compiled code
    /// cannot return a Zig error union, so it answers `CoroutineSuspended` and
    /// leaves the state here; each frame on the way out appends its own
    /// continuation, and whoever called into the compiled code takes it.
    in_flight_suspend: ?*SuspendState = null,
    /// Innermost-first chain of active interpreter frames (GC root seed).
    frame_chain: ?*Frame = null,
    /// Innermost in-flight resume node chain (GC root seed).
    resuming: ?*ResumeFrames = null,

    /// Free-list of frame register buffers (see `acquireRegs`).
    regs_pool: std.ArrayList([]Value) = .empty,
    /// Free-list of frame ARG/CAPTURE carrier buffers (see `acquireArgsCap`).
    args_pool: std.ArrayList([]Value) = .empty,
    /// Size-classed free-lists of arg/capture carriers, one bucket per entry
    /// of `ARGS_CLASS_CAPS` (see `acquireArgsCap`).
    args_class_pool: [ARGS_CLASS_CAPS.len]ArgsBucket = @splat(.{}),
    /// Lexical-origin override for file-private visibility (see
    /// `RefSiteOverride`).
    ref_site_override: ?RefSiteOverride = null,
    /// A direct call the host prepared for the flat driver to pick up.
    host_flat_armed: bool = false,
    host_flat_req: ?FlatCallReq = null,
    /// Free-list of flat activations (see `actAlloc`).
    act_pool_len: usize = 0,
    act_pool: [ACT_POOL_MAX]*Activation = undefined,
    /// `KLIO_SPIN_TRACE` bookkeeping.
    spin_last_dump: i64 = 0,
    spin_check_counter: u64 = 0,
    /// Current leaf-serve nesting level, indexing `leaf_bank`.
    leaf_depth: usize = 0,
    /// Free-list of enclosing-`this` chain buffers (see `chainAcquire`).
    chain_pool: [CHAIN_POOL_MAX][]EnclosingEntry = undefined,
    chain_pool_len: usize = 0,
};

/// Native-recursion depth for the whole-function JIT: a compiled body recursing
/// into a compiled callee runs it frameless (no interpreter frame), so each level
/// costs a few C-stack frames. Bounded so deep recursion falls back to the
/// frame-based path (whose `evtls.eval_depth` bound raises a catchable StackOverflow)
/// before the native stack faults.
/// Static per-thread slot/tag rows for native-to-native JIT recursion, one
/// row per nesting level (rows are disjoint, so re-entrancy is safe).
/// Thread-local statics are zero-initialized once — a per-call stack
/// `undefined` buffer is 0xaa-filled by the safe build on every call.
/// Recursion deeper than the bank falls back to the frame path.
pub const NATIVE_SLOT_BANK_DEPTH: usize = 192;

pub threadlocal var native_slot_bank: [NATIVE_SLOT_BANK_DEPTH][192]i64 = @splat(@splat(0));

pub threadlocal var native_tag_bank: [NATIVE_SLOT_BANK_DEPTH][192]u8 = @splat(@splat(0));

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
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain) {
        // The walker records each Trace op's span on its mark, exactly as
        // a frame tracks cur_span — including the null of a body that has
        // executed no Trace (a synthesized accessor): span-derived gates
        // read the INNERMOST executing code's site or nothing, never the
        // caller's.
        return fusedTls().marks[fusedTls().depth - 1].span;
    }
    return if (evtls.frame_chain) |fr| fr.cur_span else null;
}

/// The declaring package of the innermost executing frame's function.
/// Null-receiver extension-property dispatch keys on it: same-name
/// nullable extension properties in different packages resolve to the
/// one the executing code can see.
pub fn currentFramePackage() ?[]const u8 {
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain) {
        const pkg = fusedTls().marks[fusedTls().depth - 1].func.package;
        if (pkg.len != 0) return pkg;
    }
    const fr = evtls.frame_chain orelse return null;
    const pkg = fr.func.package;
    return if (pkg.len == 0) null else pkg;
}

/// Every executing frame's bound `this` (the this param, or the closure's
/// captured `this` slot), innermost first — the lexical receiver tower of
/// the current call stack. The member-extension owner walk consults it
/// when the dynamic enclosing chain has no matching entry (a property
/// read inside nested lambdas whose frames never pushed the chain).
///
/// The iterator form does the same walk, with the same adjacent-duplicate
/// suppression, without building a slice: a consumer that only scans the
/// tower pays no allocator traffic per property read.
pub const ThisChainIter = struct {
    cur: ?*Frame,
    steps: usize = 0,
    prev: ?Value = null,
    /// Active fused walkers' receivers, yielded innermost-first before the
    /// frames: a fused body binds its receiver in the walker's args, never
    /// in a frame, so without these a member-extension owner executing
    /// FUSED is invisible to the receiver-tower walks.
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

/// The nearest enclosing frame's declaring package, walking outward past
/// frames without one (synthesized accessors / init thunks carry no
/// package of their own; their lexical home is the calling frame's).
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

/// Lexical-origin override for file-private visibility. Kotlin resolves a
/// callable reference where it is WRITTEN: `.map(String::indentWidth)`
/// referencing a file-private extension is legal in its declaring file even
/// though `map` invokes it from another file. While a bound reference
/// dispatches, the visibility file is the reference's creation site, not
/// the dynamic caller. Scoped to the frame that was innermost at push: a
/// candidate body run during dispatch executes in a DEEPER frame, so its
/// own dispatches ignore the override and see their own files.
pub const RefSiteOverride = struct { file: ir.FileId, frame: *const Frame };

/// The active reference-site file, when the innermost frame is still the
/// one the override was pushed under.
pub fn refSiteFile() ?ir.FileId {
    const o = evtls.ref_site_override orelse return null;
    const fr = evtls.frame_chain orelse return null;
    return if (fr == o.frame) o.file else null;
}

/// Install a reference-site override on the current innermost frame.
/// Returns the previous override; the caller restores it via
/// `popRefSiteFile` when its dispatch completes.
pub fn pushRefSiteFile(file: ir.FileId) ?RefSiteOverride {
    const prev = evtls.ref_site_override;
    if (evtls.frame_chain) |fr| evtls.ref_site_override = .{ .file = file, .frame = fr };
    return prev;
}

pub fn popRefSiteFile(prev: ?RefSiteOverride) void {
    evtls.ref_site_override = prev;
}

/// Simple name of the function the innermost active frame is executing.
pub fn currentFuncName() ?[]const u8 {
    return if (evtls.frame_chain) |fr| fr.func.name else null;
}

/// The function the innermost active frame is executing. A bare-name field read
/// consults it to learn whether the reader is a member-extension body, whose
/// declaring class is an implicit receiver the read must prefer.
/// The innermost EXECUTING function — a real frame, or the fused walker's
/// body when it is what runs on top of the frame chain. The fused marker
/// records the chain head at fused entry: while no frame has been pushed
/// above it, the fused body is the executing code (private-member
/// visibility, self-serve guards, and file scoping all key off this); the
/// moment a callee pushes a real frame, that frame wins again.
/// The innermost executing frame's i-th bound parameter value (borrowed),
/// or null. Reified type-variable reads resolve through this: a type
/// parameter that names a value parameter's declared type binds to that
/// argument's runtime class, whatever dispatch path reached the frame.
pub fn currentFrameParam(i: usize) ?Value {
    const fr = evtls.frame_chain orelse return null;
    if (i >= fr.params.items.len) return null;
    return fr.params.items[i];
}

/// The module the innermost frame's body is read against: a side module
/// for an anonymous-object or local-class member (and the closures lowered
/// inside one), else the main module.
pub fn currentFrameModule() ?*const Module {
    const fr = evtls.frame_chain orelse return null;
    return fr.module;
}

pub fn currentFrameFunc() ?*const ir.Func {
    if (fusedTls().depth > 0 and fusedTls().marks[fusedTls().depth - 1].head == evtls.frame_chain)
        return fusedTls().marks[fusedTls().depth - 1].func;
    return if (evtls.frame_chain) |fr| fr.func else null;
}

pub const FusedMark = struct { func: *const ir.Func, mod: *const Module, head: ?*Frame, recv: ?Value, span: ?ir.Span = null };

/// Type-parameter names declared by the innermost frame's function. An
/// `object` expression lowered at run time inherits these as its members'
/// type variables (`ConcurrentSet<Key>()`'s literal declares `add(element:
/// Key)` against the factory's `Key`, not a nominal class of that name).
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

/// Per-thread free-list of register buffers, reused across calls so a freeing
/// backend pays no per-call alloc/free for the `regs` array. Only used under the
/// reference-counting (freeing) backends: under the tracing GC the buffer memory
/// is GC-owned and must not be hand-recycled; under the arena nothing is freed.
/// Bounded so a deep-then-shallow call profile cannot retain buffers unboundedly.
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
pub inline fn regsAlloc(fallback: Allocator) Allocator {
    if (!runtime.reclaimEnabled() and runtime.gc.gc_enabled) return std.heap.c_allocator;
    return fallback;
}

/// VM-plan P2: whether every instruction of `f` sits in the flattened
/// engine's simple subset (register moves, consts, arithmetic, branches,
/// returns, EXACT calls) with no catch/finally machinery. Coverage
/// measurement first, engine second.
pub fn classifyFlattenable(f: *const Func) u8 {
    for (f.blocks) |*blk| {
        if (blk.catches.len != 0 or blk.finally != null or blk.lr_absorb != null) return 2;
        for (blk.insts) |*inst| {
            switch (inst.*) {
                // The COMMON population (the 0.09% lesson): everything the
                // flattened engine must serve day one. Excluded tails deopt.
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

/// Every buffer pool belongs to the RUNNING thread: a frame captures its
/// `EvalTls` pointer when it is built, but a suspended coroutine resumes on
/// whatever thread the dispatcher hands it, and reaching the origin thread's
/// free list races its length (an intermittent `integer overflow` when a
/// guarded decrement went negative). Callers therefore pass `&evtls` read
/// fresh at the call, never a stored pointer — which also keeps the thread
/// pointer to one lookup per frame operation instead of one per pool.
/// Per-function eager-fill census (`KLIO_FRAME_CENSUS`): which bodies still
/// pay the whole register bank on every call.
pub var fill_census: [FRAME_CENSUS_SLOTS]u32 = @splat(0);

pub fn fillCensusBump(fid: u32, n: u32) void {
    if (!ev_diag.frame_census_on) return;
    fill_census[fid & (FRAME_CENSUS_SLOTS - 1)] +%= n;
}

pub fn acquireRegs(ev: *EvalTls, allocator: Allocator, n: u32, no_fill: bool, fid: u32) Allocator.Error!std.ArrayList(Value) {
    if (parent.frame_count_on) parent.frame_alloc_total += 1;
    const ra = regsAlloc(allocator);
    if (ev.regs_pool.items.len > 0) {
        const buf = ev.regs_pool.items[ev.regs_pool.items.len - 1];
        if (buf.len >= n) {
            ev.regs_pool.items.len -= 1;
            const list: std.ArrayList(Value) = .{ .items = buf[0..n], .capacity = buf.len };
            // A no-fill frame keeps whatever the pooled buffer last held;
            // its written mask keeps every reader away from those slots.
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
pub fn releaseRegs(ev: *EvalTls, allocator: Allocator, regs: *std.ArrayList(Value)) void {
    const ra = regsAlloc(allocator);
    // The size-classed arg carriers come from the RUN allocator (frames and
    // hosts both produce them), so none may outlive the outermost evaluation
    // that produced it — a pooled buffer surviving into the next run, or into
    // a worker thread's teardown, is a dangling free. Draining at depth 0
    // bounds the pool's lifetime to one evaluation, where the allocator is
    // fixed, and still recycles across every nested call within it. This must
    // run BEFORE the pooled-register early return below.
    if (ev.eval_depth == 0 and argsClassPooled(ev)) drainArgsClassPool(ev, allocator);
    const gc_pool = !runtime.reclaimEnabled() and runtime.gc.gc_enabled;
    const pool_ok = (gc_pool or (runtime.reclaimEnabled() and ev.eval_depth > 0)) and
        regs.capacity > 0 and ev.regs_pool.items.len < REGS_POOL_MAX;
    if (pool_ok) {
        const buf = regs.allocatedSlice();
        regs.* = .empty;
        // Leaves the traced set (pooled, no live values) — shrink the
        // collector's external-live estimate to match.
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

/// Free every pooled register buffer. Called when the outermost frame unwinds
/// (never under the GC pool, whose libc buffers persist for the process).
fn drainRegsPool(ev: *EvalTls, allocator: Allocator) void {
    const ra = regsAlloc(allocator);
    for (ev.regs_pool.items) |buf| ra.free(buf);
    ev.regs_pool.clearRetainingCapacity();
    for (ev.args_pool.items) |buf| allocator.free(buf);
    ev.args_pool.deinit(allocator);
    ev.args_pool = .empty;
    drainArgsClassPool(ev, allocator);
}

/// Free every pooled size-classed arg carrier. The bytes left the collector's
/// external-live estimate when they entered the pool (see `releaseArgs`).
fn drainArgsClassPool(ev: *EvalTls, allocator: Allocator) void {
    for (&ev.args_class_pool) |*bucket| {
        for (bucket.bufs[0..bucket.len]) |buf| allocator.free(buf);
        bucket.len = 0;
    }
}

/// Whether any size-classed carrier is currently pooled. A pooled buffer
/// belongs to the run's allocator, so the outermost unwind must drain them
/// before that allocator goes away.
fn argsClassPooled(ev: *const EvalTls) bool {
    for (ev.args_class_pool) |bucket| {
        if (bucket.len != 0) return true;
    }
    return false;
}

/// Per-thread free-list of frame ARG-carrier buffers. Every interpreted
/// call allocates a `Value` list for its params (and one for captures)
/// that lives until the frame tears down — the alloc+memcpy pair was the
/// single largest active-CPU leaf in the concurrent-collection profiles.
/// Pooled under the refcount backend only. GC-mode pooling was measured
/// NEGATIVE (13.1s -> 14.7s x2 on the concurrent benchmark): the slab run
/// allocator is already a size-classed free-list, and the pool's
/// top-of-stack fit check thrashes on mixed carrier sizes. The arena never
/// frees; pooling is pointless there.
const ARGS_POOL_MAX: usize = 64;

/// One size class's buffers. A fixed array: the pool is per-thread, bounded,
/// and must never allocate to recycle.
const ArgsBucket = struct {
    bufs: [ARGS_CLASS_MAX][]Value = undefined,
    len: usize = 0,
};

/// Size classes for the arg/capture carriers. The earlier pool was one
/// top-of-stack slot whose fit check thrashed on mixed carrier sizes, which
/// is why it was worth having only under the refcount backend. Bucketing by
/// an exact capacity makes every acquire either an exact-size pop or a fresh
/// allocation, so the pool serves the tracing GC — the default backend, where
/// the alloc/free pair was a quarter of the interpreted call's cost.
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
        // A fresh carrier enters the traced set here, exactly as a pooled one
        // does above: its release un-notes the same bytes, and an unbalanced
        // pair drives the collector's external-live estimate negative.
        if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting)
            runtime.gc.noteExternalBytes(list.capacity * @sizeOf(Value));
        return list;
    }
    var list: std.ArrayList(Value) = .empty;
    try list.ensureTotalCapacityPrecise(allocator, @max(cap, 4));
    return list;
}

/// Return an arg/capture carrier to the pool (refcount backend) or free it.
/// The values inside are the caller's responsibility; only the buffer is
/// recycled.
pub fn releaseArgs(allocator: Allocator, list: *std.ArrayList(Value)) void {
    releaseArgsIn(&evtls, allocator, list);
}

/// `releaseArgs` with the running thread's state already resolved, so a frame
/// teardown pays one thread-pointer lookup for all of its buffers.
pub fn releaseArgsIn(ev: *EvalTls, allocator: Allocator, list: *std.ArrayList(Value)) void {
    if (list.capacity != 0) {
        if (argsClassOfExact(list.capacity)) |ci| {
            const bucket = &ev.args_class_pool[ci];
            if (bucket.len < ARGS_CLASS_MAX) {
                const buf = list.allocatedSlice();
                list.* = .empty;
                // Leaves the traced set (pooled, no live values) — shrink the
                // collector's external-live estimate to match.
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

/// An in-flight `resumeContinuation` on this thread: while it rebuilds a parked
/// activation one frame at a time, the not-yet-rebuilt snapshots live only in
/// its Zig-local `frames` list (already taken out of the park registry, not yet
/// on `evtls.frame_chain`), so a collection during an inner frame's eval would sweep
/// them. Each resume links a node here; the GC marks `frames.items[head..]`.
/// Resumes nest (a resumed frame can suspend/resume again), so it is a chain.
pub const ResumeFrames = struct {
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
    /// The fused walker's active chain windows — enclosing entries a
    /// frameless body owns. A window entry can be the only reference to
    /// its object once the register it was pushed from is overwritten, so
    /// the collector must mark the live windows exactly as it marks a
    /// frame's `enclosing_this`.
    fused_chains: *const [FUSED_BANK_DEPTH]std.ArrayList(EnclosingEntry),
    fused_depth: *const usize,
    /// Owning thread, for the frame-walk audit (`KLIO_GC_FRAME_AUDIT=1`):
    /// a collector marking ANOTHER thread's chain must find that thread
    /// parked, so a torn frame there names an unparked mutator.
    tid: runtime.gc.Tid = 0,
};

threadlocal var frame_anchor: FrameAnchor = undefined;

/// This thread's GC root node. Its `ctx` is `&frame_anchor`, so the collector
/// can mark this thread's frames from any thread while it is parked at a safe
/// point. Registered lazily on first frame push; unlinked at the thread's exit
/// seam (its threadlocal storage dies with it).
threadlocal var frame_troot: runtime.gc.ThreadRoot = undefined;

threadlocal var frame_troot_inited: bool = false;

pub inline fn gcPushFrame(f: *Frame) void {
    // The chain is maintained in every allocator mode (it backs stack-trace
    // capture, not only GC marking); only the GC root registration is gated on
    // the collector being active.
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

/// Mark every live Value reachable from the `ctx` thread's frame chain and any
/// in-flight resume. `ctx` is that thread's `&frame_anchor`.
/// Mark a frame's register file, skipping slots its written mask says were
/// never written — an unfilled slot holds whatever the pooled buffer last
/// carried and must never reach the collector.
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

/// Keep the side-table slot of a closure whose body is currently on the stack
/// (or parked) alive: marking it live spares it from `reclaimDead`'s id reuse
/// and shades its capture-store cell + receiver chain. The running frame only
/// holds a copy of the capture *values*, so this is the sole thing that roots
/// the slot for a body that outlives the collection that fires during it.
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

/// Unlink this thread's frame-chain root node at its exit seam and release the
/// libc-backed register buffers cached by this thread.  Big-stack test and
/// intrinsic workers are short-lived, so process-lifetime pooling would leak
/// one cache per completed worker.
pub fn gcUninstallFrameRoot() void {
    if (frame_troot_inited) {
        runtime.gc.unregisterThreadRoot(&frame_troot);
        frame_troot_inited = false;
    }
    if (runtime.gc.gc_enabled and evtls.regs_pool.items.len > 0) {
        drainRegsPool(&evtls, std.heap.c_allocator);
        evtls.regs_pool.deinit(std.heap.c_allocator);
        // `deinit` leaves the list undefined. That was invisible while this seam
        // only ever ran on a thread about to be destroyed; the interpreter now
        // runs on the process main thread, whose threadlocals outlive the seam,
        // and the next evaluation read a garbage length.
        evtls.regs_pool = .empty;
    }
}

/// Capture the live call stack (innermost-first) as `StackFrame`s. Each entry
/// records the running function's display label and the source position it is
/// executing (the per-statement `Trace`). Returns null when there is no active
/// frame. The labels borrow program-lifetime module memory; only the frame
/// slice is owned by the returned cell.
pub fn captureStack(allocator: Allocator) Allocator.Error!?runtime.StackRef {
    // The live call stack is the pushed frame chain (`frame_chain`) with the
    // fully-fused activations (`fusedTls().marks`) layered on top. A fused body
    // never opens a Frame, so a trace built from `frame_chain` alone drops
    // every fused call — and a small program that fuses end to end has NO
    // pushed frames at all, so the trace comes out empty. Each fused mark
    // records the `frame_chain` head it sits on; interleave them
    // innermost-first (a higher `fusedTls().marks` index is more inner, and a mark
    // is more inner than the frame it is fused onto).
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
    // Every fused mark's head is a live frame (or null), so the walk emits all
    // of them and `i == total`; shrink defensively if a mark was ever skipped.
    if (i != total) {
        const shrunk = try allocator.realloc(frames, i);
        return try runtime.StackRef.init(allocator, .{ .frames = shrunk });
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
