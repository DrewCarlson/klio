//! The `Vm` run loop and constructors.
//!
//! Establishes a `Vm` around a lowered IR module, runs the startup
//! pipeline (top-level property initialisers, enum-entry ctor args), and
//! drives `main` through the IR evaluator. `object` / companion
//! singletons are not part of startup: they initialize lazily at first
//! access through `host_globals.ensureObjectSingleton`.
//! Inherent methods over `*Vm`, exported under `Vm.*` aliases by the
//! module root.

const std = @import("std");
const host_instances = @import("host_instances.zig");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");
const build = @import("../build.zig");
const vmhost = @import("vmhost.zig");
const trace = @import("trace.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const Output = runtime.Output;
const SharedOutput = root.SharedOutput;
const RuntimeError = runtime.RuntimeError;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalError = ir.eval.EvalError;

const Vm = root.Vm;
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const ProgramImage = root.ProgramImage;
const SendableVmSeed = root.SendableVmSeed;
const VmError = root.VmError;
const VmResult = root.VmResult;
const ClassTable = root.ClassTable;
const OuterTable = root.OuterTable;
const AnonMethodEntry = root.AnonMethodEntry;
const SharedClosures = root.SharedClosures;

/// Build a Vm around an already-lowered IR module. Stdlib aliases
/// (`print`, `println`, `listOf`, …) are installed into globals up front
/// so identifiers covered by Kotlin's default imports resolve without an
/// explicit `import`.
pub fn vmNew(allocator: Allocator, module: ObjRef(Module)) Allocator.Error!Vm {
    var env = Env.init(allocator);
    for (stdlib.IMPLICIT_ALIASES) |alias| {
        if (stdlib.implementation(alias.fqn)) |func| {
            try env.define(alias.name, Value.internIntrinsic(alias.fqn, func));
        }
    }
    const globals = try ObjRef(Env).init(allocator, env);

    return .{
        .module = module,
        .globals = globals,
        .instance_id_counter = try ObjRef(std.atomic.Value(u64)).init(allocator, std.atomic.Value(u64).init(0)),
        .classes = try ObjRef(ClassTable).init(allocator, ClassTable.init(allocator)),
        .top_level_props = .empty,
        .enum_entry_arg_inits = .empty,
        .class_default_outer = try ObjRef(OuterTable).init(allocator, OuterTable.init(allocator)),
        .anon_methods = try root.AnonMethods.init(allocator, std.StringHashMap(AnonMethodEntry).init(allocator)),
        .closures = try SharedClosures.new(allocator),
        .prog = try ObjRef(ProgramImage).init(allocator, try ProgramImage.init(allocator)),
        .out_sink = try SharedOutput.new(allocator),
        .threads = try root.ThreadTable.init(allocator, std.AutoHashMap(u64, root.ThreadEntry).init(allocator)),
        .object_states = try root.ObjectStates.init(allocator, std.StringHashMap(root.ObjectInitState).init(allocator)),
        .singletons_by_id = try root.SingletonsById.init(allocator, std.AutoHashMap(u32, runtime.Value).init(allocator)),
        .allocator = allocator,
    };
}

/// Build a Vm from a fully-prepared `build.BuiltModule`. The recommended
/// entry point for the driver — it carries both the IR module and the
/// synthesised runtime `ClassDef` table.
pub fn vmFromBuilt(allocator: Allocator, built: *build.BuiltModule) Allocator.Error!struct { vm: Vm, main: ?FuncId } {
    var vm = try vmNew(allocator, built.module.clone());
    vm.classes.deinit();
    // Take ownership of the built class table; leave an empty map behind
    // so the `BuiltModule`'s own `deinit` is a no-op for it.
    const taken = built.classes;
    built.classes = ClassTable.init(allocator);
    vm.classes = try ObjRef(ClassTable).init(allocator, taken);

    // COPY the enum-entry ctor-arg thunks rather than moving the list: the
    // built list is arena-owned, and the Vm frees its own containers with
    // the VM allocator — under a GC run that is the slab, and freeing an
    // arena buffer through the slab reads a garbage page header at
    // teardown. The entries are plain values; the donor list stays with
    // `built` so its own deinit frees it where it was allocated.
    vm.enum_entry_arg_inits.deinit(allocator);
    vm.enum_entry_arg_inits = .empty;
    try vm.enum_entry_arg_inits.appendSlice(allocator, built.enum_entry_arg_inits.items);

    // Top-level property initialiser order is preserved.
    vm.top_level_props.deinit(allocator);
    vm.top_level_props = .empty;
    {
        const pg = vm.prog.borrowMut();
        defer pg.deinit();
        const prog = pg.get();
        for (built.top_level_props.items) |nf| {
            try vm.top_level_props.append(allocator, nf);
            try prog.top_level_prop_inits.put(nf.name, .{ .func = nf.func, .default = nf.default, .file = nf.file });
        }
        // The Vm owns the ordered list for the run; the program image borrows
        // its slice so the on-demand driver can run a file's clinit in order.
        prog.top_level_props_ordered = vm.top_level_props.items;

        // Move every dispatch-time side table into the program image. Each
        // map is swapped with a fresh empty so the `BuiltModule`'s own
        // `deinit` is a no-op for the moved table.
        prog.body_prop_inits.deinit();
        prog.body_prop_inits = built.body_prop_inits;
        built.body_prop_inits = build.PairFuncMap.init(allocator);

        prog.instance_prop_getters.deinit();
        prog.instance_prop_getters = built.instance_prop_getters;
        built.instance_prop_getters = build.PairFuncMap.init(allocator);

        prog.getter_prop_names.deinit();
        prog.getter_prop_names = built.getter_prop_names;
        built.getter_prop_names = std.StringHashMap(void).init(allocator);

        prog.instance_prop_setters.deinit();
        prog.instance_prop_setters = built.instance_prop_setters;
        built.instance_prop_setters = build.PairFuncMap.init(allocator);

        prog.instance_prop_private.deinit();
        prog.instance_prop_private = built.instance_prop_private;
        built.instance_prop_private = build.PairFuncMap.init(allocator);

        prog.parent_ctor_args.deinit();
        prog.parent_ctor_args = built.parent_ctor_args;
        built.parent_ctor_args = std.StringHashMap([]FuncId).init(allocator);

        prog.parent_ctor_arg_names.deinit();
        prog.parent_ctor_arg_names = built.parent_ctor_arg_names;
        built.parent_ctor_arg_names = std.StringHashMap([]const ?[]const u8).init(allocator);

        prog.init_blocks.deinit();
        prog.init_blocks = built.init_blocks;
        built.init_blocks = std.StringHashMap([]FuncId).init(allocator);

        prog.extension_props.deinit();
        prog.extension_props = built.extension_props;
        built.extension_props = build.PairFuncMap.init(allocator);

        prog.owner_keyed_ext_names.deinit();
        prog.owner_keyed_ext_names = built.owner_keyed_ext_names;
        built.owner_keyed_ext_names = std.StringHashMap(void).init(allocator);
        prog.nullable_ext_props.deinit();
        prog.nullable_ext_props = built.nullable_ext_props;
        built.nullable_ext_props = @TypeOf(built.nullable_ext_props).init(allocator);

        prog.extension_prop_setters.deinit();
        prog.extension_prop_setters = built.extension_prop_setters;
        built.extension_prop_setters = build.PairFuncMap.init(allocator);

        prog.extension_prop_delegates.deinit();
        prog.extension_prop_delegates = built.extension_prop_delegates;
        built.extension_prop_delegates = build.PairFuncMap.init(allocator);

        prog.secondary_ctors.deinit();
        prog.secondary_ctors = built.secondary_ctors;
        built.secondary_ctors = std.StringHashMap([]build.SecondaryCtorEntry).init(allocator);

        prog.primary_ctor_default_thunks.deinit();
        prog.primary_ctor_default_thunks = built.primary_ctor_default_thunks;
        built.primary_ctor_default_thunks = std.StringHashMap([]?FuncId).init(allocator);

        prog.class_delegates.deinit();
        prog.class_delegates = built.class_delegates;
        built.class_delegates = std.StringHashMap([]build.StrFunc).init(allocator);

        prog.func_defaults.deinit();
        prog.func_defaults = built.func_defaults;
        built.func_defaults = std.AutoHashMap(u32, []?FuncId).init(allocator);

        // `object_names` is a set in the program image; copy the names in.
        for (built.object_names.items) |n| try prog.object_names.put(n, {});
    }

    // Pre-populated enum-entry override methods land in the same
    // `anon_methods` side-table the Vm consults for anon-object +
    // local-class methods.
    {
        const ag = vm.anon_methods.borrowMut();
        defer ag.deinit();
        var it = built.enum_entry_methods.iterator();
        while (it.next()) |e| {
            const key = try anonMethodKey(allocator, e.key_ptr.a, e.key_ptr.b);
            try ag.get().put(key, .{
                .module = e.value_ptr.module.clone(),
                .func = e.value_ptr.func,
                .captures = &.{},
            });
        }
    }

    return .{ .vm = vm, .main = built.main };
}

/// `(class, method)` key for the `anon_methods` table, matching the
/// `\u{1f}`-joined key the rest of the Vm uses.
fn anonMethodKey(allocator: Allocator, class: []const u8, method: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class, method });
}

/// Install pack-provided host bindings. Probed before
/// `stdlib.implementation` during dispatch so a pack's FQN-keyed
/// bindings shadow the stdlib's default lookup. Called before `run`.
pub fn vmSetInstalledBindings(self: *Vm, bindings: stdlib.HostBindings) Allocator.Error!void {
    {
        const g = self.prog.borrowMut();
        defer g.deinit();
        g.get().installed_bindings.deinit();
        g.get().installed_bindings = try ObjRef(stdlib.HostBindings).init(self.allocator, bindings);
    }
    // Re-settle each symbol's single executable form against the new
    // overlay so dispatch consults the link-time form, not a per-call probe.
    try linkProgramForms(self);
}

/// Resolve every symbol's single executable form once against the current
/// `installed_bindings` overlay. The VM dispatch paths consult the recorded
/// form rather than probing the overlay per call.
fn linkProgramForms(self: *Vm) Allocator.Error!void {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    {
        // Build the name->ClassId overlay once here (single-threaded setup), so
        // `classId` is O(1) at run time instead of a linear scan over every
        // class (the dominant cost of `is`/`when` type checks).
        const mm = module_ref.borrowMut();
        defer mm.deinit();
        try mm.get().buildClassIdMap(self.allocator);
        // The HOST-SHADOW set: every non-stdlib overlay fqn names a pack
        // declaration whose host binding is authoritative over its
        // interpreted body (auto_bindings marks them overrides). A static
        // member bind consults this to leave those on the runtime walk's
        // binding preference.
        {
            const reg = &mm.get().registry;
            const bg = self.prog.borrow();
            defer bg.deinit();
            const ig = bg.get().installed_bindings.borrow();
            defer ig.deinit();
            var kit = ig.get().table.iterator();
            while (kit.next()) |entry| {
                const fqn = entry.key_ptr.*;
                if (std.mem.startsWith(u8, fqn, "kotlin.")) continue;
                const owned = reg.allocator.dupe(u8, fqn) catch continue;
                reg.host_shadowed_fqns.put(owned, {}) catch reg.allocator.free(owned);
            }
        }
    }
    const mg = module_ref.borrow();
    defer mg.deinit();
    const g = self.prog.borrowMut();
    defer g.deinit();
    try g.get().linkResolvedForms(mg.get());
}

/// A borrowed view over this Vm's shared program-state handles. Copying
/// the handles by value bumps no refcount; the `Vm` keeps every cell alive
/// for the view's whole lifetime, so the view owns nothing.
fn sharedHandles(self: *Vm) vmhost.SharedHandles {
    return .{
        .globals = self.globals,
        .module = self.module,
        .instance_id_counter = self.instance_id_counter,
        .classes = self.classes,
        .prog = self.prog,
        .anon_methods = self.anon_methods,
        .class_default_outer = self.class_default_outer,
        .closures = self.closures,
        .out_sink = self.out_sink,
        .threads = self.threads,
        .object_states = self.object_states,
        .singletons_by_id = self.singletons_by_id,
        .allocator = self.allocator,
    };
}

/// Build a `VmHost` that borrows this Vm's shared state for the duration of
/// one evaluation. The handles are copied by value with no refcount bump,
/// so the host owns nothing and is dropped just by going out of scope — the
/// `Vm` keeps every cell alive for the call's whole lifetime.
pub fn vmMakeHost(self: *Vm, out: Output) VmHost {
    return VmHost.borrowed(sharedHandles(self), self.globals, out);
}

/// A snapshot of every handle a freshly spawned OS thread needs to
/// materialize its own child `Vm`. The seed carries `self.allocator`
/// verbatim; the child allocates and frees against it on another thread.
/// That sharing is sound under Zig 0.16 only while the backing allocator
/// is thread-safe and nothing calls `.reset()`/`.deinit()` on it while a
/// worker is live — the two invariants documented and guarded at the live
/// spawn seam (`assertSpawnAllocatorInvariant` in `intrinsic_host.zig`).
/// Here we assert the cheaply-checkable part: a non-degenerate allocator.
pub fn vmSpawnChild(self: *Vm) SendableVmSeed {
    const ok = @intFromPtr(self.allocator.vtable) != 0;
    if (!ok and trace.invariantsEnabled()) {
        trace.invariant("kind=spawn_allocator site=vmSpawnChild detail=degenerate_allocator", .{});
    }
    std.debug.assert(ok);
    return .{
        .module = self.module.clone(),
        .globals = self.globals.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .closures = self.closures.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .object_states = self.object_states.clone(),
        .singletons_by_id = self.singletons_by_id.clone(),
        .allocator = self.allocator,
    };
}

/// Invoke a thread-body callable on this (child) Vm, writing through the
/// shared serialized sink.
pub fn vmRunThreadBlock(self: *Vm, block: *const Value) Allocator.Error!runtime.EvalResult {
    // The intrinsic host borrows the child Vm's shared handles by value (no
    // refcount bump) and runs for the duration of this one call on the same
    // (worker) thread, so it owns nothing and needs no matching deinit — the
    // child `Vm` keeps every cell alive across the call.
    var intrinsic = VmIntrinsicHost.borrowed(sharedHandles(self));
    const host = intrinsic.intrinsicHost();
    const r = try host.invokeCallable(block, &.{}, self.out_sink.output());
    return r;
}

/// Run the program's `main` function. All evaluation writes through one
/// shared serialized sink (`out_sink`); on completion the accumulated
/// output is replayed into the caller's `out` in order.
// ---- GC: the Vm program-graph root provider -----------------------------
var gc_vms: std.ArrayListUnmanaged(*const Vm) = .empty;
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
        m.shade(&vm.globals.cell.hdr);
        m.shade(&vm.classes.cell.hdr);
        m.shade(&vm.class_default_outer.cell.hdr);
        // The lambda side-table spine is permanent and traces nothing (its
        // per-closure captures/chain are kept alive by `markClosureHook` only
        // while a live value references the id), so it is NOT shaded here — that
        // strong root was the closure leak.
        // Object/companion singletons captured mid-construction, anon-object
        // method receivers, and the program image's default-value Values.
        m.shade(&vm.object_states.cell.hdr);
        m.shade(&vm.singletons_by_id.cell.hdr);
        m.shade(&vm.anon_methods.cell.hdr);
        m.shade(&vm.prog.cell.hdr);
    }
}

/// Register a live Vm as a GC root (its globals/class graph). Idempotent root
/// registration; the Vm pointer is stable for the run.
pub fn gcRegisterVm(vm: *const Vm) void {
    // The lazy-`sequence{}` builder continuation mark/free hooks are needed
    // regardless of the memory mode: `BuilderState.deinit` calls `freeSuspendHook`
    // under refcount teardown too. Install them unconditionally (idempotent).
    runtime.gc.markSuspendHook = ir.eval.gcMarkSuspendStateOpaque;
    runtime.gc.freeSuspendHook = ir.eval.freeSuspendStateOpaque;
    // All Vms share one closure side-table by handle clone; install it (and the
    // liveness + non-capturing-lambda singleton-identity hooks) with it. The
    // singleton-identity comparison must hold in every memory mode, so install
    // unconditionally — the GC mark/sweep hooks are inert when GC is off.
    root.gcInstallClosureHook(vm.closures);
    if (!runtime.gc.gc_enabled) return;
    if (!gc_vm_root_registered.swap(true, .monotonic)) runtime.gc.registerRoot(gcMarkAllVms);
    gcVmsLock();
    defer gcVmsUnlock();
    for (gc_vms.items) |registered| {
        if (registered == vm) return;
    }
    gc_vms.append(std.heap.page_allocator, vm) catch @panic("KGC: vm root registration failed");
}

/// Remove a finished Vm from the process root set. The root callback itself is
/// process-lifetime, but it must never retain a pointer into a completed
/// in-process test run's phase arena.
pub fn gcUnregisterVm(vm: *const Vm) void {
    if (!runtime.gc.gc_enabled) return;
    gcVmsLock();
    defer gcVmsUnlock();
    for (gc_vms.items, 0..) |registered, i| {
        if (registered == vm) {
            _ = gc_vms.swapRemove(i);
            return;
        }
    }
}

pub fn vmRun(self: *Vm, main: FuncId, out: Output) Allocator.Error!VmResult {
    gcRegisterVm(self);
    // Stream program output from here on: a run that hangs, loops, or is killed
    // must still show what it printed. `replayInto` below is then a no-op,
    // except for a caller that attaches nothing (the capture harnesses).
    self.out_sink.attach(out);
    // Close the permanent generation: everything minted up to here (the stdlib
    // image, the program's class/IR graph, the empty global/class tables) is
    // immortal and reference-stable; cells minted from here on are nursery and
    // tracked for sweep. Worker threads minting cells run program code only and
    // set their own threadlocal `alloc_perm = false` at thread entry.
    runtime.gc.alloc_perm = false;
    runtime.gc.program_started = true;
    // The main run thread joins the mutator set so a collection started by any
    // spawned worker stops it at a safe point before touching the shared heap.
    vmhost.coroutines.gcThreadEnter();
    defer vmhost.coroutines.gcThreadExit();
    const result = try vmRunInner(self, main);
    self.out_sink.replayInto(out);
    return result;
}

/// Sequential startup pipeline sharing mutable host state. Every exit —
/// including a failing top-level initializer, enum-entry init, or invalid
/// `main` — routes through `joinAllThreads`: outstanding worker threads
/// and the dispatcher pool must drain, and the process-global registries
/// (slot owners, persisted continuations, run-scoped library state) must
/// sweep, before the Vm and its arena tear down on any path.
/// Count of Vm runs live in this process. A nested run (a lazy
/// image-extend baking eager calls mid-program) must not treat its own
/// completion as THE run boundary: the abandon flags, the dispatcher
/// pool, and the run-scoped global registries all belong to the
/// outermost run, and raising the boundary from a nested join killed the
/// outer program's coroutines mid-flight.
var live_vm_runs = std.atomic.Value(usize).init(0);

pub fn vmRunInner(self: *Vm, main: FuncId) Allocator.Error!VmResult {
    _ = live_vm_runs.fetchAdd(1, .acq_rel);
    defer _ = live_vm_runs.fetchSub(1, .acq_rel);
    const result = try vmRunBody(self, main);
    // Join every still-running spawned thread before returning so a
    // program that omits an explicit `join()` does not lose a child's
    // writes (and the process does not outlive them, racing the next
    // run's ObjCell borrows). A child that threw surfaces here only if
    // `main` itself did not already fail.
    return joinAllThreads(self, result);
}

fn vmRunBody(self: *Vm, main: FuncId) Allocator.Error!VmResult {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    const sink = self.out_sink.output();

    if (try vmPrepareInner(self, module, sink)) |verr| return .{ .err = verr };

    const func = module.funcById(main) orelse return .{ .err = .InvalidMain };
    // A `suspend fun main` is driven through the cooperative coroutine pump
    // (kotlinc wraps it in `runSuspend`), so a real suspension such as
    // `delay` parks and resumes instead of escaping as a "suspended outside a
    // driver" error.
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
    // argv[1..]; empty under `klio run`), matching Kotlin's entry contract.
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

/// Build the `Array<String>` value bound to `main`'s parameter.
fn programArgsValue(a: Allocator, argv: []const []const u8) Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(a);
    for (argv) |s| {
        try list.append(a, .{ .String = try runtime.strInit(a, s) });
    }
    return runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, list));
}

/// Outcome of invoking a function/method/constructor into a prepared Vm.
/// `ok` carries the return value, `threw` the uncaught Kotlin Throwable, and
/// `failed` an interpreter-level error message (unbound symbol, arity, etc.).
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

/// Human-readable message for a non-throw `EvalError` (an interpreter-level
/// failure surfaced as a test failure rather than an assertion failure).
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

/// The pre-main startup pipeline, factored out so an embedder (the test
/// runner) can prepare a Vm and then invoke arbitrary entry points instead
/// of `main`. Returns `null` on success, or the `VmError` of a failing
/// top-level / enum-entry initializer. `module` and `sink` are already
/// borrowed by the caller.

fn instantiateEnumEntryBodies(self: *Vm, module: *const Module, sink: Output) Allocator.Error!?VmError {
    var enum_defs: std.ArrayList(runtime.ObjRef(runtime.ClassDef)) = .empty;
    defer {
        for (enum_defs.items) |d| d.deinit();
        enum_defs.deinit(self.allocator);
    }
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        var it = cg.get().valueIterator();
        while (it.next()) |d| {
            const dg = d.borrow();
            const keep = dg.get().is_enum and dg.get().enum_entries.len != 0;
            dg.deinit();
            if (keep) try enum_defs.append(self.allocator, d.clone());
        }
    }
    const pa = self.patch_allocator orelse self.allocator;
    for (enum_defs.items) |cdef| {
        var enum_fqn: []const u8 = undefined;
        var n_entries: usize = 0;
        {
            const dg = cdef.borrow();
            enum_fqn = dg.get().fqn;
            n_entries = dg.get().enum_entries.len;
            dg.deinit();
        }
        const enum_cid = module.classIdByFqn(enum_fqn) orelse continue;
        const enum_simple = if (std.mem.lastIndexOfScalar(u8, enum_fqn, '.')) |dot| enum_fqn[dot + 1 ..] else enum_fqn;
        const has_secondary = blk: {
            const dg = cdef.borrow();
            defer dg.deinit();
            if (dg.get().secondary_ctors.len != 0) break :blk true;
            // A vararg primary parameter needs the ordinary argument packing
            // too (an entry passing nothing still gets an empty array).
            for (module.classes.items[enum_cid.int()].primary_params) |prm| if (prm.is_vararg) break :blk true;
            break :blk false;
        };
        // The rebuilt entries are installed on the class before any is
        // constructed: an entry's construction runs user code (safe points),
        // and an instance held only in a local array between iterations is
        // unreachable to the collector, which swept the first entry while
        // the second was being built and left its fields dangling.
        const replaced: []runtime.ClassDef.EnumEntry = blk: {
            const dg = cdef.borrow();
            defer dg.deinit();
            const copy = try pa.alloc(runtime.ClassDef.EnumEntry, n_entries);
            @memcpy(copy, dg.get().enum_entries);
            break :blk copy;
        };
        {
            const dg = cdef.borrowMut();
            dg.get().enum_entries = replaced;
            dg.deinit();
        }
        for (0..n_entries) |i| {
            var entry_name: []const u8 = undefined;
            var current_class: []const u8 = "";
            var entry_rebuilt = false;
            {
                const dg = cdef.borrow();
                defer dg.deinit();
                const e = dg.get().enum_entries[i];
                entry_name = e.name;
                if (e.value == .Instance) {
                    const ig = e.value.Instance.borrow();
                    const icg = ig.get().class.borrow();
                    current_class = icg.get().name;
                    icg.deinit();
                    entry_rebuilt = ig.get().get("__enum_entry_built__") != null;
                    ig.deinit();
                }
            }
            const synth = try std.fmt.allocPrint(self.allocator, "${s}", .{entry_name});
            defer self.allocator.free(synth);
            const body_cid = module.classIdNestedIn(enum_cid, synth);
            // An enum declaring secondary constructors builds its entries
            // through the ordinary path too: the entry's arguments pick the
            // constructor (`ENTRY(5)` may reach `constructor(n: Int) :
            // this(n, "x")`), and its body runs as written.
            if (body_cid == null and !has_secondary) continue;
            if (body_cid != null and std.mem.eql(u8, current_class, synth)) continue;
            if (body_cid == null and entry_rebuilt) continue;
            var host = vmMakeHost(self, sink);
            var ctor_args: std.ArrayList(Value) = .empty;
            defer ctor_args.deinit(self.allocator);
            if (body_cid == null) {
                for (self.enum_entry_arg_inits.items) |init_entry| {
                    if (!std.mem.eql(u8, init_entry.class_name, enum_simple) or !std.mem.eql(u8, init_entry.entry_name, entry_name)) continue;
                    for (init_entry.funcs) |fid| {
                        const init_func = module.funcById(fid) orelse continue;
                        switch (try ir.eval.evalWith(VmHost, self.allocator, module, init_func, .empty, &host)) {
                            .ok => |val| try ctor_args.append(self.allocator, val),
                            .err => |e| return vmErrorFromEval(self.allocator, e),
                        }
                    }
                    break;
                }
            }
            const target_cid = body_cid orelse enum_cid;
            if (runtime.envOnce("KLIO_ENUM_INIT_TRACE") != null) std.debug.print("[enum-init] build {s}.{s} via {s} (body={}, secondary={}, nargs={d})\n", .{ enum_fqn, entry_name, module.classes.items[target_cid.int()].fqn, body_cid != null, has_secondary, ctor_args.items.len });
            // The name string and the constructor arguments are pinned until
            // the instance owns them: the header thunks run user code first.
            const preset_name: Value = .{ .String = try runtime.strInit(self.allocator, entry_name) };
            const entry_keepalive = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(entry_keepalive);
            runtime.keepalivePush(preset_name);
            runtime.keepalivePushSlice(ctor_args.items);
            host_instances.setEnumEntryPreset(.{
                .class_fqn = module.classes.items[target_cid.int()].fqn,
                .name = preset_name,
                .ordinal = Value.newInt(@intCast(i)),
            });
            const made = switch (try host_instances.newInstance(&host, self.allocator, target_cid, ctor_args.items, null)) {
                .ok => |v| v,
                .err => |e| {
                    host_instances.setEnumEntryPreset(null);
                    return vmErrorFromEval(self.allocator, e);
                },
            };
            host_instances.setEnumEntryPreset(null);
            if (made != .Instance) continue;
            if (body_cid == null) {
                // The marker is appended through the instance's own allocator:
                // a field list grown with the patch allocator is freed through
                // the slab at sweep.
                const g = made.Instance.borrowMut();
                defer g.deinit();
                try g.get().define(self.allocator, "__enum_entry_built__", .{ .Bool = true });
            }
            replaced[i].value = made;
        }
    }
    return null;
}

fn vmPrepareInner(self: *Vm, module: *const Module, sink: Output) Allocator.Error!?VmError {
    // Canonicalize name-bearing strings once per module, before any user
    // code runs, so hot-path name compares exit on pointer equality. The
    // shared borrow the callers hold guards nothing concurrent here —
    // prepare is single-threaded — so the const cast is sound.
    {
        const need = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().canonicalized_module_identity != self.module.identity();
        };
        if (need) {
            const pg = self.prog.borrowMut();
            defer pg.deinit();
            const cg = self.classes.borrowMut();
            defer cg.deinit();
            pg.get().canonicalizeProgramNames(@constCast(module), cg.get());
            pg.get().canonicalized_module_identity = self.module.identity();
        }
    }
    // Settle each symbol's single executable form before any user code
    // runs. `setInstalledBindings` already links when a pack overlay is
    // installed; this covers the no-overlay configurations (the embedded
    // run path, the bench harness) so every dispatch consults a populated
    // resolved-form table. Idempotent — skip if already linked for the
    // current overlay.
    {
        const linked = blk: {
            const g = self.prog.borrow();
            defer g.deinit();
            break :blk g.get().resolved_linked;
        };
        if (!linked) {
            const g = self.prog.borrowMut();
            defer g.deinit();
            try g.get().linkResolvedForms(module);
        }
    }

    // Top-level `const val`s are compile-time constants; bind them in
    // globals up front — before the object / companion initializers
    // below, which run ahead of the top-level property inits and may read
    // a top-level const.
    {
        var it = module.registry.class_const_inits.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.a.len != 0) continue;
            const v = try ir.eval.constToValue(self.allocator, e.value_ptr);
            const g = self.globals.borrowMut();
            g.get().define(e.key_ptr.b, v) catch {};
            g.deinit();
        }
    }

    // `object Foo { … }` singletons and companions are NOT constructed
    // here: Kotlin initializes an object lazily at its first access (and a
    // companion additionally at the first instantiation of its owning
    // class), and a never-referenced object never initializes. The
    // first-access gate lives in `host_globals.ensureObjectSingleton`;
    // every read path for a singleton routes through it.

    // Run top-level property initialisers before main so global reads
    // against the env see the initial values. A property already defined
    // (its initializer was driven on demand by an earlier initialiser via
    // `ensureTopLevelInited`) is not re-run: the initializer executes once.
    // While this pass is mid-flight, a forward read of a later annotated
    // property observes its declared type's default (JVM <clinit> field
    // semantics) instead of driving the initializer out of order; the flag
    // scopes that window to this loop alone.
    {
        vmhost.host_impl.setStartupInitsActive(true);
        defer vmhost.host_impl.setStartupInitsActive(false);
        for (self.top_level_props.items) |nf| {
            const init_func = module.funcById(nf.func) orelse return .InvalidMain;
            {
                const g = self.globals.borrow();
                const exists = g.get().lookup(nf.name) != null;
                g.deinit();
                if (exists) continue;
            }
            // This prop's file `<clinit>` is running for its initializer, so a
            // same-file forward read defaults while a cross-file read drives
            // (per-file lazy static init, not one global clinit). Guard the
            // prop itself too, so a re-entrant on-demand drive of this file
            // (an object this initializer constructs reads a later sibling)
            // skips the prop the startup pass is still evaluating instead of
            // re-driving it into an unresolved cycle.
            vmhost.host_impl.pushInitFile(nf.file);
            defer vmhost.host_impl.popInitFile(nf.file);
            vmhost.host_impl.pushInitProp(nf.name);
            defer vmhost.host_impl.popInitProp(nf.name);
            var host = vmMakeHost(self, sink);
            const r = try ir.eval.evalWith(VmHost, self.allocator, module, init_func, .empty, &host);
            switch (r) {
                .ok => |v| {
                    const g = self.globals.borrowMut();
                    defer g.deinit();
                    g.get().define(nf.name, v) catch {};
                },
                // A top-level `val` whose initializer references a not-yet-
                // consumed symbol is deferred to on-access; only a missing-
                // symbol failure defers. `CalleeFailed` is the body-exit
                // re-tag of the same missing-symbol condition. A deferred
                // property is past its turn, so later reads inside this
                // window drive it rather than defaulting it.
                .err => |e| switch (e) {
                    .Unbound, .Unimplemented, .CalleeFailed => {
                        if (runtime.envOnce("KLIO_TOPPROP_TRACE") != null) std.debug.print("[topprop-defer] {s}: {s}\n", .{ nf.name, @tagName(e) });
                        vmhost.host_impl.noteStartupDeferred(nf.name);
                    },
                    else => return vmErrorFromEval(self.allocator, e),
                },
            }
        }
    }

    if (runtime.envOnce("KLIO_DUMP_FN")) |w| {
        const dmg = self.module.borrow();
        defer dmg.deinit();
        // Accepts a numeric FuncId or a function simple name (dumps every
        // func bearing the name).
        const by_id: ?u32 = std.fmt.parseInt(u32, w, 10) catch null;
        for (dmg.get().funcs.items) |*df| {
            if (by_id) |want| {
                if (df.id.int() != want) continue;
            } else if (!std.mem.eql(u8, df.name, w)) continue;
            std.debug.print("[dumpfn] {s}#{d} blocks={d}\n", .{ df.fqn, df.id.int(), df.blocks.len });
            for (df.blocks, 0..) |blk, bi| {
                std.debug.print("[dumpfn] b{d}: catches={d} fin={?} fin_done={?} done_for={?} pop={d}\n", .{
                    bi,
                    blk.catches.len,
                    if (blk.finally) |x| @intFromEnum(x) else null,
                    if (blk.finally_done) |x| @intFromEnum(x) else null,
                    if (blk.finally_done_for) |x| @intFromEnum(x) else null,
                    blk.pop_on_exit.len,
                });
                for (blk.insts) |inst| {
                    switch (inst) {
                        .Trace => |t| std.debug.print("[dumpfn]   Trace {any}\n", .{t}),
                        .Call => |c| std.debug.print("[dumpfn]   Call func=#{d} n_args={d} exact={}\n", .{ c.func.int(), c.n_args, c.exact }),
                        .NewInstance => |ni| {
                            const cls = dmg.get().classes.items;
                            const nm = if (ni.class.int() < cls.len) cls[ni.class.int()].fqn else "?";
                            std.debug.print("[dumpfn]   NewInstance dst=r{d} class={s} n_args={d}\n", .{ ni.dst.int(), nm, ni.n_args });
                        },
                        .GetField => |gf| {
                            const cs = dmg.get().consts.items;
                            const nm = if (gf.field.int() < cs.len and cs[gf.field.int()] == .String) cs[gf.field.int()].String else "?";
                            std.debug.print("[dumpfn]   GetField dst=r{d} recv=r{d} field={s}\n", .{ gf.dst.int(), gf.receiver.int(), nm });
                        },
                        .LoadFromThisOrGlobal => |lg| {
                            const cs = dmg.get().consts.items;
                            const nm = if (lg.name.int() < cs.len and cs[lg.name.int()] == .String) cs[lg.name.int()].String else "?";
                            std.debug.print("[dumpfn]   LoadFromThisOrGlobal dst=r{d} name={s}\n", .{ lg.dst.int(), nm });
                        },
                        .CallMemberOrGlobal => |cg| {
                            const nm = blk: {
                                const cs = dmg.get().consts.items;
                                if (cg.name.int() < cs.len and cs[cg.name.int()] == .String)
                                    break :blk cs[cg.name.int()].String;
                                break :blk "?";
                            };
                            std.debug.print("[dumpfn]   CallMemberOrGlobal dst=r{d} name={s} n_args={d} func={?d} final={} class={?d} cands={d}\n", .{
                                cg.dst.int(),
                                nm,
                                cg.n_args,
                                if (cg.func) |f| f.int() else null,
                                cg.func_final,
                                if (cg.class) |c| c.int() else null,
                                if (cg.candidates) |cl| cl.len else 0,
                            });
                        },
                        .MakeCell => |mc| std.debug.print("[dumpfn]   MakeCell dst=r{d}\n", .{mc.dst.int()}),
                        .CellSet => |cs| std.debug.print("[dumpfn]   CellSet cell=r{d} value=r{d}\n", .{ cs.cell.int(), cs.value.int() }),
                        .CellGet => |cg2| std.debug.print("[dumpfn]   CellGet dst=r{d} cell=r{d}\n", .{ cg2.dst.int(), cg2.cell.int() }),
                        .LoadCapture => |lc| std.debug.print("[dumpfn]   LoadCapture dst=r{d} idx={d}\n", .{ lc.dst.int(), lc.idx }),
                        .AstLambda => |al| {
                            std.debug.print("[dumpfn]   AstLambda dst=r{d} body=#{?d} caps=", .{ al.dst.int(), if (al.body_func) |bf| bf.int() else null });
                            for (al.captures) |cr| std.debug.print("r{d} ", .{cr.int()});
                            std.debug.print("\n", .{});
                        },
                        .CallMember => |cm| {
                            const nm = blk: {
                                const cs = dmg.get().consts.items;
                                if (cm.name.int() < cs.len and cs[cm.name.int()] == .String)
                                    break :blk cs[cm.name.int()].String;
                                break :blk "?";
                            };
                            std.debug.print("[dumpfn]   CallMember dst=r{d} recv=r{d} name={s} n={d} trailing={} static_recv={} declared_recv={} resolved={?d}\n", .{
                                cm.dst.int(),
                                cm.receiver.int(),
                                nm,
                                cm.n_args,
                                cm.trailing_lambda,
                                cm.static_recv != null,
                                cm.declared_recv != null,
                                if (cm.resolved) |r| r.int() else null,
                            });
                        },
                        .CallValue => |cv| std.debug.print("[dumpfn]   CallValue dst=r{d} callee=r{d} args=r{d} n={d}\n", .{ cv.dst.int(), cv.callee.int(), cv.args.int(), cv.n_args }),
                        .Move => |mv| std.debug.print("[dumpfn]   Move dst=r{d} src=r{d}\n", .{ mv.dst.int(), mv.src.int() }),
                        .UnOp => |uo| std.debug.print("[dumpfn]   UnOp dst=r{d} op={s} operand=r{d}\n", .{ uo.dst.int(), @tagName(uo.op), uo.operand.int() }),
                        else => std.debug.print("[dumpfn]   {s}\n", .{@tagName(std.meta.activeTag(inst))}),
                    }
                }
                std.debug.print("[dumpfn]   -> {s}\n", .{@tagName(std.meta.activeTag(blk.terminator))});
            }
        }
    }
    // An enum entry declared with a body (`B(args) { … }`) is an instance of
    // the nested class `$B : Enum(args)` the parser synthesized for it.
    // Construct it through the ordinary class path (parent constructor
    // arguments, property initializers, init blocks), carry the entry's
    // name and ordinal over, and make it the entry's value.
    if (try instantiateEnumEntryBodies(self, module, sink)) |err| return err;
    // Patch enum-entry instance fields with evaluated ctor args.
    for (self.enum_entry_arg_inits.items) |entry| {
        const class_def: ?runtime.ObjRef(runtime.ClassDef) = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(entry.class_name)) |d| break :blk d.clone();
            break :blk null;
        };
        const cdef = class_def orelse continue;
        defer cdef.deinit();
        // Entry instance + primary-param names off the runtime ClassDef.
        var param_names: std.ArrayList([]const u8) = .empty;
        defer param_names.deinit(self.allocator);
        var entry_inst: ?runtime.ObjRef(runtime.InstanceData) = null;
        {
            const dg = cdef.borrow();
            defer dg.deinit();
            for (dg.get().primary_params) |p| try param_names.append(self.allocator, p.name);
            for (dg.get().enum_entries) |e| {
                if (std.mem.eql(u8, e.name, entry.entry_name)) {
                    if (e.value == .Instance) entry_inst = e.value.Instance.clone();
                    break;
                }
            }
        }
        const inst = entry_inst orelse continue;
        defer inst.deinit();
        // An entry rebuilt through the ordinary instantiation path (a body
        // subclass, a secondary or vararg constructor) bound its constructor
        // fields there; patching those in again would define page-allocated
        // values into a slab-owned instance.
        {
            const g = inst.borrow();
            defer g.deinit();
            const icg = g.get().class.borrow();
            const built_class = icg.get().is_enum and icg.get().enum_entries.len == 0;
            icg.deinit();
            if (built_class or g.get().get("__enum_entry_built__") != null) continue;
        }
        // A cached base shares these instances across per-program Vms, and
        // the ctor args are per-class constants: once one Vm has patched the
        // fields, re-evaluating them would only swap equal values — and the
        // release of the previous Vm's value would cross allocators. Skip
        // entries whose fields are already complete.
        const already_patched = blk: {
            const g = inst.borrow();
            defer g.deinit();
            for (param_names.items) |pn| {
                if (g.get().get(pn) == null) break :blk false;
            }
            break :blk true;
        };
        if (already_patched) continue;
        for (entry.funcs, 0..) |fid, idx| {
            const init_func = module.funcById(fid) orelse continue;
            const v = blk: {
                var host = vmMakeHost(self, sink);
                switch (try ir.eval.evalWith(VmHost, self.allocator, module, init_func, .empty, &host)) {
                    .ok => |val| break :blk val,
                    .err => |e| return vmErrorFromEval(self.allocator, e),
                }
            };
            if (idx < param_names.items.len) {
                // The instance is shared through the base cache, so the value
                // stored must share the CACHE's lifetime: copy a string into
                // the patch allocator (scalars are by value; anything else is
                // left as-is and noted by the trace above when it appends).
                const pa = self.patch_allocator orelse self.allocator;
                const stored: Value = switch (v) {
                    .String => |sref| blk: {
                        const sg = sref.borrow();
                        defer sg.deinit();
                        break :blk .{ .String = try runtime.strInit(pa, sg.get().bytes) };
                    },
                    else => v,
                };
                const g = inst.borrowMut();
                // A baked enum instance carries every constructor-parameter
                // field, so this define REPLACES in place. An append here
                // means the bake dropped a field — name it, because the
                // shared image instance cannot grow a per-VM buffer.
                if (g.get().get(param_names.items[idx]) == null and
                    runtime.envOnce("KLIO_ENUM_INIT_TRACE") != null)
                {
                    std.debug.print("[enum-init-append] class={s} entry={s} field={s}\n", .{
                        entry.class_name, entry.entry_name, param_names.items[idx],
                    });
                }
                g.get().define(pa, param_names.items[idx], stored) catch {};
                g.deinit();
            }
        }
    }
    return null;
}

/// Run the pre-main startup pipeline against this Vm. Public entry for an
/// embedder that drives entry points other than `main` (the test runner).
pub fn vmPrepare(self: *Vm) Allocator.Error!?VmError {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    return vmPrepareInner(self, mg.get(), self.out_sink.output());
}

/// Invoke a top-level, no-argument function (a test function) on a prepared
/// Vm and classify the result.
pub fn vmCallNoArg(self: *Vm, func_id: FuncId) Allocator.Error!CallOutcome {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    const func = module.funcById(func_id) orelse return .{ .failed = "test function not found" };
    var host = vmMakeHost(self, self.out_sink.output());
    const r = try ir.eval.evalWith(VmHost, self.allocator, module, func, .empty, &host);
    return outcomeFromEval(self, r);
}

/// Construct an instance of `class_id` via its no-argument constructor.
pub fn vmConstruct(self: *Vm, class_id: ir.ClassId) Allocator.Error!CallOutcome {
    var intrinsic = VmIntrinsicHost.borrowed(sharedHandles(self));
    const r = try vmhost.intrinsic_host.construct(&intrinsic, class_id, &.{}, self.out_sink.output());
    return outcomeFromEval(self, r);
}

/// Invoke the no-argument method `name` on `receiver` (a test class's
/// `@BeforeTest`/`@Test`/`@AfterTest` method).
pub fn vmCallMethod(self: *Vm, receiver: *const Value, name: []const u8) Allocator.Error!CallOutcome {
    // Route through `callMember` directly (not `invokeMethod`, which flattens
    // every non-throw error to null) so a test method's real failure surfaces.
    // The test runner owns `receiver` in a Zig local rather than an evaluator
    // frame; pin it across dispatch until the called frame has rooted its params.
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePush(receiver.*);
    var host = vmMakeHost(self, self.out_sink.output());
    const r = try host.callMember(self.allocator, receiver, name, &.{});
    return outcomeFromEval(self, r);
}

/// Prepare the Vm, run `body` (which invokes entry points via the call
/// helpers above), then drain workers. Returns a startup `VmError` if
/// preparation failed (in which case `body` does not run). The shared output
/// sink mirrors the `main` run path: writes during `body` stream to `out` as
/// they happen.
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
    const prep = try vmPrepare(self);
    if (prep == null) try body(ctx, self);
    _ = joinAllThreads(self, .{ .ok = .{ .Unit = {} } });
    self.out_sink.replayInto(out);
    return prep;
}

/// Join every outstanding spawned/dispatched worker thread, called at the
/// end of `vmRunInner`. If `main` succeeded but a child threw, the
/// child's error is surfaced; if `main` already failed,
/// child errors are swallowed (the original failure wins).
///
/// After the last worker has joined this is the only run-boundary seam that
/// runs exclusively on the top-level driver thread (workers run through
/// `vmRunThreadBlock`, which never reaches here), so it is where the
/// process-global slot-owner registry is drained: any slot a driver left
/// registered on an error/abort/cancel path holds a clone of an arena-backed
/// `DriverWakeup`, and draining here — once no worker can still route through
/// it — keeps a stale entry from surviving into the next run's reset arena.
fn joinAllThreads(self: *Vm, result: VmResult) VmResult {
    var out = result;
    // A NESTED join (a mid-program image-extend's bake Vm) owns only its
    // own explicit threads. The abandon flags, the shared dispatcher
    // pool, and the run-scoped global registries belong to the outermost
    // run — raising the boundary here aborted the outer program's
    // coroutines at their next block edge.
    const outermost = live_vm_runs.load(.acquire) <= 1;
    if (outermost) {
        // The run's result is computed; every worker still executing user code
        // — explicit threads included — must stop cooperatively so a leaked
        // spinner or sleeper cannot hold this join open forever (the per-test
        // wall cap is already cleared here, and the pool's own abandonment
        // only begins after the explicit joins). The pool shutdown inside the
        // drain loop clears `abandon_requested` when it finishes; re-arm it at
        // each pass so the request stays live for stragglers.
        runtime.setRunBoundaryAbandon(true);
        runtime.requestAbandon();
    }
    defer if (outermost) {
        runtime.setRunBoundaryAbandon(false);
        runtime.clearAbandon();
    };
    // Once both worker populations have drained, sweep the process-global
    // registries that key into this run's value graph: the slot-owner and
    // persisted-continuation maps here, and each library layer's run-scoped
    // state (e.g. the kxco channel registry) through its registered
    // run-boundary hook.
    defer if (outermost) runtime.runBoundarySweep();
    defer if (outermost) vmhost.coroutines.drainVirtualClock();
    defer if (outermost) vmhost.coroutines.drainPersistedParked();
    defer if (outermost) vmhost.coroutines.drainSlotOwners();
    // Two worker populations drain in turn: explicit `kotlin.concurrent`
    // threads (which may still post dispatcher tasks) first, then the
    // dispatcher pool (whose tasks may have spawned threads). Loop until
    // a full pass leaves both empty.
    while (true) {
        var joined_any = false;
        // The pool-shutdown pass below clears the abandon request when it
        // finishes; re-arm for this pass's joins.
        if (outermost) runtime.requestAbandon();
        while (true) {
            // Take one outstanding handle under the lock, then join it
            // without holding the lock so the worker's own result
            // publication (which re-locks the table) cannot deadlock.
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
                h.join();
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

/// Render a child thread's `RuntimeError` into a `VmError.Eval` message.
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

/// Format an `EvalError` into a `VmError` (a thrown exception renders
/// its fqn + message).
fn vmErrorFromEval(allocator: Allocator, e: EvalError) VmError {
    switch (e) {
        .Throw => |v| {
            var buf: std.ArrayList(u8) = .empty;
            switch (v) {
                .Exception, .Instance => {
                    buf.appendSlice(allocator, "uncaught ") catch return .{ .Eval = "uncaught exception" };
                    ir.eval.formatThrowable(allocator, &v, &buf, false, 0) catch {};
                },
                else => {
                    buf.appendSlice(allocator, "uncaught throw") catch return .{ .Eval = "uncaught throw" };
                },
            }
            const out = buf.toOwnedSlice(allocator) catch "uncaught exception";
            return .{ .Eval = out };
        },
        .Unsupported => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Type => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Unbound => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Unimplemented => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .CalleeFailed => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Arity => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .StackOverflow => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "uncaught java.lang.StackOverflowError: {s}", .{s}) catch s },
        else => return .{ .Eval = "IR eval error" },
    }
}

/// Release every owned handle of the Vm.
///
/// The pure arena profile drops everything en masse. Freeing profiles still
/// release raw host containers here; under tracing GC the `ObjRef` releases are
/// inert and reachability owns their cells. Receiver/coroutine thread-locals are
/// cleared in every mode. Real OS thread handles were already joined by
/// `joinAllThreads`.
pub fn vmDeinit(self: *Vm) void {
    gcUnregisterVm(self);
    if (runtime.freeScratch()) {
        self.module.deinit();
        self.globals.deinit();
        self.instance_id_counter.deinit();
        self.classes.deinit();
        self.top_level_props.deinit(self.allocator);
        self.enum_entry_arg_inits.deinit(self.allocator);
        self.class_default_outer.deinit();
        self.anon_methods.deinit();
        self.closures.deinit();
        self.prog.deinit();
        self.out_sink.deinit();
        self.threads.deinit();
        self.object_states.deinit();
        self.singletons_by_id.deinit();
    }
    // The receiver/coroutine thread-locals are balanced within a run; assert
    // they are empty at the boundary and clear them so leaked-across-runs
    // state is a loud Debug failure for the next program in this thread. This
    // runs on both paths — it is a thread-local clear, not arena memory.
    vmhost.resetReceiverThreadLocals();
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Free a `Func` body produced by `FuncBuilder.finish` (the module's
/// `deinit` frees the `funcs` list but not each func's owned blocks).
fn freeFunc(func: ir.Func) void {
    for (func.blocks) |blk| {
        if (blk.insts.len != 0) testing.allocator.free(blk.insts);
        if (blk.catches.len != 0) testing.allocator.free(blk.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

test "vm runs a simple main returning an int const" {
    const FuncBuilder = ir.build.FuncBuilder;
    var module = Module.default(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &module);
    const r = try b.emitConst(.{ .Int = 42 });
    b.terminate(.{ .Return = r });
    const main_func = try b.finish("main", "main", ir.build.typeInt());
    b.deinit();
    const main_id = module.nextFuncId();
    var placed = main_func;
    placed.id = main_id;
    try module.funcs.append(testing.allocator, placed);
    try module.func_index.append(testing.allocator, .{ .name = "main", .id = main_id });
    try module.top_level.append(testing.allocator, main_id);
    try module.rebuildFuncNameIndex(testing.allocator);

    const module_ref = try ObjRef(Module).init(testing.allocator, module);
    var vm = try vmNew(testing.allocator, module_ref);

    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const res = try vmRun(&vm, main_id, cap.output());
    try testing.expect(res == .ok);
    try testing.expect(res.ok == .Int and res.ok.Int == 42);

    vmDeinit(&vm);
    freeFunc(placed);
}
