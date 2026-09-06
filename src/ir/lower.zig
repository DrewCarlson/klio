//! AST → IR lowering — module root. The lowering entry + context lives in
//! `lower/mod.zig`; this file re-exports its public surface so consumers
//! reach it as `ir.lower.<name>`.

const mod = @import("lower/mod.zig");

// Type aliases.
pub const AstBinOp = mod.AstBinOp;
pub const AstUnOp = mod.AstUnOp;
pub const AstBlock = mod.AstBlock;
pub const Expr = mod.Expr;
pub const Stmt = mod.Stmt;
pub const FuncBuilder = mod.FuncBuilder;

// Sibling lower namespaces.
pub const ast_scan = mod.ast_scan;
pub const helpers = mod.helpers;
pub const inline_state = mod.inline_state;
pub const for_loop = mod.for_loop;
pub const inline_call = mod.inline_call;
pub const lambda_body = mod.lambda_body;
pub const literals = mod.literals;
pub const thunks = mod.thunks;
pub const when_expr = mod.when_expr;
pub const decl = mod.decl;
pub const expr = mod.expr;
pub const stmt = mod.stmt;

// AST-scan helpers.
pub const collectDottedFqn = mod.collectDottedFqn;
pub const collectPathIdents = mod.collectPathIdents;
pub const collectPathIdentsStmt = mod.collectPathIdentsStmt;
pub const computeBoxedVars = mod.computeBoxedVars;
pub const isBoxedToAnyForm = mod.isBoxedToAnyForm;
pub const namesReferencedInLambdas = mod.namesReferencedInLambdas;
pub const collectVarDecls = mod.collectVarDecls;

// Builder-side helpers.
pub const isAnyTypedPath = mod.isAnyTypedPath;
pub const lambdaWritesOuterVar = mod.lambdaWritesOuterVar;
pub const boxedCellReg = mod.boxedCellReg;
pub const calleeLabel = mod.calleeLabel;
pub const lowerArgRun = mod.lowerArgRun;
pub const internArgNames = mod.internArgNames;
pub const internTypeArgs = mod.internTypeArgs;
pub const astBinop = mod.astBinop;
pub const exprSpan = mod.exprSpan;

// Inline-state registries.
pub const setInlineFnAsts = mod.setInlineFnAsts;
pub const setTypeAliasTags = mod.setTypeAliasTags;
pub const registerInlineFnId = mod.registerInlineFnId;
pub const resetInlineMemberOwners = mod.resetInlineMemberOwners;
pub const registerInlineMemberOwner = mod.registerInlineMemberOwner;
pub const registerExprBodyMember = mod.registerExprBodyMember;
pub const exprBodyMemberAst = mod.exprBodyMemberAst;
pub const resetMemberPropAsts = mod.resetMemberPropAsts;
pub const resetClassSupertypeRefs = mod.resetClassSupertypeRefs;
pub const registerClassSupertypeRefs = mod.registerClassSupertypeRefs;
pub const classSupertypeRefs = mod.classSupertypeRefs;
pub const resetExprBodyMembers = mod.resetExprBodyMembers;
pub const registerMemberPropAst = mod.registerMemberPropAst;
pub const resetMemberExtPropRecv = mod.resetMemberExtPropRecv;
pub const registerMemberExtPropRecv = mod.registerMemberExtPropRecv;
pub const memberExtPropRecv = mod.memberExtPropRecv;
pub const setDeferredSection = mod.setDeferredSection;
pub const ensureInlineBody = mod.ensureInlineBody;
pub const setShadowedInlineNames = mod.setShadowedInlineNames;
pub const setTopLevelPropNames = mod.setTopLevelPropNames;

// Literal lowering surface.
pub const widenNumericLiteral = mod.widenNumericLiteral;

// Thunk lowering surface.
pub const lowerAccessorBlock = mod.lowerAccessorBlock;
pub const lowerAccessorBlockRet = mod.lowerAccessorBlockRet;
pub const lowerSetterBlockTyped = mod.lowerSetterBlockTyped;
pub const lowerSetterExprTyped = mod.lowerSetterExprTyped;
pub const lowerAccessorExpr = mod.lowerAccessorExpr;
pub const lowerAccessorExprWithExpected = mod.lowerAccessorExprWithExpected;
pub const lowerAccessorExprEnclosing = mod.lowerAccessorExprEnclosing;
pub const lowerPropertyInitExpr = mod.lowerPropertyInitExpr;
pub const lowerBinaryExprAsThunk = mod.lowerBinaryExprAsThunk;
pub const lowerBlockAsThunk = mod.lowerBlockAsThunk;
pub const lowerBlockAsUnaryThunk = mod.lowerBlockAsUnaryThunk;
pub const lowerEmptyThunk = mod.lowerEmptyThunk;
pub const lowerExprAsParamThunk = mod.lowerExprAsParamThunk;
pub const lowerExprAsParamThunkScoped = mod.lowerExprAsParamThunkScoped;
pub const lowerExprAsParamThunkScopedEnclosing = mod.lowerExprAsParamThunkScopedEnclosing;
pub const lowerExprAsThunk = mod.lowerExprAsThunk;
pub const lowerDelegateExprAsThunk = mod.lowerDelegateExprAsThunk;
pub const lowerExprAsThunkTyped = mod.lowerExprAsThunkTyped;
pub const lowerInitBlock = mod.lowerInitBlock;
pub const lowerInitBlockWithParams = mod.lowerInitBlockWithParams;
pub const lowerUnaryExprAsThunk = mod.lowerUnaryExprAsThunk;

// when / for lowering surface.
pub const lowerWhen = mod.lowerWhen;
pub const lowerFor = mod.lowerFor;
pub const lowerForLabeled = mod.lowerForLabeled;

// Lambda-body lowering surface.
pub const lowerLambdaBodyCapturing = mod.lowerLambdaBodyCapturing;
pub const lowerLambdaBodyCapturingKind = mod.lowerLambdaBodyCapturingKind;
pub const lowerLambdaBodyCapturingKindWith = mod.lowerLambdaBodyCapturingKindWith;
pub const resolveCapture = mod.resolveCapture;

// Inline-call lowering surface.
pub const argLambdaHasNonlocalReturn = mod.argLambdaHasNonlocalReturn;
pub const spliceInlineLambda = mod.spliceInlineLambda;
pub const tryInlineCallWithTypeArgs = mod.tryInlineCallWithTypeArgs;

// Declaration lowering surface.
pub const bindParams = mod.bindParams;
pub const lowerClass = mod.lowerClass;
pub const lowerClassWithFile = mod.lowerClassWithFile;
pub const lowerClassWithExtras = mod.lowerClassWithExtras;
pub const lowerClassWithExtrasFqn = mod.lowerClassWithExtrasFqn;
pub const lowerClassWithExtrasFqnPkg = mod.lowerClassWithExtrasFqnPkg;
pub const lowerFunction = mod.lowerFunction;
pub const lowerFunctionWithFile = mod.lowerFunctionWithFile;
pub const lowerFunctionBodyInto = mod.lowerFunctionBodyInto;
pub const lowerMethod = mod.lowerMethod;
pub const lowerMethodWithMemberContext = mod.lowerMethodWithMemberContext;
pub const setLowerAnonCaptures = mod.setLowerAnonCaptures;
pub const takeLowerAnonCaptures = mod.takeLowerAnonCaptures;
pub const resolveAnnotationNames = mod.resolveAnnotationNames;

// Expression / statement lowering surface.
pub const lowerExpr = mod.lowerExpr;
pub const lowerReceiver = mod.lowerReceiver;
pub const lowerBlock = mod.lowerBlock;
pub const lowerStmt = mod.lowerStmt;

test {
    @import("std").testing.refAllDecls(@This());
    _ = mod;
}
