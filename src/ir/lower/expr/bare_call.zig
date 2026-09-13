//! Bare, path-qualified and fully-qualified call lowering.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const literals = @import("../literals.zig");
const inline_state = @import("../inline_state.zig");
const decl_mod = @import("../decl.zig");
const ast_scan = @import("../ast_scan.zig");
const inline_call = @import("../inline_call.zig");
const lambda_body = @import("../lambda_body.zig");
const static_call_type = @import("../static_call_type.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunWithArity = helpers.lowerArgRunWithArity;
const lowerArgRunFull = helpers.lowerArgRunFull;
const internArgNames = helpers.internArgNames;
const internTypeArgs = helpers.internTypeArgs;
const exprSpan = helpers.exprSpan;
const collectDottedFqn = ast_scan.collectDottedFqn;
const isPackageHead = literals.isPackageHead;
const isPkgRoot = literals.isPkgRoot;
const isTopLevelProp = inline_state.isTopLevelProp;
const isLowerAnonCapture = decl_mod.isLowerAnonCapture;
const tryInlineCallWithTypeArgs = inline_call.tryInlineCallWithTypeArgs;
const resolveCapture = lambda_body.resolveCapture;
const staticCallReturnTypeRef = static_call_type.staticCallReturnTypeRef;

const receiver_mod = @import("receiver.zig");
const overloadPickByCast = receiver_mod.overloadPickByCast;
const overloadPickByLambdaReturn = receiver_mod.overloadPickByLambdaReturn;

const paths_mod = @import("paths.zig");
const classWithCompanion = paths_mod.classWithCompanion;
const ownMemberRejectsLambdas = paths_mod.ownMemberRejectsLambdas;

const member_mod = @import("member.zig");
const propTypeHeadOn = member_mod.propTypeHeadOn;

const lambda_mod = @import("lambda.zig");
const argFnArities = lambda_mod.argFnArities;
const argFnGenericFlags = lambda_mod.argFnGenericFlags;
const argLambdaBroadMasks = lambda_mod.argLambdaBroadMasks;
const argLambdaParamTypes = lambda_mod.argLambdaParamTypes;
const argLambdaParamTypesRecv = lambda_mod.argLambdaParamTypesRecv;
const deinitArgLambdaParamTypes = lambda_mod.deinitArgLambdaParamTypes;
const extensionCandidateFitsArity = lambda_mod.extensionCandidateFitsArity;
const memberHostingTrailingLambda = lambda_mod.memberHostingTrailingLambda;
const overloadHostingTrailingLambda = lambda_mod.overloadHostingTrailingLambda;
const predeclaredMemberTrailingLambdaShape = lambda_mod.predeclaredMemberTrailingLambdaShape;
const recordLambdaArgReceivers = lambda_mod.recordLambdaArgReceivers;
const substitutionRecv = lambda_mod.substitutionRecv;

const compose_mod = @import("compose.zig");
const ctorArgFnArities = compose_mod.ctorArgFnArities;
const ctorRealignedArgNames = compose_mod.ctorRealignedArgNames;
const resolveCallWithComposerAbi = compose_mod.resolveCallWithComposerAbi;
const selectedCallArgsForBuilder = compose_mod.selectedCallArgsForBuilder;

const call_mod = @import("call.zig");
const eagerAuditOn = call_mod.eagerAuditOn;
const emptyContainerCreatorArity = call_mod.emptyContainerCreatorArity;
const lastArgIsLambda = call_mod.lastArgIsLambda;
const nameHasReceiverCandidate = call_mod.nameHasReceiverCandidate;
const nameHasReifiedInlineCandidate = call_mod.nameHasReifiedInlineCandidate;

const emit_mod = @import("emit.zig");
const bareStaticRecvHead = emit_mod.bareStaticRecvHead;
const cmgCandidates = emit_mod.cmgCandidates;
const cmgStaticRecv = emit_mod.cmgStaticRecv;
const emitCall = emit_mod.emitCall;
const emitCallMember = emit_mod.emitCallMember;
const emitMemberOrGlobal = emit_mod.emitMemberOrGlobal;
const emitValueCall = emit_mod.emitValueCall;
const narrowedThisDeclares = emit_mod.narrowedThisDeclares;
const subjectCorrectedBareThis = emit_mod.subjectCorrectedBareThis;

const local_call_mod = @import("local_call.zig");
const anyLocalFnOverloadApplicable = local_call_mod.anyLocalFnOverloadApplicable;
const factoryResultHead = local_call_mod.factoryResultHead;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;
const enclosingObjectDeclaring = arg_shape_mod.enclosingObjectDeclaring;
const loadObjectValue = arg_shape_mod.loadObjectValue;

const static_type_mod = @import("static_type.zig");
const ownedClassSelfType = static_type_mod.ownedClassSelfType;

const type_probe_mod = @import("type_probe.zig");
const buildArgShapes = type_probe_mod.buildArgShapes;
const buildStaticArgShapes = type_probe_mod.buildStaticArgShapes;
const buildStaticReturnArgShapes = type_probe_mod.buildStaticReturnArgShapes;

const probe_mod = @import("probe.zig");
const anyReceiverClassDeclares = probe_mod.anyReceiverClassDeclares;
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const fnTypedRecvCannotShadow = probe_mod.fnTypedRecvCannotShadow;
const inReceiverContext = probe_mod.inReceiverContext;
const indexDeferReason = probe_mod.indexDeferReason;
const ownerChainShadowContains = probe_mod.ownerChainShadowContains;
const receiverTypeKnown = probe_mod.receiverTypeKnown;
const recordAmbiguousCall = probe_mod.recordAmbiguousCall;
const recordOutOfScopeCall = probe_mod.recordOutOfScopeCall;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const orEmitAudit = audit_mod.orEmitAudit;

const member_call_mod = @import("member_call.zig");
const ctorArgStaticHeads = member_call_mod.ctorArgStaticHeads;
const lowerResolvedExtensionCall = member_call_mod.lowerResolvedExtensionCall;
const lowerResolvedMemberCall = member_call_mod.lowerResolvedMemberCall;

const block_mod = @import("block.zig");
const firstSegment = block_mod.firstSegment;
const headIsPackage = block_mod.headIsPackage;
const rsplitLast = block_mod.rsplitLast;

const tests_shapes_mod = @import("tests_shapes.zig");
const Module = tests_shapes_mod.Module;
const span = tests_shapes_mod.span;

pub fn lowerPathCall(
    b: *FuncBuilder,
    expr: *const Expr,
    shadowed_by_class: bool,
    class_competes: bool,
    force_static_class: *bool,
) Allocator.Error!?Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const segments = callee.Path.segments;
    const name0 = segments[0].name;

    // Secondary-ctor delegation / default-value thunk: a bare own-member call
    // with no `this` in scope is a companion access — the enclosing instance
    // does not exist yet, so `generateOetf(x)` inside `: this(generateOetf(x))`
    // binds the companion's `generateOetf`, never an instance method. Dispatch
    // it as a member call on the owner class value; the VM forwards a class
    // receiver to its companion singleton, walking the superclass chain so an
    // inherited companion member (declared on a superclass's companion) resolves
    // too — `Sub.mk()` lowers to exactly this `LoadGlobal + CallMember` pair.
    // Mirrors the value-read handling of the same case (a bare own-member read
    // in a param thunk); `own_members` already includes own + inherited
    // companion members, so a plain member name is filtered by `hasOwnMember`.
    if (b.isParamThunk() and b.resolve("this") == null and
        b.hasOwnMember(name0) and b.ownMemberApplicable(name0, args.len) and
        !ownMemberRejectsLambdas(b, name0, args) and !classWithCompanion(b, name0))
    {
        if (b.ownerClass()) |owner| {
            const cls = b.allocReg();
            const on = try b.module.internConst(b.allocator, .{ .String = owner });
            try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = on } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            const nmc = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = cls,
                .name = nmc,
                .trailing_lambda = b.callTrailingLambda(),
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // A captured outer that also names a top-level fn: route through value.
    // Unless the outer is a local FUNCTION that cannot take this call — a
    // local `fun validate()` does not shadow the top-level `validate(block)`
    // for `validate { … }`, and routing through the captured self-cell made
    // the local call itself.
    const local_fn_takes_call = if (b.localFnDecls(name0)) |decls|
        try anyLocalFnOverloadApplicable(b, decls, args, ast_arg_names)
    else
        true;
    const shadowed_by_local = b.knowsOuter(name0) and b.resolve(name0) == null and
        b.module.hasBareCallCandidate(name0, segments[0].span.file) and
        local_fn_takes_call and
        // A captured local with definite NON-callable evidence (`var key = 0`
        // beside the `key(...) {}` composable) never serves a CALL — the
        // function wins, as in Kotlin.
        !b.isNonFnLocal(name0);
    if (shadowed_by_local) {
        const callee_r = try resolveCapture(b, name0);
        // Only a captured local *extension* function or a receiver-lambda param
        // takes the enclosing receiver as a leading `this`; a plain captured
        // local function (`fun check(a, b)` called from inside a `repeat { }`
        // lambda) must dispatch as a bare value, or `callValueWithThis`'s
        // receiver-fills-param heuristic shifts the enclosing `this` into the
        // first value parameter.
        const wants_this = b.isLocalExtFn(name0) or b.isReceiverLambdaParam(name0);
        const this_reg: ?Reg = if (wants_this)
            (if (b.knowsOuter("this") or b.capturesThisSlot())
                try resolveCapture(b, "this")
            else
                b.resolve("this"))
        else
            null;
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        if (this_reg) |recv| {
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = callee_r,
                .receiver = recv,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
        } else {
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
        }
        return dst;
    }

    // Bare-call resolution through the unified resolver. `resolveCall` folds
    // applicability, scope, and the member-vs-global emission decision into
    // one query; the switch below routes its verdict to a single emitter.
    const want = args.len;
    const cands = try b.module.bareCallCandidates(
        b.allocator,
        name0,
        segments[0].span.file,
    );
    defer b.allocator.free(cands);
    if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name0)) {
            std.debug.print("[bare-candidates] {s} file={d} count={d}\n", .{
                name0,
                segments[0].span.file.int(),
                cands.len,
            });
            for (cands) |fid| {
                const f = b.module.funcById(fid) orelse continue;
                std.debug.print(
                    "[bare-candidate] {s}#{d} pkg={s} file={?d} params={d} body={} kind={s} sig={} vis={s} mext_owner={s}\n",
                    .{
                        f.fqn,
                        fid.int(),
                        f.package,
                        if (b.module.registry.private_fn_files.get(fid)) |file| file.int() else null,
                        f.params.len,
                        f.hasBody(),
                        @tagName(f.kind),
                        b.module.decl_sigs.get(fid.int()) != null,
                        if (b.module.decl_sigs.get(fid.int())) |ds| @tagName(ds.visibility) else "-",
                        b.module.registry.member_ext_owner_class.get(fid) orelse "-",
                    },
                );
                for (f.params) |p| std.debug.print("  [bare-cand-param] {s}: {s}\n", .{ p.name, p.ty.name });
            }
        }
    }
    const last_arg_lambda = lastArgIsLambda(args);

    // An own member applicable to this call outranks a same-named top-level
    // function: defer to the member-dispatch path (`lowerImplicitThisCall`). A
    // cast at the call site commits to a specific overload and overrides.
    const prefer_member = b.resolve("this") != null and b.hasOwnMember(name0) and
        b.ownMemberApplicable(name0, args.len) and !ownMemberRejectsLambdas(b, name0, args) and
        b.resolve(name0) == null and !b.isLocalFn(name0) and !b.isLocalExtFn(name0);

    // Call-site evidence pre-picks a same-tier overload: an `as` cast names
    // the parameter type outright, and a trailing lambda's derived return
    // discriminates a return-variant family (the sumOf shape).
    const cast_pick: ?FuncId = (try overloadPickByCast(b, cands, args, want)) orelse
        try overloadPickByLambdaReturn(b, cands, args, want);

    // The index classification, for the ambiguity / out-of-scope diagnostics.
    // A cast at the call site pre-picks a same-tier overload, so an ambiguity
    // or type-overload deferral is not reported.
    var index_res = b.module.resolveBareCallIndexed(
        name0,
        b.self_package,
        segments[0].span.file,
        want,
        last_arg_lambda,
    );
    if (cast_pick != null) {
        const r = indexDeferReason(index_res);
        if (r == .ambiguous_tier or r == .type_overload) {
            index_res.outcome = .{ .deferred = .cast_disambiguated };
        }
    }

    if (prefer_member and cast_pick == null) return null;

    const shapes = try buildArgShapes(b, args, ast_arg_names);
    defer b.allocator.free(shapes);
    // An argument written with an EXPLICIT type-argument list carries
    // programmer-stated types the raw shape pass cannot see
    // (`pick(emptyList<Int>())` — the call-return record instantiates
    // `List<Int>`). Derive exactly those args so the emission pick judges
    // the same evidence the derivation passes did; anything else keeps the
    // raw shape (cost and behavior unchanged).
    var explicit_shape_owned: [8]?ir.TypeRef = @splat(null);
    defer for (&explicit_shape_owned) |*t| {
        if (t.*) |*owned| owned.deinit(b.allocator);
    };
    for (args, shapes, 0..) |*a, *sh, i| {
        if (i >= explicit_shape_owned.len) break;
        if (sh.ty != null) continue;
        if (a.* != .Call) continue;
        // A stdlib collection FACTORY names its own result head, and for a
        // bare call that head is often the only evidence there is. Without
        // it `combine(listOf(this, other)) { … }` inside a `Flow<T>`
        // extension gave its first argument no type at all, the binary
        // extension `Flow<T1>.combine(flow, transform)` was not disproved,
        // and the enclosing receiver bound it — passing the list itself as
        // `flow`, which then failed collecting a `List`.
        if (a.Call.type_args.len == 0) {
            if (a.Call.callee.* != .Path or a.Call.callee.Path.segments.len != 1) continue;
            const head = factoryResultHead(a.Call.callee.Path.segments[0].name) orelse continue;
            if (b.resolve(a.Call.callee.Path.segments[0].name) != null) continue;
            sh.ty = .{ .name = head, .nullable = false, .args = &.{} };
            continue;
        }
        if (try staticCallReturnTypeRef(b, a)) |t| {
            // Only a FULLY CONCRETE record is disproof-grade: a derivation
            // still carrying a bare type parameter anywhere (`Core<E>(...)`
            // inside the declaring class) names the wrong scope's parameter
            // and refuted every applicable overload of `atomic(...)`.
            var concrete = blk: {
                const th = typeHead(std.mem.trimEnd(u8, t.name, "?"));
                if (bareTypeParamHead(th) or ir.parseClassTypeParamIdentity(th) != null) break :blk false;
                for (t.args) |a2| {
                    const ah = typeHead(std.mem.trimEnd(u8, a2.name, "?"));
                    if (bareTypeParamHead(ah) or ir.parseClassTypeParamIdentity(ah) != null) break :blk false;
                }
                break :blk true;
            };
            if (b.isTypeParam(typeHead(std.mem.trimEnd(u8, t.name, "?")))) concrete = false;
            if (concrete) {
                explicit_shape_owned[i] = t;
                sh.ty = t;
                sh.ty_authoritative = true;
            } else {
                var owned = t;
                owned.deinit(b.allocator);
            }
        }
    }
    const owned_type_param_bounds = try b.typeParamBoundsSlice();
    defer if (owned_type_param_bounds) |bounds| b.allocator.free(bounds);
    var ctx = resolveCtxFor(
        b,
        name0,
        ast_type_args,
        cast_pick,
        owned_type_param_bounds orelse &.{},
    );
    ctx.nonlocal_return_lambda = inline_call.argLambdaHasNonlocalReturn(args) or blk: {
        // A spliced forwarder passes the original lambda along as a
        // parameter Path (`synchronized(lock, block)` inside another
        // inline wrapper): follow the splice's lambda-argument map so a
        // non-local `return` in the ORIGINAL literal still pins the
        // static inline resolution.
        for (args) |*a| {
            if (a.* != .Path or a.Path.segments.len != 1) continue;
            const lam = b.inlineLambdaFor(a.Path.segments[0].name) orelse continue;
            if (lam.* != .Lambda) continue;
            var one = [_]Expr{lam.*};
            if (inline_call.argLambdaHasNonlocalReturn(&one)) break :blk true;
        }
        break :blk false;
    };
    if (runtime.envOnce("KLIO_EF_TRACE")) |efw| {
        if (std.mem.eql(u8, efw, name0)) std.debug.print("[efset] nlr={} nargs={d} last_lambda={} file={d}\n", .{ ctx.nonlocal_return_lambda, args.len, lastArgIsLambda(args), segments[0].span.file.int() });
    }
    const res = try resolveCallWithComposerAbi(
        b,
        name0,
        segments[0].span.file,
        cands,
        shapes,
        last_arg_lambda,
        ctx,
    );
    // Eager audit: where typeck recorded a pick for this call site,
    // compare it against the engine's answer. Audit-only — behavior
    // flips seam by seam once disagreement is at zero.
    if (eagerAuditOn() and runtime.envOnce("KLIO_EAGER_HITS") != null) {
        std.debug.print("[EAGER-PROBE] '{s}' f{d}:{d}-{d} map={}\n", .{ name0, segments[0].span.file.int(), segments[0].span.start, segments[0].span.end, b.module.eager_calls != null });
    }
    var res_final = res;
    if (b.module.eagerCallTarget(segments[0].span)) |eager_fid| eager: {
        // A pick that resolves the call back to the ENCLOSING declaration
        // while the lazy engine chose otherwise is distrusted: stdlib
        // overload families delegate to same-name siblings, and a
        // mis-picked self-target recurses forever.
        if (b.self_decl_span) |sds| {
            const ec = &(b.module.eager_calls.?);
            if (ec.get(segments[0].span)) |decl| {
                if (decl.file.int() == sds.file.int() and decl.start == sds.start and decl.end == sds.end and
                    (res.target == null or res.target.?.int() != eager_fid.int()))
                {
                    break :eager;
                }
            }
        }
        // Consumption: the typeck-decided target is type-derived and
        // overload-precise where the lazy engine is shape-based; prefer
        // it. `target_final` pins the pick against runtime value-typed
        // re-picks, matching a cast-disambiguated call.
        if (res.target == null or res.target.?.int() != eager_fid.int()) {
            res_final.target = eager_fid;
            res_final.target_final = true;
            if (res_final.emit_form != .Call) res_final.emit_form = .Call;
        }
        if (eagerAuditOn()) {
            const lazy: ?FuncId = res.target;
            if (runtime.envOnce("KLIO_EAGER_HITS") != null) {
                std.debug.print("[EAGER-HIT] '{s}'\n", .{name0});
            }
            if (lazy == null or lazy.?.int() != eager_fid.int()) {
                const lazy_str: i64 = if (lazy) |l| @intCast(l.int()) else -1;
                const efqn: []const u8 = if (b.module.funcById(eager_fid)) |f| f.fqn else "?";
                const lfqn: []const u8 = if (lazy) |l| (if (b.module.funcById(l)) |f| f.fqn else "?") else "-";
                std.debug.print("[EAGER-AUDIT] call '{s}': eager={d}({s}) lazy={d}({s})\n", .{ name0, eager_fid.int(), efqn, lazy_str, lfqn });
            }
        }
    }

    defer b.allocator.free(res_final.candidate_set);
    const was_cast = cast_pick != null and res_final.target != null and cast_pick.?.int() == res_final.target.?.int();

    // Kotlin ranks an implicit receiver's FUNCTION-TYPED property — the
    // invoke convention — above an outer-scope top-level function:
    // `with(Host()) { handler() }` calls the Host property's lambda even
    // when a top-level `handler()` exists. The static engine ranks
    // functions only, so a top-level pick with such a peer re-routes to
    // the member-or-global walk, whose runtime tail prefers the member.
    if (res_final.target != null and !was_cast) peer: {
        const tgt = res_final.target.?;
        const tf = b.module.funcById(tgt) orelse break :peer;
        if (tf.kind != .plain) break :peer;
        if (tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this")) break :peer;
        if (b.resolve(name0) != null) break :peer;
        const recv_heads = [_]?[]const u8{ bareStaticRecvHead(b), b.recvTy(), b.enclosingRecvTy() };
        for (recv_heads) |mh| {
            const h = mh orelse continue;
            const ph = propTypeHeadOn(b, typeHead(std.mem.trimEnd(u8, h, "?")), name0) orelse continue;
            // Function-typed property heads register as `FunctionN` from a
            // lowered ref or the `<function>` placeholder from an AST
            // function-type annotation; only the former proves an arity.
            if (std.mem.startsWith(u8, ph, "Function")) {
                const n = std.fmt.parseInt(usize, ph["Function".len..], 10) catch continue;
                if (n != args.len) continue;
            } else if (!std.mem.eql(u8, ph, "<function>")) continue;
            orEmitAudit(b, "prop_invoke_peer", "CallMemberOrGlobal", name0);
            return try emitMemberOrGlobal(b, expr, tgt, false);
        }
    }

    // A known stdlib host-intrinsic global (alias) whose user overloads do not
    // apply to this call still resolves to the intrinsic global. In a receiver
    // context, bind it directly — no class declares the name as a member, so a
    // `this.<name>` redispatch would invoke the receiver itself.
    if (res_final.target == null and !shadowed_by_class and inReceiverContext(b) and
        ir.isAliasName(name0) and !anyReceiverClassDeclares(b, name0) and
        !extensionCandidateFitsArity(b, name0, args.len) and
        b.resolve(name0) == null and !b.knowsOuter(name0))
    {
        return try emitValueCall(b, args, ast_arg_names, ast_type_args, name0);
    }

    // KLIO_BARE_TRACE=<name>: print the static resolution for a bare call —
    // which overload bound (or that none did), the emit form, and the
    // receiver context the decision saw. The static complement of
    // KLIO_MISS_TRACE.
    if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name0) and res_final.target == null) {
            std.debug.print("[bare] {s} -> NONE recv_ty={s} encl_recv={s} pkg={s} shadowed={} known_none={} at=f{d}:{d}\n", .{
                name0,
                b.recvTy() orelse "-",
                b.enclosingRecvTy() orelse "-",
                b.self_package,
                shadowed_by_class,
                b.own_recv_known_none,
                segments[0].span.file.int(),
                segments[0].span.start,
            });
        }
    }
    // A TYPE-DISPATCHED overload set the index deferred to runtime must
    // reach an emit form whose runtime tail re-ranks by value types.
    // Falling through to the bare-name value read handed the call to the
    // global lookup's first-wins pick — the deprecated 9-param
    // ActualParagraph sibling ran with a TextOverflow in its Boolean
    // `ellipsis` slot.
    if (res_final.target == null and !shadowed_by_class and
        indexDeferReason(index_res) == .type_overload)
    {
        if (index_res.first) |first_cand| {
            orEmitAudit(b, "type_overload_deferred", "CallMemberOrGlobal", name0);
            return try emitMemberOrGlobal(b, expr, first_cand, false);
        }
    }
    // RESOLUTION PARITY for spliced receiver-lambda regions: a PLAIN
    // top-level pick may be shadowed by the subject's members/extensions
    // (the framed route's runtime walk would rank them first — static
    // `sort()` inside `toTypedArray().apply { }` bound a wrong top-level
    // where Array.sort must win). Defer those to the member-first walk.
    // An EXTENSION pick stands: it is receiver-compatible evidence the
    // walk can only weaken (`putAll(this@toMap)` must keep the
    // Iterable-pairs extension, not fall to the member `putAll(Map)`).
    if (inline_call.rfsEnabled() and b.encl_tower_depth > 0 and
        res_final.target != null and !nameHasReifiedInlineCandidate(name0))
    plain_defer: {
        const tf0 = b.module.funcById(res_final.target.?) orelse break :plain_defer;
        const is_ext0 = tf0.params.len != 0 and std.mem.eql(u8, tf0.params[0].name, "this");
        if (is_ext0) break :plain_defer;
        if (!nameHasReceiverCandidate(b, name0, null) and
            !b.module.registry.class_member_names.contains(name0)) break :plain_defer;
        orEmitAudit(b, "tower_parity_defer", "fallthrough", name0);
        return null;
    }
    if (res_final.target) |target| {
        if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
            if (std.mem.eql(u8, w, name0)) {
                const tfn = b.module.funcById(target);
                const tf = if (tfn) |f| f.fqn else "?";
                const np: usize = if (tfn) |f| f.params.len else 0;
                const is_ext_t = if (tfn) |f| f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this") else false;
                const sel_ret: []const u8 = if (tfn) |f| blk_sr: {
                    if (f.params.len == 0) break :blk_sr "-";
                    const lp = f.params[f.params.len - 1].ty;
                    if (lp.args.len == 0) break :blk_sr "-";
                    break :blk_sr lp.args[lp.args.len - 1].name;
                } else "-";
                std.debug.print("[bare] pick_was={?d} sel_ret={s}\n", .{ if (cast_pick) |cp| cp.int() else null, sel_ret });
                std.debug.print("[bare] {s} -> {s}#{d} params={d} ext={} form={s} recv_ty={s} encl_recv={s} pkg={s} shadowed={} at=f{d}:{d}\n", .{
                    name0,
                    tf,
                    target.int(),
                    np,
                    is_ext_t,
                    @tagName(res_final.emit_form),
                    b.recvTy() orelse "-",
                    b.enclosingRecvTy() orelse "-",
                    b.self_package,
                    shadowed_by_class,
                    @intFromEnum(segments[0].span.file),
                    segments[0].span.start,
                });
                for (shapes) |*sh| std.debug.print("  [bare-shape] {s}\n", .{if (sh.ty) |t| t.name else "?"});
                std.debug.print("[bare-res] {s} tier={d} reason={?s} final={} tier_count={d} index={s} lazy={?d}\n", .{ name0, res_final.tier, if (res_final.reason) |r| @tagName(r) else null, res_final.target_final, res_final.tier_count, @tagName(index_res.outcome), if (res.target) |t| t.int() else null });
            }
        }
        if (!shadowed_by_class) {
            // Constructors do not yet occupy a `resolveCall` candidate slot,
            // but their classifier scope tier is shared with callables. A
            // nearer class constructs immediately; a nearer function commits;
            // only an equal-tier constructor/factory family needs the
            // class-carrying runtime comparison. An explicit argument cast
            // already disambiguated the factory overload.
            if (class_competes and !was_cast) {
                const caller_pkg = b.module.packageOfFile(
                    segments[0].span.file,
                ) orelse b.self_package;
                const class_tier = b.module.classRefTier(
                    name0,
                    caller_pkg,
                    segments[0].span.file,
                ) orelse ir.Module.other_package_tier;
                if (class_tier < res_final.tier) {
                    force_static_class.* = true;
                    return null;
                }
                if (class_tier == res_final.tier) return null;
            }
            if (indexDeferReason(index_res) == .ambiguous_tier) {
                try recordAmbiguousCall(b, name0, segments[0].span, index_res);
            }
            // A target in a package the caller cannot see is an unresolved
            // reference (kotlinc rejects the call); the diagnostic fails the
            // program before it runs.
            _ = try recordOutOfScopeCall(b, name0, segments[0].span, target, index_res);
            // A per-file import alias (`import ... unsafeFlow as flow`)
            // resolves through the symbol index to a target the NAME-keyed
            // inline table cannot see — it holds declared names only. When
            // that committed target is an inline header stub, emitting the
            // call would enter a bodyless frame at runtime; splice its
            // registered AST by id instead.
            if (b.module.funcById(target)) |tfi| {
                // Alias calls only (`import ... unsafeFlow as flow` spells
                // `flow`): when the call-site name matches the declared name,
                // the NAME-keyed inline path already made its splice-or-defer
                // decision and forcing a second splice here re-lowers bodies
                // in foreign file scopes (a compose body's package-private
                // reference failed at its splice site).
                if (tfi.is_inline and !tfi.hasBody() and !std.mem.eql(u8, name0, tfi.name)) {
                    if (inline_state.inlineAstById(target.int())) |inline_ast| {
                        inline_state.ensureInlineBody(inline_ast);
                        const iexp = b.peekExpected();
                        const iexp_ptr: ?*const ast.TypeRef = if (iexp) |*_e| _e else null;
                        var iselected = try selectedCallArgsForBuilder(
                            b,
                            target,
                            args,
                            ast_arg_names,
                            exprSpan(callee),
                            call.has_trailing_lambda,
                        );
                        defer iselected.deinit(b.allocator);
                        inline_call.splice_route_tag = "lowerPathCall:14624";
                        if (try tryInlineCallWithTypeArgs(b, name0, inline_ast, iselected.args, iselected.names, null, ast_type_args, iexp_ptr)) |r| {
                            return r;
                        }
                    }
                }
            }
            return switch (res_final.emit_form) {
                // A finalized pick is as definitive as a cast pick: the
                // runtime's value-typed overload re-pick must not override it.
                .Call => try emitCall(b, expr, target, was_cast or res_final.target_final),
                .CallMember => try emitCallMember(b, expr, target, was_cast),
                .CallMemberOrGlobal => try emitMemberOrGlobal(b, expr, target, was_cast),
                // The resolver never emits a value call with a committed target.
                .CallValue => unreachable,
            };
        }
    }
    return null;
}

/// The receiver-context bits `resolveCall` folds into its emit-form decision,
/// read once from the builder. Shared by the live path and the audit shadow so
/// both query `resolveCall` identically.
/// The active inline splice's receiver head, for a name the spliced body
/// does NOT bind itself. A spliced inline function's own parameter shadows
/// its receiver's extensions exactly as it does before splicing — `mp`'s
/// `crossinline transform` against `Flw.transform` — so a name the splice
/// substituted keeps resolving as that parameter.
fn spliceRecvForName(b: *const FuncBuilder, name0: []const u8) ?[]const u8 {
    if (b.resolve(name0) != null or b.knowsOuter(name0)) return null;
    if (b.inlineLambdaFor(name0) != null) return null;
    return b.spliceRecvTy();
}

pub fn resolveCtxFor(
    b: *FuncBuilder,
    name0: []const u8,
    ast_type_args: []const ast.TypeRef,
    cast_pick: ?FuncId,
    actual_type_param_bounds: []const ir.ModuleRegistry.TypeParamBound,
) ir.Module.ResolveCtx {
    return .{
        .in_receiver_context = inReceiverContext(b),
        .unknown_receiver = b.capturesThisSlot() or b.isParamThunk() or
            (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name0)),
        .recv_cannot_shadow = fnTypedRecvCannotShadow(b, name0) and
            !b.capturesThisSlot() and !b.isParamThunk() and
            b.ownerClass() == null,
        .enclosing_has_member = b.hasEnclosingMember(name0) or blk: {
            const oc = b.ownerClass() orelse break :blk false;
            break :blk (ownerChainShadowContains(b, oc, name0) orelse false);
        },
        .receiver_known = receiverTypeKnown(b, name0),
        .has_type_args = ast_type_args.len != 0,
        .has_composer = b.resolve("$composer") != null,
        .cast_pick = cast_pick,
        // Inside an inline SPLICE the frame's own `recv_ty` is the CALLER's,
        // so a spliced extension body would resolve its bare calls with no
        // receiver at all and lose its own receiver's extensions
        // (`serializer(type)` inside `SerializersModule.serializer()` bound
        // the module-less overload). The splice channel carries the spliced
        // declaration's receiver; consult it only when the frame has none.
        // During an ACTIVE splice the spliced body's bare calls resolve
        // against the spliced declaration's OWN receiver, ahead of the
        // frame's `recv_ty` — which is the CALLER's. A receiver-bearing
        // caller (an inline fn spliced into an EXTENSION function) would
        // otherwise shadow the splice receiver and a bare extension call in
        // the spliced body (`transform { }` = `Flow.unsafeTransform` inside
        // `Flow.map`, spliced into `List<T>.ext`) would resolve against the
        // caller's receiver and miss. Mirrors `bareStaticRecvHead`: this
        // narrow, then the splice receiver, then the frame's own.
        // During an ACTIVE splice the frame's own `recv_ty` is the CALLER's
        // (the inline body is hygienic). When the caller is itself a
        // receiver-bearing function (an inline fn spliced into an EXTENSION
        // function), that caller receiver would shadow the spliced
        // declaration's own receiver and a bare extension call in the body
        // (`transform { }` = `Flow.unsafeTransform` inside `Flow.map`,
        // spliced into `List<T>.ext`) would resolve against the wrong
        // receiver and miss. Prefer the splice receiver over the caller's,
        // mirroring `bareStaticRecvHead`; `spliceRecvForName`'s local gate
        // cannot serve here because the collided name (`transform`) is also
        // a bound param, so consult the splice receiver directly.
        .recv_ty = blk_recv: {
            const chosen = b.thisNarrow() orelse
                (if (b.spliceHintActive() and b.recvTy() != null) b.spliceRecvTy() else b.recvTy()) orelse
                spliceRecvForName(b, name0);
            if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
                if (std.mem.eql(u8, w, name0)) std.debug.print("[bare-ctx] {s} narrow={?s} splice_active={} recvTy={?s} spliceRecvTy={?s} hintRecv={?s} forName={?s} -> {?s}\n", .{ name0, b.thisNarrow(), b.spliceHintActive(), b.recvTy(), b.spliceRecvTy(), b.spliceHintRecv(), spliceRecvForName(b, name0), chosen });
            }
            break :blk_recv chosen;
        },
        .recv_type = if (b.thisNarrow()) |t|
            ir.TypeRef{ .name = t, .nullable = false, .args = &.{} }
        else if (b.spliceHintActive() and b.recvTy() != null)
            (if (b.spliceRecvTyRef()) |srt| srt.* else null)
        else if (b.recvTypeRef()) |rt|
            rt
        else if (spliceRecvForName(b, name0) != null)
            (if (b.spliceRecvTyRef()) |srt| srt.* else null)
        else
            null,
        .actual_type_param_bounds = actual_type_param_bounds,
        .is_value_capture = b.knowsOuter(name0) and b.resolve(name0) == null,
        .in_tailrec_body = b.tailrecSelf() != null,
        .owner_class = b.ownerClass(),
        .receiver_scope_complete = receiverScopeKind(b) != .no,
        .tower_scope = receiverScopeKind(b) == .tower,
        .tower = b.implicit_receiver_tower.items,
    };
}

/// A lambda/thunk body's receiver scope is complete when its
/// implicit-receiver TOWER enumerates every level and each entry's class is
/// free of the outer-receiver escapes (enclosing-class instances, companion
/// pairing) with a complete hierarchy shadow set — the same tests the
/// plain-method owner path applies, per tower entry.
fn towerScopeComplete(b: *FuncBuilder) bool {
    const items = b.implicit_receiver_tower.items;
    if (items.len == 0) return false;
    for (items) |entry| {
        var head = std.mem.trimEnd(u8, entry.head, "?");
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        const cid = (if (std.mem.indexOfScalar(u8, head, '.') != null)
            b.module.classIdByFqn(head)
        else
            b.module.uniqueClassIdBySimpleName(typeHead(head))) orelse return false;
        if (cid.int() >= b.module.classes.items.len) return false;
        const lifted = b.module.classes.items[cid.int()].name;
        const fqn = b.module.classes.items[cid.int()].fqn;
        if (b.module.registry.enclosing_class.get(lifted) != null or
            b.module.registry.enclosing_class.get(fqn) != null)
        {
            return false;
        }
        if (b.module.registry.companion_singletons.contains(lifted) or
            b.module.registry.companion_singletons.contains(fqn))
        {
            return false;
        }
        if (ownerChainShadowContains(b, lifted, "") == null) return false;
    }
    return true;
}

const ScopeCompleteness = enum { no, plain, tower };

fn receiverScopeKind(b: *FuncBuilder) ScopeCompleteness {
    if (b.capturesThisSlot() or b.isParamThunk()) {
        if (std.mem.eql(u8, runtime.envOnce("KLIO_TOWER_SCOPE") orelse "1", "0")) return .no;
        return if (towerScopeComplete(b)) .tower else .no;
    }
    return if (receiverScopeCompletePlain(b)) .plain else .no;
}

pub fn receiverScopeCompletePlain(b: *FuncBuilder) bool {
    const recv = b.recvTypeRef();
    const owner = b.ownerClass();
    if (recv) |receiver| {
        const head = typeHead(receiver.name);
        const hierarchy = b.module.registry.hierarchy_shadow_names.get(head) orelse
            b.module.registry.hierarchy_shadow_names.get(receiver.name) orelse
            return false;
        if (!hierarchy.complete) return false;
    }
    const owner_name = owner orelse return recv != null;
    const owner_id = b.module.classId(owner_name);
    const owner_fqn = if (owner_id) |id|
        (if (id.int() < b.module.classes.items.len)
            b.module.classes.items[id.int()].fqn
        else
            owner_name)
    else
        owner_name;
    if (b.module.registry.enclosing_class.get(owner_name) != null or
        b.module.registry.enclosing_class.get(owner_fqn) != null)
    {
        return false;
    }
    if (b.module.registry.companion_singletons.contains(owner_name) or
        b.module.registry.companion_singletons.contains(owner_fqn))
    {
        return false;
    }
    return ownerChainShadowContains(b, owner_name, "") != null;
}

pub fn allNull(names: []const ?[]const u8) bool {
    for (names) |n| {
        if (n != null) return false;
    }
    return true;
}

/// Resolve an own private method against the complete predeclared overload
/// set. Private members cannot be overridden, so a unique applicability winner
/// is a direct target even when its declaration appears after the caller.
pub fn resolvePrivateMemberCall(
    b: *FuncBuilder,
    name: []const u8,
    file: ir.FileId,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error!Module.MemberResolution {
    const owner_name = b.ownerClass() orelse return .{};
    const owner_id = b.module.classIdIndexed(owner_name, b.self_package, file) orelse
        b.module.classId(owner_name) orelse return .{};
    if (owner_id.int() >= b.module.classes.items.len) return .{};
    const shapes = try buildStaticArgShapes(b, args, arg_names);
    defer b.allocator.free(shapes);
    const owned_type_param_bounds = try b.typeParamBoundsSlice();
    defer if (owned_type_param_bounds) |bounds| b.allocator.free(bounds);
    var owner_type = try ownedClassSelfType(
        b.allocator,
        &b.module.classes.items[owner_id.int()],
    );
    defer owner_type.deinit(b.allocator);
    return b.module.resolveMemberCall(owner_id, name, shapes, .{
        .caller_file = file,
        .lexical_owner = owner_id,
        .private_only = true,
        .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
        .receiver_type = owner_type,
    });
}

/// Inside a method body: unqualified `name(...)` is a method call on `this`.
pub fn lowerImplicitThisCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
) Allocator.Error!?Reg {
    const segments = callee.Path.segments;
    if (segments.len != 1) return null;
    const name0 = segments[0].name;
    if (b.resolve(name0) != null or b.knowsOuter(name0) or !b.hasOwnMember(name0)) return null;
    // A call written with EXPLICIT type arguments cannot be answered by an own
    // member that declares no type parameters, so that member does not shadow
    // the same-named top-level function. androidx.collection's own test
    // declares `@Test fun emptyObjectIntMap()` and calls the imported
    // `fun <K> emptyObjectIntMap()` inside it; routing through implicit-this
    // dispatch bound the enclosing method and recursed until the eval depth
    // blew. Declining here returns the call to the normal resolution path,
    // which is what the same call in initializer position always took.
    if (ast_type_args.len != 0 and !b.ownMemberAcceptsTypeArgs(name0)) return null;
    // E4: when the eager channel committed this call to a PLAIN top-level
    // function, the same-named own member does not shadow it — kotlin
    // scoping resolved the other way, and the record gate now checks the
    // full declared+inherited member surface, so a surviving record means
    // no member (own or inherited) shadows. The redirect stands where the
    // channel is silent or names a method.
    if (b.module.eagerCallTarget(segments[0].span)) |efid| {
        if (b.module.funcById(efid)) |ef| {
            if (ef.kind == .plain) return null;
        }
    }
    // A same-named member that cannot bind this call's arity (a 0-arg
    // `requireNotNull()` for a 1-arg `requireNotNull(x)`) does not shadow the
    // top-level function: defer to the global-resolution path instead of
    // emitting a `this.<member>` call that can't dispatch.
    if (!b.ownMemberApplicable(name0, args.len)) return null;
    if (ownMemberRejectsLambdas(b, name0, args)) return null;
    const this_reg0 = b.resolve("this") orelse return null;
    const this_reg = subjectCorrectedBareThis(b, name0, this_reg0);

    const member_lambda_shape: ?ir.ModuleRegistry.MemberTrailingLambdaShape = if (allNull(ast_arg_names) and lastArgIsLambda(args))
        predeclaredMemberTrailingLambdaShape(b, name0, args.len)
    else
        null;
    const member_lambda_fid: ?FuncId = if (allNull(ast_arg_names) and lastArgIsLambda(args))
        memberHostingTrailingLambda(b, name0, args.len)
    else
        null;

    // Broad-collection mask: a trailing lambda bound to this member's
    // function-typed parameter whose declared type is `Iterable`/`Collection`
    // marks the lambda's matching params broad, so `it + x` over a runtime
    // `Set` yields a `List` (the declared, not runtime, receiver type).
    const itc_broad: ?[]u32 = blk: {
        const fid = member_lambda_fid orelse break :blk null;
        const f = b.module.funcById(fid) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (itc_broad) |m| b.allocator.free(m);

    // Private own-class methods bind to their stable declaration identity.
    const private_resolution = try resolvePrivateMemberCall(
        b,
        name0,
        segments[0].span.file,
        args,
        ast_arg_names,
    );
    if (private_resolution.dispatch == .direct and ast_type_args.len == 0) {
        const fid = private_resolution.target.?;
        // Reserve the receiver slot first, then lower the arguments into a
        // contiguous run immediately after it. `lowerArgRun` reserves every
        // argument slot before lowering any argument, so an argument's own
        // scratch registers can never clobber an already-lowered slot (a bug
        // the previous hand-rolled loop had, dropping local-variable args).
        const args_start = b.allocReg();
        b.pending_arg_broad_masks = itc_broad;
        if (b.module.funcById(fid)) |pf| {
            const recv_off: usize = if (pf.params.len != 0 and std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0;
            try recordLambdaArgReceivers(b, pf, args, ast_arg_names, ast_type_args, recv_off);
        }
        const priv_arity: ?[]const i16 = if (b.module.funcById(fid)) |pf|
            (try argFnArities(b, pf, args, ast_arg_names, if (pf.params.len != 0 and std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0))
        else
            null;
        defer if (priv_arity) |arities| b.allocator.free(arities);
        const priv_fn_generic: ?[]bool = if (b.module.funcById(fid)) |pf|
            (try argFnGenericFlags(b, pf, args, ast_arg_names, if (pf.params.len != 0 and std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0))
        else
            null;
        defer if (priv_fn_generic) |m| b.allocator.free(m);
        b.pending_arg_fn_generic = priv_fn_generic;
        const priv_lambda_param_types: ?[]?[]ir.TypeRef = if (b.module.funcById(fid)) |pf|
            blk_priv: {
                if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] privBare fn={s}\n", .{pf.name});
                break :blk_priv try argLambdaParamTypes(
                b,
                pf,
                args,
                ast_arg_names,
                ast_type_args,
                if (pf.params.len != 0 and
                    std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0,
            );
            }
        else
            null;
        defer if (priv_lambda_param_types) |types|
            deinitArgLambdaParamTypes(b.allocator, types);
        b.pending_arg_lambda_param_types = priv_lambda_param_types;
        const run = try lowerArgRunWithArity(b, args, priv_arity);
        try b.push(.{ .Move = .{ .dst = args_start, .src = this_reg } });
        var user_arg_names = try b.allocator.alloc(?[]const u8, ast_arg_names.len + 1);
        defer b.allocator.free(user_arg_names);
        user_arg_names[0] = null;
        for (ast_arg_names, 0..) |n, i| user_arg_names[i + 1] = n;
        const arg_names = try internArgNames(b.allocator, b.module, user_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .Call = .{
            .dst = dst,
            .func = fid,
            .trailing_lambda = b.callTrailingLambda(),
            .args = args_start,
            .n_args = run[1] + 1,
            .arg_names = arg_names,
            .type_args = &.{},
            .exact = true,
        } });
        return dst;
    }
    // A member the receiver type PROVABLY declares wins over any same-named
    // top-level in Kotlin's scope order, so a resolved target commits
    // statically here — direct for final/private, a virtual slot otherwise.
    // Only an UNPROVEN member keeps the OrGlobal fallback below (a
    // non-callable property, an arity miss the runtime resolves to the
    // global). `KLIO_ITC_MEMBER=0` disables for single-binary A/B.
    const itc_gate = runtime.envOnce("KLIO_ITC_MEMBER") orelse "1";
    const itc_on = blk: {
        if (std.mem.eql(u8, itc_gate, "0")) break :blk false;
        if (std.mem.eql(u8, itc_gate, "1")) break :blk true;
        var it = std.mem.splitScalar(u8, itc_gate, ',');
        while (it.next()) |n| {
            if (std.mem.eql(u8, n, name0)) break :blk true;
        }
        break :blk false;
    };
    if (itc_on) attempt: {
        const head_name = bareStaticRecvHead(b) orelse b.ownerClass() orelse break :attempt;
        // A same-named FUNCTION-TYPED property on the receiver is an
        // invoke-convention peer the member resolver cannot rank (it ranks
        // functions only): `class C(val f: (A) -> T) { fun f(vararg s: A) =
        // f(s) }` binds the PROPERTY's invoke in Kotlin when the member's
        // vararg refuses the array. Leave such calls to the runtime walk.
        if (b.module.registry.class_prop_type_heads.get(.{ .a = typeHead(head_name), .b = name0 })) |ph| {
            if (std.mem.startsWith(u8, ph, "Function")) break :attempt;
        }
        {
            const guard_cid = if (std.mem.indexOfScalar(u8, head_name, '.') != null)
                b.module.classIdByFqn(head_name)
            else
                b.module.classIdIndexed(typeHead(head_name), b.self_package, segments[0].span.file) orelse
                    b.module.classId(typeHead(head_name));
            if (guard_cid) |gc| {
                if (gc.int() < b.module.classes.items.len) {
                    for (b.module.classes.items[gc.int()].primary_params) |pp| {
                        if (std.mem.eql(u8, pp.name, name0) and
                            std.mem.startsWith(u8, typeHead(pp.ty.name), "Function"))
                        {
                            break :attempt;
                        }
                    }
                }
            }
        }
        var owned_head_ty: ?TypeRef = null;
        defer if (owned_head_ty) |*t| t.deinit(b.allocator);
        const recv_ty = blk: {
            if (b.recvTypeRef()) |declared| {
                if (std.mem.eql(u8, typeHead(declared.name), head_name)) break :blk declared;
            }
            const head_fqn = blk2: {
                if (std.mem.indexOfScalar(u8, head_name, '.') != null) break :blk2 head_name;
                const cid = b.module.classIdIndexed(head_name, b.self_package, segments[0].span.file) orelse
                    b.module.classId(head_name) orelse break :attempt;
                if (cid.int() >= b.module.classes.items.len) break :attempt;
                break :blk2 b.module.classes.items[cid.int()].fqn;
            };
            owned_head_ty = TypeRef{
                .name = try b.allocator.dupe(u8, head_fqn),
                .nullable = false,
                .args = &.{},
            };
            break :blk owned_head_ty.?;
        };
        var this_path = [_]ast.Ident{.{ .name = "this", .span = segments[0].span }};
        const this_expr = Expr{ .Path = .{ .segments = &this_path, .span = segments[0].span } };
        switch (try lowerResolvedMemberCall(
            b,
            &this_expr,
            .{ .name = name0, .span = segments[0].span },
            args,
            ast_arg_names,
            ast_type_args,
            recv_ty,
            .{ .reg = this_reg, .non_null = true },
        )) {
            .lowered => |reg| {
                orEmitAudit(b, "implicit_this_call_member_bound", "Call/implicit-member", name0);
                return reg;
            },
            .deferred, .none => {},
        }
    }
    b.pending_arg_broad_masks = itc_broad;
    var member_arity: ?[]i16 = null;
    var member_fn_generic: ?[]bool = null;
    var member_lambda_param_types: ?[]?[]ir.TypeRef = null;
    const member_signature_fid = private_resolution.target orelse member_lambda_fid;
    if (member_signature_fid) |fid| {
        if (b.module.funcById(fid)) |f| {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
            member_arity = try argFnArities(b, f, args, ast_arg_names, recv_off);
            member_fn_generic = try argFnGenericFlags(
                b,
                f,
                args,
                ast_arg_names,
                recv_off,
            );
            if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] memberDeferred fn={s}\n", .{f.name});
        member_lambda_param_types = try argLambdaParamTypes(
                b,
                f,
                args,
                ast_arg_names,
                ast_type_args,
                recv_off,
            );
        }
    }
    if (member_lambda_shape) |shape| {
        if (member_arity == null) {
            const out = try b.allocator.alloc(i16, args.len);
            for (out) |*arity| arity.* = -1;
            member_arity = out;
        }
        member_arity.?[member_arity.?.len - 1] = shape.value_arity;
        const trailing = &args[args.len - 1];
        b.recordLambdaArgArity(trailing.span(), shape.value_arity);
        if (shape.receiver_head) |recv| {
            // An UNINSTANTIATED declared head (a type param or a class
            // param's identity mangle) must not clobber an instantiated
            // record another resolution pass already made for this slot.
            const uninstantiated = bareTypeParamHead(recv) or
                ir.parseClassTypeParamIdentity(recv) != null;
            if (!(uninstantiated and b.lambdaArgRecv(trailing.span()) != null)) {
                if (std.c.getenv("KLIO_LAR_TRACE") != null)
                    std.debug.print("[lar-site] site=shape name={s} recv={s} s={d}..{d}\n", .{ name0, recv, trailing.span().start, trailing.span().end });
                try b.recordLambdaArgRecvOwned(
                    trailing.span(),
                    try (ir.TypeRef{
                        .name = recv,
                        .nullable = false,
                        .args = &.{},
                    }).clone(b.allocator),
                );
            }
        }
    }
    defer if (member_arity) |arities| b.allocator.free(arities);
    defer if (member_fn_generic) |flags| b.allocator.free(flags);
    defer if (member_lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_fn_generic = member_fn_generic;
    b.pending_arg_lambda_param_types = member_lambda_param_types;
    const run = try lowerArgRunWithArity(b, args, member_arity);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    // When a same-named top-level function exists, the own member may be a
    // non-callable *property* (`val allStatusCodes = allStatusCodes()`),
    // which kotlinc skips for a call — emit the OrGlobal form so member
    // dispatch still wins when callable but a miss falls through to the
    // function instead of erroring. The same applies when the name is a
    // known top-level stdlib function (a host intrinsic, absent from
    // `funcsBySimpleName`): a `@Test fun listOfNotNull()` method calling the
    // top-level `listOfNotNull(...)` must fall through on the arity miss.
    if (b.module.hasBareCallCandidate(name0, segments[0].span.file) or
        ir.isAliasName(name0))
    {
        const this_idx = try b.recordCapture("this");
        orEmitAudit(b, "implicit_this_call_global_fallback", "CallMemberOrGlobal", name0);
        try b.push(.{ .CallMemberOrGlobal = .{
            .dst = dst,
            .this_idx = this_idx,
            .recv = this_reg,
            .name = nm,
            .trailing_lambda = b.callTrailingLambda(),
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
            .static_recv = try cmgStaticRecv(b),
        } });
        return dst;
    }
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = this_reg,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
    } });
    return dst;
}

/// Unresolved bare-name call: anon capture, primitive conversion, or
/// CallMemberOrGlobal.
pub fn lowerUnresolvedBareCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    static_ext: ?FuncId,
) Allocator.Error!?Reg {
    const name0 = callee.Path.segments[0].name;
    // Inside its own inline splice, a bare call of the SPLICED FUNCTION'S
    // name resolves through the receiver walk — kotlinc binds the
    // receiver's member (`ClosedRange.contains` inside the ranges
    // `contains` body), never the enclosing extension itself. Keeping the
    // self hint re-enters the splice at the global tier whenever every
    // receiver probe misses, which is an unconditional recursion.
    var ext_hint = static_ext;
    if (ext_hint) |hint| {
        if (b.currentInlineDecl()) |decl| {
            if (inline_state.inlineIdByAst(decl)) |own| {
                if (own == hint.int()) ext_hint = null;
            }
        }
    }
    // A bare call to a name the enclosing anon object closes over.
    if (isLowerAnonCapture(name0)) {
        const idx = try b.recordCapture(name0);
        const callee_r = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = callee_r, .idx = idx } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }
    // A stdlib container creator (`emptyList<String>()`) called with type
    // args inside a method body. The name is a host-intrinsic global, never
    // a class member, so the runtime `this.<name>()` redispatch the general
    // receiver-context path would emit cannot apply — and that path drops
    // the type args, losing the element head the value needs for receiver
    // proofs. Bind the global value directly and carry the type args so the
    // creation-site stamp (`runtime.attachDeclaredElemTypes`) runs.
    if (ast_type_args.len != 0 and emptyContainerCreatorArity(name0) != 0 and
        b.module.funcId(name0) == null and !anyReceiverClassDeclares(b, name0))
    {
        orEmitAudit(b, "container_creator_typed", "LoadGlobal", name0);
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
    // Outside any receiver context no member can serve the call (kotlinc
    // rejects resolving a bare call against a caller's receiver), and
    // `funcId == null` here means the overload tier has no candidates
    // either — the callee is a static global value.
    if (!inReceiverContext(b)) {
        // A name with no local, no capture, no global candidate, no
        // classifier, and no top-level property is PROVABLY unresolved
        // here — kotlinc rejects it (`fun probe(`this`: Box) { show() }`
        // has no receiver for `show`). Restricted to PACKAGE-LESS files
        // (the user-script shape): pack sources lower in stages where a
        // sibling classifier or a native binding is not yet visible
        // (`PathBuilder`, `__skia_c_draw_text2` false-fired), and a
        // runtime side module resolves against a wider universe. A named
        // import of the leaf also defeats provability: an intrinsic-only
        // function (`kotlin.concurrent.thread`) has a host impl but no
        // declaration, so the candidate probe cannot see it — the
        // runtime global universe serves the call.
        const file0 = callee.Path.segments[0].span.file;
        if (!b.module.anon_side and b.module.packageOfFile(file0) == null and
            b.resolve(name0) == null and !b.knowsOuter(name0) and
            !b.module.hasBareCallCandidate(name0, file0) and
            b.module.classId(name0) == null and !isTopLevelProp(name0) and
            b.module.importAliasIn(file0, name0) == null)
        {
            try b.module.resolve_diags.append(b.allocator, .{
                .name = name0,
                .fqn_a = "",
                .fqn_b = "",
                .span = callee.Path.segments[0].span,
                .kind = .unresolved_local,
            });
            return try b.emitConst(.Unit);
        }
        orEmitAudit(b, "unresolved_bare_call", "LoadGlobal", name0);
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
    // A known top-level stdlib function (`listOfNotNull`, `buildList`,
    // `compareBy`, …) that no class declares as a member is never a member of
    // the implicit receiver. Bind the global directly: routing it through
    // `CallMemberOrGlobal` would let the member/extension probe treat it as an
    // extension on `this` and prepend the receiver into its varargs.
    if (ir.isAliasName(name0) and !anyReceiverClassDeclares(b, name0) and
        !extensionCandidateFitsArity(b, name0, args.len))
    {
        orEmitAudit(b, "unresolved_bare_call", "LoadGlobal", name0);
        const callee_r = b.allocReg();
        const nm0 = try b.module.internConst(b.allocator, .{ .String = name0 });
        try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm0 } });
        const run0 = try lowerArgRun(b, args);
        const arg_names0 = try internArgNames(b.allocator, b.module, ast_arg_names);
        const type_args0 = try helpers.internTypeArgsScoped(b, ast_type_args);
        const dst0 = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst0,
            .callee = callee_r,
            .args = run0[0],
            .n_args = run0[1],
            .arg_names = arg_names0,
            .type_args = type_args0,
        } });
        return dst0;
    }
    // When `this` is bound locally (the frame's own receiver param — a
    // top-level/member extension's receiver, not an outer closure capture),
    // pass it as the explicit innermost receiver. A `recordCapture("this")`
    // here is wrong: a non-closure extension function has no capture frame,
    // so the capture slot is empty and the bare member misses its own
    // receiver. This is the `is JobSupport -> invokeOnCompletionInternal(…)`
    // shape — a bare member call on the extension's smart-cast receiver.
    // The only `this` in scope is an ordinary user parameter named `this`:
    // no implicit receiver exists, so the bare name binds a global or is an
    // unresolved reference at runtime — never a member of the parameter.
    if (b.this_is_plain_param and b.recvTy() == null and b.ownerClass() == null and
        !b.capturesThisSlot())
    {
        return try emitValueCall(b, args, ast_arg_names, ast_type_args, name0);
    }
    // A runtime-relowered body calling a LOCAL FN captured under its
    // MANGLED overload name (`Composition$ovl0`): route through the
    // captured value. The CMG name walk cannot see frame captures, so it
    // fell to a same-named classifier — the pack's `interface Composition`
    // instead of the test's local `@Composable fun Composition`.
    {
        var ovl_i: usize = 0;
        while (ovl_i < 4) : (ovl_i += 1) {
            var mb: [96]u8 = undefined;
            const mangled = std.fmt.bufPrint(&mb, "{s}$ovl{d}", .{ name0, ovl_i }) catch break;
            if (isLowerAnonCapture(mangled)) {
                return try emitValueCall(b, args, ast_arg_names, ast_type_args, try b.module.func_name_index.allocator.dupe(u8, mangled));
            }
        }
    }
    // A bare call in a receiver context is usually a MEMBER call written
    // without `this.` — measured, the names reaching here are `isEmpty`,
    // `get`, `contains`, `append`, not top-level functions. When the implicit
    // receiver's head names a class, the member has the same static answer the
    // explicit-receiver path computes. The receiver itself may be a CAPTURE
    // rather than a bound parameter, which is the case at most of these sites,
    // so materialise it through the closure's slot before asking.
    if (runtime.envOnce("KLIO_CHAN")) |w| {
        if (std.mem.eql(u8, w, name0)) {
            std.debug.print("[chan] {s} narrow={?s} hint_active={} hint={?s} splice_recv={?s} recv_ty={?s} owner={?s} lam_splice={} this_decl={?s} head={?s}\n", .{
                name0,
                b.thisNarrow(),
                b.spliceHintActive(),
                b.spliceHintRecv(),
                b.spliceRecvTy(),
                b.recvTy(),
                b.ownerClass(),
                b.lambda_splice_resolve != null,
                b.localDeclType("this"),
                bareStaticRecvHead(b),
            });
        }
    }
    if (bareStaticRecvHead(b)) |head_name| bare_member: {
        const head_fqn = blk: {
            if (std.mem.indexOfScalar(u8, head_name, '.') != null) break :blk head_name;
            const cid = b.module.classIdIndexed(head_name, b.self_package, callee.Path.segments[0].span.file) orelse
                b.module.classId(head_name) orelse {
                if (runtime.envOnce("KLIO_BAREARM") != null)
                    std.debug.print("[barearm-break] {s} no class id for {s}\n", .{ name0, head_name });
                break :bare_member;
            };
            if (cid.int() >= b.module.classes.items.len) break :bare_member;
            break :blk b.module.classes.items[cid.int()].fqn;
        };
        // The head's type ARGUMENTS are usually absent here, and that is fine
        // for this arm: the scorer already ranks a bare head, and refusing one
        // rules out every bare call in a generic body — which is most of them.
        // Prefer the enclosing declaration's own receiver type when it names
        // this head, since that one carries the arguments.
        var owned_recv_ty: ?TypeRef = null;
        defer if (owned_recv_ty) |*t| t.deinit(b.allocator);
        const recv_ty = blk: {
            // Inside a splice the enclosing declaration's receiver is the
            // CALLER's, not the spliced body's. Use the spliced declaration's
            // own receiver type, which carries the type arguments an overload
            // set that differs by element type needs.
            if (b.spliceHintActive()) {
                // The window's ACTUAL receiver record wins when its head
                // is (or extends) the declared one: `List<List<String>>`
                // carries the instantiation the declared `Collection<T>`
                // quotes as the callee's own parameter — and that
                // parameter NAME can capture into an inner callee's
                // same-named one.
                if (b.spliceRecvTyRef()) |art| {
                    const ah = typeHead(std.mem.trimEnd(u8, art.name, "?"));
                    const fits = std.mem.eql(u8, ah, head_name) or fit: {
                        const a_cid = b.module.uniqueClassIdBySimpleName(ah) orelse break :fit false;
                        const d_cid = b.module.uniqueClassIdBySimpleName(head_name) orelse break :fit false;
                        break :fit b.module.classIdIsOrExtends(a_cid, d_cid);
                    };
                    if (fits) {
                        owned_recv_ty = try art.clone(b.allocator);
                        break :blk owned_recv_ty.?;
                    }
                }
                if (b.spliceHintRecvRef()) |rt| {
                    if (std.mem.eql(u8, typeHead(rt.name.name), head_name)) {
                        owned_recv_ty = try decl_mod.loweredTypeRef(b.allocator, &rt, true);
                        break :blk owned_recv_ty.?;
                    }
                }
            } else if (b.recvTypeRef()) |declared| {
                if (std.mem.eql(u8, typeHead(declared.name), head_name)) break :blk declared;
            }
            break :blk TypeRef{ .name = head_fqn, .nullable = false, .args = &.{} };
        };
        const this_reg = if (b.resolve("this")) |r|
            r
        else if (b.capturesThisSlot() or b.knowsOuter("this"))
            try lambda_body.resolveCapture(b, "this")
        else {
            if (runtime.envOnce("KLIO_BAREARM") != null)
                std.debug.print("[barearm-break] {s} no this reg\n", .{name0});
            break :bare_member;
        };
        var this_path = [_]ast.Ident{.{ .name = "this", .span = callee.Path.segments[0].span }};
        const this_expr = Expr{ .Path = .{ .segments = &this_path, .span = callee.Path.segments[0].span } };
        const bare_member = try lowerResolvedMemberCall(
            b,
            &this_expr,
            .{ .name = name0, .span = callee.Path.segments[0].span },
            args,
            ast_arg_names,
            ast_type_args,
            recv_ty,
            .{ .reg = this_reg, .non_null = true },
        );
        if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
            if (std.mem.eql(u8, w, name0)) std.debug.print("[bare-member] {s} outcome={s} recv_ty={s} this_reg={d}\n", .{ name0, @tagName(std.meta.activeTag(bare_member)), recv_ty.name, this_reg.int() });
        }
        switch (bare_member) {
            .lowered => |reg| {
                orEmitAudit(b, "unresolved_bare_call", "Call/bare-member", name0);
                return reg;
            },
            .deferred, .none => {},
        }
        // No member serves it. Kotlin tries this receiver's EXTENSIONS before
        // moving outwards, so ask for them here rather than deferring the
        // whole walk: `plus(element)` written inside `Iterable<T>.plusElement`
        // is an extension on the body's own receiver, and leaving it dynamic
        // is what makes that body pick the concatenating overload at run time.
        // An applicable-but-DEFERRED member blocks the static extension
        // commit exactly as on the explicit-receiver path: a member the
        // receiver declares beats every extension in Kotlin, and committing
        // the extension here bound `Iterable.contains`'s own smart-cast
        // `contains(element)` back to itself once bound refutation pruned
        // the candidate tie down to it.
        member_call_mod.ext_route_tag = "lowerUnresolvedBareCall:18047";
        if (bare_member != .deferred) if (try lowerResolvedExtensionCall(
            b,
            &this_expr,
            .{ .name = name0, .span = callee.Path.segments[0].span },
            args,
            ast_arg_names,
            ast_type_args,
            recv_ty,
        )) |reg| {
            orEmitAudit(b, "unresolved_bare_call", "Call/bare-extension", name0);
            return reg;
        };
        // Kotlin then tries the OUTER implicit receivers, innermost first.
        // An extension serving an outer tower entry commits statically with
        // its receiver bound through the entry's `this@<label>` slot — the
        // same capture channel an explicit `this@drop` reference lowers
        // through — so the call needs no runtime receiver walk. Entries
        // without a reachable label stay dynamic.
        if (bare_member != .deferred and
            !std.mem.eql(u8, runtime.envOnce("KLIO_TOWER_EMIT") orelse "1", "0"))
        {
            const inner_tail = if (std.mem.lastIndexOfScalar(u8, head_name, '.')) |i|
                head_name[i + 1 ..]
            else
                head_name;
            for (b.implicit_receiver_tower.items) |entry| {
                const lbl = entry.label orelse continue;
                const entry_tail = if (std.mem.lastIndexOfScalar(u8, entry.head, '.')) |i|
                    entry.head[i + 1 ..]
                else
                    entry.head;
                if (std.mem.eql(u8, entry_tail, inner_tail)) continue;
                var slot_buf: [160]u8 = undefined;
                const slot = std.fmt.bufPrint(&slot_buf, "this@{s}", .{lbl}) catch continue;
                if (b.resolve(slot) == null and !b.knowsOuter(slot) and
                    !decl_mod.isLowerAnonCapture(slot)) continue;
                const outer_fqn = blk2: {
                    if (std.mem.indexOfScalar(u8, entry.head, '.') != null) break :blk2 entry.head;
                    const cid = b.module.classIdIndexed(entry.head, b.self_package, callee.Path.segments[0].span.file) orelse
                        b.module.classId(entry.head) orelse break :blk2 entry.head;
                    if (cid.int() >= b.module.classes.items.len) break :blk2 entry.head;
                    break :blk2 b.module.classes.items[cid.int()].fqn;
                };
                const outer_ty = TypeRef{ .name = outer_fqn, .nullable = false, .args = &.{} };
                // A member the outer receiver declares beats every extension
                // at its own level. An applicable (even unproven) member
                // keeps the call dynamic AND stops the walk: this level owns
                // the call.
                if (b.module.classIdByFqn(outer_fqn) orelse b.module.classId(entry_tail)) |ocid| {
                    var outer_shapes = try buildStaticReturnArgShapes(b, args, ast_arg_names);
                    defer outer_shapes.deinit(b.allocator);
                    const om = b.module.resolveMemberCall(ocid, name0, outer_shapes.shapes, .{
                        .caller_file = callee.Path.segments[0].span.file,
                        .receiver_type = outer_ty,
                    });
                    if (om.target != null or om.applicable) break;
                }
                const outer_this = Expr{ .This = .{
                    .qualifier = .{ .name = lbl, .span = callee.Path.segments[0].span },
                    .span = callee.Path.segments[0].span,
                } };
                member_call_mod.ext_route_tag = "lowerUnresolvedBareCall:18108";
                if (try lowerResolvedExtensionCall(
                    b,
                    &outer_this,
                    .{ .name = name0, .span = callee.Path.segments[0].span },
                    args,
                    ast_arg_names,
                    ast_type_args,
                    outer_ty,
                )) |reg| {
                    orEmitAudit(b, "unresolved_bare_call", "Call/bare-tower-extension", name0);
                    return reg;
                }
            }
        }
        if (runtime.envOnce("KLIO_BAREARM") != null) {
            var loc_buf: [256]u8 = undefined;
            const cs = callee.Path.segments[0].span;
            const loc: []const u8 = blk2: {
                if (span.active_map) |m| {
                    if (m.getChecked(cs.file)) |sf| {
                        const lc = sf.lineCol(cs.start);
                        const base = if (std.mem.lastIndexOfScalar(u8, sf.path, '/')) |i| sf.path[i + 1 ..] else sf.path;
                        break :blk2 std.fmt.bufPrint(&loc_buf, "{s}:{d}", .{ base, lc.line }) catch "?";
                    }
                }
                break :blk2 std.fmt.bufPrint(&loc_buf, "f{d}:{d}", .{ cs.file.int(), cs.start }) catch "?";
            };
            std.debug.print("[barearm-miss] {s} {s} recv={s} nargs={d} splice={}\n", .{
                loc, name0, recv_ty.name, args.len, b.spliceHintActive(),
            });
            for (args, 0..) |*a, i| {
                const t = argDeclTypeRefLazy(b, a);
                std.debug.print("[barearm-miss]   arg{d} ty={?s}\n", .{ i, if (t) |tt| tt.name else null });
            }
        }
    }
    // A call written with EXPLICIT type arguments cannot be answered by a
    // same-named own member that declares none, so the deferred member-first
    // form would bind the wrong target: androidx.collection's own
    // `@Test fun emptyObjectIntMap()` calling the imported
    // `fun <K> emptyObjectIntMap()` bound itself and recursed until the eval
    // depth blew. Commit the top-level function instead.
    if (ast_type_args.len != 0 and !b.ownMemberAcceptsTypeArgs(name0)) {
        if (b.module.funcId(name0)) |gid| {
            if (b.module.funcById(gid)) |gf| {
                const is_ext = gf.params.len != 0 and std.mem.eql(u8, gf.params[0].name, "this");
                if (!is_ext) {
                    orEmitAudit(b, "unresolved_bare_call", "Call/type-args-global", name0);
                    const grun = try lowerArgRun(b, args);
                    const gnames = try internArgNames(b.allocator, b.module, ast_arg_names);
                    const gtargs = try internTypeArgs(b.allocator, b.module, ast_type_args);
                    const gdst = b.allocReg();
                    try b.push(.{ .Call = .{
                        .dst = gdst,
                        .func = gid,
                        .trailing_lambda = b.callTrailingLambda(),
                        .args = grun[0],
                        .n_args = grun[1],
                        .arg_names = gnames,
                        .type_args = gtargs,
                        .exact = false,
                    } });
                    return gdst;
                }
            }
        }
    }
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    const dst = b.allocReg();
    orEmitAudit(b, "unresolved_bare_call", "CallMemberOrGlobal", name0);
    // No committed target, but a trailing lambda's expected shape still has
    // a static answer: read the per-arg lambda arities from the same-name
    // overload that hosts it at this arity, so a `T.() -> R` handler drops
    // its synthetic `it` here too (`launch { … }` deferred inside a
    // receiver context) and `it` resolves to the enclosing lambda's.
    const bare_arity: ?[]const i16 = blk: {
        if (allNull(ast_arg_names) and lastArgIsLambda(args)) {
            if (overloadHostingTrailingLambda(b, name0, args.len)) |fid| {
                if (b.module.funcById(fid)) |f| {
                    // The receiver offset depends on the candidate's own
                    // shape: a top-level fn has no leading `this`, and a
                    // blanket offset misaligned every arity (the trailing
                    // `() -> T` block read past the params, kept its
                    // synthetic `it`, and shadowed the enclosing one).
                    const off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
                    // The arity alone is not the whole lambda shape: a
                    // `T.() -> R` parameter also owns the block's `this`.
                    // Without the receiver record the block lowers
                    // receiverless and its bare `this` captures the
                    // ENCLOSING instance — `SnapshotStateMap.mutate`'s
                    // `withCurrent { this }` returned the outer map instead
                    // of the bound record. Record ONLY when the pick came
                    // from the owner-scoped member walk (it is absent from
                    // the top-level name index): a member's signature is
                    // scope-proven, while a top-level namesake pick is
                    // declaration-order heuristic and a wrong receiver
                    // stamp OVERRIDES the correct shape other sources
                    // supply (a same-name `g`/`group` twin re-shaped the
                    // SlotTable builder blocks and shifted every binding).
                    const member_pick = blk2: {
                        const tl = b.module.func_name_index.get(name0) orelse break :blk2 true;
                        for (tl.items) |tfid| {
                            if (tfid == fid) break :blk2 false;
                        }
                        break :blk2 true;
                    };
                    // A SINGLE-candidate top-level pick is equally
                    // scope-proven: there is no namesake whose shape the
                    // stamp could override, and skipping it strands a
                    // receiver lambda's `this` on the creation-time
                    // lexical receiver — `createTestResult { launch {…} }`
                    // bound the runner to the OUTER TestScope, whose
                    // dispatcher queues onto the very scheduler only the
                    // runner pumps, deadlocking every `runTest`.
                    const single_toplevel = blk2: {
                        const tl = b.module.func_name_index.get(name0) orelse break :blk2 false;
                        break :blk2 tl.items.len == 1 and tl.items[0] == fid;
                    };
                    if (member_pick or single_toplevel)
                        try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, off);
                    break :blk try argFnArities(b, f, args, ast_arg_names, off);
                }
            }
        }
        break :blk null;
    };
    // Lambda params still type from the RESOLVED extension hint on the
    // deferred form: `all { it.isWhitespace() }` inside `isBlank` defers
    // (the lazy-relower scope cannot prove the member-shadow negative),
    // but `kotlin.text.all`'s `predicate: (Char) -> Boolean` is the
    // engine's committed candidate, so `it` is Char exactly as on the
    // static path. Only the resolved hint is trusted — the
    // trailing-lambda namesake pick above stays arity/receiver-only (a
    // wrong namesake type stamp is worse than none).
    // A return-variant family discriminates by the trailing lambda's
    // derived return even when the resolution declined outright: the
    // picked fid rides the deferred CMG as a PINNED global leg — the
    // runtime re-rank runs the first-declared variant otherwise (the
    // Double sumOf, 3.0 where kotlinc prints 3).
    var ext_hint_final = false;
    if (allNull(ast_arg_names) and lastArgIsLambda(args)) {
        const pcands = try b.module.bareCallCandidates(b.allocator, name0, callee.Path.segments[0].span.file);
        defer b.allocator.free(pcands);
        if (try overloadPickByLambdaReturn(b, pcands, args, args.len)) |picked| {
            ext_hint = picked;
            ext_hint_final = true;
        }
    }
    const bare_recv_ref = b.recvTypeRef();
    const bare_lambda_param_types: ?[]?[]ir.TypeRef = blk: {
        const hint = ext_hint orelse break :blk null;
        const f = b.module.funcById(hint) orelse break :blk null;
        const off: usize = if (f.params.len != 0 and
            std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] unresolvedBare fn={s}\n", .{f.name});
        // The IMPLICIT receiver (the enclosing extension's declared
        // receiver, args included) instantiates the slot — `sumOf
        // { it.size.toLong() }` inside Array.flatten binds T2 :=
        // Array<out T>, so `it` types and the body binds statically.
        const recv_ptr: ?*const ir.TypeRef = if (off == 1)
            (if (bare_recv_ref) |*r| substitutionRecv(b, r) else null)
        else
            null;
        break :blk try argLambdaParamTypesRecv(b, f, args, ast_arg_names, ast_type_args, off, recv_ptr);
    };
    defer if (bare_lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = bare_lambda_param_types;
    if (runtime.envOnce("KLIO_ADM_TRACE") != null) {
        const f0 = if (ext_hint) |h| b.module.funcById(h) else null;
        std.debug.print("[ubc-lpt] {s} hint={?d} lpt={} p_last={s} p_last_args={d}\n", .{
            name0,
            if (ext_hint) |h| h.int() else null,
            bare_lambda_param_types != null,
            if (f0) |f| (if (f.params.len != 0) f.params[f.params.len - 1].ty.name else "-") else "?",
            if (f0) |f| (if (f.params.len != 0) f.params[f.params.len - 1].ty.args.len else 0) else 0,
        });
    }
    if (enclosingObjectDeclaring(b, name0, callee.Path.segments[0].span.file)) |obj_cid| {
        const obj_r = try loadObjectValue(b, obj_cid);
        const run = try lowerArgRunWithArity(b, args, bare_arity);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        orEmitAudit(b, "enclosing_object_member", "CallMember", name0);
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = obj_r,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .trailing_lambda = b.callTrailingLambda(),
        } });
        return dst;
    }
    if (b.resolve("this")) |this_reg| {
        const run = try lowerArgRunWithArity(b, args, bare_arity);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        try b.push(.{ .CallMemberOrGlobal = .{
            .dst = dst,
            .this_idx = 0,
            .name = nm,
            .trailing_lambda = b.callTrailingLambda(),
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .recv = this_reg,
            .func = ext_hint,
            .func_final = ext_hint_final,
            .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
            .static_recv = try cmgStaticRecv(b),
            .type_args = try helpers.internTypeArgsScoped(b, ast_type_args),
        } });
        return dst;
    }
    const this_idx = try b.recordCapture("this");
    const run = try lowerArgRunWithArity(b, args, bare_arity);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = this_idx,
        .name = nm,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .func = ext_hint,
        .func_final = ext_hint_final,
        .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
        .static_recv = try cmgStaticRecv(b),
        .type_args = try helpers.internTypeArgsScoped(b, ast_type_args),
    } });
    return dst;
}

/// Built-in stdlib companion shortcuts: `Result.success(x)`, `Result.failure(e)`.
pub fn lowerCompanionShortcut(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    if (callee.* != .Member) return null;
    const recv_box = callee.Member.receiver;
    const mname = callee.Member.name;
    if (recv_box.* != .Path or recv_box.Path.segments.len != 1) return null;
    const head = recv_box.Path.segments[0].name;
    if (b.resolve(head) != null or b.knowsOuter(head)) return null;

    const Shortcut = struct { cls: []const u8, method: []const u8, fqn: []const u8 };
    const shortcuts = [_]Shortcut{
        .{ .cls = "Result", .method = "success", .fqn = "kotlin.Result.Companion.success" },
        .{ .cls = "Result", .method = "failure", .fqn = "kotlin.Result.Companion.failure" },
    };
    for (shortcuts) |sc| {
        if (std.mem.eql(u8, head, sc.cls) and std.mem.eql(u8, mname.name, sc.method)) {
            const callee_r = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = sc.fqn });
            try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = n } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
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

/// Package-qualified constructor call: the dotted callee (`app.sub.Widget()`)
/// names a class by its fully-qualified name. Rewrite it to a bare constructor
/// call on the class's simple name so the ordinary class-name path constructs
/// it — otherwise the member fallback reads the package head as a field of the
/// implicit receiver. Only fires when the head is genuinely a package (not a
/// local/captured/enclosing-member in scope) and the FQN names a class.
pub fn lowerFqnCtorCall(b: *FuncBuilder, expr: *const Expr) Allocator.Error!?Reg {
    const callee = expr.Call.callee;
    const fqn = (try collectDottedFqn(b.allocator, callee)) orelse return null;
    defer b.allocator.free(fqn);
    const tail = rsplitLast(fqn, '.');
    if (std.mem.eql(u8, tail, fqn)) return null; // not dotted
    const cid = b.module.classIdByFqn(fqn) orelse return null; // FQN is not a class
    const head = firstSegment(fqn);
    // The head must be a real package the reference qualifies through, not a
    // name that resolves in scope (which would be a member/local access).
    if (!headIsPackage(b, head)) return null;
    if (b.resolve(head) != null or b.knowsOuter(head) or b.hasEnclosingMember(head)) return null;
    if (b.module.classId(head) != null) return null; // head names a class: nested-class path handles it
    // Construct the EXACT class the FQN names. Rewriting to the bare simple
    // name and re-lowering would re-resolve it by simple name and pick the
    // first same-named class from another package (`gapbuffer.SlotTable` vs
    // `linkbuffer.SlotTable`) — the package qualifier must decide.
    const args = expr.Call.args;
    const ast_arg_names = expr.Call.arg_names;
    const ctor_arity = try ctorArgFnArities(b, cid, args, ast_arg_names);
    defer if (ctor_arity) |ca| b.allocator.free(ca);
    const run = try lowerArgRunFull(b, args, ctor_arity, null);
    const realigned = try ctorRealignedArgNames(b, cid, args, ast_arg_names);
    defer if (realigned) |r| b.allocator.free(r);
    const arg_names = try internArgNames(b.allocator, b.module, realigned orelse ast_arg_names);
    const dst = b.allocReg();
    try b.push(.{ .NewInstance = .{
        .dst = dst,
        .class = cid,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .arg_static_heads = try ctorArgStaticHeads(b, args),
    } });
    return dst;
}

/// Package-qualified call to a user / pack top-level function (FQN flatten).
pub fn lowerFqnFlattenCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
) Allocator.Error!?Reg {
    const fqn = (try collectDottedFqn(b.allocator, callee)) orelse return null;
    defer b.allocator.free(fqn);
    const head = firstSegment(fqn);
    const tail = rsplitLast(fqn, '.');
    const head_is_real_pkg = isPkgRoot(head);
    if (std.mem.eql(u8, tail, fqn)) return null;
    if (isPackageHead(head) and
        headIsPackage(b, head) and
        b.resolve(head) == null and
        !b.knowsOuter(head) and
        !b.hasOwnMember(head) and
        !b.hasEnclosingMember(head) and
        b.module.classId(head) == null and
        (head_is_real_pkg or !isTopLevelProp(head)) and
        (head_is_real_pkg or b.resolve("this") == null))
    {
        const want = args.len;
        const cands = b.module.funcsBySimpleName(tail);
        // A fully-qualified callee binds the one declaration whose FQN
        // matches exactly. It must never fall back to a same-tail-named
        // function in another package (a user `println` cannot answer a
        // `kotlin.io.println` call) — when no lowered declaration owns the
        // FQN the call belongs to global/intrinsic resolution, so decline
        // the flatten and let `lowerFqnGlobalCall` load it by FQN.
        var pick: ?FuncId = null;
        var fqn_arity_matches: usize = 0;
        for (cands) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            if (std.mem.eql(u8, f.fqn, fqn) and f.params.len == want) {
                // A vararg declaration's param count is not an exact arity
                // (`remember(vararg keys, calc)` at 4 params ties the
                // 1-key fixed overload); Kotlin prefers the fixed-arity
                // declaration, so only those count as exact here.
                var has_vararg = false;
                for (f.params) |p| {
                    if (p.is_vararg) {
                        has_vararg = true;
                        break;
                    }
                }
                if (has_vararg) continue;
                if (pick == null) pick = fid;
                fqn_arity_matches += 1;
            }
        }
        // A UNIQUE FQN+arity match is THE target, so the call is EXACT —
        // the runtime overload re-pick ranks across every same-simple-name
        // candidate in the program, and a user fn with a more specific
        // parameter type would hijack the qualified call (a user
        // `synchronized(lock: Lock, block)` delegating to
        // `kotlin.synchronized` re-picked back to ITSELF and recursed).
        // Same-arity FQN overloads stay ambiguous here and fall to the
        // shape-checked arm below.
        if (fqn_arity_matches == 1) {
            const func_id = pick.?;
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
            const dst = b.allocReg();
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .trailing_lambda = b.callTrailingLambda(),
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
                .type_args = type_args,
                .exact = true,
            } });
            return dst;
        }
    }
    return null;
}

/// Fully-qualified callee resolved as a global, CallValue.
pub fn lowerFqnGlobalCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const fqn = (try collectDottedFqn(b.allocator, callee)) orelse return null;
    defer b.allocator.free(fqn);
    const head = firstSegment(fqn);
    const head_is_real_pkg = isPkgRoot(head);
    // A fully-qualified property access followed by a member call
    // (`kotlin.math.PI.toFloat()`): the prefix names a top-level property, so
    // the call is a member call on that property's value, not a global
    // function whose FQN is the whole dotted path. Decline and let the
    // member-call fallback lower the property load + `CallMember`.
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| {
        const prefix = fqn[0..dot];
        const prefix_name = rsplitLast(prefix, '.');
        // A single-segment prefix that scope binds first (a local, an own or
        // enclosing member, a receiver's member, the smart-cast `this`'s
        // member) is that binding, not the same-named top-level property,
        // whose qualified name equals its simple name in the default package:
        // `items.sum()` inside `is Wrapper ->` read the global `items`.
        if (std.mem.indexOfScalar(u8, prefix, '.') == null and !head_is_real_pkg) {
            const pfile = exprSpan(callee).file;
            if (b.resolve(prefix) != null or b.knowsOuter(prefix) or b.hasOwnMember(prefix) or
                b.hasEnclosingMember(prefix) or narrowedThisDeclares(b, prefix, pfile) or
                (inReceiverContext(b) and anyReceiverClassDeclares(b, prefix)))
            {
                return null;
            }
        }
        // The suspend-intrinsic property has no registry row of its own; a
        // qualified call through it (`kotlin.coroutines.coroutineContext
        // .cancel()`) is a member call on the property's value exactly like
        // the registered-property case below.
        const intrinsic_prop = std.mem.eql(u8, prefix, "kotlin.coroutines.coroutineContext");
        if (b.module.topLevelPropFqn(prefix_name) orelse
            (if (intrinsic_prop) @as(?[]const u8, prefix) else null)) |pfqn|
        {
            if (std.mem.eql(u8, pfqn, prefix)) {
                // Load the property value by its package-qualified FQN, then
                // member-call the trailing segment on it.
                const recv = b.allocReg();
                const pn = try b.module.internConst(b.allocator, .{ .String = prefix });
                try b.push(.{ .LoadGlobal = .{ .dst = recv, .name = pn } });
                const last = fqn[dot + 1 ..];
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                const mname = try b.module.internConst(b.allocator, .{ .String = last });
                try b.push(.{ .CallMember = .{
                    .dst = dst,
                    .receiver = recv,
                    .name = mname,
                    .trailing_lambda = b.callTrailingLambda(),
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
    }
    if (isPackageHead(head) and
        headIsPackage(b, head) and
        b.resolve(head) == null and
        !b.knowsOuter(head) and
        !b.hasOwnMember(head) and
        !b.hasEnclosingMember(head) and
        b.module.classId(head) == null and
        (head_is_real_pkg or !isTopLevelProp(head)) and
        (head_is_real_pkg or b.resolve("this") == null))
    {
        // An exact-FQN name can cover a whole OVERLOAD SET
        // (`kotlin.test.assertTrue` is (Boolean, String?) AND (String?,
        // () -> Boolean)); the runtime value load binds the first by
        // declaration order regardless of the call's arguments. With the
        // arguments in hand, bind the UNIQUE overload whose declared
        // signature the argument shapes fit; only an undecidable tie keeps
        // the value-call fallback.
        {
            const last = rsplitLast(fqn, '.');
            const shapes = try buildArgShapes(b, args, ast_arg_names);
            defer b.allocator.free(shapes);
            var only: ?FuncId = null;
            var fit_count: usize = 0;
            var fqn_overloads: usize = 0;
            for (b.module.funcsBySimpleName(last)) |fid| {
                const f = b.module.funcById(fid) orelse continue;
                if (!std.mem.eql(u8, f.fqn, fqn)) continue;
                if (!f.hasBody()) continue;
                if (f.low_priority) continue;
                fqn_overloads += 1;
                if (!fqnCallArityFits(b, fid, args.len)) continue;
                if (!b.module.declSigCompatible(fid, shapes)) continue;
                only = fid;
                fit_count += 1;
                if (fit_count > 1) break;
            }
            if (fqn_overloads > 1 and fit_count == 1) {
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                try b.push(.{ .Call = .{
                    .dst = dst,
                    .func = only.?,
                    .trailing_lambda = b.callTrailingLambda(),
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                    .type_args = &.{},
                    .exact = false,
                } });
                return dst;
            }
        }
        const callee_r = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = fqn });
        try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = n } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
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

/// Whether `fid` can take `want` positional args: at least the required
/// (non-defaulted, non-vararg) count, at most the declared total unless a
/// vararg absorbs the excess.
fn fqnCallArityFits(b: *FuncBuilder, fid: FuncId, want: usize) bool {
    const arity = b.module.decl_user_arity.get(fid.int()) orelse return false;
    if (want < arity.required) return false;
    return arity.has_vararg or want <= arity.total;
}
