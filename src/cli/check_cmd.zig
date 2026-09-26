//! `klio check`, `klio lex` and `klio parse`: the front end's diagnostics
//! and outputs for a file, rendered as the user asked.

const std = @import("std");
const span = @import("span");
const SourceMap = span.SourceMap;
const FileId = span.FileId;
const diagnostics = @import("diagnostics");
const DiagnosticSink = diagnostics.DiagnosticSink;
const render = diagnostics.render;
const lexer = @import("lexer");
const Lexer = lexer.Lexer;
const parser = @import("parser");
const Parser = parser.Parser;
const ast = @import("ast");
const KotlinFile = ast.KotlinFile;
const resolver = @import("resolver");
const typeck = @import("typeck");

const io = @import("io.zig");
const pack_cache = @import("pack_cache.zig");
const sema_cmd = @import("sema_cmd.zig");
const sema_run = @import("sema_run.zig");
const sema_diagnostics = @import("sema_diagnostics.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;
const loadInstalledPacks = pack_cache.loadInstalledPacks;

pub const DiagFormat = enum {
    Plain,
    Json,
    Sarif,
};

/// What `klio check` analyzes with: the resolver and type checker, or sema
/// as `klio run` runs it.
pub const Engine = enum {
    old,
    sema,

    pub fn fromStr(s: []const u8) ?Engine {
        return std.meta.stringToEnum(Engine, s);
    }
};

pub fn load(gpa: std.mem.Allocator, map: *SourceMap, path: []const u8) ?FileId {
    const src = io.readFile(gpa, path) catch |e| {
        io.printStderr(gpa, "error: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return null;
    };
    defer gpa.free(src);
    return map.add(path, src) catch return null;
}

/// `klio check`: type-check files, emit diagnostics. Exit 1 on error, 2 on IO.
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
        const file_ast = parseInto(gpa, &map, id, &all) catch return 2;
        user_asts.append(gpa, file_ast) catch return 2;
    }

    // Only diagnostics anchored in a user file surface; pack shims are trusted.
    const loaded = loadInstalledPacks(gpa, user_asts.items, &map, features);
    var combined: std.ArrayList(KotlinFile) = .empty;
    defer combined.deinit(gpa);
    combined.appendSlice(gpa, loaded.asts) catch return 2;
    combined.appendSlice(gpa, user_asts.items) catch return 2;

    // `gpa` is the process-lifetime arena: nothing here frees.
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

    return report(gpa, all.diags(), &map, format);
}

/// Lexes and parses the file `id` of `map`, its diagnostics into `sink`.
fn parseInto(gpa: std.mem.Allocator, map: *SourceMap, id: FileId, sink: *DiagnosticSink) !KotlinFile {
    const src = map.get(id).source;
    var lx = try Lexer.init(gpa, id, src);
    var lexed = try lx.tokenize();
    defer lexed.deinit(gpa);
    for (lexed.diagnostics.diags()) |d| try sink.emit(gpa, d);
    const p = Parser.new(gpa, id, src, lexed.tokens, lexed.strings);
    const file_ast = p.parseFile();
    for (p.diagnostics.diags()) |d| try sink.emit(gpa, d);
    return file_ast;
}

/// Prints `diags` in `format` and answers the exit code: 1 when one is an
/// error.
fn report(gpa: std.mem.Allocator, diags: []const diagnostics.Diagnostic, map: *const SourceMap, format: DiagFormat) u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const rr = switch (format) {
        .Plain => render.plain.render(gpa, diags, map, &buf),
        .Json => render.json.render(gpa, diags, map, &buf),
        .Sarif => render.sarif.render(gpa, diags, map, &buf),
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

/// `klio check --engine=sema`: the files loaded and analyzed as `klio run`
/// analyzes them, with the packs they use, and their lex, parse and sema
/// diagnostics in the order of the source. Exit 1 on an error, 2 when the
/// check itself failed.
pub fn runCheckSema(gpa: std.mem.Allocator, files: []const []const u8, format: DiagFormat, feature_specs: []const []const u8) u8 {
    if (files.len == 0) {
        io.printStderr(gpa, "usage: klio check <file.kt> [--format=plain|json|sarif]\n", .{});
        return 2;
    }
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    const arena = mem.arena();
    var load_report: sema_cmd.LoadReport = .{};
    const src = sema_cmd.loadSources(arena, mem.map, files, .{ .feature_specs = feature_specs, .report = &load_report }) catch |e| switch (e) {
        error.ProgramSyntax => return syntaxOnly(gpa, files, format),
        else => return sema_run.loadFailed(gpa, e, &load_report),
    };
    const s = sema_run.analyzeRun(gpa, arena, mem.map, src, sema_cmd.hostBinding(gpa)) catch |e| {
        io.printStderr(gpa, "error: the sema pipeline failed: {s}\n", .{@errorName(e)});
        return 2;
    };
    const found = sema_diagnostics.collect(arena, s, .{}) catch return 2;
    var all: std.ArrayList(diagnostics.Diagnostic) = .empty;
    all.appendSlice(arena, load_report.syntax_diags.items) catch return 2;
    all.appendSlice(arena, found.list) catch return 2;
    sema_diagnostics.sortByPlace(all.items);
    return report(gpa, all.items, mem.map, format);
}

/// The lex and parse diagnostics of files one of which does not parse.
fn syntaxOnly(gpa: std.mem.Allocator, files: []const []const u8, format: DiagFormat) u8 {
    var map = SourceMap.init(gpa);
    defer map.deinit();
    var all = DiagnosticSink.init();
    defer all.deinit(gpa);
    for (files) |path| {
        const id = load(gpa, &map, path) orelse return 2;
        _ = parseInto(gpa, &map, id, &all) catch return 2;
    }
    return report(gpa, all.diags(), &map, format);
}

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
    const p = Parser.new(gpa, id, src, lexed.tokens, lexed.strings);
    const file_ast = p.parseFile();
    renderToStderr(gpa, &p.diagnostics, &map);
    io.printStdout(gpa, "{any}\n", .{file_ast});
    return if (p.diagnostics.hasErrors()) 1 else 0;
}

pub fn renderToStderr(
    gpa: std.mem.Allocator,
    sink: *const DiagnosticSink,
    map: *const SourceMap,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    render.plain.render(gpa, sink.diags(), map, &buf) catch return;
    io.writeStderr(buf.items);
}

test "an engine is named as --engine spells it" {
    try std.testing.expectEqual(Engine.sema, Engine.fromStr("sema").?);
    try std.testing.expectEqual(Engine.old, Engine.fromStr("old").?);
    try std.testing.expect(Engine.fromStr("typeck") == null);
}

test "diag format variants exist" {
    try std.testing.expectEqual(DiagFormat.Plain, DiagFormat.Plain);
    try std.testing.expect(DiagFormat.Json != DiagFormat.Sarif);
}
