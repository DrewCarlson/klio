//! Lambda and anonymous function lowering, and the function-type shape
//! probes that bind their parameters.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const decl_mod = @import("../decl.zig");
const lambda_body = @import("../lambda_body.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const Func = ir.Func;
const TypeRef = ir.TypeRef;
const exprSpan = helpers.exprSpan;
const lowerLambdaBodyCapturingKind = lambda_body.lowerLambdaBodyCapturingKind;
const resolveCapture = lambda_body.resolveCapture;
const EnclosingOwner = lambda_body.EnclosingOwner;

const expr_mod = @import("../expr.zig");

const binary_mod = @import("binary.zig");
const isPrimitiveTypeName = binary_mod.isPrimitiveTypeName;

const paths_mod = @import("paths.zig");
const loweredOwnedLocalTypeRef = paths_mod.loweredOwnedLocalTypeRef;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;

const static_type_mod = @import("static_type.zig");
const staticExprTypeRef = static_type_mod.staticExprTypeRef;
const staticTypeClassId = static_type_mod.staticTypeClassId;

const type_probe_mod = @import("type_probe.zig");
const buildStaticReturnArgShapes = type_probe_mod.buildStaticReturnArgShapes;
const simpleTypeHead = type_probe_mod.simpleTypeHead;

const probe_mod = @import("probe.zig");
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const eagerLambdaRecvHead = probe_mod.eagerLambdaRecvHead;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const orAuditOn = audit_mod.orAuditOn;

const expected_mod = @import("expected.zig");
const applyExpectedLiteralKindsToArgs = expected_mod.applyExpectedLiteralKindsToArgs;

const block_mod = @import("block.zig");
const rsplitLast = block_mod.rsplitLast;

pub fn lowerLambda(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const lam = expr.Lambda;
    const eager_shape = b.module.eagerParamShapeOf(lam.body.span);
    const recorded_recv = b.lambdaArgRecv(expr.span());
    var expected_recv_owned: ?ir.TypeRef = null;
    defer if (expected_recv_owned) |receiver| {
        var cleanup = receiver;
        cleanup.deinit(b.allocator);
    };
    const expected_recv: ?ir.TypeRef = blk: {
        if (b.peekExpected()) |exp| {
            if (exp.function) |ft| {
                if (ft.receiver) |*receiver| {
                    expected_recv_owned = try loweredOwnedLocalTypeRef(b, receiver);
                    break :blk expected_recv_owned.?;
                }
            }
        }
        break :blk null;
    };
    const expected_shape_known = if (b.peekExpected()) |exp|
        exp.function != null
    else
        false;
    const receiver_type = recorded_recv orelse expected_recv;
    const receiver_head = if (receiver_type) |receiver|
        receiver.name
    else
        b.module.eagerRecvHeadOf(lam.body.span);
    const lambda_receiver_shape_known = expected_shape_known or
        recorded_recv != null or eager_shape != null;
    const lambda_has_receiver = receiver_head != null or
        (eager_shape != null and eager_shape.?.has_receiver);
    b.module.pending_lambda_no_receiver = lambda_receiver_shape_known and !lambda_has_receiver;
    // Consume the per-argument expected lambda arity set by the call
    // lowering for this argument slot before the body recurses (which
    // re-arms it for the body's own nested calls).
    var expected_arity = b.pending_lambda_arity;
    b.pending_lambda_arity = -1;
    // Broad-collection mask for this lambda's params (set by the call lowering
    // from the callee parameter's function type). Consumed before the body
    // recurses so a nested lambda does not inherit it.
    const lambda_broad_mask = b.pending_lambda_broad_mask;
    b.pending_lambda_broad_mask = 0;
    // Callee-generic slot flag: the expected function type's parameters are
    // all the callee's own type parameters, so this lambda's params carry
    // Kotlin's generic static typing. Consumed the same way.
    const lambda_fn_generic = b.pending_ref_fn_generic;
    b.pending_ref_fn_generic = false;
    // A lambda assigned to a typed binding (`val h: Ctx.() -> Unit = { … }`)
    // never reaches the call-argument arity path; derive the arity from the
    // binding's functional type so a `T.() -> R` receiver lambda (zero value
    // parameters) drops its `it` and resolves bare members through the
    // receiver bound at invocation, rather than a spurious `it` parameter.
    // The arity recorded at the call site (by span), authoritative when the
    // per-argument `pending_lambda_arity` was not set on this emit path.
    var arity_src: []const u8 = "pending";
    if (expected_arity == -1) {
        if (b.lambdaArgArity(expr.span())) |ar| {
            expected_arity = ar;
            arity_src = "callsite";
        }
    }
    if (expected_arity == -1) {
        if (b.peekExpected()) |exp| {
            if (exp.function) |ft| {
                expected_arity = @intCast(ft.params.len);
                arity_src = "expected";
            }
        }
    }
    // Last resort: typeck's own answer for this lambda, keyed by its body span.
    // The AST-side sources above all need the callee's signature, which a
    // CROSS-PACK member call does not have — the callee is absent from the
    // lowering module's name index (`onDrawWithContent { … }` on a
    // `CacheDrawScope` declared in another pack). Typeck resolved the expected
    // type across packs, so it knows the value arity even when the lowering
    // cannot see the declaration.
    if (expected_arity == -1) {
        if (eager_shape) |shape| {
            expected_arity = @intCast(shape.arity);
            arity_src = if (shape.has_receiver) "eager-recv" else "eager-plain";
        }
    }
    // A zero-`->` lambda gets its implicit `it` only when its own
    // functional type takes exactly one parameter. A `() -> R` and a
    // `T.() -> R` receiver lambda both encode arity 0, so the
    // parser-injected `it` is dropped and an `it` reference inside resolves
    // to the nearest enclosing lambda's `it` (or is rejected when none
    // exists). Suppression applies only to the arity-0 shapes; an unknown
    // arity (-1, an unconstrained value position) keeps the single-`it`
    // binding unchanged.
    const suppress_it = lam.implicit_it and expected_arity == 0;
    if (orAuditOn() and lam.implicit_it)
        std.debug.print("[IT-AUDIT] lambda f{d}:{d}..{d} expected_arity={d} src={s} suppress={}\n", .{ lam.body.span.file.int(), lam.body.span.start, lam.body.span.end, expected_arity, arity_src, suppress_it });
    const eff_params: []const ast.Ident = if (suppress_it) &.{} else lam.params;
    const eff_param_tys: []const ?ast.TypeRef = if (suppress_it) &.{} else lam.param_tys;
    // Names of lambda params (including the implicit `it`) whose effective
    // static type — the lambda's own annotation, else the expected functional
    // type's parameter — is a broad collection (`Iterable`/`Collection`).
    // Recorded on the body builder so `it + x` over a runtime `Set` produces a
    // `List`. Derived here (not via the body's `param_tys`) so the implicit
    // `it`'s runtime overload-dispatch placeholder type is left untouched.
    var broad_names: std.ArrayList([]const u8) = .empty;
    defer broad_names.deinit(b.allocator);
    if (!suppress_it and eff_params.len != 0) {
        const ft = if (b.peekExpected()) |exp| exp.function else null;
        for (eff_params, 0..) |p, i| {
            const ty: ?ast.TypeRef = if (i < eff_param_tys.len and eff_param_tys[i] != null)
                eff_param_tys[i]
            else if (ft != null and i < ft.?.params.len)
                ft.?.params[i]
            else
                null;
            const by_ty = ty != null and ty.?.function == null and helpers.isBroadCollectionTypeName(ty.?.name.name);
            // Also honor the callee-parameter mask: a call-argument lambda has
            // no expected functional type on the stack, so its `it`'s declared
            // `Iterable` type lives only in the callee's parameter signature.
            const by_mask = i < 32 and (lambda_broad_mask >> @intCast(i)) & 1 != 0;
            if (by_ty or by_mask) {
                try broad_names.append(b.allocator, p.name);
            }
        }
    }
    // Params of a callee-generic slot (unannotated only — an explicit
    // annotation is the stronger static fact and wins).
    var generic_names: std.ArrayList([]const u8) = .empty;
    defer generic_names.deinit(b.allocator);
    if (lambda_fn_generic and !suppress_it) {
        for (eff_params, 0..) |p, i| {
            const annotated = i < eff_param_tys.len and eff_param_tys[i] != null;
            if (!annotated) try generic_names.append(b.allocator, p.name);
        }
    }
    // `outer_names` / `inherited_rlp` ownership passes into the lambda lower.
    const outer_names = try b.visibleNames();
    const inherited_rlp = try b.receiverLambdaParamNames();
    try b.stashRecvHeadsForLambda();
    var outer_boxed = try b.boxedVarsSnapshot();
    defer outer_boxed.deinit();
    const enclosing_owner = try enclosingOwnerFor(b);

    const inherited_lef = try b.localExtFnNames();
    const inherited_erp = try b.erasedRecvParamNames();
    // The implicit label this lambda carries (`runTest { … }` → "runTest").
    // The body binds `this@<label>` to its receiver.
    b.module.pending_lambda_this_label = b.pending_lambda_label;
    // The receiver type in scope at the body's site: a receiver lambda
    // (`T.() -> R`) rebinds the implicit `this` to `T`, otherwise a plain
    // block captures the enclosing `this`. Carried into the body so a bare
    // call there can still disambiguate a receiver-lambda argument's arity.
    // A receiver-lambda ARGUMENT whose receiver type the resolved callee made
    // concrete (recorded by `recordLambdaArgReceivers`) — reached when the
    // call is deferred so no expected type carries the receiver to lowerLambda.
    b.module.pending_lambda_receiver_tower = try b.collectReceiverTowerLabeled(
        b.allocator,
        receiver_head,
        b.pending_lambda_label,
    );
    b.module.pending_lambda_enclosing_recv = blk: {
        if (receiver_head) |rr| break :blk rr;
        break :blk b.enclosingRecvTy();
    };
    // The body owns that receiver as its extension receiver, so a bare call
    // there prefers an extension on it over a same-file plain namesake —
    // `validate { contact(c) }` binds `MockViewValidator.contact`, not the
    // same-file `@Composable contact`.
    if (std.c.getenv("KLIO_LAR_TRACE") != null) {
        std.debug.print("[lar-stash] s={d}..{d} head={s} ty={s}\n", .{ expr.span().start, expr.span().end, receiver_head orelse "-", if (receiver_type) |r| r.name else "-" });
    }
    if (receiver_head) |rr| b.module.pending_lambda_own_recv = rr;
    if (receiver_type) |receiver| {
        b.module.pending_lambda_own_recv_type = try receiver.clone(b.allocator);
    }
    b.module.pending_lambda_unit = b.pending_ref_lambda_unit;
    if (!suppress_it) {
        if (b.pending_ref_lambda_param_types) |types| {
            const value_param_count: usize = if (lam.implicit_it and
                eff_params.len == 0) 1 else eff_params.len;
            const count = @min(types.len, value_param_count);
            const owned = try b.allocator.alloc(ir.TypeRef, count);
            var initialized: usize = 0;
            errdefer {
                for (owned[0..initialized]) |*ty| ty.deinit(b.allocator);
                b.allocator.free(owned);
            }
            for (types[0..count], owned) |src, *dst| {
                dst.* = try src.clone(b.allocator);
                initialized += 1;
            }
            b.module.pending_lambda_param_types = owned;
        }
    }
    // Carry the enclosing non-reified type-parameter names so an `x as T`
    // cast inside the lambda body is still erased.
    b.module.pending_lambda_type_params = try b.typeParamNamesSlice();
    b.module.pending_lambda_reified_names = try b.reifiedTypeNamesSlice();
    b.module.pending_lambda_type_param_bounds = try b.typeParamBoundsSlice();
    b.module.pending_lambda_type_param_bound_refs = try b.typeParamBoundRefsSlice();
    b.module.pending_lambda_ctx_fn_shapes = try b.contextFnShapesSlice();
    // A lambda inside a local fn's body keeps that fn's self-identity (a
    // named local fn overrides this with its own before its body lowers).
    if (b.module.pending_lambda_self_fn == null) b.module.pending_lambda_self_fn = b.selfLocalFn();
    // Non-callable-local evidence flows into the body (transitively — this
    // builder's set already includes what it inherited).
    b.module.pending_lambda_nonfn_locals = try b.nonFnLocalNames();
    b.module.pending_lambda_local_decl_types = try b.localDeclTypesSnapshot();
    if (std.c.getenv("KLIO_LAMINH") != null) std.debug.print("[laminh] produce lambda b={x} n={d}\n", .{ @intFromPtr(b) & 0xffff, b.localDeclTypeCount() });
    // Fold ACTIVE inline-splice param types into the snapshot: a nested
    // closure inside a spliced body captures the callee's parameter by
    // name (`destination.add(it)` inside `transform(element)?.let { ... }`
    // spliced from mapNotNullTo), and the local-decl snapshot never saw
    // the splice channel.
    if (b.module.pending_lambda_local_decl_types) |*locals| {
        var sp_it = b.spliceParamTyIterator();
        while (sp_it.next()) |e| {
            if (locals.types.contains(e.key_ptr.*)) continue;
            const lowered_ty = try decl_mod.loweredTypeRef(b.allocator, e.value_ptr, true);
            try locals.types.put(e.key_ptr.*, lowered_ty);
        }
        // Pre-derive the lazily-typed outer locals INTO the snapshot: a
        // closure capturing `val iterator = listIterator(size)` sees only
        // an on-demand derivation that cannot run in the closure's scope.
        // Deriving here runs in the OUTER builder — the only scope the
        // initializer was written in — and the closure inherits a plain
        // declared type.
        var init_it = b.localInitExprIterator();
        while (init_it.next()) |e| {
            if (locals.types.contains(e.key_ptr.*)) continue;
            const prev_self = expr_mod.init_self_name;
            if (b.localInitNameFree(e.key_ptr.*)) expr_mod.init_self_name = e.key_ptr.*;
            // The FULL deriver, not just the call-return channel: a literal
            // or member-read init crosses the capture boundary too
            // (`var result = 0` read inside the repeat lambda).
            const derived = staticExprTypeRef(b, e.value_ptr.*) catch null;
            expr_mod.init_self_name = prev_self;
            if (derived) |ty| try locals.types.put(e.key_ptr.*, ty);
        }
    }
    const lowered = try lambda_body.lowerLambdaBodyCapturingKindWithIt(
        b.module,
        eff_params,
        eff_param_tys,
        &lam.body,
        outer_names,
        true,
        &outer_boxed,
        null,
        false,
        false,
        inherited_rlp,
        inherited_lef,
        inherited_erp,
        &b.local_fn_overloads,
        enclosing_owner,
        suppress_it,
        if (suppress_it) lam.span else null,
        broad_names.items,
        generic_names.items,
    );
    const body_func = lowered.func;
    const captured_names = lowered.captures;
    if (b.module.funcByIdMut(body_func)) |f| {
        f.lambda_receiver_shape_known = lambda_receiver_shape_known;
        f.lambda_has_receiver = lambda_has_receiver;
        f.lambda_it_unconstrained = lam.implicit_it and expected_arity == -1;
        // The receiver HEAD is this lambda's OWN derivation — the body
        // builder's recvTy can carry the ENCLOSING lambda's receiver (a
        // placement block nested in a measure lambda recorded
        // "MeasureScope"), and the runtime's compatibility receiver
        // inference then re-selects a chain value satisfying the wrong
        // head, silently swapping the invoke's real receiver (the
        // coordinator displaced the PlacementScope and every placement
        // pass lost its member-extension owner). When the shape is known,
        // record exactly the derived head — or null for a plain lambda,
        // which disables re-selection and keeps the passed receiver.
        if (lambda_receiver_shape_known) {
            f.lambda_receiver_ty = if (receiver_head) |h| try b.allocator.dupe(u8, h) else null;
        }
    }

    // Record the implicit label.
    if (b.pending_lambda_label) |label| {
        b.pending_lambda_label = null;
        if (b.module.funcByIdMut(body_func)) |f| {
            f.implicit_label = label;
        }
    }
    // A `suspend { … }` literal: the body is a suspend function value.
    if (b.pending_suspend_lambda) {
        b.pending_suspend_lambda = false;
        if (b.module.funcByIdMut(body_func)) |f| {
            f.is_suspend = true;
        }
    }
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *c| c.* = try resolveCapture(b, n);

    const param_names = if (suppress_it)
        try b.allocator.alloc([]const u8, 0)
    else
        try lambdaParamNames(b.allocator, lam.params);
    const body_ast = lam.body;
    const dst = b.allocReg();
    try b.push(.{ .AstLambda = .{
        .dst = dst,
        .params = param_names,
        .body_ast = body_ast,
        .captures = captures,
        .captured_names = captured_names,
        .absorb_return = false,
        .body_func = body_func,
    } });
    return dst;
}

pub fn lowerAnonFun(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const af = expr.AnonFun;
    const receiver_head: ?[]const u8 = if (af.receiver_ty) |r| r.name.name else null;
    const body_block: ast.Block = blk: {
        if (af.body) |body| {
            switch (body.*) {
                .Block => |bl| break :blk bl,
                .Expr => |e| {
                    const stmts = try b.allocator.alloc(ast.Stmt, 1);
                    stmts[0] = .{ .Expr = e };
                    break :blk .{ .stmts = stmts, .span = exprSpan(expr) };
                },
            }
        }
        break :blk .{ .stmts = &.{}, .span = exprSpan(expr) };
    };
    const param_names = try b.allocator.alloc([]const u8, af.params.len);
    const param_idents = try b.allocator.alloc(ast.Ident, af.params.len);
    defer b.allocator.free(param_idents);
    const param_tys = try b.allocator.alloc(?ast.TypeRef, af.params.len);
    defer b.allocator.free(param_tys);
    for (af.params, param_names, param_idents, param_tys) |p, *pn, *pi, *pt| {
        pn.* = p.name.name;
        pi.* = p.name;
        pt.* = p.ty;
    }
    // `outer_names` / `inherited_rlp` ownership passes into the lambda lower.
    const outer_names = try b.visibleNames();
    const inherited_rlp = try b.receiverLambdaParamNames();
    try b.stashRecvHeadsForLambda();
    var outer_boxed = try b.boxedVarsSnapshot();
    defer outer_boxed.deinit();
    const enclosing_owner = try enclosingOwnerFor(b);

    const inherited_lef = try b.localExtFnNames();
    const inherited_erp = try b.erasedRecvParamNames();
    b.module.pending_lambda_receiver_tower = try b.collectReceiverTowerLabeled(b.allocator, receiver_head, null);
    if (receiver_head) |head| {
        b.module.pending_lambda_enclosing_recv = head;
        b.module.pending_lambda_own_recv = head;
    }
    if (af.receiver_ty) |*receiver| {
        b.module.pending_lambda_own_recv_type = try loweredOwnedLocalTypeRef(b, receiver);
    }
    b.module.pending_lambda_nonfn_locals = try b.nonFnLocalNames();
    b.module.pending_lambda_local_decl_types = try b.localDeclTypesSnapshot();
    if (std.c.getenv("KLIO_LAMINH") != null) std.debug.print("[laminh] produce anonfun b={x} n={d}\n", .{ @intFromPtr(b) & 0xffff, b.localDeclTypeCount() });
    if (af.context_params.len != 0) b.module.pending_lambda_ctx_params = af.context_params;
    const lowered = try lowerLambdaBodyCapturingKind(
        b.module,
        param_idents,
        param_tys,
        &body_block,
        outer_names,
        false,
        &outer_boxed,
        null,
        inherited_rlp,
        inherited_lef,
        inherited_erp,
        enclosing_owner,
    );
    const captured_names = lowered.captures;
    if (b.module.funcByIdMut(lowered.func)) |f| {
        f.lambda_receiver_shape_known = true;
        f.lambda_has_receiver = receiver_head != null;
    }
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *c| c.* = try resolveCapture(b, n);
    const dst = b.allocReg();
    try b.push(.{ .AstLambda = .{
        .dst = dst,
        .params = param_names,
        .body_ast = body_block,
        .captures = captures,
        .captured_names = captured_names,
        .absorb_return = true,
        .body_func = lowered.func,
    } });
    return dst;
}

/// Build the lexically enclosing class context handed to a lambda body.
fn enclosingOwnerFor(b: *FuncBuilder) Allocator.Error!?EnclosingOwner {
    if (b.ownerClass()) |o| {
        return EnclosingOwner{ .class = o, .members = try b.enclosingMembersForChild() };
    }
    return null;
}

fn lambdaParamNames(allocator: Allocator, params: []const ast.Ident) Allocator.Error![][]const u8 {
    if (params.len == 0) {
        const out = try allocator.alloc([]const u8, 1);
        out[0] = "it";
        return out;
    }
    const out = try allocator.alloc([]const u8, params.len);
    for (params, out) |p, *o| o.* = p.name;
    return out;
}

/// The non-receiver parameter count encoded in a lowered function-type
/// head (`Function{N}` from `decl.loweredTypeRef`), or null when the type
/// is not a function type. A `T.() -> R` receiver lambda and a `() -> R`
/// lambda both encode `Function0`; a `(T) -> R` lambda encodes `Function1`.
fn fnTypeArity(ty: ir.TypeRef) ?i16 {
    const head = ty.name;
    if (!std.mem.startsWith(u8, head, "Function")) return null;
    const digits = head["Function".len..];
    if (digits.len == 0) return null;
    const n = std.fmt.parseInt(i16, digits, 10) catch return null;
    return n;
}

/// A function-typed parameter whose declared return is `Unit`: the
/// `Function{N}` tag's trailing type argument (before any `#` markers).
fn fnTypeReturnsUnit(b: *FuncBuilder, ty: ir.TypeRef) bool {
    if (fnTypeArityAlias(b, ty) == null) return false;
    var hi = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    if (hi == 0) return false;
    const ret = ty.args[hi - 1];
    return (std.mem.eql(u8, ret.name, "Unit") or std.mem.eql(u8, ret.name, "kotlin.Unit")) and !ret.nullable;
}

/// `fnTypeArity` resolving an aliased function-typed parameter
/// (`RoutingHandler = RoutingContext.() -> Unit` → `Function0`) through the
/// typealias registry before reading the `Function{N}` tag.
pub fn fnTypeArityAlias(b: *FuncBuilder, ty: ir.TypeRef) ?i16 {
    if (fnTypeArity(ty)) |n| return n;
    if (b.module.registry.type_aliases.get(ty.name)) |resolved| {
        if (std.mem.startsWith(u8, resolved, "Function")) {
            const digits = resolved["Function".len..];
            if (digits.len != 0) return std.fmt.parseInt(i16, digits, 10) catch null;
        }
    }
    return null;
}

/// Per-argument expected lambda arity for a call dispatched to the
/// resolved runtime `func`, parallel to `args`. Each entry is the
/// non-receiver parameter count of the matching parameter's function type,
/// or `-1` when the parameter is not a function type or cannot be aligned.
/// `recv_offset` skips a leading implicit `this` parameter (member /
/// extension calls). Positional alignment only: a named or spread argument
/// list yields all-unknown so a misaligned guess never suppresses an `it`.
/// The extension overload named `name` that hosts a trailing lambda for a
/// call of `user_arg_count` arguments: an extension (leading `this`) whose
/// last parameter is function-typed and whose non-receiver arity equals
/// `user_arg_count`. The bare-call heuristic resolves one FuncId by
/// declaration order, which for an overloaded name (`get` — `List.get`,
/// `Map.get`, `Route.get(path, body)`) may not be the overload the trailing
/// lambda lands on; the per-argument arity readout must read the lambda's
/// expected arity from the hosting overload so a `T.() -> R` handler drops
/// its synthetic `it`.
/// Whether `f`'s trailing function-typed parameter declares more
/// parameters than the call's trailing lambda supplies, leaving a reified
/// type parameter that appears in that lambda-parameter list unbound. Used
/// to reject a reified inline overload a bare/underfilled lambda cannot
/// instantiate (`post<reified R>(path, RoutingContext.(R) -> Unit)` for a
/// zero-parameter handler). Conservative: only fires when the last
/// parameter resolves to a function type whose arity exceeds the lambda's.
pub fn reifiedNeedsLambdaArity(b: *FuncBuilder, f: *const ast.Function, lambda_arity: usize) bool {
    if (f.params.len == 0) return false;
    const ty = f.params[f.params.len - 1].ty;
    const fn_arity: usize = blk: {
        if (ty.function) |ft| break :blk ft.params.len;
        const tag = b.module.registry.type_aliases.get(ty.name.name) orelse return false;
        if (!std.mem.startsWith(u8, tag, "Function")) return false;
        break :blk std.fmt.parseInt(usize, tag["Function".len..], 10) catch return false;
    };
    return fn_arity > lambda_arity;
}

/// Whether any same-named lowered candidate is an extension whose value-
/// parameter shape can bind this call's argument count through an implicit
/// receiver — `to(x)` inside a class is `this.to(x)`, so the receiver-bound
/// candidate keeps the bare call on the member/extension dispatch path. The
/// host global serves the call only when no receiver-bound binding is
/// possible (no such candidate, or none fits the arity: `iterator { … }`
/// against the zero-arg `Map.iterator()` family).
pub fn extensionCandidateFitsArity(b: *FuncBuilder, name: []const u8, user_arg_count: usize) bool {
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        const user_params = f.params.len - 1;
        var required: usize = 0;
        var has_vararg = false;
        for (f.params[1..]) |*p| {
            if (p.is_vararg) {
                has_vararg = true;
                continue;
            }
            if (!p.has_default) required += 1;
        }
        if (has_vararg) {
            if (user_arg_count >= required) return true;
        } else if (user_arg_count >= required and user_arg_count <= user_params) {
            return true;
        }
    }
    return false;
}

/// The class MEMBER that hosts a trailing lambda for a bare call, reached
/// owner-scoped through `member_method_fids`. `Module.func_name_index` indexes
/// only TOP-LEVEL functions, so a bare call to a member (`onDrawWithContent { … }`
/// inside a `CacheDrawScope` extension) could not reach its signature at lower
/// time: the trailing lambda's expected arity came back unknown and a
/// `T.() -> R` receiver lambda kept the parser's synthetic `it`, which then
/// swallowed the receiver at invocation.
///
/// The candidate classes are the enclosing owner and the declared extension
/// receiver, each walked up its supertype chain — the member may be declared on
/// a supertype of the receiver we are lowering against.
pub fn memberHostingTrailingLambda(b: *FuncBuilder, name: []const u8, user_arg_count: usize) ?FuncId {
    const mhtl_trace = if (runtime.envOnce("KLIO_MISS_TRACE")) |w| std.mem.eql(u8, w, name) else false;
    var roots: [2]?[]const u8 = .{ b.ownerClass(), null };
    if (b.recvTy()) |rt| roots[1] = rsplitLast(rt, '.');
    if (mhtl_trace) std.debug.print("[mhtl] {s}: owner={?s} recv_root={?s} argc={d}\n", .{ name, roots[0], roots[1], user_arg_count });
    for (roots) |root_opt| {
        const root = root_opt orelse continue;
        // The class itself, then its transitive supertype names (nearest first).
        const supers: []const []const u8 = b.module.registry.class_super_names.get(root) orelse &.{};
        var i: usize = 0;
        while (i < 1 + supers.len) : (i += 1) {
            const cls = if (i == 0) root else supers[i - 1];
            const prefix = std.fmt.allocPrint(b.allocator, "{s}\x00{s}\x00", .{ cls, name }) catch return null;
            defer b.allocator.free(prefix);
            var found: ?FuncId = null;
            var found_arity: ?i16 = null;
            var found_recv: ?[]const u8 = null;
            var it = b.module.registry.member_method_fids.iterator();
            while (it.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
                const fid = entry.value_ptr.*;
                const f = b.module.funcById(fid) orelse continue;
                const hosts = memberHostsTrailingLambdaAtArity(b, cls, f, fid, user_arg_count);
                if (mhtl_trace) std.debug.print("[mhtl] {s}: cls={s} cand #{d} params={d} hosts={} last_ty={s} last_arity={?d}\n", .{ name, cls, fid.int(), f.params.len, hosts, if (f.params.len != 0) f.params[f.params.len - 1].ty.name else "-", if (f.params.len != 0) fnTypeArityAlias(b, f.params[f.params.len - 1].ty) else null });
                if (!hosts) continue;
                const last = f.params[f.params.len - 1];
                const arity = fnTypeArityAlias(b, last.ty) orelse continue;
                const recv = fnTypeReceiverHead(b, last.ty);
                if (found_arity) |fa| {
                    if (fa != arity or !optionalStringEql(found_recv, recv)) return null;
                } else {
                    found = fid;
                    found_arity = arity;
                    found_recv = recv;
                }
            }
            if (found) |fid| return fid;
        }
    }
    return null;
}

pub fn predeclaredMemberTrailingLambdaShape(b: *FuncBuilder, name: []const u8, user_arg_count: usize) ?ir.ModuleRegistry.MemberTrailingLambdaShape {
    if (user_arg_count >= 63) return null;
    const bit = @as(u64, 1) << @intCast(user_arg_count);
    var roots: [2]?[]const u8 = .{ b.ownerClass(), null };
    if (b.recvTy()) |rt| roots[1] = rsplitLast(rt, '.');
    for (roots) |root_opt| {
        const root = root_opt orelse continue;
        const supers: []const []const u8 = b.module.registry.class_super_names.get(root) orelse &.{};
        var i: usize = 0;
        while (i < 1 + supers.len) : (i += 1) {
            const cls = if (i == 0) root else supers[i - 1];
            const shapes = b.module.registry.member_trailing_lambda_shapes.get(.{ .a = cls, .b = name }) orelse continue;
            var agreed: ?ir.ModuleRegistry.MemberTrailingLambdaShape = null;
            for (shapes.items) |shape| {
                if (shape.accepted_arities & bit == 0) continue;
                if (agreed) |old| {
                    if (old.value_arity != shape.value_arity or
                        !optionalStringEql(old.receiver_head, shape.receiver_head)) return null;
                } else {
                    agreed = shape;
                }
            }
            if (agreed) |shape| return shape;
        }
    }
    return null;
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn memberParamHasDefault(b: *FuncBuilder, cls: []const u8, fid: FuncId, param_index: usize) bool {
    const f = b.module.funcById(fid) orelse return false;
    if (param_index < f.params.len and f.params[param_index].has_default) return true;
    if (b.module.registry.local_fn_defaults.get(fid)) |slots| {
        if (param_index < slots.items.len and slots.items[param_index] != null) return true;
    }
    if (b.module.registry.abstract_member_defaults.get(.{ .a = cls, .b = f.name })) |slots| {
        if (param_index < slots.items.len and slots.items[param_index] != null) return true;
    }
    const supers: []const []const u8 = b.module.registry.class_super_names.get(cls) orelse &.{};
    for (supers) |owner| {
        if (b.module.registry.abstract_member_defaults.get(.{ .a = owner, .b = f.name })) |slots| {
            if (param_index < slots.items.len and slots.items[param_index] != null) return true;
        }
    }
    return false;
}

fn memberHostsTrailingLambdaAtArity(b: *FuncBuilder, cls: []const u8, f: *const Func, fid: FuncId, user_arg_count: usize) bool {
    if (user_arg_count == 0 or f.params.len == 0) return false;
    const off: usize = if (std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const user_params = f.params.len - off;
    if (user_arg_count > user_params or user_params == 0) return false;
    const last = f.params[f.params.len - 1];
    if (last.is_vararg or fnTypeArityAlias(b, last.ty) == null) return false;
    // Positional arguments before a trailing lambda fill parameters from the
    // front. Every gap before the last parameter must therefore have a
    // declaration-site default, including one inherited from an expect or
    // abstract member by its concrete implementation.
    var pi = off + user_arg_count - 1;
    while (pi < f.params.len - 1) : (pi += 1) {
        if (!memberParamHasDefault(b, cls, fid, pi)) return false;
    }
    return true;
}

/// The declared RETURN type head of a function-typed parameter — the last type
/// argument of its `FunctionN`. Null when the shape is not a function type.
fn lambdaReturnHead(ty: ir.TypeRef) ?[]const u8 {
    if (!std.mem.startsWith(u8, ty.name, "Function")) return null;
    if (ty.args.len == 0) return null;
    return ty.args[ty.args.len - 1].name;
}

fn retHeadEql(a: ?[]const u8, b_in: ?[]const u8) bool {
    if (a == null and b_in == null) return true;
    if (a == null or b_in == null) return false;
    return std.mem.eql(u8, a.?, b_in.?);
}

pub fn overloadHostingTrailingLambda(b: *FuncBuilder, name: []const u8, user_arg_count: usize) ?FuncId {
    const ohtl_trace = if (runtime.envOnce("KLIO_MISS_TRACE")) |w| std.mem.eql(u8, w, name) else false;
    const list = b.module.func_name_index.get(name) orelse {
        if (ohtl_trace) std.debug.print("[ohtl] {s}: no func_name_index entry\n", .{name});
        return memberHostingTrailingLambda(b, name, user_arg_count);
    };
    if (ohtl_trace) std.debug.print("[ohtl] {s}: {d} candidates argc={d}\n", .{ name, list.items.len, user_arg_count });
    // With several same-named overloads that all host a trailing lambda
    // (`SnapshotStateList.withCurrent(block: T.() -> R)` and
    // `StateRecord.withCurrent(block: (r: T) -> R)`), declaration order is not
    // evidence: the block's arity differs per overload (0 vs 1), and picking
    // the wrong one records the wrong arity, so a receiver-lambda argument
    // keeps a spurious `it` and its bare member reads fall through to globals.
    // Prefer the overload whose leading `this` matches the enclosing receiver
    // type; only fall back to declaration order when none matches.
    const recv_simple: ?[]const u8 = if (b.enclosingRecvTy()) |r| simpleTypeHead(r) else null;
    var fallback: ?FuncId = null;
    // A candidate whose body has not been attached yet still answers the
    // arity question — its SIGNATURE is what the lambda shape needs. A file
    // lowered before the file that declares its callee (a user file whose
    // package places it ahead of a pack's own sources) sees the callee
    // body-less at this point; skipping it left the trailing receiver-lambda
    // with a spurious implicit `it` bound to the invocation argument
    // (`launch(Dispatchers.Default) { it }` read the StandaloneCoroutine).
    // With-body candidates still outrank body-less ones: an `expect`
    // declaration shadowed by its actual keeps losing to the real one.
    var bodyless: ?FuncId = null;
    var fallback_ret: ?[]const u8 = null;
    var ret_conflict = false;
    for (list.items) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (ohtl_trace) std.debug.print("[ohtl] {s}: cand #{d} params={d} body={} last_ty={s} last_arity={?d}\n", .{ name, fid.int(), f.params.len, f.hasBody(), if (f.params.len != 0) f.params[f.params.len - 1].ty.name else "-", if (f.params.len != 0) fnTypeArityAlias(b, f.params[f.params.len - 1].ty) else null });
        // Both shapes host a trailing lambda: an extension/member (leading
        // `this`) and a plain top-level fn — the offset generalizes.
        const off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const user_params = f.params.len - off;
        if (user_params < user_arg_count) continue;
        const last = f.params[f.params.len - 1];
        if (last.is_vararg) continue;
        if (fnTypeArityAlias(b, last.ty) == null) continue;
        // Under-applied (`launch { … }` against `launch(context = …,
        // start = …, block)`): the trailing lambda binds the last param
        // out of sequence, so every skipped parameter must be defaulted.
        if (user_params != user_arg_count) {
            var i: usize = off + user_arg_count - 1; // leading args fill params[off..]
            var gap_defaulted = true;
            while (i < f.params.len - 1) : (i += 1) {
                if (!f.params[i].has_default) {
                    gap_defaulted = false;
                    break;
                }
            }
            if (!gap_defaulted) continue;
        }
        if (!f.hasBody()) {
            if (bodyless == null) bodyless = fid;
            continue;
        }
        // Receiver match wins outright; otherwise remember the first valid
        // candidate as the declaration-order fallback.
        if (recv_simple) |rs| {
            if (off == 1 and std.mem.eql(u8, simpleTypeHead(f.params[0].ty.name), rs))
                return fid;
        }
        if (fallback == null) {
            fallback = fid;
            fallback_ret = lambdaReturnHead(last.ty);
        } else if (!retHeadEql(fallback_ret, lambdaReturnHead(last.ty))) {
            ret_conflict = true;
        }
    }
    // Several surviving candidates whose trailing lambdas differ in RETURN
    // type — `sumOf(selector: (T) -> Int)` against `(T) -> Double`, 80 of them
    // for that name. Kotlin picks by the lambda's inferred return type, which
    // lowering does not have, so declaration order here is a guess. The pick
    // is used to STAMP the lambda's parameter types as if it were proven, and
    // a wrong stamp is worse than none: the call resolves correctly when
    // nothing is recorded. Decline instead.
    if (ret_conflict) {
        if (ohtl_trace) std.debug.print("[ohtl] {s}: declined, candidates differ in lambda return type\n", .{name});
        return null;
    }
    if (fallback) |fid| return fid;
    // A member on the enclosing/receiver class outranks a SIGNATURE-ONLY
    // top-level namesake: at pack bake the StateRecord.withCurrent extension
    // is still body-less while SnapshotStateMap.mutate's call to its own
    // private withCurrent lowers, and letting the extension's (r: T) -> R
    // arity re-shape the member call's `{ this }` block made a fresh engine
    // pack return the outer map from every mutate (the get_field-map
    // family). A WITH-BODY top-level (the fallback above) still wins as
    // before.
    if (memberHostingTrailingLambda(b, name, user_arg_count)) |fid| return fid;
    if (bodyless) |fid| return fid;
    return null;
}

/// Whether any argument in the call is passed by name.
pub fn anyNamedArg(arg_names: []const ?[]const u8) bool {
    for (arg_names) |an| if (an != null) return true;
    return false;
}

/// Map each argument to the callee parameter it fills, honoring Kotlin's
/// named-argument rules: a named argument matches the parameter of that name; an
/// unnamed trailing lambda binds the last parameter; the remaining unnamed
/// (positional) arguments fill the still-unassigned parameters left to right.
/// `params` is the callee's parameter slice with any receiver already removed.
/// Returns a per-argument target index (parallel to `args`), null for an
/// argument whose parameter can't be determined. Caller frees the slice.
pub fn mapArgsToParams(
    b: *FuncBuilder,
    params: []const ir.Param,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error!?[]?usize {
    const out = try b.allocator.alloc(?usize, args.len);
    for (out) |*o| o.* = null;
    const used = try b.allocator.alloc(bool, params.len);
    defer b.allocator.free(used);
    for (used) |*u| u.* = false;
    // 1. Named arguments bind their same-named parameter. A named argument
    // that matches NO parameter makes the whole call inapplicable to this
    // callee (Kotlin rejects the candidate outright), so the map must fail
    // rather than silently drop the argument — otherwise an unnamed trailing
    // lambda still "binds" the last parameter of a callee that cannot take
    // this call, and downstream heuristics record that parameter's lambda
    // shape (receiver head, arity) against the wrong lambda.
    for (args, 0..) |_, j| {
        const an = if (j < arg_names.len) arg_names[j] else null;
        if (an) |name| {
            const idx_opt: ?usize = for (params, 0..) |p, idx| {
                if (std.mem.eql(u8, p.name, name)) break idx;
            } else null;
            const idx = idx_opt orelse {
                b.allocator.free(out);
                return null;
            };
            out[j] = idx;
            used[idx] = true;
        }
    }
    // 2. An unnamed trailing lambda binds the last (still-free) parameter.
    var trailing_done = false;
    if (args.len != 0) {
        const last = args.len - 1;
        const last_named = last < arg_names.len and arg_names[last] != null;
        const last_lambda = args[last] == .Lambda or args[last] == .AnonFun;
        if (!last_named and last_lambda and params.len != 0 and !used[params.len - 1]) {
            out[last] = params.len - 1;
            used[params.len - 1] = true;
            trailing_done = true;
        }
    }
    // 3. Remaining unnamed arguments fill the free parameters front to back.
    var pidx: usize = 0;
    for (args, 0..) |_, j| {
        const an = if (j < arg_names.len) arg_names[j] else null;
        if (an != null) continue;
        if (trailing_done and j == args.len - 1) continue;
        while (pidx < params.len and used[pidx]) pidx += 1;
        if (pidx < params.len) {
            out[j] = pidx;
            if (!params[pidx].is_vararg) {
                used[pidx] = true;
                pidx += 1;
            }
        }
    }
    return out;
}

/// The element type of a function-typed VARARG parameter. The lowered
/// parameter may carry the element type directly (`Function0`) rather than a
/// materialized array, so try it as-is before stripping an array layer.
fn varargFnElemTy(b: *FuncBuilder, ty: ir.TypeRef) ir.TypeRef {
    if (fnTypeArityAlias(b, ty) != null) return ty;
    return applicability.varargElementRef(&ty);
}

pub fn argFnArities(b: *FuncBuilder, func: *const Func, args: []const Expr, arg_names: []const ?[]const u8, recv_offset: usize) Allocator.Error!?[]i16 {
    if (args.len == 0) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (func.params.len < recv_offset) return null;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(i16, args.len);
    for (out) |*o| o.* = -1;
    // Named arguments: resolve each lambda's expected arity through its target
    // parameter (by name) so a receiver lambda passed by name is still detected
    // as arity-0 — otherwise it is mistaken for an `it`-lambda and its bare
    // member accesses fall through to unresolved globals.
    if (anyNamedArg(arg_names)) {
        const map = (try mapArgsToParams(b, params, args, arg_names)) orelse {
            b.allocator.free(out);
            return null;
        };
        defer b.allocator.free(map);
        for (out, map) |*o, m| {
            if (m) |pi| o.* = fnTypeArityAlias(b, params[pi].ty) orelse -1;
        }
        return out;
    }
    // A trailing lambda fills the last function-typed parameter even when
    // earlier defaulted parameters are omitted; align the trailing lambda
    // with the last parameter and the leading args from the front.
    // Same vararg run as the receiver recorder below. Without this the
    // literals keep their implicit `it` parameter, so the closure reports one
    // value parameter, and the VM's receiver rule — bind the extra leading
    // argument when a receiver-carrying closure is called with `n_params + 1`
    // arguments — cannot fire.
    for (params, 0..) |p, vp| {
        if (!p.is_vararg) continue;
        const n_after = params.len - vp - 1;
        if (args.len < vp + n_after) break;
        const vararg_end = args.len - n_after;
        const elem_arity = fnTypeArityAlias(b, varargFnElemTy(b, params[vp].ty)) orelse -1;
        var vi2: usize = 0;
        while (vi2 < vp and vi2 < args.len) : (vi2 += 1) out[vi2] = fnTypeArityAlias(b, params[vi2].ty) orelse -1;
        vi2 = vp;
        while (vi2 < vararg_end) : (vi2 += 1) out[vi2] = elem_arity;
        var k: usize = 0;
        while (k < n_after) : (k += 1) {
            const ai = vararg_end + k;
            const pi = vp + 1 + k;
            if (ai < args.len and pi < params.len) out[ai] = fnTypeArityAlias(b, params[pi].ty) orelse -1;
        }
        return out;
    }
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        // Leading positional args map 1:1 from the front.
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            out[i] = fnTypeArityAlias(b, params[i].ty) orelse -1;
        }
        // The trailing lambda maps to the last parameter.
        out[args.len - 1] = fnTypeArityAlias(b, params[params.len - 1].ty) orelse -1;
    } else if (args.len == params.len) {
        for (params, out) |p, *o| o.* = fnTypeArityAlias(b, p.ty) orelse -1;
    } else {
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// The declared receiver-type head of a receiver-lambda parameter type
/// (`MockViewValidator.() -> Unit`), or null when the type is not a direct
/// receiver function. The lowered encoding is
/// `[#suspend?] [receiver?] params(n) ret(1) [#markers]`; a receiver is present
/// when the non-marker, non-suspend arg count is `n + 2`.
pub fn fnTypeReceiver(b: *FuncBuilder, ty: ir.TypeRef) ?ir.TypeRef {
    if (!std.mem.startsWith(u8, ty.name, "Function")) return null;
    const arity = fnTypeArityAlias(b, ty) orelse return null;
    const n: usize = if (arity < 0) 0 else @intCast(arity);
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo; // [receiver?] params(n) ret(1)
    if (remaining == n + 2 and lo < hi) {
        const receiver = ty.args[lo];
        if (receiver.name.len != 0 and receiver.name[0] != '#') return receiver;
    }
    return null;
}

pub fn fnTypeReceiverHead(b: *FuncBuilder, ty: ir.TypeRef) ?[]const u8 {
    return if (fnTypeReceiver(b, ty)) |receiver| receiver.name else null;
}

fn funcDeclaresTypeParam(b: *const FuncBuilder, func: *const Func, name: []const u8) bool {
    const params = b.module.registry.func_type_params.get(func.id) orelse return false;
    for (params.items) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    return false;
}

/// Substitute a receiver-function parameter's direct function type parameter
/// from authoritative call-argument evidence. This is the common
/// `with(receiver, block: T.() -> R)` shape: the block's implicit receiver is
/// the static type of `receiver`, not the unbound declaration name `T`.
pub fn callBoundLambdaReceiverType(
    b: *FuncBuilder,
    func: *const Func,
    declared_receiver: ir.TypeRef,
    params: []const ir.Param,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    call_receiver: ?ir.TypeRef,
) Allocator.Error!ir.TypeRef {
    const head = declared_receiver.name;
    if (!funcDeclaresTypeParam(b, func, head)) {
        // The head can be the ENCLOSING CLASS's type parameter, whose
        // instantiation the call receiver's own type arguments carry:
        // `propertyEquals { }` on a `CompareContext<Map<K, V>>` receiver
        // binds its `T.() -> P` lambda's receiver to `Map<K, V>`.
        if (classParamReceiverInstantiation(b, func, head, call_receiver)) |inst| {
            return inst.clone(b.allocator);
        }
        return declared_receiver.clone(b.allocator);
    }
    if (b.module.registry.func_type_params.get(func.id)) |declared_params| {
        for (declared_params.items, 0..) |param, index| {
            if (!std.mem.eql(u8, param, head)) continue;
            if (index < type_args.len) {
                return loweredOwnedLocalTypeRef(b, &type_args[index]);
            }
            break;
        }
    }
    if (call_receiver) |actual_receiver| {
        if (func.params.len != 0 and
            std.mem.eql(u8, func.params[0].name, "this") and
            std.mem.eql(u8, func.params[0].ty.name, head))
        {
            return actual_receiver.clone(b.allocator);
        }
    }

    var mapping: ?[]const ?usize = null;
    defer if (mapping) |items| b.allocator.free(items);
    if (anyNamedArg(arg_names)) {
        mapping = try mapArgsToParams(b, params, args, arg_names);
        if (mapping == null) return declared_receiver.clone(b.allocator);
    }

    const trailing_lambda = args.len != 0 and
        (args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun);
    var bound: ?ir.TypeRef = null;
    for (args, 0..) |*arg, i| {
        if (arg.* == .Lambda or arg.* == .AnonFun or arg.* == .Spread) continue;
        const param_index: ?usize = if (mapping) |items|
            items[i]
        else if (trailing_lambda and i + 1 == args.len and args.len <= params.len)
            params.len - 1
        else if (i < params.len)
            i
        else
            null;
        const pi = param_index orelse continue;
        if (pi >= params.len) continue;
        const param_ty = params[pi].ty;
        if (param_ty.nullable or param_ty.args.len != 0 or
            !std.mem.eql(u8, param_ty.name, head)) continue;
        const actual = argDeclTypeRefLazy(b, arg) orelse continue;
        if (b.isTypeParam(actual.name)) continue;
        if (bound) |existing| {
            if (!existing.eql(actual)) return declared_receiver.clone(b.allocator);
        } else {
            bound = actual;
        }
    }
    return if (bound) |actual|
        actual.clone(b.allocator)
    else
        declared_receiver.clone(b.allocator);
}

/// `head` as a type parameter of `func`'s ENCLOSING CLASS, instantiated by
/// the call receiver's own type arguments. Answers a borrowed ref into the
/// receiver's arg list; the caller clones. The receiver must name the
/// declaring class itself so its argument list aligns with the class's
/// parameter list, and the instantiation must be concrete.
fn classParamReceiverInstantiation(
    b: *FuncBuilder,
    func: *const Func,
    head: []const u8,
    call_receiver: ?ir.TypeRef,
) ?*const ir.TypeRef {
    const cpt = runtime.envOnce("KLIO_CPT_TRACE") != null;
    // The declared receiver's head is usually the class param's IDENTITY
    // MANGLE, which names its owning class and parameter directly; a plain
    // param name falls back to the declaration's enclosing class.
    var owner: ir.ClassId = undefined;
    var param_name: []const u8 = head;
    if (ir.parseClassTypeParamIdentity(head)) |identity| {
        owner = identity.owner;
        param_name = identity.param;
    } else {
        const sig = b.module.decl_sigs.get(func.id.int()) orelse {
            if (cpt) std.debug.print("[cpt] {s}: no sig\n", .{func.name});
            return null;
        };
        owner = sig.enclosing_class orelse {
            if (cpt) std.debug.print("[cpt] {s}: no enclosing class\n", .{func.name});
            return null;
        };
    }
    if (owner.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[owner.int()];
    var index: ?usize = null;
    for (cls.type_params, 0..) |tp, i| {
        if (std.mem.eql(u8, tp, param_name)) {
            index = i;
            break;
        }
    }
    const ti = index orelse {
        if (cpt) std.debug.print("[cpt] {s} param={s}: not in {s} params (n={d})\n", .{ func.name, param_name, cls.name, cls.type_params.len });
        return null;
    };
    const own_recv: ?ir.TypeRef = if (call_receiver == null) b.recvTypeRef() else null;
    const recv: *const ir.TypeRef = if (call_receiver) |*cr| cr else if (own_recv) |*orr| orr else {
        if (cpt) std.debug.print("[cpt] {s} head={s}: no receiver ref\n", .{ func.name, head });
        return null;
    };
    var rhead = std.mem.trimEnd(u8, recv.name, "?");
    if (std.mem.indexOfScalar(u8, rhead, '<')) |lt| rhead = rhead[0..lt];
    rhead = typeHead(rhead);
    if (!std.mem.eql(u8, rhead, cls.name) and !std.mem.eql(u8, rhead, applicability.simpleName(cls.fqn))) {
        if (cpt) std.debug.print("[cpt] {s} head={s}: recv {s} != cls {s}\n", .{ func.name, head, rhead, cls.name });
        return null;
    }
    if (ti >= recv.args.len) {
        if (cpt) std.debug.print("[cpt] {s} head={s}: recv {s} args={d} ti={d}\n", .{ func.name, head, recv.name, recv.args.len, ti });
        return null;
    }
    const inst = &recv.args[ti];
    if (inst.name.len == 0 or b.isTypeParam(inst.name)) {
        if (cpt) std.debug.print("[cpt] {s} head={s}: inst {s} not concrete\n", .{ func.name, head, inst.name });
        return null;
    }
    if (cpt) std.debug.print("[cpt] {s} head={s}: -> {s}\n", .{ func.name, head, inst.name });
    return inst;
}

fn recordCallBoundLambdaReceiver(
    b: *FuncBuilder,
    func: *const Func,
    call_span: ast.Span,
    declared_receiver: ir.TypeRef,
    params: []const ir.Param,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    call_receiver: ?ir.TypeRef,
) Allocator.Error!void {
    const resolved = try callBoundLambdaReceiverType(
        b,
        func,
        declared_receiver,
        params,
        args,
        arg_names,
        type_args,
        call_receiver,
    );
    // An answer that is still the UNINSTANTIATED declared parameter — the
    // function's own type param or a class param's identity mangle — must
    // never clobber an instantiated record another resolution pass made.
    if (resolved.eql(declared_receiver) and
        (funcDeclaresTypeParam(b, func, declared_receiver.name) or
            ir.parseClassTypeParamIdentity(declared_receiver.name) != null) and
        b.lambdaArgRecv(call_span) != null)
    {
        var cleanup = resolved;
        cleanup.deinit(b.allocator);
        return;
    }
    if (std.c.getenv("KLIO_LAR_TRACE") != null)
        std.debug.print("[lar-site] site=cbr fn={s} declared={s} resolved={s} s={d}..{d}\n", .{ func.fqn, declared_receiver.name, resolved.name, call_span.start, call_span.end });
    try b.recordLambdaArgRecvOwned(call_span, resolved);
}

/// Record the receiver-type head of each receiver-lambda ARGUMENT so its body
/// owns that receiver even when the call is deferred and no expected type
/// reaches `lowerLambda`. Mirrors `argFnArities`' arg→param alignment.
pub fn recordLambdaArgReceivers(
    b: *FuncBuilder,
    func: *const Func,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    recv_offset: usize,
) Allocator.Error!void {
    return recordLambdaArgReceiversForCallReceiver(
        b,
        func,
        args,
        arg_names,
        type_args,
        null,
        recv_offset,
    );
}

pub fn recordLambdaArgReceiversForCallReceiver(
    b: *FuncBuilder,
    func: *const Func,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    call_receiver: ?ir.TypeRef,
    recv_offset: usize,
) Allocator.Error!void {
    if (args.len == 0 or func.params.len < recv_offset) return;
    for (args) |*a| if (a.* == .Spread) return;
    const params = func.params[recv_offset..];
    if (anyNamedArg(arg_names)) {
        const map = (try mapArgsToParams(b, params, args, arg_names)) orelse return;
        defer b.allocator.free(map);
        for (args, map) |*a, m| {
            if (a.* != .Lambda and a.* != .AnonFun) continue;
            if (m) |pi| if (pi < params.len) {
                if (fnTypeReceiver(b, params[pi].ty)) |receiver| {
                    try recordCallBoundLambdaReceiver(b, func, a.span(), receiver, params, args, arg_names, type_args, call_receiver);
                }
            };
        }
        return;
    }
    // A function-typed VARARG parameter binds EVERY argument in its run.
    // `f(vararg blocks: Sink.() -> Unit)` called with two lambda literals
    // matches neither shape below — two arguments never equal the one
    // declared parameter, nor fit `args.len <= params.len` — so neither
    // literal was recorded. kotlinx-datetime's `alternativeParsing(vararg
    // others: T.() -> Unit, primary: T.() -> Unit)` is the shape RFC_1123
    // parses through.
    for (params, 0..) |p, vp| {
        if (!p.is_vararg) continue;
        const n_after = params.len - vp - 1;
        if (args.len < vp + n_after) break;
        const vararg_end = args.len - n_after;
        if (fnTypeReceiver(b, varargFnElemTy(b, params[vp].ty))) |receiver| {
            var vi: usize = vp;
            while (vi < vararg_end) : (vi += 1) {
                if (args[vi] != .Lambda and args[vi] != .AnonFun) continue;
                try recordCallBoundLambdaReceiver(b, func, args[vi].span(), receiver, params, args, arg_names, type_args, call_receiver);
            }
        }
        var k: usize = 0;
        while (k < n_after) : (k += 1) {
            const ai = vararg_end + k;
            const pi = vp + 1 + k;
            if (ai >= args.len or pi >= params.len) break;
            if (args[ai] != .Lambda and args[ai] != .AnonFun) continue;
            if (fnTypeReceiver(b, params[pi].ty)) |receiver| {
                try recordCallBoundLambdaReceiver(b, func, args[ai].span(), receiver, params, args, arg_names, type_args, call_receiver);
            }
        }
        return;
    }
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            if ((args[i] == .Lambda or args[i] == .AnonFun)) {
                if (fnTypeReceiver(b, params[i].ty)) |receiver| {
                    try recordCallBoundLambdaReceiver(b, func, args[i].span(), receiver, params, args, arg_names, type_args, call_receiver);
                }
            }
        }
        if (fnTypeReceiver(b, params[params.len - 1].ty)) |receiver| {
            try recordCallBoundLambdaReceiver(
                b,
                func,
                args[args.len - 1].span(),
                receiver,
                params,
                args,
                arg_names,
                type_args,
                call_receiver,
            );
        }
    } else if (args.len == params.len) {
        for (args, params) |*a, p| {
            if (a.* != .Lambda and a.* != .AnonFun) continue;
            if (fnTypeReceiver(b, p.ty)) |receiver| {
                try recordCallBoundLambdaReceiver(b, func, a.span(), receiver, params, args, arg_names, type_args, call_receiver);
            }
        }
    }
}

/// A bitmask of which of a `FunctionN`-typed parameter's `arity` value
/// parameters are declared as a broad collection (`Iterable`/`Collection`).
/// Used so a lambda bound to that parameter marks those of its own params
/// broad — then `it + x` over a runtime `Set` produces a `List`, matching the
/// declared (not runtime) receiver type. Only direct `Function{N}` types are
/// decoded (a typealias gives arity but not parameter types → mask 0).
fn fnTypeBroadMask(ty: ir.TypeRef, arity: i16) u32 {
    if (arity <= 0) return 0;
    const n: usize = @intCast(arity);
    if (!std.mem.startsWith(u8, ty.name, "Function")) return 0;
    // The lowered encoding is `[#suspend?] [receiver?] params… ret [#markers]`.
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo; // [receiver?] params(n) ret(1)
    var pstart = lo;
    if (remaining == n + 2) {
        pstart = lo + 1; // an explicit receiver precedes the value params
    } else if (remaining != n + 1) {
        return 0; // cannot align
    }
    var mask: u32 = 0;
    var i: usize = 0;
    while (i < n and i < 32 and pstart + i < hi) : (i += 1) {
        if (helpers.isBroadCollectionTypeName(ty.args[pstart + i].name)) {
            mask |= (@as(u32, 1) << @intCast(i));
        }
    }
    return mask;
}

/// Per-argument broad-collection lambda-parameter masks for a call dispatched
/// to `func`, parallel to `args` and aligned exactly like `argFnArities`.
pub fn argLambdaBroadMasks(b: *FuncBuilder, func: *const Func, args: []const Expr, arg_names: []const ?[]const u8, recv_offset: usize) Allocator.Error!?[]u32 {
    if (args.len == 0) return null;
    for (arg_names) |an| if (an != null) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (func.params.len < recv_offset) return null;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(u32, args.len);
    for (out) |*o| o.* = 0;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            out[i] = fnTypeBroadMask(params[i].ty, fnTypeArityAlias(b, params[i].ty) orelse -1);
        }
        out[args.len - 1] = fnTypeBroadMask(params[params.len - 1].ty, fnTypeArityAlias(b, params[params.len - 1].ty) orelse -1);
    } else if (args.len == params.len) {
        for (params, out) |p, *o| o.* = fnTypeBroadMask(p.ty, fnTypeArityAlias(b, p.ty) orelse -1);
    } else {
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// Whether a callee parameter's declared function type takes only values
/// typed by the callee's own type parameters (`f2t: (T, T) -> T` inside
/// `fun <T : Comparable<T>> ...`). A callable reference in such a slot
/// denotes the GENERIC overload of the referenced name: kotlinc substitutes
/// the call-site type argument, so only the generic candidate applies.
fn fnTypeIsCalleeGeneric(b: *FuncBuilder, func: *const Func, ty: ir.TypeRef, arity: i16) bool {
    if (arity <= 0) return false;
    const tps = b.module.registry.func_type_params.get(func.id) orelse return false;
    if (tps.items.len == 0) return false;
    if (!std.mem.startsWith(u8, ty.name, "Function")) return false;
    const n: usize = @intCast(arity);
    // The lowered encoding is `[#suspend?] [receiver?] params… ret [#markers]`.
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo;
    var pstart = lo;
    if (remaining == n + 2) {
        pstart = lo + 1;
    } else if (remaining != n + 1) {
        return false;
    }
    var i: usize = 0;
    while (i < n and pstart + i < hi) : (i += 1) {
        var hit = false;
        for (tps.items) |tp| {
            if (std.mem.eql(u8, ty.args[pstart + i].name, tp)) {
                hit = true;
                break;
            }
        }
        if (!hit) return false;
    }
    return true;
}

/// Per-argument callee-generic function-type flags for a call dispatched to
/// `func`, parallel to `args` and aligned exactly like `argFnArities`.
pub fn argFnGenericFlags(b: *FuncBuilder, func: *const Func, args: []const Expr, arg_names: []const ?[]const u8, recv_offset: usize) Allocator.Error!?[]bool {
    if (args.len == 0) return null;
    for (arg_names) |an| if (an != null) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (func.params.len < recv_offset) return null;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(bool, args.len);
    for (out) |*o| o.* = false;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            out[i] = fnTypeIsCalleeGeneric(b, func, params[i].ty, fnTypeArityAlias(b, params[i].ty) orelse -1);
        }
        out[args.len - 1] = fnTypeIsCalleeGeneric(b, func, params[params.len - 1].ty, fnTypeArityAlias(b, params[params.len - 1].ty) orelse -1);
    } else if (args.len == params.len) {
        for (params, out) |p, *o| o.* = fnTypeIsCalleeGeneric(b, func, p.ty, fnTypeArityAlias(b, p.ty) orelse -1);
    } else {
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// Pseudo-explicit type args solved from the call site's EXPECTED type: when
/// the declared return's head matches the expected head, its argument count
/// matches, and EVERY one of the callee's type parameters appears as a
/// direct return type argument, each binds to the expected's argument at
/// that position. `compareBy`'s `Comparator<T>` against an expected
/// `Comparator<String>` yields `[String]`; a partial or mismatched shape
/// yields nothing.
pub fn expectedReturnTypeArgsFor(b: *FuncBuilder, func: *const Func) Allocator.Error!?[]ir.TypeRef {
    const exp = b.peekExpected() orelse return null;
    if (exp.function != null or exp.type_args.len == 0) return null;
    const tps = b.module.registry.func_type_params.get(func.id) orelse return null;
    if (tps.items.len == 0) return null;
    const ret = func.return_ty;
    if (ret.name.len == 0 or ret.args.len == 0) return null;
    if (!std.mem.eql(u8, typeHead(std.mem.trimEnd(u8, ret.name, "?")), exp.name.name)) return null;
    if (exp.type_args.len != ret.args.len) return null;
    const out = try b.allocator.alloc(ir.TypeRef, tps.items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*t| t.deinit(b.allocator);
        b.allocator.free(out);
    }
    for (tps.items) |tp| {
        var found: ?usize = null;
        var declared_nullable = false;
        for (ret.args, 0..) |ra, ri| {
            var rn = std.mem.trimEnd(u8, ra.name, "?");
            if (std.mem.startsWith(u8, rn, "in#")) rn = rn[3..];
            if (std.mem.startsWith(u8, rn, "out#")) rn = rn[4..];
            if (std.mem.eql(u8, rn, tp)) {
                found = ri;
                declared_nullable = ra.nullable or rn.len != std.mem.trimEnd(u8, ra.name, "?").len or
                    std.mem.endsWith(u8, ra.name, "?");
                break;
            }
        }
        const ri = found orelse {
            for (out[0..filled]) |*t| t.deinit(b.allocator);
            b.allocator.free(out);
            return null;
        };
        const ta = exp.type_args[ri];
        if (ta.is_star) {
            for (out[0..filled]) |*t| t.deinit(b.allocator);
            b.allocator.free(out);
            return null;
        }
        out[filled] = try loweredOwnedLocalTypeRef(b, &ta.ty);
        // A declared `T?` return position already carries the `?`: the
        // binding is the expected argument WITHOUT it (`Comparator<T?>`
        // against `Comparator<String?>` binds T := String, satisfying
        // `T : Any` exactly as kotlinc solves nullsFirst).
        if (declared_nullable) out[filled].nullable = false;
        filled += 1;
    }
    return out;
}

/// PARTIAL bindings solved from the call site's EXPECTED type: each of the
/// callee's type parameters that appears as a direct return type argument
/// binds to the expected's argument at that position; the rest stay unbound
/// (unlike `expectedReturnTypeArgsFor`, which needs every one for the
/// positional explicit-args slot). The caller owns the bindings' types.
fn expectedReturnPartialBindings(b: *FuncBuilder, func: *const Func) Allocator.Error!?[]ir.Module.TypeBinding {
    const exp = b.peekExpected() orelse return null;
    if (exp.function != null or exp.type_args.len == 0) return null;
    const tps = b.module.registry.func_type_params.get(func.id) orelse return null;
    if (tps.items.len == 0) return null;
    const ret = func.return_ty;
    if (ret.name.len == 0 or ret.args.len == 0) return null;
    if (!std.mem.eql(u8, typeHead(std.mem.trimEnd(u8, ret.name, "?")), exp.name.name)) return null;
    if (exp.type_args.len != ret.args.len) return null;
    var out: std.ArrayList(ir.Module.TypeBinding) = .empty;
    errdefer {
        for (out.items) |*bd| {
            var t = bd.ty;
            t.deinit(b.allocator);
        }
        out.deinit(b.allocator);
    }
    for (tps.items) |tp| {
        var found: ?usize = null;
        var declared_nullable = false;
        for (ret.args, 0..) |ra, ri| {
            var rn = std.mem.trimEnd(u8, ra.name, "?");
            if (std.mem.startsWith(u8, rn, "in#")) rn = rn[3..];
            if (std.mem.startsWith(u8, rn, "out#")) rn = rn[4..];
            if (std.mem.eql(u8, rn, tp)) {
                found = ri;
                declared_nullable = ra.nullable or std.mem.endsWith(u8, ra.name, "?");
                break;
            }
        }
        const ri = found orelse continue;
        const ta = exp.type_args[ri];
        if (ta.is_star) continue;
        var ty = try loweredOwnedLocalTypeRef(b, &ta.ty);
        if (declared_nullable) ty.nullable = false;
        try out.append(b.allocator, .{ .name = tp, .ty = ty });
    }
    if (out.items.len == 0) {
        out.deinit(b.allocator);
        return null;
    }
    return try out.toOwnedSlice(b.allocator);
}

fn instantiatedLambdaValueParams(
    b: *FuncBuilder,
    func: *const Func,
    fn_ty: ir.TypeRef,
    type_args: []const ast.TypeRef,
    include_function_receiver: bool,
    recv: ?*const ir.TypeRef,
    shapes: ?[]const applicability.ArgShape,
) Allocator.Error!?[]ir.TypeRef {
    const arity = fnTypeArityAlias(b, fn_ty) orelse return null;
    if (arity < 0) return null;
    const n: usize = @intCast(arity);

    const explicit = try b.allocator.alloc(ir.TypeRef, type_args.len);
    defer {
        for (explicit) |*ty| ty.deinit(b.allocator);
        b.allocator.free(explicit);
    }
    for (type_args, explicit) |*src, *dst| {
        dst.* = try loweredOwnedLocalTypeRef(b, src);
    }
    // An expected type at the call site binds like explicit type args:
    // compareBy's declared `Comparator<T>` against an expected
    // `Comparator<String>` binds T := String, instantiating the selector's
    // `(T) -> ...` so the literal's parameter types.
    var expected_explicit: ?[]ir.TypeRef = null;
    defer if (expected_explicit) |ea| {
        for (ea) |*t| t.deinit(b.allocator);
        b.allocator.free(ea);
    };
    if (type_args.len == 0) {
        expected_explicit = try expectedReturnTypeArgsFor(b, func);
    }
    const explicit_eff: []const ir.TypeRef = if (explicit.len != 0)
        explicit
    else
        (expected_explicit orelse explicit);
    // A PARTIAL expected binding still instantiates the lambda slot's
    // inputs: two-arg `compareBy(comparator, selector)` declares [T, K]
    // and its `Comparator<T>` return binds only T from the expected type —
    // exactly the parameter the selector's `it` needs; K stays bare and
    // the per-slot guard below handles it.
    var fn_ty_sub: ?ir.TypeRef = null;
    defer if (fn_ty_sub) |*t| t.deinit(b.allocator);
    if (type_args.len == 0 and expected_explicit == null) {
        if (try expectedReturnPartialBindings(b, func)) |binds| {
            defer {
                for (binds) |*bd| {
                    var t = bd.ty;
                    t.deinit(b.allocator);
                }
                b.allocator.free(binds);
            }
            var scratch0 = std.heap.ArenaAllocator.init(b.allocator);
            defer scratch0.deinit();
            if (ir.Module.substituteBoundType(scratch0.allocator(), fn_ty, binds) catch null) |sub| {
                fn_ty_sub = try sub.clone(b.allocator);
            }
        }
    }
    const fn_ty_eff: ir.TypeRef = fn_ty_sub orelse fn_ty;
    var instantiated = blk: {
        // The ENGINE: solve every binding the call site offers — receiver,
        // typed value arguments, explicit type args — in one pass and
        // substitute the lambda's declared fn type through it. The bare-tp
        // guard below refuses whatever stays unsubstituted.
        engine: {
            if (std.mem.eql(u8, runtime.envOnce("KLIO_ENGINE_LAMBDA") orelse "1", "0")) break :engine;
            const sh = shapes orelse break :engine;
            var scratch = std.heap.ArenaAllocator.init(b.allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const solved = (b.module.solveCallBindings(
                a,
                func.id,
                func,
                if (recv) |r| r.* else null,
                null,
                sh,
                explicit_eff,
                false,
            ) catch break :engine) orelse break :engine;
            if (solved.bindings.len == 0) break :engine;
            const substituted = ir.Module.substituteBoundType(a, fn_ty_eff, solved.bindings) catch break :engine;
            break :blk try substituted.clone(b.allocator);
        }
        // With no explicit type args, the ACTUAL receiver may bind the
        // callee's params (`Iterable<String>.count` binds T := String).
        if (type_args.len == 0) {
            if (recv) |r| {
                // Partial substitution: a return-only parameter (`R` in
                // `minOfWith`'s selector) must not block binding the ones
                // the receiver proves; the bare-tp guard below refuses any
                // entry that stayed unsubstituted.
                if (try b.module.instantiatedTypeFromReceiverPartial(
                    b.allocator,
                    func.id,
                    fn_ty_eff,
                    r.*,
                )) |t| break :blk t;
            }
        }
        break :blk (try b.module.instantiatedDeclarationType(
            b.allocator,
            func.id,
            fn_ty_eff,
            explicit_eff,
        )) orelse try fn_ty_eff.clone(b.allocator);
    };
    defer instantiated.deinit(b.allocator);

    var hi = instantiated.args.len;
    while (hi > 0 and instantiated.args[hi - 1].name.len != 0 and
        instantiated.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, instantiated.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo;
    const has_receiver = remaining == n + 2;
    if (!has_receiver and remaining != n + 1) return null;
    const include_receiver = has_receiver and include_function_receiver;
    const start = lo + @intFromBool(has_receiver and !include_receiver);
    const count = n + @intFromBool(include_receiver);
    if (count == 0 and !include_function_receiver) return null;

    const out = try b.allocator.alloc(ir.TypeRef, count);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*ty| ty.deinit(b.allocator);
        b.allocator.free(out);
    }
    // A slice that still quotes one of the CALLEE's own type parameters is
    // not an answer: the head names nothing in the receiving scope, and
    // recording it feeds the no-class bucket and disproves candidates a
    // null leaves open (the splice-inheritance rule). Refuse the whole
    // slice when any entry's head stayed unsubstituted.
    const callee_tps = b.module.registry.func_type_params.get(func.id);
    for (out, instantiated.args[start .. start + count]) |*dst, src| {
        const h = typeHead(std.mem.trimEnd(u8, src.name, "?"));
        // A star-erased head names nothing either — the engine's erasure
        // marks an UNSOLVED parameter, which is a null answer here.
        if (std.mem.eql(u8, h, "*")) {
            for (out[0..initialized]) |*ty| ty.deinit(b.allocator);
            b.allocator.free(out);
            return null;
        }
        if (callee_tps) |tps| {
            for (tps.items) |tp| {
                if (std.mem.eql(u8, tp, h)) {
                    for (out[0..initialized]) |*ty| ty.deinit(b.allocator);
                    b.allocator.free(out);
                    return null;
                }
            }
        }
        dst.* = try src.clone(b.allocator);
        initialized += 1;
    }
    return out;
}

pub fn deinitArgLambdaParamTypes(
    allocator: Allocator,
    types: []?[]ir.TypeRef,
) void {
    for (types) |maybe_params| {
        if (maybe_params) |params| {
            for (params) |*ty| ty.deinit(allocator);
            allocator.free(params);
        }
    }
    allocator.free(types);
}

/// The receiver to substitute a generic callee's params from: a declared
/// receiver carrying ARGUMENTS is authoritative; a bare type-param head
/// resolves through its full bound ref when one was recorded
/// (`T : Iterable<String>` answers `Iterable<String>`); a head-only
/// receiver substitutes nothing.
pub fn substitutionRecv(b: *FuncBuilder, declared: ?*const ir.TypeRef) ?*const ir.TypeRef {
    const d = declared orelse return null;
    var head = std.mem.trimEnd(u8, d.name, "?");
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (b.typeParamBoundRef(typeHead(head))) |ref| return ref;
    if (d.args.len != 0) return d;
    if (std.mem.eql(u8, runtime.envOnce("KLIO_SUBST_NONGEN") orelse "1", "0")) return null;
    // A head-only receiver naming a NON-GENERIC class is complete: the head
    // is the whole type, so `SlotWriter.let { writer -> }` binds
    // `T := SlotWriter` exactly. Only a generic class's bare head (a `List`
    // missing its element) says nothing.
    const cid = (if (std.mem.indexOfScalar(u8, head, '.') != null)
        b.module.classIdByFqn(head)
    else
        b.module.uniqueClassIdBySimpleName(typeHead(head))) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    if (b.module.classes.items[cid.int()].type_params.len == 0) return d;
    return null;
}

/// Instantiated expected value-parameter types for each lambda argument,
/// aligned through the same positional/named/trailing-lambda map as arity.
pub fn argLambdaParamTypes(
    b: *FuncBuilder,
    func: *const Func,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    recv_offset: usize,
) Allocator.Error!?[]?[]ir.TypeRef {
    applyExpectedLiteralKindsToArgs(b, func, args, arg_names, recv_offset);
    return argLambdaParamTypesRecv(b, func, args, arg_names, type_args, recv_offset, null);
}

pub fn argLambdaParamTypesRecv(
    b: *FuncBuilder,
    func: *const Func,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    recv_offset: usize,
    recv: ?*const ir.TypeRef,
) Allocator.Error!?[]?[]ir.TypeRef {
    if (runtime.envOnce("KLIO_ALPT")) |want| {
        if (std.mem.eql(u8, want, func.name)) {
            std.debug.print("[alpt] {s}#{d} nargs={d} nparams={d} off={d} p_last={s} p_last_args={d}\n", .{
                func.fqn,
                func.id.int(),
                args.len,
                func.params.len,
                recv_offset,
                if (func.params.len != 0) func.params[func.params.len - 1].ty.name else "-",
                if (func.params.len != 0) func.params[func.params.len - 1].ty.args.len else 0,
            });
        }
    }
    if (args.len == 0 or func.params.len < recv_offset) return null;
    for (args) |*arg| if (arg.* == .Spread) return null;
    // One shape build per call: the engine consumes value-argument
    // evidence alongside the receiver and explicit type args.
    var lam_shape_set = try buildStaticReturnArgShapes(b, args, arg_names);
    defer lam_shape_set.deinit(b.allocator);
    const lam_shapes = lam_shape_set.shapes;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(?[]ir.TypeRef, args.len);
    for (out) |*slot| slot.* = null;
    errdefer deinitArgLambdaParamTypes(b.allocator, out);
    var any = false;
    // Lambda literals bound to a `-> Unit` parameter return Unit whatever
    // their tail expression yields; the mask rides the same per-argument
    // channel as the instantiated parameter types.
    const unit_mask = try b.allocator.alloc(bool, args.len);
    for (unit_mask) |*u| u.* = false;
    if (b.pending_arg_lambda_unit) |m| b.allocator.free(m);
    b.pending_arg_lambda_unit = unit_mask;

    if (anyNamedArg(arg_names)) {
        const mapping = (try mapArgsToParams(b, params, args, arg_names)) orelse {
            b.allocator.free(out);
            return null;
        };
        defer b.allocator.free(mapping);
        for (args, mapping, out, 0..) |*arg, mapped, *slot, ai| {
            const callable_ref = arg.* == .PropertyRef or arg.* == .MemberRef;
            if (arg.* != .Lambda and arg.* != .AnonFun and !callable_ref) continue;
            const pi = mapped orelse continue;
            if ((arg.* == .Lambda or callable_ref) and fnTypeReturnsUnit(b, params[pi].ty)) unit_mask[ai] = true;
            slot.* = try instantiatedLambdaValueParams(
                b,
                func,
                params[pi].ty,
                type_args,
                callable_ref,
                recv,
                lam_shapes,
            );
            any = any or slot.* != null;
        }
    } else {
        const trailing_lambda = args[args.len - 1] == .Lambda or
            args[args.len - 1] == .AnonFun;
        for (args, out, 0..) |*arg, *slot, i| {
            const callable_ref = arg.* == .PropertyRef or arg.* == .MemberRef;
            if (arg.* != .Lambda and arg.* != .AnonFun and !callable_ref) continue;
            const pi: ?usize = if (trailing_lambda and i + 1 == args.len and
                args.len <= params.len)
                params.len - 1
            else if (i < params.len)
                i
            else
                null;
            if (pi) |param_index| {
                if ((arg.* == .Lambda or callable_ref) and fnTypeReturnsUnit(b, params[param_index].ty)) unit_mask[i] = true;
                slot.* = try instantiatedLambdaValueParams(
                    b,
                    func,
                    params[param_index].ty,
                    type_args,
                    callable_ref,
                    recv,
                    lam_shapes,
                );
                any = any or slot.* != null;
            }
        }
    }
    if (runtime.envOnce("KLIO_ALPT")) |want| {
        if (std.mem.eql(u8, want, func.name)) {
            for (out, 0..) |slot, i| {
                if (slot) |tys| {
                    for (tys) |t| std.debug.print("[alpt-slot] {s}#{d} arg{d} ty={s}\n", .{ func.fqn, func.id.int(), i, t.name });
                }
            }
        }
    }
    if (!any) {
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// The unique body-bearing generic overload of `name` with `arity` value
/// params (every one typed by the func's own type parameters), or null when
/// none or several exist. The target a callee-generic `::name` slot binds.
///
/// Reads the placed `Func` when phase 2 has lowered the body, else the
/// phase-1 header metadata (`decl_user_sig` + `decl_ast_body`) — the
/// in-memory two-phase build lowers user files while the stdlib funcs are
/// still header stubs, and the answer must not depend on that state.
pub fn genericRefTarget(
    b: *FuncBuilder,
    name: []const u8,
    caller_file: ir.FileId,
    arity: usize,
) Allocator.Error!?FuncId {
    const candidates = try b.module.bareCallCandidates(
        b.allocator,
        name,
        caller_file,
    );
    defer b.allocator.free(candidates);
    var found: ?FuncId = null;
    cands: for (candidates) |id| {
        const f = b.module.funcById(id) orelse continue;
        // An extension (a placed leading `this`, or a header stub's
        // synthesized receiver param) never binds a bare `::name`.
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        const tps = b.module.registry.func_type_params.get(id) orelse continue;
        if (tps.items.len == 0) continue;
        if (f.hasBody()) {
            if (f.params.len != arity or arity == 0) continue;
            if (f.params[f.params.len - 1].is_vararg) continue;
            for (f.params) |*p| {
                if (!nameInList(p.ty.name, tps.items)) continue :cands;
            }
        } else {
            // Phase-1 header stub: judge by the declared metadata, so the
            // answer is the same whether the body is placed yet or not.
            if (!b.module.decl_ast_body.contains(id.int())) continue;
            const sig = b.module.decl_user_sig.get(id.int()) orelse continue;
            if (sig.len != arity or arity == 0) continue;
            if (b.module.decl_user_arity.get(id.int())) |da| {
                if (da.has_vararg) continue;
            }
            for (sig) |*ty| {
                if (!nameInList(ty.name, tps.items)) continue :cands;
            }
        }
        if (found != null) return null;
        found = id;
    }
    return found;
}

const CallableRefArgShapes = struct {
    shapes: []applicability.ArgShape,
    owned_types: []TypeRef = &.{},

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.owned_types) |*ty| ty.deinit(allocator);
        if (self.owned_types.len != 0) allocator.free(self.owned_types);
        allocator.free(self.shapes);
    }
};

/// Expected argument types for a callable reference. A typed local initializer
/// contributes its source function type; an argument position contributes the
/// callee-instantiated lambda parameter types, falling back to arity alone.
pub fn callableRefArgShapes(
    b: *FuncBuilder,
    ref_arity: i16,
) Allocator.Error!?CallableRefArgShapes {
    if (b.pending_ref_lambda_param_types) |types| {
        const shapes = try b.allocator.alloc(applicability.ArgShape, types.len);
        for (types, shapes) |ty, *shape| {
            shape.* = .{ .ty = ty, .ty_authoritative = true };
        }
        return .{ .shapes = shapes };
    }
    if (b.peekExpected()) |expected| {
        if (expected.function) |ft| {
            const types = try b.allocator.alloc(TypeRef, ft.params.len);
            var initialized: usize = 0;
            errdefer {
                for (types[0..initialized]) |*ty| ty.deinit(b.allocator);
                b.allocator.free(types);
            }
            for (ft.params, types) |*param, *ty| {
                ty.* = try loweredOwnedLocalTypeRef(b, param);
                initialized += 1;
            }
            const shapes = try b.allocator.alloc(applicability.ArgShape, types.len);
            for (types, shapes) |ty, *shape| {
                shape.* = .{ .ty = ty, .ty_authoritative = true };
            }
            return .{ .shapes = shapes, .owned_types = types };
        }
    }
    if (ref_arity < 0) return null;
    const shapes = try b.allocator.alloc(applicability.ArgShape, @intCast(ref_arity));
    @memset(shapes, .{});
    return .{ .shapes = shapes };
}

pub fn resolveExtensionRefTarget(
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    ref_shapes: *const CallableRefArgShapes,
) Allocator.Error!?FuncId {
    const receiver_ty = argDeclTypeRefLazy(b, receiver) orelse return null;
    const unbound = receiver.* == .Path and
        receiver.Path.segments.len == 1 and
        b.resolve(receiver.Path.segments[0].name) == null and
        !b.knowsOuter(receiver.Path.segments[0].name) and
        b.module.classIdIndexed(
            receiver.Path.segments[0].name,
            b.self_package,
            name.span.file,
        ) != null;
    const args = if (unbound) blk: {
        if (ref_shapes.shapes.len == 0) return null;
        break :blk ref_shapes.shapes[1..];
    } else ref_shapes.shapes;
    const trace_ref = if (runtime.envOnce("KLIO_BARE_TRACE")) |wanted|
        std.mem.eql(u8, wanted, name.name)
    else
        false;
    if (trace_ref) {
        std.debug.print("[refext] {s} unbound={} expected={d} args={d}", .{
            name.name,
            unbound,
            ref_shapes.shapes.len,
            args.len,
        });
        for (ref_shapes.shapes) |shape| {
            std.debug.print(" {s}", .{if (shape.ty) |ty| ty.name else "?"});
        }
        std.debug.print("\n", .{});
    }

    if (staticTypeClassId(b, receiver_ty)) |owner| {
        if (b.module.resolveMemberCall(owner, name.name, args, .{
            .caller_file = name.span.file,
            .lexical_owner = if (b.ownerClass()) |owner_name|
                b.module.classId(owner_name)
            else
                null,
            .receiver_type = receiver_ty,
        }).applicable) return null;
    }

    const implicit_owners = try b.collectImplicitReceiverTower(
        b.allocator,
        eagerLambdaRecvHead(b),
    );
    defer b.allocator.free(implicit_owners);
    const resolution = b.module.resolveExtensionCall(
        name.name,
        receiver_ty,
        args,
        .{
            .caller_file = name.span.file,
            .caller_package = b.module.packageOfFile(name.span.file) orelse
                b.self_package,
            .implicit_dispatch_owners = implicit_owners,
            .lexical_owner = b.ownerClass(),
            .call_name = name.name,
        },
    );
    const target = resolution.target orelse return null;
    if (trace_ref) std.debug.print("[refext] {s} -> #{d}\n", .{
        name.name,
        target.int(),
    });
    const func = b.module.funcById(target) orelse return null;
    const kind = if (b.module.decl_sigs.get(target.int())) |decl|
        decl.kind
    else
        func.kind;
    if (kind != .top_level_extension) return null;
    return target;
}

fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Lambda-param types for a CONSTRUCTOR call's lambda arguments, read from
/// the class's primary params whose declared types are CONCRETE function
/// types. Positional args only; a param mentioning a type parameter or the
/// suspend marker contributes nothing.
pub fn ctorLambdaParamTypes(
    b: *FuncBuilder,
    class_id: ir.ClassId,
    args: []const Expr,
) Allocator.Error!?[]?[]ir.TypeRef {
    if (class_id.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[class_id.int()];
    if (args.len == 0) return null;
    if (runtime.envOnce("KLIO_CTORLPT_TRACE") != null) {
        std.debug.print("[ctorlpt] {s} nparams={d} p_last_ty={s}<{d}>\n", .{ cls.name, cls.primary_params.len, if (cls.primary_params.len != 0) cls.primary_params[cls.primary_params.len - 1].ty.name else "-", if (cls.primary_params.len != 0) cls.primary_params[cls.primary_params.len - 1].ty.args.len else 0 });
    }
    // The array ctors' trailing init lambda takes the element INDEX
    // whatever the class row records (the (size, init) form is an
    // intrinsic, not the row's primary constructor).
    {
        const n = cls.name;
        const is_array_ctor = std.mem.eql(u8, n, "Array") or
            (std.mem.endsWith(u8, n, "Array") and isPrimitiveTypeName(n[0 .. n.len - "Array".len]));
        if (is_array_ctor and args.len == 2 and args[args.len - 1] == .Lambda) {
            const out0 = try b.allocator.alloc(?[]ir.TypeRef, args.len);
            @memset(out0, null);
            errdefer deinitArgLambdaParamTypes(b.allocator, out0);
            const tys0 = try b.allocator.alloc(ir.TypeRef, 1);
            tys0[0] = .{ .name = try b.allocator.dupe(u8, "Int"), .nullable = false, .args = &.{} };
            out0[args.len - 1] = tys0;
            return out0;
        }
    }
    if (cls.primary_params.len == 0) return null;
    var any = false;
    const out = try b.allocator.alloc(?[]ir.TypeRef, args.len);
    @memset(out, null);
    errdefer deinitArgLambdaParamTypes(b.allocator, out);
    for (args, 0..) |*arg, i| {
        if (arg.* != .Lambda) continue;
        if (i >= cls.primary_params.len) break;
        const pt = cls.primary_params[i].ty;
        const head = typeHead(std.mem.trimEnd(u8, pt.name, "?"));
        if (!std.mem.startsWith(u8, head, "Function") and
            !std.mem.eql(u8, head, "<function>")) continue;
        if (pt.args.len < 2) continue;
        const value_ins = pt.args[0 .. pt.args.len - 1];
        var ok = true;
        for (value_ins) |vi| {
            const h2 = typeHead(std.mem.trimEnd(u8, vi.name, "?"));
            if (h2.len == 0 or h2[0] == '#' or bareTypeParamHead(h2) or
                ir.parseClassTypeParamIdentity(h2) != null)
            {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        const tys = try b.allocator.alloc(ir.TypeRef, value_ins.len);
        var filled: usize = 0;
        errdefer {
            for (tys[0..filled]) |*t| t.deinit(b.allocator);
            b.allocator.free(tys);
        }
        for (value_ins) |vi| {
            tys[filled] = try vi.clone(b.allocator);
            filled += 1;
        }
        out[i] = tys;
        any = true;
    }
    if (!any) {
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// The lambda-param types a fun-interface SAM conversion hands its sole
/// lambda argument: the interface's single abstract method's value-param
/// types, substituted under the class's type params as bound by the call's
/// explicit type arguments or the site's EXPECTED type. Null when neither
/// binds, when the interface has no sole abstract method, or when the
/// method takes no value params.
pub fn samLambdaParamTypes(
    b: *FuncBuilder,
    class_id: ir.ClassId,
    ast_type_args: []const ast.TypeRef,
) Allocator.Error!?[]?[]ir.TypeRef {
    if (class_id.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[class_id.int()];
    const st = runtime.envOnce("KLIO_SAM_TRACE") != null;
    var sam_fid: ?FuncId = null;
    for (cls.methods) |mfid| {
        const mf0 = b.module.funcById(mfid) orelse continue;
        if (mf0.hasBody()) continue;
        if (sam_fid != null) {
            if (st) std.debug.print("[sam-in] multi-abstract {s} + {s}\n", .{ b.module.funcById(sam_fid.?).?.name, mf0.name });
            return null;
        }
        sam_fid = mfid;
    }
    // An image class row can carry no method list (lazy header); the
    // member registry still records the interface's declared methods.
    if (sam_fid == null) {
        var prefix_buf: [160]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}\x00", .{cls.name}) catch return null;
        var it = b.module.registry.member_method_fids.iterator();
        while (it.next()) |e| {
            if (!std.mem.startsWith(u8, e.key_ptr.*, prefix)) continue;
            const mf0 = b.module.funcById(e.value_ptr.*) orelse continue;
            if (mf0.hasBody()) continue;
            if (sam_fid != null and sam_fid.?.int() != e.value_ptr.int()) {
                if (st) std.debug.print("[sam-in] registry multi-abstract\n", .{});
                return null;
            }
            sam_fid = e.value_ptr.*;
        }
    }
    if (st) std.debug.print("[sam-in] methods={d} sam={}\n", .{ cls.methods.len, sam_fid != null });
    const mf = b.module.funcById(sam_fid orelse return null) orelse return null;
    const base: usize = if (mf.params.len != 0 and std.mem.eql(u8, mf.params[0].name, "this")) 1 else 0;
    if (mf.params.len == base) return null;
    var scratch = std.heap.ArenaAllocator.init(b.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var binds: std.ArrayList(ir.Module.TypeBinding) = .empty;
    if (ast_type_args.len == cls.type_params.len and ast_type_args.len != 0) {
        for (cls.type_params, ast_type_args) |tp, *ta| {
            const ty = try decl_mod.loweredTypeRef(a, ta, true);
            try binds.append(a, .{ .name = tp, .ty = ty });
            // The registry may spell the method's params with the class
            // identity mangle; bind that spelling too.
            try binds.append(a, .{ .name = try ir.classTypeParamIdentity(a, class_id, tp), .ty = ty });
        }
    } else if (b.peekExpected()) |exp| {
        if (exp.function == null and exp.type_args.len == cls.type_params.len and
            exp.type_args.len != 0 and std.mem.eql(u8, exp.name.name, cls.name))
        {
            for (cls.type_params, exp.type_args) |tp, ta| {
                if (ta.is_star) return null;
                const ty = try decl_mod.loweredTypeRef(a, &ta.ty, true);
                try binds.append(a, .{ .name = tp, .ty = ty });
                try binds.append(a, .{ .name = try ir.classTypeParamIdentity(a, class_id, tp), .ty = ty });
            }
        }
    }
    if (st and binds.items.len == 0) {
        if (b.peekExpected()) |exp| std.debug.print("[sam-in] nobind exp_name={s} exp_targs={d} exp_fn={}\n", .{ exp.name.name, exp.type_args.len, exp.function != null })
        else std.debug.print("[sam-in] nobind noexp\n", .{});
    }
    if (binds.items.len == 0) return null;
    const out = try b.allocator.alloc(?[]ir.TypeRef, 1);
    out[0] = null;
    errdefer b.allocator.free(out);
    const tys = try b.allocator.alloc(ir.TypeRef, mf.params.len - base);
    var filled: usize = 0;
    errdefer {
        for (tys[0..filled]) |*t| t.deinit(b.allocator);
        b.allocator.free(tys);
    }
    for (mf.params[base..]) |*p2| {
        const sub = try ir.Module.substituteBoundType(a, p2.ty, binds.items);
        tys[filled] = try sub.clone(b.allocator);
        filled += 1;
    }
    out[0] = tys;
    return out;
}
