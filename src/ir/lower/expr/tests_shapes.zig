//! Expression lowering tests: argument shapes, lambdas, compose ABI threading
//! and call emission.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const compose_pass = @import("compose_pass");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const UnOp = ir.UnOp;
const FuncId = ir.FuncId;
const BlockId = ir.BlockId;
const Func = ir.Func;
const StringSet = std.StringHashMap(void);
const testing = std.testing;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const lambda_mod = @import("lambda.zig");
const mapArgsToParams = lambda_mod.mapArgsToParams;
const recordLambdaArgReceivers = lambda_mod.recordLambdaArgReceivers;
const recordLambdaArgReceiversForCallReceiver = lambda_mod.recordLambdaArgReceiversForCallReceiver;

const compose_mod = @import("compose.zig");
const selectedCallArgs = compose_mod.selectedCallArgs;
const selectedCallArgsForBuilder = compose_mod.selectedCallArgsForBuilder;

const emit_mod = @import("emit.zig");
const emitMemberOrGlobal = emit_mod.emitMemberOrGlobal;
const threadedTrailingLambdaParam = emit_mod.threadedTrailingLambdaParam;
const trailingLambdaArgNames = emit_mod.trailingLambdaArgNames;

const arg_shape_mod = @import("arg_shape.zig");
const shapeOfAstArg = arg_shape_mod.shapeOfAstArg;

const type_probe_mod = @import("type_probe.zig");
const buildArgShapes = type_probe_mod.buildArgShapes;

const bare_call_mod = @import("bare_call.zig");
const resolveCtxFor = bare_call_mod.resolveCtxFor;

const member_call_mod = @import("member_call.zig");
const localExtensionReceiverCouldApply = member_call_mod.localExtensionReceiverCouldApply;

pub const span = @import("span");
pub const Module = ir.Module;

pub fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

pub fn freeFunc(func: Func) void {
    for (func.blocks) |b| {
        if (b.insts.len != 0) testing.allocator.free(b.insts);
        if (b.catches.len != 0) testing.allocator.free(b.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

test "buildArgShapes: literal, lambda, spread, and named argument shapes" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();

    const lit = Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = dummySpan() } };
    var lam_params = [_]ast.Ident{.{ .name = "x", .span = dummySpan() }};
    const lam = Expr{ .Lambda = .{
        .params = &lam_params,
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } };
    var spread_inner = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } };
    const spread = Expr{ .Spread = .{ .expr = &spread_inner, .span = dummySpan() } };

    const args = [_]Expr{ lit, lam, spread };
    const names = [_]?[]const u8{ null, "block", null };
    const shapes = try buildArgShapes(&b, &args, &names);
    defer b.allocator.free(shapes);

    try testing.expectEqual(@as(usize, 3), shapes.len);
    // Literal Int argument: numeric literal kind, not a lambda / spread.
    try testing.expect(shapes[0].literal_kind == .numeric);
    try testing.expect(!shapes[0].is_lambda);
    try testing.expect(!shapes[0].is_spread);
    try testing.expect(shapes[0].named == null);
    try testing.expect(shapes[0].lambda_arity == null);
    // Named lambda argument: one declared param, bound to name "block".
    try testing.expect(shapes[1].is_lambda);
    try testing.expectEqual(@as(?u8, 1), shapes[1].lambda_arity);
    try testing.expectEqualStrings("block", shapes[1].named.?);
    try testing.expect(shapes[1].literal_kind == null);
    // Spread argument.
    try testing.expect(shapes[2].is_spread);
    try testing.expect(!shapes[2].is_lambda);
    try testing.expect(shapes[2].named == null);

    const null_lit = Expr{ .NullLit = .{ .span = dummySpan() } };
    const null_shape = shapeOfAstArg(&b, &null_lit, null);
    try testing.expect(null_shape.is_null);

    try b.setLocalCallReturn("predicate", "Boolean", false);
    var predicate_segments = [_]ast.Ident{.{ .name = "predicate", .span = dummySpan() }};
    var predicate = Expr{ .Path = .{ .segments = &predicate_segments, .span = dummySpan() } };
    const predicate_call = Expr{ .Call = .{
        .callee = &predicate,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    const call_shape = shapeOfAstArg(&b, &predicate_call, null);
    try testing.expectEqualStrings("Boolean", call_shape.ty.?.name);
}

test "binary overload lowering preserves structural call return types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();
    const lhs_sp = span.Span.init(sp.file, 1, 2);
    const rhs_sp = span.Span.init(sp.file, 3, 4);
    const rhs2_sp = span.Span.init(sp.file, 5, 6);
    try m.registry.file_packages.put(sp.file, "sample");

    const box = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Box",
        .fqn = "sample.Box",
        .package = "sample",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    _ = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Stream",
        .fqn = "sample.Stream",
        .package = "sample",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });

    const int_args = try a.dupe(ir.TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    const t_args = try a.dupe(ir.TypeRef, &.{
        .{ .name = "T", .nullable = false, .args = &.{} },
    });
    const stream_int = ir.TypeRef{ .name = "Stream", .nullable = false, .args = int_args };
    const box_t = ir.TypeRef{ .name = "Box", .nullable = false, .args = t_args };
    const stream_t = ir.TypeRef{ .name = "Stream", .nullable = false, .args = t_args };
    const child_box_int = ir.TypeRef{ .name = "ChildBox", .nullable = false, .args = int_args };
    const child_box_t = ir.TypeRef{ .name = "ChildBox", .nullable = false, .args = t_args };
    const child_supers = try a.dupe(ir.ClassId, &.{box});
    const child_super_refs = try a.dupe(ir.TypeRef, &.{box_t});
    _ = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "ChildBox",
        .fqn = "sample.ChildBox",
        .package = "sample",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = child_supers,
        .supertype_refs = child_super_refs,
    });

    const Add = struct {
        fn func(
            module: *Module,
            alloc: Allocator,
            name: []const u8,
            params: []ir.Param,
            return_ty: ir.TypeRef,
            kind: ir.FuncKind,
            receiver_ty: ?ir.TypeRef,
            sig: []const ir.TypeRef,
        ) !FuncId {
            const id = module.nextFuncId();
            const blocks = try alloc.alloc(ir.Block, 1);
            blocks[0] = .{
                .id = ir.BlockId.from(0),
                .insts = &.{},
                .terminator = .{ .Return = null },
            };
            try module.funcs.append(alloc, .{
                .id = id,
                .name = name,
                .fqn = try std.fmt.allocPrint(alloc, "sample.{s}", .{name}),
                .package = "sample",
                .params = params,
                .return_ty = return_ty,
                .n_locals = 0,
                .blocks = blocks,
                .entry = ir.BlockId.from(0),
                .is_suspend = false,
                .kind = kind,
                .has_receiver_param = kind == .top_level_extension,
            });
            try module.func_index.append(alloc, .{ .name = name, .id = id });
            const user_arity: u16 = @intCast(sig.len);
            const arity: Module.DeclArity = .{
                .required = user_arity,
                .total = user_arity,
                .has_vararg = false,
            };
            try module.decl_user_arity.put(id.int(), arity);
            try module.decl_sigs.put(id.int(), .{
                .receiver_ty = receiver_ty,
                .arity = arity,
                .sig = sig,
                .kind = kind,
                .has_body = true,
            });
            return id;
        }
    };

    const make_box = try Add.func(
        &m,
        a,
        "makeBox",
        &.{},
        child_box_int,
        .plain,
        null,
        &.{},
    );
    const make_stream = try Add.func(
        &m,
        a,
        "makeStream",
        &.{},
        stream_int,
        .plain,
        null,
        &.{},
    );
    const element_params = try a.dupe(ir.Param, &.{
        .{ .name = "this", .ty = box_t, .default = null },
        .{ .name = "element", .ty = t_args[0], .default = null },
    });
    const element = try Add.func(
        &m,
        a,
        "plus",
        element_params,
        child_box_t,
        .top_level_extension,
        box_t,
        &.{t_args[0]},
    );
    const stream_params = try a.dupe(ir.Param, &.{
        .{ .name = "this", .ty = box_t, .default = null },
        .{ .name = "elements", .ty = stream_t, .default = null },
    });
    const sequence = try Add.func(
        &m,
        a,
        "plus",
        stream_params,
        child_box_t,
        .top_level_extension,
        box_t,
        &.{stream_t},
    );
    for ([_]FuncId{ element, sequence }) |fid| {
        var params: std.ArrayList([]const u8) = .empty;
        try params.append(a, "T");
        try m.registry.func_type_params.put(fid, params);
    }
    try m.rebuildFuncNameIndex(a);

    var make_box_path = [_]ast.Ident{.{ .name = "makeBox", .span = lhs_sp }};
    var make_box_callee = Expr{ .Path = .{ .segments = &make_box_path, .span = lhs_sp } };
    var lhs = Expr{ .Call = .{
        .callee = &make_box_callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = lhs_sp,
    } };
    var make_stream_path = [_]ast.Ident{.{ .name = "makeStream", .span = rhs_sp }};
    var make_stream_callee = Expr{ .Path = .{ .segments = &make_stream_path, .span = rhs_sp } };
    var rhs = Expr{ .Call = .{
        .callee = &make_stream_callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = rhs_sp,
    } };
    var inner = Expr{ .Binary = .{
        .lhs = &lhs,
        .op = .Add,
        .rhs = &rhs,
        .span = sp,
    } };
    var make_stream2_path = [_]ast.Ident{.{ .name = "makeStream", .span = rhs2_sp }};
    var make_stream2_callee = Expr{ .Path = .{ .segments = &make_stream2_path, .span = rhs2_sp } };
    var rhs2 = Expr{ .Call = .{
        .callee = &make_stream2_callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = rhs2_sp,
    } };
    const binary = Expr{ .Binary = .{
        .lhs = &inner,
        .op = .Add,
        .rhs = &rhs2,
        .span = span.Span.init(sp.file, 7, 8),
    } };

    var eager_types = std.AutoHashMap(ast.Span, ir.EagerTypeHead).init(a);
    try eager_types.put(lhs_sp, .{ .name = "ChildBox", .nullable = false });
    try eager_types.put(rhs_sp, .{ .name = "Stream", .nullable = false });
    try eager_types.put(rhs2_sp, .{ .name = "Stream", .nullable = false });
    try eager_types.put(sp, .{ .name = "ChildBox", .nullable = false });
    m.eager_types = eager_types;
    const prev_package = build.setLowerSelfPackage("sample");
    defer _ = build.setLowerSelfPackage(prev_package);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    _ = try lowerExpr(&b, &binary);

    var saw_make_box = false;
    var make_stream_count: usize = 0;
    var sequence_count: usize = 0;
    for (b.blocks.items[b.cur.int()].insts) |inst| switch (inst) {
        .Call => |call| {
            if (call.func == make_box) saw_make_box = true;
            if (call.func == make_stream) make_stream_count += 1;
            if (call.func == element) return error.TestUnexpectedResult;
            if (call.func == sequence) {
                try testing.expect(call.exact);
                sequence_count += 1;
            }
        },
        else => {},
    };
    try testing.expect(saw_make_box);
    try testing.expectEqual(@as(usize, 2), make_stream_count);
    try testing.expectEqual(@as(usize, 2), sequence_count);
}

test "selected call args discard a composer pair from a non-composable overload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const plain_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = plain_id,
        .name = "sameName",
        .fqn = "sample.sameName",
        .params = try a.dupe(ir.Param, &.{.{ .name = "value", .ty = build.typeInt(), .default = null }}),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    const composable_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = composable_id,
        .name = "sameName",
        .fqn = "sample.sameNameComposable",
        .params = &.{},
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .annotation_names = &.{"Composable"},
    });

    const args = [_]Expr{
        .{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } },
        .{ .NullLit = .{ .span = dummySpan() } },
        .{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } },
    };
    const names = [_]?[]const u8{ null, "$composer", "$changed" };
    const plain = selectedCallArgs(&m, plain_id, &args, &names);
    try testing.expectEqual(@as(usize, 1), plain.args.len);
    try testing.expectEqual(@as(usize, 1), plain.names.len);
    const composable = selectedCallArgs(&m, composable_id, &args, &names);
    try testing.expectEqual(@as(usize, 3), composable.args.len);
    try testing.expectEqual(@as(usize, 3), composable.names.len);

    const header_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = header_id,
        .name = "reserved",
        .fqn = "sample.reserved",
        .params = try a.dupe(ir.Param, &.{.{ .name = "value", .ty = build.typeInt(), .default = null }}),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    const body_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = body_id,
        .name = "reserved",
        .fqn = "sample.reserved",
        .params = try a.dupe(ir.Param, &.{
            .{ .name = "value", .ty = build.typeInt(), .default = null },
            .{ .name = "$composer", .ty = build.typeUnit(), .default = null },
            .{ .name = "$changed", .ty = build.typeInt(), .default = null },
        }),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    const reserved_sig: ir.Module.DeclSig = .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{build.typeInt()},
        .has_body = true,
    };
    try m.decl_sigs.put(header_id.int(), reserved_sig);
    try m.decl_sigs.put(body_id.int(), reserved_sig);
    try m.func_index.append(a, .{ .name = "reserved", .id = header_id });
    try m.func_index.append(a, .{ .name = "reserved", .id = body_id });
    try m.rebuildFuncNameIndex(a);
    const reserved = selectedCallArgs(&m, header_id, &args, &names);
    try testing.expectEqual(@as(usize, 3), reserved.args.len);
    try testing.expectEqual(@as(usize, 3), reserved.names.len);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    try b.bind("$composer", b.allocReg());
    const source_names = [_]?[]const u8{null};
    var completed = try selectedCallArgsForBuilder(
        &b,
        header_id,
        args[0..1],
        &source_names,
        dummySpan(),
        false,
    );
    defer completed.deinit(a);
    try testing.expectEqual(@as(usize, 3), completed.args.len);
    try testing.expectEqualStrings("$composer", completed.names[1].?);
    try testing.expectEqualStrings("$changed", completed.names[2].?);
    try testing.expect(completed.args[1] == .Path);
    try testing.expectEqualStrings("$composer", completed.args[1].Path.segments[0].name);
}

test "threaded trailing lambda binds before the composer pair" {
    var params = [_]ir.Param{
        .{ .name = "modifier$arg", .ty = .{ .name = "Modifier", .nullable = false, .args = &.{} }, .default = null },
        .{ .name = "measurePolicy", .ty = .{ .name = "Function1", .nullable = false, .args = &.{} }, .default = null },
        .{ .name = "$composer", .ty = .{ .name = "Composer", .nullable = false, .args = &.{} }, .default = null },
        .{ .name = "$changed", .ty = build.typeInt(), .default = null },
    };
    const f = Func{
        .id = FuncId.from(0),
        .name = "SubcomposeLayout",
        .fqn = "androidx.compose.ui.layout.SubcomposeLayout",
        .params = &params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    };
    var lambda_params: [0]ast.Ident = .{};
    const args = [_]Expr{
        .{ .Lambda = .{
            .params = &lambda_params,
            .body = .{ .stmts = &.{}, .span = dummySpan() },
            .span = dummySpan(),
        } },
        .{ .NullLit = .{ .span = dummySpan() } },
        .{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } },
    };
    const names = [_]?[]const u8{ null, "$composer", "$changed" };
    const hit = threadedTrailingLambdaParam(&f, &args, &names).?;
    try testing.expectEqual(@as(usize, 0), hit.arg_index);
    try testing.expectEqualStrings("measurePolicy", hit.param_name);

    const explicitly_named = [_]?[]const u8{ "measurePolicy", "$composer", "$changed" };
    try testing.expect(threadedTrailingLambdaParam(&f, &args, &explicitly_named) == null);

    params[1].is_vararg = true;
    try testing.expect(threadedTrailingLambdaParam(&f, &args, &names) == null);
}

test "selected composable parameters bind named and trailing lambdas exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const scaffold_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = scaffold_id,
        .name = "Scaffold",
        .fqn = "androidx.compose.material3.Scaffold",
        .params = try a.dupe(ir.Param, &.{
            .{
                .name = "topBar",
                .ty = .{ .name = "Function0", .nullable = false, .args = &.{} },
                .default = null,
                .composable_arity = 0,
            },
            .{
                .name = "modifier",
                .ty = .{ .name = "Modifier", .nullable = false, .args = &.{} },
                .default = null,
                .has_default = true,
            },
            .{
                .name = "content",
                .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
                .default = null,
                .composable_arity = 1,
            },
            .{ .name = "$composer", .ty = .{ .name = "Composer", .nullable = false, .args = &.{} }, .default = null },
            .{ .name = "$changed", .ty = build.typeInt(), .default = null },
        }),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .annotation_names = &.{"Composable"},
    });

    var composable_names = std.StringHashMap(void).init(a);
    try composable_names.put("TopAppBar", {});
    var sinks = std.StringHashMap(void).init(a);
    compose_pass.active_composable_names = &composable_names;
    defer compose_pass.active_composable_names = null;
    compose_pass.active_composable_sinks = &sinks;
    defer compose_pass.active_composable_sinks = null;
    const old_memo = compose_pass.emit_lambda_memo;
    compose_pass.emit_lambda_memo = true;
    defer compose_pass.emit_lambda_memo = old_memo;

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    try b.bind("$composer", b.allocReg());

    var top_segments = [_]ast.Ident{.{ .name = "TopAppBar", .span = dummySpan() }};
    var top_callee = Expr{ .Path = .{ .segments = &top_segments, .span = dummySpan() } };
    var top_args: [0]Expr = .{};
    var top_names: [0]?[]const u8 = .{};
    const top_call = Expr{ .Call = .{
        .callee = &top_callee,
        .args = &top_args,
        .arg_names = &top_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = dummySpan(),
    } };
    var lambda_params: [0]ast.Ident = .{};
    var lambda_stmts = [_]ast.Stmt{.{ .Expr = top_call }};
    var content_params = [_]ast.Ident{.{ .name = "padding", .span = dummySpan() }};
    var source_args = [_]Expr{
        .{ .Lambda = .{
            .params = &lambda_params,
            .body = .{ .stmts = &lambda_stmts, .span = dummySpan() },
            .span = dummySpan(),
        } },
        .{ .Lambda = .{
            .params = &content_params,
            .body = .{ .stmts = &.{}, .span = dummySpan() },
            .span = dummySpan(),
        } },
    };
    const source_names = [_]?[]const u8{ "topBar", null };
    var selected = try selectedCallArgsForBuilder(
        &b,
        scaffold_id,
        &source_args,
        &source_names,
        dummySpan(),
        true,
    );
    defer selected.deinit(a);

    try testing.expectEqual(@as(usize, 4), selected.args.len);
    try testing.expect(selected.args[0] == .Call);
    try testing.expectEqual(@as(usize, 5), selected.args[0].Call.args.len);
    // The memo wrap re-attaches the callee-derived label around the block.
    const wrapped_top_bar_arg = selected.args[0].Call.args[2];
    try testing.expect(wrapped_top_bar_arg == .Labeled);
    const wrapped_top_bar = wrapped_top_bar_arg.Labeled.expr.*;
    try testing.expect(wrapped_top_bar == .Lambda);
    try testing.expectEqual(@as(usize, 2), wrapped_top_bar.Lambda.params.len);
    try testing.expectEqualStrings("$composer", wrapped_top_bar.Lambda.params[0].name);
    try testing.expectEqualStrings("$changed", wrapped_top_bar.Lambda.params[1].name);
    const content_arg = selected.args[1];
    try testing.expect(content_arg == .Call);
    const content_lam = content_arg.Call.args[2].Labeled.expr.*;
    try testing.expectEqual(@as(usize, 3), content_lam.Lambda.params.len);
    try testing.expectEqualStrings("padding", content_lam.Lambda.params[0].name);
    try testing.expectEqualStrings("$composer", content_lam.Lambda.params[1].name);
    try testing.expectEqualStrings("$changed", content_lam.Lambda.params[2].name);
}

test "member-or-global emission binds a composable trailing lambda by parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const surface_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = surface_id,
        .name = "Surface",
        .fqn = "androidx.compose.material3.Surface",
        .params = try a.dupe(ir.Param, &.{
            .{ .name = "modifier", .ty = .{ .name = "Modifier", .nullable = false, .args = &.{} }, .default = null },
            .{ .name = "content", .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .default = null },
            .{ .name = "$composer", .ty = .{ .name = "Composer", .nullable = false, .args = &.{} }, .default = null },
            .{ .name = "$changed", .ty = build.typeInt(), .default = null },
        }),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    try m.func_index.append(a, .{ .name = "Surface", .id = surface_id });
    try m.rebuildFuncNameIndex(a);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    try b.bind("$composer", b.allocReg());

    var callee_segments = [_]ast.Ident{.{ .name = "Surface", .span = dummySpan() }};
    var callee = Expr{ .Path = .{ .segments = &callee_segments, .span = dummySpan() } };
    var lambda_params: [0]ast.Ident = .{};
    var args = [_]Expr{.{ .Lambda = .{
        .params = &lambda_params,
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } }};
    var names = [_]?[]const u8{null};
    const call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = dummySpan(),
    } };
    const result = try emitMemberOrGlobal(&b, &call, surface_id, false);
    b.terminate(.{ .Return = result });
    const lowered = try b.finish("caller", "sample.caller", build.typeUnit());

    var found = false;
    for (lowered.blocks[0].insts) |inst| switch (inst) {
        .CallMemberOrGlobal => |cmg| {
            try testing.expectEqual(@as(usize, 3), cmg.arg_names.len);
            const content = m.consts.items[cmg.arg_names[0].?.int()];
            const composer = m.consts.items[cmg.arg_names[1].?.int()];
            const changed = m.consts.items[cmg.arg_names[2].?.int()];
            try testing.expectEqualStrings("content", content.String);
            try testing.expectEqualStrings("$composer", composer.String);
            try testing.expectEqualStrings("$changed", changed.String);
            try testing.expect(!cmg.trailing_lambda);
            found = true;
        },
        else => {},
    };
    try testing.expect(found);
}

test "trailing lambda names only a fixed parameter after a vararg" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();

    var final_vararg_params = [_]ir.Param{
        .{ .name = "item", .ty = build.typeInt(), .default = null },
        .{
            .name = "selectors",
            .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
            .default = null,
            .is_vararg = true,
        },
    };
    const final_vararg = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = final_vararg,
        .name = "inspect",
        .fqn = "app.inspect",
        .params = &final_vararg_params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });

    var fixed_tail_params = [_]ir.Param{
        .{
            .name = "keys",
            .ty = build.typeInt(),
            .default = null,
            .is_vararg = true,
        },
        .{
            .name = "block",
            .ty = .{ .name = "Function0", .nullable = false, .args = &.{} },
            .default = null,
        },
    };
    const fixed_tail = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = fixed_tail,
        .name = "remember",
        .fqn = "app.remember",
        .params = &fixed_tail_params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });

    var lambda_params = [_]ast.Ident{.{ .name = "it", .span = dummySpan() }};
    const lambda = Expr{ .Lambda = .{
        .params = &lambda_params,
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const final_args = [_]Expr{
        .{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } },
        lambda,
        lambda,
    };
    const final_names = [_]?[]const u8{ null, null, null };
    const positional = try trailingLambdaArgNames(
        &b,
        final_vararg,
        &final_args,
        &final_names,
    );
    try testing.expectEqual(@as(usize, 0), positional.len);

    var no_lambda_params: [0]ast.Ident = .{};
    const fixed_args = [_]Expr{
        .{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } },
        .{ .Lambda = .{
            .params = &no_lambda_params,
            .body = .{ .stmts = &.{}, .span = dummySpan() },
            .span = dummySpan(),
        } },
    };
    const fixed_names = [_]?[]const u8{ null, null };
    const tagged = try trailingLambdaArgNames(
        &b,
        fixed_tail,
        &fixed_args,
        &fixed_names,
    );
    defer a.free(tagged);
    try testing.expectEqual(@as(usize, 2), tagged.len);
    try testing.expect(tagged[0] == null);
    try testing.expect(tagged[1] != null);
}

test "lambda lowering records unknown, plain, and receiver callable shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const sp = dummySpan();
    const unit_ty = ast.TypeRef{
        .name = .{ .name = "Unit", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const string_ty = ast.TypeRef{
        .name = .{ .name = "String", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    var plain_fn = ast.FunctionTypeRef{
        .receiver = null,
        .params = &.{},
        .ret = unit_ty,
        .is_suspend = false,
        .span = sp,
    };
    var receiver_fn = ast.FunctionTypeRef{
        .receiver = string_ty,
        .params = &.{},
        .ret = unit_ty,
        .is_suspend = false,
        .span = sp,
    };
    const plain_ty = ast.TypeRef{
        .name = .{ .name = "<function>", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = &plain_fn,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const receiver_ty = ast.TypeRef{
        .name = .{ .name = "<function>", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = &receiver_fn,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const lambda = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = sp },
        .span = sp,
    } };

    _ = try lowerExpr(&b, &lambda);
    const unknown = &m.funcs.items[m.funcs.items.len - 1];
    try testing.expect(!unknown.lambda_receiver_shape_known);
    try testing.expect(!unknown.lambda_has_receiver);

    var prev = b.pushExpected(plain_ty);
    _ = try lowerExpr(&b, &lambda);
    b.restoreExpected(prev);
    const plain = &m.funcs.items[m.funcs.items.len - 1];
    try testing.expect(plain.lambda_receiver_shape_known);
    try testing.expect(!plain.lambda_has_receiver);

    prev = b.pushExpected(receiver_ty);
    _ = try lowerExpr(&b, &lambda);
    b.restoreExpected(prev);
    const receiver = &m.funcs.items[m.funcs.items.len - 1];
    try testing.expect(receiver.lambda_receiver_shape_known);
    try testing.expect(receiver.lambda_has_receiver);
}

test "receiver lambda substitutes a direct call type parameter" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();

    const fid = FuncId.from(42);
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(fid, type_params);

    var receiver_fn_args = [_]ir.TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        build.typeUnit(),
    };
    var params = [_]ir.Param{
        .{ .name = "receiver", .ty = .{ .name = "T", .nullable = false, .args = &.{} }, .default = null },
        .{
            .name = "block",
            .ty = .{ .name = "Function0", .nullable = false, .args = &receiver_fn_args },
            .default = null,
        },
    };
    const func = Func{
        .id = fid,
        .name = "with",
        .fqn = "kotlin.with",
        .params = &params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = BlockId.from(0),
        .is_suspend = false,
        .low_priority = false,
    };

    const owner_reg = b.allocReg();
    try b.bind("owner", owner_reg);
    const sp = dummySpan();
    _ = try m.reserveClassFqn(a, "ShadowOwner", "sample.ShadowOwner", "sample", false);
    var ctor_path = [_]ast.Ident{.{ .name = "ShadowOwner", .span = sp }};
    var ctor_callee = Expr{ .Path = .{ .segments = &ctor_path, .span = sp } };
    const ctor_init = Expr{ .Call = .{
        .callee = &ctor_callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    try b.setLocalInitExpr("owner", &ctor_init);
    var owner_path = [_]ast.Ident{.{ .name = "owner", .span = sp }};
    const owner_arg = Expr{ .Path = .{ .segments = &owner_path, .span = sp } };
    const lambda = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = sp },
        .span = sp,
    } };
    const args = [_]Expr{ owner_arg, lambda };

    try recordLambdaArgReceivers(&b, &func, &args, &.{}, &.{}, 0);
    try testing.expectEqualStrings("sample.ShadowOwner", b.lambdaArgRecv(sp).?.name);

    var unknown_path = [_]ast.Ident{.{ .name = "unknown", .span = sp }};
    const unknown_arg = Expr{ .Path = .{ .segments = &unknown_path, .span = sp } };
    const unproven_args = [_]Expr{ unknown_arg, lambda };
    try recordLambdaArgReceivers(&b, &func, &unproven_args, &.{}, &.{}, 0);
    try testing.expectEqualStrings("sample.ShadowOwner", b.lambdaArgRecv(sp).?.name);

    const explicit_any = ast.TypeRef{
        .name = .{ .name = "Any", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    try recordLambdaArgReceivers(&b, &func, &args, &.{}, &.{explicit_any}, 0);
    try testing.expectEqualStrings("Any", b.lambdaArgRecv(sp).?.name);

    var extension_params = [_]ir.Param{
        .{ .name = "this", .ty = .{ .name = "T", .nullable = false, .args = &.{} }, .default = null },
        .{
            .name = "block",
            .ty = .{ .name = "Function0", .nullable = false, .args = &receiver_fn_args },
            .default = null,
        },
    };
    var extension = func;
    extension.name = "apply";
    extension.fqn = "kotlin.apply";
    extension.params = &extension_params;
    try recordLambdaArgReceiversForCallReceiver(
        &b,
        &extension,
        &.{lambda},
        &.{},
        &.{},
        .{ .name = "LongArray", .nullable = false, .args = &.{} },
        1,
    );
    try testing.expectEqualStrings("LongArray", b.lambdaArgRecv(sp).?.name);
}

test "local extension receiver applicability rejects nullable Nothing" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();

    try b.markLocalExtFn("contentEquals", 1);
    try b.addLocalFnOverload("contentEquals", .{
        .mangled = "contentEquals$ovl0",
        .receiver_ty = try (ir.TypeRef{
            .name = "String",
            .nullable = false,
            .args = &.{},
        }).clone(a),
        .param_tys = try a.alloc(?[]const u8, 0),
        .param_names = try a.alloc([]const u8, 0),
        .n_required = 0,
        .has_vararg = false,
        .is_ext = true,
    });

    try testing.expect(!(try localExtensionReceiverCouldApply(&b, "contentEquals", .{
        .name = "Nothing",
        .nullable = true,
        .args = &.{},
    })));
    try testing.expect(try localExtensionReceiverCouldApply(&b, "contentEquals", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }));
    try testing.expect(try localExtensionReceiverCouldApply(&b, "contentEquals", null));
}

test "argument maps repeat a vararg slot before a trailing lambda" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();

    const params = [_]ir.Param{
        .{ .name = "head", .ty = build.typeInt(), .default = null },
        .{ .name = "values", .ty = build.typeInt(), .default = null, .is_vararg = true },
        .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .default = null },
    };
    var lambda_params: [0]ast.Ident = .{};
    const args = [_]Expr{
        .{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } },
        .{ .IntLit = .{ .value = 2, .kind = .Int, .span = dummySpan() } },
        .{ .IntLit = .{ .value = 3, .kind = .Int, .span = dummySpan() } },
        .{ .Lambda = .{ .params = &lambda_params, .body = .{ .stmts = &.{}, .span = dummySpan() }, .span = dummySpan() } },
    };
    const mapped = (try mapArgsToParams(&b, &params, &args, &.{})).?;
    defer testing.allocator.free(mapped);
    try testing.expectEqualSlices(?usize, &.{ 0, 1, 1, 2 }, mapped);
}

test "lowers null literal" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const e = Expr{ .NullLit = .{ .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].insts[0] == .Const);
}

test "lowers unary negation" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var lit = Expr{ .IntLit = .{ .value = 5, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .Unary = .{ .op = .Neg, .expr = &lit, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].insts[1] == .UnOp);
    try testing.expectEqual(UnOp.Neg, func.blocks[0].insts[1].UnOp.op);
}

test "unbound path in a plain body is a static global read" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var seg = [_]ast.Ident{.{ .name = "println", .span = dummySpan() }};
    const e = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    // No receiver context, so nothing can shadow the global.
    try testing.expect(func.blocks[0].insts[0] == .LoadGlobal);
}

test "unbound path in a lambda body resolves member-vs-global at runtime" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOuterNames(StringSet.init(testing.allocator));
    var seg = [_]ast.Ident{.{ .name = "println", .span = dummySpan() }};
    const e = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    // The lambda's bound receiver is unknowable statically, so the Or form keeps
    // the runtime member arm.
    try testing.expect(func.blocks[0].insts[0] == .LoadFromThisOrGlobal);
}

test "calling an object loads its exact singleton for operator invoke" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    const cid = try m.reserveClassFqn(a, "Callable", "sample.Callable", "sample", false);
    m.classes.items[cid.int()].is_object = true;
    try m.registry.file_packages.put(dummySpan().file, "sample");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var segments = [_]ast.Ident{.{ .name = "Callable", .span = dummySpan() }};
    var callee = Expr{ .Path = .{ .segments = &segments, .span = dummySpan() } };
    var args = [_]Expr{.{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } }};
    const call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &call);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "sample.f", build.typeInt());
    defer freeFunc(func);

    try testing.expect(func.blocks[0].insts[0] == .LoadGlobal);
    try testing.expectEqual(cid, func.blocks[0].insts[0].LoadGlobal.class.?);
    try testing.expect(func.blocks[0].insts[func.blocks[0].insts.len - 1] == .CallValue);
    for (func.blocks[0].insts) |inst| try testing.expect(inst != .NewInstance);
}

test "fun interface classifier lowers to a static SAM instance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const cid = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Action",
        .fqn = "sample.Action",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
        .is_fun_interface = true,
    });
    try m.registry.file_packages.put(dummySpan().file, "sample");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var segments = [_]ast.Ident{.{ .name = "Action", .span = dummySpan() }};
    var callee = Expr{ .Path = .{ .segments = &segments, .span = dummySpan() } };
    var args = [_]Expr{.{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } }};
    const call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &call);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "sample.f", build.typeUnit());

    var saw_sam = false;
    for (func.blocks[0].insts) |inst| switch (inst) {
        .NewInstance => |ni| {
            try testing.expectEqual(cid, ni.class);
            saw_sam = true;
        },
        .CallMemberOrGlobal => return error.TestUnexpectedResult,
        else => {},
    };
    try testing.expect(saw_sam);
}

test "renamed overloaded import binds exact extension and plain identities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();

    const Add = struct {
        fn func(
            module: *Module,
            alloc: Allocator,
            params: []ir.Param,
            kind: ir.FuncKind,
            is_inline: bool,
            arity: Module.DeclArity,
        ) !FuncId {
            const id = module.nextFuncId();
            try module.funcs.append(alloc, .{
                .id = id,
                .name = "combine",
                .fqn = "sample.combine",
                .package = "sample",
                .params = params,
                .return_ty = .{ .name = "Flow", .nullable = false, .args = &.{} },
                .n_locals = 0,
                .blocks = &.{},
                .entry = ir.BlockId.from(0),
                .is_suspend = false,
                .kind = kind,
                .has_receiver_param = kind == .top_level_extension,
                .is_inline = is_inline,
            });
            try module.func_index.append(alloc, .{ .name = "combine", .id = id });
            try module.decl_user_arity.put(id.int(), arity);
            const off: usize = if (kind == .top_level_extension) 1 else 0;
            const sig = try alloc.alloc(ir.TypeRef, params.len - off);
            for (params[off..], sig) |p, *ty| ty.* = p.ty;
            try module.decl_sigs.put(id.int(), .{
                .receiver_ty = if (off == 1) params[0].ty else null,
                .arity = arity,
                .sig = sig,
                .kind = kind,
                .is_inline = is_inline,
                .has_body = true,
            });
            return id;
        }
    };

    const ext_params = try a.alloc(ir.Param, 3);
    ext_params[0] = .{ .name = "this", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    ext_params[1] = .{ .name = "other", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    ext_params[2] = .{ .name = "transform", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    const ext_id = try Add.func(&m, a, ext_params, .top_level_extension, false, .{
        .required = 2,
        .total = 2,
        .has_vararg = false,
    });

    const plain_params = try a.alloc(ir.Param, 3);
    plain_params[0] = .{ .name = "flow", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    plain_params[1] = .{ .name = "other", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    plain_params[2] = .{ .name = "transform", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    const plain_id = try Add.func(&m, a, plain_params, .plain, false, .{
        .required = 3,
        .total = 3,
        .has_vararg = false,
    });

    const inline_params = try a.alloc(ir.Param, 4);
    inline_params[0] = .{ .name = "first", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    inline_params[1] = .{ .name = "second", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    inline_params[2] = .{ .name = "third", .ty = .{ .name = "String", .nullable = false, .args = &.{} }, .default = null };
    inline_params[3] = .{ .name = "transform", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null };
    const inline_id = try Add.func(&m, a, inline_params, .plain, true, .{
        .required = 4,
        .total = 4,
        .has_vararg = false,
    });
    try m.rebuildFuncNameIndex(a);

    var paths: std.ArrayList(ir.ModuleRegistry.ImportPath) = .empty;
    const import_segs = try a.dupe([]const u8, &.{ "sample", "combine" });
    try paths.append(a, .{ .fqn = try a.dupe(u8, "sample.combine"), .segs = import_segs });
    var imports = std.StringHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(a);
    try imports.put("combineOriginal", paths);
    try m.registry.import_aliases.put(sp.file, imports);

    _ = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "String",
        .fqn = "kotlin.String",
        .package = "kotlin",
        .type_params = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const string_names = std.StringHashMap(void).init(a);
    try m.registry.hierarchy_shadow_names.put("String", .{
        .names = string_names,
        .complete = true,
    });
    _ = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Int",
        .fqn = "kotlin.Int",
        .package = "kotlin",
        .type_params = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setRecvTy("String");
    try b.bind("this", b.allocReg());
    try b.bind("first", b.allocReg());
    try b.bind("other", b.allocReg());
    try b.bind("transform", b.allocReg());
    try b.bind("arrayTransform", b.allocReg());
    try b.setLocalDeclType("first", "String");
    try b.setLocalDeclType("other", "String");
    try b.setLocalDeclType("transform", "String");
    try b.setLocalDeclType("arrayTransform", "Int");

    var callee_segs = [_]ast.Ident{.{ .name = "combineOriginal", .span = sp }};
    var callee = Expr{ .Path = .{ .segments = &callee_segs, .span = sp } };
    var other_segs = [_]ast.Ident{.{ .name = "other", .span = sp }};
    var transform_segs = [_]ast.Ident{.{ .name = "transform", .span = sp }};
    var ext_args = [_]Expr{
        .{ .Path = .{ .segments = &other_segs, .span = sp } },
        .{ .Path = .{ .segments = &transform_segs, .span = sp } },
    };
    const ext_call = Expr{ .Call = .{
        .callee = &callee,
        .args = &ext_args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    const ext_shapes = try buildArgShapes(&b, &ext_args, &.{});
    defer a.free(ext_shapes);
    const ext_resolution = m.resolveExtensionCall(
        callee_segs[0].name,
        .{ .name = "String", .nullable = false, .args = &.{} },
        ext_shapes,
        .{
            .caller_file = sp.file,
            .caller_package = b.self_package,
            .call_name = callee_segs[0].name,
        },
    );
    try testing.expectEqual(ext_id, ext_resolution.target.?);
    _ = try lowerExpr(&b, &ext_call);
    const ext_insts = b.blocks.items[b.cur.int()].insts;
    const ext_inst = ext_insts[ext_insts.len - 1];
    try testing.expect(ext_inst == .Call);
    try testing.expectEqual(ext_id, ext_inst.Call.func);
    try testing.expect(ext_inst.Call.exact);

    var first_segs = [_]ast.Ident{.{ .name = "first", .span = sp }};
    var plain_args = [_]Expr{
        .{ .Path = .{ .segments = &first_segs, .span = sp } },
        .{ .Path = .{ .segments = &other_segs, .span = sp } },
        .{ .Path = .{ .segments = &transform_segs, .span = sp } },
    };
    const plain_call = Expr{ .Call = .{
        .callee = &callee,
        .args = &plain_args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    _ = try lowerExpr(&b, &plain_call);
    const plain_insts = b.blocks.items[b.cur.int()].insts;
    const plain_inst = plain_insts[plain_insts.len - 1];
    try testing.expect(plain_inst == .Call);
    try testing.expectEqual(plain_id, plain_inst.Call.func);
    try testing.expect(plain_inst.Call.exact);

    var array_transform_segs = [_]ast.Ident{.{ .name = "arrayTransform", .span = sp }};
    var inline_args = [_]Expr{
        .{ .Path = .{ .segments = &first_segs, .span = sp } },
        .{ .Path = .{ .segments = &other_segs, .span = sp } },
        .{ .Path = .{ .segments = &other_segs, .span = sp } },
        .{ .Path = .{ .segments = &array_transform_segs, .span = sp } },
    };
    const inline_shapes = try buildArgShapes(&b, &inline_args, &.{});
    defer a.free(inline_shapes);
    const inline_res = try m.resolveCall(
        a,
        callee_segs[0].name,
        b.self_package,
        callee_segs[0].span.file,
        inline_shapes,
        false,
        resolveCtxFor(&b, callee_segs[0].name, &.{}, null, &.{}),
    );
    defer a.free(inline_res.candidate_set);
    try testing.expectEqual(inline_id, inline_res.target.?);
    try testing.expect(inline_res.target_final);

    const string_ref = ir.TypeRef{
        .name = "String",
        .nullable = false,
        .args = &.{},
    };
    const plain_ref_types = [_]ir.TypeRef{
        string_ref,
        string_ref,
        string_ref,
    };
    b.pending_ref_lambda_param_types = &plain_ref_types;
    const plain_ref = Expr{ .PropertyRef = .{
        .name = .{ .name = "combineOriginal", .span = sp },
        .span = sp,
    } };
    _ = try lowerExpr(&b, &plain_ref);
    b.pending_ref_lambda_param_types = null;
    const plain_ref_insts = b.blocks.items[b.cur.int()].insts;
    const plain_ref_inst = plain_ref_insts[plain_ref_insts.len - 1];
    try testing.expect(plain_ref_inst == .LoadGlobal);
    try testing.expectEqual(plain_id, plain_ref_inst.LoadGlobal.func.?);

    var string_type_segs = [_]ast.Ident{.{ .name = "String", .span = sp }};
    var string_type = Expr{ .Path = .{ .segments = &string_type_segs, .span = sp } };
    b.pending_ref_lambda_param_types = &plain_ref_types;
    const unbound_ref = Expr{ .MemberRef = .{
        .receiver = &string_type,
        .name = .{ .name = "combineOriginal", .span = sp },
        .span = sp,
    } };
    _ = try lowerExpr(&b, &unbound_ref);
    b.pending_ref_lambda_param_types = null;
    const unbound_insts = b.blocks.items[b.cur.int()].insts;
    const unbound_inst = unbound_insts[unbound_insts.len - 1];
    try testing.expect(unbound_inst == .MemberRef);
    try testing.expectEqual(ext_id, unbound_inst.MemberRef.func.?);

    const bound_ref_types = [_]ir.TypeRef{ string_ref, string_ref };
    b.pending_ref_lambda_param_types = &bound_ref_types;
    var first_receiver_segs = [_]ast.Ident{.{ .name = "first", .span = sp }};
    var first_receiver = Expr{ .Path = .{ .segments = &first_receiver_segs, .span = sp } };
    const bound_ref = Expr{ .MemberRef = .{
        .receiver = &first_receiver,
        .name = .{ .name = "combineOriginal", .span = sp },
        .span = sp,
    } };
    _ = try lowerExpr(&b, &bound_ref);
    b.pending_ref_lambda_param_types = null;
    const bound_insts = b.blocks.items[b.cur.int()].insts;
    const bound_inst = bound_insts[bound_insts.len - 1];
    try testing.expect(bound_inst == .MemberRef);
    try testing.expectEqual(ext_id, bound_inst.MemberRef.func.?);
}
