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
const span_mod = @import("span");

const ir = @import("ir");
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
const compose_ui = @import("compose_ui");

/// Output format for `klio check`. Mirrors `commands::DiagFormat`.
pub const DiagFormat = enum {
    Plain,
    Json,
    Sarif,
};

/// Read a source file into the map, returning its `FileId`. On failure
/// the error is printed to stderr and `null` is returned.
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
    runtime.prof.opProfMaybeStart();
    interp_ir.resetReceiverThreadLocals();
    interp_ir.resetRunGlobalCaches();
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
    interp_ir.resetRunGlobalCaches();
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

/// `klio dump-ir <file> [--func NAME] [--all]` — lower the file (linked against
/// the stdlib + any gated packs, exactly as `run`/`test` do) and print its IR
/// without executing it. The Direct/Dynamic call tally is the oracle for the
/// static-binding work.
pub fn runDumpIr(
    gpa: std.mem.Allocator,
    path: []const u8,
    opts: ir.disasm.Options,
    features: *const RequestedFeatures,
) u8 {
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
    var all_asts: std.ArrayList(KotlinFile) = .empty;
    defer all_asts.deinit(gpa);
    all_asts.appendSlice(gpa, loaded.asts) catch return 1;
    all_asts.appendSlice(gpa, user_asts.items) catch return 1;

    var built = interp_ir.build.buildModuleFiles(gpa, all_asts.items) catch {
        io.printStderr(gpa, "error: lowering failed\n", .{});
        return 1;
    };
    defer built.deinit();

    const mg = built.module.borrow();
    defer mg.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    ir.disasm.dumpModule(&aw.writer, mg.get(), opts) catch return 1;
    const text = aw.toOwnedSlice() catch return 1;
    defer gpa.free(text);
    io.printStdout(gpa, "{s}", .{text});
    return 0;
}

const TestRunCtx = struct {
    gpa: std.mem.Allocator,
    vm: *Vm,
    user_asts: []const KotlinFile,
    out: runtime.Output,
    time_mode: interp_ir.TimeMode,
    reclaim: bool,
    only_fids: []const u32,
    filter: ?[]const u8,
};

/// Big-stack worker entry: re-establish the thread-local coroutine time mode
/// and reclaim flag (a fresh OS thread), then discover and run the tests.
fn testRunEntry(ctx: TestRunCtx) test_runner.Report {
    interp_ir.setCoroutineTimeMode(ctx.time_mode);
    runtime.setReclaim(ctx.reclaim);
    return test_runner.runTests(ctx.gpa, ctx.vm, ctx.user_asts, ctx.out, ctx.only_fids, ctx.filter) catch |err| {
        io.printStderr(ctx.gpa, "error: test runner: {s}\n", .{@errorName(err)});
        return test_runner.Report{ .results = &.{}, .passed = 0, .failed = 1, .skipped = 0 };
    };
}

/// `klio test` — discover and run `kotlin.test` `@Test` functions in the
/// given files/directories. Returns 1 if any test fails (or the module
/// fails to build), 0 otherwise.
/// `--isolate`: an opt-in debugging driver that runs each discovered `@Test` in
/// its OWN sub-process with a per-test wall-clock timeout, so a test that hangs
/// or crashes is pinpointed (the parent kills the child and records it) rather
/// than taking down the whole suite. `base_args` is the original `test`
/// argument vector minus `--isolate`/`--jobs`; the driver re-invokes
/// `klio test <base_args> --list` to enumerate, then an exact
/// `... --filter==<name>` per test with the timeout enforced by the parent
/// (`std.process.run`).
pub fn runTestsIsolated(
    gpa: std.mem.Allocator,
    self: []const u8,
    base_args: []const []const u8,
    timeout_s: u64,
) u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const rio = threaded.io();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    runtime.procEnvPutAllInto(gpa, &env);

    // 1. Enumerate the test names (compile once; no execution).
    var list_argv: std.ArrayList([]const u8) = .empty;
    defer list_argv.deinit(gpa);
    list_argv.append(gpa, self) catch return 2;
    list_argv.append(gpa, "test") catch return 2;
    list_argv.appendSlice(gpa, base_args) catch return 2;
    list_argv.append(gpa, "--list") catch return 2;
    const listed = std.process.run(gpa, rio, .{ .argv = list_argv.items, .environ_map = &env }) catch {
        io.writeStderr("error: --isolate: failed to enumerate tests\n");
        return 2;
    };
    defer gpa.free(listed.stdout);
    defer gpa.free(listed.stderr);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, listed.stdout, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len != 0) names.append(gpa, t) catch return 2;
    }
    if (names.items.len == 0) {
        io.printStdout(gpa, "no tests found\n", .{});
        return 0;
    }

    const timeout_ms: i64 = @intCast(timeout_s * 1000);
    var passed: usize = 0;
    var failed: usize = 0;
    var timed_out: usize = 0;
    for (names.items) |name| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        const filt = std.fmt.allocPrint(gpa, "--filter=={s}", .{name}) catch return 2;
        defer gpa.free(filt);
        argv.append(gpa, self) catch return 2;
        argv.append(gpa, "test") catch return 2;
        argv.appendSlice(gpa, base_args) catch return 2;
        argv.append(gpa, filt) catch return 2;
        const res = std.process.run(gpa, rio, .{
            .argv = argv.items,
            .environ_map = &env,
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
        }) catch |e| {
            if (e == error.Timeout) {
                io.printStdout(gpa, "{s} TIMEOUT ({d}s)\n", .{ name, timeout_s });
                timed_out += 1;
            } else {
                io.printStdout(gpa, "{s} ERROR (spawn failed)\n", .{name});
                failed += 1;
            }
            continue;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        // A clean exit-0 → the isolated test passed; exit-1 → it failed; any
        // abnormal termination (signal/crash) → CRASH.
        switch (res.term) {
            .exited => |c| if (c == 0) {
                io.printStdout(gpa, "{s} PASSED\n", .{name});
                passed += 1;
            } else {
                io.printStdout(gpa, "{s} FAILED\n", .{name});
                failed += 1;
            },
            else => {
                io.printStdout(gpa, "{s} CRASH\n", .{name});
                timed_out += 1;
            },
        }
    }
    io.printStdout(gpa, "\n{d} tests, {d} passed, {d} failed, {d} timeout/crash\n", .{
        names.items.len, passed, failed, timed_out,
    });
    return if (failed + timed_out > 0) 1 else 0;
}

pub fn runTestFiles(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    features: *const RequestedFeatures,
    only_files: []const []const u8,
    filter: ?[]const u8,
    format: TestFormat,
    list_only: bool,
) u8 {
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    runtime.prof.opProfMaybeStart();
    interp_ir.resetReceiverThreadLocals();
    interp_ir.resetRunGlobalCaches();

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

    // Fast path: assemble against the baked stdlib image. Read each selected
    // FileId from the reparsed user AST itself; deriving it from map length and
    // argv position made a multi-`--only-file` batch silently select the wrong
    // subset whenever preparation inserted additional source-map entries.
    // Falls back to the
    // legacy whole-module build when the cache misses or the program
    // cannot extend the base (e.g. files declaring expect/actual).
    {
        const prev_reclaim = runtime.reclaimEnabled();
        if (!runtime.reclaimRequested()) runtime.setReclaim(false);
        defer runtime.setReclaim(prev_reclaim);
        if (stdlib_image.tryPrepare(gpa, files.items, features)) |prep| {
            var image_fids: std.ArrayList(u32) = .empty;
            defer image_fids.deinit(gpa);
            for (files.items, 0..) |path, i| {
                for (only_files) |of| {
                    if (std.mem.eql(u8, path, of) or std.mem.endsWith(u8, path, of)) {
                        if (i >= prep.user_asts.len) return 1;
                        const fid = prep.user_asts[i].span.file.int();
                        if (runtime.envOnce("KLIO_TEST_FILE_TRACE") != null) {
                            io.printStderr(gpa, "[test-file] {s} -> {d}\n", .{ path, fid });
                        }
                        image_fids.append(gpa, fid) catch return 1;
                        break;
                    }
                }
            }
            return runTestsOnBuilt(gpa, prep.built, prep.bindings, prep.map, prep.user_asts, image_fids.items, filter, format, list_only);
        }
    }

    var map = SourceMap.init(gpa);
    defer map.deinit();

    // `--only-file`: FileIds whose `@Test` methods should actually run (the
    // rest are compiled as context only). Empty = run every file's tests.
    var only_fids: std.ArrayList(u32) = .empty;
    defer only_fids.deinit(gpa);

    var user_asts: std.ArrayList(KotlinFile) = .empty;
    defer user_asts.deinit(gpa);
    for (files.items) |path| {
        const id = load(gpa, &map, path) orelse return 1;
        for (only_files) |of| {
            if (std.mem.eql(u8, path, of) or std.mem.endsWith(u8, path, of)) {
                only_fids.append(gpa, id.int()) catch return 1;
                break;
            }
        }
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

    if (computeEagerCalls(gpa, all_asts.items, &.{})) |ec| ir.pending_eager_calls = ec;
    // Reachable during LOWERING, not just during the run: lowering-time
    // diagnostics resolve a span to a file and line through this map, and
    // `runTestsOnBuilt` re-installs it for the run itself.
    span.active_map = &map;
    const built = interp_ir.build.buildModuleFiles(gpa, all_asts.items) catch return 1;
    return runTestsOnBuilt(gpa, built, loaded.bindings, &map, user_asts.items, only_fids.items, filter, format, list_only);
}

/// Tail shared by the legacy and image test paths: surface lowering-time
/// resolution diagnostics, materialize a Vm, install bindings, then
/// discover and run the `@Test` functions in `user_asts`.
/// Test-runner output format. `plain` is the human-facing per-test list +
/// summary; `json` is a machine-readable object (counts + per-test status +
/// failure reason) for CI ratchets.
pub const TestFormat = enum { plain, json };

/// Emit a JSON string literal with the minimal escapes JSON requires.
fn writeJsonString(gpa: std.mem.Allocator, s: []const u8) void {
    io.printStdout(gpa, "\"", .{});
    for (s) |c| switch (c) {
        '"' => io.printStdout(gpa, "\\\"", .{}),
        '\\' => io.printStdout(gpa, "\\\\", .{}),
        '\n' => io.printStdout(gpa, "\\n", .{}),
        '\r' => io.printStdout(gpa, "\\r", .{}),
        '\t' => io.printStdout(gpa, "\\t", .{}),
        else => if (c < 0x20) io.printStdout(gpa, "\\u{x:0>4}", .{c}) else io.printStdout(gpa, "{c}", .{c}),
    };
    io.printStdout(gpa, "\"", .{});
}

fn runTestsOnBuilt(
    gpa: std.mem.Allocator,
    built_in: interp_ir.build.BuiltModule,
    bindings: HostBindings,
    map: *const SourceMap,
    user_asts: []const KotlinFile,
    only_fids: []const u32,
    filter: ?[]const u8,
    format: TestFormat,
    list_only: bool,
) u8 {
    const prev_reclaim = runtime.reclaimEnabled();
    if (!runtime.reclaimRequested()) runtime.setReclaim(false);
    defer runtime.setReclaim(prev_reclaim);

    var built = built_in;
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

    const fb = Vm.fromBuilt(gpa, &built) catch return 1;
    var vm = fb.vm;
    defer vm.deinit();
    vm.setInstalledBindings(bindings) catch return 1;

    span.active_map = map;
    defer span.active_map = null;

    // `--list`: discover the `@Test` names and print them, one per line, without
    // running any (the `--isolate` driver spawns a sub-process per name).
    if (list_only) {
        const names = test_runner.listTests(gpa, &vm, user_asts, only_fids, filter) catch return 1;
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        for (names) |n| io.printStdout(gpa, "{s}\n", .{n});
        return 0;
    }

    var stdout = io.StdoutSink{};
    // Run on the large interpreter stack: a test exercises arbitrary
    // (possibly deep) program recursion, same as `main`.
    var report = runtime.runOnBigStack(TestRunCtx, test_runner.Report, testRunEntry, .{
        .gpa = gpa,
        .vm = &vm,
        .user_asts = user_asts,
        .out = stdout.output(),
        .time_mode = interp_ir.coroutineTimeMode(),
        .reclaim = runtime.reclaimEnabled(),
        .only_fids = only_fids,
        .filter = filter,
    });
    defer report.deinit(gpa);

    if (format == .json) {
        io.printStdout(gpa, "{{\"total\":{d},\"passed\":{d},\"failed\":{d},\"skipped\":{d},\"tests\":[", .{
            report.results.len, report.passed, report.failed, report.skipped,
        });
        for (report.results, 0..) |r, idx| {
            if (idx != 0) io.printStdout(gpa, ",", .{});
            io.printStdout(gpa, "{{\"name\":", .{});
            writeJsonString(gpa, r.display);
            io.printStdout(gpa, ",\"outcome\":\"{s}\"", .{@tagName(r.outcome)});
            if (r.detail) |d| {
                io.printStdout(gpa, ",\"detail\":", .{});
                writeJsonString(gpa, d);
            }
            io.printStdout(gpa, "}}", .{});
        }
        io.printStdout(gpa, "]}}\n", .{});
        return if (report.failed > 0) 1 else 0;
    }

    for (report.results) |r| {
        const tag = switch (r.outcome) {
            .passed => "PASSED",
            .failed => "FAILED",
            .skipped => "SKIPPED",
        };
        io.printStdout(gpa, "{s} {s}\n", .{ r.display, tag });
        if (r.detail) |d| io.printStdout(gpa, "    {s}\n", .{d});
    }
    if (report.results.len == 0) {
        if (report.failed != 0) {
            io.printStdout(gpa, "test runner failed before producing a result\n", .{});
            return 1;
        }
        io.printStdout(gpa, "no tests found\n", .{});
        return 0;
    }
    io.printStdout(gpa, "\n{d} tests, {d} passed, {d} failed, {d} skipped\n", .{
        report.results.len, report.passed, report.failed, report.skipped,
    });
    if (runtime.envOnce("KLIO_PUMP_DIAG") != null) interp_ir.coroutines_diag.dumpSleepCounts();
    ir.eval.callStatsDump();
    ir.eval.dispatchStatsDump();
    if (runtime.envOnce("KLIO_DISPATCH_STATS") != null) {
        ir.lower.expr.lowerSitesDump();
        ir.lower.expr.lowerNoRecvDump();
        ir.lower.expr.lowerDeclineDump();
        ir.lower.expr.lowerPromoDump();
        ir.lower.expr.lowerLocalInitDump();
        ir.lower.expr.lowerNoClassDump();
    }
    ir.eval.probeStatsDump();
    ir.eval.opProfDump();
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

/// The eager pipeline, now the ONLY pipeline: run resolver + typeck over
/// the program the way `klio check` does and convert the recorded overload
/// picks into the span-pair map lowering composes with its own declaration
/// identities. Fallback-safe by design — any failure returns null and
/// lowering proceeds on AST evidence alone (`KLIO_EAGER_AUDIT=1` logs the
/// skip), so a program that defeats typeck still runs.
///
/// There is no opt-out. It was behind `KLIO_EAGER` while the channels were
/// unsound; validation is now identical with and without the evidence
/// (`commontest-sweep.py --eager both` reported ON/OFF identical across
/// all 117 stdlib files, and every compose suite is green under it), so the
/// gate and the second code path are gone.
pub fn computeEagerCalls(
    gpa: std.mem.Allocator,
    combined: []const KotlinFile,
    native_fqns: []const []const u8,
) ?std.AutoHashMap(span_mod.Span, span_mod.Span) {
    const audit = runtime.envOnce("KLIO_EAGER_AUDIT") != null;
    const r = resolver.resolveModuleWithNatives(gpa, combined, native_fqns) catch {
        if (audit) std.debug.print("[EAGER] resolver failed; staying lazy\n", .{});
        return null;
    };
    const tc = typeck.typecheckModule(gpa, combined, &r) catch {
        if (audit) std.debug.print("[EAGER] typeck failed; staying lazy\n", .{});
        return null;
    };
    // Only a record whose decl_span IS a function declaration's name-span
    // in the typechecked sources composes soundly: a builtin-header FnSig
    // carries a synthetic span that can collide with real coordinates.
    var declared = std.AutoHashMap(span_mod.Span, void).init(gpa);
    defer declared.deinit();
    for (combined) |*kf| {
        for (kf.decls) |*d| {
            switch (d.*) {
                .Function => |*f| declared.put(f.name.span, {}) catch {},
                .Class => |*c| {
                    for (c.members) |*mm| {
                        if (mm.* == .Function) declared.put(mm.Function.name.span, {}) catch {};
                    }
                },
                else => {},
            }
        }
    }
    var out = std.AutoHashMap(span_mod.Span, span_mod.Span).init(gpa);
    var it = tc.resolved_calls.iterator();
    var n: usize = 0;
    var seen_total: usize = 0;
    var no_decl_span: usize = 0;
    var not_declared: usize = 0;
    while (it.next()) |e| {
        seen_total += 1;
        const decl = e.value_ptr.decl_span orelse {
            no_decl_span += 1;
            continue;
        };
        if (!declared.contains(decl)) {
            not_declared += 1;
            continue;
        }
        out.put(e.key_ptr.*, decl) catch continue;
        n += 1;
        if (runtime.envOnce("KLIO_EAGER_HITS") != null) {
            std.debug.print("[EAGER-REC] call f{d}:{d}-{d} -> decl f{d}:{d}-{d}\n", .{ e.key_ptr.file.int(), e.key_ptr.start, e.key_ptr.end, decl.file.int(), decl.start, decl.end });
        }
    }
    if (audit) {
        const g = typeck.check.expr_calls.eager_gate_counts;
        const cs = typeck.check.expr_calls.call_shape_counts;
        std.debug.print("[EAGER-SHAPE] calls={d} member={d} member_with_class={d} member_ext_cands={d}\n", .{ cs[0], cs[1], cs[2], cs[3] });
        std.debug.print("[EAGER-GATES] entered={d} vararg={d} type_param={d} ext_name={d} member_shadow={d} pkg_visibility={d} recorded={d}\n", .{ g[0], g[1], g[2], g[3], g[4], g[5], g[6] });
    }
    if (audit) std.debug.print("[EAGER] {d} call resolutions recorded (typeck resolved {d}; {d} carried no decl span, {d} named a decl outside the checked sources)\n", .{ n, seen_total, no_decl_span, not_declared });
    // The companion evidence channel: per-expression type heads. Only
    // decisive heads enter (scalars, String, named classes, nullable
    // wrappers of those) — a Function/TypeParam/Unresolved answer would
    // override AST evidence with mush.
    var tout = std.AutoHashMap(span_mod.Span, ir.EagerTypeHead).init(gpa);
    var tit = tc.types.iterator();
    var tn: usize = 0;
    while (tit.next()) |e| {
        // A type recorded inside a generic body is true only for the
        // instantiation typeck happened to check last. Handing it to lowering
        // changes which overload wins — `plusElement`'s `return plus(element)`
        // matches `plus(element: T)` against `T`, but against
        // `List<String>` the concatenating `plus(Iterable<T>)` also applies.
        if (tc.types_instantiation_dependent.contains(e.key_ptr.*)) continue;
        const head = eagerHeadOf(e.value_ptr, false) orelse continue;
        tout.put(e.key_ptr.*, head) catch continue;
        tn += 1;
    }
    if (audit) std.debug.print("[EAGER] {d} type heads recorded ({d} excluded as instantiation-dependent)\n", .{ tn, tc.types_instantiation_dependent.count() });
    ir.pending_eager_types = tout;
    var rout = std.AutoHashMap(span_mod.Span, []const u8).init(gpa);
    var rit = tc.lambda_recv_heads.iterator();
    while (rit.next()) |e| rout.put(e.key_ptr.*, e.value_ptr.*) catch {};
    if (audit) std.debug.print("[EAGER] {d} lambda receiver heads recorded\n", .{rout.count()});
    ir.pending_eager_recv_heads = rout;
    var pout = std.AutoHashMap(span_mod.Span, ir.EagerParamShape).init(gpa);
    var pit = tc.lambda_param_shapes.iterator();
    while (pit.next()) |e| pout.put(e.key_ptr.*, .{ .has_receiver = e.value_ptr.has_receiver, .arity = e.value_ptr.arity }) catch {};
    if (audit) std.debug.print("[EAGER] {d} param shapes recorded\n", .{pout.count()});
    ir.pending_eager_param_shapes = pout;
    return out;
}

fn eagerHeadOf(t: *const typeck.check.Type, nullable: bool) ?ir.EagerTypeHead {
    // Primitive scalar heads stay OUT of the channel: the applicability
    // engine treats primitive evidence as exact, but a literal's type
    // coerces to the parameter's primitive (an Int literal fills a
    // `vararg Byte` slot), and the head cannot carry literalness.
    return switch (t.*) {
        .String => .{ .name = "String", .nullable = nullable },
        .Nullable => |inner| eagerHeadOf(inner, true),
        .Generic => |g| .{ .name = g.name, .nullable = nullable },
        else => null,
    };
}

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

    if (computeEagerCalls(gpa, all_asts, &.{})) |ec| ir.pending_eager_calls = ec;
    // See the note in the test path: the map is installed before lowering so
    // lowering-time diagnostics can name a file and line.
    span.active_map = map;
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
    return runBuiltModuleArgs(gpa, built_in, bindings, map, no_main_msg, &.{});
}

/// `runBuiltModule` with the program argv `main(args: Array<String>)`
/// receives (a bundle's argv[1..]; empty under `klio run`).
pub fn runBuiltModuleArgs(
    gpa: std.mem.Allocator,
    built_in: interp_ir.build.BuiltModule,
    bindings: HostBindings,
    map: *const SourceMap,
    no_main_msg: []const u8,
    program_args: []const []const u8,
) u8 {
    const prev_reclaim = runtime.reclaimEnabled();
    if (!runtime.reclaimRequested()) runtime.setReclaim(false);
    // A hosted UI run stays resident after `main` returns: the platform frame
    // source re-enters the VM each vsync, so its reclaim mode, source map, and
    // VM state must survive this scope instead of being torn down. Every
    // non-hosted run (all of desktop/headless) restores/deinits as before.
    defer if (!compose_ui.hostedActive()) runtime.setReclaim(prev_reclaim);

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
    defer if (!compose_ui.hostedActive()) vm.deinit();
    vm.program_args = program_args;
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
    defer if (!compose_ui.hostedActive()) {
        span.active_map = null;
    };
    runtime.prof.maybeStart();
    const res = runMainBigStack(&vm, main, stdout.output());
    runtime.prof.maybeReport();
    ir.eval.callStatsDump();
    ir.eval.dispatchStatsDump();
    if (runtime.envOnce("KLIO_DECL_AUDIT") != null) declAudit(gpa, &built);
    // The dispatch census is reported for `run` as well as for `test`. The two
    // answer different questions: the stdlib's own tests are generic
    // throughout, so a change that reads a CONCRETE element type measures as
    // zero there and is not worthless — ordinary application code is where it
    // shows.
    if (runtime.envOnce("KLIO_DISPATCH_STATS") != null) {
        ir.lower.expr.lowerSitesDump();
        ir.lower.expr.lowerNoRecvDump();
        ir.lower.expr.lowerDeclineDump();
        ir.lower.expr.lowerPromoDump();
        ir.lower.expr.lowerLocalInitDump();
        ir.lower.expr.lowerNoClassDump();
    }
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


/// `KLIO_DECL_AUDIT=1` — the completeness audit for the no-holes symbol table.
///
/// PROGRAM-SCOPED: the IR is lazy, so a declaration only enters the module
/// when the program under audit reaches its package. Run it on a program that
/// exercises the surface being measured — the same audit reports 9 holes for
/// a `println`-only program and 6 for one that also imports `kotlin.system`.
/// The number is a lower bound on what is declared, never an upper bound on
/// what is missing.
///
/// every FQN the intrinsic registry can serve, paired with whether the module
/// carries a DECLARATION for it. A callable the runtime can dispatch but the
/// resolver cannot see is a hole: resolution has to fall back to a name probe
/// there, which is exactly what the unified table exists to remove. Prints the
/// tally and the first missing entries per package.
fn declAudit(gpa: std.mem.Allocator, built: *const interp_ir.build.BuiltModule) void {
    const mg = built.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    var total: usize = 0;
    var missing: usize = 0;
    var member_missing: usize = 0;
    var toplevel_missing: usize = 0;
    var unaligned: usize = 0;
    var unaligned_samples: std.ArrayList([]const u8) = .empty;
    defer unaligned_samples.deinit(gpa);
    var by_pkg = std.StringHashMap(usize).init(gpa);
    defer by_pkg.deinit();
    var samples: std.ArrayList([]const u8) = .empty;
    defer samples.deinit(gpa);
    var it = stdlib.implementations.allFqns();
    while (it.next()) |fqn| {
        total += 1;
        if (module.funcIdByFqn(fqn) != null) continue;
        // A class (its constructor) and a top-level property are declared
        // entities too; the registry serves both under an FQN key.
        if (module.classIdByFqn(fqn) != null) continue;
        {
            const simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
            if (module.registry.top_level_prop_pkgs.get(simple) != null) continue;
        }
        missing += 1;
        const pkg = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[0..d] else "";
        // A receiver-qualified form (`kotlin.Float.plus`) is a MEMBER of a
        // builtin type, which has no Kotlin source declaration by design.
        // The holes that matter for the scope walk are package-level
        // callables: the owner segment starts lowercase.
        const owner_simple = if (std.mem.lastIndexOfScalar(u8, pkg, '.')) |d2| pkg[d2 + 1 ..] else pkg;
        if (owner_simple.len != 0 and std.ascii.isUpper(owner_simple[0])) {
            member_missing += 1;
            continue;
        }
        // A registry key that names the same callable under a different
        // package (`kotlin.naturalOrder` for `kotlin.comparisons.naturalOrder`)
        // is not a missing declaration — it is an UNALIGNED key, which the
        // scope walk must reconcile separately.
        {
            const simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
            var aligned_elsewhere = module.funcsBySimpleName(simple).len != 0;
            // A CLASS the module declares under another package
            // (`kotlin.StringBuilder` for `kotlin.text.StringBuilder`) is the
            // same shape of mismatch as a function's.
            if (!aligned_elsewhere and module.uniqueClassIdBySimpleName(simple) != null) aligned_elsewhere = true;
            // An extension property's getter carries the
            // `__ext_get_<Head>_<name>` naming contract, so its declaration
            // never appears under the registry's own key.
            if (!aligned_elsewhere) {
                var it2 = module.registry.ext_prop_type_heads.iterator();
                while (it2.next()) |e2| {
                    if (std.mem.eql(u8, e2.key_ptr.b, simple)) {
                        aligned_elsewhere = true;
                        break;
                    }
                }
            }
            if (aligned_elsewhere) {
                unaligned += 1;
                if (unaligned_samples.items.len < 20) unaligned_samples.append(gpa, fqn) catch {};
                continue;
            }
        }
        toplevel_missing += 1;
        const gop = by_pkg.getOrPut(pkg) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (samples.items.len < 40) samples.append(gpa, fqn) catch {};
    }
    io.printStdout(gpa, "[decl-audit] intrinsics={d} declared={d} missing={d} (builtin-type members {d}, unaligned keys {d}, package-level holes {d})\n", .{ total, total - missing, missing, member_missing, unaligned, toplevel_missing });
    var pit = by_pkg.iterator();
    while (pit.next()) |e| {
        io.printStdout(gpa, "[decl-audit] {d:>5}  {s}\n", .{ e.value_ptr.*, e.key_ptr.* });
    }
    for (samples.items) |fq| io.printStdout(gpa, "[decl-audit] hole: {s}\n", .{fq});
    for (unaligned_samples.items) |fq| io.printStdout(gpa, "[decl-audit] unaligned: {s}\n", .{fq});
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
    // Run the interpreter on the process main thread on every platform, with a
    // large stack via an in-thread stack switch (no worker-thread hop). A program
    // that opens a Compose UI must drive the platform windowing + single-threaded
    // GPU context from the main thread (AppKit/Metal on macOS, UIKit/Metal on
    // iOS); keeping the default uniform means the UI path is the normal path.
    return runtime.runOnBigStackMainThread(MainRunCtx, interp_ir.VmResult, runMainEntry, ctx);
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
