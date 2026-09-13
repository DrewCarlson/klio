//! The whole-function compile gate: collects a function body, infers its
//! parameter specialization, and drives the emitter for function-mode JIT.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const jit = @import("jit");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const inline_analysis = @import("inline_analysis.zig");
const type_infer = @import("types.zig");
const loop_shape = @import("loop_shape.zig");
const compiler = @import("compiler.zig");
const run_mod = @import("run.zig");
const code_cache = @import("cache.zig");

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const Reg = ir.Reg;
const BlockId = ir.BlockId;
const FuncId = ir.FuncId;
const Allocator = std.mem.Allocator;

const debugEnabled = code_cache.debugEnabled;
const fjFieldsEnabled = code_cache.fjFieldsEnabled;
const fjMemberEnabled = code_cache.fjMemberEnabled;
const CallSite = common.CallSite;
const CompiledLoop = common.CompiledLoop;
const DirectSite = common.DirectSite;
const MAX_SLOTS = common.MAX_SLOTS;
const MemberIC = common.MemberIC;
const MethodFieldCheck = common.MethodFieldCheck;
const ObjParamLoad = common.ObjParamLoad;
const RegType = common.RegType;
const valuePayloadOffset = common.valuePayloadOffset;
const valueTagOffset = common.valueTagOffset;
const Compiler = compiler.Compiler;
const BodyInstPos = inline_analysis.BodyInstPos;
const INLINE_MAX_BLOCKS = inline_analysis.INLINE_MAX_BLOCKS;
const InlineSite = inline_analysis.InlineSite;
const calleeBlockOrder = inline_analysis.calleeBlockOrder;
const calleeReturnsValue = inline_analysis.calleeReturnsValue;
const directCallTarget = inline_analysis.directCallTarget;
const fjDirectEnabled = inline_analysis.fjDirectEnabled;
const fjSelfInlineEnabled = inline_analysis.fjSelfInlineEnabled;
const instAnyDst = inline_analysis.instAnyDst;
const nativeScalarCallShape = inline_analysis.nativeScalarCallShape;
const selfInlinableCallee = inline_analysis.selfInlinableCallee;
const soleReceiverMove = inline_analysis.soleReceiverMove;
const execEscapable = loop_shape.execEscapable;
const instReadsDef = loop_shape.instReadsDef;
const succEach = loop_shape.succEach;
const typeAt = loop_shape.typeAt;
const INT_TAG = run_mod.INT_TAG;
const FieldResolver = shapes.FieldResolver;
const MemberResolver = shapes.MemberResolver;
const VirtResolver = shapes.VirtResolver;
const bitwiseOpOf = shapes.bitwiseOpOf;
const cellScalarType = shapes.cellScalarType;
const isDivBinOp = shapes.isDivBinOp;
const memberFieldName = shapes.memberFieldName;
const numericConvOf = shapes.numericConvOf;
const trampolinableCallOf = shapes.trampolinableCallOf;
const trampolinableFieldOf = shapes.trampolinableFieldOf;
const trampolinableFieldSetOf = shapes.trampolinableFieldSetOf;
const trampolinableGlobalOf = shapes.trampolinableGlobalOf;
const trampolinableMemberOf = shapes.trampolinableMemberOf;
const trampolinableVirtualOf = shapes.trampolinableVirtualOf;
const declaredScalarName = type_infer.declaredScalarName;
const fillInlineTypes = type_infer.fillInlineTypes;
const funcReturnRegType = type_infer.funcReturnRegType;
const instanceClassIdentity = type_infer.instanceClassIdentity;
const isScalarRt = type_infer.isScalarRt;
const isUnitReturn = type_infer.isUnitReturn;
const retRegType = type_infer.retRegType;
const setDefType = type_infer.setDefType;
const setType = type_infer.setType;

// --- whole-function JIT (function mode) -------------------------------------

/// Every block reachable from the function entry (the compile covers the whole
/// body, entry to `Return`). Caller frees.
fn collectFunc(a: Allocator, func: *const Func) Allocator.Error!?[]BlockId {
    const nb = func.blocks.len;
    if (nb == 0) return null;
    const reach = try a.alloc(bool, nb);
    defer a.free(reach);
    @memset(reach, false);
    var order: std.ArrayListUnmanaged(BlockId) = .empty;
    errdefer order.deinit(a);
    var succ: std.ArrayListUnmanaged(BlockId) = .empty;
    defer succ.deinit(a);
    const entry = func.entry.int();
    if (entry >= nb) return null;
    reach[entry] = true;
    try order.append(a, func.entry);
    var i: usize = 0;
    while (i < order.items.len) : (i += 1) {
        succ.clearRetainingCapacity();
        try succEach(func.blocks[order.items[i].int()].terminator, &succ, a);
        for (succ.items) |s| {
            if (s.int() < nb and !reach[s.int()]) {
                reach[s.int()] = true;
                try order.append(a, s);
            }
        }
    }
    return try order.toOwnedSlice(a);
}

/// Type inference for a whole function: seed `LoadParam` dsts from the live
/// argument kinds, then propagate (`setDefType`) over every block to a fixpoint.
fn inferFuncTypes(a: Allocator, module: *const Module, func: *const Func, n_regs: u32, params: []const Value) Allocator.Error![]RegType {
    const types = try a.alloc(RegType, n_regs);
    @memset(types, .unknown);
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (func.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* == .LoadParam) {
                    const lp = inst.LoadParam;
                    if (lp.idx < params.len) {
                        if (cellScalarType(params[lp.idx])) |rt| {
                            if (setType(types, lp.dst, rt)) changed = true;
                        }
                    }
                    continue;
                }
                if (setDefType(types, module, inst, &.{}, &.{})) changed = true;
            }
        }
    }
    return types;
}

/// Try to compile the whole body of `func` to native code (function mode): a
/// scalar function whose params/locals/return are scalar and whose only calls
/// are positional top-level calls (so direct recursion stays native through the
/// call trampoline). `params` are the live arguments at the hot call, used to
/// specialize param kinds. Returns null for any unsupported shape.
pub fn tryCompileFunc(a: Allocator, module: *const Module, func: *const Func, params: []const Value, captures: []const Value, resolver: ?MemberResolver, virt_resolver: ?VirtResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver, resolver_user: ?*anyopaque) Allocator.Error!?CompiledLoop {
    if (func.blocks.len == 0) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4075\n", .{func.name}); return null; }
    if (func.is_suspend or func.is_inline) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4076\n", .{func.name}); return null; }
    // Bisect: KLIO_FJ_ONLY=name compiles only that body.
    if (runtime.envOnce("KLIO_FJ_ONLY")) |only| {
        if (!std.mem.eql(u8, only, func.name)) return null;
    }
    // Bisect: KLIO_FJ_SKIP=a,b declines the named bodies.
    if (runtime.envOnce("KLIO_FJ_SKIP")) |skips| {
        var it2 = std.mem.splitScalar(u8, skips, ',');
        while (it2.next()) |nm| {
            if (std.mem.eql(u8, nm, func.name)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4081\n", .{func.name}); return null; }
        }
    }
    // No package gate. This tier is entered from a frame that is ALREADY
    // running the function's lowered body, so it can only ever replace a body
    // the runtime chose to run — a symbol the link settled onto a native
    // binding never reaches here, and `is_suspend` is refused above, which is
    // what cooperative scheduling actually rides on. Excluding every `kotlin*`
    // package instead left the whole stdlib interpreted for no mechanism.
    // `KLIO_FJ_SKIP` still bisects a specific body.
    const n_params: u32 = @intCast(func.params.len);
    if (n_params > 16 or params.len < n_params) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4089\n", .{func.name}); return null; }
    // Result must be scalar or Unit.
    const result_rt: RegType = retRegType(func.return_ty);
    // Only a return type whose boxed form `valueFromSlot` reproduces exactly:
    // `Char`/`Short`/`Byte` map to `.i32` but rebox to `.Int`, so a function
    // returning one would hand back a wrong-tagged value. Restrict to the exact
    // kinds (or Unit).
    const exact_ret = !func.return_ty.nullable and (std.mem.eql(u8, func.return_ty.name, "Int") or
        std.mem.eql(u8, func.return_ty.name, "Long") or std.mem.eql(u8, func.return_ty.name, "Double") or
        std.mem.eql(u8, func.return_ty.name, "Float") or std.mem.eql(u8, func.return_ty.name, "Boolean"));
    const result_scalar = isScalarRt(result_rt) and exact_ret;
    // A declared-object (or Unit) result is served by the frame-resident
    // return protocol: every value `Return` records its register index and
    // `runFunc` reads the frame register the handlers populated. Only the
    // in-between shapes decline: an inexact scalar (Char/Short/Byte rebox as
    // Int) and a nullable scalar (its Null arm has no slot form).
    const result_object = !result_scalar and !declaredScalarName(func.return_ty.name) and !isUnitReturn(func.return_ty);
    if (!result_scalar and !result_object and !(result_rt == .unknown and isUnitReturn(func.return_ty))) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4100\n", .{func.name}); return null; }

    const body = (try collectFunc(a, func)) orelse { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4102\n", .{func.name}); return null; };
    defer a.free(body);

    // Method mode: a `this`-receiver whose ONLY use is native field access.
    // The receiver's class is guarded at entry (a different class declines to
    // the interpreter) and its field-buffer pointer is seeded into a slot, so
    // the body's `this.x` reads/writes compile to direct memory ops. The body
    // has effects and holds an object, so it never native-recurses; every
    // deopt resumes through the TOP-LEVEL activation's real frame, exactly
    // like a loop deopt.
    const is_method = fjFieldsEnabled() and n_params >= 1 and func.params.len >= 1 and
        std.mem.eql(u8, func.params[0].name, "this") and
        params[0] == .Instance and field_resolver != null and resolver_user != null;
    const n_regs: u32 = func.n_locals;

    // Object params (an Instance argument at the hot call): their LoadParam
    // destinations are FRAME registers, seeded borrowed before native entry.
    // The method receiver's loads are the param-0 subset (its field ops are
    // native; every object reg is additionally usable as a member/virtual
    // receiver, an object move, or a null test — all trampoline sites).
    var recv_regs_buf: [4]u32 = undefined;
    var n_recv_regs: usize = 0;
    var obj_loads_buf: [16]ObjParamLoad = undefined;
    var n_obj_loads: usize = 0;
    for (func.blocks) |*blk| {
        for (blk.insts) |*inst| {
            if (inst.* != .LoadParam) continue;
            const lp = inst.LoadParam;
            if (lp.idx >= params.len or params[lp.idx] != .Instance) continue;
            if (n_obj_loads >= obj_loads_buf.len) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4131\n", .{func.name}); return null; }
            obj_loads_buf[n_obj_loads] = .{ .param_idx = @intCast(lp.idx), .reg = lp.dst.int() };
            n_obj_loads += 1;
            if (is_method and lp.idx == 0) {
                if (n_recv_regs >= recv_regs_buf.len) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4135\n", .{func.name}); return null; }
                recv_regs_buf[n_recv_regs] = lp.dst.int();
                n_recv_regs += 1;
            }
        }
    }
    const recv_regs = recv_regs_buf[0..n_recv_regs];
    const obj_loads = obj_loads_buf[0..n_obj_loads];

    // Lambda captures: every LoadCapture destination is a FRAME register
    // seeded borrowed from the activation's capture vector (any value kind —
    // a captured scalar stays boxed; a `var` capture's Cell declines at its
    // CellGet). The capture INDEX layout is static per lambda body, so the
    // compile-time snapshot only bounds the indexes.
    var cap_loads_buf: [16]ObjParamLoad = undefined;
    var n_cap_loads: usize = 0;
    for (func.blocks) |*blk| {
        for (blk.insts) |*inst| {
            if (inst.* != .LoadCapture) continue;
            const lcx = inst.LoadCapture;
            if (lcx.idx >= captures.len or lcx.idx > std.math.maxInt(u16)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: cap-idx\n", .{func.name}); return null; }
            if (n_cap_loads >= cap_loads_buf.len) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: cap-cap\n", .{func.name}); return null; }
            cap_loads_buf[n_cap_loads] = .{ .param_idx = @intCast(lcx.idx), .reg = lcx.dst.int() };
            n_cap_loads += 1;
        }
    }
    const cap_loads = cap_loads_buf[0..n_cap_loads];

    const isRecvReg = struct {
        fn f(set: []const u32, r: u32) bool {
            for (set) |x| {
                if (x == r) return true;
            }
            return false;
        }
    }.f;

    // Self-call inlining (opt-in): `this.helper(args)` lowers to a static Call
    // with the receiver MOVED into arg 0, and that Move is what makes the whole
    // method uncompilable — a receiver register may otherwise appear only as a
    // field-op receiver. When the callee never touches `this`, the splice makes
    // both the Move and the call disappear, so the receiver is never
    // materialized and the method can still run frameless at the seam.
    const InstPos = BodyInstPos;
    var inline_sites: std.ArrayListUnmanaged(InlineSite) = .empty;
    defer inline_sites.deinit(a);
    var skip_insts: std.ArrayListUnmanaged(InstPos) = .empty;
    defer skip_insts.deinit(a);
    var total_regs: u32 = n_regs;
    if (is_method and fjSelfInlineEnabled()) {
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            for (blk.insts, 0..) |*inst, ii| {
                const tc = trampolinableCallOf(inst) orelse continue;
                if (tc.n_args == 0 or tc.n_args > 6) continue;
                const cf = module.funcById(tc.func) orelse continue;
                if (!selfInlinableCallee(module, cf, tc.n_args, if (params.len > 0) &params[0] else null, field_nn_resolver, resolver_user)) continue;
                const mv = soleReceiverMove(func, body, tc.args_reg, bid.int(), @intCast(ii), &recv_regs_buf, n_recv_regs) orelse continue;
                inline_sites.append(a, .{
                    .block = bid,
                    .inst = @intCast(ii),
                    .callee = cf,
                    .base = total_regs,
                    // Member convention: parameter 1 is the first real argument,
                    // and parameter 0 (the receiver) is skipped by the emitter.
                    .args_reg = tc.args_reg + 1,
                    .n_args = tc.n_args - 1,
                    .dst = tc.dst,
                    .is_member = true,
                    .recv_reg = tc.args_reg,
                    .this_reg = 0,
                    .field_site_base = 0,
                    .n_field_sites = 0,
                    .has_result = calleeReturnsValue(cf),
                    .resume_at = .{ .b = mv.b, .i = mv.i },
                }) catch return null;
                skip_insts.append(a, .{ .b = mv.b, .i = mv.i }) catch return null;
                total_regs += cf.n_locals;
                if (total_regs > 4096) return null;
                if (debugEnabled()) std.debug.print("[jit]   inlining self-call {s} into {s} at b{d}:{d} (move b{d}:{d})\n", .{ cf.name, func.name, bid.int(), ii, mv.b, mv.i });
            }
        }
    }
    const inlinedAt = struct {
        fn f(sites: []const InlineSite, b: u32, i: u32) bool {
            for (sites) |*s| {
                if (s.block.int() == b and s.inst == i) return true;
            }
            return false;
        }
    }.f;
    // A self call the splice cannot take — the helper is too big, loops, or
    // reads something the splice refuses — becomes a DIRECT call into the
    // callee's own compiled code. Without it that call is a trampoline site,
    // which costs a boxed round trip per iteration AND makes this body able to
    // deopt, so it loses the frameless seam. With it the receiver Move
    // disappears the same way the splice's does, and both bodies stay native.
    var direct_sites: std.ArrayListUnmanaged(DirectSite) = .empty;
    defer direct_sites.deinit(a);
    if (is_method and fjDirectEnabled() and params.len > 0 and params[0] == .Instance) {
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            for (blk.insts, 0..) |*inst, ii| {
                if (inlinedAt(inline_sites.items, bid.int(), @intCast(ii))) continue;
                const tc = trampolinableCallOf(inst) orelse continue;
                if (tc.n_args == 0 or tc.n_args > 6) continue;
                const cf = module.funcById(tc.func) orelse continue;
                if (cf == func) continue; // a self-recursive call would reuse one slot window
                const mv = soleReceiverMove(func, body, tc.args_reg, bid.int(), @intCast(ii), &recv_regs_buf, n_recv_regs) orelse continue;
                const cl = directCallTarget(module, cf, tc.n_args, &params[0], resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user) orelse continue;
                direct_sites.append(a, .{
                    .block = bid,
                    .inst = @intCast(ii),
                    .callee = cl,
                    .slot_base = 0, // assigned once the caller's own slots are laid out
                    .args_reg = tc.args_reg,
                    .n_args = tc.n_args,
                    .dst = tc.dst,
                    .has_result = false, // set once the caller's register types are known
                    .may_deopt = cl.can_deopt,
                    .resume_at = .{ .b = mv.b, .i = mv.i },
                    .fbase_slot = 0, // the caller's entry base, assigned with the slot layout
                }) catch return null;
                skip_insts.append(a, .{ .b = mv.b, .i = mv.i }) catch return null;
                if (debugEnabled()) std.debug.print("[jit]   direct call {s} from {s} at b{d}:{d} (move b{d}:{d})\n", .{ cf.name, func.name, bid.int(), ii, mv.b, mv.i });
            }
        }
    }
    const directAt = struct {
        fn f(sites: []DirectSite, b: u32, i: u32) ?*DirectSite {
            for (sites) |*s| {
                if (s.block.int() == b and s.inst == i) return s;
            }
            return null;
        }
    }.f;
    const skippedAt = struct {
        fn f(list: []const InstPos, b: u32, i: u32) bool {
            for (list) |p| {
                if (p.b == b and p.i == i) return true;
            }
            return false;
        }
    }.f;

    var has_div = false;
    var n_escapes: u32 = 0;
    const EscapePos = struct { b: u32, i: u32 };
    var escape_pos: std.ArrayListUnmanaged(EscapePos) = .empty;
    defer escape_pos.deinit(a);
    // Validate shape: no try-regions; Goto/Branch/Return terminators; scalar
    // ops + positional top-level calls (+ `this`-field access in method mode).
    // A method receiver register may appear ONLY as a field-op receiver.
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        if (blk.catches.len != 0 or blk.finally != null) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4163\n", .{func.name}); return null; }
        switch (blk.terminator) {
            .Goto, .Branch, .Return => {},
            else => { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4166\n", .{func.name}); return null; },
        }
        if (blk.terminator == .Return) {
            if (blk.terminator.Return) |rr| {
                if (isRecvReg(recv_regs, rr.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4170\n", .{func.name}); return null; }
            }
        }
        for (blk.insts, 0..) |*inst, inst_i| {
            // The receiver Move an inlined self-call consumed, and the call it
            // fed, are spliced away — neither reaches the emitter.
            if (skippedAt(skip_insts.items, bid.int(), @intCast(inst_i))) continue;
            if (inlinedAt(inline_sites.items, bid.int(), @intCast(inst_i))) continue;
            if (numericConvOf(module, inst)) |nc| {
                if (isRecvReg(recv_regs, nc.src.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4175\n", .{func.name}); return null; }
                continue;
            }
            if (bitwiseOpOf(module, inst)) |bo| {
                if (isRecvReg(recv_regs, bo.lhs.int()) or isRecvReg(recv_regs, bo.rhs.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4179\n", .{func.name}); return null; }
                continue;
            }
            if (trampolinableCallOf(inst)) |tc| {
                if (tc.n_args > 6) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4183\n", .{func.name}); return null; }
                var k: u32 = 0;
                while (k < tc.n_args) : (k += 1) {
                    if (isRecvReg(recv_regs, tc.args_reg + k)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4186\n", .{func.name}); return null; }
                }
                continue;
            }
            // Member / virtual calls trampoline; the receiver must be one of
            // the seeded object registers (an object param — including the
            // method receiver — whose value the handler reads from the frame).
            // An UNRESOLVED bare-name member with no declared head keeps the
            // interpreter: its resolution consults the executing frame's
            // receiver tower and visibility surface (an interface default's
            // `isEmpty()` resolved a file-private extension there), context
            // the trampoline's by-name dispatch does not carry.
            // Member/virtual trampoline sites (KLIO_FJ_MEMBER=0 bisects):
            // the receiver must be a seeded object-param register. (Both
            // launch repros — Changes.isNotEmpty, dataIndexToDataAnchor —
            // were ONE bug: the object-param seed table was never copied
            // into the CompiledLoop, so receivers read stale pooled-frame
            // registers.)
            if (trampolinableMemberOf(module, inst)) |mc| {
                if (!fjMemberEnabled()) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4205\n", .{func.name}); return null; }
                // The receiver may be ANY object-typed register — a param, a
                // prior call's boxed result, an object field read: every
                // object def is handler-written, so its value is in the frame
                // where the site handler reads it. The site build (post-
                // typing) enforces the .object kind.
                if (mc.dispatch_recv != null) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4211\n", .{func.name}); return null; }
                continue;
            }
            if (trampolinableVirtualOf(inst)) |vc| {
                if (!fjMemberEnabled()) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4215\n", .{func.name}); return null; }
                _ = vc;
                continue;
            }
            switch (inst.*) {
                // `/` and `%` divide: the deopt they can raise has no frame to
                // resume into when the body runs as a native-recursed callee.
                // That is survivable because such a body is PURE — it runs with
                // no trampoline, so it cannot call out or touch anything — and
                // the recursion site falls back to re-running it interpreted,
                // which is where the real divide-by-zero is raised. Refusing
                // division outright kept ordinary arithmetic helpers (anything
                // with a `%`) uncompiled, and their callers then trampolined
                // per iteration and ran slower than the plain interpreter.
                .BinOp => |b| {
                    if (isRecvReg(recv_regs, b.lhs.int()) or isRecvReg(recv_regs, b.rhs.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4228\n", .{func.name}); return null; }
                    if (isDivBinOp(b.op)) has_div = true;
                },
                .Move => |m| if (isRecvReg(recv_regs, m.src.int()) or isRecvReg(recv_regs, m.dst.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4234\n", .{func.name}); return null; },
                .Not => |nt| if (isRecvReg(recv_regs, nt.src.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4235\n", .{func.name}); return null; },
                .UnOp => |u| if (isRecvReg(recv_regs, u.operand.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4236\n", .{func.name}); return null; },
                .GetField => |gf| {
                    if (!is_method or !isRecvReg(recv_regs, gf.receiver.int())) {
                        if (!execEscapable(inst)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4239 inst={s}\n", .{ func.name, @tagName(std.meta.activeTag(inst.*)) }); return null; }
                        n_escapes += 1;
                        escape_pos.append(a, .{ .b = bid.int(), .i = @intCast(inst_i) }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4241\n", .{func.name}); return null; };
                        continue;
                    }
                },
                .SetField => |sf| {
                    if (!is_method or !isRecvReg(recv_regs, sf.receiver.int())) {
                        if (!execEscapable(inst)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4247 inst={s}\n", .{ func.name, @tagName(std.meta.activeTag(inst.*)) }); return null; }
                        n_escapes += 1;
                        escape_pos.append(a, .{ .b = bid.int(), .i = @intCast(inst_i) }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4249\n", .{func.name}); return null; };
                        continue;
                    }
                    if (sf.super_owner != null) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4252\n", .{func.name}); return null; }
                    if (isRecvReg(recv_regs, sf.value.int())) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4253\n", .{func.name}); return null; }
                },
                .Const, .Trace, .LoadParam => {},
                else => {
                    // Anything the emitter has no native or trampoline form
                    // for runs as an ESCAPE: the interpreter's own arm
                    // against the live frame. Bounded per body so a mostly-
                    // escaped body stays interpreted.
                    if (!execEscapable(inst)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4261 inst={s}\n", .{ func.name, @tagName(std.meta.activeTag(inst.*)) }); return null; }
                    n_escapes += 1;
                    escape_pos.append(a, .{ .b = bid.int(), .i = @intCast(inst_i) }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4263\n", .{func.name}); return null; };
                },
            }
        }
    }
    if (n_escapes > 24) {
        if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: escape-cap\n", .{func.name});
        { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4270\n", .{func.name}); return null; }
    }

    // Each param must be a scalar value (the method receiver is `.object`);
    // record its kind for the entry guard.
    const param_rt = try a.alloc(RegType, n_params);
    var ok = false;
    defer if (!ok) a.free(param_rt);
    {
        var p: u32 = 0;
        while (p < n_params) : (p += 1) {
            if (params[p] == .Instance) {
                param_rt[p] = .object;
                continue;
            }
            param_rt[p] = cellScalarType(params[p]) orelse {
                if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: param-kind\n", .{func.name});
                { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4287\n", .{func.name}); return null; }
            };
        }
    }

    // Resolve every `this`-field op against the LIVE receiver: the stored
    // index, the field's exact live scalar kind (only the exact-rebox kinds —
    // a Char/Short/Byte field would rebox as Int on deopt), and the tag the
    // native read guards on. These seed the type inference so field-read
    // destinations type precisely.
    const FieldPre = struct { block: u32, inst: u32, idx: u32, rt: RegType, tag: u8, is_set: bool, dst_or_src: u32, nn: bool, name: []const u8 };
    var field_pres: std.ArrayListUnmanaged(FieldPre) = .empty;
    defer field_pres.deinit(a);
    if (is_method) {
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            for (blk.insts, 0..) |*inst, ii| {
                const info: struct { name_id: ir.ConstId, is_set: bool, reg: u32, recv: u32 } = switch (inst.*) {
                    .GetField => |gf| .{ .name_id = gf.field, .is_set = false, .reg = gf.dst.int(), .recv = gf.receiver.int() },
                    .SetField => |sf| .{ .name_id = sf.field, .is_set = true, .reg = sf.value.int(), .recv = sf.receiver.int() },
                    else => continue,
                };
                // Only the receiver's OWN fields take the native fixed-index
                // route (the entry guard pins their class); any other object's
                // field op goes through the by-name trampoline site below.
                if (!isRecvReg(recv_regs, info.recv)) continue;
                if (info.name_id.int() >= module.consts.items.len) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4309\n", .{func.name}); return null; }
                const namec = module.consts.items[info.name_id.int()];
                if (namec != .String) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4311\n", .{func.name}); return null; }
                const fname = memberFieldName(namec.String);
                const idx = field_resolver.?(resolver_user.?, &params[0], fname) orelse { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4313\n", .{func.name}); return null; };
                const fv: Value = blk2: {
                    const g = params[0].Instance.borrow();
                    defer g.deinit();
                    const items = g.get().fields.items;
                    if (idx >= items.len) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4318\n", .{func.name}); return null; }
                    break :blk2 items[idx].value;
                };
                const rt: RegType = switch (fv) {
                    .Int => .i32,
                    .Long => .i64,
                    .Double => .f64,
                    .Float => .f32,
                    .Bool => .boolean,
                    // An object-valued own field cannot live in a slot; its
                    // READ is served by the by-name trampoline site (boxed
                    // into the frame register). A store stays interpreted.
                    else => {
                        if (!info.is_set) continue;
                        if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4327\n", .{func.name});
                        return null;
                    },
                };
                const nn = !info.is_set and field_nn_resolver != null and
                    field_nn_resolver.?(resolver_user.?, &params[0], fname) != null;
                field_pres.append(a, .{
                    .block = bid.int(),
                    .inst = @intCast(ii),
                    .idx = idx,
                    .rt = rt,
                    .tag = @intFromEnum(std.meta.activeTag(fv)),
                    .is_set = info.is_set,
                    .dst_or_src = info.reg,
                    .nn = nn,
                    .name = fname,
                }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4341\n", .{func.name}); return null; };
            }
        }
    }

    const base_types = try inferFuncTypes(a, module, func, n_regs, params);
    // Inlined callee registers live above the caller's, so the type array (and
    // the slot space derived from it) covers both.
    const types = if (total_regs == n_regs) base_types else blk_t: {
        const t = a.alloc(RegType, total_regs) catch return null;
        @memcpy(t[0..n_regs], base_types);
        @memset(t[n_regs..], .unknown);
        a.free(base_types);
        break :blk_t t;
    };
    defer if (!ok) a.free(types);
    // Seed field-read destination types, object-param registers, and
    // member/virtual result types, then re-run the fixpoint so they
    // propagate into the arithmetic that consumes them.
    {
        for (obj_loads) |opl| {
            if (opl.reg >= n_regs) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4353\n", .{func.name}); return null; }
            _ = setType(types, Reg.from(opl.reg), .object);
        }
        for (cap_loads) |cpl| {
            if (cpl.reg >= n_regs) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: cap-reg\n", .{func.name}); return null; }
            _ = setType(types, Reg.from(cpl.reg), .object);
        }
        // An escaped instruction's destination types by its statically known
        // result kind where one exists, so consumers (a Branch condition, a
        // scalar accumulate) stay native with the escape's unspill syncing
        // the slot.
        for (escape_pos.items) |ep2| {
            const ei = &func.blocks[ep2.b].insts[ep2.i];
            switch (ei.*) {
                .InstanceOf => |io2| {
                    if (io2.dst.int() < n_regs) _ = setType(types, io2.dst, .boolean);
                },
                else => {},
            }
        }
        // Member/virtual result registers: resolve against the live param
        // receiver for a precise scalar kind; anything unresolved is a
        // boxed object write (always sound — the handler boxes the result
        // into the frame register).
        for (body) |bid2| {
            for (func.blocks[bid2.int()].insts, 0..) |*inst2, ii2| {
                var dstr: ?Reg = null;
                var rt2: RegType = .object;
                if (inst2.* == .GetField) {
                    // Own-field reads seed their exact scalar kind below (the
                    // FieldPre pass); every other field read is a by-name
                    // trampoline site whose result boxes into the frame.
                    var covered = false;
                    for (field_pres.items) |fp2| {
                        if (fp2.block == bid2.int() and fp2.inst == ii2) covered = true;
                    }
                    if (!covered) dstr = inst2.GetField.dst;
                } else if (trampolinableGlobalOf(module, inst2)) |lg2| {
                    dstr = lg2.dst;
                } else if (trampolinableMemberOf(module, inst2)) |mc2| {
                    dstr = mc2.dst;
                    if (mc2.resolved) |fid2| {
                        if (module.funcById(fid2)) |f2| rt2 = funcReturnRegType(module, f2);
                    } else if (resolver != null) {
                        for (obj_loads) |opl| {
                            if (opl.reg == mc2.recv.int()) {
                                // Placeholder arguments: this asks which
                                // overload the NAME and ARITY select, so the
                                // values are stand-ins — but every slot the
                                // resolver reads must exist. The partial fill
                                // that used to break out early handed it
                                // undefined Values and segfaulted under load.
                                var av2: [6]Value = undefined;
                                if (mc2.n_args <= av2.len) {
                                    for (0..mc2.n_args) |k2| av2[k2] = .Unit;
                                    if (resolver.?(resolver_user.?, &params[opl.param_idx], mc2.name, av2[0..mc2.n_args])) |fid2| {
                                        if (module.funcById(fid2)) |f2| rt2 = funcReturnRegType(module, f2);
                                    }
                                }
                                break;
                            }
                        }
                    }
                } else if (trampolinableVirtualOf(inst2)) |vc2| {
                    dstr = vc2.dst;
                    if (virt_resolver != null) {
                        for (obj_loads) |opl| {
                            if (opl.reg == vc2.recv.int()) {
                                if (virt_resolver.?(resolver_user.?, &params[opl.param_idx], vc2.slot)) |fid2| {
                                    if (module.funcById(fid2)) |f2| rt2 = funcReturnRegType(module, f2);
                                }
                                break;
                            }
                        }
                    }
                    // Receiver class outside the main module (the resolve memo
                    // only sees main-module classes): the slot ROOT's declared
                    // return type is still binding on every override — a
                    // primitive return has no covariant widening — so a scalar
                    // declaration types the destination without knowing the
                    // target. A lying override deopts at the site (the handler
                    // re-runs the instruction interpreted on a kind mismatch).
                    if (rt2 == .object) {
                        if (module.funcById(FuncId.from(vc2.slot))) |rootf| {
                            const drt = retRegType(rootf.return_ty);
                            if (drt != .unknown) rt2 = drt;
                        }
                    }
                }
                if (dstr) |d2| {
                    if (d2.int() >= n_regs) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4398\n", .{func.name}); return null; }
                    if (rt2 == .unknown) rt2 = .object;
                    _ = setType(types, d2, rt2);
                }
            }
        }
        for (field_pres.items) |fp| {
            if (!fp.is_set) {
                if (fp.dst_or_src >= n_regs) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4406\n", .{func.name}); return null; }
                _ = setType(types, Reg.from(fp.dst_or_src), fp.rt);
            }
        }
        var changed = true;
        var iters: usize = 0;
        while (changed and iters < 16) : (iters += 1) {
            changed = false;
            for (func.blocks) |*blk| {
                for (blk.insts) |*inst| {
                    if (inst.* == .LoadParam) continue;
                    if (setDefType(types, module, inst, &.{}, &.{})) changed = true;
                }
            }
        }
        // A field WRITE's source must be scalar of the field's exact kind.
        for (field_pres.items) |fp| {
            if (fp.is_set) {
                if (fp.dst_or_src >= n_regs or typeAt(types, Reg.from(fp.dst_or_src)) != fp.rt) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4424\n", .{func.name}); return null; }
            }
        }
    }

    // Inlined callee registers are typed LAST: their parameters take the types
    // of the caller registers feeding the call, and a field read only gets its
    // type in the pass above — typing the splice before it left every callee
    // parameter unknown and the emit refused the body.
    for (inline_sites.items) |*site| {
        fillInlineTypes(a, module, site, types[0..n_regs], types, field_resolver, resolver_user, &.{}, if (params.len > 0) &params[0] else null) catch return null;
    }

    // CASCADE: any instruction reading a register the typing could not
    // settle (an escaped producer's destination) escapes too — escaped
    // instructions read the live frame, where the arm-written values are
    // real. Fixpoint, bounded by the escape cap.
    {
        const inEscapes = struct {
            fn f(list: []const EscapePos, b: u32, i: u32) bool {
                for (list) |e| {
                    if (e.b == b and e.i == i) return true;
                }
                return false;
            }
        }.f;
        var grew = true;
        while (grew) {
            grew = false;
            for (body) |bid| {
                const blk = &func.blocks[bid.int()];
                for (blk.insts, 0..) |*inst, ii| {
                    if (inEscapes(escape_pos.items, bid.int(), @intCast(ii))) continue;
                    var reads2: [8]Reg = undefined;
                    var nr2: usize = 0;
                    var df2: ?Reg = null;
                    instReadsDef(module, inst, &reads2, &nr2, &df2, types);
                    var unknown = false;
                    for (reads2[0..nr2]) |rr2| {
                        if (rr2.int() < n_regs and types[rr2.int()] == .unknown) unknown = true;
                    }
                    if (!unknown) continue;
                    if (!execEscapable(inst)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4458 inst={s}\n", .{ func.name, @tagName(std.meta.activeTag(inst.*)) }); return null; }
                    if (inst.* == .Trace or inst.* == .LoadParam) continue;
                    n_escapes += 1;
                    if (n_escapes > 24) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4461\n", .{func.name}); return null; }
                    escape_pos.append(a, .{ .b = bid.int(), .i = @intCast(ii) }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4462\n", .{func.name}); return null; };
                    grew = true;
                }
            }
        }
    }
    // Post-cascade profitability re-check (the cascade grows the set).
    if (n_escapes != 0) {
        var total_insts2: u32 = 0;
        for (body) |bid2| total_insts2 += @intCast(func.blocks[bid2.int()].insts.len);
        if (n_escapes * 5 > total_insts2) {
            if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: escape-heavy ({d}/{d})\n", .{ func.name, n_escapes, total_insts2 });
            return null;
        }
    }

    // The return register must carry the declared scalar kind — or, when the
    // escape chain left it untyped, the return reads the LIVE FRAME (the
    // escaped arm wrote the real value there). A Branch on an untyped
    // condition has no such fallback: decline.
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        if (blk.terminator == .Return) {
            if (blk.terminator.Return) |rr| {
                if (rr.int() >= n_regs) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4478\n", .{func.name}); return null; }
                const rt3 = typeAt(types, rr);
                if (result_scalar) {
                    // Slot-typed must match the declared kind; unknown reads
                    // the frame (the escaped arm wrote the real value there).
                    if (rt3 != .unknown and rt3 != result_rt) {
                        if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: result-kind\n", .{func.name});
                        return null;
                    }
                } else if (result_object) {
                    // Every value return must be frame-resident: a scalar-
                    // typed register's boxed form may not match the declared
                    // type (e.g. Any with an Int arm), and `.null_` has no
                    // frame-register backing.
                    if (rt3 != .object and rt3 != .unknown) {
                        if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: result-kind\n", .{func.name});
                        return null;
                    }
                }
            }
        }
    }
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        if (blk.terminator == .Branch) {
            const cond = blk.terminator.Branch.cond;
            if (cond.int() >= n_regs or !isScalarRt(typeAt(types, cond))) {
                if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: branch-unknown\n", .{func.name});
                return null;
            }
        }
    }

    // Def set: every register written somewhere in the body (reboxed on deopt).
    const def = try a.alloc(bool, n_regs);
    defer if (!ok) a.free(def);
    @memset(def, false);
    // read set is unused in function mode (no entry unbox); allocate an empty.
    const read = try a.alloc(bool, n_regs);
    defer if (!ok) a.free(read);
    @memset(read, false);

    var call_sites: std.ArrayListUnmanaged(CallSite) = .empty;
    defer if (!ok) call_sites.deinit(a);

    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        for (blk.insts, 0..) |*inst, i| {
            if (instAnyDst(inst)) |d| {
                if (d.int() < n_regs) def[d.int()] = true;
            }
            const tc = trampolinableCallOf(inst) orelse continue;
            if (inlinedAt(inline_sites.items, bid.int(), @intCast(i))) continue; // spliced in place
            if (directAt(direct_sites.items, bid.int(), @intCast(i))) |ds| {
                // Called straight into the callee's code, so no trampoline site
                // and no boxing — but the argument kinds this body actually
                // holds must be the ones the callee was compiled for.
                var dk: u32 = 1;
                while (dk < ds.n_args) : (dk += 1) {
                    const ar = ds.args_reg + dk;
                    if (ar >= n_regs or types[ar] != ds.callee.param_rt[dk]) {
                        if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: direct-arg-kind\n", .{func.name});
                        return null;
                    }
                }
                ds.has_result = tc.dst.int() < n_regs and isScalarRt(typeAt(types, tc.dst));
                if (ds.has_result and typeAt(types, tc.dst) != ds.callee.result_rt) {
                    if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: direct-result-kind\n", .{func.name});
                    return null;
                }
                continue;
            }
            // A suspend callee would park through the trampoline; every
            // function-mode body must be suspension-free so a flat-driver
            // native run's outcomes stay RETURN / throw / deopt only.
            if (module.funcById(tc.func)) |cf| {
                // A bodyless callee is an abstract-member static anchor: the
                // interpreted Call arm re-dispatches it virtually on the
                // receiver, which a raw callFunc cannot.
                if (cf.is_suspend or !cf.hasBody()) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4517\n", .{func.name}); return null; }
            } else { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4518\n", .{func.name}); return null; }
            // Args must already live in typed scalar slots.
            var k: u8 = 0;
            while (k < tc.n_args) : (k += 1) {
                const ar = tc.args_reg + k;
                if (ar >= n_regs or !isScalarRt(types[ar])) {
                    if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: call-arg-kind\n", .{func.name});
                    return null;
                }
            }
            var span: ?ir.Span = null;
            var bj: usize = i;
            while (bj > 0) {
                bj -= 1;
                if (blk.insts[bj] == .Trace) {
                    span = blk.insts[bj].Trace.span;
                    break;
                }
            }
            const has_result = tc.dst.int() < n_regs and isScalarRt(typeAt(types, tc.dst));
            call_sites.append(a, .{
                .func = tc.func,
                .args_reg = tc.args_reg,
                .n_args = tc.n_args,
                .dst_reg = tc.dst.int(),
                .has_result = has_result,
                .block = bid,
                .inst = @intCast(i),
                .span = span,
            }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4544\n", .{func.name}); return null; };
        }
    }

    // Member / virtual trampoline sites (object receiver seeded in a frame
    // register; scalar args from typed slots; an object result boxes into
    // the frame register, a scalar one fills its slot). No entry class
    // guard: dispatch is dynamic per receiver.
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        for (blk.insts, 0..) |*inst, i| {
            // The receiver Move an inlined self-call consumed is spliced away:
            // registering it as an object move would put a boxed copy back and
            // make the method need a frame again.
            if (skippedAt(skip_insts.items, bid.int(), @intCast(i))) continue;
            if (inst.* == .Move) {
                // An object move copies one boxed FRAME register into another
                // — the handler does it; the native scalar Move would copy a
                // garbage slot (object registers are not slot-backed).
                const m = inst.Move;
                const obj_mv = typeAt(types, m.dst) == .object or typeAt(types, m.src) == .object or
                    typeAt(types, m.src) == .null_;
                if (obj_mv) {
                    if (m.dst.int() >= n_regs or m.src.int() >= n_regs) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: objmove-reg\n", .{func.name}); return null; }
                    var span6: ?ir.Span = null;
                    var bj6: usize = i;
                    while (bj6 > 0) {
                        bj6 -= 1;
                        if (blk.insts[bj6] == .Trace) {
                            span6 = blk.insts[bj6].Trace.span;
                            break;
                        }
                    }
                    call_sites.append(a, .{
                        .dst_reg = m.dst.int(),
                        .src_reg = m.src.int(),
                        .block = bid,
                        .inst = @intCast(i),
                        .span = span6,
                        .is_obj_move = true,
                    }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4740\n", .{func.name}); return null; };
                }
                continue;
            }
            if (trampolinableGlobalOf(module, inst)) |lg| {
                // Global read: the handler boxes the value into the frame
                // register (a missing global deopts; the interpreter re-runs
                // the read and raises properly).
                if (lg.dst.int() >= n_regs or typeAt(types, lg.dst) != .object) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: global-kind\n", .{func.name}); return null; }
                var span4: ?ir.Span = null;
                var bj4: usize = i;
                while (bj4 > 0) {
                    bj4 -= 1;
                    if (blk.insts[bj4] == .Trace) {
                        span4 = blk.insts[bj4].Trace.span;
                        break;
                    }
                }
                call_sites.append(a, .{
                    .dst_reg = lg.dst.int(),
                    .name = lg.name,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span4,
                    .is_load_global = true,
                }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4676\n", .{func.name}); return null; };
                continue;
            }
            if (inst.* == .GetField) {
                var covered = false;
                for (field_pres.items) |fp3| {
                    if (fp3.block == bid.int() and fp3.inst == i) covered = true;
                }
                if (!covered) {
                    // By-name field read on a varying receiver: the handler
                    // resolves the stored index on the live receiver per call
                    // and boxes the value into the frame register; a getter
                    // property or non-Instance receiver deopts (the read is
                    // pure, so the interpreter re-runs it).
                    if (field_resolver == null) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: field-host\n", .{func.name}); return null; }
                    const tf = trampolinableFieldOf(module, inst) orelse { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: field-name\n", .{func.name}); return null; };
                    if (tf.recv.int() >= n_regs or typeAt(types, tf.recv) != .object) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: field-recv\n", .{func.name}); return null; }
                    if (tf.dst.int() >= n_regs or typeAt(types, tf.dst) != .object) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: field-dst\n", .{func.name}); return null; }
                    var span5: ?ir.Span = null;
                    var bj5: usize = i;
                    while (bj5 > 0) {
                        bj5 -= 1;
                        if (blk.insts[bj5] == .Trace) {
                            span5 = blk.insts[bj5].Trace.span;
                            break;
                        }
                    }
                    call_sites.append(a, .{
                        .dst_reg = tf.dst.int(),
                        .recv_reg = tf.recv.int(),
                        .name = memberFieldName(tf.name),
                        .block = bid,
                        .inst = @intCast(i),
                        .span = span5,
                        .is_field = true,
                        .field_named = true,
                        .recv_varies = true,
                        .has_result = true,
                    }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4705\n", .{func.name}); return null; };
                }
                continue;
            }
            // A numeric conversion or a bitwise op spells as a member or
            // virtual call on a SCALAR receiver, and the emitter lowers both
            // inline. Reaching the member branch rejected the whole body for a
            // non-object receiver, so a method doing `k.toLong()` or `x shl 3`
            // never compiled.
            if (nativeScalarCallShape(module, inst, types, n_regs)) continue;
            const kind: enum { member, virt } = if (trampolinableMemberOf(module, inst) != null) .member else if (trampolinableVirtualOf(inst) != null) .virt else continue;
            // The receiver register must be object-typed: the handler reads
            // its value from the FRAME, which holds every object def (handler
            // deliveries, object moves, seeded params). An unknown-typed one
            // has an unclassified def; a scalar one lives in a slot.
            {
                const rreg: Reg = if (kind == .member) trampolinableMemberOf(module, inst).?.recv else trampolinableVirtualOf(inst).?.recv;
                if (rreg.int() >= n_regs or typeAt(types, rreg) != .object) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: recv-kind\n", .{func.name}); return null; }
            }
            const args_reg: u32 = if (kind == .member) trampolinableMemberOf(module, inst).?.args_reg else trampolinableVirtualOf(inst).?.args_reg;
            const n_args: u32 = if (kind == .member) trampolinableMemberOf(module, inst).?.n_args else trampolinableVirtualOf(inst).?.n_args;
            const dst: Reg = if (kind == .member) trampolinableMemberOf(module, inst).?.dst else trampolinableVirtualOf(inst).?.dst;
            var k: u8 = 0;
            while (k < n_args) : (k += 1) {
                const ar = args_reg + k;
                if (ar >= n_regs or !(isScalarRt(types[ar]) or types[ar] == .object or types[ar] == .null_)) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4562\n", .{func.name}); return null; }
            }
            var span: ?ir.Span = null;
            var bj: usize = i;
            while (bj > 0) {
                bj -= 1;
                if (blk.insts[bj] == .Trace) {
                    span = blk.insts[bj].Trace.span;
                    break;
                }
            }
            const has_result = dst.int() < n_regs and (isScalarRt(typeAt(types, dst)) or typeAt(types, dst) == .object);
            if (kind == .member) {
                const mc = trampolinableMemberOf(module, inst).?;
                if (debugEnabled()) std.debug.print("[jit-dbg] fsite member {s}.{s} resolved={?} declared={s} recv_reg={d}\n", .{ func.name, mc.name, if (mc.resolved) |f2| f2.int() else null, mc.declared, mc.recv.int() });
                call_sites.append(a, .{
                    .func = @enumFromInt(0),
                    .args_reg = args_reg,
                    .n_args = n_args,
                    .dst_reg = dst.int(),
                    .has_result = has_result,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_member = true,
                    .recv_reg = mc.recv.int(),
                    .name = mc.name,
                    .resolved_member = mc.resolved,
                    .declared_name = mc.declared,
                    .recv_class = 0,
                }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4591\n", .{func.name}); return null; };
            } else {
                const vc = trampolinableVirtualOf(inst).?;
                call_sites.append(a, .{
                    .func = @enumFromInt(0),
                    .args_reg = args_reg,
                    .n_args = n_args,
                    .dst_reg = dst.int(),
                    .has_result = has_result,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_virtual = true,
                    .virt_slot = vc.slot,
                    .recv_reg = vc.recv.int(),
                }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4606\n", .{func.name}); return null; };
            }
        }
    }

    // ESCAPE sites: one per instruction the scan marked; the callback runs
    // the interpreter's own arm with a full scalar spill/unspill around it.
    for (escape_pos.items) |ep| {
        const blk = &func.blocks[ep.b];
        var span3: ?ir.Span = null;
        var bj: usize = ep.i;
        while (bj > 0) {
            bj -= 1;
            if (blk.insts[bj] == .Trace) {
                span3 = blk.insts[bj].Trace.span;
                break;
            }
        }
        call_sites.append(a, .{
            .dst_reg = 0,
            .block = BlockId.from(ep.b),
            .inst = ep.i,
            .span = span3,
            .is_exec = true,
            .exec_inst = &blk.insts[ep.i],
        }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4631\n", .{func.name}); return null; };
    }

    // `this`-field sites: native memory accesses through the entry-seeded
    // field-buffer pointer (the slot index is filled in below, after the
    // layout is settled).
    // Trampoline-density profitability: every non-native site is a host
    // round-trip that costs about as much as the interpreted instruction it
    // replaces, and a tiny body's native entry (slot setup, seeding, tag
    // copy) costs more than its walk. Compile only when enough plain native
    // instructions amortize the overhead; the measurement behind the
    // thresholds is the compose replica, where the ungated tier ran a net
    // ~3% SLOWER (KLIO_FJ_MINPROFIT=insts,K overrides for re-measurement).
    {
        var total_insts3: u32 = 0;
        for (body) |bid3| total_insts3 += @intCast(func.blocks[bid3.int()].insts.len);
        var min_insts: u32 = 8;
        var site_k: u32 = 4;
        if (runtime.envOnce("KLIO_FJ_MINPROFIT")) |raw| {
            var it3 = std.mem.splitScalar(u8, raw, ',');
            if (it3.next()) |x| min_insts = std.fmt.parseInt(u32, x, 10) catch min_insts;
            if (it3.next()) |x| site_k = std.fmt.parseInt(u32, x, 10) catch site_k;
        }
        const tramp_sites: u32 = @intCast(call_sites.items.len);
        if (tramp_sites != 0 and (total_insts3 < min_insts or tramp_sites * site_k > total_insts3)) {
            if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: tramp-heavy ({d} sites / {d} insts)\n", .{ func.name, tramp_sites, total_insts3 });
            return null;
        }
    }
    // A spliced callee's `this`-field ops become the caller's own native field
    // sites, contiguous per site so the inline emit can index them in body
    // order. The receiver is the caller's `this` (a SELF call), so they ride the
    // same entry field-base and stay native — no trampoline, so the method can
    // still run frameless at the seam.
    for (inline_sites.items) |*site| {
        site.field_site_base = @intCast(call_sites.items.len + field_pres.items.len);
        var nf: u32 = 0;
        var forder_buf: [INLINE_MAX_BLOCKS]u32 = undefined;
        const forder = calleeBlockOrder(site.callee, &forder_buf) orelse return null;
        for (forder) |fb| for (site.callee.blocks[fb].insts) |*ci| {
            const is_set = trampolinableFieldSetOf(module, ci) != null;
            const fname = if (trampolinableFieldOf(module, ci)) |fld|
                memberFieldName(fld.name)
            else if (trampolinableFieldSetOf(module, ci)) |fs|
                memberFieldName(fs.name)
            else
                continue;
            if (params.len == 0 or params[0] != .Instance) return null;
            const idx = (field_resolver orelse return null)(resolver_user.?, &params[0], fname) orelse return null;
            const reg: u32 = if (is_set)
                site.base + trampolinableFieldSetOf(module, ci).?.value.int()
            else
                site.base + trampolinableFieldOf(module, ci).?.dst.int();
            if (reg >= total_regs or !isScalarRt(typeAt(types, Reg.from(reg)))) return null;
            const fv: Value = blk_fv: {
                const g = params[0].Instance.borrow();
                defer g.deinit();
                const items = g.get().fields.items;
                if (idx >= items.len) return null;
                break :blk_fv items[idx].value;
            };
            const nn = !is_set and field_nn_resolver != null and
                field_nn_resolver.?(resolver_user.?, &params[0], fname) != null;
            field_pres.append(a, .{
                .block = site.block.int(),
                .inst = site.inst,
                .idx = idx,
                .rt = typeAt(types, Reg.from(reg)),
                .tag = @intFromEnum(std.meta.activeTag(fv)),
                .is_set = is_set,
                .dst_or_src = reg,
                .nn = nn,
                .name = fname,
            }) catch return null;
            nf += 1;
        };
        site.n_field_sites = nf;
    }

    const field_sites_base: usize = call_sites.items.len;
    for (field_pres.items) |fp| {
        var span2: ?ir.Span = null;
        {
            const blk = &func.blocks[fp.block];
            var bj: usize = fp.inst;
            while (bj > 0) {
                bj -= 1;
                if (blk.insts[bj] == .Trace) {
                    span2 = blk.insts[bj].Trace.span;
                    break;
                }
            }
        }
        call_sites.append(a, .{
            .dst_reg = if (fp.is_set) 0 else fp.dst_or_src,
            .src_reg = if (fp.is_set) fp.dst_or_src else 0,
            .has_result = !fp.is_set,
            .block = BlockId.from(fp.block),
            .inst = fp.inst,
            .span = span2,
            .is_field = !fp.is_set,
            .is_field_set = fp.is_set,
            .native = true,
            .field_idx = fp.idx,
            .tag = fp.tag,
            .nn = fp.nn,
        }) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4664\n", .{func.name}); return null; };
    }

    // Deopt-freedom: no tramp calls (the sites before `field_sites_base` are
    // exactly the trampolined Calls), no division, every read NN-proven.
    var all_reads_nn = true;
    for (field_pres.items) |fp| {
        if (!fp.is_set and !fp.nn) all_reads_nn = false;
    }
    var writes_fields = false;
    for (field_pres.items) |fp| {
        if (fp.is_set) writes_fields = true;
    }
    // A direct call into a callee that can deopt gives THIS body a deopt edge
    // of its own: the site re-runs the call from the interpreter, which needs a
    // frame to resume into, so the body no longer qualifies for the frameless
    // seam.
    var direct_may_deopt = false;
    for (direct_sites.items) |*ds| {
        if (ds.may_deopt) direct_may_deopt = true;
    }
    const can_deopt = direct_may_deopt or !(is_method and field_sites_base == 0 and !has_div and all_reads_nn);
    if (can_deopt and is_method and debugEnabled()) {
        // Which condition refused this method the seam — the histogram that says
        // where the next widening belongs.
        std.debug.print("[jit]   method {s} can deopt: tramp-calls={d} div={} reads-nn={}\n", .{
            func.name, field_sites_base, has_div, all_reads_nn,
        });
    }

    const has_calls = call_sites.items.len != 0;
    const param_slot_base: u32 = total_regs;
    const after_params: u32 = total_regs + n_params;
    const uc_slot: u32 = after_params;
    const tramp_slot: u32 = after_params + 1;
    const calls_base: u32 = after_params + (if (has_calls) @as(u32, 2) else 0);
    const fbase_slot: u32 = calls_base;
    const result_slot: u32 = calls_base + (if (is_method) @as(u32, 1) else 0);
    const result_reg_slot: u32 = result_slot + 1;
    // A direct callee runs on a slot window carved out of this body's own slot
    // array, so a call is a pointer bump: no allocation, no frame. One window
    // serves every direct call here — only one is ever live at a time, and a
    // callee's own nested calls already fit inside its `n_slots`.
    var n_slots: u32 = result_reg_slot + 1;
    if (direct_sites.items.len != 0) {
        var window: u32 = 0;
        for (direct_sites.items) |*ds| {
            ds.slot_base = n_slots;
            ds.fbase_slot = fbase_slot;
            if (ds.callee.n_slots > window) window = ds.callee.n_slots;
        }
        n_slots += window;
        // 192 is the seam's per-depth slot bank: a body that outgrows it falls
        // off the frameless path, which costs more than the call it saves.
        if (n_slots > MAX_SLOTS) { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: direct-slots\n", .{func.name}); return null; }
    }
    for (call_sites.items[field_sites_base..]) |*site| site.fbase_slot = fbase_slot;

    var c = Compiler{
        .a = a,
        .module = module,
        .func = func,
        .body = body,
        .types = types,
        .array_info = &.{},
        .cell_info = &.{},
        .call_sites = call_sites.items,
        .inline_sites = inline_sites.items,
        .direct_sites = direct_sites.items,
        .nullable = &.{},
        .null_flag_slot = &.{},
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .entry_fbase_slot = fbase_slot,
        .n_regs = n_regs,
        .reg_slots = n_slots,
        .val_payload_off = valuePayloadOffset(),
        .val_tag_off = valueTagOffset(),
        .func_mode = true,
        .method_mode = is_method,
        .param_slot_base = param_slot_base,
        .n_params = n_params,
        .result_slot = result_slot,
        .result_reg_slot = result_reg_slot,
        .em = jit.Emitter.init(a),
        .block_label = try a.alloc(?jit.Label, func.blocks.len),
        .exit_targets = .empty,
        .exit_labels = .empty,
        .deopt_codes = .empty,
        .deopt_labels = .empty,
        .epilogue = undefined,
    };
    defer c.em.deinit();
    defer a.free(c.block_label);
    defer c.exit_targets.deinit(a);
    defer c.exit_labels.deinit(a);
    defer c.deopt_codes.deinit(a);
    defer c.deopt_labels.deinit(a);
    @memset(c.block_label, null);

    for (body) |bid| c.block_label[bid.int()] = c.em.newLabel() catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4725\n", .{func.name}); return null; };
    c.epilogue = c.em.newLabel() catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4726\n", .{func.name}); return null; };

    c.run() catch |e| {
        if (debugEnabled()) std.debug.print("[jit]   bail: func codegen {s} in {s}\n", .{ @errorName(e), func.name });
        { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4730\n", .{func.name}); return null; }
    };

    const exec = jit.finalize(c.em.code()) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4733\n", .{func.name}); return null; };
    const sites_owned = call_sites.toOwnedSlice(a) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4734\n", .{func.name}); return null; };
    // Function mode restricts returns/params to exact `Int`-boxing kinds (see
    // `exact_ret`), so the default `Int` tag is correct for every register.
    const fn_tags = a.alloc(u8, n_regs) catch {
        a.free(sites_owned);
        { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4739\n", .{func.name}); return null; }
    };
    @memset(fn_tags, INT_TAG);
    const obj_loads_owned: []ObjParamLoad = if (obj_loads.len != 0)
        (a.dupe(ObjParamLoad, obj_loads) catch return null)
    else
        &.{};
    const cap_loads_owned: []ObjParamLoad = if (cap_loads.len != 0)
        (a.dupe(ObjParamLoad, cap_loads) catch return null)
    else
        &.{};
    // A direct callee reads and writes `this` through ITS OWN field indexes on
    // the same receiver, and its entry guard never runs (the call bypasses it),
    // so those (index, name) pairs join this body's — one entry check covers
    // both bodies.
    const method_fields_owned: []MethodFieldCheck = blk: {
        var n_mf: usize = field_pres.items.len;
        for (direct_sites.items) |*ds| n_mf += ds.callee.method_fields.len;
        if (n_mf == 0) break :blk &.{};
        const out2 = a.alloc(MethodFieldCheck, n_mf) catch { if (debugEnabled()) std.debug.print("[jit]   fdecl {s}@L4748\n", .{func.name}); return null; };
        for (field_pres.items, out2[0..field_pres.items.len]) |fp, *o| o.* = .{ .idx = fp.idx, .name = fp.name };
        var mf_n: usize = field_pres.items.len;
        for (direct_sites.items) |*ds| {
            for (ds.callee.method_fields) |mf| {
                out2[mf_n] = mf;
                mf_n += 1;
            }
        }
        break :blk out2;
    };
    // Re-verify every (index, name) pair and read the layout id under ONE
    // borrow: an entry matching this shape at run time provably has each
    // name at its index, so the per-entry loop is skipped.
    var guard_shape: u64 = 0;
    if (is_method and method_fields_owned.len != 0) {
        const gsh = params[0].Instance.borrow();
        defer gsh.deinit();
        const bsh = gsh.get();
        var all_ok = true;
        for (method_fields_owned) |mf| {
            if (mf.idx >= bsh.fields.items.len or
                !(bsh.fields.items[mf.idx].name.ptr == mf.name.ptr or std.mem.eql(u8, bsh.fields.items[mf.idx].name, mf.name)))
            {
                all_ok = false;
                break;
            }
        }
        if (all_ok) {
            const sp = bsh.shapeOf();
            if (sp > 1) guard_shape = sp;
        }
    }
    ok = true;
    return CompiledLoop{
        .exec = exec,
        .n_regs = n_regs,
        .n_slots = n_slots,
        .reg_types = types,
        .box_tags = fn_tags,
        .read_set = read,
        .def_set = def,
        .arrays = &.{},
        .cells = &.{},
        .nullables = &.{},
        .field_bases = &.{},
        .call_sites = sites_owned,
        .member_ics = blk: {
            const ics = a.alloc(MemberIC, sites_owned.len) catch break :blk &.{};
            @memset(ics, .{});
            break :blk ics;
        },
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .func_mode = true,
        .n_params = n_params,
        .param_slot_base = param_slot_base,
        .result_slot = result_slot,
        .result_rt = result_rt,
        .param_rt = param_rt,
        .method_mode = is_method,
        .guard_class = if (is_method) instanceClassIdentity(params[0]) else 0,
        .entry_fbase_slot = fbase_slot,
        .no_native_recurse = is_method,
        .can_deopt = can_deopt,
        .writes_fields = writes_fields,
        .has_tramp_sites = field_sites_base != 0,
        .obj_param_loads = obj_loads_owned,
        .capture_loads = cap_loads_owned,
        .method_fields = method_fields_owned,
        .guard_shape = guard_shape,
        .result_reg_slot = result_reg_slot,
        .direct_sites = if (direct_sites.items.len != 0)
            (a.dupe(DirectSite, direct_sites.items) catch return null)
        else
            &.{},
        .self_dbg_name = func.name,
        .allocator = a,
    };
}
