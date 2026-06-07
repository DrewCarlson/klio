//! Subcommand definitions for the `klio` CLI: lex, parse, run, check, repl.
//!
//! Mirrors `crates/klio-cli/src/commands.rs`. Each `run*` returns a
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

const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const io = @import("io.zig");

const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;
const loadInstalledPacks = pack_cache.loadInstalledPacks;

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

    var r = resolver.resolveModule(gpa, combined.items) catch return 2;
    defer r.deinit();
    for (r.diagnostics.diags()) |d| {
        if (user_file_ids.contains(d.primary.span.file.int())) {
            all.emit(gpa, d) catch return 2;
        }
    }
    var tc = typeck.typecheckModule(gpa, combined.items, &r) catch return 2;
    defer tc.deinit(gpa);
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

    return runBuilt(gpa, all_asts.items, loaded.bindings, "runtime error: no main function in module");
}

/// `klio run` over a single source file through `interp_ir`'s Vm.
pub fn runFileIrVm(
    gpa: std.mem.Allocator,
    path: []const u8,
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
    // Unified build path: a script and a pack-using program both flow
    // through `build_module_files`.
    var all_asts: std.ArrayList(KotlinFile) = .empty;
    defer all_asts.deinit(gpa);
    all_asts.appendSlice(gpa, loaded.asts) catch return 1;
    all_asts.appendSlice(gpa, user_asts.items) catch return 1;

    return runBuilt(gpa, all_asts.items, loaded.bindings, "error: no main function found");
}

/// Shared tail of the two `run*` paths: build the module, materialize a
/// Vm, register installed bindings, and run `main`.
fn runBuilt(
    gpa: std.mem.Allocator,
    all_asts: []const KotlinFile,
    bindings: HostBindings,
    no_main_msg: []const u8,
) u8 {
    var built = interp_ir.build.buildModuleFiles(gpa, all_asts) catch return 1;
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
    const res = vm.run(main, stdout.output()) catch return 1;
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
