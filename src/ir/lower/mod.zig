//! AST → IR lowering.
//!
//! Lowering entry point + the wiring that lets the per-construct lower
//! files operate as free functions over a shared `FuncBuilder`. Covers
//! literals, binary / unary primitive operations, paths (as parameter /
//! local reads), if-expression, block expressions, and the remaining
//! expression / statement / declaration forms across the sibling files.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");

const Allocator = std.mem.Allocator;

pub const AstBinOp = ast.BinOp;
pub const AstUnOp = ast.UnOp;
pub const AstBlock = ast.Block;
pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;

pub const FuncBuilder = build.FuncBuilder;
pub const BinOp = ir.BinOp;
pub const BlockId = ir.BlockId;
pub const Const = ir.Const;
pub const Func = ir.Func;
pub const FuncId = ir.FuncId;
pub const Inst = ir.Inst;
pub const Reg = ir.Reg;
pub const Terminator = ir.Terminator;
pub const UnOp = ir.UnOp;
pub const Module = ir.Module;
pub const TypeRef = ir.TypeRef;

// Sibling lower files. Each contributes free functions over the shared
// `FuncBuilder` / context established here.
pub const ast_scan = @import("ast_scan.zig");
pub const helpers = @import("helpers.zig");
pub const inline_state = @import("inline_state.zig");
pub const for_loop = @import("for_loop.zig");
pub const inline_call = @import("inline_call.zig");
pub const lambda_body = @import("lambda_body.zig");
pub const literals = @import("literals.zig");
pub const thunks = @import("thunks.zig");
pub const when_expr = @import("when_expr.zig");
pub const decl = @import("decl.zig");
pub const expr = @import("expr.zig");
pub const static_call_type = @import("static_call_type.zig");
pub const stmt = @import("stmt.zig");

// AST-scan helpers (pure AST walks, no FuncBuilder dependency).
pub const collectDottedFqn = ast_scan.collectDottedFqn;
pub const collectPathIdents = ast_scan.collectPathIdents;
pub const collectPathIdentsStmt = ast_scan.collectPathIdentsStmt;
pub const computeBoxedVars = ast_scan.computeBoxedVars;
pub const isBoxedToAnyForm = ast_scan.isBoxedToAnyForm;
pub const namesReferencedInLambdas = ast_scan.namesReferencedInLambdas;
pub const collectVarDecls = ast_scan.collectVarDecls;

// Builder-side helpers.
pub const isAnyTypedPath = helpers.isAnyTypedPath;
pub const lambdaWritesOuterVar = helpers.lambdaWritesOuterVar;
pub const boxedCellReg = helpers.boxedCellReg;
pub const calleeLabel = helpers.calleeLabel;
pub const lowerArgRun = helpers.lowerArgRun;
pub const internArgNames = helpers.internArgNames;
pub const internTypeArgs = helpers.internTypeArgs;
pub const astBinop = helpers.astBinop;
pub const exprSpan = helpers.exprSpan;

// Inline-state registries (thread-local equivalents installed by the
// build driver before body lowering).
pub const setInlineFnAsts = inline_state.setInlineFnAsts;
pub const setTypeAliasTags = inline_state.setTypeAliasTags;
pub const registerInlineFnId = inline_state.registerInlineFnId;
pub const registerExprBodyMember = inline_state.registerExprBodyMember;
pub const exprBodyMemberAst = inline_state.exprBodyMemberAst;
pub const resetInlineMemberOwners = inline_state.resetInlineMemberOwners;
pub const registerInlineMemberOwner = inline_state.registerInlineMemberOwner;
pub const resetMemberPropAsts = inline_state.resetMemberPropAsts;
pub const resetClassSupertypeRefs = inline_state.resetClassSupertypeRefs;
pub const registerClassSupertypeRefs = inline_state.registerClassSupertypeRefs;
pub const classSupertypeRefs = inline_state.classSupertypeRefs;
pub const resetExprBodyMembers = inline_state.resetExprBodyMembers;
pub const registerMemberPropAst = inline_state.registerMemberPropAst;
pub const resetMemberExtPropRecv = inline_state.resetMemberExtPropRecv;
pub const registerMemberExtPropRecv = inline_state.registerMemberExtPropRecv;
pub const memberExtPropRecv = inline_state.memberExtPropRecv;
pub const setDeferredSection = inline_state.setDeferredSection;
pub const ensureInlineBody = inline_state.ensureInlineBody;
pub const setShadowedInlineNames = inline_state.setShadowedInlineNames;
pub const setTopLevelPropNames = inline_state.setTopLevelPropNames;

// Literal lowering surface.
pub const widenNumericLiteral = literals.widenNumericLiteral;

// Thunk lowering surface.
pub const lowerAccessorBlock = thunks.lowerAccessorBlock;
pub const lowerAccessorBlockRet = thunks.lowerAccessorBlockRet;
pub const lowerSetterBlockTyped = thunks.lowerSetterBlockTyped;
pub const lowerSetterExprTyped = thunks.lowerSetterExprTyped;
pub const lowerAccessorExpr = thunks.lowerAccessorExpr;
pub const lowerAccessorExprWithExpected = thunks.lowerAccessorExprWithExpected;
pub const lowerAccessorExprEnclosing = thunks.lowerAccessorExprEnclosing;
pub const lowerPropertyInitExpr = thunks.lowerPropertyInitExpr;
pub const lowerBinaryExprAsThunk = thunks.lowerBinaryExprAsThunk;
pub const lowerBlockAsThunk = thunks.lowerBlockAsThunk;
pub const lowerBlockAsUnaryThunk = thunks.lowerBlockAsUnaryThunk;
pub const lowerEmptyThunk = thunks.lowerEmptyThunk;
pub const staticExprTypeRef = expr.staticExprTypeRef;
pub const lowerExprAsParamThunk = thunks.lowerExprAsParamThunk;
pub const lowerExprAsParamThunkScoped = thunks.lowerExprAsParamThunkScoped;
pub const lowerExprAsParamThunkScopedEnclosing = thunks.lowerExprAsParamThunkScopedEnclosing;
pub const lowerExprAsThunk = thunks.lowerExprAsThunk;
pub const lowerDelegateExprAsThunk = thunks.lowerDelegateExprAsThunk;
pub const lowerExprAsThunkTyped = thunks.lowerExprAsThunkTyped;
pub const lowerInitBlock = thunks.lowerInitBlock;
pub const lowerInitBlockWithParams = thunks.lowerInitBlockWithParams;
pub const lowerUnaryExprAsThunk = thunks.lowerUnaryExprAsThunk;

// when / for lowering surface.
pub const lowerWhen = when_expr.lowerWhen;
pub const lowerFor = for_loop.lowerFor;
pub const lowerForLabeled = for_loop.lowerForLabeled;

// Lambda-body lowering surface.
pub const lowerLambdaBodyCapturing = lambda_body.lowerLambdaBodyCapturing;
pub const lowerLambdaBodyCapturingKind = lambda_body.lowerLambdaBodyCapturingKind;
pub const lowerLambdaBodyCapturingKindWith = lambda_body.lowerLambdaBodyCapturingKindWith;
pub const resolveCapture = lambda_body.resolveCapture;

// Inline-call lowering surface.
pub const argLambdaHasNonlocalReturn = inline_call.argLambdaHasNonlocalReturn;
pub const spliceInlineLambda = inline_call.spliceInlineLambda;
pub const tryInlineCallWithTypeArgs = inline_call.tryInlineCallWithTypeArgs;

// Declaration lowering surface (the build driver's main entry points).
pub const bindParams = decl.bindParams;
pub const lowerClass = decl.lowerClass;
pub const lowerClassWithFile = decl.lowerClassWithFile;
pub const lowerClassWithExtras = decl.lowerClassWithExtras;
pub const lowerClassWithExtrasFqn = decl.lowerClassWithExtrasFqn;
pub const lowerClassWithExtrasFqnPkg = decl.lowerClassWithExtrasFqnPkg;
pub const lowerFunction = decl.lowerFunction;
pub const lowerFunctionWithFile = decl.lowerFunctionWithFile;
pub const lowerFunctionBodyInto = decl.lowerFunctionBodyInto;
pub const lowerMethod = decl.lowerMethod;
pub const lowerMethodWithMemberContext = decl.lowerMethodWithMemberContext;
pub const setLowerAnonCaptures = decl.setLowerAnonCaptures;
pub const takeLowerAnonCaptures = decl.takeLowerAnonCaptures;
pub const resolveAnnotationNames = decl.resolveAnnotationNames;

// Expression / statement lowering surface — the central recursive
// dispatch that every sibling calls back into.
pub const lowerExpr = expr.lowerExpr;
pub const lowerReceiver = expr.lowerReceiver;
pub const lowerBlock = expr.lowerBlock;
pub const lowerStmt = stmt.lowerStmt;

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

fn freeFunc(func: Func) void {
    for (func.blocks) |b| {
        if (b.insts.len != 0) testing.allocator.free(b.insts);
        if (b.catches.len != 0) testing.allocator.free(b.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

test "lowers_int_literal_to_const" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const lit = intLit(7);
    const r = try lowerExpr(&b, &lit);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", build.typeInt());
    defer freeFunc(func);
    try testing.expectEqual(@as(usize, 1), func.blocks[0].insts.len);
    try testing.expect(func.blocks[0].insts[0] == .Const);
}

test "lowers_binary_add" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var lhs = intLit(1);
    var rhs = intLit(2);
    const e = Expr{ .Binary = .{ .op = .Add, .lhs = &lhs, .rhs = &rhs, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", build.typeInt());
    defer freeFunc(func);
    // 2 consts + 1 binop
    try testing.expectEqual(@as(usize, 3), func.blocks[0].insts.len);
    try testing.expect(func.blocks[0].insts[2] == .BinOp);
    try testing.expectEqual(BinOp.Add, func.blocks[0].insts[2].BinOp.op);
}

test "lowers_path_through_scope" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const p = b.allocReg();
    try b.bind("x", p);
    var segs = [_]ast.Ident{.{ .name = "x", .span = dummySpan() }};
    const path = Expr{ .Path = .{ .segments = &segs, .span = dummySpan() } };
    const r = try lowerExpr(&b, &path);
    try testing.expectEqual(p, r);
}
