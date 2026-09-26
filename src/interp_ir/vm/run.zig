//! The `Vm` run loop and constructors: establishes a `Vm` around a lowered IR
//! module, runs the startup pipeline, and drives `main` through the IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Output = runtime.Output;
const SharedOutput = root.SharedOutput;
const RuntimeError = runtime.RuntimeError;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalError = ir.eval.EvalError;

const Vm = root.Vm;
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const VmError = root.VmError;
const VmResult = root.VmResult;
const SharedClosures = root.SharedClosures;

pub fn vmNew(allocator: Allocator, module: ObjRef(Module)) Allocator.Error!Vm {
    return .{
        .module = module,
        .instance_id_counter = try ObjRef(std.atomic.Value(u64)).init(allocator, std.atomic.Value(u64).init(0)),
        .closures = try SharedClosures.new(allocator),
        .out_sink = try SharedOutput.new(allocator),
        .threads = try root.ThreadTable.init(allocator, std.AutoHashMap(u64, root.ThreadEntry).init(allocator)),
        .allocator = allocator,
    };
}

/// Borrowed view of this Vm's shared handles; copies bump no refcount and own nothing.
fn sharedHandles(self: *Vm) vmhost.SharedHandles {
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

/// `VmHost` borrowing this Vm's state for one evaluation; it owns nothing, no deinit.
pub fn vmMakeHost(self: *Vm, out: Output) VmHost {
    return VmHost.borrowed(sharedHandles(self), out);
}

/// The timer thread's body over this Vm's handles.
pub fn vmRunTimerService(self: *Vm) Allocator.Error!void {
    var intrinsic = VmIntrinsicHost.borrowed(sharedHandles(self));
    try vmhost.coroutines.driveTimerService(&intrinsic, self.out_sink.output());
}

pub fn vmRunThreadBlock(self: *Vm, block: *const Value) Allocator.Error!runtime.EvalResult {
    // The intrinsic host borrows the child Vm's handles by value for this one call.
    var intrinsic = VmIntrinsicHost.borrowed(sharedHandles(self));
    const host = intrinsic.intrinsicHost();
    const r = try host.invokeCallable(block, &.{}, self.out_sink.output());
    return r;
}

var gc_vms: std.ArrayList(*const Vm) = .empty;
var gc_vm_root_registered = std.atomic.Value(bool).init(false);
var gc_vms_lock = std.atomic.Value(bool).init(false);

fn gcVmsLock() void {
    while (gc_vms_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn gcVmsUnlock() void {
    gc_vms_lock.store(false, .release);
}

fn gcMarkAllVms(m: *runtime.gc.Marker) void {
    gcVmsLock();
    defer gcVmsUnlock();
    for (gc_vms.items) |vm| {
        // The lambda side-table spine traces nothing and its per-closure captures
        // stay alive through `markClosureHook`, so shading it would pin every closure.
        if (vm.resolved_state) |st| m.shade(&st.cell.hdr);
        // A finished thread's error result can hold values nothing else does.
        m.shade(&vm.threads.cell.hdr);
    }
}

/// Register a live Vm as a GC root (its run state). Idempotent.
pub fn gcRegisterVm(vm: *const Vm) void {
    // The lazy-`sequence {}` continuation hooks are needed in every memory mode.
    runtime.gc.markSuspendHook = ir.eval.gcMarkSuspendStateOpaque;
    runtime.gc.freeSuspendHook = ir.eval.freeSuspendStateOpaque;
    // All Vms share one closure side table by handle clone; install it with the
    // liveness and lambda-identity hooks in every mode (GC hooks are inert when off).
    root.gcInstallClosureHook(vm.closures, vm.module.asPtrConst());
    if (!runtime.gc.gc_enabled) return;
    if (!gc_vm_root_registered.swap(true, .monotonic)) runtime.gc.registerRoot(gcMarkAllVms);
    gcVmsLock();
    defer gcVmsUnlock();
    for (gc_vms.items) |registered| {
        if (registered == vm) return;
    }
    gc_vms.append(std.heap.page_allocator, vm) catch @panic("KGC: vm root registration failed");
}

/// Drop a finished Vm from the process root set; the process-lifetime callback
/// must never retain a pointer into a completed run's phase arena.
pub fn gcUnregisterVm(vm: *const Vm) void {
    if (!runtime.gc.gc_enabled) return;
    gcVmsLock();
    defer gcVmsUnlock();
    for (gc_vms.items, 0..) |registered, i| {
        if (registered == vm) {
            _ = gc_vms.swapRemove(i);
            if (gc_vms.items.len == 0) root.gcRetireClosureTable();
            return;
        }
    }
}

pub fn vmRun(self: *Vm, main: FuncId, out: Output) Allocator.Error!VmResult {
    gcRegisterVm(self);
    // Stream output from here so a run that hangs or is killed still shows its prints.
    self.out_sink.attach(out);
    // Close the permanent generation: cells minted up to here are immortal and
    // reference-stable, later ones nursery and swept (a worker does the same at entry).
    runtime.gc.alloc_perm = false;
    runtime.gc.program_started = true;
    // The run thread joins the mutator set, so a worker's collection stops it safely.
    vmhost.coroutines.gcThreadEnter();
    defer vmhost.coroutines.gcThreadExit();
    const result = try vmRunInner(self, main);
    self.out_sink.replayInto(out);
    return result;
}

/// Count of Vm runs live in this process. A nested run (a mid-program image
/// extend) must not treat its own completion as the run boundary: the abandon
/// flags, dispatcher pool and run-scoped registries belong to the outermost run.
var live_vm_runs = std.atomic.Value(usize).init(0);

fn vmRunInner(self: *Vm, main: FuncId) Allocator.Error!VmResult {
    _ = live_vm_runs.fetchAdd(1, .acq_rel);
    defer _ = live_vm_runs.fetchSub(1, .acq_rel);
    const clock_held = vmhost.coroutines.threadClockBegin();
    const result = blk: {
        defer if (clock_held) vmhost.coroutines.threadClockEnd();
        break :blk try vmRunBody(self, main);
    };
    // Join spawned threads on every exit so a program that omits `join()` keeps a
    // child's writes. A child error surfaces only if `main` did not already fail.
    return joinAllThreads(self, result);
}

fn vmRunBody(self: *Vm, main: FuncId) Allocator.Error!VmResult {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    const sink = self.out_sink.output();

    // The module initializes its statics and objects on first touch through
    // its own tables, but for its eager properties, which run now.
    try vmPrepareResolved(self);
    if (module.resolved != null) {
        var start_host = vmMakeHost(self, sink);
        if (try ir.eval.resolved_ops.runEagerUnits(VmHost, self.allocator, module, &start_host)) |e| return .{ .err = vmErrorFromEval(self.allocator, e) };
    }

    const func = module.funcById(main) orelse return .{ .err = .InvalidMain };
    // A `suspend fun main` runs on the cooperative pump, so `delay` parks, not escapes.
    if (func.is_suspend) {
        var intrinsic = VmIntrinsicHost.borrowed(sharedHandles(self));
        const r = try vmhost.coroutines.driveSuspendMain(&intrinsic, main, sink);
        return switch (r) {
            .ok => |v| .{ .ok = v },
            .err => |e| .{ .err = .{ .Eval = vmEvalMessage(self.allocator, e) } },
        };
    }
    var host = vmMakeHost(self, sink);
    // `fun main(args: Array<String>)` receives the program argv (a bundle's
    // `argv[1..]`, empty under `klio run`), per Kotlin's entry contract.
    var args: std.ArrayList(Value) = .empty;
    if (func.params.len >= 1) {
        try args.append(self.allocator, try programArgsValue(self.allocator, self.program_args));
    }
    const r = try ir.eval.evalWith(VmHost, self.allocator, module, func, args, &host);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = vmErrorFromEval(self.allocator, e) },
    };
}

fn programArgsValue(a: Allocator, argv: []const []const u8) Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(a);
    for (argv) |s| {
        try list.append(a, .{ .String = try runtime.strInit(a, s) });
    }
    return runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, list));
}

/// Allocates the run state of a module lowered from sema, once per Vm: its
/// statics at their seeds, every init unit idle, no singleton built.
pub fn vmPrepareResolved(self: *Vm) Allocator.Error!void {
    if (self.resolved_state != null) return;
    const r = self.module.asPtrConst().resolved orelse return;
    const st = try ir.resolved.stateNew(self.allocator, r);
    // The Vm may already be a root: the collector reads the field under this lock.
    gcVmsLock();
    defer gcVmsUnlock();
    self.resolved_state = st;
}

/// Call outcome: `threw` is an uncaught Throwable, `failed` an interpreter error.
pub const CallOutcome = union(enum) {
    ok: Value,
    threw: Value,
    failed: []const u8,
};

fn outcomeFromEval(self: *Vm, r: ir.eval.EvalResult) CallOutcome {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| switch (e) {
            .Throw => |v| .{ .threw = v },
            else => .{ .failed = evalErrMessage(self.allocator, e) },
        },
    };
}

fn evalErrMessage(allocator: Allocator, e: EvalError) []const u8 {
    return switch (e) {
        .Unsupported, .Type, .Unbound, .Unimplemented, .CalleeFailed, .Arity, .StackOverflow => |s| s,
        else => std.fmt.allocPrint(allocator, "{s}", .{@tagName(e)}) catch "evaluation error",
    };
}

fn outcomeFromRuntime(self: *Vm, r: runtime.EvalResult) CallOutcome {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| switch (e) {
            .Thrown => |v| .{ .threw = v },
            else => .{ .failed = vmEvalMessage(self.allocator, e) },
        },
    };
}

pub fn vmPrepare(self: *Vm) Allocator.Error!?VmError {
    try vmPrepareResolved(self);
    return null;
}

/// Runs a program's `main` as `vmRunBody` does: a `suspend fun main` on the
/// cooperative pump, so a suspension parks instead of escaping, and
/// `main(args)` with the program's arguments.
pub fn vmCallMain(self: *Vm, func_id: FuncId) Allocator.Error!CallOutcome {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    const func = module.funcById(func_id) orelse return .{ .failed = "main not found" };
    const sink = self.out_sink.output();
    // The program's eager properties are initialized when it starts, then
    // the file declaring `main` before it runs, as the JVM initializes the
    // class whose `main` it launches.
    if (module.resolved != null) {
        var init_host = vmMakeHost(self, sink);
        if (try ir.eval.resolved_ops.runEagerUnits(VmHost, self.allocator, module, &init_host)) |e| return outcomeFromEval(self, .{ .err = e });
        if (try ir.eval.resolved_ops.ensureFacade(VmHost, self.allocator, module, &init_host, func_id)) |e| return outcomeFromEval(self, .{ .err = e });
    }
    if (func.is_suspend) {
        var intrinsic = VmIntrinsicHost.borrowed(sharedHandles(self));
        return outcomeFromRuntime(self, try vmhost.coroutines.driveSuspendMain(&intrinsic, func_id, sink));
    }
    var host = vmMakeHost(self, sink);
    var args: std.ArrayList(Value) = .empty;
    if (func.params.len >= 1) try args.append(self.allocator, try programArgsValue(self.allocator, self.program_args));
    const r = try ir.eval.evalWith(VmHost, self.allocator, module, func, args, &host);
    return outcomeFromEval(self, r);
}

/// The program's start for a host that runs no `main` (the test runner):
/// its eager properties initialized. Null when that went through.
pub fn vmStartProgram(self: *Vm) Allocator.Error!?CallOutcome {
    try vmPrepareResolved(self);
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    if (module.resolved == null) return null;
    var host = vmMakeHost(self, self.out_sink.output());
    if (try ir.eval.resolved_ops.runEagerUnits(VmHost, self.allocator, module, &host)) |e| return outcomeFromEval(self, .{ .err = e });
    return null;
}

/// Calls `func_id` of a module lowered from sema with `args`.
pub fn vmCallArgs(self: *Vm, func_id: FuncId, args: []const Value) Allocator.Error!CallOutcome {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    const func = module.funcById(func_id) orelse return .{ .failed = "function not found" };
    var host = vmMakeHost(self, self.out_sink.output());
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(self.allocator, args);
    for (list.items) |v| v.retain();
    return outcomeFromEval(self, try ir.eval.evalWith(VmHost, self.allocator, module, func, list, &host));
}

/// An instance of `class` of a module lowered from sema, built as
/// `RNewInstance` builds it with the constructor `ctor` and no arguments.
pub fn vmNewResolved(self: *Vm, class: ir.ClassId, ctor: FuncId) Allocator.Error!CallOutcome {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    const r = module.resolved orelse return .{ .failed = "the module has no resolved tables" };
    if (class.int() >= r.classes.len) return .{ .failed = "class not in the tables" };
    // A host-backed class's constructor makes the host value itself.
    if (ctor.int() < r.func_native.len and r.func_native[ctor.int()] != .none) {
        var host = vmMakeHost(self, self.out_sink.output());
        return outcomeFromEval(self, try host.callNative(self.allocator, r.func_native[ctor.int()], &.{}));
    }
    const st = self.resolved_state orelse return .{ .failed = "no resolved state" };
    const identity = st.cell.data.takeIdentity();
    const inst = try ir.resolved.instantiate(self.allocator, r, class, identity);
    return vmCallArgs(self, ctor, &.{inst});
}

/// A throwable's `toString()`, which heads its stack trace: its class's own
/// through the `Any.toString` slot. Null for a value the tables do not
/// class, or when the call does not answer a string.
pub fn vmThrowableText(self: *Vm, allocator: Allocator, v: *const Value) Allocator.Error!?[]const u8 {
    const r = self.module.asPtrConst().resolved orelse return null;
    if (v.* != .Instance) return null;
    const cls = ir.resolved.classOf(r, v) orelse return null;
    const slot = r.well_known.get(.to_string) orelse return null;
    const target = ir.resolved.slotTarget(r, cls, slot) orelse return null;
    switch (try vmCallArgs(self, target, &.{v.*})) {
        .ok => |t| if (t == .String) return try allocator.dupe(u8, t.String.asPtrConst().bytes),
        else => {},
    }
    return null;
}

fn throwableHeader(ctx: *anyopaque, allocator: Allocator, v: *const Value) Allocator.Error!?[]const u8 {
    const self: *Vm = @ptrCast(@alignCast(ctx));
    return vmThrowableText(self, allocator, v);
}

/// An uncaught throwable as the JVM reports one that ends `main`:
/// `Exception in thread "main" ` and its stack trace, each header its
/// `toString()`.
pub fn vmUncaughtText(self: *Vm, allocator: Allocator, v: *const Value) Allocator.Error![]const u8 {
    return vmThreadUncaughtText(self, allocator, v, "main");
}

/// `vmUncaughtText` for a throwable that ends the thread `thread`.
pub fn vmThreadUncaughtText(self: *Vm, allocator: Allocator, v: *const Value, thread: []const u8) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.print(allocator, "Exception in thread \"{s}\" ", .{thread});
    try ir.eval.formatThrowableWith(allocator, v, &text, .{ .ctx = self, .render = throwableHeader });
    return text.items;
}

/// What the JVM's default handler prints ahead of a trace that ends `main`.
pub const uncaught_prefix = "Exception in thread \"main\" ";

/// Prepare the Vm, run `body`, then drain workers; a startup `VmError` skips `body`.
pub fn vmRunCalls(
    self: *Vm,
    out: Output,
    comptime Ctx: type,
    ctx: Ctx,
    comptime body: fn (Ctx, *Vm) Allocator.Error!void,
) Allocator.Error!?VmError {
    gcRegisterVm(self);
    self.out_sink.attach(out);
    runtime.gc.alloc_perm = false;
    runtime.gc.program_started = true;
    vmhost.coroutines.gcThreadEnter();
    defer vmhost.coroutines.gcThreadExit();
    _ = live_vm_runs.fetchAdd(1, .acq_rel);
    defer _ = live_vm_runs.fetchSub(1, .acq_rel);
    // The thread running the program is the JVM's "main".
    const tid = std.Thread.getCurrentId();
    runtime.setThreadName(tid, "main");
    defer runtime.clearThreadName(tid);
    runtime.setProgramThread(tid);
    defer runtime.setProgramThread(0);
    const prep = try vmPrepare(self);
    if (prep == null) {
        const clock_held = vmhost.coroutines.threadClockBegin();
        defer if (clock_held) vmhost.coroutines.threadClockEnd();
        try body(ctx, self);
    }
    _ = joinAllThreads(self, .{ .ok = .{ .Unit = {} } });
    self.out_sink.replayInto(out);
    return prep;
}

/// Join every outstanding spawned and dispatched worker; a child's error surfaces only
/// when `main` succeeded. The last join is the only run-boundary seam on the driver
/// thread alone, so it drains the slot-owner registry before the next run resets its arena.
fn joinAllThreads(self: *Vm, result: VmResult) VmResult {
    var out = result;
    // A nested join owns only its own explicit threads; the abandon flags, the
    // shared dispatcher pool and the run-scoped registries belong to the outermost run.
    const outermost = live_vm_runs.load(.acquire) <= 1;
    if (outermost) {
        // Every worker still running user code must stop cooperatively, or a leaked
        // spinner holds the join open. Pool shutdown clears it, so re-arm each pass.
        runtime.setRunBoundaryAbandon(true);
        runtime.requestAbandon();
    }
    defer if (outermost) {
        runtime.setRunBoundaryAbandon(false);
        runtime.clearAbandon();
    };
    // Once both populations drain, sweep the process-global registries keyed into this
    // run's graph: slot owners, persisted continuations, per-library run-scoped state.
    defer if (outermost) runtime.runBoundarySweep();
    defer if (outermost) vmhost.coroutines.drainVirtualClock();
    defer if (outermost) vmhost.coroutines.drainPersistedParked();
    defer if (outermost) vmhost.coroutines.drainMainQueue();
    defer if (outermost) vmhost.coroutines.drainSlotOwners();
    // The two populations drain in turn: explicit threads (which may post tasks)
    // then the dispatcher pool (whose tasks may spawn threads), until both empty.
    // The next run's first timer post starts a fresh timer thread.
    defer if (outermost) vmhost.coroutines.timerServiceReopen();
    while (true) {
        var joined_any = false;
        if (outermost) runtime.requestAbandon();
        // An explicit thread joined below may still wait on a pool timer.
        if (outermost) vmhost.coroutines.timerServiceReopen();
        while (true) {
            // Take one handle under the lock and join it without holding the lock,
            // so the worker's own result publication cannot deadlock against it.
            const id = blk: {
                const g = self.threads.borrowMut();
                defer g.deinit();
                var it = g.get().iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.handle != null) break :blk entry.key_ptr.*;
                }
                break :blk null;
            };
            const tid = id orelse break;
            joined_any = true;

            const handle = blk: {
                const g = self.threads.borrowMut();
                defer g.deinit();
                if (g.get().getPtr(tid)) |entry| {
                    const h = entry.handle;
                    entry.handle = null;
                    break :blk h;
                }
                break :blk null;
            };
            if (handle) |h| {
                // join() establishes happens-before with the worker's writes.
                // Blocked, the joining thread counts as parked for a
                // collection the worker starts.
                runtime.gc.enterBlockingSafe();
                h.join();
                runtime.gc.exitBlockingSafe();
            }
            const g = self.threads.borrow();
            defer g.deinit();
            if (out == .ok) {
                if (g.get().get(tid)) |entry| {
                    if (entry.result) |res| switch (res) {
                        .ok => {},
                        .err => |e| out = .{ .err = .{ .Eval = vmEvalMessage(self.allocator, e) } },
                    };
                }
            }
        }
        if (!outermost) {
            if (!joined_any) break;
            continue;
        }
        // The timer thread stops before the pool, so no timer it fires can post
        // to a pool that has shut down; a pool task stopping meanwhile finds
        // its timer posts dropped.
        vmhost.coroutines.timerServiceStop();
        const pool_had_work = vmhost.scheduler.outstandingOther() != 0;
        vmhost.scheduler.shutdownAndJoin();
        if (out == .ok) {
            if (vmhost.scheduler.takeFirstError()) |e| {
                out = .{ .err = .{ .Eval = vmEvalMessage(self.allocator, e) } };
            }
        } else {
            _ = vmhost.scheduler.takeFirstError();
        }
        if (!joined_any and !pool_had_work) break;
    }
    return out;
}

fn vmEvalMessage(allocator: Allocator, e: RuntimeError) []const u8 {
    return switch (e) {
        .Unbound => |s| s,
        .Type => |s| s,
        .Arity => |s| s,
        .Unimplemented => |s| s,
        .CalleeFailed => |s| s,
        .NoMain => "no main function",
        else => std.fmt.allocPrint(allocator, "{any}", .{e}) catch "spawned thread error",
    };
}

fn vmErrorFromEval(allocator: Allocator, e: EvalError) VmError {
    switch (e) {
        .Throw => |v| {
            var buf: std.ArrayList(u8) = .empty;
            switch (v) {
                .Exception, .Instance => {
                    buf.appendSlice(allocator, uncaught_prefix) catch return .{ .Eval = uncaught_prefix };
                    ir.eval.formatThrowable(allocator, &v, &buf, false, 0) catch {};
                },
                else => {
                    buf.appendSlice(allocator, uncaught_prefix ++ "<thrown value>") catch return .{ .Eval = uncaught_prefix };
                },
            }
            const out = buf.toOwnedSlice(allocator) catch uncaught_prefix;
            return .{ .Eval = out };
        },
        .Unsupported => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Type => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Unbound => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Unimplemented => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .CalleeFailed => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Arity => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .StackOverflow => |s| return .{ .Eval = std.fmt.allocPrint(allocator, uncaught_prefix ++ "klio.StackOverflowError: {s}", .{s}) catch s },
        else => return .{ .Eval = "IR eval error" },
    }
}

/// Release every owned handle of the Vm. The pure arena profile drops everything en masse;
/// freeing profiles release the raw host containers here, and under tracing GC the releases
/// are inert since reachability owns the cells. Thread locals are cleared in every mode.
pub fn vmDeinit(self: *Vm) void {
    gcUnregisterVm(self);
    if (runtime.freeScratch()) {
        self.module.deinit();
        self.instance_id_counter.deinit();
        self.closures.deinit();
        self.out_sink.deinit();
        self.threads.deinit();
        if (self.resolved_state) |st| st.deinit();
    }
    vmhost.resetReceiverThreadLocals();
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}
