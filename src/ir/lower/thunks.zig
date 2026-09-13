//! Lowering helpers that wrap an expression or block as a synthetic 0-, 1- or
//! 2-arg IR function, for default-arg producers, accessors and init blocks.

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

/// The allocator backing a `Module`'s growable tables, recovered from a managed
/// member since the containers are unmanaged.
fn moduleAllocator(module: *Module) Allocator {
    return module.func_name_index.allocator;
}

/// `pushFunc` plus a decl_span stamp, so a synthesized fn carries the file its body
/// was written in, which the import-scoped member-extension probe reads.
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
    try module.appendFunc(func);
    // An extension-property getter is looked up by name under the
    // `__ext_get_<Head>_<name>` contract, so without the index entry no accessor is
    // findable. Mangled names never collide with user identifiers.
    if (std.mem.startsWith(u8, func.name, "__ext_get_")) {
        const a = moduleAllocator(module);
        try module.func_index.append(a, .{ .name = func.name, .id = id });
        const gop = try module.func_name_index.getOrPut(func.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, id);
    }
    return id;
}

/// Clone a borrowed own-member set into a fresh owned `StringSet`, sharing the key
/// slices, for `setOwnMembers`, which takes ownership.
fn cloneOwnMembers(allocator: Allocator, src: *const StringSet) Allocator.Error!StringSet {
    var out = StringSet.init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

/// Lower an arbitrary expression as a 0-arg synthetic function returning its value,
/// pushed onto the module for `eval_with`.
/// `emitCtxPrologueIfAny` emits a contextual property accessor's context-load
/// prologue, and `recordThunkParamTypes` the declared type of each bound parameter,
/// when the declaration lowering stashed them; both are no-ops otherwise.
fn consumePendingParamTypes(b: *FuncBuilder, params: []const []const u8) Allocator.Error!void {
    const types = b.module.pending_param_types orelse return;
    b.module.pending_param_types = null;
    for (params, 0..) |name, i| {
        if (i >= types.len) break;
        const ty = &(types[i] orelse continue);
        if (ty.function != null or ty.name.name.len == 0) continue;
        var lowered = try decl.loweredTypeRef(b.allocator, ty, true);
        var head = std.mem.trimEnd(u8, lowered.name, "?");
        if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
        if (head.len != 0 and head.len <= 2 and std.ascii.isUpper(head[0])) {
            lowered.deinit(b.allocator);
            continue;
        }
        try b.setLocalDeclTypeOwned(name, lowered);
    }
}

/// Bind a member extension property accessor's receiver under its label
/// (`this@<prop>`) and record its dispatch owner when the declaration lowering
/// stashed them.
fn consumePendingAccessorReceiver(b: *FuncBuilder, params: []const []const u8) Allocator.Error!void {
    const label = b.module.pending_accessor_this_label;
    const owner = b.module.pending_accessor_dispatch_owner;
    b.module.pending_accessor_this_label = null;
    b.module.pending_accessor_dispatch_owner = null;
    if (!leadsWithThis(params)) return;
    const this_reg = b.resolve("this") orelse return;
    if (label) |l| {
        const slot = try std.fmt.allocPrint(b.allocator, "this@{s}", .{l});
        try b.bind(slot, this_reg);
        b.setOwnThisLabel(l);
    }
    if (owner) |o| b.setDispatchOwner(o);
}

/// Install the owner class's member arity mask when the declaration lowering
/// stashed one; otherwise the permissive default stands.
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

/// A top-level delegated property's delegate thunk: the expression, then the
/// `provideDelegate` convention with a null receiver.
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

/// As `lowerExprAsThunk`, seeding the declared type as the tail-position expected
/// type, so `var g: Long = 0` widens its literal as a local `val x: Long = 0` does.
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

/// Lower a block as a 0-arg synthetic function, its trailing expression becoming
/// the implicit return value.
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

/// Lower an expression as a 2-arg synthetic function bound under the supplied
/// parameter names, for instance accessors taking `this` and the new value.
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

/// Like `lowerExprAsParamThunk` but also puts the enclosing class's name and
/// own-member set in scope.
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

/// Full form: also threads the lexically enclosing class chain's member names, so a
/// bare name in a nested class's ctor default that names an outer member resolves
/// through the receiver walk.
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
    // The declared parameter type the thunk's expression must satisfy, from which a
    // parent-constructor argument binds its reified parameter.
    const expected = module.pending_thunk_expected;
    module.pending_thunk_expected = null;
    const prev_expected = b.pushExpected(expected);
    const v = try lowerExpr(&b, expr);
    _ = b.pushExpected(prev_expected);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    // Record the bound params for a `this`-leading thunk, an inner class's
    // ctor-default: the eval `this`-parameter fallback reads them to recover the
    // receiver. Other param thunks keep the empty metadata their callers expect.
    if (leadsWithThis(params)) {
        func.params = try accessorParams(allocator, params, owner_class orelse "", null);
    }
    func.has_receiver_param = leadsWithThis(params);
    return pushFuncSpanned(module, func, expr.span());
}

/// Whether a synthesized param list leads with the implicit `this` receiver. These
/// lists are compiler-built, so a leading `this` is never a user backtick parameter.
fn leadsWithThis(params: []const []const u8) bool {
    return params.len != 0 and std.mem.eql(u8, params[0], "this");
}

/// Lower an init-style block with arbitrary bound parameter names, recording the
/// bound params including `this` so the eval `this`-parameter fallback recovers the
/// receiver and a bare companion-method call resolves against the instance's chain.
pub fn lowerInitBlockWithParams(
    module: *Module,
    owner_class: []const u8,
    own_members: *const StringSet,
    params: []const []const u8,
    declared_params: []const Param,
    block: *const ast.Block,
    name: []const u8,
) Allocator.Error!FuncId {
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    // Box body `var`s and params a nested lambda mutates into shared cells, as a
    // normal function body does; otherwise the lambda's write is lost.
    try setInitBlockBoxedVars(&b, allocator, params, block);
    try bindParams(&b, params);
    // An init block reads the constructor's parameters, whose names alone its
    // builder knew.
    try consumePendingParamTypes(&b, params);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.params = try accessorParams(allocator, params, owner_class, declared_params);
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

/// Lower a class init block as a 1-arg IR function whose only parameter binds `this`.
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

/// The set of `var`s, body decls plus params, that a nested lambda in the init block
/// mutates, marked for boxing so the lambda closes over a shared cell.
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

/// Like `lowerAccessorExpr` but seeds the lexically enclosing class's member set, so
/// a nested class's initializer or accessor resolves a bare name the enclosing class
/// or its companion declares, not an unrelated global of the same simple name.
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

/// Lower a body-property initializer preserving the declared types of the
/// primary-constructor parameters its synthetic function captures, which participate
/// in overload resolution as in an ordinary function body.
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

/// Like `lowerAccessorExpr` but seeds the tail-position expected type, so a reified
/// inline call infers its type argument from the property's declared type.
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
    // The accessor body runs with `this` of type `owner_class`, so record it and let
    // the resolver prefer a member of the receiver over a same-named imported
    // extension with a different receiver type.
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    if (enclosing_members) |em| b.setEnclosingMembers(try cloneOwnMembers(allocator, em));
    try bindParams(&b, params);
    try consumePendingAccessorReceiver(&b, params);
    if (declared_params) |typed| {
        try b.setLocalDeclType("this", owner_class);
        for (typed) |p| {
            if (b.resolve(p.name) == null) continue;
    // A `vararg names: String` parameter's value is an Array; typing it by its
    // element sends a `names.toList()` to the CharSequence extension.
            try b.setLocalDeclType(p.name, if (p.is_vararg) "Array" else p.ty.name);
            if (p.ty.nullable and !p.is_vararg) try b.setLocalDeclNullable(p.name);
        }
    }
    const prev = b.pushExpected(expected);
    // `var first: Long = 0`: the initializer literal takes the property's declared
    // type, as a local `val x: Long = 0` does.
    const widened: ?Expr = if (expected) |*ty| literals.widenNumericLiteral(expr, ty) else null;
    const v = try lowerExpr(&b, if (widened) |*w| w else expr);
    b.restoreExpected(prev);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, try accessorReturnTy(allocator, expected));
    func.params = try accessorParams(allocator, params, owner_class, declared_params);
    func.has_receiver_param = leadsWithThis(params);
    const fid = try pushFunc(module, func);
    // A synthesized accessor or initializer carries its declaring file: the
    // import-scoped member-extension probe resolves against the frame fn's
    // decl_span file, and a property initializer using an imported companion
    // extension is legal there.
    try module.decl_span.put(fid.int(), expr.span());
    return fid;
}

/// The accessor's declared property type as its IR return type, so the getter's
/// return head is readable where the naming-contract lookup consumes it. Unit when
/// the property declares none.
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
/// `this`-parameter fallback can recover the receiver. Each carries the type it was
/// declared with where known: a body-property initializer reading `side * 2` off an
/// `Int` constructor parameter is an integer multiply, which a caller seeing only
/// `Unit` cannot tell.
fn accessorParams(
    allocator: Allocator,
    params: []const []const u8,
    owner_class: []const u8,
    declared: ?[]const Param,
) Allocator.Error![]Param {
    const out = try allocator.alloc(Param, params.len);
    for (params, out, 0..) |n, *slot, i| {
        var ty = build.typeUnit();
        if (i == 0 and std.mem.eql(u8, n, "this") and owner_class.len != 0) {
            ty = .{ .name = owner_class, .nullable = false, .args = &.{} };
        } else if (declared) |typed| {
            for (typed) |d| {
                if (!std.mem.eql(u8, d.name, n)) continue;
                // A `vararg` parameter's value is an Array, not one element.
                ty = if (d.is_vararg)
                    .{ .name = "Array", .nullable = false, .args = &.{} }
                else
                    d.ty;
                break;
            }
        }
        slot.* = .{
            .name = n,
            .ty = ty,
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

/// `lowerAccessorBlock` carrying the property's declared type as the accessor's
/// return type, which the ext-getter naming-contract lookup reads.
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
    // Box body `var`s and params a nested lambda mutates into shared cells, exactly
    // as a normal function body does; otherwise a block-body accessor mutating a
    // local from inside a non-inline lambda captures a copy and loses the write.
    try setInitBlockBoxedVars(&b, allocator, params, block);
    try bindParams(&b, params);
    try consumePendingAccessorReceiver(&b, params);
    // A secondary constructor's body reads that constructor's parameters, and this
    // builder knew their names alone.
    try consumePendingParamTypes(&b, params);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, try accessorReturnTy(allocator, expected));
    // Record the synthesized parameter list. Without it the frame's `this` is
    // invisible to `frameThisParam`, so a bare member call in the body finds no
    // implicit receiver and falls through to the global tier: an inner class's
    // accessor calling the outer class's member dies as `unresolved global`, the
    // receiver walk never following the `outer` link.
    func.params = try accessorParams(allocator, params, owner_class, null);
    func.has_receiver_param = leadsWithThis(params);
    const fid = try pushFunc(module, func);
    // Same declaring-file stamp as the expression form above.
    try module.decl_span.put(fid.int(), block.span);
    return fid;
}

/// `lowerAccessorBlock` and `lowerAccessorExpr` with the setter's value parameter
/// typed, so `set(value) { … }` resolves `value` against the property's declared
/// type and its member calls and templates bind statically.
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
    func.params = try accessorParams(allocator, params, owner_class, null);
    // The value parameter's declared type belongs on the signature too: a consumer
    // reading `Func.params`, such as the native emitter, has no other place to learn
    // what a setter takes.
    if (value_ty_head) |vh| {
        for (func.params) |*fp| {
            if (!std.mem.eql(u8, fp.name, value_name)) continue;
            fp.ty = .{ .name = vh, .nullable = value_nullable, .args = &.{} };
        }
    }
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
    func.params = try accessorParams(allocator, params, owner_class, null);
    // The value parameter's declared type belongs on the signature too: a consumer
    // reading `Func.params`, such as the native emitter, has no other place to learn
    // what a setter takes.
    if (value_ty_head) |vh| {
        for (func.params) |*fp| {
            if (!std.mem.eql(u8, fp.name, value_name)) continue;
            fp.ty = .{ .name = vh, .nullable = value_nullable, .args = &.{} };
        }
    }
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

/// Free the per-block instruction and catch slices and the params and capture-name
/// lists of every func a thunk lowering pushed onto a module; the module's `deinit`
/// frees only the func list itself.
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
