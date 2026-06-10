//! IR-native interpreter.
//!
//! This module executes a frozen `ir.Module` end-to-end with no AST
//! evaluator and no callback into a tree walker. The `Vm` grows until
//! every Kotlin shape we support has a Vm-native execution path.
//!
//! Module construction goes through `ir.lower` directly; the driver
//! parses + type-checks via the shared front-end modules and hands the
//! resulting AST to this module's `build_module`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const span = @import("span");
const stdlib = @import("stdlib");
const diagnostics = @import("diagnostics");

const Allocator = std.mem.Allocator;

pub const Output = runtime.Output;

pub const build = @import("build.zig");

const vmhost = @import("vm/vmhost.zig");
const run_mod = @import("vm/run.zig");

pub const VmHost = vmhost.VmHost;
pub const VmIntrinsicHost = vmhost.VmIntrinsicHost;

/// Assert-empty + clear the process-wide receiver/coroutine thread-locals at a
/// run boundary. Called by `Vm.deinit` and by the public runners so leaked
/// cross-run state is a loud Debug failure.
pub const resetReceiverThreadLocals = vmhost.resetReceiverThreadLocals;

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const HostBindings = stdlib.HostBindings;
const StdlibFn = stdlib.StdlibFn;
const Module = ir.Module;
pub const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const RuntimeError = runtime.RuntimeError;

/// Runtime-lowered method bodies for anonymous-object / local classes,
/// keyed by `(class, method)`: the owning module, the body's `FuncId`,
/// and the captured-name/value pairs to bind on call.
pub const AnonMethodEntry = struct {
    module: ObjRef(Module),
    func: FuncId,
    captures: []NameValue,
};

pub const NameValue = struct {
    name: []const u8,
    value: Value,
};

pub const ClassTable = build.ClassTable;
pub const OuterTable = std.StringHashMap(Value);
pub const AnonMethods = ObjRef(std.StringHashMap(AnonMethodEntry));

/// `(class, member)` → `FuncId` registry table (shared with `build`).
pub const PairFuncMap = build.PairFuncMap;
pub const StrPair = build.StrPair;
pub const StrFunc = build.StrFunc;
pub const NameFunc = build.NameFunc;
pub const EnumEntryArgInit = build.EnumEntryArgInit;

/// Build-time-immutable program metadata. Produced once by
/// `build.build_module` and shared by handle with every OS thread the
/// program spawns. Nothing here is mutated after construction.
pub const ProgramImage = struct {
    /// Top-level property name → 0-arg initializer `FuncId`.
    top_level_prop_inits: std.StringHashMap(FuncId),
    body_prop_inits: PairFuncMap,
    instance_prop_getters: PairFuncMap,
    instance_prop_setters: PairFuncMap,
    parent_ctor_args: std.StringHashMap([]FuncId),
    init_blocks: std.StringHashMap([]FuncId),
    extension_props: PairFuncMap,
    extension_prop_setters: PairFuncMap,
    secondary_ctors: std.StringHashMap([]build.SecondaryCtorEntry),
    primary_ctor_default_thunks: std.StringHashMap([]?FuncId),
    /// Names of every top-level `object` / synthesised companion. The
    /// startup pass initializes these eagerly but defers any whose
    /// initializer throws; `lookupGlobal` initializes a deferred object
    /// on first access — matching Kotlin's lazy `object` init.
    object_names: std.StringHashMap(void),
    class_delegates: std.StringHashMap([]StrFunc),
    func_defaults: std.AutoHashMap(u32, []?FuncId),
    installed_bindings: ObjRef(HostBindings),
    /// Link-time resolved executable form per top-level `FuncId`
    /// (keyed by `FuncId.int()`). A present entry binds that symbol's
    /// single executable form to the native binding it maps to; an
    /// absent entry runs the lowered body. Populated once by
    /// `linkResolvedForms` after both the module funcs and
    /// `installed_bindings` exist, so pack-vs-source identity is settled
    /// up front, deterministically, independent of load order. The VM
    /// dispatch paths consult this directly instead of re-deciding the
    /// form per call against `installed_bindings`.
    resolved_native: std.AutoHashMap(u32, StdlibFn),
    /// Whether `linkResolvedForms` has run for the current
    /// `installed_bindings` snapshot.
    resolved_linked: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Allocator.Error!ProgramImage {
        return .{
            .top_level_prop_inits = std.StringHashMap(FuncId).init(allocator),
            .body_prop_inits = PairFuncMap.init(allocator),
            .instance_prop_getters = PairFuncMap.init(allocator),
            .instance_prop_setters = PairFuncMap.init(allocator),
            .parent_ctor_args = std.StringHashMap([]FuncId).init(allocator),
            .init_blocks = std.StringHashMap([]FuncId).init(allocator),
            .extension_props = PairFuncMap.init(allocator),
            .extension_prop_setters = PairFuncMap.init(allocator),
            .secondary_ctors = std.StringHashMap([]build.SecondaryCtorEntry).init(allocator),
            .primary_ctor_default_thunks = std.StringHashMap([]?FuncId).init(allocator),
            .object_names = std.StringHashMap(void).init(allocator),
            .class_delegates = std.StringHashMap([]StrFunc).init(allocator),
            .func_defaults = std.AutoHashMap(u32, []?FuncId).init(allocator),
            .installed_bindings = try ObjRef(HostBindings).init(allocator, HostBindings.init(allocator)),
            .resolved_native = std.AutoHashMap(u32, StdlibFn).init(allocator),
            .resolved_linked = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProgramImage) void {
        self.top_level_prop_inits.deinit();
        self.body_prop_inits.deinit();
        self.instance_prop_getters.deinit();
        self.instance_prop_setters.deinit();
        self.parent_ctor_args.deinit();
        self.init_blocks.deinit();
        self.extension_props.deinit();
        self.extension_prop_setters.deinit();
        self.secondary_ctors.deinit();
        self.primary_ctor_default_thunks.deinit();
        self.object_names.deinit();
        self.class_delegates.deinit();
        self.func_defaults.deinit();
        self.installed_bindings.deinit();
        self.resolved_native.deinit();
    }

    /// Resolve each symbol's single executable form ONCE: for every
    /// body-bearing top-level `FuncId` whose FQN maps to a native
    /// binding in `installed_bindings`, record that binding as the
    /// symbol's form. Funcs with no matching binding run their lowered
    /// body and are simply absent from the table.
    ///
    /// This is the link/finalize step of the two-phase build: it settles
    /// pack-vs-source identity deterministically, as a pure function of
    /// `(FuncId → fqn, installed_bindings)`, with no per-call FQN probe.
    /// It mirrors exactly what the per-call short-circuit in
    /// `callFunc`/`callValue` used to decide on every dispatch
    /// (`installed_bindings.resolve(func.fqn)`), but does it once.
    /// Idempotent: re-running after an `installed_bindings` change
    /// rebuilds the table.
    pub fn linkResolvedForms(self: *ProgramImage, module: *const Module) Allocator.Error!void {
        self.resolved_native.clearRetainingCapacity();
        const bg = self.installed_bindings.borrow();
        defer bg.deinit();
        const bindings = bg.get();
        if (!bindings.isEmpty()) {
            for (module.funcs.items) |*f| {
                if (bindings.resolve(f.fqn)) |intrinsic| {
                    try self.resolved_native.put(f.id.int(), intrinsic);
                }
            }
        }
        self.resolved_linked = true;
    }

    /// The link-time-resolved native form for `func`, or `null` when the
    /// symbol's single form is its lowered body. Consulted by the VM
    /// dispatch paths in place of the deleted per-call FQN short-circuit.
    pub fn resolvedNativeForm(self: *const ProgramImage, func: FuncId) ?StdlibFn {
        return self.resolved_native.get(func.int());
    }
};

/// Single exclusive spin lock, re-exported from `runtime.objcell` so the
/// interpreter, the stdlib concurrency intrinsics, and the shared
/// output/closure handles all share one definition (`coroutines.zig`
/// imports it as `root.SpinMutex`).
pub const SpinMutex = runtime.SpinMutex;

/// Shared serialized stdout sink. The root and every spawned thread
/// write through this so concurrent `println` is serialized; on
/// completion the recorded calls replay into the caller's real sink.
///
/// A thin handle over `ObjRef(RecordingSink)` — the same shared cell
/// `ThreadTable` is built on. Every access takes the cell's reader/writer
/// lock's exclusive `borrowMut`, serializing concurrent writes exactly as
/// the prior hand-rolled mutex did.
pub const SharedOutput = struct {
    obj: ObjRef(runtime.RecordingSink),

    pub fn new(allocator: Allocator) Allocator.Error!SharedOutput {
        const obj = try ObjRef(runtime.RecordingSink).init(allocator, runtime.RecordingSink.init(allocator));
        // Shared across every thread of the program from creation; all
        // writes serialize through the cell's exclusive lock.
        return .{ .obj = obj };
    }

    pub fn clone(self: SharedOutput) SharedOutput {
        return .{ .obj = self.obj.clone() };
    }

    pub fn deinit(self: SharedOutput) void {
        self.obj.deinit();
    }

    pub fn replayInto(self: SharedOutput, out: Output) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        g.get().replayInto(out);
    }

    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        const self: SharedOutput = .{ .obj = .{ .cell = @ptrCast(@alignCast(ctx)) } };
        const g = self.obj.borrowMut();
        defer g.deinit();
        g.get().output().writeln(s);
    }
    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: SharedOutput = .{ .obj = .{ .cell = @ptrCast(@alignCast(ctx)) } };
        const g = self.obj.borrowMut();
        defer g.deinit();
        g.get().output().write(s);
    }

    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: SharedOutput) Output {
        return .{ .ctx = self.obj.cell, .vtable = &vtable };
    }
};

/// One element of the lambda/closure side-table.
pub const ClosureInfo = struct {
    body_func: FuncId,
    n_params: usize,
    /// Capture names, in the same order as the runtime captures vec.
    capture_names: [][]const u8,
    /// Live capture values. Stored behind a shared interior-mutable
    /// handle so the lambda body's `StoreGlobal` writes propagate.
    captures: ObjRef(std.ArrayList(Value)),
};

/// Lambda/closure side-table shared across every OS thread of one
/// program. Indices (`Value.IrClosure.id`) are append-stable — `push`
/// only ever extends — so a shared mutex-guarded list keeps cross-thread
/// closure creation sound while every existing id stays valid.
pub const SharedClosures = struct {
    obj: ObjRef(std.ArrayList(ClosureInfo)),

    pub fn new(allocator: Allocator) Allocator.Error!SharedClosures {
        const obj = try ObjRef(std.ArrayList(ClosureInfo)).init(allocator, .empty);
        // The side-table is shared across every thread from creation, so
        // `get`/`push` go through the cell's reader/writer lock.
        return .{ .obj = obj };
    }

    pub fn clone(self: SharedClosures) SharedClosures {
        return .{ .obj = self.obj.clone() };
    }

    pub fn deinit(self: SharedClosures) void {
        self.obj.deinit();
    }

    pub fn get(self: SharedClosures, id: usize) ?ClosureInfo {
        const g = self.obj.borrow();
        defer g.deinit();
        const list = g.get();
        if (id >= list.items.len) return null;
        return list.items[id];
    }

    /// Append `info`, returning its stable id.
    pub fn push(self: SharedClosures, info: ClosureInfo) Allocator.Error!u64 {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const list = g.get();
        const id: u64 = list.items.len;
        try list.append(self.obj.cell.allocator, info);
        return id;
    }
};

/// One spawned OS thread tracked by the host. The thread yields the
/// body's terminal result (an error carries a thrown Kotlin Throwable).
pub const ThreadEntry = struct {
    handle: ?std.Thread,
    /// Terminal result published by the thread body on exit.
    result: ?ThreadResult = null,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const ThreadResult = union(enum) {
    ok: void,
    err: RuntimeError,
};

pub const ThreadTable = ObjRef(std.AutoHashMap(u64, ThreadEntry));

/// First-access initialization state for one `object` / companion
/// singleton, keyed by its lifted global name in `ObjectStates`. A name
/// with no entry is either not yet initialized or already published in
/// `globals`; the gate in `host_globals.ensureObjectSingleton` checks
/// `globals` first, so the table only carries the transient and terminal
/// non-published states.
pub const ObjectInitState = union(enum) {
    /// Construction is running on `thread`. `instance` is set as soon as
    /// the instance shell is materialized, so re-entrant access from the
    /// constructing thread (an object referencing itself during its own
    /// init) observes the partially-initialized singleton, matching
    /// Kotlin. Any other thread waits for the entry to resolve.
    InProgress: struct { thread: std.Thread.Id, instance: ?Value },
    /// The first construction threw. The initializer is never retried;
    /// every later access throws `FileFailedToInitializeException`
    /// without the original cause, matching kotlinc.
    Failed,
};

/// Shared lazy-`object` init table: one entry per singleton whose
/// construction is in flight or has failed. Shared by handle with every
/// OS thread, like `ThreadTable`; the cell's writer lock serializes the
/// claim that makes first-access construction once-only across threads.
pub const ObjectStates = ObjRef(std.StringHashMap(ObjectInitState));

/// Vm-level errors. Carried as data, mirroring Rust's `VmError`.
pub const VmError = union(enum) {
    /// main function not found in module
    InvalidMain,
    /// IR eval: {0}
    Eval: []const u8,
};

/// `Result<Value, VmError>` carried as data.
pub const VmResult = union(enum) {
    ok: Value,
    err: VmError,
};

/// How the default interceptor interprets a `delay` directive.
pub const TimeMode = enum {
    /// Consume real wall-clock time, matching the JVM.
    Wall,
    /// Advance a logical clock instantly — deterministic and fast.
    Virtual,

    pub const default: TimeMode = .Wall;
};

threadlocal var coroutine_time_mode_tls: TimeMode = .Wall;

/// Set the coroutine time mode for the current thread.
pub fn setCoroutineTimeMode(mode: TimeMode) void {
    coroutine_time_mode_tls = mode;
}

/// Current coroutine time mode for this thread.
pub fn coroutineTimeMode() TimeMode {
    return coroutine_time_mode_tls;
}

/// One Vm instance executes a single program against the IR module
/// produced by the front end.
pub const Vm = struct {
    module: ObjRef(Module),
    globals: ObjRef(Env),
    /// Process-wide monotonic instance-id source.
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    /// Per-class runtime metadata produced by `build.build_module`.
    classes: ObjRef(ClassTable),
    /// Top-level property initialiser `FuncIds`, run at `run` start.
    top_level_props: std.ArrayList(NameFunc),
    /// Enum-entry ctor-arg thunks to evaluate at startup.
    enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit),
    /// Default outer instance to attach to locally-registered classes.
    class_default_outer: ObjRef(OuterTable),
    /// Runtime-lowered method bodies for anonymous-object / local classes.
    anon_methods: AnonMethods,
    /// Closure side-table, shared across threads.
    closures: SharedClosures,
    /// Build-time-immutable program metadata, shared by handle.
    prog: ObjRef(ProgramImage),
    /// Shared serialized stdout sink.
    out_sink: SharedOutput,
    /// Host-side registry of live spawned-thread join handles.
    threads: ThreadTable,
    /// Lazy `object` / companion first-access init states.
    object_states: ObjectStates,
    allocator: Allocator,

    pub const new = run_mod.vmNew;
    pub const fromBuilt = run_mod.vmFromBuilt;
    pub const setInstalledBindings = run_mod.vmSetInstalledBindings;
    pub const makeHost = run_mod.vmMakeHost;
    pub const spawnChild = run_mod.vmSpawnChild;
    pub const runThreadBlock = run_mod.vmRunThreadBlock;
    pub const run = run_mod.vmRun;
    pub const runInner = run_mod.vmRunInner;
    pub const deinit = run_mod.vmDeinit;
};

/// `Send` capture of the shared program state for a new OS thread.
/// Every field is an owned shared handle, so the seed outlives the
/// spawning call and carries no borrow.
pub const SendableVmSeed = struct {
    module: ObjRef(Module),
    globals: ObjRef(Env),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    object_states: ObjectStates,
    allocator: Allocator,

    /// Materialize a child `Vm` on the current (new) OS thread.
    pub fn materialize(self: SendableVmSeed) Allocator.Error!Vm {
        return .{
            .module = self.module,
            .globals = self.globals,
            .instance_id_counter = self.instance_id_counter,
            .classes = self.classes,
            .top_level_props = .empty,
            .enum_entry_arg_inits = .empty,
            .class_default_outer = self.class_default_outer,
            .anon_methods = self.anon_methods,
            .closures = self.closures,
            .prog = self.prog,
            .out_sink = self.out_sink,
            .threads = self.threads,
            .object_states = self.object_states,
            .allocator = self.allocator,
        };
    }
};

// -------------------------------------------------------------------------
// Free helpers ported from lib.rs
// -------------------------------------------------------------------------

/// Whether `name` names a property (not a function) reachable on
/// `receiver`'s class. Walks the parent chain and declared supertypes.
pub fn memberIsProperty(allocator: Allocator, classes: *const ObjRef(ClassTable), receiver: *const Value, name: []const u8) bool {
    const start: ObjRef(ClassDef) = switch (receiver.*) {
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            for (g.get().fields.items) |f| {
                if (std.mem.eql(u8, f.name, name)) return true;
            }
            break :blk g.get().class.clone();
        },
        .Class => |cls| cls.clone(),
        else => return false,
    };
    defer start.deinit();

    var stack: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (stack.items) |c| c.deinit();
        stack.deinit(allocator);
    }
    stack.append(allocator, start.clone()) catch return false;

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    while (stack.pop()) |c| {
        defer c.deinit();
        const cg = c.borrow();
        defer cg.deinit();
        const cdef = cg.get();
        var already = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, cdef.name)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        seen.append(allocator, cdef.name) catch return false;

        for (cdef.primary_params) |p| {
            if (p.property != null and std.mem.eql(u8, p.name, name)) return true;
        }
        for (cdef.body_properties) |p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        if (cdef.parent) |parent| {
            stack.append(allocator, parent.clone()) catch return false;
        }
        for (cdef.supertype_names) |sn| {
            const tg = classes.borrow();
            defer tg.deinit();
            if (tg.get().get(sn)) |sc| {
                stack.append(allocator, sc.clone()) catch return false;
            }
        }
    }
    return false;
}

/// Whether a body's declared primitive parameter type can accept `v`.
/// Conservative: only a definite concrete-primitive-vs-different-
/// primitive pairing rejects.
pub fn primitiveParamAccepts(type_name: []const u8, v: *const Value) bool {
    const arg_is_primitive = switch (v.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Char, .Bool, .String => true,
        else => false,
    };
    if (!arg_is_primitive) return true;
    const eq = std.mem.eql;
    if (eq(u8, type_name, "Int")) return v.* == .Int;
    if (eq(u8, type_name, "Long")) return v.* == .Long;
    if (eq(u8, type_name, "Short")) return v.* == .Short;
    if (eq(u8, type_name, "Byte")) return v.* == .Byte;
    if (eq(u8, type_name, "UInt")) return v.* == .UInt;
    if (eq(u8, type_name, "ULong")) return v.* == .ULong;
    if (eq(u8, type_name, "UShort")) return v.* == .UShort;
    if (eq(u8, type_name, "UByte")) return v.* == .UByte;
    if (eq(u8, type_name, "Double")) return v.* == .Double;
    if (eq(u8, type_name, "Float")) return v.* == .Float;
    if (eq(u8, type_name, "Char")) return v.* == .Char;
    if (eq(u8, type_name, "Boolean")) return v.* == .Bool;
    if (eq(u8, type_name, "String")) return v.* == .String;
    return true;
}

fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// Permissive receiver/param-type compatibility used by extension
/// overload pickers. Returns false only when the runtime value provably
/// does not satisfy the parameter's nominal type.
pub fn receiverCompatibleWithParam(receiver: *const Value, param_ty: *const TypeRef) bool {
    if (receiver.* == .Instance) return true;
    const pn_simple = simpleName(param_ty.name);
    if (std.mem.eql(u8, pn_simple, "Any") or
        std.mem.eql(u8, pn_simple, "Any?") or
        std.mem.eql(u8, pn_simple, "Unit") or
        std.mem.startsWith(u8, pn_simple, "Function") or
        (pn_simple.len <= 2 and allAsciiUpper(pn_simple)))
    {
        return true;
    }
    return receiver.isRuntimeType(pn_simple);
}

/// True when an extension's declared receiver type name denotes a user /
/// pack class — i.e. not a builtin, an open supertype a builtin
/// satisfies, or a bare type parameter.
pub fn extDeclRecvIsUserClass(ty_name: []const u8) bool {
    const s = simpleName(ty_name);
    if (s.len == 0) return false;
    if (s.len <= 2 and allAsciiUpper(s)) return false;
    const builtins = [_][]const u8{
        "String",   "StringBuilder", "CharSequence", "Appendable",  "Int",        "Long",
        "Short",    "Byte",          "Double",       "Float",       "Char",       "Boolean",
        "Number",   "Array",         "List",         "MutableList", "Collection", "Iterable",
        "Map",      "MutableMap",    "Set",          "MutableSet",  "Sequence",   "Comparable",
        "Any",      "Unit",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, s, b)) return false;
    }
    return true;
}

/// True when `fqn` names a builtin `kotlin.*` Throwable-hierarchy class
/// that klio constructs as a host `Value.Exception` rather than a
/// generic Instance.
pub fn isBuiltinThrowableFqn(fqn: []const u8) bool {
    const names = [_][]const u8{
        "kotlin.Throwable",                       "kotlin.Exception",
        "kotlin.Error",                           "kotlin.RuntimeException",
        "kotlin.IllegalArgumentException",        "kotlin.IllegalStateException",
        "kotlin.IndexOutOfBoundsException",       "kotlin.NullPointerException",
        "kotlin.ArithmeticException",             "kotlin.ClassCastException",
        "kotlin.NoSuchElementException",          "kotlin.NumberFormatException",
        "kotlin.UnsupportedOperationException",   "kotlin.NoWhenBranchMatchedException",
        "kotlin.ConcurrentModificationException", "kotlin.AssertionError",
    };
    for (names) |n| {
        if (std.mem.eql(u8, fqn, n)) return true;
    }
    return false;
}

/// True for a builtin (non-`Instance`, non-`Class`) value.
pub fn valueIsBuiltin(v: *const Value) bool {
    return switch (v.*) {
        .String, .StringBuilder, .Int, .Long, .Short, .Byte, .Double, .Float, .Char, .Bool, .Array, .List, .Map, .Result => true,
        else => false,
    };
}

/// A `TypeRef` denoting a Kotlin function type.
pub fn isFunctionType(ty: *const TypeRef) bool {
    const n = simpleName(ty.name);
    return std.mem.startsWith(u8, n, "Function") or
        std.mem.indexOf(u8, ty.name, "->") != null;
}

/// Whether a runtime value can be invoked as `f(...)`.
pub fn valueIsCallable(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Function, .Intrinsic, .BoundMethod, .PropertyRef => true,
        else => false,
    };
}

/// True when `v` is a `Value.Exception` whose `fqn` names a
/// `CancellationException` (including the timeout variant).
pub fn isCancellationException(v: *const Value) bool {
    switch (v.*) {
        .Exception => |e| {
            const g = e.fqn.borrow();
            defer g.deinit();
            const s = g.get().*;
            return std.mem.endsWith(u8, s, "CancellationException") or
                std.mem.endsWith(u8, s, "TimeoutCancellationException");
        },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            const name = cg.get().name;
            return std.mem.endsWith(u8, name, "CancellationException") or
                std.mem.endsWith(u8, name, "TimeoutCancellationException");
        },
        else => return false,
    }
}

// -------------------------------------------------------------------------
// Tests (mirror the Rust crate's lib.rs `mod tests`)
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = build;
    _ = vmhost;
    _ = run_mod;
}

test "value_is_callable / value_is_builtin classification" {
    const i: Value = .{ .Int = 1 };
    try testing.expect(valueIsBuiltin(&i));
    try testing.expect(!valueIsCallable(&i));
    const p: Value = .{ .PropertyRef = .{ .name = try ObjRef([]const u8).init(testing.allocator, "x") } };
    defer p.PropertyRef.name.deinit();
    try testing.expect(valueIsCallable(&p));
    try testing.expect(!valueIsBuiltin(&p));
}

test "is_builtin_throwable_fqn matches exact builtin names only" {
    try testing.expect(isBuiltinThrowableFqn("kotlin.IllegalStateException"));
    try testing.expect(!isBuiltinThrowableFqn("my.app.Error"));
}

test "ext_decl_recv_is_user_class rejects builtins and type params" {
    try testing.expect(!extDeclRecvIsUserClass("String"));
    try testing.expect(!extDeclRecvIsUserClass("T"));
    try testing.expect(extDeclRecvIsUserClass("com.example.Widget"));
}

fn linkTestNativeFn(ctx: *runtime.CallCtx) std.mem.Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .ok = Value.Unit };
}

fn pushLinkTestFunc(m: *Module, a: Allocator, name: []const u8, fqn: []const u8) Allocator.Error!FuncId {
    const id = FuncId.from(@intCast(m.funcs.items.len));
    const blocks = try a.alloc(ir.Block, 1);
    blocks[0] = .{ .id = ir.BlockId.from(0), .insts = &.{}, .terminator = .{ .Return = null } };
    try m.funcs.append(a, .{
        .id = id,
        .name = name,
        .fqn = fqn,
        .package = "",
        .params = &.{},
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = blocks,
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    return id;
}

test "linkResolvedForms binds one form per symbol from the installed overlay" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| a.free(f.blocks);
        m.deinit(a);
    }
    // Two body-bearing funcs; only the first's FQN has a native binding.
    const shimmed = try pushLinkTestFunc(&m, a, "now", "kotlinx.datetime.now");
    const plain = try pushLinkTestFunc(&m, a, "plain", "app.plain");

    var prog = try ProgramImage.init(a);
    defer prog.deinit();

    // Empty overlay: every symbol's form is its lowered body.
    try prog.linkResolvedForms(&m);
    try testing.expect(prog.resolved_linked);
    try testing.expect(prog.resolvedNativeForm(shimmed) == null);
    try testing.expect(prog.resolvedNativeForm(plain) == null);

    // Install a binding for the shimmed FQN, re-link, and confirm the
    // resolved form is the native binding for that symbol and the lowered
    // body (absent) for the other — exactly what the deleted per-call
    // `installed_bindings.resolve(fqn)` short-circuit would have picked.
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        try bg.get().register("kotlinx.datetime.now", linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);
    const resolved = prog.resolvedNativeForm(shimmed);
    try testing.expect(resolved != null);
    try testing.expect(resolved.? == linkTestNativeFn);
    try testing.expect(prog.resolvedNativeForm(plain) == null);

    // Re-linking is idempotent and rebuilds the table from the current
    // overlay: clearing the binding drops the resolved native form.
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        _ = bg.get().table.remove("kotlinx.datetime.now");
    }
    try prog.linkResolvedForms(&m);
    try testing.expect(prog.resolvedNativeForm(shimmed) == null);
}

test "shared closures push is append-stable" {
    const sc = try SharedClosures.new(testing.allocator);
    defer sc.deinit();
    const caps = try ObjRef(std.ArrayList(Value)).init(testing.allocator, .empty);
    defer caps.deinit();
    const id0 = try sc.push(.{ .body_func = .from(0), .n_params = 0, .capture_names = &.{}, .captures = caps });
    const id1 = try sc.push(.{ .body_func = .from(1), .n_params = 0, .capture_names = &.{}, .captures = caps });
    try testing.expectEqual(@as(u64, 0), id0);
    try testing.expectEqual(@as(u64, 1), id1);
    try testing.expect(sc.get(0) != null);
    try testing.expect(sc.get(2) == null);
}

test "shared output records and replays into the real sink" {
    const shared = try SharedOutput.new(testing.allocator);
    defer shared.deinit();
    const sink = shared.output();
    sink.write("x");
    sink.writeln("y");
    sink.writeln("z");

    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    shared.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("xy", cap.lines.items[0]);
    try testing.expectEqualStrings("z", cap.lines.items[1]);
}

test "shared output clone shares one inner sink" {
    const shared = try SharedOutput.new(testing.allocator);
    defer shared.deinit();
    const other = shared.clone();
    defer other.deinit();
    try testing.expect(ObjRef(runtime.RecordingSink).ptrEq(shared.obj, other.obj));

    shared.output().writeln("a");
    other.output().writeln("b");

    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    other.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("a", cap.lines.items[0]);
    try testing.expectEqualStrings("b", cap.lines.items[1]);
}
