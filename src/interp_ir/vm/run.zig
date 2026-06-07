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
    const sched = try allocator.create(runtime.InProcessScheduler);
    sched.* = runtime.InProcessScheduler.init(allocator);

    return .{
        .module = module,
        .globals = globals,
        .scheduler = sched,
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
    // Top-level property initialiser order is preserved.
    vm.top_level_props.deinit(allocator);
    vm.top_level_props = .empty;
    for (built.top_level_props.items) |nf| {
        try vm.top_level_props.append(allocator, .{ .name = nf.name, .func = nf.func });
        try vm.prog.borrowMut().get().top_level_prop_inits.put(nf.name, nf.func);
    }
    return .{ .vm = vm, .main = built.main };
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

/// Build a `VmHost` bound to this Vm's shared state for the duration of
/// one evaluation. The immutable program image, closure table, id
/// counter, and stdout sink are shared by handle.
pub fn vmMakeHost(self: *Vm, out: Output) VmHost {
    return .{
        .globals = self.globals.clone(),
        .module = self.module.clone(),
        .scheduler = self.scheduler,
        .out = out,
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

/// A snapshot of every handle a freshly spawned OS thread needs to
/// materialize its own child `Vm`.
pub fn vmSpawnChild(self: *Vm) SendableVmSeed {
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
    var intrinsic = VmIntrinsicHost{
        .scheduler = self.scheduler,
        .module = self.module.clone(),
        .closures = self.closures.clone(),
        .globals = self.globals.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .allocator = self.allocator,
    };
    defer {
        intrinsic.module.deinit();
        intrinsic.closures.deinit();
        intrinsic.globals.deinit();
        intrinsic.classes.deinit();
        intrinsic.prog.deinit();
        intrinsic.anon_methods.deinit();
        intrinsic.class_default_outer.deinit();
        intrinsic.instance_id_counter.deinit();
        intrinsic.out_sink.deinit();
        intrinsic.threads.deinit();
    }
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

    // Run top-level property initialisers before main so global reads
    // against the env see the initial values.
    for (self.top_level_props.items) |nf| {
        if (nf.func.int() >= module.funcs.items.len) return .{ .err = .InvalidMain };
        const init_func = &module.funcs.items[nf.func.int()];
        var host = vmMakeHost(self, sink);
        defer hostDeinit(&host);
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

    if (main.int() >= module.funcs.items.len) return .{ .err = .InvalidMain };
    const func = &module.funcs.items[main.int()];
    var host = vmMakeHost(self, sink);
    defer hostDeinit(&host);
    var iface = host.hostInterface();
    const r = try ir.eval.evalWith(self.allocator, module, func, .empty, &iface);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = vmErrorFromEval(self.allocator, e) },
    };
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
        else => return .{ .Eval = "IR eval error" },
    }
}

/// Drop the shared handles a `VmHost` cloned in `vmMakeHost`.
fn hostDeinit(host: *VmHost) void {
    host.globals.deinit();
    host.module.deinit();
    host.instance_id_counter.deinit();
    host.classes.deinit();
    host.prog.deinit();
    host.anon_methods.deinit();
    host.class_default_outer.deinit();
    host.closures.deinit();
    host.out_sink.deinit();
    host.threads.deinit();
}

/// Release every owned handle of the Vm.
pub fn vmDeinit(self: *Vm) void {
    self.module.deinit();
    self.globals.deinit();
    self.scheduler.deinit();
    self.allocator.destroy(self.scheduler);
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
