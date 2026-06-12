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
    return .{ .String = try StringRef.init(allocator, s) };
}

fn displayThrow(allocator: Allocator, v: *const Value) Allocator.Error![]u8 {
    switch (v.*) {
        .Exception => |e| {
            const fg = e.fqn.borrow();
            defer fg.deinit();
            const fqn = fg.get().*;
            if (e.message) |m| {
                const mg = m.borrow();
                defer mg.deinit();
                return std.fmt.allocPrint(allocator, "{s}({s})", .{ fqn, mg.get().* });
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
                    return std.fmt.allocPrint(allocator, "{s}({s})", .{ name, sg.get().* });
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
threadlocal var eval_depth: usize = 0;

/// Resolved depth cap for the current thread. `0` means "not yet read"; the
/// first `runFrame` reads the env once and caches the result.
threadlocal var eval_depth_cap: usize = 0;

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
pub const EnclosingEntry = struct {
    v: Value,
    kind: Kind = .receiver,

    pub const Kind = enum { receiver, subject, access };

    pub fn isSubject(self: EnclosingEntry) bool {
        return self.kind == .subject;
    }
};

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
/// `active_chain_base`, minus `access` entries. Because the chain lives on
/// the frame, it travels with a parked continuation and cannot leak past
/// the frame or across a `run` boundary.
threadlocal var active_chain: ?*std.ArrayList(EnclosingEntry) = null;

/// Length of the active chain's seeded (frame-entry) prefix. Entries at
/// `>= active_chain_base` are in-flight pushes made by the currently
/// executing frame around a dispatch; only those transfer into the next
/// frame entered.
threadlocal var active_chain_base: usize = 0;

/// Push `v` as an enclosing implicit receiver for the about-to-be-invoked
/// callable. Appends to the current frame's chain; the invoked frame picks
/// it up at entry. A no-op (silently dropped) when no frame is active.
pub fn pushEnclosing(v: *const Value) void {
    const chain = active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .receiver }) catch {};
}

/// Push a receiver-lambda subject (`with(x) { … }`'s `x`). The subject is a
/// receiver inside the lambda body, but its `outer` links are not.
pub fn pushEnclosingSubject(v: *const Value) void {
    const chain = active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .subject }) catch {};
}

/// Push `v` for dispatch-time visibility only (the member-extension
/// visibility filter and field-resolution fallbacks consult the chain
/// while resolving one call). The entry never becomes part of a callee
/// frame's lexical receiver scope.
pub fn pushEnclosingAccess(v: *const Value) void {
    const chain = active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .access }) catch {};
}

/// Pop the most recent `pushEnclosing`/`pushEnclosingSubject`. A no-op when no
/// frame is active or the chain is empty.
pub fn popEnclosing() void {
    const chain = active_chain orelse return;
    if (chain.items.len > 0) _ = chain.pop();
}

/// The innermost enclosing `this`, or `null` when the chain is empty.
pub fn enclosingThisLast() ?Value {
    const chain = active_chain orelse return null;
    if (chain.items.len == 0) return null;
    return chain.items[chain.items.len - 1].v;
}

/// The enclosing-`this` chain, innermost first. Caller owns the returned slice.
pub fn enclosingThisChainAlloc(allocator: Allocator) Allocator.Error![]Value {
    const chain = active_chain orelse return allocator.alloc(Value, 0);
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
    const chain = active_chain orelse return allocator.alloc(EnclosingEntry, 0);
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
    const chain = active_chain orelse return allocator.alloc(EnclosingEntry, 0);
    var out: std.ArrayList(EnclosingEntry) = .empty;
    errdefer out.deinit(allocator);
    for (chain.items) |e| {
        if (e.kind == .access) continue;
        try out.append(allocator, e);
    }
    return out.toOwnedSlice(allocator);
}

/// Backing allocator for a frame's `enclosing_this` chain. The chain is
/// frame-scoped (created and torn down with the frame, or copied verbatim into
/// a `FrameSnapshot` on suspend), so it is backed by the same per-call
/// allocator the frame's regs/params/captures use.
fn chainAllocator() Allocator {
    return std.heap.page_allocator;
}

fn maxEvalDepth() usize {
    if (eval_depth_cap != 0) return eval_depth_cap;
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
    eval_depth_cap = cap;
    return cap;
}

/// `Result<Value, EvalError>` as data. OOM stays a Zig `error`; this
/// carries the `EvalError` data path.
pub const EvalResult = union(enum) {
    ok: Value,
    err: EvalError,
};

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
    regs: []Value,
    params: []Value,
    captures: []Value,
    /// The frame's enclosing-`this` chain (innermost last) at the suspension
    /// point. Restored verbatim on resume so implicit-receiver resolution
    /// (bare member / `this@Outer`) inside a receiver-lambda / `with` /
    /// member-extension body sees the same receivers after the park that it saw
    /// before: the chain travels with the parked continuation instead of being
    /// recovered from process-global state the resuming thread happens to hold.
    enclosing_this: []EnclosingEntry,
    try_stack: []TryFrame,
    is_lambda: bool,
    /// Register the resumed value is written into before execution
    /// continues (the destination of the suspending call site).
    resume_reg: ?Reg,
};

/// Layer 1 — a parked activation: a stack of frame snapshots
/// (outermost first, innermost last) plus the token the interceptor
/// uses to resume it. Pure suspend mechanism: it carries no thread,
/// dispatcher, or timing policy of its own.
pub const SuspendState = struct {
    token: u64,
    frames: std.ArrayList(FrameSnapshot) = .empty,
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
};

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
    /// The `active_chain` pointer to restore when this frame exits, so a frame
    /// running under a caller frame returns enclosing-`this` resolution to the
    /// caller's chain rather than leaving a dangling pointer.
    prev_chain: ?*std.ArrayList(EnclosingEntry),
    /// The caller's `active_chain_base`, restored on exit alongside
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

    fn newWithCaptures(
        allocator: Allocator,
        module: *const Module,
        func: *const Func,
        params_in: std.ArrayList(Value),
        captures: std.ArrayList(Value),
    ) Allocator.Error!Frame {
        const params = params_in;
        coerceIntArgsToLong(func, params.items);
        var regs: std.ArrayList(Value) = .empty;
        try regs.appendNTimes(allocator, .Unit, func.n_locals);
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
        if (active_chain) |caller| {
            for (caller.items[@min(active_chain_base, caller.items.len)..]) |e| {
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
        self.prev_chain = active_chain;
        self.prev_chain_base = active_chain_base;
        active_chain = &self.enclosing_this;
        active_chain_base = self.enclosing_this.items.len;
    }

    fn deactivateChain(self: *Frame) void {
        active_chain = self.prev_chain;
        active_chain_base = self.prev_chain_base;
    }

    fn deinit(self: *Frame) void {
        self.regs.deinit(self.allocator);
        self.params.deinit(self.allocator);
        self.captures.deinit(self.allocator);
        self.enclosing_this.deinit(chainAllocator());
    }

    fn read(self: *const Frame, r: Reg) Value {
        const idx = r.int();
        if (idx < self.regs.items.len) return self.regs.items[idx];
        return .Unit;
    }

    fn write(self: *Frame, r: Reg, v: Value) Allocator.Error!void {
        const idx = r.int();
        if (idx >= self.regs.items.len) {
            try self.regs.appendNTimes(self.allocator, .Unit, idx + 1 - self.regs.items.len);
        }
        self.regs.items[idx] = v;
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
    return evalWithCaptures(H, allocator, module, func, args, .empty, host);
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
    return evalWithCapturesChained(H, allocator, module, owning, func, args, captures, &.{}, host);
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
    host: *H,
) Allocator.Error!EvalResult {
    var try_stack: std.ArrayList(TryFrame) = .empty;
    defer try_stack.deinit(allocator);
    const func_name = func.name;
    var frame = try Frame.newWithCaptures(allocator, module, func, args, captures);
    defer frame.deinit();
    frame.module_arc = owning;
    try frame.activateChain(chain_seed);
    defer frame.deactivateChain();
    const cur = func.entry;
    var result = try runFrame(H, allocator, module, &frame, &try_stack, cur, 0, host);
    // A labeled return whose target is this function exits it as a
    // normal return. Other labels propagate further outward until the
    // matching frame catches them.
    if (result == .err and result.err == .LabeledReturn and
        std.mem.eql(u8, result.err.LabeledReturn.label, func_name))
    {
        result = ok(result.err.LabeledReturn.value);
    }
    // A bare integer literal returned where the declared return type is
    // `Long` (`fun f(): Long = 0`) carries an `Int` tag out of the
    // body; normalize it so the caller's `Long` binding observes a
    // `Long`.
    if (result == .ok) {
        coerceIntToLongTy(func.return_ty, &result.ok);
    }
    // The body ran: an `Unimplemented` escaping it is a real failure of
    // an executed statement, not a dispatch miss. Re-tag it so no
    // enclosing candidate walk retries (and re-executes) this body.
    if (result == .err and result.err == .Unimplemented) {
        result = errResult(.{ .CalleeFailed = result.err.Unimplemented });
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
    // feed its return value to the next-outer frame, and so on.
    var frames = state.frames;
    defer frames.deinit(allocator);
    var head: usize = 0;
    var first = true;
    var pending_throw_from_inner: ?Value = null;
    while (head < frames.items.len) {
        const snap = frames.items[head];
        head += 1;
        // Resolve the frame's `FuncId` against the module it was lowered
        // into — a per-method sub-module for an anon-object / local /
        // nested class, the passed-in (main) module otherwise.
        const snap_module = snap.module;
        const m: *const Module = snap_module orelse module;
        const func = &m.funcs.items[snap.func.int()];
        var params: std.ArrayList(Value) = .empty;
        try params.appendSlice(allocator, snap.params);
        var caps: std.ArrayList(Value) = .empty;
        try caps.appendSlice(allocator, snap.captures);
        var frame = try Frame.newWithCaptures(allocator, m, func, params, caps);
        defer frame.deinit();
        frame.module_arc = snap_module;
        // Restore the frame's enclosing-`this` chain verbatim so implicit
        // receivers resolved before the park resolve identically after it.
        try frame.activateChainFrom(snap.enclosing_this);
        defer frame.deactivateChain();
        frame.regs.clearRetainingCapacity();
        try frame.regs.appendSlice(allocator, snap.regs);
        // Kotlin `Continuation.resumeWith(Result.failure(e))` means
        // "resume by throwing `e` at the suspension point". Only the
        // innermost (suspending) frame sees the raw failure Result;
        // route it as a throw there instead of delivering it as the
        // suspending call's value, so a cancellation preempts a parked
        // `delay`/acquire rather than letting it complete.
        var resume_throw: ?Value = null;
        if (pending_throw_from_inner) |exc| {
            pending_throw_from_inner = null;
            resume_throw = exc;
        } else if (first) {
            if (carry == .Result and !carry.Result.ok) {
                resume_throw = carry.Result.payload.*;
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
        const r = try runFrameInner(H, allocator, m, &frame, &try_stack, snap.block, snap.inst_idx, resume_throw, host);
        switch (r) {
            .ok => |v| carry = v,
            .err => |e| switch (e) {
                .Suspended => |inner| {
                    // Re-suspended before this frame finished. The newly
                    // captured inner frames stay innermost-first; the
                    // still-pending outer frames sit after them.
                    var i = head;
                    while (i < frames.items.len) : (i += 1) {
                        try inner.frames.append(allocator, frames.items[i]);
                    }
                    return errResult(.{ .Suspended = inner });
                },
                .Throw => |exc| {
                    // Route the throw through the next-outer frame's
                    // restored try-stack: a `try { suspendingCall() }
                    // catch (e) { … }` should see exceptions raised after
                    // the parked call resumes.
                    if (head >= frames.items.len) {
                        return errResult(.{ .Throw = exc });
                    }
                    pending_throw_from_inner = exc;
                },
                // A resumed frame ran; its unresolved-operation failure is
                // real, never a dispatch miss (see `CalleeFailed`).
                .Unimplemented => |msg| return errResult(.{ .CalleeFailed = msg }),
                else => return errResult(e),
            },
        }
    }
    return ok(carry);
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
    if (eval_depth >= maxEvalDepth()) {
        return errResult(.{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" });
    }
    eval_depth += 1;
    defer eval_depth -= 1;
    return runFrameInner(H, allocator, module, frame, try_stack, cur, resume_idx, null, host);
}

fn typeRefName(name: []const u8) TypeRef {
    return .{ .name = name, .nullable = false, .args = &.{} };
}

/// `resume_throw`: when a continuation is resumed with
/// `Result.failure(e)` (Kotlin's `resumeWith(failure)` = "resume by
/// throwing at the suspension point"), the exception is routed through
/// this frame's restored try-stack instead of being delivered as the
/// suspending call's value. This makes a cancellation actually preempt
/// a parked `delay` / acquire.
fn runFrameInner(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    host: *H,
) Allocator.Error!EvalResult {
    var cur = cur_in;
    var resume_idx = resume_idx_in;
    var resume_throw = resume_throw_in;
    var pending_rethrow: ?struct { key: BlockId, exc: Value } = null;
    var pending_return: ?struct { key: BlockId, val: Value } = null;
    const func: *const Func = frame.func;
    while (true) {
        // Daemon abandonment: a dispatcher pool task still running at the
        // run boundary stops at its next block instead of completing (or
        // looping forever). The unwind bypasses user catch/finally frames
        // deliberately — the task is being torn down, not failing.
        if (runtime.shouldAbandon()) {
            return errResult(.{ .Type = "daemon task abandoned at run boundary" });
        }
        const block = &func.blocks[cur.int()];
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
        var start_idx = resume_idx;
        resume_idx = 0;
        if (resume_throw) |exc| {
            resume_throw = null;
            // Resumed with an exception: skip the remaining instructions
            // of the suspending block and route the throw through the
            // restored try-stack exactly as a mid-block throw would.
            thrown = exc;
            start_idx = insts.len;
        }
        var idx: usize = 0;
        while (idx < insts.len) : (idx += 1) {
            if (idx < start_idx) continue;
            const inst = &insts[idx];
            const r = try execInst(H, allocator, frame, inst, host);
            switch (r) {
                .ok => {},
                .err => |e| switch (e) {
                    .Throw => |v| {
                        thrown = v;
                        break;
                    },
                    .NonLocalReturn => |v| {
                        // A non-local return unwinds through the lambda
                        // frame *and* through any inline-function frames it
                        // was passed into, landing in the function that
                        // wrote the lambda (Kotlin allows non-local return
                        // only via inline functions).
                        if (frame.func.is_lambda or frame.func.is_inline) {
                            return errResult(.{ .NonLocalReturn = v });
                        }
                        return ok(v);
                    },
                    .Suspended => |state| {
                        // Snapshot this activation so it can be resumed
                        // just past the suspending instruction. The resume
                        // value lands in the suspending call's destination
                        // register (or one a binding set explicitly via
                        // `pending_resume_reg`).
                        const resume_reg = if (state.pending_resume_reg) |rr| blk: {
                            state.pending_resume_reg = null;
                            break :blk rr;
                        } else instDst(inst);
                        try state.frames.append(allocator, .{
                            .func = frame.func.id,
                            .module = frame.module_arc,
                            .block = cur,
                            .inst_idx = idx + 1,
                            .regs = try allocator.dupe(Value, frame.regs.items),
                            .params = try allocator.dupe(Value, frame.params.items),
                            .captures = try allocator.dupe(Value, frame.captures.items),
                            .enclosing_this = try allocator.dupe(EnclosingEntry, frame.enclosing_this.items),
                            .try_stack = try allocator.dupe(TryFrame, try_stack.items),
                            .is_lambda = frame.func.is_lambda,
                            .resume_reg = resume_reg,
                        });
                        return errResult(.{ .Suspended = state });
                    },
                    else => return errResult(e),
                },
            }
        }
        if (thrown) |exc| {
            // Mid-block throw — same try-stack walk as Terminator.Throw.
            var routed = false;
            while (try_stack.pop()) |tf| {
                if (findCatch(H, host, &exc, tf.catches)) |h| {
                    try frame.write(h.exception_reg, exc);
                    cur = h.handler;
                    routed = true;
                    break;
                } else if (tf.finally_entry) |fin| {
                    const key = tf.finally_done orelse fin;
                    pending_rethrow = .{ .key = key, .exc = exc };
                    cur = fin;
                    routed = true;
                    break;
                }
            }
            if (!routed) {
                return errResult(.{ .Throw = exc });
            }
            continue;
        }
        // Symmetric try-stack pop on normal flow through finally.
        if (term == .Goto and pending_rethrow == null and pending_return == null) {
            const done_for = frame.block(cur).finally_done_for;
            const pos: ?usize = if (done_for) |body|
                rpositionByBody(try_stack.items, body)
            else
                rpositionByFinallyEntry(try_stack.items, cur);
            if (pos) |p| {
                _ = try_stack.orderedRemove(p);
            }
        }
        // Finally exit with a pending return: replay the return through
        // any outer finally, otherwise complete it. The key pinned in
        // `pending_return` is the *done sentinel* — the synthesized exit
        // block of the user finally body, so an `if`/`when` inside the
        // finally still resolves here once its join reaches the sentinel.
        if (pending_return) |pr| {
            if (std.meta.eql(pr.key, cur) and term == .Goto) {
                const v = pr.val;
                pending_return = null;
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
                    pending_return = .{ .key = c.key, .val = v };
                    cur = c.jump;
                    continue;
                }
                return ok(v);
            }
            if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                pending_return = null;
            }
        }
        // Finally re-throw: if we entered the current block as a finally
        // on the uncaught-throw path, and the block exits via a plain
        // Goto (no `return` / `throw` swallowed the pending exception),
        // re-raise the saved exception through the enclosing try-stack
        // just like a fresh throw.
        if (pending_rethrow) |pr| {
            if (std.meta.eql(pr.key, cur) and term == .Goto) {
                const exc = pr.exc;
                pending_rethrow = null;
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (findCatch(H, host, &exc, tf.catches)) |h| {
                        try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin2| {
                        const key = tf.finally_done orelse fin2;
                        pending_rethrow = .{ .key = key, .exc = exc };
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
                pending_rethrow = null;
            }
        }
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
                // Walk the try-stack for the nearest finally; route the
                // return through it.
                var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                var i: usize = try_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (try_stack.items[i].finally_entry) |fin| {
                        const key = try_stack.items[i].finally_done orelse fin;
                        chosen = .{ .i = i, .jump = fin, .key = key };
                        break;
                    }
                }
                if (chosen) |c| {
                    try_stack.shrinkRetainingCapacity(c.i);
                    pending_return = .{ .key = c.key, .val = v };
                    cur = c.jump;
                    continue;
                }
                return ok(v);
            },
            .NonLocalReturn => |maybe_r| {
                const v = if (maybe_r) |r| frame.read(r) else Value.Unit;
                if (frame.func.is_lambda or frame.func.is_inline) {
                    return errResult(.{ .NonLocalReturn = v });
                }
                return ok(v);
            },
            .LabeledReturn => |lr| {
                const v = if (lr.value) |r| frame.read(r) else Value.Unit;
                if (std.mem.eql(u8, frame.func.name, lr.label)) {
                    return ok(v);
                }
                return errResult(.{ .LabeledReturn = .{ .label = lr.label, .value = v } });
            },
            .Throw => |r| {
                const exc = frame.read(r);
                if (envVarSet("KLIO_THROW_TRACE")) {
                    const s = displayThrow(allocator, &exc) catch "";
                    std.debug.print("[throw-trace] from fn {s} (fqn={s}): {s}\n", .{ frame.func.name, frame.func.fqn, s });
                }
                // Walk the try stack for a matching handler.
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (findCatch(H, host, &exc, tf.catches)) |h| {
                        try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin| {
                        const key = tf.finally_done orelse fin;
                        pending_rethrow = .{ .key = key, .exc = exc };
                        cur = fin;
                        routed = true;
                        break;
                    }
                }
                if (!routed) {
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
                try frame.regs.appendNTimes(allocator, .Unit, n);
                try_stack.clearRetainingCapacity();
                cur = frame.func.entry;
            },
            .TailCallFunc => |tc| {
                var new_params: std.ArrayList(Value) = .empty;
                var k: u8 = 0;
                while (k < tc.n_args) : (k += 1) {
                    try new_params.append(allocator, frame.read(Reg.from(tc.args.int() + @as(u32, k))));
                }
                const new_func = &module.funcs.items[tc.func.int()];
                coerceIntArgsToLong(new_func, new_params.items);
                frame.func = new_func;
                frame.params.deinit(allocator);
                frame.params = new_params;
                frame.regs.clearRetainingCapacity();
                try frame.regs.appendNTimes(allocator, .Unit, new_func.n_locals);
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
        .CallMemberOrGlobal => |x| x.dst,
        .CallValueOrMember => |x| x.dst,
        .CallMemberOrValue => |x| x.dst,
        .NewInstance => |x| x.dst,
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

fn execInst(comptime H: type, allocator: Allocator, frame: *Frame, inst: *const Inst, host: *H) Allocator.Error!EvalResult {
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
            try frame.write(mv.dst, v);
        },
        .MakeCell => |mc| {
            const v = frame.read(mc.src);
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
            try frame.write(cg.dst, v);
        },
        .CellSet => |cs| {
            const v = frame.read(cs.value);
            switch (frame.read(cs.cell)) {
                .Cell => |c| {
                    const g = c.borrowMut();
                    defer g.deinit();
                    g.get().* = v;
                },
                else => {
                    try frame.write(cs.cell, v);
                },
            }
        },
        .Not => |n| {
            const v = frame.read(n.src);
            // User-defined `operator fun not(): T` overrides the builtin
            // Bool inversion; route through call_member.
            if (v == .Instance) {
                const result = host.callMember(allocator, &v, "not", &.{});
                switch (try result) {
                    .ok => |rv| {
                        try frame.write(n.dst, rv);
                        return ok(.Unit);
                    },
                    .err => |e| return errResult(e),
                }
            }
            const b = switch (v) {
                .Bool => |bv| !bv,
                else => return errResult(.{ .Type = "Not on non-bool" }),
            };
            try frame.write(n.dst, .{ .Bool = b });
        },
        .UnOp => |u| {
            const v = frame.read(u.operand);
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
                        return ok(.Unit);
                    },
                    .err => |e| return errResult(e),
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
                    return ok(.Unit);
                },
                .err => |e| switch (e) {
                    .Unimplemented => {},
                    else => return errResult(e),
                },
            }
            switch (try applyUnop(allocator, u.op, &v)) {
                .ok => |out| try frame.write(u.dst, out),
                .err => |e| return errResult(e),
            }
        },
        .BinOp => |bo| {
            const l = frame.read(bo.lhs);
            const r = frame.read(bo.rhs);
            // StringConcat over a Value.Instance routes the instance
            // through toString so user-defined overrides fire.
            if (bo.op == .StringConcat) {
                const ls = switch (try stringify(H, allocator, host, &l)) {
                    .ok => |s| s,
                    .err => |e| return errResult(e),
                };
                const rs = switch (try stringify(H, allocator, host, &r)) {
                    .ok => |s| s,
                    .err => |e| return errResult(e),
                };
                const combined = try std.mem.concat(allocator, u8, &.{ ls, rs });
                try frame.write(bo.dst, .{ .String = try StringRef.init(allocator, combined) });
                return ok(.Unit);
            }
            // Collection `+` / `-` operators are stdlib operator
            // functions on the left collection.
            if ((bo.op == .Add or bo.op == .Sub) and switch (l) {
                .Map, .List, .Set, .Sequence, .Range => true,
                else => false,
            }) {
                const method = if (bo.op == .Add) "plus" else "minus";
                switch (try host.callMember(allocator, &l, method, &.{r})) {
                    .ok => |rv| {
                        try frame.write(bo.dst, rv);
                        return ok(.Unit);
                    },
                    .err => |e| return errResult(e),
                }
            }
            // Arrays define `+` (`plus`) but no `-`.
            if (bo.op == .Add and l == .Array) {
                switch (try host.callMember(allocator, &l, "plus", &.{r})) {
                    .ok => |rv| {
                        try frame.write(bo.dst, rv);
                        return ok(.Unit);
                    },
                    .err => |e| return errResult(e),
                }
            }
            // Referential identity (`===` / `!==`): pure pointer
            // identity, never a user `equals` dispatch.
            if (bo.op == .IdentEq or bo.op == .IdentNeq) {
                const same = Value.referenceEq(&l, &r);
                const b = if (bo.op == .IdentNeq) !same else same;
                try frame.write(bo.dst, .{ .Bool = b });
                return ok(.Unit);
            }
            // COROUTINE_SUSPENDED and Result have no user `equals`
            // surface: any equality against them is structural /
            // identity, never a `call_member("equals")` dispatch.
            if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
                (l == .CoroutineSuspended or r == .CoroutineSuspended or l == .Result or r == .Result))
            {
                const eq = Value.structuralEq(&l, &r);
                const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
                try frame.write(bo.dst, .{ .Bool = b });
                return ok(.Unit);
            }
            if (operatorMethod(bo.op)) |method| {
                if (l == .Instance or r == .Instance) {
                    // Strict extension dispatch: an operator extension whose
                    // declared receiver doesn't accept `l` is not a candidate
                    // (kotlinc drops it), so `Unimplemented` surfaces and the
                    // `<op>Assign` fallback below can fire — `config += other`
                    // on a type declaring only `plusAssign` must not bind a
                    // receiver-incompatible `plus` like `String?.plus(Any?)`.
                    var result: Value = undefined;
                    switch (try host.callMemberStrictExt(allocator, &l, method, &.{r}, &.{null}, null)) {
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
                        else => result,
                    };
                    try frame.write(bo.dst, final_val);
                    return ok(.Unit);
                }
            }
            switch (try applyBinop(allocator, bo.op, &l, &r)) {
                .ok => |out| try frame.write(bo.dst, out),
                .err => |e| return errResult(e),
            }
        },
        .Trace => {},
        .LoadParam => |lp| {
            const v = if (lp.idx < frame.params.items.len) frame.params.items[lp.idx] else Value.Unit;
            try frame.write(lp.dst, v);
        },
        .NotNullAssert => |nn| {
            const v = frame.read(nn.src);
            if (v == .Null) {
                const exc = Value{ .Exception = .{
                    .fqn = try StringRef.init(allocator, "kotlin.NullPointerException"),
                    .message = null,
                    .cause = null,
                } };
                return errResult(.{ .Throw = exc });
            }
            try frame.write(nn.dst, v);
        },
        .GetField => |gf| {
            const recv = frame.read(gf.receiver);
            const name = constStr(frame.module, gf.field) orelse
                return errResult(.{ .Type = "GetField: name not a string const" });
            // Keep the executing function's receiver reachable as the
            // enclosing `this` while the field/property is resolved.
            var pushed_enclosing = false;
            if (frame.params.items.len > 0 and frame.params.items[0] == .Instance) {
                const pi = frame.params.items[0].Instance;
                const same = recv == .Instance and ObjRef(InstanceData).ptrEq(pi, recv.Instance);
                if (!same) {
                    pushEnclosingAccess(&frame.params.items[0]);
                    pushed_enclosing = true;
                }
            }
            const got = host.getField(allocator, &recv, name);
            if (pushed_enclosing) popEnclosing();
            switch (try got) {
                .ok => |v| try frame.write(gf.dst, v),
                .err => |e| return errResult(e),
            }
        },
        .SetField => |sf| {
            const recv = frame.read(sf.receiver);
            const v = frame.read(sf.value);
            const name = constStr(frame.module, sf.field) orelse
                return errResult(.{ .Type = "SetField: name not a string const" });
            switch (try host.setField(allocator, &recv, name, v)) {
                .ok => {},
                .err => |e| return errResult(e),
            }
        },
        .Call => |call| {
            const arg_values = try readArgRun(allocator, frame, call.args, call.n_args);
            defer allocator.free(arg_values);
            const names = try resolveArgNames(allocator, frame.module, call.arg_names);
            defer allocator.free(names);
            var ta: std.ArrayList([]const u8) = .empty;
            defer ta.deinit(allocator);
            for (call.type_args) |c| {
                try ta.append(allocator, constStr(frame.module, c) orelse "");
            }
            // Invoking an extension / member-extension function from
            // inside a method: keep the caller's instance `this`
            // reachable as the enclosing receiver.
            const callee_fn: ?*const Func = if (call.func.int() < frame.module.funcs.items.len)
                &frame.module.funcs.items[call.func.int()]
            else
                null;
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
            const res = host.callFuncTyped(allocator, frame.module, call.func, arg_values, names, ta.items, call.exact);
            if (pushed_enclosing) popEnclosing();
            switch (try res) {
                .ok => |result| try frame.write(call.dst, result),
                .err => |e| return errResult(e),
            }
        },
        .CallValue => |cv| {
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
            const result = host.callValueNamed(allocator, &callee_v, arg_values_list.items, names_list.items);
            switch (try result) {
                .ok => |rv| try frame.write(cv.dst, rv),
                .err => |e| return errResult(e),
            }
        },
        .CallValueWithThis => |cvt| {
            const callee_v = frame.read(cvt.callee);
            const recv = frame.read(cvt.receiver);
            const arg_values = try readArgRun(allocator, frame, cvt.args, cvt.n_args);
            defer allocator.free(arg_values);
            const names = try resolveArgNames(allocator, frame.module, cvt.arg_names);
            defer allocator.free(names);
            switch (try host.callValueWithThis(allocator, &callee_v, &recv, arg_values, names)) {
                .ok => |rv| try frame.write(cvt.dst, rv),
                .err => |e| return errResult(e),
            }
        },
        .CallSpread => |cs| {
            const callee_v = frame.read(cs.callee);
            var arg_values: std.ArrayList(Value) = .empty;
            defer arg_values.deinit(allocator);
            var effective_names: std.ArrayList(?[]const u8) = .empty;
            defer effective_names.deinit(allocator);
            const in_names = try resolveArgNames(allocator, frame.module, cs.arg_names);
            defer allocator.free(in_names);
            for (cs.parts, 0..) |part, i| {
                const v = frame.read(part.reg);
                const name: ?[]const u8 = if (i < in_names.len) in_names[i] else null;
                if (part.is_spread) {
                    switch (try spreadItems(allocator, &v)) {
                        .ok => |items| {
                            defer allocator.free(items);
                            for (items) |item| {
                                try arg_values.append(allocator, item);
                                try effective_names.append(allocator, null);
                            }
                        },
                        .err => |e| return errResult(e),
                    }
                } else {
                    try arg_values.append(allocator, v);
                    try effective_names.append(allocator, name);
                }
            }
            switch (try host.callValueNamed(allocator, &callee_v, arg_values.items, effective_names.items)) {
                .ok => |rv| try frame.write(cs.dst, rv),
                .err => |e| return errResult(e),
            }
        },
        .CallSuper => |csup| {
            const recv = frame.read(csup.receiver);
            const owner_str = constStr(frame.module, csup.owner_class) orelse
                return errResult(.{ .Type = "CallSuper: owner not a string const" });
            const qual_str: ?[]const u8 = if (csup.qualifier) |id| constStr(frame.module, id) else null;
            const name_str = constStr(frame.module, csup.name) orelse
                return errResult(.{ .Type = "CallSuper: name not a string const" });
            const arg_values = try readArgRun(allocator, frame, csup.args, csup.n_args);
            defer allocator.free(arg_values);
            const names = try resolveArgNames(allocator, frame.module, csup.arg_names);
            defer allocator.free(names);
            switch (try host.callSuper(allocator, &recv, owner_str, qual_str, name_str, arg_values, names)) {
                .ok => |rv| try frame.write(csup.dst, rv),
                .err => |e| return errResult(e),
            }
        },
        .CallMemberOrGlobal => |cmg| return execCallMemberOrGlobal(H, allocator, frame, cmg, host),
        .CallMember => |cm| {
            const recv = frame.read(cm.receiver);
            const name_str = constStr(frame.module, cm.name) orelse
                return errResult(.{ .Type = "CallMember: name not a string const" });
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
            const res = if (static_recv) |sname|
                host.callMemberNamedStatic(allocator, &recv, name_str, arg_values, names, sname)
            else
                host.callMemberNamed(allocator, &recv, name_str, arg_values, names);
            if (pushed_enclosing) popEnclosing();
            switch (try res) {
                .ok => |rv| try frame.write(cm.dst, rv),
                .err => |e| return errResult(e),
            }
        },
        .CallMemberOrValue => |cmv| {
            const recv = frame.read(cmv.receiver);
            const user_args = try readArgRun(allocator, frame, cmv.args, cmv.n_args);
            defer allocator.free(user_args);
            const names = try resolveArgNames(allocator, frame.module, cmv.arg_names);
            defer allocator.free(names);
            const name_str = constStr(frame.module, cmv.name) orelse
                return errResult(.{ .Type = "CallMemberOrValue: name not a string const" });
            if (host.hostHasMember(&recv, name_str)) {
                orAudit("CallMemberOrValue", name_str, "member", 0, &recv);
                switch (try host.callMemberNamed(allocator, &recv, name_str, user_args, names)) {
                    .ok => |rv| try frame.write(cmv.dst, rv),
                    .err => |e| return errResult(e),
                }
            } else {
                orAudit("CallMemberOrValue", name_str, "value", -1, &recv);
                const fb = frame.read(cmv.fallback);
                switch (try host.callValueWithThis(allocator, &fb, &recv, user_args, names)) {
                    .ok => |rv| try frame.write(cmv.dst, rv),
                    .err => |e| return errResult(e),
                }
            }
        },
        .CallValueOrMember => |cvm| {
            const callee_v = frame.read(cvm.callee);
            const arg_values = try readArgRun(allocator, frame, cvm.args, cvm.n_args);
            defer allocator.free(arg_values);
            const names = try resolveArgNames(allocator, frame.module, cvm.arg_names);
            defer allocator.free(names);
            const invocable = switch (callee_v) {
                .Function, .Intrinsic, .IrClosure, .BoundMethod, .BoundUserMethod => true,
                .Instance => |i| blk: {
                    const g = i.borrow();
                    defer g.deinit();
                    const cg = g.get().class.borrow();
                    defer cg.deinit();
                    const cls = cg.get().name;
                    if (frame.module.registry.hierarchy_methods.get(cls)) |mset| {
                        break :blk mset.contains("invoke");
                    }
                    break :blk false;
                },
                else => false,
            };
            if (invocable) {
                if (orAuditOn()) {
                    const name_str = constStr(frame.module, cvm.name) orelse "?";
                    orAudit("CallValueOrMember", name_str, "value", -1, null);
                }
                switch (try host.callValueNamed(allocator, &callee_v, arg_values, names)) {
                    .ok => |rv| try frame.write(cvm.dst, rv),
                    .err => |e| return errResult(e),
                }
            } else {
                const recv = frame.read(cvm.this_recv);
                const name_str = constStr(frame.module, cvm.name) orelse
                    return errResult(.{ .Type = "CallValueOrMember: name not a string const" });
                orAudit("CallValueOrMember", name_str, "member", 0, &recv);
                switch (try host.callMemberNamed(allocator, &recv, name_str, arg_values, names)) {
                    .ok => |rv| try frame.write(cvm.dst, rv),
                    .err => |e| return errResult(e),
                }
            }
        },
        .NewInstance => |ni| {
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
                .err => |e| return errResult(e),
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
                    const g = inst_ref.borrowMut();
                    defer g.deinit();
                    g.get().outer = outer_hint.?;
                }
            }
            try frame.write(ni.dst, result);
        },
        .InstanceOf => |io| {
            const v = frame.read(io.src);
            const is = host.instanceOf(&v, io.ty);
            try frame.write(io.dst, .{ .Bool = is });
        },
        .Cast => |cast| {
            const v = frame.read(cast.src);
            if (host.instanceOf(&v, cast.ty)) {
                try frame.write(cast.dst, v);
            } else if (typeParamCastPasses(H, frame, cast.ty, host)) {
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
                    .fqn = try StringRef.init(allocator, "kotlin.ClassCastException"),
                    .message = try StringRef.init(allocator, msg),
                    .cause = null,
                } };
                return errResult(.{ .Throw = exc });
            }
        },
        .Lambda => |lam| {
            const cap_values = try readRegSlice(allocator, frame, lam.captures);
            defer allocator.free(cap_values);
            switch (try host.buildClosure(allocator, frame.module, lam.body_func, cap_values)) {
                .ok => |v| try frame.write(lam.dst, v),
                .err => |e| return errResult(e),
            }
        },
        .AstLambda => |al| {
            const cap_values = try readRegSlice(allocator, frame, al.captures);
            defer allocator.free(cap_values);
            switch (try host.buildAstLambdaWithFlagFuncid(allocator, frame.module, al.params, &al.body_ast, al.captured_names, cap_values, al.absorb_return, al.body_func)) {
                .ok => |v| try frame.write(al.dst, v),
                .err => |e| return errResult(e),
            }
        },
        .RegisterClass => |rc| {
            const cap_values = try readRegSlice(allocator, frame, rc.captures);
            defer allocator.free(cap_values);
            switch (try host.registerClassCaptured(allocator, rc.class, rc.captured_names, cap_values)) {
                .ok => {},
                .err => |e| return errResult(e),
            }
        },
        .BuildObject => |bobj| {
            const cap_values = try readRegSlice(allocator, frame, bobj.captures);
            defer allocator.free(cap_values);
            switch (try host.buildObject(allocator, bobj.ast, bobj.captured_names, cap_values, bobj.scope_renames)) {
                .ok => |v| try frame.write(bobj.dst, v),
                .err => |e| return errResult(e),
            }
        },
        .StoreGlobal => |sg| {
            const name_str = constStr(frame.module, sg.name) orelse
                return errResult(.{ .Type = "StoreGlobal: name not a string const" });
            const v = frame.read(sg.value);
            switch (try host.storeGlobal(allocator, name_str, v)) {
                .ok => {},
                .err => |e| return errResult(e),
            }
        },
        .StoreToThisOrGlobal => |stg| {
            const name_str = constStr(frame.module, stg.name) orelse
                return errResult(.{ .Type = "StoreToThisOrGlobal: name not a string const" });
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
                const cands = try implicitCandidatesAlloc(H, allocator, frame, stg.this_idx, false, host, name_str);
                defer allocator.free(cands);
                for (cands) |c| {
                    if (c.v != .Instance or !host.hostHasProperty(&c.v, name_str)) continue;
                    orAudit("StoreToThisOrGlobal", name_str, "member", c.depth, &c.v);
                    switch (try host.setField(allocator, &c.v, name_str, v)) {
                        .ok => {},
                        .err => |e| return errResult(e),
                    }
                    routed = true;
                    break;
                }
            }
            if (!routed) {
                orAudit("StoreToThisOrGlobal", name_str, "global", -1, null);
                switch (try host.storeGlobal(allocator, name_str, v)) {
                    .ok => {},
                    .err => |e| return errResult(e),
                }
            }
        },
        .LoadGlobal => |lg| {
            const name_str = constStr(frame.module, lg.name) orelse
                return errResult(.{ .Type = "LoadGlobal: name not a string const" });
            // A lowering-resolved identity binds that exact declaration;
            // the name string is only the unresolved-shape fallback.
            const by_id: ?Value = if (lg.func != null or lg.class != null)
                host.lookupGlobalById(allocator, lg.func, lg.class)
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
            } else {
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                return errResult(.{ .Unbound = msg });
            }
            try frame.write(lg.dst, v);
        },
        .LoadCapture => |lc| {
            const v = if (lc.idx < frame.captures.items.len) frame.captures.items[lc.idx] else Value.Unit;
            try frame.write(lc.dst, v);
        },
        .LoadFromThisOrGlobal => |lt| {
            const name_str = constStr(frame.module, lt.name) orelse
                return errResult(.{ .Type = "LoadFromThisOrGlobal: name not a string const" });
            var resolved: ?Value = null;
            {
                // `consult_param = true`: in a method / extension body the
                // implicit receiver is the frame's `this` *parameter*, not
                // a capture slot.
                const cands = try implicitCandidatesAlloc(H, allocator, frame, lt.this_idx, true, host, stripScopeGetter(name_str));
                defer allocator.free(cands);
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
                        .err => {},
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
                host.lookupGlobalById(allocator, lt.func, lt.class)
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
                            const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{bare_name});
                            return errResult(.{ .Unbound = msg });
                        }
                    },
                    .err => |e| return errResult(e),
                }
            }
            try frame.write(lt.dst, v);
        },
        .Index => |ix| {
            const recv = frame.read(ix.receiver);
            const i = frame.read(ix.index);
            switch (try host.callMember(allocator, &recv, "get", &.{i})) {
                .ok => |rv| try frame.write(ix.dst, rv),
                .err => |e| return errResult(e),
            }
        },
        .IndexSet => |ixs| {
            const recv = frame.read(ixs.receiver);
            const i = frame.read(ixs.index);
            const v = frame.read(ixs.value);
            switch (try host.callMember(allocator, &recv, "set", &.{ i, v })) {
                .ok => {},
                .err => |e| return errResult(e),
            }
        },
        .NewList => |nl| {
            const items = try readArgRun(allocator, frame, nl.args, nl.n_args);
            var list: std.ArrayList(Value) = .empty;
            try list.appendSlice(allocator, items);
            allocator.free(items);
            try frame.write(nl.dst, .{ .List = .{
                .items = try ValueList.init(allocator, list),
                .mutable = false,
                .enum_class = null,
                .backing = null,
            } });
        },
        .QualifiedThis => |qt| {
            const recv = frame.read(qt.receiver);
            const qual_str = constStr(frame.module, qt.qualifier) orelse
                return errResult(.{ .Type = "QualifiedThis: qualifier not a string const" });
            switch (try host.qualifiedThis(allocator, &recv, qual_str)) {
                .ok => |v| try frame.write(qt.dst, v),
                .err => |e| return errResult(e),
            }
        },
        .PropertyRef => |pr| {
            const name_str = constStr(frame.module, pr.name) orelse
                return errResult(.{ .Type = "PropertyRef: name not a string const" });
            try frame.write(pr.dst, .{ .PropertyRef = .{ .name = try StringRef.init(allocator, name_str) } });
        },
        .MemberRef => |mr| {
            const recv = frame.read(mr.receiver);
            const name_str = constStr(frame.module, mr.name) orelse
                return errResult(.{ .Type = "MemberRef: name not a string const" });
            switch (try host.memberRef(allocator, &recv, name_str)) {
                .ok => |v| try frame.write(mr.dst, v),
                .err => |e| return errResult(e),
            }
        },
    }
    return ok(.Unit);
}

/// `name(args)` where lowering could not classify the bare callee as
/// member-vs-global. Mirrors Kotlin's call resolution for an implicit
/// receiver: each candidate receiver is searched innermost-first, members
/// and applicable extensions per receiver (pinned by the
/// `inner_ext_over_outer_member` kotlinc parity fixture), then the
/// top-level tiers — runtime overload selection, the lowering-resolved
/// constructor class, the global by name — and only then an error.
fn execCallMemberOrGlobal(comptime H: type, allocator: Allocator, frame: *Frame, cmg: anytype, host: *H) Allocator.Error!EvalResult {
    const name_str = constStr(frame.module, cmg.name) orelse
        return errResult(.{ .Type = "CallMemberOrGlobal: name not a string const" });
    const arg_values = try readArgRun(allocator, frame, cmg.args, cmg.n_args);
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cmg.arg_names);
    defer allocator.free(names);
    // The receiver is the lambda capture slot, or — when that is empty —
    // the enclosing function's `this` *parameter*.
    const this_val = implicitThisValue(frame, cmg.this_idx, true);
    // A bare callee whose name starts uppercase is a constructor / type,
    // never an instance member.
    const is_ctor_name = name_str.len > 0 and std.ascii.isUpper(name_str[0]);
    var resolved: ?Value = null;
    var first_real_err: ?EvalError = null;
    // A bare `name` bound to a captured callable in the innermost
    // scoped-global layer is a closed-over parameter/local that shadows
    // a same-named member, but a genuine member of the implicit receiver
    // still wins over an over-captured scoped global.
    const shadow_capture = host.isShadowingCapture(name_str) and
        ((this_val == .Null or this_val == .Unit) or !host.hostHasMember(&this_val, name_str));

    if (!is_ctor_name and !shadow_capture) {
        const cands = try implicitCandidatesAlloc(H, allocator, frame, cmg.this_idx, true, host, name_str);
        defer allocator.free(cands);
        // Inside an extension body, the implicit `this` has the
        // extension's DECLARED receiver type, and Kotlin resolves a bare
        // extension call against that static type — not the runtime
        // value's type, which may be a subtype carrying its own
        // same-name extension. Hand the declared head to the strict
        // probe for exactly that candidate.
        const static_recv_ty: ?[]const u8 = blk: {
            switch (frame.func.kind) {
                .top_level_extension, .member_extension => {},
                else => break :blk null,
            }
            const idx = frameThisParam(frame) orelse break :blk null;
            break :blk frame.func.params[idx].ty.name;
        };
        // Strict pass: members and receiver-compatible extensions of each
        // candidate, innermost first — the kotlinc candidate order.
        for (cands) |c| {
            const hint: ?[]const u8 = if (static_recv_ty != null and sameReceiver(c.v, this_val))
                static_recv_ty
            else
                null;
            switch (try host.callMemberStrictExt(allocator, &c.v, name_str, arg_values, names, hint)) {
                .ok => |v| {
                    orAudit("CallMemberOrGlobal", name_str, "member", c.depth, &c.v);
                    resolved = v;
                    break;
                },
                .err => |e| switch (e) {
                    .Suspended, .CalleeFailed => return errResult(e),
                    // Control flow out of a body that RAN: the candidate
                    // was the real callee (a `synchronized { return x }`
                    // non-local return, a thrown exception). Walking on
                    // would re-execute its side effects on an outer
                    // receiver — same doctrine as `CalleeFailed`.
                    .Throw, .NonLocalReturn, .LabeledReturn => return errResult(e),
                    .Unimplemented => {},
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
            for (cands) |c| {
                switch (try host.callMemberNamed(allocator, &c.v, name_str, arg_values, names)) {
                    .ok => |v| {
                        orAudit("CallMemberOrGlobal", name_str, "member_lenient", c.depth, &c.v);
                        resolved = v;
                        break;
                    },
                    .err => |e| switch (e) {
                        .Suspended, .CalleeFailed => return errResult(e),
                        // Same as the strict pass: a body that ran owns
                        // its control flow; never re-probe.
                        .Throw, .NonLocalReturn, .LabeledReturn => return errResult(e),
                        .Unimplemented => {},
                        else => if (first_real_err == null) {
                            first_real_err = e;
                        },
                    },
                }
            }
        }
    }
    var result: Value = undefined;
    if (resolved) |v| {
        result = v;
    } else {
        // Overloaded top-level function: select by runtime arg types
        // before falling back to the single global value baked in at
        // lower time.
        const overload = switch (try host.callNamedOverload(allocator, frame.module, name_str, arg_values, names)) {
            .ok => |maybe| maybe,
            .err => |e| return errResult(e),
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
            const by_id: ?Value = if ((cmg.class != null or cmg.func != null) and
                !host.isShadowingCapture(name_str))
                host.lookupGlobalById(allocator, cmg.func, cmg.class)
            else
                null;
            const global = if (by_id != null) by_id else switch (try host.lookupGlobalThrowing(allocator, name_str)) {
                .ok => |maybe| maybe,
                .err => |e| return errResult(e),
            };
            if (global) |callee| {
                orAudit("CallMemberOrGlobal", name_str, if (by_id != null) "global_id" else "global", -1, null);
                switch (try host.callValueNamed(allocator, &callee, arg_values, names)) {
                    .ok => |v| result = v,
                    .err => |e| return errResult(e),
                }
            } else {
                if (first_real_err) |fre| return errResult(fre);
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                return errResult(.{ .Unbound = msg });
            }
        }
    }
    try frame.write(cmg.dst, result);
    return ok(.Unit);
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

/// Index of the frame's `this` parameter, if any.
fn frameThisParam(frame: *const Frame) ?usize {
    for (frame.func.params, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, "this")) return i;
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
    for (frame.func.capture_order, 0..) |n, i| {
        if (std.mem.eql(u8, n, "this")) {
            if (i < frame.captures.items.len and frame.captures.items[i] == .Instance) {
                return frame.captures.items[i];
            }
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
/// `captures[this_idx]` if in range, else `Null`. When `consult_param` is
/// set and the capture slot did not yield an instance receiver, fall back
/// to the frame's `this` *parameter* (the call form needs this; the bare
/// read/write forms carry the receiver in the capture slot only).
fn implicitThisValue(frame: *const Frame, this_idx: usize, consult_param: bool) Value {
    var this_val: Value = if (this_idx < frame.captures.items.len)
        frame.captures.items[this_idx]
    else
        Value.Null;
    if (consult_param and (this_val == .Null or this_val == .Unit)) {
        if (frameThisParam(frame)) |idx| {
            if (idx < frame.params.items.len) this_val = frame.params.items[idx];
        }
    }
    return this_val;
}

/// One candidate receiver for a bare-name `*OrGlobal` resolution. `depth`
/// is the candidate's position in the search order (0 = the frame's own
/// implicit `this`), recorded for the KLIO_OR_AUDIT readout.
const ImplicitCandidate = struct {
    v: Value,
    depth: u16,
};

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
fn implicitCandidatesAlloc(comptime H: type, allocator: Allocator, frame: *const Frame, this_idx: usize, consult_param: bool, host: *H, bare_name: []const u8) Allocator.Error![]ImplicitCandidate {
    var out: std.ArrayList(ImplicitCandidate) = .empty;
    errdefer out.deinit(allocator);
    const this_val = implicitThisValue(frame, this_idx, consult_param);
    const entries = try enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    var depth: u16 = 0;
    if (this_val != .Null and this_val != .Unit) {
        // When the frame's own `this` is also the innermost chain entry
        // (a seeded method/extension receiver, or a receiver-split
        // subject), the entry's own run covers it with the right kind.
        const dup = entries.len > 0 and sameReceiver(entries[0].v, this_val);
        if (!dup) {
            // The frame's own `this` brings its class-nesting tower (and
            // companion) only when it is a *dispatch* receiver. An
            // extension receiver is subject-like — `fun Owner.Inner.f()`
            // does not put `Inner`'s enclosing `Owner` instance or
            // companion in scope.
            const own_is_subject = switch (frame.func.kind) {
                .top_level_extension, .member_extension => true,
                else => false,
            };
            try appendCandidateRun(H, allocator, &out, this_val, own_is_subject, &depth, host, bare_name);
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
fn readArgRun(allocator: Allocator, frame: *const Frame, args_start: Reg, n: u8) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        out[i] = frame.read(Reg.from(args_start.int() + i));
    }
    return out;
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
        .Array, .List, .Set => {
            const items_ref = switch (v.*) {
                .Array => |a| a.items,
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
    var lhs = constToValueNoAlloc(&module.consts.items[id.int()]);
    return Value.structuralEq(&lhs, v);
}

/// `const_to_value` for non-String consts: avoids an allocator when the
/// caller only compares structurally. String consts are not produced by
/// switch keys, so this is sufficient for `constMatches`.
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
            .Double => |d| return ok(.{ .Double = -d }),
            .Float => |f| return ok(.{ .Float = -f }),
            else => {},
        },
        .Plus => return ok(v.*),
        .Inc => switch (v.*) {
            .Int => |i| return ok(.{ .Int = i +% 1 }),
            .Long => |l| return ok(.{ .Long = l +% 1 }),
            .Float => |f| return ok(.{ .Float = f + 1.0 }),
            .Double => |d| return ok(.{ .Double = d + 1.0 }),
            .Char => |c| return ok(.{ .Char = c +% 1 }),
            else => {},
        },
        .Dec => switch (v.*) {
            .Int => |i| return ok(.{ .Int = i -% 1 }),
            .Long => |l| return ok(.{ .Long = l -% 1 }),
            .Float => |f| return ok(.{ .Float = f - 1.0 }),
            .Double => |d| return ok(.{ .Double = d - 1.0 }),
            .Char => |c| return ok(.{ .Char = c -% 1 }),
            else => {},
        },
    }
    const s = v.display(allocator) catch "?";
    const msg = try std.fmt.allocPrint(allocator, "UnOp.{s} on {s}", .{ @tagName(op), s });
    return errResult(.{ .Type = msg });
}

/// Render a Value to its Kotlin string representation. For
/// `Value.Instance`, dispatches `toString()` through the host so
/// user-defined overrides fire; primitives use `renderValue`'s fast
/// path. Caller owns the returned string.
fn stringify(comptime H: type, allocator: Allocator, host: *H, v: *const Value) Allocator.Error!union(enum) { ok: []const u8, err: EvalError } {
    if (v.* == .Instance) {
        switch (try host.callMember(allocator, v, "toString", &.{})) {
            .ok => |result| {
                if (result == .String) {
                    const g = result.String.borrow();
                    defer g.deinit();
                    return .{ .ok = try allocator.dupe(u8, g.get().*) };
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

fn operatorMethod(op: BinOp) ?[]const u8 {
    return switch (op) {
        .Add => "plus",
        .Sub => "minus",
        .Mul => "times",
        .Div => "div",
        .Mod => "rem",
        .Eq => "equals",
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
/// string templates do. Mirrors the Rust `render_value`.
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
            break :blk allocator.dupe(u8, g.get().*);
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
        .fqn = try StringRef.init(allocator, "kotlin.ArithmeticException"),
        .message = try StringRef.init(allocator, msg),
        .cause = null,
    } } };
}

/// Kotlin's defined numeric conversions and operator semantics.
fn applyBinop(allocator: Allocator, op: BinOp, l: *const Value, r: *const Value) Allocator.Error!EvalResult {
    // Kotlin promotes `Byte`/`Short` to `Int` in arithmetic and
    // comparison. Widen and re-dispatch.
    if ((promoteByteShort(l) != null or promoteByteShort(r) != null) and op != .StringConcat) {
        const nl = promoteByteShort(l) orelse l.*;
        const nr = promoteByteShort(r) orelse r.*;
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
                const s = try std.mem.concat(allocator, u8, &.{ g.get().*, rs });
                return ok(.{ .String = try StringRef.init(allocator, s) });
            }
            if (r.* == .String) {
                const ls = try renderValue(allocator, l);
                defer allocator.free(ls);
                const g = r.String.borrow();
                defer g.deinit();
                const s = try std.mem.concat(allocator, u8, &.{ ls, g.get().* });
                return ok(.{ .String = try StringRef.init(allocator, s) });
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
        },
        .Eq => return ok(.{ .Bool = Value.structuralEq(l, r) }),
        .NotEq => return ok(.{ .Bool = !Value.structuralEq(l, r) }),
        .BoxedEq => return ok(.{ .Bool = Value.structuralEqBoxed(l, r) }),
        .BoxedNotEq => return ok(.{ .Bool = !Value.structuralEqBoxed(l, r) }),
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
            return ok(.{ .String = try StringRef.init(allocator, s) });
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
    if (l.* == .UInt and r.* == .UInt) return Pair.cmpOrder(op, std.math.order(l.UInt, r.UInt));
    if (l.* == .ULong and r.* == .ULong) return Pair.cmpOrder(op, std.math.order(l.ULong, r.ULong));
    if (l.* == .UShort and r.* == .UShort) return Pair.cmpOrder(op, std.math.order(l.UShort, r.UShort));
    if (l.* == .UByte and r.* == .UByte) return Pair.cmpOrder(op, std.math.order(l.UByte, r.UByte));
    // Mixed Int/Long.
    if (l.* == .Int and r.* == .Long) return Pair.cmpOrder(op, std.math.order(@as(i64, l.Int), r.Long));
    if (l.* == .Long and r.* == .Int) return Pair.cmpOrder(op, std.math.order(l.Long, @as(i64, r.Int)));
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
        return Pair.cmpOrder(op, utf16Cmp(lg.get().*, rg.get().*));
    }
    return null;
}

/// Build a `Range` value for `..` / `..<`. Returns `null` for unhandled
/// operand pairings.
fn rangeValue(op: BinOp, l: *const Value, r: *const Value) ?Value {
    const minus_one: i64 = if (op == .RangeUntil) 1 else 0;
    if (l.* == .Int and r.* == .Int) {
        return .{ .Range = .{ .start = @as(i64, l.Int), .end = @as(i64, r.Int) - minus_one, .step = 1, .kind = .Int } };
    }
    if (l.* == .Char and r.* == .Char) {
        return .{ .Range = .{ .start = @as(i64, l.Char), .end = @as(i64, r.Char) - minus_one, .step = 1, .kind = .Char } };
    }
    if (l.* == .Long and r.* == .Long) {
        return .{ .Range = .{ .start = l.Long, .end = r.Long - minus_one, .step = 1, .kind = .Long } };
    }
    if (l.* == .Int and r.* == .Long) {
        return .{ .Range = .{ .start = @as(i64, l.Int), .end = r.Long - minus_one, .step = 1, .kind = .Long } };
    }
    if (l.* == .Long and r.* == .Int) {
        return .{ .Range = .{ .start = l.Long, .end = @as(i64, r.Int) - minus_one, .step = 1, .kind = .Long } };
    }
    return null;
}

fn promoteByteShort(v: *const Value) ?Value {
    return switch (v.*) {
        .Byte => |b| .{ .Int = @as(i32, b) },
        .Short => |s| .{ .Int = @as(i32, s) },
        else => null,
    };
}

fn widenFloat(v: *const Value) Value {
    return switch (v.*) {
        .Float => |f| .{ .Double = @as(f64, f) },
        else => v.*,
    };
}

/// Rust `wrapping_div`: truncating integer division with `MIN / -1`
/// wrapping to `MIN`.
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
/// (`Unsupported`/`null`/`false`/empty), so all dispatch paths behave
/// exactly like Rust's `NullHost`. The evaluator is generic over the host
/// type and calls these as plain comptime-duck-typed methods.
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

    pub fn callMemberStrictExt(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
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

    pub fn companionWithMember(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?Value {
        _ = .{ self, allocator, receiver, name };
        return null;
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

    pub fn lookupGlobalById(self: *NullHost, allocator: Allocator, func: ?FuncId, class: ?ClassId) ?Value {
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

    pub fn buildObject(self: *NullHost, allocator: Allocator, ast: *const @import("ast").Expr, captured_names: []const []const u8, captures: []const Value, scope_renames: []const ir.ScopeRename) Allocator.Error!EvalResult {
        _ = .{ self, allocator, ast, captured_names, captures, scope_renames };
        return errResult(.{ .Unsupported = "Host.build_object" });
    }

    pub fn callValueWithThis(self: *NullHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, callee, this_value, args, arg_names };
        return errResult(.{ .Unsupported = "Host.call_value_with_this" });
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
        if (func.int() >= module.funcs.items.len) {
            const msg = try std.fmt.allocPrint(allocator, "unknown FuncId {d}", .{func.int()});
            return errResult(.{ .Type = msg });
        }
        const f = &module.funcs.items[func.int()];
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

    pub fn callNamedOverload(self: *NullHost, allocator: Allocator, module: *const Module, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!MaybeValueResult {
        _ = .{ self, allocator, module, name, args, arg_names };
        return .{ .ok = null };
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

// -------------------------------------------------------------------------
// Tests (mirrors the Rust crate's `eval.rs` `mod tests`)
// -------------------------------------------------------------------------

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

test "enclosing chain tags subjects and projects innermost-first" {
    var chain: std.ArrayList(EnclosingEntry) = .empty;
    defer chain.deinit(chainAllocator());
    const prev = active_chain;
    active_chain = &chain;
    defer active_chain = prev;

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
    const prev = active_chain;
    active_chain = null;
    defer active_chain = prev;

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
