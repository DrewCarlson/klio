//! Expression lowering: the central recursive dispatch every sibling lower file
//! calls back into. Literals, primitive binary and unary operations, paths,
//! member access, calls, when/if/try as expressions, lambdas, and the rest.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const applicability = @import("applicability");
const build = @import("../build.zig");
const compose_pass = @import("compose_pass");

const helpers = @import("helpers.zig");
const literals = @import("literals.zig");
const inline_state = @import("inline_state.zig");
const decl_mod = @import("decl.zig");
const ast_scan = @import("ast_scan.zig");
const inline_call = @import("inline_call.zig");
const lambda_body = @import("lambda_body.zig");
const for_loop = @import("for_loop.zig");
const when_expr = @import("when_expr.zig");
const stmt_mod = @import("stmt.zig");
const static_call_type = @import("static_call_type.zig");

const Allocator = std.mem.Allocator;

const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const AstBlock = ast.Block;
const AstBinOp = ast.BinOp;
const AstUnOp = ast.UnOp;
const BinOp = ir.BinOp;
const Const = ir.Const;
const ConstId = ir.ConstId;
const Inst = ir.Inst;
const Reg = ir.Reg;
const UnOp = ir.UnOp;
const FuncId = ir.FuncId;
const BlockId = ir.BlockId;
const Func = ir.Func;
const Terminator = ir.Terminator;
const SpreadPart = ir.SpreadPart;
const CatchHandler = ir.CatchHandler;
const TypeRef = ir.TypeRef;
const StringSet = std.StringHashMap(void);

const astBinop = helpers.astBinop;
const boxedCellReg = helpers.boxedCellReg;
const calleeLabel = helpers.calleeLabel;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunWithArity = helpers.lowerArgRunWithArity;
const lowerArgRunFull = helpers.lowerArgRunFull;
const internArgNames = helpers.internArgNames;
const internTypeArgs = helpers.internTypeArgs;
const exprSpan = helpers.exprSpan;
const isAnyTypedPath = helpers.isAnyTypedPath;
const isGenericTypedPath = helpers.isGenericTypedPath;

const isBoxedToAnyForm = ast_scan.isBoxedToAnyForm;
const collectDottedFqn = ast_scan.collectDottedFqn;
const collectPathIdents = ast_scan.collectPathIdents;
const collectPathIdentsStmt = ast_scan.collectPathIdentsStmt;

const isPackageHead = literals.isPackageHead;
const isPkgRoot = literals.isPkgRoot;

const isTopLevelProp = inline_state.isTopLevelProp;
const inlineFnAst = inline_state.inlineFnAst;
const inlineFnAstForRecv = inline_state.inlineFnAstForRecv;
const CallShape = inline_state.CallShape;

const isLowerAnonCapture = decl_mod.isLowerAnonCapture;

const argLambdaHasNonlocalReturn = inline_call.argLambdaHasNonlocalReturn;
const spliceInlineLambda = inline_call.spliceInlineLambda;
const tryInlineCallWithTypeArgs = inline_call.tryInlineCallWithTypeArgs;

const lowerLambdaBodyCapturing = lambda_body.lowerLambdaBodyCapturing;
const lowerLambdaBodyCapturingKind = lambda_body.lowerLambdaBodyCapturingKind;
const resolveCapture = lambda_body.resolveCapture;
const EnclosingOwner = lambda_body.EnclosingOwner;

const lowerFor = for_loop.lowerFor;
const lowerForLabeled = for_loop.lowerForLabeled;
const lowerWhen = when_expr.lowerWhen;
const lowerStmt = stmt_mod.lowerStmt;

const staticCallReturnTypeRef = static_call_type.staticCallReturnTypeRef;
const callableRefDeclTypeRef = static_call_type.callableRefDeclTypeRef;
const StaticReturnArgShapes = static_call_type.StaticReturnArgShapes;

// Aliases for names that moved into sibling files, so call sites keep
// resolving through `expr`.

const receiver_mod = @import("expr/receiver.zig");
const resolveThisRegKind = receiver_mod.resolveThisRegKind;
const resolveSuperThisReg = receiver_mod.resolveSuperThisReg;
pub const lowerReceiver = receiver_mod.lowerReceiver;
pub const overloadPickByCast = receiver_mod.overloadPickByCast;
pub const receiverHeadServes = receiver_mod.receiverHeadServes;
pub const overloadPickByLambdaReturn = receiver_mod.overloadPickByLambdaReturn;
pub const overloadPickByLambdaReturnFull = receiver_mod.overloadPickByLambdaReturnFull;

const binary_mod = @import("expr/binary.zig");
pub const isPrimitiveTypeName = binary_mod.isPrimitiveTypeName;
const lowerBinary = binary_mod.lowerBinary;
const writeBackLvalue = binary_mod.writeBackLvalue;

const paths_mod = @import("expr/paths.zig");
pub const scopeTypeRename = paths_mod.scopeTypeRename;
pub const scopeTypeRenameFrom = paths_mod.scopeTypeRenameFrom;
const collectScopeRenames = paths_mod.collectScopeRenames;
const collectScopeClasses = paths_mod.collectScopeClasses;
pub const loweredTypeName = paths_mod.loweredTypeName;
pub const loweredOwnedLocalTypeRef = paths_mod.loweredOwnedLocalTypeRef;
pub const loweredCheckTypeName = paths_mod.loweredCheckTypeName;
pub const filePrivatePropRename = paths_mod.filePrivatePropRename;
const lowerPath = paths_mod.lowerPath;
pub const ImportRewrite = paths_mod.ImportRewrite;
pub const importCompanionRewrite = paths_mod.importCompanionRewrite;
const lowerStringTemplate = paths_mod.lowerStringTemplate;

const member_mod = @import("expr/member.zig");
const lowerMember = member_mod.lowerMember;
pub const staticBareReceiverType = member_mod.staticBareReceiverType;
const superBase = member_mod.superBase;

const control_mod = @import("expr/control.zig");
const leaveTryFramesForJump = control_mod.leaveTryFramesForJump;
const replayFinallysForJump = control_mod.replayFinallysForJump;
const lowerReturn = control_mod.lowerReturn;
const lowerTry = control_mod.lowerTry;
const nullableIncDecCall = control_mod.nullableIncDecCall;
const sideEffectingMemberTarget = control_mod.sideEffectingMemberTarget;
const lowerPostfix = control_mod.lowerPostfix;
const lowerLabeled = control_mod.lowerLabeled;
const emitTowerPopsForJump = control_mod.emitTowerPopsForJump;

const lambda_mod = @import("expr/lambda.zig");
const lowerLambda = lambda_mod.lowerLambda;
const lowerAnonFun = lambda_mod.lowerAnonFun;
const genericRefTarget = lambda_mod.genericRefTarget;
const callableRefArgShapes = lambda_mod.callableRefArgShapes;
const resolveExtensionRefTarget = lambda_mod.resolveExtensionRefTarget;

const compose_mod = @import("expr/compose.zig");

const call_mod = @import("expr/call.zig");
pub const lastArgIsLambda = call_mod.lastArgIsLambda;
const lowerCall = call_mod.lowerCall;

const emit_mod = @import("expr/emit.zig");
pub const bareStaticRecvHead = emit_mod.bareStaticRecvHead;

const call_general_mod = @import("expr/call_general.zig");
pub const recvChainOf = call_general_mod.recvChainOf;
pub const classIsOrExtendsHosted = call_general_mod.classIsOrExtendsHosted;

const inline_target_mod = @import("expr/inline_target.zig");

const local_call_mod = @import("expr/local_call.zig");

const arg_shape_mod = @import("expr/arg_shape.zig");
pub const narrowIsCheckAll = arg_shape_mod.narrowIsCheckAll;
pub const narrowIsCheck = arg_shape_mod.narrowIsCheck;
pub const narrowNullCheckAll = arg_shape_mod.narrowNullCheckAll;
const condNarrowsThisNotNull = arg_shape_mod.condNarrowsThisNotNull;
const argDeclTypeRef = arg_shape_mod.argDeclTypeRef;
pub const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;
pub const objectRefTypeRef = arg_shape_mod.objectRefTypeRef;
const enclosingObjectDeclaring = arg_shape_mod.enclosingObjectDeclaring;
const loadObjectValue = arg_shape_mod.loadObjectValue;

const static_type_mod = @import("expr/static_type.zig");
pub const staticTypeClassId = static_type_mod.staticTypeClassId;
pub const staticDispatchReceiverTypeRef = static_type_mod.staticDispatchReceiverTypeRef;
pub const ctorInitTypeRef = static_type_mod.ctorInitTypeRef;
pub const iterableElementTypeRef = static_type_mod.iterableElementTypeRef;
pub const iterableElementTypeName = static_type_mod.iterableElementTypeName;
pub const TyMemoHit = static_type_mod.TyMemoHit;
pub const staticExprTypeRef = static_type_mod.staticExprTypeRef;
pub const tyMemoCall = static_type_mod.tyMemoCall;
pub const tyMemoCallEnter = static_type_mod.tyMemoCallEnter;
pub const tyMemoCallLeave = static_type_mod.tyMemoCallLeave;
pub const nullaryMemberReturnTypeRef = static_type_mod.nullaryMemberReturnTypeRef;

const type_probe_mod = @import("expr/type_probe.zig");
pub const localInitTypeRefNamed = type_probe_mod.localInitTypeRefNamed;
pub const extensionNullaryReturnTypeRef = type_probe_mod.extensionNullaryReturnTypeRef;
pub const patchStarredCallRecord = type_probe_mod.patchStarredCallRecord;
pub const buildStaticReturnArgShapes = type_probe_mod.buildStaticReturnArgShapes;
pub const enclosingHasMemberNamed = type_probe_mod.enclosingHasMemberNamed;
pub const lateinitMarkerName = type_probe_mod.lateinitMarkerName;

const bare_call_mod = @import("expr/bare_call.zig");
pub const resolveCtxFor = bare_call_mod.resolveCtxFor;
pub const allNull = bare_call_mod.allNull;

const probe_mod = @import("expr/probe.zig");
const recordOutOfScopeRef = probe_mod.recordOutOfScopeRef;
const classFqnOf = probe_mod.classFqnOf;
const inReceiverContext = probe_mod.inReceiverContext;
pub const eagerLambdaRecvHead = probe_mod.eagerLambdaRecvHead;
const fqnOf = probe_mod.fqnOf;
const enclosingDeclaresMember = probe_mod.enclosingDeclaresMember;
pub const typeHead = probe_mod.typeHead;
const userFunctionDeclared = probe_mod.userFunctionDeclared;
pub const bareTypeParamHead = probe_mod.bareTypeParamHead;

const audit_mod = @import("expr/audit.zig");
pub const orEmitAudit = audit_mod.orEmitAudit;
pub const setResolveStrictForTest = audit_mod.setResolveStrictForTest;
pub const resetResolveStrictForTest = audit_mod.resetResolveStrictForTest;
const refAudit = audit_mod.refAudit;
pub const LmReason = audit_mod.LmReason;
pub const NoRecvPath = audit_mod.NoRecvPath;
pub const NoRecvInit = audit_mod.NoRecvInit;
pub const NoRecvCall = audit_mod.NoRecvCall;
pub const DeclineKind = audit_mod.DeclineKind;
pub const PromoBlock = audit_mod.PromoBlock;
pub const lowerLocalInitDump = audit_mod.lowerLocalInitDump;
pub const lowerPromoDump = audit_mod.lowerPromoDump;
pub const NoClassKind = audit_mod.NoClassKind;
pub const lowerNoClassDump = audit_mod.lowerNoClassDump;
pub const lowerDeclineDump = audit_mod.lowerDeclineDump;
pub const lowerNoRecvDump = audit_mod.lowerNoRecvDump;
pub const lowerSitesDump = audit_mod.lowerSitesDump;

const refs_mod = @import("expr/refs.zig");
const localExtRefClosure = refs_mod.localExtRefClosure;
const expectedHeadsConst = refs_mod.expectedHeadsConst;
const isVarargIntrinsicName = refs_mod.isVarargIntrinsicName;
const varargIntrinsicRefClosure = refs_mod.varargIntrinsicRefClosure;
const boundLocalExtRefClosure = refs_mod.boundLocalExtRefClosure;
const isArrayCtorRefName = refs_mod.isArrayCtorRefName;
const arrayCtorRefClosure = refs_mod.arrayCtorRefClosure;
const bareRefExtensionReceiverClass = refs_mod.bareRefExtensionReceiverClass;
const bareRefNamesOnlyExtensions = refs_mod.bareRefNamesOnlyExtensions;
const enclosingClassDeclaringMember = refs_mod.enclosingClassDeclaringMember;
const adaptedRefClosure = refs_mod.adaptedRefClosure;
const reifiedRefClosure = refs_mod.reifiedRefClosure;

const expected_mod = @import("expr/expected.zig");
pub const astTypeRefFromIr = expected_mod.astTypeRefFromIr;
pub const valueClassCtorTypeRef = expected_mod.valueClassCtorTypeRef;
pub const applyExpectedLiteralKinds = expected_mod.applyExpectedLiteralKinds;
pub const applyExpectedLiteralKindsToArgs = expected_mod.applyExpectedLiteralKindsToArgs;

const member_call_mod = @import("expr/member_call.zig");

const block_mod = @import("expr/block.zig");
pub const lowerBlock = block_mod.lowerBlock;
const hoistMutualLocalFns = block_mod.hoistMutualLocalFns;
pub const rsplitLast = block_mod.rsplitLast;
const setToSlice = block_mod.setToSlice;

const tests_shapes_mod = @import("expr/tests_shapes.zig");

const tests_dispatch_mod = @import("expr/tests_dispatch.zig");

/// Deriver-only leniency: a type record can pick among bodyless expect headers
/// whose signatures discriminate; an emission pick never can.
pub threadlocal var lamret_allow_bodyless: bool = false;

/// Lower one expression into the current block, returning the register holding
/// its value. Value-less forms return a synthetic `Unit` register.
pub fn lowerExpr(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    // Arm the implicit label for a call's argument lambdas with the callee's
    // simple name; `lowerArgRun` re-arms it per argument.
    if (expr.* == .Call) {
        b.pending_lambda_label = calleeLabel(expr.Call.callee);
    }
    // Tail position is consumed here and handed on only by the forms that keep
    // it: `if`/`when` arms, an elvis right side, a block's last statement.
    const tail_here = b.tail_pos;
    b.tail_pos = false;
    b.tail_here = tail_here;
    b.call_tail = expr.* == .Call and tail_here;
    switch (expr.*) {
        .IntLit => |lit| {
    // Honour the literal's declared kind (`1L`, `1U`, `1uL`) over its range.
            return switch (lit.kind) {
                .Long => b.emitConst(.{ .Long = lit.value }),
                .UInt => b.emitConst(.{ .UInt = @intCast(lit.value) }),
                .ULong => b.emitConst(.{ .ULong = @bitCast(lit.value) }),
                .Int => blk: {
                    if (lit.value >= std.math.minInt(i32) and lit.value <= std.math.maxInt(i32)) {
                        break :blk b.emitConst(.{ .Int = @intCast(lit.value) });
                    } else {
                        break :blk b.emitConst(.{ .Long = lit.value });
                    }
                },
            };
        },
        .FloatLit => |lit| return switch (lit.kind) {
            .Float => b.emitConst(.{ .Float = @floatCast(lit.value) }),
            .Double => b.emitConst(.{ .Double = lit.value }),
        },
        .BoolLit => |lit| return b.emitConst(.{ .Bool = lit.value }),
        .NullLit => return b.emitConst(.Null),
        .CharLit => |lit| return b.emitConst(.{ .Char = lit.value }),

        .Binary => |bin| return lowerBinary(b, bin),

        .Unary => |u| return lowerUnary(b, u),
        .If => |f| return lowerIf(b, f, tail_here),
        .Block => |block| {
            b.tail_pos = tail_here;
            return lowerBlock(b, &block);
        },
        .Path => return lowerPath(b, expr),
        .StringTemplate => |st| return lowerStringTemplate(b, st.parts),
        .While => |w| return lowerWhile(b, w),
        .Member => return lowerMember(b, expr),
        .Index => |ix| return lowerIndex(b, ix),
        .Call => return lowerCall(b, expr),
        .DoWhile => |w| return lowerDoWhile(b, w),
        .Return => return lowerReturn(b, expr),
        .Throw => |t| {
            const r = try lowerExpr(b, t.value);
            b.terminate(.{ .Throw = r });
            const dead = try b.allocBlock();
            b.switchTo(dead);
            return b.emitConst(.Unit);
        },
        .When => |w| return lowerWhenExpr(b, w, expr, tail_here),
        .Try => return lowerTry(b, expr),
        .Lambda => return lowerLambda(b, expr),
        .Break => |brk| return lowerBreak(b, brk, expr),
        .Continue => |cont| return lowerContinue(b, cont, expr),
        .For => |f| return lowerFor(b, f.vars, f.by_name, f.destructured, f.var_sources, f.iter, f.body),
        .IsCheck => |ck| return lowerIsCheck(b, ck),
        .As => |cast| return lowerAsCast(b, cast),
        .Postfix => return lowerPostfix(b, expr),
        .Labeled => return lowerLabeled(b, expr),
        .PropertyRef => |pr| return lowerPropertyRef(b, pr, expr),
        .MemberRef => |mr| return lowerMemberRefExpr(b, mr),
        .ObjectExpr => return lowerObjectExpr(b, expr),
        .AnonFun => return lowerAnonFun(b, expr),
        .This => |t| return lowerThis(b, t, expr),
        .Super => {
            // `super` bare reads the same instance value as `this`.
            if (try superBase(b, expr.Super)) |base| return base.this_reg;
            if (try resolveSuperThisReg(b)) |this_reg| return this_reg;
            try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
            return b.emitConst(.Unit);
        },
        .Spread => |sp| {
            // A spread outside a call's argument run is a supertype constructor
            // argument lowered as its own thunk: its value is the array itself,
            // which the constructor path adopts as the packed vararg.
            return lowerExpr(b, sp.expr);
        },
    }
}


/// Prefix `!`, `-`, `+`, `++` and `--`. The increment forms need both an
/// Inc/Dec UnOp and a write-back to the lvalue, and evaluate to the new value.
fn lowerUnary(b: *FuncBuilder, u: @FieldType(Expr, "Unary")) Allocator.Error!Reg {
    // `-2147483648` parses as Neg(IntLit(2147483648)), whose operand
    // does not fit in i32, so general lowering would widen it to Long.
    if (u.op == .Neg and u.expr.* == .IntLit) {
        const il = u.expr.IntLit;
        if (il.kind == .Int and il.value == @as(i64, std.math.maxInt(i32)) + 1) {
            return b.emitConst(.{ .Int = std.math.minInt(i32) });
        }
    }
    // Prefix `++`/`--` need both an Inc/Dec UnOp and a write-back to the
    // lvalue, and evaluate to the new value.
    if (u.op == .PreInc or u.op == .PreDec) {
        if (try nullableIncDecCall(b, u.expr, u.op == .PreInc)) |r| {
            try writeBackLvalue(b, u.expr, r);
            return r;
        }
        const uo: UnOp = if (u.op == .PreInc) .Inc else .Dec;
        if (stmt_mod.indexNeedsCaching(u.expr)) {
            try b.pushScope();
            defer b.popScope() catch {};
            const cached = try stmt_mod.cacheIndexTarget(b, &u.expr.Index);
            const cur = try lowerExpr(b, &cached);
            const dst = b.allocReg();
            try b.push(.{ .UnOp = .{ .dst = dst, .op = uo, .operand = cur } });
            try writeBackLvalue(b, &cached, dst);
            // The prefix form's value is a fresh read of the element.
            return try lowerExpr(b, &cached);
        }
        if (sideEffectingMemberTarget(u.expr)) {
            // `++getA().x` evaluates `getA()` once.
            const m = &u.expr.Member;
            const recv = try lowerReceiver(b, m.receiver);
            const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
            const cur = b.allocReg();
            try b.push(.{ .GetField = .{ .dst = cur, .receiver = recv, .field = field } });
            const dst = b.allocReg();
            try b.push(.{ .UnOp = .{ .dst = dst, .op = uo, .operand = cur } });
            try stmt_mod.storeMemberThroughReg(b, m, recv, dst);
            // The prefix form's value is a fresh read of the property.
            const result = b.allocReg();
            try b.push(.{ .GetField = .{ .dst = result, .receiver = recv, .field = field } });
            return result;
        }
        const operand = try lowerExpr(b, u.expr);
        const dst = b.allocReg();
        try b.push(.{ .UnOp = .{ .dst = dst, .op = uo, .operand = operand } });
        try writeBackLvalue(b, u.expr, dst);
        return dst;
    }
    const operand = try lowerExpr(b, u.expr);
    const dst = b.allocReg();
    switch (u.op) {
        .Not => try b.push(.{ .Not = .{ .dst = dst, .src = operand } }),
        .Neg => try b.push(.{ .UnOp = .{ .dst = dst, .op = .Neg, .operand = operand } }),
        .Pos => try b.push(.{ .UnOp = .{ .dst = dst, .op = .Plus, .operand = operand } }),
        .PreInc, .PreDec => unreachable,
    }
    return dst;
}


/// `if` as an expression: a single destination register both arms write into
/// via Move before jumping to the join.
fn lowerIf(b: *FuncBuilder, f: @FieldType(Expr, "If"), tail_here: bool) Allocator.Error!Reg {
    const cond_r = try lowerExpr(b, f.cond);
    const t_block = try b.allocBlock();
    const f_block = try b.allocBlock();
    const join = try b.allocBlock();
    const dst = b.allocReg();
    b.terminate(.{ .Branch = .{ .cond = cond_r, .t = t_block, .f = f_block } });
    // An `if (x is T)` guard smart-casts `x` for the arm, and extension
    // resolution is static; see `narrowIsCheck`.
    b.switchTo(t_block);
    var narrowed: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
    defer narrowed.deinit(b.allocator);
    try narrowIsCheckAll(b, f.cond, &narrowed);
    var not_null: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
    defer not_null.deinit(b.allocator);
    try narrowNullCheckAll(b, f.cond, true, &not_null);
    const this_nn = condNarrowsThisNotNull(f.cond, true);
    const prev_this_narrow = if (this_nn) b.setThisNarrow(b.recvTy()) else null;
    b.tail_pos = tail_here;
    const t_val = try lowerExpr(b, f.then_branch);
    if (this_nn) _ = b.setThisNarrow(prev_this_narrow);
    var nn = not_null.items.len;
    while (nn > 0) : (nn -= 1) b.restoreLocal(not_null.items[nn - 1]);
    var ni = narrowed.items.len;
    while (ni > 0) : (ni -= 1) b.restoreLocal(narrowed.items[ni - 1]);
    try b.push(.{ .Move = .{ .dst = dst, .src = t_val } });
    b.terminate(.{ .Goto = join });
    // Else arm.
    b.switchTo(f_block);
    var else_not_null: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
    defer else_not_null.deinit(b.allocator);
    try narrowNullCheckAll(b, f.cond, false, &else_not_null);
    b.tail_pos = tail_here;
    const f_val = if (f.else_branch) |e| try lowerExpr(b, e) else try b.emitConst(.Unit);
    var en = else_not_null.items.len;
    while (en > 0) : (en -= 1) b.restoreLocal(else_not_null.items[en - 1]);
    try b.push(.{ .Move = .{ .dst = dst, .src = f_val } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return dst;
}


/// `while (cond) body`, whose value is Unit.
fn lowerWhile(b: *FuncBuilder, w: @FieldType(Expr, "While")) Allocator.Error!Reg {
    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });

    b.switchTo(header);
    const c = try lowerExpr(b, w.cond);
    b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });

    b.switchTo(body_blk);
    try b.pushLoop(null, header, exit);
    var w_not_null: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
    defer w_not_null.deinit(b.allocator);
    try narrowNullCheckAll(b, w.cond, true, &w_not_null);
    _ = try lowerExpr(b, w.body);
    var wn = w_not_null.items.len;
    while (wn > 0) : (wn -= 1) b.restoreLocal(w_not_null.items[wn - 1]);
    b.popLoop();
    b.terminate(.{ .Goto = header });

    b.switchTo(exit);
    return b.emitConst(.Unit);
}


/// `r[a, b, ...]` becomes `r.get(a, b, ...)`, resolved against the receiver's
/// static type as kotlinc does, so a runtime subtype's own generic `get<T>`
/// cannot shadow the statically visible member. A head that is not an ancestor
/// of the runtime receiver degrades to the unhinted walk.
fn lowerIndex(b: *FuncBuilder, ix: @FieldType(Expr, "Index")) Allocator.Error!Reg {
    // the unhinted walk.
    const recv = try lowerReceiver(b, ix.receiver);
    const run = try lowerArgRun(b, ix.args);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = "get" });
    const static_recv: ?ConstId = blk: {
        const t = argDeclTypeRef(b, ix.receiver) orelse break :blk null;
        const head = std.mem.trimEnd(u8, t.name, "?");
        if (head.len == 0) break :blk null;
        break :blk try b.module.internConst(b.allocator, .{ .String = head });
    };
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .arg_names = &.{},
        .static_recv = static_recv,
    } });
    return dst;
}


/// `do body while (cond)`. Kotlin scopes the do-body's declarations into the
/// `while` condition, so a block body and the condition lower in one shared
/// scope; `continue` goes to the condition, not the body start.
fn lowerDoWhile(b: *FuncBuilder, w: @FieldType(Expr, "DoWhile")) Allocator.Error!Reg {
    const body_blk = try b.allocBlock();
    // `continue` in a do-while goes to the condition, not the body start.
    const cond_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = body_blk });

    b.switchTo(body_blk);
    try b.pushLoop(null, cond_blk, exit);
    // Kotlin scopes the do-body's declarations into the `while`
    // condition, so a block body and the condition lower in one shared
    // scope.
    if (w.body) |body| {
        if (body.* == .Block) {
            const block = &body.Block;
            try b.pushScope();
            try hoistMutualLocalFns(b, block);
            for (block.stmts) |*stmt| _ = try lowerStmt(b, stmt);
            b.popLoop();
            b.terminate(.{ .Goto = cond_blk });
            b.switchTo(cond_blk);
            const c = try lowerExpr(b, w.cond);
            try b.popScope();
            b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
            b.switchTo(exit);
            return b.emitConst(.Unit);
        }
        _ = try lowerExpr(b, body);
    }
    b.popLoop();
    b.terminate(.{ .Goto = cond_blk });
    b.switchTo(cond_blk);
    const c = try lowerExpr(b, w.cond);
    b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });

    b.switchTo(exit);
    return b.emitConst(.Unit);
}


/// `when` as an expression. `when (val v = subject)` binds `v` so pattern arms
/// can refer to it, and the subject is evaluated exactly once: the bound
/// register doubles as the when's subject, since re-lowering would re-run a
/// side-effecting subject.
fn lowerWhenExpr(b: *FuncBuilder, w: @FieldType(Expr, "When"), expr: *const Expr, tail_here: bool) Allocator.Error!Reg {
    b.tail_arm = tail_here;
    // `when (val v = subject)` binds `v` so pattern arms can refer to it.
    if (w.subject != null and w.subject_binding != null) {
        try b.pushScope();
        const sv = try lowerExpr(b, w.subject.?);
        try b.bind(w.subject_binding.?.name.name, sv);
    // The subject is evaluated exactly once: the bound register doubles
    // as the when's subject, since re-lowering would re-run a
    // side-effecting subject.
        const r = try when_expr.lowerWhenWithSubjectReg(b, w.subject, sv, w.branches, exprSpan(expr));
        try b.popScope();
        return r;
    }
    return lowerWhen(b, w.subject, w.branches, exprSpan(expr));
}


/// `break`, optionally labeled: leave the try frames the jump escapes, replay
/// their finallys, pop the enclosing receiver tower, then goto the loop exit.
fn lowerBreak(b: *FuncBuilder, brk: @FieldType(Expr, "Break"), expr: *const Expr) Allocator.Error!Reg {
    const lbl: ?[]const u8 = if (brk.label) |i| i.name else null;
    if (b.loopFor(lbl)) |frame| {
        const target = frame.break_target;
        try leaveTryFramesForJump(b, frame.finally_base, frame.catch_base);
        try replayFinallysForJump(b, frame.finally_base);
        try emitTowerPopsForJump(b, frame.encl_tower_base);
        b.terminate(.{ .Goto = target });
        const dead = try b.allocBlock();
        b.switchTo(dead);
    } else {
        try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
    }
    return b.emitConst(.Unit);
}


/// `continue`, optionally labeled: the same unwinding as `break`, jumping to
/// the loop's continue target.
fn lowerContinue(b: *FuncBuilder, cont: @FieldType(Expr, "Continue"), expr: *const Expr) Allocator.Error!Reg {
    const lbl: ?[]const u8 = if (cont.label) |i| i.name else null;
    if (b.loopFor(lbl)) |frame| {
        const target = frame.continue_target;
        try leaveTryFramesForJump(b, frame.finally_base, frame.catch_base);
        try replayFinallysForJump(b, frame.finally_base);
        try emitTowerPopsForJump(b, frame.encl_tower_base);
        b.terminate(.{ .Goto = target });
        const dead = try b.allocBlock();
        b.switchTo(dead);
    } else {
        try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
    }
    return b.emitConst(.Unit);
}


/// `x is T` / `x !is T`. A function-type check tests the erased `FunctionN` /
/// `SuspendFunctionN` name with the arity counting a receiver, as kotlinc does,
/// and an enclosing splice's reified parameter is substituted here.
fn lowerIsCheck(b: *FuncBuilder, ck: @FieldType(Expr, "IsCheck")) Allocator.Error!Reg {
    const s = try lowerExpr(b, ck.expr);
    const dst = b.allocReg();
    // A function-type `is` check tests the erased `FunctionN` /
    // `SuspendFunctionN` name, the arity counting a receiver, and a cast
    // to a function type stays erased, both as kotlinc does.
    if (ck.ty.function) |ft| {
        const arity = ft.params.len + @as(usize, @intFromBool(ft.receiver != null));
        const prefix: []const u8 = if (ft.is_suspend) "SuspendFunction" else "Function";
        const fname = std.fmt.allocPrint(b.allocator, "{s}{d}", .{ prefix, arity }) catch ck.ty.name.name;
        try b.push(.{ .InstanceOf = .{ .dst = dst, .src = s, .ty = .{ .name = fname, .nullable = ck.ty.nullable, .args = &.{} } } });
        if (ck.negated) {
            const neg = b.allocReg();
            try b.push(.{ .Not = .{ .dst = neg, .src = dst } });
            return neg;
        }
        return dst;
    }
    // An enclosing splice's reified parameter is substituted here,
    // nullability included; a class value cannot carry the `?`.
    var check_name = loweredCheckTypeName(b, &ck.ty);
    var check_nullable = ck.ty.nullable;
    if (ck.ty.type_args.len == 0) {
        if (b.resolveReifiedTypeName(ck.ty.name.name)) |bound| {
            var head = bound;
            if (std.mem.endsWith(u8, head, "?")) {
                head = head[0 .. head.len - 1];
                check_nullable = true;
            }
            // The bound name carries the full spelling
            // (`BufferedChannel<*>`), while an `is` check is on the
            // head alone.
            if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (head.len != 0) check_name = head;
        }
    }
    try b.push(.{ .InstanceOf = .{
        .dst = dst,
        .src = s,
        .ty = .{ .name = check_name, .nullable = check_nullable, .args = &.{} },
    } });
    if (ck.negated) {
        const neg = b.allocReg();
        try b.push(.{ .Not = .{ .dst = neg, .src = dst } });
        return neg;
    }
    return dst;
}


/// `x as T` / `x as? T`. A cast to a non-reified type parameter is erased:
/// `checkcast` targets the bound and passes any value, null included.
fn lowerAsCast(b: *FuncBuilder, cast: @FieldType(Expr, "As")) Allocator.Error!Reg {
    const s = try lowerExpr(b, cast.expr);
    // `x as (T & Any)`: the definitely-non-null cast of a null throws
    // NullPointerException; the type itself is erased.
    if (cast.ty.definitely_non_null and !cast.safe) {
        const dst = b.allocReg();
        try b.push(.{ .NotNullAssert = .{ .dst = dst, .src = s } });
        return dst;
    }
    // A cast to a non-reified type parameter is erased: `checkcast`
    // targets the bound and passes any value, null included. Returning
    // the value as-is also keeps a type parameter named like a concrete
    // class from being checked against it. A reified parameter the splice
    // bound is a checked cast to the bound type.
    if (cast.ty.type_args.len == 0) {
        if (b.resolveReifiedTypeName(cast.ty.name.name)) |bound| {
            var head = bound;
            var nullable = cast.ty.nullable;
            if (std.mem.endsWith(u8, head, "?")) {
                head = head[0 .. head.len - 1];
                nullable = true;
            }
            if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (head.len != 0) {
                const dst = b.allocReg();
                try b.push(.{ .Cast = .{
                    .dst = dst,
                    .src = s,
                    .ty = .{ .name = head, .nullable = nullable, .args = &.{} },
                    .safe = cast.safe,
                } });
                return dst;
            }
        }
    }
    if (b.isTypeParam(cast.ty.name.name)) return s;
    const dst = b.allocReg();
    try b.push(.{ .Cast = .{
        .dst = dst,
        .src = s,
        .ty = .{ .name = loweredCheckTypeName(b, &cast.ty), .nullable = cast.ty.nullable, .args = &.{} },
        .safe = cast.safe,
    } });
    return dst;
}


/// The `::name` forms that rewrite into another expression rather than binding
/// a reference: a reified-return closure, an array-constructor intrinsic, a
/// vararg intrinsic, and a per-file mangled private top-level function.
fn tryPropertyRefRewrites(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef"), expr: *const Expr) Allocator.Error!?Reg {

    // `::enumEntries` against a declared `() -> Head<E>`: the expected
    // return solves the target's reified type parameter, which a plain fn
    // value cannot carry, so lower a zero-arg closure over the call.
    if (try reifiedRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
    // `::Array` / `::IntArray`: the array constructors are intrinsics
    // with no function value, so the reference forwards to the call.
    if (isArrayCtorRefName(pr.name.name) and b.resolve(pr.name.name) == null and
        !b.knowsOuter(pr.name.name) and b.module.funcsBySimpleName(pr.name.name).len == 0)
    {
        if (try arrayCtorRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
    }
    // `::arrayOf` against `(Array<T>) -> …`: a vararg intrinsic whose
    // slot takes the array itself spreads it.
    if (isVarargIntrinsicName(pr.name.name) and b.resolve(pr.name.name) == null and
        !b.knowsOuter(pr.name.name) and !userFunctionDeclared(b, pr.name.name))
    {
        if (try varargIntrinsicRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
    }
    // `::name` naming a per-file mangled private top-level function
    // references the calling file's mangled name; otherwise the bare name
    // has no declaration and degrades to a member ref on `this`. Locals,
    // captures, and own members still shadow it.
    if (build.filePrivateFuncRename(pr.name.name, pr.name.span.file.int())) |renamed| {
        if (b.resolve(pr.name.name) == null and !b.knowsOuter(pr.name.name) and
            !b.hasOwnMember(pr.name.name))
        {
            var rewritten = expr.*;
            rewritten.PropertyRef.name = .{ .name = renamed, .span = pr.name.span };
            return try lowerExpr(b, &rewritten);
        }
    }
    return null;
}

/// `::localFn` loads the closure the local function lowered to: it is the
/// referenced callable, not an unbound property of a use site. A local
/// extension fn's closure takes its receiver as the leading parameter, but a
/// bare `::ref` to it is receiver-bound, kotlinc binding the enclosing implicit
/// receiver, so it forwards through a synthesized lambda.
fn tryLocalCallableRef(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef"), dst: Reg) Allocator.Error!?Reg {

    if (runtime.envOnce("KLIO_REF_TRACE")) |w| {
        if (std.mem.eql(u8, w, pr.name.name)) std.debug.print("[ref-trace] {s} lef={} recvctx={} resolve={} outer={} arity_tys={} pending={d} expected_fn={}\n", .{ pr.name.name, b.isLocalExtFn(pr.name.name), inReceiverContext(b), b.resolve(pr.name.name) != null, b.knowsOuter(pr.name.name), b.localFnParamTys(pr.name.name) != null, b.pending_lambda_arity, if (b.peekExpected()) |e| e.function != null else false });
    }
    if (b.isLocalExtFn(pr.name.name) and inReceiverContext(b) and
        (b.resolve(pr.name.name) != null or b.knowsOuter(pr.name.name)))
    {
        if (try localExtRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
    }
    if (b.isLocalFn(pr.name.name)) {
        if (b.resolve(pr.name.name)) |reg| {
            try b.push(.{ .Move = .{ .dst = dst, .src = reg } });
            return dst;
        }
    }
    // `::A` naming a local class is its constructor: the declaration
    // bound the class value under the name, and calling one constructs.
    if (build.isLocalClassInScope(pr.name.name)) {
        if (b.resolve(pr.name.name)) |reg| {
            try b.push(.{ .Move = .{ .dst = dst, .src = reg } });
            return dst;
        }
    }
    // `::rec` inside the enclosing local fn's own body loads that fn's
    // closure through its mangled cell, the binding a bare self-call
    // uses, since the plain name is unbound here. Extension locals need a
    // bound receiver and keep the forms below.
    if (b.selfLocalFn()) |slf| {
        if (std.mem.eql(u8, slf.name, pr.name.name) and !b.isLocalExtFn(slf.mangled)) {
            const cell: ?Reg = if (b.resolve(slf.mangled)) |r|
                r
            else if (b.knowsOuter(slf.mangled))
                try resolveCapture(b, slf.mangled)
            else
                null;
            if (cell) |c| {
                try b.push(.{ .CellGet = .{ .dst = dst, .cell = c } });
                return dst;
            }
        }
    }
    return null;
}

/// The innermost implicit receiver declaring `name` as a member outranks every
/// top-level pick. Stdlib alias intrinsics keep their global form, never being
/// declared by a receiver class.
fn tryReceiverMemberRef(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef"), dst: Reg, nm: ConstId) Allocator.Error!?Reg {

    if (!ir.isAliasName(pr.name.name)) receiver_member: {
        const rh = b.recvTy() orelse break :receiver_member;
        const cid = (b.module.uniqueClassIdBySimpleName(rh) orelse
            b.module.classIdByFqn(rh)) orelse break :receiver_member;
        if (!b.module.classHierarchyDeclaresMember(cid, pr.name.name))
            break :receiver_member;
        if (try resolveThisRegKind(b, true, false)) |this_reg| {
            try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = this_reg, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
            return dst;
        }
    }
    if (b.resolve(pr.name.name) == null and !b.knowsOuter(pr.name.name)) {
        if (enclosingObjectDeclaring(b, pr.name.name, pr.name.span.file)) |obj_cid| {
            const obj_r = try loadObjectValue(b, obj_cid);
            try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = obj_r, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
            return dst;
        }
    }
    return null;
}

/// What a bare `::name` denotes: the class it constructs, the function it
/// loads, and whether an enclosing member or a tracked binding shadows both.
const CallableRefPick = struct {
    class_pick: ?ir.ClassId,
    ref_pick: ?FuncId,
    member_shadows_ref: bool,
    is_tracked: bool,
    ref_arity: i32,
};

/// A registered top-level fn loads the function value, a tracked local or
/// top-level prop keeps the unbound PropertyRef, and an untracked own-receiver
/// member binds a MemberRef. A unique index pick is carried as an exact
/// identity, a class first since the runtime gives a class value precedence
/// over a same-named function.
fn resolveCallableRefPick(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef")) Allocator.Error!CallableRefPick {

    const is_tracked = b.resolve(pr.name.name) != null or isTopLevelProp(pr.name.name);
    // A same-named enclosing member shadows the global only when it could
    // be the referenced callable; where the use site expects an arity the
    // member cannot accept, the global wins.
    const ref_arity = b.pending_lambda_arity;
    const member_shadows_ref = enclosingDeclaresMember(b, pr.name.name) and
        (ref_arity < 0 or b.ownMemberApplicable(pr.name.name, @intCast(ref_arity)));
    var class_pick: ?ir.ClassId = b.module.classIdIndexed(pr.name.name, b.self_package, pr.name.span.file);
    var ref_shapes = try callableRefArgShapes(b, ref_arity);
    defer if (ref_shapes) |*shapes| shapes.deinit(b.allocator);
    // A sealed or abstract class constructs nothing through a reference,
    // so under a typed expected function type the same-named function
    // overloads are the target, picked by those types.
    if (class_pick) |cid| typed: {
        if (cid.int() >= b.module.classes.items.len or !b.module.classes.items[cid.int()].is_abstract) break :typed;
        if (b.module.funcsBySimpleName(pr.name.name).len == 0) break :typed;
        const shapes = ref_shapes orelse break :typed;
        var typed_any = false;
        for (shapes.shapes) |sh| {
            if (sh.ty != null) typed_any = true;
        }
        if (typed_any) class_pick = null;
    }
    const ref_pick: ?FuncId = if (class_pick != null)
        null
    else if (ref_shapes) |shapes|
        try b.module.resolveBareRefExpected(
            b.allocator,
            pr.name.name,
            b.self_package,
            pr.name.span.file,
            shapes.shapes,
        )
    else
        b.module.resolveBareRefIndexed(pr.name.name, b.self_package, pr.name.span.file);
    refAudit(b, pr.name.name, ref_pick);
    // A callable reference whose only declaration is in an unimported
    // package is unresolved, as kotlinc rejects it. Record the diagnostic
    // before binding the lenient pick.
    if (class_pick) |cid| {
        _ = try recordOutOfScopeRef(b, pr.name.name, pr.name.span, classFqnOf(b, cid), b.module.classRefTier(pr.name.name, b.self_package, pr.name.span.file));
    } else if (ref_pick) |fid| {
        _ = try recordOutOfScopeRef(b, pr.name.name, pr.name.span, fqnOf(b, fid), b.module.bareRefTier(pr.name.name, b.self_package, pr.name.span.file));
    }
    return .{
        .class_pick = class_pick,
        .ref_pick = ref_pick,
        .member_shadows_ref = member_shadows_ref,
        .is_tracked = is_tracked,
        .ref_arity = ref_arity,
    };
}

/// `::name` in a slot typed entirely in the callee's type parameters denotes
/// the generic overload, since kotlinc substitutes the call-site type argument.
/// Other slots keep the global forms.
fn tryGenericRefTarget(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef"), pick: CallableRefPick, dst: Reg, nm: ConstId) Allocator.Error!?Reg {
    const class_pick = pick.class_pick;
    const ref_pick = pick.ref_pick;
    const member_shadows_ref = pick.member_shadows_ref;
    const ref_arity = pick.ref_arity;

    if (class_pick == null and ref_pick == null and b.pending_ref_fn_generic and
        !member_shadows_ref and ref_arity >= 0)
    {
        if (try genericRefTarget(
            b,
            pr.name.name,
            pr.name.span.file,
            @intCast(ref_arity),
        )) |fid| {
            const fqn_n = if (b.module.funcById(fid)) |f|
                try b.module.internConst(b.allocator, .{ .String = f.fqn })
            else
                nm;
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = fqn_n, .func = fid } });
            return dst;
        }
    }
    return null;
}

/// `::ext` with no receiver, naming only extensions whose receiver an enclosing
/// `this` satisfies, is bound to that receiver.
fn tryBoundExtensionRef(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef"), pick: CallableRefPick, dst: Reg, nm: ConstId) Allocator.Error!?Reg {
    const class_pick = pick.class_pick;
    const member_shadows_ref = pick.member_shadows_ref;
    const is_tracked = pick.is_tracked;

    if (class_pick == null and !member_shadows_ref and !is_tracked) {
        const target_cls = bareRefExtensionReceiverClass(b, pr.name.name);
        if (runtime.envOnce("KLIO_REF_TRACE")) |w| {
            if (std.mem.eql(u8, w, pr.name.name)) {
                const tower = b.collectImplicitReceiverTower(b.allocator, eagerLambdaRecvHead(b)) catch &.{};
                defer b.allocator.free(tower);
                std.debug.print("[ref-ext] {s} target={?s} recvTy={?s} owner={?s} eager={?s} tower={d}:", .{ pr.name.name, target_cls, b.recvTy(), b.ownerClass(), eagerLambdaRecvHead(b), tower.len });
                for (tower) |h| std.debug.print(" {s}", .{h});
                std.debug.print("\n", .{});
            }
        }
        // No receiver type is known here, but a `this` is in scope and
        // every candidate is an extension: bind it and let dispatch check
        // the receiver.
        const target_cls_v = target_cls orelse {
            if (!bareRefNamesOnlyExtensions(b, pr.name.name)) return null;
            const this_reg = (try resolveThisRegKind(b, true, false)) orelse return null;
            try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = this_reg, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
            return dst;
        };
        const this_reg = (try resolveThisRegKind(b, true, false)) orelse return null;
        var recv_reg = this_reg;
        const innermost_lambda_recv = eagerLambdaRecvHead(b);
        const direct = (if (b.recvTy()) |rt| std.mem.eql(u8, rt, target_cls_v) else false) or
            (if (innermost_lambda_recv) |lr| std.mem.eql(u8, lr, target_cls_v) else false) or
            (innermost_lambda_recv == null and b.recvTy() == null and
                (if (b.ownerClass()) |own| std.mem.eql(u8, own, target_cls_v) else false));
        if (!direct) {
            const qnm = try b.module.internConst(b.allocator, .{ .String = target_cls_v });
            const qreg = b.allocReg();
            try b.push(.{ .QualifiedThis = .{ .dst = qreg, .receiver = this_reg, .qualifier = qnm } });
            recv_reg = qreg;
        }
        try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv_reg, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
        return dst;
    }
    return null;
}

/// Emit the reference the pick settled on: a class value, an exact function
/// identity, a bare global, or a member ref bound to the enclosing receiver.
fn emitCallableRef(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef"), pick: CallableRefPick, dst: Reg, nm: ConstId) Allocator.Error!Reg {
    const class_pick = pick.class_pick;
    const ref_pick = pick.ref_pick;
    const member_shadows_ref = pick.member_shadows_ref;
    const is_tracked = pick.is_tracked;

    if (class_pick != null and !member_shadows_ref) {
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .class = class_pick.?, .ctor_ref = true } });
    } else if (ref_pick != null and !member_shadows_ref) {
        const fid = ref_pick.?;
        if (try adaptedRefClosure(b, pr.name.name, pr.name.span, fid)) |r| {
            try b.push(.{ .Move = .{ .dst = dst, .src = r } });
            return dst;
        }
        const n = blk: {
            if (b.module.funcById(fid)) |f| {
                break :blk try b.module.internConst(b.allocator, .{ .String = f.fqn });
            }
            break :blk nm;
        };
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n, .func = fid } });
    } else if ((b.module.funcId(pr.name.name) != null or b.module.classId(pr.name.name) != null) and !member_shadows_ref) {
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
    } else if (ir.isAliasName(pr.name.name) and !member_shadows_ref) {
        // `::minOf` and friends name a stdlib host intrinsic, which a
        // bare `LoadGlobal` resolves to its `.Intrinsic` value; binding
        // it to `this` would emit a member ref that misses. The member
        // test is scoped to the enclosing class's hierarchy, a
        // program-wide name set being poisoned by unrelated namesakes.
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
    } else if (!is_tracked) {
        // Lambda-aware: a receiver lambda's `this` lives in the capture
        // slot the runtime receiver-binding fills, so a bare `::proceed`
        // binds the enclosing receiver, not a KProperty shell.
        if (try resolveThisRegKind(b, true, false)) |this_reg| {
            // Inside a member extension the frame's `this` is the
            // extension receiver, so a `::name` on an owner member routes
            // through the qualified-this walk, which resolves the
            // enclosing owner over the outer and receiver chains.
            var recv_reg = this_reg;
            if (member_shadows_ref) {
                if (b.ownerClass()) |own| {
                    const ext_recv = b.recvTy();
                    if (ext_recv != null and !std.mem.eql(u8, ext_recv.?, own)) {
                        const qnm = try b.module.internConst(b.allocator, .{ .String = own });
                        const qreg = b.allocReg();
                        try b.push(.{ .QualifiedThis = .{ .dst = qreg, .receiver = this_reg, .qualifier = qnm } });
                        recv_reg = qreg;
                    }
                }
            } else if (enclosingClassDeclaringMember(b, pr.name.name)) |decl| {
                // A member of an enclosing class binds that class's
                // instance.
                const own = b.ownerClass() orelse decl;
                if (!std.mem.eql(u8, decl, own)) {
                    const qnm = try b.module.internConst(b.allocator, .{ .String = decl });
                    const qreg = b.allocReg();
                    try b.push(.{ .QualifiedThis = .{ .dst = qreg, .receiver = this_reg, .qualifier = qnm } });
                    recv_reg = qreg;
                }
            }
            try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv_reg, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
        } else {
            try b.push(.{ .PropertyRef = .{ .dst = dst, .name = nm } });
        }
    } else {
        try b.push(.{ .PropertyRef = .{ .dst = dst, .name = nm } });
    }
    return dst;
}

/// `::name`: a callable reference with no written receiver.
fn lowerPropertyRef(b: *FuncBuilder, pr: @FieldType(Expr, "PropertyRef"), expr: *const Expr) Allocator.Error!Reg {
    if (try tryPropertyRefRewrites(b, pr, expr)) |r| return r;
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = pr.name.name });
    if (try tryLocalCallableRef(b, pr, dst)) |r| return r;
    if (try tryReceiverMemberRef(b, pr, dst, nm)) |r| return r;
    const pick = try resolveCallableRefPick(b, pr);
    if (try tryGenericRefTarget(b, pr, pick, dst, nm)) |r| return r;
    if (try tryBoundExtensionRef(b, pr, pick, dst, nm)) |r| return r;
    return emitCallableRef(b, pr, pick, dst, nm);
}


/// `TypeName::class` loads the receiver with constructor-reference semantics,
/// so a class declaring a `companion object` yields the class value; without
/// `ctor_ref` the read resolves to the published companion, per Kotlin's `C`
/// yields `C.Companion` rule. `.class` is the identity on the result, and the
/// object's class for a singleton.
fn tryTypeClassRef(b: *FuncBuilder, mr: @FieldType(Expr, "MemberRef")) Allocator.Error!?Reg {

    if (std.mem.eql(u8, mr.name.name, "class") and
        mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1)
    {
        const rn0 = mr.receiver.Path.segments[0].name;
        if (b.resolve(rn0) == null and !b.knowsOuter(rn0)) {
            // A reified parameter bound by the enclosing splice is its
            // actual: the bound head, never a runtime read of the
            // process-global `T`.
            const reified_head: ?[]const u8 = blk: {
                const bound = b.resolveReifiedTypeName(rn0) orelse break :blk null;
                var h = std.mem.trimEnd(u8, bound, "?");
                if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
                if (h.len == 0) break :blk null;
                break :blk h;
            };
            // A nested class referenced by bare name inside its declaring
            // subtree lives in the class table under its lifted name, and
            // that alias outranks every same-named class elsewhere.
            const rn = reified_head orelse (scopeTypeRename(b, rn0, mr.receiver.Path.segments[0].span.file.int()) orelse rn0);
            // Resolve by the reference's own file and package first: a
            // user declaration colliding with a builtin owns the name at
            // its own site, while the simple-name index answers whichever
            // registered last.
            if (b.module.classIdIndexed(rn, b.self_package, mr.receiver.Path.segments[0].span.file) orelse
                b.module.classId(rn)) |cid|
            {
                const recv = b.allocReg();
                const rnm = try b.module.internConst(b.allocator, .{ .String = rn });
                try b.push(.{ .LoadGlobal = .{ .dst = recv, .name = rnm, .class = cid, .ctor_ref = true } });
                const dst = b.allocReg();
                const cnm = try b.module.internConst(b.allocator, .{ .String = "class" });
                try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv, .name = cnm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
                return dst;
            }
        }
    }
    return null;
}

/// A member naming an in-scope local extension function resolves to that local,
/// not to a member of the type; its closure takes the receiver first, exactly
/// the shape a `Type::ext` ref needs.
fn tryLocalExtensionMemberRef(b: *FuncBuilder, mr: @FieldType(Expr, "MemberRef")) Allocator.Error!?Reg {

    if (!std.mem.eql(u8, mr.name.name, "class") and
        mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1 and
        b.isLocalExtFn(mr.name.name))
    {
        // `value::localExt` is bound: a lambda forwarding its arguments
        // to `value.localExt(...)`.
        const rn = mr.receiver.Path.segments[0].name;
        if (b.resolve(rn) != null or b.knowsOuter(rn)) {
            if (try boundLocalExtRefClosure(b, mr.receiver, mr.name.name, mr.span)) |r| return r;
        }
        if (b.resolve(mr.name.name)) |r| return r;
        if (b.knowsOuter(mr.name.name)) {
            const idx = try b.recordCapture(mr.name.name);
            const dst = b.allocReg();
            try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
            return dst;
        }
    }
    return null;
}

/// An extension whose declared receiver the written one satisfies, bound by the
/// expected function type's argument shapes.
fn tryExtensionMemberRef(b: *FuncBuilder, mr: @FieldType(Expr, "MemberRef")) Allocator.Error!?Reg {

    if (!std.mem.eql(u8, mr.name.name, "class")) {
        var ref_shapes = try callableRefArgShapes(b, b.pending_lambda_arity);
        defer if (ref_shapes) |*shapes| shapes.deinit(b.allocator);
        if (ref_shapes) |*shapes| {
            if (try resolveExtensionRefTarget(
                b,
                mr.receiver,
                mr.name,
                shapes,
            )) |target_id| {
                const target = b.module.funcById(target_id).?;
                const recv = try lowerReceiver(b, mr.receiver);
                const dst = b.allocReg();
                const original_name = try b.module.internConst(
                    b.allocator,
                    .{ .String = target.name },
                );
                try b.push(.{ .MemberRef = .{
                    .dst = dst,
                    .receiver = recv,
                    .name = original_name,
                    .func = target_id,
                } });
                return dst;
            }
        }
    }
    return null;
}

/// `Outer::Nested` naming a class is a constructor reference, so load the class
/// value. A receiver naming a value in scope is the bound form of an inner
/// class's constructor and keeps the receiver.
fn tryNestedClassRef(b: *FuncBuilder, mr: @FieldType(Expr, "MemberRef")) Allocator.Error!?Reg {

    if (!std.mem.eql(u8, mr.name.name, "class") and
        mr.receiver.* == .Path and
        b.module.classId(mr.name.name) != null and
        !(mr.receiver.Path.segments.len == 1 and
            (b.resolve(mr.receiver.Path.segments[0].name) != null or b.knowsOuter(mr.receiver.Path.segments[0].name))))
    {
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = mr.name.name });
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
        return dst;
    }
    return null;
}

/// `X::member` where `X` is a bare type name with no IR classId loads the type
/// reference directly; the implicit-`this` path would emit `this.X(...)` and
/// invoke the constructor instead.
fn tryBareTypeNameMemberRef(b: *FuncBuilder, mr: @FieldType(Expr, "MemberRef")) Allocator.Error!?Reg {

    if (mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1) {
        const rn = mr.receiver.Path.segments[0].name;
        // A scope-renamed name has no bare `class_id` but is a real
        // classifier, so defer to `lowerReceiver`, which applies the
        // rewrite.
        const renamed = scopeTypeRename(b, rn, mr.receiver.Path.segments[0].span.file.int()) != null;
        if (!renamed and b.resolve(rn) == null and !b.knowsOuter(rn) and
            b.module.classId(rn) == null and !b.hasOwnMember(rn) and
            !isTopLevelProp(rn))
        {
            const rr = b.allocReg();
            const rnm = try b.module.internConst(b.allocator, .{ .String = rn });
            try b.push(.{ .LoadGlobal = .{ .dst = rr, .name = rnm } });
            const dst = b.allocReg();
            const cnm = try b.module.internConst(b.allocator, .{ .String = mr.name.name });
            try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = rr, .name = cnm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
            return dst;
        }
    }
    return null;
}

/// `recv::name`: a callable reference with a written receiver.
fn lowerMemberRefExpr(b: *FuncBuilder, mr: @FieldType(Expr, "MemberRef")) Allocator.Error!Reg {
    if (try tryTypeClassRef(b, mr)) |r| return r;
    if (try tryLocalExtensionMemberRef(b, mr)) |r| return r;
    if (try tryExtensionMemberRef(b, mr)) |r| return r;
    if (try tryNestedClassRef(b, mr)) |r| return r;
    if (try tryBareTypeNameMemberRef(b, mr)) |r| return r;

    const recv = try lowerReceiver(b, mr.receiver);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = mr.name.name });
    try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
    return dst;
}


/// Anonymous-object expressions carry rich AST shape, so emit a `BuildObject`
/// whose host synthesises a fresh ClassDef with the snapshotted env on each
/// call.
fn lowerObjectExpr(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    var outer_names = try b.visibleNames();
    defer outer_names.deinit();
    // A receiver lambda binds `this` through the closure's capture slot
    // rather than a scope binding, so `visibleNames` misses it. The
    // enclosing receiver is part of the closed-over env: a supertype ctor
    // arg evaluates against this snapshot before the object exists.
    if (!outer_names.contains("this") and
        (b.resolve("this") != null or b.capturesThisSlot() or b.knowsOuter("this")))
    {
        try outer_names.put("this", {});
    }
    const captured_names = try setToSlice(b.allocator, &outer_names);
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *c| c.* = try resolveCapture(b, n);
    const dst = b.allocReg();
    const ast_box = try b.allocator.create(Expr);
    ast_box.* = expr.*;
    try b.push(.{ .BuildObject = .{
        .dst = dst,
        .ast = runtime.forest.ForestField(Expr).fromPtr(ast_box),
        .captured_names = captured_names,
        .captures = captures,
        .scope_renames = try collectScopeRenames(b, expr.ObjectExpr.span.file.int()),
        .scope_classes = try collectScopeClasses(b, expr),
    } });
    return dst;
}


/// A labeled receiver `this@fn`: resolve or capture the `this@<fn>` slot bound
/// at that function's entry, possibly through nested lambdas, else walk the
/// class and outer chain at runtime.
fn lowerQualifiedThis(b: *FuncBuilder, q: ast.Ident) Allocator.Error!Reg {

    // A labeled receiver `this@fn` for an enclosing function:
    // resolve or capture the `this@<fn>` slot bound at that
    // function's entry, possibly through nested lambdas.
    const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{q.name});
    if (b.resolve(label)) |r| return r;
    if (b.knowsOuter(label)) {
        const dst2 = try b.loadCaptureHoisted(label);
        try b.bind(label, dst2);
        return dst2;
    }
    // The enclosing anon object closed over the labeled receiver, so
    // read the capture; the class-label walk below would resolve to
    // the anon instance. No scope bind: a read inside a conditional
    // branch must not cache its register for other paths.
    if (decl_mod.isLowerAnonCapture(label)) {
        const idx = try b.recordCapture(label);
        const dst2 = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = dst2, .idx = idx } });
        return dst2;
    }
    // Inside a spliced receiver-lambda region, `this@<fn>` naming the
    // enclosing real function is that function's own receiver, while
    // the innermost `this` is the splice subject.
    if (inline_call.rfsEnabled() and
        (b.lambda_splice_resolve != null or b.encl_tower_depth > 0))
    {
        if (build.currentRealFn()) |rf| {
            if (std.mem.eql(u8, rf, q.name)) {
                if (b.resolveOutermost("this")) |own| return own;
            }
        }
    }
    // A class-name label walks at runtime from the nearest `this`
    // over the class and outer chain.
    const this_reg = b.resolve("this") orelse blk: {
        break :blk try b.loadCaptureHoisted("this");
    };
    const nm = try b.module.internConst(b.allocator, .{ .String = q.name });
    const dst = b.allocReg();
    try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm } });
    return dst;
}

/// `this`, bare or labeled.
fn lowerThis(b: *FuncBuilder, t: @FieldType(Expr, "This"), expr: *const Expr) Allocator.Error!Reg {
    if (t.qualifier) |q| return lowerQualifiedThis(b, q);

    // `this` bare resolves to the implicit first param, or the captured
    // `this` slot inside a lambda body. `KLIO_THIS_TRACE=1` prints the
    // splice window, each scope index holding a `this`, and the register.
    if (runtime.envOnce("KLIO_THIS_TRACE") != null) {
        std.debug.print("[this-trace] span={}:{} depth={d}", .{ exprSpan(expr).file, exprSpan(expr).start, b.scopes.items.len });
        if (b.lambda_splice_resolve) |w| std.debug.print(" window=caller<{d} own>={d}", .{ w.caller_depth, w.own_base });
        var k: usize = 0;
        while (k < b.scopes.items.len) : (k += 1) {
            if (b.scopes.items[k].get("this")) |r| std.debug.print(" s{d}=r{d}", .{ k, r.int() });
        }
        std.debug.print(" -> {?}\n", .{b.resolve("this")});
    }
    const this_reg = b.resolve("this") orelse blk: {
        break :blk try b.loadCaptureHoisted("this");
    };
    return this_reg;
}


/// A statically known type for an arbitrary expression: its own declared type,
/// otherwise a constructed class, a resolved call's return type, or the type a
/// local's initializer lends it. Owned by the caller.
/// The second counter bounds on-demand return-derivation nesting.
pub threadlocal var od_depth: u8 = 0;

/// The local whose own initializer is being typed. Its name is not in scope
/// there, so a bare call of that name inside the initializer resolves past it.
/// Saved and restored by `localInitTypeRef`, which nests.
pub var init_self_name: ?[]const u8 = null;


const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("expr/arg_shape.zig"));
    testing.refAllDecls(@import("expr/audit.zig"));
    testing.refAllDecls(@import("expr/bare_call.zig"));
    testing.refAllDecls(@import("expr/binary.zig"));
    testing.refAllDecls(@import("expr/block.zig"));
    testing.refAllDecls(@import("expr/call.zig"));
    testing.refAllDecls(@import("expr/call_general.zig"));
    testing.refAllDecls(@import("expr/compose.zig"));
    testing.refAllDecls(@import("expr/control.zig"));
    testing.refAllDecls(@import("expr/emit.zig"));
    testing.refAllDecls(@import("expr/expected.zig"));
    testing.refAllDecls(@import("expr/inline_target.zig"));
    testing.refAllDecls(@import("expr/lambda.zig"));
    testing.refAllDecls(@import("expr/local_call.zig"));
    testing.refAllDecls(@import("expr/member.zig"));
    testing.refAllDecls(@import("expr/member_call.zig"));
    testing.refAllDecls(@import("expr/paths.zig"));
    testing.refAllDecls(@import("expr/probe.zig"));
    testing.refAllDecls(@import("expr/receiver.zig"));
    testing.refAllDecls(@import("expr/refs.zig"));
    testing.refAllDecls(@import("expr/static_type.zig"));
    testing.refAllDecls(@import("expr/tests_dispatch.zig"));
    testing.refAllDecls(@import("expr/tests_shapes.zig"));
    testing.refAllDecls(@import("expr/type_probe.zig"));
}
