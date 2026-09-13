//! The general call path and the receiver-chain probes it consults.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const inline_state = @import("../inline_state.zig");
const decl_mod = @import("../decl.zig");
const inline_call = @import("../inline_call.zig");
const lambda_body = @import("../lambda_body.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunFull = helpers.lowerArgRunFull;
const internArgNames = helpers.internArgNames;
const exprSpan = helpers.exprSpan;
const CallShape = inline_state.CallShape;
const isLowerAnonCapture = decl_mod.isLowerAnonCapture;
const resolveCapture = lambda_body.resolveCapture;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const paths_mod = @import("paths.zig");
const ownMemberRejectsLambdas = paths_mod.ownMemberRejectsLambdas;
const scopeTypeRename = paths_mod.scopeTypeRename;
const stripLowerFileMangle = paths_mod.stripLowerFileMangle;

const lambda_mod = @import("lambda.zig");
const anyNamedArg = lambda_mod.anyNamedArg;
const ctorLambdaParamTypes = lambda_mod.ctorLambdaParamTypes;
const deinitArgLambdaParamTypes = lambda_mod.deinitArgLambdaParamTypes;
const samLambdaParamTypes = lambda_mod.samLambdaParamTypes;

const compose_mod = @import("compose.zig");
const ctorArgFnArities = compose_mod.ctorArgFnArities;
const ctorRealignedArgNames = compose_mod.ctorRealignedArgNames;
const transformCtorComposableArgs = compose_mod.transformCtorComposableArgs;

const call_mod = @import("call.zig");
const anyClassNamed = call_mod.anyClassNamed;
const ctorParamShadowsVarargMethod = call_mod.ctorParamShadowsVarargMethod;
const localValueNotInvokable = call_mod.localValueNotInvokable;
const lowerCallGeneralNoJump = call_mod.lowerCallGeneralNoJump;
const nameHasReceiverCandidate = call_mod.nameHasReceiverCandidate;
const nameHasReifiedInlineCandidate = call_mod.nameHasReifiedInlineCandidate;
const resolveThisForBareCallNoBind = call_mod.resolveThisForBareCallNoBind;
const tailrecReceiverIsSelf = call_mod.tailrecReceiverIsSelf;
const tryBareInlineExpansion = call_mod.tryBareInlineExpansion;

const emit_mod = @import("emit.zig");
const cmgCandidates = emit_mod.cmgCandidates;
const cmgStaticRecv = emit_mod.cmgStaticRecv;
const emitObjectValueCall = emit_mod.emitObjectValueCall;
const emitTailJumpRun = emit_mod.emitTailJumpRun;
const scopedClassIdForRead = emit_mod.scopedClassIdForRead;

const inline_target_mod = @import("inline_target.zig");
const hostClassOfCompanion = inline_target_mod.hostClassOfCompanion;

const local_call_mod = @import("local_call.zig");
const anyLocalFnOverloadApplicable = local_call_mod.anyLocalFnOverloadApplicable;
const lowerSelectedLocalOverloadCall = local_call_mod.lowerSelectedLocalOverloadCall;
const lowerValueInvocation = local_call_mod.lowerValueInvocation;
const selectLocalFnOverload = local_call_mod.selectLocalFnOverload;
const selfLocalFnApplicable = local_call_mod.selfLocalFnApplicable;

const arg_shape_mod = @import("arg_shape.zig");
const simpleTail = arg_shape_mod.simpleTail;

const static_type_mod = @import("static_type.zig");
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const type_probe_mod = @import("type_probe.zig");
const buildStaticReturnArgShapes = type_probe_mod.buildStaticReturnArgShapes;
const shadowedByClass = type_probe_mod.shadowedByClass;

const bare_call_mod = @import("bare_call.zig");
const allNull = bare_call_mod.allNull;
const lowerCompanionShortcut = bare_call_mod.lowerCompanionShortcut;
const lowerFqnCtorCall = bare_call_mod.lowerFqnCtorCall;
const lowerFqnFlattenCall = bare_call_mod.lowerFqnFlattenCall;
const lowerFqnGlobalCall = bare_call_mod.lowerFqnGlobalCall;
const lowerImplicitThisCall = bare_call_mod.lowerImplicitThisCall;
const lowerPathCall = bare_call_mod.lowerPathCall;
const lowerUnresolvedBareCall = bare_call_mod.lowerUnresolvedBareCall;

const probe_mod = @import("probe.zig");
const inReceiverContext = probe_mod.inReceiverContext;
const recvHeadIsFunctionType = probe_mod.recvHeadIsFunctionType;
const spliceSubjectOuterFor = probe_mod.spliceSubjectOuterFor;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const orEmitAudit = audit_mod.orEmitAudit;

const expected_mod = @import("expected.zig");
const applyExpectedLiteralKindsToCtorArgs = expected_mod.applyExpectedLiteralKindsToCtorArgs;
const enclosingChainMethodsNamed = expected_mod.enclosingChainMethodsNamed;

const member_call_mod = @import("member_call.zig");
const ctorArgStaticHeads = member_call_mod.ctorArgStaticHeads;
const lowerMemberCallFallback = member_call_mod.lowerMemberCallFallback;

const tests_shapes_mod = @import("tests_shapes.zig");
const span = tests_shapes_mod.span;

/// The state one general call-lowering ladder threads through its rungs.
///
/// The driver settles the call's shape once and hands every rung a pointer to
/// it; a rung that resolves the call returns its register and a rung that
/// declines returns null. The classifier fields below are settled partway down
/// by `settleClassifier` and read by the constructor rungs after it, so the
/// order the driver runs the rungs in is load-bearing.
const GenCtx = struct {
    b: *FuncBuilder,
    expr: *const Expr,
    callee: *const Expr,
    args: []Expr,
    ast_arg_names: []?[]const u8,
    ast_type_args: []ast.TypeRef,
    is_infix: bool,
    call_tail: bool,
    /// The class a single-segment callee names, if any.
    callee_class_id: ?ir.ClassId = null,
    callee_is_object: bool = false,
    /// Whether a single-segment class-name call resolves to the constructor.
    shadowed_by_class: bool = false,
    /// Whether a constructible same-named class competes with the function
    /// candidates for this argument count.
    class_competes: bool = false,
    /// Set by the top-level-function rung when its pick leaves the constructor
    /// as the static winner.
    force_static_class: bool = false,
};

pub fn lowerCallGeneral(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call_tail = b.call_tail;
    b.call_tail = false;
    const call = expr.Call;
    const callee = call.callee;
    var g = GenCtx{
        .b = b,
        .expr = expr,
        .callee = callee,
        .args = call.args,
        .ast_arg_names = call.arg_names,
        .ast_type_args = call.type_args,
        .is_infix = call.is_infix,
        .call_tail = call_tail,
    };

    if (try tryEnclosingNestedClassCtor(&g)) |r| return r;
    if (try tryInlineLambdaOnThis(&g)) |r| return r;
    if (try tryInlineLambdaOnReceiver(&g)) |r| return r;
    // Inline expansion (suspend-inline only).
    if (try tryBareInlineExpansion(b, expr)) |r| return r;
    if (try tryOwnReceiverFnProperty(&g)) |r| return r;
    if (try trySplicedReceiverMember(&g)) |r| return r;
    if (try tryAnonCaptureCall(&g)) |r| return r;
    if (try tryInfixAsMemberCall(&g)) |r| return r;
    if (try trySuspendBuilder(&g)) |r| return r;
    if (try tryContractMarker(&g)) |r| return r;
    if (try tryTailrecMemberJump(&g)) |r| return r;
    if (try tryTailrecBareJump(&g)) |r| return r;
    if (try tryCtorParamVarargShadow(&g)) |r| return r;
    if (try tryPlainValueShadowedGlobal(&g)) |r| return r;
    if (try tryTypedCallShadowedGlobal(&g)) |r| return r;
    if (try tryLocalBindingInvocation(&g)) |r| return r;

    try settleClassifier(&g);

    if (try tryRegisteredTopLevelFn(&g)) |r| return r;
    if (try tryObjectValueCall(&g)) |r| return r;
    if (try tryLocalClassCapture(&g)) |r| return r;
    if (try tryIndexedConstructor(&g)) |r| return r;
    if (try tryImplicitThisBareCall(&g)) |r| return r;
    if (try tryUncommittedBareCall(&g)) |r| return r;
    // Built-in stdlib companion shortcuts: `Result.success(x)` etc.
    if (try lowerCompanionShortcut(b, callee, g.args, g.ast_arg_names)) |r| return r;
    if (try tryDottedCallee(&g)) |r| return r;
    // The catch-all member / value call.
    if (callee.* == .Member) return lowerMemberCallFallback(b, expr);
    if (try tryBareMemberFirst(&g)) |r| return r;
    if (try tryArbitratedBareLocal(&g)) |r| return r;
    if (try tryReceiverFnProperty(&g)) |r| return r;
    return emitPlainValueCall(&g);
}


/// A bare ctor callee naming a nested class must bind the one in this
/// enclosing-class chain, so walk the owner's FQN for a class prefix.
fn tryEnclosingNestedClassCtor(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const ast_type_args = g.ast_type_args;
    const is_infix = g.is_infix;
    const call = g.expr.Call;
    if (!is_infix and ast_type_args.len == 0 and callee.* == .Path and
        callee.Path.segments.len == 1 and b.resolve(callee.Path.segments[0].name) == null)
    {
        const cname = callee.Path.segments[0].name;
        if (b.ownerClass()) |owner| resolve: {
            const ocid = b.module.classId(owner) orelse break :resolve;
            if (ocid.int() >= b.module.classes.items.len) break :resolve;
            const bare = b.module.classIdIndexed(cname, b.self_package, callee.Path.segments[0].span.file);
            var prefix: []const u8 = b.module.classes.items[ocid.int()].fqn;
            while (std.mem.findScalarLast(u8, prefix, '.')) |dot| {
                prefix = prefix[0..dot];
                if (b.module.classIdByFqn(prefix) == null) continue; // package, not a class
                const cand = try std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ prefix, cname });
                const cand_cid = b.module.classIdByFqn(cand);
                if (cand_cid != null and (bare == null or cand_cid.?.int() != bare.?.int())) {
                    var segs: std.ArrayList(ast.Ident) = .empty;
                    var it = std.mem.splitScalar(u8, cand, '.');
                    while (it.next()) |seg| try segs.append(b.allocator, .{ .name = seg, .span = callee.Path.segments[0].span });
                    const new_callee = try b.allocator.create(Expr);
                    new_callee.* = Expr{ .Path = .{ .segments = try segs.toOwnedSlice(b.allocator), .span = callee.Path.span } };
                    var new_call = call;
                    new_call.callee = new_callee;
                    const rewritten = Expr{ .Call = new_call };
                    return try lowerCallGeneral(b, &rewritten);
                }
                b.allocator.free(cand);
            }
        }
    }
    return null;
}


/// An inline lambda parameter with a receiver type invoked through an explicit
/// `this`: the qualifier names the lambda's receiver, so this splices.
fn tryInlineLambdaOnThis(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const is_infix = g.is_infix;
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        callee.Member.receiver.* == .This and callee.Member.receiver.This.qualifier == null)
    {
        const lam_name = callee.Member.name.name;
        if (b.inlineLambdaFor(lam_name)) |lam| {
            if (!b.hasEnclosingMember(lam_name)) {
                const recv_reg = try lowerExpr(b, callee.Member.receiver);
                return try inline_call.spliceInlineLambdaOn(b, lam_name, lam, args, recv_reg, callee.Member.receiver);
            }
        }
    }
    return null;
}


/// An inline lambda parameter with a receiver-typed function type invoked with
/// an explicit receiver. Kotlin's invoke convention resolves the local
/// parameter over the receiver's same-named member, so the lambda splices with
/// the qualifier as its receiver. Receiver-typed params only.
fn tryInlineLambdaOnReceiver(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const is_infix = g.is_infix;
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        callee.Member.receiver.* != .This)
    {
        const lam_name = callee.Member.name.name;
        if (b.isReceiverLambdaParam(lam_name)) {
            if (b.inlineLambdaFor(lam_name)) |lam| {
                if (!b.hasEnclosingMember(lam_name)) {
                    const recv_reg = try lowerExpr(b, callee.Member.receiver);
                    return try inline_call.spliceInlineLambdaOn(b, lam_name, lam, args, recv_reg, callee.Member.receiver);
                }
            }
        }
    }
    return null;
}


/// An explicit receiver invoking the enclosing class's receiver-function-typed
/// property: Kotlin runs the stored callable with that value as its receiver.
fn tryOwnReceiverFnProperty(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const is_infix = g.is_infix;
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        callee.Member.receiver.* != .This)
    {
        const mname0 = callee.Member.name.name;
        const own_recv_fn = blk: {
            if (b.resolve("this") == null) break :blk false;
            var owner = b.ownerClass() orelse build.currentOwnerClass();
            var hops: usize = 0;
            while (owner) |o| : (hops += 1) {
                if (hops > 32) break;
                if (b.module.registry.recv_fn_props.get(.{ .a = o, .b = mname0 }) != null) break :blk true;
                owner = b.module.registry.enclosing_class.get(o);
            }
            break :blk false;
        };
        if (own_recv_fn) {
            const recv_r = try lowerExpr(b, callee.Member.receiver);
            const this_reg = b.resolve("this").?;
            const cal = b.allocReg();
            const fld = try b.module.internConst(b.allocator, .{ .String = mname0 });
            try b.push(.{ .GetField = .{ .dst = cal, .receiver = this_reg, .field = fld } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = cal,
                .receiver = recv_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    return null;
}


/// The spliced receiver's chain for a bare call inside an inline body: the
/// narrowing chain, else the splice's own, with a spliced receiver lambda's
/// subject joined ahead of the enclosing framed receiver as kotlinc scopes it.
fn spliceReceiverChain(g: *GenCtx) Allocator.Error!?[]const []const u8 {
    const b = g.b;
    const callee = g.callee;

    var recv_chain = try narrowingRecvChain(b);
    // Inside a splice the active receiver is the splice's own.
    if (recv_chain == null) {
        if (b.spliceRecvTy()) |sr| recv_chain = try recvChainOf(b, sr);
    } else if (b.lambda_splice_resolve != null and inline_call.rfsEnabled()) {
        // A spliced receiver lambda is the innermost implicit receiver, ahead
        // of the enclosing framed receiver, exactly as kotlinc scopes it.
        if (b.spliceRecvTy()) |sr| {
            var sh = typeHead(std.mem.trimEnd(u8, sr, "?"));
            // Registry keys carry file-collision mangles (`Operation$f429`).
            if (b.module.classIdIndexed(sh, b.self_package, callee.Path.segments[0].span.file)) |cid| {
                if (cid.int() < b.module.classes.items.len) sh = b.module.classes.items[cid.int()].name;
            }
            if (recv_chain.?.len == 0 or !std.mem.eql(u8, typeHead(std.mem.trimEnd(u8, recv_chain.?[0], "?")), sh)) {
                const inner = try recvChainOf(b, sh);
                const outer = recv_chain.?;
                const joined = try b.allocator.alloc([]const u8, inner.len + outer.len);
                @memcpy(joined[0..inner.len], inner);
                @memcpy(joined[inner.len..], outer);
                recv_chain = joined;
            }
        }
    }
    return recv_chain;
}

/// Whether the bare name binds the spliced `this`, and whether it is a declared
/// member of the spliced receiver's hierarchy (which the pin below requires).
const SpliceBindEvidence = struct { binds_this: bool, member_of_recv: bool };

fn spliceBareNameEvidence(g: *GenCtx, nm: []const u8, recv_chain: ?[]const []const u8) SpliceBindEvidence {
    const b = g.b;
    const callee = g.callee;

    // The call binds to the spliced `this` when the name is a member of
    // its class or a chain-compatible extension. A capitalized bare call
    // to a nested class name is a constructor, not a method on `this`.
    const is_scoped_class = nm.len > 0 and std.ascii.isUpper(nm[0]) and
        (scopedClassIdForRead(b, nm, callee.Path.segments[0].span.file) != null or
            b.module.classId(nm) != null or anyClassNamed(b, nm));
    // A declared member of the spliced receiver's hierarchy binds the
    // receiver as an extension namesake does.
    const member_of_recv = blk: {
        const chain = recv_chain orelse break :blk false;
        if (chain.len == 0) break :blk false;
        const hs = b.module.registry.hierarchy_shadow_names.get(chain[0]) orelse {
            // An image-loaded class has no shadow entry, but the function
            // index still proves member-extension membership.
            if (!inline_call.rfsEnabled()) break :blk false;
            break :blk mextCandidateOwnedBy(b, nm, chain[0], callee.Path.segments[0].span.file) catch false;
        };
        if (!hs.complete) break :blk false;
        break :blk hs.names.contains(nm);
    };
    // An extension namesake does not pin the walk: static resolution below
    // ranks the overload set with argument evidence.
    var binds_this = !is_scoped_class and (b.hasOwnMember(nm) or member_of_recv);
    // Under the subject tower, arbitrating member versus extension needs
    // argument applicability, which is static resolution's strength.
    if (binds_this and inline_call.rfsEnabled() and b.encl_tower_depth > 0 and
        nameHasReceiverCandidate(b, nm, null))
    {
        binds_this = false;
    }
    if (runtime.envOnce("KLIO_BINDS_TRACE")) |w| {
        if (std.mem.eql(u8, w, nm)) {
            const c0: []const u8 = if (recv_chain) |ch| (if (ch.len != 0) ch[0] else "<empty>") else "<null>";
            const hs_state: []const u8 = if (recv_chain) |ch| blk: {
                if (ch.len == 0) break :blk "-";
                const hs = b.module.registry.hierarchy_shadow_names.get(ch[0]) orelse break :blk "no-entry";
                if (!hs.complete) break :blk "incomplete";
                break :blk if (hs.names.contains(nm)) "contains" else "missing";
            } else "-";
            std.debug.print("[binds] {s} chain0={s} hs={s} own={} scoped_class={} binds={}\n", .{
                nm, c0, hs_state, b.hasOwnMember(nm), is_scoped_class, binds_this,
            });
        }
    }
    return .{ .binds_this = binds_this, .member_of_recv = member_of_recv };
}

/// Pinning to the innermost bound `this` is sound only when the receiver
/// evidence proves that value serves the member; the `hasOwnMember` leg names
/// the lexically enclosing class, which inside a receiver lambda is not the
/// bound `this`.
fn trySpliceReceiverPin(g: *GenCtx, nm: []const u8, recv_chain: []const []const u8, bound_this: Reg) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;

const chain0 = recv_chain[0];
// The pin dispatches on the bound `this`, so the chain
// head must be that same value.
if (b.recvTy() orelse b.spliceRecvTy()) |inner| {
    const ih = typeHead(std.mem.trimEnd(u8, inner, "?"));
    const ch = typeHead(std.mem.trimEnd(u8, chain0, "?"));
    if (!std.mem.eql(u8, ih, ch) and
        !std.mem.eql(u8, simpleTail(ih), simpleTail(ch))) return null;
}
const pin_cid = (if (std.mem.findScalar(u8, chain0, '.') != null)
    b.module.classIdByFqn(chain0)
else
    b.module.uniqueClassIdBySimpleName(chain0)) orelse return null;
var shape_set = try buildStaticReturnArgShapes(b, args, ast_arg_names);
defer shape_set.deinit(b.allocator);
const pin_recv_ref: ir.TypeRef = .{ .name = chain0, .nullable = false, .args = &.{} };
const resolved = b.module.resolveMemberCall(pin_cid, nm, shape_set.shapes, .{
    .caller_file = callee.Path.segments[0].span.file,
    .lexical_owner = null,
    .actual_type_param_bounds = &.{},
    .receiver_type = pin_recv_ref,
});
const target = resolved.target orelse return null;
const tf = b.module.funcById(target) orelse return null;
if (!tf.hasBody()) return null;
// A function-spelled parameter fed a non-lambda argument
// is the member-versus-extension shape static shapes
// cannot refute through a splice substitution.
for (tf.params, 0..) |*tp, tpi| {
    if (tpi == 0 and std.mem.eql(u8, tp.name, "this")) continue;
    const ai = tpi - @intFromBool(tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this"));
    if (ai >= args.len) break;
    if (recvHeadIsFunctionType(tp.ty.name) and
        args[ai] != .Lambda and args[ai] != .AnonFun) return null;
}
// A stdlib or pack member may be shadowed by an invisible
// host binding, so pin only program-owned declarations.
const shipped_pkg = std.mem.eql(u8, tf.package, "kotlin") or
    std.mem.startsWith(u8, tf.package, "kotlin.") or
    std.mem.startsWith(u8, tf.package, "kotlinx.") or
    std.mem.startsWith(u8, tf.package, "androidx.") or
    std.mem.startsWith(u8, tf.package, "io.ktor");
if (shipped_pkg) return null;
const run = try lowerArgRun(b, args);
const dst = b.allocReg();
orEmitAudit(b, "inline_splice_recv_pin", "CallVirtual", nm);
try b.push(.{ .CallVirtual = .{
    .dst = dst,
    .receiver = bound_this,
    .slot = ir.MethodSlotId.fromFunc(target),
    .args = run[0],
    .n_args = run[1],
} });
return dst;
}

/// The runtime member-or-global walk: the chain already holds every nested
/// subject in scope order, so pinning one register would invert Kotlin's
/// innermost-first ranking.
fn emitSpliceReceiverWalk(g: *GenCtx, nm: []const u8, bound_this: Reg) Allocator.Error!Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;

const run = try lowerArgRun(b, args);
const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
const dst = b.allocReg();
const nmc = try b.module.internConst(b.allocator, .{ .String = nm });
orEmitAudit(b, "inline_splice_recv_walk", "CallMemberOrGlobal", nm);
try b.push(.{ .CallMemberOrGlobal = .{
    .dst = dst,
    .this_idx = 0,
    .name = nmc,
    .trailing_lambda = b.callTrailingLambda(),
    .args = run[0],
    .n_args = run[1],
    .arg_names = arg_names,
    // The chain already holds every nested subject in scope
    // order, so pinning one register inverts Kotlin's
    // innermost-first ranking.
    .recv = if (b.encl_tower_depth > 0) null else bound_this,
    .candidates = try cmgCandidates(b, nm, callee.Path.segments[0].span.file, run[1]),
    // Under the subject tower the runtime chain ranks the
    // receivers; a static head would pin the strict-ext arm to
    // the subject where the walk should fall outward.
    .static_recv = if (b.encl_tower_depth > 0) null else try cmgStaticRecv(b),
} });
return dst;
}

/// With the spliced receiver's type unknown the call cannot be proven to bind
/// the innermost `this`, so `CallMemberOrGlobal` tries the bound receiver, then
/// each enclosing receiver innermost-first, before any global.
fn emitSpliceUnknownReceiver(g: *GenCtx, nm: []const u8) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;

// With the spliced receiver's type unknown the call cannot be
// proven to bind the innermost `this`, so `CallMemberOrGlobal`
// tries the bound receiver, then each enclosing receiver
// innermost-first, before any global. The bound register is passed
// directly so the splice receiver stays innermost.
if (b.resolve("this")) |bound_this| {
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nmc = try b.module.internConst(b.allocator, .{ .String = nm });
    orEmitAudit(b, "inline_splice_unknown_recv", "CallMemberOrGlobal", nm);
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = 0,
        .name = nmc,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .recv = if (b.encl_tower_depth > 0) null else bound_this,
        .candidates = try cmgCandidates(b, nm, callee.Path.segments[0].span.file, run[1]),
        // Under the subject tower the runtime chain ranks the
        // receivers; a static head would pin the strict-ext arm to
        // the subject where the walk should fall outward.
        .static_recv = if (b.encl_tower_depth > 0) null else try cmgStaticRecv(b),
    } });
    return dst;
} else if (b.knowsOuter("this") or b.capturesThisSlot()) {
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const this_idx = try b.recordCapture("this");
    const dst = b.allocReg();
    const nmc = try b.module.internConst(b.allocator, .{ .String = nm });
    orEmitAudit(b, "inline_splice_unknown_recv", "CallMemberOrGlobal", nm);
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = this_idx,
        .name = nmc,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .candidates = try cmgCandidates(b, nm, callee.Path.segments[0].span.file, run[1]),
        .static_recv = try cmgStaticRecv(b),
    } });
    return dst;
}
    return null;
}

/// Inside an inline-extension splice, a bare call to a member of the spliced
/// receiver is `this.member(...)`, resolved before the bare-name paths treat it
/// as a top-level function. The bound `this` is a local register, so it
/// dispatches as an explicit `CallMember`.
fn trySplicedReceiverMember(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    if (!(!g.is_infix and callee.* == .Path and callee.Path.segments.len == 1 and
        b.currentInlineFn() != null)) return null;
    const nm = callee.Path.segments[0].name;
    const recv_chain = try spliceReceiverChain(g);
    // A captured crossinline param shadows a same-named member of the anon
    // object being lowered, so fall through to the anon-capture invocation.
    if (!(b.resolve(nm) == null and !b.knowsOuter(nm) and !isLowerAnonCapture(nm) and
        !nameHasReifiedInlineCandidate(nm))) return null;
    const ev = spliceBareNameEvidence(g, nm, recv_chain);
    if (ev.binds_this) {
        if (b.resolve("this")) |bound_this| {
            // Sound only when no enclosing receiver could shadow, so the
            // chain must be exactly the bound receiver.
            if (ev.member_of_recv and ast_type_args.len == 0 and
                recv_chain.?.len == 1 and
                // Under the subject tower the bound `this` is the spliced
                // subject, not the lexical owner a pin would resolve.
                b.encl_tower_depth == 0 and
                runtime.envOnce("KLIO_SPLICE_PIN") == null and
                allNull(ast_arg_names))
            {
                if (try trySpliceReceiverPin(g, nm, recv_chain.?, bound_this)) |r| return r;
            }
            return try emitSpliceReceiverWalk(g, nm, bound_this);
        }
    } else if (recv_chain == null and nameHasReceiverCandidate(b, nm, null)) {
        return try emitSpliceUnknownReceiver(g, nm);
    }
    return null;
}


/// Bare call to a name the enclosing anon object closes over.
fn tryAnonCaptureCall(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const is_infix = g.is_infix;
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) == null and
        isLowerAnonCapture(callee.Path.segments[0].name))
    {
        const nm0 = callee.Path.segments[0].name;
        const idx = try b.recordCapture(nm0);
        const callee_r = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = callee_r, .idx = idx } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        // Inside a receiver splice the captured name may shadow a member of the
        // spliced receiver, which Kotlin resolves to.
        if (b.spliceRecvTy() != null) {
            if (try resolveThisForBareCallNoBind(b)) |this_reg| {
                const nmc = try b.module.internConst(b.allocator, .{ .String = nm0 });
                orEmitAudit(b, "cvom_anon_capture_splice", "CallValueOrMember", nm0);
                try b.push(.{ .CallValueOrMember = .{
                    .dst = dst,
                    .callee = callee_r,
                    .this_recv = this_reg,
                    .name = nmc,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }
    return null;
}


/// Infix call `a fn b` becomes `a.fn(b)`, routed through member lowering so it
/// binds statically; a plain CallMember leaves every infix extension walking.
fn tryInfixAsMemberCall(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const is_infix = g.is_infix;
    const call = g.expr.Call;
    if (is_infix and args.len == 2 and callee.* == .Path and callee.Path.segments.len == 1) {
        // An infix call is `a.f(b)`, so route it through member lowering and bind
        // statically; a plain CallMember leaves every infix extension walking.
        var member_callee = Expr{ .Member = .{
            .receiver = &args[0],
            .name = callee.Path.segments[0],
            .safe = false,
            .span = call.span,
        } };
        const member_call = Expr{ .Call = .{
            .callee = &member_callee,
            .args = args[1..],
            .arg_names = call.arg_names[1..],
            .type_args = call.type_args,
            .is_infix = false,
            .has_trailing_lambda = call.has_trailing_lambda,
            .span = call.span,
        } };
        return try lowerMemberCallFallback(b, &member_call);
    }
    return null;
}


/// `suspend { … }` builder: the value is the lambda itself, its body marked
/// suspend so dispatch can distinguish it from a plain function value.
fn trySuspendBuilder(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "suspend") and
        args.len == 1 and args[0] == .Lambda)
    {
        b.pending_suspend_lambda = true;
        return try lowerExpr(b, &args[0]);
    }
    return null;
}


/// `contract { … }`: compile-time marker with no runtime effect.
fn tryContractMarker(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "contract") and
        args.len == 1 and args[0] == .Lambda)
    {
        return try b.emitConst(.Unit);
    }
    return null;
}


/// A self-call inside a tailrec fn becomes a TailJump that re-binds the
/// parameters in place. An instance or extension tailrec function carries its
/// receiver as the leading implicit param, so the arg run must lead with
/// `this` or every re-bound parameter shifts by one.
fn tryTailrecMemberJump(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const call_tail = g.call_tail;
    const expr = g.expr;
    if (call_tail and callee.* == .Member and !callee.Member.safe and b.tailrecSelfHasThis() and
        tailrecReceiverIsSelf(b, callee.Member.receiver))
    {
        if (b.tailrecSelf()) |ts| {
            if (std.mem.eql(u8, ts, callee.Member.name.name)) {
                if (try emitTailJumpRun(b, callee.Member.receiver, args, expr.Call.arg_names)) |run| {
                    b.terminate(.{ .TailJump = .{ .args = run[0], .n_args = @intCast(run[1].int()) } });
                    const dead = try b.allocBlock();
                    b.switchTo(dead);
                    return try b.emitConst(.Unit);
                }
            }
        }
    }
    return null;
}


/// The same jump for a bare self-call, whose receiver is synthesized.
fn tryTailrecBareJump(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const is_infix = g.is_infix;
    const call_tail = g.call_tail;
    const expr = g.expr;
    if (call_tail and callee.* == .Path and callee.Path.segments.len == 1) {
        if (b.tailrecSelf()) |ts| {
            if (std.mem.eql(u8, ts, callee.Path.segments[0].name)) {
                const sp = exprSpan(callee);
                const synth_segs = try b.allocator.alloc(ast.Ident, 1);
                defer b.allocator.free(synth_segs);
                synth_segs[0] = .{ .name = "this", .span = sp };
                const this_expr = Expr{ .Path = .{ .segments = synth_segs, .span = sp } };
                // An infix self-call (`(this - 1) test x`) carries its receiver
                // as the first written argument.
                const recv: ?*const Expr = if (b.tailrecSelfHasThis() and !is_infix) &this_expr else null;
                const run = (try emitTailJumpRun(b, recv, args, expr.Call.arg_names)) orelse return try lowerCallGeneralNoJump(b, expr);
                b.terminate(.{ .TailJump = .{ .args = run[0], .n_args = @intCast(run[1].int()) } });
                const dead = try b.allocBlock();
                b.switchTo(dead);
                return try b.emitConst(.Unit);
            }
        }
    }
    return null;
}


/// A ctor-property param shadowing a same-named vararg method dispatches by
/// argument shape, so route to member dispatch.
fn tryCtorParamVarargShadow(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) != null and
        ctorParamShadowsVarargMethod(b, callee.Path.segments[0].name))
    {
        if (b.resolve("this")) |this_reg| {
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            const nmc = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = this_reg,
                .name = nmc,
                .trailing_lambda = b.callTrailingLambda(),
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    return null;
}


/// A `name(…)` call whose name resolves to a non-function local names the
/// shadowed global when the local's declared type cannot be invoked at all.
fn tryPlainValueShadowedGlobal(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    if (callee.* == .Path and callee.Path.segments.len == 1 and ast_type_args.len == 0) {
        const nm0 = callee.Path.segments[0].name;
        // A member function of the enclosing class chain still takes the call
        // when a plain value shadows the name.
        var chain_buf: [8]FuncId = undefined;
        const chain_fns = try enclosingChainMethodsNamed(b, nm0, callee.Path.segments[0].span.file, &chain_buf);
        if (b.resolve(nm0) != null and !b.isLocalFn(nm0) and !b.isLocalExtFn(nm0) and
            b.module.classIdIndexed(nm0, b.self_package, callee.Path.segments[0].span.file) == null and
            chain_fns.len == 0 and
            // Redirect to a global only when one of this name exists; a local
            // whose declared type merely reads as non-invokable is the callee.
            b.module.hasBareCallCandidate(nm0, callee.Path.segments[0].span.file) and
            localValueNotInvokable(b, nm0))
        {
            const gv = b.allocReg();
            const cn = try b.module.internConst(b.allocator, .{ .String = nm0 });
            orEmitAudit(b, "call_shadowed_by_plain_value", "LoadGlobal", nm0);
            try b.push(.{ .LoadGlobal = .{ .dst = gv, .name = cn } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = gv,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    return null;
}


/// A `name<T>(…)` call whose name resolves to a non-function local names the
/// shadowed global: a value takes no call-site type arguments.
fn tryTypedCallShadowedGlobal(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    if (callee.* == .Path and callee.Path.segments.len == 1 and ast_type_args.len != 0) {
        const nm0 = callee.Path.segments[0].name;
        if (b.resolve(nm0) != null and !b.isLocalFn(nm0) and
            b.module.classIdIndexed(nm0, b.self_package, callee.Path.segments[0].span.file) == null)
        {
            const gv = b.allocReg();
            const cn = try b.module.internConst(b.allocator, .{ .String = nm0 });
            orEmitAudit(b, "typed_call_shadowed_global", "LoadGlobal", nm0);
            try b.push(.{ .LoadGlobal = .{ .dst = gv, .name = cn } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
            const dst = b.allocReg();
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = gv,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
                .type_args = type_args,
            } });
            return dst;
        }
    }
    return null;
}


/// A single-name callee resolving to a local binding or parameter is a value
/// invocation.
fn tryLocalBindingInvocation(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        // Same-named local-fn siblings are overloads: when the call's static facts
        // select exactly one, call through its mangled cell.
        const bare = callee.Path.segments[0].name;
        var local_fn_inapplicable = false;
        if (b.localFnOverloads(bare)) |ovs| {
            if (runtime.envOnce("KLIO_LFN_TRACE") != null)
                std.debug.print("[lfn] {s} ovs={d}\n", .{ bare, ovs.len });
            if (try selectLocalFnOverload(b, ovs, args, ast_arg_names)) |m| {
                if (runtime.envOnce("KLIO_LFN_TRACE") != null)
                    std.debug.print("[lfn] {s} selected={s} cell={} outer={}\n", .{ bare, m, b.resolve(m) != null, b.knowsOuter(m) });
                if (try lowerSelectedLocalOverloadCall(b, bare, m, args, ast_arg_names)) |r| return r;
            } else if (runtime.envOnce("KLIO_LFN_TRACE") != null)
                std.debug.print("[lfn] {s} no-select\n", .{bare});
        } else if (b.resolve(bare) != null and runtime.envOnce("KLIO_LFN_TRACE") != null)
            std.debug.print("[lfn] {s} no-registry\n", .{bare});
        // A bare call to the enclosing local fn's own name binds that fn through
        // its mangled cell; a later same-named sibling rebinds the plain slot.
        if (b.selfLocalFn()) |slf| {
            if (std.mem.eql(u8, slf.name, bare) and
                try selfLocalFnApplicable(b, slf.mangled, bare, args, ast_arg_names))
            {
                if (try lowerSelectedLocalOverloadCall(b, bare, slf.mangled, args, ast_arg_names)) |r| return r;
            }
        }
        if (b.localFnDecls(bare)) |decls| {
            local_fn_inapplicable = !(try anyLocalFnOverloadApplicable(
                b,
                decls,
                args,
                ast_arg_names,
            ));
            if (runtime.envOnce("KLIO_LFN_TRACE") != null)
                std.debug.print("[lfn] {s} decls={d} inapplicable={} plain={} mangled_cell={} mangled_outer={} splice_win={}\n", .{
                    bare,
                    decls.len,
                    local_fn_inapplicable,
                    b.resolve(bare) != null,
                    if (decls.len > 0) b.resolve(decls[0].mangled) != null else false,
                    if (decls.len > 0) b.knowsOuter(decls[0].mangled) else false,
                    b.lambda_splice_resolve != null,
                });
            // A lone local fn reached from a nested body routes through its mangled
            // overload cell, which binds before the body lowers so nested calls can
            // capture it. The plain name may also hold a same-named local property,
            // which owns the bare binding.
            const plain_is_property = b.resolve(bare) != null and !b.isLocalFn(bare);
            if (decls.len == 1 and !local_fn_inapplicable and
                (b.resolve(bare) == null or plain_is_property) and
                (b.resolve(decls[0].mangled) != null or b.knowsOuter(decls[0].mangled)))
            {
                if (try lowerSelectedLocalOverloadCall(b, bare, decls[0].mangled, args, ast_arg_names)) |r| return r;
            }
        }
        // A local function shadows an outer one by name, but only among candidates
        // that can take the call.
        if (!local_fn_inapplicable) {
            if (try lowerValueInvocation(b, callee, args, ast_arg_names)) |r| return r;
            // A lone applicable local fn reached as a capture invokes the captured
            // closure value, or the call falls to the classifier arms and loses to
            // a same-named import. Gated on an actual classifier collision.
            if (b.localFnDecls(bare) != null and b.resolve(bare) == null and b.knowsOuter(bare) and
                b.module.classIdIndexed(bare, b.self_package, callee.Path.segments[0].span.file) != null)
            {
                const cap = try resolveCapture(b, bare);
                const callee_r = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = callee_r, .cell = cap } });
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                orEmitAudit(b, "captured_local_fn_call", "CallValue", bare);
                try b.push(.{ .CallValue = .{
                    .dst = dst,
                    .callee = callee_r,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
    }
    return null;
}


/// Settle the classifier facts the constructor rungs below read: the class a
/// single-segment callee names, whether it is an object, whether the call
/// resolves to its constructor, and whether it competes with the function
/// candidates.
fn settleClassifier(g: *GenCtx) Allocator.Error!void {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;

    const callee_class_id: ?ir.ClassId = if (callee.* == .Path and callee.Path.segments.len == 1)
        b.module.classIdIndexed(callee.Path.segments[0].name, b.self_package, callee.Path.segments[0].span.file) orelse
            b.module.classIdExactImport(callee.Path.segments[0].name, callee.Path.segments[0].span.file)
    else
        null;
    const callee_is_object = if (callee_class_id) |cid|
        cid.int() < b.module.classes.items.len and b.module.classes.items[cid.int()].is_object
    else
        false;

    // Whether a single-segment class-name call resolves to the constructor.
    const shadowed_by_class = if (callee_is_object) false else try shadowedByClass(b, callee, args, ast_arg_names);
    // A constructible same-named class competes with the function candidates.
    // Until constructors join the shared applicability set, the deferred
    // class-carrying form below compares both on the actual argument types.
    const class_competes = callee.* == .Path and callee.Path.segments.len == 1 and
        !shadowed_by_class and !callee_is_object and blk: {
        const cid = callee_class_id orelse break :blk false;
        if (cid.int() >= b.module.classes.items.len) break :blk false;
        const cls = &b.module.classes.items[cid.int()];
        // An abstract/interface/sealed class never constructs, so it
        // does not compete with the function candidates.
        if (cls.is_abstract) break :blk false;
        // The class competes when its primary constructor takes this argument
        // count, or when the count exceeds the primary arity, since a secondary
        // constructor invisible in the IR class may accept it. With no matching
        // constructor the runtime falls to the factory.
        var required: usize = 0;
        var has_vararg = false;
        for (cls.primary_params) |*p| {
            if (p.is_vararg) {
                has_vararg = true;
                continue;
            }
            if (!p.has_default) required += 1;
        }
        break :blk (args.len >= required and (has_vararg or args.len <= cls.primary_params.len)) or
            args.len > cls.primary_params.len;
    };
    g.callee_class_id = callee_class_id;
    g.callee_is_object = callee_is_object;
    g.shadowed_by_class = shadowed_by_class;
    g.class_competes = class_competes;
}


/// Path-callee with a registered top-level fn becomes `Call{func}`.
fn tryRegisteredTopLevelFn(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const expr = g.expr;
    const shadowed_by_class = g.shadowed_by_class;
    const class_competes = g.class_competes;
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (try lowerPathCall(
            b,
            expr,
            shadowed_by_class,
            class_competes,
            &g.force_static_class,
        )) |r| return r;
    }
    return null;
}


/// A named object is a singleton value, invoked through its operator surface
/// once same-named function overloads have had their tier.
fn tryObjectValueCall(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    if (g.callee_is_object) {
        return try emitObjectValueCall(b, args, ast_arg_names, ast_type_args, callee.Path.segments[0].name, g.callee_class_id.?);
    }
    return null;
}


/// A local class declared in this or an enclosing function shadows any
/// same-simple-name module class for a bare constructor call.
fn tryLocalClassCapture(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const nm0 = callee.Path.segments[0].name;
        if (build.isLocalClassInScope(nm0) and b.resolve(nm0) == null and b.knowsOuter(nm0)) {
            const callee_r = try resolveCapture(b, nm0);
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            orEmitAudit(b, "local_class_capture_ctor", "CallValue", nm0);
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    return null;
}


/// The class a bare constructor call names: the indexed lookup binds the class
/// visible from the caller's package and imports, so a cross-package
/// simple-name collision constructs the right class. A typealias constructs its
/// expansion, retried through the alias registry scoped at this site.
fn indexedCtorClassId(b: *FuncBuilder, ctor_seg: ast.Ident) Allocator.Error!?ir.ClassId {
    return b.module.classIdIndexed(ctor_seg.name, b.self_package, ctor_seg.span.file) orelse
        b.module.classIdExactImport(ctor_seg.name, ctor_seg.span.file) orelse blk_alias: {
            const aref = ir.TypeRef{ .name = ctor_seg.name, .nullable = false, .args = &.{} };
            const resolved = try b.module.resolveTypeAliasAt(b.allocator, aref, ctor_seg.span.file, b.self_package);
            const rh = typeHead(std.mem.trimEnd(u8, resolved.name, "?"));
            if (std.mem.eql(u8, rh, ctor_seg.name)) break :blk_alias null;
            break :blk_alias b.module.classIdIndexed(rh, b.self_package, ctor_seg.span.file) orelse
                b.module.classId(rh);
        };
}

/// Construct the named class, or hand the call to the runtime arbitration
/// between the class and a same-named factory function.
fn emitIndexedConstructor(g: *GenCtx, class_id: ir.ClassId) Allocator.Error!Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const call = g.expr.Call;
    const shadowed_by_class = g.shadowed_by_class;
    const force_static_class = g.force_static_class;

applyExpectedLiteralKindsToCtorArgs(b, class_id, args, ast_arg_names);
const ctor_arity = try ctorArgFnArities(b, class_id, args, ast_arg_names);
defer if (ctor_arity) |ca| b.allocator.free(ca);
// The compose pass shapes a sink lambda with the bare composer pair and
// lowering repairs it against the resolved parameter's arity; a class
// whose primary constructor takes a composable lambda needs the same
// repair or the content invokes with shifted slots.
try transformCtorComposableArgs(b, class_id, args, ast_arg_names);
const cls = &b.module.classes.items[class_id.int()];
// A fun-interface conversion types its lambda's params from the
// interface's single abstract method, instantiated by the explicit type
// args or the expected type.
var sam_lpt: ?[]?[]ir.TypeRef = null;
defer if (sam_lpt) |types| deinitArgLambdaParamTypes(b.allocator, types);
if (cls.is_fun_interface and args.len == 1 and args[0] == .Lambda and
    cls.type_params.len != 0)
{
    sam_lpt = try samLambdaParamTypes(b, class_id, call.type_args);
}
if (runtime.envOnce("KLIO_SAM_TRACE") != null and cls.is_fun_interface) {
    std.debug.print("[sam] {s} tps={d} lam={} lpt={} exp={}\n", .{ cls.name, cls.type_params.len, args.len == 1 and args[0] == .Lambda, sam_lpt != null, b.peekExpected() != null });
}
// A ctor's concrete fn-typed params type their lambda arguments
// (`IntArray(256) { it shr 4 }` types `it` Int).
if (sam_lpt == null) sam_lpt = try ctorLambdaParamTypes(b, class_id, args);
b.pending_arg_lambda_param_types = sam_lpt;
const run = try lowerArgRunFull(b, args, ctor_arity, null);
b.pending_arg_lambda_param_types = null;
const realigned = try ctorRealignedArgNames(b, class_id, args, ast_arg_names);
defer if (realigned) |r| b.allocator.free(r);
const arg_names = try internArgNames(b.allocator, b.module, realigned orelse ast_arg_names);
const dst = b.allocReg();
const static_sam = cls.is_fun_interface and args.len == 1 and !anyNamedArg(ast_arg_names);
if (shadowed_by_class or force_static_class or static_sam) {
    // The subject of an enclosing receiver lambda is the innermost
    // implicit receiver of the inner class's outer type, so it is the
    // new instance's outer, as kotlinc emits for `w.Inner()`.
    if (spliceSubjectOuterFor(b, class_id)) |subject| {
        const nm = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
        orEmitAudit(b, "inner_ctor_on_splice_subject", "CallMember", callee.Path.segments[0].name);
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = subject,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }
    // A bare `Inner()` uses the enclosing `this` as the new instance's
    // outer, reachable inside a lambda body only through the capture
    // set; kotlinc likewise forces a `this$0` capture.
    if (class_id.int() < b.module.classes.items.len and
        b.module.classes.items[class_id.int()].is_inner and
        b.resolve("this") == null and b.capturesThisSlot())
    {
        _ = try b.recordCapture("this");
    }
    orEmitAudit(b, if (static_sam) "fun_interface_sam" else "bare_ctor_shadowed_by_class", "NewInstance", callee.Path.segments[0].name);
    try b.push(.{ .NewInstance = .{
        .dst = dst,
        .class = class_id,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .arg_static_heads = try ctorArgStaticHeads(b, args),
    } });
} else {
    const this_idx = try b.recordCapture("this");
    const nmc = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
    orEmitAudit(b, "class_or_factory_call", "CallMemberOrGlobal", callee.Path.segments[0].name);
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = this_idx,
        .name = nmc,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .class = class_id,
        .candidates = try cmgCandidates(b, callee.Path.segments[0].name, callee.Path.segments[0].span.file, run[1]),
        .static_recv = try cmgStaticRecv(b),
    } });
}
return dst;
}

/// A bare `Name(...)` naming a class in scope.
fn tryIndexedConstructor(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const call = g.expr.Call;
    if (!(callee.* == .Path and callee.Path.segments.len == 1)) return null;
    const ctor_seg = callee.Path.segments[0];
    const ctor_cid = try indexedCtorClassId(b, ctor_seg);
    // An applicable own member named like a class in scope wins the bare call
    // in Kotlin's scope order, binding the member's lambda shapes.
    if (ctor_cid != null and b.ownerClass() != null and b.resolve("this") != null and
        b.hasOwnMember(ctor_seg.name) and b.ownFunctionApplicable(ctor_seg.name, args.len) and
        !ownMemberRejectsLambdas(b, ctor_seg.name, args))
    {
        if (try lowerImplicitThisCall(b, callee, args, ast_arg_names, call.type_args)) |r| return r;
    }
    if (ctor_cid) |class_id| return try emitIndexedConstructor(g, class_id);
    return null;
}


/// Inside a method or extension body, an unqualified `name(...)` that matched
/// no local, top-level fn, or class is a method call on `this`.
fn tryImplicitThisBareCall(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    if (callee.* == .Path) {
        if (try lowerImplicitThisCall(
            b,
            callee,
            args,
            ast_arg_names,
            ast_type_args,
        )) |r| return r;
    }
    return null;
}


/// The resolver above declined to commit a target, so in a receiver context the
/// call must still dispatch member-first; a bare-name value load would miss
/// receiver methods entirely. Outside a receiver context an indexed name keeps
/// the value-call fallback.
fn tryUncommittedBareCall(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) == null and
        !b.knowsOuter(callee.Path.segments[0].name) and
        b.module.classId(callee.Path.segments[0].name) == null and
        // A collision-mangled class reached only through an explicit import is
        // registered under its mangled name, so `classId` misses.
        b.module.classIdExactImport(callee.Path.segments[0].name, callee.Path.segments[0].span.file) == null and
        (b.module.funcId(callee.Path.segments[0].name) == null or inReceiverContext(b)))
    {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, null)) |r| return r;
    }
    return null;
}


/// A package-qualified constructor call is resolved before the function-FQN and
/// member-fallback paths, which would read the package head as a field of the
/// implicit receiver. A multi-segment Path callee is the same dotted-FQN shape,
/// so it routes here for the same overload-precise binding.
fn tryDottedCallee(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    const expr = g.expr;
    const dotted_callee = callee.* == .Member or
        (callee.* == .Path and callee.Path.segments.len >= 2);
    if (callee.* == .Member) {
        if (try lowerFqnCtorCall(b, expr)) |r| return r;
    }
    // Package-qualified call to a user / pack top-level function.
    if (dotted_callee) {
        if (try lowerFqnFlattenCall(b, callee, args, ast_arg_names, ast_type_args)) |r| return r;
    }
    // Fully-qualified callee resolved as a global, CallValue.
    if (dotted_callee) {
        if (try lowerFqnGlobalCall(b, callee, args, ast_arg_names)) |r| return r;
    }
    return null;
}


/// A bare single-name call no earlier path resolved, whose name could be a
/// member of an implicit receiver, must dispatch member-first rather than fall
/// to a value load binding a same-named top-level global.
fn tryBareMemberFirst(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const ast_type_args = g.ast_type_args;
    const call = g.expr.Call;
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const nm0 = callee.Path.segments[0].name;
        // Only reroute a name that actually is an own or enclosing member, so a
        // top-level helper called in a lambda stays on the global path.
        if (b.resolve(nm0) == null and inReceiverContext(b) and b.hasEnclosingMember(nm0)) {
            // A captured local fn is a candidate the runtime member walk cannot
            // see, so emit the runtime-arbitrated form; its value arm falls to the
            // enclosing member when the closure's declared params refute the args.
            if (b.knowsOuter(nm0) and call.type_args.len == 0) {
                if (try resolveThisForBareCallNoBind(b)) |this_reg| {
                    const cv = try resolveCapture(b, nm0);
                    const run0 = try lowerArgRun(b, args);
                    const an0 = try internArgNames(b.allocator, b.module, ast_arg_names);
                    const nmc = try b.module.internConst(b.allocator, .{ .String = nm0 });
                    const d0 = b.allocReg();
                    orEmitAudit(b, "cvom_bare_capture", "CallValueOrMember", nm0);
                    try b.push(.{ .CallValueOrMember = .{
                        .dst = d0,
                        .callee = cv,
                        .this_recv = this_reg,
                        .name = nmc,
                        .args = run0[0],
                        .n_args = run0[1],
                        .arg_names = an0,
                    } });
                    return d0;
                }
            }
            if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, null)) |r| return r;
        }
    }
    return null;
}


/// A bare call whose name is a bound local or captured outer does not shadow an
/// implicit receiver's member unless the local is invokable, so emit the
/// arbitrated form: value when callable, else the member on `this`.
fn tryArbitratedBareLocal(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const call = g.expr.Call;
    if (callee.* == .Path and callee.Path.segments.len == 1 and call.type_args.len == 0) {
        const nm0 = callee.Path.segments[0].name;
        // A receiver-lambda param is Kotlin-unambiguous, the param winning with its
        // receiver bound by declared type, so let the ladder reach the arms
        // carrying the declared head.
        if (!b.isLocalFn(nm0) and !b.isLocalExtFn(nm0) and
            !b.isReceiverLambdaParam(nm0) and
            (b.knowsOuter(nm0) or b.resolve(nm0) != null))
        {
            if (try resolveThisForBareCallNoBind(b)) |this_reg| {
                const cv = try lowerExpr(b, callee);
                const run0 = try lowerArgRun(b, args);
                const an0 = try internArgNames(b.allocator, b.module, ast_arg_names);
                const nmc = try b.module.internConst(b.allocator, .{ .String = nm0 });
                const d0 = b.allocReg();
                orEmitAudit(b, "cvom_bare_local", "CallValueOrMember", nm0);
                try b.push(.{ .CallValueOrMember = .{
                    .dst = d0,
                    .callee = cv,
                    .this_recv = this_reg,
                    .name = nmc,
                    .args = run0[0],
                    .n_args = run0[1],
                    .arg_names = an0,
                } });
                return d0;
            }
        }
    }
    return null;
}


/// A receiver-function-typed property invoked bare takes the innermost implicit
/// receiver in scope, exactly as Kotlin binds it; otherwise the closure body
/// runs receiverless and its member calls fall to globals.
fn tryReceiverFnProperty(g: *GenCtx) Allocator.Error!?Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;

    var core = callee;
    var hops: usize = 0;
    while (hops < 8) : (hops += 1) {
        switch (core.*) {
            .Unary => |u| core = u.expr,
            .Postfix => |pf| core = pf.expr,
            else => break,
        }
    }
    if (core.* != .Path or core.Path.segments.len != 1) return null;
    const pname = core.Path.segments[0].name;
    if (b.resolve(pname) != null or b.knowsOuter(pname)) return null;
    const this_reg = b.resolve("this") orelse return null;
    var owner: ?[]const u8 = b.ownerClass();
    var ohops: usize = 0;
    const is_recv_fn = blk: {
        while (owner) |o| : (ohops += 1) {
            if (ohops > 32) break;
            if (b.module.registry.recv_fn_props.get(.{ .a = o, .b = pname }) != null) break :blk true;
            owner = b.module.registry.enclosing_class.get(o);
        }
        break :blk false;
    };
    if (!is_recv_fn) return null;
    const callee_r = try lowerExpr(b, callee);
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    try b.push(.{ .CallValueWithThis = .{
        .dst = dst,
        .callee = callee_r,
        .receiver = this_reg,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
    } });
    return dst;
}

/// Nothing above bound the call, so invoke the lowered callee value.
fn emitPlainValueCall(g: *GenCtx) Allocator.Error!Reg {
    const b = g.b;
    const callee = g.callee;
    const args = g.args;
    const ast_arg_names = g.ast_arg_names;
    const call = g.expr.Call;

    const callee_r = try lowerExpr(b, callee);
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    // Carry explicit call-site type arguments so an intrinsic container creator
    // stamps and coerces its element type.
    const type_args = try helpers.internTypeArgsScoped(b, call.type_args);
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


/// True when a bodied same-name function already accepts this call's arity.
pub fn aFuncFits(b: *FuncBuilder, nm: []const u8, want: usize) bool {
    for (b.module.funcsBySimpleName(nm)) |fid| {
        const mf = b.module.funcById(fid) orelse continue;
        if (!mf.hasBody()) continue;
        const has_this = mf.params.len != 0 and std.mem.eql(u8, mf.params[0].name, "this");
        const base: usize = if (has_this) 1 else 0;
        const user = mf.params.len - base;
        if (user == want) return true;
        if (want < user) {
            var all_optional = true;
            for (mf.params[base + want ..]) |p| {
                if (p.default == null and !p.is_vararg) {
                    all_optional = false;
                    break;
                }
            }
            if (all_optional) return true;
        }
        if (want > user and mf.params.len != 0 and mf.params[mf.params.len - 1].is_vararg) return true;
    }
    return false;
}

/// Whether any bare-call candidate for `nm` visible from `file` is a member
/// extension declared in `chain_head`'s class or a supertype of it.
fn mextCandidateOwnedBy(b: *FuncBuilder, nm: []const u8, chain_head: []const u8, file: ir.FileId) Allocator.Error!bool {
    const head = stripLowerFileMangle(typeHead(std.mem.trimEnd(u8, chain_head, "?")));
    if (head.len == 0) return false;
    const cands = try b.module.bareCallCandidates(b.allocator, nm, file);
    defer b.allocator.free(cands);
    for (cands) |fid| {
        const owner_fqn = b.module.registry.member_ext_owner_class.get(fid) orelse continue;
        const owner_simple = stripLowerFileMangle(simpleTail(owner_fqn));
        if (std.mem.eql(u8, owner_simple, head)) return true;
        if (b.module.classIsOrExtends(head, owner_simple)) return true;
    }
    return false;
}

pub fn narrowingRecvChain(b: *FuncBuilder) Allocator.Error!?[]const []const u8 {
    const cur = b.recvTy() orelse b.ownerClass() orelse return null;
    return try recvChainOf(b, cur);
}

/// Receiver evidence for a bare call inside an inline body. The inline extension's
/// receiver is the active lexical receiver while its own body lowers; a spliced
/// lambda argument restores the caller's receiver tower.
pub fn inlineBodyRecvHead(b: *const FuncBuilder) ?[]const u8 {
    if (b.lambda_splice_resolve == null) {
        if (b.spliceRecvTy()) |receiver| return receiver;
    } else if (inline_call.rfsEnabled() and b.splice_recv_from_window) {
        // A spliced receiver lambda's window carries its subject's head, without
        // which a reified splice declines and falls to a dynamic call that cannot
        // carry `T`. Only the window-set head qualifies.
        if (b.spliceRecvTy()) |receiver| return receiver;
    }
    return b.recvTy() orelse b.ownerClass();
}

pub fn inlineBodyRecvChain(b: *FuncBuilder) Allocator.Error!?[]const []const u8 {
    const receiver = inlineBodyRecvHead(b) orelse return null;
    return try recvChainOf(b, receiver);
}

/// `cur` followed by its transitive supertype simple names, nearest first, from the
/// hierarchy recorded at build time. A type with no recorded hierarchy yields itself.
pub fn recvChainOf(b: *FuncBuilder, cur: []const u8) Allocator.Error![]const []const u8 {
    const supers: []const []const u8 =
        b.module.registry.class_super_names.get(cur) orelse &.{};
    const chain = try b.allocator.alloc([]const u8, supers.len + 1);
    chain[0] = cur;
    @memcpy(chain[1..], supers);
    return chain;
}

/// Whether inline member fn `f` is declared on the enclosing class or one of its
/// transitive supertypes, so it is reachable as `this.<f>` from a member body.
pub fn inlineOwnerInEnclosingHierarchy(b: *FuncBuilder, enclosing: []const u8, f: *const ast.Function) bool {
    const owner = inline_state.inlineMemberOwner(f) orelse return false;
    return classIsOrExtendsHosted(b, enclosing, owner);
}

/// Whether a member-inline candidate's owner class is on the qualified call
/// receiver's static type chain. Strict: an unprovable receiver type rejects.
pub fn memberOwnerOnReceiverChainStrict(b: *FuncBuilder, receiver: *const Expr, cf: *const ast.Function) Allocator.Error!bool {
    const owner = inline_state.inlineMemberOwner(cf) orelse return false;
    const head = (try inline_call.inferReceiverType(b, receiver)) orelse return false;
    return classIsOrExtendsHosted(b, head, owner);
}

pub fn memberOwnerOnReceiverChain(b: *FuncBuilder, receiver: *const Expr, cf: *const ast.Function) Allocator.Error!bool {
    const owner = inline_state.inlineMemberOwner(cf) orelse return true;
    const head = (try inline_call.inferReceiverType(b, receiver)) orelse return true;
    return classIsOrExtendsHosted(b, head, owner);
}

/// `classIsOrExtends` that also accepts `$Companion`-mangled names on either side
/// by reducing them to their host class, so a bare call inside a companion sees
/// its supertype's companion members.
pub fn classIsOrExtendsHosted(b: *FuncBuilder, sub: []const u8, super: []const u8) bool {
    if (b.module.classIsOrExtends(sub, super)) return true;
    const sub_host = hostClassOfCompanion(sub) orelse sub;
    const super_host = hostClassOfCompanion(super) orelse super;
    if (sub_host.len == sub.len and super_host.len == super.len) return false;
    return b.module.classIsOrExtends(sub_host, super_host);
}

/// The symbol-index scope tier of an inline candidate at a reference site (0
/// named-import to 5 invisible). Unknown metadata ranks as the default-import tier.
fn inlineCandTier(b: *const FuncBuilder, f: *const ast.Function, caller_file: span.FileId) u8 {
    const m = b.module;
    const decl_file = f.name.span.file;
    const decl_pkg = m.packageOfFile(decl_file) orelse return 3;
    const caller_pkg = m.packageOfFile(caller_file) orelse b.self_package;
    var buf: [256]u8 = undefined;
    const fqn = std.fmt.bufPrint(&buf, "{s}.{s}", .{ decl_pkg, f.name.name }) catch return 3;
    return m.scopeTier(fqn, decl_pkg, f.name.name, caller_pkg, caller_file);
}

/// Whether a plain top-level inline fn is visible at `caller_file` under Kotlin
/// scoping: same package, exact or wildcard import, or a default-import package.
pub fn bareInlineVisibleFrom(b: *const FuncBuilder, f: *const ast.Function, caller_file: span.FileId) bool {
    return inlineCandTier(b, f, caller_file) <= 3;
}

/// Re-rank a shape-based plain-inline pick by call-site visibility: the
/// registration-order pick is bake-order-sensitive where Kotlin resolves by scope.
/// Prefer the lowest tier among candidates that fit the call shape; ties keep
/// the incumbent.
pub fn retierPlainInlinePick(
    b: *const FuncBuilder,
    pick: *const ast.Function,
    nm: []const u8,
    shape: CallShape,
    caller_file: span.FileId,
) *const ast.Function {
    if (pick.receiver_type != null or inline_state.inlineMemberOwner(pick) != null) return pick;
    const cands = inline_state.candidatesForName(nm) orelse return pick;
    if (cands.len < 2) return pick;
    var best = pick;
    var best_tier = inlineCandTier(b, pick, caller_file);
    for (cands) |cf| {
        if (cf == pick) continue;
        if (cf.receiver_type != null or inline_state.inlineMemberOwner(cf) != null) continue;
        if (shape.last_is_lambda) {
            if (cf.params.len == 0) continue;
            const lp = &cf.params[cf.params.len - 1];
            if (lp.ty.function == null) continue;
            if (cf.params.len != shape.want) continue;
        } else if (cf.params.len != shape.want) {
            continue;
        }
        const t = inlineCandTier(b, cf, caller_file);
        if (t < best_tier) {
            best_tier = t;
            best = cf;
        }
    }
    return best;
}

/// Whether an implicit receiver in the caller's context declares a member named
/// `nm` taking `argc` args, bodyless (`registry.abstract_member_arity`) or concrete
/// (`member_method_fids`), over the recorded supertype chains. Kotlin ranks such a
/// member above any extension, so an inline-extension splice yields to it.
pub fn receiverMemberTakesCall(b: *FuncBuilder, evid_chain: ?[]const []const u8, nm: []const u8, argc: usize) bool {
    var heads_buf: [12][]const u8 = undefined;
    var n: usize = 0;
    if (b.recvTy()) |h| {
        heads_buf[n] = h;
        n += 1;
    }
    if (b.ownerClass()) |h| {
        if (n < heads_buf.len) {
            heads_buf[n] = h;
            n += 1;
        }
    }
    if (evid_chain) |chain| for (chain) |h| {
        if (n < heads_buf.len) {
            heads_buf[n] = h;
            n += 1;
        }
    };
    const bit: u64 = @as(u64, 1) << @intCast(@min(argc, 63));
    var stack_buf: [48][]const u8 = undefined;
    var stack_len: usize = 0;
    for (heads_buf[0..n]) |h| {
        if (stack_len < stack_buf.len) {
            stack_buf[stack_len] = h;
            stack_len += 1;
        }
    }
    var seen_buf: [48][]const u8 = undefined;
    var seen_len: usize = 0;
    while (stack_len > 0) {
        stack_len -= 1;
        const cur = stack_buf[stack_len];
        var dup = false;
        for (seen_buf[0..seen_len]) |sn| {
            if (std.mem.eql(u8, sn, cur)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_len < seen_buf.len) {
            seen_buf[seen_len] = cur;
            seen_len += 1;
        }
        // Bodyless slots only: a concrete member is already ranked by the existing
        // ladders, and the abstract record is the information they lack.
        if (b.module.registry.abstract_member_arity.get(.{ .a = cur, .b = nm })) |mask| {
            if (runtime.envOnce("KLIO_INLINE_PICK")) |w| {
                if (std.mem.eql(u8, w, nm)) std.debug.print("[rmtc] {s} on {s} mask={x} argc={d}\n", .{ nm, cur, mask, argc });
            }
            if (mask & bit != 0) return true;
        }
        const supers: []const []const u8 = b.module.registry.class_super_names.get(cur) orelse &.{};
        for (supers) |sup| {
            if (stack_len < stack_buf.len) {
                stack_buf[stack_len] = sup;
                stack_len += 1;
            }
        }
    }
    return false;
}

/// Whether the module declares a same-named non-inline extension whose receiver
/// head appears in `chain`. Declines an inline splice that picked a receiverless
/// candidate while a receiver is in scope; the inline candidate set cannot hold
/// the extension, so the decline must come from outside it.
pub fn nonInlineExtensionFits(b: *FuncBuilder, name: []const u8, chain: []const []const u8, file: ir.FileId) bool {
    // An import alias means the call site's name is not the declared one.
    var lookup = name;
    if (b.module.importAliasIn(file, name)) |segs| {
        if (segs.len != 0) lookup = segs[segs.len - 1];
    }
    for (b.module.funcsBySimpleName(lookup)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        var rh = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
        if (std.mem.findScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
        const rhead = typeHead(rh);
        for (chain) |c| {
            var ch = std.mem.trimEnd(u8, c, "?");
            if (std.mem.findScalar(u8, ch, '<')) |lt| ch = ch[0..lt];
            if (std.mem.eql(u8, rhead, typeHead(ch))) return true;
        }
    }
    return false;
}

/// Publish a call's explicit type arguments under the callee's reified
/// type-parameter names, for a call that could not be spliced; without it the body
/// reads a stale binding. Only reified parameters of a candidate with this name
/// are written, each name once.
pub fn storeExplicitReifiedGlobals(b: *FuncBuilder, name: []const u8, type_args: []const ast.TypeRef) Allocator.Error!void {
    if (type_args.len == 0) return;
    const cands = inline_state.candidatesForName(name) orelse return;
    var written: std.ArrayList([]const u8) = .empty;
    defer written.deinit(b.allocator);
    for (cands) |cf| {
        for (cf.type_params, 0..) |tp, i| {
            if (!tp.is_reified or i >= type_args.len) continue;
            var dup = false;
            for (written.items) |w| {
                if (std.mem.eql(u8, w, tp.name.name)) dup = true;
            }
            if (dup) continue;
            const arg = &type_args[i];
            if (arg.function != null) continue;
            const resolved = scopeTypeRename(b, arg.name.name, arg.name.span.file.int()) orelse arg.name.name;
            const cls_reg = b.allocReg();
            const arg_name = try b.module.internConst(b.allocator, .{ .String = resolved });
            const cls_pick: ?ir.ClassId = b.module.classIdIndexed(resolved, b.self_package, arg.name.span.file) orelse
                b.module.classId(resolved);
            try b.push(.{ .LoadGlobal = .{ .dst = cls_reg, .name = arg_name, .class = cls_pick, .ctor_ref = true } });
            const tp_global = try b.module.internConst(b.allocator, .{ .String = tp.name.name });
            try b.push(.{ .StoreGlobal = .{ .name = tp_global, .value = cls_reg } });
            try written.append(b.allocator, tp.name.name);
        }
    }
}

/// Heads whose values a `vararg` sibling's single argument can never be.
fn containerParamHead(name: []const u8) bool {
    const heads = [_][]const u8{
        "Iterable", "Collection", "List", "MutableList", "Set", "MutableSet",
        "Sequence", "Array",
    };
    for (heads) |h| if (std.mem.eql(u8, name, h)) return true;
    return false;
}

/// The same-named inline sibling declaring its first parameter `vararg`, when
/// `picked` declares it as a container the first argument's static type is not.
pub fn varargSiblingForContainerMismatch(
    b: *FuncBuilder,
    nm: []const u8,
    picked: *const ast.Function,
    args: []const Expr,
) Allocator.Error!?*const ast.Function {
    if (args.len == 0) return null;
    if (picked.params.len == 0) return null;
    const p0 = &picked.params[0];
    if (p0.is_vararg) return null;
    if (!containerParamHead(typeHead(p0.ty.name.name))) return null;

    var arg_ty = (staticExprTypeRef(b, &args[0]) catch null) orelse return null;
    defer arg_ty.deinit(b.allocator);
    const arg_head = typeHead(std.mem.trimEnd(u8, arg_ty.name, "?"));
    if (arg_head.len == 0) return null;
    if (containerParamHead(arg_head)) return null;
    // A class that really does implement the container is no mismatch.
    if (b.module.uniqueClassIdBySimpleName(arg_head)) |acid| {
        if (b.module.uniqueClassIdBySimpleName(typeHead(p0.ty.name.name))) |pcid| {
            if (b.module.classIdIsOrExtends(acid, pcid)) return null;
        }
    }

    const cands = inline_state.candidatesForName(nm) orelse return null;
    for (cands) |c| {
        if (c == picked) continue;
        if (c.params.len != picked.params.len) continue;
        if (c.params.len == 0 or !c.params[0].is_vararg) continue;
        if (c.receiver_type != null) continue;
        return c;
    }
    return null;
}
