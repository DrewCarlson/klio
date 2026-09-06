//! The per-evaluation `VmHost` — the host type the IR evaluator
//! dispatches non-trivial operations through, plus the `VmIntrinsicHost`
//! adapter the stdlib reaches back through to invoke lambdas and the rest
//! of the runtime.
//!
//! The IR evaluator (`ir.eval`) is generic over its host type
//! (`comptime H`); `interp_ir` supplies `H = VmHost` at every
//! `ir.eval.evalWith(VmHost, ...)` call site, so `host.callValue(...)` and
//! the rest resolve as direct comptime-duck-typed method calls with no
//! `{ctx, vtable}` indirection. The per-operation methods are FREE
//! FUNCTIONS over `*VmHost` living in the sibling `host_*.zig` files; this
//! file owns the struct definitions and aliases each free function as a
//! `VmHost` method decl. `VmIntrinsicHost` still uses the
//! `runtime.IntrinsicHost` `{ctx, vtable}` pair, which is a separate seam.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const span = @import("span");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const Output = runtime.Output;
const SharedOutput = root.SharedOutput;
const RuntimeError = runtime.RuntimeError;
const IntrinsicHost = runtime.IntrinsicHost;
const HostResultU64 = runtime.HostResultU64;
const InstanceData = runtime.InstanceData;

const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
/// The stdlib `IntrinsicHost` callbacks carry `runtime.EvalResult`
/// (`Value` / `RuntimeError`), distinct from the IR evaluator's
/// `ir.eval.EvalResult` (`Value` / `EvalError`).
const RuntimeEvalResult = runtime.EvalResult;
const EvalError = ir.eval.EvalError;
const UnitResult = ir.eval.UnitResult;
const MaybeValueResult = ir.eval.MaybeValueResult;
const ReceiverShape = ir.eval.ReceiverShape;

const ProgramImage = root.ProgramImage;
const AnonMethods = root.AnonMethods;
const ClassTable = root.ClassTable;
const OuterTable = root.OuterTable;
const SharedClosures = root.SharedClosures;
const ThreadTable = root.ThreadTable;
const ObjectStates = root.ObjectStates;

// Sibling impl files. Each holds the free functions over `*VmHost` /
// `*VmIntrinsicHost` that fill in one slice of host behaviour.
pub const host_call_func = @import("host_call_func.zig");
pub const host_call_member = @import("host_call_member.zig");
pub const host_call_value = @import("host_call_value.zig");
pub const host_classes = @import("host_classes.zig");
pub const host_context = @import("host_context.zig");
pub const host_fields = @import("host_fields.zig");
const builtin_members = @import("builtin_members.zig");
pub const host_globals = @import("host_globals.zig");
pub const host_instances = @import("host_instances.zig");
pub const host_impl = @import("host_impl.zig");
pub const intrinsic_host = @import("intrinsic_host.zig");
pub const coroutines = @import("coroutines.zig");
pub const compose = @import("compose.zig");
pub const scheduler = @import("scheduler.zig");
pub const trace = @import("trace.zig");

/// Emit one structured `[PATH]` dispatch record (`KLIO_TRACE_PATH`) for a
/// terminal dispatch site: `path_tag` identifies the site, `decl_fqn`/`fid`
/// the chosen declaration (`fid` null for a native intrinsic form),
/// `receiver` the dispatch receiver (null for receiverless entries), and
/// `args` the call arguments. Free when the gate is off: the first check
/// returns before any label or tag work.
pub fn emitPath(
    allocator: Allocator,
    path_tag: []const u8,
    decl_fqn: []const u8,
    fid: ?FuncId,
    receiver: ?*const Value,
    args: []const Value,
) void {
    if (!trace.pathEnabled()) return;
    const recv_label: []const u8 = if (receiver) |r|
        trace.recvLabel(allocator, r.*) catch return
    else
        "none";
    defer if (receiver) |r| trace.freeLabel(allocator, r.*, recv_label);
    emitPathLabeled(allocator, path_tag, decl_fqn, fid, recv_label, args);
}

/// `emitPath` with a caller-supplied receiver label. Super-qualified
/// dispatch uses this to label the record with the resolved static target
/// class (`super(Base)`) rather than the runtime receiver: `super.f()` is
/// static dispatch, so keying it on the runtime class would collide with
/// the virtual `recv.f()` key while legitimately choosing a different
/// declaration.
pub fn emitPathLabeled(
    allocator: Allocator,
    path_tag: []const u8,
    decl_fqn: []const u8,
    fid: ?FuncId,
    recv_label: []const u8,
    args: []const Value,
) void {
    if (!trace.pathEnabled()) return;
    // Coarse arg-shape tags via `trace.recvLabel`: the runtime-type label
    // per argument — the same axis member dispatch probes — with an
    // instance reporting its runtime class name. Comma-joined; `-` for a
    // zero-arg call so the record stays one space-separated token list.
    var tags: std.ArrayList(u8) = .empty;
    defer tags.deinit(allocator);
    if (args.len == 0) {
        tags.appendSlice(allocator, "-") catch return;
    }
    for (args, 0..) |a, i| {
        if (i != 0) tags.append(allocator, ',') catch return;
        const label = trace.recvLabel(allocator, a) catch return;
        defer trace.freeLabel(allocator, a, label);
        tags.appendSlice(allocator, label) catch return;
    }
    const fn_name = pathSimpleName(decl_fqn);
    const caller: []const u8 = if (ir.eval.currentFrameFunc()) |cf|
        (if (cf.fqn.len != 0) cf.fqn else cf.name)
    else
        "-";
    if (fid) |f| {
        trace.path("fn={s} recv={s} argc={d} args={s} decl={s}#{d} path={s} caller={s}", .{
            fn_name, recv_label, args.len, tags.items, decl_fqn, f.int(), path_tag, caller,
        });
    } else {
        trace.path("fn={s} recv={s} argc={d} args={s} decl={s} path={s} caller={s}", .{
            fn_name, recv_label, args.len, tags.items, decl_fqn, path_tag, caller,
        });
    }
}

/// Simple-name tail of a possibly-qualified name (`a.b.C` -> `C`).
fn pathSimpleName(fqn: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

/// Assert (Debug) that the process-wide receiver/coroutine thread-locals are
/// empty at a run boundary, then clear them. Run between programs so leaked
/// state is a loud failure rather than silently threaded into the next run.
pub fn resetReceiverThreadLocals() void {
    host_instances.resetReceiverTls();
    host_call_member.resetReceiverTls();
    host_fields.resetReceiverTls();
    host_impl.resetReceiverTls();
    coroutines.resetReceiverTls();
    compose.resetAtRunBoundary();
}

/// Drop the process-global anon-`object` site caches: their keys and thunk
/// sub-modules belong to the finished run and must not be reused by the next
/// one in the same process (tests, repeated CLI runs). PROGRAM boundary only —
/// never from a Vm deinit: transient Vms (worker-pool tasks, nested drivers)
/// tear down while the program's classes registry still holds the site names
/// as live map keys, and freeing them there is a use-after-free on the next
/// anon-object instantiation.
pub fn resetRunGlobalCaches() void {
    host_instances.resetAnonSiteCache();
    host_call_member.resetStaticApplicabilityCache();
    // Invalidate every pointer-keyed dispatch cache (the thread-local method /
    // resolve / perm L1s, the name-identity slots, the owner-keyed ext-prop
    // memo) in one stroke: entries carry a generation stamp, and stale
    // generations never hit — including on still-parked pool worker threads a
    // per-thread clear could not reach. Without this, an in-process driver
    // running many programs replayed the previous program's resolutions off
    // reused cell addresses (wrong overloads, calls into freed IR).
    host_call_member.bumpDispatchCacheGen();
    // The bytecode-tier stream cache keys on blocks-pointer identity;
    // reused addresses across in-process programs must not replay a prior
    // program's compiled stream.
    ir.bc.resetCacheForTest();
    ir.eval.resetSuspendLivenessCache();
    stdlib.resetEmptyCollectionSingletons();
    stdlib.resetEmptySequenceSingleton();
}

/// A borrowed view over a `Vm`'s (or another host's) shared program-state
/// handles. The fields are plain value copies of `ObjRef`/`Shared*`
/// handles — copying them does NOT bump any refcount, so a `SharedHandles`
/// owns nothing and must never be `deinit`'d. The owner (`self`) keeps every
/// cell alive for the view's whole lifetime. Used to stamp out transient,
/// call-scoped `VmHost`/`VmIntrinsicHost`s without per-handle atomic traffic.
pub const SharedHandles = struct {
    globals: ObjRef(Env),
    module: ObjRef(Module),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    object_states: ObjectStates,
    singletons_by_id: root.SingletonsById,
    allocator: Allocator,

    /// Borrow the shared handles a live `VmHost` holds, without cloning.
    pub fn fromHost(host: *const VmHost) SharedHandles {
        return .{
            .globals = host.globals,
            .module = host.module,
            .instance_id_counter = host.instance_id_counter,
            .classes = host.classes,
            .prog = host.prog,
            .anon_methods = host.anon_methods,
            .class_default_outer = host.class_default_outer,
            .closures = host.closures,
            .out_sink = host.out_sink,
            .threads = host.threads,
            .object_states = host.object_states,
            .singletons_by_id = host.singletons_by_id,
            .allocator = host.allocator,
        };
    }

    /// Borrow the shared handles a live `VmIntrinsicHost` holds.
    pub fn fromIntrinsic(host: *const VmIntrinsicHost) SharedHandles {
        return .{
            .globals = host.globals,
            .module = host.module,
            .instance_id_counter = host.instance_id_counter,
            .classes = host.classes,
            .prog = host.prog,
            .anon_methods = host.anon_methods,
            .class_default_outer = host.class_default_outer,
            .closures = host.closures,
            .out_sink = host.out_sink,
            .threads = host.threads,
            .object_states = host.object_states,
            .singletons_by_id = host.singletons_by_id,
            .allocator = host.allocator,
        };
    }
};

/// IR Host implementation. Every method native to the Vm lives as a
/// free function over `*VmHost` in a sibling file; this struct holds the
/// shared state those functions read and write for the duration of one
/// evaluation.
pub const VmHost = struct {
    globals: ObjRef(Env),
    module: ObjRef(Module),
    out: Output,
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    object_states: ObjectStates,
    singletons_by_id: root.SingletonsById,
    allocator: Allocator,

    /// Build a transient `VmHost` that BORROWS another host/Vm's shared
    /// handles by value, with no refcount bump. The view never outlives the
    /// owner, so it must not `deinit` any borrowed handle — the owner still
    /// holds each cell. `globals` and `out` are passed explicitly because a
    /// delegated closure body layers its own scoped env, and each call binds
    /// its own output sink.
    pub fn borrowed(state: SharedHandles, globals: ObjRef(Env), out: Output) VmHost {
        return .{
            .globals = globals,
            .module = state.module,
            .out = out,
            .instance_id_counter = state.instance_id_counter,
            .classes = state.classes,
            .prog = state.prog,
            .anon_methods = state.anon_methods,
            .class_default_outer = state.class_default_outer,
            .closures = state.closures,
            .out_sink = state.out_sink,
            .threads = state.threads,
            .object_states = state.object_states,
            .singletons_by_id = state.singletons_by_id,
            .allocator = state.allocator,
        };
    }

    // The IR evaluator is generic over its host type (`comptime H`) and
    // invokes these as plain methods (`host.callValue(...)`). Each is the
    // free function over `*VmHost` living in a sibling file; aliasing them
    // here as struct decls makes method-call syntax resolve directly, with
    // no `{ctx, vtable}` indirection. `interp_ir` supplies `H = VmHost` at
    // every `ir.eval.evalWith(VmHost, ...)` call site.
    pub const callValue = host_call_value.callValue;
    pub const callableDeclaredArity = host_call_func.callableDeclaredArity;
    pub const prepareClosureFlatCall = host_call_value.prepareClosureFlatCall;
    pub const callClosureFast = host_call_value.callClosureFast;
    pub const prepareClosureWithThisFlatCall = host_call_value.prepareClosureWithThisFlatCall;
    pub const prepareValueRecvCtxFlatCall = host_call_value.prepareValueRecvCtxFlatCall;
    pub const prepareUndispatchedStartFlatCall = host_call_value.prepareUndispatchedStartFlatCall;
    pub const undispatchedBarrierPark = host_call_value.undispatchedBarrierPark;
    pub const undispatchedScopeLeave = host_call_value.undispatchedScopeLeave;
    pub const rootPumpBarrierPark = host_call_value.rootPumpBarrierPark;
    pub const rootPumpFlatComplete = host_call_value.rootPumpFlatComplete;
    pub const prepareTypedFlatCall = host_call_func.prepareTypedFlatCall;
    pub const typedBindingsRestore = host_call_func.typedBindingsRestore;
    pub const typedCallBoundary = host_call_func.typedCallBoundary;
    pub const flatCallClosed = host_call_value.flatCallClosed;
    pub const callValueNamed = host_call_value.callValueNamed;
    pub const callValueNamedRecvCtx = host_call_value.callValueNamedRecvCtx;
    pub const closureParamsDisproven = host_call_value.closureParamsDisproven;
    pub const callValueNamedTyped = host_call_value.callValueNamedTyped;
    pub const collectionsEqualHostAware = host_call_member.collectionsEqualHostAware;
    pub const deepValueEquals = host_call_member.deepValueEquals;
    pub const callValueWithThis = host_call_value.callValueWithThis;
    pub const callValueWithThisHead = host_call_value.callValueWithThisHead;
    pub const callValueWithThisExact = host_call_value.callValueWithThisExact;
    pub const callableFieldArity = host_call_member.callableFieldArity;
    pub const valueCouldServeName = host_call_member.valueCouldServeName;
    pub const debugClassNameOf = host_call_member.debugClassNameOf;
    pub const bindTypeParamGlobal = host_globals.bindTypeParamGlobal;
    pub const bindTypeParamSpelling = host_globals.bindTypeParamSpelling;
    pub const restoreGlobalBinding = host_globals.restoreGlobalBinding;
    pub const callMember = host_call_member.callMember;
    pub const prepareMemberFlatCall = host_call_member.prepareMemberFlatCall;
    pub const prepareMemberFlatCallNamed = host_call_member.prepareMemberFlatCallNamed;
    pub const callMemberNamed = host_call_member.callMemberNamed;
    pub const callMemberNamedStatic = host_call_member.callMemberNamedStatic;
    pub const callMemberNamedDeclared = host_call_member.callMemberNamedDeclared;
    pub const invokeResolvedMember = host_call_member.invokeResolvedMember;
    pub const invokeVirtualMember = host_call_member.invokeVirtualMember;
    pub const prepareVirtualFlatCall = host_call_member.prepareVirtualFlatCall;
    pub const prepareResolvedFlatCall = host_call_member.prepareResolvedFlatCall;
    pub const memberSiteSig = host_call_member.memberSiteSig;
    pub const hostMemberServeProbe = host_call_member.hostMemberServeProbe;
    pub const hostMemberServeKind = host_call_member.hostMemberServeKind;
    pub const prepareMemberFlatFromFid = host_call_member.prepareMemberFlatFromFid;
    pub const callMemberStrictExt = host_call_member.callMemberStrictExt;
    pub const receiverImplementsType = host_call_member.receiverImplementsType;
    pub const memberExtOverridesFor = host_call_member.memberExtOverridesFor;
    pub const callMemberMembersOnly = host_call_member.callMemberMembersOnly;
    pub const callMemberMembersOnlyLenient = host_call_member.callMemberMembersOnlyLenient;
    pub const committedExtReceiverDisproven = host_call_member.committedExtReceiverDisproven;
    pub const committedExtReceiverProven = host_call_member.committedExtReceiverProven;
    pub const resolveMemberFuncId = host_call_member.resolveMemberFuncId;
    pub const resolveVirtualFuncId = host_call_member.resolveVirtualFuncId;
    pub const hostHasMember = host_call_member.hostHasMember;
    pub const cmgGlobalSkip = host_call_member.cmgGlobalSkip;
    pub const cmgGlobalRecord = host_call_member.cmgGlobalRecord;
    pub const hostHasProperty = host_call_member.hostHasProperty;
    pub const hostHasExtPropSetter = host_fields.hostHasExtPropSetter;
    pub const companionWithMember = host_call_member.companionWithMember;
    pub const declaringClassSimpleName = host_call_member.declaringClassSimpleName;
    pub const memberRef = host_call_member.memberRef;
    pub const memberRefExact = host_call_member.memberRefExact;
    pub const callSuper = host_call_member.callSuper;
    pub const qualifiedThis = host_call_member.qualifiedThis;
    pub const setCtorArgStaticHeads = host_instances.setCtorArgStaticHeads;
    pub const newInstance = host_instances.newInstance;
    pub const newInstanceNamed = host_instances.newInstanceNamed;
    pub const classSecondaryCtorCanBind = host_instances.classSecondaryCtorCanBind;
    pub const buildObject = host_instances.buildObject;
    pub const getField = host_fields.getField;
    pub const getMemberField = host_fields.getMemberField;
    pub const getMemberFieldNoExt = host_fields.getMemberFieldNoExt;
    pub const enclosingEnumEntry = host_fields.enclosingEnumEntry;
    pub const enclosingEnumEntryByOwner = host_fields.enclosingEnumEntryByOwner;
    pub const stampRefAdaptation = host_fields.stampRefAdaptation;
    pub const closureRefEquals = builtin_members.closureRefEquals;
    pub const fieldSiteRoute = host_fields.fieldSiteRoute;
    pub const fieldWriteSiteRoute = host_fields.fieldWriteSiteRoute;
    pub const sgetterNameMatches = host_fields.sgetterNameMatches;
    pub const storedNullServable = host_fields.storedNullServable;
    pub const builtinIndexPropsServable = host_fields.builtinIndexPropsServable;
    pub const runFieldGetter = host_fields.runFieldGetter;
    pub const fieldGetterIsLeaf = host_fields.fieldGetterIsLeaf;
    pub const funcRunsItsBody = host_fields.funcRunsItsBody;
    pub const ownerModuleForFunc = host_fields.ownerModuleForFunc;
    pub const replayHits = host_call_member.replayHits;
    pub const extFbCounts = host_call_member.extFbCounts;
    pub const dispatchCacheGen = host_call_member.dispatchCacheGen;
    pub const leafGlobalGet = host_globals.leafGlobalGet;
    pub const fastCallPlan = host_call_func.fastCallPlan;
    pub const fuseSiteBinds = host_call_func.fuseSiteBinds;
    pub const callFuncFast = host_call_func.callFuncFast;
    pub const flatPlainCallOpen = host_call_func.flatPlainCallOpen;
    pub const plainStoredFieldIndex = host_fields.plainStoredFieldIndex;
    pub const plainStoredScalarFieldNN = host_fields.plainStoredScalarFieldNN;
    pub const setField = host_fields.setField;
    pub const setFieldFrom = host_fields.setFieldFrom;
    pub const instanceOf = host_classes.instanceOf;
    pub const ctxStackLen = host_context.ctxStackLen;
    pub const ctxPush = host_context.ctxPush;
    pub const ctxStackTruncate = host_context.ctxStackTruncate;
    pub const ctxResolve = host_context.ctxResolve;
    pub const ctxActivate = host_context.ctxActivate;
    pub const ctxIsActive = host_context.ctxIsActive;
    pub const isConcreteCastTarget = host_classes.isConcreteCastTarget;
    pub const registerClass = host_classes.registerClass;
    pub const registerClassCaptured = host_classes.registerClassCaptured;
    pub const localClassValue = host_classes.localClassValue;
    pub const lookupGlobal = host_globals.lookupGlobal;
    pub const composeSnapshotGlobals = host_globals.composeSnapshotGlobals;
    pub const lookupGlobalById = host_globals.lookupGlobalById;
    pub const mainFuncNameMatches = host_globals.mainFuncNameMatches;
    pub const lookupGlobalThrowing = host_globals.lookupGlobalThrowing;
    pub const storeGlobal = host_globals.storeGlobal;
    pub const isShadowingCapture = host_globals.isShadowingCapture;
    pub const scopedLocalBinds = host_globals.scopedLocalBinds;
    pub const buildClosure = host_call_value.buildClosure;
    pub const buildAstLambdaWithFlagFuncid = host_call_value.buildAstLambdaWithFlagFuncid;
    pub const callableReceiverShape = host_call_value.callableReceiverShape;
    pub const callableAcceptsArgs = host_call_value.callableAcceptsArgs;
    pub const callableAcceptsCall = host_call_value.callableAcceptsCall;
    pub const closureNeedsThisCapture = host_call_value.closureNeedsThisCapture;
    pub const overrideClosureThis = host_call_value.overrideClosureThis;
    pub const callFunc = host_call_func.callFunc;
    pub const samConvertActivationArgs = host_call_func.samConvertActivationArgs;
    pub const callFuncNamed = host_call_func.callFuncNamed;
    pub const callFuncTyped = host_call_func.callFuncTyped;
    pub const setTrailingLambdaCall = host_call_func.setTrailingLambdaCall;
    pub const setTrailingMemberCall = host_call_member.setTrailingMemberCall;
    pub const callNamedOverload = host_call_func.callNamedOverload;
    pub const pickNamedOverloadId = host_call_func.pickNamedOverloadId;
    pub const pickNamedOverloadIdRecv = host_call_func.pickNamedOverloadIdRecv;
    pub const bareUnsettledHeaderNoOp = host_call_func.bareUnsettledHeaderNoOp;
};

/// Stdlib `CallCtx` host adapter for native Vm dispatch. HOF bindings
/// (`map`, `forEach`, scope fns, …) reach back through this adapter to
/// invoke the lambda they were passed.
pub const VmIntrinsicHost = struct {
    module: ObjRef(Module),
    closures: SharedClosures,
    globals: ObjRef(Env),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    out_sink: SharedOutput,
    threads: ThreadTable,
    object_states: ObjectStates,
    singletons_by_id: root.SingletonsById,
    allocator: Allocator,

    /// Build a transient `VmIntrinsicHost` that BORROWS another host's shared
    /// handles by value, with no refcount bump. Same non-owning contract as
    /// `VmHost.borrowed`: the view never outlives its owner and must not
    /// `deinit` any borrowed handle.
    pub fn borrowed(state: SharedHandles) VmIntrinsicHost {
        return .{
            .module = state.module,
            .closures = state.closures,
            .globals = state.globals,
            .classes = state.classes,
            .prog = state.prog,
            .anon_methods = state.anon_methods,
            .class_default_outer = state.class_default_outer,
            .instance_id_counter = state.instance_id_counter,
            .out_sink = state.out_sink,
            .threads = state.threads,
            .object_states = state.object_states,
            .singletons_by_id = state.singletons_by_id,
            .allocator = state.allocator,
        };
    }

    /// Build a `runtime.IntrinsicHost` `{ctx, vtable}` pair bound to this
    /// adapter.
    pub fn intrinsicHost(self: *VmIntrinsicHost) IntrinsicHost {
        return .{ .ctx = self, .vtable = &intrinsic_vtable };
    }
};

// -------------------------------------------------------------------------
// `runtime.IntrinsicHost` vtable wiring for `VmIntrinsicHost`.
// -------------------------------------------------------------------------

fn ip(ctx: *anyopaque) *VmIntrinsicHost {
    return @ptrCast(@alignCast(ctx));
}

fn ivInvokeCallable(ctx: *anyopaque, callable: *const Value, args: []const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.invokeCallable(ip(ctx), callable, args, out);
}
fn ivInvokeCallableWithThis(ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.invokeCallableWithThis(ip(ctx), callable, args, this_value, out);
}
fn ivInvokeMethod(ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    return intrinsic_host.invokeMethod(ip(ctx), receiver, name, args, out);
}
fn ivGetProperty(ctx: *anyopaque, receiver: *const Value, name: []const u8, out: Output) Allocator.Error!?RuntimeEvalResult {
    return intrinsic_host.getProperty(ip(ctx), receiver, name, out);
}
fn ivConstructNamed(ctx: *anyopaque, class: *const Value, names: []const []const u8, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    return intrinsic_host.constructNamed(ip(ctx), class, names, args, out);
}
fn ivLookupGlobal(ctx: *anyopaque, name: []const u8) ?Value {
    return intrinsic_host.lookupGlobal(ip(ctx), name);
}
fn ivAllocInstanceId(ctx: *anyopaque) u64 {
    return intrinsic_host.allocInstanceId(ip(ctx));
}
fn ivNewSynthInstance(ctx: *anyopaque, class_fqn: []const u8, identity: u64, fields: []const InstanceData.Field) Allocator.Error!Value {
    return intrinsic_host.newSynthInstance(ip(ctx), class_fqn, identity, fields);
}
fn ivRunBlocking(ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.runBlocking(ip(ctx), block, scope, out);
}
fn ivCoroutineRunRoot(ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.coroutineRunRoot(ip(ctx), scope, block, out);
}
fn ivCoroutineStartRootOrSuspended(ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.coroutineStartRootOrSuspended(ip(ctx), scope, block, out);
}
fn ivCoroutineHasDriver(ctx: *anyopaque) bool {
    _ = ctx;
    return coroutines.coroutineHasDriver();
}
fn ivCoroutineLaunch(ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineLaunch(ip(ctx), block, scope, out);
}
fn ivCoroutineSpawnTimeout(ctx: *anyopaque, block: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineSpawnTimeout(ip(ctx), block, out);
}
fn ivCoroutineArmSlot(ctx: *anyopaque, slot: i64) void {
    intrinsic_host.coroutineArmSlot(ip(ctx), slot);
}
fn ivCoroutineDisarmSlot(ctx: *anyopaque) void {
    intrinsic_host.coroutineDisarmSlot(ip(ctx));
}
fn ivCoroutinePushScope(ctx: *anyopaque, scope: *const Value) void {
    intrinsic_host.coroutinePushScope(ip(ctx), scope);
}
fn ivCoroutinePopScope(ctx: *anyopaque) void {
    intrinsic_host.coroutinePopScope(ip(ctx));
}
fn ivCoroutineResumeSlotValue(ctx: *anyopaque, slot: i64, value: Value) void {
    intrinsic_host.coroutineResumeSlotValue(ip(ctx), slot, value);
}
fn ivMarkSlotOwnerSchedulerBacked(ctx: *anyopaque, slot: i64) void {
    _ = ctx;
    intrinsic_host.markSlotOwnerSchedulerBacked(slot);
}
fn ivActiveCoroScope(ctx: *anyopaque) ?Value {
    return intrinsic_host.activeCoroScope(ip(ctx));
}
fn ivLookupGlobalFunc(ctx: *anyopaque, name: []const u8) ?Value {
    return intrinsic_host.lookupGlobalFunc(ip(ctx), name);
}
fn ivCoroutineResumeExternal(ctx: *anyopaque, slot: i64, value: Value, out: Output) void {
    intrinsic_host.coroutineResumeExternal(ip(ctx), slot, value, out);
}
fn ivCoroutineResumeContinuation(ctx: *anyopaque, slot: i64, value: Value, out: Output) void {
    intrinsic_host.coroutineResumeContinuation(ip(ctx), slot, value, out);
}
fn ivCoroutineDrainToIdle(ctx: *anyopaque, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineDrainToIdle(ip(ctx), out);
}
fn ivCoroutineDispatchPooled(ctx: *anyopaque, block: *const Value, io_kind: bool, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineDispatchPooled(ip(ctx), block, io_kind, out);
}
fn ivSpawnOsThread(ctx: *anyopaque, block: *const Value, out: Output) Allocator.Error!HostResultU64 {
    return intrinsic_host.spawnOsThread(ip(ctx), block, out);
}
fn ivJoinOsThread(ctx: *anyopaque, id: u64) Allocator.Error!?RuntimeError {
    return intrinsic_host.joinOsThread(ip(ctx), id);
}
fn ivOsThreadAlive(ctx: *anyopaque, id: u64) bool {
    return intrinsic_host.osThreadAlive(ip(ctx), id);
}
fn ivBuilderStep(ctx: *anyopaque, state: runtime.BuilderStateRef, out: Output) Allocator.Error!runtime.BuilderStepResult {
    return @import("coroutines.zig").builderStep(ip(ctx), state, out);
}
fn ivPersist(ctx: *anyopaque) IntrinsicHost {
    const src = ip(ctx);
    // Clone the shared handles into an allocator-owned host so it outlives the
    // `main` activation whose transient host this was. Refcounts hold the
    // module / globals / closures / object-states alive; the copy is never
    // released — an OS-driven frame loop owns it until the process exits.
    const p = src.allocator.create(VmIntrinsicHost) catch return .{ .ctx = src, .vtable = &intrinsic_vtable };
    p.* = .{
        .module = src.module.clone(),
        .closures = src.closures.clone(),
        .globals = src.globals.clone(),
        .classes = src.classes.clone(),
        .prog = src.prog.clone(),
        .anon_methods = src.anon_methods.clone(),
        .class_default_outer = src.class_default_outer.clone(),
        .instance_id_counter = src.instance_id_counter.clone(),
        .out_sink = src.out_sink.clone(),
        .threads = src.threads.clone(),
        .object_states = src.object_states.clone(),
        .singletons_by_id = src.singletons_by_id.clone(),
        .allocator = src.allocator,
    };
    return .{ .ctx = p, .vtable = &intrinsic_vtable };
}
fn ivCallableReturnTy(ctx: *anyopaque, callable: *const Value) ?[]const u8 {
    const self = ip(ctx);
    if (callable.* != .IrClosure) return null;
    const info = self.closures.get(@intCast(callable.IrClosure.id)) orelse return null;
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const module = info.module orelse module_ref.asPtr();
    const func = module.funcById(info.body_func) orelse return null;
    const name = func.return_ty.name;
    if (name.len == 0 or std.mem.eql(u8, name, "Unit") or std.mem.eql(u8, name, "kotlin.Unit")) return null;
    return name;
}

const intrinsic_vtable: IntrinsicHost.VTable = .{
    .invoke_callable = ivInvokeCallable,
    .invoke_callable_with_this = ivInvokeCallableWithThis,
    .invoke_method = ivInvokeMethod,
    .get_property = ivGetProperty,
    .construct_named = ivConstructNamed,
    .lookup_global = ivLookupGlobal,
    .alloc_instance_id = ivAllocInstanceId,
    .new_synth_instance = ivNewSynthInstance,
    .run_blocking = ivRunBlocking,
    .coroutine_run_root = ivCoroutineRunRoot,
    .coroutine_start_root_or_suspended = ivCoroutineStartRootOrSuspended,
    .coroutine_has_driver = ivCoroutineHasDriver,
    .coroutine_launch = ivCoroutineLaunch,
    .coroutine_spawn_timeout = ivCoroutineSpawnTimeout,
    .coroutine_arm_slot = ivCoroutineArmSlot,
    .coroutine_disarm_slot = ivCoroutineDisarmSlot,
    .coroutine_push_scope = ivCoroutinePushScope,
    .coroutine_pop_scope = ivCoroutinePopScope,
    .coroutine_resume_slot_value = ivCoroutineResumeSlotValue,
    .mark_slot_owner_scheduler_backed = ivMarkSlotOwnerSchedulerBacked,
    .active_coro_scope = ivActiveCoroScope,
    .lookup_global_func = ivLookupGlobalFunc,
    .coroutine_resume_external = ivCoroutineResumeExternal,
    .coroutine_dispatch_pooled = ivCoroutineDispatchPooled,
    .coroutine_resume_continuation = ivCoroutineResumeContinuation,
    .coroutine_drain_to_idle = ivCoroutineDrainToIdle,
    .spawn_os_thread = ivSpawnOsThread,
    .join_os_thread = ivJoinOsThread,
    .os_thread_alive = ivOsThreadAlive,
    .builder_step = ivBuilderStep,
    .callable_return_ty = ivCallableReturnTy,
    .persist = ivPersist,
};

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = host_call_func;
    _ = host_call_member;
    _ = host_call_value;
    _ = host_classes;
    _ = host_fields;
    _ = host_globals;
    _ = host_instances;
    _ = host_impl;
    _ = intrinsic_host;
    _ = coroutines;
    _ = trace;
}
