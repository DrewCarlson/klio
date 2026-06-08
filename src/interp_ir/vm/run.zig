//! The `Vm` run loop and constructors.
//!
//! Establishes a `Vm` around a lowered IR module, runs the startup
//! pipeline (object singletons, top-level property initialisers,
//! enum-entry ctor args), and drives `main` through the IR evaluator.
//! Inherent methods over `*Vm`, exported under `Vm.*` aliases by the
//! module root.

const std = @import("std");

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
            try env.define(alias.name, .{ .Intrinsic = .{ .fqn = alias.fqn, .func = func } });
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

    // Move the enum-entry ctor-arg thunks into the Vm; the startup pass
    // patches each entry's instance fields with their evaluated values.
    vm.enum_entry_arg_inits.deinit(allocator);
    vm.enum_entry_arg_inits = built.enum_entry_arg_inits;
    built.enum_entry_arg_inits = .empty;

    // Top-level property initialiser order is preserved.
    vm.top_level_props.deinit(allocator);
    vm.top_level_props = .empty;
    {
        const pg = vm.prog.borrowMut();
        defer pg.deinit();
        const prog = pg.get();
        for (built.top_level_props.items) |nf| {
            try vm.top_level_props.append(allocator, .{ .name = nf.name, .func = nf.func });
            try prog.top_level_prop_inits.put(nf.name, nf.func);
        }

        // Move every dispatch-time side table into the program image. Each
        // map is swapped with a fresh empty so the `BuiltModule`'s own
        // `deinit` is a no-op for the moved table (matching Rust's
        // by-value move in `from_built`).
        prog.body_prop_inits.deinit();
        prog.body_prop_inits = built.body_prop_inits;
        built.body_prop_inits = build.PairFuncMap.init(allocator);

        prog.instance_prop_getters.deinit();
        prog.instance_prop_getters = built.instance_prop_getters;
        built.instance_prop_getters = build.PairFuncMap.init(allocator);

        prog.instance_prop_setters.deinit();
        prog.instance_prop_setters = built.instance_prop_setters;
        built.instance_prop_setters = build.PairFuncMap.init(allocator);

        prog.parent_ctor_args.deinit();
        prog.parent_ctor_args = built.parent_ctor_args;
        built.parent_ctor_args = std.StringHashMap([]FuncId).init(allocator);

        prog.init_blocks.deinit();
        prog.init_blocks = built.init_blocks;
        built.init_blocks = std.StringHashMap([]FuncId).init(allocator);

        prog.extension_props.deinit();
        prog.extension_props = built.extension_props;
        built.extension_props = build.PairFuncMap.init(allocator);

        prog.extension_prop_setters.deinit();
        prog.extension_prop_setters = built.extension_prop_setters;
        built.extension_prop_setters = build.PairFuncMap.init(allocator);

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
    const g = self.prog.borrowMut();
    defer g.deinit();
    g.get().installed_bindings.deinit();
    g.get().installed_bindings = try ObjRef(stdlib.HostBindings).init(self.allocator, bindings);
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
pub fn vmRun(self: *Vm, main: FuncId, out: Output) Allocator.Error!VmResult {
    const result = try vmRunInner(self, main);
    self.out_sink.replayInto(out);
    return result;
}

/// Sequential startup pipeline sharing mutable host state.
pub fn vmRunInner(self: *Vm, main: FuncId) Allocator.Error!VmResult {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const module = mg.get();
    const sink = self.out_sink.output();

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

    // Allocate every `object Foo { … }` singleton FIRST, so a top-level
    // property initialiser that captures the object observes the same
    // instance the main body will (preserving `===` identity across init
    // contexts). Non-companion objects first, then synth companions: a
    // companion's `val` initializer may reference a top-level singleton.
    {
        var object_names: std.ArrayList([]const u8) = .empty;
        defer object_names.deinit(self.allocator);
        for (module.registry.object_names.items) |n| try object_names.append(self.allocator, n);
        // Stable sort: preserve source order within each rank, matching
        // Rust's `sort_by_key`.
        std.sort.insertion([]const u8, object_names.items, {}, lessByCompanionRank);
        for (object_names.items) |obj_name| {
            // Skip an object/companion already initialized on demand.
            {
                const gg = self.globals.borrow();
                const existing = gg.get().lookup(obj_name);
                gg.deinit();
                if (existing) |ev| {
                    if (ev == .Instance) continue;
                }
            }
            const class_id = module.classId(obj_name) orelse continue;
            const inst = blk: {
                var host = vmMakeHost(self, sink);
                var iface = host.hostInterface();
                switch (try iface.newInstance(self.allocator, class_id, &.{})) {
                    .ok => |v| break :blk v,
                    // Defer an object whose eager initializer throws — it is
                    // initialized on first access in `lookupGlobal` instead.
                    .err => continue,
                }
            };
            if (inst == .Instance) {
                if (std.mem.indexOf(u8, obj_name, "$Companion$")) |sep| {
                    const outer_name = obj_name[0..sep];
                    const outer_def: ?runtime.ObjRef(runtime.ClassDef) = blk: {
                        const cg = self.classes.borrow();
                        defer cg.deinit();
                        if (cg.get().get(outer_name)) |d| break :blk d.clone();
                        break :blk null;
                    };
                    if (outer_def) |od| {
                        const ig = inst.Instance.borrowMut();
                        ig.get().outer = .{ .Class = od };
                        ig.deinit();
                    }
                }
            }
            const g = self.globals.borrowMut();
            g.get().define(obj_name, inst) catch {};
            g.deinit();
        }
    }

    // Run top-level property initialisers before main so global reads
    // against the env see the initial values.
    for (self.top_level_props.items) |nf| {
        if (nf.func.int() >= module.funcs.items.len) return .{ .err = .InvalidMain };
        const init_func = &module.funcs.items[nf.func.int()];
        var host = vmMakeHost(self, sink);
        var iface = host.hostInterface();
        const r = try ir.eval.evalWith(self.allocator, module, init_func, .empty, &iface);
        switch (r) {
            .ok => |v| {
                const g = self.globals.borrowMut();
                defer g.deinit();
                g.get().define(nf.name, v) catch {};
            },
            // A top-level `val` whose initializer references a not-yet-
            // consumed symbol is deferred to on-access; only a missing-
            // symbol failure defers.
            .err => |e| switch (e) {
                .Unbound, .Unimplemented => {},
                else => return .{ .err = vmErrorFromEval(self.allocator, e) },
            },
        }
    }

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
            const eg = dg.get().enum_entries.borrow();
            defer eg.deinit();
            for (eg.get().items) |e| {
                if (std.mem.eql(u8, e.name, entry.entry_name)) {
                    if (e.value == .Instance) entry_inst = e.value.Instance.clone();
                    break;
                }
            }
        }
        const inst = entry_inst orelse continue;
        defer inst.deinit();
        for (entry.funcs, 0..) |fid, idx| {
            if (fid.int() >= module.funcs.items.len) continue;
            const init_func = &module.funcs.items[fid.int()];
            const v = blk: {
                var host = vmMakeHost(self, sink);
                var iface = host.hostInterface();
                switch (try ir.eval.evalWith(self.allocator, module, init_func, .empty, &iface)) {
                    .ok => |val| break :blk val,
                    .err => |e| return .{ .err = vmErrorFromEval(self.allocator, e) },
                }
            };
            if (idx < param_names.items.len) {
                const g = inst.borrowMut();
                g.get().define(self.allocator, param_names.items[idx], v) catch {};
                g.deinit();
            }
        }
    }

    if (main.int() >= module.funcs.items.len) return .{ .err = .InvalidMain };
    const func = &module.funcs.items[main.int()];
    var host = vmMakeHost(self, sink);
    var iface = host.hostInterface();
    const r = try ir.eval.evalWith(self.allocator, module, func, .empty, &iface);
    const result: VmResult = switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = vmErrorFromEval(self.allocator, e) },
    };
    // Join every still-running spawned thread before returning so a
    // program that omits an explicit `join()` does not lose a child's
    // writes (and the process does not outlive them, racing the next
    // run's ObjCell borrows). A child that threw surfaces here only if
    // `main` itself did not already fail.
    return joinAllThreads(self, result);
}

/// Join every outstanding spawned/dispatched worker thread, mirroring the
/// join-all loop at the end of Rust's `Vm::run`. If `main` succeeded but a
/// child threw, the child's error is surfaced; if `main` already failed,
/// child errors are swallowed (the original failure wins).
fn joinAllThreads(self: *Vm, result: VmResult) VmResult {
    var out = result;
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
    return out;
}

/// Render a child thread's `RuntimeError` into a `VmError.Eval` message,
/// mirroring Rust's `VmError::Eval(format!("{e}"))`.
fn vmEvalMessage(allocator: Allocator, e: RuntimeError) []const u8 {
    return switch (e) {
        .Unbound => |s| s,
        .Type => |s| s,
        .Arity => |s| s,
        .Unimplemented => |s| s,
        .NoMain => "no main function",
        else => std.fmt.allocPrint(allocator, "{any}", .{e}) catch "spawned thread error",
    };
}

/// Sort key for object-singleton initialisation order: non-companion
/// objects (`false`) precede synth companion objects (`true`), matching
/// Rust's `sort_by_key(|n| n.contains("$Companion$"))`.
fn lessByCompanionRank(_: void, a: []const u8, b: []const u8) bool {
    const ra = std.mem.indexOf(u8, a, "$Companion$") != null;
    const rb = std.mem.indexOf(u8, b, "$Companion$") != null;
    return @intFromBool(ra) < @intFromBool(rb);
}

/// Format an `EvalError` into a `VmError`, mirroring the Rust
/// `From<EvalError> for VmError` conversion (a thrown exception renders
/// its fqn + message).
fn vmErrorFromEval(allocator: Allocator, e: EvalError) VmError {
    switch (e) {
        .Throw => |v| {
            if (v == .Exception) {
                const ex = v.Exception;
                const fqn_g = ex.fqn.borrow();
                defer fqn_g.deinit();
                const fqn = fqn_g.get().*;
                var msg: []const u8 = "<no message>";
                if (ex.message) |m| {
                    const mg = m.borrow();
                    defer mg.deinit();
                    msg = mg.get().*;
                }
                const out = std.fmt.allocPrint(allocator, "uncaught {s}: {s}", .{ fqn, msg }) catch "uncaught exception";
                return .{ .Eval = out };
            }
            const out = std.fmt.allocPrint(allocator, "uncaught throw", .{}) catch "uncaught throw";
            return .{ .Eval = out };
        },
        .Unsupported => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Type => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Unbound => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Unimplemented => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .Arity => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "IR eval: {s}", .{s}) catch s },
        .StackOverflow => |s| return .{ .Eval = std.fmt.allocPrint(allocator, "uncaught java.lang.StackOverflowError: {s}", .{s}) catch s },
        else => return .{ .Eval = "IR eval error" },
    }
}

/// Release every owned handle of the Vm.
pub fn vmDeinit(self: *Vm) void {
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
    // The receiver/coroutine thread-locals are balanced within a run; assert
    // they are empty at the boundary and clear them so leaked-across-runs
    // state is a loud Debug failure for the next program in this thread.
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
    const main_id = FuncId.from(@intCast(module.funcs.items.len));
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
