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
const lowerBlock = expr_mod.lowerBlock;

/// The allocator backing a `Module`'s growable tables. The module's
/// containers are unmanaged, so recover the allocator from a managed
/// member (`func_name_index`) it was initialised with.
fn moduleAllocator(module: *Module) Allocator {
    return module.func_name_index.allocator;
}

/// Assign the next `FuncId` to `func` and append it to the module.
fn pushFunc(module: *Module, func_in: Func) Allocator.Error!FuncId {
    // FuncId indexes module.funcs; the IR caps the func count at u32.
    const id = FuncId.from(@intCast(module.funcs.items.len));
    var func = func_in;
    func.id = id;
    try module.funcs.append(moduleAllocator(module), func);
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
pub fn lowerExprAsThunk(module: *Module, expr: *const Expr, name: []const u8) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    const v = try lowerExpr(&b, expr);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFunc(module, func);
}

/// Lower a block as a 0-arg synthetic function. The block's trailing
/// expression becomes the implicit return value.
pub fn lowerBlockAsThunk(module: *Module, block: *const ast.Block, name: []const u8) Allocator.Error!FuncId {
    var b = try FuncBuilder.init(moduleAllocator(module), module);
    defer b.deinit();
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFunc(module, func);
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
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    const func = try b.finish(name, name, build.typeUnit());
    return pushFunc(module, func);
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
    return pushFunc(module, func);
}

pub fn lowerExprAsParamThunk(
    module: *Module,
    params: []const []const u8,
    expr: *const Expr,
    name: []const u8,
) Allocator.Error!FuncId {
    return lowerExprAsParamThunkScoped(module, params, expr, name, null, null);
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
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    try bindParams(&b, params);
    b.setParamThunk(true);
    if (owner_class) |owner| {
        b.setOwnerClass(owner);
    }
    if (own_members) |set| {
        b.setOwnMembers(try cloneOwnMembers(allocator, set));
    }
    const v = try lowerExpr(&b, expr);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.has_receiver_param = leadsWithThis(params);
    return pushFunc(module, func);
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
    try bindParams(&b, params);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.params = try accessorParams(allocator, params);
    func.has_receiver_param = leadsWithThis(params);
    return pushFunc(module, func);
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
    try bindParams(&b, &.{"this"});
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.has_receiver_param = true;
    return pushFunc(module, func);
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
    return lowerAccessorExprWithExpected(module, owner_class, own_members, params, expr, name, null);
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
    try bindParams(&b, params);
    const prev = b.pushExpected(expected);
    const v = try lowerExpr(&b, expr);
    b.restoreExpected(prev);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.params = try accessorParams(allocator, params);
    func.has_receiver_param = leadsWithThis(params);
    return pushFunc(module, func);
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
    const allocator = moduleAllocator(module);
    var b = try FuncBuilder.init(allocator, module);
    defer b.deinit();
    b.setOwnerClass(owner_class);
    b.setRecvTy(owner_class);
    b.setOwnMembers(try cloneOwnMembers(allocator, own_members));
    try bindParams(&b, params);
    const v = try lowerBlock(&b, block);
    b.terminate(.{ .Return = v });
    var func = try b.finish(name, name, build.typeUnit());
    func.has_receiver_param = leadsWithThis(params);
    return pushFunc(module, func);
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
    return pushFunc(module, func);
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
