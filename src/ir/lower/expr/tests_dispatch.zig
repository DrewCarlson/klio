//! Expression lowering tests: paths, members, literals and the dispatch
//! ladder.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const BinOp = ir.BinOp;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const StringSet = std.StringHashMap(void);
const testing = std.testing;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const paths_mod = @import("paths.zig");
const collectScopeClasses = paths_mod.collectScopeClasses;
const loweredCheckTypeName = paths_mod.loweredCheckTypeName;
const sgetterOwner = paths_mod.sgetterOwner;

const lambda_mod = @import("lambda.zig");
const fnTypeReceiverHead = lambda_mod.fnTypeReceiverHead;
const memberHostingTrailingLambda = lambda_mod.memberHostingTrailingLambda;
const overloadHostingTrailingLambda = lambda_mod.overloadHostingTrailingLambda;

const call_general_mod = @import("call_general.zig");
const inlineBodyRecvChain = call_general_mod.inlineBodyRecvChain;

const local_call_mod = @import("local_call.zig");
const headCompatible = local_call_mod.headCompatible;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;

const static_type_mod = @import("static_type.zig");
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const type_probe_mod = @import("type_probe.zig");
const buildArgShapes = type_probe_mod.buildArgShapes;

const bare_call_mod = @import("bare_call.zig");
const receiverScopeCompletePlain = bare_call_mod.receiverScopeCompletePlain;
const resolvePrivateMemberCall = bare_call_mod.resolvePrivateMemberCall;

const probe_mod = @import("probe.zig");
const memberCallArgArities = probe_mod.memberCallArgArities;

const member_call_mod = @import("member_call.zig");
const lowerResolvedMemberCall = member_call_mod.lowerResolvedMemberCall;

const tests_shapes_mod = @import("tests_shapes.zig");
const Module = tests_shapes_mod.Module;
const dummySpan = tests_shapes_mod.dummySpan;
const freeFunc = tests_shapes_mod.freeFunc;
const span = tests_shapes_mod.span;

test "scope getter owner follows the class contributing an enclosing property" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);

    var inner_names = std.StringHashMap(void).init(testing.allocator);
    try inner_names.put("innerValue", {});
    try m.registry.hierarchy_shadow_names.put("Outer$Inner", .{
        .names = inner_names,
        .complete = true,
    });
    var outer_names = std.StringHashMap(void).init(testing.allocator);
    try outer_names.put("receiveException", {});
    try m.registry.hierarchy_shadow_names.put("Outer", .{
        .names = outer_names,
        .complete = true,
    });
    try m.registry.enclosing_class.put("Outer$Inner", "Outer");

    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOwnerClass("Outer$Inner");

    try testing.expectEqualStrings("Outer$Inner", sgetterOwner(&b, "innerValue").?);
    try testing.expectEqualStrings("Outer", sgetterOwner(&b, "receiveException").?);
}

test "receiver scope completeness requires a complete static receiver tower" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const owner_names = std.StringHashMap(void).init(testing.allocator);
    try m.registry.hierarchy_shadow_names.put("Owner", .{
        .names = owner_names,
        .complete = true,
    });

    var owner_builder = try FuncBuilder.init(testing.allocator, &m);
    defer owner_builder.deinit();
    owner_builder.setOwnerClass("Owner");
    try testing.expect(receiverScopeCompletePlain(&owner_builder));

    m.registry.hierarchy_shadow_names.getPtr("Owner").?.complete = false;
    try testing.expect(!receiverScopeCompletePlain(&owner_builder));
    m.registry.hierarchy_shadow_names.getPtr("Owner").?.complete = true;

    try m.registry.enclosing_class.put("Owner", "Outer");
    try testing.expect(!receiverScopeCompletePlain(&owner_builder));
    _ = m.registry.enclosing_class.remove("Owner");

    try m.registry.companion_singletons.put("Owner", "Owner$Companion");
    try testing.expect(!receiverScopeCompletePlain(&owner_builder));
    _ = m.registry.companion_singletons.remove("Owner");

    var extension_builder = try FuncBuilder.init(testing.allocator, &m);
    defer extension_builder.deinit();
    extension_builder.setRecvTy("String");
    try testing.expect(!receiverScopeCompletePlain(&extension_builder));
    const string_names = std.StringHashMap(void).init(testing.allocator);
    try m.registry.hierarchy_shadow_names.put("String", .{
        .names = string_names,
        .complete = true,
    });
    try testing.expect(receiverScopeCompletePlain(&extension_builder));
    m.registry.hierarchy_shadow_names.getPtr("String").?.complete = false;
    try testing.expect(!receiverScopeCompletePlain(&extension_builder));
    m.registry.hierarchy_shadow_names.getPtr("String").?.complete = true;
    extension_builder.setOwnerClass("Owner");
    try testing.expect(receiverScopeCompletePlain(&extension_builder));
}

test "bare enclosing property lowers with its outer getter owner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = Module.default(a);
    defer m.deinit(a);
    var inner_names = std.StringHashMap(void).init(a);
    try inner_names.put("next", {});
    try m.registry.hierarchy_shadow_names.put("Outer$Inner", .{
        .names = inner_names,
        .complete = true,
    });
    var outer_names = std.StringHashMap(void).init(a);
    try outer_names.put("receiveException", {});
    try m.registry.hierarchy_shadow_names.put("Outer", .{
        .names = outer_names,
        .complete = true,
    });
    try m.registry.enclosing_class.put("Outer$Inner", "Outer");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("Outer$Inner");
    var enclosing = StringSet.init(a);
    try enclosing.put("receiveException", {});
    b.setEnclosingMembers(enclosing);
    try b.bind("this", b.allocReg());

    var seg = [_]ast.Ident{.{ .name = "receiveException", .span = dummySpan() }};
    const e = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    const result = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = result });
    const func = try b.finish("next", "Outer.Inner.next", build.typeString());

    try testing.expect(func.blocks[0].insts[0] == .LoadFromThisOrGlobal);
    const field = func.blocks[0].insts[0].LoadFromThisOrGlobal.name;
    try testing.expectEqualStrings(
        "$sgetter$Outer\u{1f}receiveException",
        m.consts.items[field.int()].String,
    );
}

test "super property in a lambda uses the enclosing this capture" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOwnerClass("Derived");
    b.setOuterNames(StringSet.init(testing.allocator));

    var receiver = Expr{ .Super = .{
        .qualifier = null,
        .label = null,
        .span = dummySpan(),
    } };
    const e = Expr{ .Member = .{
        .receiver = &receiver,
        .name = .{ .name = "label", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "Derived.f", build.typeString());
    defer freeFunc(func);

    try testing.expectEqual(@as(usize, 2), func.blocks[0].insts.len);
    const capture = func.blocks[0].insts[0].LoadCapture;
    const call = func.blocks[0].insts[1].CallSuper;
    try testing.expectEqual(capture.dst, call.receiver);
    try testing.expectEqualStrings("this", func.capture_order[capture.idx]);
}

test "labeled super starts at the labeled outer class on this@Outer" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOwnerClass("Inner");
    b.setOuterNames(StringSet.init(testing.allocator));
    try b.bind("this", b.allocReg());

    var receiver = Expr{ .Super = .{
        .qualifier = null,
        .label = .{ .name = "Outer", .span = dummySpan() },
        .span = dummySpan(),
    } };
    const e = Expr{ .Member = .{
        .receiver = &receiver,
        .name = .{ .name = "label", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "Inner.f", build.typeString());
    defer freeFunc(func);

    try testing.expectEqual(@as(usize, 2), func.blocks[0].insts.len);
    const qthis = func.blocks[0].insts[0].QualifiedThis;
    try testing.expectEqualStrings("Outer", m.consts.items[qthis.qualifier.int()].String);
    const call = func.blocks[0].insts[1].CallSuper;
    try testing.expectEqual(qthis.dst, call.receiver);
    try testing.expectEqualStrings("Outer", m.consts.items[call.owner_class.int()].String);
    try testing.expect(call.qualifier == null);
}

test "lowers int min value as int" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // -2147483648 parses as Neg(IntLit(2147483648)).
    var lit = Expr{ .IntLit = .{ .value = @as(i64, std.math.maxInt(i32)) + 1, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .Unary = .{ .op = .Neg, .expr = &lit, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].insts[0] == .Const);
    const cid = func.blocks[0].insts[0].Const.value;
    try testing.expect(m.consts.items[cid.int()] == .Int);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), m.consts.items[cid.int()].Int);
}

test "lowers if expression with both arms" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var cond = Expr{ .BoolLit = .{ .value = true, .span = dummySpan() } };
    var t_branch = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    var e_branch = Expr{ .IntLit = .{ .value = 2, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .If = .{
        .cond = &cond,
        .then_branch = &t_branch,
        .else_branch = &e_branch,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    // The entry block ends in a Branch terminator.
    try testing.expect(func.blocks[0].terminator == .Branch);
}

test "lowers string template as concat chain" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var parts = [_]ast.StringPart{
        .{ .Text = "hi " },
        .{ .Text = "there" },
    };
    const e = Expr{ .StringTemplate = .{ .parts = &parts, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeString());
    defer freeFunc(func);
    // The final instruction is a StringConcat BinOp.
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .BinOp);
    try testing.expectEqual(BinOp.StringConcat, insts[insts.len - 1].BinOp.op);
}

test "captured lateinit local reads through LateinitCheck in a lambda body" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var outer = StringSet.init(testing.allocator);
    try outer.put("s", {});
    try outer.put("s$klio_lateinit", {});
    b.setOuterNames(outer);

    var segs = [_]ast.Ident{.{ .name = "s", .span = dummySpan() }};
    const e = Expr{ .Path = .{ .segments = &segs, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeString());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .LateinitCheck);
    try testing.expectEqual(r.int(), insts[insts.len - 1].LateinitCheck.dst.int());
    // A lambda parameter shadowing the captured name is a plain binding.
    var b2 = try FuncBuilder.init(testing.allocator, &m);
    defer b2.deinit();
    var outer2 = StringSet.init(testing.allocator);
    try outer2.put("s", {});
    try outer2.put("s$klio_lateinit", {});
    b2.setOuterNames(outer2);
    const param = b2.allocReg();
    try b2.bind("s", param);
    const r2 = try lowerExpr(&b2, &e);
    try testing.expectEqual(param.int(), r2.int());
    b2.terminate(.{ .Return = r2 });
    const func2 = try b2.finish("g", "g", build.typeString());
    defer freeFunc(func2);
    for (func2.blocks[0].insts) |inst| try testing.expect(inst != .LateinitCheck);
}

test "boxed capture interpolation reads the entry-hoisted cell value" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var outer = StringSet.init(testing.allocator);
    try outer.put("count", {});
    b.setOuterNames(outer);
    var boxed = StringSet.init(testing.allocator);
    try boxed.put("count", {});
    b.setBoxedVars(boxed);

    var parts = [_]ast.StringPart{.{ .ShortInterp = .{ .name = "count", .span = dummySpan() } }};
    const e = Expr{ .StringTemplate = .{ .parts = &parts, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeString());
    defer freeFunc(func);

    var capture_reg: ?Reg = null;
    var value_reg: ?Reg = null;
    for (func.blocks[0].insts) |inst| switch (inst) {
        .LoadCapture => |lc| capture_reg = lc.dst,
        .CellGet => |cg| {
            try testing.expectEqual(capture_reg.?, cg.cell);
            value_reg = cg.dst;
        },
        else => {},
    };
    try testing.expect(capture_reg != null);
    try testing.expect(value_reg != null);
    const concat = func.blocks[0].insts[func.blocks[0].insts.len - 1].BinOp;
    try testing.expectEqual(value_reg.?, concat.rhs);
}

test "lowers elvis as branch with null check" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var lhs = Expr{ .NullLit = .{ .span = dummySpan() } };
    var rhs = Expr{ .IntLit = .{ .value = 3, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .Binary = .{ .op = .Elvis, .lhs = &lhs, .rhs = &rhs, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].terminator == .Branch);
}

test "lowers is-check to instance-of" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var inner = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    const ty = ast.TypeRef{
        .name = .{ .name = "Int", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const e = Expr{ .IsCheck = .{ .expr = &inner, .ty = ty, .negated = false, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeBool());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .InstanceOf);
}

test "bare is-check type normalises to the file's exact-import class FQN" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    // Two packages declare a nested `Marker` under a same-named outer class:
    // both lift as `Operation$Marker`, so the bare simple name identifies
    // neither. The file's explicit import names exactly one; the check type
    // must carry that class's canonical FQN so the runtime compares identity.
    _ = try m.reserveClassFqn(a, "Operation$Marker", "com.ga.Operation.Marker", "com.ga", false);
    _ = try m.reserveClassFqn(a, "Operation$Marker", "com.gb.Operation.Marker", "com.gb", false);
    {
        var paths: std.ArrayList(ir.ModuleRegistry.ImportPath) = .empty;
        const segs = try a.alloc([]const u8, 4);
        segs[0] = "com";
        segs[1] = "ga";
        segs[2] = "Operation";
        segs[3] = "Marker";
        try paths.append(a, .{ .fqn = try a.dupe(u8, "com.ga.Operation.Marker"), .segs = segs });
        var inner_map = std.StringHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(a);
        try inner_map.put("Marker", paths);
        try m.registry.import_aliases.put(span.FileId.from(0), inner_map);
    }
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const ty = ast.TypeRef{
        .name = .{ .name = "Marker", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    try testing.expectEqualStrings("com.ga.Operation.Marker", loweredCheckTypeName(&b, &ty));
    // A file without the import keeps the bare simple name.
    const ty2 = ast.TypeRef{
        .name = .{ .name = "Marker", .span = span.Span.init(span.FileId.from(3), 0, 0) },
        .nullable = false,
        .span = span.Span.init(span.FileId.from(3), 0, 0),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    try testing.expectEqualStrings("Marker", loweredCheckTypeName(&b, &ty2));
}

test "anonymous object carries a lexical classifier identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();
    try m.registry.file_packages.put(sp.file, "sample");
    _ = try m.reserveClassFqn(a, "Marker", "sample.Marker", "sample", false);
    try m.registry.companion_singletons.put("Marker", "Marker$Companion");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var segs = [_]ast.Ident{.{ .name = "Marker", .span = sp }};
    const expr = Expr{ .Path = .{ .segments = &segs, .span = sp } };
    const refs = try collectScopeClasses(&b, &expr);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("Marker", refs[0].name);
    try testing.expectEqualStrings("sample.Marker", refs[0].fqn);
    try testing.expect(refs[0].has_companion);
}

test "trailing-lambda arity host accepts a signature-only candidate" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    // `launch(context, start, block)` as it looks to a file lowered BEFORE
    // the file that declares it: the signature (params, function-typed
    // tail) is lifted, but no body is attached yet. The arity host must
    // still pick it — skipping it left the trailing receiver lambda with a
    // spurious implicit `it` bound to the invocation's receiver argument.
    const params = try a.alloc(ir.Param, 4);
    params[0] = .{ .name = "this", .ty = .{ .name = "CoroutineScope", .nullable = false, .args = &.{} }, .default = null };
    params[1] = .{ .name = "context", .ty = .{ .name = "CoroutineContext", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[2] = .{ .name = "start", .ty = .{ .name = "CoroutineStart", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[3] = .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .default = null };
    const id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = id,
        .name = "launch",
        .fqn = "kotlinx.coroutines.launch",
        .package = "kotlinx.coroutines",
        .params = params,
        .return_ty = .{ .name = "Job", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = &.{}, // signature only: hasBody() == false
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    try m.func_index.append(a, .{ .name = "launch", .id = id });
    try m.rebuildFuncNameIndex(a);
    defer {
        a.free(m.funcs.items[id.int()].params);
        m.funcs.items[id.int()].params = &.{};
    }

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    // `launch(Dispatchers.Default) { … }`: two user args, trailing lambda.
    const picked = overloadHostingTrailingLambda(&b, "launch", 2);
    try testing.expect(picked != null);
    try testing.expectEqual(id.int(), picked.?.int());
}

test "typed explicit extension receiver supplies trailing lambda arity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    try m.registry.class_super_names.put("TestScope", try a.dupe([]const u8, &.{"CoroutineScope"}));

    const params = try a.alloc(ir.Param, 4);
    params[0] = .{ .name = "this", .ty = .{ .name = "CoroutineScope", .nullable = false, .args = &.{} }, .default = null };
    params[1] = .{ .name = "context", .ty = .{ .name = "CoroutineContext", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[2] = .{ .name = "start", .ty = .{ .name = "CoroutineStart", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[3] = .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .default = null };
    const id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = id,
        .name = "launch",
        .fqn = "launch",
        .package = "",
        .params = params,
        .return_ty = .{ .name = "Job", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .top_level_extension,
    });
    try m.func_index.append(a, .{ .name = "launch", .id = id });
    try m.rebuildFuncNameIndex(a);
    defer {
        a.free(m.funcs.items[id.int()].params);
        m.funcs.items[id.int()].params = &.{};
    }

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const recv_reg = b.allocReg();
    try b.bind("outerScope", recv_reg);
    try b.setLocalDeclType("outerScope", "TestScope");
    var recv_segs = [_]ast.Ident{.{ .name = "outerScope", .span = dummySpan() }};
    const receiver = Expr{ .Path = .{ .segments = &recv_segs, .span = dummySpan() } };
    var implicit_it = [_]ast.Ident{.{ .name = "it", .span = dummySpan() }};
    const args = [_]Expr{.{ .Lambda = .{
        .params = &implicit_it,
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
        .implicit_it = true,
    } }};
    const arities = (try memberCallArgArities(&b, &receiver, "launch", &args, &.{})).?;
    defer a.free(arities);
    try testing.expectEqualSlices(i16, &.{0}, arities);
}

test "inherited member receiver lambda uses abstract defaults" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    try m.registry.class_super_names.put("ResumeTest", try a.dupe([]const u8, &.{"TestBase"}));

    var block_args = [_]ir.TypeRef{
        .{ .name = "CoroutineScope", .nullable = false, .args = &.{} },
        .{ .name = "Unit", .nullable = false, .args = &.{} },
    };
    const params = try a.alloc(ir.Param, 4);
    params[0] = .{ .name = "this", .ty = .{ .name = "TestBase", .nullable = false, .args = &.{} }, .default = null };
    params[1] = .{ .name = "expected", .ty = .{ .name = "Function1", .nullable = true, .args = &.{} }, .default = null };
    params[2] = .{ .name = "unhandled", .ty = .{ .name = "List", .nullable = false, .args = &.{} }, .default = null };
    params[3] = .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &block_args }, .default = null };
    const id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = id,
        .name = "runTest",
        .fqn = "TestBase.runTest",
        .package = "",
        .params = params,
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .instance_method,
    });
    defer {
        a.free(m.funcs.items[id.int()].params);
        m.funcs.items[id.int()].params = &.{};
    }
    try m.registry.member_method_fids.put(try a.dupe(u8, "TestBase\x00runTest\x003"), id);
    var defaults: std.ArrayList(?FuncId) = .empty;
    try defaults.appendSlice(a, &.{ null, id, id, null });
    try m.registry.abstract_member_defaults.put(.{ .a = "TestBase", .b = "runTest" }, defaults);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("ResumeTest");
    const picked = memberHostingTrailingLambda(&b, "runTest", 1);
    try testing.expect(picked != null);
    try testing.expectEqual(id.int(), picked.?.int());
    try testing.expectEqualStrings("CoroutineScope", fnTypeReceiverHead(&b, params[3].ty).?);
}

test "headCompatible: literal heads disprove scalar params only" {
    // Literal Boolean disproves a String param — the local-fn overload
    // shape that recursed before selection existed.
    try std.testing.expect(!headCompatible("Boolean", "String", true));
    try std.testing.expect(headCompatible("Boolean", "Boolean", true));
    // Numeric literals coerce across the numeric family.
    try std.testing.expect(headCompatible("Int", "Long", true));
    try std.testing.expect(headCompatible("Int", "Double", true));
    try std.testing.expect(!headCompatible("Int", "String", true));
    // A lambda binds only function-shaped or generic params.
    try std.testing.expect(headCompatible("->", "() -> Unit", true));
    try std.testing.expect(headCompatible("->", "T", true));
    try std.testing.expect(!headCompatible("->", "String", true));
    try std.testing.expect(!headCompatible("String", "(Int) -> Int", true));
    // A parsed function type carries the synthetic `<function>` tag; a
    // lambda binds it under either strictness. `expect(…, predicate:
    // (Char) -> Boolean) { it == '-' }` regressed when the tag was not
    // recognized and the local fn was deemed inapplicable.
    try std.testing.expect(headCompatible("->", "<function>", true));
    try std.testing.expect(headCompatible("->", "<function>", false));
    // A user class head never disproves another named type (supertypes
    // are unknown here); generic/Any params accept anything.
    try std.testing.expect(headCompatible("MyThing", "Other", true));
    try std.testing.expect(headCompatible("String", "Any", true));
    try std.testing.expect(headCompatible("Int", "T", true));
    // Disproof-only lambda case (applicability decision): a lambda may
    // bind an unknown class name (a possible function typealias), so it
    // is not ruled inapplicable — but a definite scalar still disproves.
    try std.testing.expect(headCompatible("->", "MyPredicate", false));
    try std.testing.expect(!headCompatible("->", "MyPredicate", true));
    try std.testing.expect(!headCompatible("->", "String", false));
    try std.testing.expect(!headCompatible("->", "Int", false));
    // Nullable params adjudicate under the underlying head.
    try std.testing.expect(headCompatible("Boolean", "Boolean?", true));
    try std.testing.expect(!headCompatible("Boolean", "String?", true));
}

test "shared member resolution selects overloads and dispatch forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const owner = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Owner",
        .fqn = "sample.Owner",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });

    const Add = struct {
        fn member(
            module: *Module,
            allocator: Allocator,
            owner_id: ir.ClassId,
            name: []const u8,
            ty: []const u8,
            is_private: bool,
            is_open: bool,
        ) !FuncId {
            const id = module.nextFuncId();
            const params = try allocator.alloc(ir.Param, 2);
            params[0] = .{ .name = "this", .ty = .{ .name = "Owner", .nullable = false, .args = &.{} }, .default = null };
            params[1] = .{ .name = "value", .ty = .{ .name = ty, .nullable = false, .args = &.{} }, .default = null };
            try module.funcs.append(allocator, .{
                .id = id,
                .name = name,
                .fqn = "sample.Owner.member",
                .package = "sample",
                .params = params,
                .return_ty = build.typeUnit(),
                .n_locals = 0,
                .blocks = &.{},
                .entry = ir.BlockId.from(0),
                .is_suspend = false,
                .kind = .instance_method,
                .has_receiver_param = true,
                .is_open = is_open,
            });
            const declared = try allocator.alloc(ir.TypeRef, 1);
            declared[0] = params[1].ty;
            try module.decl_sigs.put(id.int(), .{
                .enclosing_class = owner_id,
                .arity = .{ .required = 1, .total = 1, .has_vararg = false },
                .sig = declared,
                .kind = .instance_method,
                .visibility = if (is_private) .Private else .Public,
                .has_body = true,
            });
            try module.registerMemberDecl(allocator, "sample.Owner", name, id);
            return id;
        }
    };
    const int_pick = try Add.member(&m, a, owner, "pick", "Int", true, false);
    const bool_pick = try Add.member(&m, a, owner, "pick", "Boolean", true, false);
    m.classes.items[owner.int()].is_open = true;
    const final_pick = try Add.member(&m, a, owner, "finalPick", "Int", false, false);
    const virtual_pick = try Add.member(&m, a, owner, "virtualPick", "Int", false, true);
    const lambda_pick = try Add.member(&m, a, owner, "lambdaPick", "Function1", false, false);
    const member_plus = try Add.member(&m, a, owner, "plus", "Int", true, false);
    const nullable_plus = m.nextFuncId();
    const nullable_params = try a.dupe(ir.Param, &.{
        .{ .name = "this", .ty = .{ .name = "Owner", .nullable = true, .args = &.{} }, .default = null },
        .{ .name = "value", .ty = build.typeInt(), .default = null },
    });
    try m.funcs.append(a, .{
        .id = nullable_plus,
        .name = "plus",
        .fqn = "sample.nullablePlus",
        .package = "sample",
        .params = nullable_params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .deferred_offset = 1,
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .top_level_extension,
        .has_receiver_param = true,
    });
    try m.func_index.append(a, .{ .name = "plus", .id = nullable_plus });
    try m.decl_sigs.put(nullable_plus.int(), .{
        .receiver_ty = nullable_params[0].ty,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = try a.dupe(ir.TypeRef, &.{build.typeInt()}),
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.registry.file_packages.put(dummySpan().file, "sample");
    try m.rebuildFuncNameIndex(a);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("Owner");
    var int_args = [_]Expr{.{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } }};
    var bool_args = [_]Expr{.{ .BoolLit = .{ .value = true, .span = dummySpan() } }};
    var unknown_name = [_]ast.Ident{.{ .name = "unknown", .span = dummySpan() }};
    var unknown_args = [_]Expr{.{ .Path = .{ .segments = &unknown_name, .span = dummySpan() } }};
    try testing.expectEqual(
        int_pick,
        (try resolvePrivateMemberCall(
            &b,
            "pick",
            dummySpan().file,
            &int_args,
            &.{},
        )).target.?,
    );
    try testing.expectEqual(
        bool_pick,
        (try resolvePrivateMemberCall(
            &b,
            "pick",
            dummySpan().file,
            &bool_args,
            &.{},
        )).target.?,
    );
    try testing.expect((try resolvePrivateMemberCall(
        &b,
        "pick",
        dummySpan().file,
        &unknown_args,
        &.{},
    )).target == null);

    const int_shapes = try buildArgShapes(&b, &int_args, &.{});
    defer a.free(int_shapes);
    const final_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.direct, final_result.dispatch);
    try testing.expectEqual(final_pick, final_result.target.?);
    const virtual_result = m.resolveMemberCall(owner, "virtualPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.virtual, virtual_result.dispatch);
    try testing.expectEqual(virtual_pick, virtual_result.target.?);
    const lambda_shapes = [_]applicability.ArgShape{.{
        .is_lambda = true,
        .lambda_arity = 1,
        .lambda_is_literal = true,
    }};
    const lambda_result = m.resolveMemberCall(owner, "lambdaPick", &lambda_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.direct, lambda_result.dispatch);
    try testing.expectEqual(lambda_pick, lambda_result.target.?);
    const recv_reg = b.allocReg();
    try b.bind("target", recv_reg);
    try b.setLocalDeclType("target", "Owner");
    var recv_path = [_]ast.Ident{.{ .name = "target", .span = dummySpan() }};
    var recv_expr = Expr{ .Path = .{ .segments = &recv_path, .span = dummySpan() } };
    const lowered_virtual = try lowerResolvedMemberCall(
        &b,
        &recv_expr,
        .{ .name = "virtualPick", .span = dummySpan() },
        &int_args,
        &.{},
        &.{},
        .{ .name = "Owner", .nullable = false, .args = &.{} },
        .{},
    );
    try testing.expect(lowered_virtual == .lowered);
    const virtual_inst = b.blocks.items[b.cur.int()].insts[b.blocks.items[b.cur.int()].insts.len - 1];
    try testing.expect(virtual_inst == .CallVirtual);
    try testing.expectEqual(ir.MethodSlotId.fromFunc(virtual_pick), virtual_inst.CallVirtual.slot);
    // A `specialized` classifier's values are host-represented, and a virtual
    // slot is still the right emission for one: `invokeVirtualMember` resolves
    // it against an interpreted receiver's own class and falls back to the
    // member's name for a host-backed value.
    m.classes.items[owner.int()].receiver_abi = .specialized;
    try testing.expect((try lowerResolvedMemberCall(
        &b,
        &recv_expr,
        .{ .name = "virtualPick", .span = dummySpan() },
        &int_args,
        &.{},
        &.{},
        .{ .name = "Owner", .nullable = false, .args = &.{} },
        .{},
    )) == .lowered);
    const specialized_inst = b.blocks.items[b.cur.int()].insts[b.blocks.items[b.cur.int()].insts.len - 1];
    try testing.expect(specialized_inst == .CallVirtual);
    m.classes.items[owner.int()].receiver_abi = .instance;
    m.classes.items[owner.int()].is_open = false;
    m.classes.items[owner.int()].is_stub = true;
    const stub_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.virtual, stub_result.dispatch);
    try testing.expectEqual(final_pick, stub_result.target.?);
    m.classes.items[owner.int()].is_stub = false;
    m.classes.items[owner.int()].is_value = true;
    // A value-class receiver arrives boxed like any instance, so its final
    // members take the ordinary direct rule.
    const value_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.direct, value_result.dispatch);
    try testing.expectEqual(final_pick, value_result.target.?);
    m.classes.items[owner.int()].is_value = false;
    m.decl_sigs.getPtr(final_pick.int()).?.has_body = false;
    const bodyless_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.virtual, bodyless_result.dispatch);
    try testing.expectEqual(final_pick, bodyless_result.target.?);
    m.decl_sigs.getPtr(final_pick.int()).?.has_body = true;

    const eager_recv_span = ast.Span.init(dummySpan().file, 50, 51);
    var eager_types = std.AutoHashMap(ast.Span, ir.EagerTypeHead).init(a);
    try eager_types.put(eager_recv_span, .{ .name = "Owner", .nullable = false });
    m.eager_types = eager_types;
    try b.bind("eagerTarget", b.allocReg());
    var eager_recv_path = [_]ast.Ident{.{
        .name = "eagerTarget",
        .span = eager_recv_span,
    }};
    var eager_receiver = Expr{ .Path = .{
        .segments = &eager_recv_path,
        .span = eager_recv_span,
    } };
    var eager_member = Expr{ .Member = .{
        .receiver = &eager_receiver,
        .name = .{ .name = "finalPick", .span = eager_recv_span },
        .safe = false,
        .span = eager_recv_span,
    } };
    const eager_call = Expr{ .Call = .{
        .callee = &eager_member,
        .args = &int_args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = eager_recv_span,
    } };
    _ = try lowerExpr(&b, &eager_call);
    const eager_call_inst = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ];
    try testing.expect(eager_call_inst == .Call);
    try testing.expectEqual(final_pick, eager_call_inst.Call.func);
    try testing.expect(eager_call_inst.Call.exact);

    try b.setLocalDeclNullable("target");
    const nullable_binary = Expr{ .Binary = .{
        .lhs = &recv_expr,
        .op = .Add,
        .rhs = &int_args[0],
        .span = dummySpan(),
    } };
    _ = try lowerExpr(&b, &nullable_binary);
    const nullable_inst = b.blocks.items[b.cur.int()].insts[b.blocks.items[b.cur.int()].insts.len - 1];
    try testing.expect(nullable_inst == .Call);
    try testing.expectEqual(nullable_plus, nullable_inst.Call.func);
    try testing.expect(nullable_inst.Call.exact);
    try testing.expect(nullable_inst.Call.func != member_plus);

    // A receiver typed by a TYPE PARAMETER resolves through the parameter's
    // upper bound. The bound record drops the bound's type ARGUMENTS, which
    // is what `head_only` reports and what `complete` refuses — and the
    // stdlib's two most common parameters (`C : MutableCollection<in T>`,
    // `M : MutableMap<in K, in V>`) are exactly that shape.
    m.classes.items[owner.int()].is_open = true;
    try b.bind("bounded", b.allocReg());
    try b.setLocalDeclType("bounded", "C");
    var bounded_path = [_]ast.Ident{.{ .name = "bounded", .span = dummySpan() }};
    var bounded_recv = Expr{ .Path = .{ .segments = &bounded_path, .span = dummySpan() } };
    const bounded_ty = ir.TypeRef{ .name = "C", .nullable = false, .args = &.{} };

    try b.addTypeParamBoundHead("C", "Owner", false, false);
    try testing.expect((try lowerResolvedMemberCall(
        &b,
        &bounded_recv,
        .{ .name = "virtualPick", .span = dummySpan() },
        &int_args,
        &.{},
        &.{},
        bounded_ty,
        .{},
    )) == .none);

    try b.addTypeParamBoundHead("C", "Owner", false, true);
    try testing.expect((try lowerResolvedMemberCall(
        &b,
        &bounded_recv,
        .{ .name = "virtualPick", .span = dummySpan() },
        &int_args,
        &.{},
        &.{},
        bounded_ty,
        .{},
    )) == .lowered);
    const bounded_inst = b.blocks.items[b.cur.int()].insts[b.blocks.items[b.cur.int()].insts.len - 1];
    try testing.expect(bounded_inst == .CallVirtual);
    try testing.expectEqual(ir.MethodSlotId.fromFunc(virtual_pick), bounded_inst.CallVirtual.slot);
}

test "the declared-type walk terminates on a cyclic initializer chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();

    // `a`'s type comes from `b.field`, and `b`'s from `a.field`. Kotlin cannot
    // write that, but lowering asks about both from a point where both are
    // bound, and the walk followed the chain forever.
    var a_path = [_]ast.Ident{.{ .name = "a", .span = dummySpan() }};
    var b_path = [_]ast.Ident{.{ .name = "b", .span = dummySpan() }};
    var a_recv = Expr{ .Path = .{ .segments = &a_path, .span = dummySpan() } };
    var b_recv = Expr{ .Path = .{ .segments = &b_path, .span = dummySpan() } };
    const a_init = Expr{ .Member = .{
        .receiver = &b_recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const b_init = Expr{ .Member = .{
        .receiver = &a_recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    try b.bind("a", b.allocReg());
    try b.bind("b", b.allocReg());
    try b.setLocalInitExpr("a", &a_init);
    try b.setLocalInitExpr("b", &b_init);

    try testing.expect(argDeclTypeRefLazy(&b, &a_recv) == null);
    try testing.expect(argDeclTypeRefLazy(&b, &b_recv) == null);
    try testing.expectEqual(@as(usize, 0), static_type_mod.init_chain_len);
}

test "explicit member extension emits its resolved declaration identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();
    try m.registry.file_packages.put(sp.file, "sample");
    const owner = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Scope",
        .fqn = "sample.Scope",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_object = true,
    });
    const target = m.nextFuncId();
    const params = try a.dupe(ir.Param, &.{.{
        .name = "this",
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .default = null,
    }});
    try m.funcs.append(a, .{
        .id = target,
        .name = "value",
        .fqn = "sample.Scope.value",
        .package = "sample",
        .params = params,
        .return_ty = build.typeInt(),
        .n_locals = 0,
        .blocks = &.{},
        .deferred_offset = 1,
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .member_extension,
        .has_receiver_param = true,
    });
    try m.func_index.append(a, .{ .name = "value", .id = target });
    try m.registry.member_ext_owner_class.put(target, "sample.Scope");
    try m.decl_sigs.put(target.int(), .{
        .enclosing_class = owner,
        .receiver_ty = params[0].ty,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .member_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const previous_package = build.setLowerSelfPackage("sample");
    defer _ = build.setLowerSelfPackage(previous_package);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("Scope");
    const receiver_reg = b.allocReg();
    try b.bind("text", receiver_reg);
    try b.setLocalDeclType("text", "String");
    var receiver_segments = [_]ast.Ident{.{ .name = "text", .span = sp }};
    var receiver = Expr{ .Path = .{
        .segments = &receiver_segments,
        .span = sp,
    } };
    var member = Expr{ .Member = .{
        .receiver = &receiver,
        .name = .{ .name = "value", .span = sp },
        .safe = false,
        .span = sp,
    } };
    const call = Expr{ .Call = .{
        .callee = &member,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    _ = try lowerExpr(&b, &call);
    const inst = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ];
    try testing.expect(inst == .CallMember);
    try testing.expectEqual(target, inst.CallMember.resolved.?);
    try testing.expect(inst.CallMember.dispatch_receiver != null);
    var found_dispatch = false;
    for (b.blocks.items[b.cur.int()].insts) |candidate| {
        if (candidate != .LoadGlobal) continue;
        if (candidate.LoadGlobal.class == owner and
            candidate.LoadGlobal.dst == inst.CallMember.dispatch_receiver.?)
        {
            found_dispatch = true;
            break;
        }
    }
    try testing.expect(found_dispatch);
}

test "receiver callable emission respects members and lazy extensions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    var names = std.StringHashMap(void).init(a);
    try names.put("member", {});
    try m.registry.hierarchy_shadow_names.put("Target", .{
        .names = names,
        .complete = true,
    });

    const ext = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = ext,
        .name = "extension",
        .fqn = "sample.extension",
        .package = "sample",
        .params = &.{},
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    try m.func_index.append(a, .{ .name = "extension", .id = ext });
    try m.decl_sigs.put(ext.int(), .{
        .receiver_ty = .{ .name = "Target", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .has_body = true,
    });

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const target_reg = b.allocReg();
    try b.bind("target", target_reg);
    try b.setLocalDeclType("target", "Target");
    for ([_][]const u8{ "value", "member", "extension" }) |name| {
        try b.bind(name, b.allocReg());
        try b.markParam(name);
        try b.markReceiverLambdaParam(name);
        try b.markReceiverLambdaArity(name, 0);
    }

    var receiver_segments = [_]ast.Ident{.{
        .name = "target",
        .span = dummySpan(),
    }};
    var receiver = Expr{ .Path = .{
        .segments = &receiver_segments,
        .span = dummySpan(),
    } };

    const Expect = struct {
        fn lower(
            builder: *FuncBuilder,
            recv: *Expr,
            name: []const u8,
            tag: std.meta.Tag(ir.Inst),
        ) !void {
            var callee = Expr{ .Member = .{
                .receiver = recv,
                .name = .{ .name = name, .span = dummySpan() },
                .safe = false,
                .span = dummySpan(),
            } };
            const call = Expr{ .Call = .{
                .callee = &callee,
                .args = &.{},
                .arg_names = &.{},
                .type_args = &.{},
                .is_infix = false,
                .span = dummySpan(),
            } };
            _ = try lowerExpr(builder, &call);
            const insts = builder.blocks.items[builder.cur.int()].insts;
            try testing.expectEqual(tag, std.meta.activeTag(insts[insts.len - 1]));
        }
    };

    try Expect.lower(&b, &receiver, "value", .CallValueWithThis);
    try Expect.lower(&b, &receiver, "member", .CallMemberOrValue);
    try Expect.lower(&b, &receiver, "extension", .CallMemberOrValue);
    const receiver_fallback = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ].CallMemberOrValue;
    try testing.expect(receiver_fallback.fallback_takes_receiver);
    try testing.expect(receiver_fallback.fallback_receiver_shape_known);

    // A receiver-function-typed local is the same proven callable shape as a
    // parameter, even when its underlying value is an ordinary function
    // adapted at the assignment.
    try b.bind("typed", b.allocReg());
    try b.setLocalDeclRecvFn("typed");
    try Expect.lower(&b, &receiver, "typed", .CallValueWithThis);
    const typed_call = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ].CallValueWithThis;
    try testing.expect(typed_call.receiver_shape_exact);

    // A plain local remains on the member-or-value compatibility form and
    // never receives the call receiver positionally.
    try b.bind("plain", b.allocReg());
    try b.markLocalFn("plain");
    try Expect.lower(&b, &receiver, "plain", .CallMemberOrValue);
    const plain_fallback = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ].CallMemberOrValue;
    try testing.expect(!plain_fallback.fallback_takes_receiver);
    try testing.expect(plain_fallback.fallback_receiver_shape_known);

    // An erased receiver removes the member leg, but does not by itself prove
    // that a same-named local is callable. Exact value dispatch still requires
    // the local's declared receiver-function shape.
    try b.bind("unknown", b.allocReg());
    try b.markParam("unknown");
    try b.markErasedRecvParam("target");
    try Expect.lower(&b, &receiver, "value", .CallValueWithThis);
    try Expect.lower(&b, &receiver, "unknown", .CallMemberOrValue);
}

test "lowers postfix not-null assert" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var inner = Expr{ .NullLit = .{ .span = dummySpan() } };
    const e = Expr{ .Postfix = .{ .op = .NotNull, .expr = &inner, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .NotNullAssert);
}

test "trailing lambda's implicit label survives a call-shaped receiver" {
    // `Stack().apply { … }`: lowering the receiver `Stack()` re-arms the
    // ambient pending label with "Stack"; the argument lambda must still
    // record "apply" so `return@apply` unwinds to the lambda, not into
    // the `apply` frame itself. Arena-backed: lambda lowering hangs side
    // tables off the module that outlive the builder.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var recv_segs = [_]ast.Ident{.{ .name = "Stack", .span = dummySpan() }};
    var recv_callee = Expr{ .Path = .{ .segments = &recv_segs, .span = dummySpan() } };
    var recv_call = Expr{ .Call = .{
        .callee = &recv_callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    var callee = Expr{ .Member = .{
        .receiver = &recv_call,
        .name = .{ .name = "apply", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    var args = [_]Expr{.{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } }};
    var arg_names = [_]?[]const u8{null};
    const e = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    // Arena-owned: no freeFunc — the arena reclaims the whole build.
    _ = try b.finish("f", "f", build.typeUnit());
    var found = false;
    for (m.funcs.items) |*f| {
        if (f.is_lambda) {
            try testing.expectEqualStrings("apply", f.implicit_label orelse "");
            found = true;
        }
    }
    try testing.expect(found);
}

test "inline extension receiver type remains available during body splicing" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    try b.setLocalDeclType("this", "Oklab");
    b.setSpliceRecvTy("Float");
    const this_expr = Expr{ .This = .{
        .qualifier = null,
        .span = dummySpan(),
    } };
    const ty = argDeclTypeRefLazy(&b, &this_expr) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Float", ty.name);
    try testing.expect(!ty.nullable);

    const param_ty = ast.TypeRef{
        .name = .{ .name = "Float", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    _ = try b.bindSpliceParamTy("minimumValue", param_ty);
    var segments = [_]ast.Ident{.{
        .name = "minimumValue",
        .span = dummySpan(),
    }};
    const param_expr = Expr{ .Path = .{
        .segments = &segments,
        .span = dummySpan(),
    } };
    const param = argDeclTypeRefLazy(&b, &param_expr) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Float", param.name);
}

test "inline extension body receiver outranks the enclosing member receiver" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOwnerClass("MeasurePolicy");
    b.setSpliceRecvTy("List");

    const body_chain = (try inlineBodyRecvChain(&b)) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(body_chain);
    try testing.expectEqualStrings("List", body_chain[0]);

    b.lambda_splice_resolve = .{ .caller_depth = 0, .own_base = 0 };
    const lambda_chain = (try inlineBodyRecvChain(&b)) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(lambda_chain);
    try testing.expectEqualStrings("MeasurePolicy", lambda_chain[0]);
}

test "declared member property chains retain static receiver types" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    try m.registry.class_prop_type_heads.put(
        .{ .a = "Coordinator", .b = "layoutNode" },
        "LayoutNode",
    );
    try m.registry.class_prop_type_heads.put(
        .{ .a = "LayoutNode", .b = "nodes" },
        "NodeChain",
    );

    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOwnerClass("Coordinator");

    var layout_node_path = [_]ast.Ident{.{
        .name = "layoutNode",
        .span = dummySpan(),
    }};
    var layout_node = Expr{ .Path = .{
        .segments = &layout_node_path,
        .span = dummySpan(),
    } };
    const first = argDeclTypeRefLazy(&b, &layout_node) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("LayoutNode", first.name);

    const nodes = Expr{ .Member = .{
        .receiver = &layout_node,
        .name = .{ .name = "nodes", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const chained = argDeclTypeRefLazy(&b, &nodes) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("NodeChain", chained.name);
}

test "elvis over distinct branch types joins to the common supertype" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    try m.registry.class_prop_type_heads.put(.{ .a = "Holder", .b = "pending" }, "R");
    try m.registry.class_prop_type_heads.put(.{ .a = "Holder", .b = "base" }, "I");
    const supers = try testing.allocator.dupe([]const u8, &.{"I"});
    try m.registry.class_super_names.put("R", supers);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = try FuncBuilder.init(arena.allocator(), &m);
    defer b.deinit();
    b.setOwnerClass("Holder");

    var pending_path = [_]ast.Ident{.{ .name = "pending", .span = dummySpan() }};
    var pending = Expr{ .Path = .{ .segments = &pending_path, .span = dummySpan() } };
    var base_path = [_]ast.Ident{.{ .name = "base", .span = dummySpan() }};
    var base = Expr{ .Path = .{ .segments = &base_path, .span = dummySpan() } };

    const joined = Expr{ .Binary = .{
        .op = .Elvis,
        .lhs = &pending,
        .rhs = &base,
        .span = dummySpan(),
    } };
    const t = (try staticExprTypeRef(&b, &joined)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("I", t.name);

    // Same-head branches keep their type.
    const same = Expr{ .Binary = .{
        .op = .Elvis,
        .lhs = &pending,
        .rhs = &pending,
        .span = dummySpan(),
    } };
    const st = (try staticExprTypeRef(&b, &same)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("R", st.name);
}

test "bare call commits an outer tower extension through its label slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();
    try m.registry.file_packages.put(sp.file, "sample");
    _ = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Inner",
        .fqn = "sample.Inner",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_object = false,
    });
    _ = try m.addClass(a, .{
        .id = ir.ClassId.from(1),
        .name = "Outer",
        .fqn = "sample.Outer",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_object = false,
    });
    const ext = m.nextFuncId();
    const ext_params = try a.dupe(ir.Param, &.{.{
        .name = "this",
        .ty = .{ .name = "Outer", .nullable = false, .args = &.{} },
        .default = null,
    }});
    try m.funcs.append(a, .{
        .id = ext,
        .name = "describe",
        .fqn = "sample.describe",
        .package = "sample",
        .params = ext_params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .has_receiver_param = true,
    });
    try m.func_index.append(a, .{ .name = "describe", .id = ext });
    try m.decl_sigs.put(ext.int(), .{
        .receiver_ty = .{ .name = "Outer", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const previous_package = build.setLowerSelfPackage("sample");
    defer _ = build.setLowerSelfPackage(previous_package);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    // A lambda body whose own receiver is Inner; the enclosing extension
    // fn's Outer receiver sits one tower level out under `this@probe`.
    b.setRecvTy("Inner");
    try b.bind("this", b.allocReg());
    const outer_reg = b.allocReg();
    try b.bind("this@probe", outer_reg);
    try b.setImplicitReceiverTower(&.{
        .{ .head = "Inner", .label = null },
        .{ .head = "Outer", .label = "probe" },
    });

    var callee_segments = [_]ast.Ident{.{ .name = "describe", .span = sp }};
    var callee = Expr{ .Path = .{ .segments = &callee_segments, .span = sp } };
    const call = Expr{ .Call = .{
        .callee = &callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    _ = try lowerExpr(&b, &call);
    const insts = b.blocks.items[b.cur.int()].insts;
    const inst = insts[insts.len - 1];
    try testing.expect(inst == .Call);
    try testing.expectEqual(ext, inst.Call.func);
    try testing.expect(inst.Call.exact);
    // The receiver argument is the labeled outer slot, not the lambda's
    // own `this`.
    var moved_from_outer = false;
    for (insts) |candidate| {
        if (candidate != .Move) continue;
        if (candidate.Move.src == outer_reg) {
            moved_from_outer = true;
            break;
        }
    }
    try testing.expect(moved_from_outer);
}

test "a member reference on a scope-renamed nested class loads the lifted name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();
    // `Box` is a nested class of `Holder`, lifted to `Holder$Box`: it has no
    // binding under its bare simple name.
    var aliases = std.StringHashMap([]const u8).init(a);
    try aliases.put("Box", "Holder$Box");
    try m.registry.nested_object_aliases.put("Holder", aliases);
    _ = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Holder$Box",
        .fqn = "sample.Holder$Box",
        .package = "sample",
        .type_params = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("Holder");

    var recv_segments = [_]ast.Ident{.{ .name = "Box", .span = sp }};
    var recv = Expr{ .Path = .{ .segments = &recv_segments, .span = sp } };
    const ref = Expr{ .MemberRef = .{
        .receiver = &recv,
        .name = .{ .name = "i", .span = sp },
        .span = sp,
    } };
    _ = try lowerExpr(&b, &ref);

    // The qualifier resolves through the lifted name, never the bare `Box`
    // (which has no binding of its own and would raise an unresolved global).
    var lifted = false;
    var bare = false;
    for (b.blocks.items[b.cur.int()].insts) |inst| {
        const name: ?[]const u8 = switch (inst) {
            .LoadGlobal => |lg| m.consts.items[lg.name.int()].String,
            .LoadFromThisOrGlobal => |lt| m.consts.items[lt.name.int()].String,
            .GetField => |gf| m.consts.items[gf.field.int()].String,
            else => null,
        };
        const n = name orelse continue;
        if (std.mem.eql(u8, n, "Holder$Box")) lifted = true;
        if (std.mem.eql(u8, n, "Box")) bare = true;
    }
    try testing.expect(lifted);
    try testing.expect(!bare);
}
