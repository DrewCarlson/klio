//! Subcommand definitions for the `klio` CLI: lex, parse, run, check, repl.
//!
//! Each `run*` returns a
//! process exit code; diagnostics are rendered through the
//! `diagnostics.render` family. The full pipeline is
//! read .kt -> lexer -> parser -> resolver -> typeck -> ir lower ->
//! interp_ir run, with stdlib + kotlinx + ktor intrinsics registered.

const std = @import("std");

const span = @import("span");
const SourceMap = span.SourceMap;
const FileId = span.FileId;

const diagnostics = @import("diagnostics");
const DiagnosticSink = diagnostics.DiagnosticSink;
const Diagnostic = diagnostics.Diagnostic;
const Severity = diagnostics.Severity;
const render = diagnostics.render;

const lexer = @import("lexer");
const Lexer = lexer.Lexer;

const parser = @import("parser");
const Parser = parser.Parser;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;

const resolver = @import("resolver");
const typeck = @import("typeck");

const interp_ir = @import("interp_ir");
const Vm = interp_ir.Vm;

const runtime = @import("runtime");

const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const io = @import("io.zig");

const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;
const loadInstalledPacks = pack_cache.loadInstalledPacks;

const stdlib_image = @import("stdlib_image.zig");

const test_runner = @import("test_runner");

/// Output format for `klio check`. Mirrors `commands::DiagFormat`.
pub const DiagFormat = enum {
    Plain,
    Json,
    Sarif,
};

/// Read a source file into the map, returning its `FileId`. On failure
/// the error is printed to stderr and `null` is returned, mirroring the
/// Rust `load` helper.
fn load(gpa: std.mem.Allocator, map: *SourceMap, path: []const u8) ?FileId {
    const src = io.readFile(gpa, path) catch |e| {
        io.printStderr(gpa, "error: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return null;
    };
    defer gpa.free(src);
    return map.add(path, src) catch return null;
}

/// `klio check`: type-check `.kt` files and emit diagnostics. Exit 1 on
/// any error, 2 on usage/IO failure.
pub fn runCheck(
    gpa: std.mem.Allocator,
    files: []const []const u8,
    format: DiagFormat,
    features: *const RequestedFeatures,
) u8 {
    if (files.len == 0) {
        io.printStderr(gpa, "usage: klio check <file.kt> [--format=plain|json|sarif]\n", .{});
        return 2;
    }
    var map = SourceMap.init(gpa);
    defer map.deinit();
    var all = DiagnosticSink.init();
    defer all.deinit(gpa);

    var user_asts: std.ArrayList(KotlinFile) = .empty;
    defer user_asts.deinit(gpa);
    var user_file_ids = std.AutoHashMap(u32, void).init(gpa);
    defer user_file_ids.deinit();

    for (files) |path| {
        const id = load(gpa, &map, path) orelse return 2;
        user_file_ids.put(id.int(), {}) catch return 2;
        const src = map.get(id).source;
        var lx = Lexer.init(gpa, id, src) catch return 2;
        var lexed = lx.tokenize() catch return 2;
        defer lexed.deinit(gpa);
        for (lexed.diagnostics.diags()) |d| {
            all.emit(gpa, d) catch return 2;
        }
        const p = Parser.new(gpa, id, src, lexed.tokens);
        const file_ast = p.parseFile();
        for (p.diagnostics.diags()) |d| {
            all.emit(gpa, d) catch return 2;
        }
        user_asts.append(gpa, file_ast) catch return 2;
    }

    // Pack declarations the user imports participate in resolution +
    // type inference, but only diagnostics anchored in a user file are
    // surfaced — pack shims are trusted.
    const loaded = loadInstalledPacks(gpa, user_asts.items, &map, features);
    var combined: std.ArrayList(KotlinFile) = .empty;
    defer combined.deinit(gpa);
    combined.appendSlice(gpa, loaded.asts) catch return 2;
    combined.appendSlice(gpa, user_asts.items) catch return 2;

    // `gpa` here is the process-lifetime arena (`main.zig`), so the resolver
    // and type checker allocate their whole workspace from it and free
    // nothing — the arena reclaims everything at process exit.
    var native_fqns: std.ArrayList([]const u8) = .empty;
    defer native_fqns.deinit(gpa);
    {
        var it = loaded.bindings.table.keyIterator();
        while (it.next()) |k| {
            native_fqns.append(gpa, k.*) catch return 2;
        }
    }
    const r = resolver.resolveModuleWithNatives(gpa, combined.items, native_fqns.items) catch return 2;
    for (r.diagnostics.diags()) |d| {
        if (user_file_ids.contains(d.primary.span.file.int())) {
            all.emit(gpa, d) catch return 2;
        }
    }
    const tc = typeck.typecheckModule(gpa, combined.items, &r) catch return 2;
    for (tc.diagnostics.diags()) |d| {
        if (user_file_ids.contains(d.primary.span.file.int())) {
            all.emit(gpa, d) catch return 2;
        }
    }

    const diags = all.diags();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const rr = switch (format) {
        .Plain => render.plain.render(gpa, diags, &map, &buf),
        .Json => render.json.render(gpa, diags, &map, &buf),
        .Sarif => render.sarif.render(gpa, diags, &map, &buf),
    };
    rr catch |e| {
        io.printStderr(gpa, "render failed: {s}\n", .{@errorName(e)});
        return 2;
    };
    io.writeStdout(buf.items);

    var has_errors = false;
    for (diags) |d| {
        if (d.severity == .Error) has_errors = true;
    }
    return if (has_errors) 1 else 0;
}

/// `klio lex`: lex a source file and print tokens.
pub fn runLex(gpa: std.mem.Allocator, path: []const u8) u8 {
    var map = SourceMap.init(gpa);
    defer map.deinit();
    const id = load(gpa, &map, path) orelse return 1;
    const src = map.get(id).source;
    var lx = Lexer.init(gpa, id, src) catch return 1;
    var result = lx.tokenize() catch return 1;
    defer result.deinit(gpa);
    for (result.tokens) |tok| {
        io.printStdout(gpa, "{any}\n", .{tok.kind});
    }
    renderToStderr(gpa, &result.diagnostics, &map);
    return if (result.diagnostics.hasErrors()) 1 else 0;
}

/// `klio parse`: lex + parse a source file and print the AST.
pub fn runParse(gpa: std.mem.Allocator, path: []const u8) u8 {
    var map = SourceMap.init(gpa);
    defer map.deinit();
    const id = load(gpa, &map, path) orelse return 1;
    const src = map.get(id).source;
    var lx = Lexer.init(gpa, id, src) catch return 1;
    var lexed = lx.tokenize() catch return 1;
    defer lexed.deinit(gpa);
    renderToStderr(gpa, &lexed.diagnostics, &map);
    if (lexed.diagnostics.hasErrors()) return 1;
    const p = Parser.new(gpa, id, src, lexed.tokens);
    const file_ast = p.parseFile();
    renderToStderr(gpa, &p.diagnostics, &map);
    io.printStdout(gpa, "{any}\n", .{file_ast});
    return if (p.diagnostics.hasErrors()) 1 else 0;
}

/// `klio run` over multiple files (single-module semantics): every
/// file's top-level declarations are visible to every other file.
pub fn runModuleFiles(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    features: *const RequestedFeatures,
) u8 {
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    interp_ir.resetReceiverThreadLocals();
    if (tryImagePath(gpa, paths, features)) |code| return code;
    var map = SourceMap.init(gpa);
    defer map.deinit();
    var asts: std.ArrayList(KotlinFile) = .empty;
    defer asts.deinit(gpa);

    for (paths) |path| {
        const id = load(gpa, &map, path) orelse return 1;
        const src = map.get(id).source;
        var lx = Lexer.init(gpa, id, src) catch return 1;
        var lexed = lx.tokenize() catch return 1;
        defer lexed.deinit(gpa);
        renderToStderr(gpa, &lexed.diagnostics, &map);
        if (lexed.diagnostics.hasErrors()) return 1;
        const p = Parser.new(gpa, id, src, lexed.tokens);
        const file_ast = p.parseFile();
        renderToStderr(gpa, &p.diagnostics, &map);
        if (p.diagnostics.hasErrors()) return 1;
        asts.append(gpa, file_ast) catch return 1;
    }

    const loaded = loadInstalledPacks(gpa, asts.items, &map, features);
    // Pack ASTs first so the user's main wins when build_module_files
    // picks a `main` declaration.
    var all_asts: std.ArrayList(KotlinFile) = .empty;
    defer all_asts.deinit(gpa);
    all_asts.appendSlice(gpa, loaded.asts) catch return 1;
    all_asts.appendSlice(gpa, asts.items) catch return 1;

    return runBuilt(gpa, all_asts.items, loaded.bindings, &map, "runtime error: no main function in module");
}

/// `klio run` over a single source file through `interp_ir`'s Vm.
pub fn runFileIrVm(
    gpa: std.mem.Allocator,
    path: []const u8,
    features: *const RequestedFeatures,
) u8 {
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    // Catch any receiver/coroutine thread-local state leaked from a prior run
    // on this thread before assembling the next program.
    interp_ir.resetReceiverThreadLocals();
    if (tryImagePath(gpa, &.{path}, features)) |code| return code;
    var map = SourceMap.init(gpa);
    defer map.deinit();
    const id = load(gpa, &map, path) orelse return 1;
    const src = map.get(id).source;
    var lx = Lexer.init(gpa, id, src) catch return 1;
    var lexed = lx.tokenize() catch return 1;
    defer lexed.deinit(gpa);
    renderToStderr(gpa, &lexed.diagnostics, &map);
    if (lexed.diagnostics.hasErrors()) return 1;
    const p = Parser.new(gpa, id, src, lexed.tokens);
    const file_ast = p.parseFile();
    renderToStderr(gpa, &p.diagnostics, &map);
    if (p.diagnostics.hasErrors()) return 1;

    var user_asts: std.ArrayList(KotlinFile) = .empty;
    defer user_asts.deinit(gpa);
    user_asts.append(gpa, file_ast) catch return 1;

    const loaded = loadInstalledPacks(gpa, user_asts.items, &map, features);
    // Unified build path: a script and a pack-using program both flow
    // through `build_module_files`.
    var all_asts: std.ArrayList(KotlinFile) = .empty;
    defer all_asts.deinit(gpa);
    all_asts.appendSlice(gpa, loaded.asts) catch return 1;
    all_asts.appendSlice(gpa, user_asts.items) catch return 1;

    return runBuilt(gpa, all_asts.items, loaded.bindings, &map, "error: no main function found");
}

const TestRunCtx = struct {
    gpa: std.mem.Allocator,
    vm: *Vm,
    user_asts: []const KotlinFile,
    out: runtime.Output,
    time_mode: interp_ir.TimeMode,
    reclaim: bool,
};

/// Big-stack worker entry: re-establish the thread-local coroutine time mode
/// and reclaim flag (a fresh OS thread), then discover and run the tests.
fn testRunEntry(ctx: TestRunCtx) test_runner.Report {
    interp_ir.setCoroutineTimeMode(ctx.time_mode);
    runtime.setReclaim(ctx.reclaim);
    return test_runner.runTests(ctx.gpa, ctx.vm, ctx.user_asts, ctx.out) catch
        test_runner.Report{ .results = &.{}, .passed = 0, .failed = 1, .skipped = 0 };
}

/// `klio test` — discover and run `kotlin.test` `@Test` functions in the
/// given files/directories. Returns 1 if any test fails (or the module
/// fails to build), 0 otherwise.
pub fn runTestFiles(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    features: *const RequestedFeatures,
) u8 {
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    interp_ir.resetReceiverThreadLocals();

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    for (paths) |p| collectKtFiles(gpa, p, &files) catch {
        io.printStderr(gpa, "error: cannot read `{s}`\n", .{p});
        return 1;
    };
    if (files.items.len == 0) {
        io.writeStderr("error: no `.kt` files found\n");
        return 1;
    }

    var map = SourceMap.init(gpa);
    defer map.deinit();

    var user_asts: std.ArrayList(KotlinFile) = .empty;
    defer user_asts.deinit(gpa);
    for (files.items) |path| {
        const id = load(gpa, &map, path) orelse return 1;
        const src = map.get(id).source;
        var lx = Lexer.init(gpa, id, src) catch return 1;
        var lexed = lx.tokenize() catch return 1;
        defer lexed.deinit(gpa);
        renderToStderr(gpa, &lexed.diagnostics, &map);
        if (lexed.diagnostics.hasErrors()) return 1;
        const p = Parser.new(gpa, id, src, lexed.tokens);
        const file_ast = p.parseFile();
        renderToStderr(gpa, &p.diagnostics, &map);
        if (p.diagnostics.hasErrors()) return 1;
        user_asts.append(gpa, file_ast) catch return 1;
    }

    const loaded = loadInstalledPacks(gpa, user_asts.items, &map, features);
    var all_asts: std.ArrayList(KotlinFile) = .empty;
    defer all_asts.deinit(gpa);
    all_asts.appendSlice(gpa, loaded.asts) catch return 1;
    all_asts.appendSlice(gpa, user_asts.items) catch return 1;

    const prev_reclaim = runtime.reclaimEnabled();
    if (!runtime.reclaimRequested()) runtime.setReclaim(false);
    defer runtime.setReclaim(prev_reclaim);

    var built = interp_ir.build.buildModuleFiles(gpa, all_asts.items) catch return 1;
    {
        const mg = built.module.borrow();
        defer mg.deinit();
        const rdiags = mg.get().resolve_diags.items;
        if (rdiags.len != 0) {
            for (rdiags) |d| {
                const msg = d.render(gpa, &map) catch return 1;
                defer gpa.free(msg);
                io.printStderr(gpa, "{s}\n", .{msg});
            }
            return 1;
        }
    }

    const fb = Vm.fromBuilt(gpa, &built) catch return 1;
    var vm = fb.vm;
    defer vm.deinit();
    vm.setInstalledBindings(loaded.bindings) catch return 1;

    span.active_map = &map;
    defer span.active_map = null;

    var stdout = io.StdoutSink{};
    // Run on the large interpreter stack: a test exercises arbitrary
    // (possibly deep) program recursion, same as `main`.
    var report = runtime.runOnBigStack(TestRunCtx, test_runner.Report, testRunEntry, .{
        .gpa = gpa,
        .vm = &vm,
        .user_asts = user_asts.items,
        .out = stdout.output(),
        .time_mode = interp_ir.coroutineTimeMode(),
        .reclaim = runtime.reclaimEnabled(),
    });
    defer report.deinit(gpa);

    for (report.results) |r| {
        const tag = switch (r.outcome) {
            .passed => "PASSED",
            .failed => "FAILED",
            .skipped => "SKIPPED",
        };
        io.printStdout(gpa, "{s} {s}\n", .{ r.display, tag });
        if (r.detail) |d| io.printStdout(gpa, "    {s}\n", .{d});
    }
    io.printStdout(gpa, "\n{d} tests, {d} passed, {d} failed, {d} skipped\n", .{
        report.results.len, report.passed, report.failed, report.skipped,
    });
    return if (report.failed > 0) 1 else 0;
}

/// Collect `.kt` files from `path`: a single file (added as-is) or a
/// directory (walked recursively). Results are appended to `out` and sorted
/// for deterministic test ordering.
fn collectKtFiles(
    gpa: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try collectKtDir(gpa, threaded.io(), path, out);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

fn collectKtDir(
    gpa: std.mem.Allocator,
    fio: std.Io,
    path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(fio, path, .{ .iterate = true }) catch {
        // Not a directory: a directly-named source file.
        if (std.mem.endsWith(u8, path, ".kt")) try out.append(gpa, try gpa.dupe(u8, path));
        return;
    };
    defer dir.close(fio);
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        const child = try std.fs.path.join(gpa, &.{ path, entry.name });
        if (entry.kind == .directory) {
            defer gpa.free(child);
            try collectKtDir(gpa, fio, child, out);
        } else if (std.mem.endsWith(u8, entry.name, ".kt")) {
            try out.append(gpa, child);
        } else {
            gpa.free(child);
        }
    }
}

/// Shared tail of the two `run*` paths: build the module, materialize a
/// Vm, register installed bindings, and run `main`. `map` locates
/// lowering diagnostics (file:line) in the parsed sources.
fn runBuilt(
    gpa: std.mem.Allocator,
    all_asts: []const KotlinFile,
    bindings: HostBindings,
    map: *const SourceMap,
    no_main_msg: []const u8,
) u8 {
    // The whole `klio` process runs on one process-lifetime arena
    // (`main.zig`), freed once at exit, so per-cell `ObjRef.deinit` and the
    // `vm.deinit()` value-graph walk are wasted work — the arena reclaims
    // everything. Switch this thread to the reclaim fast path and restore
    // the prior mode after so the REPL's next program is unaffected.
    const prev_reclaim = runtime.reclaimEnabled();
    if (!runtime.reclaimRequested()) runtime.setReclaim(false);
    defer runtime.setReclaim(prev_reclaim);

    const built = interp_ir.build.buildModuleFiles(gpa, all_asts) catch return 1;
    return runBuiltModule(gpa, built, bindings, map, no_main_msg);
}

/// Assemble the program against the baked stdlib image when possible.
/// Returns the process exit code on the fast path, null when the legacy
/// whole-program path must run instead (cache disabled/missing, parse
/// errors, base-name collision fallback, unbakeable base).
fn tryImagePath(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    features: *const RequestedFeatures,
) ?u8 {
    const prev_reclaim = runtime.reclaimEnabled();
    if (!runtime.reclaimRequested()) runtime.setReclaim(false);
    defer runtime.setReclaim(prev_reclaim);
    const prepared = stdlib_image.tryPrepare(gpa, paths, features) orelse return null;
    const msg = if (paths.len == 1) "error: no main function found" else "runtime error: no main function in module";
    return runBuiltModule(gpa, prepared.built, prepared.bindings, prepared.map, msg);
}

/// Tail shared by the legacy and image paths: surface lowering-time
/// resolution diagnostics, materialize a Vm, install bindings, run `main`.
fn runBuiltModule(
    gpa: std.mem.Allocator,
    built_in: interp_ir.build.BuiltModule,
    bindings: HostBindings,
    map: *const SourceMap,
    no_main_msg: []const u8,
) u8 {
    const prev_reclaim = runtime.reclaimEnabled();
    if (!runtime.reclaimRequested()) runtime.setReclaim(false);
    defer runtime.setReclaim(prev_reclaim);

    var built = built_in;
    // Lowering-time resolution diagnostics (ambiguous bare calls) fail
    // the program before it runs.
    {
        const mg = built.module.borrow();
        defer mg.deinit();
        const rdiags = mg.get().resolve_diags.items;
        if (rdiags.len != 0) {
            for (rdiags) |d| {
                const msg = d.render(gpa, map) catch return 1;
                defer gpa.free(msg);
                io.printStderr(gpa, "{s}\n", .{msg});
            }
            return 1;
        }
    }
    const main_id = built.main;
    const fb = Vm.fromBuilt(gpa, &built) catch return 1;
    var vm = fb.vm;
    defer vm.deinit();
    vm.setInstalledBindings(bindings) catch return 1;

    const main = main_id orelse {
        io.printStderr(gpa, "{s}\n", .{no_main_msg});
        return 1;
    };

    var stdout = io.StdoutSink{};
    // Make the source map reachable from inside the VM so a thrown exception's
    // captured frames resolve to file paths + lines (uncaught render and
    // `printStackTrace`). Cleared after the run.
    span.active_map = map;
    defer span.active_map = null;
    runtime.prof.maybeStart();
    const res = runMainBigStack(&vm, main, stdout.output());
    runtime.prof.maybeReport();
    return switch (res) {
        .ok => 0,
        .err => |e| blk: {
            switch (e) {
                .InvalidMain => io.writeStderr("runtime error: main function not found in module\n"),
                .Eval => |m| io.printStderr(gpa, "runtime error: {s}\n", .{m}),
            }
            break :blk 1;
        },
    };
}

/// Run `main` on a large-stack worker thread so deep-but-finite legitimate
/// recursion runs to completion instead of overflowing the ~8 MiB main stack
/// (the eval-depth cap remains the backstop against unbounded recursion). The
/// coroutine time mode is thread-local, so it is re-established on the worker.
const MainRunCtx = struct {
    vm: *Vm,
    main: interp_ir.FuncId,
    out: interp_ir.Output,
    time_mode: interp_ir.TimeMode,
    reclaim: bool,
};

fn runMainBigStack(vm: *Vm, main: interp_ir.FuncId, out: interp_ir.Output) interp_ir.VmResult {
    const ctx = MainRunCtx{
        .vm = vm,
        .main = main,
        .out = out,
        .time_mode = interp_ir.coroutineTimeMode(),
        .reclaim = runtime.reclaimEnabled(),
    };
    return runtime.runOnBigStack(MainRunCtx, interp_ir.VmResult, runMainEntry, ctx);
}

fn runMainEntry(ctx: MainRunCtx) interp_ir.VmResult {
    interp_ir.setCoroutineTimeMode(ctx.time_mode);
    runtime.setReclaim(ctx.reclaim);
    return ctx.vm.run(ctx.main, ctx.out) catch return .{ .err = .{ .Eval = "out of memory" } };
}

/// `klio repl`: minimal interactive read-eval loop.
pub fn runRepl(gpa: std.mem.Allocator) u8 {
    io.writeStdout("klio repl (experimental). Ctrl-D to exit.\n");
    var buf: [4096]u8 = undefined;
    while (true) {
        io.writeStdout("klio> ");
        const line = io.readLine(&buf) orelse break;
        io.printStdout(gpa, "{s}\n", .{line});
    }
    return 0;
}

fn renderToStderr(
    gpa: std.mem.Allocator,
    sink: *const DiagnosticSink,
    map: *const SourceMap,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    render.plain.render(gpa, sink.diags(), map, &buf) catch return;
    io.writeStderr(buf.items);
}

test "diag format variants exist" {
    try std.testing.expectEqual(DiagFormat.Plain, DiagFormat.Plain);
    try std.testing.expect(DiagFormat.Json != DiagFormat.Sarif);
}
