//! Expression lowering — the central recursive dispatch. Every sibling
//! lower file calls back into `lowerExpr`. Covers literals, binary /
//! unary primitive operations, paths, member access, calls (including
//! the overload-resolution ladder), when / if / try as expressions,
//! lambdas, and the remaining grammar.

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

// Helper re-aliases for the sibling free functions used below.
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

// -------------------------------------------------------------------------
// Sub-module imports and re-exports. Every name below moved out of this
// file; the aliases keep every call site resolving through `expr`.
// -------------------------------------------------------------------------

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

/// Deriver-only leniency: a TYPE record can pick among bodyless expect
/// headers whose signatures discriminate; an emission pick never can.
pub threadlocal var lamret_allow_bodyless: bool = false;

/// Lower one expression into the current block, returning the register
/// holding its value. Value-less forms (assignments, declarations) return a
/// synthetic `Unit` register so downstream code stays uniform.
pub fn lowerExpr(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    // Arm the implicit-label for a call's argument lambdas with the
    // callee's simple name (`with(n) { … }` → "with"). `lowerArgRun`
    // consumes and re-arms it per argument; `Lambda` reads it.
    if (expr.* == .Call) {
        b.pending_lambda_label = calleeLabel(expr.Call.callee);
    }
    // Tail position is consumed here and handed on only by the forms that
    // keep it (`if`/`when` arms, an elvis right side, a block's last
    // statement); every other child lowers outside tail position.
    const tail_here = b.tail_pos;
    b.tail_pos = false;
    b.tail_here = tail_here;
    b.call_tail = expr.* == .Call and tail_here;
    switch (expr.*) {
        .IntLit => |lit| {
            // Honour the literal's declared kind (`1L`, `1U`, `1uL`)
            // rather than letting the value range pick.
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

        .Unary => |u| {
            // `-2147483648` parses as Neg(IntLit(2147483648)); the operand's
            // value doesn't fit in i32 so general IntLit-lowering would widen
            // to Long. Special-case Int.MIN_VALUE so it stays Int.
            if (u.op == .Neg and u.expr.* == .IntLit) {
                const il = u.expr.IntLit;
                if (il.kind == .Int and il.value == @as(i64, std.math.maxInt(i32)) + 1) {
                    return b.emitConst(.{ .Int = std.math.minInt(i32) });
                }
            }
            // Prefix ++ / -- need both an Inc/Dec UnOp AND a write-back to
            // the lvalue; return the NEW value.
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
        },
        .If => |f| {
            // A single destination register both arms write into via Move
            // before jumping to the join.
            const cond_r = try lowerExpr(b, f.cond);
            const t_block = try b.allocBlock();
            const f_block = try b.allocBlock();
            const join = try b.allocBlock();
            const dst = b.allocReg();
            b.terminate(.{ .Branch = .{ .cond = cond_r, .t = t_block, .f = f_block } });
            // Then arm. An `if (x is T)` guard smart-casts `x` to `T` for the
            // arm, and extension resolution is static — see `narrowIsCheck`.
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
        },
        .Block => |block| {
            b.tail_pos = tail_here;
            return lowerBlock(b, &block);
        },
        .Path => return lowerPath(b, expr),
        .StringTemplate => |st| return lowerStringTemplate(b, st.parts),
        .While => |w| {
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
        },
        .Member => return lowerMember(b, expr),
        .Index => |ix| {
            // `r[a, b, ...]` → r.get(a, b, ...). The `get` resolves against
            // the receiver's STATIC type, as kotlinc does: carry the declared
            // head so a runtime subtype's own generic `get<T>` cannot shadow
            // the statically-visible member. `map[local]` on a
            // `PersistentMap<CompositionLocal, ValueHolder>`-typed local must
            // bind the plain map `get` (returning the holder), never
            // `PersistentCompositionLocalHashMap.get<T>` (the composition-
            // local READ, which returns the resolved value). A head that is
            // not an ancestor of the runtime receiver disengages the static
            // scope, so an imprecise head degrades to the unhinted walk.
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
        },
        .Call => return lowerCall(b, expr),
        .DoWhile => |w| {
            const body_blk = try b.allocBlock();
            // `continue` in a do-while goes to the condition, never back to
            // the body's start.
            const cond_blk = try b.allocBlock();
            const exit = try b.allocBlock();
            b.terminate(.{ .Goto = body_blk });

            b.switchTo(body_blk);
            try b.pushLoop(null, cond_blk, exit);
            // Kotlin scopes the do-body's declarations into the `while`
            // condition; when the body is a block, lower its statements and the
            // condition in one shared scope so `do { val x = … } while (x …)`
            // resolves `x` instead of treating it as a stray global.
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
        },
        .Return => return lowerReturn(b, expr),
        .Throw => |t| {
            const r = try lowerExpr(b, t.value);
            b.terminate(.{ .Throw = r });
            const dead = try b.allocBlock();
            b.switchTo(dead);
            return b.emitConst(.Unit);
        },
        .When => |w| {
            b.tail_arm = tail_here;
            // `when (val v = subject) { ... }` binds `v` to the subject's
            // value so pattern arms can refer to it.
            if (w.subject != null and w.subject_binding != null) {
                try b.pushScope();
                const sv = try lowerExpr(b, w.subject.?);
                try b.bind(w.subject_binding.?.name.name, sv);
                // The subject is evaluated exactly once: the bound register
                // doubles as the when's subject (re-lowering would re-run a
                // side-effecting subject like a queue poll).
                const r = try when_expr.lowerWhenWithSubjectReg(b, w.subject, sv, w.branches, exprSpan(expr));
                try b.popScope();
                return r;
            }
            return lowerWhen(b, w.subject, w.branches, exprSpan(expr));
        },
        .Try => return lowerTry(b, expr),
        .Lambda => return lowerLambda(b, expr),
        .Break => |brk| {
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
        },
        .Continue => |cont| {
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
        },
        .For => |f| return lowerFor(b, f.vars, f.by_name, f.destructured, f.var_sources, f.iter, f.body),
        .IsCheck => |ck| {
            const s = try lowerExpr(b, ck.expr);
            const dst = b.allocReg();
            // A function-type `is` check tests the erased `FunctionN` /
            // `SuspendFunctionN` name (the arity counting a receiver), as
            // kotlinc's `instanceof` does. A cast to a function type stays
            // erased (`loweredCheckTypeName`), matching kotlinc's arity-only
            // CHECKCAST that never narrows past the value already being a
            // function.
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
            // NULLABILITY included. Leaving the parameter name for the
            // runtime to resolve through its bound class value loses the
            // `?`: `filterIsInstance<Int?>()` then dropped every null,
            // because a class value cannot carry nullability.
            var check_name = loweredCheckTypeName(b, &ck.ty);
            var check_nullable = ck.ty.nullable;
            if (ck.ty.type_args.len == 0) {
                if (b.resolveReifiedTypeName(ck.ty.name.name)) |bound| {
                    var head = bound;
                    if (std.mem.endsWith(u8, head, "?")) {
                        head = head[0 .. head.len - 1];
                        check_nullable = true;
                    }
                    // The bound name carries the FULL spelling
                    // (`BufferedChannel<*>`); an `is` check is on the head
                    // alone, exactly as the runtime's class-value fallback
                    // was.
                    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
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
        },
        .As => |cast| {
            const s = try lowerExpr(b, cast.expr);
            // `x as (T & Any)`: the definitely-non-null cast of a null throws
            // NullPointerException; the type itself is erased.
            if (cast.ty.definitely_non_null and !cast.safe) {
                const dst = b.allocReg();
                try b.push(.{ .NotNullAssert = .{ .dst = dst, .src = s } });
                return dst;
            }
            // A cast to a NON-reified type parameter (`x as T`) is erased: the
            // JVM `checkcast` targets the bound and passes any value (including
            // null), so it is a runtime no-op — a genuine mismatch surfaces
            // only when the value is later used as `T`. Return the value as-is,
            // so a type parameter named like a concrete class (`class
            // ScopeMap<Key, Scope>` alongside a test's `class Scope`) is not
            // checked against that class and a nullable instantiation does not
            // throw. A REIFIED parameter the enclosing splice bound is a
            // checked cast to the bound type, nullability included.
            if (cast.ty.type_args.len == 0) {
                if (b.resolveReifiedTypeName(cast.ty.name.name)) |bound| {
                    var head = bound;
                    var nullable = cast.ty.nullable;
                    if (std.mem.endsWith(u8, head, "?")) {
                        head = head[0 .. head.len - 1];
                        nullable = true;
                    }
                    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
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
        },
        .Postfix => return lowerPostfix(b, expr),
        .Labeled => return lowerLabeled(b, expr),
        .PropertyRef => |pr| {
            // `::enumEntries` against a declared `() -> Head<E>` function
            // type: the expected return solves the target's single reified
            // type parameter, and the plain fn VALUE cannot carry it —
            // lower the reference as a zero-arg closure over the stamped
            // call instead.
            if (try reifiedRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
            // `::Array` / `::IntArray`: the array constructors are intrinsics
            // with no function value to load; the reference forwards to the
            // constructor call.
            if (isArrayCtorRefName(pr.name.name) and b.resolve(pr.name.name) == null and
                !b.knowsOuter(pr.name.name) and b.module.funcsBySimpleName(pr.name.name).len == 0)
            {
                if (try arrayCtorRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
            }
            // `::arrayOf` against `(Array<T>) -> …`: a vararg intrinsic
            // reference whose slot takes the array itself spreads it.
            if (isVarargIntrinsicName(pr.name.name) and b.resolve(pr.name.name) == null and
                !b.knowsOuter(pr.name.name) and !userFunctionDeclared(b, pr.name.name))
            {
                if (try varargIntrinsicRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
            }
            // `::name` naming a file-private top-level function mangled per
            // file (two files in one package each declaring the same
            // `private fun`) references the calling file's mangled name.
            // Without the rewrite the bare name has no declaration at all
            // and the reference degrades to a member ref on the enclosing
            // `this` — kotlinx's `::createSegment` inside SemaphoreImpl.
            // Locals, outer captures and own members still shadow it, the
            // same scope order the bare CALL rewrite honors.
            if (build.filePrivateFuncRename(pr.name.name, pr.name.span.file.int())) |renamed| {
                if (b.resolve(pr.name.name) == null and !b.knowsOuter(pr.name.name) and
                    !b.hasOwnMember(pr.name.name))
                {
                    var rewritten = expr.*;
                    rewritten.PropertyRef.name = .{ .name = renamed, .span = pr.name.span };
                    return lowerExpr(b, &rewritten);
                }
            }
            // `::greet` — a registered top-level fn loads the function value;
            // a tracked local / top-level prop keeps the unbound PropertyRef;
            // an untracked own-receiver member binds a MemberRef. The symbol
            // index resolves the name from this file's package and imports,
            // and a unique pick is carried as an exact identity — a class
            // first (`::Ctor`; the runtime gives a class value precedence
            // over a same-named function), then a non-extension function —
            // so a same-simple-name declaration from another package cannot
            // swap in at runtime. Deferred shapes (overload sets, extension
            // forms) keep the name-keyed emission.
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = pr.name.name });
            // `::localFn` names a local function, which is lowered to a closure
            // value bound to a register. The reference loads that closure — it
            // is the referenced callable, not an unbound property of whatever
            // the use site later applies it to.
            // A LOCAL EXTENSION fn's closure takes its receiver as the
            // leading parameter, but a bare `::ref` to it is
            // receiver-BOUND — kotlinc binds the enclosing implicit
            // receiver, so `handles.forEach(::validateGroupState)` inside
            // `table.edit { }` invokes with the edit receiver. Forward
            // through a synthesized lambda whose bare call re-resolves the
            // local ext against `this` (capture machinery included); the
            // reference then has the value-parameter arity the use site
            // expects. The mark set is inherited into nested lambda
            // builders, where the closure itself is an outer capture.
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
            // `::A` naming a LOCAL class is its constructor: the declaration
            // bound the class value under the name, and calling a class value
            // constructs it.
            if (build.isLocalClassInScope(pr.name.name)) {
                if (b.resolve(pr.name.name)) |reg| {
                    try b.push(.{ .Move = .{ .dst = dst, .src = reg } });
                    return dst;
                }
            }
            // `::rec` referencing the ENCLOSING local fn from inside its own
            // body (or a lambda nested in it): the plain name is unbound here
            // — and a later same-named sibling would rebind it — so the
            // reference loads the fn's own closure through its mangled cell,
            // the same binding a bare self-call uses. Extension locals need a
            // bound receiver and keep the member/property forms below.
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
            // The innermost implicit receiver declaring `name` as a member
            // outranks every top-level pick: kotlinc binds `::proceed`
            // inside `intercept { handler(context, ::proceed) }` to the
            // pipeline context, not a same-named global. Stdlib alias
            // intrinsics keep their global form (a receiver class does not
            // shadow `::minOf`-style refs it never declares).
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
            const is_tracked = b.resolve(pr.name.name) != null or isTopLevelProp(pr.name.name);
            // A same-named enclosing member only shadows the global for `::name`
            // when it could actually be the referenced callable: if the use
            // site expects a specific arity (a function-typed parameter slot)
            // and the member cannot accept it, the global wins — e.g.
            // `propagateOf2(::minOf, …)` from a `@Test fun minOf()` references
            // the stdlib `minOf`, not the zero-arg test method.
            const ref_arity = b.pending_lambda_arity;
            const member_shadows_ref = enclosingDeclaresMember(b, pr.name.name) and
                (ref_arity < 0 or b.ownMemberApplicable(pr.name.name, @intCast(ref_arity)));
            var class_pick: ?ir.ClassId = b.module.classIdIndexed(pr.name.name, b.self_package, pr.name.span.file);
            var ref_shapes = try callableRefArgShapes(b, ref_arity);
            defer if (ref_shapes) |*shapes| shapes.deinit(b.allocator);
            // A sealed/abstract class constructs nothing through a reference:
            // under a TYPED expected function type, the same-named function
            // overloads are the reference's target, picked by those types
            // (`val g: (String?) -> P = ::P` binds the `String?` overload,
            // which a runtime `null` could never tell from `Number?`).
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
            // A callable reference whose only declaration is in an
            // unimported package is unresolved (kotlinc rejects `::name` /
            // `::Ctor` the same as a bare call to it). Record the
            // diagnostic before binding the lenient pick.
            if (class_pick) |cid| {
                _ = try recordOutOfScopeRef(b, pr.name.name, pr.name.span, classFqnOf(b, cid), b.module.classRefTier(pr.name.name, b.self_package, pr.name.span.file));
            } else if (ref_pick) |fid| {
                _ = try recordOutOfScopeRef(b, pr.name.name, pr.name.span, fqnOf(b, fid), b.module.bareRefTier(pr.name.name, b.self_package, pr.name.span.file));
            }
            // `::name` in a slot whose declared function type is written
            // entirely in the callee's type parameters
            // (`totalOrderMinOf2<Comparable<Any>>(::minOf)` against
            // `f2t: (T, T) -> T`) denotes the GENERIC overload: kotlinc
            // substitutes the call-site type argument, so only the generic
            // candidate is applicable. Bind the reference by id; a numeric
            // or otherwise-typed slot keeps the plain alias/global forms.
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
            // `::ext` with no receiver, naming only EXTENSION functions whose
            // receiver an enclosing `this` satisfies, is bound to that
            // receiver.
            if (class_pick == null and !member_shadows_ref and !is_tracked) ext_ref: {
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
                // No receiver type is known here (a receiver lambda lowered
                // without its expected type), but a `this` is in scope and
                // every candidate is an extension: bind it and let dispatch
                // check the receiver.
                const target_cls_v = target_cls orelse {
                    if (!bareRefNamesOnlyExtensions(b, pr.name.name)) break :ext_ref;
                    const this_reg = (try resolveThisRegKind(b, true, false)) orelse break :ext_ref;
                    try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = this_reg, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
                    return dst;
                };
                const this_reg = (try resolveThisRegKind(b, true, false)) orelse break :ext_ref;
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
                // `::minOf` / `::maxOf` / `::listOf` … name a stdlib host
                // intrinsic. A bare `LoadGlobal` resolves it to its
                // `.Intrinsic` callable value; binding it to the enclosing
                // `this` (the `!is_tracked` branch below) would emit a
                // `this.<name>` member ref that misses at runtime. The member
                // test is scoped to the ENCLOSING class's hierarchy — a
                // program-wide member-name set is poisoned by an unrelated
                // sibling class that happens to declare a `minOf`/`maxOf`
                // `@Test`, which `::minOf` here can never refer to.
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            } else if (!is_tracked) {
                // Lambda-aware: a receiver lambda's `this` lives in the
                // capture slot the runtime receiver-binding fills, so a bare
                // `::proceed` inside `intercept { handler(context, ::proceed) }`
                // binds the pipeline context, not a KProperty shell.
                if (try resolveThisRegKind(b, true, false)) |this_reg| {
                    // Inside a MEMBER EXTENSION the frame's `this` is the
                    // extension receiver; a `::name` referencing an OWNER
                    // member must bind the dispatch receiver instead
                    // (`::requestFocus` inside `SemanticsPropertyReceiver.
                    // applySemantics()` of FocusableNode). Route through
                    // the qualified-this runtime walk, which resolves the
                    // enclosing owner instance over the outer/receiver
                    // chains.
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
                        // A member of an ENCLOSING class (`::outerMember`
                        // inside an inner class) binds that class's instance.
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
        },
        .MemberRef => |mr| {
            // `TypeName::class` on a bare type name: load the receiver with
            // constructor-reference semantics so a class that declares a
            // `companion object` yields the CLASS value, not its companion
            // singleton. Without `ctor_ref` a class-name read resolves to the
            // published companion (Kotlin's `C` ⇒ `C.Companion` value rule),
            // and `.class` then takes the companion's class — so once the
            // companion is constructed, `C::class` degrades to
            // `C$Companion$Companion` and `isInstance` / the name diverge.
            // `.class` is the identity on the resulting class value (and the
            // object's class for an `object` singleton), so it is kept.
            if (std.mem.eql(u8, mr.name.name, "class") and
                mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1)
            {
                const rn0 = mr.receiver.Path.segments[0].name;
                if (b.resolve(rn0) == null and !b.knowsOuter(rn0)) {
                    // A reified parameter bound by the enclosing splice IS
                    // its actual (`T::class` inside a spliced
                    // `assertFailsWith<reified T>`): the bound head, never
                    // a runtime read of the process-global `T`.
                    const reified_head: ?[]const u8 = blk: {
                        const bound = b.resolveReifiedTypeName(rn0) orelse break :blk null;
                        var h = std.mem.trimEnd(u8, bound, "?");
                        if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
                        if (h.len == 0) break :blk null;
                        break :blk h;
                    };
                    // A nested class referenced by bare name inside its
                    // declaring subtree lives in the class table under its
                    // lifted name: that alias outranks every same-named
                    // class elsewhere (`A::class` inside a member extension
                    // of the outer that declares `class A`).
                    const rn = reified_head orelse (scopeTypeRename(b, rn0, mr.receiver.Path.segments[0].span.file.int()) orelse rn0);
                    // Resolve by the reference's own file and package first: a
                    // user declaration whose simple name collides with a
                    // builtin (`object Target` beside `kotlin.annotation
                    // .Target`) owns the name at its own site, and the
                    // simple-name index answers whichever registered last.
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
            // `String::countVowels` where the member names an in-scope
            // LOCAL extension function: kotlinc resolves the reference to
            // that local, not to a member of the type. The local lowered
            // as a closure bound to its name; the closure takes the
            // receiver as its first param, exactly the callable shape a
            // `Type::ext` reference must have.
            if (!std.mem.eql(u8, mr.name.name, "class") and
                mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1 and
                b.isLocalExtFn(mr.name.name))
            {
                // `value::localExt` is BOUND: a lambda forwarding its
                // arguments to `value.localExt(...)`.
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
            // `Outer::Nested` where `Nested` is a class is a constructor
            // reference, not a bound member ref — load the class value. A
            // receiver naming a VALUE in scope (`outer::Inner`) is the bound
            // form of an inner class's constructor and keeps the receiver.
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
            // `X::member` where `X` is a bare type/constructor name that has
            // no IR classId (e.g. an unsigned array `ULongArray`) must load
            // the type reference directly. Routing it through
            // `lowerReceiver` -> the implicit-`this` path inside a method
            // would emit `this.X(...)` and invoke the constructor instead of
            // taking the type value (`UIntArray::copyInto` inside a test
            // class constructed a UIntArray from the ref's first use).
            if (mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1) {
                const rn = mr.receiver.Path.segments[0].name;
                // A scope-renamed name has no bare `class_id` either, but it
                // is a real classifier — a nested `Box` inside its declaring
                // class lifts to `Holder$Box`. Loading the bare name would
                // strand the reference on an unresolved global; defer to
                // `lowerReceiver`, which applies the rewrite.
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
            const recv = try lowerReceiver(b, mr.receiver);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = mr.name.name });
            try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv, .name = nm, .adapt_arity = b.pending_lambda_arity, .adapt_unit = b.pending_ref_lambda_unit, .adapt_heads = try expectedHeadsConst(b) } });
            return dst;
        },
        .ObjectExpr => {
            // Anonymous-object expressions carry rich AST shape; emit a
            // `BuildObject` Inst whose host synthesises a fresh ClassDef
            // with the snapshotted env on each call.
            var outer_names = try b.visibleNames();
            defer outer_names.deinit();
            // A receiver lambda binds `this` through the closure's capture
            // slot rather than a scope binding, so `visibleNames` misses it
            // (a method body binds it as a param and includes it). The
            // enclosing receiver is part of the anon's closed-over env: a
            // supertype ctor arg (`object : Prov(this)`) evaluates against
            // this snapshot before the object exists.
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
        },
        .AnonFun => return lowerAnonFun(b, expr),
        .This => |t| {
            if (t.qualifier) |q| {
                // A labeled receiver `this@fn` for an enclosing (extension)
                // function: resolve / capture the `this@<fn>` slot bound at
                // that function's entry — possibly through nested lambdas — so
                // it is the function's receiver, not the lambda's own `this`.
                const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{q.name});
                if (b.resolve(label)) |r| return r;
                if (b.knowsOuter(label)) {
                    const dst2 = try b.loadCaptureHoisted(label);
                    try b.bind(label, dst2);
                    return dst2;
                }
                // The enclosing ANON OBJECT closed over the labeled
                // receiver (`this@minus` inside an anon method): read the
                // capture. The class-label walk below would resolve to the
                // anon instance itself. No scope bind: a read inside a
                // conditional branch must not cache its register for reads
                // on paths where the branch never ran.
                if (decl_mod.isLowerAnonCapture(label)) {
                    const idx = try b.recordCapture(label);
                    const dst2 = b.allocReg();
                    try b.push(.{ .LoadCapture = .{ .dst = dst2, .idx = idx } });
                    return dst2;
                }
                // Inside a spliced receiver-lambda region, `this@<fn>`
                // naming the enclosing REAL function is that function's
                // OWN receiver — the innermost `this` is the splice
                // subject (`destination.apply { putAll(this@toMap) }`
                // read the destination back and built an empty map). The
                // outermost scope's `this` binding is the function's own.
                if (inline_call.rfsEnabled() and
                    (b.lambda_splice_resolve != null or b.encl_tower_depth > 0))
                {
                    if (build.currentRealFn()) |rf| {
                        if (std.mem.eql(u8, rf, q.name)) {
                            if (b.resolveOutermost("this")) |own| return own;
                        }
                    }
                }
                // Otherwise a class-name label (`this@Outer`): walk at runtime
                // from the nearest `this` over the class/outer chain.
                const this_reg = b.resolve("this") orelse blk: {
                    break :blk try b.loadCaptureHoisted("this");
                };
                const nm = try b.module.internConst(b.allocator, .{ .String = q.name });
                const dst = b.allocReg();
                try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm } });
                return dst;
            }
            // `this` bare resolves to the implicit first param, or the
            // captured `this` slot inside a lambda body.
            // `KLIO_THIS_TRACE=1` — every bare-`this` lowering: the active
            // splice window, each scope index holding a `this` binding, and
            // the resolved register (`resolve` applies the window + the
            // enclosing splice's hidden bands).
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
        },
        .Super => {
            // `super` bare reads the same instance value as `this`
            // (`this@Outer` for a labeled `super@Outer`).
            if (try superBase(b, expr.Super)) |base| return base.this_reg;
            if (try resolveSuperThisReg(b)) |this_reg| return this_reg;
            try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
            return b.emitConst(.Unit);
        },
        .Spread => |sp| {
            // A spread outside a call's argument run is a supertype
            // constructor argument (`: Base(s, *ints)`) lowered as its own
            // thunk: its value is the array itself, which the constructor
            // path adopts as the packed vararg.
            return lowerExpr(b, sp.expr);
        },
    }
}

/// A statically known type for an arbitrary expression: its own declared type
/// where it has one, otherwise a constructed class, a resolved call's return
/// type, or the type a local's initializer lends it. Owned by the caller.
/// On-demand return-derivation nesting: a body deriving a body must
/// terminate on mutual recursion.
pub threadlocal var od_depth: u8 = 0;

/// The local whose own initializer is currently being typed. Its name is not
/// in scope there, so a bare call of that name inside the initializer resolves
/// past it. Saved and restored by `localInitTypeRef`, which nests.
pub var init_self_name: ?[]const u8 = null;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
