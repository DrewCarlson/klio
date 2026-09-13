//! Callee analysis for inlining and direct calls: block ordering and the inlinability gates,
//! the self-inline and direct-compile paths, receiver class sets, and instruction remapping.

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
/// Upper bound on a splice candidate's block count, keeping the scan and label table fixed-size.
pub const CALLEE_BLOCK_LIMIT: usize = 64;

/// The blocks a splice covers: those reachable from the callee's entry, entry first then
/// ascending. Null for an unsupported terminator, a bad edge, or more blocks than the budget.
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

/// Whether a splice-eligible callee delivers a value; `selfInlinableCallee` proved the returns agree.
pub fn calleeReturnsValue(f: *const Func) bool {
    for (f.blocks) |*b| {
        if (b.terminator == .Return and b.terminator.Return != null) return true;
    }
    return false;
}

/// Whether a top-level callee can be inlined into the native loop: a single block returning a
/// value, only scalar instructions, scalar required parameters and a scalar return.
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
            .LoadParam => |lp| if (lp.idx >= f.params.len) return false,
            else => return false,
        }
    }
    return true;
}

/// One inlined call: the callee's block is emitted in place of the call, its registers shifted by
/// `base` into the caller's extended register space, and a deopt resumes at the original call.
pub const InlineSite = struct {
    block: BlockId,
    inst: u32,
    callee: *const Func,
    base: u32,
    args_reg: u32,
    n_args: u32,
    dst: Reg,
    /// Member inline: the receiver register (the callee's `this`), the callee register `LoadParam 0`
    /// writes (mapped to `recv_reg`, not `base`), and the field sites its `this` accesses registered as.
    is_member: bool = false,
    recv_reg: u32 = 0,
    this_reg: u32 = 0,
    field_site_base: u32 = 0,
    n_field_sites: u32 = 0,
    has_result: bool = true,
    /// Where a deopt inside the spliced body resumes: the receiver `Move` this splice removed. Null
    /// for a top-level inline, which removes nothing, so the call's own position is right.
    resume_at: ?BodyInstPos = null,
    /// One arm of a per-iteration receiver guard: run this body only when the receiver's class matches
    /// `guard_class`. Arms at one position chain, the last miss falling through to `fallback_site`.
    /// The guard makes the arm SOUND; the class set that chose the arms is only a heuristic.
    guarded: bool = false,
    guard_class: usize = 0,
    fallback_site: u32 = 0,
};

/// The register whose LIVE tag governs `reg`'s rebox at the call at `call_idx`: same-block `Move`s
/// are walked backward, redirecting through each, and any other definition ends the chain there.
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

/// The register an instruction defines, read structurally rather than from a hand-kept list, since
/// callers use it to prove a register is NOT written in a loop.
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

/// Inlines a SELF call, `this.helper(...)`, which the lowerer emits as a static `Call` with the
/// receiver moved into arg 0. That Move alone makes the method uncompilable, a receiver register
/// being allowed only as a field-op receiver. `KLIO_FJ_SELF_INLINE=0` disables it.
var fj_self_inline_cache: ?bool = null;
pub fn fjSelfInlineEnabled() bool {
    if (fj_self_inline_cache) |v| return v;
    const on = if (runtime.envOnce("KLIO_FJ_SELF_INLINE")) |v| !(v.len != 0 and v[0] == '0') else true;
    fj_self_inline_cache = on;
    return on;
}

/// A callee this tier can splice at a self-call: scalar control flow over its own registers, reading
/// and writing `this` only through the field-site machinery. Refusing any other `this` use keeps the
/// receiver register unmaterialized, which is what lets the caller compile.
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
    // Returns that disagree would need the splice to deliver a value on one path and not another.
    if (value_rets != 0 and void_rets != 0) return false;
    if (value_rets + void_rets == 0) return false;
    if (total_insts == 0 or total_insts > INLINE_MAX_INSTS) return false;
    for (f.params[1..]) |p| {
        if (p.is_vararg or p.default != null or !isScalarRt(retRegType(p.ty))) return false;
    }
    if (value_rets != 0 and !isScalarRt(retRegType(f.return_ty))) return false;
    // The lowerer emits a `LoadParam` for EVERY parameter, so the receiver load is present even in a
    // body that ignores `this`. What matters is that its register is never read: the emitter skips it.
    var this_dst: ?u32 = null;
    for (order) |b| {
        for (f.blocks[b].insts) |*ci| {
            if (ci.* == .LoadParam and ci.LoadParam.idx == 0) this_dst = ci.LoadParam.dst.int();
            // A `this`-field access is fine at a SELF call: the callee's receiver is the caller's, and the
            // access rides the caller's own entry field base.
            if (trampolinableFieldOf(module, ci) != null) continue;
            if (trampolinableFieldSetOf(module, ci) != null) continue;
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
    // A deopt inside the splice re-runs the whole call, so a callee that WRITES a field must not be
    // able to deopt first: every field it reads must be a non-nullable scalar, and it must not divide.
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

/// `KLIO_FJ_DIRECT=0` disables direct calls between compiled units, to bisect a regression.
var fj_direct_cache: ?bool = null;
pub fn fjDirectEnabled() bool {
    if (fj_direct_cache) |v| return v;
    const on = if (runtime.envOnce("KLIO_FJ_DIRECT")) |v| !(v.len != 0 and v[0] == '0') else true;
    fj_direct_cache = on;
    return on;
}

/// Compile nesting a direct call may trigger: A's compile compiles B, whose compile may compile C.
/// Bounded so a deep helper chain cannot recurse the compiler off the stack.
threadlocal var direct_compile_depth: u32 = 0;
const DIRECT_COMPILE_MAX_DEPTH: u32 = 4;

/// The compiled unit a direct call may target: a deopt-free method body on the same receiver,
/// taking scalar arguments and delivering a scalar or nothing. Deopt-freedom is what makes the call
/// a plain `call`, with no resume point to reconstruct and no frame to own.
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
    // A callee that CAN deopt is still reachable: the caller tests its resume code and re-runs the call
    // interpreted, which is correct only while the callee changed nothing observable first.
    if (cl.can_deopt and cl.writes_fields) return null;
    if (cl.n_params != n_args or cl.param_rt.len != n_args) return null;
    if (cl.param_rt[0] != .object) return null;
    for (cl.param_rt[1..], 1..) |prt, i| {
        if (!isScalarRt(prt) or prt != retRegType(cf.params[i].ty)) return null;
    }
    // Nothing seeds the callee's frame registers or capture vector here: with no trampoline and no
    // deopt its body never reads them, so a unit wanting more than its receiver boxed is out of scope.
    if (cl.capture_loads.len != 0 or cl.obj_param_loads.len > 1) return null;
    if (cl.guard_class != instanceClassIdentity(recv.*)) return null;
    return cl;
}

/// Whether an instruction is a call-SHAPED op the emitter lowers inline: a numeric conversion or a
/// bitwise op over scalars. Both spell as a member or virtual call, so a site pass that misses them
/// trampolines the work or rejects the body. The same names on a BOXED receiver have no inline form.
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

const LoopRecvSource = struct { src: u32, mv: BodyInstPos };

/// The object register a call's receiver argument is Moved from, when that Move is the ONLY writer
/// of the argument register and nothing else reads it: the loop-tier analogue of `soleReceiverMove`.
/// Whether the source must be loop-INVARIANT is the caller's call, and `types` is optional because
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

/// The distinct classes a per-iteration receiver can hold, when a LOOP-INVARIANT collection produces
/// it inside the loop: enumerating the container specializes a polymorphic site without guessing.
/// A heuristic only, since each arm re-checks the class and a miss falls through to the trampoline.
pub fn receiverClassSet(
    func: *const Func,
    body: []const BlockId,
    recv_reg: u32,
    regs: []const Value,
    out: *[MAX_RECV_CLASSES]Value,
) ?[]const Value {
    // The receiver must have exactly one producer in the loop, reading from a container never rewritten.
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

pub const BodyInstPos = struct { b: u32, i: u32 };

/// The single `Move` that loads the receiver into `reg` for the call at (`call_b`, `call_i`), when
/// nothing else in the body references `reg`. Exhaustive through `visitInstRegs`.
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
    // A deopt out of the spliced body re-runs the whole call, and the Move removed here is what fills
    // the call's receiver argument, so the interpreter resumes AT the Move; the argument moves re-run
    // in between are idempotent.
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

pub fn slotBytes(slot: u32) i32 {
    return @intCast(@as(u64, slot) * 8);
}

/// Copies an instruction with every register reference shifted by `base`, to emit an inlined callee
/// body in the caller's extended register space.
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
            // Bitwise and numeric-conversion infix ops are the only CallMembers an inlinable callee holds.
            cm.dst = Reg.from(cm.dst.int() + b);
            cm.receiver = Reg.from(cm.receiver.int() + b);
            cm.args = Reg.from(cm.args.int() + b);
        },
        .Trace => {},
        else => {},
    }
    return out;
}
