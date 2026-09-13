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
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const bare_call_mod = @import("bare_call.zig");
const allNull = bare_call_mod.allNull;
const lowerImplicitThisCall = bare_call_mod.lowerImplicitThisCall;
const lowerUnresolvedBareCall = bare_call_mod.lowerUnresolvedBareCall;

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

/// The argument expressions a tailrec self-call re-binds the parameters
/// from: the receiver first when the function carries an implicit `this`,
/// the written arguments placed by name where the call names them, then
/// the defaults of the parameters the call omits (Kotlin evaluates them in
/// parameter order after the given arguments). Null when an omitted
/// parameter has no default here (an override inheriting one): that call
/// stays a call. Caller frees.
/// Lower a tail jump's arguments in Kotlin's evaluation order — the written
/// arguments as written, then the omitted parameters' defaults in parameter
/// order — and lay the values out by parameter slot for `TailJump`. Null
/// when the call cannot become a jump.
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
        // More arguments than declared parameters (a vararg): keep them as
        // written.
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

/// The `Call` emit form: a resolved bare-name static call. A committed
/// non-extension target lowers to a direct `Call` (or a `TailCallFunc` in a
/// tailrec body); an extension target routes through `emitExtBareCall`, which
/// prepends `this`. `resolveCall` has already decided this is a static call, so
/// the member-vs-global walk lives in `emitMemberOrGlobal`, not here.
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
    // parameter types are authoritative even when the source callee is an
    // alias with no same-named entry in the function index.
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
        // No `this` in scope — fall through to the unmodified Call below.
    }

    const callee_is_tailrec = blk: {
        if (b.module.funcById(func_id)) |f| {
            if (f.is_tailrec) break :blk true;
        }
        break :blk false;
    };
    // Only a call in tail position is a tail call: `return 1 + f(x - 1)`
    // recurses and adds.
    if (b.tail_call_ok and b.tailrecSelf() != null and callee_is_tailrec and allNull(ast_arg_names)) {
        const run = try lowerArgRun(b, args);
        b.terminate(.{ .TailCallFunc = .{ .func = func_id, .args = run[0], .n_args = run[1] } });
        const dead = try b.allocBlock();
        b.switchTo(dead);
        return b.emitConst(.Unit);
    }
    // A bare call a runtime implicit receiver could shadow is routed by
    // `resolveCall` to the `CallMemberOrGlobal` emit form (`emitMemberOrGlobal`),
    // never here: reaching `emitCall` means the resolver already committed to the
    // static call, so this emitter only ever emits the direct `Call`.
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
        // A MEMBER-form call to an extension carries its receiver in the
        // callee: derive it so the lambda's params instantiate
        // (`dropped.associateWith { name -> ... }` on a DERIVED local left
        // the slot at bare `T`; the annotated form already bound String).
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
    // A trailing lambda always binds the target's last (function-typed)
    // parameter. When a vararg parameter precedes it, positional binding
    // would otherwise pack the lambda into the vararg and leave the last
    // parameter unfilled (Kotlin forbids a positional argument after a
    // vararg, so the trailing lambda is the only filler). Name the lambda
    // to the last parameter so the runtime binds it correctly.
    const arg_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    var type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    if (type_args.len == 0) {
        if (try spliceReifiedTypeArgs(b, func_id, args.len)) |stamped| type_args = stamped;
    }
    const dst = b.allocReg();
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
    return dst;
}

/// The `CallMember` emit form: a resolved extension bound on the implicit
/// `this` with member precedence — a member of the receiver outranks the
/// same-named top-level extension. Routes through `emitExtBareCall`, which
/// selects the static-receiver `CallMember` (or, for a vararg trailing-lambda
/// gap / cast, the prepended static `Call`). With no `this` in scope the bind
/// degrades to the static `Call` of `emitCall`.
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

/// The receiver a BARE call to member `name` actually dispatches on when
/// spliced-subject binds shadow `this` (`with(rec) { writable { … } }`
/// where `writable` is the enclosing class's member): the innermost
/// subject whose class declares the member, else the receiver beneath
/// the whole subject run. Anything unprovable keeps the supplied reg.
/// Whether an extension property (or extension function) named `name` is
/// declared for `head` or one of its registered supertypes: the getter is
/// a registered function with a leading `this` whose declared receiver
/// the head is or extends.
fn extensionPropOnHead(b: *FuncBuilder, head_in: []const u8, name: []const u8) bool {
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

/// An extension property `val <head>.<name>` is known either by its
/// declared-type record or by its lowered getter `__ext_get_<head>_<name>`.
fn extPropExistsOn(b: *const FuncBuilder, head: []const u8, name: []const u8) bool {
    if (b.module.registry.ext_prop_type_heads.get(.{ .a = head, .b = name }) != null) return true;
    var buf: [160]u8 = undefined;
    const gname = std.fmt.bufPrint(&buf, "__ext_get_{s}_{s}", .{ head, name }) catch return false;
    return b.module.funcsBySimpleName(gname).len != 0;
}

/// Whether the smart-cast `this` (`when (this) { is ScatterSetWrapper<T> ->
/// set… }`) declares `name` as a member or property: such a bare name is the
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
    // Only correct when the ambient `this` IS the innermost subject —
    // otherwise scope already resolved beneath the subjects.
    if (sbs[sbs.len - 1].reg != this_reg) {
        if (sct) std.debug.print("[sct] {s}: this r{d} != innermost subject r{d}\n", .{ name, this_reg.int(), sbs[sbs.len - 1].reg.int() });
        return this_reg;
    }
    // A smart-cast `this` (`when (this) { is ScatterSetWrapper<T> -> set… }`)
    // narrows the innermost subject: the NARROWED class's member is this
    // subject's, and the walk below (by the subjects' declared heads —
    // `Set`, which has no `set`) must not hand the read to an outer `this`.
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
        // An EXTENSION property declared on the subject's type (or a
        // supertype) binds the bare name to that subject the same way a
        // member does: `isSpecified` inside a spliced `Dp.takeOrElse`,
        // `indices` inside `List.fastForEach`.
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

/// The `CallMemberOrGlobal` emit form: the bare name dispatches member-first on
/// the runtime implicit receiver, falling back to the resolved global. A
/// non-extension target carries its resolved `func` as the global arm; a
/// resolved extension a member could shadow defers to the pure member-first
/// walk (`lowerUnresolvedBareCall`), which carries no static arm.
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

    // An APPLICABLE own member shadows the same-named top-level function in
    // Kotlin's scope order (`private fun Json(arrays: Boolean, build:
    // PolymorphicModuleBuilder<Any>.() -> Unit)` beside the library's
    // `Json { … }` builder): the implicit-this path binds the MEMBER's
    // lambda shapes and receivers, where the deferred form below would read
    // them off the global candidate.
    if (callee.Path.segments.len == 1 and b.resolve("this") != null and
        b.hasOwnMember(name0) and b.ownFunctionApplicable(name0, call.args.len) and
        !ownMemberRejectsLambdas(b, name0, call.args))
    {
        if (try lowerImplicitThisCall(b, callee, call.args, call.arg_names, ast_type_args)) |r| return r;
    }

    if (!isNonExt(b, func_id)) {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, func_id)) |r| return r;
        return emitCall(b, expr, func_id, was_cast);
    }
    // The whole reason for the member-first form is that a member of the
    // implicit receiver could shadow the resolved global. With NO receiver
    // in scope there is no member to find, and the runtime walk resolves the
    // name only to arrive at the declaration already in hand.
    // A TRAILING LAMBDA keeps the member-or-global path: it does more than
    // dispatch there — the committed candidate shapes the lambda's arity,
    // its receiver and the composable broad masks, and the static emit does
    // not carry that.
    if (!call.has_trailing_lambda and
        b.resolve("this") == null and b.ownerClass() == null and
        b.recvTy() == null and b.spliceRecvTy() == null)
    {
        orEmitAudit(b, "bare_call_no_receiver_to_shadow", "Call", name0);
        return emitCall(b, expr, func_id, was_cast);
    }

    const this_idx = try b.recordCapture("this");
    const broad_masks: ?[]u32 = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (broad_masks) |m| b.allocator.free(m);
    b.pending_arg_broad_masks = broad_masks;
    // The dispatch is deferred, but the trailing lambda's static shape comes
    // from the committed global candidate: read the per-arg lambda arities
    // from it so a `T.() -> R` receiver lambda drops its synthetic `it` here
    // exactly as on the static-call path (`it` then resolves to the
    // enclosing lambda's, matching kotlinc).
    const arg_arity: ?[]const i16 = blk: {
        if (b.module.funcById(func_id)) |f| {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            // The receiver-type head of a receiver-lambda argument comes from
            // the same committed candidate: a deferred `validate { … }` must
            // lower its block with `MockViewValidator` as the body's receiver,
            // or bare ext-overload selection inside (`Composition(a, b, c)`
            // beside a local `MockViewValidator.Composition`) has no receiver
            // evidence and picks the wrong sibling.
            try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
            break :blk try argFnArities(b, f, args, ast_arg_names, recv_off);
        }
        break :blk null;
    };
    // The deferred form types lambda params from the committed global
    // candidate exactly as the static Call emitter does — a bare
    // `all { it.isWhitespace() }` whose inline callee is still a header
    // stub defers, and without this the closure's `it` lowers untyped.
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
    orEmitAudit(b, "bare_call_member_shadowable", "CallMemberOrGlobal", name0);
    const cmg_static_recv: ?ConstId = try cmgStaticRecv(b);
    var type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    // The deferred form keeps the reified splice substitution too: a
    // spliced `enumEntriesIntrinsic()` lowered in a receiver context
    // (a lambda body) is otherwise blind at the runtime intrinsic.
    if (type_args.len == 0) {
        if (try spliceReifiedTypeArgs(b, func_id, args.len)) |stamped| type_args = stamped;
    }
    try b.push(.{ .CallMemberOrGlobal = .{
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
    } });
    return dst;
}

/// The receiver-type tag for a deferred member-or-global bare call: the
/// enclosing extension's declared receiver head, when this body has one.
/// The class id a bare classifier read binds, innermost first: a NESTED
/// class/object of the enclosing class chain (registered under its lifted
/// `Outer$Name` key, invisible to the flat index) beats the package-scope
/// pick — `object E : Base(Key)` inside a class declaring `object Key`
/// reads ITS OWN Key, not `CoroutineContext.Key` from a wildcard import.
pub fn scopedClassIdForRead(b: *FuncBuilder, name0: []const u8, file: anytype) ?ir.ClassId {
    if (nestedClassIdAtLexicalSite(b, name0)) |cid| return cid;
    if (b.module.classIdExactImport(name0, file)) |cid| return cid;
    // A receiver context whose owner chain is unknown here (a super-arg /
    // default-value thunk, a lambda) may still see a NESTED classifier the
    // flat index cannot rank; committing the package-scope pick would
    // override the runtime's scope walk with the wrong declaration
    // (CoroutineContext.Key shadowing a nested `object Key`). Decline —
    // the name-keyed runtime path owns the scoped resolution.
    if (inReceiverContext(b)) return null;
    return b.module.classIdIndexed(name0, b.self_package, file);
}

/// The class visible at a lexical source site without the receiver-context
/// decline used by an immediately-lowered read. Anonymous-object bodies use
/// this before moving into their registry-free side modules.
pub fn classIdAtLexicalSite(b: *FuncBuilder, name0: []const u8, file: anytype) ?ir.ClassId {
    if (nestedClassIdAtLexicalSite(b, name0)) |cid| return cid;
    if (b.module.classIdExactImport(name0, file)) |cid| return cid;
    return b.module.classIdIndexed(name0, b.self_package, file);
}

pub fn nestedClassIdAtLexicalSite(b: *FuncBuilder, name0: []const u8) ?ir.ClassId {
    if (b.ownerClass()) |oc| {
        // Resolve the OWNER to an id once (its lifted simple name is in the
        // class index), then answer through the nesting tree — the one
        // scoped classifier lookup, no string-mangled probing.
        if (b.module.classId(oc)) |owner_id| {
            if (b.module.classIdNestedIn(owner_id, name0)) |cid| return cid;
            // The nesting tree (`class_children`) is built at VM setup, AFTER
            // this lowering runs for a baked pack's bodies, so it can be empty
            // here. Derive the nesting directly from FQNs (which `classIdByFqn`
            // resolves without the tree): a bare `Nested` inside `a.b.Outer`
            // resolves to `a.b.Outer.Nested`, walking up the enclosing-class
            // FQNs so a reference to an outer-scope nested class still binds.
            if (b.module.classFqnById(owner_id)) |ofqn| {
                var pfqn: []const u8 = ofqn;
                var hops: usize = 0;
                while (hops < 16) : (hops += 1) {
                    const cand = std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ pfqn, name0 }) catch break;
                    defer b.allocator.free(cand);
                    if (b.module.classIdByFqn(cand)) |cid| return cid;
                    const dot = std.mem.lastIndexOfScalar(u8, pfqn, '.') orelse break;
                    pfqn = pfqn[0..dot];
                    if (b.module.classIdByFqn(pfqn) == null) break; // left the class nest
                }
            }
        }
    }
    return null;
}

/// Whether the currently bound `this` is the tower's INNERMOST pushed
/// subject (already on the runtime chain, so emissions defer to the
/// chain) rather than a nested inline-EXT splice receiver (not on the
/// chain — must stay pinned; `resumeWith` inside a spliced
/// `Continuation.resume` dispatches on the CAST receiver, which no walk
/// can find).
fn boundThisIsTowerTop(b: *FuncBuilder) bool {
    if (b.encl_tower_depth == 0) return false;
    const top = b.encl_tower_top orelse return false;
    const cur = b.resolve("this") orelse return false;
    return cur.int() == top.int();
}

pub fn cmgStaticRecv(b: *FuncBuilder) Allocator.Error!?ConstId {
    // Under an active subject tower the runtime chain ranks the
    // receivers; a static head would pin the strict-ext arm to the
    // innermost SUBJECT and raise where the walk must fall outward
    // (`eachInline` inside `with(sb) { ... }` is the enclosing class's
    // member-inline, StringBuilder declares nothing by that name).
    if (boundThisIsTowerTop(b)) return null;
    const rt = bareStaticRecvHead(b) orelse return null;
    return try b.module.internConst(b.allocator, .{ .String = rt });
}

/// The static-receiver head a BARE call's dispatch hint should carry.
/// Inside an active inline splice this is the spliced fn's own receiver
/// (null for a receiver-less inline fn) — Kotlin inline bodies are
/// hygienic, so a bare call written in the stdlib body must never resolve
/// against the inline SITE's class. Outside a splice: the enclosing
/// function's receiver, as before.
pub fn bareStaticRecvHead(b: *const FuncBuilder) ?[]const u8 {
    if (b.thisNarrow()) |t| return t;
    if (b.spliceHintActive()) return b.spliceHintRecv();
    // An `is`-narrow of `this` is the innermost receiver truth: inside
    // `if (this is Collection)`, a bare call resolves against Collection
    // exactly as kotlinc smart-casts — `Iterable.contains`'s own
    // `contains(element)` binds the Collection MEMBER, never itself. The
    // narrow lives in the local-decl map under "this" (`narrowLocal`);
    // consulted AFTER the splice hint so a spliced stdlib body never
    // resolves against the inline site's caller context. Default ON with
    // the genuine-narrow gate below — the earlier 4.3x DeepRecursive
    // slowdown and the ArrayDeque mis-bind were both the UNGATED consult
    // trusting an enclosing method's `this` decl through receiver-less
    // lambdas. `KLIO_THIS_NARROW=0` disables for single-binary A/B.
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_THIS_NARROW") orelse "1", "0")) {
        // Only a genuine NARROW counts: the entry must differ from this
        // frame's own declared receiver. A lambda with no receiver of its
        // own sees the ENCLOSING method's `this` decl through the shared
        // local map, and trusting that bound a bare `clear()` inside
        // `apply { }` to the enclosing test method (the ArrayDeque armed
        // recursion) instead of the runtime receiver walk.
        if (b.recvTy()) |declared| {
            if (b.localDeclType("this")) |narrowed| {
                if (!std.mem.eql(u8, typeHead(narrowed), typeHead(declared)))
                    return typeHead(narrowed);
            }
        }
    }
    if (b.recvTy()) |own| return own;
    // A lambda DECLARED receiverless (shape known) chains to the enclosing
    // receiver, exactly Kotlin's implicit-receiver resolution; an untyped
    // receiver-lambda must not (the ArrayDeque hazard above).
    if (b.own_recv_known_none) return b.enclosingRecvTy();
    return null;
}

/// Package/import-scoped declarations carried by a deferred bare call. The
/// optional distinction is intentional: null means the remaining host-only or
/// incomplete-header boundary has no rankable declaration metadata; a non-null
/// (possibly empty) slice is authoritative and prevents the runtime from
/// widening back to the program-wide simple-name index.
pub fn cmgCandidates(b: *FuncBuilder, name: []const u8, file: ir.FileId, user_arg_count: usize) Allocator.Error!?[]const FuncId {
    return b.module.boundedCallCandidates(b.allocator, name, b.self_package, file, user_arg_count);
}

/// The `CallValue` emit form for a bare name with no committed target: load the
/// global by name and invoke it. Used for a host-intrinsic alias whose user
/// overloads do not apply (no class declares the name as a member).
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

/// Arg names for a bare `Call`, synthesizing a name for a trailing lambda
/// that follows a vararg parameter so it binds the target's last
/// (function-typed) parameter rather than being packed into the vararg.
/// Returns the plain interned names otherwise.
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
            // Only the vararg-before-trailing-lambda shape needs the
            // synthesized name; a plain positional trailing lambda already
            // lands on the last parameter. A final vararg of function values
            // absorbs every lambda positionally and must remain unnamed.
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

/// The source trailing lambda immediately before the Compose synthetic pair
/// binds the selected declaration's last user parameter. The AST pass appends
/// the pair and clears `has_trailing_lambda`, so carrying this exact parameter
/// name into IR preserves Kotlin's across-default binding.
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

/// The extension-fn bare-call path: prepend `this`, with trailing-lambda
/// arg-name synthesis and the member-precedence routing.
fn emitExtBareCall(b: *FuncBuilder, expr: *const Expr, func_id_in: FuncId, this_reg: Reg, was_cast_in: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    // The THIRD emission channel for a return-variant family: a bare
    // extension call on the implicit receiver reached here with the
    // heuristic sibling committed, and the member-precedence CallMember
    // below would hand the runtime walk a first-declared re-pick (the
    // Double sumOf, 3.0 where kotlinc prints 3). The trailing lambda's
    // derived return discriminates here exactly as on the other two paths.
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
            // The trailing lambda lands on whichever same-name overload
            // declares a function-typed last parameter of the call's user
            // arity — the bare-call heuristic may have resolved a sibling
            // (`List.get(index)`) that cannot host the lambda, leaving the
            // receiver lambda's `it` unsuppressed. Prefer the overload that
            // actually hosts the trailing lambda for the arity readout.
            const arity_fid: ?FuncId = if (lastArgIsLambda(args))
                (overloadHostingTrailingLambda(b, callee.Path.segments[0].name, args.len) orelse func_id)
            else
                func_id;
            if (arity_fid) |fid| {
                if (b.module.funcById(fid)) |f| {
                    // `all` leads with the synthesized `this`, aligned with
                    // the function's own leading `this` parameter, so no
                    // offset.
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
        // Member-of-receiver precedence: route through call_member on `this`.
        // Carry the trailing lambda's expected arity (from the overload that
        // hosts it) so a `T.() -> R` receiver handler drops its synthetic
        // `it` and resolves bare members through the receiver bound at
        // invocation, even on this member-dispatch arm.
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
        // A captured-`this` receiver context routes through `emitMemberOrGlobal`
        // (the `CallMemberOrGlobal` emit form), never here — `resolveCall` never
        // reaches the static-receiver `CallMember` bind for such a call.
        //
        // Inside an extension body the implicit `this` has the
        // extension's declared receiver type; record it so dispatch
        // resolves extensions against the STATIC type, as kotlinc does.
        const static_recv: ?ConstId = if (bareStaticRecvHead(b)) |rt|
            try b.module.internConst(b.allocator, .{ .String = rt })
        else
            null;
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = this_reg,
            .name = nmc,
            .trailing_lambda = b.callTrailingLambda(),
            .args = uargs[0],
            .n_args = uargs[1],
            .arg_names = uarg_names,
            .static_recv = static_recv,
        } });
        return dst;
    }
    // The member-precedence branch above lowers its own argument run and
    // returns; only the static-call path reaches here, so the `this`-prepended
    // run is lowered now — lowering it earlier would emit (and execute) every
    // argument's side effects a second time on the member path.
    const run = try lowerArgRunWithArity(b, all, arg_arity);
    const dst = b.allocReg();
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
    return dst;
}

/// Emit a dotted `pkg.Outer.Inner.member…` reference by binding the LONGEST
/// prefix that names a class to its EXACT id, then reading each remaining
/// segment as a field. Riding the class id keeps a same-simple-name class in
/// another package from swapping in at runtime (the `gapbuffer` vs
/// `linkbuffer` `Operation.Ins` collision), which a plain name-keyed global
/// load cannot do. Returns null when no prefix names a class — the caller
/// falls back to the name-keyed load.
pub fn emitFqnWithClassPrefix(b: *FuncBuilder, fqn: []const u8) Allocator.Error!?Reg {
    var end = fqn.len;
    while (true) {
        if (b.module.classIdByFqn(fqn[0..end])) |cid| {
            // Ride the exact id ONLY when the prefix's simple name is
            // genuinely ambiguous — collision-mangled out of the flat index
            // (null) or resolving to a DIFFERENT first-registered class.
            // When the simple name resolves to this very class the name-keyed
            // load is already correct AND preferable: an id load returns a
            // class's companion (or misses a same-named factory function),
            // so overriding an unambiguous `kotlinx.coroutines.Job` would
            // hand back `Job.Key` instead of the Job factory.
            const prefix = fqn[0..end];
            const simple = if (std.mem.lastIndexOfScalar(u8, prefix, '.')) |d| prefix[d + 1 ..] else prefix;
            const simple_cid = b.module.classId(simple);
            if (simple_cid != null and simple_cid.?.int() == cid.int()) return null;
            // The id table resolves an `object` prefix straight to its
            // singleton; a plain class prefix loads its class value, off which
            // each remaining segment reads its nested classifier / member.
            var cur = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = fqn[0..end] });
            try b.push(.{ .LoadGlobal = .{ .dst = cur, .name = n, .class = cid } });
            var rest = fqn[end..];
            while (rest.len > 0) {
                rest = rest[1..]; // skip '.'
                const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
                const next = b.allocReg();
                const field = try b.module.internConst(b.allocator, .{ .String = rest[0..dot] });
                try b.push(.{ .GetField = .{ .dst = next, .receiver = cur, .field = field } });
                cur = next;
                rest = rest[dot..];
            }
            return cur;
        }
        const dot = std.mem.lastIndexOfScalar(u8, fqn[0..end], '.') orelse break;
        end = dot;
    }
    return null;
}
