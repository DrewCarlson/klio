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
const bc = @import("bc.zig");

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

const exec_call = @import("exec_call.zig");

const argNamesAllNull = exec_call.argNamesAllNull;
const callerThisValue = exec_call.callerThisValue;
const constStr = exec_call.constStr;
const declaringClassName = exec_call.declaringClassName;
const envVarSet = exec_call.envVarSet;
const execArmAstLambda = exec_call.execArmAstLambda;
const execArmBuildObject = exec_call.execArmBuildObject;
const execArmCall = exec_call.execArmCall;
const execArmCallMemberOrValue = exec_call.execArmCallMemberOrValue;
const execArmCallSpread = exec_call.execArmCallSpread;
const execArmCallSuper = exec_call.execArmCallSuper;
const execArmCallValue = exec_call.execArmCallValue;
const execArmCallValueOrMember = exec_call.execArmCallValueOrMember;
const execArmCallVirtual = exec_call.execArmCallVirtual;
const execArmCast = exec_call.execArmCast;
const execArmCtxCall = exec_call.execArmCtxCall;
const execArmCtxScope = exec_call.execArmCtxScope;
const execArmIndex = exec_call.execArmIndex;
const execArmIndexSet = exec_call.execArmIndexSet;
const execArmInstanceOf = exec_call.execArmInstanceOf;
const execArmLambda = exec_call.execArmLambda;
const execArmLoadFromThisOrGlobal = exec_call.execArmLoadFromThisOrGlobal;
const execArmMemberRef = exec_call.execArmMemberRef;
const execArmNewInstance = exec_call.execArmNewInstance;
const execArmNewList = exec_call.execArmNewList;
const execArmPropertyRef = exec_call.execArmPropertyRef;
const execArmQualifiedThis = exec_call.execArmQualifiedThis;
const execArmRegisterClass = exec_call.execArmRegisterClass;
const execArmStoreToThisOrGlobal = exec_call.execArmStoreToThisOrGlobal;
const execCallMemberOrGlobal = exec_call.execCallMemberOrGlobal;
const fastIndexGet = exec_call.fastIndexGet;
const fastSubscript = exec_call.fastSubscript;
const freeArgNames = exec_call.freeArgNames;
const freeDispatchMissMsg = exec_call.freeDispatchMissMsg;
const nullSiteOk = exec_call.nullSiteOk;
const ownReceiverEntry = exec_call.ownReceiverEntry;
const primitiveMemberFast = exec_call.primitiveMemberFast;
const primitiveMemberOp = exec_call.primitiveMemberOp;
const rangeIterFast = exec_call.rangeIterFast;
const readArgRun = exec_call.readArgRun;
const resolveArgNames = exec_call.resolveArgNames;
const sameReceiver = exec_call.sameReceiver;

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
    /// NATIVE_SLOT_BANK_DEPTH).
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

    /// Free-list of frame register buffers (see `acquireRegs`).
    regs_pool: std.ArrayListUnmanaged([]Value) = .empty,
    /// Free-list of frame ARG/CAPTURE carrier buffers (see `acquireArgsCap`).
    args_pool: std.ArrayListUnmanaged([]Value) = .empty,
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
const NATIVE_SLOT_BANK_DEPTH: usize = 192;
threadlocal var native_slot_bank: [NATIVE_SLOT_BANK_DEPTH][192]i64 = @splat(@splat(0));
threadlocal var native_tag_bank: [NATIVE_SLOT_BANK_DEPTH][192]u8 = @splat(@splat(0));

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
    if (fused_depth > 0 and fused_marks[fused_depth - 1].head == evtls.frame_chain) {
        // The walker records each Trace op's span on its mark, exactly as
        // a frame tracks cur_span — including the null of a body that has
        // executed no Trace (a synthesized accessor): span-derived gates
        // read the INNERMOST executing code's site or nothing, never the
        // caller's.
        return fused_marks[fused_depth - 1].span;
    }
    return if (evtls.frame_chain) |fr| fr.cur_span else null;
}

/// The declaring package of the innermost executing frame's function.
/// Null-receiver extension-property dispatch keys on it: same-name
/// nullable extension properties in different packages resolve to the
/// one the executing code can see.
pub fn currentFramePackage() ?[]const u8 {
    if (fused_depth > 0 and fused_marks[fused_depth - 1].head == evtls.frame_chain) {
        const pkg = fused_marks[fused_depth - 1].func.package;
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
            const v = fused_marks[self.fused_i].recv orelse continue;
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
    return .{ .cur = evtls.frame_chain, .fused_i = fused_depth };
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
    if (fused_depth > 0 and fused_marks[fused_depth - 1].head == evtls.frame_chain) {
        const pkg = fused_marks[fused_depth - 1].func.package;
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

pub fn currentFrameFunc() ?*const ir.Func {
    if (fused_depth > 0 and fused_marks[fused_depth - 1].head == evtls.frame_chain)
        return fused_marks[fused_depth - 1].func;
    return if (evtls.frame_chain) |fr| fr.func else null;
}

const FusedMark = struct { func: *const ir.Func, mod: *const Module, head: ?*Frame, recv: ?Value, span: ?ir.Span = null };
threadlocal var fused_marks: [FUSED_BANK_DEPTH]FusedMark = undefined;

/// Type-parameter names declared by the innermost frame's function. An
/// `object` expression lowered at run time inherits these as its members'
/// type variables (`ConcurrentSet<Key>()`'s literal declares `add(element:
/// Key)` against the factory's `Key`, not a nominal class of that name).
pub fn currentFrameTypeParams() []const []const u8 {
    if (fused_depth > 0 and fused_marks[fused_depth - 1].head == evtls.frame_chain) {
        const mk = &fused_marks[fused_depth - 1];
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
inline fn regsAlloc(fallback: Allocator) Allocator {
    if (!runtime.reclaimEnabled() and runtime.gc.gc_enabled) return std.heap.c_allocator;
    return fallback;
}

/// VM-plan P2: whether every instruction of `f` sits in the flattened
/// engine's simple subset (register moves, consts, arithmetic, branches,
/// returns, EXACT calls) with no catch/finally machinery. Coverage
/// measurement first, engine second.
fn classifyFlattenable(f: *const Func) u8 {
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
var fill_census: [FRAME_CENSUS_SLOTS]u32 = @splat(0);

pub fn fillCensusBump(fid: u32, n: u32) void {
    if (!frame_census_on) return;
    fill_census[fid & (FRAME_CENSUS_SLOTS - 1)] +%= n;
}

pub var regs_pool_hit: u64 = 0;
pub var regs_pool_miss: u64 = 0;
pub var regs_fill_slots: u64 = 0;

fn acquireRegs(ev: *EvalTls, allocator: Allocator, n: u32, no_fill: bool, fid: u32) Allocator.Error!std.ArrayList(Value) {
    if (frame_count_on) frame_alloc_total += 1;
    const ra = regsAlloc(allocator);
    if (ev.regs_pool.items.len > 0) {
        const buf = ev.regs_pool.items[ev.regs_pool.items.len - 1];
        if (buf.len >= n) {
            ev.regs_pool.items.len -= 1;
            const list: std.ArrayList(Value) = .{ .items = buf[0..n], .capacity = buf.len };
            // A no-fill frame keeps whatever the pooled buffer last held;
            // its written mask keeps every reader away from those slots.
            if (!no_fill) @memset(list.items, .Unit);
            if (frame_count_on) {
                regs_pool_hit += 1;
                if (!no_fill) {
                    regs_fill_slots += n;
                    fillCensusBump(fid, n);
                }
            }
            // Re-enters the traced set (see releaseRegs).
            if (runtime.gc.gc_enabled and !runtime.reclaimEnabled() and runtime.gc.external_accounting) runtime.gc.noteExternalBytes(buf.len * @sizeOf(Value));
            return list;
        }
    }
    if (frame_count_on) {
        regs_pool_miss += 1;
        if (!no_fill) {
            regs_fill_slots += n;
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
fn releaseRegs(ev: *EvalTls, allocator: Allocator, regs: *std.ArrayList(Value)) void {
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
    tid: u32 = 0,
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
inline fn gcPopFrame(f: *Frame) void {
    evtls.frame_chain = f.gc_link;
}

/// Mark every live Value reachable from the `ctx` thread's frame chain and any
/// in-flight resume. `ctx` is that thread's `&frame_anchor`.
/// Mark a frame's register file, skipping slots its written mask says were
/// never written — an unfilled slot holds whatever the pooled buffer last
/// carried and must never reach the collector.
fn gcMarkFrameRegs(f: *const Frame, m: *runtime.gc.Marker) void {
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
fn stwAuditOn() bool {
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
            const me: u32 = @bitCast(std.Thread.getCurrentId());
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
inline fn markFrameClosure(closure_id: ?u64, m: *runtime.gc.Marker) void {
    if (closure_id) |id| {
        if (runtime.gc.markClosureHook) |hook| hook(id, m);
    }
}

/// Link this thread's frame-chain root node (idempotent per thread).
pub fn gcInstallFrameRoot() void {
    if (frame_troot_inited) return;
    frame_troot_inited = true;
    frame_anchor = .{ .chain = &evtls.frame_chain, .resuming = &evtls.resuming, .fused_chains = &fused_chain, .fused_depth = &fused_depth, .tid = @bitCast(std.Thread.getCurrentId()) };
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
    }
}

/// Capture the live call stack (innermost-first) as `StackFrame`s. Each entry
/// records the running function's display label and the source position it is
/// executing (the per-statement `Trace`). Returns null when there is no active
/// frame. The labels borrow program-lifetime module memory; only the frame
/// slice is owned by the returned cell.
fn captureStack(allocator: Allocator) Allocator.Error!?runtime.StackRef {
    // The live call stack is the pushed frame chain (`frame_chain`) with the
    // fully-fused activations (`fused_marks`) layered on top. A fused body
    // never opens a Frame, so a trace built from `frame_chain` alone drops
    // every fused call — and a small program that fuses end to end has NO
    // pushed frames at all, so the trace comes out empty. Each fused mark
    // records the `frame_chain` head it sits on; interleave them
    // innermost-first (a higher `fused_marks` index is more inner, and a mark
    // is more inner than the frame it is fused onto).
    var frame_n: usize = 0;
    {
        var cur = evtls.frame_chain;
        while (cur) |f| : (cur = f.gc_link) frame_n += 1;
    }
    const total = fused_depth + frame_n;
    if (total == 0) return null;
    const frames = try allocator.alloc(runtime.StackFrame, total);
    errdefer allocator.free(frames);
    var i: usize = 0;
    var fi: usize = fused_depth;
    var fr = evtls.frame_chain;
    while (true) {
        while (fi > 0 and fused_marks[fi - 1].head == fr) {
            const mk = &fused_marks[fi - 1];
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

/// Threads currently inside at least one interpreted activation (the
/// outermost `runFrame` entry). The test runner's wall-cap drain polls this
/// to know every abandoned cohort member has actually LEFT interpreted code
/// before it clears the abandonment flags — a straggler that outlives a
/// fixed grace window would otherwise keep running its dead test's loops
/// (with the flags cleared, forever) and contaminate every later test in
/// the class.
pub var threads_in_eval = std.atomic.Value(u32).init(0);

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

/// First wall-cap fire already threw the catchable timeout on some thread;
/// a second expiry (the extended unwind deadline) hard-aborts. Reset by the
/// test runner when it arms a fresh deadline.
pub var wall_cap_thrown = std.atomic.Value(bool).init(false);

/// The wall-cap firing policy. FIRST fire: extend the deadline by an unwind
/// budget and unwind with a CATCHABLE Kotlin exception, so the test's
/// `catch`/`finally` (and the test infra's teardown — a compositionTest
/// disposing its recomposer, a runTest cancelling its children) actually
/// run; the hard `.Type` abort skipped them, and the dead test's globally
/// registered snapshot observers and live compositions contaminated every
/// later test in the class. SECOND fire (teardown itself hung past the
/// budget): the original hard abort + cohort abandonment.
fn wallCapFire(allocator: Allocator) Allocator.Error!EvalResult {
    if (!wall_cap_thrown.swap(true, .acq_rel)) {
        const dl = test_wall_deadline_ms.load(.monotonic);
        if (dl != 0) test_wall_deadline_ms.store(dl + 20_000, .monotonic);
        std.debug.print("[wall-cap] test wall-clock deadline exceeded — throwing; hang location follows:\n", .{});
        dumpFrameChainForDiagAlways();
        return errResult(.{ .Throw = try Value.newException(allocator, .{
            .fqn = try runtime.strInit(allocator, "kotlin.RuntimeException"),
            .message = .from(try runtime.strInit(allocator, "test wall-clock deadline exceeded")),
            .cause = null,
        }) });
    }
    std.debug.print("[wall-cap] deadline exceeded again during unwind — hard abort:\n", .{});
    dumpFrameChainForDiagAlways();
    wallCapAbandon();
    return errResult(.{ .Type = "test wall-clock deadline exceeded" });
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

/// Diagnostic: print the live frame chain (as the spin tracer does), for an
/// error site that raises a traceless Vm error. Gated by KLIO_ERR_TRACE.
/// KLIO_CALL_STATS: per-function invocation counters over the whole run.
/// `callStatsDump` prints the top entries — the workload census that
/// separates "the interpreter is slow per call" from "the program runs more
/// calls than the reference would" (missed skipping, repeated recompose).
var call_stats_state: u8 = 0;
var call_stats_mutex: runtime.SpinMutex = .{};
/// Serve an outer-hop stored-slot field route (tag 3): hop the receiver's
/// `outer` links, verify the destination's class identity (low 32 bits),
/// then read the indexed slot with the same name/Null/Delegate guards the
/// own-slot route applies. The returned value carries a retained ref.
fn serveOuterSlotRoute(recv: *const Value, name: []const u8, route: u64) ?Value {
    const hops: u64 = (route >> 2) & 63;
    const idx: usize = @intCast((route >> 8) & 0xFFFFFF);
    const want_cls: u32 = @intCast(route >> 32);
    var cur: Value = recv.*;
    var h: u64 = 0;
    while (h < hops) : (h += 1) {
        if (cur != .Instance) return null;
        const g = cur.Instance.borrow();
        const o = g.get().outer;
        g.deinit();
        cur = o orelse return null;
    }
    if (cur != .Instance) return null;
    const g = cur.Instance.borrow();
    defer g.deinit();
    const b = g.get();
    if (@as(u32, @truncate(@as(u64, @intCast(b.class.identity())))) != want_cls) return null;
    if (idx >= b.fields.items.len) return null;
    const f = &b.fields.items[idx];
    if (!std.mem.eql(u8, f.name, name)) return null;
    const v = f.value;
    if (v == .Null or v == .Delegate) return null;
    v.retain();
    return v;
}

var call_stats: ?std.StringHashMap(u64) = null;
fn callStatsBump(fqn: []const u8) void {
    callStatsBumpId(fqn, 0, null);
}
/// Census bump with the executing FuncId, so the anonymous-lambda mass
/// (every lambda's fqn is the literal "<lambda>") decomposes into
/// per-body counters under KLIO_CALL_STATS_LAMBDA — the id keys resolve
/// back to bodies via `dump-ir --func`.
fn callStatsBumpId(fqn: []const u8, fid: u32, module: ?*const Module) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var key: []const u8 = fqn;
    var buf: [160]u8 = undefined;
    if (fid != 0 and std.mem.eql(u8, fqn, "<lambda>") and lambdaStatsOn()) {
        key = blk: {
            // Name the body by its declaration site so the census reads
            // without a dump-ir id correlation step.
            if (module) |m| {
                if (@constCast(m).decl_span.get(fid)) |sp| {
                    if (span.active_map) |am| {
                        if (am.getChecked(sp.file)) |sf| {
                            const lc = sf.lineCol(sp.start);
                            const base = if (std.mem.lastIndexOfScalar(u8, sf.path, '/')) |ix| sf.path[ix + 1 ..] else sf.path;
                            break :blk std.fmt.bufPrint(&buf, "<lambda>#{d}[{s}:{d}]", .{ fid, base, lc.line }) catch fqn;
                        }
                    }
                }
            }
            break :blk std.fmt.bufPrint(&buf, "<lambda>#{d}", .{fid}) catch fqn;
        };
    }
    // KLIO_CALL_STATS_CALLER=<substr>: a matching fqn additionally bumps
    // `<fqn>@<caller-fqn>`, attributing the frame to the interpreted frame
    // live at activation. This names the dispatch context of census residue
    // whose serve route is unknown.
    var cbuf: [256]u8 = undefined;
    var caller_key: ?[]const u8 = null;
    if (callerStatsFilter()) |substr| {
        if (std.mem.indexOf(u8, key, substr) != null) {
            const cfqn: []const u8 = if (evtls.frame_chain) |fr| fr.func.fqn else "<top>";
            // The caller's current span IS the call site — it names which
            // literal/site invoked this body without any id correlation.
            var site_buf: [64]u8 = undefined;
            var site: []const u8 = "";
            if (evtls.frame_chain) |fr| {
                if (fr.cur_span) |sp| {
                    if (span.active_map) |am| {
                        if (am.getChecked(sp.file)) |sf| {
                            const lc = sf.lineCol(sp.start);
                            const base = if (std.mem.lastIndexOfScalar(u8, sf.path, '/')) |ix| sf.path[ix + 1 ..] else sf.path;
                            site = std.fmt.bufPrint(&site_buf, "[{s}:{d}]", .{ base, lc.line }) catch "";
                        }
                    }
                }
            }
            caller_key = std.fmt.bufPrint(&cbuf, "{s}@{s}{s}", .{ key, cfqn, site }) catch null;
        }
    }
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
    callStatsBumpKeyLocked(key);
    if (caller_key) |ck| callStatsBumpKeyLocked(ck);
}

/// Bump one census key with `call_stats_mutex` already held. The key may
/// point at a stack buffer: the first insertion re-keys with an owned dupe.
fn callStatsBumpKeyLocked(key: []const u8) void {
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

fn callerStatsFilter() ?[]const u8 {
    const S = struct {
        var state: u8 = 0;
        var val: []const u8 = "";
    };
    if (S.state == 0) {
        if (runtime.envOnce("KLIO_CALL_STATS_CALLER")) |v| {
            S.val = v;
            S.state = 2;
        } else S.state = 1;
    }
    return if (S.state == 2) S.val else null;
}
fn lambdaStatsOn() bool {
    const S = struct {
        var state: u8 = 0;
    };
    if (S.state == 0) S.state = if (runtime.envOnce("KLIO_CALL_STATS_LAMBDA") != null) 2 else 1;
    return S.state == 2;
}
/// KLIO_CALL_STATS census tap for slow-ladder GetField executions: keys are
/// `<gf>Type.name`, so the dump separates the field-read workload from the
/// call workload.
fn gfStatsBump(recv: *const Value, name: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "<gf>{s}.{s}", .{ recv.typeFqn(), name }) catch return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

/// KLIO_CALL_STATS census tap for member calls that reached the slow name
/// ladder: keys are `<ladder>Type.name`, so the dump names exactly which
/// member dispatches are still unbound at runtime on a given workload.
fn ladderStatsBump(recv: *const Value, name: []const u8, in_fn: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    var buf: [256]u8 = undefined;
    // An interpreted instance reports `<instance>` through `typeFqn`, which
    // names nothing — and the class is the whole point of a ladder split.
    const recv_name: []const u8 = if (recv.* == .Instance) blk: {
        const g = recv.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        const nm = cg.get().name;
        break :blk if (nm.len != 0) nm else recv.typeFqn();
    } else recv.typeFqn();
    // The enclosing function names the SITE: the ladder total is a few hot
    // unbound sites times their execution counts, and per-name rows alone
    // sent the analysis toward the wrong shape.
    const key = std.fmt.bufPrint(&buf, "<ladder>{s}.{s}@{s}", .{ recv_name, name, in_fn }) catch return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (call_stats == null) call_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
    const gop = call_stats.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, key) catch key;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

/// Host-route sub-tag names for the op profiler (see `runtime.prof.opRoute`).
/// Order is the route index contract shared with the host dispatch stages.
pub const op_route_names = [_][]const u8{
    "route:member-arg-prep", // 0
    "route:member-flat-prep", // 1
    "route:member-ladder", // 2
    "route:member-ext-fallback", // 3
    "route:member-invoke-fid", // 4
    "route:flat-activation", // 5
    "route:member-stdlib-dispatch", // 6
    "route:recv-fn-field", // 7
    "route:vararg-shadow", // 8
    "route:ir-method-walk", // 9
    "route:member-named-inner", // 10
    "route:ltg-cands", // 11
    "route:ltg-probe", // 12
    "route:ltg-global", // 13
    "route:gf-slow", // 14
    "route:member-cache-probe", // 15
    "route:member-post-stdlib", // 16
    "route:member-positional", // 17
    "route:member-miss-tail", // 18
};

/// KLIO_OP_PROF report: map the runtime sampler's per-tag counts to opcode
/// names and print the distribution. Lives here because only the IR layer
/// can name `Inst` tags.
pub fn opProfDump() void {
    const counts = runtime.prof.opProfCounts() orelse return;
    const Entry = struct { name: []const u8, n: u64 };
    var list: [512]Entry = undefined;
    var used: usize = 0;
    var total: u64 = 0;
    const n_tags = @typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields.len;
    for (counts, 0..) |*slot, i| {
        const n = slot.load(.monotonic);
        if (n == 0) continue;
        total += n;
        const name: []const u8 = if (i == runtime.prof.OP_OUTSIDE)
            "<outside-eval>"
        else if (i < n_tags)
            @tagName(@as(@typeInfo(Inst).@"union".tag_type.?, @enumFromInt(i)))
        else if (i >= runtime.prof.OP_ROUTE_BASE and
            i - runtime.prof.OP_ROUTE_BASE < op_route_names.len)
            op_route_names[i - runtime.prof.OP_ROUTE_BASE]
        else
            "<unknown>";
        list[used] = .{ .name = name, .n = n };
        used += 1;
    }
    if (total == 0) return;
    std.mem.sort(Entry, list[0..used], {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[op-prof] {d} samples by opcode:\n", .{total});
    const ft: f64 = @floatFromInt(total);
    for (list[0..used]) |e| {
        const pct = 100.0 * @as(f64, @floatFromInt(e.n)) / ft;
        if (pct < 0.3) break;
        std.debug.print("[op-prof] {d:>6.2}%  {d:>9}  {s}\n", .{ pct, e.n, e.name });
    }
}

/// Probe channel for the call census: host dispatch stages report the names
/// that miss their caches, prefixed per stage in a second map.
var probe_stats: ?std.StringHashMap(u64) = null;
pub fn callStatsProbe(name: []const u8) void {
    if (call_stats_state == 0)
        call_stats_state = if (runtime.envOnce("KLIO_CALL_STATS") != null) 2 else 1;
    if (call_stats_state != 2) return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    if (probe_stats == null) probe_stats = std.StringHashMap(u64).init(std.heap.page_allocator);
    const gop = probe_stats.?.getOrPut(name) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}
pub fn probeStatsDump() void {
    if (call_stats_state != 2) return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    const stats = &(probe_stats orelse return);
    const Entry = struct { fqn: []const u8, n: u64 };
    var list = std.ArrayList(Entry).initCapacity(std.heap.page_allocator, stats.count()) catch return;
    defer list.deinit(std.heap.page_allocator);
    var it = stats.iterator();
    var total: u64 = 0;
    while (it.next()) |e| {
        list.appendAssumeCapacity(.{ .fqn = e.key_ptr.*, .n = e.value_ptr.* });
        total += e.value_ptr.*;
    }
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[probe-stats] total={d} distinct={d}\n", .{ total, list.items.len });
    const top = @min(list.items.len, 40);
    for (list.items[0..top]) |e| std.debug.print("[probe-stats] {d:>10} {s}\n", .{ e.n, e.fqn });
}

/// `KLIO_DISPATCH_STATS=1` — executed-instruction census over the call
/// forms, so the static-dispatch campaign can be planned from counts rather
/// than from the shape of the IR. Every counter is a plain relaxed add on a
/// process-global array; the gate is read once.
pub const DispatchKind = enum(u8) {
    call_static,
    call_member_resolved,
    call_member_virtual,
    call_virtual_slot,
    call_member_or_global,
    call_value,
    call_member_or_value,
    call_value_or_member,
    call_spread,
    call_super,
    ctx_call,
    /// Where a name-based member dispatch ended up, so the campaign knows
    /// whether static binding must target intrinsics or interpreted bodies.
    served_intrinsic,
    served_user_body,
    served_extension,
    /// Sub-tails of the name-based member arm, in the order it tries them.
    member_fast_subscript,
    member_prim_op,
    member_range_iter,
    member_flat_prepare,
    member_ladder,
    /// Slot-bound / lowering-resolved calls served as pushed activations on
    /// the flat driver instead of through the recursive invoker.
    virtual_flat_prepare,
    resolved_flat_prepare,
    /// Exact static calls fused by the cached fast plan, split by whether
    /// the widened receiver-carrying admission served them.
    static_flat_fuse,
    static_flat_fuse_ext,
    /// By-name member calls replayed from their instruction-site memo.
    member_site_flat,
    /// VM-plan P0 baseline: every interpreter frame constructed. P1's
    /// contiguous stack and P2's call fusion drive this denominator down
    /// per call; the compose margin is the external gauge.
    frame_push,
    /// VM-plan P2 coverage: frames whose Func the flattened engine's
    /// simple-inst subset can execute end to end. The ratio to
    /// `frame_push` is the engine's reachable share BEFORE it is built.
    frame_push_flattenable,
};
const DISPATCH_KINDS = @typeInfo(DispatchKind).@"enum".fields.len;
var dispatch_counts: [DISPATCH_KINDS]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));
var dispatch_stats_state: u8 = 0;

pub inline fn dispatchBump(comptime k: DispatchKind) void {
    if (dispatch_stats_state == 0) {
        dispatch_stats_state = if (runtime.envOnce("KLIO_DISPATCH_STATS") != null) 2 else 1;
    }
    if (dispatch_stats_state != 2) return;
    _ = dispatch_counts[@intFromEnum(k)].fetchAdd(1, .monotonic);
}

/// Public tap for the host's dispatch tails (see `DispatchKind`).
pub fn dispatchNote(comptime k: DispatchKind) void {
    dispatchBump(k);
}

/// Installed by the VM host so the stats dump can report how many named
/// member calls the builtin intrinsic replay served outright. `member_ladder`
/// counts the ROUTE a call took, not the work it did, so the two differ.
pub var dispatch_replay_hits: ?*const fn () u64 = null;

/// Set by the host so the dispatch report can name how the member-extension
/// fallback resolved: a plain-key hit, a chain-folded hit, or a full walk.
pub var ext_fb_counts: ?*const fn () [4]u64 = null;

pub fn dispatchStatsDump() void {
    if (dispatch_stats_state != 2) return;
    if (ext_fb_counts) |f| {
        const c = f();
        if (c[0] != 0) std.debug.print(
            "[ext-fb] total={d} plain-hit={d} chain-hit={d} walk={d}\n",
            .{ c[0], c[1], c[2], c[3] },
        );
    }
    var total: u64 = 0;
    for (&dispatch_counts) |*c| total += c.load(.monotonic);
    if (total == 0) return;
    std.debug.print("[dispatch-stats] total={d}\n", .{total});
    if (dispatch_replay_hits) |f| std.debug.print("[dispatch-stats] replay-hits={d}\n", .{f()});
    inline for (@typeInfo(DispatchKind).@"enum".fields) |f| {
        const n = dispatch_counts[f.value].load(.monotonic);
        if (n != 0) std.debug.print("[dispatch-stats] {d:>12} {d:>6.2}%  {s}\n", .{ n, @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total)), f.name });
    }
}

pub fn callStatsDump() void {
    if (call_stats_state != 2) return;
    call_stats_mutex.lock();
    defer call_stats_mutex.unlock();
    const stats = &(call_stats orelse return);
    const Entry = struct { fqn: []const u8, n: u64 };
    var list = std.ArrayList(Entry).initCapacity(std.heap.page_allocator, stats.count()) catch return;
    defer list.deinit(std.heap.page_allocator);
    var it = stats.iterator();
    var total: u64 = 0;
    while (it.next()) |e| {
        list.appendAssumeCapacity(.{ .fqn = e.key_ptr.*, .n = e.value_ptr.* });
        total += e.value_ptr.*;
    }
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[call-stats] total={d} distinct={d}\n", .{ total, list.items.len });
    const top = @min(list.items.len, 60);
    for (list.items[0..top]) |e| std.debug.print("[call-stats] {d:>10} {s}\n", .{ e.n, e.fqn });
}

/// KLIO_FN_PROF report: the sampler's per-id counts resolved to function
/// names through `module`. Ids fold into the table, so a name is reported
/// only when its id owns the slot; the fold is 1:1 for every program with
/// fewer functions than the table's slots.
/// KLIO_FRAME_COUNT / KLIO_FRAME_CENSUS: how many interpreted activations a
/// workload runs, and which functions they belong to. `activations` counts
/// register-bank acquisitions (one per real frame); `entries` counts
/// `runFrameExec` entries, which is higher because a flat call re-enters its
/// caller's frame. The frames-per-unit-of-work metric that separates "too
/// many frames" (splice work) from "frames too expensive" (activation cost).
pub var frame_count_total: u64 = 0;
pub var frame_alloc_total: u64 = 0;
pub var frame_count_on: bool = false;
const FRAME_CENSUS_SLOTS: usize = 1 << 21;
var frame_census: [FRAME_CENSUS_SLOTS]u32 = @splat(0);
var frame_census_on: bool = false;

pub var frame_watch_want: []const u8 = "";

pub fn frameCountInit() void {
    frame_count_on = runtime.envOnce("KLIO_FRAME_COUNT") != null;
    fuse_census_on = runtime.envOnce("KLIO_FUSE_CENSUS") != null;
    if (fuse_census_on) frame_count_on = true;
    if (runtime.envOnce("KLIO_FRAME_WATCH")) |w| {
        frame_watch_want = w;
        frame_count_on = true;
    }
    frame_census_on = runtime.envOnce("KLIO_FRAME_CENSUS") != null;
    if (frame_census_on) frame_count_on = true;
}

inline fn frameCensusBump(fid: u32) void {
    if (!frame_census_on) return;
    frame_census[fid & (FRAME_CENSUS_SLOTS - 1)] +%= 1;
}

/// `KLIO_FUSE_CENSUS`: the ceiling measurement for a fused native-bank
/// execution tier. Every activated body is classified once — could a walker
/// with C-stack registers, routed field access and pre-resolved calls run
/// it end to end? — and activations tally by verdict, with the blocking
/// instruction named for the near-misses.
var fuse_census_on: bool = false;
var fuse_ok_acts: u64 = 0;
var fuse_blocked_acts: u64 = 0;
var fuse_structural_acts: u64 = 0;
var fuse_block_by_tag: [64]u64 = @splat(0);
const FUSE_VERDICT_SLOTS: usize = 1 << 21;
/// 0 = unclassified, 1 = ok, 2 + tag = blocked by that instruction tag,
/// 255 = structural (suspend / catches / too big).
var fuse_verdict: [FUSE_VERDICT_SLOTS]u8 = @splat(0);

fn fuseClassify(func: *const Func) u8 {
    if (func.is_suspend) return 255;
    if (func.blocks.len == 0 or func.blocks.len > 64) return 255;
    if (func.n_locals > 128) return 255;
    var total: usize = 0;
    for (func.blocks) |*b| {
        if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return 255;
        total += b.insts.len;
        if (total > 256) return 255;
        switch (b.terminator) {
            .Return, .Goto, .Branch, .Throw, .Unreachable, .Switch => {},
            else => return 255,
        }
        for (b.insts) |*inst| {
            switch (inst.*) {
                .Const, .Move, .LoadParam, .LoadCapture, .BinOp, .UnOp, .Not, .Trace,
                .GetField, .SetField, .Index, .IndexSet, .Cast, .InstanceOf,
                .NotNullAssert, .Call, .MakeCell, .CellGet,
                .CellSet, .QualifiedThis, .EnclosingPush, .EnclosingPop => {},
                else => return 2 + @as(u8, @intFromEnum(std.meta.activeTag(inst.*))),
            }
        }
    }
    return 1;
}

inline fn fuseCensusBump(func: *const Func) void {
    if (!fuse_census_on) return;
    const slot = func.id.int() & (FUSE_VERDICT_SLOTS - 1);
    if (fuse_verdict[slot] == 0) fuse_verdict[slot] = fuseClassify(func);
    switch (fuse_verdict[slot]) {
        1 => fuse_ok_acts += 1,
        255 => fuse_structural_acts += 1,
        else => |v| {
            fuse_blocked_acts += 1;
            if (v >= 2 and v - 2 < fuse_block_by_tag.len) fuse_block_by_tag[v - 2] += 1;
        },
    }
}

/// Executed-instruction total (`KLIO_FRAME_COUNT` prints it): the denominator
/// that turns a sampled opcode profile into a per-instruction cost.
pub threadlocal var inst_count: u64 = 0;
pub var inst_count_all: std.atomic.Value(u64) = .init(0);

pub fn frameCountDump(module: *const Module) void {
    if (!frame_count_on) return;
    std.debug.print("[frames] entries={d} activations={d} insts={d}\n", .{ frame_count_total, frame_alloc_total, inst_count_all.load(.monotonic) + inst_count });
    std.debug.print("[call] pre_ms={d} args_ms={d} replay_ms={d} prep_ms={d} probe_ms={d}\n", .{ cm_pre_ns / 1_000_000, cm_args_ns / 1_000_000, cm_replay_ns / 1_000_000, cm_prep_ns / 1_000_000, cm_probe_ns / 1_000_000 });
    std.debug.print("[call] member_arms={d}\n", .{cm_calls});
    std.debug.print("[regs] pool_hit={d} pool_miss={d} filled_slots={d}\n", .{ regs_pool_hit, regs_pool_miss, regs_fill_slots });
    if (frame_census_on) {
        const FE = struct { name: []const u8, n: u32 };
        var fl: std.ArrayList(FE) = .empty;
        defer fl.deinit(std.heap.page_allocator);
        var fid: u32 = 0;
        while (fid < fill_census.len) : (fid += 1) {
            const n = fill_census[fid];
            if (n == 0) continue;
            const f = module.funcById(@enumFromInt(fid));
            const nm: []const u8 = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "<unknown>";
            fl.append(std.heap.page_allocator, .{ .name = nm, .n = n }) catch break;
        }
        std.mem.sort(FE, fl.items, {}, struct {
            fn gt(_: void, a: FE, b: FE) bool {
                return a.n > b.n;
            }
        }.gt);
        for (fl.items[0..@min(fl.items.len, 12)]) |e| {
            std.debug.print("[fill] {d:>10} {s}\n", .{ e.n, e.name });
        }
    }
    if (fuse_census_on) {
        std.debug.print("[fuse] ok={d} blocked={d} structural={d}\n", .{ fuse_ok_acts, fuse_blocked_acts, fuse_structural_acts });
        const tag_fields = @typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields;
        inline for (tag_fields) |f| {
            if (f.value < fuse_block_by_tag.len and fuse_block_by_tag[f.value] != 0) {
                std.debug.print("[fuse-block] {d:>10} {s}\n", .{ fuse_block_by_tag[f.value], f.name });
            }
        }
    }
    std.debug.print("[getfield] mono={d} getter={d} poly={d} total={d} getter_ms={d} slow_ms={d}\n", .{ gf_mono, gf_getter, gf_poly, gf_slow, gf_getter_ns / 1_000_000, gf_slow_ns / 1_000_000 });
    if (!frame_census_on) return;
    const Entry = struct { name: []const u8, n: u32 };
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(std.heap.page_allocator);
    var fid: u32 = 0;
    while (fid < frame_census.len) : (fid += 1) {
        const n = frame_census[fid];
        if (n == 0) continue;
        const f = module.funcById(@enumFromInt(fid));
        const nm: []const u8 = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "<unknown>";
        list.append(std.heap.page_allocator, .{ .name = nm, .n = n }) catch return;
    }
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    // Package split for the AOT scoping question: how many activations are
    // bodies an emitted compose set could own outright.
    var in_compose: u64 = 0;
    var in_coroutines: u64 = 0;
    var in_accessor: u64 = 0;
    var in_lambda: u64 = 0;
    var in_other: u64 = 0;
    for (list.items) |e| {
        if (std.mem.startsWith(u8, e.name, "androidx.compose")) {
            in_compose += e.n;
        } else if (std.mem.startsWith(u8, e.name, "kotlinx.coroutines")) {
            in_coroutines += e.n;
        } else if (std.mem.startsWith(u8, e.name, "__get_") or
            std.mem.startsWith(u8, e.name, "__set_") or
            std.mem.startsWith(u8, e.name, "__init_prop_") or
            std.mem.startsWith(u8, e.name, "__ext_get_"))
        {
            in_accessor += e.n;
        } else if (std.mem.startsWith(u8, e.name, "<lambda>")) {
            in_lambda += e.n;
        } else {
            in_other += e.n;
        }
    }
    std.debug.print("[census-split] compose={d} accessor={d} lambda={d} coroutines={d} other={d}\n", .{ in_compose, in_accessor, in_lambda, in_coroutines, in_other });
    const top = @min(list.items.len, 40);
    for (list.items[0..top]) |e| std.debug.print("[frames] {d:>9} {s}\n", .{ e.n, e.name });
}

/// The first source span an emitted body carries, for naming an anonymous
/// function in a profile.
fn funcFirstSpan(f: *const ir.Func) ?ir.Span {
    for (f.blocks) |*b| {
        for (b.insts) |*inst| {
            if (inst.* == .Trace) return inst.Trace.span;
        }
    }
    return null;
}

pub fn fnProfDump(module: *const Module) void {
    const counts = runtime.prof.fnProfCounts() orelse return;
    const Entry = struct { name: []const u8, n: u32 };
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(std.heap.page_allocator);
    var total: u64 = 0;
    var fid: u32 = 0;
    while (fid < counts.len) : (fid += 1) {
        const n = counts[fid].load(.monotonic);
        if (n == 0) continue;
        total += n;
        const f = module.funcById(@enumFromInt(fid));
        var nm: []const u8 = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "<unknown>";
        // A lambda's name says nothing; every one of them reads `<lambda>` and
        // the whole population lands in one bucket. Name it by id and its
        // source position, which is what makes a hot one findable.
        if (f) |ff| {
            if (std.mem.eql(u8, nm, "<lambda>")) {
                const buf = std.heap.page_allocator.alloc(u8, 160) catch return;
                var site: []const u8 = "";
                var site_buf: [96]u8 = undefined;
                if (ff.blocks.len != 0 and ff.blocks[0].insts.len != 0) {
                    if (funcFirstSpan(ff)) |sp| {
                        if (span.active_map) |am| {
                            if (am.getChecked(sp.file)) |sf| {
                                const lc = sf.lineCol(sp.start);
                                const base = if (std.mem.lastIndexOfScalar(u8, sf.path, '/')) |ix| sf.path[ix + 1 ..] else sf.path;
                                site = std.fmt.bufPrint(&site_buf, " {s}:{d}", .{ base, lc.line }) catch "";
                            }
                        }
                    }
                }
                nm = std.fmt.bufPrint(buf, "<lambda>#{d}{s}", .{ fid, site }) catch nm;
            }
        }
        list.append(std.heap.page_allocator, .{ .name = nm, .n = n }) catch return;
    }
    if (total == 0) return;
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    std.debug.print("[fn-prof] samples={d} distinct={d} (names resolve through ONE module; a pack/anon-module body with the same numeric id reports under the wrong name — verify a surprising item with KLIO_TRACE_PATH or a frame-push count before chasing it)\n", .{ total, list.items.len });
    const top = @min(list.items.len, 40);
    for (list.items[0..top]) |e| {
        const pct = @as(f64, @floatFromInt(e.n)) * 100.0 / @as(f64, @floatFromInt(total));
        std.debug.print("[fn-prof] {d:>7.2}% {d:>8} {s}\n", .{ pct, e.n, e.name });
    }
}

/// Cached KLIO_ERR_TRACE presence — the flag is read on every dispatch-miss
/// diagnostic path, and `getenvSlice` takes a global mutex per call. The env
/// is set at launch; a mid-run change is not observed (benign data race:
/// both racers store the same verdict).
var err_trace_state: u8 = 0;
pub fn errTraceOn() bool {
    if (err_trace_state == 0)
        err_trace_state = if (runtime.envOnce("KLIO_ERR_TRACE") != null) 2 else 1;
    return err_trace_state == 2;
}

pub fn dumpFrameChainForDiag() void {
    if (!errTraceOn()) return;
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
/// Install the runtime-layer frame-dump hook (idempotent; see
/// `runtime.debug_frame_dump`).
pub fn installDebugFrameDump() void {
    runtime.debug_frame_dump = &dumpFrameChainForDiagAlways;
}

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
                i, p.name, @tagName(std.meta.activeTag(v.*)), diagValueClassName(v),
            });
        }
        // Captures carry a closure's environment; a mis-captured callee
        // slot (`this.LocalFn(...)` binding an Any) is only visible here.
        for (fr.captures.items, 0..) |*cv, i| {
            std.debug.print("  [cap {d}] {s} {s}\n", .{
                i, @tagName(std.meta.activeTag(cv.*)), diagValueClassName(cv),
            });
        }
    }
}

/// The value's concrete runtime class name for diagnostics: an Instance
/// answers its class, everything else its type FQN. `typeFqn` alone prints
/// `<instance>` for interpreted objects, which hides exactly the fact a
/// wrong-receiver diagnosis needs.
fn diagValueClassName(v: *const Value) []const u8 {
    if (v.* == .Instance) {
        const ig = v.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        return cg.get().name;
    }
    return v.typeFqn();
}

fn spinDumpMaybe() void {
    if (!spin_interval_read) {
        spin_interval_read = true;
        if (runtime.envOnce("KLIO_SPIN_TRACE")) |v| {
            spin_interval_s = std.fmt.parseInt(i64, v, 10) catch 30;
        }
    }
    const iv = spin_interval_s orelse return;
    const now: i64 = @intCast(runtime.clockMonotonicNanos() / std.time.ns_per_s);
    if (evtls.spin_last_dump == 0) {
        evtls.spin_last_dump = now;
        return;
    }
    if (now - evtls.spin_last_dump < iv) return;
    evtls.spin_last_dump = now;
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
                if (!f0.wmask.has(i)) continue;
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
            if (e.message.get()) |m| {
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
        .Exception => |e| {
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
/// Iterate the pushed enclosing receivers, innermost first. The values are
/// borrowed from the live chain — do not retain past the call.
pub const EnclosingChainIter = struct {
    idx: usize,
    pub fn next(self: *EnclosingChainIter) ?Value {
        const chain = evtls.active_chain orelse return null;
        while (self.idx > 0) {
            self.idx -= 1;
            const e = chain.items[self.idx];
            if (e.kind == .receiver or e.kind == .subject) return e.v;
        }
        return null;
    }
};

pub fn enclosingChainIter() EnclosingChainIter {
    const chain = evtls.active_chain orelse return .{ .idx = 0 };
    return .{ .idx = chain.items.len };
}

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
/// Fold the active enclosing-`this` chain's shape (entry kinds + receiver
/// class identities) into a hash, without allocating. Used to key
/// chain-dependent resolutions (member-extension applicability) in the
/// extension cache: identical chain shapes resolve identically.
pub fn enclosingChainClassHash() u64 {
    var h = std.hash.Wyhash.init(0x8f14e45fceea167a);
    if (evtls.active_chain) |chain| {
        for (chain.items) |e| {
            const kb: u8 = @intFromEnum(e.kind);
            h.update((&kb)[0..1]);
            var k: u64 = undefined;
            if (e.v == .Instance) {
                k = @intCast(runtime.InstanceData.classIdentityUnlocked(e.v.Instance));
            } else {
                k = @as(u64, @intFromEnum(std.meta.activeTag(e.v))) +% 0x2b8c;
            }
            h.update(std.mem.asBytes(&k));
        }
    }
    return h.final() | 1;
}

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
    var out: std.ArrayList(EnclosingEntry) = .empty;
    errdefer out.deinit(allocator);
    if (evtls.active_chain) |chain| {
        for (chain.items) |e| {
            if (e.kind == .access) continue;
            try out.append(allocator, e);
        }
    }
    // The creating function's OWN receiver (`this`, params[0] of an
    // extension or member) is the innermost lexical receiver at the
    // literal, and it lives in the frame's params — never on the enclosing
    // chain. Without it a lambda inside `ReceiveChannel.toList()` had only
    // the buildList receiver in scope and `consumeEach(::add)` dispatched
    // on the MutableList.
    if (evtls.frame_chain) |fr| {
        if (fr.func.params.len != 0 and std.mem.eql(u8, fr.func.params[0].name, "this") and
            fr.params.items.len != 0)
        {
            const own = fr.params.items[0];
            const dup = blk: {
                if (out.items.len == 0) break :blk false;
                const last = out.items[out.items.len - 1].v;
                if (last == .Instance and own == .Instance)
                    break :blk last.Instance.identity() == own.Instance.identity();
                break :blk false;
            };
            if (!dup and own != .Null and own != .Unit) {
                try out.append(allocator, .{ .v = own, .kind = .receiver });
            }
        }
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

/// Per-thread free-list of enclosing-`this` chain buffers. Nearly every call
/// seeds a chain of one or two entries and drops it again at teardown, so the
/// buffer is recycled rather than round-tripped through the slab. The backing
/// allocator is process-global, so a buffer is safe to hand to any later frame
/// on this thread.
const CHAIN_POOL_MAX: usize = 128;

fn chainAcquire(ev: *EvalTls) std.ArrayList(EnclosingEntry) {
    if (ev.chain_pool_len > 0) {
        ev.chain_pool_len -= 1;
        const buf = ev.chain_pool[ev.chain_pool_len];
        return .{ .items = buf[0..0], .capacity = buf.len };
    }
    return .empty;
}

fn chainRelease(ev: *EvalTls, list: *std.ArrayList(EnclosingEntry)) void {
    if (list.capacity > 0 and ev.chain_pool_len < CHAIN_POOL_MAX) {
        ev.chain_pool[ev.chain_pool_len] = list.allocatedSlice();
        ev.chain_pool_len += 1;
        list.* = .empty;
        return;
    }
    list.deinit(chainAllocator());
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
pub fn flatEnabled() bool {
    if (flat_enabled_cached) |b| return b;
    const raw = runtime.envOnce("KLIO_FLAT");
    const b = !(raw != null and std.mem.eql(u8, raw.?, "0"));
    flat_enabled_cached = b;
    return b;
}

/// `KLIO_FLAT_VCALL=0` keeps slot-bound and lowering-resolved member calls on
/// the recursive invoker — the bisect switch for the fused virtual path.
var vcall_flat_cached: ?bool = null;
pub fn vcallFlatEnabled() bool {
    if (vcall_flat_cached) |b| return b;
    const raw = runtime.envOnce("KLIO_FLAT_VCALL");
    const b = !(raw != null and std.mem.eql(u8, raw.?, "0"));
    vcall_flat_cached = b;
    return b;
}

/// `KLIO_MEMBER_SITE=0` disables the CallMember instruction-site memo — the
/// bisect switch for the by-name replay path.
var member_site_cached: ?bool = null;
fn memberSiteEnabled() bool {
    if (member_site_cached) |b| return b;
    const raw = runtime.envOnce("KLIO_MEMBER_SITE");
    const b = !(raw != null and std.mem.eql(u8, raw.?, "0"));
    member_site_cached = b;
    return b;
}

/// Cached hot-path trace gates: the memoized `getenvSlice` still takes a
/// lock + hashmap probe per consult, which prices every dispatch arm when
/// consulted per executed instruction. The env never changes mid-run.
var cv_trace_cached: ?bool = null;
fn cvTraceOn() bool {
    if (cv_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_CALLVALUE_TRACE") != null;
    cv_trace_cached = b;
    return b;
}
var lr_trace_cached: ?bool = null;
var gf_trace_init: bool = false;
var gf_trace_val: ?[]const u8 = null;
/// `KLIO_GF_TRACE` — cached once: the raw getenv is a full environ scan
/// and this gate sits on EVERY GetField execution.
fn gfTraceWant() ?[]const u8 {
    if (!gf_trace_init) {
        gf_trace_val = if (std.c.getenv("KLIO_GF_TRACE")) |w| std.mem.span(w) else null;
        gf_trace_init = true;
    }
    return gf_trace_val;
}

var cm_trace_init: bool = false;
var cm_trace_val: ?[]const u8 = null;
fn cmTraceWant() ?[]const u8 {
    if (!cm_trace_init) {
        cm_trace_val = if (std.c.getenv("KLIO_CM_TRACE")) |w| std.mem.span(w) else null;
        cm_trace_init = true;
    }
    return cm_trace_val;
}

var chain_trace_init: bool = false;
var chain_trace_on: bool = false;
fn chainTraceOn() bool {
    if (!chain_trace_init) {
        chain_trace_on = std.c.getenv("KLIO_CHAIN_TRACE") != null;
        chain_trace_init = true;
    }
    return chain_trace_on;
}

fn lrTraceOn() bool {
    if (lr_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_LR_TRACE") != null;
    lr_trace_cached = b;
    return b;
}
var resume_trace_cached: ?bool = null;
fn resumeTraceOn() bool {
    if (resume_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_RESUME_TRACE") != null;
    resume_trace_cached = b;
    return b;
}
var miss_trace_init: bool = false;
var miss_trace_val: ?[]const u8 = null;
pub fn missTraceWant() ?[]const u8 {
    if (!miss_trace_init) {
        miss_trace_val = runtime.envOnce("KLIO_MISS_TRACE");
        miss_trace_init = true;
    }
    return miss_trace_val;
}
var cmg_trace_init: bool = false;
var cmg_trace_val: ?[]const u8 = null;
pub fn cmgTraceWant() ?[]const u8 {
    if (!cmg_trace_init) {
        cmg_trace_val = runtime.envOnce("KLIO_CMG_TRACE");
        cmg_trace_init = true;
    }
    return cmg_trace_val;
}
var nu_trace_init: bool = false;
var nu_trace_val: ?[]const u8 = null;
pub fn nuTraceWant() ?[]const u8 {
    if (!nu_trace_init) {
        nu_trace_val = runtime.envOnce("KLIO_NU_TRACE");
        nu_trace_init = true;
    }
    return nu_trace_val;
}

/// Host→driver flat-call handoff for resolution ladders whose PICK lives
/// deep in host code (the CMG global-overload terminal): the exec arm arms
/// the slot, the host's terminal takes the arm (one-shot — inner calls see
/// it disarmed), prepares the flat request instead of dispatching, and
/// stashes it here; the arm consumes the stash and pushes the activation.
pub fn armHostFlatReq() void {
    evtls.host_flat_armed = true;
}
pub fn takeHostFlatArm() bool {
    const a = evtls.host_flat_armed;
    evtls.host_flat_armed = false;
    return a;
}
pub fn stashHostFlatReq(req: FlatCallReq) void {
    evtls.host_flat_req = req;
}
pub fn takeHostFlatReq() ?FlatCallReq {
    const r = evtls.host_flat_req;
    evtls.host_flat_req = null;
    return r;
}

/// Stash a control-flow `EvalError` on the frame and signal `Step.raised`.
pub inline fn raiseStep(frame: *Frame, e: EvalError) Step {
    frame.step_err = e;
    return .raised;
}

pub inline fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

pub inline fn errResult(e: EvalError) EvalResult {
    return .{ .err = e };
}

/// One active try-region recorded on the eval's try-stack. Separates
/// the *entry* (where to jump to start running finally / catch) from
/// the *done sentinel* (the synthesized block whose entry signals
/// the finally body has run to completion regardless of any internal
/// control flow in the user finally body).

/// Restore the frame's enclosing-receiver chain to its try-entry length
/// when a throw routes to a catch or finally: the unwind skipped any
/// `EnclosingPop` inside the try body, and the stale spliced subject
/// would otherwise shadow reads for the rest of the frame.
fn truncChainTo(frame: *Frame, chain_len: usize) void {
    if (frame.enclosing_this.items.len > chain_len) {
        frame.enclosing_this.shrinkRetainingCapacity(chain_len);
    }
}

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

    fn newWithCaptures(
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
            const caller = if (evtls.frame_chain) |fr| (if (fr.func.fqn.len != 0) fr.func.fqn else fr.func.name) else "<none>";
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
        if (dispatch_stats_state == 2) {
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
        if (frame_count_on) {
            frameCensusBump(func.id.int());
            fuseCensusBump(func);
            if (frame_watch_want.len != 0 and std.mem.indexOf(u8, func.name, frame_watch_want) != null) {
                const caller: []const u8 = if (evtls.frame_chain) |fr| fr.func.name else "<top>";
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
    fn activateChain(self: *Frame, seed: []const EnclosingEntry) Allocator.Error!void {
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
    fn activateChainFrom(self: *Frame, saved: []const EnclosingEntry) Allocator.Error!void {
        try self.enclosing_this.appendSlice(chainAllocator(), saved);
        self.activateAs();
    }

    fn activateAs(self: *Frame) void {
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

    fn deactivateChain(self: *Frame) void {
        if (chainTraceOn()) {
            std.debug.print("[chain] deact tid={d} tls={*} frame={*} restore={*} fn={s}\n", .{
                std.Thread.getCurrentId(), self.tls, self, self.prev_chain, self.func.name,
            });
        }
        self.tls.active_chain = self.prev_chain;
        self.tls.active_chain_base = self.prev_chain_base;
    }

    fn deinit(self: *Frame) void {
        // Tripwire (`KLIO_GC_STW_AUDIT=1`): tearing a frame down while the
        // world is stopped means the collector is walking this thread's
        // chain right now — a rendezvous hole, and exactly the shape that
        // makes a mark walk read freed frame buffers.
        if (stwAuditOn() and runtime.gc.worldStopped()) {
            const me: u32 = @bitCast(std.Thread.getCurrentId());
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
        const ev: *EvalTls = &evtls;
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

    fn block(self: *const Frame, b: BlockId) *const ir.Block {
        return &self.func.blocks[b.int()];
    }

    /// Fill every not-yet-written register slot with `Unit` and saturate
    /// the written mask. Called before the register file escapes the
    /// masked world — a suspension snapshot, the loop JIT, the C-native
    /// surface, a resume rebuild — so those consumers see exactly the file
    /// an eagerly-filled frame would carry. No-op once saturated.
    fn materializeRegs(self: *Frame) void {
        if (self.wmask.isAll()) return;
        for (self.regs.items, 0..) |*v, i| {
            if (!self.wmask.has(i)) v.* = .Unit;
        }
        self.wmask.setAll();
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
/// The cached literal-coercion plan for `func`: bit 1 = computed, bit 2 =
/// a declared non-nullable `Long` param (coerceIntArgsToLong), bit 4 = a
/// type-variable param beside a peer (coerceGenericIntPeersToLong).
fn coercePlanFor(module: *const Module, func: *const Func) u8 {
    var plan = func.coerce_plan;
    if (plan != 0) return plan;
    plan = 1;
    for (func.params) |*p| {
        if (!p.is_vararg and !p.ty.nullable and std.mem.eql(u8, p.ty.name, "Long")) {
            plan |= 2;
            break;
        }
    }
    if (func.params.len >= 2) {
        for (func.params) |*p| {
            if (!p.ty.nullable and isFuncTypeParam(module, func, p.ty.name)) {
                plan |= 4;
                break;
            }
        }
    }
    @constCast(func).coerce_plan = plan;
    return plan;
}

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
        const ti = func.params[i].ty;
        if (ti.nullable or !isFuncTypeParam(module, func, ti.name)) continue;
        if (iv == .Int) {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                if (j == i or params[j] != .Long) continue;
                if (std.mem.eql(u8, func.params[j].ty.name, ti.name)) {
                    params[i] = .{ .Long = @as(i64, iv.Int) };
                    break;
                }
            }
            continue;
        }
        // The same literal-flow shape one level down: `assertEquals(
        // listOf(0..10, ...), longRangesValue)` types the range literals
        // as `LongRange` via the shared `T = List<LongRange>` — retag the
        // Int-kind range/scalar elements of the literal list when the peer
        // bound to the same `T` carries Long content.
        if (iv == .Range or iv == .List) {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                if (j == i) continue;
                if (!std.mem.eql(u8, func.params[j].ty.name, ti.name)) continue;
                if (iv == .Range and params[j] == .Range) {
                    if (iv.Range.kind == .Int and params[j].Range.kind == .Long and !iv.Range.progression) {
                        iv.Range.kind = .Long;
                    }
                    break;
                }
                if (iv == .List and params[j] == .List) {
                    if (peerListIsLongContent(&params[j])) widenIntListContentToLong(&params[i]);
                    break;
                }
            }
        }
    }
}

/// Whether every element of the peer list is Long-kind content (a Long
/// scalar or a Long-kind range) — the evidence the literal side's Ints
/// were typed `Long` by inference.
fn peerListIsLongContent(v: *const Value) bool {
    const g = v.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    if (items.len == 0) return false;
    for (items) |*e| {
        switch (e.*) {
            .Long => {},
            .Range => |r| if (r.kind != .Long) return false,
            else => return false,
        }
    }
    return true;
}

fn widenIntListContentToLong(v: *Value) void {
    const g = v.List.items.borrowMut();
    defer g.deinit();
    for (g.get().items) |*e| {
        switch (e.*) {
            .Int => |x| e.* = .{ .Long = @as(i64, x) },
            .Range => |r| if (r.kind == .Int and !r.progression) {
                r.kind = .Long;
            },
            else => {},
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

/// Whether `v` is a primitive the leaf evaluator may hand to `applyBinop`
/// directly. Everything else (instances with operator overloads, strings,
/// collections, cells) needs the full operator arm, so the leaf declines.
fn leafPrimitive(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char => true,
        else => false,
    };
}

/// Serve a `leafExprBody` without building a frame.
///
/// A leaf body reads its arguments and some stored fields, combines them
/// with primitive operators and returns — it opens no scope, dispatches
/// nothing, and cannot suspend, so an activation, register buffer, GC frame
/// link and receiver chain are all pure overhead. The property getters that
/// dominate a composition workload (`capacity`, `size`, index arithmetic
/// over a gap buffer) are exactly this shape and run millions of times.
///
/// Speculative: any instruction whose real semantics need the frame path —
/// a field read that is not a claimed stored slot, an operator over a
/// non-primitive — abandons the serve and returns null, and the caller runs
/// the ordinary body. Nothing is mutated before that point, so abandoning is
/// always safe.
/// Whether `module` is the one `func`'s body indexes against: its ids must
/// name this very `Func`, not merely be in range.
fn funcOwnedBy(module: *const Module, func: *const Func) bool {
    return module.funcById(func.id) == func;
}

pub fn leafExprServe(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
) Allocator.Error!?EvalResult {
    return leafExprServeAt(H, allocator, module, func, args, host, LEAF_MAX_DEPTH);
}

/// Per-thread bank of leaf register files, one per nesting level. A stack
/// array would be `undefined`-filled on entry under the safety builds (and
/// zeroed under any build), which for a two-instruction accessor costs more
/// than the frame the serve replaces; the bank is initialised once per
/// thread and each level owns its slice for the serve's duration.
const LEAF_BANK_DEPTH: usize = 8;
threadlocal var leaf_bank: [LEAF_BANK_DEPTH][ir.LEAF_MAX_REGS]Value = undefined;

/// Scratch for the leaf serve's literal-typing coercion, per nesting level.
/// A per-call `[LEAF_MAX_REGS]Value = undefined` stack array paid a 2.5KB
/// safety-mode 0xAA fill on EVERY serve — 15% of the compose slot-table
/// benchmark's whole profile; the threadlocal bank is initialized once per
/// thread and reused.
threadlocal var coerce_bank: [LEAF_BANK_DEPTH][ir.LEAF_MAX_REGS]Value = undefined;

/// How far a leaf serve chains into other leaf callees. A gap-buffer read is
/// typically three levels (`groupSize` -> `groupIndexToAddress` -> the array
/// index helper); the bound keeps the native recursion trivially finite.
const LEAF_MAX_DEPTH: u8 = 8;

/// Raised by the walk when an instruction needs the frame path. Caught at the
/// serve boundary, where it becomes a plain "declined".
const LeafAbandon = error{LeafAbandon};

fn leafReqServable(req: FlatCallReq) bool {
    return req.captures.items.len == 0 and
        req.chain.len == 0 and
        req.closure_id == null and
        req.type_args.len == 0 and
        req.keepalive == null and
        req.typed_saved == null and
        req.ctx_mark_override == null and
        req.pop_enclosing_n == 0 and
        req.scope_guard_ident == 0 and
        !req.composer_pushed and
        !req.suspend_barrier and
        !req.root_pump and
        req.owning == null and
        req.func.leafExprBody();
}

fn leafExprServeAt(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
) Allocator.Error!?EvalResult {
    if (comptime !@hasDecl(H, "fieldSiteRoute")) return null;
    const trace = leafTraceWant(func);
    if (!func.leafExprBody()) {
        if (trace) std.debug.print("[leaf] {s}: not a leaf body\n", .{func.name});
        return null;
    }
    if (func.leaf_hopeless != 0) return null;
    if (args.len != func.params.len) {
        if (trace) std.debug.print("[leaf] {s}: arity {d} vs {d}\n", .{ func.name, args.len, func.params.len });
        return null;
    }
    // The literal-typing coercions a real frame push applies
    // (Frame.newWithCaptures) apply on this serve too: a bare Int flowing
    // into a declared Long param, or into a shared type-variable slot
    // beside a Long peer, is a Long-typed literal — `eq(0, 0L)` must
    // compare two Longs here exactly as on the framed path.
    const reclaim = runtime.reclaimEnabled();
    const ev: *EvalTls = &evtls;
    if (ev.leaf_depth >= LEAF_BANK_DEPTH) return null;
    var eff_args = args;
    {
        const plan = coercePlanFor(module, func);
        if (plan & 6 != 0 and args.len <= ir.LEAF_MAX_REGS) {
            const coerce_buf: []Value = coerce_bank[ev.leaf_depth][0..args.len];
            @memcpy(coerce_buf, args);
            if (plan & 2 != 0) coerceIntArgsToLong(func, coerce_buf);
            if (plan & 4 != 0) coerceGenericIntPeersToLong(module, func, coerce_buf);
            eff_args = coerce_buf;
        }
    }
    // Only the body's own locals are live, and they come from the per-thread
    // bank rather than a fresh stack array.
    const nlive: usize = @min(@as(usize, func.n_locals), ir.LEAF_MAX_REGS);
    const regs: []Value = leaf_bank[ev.leaf_depth][0..nlive];
    ev.leaf_depth += 1;
    defer ev.leaf_depth -= 1;
    // A def-before-use-proven body never reads a stale slot, so the bank
    // keeps whatever the previous serve left; the fill stays for reclaim
    // builds (each write releases the slot's prior value, which must be
    // live) and unproven bodies. `wmask` tracks which slots the serve has
    // written so a lazy pin can zero the rest first (the keepalive pins the
    // whole slice, and a stale slot must not reach the collector).
    var wmask: u64 = 0;
    if (reclaim) {
        for (regs) |*v| v.* = .Unit;
        wmask = ~@as(u64, 0);
    }
    defer if (reclaim) {
        for (regs) |*v| v.release(allocator);
    };
    // The register file is a native local, invisible to the collector's frame
    // walk, so an instruction that can allocate must pin it first or a
    // collection could sweep an intermediate. Pinning is deferred to the
    // first such instruction: a plain field-and-arithmetic accessor — the
    // shape this exists for — reaches no safe point and pays nothing.
    var pin: ?usize = null;
    defer if (pin) |m| runtime.keepaliveRestore(m);
    const fs: ?*const bc.FuncStreams = if (bc.enabled())
        bc.funcStreams(func, !jit_loop.enabled(), module.consts.items)
    else
        null;
    const out = (if (fs) |f|
        leafWalkStream(H, allocator, module, func, eff_args, host, depth, regs, reclaim, trace, &pin, &wmask, f)
    else
        leafWalk(H, allocator, module, func, eff_args, host, depth, regs, reclaim, trace, &pin, &wmask)) catch |e| switch (e) {
        error.LeafAbandon => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // The register file is released on the way out; the caller owns one
    // reference to the result, exactly as a returning frame would hand over.
    out.retain();
    return EvalResult{ .ok = out };
}


/// The leaf walk over the function's DENSE bytecode stream: the same op
/// set the framed flat loop runs, over the leaf bank. The Inst-union
/// re-walk this replaces was the single largest cost of call-dense
/// interpreted code (~35% of a 3M-call benchmark); simple ops decode from
/// packed u32s here, and only the complex ops (`escape`) touch the union,
/// through the same `leafRunOne` the fallback walker uses. Any structure
/// the stream cannot express abandons to the framed path exactly as the
/// union walker would.
fn leafWalkStream(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
    fs: *const bc.FuncStreams,
) (Allocator.Error || LeafAbandon)!Value {
    var block: usize = 0;
    var steps: usize = 0;
    outer: while (true) {
        if (block >= func.blocks.len) return error.LeafAbandon;
        const st = (if (block < fs.streams.len) fs.streams[block] else null) orelse return error.LeafAbandon;
        const code = st.code;
        var pc: usize = 0;
        while (pc < code.len) {
            steps += 1;
            if (steps > ir.LEAF_MAX_STEPS) return error.LeafAbandon;
            const op: bc.Op = @enumFromInt(code[pc]);
            switch (op) {
                .trace => pc += 4,
                .const_int => {
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), .{ .Int = @bitCast(code[pc + 2]) }, reclaim, false, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .const_load => {
                    const cid = code[pc + 2];
                    if (cid >= module.consts.items.len) return error.LeafAbandon;
                    if (module.consts.items[cid] == .String) leafPin(pin, regs, wmask);
                    const v = try constToValue(allocator, &module.consts.items[cid]);
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), v, reclaim, false, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .move => {
                    const v = leafRead(regs, wmask.*, @enumFromInt(code[pc + 2])) orelse return error.LeafAbandon;
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), v, reclaim, true, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .load_param => {
                    const pi = code[pc + 2];
                    if (pi >= args.len) return error.LeafAbandon;
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), args[pi], reclaim, true, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .cell_get => return error.LeafAbandon,
                .bin => {
                    const kind: ir.BinOp = @enumFromInt(code[pc + 2]);
                    const l = leafRead(regs, wmask.*, @enumFromInt(code[pc + 4])) orelse return error.LeafAbandon;
                    const r = leafRead(regs, wmask.*, @enumFromInt(code[pc + 5])) orelse return error.LeafAbandon;
                    if (scalarBin(kind, l, r)) |v| {
                        if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 3]), v, reclaim, false, wmask)) return error.LeafAbandon;
                    } else {
                        if (!leafPrimitive(&l) or !leafPrimitive(&r)) return error.LeafAbandon;
                        const res = try applyBinop(allocator, kind, &l, &r);
                        if (res != .ok) return error.LeafAbandon;
                        if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 3]), res.ok, reclaim, false, wmask)) return error.LeafAbandon;
                    }
                    pc += 6;
                },
                .escape => {
                    const inst_idx = code[pc + 1];
                    const b = &func.blocks[block];
                    if (inst_idx >= b.insts.len) return error.LeafAbandon;
                    try leafRunOne(H, allocator, module, func, args, host, depth, &b.insts[inst_idx], regs, reclaim, trace, pin, wmask);
                    pc += 2;
                },
                .jump => {
                    block = code[pc + 1];
                    continue :outer;
                },
                .br => {
                    const c = leafRead(regs, wmask.*, @enumFromInt(code[pc + 1])) orelse return error.LeafAbandon;
                    if (c != .Bool) return error.LeafAbandon;
                    block = if (c.Bool) code[pc + 2] else code[pc + 3];
                    continue :outer;
                },
                .ret => {
                    if (code[pc + 1] == 0) return .Unit;
                    return leafRead(regs, wmask.*, @enumFromInt(code[pc + 2])) orelse error.LeafAbandon;
                },
                .term_exit => break,
                .cmp_br => {
                    const kind: ir.BinOp = @enumFromInt(code[pc + 2]);
                    const l = leafRead(regs, wmask.*, @enumFromInt(code[pc + 4])) orelse return error.LeafAbandon;
                    const r = leafRead(regs, wmask.*, @enumFromInt(code[pc + 5])) orelse return error.LeafAbandon;
                    const v = scalarBin(kind, l, r) orelse return error.LeafAbandon;
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 3]), v, reclaim, false, wmask)) return error.LeafAbandon;
                    if (v != .Bool) return error.LeafAbandon;
                    block = if (v.Bool) code[pc + 6] else code[pc + 7];
                    continue :outer;
                },
            }
        }
        // Off the stream's end (or `term_exit`): the block's REAL
        // terminator decides, exactly as the union walker's loop does.
        switch (func.blocks[block].terminator) {
            .Return => |r| {
                const rr = r orelse return .Unit;
                return leafRead(regs, wmask.*, rr) orelse return error.LeafAbandon;
            },
            .Goto => |g| block = g.int(),
            .Branch => |br| {
                const c = leafRead(regs, wmask.*, br.cond) orelse return error.LeafAbandon;
                if (c != .Bool) return error.LeafAbandon;
                block = if (c.Bool) br.t.int() else br.f.int();
            },
            else => return error.LeafAbandon,
        }
    }
}

/// Walk the body's blocks until one returns. `Goto`/`Branch` are followed;
/// everything else about the body was admitted structurally, and any
/// individual instruction the serve cannot execute abandons here.
fn leafWalk(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
) (Allocator.Error || LeafAbandon)!Value {
    var block_idx: usize = 0;
    var steps: usize = 0;
    while (true) {
        if (block_idx >= func.blocks.len) return error.LeafAbandon;
        const b = &func.blocks[block_idx];
        steps += b.insts.len + 1;
        if (steps > ir.LEAF_MAX_STEPS) return error.LeafAbandon;
        try leafRunInsts(H, allocator, module, func, args, host, depth, b, regs, reclaim, trace, pin, wmask);
        switch (b.terminator) {
            .Return => |r| {
                const rr = r orelse return .Unit;
                return leafRead(regs, wmask.*, rr) orelse return error.LeafAbandon;
            },
            .Goto => |g| block_idx = g.int(),
            .Branch => |br| {
                const c = leafRead(regs, wmask.*, br.cond) orelse return error.LeafAbandon;
                if (c != .Bool) {
                    if (trace) std.debug.print("[leaf] {s}: branch on {s}\n", .{ func.name, @tagName(c) });
                    return error.LeafAbandon;
                }
                block_idx = if (c.Bool) br.t.int() else br.f.int();
            },
            // A guard's throwing arm is admitted structurally but never
            // executed here: raising needs the frame path's unwind machinery.
            // `leafExprBody` admits no other terminator.
            else => return error.LeafAbandon,
        }
    }
}

fn leafRunInsts(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    b: *const ir.Block,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
) (Allocator.Error || LeafAbandon)!void {
    for (b.insts) |*inst| {
        try leafRunOne(H, allocator, module, func, args, host, depth, inst, regs, reclaim, trace, pin, wmask);
    }
}

/// One leaf-body instruction — shared by the Inst-union walker above and
/// the dense-stream walker (`leafWalkStream`), whose `escape` ops land
/// here.
fn leafRunOne(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    inst: *const Inst,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
) (Allocator.Error || LeafAbandon)!void {
    {
        switch (inst.*) {
            .Trace => {},
            .LoadParam => |lp| {
                if (lp.idx >= args.len) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, lp.dst, args[lp.idx], reclaim, true, wmask)) return error.LeafAbandon;
            },
            .Const => |c| {
                if (c.value.int() >= module.consts.items.len) return error.LeafAbandon;
                if (module.consts.items[c.value.int()] == .String) leafPin(pin, regs, wmask);
                const v = try constToValue(allocator, &module.consts.items[c.value.int()]);
                if (!leafWrite(allocator, regs, c.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .Move => |mv| {
                const v = leafRead(regs, wmask.*, mv.src) orelse return error.LeafAbandon;
                if (!leafWrite(allocator, regs, mv.dst, v, reclaim, true, wmask)) return error.LeafAbandon;
            },
            .Not => |n| {
                const v = leafRead(regs, wmask.*, n.src) orelse return error.LeafAbandon;
                if (v != .Bool) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, n.dst, .{ .Bool = !v.Bool }, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .BinOp => |bo| {
                const l = leafRead(regs, wmask.*, bo.lhs) orelse return error.LeafAbandon;
                const r = leafRead(regs, wmask.*, bo.rhs) orelse return error.LeafAbandon;
                if (scalarBin(bo.op, l, r)) |v| {
                    if (!leafWrite(allocator, regs, bo.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
                    return;
                }
                if (!leafPrimitive(&l) or !leafPrimitive(&r)) return error.LeafAbandon;
                const res = try applyBinop(allocator, bo.op, &l, &r);
                if (res != .ok) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, bo.dst, res.ok, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .GetField => |gf| {
                const recv = leafRead(regs, wmask.*, gf.receiver) orelse return error.LeafAbandon;
                if (gf.field.int() >= module.consts.items.len) return error.LeafAbandon;
                const fname: []const u8 = switch (module.consts.items[gf.field.int()]) {
                    .String => |s| s,
                    else => return error.LeafAbandon,
                };
                if (try builtinFieldFast(H, host, allocator, &recv, fname)) |bv| {
                    if (!leafWrite(allocator, regs, gf.dst, bv, reclaim, false, wmask)) return error.LeafAbandon;
                    return;
                }
                if (recv != .Instance) {
                    if (trace) std.debug.print("[leaf] {s}: field receiver is {s}\n", .{ func.name, @tagName(recv) });
                    return error.LeafAbandon;
                }
                const v = try leafStoredField(H, allocator, host, &inst.GetField, &recv, fname, pin, regs, wmask) orelse {
                    if (trace) std.debug.print("[leaf] {s}: no stored-slot route for {s}\n", .{ func.name, fname });
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, gf.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .CallMember => |cm| {
                // The value-level fast serves only: a primitive bit/conversion
                // member is a pure function of its receiver and argument, so
                // the frameless walk can run it. The gap-buffer and trie
                // helpers this exists for (`indexSegment`, the mask/shift
                // predicates) are otherwise a full activation per bit twiddle.
                if (cm.arg_names.len != 0 or cm.n_args > 1) return error.LeafAbandon;
                const recv = leafRead(regs, wmask.*, cm.receiver) orelse return error.LeafAbandon;
                const nm = constStr(module, cm.name) orelse return error.LeafAbandon;
                const marg: ?Value = if (cm.n_args == 1)
                    (leafRead(regs, wmask.*, Reg.from(cm.args.int())) orelse return error.LeafAbandon)
                else
                    null;
                const mv = primitiveMemberOp(&recv, nm, marg) orelse blk: {
                    // `data[idx]` on a container lowers as a `get` member
                    // call in accessor bodies; serve it exactly as the
                    // `.Index` arm below does (a bounds miss abandons to
                    // the framed path, which raises properly).
                    if (marg) |ia| {
                        if (std.mem.eql(u8, nm, "get")) {
                            if (fastIndexGet(&recv, &ia)) |v| break :blk v;
                        }
                    }
                    if (trace) std.debug.print("[leaf] {s}: member {s} is not a primitive op\n", .{ func.name, nm });
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, cm.dst, mv, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .Index => |ix| {
                const recv = leafRead(regs, wmask.*, ix.receiver) orelse return error.LeafAbandon;
                const idx = leafRead(regs, wmask.*, ix.index) orelse return error.LeafAbandon;
                const v = fastIndexGet(&recv, &idx) orelse {
                    if (trace) std.debug.print("[leaf] {s}: index needs the slow get\n", .{func.name});
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, ix.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .LoadGlobal => |lg| {
                // Only a plain-name scalar read is servable: an identity-
                // resolved binding is a function/class value, and anything
                // non-scalar may need the singleton/init/delegate machinery.
                if (comptime !@hasDecl(H, "leafGlobalGet")) return error.LeafAbandon;
                if (lg.func != null or lg.class != null or lg.ctor_ref) return error.LeafAbandon;
                const gname = constStr(module, lg.name) orelse return error.LeafAbandon;
                const v = host.leafGlobalGet(gname) orelse {
                    if (trace) std.debug.print("[leaf] {s}: global {s} not servable\n", .{ func.name, gname });
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, lg.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .Call => |c| {
                if (depth == 0) return error.LeafAbandon;
                if (comptime !@hasDecl(H, "funcRunsItsBody")) return error.LeafAbandon;
                if (c.arg_names.len != 0 or c.type_args.len != 0) return error.LeafAbandon;
                const callee = module.funcById(c.func) orelse return error.LeafAbandon;
                _ = module.ensureFuncBody(@constCast(callee));
                if (!callee.leafExprBody()) {
                    if (trace) {
                        var ninsts: usize = 0;
                        for (callee.blocks) |*cb| ninsts += cb.insts.len;
                        var why: []const u8 = "?";
                        var pflag = false;
                        for (callee.params) |*cp| {
                            if (cp.is_vararg or cp.default != null) pflag = true;
                        }
                        if (pflag) why = "param-default-or-vararg";
                        for (callee.blocks) |*cb| {
                            if (cb.catches.len != 0 or cb.finally != null or cb.lr_absorb != null) why = "try-region";
                            switch (cb.terminator) {
                                .Return, .Goto, .Branch, .Throw, .Unreachable => {},
                                else => |t| {
                                    if (std.mem.eql(u8, why, "?")) why = @tagName(t);
                                },
                            }
                        }
                        std.debug.print("[leaf] {s}: callee {s}#{d} is not a leaf why={s} (blocks={d} locals={d} insts={d} lambda={} suspend={} hopeless={d} state={d})\n", .{
                            func.name, callee.name, callee.id.int(), why, callee.blocks.len, callee.n_locals, ninsts, callee.is_lambda, callee.is_suspend, callee.leaf_hopeless, callee.leaf_state,
                        });
                    }
                    return error.LeafAbandon;
                }
                // A symbol the link step settled onto a native binding, or one
                // that redirects to a sibling declaration, does not run this
                // body at all.
                if (!host.funcRunsItsBody(c.func)) {
                    if (trace) std.debug.print("[leaf] {s}: callee {s} resolves elsewhere\n", .{ func.name, callee.name });
                    return error.LeafAbandon;
                }
                const base = c.args.int();
                if (base + c.n_args > regs.len) return error.LeafAbandon;
                // The arg slice reads raw slots: settle any not-yet-written
                // one to the fill value first (the lazy-fill invariant every
                // masked read enforces individually).
                var ai: usize = base;
                while (ai < base + c.n_args) : (ai += 1) {
                    if (ai < 64 and (wmask.* >> @as(u6, @intCast(ai))) & 1 == 0) {
                        regs[ai] = .{ .Unit = {} };
                        wmask.* |= @as(u64, 1) << @as(u6, @intCast(ai));
                    }
                }
                leafPin(pin, regs, wmask);
                const r = try leafExprServeAt(H, allocator, module, callee, regs[base .. base + c.n_args], host, depth - 1) orelse
                    return error.LeafAbandon;
                if (r != .ok) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, c.dst, r.ok, reclaim, false, wmask)) return error.LeafAbandon;
            },
            else => |other| {
                if (trace) std.debug.print("[leaf] {s}: unsupported {s}\n", .{ func.name, @tagName(other) });
                // Structural: this instruction can never serve, so no
                // future attempt on this body can succeed.
                @constCast(func).leaf_hopeless = 1;
                return error.LeafAbandon;
            },
        }
    }
}


/// `KLIO_LEAF_TRACE=<name>` — report why the frameless leaf serve declined
/// for a matching function.
var leaf_trace_state: u8 = 0;
var leaf_trace_want: []const u8 = "";
fn leafTraceWant(func: *const Func) bool {
    if (leaf_trace_state == 0) {
        leaf_trace_want = runtime.envOnce("KLIO_LEAF_TRACE") orelse "";
        leaf_trace_state = 1;
    }
    if (leaf_trace_want.len == 0) return false;
    if (leaf_trace_want.len == 1 and leaf_trace_want[0] == '*') return true;
    return std.mem.indexOf(u8, func.name, leaf_trace_want) != null;
}

/// The declared members of a builtin receiver that no user declaration can
/// shadow and that the field ladder reaches only after some sixty name
/// comparisons. Array length reads dominate the slow-ladder field census on a
/// composition workload, so answer them without entering the ladder.
fn builtinFieldFast(comptime H: type, host: *H, allocator: Allocator, recv: *const Value, name: []const u8) Allocator.Error!?Value {
    // `indices` / `lastIndex` over any host container with a direct
    // length: the same answers the host field arm computes, minus the
    // ladder. The map CAS loop's `fastForEach` read `List.indices`
    // through the slow ladder 220k times in one run. Both names are
    // SHADOWABLE stdlib extension properties, so the serve is gated on
    // the host's program-wide verdict that no user declaration shadows
    // them (a user `List.indices` must win through the ladder).
    if (std.mem.eql(u8, name, "indices") or std.mem.eql(u8, name, "lastIndex")) {
        const servable = if (comptime @hasDecl(H, "builtinIndexPropsServable")) host.builtinIndexPropsServable() else false;
        if (!servable) return null;
        const len: ?i64 = switch (recv.*) {
            .Array => |a| @intCast(a.len()),
            .List => |l| if (l.backing == null) blk: {
                const g = l.items.borrow();
                defer g.deinit();
                break :blk @intCast(g.get().items.len);
            } else null,
            .Set => |st| if (st.backing == null) blk: {
                const g = st.items.borrow();
                defer g.deinit();
                break :blk @intCast(g.get().items.len);
            } else null,
            else => null,
        };
        if (len) |n| {
            if (name.len == 9) return Value.newInt(@intCast(n - 1));
            return try Value.newRange(allocator, .{ .start = 0, .end = n - 1, .step = 1, .kind = .Int });
        }
    }
    switch (recv.*) {
        .Array => |a| if (std.mem.eql(u8, name, "size")) {
            return Value.newInt(@intCast(a.len()));
        },
        .String => |s| if (std.mem.eql(u8, name, "length")) {
            const g = s.borrow();
            defer g.deinit();
            return Value.newInt(@intCast(g.get().u16_len));
        },
        // Plain container sizes: `backing != null` marks a live VIEW
        // (`subList`, a map's `values`), whose length the view machinery
        // computes — only backing-free containers read their own item
        // list here. `Stack.size` -> `backing.size` otherwise paid the
        // slow field ladder on every read (678k in one recompose test).
        .List => |l| if (l.backing == null and std.mem.eql(u8, name, "size")) {
            const g = l.items.borrow();
            defer g.deinit();
            return Value.newInt(@intCast(g.get().items.len));
        },
        .Set => |st| if (st.backing == null and std.mem.eql(u8, name, "size")) {
            const g = st.items.borrow();
            defer g.deinit();
            return Value.newInt(@intCast(g.get().items.len));
        },
        // Progression `first`/`last`/`step` property reads on a host range
        // value, exactly the host field arm's answers (stored bounds even
        // when empty; `step` in the progression's width). The map CAS
        // loop's `indices` iteration read these through the slow ladder
        // 440k times in one run.
        .Range => |r| {
            if (std.mem.eql(u8, name, "step")) {
                return switch (r.kind) {
                    .Long, .ULong => .{ .Long = r.step },
                    .Int, .Char, .UInt => Value.newInt(@truncate(r.step)),
                };
            }
            const is_first = std.mem.eql(u8, name, "first");
            if (is_first or std.mem.eql(u8, name, "last")) {
                const v: i64 = if (is_first) r.start else r.end;
                return switch (r.kind) {
                    .Int => Value.newInt(@truncate(v)),
                    .Long => .{ .Long = v },
                    .Char => .{ .Char = @truncate(@as(u64, @bitCast(v))) },
                    .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
                    .ULong => .{ .ULong = @bitCast(v) },
                };
            }
        },
        else => {},
    }
    return null;
}

/// Pin the leaf register file as a collector root, once per serve. Called
/// immediately before the first instruction that can reach a safe point.
fn leafPin(pin: *?usize, regs: []Value, wmask: *u64) void {
    if (pin.* != null) return;
    // The keepalive pins the SLICE (the collector reads its current
    // contents), so every slot must hold a valid value before the pin: a
    // no-fill serve zeroes the not-yet-written slots here, paying the fill
    // only on the (rare) pinning path.
    for (regs, 0..) |*v, i| {
        if (i < 64 and wmask.* & (@as(u64, 1) << @intCast(i)) == 0) v.* = .Unit;
    }
    wmask.* = ~@as(u64, 0);
    pin.* = runtime.keepaliveMark();
    runtime.keepalivePushSlice(regs);
}

fn leafRead(regs: []const Value, wmask: u64, r: Reg) ?Value {
    const i = r.int();
    if (i >= regs.len) return null;
    // A slot this serve has not written yet reads as the fill value. The
    // eager whole-bank fill was 15% of the compose slot-table benchmark's
    // profile (millions of serves x n_locals Unit stores); reads are far
    // rarer than slots, so the zero moved here. Reclaim builds keep the
    // eager fill (their teardown releases every slot, so all slots must
    // hold owned values) and pass an all-ones mask.
    if ((wmask >> @as(u6, @truncate(i))) & 1 == 0) return .{ .Unit = {} };
    return regs[i];
}

/// Store into the leaf register file with the same ownership rule a frame
/// uses: the register owns one reference, the previous occupant loses one.
/// `borrowed` marks a value the leaf does not yet own a reference to.
fn leafWrite(allocator: Allocator, regs: []Value, r: Reg, v: Value, reclaim: bool, borrowed: bool, wmask: *u64) bool {
    const i = r.int();
    if (i >= regs.len) return false;
    if (i < 64) wmask.* |= @as(u64, 1) << @intCast(i);
    if (reclaim) {
        if (borrowed) v.retain();
        const old = regs[i];
        regs[i] = v;
        old.release(allocator);
    } else {
        regs[i] = v;
    }
    return true;
}

/// The stored-slot read of one `GetField` in a leaf body, using the
/// instruction's own claimed (class, slot) route — the same single-fill site
/// memo the framed `GetField` arm fills and re-verifies by name. Null for a
/// getter-routed, unclaimed, lateinit or delegated field, which the leaf
/// cannot serve.
fn leafStoredField(comptime H: type, allocator: Allocator, host: *H, gf: anytype, recv: *const Value, fname: []const u8, pin: *?usize, regs: []Value, wmask: *u64) Allocator.Error!?Value {
    const claimed = @atomicLoad(u64, @constCast(&gf.site_cls), .acquire);
    const cls: u64 = blk: {
        const g = recv.Instance.borrow();
        defer g.deinit();
        break :blk @intCast(g.get().class.identity());
    };
    if (claimed == 0) {
        // First execution claims the site for this class when the shared
        // (class, name) memo already routes the read to a stored slot or to
        // a getter that is itself a leaf. For a stored route the layout id
        // is bound to the verified index under one borrow, so a replay
        // matching BOTH class and shape skips the per-hit verify.
        if (host.fieldSiteRoute(recv, fname)) |route| {
            const usable = switch (route.route & 3) {
                1, 3 => true,
                2 => host.fieldGetterIsLeaf(@enumFromInt(route.route >> 2)),
                else => false,
            };
            const shp: u64 = blk2: {
                const g = recv.Instance.borrow();
                defer g.deinit();
                const b = g.get();
                if (route.route & 3 != 1) break :blk2 0;
                const idx2: usize = @intCast(route.route >> 2);
                if (idx2 >= b.fields.items.len) break :blk2 0;
                const f2 = &b.fields.items[idx2];
                if (!std.mem.eql(u8, f2.name, fname) and !leafSgetterMatches(fname, f2.name)) break :blk2 0;
                const sp = b.shapeOf();
                break :blk2 if (sp > 1) sp else 0;
            };
            if (usable and
                @cmpxchgStrong(u64, @constCast(&gf.site_cls), 0, route.cls, .acq_rel, .monotonic) == null)
            {
                if (shp != 0) @atomicStore(u64, @constCast(&gf.site_shape), shp, .monotonic);
                @atomicStore(u64, @constCast(&gf.site_route), route.route, .release);
            }
        }
        return null;
    }
    // A POLYMORPHIC site (`op.ints` inside `Operations.pushOp`, where `op` is
    // any of the changelist's ~40 Operation subclasses) claims one class and
    // then sees another on nearly every call. Declining there sent the whole
    // body — one of the hottest in a recomposition — to the frame path
    // forever. The per-site claim is only a fast path: on a miss, ask the
    // shared (class, name) memo, which answers from its own cache — its
    // index is NOT shape-checked, so that path keeps the name verify.
    var route = @atomicLoad(u64, @constCast(&gf.site_route), .acquire);
    var mono_claim = true;
    if (claimed != cls) {
        const alt = host.fieldSiteRoute(recv, fname) orelse return null;
        if (alt.cls != cls) return null;
        route = alt.route;
        mono_claim = false;
    }
    // A property whose backing is another leaf property chains through it:
    // the callee is pure by construction, so re-running it if this serve is
    // later abandoned observes nothing.
    if (route & 3 == 2) {
        if (!host.fieldGetterIsLeaf(@enumFromInt(route >> 2))) return null;
        leafPin(pin, regs, wmask);
        return switch (try host.runFieldGetter(allocator, @enumFromInt(route >> 2), recv.*)) {
            .ok => |v| v,
            .err => null,
        };
    }
    if (route & 3 == 3) return serveOuterSlotRoute(recv, fname, route);
    if (route & 3 != 1) return null;
    const idx: usize = @intCast(route >> 2);
    const g = recv.Instance.borrow();
    defer g.deinit();
    const b = g.get();
    const fields = b.fields.items;
    if (idx >= fields.len) return null;
    const f = &fields[idx];
    // A mono claim whose recorded LAYOUT matches the live receiver proves
    // the index; anything else pays the name verify.
    const shape_ok = mono_claim and
        @atomicLoad(u64, @constCast(&gf.site_shape), .monotonic) == b.shapeOf();
    if (!shape_ok and !std.mem.eql(u8, f.name, fname) and !leafSgetterMatches(fname, f.name)) return null;
    const v = f.value;
    if (v == .Null or v == .Delegate) return null;
    // Owned on the way out, matching the getter branch above: the register
    // file this lands in releases what it holds.
    v.retain();
    return v;
}

/// A scoped `$sgetter$<owner>\u{1f}<prop>` site stores its slot under the
/// bare property name; match the separator-guarded suffix so the drift guard
/// stays exact.
fn leafSgetterMatches(name: []const u8, field_name: []const u8) bool {
    return std.mem.startsWith(u8, name, "$sgetter$") and
        name.len > field_name.len and
        std.mem.endsWith(u8, name, field_name) and
        name[name.len - field_name.len - 1] == '\u{1f}';
}

/// Run a function body, routing non-trivial dispatch (`CallValue` /
/// `CallMember` / `NewInstance` / `InstanceOf`) through the supplied
/// host implementation. `H` is the concrete host type, supplied at the
/// call site (`VmHost` in the interpreter, `NullHost` in ir's own tests);
/// every `host.method(...)` is a comptime-duck-typed direct call.
pub fn evalWith(comptime H: type, allocator: Allocator, module: *const Module, func: *const Func, args: std.ArrayList(Value), host: *H) Allocator.Error!EvalResult {
    dumpFnIfRequested(module, func);
    boolThisTrap(func, args.items);
    return evalWithCaptures(H, allocator, module, func, args, .empty, host);
}

/// `KLIO_THIS_TRAP=1`: print every frame entry that binds a Bool into a
/// `this` parameter — the ext-receiver misbind signature — with the caller.
var bool_this_trap_state: u8 = 0;
pub fn boolThisTrap(func: *const Func, args: []const Value) void {
    // Consulted per flat-call open: cache the env verdict once.
    if (bool_this_trap_state == 0)
        bool_this_trap_state = if (runtime.envOnce("KLIO_THIS_TRAP") != null) 2 else 1;
    if (bool_this_trap_state != 2) return;
    if (func.params.len == 0 or args.len == 0) return;
    if (!std.mem.eql(u8, func.params[0].name, "this")) return;
    if (args[0] != .Bool and args[0] != .Int) return;
    const cf = currentFrameFunc();
    std.debug.print("[this-trap] fn={s}#{d} nargs={d} caller={s}#{d} vals:", .{
        func.fqn,
        func.id.int(),
        args.len,
        if (cf) |c| c.fqn else "<none>",
        if (cf) |c| c.id.int() else 0,
    });
    for (args) |a| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(a))});
    std.debug.print("\n", .{});
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
        const w = runtime.envOnce("KLIO_DUMP_FN") orelse "";
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
    } else if (std.mem.indexOfScalar(u8, want, '.') != null) {
        if (!std.mem.eql(u8, func.fqn, want)) return;
    } else if (!std.mem.eql(u8, func.name, want)) return;
    // A deferred body has no blocks yet; wait for the post-materialize call.
    if (func.blocks.len == 0) return;
    dump_fn_done = true;
    std.debug.print("[dump-fn] {s}#{d} params={d} blocks={d} recv_ty={?s} caps=", .{ func.fqn, func.id.int(), func.params.len, func.blocks.len, func.lambda_receiver_ty });
    for (func.capture_order) |cn| std.debug.print("{s},", .{cn});
    std.debug.print("\n", .{});
    for (func.blocks, 0..) |*blk, bi| {
        std.debug.print("  block {d}:\n", .{bi});
        for (blk.insts, 0..) |*inst, ii| {
            std.debug.print("    {d}: {s}", .{ ii, @tagName(std.meta.activeTag(inst.*)) });
            switch (inst.*) {
                .LoadGlobal => |x| std.debug.print(" name={s} func={?}", .{ constStr(module, x.name) orelse "?", if (x.func) |f| f.int() else null }),
                .GetField => |x| std.debug.print(" field={s} recv=r{d} dst=r{d}", .{ constStr(module, x.field) orelse "?", x.receiver.int(), x.dst.int() }),
                .LoadFromThisOrGlobal => |x| std.debug.print(" name={s} func={?}", .{ constStr(module, x.name) orelse "?", if (x.func) |f| f.int() else null }),
                .CallMemberOrGlobal => |x| std.debug.print(" name={s} recv={?d} this_idx={d} dst=r{d}", .{ constStr(module, x.name) orelse "?", if (x.recv) |r| r.int() else null, x.this_idx, x.dst.int() }),
                .CallMember => |x| std.debug.print(" name={s} recv=r{d} resolved={?d}", .{ constStr(module, x.name) orelse "?", x.receiver.int(), if (x.resolved) |f| f.int() else null }),
                .LoadCapture => |x| std.debug.print(" idx={d} dst=r{d}", .{ x.idx, x.dst.int() }),
                .Move => |x| std.debug.print(" dst=r{d} src=r{d}", .{ x.dst.int(), x.src.int() }),
                .AstLambda => |x| std.debug.print(" dst=r{d} body=#{?d}", .{ x.dst.int(), if (x.body_func) |bf| bf.int() else null }),
                .Call => |x| std.debug.print(" func=#{d} dst=r{d} args=r{d}+{d} exact={}", .{ x.func.int(), x.dst.int(), x.args.int(), x.n_args, x.exact }),
                .BinOp => |x| std.debug.print(" op={s} dst=r{d} lhs=r{d} rhs=r{d}", .{ @tagName(x.op), x.dst.int(), x.lhs.int(), x.rhs.int() }),
                .CallVirtual => |x| std.debug.print(" slot={d} recv=r{d} dst=r{d}", .{ x.slot.int(), x.receiver.int(), x.dst.int() }),
                else => {},
            }
            std.debug.print("\n", .{});
        }
        switch (blk.terminator) {
            .Branch => |br| std.debug.print("    term: Branch cond=r{d} t={d} f={d}\n", .{ br.cond.int(), br.t.int(), br.f.int() }),
            else => std.debug.print("    term: {s}\n", .{@tagName(std.meta.activeTag(blk.terminator))}),
        }
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
    boolThisTrap(func, args.items);
    // The recursive call seam. A leaf-expression callee reached here needs
    // none of the frame below it, and this is the one point every
    // interpreted call passes through, whatever route resolved it. A
    // callee with a registered transpiled body takes the frame path
    // instead so its emitted C runs (free everywhere else: the native
    // table is empty in a non-transpiled process).
    if (owning == null and closure_id == null and chain_seed.len == 0 and
        captures.items.len == 0 and func.leafExprBody() and
        (!nativeModuleOk(module) or nativeFor(func.id.int(), func.fqn) == null))
    {
        if (try leafExprServe(H, allocator, module, func, args.items, host)) |lr| {
            var a = args;
            a.deinit(allocator);
            var c = captures;
            c.deinit(allocator);
            return lr;
        }
    }
    // The METHOD tier at the seam: a deopt-free compiled method body (pure
    // native function over receiver fields + scalar args — no calls, no
    // guards, RETURN its only outcome) runs with no frame regardless of the
    // chain seed (it consults neither the chain nor any register file). The
    // seam also counts and triggers the compile: member-dispatched bodies
    // reach neither the framed entry hook nor (when fusable) any frame.
    if (comptime @hasDecl(H, "plainStoredFieldIndex") and @hasDecl(H, "plainStoredScalarFieldNN") and @hasDecl(H, "resolveMemberFuncId")) {
        switch (jit_loop.methodSeamProbe(func)) {
            .run => |cl| if (args.items.len >= func.params.len and
                evtls.jit_native_depth < NATIVE_SLOT_BANK_DEPTH and cl.n_slots <= 192)
            {
                const fslots: []i64 = &native_slot_bank[evtls.jit_native_depth];
                const ftags: []u8 = &native_tag_bank[evtls.jit_native_depth];
                evtls.jit_native_depth += 1;
                const fo = jit_loop.runFunc(cl, &.{}, args.items, fslots[0..cl.n_slots], ftags[0..cl.n_regs], null, null);
                evtls.jit_native_depth -= 1;
                if (fo == null and runtime.envOnce("KLIO_JIT_DEBUG") != null) {
                    std.debug.print("[jit]   seam run DECLINED {s}\n", .{func.name});
                }
                if (fo) |o| {
                    if (o.code.inst == jit_loop.RETURN_INST) {
                        var aa = args;
                        aa.deinit(allocator);
                        var cc = captures;
                        cc.deinit(allocator);
                        return ok(o.value);
                    }
                }
                // Guard/kind decline: the body never executed — run it framed.
            },
            .compile => {
                // Compile-only resolver context: the three resolvers read only
                // host + allocator; the frame member is never touched here.
                var cctx: LoopTramp(H).Ctx = .{ .host = host, .allocator = allocator, .module = module, .frame = undefined };
                jit_loop.methodSeamCompile(module, func, args.items, &LoopTramp(H).resolveMember, &LoopTramp(H).resolveVirtual, &LoopTramp(H).resolveField, &LoopTramp(H).resolveFieldNN, @ptrCast(&cctx));
            },
            .no => {},
        }
    }
    // The fused tier at the same seam: a transitively closed body runs on
    // the C bank with no Frame at all, raising real errors (never
    // abandoning) — see `fusedExec`.
    if (owning == null and closure_id == null and chain_seed.len == 0 and
        captures.items.len == 0 and
        (!nativeModuleOk(module) or nativeFor(func.id.int(), func.fqn) == null))
    {
        if (try fusedExecOpt(H, allocator, module, func, args.items, host, true)) |fr| {
            var a = args;
            a.deinit(allocator);
            var c = captures;
            c.deinit(allocator);
            return fr;
        }
    }
    // Host-route serve at the same seam: a routed target (the snapshot walk
    // family) reached through ANY dispatch path — overload ranking, value
    // invocation, extension fallback — serves here without a frame. The
    // static-call and CMG-replay intercepts cannot see a target the overload
    // leg resolves natively (`readable` inside `writableRecord` rode that
    // route at 1.1 frames per map insert). Args are already settled in param
    // order, which is exactly the shape the serves take.
    // A host-served target is a pure function of (receiver, args) by
    // construction, so a chain SEED does not disqualify it: the seed only
    // matters to a framed body, and member calls always carry one — which
    // silently kept every serve off the member-call path (`Operations.push`
    // framed 4% of vpd with its serve sitting right here).
    if (owning == null and closure_id == null and captures.items.len == 0) {
        if (exec_call.hostRouteServe(H, allocator, func, args.items, host)) |served| {
            var a = args;
            a.deinit(allocator);
            var c = captures;
            c.deinit(allocator);
            return ok(served);
        }
        if (try exec_call.hostRouteServeThrowing(H, allocator, module, func, args.items, host)) |r| {
            var a = args;
            a.deinit(allocator);
            var c = captures;
            c.deinit(allocator);
            return r;
        }
    }
    callStatsBumpId(func.fqn, func.id.int(), module);
    const ev: *EvalTls = &evtls;
    var try_stack: std.ArrayList(TryFrame) = .empty;
    defer try_stack.deinit(allocator);
    // Kotlin's SAM conversion happens at the CALL boundary: a lambda bound to
    // a `fun interface` parameter arrives as an instance of that interface.
    // Activation setup is the one point every call shape passes through.
    if (comptime @hasDecl(H, "samConvertActivationArgs")) {
        try host.samConvertActivationArgs(allocator, func, args.items);
    }
    var frame = try Frame.newWithCaptures(ev, allocator, module, func, args, captures);
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
                if (runtime.envOnce("KLIO_AMP_TRACE")) |w| {
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
    // The replay activates and deactivates a rebuilt frame per snapshot;
    // the per-frame prev-chain captures are only coherent while the replay
    // runs, and a deactivation cascade could leave the thread's active
    // chain pointing at a rebuilt frame's list AFTER that frame was torn
    // down — the next fresh call on this thread then merged its enclosing
    // chain from freed memory (the cross-thread yield GPF). Pin the
    // pre-replay chain and restore it on every exit.
    const saved_chain = evtls.active_chain;
    const saved_chain_base = evtls.active_chain_base;
    defer {
        evtls.active_chain = saved_chain;
        evtls.active_chain_base = saved_chain_base;
    }
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
        var frame = try Frame.newWithCaptures(&evtls, allocator, m, func, params, caps);
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
                // The sparse snapshot recorded only live registers over a
                // Unit base; a no-fill frame must materialize that base
                // before the entries land on it.
                frame.materializeRegs();
                for (entries) |entry| {
                    if (entry.id < frame.regs.items.len) frame.regs.items[entry.id] = entry.value;
                }
            },
            .dense => |values| {
                frame.regs.clearRetainingCapacity();
                try frame.regs.appendSlice(regsAlloc(allocator), values);
                frame.wmask.setAll();
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
                if (head < frames.items.len) {
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
                } else if (tails.* != null) {
                    // This list is drained: hand the inherited chain through
                    // WITHOUT wrapping an empty segment around it — every
                    // park/resume cycle of a suspending loop otherwise grew
                    // the parked state's chain by one dead segment, forever.
                    var slot: *?*TailSeg = &inner.tails;
                    while (slot.*) |t| slot = &t.next;
                    slot.* = tails.*;
                    tails.* = null;
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
    if (evtls.eval_depth == 0) _ = threads_in_eval.fetchAdd(1, .monotonic);
    evtls.eval_depth += 1;
    defer {
        evtls.eval_depth -= 1;
        // Safe point: back at the outermost activation, no native JIT frame is on
        // the stack, so the JIT cache can be trimmed if it has grown past its cap.
        if (evtls.eval_depth == 0) {
            _ = threads_in_eval.fetchSub(1, .monotonic);
            jit_loop.evictIfOverBudget();
        }
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
    // The snapshot copies (and under reclaim retains) the whole file, and
    // the collector traces the copy; give it a fully-defined file.
    frame.materializeRegs();
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

/// Per-thread activation freelist. Direct interpreted calls open one
/// activation each; without the pool every call paid an allocator
/// create/destroy for a ~300-byte struct. Pooled only under the tracing GC
/// (whose stable `c_allocator` backing the regs pool also uses); the
/// refcounting/arena backends keep plain create/destroy. Entries are inert
/// storage — no Values, nothing the GC must see.
const ACT_POOL_MAX = 128;

inline fn actPoolOn() bool {
    return !runtime.reclaimEnabled() and runtime.gc.gc_enabled;
}

fn actAlloc(ev: *EvalTls, allocator: Allocator) Allocator.Error!*Activation {
    if (actPoolOn()) {
        if (ev.act_pool_len > 0) {
            ev.act_pool_len -= 1;
            return ev.act_pool[ev.act_pool_len];
        }
        return std.heap.c_allocator.create(Activation);
    }
    return allocator.create(Activation);
}

fn actFree(ev: *EvalTls, allocator: Allocator, act: *Activation) void {
    if (actPoolOn()) {
        if (ev.act_pool_len < ACT_POOL_MAX) {
            ev.act_pool[ev.act_pool_len] = act;
            ev.act_pool_len += 1;
            return;
        }
        std.heap.c_allocator.destroy(act);
        return;
    }
    allocator.destroy(act);
}

/// Open a flat activation for a direct interpreted call: the same entry
/// sequence `evalWithCapturesChained` performs for a recursive call (frame
/// construction with the arg buffer transferred as params, GC chain push,
/// lexical receiver-chain activation, context-parameter seeding).
fn openActivation(comptime H: type, allocator: Allocator, caller_module: *const Module, req: FlatCallReq, host: *H) Allocator.Error!*Activation {
    const ev: *EvalTls = &evtls;
    boolThisTrap(req.func, req.args.items);
    const module = req.run_module orelse caller_module;
    dumpFnIfRequested(module, req.func);
    // SAM conversion at the call boundary, as `evalWithCapturesChained` does
    // for the recursive path — the flat activation is the other way in.
    if (comptime @hasDecl(H, "samConvertActivationArgs")) {
        try host.samConvertActivationArgs(allocator, req.func, req.args.items);
    }
    const act = try actAlloc(ev, allocator);
    errdefer actFree(ev, allocator, act);
    act.* = .{
        .frame = try Frame.newWithCaptures(ev, allocator, module, req.func, req.args, req.captures),
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
    actFree(&evtls, allocator, act);
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
    // A live-parked activation may resume on a DIFFERENT worker thread than
    // the one that parked it (the pool rotates, and the parker may already
    // have exited — the daemon-abandon teardown races exactly this way).
    // Rebind the frame to the RESUMING thread's eval TLS first; the parked
    // pointer otherwise dereferences a dead thread's storage.
    act.frame.tls = &evtls;
    gcPushFrame(&act.frame);
    act.frame.activateAs();
    if (resume_throw == null) {
        if (resume_reg) |r| try act.frame.write(r, carry);
    }
    const res = try runFlatLoop(H, allocator, &act.frame, &act.try_stack, block, inst_idx, resume_throw, resume_unwind, act, host);
    if (res == .err and res.err == .Suspended) return res;
    const out = frameBoundary(act.frame.func, res);
    teardownActivation(H, allocator, act, host);
    actFree(&evtls, allocator, act);
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
    const ev: *EvalTls = &evtls;
    var stack: std.ArrayList(*Activation) = .empty;
    defer stack.deinit(allocator);
    // On an allocation failure, unwind every open activation so no frame is
    // left dangling on the GC chain.
    errdefer while (stack.pop()) |act| {
        ev.eval_depth -= 1;
        teardownActivation(H, allocator, act, host);
        actFree(ev, allocator, act);
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
            // A leaf-expression callee needs none of the activation: serve it
            // here and deliver its value straight into the caller's register.
            // This is the seam every direct call passes through, so it covers
            // plain calls the member and getter entries never see.
            // The module the callee's body must be READ against. A request
            // that names one is authoritative; otherwise the caller's module
            // is right only when it actually owns this `Func`. An anonymous
            // object's runtime module delegates base funcs through the shared
            // lazy header section but carries only its own const pool, so a
            // callee reached from there would read const ids outside it.
            const callee_mod: *const Module = site.req.run_module orelse blk_cm: {
                if (funcOwnedBy(f.module, site.req.func)) break :blk_cm f.module;
                if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                    if (host.ownerModuleForFunc(site.req.func)) |m| break :blk_cm m;
                }
                break :blk_cm f.module;
            };
            // A host-served compose helper answers before any activation
            // opens, on the flat path as well as the recursive seam: the
            // composer's stacks are reached through both. A pending
            // enclosing pop or chain seed is fine — `discardFlatReq` undoes
            // everything the request set up.
            if (site.req.captures.items.len == 0 and site.req.closure_id == null and
                site.req.type_args.len == 0 and !site.req.composer_pushed)
            {
                // The seam method tier on the flat path: a deopt-free
                // compiled method body serves the request natively (RETURN
                // is its only outcome). Counting/compiling stays on the
                // recursive seam; this arm only RUNS an already-compiled one.
                if (comptime @hasDecl(H, "plainStoredFieldIndex")) run: {
                    const cl = jit_loop.methodSeamPeek(site.req.func) orelse break :run;
                    if (site.req.args.items.len < site.req.func.params.len or
                        evtls.jit_native_depth >= NATIVE_SLOT_BANK_DEPTH or cl.n_slots > 192) break :run;
                    const fslots: []i64 = &native_slot_bank[evtls.jit_native_depth];
                    const ftags: []u8 = &native_tag_bank[evtls.jit_native_depth];
                    evtls.jit_native_depth += 1;
                    const fo = jit_loop.runFunc(cl, &.{}, site.req.args.items, fslots[0..cl.n_slots], ftags[0..cl.n_regs], null, null);
                    evtls.jit_native_depth -= 1;
                    if (fo) |o| {
                        if (o.code.inst == jit_loop.RETURN_INST) {
                            const dst = site.req.dst;
                            discardFlatReq(H, allocator, site.req, host);
                            try f.write(dst, o.value);
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        }
                    }
                }
                if (exec_call.hostRouteServe(H, allocator, site.req.func, site.req.args.items, host)) |served| {
                    const dst = site.req.dst;
                    discardFlatReq(H, allocator, site.req, host);
                    try f.write(dst, served);
                    cur = site.ret_block;
                    ridx = site.ret_idx;
                    continue;
                }
                if (try exec_call.hostRouteServeThrowing(H, allocator, callee_mod, site.req.func, site.req.args.items, host)) |r| {
                    const dst = site.req.dst;
                    discardFlatReq(H, allocator, site.req, host);
                    switch (r) {
                        .ok => |v| {
                            try f.write(dst, v);
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        },
                        .err => |e| switch (e) {
                            .Throw => |v| {
                                rthrow = v;
                                cur = site.ret_block;
                                ridx = site.ret_idx;
                                continue;
                            },
                            else => {
                                runwind = e;
                                cur = site.ret_block;
                                ridx = site.ret_idx;
                                continue;
                            },
                        },
                    }
                }
            }
            if (site.req.captures.items.len == 0 and site.req.closure_id == null and
                site.req.type_args.len == 0 and !site.req.composer_pushed and
                site.req.chain.len == 0)
            fused: {
                const callee_mod2 = blk_cm2: {
                    if (funcOwnedBy(f.module, site.req.func)) break :blk_cm2 f.module;
                    if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                        if (host.ownerModuleForFunc(site.req.func)) |m| break :blk_cm2 m;
                    }
                    break :blk_cm2 f.module;
                };
                const fr = (try fusedExecOpt(H, allocator, callee_mod2, site.req.func, site.req.args.items, host, true)) orelse break :fused;
                const dst = site.req.dst;
                discardFlatReq(H, allocator, site.req, host);
                switch (fr) {
                    .ok => |v| {
                        try f.write(dst, v);
                        cur = site.ret_block;
                        ridx = site.ret_idx;
                        continue;
                    },
                    .err => |e| switch (e) {
                        // The flat protocol: a throw re-enters the caller
                        // through `rthrow` so its catch handlers dispatch;
                        // only the non-catchable unwinds ride `runwind`.
                        .Throw => |v| {
                            rthrow = v;
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        },
                        else => {
                            runwind = e;
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        },
                    },
                }
            }
            if (leafReqServable(site.req)) {
                // A flat request carries the callee's `Func` directly, but the
                // module its body must be READ against is only known when the
                // request names one. Falling back to the caller's module is
                // wrong whenever the callee was resolved in a different one:
                // its const and func ids index that module's tables, and an
                // anonymous object's one-function runtime module has neither
                // (`androidx.compose.runtime.report`, id 15036, served against
                // a module of 1 func and 6 consts, read const 9028).
                if (try leafExprServe(H, allocator, callee_mod, site.req.func, site.req.args.items, host)) |lr| {
                    const dst = site.req.dst;
                    discardFlatReq(H, allocator, site.req, host);
                    try f.write(dst, lr.ok);
                    cur = site.ret_block;
                    ridx = site.ret_idx;
                    continue;
                }
            }
            // Same depth bound as the recursive path: an unbounded interpreted
            // recursion becomes a catchable StackOverflowError at the caller.
            if (ev.eval_depth >= maxEvalDepth()) {
                dumpFrameChainForDiag();
                discardFlatReq(H, allocator, site.req, host);
                runwind = .{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" };
                cur = site.ret_block;
                ridx = site.ret_idx;
                continue;
            }
            ev.eval_depth += 1;
            const act = openActivation(H, allocator, callee_mod, site.req, host) catch |e| {
                ev.eval_depth -= 1;
                return e;
            };
            act.ret_block = site.ret_block;
            act.ret_idx = site.ret_idx;
            stack.append(allocator, act) catch |e| {
                ev.eval_depth -= 1;
                teardownActivation(H, allocator, act, host);
                actFree(ev, allocator, act);
                return e;
            };
            cur = site.req.func.entry;
            ridx = 0;
            // Function-tier attempt for the fresh activation: the framed
            // entry hook lives only in runFrameExec's generic loop, and the
            // flat driver is the path member- and bc-driven calls actually
            // take. Function-mode bodies are suspension-free by
            // construction, so the outcomes are exactly RETURN (deliver as
            // the driver's own completion), a real throw, or a deopt that
            // resumes interpretation at the outcome point in this frame.
            if (comptime @hasDecl(H, "callFunc")) hook: {
                if (!jit_loop.funcEnabled()) break :hook;
                if (runtime.envOnce("KLIO_FJ_FLATHOOK")) |v| {
                    if (v.len != 0 and v[0] == '0') break :hook;
                }
                var hctx: LoopTramp(H).Ctx = .{ .host = host, .allocator = allocator, .module = act.frame.module, .frame = &act.frame };
                const mres: ?jit_loop.MemberResolver = if (comptime @hasDecl(H, "resolveMemberFuncId")) &LoopTramp(H).resolveMember else null;
                const vres: ?jit_loop.VirtResolver = if (comptime @hasDecl(H, "resolveVirtualFuncId")) &LoopTramp(H).resolveVirtual else null;
                const fres: ?jit_loop.FieldResolver = if (comptime @hasDecl(H, "plainStoredFieldIndex")) &LoopTramp(H).resolveField else null;
                const fnres: ?jit_loop.FieldResolver = if (comptime @hasDecl(H, "plainStoredScalarFieldNN")) &LoopTramp(H).resolveFieldNN else null;
                const fo = jit_loop.maybeRunHotFunc(act.frame.module, site.req.func, &act.frame.regs, act.frame.params.items, act.frame.captures.items, allocator, &LoopTramp(H).call, @ptrCast(&hctx), mres, vres, fres, fnres) orelse break :hook;
                if (fo.code.inst == jit_loop.RETURN_INST) {
                    var res2: EvalResult = ok(fo.value);
                    const act2 = stack.pop().?;
                    ev.eval_depth -= 1;
                    res2 = frameBoundary(act2.frame.func, res2);
                    if (act2.root_pump) {
                        if (comptime @hasDecl(H, "rootPumpFlatComplete")) {
                            res2 = try host.rootPumpFlatComplete(allocator, res2, act2.keepalive orelse .Unit, act2.barrier_scope_base);
                        }
                    }
                    if (act2.type_args.len > 0) {
                        if (comptime @hasDecl(H, "typedCallBoundary")) host.typedCallBoundary(act2.frame.module, act2.frame.func, act2.type_args, &res2);
                    }
                    const rb2 = act2.ret_block;
                    const rix2 = act2.ret_idx;
                    const rd2 = act2.ret_dst;
                    teardownActivation(H, allocator, act2, host);
                    actFree(ev, allocator, act2);
                    const pf2: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
                    switch (res2) {
                        .ok => |v| {
                            try pf2.write(rd2, v);
                            cur = rb2;
                            ridx = rix2;
                        },
                        .err => |e2| switch (e2) {
                            .Throw => |v| {
                                rthrow = v;
                                cur = rb2;
                                ridx = rix2;
                            },
                            else => {
                                runwind = e2;
                                cur = rb2;
                                ridx = rix2;
                            },
                        },
                    }
                    continue;
                }
                if (fo.code.inst == jit_loop.THROW_INST) {
                    if (runtime.envOnce("KLIO_JIT_DEBUG") != null) std.debug.print("[jit-dbg] flat THROW {s}\n", .{site.req.func.fqn});
                    const e2 = hctx.pending.?;
                    hctx.pending = null;
                    switch (e2) {
                        .Throw => |exc| {
                            rthrow = exc;
                            cur = fo.code.block;
                            ridx = 0;
                        },
                        else => {
                            runwind = e2;
                            cur = fo.code.block;
                            ridx = 0;
                        },
                    }
                    continue;
                }
                // Deopt: resume interpretation at the outcome point (the
                // frame's written scalar registers were reboxed by runFunc).
                // A handler-issued deopt carries the sentinel and records the
                // resume instruction on the context; a native one (div by
                // zero) encodes the instruction directly.
                if (runtime.envOnce("KLIO_JIT_DEBUG") != null) std.debug.print("[jit-dbg] flat DEOPT {s} b={d} i={d}\n", .{ site.req.func.fqn, fo.code.block, fo.code.inst });
                cur = fo.code.block;
                ridx = if (fo.code.inst == jit_loop.DEOPT_INST) hctx.pending_deopt_inst else fo.code.inst;
            }
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
                ev.eval_depth -= 1;
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
            ev.eval_depth -= 1;
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
            actFree(ev, allocator, act);
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
            /// Set alongside `pending` when a trampolined callee SUSPENDED:
            /// the call site's instruction index and result register, so the
            /// interpreter can park this frame at the call exactly as the
            /// interpreted path would (block, inst+1, resume reg). Without
            /// it the suspension propagated as a plain error and the loop
            /// frame fell out of the continuation — a JITted `for` sending
            /// into a channel silently lost every element after the tier-up.
            pending_suspend_inst: u32 = 0,
            pending_suspend_dst: ?Reg = null,
        };

        fn stashErr(lc: *Ctx, e: EvalError, inst: u32, dst: ?Reg) void {
            lc.pending = e;
            if (e == .Suspended) {
                lc.pending_suspend_inst = inst;
                lc.pending_suspend_dst = dst;
            }
        }

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
        /// ESCAPE: run the interpreter's own arm for one instruction against
        /// the live frame. Full scalar sync both ways — before: every
        /// scalar-typed register's slot reboxes into the frame; after: each
        /// reboxes back (a kind change deopts AT THE NEXT instruction — the
        /// arm's effects are real and the frame is already correct).
        noinline fn execEscapeSite(tctx: *jit_loop.TrampCtx, lc: *Ctx, cl: anytype, site: anytype) ?u64 {
            const n = cl.n_regs;
            var r: u32 = 0;
            while (r < n) : (r += 1) {
                switch (cl.reg_types[r]) {
                    .i32, .i64, .f64, .f32, .boolean => {
                        if (r < lc.frame.regs.items.len)
                            lc.frame.regs.items[r] = jit_loop.valueFromSlotTagged(cl.reg_types[r], tctx.tags[r], tctx.slots[r]);
                    },
                    else => {},
                }
            }
            if (site.span) |sp| lc.frame.cur_span = sp;
            const step = execInst(H, lc.allocator, lc.frame, site.exec_inst.?, lc.host) catch {
                lc.pending = .{ .Type = "out of memory in JIT escape" };
                return jit_loop.throwCode(site.block);
            };
            switch (step) {
                .cont => {},
                .raised => {
                    const e = lc.frame.step_err.?;
                    lc.frame.step_err = null;
                    stashErr(lc, e, site.inst, null);
                    return jit_loop.throwCode(site.block);
                },
                .flat_call => {
                    // The arm prepared a flat request but ran nothing:
                    // discard it and deopt AT this instruction so the
                    // interpreter re-runs it with its own flat machinery.
                    const req = lc.frame.flat_call.?;
                    lc.frame.flat_call = null;
                    discardFlatReq(H, lc.allocator, req, lc.host);
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                },
            }
            r = 0;
            while (r < n) : (r += 1) {
                switch (cl.reg_types[r]) {
                    .i32, .i64, .f64, .f32, .boolean => {
                        if (r >= lc.frame.regs.items.len) continue;
                        const v = lc.frame.regs.items[r];
                        const sv = jit_loop.cellSlotIn(cl.reg_types[r], v) orelse {
                            lc.pending_deopt_inst = site.inst + 1;
                            return jit_loop.deoptCode(site.block);
                        };
                        tctx.slots[r] = sv;
                        if (cl.reg_types[r] == .i32) tctx.tags[r] = @intFromEnum(std.meta.activeTag(v));
                    },
                    else => {},
                }
            }
            return 0;
        }

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
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[site.src_reg], tctx.tags[site.src_reg], tctx.slots[site.src_reg]),
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
                const idx_v = jit_loop.valueFromSlotTagged(cl.reg_types[site.args_reg], tctx.tags[site.args_reg], tctx.slots[site.args_reg]);
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
                var argbuf2: [6]Value = undefined;
                var k2: usize = 0;
                while (k2 < site.n_args) : (k2 += 1) {
                    const ar = @as(usize, site.args_reg) + k2;
                    const tr2: usize = if (k2 < 3 and site.arg_tag_regs[k2] != 0) site.arg_tag_regs[k2] else ar;
                    argbuf2[k2] = switch (cl.reg_types[ar]) {
                        .object => lc.frame.regs.items[ar],
                        .null_ => .Null,
                        else => jit_loop.valueFromSlotTagged(cl.reg_types[ar], tctx.tags[tr2], tctx.slots[ar]),
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
                                stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
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
                        stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            // Map store `map[key] = value`; result discarded.
            if (site.is_map_set) {
                if (comptime !@hasDecl(H, "callMemberNamed")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const m = lc.frame.regs.items[site.recv_reg];
                const key = jit_loop.valueFromSlotTagged(cl.reg_types[site.args_reg], tctx.tags[site.args_reg], tctx.slots[site.args_reg]);
                const val = jit_loop.valueFromSlotTagged(cl.reg_types[site.src_reg], tctx.tags[site.src_reg], tctx.slots[site.src_reg]);
                var names: [2]?[]const u8 = .{ null, null };
                const r = lc.host.callMemberNamed(lc.allocator, &m, "set", &.{ key, val }, names[0..2]) catch {
                    lc.pending = .{ .Type = "out of memory in JIT map store" };
                    return jit_loop.throwCode(site.block);
                };
                switch (r) {
                    .ok => return 0,
                    .err => |e| {
                        stashErr(lc, e, site.inst, null);
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            // Map load `map[key]` -> nullable scalar (value slot + flag slot).
            if (site.is_map_get) {
                if (comptime !@hasDecl(H, "callMemberNamed")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const m = lc.frame.regs.items[site.recv_reg];
                const key = jit_loop.valueFromSlotTagged(cl.reg_types[site.args_reg], tctx.tags[site.args_reg], tctx.slots[site.args_reg]);
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
                        stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
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
            if (site.is_exec) {
                if (execEscapeSite(tctx, lc, cl, site)) |code| return code;
                return 0;
            }
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
                        stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
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
                // A by-name site resolves the stored index on the live
                // receiver per call (a getter property or missing member
                // deopts — the read is pure, the interpreter re-runs it).
                // A fixed-index site's varying boxed receiver may be a
                // different class this iteration (or null after a `?.` chain
                // step); deopt unless it matches.
                if (recv != .Instance or (!site.field_named and site.recv_varies and jit_loop.instanceClassIdentity(recv) != site.recv_class)) {
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                const fidx: u32 = if (site.field_named) blk_fn: {
                    if (comptime !@hasDecl(H, "plainStoredFieldIndex")) {
                        lc.pending_deopt_inst = site.inst;
                        return jit_loop.deoptCode(site.block);
                    }
                    break :blk_fn lc.host.plainStoredFieldIndex(lc.allocator, &recv, site.name) orelse {
                        lc.pending_deopt_inst = site.inst;
                        return jit_loop.deoptCode(site.block);
                    };
                } else site.field_idx;
                const g = recv.Instance.borrow();
                const fv: ?Value = if (fidx < g.get().fields.items.len) g.get().fields.items[fidx].value else null;
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
                    if (cl.reg_types[site.dst_reg] == .i32) {
                        tctx.tags[site.dst_reg] = @intFromEnum(std.meta.activeTag(fv.?));
                    }
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
            var argbuf: [6]Value = undefined;
            var k: usize = 0;
            while (k < site.n_args) : (k += 1) {
                const ar = @as(usize, site.args_reg) + k;
                // The LIVE tag comes through the move chain's source: the
                // native code copies arg SLOTS without updating the tag
                // array (see CallSite.arg_tag_regs).
                const tr: usize = if (k < 3 and site.arg_tag_regs[k] != 0) site.arg_tag_regs[k] else ar;
                argbuf[k] = switch (cl.reg_types[ar]) {
                    .object => lc.frame.regs.items[ar],
                    .null_ => .Null,
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[ar], tctx.tags[tr], tctx.slots[ar]),
                };
            }
            // Native recursion: a compiled body calling a compiled (scalar)
            // callee runs its body directly — no interpreter frame, no dispatch.
            // The callee is pure (scalar in, scalar out), so a deopt/throw can
            // safely fall back to the frame-based path by re-running it below.
            if (!site.is_member and !site.is_virtual and !runtime.shouldAbandon()) {
                if (lc.module.funcById(site.func)) |callee| {
                    if (jit_loop.compiledFunc(callee)) |callee_cl| {
                        if (!callee_cl.no_native_recurse and
                            evtls.jit_native_depth < NATIVE_SLOT_BANK_DEPTH and callee_cl.n_slots <= 192)
                        {
                            // Per-depth rows from the thread's static bank: a
                            // stack `undefined` array here is 0xaa-filled per
                            // CALL under the safe build — it was 70% of a
                            // native fib's wall.
                            const fslots: []i64 = &native_slot_bank[evtls.jit_native_depth];
                            const ftags: []u8 = &native_tag_bank[evtls.jit_native_depth];
                            evtls.jit_native_depth += 1;
                            const fo = jit_loop.runFunc(callee_cl, &.{}, argbuf[0..site.n_args], fslots[0..callee_cl.n_slots], ftags[0..callee_cl.n_regs], &call, tctx.user);
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
            const res = if (site.is_virtual) virt: {
                if (comptime !@hasDecl(H, "invokeVirtualMember")) {
                    break :virt EvalResult{ .err = .{
                        .Type = "host cannot dispatch virtual calls",
                    } };
                }
                var recv = switch (cl.reg_types[site.recv_reg]) {
                    .object, .unknown => lc.frame.regs.items[site.recv_reg],
                    .null_ => Value.Null,
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[site.recv_reg], tctx.tags[site.recv_reg], tctx.slots[site.recv_reg]),
                };
                recv.retain();
                defer recv.release(lc.allocator);
                var names: [6]?[]const u8 = .{ null, null, null, null, null, null };
                break :virt lc.host.invokeVirtualMember(
                    lc.allocator,
                    &recv,
                    ir.MethodSlotId.from(site.virt_slot),
                    argbuf[0..site.n_args],
                    names[0..site.n_args],
                    null,
                    null,
                ) catch {
                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                    return jit_loop.throwCode(site.block);
                };
            } else if (site.is_member) member: {
                const recv_tag_src: usize = if (site.recv_tag_reg != 0) site.recv_tag_reg else site.recv_reg;
                var recv = switch (cl.reg_types[site.recv_reg]) {
                    .object, .unknown => lc.frame.regs.items[site.recv_reg],
                    .null_ => Value.Null,
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[site.recv_reg], tctx.tags[recv_tag_src], tctx.slots[site.recv_reg]),
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
                            else => jit_loop.valueFromSlotTagged(cl.reg_types[reg], tctx.tags[reg], tctx.slots[reg]),
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
                        &.{},
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
                var names: [6]?[]const u8 = .{ null, null, null, null, null, null };
                const r = (if (site.declared_name.len != 0)
                    lc.host.callMemberNamedDeclared(lc.allocator, &recv, site.name, argbuf[0..site.n_args], names[0..site.n_args], site.declared_name)
                else
                    lc.host.callMemberNamed(lc.allocator, &recv, site.name, argbuf[0..site.n_args], names[0..site.n_args])) catch {
                    if (pushed) popEnclosing();
                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                    return jit_loop.throwCode(site.block);
                };
                if (pushed) popEnclosing();
                if (r == .err and r.err == .Unimplemented and runtime.envOnce("KLIO_JIT_DEBUG") != null) {
                    std.debug.print("[jit-dbg] member miss: body={s} name={s} declared={s} recv_reg={d} n_params={d}\n", .{ lc.frame.func.fqn, site.name, site.declared_name, site.recv_reg, lc.frame.params.items.len });
                }
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
                                // The call ALREADY RAN — a deopt that re-runs
                                // the instruction would double its effects.
                                // Deliver the boxed result into the frame
                                // register (the rebox pass skips it) and
                                // resume interpretation AFTER the site.
                                v.retain();
                                lc.frame.write(Reg.from(site.dst_reg), v) catch {
                                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                                    return jit_loop.throwCode(site.block);
                                };
                                tctx.deopt_skip_reg = site.dst_reg;
                                lc.pending_deopt_inst = site.inst + 1;
                                return jit_loop.deoptCode(site.block);
                            };
                            tctx.slots[site.dst_reg] = s;
                            // The call's ACTUAL result kind governs how this
                            // register reboxes (an intrinsic `toChar` has no
                            // static return to read).
                            if (cl.reg_types[site.dst_reg] == .i32) {
                                tctx.tags[site.dst_reg] = @intFromEnum(std.meta.activeTag(v));
                            }
                        }
                    }
                    return 0;
                },
                .err => |e| {
                    stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
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

        /// Compile-time virtual-slot resolver: the FuncId the slot dispatches
        /// to on the receiver's class, so a loop-invariant virtual call can
        /// inline its monomorphic target. Null keeps the site a trampoline.
        fn resolveVirtual(user: *anyopaque, receiver: *const Value, slot: u32) ?FuncId {
            if (comptime !@hasDecl(H, "resolveVirtualFuncId")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.resolveVirtualFuncId(receiver, ir.MethodSlotId.from(slot));
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
    if (frame_count_on) frame_count_total += 1;
    // KLIO_FN_PROF: attribute samples to the interpreted function running
    // here, restoring the caller's on exit so the histogram is self-time.
    const fn_prof_prev = runtime.prof.current_fn;
    if (runtime.prof.fn_prof_active) runtime.prof.current_fn = frame.func.id.int();
    defer if (runtime.prof.fn_prof_active) {
        runtime.prof.current_fn = fn_prof_prev;
    };
    // Resolved once: the per-instruction gates below would otherwise pay a
    // dynamic thread-local lookup each, which the compiler cannot hoist past
    // the dispatch calls between them.
    //
    // Re-bound to the RUNNING thread first. A frame's `tls` is captured when
    // it is built, but a suspended coroutine resumes on whatever thread the
    // dispatcher hands it, and the state behind this pointer — the register
    // free-list, the receiver chain, the frame chain — is per-thread and
    // unsynchronized. A migrated frame that kept its origin thread's pointer
    // raced that thread's pool (an intermittent `integer overflow` from the
    // free list's length going negative under concurrent snapshot tests).
    //
    // A migrated frame's CHAIN activation also happened against the
    // constructing thread's context: its prev_chain points into that
    // thread's stack, and deactivating here would transplant the foreign
    // pointer into THIS thread's active chain — which then outlives the
    // frame it names, and the next fresh call on this thread merges its
    // enclosing chain from freed memory (the cross-thread yield GPF).
    // Re-home the activation: this frame's chain becomes the running
    // thread's active chain, and its deactivate restores the running
    // thread's own current chain.
    if (frame.tls != &evtls) {
        frame.tls = &evtls;
        frame.prev_chain = evtls.active_chain;
        frame.prev_chain_base = evtls.active_chain_base;
        evtls.active_chain = &frame.enclosing_this;
        evtls.active_chain_base = frame.enclosing_this.items.len;
    }
    const ftls: *EvalTls = frame.tls;
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
        if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
            std.debug.print("[empty-frame] fqn={s} params={d} caller={s}\n", .{
                func.fqn, func.params.len,
                if (currentFrameFunc()) |cf| cf.fqn else "<none>",
            });
            dumpFrameChainForDiagAlways();
        }
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
    const virt_resolver: ?jit_loop.VirtResolver =
        if (comptime tramp_ok and @hasDecl(H, "resolveVirtualFuncId")) &LoopTramp(H).resolveVirtual else null;
    // The bytecode tier's per-func stream table, hoisted to one lookup per
    // activation; per block entry it is a plain array index.
    // Fused terminator ops only when the loop JIT is off: the JIT's
    // compile trigger lives at this loop's block entry, and fused edges
    // would starve it.
    const bc_streams: ?*const bc.FuncStreams = if (bc.enabled()) bc.funcStreams(func, !jit_on, module.consts.items) else null;
    // The C transpiler's native table: a registered function's blocks run
    // as emitted C instead of the stream (one lookup per activation; the
    // table is empty in every non-transpiled process).
    const native_fn: ?NativeFn = if (nativeModuleOk(module)) nativeFor(func.id.int(), func.fqn) else null;
    if (native_fn == null and native_any.load(.acquire) and
        func.package.len == 0 and runtime.envOnce("KLIO_NATIVE_TRACE") != null)
    {
        std.debug.print("[native-miss] fn={s} fid={d}\n", .{ func.fqn, func.id.int() });
    }
    // The loop JIT's per-function state, hoisted to one lookup per
    // activation; the per-block-entry probe is then two array loads.
    const jit_fj: ?*jit_loop.FuncJit = if (jit_on) jit_loop.forFunc(func) else null;
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
        ftls.spin_check_counter +%= 1;
        if (ftls.spin_check_counter & 0xFFFF == 0) {
            spinDumpMaybe();
            const wall_dl = test_wall_deadline_ms.load(.monotonic);
            if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
                // A caught hang should say WHERE it looped, not just that it did.
                // Dump the live frame chain (innermost first, with file:line) so
                // the culprit function/recursion is named at the abort point.
                return try wallCapFire(allocator);
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
        if (jit_fj != null and resume_idx == 0 and resume_throw == null and resume_unwind == null) {
            // Compiled code reads and writes the raw register slice with no
            // mask maintenance; hand it a fully-defined file. One fill per
            // frame at most — the mask saturates.
            frame.materializeRegs();
            if (jit_loop.maybeRunHotPre(jit_fj.?, frame.module, func, &frame.regs, allocator, cur, tramp_fn, tramp_user, member_resolver, virt_resolver, field_resolver, field_nn_resolver)) |res| {
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
                            // A trampolined callee SUSPENDED mid-loop: park
                            // this frame at the call site exactly as the
                            // interpreted path would — the native exit has
                            // already reboxed the loop registers, so the
                            // snapshot resumes the loop right after the
                            // call with the resume value in its dst.
                            // Propagating it as a plain error dropped the
                            // loop frame from the continuation (a JITted
                            // `for` sending into a channel lost every
                            // element after the tier-up).
                            .Suspended => {
                                park_out.* = .{
                                    .block = res.block,
                                    .inst_idx = @as(usize, loop_ctx.pending_suspend_inst) + 1,
                                    .resume_reg = loop_ctx.pending_suspend_dst,
                                };
                                return errResult(e);
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
                // FRESH entry only: a deopt/throw resume (or a loop whose
                // back-edge targets the entry block) arrives here with
                // resume state set, and re-running the whole body from
                // scratch would double its effects and drop the pending
                // throw.
                if (cur.int() == func.entry.int() and resume_idx == 0 and
                    resume_throw == null and resume_unwind == null)
                {
                    if (jit_loop.maybeRunHotFunc(frame.module, func, &frame.regs, frame.params.items, frame.captures.items, allocator, tramp_fn, tramp_user, member_resolver, virt_resolver, field_resolver, field_nn_resolver)) |fo| {
                        if (fo.code.inst == jit_loop.RETURN_INST) {
                            return ok(fo.value);
                        }
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
                        // Deopt: a handler-issued one carries the sentinel and
                        // records the resume instruction on the context; a
                        // native one (div by zero) encodes it directly.
                        cur = fo.code.block;
                        resume_idx = if (fo.code.inst == jit_loop.DEOPT_INST) loop_ctx.pending_deopt_inst else fo.code.inst;
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
        if (resume_idx == 0 and (has_catches or finally != null or block.lr_absorb != null)) {
            try try_stack.append(allocator, .{
                .body = cur,
                .chain_len = frame.enclosing_this.items.len,
                .catches = block.catches,
                .finally_entry = finally,
                .finally_done = finally_done,
                .lr_absorb = block.lr_absorb,
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
        var ret_v: EvalResult = ok(.Unit);
        var ran_bc = false;
        // Fused-flow exits back to the frame loop: run this block from its
        // top / run only this block's terminator.
        var bc_goto: ?BlockId = null;
        var bc_term: ?BlockId = null;
        // The bytecode tier: the dense per-block stream replaces this
        // instruction loop's union dispatch; every non-simple op escapes
        // to `execInst`, and all control flow funnels through the same
        // `afterStep` the walker uses. In a FUSED function (no try
        // machinery, JIT off) the streams carry jump/br/ret terminator
        // ops, so straight-line control flow never surfaces to the frame
        // loop's per-block bookkeeping; each taken edge runs the same
        // abandon/spin/GC guards the frame loop runs per block entry.
        // A registered native function runs its emitted C for this block
        // (and, fused, every block it flows into) with the exact exits the
        // stream loop has. Fresh block entries only: a resume mid-block
        // (start_idx != 0) or one carrying a throw/unwind goes through the
        // stream's idx_pc machinery — the coordinates are shared, so a
        // parked transpiled function resumes exactly like an interpreted
        // one.
        var native_ran = false;
        if (native_fn) |nf| native_run: {
            if (thrown != null or unwound != null) break :native_run;
            if (start_idx != 0) break :native_run;
            if (frame.regs.items.len < func.n_locals) break :native_run;
            // The emitted C's hot view reads and writes raw register bytes
            // with no mask maintenance; hand it a fully-defined file.
            frame.materializeRegs();
            // Every native level stacks kf + glue + serve frames for ANY
            // call form (member escapes included, not just the quickened
            // static op), far heavier than an interpreter frame — past
            // this depth a deep chain runs the stream instead, so the C
            // stack stays bounded and the eval-depth cap keeps raising
            // its catchable StackOverflow first.
            if (evtls.eval_depth > NATIVE_RECURSE_MAX_DEPTH) break :native_run;
            var nctx: NativeCtx = .{
                .frame = frame,
                .allocator = allocator,
                .ftls = ftls,
                .host = @ptrCast(host),
                .flat_out = flat_out,
                .park_out = park_out,
                .thrown = &thrown,
                .unwound = &unwound,
                .ret_v = &ret_v,
                .arm_bin = &NativeGlue(H).armBin,
                .escape = &NativeGlue(H).escape,
                .call = &NativeGlue(H).call,
                .field_route = &NativeGlue(H).fieldRoute,
                .field_write_route = &NativeGlue(H).fieldWriteRoute,
            };
            nf(@ptrCast(&nctx), cur.int());
            if (runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
                std.debug.print("[native] fn={s} entry=b{d} outcome={s}\n", .{
                    func.fqn, cur.int(), @tagName(nctx.outcome),
                });
            }
            switch (nctx.outcome) {
                .none => break :native_run,
                .term => bc_term = @enumFromInt(nctx.out_block),
                .goto => bc_goto = @enumFromInt(nctx.out_block),
                .brk => cur = @enumFromInt(nctx.out_block),
                .ret => return ret_v,
                .oom => return error.OutOfMemory,
            }
            ran_bc = true;
            native_ran = true;
        }
        if (!native_ran and bc_streams != null) bc_run: {
            const bs = bc_streams.?;
            // A resume that arrived carrying a throw/unwind skips the
            // instruction surface entirely — for an EMPTY block its
            // `start_idx = insts.len` is 0, indistinguishable from a
            // fresh entry, and a fused terminator op must not run
            // before the routing below.
            if (thrown != null or unwound != null) break :bc_run;
            // The one bounds check the stream ops rely on: build-time
            // validation proved every operand `< n_locals`.
            if (frame.regs.items.len < func.n_locals) break :bc_run;
            var bcur = cur;
            var binsts = insts;
            const stream0 = bs.streams[bcur.int()] orelse break :bc_run;
            ran_bc = true;
            var code = stream0.code;
            var pc: usize = if (start_idx == 0)
                0
            else if (start_idx >= binsts.len)
                code.len
            else
                stream0.idx_pc[start_idx];
            bc_loop: while (pc < code.len) {
                const op: bc.Op = @enumFromInt(code[pc]);
                switch (op) {
                    .const_load => {
                        const v = try constToValue(allocator, &frame.module.consts.items[code[pc + 2]]);
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .const_int => {
                        const v: Value = .{ .Int = @bitCast(code[pc + 2]) };
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .move => {
                        const v = frame.regs.items.ptr[code[pc + 2]];
                        v.retain();
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .load_param => {
                        const pidx: usize = code[pc + 2];
                        const v = if (pidx < frame.params.items.len) frame.params.items[pidx] else Value.Unit;
                        v.retain();
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .cell_get => {
                        const v = switch (frame.regs.items.ptr[code[pc + 2]]) {
                            .Cell => |c| vblk: {
                                const g = c.borrow();
                                defer g.deinit();
                                break :vblk g.get().*;
                            },
                            else => |other| other,
                        };
                        v.retain();
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .trace => {
                        frame.cur_span = .{
                            .file = @enumFromInt(code[pc + 1]),
                            .start = code[pc + 2],
                            .end = code[pc + 3],
                        };
                        pc += 4;
                    },
                    .bin => {
                        // Same-tag scalar operands take an inline path with
                        // the exact `applyBinop` semantics (wrap arithmetic,
                        // truncated div/rem, numeric compare); anything else
                        // — including a zero divisor, whose exception the
                        // generic arm constructs — falls through. The
                        // operands ride in the stream, so the fast path
                        // never loads the Inst union.
                        if (binFast(
                            frame,
                            @enumFromInt(code[pc + 2]),
                            @enumFromInt(code[pc + 3]),
                            @enumFromInt(code[pc + 4]),
                            @enumFromInt(code[pc + 5]),
                            allocator,
                        )) {
                            pc += 6;
                            continue :bc_loop;
                        }
                        idx = code[pc + 1];
                        const inst = &binsts[idx];
                        const r = try execArmBinOp(H, allocator, frame, inst.BinOp, host);
                        switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                            .cont => pc += 6,
                            .brk => break :bc_loop,
                            .ret => return ret_v,
                        }
                    },
                    .escape => {
                        idx = code[pc + 1];
                        const inst = &binsts[idx];
                        const r = try execInst(H, allocator, frame, inst, host);
                        switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                            .cont => pc += 2,
                            .brk => break :bc_loop,
                            .ret => return ret_v,
                        }
                    },
                    .jump, .br => {
                        var target: u32 = undefined;
                        if (op == .jump) {
                            target = code[pc + 1];
                        } else {
                            const cv = frame.regs.items.ptr[code[pc + 1]];
                            if (cv != .Bool) {
                                // Cell-carried or coercing condition: the
                                // frame loop's Branch runs `valueTruthy`.
                                bc_term = bcur;
                                break :bc_loop;
                            }
                            target = if (cv.Bool) code[pc + 2] else code[pc + 3];
                        }
                        if (fusedEdgeGuard(allocator, ftls)) |er| {
                            cur = bcur;
                            return er;
                        }
                        const nb: BlockId = @enumFromInt(target);
                        if (bs.streams[nb.int()]) |ns| {
                            bcur = nb;
                            binsts = frame.func.blocks[nb.int()].insts;
                            code = ns.code;
                            pc = 0;
                        } else {
                            bc_goto = nb;
                            break :bc_loop;
                        }
                    },
                    .cmp_br => {
                        // The block's last BinOp fused with its Branch: the
                        // scalar compare computes inline, still writes dst
                        // (register state matches the unfused form), and
                        // branches without another fetch. Non-scalar
                        // operands run the generic arm, then branch on dst.
                        var taken: ?bool = null;
                        {
                            const regs = frame.regs.items.ptr;
                            const di = code[pc + 3];
                            if (scalarBin(@enumFromInt(code[pc + 2]), regs[code[pc + 4]], regs[code[pc + 5]])) |out| {
                                if (out == .Bool) {
                                    const old = regs[di];
                                    regs[di] = out;
                                    frame.wmask.set(di);
                                    if (runtime.reclaimEnabled()) old.release(allocator);
                                    taken = out.Bool;
                                }
                            }
                        }
                        if (taken == null) {
                            idx = code[pc + 1];
                            const inst = &binsts[idx];
                            const r = try execArmBinOp(H, allocator, frame, inst.BinOp, host);
                            switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                .cont => {},
                                .brk => break :bc_loop,
                                .ret => return ret_v,
                            }
                            const cv = frame.read(@enumFromInt(code[pc + 3]));
                            if (cv != .Bool) {
                                bc_term = bcur;
                                break :bc_loop;
                            }
                            taken = cv.Bool;
                        }
                        if (fusedEdgeGuard(allocator, ftls)) |er| {
                            cur = bcur;
                            return er;
                        }
                        const nb: BlockId = @enumFromInt(if (taken.?) code[pc + 6] else code[pc + 7]);
                        if (bs.streams[nb.int()]) |ns| {
                            bcur = nb;
                            binsts = frame.func.blocks[nb.int()].insts;
                            code = ns.code;
                            pc = 0;
                        } else {
                            bc_goto = nb;
                            break :bc_loop;
                        }
                    },
                    .ret => {
                        const v: Value = if (code[pc + 1] != 0)
                            frame.regs.items.ptr[code[pc + 2]]
                        else
                            .Unit;
                        v.retain();
                        return ok(v);
                    },
                    .term_exit => {
                        bc_term = bcur;
                        break :bc_loop;
                    },
                }
            }
            // Fused flow may have advanced blocks; the walker fallback and
            // the mid-block throw/unwind routing below key on `cur`.
            cur = bcur;
        }
        if (bc_goto) |nb| {
            cur = nb;
            continue;
        }
        if (bc_term) |nb| {
            // Re-enter the frame loop to run ONLY this block's real
            // terminator: the sentinel skips the instruction loop and the
            // stream (including its fused terminator ops — an empty block
            // entered at index 0 would otherwise replay them).
            cur = nb;
            resume_idx = std.math.maxInt(usize);
            continue;
        }
        if (!ran_bc) {
            while (idx < insts.len) : (idx += 1) {
                if (idx < start_idx) continue;
                const inst = &insts[idx];
                const r = try execInst(H, allocator, frame, inst, host);
                switch (try afterStep(allocator, frame, r, inst, idx, cur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                    .cont => {},
                    .brk => break,
                    .ret => return ret_v,
                }
            }
        }
        if (unwound) |e| {
            // Mid-block non-local return -- route through the armed finally
            // blocks only (never a catch), then keep unwinding. A splice
            // region's labeled-return absorption catches a `LabeledReturn`
            // whose label it owns: control resumes at the region's join with
            // the value delivered, exactly the exit the label meant.
            frame.pending_finally.release(allocator);
            var routed = false;
            while (try_stack.pop()) |tf| {
                if (e == .LabeledReturn) if (tf.lr_absorb) |ab| {
                    if (std.mem.eql(u8, ab.label, e.LabeledReturn.label)) {
                        try frame.write(ab.value_reg, e.LabeledReturn.value);
                        cur = ab.handler;
                        routed = true;
                        break;
                    }
                };
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
                    truncChainTo(frame, tf.chain_len);
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
                    truncChainTo(frame, tf.chain_len);
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
                        truncChainTo(frame, tf.chain_len);
                    try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin2| {
                        const key = tf.finally_done orelse fin2;
                        truncChainTo(frame, tf.chain_len);
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
                    if (e == .LabeledReturn) if (tf.lr_absorb) |ab| {
                        if (std.mem.eql(u8, ab.label, e.LabeledReturn.label)) {
                            try frame.write(ab.value_reg, e.LabeledReturn.value);
                            cur = ab.handler;
                            routed = true;
                            break;
                        }
                    };
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
                // Innermost-first: a splice region's absorption for this
                // label ends the unwind at its join; armed finallys inside
                // it still run first (they sit deeper on the stack).
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (tf.lr_absorb) |ab| {
                        if (std.mem.eql(u8, ab.label, lr.label)) {
                            try frame.write(ab.value_reg, v);
                            cur = ab.handler;
                            routed = true;
                            break;
                        }
                        continue;
                    }
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
                        truncChainTo(frame, tf.chain_len);
                    try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin| {
                        frame.pending_finally.release(allocator);
                        const key = tf.finally_done orelse fin;
                        truncChainTo(frame, tf.chain_len);
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
                if (!runtime.reclaimEnabled() and frame.func.frameNoFill()) {
                    frame.regs.items.len = n;
                    frame.wmask = RegMask.none;
                } else {
                    try frame.regs.appendNTimes(regsAlloc(allocator), .Unit, n);
                    frame.wmask.setAll();
                }
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
                if (!runtime.reclaimEnabled() and new_func.frameNoFill()) {
                    try frame.regs.ensureTotalCapacity(regsAlloc(allocator), new_func.n_locals);
                    frame.regs.items.len = new_func.n_locals;
                    frame.wmask = RegMask.none;
                } else {
                    try frame.regs.appendNTimes(regsAlloc(allocator), .Unit, new_func.n_locals);
                    frame.wmask.setAll();
                }
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
                if (cmgTraceWant()) |w| if (std.mem.eql(u8, w, frame.func.name)) {
                    std.debug.print("[switch] {s} v={s}", .{ frame.func.name, @tagName(std.meta.activeTag(v)) });
                    if (v == .Int) std.debug.print(":{d}", .{v.Int});
                    std.debug.print(" -> b{d} (default b{d}, {d} arms)\n", .{ next.int(), sw.default.int(), sw.arms.len });
                };
                cur = next;
            },
        }
    }
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
/// The shared post-step control-flow handling for both instruction loops
/// (the tree walker's and the bytecode tier's): flat-call handoff, throw /
/// non-local-return capture, suspension parking. `.brk` breaks to the
/// block's unwind handling with `thrown`/`unwound` set; `.ret` returns
/// `ret.*` from the frame.
const AfterStep = enum { cont, brk, ret };

fn afterStep(
    allocator: Allocator,
    frame: *Frame,
    r: Step,
    inst: *const Inst,
    idx: usize,
    cur: BlockId,
    flat_out: *?FlatCallSite,
    park_out: *?ParkPoint,
    thrown: *?Value,
    unwound: *?EvalError,
    ret: *EvalResult,
) Allocator.Error!AfterStep {
    if (r == .flat_call) {
        const req = frame.flat_call.?;
        frame.flat_call = null;
        flat_out.* = .{ .req = req, .ret_block = cur, .ret_idx = idx + 1 };
        ret.* = ok(.Unit);
        return .ret;
    }
    if (r == .raised) {
        const e = frame.step_err.?;
        frame.step_err = null;
        switch (e) {
            .Throw => |v| {
                var tv = v;
                try attachStackTrace(allocator, &tv);
                thrown.* = tv;
                return .brk;
            },
            .NonLocalReturn, .LabeledReturn => {
                unwound.* = e;
                return .brk;
            },
            .CalleeFailed, .StackOverflow => {
                unwound.* = e;
                return .brk;
            },
            .Suspended => |state| {
                const resume_reg = if (state.pending_resume_reg) |rr| blk: {
                    state.pending_resume_reg = null;
                    break :blk rr;
                } else instDst(inst);
                park_out.* = .{ .block = cur, .inst_idx = idx + 1, .resume_reg = resume_reg };
                ret.* = errResult(.{ .Suspended = state });
                return .ret;
            },
            else => {
                ret.* = errResult(e);
                return .ret;
            },
        }
    }
    return .cont;
}

/// The bytecode tier's inline BinOp path: same-tag Int/Long scalar
/// arithmetic and comparison (and Bool And/Or) with results written
/// straight into the register file. Semantics mirror `applyBinop`'s
/// same-tag cases exactly — wrap arithmetic, `divTruncI32/64` /
/// `remTruncI32/64`, numeric equality — and every other shape
/// (mixed tags, zero divisors, Cells, user operators) returns false
/// so the generic arm runs.
inline fn binFast(frame: *Frame, op: BinOp, dst: Reg, lhs: Reg, rhs: Reg, allocator: Allocator) bool {
    // Register indices are PROVEN in bounds: validated `< n_locals` at
    // stream build, and the bytecode section checked
    // `regs.len >= n_locals` once at entry.
    const regs = frame.regs.items.ptr;
    const lv = regs[lhs.int()];
    const rv = regs[rhs.int()];
    const out: Value = scalarBin(op, lv, rv) orelse return false;
    const old = regs[dst.int()];
    regs[dst.int()] = out;
    frame.wmask.set(dst.int());
    if (runtime.reclaimEnabled()) old.release(allocator);
    return true;
}

/// The shared same-tag scalar BinOp core: Int/Int, Long/Long, Bool/Bool
/// and mixed Int/Long pairs with `applyBinop`'s exact semantics. Null
/// for every shape the generic arm must handle (mixed non-integer tags,
/// zero divisors, boxed equality on mixed widths, Cells, ===).
inline fn scalarBin(op: BinOp, lv: Value, rv: Value) ?Value {
    return if (lv == .Int and rv == .Int) blk: {
        const a = lv.Int;
        const b = rv.Int;
        break :blk switch (op) {
            .Add => .{ .Int = a +% b },
            .Sub => .{ .Int = a -% b },
            .Mul => .{ .Int = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Int = divTruncI32(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Int = remTruncI32(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq, .BoxedEq => .{ .Bool = a == b },
            .NotEq, .BoxedNotEq => .{ .Bool = a != b },
            .And => .{ .Int = a & b },
            .Or => .{ .Int = a | b },
            .Xor => .{ .Int = a ^ b },
            .Shl => .{ .Int = @as(i32, @bitCast(@as(u32, @bitCast(a)) << @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)))) },
            .Shr => .{ .Int = a >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)) },
            .UShr => .{ .Int = @as(i32, @bitCast(@as(u32, @bitCast(a)) >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)))) },
            else => break :blk null,
        };
    } else if (lv == .Long and rv == .Long) blk: {
        const a = lv.Long;
        const b = rv.Long;
        break :blk switch (op) {
            .Add => .{ .Long = a +% b },
            .Sub => .{ .Long = a -% b },
            .Mul => .{ .Long = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Long = divTruncI64(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Long = remTruncI64(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq, .BoxedEq => .{ .Bool = a == b },
            .NotEq, .BoxedNotEq => .{ .Bool = a != b },
            .And => .{ .Long = a & b },
            .Or => .{ .Long = a | b },
            .Xor => .{ .Long = a ^ b },
            else => break :blk null,
        };
    } else if (lv == .Bool and rv == .Bool) blk: {
        break :blk switch (op) {
            .And => .{ .Bool = lv.Bool and rv.Bool },
            .Or => .{ .Bool = lv.Bool or rv.Bool },
            .Xor => .{ .Bool = lv.Bool != rv.Bool },
            .Eq, .BoxedEq => .{ .Bool = lv.Bool == rv.Bool },
            .NotEq, .BoxedNotEq => .{ .Bool = lv.Bool != rv.Bool },
            else => break :blk null,
        };
    } else if ((lv == .Double and rv == .Float) or (lv == .Float and rv == .Double)) blk: {
        // A Double against a Float (a smart cast to each in one condition)
        // compares as Double under IEEE: `0.0 != -0.0F` is false. Boxed
        // equality stays tag-sensitive and falls through.
        const a: f64 = if (lv == .Double) lv.Double else @floatCast(lv.Float);
        const b: f64 = if (rv == .Double) rv.Double else @floatCast(rv.Float);
        break :blk switch (op) {
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq => .{ .Bool = a == b },
            .NotEq => .{ .Bool = a != b },
            else => break :blk null,
        };
    } else if ((lv == .Int or lv == .Long) and (rv == .Int or rv == .Long)) blk: {
        // Mixed widths promote to Long, as `applyBinop` does. Boxed
        // equality stays tag-sensitive (`(1 as Any) != (1L as Any)`)
        // and falls through.
        const a: i64 = if (lv == .Int) lv.Int else lv.Long;
        const b: i64 = if (rv == .Int) rv.Int else rv.Long;
        break :blk switch (op) {
            .Add => .{ .Long = a +% b },
            .Sub => .{ .Long = a -% b },
            .Mul => .{ .Long = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Long = divTruncI64(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Long = remTruncI64(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq => .{ .Bool = a == b },
            .NotEq => .{ .Bool = a != b },
            // The logical trio only lowers to a BinOp when the STATIC
            // types agree, but a literal's runtime tag can be narrower
            // than its declared Long; compute wide, return Long as the
            // declared type promised.
            .And => .{ .Long = a & b },
            .Or => .{ .Long = a | b },
            .Xor => .{ .Long = a ^ b },
            // Long shifts take an Int count (`Long.shl(bitCount: Int)`);
            // the count uses its low 6 bits, JVM-style.
            .Shl => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) << @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            .Shr => if (lv == .Long) .{ .Long = a >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)) } else break :blk null,
            .UShr => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            else => break :blk null,
        };
    } else null;
}

/// The frame loop's per-block-entry guards, run on every taken FUSED
/// edge: daemon abandonment, the spin/wall diagnostic, and the GC safe
/// point. Non-null = abort the frame with this result.
inline fn fusedEdgeGuard(allocator: Allocator, ftls: *EvalTls) ?EvalResult {
    if (runtime.shouldAbandon()) {
        return errResult(.{ .Type = "daemon task abandoned at run boundary" });
    }
    ftls.spin_check_counter +%= 1;
    if (ftls.spin_check_counter & 0xFFFF == 0) {
        spinDumpMaybe();
        const wall_dl = test_wall_deadline_ms.load(.monotonic);
        if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
            return wallCapFire(allocator) catch
                errResult(.{ .Type = "test wall-clock deadline exceeded" });
        }
    }
    if (runtime.gc.gc_enabled and runtime.gc.pending()) {
        runtime.gc.safePoint();
    }
    return null;
}

/// Unchecked register store for the bytecode loop's simple ops: the
/// index was validated `< n_locals` at stream build and the section
/// checked `regs.len >= n_locals` once at entry. Takes ownership of `v`.
inline fn writeFastU(frame: *Frame, r: Reg, v: Value, allocator: Allocator) void {
    const idx = r.int();
    const old = frame.regs.items.ptr[idx];
    frame.regs.items.ptr[idx] = v;
    frame.wmask.set(idx);
    if (runtime.reclaimEnabled()) old.release(allocator);
}

/// The C transpiler's native-function surface (plans/c-transpiler-plan.md
/// stage 2). A transpiled program registers per-fid C functions before the
/// run starts; the frame loop then executes a registered function's blocks
/// through the emitted C instead of the bytecode stream. The C code never
/// touches interpreter state: every op is a call back into one of the
/// `nativeOp*` helpers below (exported behind a C ABI by klio_rt), which
/// are the stream loop's own arm bodies over a `NativeCtx` that carries
/// the frame-loop locals for one activation.
pub const NativeFn = *const fn (ctx: ?*anyopaque, entry_block: u32) callconv(.c) void;

var native_mutex: runtime.SpinMutex = .{};
const NativeEntry = struct { f: NativeFn, fqn: []const u8 };
var native_table: std.AutoHashMapUnmanaged(u32, NativeEntry) = .empty;
var native_any: std.atomic.Value(bool) = .init(false);

/// Registration happens from the transpiled binary's `main` before the
/// program runs; the table is read-only afterwards. `fqn` is the emitted
/// function's fully qualified name: fids are only stable when the running
/// binary lowers the same program to the same module shape the emitter
/// walked, so the lookup refuses an entry whose name does not match —
/// a mismatched table silently falls back to full interpretation rather
/// than ever running the wrong body.
pub fn registerNative(fid: u32, f: NativeFn, fqn: []const u8) void {
    native_mutex.lock();
    defer native_mutex.unlock();
    const owned = std.heap.smp_allocator.dupe(u8, fqn) catch return;
    native_table.put(std.heap.smp_allocator, fid, .{ .f = f, .fqn = owned }) catch return;
    native_any.store(true, .release);
}

fn nativeFor(fid: u32, fqn: []const u8) ?NativeFn {
    if (!native_any.load(.acquire)) return null;
    native_mutex.lock();
    defer native_mutex.unlock();
    const e = native_table.get(fid) orelse return null;
    if (!std.mem.eql(u8, e.fqn, fqn)) {
        if (runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
            std.debug.print("[native-fqn] fid={d} table={s} frame={s}\n", .{ fid, e.fqn, fqn });
        }
        return null;
    }
    return e.f;
}

/// Scalar-replay leaf body (`kl_<fid>`): the whole function computed over
/// (int64 value, genre) pairs — genres 0 Int, 1 Long, 2 Bool, 3 Unit,
/// 4 Char. Returns nonzero with the result in (ret, retg); zero = the
/// body bailed (non-scalar input, div guard, depth or edge trigger) and
/// the caller re-runs the call through the ordinary path — sound because
/// only statically PURE bodies are ever registered here.
pub const NativeLeafFn = *const fn (
    ctx: ?*anyopaque,
    ev: *NativeEdgeView,
    argv: [*]const i64,
    argg: [*]const i32,
    ret: *i64,
    retg: *i32,
    depth: u32,
    aux: [*]i64,
    auxg: [*]i32,
) callconv(.c) i32;

/// A leaf's ctor-tail return (`*retg == leaf_ctor_tail_genre`): the body
/// could not construct its result natively, so it hands back the site
/// (`*ret` = block<<16 | inst index into the leaf FUNCTION's own IR) and
/// the ctor's scalar arguments in `aux`/`auxg`. The gate constructs ONCE
/// through the host with the inst's own names/static-heads — exact
/// semantics including a throwing constructor, no re-run. A callee that
/// may ctor-tail is only ever called in tail position (eligibility rule),
/// so one shared aux buffer serves the whole native call chain.
pub const leaf_ctor_tail_genre: i32 = 200;

/// Zig mirror of the emitted C `klio_ctor_site` (see klio_rt.h).
pub const CtorSite = extern struct {
    fqn: [*:0]const u8,
    block: u32,
    inst: u32,
    memo: u64,
};

/// Threadlocal interp edge view for `tryLeafValues` (see the cache
/// comment there); rebuilt only when the serving host changes.
threadlocal var leaf_ev_cache: NativeEdgeView = undefined;
threadlocal var leaf_ev_host: ?*anyopaque = null;
threadlocal var leaf_ev_counter: u64 = 0;

const NativeLeafEntry = struct { f: NativeLeafFn, fqn: []const u8 };
var native_leaf_table: std.AutoHashMapUnmanaged(u32, NativeLeafEntry) = .empty;
/// FQN-keyed leaves (a loaded leaf LIBRARY: bakes are not cross-process
/// fid-stable, so a prebuilt library can only name bodies by fqn).
var native_leaf_by_fqn: std.StringHashMapUnmanaged(NativeLeafFn) = .empty;
var native_leaf_any: std.atomic.Value(bool) = .init(false);

/// One character per declared param type, appended to a leaf's fqn so
/// OVERLOADS (which share the fqn) can never serve each other's calls.
/// Computed from the same Func data on both the emitting and the
/// serving side, so the spellings agree by construction.
pub fn leafSigChar(ty: []const u8) u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, ty, '.')) |d| ty[d + 1 ..] else ty;
    const eq = std.mem.eql;
    if (eq(u8, base, "Int")) return 'i';
    if (eq(u8, base, "Long")) return 'l';
    if (eq(u8, base, "Boolean")) return 'b';
    if (eq(u8, base, "Char")) return 'c';
    if (eq(u8, base, "Double")) return 'd';
    if (eq(u8, base, "Float")) return 'f';
    if (eq(u8, base, "Short")) return 's';
    if (eq(u8, base, "Byte")) return 'y';
    return 'o';
}

/// `fqn#<sig>` — the collision-proof registration key for `f`. A
/// non-scalar param contributes its declared type HEAD, not just 'o':
/// `Map.iterator`, `MutableMap.iterator`, and the identity
/// `Iterator<T>.iterator() = this` all share
/// `kotlin.collections.iterator` and an object receiver, and the
/// single-char sig let the LAST registration win — the identity body
/// served Map callers and returned the receiver map.
pub fn leafKeyAlloc(gpa2: std.mem.Allocator, f: *const Func) ?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(gpa2, f.fqn) catch return null;
    buf.append(gpa2, '#') catch return null;
    for (f.params) |*p| {
        const c = leafSigChar(p.ty.name);
        if (c != 'o') {
            buf.append(gpa2, c) catch return null;
            continue;
        }
        const nm = p.ty.name;
        const head = if (std.mem.lastIndexOfScalar(u8, nm, '.')) |d| nm[d + 1 ..] else nm;
        if (head.len == 0) {
            buf.append(gpa2, 'o') catch return null;
        } else {
            buf.append(gpa2, '{') catch return null;
            buf.appendSlice(gpa2, head) catch return null;
            buf.append(gpa2, '}') catch return null;
        }
    }
    return buf.toOwnedSlice(gpa2) catch null;
}

test "leafKeyAlloc separates object-receiver overloads by type head" {
    const gpa2 = std.testing.allocator;
    const mk = struct {
        fn key(al: std.mem.Allocator, ty_name: []const u8) ![]u8 {
            var params = [_]ir.Param{.{
                .name = "this",
                .ty = .{ .name = ty_name, .nullable = false, .args = &.{} },
                .default = null,
                .is_property = false,
                .is_vararg = false,
                .has_default = false,
            }};
            var f = std.mem.zeroInit(Func, .{
                .fqn = "kotlin.collections.iterator",
                .name = "iterator",
                .params = params[0..],
            });
            return leafKeyAlloc(al, &f) orelse error.OutOfMemory;
        }
    };
    const a2 = try mk.key(gpa2, "Map");
    defer gpa2.free(a2);
    const b2 = try mk.key(gpa2, "Iterator");
    defer gpa2.free(b2);
    try std.testing.expect(!std.mem.eql(u8, a2, b2));
    try std.testing.expectEqualStrings("kotlin.collections.iterator#{Map}", a2);
}

/// Register a leaf by FQN alone (leaf-library loading).
pub fn registerNativeLeafFqn(fqn: []const u8, f: NativeLeafFn) void {
    native_mutex.lock();
    defer native_mutex.unlock();
    const owned = std.heap.smp_allocator.dupe(u8, fqn) catch return;
    native_leaf_by_fqn.put(std.heap.smp_allocator, owned, f) catch return;
    native_leaf_any.store(true, .release);
}

pub fn registerNativeLeaf(fid: u32, f: NativeLeafFn, fqn: []const u8) void {
    native_mutex.lock();
    defer native_mutex.unlock();
    const owned = std.heap.smp_allocator.dupe(u8, fqn) catch return;
    native_leaf_table.put(std.heap.smp_allocator, fid, .{ .f = f, .fqn = owned }) catch return;
    native_leaf_any.store(true, .release);
}

/// The scalar-replay leaf gate, shared by the transpiled program's
/// native glue and the interpreter's call arm. Marshals scalar args,
/// runs the registered `kl_` body, and unmarshals the result — a
/// genre-200 ctor-tail constructs ONCE through the host with the site
/// inst's own names/static-heads (exact, throw included). Returns null
/// when the call is not leaf-served (no registration, non-scalar args,
/// or the leaf bailed) — the caller falls through to the ordinary
/// paths, which re-run the pure body exactly.
var leaf_diag_serve = std.atomic.Value(u64).init(0);
var leaf_diag_bail = std.atomic.Value(u64).init(0);
var leaf_diag_try = std.atomic.Value(u64).init(0);
var leaf_diag_nokey = std.atomic.Value(u64).init(0);
pub fn leafDiagDump() void {
    if (runtime.envOnce("KLIO_LEAF_DIAG") == null) return;
    std.debug.print("[leaf-diag] served={d} bailed={d} tried={d} nokey={d}\n", .{ leaf_diag_serve.load(.monotonic), leaf_diag_bail.load(.monotonic), leaf_diag_try.load(.monotonic), leaf_diag_nokey.load(.monotonic) });
}

pub const LeafOutcome = union(enum) { val: Value, raise: EvalError };

/// Value-level scalar-replay leaf gate shared by the framed call arm,
/// the fused driver, and the transpiled program's native glue. Null =
/// not leaf-served (no registration, non-scalar args, or a pure bail);
/// the caller falls through to its ordinary path, which re-runs the
/// pure body exactly. A genre-200 ctor-tail constructs ONCE through
/// the host with the site inst's own names/static-heads — a throwing
/// constructor comes back as `.raise`, exact, never re-run.
pub fn tryLeafValues(comptime H: type, allocator: Allocator, module: *const Module, cf: *const Func, args: []const Value, host: *H, nctx: ?*NativeCtx) Allocator.Error!?LeafOutcome {
    if (!native_leaf_any.load(.acquire)) return null;
    if (args.len > 8 or args.len != cf.params.len) return null;

    // Per-Func route memo: the registry lookup (mutex + hash + fqn
    // compare) priced every call by ~20% on a call-dense benchmark;
    // the table is write-once, so one resolution is final.
    _ = leaf_diag_try.fetchAdd(1, .monotonic);
    const route = cf.leaf_route.load(.acquire);
    const klf: NativeLeafFn = switch (route) {
        0 => blk_r: {
            // A symbol the link step settled onto a native binding (or a
            // sibling redirect) never runs its lowered body — the leaf
            // compiled that body, so serving it would bypass the host
            // intrinsic (the clock stub __klio_time_systemMillis
            // leaf-served 0). Checked once; the memo pins the verdict.
            const runs_body = if (comptime @hasDecl(H, "funcRunsItsBody"))
                host.funcRunsItsBody(cf.id)
            else
                true;
            const f0: ?NativeLeafFn = if (!runs_body)
                null
            else
                nativeLeafFor(cf.id.int(), cf.fqn) orelse nativeLeafForFunc(cf);
            if (f0 == null) _ = leaf_diag_nokey.fetchAdd(1, .monotonic);
            const enc: usize = if (f0) |fp| @intFromPtr(fp) else 1;
            @constCast(cf).leaf_route.store(enc, .release);
            break :blk_r f0 orelse return null;
        },
        1 => return null,
        else => @ptrFromInt(route),
    };
    var argv: [8]i64 = undefined;
    var argg: [8]i32 = undefined;
    for (args, 0..) |a, i| {
        switch (a) {
            .Int => |v| {
                argv[i] = v;
                argg[i] = 0;
            },
            .Long => |v| {
                argv[i] = v;
                argg[i] = 1;
            },
            .Bool => |v| {
                argv[i] = @intFromBool(v);
                argg[i] = 2;
            },
            .Unit => {
                argv[i] = 0;
                argg[i] = 3;
            },
            .Char => |v| {
                argv[i] = v;
                argg[i] = 4;
            },
            .Double => |v| {
                argv[i] = @bitCast(v);
                argg[i] = 5;
            },
            .Float => |v| {
                argv[i] = @as(u32, @bitCast(v));
                argg[i] = 6;
            },
            .Instance => |inst| {
                // Genre 8: a borrowed instance HANDLE (the raw cell — the
                // caller's frame roots it and the GC never moves cells).
                // Leaf field reads resolve through the view's field_route;
                // any other op on genre 8 bails.
                argv[i] = @bitCast(@as(u64, @intFromPtr(inst.cell)));
                argg[i] = 8;
            },
            else => {
                // Opaque cargo (genre 7): an unused receiver param rides
                // through; every emitted op on genre > 6 bails, so a body
                // that actually touches it re-runs interpreted.
                argv[i] = 0;
                argg[i] = 7;
            },
        }
    }
    var ev: NativeEdgeView = undefined;
    if (nctx) |nc| {
        nativeEdgeView(nc, &ev);
        ev.route_ctx = @ptrCast(host);
        ev.field_route = &LeafFieldRoute(H).route;
        ev.type_route = &LeafTypeRoute(H).route;
        ev.statics_route = &LeafStaticsRoute(H).route;
    } else {
        // Threadlocal cached interp edge view: every pointer in it is
        // process- or thread-stable, so the per-call cost collapses to
        // refreshing the two mode flags plus a host-identity check —
        // the full 12-field build (four of them fn calls) priced every
        // serve. The counter deliberately accumulates across calls;
        // the guard only compares it against per-call thresholds.
        if (leaf_ev_host != @as(?*anyopaque, @ptrCast(host))) {
            leaf_ev_cache = .{
                .rare = &leafEdgeRareInterp,
                .route_ctx = @ptrCast(host),
                .field_route = &LeafFieldRoute(H).route,
                .type_route = &LeafTypeRoute(H).route,
                .statics_route = &LeafStaticsRoute(H).route,
                .counter = &leaf_ev_counter,
                .idle = runtime.gc.idleTickPtr(),
                .abandonable = runtime.abandonablePtr(),
                .rb_abandon = runtime.runBoundaryAbandonPtr(),
                .abandon_req = runtime.abandonRequestedPtr(),
                .gc_pending = runtime.gc.pendingFlagPtr(),
                .gc_on = 0,
                .always = 0,
            };
            leaf_ev_host = @ptrCast(host);
        }
        leaf_ev_cache.gc_on = @intFromBool(runtime.gc.gc_enabled);
        leaf_ev_cache.always = @intFromBool(runtime.gc.stressActive());
    }
    const evp: *NativeEdgeView = if (nctx != null) &ev else &leaf_ev_cache;
    var rl: i64 = 0;
    var rg: i32 = 0;
    var aux: [8]i64 = undefined;
    var auxg: [8]i32 = undefined;
    const cctx: ?*anyopaque = if (nctx) |nc| @ptrCast(nc) else null;
    if (klf(cctx, evp, &argv, &argg, &rl, &rg, 0, &aux, &auxg) == 0) {
        _ = leaf_diag_bail.fetchAdd(1, .monotonic);
        // Bail damper: a leaf that has NEVER served and keeps bailing is
        // structural for this program's call shapes — stop attempting it.
        // The served bit is sticky, so a genre-mixed fn stays enabled.
        const probe = @constCast(cf).leaf_bail_probe.fetchAdd(1, .monotonic);
        if (probe & 0x8000_0000 == 0 and (probe & 0x7FFF_FFFF) >= 64) {
            @constCast(cf).leaf_route.store(1, .release);
        }
        return null;
    }
    _ = leaf_diag_serve.fetchAdd(1, .monotonic);
    const probe0 = cf.leaf_bail_probe.load(.monotonic);
    if (probe0 & 0x8000_0000 == 0) {
        _ = @constCast(cf).leaf_bail_probe.fetchOr(0x8000_0000, .monotonic);
    }
    if (runtime.envOnce("KLIO_LEAF_TRACE_SERVE") != null) {
        std.debug.print("[leaf-serve] {s} rg={d} rl={d}\n", .{ cf.fqn, rg, rl });
    }
    if (rg == leaf_ctor_tail_genre) {
        const sd: *CtorSite = @ptrFromInt(@as(usize, @bitCast(rl)));
        const memo = @atomicLoad(u64, &sd.memo, .acquire);
        const site_fid: u32 = if (memo != 0) @intCast(memo - 1) else fid_blk: {
            const want = std.mem.span(sd.fqn);
            const hash_pos = std.mem.lastIndexOfScalar(u8, want, '#') orelse return null;
            const want_fqn = want[0..hash_pos];
            const dot = std.mem.lastIndexOfScalar(u8, want_fqn, '.') orelse return null;
            var found: ?u32 = null;
            for (module.funcsBySimpleName(want_fqn[dot + 1 ..])) |cand| {
                const cf2 = module.funcById(cand) orelse continue;
                if (!std.mem.eql(u8, cf2.fqn, want_fqn)) continue;
                var buf2: [512]u8 = undefined;
                var fbs2 = std.heap.FixedBufferAllocator.init(&buf2);
                const k2 = leafKeyAlloc(fbs2.allocator(), cf2) orelse continue;
                if (std.mem.eql(u8, k2, want)) {
                    found = cand.int();
                    break;
                }
            }
            const got = found orelse return null;
            @atomicStore(u64, &sd.memo, @as(u64, got) + 1, .release);
            break :fid_blk got;
        };
        const tbi: usize = sd.block;
        const tii: usize = sd.inst;
        const sf = module.funcById(ir.FuncId.from(site_fid)) orelse return null;
        if (tbi >= sf.blocks.len or tii >= sf.blocks[tbi].insts.len) return null;
        const SiteCtor = struct { class: ir.ClassId, n_args: u32, arg_names: []const ?ir.ConstId, heads: []const ?ir.ConstId };
        const sc: SiteCtor = switch (sf.blocks[tbi].insts[tii]) {
            .NewInstance => |*ni| .{ .class = ni.class, .n_args = ni.n_args, .arg_names = ni.arg_names, .heads = ni.arg_static_heads },
            .CallMemberOrGlobal => |*cg| if (cg.class) |cl| SiteCtor{ .class = cl, .n_args = cg.n_args, .arg_names = cg.arg_names, .heads = &.{} } else return null,
            else => return null,
        };
        var vals: [8]Value = undefined;
        for (0..sc.n_args) |ai| {
            vals[ai] = switch (auxg[ai]) {
                0 => .{ .Int = @intCast(aux[ai]) },
                1 => .{ .Long = aux[ai] },
                2 => .{ .Bool = aux[ai] != 0 },
                3 => .Unit,
                4 => .{ .Char = @intCast(aux[ai]) },
                5 => .{ .Double = @bitCast(aux[ai]) },
                6 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(aux[ai]))))) },
                // A genre-8 aux is a borrowed handle used as a ctor arg;
                // the construction retains what it stores, so no retain
                // here — the caller's frame roots it for the call.
                8 => .{ .Instance = .{ .cell = @ptrFromInt(@as(usize, @bitCast(aux[ai]))) } },
                else => return null,
            };
        }
        const names = try resolveArgNames(allocator, module, sc.arg_names);
        defer freeArgNames(allocator, names);
        const static_heads = try resolveArgNames(allocator, module, sc.heads);
        defer freeArgNames(allocator, static_heads);
        if (comptime @hasDecl(H, "setCtorArgStaticHeads")) {
            host.setCtorArgStaticHeads(static_heads);
        }
        switch (try host.newInstanceNamed(allocator, sc.class, vals[0..sc.n_args], names, null)) {
            .ok => |v| return .{ .val = v },
            .err => |e| return .{ .raise = e },
        }
    }
    const v: Value = switch (rg) {
        0 => .{ .Int = @intCast(rl) },
        1 => .{ .Long = rl },
        2 => .{ .Bool = rl != 0 },
        3 => .Unit,
        4 => .{ .Char = @intCast(rl) },
        5 => .{ .Double = @bitCast(rl) },
        6 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(rl))))) },
        8 => blk8: {
            // A genre-8 handle coming BACK is a borrowed cell becoming an
            // owned Value: retain before it escapes the call window.
            const iv = Value{ .Instance = .{ .cell = @ptrFromInt(@as(usize, @bitCast(rl))) } };
            iv.retain();
            break :blk8 iv;
        },
        else => return null,
    };
    return .{ .val = v };
}

/// Frame-level wrapper over `tryLeafValues` for the framed call arm and
/// the transpiled program's glue: args come straight from the frame's
/// register file (they are Values already), the result writes the dst.
pub fn tryLeafCall(comptime H: type, allocator: Allocator, frame: *Frame, c: anytype, host: *H, nctx: ?*NativeCtx) Allocator.Error!?Step {
    if (!native_leaf_any.load(.acquire)) return null;
    if (c.type_args.len != 0 or !argNamesAllNull(c.arg_names)) return null;
    const cf = frame.module.funcById(c.func) orelse return null;
    const base = c.args.int();
    if (base + c.n_args > frame.regs.items.len) return null;
    const outcome = (try tryLeafValues(H, allocator, frame.module, cf, frame.regs.items[base .. base + c.n_args], host, nctx)) orelse return null;
    switch (outcome) {
        .val => |v| {
            try frame.write(c.dst, v);
            return .cont;
        },
        .raise => |e| return raiseStep(frame, e),
    }
}

fn nativeLeafFor(fid: u32, fqn: []const u8) ?NativeLeafFn {
    if (!native_leaf_any.load(.acquire)) return null;
    native_mutex.lock();
    defer native_mutex.unlock();
    if (native_leaf_table.get(fid)) |e| {
        if (std.mem.eql(u8, e.fqn, fqn)) return e.f;
    }
    return null;
}

/// Fqn-map lookup by the collision-proof key (fqn#sig).
fn nativeLeafForFunc(cf: *const Func) ?NativeLeafFn {
    if (!native_leaf_any.load(.acquire)) return null;
    var buf: [512]u8 = undefined;
    var fbs = std.heap.FixedBufferAllocator.init(&buf);
    const key = leafKeyAlloc(fbs.allocator(), cf) orelse return null;
    native_mutex.lock();
    defer native_mutex.unlock();
    return native_leaf_by_fqn.get(key);
}

var native_expect_funcs: usize = 0;
var native_expect_consts: usize = 0;

/// The emitted operands (const ids, fids, register numbers) index the
/// tables of the module the emitter walked. The fqn guard catches a
/// shifted fid, but a frame can carry a module whose CONST pool differs
/// while the function itself matches — a delegating anonymous-object
/// module, or a run that rebuilt a different module shape — and a
/// mismatched const id then reads garbage (or out of bounds). The
/// emitted C registers the walked module's table sizes; a frame whose
/// module carries LESS runs interpreted. Prefix bound, not equality:
/// execution appends runtime-synthesized functions and constants to the
/// program module, which leaves every emitted id valid.
pub fn setNativeModuleCheck(n_funcs: usize, n_consts: usize) void {
    native_expect_funcs = n_funcs;
    native_expect_consts = n_consts;
}

fn nativeModuleOk(module: *const Module) bool {
    if (native_expect_funcs == 0 and native_expect_consts == 0) return true;
    const match = module.funcs.items.len >= native_expect_funcs and
        module.consts.items.len >= native_expect_consts;
    if (!match and runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
        std.debug.print("[native-modcheck] funcs {d} (want {d}) consts {d} (want {d})\n", .{
            module.funcs.items.len, native_expect_funcs,
            module.consts.items.len, native_expect_consts,
        });
    }
    return match;
}

/// What a native run left for the frame loop: the same exits the stream
/// loop has. `term`/`goto` mirror `bc_term`/`bc_goto`, `brk` is the
/// unwind break with `thrown`/`unwound` set, `ret` returns `ret_v`,
/// `none` means the entry block was not compiled (fall back to the
/// stream/walker for this block).
pub const NativeOutcome = enum(u8) { none, term, goto, brk, ret, oom };

const NativeStep = enum { cont, brk, ret, oom };

/// Recursive native call serving stops here and flat-parks instead; each
/// recursive level stacks kf + glue + serve frames, so this must sit well
/// under the C stack's capacity while staying above any realistic
/// non-adversarial call chain.
const NATIVE_RECURSE_MAX_DEPTH: usize = 200;

pub const NativeCtx = struct {
    frame: *Frame,
    allocator: Allocator,
    ftls: *EvalTls,
    host: *anyopaque,
    flat_out: *?FlatCallSite,
    park_out: *?ParkPoint,
    thrown: *?Value,
    unwound: *?EvalError,
    ret_v: *EvalResult,
    /// Host-typed glue (the frame loop instantiates these for its `H`):
    /// run `execArmBinOp`/`execInst`/`execArmCall` + `afterStep` for the
    /// inst at (block, idx).
    arm_bin: *const fn (*NativeCtx, u32, u32) NativeStep,
    escape: *const fn (*NativeCtx, u32, u32) NativeStep,
    call: *const fn (*NativeCtx, u32, u32) NativeStep,
    /// Resolve a `GetField` site to (class cell identity, stored slot) for
    /// the receiver currently in its register, so the emitted C can read the
    /// slot inline behind a class guard. Zero when the site is not a plain
    /// stored read (custom accessor, non-instance receiver, unknown class).
    field_route: *const fn (*NativeCtx, u32, u32, *u64, *i32) i32,
    /// The same for a `SetField` site: a plain stored-slot verdict from the
    /// interpreter's write memo, so the emitted C can store into the slot
    /// behind a class guard (with the GC write barrier).
    field_write_route: *const fn (*NativeCtx, u32, u32, *u64, *i32) i32,
    outcome: NativeOutcome = .none,
    out_block: u32 = 0,
};

fn NativeGlue(comptime H: type) type {
    return struct {
        fn armBin(ctx: *NativeCtx, block: u32, idx: u32) NativeStep {
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            const r = execArmBinOp(H, ctx.allocator, frame, inst.BinOp, host) catch return .oom;
            return glueAfter(ctx, r, inst, idx, block);
        }
        fn fieldRoute(ctx: *NativeCtx, block: u32, idx: u32, cls_out: *u64, slot_out: *i32) i32 {
            if (comptime !@hasDecl(H, "fieldSiteRoute")) return 0;
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            if (inst.* != .GetField) return 0;
            const gf = inst.GetField;
            const recv = frame.read(gf.receiver);
            if (recv != .Instance) return 0;
            const name = constStr(frame.module, gf.field) orelse return 0;
            // The site memo's own verdict decides this, exactly as the
            // frameless accessor serve reads it: only a PLAIN STORED slot
            // (tag 1) may be read inline. A getter route, an outer-hop read
            // or a delegated/lateinit property keeps the escape path, which
            // is what forces a `by lazy` instead of handing back the
            // delegate object.
            const claim = host.fieldSiteRoute(&recv, name) orelse return 0;
            if (claim.route & 3 != 1) return 0;
            const slot: usize = @intCast(claim.route >> 2);
            {
                const g = recv.Instance.borrow();
                defer g.deinit();
                const fields = g.get().fields.items;
                if (slot >= fields.len) return 0;
                // Re-verify by name, and decline the shapes the serve
                // declines: a null slot may be an unset lateinit, and a
                // Delegate must be read through its own protocol.
                const fld = fields[slot];
                if (!std.mem.eql(u8, fld.name, name) and
                    !H.sgetterNameMatches(name, fld.name)) return 0;
                if (fld.value == .Null or fld.value == .Delegate) return 0;
                // The identity the emitted C compares is the raw CELL
                // pointer it reads out of `InstanceData.class`; `asPtr`
                // would hand back the payload address instead.
                cls_out.* = @intFromPtr(g.get().class.cell);
            }
            slot_out.* = @intCast(slot);
            return 1;
        }
        fn fieldWriteRoute(ctx: *NativeCtx, block: u32, idx: u32, cls_out: *u64, slot_out: *i32) i32 {
            if (comptime !@hasDecl(H, "fieldWriteSiteRoute")) return 0;
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            if (inst.* != .SetField) return 0;
            const sf = inst.SetField;
            const recv = frame.read(sf.receiver);
            if (recv != .Instance) return 0;
            const name = constStr(frame.module, sf.field) orelse return 0;
            const claim = host.fieldWriteSiteRoute(&recv, name) orelse return 0;
            if (claim.route & 3 != 1) return 0;
            cls_out.* = claim.cls;
            slot_out.* = @intCast(claim.route >> 2);
            return 1;
        }
        fn escape(ctx: *NativeCtx, block: u32, idx: u32) NativeStep {
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            const r = execInst(H, ctx.allocator, frame, inst, host) catch return .oom;
            return glueAfter(ctx, r, inst, idx, block);
        }
        fn call(ctx: *NativeCtx, block: u32, idx: u32) NativeStep {
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            // Recursive serving stacks a full native+glue+serve slice per
            // level, far heavier than an interpreter frame — past this
            // depth the C stack would fault long before the eval-depth
            // cap raises its catchable StackOverflow. Deep chains hand
            // the call to the flat driver instead (the caller unwinds and
            // resumes through the stream: slower, bounded).
            const recurse_ok = evtls.eval_depth < NATIVE_RECURSE_MAX_DEPTH;
            // A monomorphic plain call whose callee LEAF-serves is
            // answered in place — the same `leafExprServe` the
            // interpreter's flat driver uses, without the full-frame
            // recursive serve (which cost native calls 3x against the
            // interpreter on fib). The gate mirrors execArmCall's fast
            // path minus the shapes the leaf bank cannot take
            // (extensions seed receivers; ambiguous fids re-resolve).
            if (recurse_ok) direct: {
                const c = &inst.Call;
                if (c.type_args.len != 0 or !argNamesAllNull(c.arg_names)) break :direct;
                const cf = frame.module.funcById(c.func) orelse break :direct;
                // Scalar-replay body (`kl_`): the whole call runs as direct
                // C over (int64, genre) pairs when every argument is a
                // scalar. A zero return is a pure bail — fall through to
                // the ordinary paths, which re-run the call exactly.
                if (tryLeafCall(H, ctx.allocator, frame, c, host, ctx) catch return .oom) |st| {
                    if (st == .cont) return .cont;
                    return glueAfter(ctx, st, inst, idx, block);
                }
                if (!cf.leafExprBody()) break :direct;
                var plan = cf.fast_call;
                if (plan == 0) {
                    if (comptime @hasDecl(H, "fastCallPlan")) {
                        plan = host.fastCallPlan(frame.module, c.func);
                        @constCast(cf).fast_call = plan;
                    } else break :direct;
                }
                if (plan & ir.FAST_CALL_EXT_FLAG != 0) break :direct;
                if (plan & ir.FAST_CALL_AMBIG_FLAG != 0) break :direct;
                const plan_arity = plan & 0x1FFF;
                if (plan_arity < 2 or plan_arity - 2 != c.n_args) break :direct;
                const base = c.args.int();
                if (base + c.n_args > frame.regs.items.len) break :direct;
                const argv = frame.regs.items[base .. base + c.n_args];
                const lr = leafExprServe(H, ctx.allocator, frame.module, cf, argv, host) catch return .oom;
                if (lr) |served| {
                    frame.write(c.dst, served.ok) catch return .oom;
                    return .cont;
                }
            }
            const r = execArmCall(H, ctx.allocator, frame, &inst.Call, host, !recurse_ok) catch return .oom;
            // A flat request whose callee LEAF-serves is answered in
            // place: the flat driver would run the same
            // `leafExprServe` after a full kf_ unwind + stream resume
            // — the round trip cost native calls 3x against the
            // interpreter on call-heavy code (fib). Identical serve,
            // identical module choice, no unwind.
            if (r == .flat_call) leaf: {
                const req = frame.flat_call.?;
                if (!leafReqServable(req)) break :leaf;
                const callee_mod: *const Module = req.run_module orelse blk: {
                    if (funcOwnedBy(frame.module, req.func)) break :blk frame.module;
                    if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                        if (host.ownerModuleForFunc(req.func)) |m| break :blk m;
                    }
                    break :blk frame.module;
                };
                const lr = leafExprServe(H, ctx.allocator, callee_mod, req.func, req.args.items, host) catch return .oom;
                if (lr) |served| {
                    frame.flat_call = null;
                    const dst = req.dst;
                    discardFlatReq(H, ctx.allocator, req, host);
                    frame.write(dst, served.ok) catch return .oom;
                    return .cont;
                }
            }
            return glueAfter(ctx, r, inst, idx, block);
        }
    };
}

fn glueAfter(ctx: *NativeCtx, r: Step, inst: *const Inst, idx: u32, block: u32) NativeStep {
    const a = afterStep(
        ctx.allocator,
        ctx.frame,
        r,
        inst,
        idx,
        @enumFromInt(block),
        ctx.flat_out,
        ctx.park_out,
        ctx.thrown,
        ctx.unwound,
        ctx.ret_v,
    ) catch return .oom;
    return switch (a) {
        .cont => .cont,
        .brk => .brk,
        .ret => .ret,
    };
}

/// The activation's register file as raw bytes for the emitted C's
/// inline scalar ops (the hot view). Stable for the whole activation:
/// regs are sized once at frame construction and never reallocated.
pub fn nativeFrameRegs(ctx: *NativeCtx) [*]u8 {
    return @ptrCast(ctx.frame.regs.items.ptr);
}

pub fn nativeOpTrace(ctx: *NativeCtx, file: u32, start: u32, end: u32) void {
    ctx.frame.cur_span = .{ .file = @enumFromInt(file), .start = start, .end = end };
}

/// The frame's `cur_span` storage as raw bytes, so the emitted C can
/// inline the per-statement trace store (a plain 3×u32 + presence-tag
/// write; no ownership). Stable for the activation — the frame is a
/// field of the heap activation.
pub fn nativeFrameSpanSlot(ctx: *NativeCtx) [*]u8 {
    return @ptrCast(&ctx.frame.cur_span);
}

/// The per-thread/global flag addresses the emitted C polls to inline
/// the fused edge guard: the guard's slow work runs only when a trigger
/// fires (`nativeOpEdgeRare`). Pointers are per-THREAD where the state
/// is threadlocal, so the view is fetched at every activation entry —
/// the same freshness rule as the register base.
pub const NativeEdgeView = extern struct {
    counter: *u64,
    idle: *u64,
    abandonable: *const bool,
    rb_abandon: *const bool,
    abandon_req: *const bool,
    gc_pending: *const bool,
    gc_on: u8,
    always: u8,
    /// Rare-trigger handler for this view's context (see klio_rt.h).
    rare: *const fn (ctx: ?*anyopaque, reasons: u32) callconv(.c) i32,
    /// Field-read route resolver for leaf genre-8 handles (see
    /// klio_rt.h); null outside the leaf gates.
    route_ctx: ?*anyopaque = null,
    field_route: ?*const fn (route_ctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8, cls48_out: *u64, slot_out: *i32) callconv(.c) i32 = null,
    /// Instance-of verdict resolver for leaf genre-8 handles: 1 = the
    /// receiver's class IS the named type, 2 = it is not, 0 = miss
    /// (bail). The site binds the verdict to the receiver's class word.
    type_route: ?*const fn (route_ctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8) callconv(.c) i32 = null,
    /// Static-member resolver for leaf genre-9 class handles (`owner`
    /// is the emitted class-name literal): fills (value, genre) and
    /// returns 1, or 0 to bail. Enum entries only — see
    /// leafStaticMember.
    statics_route: ?*const fn (route_ctx: ?*anyopaque, owner: [*:0]const u8, name: [*:0]const u8, out_v: *i64, out_g: *i32) callconv(.c) i32 = null,
};

/// Per-host statics thunk for leaf bodies: a genre-9 class handle's
/// member read resolves through the host's enum-entry table (the only
/// borrow-safe static family) and marshals the entry like a leaf arg.
fn LeafStaticsRoute(comptime H: type) type {
    return struct {
        fn route(rctx: ?*anyopaque, owner: [*:0]const u8, name: [*:0]const u8, out_v: *i64, out_g: *i32) callconv(.c) i32 {
            if (comptime !@hasDecl(H, "leafStaticMember")) return 0;
            const host: *H = @ptrCast(@alignCast(rctx orelse return 0));
            const v = host.leafStaticMember(std.mem.span(owner), std.mem.span(name)) orelse return 0;
            switch (v) {
                .Int => |x| {
                    out_v.* = x;
                    out_g.* = 0;
                },
                .Long => |x| {
                    out_v.* = x;
                    out_g.* = 1;
                },
                .Bool => |x| {
                    out_v.* = @intFromBool(x);
                    out_g.* = 2;
                },
                .Char => |x| {
                    out_v.* = x;
                    out_g.* = 4;
                },
                .Instance => |inst| {
                    out_v.* = @bitCast(@as(u64, @intFromPtr(inst.cell)));
                    out_g.* = 8;
                },
                else => return 0,
            }
            return 1;
        }
    };
}

/// Per-host instance-of thunk for leaf bodies: rebuilds a borrowed
/// Instance view over the raw cell and asks the host's own `is`
/// predicate against a plain non-nullable classifier name (eligibility
/// rejected everything else). 1 = yes, 2 = no; the site caches the
/// verdict keyed to the receiver's class word.
fn LeafTypeRoute(comptime H: type) type {
    return struct {
        fn route(rctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8) callconv(.c) i32 {
            if (comptime !@hasDecl(H, "instanceOf")) return 0;
            const host: *H = @ptrCast(@alignCast(rctx orelse return 0));
            const cell = recv_cell orelse return 0;
            const v = Value{ .Instance = .{ .cell = @ptrCast(@alignCast(cell)) } };
            const ty = TypeRef{ .name = std.mem.span(name), .nullable = false, .args = &.{} };
            return if (host.instanceOf(&v, ty)) 1 else 2;
        }
    };
}

/// Per-host field-route thunk for leaf bodies: rebuilds a borrowed
/// Instance view over the raw cell (no retain — the leaf's caller roots
/// it) and asks the host's single-fill field-site claim. Only a PLAIN
/// STORED slot resolves; everything else bails the leaf.
fn LeafFieldRoute(comptime H: type) type {
    return struct {
        fn route(rctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8, cls48_out: *u64, slot_out: *i32) callconv(.c) i32 {
            if (comptime !@hasDecl(H, "fieldSiteRoute")) return 0;
            const host: *H = @ptrCast(@alignCast(rctx orelse return 0));
            const cell = recv_cell orelse return 0;
            const v = Value{ .Instance = .{ .cell = @ptrCast(@alignCast(cell)) } };
            var claim = host.fieldSiteRoute(&v, std.mem.span(name)) orelse {
                if (runtime.envOnce("KLIO_LEAF_ROUTE_TRACE") != null)
                    std.debug.print("[leaf-route] {s}: no claim\n", .{std.mem.span(name)});
                return 0;
            };
            if (runtime.envOnce("KLIO_LEAF_ROUTE_TRACE") != null)
                std.debug.print("[leaf-route] {s}: tag={d}\n", .{ std.mem.span(name), claim.route & 3 });
            if (claim.route & 3 == 2) {
                // A GETTER route whose body is the canonical trivial
                // accessor (`get() = _backing`) chases through to the
                // backing field's stored slot — one level, exactly the
                // accessorFastGet shape. Anything else bails the leaf.
                if (comptime !@hasDecl(H, "hostModulePtr")) return 0;
                const mod2 = host.hostModulePtr();
                const gfid: u32 = @intCast(claim.route >> 2);
                const gf = mod2.funcById(ir.FuncId.from(gfid)) orelse return 0;
                const fc = gf.accessorFieldConstIn(mod2) orelse return 0;
                if (fc.int() >= mod2.consts.items.len) return 0;
                const under: []const u8 = switch (mod2.consts.items[fc.int()]) {
                    .String => |sv| sv,
                    else => return 0,
                };
                claim = host.fieldSiteRoute(&v, under) orelse return 0;
            }
            if (claim.route & 3 != 1) return 0;
            const slot = claim.route >> 2;
            if (slot > std.math.maxInt(i32)) return 0;
            cls48_out.* = claim.cls & 0xFFFF_FFFF_FFFF;
            slot_out.* = @intCast(slot);
            return 1;
        }
    };
}

/// Rare handler for the INTERPRETER's leaf gate: no NativeCtx exists,
/// so a persistent condition (abandon request, pending GC, an expired
/// test wall deadline) bails the leaf — the interpreted re-run reaches
/// its own safe point and services it; the condition persisting is what
/// makes the bail loop-free. A bare cadence tick continues natively.
fn leafEdgeRareInterp(ctx: ?*anyopaque, reasons: u32) callconv(.c) i32 {
    _ = ctx;
    if (reasons & 0x2 != 0 and runtime.shouldAbandon()) return 1;
    if (reasons & 0x4 != 0) return 1;
    if (reasons & 0x1 != 0) {
        spinDumpMaybe();
        const wall_dl = test_wall_deadline_ms.load(.monotonic);
        if (wall_dl != 0 and nowMonotonicMs() > wall_dl) return 1;
    }
    return 0;
}

fn nativeOpEdgeRareC(ctx: ?*anyopaque, reasons: u32) callconv(.c) i32 {
    return nativeOpEdgeRare(@ptrCast(@alignCast(ctx.?)), reasons);
}

pub fn nativeEdgeView(ctx: *NativeCtx, out: *NativeEdgeView) void {
    out.* = .{
        .rare = &nativeOpEdgeRareC,
        .counter = &ctx.ftls.spin_check_counter,
        .idle = runtime.gc.idleTickPtr(),
        .abandonable = runtime.abandonablePtr(),
        .rb_abandon = runtime.runBoundaryAbandonPtr(),
        .abandon_req = runtime.abandonRequestedPtr(),
        .gc_pending = runtime.gc.pendingFlagPtr(),
        .gc_on = @intFromBool(runtime.gc.gc_enabled),
        .always = @intFromBool(runtime.gc.stressActive()),
    };
}

/// Edge-guard slow path for the inlined edge: `reasons` says which
/// trigger fired (bit 0 = counter cadence, bit 1 = abandon flags,
/// bit 2 = gc pending, bit 3 = stress/always, bit 4 = idle cadence);
/// the actions mirror `fusedEdgeGuard` exactly for those triggers.
pub fn nativeOpEdgeRare(ctx: *NativeCtx, reasons: u32) i32 {
    if (reasons & 0x2 != 0 and runtime.shouldAbandon()) {
        ctx.ret_v.* = errResult(.{ .Type = "daemon task abandoned at run boundary" });
        ctx.outcome = .ret;
        return 1;
    }
    if (reasons & 0x1 != 0) {
        spinDumpMaybe();
        const wall_dl = test_wall_deadline_ms.load(.monotonic);
        if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
            ctx.ret_v.* = wallCapFire(ctx.allocator) catch
                errResult(.{ .Type = "test wall-clock deadline exceeded" });
            ctx.outcome = .ret;
            return 1;
        }
    }
    if (reasons & 0x8 != 0) {
        // Stress mode: run the full guard's gc arm (pending() carries the
        // stress counters).
        if (runtime.gc.gc_enabled and runtime.gc.pending()) runtime.gc.safePoint();
        return 0;
    }
    if (reasons & 0x10 != 0) runtime.gc.idleProbeNow();
    if (reasons & 0x4 != 0) {
        if (runtime.gc.gc_enabled) runtime.gc.safePoint();
    }
    return 0;
}

pub fn nativeOpConstLoad(ctx: *NativeCtx, dst: u32, const_id: u32) i32 {
    const v = constToValue(ctx.allocator, &ctx.frame.module.consts.items[const_id]) catch {
        ctx.outcome = .oom;
        return 1;
    };
    writeFastU(ctx.frame, @enumFromInt(dst), v, ctx.allocator);
    return 0;
}

pub fn nativeOpConstInt(ctx: *NativeCtx, dst: u32, payload: i32) void {
    writeFastU(ctx.frame, @enumFromInt(dst), .{ .Int = payload }, ctx.allocator);
}

pub fn nativeOpMove(ctx: *NativeCtx, dst: u32, src: u32) void {
    const v = ctx.frame.regs.items.ptr[src];
    v.retain();
    writeFastU(ctx.frame, @enumFromInt(dst), v, ctx.allocator);
}

pub fn nativeOpLoadParam(ctx: *NativeCtx, dst: u32, pidx: u32) void {
    const frame = ctx.frame;
    const v = if (pidx < frame.params.items.len) frame.params.items[pidx] else Value.Unit;
    v.retain();
    writeFastU(frame, @enumFromInt(dst), v, ctx.allocator);
}

pub fn nativeOpCellGet(ctx: *NativeCtx, dst: u32, cell: u32) void {
    const frame = ctx.frame;
    const v = switch (frame.regs.items.ptr[cell]) {
        .Cell => |c| vblk: {
            const g = c.borrow();
            defer g.deinit();
            break :vblk g.get().*;
        },
        else => |other| other,
    };
    v.retain();
    writeFastU(frame, @enumFromInt(dst), v, ctx.allocator);
}

/// Nonzero = the emitted function must return (outcome set on the ctx).
pub fn nativeOpBin(ctx: *NativeCtx, block: u32, inst_idx: u32, kind: u32, dst: u32, lhs: u32, rhs: u32) i32 {
    if (binFast(ctx.frame, @enumFromInt(kind), @enumFromInt(dst), @enumFromInt(lhs), @enumFromInt(rhs), ctx.allocator)) return 0;
    switch (ctx.arm_bin(ctx, block, inst_idx)) {
        .cont => return 0,
        .brk => {
            ctx.outcome = .brk;
            ctx.out_block = block;
            return 1;
        },
        .ret => {
            ctx.outcome = .ret;
            return 1;
        },
        .oom => {
            ctx.outcome = .oom;
            return 1;
        },
    }
}

/// A statically-bound `.Call` escape, served recursively so the emitted
/// caller stays on the C stack (the callee's own emitted body engages
/// inside the recursive activation). Same return contract as
/// `nativeOpEscape`.
pub fn nativeOpCall(ctx: *NativeCtx, block: u32, inst_idx: u32) i32 {
    if (runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
        std.debug.print("[native-call] from={s} b{d} i{d}\n", .{ ctx.frame.func.fqn, block, inst_idx });
    }
    switch (ctx.call(ctx, block, inst_idx)) {
        .cont => return 0,
        .brk => {
            ctx.outcome = .brk;
            ctx.out_block = block;
            return 1;
        },
        .ret => {
            ctx.outcome = .ret;
            return 1;
        },
        .oom => {
            ctx.outcome = .oom;
            return 1;
        },
    }
}

/// Nonzero = the emitted function must return (outcome set on the ctx).
/// Resolve a `GetField` site for the emitted C's inline read. Returns 1 with
/// `cls_out`/`slot_out` filled when the site is a plain stored field on the
/// receiver's current class; 0 leaves the site on the escape helper.
pub fn nativeOpFieldRoute(ctx: *NativeCtx, block: u32, inst_idx: u32, cls_out: *u64, slot_out: *i32) i32 {
    return ctx.field_route(ctx, block, inst_idx, cls_out, slot_out);
}

pub fn nativeOpFieldWriteRoute(ctx: *NativeCtx, block: u32, inst_idx: u32, cls_out: *u64, slot_out: *i32) i32 {
    return ctx.field_write_route(ctx, block, inst_idx, cls_out, slot_out);
}

pub fn nativeOpEscape(ctx: *NativeCtx, block: u32, inst_idx: u32) i32 {
    switch (ctx.escape(ctx, block, inst_idx)) {
        .cont => return 0,
        .brk => {
            ctx.outcome = .brk;
            ctx.out_block = block;
            return 1;
        },
        .ret => {
            ctx.outcome = .ret;
            return 1;
        },
        .oom => {
            ctx.outcome = .oom;
            return 1;
        },
    }
}

/// The per-taken-edge guards on a fused `goto`. Nonzero = return.
pub fn nativeOpEdge(ctx: *NativeCtx) i32 {
    if (fusedEdgeGuard(ctx.allocator, ctx.ftls)) |er| {
        ctx.ret_v.* = er;
        ctx.outcome = .ret;
        return 1;
    }
    return 0;
}

/// Fused Branch: 1 = take the true edge, 0 = the false edge, 2 = return
/// (non-Bool condition exits to the real terminator; edge-guard abort).
pub fn nativeOpBr(ctx: *NativeCtx, block: u32, cond: u32) i32 {
    const cv = ctx.frame.regs.items.ptr[cond];
    if (cv != .Bool) {
        ctx.outcome = .term;
        ctx.out_block = block;
        return 2;
    }
    if (fusedEdgeGuard(ctx.allocator, ctx.ftls)) |er| {
        ctx.ret_v.* = er;
        ctx.outcome = .ret;
        return 2;
    }
    return @intFromBool(cv.Bool);
}

/// Fused compare-and-branch; same return contract as `nativeOpBr`.
pub fn nativeOpCmpBr(ctx: *NativeCtx, block: u32, inst_idx: u32, kind: u32, dst: u32, lhs: u32, rhs: u32) i32 {
    const frame = ctx.frame;
    var taken: ?bool = null;
    {
        const regs = frame.regs.items.ptr;
        if (scalarBin(@enumFromInt(kind), regs[lhs], regs[rhs])) |out| {
            if (out == .Bool) {
                const old = regs[dst];
                regs[dst] = out;
                frame.wmask.set(dst);
                if (runtime.reclaimEnabled()) old.release(ctx.allocator);
                taken = out.Bool;
            }
        }
    }
    if (taken == null) {
        switch (ctx.arm_bin(ctx, block, inst_idx)) {
            .cont => {},
            .brk => {
                ctx.outcome = .brk;
                ctx.out_block = block;
                return 2;
            },
            .ret => {
                ctx.outcome = .ret;
                return 2;
            },
            .oom => {
                ctx.outcome = .oom;
                return 2;
            },
        }
        const cv = frame.read(@enumFromInt(dst));
        if (cv != .Bool) {
            ctx.outcome = .term;
            ctx.out_block = block;
            return 2;
        }
        taken = cv.Bool;
    }
    if (fusedEdgeGuard(ctx.allocator, ctx.ftls)) |er| {
        ctx.ret_v.* = er;
        ctx.outcome = .ret;
        return 2;
    }
    return @intFromBool(taken.?);
}

pub fn nativeOpRet(ctx: *NativeCtx, has_val: u32, reg: u32) void {
    const v: Value = if (has_val != 0) ctx.frame.regs.items.ptr[reg] else .Unit;
    v.retain();
    ctx.ret_v.* = ok(v);
    ctx.outcome = .ret;
}

pub fn nativeOpTerm(ctx: *NativeCtx, block: u32) void {
    ctx.outcome = .term;
    ctx.out_block = block;
}

pub fn nativeOpGotoExit(ctx: *NativeCtx, block: u32) void {
    ctx.outcome = .goto;
    ctx.out_block = block;
}

noinline fn execInst(comptime H: type, allocator: Allocator, frame: *Frame, inst: *const Inst, host: *H) Allocator.Error!Step {
    if (frame_count_on) inst_count += 1;
    if (runtime.prof.op_prof_active) runtime.prof.current_op = @intFromEnum(inst.*);
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
                else => {
                    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        std.debug.print("[not-miss] in={s} kind={s} span={?any}\n", .{
                            frame.func.name, @tagName(std.meta.activeTag(v)), frame.cur_span,
                        });
                        dumpCurrentFrameParamsForDiag();
                        dumpFrameChainForDiagAlways();
                    }
                    return raiseStep(frame, .{ .Type = "Not on non-bool" });
                },
            };
            try frame.write(n.dst, .{ .Bool = b });
        },
        .UnOp => |u| return execArmUnOp(H, allocator, frame, u, host),
        .BinOp => |bo| return execArmBinOp(H, allocator, frame, bo, host),
        .Trace => |t| frame.cur_span = t.span,
        .EnclosingPush => |x| {
            const v = frame.read(x.src);
            pushEnclosingSubject(&v);
        },
        .EnclosingPop => popEnclosing(),
        .LoadParam => |lp| {
            const v = if (lp.idx < frame.params.items.len) frame.params.items[lp.idx] else Value.Unit;
            v.retain();
            try frame.write(lp.dst, v);
        },
        .NotNullAssert => |nn| {
            const v = frame.read(nn.src);
            if (v == .Null) {
                const exc = try Value.newException(allocator, .{
                    .fqn = try runtime.strInit(allocator, "kotlin.NullPointerException"),
                    .message = .{},
                    .cause = null,
                });
                return raiseStep(frame, .{ .Throw = exc });
            }
            v.retain();
            try frame.write(nn.dst, v);
        },
        .GetField => |*gf| {
            const gf_step = try execArmGetField(H, allocator, frame, gf, host);
            if (gfTraceWant()) |w0| {
                if (constStr(frame.module, gf.field)) |fname| {
                    if (std.mem.indexOf(u8, fname, w0) != null and gf_step == .cont) {
                        const rv = frame.read(gf.dst);
                        const rn: []const u8 = if (rv == .Instance) blk: {
                            const g = rv.Instance.borrow();
                            const cg = g.get().class.borrow();
                            const n = cg.get().name;
                            cg.deinit();
                            g.deinit();
                            break :blk n;
                        } else @tagName(rv);
                        std.debug.print("[gfarm]   -> result={s}\n", .{rn});
                    }
                }
            }
            return gf_step;
        },
        .SetField => |sf| return execArmSetField(H, allocator, frame, sf, host),
        .CompoundField => |cf| return execArmCompoundField(H, allocator, frame, cf, host),
        .Call => |*call| return execArmCall(H, allocator, frame, call, host, true),
        .CallValue => |cv| return execArmCallValue(H, allocator, frame, cv, host),
        .CallValueWithThis => |cvt| {
            var callee_v = frame.read(cvt.callee);
            // A boxed capture holds the callable in a cell — a recursive local
            // extension function reaches its own closure through the shared
            // self-cell. A Cell is never callable itself, so classify its
            // CONTENT, exactly as the value-or-member arm does.
            if (callee_v == .Cell) {
                const cg = callee_v.Cell.borrow();
                callee_v = cg.get().*;
                cg.deinit();
            }
            const recv = frame.read(cvt.receiver);
            const arg_values = try readArgRun(allocator, frame, cvt.args, cvt.n_args);
            defer allocator.free(arg_values);
            const names = try resolveArgNames(allocator, frame.module, cvt.arg_names);
            defer freeArgNames(allocator, names);
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
                if (flatEnabled() and cvt.recv_head == null and callee_v == .IrClosure and argNamesAllNull(cvt.arg_names)) {
                    if (try host.prepareClosureWithThisFlatCall(allocator, &callee_v, &recv, arg_values)) |prep0| {
                        var prep = prep0;
                        prep.dst = cvt.dst;
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            const result = if (cvt.recv_head != null and comptime @hasDecl(H, "callValueWithThisHead")) blk: {
                const head = constStr(frame.module, cvt.recv_head.?) orelse "";
                break :blk try host.callValueWithThisHead(allocator, &callee_v, &recv, arg_values, names, head);
            } else if (cvt.receiver_shape_exact)
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
        .CallMemberOrGlobal => |*cmg| return execCallMemberOrGlobal(H, allocator, frame, cmg, host),
        .CallMember => |*cm| return execArmCallMember(H, allocator, frame, cm, host),
        .CallVirtual => |*cv| return execArmCallVirtual(H, allocator, frame, cv, host),
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
            switch (try loadGlobalValue(H, allocator, frame.module, lg, host)) {
                .ok => |v| try frame.write(lg.dst, v),
                .err => |e| return raiseStep(frame, e),
            }
        },
        .LoadCapture => |lc| {
            const v = if (lc.idx < frame.captures.items.len) frame.captures.items[lc.idx] else Value.Unit;
            v.retain();
            try frame.write(lc.dst, v);
        },
        .LoadFromThisOrGlobal => |*lt| return execArmLoadFromThisOrGlobal(H, allocator, frame, lt, host),
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
    const l = frame.read(bo.lhs);
    const r = frame.read(bo.rhs);
    switch (try binopValue(H, allocator, l, r, @TypeOf(bo), bo, host)) {
        .ok => |v| try frame.write(bo.dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// The full binary-operator semantics with no frame coupling: the framed
/// arm and the fused tier both call this, so the slow tails (identity and
/// structural equality, string concatenation through user toString,
/// collection operators, compareTo reduction) exist exactly once.
fn binopValue(comptime H: type, allocator: Allocator, l_in: Value, r_in: Value, comptime OpT: type, bo: OpT, host: *H) Allocator.Error!EvalResult {
    var l = l_in;
    var r = r_in;
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
    // `Add` with a String operand IS concatenation (`String.plus(Any?)`), so
    // it renders the other side the same way — through the host, where a user
    // `toString` and a container's element renderings fire. The host-free
    // arithmetic fallback would print `ClassName@id` for a user element.
    // LEFT operand only: `String.plus(Any?)` is a member on String, while
    // `collection + element` is the collection's own `plus`.
    const string_add = bo.op == .Add and l == .String;
    if (bo.op == .StringConcat or string_add) {
        const ls = switch (try stringify(H, allocator, host, &l)) {
            .ok => |s| s,
            .err => |e| return errResult(e),
        };
        const rs = switch (try stringify(H, allocator, host, &r)) {
            .ok => |s| s,
            .err => |e| return errResult(e),
        };
        const combined = try std.mem.concat(allocator, u8, &.{ ls, rs });
        // `ls`/`rs` are owned renderings (stringify/renderValue allocate
        // a private copy); `combined` is adopted by the StringRef cell.
        // Free the two now-dead pieces under a freeing allocator.
        if (runtime.freeScratch()) {
            allocator.free(ls);
            allocator.free(rs);
        }
        return ok(.{ .String = try runtime.strInitOwned(allocator, combined) });
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
                        return ok(l);
                    },
                    .err => |e| return errResult(e),
                }
            }
        }
        const method = if (bo.op == .Add) "plus" else "minus";
        switch (try host.callMember(allocator, &l, method, &.{r})) {
            .ok => |rv| {
                return ok(rv);
            },
            .err => |e| return errResult(e),
        }
    }
    // Arrays define `+` (`plus`) but no `-`.
    if (bo.op == .Add and l == .Array) {
        switch (try host.callMember(allocator, &l, "plus", &.{r})) {
            .ok => |rv| {
                return ok(rv);
            },
            .err => |e| return errResult(e),
        }
    }
    // Referential identity (`===` / `!==`): pure pointer
    // identity, never a user `equals` dispatch.
    if (bo.op == .IdentEq or bo.op == .IdentNeq) {
        const same = Value.referenceEq(&l, &r);
        const b = if (bo.op == .IdentNeq) !same else same;
        return ok(.{ .Bool = b });
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
        return ok(.{ .Bool = b });
    }
    // The suspension marker has identity-only equality and no member surface.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .CoroutineSuspended or r == .CoroutineSuspended))
    {
        const eq = Value.structuralEq(&l, &r);
        const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
        return ok(.{ .Bool = b });
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
        return ok(.{ .Bool = b });
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
            return ok(.{ .Bool = if (neg) !eq else eq });
        }
    }
    // Callable references compare by target, bound receiver and adaptation
    // (two loads of `::f` are equal; two wrappers of the same adaptation of
    // the same target are equal), never by closure identity alone.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .IrClosure or r == .IrClosure or l == .PropertyRef or r == .PropertyRef) and
        comptime @hasDecl(H, "deepValueEquals"))
    {
        // A callable against a non-callable, non-instance value is never
        // equal (`::foo == "foo"`); an instance keeps its own `equals`.
        const eq = if (l != .Instance and r != .Instance)
            try host.deepValueEquals(allocator, &l, &r)
        else
            false;
        const neg = bo.op == .NotEq or bo.op == .BoxedNotEq;
        if (l != .Instance and r != .Instance) return ok(.{ .Bool = if (neg) !eq else eq });
    }
    if (operatorMethod(bo.op)) |method| {
        if (l == .Instance or r == .Instance) {
            // A `fun interface` SAM wrapper has no equality of its own —
            // dispatching `equals` on it routes into the wrapped lambda.
            // Compare through the wrapper (structuralEq unwraps both
            // sides), so a memoized lambda equals its converted form no
            // matter which call boundary happened to wrap it.
            if ((bo.op == .Eq or bo.op == .BoxedEq or bo.op == .NotEq or bo.op == .BoxedNotEq) and
                (Value.samTargetOf(&l) != null or Value.samTargetOf(&r) != null))
            {
                const eqv = Value.structuralEq(&l, &r);
                const bv = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eqv else eqv;
                return ok(.{ .Bool = bv });
            }
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
                                .err => |e2| return errResult(e2),
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
                            return errResult(e);
                        }
                    },
                    else => return errResult(e),
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
            return ok(final_val);
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
                return ok(rv);
            },
            .err => |e| return errResult(e),
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
            return ok(.{ .Bool = b });
        }
    }
    switch (try applyBinop(allocator, bo.op, &l, &r)) {
        .ok => |out| return ok(out),
        .err => |e| return errResult(e),
    }
}

/// Outlined `execInst` arm — see `execInst`.

/// The stored slot's name against the site's name. Both come from the same
/// module string pool at nearly every site, so the pointer check settles it
/// without touching the bytes — this guard runs on EVERY field read.
inline fn sameFieldName(stored: []const u8, want: []const u8) bool {
    if (stored.ptr == want.ptr and stored.len == want.len) return true;
    if (std.mem.eql(u8, stored, want)) return true;
    // A scoped `$sgetter$<owner>\u{1f}<prop>` site stores its slot under the
    // bare property name; the separator-guarded suffix keeps it exact.
    return std.mem.startsWith(u8, want, "$sgetter$") and
        want.len > stored.len and
        std.mem.endsWith(u8, want, stored) and
        want[want.len - stored.len - 1] == '\u{1f}';
}

/// A field-read site that sees more than one receiver class re-asked the
/// host's (class, name) memo on every read, which interns the name and
/// probes a hash map. Remember the answer per (site, class) instead: the
/// route is a pure function of that pair.
pub var cm_calls: u64 = 0;
pub var cm_args_ns: u64 = 0;
pub var cm_prep_ns: u64 = 0;
pub var cm_replay_ns: u64 = 0;
pub var cm_pre_ns: u64 = 0;
pub var cm_probe_ns: u64 = 0;
/// Dispatch-phase nanoseconds, counted only under `KLIO_FRAME_COUNT`. Only
/// phases that RETURN before the callee runs are timed: a timer around a
/// whole dispatch arm would bill the callee's own execution to dispatch,
/// which is how a 63ns resolution first read as 590ns.
pub fn armNow() u64 {
    return gfNow();
}
pub fn armIsOn() bool {
    return frame_count_on;
}
pub var gf_mono: u64 = 0;
pub var gf_getter_ns: u64 = 0;
pub var gf_slow_ns: u64 = 0;

/// Monotonic nanoseconds for the field-read attribution buckets. Read only
/// when `KLIO_FRAME_COUNT` is on, so the clock never prices a normal run.
inline fn gfNow() u64 {
    if (!frame_count_on) return 0;
    return @intCast(runtime.clockMonotonicNanos());
}
var gf_slow_census_state: u8 = 0;
var gf_slow_census_val: bool = false;
/// `KLIO_GF_SLOW_CENSUS=1`: one line per field read that reaches the ladder.
fn gfSlowCensusOn() bool {
    if (gf_slow_census_state == 0) {
        gf_slow_census_val = runtime.envOnce("KLIO_GF_SLOW_CENSUS") != null;
        gf_slow_census_state = 1;
    }
    return gf_slow_census_val;
}

pub var gf_getter: u64 = 0;
pub var gf_poly: u64 = 0;
pub var gf_slow: u64 = 0;

const POLY_FIELD_SLOTS: usize = 1 << 14;
const PolyFieldEnt = struct { key: u64 = 0, route: u64 = 0 };
threadlocal var poly_field_cache: [POLY_FIELD_SLOTS]PolyFieldEnt = @splat(.{});

inline fn polyFieldKey(site: usize, cls: u64) u64 {
    const k = (@as(u64, site) *% 0x9E3779B97F4A7C15) ^ (cls *% 0xC2B2AE3D27D4EB4F);
    return k | 1;
}

fn polyFieldRoute(comptime H: type, host: *H, site: usize, cls: u64, recv: *const Value, name: []const u8) ?u64 {
    // The host's own (class, name) memo is generation-guarded; this cache
    // mirrors it, so the generation belongs in the key.
    const gen: u64 = if (comptime @hasDecl(H, "dispatchCacheGen")) H.dispatchCacheGen() else 0;
    const key = polyFieldKey(site, cls ^ (gen *% 0x51_7C_C1_B7_27_22_0A_95));
    const slot = &poly_field_cache[@as(usize, @intCast(key >> 17)) & (POLY_FIELD_SLOTS - 1)];
    if (slot.key == key) return if (slot.route == 0) null else slot.route;
    const r = host.fieldSiteRoute(recv, name);
    const route: u64 = if (r) |rr| (if (rr.cls == cls) rr.route else 0) else 0;
    slot.key = key;
    slot.route = route;
    return if (route == 0) null else route;
}

noinline fn execArmGetField(comptime H: type, allocator: Allocator, frame: *Frame, gf: anytype, host: *H) Allocator.Error!Step {
    if (frame_count_on) gf_slow += 1;
    const recv = frame.read(gf.receiver);
    if (gfTraceWant()) |w0| {
        if (constStr(frame.module, gf.field)) |fname| {
            if (std.mem.indexOf(u8, fname, w0) != null) {
                const rn: []const u8 = if (recv == .Instance) blk: {
                    const g = recv.Instance.borrow();
                    const cg = g.get().class.borrow();
                    const n = cg.get().name;
                    cg.deinit();
                    g.deinit();
                    break :blk n;
                } else @tagName(recv);
                std.debug.print("[gfarm] field={s} recv={s} in={s}\n", .{ fname, rn, frame.func.name });
            }
        }
    }
    const name = constStr(frame.module, gf.field) orelse
        return raiseStep(frame, .{ .Type = "GetField: name not a string const" });
    if (try builtinFieldFast(H, host, allocator, &recv, name)) |bv| {
        try frame.write(gf.dst, bv);
        return .cont;
    }
    // A bare class name in value position resolves through the per-class
    // companion memo, and any NON-class receiver of the sentinel is an
    // identity read (the host arm returns it unchanged); the site-claim
    // machinery below never claims these, so without this arm every read
    // paid the host round-trip (718k sentinel reads in one recompose
    // test, most of them instance identities).
    if (std.mem.eql(u8, name, "<class-companion-or-self>")) {
        if (recv == .Class) {
            const g = recv.Class.borrow();
            defer g.deinit();
            switch (g.get().companion_read_state.load(.acquire)) {
                1 => {
                    recv.retain();
                    try frame.write(gf.dst, recv);
                    return .cont;
                },
                2 => {
                    const v = g.get().companion_read_value;
                    v.retain();
                    try frame.write(gf.dst, v);
                    return .cont;
                },
                else => {},
            }
        } else {
            recv.retain();
            try frame.write(gf.dst, recv);
            return .cont;
        }
    }
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
    // Site memo: serve a stored-slot read or a class getter directly when
    // the receiver's class is the one that claimed this site. The slot
    // read re-verifies by name and declines the lateinit/delegate shapes,
    // exactly as the (class, name) memo it mirrors.
    if (comptime @hasDecl(H, "fieldSiteRoute")) {
        if (recv == .Instance) {
            const w0 = @atomicLoad(u64, @constCast(&gf.site_cls), .acquire);
            var site_mismatch = false;
            if (w0 > 1) fast: {
                var getter_fid: u64 = 0;
                {
                    const g = recv.Instance.borrow();
                    defer g.deinit();
                    const b = g.get();
                    if (w0 != @as(u64, @intCast(b.class.identity()))) {
                        site_mismatch = true;
                        break :fast;
                    }
                    const route = @atomicLoad(u64, @constCast(&gf.site_route), .acquire);
                    if (route == 0) break :fast;
                    if (route & 3 == 1) {
                        const idx: usize = @intCast(route >> 2);
                        if (idx >= b.fields.items.len) break :fast;
                        const f = &b.fields.items[idx];
                        // A recorded LAYOUT match proves the index names this
                        // property; only a drifted layout (dynamic define)
                        // pays the name re-verify. The claim key stays the
                        // CLASS — two classes can share a layout while
                        // routing the same name differently.
                        if (@atomicLoad(u64, @constCast(&gf.site_shape), .monotonic) != b.shapeOf() and
                            !sameFieldName(f.name, name)) break :fast;
                        const v = f.value;
                        if (v == .Delegate) break :fast;
                        if (frame_count_on) gf_mono += 1;
                        // A stored slot holding NULL is a plain null unless the
                        // property is an unset `lateinit`, whose read must
                        // throw. Declining every null sent the commonest field
                        // shape there is — an optional link (`next`) — down the
                        // slow ladder on every read.
                        if (v == .Null) {
                            if (comptime !@hasDecl(H, "storedNullServable")) break :fast;
                            if (!nullSiteOk(H, host, &recv, name, @constCast(&gf.null_ok))) break :fast;
                        }
                        v.retain();
                        if (pushed_enclosing) popEnclosing();
                        try frame.write(gf.dst, v);
                        return .cont;
                    }
                    if (route & 3 == 2) getter_fid = route >> 2;
                    if (route & 3 == 3) {
                        if (serveOuterSlotRoute(&recv, name, route)) |v| {
                            if (pushed_enclosing) popEnclosing();
                            try frame.write(gf.dst, v);
                            return .cont;
                        }
                        break :fast;
                    }
                }
                if (getter_fid != 0) {
                    if (frame_count_on) gf_getter += 1;
                    const t0 = gfNow();
                    defer gf_getter_ns +%= gfNow() -% t0;
                    const got_g = host.runFieldGetter(allocator, @enumFromInt(getter_fid), recv);
                    if (pushed_enclosing) popEnclosing();
                    switch (try got_g) {
                        .ok => |v| {
                            v.retain();
                            try frame.write(gf.dst, v);
                            return .cont;
                        },
                        .err => |e| return raiseStep(frame, e),
                    }
                }
            }
            // A polymorphic site: the mono-class claim belongs to a
            // different receiver class (an iterator hierarchy sharing one
            // base-class read site). Serve this class from its own
            // (class, name) memo route — one probe instead of the slow
            // ladder — leaving the site's claim untouched.
            if (site_mismatch) poly: {
                const cls_now: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(recv.Instance));
                const r: struct { route: u64 } = .{
                    .route = polyFieldRoute(H, host, @intFromPtr(gf), cls_now, &recv, name) orelse break :poly,
                };
                if (r.route & 3 == 1) {
                    const idx: usize = @intCast(r.route >> 2);
                    const g = recv.Instance.borrow();
                    defer g.deinit();
                    const b = g.get();
                    if (idx >= b.fields.items.len) break :poly;
                    const f = &b.fields.items[idx];
                    if (!sameFieldName(f.name, name)) break :poly;
                    const v = f.value;
                    if (v == .Null or v == .Delegate) break :poly;
                    if (frame_count_on) gf_poly += 1;
                    v.retain();
                    if (pushed_enclosing) popEnclosing();
                    try frame.write(gf.dst, v);
                    return .cont;
                }
                if (r.route & 3 == 2) {
                    const got_g = host.runFieldGetter(allocator, @enumFromInt(r.route >> 2), recv);
                    if (pushed_enclosing) popEnclosing();
                    switch (try got_g) {
                        .ok => |v| {
                            v.retain();
                            try frame.write(gf.dst, v);
                            return .cont;
                        },
                        .err => |e| return raiseStep(frame, e),
                    }
                }
                if (r.route & 3 == 3) {
                    if (serveOuterSlotRoute(&recv, name, r.route)) |v| {
                        if (pushed_enclosing) popEnclosing();
                        try frame.write(gf.dst, v);
                        return .cont;
                    }
                }
            }
            if (gfSlowCensusOn()) {
                const cn: []const u8 = if (recv == .Instance) blk: {
                    const g = recv.Instance.borrow();
                    defer g.deinit();
                    const cg = g.get().class.borrow();
                    defer cg.deinit();
                    break :blk cg.get().name;
                } else @tagName(recv);
                std.debug.print("[gf-slow] {s}.{s}\n", .{ cn, name });
            }
        }
    }
    runtime.prof.opRoute(14);
    gfStatsBump(&recv, name);
    const t_slow = gfNow();
    const got = host.getField(allocator, &recv, name);
    gf_slow_ns +%= gfNow() -% t_slow;
    if (pushed_enclosing) popEnclosing();
    switch (try got) {
        // host.getField returns a borrowed field value; the register owns its ref.
        .ok => |v| {
            v.retain();
            if (comptime @hasDecl(H, "fieldSiteRoute")) {
                if (recv == .Instance and @atomicLoad(u64, @constCast(&gf.site_cls), .monotonic) == 0) {
                    // Claim only once a route exists. The (class, name) memo
                    // fills lazily — and not at all while the dispatch
                    // universe is still unstable — so a no-route first read
                    // must leave the site unclaimed for a later read to
                    // retry, or a warmup-executed hot site is pinned to the
                    // slow ladder for the whole run.
                    if (host.fieldSiteRoute(&recv, name)) |r| {
                        // For a stored route, bind (shape, index, name) under
                        // ONE borrow — the layout id recorded is exactly the
                        // one the index was verified against, so the replay's
                        // shape match can retire the per-hit verify. The
                        // CLAIM key stays the class.
                        const shp: u64 = blk: {
                            const g2 = recv.Instance.borrow();
                            defer g2.deinit();
                            const b2 = g2.get();
                            if (r.route & 3 != 1) break :blk 0;
                            const idx2: usize = @intCast(r.route >> 2);
                            if (idx2 >= b2.fields.items.len) break :blk 0;
                            if (!sameFieldName(b2.fields.items[idx2].name, name)) break :blk 0;
                            const sp = b2.shapeOf();
                            break :blk if (sp > 1) sp else 0;
                        };
                        if (@cmpxchgStrong(u64, @constCast(&gf.site_cls), 0, r.cls, .acq_rel, .monotonic) == null) {
                            if (shp != 0) @atomicStore(u64, @constCast(&gf.site_shape), shp, .monotonic);
                            if (r.route != 0) @atomicStore(u64, @constCast(&gf.site_route), r.route, .release);
                        }
                    }
                }
            }
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
        .List => |l| l.mutable and !modCountFrozenEval(l.mod_count.get()),
        .Set => |st| st.mutable and !modCountFrozenEval(st.mod_count.get()),
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

/// A member call site that sees more than one receiver class re-ran the
/// whole resolution ladder on every call — the single claimed class in the
/// instruction only ever serves one of them. Compose's changelist walks ~40
/// `Operation` subclasses through one site, so remember the resolved target
/// per (site, class, argument signature) instead. The dispatch generation is
/// folded into the key, so a cache flush invalidates every entry at once.
const CALL_PIC_SLOTS: usize = 1 << 14;
const CallPicEnt = struct { key: u64 = 0, fid: u32 = 0 };
threadlocal var call_pic: [CALL_PIC_SLOTS]CallPicEnt = @splat(.{});

inline fn callPicKey(site: usize, cls: u64, sig: u64, gen: u64) u64 {
    var k = (@as(u64, site) *% 0x9E3779B97F4A7C15) ^ (cls *% 0xC2B2AE3D27D4EB4F);
    k ^= sig *% 0xD6E8FEB86659FD93;
    k ^= gen *% 0x517CC1B727220A95;
    return k | 1;
}

fn callPicGet(site: usize, cls: u64, sig: u64, gen: u64) ?u32 {
    const key = callPicKey(site, cls, sig, gen);
    const e = &call_pic[@as(usize, @intCast(key >> 17)) & (CALL_PIC_SLOTS - 1)];
    if (e.key != key) return null;
    return e.fid;
}

fn callPicPut(site: usize, cls: u64, sig: u64, gen: u64, fid: u32) void {
    const key = callPicKey(site, cls, sig, gen);
    const e = &call_pic[@as(usize, @intCast(key >> 17)) & (CALL_PIC_SLOTS - 1)];
    e.key = key;
    e.fid = fid;
}

fn tryLeafMember(comptime H: type, allocator: Allocator, frame: *Frame, recv: Value, fid: ir.FuncId, args: []const Value, host: *H) Allocator.Error!?LeafOutcome {
    if (recv == .Null) return null;
    const lf = frame.module.funcById(fid) orelse return null;
    if (args.len + 1 > 8) return null;
    var all: [8]Value = undefined;
    all[0] = recv;
    for (args, 0..) |a, i| all[i + 1] = a;
    return tryLeafValues(H, allocator, frame.module, lf, all[0 .. args.len + 1], host, null);
}

noinline fn execArmCallMember(comptime H: type, allocator: Allocator, frame: *Frame, cm: anytype, host: *H) Allocator.Error!Step {
    const cm_t0 = gfNow();
    defer if (frame_count_on) {
        cm_calls += 1;
    };
    const recv = frame.read(cm.receiver);
    if (cmTraceWant()) |w0| {
        const want = w0;
        if (constStr(frame.module, cm.name)) |nm| {
            if (std.mem.eql(u8, nm, want)) {
                const chain = evtls.active_chain;
                const drecv_tn: []const u8 = if (cm.dispatch_receiver) |reg| blk: {
                    const dv = frame.read(reg);
                    if (dv == .Instance) {
                        const g = dv.Instance.borrow();
                        const cg = g.get().class.borrow();
                        const n = cg.get().name;
                        cg.deinit();
                        g.deinit();
                        break :blk n;
                    }
                    break :blk @tagName(dv);
                } else "-";
                std.debug.print("[cmarm] name={s} in={s} resolved={} dispatch={s} chain_len={d} chain_base={d}\n", .{
                    nm,
                    frame.func.name,
                    cm.resolved != null,
                    drecv_tn,
                    if (chain) |c| c.items.len else 0,
                    evtls.active_chain_base,
                });
                if (chain) |c| {
                    for (c.items, 0..) |e, i| {
                        const tn: []const u8 = if (e.v == .Instance) blk: {
                            const g = e.v.Instance.borrow();
                            const cg = g.get().class.borrow();
                            const n = cg.get().name;
                            cg.deinit();
                            g.deinit();
                            break :blk n;
                        } else @tagName(e.v);
                        std.debug.print("[cmarm]   [{d}] kind={s} {s}\n", .{ i, @tagName(e.kind), tn });
                    }
                }
            }
        }
    }
    // Complete lowering evidence selected this declaration. Execute that
    // identity before representation-specific member fast paths; an invalid
    // identity is an image/link error, never permission to reinterpret the
    // call through name-based dispatch.
    if (cm.resolved) |fid| {
        dispatchBump(.call_member_resolved);
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
            // Scalar-replay leaf on the lowering-resolved member: the
            // receiver rides as param 0 (opaque genre when non-scalar); a
            // bail falls through to the ordinary invokers, which re-run
            // the pure body exactly.
            if (argNamesAllNull(cm.arg_names) and ra.len + 1 <= 8 and
                cm.dispatch_receiver == null and recv != .Null) leaf: {
                const lf = frame.module.funcById(fid) orelse break :leaf;
                var all: [8]Value = undefined;
                all[0] = recv;
                for (ra, 0..) |a, i| all[i + 1] = a;
                if (try tryLeafValues(H, allocator, frame.module, lf, all[0 .. ra.len + 1], host, null)) |lo| switch (lo) {
                    .val => |v| {
                        try frame.write(cm.dst, v);
                        return .cont;
                    },
                    .raise => |e| return raiseStep(frame, e),
                };
            }
            // A lowering-resolved plain member at the fully-applied no-vararg
            // shape runs as a pushed activation; member extensions (which
            // seed the dispatch receiver) and every padded/vararg shape keep
            // the recursive invoker.
            if (comptime @hasDecl(H, "prepareResolvedFlatCall")) {
                if (flatEnabled() and vcallFlatEnabled() and argNamesAllNull(cm.arg_names)) {
                    if (try host.prepareResolvedFlatCall(allocator, &recv, fid, ra)) |prep0| {
                        dispatchBump(.resolved_flat_prepare);
                        var prep = prep0;
                        prep.dst = cm.dst;
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            const dispatch_ptr: ?*const Value = if (dispatch_recv) |*value|
                value
            else
                null;
            const names_resolved = try resolveArgNames(allocator, frame.module, cm.arg_names);
            defer allocator.free(names_resolved);
            switch (try host.invokeResolvedMember(
                allocator,
                dispatch_ptr,
                &recv,
                fid,
                ra,
                names_resolved,
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
    dispatchBump(.call_member_virtual);
    if (fastSubscript(allocator, frame, cm)) |rv| {
        dispatchBump(.member_fast_subscript);
        try frame.write(cm.dst, rv);
        return .cont;
    }
    if (primitiveMemberFast(frame, cm)) |rv| {
        dispatchBump(.member_prim_op);
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
                dispatchBump(.member_range_iter);
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
    runtime.prof.opRoute(0);
    const cm_args_t0 = gfNow();
    const arg_values = try readArgRun(allocator, frame, cm.args, cm.n_args);
    if (frame_count_on) cm_args_ns +%= gfNow() -% cm_args_t0;
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cm.arg_names);
    defer freeArgNames(allocator, names);
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
    // Site memo replay: the claimed (class, arg-signature) pair serves its
    // recorded target without the string-keyed cache probe. The signature is
    // the same strict fold the method cache keys under, so the replay can
    // never serve an overload that cache would have discriminated.
    if (frame_count_on) cm_pre_ns +%= gfNow() -% cm_t0;
    if (comptime @hasDecl(H, "memberSiteSig") and @hasDecl(H, "prepareMemberFlatFromFid")) {
        if (flatEnabled() and memberSiteEnabled() and recv == .Instance and argNamesAllNull(cm.arg_names)) {
            const w0 = @atomicLoad(u64, @constCast(&cm.site_cls), .acquire);
            if (w0 > 1) site: {
                const cls_now: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(recv.Instance));
                if (w0 != cls_now) {
                    // A polymorphic site: this class has its own remembered
                    // target, so it never re-runs the ladder either.
                    const gen: u64 = if (comptime @hasDecl(H, "dispatchCacheGen")) H.dispatchCacheGen() else 0;
                    const sig_p = host.memberSiteSig(arg_values) orelse break :site;
                    const fid_p = callPicGet(@intFromPtr(cm), cls_now, sig_p, gen) orelse break :site;
                    if (try tryLeafMember(H, allocator, frame, recv, @enumFromInt(fid_p), arg_values, host)) |lo| switch (lo) {
                        .val => |v| {
                            if (pushed_enclosing) popEnclosing();
                            try frame.write(cm.dst, v);
                            return .cont;
                        },
                        .raise => |e| {
                            if (pushed_enclosing) popEnclosing();
                            return raiseStep(frame, e);
                        },
                    };
                    if (try host.prepareMemberFlatFromFid(allocator, &recv, name_str, arg_values, @enumFromInt(fid_p))) |prep0| {
                        dispatchBump(.member_site_flat);
                        var prep = prep0;
                        prep.dst = cm.dst;
                        prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                    break :site;
                }
                const route = @atomicLoad(u64, @constCast(&cm.site_route), .acquire);
                if (route == 0) break :site;
                const sig_now = host.memberSiteSig(arg_values) orelse break :site;
                if (sig_now != @atomicLoad(u64, @constCast(&cm.site_sig), .monotonic)) break :site;
                // Route bit0 = 1 carries a flat-call FuncId; bit0 = 0
                // carries a host-serve kind (the CHAMP builder ops) that
                // answers without any call machinery.
                if (route & 1 == 0) {
                    if (comptime @hasDecl(H, "hostMemberServeKind")) {
                        if (try host.hostMemberServeKind(allocator, @intCast(route >> 1), &recv, arg_values)) |served| {
                            dispatchBump(.member_site_flat);
                            if (pushed_enclosing) popEnclosing();
                            try frame.write(cm.dst, served);
                            return .cont;
                        }
                    }
                    break :site;
                }
                if (try tryLeafMember(H, allocator, frame, recv, @enumFromInt(@as(u32, @intCast(route >> 1))), arg_values, host)) |lo| switch (lo) {
                    .val => |v| {
                        if (pushed_enclosing) popEnclosing();
                        try frame.write(cm.dst, v);
                        return .cont;
                    },
                    .raise => |e| {
                        if (pushed_enclosing) popEnclosing();
                        return raiseStep(frame, e);
                    },
                };
                if (try host.prepareMemberFlatFromFid(allocator, &recv, name_str, arg_values, @enumFromInt(@as(u32, @intCast(route >> 1))))) |prep0| {
                    dispatchBump(.member_site_flat);
                    var prep = prep0;
                    prep.dst = cm.dst;
                    prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                    frame.flat_call = prep;
                    return .flat_call;
                }
            }
        }
    }
    // Flat member dispatch: a previously-resolved user method (or cached
    // top-level extension) at the fully-applied no-vararg shape runs as a
    // pushed activation. The host consults the same caches the recursive
    // ladder's entry consults; anything else falls through to the ladder.
    if (comptime @hasDecl(H, "prepareMemberFlatCall")) {
        if (flatEnabled()) {
            runtime.prof.opRoute(1);
            const cm_prep_t0 = gfNow();
            defer if (frame_count_on) {
                cm_prep_ns +%= gfNow() -% cm_prep_t0;
            };
            const prep_opt: ?FlatCallReq = if (argNamesAllNull(cm.arg_names))
                try host.prepareMemberFlatCall(allocator, &recv, name_str, arg_values, static_recv, declared_recv, true)
            else if (comptime @hasDecl(H, "prepareMemberFlatCallNamed"))
                // A NAMED call whose binding permutation is already known
                // replays it into declaration order and runs flat, exactly
                // as the positional form does.
                try host.prepareMemberFlatCallNamed(allocator, &recv, name_str, arg_values, names, static_recv, declared_recv)
            else
                null;
            if (prep_opt) |prep0| {
                dispatchBump(.member_flat_prepare);
                var prep = prep0;
                prep.dst = cm.dst;
                prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                // Claim the site memo for the resolved target, keyed by the
                // receiver class and the strict argument signature. Claimed
                // only once resolution is stable (the same gate the host's
                // own caches fill under) and only for the positional form.
                if (comptime @hasDecl(H, "memberSiteSig")) {
                    if (memberSiteEnabled() and recv == .Instance and argNamesAllNull(cm.arg_names) and
                        dispatchCacheStable())
                    {
                        if (host.memberSiteSig(arg_values)) |sig| {
                            const cls: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(recv.Instance));
                            if (cls > 1 and @cmpxchgStrong(u64, @constCast(&cm.site_cls), 0, cls, .acq_rel, .monotonic) == null) {
                                @atomicStore(u64, @constCast(&cm.site_sig), sig, .monotonic);
                                @atomicStore(u64, @constCast(&cm.site_route), (@as(u64, prep.func.id.int()) << 1) | 1, .release);
                            } else if (cls > 1) {
                                // The instruction already belongs to another
                                // class: remember this one in the per-site
                                // cache so it stops re-resolving too.
                                const gen: u64 = if (comptime @hasDecl(H, "dispatchCacheGen")) H.dispatchCacheGen() else 0;
                                callPicPut(@intFromPtr(cm), cls, sig, gen, prep.func.id.int());
                            }
                        }
                    }
                }
                frame.flat_call = prep;
                runtime.prof.opRoute(5);
                return .flat_call;
            }
        }
    }
    // Host member serves (the CHAMP builder ops) answer here, ahead of the
    // ladder entry, and claim the site memo with a host-kind route so later
    // executions skip the flat-prepare decline walk entirely.
    if (comptime @hasDecl(H, "hostMemberServeProbe")) {
        if (recv == .Instance and argNamesAllNull(cm.arg_names)) {
            if (try host.hostMemberServeProbe(allocator, &recv, name_str, arg_values)) |hit| {
                if (comptime @hasDecl(H, "memberSiteSig")) {
                    if (memberSiteEnabled() and dispatchCacheStable() and
                        @atomicLoad(u64, @constCast(&cm.site_cls), .monotonic) == 0)
                    {
                        if (host.memberSiteSig(arg_values)) |sig| {
                            const cls: u64 = blk: {
                                const g = recv.Instance.borrow();
                                defer g.deinit();
                                break :blk @intCast(g.get().class.identity());
                            };
                            if (cls > 1 and @cmpxchgStrong(u64, @constCast(&cm.site_cls), 0, cls, .acq_rel, .monotonic) == null) {
                                @atomicStore(u64, @constCast(&cm.site_sig), sig, .monotonic);
                                @atomicStore(u64, @constCast(&cm.site_route), @as(u64, hit.kind) << 1, .release);
                            }
                        }
                    }
                }
                if (pushed_enclosing) popEnclosing();
                try frame.write(cm.dst, hit.val);
                return .cont;
            }
        }
    }
    dispatchBump(.member_ladder);
    ladderStatsBump(&recv, name_str, frame.func.name);
    runtime.prof.opRoute(2);
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

fn valueTruthy(allocator: Allocator, v: *const Value) Allocator.Error!union(enum) { ok: bool, err: EvalError } {
    switch (v.*) {
        .Bool => |b| return .{ .ok = b },
        else => {
            const s = v.display(allocator) catch "?";
            // Name the frame and its function so a wrong-value branch is
            // attributable without a debugger: the value alone cannot say
            // WHICH branch mis-wired.
            const fname: []const u8 = if (currentFrameFunc()) |cf| cf.fqn else "?";
            const fid: u32 = if (currentFrameFunc()) |cf| cf.id.int() else 0;
            const sp: ?span.Span = if (evtls.frame_chain) |fr| fr.cur_span else null;
            const msg = if (sp) |p2|
                try std.fmt.allocPrint(allocator, "non-bool in branch: {s} (in {s}#{d} at f{d}:{d})", .{ s, fname, fid, p2.file.int(), p2.start })
            else
                try std.fmt.allocPrint(allocator, "non-bool in branch: {s} (in {s}#{d})", .{ s, fname, fid });
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
    // Instances dispatch their `toString()` override; List/Set/Map and the
    // tuple shapes dispatch too so their element `toString()` fires (the fast
    // `renderValue`/`display` formatter prints `ClassName@id` for a user
    // element), and `Result` so `Failure($exception)` interpolates the
    // payload's override. Arrays keep Kotlin's identity `toString`, so they
    // are not included.
    if (v.* == .Instance or v.* == .List or v.* == .Set or v.* == .Map or v.* == .Result or
        v.* == .Pair or v.* == .Triple)
    {
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
    return .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, "kotlin.ArithmeticException"),
        .message = .from(try runtime.strInit(allocator, msg)),
        .cause = null,
    }) };
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
            if (l.* == .Long and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = divTruncI64(l.Long, @as(i64, r.Int)) });
            }
            if (l.* == .Int and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = divTruncI64(@as(i64, l.Int), r.Long) });
            }
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
            if (l.* == .Long and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = remTruncI64(l.Long, @as(i64, r.Int)) });
            }
            if (l.* == .Int and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = remTruncI64(@as(i64, l.Int), r.Long) });
            }
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
        .And, .Or, .Xor, .Shl, .Shr, .UShr => {
            if (op == .And and l.* == .Bool and r.* == .Bool) return ok(.{ .Bool = l.Bool and r.Bool });
            if (op == .Or and l.* == .Bool and r.* == .Bool) return ok(.{ .Bool = l.Bool or r.Bool });
            if (scalarBin(op, l.*, r.*)) |v| return ok(v);
        },
        .RangeTo, .RangeUntil => {
            if (try rangeValue(allocator, op, l, r)) |v| return ok(v);
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
    dumpFrameChainForDiag();
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
fn rangeValue(allocator: Allocator, op: BinOp, l: *const Value, r: *const Value) Allocator.Error!?Value {
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
            return try Value.newRange(allocator, .{ .start = e[0], .end = e[1], .step = 1, .kind = kind });
        }
        bound -= 1;
    }
    return try Value.newRange(allocator, .{ .start = start, .end = bound, .step = 1, .kind = kind });
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
    pub fn getMemberFieldNoExt(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
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

/// The full `LoadGlobal` semantics with no frame coupling — the framed arm
/// and the fused tier both call this. The result is RETAINED for the
/// caller's register.
fn loadGlobalValue(comptime H: type, allocator: Allocator, module: *const Module, lg: anytype, host: *H) Allocator.Error!EvalResult {
    {
            const name_str = constStr(module, lg.name) orelse
                return errResult(.{ .Type = "LoadGlobal: name not a string const" });
            // A lowering-resolved identity binds that exact declaration;
            // the name string is only the unresolved-shape fallback.
            const by_id: ?Value = if (lg.func != null or lg.class != null)
                host.lookupGlobalById(allocator, lg.func, lg.class, lg.ctor_ref)
            else
                null;
            const lg_r: MaybeValueResult = if (by_id != null) .{ .ok = by_id } else try host.lookupGlobalThrowing(allocator, name_str);
            const found = switch (lg_r) {
                .ok => |maybe| maybe,
                .err => |e| return errResult(e),
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
                if (module.registry.top_level_prop_getters.get(name_str)) |getter_fid| {
                    switch (try host.callFunc(allocator, module, getter_fid, &.{})) {
                        .ok => |gv| {
                            return ok(gv);
                        },
                        .err => |e| return errResult(e),
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
                                        return ok(fv);
                                    },
                                    .err => {},
                                }
                            }
                        }
                    }
                }
                // A `$lc<fn>`-mangled LOCAL class name (`Local$lcmain`) is how
                // lowering refers to a local class, but the runtime registers
                // it under its simple declared name (`Local`). A reified
                // splice that materialized the mangled name as a global —
                // `Json.encodeToString(localValue)` -> `Local$lcmain.serializer()`
                // — resolves through the simple name.
                if (std.mem.indexOf(u8, name_str, "$lc")) |lci| {
                    const simple = name_str[0..lci];
                    if (simple.len != 0) {
                        switch (try host.lookupGlobalThrowing(allocator, simple)) {
                            .ok => |maybe| if (maybe) |lv| return ok(lv),
                            .err => {},
                        }
                    }
                }
                if (envVarSet("KLIO_UNRESOLVED_TRACE")) {
                    std.debug.print("[unresolved] `{s}`\n", .{name_str});
                }
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[lg-tail-a] name={s}\n", .{name_str});
                }
                dumpFrameChainForDiag();
                return errResult(.{ .Unbound = msg });
            } else {
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[lg-tail-b] name={s} func={?} class={?}\n", .{ name_str, if (lg.func) |f| f.int() else null, if (lg.class) |c| c.int() else null });
                }
                dumpFrameChainForDiag();
                return errResult(.{ .Unbound = msg });
            }
            v.retain();
            return ok(v);
    }
}

// ---- The fused execution tier -----------------------------------------------
//
// A body the classifier accepts runs with its registers in a per-thread
// C bank: no Frame, no register pool, no activation bookkeeping. Unlike the
// leaf tier there is NO abandon — fused bodies contain writes, so every
// admitted instruction either executes or RAISES exactly as the framed arm
// would, and classification is TRANSITIVE over statically-resolved calls so
// no framed machinery (and no suspension) can ever appear beneath a fused
// activation. `KLIO_FUSED=0` disables the tier.

pub const FUSED_MAX_REGS: usize = 128;
const FUSED_BANK_DEPTH: usize = 24;
const FUSED_MAX_BLOCKS: usize = 64;
const FUSED_MAX_INSTS: usize = 256;

threadlocal var fused_bank: [FUSED_BANK_DEPTH][FUSED_MAX_REGS]Value = undefined;
threadlocal var fused_chain: [FUSED_BANK_DEPTH]std.ArrayList(EnclosingEntry) = @splat(.empty);
threadlocal var fused_depth: usize = 0;

var fused_enabled_state: u8 = 0;
var fused_enabled_val: bool = true;
var fused_sel: ?[]const u8 = null;
/// `KLIO_FUSED=0` disables the tier; a comma list fuses ONLY those simple
/// names; a list starting with `!` fuses all BUT those — the same bisect
/// grammar as KLIO_MEMBER_INLINE.
pub fn fusedEnabled() bool {
    if (fused_enabled_state == 0) {
        const raw = runtime.envOnce("KLIO_FUSED") orelse "1";
        if (std.mem.eql(u8, raw, "0")) {
            fused_enabled_val = false;
        } else {
            fused_enabled_val = true;
            if (!std.mem.eql(u8, raw, "1")) fused_sel = raw;
        }
        fused_enabled_state = 1;
    }
    return fused_enabled_val;
}


fn fusedNameSelected(name: []const u8) bool {
    const sel = fused_sel orelse return true;
    const inverted = std.mem.startsWith(u8, sel, "!");
    var it = std.mem.splitScalar(u8, if (inverted) sel[1..] else sel, ',');
    while (it.next()) |tok| {
        if (tok.len != 0 and std.mem.eql(u8, tok, name)) return !inverted;
    }
    return inverted;
}

/// Transitive closed-world classification, memoized on the Func. A cycle
/// (mutual recursion) reads as eligible while the root classification runs
/// and settles with the root's verdict. The host is part of the verdict: a
/// body that (transitively) calls a HOST-OWNED function must not fuse —
/// `KlioContinuation.resumeWith` runs its own lowered body but calls the
/// host's `__klio_co_resume`, and the resume machinery assumes a framed
/// caller (fusing it stalled the pump).
/// fuse_state: 0 unasked, 1 FULL (every op in the fast set, callees
/// transitively full — flat and recursive seams), 2 no, 3 in progress,
/// 4 PARTIAL (structurally sound; runs fused until the first heavy op,
/// then MATERIALIZES a real frame and continues framed — recursive seam
/// only, because a flat caller cannot adopt the materialized remainder's
/// suspension).
fn fusedEligible(comptime H: type, host: *H, module: *const Module, func: *const Func) bool {
    return fusedVerdict(H, host, module, func) == 1;
}

/// Funcs THIS thread is currently classifying, so a self-recursive body's
/// own call site resolves optimistically (the fixpoint that lets fused
/// recursion classify FULL) while ANOTHER thread's in-progress marker is
/// a plain decline — handing the optimistic verdict across threads let a
/// second core run a body fused before the classifying thread had even
/// ensured its blocks were decoded (the dispatched_delay corpus panic).
threadlocal var classify_stack: [128]u32 = undefined;
threadlocal var classify_depth: usize = 0;

fn classifyingHere(fid: u32) bool {
    for (classify_stack[0..classify_depth]) |f| {
        if (f == fid) return true;
    }
    return false;
}

fn fusedVerdict(comptime H: type, host: *H, module: *const Module, func: *const Func) u8 {
    switch (func.fuse_state) {
        1, 2, 4 => return func.fuse_state,
        3 => return if (classifyingHere(func.id.int())) 1 else 2,
        else => {},
    }
    if (comptime @hasDecl(H, "funcRunsItsBody")) {
        if (!host.funcRunsItsBody(func.id)) {
            @constCast(func).fuse_state = 2;
            return 2;
        }
    }
    if (classify_depth >= classify_stack.len) return 2; // depth guard: decline, no memo
    @constCast(func).fuse_state = 3;
    classify_stack[classify_depth] = func.id.int();
    classify_depth += 1;
    const verdict = fusedClassify(H, host, module, func);
    classify_depth -= 1;
    @constCast(func).fuse_state = verdict;
    return verdict;
}

fn bareTypeVarHead(name: []const u8) bool {
    const head = std.mem.trimEnd(u8, name, "?");
    return head.len > 0 and head.len <= 2 and std.ascii.isUpper(head[0]);
}

fn fusedClassify(comptime H: type, host: *H, module: *const Module, func: *const Func) u8 {
    if (func.is_suspend or func.is_lambda) return 2;
    // A generic body's `as T` / `is T` consults the frame's reified
    // context (`typeParamCastPasses`), which the fused walker does not
    // carry — kotlinx's `systemProp<T>` silently failed its cast and the
    // DEFAULT_TIMEOUT initializer died with it. Func carries no type-param
    // list, so a parameter or return typed as a bare type variable is the
    // generic marker, and the Cast/InstanceOf ops are guarded below too.
    if (bareTypeVarHead(func.return_ty.name)) return 2;
    for (func.params) |*p| {
        if (bareTypeVarHead(p.ty.name)) return 2;
    }
    if (func.blocks.len == 0 or func.blocks.len > FUSED_MAX_BLOCKS) return 2;
    if (func.n_locals > FUSED_MAX_REGS) return 2;
    for (func.params) |*p| {
        if (p.is_vararg or p.default != null) return 2;
    }
    var heavy = false;
    var total: usize = 0;
    // How much fused progress the ENTRY block makes before its first heavy
    // op. A body whose entry hits a heavy op almost immediately gains
    // nothing from a fused prefix — materialization then pays walker entry
    // PLUS the full frame build on nearly every call (the observed
    // [fused-mat] b0:1..b0:5 family) — so it runs framed outright.
    var entry_prefix: usize = 0;
    var entry_heavy = false;
    for (func.blocks, 0..) |*b, bi| {
        if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return 2;
        total += b.insts.len;
        if (total > FUSED_MAX_INSTS) return 2;
        switch (b.terminator) {
            .Return, .Goto, .Branch, .Switch, .Throw, .Unreachable => {},
            else => return 2,
        }
        const is_entry = bi == func.entry.int();
        for (b.insts) |*inst| {
            const was_heavy = heavy;
            _ = was_heavy;
            const heavy_before = heavy;
            defer if (is_entry and !entry_heavy) {
                if (heavy != heavy_before) {
                    entry_heavy = true;
                } else switch (inst.*) {
                    .Trace => {},
                    else => entry_prefix += 1,
                }
            };
            switch (inst.*) {
                .Trace, .Const, .Move, .LoadParam, .BinOp, .Not, .GetField, .SetField,
                .Index, .IndexSet, .NotNullAssert, .MakeCell,
                .CellGet, .CellSet, .EnclosingPush, .EnclosingPop => {},
                .Cast => |ct| if (bareTypeVarHead(ct.ty.name)) return 2,
                .InstanceOf => |io| if (bareTypeVarHead(io.ty.name)) return 2,
                // Non-suspending open-world ops: a global read may run a
                // lazy initializer and a construction runs ctor bodies, but
                // neither can suspend (Kotlin forbids suspend there), so no
                // materialization is needed beneath them.
                .LoadGlobal => {},
                // Dynamic member dispatch stays framed: the recursive host
                // entries lose the flat path's site memos (fused-first
                // execution never stamps them), which measured ~5% slower
                // on the recomposition replica.
                .CallVirtual, .CallMember => heavy = true,
                .NewInstance => |ni| {
                    if (ni.arg_names.len != 0) {
                        for (ni.arg_names) |an| {
                            if (an != null) heavy = true;
                        }
                    }
                },
                .Call => |c| blk: {
                    if (c.arg_names.len != 0 or c.type_args.len != 0) {
                        heavy = true;
                        break :blk;
                    }
                    const callee = module.funcById(c.func) orelse {
                        heavy = true;
                        break :blk;
                    };
                    _ = module.ensureFuncBody(@constCast(callee));
                    if (callee.params.len != c.n_args) {
                        heavy = true;
                        break :blk;
                    }
                    if (fusedVerdict(H, host, module, callee) != 1) heavy = true;
                },
                // A SuspendResumePoint marks a resumable body: never fused,
                // never materialized mid-flight.
                .SuspendResumePoint => return 2,
                else => heavy = true,
            }
        }
    }
    if (heavy and entry_heavy and entry_prefix < fused_min_prefix) return 2;
    return if (heavy) 4 else 1;
}


/// A heavy body whose fusable entry prefix is shorter than this runs
/// framed: the prefix win cannot pay for the materialize handoff.
const fused_min_prefix: usize = 24;

const FusedFail = error{ Raise, Materialize } || Allocator.Error;
threadlocal var fused_err: EvalError = undefined;

inline fn fusedRaise(e: EvalError) FusedFail {
    fused_err = e;
    return error.Raise;
}

/// The tier's entry: null when the body is ineligible (caller proceeds to
/// the framed path), an EvalResult otherwise — `.ok` or a genuinely raised
/// `.err`, never an abandon.
pub fn fusedExec(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
) Allocator.Error!?EvalResult {
    return fusedExecOpt(H, allocator, module, func, args, host, false);
}

/// `allow_materialize`: a PARTIAL body runs its fused prefix and then
/// builds the real Frame and continues framed — only the recursive seam
/// may allow it (a flat caller cannot adopt the remainder's suspension,
/// and a fused .Call parent must never sit above a parkable callee).
pub fn fusedExecOpt(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    allow_materialize: bool,
) Allocator.Error!?EvalResult {
    if (comptime !@hasDecl(H, "fieldSiteRoute")) return null;
    if (!fusedEnabled()) return null;
    // A symbol the host settled onto a native binding or a redirect does
    // not run its lowered body — fusing it executes a stub the host never
    // intended to run. The coroutine bridge (`__klio_co_resume`,
    // `KlioContinuation.resumeWith`) is exactly this shape, and fusing it
    // leaked the pump's per-resume state until the RSS cap fired.
    if (!fusedNameSelected(if (func.fqn.len != 0) func.fqn else func.name)) return null;
    const verdict = fusedVerdict(H, host, module, func);
    if (verdict == 2) return null;
    if (verdict == 4 and !allow_materialize) return null;
    if (args.len != func.params.len) return null;
    // An INNER-class member's bare reads reach the enclosing instance
    // (`hasNext(): Boolean = index < size` reads the OUTER list's size),
    // context the walker does not model — the framed path resolves it
    // through the enclosing chain. A receiver carrying an outer declines.
    if (args.len > 0 and args[0] == .Instance) {
        const g = args[0].Instance.borrow();
        const has_outer = g.get().outer != null;
        g.deinit();
        if (has_outer) return null;
    }
    if (fused_depth >= FUSED_BANK_DEPTH) return null;
    // Function-tier handshake: a hot fully-fusable body yields to the framed
    // path so the JIT can count and compile it (the walker otherwise starves
    // the tier — a fused body never opens a frame).
    if (jit_loop.fusedShouldYieldToFuncTier(func)) return null;
    // A memoized verdict travels between threads without ordering against
    // the body's lazy decode; re-ensure here (idempotent, serialized) so
    // the walker never indexes an empty block table.
    if (func.blocks.len == 0 and !module.ensureFuncBody(@constCast(func))) return null;
    if (frame_count_on) frame_count_total += 1;
    if (runtime.envOnce("KLIO_FUSED_TRACE") != null) {
        std.debug.print("[fused] {s}\n", .{if (func.fqn.len != 0) func.fqn else func.name});
    }
    return try fusedRun(H, allocator, module, func, args, host);
}

fn fusedRun(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args_in: []const Value,
    host: *H,
) Allocator.Error!EvalResult {
    const reclaim = runtime.reclaimEnabled();
    var eff_args = args_in;
    {
        const plan = coercePlanFor(module, func);
        if (plan & 6 != 0 and args_in.len <= ir.LEAF_MAX_REGS) {
            const coerce_buf: []Value = coerce_bank[fused_depth % LEAF_BANK_DEPTH][0..args_in.len];
            @memcpy(coerce_buf, args_in);
            if (plan & 2 != 0) coerceIntArgsToLong(func, coerce_buf);
            if (plan & 4 != 0) coerceGenericIntPeersToLong(module, func, coerce_buf);
            eff_args = coerce_buf;
        }
    }
    const nlive: usize = @min(@as(usize, func.n_locals), FUSED_MAX_REGS);
    const regs: []Value = fused_bank[fused_depth][0..nlive];
    fused_depth += 1;
    defer fused_depth -= 1;
    // Unlike the leaf bank there is no def-before-use proof here: fill the
    // bank so the register file is always well-formed, and pin it for the
    // collector for the whole run (fused bodies allocate and call).
    for (regs) |*v| v.* = .Unit;
    fused_marks[fused_depth - 1] = .{
        .func = func,
        .mod = module,
        .head = evtls.frame_chain,
        .recv = if (func.has_receiver_param and eff_args.len > 0 and eff_args[0] == .Instance) eff_args[0] else null,
    };
    if (runtime.gc.gc_enabled) gcInstallFrameRoot();
    const pin_mark = runtime.keepaliveMark();
    runtime.keepalivePushSlice(regs);
    // The args slice is NOT otherwise a root: a dispatch that assembled it
    // in a scratch buffer (a defaulted call's argv) may hold the only
    // reference to a value in it, and unlike a framed call — which moves
    // argv into rooted params before any safe point — the fused body runs
    // through safe points with argv still in the scratch buffer.
    runtime.keepalivePushSlice(eff_args);
    defer runtime.keepaliveRestore(pin_mark);
    defer if (reclaim) {
        for (regs) |*v| v.release(allocator);
    };
    // The fused body OWNS an enclosing chain exactly as a frame does
    // (seeded from the caller's in-flight pushes plus its own receiver,
    // then activated). Without this, a body invoked with the chain
    // DETACHED (host trampolines null it) lost its own subject pushes —
    // `apply { add(...) }`'s subject silently vanished and the framed
    // remainder resolved `add` against the test instance.
    const chain = &fused_chain[fused_depth - 1];
    chain.clearRetainingCapacity();
    if (evtls.active_chain) |caller| {
        const base = @min(evtls.active_chain_base, caller.items.len);
        for (caller.items[base..]) |e| {
            if (e.kind == .access) continue;
            try chain.append(chainAllocator(), e);
        }
    }
    if (exec_call.ownReceiverEntry(func, eff_args)) |own| {
        const dup = chain.items.len > 0 and sameReceiver(chain.items[chain.items.len - 1].v, own.v);
        if (!dup) try chain.append(chainAllocator(), own);
    }
    const prev_chain = evtls.active_chain;
    const prev_chain_base = evtls.active_chain_base;
    evtls.active_chain = chain;
    evtls.active_chain_base = chain.items.len;
    defer {
        evtls.active_chain = prev_chain;
        evtls.active_chain_base = prev_chain_base;
    }
    var pushed_enclosing: usize = 0;
    defer while (pushed_enclosing > 0) : (pushed_enclosing -= 1) popEnclosing();

    // KLIO_FN_PROF: a fused body is the executing function — without this
    // stamp its samples billed to the last FRAMED caller.
    const fn_prof_prev = runtime.prof.current_fn;
    if (runtime.prof.fn_prof_active) runtime.prof.current_fn = func.id.int();
    defer if (runtime.prof.fn_prof_active) {
        runtime.prof.current_fn = fn_prof_prev;
    };

    var cur: BlockId = func.entry;
    walk: while (true) {
        // The framed loop's GC safe point, once per block, UNCONDITIONAL:
        // `pending()` never sees another thread's stop_flag, so gating on it
        // let a fused spin-loop (JobSupport's state machine waiting on a
        // sibling thread) skip the stop-the-world rendezvous — the collector
        // waited on this thread while this thread waited on a parked mutator.
        // `safePoint()` itself parks on a raised stop and no-ops otherwise;
        // a fused-only hot loop also needs it so allocations ever collect
        // (DeepRecursiveTest grew past the RSS cap). The bank is pinned, so
        // stopping here is root-exact.
        if (runtime.gc.gc_enabled) runtime.gc.safePoint();
        const blk = &func.blocks[cur.int()];
        for (blk.insts, 0..) |*inst, idx| {
            fusedInst(H, allocator, module, func, eff_args, host, inst, regs, reclaim, &pushed_enclosing) catch |e| switch (e) {
                error.Raise => return .{ .err = fused_err },
                // A heavy op: build the real Frame from the bank and run
                // the remainder framed, starting AT this instruction (no
                // side effect of it has run). The framed machinery then
                // owns the heavy op — including any suspension beneath it.
                error.Materialize => {
                    const moved_pushes = pushed_enclosing;
                    pushed_enclosing = 0;
                    return try fusedMaterializeAndRun(
                        H,
                        allocator,
                        module,
                        func,
                        args_in,
                        regs,
                        cur,
                        idx,
                        moved_pushes,
                        host,
                    );
                },
                else => |oe| return oe,
            };
        }
        switch (blk.terminator) {
            .Goto => |next| cur = next,
            .Branch => |br| {
                const v = fusedRead(regs, br.cond);
                switch (try valueTruthy(allocator, &v)) {
                    .ok => |b| cur = if (b) br.t else br.f,
                    .err => |e| return .{ .err = e },
                }
            },
            .Switch => |sw| {
                const v = fusedRead(regs, sw.reg);
                var next = sw.default;
                for (sw.arms) |arm| {
                    if (constMatches(module, arm.key, &v)) {
                        next = arm.target;
                        break;
                    }
                }
                cur = next;
            },
            .Return => |maybe_r| {
                const v = if (maybe_r) |r| fusedRead(regs, r) else Value.Unit;
                v.retain();
                return ok(v);
            },
            .Throw => |r| {
                const exc = fusedRead(regs, r);
                exc.retain();
                return .{ .err = .{ .Throw = exc } };
            },
            .Unreachable => return .{ .err = .{ .Type = "unreachable block executed" } },
            else => unreachable,
        }
        continue :walk;
    }
}

/// Build the real Frame from the bank at (cur, idx) and run the remainder
/// through the framed engine — the same startup sequence the recursive
/// seam performs, resumed mid-body. Bank slots are copied with their own
/// retains (the bank's teardown and the frame's teardown each release
/// one), and subject pushes the fused prefix made are mirrored onto the
/// frame's own chain, with the walker's caller-chain originals still
/// popped by its defer.
fn fusedMaterializeAndRun(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args_in: []const Value,
    regs: []Value,
    cur: BlockId,
    idx: usize,
    pushed_enclosing: usize,
    host: *H,
) Allocator.Error!EvalResult {
    const ev: *EvalTls = &evtls;
    if (runtime.envOnce("KLIO_FUSED_TRACE") != null) {
        std.debug.print("[fused-mat] {s} at b{d}:{d} pushes={d}\n", .{
            if (func.fqn.len != 0) func.fqn else func.name, cur.int(), idx, pushed_enclosing,
        });
    }
    var arg_list: std.ArrayList(Value) = .empty;
    try arg_list.appendSlice(allocator, args_in);
    if (runtime.reclaimEnabled()) for (arg_list.items) |v| v.retain();
    var try_stack: std.ArrayList(TryFrame) = .empty;
    defer try_stack.deinit(allocator);
    var frame = try Frame.newWithCaptures(ev, allocator, module, func, arg_list, .empty);
    defer frame.deinit();
    gcPushFrame(&frame);
    defer gcPopFrame(&frame);
    // The frame inherits the walker's chain window WHOLE — the window IS
    // what activateChain would have built for this frame (caller in-flight
    // copies + own receiver), and the walker's own subject pushes sit above
    // its base exactly as framed in-flight pushes would. Re-deriving via
    // activateChain here dropped the seeded portion (it lives BELOW the
    // window's base, invisible to the in-flight copy): the member-extension
    // owner vanished and `this@Outer` in the remainder missed. The base is
    // restored to the window's seed length so a callee of the remainder
    // still sees the prefix's pushes as in-flight.
    const wbase = ev.active_chain_base;
    if (ev.active_chain) |wchain| {
        try frame.enclosing_this.appendSlice(chainAllocator(), wchain.items);
        // The frame owns the entries now; a populated window would keep
        // rooting them (it is marked as a thread root) long after the
        // remainder dropped them.
        wchain.clearRetainingCapacity();
    }
    frame.activateAs();
    ev.active_chain_base = @min(wbase, frame.enclosing_this.items.len);
    defer frame.deactivateChain();
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
    // Bank slots MOVE into the frame (no retain): the walker never resumes
    // after a materialization, so the frame takes the bank's reference and
    // the bank is zeroed behind it. Leaving the values in the pinned bank
    // kept re-rooting objects the remainder had already dropped — the
    // keepalive pin shaded swept cells collection after collection.
    const n = @min(regs.len, frame.regs.items.len);
    for (regs[0..n], 0..) |v, i| {
        if (runtime.reclaimEnabled()) frame.regs.items[i].release(allocator);
        frame.regs.items[i] = v;
        frame.wmask.set(i);
    }
    for (regs) |*v| v.* = .Unit;
    const result = try runFrame(H, allocator, module, &frame, &try_stack, cur, idx, host);
    return frameBoundary(func, result);
}

inline fn fusedRead(regs: []const Value, r: Reg) Value {
    const i = r.int();
    if (i >= regs.len) return .Unit;
    return regs[i];
}

inline fn fusedWrite(allocator: Allocator, regs: []Value, dst: Reg, v: Value, reclaim: bool, retain_src: bool) void {
    const i = dst.int();
    if (i >= regs.len) {
        if (reclaim and !retain_src) v.release(allocator);
        return;
    }
    if (reclaim) {
        if (retain_src) v.retain();
        const old = regs[i];
        regs[i] = v;
        old.release(allocator);
    } else {
        regs[i] = v;
    }
}

fn fusedInst(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    inst: *const Inst,
    regs: []Value,
    reclaim: bool,
    pushed_enclosing: *usize,
) FusedFail!void {
    switch (inst.*) {
        // The walker's cur_span: recorded on the mark so span-derived
        // context (file-private scoping, diagnostics) sees the executing
        // call site, exactly as a frame tracks it.
        .Trace => |t| fused_marks[fused_depth - 1].span = t.span,
        .LoadParam => |lp| {
            const v = if (lp.idx < args.len) args[lp.idx] else Value.Unit;
            fusedWrite(allocator, regs, lp.dst, v, reclaim, true);
        },
        .Const => |c| {
            if (c.value.int() >= module.consts.items.len)
                return fusedRaise(.{ .Type = "fused: const id out of range" });
            const v = try constToValue(allocator, &module.consts.items[c.value.int()]);
            fusedWrite(allocator, regs, c.dst, v, reclaim, false);
        },
        .Move => |mv| fusedWrite(allocator, regs, mv.dst, fusedRead(regs, mv.src), reclaim, true),
        .Not => |n| {
            const v = fusedRead(regs, n.src);
            if (v == .Instance) {
                switch (try host.callMember(allocator, &v, "not", &.{})) {
                    .ok => |rv| fusedWrite(allocator, regs, n.dst, rv, reclaim, false),
                    .err => |e| return fusedRaise(e),
                }
                return;
            }
            const b = switch (v) {
                .Bool => |bv| !bv,
                else => return fusedRaise(.{ .Type = "Not on non-bool" }),
            };
            fusedWrite(allocator, regs, n.dst, .{ .Bool = b }, reclaim, false);
        },
        .BinOp => |bo| {
            const l = fusedRead(regs, bo.lhs);
            const r = fusedRead(regs, bo.rhs);
            if (scalarBin(bo.op, l, r)) |v| {
                fusedWrite(allocator, regs, bo.dst, v, reclaim, false);
                return;
            }
            switch (try binopValue(H, allocator, l, r, @TypeOf(bo), bo, host)) {
                .ok => |v| fusedWrite(allocator, regs, bo.dst, v, reclaim, false),
                .err => |e| return fusedRaise(e),
            }
        },
        .GetField => |gf| {
            const recv = fusedRead(regs, gf.receiver);
            const fname = constStr(module, gf.field) orelse
                return fusedRaise(.{ .Type = "GetField: name not a string const" });
            if (try builtinFieldFast(H, host, allocator, &recv, fname)) |bv| {
                fusedWrite(allocator, regs, gf.dst, bv, reclaim, false);
                return;
            }
            // Framed parity: the executing body's receiver stays reachable as
            // an enclosing `this` while the field/property resolves — a
            // member-extension property on another receiver (the negative-zero
            // `Double.Companion.NegativeZero` shape) needs it as its owner.
            var pushed_access = false;
            if (func.has_receiver_param and args.len > 0 and args[0] == .Instance) {
                const same = recv == .Instance and ObjRef(InstanceData).ptrEq(args[0].Instance, recv.Instance);
                if (!same) {
                    pushEnclosingAccess(&args[0]);
                    pushed_access = true;
                }
            }
            defer if (pushed_access) popEnclosing();
            switch (try host.getField(allocator, &recv, fname)) {
                .ok => |v| {
                    if (runtime.envOnce("KLIO_FUSED_GF_TRACE")) |w| {
                        if (std.mem.eql(u8, w, fname)) {
                            std.debug.print("[fused-gf] {s} recv={s} -> {s}", .{ fname, @tagName(std.meta.activeTag(recv)), @tagName(std.meta.activeTag(v)) });
                            switch (v) {
                                .Long => |l| std.debug.print(" L{d}", .{l}),
                                .Int => |iv| std.debug.print(" I{d}", .{iv}),
                                .Double => |d| std.debug.print(" D{d}", .{d}),
                                else => {},
                            }
                            switch (recv) {
                                .Long => |l| std.debug.print(" recvL{d}", .{l}),
                                else => {},
                            }
                            std.debug.print("\n", .{});
                        }
                    }
                    fusedWrite(allocator, regs, gf.dst, v, reclaim, true);
                },
                .err => |e| return fusedRaise(e),
            }
        },
        .SetField => |sf| {
            const recv = fusedRead(regs, sf.receiver);
            const v = fusedRead(regs, sf.value);
            const fname = constStr(module, sf.field) orelse
                return fusedRaise(.{ .Type = "SetField: name not a string const" });
            const super_owner: ?[]const u8 = if (sf.super_owner) |c| constStr(module, c) else null;
            switch (try host.setFieldFrom(allocator, &recv, fname, v, super_owner)) {
                .ok => {},
                .err => |e| return fusedRaise(e),
            }
        },
        .Index => |ix| {
            const recv = fusedRead(regs, ix.receiver);
            const idx = fusedRead(regs, ix.index);
            if (fastIndexGet(&recv, &idx)) |v| {
                v.retain();
                fusedWrite(allocator, regs, ix.dst, v, reclaim, false);
                return;
            }
            switch (try host.callMember(allocator, &recv, "get", &.{idx})) {
                .ok => |v| fusedWrite(allocator, regs, ix.dst, v, reclaim, false),
                .err => |e| return fusedRaise(e),
            }
        },
        .IndexSet => |ixs| {
            const recv = fusedRead(regs, ixs.receiver);
            const idx = fusedRead(regs, ixs.index);
            const v = fusedRead(regs, ixs.value);
            if (exec_call.fastIndexSet(allocator, &recv, &idx, v)) |expr_val| {
                if (reclaim) expr_val.release(allocator);
                return;
            }
            switch (try host.callMember(allocator, &recv, "set", &.{ idx, v })) {
                .ok => {},
                .err => |e| return fusedRaise(e),
            }
        },
        .InstanceOf => |io| {
            const v = fusedRead(regs, io.src);
            fusedWrite(allocator, regs, io.dst, .{ .Bool = host.instanceOf(&v, io.ty) }, reclaim, false);
        },
        .Cast => |cast| {
            const v = fusedRead(regs, cast.src);
            if (host.instanceOf(&v, cast.ty)) {
                fusedWrite(allocator, regs, cast.dst, v, reclaim, true);
            } else if (exec_call.typeParamCastPassesIn(H, module, func, cast.ty, host)) {
                fusedWrite(allocator, regs, cast.dst, v, reclaim, true);
            } else if (cast.safe) {
                fusedWrite(allocator, regs, cast.dst, .Null, reclaim, false);
            } else {
                if (runtime.envOnce("KLIO_THROW_TRACE") != null) {
                    std.debug.print("[throw-trace] from fused fn {s}: ClassCastException cast to {s} (value tag {s})\n", .{ func.name, cast.ty.name, @tagName(std.meta.activeTag(v)) });
                }
                const msg = try std.fmt.allocPrint(allocator, "cast to `{s}` failed", .{cast.ty.name});
                const exc = try Value.newException(allocator, .{
                    .fqn = try runtime.strInit(allocator, "kotlin.ClassCastException"),
                    .message = .from(try runtime.strInitOwned(allocator, msg)),
                    .cause = null,
                });
                return fusedRaise(.{ .Throw = exc });
            }
        },
        .NotNullAssert => |nn| {
            const v = fusedRead(regs, nn.src);
            if (v == .Null) {
                const exc = try Value.newException(allocator, .{
                    .fqn = try runtime.strInit(allocator, "kotlin.NullPointerException"),
                    .message = .{},
                    .cause = null,
                });
                return fusedRaise(.{ .Throw = exc });
            }
            fusedWrite(allocator, regs, nn.dst, v, reclaim, true);
        },
        .MakeCell => |mc| {
            const v = fusedRead(regs, mc.src);
            v.retain();
            fusedWrite(allocator, regs, mc.dst, try Value.newCell(allocator, v), reclaim, false);
        },
        .CellGet => |cg| {
            const v = switch (fusedRead(regs, cg.cell)) {
                .Cell => |c| blk: {
                    const g = c.borrow();
                    defer g.deinit();
                    break :blk g.get().*;
                },
                else => |other| other,
            };
            fusedWrite(allocator, regs, cg.dst, v, reclaim, true);
        },
        .CellSet => |cs| {
            const cell_v = fusedRead(regs, cs.cell);
            const v = fusedRead(regs, cs.value);
            switch (cell_v) {
                .Cell => |c| {
                    v.retain();
                    const g = c.borrowMut();
                    defer g.deinit();
                    const old = g.get().*;
                    g.get().* = v;
                    if (reclaim) old.release(allocator);
                },
                else => return fusedRaise(.{ .Type = "CellSet on non-cell" }),
            }
        },
        .LoadGlobal => |lg| {
            switch (try loadGlobalValue(H, allocator, module, lg, host)) {
                .ok => |v| fusedWrite(allocator, regs, lg.dst, v, reclaim, false),
                .err => |e| return fusedRaise(e),
            }
        },
        .NewInstance => |ni| {
            var argv: [FUSED_MAX_REGS]Value = undefined;
            if (ni.n_args > FUSED_MAX_REGS)
                return fusedRaise(.{ .Type = "fused: too many ctor args" });
            var i: u32 = 0;
            while (i < ni.n_args) : (i += 1) {
                argv[i] = fusedRead(regs, Reg.from(ni.args.int() + i));
            }
            const names = try exec_call.resolveArgNames(allocator, module, ni.arg_names);
            defer exec_call.freeArgNames(allocator, names);
            const static_heads = try exec_call.resolveArgNames(allocator, module, ni.arg_static_heads);
            defer exec_call.freeArgNames(allocator, static_heads);
            if (comptime @hasDecl(H, "setCtorArgStaticHeads")) {
                host.setCtorArgStaticHeads(static_heads);
            }
            // A bare `Inner(args)` inside a member is `this@Outer.Inner`:
            // the fused body's own `this` parameter is the outer hint,
            // exactly as the framed arm passes its frame's `this`.
            var outer_hint: ?Value = null;
            if (args.len > 0 and func.params.len > 0 and
                std.mem.eql(u8, func.params[0].name, "this")) outer_hint = args[0];
            const hint_ptr: ?*const Value = if (outer_hint) |*h| h else null;
            const result = switch (try host.newInstanceNamed(allocator, ni.class, argv[0..ni.n_args], names, hint_ptr)) {
                .ok => |v| v,
                .err => |e| return fusedRaise(e),
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
                    outer_hint.?.retain();
                    const g = inst_ref.borrowMut();
                    defer g.deinit();
                    g.get().outer = outer_hint.?;
                }
            }
            fusedWrite(allocator, regs, ni.dst, result, reclaim, false);
        },
        .EnclosingPush => |x| {
            const v = fusedRead(regs, x.src);
            pushEnclosingSubject(&v);
            pushed_enclosing.* += 1;
        },
        .EnclosingPop => {
            popEnclosing();
            if (pushed_enclosing.* > 0) pushed_enclosing.* -= 1;
        },
        .Call => |c| {
            const callee = module.funcById(c.func) orelse
                return error.Materialize;
            // Same-name same-arity peers: the baked DIRECT id is only the
            // target when this SITE's scope binds it — framed re-resolves
            // otherwise (a host binding beat the pack body for
            // convertDurationUnit, Long vs Double). Ask exactly as the
            // framed fast path does and hand ambiguous sites to the framed
            // machinery.
            if (comptime @hasDecl(H, "callFuncFast")) {
                var plan = callee.fast_call;
                if (plan == 0) {
                    plan = host.fastCallPlan(module, c.func);
                    @constCast(callee).fast_call = plan;
                }
                if (plan & ir.FAST_CALL_AMBIG_FLAG != 0) {
                    var verdict = @atomicLoad(u8, @constCast(&c.fuse_site), .acquire);
                    if (verdict == 0) {
                        const cfile: ?ir.FileId = if (fused_marks[fused_depth - 1].span) |sp| sp.file else null;
                        verdict = if (host.fuseSiteBinds(module, c.func, func.package, cfile)) 2 else 1;
                        @atomicStore(u8, @constCast(&c.fuse_site), verdict, .release);
                    }
                    if (verdict != 2) return error.Materialize;
                }
            }
            var argv: [FUSED_MAX_REGS]Value = undefined;
            if (c.n_args > FUSED_MAX_REGS)
                return fusedRaise(.{ .Type = "fused: too many call args" });
            var i: u32 = 0;
            while (i < c.n_args) : (i += 1) {
                argv[i] = fusedRead(regs, Reg.from(c.args.int() + i));
            }
            if (c.arg_names.len != 0 or c.type_args.len != 0 or callee.params.len != c.n_args)
                return error.Materialize;
            // Scalar-replay leaf: a registered pure callee runs as direct
            // C; a bail falls through to fusedExec, which re-runs the
            // pure body exactly.
            const leaf_served: ?Value = if (try tryLeafValues(H, allocator, module, callee, argv[0..c.n_args], host, null)) |lo| switch (lo) {
                .val => |v| v,
                .raise => |e| return fusedRaise(e),
            } else null;
            if (leaf_served) |lv| {
                fusedWrite(allocator, regs, c.dst, lv, reclaim, false);
                return;
            }
            const direct = try fusedExec(H, allocator, module, callee, argv[0..c.n_args], host);
            const r = direct orelse blk: {
                // The runtime gates (bank depth, a host-owned callee, a
                // PARTIAL callee) can decline what the classifier admitted.
                // A FULL-classified callee run framed stays non-suspending
                // (its calls are transitively full), so the seam fallback
                // is sound; anything else materializes this body instead.
                if (fusedVerdict(H, host, module, callee) != 1) return error.Materialize;
                var arg_list: std.ArrayList(Value) = .empty;
                try arg_list.appendSlice(allocator, argv[0..c.n_args]);
                if (runtime.reclaimEnabled()) for (arg_list.items) |v| v.retain();
                break :blk try evalWithCapturesChained(H, allocator, module, null, callee, arg_list, .empty, &.{}, null, host);
            };
            switch (r) {
                .ok => |v| {
                    if (runtime.envOnce("KLIO_FUSED_CALL_TRACE")) |w| {
                        if (std.mem.indexOf(u8, callee.name, w) != null) {
                            std.debug.print("[fused-call] {s} in {s} -> {s}", .{ callee.name, func.name, @tagName(std.meta.activeTag(v)) });
                            switch (v) {
                                .Long => |l| std.debug.print(" L{d}", .{l}),
                                .Int => |iv| std.debug.print(" I{d}", .{iv}),
                                .Double => |d| std.debug.print(" D{d}", .{d}),
                                else => {},
                            }
                            std.debug.print(" direct={}\n", .{direct != null});
                        }
                    }
                    fusedWrite(allocator, regs, c.dst, v, reclaim, false);
                },
                .err => |e| return fusedRaise(e),
            }
        },
        else => return error.Materialize,
    }
}
