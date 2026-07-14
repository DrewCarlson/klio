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
        const idx = try b.recordCapture("this");
        const dst = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
        try b.bind("this", dst);
        return dst;
    }
    if (b.knowsOuter(name)) {
        const idx = try b.recordCapture(name);
        const dst = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
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
        const idx = try b.recordCapture(name);
        const dst = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
        return dst;
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
    inherited_lef: StringSet,
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
    inherited_lef: StringSet,
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
    inherited_lef: StringSet,
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
    inherited_lef: StringSet,
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
    // Same carrier for local extension functions: a captured local ext fn
    // called bare in this body must still prepend the enclosing receiver.
    var inherited_ext = inherited_lef;
    defer inherited_ext.deinit();
    try b.inheritLocalExtFns(&inherited_ext);
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
        try ast_scan.namesAssignedInLambdas(body.stmts, &assigned);
        for (names.items) |pname| {
            if (assigned.contains(pname)) try boxed.put(pname, {});
        }
    }
    b.setBoxedVars(boxed);
    try decl.bindParams(&b, names.items);
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
    if (is_lambda and this_label != null and
        ast_scan.referencesQualifiedThis(body.stmts, this_label.?))
    {
        const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{this_label.?});
        if (b.resolve(label) == null) {
            const this_reg: ?Reg = if (b.resolve("this")) |r| r else blk: {
                const idx = try b.recordCapture("this");
                const dst = b.allocReg();
                try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
                break :blk dst;
            };
            if (this_reg) |tr| try b.bind(label, tr);
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
            }
        }
    }
    const result = try expr.lowerBlock(&b, body);
    b.terminate(.{ .Return = result });
    const captured = try b.allocator.dupe([]const u8, b.capturesTaken());
    var func = try b.finish("<lambda>", "<lambda>", literalReturnTy(body) orelse build.typeUnit());
    // Function count is bounded well below u32::MAX; the index is the new FuncId.
    const id = module.nextFuncId();
    func.id = id;
    func.is_lambda = is_lambda;
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
