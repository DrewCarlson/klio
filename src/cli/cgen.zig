//! Ahead-of-time C generation: the program itself, not a launcher for it.
//!
//! The emitted file is self-contained. Every function is a C function, every
//! block a label, every register a typed C local, and every constant a C
//! literal — nothing here names a block or an instruction index, so nothing
//! reads the module at run time and no image is loaded.
//!
//! This is the scalar core: the statically-typed arithmetic subset, which needs
//! no runtime at all. Everything outside it is refused by `eligible` and the
//! caller falls back, so the set can widen without a correctness cliff. See
//! `plans/native-c-backend.md`.
const std = @import("std");
/// The interpreter's own stdlib table. A member the backend does not perform
/// directly is not a gap to fill here: the operation already exists, named, and
/// compiled code calls the same entry the interpreter does.
const stdlib = @import("stdlib");
/// The interpreter's member dispatch. Which builtin member calls the runtime
/// can serve is its classification, read here at compile time so the backend
/// keeps no second table of the same names.
const member_dispatch = @import("interp_ir").member_dispatch;
const ir = @import("ir");

const Reg = ir.Reg;
const Func = ir.Func;
const Module = ir.Module;

const mod_model = @import("cgen/model.zig");
pub const Compiled = mod_model.Compiled;
pub const BareResolution = mod_model.BareResolution;
pub const Program = mod_model.Program;
pub const Parent = mod_model.Parent;
pub const FieldInfo = mod_model.FieldInfo;
pub const Laid = mod_model.Laid;
pub const Error = mod_model.Error;
pub const BodyProp = mod_model.BodyProp;
pub const EnumEntryInfo = mod_model.EnumEntryInfo;
pub const ClassLayout = mod_model.ClassLayout;
pub const CapInfo = mod_model.CapInfo;
pub const LambdaInfo = mod_model.LambdaInfo;
pub const Global = mod_model.Global;
pub const FuncDefaults = mod_model.FuncDefaults;
pub const Accepted = mod_model.Accepted;

const mod_types = @import("cgen/types.zig");
pub const Ty = mod_types.Ty;
pub const tyOf = mod_types.tyOf;
pub const funcRetTy = mod_types.funcRetTy;
pub const funcRetTy2 = mod_types.funcRetTy2;
pub const constTy = mod_types.constTy;
pub const sameWidthKind = mod_types.sameWidthKind;
pub const isNumericTy = mod_types.isNumericTy;
pub const paramTy = mod_types.paramTy;
pub const isStringReg = mod_types.isStringReg;
pub const THROWABLE_CLS = mod_types.THROWABLE_CLS;
pub const isThrowableClass = mod_types.isThrowableClass;
pub const ThrowTy = mod_types.ThrowTy;
pub const simpleName = mod_types.simpleName;
pub const ThrowTable = mod_types.ThrowTable;
pub const buildThrowTable = mod_types.buildThrowTable;
pub const numberThrowSubtree = mod_types.numberThrowSubtree;
pub const LIST_CLS = mod_types.LIST_CLS;
pub const CELL_CLS = mod_types.CELL_CLS;
pub const ARRAY_CLS = mod_types.ARRAY_CLS;
pub const ITER_CLS = mod_types.ITER_CLS;
pub const RANGE_CLS = mod_types.RANGE_CLS;
pub const NUMCLS_BASE = mod_types.NUMCLS_BASE;
pub const numCls = mod_types.numCls;
pub const numClsTy = mod_types.numClsTy;
pub const builtinQualifier = mod_types.builtinQualifier;
pub const BuiltinConst = mod_types.BuiltinConst;
pub const builtinConst = mod_types.builtinConst;
pub const FUNC_CLS_BASE = mod_types.FUNC_CLS_BASE;
pub const FUNC_MAX_ARITY = mod_types.FUNC_MAX_ARITY;
pub const funcCls = mod_types.funcCls;
pub const funcClsArity = mod_types.funcClsArity;
pub const functionTypeArity = mod_types.functionTypeArity;
pub const refElemCls = mod_types.refElemCls;
pub const commonCls = mod_types.commonCls;
pub const isToStringCall = mod_types.isToStringCall;
pub const rendersToString = mod_types.rendersToString;
pub const callResultCls = mod_types.callResultCls;
pub const refElemOf = mod_types.refElemOf;
pub const functionResultTy = mod_types.functionResultTy;
pub const isBuiltinCls = mod_types.isBuiltinCls;
pub const primArrayKind = mod_types.primArrayKind;
pub const primKindOfTy = mod_types.primKindOfTy;
pub const primArrayElem = mod_types.primArrayElem;
pub const unsignedTypeOf = mod_types.unsignedTypeOf;
pub const isArrayTypeName = mod_types.isArrayTypeName;
pub const arrayElemOf = mod_types.arrayElemOf;
pub const arrayOfIntrinsic = mod_types.arrayOfIntrinsic;
pub const STRING_CLS = mod_types.STRING_CLS;
pub const promote = mod_types.promote;
pub const isCmp = mod_types.isCmp;
pub const isBitwise = mod_types.isBitwise;
pub const wrapTy = mod_types.wrapTy;
pub const cOp = mod_types.cOp;

const mod_layout = @import("cgen/layout.zig");
pub const classFields = mod_layout.classFields;
pub const classFieldsAt = mod_layout.classFieldsAt;
pub const isBackingAccess = mod_layout.isBackingAccess;
pub const plainFieldName = mod_layout.plainFieldName;
pub const fieldIndex = mod_layout.fieldIndex;
pub const classIndexOfName = mod_layout.classIndexOfName;

const mod_analysis = @import("cgen/analysis.zig");
pub const numConv = mod_analysis.numConv;
pub const numConvVirtual = mod_analysis.numConvVirtual;
pub const ListIntrinsic = mod_analysis.ListIntrinsic;
pub const listIntrinsic = mod_analysis.listIntrinsic;
pub const hostMemberOp = mod_analysis.hostMemberOp;
pub const stdlibEntry = mod_analysis.stdlibEntry;
pub const isLaunch = mod_analysis.isLaunch;
pub const isDelay = mod_analysis.isDelay;
pub const isRunBlocking = mod_analysis.isRunBlocking;
pub const isArrayOfNulls = mod_analysis.isArrayOfNulls;
pub const ScalarIntrinsic = mod_analysis.ScalarIntrinsic;
pub const scalarIntrinsic = mod_analysis.scalarIntrinsic;
pub const slotImpl = mod_analysis.slotImpl;
pub const MAX_CALL_PARAMS = mod_analysis.MAX_CALL_PARAMS;
pub const ArgBinding = mod_analysis.ArgBinding;
pub const bindCallArgs = mod_analysis.bindCallArgs;
pub const memberRoot = mod_analysis.memberRoot;
pub const settleTypes = mod_analysis.settleTypes;
pub const noReg = mod_analysis.noReg;
pub const bareTy = mod_analysis.bareTy;
pub const array_init_args = mod_analysis.array_init_args;
pub const arrayInitFnType = mod_analysis.arrayInitFnType;
pub const expectedFnType = mod_analysis.expectedFnType;
pub const lambdaParams = mod_analysis.lambdaParams;
pub const lambdaEscapes = mod_analysis.lambdaEscapes;
pub const instReadsReg = mod_analysis.instReadsReg;
pub const resolveBare = mod_analysis.resolveBare;
pub const bareOn = mod_analysis.bareOn;
pub const PropUse = mod_analysis.PropUse;
pub const LambdaUse = mod_analysis.LambdaUse;
pub const lambdaSingletonSlot = mod_analysis.lambdaSingletonSlot;
pub const typeHasSlot = mod_analysis.typeHasSlot;
pub const AccessPlan = mod_analysis.AccessPlan;
pub const accessPlan = mod_analysis.accessPlan;
pub const accessOwner = mod_analysis.accessOwner;
pub const VirtualProp = mod_analysis.VirtualProp;
pub const typeReaches = mod_analysis.typeReaches;
pub const virtualProp = mod_analysis.virtualProp;
pub const toStringOf = mod_analysis.toStringOf;
pub const SlotUse = mod_analysis.SlotUse;
pub const listMemberName = mod_analysis.listMemberName;
pub const isPrintln = mod_analysis.isPrintln;
pub const traceOn = mod_analysis.traceOn;
pub const layoutNo = mod_analysis.layoutNo;
pub const layoutNoTy = mod_analysis.layoutNoTy;
pub const instRefuse = mod_analysis.instRefuse;
pub const instRefuseNamed = mod_analysis.instRefuseNamed;
pub const noCallee = mod_analysis.noCallee;
pub const no = mod_analysis.no;
pub const noName = mod_analysis.noName;
pub const receiverClass = mod_analysis.receiverClass;
pub const globalTy = mod_analysis.globalTy;
pub const objectClassNamed = mod_analysis.objectClassNamed;
pub const companionObjectNamed = mod_analysis.companionObjectNamed;
pub const companionReceiver = mod_analysis.companionReceiver;
pub const topLevelFuncNamed = mod_analysis.topLevelFuncNamed;
pub const bareCallTarget = mod_analysis.bareCallTarget;
pub const ambiguousOverload = mod_analysis.ambiguousOverload;
pub const ctorFits = mod_analysis.ctorFits;
pub const classQualifierNamed = mod_analysis.classQualifierNamed;
pub const qualifierOwnerFqn = mod_analysis.qualifierOwnerFqn;
pub const nestedClassNamed = mod_analysis.nestedClassNamed;
pub const isDispatched = mod_analysis.isDispatched;
pub const SingletonUse = mod_analysis.SingletonUse;
pub const singletonSlot = mod_analysis.singletonSlot;
pub const enumClassNamed = mod_analysis.enumClassNamed;
pub const enumEntryIndex = mod_analysis.enumEntryIndex;
pub const staticClassOf = mod_analysis.staticClassOf;
pub const enumEntries = mod_analysis.enumEntries;
pub const globalIndex = mod_analysis.globalIndex;

const mod_eligible = @import("cgen/eligible.zig");
pub const eligible = mod_eligible.eligible;

const mod_decl = @import("cgen/decl.zig");
pub const mangleName = mod_decl.mangleName;
pub const writeSymbol = mod_decl.writeSymbol;
pub const ctorParamTy = mod_decl.ctorParamTy;
pub const ctorDefault = mod_decl.ctorDefault;
pub const ownLayout = mod_decl.ownLayout;
pub const layoutFor = mod_decl.layoutFor;
pub const writeCtorProto = mod_decl.writeCtorProto;
pub const writeThunkCall = mod_decl.writeThunkCall;
pub const writeCtorBody = mod_decl.writeCtorBody;
pub const renderExpr = mod_decl.renderExpr;
pub const zeroKindOf = mod_decl.zeroKindOf;
pub const boxFnName = mod_decl.boxFnName;
pub const acceptedParamTy = mod_decl.acceptedParamTy;
pub const convExpr = mod_decl.convExpr;
pub const boxExpr = mod_decl.boxExpr;
pub const unboxExpr = mod_decl.unboxExpr;
pub const regName = mod_decl.regName;
pub const writeProto = mod_decl.writeProto;
pub const writeConst = mod_decl.writeConst;
pub const emitCLiteral = mod_decl.emitCLiteral;
pub const writeFloatLit = mod_decl.writeFloatLit;
pub const writeDivGuard = mod_decl.writeDivGuard;
pub const succOf = mod_decl.succOf;
pub const blockOrder = mod_decl.blockOrder;
pub const reachableBlocks = mod_decl.reachableBlocks;
pub const acceptedRet = mod_decl.acceptedRet;
pub const suspendPoints = mod_decl.suspendPoints;
pub const bodySuspends = mod_decl.bodySuspends;
pub const isSuspendingCall = mod_decl.isSuspendingCall;
pub const suspendIndex = mod_decl.suspendIndex;

const mod_body = @import("cgen/body.zig");
pub const writeBody = mod_body.writeBody;

const mod_emit = @import("cgen/emit.zig");
pub const emit = mod_emit.emit;

/// Why a class has no layout. Reported only when a program actually needed
/// one: the table is built for every class in the module, so reporting during
/// the build names classes nothing ever asked about — mostly library
/// interfaces, which have no layout by their nature.
pub var layout_quiet = true;

/// A refusal may re-derive a class layout just to SAY why it has none, and
/// deriving one compiles property initializers, which can refuse again. Without
/// this, the explanation recurses into itself.
pub var layout_diag_busy = false;
