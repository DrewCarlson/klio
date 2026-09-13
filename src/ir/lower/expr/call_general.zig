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

pub fn lowerCallGeneral(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call_tail = b.call_tail;
    b.call_tail = false;
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const is_infix = call.is_infix;

    // A bare ctor callee naming a nested class must bind the one in THIS
    // enclosing-class chain, not a same-simple-name nested class in a sibling
    // outer class. Walk the owner's FQN, and for each prefix that is itself a
    // CLASS (never a package — so a same-package top-level is left alone),
    // check for a nested `<prefix>.<name>`. Only rewrite when it differs from
    // the bare resolution (a genuine collision), to the qualified path.
    if (!is_infix and ast_type_args.len == 0 and callee.* == .Path and
        callee.Path.segments.len == 1 and b.resolve(callee.Path.segments[0].name) == null)
    {
        const cname = callee.Path.segments[0].name;
        if (b.ownerClass()) |owner| resolve: {
            const ocid = b.module.classId(owner) orelse break :resolve;
            if (ocid.int() >= b.module.classes.items.len) break :resolve;
            const bare = b.module.classIdIndexed(cname, b.self_package, callee.Path.segments[0].span.file);
            var prefix: []const u8 = b.module.classes.items[ocid.int()].fqn;
            while (std.mem.lastIndexOfScalar(u8, prefix, '.')) |dot| {
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
                    return lowerCallGeneral(b, &rewritten);
                }
                b.allocator.free(cand);
            }
        }
    }

    // `this.onError(index)` — an inline lambda PARAMETER with a receiver type
    // (`String.(Int) -> Nothing`) invoked through an explicit `this`. The
    // qualifier names the lambda's receiver, not a member of it, so this is
    // the same splice the bare form takes; without the arm the call emitted
    // a member dispatch that no class declares.
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

    // `flow.emit(1)` — an inline lambda PARAMETER with a RECEIVER-typed
    // function type (`T.(Int) -> Unit`) invoked with an explicit receiver
    // expression. Kotlin's invoke convention resolves the local parameter
    // over the receiver's same-named MEMBER (the local scope is nearer), so
    // the call splices the lambda with the qualifier as its receiver —
    // SharedFlowTest's testSubscriptionByFirstSuspensionInCollect calls
    // `flow.emit(1)` where `emit: T.(Int) -> Unit` must shadow
    // MutableStateFlow's own `emit`. Receiver-typed params only: a plain
    // `(Int) -> Unit` param is inapplicable to a qualified call and the
    // member keeps it.
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

    // Inline expansion (suspend-inline only).
    if (try tryBareInlineExpansion(b, expr)) |r| {
        return r;
    }

    // `collector.block()` — an EXPLICIT receiver invoking the enclosing
    // class's RECEIVER-function-typed property (`SafeFlow.block: suspend
    // FlowCollector.() -> Unit`): Kotlin runs the stored callable with the
    // explicit value as its receiver. Without this arm the call dispatched
    // as a member of the receiver and missed (`invoke` on NopCollector).
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

    // Inside an inline-extension splice, a bare call to a member of the
    // spliced extension's bound receiver (`receiveNullable(...)` inside a
    // spliced `ApplicationCall.receive`) is `this.member(...)` on that
    // receiver. Resolve it here, before the bare-name paths below treat the
    // member as a top-level function (which would lose the receiver). The
    // bound `this` is a local register (the splice's receiver binding), not a
    // captured frame slot, so dispatch it as an explicit `CallMember`.
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1 and
        b.currentInlineFn() != null)
    {
        const nm = callee.Path.segments[0].name;
        // Only route to the spliced receiver when the bare name is a member
        // of it or names an extension whose declared receiver type is
        // compatible with the spliced receiver's type chain. A bare call
        // whose only extension namesakes target unrelated types (`maxOf(a,
        // b)` inside `Buffer.indexOf`, whose extension overloads are
        // `Iterable.maxOf` / array `maxOf`) is the package-level function,
        // not a receiver member — it must fall through to the bare-name path.
        var recv_chain = try narrowingRecvChain(b);
        // Inside an inline splice the ACTIVE receiver is the splice's — for
        // `Greeter().apply { greet() }` the substituted concrete head — and
        // the enclosing function's own receiver context says nothing about
        // it. Without this, the receiver's member could not shadow a
        // same-named top-level function.
        if (recv_chain == null) {
            if (b.spliceRecvTy()) |sr| recv_chain = try recvChainOf(b, sr);
        } else if (b.lambda_splice_resolve != null and inline_call.rfsEnabled()) {
            // A spliced receiver LAMBDA is the innermost implicit receiver,
            // AHEAD of the enclosing (framed) receiver the narrowing chain
            // starts from: `with(operation) { executeWithComposeStackTrace(...) }`
            // inside a framed `OpIterator.()` block resolves the bare call
            // against the with-subject first, exactly as kotlinc scopes it.
            if (b.spliceRecvTy()) |sr| {
                var sh = typeHead(std.mem.trimEnd(u8, sr, "?"));
                // The registry keys carry file-collision mangles
                // (`Operation$f429`); resolve the source-spelled head
                // through the class index scoped at this reference site.
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
        // A captured crossinline param shadows a same-named member of the
        // anonymous object being lowered (`object : Iterable<T> { override fun
        // iterator() = iterator() }` — the bare `iterator()` is the captured
        // lambda, not the override, which would recurse). Let it fall through
        // to the anon-capture invocation below.
        if (b.resolve(nm) == null and !b.knowsOuter(nm) and !isLowerAnonCapture(nm) and
            !nameHasReifiedInlineCandidate(nm))
        {
            // Confident the call binds to the spliced `this`: the name is a
            // member of its class, or an extension whose declared receiver is
            // compatible with the *known* receiver-type chain. Dispatch it
            // straight onto the bound receiver register.
            // A NESTED CLASS's name sits in the own-member set but a
            // capitalized bare call to it is a CONSTRUCTOR, never a
            // method on `this` — leave it to the ctor resolution.
            const is_scoped_class = nm.len > 0 and std.ascii.isUpper(nm[0]) and
                (scopedClassIdForRead(b, nm, callee.Path.segments[0].span.file) != null or
                    b.module.classId(nm) != null or anyClassNamed(b, nm));
            // A DECLARED MEMBER of the spliced receiver's own hierarchy
            // (`fetchStreamingResponse()` inside a spliced member-inline
            // `HttpStatement.body`) binds the receiver the same way an
            // extension namesake does — the hierarchy shadow set answers
            // membership even when the member is internal.
            const member_of_recv = blk: {
                const chain = recv_chain orelse break :blk false;
                if (chain.len == 0) break :blk false;
                const hs = b.module.registry.hierarchy_shadow_names.get(chain[0]) orelse {
                    // An image-loaded class carries no per-build shadow
                    // entry; the function index still proves member-EXT
                    // membership (`executeWithComposeStackTrace` inside
                    // `with(operation) { ... }` is Operation's member
                    // extension in the pack).
                    if (!inline_call.rfsEnabled()) break :blk false;
                    break :blk mextCandidateOwnedBy(b, nm, chain[0], callee.Path.segments[0].span.file) catch false;
                };
                if (!hs.complete) break :blk false;
                break :blk hs.names.contains(nm);
            };
            // An extension NAMESAKE on the receiver chain does not pin the
            // walk: the static bare-extension resolution below ranks the
            // overload set with argument evidence (`plus(element)` inside a
            // spliced `plusElement` must pick the `element: T` overload; the
            // walk's member-first runtime pick took the Iterable one), and
            // its own deferral remains the fallback when the shapes cannot
            // prove a pick.
            var binds_this = !is_scoped_class and (b.hasOwnMember(nm) or member_of_recv);
            // Under the subject tower, when the name ALSO has an
            // extension candidate whose declared receiver matches the
            // chain, the member-vs-extension arbitration needs argument
            // applicability — static resolution's strength, not the
            // runtime walk's (`putAll(pairs)` must drop the member
            // `putAll(Map)` for the Iterable-pairs extension). Fall
            // through to the static tiers; the commit-point parity guard
            // still defers plain top-level picks.
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
            if (binds_this) {
                // Pinning the dispatch to the innermost bound `this` is only
                // sound when the receiver evidence proves that value serves
                // the member (`member_of_recv`, an extension on the proven
                // chain). The `hasOwnMember` leg names a member of the
                // lexically enclosing CLASS — inside a receiver lambda whose
                // receiver does not own the member (a `(Long) -> R` frame
                // callback created in a `CoroutineScope.()` block, calling a
                // Recomposer private), the bound `this` is the scope receiver
                // and the owner sits further out; a lazily lowered pack body
                // has no receiver-type context to tell the cases apart. Emit
                // the receiver-walking form for that leg: the walk tries the
                // bound receiver's members first (identical to the pin when
                // `this` IS the owner), then each enclosing receiver.
                if (b.resolve("this")) |bound_this| {
                    // The PROVEN leg resolves statically: the chain's head
                    // class declares the member, so the call binds its
                    // virtual slot instead of walking per invocation
                    // (`propertyEquals { ... }` inside a spliced
                    // `(object {}).let` ran the walk 200 times per suite).
                    // Sound only when NO enclosing receiver could shadow:
                    // the chain must be exactly the bound receiver. With
                    // outer receivers in scope the walking form arbitrates
                    // (the atomicfu mutex splice livelocked when pinned).
                    if (member_of_recv and ast_type_args.len == 0 and
                        recv_chain.?.len == 1 and
                        // Under the subject tower the bound `this` is the
                        // spliced SUBJECT; a pin resolved against a lexical
                        // owner would dispatch that owner's member ON the
                        // subject (CallVirtual Holder.eachInline on the
                        // StringBuilder). The walking form ranks receivers
                        // correctly there.
                        b.encl_tower_depth == 0 and
                        runtime.envOnce("KLIO_SPLICE_PIN") == null and
                        allNull(ast_arg_names)) pin: {
                        const chain0 = recv_chain.?[0];
                        // The pin dispatches on the BOUND `this`, so the
                        // chain's head must be that same value. Inside a
                        // receiver lambda over another type the two diverge —
                        // the chain names the enclosing class that owns the
                        // member while `this` is the lambda's receiver — and
                        // pinning then dispatched the owner's member on the
                        // lambda receiver (`eachInline` on
                        // kotlin.text.StringBuilder inside `with(sb) { … }`),
                        // blocking the outward walk a non-inline sibling uses.
                        if (b.recvTy() orelse b.spliceRecvTy()) |inner| {
                            const ih = typeHead(std.mem.trimEnd(u8, inner, "?"));
                            const ch = typeHead(std.mem.trimEnd(u8, chain0, "?"));
                            if (!std.mem.eql(u8, ih, ch) and
                                !std.mem.eql(u8, simpleTail(ih), simpleTail(ch))) break :pin;
                        }
                        const pin_cid = (if (std.mem.indexOfScalar(u8, chain0, '.') != null)
                            b.module.classIdByFqn(chain0)
                        else
                            b.module.uniqueClassIdBySimpleName(chain0)) orelse break :pin;
                        var shape_set = try buildStaticReturnArgShapes(b, args, ast_arg_names);
                        defer shape_set.deinit(b.allocator);
                        const pin_recv_ref: ir.TypeRef = .{ .name = chain0, .nullable = false, .args = &.{} };
                        const resolved = b.module.resolveMemberCall(pin_cid, nm, shape_set.shapes, .{
                            .caller_file = callee.Path.segments[0].span.file,
                            .lexical_owner = null,
                            .actual_type_param_bounds = &.{},
                            .receiver_type = pin_recv_ref,
                        });
                        const target = resolved.target orelse break :pin;
                        const tf = b.module.funcById(target) orelse break :pin;
                        if (!tf.hasBody()) break :pin;
                        // A FUNCTION-SPELLED parameter fed a non-lambda
                        // argument is exactly the member-vs-extension shape
                        // the static shapes cannot always refute (the arg's
                        // static type may be unknowable through the splice
                        // substitution): `url(urlString)` must not pin the
                        // member `url(block)`. Fall to the walking form,
                        // whose runtime adjudication sees the value.
                        for (tf.params, 0..) |*tp, tpi| {
                            if (tpi == 0 and std.mem.eql(u8, tp.name, "this")) continue;
                            const ai = tpi - @intFromBool(tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this"));
                            if (ai >= args.len) break;
                            if (recvHeadIsFunctionType(tp.ty.name) and
                                args[ai] != .Lambda and args[ai] != .AnonFun) break :pin;
                        }
                        // A member in a stdlib/pack package may be shadowed
                        // by a HOST binding the lowering cannot see
                        // (atomicfu's ReentrantLock.unlock stub deadlocked
                        // when its interpreted body was pinned). Pin only
                        // program-owned declarations.
                        const shipped_pkg = std.mem.eql(u8, tf.package, "kotlin") or
                            std.mem.startsWith(u8, tf.package, "kotlin.") or
                            std.mem.startsWith(u8, tf.package, "kotlinx.") or
                            std.mem.startsWith(u8, tf.package, "androidx.") or
                            std.mem.startsWith(u8, tf.package, "io.ktor");
                        if (shipped_pkg) break :pin;
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
                        // With the runtime subject tower live, the chain
                        // already holds every nested subject in scope order;
                        // pinning one bound register would put it AHEAD of an
                        // inner subject and invert Kotlin's innermost-first
                        // receiver ranking.
                        .recv = if (b.encl_tower_depth > 0) null else bound_this,
                        .candidates = try cmgCandidates(b, nm, callee.Path.segments[0].span.file, run[1]),
                        // Under the subject tower the runtime chain ranks the
                        // receivers; a static head would pin the strict-ext
                        // arm to the SUBJECT and raise where the walk should
                        // fall outward (`eachInline` in `with(sb) { ... }` is
                        // the enclosing Holder's member-inline).
                        .static_recv = if (b.encl_tower_depth > 0) null else try cmgStaticRecv(b),
                    } });
                    return dst;
                }
            } else if (recv_chain == null and nameHasReceiverCandidate(b, nm, null)) {
                // The name is an extension namesake but the spliced receiver's
                // type is unknown here, so we cannot prove it binds to the
                // innermost `this`. Emit the receiver-walking form rather than
                // pinning it to `this`: a bare `collect` inside a nested
                // `FlowCollector.()` lambda must reach the outer `Flow`
                // receiver (`this@unsafeTransform`), not dispatch on the
                // collector. `CallMemberOrGlobal` tries the bound receiver,
                // then each enclosing receiver innermost-first, before any
                // global. Pass the bound `this` register directly so the splice
                // receiver (`filterIsInstanceTo` on the bound `List`) is the
                // innermost candidate even though it is a local register, not a
                // capture. Still handled here so the bare-name paths below
                // cannot grab it as a top-level function and drop the receiver.
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
                        // receivers; a static head would pin the strict-ext
                        // arm to the SUBJECT and raise where the walk should
                        // fall outward (`eachInline` in `with(sb) { ... }` is
                        // the enclosing Holder's member-inline).
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
            }
        }
    }

    // Bare call to a name the enclosing anon object closes over.
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
        // Inside a receiver splice the captured name may shadow a MEMBER
        // of the spliced receiver (`lock()` in withLock's body vs the
        // caller's captured `val lock`): Kotlin resolves the body's bare
        // call to the receiver member, and the capture is usually not
        // even callable — emit the runtime-arbitrated form.
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

    // Infix call `a fn b` → `a.fn(b)`.
    if (is_infix and args.len == 2 and callee.* == .Path and callee.Path.segments.len == 1) {
        // An infix call IS `a.f(b)`: route it through the member lowering
        // so it binds statically like the written-out form. The plain
        // CallMember emitted here left every infix extension walking by
        // name (`0 until times` inside `repeat`'s body, once per run).
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

    // `suspend { … }` builder: the value is the lambda itself, with its
    // body marked suspend so dispatch can distinguish it from a plain
    // function value.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "suspend") and
        args.len == 1 and args[0] == .Lambda)
    {
        b.pending_suspend_lambda = true;
        return lowerExpr(b, &args[0]);
    }
    // `contract { … }` — compile-time marker with no runtime effect.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "contract") and
        args.len == 1 and args[0] == .Lambda)
    {
        return b.emitConst(.Unit);
    }
    // Self-call inside a tailrec fn → TailJump terminator. The jump
    // re-binds the function's parameters in place; an instance/extension
    // tailrec function carries its receiver as the leading implicit
    // param, and a bare recursive call keeps the same receiver, so the
    // arg run must lead with `this` — dropping it would shift every
    // re-bound parameter by one.
    // The self-call may name its receiver: `1.foo(x - 1)` on an extension,
    // `this foo x` as an infix call, `this@label.foo(…)`, or an object
    // dispatcher `O.rec(…)`. The receiver expression is the re-bound
    // leading `this` parameter.
    if (call_tail and callee.* == .Member and !callee.Member.safe and b.tailrecSelfHasThis() and
        tailrecReceiverIsSelf(b, callee.Member.receiver))
    {
        if (b.tailrecSelf()) |ts| {
            if (std.mem.eql(u8, ts, callee.Member.name.name)) {
                if (try emitTailJumpRun(b, callee.Member.receiver, args, expr.Call.arg_names)) |run| {
                    b.terminate(.{ .TailJump = .{ .args = run[0], .n_args = @intCast(run[1].int()) } });
                    const dead = try b.allocBlock();
                    b.switchTo(dead);
                    return b.emitConst(.Unit);
                }
            }
        }
    }
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
                const run = (try emitTailJumpRun(b, recv, args, expr.Call.arg_names)) orelse return lowerCallGeneralNoJump(b, expr);
                b.terminate(.{ .TailJump = .{ .args = run[0], .n_args = @intCast(run[1].int()) } });
                const dead = try b.allocBlock();
                b.switchTo(dead);
                return b.emitConst(.Unit);
            }
        }
    }

    // A ctor-property param shadowing a same-named vararg method must dispatch
    // by argument shape: a field initializer `val data = createFrom("a", "b")`
    // has the param in scope as a local, but the call belongs to the vararg
    // method, not the property lambda invoked with two arguments. Route to
    // member dispatch so `varargShadowedFieldInvoke` makes the pick.
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

    // A `name<T>(…)` call whose name resolves to a value parameter/local that
    // is not a local function names the SHADOWED global function/builder: a
    // value takes no call-site type arguments. `iterator<List<T>> { … }` inside
    // `windowedIterator(iterator: Iterator<T>, …)` binds the `iterator {}`
    // builder, not the `iterator` parameter. Load the global so the runtime
    // resolves the intrinsic builder rather than invoking the parameter.
    // Likewise a `name(…)` call whose name resolves to a value whose
    // DECLARED type cannot be invoked (`var globalFun: Int = globalFun()`
    // in a primary constructor: the parameter is an `Int`, the call is the
    // top-level function): a value of a primitive/String type, or of a
    // class with no `invoke` member, is never a callee.
    if (callee.* == .Path and callee.Path.segments.len == 1 and ast_type_args.len == 0) {
        const nm0 = callee.Path.segments[0].name;
        // A member FUNCTION of the enclosing class chain still takes the
        // call when a plain value shadows the name (`AbstractCoroutine`'s
        // `if (initParentJob) initParentJob(parent)`: the Boolean property
        // and the inherited `JobSupport.initParentJob(Job?)`).
        var chain_buf: [8]FuncId = undefined;
        const chain_fns = try enclosingChainMethodsNamed(b, nm0, callee.Path.segments[0].span.file, &chain_buf);
        if (b.resolve(nm0) != null and !b.isLocalFn(nm0) and !b.isLocalExtFn(nm0) and
            b.module.classIdIndexed(nm0, b.self_package, callee.Path.segments[0].span.file) == null and
            chain_fns.len == 0 and
            // Only redirect to a global when a global function/builder of this
            // name actually exists to receive the call. Without this guard a
            // local whose DECLARED type reads as non-invokable — a receiver
            // lambda's value parameter mis-typed as its own receiver class
            // (`{ block -> block(7) }` bound to `Cls.((Int) -> Unit) -> Unit`,
            // where the receiver leaks into `block`'s type) — emitted a
            // `LoadGlobal` for a name no global carries and failed at runtime
            // with "unresolved global". The local IS the callee: fall through
            // to the value-invocation path.
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

    // A single-name callee resolving to a local binding / parameter is a
    // value invocation.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        // Same-named local-fn siblings are OVERLOADS: when the call's
        // static facts (arity, argument names, literal/declared type
        // heads) select exactly one, call through its mangled cell —
        // reachable both in the declaring scope and as a capture. Calls
        // no fact separates keep the plain last-decl binding below.
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
        // SELF-reference: a bare call to the enclosing local fn's own name
        // from inside its body — including generated nested lambdas (the
        // compose restart re-invoke) — binds the fn ITSELF through its
        // mangled cell. The plain name cannot serve it: a later same-named
        // sibling declaration rebinds the shared plain-name slot (last bind
        // wins), and Kotlin scopes this call to the declarations visible at
        // this point in the body — the enclosing fn, never the sibling.
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
            // A LONE local fn reached from a NESTED body (its own body, or
            // a local fn declared inside it): the mangled overload cell
            // binds BEFORE the body lowers exactly so nested calls can
            // capture it. Route the call through the cell (`fun traverse`
            // inside GapComposer's `movableContentReferenceFor` recursing
            // into its encloser). The PLAIN name cannot serve even when it
            // IS a visible outer binding: a later same-named sibling
            // declaration (a validator extension beside the composable)
            // rebinds the shared plain-name slot, so a by-name capture
            // runs the sibling. Multi-overload sets select above; an
            // inapplicable local keeps outward resolution.
            // The plain name may also be bound to a same-named local
            // PROPERTY (`var seen = ...; fun seen(x)`): the property owns
            // the bare binding, so a CALL routes through the fn's mangled
            // cell — Kotlin resolves `seen(x)` to the fun and `seen` to
            // the var.
            const plain_is_property = b.resolve(bare) != null and !b.isLocalFn(bare);
            if (decls.len == 1 and !local_fn_inapplicable and
                (b.resolve(bare) == null or plain_is_property) and
                (b.resolve(decls[0].mangled) != null or b.knowsOuter(decls[0].mangled)))
            {
                if (try lowerSelectedLocalOverloadCall(b, bare, decls[0].mangled, args, ast_arg_names)) |r| return r;
            }
        }
        // A local function shadows an outer one by NAME, but only among
        // candidates that can take the call. A local `fun validate()` does
        // not hide the top-level `validate(block: () -> Unit)` from
        // `validate { … }`; invoking the local as a value made it call
        // itself for ever. With no applicable local, resolution continues
        // outward to the top-level / member candidates below.
        if (!local_fn_inapplicable) {
            if (try lowerValueInvocation(b, callee, args, ast_arg_names)) |r| return r;
            // A LONE applicable local fn reached as a CAPTURE (declared in
            // an enclosing body, called from this closure): invoke the
            // captured closure value. Without this the call fell through to
            // the classifier arms, and a local `fun Test(a, b)` lost to an
            // imported `kotlin.test.Test` inside `r.go { Test(1, 2) }`.
            // Two or more siblings select through the mangled binding above.
            // Gated on an actual classifier collision: a captured local fn
            // with NO same-named class keeps its established route (its
            // value binding is not always capturable — a `fun emit` inside
            // a runtime-lowered lambda resolves through the scoped-global
            // layers, not a capture slot).
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
    var force_static_class = false;
    // A constructible same-named class competes with the function candidates.
    // Until constructors participate in the shared applicability set, the
    // deferred class-carrying form below compares both declarations on the
    // actual argument types (`Box(s.length)` constructs `Box(Int)`, not the
    // `fun Box(s: String)` factory).
    const class_competes = callee.* == .Path and callee.Path.segments.len == 1 and
        !shadowed_by_class and !callee_is_object and blk: {
        const cid = callee_class_id orelse break :blk false;
        if (cid.int() >= b.module.classes.items.len) break :blk false;
        const cls = &b.module.classes.items[cid.int()];
        // An abstract/interface/sealed class never constructs, so it
        // does not compete with the function candidates.
        if (cls.is_abstract) break :blk false;
        // The class competes when its primary constructor can take this
        // argument count, OR when the count exceeds the primary arity — a
        // secondary constructor (not visible in the IR class, which carries
        // only the primary) may accept it (`ByteString(bytes, 0, n)` binds
        // the `(ByteArray, Int, Int)` secondary, not `fun ByteString(vararg
        // Byte)`). Deferring an over-primary count to runtime is safe: when
        // no constructor actually matches, the runtime falls to the factory.
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

    // Path-callee with a registered top-level fn → Call{func}.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (try lowerPathCall(
            b,
            expr,
            shadowed_by_class,
            class_competes,
            &force_static_class,
        )) |r| return r;
    }

    // A named object is a singleton value, not a constructible class.
    // Once same-named function overloads have had their ordinary call tier,
    // invoke the exact object identity through its operator surface.
    if (callee_is_object) {
        return try emitObjectValueCall(b, args, ast_arg_names, ast_type_args, callee.Path.segments[0].name, callee_class_id.?);
    }

    // A LOCAL class declared in this function (or an enclosing one) shadows
    // any same-simple-name module class for a bare constructor call. Its
    // runtime `.Class` value is bound at the declaration; inside a nested
    // lambda it arrives through the capture set. Route the call through
    // that binding — the module-index class path below would construct an
    // unrelated class (a nested class of another owner) instead.
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

    // Path-callee with a registered class name. The indexed lookup binds
    // the class visible from the caller's package and imports, so a
    // cross-package simple-name collision constructs the right class.
    // A typealias constructs its expansion (`typealias Node = ListNode;
    // Node("a")` is a ListNode constructor call), so an unindexed name
    // retries through the alias registry scoped at this reference site.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const ctor_seg = callee.Path.segments[0];
        const ctor_cid: ?ir.ClassId = b.module.classIdIndexed(ctor_seg.name, b.self_package, ctor_seg.span.file) orelse
            b.module.classIdExactImport(ctor_seg.name, ctor_seg.span.file) orelse blk_alias: {
                const aref = ir.TypeRef{ .name = ctor_seg.name, .nullable = false, .args = &.{} };
                const resolved = try b.module.resolveTypeAliasAt(b.allocator, aref, ctor_seg.span.file, b.self_package);
                const rh = typeHead(std.mem.trimEnd(u8, resolved.name, "?"));
                if (std.mem.eql(u8, rh, ctor_seg.name)) break :blk_alias null;
                break :blk_alias b.module.classIdIndexed(rh, b.self_package, ctor_seg.span.file) orelse
                    b.module.classId(rh);
            };
        // An APPLICABLE own member named like a class in scope (`private fun
        // Json(arrays: Boolean, build: PolymorphicModuleBuilder<Any>.() -> Unit)`
        // beside the library's `Json` class) wins the bare call in Kotlin's
        // scope order: the implicit-this path binds the member's lambda
        // shapes and receivers, where the constructor path below would not.
        if (ctor_cid != null and b.ownerClass() != null and b.resolve("this") != null and
            b.hasOwnMember(ctor_seg.name) and b.ownFunctionApplicable(ctor_seg.name, args.len) and
            !ownMemberRejectsLambdas(b, ctor_seg.name, args))
        {
            if (try lowerImplicitThisCall(b, callee, args, ast_arg_names, call.type_args)) |r| return r;
        }
        if (ctor_cid) |class_id| {
            applyExpectedLiteralKindsToCtorArgs(b, class_id, args, ast_arg_names);
            const ctor_arity = try ctorArgFnArities(b, class_id, args, ast_arg_names);
            defer if (ctor_arity) |ca| b.allocator.free(ca);
            // P12's shape-repair contract for constructor calls: the compose
            // pass shapes a sink lambda with the bare composer pair and the
            // LOWERING repairs it against the resolved parameter's declared
            // arity. Function calls repair in transformSelectedComposableArgs;
            // a class whose primary constructor takes a composable lambda
            // (`MovableContent({ content() })`, arity 1) needs the same
            // repair here, or the content invokes with every slot shifted.
            try transformCtorComposableArgs(b, class_id, args, ast_arg_names);
            const cls = &b.module.classes.items[class_id.int()];
            // A fun-interface conversion types its lambda's params from the
            // interface's single abstract method, instantiated by the
            // explicit type args or the EXPECTED type (`val C:
            // Comparator<String> get() = Comparator { a, b -> ... }` binds
            // T := String, so `a` dispatches statically).
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
            // A ctor's CONCRETE fn-typed params type their lambda arguments
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
                // `Inner()` inside a spliced receiver lambda whose subject is
                // an instance of the inner class's outer (`with(w) { Inner()
                // }`): the subject is the innermost implicit receiver of that
                // type, so it is the new instance's outer, the same member
                // call kotlinc emits for `w.Inner()`.
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
                // A bare `Inner()` uses the enclosing `this` as the new
                // instance's outer. Inside a lambda body that `this` is
                // only reachable through the closure's capture set, so
                // record the capture (kotlinc does the same: the inner
                // ctor's outer argument forces a `this$0` capture).
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
    }

    // Inside a method/extension body: unqualified `name(...)` that didn't
    // match a local / top-level fn / class is a method call on `this`.
    if (callee.* == .Path) {
        if (try lowerImplicitThisCall(
            b,
            callee,
            args,
            ast_arg_names,
            ast_type_args,
        )) |r| return r;
    }

    // Unresolved bare-name call. Reaching here means the resolver above
    // declined to commit a target, so in a receiver context the call must
    // still dispatch member-first even when a same-named top-level function
    // exists in the index (a bare `close(permission)` inside a NodeList
    // member-extension reaches the receiver's inherited member, not a
    // same-named extension elsewhere); a bare-name value load would miss
    // receiver METHODS entirely. Outside a receiver context an indexed name
    // keeps the value-call fallback, which binds the resolved global.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) == null and
        !b.knowsOuter(callee.Path.segments[0].name) and
        b.module.classId(callee.Path.segments[0].name) == null and
        // A collision-mangled class reached only through an explicit import
        // (`import a.Widget` with a same-named `b.Widget`) is registered under
        // its mangled name, so `classId` misses — but it is a real class ctor,
        // not an unresolved bare call.
        b.module.classIdExactImport(callee.Path.segments[0].name, callee.Path.segments[0].span.file) == null and
        (b.module.funcId(callee.Path.segments[0].name) == null or inReceiverContext(b)))
    {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, null)) |r| return r;
    }

    // Built-in stdlib companion shortcuts: `Result.success(x)` etc.
    if (try lowerCompanionShortcut(b, callee, args, ast_arg_names)) |r| return r;

    // Package-qualified constructor call (`app.sub.Widget()`): the dotted
    // callee names a class, so construct it — before the function-FQN and
    // member-fallback paths, which would otherwise read the package head as a
    // field of the implicit receiver (`get_field app on this`).
    // A multi-segment Path callee is the same dotted-FQN shape (the compose
    // pass synthesizes `androidx.compose.runtime.remember(...)` that way);
    // routing it here gives the qualified call the same overload-precise
    // binding the parsed Member form gets, instead of a first-registered
    // global value call.
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

    // The catch-all member / value call.
    if (callee.* == .Member) {
        return lowerMemberCallFallback(b, expr);
    }
    // A bare single-name call that no earlier path resolved, but whose name
    // could be a member of an implicit receiver (a lambda's captured outer
    // `this`), must dispatch member-first — not fall to a bare-name value load
    // that binds a same-named top-level global. Otherwise `error(msg)` inside a
    // `runCatching { }` binds `kotlin.error` instead of the enclosing class's
    // own `error`.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const nm0 = callee.Path.segments[0].name;
        // Only reroute a name that is ACTUALLY an own/enclosing member — not
        // merely "an unknown receiver could have it" — so a top-level helper
        // (`testEquals`) called in a lambda is left on the global path.
        if (b.resolve(nm0) == null and inReceiverContext(b) and b.hasEnclosingMember(nm0)) {
            // A captured local fn is a candidate the runtime member walk
            // cannot see: emit the runtime-arbitrated form. Its value arm
            // falls to the enclosing member when the closure's declared
            // params refute the args (`testEncode(codec, bytes, symbols)`
            // binds the local on String args, the private member on
            // ByteArray).
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
    // A bare call whose name is a bound local / captured outer does not
    // shadow an implicit receiver's member unless the local is actually
    // invokable: `subList = subList(0, 4)` inside `buildList { }` calls
    // the receiver's subList; the captured non-callable `val subList` is
    // not a candidate. Emit the runtime-arbitrated form (value when
    // callable, else the member on `this`) — the same arbitration
    // `redirect_to_member` applies inside a method body.
    if (callee.* == .Path and callee.Path.segments.len == 1 and call.type_args.len == 0) {
        const nm0 = callee.Path.segments[0].name;
        // A RECEIVER-lambda param is Kotlin-unambiguous (the param wins and
        // its receiver binds by declared type): let the ladder reach the
        // RLP arms, which carry the declared head — this arbitration arm
        // seated the syntactic `this` (flowScope's coroutine) and
        // combineInternal's `transform(...)` lost its FlowCollector.
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
    // A RECEIVER-function-typed property invoked bare (`block!!()` where
    // `block: Scope.() -> R` and an implicit receiver is in scope — the
    // cached-draw block invoked directly inside `scope.apply { … }`): the
    // innermost implicit receiver rides the call, exactly as Kotlin binds
    // it. Without this the closure body ran receiverless and its bare
    // member calls fell to globals.
    recv_fn: {
        var core = callee;
        var hops: usize = 0;
        while (hops < 8) : (hops += 1) {
            switch (core.*) {
                .Unary => |u| core = u.expr,
                .Postfix => |pf| core = pf.expr,
                else => break,
            }
        }
        if (core.* != .Path or core.Path.segments.len != 1) break :recv_fn;
        const pname = core.Path.segments[0].name;
        if (b.resolve(pname) != null or b.knowsOuter(pname)) break :recv_fn;
        const this_reg = b.resolve("this") orelse break :recv_fn;
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
        if (!is_recv_fn) break :recv_fn;
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
    const callee_r = try lowerExpr(b, callee);
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    // Carry explicit call-site type arguments so an intrinsic container
    // creator (`listOf<Byte>(…)`) stamps and coerces its element type.
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

/// The receiver type a bare extension call inside this builder's body
/// narrows against — the enclosing extension's declared receiver, or
/// inside a class method (no extension receiver) the enclosing class
/// itself, since `this` is the implicit receiver Kotlin resolves the
/// call's extension on — followed by its transitive supertype names,
/// most-derived first. Null when no receiver is in scope.
/// Whether any bare-call candidate for `nm` visible from `file` is a
/// member EXTENSION declared in (a supertype of) `chain_head`'s class.
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

/// Receiver evidence for a bare call inside an inline body. The inline
/// extension's receiver is the active lexical receiver while its own body is
/// lowered. A spliced lambda argument restores the caller's receiver tower.
pub fn inlineBodyRecvHead(b: *const FuncBuilder) ?[]const u8 {
    if (b.lambda_splice_resolve == null) {
        if (b.spliceRecvTy()) |receiver| return receiver;
    } else if (inline_call.rfsEnabled() and b.splice_recv_from_window) {
        // A spliced receiver LAMBDA's window carries its subject's head
        // (`polymorphic { subclass(ints) }` lowers under
        // PolymorphicModuleBuilder, not the outer serializers-module
        // builder): without it the reified `subclass` splice declined on
        // recv_mismatch and fell to a dynamic call that cannot carry `T`.
        // Only the WINDOW-set head qualifies — a stale enclosing-EXT
        // receiver keeps the hygiene contract (the test pinning
        // MeasurePolicy over List).
        if (b.spliceRecvTy()) |receiver| return receiver;
    }
    return b.recvTy() orelse b.ownerClass();
}

pub fn inlineBodyRecvChain(b: *FuncBuilder) Allocator.Error!?[]const []const u8 {
    const receiver = inlineBodyRecvHead(b) orelse return null;
    return try recvChainOf(b, receiver);
}

/// `cur` followed by its transitive supertype simple names (nearest
/// first), from the hierarchy recorded at build time. A type with no
/// recorded hierarchy (a built-in, a generic parameter) yields just
/// itself.
pub fn recvChainOf(b: *FuncBuilder, cur: []const u8) Allocator.Error![]const []const u8 {
    const supers: []const []const u8 =
        b.module.registry.class_super_names.get(cur) orelse &.{};
    const chain = try b.allocator.alloc([]const u8, supers.len + 1);
    chain[0] = cur;
    @memcpy(chain[1..], supers);
    return chain;
}

/// The inline-fn declaration a bare call may splice, resolved through
/// the symbol index FIRST: a unique top-level winner decides — an
/// inline winner splices its registered AST, a non-inline winner
/// suppresses the splice so the normal call path binds it. The
/// shape/receiver narrowing over the simple-name candidate table
/// survives only as the tie-break for the shapes the index defers on
/// (extension forms, overload sets, default/vararg/trailing-lambda
/// shapes, and bodies lowered before the phase-1 headers exist — class
/// method bodies). Default-import-owned names never splice. The
/// KLIO_RESOLVE_AUDIT `inline` records compare this pick against the
/// simple-name narrowing's per call, a permanent regression detector
/// for the fold (zero unexplained divergences over the corpus).
/// Whether inline member fn `f` is declared on the enclosing class or one of
/// its transitive supertypes — i.e. reachable as `this.<f>` from a member body.
pub fn inlineOwnerInEnclosingHierarchy(b: *FuncBuilder, enclosing: []const u8, f: *const ast.Function) bool {
    const owner = inline_state.inlineMemberOwner(f) orelse return false;
    return classIsOrExtendsHosted(b, enclosing, owner);
}

/// Whether a member-inline candidate's owner class is on the qualified
/// call receiver's static type chain. An unknown receiver type keeps the
/// candidate (the shape-based pick's historical behavior); a KNOWN
/// receiver whose hierarchy does not include the owner rejects it —
/// `resp.body<User>()` on an `HttpResponse` must not splice the
/// unrelated `HttpStatement.body`.
/// Strict form for the monomorphic member-inline splice: an UNPROVABLE
/// receiver type rejects instead of passing — `xs.fold(init) { }` on a
/// List must never splice SnapshotIdSet's same-named member body.
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

/// `classIsOrExtends` that also accepts `$Companion`-mangled names on
/// either side by reducing them to their host class: a bare call inside
/// `ContentType.Companion` is in scope of `HeaderValueWithParameters`'s
/// companion members exactly when `ContentType` extends it.
pub fn classIsOrExtendsHosted(b: *FuncBuilder, sub: []const u8, super: []const u8) bool {
    if (b.module.classIsOrExtends(sub, super)) return true;
    const sub_host = hostClassOfCompanion(sub) orelse sub;
    const super_host = hostClassOfCompanion(super) orelse super;
    if (sub_host.len == sub.len and super_host.len == super.len) return false;
    return b.module.classIsOrExtends(sub_host, super_host);
}

/// The symbol-index scope tier of an inline candidate at a reference
/// site (0 named-import … 5 invisible); unknown metadata ranks as the
/// default-import tier so it neither wins nor loses against real
/// records.
fn inlineCandTier(b: *const FuncBuilder, f: *const ast.Function, caller_file: span.FileId) u8 {
    const m = b.module;
    const decl_file = f.name.span.file;
    const decl_pkg = m.packageOfFile(decl_file) orelse return 3;
    const caller_pkg = m.packageOfFile(caller_file) orelse b.self_package;
    var buf: [256]u8 = undefined;
    const fqn = std.fmt.bufPrint(&buf, "{s}.{s}", .{ decl_pkg, f.name.name }) catch return 3;
    return m.scopeTier(fqn, decl_pkg, f.name.name, caller_pkg, caller_file);
}

/// Whether a plain top-level inline fn is visible at `caller_file` under
/// Kotlin scoping: same package, exact or wildcard import, or a
/// default-import package. Only the invisible tier (an unimported
/// foreign package) is rejected.
pub fn bareInlineVisibleFrom(b: *const FuncBuilder, f: *const ast.Function, caller_file: span.FileId) bool {
    return inlineCandTier(b, f, caller_file) <= 3;
}

/// Re-rank a shape-based plain-inline pick by call-site visibility: with
/// several same-name NON-extension inline candidates across packs (seven
/// `synchronized` actuals in the compose set), the registration-order
/// pick is bake-order-sensitive and can splice another pack's body.
/// Kotlin resolves by scope — prefer the lowest tier among candidates
/// that fit the call shape; ties keep the incumbent.
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

/// Whether an implicit receiver in the caller's context declares a MEMBER
/// named `nm` that can take `argc` args — bodyless
/// (`registry.abstract_member_arity`) or concrete (`member_method_fids`
/// at the exact arity), walked over the recorded supertype name chains.
/// Kotlin ranks such a member above any extension, so an inline-extension
/// splice must yield to it (`respond(message, typeInfo<T>())` inside an
/// `ApplicationCall` extension binds the interface's member, never the
/// reified 2-arg `respond(status, message)` extension).
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
        // Bodyless slots only: a CONCRETE member is already ranked by the
        // existing ladders, and vetoing every concrete-member namesake here
        // was measured too blunt (it broke `execute(context, Unit)` inside
        // the pipeline extension). The abstract record is the information
        // the ladders lack.
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

/// Whether the module declares a same-named NON-inline extension whose
/// receiver head appears in `chain`. Used to decline an inline splice that
/// picked a receiverless candidate while a receiver is in scope: the inline
/// candidate set cannot contain the extension (it is not inline), so the
/// decline has to come from outside that set.
pub fn nonInlineExtensionFits(b: *FuncBuilder, name: []const u8, chain: []const []const u8, file: ir.FileId) bool {
    // `import kotlinx.coroutines.flow.combine as combineOriginal` means the
    // call site's name is not the declared one; look the extension up under
    // what it is actually called. CombineTest imports exactly this way, so
    // without the unaliasing the check found nothing.
    var lookup = name;
    if (b.module.importAliasIn(file, name)) |segs| {
        if (segs.len != 0) lookup = segs[segs.len - 1];
    }
    for (b.module.funcsBySimpleName(lookup)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        var rh = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
        if (std.mem.indexOfScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
        const rhead = typeHead(rh);
        for (chain) |c| {
            var ch = std.mem.trimEnd(u8, c, "?");
            if (std.mem.indexOfScalar(u8, ch, '<')) |lt| ch = ch[0..lt];
            if (std.mem.eql(u8, rhead, typeHead(ch))) return true;
        }
    }
    return false;
}

/// Publish a call's EXPLICIT type arguments under the callee's reified
/// type-parameter names, for a call that could not be spliced. The spliced
/// form binds these names itself; without the splice the body would read a
/// stale binding. Only reified parameters of a candidate with this name are
/// written, and each name once.
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

/// The same-named inline sibling that declares the first parameter
/// `vararg`, when `picked` declares it as a CONTAINER the first argument's
/// static type is not. Null when the pick already fits.
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
