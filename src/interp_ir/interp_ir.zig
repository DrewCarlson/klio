//! IR-native interpreter: `Vm` executes a frozen `ir.Module` end-to-end, with
//! no AST evaluator behind it.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;

pub const Output = runtime.Output;

/// The value codec the base image is written in.
pub const codec = @import("codec.zig");

const vmhost = @import("vm/vmhost.zig");
const run_mod = @import("vm/run.zig");

pub const VmHost = vmhost.VmHost;
pub const VmIntrinsicHost = vmhost.VmIntrinsicHost;

/// Composer-stack intrinsics the loader merges into the host bindings.
pub const compose = @import("vm/compose.zig");
pub const coroutines_diag = @import("vm/coroutines.zig");

/// Assert empty and clear the process-wide receiver/coroutine thread-locals at
/// a run boundary; leaked cross-run state is a loud Debug failure.
pub const resetReceiverThreadLocals = vmhost.resetReceiverThreadLocals;
pub const resetRunGlobalCaches = vmhost.resetRunGlobalCaches;

/// The members the VM implements over host values, for the bridge to bind
/// (`bridge.Options.host_fns`).
pub const hostMemberFn = @import("vm/host_members.zig").resolve;
/// The fast paths the VM puts in front of declarations with bodies
/// (`bridge.Options.host_tries`).
pub const hostMemberTry = @import("vm/host_members.zig").resolveTry;

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Module = ir.Module;
pub const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const RuntimeError = runtime.RuntimeError;

/// Single exclusive spin lock, re-exported from `runtime.objcell` so the
/// interpreter, the intrinsics, and the shared handles share one definition.
pub const SpinMutex = runtime.SpinMutex;

/// The program's stdout sink, shared by every thread: a handle over an `ObjRef`
/// cell, so each write takes the cell's exclusive `borrowMut` and concurrent
/// `println`s serialize. Writes stream as they happen, so a hanging or killed
/// program still shows its output. With no destination attached the sink
/// records instead, and `attach` flushes that backlog before streaming.
pub const SharedOutput = struct {
    obj: ObjRef(State),

    pub const State = struct {
        /// Where writes go. Null until `attach`: record instead.
        dest: ?Output = null,
        rec: runtime.RecordingSink,

        pub fn deinit(self: *State) void {
            self.rec.deinit();
        }
    };

    pub fn new(allocator: Allocator) Allocator.Error!SharedOutput {
        const obj = try ObjRef(State).init(allocator, .{ .rec = runtime.RecordingSink.init(allocator) });
        return .{ .obj = obj };
    }

    pub fn clone(self: SharedOutput) SharedOutput {
        return .{ .obj = self.obj.clone() };
    }

    pub fn deinit(self: SharedOutput) void {
        self.obj.deinit();
    }

    /// Stream from here on to `out`, flushing anything recorded first.
    pub fn attach(self: SharedOutput, out: Output) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        st.rec.replayInto(out);
        st.dest = out;
    }

    /// Drain the recording into `out`; a no-op once a destination is attached.
    pub fn replayInto(self: SharedOutput, out: Output) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        if (st.dest != null) return;
        st.rec.replayInto(out);
    }

    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        const self: SharedOutput = .{ .obj = .{ .cell = @ptrCast(@alignCast(ctx)) } };
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        if (st.dest) |d| d.writeln(s) else st.rec.output().writeln(s);
    }
    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: SharedOutput = .{ .obj = .{ .cell = @ptrCast(@alignCast(ctx)) } };
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        if (st.dest) |d| d.write(s) else st.rec.output().write(s);
    }

    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: SharedOutput) Output {
        return .{ .ctx = self.obj.cell, .vtable = &vtable };
    }
};

pub const ClosureInfo = struct {
    body_func: FuncId,
    /// A function value loaded from a declaration (`::f`): equal to every other
    /// load but never identical, unlike Kotlin's non-capturing-lambda singleton.
    is_ref: bool = false,
    /// The module `body_func` indexes, null for the main program module. A
    /// sub-module closure must resolve against it: sub-module `FuncId`s start at
    /// 0. The module lives for the run, owned by the anon table or run arena.
    module: ?*const ir.Module = null,
    n_params: usize,
    receiver_shape_known: bool = false,
    /// The callable declares an extension receiver outside `n_params`.
    has_receiver: bool = false,
    /// Capture names, in the same order as the runtime captures vec.
    capture_names: [][]const u8,
    /// Live capture values, behind a shared handle so `StoreGlobal` propagates.
    captures: ObjRef(std.ArrayList(Value)),

    /// Set for a closure lowered from sema: what it is beside its body,
    /// which then takes the call's arguments exactly and does not read
    /// `capture_names`.
    resolved: ?ir.resolved.Callable = null,

    /// True once the closure's cell is swept, its metadata freed and its id
    /// back on the free list.
    reclaimed: bool = false,
};

/// The closure slots and the reclaimed ids, written only under the table's
/// exclusive borrow.
pub const ClosureTable = struct {
    /// Tells this table from every other a process makes, for a sweep that
    /// finalizes an earlier program's closure after a later program's table
    /// took its place, perhaps at the same address.
    gen: u64,
    slots: std.ArrayList(ClosureInfo) = .empty,
    /// Reclaimed ids; `push` reuses one before extending `slots`.
    free: std.ArrayList(u64) = .empty,

    /// Traces nothing. A closure's capture store lives only while a value
    /// references its id, through `markClosureHook`, so the table must not
    /// pin it.
    pub fn gcTrace(self: *const ClosureTable, m: *runtime.gc.Marker) void {
        _ = self;
        _ = m;
    }

    pub fn deinit(self: *ClosureTable, a: Allocator) void {
        self.slots.deinit(a);
        self.free.deinit(a);
    }

    pub fn gcFinalize(self: *ClosureTable, a: Allocator) void {
        self.deinit(a);
    }
};

/// The generation the next closure table takes; 0 names no table.
var table_gens = std.atomic.Value(u64).init(0);

/// The process-wide closure side-table `markClosureHook` consults. Every Vm
/// shares one spine by handle clone, so one handle serves every collector.
var active_closures: ?SharedClosures = null;

fn markClosureThunk(id: u64, m: *runtime.gc.Marker) void {
    const sc = active_closures orelse return;
    // Shade the slot's capture store. The table's shared borrow is held
    // throughout: a mark may run beside a `push` that reallocates the slots,
    // which takes the exclusive borrow.
    const g = sc.obj.borrow();
    defer g.deinit();
    const slots = g.get().slots.items;
    if (id >= slots.len) return;
    m.shade(&slots[id].captures.cell.hdr);
}

/// The table swept closures release their slots into: the running program's,
/// or null. Read by the thread that sweeps, which may be the sweeper.
var release_table = std.atomic.Value(?*anyopaque).init(null);

/// The program's last Vm is gone: a later sweep releases into no table, since
/// this one's memory may leave with the program's heap.
pub fn gcRetireClosureTable() void {
    release_table.store(null, .release);
}

/// Frees the slot of a closure whose cell was swept, when its table is the
/// running program's. Runs on the sweeper thread, or on the collector inside
/// the stop; neither holds a cell lock, and the table's lock is held by others
/// only between their safe points.
fn releaseClosureThunk(table: u64, id: u64) void {
    const cell = release_table.load(.acquire) orelse return;
    const sc: SharedClosures = .{ .obj = .{ .cell = @ptrCast(@alignCast(cell)) } };
    sc.release(table, id);
}

/// Singleton identity for a closure id: non-zero and stable per (module, body
/// function) when the closure captures nothing, 0 otherwise. Kotlin makes a
/// non-capturing lambda a singleton, so `structuralEq` compares by this.
fn closureSingletonThunk(id: u64) u64 {
    const sc = active_closures orelse return 0;
    const info = sc.get(id) orelse return 0;
    // A capturing closure keeps per-instance identity; a reclaimed slot none.
    if (info.reclaimed or info.is_ref or info.capture_names.len != 0) return 0;
    const mod_bits: u64 = if (info.module) |m| @intFromPtr(m) else 0;
    var h: u64 = 1469598103934665603;
    h = (h ^ mod_bits) *% 1099511628211;
    h = (h ^ info.body_func.int()) *% 1099511628211;
    return h | 1;
}

/// The module a closure lowered from sema belongs to when its slot names
/// none, for the display hook.
var active_module: ?*const Module = null;

/// A closure lowered from sema renders as its `toString` answers.
fn closureTextThunk(id: u64, w: *std.Io.Writer) std.Io.Writer.Error!bool {
    const sc = active_closures orelse return false;
    const info = sc.get(id) orelse return false;
    const kind = info.resolved orelse return false;
    const module = info.module orelse active_module orelse return false;
    const func = module.funcById(info.body_func) orelse return false;
    const body: ir.resolved.ClosureBody = .{ .id = id, .func = func, .module = module, .kind = kind };
    const text = ir.eval.resolved_ops.closureText(std.heap.page_allocator, module, body) catch return false;
    defer std.heap.page_allocator.free(text);
    try w.writeAll(text);
    return true;
}

/// Install the closure-liveness hook; idempotent across Vms sharing a spine.
pub fn gcInstallClosureHook(closures: SharedClosures, module: *const Module) void {
    active_closures = closures;
    if (module.resolved != null) active_module = module;
    runtime.gc.closureTextHook = closureTextThunk;
    runtime.gc.markClosureHook = markClosureThunk;
    runtime.gc.closureSingletonHook = closureSingletonThunk;
    release_table.store(@ptrCast(closures.obj.cell), .release);
    runtime.setClosureReleaseHook(releaseClosureThunk);
    // A lazy `sequence {}` builder parks its continuation as an opaque
    // `*ir.eval.SuspendState`, which the GC needs these hooks to reach.
    runtime.gc.markSuspendHook = ir.eval.gcMarkSuspendStateOpaque;
    runtime.gc.freeSuspendHook = ir.eval.freeSuspendStateOpaque;
}

/// Clear program-owned closure hooks before the run's phase arena is released.
pub fn gcResetProgramHooks() void {
    active_closures = null;
    active_module = null;
    runtime.gc.closureTextHook = null;
    runtime.gc.markClosureHook = null;
    runtime.gc.closureSingletonHook = null;
    release_table.store(null, .release);
}

/// Lambda/closure side-table shared across every OS thread of one program. A
/// closure's slot is held by its one cell, the `IrClosure` value's: it is
/// released when the collector sweeps that cell, and a frame running or
/// parking the closure's body holds the cell.
pub const SharedClosures = struct {
    obj: ObjRef(ClosureTable),

    pub fn new(allocator: Allocator) Allocator.Error!SharedClosures {
        const gen = table_gens.fetchAdd(1, .monotonic) + 1;
        return .{ .obj = try ObjRef(ClosureTable).init(allocator, .{ .gen = gen }) };
    }

    pub fn clone(self: SharedClosures) SharedClosures {
        return .{ .obj = self.obj.clone() };
    }

    pub fn deinit(self: SharedClosures) void {
        self.obj.deinit();
    }

    /// The generation a closure made from this table records.
    pub fn generation(self: SharedClosures) u64 {
        return self.obj.asPtrConst().gen;
    }

    pub fn get(self: SharedClosures, id: usize) ?ClosureInfo {
        const g = self.obj.borrow();
        defer g.deinit();
        const slots = g.get().slots.items;
        if (id >= slots.len) return null;
        return slots[id];
    }

    /// Free slot `id`'s owned metadata and its id, when `gen` is this table's
    /// and the slot is held. The capture-store cell is swept separately.
    pub fn release(self: SharedClosures, gen: u64, id: u64) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const t = g.get();
        if (gen != t.gen or id >= t.slots.items.len) return;
        const info = &t.slots.items[@intCast(id)];
        if (info.reclaimed) return;
        const a = self.obj.cell.allocator;
        // An id that cannot be listed stays held: a reused slot must be on the
        // list, and a lost one only makes the table longer.
        t.free.append(a, id) catch return;
        if (info.capture_names.len != 0) a.free(info.capture_names);
        info.capture_names = &.{};
        info.reclaimed = true;
    }

    /// Bind `info` to a slot and return its id, reusing a reclaimed slot first.
    /// A reused slot's fields are overwritten here before any read.
    pub fn push(self: SharedClosures, info: ClosureInfo) Allocator.Error!u64 {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const t = g.get();
        if (t.free.pop()) |id| {
            t.slots.items[@intCast(id)] = info;
            return id;
        }
        const id: u64 = t.slots.items.len;
        try t.slots.append(self.obj.cell.allocator, info);
        return id;
    }
};

/// One spawned OS thread; an error result carries a thrown Kotlin Throwable.
pub const ThreadEntry = struct {
    handle: ?std.Thread,
    /// The thread's name, as `Thread.name` answers it.
    name: []const u8 = "",
    result: ?ThreadResult = null,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// An error result can carry values only this entry holds.
    pub fn gcTrace(self: *const ThreadEntry, m: *runtime.gc.Marker) void {
        if (self.result) |r| switch (r) {
            .err => |e| e.gcMark(m),
            .ok => {},
        };
    }
};

pub const ThreadResult = union(enum) {
    ok: void,
    err: RuntimeError,
};

pub const ThreadTable = ObjRef(std.AutoHashMap(u64, ThreadEntry));

/// Vm-level errors, carried as data.
pub const VmError = union(enum) {
    InvalidMain,
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
    /// Advance a logical clock instantly, deterministic and fast.
    Virtual,

    pub const default: TimeMode = .Wall;
};

threadlocal var coroutine_time_mode_tls: TimeMode = .Wall;

pub fn setCoroutineTimeMode(mode: TimeMode) void {
    coroutine_time_mode_tls = mode;
}

pub fn coroutineTimeMode() TimeMode {
    return coroutine_time_mode_tls;
}

/// One Vm instance executes one program against a front-end IR module.
pub const Vm = struct {
    module: ObjRef(Module),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    /// The run state of code lowered from sema: statics, init units and
    /// singletons. Allocated by the first run of a module that has
    /// `resolved` tables.
    resolved_state: ?ir.resolved.StateRef = null,
    allocator: Allocator,
    /// Process argv for `main(args)`; empty under `klio run`, set by a bundle.
    program_args: []const []const u8 = &.{},

    pub const new = run_mod.vmNew;
    pub const makeHost = run_mod.vmMakeHost;
    pub const runThreadBlock = run_mod.vmRunThreadBlock;
    pub const runTimerService = run_mod.vmRunTimerService;
    pub const run = run_mod.vmRun;
    pub const deinit = run_mod.vmDeinit;
    // Embedder entry points: prepare startup, then invoke functions or methods.
    pub const prepare = run_mod.vmPrepare;
    pub const prepareResolved = run_mod.vmPrepareResolved;
    pub const runCalls = run_mod.vmRunCalls;
    pub const callMain = run_mod.vmCallMain;
    pub const callArgs = run_mod.vmCallArgs;
    pub const newResolved = run_mod.vmNewResolved;
    pub const throwableText = run_mod.vmThrowableText;
    pub const uncaughtText = run_mod.vmUncaughtText;
    pub const threadUncaughtText = run_mod.vmThreadUncaughtText;
};

pub const CallOutcome = run_mod.CallOutcome;
pub const uncaught_prefix = run_mod.uncaught_prefix;

/// `Send` capture of the shared program state for a new OS thread. Every field
/// is an owned shared handle, so the seed outlives the spawning call.
pub const SendableVmSeed = struct {
    module: ObjRef(Module),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    /// The run state of code lowered from sema: statics, init units and
    /// singletons. Allocated by the first run of a module that has
    /// `resolved` tables.
    resolved_state: ?ir.resolved.StateRef = null,
    allocator: Allocator,

    pub fn materialize(self: SendableVmSeed) Allocator.Error!Vm {
        return .{
            .module = self.module,
            .instance_id_counter = self.instance_id_counter,
            .closures = self.closures,
            .out_sink = self.out_sink,
            .threads = self.threads,
            .resolved_state = self.resolved_state,
            .allocator = self.allocator,
        };
    }
};

fn simpleName(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// True when an extension's declared receiver names a user or pack class, not a
/// builtin, an open supertype a builtin satisfies, or a bare type parameter.
pub fn extDeclRecvIsUserClass(ty_name: []const u8) bool {
    const s = simpleName(ty_name);
    if (s.len == 0) return false;
    if (s.len <= 2 and allAsciiUpper(s)) return false;
    const builtins = std.StaticStringMap(void).initComptime(.{
        .{"String"},       .{"StringBuilder"},     .{"CharSequence"},  .{"Appendable"},   .{"Int"},          .{"Long"},
        .{"Short"},        .{"Byte"},              .{"Double"},        .{"Float"},        .{"Char"},         .{"Boolean"},
        .{"Number"},       .{"Array"},             .{"List"},          .{"MutableList"},  .{"Collection"},   .{"Iterable"},
        .{"Map"},          .{"MutableMap"},        .{"Set"},           .{"MutableSet"},   .{"Sequence"},     .{"Comparable"},
        .{"Any"},          .{"Unit"},              .{"UInt"},          .{"ULong"},        .{"UShort"},       .{"UByte"},
        .{"ByteArray"},    .{"ShortArray"},        .{"IntArray"},      .{"LongArray"},    .{"CharArray"},    .{"BooleanArray"},
        .{"FloatArray"},   .{"DoubleArray"},       .{"UByteArray"},    .{"UShortArray"},  .{"UIntArray"},    .{"ULongArray"},
        .{"Iterator"},     .{"MutableIterator"},   .{"ListIterator"},  .{"MutableListIterator"},             .{"MutableIterable"},
        .{"MutableCollection"},                    .{"Comparator"},    .{"Enum"},         .{"Throwable"},    .{"Nothing"},
        .{"IntRange"},     .{"LongRange"},         .{"CharRange"},     .{"ClosedRange"},  .{"Pair"},         .{"Triple"},
    });
    if (builtins.has(s)) return false;
    return true;
}

/// True when `fqn` names a builtin `kotlin.*` Throwable class that klio
/// constructs as a host `Value.Exception` rather than a generic Instance.
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
        "kotlin.UninitializedPropertyAccessException",
        "kotlin.coroutines.cancellation.CancellationException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, fqn, n)) return true;
    }
    return false;
}

pub fn valueIsBuiltin(v: *const Value) bool {
    return switch (v.*) {
        .String, .StringBuilder, .Int, .Long, .Short, .Byte, .Double, .Float, .Char, .Bool, .Array, .List, .Map, .Result => true,
        else => false,
    };
}

pub fn isFunctionType(ty: *const TypeRef) bool {
    const n = simpleName(ty.name);
    return std.mem.startsWith(u8, n, "Function") or
        std.mem.find(u8, ty.name, "->") != null;
}

pub fn valueIsCallable(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
        else => false,
    };
}

/// True when `v` is a `CancellationException`, timeout variant included.
pub fn isCancellationException(v: *const Value) bool {
    switch (v.*) {
        .Exception => |e| {
            const g = e.fqn.borrow();
            defer g.deinit();
            const s = g.get().bytes;
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

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = codec;
    _ = vmhost;
    _ = run_mod;
    _ = @import("vm/host_members.zig");
}

test "value_is_callable / value_is_builtin classification" {
    const i: Value = .{ .Int = 1 };
    try testing.expect(valueIsBuiltin(&i));
    try testing.expect(!valueIsCallable(&i));
    const p: Value = .{ .PropertyRef = .{ .name = try runtime.strInit(testing.allocator, "x") } };
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
    try testing.expect(!extDeclRecvIsUserClass("ByteArray"));
    try testing.expect(!extDeclRecvIsUserClass("kotlin.ByteArray"));
    try testing.expect(!extDeclRecvIsUserClass("UIntArray"));
    try testing.expect(!extDeclRecvIsUserClass("ULong"));
    try testing.expect(!extDeclRecvIsUserClass("Iterator"));
    try testing.expect(!extDeclRecvIsUserClass("Comparator"));
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

/// A closure cell over a slot of `sc` taken for it, as `makeResolvedClosure` makes one.
fn testClosure(sc: SharedClosures, caps: ObjRef(std.ArrayList(Value)), names: [][]const u8) !runtime.IrClosureRef {
    const id = try sc.push(.{ .body_func = .from(0), .n_params = 0, .capture_names = names, .captures = caps });
    return runtime.IrClosureRef.init(sc.obj.cell.allocator, .{ .id = id, .table = sc.generation(), .captures = try sc.obj.cell.allocator.alloc(Value, 0) });
}

/// What the collector does to a closure cell it sweeps.
fn sweepCell(c: runtime.IrClosureRef) void {
    c.cell.hdr.gc_finalize(&c.cell.hdr);
}

test "a swept closure's slot is reused and a live one's is not" {
    const a = testing.allocator;
    const sc = try SharedClosures.new(a);
    defer sc.deinit();
    release_table.store(@ptrCast(sc.obj.cell), .release);
    defer release_table.store(null, .release);
    runtime.setClosureReleaseHook(releaseClosureThunk);
    defer runtime.setClosureReleaseHook(null);
    const caps = try ObjRef(std.ArrayList(Value)).init(a, .empty);
    defer caps.deinit();

    const live = try testClosure(sc, caps, &.{});
    defer sweepCell(live);
    const names = try a.alloc([]const u8, 2);
    @memset(names, "");
    const dead = try testClosure(sc, caps, names);
    const live_id = live.asPtrConst().id;
    const dead_id = dead.asPtrConst().id;

    sweepCell(dead);
    // The swept closure's names are freed (the allocator checks) and its id
    // is the next one taken; the live closure's slot is untouched.
    try testing.expect(sc.get(dead_id).?.reclaimed);
    try testing.expectEqual(@as(usize, 0), sc.get(dead_id).?.capture_names.len);
    try testing.expect(!sc.get(live_id).?.reclaimed);
    const next = try testClosure(sc, caps, &.{});
    defer sweepCell(next);
    try testing.expectEqual(dead_id, next.asPtrConst().id);
    try testing.expect(!sc.get(dead_id).?.reclaimed);
    const fresh = try testClosure(sc, caps, &.{});
    defer sweepCell(fresh);
    try testing.expect(fresh.asPtrConst().id != live_id);
    try testing.expect(fresh.asPtrConst().id != dead_id);
}

test "a closure swept after its program's table was replaced leaves the new table alone" {
    const a = testing.allocator;
    const old = try SharedClosures.new(a);
    defer old.deinit();
    const new = try SharedClosures.new(a);
    defer new.deinit();
    try testing.expect(old.generation() != new.generation());
    runtime.setClosureReleaseHook(releaseClosureThunk);
    defer runtime.setClosureReleaseHook(null);
    defer release_table.store(null, .release);
    const caps = try ObjRef(std.ArrayList(Value)).init(a, .empty);
    defer caps.deinit();

    release_table.store(@ptrCast(old.obj.cell), .release);
    const stale = try testClosure(old, caps, &.{});
    // The next program's table takes over, and its first closure takes the
    // same id the stale one holds.
    release_table.store(@ptrCast(new.obj.cell), .release);
    const current = try testClosure(new, caps, &.{});
    defer sweepCell(current);
    try testing.expectEqual(stale.asPtrConst().id, current.asPtrConst().id);
    sweepCell(stale);
    try testing.expect(!new.get(current.asPtrConst().id).?.reclaimed);
    // With no program's table installed, a sweep releases nothing.
    release_table.store(null, .release);
    const orphan = try testClosure(new, caps, &.{});
    sweepCell(orphan);
    try testing.expect(!new.get(orphan.asPtrConst().id).?.reclaimed);
}

test "a closure's slot is released once, however often its release runs" {
    const a = testing.allocator;
    const sc = try SharedClosures.new(a);
    defer sc.deinit();
    const caps = try ObjRef(std.ArrayList(Value)).init(a, .empty);
    defer caps.deinit();
    const id = try sc.push(.{ .body_func = .from(0), .n_params = 0, .capture_names = &.{}, .captures = caps });
    sc.release(sc.generation(), id);
    sc.release(sc.generation(), id);
    sc.release(sc.generation(), id + 10);
    const g = sc.obj.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.get().free.items.len);
}

test "a mark of a closure's slot runs beside pushes and releases that change the table" {
    const a = std.heap.smp_allocator;
    const sc = try SharedClosures.new(a);
    defer sc.deinit();
    active_closures = sc;
    defer active_closures = null;
    const caps = try ObjRef(std.ArrayList(Value)).init(a, .empty);
    defer caps.deinit();
    const other = try ObjRef(std.ArrayList(Value)).init(a, .empty);
    defer other.deinit();
    _ = try sc.push(.{ .body_func = .from(0), .n_params = 0, .capture_names = &.{}, .captures = caps });

    // A mutator making closures and a sweeper releasing every other one: the
    // slots grow, and freed ids are taken again.
    const Churn = struct {
        fn run(s: SharedClosures, c: ObjRef(std.ArrayList(Value)), stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.monotonic)) {
                const keep = s.push(.{ .body_func = .from(1), .n_params = 0, .capture_names = &.{}, .captures = c }) catch return;
                const drop = s.push(.{ .body_func = .from(1), .n_params = 0, .capture_names = &.{}, .captures = c }) catch return;
                _ = keep;
                s.release(s.generation(), drop);
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, Churn.run, .{ sc, other, &stop });
    // Each mark reads slot 0 and shades its capture store while the slots are
    // reallocated under it; a mark that let go of the table first would read
    // a buffer the push has freed.
    var epoch: usize = 1;
    while (epoch < 20_000) : (epoch += 1) {
        var m: runtime.gc.Marker = .{ .epoch = epoch, .arena = a };
        defer m.grey.deinit(a);
        markClosureThunk(0, &m);
        try testing.expectEqual(@as(usize, 1), m.grey.items.len);
        try testing.expectEqual(&caps.cell.hdr, m.grey.items[0]);
    }
    stop.store(true, .monotonic);
    t.join();
    try testing.expect(!sc.get(0).?.reclaimed);
}

test "a thread's error result keeps the values it carries reachable" {
    const a = testing.allocator;
    const table = try ThreadTable.init(a, std.AutoHashMap(u64, ThreadEntry).init(a));
    defer table.deinit();
    const thrown = try runtime.strInit(a, "boom");
    defer thrown.deinit();
    {
        const g = table.borrowMut();
        defer g.deinit();
        try g.get().put(1, .{ .handle = null, .result = .{ .err = .{ .Thrown = .{ .String = thrown } } } });
        try g.get().put(2, .{ .handle = null, .result = .{ .ok = {} } });
    }
    var m: runtime.gc.Marker = .{ .epoch = 91, .arena = a };
    defer m.grey.deinit(a);
    table.cell.hdr.gc_trace(&table.cell.hdr, &m);
    try testing.expectEqual(@as(usize, 91), thrown.cell.hdr.gc_mark);
}

test "closure singleton identity excludes lexical receiver chains" {
    const sc = try SharedClosures.new(testing.allocator);
    defer sc.deinit();
    active_closures = sc;
    defer active_closures = null;
    const caps = try ObjRef(std.ArrayList(Value)).init(testing.allocator, .empty);
    defer caps.deinit();

    const plain0 = try sc.push(.{ .body_func = .from(7), .n_params = 0, .capture_names = &.{}, .captures = caps });
    const plain1 = try sc.push(.{ .body_func = .from(7), .n_params = 0, .capture_names = &.{}, .captures = caps });
    try testing.expect(closureSingletonThunk(plain0) != 0);
    try testing.expectEqual(closureSingletonThunk(plain0), closureSingletonThunk(plain1));

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
    try testing.expect(ObjRef(SharedOutput.State).ptrEq(shared.obj, other.obj));

    shared.output().writeln("a");
    other.output().writeln("b");

    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    other.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("a", cap.lines.items[0]);
    try testing.expectEqualStrings("b", cap.lines.items[1]);
}
