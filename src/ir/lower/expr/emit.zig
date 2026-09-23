//! Call emission: the member/global, value, object and extension bare tails.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const ConstId = ir.ConstId;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const Func = ir.Func;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunWithArity = helpers.lowerArgRunWithArity;
const lowerArgRunFull = helpers.lowerArgRunFull;
const internArgNames = helpers.internArgNames;
const exprSpan = helpers.exprSpan;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const receiver_mod = @import("receiver.zig");
const overloadPickByLambdaReturn = receiver_mod.overloadPickByLambdaReturn;

const paths_mod = @import("paths.zig");
const ownMemberRejectsLambdas = paths_mod.ownMemberRejectsLambdas;

const member_mod = @import("member.zig");
const staticTypeDeclaresProp = member_mod.staticTypeDeclaresProp;

const lambda_mod = @import("lambda.zig");
const implicit_walk = @import("implicit_walk.zig");
const argFnArities = lambda_mod.argFnArities;
const argFnGenericFlags = lambda_mod.argFnGenericFlags;
const argLambdaBroadMasks = lambda_mod.argLambdaBroadMasks;
const argLambdaParamTypes = lambda_mod.argLambdaParamTypes;
const argLambdaParamTypesRecv = lambda_mod.argLambdaParamTypesRecv;
const deinitArgLambdaParamTypes = lambda_mod.deinitArgLambdaParamTypes;
const overloadHostingTrailingLambda = lambda_mod.overloadHostingTrailingLambda;
const recordLambdaArgReceivers = lambda_mod.recordLambdaArgReceivers;

const compose_mod = @import("compose.zig");
const hasComposerArgPair = compose_mod.hasComposerArgPair;
const hasThreadedComposerParams = compose_mod.hasThreadedComposerParams;
const selectedCallArgsForBuilder = compose_mod.selectedCallArgsForBuilder;

const call_mod = @import("call.zig");
const lastArgIsLambda = call_mod.lastArgIsLambda;
const resolveThisForBareCall = call_mod.resolveThisForBareCall;

const static_type_mod = @import("static_type.zig");
const type_probe = @import("type_probe.zig");
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const bare_call_mod = @import("bare_call.zig");
const allNull = bare_call_mod.allNull;
const lowerImplicitThisCall = bare_call_mod.lowerImplicitThisCall;
const lowerUnresolvedBareCall = bare_call_mod.lowerUnresolvedBareCall;

const core_inst = @import("../../core/inst.zig");
const probe_mod = @import("probe.zig");
const inReceiverContext = probe_mod.inReceiverContext;
const isNonExt = probe_mod.isNonExt;
const overloadParamTypeConflicts = probe_mod.overloadParamTypeConflicts;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const orEmitAudit = audit_mod.orEmitAudit;

const expected_mod = @import("expected.zig");
const applyExpectedLiteralKindsToArgs = expected_mod.applyExpectedLiteralKindsToArgs;
const spliceReifiedTypeArgs = expected_mod.spliceReifiedTypeArgs;

/// Lower a tail jump's arguments in Kotlin's evaluation order, written arguments
/// first and then omitted parameters' defaults in parameter order, laid out by
/// parameter slot. Null when the call cannot become a jump.
pub fn emitTailJumpRun(b: *FuncBuilder, receiver: ?*const Expr, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!?[2]Reg {
    const params = b.tailrecParams();
    const lead: usize = if (receiver != null) 1 else 0;
    var any_named = false;
    for (arg_names) |n| if (n != null) {
        any_named = true;
    };
    if (!any_named and args.len >= params.len) {
        const all = try b.allocator.alloc(Expr, lead + args.len);
        defer b.allocator.free(all);
        if (receiver) |r| all[0] = r.*;
        for (args, 0..) |arg, i| all[lead + i] = arg;
        const run = try lowerArgRun(b, all);
        return .{ run[0], Reg.from(@intCast(run[1])) };
    }
    const n_regular = params.len;
    const slots = try b.allocator.alloc(?Reg, lead + n_regular);
    defer b.allocator.free(slots);
    @memset(slots, null);
    if (receiver) |r| slots[0] = try lowerExpr(b, r);
    var next_pos: usize = 0;
    for (args, 0..) |*arg, i| {
        const name: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        var slot: ?usize = null;
        if (name) |nm| {
            for (params, 0..) |p, pi| if (std.mem.eql(u8, p.name.name, nm)) {
                slot = pi;
                break;
            };
        } else {
            while (next_pos < n_regular and slots[lead + next_pos] != null) next_pos += 1;
            if (next_pos < n_regular) slot = next_pos;
        }
        const si = slot orelse return null;
        slots[lead + si] = try lowerExpr(b, arg);
    }
    for (params, 0..) |p, pi| {
        if (slots[lead + pi] != null) continue;
        const d = p.default orelse return null;
        slots[lead + pi] = try lowerExpr(b, d);
    }
    const first = b.allocReg();
    var k: usize = 1;
    while (k < slots.len) : (k += 1) _ = b.allocReg();
    for (slots, 0..) |sv, si| {
        try b.push(.{ .Move = .{ .dst = Reg.from(first.int() + @as(u32, @intCast(si))), .src = sv.? } });
    }
    return .{ first, Reg.from(@intCast(slots.len)) };
}

fn tailJumpArgs(b: *FuncBuilder, receiver: ?*const Expr, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!?[]Expr {
    const params = b.tailrecParams();
    const lead: usize = if (receiver != null) 1 else 0;
    var any_named = false;
    for (arg_names) |n| if (n != null) {
        any_named = true;
    };
    if (!any_named and args.len > params.len) {
        // More arguments than declared parameters (a vararg): keep as written.
        const all = try b.allocator.alloc(Expr, lead + args.len);
        if (receiver) |r| all[0] = r.*;
        for (args, 0..) |arg, i| all[lead + i] = arg;
        return all;
    }
    const n_regular = params.len;
    const all = try b.allocator.alloc(Expr, lead + n_regular);
    errdefer b.allocator.free(all);
    const filled = try b.allocator.alloc(bool, n_regular);
    defer b.allocator.free(filled);
    @memset(filled, false);
    if (receiver) |r| all[0] = r.*;
    var next_pos: usize = 0;
    for (args, 0..) |arg, i| {
        const name: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        var slot: ?usize = null;
        if (name) |nm| {
            for (params, 0..) |p, pi| if (std.mem.eql(u8, p.name.name, nm)) {
                slot = pi;
                break;
            };
        } else {
            while (next_pos < n_regular and filled[next_pos]) next_pos += 1;
            if (next_pos < n_regular) slot = next_pos;
        }
        const si = slot orelse return null;
        all[lead + si] = arg;
        filled[si] = true;
    }
    for (params, 0..) |p, pi| {
        if (filled[pi]) continue;
        const d = p.default orelse return null;
        all[lead + pi] = d.*;
    }
    return all;
}

/// The `Call` emit form: a resolved bare-name static call, lowering to a direct
/// `Call` or a `TailCallFunc`. An extension target routes through
/// `emitExtBareCall`, which prepends `this`.
pub fn emitCall(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    if (runtime.envOnce("KLIO_EMIT_TRACE") != null) {
        const c0 = call.callee;
        if (c0.* == .Path and c0.Path.segments.len == 1 and std.mem.eql(u8, c0.Path.segments[0].name, "remember") and @intFromEnum(c0.Path.segments[0].span.file) == 0) {
            std.debug.print("[emitCall] remember -> #{d} nargs={d}\n", .{ func_id.int(), call.args.len });
            runtime.trace.dumpCurrent(.{});
        }
    }
    var selected_args = try selectedCallArgsForBuilder(b, func_id, call.args, call.arg_names, exprSpan(call.callee), call.has_trailing_lambda);
    defer selected_args.deinit(b.allocator);
    const args = selected_args.args;
    const ast_arg_names = selected_args.names;
    const ast_type_args = call.type_args;
    const prev_trailing = b.setCallTrailingLambda(
        call.has_trailing_lambda and !hasComposerArgPair(ast_arg_names),
    );
    defer _ = b.setCallTrailingLambda(prev_trailing);

    // The committed target is overload-precise, so its receiver-function
    // parameter types are authoritative even for an alias callee.
    if (b.module.funcById(func_id)) |f| {
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
        applyExpectedLiteralKindsToArgs(b, f, args, ast_arg_names, recv_off);
    }

    const needs_this = blk: {
        if (b.module.funcById(func_id)) |f| {
            break :blk f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        }
        break :blk false;
    };
    if (needs_this) {
        const this_reg_opt = try resolveThisForBareCall(b);
        if (this_reg_opt) |this_reg0| {
            const this_reg = blk: {
                const c0 = call.callee;
                if (c0.* == .Path and c0.Path.segments.len == 1) {
                    break :blk subjectCorrectedBareThis(b, c0.Path.segments[0].name, this_reg0);
                }
                break :blk this_reg0;
            };
            return emitExtBareCall(b, expr, func_id, this_reg, was_cast);
        }
        // No `this` in scope: fall through to the unmodified Call below.
    }

    const callee_is_tailrec = blk: {
        if (b.module.funcById(func_id)) |f| {
            if (f.is_tailrec) break :blk true;
        }
        break :blk false;
    };
    // Only a call in tail position is a tail call: `return 1 + f(x - 1)` adds.
    if (b.tail_call_ok and b.tailrecSelf() != null and callee_is_tailrec and allNull(ast_arg_names)) {
        const run = try lowerArgRun(b, args);
        b.terminate(.{ .TailCallFunc = .{ .func = func_id, .args = run[0], .n_args = run[1] } });
        const dead = try b.allocBlock();
        b.switchTo(dead);
        return b.emitConst(.Unit);
    }
    // `resolveCall` routes a call a runtime receiver could shadow to
    // `emitMemberOrGlobal`, so the static call is already committed here.
    const arg_arity: ?[]const i16 = blk: {
        if (b.module.funcById(func_id)) |f| {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            break :blk try argFnArities(b, f, args, ast_arg_names, recv_off);
        }
        break :blk null;
    };
    const param_ty_names: ?[]const ?[]const u8 = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        if (!allNull(ast_arg_names)) break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const names = try b.allocator.alloc(?[]const u8, args.len);
        for (names, 0..) |*t, j| {
            const pidx = recv_off + j;
            if (pidx < f.params.len and !f.params[pidx].is_vararg and
                !overloadParamTypeConflicts(b.module, f, pidx))
            {
                t.* = f.params[pidx].ty.name;
            } else {
                t.* = null;
            }
        }
        break :blk names;
    };
    defer if (param_ty_names) |pt| b.allocator.free(pt);
    const broad_masks: ?[]u32 = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (broad_masks) |m| b.allocator.free(m);
    b.pending_arg_broad_masks = broad_masks;
    const fn_generic: ?[]bool = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argFnGenericFlags(b, f, args, ast_arg_names, recv_off);
    };
    defer if (fn_generic) |m| b.allocator.free(m);
    b.pending_arg_fn_generic = fn_generic;
    var lpt_recv_owned: ?ir.TypeRef = null;
    defer if (lpt_recv_owned) |*t| t.deinit(b.allocator);
    const lambda_param_types: ?[]?[]ir.TypeRef = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and
            std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        // A member-form call to an extension carries its receiver in the callee,
        // so derive it and let the lambda's params instantiate.
        const recv_ptr: ?*const ir.TypeRef = rp: {
            if (recv_off != 1) break :rp null;
            const ce = expr.Call.callee;
            if (ce.* != .Member) break :rp null;
            lpt_recv_owned = staticExprTypeRef(b, ce.Member.receiver) catch null;
            break :rp if (lpt_recv_owned) |*t| t else null;
        };
        if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] emitCall fn={s} recv={s} callee={s} roff={d}\n", .{ f.name, if (recv_ptr) |r| r.name else "<null>", @tagName(std.meta.activeTag(expr.Call.callee.*)), recv_off });
        break :blk try argLambdaParamTypesRecv(
            b,
            f,
            args,
            ast_arg_names,
            ast_type_args,
            recv_off,
            recv_ptr,
        );
    };
    defer if (lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = lambda_param_types;
    const run = try lowerArgRunFull(b, args, arg_arity, param_ty_names);
    // A trailing lambda always binds the target's last, function-typed parameter.
    // With a vararg before it, positional binding would pack the lambda into the
    // vararg, since Kotlin forbids a positional argument after a vararg.
    const arg_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    var type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    if (type_args.len == 0) {
        if (try spliceReifiedTypeArgs(b, func_id, args.len)) |stamped| type_args = stamped;
    }
    const dst = b.allocReg();
    const ctx_handed = try probe_mod.contextHandoverBegin(b, func_id, ast_type_args);
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = was_cast,
    } });
    try probe_mod.contextHandoverEnd(b, ctx_handed);
    return dst;
}

/// The `CallMember` emit form: a resolved extension bound on the implicit `this`
/// with member precedence. Routes through `emitExtBareCall`; with no `this` in
/// scope it degrades to `emitCall`.
pub fn emitCallMember(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    if (try resolveThisForBareCall(b)) |this_reg0| {
        const this_reg = blk: {
            const c0 = expr.Call.callee;
            if (c0.* == .Path and c0.Path.segments.len == 1) {
                break :blk subjectCorrectedBareThis(b, c0.Path.segments[0].name, this_reg0);
            }
            break :blk this_reg0;
        };
        return emitExtBareCall(b, expr, func_id, this_reg, was_cast);
    }
    return emitCall(b, expr, func_id, was_cast);
}

/// Whether an extension property or function named `name` is declared for `head`
/// or a registered supertype: its getter has a leading `this` whose declared
/// receiver the head is or extends.
pub fn extensionPropOnHead(b: *FuncBuilder, head_in: []const u8, name: []const u8) bool {
    const head = typeHead(std.mem.trimEnd(u8, head_in, "?"));
    if (head.len == 0) return false;
    const simple = applicability.simpleName(head);
    if (extPropExistsOn(b, simple, name)) return true;
    for (applicability.builtinSupersOf(simple)) |sup| {
        if (extPropExistsOn(b, sup, name)) return true;
    }
    if (b.module.registry.class_super_names.get(simple)) |chain| {
        for (chain) |sup| {
            if (extPropExistsOn(b, applicability.simpleName(sup), name)) return true;
        }
    }
    return false;
}

/// An extension property `val <head>.<name>` is known either by its declared-type
/// record or by its lowered getter `__ext_get_<head>_<name>`.
fn extPropExistsOn(b: *const FuncBuilder, head: []const u8, name: []const u8) bool {
    if (b.module.registry.ext_prop_type_heads.get(.{ .a = head, .b = name }) != null) return true;
    var buf: [160]u8 = undefined;
    const gname = std.fmt.bufPrint(&buf, "__ext_get_{s}_{s}", .{ head, name }) catch return false;
    return b.module.funcsBySimpleName(gname).len != 0;
}

/// Whether the smart-cast `this` declares `name`. Such a bare name is the
/// narrowed receiver's own, ahead of any same-named global or outer `this`.
pub fn narrowedThisDeclares(b: *const FuncBuilder, name: []const u8, file: ir.FileId) bool {
    const nh = b.thisNarrow() orelse return false;
    const h = typeHead(std.mem.trimEnd(u8, nh, "?"));
    if (h.len == 0) return false;
    if (staticTypeDeclaresProp(b, h, name)) return true;
    const cid = b.module.classIdIndexed(h, b.self_package, file) orelse
        b.module.classId(h) orelse return false;
    return b.module.classHierarchyDeclaresMember(cid, name);
}

pub fn subjectCorrectedBareThis(b: *FuncBuilder, name: []const u8, this_reg: Reg) Reg {
    const sct = if (runtime.envOnce("KLIO_SCT_TRACE")) |w| std.mem.eql(u8, w, name) else false;
    const sbs = b.subject_binds.items;
    if (sbs.len == 0) return this_reg;
    // Only correct when the ambient `this` is the innermost subject; otherwise
    // scope already resolved beneath the subjects.
    if (sbs[sbs.len - 1].reg != this_reg) {
        if (sct) std.debug.print("[sct] {s}: this r{d} != innermost subject r{d}\n", .{ name, this_reg.int(), sbs[sbs.len - 1].reg.int() });
        return this_reg;
    }
    // A smart-cast `this` narrows the innermost subject, so the walk below, which
    // goes by the subjects' declared heads, must not reach an outer `this`.
    if (narrowedThisDeclares(b, name, ir.FileId.from(0))) {
        if (sct) std.debug.print("[sct] {s}: narrowed this declares it\n", .{name});
        return this_reg;
    }
    var i = sbs.len;
    while (i > 0) {
        i -= 1;
        const h = sbs[i].head orelse {
            if (sct) std.debug.print("[sct] {s}: subject {d} head unknown\n", .{ name, i });
            return this_reg;
        };
        const cid = b.module.classIdIndexed(h, b.self_package, ir.FileId.from(0)) orelse
            b.module.classId(h) orelse
            {
                if (sct) std.debug.print("[sct] {s}: head {s} unresolvable\n", .{ name, h });
                return this_reg;
            };
        if (b.module.classHierarchyDeclaresMember(cid, name)) {
            if (sct) std.debug.print("[sct] {s}: subject {d} ({s}) declares it\n", .{ name, i, h });
            return sbs[i].reg;
        }
        // An extension property declared on the subject's type or a supertype
        // binds the bare name to that subject the same way a member does.
        if (extensionPropOnHead(b, h, name)) {
            if (sct) std.debug.print("[sct] {s}: subject {d} ({s}) has an extension property\n", .{ name, i, h });
            return sbs[i].reg;
        }
    }
    if (sct) {
        std.debug.print("[sct] {s}: -> beneath-subjects this {?} (subjects={d}):", .{ name, sbs[0].prior_this, sbs.len });
        for (sbs) |sb| std.debug.print(" [reg=r{d} head={s} prior={?}]", .{ sb.reg.int(), sb.head orelse "-", sb.prior_this });
        std.debug.print("\n", .{});
    }
    return sbs[0].prior_this orelse this_reg;
}

/// The `CallMemberOrGlobal` emit form: member-first dispatch on the runtime
/// implicit receiver, falling back to the resolved global. A resolved extension a
/// The lexical owner's class id, for asking what its hierarchy declares.
pub fn ownerClassIdOf(b: *FuncBuilder, file: ir.FileId) ?ir.ClassId {
    const owner = b.ownerClass() orelse return null;
    return b.module.classIdIndexed(owner, b.self_package, file) orelse b.module.classId(owner);
}

/// member could shadow defers to the pure member-first walk instead.
pub fn emitMemberOrGlobal(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    var selected_args = try selectedCallArgsForBuilder(b, func_id, call.args, call.arg_names, exprSpan(callee), call.has_trailing_lambda);
    defer selected_args.deinit(b.allocator);
    const args = selected_args.args;
    const ast_arg_names = selected_args.names;
    const ast_type_args = call.type_args;
    const name0 = callee.Path.segments[0].name;
    const prev_trailing = b.setCallTrailingLambda(
        call.has_trailing_lambda and !hasComposerArgPair(ast_arg_names),
    );
    defer _ = b.setCallTrailingLambda(prev_trailing);

    // An applicable own member shadows the same-named top-level function in
    // Kotlin's scope order, and binds the member's lambda shapes and receivers.
    if (callee.Path.segments.len == 1 and b.resolve("this") != null and
        b.hasOwnMember(name0) and b.ownFunctionApplicable(name0, call.args.len) and
        !ownMemberRejectsLambdas(b, name0, call.args))
    {
        if (try lowerImplicitThisCall(b, callee, call.args, call.arg_names, ast_type_args)) |r| return r;
    }
    if (audit_mod.orAuditOn() and callee.Path.segments.len == 1) {
        const ocid = ownerClassIdOf(b, callee.Path.segments[0].span.file);
        std.debug.print("[KLIO_OR_AUDIT] gate name={s} this={} own={} applicable={} rejects={} inherited={} owner={s}\n", .{
            name0,
            b.resolve("this") != null,
            b.hasOwnMember(name0),
            b.ownFunctionApplicable(name0, call.args.len),
            ownMemberRejectsLambdas(b, name0, call.args),
            ocid != null and b.module.classHierarchyDeclaresMember(ocid.?, name0),
            b.ownerClass() orelse "-",
        });
    }

    if (!isNonExt(b, func_id)) {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, func_id)) |r| return r;
        return emitCall(b, expr, func_id, was_cast);
    }
    // The member-first form exists because a member could shadow the resolved
    // global, which no receiver in scope makes impossible. A trailing lambda keeps
    // this path anyway: the committed candidate shapes its arity, receiver and
    // composable masks, which the static emit does not carry.
    if (!call.has_trailing_lambda and
        b.resolve("this") == null and b.ownerClass() == null and
        b.recvTy() == null and b.spliceRecvTy() == null)
    {
        orEmitAudit(b, "bare_call_no_receiver_to_shadow", "Call", name0);
        return emitCall(b, expr, func_id, was_cast);
    }
    // The walk the deferred form exists to run, run here: a receiver in scope
    // that declares the sole callable of this arity takes the call, and none
    // declaring it at all leaves the committed global as the only candidate.
    // Only where the resolver's pick is the sole candidate is a proven-global
    // verdict the whole answer: with several, the runtime still ranks the
    // overload by the values, which is a question the walk does not ask.
    var walk_global = false;
    switch (try implicit_walk.walkCall(b, .{ .name = name0, .span = callee.Path.segments[0].span }, args, ast_arg_names, "shadowable")) {
        .global => {
            // A direct call needs a body to run: the deferred form's global
            // leg resolves a bodyless declaration by name at run time.
            const cands = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, args.len);
            const has_body = if (b.module.funcById(func_id)) |gf| gf.hasBody() else false;
            walk_global = has_body and (was_cast or (cands != null and cands.?.len == 1));
        },
        // A receiver whose member accepts the arguments takes the call from
        // the committed global, in Kotlin's scope order.
        .member => |hit| {
            if (try implicit_walk.lowerWalkedMemberCall(b, hit, .{ .name = name0, .span = callee.Path.segments[0].span }, args, ast_arg_names, ast_type_args, "shadowable")) |r| return r;
        },
        .undecided => {},
    }

    const this_idx = try b.recordCapture("this");
    const broad_masks: ?[]u32 = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (broad_masks) |m| b.allocator.free(m);
    b.pending_arg_broad_masks = broad_masks;
    // The trailing lambda's static shape still comes from the committed global
    // candidate, so a `T.() -> R` receiver lambda drops its synthetic `it` here as
    // on the static path.
    const arg_arity: ?[]const i16 = blk: {
        if (b.module.funcById(func_id)) |f| {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            // Without the candidate's receiver head, bare ext-overload selection
            // inside the block has no evidence and picks the wrong sibling.
            try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
            // A candidate whose parameters do not align with the arguments
            // (a shorter overload than the runtime will pick) shaped nothing;
            // the namesakes hosting the block can still agree on its receiver.
            try lambda_mod.recordTrailingLambdaConsensus(b, name0, args, ast_arg_names, ast_type_args, false);
            break :blk try argFnArities(b, f, args, ast_arg_names, recv_off);
        }
        break :blk null;
    };
    // The deferred form types lambda params from the committed candidate, or a
    // closure's `it` lowers untyped whenever the callee is still a header stub.
    const lambda_param_types: ?[]?[]ir.TypeRef = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and
            std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] stubDeferred fn={s}\n", .{f.name});
        break :blk try argLambdaParamTypes(
            b,
            f,
            args,
            ast_arg_names,
            ast_type_args,
            recv_off,
        );
    };
    defer if (lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = lambda_param_types;
    if (runtime.envOnce("KLIO_ADM_TRACE") != null) {
        const f0 = b.module.funcById(func_id);
        std.debug.print("[cmg-lpt] {s} fid={d} lpt={} p_last={s} p_last_args={d}\n", .{
            name0,
            func_id.int(),
            lambda_param_types != null,
            if (f0) |f| (if (f.params.len != 0) f.params[f.params.len - 1].ty.name else "-") else "?",
            if (f0) |f| (if (f.params.len != 0) f.params[f.params.len - 1].ty.args.len else 0) else 0,
        });
    }
    const run = try lowerArgRunWithArity(b, args, arg_arity);
    const arg_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    const dst = b.allocReg();
    const cmg_static_recv: ?ConstId = try cmgStaticRecv(b);
    var type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    // The deferred form keeps the reified splice substitution too, or a spliced
    // intrinsic lowered in a receiver context is blind at run time.
    if (type_args.len == 0) {
        if (try spliceReifiedTypeArgs(b, func_id, args.len)) |stamped| type_args = stamped;
    }
    if (walk_global) {
        // The same arguments the deferred form would carry, bound to the one
        // declaration the walk proved is the only candidate.
        orEmitAudit(b, "bare_call_walked_global", "Call", name0);
        if (runtime.envOnce("KLIO_WALK_PROBE") != null) {
            const gf = b.module.funcById(func_id);
            std.debug.print("[walk-global-call] name={s} fid={d} fqn={s} hasBody={} nparams={d} nargs={d} type_args={d} trailing={}\n", .{
                name0, func_id.int(), if (gf) |f| f.fqn else "?", if (gf) |f| f.hasBody() else false, if (gf) |f| f.params.len else 0, run[1], type_args.len, b.callTrailingLambda(),
            });
        }
        const ctx_handed = try probe_mod.contextHandoverBegin(b, func_id, ast_type_args);
        try b.push(.{ .Call = .{
            .dst = dst,
            .func = func_id,
            .trailing_lambda = b.callTrailingLambda(),
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .type_args = type_args,
            .exact = was_cast,
        } });
        try probe_mod.contextHandoverEnd(b, ctx_handed);
        return dst;
    }
    orEmitAudit(b, "bare_call_member_shadowable", "CallMemberOrGlobal", name0);
    try b.push(.{ .CallMemberOrGlobal = try b.boxInst(ir.CallMemberOrGlobalInst{
        .dst = dst,
        .this_idx = this_idx,
        .name = nm,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .func = func_id,
        .func_final = was_cast,
        .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
        .static_recv = cmg_static_recv,
        .type_args = type_args,
    }) });
    return dst;
}

/// The class id a bare classifier read binds, innermost first: a nested class of
/// the enclosing chain, under its lifted `Outer$Name` key, beats the
/// package-scope pick.
pub fn scopedClassIdForRead(b: *FuncBuilder, name0: []const u8, file: anytype) Allocator.Error!?ir.ClassId {
    if (nestedClassIdAtLexicalSite(b, name0)) |cid| return cid;
    if (b.module.classIdExactImport(name0, file)) |cid| return cid;
    // A receiver in scope may nest a classifier of the name, which outranks
    // the flat index's pick; the walk says whether one does, and only a
    // receiver it cannot see leaves the read to the name.
    if (inReceiverContext(b)) {
        switch (try implicit_walk.walk(b, name0, null, .classifier, "class_name_scoped")) {
            .member => |hit| return implicit_walk.nestedClassifierOnChain(b, hit.cid, name0, 0),
            .global => {},
            .undecided => return null,
        }
    }
    return b.module.classIdIndexed(name0, b.self_package, file);
}

/// The class visible at a lexical source site, without the receiver-context
/// decline. Anonymous-object bodies use this before moving into their side
/// modules.
pub fn classIdAtLexicalSite(b: *FuncBuilder, name0: []const u8, file: anytype) ?ir.ClassId {
    if (nestedClassIdAtLexicalSite(b, name0)) |cid| return cid;
    if (b.module.classIdExactImport(name0, file)) |cid| return cid;
    return b.module.classIdIndexed(name0, b.self_package, file);
}

pub fn nestedClassIdAtLexicalSite(b: *FuncBuilder, name0: []const u8) ?ir.ClassId {
    if (b.ownerClass()) |oc| {
        // Resolve the owner to an id once, its lifted simple name being in the
        // class index, then answer through the nesting tree.
        if (b.module.classId(oc)) |owner_id| {
            if (b.module.classIdNestedIn(owner_id, name0)) |cid| return cid;
            // `class_children` is built at VM setup, after this lowering runs for
            // a baked pack's bodies, so derive the nesting from FQNs instead,
            // walking up the enclosing-class FQNs.
            if (b.module.classFqnById(owner_id)) |ofqn| {
                var pfqn: []const u8 = ofqn;
                var hops: usize = 0;
                while (hops < 16) : (hops += 1) {
                    const cand = std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ pfqn, name0 }) catch break;
                    defer b.allocator.free(cand);
                    if (b.module.classIdByFqn(cand)) |cid| return cid;
                    const dot = std.mem.findScalarLast(u8, pfqn, '.') orelse break;
                    pfqn = pfqn[0..dot];
                    if (b.module.classIdByFqn(pfqn) == null) break; // left the class nest
                }
            }
        }
    }
    return null;
}

/// The innermost implicit receiver with an applicable member of this name,
/// as a register, or null when no receiver can be proven to hold one.
///
/// Kotlin ranks implicit receivers innermost-first and takes the first with an
/// APPLICABLE member, which is the ranking `EnclosingPush` exists to let the
/// runtime perform. `subject_binds` is the same stack, kept by lowering with
/// each subject's head beside its register, so the ranking can be done here.
///
/// Applicability without argument types comes from the arity key: a class
/// whose (simple name, name, arity) names exactly one declaration has nothing
/// to pick between. A same-named extension that could serve the receiver
/// withdraws the answer, because a member wins only by being applicable.
pub fn implicitReceiverDeclaring(
    b: *FuncBuilder,
    name: []const u8,
    arity: usize,
) Allocator.Error!?struct { reg: Reg, fid: ir.FuncId } {
    const sbs = b.subject_binds.items;
    var i = sbs.len;
    while (i > 0) {
        i -= 1;
        const h = sbs[i].head orelse return null;
        if (declaredSlotOn(b, h, name, arity)) |fid| return .{ .reg = sbs[i].reg, .fid = fid };
    }
    const own = b.recvTy() orelse b.enclosingRecvTy() orelse b.ownerClass() orelse return null;
    const fid = declaredSlotOn(b, own, name, arity) orelse return null;
    // Beneath the subjects. Inside a splice `this` IS the innermost subject,
    // which the walk just ruled out, so the declaration's own receiver is the
    // one bound before any subject did: `with(sb) { eachPlain { } }` names
    // the enclosing class's method on the enclosing instance, not on `sb`.
    if (sbs.len != 0) {
        if (sbs[0].prior_this) |prior| return .{ .reg = prior, .fid = fid };
        return null;
    }
    // An extension splice binds `this` to the spliced receiver without a
    // subject bind, so with one active the ambient `this` is not the
    // declaration's own receiver and nothing here records what is:
    // `takeSnapshot().run { clearWatchSet(c) }` names the enclosing class's
    // method, and `this` there is the snapshot.
    if (b.spliceRecvTy() != null) return null;
    if (b.resolve("this")) |this_reg| return .{ .reg = this_reg, .fid = fid };
    if (b.capturesThisSlot()) return .{ .reg = try b.loadCaptureHoisted("this"), .fid = fid };
    return null;
}

/// The sole declaration of `name` at `arity` on `head`, or null.
///
/// The registry keys a member declaration by the owner's SIMPLE name, so a
/// key answers for every class of that name and two in different packages
/// collide without either overwriting the other. The declaration found must
/// therefore be checked to belong to this head's class or one of its
/// ancestors; skipping that bound `clearWatchSet` on a `ReadonlySnapshot`
/// whose chain never declared it.
pub fn declaredSlotOn(b: *FuncBuilder, head_in: []const u8, name: []const u8, arity: usize) ?ir.FuncId {
    const fid = declaredSlotOnNoExt(b, head_in, name, arity) orelse return null;
    if (b.module.extensionCouldServe(classIdOfHead(b, head_in), name)) return null;
    return fid;
}

pub fn classIdOfHead(b: *FuncBuilder, head_in: []const u8) ?ir.ClassId {
    var head = std.mem.trimEnd(u8, head_in, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0) return null;
    const simple = if (std.mem.findScalarLast(u8, head, '.')) |i| head[i + 1 ..] else head;
    return b.module.classIdByFqn(head) orelse b.module.uniqueClassIdBySimpleName(simple);
}

/// As `declaredSlotOn`, without the extension question. A `super.f()` names a
/// member by the language rule; no extension can take it.
pub fn declaredSlotOnNoExt(b: *FuncBuilder, head_in: []const u8, name: []const u8, arity: usize) ?ir.FuncId {
    var head = std.mem.trimEnd(u8, head_in, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0) return null;
    const simple = if (std.mem.findScalarLast(u8, head, '.')) |i| head[i + 1 ..] else head;
    const cid = b.module.classIdByFqn(head) orelse b.module.uniqueClassIdBySimpleName(simple) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    // The table is keyed by `Class.name`, which is NOT the FQN's last
    // segment: two classes sharing a simple name are collision-mangled, and
    // compose ships two `changelist.Operation`s registered as
    // `Operation$f206` and `Operation$f222`. Keying on the tail looked up a
    // name no writer ever used.
    const keyed = b.module.classes.items[cid.int()].name;
    if (keyed.len == 0) return null;
    var kb: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{s}\x00{s}\x00{d}", .{ keyed, name, arity }) catch return null;
    if (b.module.registry.member_method_ambiguous.contains(key)) return null;
    const fid = b.module.registry.member_method_fids.get(key) orelse return null;
    const owner = (b.module.decl_sigs.get(fid.int()) orelse return null).enclosing_class orelse return null;
    if (owner.int() != cid.int() and !(b.module.classIsAKnown(cid, owner) orelse false)) return null;
    return fid;
}

/// The declaration `super.name(...)` names, given the class the super
/// reference resolves against and whether it was qualified.
///
/// A super call is not virtual: the language fixes the target, so it binds a
/// direct `Call`. An unqualified `super` names the SUPERCLASS of the
/// enclosing class; a qualified one names the supertype it spells, which
/// `superBase` has already resolved into the owner it returns. The
/// declaration must carry a body, since `super` to an abstract member is not
/// a call Kotlin allows.
/// The supertype a `super` reference names. Qualified, it is the one spelled,
/// which `superBase` already resolved into the owner it returned. Unqualified
/// it is the superclass, and with several supertypes Kotlin allows the plain
/// form only when ONE of them declares the member — so the sole declarer is
/// the answer and anything else declines.
pub const SuperMemberKind = enum { method, property };

pub fn superTypeFor(
    b: *FuncBuilder,
    owner_head: []const u8,
    qualifier: ?[]const u8,
    name: []const u8,
    arity: usize,
    kind: SuperMemberKind,
) ?ir.ClassId {
    // `super<K>` names the supertype outright. `super@Outer` does NOT: the
    // label picks which enclosing INSTANCE the call runs against, and
    // `superBase` has already resolved it into the class whose SUPERTYPES
    // the reference means. Treating a label as a qualifier bound
    // `super@A.foo()` to `A.foo` itself, which called the override instead
    // of the base.
    var cbuf: [16]ir.ClassId = undefined;
    const sups = superCandidates(b, owner_head, qualifier, &cbuf) orelse return null;
    if (sups.len == 0) return null;
    // One supertype is the answer on its own. Asking whether it declares the
    // member is the NEXT question, and answering it here made a lookup that
    // cannot see the declaration withdraw the supertype too.
    if (sups.len == 1) return sups[0];
    var buf: [256]u8 = undefined;
    var picked: ?ir.ClassId = null;
    for (sups) |sid| {
        if (sid.int() >= b.module.classes.items.len) return null;
        const declares = switch (kind) {
            .method => nearestDeclOnChain(b, sid, name, arity) != null or chainDeclaresMethod(b, sid, name),
            .property => b.module.declaredGetterOn(sid, name, &buf) != null,
        };
        if (!declares) continue;
        if (picked != null) return null;
        picked = sid;
    }
    return picked;
}

/// The classes an unqualified `super` in a member of `owner_head` means: the
/// owner's supertypes when the owner is in the class table, else the heads
/// its declaration listed, which is what a function-local class has, being
/// registered at run time and lowered then. Null when the owner is not known
/// at all, which is different from a class with no supertypes.
pub fn ownerSupertypeIds(b: *FuncBuilder, owner_head: []const u8, buf: *[16]ir.ClassId) ?[]const ir.ClassId {
    if (classIdOfHead(b, owner_head)) |cid| {
        if (cid.int() >= b.module.classes.items.len) return null;
        return b.module.classes.items[cid.int()].supertypes;
    }
    const oc = b.ownerClass() orelse return null;
    if (!std.mem.eql(u8, oc, owner_head)) return null;
    const heads = build.ownerSuperHeads();
    if (heads.len == 0) return null;
    var n: usize = 0;
    for (heads) |h| {
        if (n == buf.len) break;
        if (classIdOfHead(b, h)) |sid| {
            buf[n] = sid;
            n += 1;
        }
    }
    return buf[0..n];
}

/// The classes a `super` reference searches: the one it names, or the
/// owner's supertypes.
pub fn superCandidates(b: *FuncBuilder, owner_head: []const u8, qualifier: ?[]const u8, buf: *[16]ir.ClassId) ?[]const ir.ClassId {
    if (qualifier) |q| {
        buf[0] = classIdOfHead(b, q) orelse return null;
        return buf[0..1];
    }
    return ownerSupertypeIds(b, owner_head, buf);
}

/// Whether `fid` names something a direct call can enter.
///
/// Carrying the body itself is not required: the member table hands back the
/// reserved header and link redirects a bodyless header onto the sibling
/// that has one. What must be refused is a declaration with no body
/// ANYWHERE, because link settles that onto a native instead, and a
/// collection native dispatches on the receiver's own class —
/// `super<ArrayList>.add` reached `AbstractMutableList.add`, re-entered the
/// subclass override, and recursed until the stack gave out.
fn executableDecl(b: *FuncBuilder, fid: ir.FuncId) bool {
    const f = b.module.funcById(fid) orelse return false;
    if (f.hasBody()) return true;
    const sig = b.module.decl_sigs.get(fid.int()) orelse return false;
    return sig.has_body;
}

/// The `Any` member `super.name(...)` bottoms out in, when no supertype
/// declares the name at all.
///
/// A class whose chain declares nothing called `toString` inherits `Any`'s,
/// and the language fixes that: the runtime walk was discovering it by
/// exhausting the supertype list on every execution. The chain walk alone
/// decides. The hierarchy shadow set cannot answer this question for these
/// three names: every class nominally declares `toString` because `Any`
/// does, so consulting it declines every site. What matters is whether a
/// supertype has its OWN declaration, which is what the walk looks for.
pub fn superAnyMember(
    b: *FuncBuilder,
    owner_head: []const u8,
    qualifier: ?[]const u8,
    name: []const u8,
    arity: usize,
) core_inst.BuiltinMember {
    if (qualifier != null) return .none;
    const which: core_inst.BuiltinMember = if (arity == 0 and std.mem.eql(u8, name, "toString"))
        .any_to_string
    else if (arity == 0 and std.mem.eql(u8, name, "hashCode"))
        .any_hash_code
    else if (arity == 1 and std.mem.eql(u8, name, "equals"))
        .any_equals
    else
        return .none;
    var cbuf: [16]ir.ClassId = undefined;
    const sups = ownerSupertypeIds(b, owner_head, &cbuf) orelse return .none;
    for (sups) |sid| {
        if (sid.int() >= b.module.classes.items.len) return .none;
        if (nearestDeclOnChain(b, sid, name, arity) != null) return .none;
        if (chainDeclaresMethod(b, sid, name)) return .none;
    }
    return which;
}

/// Whether some class on the chain from `cid` IMPLEMENTS a member called
/// `name`, at any arity. Level order over class and interfaces alike. What
/// picking the supertype an unqualified `super` means asks, and what the
/// `Any` default has to rule out: an overload set the (name, arity) key calls
/// ambiguous still declares the member. An abstract declaration does not
/// count, since `super` cannot reach it and an interface restating a method
/// its sibling class implements is not a second answer.
fn chainDeclaresMethod(b: *FuncBuilder, cid: ir.ClassId, name: []const u8) bool {
    var level: [32]ir.ClassId = undefined;
    var next: [32]ir.ClassId = undefined;
    var n: usize = 1;
    level[0] = cid;
    var depth: usize = 0;
    while (depth < 16 and n != 0) : (depth += 1) {
        var n_next: usize = 0;
        for (level[0..n]) |c_id| {
            if (c_id.int() >= b.module.classes.items.len) continue;
            const c = &b.module.classes.items[c_id.int()];
            for (b.module.memberDecls(c.fqn, name)) |fid| {
                if (executableDecl(b, fid)) return true;
            }
            for (c.supertypes) |sup| {
                if (n_next == next.len) return false;
                next[n_next] = sup;
                n_next += 1;
            }
        }
        for (next[0..n_next], 0..) |v, i| level[i] = v;
        n = n_next;
    }
    return false;
}

/// Among the overloads of `name` on the chain from `cid`, the one the call's
/// static argument types select. The nearest level declaring an applicable
/// candidate answers, and within it the best score wins when it is unique.
/// This is what `nearestDeclOnChain` cannot do: two same-arity overloads make
/// its (name, arity) key ambiguous by construction, and `placeAt(position,
/// zIndex, layerBlock)` beside `placeAt(position, zIndex, layer)` is exactly
/// the shape a super call in a layout node has.
fn superOverloadOnChain(
    b: *FuncBuilder,
    cid: ir.ClassId,
    name: []const u8,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?ir.FuncId {
    var shape_set = try type_probe.buildStaticReturnArgShapes(b, args, ast_arg_names);
    defer shape_set.deinit(b.allocator);
    const named = !allNull(ast_arg_names);
    // The member resolver's own conventions: the declaration's parameters
    // with `this` in front, skipped by the scorer.
    const scope = applicability.ApplicabilityScope{ .member = true, .named = named, .recv_external = named };
    var level: [32]ir.ClassId = undefined;
    var next: [32]ir.ClassId = undefined;
    var n: usize = 1;
    level[0] = cid;
    var depth: usize = 0;
    while (depth < 16 and n != 0) : (depth += 1) {
        var best: ?ir.FuncId = null;
        var best_points: i32 = std.math.minInt(i32);
        var tie = false;
        var n_next: usize = 0;
        for (level[0..n]) |c_id| {
            if (c_id.int() >= b.module.classes.items.len) continue;
            const c = &b.module.classes.items[c_id.int()];
            for (b.module.memberDecls(c.fqn, name)) |fid| {
                if (!executableDecl(b, fid)) continue;
                const f = b.module.funcById(fid) orelse continue;
                // A header whose value parameters are not listed yet cannot
                // be scored, and a wrong score here binds the wrong body.
                if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
                const sig = applicability.SigView{
                    .params = f.params,
                    .has_body = true,
                    .is_member = true,
                    .fid = fid,
                    .package = f.package,
                };
                const score = applicability.applicable(&sig, shape_set.shapes, scope) orelse continue;
                if (best == null or score.points > best_points) {
                    best = fid;
                    best_points = score.points;
                    tie = false;
                } else if (score.points == best_points and best.?.int() != fid.int()) {
                    tie = true;
                }
            }
            for (c.supertypes) |sup| {
                if (n_next == next.len) return null;
                next[n_next] = sup;
                n_next += 1;
            }
        }
        if (best) |fid| return if (tie) null else fid;
        for (next[0..n_next], 0..) |v, i| level[i] = v;
        n = n_next;
    }
    return null;
}

/// The declaration `super.name(args)` calls: the nearest implementation on
/// the chain of the supertype the reference means, selected by the call's
/// static argument types where the arity alone leaves several.
pub fn superTargetSlot(
    b: *FuncBuilder,
    owner_head: []const u8,
    qualifier: ?[]const u8,
    name: []const u8,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?ir.FuncId {
    const why = runtime.envOnce("KLIO_SUPER_WHY") != null;
    const arity = args.len;
    const scid = superTypeFor(b, owner_head, qualifier, name, arity, .method) orelse {
        if (why) {
            const c0 = classIdOfHead(b, owner_head);
            const n0: usize = if (c0) |cc| (if (cc.int() < b.module.classes.items.len) b.module.classes.items[cc.int()].supertypes.len else 0) else 999;
            std.debug.print("[super-step] {s}.{s}/{d}: no supertype pick sups={d}\n", .{ owner_head, name, arity, n0 });
        }
        return null;
    };
    if (nearestDeclOnChain(b, scid, name, arity)) |fid| return fid;
    if (try superOverloadOnChain(b, scid, name, args, ast_arg_names)) |fid| return fid;
    if (why) std.debug.print("[super-step] {s}.{s}/{d}: no decl on chain from {s}\n", .{ owner_head, name, arity, b.module.classes.items[scid.int()].fqn });
    return null;
}

/// The class a `super` reference resolves against: the supertype it names,
/// or the class whose supertypes an unqualified one means.
pub fn superStartClass(b: *FuncBuilder, owner_head: []const u8, qualifier: ?[]const u8) ?ir.ClassId {
    return classIdOfHead(b, qualifier orelse owner_head);
}

/// What `super.<prop>` (or `super.<prop> = v`) reaches, as far as this body
/// can see: the accessor the nearest declaring class on the supertype's
/// chain has, when its function exists, or the cell that class stores the
/// property in, when its layout is composed. Null leaves the access to the
/// link pass, which asks the same question once every body has lowered.
pub fn superPropertyAnswer(b: *FuncBuilder, owner_head: []const u8, qualifier: ?[]const u8, name: []const u8, access: ir.SuperAccess) ?ir.SuperAnswer {
    var cbuf: [16]ir.ClassId = undefined;
    const cands = superCandidates(b, owner_head, qualifier, &cbuf) orelse return null;
    if (cands.len == 0) return null;
    var buf: [256]u8 = undefined;
    return b.module.superMemberAmong(cands, name, access, &buf);
}

/// `super.Inner(args)`: the classifier `Inner` nested in a class on the
/// chain of the supertype the reference means. The call constructs it on
/// this receiver, which is what the bare `Inner(args)` in the same body does.
pub fn superNestedClass(b: *FuncBuilder, owner_head: []const u8, qualifier: ?[]const u8, name: []const u8) ?ir.ClassId {
    var cbuf: [16]ir.ClassId = undefined;
    const cands = superCandidates(b, owner_head, qualifier, &cbuf) orelse return null;
    for (cands) |sid| {
        if (nestedClassOnChain(b, sid, name)) |c| return c;
    }
    return null;
}

fn nestedClassOnChain(b: *FuncBuilder, cid: ir.ClassId, name: []const u8) ?ir.ClassId {
    var cur = cid;
    var hops: usize = 0;
    while (hops < 32) : (hops += 1) {
        if (cur.int() >= b.module.classes.items.len) return null;
        const c = &b.module.classes.items[cur.int()];
        var buf: [512]u8 = undefined;
        const fqn = std.fmt.bufPrint(&buf, "{s}.{s}", .{ c.fqn, name }) catch return null;
        if (b.module.classIdByFqn(fqn)) |nested| return nested;
        if (c.supertypes.len == 0) return null;
        cur = c.supertypes[0];
    }
    return null;
}

/// The host-backed class a `super` reference reaches, when the supertype it
/// means is one: the instance holds that base as its `__delegate__<Name>`
/// cell, and a super member runs on the delegate rather than on a body.
pub fn superHostBackedBase(b: *FuncBuilder, owner_head: []const u8, qualifier: ?[]const u8) ?*const ir.Class {
    var cbuf: [16]ir.ClassId = undefined;
    const cands = superCandidates(b, owner_head, qualifier, &cbuf) orelse return null;
    for (cands) |sid| {
        if (hostBackedClass(b, sid)) |c| return c;
    }
    return null;
}

fn hostBackedClass(b: *FuncBuilder, cid: ir.ClassId) ?*const ir.Class {
    if (cid.int() >= b.module.classes.items.len) return null;
    const c = &b.module.classes.items[cid.int()];
    return if (c.is_intrinsic_backed) c else null;
}

/// The nearest IMPLEMENTATION of `name` at `arity` from `cid` upward, which
/// is what `super` reaches: `AbstractMutableList` does not declare `iterator`
/// itself, it inherits it.
///
/// The member table answers, and what it holds is a signature index whose
/// first writer wins — the reserved HEADER, not the body. That is fine for a
/// direct call: link settles a bodyless header onto its same-owner body
/// sibling. `Class.methods` would hold the body directly but it is filled at
/// the END of lowering that class and bodies lower from a pool, so reading
/// it from inside another body is order-dependent.
fn nearestDeclOnChain(b: *FuncBuilder, cid: ir.ClassId, name: []const u8, arity: usize) ?ir.FuncId {
    // Level order over every supertype, not the first one only: an interface
    // sibling can hold the implementation, and following the superclass link
    // alone walked straight past it. Nearest wins, and a level offering two
    // different answers decides nothing.
    var level: [32]ir.ClassId = undefined;
    var next: [32]ir.ClassId = undefined;
    var n: usize = 1;
    level[0] = cid;
    var depth: usize = 0;
    while (depth < 16 and n != 0) : (depth += 1) {
        var found: ?ir.FuncId = null;
        var n_next: usize = 0;
        for (level[0..n]) |c_id| {
            if (c_id.int() >= b.module.classes.items.len) continue;
            const c = &b.module.classes.items[c_id.int()];
            // The key existing is not the same as the class holding the
            // implementation `super` reaches: an abstract override hid the
            // body above it, so anything unenterable keeps the walk going.
            if (declaredSlotOnNoExt(b, c.fqn, name, arity)) |fid| {
                if (executableDecl(b, fid)) {
                    if (found) |prev| {
                        if (prev.int() != fid.int()) return null;
                    } else found = fid;
                }
            }
            for (c.supertypes) |sup| {
                if (n_next == next.len) return null;
                next[n_next] = sup;
                n_next += 1;
            }
        }
        if (found) |fid| return fid;
        for (next[0..n_next], 0..) |v, i| level[i] = v;
        n = n_next;
    }
    return null;
}

/// Whether the bound `this` is the tower's innermost pushed subject, already on
/// the runtime chain, rather than a nested inline-extension splice receiver,
/// which is not and must stay pinned.
fn boundThisIsTowerTop(b: *FuncBuilder) bool {
    if (b.encl_tower_depth == 0) return false;
    const top = b.encl_tower_top orelse return false;
    const cur = b.resolve("this") orelse return false;
    return cur.int() == top.int();
}

pub fn cmgStaticRecv(b: *FuncBuilder) Allocator.Error!?ConstId {
    // Under an active subject tower the runtime chain ranks the receivers; a
    // static head would raise where the walk must fall outward.
    if (boundThisIsTowerTop(b)) return null;
    const rt = bareStaticRecvHead(b) orelse return null;
    return try b.module.internConst(b.allocator, .{ .String = rt });
}

/// The static-receiver head a bare call's dispatch hint carries: inside an active
/// splice the spliced fn's own receiver, since inline bodies are hygienic and a
/// bare call in a stdlib body must not resolve against the site's class.
/// Outside a splice, the enclosing function's receiver.
pub fn bareStaticRecvHead(b: *const FuncBuilder) ?[]const u8 {
    if (b.thisNarrow()) |t| return t;
    if (b.spliceHintActive()) return b.spliceHintRecv();
    // An `is`-narrow of `this` is the innermost receiver truth, exactly as kotlinc
    // smart-casts. It lives in the local-decl map under "this", consulted after
    // the splice hint so a spliced body never resolves against the caller
    // context. `KLIO_THIS_NARROW=0` disables.
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_THIS_NARROW") orelse "1", "0")) {
        // Only a genuine narrow counts: a lambda with no receiver of its own sees
        // the enclosing method's `this` decl through the shared local map, and
        // trusting that binds bare calls to the wrong receiver.
        if (b.recvTy()) |declared| {
            if (b.localDeclType("this")) |narrowed| {
                if (!std.mem.eql(u8, typeHead(narrowed), typeHead(declared)))
                    return typeHead(narrowed);
            }
        }
    }
    if (b.recvTy()) |own| return own;
    // A lambda declared receiverless chains to the enclosing receiver, exactly
    // Kotlin's implicit-receiver resolution; an untyped receiver-lambda must not.
    if (b.own_recv_known_none) return b.enclosingRecvTy();
    return null;
}

/// Package- and import-scoped declarations carried by a deferred bare call. Null
/// means no rankable metadata; a non-null, possibly empty slice is authoritative
/// and keeps the runtime from widening to the program-wide simple-name index.
pub fn cmgCandidates(b: *FuncBuilder, name: []const u8, file: ir.FileId, user_arg_count: usize) Allocator.Error!?[]const FuncId {
    return b.module.boundedCallCandidates(b.allocator, name, b.self_package, file, user_arg_count);
}

/// The `CallValue` emit form for a bare name with no committed target: load the
/// global by name and invoke it, for a host-intrinsic alias.
pub fn emitValueCall(
    b: *FuncBuilder,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    name0: []const u8,
) Allocator.Error!Reg {
    orEmitAudit(b, "alias_global_no_overload", "LoadGlobal", name0);
    const callee_r = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm } });
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    const dst = b.allocReg();
    try b.push(.{ .CallValue = .{
        .dst = dst,
        .callee = callee_r,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
    } });
    return dst;
}

pub fn emitObjectValueCall(
    b: *FuncBuilder,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    name0: []const u8,
    class_id: ir.ClassId,
) Allocator.Error!Reg {
    orEmitAudit(b, "object_operator_call", "LoadGlobal", name0);
    const callee_r = b.allocReg();
    const identity = b.module.classFqnById(class_id) orelse name0;
    const nm = try b.module.internConst(b.allocator, .{ .String = identity });
    try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm, .class = class_id } });
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    const dst = b.allocReg();
    try b.push(.{ .CallValue = .{
        .dst = dst,
        .callee = callee_r,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
    } });
    return dst;
}

/// Arg names for a bare `Call`, synthesizing a name for a trailing lambda after a
/// vararg parameter so it binds the last, function-typed parameter.
pub fn trailingLambdaArgNames(
    b: *FuncBuilder,
    func_id: FuncId,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error![]?ConstId {
    if (b.module.funcById(func_id)) |f| {
        if (threadedTrailingLambdaParam(f, args, ast_arg_names)) |hit| {
            const tagged = try internArgNames(b.allocator, b.module, ast_arg_names);
            tagged[hit.arg_index] = try b.module.internConst(b.allocator, .{ .String = hit.param_name });
            return tagged;
        }
    }
    if (args.len != 0 and allNull(ast_arg_names) and lastArgIsLambda(args)) {
        if (b.module.funcById(func_id)) |f| {
            const last_is_fixed_fn = f.params.len != 0 and
                !f.params[f.params.len - 1].is_vararg and
                std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function");
            var has_earlier_vararg = false;
            if (f.params.len > 1) {
                for (f.params[0 .. f.params.len - 1]) |p| {
                    if (p.is_vararg) has_earlier_vararg = true;
                }
            }
            // Only the vararg-before-trailing-lambda shape needs it; a plain
            // positional trailing lambda already lands on the last parameter, and
            // a final vararg of function values absorbs every lambda.
            if (last_is_fixed_fn and has_earlier_vararg) {
                const tagged = try b.allocator.alloc(?ConstId, args.len);
                for (tagged) |*t| t.* = null;
                const cid = try b.module.internConst(b.allocator, .{ .String = f.params[f.params.len - 1].name });
                tagged[tagged.len - 1] = cid;
                return tagged;
            }
        }
    }
    return internArgNames(b.allocator, b.module, ast_arg_names);
}

const ThreadedTrailingLambda = struct {
    arg_index: usize,
    param_name: []const u8,
};

/// The source trailing lambda before the Compose synthetic pair binds the selected
/// declaration's last user parameter. The AST pass clears `has_trailing_lambda`,
/// so carrying the name into IR preserves Kotlin's across-default binding.
pub fn threadedTrailingLambdaParam(
    f: *const Func,
    args: []const Expr,
    names: []const ?[]const u8,
) ?ThreadedTrailingLambda {
    if (!hasThreadedComposerParams(f) or args.len < 3 or names.len != args.len) return null;
    const composer_name = names[names.len - 2] orelse return null;
    const changed_name = names[names.len - 1] orelse return null;
    if (!std.mem.eql(u8, composer_name, "$composer") or
        !std.mem.eql(u8, changed_name, "$changed"))
    {
        return null;
    }
    const arg_index = args.len - 3;
    if (args[arg_index] != .Lambda or names[arg_index] != null) return null;
    const user_param_end = f.params.len - 2;
    if (user_param_end == 0) return null;
    const param = &f.params[user_param_end - 1];
    if (param.is_vararg or !std.mem.startsWith(u8, param.ty.name, "Function")) return null;
    return .{ .arg_index = arg_index, .param_name = param.name };
}

/// The extension-fn bare-call path: prepend `this`, with trailing-lambda arg-name
/// synthesis and the member-precedence routing.
fn emitExtBareCall(b: *FuncBuilder, expr: *const Expr, func_id_in: FuncId, this_reg: Reg, was_cast_in: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    // A bare extension call can reach here with a heuristic sibling committed, and
    // the CallMember below would hand the walk a first-declared re-pick, so the
    // trailing lambda's derived return discriminates a return-variant family.
    var func_id = func_id_in;
    var was_cast = was_cast_in;
    if (!was_cast and lastArgIsLambda(call.args) and allNull(call.arg_names) and
        callee.* == .Path and callee.Path.segments.len == 1)
    {
        const pcands = try b.module.bareCallCandidates(b.allocator, callee.Path.segments[0].name, callee.Path.segments[0].span.file);
        defer b.allocator.free(pcands);
        if (try overloadPickByLambdaReturn(b, pcands, call.args, call.args.len)) |picked| {
            func_id = picked;
            was_cast = true;
        }
    }
    var selected_args = try selectedCallArgsForBuilder(b, func_id, call.args, call.arg_names, exprSpan(callee), call.has_trailing_lambda);
    defer selected_args.deinit(b.allocator);
    const args = selected_args.args;
    const ast_arg_names = selected_args.names;
    const ast_type_args = call.type_args;
    const prev_trailing = b.setCallTrailingLambda(
        call.has_trailing_lambda and !hasComposerArgPair(ast_arg_names),
    );
    defer _ = b.setCallTrailingLambda(prev_trailing);

    // Synthesise a Path("this") arg expr then lower the run.
    const sp = exprSpan(callee);
    const all = try b.allocator.alloc(Expr, args.len + 1);
    defer b.allocator.free(all);
    const synth_segs = try b.allocator.alloc(ast.Ident, 1);
    defer b.allocator.free(synth_segs);
    synth_segs[0] = .{ .name = "this", .span = sp };
    all[0] = .{ .Path = .{ .segments = synth_segs, .span = sp } };
    for (args, 0..) |a, i| all[i + 1] = a;
    const arg_arity: ?[]const i16 = blk: {
        if (allNull(ast_arg_names)) {
            // The trailing lambda lands on whichever same-name overload declares a
            // function-typed last parameter of the call's user arity.
            const arity_fid: ?FuncId = if (lastArgIsLambda(args))
                (overloadHostingTrailingLambda(b, callee.Path.segments[0].name, args.len) orelse func_id)
            else
                func_id;
            if (arity_fid) |fid| {
                if (b.module.funcById(fid)) |f| {
                    // `all` leads with the synthesized `this`, aligned with the
                    // function's own leading `this` parameter, so no offset.
                    break :blk try argFnArities(b, f, all, &.{}, 0);
                }
            }
        }
        break :blk null;
    };

    // Target params for trailing-lambda arg-name synthesis.
    var target_params: [][]const u8 = &.{};
    if (b.module.funcById(func_id)) |f| {
        target_params = try b.allocator.alloc([]const u8, f.params.len);
        for (f.params, target_params) |p, *tp| tp.* = p.name;
    }
    defer if (target_params.len != 0) b.allocator.free(target_params);
    const user_arg_count = all.len - 1;
    const trailing_lambda_call = lastArgIsLambda(args);
    const synth_names_needed = target_params.len != 0 and user_arg_count >= 1 and
        (1 + user_arg_count) < target_params.len and allNull(ast_arg_names) and trailing_lambda_call;

    var arg_names: []?ConstId = undefined;
    if (synth_names_needed) {
        const tagged = try b.allocator.alloc(?ConstId, all.len);
        for (tagged) |*t| t.* = null;
        const p_name = target_params[target_params.len - 1];
        const cid = try b.module.internConst(b.allocator, .{ .String = p_name });
        tagged[tagged.len - 1] = cid;
        arg_names = tagged;
    } else {
        arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    }
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);

    if (!synth_names_needed and !was_cast) {
        // Member-of-receiver precedence: route through call_member on `this`,
        // carrying the hosting overload's lambda arity so a `T.() -> R` handler
        // drops its synthetic `it` here too.
        const uarg_arity: ?[]const i16 = ablk: {
            if (allNull(ast_arg_names) and lastArgIsLambda(args)) {
                if (overloadHostingTrailingLambda(b, callee.Path.segments[0].name, args.len)) |fid| {
                    if (b.module.funcById(fid)) |f| {
                        break :ablk try argFnArities(b, f, args, &.{}, 1);
                    }
                }
            }
            break :ablk null;
        };
        const uargs = try lowerArgRunWithArity(b, args, uarg_arity);
        const uarg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nmc = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
        const dst = b.allocReg();
        // A captured-`this` receiver context routes through `emitMemberOrGlobal`.
        // Inside an extension body the implicit `this` has the declared receiver
        // type, so record it and resolve extensions statically, as kotlinc does.
        const static_recv: ?ConstId = if (bareStaticRecvHead(b)) |rt|
            try b.module.internConst(b.allocator, .{ .String = rt })
        else
            null;
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = this_reg,
            .name = nmc,
            .args = uargs[0],
            .n_args = uargs[1],
            .extra = try b.memberExtra(.{ .trailing_lambda = b.callTrailingLambda(), .arg_names = uarg_names, .static_recv = static_recv }),
        } });
        return dst;
    }
    // Only the static-call path reaches here, so the `this`-prepended run lowers
    // now; lowering it earlier would execute every argument's side effects a
    // second time on the member path.
    const run = try lowerArgRunWithArity(b, all, arg_arity);
    const dst = b.allocReg();
    const ctx_handed = try probe_mod.contextHandoverBegin(b, func_id, ast_type_args);
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = was_cast,
    } });
    try probe_mod.contextHandoverEnd(b, ctx_handed);
    return dst;
}

/// Emit a dotted `pkg.Outer.Inner.member…` reference by binding the longest
/// class-naming prefix to its exact id and reading each remaining segment as a
/// field, so a same-simple-name class elsewhere cannot swap in at runtime.
pub fn emitFqnWithClassPrefix(b: *FuncBuilder, fqn: []const u8) Allocator.Error!?Reg {
    var end = fqn.len;
    while (true) {
        if (b.module.classIdByFqn(fqn[0..end])) |cid| {
            // Ride the exact id only when the prefix's simple name is genuinely
            // ambiguous. Where it resolves to this very class the name-keyed load
            // is preferable, since an id load returns a class's companion or
            // misses a same-named factory function.
            const prefix = fqn[0..end];
            const simple = if (std.mem.findScalarLast(u8, prefix, '.')) |d| prefix[d + 1 ..] else prefix;
            const simple_cid = b.module.classId(simple);
            if (simple_cid != null and simple_cid.?.int() == cid.int()) return null;
            // The id table resolves an `object` prefix to its singleton; a class
            // prefix loads its class value, off which the remaining segments read.
            var cur = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = fqn[0..end] });
            try b.push(.{ .LoadGlobal = .{ .dst = cur, .name = n, .class = cid } });
            var rest = fqn[end..];
            // Only the FIRST hop reads off the class the prefix names; past
            // that the receiver is whatever the previous hop produced.
            var hop_cls: ?ir.ClassId = cid;
            while (rest.len > 0) {
                rest = rest[1..]; // skip '.'
                const dot = std.mem.findScalar(u8, rest, '.') orelse rest.len;
                const next = b.allocReg();
                const field = try b.module.internConst(b.allocator, .{ .String = rest[0..dot] });
                try b.push(.{ .GetField = .{
                    .dst = next,
                    .receiver = cur,
                    .field = field,
                    .own_cls = hop_cls,
                } });
                hop_cls = null;
                cur = next;
                rest = rest[dot..];
            }
            return cur;
        }
        const dot = std.mem.findScalarLast(u8, fqn[0..end], '.') orelse break;
        end = dot;
    }
    return null;
}
