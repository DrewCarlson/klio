//! Run-time tables for code lowered from sema: per class, static, init unit
//! and native, indexed by the ids the bridge allocates. The VM reaches them
//! through `Module.resolved`; nothing in them is found by name.

const std = @import("std");
const runtime = @import("runtime");

const root_ir = @import("../ir.zig");
const ids = @import("ids.zig");
const class_mod = @import("class.zig");
const func_mod = @import("func.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassId = ids.ClassId;
const ConstId = ids.ConstId;
const FuncId = ids.FuncId;
const MethodSlotId = ids.MethodSlotId;
const NativeId = ids.NativeId;
const NO_FUNC = ids.NO_FUNC;
const SlotSeed = class_mod.SlotSeed;
const Func = func_mod.Func;
const Module = root_ir.Module;

/// An index the tables leave empty: a static with no init unit.
pub const NONE: u32 = std.math.maxInt(u32);

pub const Resolved = struct {
    /// By ClassId.
    classes: []ClassRt = &.{},
    /// By StaticId.
    statics: []StaticRt = &.{},
    init_units: []InitUnitRt = &.{},
    /// By FuncId: for a function the file facade declares (a top-level
    /// function, accessor or defaults bridge), the init unit of its file,
    /// which entering it runs first, as the JVM initializes a class before
    /// its static method runs. `NONE` for every other function.
    facade_unit: []const u32 = &.{},
    /// The init units of the files' `@EagerInitialization` properties, in
    /// file order: what the program's start runs before `main`, as
    /// Kotlin/Native initializes such a property when the program starts.
    eager_units: []const u32 = &.{},
    /// Names a function as a JVM stack frame does; null where no builder
    /// set one, and a frame then shows the function's FQN.
    frame_namer: ?FrameNamer = null,
    /// By NativeId.
    natives: []NativeRt = &.{},
    /// By FuncId: the native a bodyless declaration is bound to, else `.none`.
    func_native: []NativeId = &.{},
    /// By FuncId, for a declaration with a body: the host's fast path in
    /// front of it (`NativeRt.host_try`), which answers or declines into
    /// the body; `.none` for most.
    func_try: []const NativeId = &.{},
    /// By FuncId, for the root of a slot: the native a host value whose
    /// class has no implementation of the slot answers with (an iterator's
    /// `hasNext`, an entry's `key`), `.none` where the VM has none.
    host_slot: []const NativeId = &.{},
    /// By FuncId, for the root of a slot: its index in the vtable of every
    /// class, or in the table each class keeps for the interface declaring
    /// it (`slot_iface`); `NONE` for a function that roots no slot.
    slot_index: []const u32 = &.{},
    /// By FuncId, for the root of a slot an interface declares: that
    /// interface's `ClassId`; `NONE` for a slot a class declares.
    slot_iface: []const u32 = &.{},
    /// The base members natives call back into Kotlin through.
    well_known: WellKnownSlots = .initFill(null),
    /// The objects natives need a reference to.
    well_known_objects: WellKnownObjects = .initFill(null),
    /// The classes natives build instances of.
    well_known_classes: WellKnownClasses = .initFill(null),
    /// The top-level properties host fast paths read.
    well_known_statics: WellKnownStatics = .initFill(null),
    host_class: HostClasses = .{},
    /// The classes of the exceptions the VM raises itself.
    exceptions: Exceptions = .{},
    base: BaseClasses = .{},
    /// By ClassId: the class's generated serializer, when it has one.
    serializers: []const ?SerializerRt = &.{},
};

/// The init unit a call from `caller` into `callee` runs first: the unit of
/// the file whose facade declares `callee`, unless `caller` is code of that
/// same facade, which entering already initialized. `NONE` for none.
pub fn facadeEntry(r: *const Resolved, caller: FuncId, callee: FuncId) u32 {
    const units = r.facade_unit;
    if (callee.int() >= units.len) return NONE;
    const unit = units[callee.int()];
    if (unit == NONE) return unit;
    if (caller.int() < units.len and units[caller.int()] == unit) return NONE;
    return unit;
}

/// Classes of the base the host makes values of: a host `Result` a native
/// returns becomes a Kotlin one, and `coroutineContext` outside any
/// coroutine is `EmptyCoroutineContext`.
pub const BaseClasses = struct {
    empty_coroutine_context: ?ClassId = null,
    /// `kotlin.Result` over its `value`.
    result: ?ClassCtor = null,
    /// `kotlin.Result.Failure` over its `exception`.
    result_failure: ?ClassCtor = null,
    /// `kotlin.reflect.KlioType`, the run-time type a reified type
    /// parameter stands for, which a dynamic type test reads.
    ktype: ?KTypeLayout = null,
    /// The static of `CoroutineSingletons.COROUTINE_SUSPENDED`, which the
    /// host's suspension sentinel is to Kotlin code.
    coroutine_suspended: ?ids.StaticId = null,
    /// `ExceptionInInitializerError(message, thrown)`, which the use that
    /// runs an object's or a file's failing initializer raises over the
    /// throw, as the JVM does.
    init_failed: ?ClassCtor = null,
    /// `NoClassDefFoundError(message, cause)`, which every later use of an
    /// object or a file whose initialization failed raises.
    no_class_def: ?ClassCtor = null,
    /// `KlioMatchGroups(match)`, a host match's `groups`.
    match_groups: ?ClassCtor = null,
};

/// Where a `KlioType` holds its classifier (a `KClass`) and whether it is
/// nullable.
pub const KTypeLayout = struct { class: ClassId, classifier: u32, nullable: u32 };

/// A class and the constructor that builds it.
pub const ClassCtor = Raised;

const prim_array_kinds = @typeInfo(runtime.PrimitiveArrayKind).@"enum".fields.len;

/// The class of each host value kind, so a call or a type test on a host
/// value finds its class by id. Null where the base declares none.
pub const HostClasses = struct {
    unit: ?ClassId = null,
    boolean: ?ClassId = null,
    char: ?ClassId = null,
    byte: ?ClassId = null,
    short: ?ClassId = null,
    int: ?ClassId = null,
    long: ?ClassId = null,
    float: ?ClassId = null,
    double: ?ClassId = null,
    ubyte: ?ClassId = null,
    ushort: ?ClassId = null,
    uint: ?ClassId = null,
    ulong: ?ClassId = null,
    string: ?ClassId = null,
    /// `Array<T>`.
    array: ?ClassId = null,
    /// By `runtime.PrimitiveArrayKind`: `IntArray`, `LongArray`, ...
    prim_array: [prim_array_kinds]?ClassId = @splat(null),
    /// By arity: the `FunctionN` class a closure of that arity is.
    function: []const ClassId = &.{},
    /// By arity: the root slot of `FunctionN.invoke`.
    invoke_slot: []const MethodSlotId = &.{},
    /// By arity: `SuspendFunctionN`, which a function value of that arity
    /// is too, since the VM suspends by snapshotting frames.
    suspend_function: []const ClassId = &.{},
    /// By arity: the root slot of `SuspendFunctionN.invoke`, which a class
    /// extending a suspend function type implements.
    suspend_invoke_slot: []const MethodSlotId = &.{},
    /// By arity (the arguments `get` takes): `KProperty0`, `KProperty1`, ...
    property: []const ClassId = &.{},
    /// By arity: `KMutableProperty0`, `KMutableProperty1`, ...
    mutable_property: []const ClassId = &.{},
    /// By arity: the root slot of `KPropertyN.get`, which a property
    /// reference answers by calling its getter.
    property_get: []const MethodSlotId = &.{},
    /// By arity: the root slot of `KMutablePropertyN.set`, answered by the
    /// reference's setter.
    property_set: []const MethodSlotId = &.{},
    /// The root slot of the getter of `KCallable.name`, which a callable
    /// reference answers with its name.
    callable_name: ?MethodSlotId = null,
    /// The root slots of `Any.equals` and `Any.hashCode`, which a callable
    /// reference answers by its target and bound receiver.
    equals_slot: ?MethodSlotId = null,
    hash_code_slot: ?MethodSlotId = null,
    /// The root slot of `Any.toString`, which a closure answers with what
    /// kotlinc's lambda or reference prints.
    to_string_slot: ?MethodSlotId = null,
    /// `Map.Entry`, and the root slots of its `key` and `value` getters: a
    /// host entry compares with an instance implementing it through them.
    map_entry: ?ClassId = null,
    entry_key_slot: ?MethodSlotId = null,
    entry_value_slot: ?MethodSlotId = null,
    /// `kotlin.collections.List`, `Set` and `Map`: a host collection compares
    /// with an instance implementing the same one element by element.
    list: ?ClassId = null,
    set: ?ClassId = null,
    map: ?ClassId = null,
    /// By value tag, the class a host value of that kind is an instance of
    /// (a list is an `ArrayList`, a string builder a `StringBuilder`), for
    /// its type tests; the host serves its members.
    by_tag: [value_tags]?ClassId = @splat(null),
    /// By `runtime.RangeKind`: `IntRange`, `LongRange`, `CharRange`, ...;
    /// and the progressions a stepped range is.
    range: [range_kinds]?ClassId = @splat(null),
    progression: [range_kinds]?ClassId = @splat(null),
};

const value_tags = @typeInfo(std.meta.Tag(Value)).@"enum".fields.len;
const range_kinds = @typeInfo(runtime.RangeKind).@"enum".fields.len;

/// A class the VM throws: an instance seeded like any other, then built by
/// `ctor`, which takes the instance and the message (`String?`).
pub const Raised = struct { class: ClassId, ctor: FuncId };

pub const Exceptions = struct {
    /// A null receiver, `!!` on null, `null as T` for a non-null `T`.
    null_pointer: ?Raised = null,
    class_cast: ?Raised = null,
    /// Integer division or remainder by zero.
    arithmetic: ?Raised = null,
    /// A `lateinit` property read before its first write.
    uninitialized_property: ?Raised = null,
    index_out_of_bounds: ?Raised = null,
    /// Thrown for an array index when set, else `index_out_of_bounds`.
    array_index_out_of_bounds: ?Raised = null,
    /// Thrown for a string index when set, else `index_out_of_bounds`.
    string_index_out_of_bounds: ?Raised = null,
    /// By class FQN, every throwable class with a `(String?)` constructor: a
    /// native throws a host exception by the name of its class, and the VM
    /// raises an instance of that class instead, until natives throw by id.
    by_fqn: std.StringHashMapUnmanaged(Raised) = .empty,
};

pub const ClassRt = struct {
    /// Its `ir_class` is this class's id.
    def: ObjRef(runtime.ClassDef),
    /// One per field slot. The def's `layout_slots` names them.
    seeds: []const SlotSeed = &.{},
    /// Objects and companions: the constructor `LoadObject` runs.
    object_ctor: u32 = NO_FUNC,
    /// Objects and companions: the singleton as a failed initialization
    /// names it, `object pkg.Outer.Inner` or `object pkg.Box.Companion`.
    init_name: []const u8 = "",
    /// A class extending one whose constructor is the host's (a program's
    /// `ArrayList` subclass): the slot holding the host value its
    /// superclass constructor made, which the host's members act on.
    host_slot: u32 = NONE,
    /// The class's implementation of each slot a class declares, by
    /// `Resolved.slot_index`, with the root it serves: an index means one
    /// slot only down the chain of the class declaring it, so a class
    /// outside that chain holds another there.
    vtable: []const VSlot = &.{},
    /// Per interface whose slots the class implements: its implementation
    /// of each, by `Resolved.slot_index`.
    itables: []const ITable = &.{},
    /// A `Throwable`: an instance takes the stack trace of its
    /// construction, as the JVM's `fillInStackTrace` does.
    throwable: bool = false,
    /// Whether an instance keeps `Any`'s `hashCode` and `equals`, so a hash
    /// map finds it by identity (`eval/intrinsics.zig`): 0 before the first
    /// ask, 1 no, 2 yes.
    identity_keyed: std.atomic.Value(u8) = .init(0),
};

/// A vtable entry: the root a slot is for and the class's implementation,
/// `NO_FUNC` in both where the class has none.
pub const VSlot = struct { root: u32 = NO_FUNC, func: u32 = NO_FUNC };

/// A class's implementations of one interface's slots.
pub const ITable = struct { iface: ClassId, entries: []const u32 };

pub const StaticRt = struct {
    /// The init unit that writes it, `NONE` for one no unit initializes.
    unit: u32,
    seed: SlotSeed,
    /// For display.
    name: []const u8,
};

pub const InitUnitRt = struct {
    func: FuncId,
    /// The JVM class the unit initializes, as a failure names it: a file's
    /// facade (`pkg.MainKt`) or an enum class (`pkg.Outer$Kind`).
    name: []const u8 = "",
};

pub const NativeRt = struct {
    func: runtime.StdlibFn,
    /// For display.
    name: []const u8,
    /// The table `func` came from and its key there, so a loaded image
    /// binds the same host function (`bridge.rebindNative`). `unbound`: a
    /// compiler intrinsic, which `op` names.
    table: NativeTable = .unbound,
    key: []const u8 = "",
    /// A member the VM implements over a host value (`table` is
    /// `.members`, `key` its `hostKey`).
    host_fn: ?HostFn = null,
    /// A fast path the VM puts in front of a declaration's Kotlin body
    /// (`table` is `.tries`, `key` its `hostKey`).
    host_try: ?HostTry = null,
    /// Natives take a vararg's elements in its place and no type values:
    /// how many reified type values end the run, and where the vararg
    /// array sits, counted back from the last value argument.
    reified: u16 = 0,
    vararg_back: ?u16 = null,
    /// A compiler intrinsic the host answers from its run state.
    op: HostOp = .none,
    /// A companion member the host implements as its class's static: the
    /// companion the call passes first is not the native's.
    static_: bool = false,
    /// An instance member: its receiver comes first, and an instance
    /// holding a host value (`ClassRt.host_slot`) passes that value.
    receiver: bool = false,
    /// The root slot of the instance member the native implements, `NONE`
    /// for any other native. A call site the lowering bound to the native
    /// statically (a member of a class common Kotlin declares final, which
    /// the JVM leaves open: `ArrayList`, `HashMap`) runs a Kotlin receiver's
    /// own override of that slot instead.
    slot: u32 = NONE,
    /// The stdlib function a call runs straight, with nothing around it, found on the
    /// first such call and kept (the VM's `callNativeDirect`): 0 before it, 1 for a native
    /// that has none, else the function.
    direct: std.atomic.Value(usize) = .init(0),
    /// What the native is as a few instructions (`eval/intrinsics.zig`), found on the first
    /// ask and kept: 0 before it.
    intrinsic: std.atomic.Value(u8) = .init(0),
};

/// The binding's tables a native is found in: by declaration FQN or host
/// symbol, by class FQN for a host-backed class's constructor, and by
/// `hostKey` for a member the VM implements.
pub const NativeTable = enum { natives, constructors, members, tries, unbound };

/// A member the VM implements over a host value (a list's `add`, an
/// iterator's `next`): `host` is the VM's host, `args` the receiver and
/// then the arguments.
pub const HostFn = *const fn (host: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!root_ir.eval.EvalResult;

/// The VM's member implementations, by `hostKey`.
pub const HostFnResolver = *const fn (key: []const u8) ?HostFn;

/// A fast path the host puts in front of a declaration's Kotlin body (the
/// persistent collections' builders): its answer, or null when it declines
/// and the body runs.
pub const HostTry = *const fn (host: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?root_ir.eval.EvalResult;

/// The VM's fast paths, by `hostKey` of the declaration they front.
pub const HostTryResolver = *const fn (key: []const u8) ?HostTry;

/// The key a member the VM implements is found by: the declaration's FQN,
/// behind `get ` or `set ` for a property's accessor.
pub fn hostKey(buf: []u8, fqn: []const u8, kind: MemberKind) ?[]const u8 {
    const prefix = switch (kind) {
        .function => "",
        .getter => "get ",
        .setter => "set ",
    };
    return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, fqn }) catch null;
}

/// Names a function as a stack frame shows it, its Kotlin qualified
/// declaration (`pkg.Outer.f`), for a throwable's trace; null where the
/// namer cannot say.
pub const FrameNamer = struct {
    ctx: *anyopaque,
    name: *const fn (ctx: *anyopaque, f: FuncId) ?[]const u8,
};

/// The compiler intrinsics the host answers: `coroutineContext` is the
/// active coroutine's context; `generated_serializer` is the serializer
/// the serialization plugin generates for a class (`Resolved.serializers`);
/// `stack_frames` is the frames a throwable's throw captured, each
/// rendered `pkg.f(File.kt:line)`; `print_err` writes a line to standard
/// error.
/// `missing_symbol`: an `external` function whose `@ExternalSymbolName`
/// names a host symbol no binding registers; a call fails naming both.
pub const HostOp = enum { none, coroutine_context, generated_serializer, stack_frames, print_err, missing_symbol };

/// Where a class's generated `serializer(...)` lives: on its companion, or
/// on an object itself.
pub const SerializerRt = struct { holder: ClassId, func: FuncId, arity: u16 };

/// A member as a function, or a property's getter or setter.
pub const MemberKind = enum { function, getter, setter };

/// By `runtime.WellKnown`: the slot of the base member a native calls on a
/// value it was given (`toString` when it prints one, `compare` of a
/// comparator it sorts with), so the value's class answers with its own
/// implementation. Null where the base declares none.
pub const WellKnownSlots = std.enums.EnumArray(runtime.WellKnown, ?MethodSlotId);

/// By `runtime.WellKnownObject`: the object's class, null where no source
/// declares it.
pub const WellKnownObjects = std.enums.EnumArray(runtime.WellKnownObject, ?ClassId);

/// By `runtime.WellKnownClass`: the class and its primary constructor,
/// null where no source declares it.
pub const WellKnownClasses = std.enums.EnumArray(runtime.WellKnownClass, ?ClassCtor);

/// By `runtime.WellKnownStatic`: the property's static, null where no
/// source declares it.
pub const WellKnownStatics = std.enums.EnumArray(runtime.WellKnownStatic, ?ids.StaticId);

/// What a closure lowered from sema is, beside the function its body runs.
pub const Callable = union(enum) {
    /// A lambda or anonymous function: its body takes the call's arguments
    /// as its parameters and reads its captures with `LoadCapture`.
    lambda,
    /// A function reference over its adapter; the target answers equality
    /// and `name`. A bound receiver is capture 0.
    function_ref: FuncId,
    /// A property reference over its getter.
    property_ref: PropertyRef,
};

pub const PropertyRef = struct {
    /// `NO_FUNC` for a read-only property.
    setter: u32 = NO_FUNC,
    name: ConstId,
    /// The receiver is bound: it is capture 0 and the first argument the
    /// getter and setter take.
    bound: bool = false,
};

/// A closure as the host's side table records it.
pub const ClosureBody = struct {
    id: u64,
    func: *const Func,
    /// The module `func` belongs to.
    module: *const Module,
    /// A sub-module the body was lowered into, null for the main module.
    owning: ?*const Module = null,
    kind: Callable,

    /// The number of arguments a call of the closure passes.
    pub fn arity(self: ClosureBody) usize {
        return switch (self.kind) {
            .property_ref => |p| self.func.params.len -| @intFromBool(p.bound),
            else => self.func.params.len,
        };
    }
};

/// `failed`: the unit's initialization threw; every later use throws too.
pub const UnitState = enum(u8) { idle, running, done, failed };

/// Per VM run: owned by the host, reached by `host.resolvedState()` behind
/// a shared handle, so every thread of the run sees one set of statics.
pub const ResolvedState = struct {
    /// By StaticId. Read with `loadStatic` and written with `storeStatic`,
    /// neither of which takes the state's lock.
    statics: []Value,
    /// Odd while a static store is in flight. A read copies a static between
    /// two equal even readings, so it never pairs one store's tag with
    /// another's payload; stores take turns on it.
    static_seq: std.atomic.Value(u32) = .init(0),
    /// By init unit.
    unit_state: []UnitState,
    /// By init unit: what a failed unit's initializer threw, which every
    /// later use's error names.
    unit_failure: []?Value = &.{},
    /// By init unit: the thread running its initializer, while it runs.
    unit_owner: []u64 = &.{},
    /// By ClassId.
    singletons: []?Value,
    /// By ClassId: where an object's initialization is, as `unit_state`
    /// says it of a unit. `done` is stored last, so a reader that loads it
    /// finds the finished singleton without the lock.
    object_state: []UnitState = &.{},
    /// By ClassId: the thread running an object's initializer, while it
    /// runs. That thread reads the instance it is building; any other waits.
    object_owner: []u64 = &.{},
    /// By FuncId: the closure of a lambda literal that captures nothing,
    /// one instance for every evaluation, as Kotlin makes it.
    lambdas: std.AutoHashMapUnmanaged(u32, Value) = .empty,
    /// By ClassId: the objects whose initialization threw, with what it
    /// threw, which every later use throws for.
    failed_objects: std.AutoHashMapUnmanaged(u32, Value) = .empty,
    /// Static `i`, copied whole. The collector never runs inside
    /// `storeStatic`, which holds no safe point.
    pub fn loadStatic(self: *const ResolvedState, i: usize) Value {
        const words: *const [2]u64 = @ptrCast(&self.statics[i]);
        while (true) {
            const before = self.static_seq.load(.acquire);
            if (before & 1 == 0) {
                // Acquire loads keep the second reading after both words, and
                // one that saw a word of a later store sees its odd sequence.
                const w0 = @atomicLoad(u64, &words[0], .acquire);
                const w1 = @atomicLoad(u64, &words[1], .acquire);
                if (self.static_seq.load(.monotonic) == before) {
                    var out: Value = undefined;
                    const dst: *[2]u64 = @ptrCast(&out);
                    dst[0] = w0;
                    dst[1] = w1;
                    return out;
                }
            }
            std.atomic.spinLoopHint();
        }
    }

    /// Stores `v` in static `i` and answers the value it replaced, taking no
    /// reference and no lock: stores take turns on the sequence. A value
    /// that holds a cell records the barrier for this static alone, so the
    /// next collection retraces the statics stored since the last one and
    /// not the whole state; a scalar makes no edge and records nothing. The
    /// remembered set is read only inside a stop, and no stop falls between
    /// the barrier and the store.
    pub fn storeStatic(self: *ResolvedState, i: usize, v: Value) Value {
        const h = self.cellHdr();
        if (h.gc_gen != 0 and !v.isPrimitive()) runtime.gc.writeBarrierAt(h, i, traceStaticsRange);
        var seq = self.static_seq.load(.monotonic);
        while (true) {
            if (seq & 1 == 0) {
                seq = self.static_seq.cmpxchgWeak(seq, seq + 1, .acquire, .monotonic) orelse break;
            } else {
                std.atomic.spinLoopHint();
                seq = self.static_seq.load(.monotonic);
            }
        }
        const old = self.statics[i];
        // Release stores: a read that sees either word also sees the odd sequence.
        const src: *const [2]u64 = @ptrCast(&v);
        const words: *[2]u64 = @ptrCast(&self.statics[i]);
        @atomicStore(u64, &words[0], src[0], .release);
        @atomicStore(u64, &words[1], src[1], .release);
        self.static_seq.store(seq + 2, .release);
        return old;
    }

    fn cellHdr(self: *ResolvedState) *runtime.gc.GcHeader {
        const cb: *StateRef.Cell = @alignCast(@fieldParentPtr("data", self));
        return &cb.hdr;
    }

    /// Statics `lo` through `hi` of the state whose cell is `h`, read as
    /// `loadStatic` reads them: a mark may run beside a store.
    fn traceStaticsRange(h: *runtime.gc.GcHeader, m: *runtime.gc.Marker, lo: u32, hi: u32) void {
        const cb: *StateRef.Cell = @fieldParentPtr("hdr", @as(*align(16) runtime.gc.GcHeader, @alignCast(h)));
        const self = &cb.data;
        if (lo >= self.statics.len) return;
        const end = @min(self.statics.len, @as(usize, hi) + 1);
        for (lo..end) |i| self.loadStatic(i).gcMark(m);
    }

    pub fn gcTrace(self: *const ResolvedState, m: *runtime.gc.Marker) void {
        for (0..self.statics.len) |i| self.loadStatic(i).gcMark(m);
        for (self.singletons) |s| if (s) |v| v.gcMark(m);
        for (self.unit_failure) |f| if (f) |v| v.gcMark(m);
        var it = self.lambdas.valueIterator();
        while (it.next()) |v| v.gcMark(m);
        var fit = self.failed_objects.valueIterator();
        while (fit.next()) |v| v.gcMark(m);
    }

    pub fn gcFinalize(self: *ResolvedState, a: Allocator) void {
        self.freeArrays(a);
    }

    pub fn deinit(self: *ResolvedState, a: Allocator) void {
        for (self.statics) |v| v.release(a);
        for (self.singletons) |s| if (s) |v| v.release(a);
        for (self.unit_failure) |f| if (f) |v| v.release(a);
        var it = self.lambdas.valueIterator();
        while (it.next()) |v| v.release(a);
        var fit = self.failed_objects.valueIterator();
        while (fit.next()) |v| v.release(a);
        self.freeArrays(a);
    }

    fn freeArrays(self: *ResolvedState, a: Allocator) void {
        a.free(self.statics);
        a.free(self.unit_state);
        a.free(self.unit_failure);
        a.free(self.unit_owner);
        a.free(self.singletons);
        a.free(self.object_state);
        a.free(self.object_owner);
        self.lambdas.deinit(a);
        self.failed_objects.deinit(a);
        self.statics = &.{};
        self.unit_state = &.{};
        self.unit_failure = &.{};
        self.unit_owner = &.{};
        self.singletons = &.{};
        self.object_state = &.{};
        self.object_owner = &.{};
        self.lambdas = .empty;
        self.failed_objects = .empty;
    }
};

pub const StateRef = ObjRef(ResolvedState);

/// The class of `v` in the tables, or null for a value they do not cover.
/// A closure's class needs the host's side table and is not answered here.
pub fn classOf(r: *const Resolved, v: *const Value) ?ClassId {
    const h = &r.host_class;
    return switch (v.*) {
        // Written once when the instance is made, from its def's id, so
        // read without a borrow.
        .Instance => |inst| blk: {
            const id = inst.asPtrConst().class_id;
            break :blk if (id == std.math.maxInt(u32)) null else ClassId.from(id);
        },
        .Unit => h.unit,
        .Bool => h.boolean,
        .Char => h.char,
        .Byte => h.byte,
        .Short => h.short,
        .Int => h.int,
        .Long => h.long,
        .Float => h.float,
        .Double => h.double,
        .UByte => h.ubyte,
        .UShort => h.ushort,
        .UInt => h.uint,
        .ULong => h.ulong,
        .String => h.string,
        .Array => |arr| if (arr.primKind()) |k| h.prim_array[@intFromEnum(k)] else h.array,
        // A name-only property reference: a local delegated property's `KProperty0`.
        .PropertyRef => if (h.property.len != 0) h.property[0] else null,
        .Range => |rd| if (rd.progression) h.progression[@intFromEnum(rd.kind)] else h.range[@intFromEnum(rd.kind)],
        // A host exception is replaced by an instance before code lowered
        // from sema sees it; one that got through is a `Throwable`.
        .Exception => |e| blk: {
            const g = e.fqn.borrow();
            defer g.deinit();
            break :blk if (r.exceptions.by_fqn.get(g.get().bytes)) |raised| raised.class else h.by_tag[@intFromEnum(std.meta.activeTag(v.*))];
        },
        else => h.by_tag[@intFromEnum(std.meta.activeTag(v.*))],
    };
}

/// The class a `KClass` value names: a `.Class` whose def the bridge made.
pub fn classOfKClass(v: *const Value) ?ClassId {
    if (v.* != .Class) return null;
    const g = v.Class.borrow();
    defer g.deinit();
    const raw = g.get().ir_class;
    return if (raw == std.math.maxInt(u32)) null else ClassId.from(raw);
}

/// The implementation class `cls` has for the slot `slot` roots, from its
/// vtable or the table it keeps for the slot's interface; null where it
/// has none.
pub fn slotTarget(r: *const Resolved, cls: ClassId, slot: MethodSlotId) ?FuncId {
    const root = slot.int();
    if (root >= r.slot_index.len or cls.int() >= r.classes.len) return null;
    const idx = r.slot_index[root];
    if (idx == NONE) return null;
    const c = &r.classes[cls.int()];
    const iface = r.slot_iface[root];
    if (iface == NONE) {
        // A class not descended from the slot's class keeps another slot
        // at its index.
        if (idx >= c.vtable.len or c.vtable[idx].root != root) return null;
        const f = c.vtable[idx].func;
        return if (f == NO_FUNC) null else FuncId.from(f);
    }
    const entries = for (c.itables) |t| {
        if (t.iface.int() == iface) break t.entries;
    } else return null;
    if (idx >= entries.len or entries[idx] == NO_FUNC) return null;
    return FuncId.from(entries[idx]);
}

/// Whether an instance of `sub` is a `sup`.
pub fn isA(m: *const Module, sub: ClassId, sup: ClassId) bool {
    return sub == sup or m.classIsA(sub, sup);
}

/// Whether `sup` is the `FunctionN` of suspend function class `sub`'s
/// arity plus one, the form that takes the continuation.
pub fn isContinuationForm(r: *const Resolved, sub: ClassId, sup: ClassId) bool {
    const h = &r.host_class;
    for (h.suspend_function, 0..) |f, k| {
        if (f != sub) continue;
        return k + 1 < h.function.len and h.function[k + 1] == sup;
    }
    return false;
}

/// A fresh run's state: every static holds its seed, every unit is idle and
/// no singleton exists.
pub fn stateInit(a: Allocator, r: *const Resolved) Allocator.Error!ResolvedState {
    const statics = try a.alloc(Value, r.statics.len);
    errdefer a.free(statics);
    for (statics, r.statics) |*v, st| v.* = seedValue(st.seed);
    const units = try a.alloc(UnitState, r.init_units.len);
    errdefer a.free(units);
    @memset(units, .idle);
    const singletons = try a.alloc(?Value, r.classes.len);
    @memset(singletons, null);
    const failures = try a.alloc(?Value, r.init_units.len);
    @memset(failures, null);
    const unit_owner = try a.alloc(u64, r.init_units.len);
    @memset(unit_owner, 0);
    const object_state = try a.alloc(UnitState, r.classes.len);
    @memset(object_state, .idle);
    const object_owner = try a.alloc(u64, r.classes.len);
    @memset(object_owner, 0);
    return .{
        .statics = statics,
        .unit_state = units,
        .unit_failure = failures,
        .unit_owner = unit_owner,
        .singletons = singletons,
        .object_state = object_state,
        .object_owner = object_owner,
    };
}

/// `stateInit` behind a shared handle.
pub fn stateNew(a: Allocator, r: *const Resolved) Allocator.Error!StateRef {
    var st = try stateInit(a, r);
    errdefer st.freeArrays(a);
    return StateRef.init(a, st);
}

/// The value a slot seed stands for.
pub fn seedValue(seed: SlotSeed) Value {
    return switch (seed) {
        .null_ref => .Null,
        .int => .{ .Int = 0 },
        .long => .{ .Long = 0 },
        .short => .{ .Short = 0 },
        .byte => .{ .Byte = 0 },
        .float => .{ .Float = 0.0 },
        .double => .{ .Double = 0.0 },
        .boolean => .{ .Bool = false },
        .char => .{ .Char = 0 },
    };
}

/// An instance of `class` with every slot holding its seed, before any
/// constructor runs. The caller owns the one reference.
pub fn instantiate(a: Allocator, r: *const Resolved, class: ClassId) Allocator.Error!Value {
    const rt = &r.classes[class.int()];
    const inst = try InstanceData.newTrailing(a, rt.def.clone(), class.int(), rt.seeds.len);
    for (rt.seeds, inst.cell.data.slots) |seed, *v| v.* = seedValue(seed);
    return .{ .Instance = inst };
}

test "a fresh state seeds its statics and starts every unit idle" {
    const a = std.testing.allocator;
    var statics = [_]StaticRt{
        .{ .unit = 0, .seed = .int, .name = "a" },
        .{ .unit = 0, .seed = .null_ref, .name = "b" },
    };
    var units = [_]InitUnitRt{.{ .func = FuncId.from(0) }};
    const r: Resolved = .{ .statics = &statics, .init_units = &units };
    const st = try stateNew(a, &r);
    defer st.deinit();
    const g = st.borrow();
    defer g.deinit();
    try std.testing.expectEqual(@as(i32, 0), g.get().statics[0].Int);
    try std.testing.expect(g.get().statics[1] == .Null);
    try std.testing.expectEqual(UnitState.idle, g.get().unit_state[0]);
    try std.testing.expectEqual(@as(usize, 0), g.get().singletons.len);
}

test "a static store is read back whole, and the sequence is even between stores" {
    const a = std.testing.allocator;
    var statics = [_]StaticRt{.{ .unit = NONE, .seed = .int, .name = "a" }};
    const r: Resolved = .{ .statics = &statics };
    const st = try stateNew(a, &r);
    defer st.deinit();
    const s = &st.cell.data;
    try std.testing.expectEqual(Value{ .Int = 0 }, s.loadStatic(0));
    const old = s.storeStatic(0, .{ .Long = -5 });
    try std.testing.expectEqual(Value{ .Int = 0 }, old);
    try std.testing.expectEqual(Value{ .Long = -5 }, s.loadStatic(0));
    try std.testing.expectEqual(@as(u32, 2), s.static_seq.load(.monotonic));
}

test "a static store records a barrier over that static alone, and a scalar none" {
    const a = std.testing.allocator;
    var statics = [_]StaticRt{
        .{ .unit = NONE, .seed = .int, .name = "a" },
        .{ .unit = NONE, .seed = .null_ref, .name = "b" },
        .{ .unit = NONE, .seed = .null_ref, .name = "c" },
    };
    const r: Resolved = .{ .statics = &statics };
    const st = try stateNew(a, &r);
    defer st.deinit();
    const hdr = &st.cell.hdr;
    defer runtime.gc.forgetRanges(&.{.{ .start = @intFromPtr(hdr), .len = @sizeOf(runtime.gc.GcHeader) }});
    hdr.gc_gen = 1;
    hdr.gc_remembered = false;
    const s = &st.cell.data;
    _ = s.storeStatic(0, .{ .Int = 9 });
    try std.testing.expect(!hdr.gc_remembered);
    try std.testing.expectEqual(@as(u16, 0), hdr.gc_range);
    const text = try runtime.strInit(a, "kept");
    defer text.deinit();
    _ = s.storeStatic(2, .{ .String = text });
    // Remembered by range, not whole: a minor retraces static 2 alone.
    try std.testing.expect(!hdr.gc_remembered);
    try std.testing.expect(hdr.gc_range != 0);
    var m: runtime.gc.Marker = .{ .epoch = 77, .arena = a };
    defer m.grey.deinit(a);
    ResolvedState.traceStaticsRange(hdr, &m, 2, 2);
    try std.testing.expectEqual(@as(usize, 77), text.cell.hdr.gc_mark);
    _ = s.storeStatic(2, .Null);
}

test "a primitive value's class comes from the host table" {
    var r: Resolved = .{ .host_class = .{ .int = ClassId.from(7), .array = ClassId.from(8) } };
    r.host_class.prim_array[@intFromEnum(runtime.PrimitiveArrayKind.Long)] = ClassId.from(9);
    const v: Value = .{ .Int = 3 };
    try std.testing.expectEqual(ClassId.from(7), classOf(&r, &v).?);
    const s: Value = .Null;
    try std.testing.expect(classOf(&r, &s) == null);

    const a = std.testing.allocator;
    const longs = try runtime.ArrayData.initPacked(a, .Long, &.{ .{ .Long = 1 }, .{ .Long = 2 } });
    defer longs.Array.deinitStorage();
    try std.testing.expectEqual(ClassId.from(9), classOf(&r, &longs).?);
}

