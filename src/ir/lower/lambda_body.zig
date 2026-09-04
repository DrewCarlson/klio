//! Lambda-body lowering: a lambda literal's body is lowered into a
//! standalone `Func` that closes over the enclosing scope's registers.
//! Free functions over the shared `FuncBuilder`; filled in alongside the
//! expression dispatch.

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

/// The lexically enclosing class context handed to a lambda body so an
/// enclosing-class member out-prioritises a same-named imported
/// extension.
pub const EnclosingOwner = struct {
    class: []const u8,
    members: StringSet,
};

/// The declared receiver and value-parameter count of a LOWERED function
/// type, or null when `ty` is not a receiver-typed function. The lowered
/// encoding is `[#suspend?] [receiver?] params… ret [#markers]`, so a
/// receiver shows up as one extra leading entry over `FunctionN`'s N.
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

/// The allocator backing a `Module`'s growable tables. The module's
/// containers are unmanaged, so recover the allocator from a managed
/// member (`func_name_index`) it was initialised with.
fn moduleAllocator(module: *Module) Allocator {
    return module.func_name_index.allocator;
}

/// The product of lowering a lambda body: the body `Func`'s id plus the
/// capture-name list (in `LoadCapture` index order) the construction site
/// must snapshot.
pub const LoweredLambda = struct {
    func: FuncId,
    captures: [][]const u8,
};

/// Resolve a name to a register inside a lambda body, recording a capture
/// (and emitting `LoadCapture`) when the name lives in the enclosing
/// frame rather than locally.
pub fn resolveCapture(b: *FuncBuilder, name: []const u8) Allocator.Error!Reg {
    if (b.resolve(name)) |r| {
        return r;
    }
    // A lambda body's implicit `this` (the receiver of an `apply` /
    // `with` / extension-receiver lambda) is bound at invoke time
    // through the closure's capture slot rather than a scope binding
    // or an `outer_names` entry — so `knowsOuter("this")` is false
    // even though `this` is reachable. The `Expr.This` lowering uses
    // the same `isLambdaBody()` signal. Mirror it here so a *nested*
    // lambda can capture the enclosing receiver: forward `this`
    // through this builder's own capture slot rather than collapsing
    // it to `Unit`.
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
    // A name the enclosing ANON OBJECT closes over (a lambda inside an
    // anon-object method capturing the enclosing function's local, e.g.
    // `filter { it != element }` in the stdlib's Sequence.minus object):
    // forward it through this builder's capture slot — the anon method's
    // captures are supplied by name from the instance at dispatch. The
    // silent-Unit tail below would bind the lambda's capture to nothing.
    if (decl.isLowerAnonCapture(name)) {
        return try b.loadCaptureHoisted(name);
    }
    // A zero-parameter / receiver lambda whose `it` was deliberately not
    // bound, and no enclosing lambda supplies one: kotlinc rejects this as
    // an unresolved reference. Record the diagnostic so the build driver
    // fails the program before it runs, rather than reading a silent null.
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

/// Lower a lambda body, threading the enclosing builder's
/// visible-name set so Path references that hit it lower to
/// `LoadCapture`. Returns the body's `FuncId` plus the ordered
/// list of captured names — the caller resolves each to an outer
/// reg and ships it through `Inst.Lambda::captures`.
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

// Innermost rung of the lambda-body lowering wrapper chain; each flag/ref
// is threaded straight from the AST and bundling them would only obscure it.
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

/// As `lowerLambdaBodyCapturingKindWith`, but with the explicit-`it`
/// suppression decision: when `suppress_it` is set the body declares no
/// implicit `it`, so an `it` reference inside resolves to an enclosing
/// lambda's `it` (or, resolving nowhere, is rejected as unresolved).
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
    // The receiver type in scope at this body's construction site (the
    // enclosing `this`, or this receiver lambda's own receiver), stashed by
    // `lowerLambda`. Carried so a bare call in this body can disambiguate a
    // receiver-lambda argument's arity even though `recv_ty` (the decl's own
    // extension receiver) is null inside a lambda.
    if (module.pending_lambda_enclosing_recv) |rt| {
        module.pending_lambda_enclosing_recv = null;
        b.setEnclosingRecvTy(rt);
    }
    if (module.pending_lambda_receiver_tower) |tower| {
        module.pending_lambda_receiver_tower = null;
        defer moduleAllocator(module).free(tower);
        try b.setImplicitReceiverTower(tower);
    }
    // A local extension FUNCTION's body owns its declared receiver outright
    // (stashed by `lowerLocalFnDecl`): the same standing a top-level
    // extension body gets from `setRecvTy`, so bare-call resolution prefers
    // extensions on the receiver over same-named plain top-level functions.
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
    // The enclosing local `fun`'s identity (its own body, or a lambda nested
    // inside it), so a bare self-reference binds through the mangled cell.
    if (module.pending_lambda_self_fn) |slf| {
        module.pending_lambda_self_fn = null;
        b.setSelfLocalFn(slf);
    }
    // Enclosing-scope locals with definite NON-callable evidence: a bare
    // CALL of one of these names in this body never routes through the
    // captured value.
    if (module.pending_lambda_nonfn_locals) |*nf| {
        try b.inheritNonFnLocals(nf);
        var nf_own = nf.*;
        nf_own.deinit();
        module.pending_lambda_nonfn_locals = null;
    }
    // `KLIO_LAMINH=1` — the declared-type inheritance channel, producer and
    // consumer. A lambda body that inherits an EMPTY snapshot while its
    // enclosing function's builder holds records means the body was lowered
    // from a builder that is not the one holding the enclosing locals, which
    // costs every member call in that body its receiver type.
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
    // A local `fun`'s BLOCK body returns Unit on fall-through, never the
    // tail statement's value (stashed by `lowerLocalFnDecl`; a lambda
    // literal keeps last-expression semantics). Consumed here, before any
    // nested lambda inside this body lowers, so it never leaks inward.
    const fn_block_body = module.pending_lambda_fn_block_body;
    module.pending_lambda_fn_block_body = false;
    // A lambda literal bound to a `-> Unit` parameter returns Unit; its
    // tail expression runs for effect only. Consumed before any nested
    // lambda lowers, like the block-body flag.
    const unit_body = module.pending_lambda_unit;
    module.pending_lambda_unit = false;
    // Enclosing non-reified type params, so an `x as T` cast in this body is
    // erased (see FuncBuilder.type_param_names).
    if (module.pending_lambda_type_params) |tps| {
        module.pending_lambda_type_params = null;
        defer moduleAllocator(module).free(tps);
        for (tps) |tp| try b.addTypeParamName(tp);
    }
    // The enclosing splice's reified substitutions: `filter { it is R }`
    // inside a spliced `filterIsInstance<reified R>` resolves `R` here.
    if (module.pending_lambda_reified_names) |names| {
        module.pending_lambda_reified_names = null;
        defer moduleAllocator(module).free(names);
        for (names) |rn| _ = try b.bindReifiedTypeName(rn.name, rn.actual);
    }
    if (module.pending_lambda_type_param_bounds) |bounds| {
        module.pending_lambda_type_param_bounds = null;
        defer moduleAllocator(module).free(bounds);
        for (bounds) |bound| {
            // Keep the bound's concrete ARGS (registry-lifetime slices):
            // dropping them here degraded `T : Iterable<String>` to a
            // head-only record one lambda level down, and the receiver
            // bound hop then offered bare `T` to extension resolution.
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
    // Carry the lexically enclosing class (and its member-name set) so a
    // member reference inside the lambda resolves against the class that
    // declares it: a private getter (`closed`) reads the right field, and
    // a bare member call (`execute`) binds the enclosing member ahead of a
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
    // A captured `block: T.() -> R` from an enclosing scope must still
    // dispatch a bare `block()` here as `this.block()` — carry the
    // enclosing receiver-lambda-param names so `isReceiverLambdaParam`
    // sees them across the capture boundary.
    var inherited = inherited_rlp;
    defer inherited.deinit();
    try b.inheritReceiverLambdaParams(&inherited);
    // The declared receiver HEADS ride the module's pending slot (the
    // name set above carries no types): a captured `transform:
    // FlowCollector.(A) -> R` invoked bare in this body re-selects its
    // receiver by the declared head.
    if (module.pending_lambda_recv_heads) |heads| {
        module.pending_lambda_recv_heads = null;
        defer moduleAllocator(module).free(heads);
        for (heads) |kv| {
            try b.setReceiverLambdaRecvHead(kv.name, kv.head);
        }
    }
    // Same carrier for local extension functions: a captured local ext fn
    // called bare in this body must still prepend the enclosing receiver.
    var inherited_ext = inherited_lef;
    defer inherited_ext.deinit();
    try b.inheritLocalExtFns(&inherited_ext);
    // A captured parameter with an unbounded type-parameter type remains
    // statically erased inside nested lambdas. Preserve that fact so an
    // explicit receiver call continues to select its callable fallback
    // instead of consulting members on the runtime value.
    var inherited_erased = inherited_erp;
    defer inherited_erased.deinit();
    try b.inheritErasedRecvParams(&inherited_erased);
    // And for local-fn overload sets: a call in this body to a captured
    // local fn declared more than once must still select the applicable
    // sibling by its mangled binding.
    if (inherited_lfo) |table| {
        try b.inheritLocalFnOverloads(table);
    }
    if (tailrec_self) |name| {
        b.setTailrecSelf(name);
    }
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
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(b.allocator);
    for (params) |p| try names.append(b.allocator, p.name);
    if (params.len == 0 and !suppress_it) {
        try names.append(b.allocator, "it");
    }
    // A lambda parameter that a deeper nested lambda *writes* is itself a
    // captured-and-mutated local: box it so the write lands on a shared cell
    // (the same carrier as a body `var`), not the StoreGlobal capture
    // fallback. Symmetric to the function-body and inline-splice param boxing.
    {
        var assigned = ast_scan.StringSet.init(b.allocator);
        defer assigned.deinit();
        try ast_scan.namesAssignedInLambdasRebindsOnly(body.stmts, &assigned);
        for (names.items) |pname| {
            if (assigned.contains(pname)) try boxed.put(pname, {});
        }
    }
    b.setBoxedVars(boxed);
    try decl.bindParams(&b, names.items);
    // Parameter names shadow inherited enclosing-local records: without
    // this, `let { it.sortedBy { it.nonEmptyLength() } }` typed the inner
    // lambda's `it` from the OUTER `it`'s List record and refuted the
    // local String extension.
    for (names.items) |nm| b.clearLocalDeclType(nm);
    if (module.pending_lambda_param_types) |expected_types| {
        module.pending_lambda_param_types = null;
        defer moduleAllocator(module).free(expected_types);
        // The producer clamps the type list to `min(ref types, value params)`,
        // so it may carry FEWER entries than this lambda's param names (an
        // implicit-`it` / suppressed-`it` divergence, or a partially-typed SAM):
        // bind the leading names that have a type and free any surplus type.
        const bind_n = @min(expected_types.len, names.items.len);
        for (expected_types[0..bind_n], names.items[0..bind_n], 0..) |expected, name, i| {
            var owned = expected;
            if (i < param_tys.len and param_tys[i] != null) {
                owned.deinit(b.allocator);
                continue;
            }
            // A lambda parameter whose EXPECTED type is a receiver-typed
            // function (`{ fail -> fail() }` bound to
            // `child: Scope.(block: Scope.() -> Unit) -> Unit`) is a
            // receiver-lambda param exactly as an annotated one is: a bare
            // `fail()` in the body invokes it with the enclosing `this`.
            // Only the ANNOTATED types reach the classification loop below,
            // so an inferred parameter had to be marked here or the block
            // ran receiverless.
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
    const vararg_names = module.pending_lambda_vararg_params;
    module.pending_lambda_vararg_params = null;
    for (params, 0..) |p, i| {
        if (i >= param_tys.len) break;
        const ty = param_tys[i] orelse continue;
        if (ty.function) |ft| {
            try b.setLocalCallReturn(p.name, ft.ret.name.name, ft.ret.nullable);
        }
        // A local `fun`'s vararg parameter is the MATERIALIZED array inside
        // the body; its annotation names the element. Register the array
        // head, exactly as the top-level declaration lowering does.
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
        // A source-annotated (or pass-stamped) lambda parameter type is
        // authoritative for member resolution in the body, exactly like a
        // declared function parameter's.
        try b.setLocalDeclTypeOwned(p.name, try decl.loweredTypeRef(b.allocator, &ty, true));
        if (ty.nullable) try b.setLocalDeclNullable(p.name);
    }
    // A local contextual function's context parameters, stashed by its
    // declaration lowering, bind here before the body statements lower.
    if (module.pending_ctx) |pc| {
        module.pending_ctx = null;
        try decl.emitContextParamLoads(&b, pc.params, pc.type_params);
    }
    // An argument lambda's implicit label names ITS receiver
    // (`runTest { … }` → `this@runTest`). Bind the label to the receiver the
    // invoke fills in, so a reference from a nested scope — an anonymous
    // object's accessor, a further lambda — captures this one rather than
    // resolving to the innermost `this` (the anon instance).
    const this_label = module.pending_lambda_this_label;
    module.pending_lambda_this_label = null;
    if (is_lambda and this_label != null) {
        const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{this_label.?});
        if (b.resolve(label) == null) {
            // A body whose receiver is its own binding gets the label
            // unconditionally — the bind is free, and it makes the receiver
            // reachable by name from nested scopes (the tower emission path
            // resolves an outer receiver through exactly this slot). A body
            // whose `this` would need a CAPTURE only binds when the source
            // references the label, so capture lists stay unchanged.
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
    // A lambda parameter (including the implicit `it`) statically typed as a
    // broad collection (`Iterable`/`Collection`) yields a `List` from `+`/`-`
    // even over a runtime `Set`; record it so the operator lowering coerces it.
    for (broad_coll_params) |pname| {
        try b.markBroadCollectionLocal(pname);
    }
    // A lambda parameter whose expected type (from the callee parameter's
    // function type) is one of the callee's own type parameters carries
    // Kotlin's generic static typing: comparisons on it follow the
    // `compareTo` total order, and a container built from such values is
    // statically generic-elemental.
    for (generic_typed_params) |pname| {
        try b.markGenericTypedParam(pname);
    }
    // A local fn's params get the same classification a top-level fn's do
    // in decl.zig: a param declared with an extension-function type
    // (`toList: T.() -> List<*>`) is a receiver-lambda param, so a bare
    // call `toList(array)` in the body binds `array` as the RECEIVER
    // instead of invoking the value receiverless.
    for (params, 0..) |pname, pi| {
        if (pi >= param_tys.len) break;
        const t = param_tys[pi] orelse {
            // E2.4: an unannotated param's declared shape from typeck.
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
            // Aliased receiver-fn type: the alias registry keeps the
            // receiver-ness the `Function{N}` tag drops.
            try b.markReceiverLambdaParam(pname.name);
            try b.markReceiverLambdaArity(pname.name, ar);
        }
    }
    const result = try expr.lowerBlock(&b, body);
    if (fn_block_body or unit_body) {
        // `fun f() { 42 }` returns Unit, not 42 — an explicit `return`
        // terminated before reaching this fall-through.
        const unit_dst = b.allocReg();
        const unit = try b.module.internConst(b.allocator, .Unit);
        try b.push(.{ .Const = .{ .dst = unit_dst, .value = unit } });
        b.terminate(.{ .Return = unit_dst });
    } else {
        b.terminate(.{ .Return = result });
    }
    const captured = try b.allocator.dupe([]const u8, b.capturesTaken());
    var func = try b.finish("<lambda>", "<lambda>", if (unit_body) build.typeUnit() else (literalReturnTy(body) orelse build.typeUnit()));
    // Function count is bounded well below u32::MAX; the index is the new FuncId.
    const id = module.nextFuncId();
    func.id = id;
    func.is_lambda = is_lambda;
    // The receiver head may alias a span-keyed `lambda_arg_recv` entry the
    // builder frees at teardown; the Func outlives the builder, so it must
    // own its copy (reading the alias at run time observed whatever string
    // later reused the freed bytes, silently breaking receiver binding for
    // every receiver lambda recorded through a call-bound shape).
    func.lambda_receiver_ty = if (b.recvTy()) |head| try b.allocator.dupe(u8, head) else null;
    // Declared parameter annotations (`{ s: String -> … }`, an anonymous
    // function's typed params) land on the body func so runtime overload
    // dispatch can match the value against a declared function-type
    // parameter. Unannotated slots (and the injected implicit `it`) keep
    // the Unit placeholder, which dispatch treats as no-information.
    const placed_params = try b.allocator.alloc(Param, names.items.len);
    for (names.items, placed_params, 0..) |n, *dst, i| {
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
    func.params = placed_params;
    // A local extension function is lowered as a lambda body with a
    // synthesized leading `this` receiver param (ordinary receiver lambdas
    // carry their receiver as a capture, not a param). Mark it so bare
    // member resolution treats the receiver as a genuine dispatch
    // receiver.
    func.has_receiver_param = placed_params.len != 0 and
        std.mem.eql(u8, placed_params[0].name, "this");
    try module.funcs.append(b.allocator, func);
    // A lambda body carries its declaring file: the import-scoped
    // member-extension probe reads the frame fn's decl_span file, and an
    // imported companion extension (`300.milliseconds` inside a
    // `withVirtualTime { ... }` block) is in scope in the file that wrote
    // the lambda, not in the file of the function that invokes it.
    try module.decl_span.put(id.int(), body.span);
    return .{ .func = id, .captures = captured };
}

/// Static return type of a lambda whose body is a single numeric literal
/// (`{ 1 }`, `{ 1L }`, `{ 1U }`, `{ 1.0 }`). Numeric-kind-preserving folds
/// (`sumOf`) read it through the host to seed an empty-receiver
/// accumulator with the right kind; anything non-literal stays the Unit
/// placeholder, which dispatch treats as no-information.
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
    // `Scope.() -> Unit` lowers to `Function0` with the receiver as one
    // extra leading arg before the return type.
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

    // `suspend Scope.(Int) -> Unit`: the marker and the value parameter
    // both sit between the head and the return type.
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
