//! Lowering helpers that wrap an expression or block as a synthetic
//! 0/1/2-arg IR function. Used by the build pass to materialise
//! default-arg producers, accessors, init blocks, and similar
//! "expression-bodied" pieces of code without the surrounding fn /
//! method machinery.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");

const decl = @import("decl.zig");
const expr_mod = @import("expr.zig");
const ast_scan = @import("ast_scan.zig");
const literals = @import("literals.zig");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const Param = ir.Param;
const Const = ir.Const;
const Terminator = ir.Terminator;
const Expr = ast.Expr;
const TypeRef = ast.TypeRef;
const StringSet = std.StringHashMap(void);

const FuncBuilder = build.FuncBuilder;
const bindParams = decl.bindParams;
const lowerExpr = expr_mod.lowerExpr;
const stmt_mod = @import("stmt.zig");
const lowerBlock = expr_mod.lowerBlock;

/// The allocator backing a `Module`'s growable tables. The module's
/// containers are unmanaged, so recover the allocator from a managed
/// member (`func_name_index`) it was initialised with.
fn moduleAllocator(module: *Module) Allocator {
    return module.func_name_index.allocator;
}

/// `pushFunc` + a decl_span stamp: a synthesized fn carries the file its
/// body was written in, which the import-scoped member-extension probe
/// (and any other frame-file attribution) reads at run time.
fn pushFuncSpanned(module: *Module, func_in: Func, body_span: ast.Span) Allocator.Error!FuncId {
    const id = try pushFunc(module, func_in);
    try module.decl_span.put(id.int(), body_span);
    return id;
}

/// Assign the next `FuncId` to `func` and append it to the module.
fn pushFunc(module: *Module, func_in: Func) Allocator.Error!FuncId {
    // FuncId indexes module.funcs; the IR caps the func count at u32.
    const id = module.nextFuncId();
    var func = func_in;
    func.id = id;
    try module.funcs.append(moduleAllocator(module), func);
    // An extension-property getter is looked up BY NAME under the
    // `__ext_get_<Head>_<name>` contract (`extPropGetterReturn` types a
    // bare `indices` read from the getter's declared return); without the
    // index entry no accessor was ever findable and the channel answered
    // nothing. Mangled names never collide with user identifiers, so the
    // simple-name heuristics are untouched.
    if (std.mem.startsWith(u8, func.name, "__ext_get_")) {
        const a = moduleAllocator(module);
        try module.func_index.append(a, .{ .name = func.name, .id = id });
        const gop = try module.func_name_index.getOrPut(func.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, id);
    }
    return id;
}

/// Clone a borrowed own-member set into a fresh owned `StringSet` (sharing
/// the borrowed key slices) for `setOwnMembers`, which takes ownership.
fn cloneOwnMembers(allocator: Allocator, src: *const StringSet) Allocator.Error!StringSet {
    var out = StringSet.init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

/// Lower an arbitrary expression as a 0-arg synthetic function whose
/// body returns the expression's value. The synthetic function is
/// pushed onto the module so a downstream caller can invoke it via
/// `eval_with` against `module.funcs[id]`.
/// Emit a contextual property accessor's context-load prologue when the
/// declaration lowering stashed its context parameters. A no-op otherwise.
/// Record the declared type of each bound parameter when the declaration
/// lowering stashed them. A no-op otherwise, so a thunk whose caller knows
/// no types behaves exactly as before.
fn consumePendingParamTypes(b: *FuncBuilder, params: []const []const u8) Allocator.Error!void {
    const types = b.module.pending_param_types orelse return;
    b.module.pending_param_types = null;
    for (params, 0..) |name, i| {
        if (i >= types.len) break;
        const ty = &(types[i] orelse continue);
        if (ty.function != null or ty.name.name.len == 0) continue;
        var lowered = try decl.loweredTypeRef(b.allocator, ty, true);
        var head = std.mem.trimEnd(u8, lowered.name, "?");
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        if (head.len != 0 and head.len <= 2 and std.ascii.isUpper(head[0])) {
            lowered.deinit(b.allocator);
            continue;
        }
        try b.setLocalDeclTypeOwned(name, lowered);
    }
}

/// Install the owner class's member arity mask when the declaration lowering
/// stashed one. A no-op otherwise, so a thunk whose caller records no arities
/// keeps the permissive default (`ownMemberApplicable` says yes for an
/// unrecorded name).
fn consumePendingOwnMemberArity(b: *FuncBuilder) Allocator.Error!void {
    const src = b.module.pending_own_member_arity orelse return;
    b.module.pending_own_member_arity = null;
    var copy = std.StringHashMap(u64).init(b.allocator);
    var it = src.iterator();
    while (it.next()) |e| try copy.put(e.key_ptr.*, e.value_ptr.*);
    b.setOwnMemberArity(copy);
}

fn consumePendingCtx(b: *FuncBuilder) Allocator.Error!void {
    if (b.module.pending_ctx) |pc| {
        b.module.pending_ctx = null;
        try decl.emitContextParamLoads(b, pc.params, pc.type_params);
    }
}

pub fn lowerExprAsThunk(module: *Module, expr: *const Expr, name: []const u8) Allocator.Error!FuncId {
    return lowerExprAsThunkTyped(module, expr, name, null);
}

/// A top-level delegated property's delegate thunk: the expression, then
/// the `provideDelegate` convention with a null receiver.
pub fn lowerDelegateExprAsThunk(module: *Module, expr: *const Expr, name: []const u8, prop_name: []const u8) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    try consumePendingCtx(&b);
    const v = try lowerExpr(&b, expr);
    const provided = try stmt_mod.emitProvideDelegate(&b, v, prop_name);
    b.terminate(.{ .Return = provided });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFuncSpanned(module, func, expr.span());
}

/// As [`lowerExprAsThunk`], seeding the declared type as the body's
/// tail-position expected type: `var g: Long = 0` widens its literal
/// exactly as a local `val x: Long = 0` does.
pub fn lowerExprAsThunkTyped(module: *Module, expr: *const Expr, name: []const u8, expected: ?TypeRef) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    try consumePendingCtx(&b);
    const prev = b.pushExpected(expected);
    const widened: ?Expr = if (expected) |*ty| literals.widenNumericLiteral(expr, ty) else null;
    const v = try lowerExpr(&b, if (widened) |*w| w else expr);
    b.restoreExpected(prev);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFuncSpanned(module, func, expr.span());
}

/// Lower a block as a 0-arg synthetic function. The block's trailing
/// expression becomes the implicit return value.
pub fn lowerBlockAsThunk(module: *Module, block: *const ast.Block, name: []const u8) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    try consumePendingCtx(&b);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFuncSpanned(module, func, block.span);
}

/// 1-arg block thunk for setter bodies.
pub fn lowerBlockAsUnaryThunk(
    module: *Module,
    param_name: []const u8,
    block: *const ast.Block,
    name: []const u8,
) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    try bindParams(&b, &.{param_name});
    try consumePendingCtx(&b);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFuncSpanned(module, func, block.span);
}

/// Lower an expression as a 2-arg synthetic function bound under
/// the supplied parameter names. Used for instance accessors whose
/// first arg is `this` and second is the new value.
pub fn lowerBinaryExprAsThunk(
    module: *Module,
    param_a: []const u8,
    param_b: []const u8,
    expr: *const Expr,
    name: []const u8,
) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    try bindParams(&b, &.{ param_a, param_b });
    const v = try lowerExpr(&b, expr);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFuncSpanned(module, func, expr.span());
}

pub fn lowerExprAsParamThunk(
    module: *Module,
    params: []const []const u8,
    expr: *const Expr,
    name: []const u8,
) Allocator.Error!FuncId {
    return lowerExprAsParamThunkScopedEnclosing(module, params, expr, name, null, null, null);
}

/// Like [`lowerExprAsParamThunk`] but additionally puts the
/// enclosing class's name and own-member set in scope.
pub fn lowerExprAsParamThunkScoped(
    module: *Module,
    params: []const []const u8,
    expr: *const Expr,
    name: []const u8,
    owner_class: ?[]const u8,
    own_members: ?*const StringSet,
) Allocator.Error!FuncId {
    return lowerExprAsParamThunkScopedEnclosing(module, params, expr, name, owner_class, own_members, null);
}

/// Full form: additionally threads the lexically-enclosing class chain's
/// member names, so a bare name in a nested class's ctor default that
/// names an OUTER member resolves through the receiver walk (an inner
/// class's defaults see the enclosing instance) instead of binding a
/// same-named top-level declaration.
pub fn lowerExprAsParamThunkScopedEnclosing(
    module: *Module,
    params: []const []const u8,
    expr: *const Expr,
    name: []const u8,
    owner_class: ?[]const u8,
    own_members: ?*const StringSet,
    enclosing_members: ?*const StringSet,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    try bindParams(&b, params);
    try consumePendingParamTypes(&b, params);
    try consumePendingCtx(&b);
    b.setParamThunk(true);
    if (owner_class) |owner| {
        b.setOwnerClass(owner);
    }
    if (own_members) |set| {
        b.setOwnMembers(try cloneOwnMembers(allocator, set));
    }
    try consumePendingOwnMemberArity(&b);
    if (enclosing_members) |em| b.setEnclosingMembers(try cloneOwnMembers(allocator, em));
    // The declared parameter type the thunk's expression must satisfy
    // (`serializer()` as a parent constructor argument binds its reified
    // parameter from it).
    const expected = module.pending_thunk_expected;
    module.pending_thunk_expected = null;
    const prev_expected = b.pushExpected(expected);
    const v = try lowerExpr(&b, expr);
    _ = b.pushExpected(prev_expected);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    // Record the bound params for a `this`-leading thunk (an INNER class's
    // ctor-default): the eval `this`-parameter fallback reads them to
    // recover the receiver, so a bare outer-member read resolves through
    // the receiver walk. Other param thunks keep the empty metadata their
    // callers expect.
    if (leadsWithThis(params)) {
        func.params = try accessorParams(allocator, params);
    }
    func.has_receiver_param = leadsWithThis(params);
    return pushFuncSpanned(module, func, expr.span());
}

/// Whether a synthesized param list leads with the implicit `this`
/// receiver. Thunk/accessor/init param lists are compiler-built, so a
/// leading `this` is always the synthesized receiver (never a user
/// backtick parameter).
fn leadsWithThis(params: []const []const u8) bool {
    return params.len != 0 and std.mem.eql(u8, params[0], "this");
}

/// Lower an init-style block with arbitrary bound parameter names.
/// Records the bound params (incl. `this`) like the accessor-expression
/// form, so the eval `this`-parameter fallback recovers the receiver — a
/// bare companion-method call inside an init block resolves against the
/// constructed instance's chain.
pub fn lowerInitBlockWithParams(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    block: *const ast.Block,
    name: []const u8,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    // Box body `var`s (and params) a nested lambda mutates into shared cells,
    // exactly as a normal function body does — otherwise a `var` an init block
    // mutates from inside a lambda captures a copy and the write is lost.
    try setInitBlockBoxedVars(&b, allocator, params, block);
    try bindParams(&b, params);
    // An init block reads the constructor's parameters, and its builder knew
    // their NAMES alone — the same gap the delegation and default thunks had.
    // `array.copyOf()` inside `AtomicIntArray`'s init had no receiver type.
    try consumePendingParamTypes(&b, params);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.params = try accessorParams(allocator, params);
    func.has_receiver_param = leadsWithThis(params);
    return pushFuncSpanned(module, func, block.span);
}

/// Lower a function shell that takes the named params and returns Unit.
pub fn lowerEmptyThunk(module: *Module, params: []const []const u8, name: []const u8) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    try bindParams(&b, params);
    const unit = try b.emitConst(Const.Unit);
    b.terminate(.{ .Return = unit });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFunc(module, func);
}

/// Lower a class init block as a 1-arg IR function whose only
/// parameter binds `this`.
pub fn lowerInitBlock(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    block: *const ast.Block,
    name: []const u8,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    try setInitBlockBoxedVars(&b, allocator, &.{"this"}, block);
    try bindParams(&b, &.{"this"});
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.has_receiver_param = true;
    return pushFuncSpanned(module, func, block.span);
}

/// Compute the set of `var`s (body decls plus params) that a nested lambda in
/// the init block mutates, and mark them for boxing so the lambda closes over
/// a shared cell. Mirrors the body-`var` boxing in `lowerFunctionBody`.
fn setInitBlockBoxedVars(
    b: *FuncBuilder,
    allocator: Allocator,
    params: []const []const u8,
    block: *const ast.Block,
) Allocator.Error!void {
    var boxed = try ast_scan.computeBoxedVars(allocator, block.stmts);
    var assigned = StringSet.init(allocator);
    defer assigned.deinit();
    try ast_scan.namesAssignedInLambdasRebindsOnly(block.stmts, &assigned);
    for (params) |pname| {
        if (assigned.contains(pname)) try boxed.put(pname, {});
    }
    b.setBoxedVars(boxed);
}

/// Lower an instance accessor body.
pub fn lowerAccessorExpr(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    expr: *const Expr,
    name: []const u8,
) Allocator.Error!FuncId {
    return lowerAccessorExprFull(module, owner_class, own_members, null, params, null, expr, name, null);
}

/// Like [`lowerAccessorExpr`] but seeds the lexically-enclosing class's
/// member set, so a body-property initializer / accessor in a *nested*
/// class resolves a bare name the enclosing class (or its companion)
/// declares — e.g. `HexFormat.Builder.upperCase = Default.upperCase`, where
/// `Default` is the enclosing companion's member — against the enclosing
/// scope instead of an unrelated global class of the same simple name.
pub fn lowerAccessorExprEnclosing(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    enclosing_members: ?*const StringSet,
    params: []const []const u8,
    expr: *const Expr,
    name: []const u8,
    expected: ?TypeRef,
) Allocator.Error!FuncId {
    return lowerAccessorExprFull(module, owner_class, own_members, enclosing_members, params, null, expr, name, expected);
}

/// Lower a body-property initializer while preserving the declared types of
/// the primary-constructor parameters captured by its synthetic function.
/// Those static types participate in overload resolution inside the
/// initializer just as they do in an ordinary function body.
pub fn lowerPropertyInitExpr(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    enclosing_members: ?*const StringSet,
    params: []const []const u8,
    declared_params: []const Param,
    expr: *const Expr,
    name: []const u8,
    expected: ?TypeRef,
) Allocator.Error!FuncId {
    return lowerAccessorExprFull(module, owner_class, own_members, enclosing_members, params, declared_params, expr, name, expected);
}

/// Like [`lowerAccessorExpr`] but seeds the tail-position expected
/// type so a reified inline call in the body (a member property
/// initializer `val key: AttributeKey<T> = AttributeKey(name)`) infers
/// its type argument from the property's declared type — the same hint
/// a local `val x: T = …` already supplies.
pub fn lowerAccessorExprWithExpected(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    expr: *const Expr,
    name: []const u8,
    expected: ?TypeRef,
) Allocator.Error!FuncId {
    return lowerAccessorExprFull(module, owner_class, own_members, null, params, null, expr, name, expected);
}

fn lowerAccessorExprFull(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    enclosing_members: ?*const StringSet,
    params: []const []const u8,
    declared_params: ?[]const Param,
    expr: *const Expr,
    name: []const u8,
    expected: ?TypeRef,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    // The accessor body runs with `this` of type `owner_class`, so a bare
    // call inside resolves against that receiver — record it so the
    // overload/inline resolver prefers a member of the receiver over a
    // same-named imported extension with a different receiver type (e.g.
    // `get(Job)` inside `CoroutineContext.job` binds the context's `get`
    // operator, not ktor's inline `HttpClient.get`).
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    if (enclosing_members) |em| b.setEnclosingMembers(try cloneOwnMembers(allocator, em));
    try bindParams(&b, params);
    if (declared_params) |typed| {
        try b.setLocalDeclType("this", owner_class);
        for (typed) |p| {
            if (b.resolve(p.name) == null) continue;
            // A `vararg names: String` parameter's VALUE is an Array; typing
            // it by its element sent `names.toList()` in a property
            // initializer to the CharSequence extension.
            try b.setLocalDeclType(p.name, if (p.is_vararg) "Array" else p.ty.name);
            if (p.ty.nullable and !p.is_vararg) try b.setLocalDeclNullable(p.name);
        }
    }
    const prev = b.pushExpected(expected);
    // `var first: Long = 0` — the initializer literal takes the property's
    // declared type, exactly as a local `val x: Long = 0` does.
    const widened: ?Expr = if (expected) |*ty| literals.widenNumericLiteral(expr, ty) else null;
    const v = try lowerExpr(&b, if (widened) |*w| w else expr);
    b.restoreExpected(prev);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, try accessorReturnTy(allocator, expected));
    func.params = try accessorParams(allocator, params);
    func.has_receiver_param = leadsWithThis(params);
    const fid = try pushFunc(module, func);
    // A synthesized accessor/initializer carries its declaring file: the
    // import-scoped member-extension probe resolves against the frame
    // fn's decl_span file, and a property initializer using an imported
    // companion extension (`val xs = listOf(1.seconds)`) is legal there.
    try module.decl_span.put(fid.int(), expr.span());
    return fid;
}

/// The accessor's declared property type as its IR return type, so the
/// getter's return head is readable where the naming-contract lookup
/// consumes it. Unit when the property declares none.
fn accessorReturnTy(allocator: Allocator, expected: ?TypeRef) Allocator.Error!ir.TypeRef {
    const ty = expected orelse return build.typeUnit();
    if (ty.name.name.len == 0) return build.typeUnit();
    return .{
        .name = try allocator.dupe(u8, ty.name.name),
        .nullable = ty.nullable,
        .args = &.{},
    };
}

/// Record the accessor's bound parameters as `Func.params` so the eval
/// `this`-parameter fallback can recover the receiver.
fn accessorParams(allocator: Allocator, params: []const []const u8) Allocator.Error![]Param {
    const out = try allocator.alloc(Param, params.len);
    for (params, out) |n, *slot| {
        slot.* = .{
            .name = n,
            .ty = build.typeUnit(),
            .default = null,
            .is_property = false,
            .is_vararg = false,
            .has_default = false,
        };
    }
    return out;
}

/// Variant of `lowerAccessorExpr` for block-body accessors.
pub fn lowerAccessorBlock(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    block: *const ast.Block,
    name: []const u8,
) Allocator.Error!FuncId {
    return lowerAccessorBlockRet(module, owner_class, own_members, params, block, name, null);
}

/// `lowerAccessorBlock` carrying the property's declared type as the
/// accessor's return type (the ext-getter naming-contract lookup reads it).
pub fn lowerAccessorBlockRet(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    block: *const ast.Block,
    name: []const u8,
    expected: ?TypeRef,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    // Box body `var`s (and params) a nested lambda mutates into shared cells,
    // exactly as a normal function body does — a block-body accessor
    // (`val x get() { var acc = 0; xs.forEach { acc += it }; acc }`) that
    // mutates a local from inside a non-inline lambda would otherwise capture
    // a copy and lose the write.
    try setInitBlockBoxedVars(&b, allocator, params, block);
    try bindParams(&b, params);
    // A secondary constructor's BODY reads that constructor's parameters,
    // and this builder knew their names alone.
    try consumePendingParamTypes(&b, params);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, try accessorReturnTy(allocator, expected));
    // Record the synthesized parameter list. Without it the frame's `this`
    // is invisible to `frameThisParam`, so a bare member call in the body
    // finds NO implicit receiver and falls through to the global tier —
    // an inner class's accessor calling the OUTER class's member died as
    // `unresolved global` (the receiver walk never ran, so it never
    // followed the `outer` link).
    func.params = try accessorParams(allocator, params);
    func.has_receiver_param = leadsWithThis(params);
    const fid = try pushFunc(module, func);
    // Same declaring-file stamp as the expression form above.
    try module.decl_span.put(fid.int(), block.span);
    return fid;
}

/// `lowerAccessorBlock`/`lowerAccessorExpr` with the SETTER's value
/// parameter typed: `set(value) { if (value <= 0) ... }` resolves `value`
/// against the property's declared type, so its member calls and templates
/// bind statically.
pub fn lowerSetterBlockTyped(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    value_name: []const u8,
    value_ty_head: ?[]const u8,
    value_nullable: bool,
    block: *const ast.Block,
    name: []const u8,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    try setInitBlockBoxedVars(&b, allocator, params, block);
    try bindParams(&b, params);
    if (value_ty_head) |h| {
        try b.setLocalDeclType(value_name, h);
        if (value_nullable) try b.setLocalDeclNullable(value_name);
    }
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.params = try accessorParams(allocator, params);
    func.has_receiver_param = leadsWithThis(params);
    return pushFuncSpanned(module, func, block.span);
}

pub fn lowerSetterExprTyped(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    value_name: []const u8,
    value_ty_head: ?[]const u8,
    value_nullable: bool,
    expr: *const Expr,
    name: []const u8,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    try bindParams(&b, params);
    if (value_ty_head) |h| {
        try b.setLocalDeclType(value_name, h);
        if (value_nullable) try b.setLocalDeclNullable(value_name);
    }
    const v = try lowerExpr(&b, expr);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.params = try accessorParams(allocator, params);
    func.has_receiver_param = leadsWithThis(params);
    return pushFuncSpanned(module, func, expr.span());
}

pub fn lowerUnaryExprAsThunk(
    module: *Module,
    param_name: []const u8,
    expr: *const Expr,
    name: []const u8,
) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    try bindParams(&b, &.{param_name});
    const v = try lowerExpr(&b, expr);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFuncSpanned(module, func, expr.span());
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const span = @import("span");

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

fn intLit(v: i64) Expr {
    return .{ .IntLit = .{ .value = v, .kind = .Int, .span = dummySpan() } };
}

/// Free the per-block instruction / catch slices and the params /
/// capture-name lists of every func a thunk lowering pushed onto a
/// module (the module's `deinit` only frees the func list itself).
fn freeModuleFuncs(module: *Module) void {
    const a = testing.allocator;
    for (module.funcs.items) |func| {
        for (func.blocks) |bk| {
            if (bk.insts.len != 0) a.free(bk.insts);
            if (bk.catches.len != 0) a.free(bk.catches);
        }
        a.free(func.blocks);
        if (func.capture_order.len != 0) a.free(func.capture_order);
        if (func.params.len != 0) a.free(func.params);
    }
}

test "lower_expr_as_thunk pushes a zero-arg func returning the value" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    defer freeModuleFuncs(&m);
    const lit = intLit(7);
    const id = try lowerExprAsThunk(&m, &lit, "thunk");
    try testing.expectEqual(@as(u32, 0), id.int());
    try testing.expectEqual(@as(usize, 1), m.funcs.items.len);
    const f = m.funcs.items[0];
    try testing.expectEqual(id, f.id);
    try testing.expectEqualStrings("thunk", f.name);
    try testing.expect(f.blocks[0].terminator == .Return);
    try testing.expect(f.blocks[0].terminator.Return != null);
}

test "lower_empty_thunk returns Unit and binds the params" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    defer freeModuleFuncs(&m);
    const params = [_][]const u8{ "this", "value" };
    const id = try lowerEmptyThunk(&m, &params, "empty");
    const f = m.funcs.items[id.int()];
    // Two LoadParam insts plus the Unit const.
    try testing.expectEqual(@as(usize, 3), f.blocks[0].insts.len);
    try testing.expect(f.blocks[0].insts[0] == .LoadParam);
    try testing.expect(f.blocks[0].insts[2] == .Const);
    try testing.expect(f.blocks[0].terminator == .Return);
}

test "lower_accessor_expr records accessor params on the func" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    defer freeModuleFuncs(&m);
    var members = StringSet.init(testing.allocator);
    defer members.deinit();
    const params = [_][]const u8{"this"};
    const lit = intLit(3);
    const id = try lowerAccessorExpr(&m, "Foo", &members, &params, &lit, "get");
    const f = m.funcs.items[id.int()];
    try testing.expectEqual(@as(usize, 1), f.params.len);
    try testing.expectEqualStrings("this", f.params[0].name);
}

test "push_func assigns sequential ids" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    defer freeModuleFuncs(&m);
    const a = intLit(1);
    const b = intLit(2);
    const id0 = try lowerExprAsThunk(&m, &a, "a");
    const id1 = try lowerExprAsThunk(&m, &b, "b");
    try testing.expectEqual(@as(u32, 0), id0.int());
    try testing.expectEqual(@as(u32, 1), id1.int());
}
