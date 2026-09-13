//! Callee analysis for inlining and direct calls: block ordering and the
//! inlinability gates, the self-inline and direct-compile paths, receiver
//! class sets for monomorphic member calls, and instruction remapping.

const runtime = @import("runtime");
const ir = @import("../ir.zig");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const type_infer = @import("types.zig");
const loop_shape = @import("loop_shape.zig");
const run_mod = @import("run.zig");
const code_cache = @import("cache.zig");

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Reg = ir.Reg;
const BlockId = ir.BlockId;

const compileCalleeForCall = code_cache.compileCalleeForCall;
const CompiledLoop = common.CompiledLoop;
const RegType = common.RegType;
const typeAt = loop_shape.typeAt;
const valueFromSlot = run_mod.valueFromSlot;
const FieldResolver = shapes.FieldResolver;
const MemberResolver = shapes.MemberResolver;
const VirtResolver = shapes.VirtResolver;
const arrayOpOf = shapes.arrayOpOf;
const bitwiseOpOf = shapes.bitwiseOpOf;
const isDivBinOp = shapes.isDivBinOp;
const memberFieldName = shapes.memberFieldName;
const numericConvOf = shapes.numericConvOf;
const trampolinableFieldOf = shapes.trampolinableFieldOf;
const trampolinableFieldSetOf = shapes.trampolinableFieldSetOf;
const funcReturnRegType = type_infer.funcReturnRegType;
const instanceClassIdentity = type_infer.instanceClassIdentity;
const isScalarRt = type_infer.isScalarRt;
const liveElementAt = type_infer.liveElementAt;
const retRegType = type_infer.retRegType;

const INLINE_MAX_INSTS: usize = 24;
pub const INLINE_MAX_BLOCKS: usize = 8;
/// Upper bound on a splice candidate's block count, so the reachability scan
/// and the emitter's per-block label table are fixed-size.
pub const CALLEE_BLOCK_LIMIT: usize = 64;

/// The blocks a splice covers: those reachable from the callee's entry, entry
/// first then ascending index. Null when the callee has an unsupported
/// terminator, a bad edge, or more blocks than the splice's budget. Blocks that
/// are unreachable never reach the emitter, so their shape does not matter.
pub fn calleeBlockOrder(f: *const Func, buf: []u32) ?[]u32 {
    if (f.blocks.len == 0 or f.blocks.len > CALLEE_BLOCK_LIMIT) return null;
    const entry = f.entry.int();
    if (entry >= f.blocks.len) return null;
    var reach = [_]bool{false} ** CALLEE_BLOCK_LIMIT;
    var stack: [CALLEE_BLOCK_LIMIT]u32 = undefined;
    var sp: usize = 0;
    reach[entry] = true;
    stack[sp] = entry;
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const blk = &f.blocks[stack[sp]];
        var succ: [2]u32 = undefined;
        var n_succ: usize = 0;
        switch (blk.terminator) {
            .Goto => |t| {
                succ[0] = t.int();
                n_succ = 1;
            },
            .Branch => |br| {
                succ[0] = br.t.int();
                succ[1] = br.f.int();
                n_succ = 2;
            },
            .Return => {},
            else => return null,
        }
        for (succ[0..n_succ]) |s| {
            if (s >= f.blocks.len) return null;
            if (reach[s]) continue;
            reach[s] = true;
            stack[sp] = s;
            sp += 1;
        }
    }
    if (buf.len == 0) return null;
    buf[0] = entry;
    var n: usize = 1;
    var i: u32 = 0;
    while (i < f.blocks.len) : (i += 1) {
        if (!reach[i] or i == entry) continue;
        if (n >= buf.len) return null;
        buf[n] = i;
        n += 1;
    }
    return buf[0..n];
}

/// Whether a splice-eligible callee delivers a value. `selfInlinableCallee` has
/// already proven every reachable return agrees on this.
pub fn calleeReturnsValue(f: *const Func) bool {
    for (f.blocks) |*b| {
        if (b.terminator == .Return and b.terminator.Return != null) return true;
    }
    return false;
}

/// Whether a top-level callee can be inlined into the native loop: a single block
/// returning a value, made only of scalar instructions (no nested calls, object
/// ops, arrays, cells, or fields), with all-scalar required parameters and a
/// scalar return. Such a body is spliced into the caller's code with its registers
/// remapped, eliminating the call entirely.
pub fn inlinableCallee(module: *const Module, f: *const Func) bool {
    if (f.is_suspend or f.has_receiver_param) return false;
    if (f.blocks.len != 1) return false; // single block, not deferred
    const blk = &f.blocks[0];
    switch (blk.terminator) {
        .Return => |r| if (r == null) return false,
        else => return false,
    }
    for (f.params) |p| {
        if (p.is_vararg or p.default != null) return false;
        if (retRegType(p.ty) == .unknown) return false;
    }
    if (funcReturnRegType(module, f) == .unknown) return false;
    if (blk.insts.len > INLINE_MAX_INSTS) return false;
    for (blk.insts) |*inst| {
        if (numericConvOf(module, inst) != null) continue;
        if (bitwiseOpOf(module, inst) != null) continue;
        if (arrayOpOf(module, inst) != null) return false;
        switch (inst.*) {
            .Const, .Move, .BinOp, .Not, .UnOp, .Trace => {},
            // A parameter load binds to the matching caller argument at inline time.
            .LoadParam => |lp| if (lp.idx >= f.params.len) return false,
            else => return false,
        }
    }
    return true;
}

/// One inlined call: the callee's single block is emitted in place of the call,
/// with its registers shifted by `base` into the caller's extended register space.
/// `args_reg`/`dst` are caller registers; deopts inside the body resume at the
/// original call instruction (`block`,`inst`) so the interpreter re-runs the call.
pub const InlineSite = struct {
    block: BlockId,
    inst: u32,
    callee: *const Func,
    base: u32,
    args_reg: u32,
    n_args: u32,
    dst: Reg,
    /// Member inline: the call's receiver register (the callee's `this`), the
    /// callee register `LoadParam 0` writes (mapped to `recv_reg`, not `base`), and
    /// the contiguous range of field-access call sites the body's GetField/SetField
    /// on `this` were registered as (emitted in body order).
    is_member: bool = false,
    recv_reg: u32 = 0,
    this_reg: u32 = 0,
    field_site_base: u32 = 0,
    n_field_sites: u32 = 0,
    /// Has a value return (false for a `Unit` method invoked for its effect).
    has_result: bool = true,
    /// Where a deopt inside the spliced body resumes: the receiver `Move` this
    /// splice removed. Null for a top-level inline, which removes nothing, so
    /// the call's own position is right.
    resume_at: ?BodyInstPos = null,
    /// One arm of a per-iteration receiver guard: run this body only when the
    /// receiver's class matches `guard_class`. Arms at the same position are
    /// emitted as a chain, and the last miss falls through to `fallback_site`,
    /// the trampoline the call registered. The guard is what makes the arm
    /// SOUND — the class set that chose the arms is only a heuristic.
    guarded: bool = false,
    guard_class: usize = 0,
    fallback_site: u32 = 0,
};

/// The destination register an instruction writes, if any (covering every shape
/// that can appear in a compiled loop body, including object-producing ops that
/// `instReadsDef` deliberately omits). Used to confirm a register is loop-
/// invariant — defined outside the loop, never written inside.
/// The register whose LIVE tag governs `reg`'s rebox at the call at
/// `call_idx`: walk same-block `Move`s backward (arg slots are filled by
/// Moves immediately before their call), redirecting through each; any
/// other definition of the current register terminates the chain there.
pub fn argTagSourceReg(insts: []const Inst, call_idx: usize, reg: u32) u32 {
    var r = reg;
    var i = call_idx;
    while (i > 0) {
        i -= 1;
        const inst = &insts[i];
        if (inst.* == .Move) {
            const mv = inst.Move;
            if (mv.dst.int() == r) {
                r = mv.src.int();
                continue;
            }
        }
        if (instAnyDst(inst)) |d| {
            if (d.int() == r) break;
        }
    }
    return r;
}

/// The register an instruction defines, for every instruction that defines one.
/// Read structurally, not from a hand-kept list: callers use this to prove a
/// register is NOT written in a loop, so an instruction missing from the list
/// reports invariance that is not there. Anything carrying a `dst` is covered.
pub fn instAnyDst(inst: *const Inst) ?Reg {
    return switch (inst.*) {
        inline else => |x| blk: {
            const T = @TypeOf(x);
            if (@typeInfo(T) != .@"struct" or !@hasField(T, "dst")) break :blk null;
            break :blk x.dst;
        },
    };
}

pub fn regWrittenInBody(func: *const Func, body: []const BlockId, r: Reg) bool {
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            if (instAnyDst(inst)) |d| if (d.int() == r.int()) return true;
        }
    }
    return false;
}

/// Whether a member method can be inlined: a single block, all instructions are
/// scalar ops, parameter loads, or `this`-field accesses (get/set of a scalar
/// field on the `LoadParam 0` register), with scalar required parameters and a
/// scalar-or-`Unit` return. `this_reg` receives the register `LoadParam 0` binds.
/// Inline a SELF call — `this.helper(...)`, which the lowerer emits as a static
/// `Call` with the receiver moved into arg 0 — into a compiled method. That Move
/// is what made the whole method uncompilable (a receiver register may appear
/// only as a field-op receiver), so a method delegating to a sibling helper
/// compiled nothing and ran slower than interpreted. Splicing a callee that
/// never touches `this` makes both the Move and the call disappear, and the
/// method still runs frameless at the seam: 1049ms -> 351ms on such a loop.
///
/// `KLIO_FJ_SELF_INLINE=0` disables it. On by default so every corpus and sweep
/// run exercises the path — the reason it stayed off for its first hours is that
/// the corpus contained exactly ONE program that reached it.
var fj_self_inline_cache: ?bool = null;
pub fn fjSelfInlineEnabled() bool {
    if (fj_self_inline_cache) |v| return v;
    const on = if (runtime.envOnce("KLIO_FJ_SELF_INLINE")) |v| !(v.len != 0 and v[0] == '0') else true;
    fj_self_inline_cache = on;
    return on;
}

/// A callee this tier can splice into its caller at a self-call: scalar
/// control flow over the callee's own registers, reading and writing `this`
/// only through the field-site machinery. Refusing any other `this` use is what
/// keeps the receiver out of the compiled body — the register holding it is
/// never materialized, which is the whole reason the caller can compile.
///
/// A callee with branches splices as several blocks: the emitter gives each one
/// a label in the caller's code, so an `if`/`when` helper is as inlinable as a
/// straight-line expression.
pub fn selfInlinableCallee(module: *const Module, f: *const Func, n_args: u32, recv: ?*const Value, field_nn_resolver: ?FieldResolver, resolver_user: ?*anyopaque) bool {
    if (f.is_suspend or f.is_lambda) return false;
    if (!f.has_receiver_param) return false;
    if (f.params.len != n_args) return false;
    var order_buf: [INLINE_MAX_BLOCKS]u32 = undefined;
    const order = calleeBlockOrder(f, &order_buf) orelse return false;
    if (f.n_locals == 0) return false;
    var total_insts: usize = 0;
    var value_rets: usize = 0;
    var void_rets: usize = 0;
    for (order) |b| {
        const blk = &f.blocks[b];
        if (blk.catches.len != 0 or blk.finally != null) return false;
        switch (blk.terminator) {
            .Goto, .Branch => {},
            .Return => |r| if (r != null) {
                value_rets += 1;
            } else {
                void_rets += 1;
            },
            else => return false,
        }
        total_insts += blk.insts.len;
    }
    // A callee whose returns disagree would need the splice to deliver a value
    // on one path and nothing on another; the join has one shape, so decline.
    if (value_rets != 0 and void_rets != 0) return false;
    if (value_rets + void_rets == 0) return false;
    if (total_insts == 0 or total_insts > INLINE_MAX_INSTS) return false;
    for (f.params[1..]) |p| {
        if (p.is_vararg or p.default != null or !isScalarRt(retRegType(p.ty))) return false;
    }
    // A `Unit` method invoked for its effect returns no register — the splice
    // simply produces no result. Requiring a value excluded every mutator
    // (`fun widen(k: Int) { w = w + k }`), which is half the shape this exists
    // for.
    if (value_rets != 0 and !isScalarRt(retRegType(f.return_ty))) return false;
    // The lowerer emits a `LoadParam` for EVERY parameter, so the receiver load
    // is present even in a body that ignores `this`. What matters is that the
    // register it lands in is never read: the emitter skips that load, so a body
    // reading it would see an empty slot.
    var this_dst: ?u32 = null;
    for (order) |b| {
        for (f.blocks[b].insts) |*ci| {
            if (ci.* == .LoadParam and ci.LoadParam.idx == 0) this_dst = ci.LoadParam.dst.int();
            // A `this`-field read or write is fine: the call is a SELF call, so
            // the callee's receiver is the caller's, and the field access rides
            // the caller's own entry field-base. Anything else touching `this`
            // is not.
            if (trampolinableFieldOf(module, ci) != null) continue;
            if (trampolinableFieldSetOf(module, ci) != null) continue;
            // Bitwise and numeric-conversion ops lower to a `CallMember` shape
            // the emitter has a native form for, and neither can deopt.
            if (bitwiseOpOf(module, ci) != null) continue;
            if (numericConvOf(module, ci) != null) continue;
            switch (ci.*) {
                .Const, .Move, .BinOp, .Not, .UnOp, .Trace, .LoadParam => {},
                else => return false,
            }
        }
    }
    if (this_dst) |td| {
        var reads: usize = 0;
        for (order) |b| {
            const blk = &f.blocks[b];
            for (blk.insts) |*ci| {
                if (ci.* == .LoadParam and ci.LoadParam.idx == 0) continue;
                // Field ops name `this` as their receiver by design.
                if (trampolinableFieldOf(module, ci) != null) continue;
                if (trampolinableFieldSetOf(module, ci) != null) continue;
                const Ctx = struct { r: u32, n: *usize };
                var cx = Ctx{ .r = td, .n = &reads };
                ir.visitInstRegs(ci, &cx, struct {
                    fn count(c: *Ctx, rr: Reg, _: bool) void {
                        if (rr.int() == c.r) c.n.* += 1;
                    }
                }.count);
            }
            const Ctx = struct { r: u32, n: *usize };
            var cx = Ctx{ .r = td, .n = &reads };
            ir.visitTerminatorRegs(&blk.terminator, &cx, struct {
                fn count(c: *Ctx, rr: Reg, _: bool) void {
                    if (rr.int() == c.r) c.n.* += 1;
                }
            }.count);
        }
        if (reads != 0) return false;
    }
    // A deopt inside the splice re-runs the whole call, so a callee that WRITES
    // a field must not be able to deopt first: every field it reads has to be a
    // non-nullable scalar, and it must contain no division (whose zero-divisor
    // deopt would otherwise land after the write and apply it twice).
    var writes = false;
    for (order) |b| {
        for (f.blocks[b].insts) |*ci| {
            if (trampolinableFieldSetOf(module, ci) != null) writes = true;
        }
    }
    if (writes) {
        for (order) |b| {
            for (f.blocks[b].insts) |*ci| {
                if (ci.* == .BinOp and isDivBinOp(ci.BinOp.op)) return false;
                if (trampolinableFieldOf(module, ci)) |fld| {
                    const fr = field_nn_resolver orelse return false;
                    const rv = recv orelse return false;
                    if (fr(resolver_user.?, rv, memberFieldName(fld.name)) == null) return false;
                }
            }
        }
    }
    return true;
}

/// `KLIO_FJ_DIRECT=0` disables direct calls between compiled units, so a
/// regression can be bisected against the trampolined form.
var fj_direct_cache: ?bool = null;
pub fn fjDirectEnabled() bool {
    if (fj_direct_cache) |v| return v;
    const on = if (runtime.envOnce("KLIO_FJ_DIRECT")) |v| !(v.len != 0 and v[0] == '0') else true;
    fj_direct_cache = on;
    return on;
}

/// Compile nesting a direct call may trigger: A's compile compiles B, whose
/// compile may compile C. Bounded so a deep helper chain cannot recurse the
/// compiler off the stack.
threadlocal var direct_compile_depth: u32 = 0;
const DIRECT_COMPILE_MAX_DEPTH: u32 = 4;

/// The compiled unit a direct call may target: a deopt-free method body on the
/// same receiver, taking scalar arguments and delivering a scalar or nothing.
/// Deopt-freedom is what makes the call a plain `call` — RETURN is the body's
/// only outcome, so there is no resume point to reconstruct and no frame to
/// own. The callee is compiled on demand, specialized on this receiver and on
/// its own declared parameter kinds.
pub fn directCallTarget(
    module: *const Module,
    cf: *const Func,
    n_args: u32,
    recv: *const Value,
    resolver: ?MemberResolver,
    virt_resolver: ?VirtResolver,
    field_resolver: ?FieldResolver,
    field_nn_resolver: ?FieldResolver,
    resolver_user: ?*anyopaque,
) ?*const CompiledLoop {
    if (cf.is_suspend or cf.is_lambda or !cf.hasBody()) return null;
    if (!cf.has_receiver_param) return null;
    if (n_args == 0 or n_args > 8 or cf.params.len != n_args) return null;
    if (recv.* != .Instance) return null;
    var argv: [8]Value = undefined;
    argv[0] = recv.*;
    for (cf.params[1..], 1..) |pp, i| {
        if (pp.is_vararg or pp.default != null) return null;
        const prt = retRegType(pp.ty);
        if (!isScalarRt(prt)) return null;
        argv[i] = valueFromSlot(prt, 0);
    }
    if (direct_compile_depth >= DIRECT_COMPILE_MAX_DEPTH) return null;
    direct_compile_depth += 1;
    defer direct_compile_depth -= 1;
    const cl = compileCalleeForCall(module, cf, argv[0..n_args], resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user) orelse return null;
    if (!cl.func_mode or !cl.method_mode or cl.has_tramp_sites) return null;
    // A callee that CAN deopt is still reachable: the caller tests the resume
    // code it returns and re-runs the whole call interpreted, exactly as the
    // splice does. That answer is only correct while the callee has changed
    // nothing observable first, so a body that stores a field must be able to
    // reach its RETURN — a re-run would apply the store twice.
    if (cl.can_deopt and cl.writes_fields) return null;
    if (cl.n_params != n_args or cl.param_rt.len != n_args) return null;
    if (cl.param_rt[0] != .object) return null;
    for (cl.param_rt[1..], 1..) |prt, i| {
        if (!isScalarRt(prt) or prt != retRegType(cf.params[i].ty)) return null;
    }
    // Nothing seeds the callee's frame registers or capture vector here: with
    // no trampoline and no deopt, its body never reads them, but a unit that
    // wants more than its receiver boxed is out of scope.
    if (cl.capture_loads.len != 0 or cl.obj_param_loads.len > 1) return null;
    if (cl.guard_class != instanceClassIdentity(recv.*)) return null;
    // The result KIND is the caller's concern: each tier compares `result_rt`
    // against its destination register, and only when it wants the value. A
    // `Unit` method whose return type was never recorded reads as `.unknown`,
    // and demanding scalar-or-unit here refused every one of them.
    return cl;
}

/// Whether an instruction is a call-SHAPED op the emitter lowers inline: a
/// numeric conversion or a bitwise op over scalars. Both spell as a member or
/// virtual call, so a site pass that does not recognize them either trampolines
/// two instructions' worth of work through the host (the loop tier) or rejects
/// the whole body for a non-object receiver (the function tier).
///
/// The operand check is what keeps it honest: the same names on a BOXED
/// receiver (`Number.toInt()`) have no inline form, and claiming one would turn
/// a body that trampolines correctly into one that does not compile at all.
pub fn nativeScalarCallShape(module: *const Module, inst: *const Inst, types: []const RegType, n_regs: u32) bool {
    if (numericConvOf(module, inst)) |nc| {
        return nc.src.int() < n_regs and isScalarRt(typeAt(types, nc.src));
    }
    if (bitwiseOpOf(module, inst)) |bo| {
        return bo.lhs.int() < n_regs and bo.rhs.int() < n_regs and
            isScalarRt(typeAt(types, bo.lhs)) and isScalarRt(typeAt(types, bo.rhs));
    }
    return false;
}

/// The object register a receiver argument is Moved from, with the position of
/// that Move.
const LoopRecvSource = struct { src: u32, mv: BodyInstPos };

/// The object register a call's receiver argument is Moved from, when that Move
/// is the ONLY thing writing the argument register and nothing else reads it.
/// This is the loop-tier analogue of `soleReceiverMove`: the receiver is a local
/// (`val c = Counter()` above the loop) or a cursor the loop rebinds, not the
/// caller's `this`, so it is identified by the Move that feeds arg 0.
///
/// Whether the source must be loop-INVARIANT is the caller's call: a direct call
/// caches a field base at entry and needs invariance, a spliced member body reads
/// the receiver afresh each iteration and does not. `types` is optional because
/// the splice is chosen before whole-function inference runs.
pub fn loopReceiverSource(
    func: *const Func,
    body: []const BlockId,
    arg0: u32,
    call_b: u32,
    call_i: u32,
    types: ?[]const RegType,
    n_regs: u32,
) ?LoopRecvSource {
    var found: ?LoopRecvSource = null;
    var other_refs: usize = 0;
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        for (blk.insts, 0..) |*inst, ii| {
            if (bid.int() == call_b and ii == call_i) continue; // the call itself
            if (inst.* == .Move and inst.Move.dst.int() == arg0) {
                if (found != null) return null; // more than one writer
                const src = inst.Move.src.int();
                if (src >= n_regs) return null;
                if (types) |ts| if (typeAt(ts, Reg.from(src)) != .object) return null;
                found = .{ .src = src, .mv = .{ .b = bid.int(), .i = @intCast(ii) } };
                continue;
            }
            const Ctx = struct { r: u32, n: *usize };
            var cx = Ctx{ .r = arg0, .n = &other_refs };
            ir.visitInstRegs(inst, &cx, struct {
                fn f(c: *Ctx, rr: Reg, _: bool) void {
                    if (rr.int() == c.r) c.n.* += 1;
                }
            }.f);
        }
        const Ctx2 = struct { r: u32, n: *usize };
        var cx2 = Ctx2{ .r = arg0, .n = &other_refs };
        ir.visitTerminatorRegs(&blk.terminator, &cx2, struct {
            fn f(c: *Ctx2, rr: Reg, _: bool) void {
                if (rr.int() == c.r) c.n.* += 1;
            }
        }.f);
    }
    if (other_refs != 0) return null;
    const got = found orelse return null;
    if (got.mv.b != call_b or got.mv.i >= call_i) return null;
    return got;
}

pub const MAX_RECV_CLASSES: usize = 4;

/// The distinct classes a per-iteration receiver can hold, when it is produced
/// inside the loop by a read from a LOOP-INVARIANT collection. Enumerating the
/// container is what lets a polymorphic site be specialized without guessing a
/// class: the guard chain covers exactly what is there.
///
/// This is a performance heuristic, never a correctness one — each emitted arm
/// re-checks the receiver's class at run time and a miss falls through to the
/// trampoline, so a stale or partial enumeration costs speed and nothing else.
pub fn receiverClassSet(
    func: *const Func,
    body: []const BlockId,
    recv_reg: u32,
    regs: []const Value,
    out: *[MAX_RECV_CLASSES]Value,
) ?[]const Value {
    // The receiver must have exactly one producer in the loop, and that
    // producer must read from a container the loop never rewrites.
    var producer: ?*const Inst = null;
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            const d = instAnyDst(inst) orelse continue;
            if (d.int() != recv_reg) continue;
            if (producer != null) return null;
            producer = inst;
        }
    }
    const p = producer orelse return null;
    const container: Reg = switch (p.*) {
        .CallMember => |cm| cm.receiver,
        .Index => |ix| ix.receiver,
        else => return null,
    };
    if (container.int() >= regs.len) return null;
    if (regWrittenInBody(func, body, container)) return null;
    const cv = regs[container.int()];
    if (cv != .List and cv != .Array) return null;
    var n: usize = 0;
    var i: i64 = 0;
    while (i < 1024) : (i += 1) {
        const elem = liveElementAt(cv, i) orelse break;
        if (elem != .Instance) return null;
        const id = instanceClassIdentity(elem);
        var seen = false;
        for (out[0..n]) |x| {
            if (instanceClassIdentity(x) == id) seen = true;
        }
        if (seen) continue;
        if (n == MAX_RECV_CLASSES) return null; // too many shapes to be worth arms
        out[n] = elem;
        n += 1;
    }
    if (n == 0) return null;
    return out[0..n];
}

/// A (block, instruction) position inside a compiled body.
pub const BodyInstPos = struct { b: u32, i: u32 };

/// The single `Move` that loads the receiver into `reg` for the call at
/// (`call_b`, `call_i`), when `reg` is referenced by NOTHING else in the body.
/// Exhaustive: `visitInstRegs` forces every instruction shape to be considered,
/// so a register read the splice would leave stale cannot slip through.
pub fn soleReceiverMove(
    func: *const Func,
    body: []const BlockId,
    reg: u32,
    call_b: u32,
    call_i: u32,
    recv_regs: []const u32,
    n_recv: usize,
) ?BodyInstPos {
    var found: ?BodyInstPos = null;
    var other_refs: usize = 0;
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        for (blk.insts, 0..) |*inst, ii| {
            if (bid.int() == call_b and ii == call_i) continue; // the call itself
            if (inst.* == .Move) {
                const m = inst.Move;
                if (m.dst.int() == reg) {
                    if (found != null) return null; // more than one writer
                    var src_is_recv = false;
                    for (recv_regs[0..n_recv]) |x| {
                        if (x == m.src.int()) src_is_recv = true;
                    }
                    if (!src_is_recv) return null;
                    found = .{ .b = bid.int(), .i = @intCast(ii) };
                    continue;
                }
            }
            const Ctx = struct { r: u32, n: *usize };
            var cx = Ctx{ .r = reg, .n = &other_refs };
            ir.visitInstRegs(inst, &cx, struct {
                fn f(c: *Ctx, rr: Reg, _: bool) void {
                    if (rr.int() == c.r) c.n.* += 1;
                }
            }.f);
        }
        const Ctx2 = struct { r: u32, n: *usize };
        var cx2 = Ctx2{ .r = reg, .n = &other_refs };
        ir.visitTerminatorRegs(&blk.terminator, &cx2, struct {
            fn f(c: *Ctx2, rr: Reg, _: bool) void {
                if (rr.int() == c.r) c.n.* += 1;
            }
        }.f);
    }
    if (other_refs != 0) return null;
    // A deopt out of the spliced body re-runs the whole call from the
    // interpreter, and the Move being removed here is what fills the call's
    // receiver argument — so the interpreter has to resume AT the Move, not at
    // the call. That is only sound while the instructions it would re-run in
    // between are idempotent, which for the lowered call shape (the remaining
    // argument moves) they are.
    const mv = found orelse return null;
    if (mv.b != call_b or mv.i >= call_i) return null;
    const blk = &func.blocks[call_b];
    var k: u32 = mv.i + 1;
    while (k < call_i) : (k += 1) {
        switch (blk.insts[k]) {
            .Move, .Const, .Trace => {},
            else => return null,
        }
    }
    return found;
}

pub fn inlinableMemberCallee(module: *const Module, f: *const Func, this_reg_out: *u32) bool {
    if (f.is_suspend) return false;
    if (f.blocks.len != 1) return false;
    if (!f.has_receiver_param) return false; // params[0] is the synthesized `this`
    const blk = &f.blocks[0];
    switch (blk.terminator) {
        .Return => {},
        else => return false,
    }
    // Parameters after the receiver must be plain scalars.
    for (f.params, 0..) |p, i| {
        if (i == 0) continue; // the receiver
        if (p.is_vararg or p.default != null or retRegType(p.ty) == .unknown) return false;
    }
    if (blk.insts.len > INLINE_MAX_INSTS) return false;
    var this_reg: ?u32 = null;
    for (blk.insts) |*inst| {
        switch (inst.*) {
            .LoadParam => |lp| {
                if (lp.idx == 0) this_reg = lp.dst.int();
            },
            else => {},
        }
    }
    const tr = this_reg orelse return false; // must bind `this`
    this_reg_out.* = tr;
    for (blk.insts) |*inst| {
        if (numericConvOf(module, inst) != null) continue;
        if (bitwiseOpOf(module, inst) != null) continue;
        if (trampolinableFieldOf(module, inst)) |fld| {
            if (fld.recv.int() != tr) return false; // only `this`-field reads
            continue;
        }
        if (trampolinableFieldSetOf(module, inst)) |fs| {
            if (fs.recv.int() != tr) return false;
            continue;
        }
        if (arrayOpOf(module, inst) != null) return false;
        switch (inst.*) {
            .Const, .Move, .BinOp, .Not, .UnOp, .Trace => {},
            .LoadParam => |lp| if (lp.idx >= f.params.len) return false,
            else => return false,
        }
    }
    return true;
}

/// The byte displacement of a slot index from the slots base register.
pub fn slotBytes(slot: u32) i32 {
    return @intCast(@as(u64, slot) * 8);
}

/// Copy an instruction with every register reference shifted by `base` — used to
/// emit an inlined callee body in the caller's extended register space. Only the
/// scalar instruction shapes an inlinable callee can contain are remapped.
pub fn remapInst(inst: Inst, base: u32) Inst {
    const b = base;
    var out = inst;
    switch (out) {
        .Const => |*c| c.dst = Reg.from(c.dst.int() + b),
        .Move => |*m| {
            m.dst = Reg.from(m.dst.int() + b);
            m.src = Reg.from(m.src.int() + b);
        },
        .BinOp => |*x| {
            x.dst = Reg.from(x.dst.int() + b);
            x.lhs = Reg.from(x.lhs.int() + b);
            x.rhs = Reg.from(x.rhs.int() + b);
        },
        .Not => |*n| {
            n.dst = Reg.from(n.dst.int() + b);
            n.src = Reg.from(n.src.int() + b);
        },
        .UnOp => |*u| {
            u.dst = Reg.from(u.dst.int() + b);
            u.operand = Reg.from(u.operand.int() + b);
        },
        .CallMember => |*cm| {
            // Bitwise / numeric-conversion infix ops (the only CallMembers an
            // inlinable callee may contain): remap receiver, args base, dst.
            cm.dst = Reg.from(cm.dst.int() + b);
            cm.receiver = Reg.from(cm.receiver.int() + b);
            cm.args = Reg.from(cm.args.int() + b);
        },
        .Trace => {},
        else => {},
    }
    return out;
}
