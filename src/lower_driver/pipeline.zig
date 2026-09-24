//! The run path for real programs: sema over the base, the packs and the
//! program, the bridge, lowering from sema, then the VM on the resolved
//! instructions. `klio run`, `klio test` and the image commands drive it.

const std = @import("std");
const span = @import("span");
const sema = @import("sema");
const ir = @import("ir");
const runtime = @import("runtime");
const interp_ir = @import("interp_ir");

const Allocator = std.mem.Allocator;
const bridge = ir.bridge;
const lower = ir.lower_sema;
pub const base_image = @import("base_image.zig");

/// The files of one run, in the layers sema adds them: the base (the
/// stdlib and the packs) and the program.
pub const Sources = struct {
    base: []const sema.SourceFile,
    program: []const sema.SourceFile,
};

pub const Built = struct {
    s: *sema.Sema,
    br: *bridge.Bridge,
    prog: lower.Program,
};

/// Analyzes and lowers every body of `src`. Lowering errors stay in
/// `prog.errors`; a body that failed has no blocks.
/// How bodyless declarations bind: natives by FQN, receiver-qualified host
/// symbols for extensions, and host-served members of host-backed classes.
pub const Binding = struct {
    natives: bridge.NativeResolver,
    host_symbol: ?bridge.HostSymbolResolver = null,
    host_members: bool = false,
    spread_varargs: bool = false,
    constructors: ?bridge.NativeResolver = null,
    /// The members the VM implements over host values (`bridge.Options.host_fns`).
    host_fns: ?ir.resolved.HostFnResolver = null,
    /// The fast paths the VM puts in front of bodies (`bridge.Options.host_tries`).
    host_tries: ?ir.resolved.HostTryResolver = null,
};

pub fn build(a: Allocator, src: Sources, binding: Binding) !Built {
    var t = Timing.start();
    const s = try sema.Sema.init(a);
    try s.addFiles(src.base);
    t.mark("collect base");
    const base_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try s.addFiles(src.program);
    const program_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    t.mark("collect program");
    try sema.headers.resolveAllHeaders(s);
    t.mark("headers");
    try s.resolveBodies(&.{ .base, .pack, .program });
    t.mark("bodies");
    const out = try sema.output.build(s);
    t.mark("records");
    const layers = try a.dupe(bridge.Layer, &.{ base_layer, program_layer });
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const br = try bridge.build(a, s, .{ .natives = binding.natives, .host_symbol = binding.host_symbol, .host_members = binding.host_members, .spread_varargs = binding.spread_varargs, .constructors = binding.constructors, .host_fns = binding.host_fns, .host_tries = binding.host_tries, .records = out.files, .layers = layers });
    t.mark("bridge");
    const prog = try lower.lowerProgram(a, s, br);
    t.mark("lower");
    return .{ .s = s, .br = br, .prog = prog };
}

/// The base image of `base`: sema over the base alone, the bridge and the
/// lowering of every base body, serialized (`base_image.encode`). Owned by
/// `gpa`; `a` holds the build and can be dropped after.
pub fn bakeBase(a: Allocator, gpa: Allocator, base: []const sema.SourceFile, binding: Binding) ![]u8 {
    const s = try sema.Sema.init(a);
    try s.addFiles(base);
    const prefix: u32 = @intCast(s.syms.count());
    const layer: bridge.Layer = .{ .syms = prefix, .files = @intCast(s.files.items.len) };
    try sema.headers.resolveAllHeaders(s);
    try s.resolveBodies(&.{ .base, .pack });
    const out = try sema.output.build(s);
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const br = try bridge.build(a, s, .{ .natives = binding.natives, .host_symbol = binding.host_symbol, .host_members = binding.host_members, .spread_varargs = binding.spread_varargs, .constructors = binding.constructors, .host_fns = binding.host_fns, .host_tries = binding.host_tries, .records = out.files, .layers = try a.dupe(bridge.Layer, &.{layer}) });
    const prog = try lower.lowerProgram(a, s, br);
    return base_image.encode(gpa, a, s, br, &prog.lowered, prefix);
}

/// A build over the base image `image`: the base is collected, checked
/// against the image's digest and decoded from it; only the program's
/// bodies are analyzed and lowered. `error.Stale` when the image is not of
/// this base. `image` must outlive the result.
pub fn buildOnBase(a: Allocator, src: Sources, binding: Binding, image: []const u8) !Built {
    var t = Timing.start();
    const s = try sema.Sema.init(a);
    try s.addFiles(src.base);
    t.mark("collect base");
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const loaded = try base_image.decode(a, image, s, .{ .natives = binding.natives, .constructors = binding.constructors, .host_fns = binding.host_fns, .host_tries = binding.host_tries });
    t.mark("load base image");
    const base_layer: bridge.Layer = .{ .syms = loaded.header.prefix, .files = @intCast(s.files.items.len) };
    try s.addFiles(src.program);
    const program_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    t.mark("collect program");
    try s.resolveBodies(&.{.program});
    t.mark("bodies");
    const out = try sema.output.build(s);
    t.mark("records");
    const layers = try a.dupe(bridge.Layer, &.{ base_layer, program_layer });
    const br = try bridge.buildOver(a, s, loaded.br, .{ .natives = binding.natives, .host_symbol = binding.host_symbol, .host_members = binding.host_members, .spread_varargs = binding.spread_varargs, .constructors = binding.constructors, .host_fns = binding.host_fns, .host_tries = binding.host_tries, .records = out.files, .layers = layers });
    t.mark("bridge");
    const prog = try lower.lowerProgramOver(a, s, br, loaded.lowered);
    t.mark("lower");
    return .{ .s = s, .br = br, .prog = prog };
}

/// `KLIO_SEMA_TIMING`: the milliseconds each step of `build` took.
pub const Timing = struct {
    last: u64,
    on: bool,

    pub fn start() Timing {
        return .{ .last = runtime.clockMonotonicNanos(), .on = std.c.getenv("KLIO_SEMA_TIMING") != null };
    }

    pub fn mark(self: *Timing, what: []const u8) void {
        if (!self.on) return;
        const now = runtime.clockMonotonicNanos();
        std.debug.print("[sema-timing] {s} {d}ms\n", .{ what, (now - self.last) / 1_000_000 });
        self.last = now;
    }
};

/// The program's entry point, found as the JVM finds one. A candidate is a
/// top-level `main` in a program file, neither generic nor an extension,
/// taking nothing, one `Array<String>` (nullable, `out`-projected or of
/// `String?` too) or `vararg String`, and returning `Unit`; it may
/// suspend. A parameterless `main` counts only in a file declaring no
/// `main` of the arguments' shape, whatever that one returns: kotlinc
/// bridges it to `main(String[])` only where the file has none, and the
/// launcher refuses a `main(String[])` that does not return void. Of the
/// files declaring one, the last given runs.
pub fn mainOf(s: *sema.Sema) Allocator.Error!?sema.Sym {
    var best: sema.Sym = .none;
    var best_file: u32 = 0;
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = sema.Sym.from(i);
        const takes_args = entryShape(s, sym) orelse continue;
        const file = s.syms.get(sym).file;
        if (best != .none and file < best_file) continue;
        if (try sema.headers.returnType(s, sym) != s.t.unit) continue;
        if (!takes_args and fileTakesArgs(s, file)) continue;
        best = sym;
        best_file = file;
    }
    return if (best == .none) null else best;
}

/// Whether file `file` declares a `main` of the arguments' shape.
fn fileTakesArgs(s: *sema.Sema, file: u32) bool {
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = sema.Sym.from(i);
        if (s.syms.get(sym).file != file) continue;
        if (entryShape(s, sym) orelse false) return true;
    }
    return false;
}

/// The file a run looks for its entry point in last, the program's last
/// file, by its name (`main.kt`).
pub fn mainFileName(s: *sema.Sema) []const u8 {
    var last: ?u32 = null;
    for (s.files.items, 0..) |f, i| {
        if (f.origin == .program) last = @intCast(i);
    }
    return std.fs.path.basename(s.files.items[last orelse return ""].path);
}

/// Whether `sym` has an entry point's name and parameters, and if so
/// whether it takes the program's arguments.
fn entryShape(s: *sema.Sema, sym: sema.Sym) ?bool {
    if (s.syms.kind(sym) != .function) return null;
    if (!std.mem.eql(u8, s.str(s.syms.name(sym)), "main")) return null;
    const owner = s.syms.owner(sym);
    if (owner == .none or s.syms.kind(owner) != .package) return null;
    const file = s.syms.get(sym).file;
    if (file >= s.files.items.len or s.files.items[file].origin != .program) return null;
    const info = s.syms.functionInfo(sym);
    if (info.type_params.len != 0 or info.receiver != .none or info.context_params.len != 0) return null;
    switch (info.params.len) {
        0 => return false,
        1 => {},
        else => return null,
    }
    const param = info.params[0];
    const ty = s.syms.paramInfo(param).ty;
    if (s.syms.flags(param).vararg) return if (s.types.classSym(ty) == s.builtins.string) true else null;
    if (s.types.classSym(ty) != s.builtins.array) return null;
    const args = s.types.argsOf(ty);
    if (args.len != 1 or args[0].variance == .in or args[0].ty == .none) return null;
    return if (s.types.classSym(args[0].ty) == s.builtins.string) true else null;
}

pub const Exec = struct {
    result: enum { ok, threw, failed },
    /// Why the run failed. For an uncaught throwable, what the JVM prints:
    /// `Exception in thread "main" ` and the throwable's stack trace, its
    /// `toString()`, the frames captured where it was made, and each cause
    /// after `Caused by: `.
    diag: []const u8 = "",
    /// The VM, when `ExecOptions.keep_vm` kept it up after `main`.
    vm: ?*interp_ir.Vm = null,
};

const MainCtx = struct { a: Allocator, main: ir.FuncId, outcome: *?interp_ir.CallOutcome, text: *?[]const u8 };

fn callMain(ctx: MainCtx, vm: *interp_ir.Vm) Allocator.Error!void {
    ctx.outcome.* = try vm.callMain(ctx.main);
    // An uncaught throwable renders while the VM is still up, which runs its
    // `toString()`.
    const o = ctx.outcome.* orelse return;
    if (o != .threw or (o.threw != .Instance and o.threw != .Exception)) return;
    ctx.text.* = try vm.uncaughtText(ctx.a, &o.threw);
}

pub const ExecOptions = struct {
    /// What `fun main(args: Array<String>)` receives.
    args: []const []const u8 = &.{},
    /// Asked once `main` returned: true keeps the VM up for a host that
    /// re-enters it later (a hosted UI's frame source), so it is not torn
    /// down. The build's arena must then stay alive too.
    keep_vm: ?*const fn () bool = null,
};

/// Runs `main` on the VM, writing the program's output to `out`. The VM
/// allocates the program's objects from `vm_a`, the process allocator the
/// collector frees through; `a` holds the build and the result's text.
pub fn execute(a: Allocator, vm_a: Allocator, br: *bridge.Bridge, main: ir.FuncId, out: runtime.Output, opts: ExecOptions) !Exec {
    const t_vm = runtime.clockMonotonicNanos();
    const module_ref = try runtime.ObjRef(ir.Module).init(a, br.m.*);
    const vm = try a.create(interp_ir.Vm);
    vm.* = try interp_ir.Vm.new(vm_a, module_ref);
    hooks.traceRun("vm init", t_vm);
    var exec = executeOn(a, vm, br, main, out, opts) catch |e| {
        vm.deinit();
        return e;
    };
    if (opts.keep_vm) |keep| {
        if (keep()) {
            exec.vm = vm;
            return exec;
        }
    }
    const t_d = runtime.clockMonotonicNanos();
    vm.deinit();
    hooks.traceRun("vm.deinit", t_d);
    return exec;
}

fn executeOn(a: Allocator, vm: *interp_ir.Vm, br: *bridge.Bridge, main: ir.FuncId, out: runtime.Output, opts: ExecOptions) !Exec {
    vm.program_args = opts.args;
    hooks.beforeMain();
    var outcome: ?interp_ir.CallOutcome = null;
    var text: ?[]const u8 = null;
    const t_main = runtime.clockMonotonicNanos();
    runtime.runstats.markExecStart();
    const prep = try vm.runCalls(out, MainCtx, .{ .a = a, .main = main, .outcome = &outcome, .text = &text }, callMain);
    runtime.runstats.markExecEnd();
    runtime.runstats.report();
    hooks.traceRun("main", t_main);
    hooks.afterMain(br.m);
    if (prep) |e| return .{ .result = .failed, .diag = switch (e) {
        .InvalidMain => "invalid main",
        .Eval => |msg| msg,
    } };
    const o = outcome orelse return .{ .result = .failed, .diag = "main did not run" };
    return switch (o) {
        .ok => .{ .result = .ok },
        .threw => .{ .result = .threw, .diag = text orelse interp_ir.uncaught_prefix ++ "<thrown value>" },
        .failed => |msg| .{ .result = .failed, .diag = msg },
    };
}

/// The profiling and diagnostic switches a run honors, around the program:
/// `KLIO_PROF`, `KLIO_OP_PROF`, `KLIO_FN_PROF`, the frame counts, the call
/// stats, the fused tier's probes, `KLIO_RUN_STATS`, `KLIO_TRACE_RUN`,
/// `KLIO_SLAB_STAT` and `KLIO_PUMP_DIAG`.
pub const hooks = struct {
    /// Before anything of the run: the samplers that cover the whole
    /// process, and the per-run caches cleared.
    pub fn start() void {
        runtime.prof.opProfMaybeStart();
        runtime.prof.fnProfMaybeStart();
        ir.eval.frameCountInit();
        interp_ir.resetReceiverThreadLocals();
        interp_ir.resetRunGlobalCaches();
    }

    /// On the thread that runs the program, right before it: the build's
    /// scratch pages go back to the system, and the `KLIO_PROF` sampler
    /// starts (it is per thread).
    pub fn beforeMain() void {
        const t_trim = runtime.clockMonotonicNanos();
        const before = runtime.slab.mapped_bytes.load(.monotonic);
        if (runtime.envOnce("KLIO_SLAB_STAT") != null) runtime.slab.occupancyReport();
        runtime.slab.reclaimAll();
        if (traceRunOn()) {
            std.debug.print("[run]   trim {d}ms: mapped {d}mb -> {d}mb (rss {d}mb)\n", .{
                (runtime.clockMonotonicNanos() - t_trim) / 1_000_000,
                before / (1024 * 1024),
                runtime.slab.mapped_bytes.load(.monotonic) / (1024 * 1024),
                (runtime.currentRssKb() orelse 0) / 1024,
            });
        }
        runtime.prof.maybeStart();
    }

    /// Right after the program, on its thread: every report.
    pub fn afterMain(m: *const ir.Module) void {
        runtime.prof.maybeReport();
        dumps(m);
    }

    /// The counters' reports, after the program and anything it printed.
    pub fn dumps(m: *const ir.Module) void {
        if (runtime.envOnce("KLIO_PUMP_DIAG") != null) interp_ir.coroutines_diag.dumpSleepCounts();
        ir.eval.fnProfDump(m);
        ir.eval.frameCountDump(m);
        ir.eval.callStatsDump();
        ir.eval.fused.classifyRejectDump();
        ir.eval.fused.heavyReasonDump();
        ir.eval.fuseGateDump();
        ir.eval.opProfDump();
    }

    pub fn traceRunOn() bool {
        return runtime.envOnce("KLIO_TRACE_RUN") != null;
    }

    /// `[run]   <what> <ms>ms` since `t0`, under `KLIO_TRACE_RUN`.
    pub fn traceRun(comptime what: []const u8, t0: u64) void {
        if (!traceRunOn()) return;
        std.debug.print("[run]   " ++ what ++ " {d}ms\n", .{(runtime.clockMonotonicNanos() - t0) / 1_000_000});
    }
};


/// `path:line:col` of a span.
pub fn where(a: Allocator, map: *const span.SourceMap, sp: span.Span) ![]const u8 {
    const src = map.getChecked(sp.file) orelse return "<unknown>";
    const lc = src.lineCol(sp.start);
    return std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ src.path, lc.line, lc.col });
}

// ----------------------------------------------------------------- tests --

const testing = std.testing;
const driver = @import("lower_driver.zig");

const TestBuilt = struct { br: *bridge.Bridge, s: *sema.Sema, main: ir.FuncId };

/// `sources` over the miniature base, analyzed and lowered as a run does;
/// null while the lowering of some construct in it is not built.
fn testBuild(a: Allocator, sources: []const []const u8) !?TestBuilt {
    const an = try driver.analyze(a, sources);
    const prog = try lower.lowerProgram(a, an.s, an.br);
    if (prog.errors.items.len != 0) return null;
    const main_sym = (try an.mainSym()) orelse return error.TestUnexpectedResult;
    return .{ .br = an.br, .s = an.s, .main = an.br.funcOfOpt(main_sym) orelse return error.TestUnexpectedResult };
}

fn captured(a: Allocator, cap: *const runtime.CaptureOutput) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (cap.lines.items) |line| {
        try text.appendSlice(a, line);
        try text.append(a, '\n');
    }
    try text.appendSlice(a, cap.partial.items);
    return text.items;
}

test "main receives the arguments the run passes" {
    // Each program is its own run: the process-global caches keyed by the
    // addresses of a finished run's IR must not answer for another's.
    interp_ir.resetRunGlobalCaches();
    defer interp_ir.resetRunGlobalCaches();
    var mem = ir.eval.hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const b = try testBuild(a, &.{"fun main(args: Array<String>) { println(args.size); println(args[1]) }"}) orelse return error.SkipZigTest;
    var cap = runtime.CaptureOutput.init(a);
    const exec = try execute(a, a, b.br, b.main, cap.output(), .{ .args = &.{ "one", "two" } });
    try testing.expect(exec.result == .ok);
    try testing.expect(exec.vm == null);
    try testing.expectEqualStrings("2\ntwo\n", try captured(a, &cap));
}

fn programFunction(s: *sema.Sema, name: []const u8) ?sema.Sym {
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = sema.Sym.from(i);
        if (s.syms.kind(sym) != .function) continue;
        if (!std.mem.eql(u8, s.str(s.syms.name(sym)), name)) continue;
        const file = s.syms.get(sym).file;
        if (file < s.files.items.len and s.files.items[file].origin == .program) return sym;
    }
    return null;
}

fn keepVm() bool {
    return true;
}

test "a VM kept after main answers a later call into the program" {
    interp_ir.resetRunGlobalCaches();
    defer interp_ir.resetRunGlobalCaches();
    var mem = ir.eval.hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const b = try testBuild(a, &.{
        \\var frames = 0
        \\fun frame(): Int { frames += 1; return frames }
        \\fun main() { frame() }
    }) orelse return error.SkipZigTest;
    var cap = runtime.CaptureOutput.init(a);
    const exec = try execute(a, a, b.br, b.main, cap.output(), .{ .keep_vm = keepVm });
    try testing.expect(exec.result == .ok);
    const vm = exec.vm orelse return error.TestUnexpectedResult;
    defer vm.deinit();
    // The frame callback of a hosted UI re-enters the program this way: the
    // state `main` left is still there.
    const frame_sym = programFunction(b.s, "frame") orelse return error.TestUnexpectedResult;
    const frame = b.br.funcOfOpt(frame_sym) orelse return error.TestUnexpectedResult;
    const again = try vm.callArgs(frame, &.{});
    try testing.expect(again == .ok);
    try testing.expectEqual(@as(i32, 2), again.ok.Int);
}
