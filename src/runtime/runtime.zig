//! Shared runtime types for the interpreter and the stdlib.
//!
//! `Value`, `RuntimeError`, the `Output` sink, and `Env` live here so that
//! the stdlib can express native intrinsics in terms of the same
//! types the interpreter evaluates against, without either depending on
//! the other.

const std = @import("std");

const objcell = @import("objcell.zig");
const value_mod = @import("value.zig");
const class_mod = @import("class.zig");
const host_mod = @import("host.zig");
const output_mod = @import("output.zig");
const env_mod = @import("env.zig");
const proc_env_mod = @import("proc_env.zig");
const clock_mod = @import("clock.zig");
const float_fmt_mod = @import("float_fmt.zig");
const safety_mod = @import("safety.zig");
const threads_mod = @import("threads.zig");
const alloc_track_mod = @import("alloc_track.zig");

// objcell
pub const ObjRef = objcell.ObjRef;
pub const ObjGuard = objcell.ObjGuard;
pub const ObjGuardMut = objcell.ObjGuardMut;
pub const ControlBlock = objcell.ControlBlock;
pub const BorrowMutError = objcell.BorrowMutError;
pub const SpinMutex = objcell.SpinMutex;
pub const setReclaim = objcell.setReclaim;
pub const reclaimEnabled = objcell.reclaimEnabled;
pub const freeScratch = objcell.freeScratch;
pub const reclaimRequested = objcell.reclaimRequested;
pub const getenvSlice = objcell.getenvSlice;

/// Consolidated runtime performance configuration (`--opt` / `KLIO_OPT`): the
/// JIT tiers and the memory backend, resolved once from a single profile.
pub const perf = @import("perf.zig");
pub const AllocChoice = perf.AllocChoice;
pub const allocChoice = perf.allocChoice;
// Tracing GC (KGC) — see gc.zig / plans/GC.md.
pub const gc = objcell.gc;
// Page-returning slab allocator for the GC backend (keeps RSS tracking the
// live set; smp/libc free-lists never return reclaimed pages to the OS).
pub const slab = @import("slab.zig");
pub const leaktrack = @import("leaktrack.zig");
pub const trace = @import("trace.zig");
pub const forest = @import("forest.zig");
pub const prof = @import("prof.zig");
// Host-op temporary keepalive (a GC root for accumulators/snapshots held across
// a re-entrant user callable). No-ops unless the GC is active.
pub const keepaliveMark = value_mod.keepaliveMark;
pub const keepalivePush = value_mod.keepalivePush;
pub const keepalivePushSlice = value_mod.keepalivePushSlice;
pub const keepalivePushPairs = value_mod.keepalivePushPairs;
pub const keepalivePushCell = value_mod.keepalivePushCell;
pub const keepaliveRestore = value_mod.keepaliveRestore;
pub const gcUninstallKeepaliveRoot = value_mod.gcUninstallKeepaliveRoot;

// alloc_track (opt-in allocation accounting; KLIO_ALLOC_TRACK)
pub const allocTrackWrap = alloc_track_mod.wrap;
pub const allocTrackSnapshot = alloc_track_mod.snapshot;
pub const allocTrackReportPhase = alloc_track_mod.reportPhase;
pub const allocTrackReportStderr = alloc_track_mod.reportStderr;
pub const allocTrackIsActive = alloc_track_mod.isActive;
pub const AllocTrackSnap = alloc_track_mod.Snap;
pub const pageAllocator = alloc_track_mod.pageAllocator;
pub const allocTrackReportPageStderr = alloc_track_mod.reportPageStderr;

// value
pub const Value = value_mod.Value;
pub const StackFrame = value_mod.StackFrame;
pub const StackTraceData = value_mod.StackTraceData;
pub const StackRef = value_mod.StackRef;
pub const RuntimeError = value_mod.RuntimeError;
pub const EvalResult = value_mod.EvalResult;
pub const attachDeclaredElemTypes = value_mod.attachDeclaredElemTypes;
pub const MapViewKind = value_mod.MapViewKind;
pub const CollBacking = value_mod.CollBacking;
pub const CollBackingRef = value_mod.CollBackingRef;
pub const MapPair = value_mod.MapPair;
pub const MapEntries = value_mod.MapEntries;
pub const RangeKind = value_mod.RangeKind;
pub const NumericRank = value_mod.NumericRank;
pub const PrimitiveArrayKind = value_mod.PrimitiveArrayKind;
pub const PrimBuf = value_mod.PrimBuf;
pub const ArrayData = value_mod.ArrayData;
pub const ArrayStore = value_mod.ArrayStore;
pub const DelegateKind = value_mod.DelegateKind;
pub const SuspendBody = value_mod.SuspendBody;
pub const SuspendState = value_mod.SuspendState;
pub const SuspendTransition = value_mod.SuspendTransition;
pub const SuspendFrame = value_mod.SuspendFrame;
pub const PausedResume = value_mod.PausedResume;
pub const SuspendCallerCont = value_mod.SuspendCallerCont;
pub const HostSlotResult = value_mod.HostSlotResult;
pub const SequenceData = value_mod.SequenceData;
pub const SequenceSource = value_mod.SequenceSource;
pub const SeqOp = value_mod.SeqOp;
pub const BuilderState = value_mod.BuilderState;
pub const BuilderStateRef = value_mod.BuilderStateRef;
pub const MergedSource = value_mod.MergedSource;
pub const FROZEN_MOD_BIT = value_mod.FROZEN_MOD_BIT;
pub const SeqIterState = value_mod.SeqIterState;
pub const SeqIterStateRef = value_mod.SeqIterStateRef;
pub const IterCursor = value_mod.IterCursor;
pub const RegexData = value_mod.RegexData;
pub const MatchData = value_mod.MatchData;
pub const MatchGroupData = value_mod.MatchGroupData;
pub const ComparatorStep = value_mod.ComparatorStep;
pub const StringRef = value_mod.StringRef;
pub const StringData = value_mod.StringData;
pub const strInit = value_mod.strInit;
pub const strInitOwned = value_mod.strInitOwned;
pub const strMeta = value_mod.strMeta;
pub const ValueList = value_mod.ValueList;
pub const ValueBox = value_mod.ValueBox;
pub const ValueSlice = value_mod.ValueSlice;

// class
pub const ClassDef = class_mod.ClassDef;
pub const ImplicitReceiver = class_mod.ImplicitReceiver;
pub const SupertypeDelegate = class_mod.SupertypeDelegate;
pub const ClassParamDef = class_mod.ClassParamDef;
pub const TypeShape = class_mod.TypeShape;
pub const AnnotationArg = class_mod.AnnotationArg;
pub const AnnotationRecord = class_mod.AnnotationRecord;
pub const PropertyAnchors = class_mod.PropertyAnchors;
pub const MethodDef = class_mod.MethodDef;
pub const PropertyDef = class_mod.PropertyDef;
pub const InstanceData = class_mod.InstanceData;
pub const NativeState = class_mod.NativeState;
pub const NativeBox = class_mod.NativeBox;
pub const MethodHit = class_mod.MethodHit;
pub const PropertyHit = class_mod.PropertyHit;

// host
pub const StdlibFn = host_mod.StdlibFn;
pub const CallCtx = host_mod.CallCtx;
pub const IntrinsicHost = host_mod.IntrinsicHost;
pub const NoopHost = host_mod.NoopHost;
pub const HostResultU64 = host_mod.HostResultU64;
pub const BuilderStepResult = host_mod.BuilderStepResult;

// output
pub const Output = output_mod.Output;
pub const OutOp = output_mod.OutOp;
pub const RecordingSink = output_mod.RecordingSink;
pub const StdoutOutput = output_mod.StdoutOutput;
pub const CaptureOutput = output_mod.CaptureOutput;
pub const kotlinFloatToString = output_mod.kotlinFloatToString;
pub const kotlinDoubleToString = output_mod.kotlinDoubleToString;
pub const charUnitToString = output_mod.charUnitToString;
pub const coalesceSurrogates = float_fmt_mod.coalesceSurrogates;
pub const isWtf8SurrogateAt = float_fmt_mod.isWtf8SurrogateAt;
pub const wtf8SurrogateUnit = float_fmt_mod.wtf8SurrogateUnit;
pub const pushCharUnit = output_mod.pushCharUnit;
pub const charUnitsToString = output_mod.charUnitsToString;

// env
pub const Env = env_mod.Env;

// proc_env (portable process-environment access)
pub const procEnvGetVar = proc_env_mod.getVar;
pub const procEnvKlioHome = proc_env_mod.klioHome;
pub const procEnvIsSet = proc_env_mod.isSet;
pub const procEnvPutAllInto = proc_env_mod.putAllInto;

// clock (portable wall-clock / monotonic time / sleep)
pub const clockWallMillis = clock_mod.wallMillis;
pub const clockWallTime = clock_mod.wallTime;
pub const ClockWallTime = clock_mod.WallTime;
pub const clockMonotonicNanos = clock_mod.monotonicNanos;
pub const clockSleepMillis = clock_mod.sleepMillis;

// float_fmt
pub const floatToString = float_fmt_mod.floatToString;
pub const doubleToString = float_fmt_mod.doubleToString;

// threads (cross-thread name overrides + run-boundary sweep hooks)
pub const setThreadName = threads_mod.setThreadName;
pub const clearThreadName = threads_mod.clearThreadName;
pub const threadName = threads_mod.threadName;
pub const registerRunBoundaryHook = threads_mod.registerRunBoundaryHook;
pub const runBoundarySweep = threads_mod.runBoundarySweep;
pub const setThreadAbandonable = threads_mod.setThreadAbandonable;
pub const isThreadAbandonable = threads_mod.isThreadAbandonable;
pub const setWallBlockHook = threads_mod.setWallBlockHook;
pub const notifyWallBlock = threads_mod.notifyWallBlock;
pub const requestAbandon = threads_mod.requestAbandon;
pub const clearAbandon = threads_mod.clearAbandon;
pub const shouldAbandon = threads_mod.shouldAbandon;

// safety (host-protection backstops)
pub const startMemoryWatchdog = safety_mod.startMemoryWatchdog;
pub const startRunDeadline = safety_mod.startRunDeadline;
pub const runCapped = safety_mod.runCapped;
pub const CapResult = safety_mod.CapResult;
pub const runOnBigStack = safety_mod.runOnBigStack;
pub const runOnBigStackMainThread = safety_mod.runOnBigStackMainThread;
pub const runOnPersistentBigStack = safety_mod.runOnPersistentBigStack;
pub const currentRssKb = safety_mod.currentRssKb;
pub const INTERPRET_STACK_SIZE = safety_mod.INTERPRET_STACK_SIZE;

test {
    std.testing.refAllDecls(@This());
    _ = objcell;
    _ = value_mod;
    _ = class_mod;
    _ = host_mod;
    _ = output_mod;
    _ = env_mod;
    _ = proc_env_mod;
    _ = clock_mod;
    _ = float_fmt_mod;
    _ = safety_mod;
    _ = threads_mod;
    _ = alloc_track_mod;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const InstanceField = class_mod.InstanceData.Field;

fn makeClass(
    allocator: std.mem.Allocator,
    name: []const u8,
    is_data: bool,
    is_object: bool,
    is_enum: bool,
) !ObjRef(ClassDef) {
    const cd: ClassDef = .{
        .name = name,
        .fqn = name,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = is_data,
        .is_value = false,
        .is_object = is_object,
        .is_enum = is_enum,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(Env).init(allocator, Env.init(allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    };
    return ObjRef(ClassDef).init(allocator, cd);
}

test "plain instance display uses class at hex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cls = try makeClass(a, "Foo", false, false, false);
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = .empty,
        .outer = null,
        .identity = 0x2a,
        .native_state = null,
    });

    const s = try (Value{ .Instance = inst }).display(a);
    try testing.expectEqualStrings("Foo@2a", s);
}

test "data instance display unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cls = try makeClass(a, "D", true, false, false);
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = .empty,
        .outer = null,
        .identity = 99,
        .native_state = null,
    });

    const s = try (Value{ .Instance = inst }).display(a);
    try testing.expectEqualStrings("D()", s);
}

test "enum entries is_runtime_type matches both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var entry_items = try ValueList.init(a, .empty);
    {
        const g = entry_items.borrowMut();
        defer g.deinit();
        try g.get().append(a, .{ .Int = 1 });
    }
    const entries = Value{ .List = .{
        .items = entry_items,
        .mutable = false,
        .enum_entries = true,
        .backing = null,
    } };
    try testing.expect(entries.isRuntimeType("List"));
    try testing.expect(entries.isRuntimeType("EnumEntries"));
    try testing.expect(entries.isRuntimeType("Collection"));

    var plain_items = try ValueList.init(a, .empty);
    {
        const g = plain_items.borrowMut();
        defer g.deinit();
        try g.get().append(a, .{ .Int = 1 });
    }
    const plain = Value{ .List = .{
        .items = plain_items,
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    } };
    try testing.expect(plain.isRuntimeType("List"));
    try testing.expect(!plain.isRuntimeType("EnumEntries"));
}

test "enum entries keeps list type fqn for dispatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var items = try ValueList.init(a, .empty);
    {
        const g = items.borrowMut();
        defer g.deinit();
        try g.get().append(a, .{ .Int = 1 });
    }
    const entries = Value{ .List = .{
        .items = items,
        .mutable = false,
        .enum_entries = true,
        .backing = null,
    } };
    try testing.expectEqualStrings("kotlin.collections.List", entries.typeFqn());
}
