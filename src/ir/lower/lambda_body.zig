//! Lambda-body lowering: a lambda literal's body lowers into a standalone `Func`
//! closing over the enclosing scope's registers.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");

const ast_scan = @import("ast_scan.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Module = ir.Module;
const FuncId = ir.FuncId;
const Reg = ir.Reg;
const Inst = ir.Inst;
const Const = ir.Const;
const Param = ir.Param;
const Terminator = ir.Terminator;
const TypeRef = ir.TypeRef;
const StringSet = std.StringHashMap(void);
/// The per-name local-fn overload registry a nested body inherits.
pub const LocalFnOverloadTable = std.StringHashMap(std.ArrayList(build.LocalFnOverload));

/// The lexically enclosing class context, so an enclosing-class member
/// out-prioritises a same-named imported extension.
pub const EnclosingOwner = struct {
    class: []const u8,
    members: StringSet,
};

/// The declared receiver and value-parameter count of a lowered function type. The
/// encoding is `[#suspend?] [receiver?] params… ret [#markers]`, so a receiver is
/// one extra leading entry over `FunctionN`'s N.
const RecvFnShape = struct { arity: usize, recv_head: []const u8 };

fn loweredRecvFnShape(ty: *const TypeRef) ?RecvFnShape {
    if (!std.mem.startsWith(u8, ty.name, "Function")) return null;
    const want = std.fmt.parseInt(usize, ty.name["Function".len..], 10) catch return null;
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    if (hi == 0) return null;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    hi -= 1;
    if (hi < lo) return null;
    const mid = ty.args[lo..hi];
    if (mid.len != want + 1) return null;
    return .{ .arity = want, .recv_head = mid[0].name };
}

/// The allocator backing a `Module`'s growable tables, recovered from a managed
/// member since the containers are unmanaged.
fn moduleAllocator(module: *Module) Allocator {
    return module.func_name_index.allocator;
}

/// The body `Func`'s id plus the capture-name list, in `LoadCapture` index order,
/// the construction site must snapshot.
pub const LoweredLambda = struct {
    func: FuncId,
    captures: [][]const u8,
};

/// Resolve a name inside a lambda body, recording a capture and emitting
/// `LoadCapture` when the name lives in the enclosing frame.
pub fn resolveCapture(b: *FuncBuilder, name: []const u8) Allocator.Error!Reg {
    if (b.resolve(name)) |r| {
        return r;
    }
    // A lambda body's implicit `this` is bound at invoke time through the closure's
    // capture slot, not a scope binding or `outer_names` entry, so
    // `knowsOuter("this")` is false even though `this` is reachable. Mirror the
    // `isLambdaBody()` signal `Expr.This` uses, so a nested lambda can forward
    // `this` through its own capture slot rather than collapse it to `Unit`.
    if (std.mem.eql(u8, name, "this") and b.capturesThisSlot()) {
        const dst = try b.loadCaptureHoisted("this");
        try b.bind("this", dst);
        return dst;
    }
    if (b.knowsOuter(name)) {
        const dst = try b.loadCaptureHoisted(name);
        try b.bind(name, dst);
        return dst;
    }
    // A name the enclosing anon object closes over forwards through this builder's
    // capture slot, the anon method's captures being supplied by name at dispatch;
    // the silent-Unit tail below would bind it to nothing. A local class's methods
    // and ctor-argument thunks carry the same enclosing locals.
    if (decl.isLowerAnonCapture(name) or build.anonCaptureBinds(name)) {
        return try b.loadCaptureHoisted(name);
    }
    // A zero-parameter or receiver lambda whose `it` was not bound, with no
    // enclosing lambda supplying one, is an unresolved reference in Kotlin; record
    // the diagnostic so the driver fails before the run.
    if (b.it_suppressed and std.mem.eql(u8, name, "it")) {
        if (b.it_suppressed_span) |sp| {
            try b.module.resolve_diags.append(b.allocator, .{
                .name = "it",
                .fqn_a = "",
                .fqn_b = "",
                .span = sp,
                .kind = .unresolved_local,
            });
        }
    }
    const dst = b.allocReg();
    const unit = try b.module.internConst(b.allocator, .Unit);
    if (std.c.getenv("KLIO_TRACE_CAPTURE") != null) {
        std.debug.print("[CAPTURE] unresolved `{s}` collapses to Unit\n", .{name});
    }
    try b.push(.{ .Const = .{ .dst = dst, .value = unit } });
    return dst;
}

/// Lower a lambda body, threading the enclosing builder's visible-name set so Path
/// references that hit it lower to `LoadCapture`. Returns the body's `FuncId` plus
/// the captured names, which the caller ships through `Inst.Lambda::captures`.
pub fn lowerLambdaBodyCapturing(
    module: *Module,
    params: []const ast.Ident,
    param_tys: []const ?ast.TypeRef,
    body: *const ast.Block,
    outer: StringSet,
    outer_boxed: *const StringSet,
    inherited_rlp: StringSet,
    inherited_lef: std.StringHashMap(i8),
    inherited_erp: StringSet,
    enclosing_owner: ?EnclosingOwner,
) Allocator.Error!LoweredLambda {
    return lowerLambdaBodyCapturingKind(
        module,
        params,
        param_tys,
        body,
        outer,
        true,
        outer_boxed,
        null,
        inherited_rlp,
        inherited_lef,
        inherited_erp,
        enclosing_owner,
    );
}

pub fn lowerLambdaBodyCapturingKind(
    module: *Module,
    params: []const ast.Ident,
    param_tys: []const ?ast.TypeRef,
    body: *const ast.Block,
    outer: StringSet,
    is_lambda: bool,
    outer_boxed: *const StringSet,
    tailrec_self: ?[]const u8,
    inherited_rlp: StringSet,
    inherited_lef: std.StringHashMap(i8),
    inherited_erp: StringSet,
    enclosing_owner: ?EnclosingOwner,
) Allocator.Error!LoweredLambda {
    return lowerLambdaBodyCapturingKindWith(
        module,
        params,
        param_tys,
        body,
        outer,
        is_lambda,
        outer_boxed,
        tailrec_self,
        false,
        false,
        inherited_rlp,
        inherited_lef,
        inherited_erp,
        null,
        enclosing_owner,
    );
}

// Innermost rung of the lambda-body wrapper chain; each flag is threaded from the AST.
pub fn lowerLambdaBodyCapturingKindWith(
    module: *Module,
    params: []const ast.Ident,
    param_tys: []const ?ast.TypeRef,
    body: *const ast.Block,
    outer: StringSet,
    is_lambda: bool,
    outer_boxed: *const StringSet,
    tailrec_self: ?[]const u8,
    is_named_local_fn: bool,
    named_local_encl_recv: bool,
    inherited_rlp: StringSet,
    inherited_lef: std.StringHashMap(i8),
    inherited_erp: StringSet,
    inherited_lfo: ?*const LocalFnOverloadTable,
    enclosing_owner: ?EnclosingOwner,
) Allocator.Error!LoweredLambda {
    return lowerLambdaBodyCapturingKindWithIt(
        module,
        params,
        param_tys,
        body,
        outer,
        is_lambda,
        outer_boxed,
        tailrec_self,
        is_named_local_fn,
        named_local_encl_recv,
        inherited_rlp,
        inherited_lef,
        inherited_erp,
        inherited_lfo,
        enclosing_owner,
        false,
        null,
        &.{},
        &.{},
    );
}

/// The state one lambda-body lowering threads through its phases.
///
/// The driver builds one of these and hands every phase a pointer to it. The
/// builder is a driver local, so its teardown stays with the scope that owns it.
const LambdaBodyCtx = struct {
    module: *Module,
    b: *FuncBuilder,
    params: []const ast.Ident,
    param_tys: []const ?ast.TypeRef,
    body: *const ast.Block,
    is_lambda: bool,
    suppress_it: bool,
};

/// How the body terminates: a local `fun`'s block body and a lambda bound to a
/// `-> Unit` parameter both return Unit rather than the tail expression's value.
const BodyReturnShape = struct {
    fn_block_body: bool,
    unit_body: bool,
};

/// As `lowerLambdaBodyCapturingKindWith`, with the explicit-`it` suppression
/// decision: `suppress_it` declares no implicit `it`, so an `it` inside resolves to
/// an enclosing lambda's or is rejected.
pub fn lowerLambdaBodyCapturingKindWithIt(
    module: *Module,
    params: []const ast.Ident,
    param_tys: []const ?ast.TypeRef,
    body: *const ast.Block,
    outer: StringSet,
    is_lambda: bool,
    outer_boxed: *const StringSet,
    tailrec_self: ?[]const u8,
    is_named_local_fn: bool,
    named_local_encl_recv: bool,
    inherited_rlp: StringSet,
    inherited_lef: std.StringHashMap(i8),
    inherited_erp: StringSet,
    inherited_lfo: ?*const LocalFnOverloadTable,
    enclosing_owner: ?EnclosingOwner,
    suppress_it: bool,
    it_span: ?ast.Span,
    broad_coll_params: []const []const u8,
    generic_typed_params: []const []const u8,
) Allocator.Error!LoweredLambda {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    b.setBodySpan(body.span);
    b.it_suppressed = suppress_it;
    b.it_suppressed_span = it_span;
    var ctx: LambdaBodyCtx = .{
        .module = module,
        .b = &b,
        .params = params,
        .param_tys = param_tys,
        .body = body,
        .is_lambda = is_lambda,
        .suppress_it = suppress_it,
    };
    try adoptEnclosingReceiver(&ctx);
    try inheritEnclosingLocals(&ctx);
    const shape = consumeBodyReturnShape(&ctx);
    try inheritTypeParamContext(&ctx);
    bindEnclosingNameScope(&ctx, enclosing_owner, outer, is_named_local_fn, named_local_encl_recv);
    // A captured `block: T.() -> R` must still dispatch a bare `block()` as
    // `this.block()`, so carry the receiver-lambda-param names across the boundary.
    var inherited = inherited_rlp;
    defer inherited.deinit();
    // The same carrier for local extension functions, whose captured bare call must
    // still prepend the enclosing receiver.
    var inherited_ext = inherited_lef;
    defer inherited_ext.deinit();
    // A captured parameter with an unbounded type-parameter type stays statically
    // erased inside nested lambdas, so an explicit receiver call keeps its callable
    // fallback instead of consulting members on the runtime value.
    var inherited_erased = inherited_erp;
    defer inherited_erased.deinit();
    try inheritCapturedCallables(&ctx, &inherited, &inherited_ext, &inherited_erased, inherited_lfo);
    markTailrecSelf(&ctx, tailrec_self);
    var boxed = try computeBodyBoxedVars(&ctx, outer_boxed);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(b.allocator);
    try collectParamNames(&ctx, &names);
    try boxParamsAssignedInNestedLambdas(&ctx, names.items, &boxed);
    b.setBoxedVars(boxed);
    try decl.bindParams(&b, names.items);
    try bindAnonContextParams(&ctx);
    try bindInferredParamTypes(&ctx, names.items);
    try bindAnnotatedParamTypes(&ctx);
    try bindLocalContextParams(&ctx);
    try bindImplicitThisLabel(&ctx);
    try markTypedParamKinds(&ctx, broad_coll_params, generic_typed_params);
    try markReceiverLambdaParams(&ctx);
    try lowerBodyAndTerminate(&ctx, shape);
    return try finishBodyFunc(&ctx, names.items, shape.unit_body);
}

// -------------------------------------------------------------------------
// Inheriting the construction site's context.
// -------------------------------------------------------------------------

/// Adopt the receiver context the construction site stashed on the module: the
/// receiver in scope at that site, the implicit-receiver tower, and the
/// receiver this body owns outright.
fn adoptEnclosingReceiver(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    const body = ctx.body;
    // The receiver in scope at this body's construction site, the enclosing `this`
    // or this receiver lambda's own, stashed by `lowerLambda`. Carried so a bare
    // call can disambiguate a receiver-lambda argument's arity, `recv_ty` being null
    // inside a lambda.
    if (module.pending_lambda_enclosing_recv) |rt| {
        module.pending_lambda_enclosing_recv = null;
        b.setEnclosingRecvTy(rt);
    }
    if (module.pending_lambda_receiver_tower) |tower| {
        module.pending_lambda_receiver_tower = null;
        defer moduleAllocator(module).free(tower);
        try b.setImplicitReceiverTower(tower);
    }
    // A local extension function's body owns its declared receiver outright, the
    // standing a top-level extension body gets from `setRecvTy`.
    if (std.c.getenv("KLIO_LAR_TRACE") != null) {
        std.debug.print("[lar-body] s={d} own_ty={s} own={s}\n", .{ body.span.start, if (module.pending_lambda_own_recv_type) |r| r.name else "-", module.pending_lambda_own_recv orelse "-" });
    }
    if (module.pending_lambda_own_recv_type) |receiver| {
        module.pending_lambda_own_recv_type = null;
        module.pending_lambda_own_recv = null;
        b.setRecvTypeRefOwned(receiver);
    } else if (module.pending_lambda_own_recv) |rt| {
        module.pending_lambda_own_recv = null;
        b.setRecvTy(rt);
    }
}

/// Inherit what the enclosing frame knows about its locals: the enclosing local
/// `fun`'s identity, the definitely-non-callable names, and the declared types
/// a member call in this body resolves against.
fn inheritEnclosingLocals(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    // The enclosing local `fun`'s identity, so a bare self-reference binds through
    // the mangled cell.
    if (module.pending_lambda_self_fn) |slf| {
        module.pending_lambda_self_fn = null;
        b.setSelfLocalFn(slf);
    }
    // Enclosing-scope locals with definite non-callable evidence: a bare call of one
    // never routes through the captured value.
    if (module.pending_lambda_nonfn_locals) |*nf| {
        try b.inheritNonFnLocals(nf);
        var nf_own = nf.*;
        nf_own.deinit();
        module.pending_lambda_nonfn_locals = null;
    }
    // `KLIO_LAMINH=1` traces the declared-type inheritance channel: an empty
    // inherited snapshot while the enclosing builder holds records means the body
    // lowered from the wrong builder, costing every member call its receiver type.
    if (std.c.getenv("KLIO_LAMINH") != null) {
        std.debug.print("[laminh] consume pending={?d} nonfn={} params={?d}\n", .{
            if (module.pending_lambda_local_decl_types) |l| l.types.count() else null,
            module.pending_lambda_nonfn_locals != null,
            if (module.pending_lambda_param_types) |pt| pt.len else null,
        });
    }
    b.own_recv_known_none = module.pending_lambda_no_receiver;
    module.pending_lambda_no_receiver = false;
    if (module.pending_lambda_local_decl_types) |*locals| {
        try b.inheritLocalDeclTypes(locals);
        var owned = locals.*;
        var type_it = owned.types.valueIterator();
        while (type_it.next()) |ty| ty.deinit(b.allocator);
        owned.types.deinit();
        owned.nullable.deinit();
        owned.call_returns.deinit();
        module.pending_lambda_local_decl_types = null;
    }
    if (b.recvTypeRef()) |receiver| {
        try b.setLocalDeclTypeOwned(
            "this",
            try receiver.clone(b.allocator),
        );
    }
}

/// Consume the pending flags deciding whether the body returns its tail
/// expression or Unit.
fn consumeBodyReturnShape(ctx: *LambdaBodyCtx) BodyReturnShape {
    const module = ctx.module;
    // A local `fun`'s block body returns Unit on fall-through, while a lambda
    // literal keeps last-expression semantics. Consumed before any nested lambda
    // lowers, so it never leaks inward.
    const fn_block_body = module.pending_lambda_fn_block_body;
    module.pending_lambda_fn_block_body = false;
    // A lambda literal bound to a `-> Unit` parameter returns Unit, its tail running
    // for effect. Consumed before any nested lambda lowers.
    const unit_body = module.pending_lambda_unit;
    module.pending_lambda_unit = false;
    return .{ .fn_block_body = fn_block_body, .unit_body = unit_body };
}

/// Inherit the enclosing type-parameter environment: erased parameter names,
/// reified substitutions, declared bounds and context-function shapes.
fn inheritTypeParamContext(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    // Enclosing non-reified type params, so an `x as T` cast in this body is erased.
    if (module.pending_lambda_type_params) |tps| {
        module.pending_lambda_type_params = null;
        defer moduleAllocator(module).free(tps);
        for (tps) |tp| try b.addTypeParamName(tp);
    }
    // The enclosing splice's reified substitutions, so `filter { it is R }` inside a
    // spliced `filterIsInstance<reified R>` resolves `R` here.
    if (module.pending_lambda_reified_names) |names| {
        module.pending_lambda_reified_names = null;
        defer moduleAllocator(module).free(names);
        for (names) |rn| _ = try b.bindReifiedTypeName(rn.name, rn.actual);
    }
    if (module.pending_lambda_type_param_bounds) |bounds| {
        module.pending_lambda_type_param_bounds = null;
        defer moduleAllocator(module).free(bounds);
        for (bounds) |bound| {
            // Keep the bound's concrete args, registry-lifetime slices; dropping
            // them degrades the record to head-only one lambda level down and offers
            // bare `T` to extension resolution.
            try b.addTypeParamBoundHeadArgs(bound.param, bound.bound, bound.complete, bound.head_only, bound.args);
        }
    }
    if (module.pending_lambda_type_param_bound_refs) |refs| {
        module.pending_lambda_type_param_bound_refs = null;
        defer moduleAllocator(module).free(refs);
        for (refs) |r| {
            try b.addTypeParamBoundRef(r.param, r.ref);
        }
    }
    if (module.pending_lambda_ctx_fn_shapes) |shapes| {
        module.pending_lambda_ctx_fn_shapes = null;
        defer moduleAllocator(module).free(shapes);
        for (shapes) |sh| try b.markContextFnParam(sh.name, sh.ctx_types, sh.n_regular);
    }
}

/// Bind the name scope the body resolves against: the lexically enclosing class
/// and the enclosing frame's visible names.
fn bindEnclosingNameScope(
    ctx: *LambdaBodyCtx,
    enclosing_owner: ?EnclosingOwner,
    outer: StringSet,
    is_named_local_fn: bool,
    named_local_encl_recv: bool,
) void {
    const b = ctx.b;
    const is_lambda = ctx.is_lambda;
    // Carry the lexically enclosing class and its member-name set so a member
    // reference inside the lambda resolves against the declaring class, ahead of a
    // same-named imported extension.
    if (enclosing_owner) |eo| {
        b.setOwnerClass(eo.class);
        b.setEnclosingMembers(eo.members);
    }
    if (is_named_local_fn) {
        b.setOuterNamesNamedLocalFn(outer, named_local_encl_recv);
    } else if (is_lambda) {
        b.setOuterNames(outer);
    } else {
        b.setOuterNamesWithoutLambda(outer);
    }
}

/// Carry the enclosing scope's callable classifications across the boundary, so
/// a bare call of a captured callable keeps its declaration-site shape.
fn inheritCapturedCallables(
    ctx: *LambdaBodyCtx,
    inherited: *const StringSet,
    inherited_ext: *const std.StringHashMap(i8),
    inherited_erased: *const StringSet,
    inherited_lfo: ?*const LocalFnOverloadTable,
) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    try b.inheritReceiverLambdaParams(inherited);
    // The declared receiver heads ride the module's pending slot, the name set above
    // carrying no types, so a captured receiver-typed callable re-selects its
    // receiver by the declared head.
    if (module.pending_lambda_recv_heads) |heads| {
        module.pending_lambda_recv_heads = null;
        defer moduleAllocator(module).free(heads);
        for (heads) |kv| {
            try b.setReceiverLambdaRecvHead(kv.name, kv.head);
        }
    }
    try b.inheritLocalExtFns(inherited_ext);
    try b.inheritErasedRecvParams(inherited_erased);
    // And for local-fn overload sets: a call to a captured local fn declared more
    // than once must still select the applicable sibling by its mangled binding.
    if (inherited_lfo) |table| {
        try b.inheritLocalFnOverloads(table);
    }
}

/// Put a local tailrec function's body in tail position under its own name.
fn markTailrecSelf(ctx: *LambdaBodyCtx, tailrec_self: ?[]const u8) void {
    const b = ctx.b;
    if (tailrec_self) |name| {
    // A local tailrec function body is in tail position: its last statement or
    // `return` operand may jump.
        b.tail_pos = true;
        b.setTailrecSelf(name);
    }
}

// -------------------------------------------------------------------------
// Parameters and the body's own bindings.
// -------------------------------------------------------------------------

/// The names this body boxes onto shared cells: the ones it mutates itself,
/// plus the enclosing boxed names it references.
fn computeBodyBoxedVars(ctx: *LambdaBodyCtx, outer_boxed: *const StringSet) Allocator.Error!StringSet {
    const b = ctx.b;
    const body = ctx.body;
    var boxed = try ast_scan.computeBoxedVars(b.allocator, body.stmts);
    if (outer_boxed.count() != 0) {
        var refs = StringSet.init(b.allocator);
        defer refs.deinit();
        for (body.stmts) |*s| {
            try ast_scan.collectPathIdentsStmt(s, &refs);
        }
        var it = outer_boxed.keyIterator();
        while (it.next()) |n| {
            if (refs.contains(n.*)) {
                try boxed.put(n.*, {});
            }
        }
    }
    return boxed;
}

/// The body's parameter names: the declared ones, plus the implicit `it` a
/// zero-parameter lambda binds.
fn collectParamNames(ctx: *LambdaBodyCtx, names: *std.ArrayList([]const u8)) Allocator.Error!void {
    const b = ctx.b;
    const params = ctx.params;
    const suppress_it = ctx.suppress_it;
    for (params) |p| try names.append(b.allocator, p.name);
    if (params.len == 0 and !suppress_it) {
        try names.append(b.allocator, "it");
    }
}

/// Box the parameters a deeper nested lambda writes.
fn boxParamsAssignedInNestedLambdas(
    ctx: *LambdaBodyCtx,
    names: []const []const u8,
    boxed: *StringSet,
) Allocator.Error!void {
    const b = ctx.b;
    const body = ctx.body;
    // A lambda parameter a deeper nested lambda writes is a captured-and-mutated
    // local, so box it onto a shared cell rather than the StoreGlobal fallback.
    {
        var assigned = ast_scan.StringSet.init(b.allocator);
        defer assigned.deinit();
        try ast_scan.namesAssignedInLambdasRebindsOnly(body.stmts, &assigned);
        for (names) |pname| {
            if (assigned.contains(pname)) try boxed.put(pname, {});
        }
    }
}

/// Bind an anonymous context function's context names from the context stack.
fn bindAnonContextParams(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    // An anonymous context function binds its context names from the context stack,
    // which the caller's `CtxCall` fills.
    if (module.pending_lambda_ctx_params) |ctx_params| {
        module.pending_lambda_ctx_params = null;
        module.has_context_decls = true;
        for (ctx_params) |cp| {
            const r = b.allocReg();
            const ty_c = try b.module.internConst(b.allocator, .{ .String = cp.ty.name.name });
            try b.push(.{ .CtxLoad = .{ .dst = r, .ty = ty_c, .erased = false } });
            try b.bind(cp.name.name, r);
        }
    }
}

/// Bind the parameter types the pass stamped on an unannotated lambda,
/// clearing the inherited enclosing-local records the names shadow.
fn bindInferredParamTypes(ctx: *LambdaBodyCtx, names: []const []const u8) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    const param_tys = ctx.param_tys;
    // Parameter names shadow inherited enclosing-local records; without this a
    // nested lambda's `it` types from the outer `it`'s record.
    for (names) |nm| b.clearLocalDeclType(nm);
    if (module.pending_lambda_param_types) |expected_types| {
        module.pending_lambda_param_types = null;
        defer moduleAllocator(module).free(expected_types);
    // The producer clamps the type list to `min(ref types, value params)`, so bind
    // the leading names that have a type and free any surplus.
        const bind_n = @min(expected_types.len, names.len);
        for (expected_types[0..bind_n], names[0..bind_n], 0..) |expected, name, i| {
            var owned = expected;
            if (i < param_tys.len and param_tys[i] != null) {
                owned.deinit(b.allocator);
                continue;
            }
            // A lambda parameter whose expected type is a receiver-typed function is
            // a receiver-lambda param exactly as an annotated one is, so a bare call
            // invokes it with the enclosing `this`. Only annotated types reach the
            // classification loop below, so an inferred parameter is marked here.
            if (loweredRecvFnShape(&owned)) |shape| {
                try b.markReceiverLambdaParam(name);
                try b.markReceiverLambdaArity(name, shape.arity);
                try b.setReceiverLambdaRecvHead(name, if (b.isTypeParam(shape.recv_head)) null else shape.recv_head);
            }
            try b.setLocalDeclTypeOwned(name, owned);
        }
        for (expected_types[bind_n..]) |surplus| {
            var owned = surplus;
            owned.deinit(b.allocator);
        }
    }
}

/// Bind the source-annotated parameter types, with a vararg parameter taking
/// the materialized array head its annotation's element type implies.
fn bindAnnotatedParamTypes(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    const params = ctx.params;
    const param_tys = ctx.param_tys;
    const vararg_names = module.pending_lambda_vararg_params;
    module.pending_lambda_vararg_params = null;
    for (params, 0..) |p, i| {
        if (i >= param_tys.len) break;
        const ty = param_tys[i] orelse continue;
        if (ty.function) |ft| {
            try b.setLocalCallReturn(p.name, ft.ret.name.name, ft.ret.nullable);
        }
        // A local `fun`'s vararg parameter is the materialized array inside the body
        // while its annotation names the element, so register the array head.
        const is_vararg = blk: {
            for (vararg_names orelse &.{}) |vn| {
                if (std.mem.eql(u8, vn, p.name)) break :blk true;
            }
            break :blk false;
        };
        if (is_vararg) {
            try b.setLocalDeclTypeOwned(p.name, try decl.varargArrayTypeRef(b.allocator, &ty));
            continue;
        }
    // A source-annotated or pass-stamped lambda parameter type is authoritative for
    // member resolution in the body, like a declared function parameter's.
        try b.setLocalDeclTypeOwned(p.name, try decl.loweredTypeRef(b.allocator, &ty, true));
        if (ty.nullable) try b.setLocalDeclNullable(p.name);
    }
}

/// Emit the context-parameter loads a local contextual function's body opens
/// with.
fn bindLocalContextParams(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    // A local contextual function's context parameters bind here, before the body
    // statements lower.
    if (module.pending_ctx) |pc| {
        module.pending_ctx = null;
        try decl.emitContextParamLoads(b, pc.params, pc.type_params);
    }
}

/// Bind an argument lambda's implicit `this@label` to the receiver the invoke
/// fills in.
fn bindImplicitThisLabel(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const module = ctx.module;
    const b = ctx.b;
    const body = ctx.body;
    const is_lambda = ctx.is_lambda;
    // An argument lambda's implicit label names its receiver, so bind the label to
    // the receiver the invoke fills in and let a nested scope capture this one
    // rather than the innermost `this`.
    const this_label = module.pending_lambda_this_label;
    module.pending_lambda_this_label = null;
    if (is_lambda and this_label != null) {
        const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{this_label.?});
        if (b.resolve(label) == null) {
            // A body whose receiver is its own binding gets the label
            // unconditionally, the bind being free and making the receiver reachable
            // by name from nested scopes. A body whose `this` needs a capture only
            // binds when the source references the label.
            if (b.resolve("this")) |tr| {
                try b.bind(label, tr);
                if (b.recvTy() != null) b.setOwnThisLabel(this_label.?);
            } else if (ast_scan.referencesQualifiedThis(body.stmts, this_label.?)) {
                const this_reg: ?Reg = blk: {
                    break :blk try b.loadCaptureHoisted("this");
                };
                if (this_reg) |tr| try b.bind(label, tr);
            }
        }
    }
}

/// Mark the parameters whose expected type gives them a static classification
/// the runtime value alone would not.
fn markTypedParamKinds(
    ctx: *LambdaBodyCtx,
    broad_coll_params: []const []const u8,
    generic_typed_params: []const []const u8,
) Allocator.Error!void {
    const b = ctx.b;
    // A lambda parameter statically typed as a broad collection yields a `List` from
    // `+`/`-` even over a runtime `Set`, so the operator lowering coerces.
    for (broad_coll_params) |pname| {
        try b.markBroadCollectionLocal(pname);
    }
    // A lambda parameter whose expected type is one of the callee's own type
    // parameters carries Kotlin's generic static typing: comparisons follow the
    // `compareTo` total order, and a container built from such values is generic.
    for (generic_typed_params) |pname| {
        try b.markGenericTypedParam(pname);
    }
}

/// Classify the parameters declared with an extension-function type, so a bare
/// call binds its first argument as the receiver.
fn markReceiverLambdaParams(ctx: *LambdaBodyCtx) Allocator.Error!void {
    const b = ctx.b;
    const params = ctx.params;
    const param_tys = ctx.param_tys;
    // A local fn's params get the classification `decl.zig` gives a top-level fn's:
    // a param declared with an extension-function type is a receiver-lambda param,
    // so a bare call binds its first argument as the receiver.
    for (params, 0..) |pname, pi| {
        if (pi >= param_tys.len) break;
        const t = param_tys[pi] orelse {
            // An unannotated param's declared shape from typeck.
            if (b.module.eagerParamShapeOf(pname.span)) |shape| {
                if (shape.has_receiver) {
                    try b.markReceiverLambdaParam(pname.name);
                    try b.markReceiverLambdaArity(pname.name, shape.arity);
                }
            }
            continue;
        };
        if (t.function) |fnty| {
            if (fnty.receiver != null) {
                try b.markReceiverLambdaParam(pname.name);
                try b.markReceiverLambdaArity(pname.name, fnty.params.len);
                const rh = fnty.receiver.?.name.name;
                try b.setReceiverLambdaRecvHead(pname.name, if (b.isTypeParam(rh)) null else rh);
            }
        } else if (b.module.registry.recv_fn_aliases.get(t.name.name)) |ar| {
            // An aliased receiver-fn type: the alias registry keeps the
            // receiver-ness the `Function{N}` tag drops.
            try b.markReceiverLambdaParam(pname.name);
            try b.markReceiverLambdaArity(pname.name, ar);
        }
    }
}

// -------------------------------------------------------------------------
// Lowering the body and finishing the func.
// -------------------------------------------------------------------------

/// Lower the body statements and terminate on the value the return shape calls
/// for.
fn lowerBodyAndTerminate(ctx: *LambdaBodyCtx, shape: BodyReturnShape) Allocator.Error!void {
    const b = ctx.b;
    const body = ctx.body;
    const fn_block_body = shape.fn_block_body;
    const unit_body = shape.unit_body;
    const result = try expr.lowerBlock(b, body);
    if (fn_block_body or unit_body) {
        // `fun f() { 42 }` returns Unit; an explicit `return` terminates earlier.
        const unit_dst = b.allocReg();
        const unit = try b.module.internConst(b.allocator, .Unit);
        try b.push(.{ .Const = .{ .dst = unit_dst, .value = unit } });
        b.terminate(.{ .Return = unit_dst });
    } else {
        b.terminate(.{ .Return = result });
    }
}

/// The declared parameter slots the body func carries.
fn placeDeclaredParams(ctx: *LambdaBodyCtx, names: []const []const u8) Allocator.Error![]Param {
    const b = ctx.b;
    const param_tys = ctx.param_tys;
    // Declared parameter annotations land on the body func so runtime overload
    // dispatch can match the value against a declared function-type parameter.
    // Unannotated slots keep the Unit placeholder, which dispatch reads as unknown.
    const placed_params = try b.allocator.alloc(Param, names.len);
    for (names, placed_params, 0..) |n, *dst, i| {
        const ty: ir.TypeRef = blk: {
            if (i < param_tys.len) {
                if (param_tys[i]) |*t| break :blk try decl.loweredTypeRef(b.allocator, t, false);
            }
            break :blk build.typeUnit();
        };
        dst.* = .{
            .name = n,
            .ty = ty,
            .default = null,
            .is_property = false,
            .is_vararg = false,
            .has_default = false,
        };
    }
    return placed_params;
}

/// Finish the body func: snapshot the captures, register the func under a new
/// id and hand back the id plus that capture list.
fn finishBodyFunc(
    ctx: *LambdaBodyCtx,
    names: []const []const u8,
    unit_body: bool,
) Allocator.Error!LoweredLambda {
    const module = ctx.module;
    const b = ctx.b;
    const body = ctx.body;
    const is_lambda = ctx.is_lambda;
    const captured = try b.allocator.dupe([]const u8, b.capturesTaken());
    var func = try b.finish("<lambda>", "<lambda>", if (unit_body) build.typeUnit() else (literalReturnTy(body) orelse build.typeUnit()));
    // Function count is bounded well below u32::MAX; the index is the new FuncId.
    const id = module.nextFuncId();
    func.id = id;
    func.is_lambda = is_lambda;
    if (module.pending_ref_key) |key| {
        func.ref_key = key;
        module.pending_ref_key = null;
    }
    // The receiver head may alias a span-keyed `lambda_arg_recv` entry the builder
    // frees at teardown, and the Func outlives the builder, so it must own its copy.
    func.lambda_receiver_ty = if (b.recvTy()) |head| try b.allocator.dupe(u8, head) else null;
    const placed_params = try placeDeclaredParams(ctx, names);
    func.params = placed_params;
    // A local extension function lowers as a lambda body with a synthesized leading
    // `this` receiver param, ordinary receiver lambdas carrying theirs as a capture.
    // Mark it so bare member resolution treats it as a dispatch receiver.
    func.has_receiver_param = placed_params.len != 0 and
        std.mem.eql(u8, placed_params[0].name, "this");
    try module.appendFunc(func);
    // A lambda body carries its declaring file: the import-scoped member-extension
    // probe reads the frame fn's decl_span file, and an imported companion extension
    // is in scope in the file that wrote the lambda.
    try module.decl_span.put(id.int(), body.span);
    return .{ .func = id, .captures = captured };
}

/// Static return type of a lambda whose body is a single numeric literal, read by
/// numeric-kind-preserving folds to seed an empty-receiver accumulator; anything
/// non-literal stays the Unit placeholder.
fn literalReturnTy(body: *const ast.Block) ?ir.TypeRef {
    if (body.stmts.len == 0) return null;
    const last = &body.stmts[body.stmts.len - 1];
    const e = switch (last.*) {
        .Expr => |*ex| ex,
        else => return null,
    };
    const name: []const u8 = switch (e.*) {
        .IntLit => |l| switch (l.kind) {
            .Int => "kotlin.Int",
            .Long => "kotlin.Long",
            .UInt => "kotlin.UInt",
            .ULong => "kotlin.ULong",
        },
        .FloatLit => |l| switch (l.kind) {
            .Double => "kotlin.Double",
            .Float => "kotlin.Float",
        },
        else => return null,
    };
    return .{ .name = name, .nullable = false, .args = &.{} };
}

test "literalReturnTy classifies single-literal lambda bodies" {
    const s = ast.Span.init(@enumFromInt(0), 0, 1);
    var stmts = [_]ast.Stmt{.{ .Expr = .{ .IntLit = .{ .value = 1, .kind = .ULong, .span = s } } }};
    const blk: ast.Block = .{ .stmts = &stmts, .span = s };
    const ty = literalReturnTy(&blk) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("kotlin.ULong", ty.name);
    const empty: ast.Block = .{ .stmts = &.{}, .span = s };
    try std.testing.expect(literalReturnTy(&empty) == null);
}

test {
    std.testing.refAllDecls(@This());
}


test "an inferred receiver-function parameter type marks a receiver-lambda param" {
    const testing = std.testing;
    // `Scope.() -> Unit` lowers to `Function0` with the receiver as one extra
    // leading arg before the return type.
    const unit = TypeRef{ .name = "Unit", .nullable = false, .args = &.{} };
    const scope = TypeRef{ .name = "Scope", .nullable = false, .args = &.{} };
    var recv_args = [_]TypeRef{ scope, unit };
    const recv_fn = TypeRef{ .name = "Function0", .nullable = false, .args = &recv_args };
    const shape = loweredRecvFnShape(&recv_fn) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), shape.arity);
    try testing.expectEqualStrings("Scope", shape.recv_head);

    // A plain `() -> Unit` has no receiver.
    var plain_args = [_]TypeRef{unit};
    const plain_fn = TypeRef{ .name = "Function0", .nullable = false, .args = &plain_args };
    try testing.expect(loweredRecvFnShape(&plain_fn) == null);

    // `suspend Scope.(Int) -> Unit`: the marker and the value parameter both sit
    // between the head and the return type.
    const int = TypeRef{ .name = "Int", .nullable = false, .args = &.{} };
    const suspend_marker = TypeRef{ .name = "#suspend", .nullable = false, .args = &.{} };
    var s_args = [_]TypeRef{ suspend_marker, scope, int, unit };
    const s_fn = TypeRef{ .name = "Function1", .nullable = false, .args = &s_args };
    const s_shape = loweredRecvFnShape(&s_fn) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), s_shape.arity);
    try testing.expectEqualStrings("Scope", s_shape.recv_head);

    // `suspend (Int) -> Unit` without a receiver stays unmarked.
    var sp_args = [_]TypeRef{ suspend_marker, int, unit };
    const sp_fn = TypeRef{ .name = "Function1", .nullable = false, .args = &sp_args };
    try testing.expect(loweredRecvFnShape(&sp_fn) == null);

    // A non-function head is never a receiver-function type.
    const not_fn = TypeRef{ .name = "Scope", .nullable = false, .args = &recv_args };
    try testing.expect(loweredRecvFnShape(&not_fn) == null);
}
