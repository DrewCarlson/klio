//! The `Vm` run loop and constructors: establishes a `Vm` around a lowered IR
//! module, runs the startup pipeline, and drives `main` through the IR evaluator.
//! `object` and companion singletons initialize lazily at first access through
//! `host_globals.ensureObjectSingleton`, not at startup.

const std = @import("std");
const host_instances = @import("host_instances.zig");
const host_globals = @import("host_globals.zig");

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

/// Stdlib aliases go into globals up front, so Kotlin's default imports need no `import`.
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

pub fn vmFromBuilt(allocator: Allocator, built: *build.BuiltModule) Allocator.Error!struct { vm: Vm, main: ?FuncId } {
    var vm = try vmNew(allocator, built.module.clone());
    vm.classes.deinit();
    // Take the built class table, leaving an empty map so `built.deinit` is a no-op.
    const taken = built.classes;
    built.classes = ClassTable.init(allocator);
    vm.classes = try ObjRef(ClassTable).init(allocator, taken);

    // Copy the enum-entry thunks rather than move the list: the built list is arena-owned
    // and the Vm frees its containers with the VM allocator, which misreads that buffer.
    vm.enum_entry_arg_inits.deinit(allocator);
    vm.enum_entry_arg_inits = .empty;
    try vm.enum_entry_arg_inits.appendSlice(allocator, built.enum_entry_arg_inits.items);

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
        // The Vm owns the ordered list; the image borrows its slice for per-file clinit.
        prog.top_level_props_ordered = vm.top_level_props.items;

        // Move each dispatch-time side table into the image, swapping a fresh empty in.
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

        for (built.object_names.items) |n| try prog.object_names.put(n, {});
    }

    // Enum-entry overrides share the `anon_methods` table with anon-object methods.
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

/// `(class, method)` key for `anon_methods`, `\u{1f}`-joined as elsewhere in the Vm.
fn anonMethodKey(allocator: Allocator, class: []const u8, method: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class, method });
}

/// Install pack-provided host bindings, probed before `stdlib.implementation`
/// during dispatch so they shadow it. Call before `run`.
pub fn vmSetInstalledBindings(self: *Vm, bindings: stdlib.HostBindings) Allocator.Error!void {
    {
        const g = self.prog.borrowMut();
        defer g.deinit();
        g.get().installed_bindings.deinit();
        g.get().installed_bindings = try ObjRef(stdlib.HostBindings).init(self.allocator, bindings);
    }
    try linkProgramForms(self);
}

/// Resolve every symbol's executable form once against `installed_bindings`.
fn linkProgramForms(self: *Vm) Allocator.Error!void {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    {
        // Build the name->ClassId overlay once here so `classId` is O(1) at run time.
        const mm = module_ref.borrowMut();
        defer mm.deinit();
        try mm.get().buildClassIdMap(self.allocator);
        // Host-shadow set: a non-stdlib overlay fqn names a pack declaration whose
        // host binding is authoritative over its body, so a static bind defers to the walk.
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

/// Borrowed view of this Vm's shared handles; copies bump no refcount and own nothing.
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

/// `VmHost` borrowing this Vm's state for one evaluation; it owns nothing, no deinit.
pub fn vmMakeHost(self: *Vm, out: Output) VmHost {
    return VmHost.borrowed(sharedHandles(self), self.globals, out);
}

/// Snapshot of every handle a spawned OS thread needs for its own child `Vm`; the seed
/// carries `self.allocator` verbatim, sound under `assertSpawnAllocatorInvariant`.
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
        m.shade(&vm.globals.cell.hdr);
        m.shade(&vm.classes.cell.hdr);
        m.shade(&vm.class_default_outer.cell.hdr);
        // The lambda side-table spine traces nothing and its per-closure captures
        // stay alive through `markClosureHook`, so shading it would pin every closure.
        // Mid-construction singletons, anon-object receivers, image default Values.
        m.shade(&vm.object_states.cell.hdr);
        m.shade(&vm.singletons_by_id.cell.hdr);
        m.shade(&vm.anon_methods.cell.hdr);
        m.shade(&vm.prog.cell.hdr);
    }
}

/// Register a live Vm as a GC root (globals and class graph). Idempotent.
pub fn gcRegisterVm(vm: *const Vm) void {
    // The lazy-`sequence {}` continuation hooks are needed in every memory mode.
    runtime.gc.markSuspendHook = ir.eval.gcMarkSuspendStateOpaque;
    runtime.gc.freeSuspendHook = ir.eval.freeSuspendStateOpaque;
    // All Vms share one closure side table by handle clone; install it with the
    // liveness and lambda-identity hooks in every mode (GC hooks are inert when off).
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

/// Drop a finished Vm from the process root set; the process-lifetime callback
/// must never retain a pointer into a completed run's phase arena.
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

pub fn vmRunInner(self: *Vm, main: FuncId) Allocator.Error!VmResult {
    _ = live_vm_runs.fetchAdd(1, .acq_rel);
    defer _ = live_vm_runs.fetchSub(1, .acq_rel);
    const result = try vmRunBody(self, main);
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

    if (try vmPrepareInner(self, module, sink)) |verr| return .{ .err = verr };

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

/// Pre-main startup pipeline; null on success, else the failing `VmError`.
fn vmPrepareInner(self: *Vm, module: *const Module, sink: Output) Allocator.Error!?VmError {
    // Canonicalize name-bearing strings once per module so hot-path compares exit on
    // pointer equality; prepare is single-threaded, so the const cast is sound.
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
    // Settle each symbol's executable form before user code runs; idempotent when linked.
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

    // Enum classes initialize on first use; their entry thunks ride the program image.
    {
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        pg.get().enum_entry_arg_inits = self.enum_entry_arg_inits.items;
        pg.get().patch_allocator = self.patch_allocator;
    }

    // Top-level `const val`s are compile-time constants; bind them before the
    // object and companion initializers, which run first and may read one.
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

    // `object` singletons and companions are not constructed here: Kotlin initializes
    // one at first access, and every read path routes through `ensureObjectSingleton`.

    // Run top-level property initialisers before main so global reads see the
    // initial values; one already driven on demand is not re-run. While the pass
    // is mid-flight a forward read of a later annotated property observes its
    // declared type's default (JVM <clinit> semantics); the flag scopes that here.
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
            // This prop's file `<clinit>` is running, so a same-file forward read
            // defaults while a cross-file read drives. Guarding the prop itself keeps
            // a re-entrant drive of this file out of an unresolved cycle.
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
                // A top-level `val` whose initializer names a not-yet-consumed
                // symbol defers to on-access (`CalleeFailed` is the body-exit re-tag
                // of that condition); past its turn, a later read drives it.
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
        // Accepts a numeric FuncId or a function simple name.
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
    return null;
}

pub fn vmPrepare(self: *Vm) Allocator.Error!?VmError {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    return vmPrepareInner(self, mg.get(), self.out_sink.output());
}

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

pub fn vmConstruct(self: *Vm, class_id: ir.ClassId) Allocator.Error!CallOutcome {
    var intrinsic = VmIntrinsicHost.borrowed(sharedHandles(self));
    const r = try vmhost.intrinsic_host.construct(&intrinsic, class_id, &.{}, self.out_sink.output());
    return outcomeFromEval(self, r);
}

pub fn vmCallMethod(self: *Vm, receiver: *const Value, name: []const u8) Allocator.Error!CallOutcome {
    // Route through `callMember`, not `invokeMethod` (which flattens every
    // non-throw error to null), and pin `receiver` until the callee roots its params.
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePush(receiver.*);
    var host = vmMakeHost(self, self.out_sink.output());
    const r = try host.callMember(self.allocator, receiver, name, &.{});
    return outcomeFromEval(self, r);
}

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
    const prep = try vmPrepare(self);
    if (prep == null) try body(ctx, self);
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
    defer if (outermost) vmhost.coroutines.drainSlotOwners();
    // The two populations drain in turn: explicit threads (which may post tasks)
    // then the dispatcher pool (whose tasks may spawn threads), until both empty.
    while (true) {
        var joined_any = false;
        if (outermost) runtime.requestAbandon();
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

/// Release every owned handle of the Vm. The pure arena profile drops everything en masse;
/// freeing profiles release the raw host containers here, and under tracing GC the releases
/// are inert since reachability owns the cells. Thread locals are cleared in every mode.
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
    vmhost.resetReceiverThreadLocals();
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Free a `Func` body from `FuncBuilder.finish`; module `deinit` frees the list only.
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
