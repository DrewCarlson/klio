//! `klio test`: runs a suite's tests through sema, the bridge and lowering
//! from sema, as `klio run` runs a program. Sema finds the tests: `kotlin.test`
//! annotations by identity, and for each test class the implementation of
//! every `@Test`, `@BeforeTest` and `@AfterTest` method it declares or
//! inherits. The report is the name-resolving runner's.

const std = @import("std");
const span = @import("span");
const sema = @import("sema");
const ir = @import("ir");
const runtime = @import("runtime");
const interp_ir = @import("interp_ir");
const lower_driver = @import("lower_driver");
const test_runner = @import("test_runner");

const io = @import("io.zig");
const sema_cmd = @import("sema_cmd.zig");
const sema_run = @import("sema_run.zig");
const test_report = @import("test_report.zig");

const Allocator = std.mem.Allocator;
const Sym = sema.Sym;
const pipeline = lower_driver.pipeline;

pub const Options = struct {
    only_files: []const []const u8 = &.{},
    filter: ?[]const u8 = null,
    format: test_report.TestFormat = .plain,
    list_only: bool = false,
};

pub fn run(gpa: Allocator, paths: []const []const u8, feature_specs: []const []const u8, opts: Options) u8 {
    pipeline.hooks.start();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var map = span.SourceMap.init(arena);
    span.active_map = &map;
    defer span.active_map = null;

    var load_report: sema_cmd.LoadReport = .{};
    const loaded = sema_cmd.loadSources(arena, &map, paths, .{ .feature_specs = feature_specs, .report_pack_failures = true, .report = &load_report, .test_roots = true, .image = true });
    io.writeStderr(load_report.syntax.items);
    const src = loaded catch |e| switch (e) {
        error.ProgramSyntax => return 1,
        error.ProgramUnreadable => {
            io.printStderr(gpa, "error: cannot read {s}: ReadFailed\n", .{load_report.unreadable.?.path});
            return 1;
        },
        else => {
            io.printStderr(gpa, "error: cannot load the tests: {s}\n", .{@errorName(e)});
            return 2;
        },
    };
    if (src.program.len == 0) {
        io.writeStderr("error: no `.kt` files found\n");
        return 1;
    }
    const built = sema_run.buildRun(gpa, arena, &map, src, sema_cmd.hostBinding(gpa)) catch |e| {
        io.printStderr(gpa, "error: the sema pipeline failed: {s}\n", .{@errorName(e)});
        return 2;
    };
    // What did not resolve or lower in the tests' own files: a test that
    // reaches it fails with it, the others run.
    {
        var out: std.ArrayList(u8) = .empty;
        _ = sema_run.programDiagnostics(arena, &map, src.program, &built, .Warning, &out) catch |e| {
            io.printStderr(gpa, "error: cannot report the tests' errors: {s}\n", .{@errorName(e)});
            return 2;
        };
        io.writeStderr(out.items);
        if (sema_run.programImportErrors(&built) != 0) return 1;
    }

    const plan = discover(arena, &built, opts) catch |e| {
        io.printStderr(gpa, "error: cannot find the tests: {s}\n", .{@errorName(e)});
        return 2;
    };
    if (opts.list_only) {
        for (plan.top) |t| io.printStdout(gpa, "{s}\n", .{t.display});
        for (plan.classes) |c| for (c.methods) |m| io.printStdout(gpa, "{s}\n", .{m.display});
        return 0;
    }

    test_runner.setReporter(if (opts.format == .ij) .teamcity else .plain);
    defer test_runner.setReporter(.plain);
    var stdout = io.StdoutSink{};
    const ran = runtime.runOnBigStackMainThread(RunCtx, RunOutcome, runEntry, .{ .gpa = gpa, .a = arena, .br = built.br, .plan = &plan, .out = stdout.output() });
    var report = ran.report orelse {
        io.printStderr(gpa, "error: {s}\n", .{@errorName(ran.err.?)});
        return 2;
    };
    defer report.deinit(gpa);
    if (test_report.printTestReport(gpa, &report, opts.format)) |code| return code;
    pipeline.hooks.dumps(built.br.m);
    return if (report.failed > 0) 1 else 0;
}

const RunCtx = struct { gpa: Allocator, a: Allocator, br: *ir.bridge.Bridge, plan: *const test_runner.ResolvedPlan, out: runtime.Output };
const RunOutcome = struct { report: ?test_runner.Report = null, err: ?anyerror = null };

fn runEntry(ctx: RunCtx) RunOutcome {
    const module_ref = runtime.ObjRef(ir.Module).init(ctx.a, ctx.br.m.*) catch |e| return .{ .err = e };
    // The program's objects come from the process allocator, which the
    // collector frees through; the build's arena never frees.
    var vm = interp_ir.Vm.new(ctx.gpa, module_ref) catch |e| return .{ .err = e };
    defer vm.deinit();
    // The `KLIO_PROF` sampler is per thread, and this thread runs the tests.
    runtime.prof.maybeStart();
    defer runtime.prof.maybeReport();
    const report =test_runner.runResolvedTests(ctx.gpa, &vm, ctx.plan, ctx.out) catch |e| return .{ .err = e };
    return .{ .report = report };
}

// -------------------------------------------------------------- discovery --

const Annotations = struct {
    test_: Sym,
    before: Sym,
    after: Sym,
    ignore: Sym,

    fn of(s: *sema.Sema) Annotations {
        return .{
            .test_ = s.classByFqn("kotlin.test.Test"),
            .before = s.classByFqn("kotlin.test.BeforeTest"),
            .after = s.classByFqn("kotlin.test.AfterTest"),
            .ignore = s.classByFqn("kotlin.test.Ignore"),
        };
    }
};

fn annotated(s: *sema.Sema, sym: Sym, cls: Sym) !bool {
    switch (s.syms.get(sym).decl) {
        .function, .class => {},
        else => return false,
    }
    return sema.headers.hasAnnotation(s, sym, .decl, cls);
}

fn selected(s: *sema.Sema, sym: Sym, only_files: []const []const u8) bool {
    const fc = s.fileOf(s.syms.get(sym).file) orelse return false;
    if (fc.origin != .program) return false;
    if (only_files.len == 0) return true;
    for (only_files) |of| {
        if (std.mem.eql(u8, fc.path, of) or std.mem.endsWith(u8, fc.path, of)) return true;
    }
    return false;
}

/// The tests of the program's files, in declaration order: top-level
/// `@Test` functions, then each concrete class with `@Test` methods.
pub fn discover(a: Allocator, built: *const pipeline.Built, opts: Options) !test_runner.ResolvedPlan {
    const s = built.s;
    const br = built.br;
    const anns = Annotations.of(s);
    var top: std.ArrayList(test_runner.ResolvedTop) = .empty;
    var classes: std.ArrayList(test_runner.ResolvedClass) = .empty;
    // By class: its function members in declaration order.
    var members: std.AutoHashMapUnmanaged(Sym, std.ArrayList(Sym)) = .empty;
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        if (s.syms.kind(sym) != .function) continue;
        const owner = s.syms.owner(sym);
        if (owner == .none or s.syms.kind(owner) != .class) continue;
        const gop = try members.getOrPut(a, owner);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, sym);
    }
    i = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        if (!selected(s, sym, opts.only_files)) continue;
        const owner = s.syms.owner(sym);
        if (owner == .none or s.syms.kind(owner) != .package) continue;
        switch (s.syms.kind(sym)) {
            .function => {
                if (!try annotated(s, sym, anns.test_)) continue;
                const name = s.str(s.syms.name(sym));
                if (!test_runner.filterMatches(opts.filter, name)) continue;
                const fid = br.funcOfOpt(sym) orelse continue;
                try top.append(a, .{ .display = name, .fid = fid, .ignored = try annotated(s, sym, anns.ignore) });
            },
            .class => if (try testClass(a, s, br, &members, anns, sym, opts.filter)) |c| try classes.append(a, c),
            else => {},
        }
    }
    return .{ .top = top.items, .classes = classes.items };
}

fn testClass(
    a: Allocator,
    s: *sema.Sema,
    br: *const ir.bridge.Bridge,
    members: *const std.AutoHashMapUnmanaged(Sym, std.ArrayList(Sym)),
    anns: Annotations,
    cls: Sym,
    filter: ?[]const u8,
) !?test_runner.ResolvedClass {
    const info = s.syms.classInfo(cls);
    if (info.kind != .class or s.syms.flags(cls).modality == .abstract) return null;
    const cid = br.classOfOpt(cls) orelse return null;
    const class_name = s.str(s.syms.name(cls));
    var methods: std.ArrayList(test_runner.ResolvedMethod) = .empty;
    var befores: std.ArrayList(ir.FuncId) = .empty;
    var afters: std.ArrayList(ir.FuncId) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    // The class, then its supertypes: a name the class overrides is its own.
    var queue: std.ArrayList(Sym) = .empty;
    var visited: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    try queue.append(a, cls);
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const c = queue.items[qi];
        if ((try visited.getOrPut(a, c)).found_existing) continue;
        if (members.get(c)) |fs| for (fs.items) |f| {
            const name = s.str(s.syms.name(f));
            const is_test = try annotated(s, f, anns.test_);
            const is_before = try annotated(s, f, anns.before);
            const is_after = try annotated(s, f, anns.after);
            if (!is_test and !is_before and !is_after) continue;
            if ((try seen.getOrPut(a, name)).found_existing) continue;
            const impl = implementation(br, cid, f) orelse continue;
            if (is_before) try befores.append(a, impl);
            if (is_after) try afters.append(a, impl);
            if (is_test) try methods.append(a, .{
                .display = try std.fmt.allocPrint(a, "{s}.{s}", .{ class_name, name }),
                .fid = impl,
                .ignored = try annotated(s, f, anns.ignore),
            });
        };
        for (try sema.headers.supertypes(s, c)) |st| {
            const sc = s.types.classSym(st);
            if (sc != .none) try queue.append(a, sc);
        }
    }
    // A class whose name matches keeps all its methods; otherwise each
    // method's name must.
    if (filter != null and (!test_runner.filterMatches(filter, class_name) or test_runner.filterHasNegation(filter))) {
        var kept: usize = 0;
        for (methods.items) |m| {
            if (!test_runner.filterMatches(filter, m.display)) continue;
            methods.items[kept] = m;
            kept += 1;
        }
        methods.shrinkRetainingCapacity(kept);
    }
    if (methods.items.len == 0) return null;
    return .{
        .cid = cid,
        .ctor = noArgConstructor(s, br, cls),
        .methods = methods.items,
        .befores = befores.items,
        .afters = afters.items,
        .class_ignored = try annotated(s, cls, anns.ignore),
    };
}

/// What `f`, declared by the class or a supertype, runs on an instance of
/// class `cid`: the override its slot dispatches to.
fn implementation(br: *const ir.bridge.Bridge, cid: ir.ClassId, f: Sym) ?ir.FuncId {
    const fid = br.funcOfOpt(f) orelse return null;
    if (fid.int() < br.slot_of.len) {
        if (br.m.methodSlotTarget(cid, br.slot_of[fid.int()])) |t| return t;
    }
    return fid;
}

fn noArgConstructor(s: *sema.Sema, br: *const ir.bridge.Bridge, cls: Sym) ?ir.FuncId {
    for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, sema.wk.init)) |ctor| {
        if (s.syms.kind(ctor) != .constructor) continue;
        if (s.syms.functionInfo(ctor).params.len != 0) continue;
        return br.funcOfOpt(ctor);
    }
    return null;
}
