//! Evaluator entry points: argument coercion, the `eval*` family, and the
//! frame boundary that converts a non-local return into a value.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const jit_loop = @import("../jit_loop.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const Func = ir.Func;
const Module = ir.Module;
const TypeRef = ir.TypeRef;

const exec_call = @import("../exec_call.zig");

const constStr = exec_call.constStr;

const ev_activation = @import("activation.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_fused = @import("fused.zig");
const ev_host = @import("host.zig");
const ev_leaf = @import("leaf.zig");
const ev_loop = @import("loop.zig");
const ev_native = @import("native.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const EnclosingEntry = ev_state.EnclosingEntry;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const Frame = ev_frame.Frame;
const LEAF_MAX_DEPTH = ev_leaf.LEAF_MAX_DEPTH;
const LoopTramp = ev_loop.LoopTramp;
const NATIVE_SLOT_BANK_DEPTH = ev_state.NATIVE_SLOT_BANK_DEPTH;
const NullHost = ev_host.NullHost;
const TryFrame = ev_snapshot.TryFrame;
const callStatsBumpId = ev_diag.callStatsBumpId;
const currentFrameFunc = ev_state.currentFrameFunc;
const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
const errResult = ev_flow.errResult;
const fusedExecOpt = ev_fused.fusedExecOpt;
const gcPopFrame = ev_state.gcPopFrame;
const gcPushFrame = ev_state.gcPushFrame;
const leafExprServeAt = ev_leaf.leafExprServeAt;
const lrTraceOn = ev_flow.lrTraceOn;
const nativeFor = ev_native.nativeFor;
const nativeModuleOk = ev_native.nativeModuleOk;
const nullHost = ev_host.nullHost;
const ok = ev_flow.ok;
const runFrame = ev_activation.runFrame;

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
pub fn coerceIntArgsToLong(func: *const Func, params: []Value) void {
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
pub fn coercePlanFor(module: *const Module, func: *const Func) u8 {
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

pub fn coerceGenericIntPeersToLong(module: *const Module, func: *const Func, params: []Value) void {
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
pub fn leafPrimitive(v: *const Value) bool {
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
pub fn funcOwnedBy(module: *const Module, func: *const Func) bool {
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
pub fn nearestFinally(try_stack: *std.ArrayList(TryFrame), cur: BlockId) ?struct { jump: BlockId, key: BlockId } {
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
pub fn unwindTerminal(frame: *Frame, e: EvalError) EvalResult {
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
                ev_state.evtls.jit_native_depth < NATIVE_SLOT_BANK_DEPTH and cl.n_slots <= 192)
            {
                const fslots: []i64 = &ev_state.native_slot_bank[ev_state.evtls.jit_native_depth];
                const ftags: []u8 = &ev_state.native_tag_bank[ev_state.evtls.jit_native_depth];
                ev_state.evtls.jit_native_depth += 1;
                const fo = jit_loop.runFunc(cl, &.{}, args.items, fslots[0..cl.n_slots], ftags[0..cl.n_regs], null, null);
                ev_state.evtls.jit_native_depth -= 1;
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
    const ev: *EvalTls = &ev_state.evtls;
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
pub fn frameBoundary(func: *const Func, result_in: EvalResult) EvalResult {
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
