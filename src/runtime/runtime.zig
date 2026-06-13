//! Shared runtime types for the interpreter and the stdlib.
//!
//! `Value`, `RuntimeError`, the `Output` sink, and `Env` live here so that
//! the stdlib can express Rust-native intrinsics in terms of the same
//! types the interpreter evaluates against, without either depending on
//! the other. Mirrors the Rust crate's `lib.rs` `pub use ...::*`.

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

// objcell
pub const ObjRef = objcell.ObjRef;
pub const ObjGuard = objcell.ObjGuard;
pub const ObjGuardMut = objcell.ObjGuardMut;
pub const ControlBlock = objcell.ControlBlock;
pub const BorrowMutError = objcell.BorrowMutError;
pub const SpinMutex = objcell.SpinMutex;
pub const setReclaim = objcell.setReclaim;
pub const reclaimEnabled = objcell.reclaimEnabled;

// value
pub const Value = value_mod.Value;
pub const RuntimeError = value_mod.RuntimeError;
pub const EvalResult = value_mod.EvalResult;
pub const attachDeclaredElemTypes = value_mod.attachDeclaredElemTypes;
pub const MapViewKind = value_mod.MapViewKind;
pub const MapBacking = value_mod.MapBacking;
pub const MapPair = value_mod.MapPair;
pub const MapEntries = value_mod.MapEntries;
pub const RangeKind = value_mod.RangeKind;
pub const NumericRank = value_mod.NumericRank;
pub const PrimitiveArrayKind = value_mod.PrimitiveArrayKind;
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
pub const RegexData = value_mod.RegexData;
pub const MatchData = value_mod.MatchData;
pub const MatchGroupData = value_mod.MatchGroupData;
pub const ComparatorStep = value_mod.ComparatorStep;
pub const StringRef = value_mod.StringRef;
pub const ValueList = value_mod.ValueList;
pub const ValueSlice = value_mod.ValueSlice;

// class
pub const ClassDef = class_mod.ClassDef;
pub const SupertypeDelegate = class_mod.SupertypeDelegate;
pub const ClassParamDef = class_mod.ClassParamDef;
pub const TypeShape = class_mod.TypeShape;
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

// output
pub const Output = output_mod.Output;
pub const OutOp = output_mod.OutOp;
pub const RecordingSink = output_mod.RecordingSink;
pub const StdoutOutput = output_mod.StdoutOutput;
pub const CaptureOutput = output_mod.CaptureOutput;
pub const kotlinFloatToString = output_mod.kotlinFloatToString;
pub const kotlinDoubleToString = output_mod.kotlinDoubleToString;
pub const charUnitToString = output_mod.charUnitToString;
pub const pushCharUnit = output_mod.pushCharUnit;
pub const charUnitsToString = output_mod.charUnitsToString;

// env
pub const Env = env_mod.Env;

// proc_env (portable process-environment access)
pub const procEnvGetVar = proc_env_mod.getVar;
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
pub const requestAbandon = threads_mod.requestAbandon;
pub const clearAbandon = threads_mod.clearAbandon;
pub const shouldAbandon = threads_mod.shouldAbandon;

// safety (host-protection backstops)
pub const startMemoryWatchdog = safety_mod.startMemoryWatchdog;
pub const startRunDeadline = safety_mod.startRunDeadline;
pub const runCapped = safety_mod.runCapped;
pub const CapResult = safety_mod.CapResult;
pub const runOnBigStack = safety_mod.runOnBigStack;
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
}

// -------------------------------------------------------------------------
// Tests (mirrors the Rust crate's `lib.rs` `mod tests`)
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
        .enum_class = try StringRef.init(a, "Color"),
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
        .enum_class = null,
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
        .enum_class = try StringRef.init(a, "Color"),
        .backing = null,
    } };
    try testing.expectEqualStrings("kotlin.collections.List", entries.typeFqn());
}
