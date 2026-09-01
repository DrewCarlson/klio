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
pub const RequestedFeatures = pack_cache.RequestedFeatures;
const loadInstalledPacks = pack_cache.loadInstalledPacks;

const stdlib_image = @import("stdlib_image.zig");
const bundle = @import("bundle.zig");

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
    runtime.prof.fnProfMaybeStart();
    ir.eval.frameCountInit();
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
    runtime.prof.opProfMaybeStart();
    runtime.prof.fnProfMaybeStart();
    ir.eval.frameCountInit();
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

/// `klio transpile-dump <file>` — lower the file exactly as `run` does and
/// print each function's decoded bytecode stream (the transpiler emitter's
/// input tuples; plans/c-transpiler-plan.md stage 2). No execution.
pub fn runTranspileDump(
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
    const m = mg.get();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    for (m.funcs.items) |*f| {
        // The user script's functions only (empty package): pack/stdlib
        // bodies would drown the dump — the emitter consumes them lazily
        // through the same funcStreams call.
        if (f.blocks.len == 0) continue;
        if (f.package.len != 0) continue;
        const fs = ir.bc.funcStreams(f, false, m.consts.items) orelse continue;
        w.print("fn {s} (fid {d}, {d} blocks)\n", .{ f.name, f.id.int(), f.blocks.len }) catch return 1;
        for (fs.streams, 0..) |sopt, bi| {
            const st = sopt orelse continue;
            w.print(" block b{d}:\n", .{bi}) catch return 1;
            ir.bc.dumpStream(w, st) catch return 1;
        }
    }
    const text = aw.toOwnedSlice() catch return 1;
    defer gpa.free(text);
    io.printStdout(gpa, "{s}", .{text});
    return 0;
}

/// `klio transpile <file> [-o out.c]` — lower the file exactly as `run`
/// does and emit every user-script function's bytecode stream as C over
/// the klio_rt per-op helpers (plans/c-transpiler-plan.md stage 2), plus
/// the per-fid registration hook and a `main` that drives the program
/// through libklio_rt. The emitted file compiles with
/// `zig cc out.c -I<include> -L<lib> -lklio_rt -lzstd`.
pub fn runTranspile(
    gpa: std.mem.Allocator,
    path: []const u8,
    out_path: ?[]const u8,
    features: *RequestedFeatures,
) u8 {
    // The emitted ids (fids, const ids, trace file ids) are only
    // meaningful against ONE exact module, and an in-process bake is not
    // id-stable across processes — so the deliverable pins the module:
    // the program's dependency base bakes to a `.klio-image` artifact
    // beside the C file, the emitter assembles the module from THAT
    // artifact exactly as `run-image` does, and the emitted `main` runs
    // the program against the same artifact.
    const c_out = out_path orelse blk: {
        const base = std.fs.path.basename(path);
        const stem = if (std.mem.endsWith(u8, base, ".kt")) base[0 .. base.len - 3] else base;
        break :blk std.fmt.allocPrint(gpa, "{s}.c", .{stem}) catch return 1;
    };
    const image_path = blk: {
        const stem = if (std.mem.endsWith(u8, c_out, ".c")) c_out[0 .. c_out.len - 2] else c_out;
        break :blk std.fmt.allocPrint(gpa, "{s}.klio-image", .{stem}) catch return 1;
    };
    const bake_rc = bundle.bakeImage(gpa, &.{path}, features, image_path);
    if (bake_rc == 0) {
        if (bundle.assembleImageBuild(gpa, image_path, &.{path})) |asm_r| {
            var built = asm_r.built;
            return transpileEmit(gpa, &built, path, c_out, image_path);
        }
    }
    // A program the image path cannot serve (an unbakeable base, or a
    // base-name shadow `canExtendBase` rejects) runs the legacy
    // whole-program lowering — in the CLI, AND in the transpiled binary,
    // whose `klio_rt_run_file` declines the image path the same way. Emit
    // from the same legacy module; the fqn/fingerprint guards keep a
    // drifted binary interpreted rather than wrong.
    io.printStderr(gpa, "note: image path unavailable; emitting against the whole-program lowering\n", .{});
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

    if (computeEagerCalls(gpa, all_asts.items, &.{})) |ec| ir.pending_eager_calls = ec;
    span.active_map = &map;
    var built = interp_ir.build.buildModuleFiles(gpa, all_asts.items) catch {
        io.printStderr(gpa, "error: lowering failed\n", .{});
        return 1;
    };
    defer built.deinit();
    return transpileEmit(gpa, &built, path, c_out, null);
}

fn transpileEmit(
    gpa: std.mem.Allocator,
    built: *interp_ir.build.BuiltModule,
    path: []const u8,
    out_path: []const u8,
    image_path: ?[]const u8,
) u8 {
    const mg = built.module.borrow();
    defer mg.deinit();
    const m = mg.get();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    // The hot-view layout, frozen at EMIT time: the same fill the runtime
    // performs, printed as compile-time constants so every inline fast
    // path compiles to direct constant-offset loads instead of reads
    // through the runtime-filled KV struct. The runtime verifies the
    // frozen copy (registered below) against its own fill and disables
    // the view wholesale on any mismatch, so a .c linked against a
    // different runtime falls back to the exported helpers.
    var kvf: ir.hot_layout.HotLayout = undefined;
    ir.hot_layout.fillLayout(&kvf);
    w.print(
        \\/* Generated by `klio transpile {s}`. Do not edit.
        \\ * Build: zig cc <this file> -I<include> -L<lib> -lklio_rt -lzstd */
        \\#include <klio_rt.h>
        \\#include <string.h>
        \\#include <math.h>
        \\#include <stdint.h>
        \\
        \\/* Hot view: inline scalar ops over the EMIT-TIME frozen Value
        \\ * layout (KVC_*). The runtime fills KV after profile selection
        \\ * and verifies the frozen copy; usable == 0 (policy or layout
        \\ * mismatch) keeps every op on the exported helpers. */
        \\static klio_hot_layout KV;
        \\
    , .{path}) catch return 1;
    inline for (@typeInfo(ir.hot_layout.HotLayout).@"struct".fields) |fld| {
        comptime if (std.mem.eql(u8, fld.name, "usable") or
            std.mem.eql(u8, fld.name, "obj_usable") or
            std.mem.eql(u8, fld.name, "span_usable")) continue;
        var upper: [fld.name.len]u8 = undefined;
        for (fld.name, 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
        w.print("#define KVC_{s} {d}u\n", .{ upper, @field(kvf, fld.name) }) catch return 1;
    }
    w.print("static const klio_hot_layout KVF = {{\n", .{}) catch return 1;
    inline for (@typeInfo(ir.hot_layout.HotLayout).@"struct".fields) |fld| {
        w.print("  .{s} = {d}u,\n", .{ fld.name, @field(kvf, fld.name) }) catch return 1;
    }
    w.print("}};\n", .{}) catch return 1;
    w.print(
        \\
        \\static inline uint8_t *kv_slot(uint8_t *regs, uint32_t i) {{
        \\  return regs + (size_t)i * KVC_VALUE_SIZE;
        \\}}
        \\static inline uint64_t kv_tag(const uint8_t *s) {{
        \\  uint64_t t = 0;
        \\  memcpy(&t, s + KVC_TAG_OFF, KVC_TAG_SIZE);
        \\  return t;
        \\}}
        \\static inline void kv_set_tag(uint8_t *s, uint64_t tag) {{
        \\  memcpy(s + KVC_TAG_OFF, &tag, KVC_TAG_SIZE);
        \\}}
        \\static inline void kv_const_int(uint8_t *s, int32_t v) {{
        \\  memcpy(s + KVC_INT_OFF, &v, 4);
        \\  kv_set_tag(s, KVC_TAG_INT);
        \\}}
        \\static inline int32_t kv_int(const uint8_t *s) {{
        \\  int32_t v;
        \\  memcpy(&v, s + KVC_INT_OFF, 4);
        \\  return v;
        \\}}
        \\static inline void kv_set_bool(uint8_t *s, uint8_t v) {{
        \\  memcpy(s + KVC_BOOL_OFF, &v, 1);
        \\  kv_set_tag(s, KVC_TAG_BOOL);
        \\}}
        \\static inline int64_t kv_long(const uint8_t *s) {{
        \\  int64_t v;
        \\  memcpy(&v, s + KVC_LONG_OFF, 8);
        \\  return v;
        \\}}
        \\static inline void kv_set_long(uint8_t *s, int64_t v) {{
        \\  memcpy(s + KVC_LONG_OFF, &v, 8);
        \\  kv_set_tag(s, KVC_TAG_LONG);
        \\}}
        \\static inline uint16_t kv_char(const uint8_t *s) {{
        \\  uint16_t v;
        \\  memcpy(&v, s + KVC_CHAR_OFF, 2);
        \\  return v;
        \\}}
        \\static inline void kv_set_char(uint8_t *s, uint16_t v) {{
        \\  memcpy(s + KVC_CHAR_OFF, &v, 2);
        \\  kv_set_tag(s, KVC_TAG_CHAR);
        \\}}
        \\/* Object view: a plain stored field read, inline behind a class
        \\ * guard. The route (class identity + stored slot) is resolved once
        \\ * per site by the runtime and cached by the caller; a different
        \\ * class, a non-instance receiver or an unresolved site returns 0 and
        \\ * the site falls back to the escape helper, which carries the full
        \\ * semantics (custom getters, delegates, misses). */
        \\static inline void *kv_inst(const uint8_t *s) {{
        \\  void *p;
        \\  memcpy(&p, s + KVC_INST_PTR_OFF, sizeof(void *));
        \\  return p;
        \\}}
        \\static inline int kv_getfield(void *ctx, uint8_t *regs, uint32_t blk, uint32_t idx,
        \\                              uint32_t dst, uint32_t recv, uint64_t *site) {{
        \\  if (!KV.obj_usable) return 0;
        \\  const uint8_t *rs = kv_slot(regs, recv);
        \\  if (kv_tag(rs) != KVC_TAG_INSTANCE) return 0;
        \\  uint8_t *cell = (uint8_t *)kv_inst(rs);
        \\  if (!cell) return 0;
        \\  uint8_t *inst = cell + KVC_CELL_DATA_OFF;
        \\  uint64_t cls;
        \\  memcpy(&cls, inst + KVC_INST_CLASS_OFF, sizeof(uint64_t));
        \\  /* One word carries the whole route: the class cell in the high 48
        \\   * bits (a user-space pointer) and slot+1 in the low 16. A pair of
        \\   * words could be read half-updated by another thread and index the
        \\   * wrong field; one word is published or it is not. */
        \\  uint64_t cls48 = cls & 0xFFFFFFFFFFFFull;
        \\  uint64_t want = *site;
        \\  if ((want >> 16) != cls48 || (want & 0xFFFFu) == 0) {{
        \\    uint64_t rcls = 0;
        \\    int32_t rslot = -1;
        \\    if (!klio_op_field_route(ctx, blk, idx, &rcls, &rslot)) return 0;
        \\    if ((rcls & 0xFFFFFFFFFFFFull) != cls48) return 0;
        \\    if (rslot < 0 || rslot >= 0xFFFE) return 0;
        \\    want = (cls48 << 16) | (uint64_t)(rslot + 1);
        \\    *site = want;
        \\  }}
        \\  size_t slot = (size_t)((want & 0xFFFFu) - 1u);
        \\  uint8_t *fields = inst + KVC_INST_FIELDS_OFF;
        \\  uint8_t *items;
        \\  size_t len;
        \\  memcpy(&items, fields + KVC_FIELDS_PTR_OFF, sizeof(void *));
        \\  memcpy(&len, fields + KVC_FIELDS_LEN_OFF, sizeof(size_t));
        \\  if (slot >= len) return 0;
        \\  memcpy(kv_slot(regs, dst), items + slot * KVC_FIELD_STRIDE + KVC_FIELD_VALUE_OFF, KVC_VALUE_SIZE);
        \\  return 1;
        \\}}
        \\/* An IntArray element WRITE, inline. Same guards as the read, plus
        \\ * the value must be an Int: a primitive buffer holds no references,
        \\ * so the store needs no write barrier and no release of a previous
        \\ * occupant. Anything else escapes. */
        \\static inline int kv_index_set_int(uint8_t *regs, uint32_t recv, uint32_t idxreg, uint32_t valreg) {{
        \\  if (!KV.obj_usable) return 0;
        \\  const uint8_t *rs = kv_slot(regs, recv);
        \\  if (kv_tag(rs) != KVC_TAG_ARRAY) return 0;
        \\  uint64_t prim = 0;
        \\  memcpy(&prim, rs + KVC_ARR_PRIM_OFF, sizeof(uint64_t));
        \\  if (prim != KVC_ARR_PRIM_INT_WORD) return 0;
        \\  const uint8_t *is_ = kv_slot(regs, idxreg);
        \\  const uint8_t *vs = kv_slot(regs, valreg);
        \\  if (kv_tag(is_) != KVC_TAG_INT || kv_tag(vs) != KVC_TAG_INT) return 0;
        \\  int32_t i = kv_int(is_);
        \\  if (i < 0) return 0;
        \\  uint8_t *cell;
        \\  memcpy(&cell, rs + KVC_ARR_CELL_OFF, sizeof(void *));
        \\  if (!cell) return 0;
        \\  uint8_t *items;
        \\  size_t nbytes;
        \\  memcpy(&items, cell + KVC_PRIMBUF_PTR_OFF, sizeof(void *));
        \\  memcpy(&nbytes, cell + KVC_PRIMBUF_LEN_OFF, sizeof(size_t));
        \\  if ((size_t)i * 4u + 4u > nbytes) return 0;
        \\  int32_t v = kv_int(vs);
        \\  memcpy(items + (size_t)i * 4u, &v, 4);
        \\  return 1;
        \\}}
        \\/* A plain stored-field WRITE, inline behind the same one-word class
        \\ * guard as the read. A stored field can hold a reference, so the
        \\ * containing cell takes the GC write barrier before the store. A
        \\ * custom setter, a delegate or an unresolved site escapes. */
        \\static inline int kv_setfield(void *ctx, uint8_t *regs, uint32_t blk, uint32_t idx,
        \\                              uint32_t recv, uint32_t val, uint64_t *site) {{
        \\  if (!KV.obj_usable) return 0;
        \\  const uint8_t *rs = kv_slot(regs, recv);
        \\  if (kv_tag(rs) != KVC_TAG_INSTANCE) return 0;
        \\  uint8_t *cell = (uint8_t *)kv_inst(rs);
        \\  if (!cell) return 0;
        \\  uint8_t *inst = cell + KVC_CELL_DATA_OFF;
        \\  uint64_t cls;
        \\  memcpy(&cls, inst + KVC_INST_CLASS_OFF, sizeof(uint64_t));
        \\  uint64_t cls48 = cls & 0xFFFFFFFFFFFFull;
        \\  uint64_t want = *site;
        \\  if ((want >> 16) != cls48 || (want & 0xFFFFu) == 0) {{
        \\    uint64_t rcls = 0;
        \\    int32_t rslot = -1;
        \\    if (!klio_op_field_write_route(ctx, blk, idx, &rcls, &rslot)) return 0;
        \\    if ((rcls & 0xFFFFFFFFFFFFull) != cls48) return 0;
        \\    if (rslot < 0 || rslot >= 0xFFFE) return 0;
        \\    want = (cls48 << 16) | (uint64_t)(rslot + 1);
        \\    *site = want;
        \\  }}
        \\  size_t slot = (size_t)((want & 0xFFFFu) - 1u);
        \\  uint8_t *fields = inst + KVC_INST_FIELDS_OFF;
        \\  uint8_t *items;
        \\  size_t len;
        \\  memcpy(&items, fields + KVC_FIELDS_PTR_OFF, sizeof(void *));
        \\  memcpy(&len, fields + KVC_FIELDS_LEN_OFF, sizeof(size_t));
        \\  if (slot >= len) return 0;
        \\  klio_rt_write_barrier(cell);
        \\  memcpy(items + slot * KVC_FIELD_STRIDE + KVC_FIELD_VALUE_OFF, kv_slot(regs, val), KVC_VALUE_SIZE);
        \\  return 1;
        \\}}
        \\/* Scalar-replay float lanes: genre 5 stores double bits, genre 6
        \\ * stores float bits, both in the int64 value lane. */
        \\static inline double kl_bits2d(int64_t l) {{ double d; memcpy(&d, &l, 8); return d; }}
        \\static inline int64_t kl_d2bits(double d) {{ int64_t l; memcpy(&l, &d, 8); return l; }}
        \\static inline float kl_bits2f(int64_t l) {{ uint32_t u = (uint32_t)l; float f; memcpy(&f, &u, 4); return f; }}
        \\static inline int64_t kl_f2bits(float f) {{ uint32_t u; memcpy(&u, &f, 4); return (int64_t)u; }}
        \\static inline double kl_asd(int64_t l, int g) {{
        \\  if (g == 5) return kl_bits2d(l);
        \\  if (g == 6) return (double)kl_bits2f(l);
        \\  return (double)l;
        \\}}
        \\static inline float kl_asf(int64_t l, int g) {{
        \\  if (g == 6) return kl_bits2f(l);
        \\  return (float)l;
        \\}}
        \\
        \\/* Inlined per-statement trace store: a plain 3-field + presence
        \\ * write into the frame's cur_span slot (no ownership). */
        \\static inline void kv_trace(uint8_t *sp, uint32_t f, uint32_t s, uint32_t e) {{
        \\  memcpy(sp + KVC_SPAN_FILE_OFF, &f, 4);
        \\  memcpy(sp + KVC_SPAN_START_OFF, &s, 4);
        \\  memcpy(sp + KVC_SPAN_END_OFF, &e, 4);
        \\  sp[KVC_SPAN_TAG_OFF] = KVC_SPAN_TAG_SET;
        \\}}
        \\
        \\/* Inlined fused edge guard: poll the flag bytes and call the slow
        \\ * op only when a trigger fires (bit0 counter cadence, bit1 abandon,
        \\ * bit2 gc pending, bit3 stress, bit4 idle cadence). Mirrors the
        \\ * interpreter's fusedEdgeGuard trigger-for-trigger. */
        \\static inline int32_t kv_edge(void *ctx, klio_edge_view *ev) {{
        \\  uint32_t r = 0;
        \\  *ev->counter += 1;
        \\  if ((*ev->counter & 0xFFFFu) == 0) r |= 1u;
        \\  if (*ev->abandon_req && (*ev->abandonable || *ev->rb_abandon)) r |= 2u;
        \\  if (ev->always) r |= 8u;
        \\  else if (ev->gc_on) {{
        \\    *ev->idle += 1;
        \\    if ((*ev->idle & 0xFFFFu) == 0) r |= 16u;
        \\    if (*ev->gc_pending) r |= 4u;
        \\  }}
        \\  if (r) return klio_op_edge_rare(ctx, r);
        \\  return 0;
        \\}}
        \\
        \\
    , .{}) catch return 1;

    const Emitted = struct { fid: u32, fqn: []const u8 };
    var emitted: std.ArrayList(Emitted) = .empty;
    defer emitted.deinit(gpa);
    // Scalar-replay (`kl_`) pass: per-fn eligibility, then a fixpoint
    // closing the set over call targets (a body is only pure when every
    // callee is), then prototypes (mutual/self recursion) and bodies.
    // KLIO_TRANSPILE_PKGS=<comma-separated package prefixes> widens emission
    // past the user script into library code. The pinned image the binary
    // loads carries those same fids, so a registered pack body is the one the
    // run resolves; without the flag the emitter keeps its user-only default
    // (pack bodies would add tens of thousands of C functions).
    const pkg_sel: ?[]const u8 = runtime.envOnce("KLIO_TRANSPILE_PKGS");
    const emitFor = struct {
        fn ok(sel: ?[]const u8, f: *const ir.Func) bool {
            if (f.package.len == 0) return true;
            const s2 = sel orelse return false;
            var it = std.mem.splitScalar(u8, s2, ',');
            while (it.next()) |pfx| {
                if (pfx.len != 0 and std.mem.startsWith(u8, f.package, pfx)) return true;
            }
            return false;
        }
    }.ok;

    // With a selector, the image's own functions (addressed by id through the
    // lazy header table, not present in `funcs.items`) join the walk.
    var extra_funcs: std.ArrayList(*const ir.Func) = .empty;
    defer extra_funcs.deinit(gpa);
    if (pkg_sel != null) {
        var fid: u32 = 0;
        while (fid < m.func_header_offsets.len) : (fid += 1) {
            const f = m.funcById(@enumFromInt(fid)) orelse continue;
            if (!emitFor(pkg_sel, f)) continue;
            if (f.blocks.len == 0 and !m.ensureFuncBody(@constCast(f))) continue;
            extra_funcs.append(gpa, f) catch return 1;
        }
    }

    var leaf_targets = std.AutoHashMap(u32, LeafInfo).init(gpa);
    defer {
        var it = leaf_targets.valueIterator();
        while (it.next()) |v| v.targets.deinit(gpa);
        leaf_targets.deinit();
    }
    for (extra_funcs.items) |f| {
        const fs = ir.bc.funcStreams(f, true, m.consts.items) orelse continue;
        if (leafEligible(gpa, m, f, fs, m.consts.items)) |tg| {
            var tg2 = tg;
            leaf_targets.put(f.id.int(), tg2) catch {
                tg2.targets.deinit(gpa);
                return 1;
            };
        }
    }
    for (m.funcs.items) |*f| {
        if (!emitFor(pkg_sel, f)) continue;
        if (f.blocks.len == 0 and !m.ensureFuncBody(@constCast(f))) continue;
        const fs = ir.bc.funcStreams(f, true, m.consts.items) orelse continue;
        if (leafEligible(gpa, m, f, fs, m.consts.items)) |tg| {
            leaf_targets.put(f.id.int(), tg) catch return 1;
        }
    }
    // Fixpoint: (a) every call target must itself be eligible; (b) a
    // target that may return an OBJECT (its tail is a construction, or
    // it tail-calls such a fn) is only callable in tail position — the
    // ctor-tail genre then forwards unchanged through the whole chain
    // and only the gate materializes. Non-tail object calls prune the
    // caller. The returns-object set is recomputed each round.
    var pruned = true;
    while (pruned) {
        pruned = false;
        var obj = std.AutoHashMap(u32, void).init(gpa);
        defer obj.deinit();
        {
            var grew = true;
            while (grew) {
                grew = false;
                var oit = leaf_targets.iterator();
                while (oit.next()) |e| {
                    if (obj.contains(e.key_ptr.*)) continue;
                    var is_obj = e.value_ptr.ctor_tail;
                    if (!is_obj) for (e.value_ptr.targets.items) |t| {
                        if (t.tail and obj.contains(t.fid)) {
                            is_obj = true;
                            break;
                        }
                    };
                    if (is_obj) {
                        obj.put(e.key_ptr.*, {}) catch return 1;
                        grew = true;
                    }
                }
            }
        }
        var it = leaf_targets.iterator();
        var drop: ?u32 = null;
        while (it.next()) |e| {
            for (e.value_ptr.targets.items) |t| {
                if (!leaf_targets.contains(t.fid) or
                    (!t.tail and obj.contains(t.fid)))
                {
                    drop = e.key_ptr.*;
                    break;
                }
            }
            if (drop != null) break;
        }
        if (drop) |d| {
            if (std.c.getenv("KLIO_LEAF_TRACE") != null) {
                const df = m.funcById(ir.FuncId.from(d));
                std.debug.print("[leaf-prune] {s}\n", .{if (df) |x| x.fqn else "?"});
            }
            var v = leaf_targets.fetchRemove(d).?.value;
            v.targets.deinit(gpa);
            pruned = true;
        }
    }
    {
        var it = leaf_targets.keyIterator();
        while (it.next()) |fid| {
            w.print("static int32_t kl_{d}(void *ctx, klio_edge_view *ev, const int64_t *argv, const int32_t *argg, int64_t *ret, int32_t *retg, uint32_t depth, int64_t *aux, int32_t *auxg);\n", .{fid.*}) catch return 1;
        }
        w.print("\n", .{}) catch return 1;
    }
    var leaf_emitted: std.ArrayList(Emitted) = .empty;
    defer leaf_emitted.deinit(gpa);
    // The user script's functions by default; `KLIO_TRANSPILE_PKGS` widens the
    // walk to the image's library bodies. The fids the emitter registers must
    // match the fids the running binary resolves, which the pinned image
    // guarantees.
    for (m.funcs.items) |*f| {
        if (!emitFor(pkg_sel, f)) continue;
        if (f.blocks.len == 0 and !m.ensureFuncBody(@constCast(f))) continue;
        // allow_fuse mirrors the frame loop's default (the loop JIT off):
        // the running binary builds the same streams this emission used.
        const fs = ir.bc.funcStreams(f, true, m.consts.items) orelse continue;
        if (leaf_targets.contains(f.id.int())) {
            emitLeafFunc(w, m, f, fs, m.consts.items) catch return 1;
            leaf_emitted.append(gpa, .{ .fid = f.id.int(), .fqn = f.fqn }) catch return 1;
        }
        emitNativeFunc(w, f, fs, m.consts.items) catch return 1;
        emitted.append(gpa, .{ .fid = f.id.int(), .fqn = f.fqn }) catch return 1;
    }
    for (extra_funcs.items) |f| {
        const fs = ir.bc.funcStreams(f, true, m.consts.items) orelse continue;
        // A library leaf gets the frameless scalar replay too: the census of
        // a recomposition is mostly one-line accessors, and the replay is the
        // only emitted form that skips the activation entirely.
        if (leaf_targets.contains(f.id.int())) {
            emitLeafFunc(w, m, f, fs, m.consts.items) catch return 1;
            leaf_emitted.append(gpa, .{ .fid = f.id.int(), .fqn = f.fqn }) catch return 1;
        }
        emitNativeFunc(w, f, fs, m.consts.items) catch return 1;
        emitted.append(gpa, .{ .fid = f.id.int(), .fqn = f.fqn }) catch return 1;
    }

    w.print("void klio_transpiled_register(void) {{\n", .{}) catch return 1;
    w.print("  klio_rt_register_hot_layout(&KV);\n", .{}) catch return 1;
    w.print("  klio_rt_register_hot_frozen(&KVF);\n", .{}) catch return 1;
    w.print("  klio_rt_register_module_check({d}u, {d}u);\n", .{ m.funcs.items.len, m.consts.items.len }) catch return 1;
    for (emitted.items) |e| {
        w.print("  klio_rt_register_native({d}u, kf_{d}, ", .{ e.fid, e.fid }) catch return 1;
        emitCString(w, e.fqn) catch return 1;
        w.print(");\n", .{}) catch return 1;
    }
    for (leaf_emitted.items) |e| {
        w.print("  klio_rt_register_native_leaf({d}u, kl_{d}, ", .{ e.fid, e.fid }) catch return 1;
        emitCString(w, e.fqn) catch return 1;
        w.print(");\n", .{}) catch return 1;
    }
    if (image_path) |ip| {
        w.print("}}\n\n#ifndef KLIO_TRANSPILED_NO_MAIN\nint main(void) {{\n  klio_transpiled_register();\n  return klio_rt_run_image(", .{}) catch return 1;
        emitCString(w, ip) catch return 1;
        w.print(", ", .{}) catch return 1;
        emitCString(w, path) catch return 1;
    } else {
        w.print("}}\n\n#ifndef KLIO_TRANSPILED_NO_MAIN\nint main(void) {{\n  klio_transpiled_register();\n  return klio_rt_run_file(", .{}) catch return 1;
        emitCString(w, path) catch return 1;
    }
    w.print(");\n}}\n#endif\n", .{}) catch return 1;

    const text = aw.toOwnedSlice() catch return 1;
    defer gpa.free(text);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = out_path, .data = text }) catch {
        io.printStderr(gpa, "error: cannot write `{s}`\n", .{out_path});
        return 1;
    };
    return 0;
}

fn emitCString(w: anytype, s: []const u8) !void {
    try w.print("\"", .{});
    for (s) |ch| {
        switch (ch) {
            '"', '\\' => try w.print("\\{c}", .{ch}),
            '\n' => try w.print("\\n", .{}),
            else => {
                if (ch < 0x20 or ch == 0x7f) {
                    try w.print("\\{o:0>3}", .{ch});
                } else {
                    try w.print("{c}", .{ch});
                }
            },
        }
    }
    try w.print("\"", .{});
}


/// Whether `kind` is modeled by the scalar-replay (`kl_`) emitter.
fn leafBinModeled(kind: ir.BinOp) bool {
    return switch (kind) {
        .Add, .Sub, .Mul, .Div, .Mod, .Less, .LessEq, .Greater, .GreaterEq, .Eq, .NotEq, .BoxedEq, .BoxedNotEq, .And, .Or, .Xor, .Shl, .Shr, .UShr => true,
        else => false,
    };
}

/// Scalar-replay eligibility for one function: every stream op computable
/// over (int64, genre) pairs, every call a plain positional exact-arity
/// direct call. Returns the call-target fids (empty ok) or null when
/// ineligible. The caller closes the set over targets (fixpoint).
/// kl_-only scalar consts: the fused-loop set plus the float genres
/// (stored as raw bits in the int64 lane).
fn leafConstScalar(consts: []const ir.Const, id: u32) ?struct { g: u8, v: i64 } {
    if (fuseConstScalar(consts, id)) |sc| return .{ .g = sc.g, .v = sc.v };
    if (id >= consts.len) return null;
    return switch (consts[id]) {
        .Double => |d| .{ .g = 5, .v = @bitCast(d) },
        .Float => |fl| .{ .g = 6, .v = @as(i64, @as(u32, @bitCast(fl))) },
        else => null,
    };
}

fn leafTrace(f: *const ir.Func, comptime why: []const u8) void {
    if (std.c.getenv("KLIO_LEAF_TRACE") != null) std.debug.print("[leaf-miss] {s}: " ++ why ++ "\n", .{f.fqn});
}

const LeafTarget = struct { fid: u32, tail: bool };
const LeafInfo = struct { targets: std.ArrayList(LeafTarget), ctor_tail: bool };

/// Whether the stream position `q` (just past an escape) is `ret dst` —
/// the escaped instruction's result flows straight out. Trace ops may
/// intervene; anything else means mid-body use.
fn streamTailRet(code: []const u32, q0: usize, dst: u32) bool {
    var q = q0;
    while (q < code.len and @as(ir.bc.Op, @enumFromInt(code[q])) == .trace) q += 4;
    if (q + 2 >= code.len) return false;
    if (@as(ir.bc.Op, @enumFromInt(code[q])) != .ret) return false;
    return code[q + 1] != 0 and code[q + 2] == dst;
}

/// The scalar integer conversion a zero-arg virtual slot names, or null.
/// Slot ids reuse the root declaration's FuncId, so the name is static.
const ScalarConv = enum { to_int, to_long, to_short, to_byte, to_char };
fn leafScalarConv(m: *const ir.Module, slot: ir.MethodSlotId) ?ScalarConv {
    const rf = m.funcById(ir.FuncId.from(slot.int())) orelse return null;
    const eq = std.mem.eql;
    if (eq(u8, rf.name, "toInt")) return .to_int;
    if (eq(u8, rf.name, "toLong")) return .to_long;
    if (eq(u8, rf.name, "toShort")) return .to_short;
    if (eq(u8, rf.name, "toByte")) return .to_byte;
    if (eq(u8, rf.name, "toChar")) return .to_char;
    return null;
}

fn leafEligible(gpa: std.mem.Allocator, m: *const ir.Module, f: *const ir.Func, fs: *const ir.bc.FuncStreams, consts: []const ir.Const) ?LeafInfo {
    var targets: std.ArrayList(LeafTarget) = .empty;
    var ctor_tail = false;
    var ok = true;
    if (f.params.len > 8) {
        leafTrace(f, "arity");
        ok = false;
    }
    if (f.is_suspend) {
        leafTrace(f, "suspend");
        ok = false;
    }
    for (f.blocks, 0..) |*blk, bi| {
        if (!ok) break;
        if (blk.catches.len != 0 or blk.finally != null) {
            leafTrace(f, "try");
            ok = false;
            break;
        }
        // A throw-terminated block never runs natively: the emitter
        // replaces its whole body with `return 0` (bail), and the
        // interpreter's exact re-run raises the real throwable. So the
        // guard pattern (StringConcat + NewInstance + throw on the cold
        // path) costs a body nothing.
        if (blk.terminator == .Throw) continue;
        const st = (if (bi < fs.streams.len) fs.streams[bi] else null) orelse {
            leafTrace(f, "no-stream");
            ok = false;
            break;
        };
        const code = st.code;
        var pc: usize = 0;
        while (pc < code.len) {
            const op: ir.bc.Op = @enumFromInt(code[pc]);
            switch (op) {
                .trace => pc += 4,
                .const_int => pc += 3,
                .const_load => {
                    if (leafConstScalar(consts, code[pc + 2]) == null) {
                        leafTrace(f, "nonscalar-const");
                        ok = false;
                    }
                    pc += 3;
                },
                .move, .load_param => pc += 3,
                .cell_get => {
                    leafTrace(f, "cell");
                    ok = false;
                    pc += 3;
                },
                .bin => {
                    if (!leafBinModeled(@enumFromInt(code[pc + 2]))) {
                        leafTrace(f, "bin-kind");
                        ok = false;
                    }
                    pc += 6;
                },
                .escape => {
                    const inst_idx = code[pc + 1];
                    switch (f.blocks[bi].insts[inst_idx]) {
                        .Call => |c| {
                            if (c.type_args.len != 0 or c.n_args > 8) {
                                leafTrace(f, "call-shape");
                                ok = false;
                            } else {
                                var names_null = true;
                                for (c.arg_names) |n| {
                                    if (n != null) names_null = false;
                                }
                                if (!names_null) ok = false else targets.append(gpa, .{
                                    .fid = c.func.int(),
                                    .tail = streamTailRet(code, pc + 2, c.dst.int()),
                                }) catch {
                                    ok = false;
                                };
                            }
                        },
                        .UnOp => {},
                        .CallMemberOrGlobal => |*cg| {
                            // A bare constructor call the index bound to a
                            // CLASS, in tail position of a receiver-less
                            // top-level fn: no member leg can shadow (no
                            // receiver chain; captures would have shown up
                            // as cell ops), so the class leg is the whole
                            // semantics — same ctor-tail protocol as
                            // NewInstance, constructed once at the gate.
            if (cg.class) |cls| {
                                const inner = cls.int() < m.classes.items.len and
                                    m.classes.items[cls.int()].is_inner;
                                if (f.kind != .plain or
                                    std.mem.indexOfScalar(u8, f.fqn, '<') != null or
                                    cg.n_args > 8 or inner or
                                    !streamTailRet(code, pc + 2, cg.dst.int()))
                                {
                                    leafTrace(f, "obj-mid");
                                    ok = false;
                                } else ctor_tail = true;
                            } else {
                                leafTrace(f, "escape-op");
                                ok = false;
                            }
                        },
                        .CallVirtual => |*cv| {
                            // Zero-arg virtual on a receiver that is a
                            // SCALAR by construction (every register in an
                            // eligible body is): the slot id is the root
                            // declaration's FuncId, so the method NAME is
                            // known at emit time. Integer conversions emit
                            // inline; everything else bails the body.
                            if (cv.n_args != 0 or leafScalarConv(m, cv.slot) == null) {
                                leafTrace(f, "virt");
                                ok = false;
                            }
                        },
                        .NewInstance => |*ni| {
                            // Ctor-tail only: the leaf hands the scalar ctor
                            // args back through aux and the gate constructs
                            // once through the host (exact, throw included).
                            // Mid-body objects have nowhere to live natively.
                            const inner = ni.class.int() < m.classes.items.len and
                                m.classes.items[ni.class.int()].is_inner;
                            if (ni.n_args > 8 or inner or
                                !streamTailRet(code, pc + 2, ni.dst.int()))
                            {
                                leafTrace(f, "obj-mid");
                                ok = false;
                            } else ctor_tail = true;
                        },
                        else => {
                            leafTrace(f, "escape-op");
                            ok = false;
                        },
                    }
                    pc += 2;
                },
                .jump => pc += 2,
                .br => pc += 4,
                .ret => pc += 3,
                .term_exit => {
                    leafTrace(f, "term");
                    ok = false;
                    pc += 1;
                },
                .cmp_br => {
                    if (!leafBinModeled(@enumFromInt(code[pc + 2]))) {
                        leafTrace(f, "bin-kind");
                        ok = false;
                    }
                    pc += 8;
                },
            }
            if (!ok) break;
        }
    }
    if (!ok) {
        targets.deinit(gpa);
        return null;
    }
    return .{ .targets = targets, .ctor_tail = ctor_tail };
}

/// One scalar bin op of the replay: dynamic genre/width arithmetic with
/// `scalarBin`'s exact semantics over the modeled genre set; any combo
/// outside the model bails (`return 0`), which purity makes exact.
fn emitLeafBin(w: anytype, kind: ir.BinOp, dst: u32, lhs: u32, rhs: u32) !void {
    switch (kind) {
        .Less, .LessEq, .Greater, .GreaterEq => {
            const sym: []const u8 = switch (kind) {
                .Less => "<",
                .LessEq => "<=",
                .Greater => ">",
                .GreaterEq => ">=",
                else => unreachable,
            };
            try w.print("  if (g{d} > 6 || g{d} > 6 || g{d} == 2 || g{d} == 2 || g{d} == 3 || g{d} == 3) return 0;\n", .{ lhs, rhs, lhs, rhs, lhs, rhs });
            // A float operand compares in floating point (IEEE — NaN
            // yields false), the other side converted by its genre.
            try w.print("  if (g{d} >= 5 || g{d} >= 5) {{ double fa = kl_asd(l{d}, g{d}), fb = kl_asd(l{d}, g{d}); l{d} = (fa {s} fb); g{d} = 2; }}\n", .{ lhs, rhs, lhs, lhs, rhs, rhs, dst, sym, dst });
            try w.print("  else {{ l{d} = (l{d} {s} l{d}); g{d} = 2; }}\n", .{ dst, lhs, sym, rhs, dst });
        },
        .Eq, .NotEq => {
            // Same genre or both signed-numeric widths compare by value
            // (Kotlin promotes `1 == 1L`); any other mix (Bool/Char vs
            // numeric, literal-adoption shapes) bails to the interpreter.
            const neg: []const u8 = if (kind == .NotEq) "!" else "";
            try w.print("  if (!(g{d} == g{d} || (g{d} <= 1 && g{d} <= 1))) return 0;\n", .{ lhs, rhs, lhs, rhs });
            // Same-genre float equality is the IEEE operator (NaN false),
            // never the bit compare.
            try w.print("  if (g{d} == 5) {{ l{d} = {s}(kl_bits2d(l{d}) == kl_bits2d(l{d})); g{d} = 2; }}\n", .{ lhs, dst, neg, lhs, rhs, dst });
            try w.print("  else if (g{d} == 6) {{ l{d} = {s}(kl_bits2f(l{d}) == kl_bits2f(l{d})); g{d} = 2; }}\n", .{ lhs, dst, neg, lhs, rhs, dst });
            try w.print("  else {{ l{d} = {s}(l{d} == l{d}); g{d} = 2; }}\n", .{ dst, neg, lhs, rhs, dst });
        },
        .BoxedEq, .BoxedNotEq => {
            // Boxed equality is tag-sensitive across widths AND the framed
            // path may have adopted an Int literal to Long at bind — a
            // genre mismatch here cannot be decided locally, so it bails.
            const neg: []const u8 = if (kind == .BoxedNotEq) "!" else "";
            try w.print("  if (g{d} != g{d} || g{d} >= 5) return 0;\n", .{ lhs, rhs, lhs });
            try w.print("  l{d} = {s}(l{d} == l{d}); g{d} = 2;\n", .{ dst, neg, lhs, rhs, dst });
        },
        .Add, .Sub, .Mul => {
            const sym: []const u8 = switch (kind) {
                .Add => "+",
                .Sub => "-",
                .Mul => "*",
                else => unreachable,
            };
            // Float promotion first: any Double operand computes double,
            // any Float pair/int mix computes float — IEEE exactly as the
            // interpreter's scalar arms. Then the integer/Char rules.
            try w.print("  if (g{d} == 5 || g{d} == 5) {{ if (g{d} == 2 || g{d} == 2 || g{d} == 3 || g{d} == 3 || g{d} == 4 || g{d} == 4) return 0; double fa = kl_asd(l{d}, g{d}), fb = kl_asd(l{d}, g{d}); l{d} = kl_d2bits(fa {s} fb); g{d} = 5; }}\n", .{ lhs, rhs, lhs, rhs, lhs, rhs, lhs, rhs, lhs, lhs, rhs, rhs, dst, sym, dst });
            try w.print("  else if (g{d} == 6 || g{d} == 6) {{ if (g{d} == 2 || g{d} == 2 || g{d} == 3 || g{d} == 3 || g{d} == 4 || g{d} == 4) return 0; float fa = kl_asf(l{d}, g{d}), fb = kl_asf(l{d}, g{d}); l{d} = kl_f2bits(fa {s} fb); g{d} = 6; }}\n", .{ lhs, rhs, lhs, rhs, lhs, rhs, lhs, rhs, lhs, lhs, rhs, rhs, dst, sym, dst });
            try w.print("  else {{\n", .{});
            // Char rules: Char-Char (Sub) is Int; Char +/- Int stays Char;
            // any other Char combo bails. Width by promotion, wrap via
            // unsigned casts, exactly the interpreter's scalar arms.
            try w.print("  {{ int cl = (g{d} == 4), cr = (g{d} == 4);\n", .{ lhs, rhs });
            try w.print("    if (g{d} > 4 || g{d} > 4 || g{d} == 2 || g{d} == 2 || g{d} == 3 || g{d} == 3) return 0;\n", .{ lhs, rhs, lhs, rhs, lhs, rhs });
            if (kind == .Sub) {
                try w.print("    if (cl && cr) {{ l{d} = (int64_t)((int32_t)l{d} - (int32_t)l{d}); g{d} = 0; }}\n", .{ dst, lhs, rhs, dst });
                try w.print("    else if (cl || cr) {{ if (cr) return 0; l{d} = (int64_t)(uint16_t)((uint32_t)l{d} - (uint32_t)l{d}); g{d} = 4; }}\n", .{ dst, lhs, rhs, dst });
            } else {
                try w.print("    if (cl && cr) return 0;\n", .{});
                try w.print("    else if (cl || cr) {{ if (cr) return 0; l{d} = (int64_t)(uint16_t)((uint32_t)l{d} {s} (uint32_t)l{d}); g{d} = 4; }}\n", .{ dst, lhs, sym, rhs, dst });
            }
            try w.print("    else if ((g{d} | g{d}) & 1) {{ l{d} = (int64_t)((uint64_t)l{d} {s} (uint64_t)l{d}); g{d} = 1; }}\n", .{ lhs, rhs, dst, lhs, sym, rhs, dst });
            try w.print("    else {{ l{d} = (int64_t)(int32_t)((uint32_t)l{d} {s} (uint32_t)l{d}); g{d} = 0; }}\n  }} }}\n", .{ dst, lhs, sym, rhs, dst });
        },
        .Div, .Mod => {
            const sym: []const u8 = if (kind == .Div) "/" else "%";
            // Float division/remainder: IEEE (no zero guard — inf/NaN),
            // fmod matches Kotlin's truncated %.
            if (kind == .Div) {
                try w.print("  if (g{d} == 5 || g{d} == 5) {{ if (!((g{d} <= 1 || g{d} == 5) && (g{d} <= 1 || g{d} == 5))) return 0; l{d} = kl_d2bits(kl_asd(l{d}, g{d}) / kl_asd(l{d}, g{d})); g{d} = 5; goto klx_dm_{d}_{d}; }}\n", .{ lhs, rhs, lhs, lhs, rhs, rhs, dst, lhs, lhs, rhs, rhs, dst, dst, lhs });
                try w.print("  if (g{d} == 6 || g{d} == 6) {{ if (!((g{d} <= 1 || g{d} == 6) && (g{d} <= 1 || g{d} == 6))) return 0; l{d} = kl_f2bits(kl_asf(l{d}, g{d}) / kl_asf(l{d}, g{d})); g{d} = 6; goto klx_dm_{d}_{d}; }}\n", .{ lhs, rhs, lhs, rhs, lhs, rhs, dst, lhs, lhs, rhs, rhs, dst, dst, lhs });
            } else {
                try w.print("  if (g{d} == 5 || g{d} == 5) {{ if (!((g{d} <= 1 || g{d} == 5) && (g{d} <= 1 || g{d} == 5))) return 0; l{d} = kl_d2bits(fmod(kl_asd(l{d}, g{d}), kl_asd(l{d}, g{d}))); g{d} = 5; goto klx_dm_{d}_{d}; }}\n", .{ lhs, rhs, lhs, rhs, lhs, rhs, dst, lhs, lhs, rhs, rhs, dst, dst, lhs });
                try w.print("  if (g{d} == 6 || g{d} == 6) {{ if (!((g{d} <= 1 || g{d} == 6) && (g{d} <= 1 || g{d} == 6))) return 0; l{d} = kl_f2bits(fmodf(kl_asf(l{d}, g{d}), kl_asf(l{d}, g{d}))); g{d} = 6; goto klx_dm_{d}_{d}; }}\n", .{ lhs, rhs, lhs, rhs, lhs, rhs, dst, lhs, lhs, rhs, rhs, dst, dst, lhs });
            }
            try w.print("  if ((g{d} | g{d}) & ~1) return 0;\n", .{ lhs, rhs });
            try w.print("  if (l{d} == 0) return 0;\n", .{rhs});
            try w.print("  if ((g{d} | g{d}) & 1) {{ if (l{d} == INT64_MIN && l{d} == -1) return 0; l{d} = l{d} {s} l{d}; g{d} = 1; }}\n", .{ lhs, rhs, lhs, rhs, dst, lhs, sym, rhs, dst });
            try w.print("  else {{ if ((int32_t)l{d} == INT32_MIN && (int32_t)l{d} == -1) return 0; l{d} = (int64_t)((int32_t)l{d} {s} (int32_t)l{d}); g{d} = 0; }}\n", .{ lhs, rhs, dst, lhs, sym, rhs, dst });
            try w.print("  klx_dm_{d}_{d}:;\n", .{ dst, lhs });
        },
        .And, .Or, .Xor => {
            const sym: []const u8 = switch (kind) {
                .And => "&",
                .Or => "|",
                .Xor => "^",
                else => unreachable,
            };
            try w.print("  if (g{d} == 2 && g{d} == 2) {{ l{d} = (l{d} {s} l{d}) & 1; g{d} = 2; }}\n", .{ lhs, rhs, dst, lhs, sym, rhs, dst });
            try w.print("  else if (((g{d} | g{d}) & ~1) == 0) {{ int wide = (g{d} | g{d}) & 1; l{d} = l{d} {s} l{d}; if (!wide) l{d} = (int64_t)(int32_t)l{d}; g{d} = wide; }}\n", .{ lhs, rhs, lhs, rhs, dst, lhs, sym, rhs, dst, dst, dst });
            try w.print("  else return 0;\n", .{});
        },
        .Shl, .Shr, .UShr => {
            try w.print("  if ((g{d} != 0 && g{d} != 1) || g{d} != 0) return 0;\n", .{ lhs, lhs, rhs });
            switch (kind) {
                .Shl => {
                    try w.print("  if (g{d}) {{ unsigned sh = (unsigned)l{d} & 63u; l{d} = (int64_t)((uint64_t)l{d} << sh); g{d} = 1; }} else {{ unsigned sh = (unsigned)l{d} & 31u; l{d} = (int64_t)(int32_t)((uint32_t)l{d} << sh); g{d} = 0; }}\n", .{ lhs, rhs, dst, lhs, dst, rhs, dst, lhs, dst });
                },
                .Shr => {
                    try w.print("  if (g{d}) {{ unsigned sh = (unsigned)l{d} & 63u; l{d} = l{d} >> sh; g{d} = 1; }} else {{ unsigned sh = (unsigned)l{d} & 31u; l{d} = (int64_t)((int32_t)l{d} >> sh); g{d} = 0; }}\n", .{ lhs, rhs, dst, lhs, dst, rhs, dst, lhs, dst });
                },
                .UShr => {
                    try w.print("  if (g{d}) {{ unsigned sh = (unsigned)l{d} & 63u; l{d} = (int64_t)((uint64_t)l{d} >> sh); g{d} = 1; }} else {{ unsigned sh = (unsigned)l{d} & 31u; l{d} = (int64_t)(int32_t)((uint32_t)l{d} >> sh); g{d} = 0; }}\n", .{ lhs, rhs, dst, lhs, dst, rhs, dst, lhs, dst });
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

/// One scalar unary op of the replay, `applyUnop`'s exact semantics over
/// the modeled genres; anything else bails.
fn emitLeafUn(w: anytype, op: ir.UnOp, dst: u32, operand: u32) !void {
    switch (op) {
        .Plus => try w.print("  l{d} = l{d}; g{d} = g{d};\n", .{ dst, operand, dst, operand }),
        .Inc, .Dec => {
            const sym: []const u8 = if (op == .Inc) "+" else "-";
            try w.print("  switch (g{d}) {{\n", .{operand});
            try w.print("  case 0: l{d} = (int64_t)(int32_t)((uint32_t)l{d} {s} 1u); g{d} = 0; break;\n", .{ dst, operand, sym, dst });
            try w.print("  case 1: l{d} = (int64_t)((uint64_t)l{d} {s} 1u); g{d} = 1; break;\n", .{ dst, operand, sym, dst });
            try w.print("  case 4: l{d} = (int64_t)(uint16_t)((uint32_t)l{d} {s} 1u); g{d} = 4; break;\n", .{ dst, operand, sym, dst });
            try w.print("  case 5: l{d} = kl_d2bits(kl_bits2d(l{d}) {s} 1.0); g{d} = 5; break;\n", .{ dst, operand, sym, dst });
            try w.print("  case 6: l{d} = kl_f2bits(kl_bits2f(l{d}) {s} 1.0f); g{d} = 6; break;\n", .{ dst, operand, sym, dst });
            try w.print("  default: return 0;\n  }}\n", .{});
        },
        .Neg => {
            // Negating NaN keeps the canonical quiet NaN (the interpreter
            // pins Double.NaN's raw bits), not the IEEE sign flip.
            try w.print("  switch (g{d}) {{\n", .{operand});
            try w.print("  case 0: l{d} = (int64_t)(int32_t)(0u - (uint32_t)l{d}); g{d} = 0; break;\n", .{ dst, operand, dst });
            try w.print("  case 1: l{d} = (int64_t)(0u - (uint64_t)l{d}); g{d} = 1; break;\n", .{ dst, operand, dst });
            try w.print("  case 5: {{ double dv = kl_bits2d(l{d}); l{d} = kl_d2bits(dv != dv ? (double)NAN : -dv); g{d} = 5; break; }}\n", .{ operand, dst, dst });
            try w.print("  case 6: {{ float fv = kl_bits2f(l{d}); l{d} = kl_f2bits(fv != fv ? (float)NAN : -fv); g{d} = 6; break; }}\n", .{ operand, dst, dst });
            try w.print("  default: return 0;\n  }}\n", .{});
        },
    }
}

/// Emit the scalar-replay body `kl_<fid>` for an eligible function.
fn emitLeafFunc(w: anytype, m: *const ir.Module, f: *const ir.Func, fs: *const ir.bc.FuncStreams, consts: []const ir.Const) !void {
    const fid = f.id.int();
    var max_reg: u32 = 0;
    for (f.blocks, 0..) |*blk, bi| {
        if (blk.terminator == .Throw) continue;
        const st = fs.streams[bi] orelse continue;
        const code = st.code;
        var pc: usize = 0;
        while (pc < code.len) {
            const op: ir.bc.Op = @enumFromInt(code[pc]);
            switch (op) {
                .trace => pc += 4,
                .const_int, .const_load, .move, .load_param, .cell_get => {
                    if (code[pc + 1] > max_reg) max_reg = code[pc + 1];
                    if (op == .move and code[pc + 2] > max_reg) max_reg = code[pc + 2];
                    pc += 3;
                },
                .bin => {
                    if (code[pc + 3] > max_reg) max_reg = code[pc + 3];
                    if (code[pc + 4] > max_reg) max_reg = code[pc + 4];
                    if (code[pc + 5] > max_reg) max_reg = code[pc + 5];
                    pc += 6;
                },
                .escape => {
                    switch (f.blocks[bi].insts[code[pc + 1]]) {
                        .Call => |*c| {
                            if (c.dst.int() > max_reg) max_reg = c.dst.int();
                            if (c.args.int() + c.n_args > max_reg) max_reg = c.args.int() + c.n_args;
                        },
                        .UnOp => |*u| {
                            if (u.dst.int() > max_reg) max_reg = u.dst.int();
                            if (u.operand.int() > max_reg) max_reg = u.operand.int();
                        },
                        .NewInstance => |*ni| {
                            if (ni.dst.int() > max_reg) max_reg = ni.dst.int();
                            if (ni.args.int() + ni.n_args > max_reg) max_reg = ni.args.int() + ni.n_args;
                        },
                        .CallMemberOrGlobal => |*cg| {
                            if (cg.dst.int() > max_reg) max_reg = cg.dst.int();
                            if (cg.args.int() + cg.n_args > max_reg) max_reg = cg.args.int() + cg.n_args;
                        },
                        .CallVirtual => |*cv| {
                            if (cv.dst.int() > max_reg) max_reg = cv.dst.int();
                            if (cv.receiver.int() > max_reg) max_reg = cv.receiver.int();
                        },
                        else => {},
                    }
                    pc += 2;
                },
                .jump => pc += 2,
                .br => {
                    if (code[pc + 1] > max_reg) max_reg = code[pc + 1];
                    pc += 4;
                },
                .ret => pc += 3,
                .term_exit => pc += 1,
                .cmp_br => {
                    if (code[pc + 3] > max_reg) max_reg = code[pc + 3];
                    if (code[pc + 4] > max_reg) max_reg = code[pc + 4];
                    if (code[pc + 5] > max_reg) max_reg = code[pc + 5];
                    pc += 8;
                },
            }
        }
    }
    try w.print("static int32_t kl_{d}(void *ctx, klio_edge_view *ev, const int64_t *argv, const int32_t *argg, int64_t *ret, int32_t *retg, uint32_t depth, int64_t *aux, int32_t *auxg) {{\n", .{fid});
    try w.print("  if (depth > 2000u) return 0;\n", .{});
    var r: u32 = 0;
    while (r <= max_reg) : (r += 1) {
        try w.print("  int64_t l{d} = 0; int g{d} = 3; (void)l{d}; (void)g{d};\n", .{ r, r, r, r });
    }
    for (f.blocks, 0..) |*blk2, bi| {
        if (blk2.terminator == .Throw) {
            try w.print("KLB{d}:;\n  return 0;\n", .{bi});
            continue;
        }
        try w.print("KLB{d}:;\n", .{bi});
        const st = fs.streams[bi] orelse return error.Unexpected;
        const code = st.code;
        var pc: usize = 0;
        var closed = false;
        while (pc < code.len) {
            const op: ir.bc.Op = @enumFromInt(code[pc]);
            switch (op) {
                .trace => pc += 4,
                .const_int => {
                    try w.print("  l{d} = (int64_t)(int32_t)0x{x}u; g{d} = 0;\n", .{ code[pc + 1], code[pc + 2], code[pc + 1] });
                    pc += 3;
                },
                .const_load => {
                    const sc = leafConstScalar(consts, code[pc + 2]).?;
                    try w.print("  l{d} = (int64_t){d}ll; g{d} = {d};\n", .{ code[pc + 1], sc.v, code[pc + 1], sc.g });
                    pc += 3;
                },
                .move => {
                    try w.print("  l{d} = l{d}; g{d} = g{d};\n", .{ code[pc + 1], code[pc + 2], code[pc + 1], code[pc + 2] });
                    pc += 3;
                },
                .load_param => {
                    try w.print("  l{d} = argv[{d}]; g{d} = argg[{d}];\n", .{ code[pc + 1], code[pc + 2], code[pc + 1], code[pc + 2] });
                    pc += 3;
                },
                .cell_get => return error.Unexpected,
                .bin => {
                    try emitLeafBin(w, @enumFromInt(code[pc + 2]), code[pc + 3], code[pc + 4], code[pc + 5]);
                    pc += 6;
                },
                .escape => {
                    if (f.blocks[bi].insts[code[pc + 1]] == .UnOp) {
                        const u = &f.blocks[bi].insts[code[pc + 1]].UnOp;
                        try emitLeafUn(w, u.op, u.dst.int(), u.operand.int());
                        pc += 2;
                        continue;
                    }
                    const ctor_args: ?struct { base: u32, n: u32 } = switch (f.blocks[bi].insts[code[pc + 1]]) {
                        .NewInstance => |*ni| .{ .base = ni.args.int(), .n = ni.n_args },
                        .CallMemberOrGlobal => |*cg| .{ .base = cg.args.int(), .n = cg.n_args },
                        else => null,
                    };
                    if (ctor_args) |ca| {
                        // Ctor-tail (eligibility guaranteed `ret dst` follows):
                        // hand the scalar args + the owning site to the gate,
                        // which constructs once through the host.
                        var ai: u32 = 0;
                        while (ai < ca.n) : (ai += 1) {
                            try w.print("  aux[{d}] = l{d}; auxg[{d}] = g{d};\n", .{ ai, ca.base + ai, ai, ca.base + ai });
                        }
                        const site: u64 = (@as(u64, fid) << 32) | (@as(u64, @intCast(bi)) << 16) | @as(u64, code[pc + 1]);
                        try w.print("  *ret = (int64_t){d}ll; *retg = 200; return 1;\n", .{site});
                        pc += 2;
                        continue;
                    }
                    if (f.blocks[bi].insts[code[pc + 1]] == .CallVirtual) {
                        const cv = &f.blocks[bi].insts[code[pc + 1]].CallVirtual;
                        const conv = leafScalarConv(m, cv.slot).?;
                        const rr = cv.receiver.int();
                        const dd = cv.dst.int();
                        // Integer/char conversions only (floats bail at
                        // runtime by genre). Kotlin narrowing = low-bits
                        // truncation with sign extension; toChar keeps the
                        // low 16 bits unsigned.
                        try w.print("  if (g{d} > 4 || g{d} == 2 || g{d} == 3) return 0;\n", .{ rr, rr, rr });
                        switch (conv) {
                            .to_int => try w.print("  l{d} = (int64_t)(int32_t)l{d}; g{d} = 0;\n", .{ dd, rr, dd }),
                            .to_long => try w.print("  l{d} = l{d}; g{d} = 1;\n", .{ dd, rr, dd }),
                            .to_short => try w.print("  l{d} = (int64_t)(int16_t)l{d}; g{d} = 0;\n", .{ dd, rr, dd }),
                            .to_byte => try w.print("  l{d} = (int64_t)(int8_t)l{d}; g{d} = 0;\n", .{ dd, rr, dd }),
                            .to_char => try w.print("  l{d} = (int64_t)(uint16_t)l{d}; g{d} = 4;\n", .{ dd, rr, dd }),
                        }
                        pc += 2;
                        continue;
                    }
                    const c = &f.blocks[bi].insts[code[pc + 1]].Call;
                    const base = c.args.int();
                    try w.print("  {{ int64_t cav[{d}]; int32_t cag[{d}];\n", .{ @max(c.n_args, 1), @max(c.n_args, 1) });
                    var i: u32 = 0;
                    while (i < c.n_args) : (i += 1) {
                        try w.print("    cav[{d}] = l{d}; cag[{d}] = g{d};\n", .{ i, base + i, i, base + i });
                    }
                    try w.print("    int32_t rg2; int64_t rl2;\n", .{});
                    try w.print("    if (!kl_{d}(ctx, ev, cav, cag, &rl2, &rg2, depth + 1u, aux, auxg)) return 0;\n", .{c.func.int()});
                    try w.print("    l{d} = rl2; g{d} = rg2; }}\n", .{ c.dst.int(), c.dst.int() });
                    pc += 2;
                },
                .jump => {
                    try w.print("  if (kv_edge(ctx, ev)) return 0;\n  goto KLB{d};\n", .{code[pc + 1]});
                    closed = true;
                    pc += 2;
                },
                .br => {
                    try w.print("  if (g{d} != 2) return 0;\n", .{code[pc + 1]});
                    try w.print("  if (l{d}) goto KLB{d}; else goto KLB{d};\n", .{ code[pc + 1], code[pc + 2], code[pc + 3] });
                    closed = true;
                    pc += 4;
                },
                .ret => {
                    if (code[pc + 1] != 0) {
                        try w.print("  *ret = l{d}; *retg = g{d}; return 1;\n", .{ code[pc + 2], code[pc + 2] });
                    } else {
                        try w.print("  *ret = 0; *retg = 3; return 1;\n", .{});
                    }
                    closed = true;
                    pc += 3;
                },
                .term_exit => return error.Unexpected,
                .cmp_br => {
                    try emitLeafBin(w, @enumFromInt(code[pc + 2]), code[pc + 3], code[pc + 4], code[pc + 5]);
                    try w.print("  if (g{d} != 2) return 0;\n", .{code[pc + 3]});
                    try w.print("  if (l{d}) goto KLB{d}; else goto KLB{d};\n", .{ code[pc + 3], code[pc + 6], code[pc + 7] });
                    closed = true;
                    pc += 8;
                },
            }
        }
        if (!closed) try w.print("  return 0;\n", .{});
    }
    try w.print("}}\n\n", .{});
}

fn emitNativeFunc(w: anytype, f: *const ir.Func, fs: *const ir.bc.FuncStreams, consts: []const ir.Const) !void {
    try w.print("/* {s} (fid {d}) */\n", .{ f.fqn, f.id.int() });
    try w.print("static void kf_{d}(void *ctx, uint32_t entry) {{\n  uint8_t *const regs = klio_op_regs(ctx);\n  (void)regs;\n  uint8_t *const span_slot = KV.span_usable ? klio_op_span_slot(ctx) : 0;\n  (void)span_slot;\n  klio_edge_view EV;\n  klio_op_edge_view(ctx, &EV);\n  switch (entry) {{\n", .{f.id.int()});
    for (fs.streams, 0..) |sopt, bi| {
        if (sopt == null) continue;
        try w.print("  case {d}u: goto B{d};\n", .{ bi, bi });
    }
    // An uncompiled entry block: return with the outcome still `none`,
    // so the interpreter runs that block itself.
    try w.print("  default: return;\n  }}\n", .{});
    for (fs.streams, 0..) |sopt, bi| {
        const st = sopt orelse continue;
        try emitNativeBlock(w, f, st, @intCast(bi), fs, consts);
    }
    try w.print("}}\n\n", .{});
}

/// A taken edge lands on the target block's label when it was compiled,
/// and otherwise hands the block back to the interpreter (the same split
/// the stream loop makes on `streams[target] == null`).
fn emitEdgeTo(w: anytype, fs: *const ir.bc.FuncStreams, target: u32) !void {
    if (target < fs.streams.len and fs.streams[target] != null) {
        try w.print("goto B{d};", .{target});
    } else {
        try w.print("{{ klio_op_goto_exit(ctx, {d}u); return; }}", .{target});
    }
}


/// One straight-line region op a fused counted loop replays on C locals.
const FusedOp = union(enum) {
    trace: struct { file: u32, start: u32, end: u32 },
    const_int: struct { dst: u32, v: u32 },
    /// A const-table load resolved at emit time to a scalar: g encodes the
    /// width tag (0 int, 1 long, 2 bool, 3 unit) and v the payload bits.
    const_scalar: struct { dst: u32, g: u8, v: i64 },
    move: struct { dst: u32, src: u32 },
    bin: struct { kind: ir.BinOp, dst: u32, lhs: u32, rhs: u32 },
};

const FUSE_MAX_OPS = 48;
const FUSE_MAX_REGS = 96;

/// A recognized counted int loop over the BC streams:
///   H:    [trace*] cmp_br(LessEq|GreaterEq, hdst, I, B) ? BODY : EXIT
///   BODY: straight-line {trace, const_int, move, wrap-arith, compare} .. jump L1
///   L1:   [trace*] cmp_br(Eq, ldst, I, B) ? DONE : L2
///   L2:   [trace*] bin(Add, I, I, STEP) .. jump H
/// with B and STEP loop-invariant — exactly the lowerer's step-progression
/// shape (the Eq latch is the overflow-free last-element snap). The whole
/// region is re-emitted as one typed C loop over int64 locals with a
/// runtime width tag per register (Int arithmetic wraps at 32 bits, a Long
/// operand promotes — `applyBinop`'s exact fast-path semantics), entered
/// from the header label only when every live-in register carries an
/// Int/Long tag; anything else falls through to the per-op code unchanged.
/// Interpreter entries at the BODY/latch labels keep the generic per-op
/// path (their next header arrival re-engages the fused form).
const CountedLoop = struct {
    header: u32,
    exit: u32,
    done: u32,
    ind: u32,
    bound: u32,
    step: u32,
    hkind: ir.BinOp,
    hdst: u32,
    last: u32,
    ldst: u32,
    htrace: ?[3]u32,
    ltrace: ?[3]u32,
    ops: [FUSE_MAX_OPS]FusedOp,
    n_ops: usize,
    latch_ops: [8]FusedOp,
    n_latch: usize,
    regs: [FUSE_MAX_REGS]u32,
    n_regs: usize,
    reads: [FUSE_MAX_REGS]u32,
    n_reads: usize,
    writes: [FUSE_MAX_REGS]u32,
    n_writes: usize,
};

fn fuseNoteReg(cl: *CountedLoop, r: u32) bool {
    if (r >= FUSE_MAX_REGS) return false;
    for (cl.regs[0..cl.n_regs]) |x| {
        if (x == r) return true;
    }
    if (cl.n_regs >= cl.regs.len) return false;
    cl.regs[cl.n_regs] = r;
    cl.n_regs += 1;
    return true;
}

fn fuseNoteRead(cl: *CountedLoop, written: []bool, r: u32) bool {
    if (!fuseNoteReg(cl, r)) return false;
    if (!written[r]) {
        for (cl.reads[0..cl.n_reads]) |x| {
            if (x == r) return true;
        }
        if (cl.n_reads >= cl.reads.len) return false;
        cl.reads[cl.n_reads] = r;
        cl.n_reads += 1;
    }
    return true;
}

fn fuseNoteWrite(cl: *CountedLoop, written: []bool, r: u32) bool {
    if (!fuseNoteReg(cl, r)) return false;
    written[r] = true;
    for (cl.writes[0..cl.n_writes]) |x| {
        if (x == r) return true;
    }
    if (cl.n_writes >= cl.writes.len) return false;
    cl.writes[cl.n_writes] = r;
    cl.n_writes += 1;
    return true;
}

const FuseCmp = struct { kind: u32, dst: u32, lhs: u32, rhs: u32, t: u32, f: u32, trace: ?[3]u32 };

/// Parse a stream of shape [trace*] cmp_br; null on anything else.
fn fuseHeaderCmp(st: *const ir.bc.Stream) ?FuseCmp {
    const code = st.code;
    var pc: usize = 0;
    var trace: ?[3]u32 = null;
    while (pc < code.len) {
        const op: ir.bc.Op = @enumFromInt(code[pc]);
        switch (op) {
            .trace => {
                trace = .{ code[pc + 1], code[pc + 2], code[pc + 3] };
                pc += 4;
            },
            .cmp_br => {
                if (pc + 8 != code.len) return null;
                return .{ .kind = code[pc + 2], .dst = code[pc + 3], .lhs = code[pc + 4], .rhs = code[pc + 5], .t = code[pc + 6], .f = code[pc + 7], .trace = trace };
            },
            else => return null,
        }
    }
    return null;
}

/// Collect a straight-line block's fusible ops; the block must end in
/// `jump expected_next`.
fn fuseConstScalar(consts: []const ir.Const, id: u32) ?struct { g: u8, v: i64 } {
    if (id >= consts.len) return null;
    return switch (consts[id]) {
        .Int => |v| .{ .g = 0, .v = v },
        .Long => |v| .{ .g = 1, .v = v },
        .Bool => |v| .{ .g = 2, .v = @intFromBool(v) },
        .Unit => .{ .g = 3, .v = 0 },
        .Char => |v| .{ .g = 4, .v = v },
        else => null,
    };
}

fn fuseStraightBlock(cl: *CountedLoop, written: []bool, st: *const ir.bc.Stream, out: []FusedOp, n_out: *usize, expected_next: ?u32, out_target: *u32, consts: []const ir.Const) bool {
    const code = st.code;
    var pc: usize = 0;
    while (pc < code.len) {
        const op: ir.bc.Op = @enumFromInt(code[pc]);
        switch (op) {
            .trace => {
                if (n_out.* >= out.len) return false;
                out[n_out.*] = .{ .trace = .{ .file = code[pc + 1], .start = code[pc + 2], .end = code[pc + 3] } };
                n_out.* += 1;
                pc += 4;
            },
            .const_int => {
                if (n_out.* >= out.len) return false;
                if (!fuseNoteWrite(cl, written, code[pc + 1])) return false;
                out[n_out.*] = .{ .const_int = .{ .dst = code[pc + 1], .v = code[pc + 2] } };
                n_out.* += 1;
                pc += 3;
            },
            .const_load => {
                const sc = fuseConstScalar(consts, code[pc + 2]) orelse {
                    fuseTrace("  straight: const#{d} not scalar", .{code[pc + 2]});
                    return false;
                };
                if (n_out.* >= out.len) return false;
                if (!fuseNoteWrite(cl, written, code[pc + 1])) return false;
                out[n_out.*] = .{ .const_scalar = .{ .dst = code[pc + 1], .g = sc.g, .v = sc.v } };
                n_out.* += 1;
                pc += 3;
            },
            .move => {
                if (n_out.* >= out.len) return false;
                if (!fuseNoteRead(cl, written, code[pc + 2])) return false;
                if (!fuseNoteWrite(cl, written, code[pc + 1])) return false;
                out[n_out.*] = .{ .move = .{ .dst = code[pc + 1], .src = code[pc + 2] } };
                n_out.* += 1;
                pc += 3;
            },
            .bin => {
                const kind: ir.BinOp = @enumFromInt(code[pc + 2]);
                const hot = hotIntExpr(kind) orelse return false;
                if (hot.divmod) return false;
                if (n_out.* >= out.len) return false;
                if (!fuseNoteRead(cl, written, code[pc + 4])) return false;
                if (!fuseNoteRead(cl, written, code[pc + 5])) return false;
                if (!fuseNoteWrite(cl, written, code[pc + 3])) return false;
                out[n_out.*] = .{ .bin = .{ .kind = kind, .dst = code[pc + 3], .lhs = code[pc + 4], .rhs = code[pc + 5] } };
                n_out.* += 1;
                pc += 6;
            },
            .jump => {
                if (pc + 2 != code.len) {
                    fuseTrace("  straight: jump not at tail", .{});
                    return false;
                }
                if (expected_next) |want| {
                    if (code[pc + 1] != want) {
                        fuseTrace("  straight: jump to B{d} want B{d}", .{ code[pc + 1], want });
                        return false;
                    }
                }
                out_target.* = code[pc + 1];
                return true;
            },
            else => {
                fuseTrace("  straight: op {s} not fusible", .{@tagName(op)});
                return false;
            },
        }
    }
    return false;
}

/// Recognize the counted-loop region headed at `header`, or null.
fn fuseTrace(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("KLIO_FUSE_TRACE") != null) std.debug.print("[fuse] " ++ fmt ++ "\n", args);
}

fn recognizeCountedLoop(fs: *const ir.bc.FuncStreams, header: u32, consts: []const ir.Const) ?CountedLoop {
    var cl: CountedLoop = undefined;
    cl.n_ops = 0;
    cl.n_latch = 0;
    cl.n_regs = 0;
    cl.n_reads = 0;
    cl.n_writes = 0;
    var written = [_]bool{false} ** FUSE_MAX_REGS;

    const hstream = (if (header < fs.streams.len) fs.streams[header] else null) orelse return null;
    const h = fuseHeaderCmp(hstream) orelse return null;
    const hkind: ir.BinOp = @enumFromInt(h.kind);
    fuseTrace("B{d}: header cmp kind={s} I=r{d} B=r{d} dst=r{d} t=B{d} f=B{d}", .{ header, @tagName(hkind), h.lhs, h.rhs, h.dst, h.t, h.f });
    if (hkind != .LessEq and hkind != .GreaterEq) return null;
    if (h.lhs >= FUSE_MAX_REGS or h.rhs >= FUSE_MAX_REGS or h.dst >= FUSE_MAX_REGS) return null;
    cl.header = header;
    cl.exit = h.f;
    cl.ind = h.lhs;
    cl.bound = h.rhs;
    cl.hkind = hkind;
    cl.hdst = h.dst;
    cl.htrace = h.trace;
    if (!fuseNoteRead(&cl, &written, cl.ind)) { fuseTrace("B{d}: note ind", .{header}); return null; }
    if (!fuseNoteRead(&cl, &written, cl.bound)) { fuseTrace("B{d}: note bound", .{header}); return null; }
    if (!fuseNoteWrite(&cl, &written, cl.hdst)) { fuseTrace("B{d}: note hdst", .{header}); return null; }

    const body = h.t;
    const bstream = (if (body < fs.streams.len) fs.streams[body] else null) orelse {
        fuseTrace("B{d}: body B{d} has no stream", .{ header, h.t });
        return null;
    };
    var l1: u32 = 0;
    if (!fuseStraightBlock(&cl, &written, bstream, &cl.ops, &cl.n_ops, null, &l1, consts)) {
        fuseTrace("B{d}: body block B{d} not fusible", .{ header, body });
        return null;
    }

    const l1stream = (if (l1 < fs.streams.len) fs.streams[l1] else null) orelse { fuseTrace("B{d}: l1 B{d} no stream", .{ header, l1 }); return null; };
    const lc = fuseHeaderCmp(l1stream) orelse {
        fuseTrace("B{d}: latch B{d} not a cmp", .{ header, l1 });
        return null;
    };
    if (@as(ir.BinOp, @enumFromInt(lc.kind)) != .Eq) { fuseTrace("B{d}: latch kind not Eq", .{header}); return null; }
    // The Eq exit compares the induction register against the progression's
    // LAST element — for a stepped/downTo loop the lowerer snaps it into a
    // register distinct from the entry bound. Any loop-invariant register
    // is acceptable.
    if (lc.lhs != cl.ind) {
        fuseTrace("B{d}: latch operands mismatch", .{header});
        return null;
    }
    cl.last = lc.rhs;
    if (cl.last >= FUSE_MAX_REGS) { fuseTrace("B{d}: last reg big", .{header}); return null; }
    if (!fuseNoteRead(&cl, &written, cl.last)) { fuseTrace("B{d}: note last", .{header}); return null; }
    if (lc.dst >= FUSE_MAX_REGS) { fuseTrace("B{d}: ldst big", .{header}); return null; }
    cl.done = lc.t;
    cl.ldst = lc.dst;
    cl.ltrace = lc.trace;
    if (!fuseNoteWrite(&cl, &written, cl.ldst)) { fuseTrace("B{d}: note ldst", .{header}); return null; }

    // The increment block's back edge returns to the BODY (the rotated
    // loop's head), not to this entry-check block.
    const l2 = lc.f;
    const l2stream = (if (l2 < fs.streams.len) fs.streams[l2] else null) orelse { fuseTrace("B{d}: l2 B{d} no stream", .{ header, l2 }); return null; };
    var back: u32 = 0;
    if (!fuseStraightBlock(&cl, &written, l2stream, &cl.latch_ops, &cl.n_latch, body, &back, consts)) {
        fuseTrace("B{d}: incr block B{d} not fusible", .{ header, l2 });
        return null;
    }
    var incs: usize = 0;
    var step: u32 = 0;
    for (cl.latch_ops[0..cl.n_latch]) |op| {
        switch (op) {
            .bin => |b| {
                // Ascending loops increment; `downTo` decrements. Either
                // way the op replays generically — the validator only pins
                // the shape (exactly one in-place +/- on the induction reg).
                if (b.dst != cl.ind or b.lhs != cl.ind or (b.kind != .Add and b.kind != .Sub)) {
                    fuseTrace("latch op shape: dst=r{d} lhs=r{d} kind={s}", .{ b.dst, b.lhs, @tagName(b.kind) });
                    return null;
                }
                step = b.rhs;
                incs += 1;
            },
            .trace, .const_scalar, .const_int => {},
            else => return null,
        }
    }
    if (incs != 1) { fuseTrace("B{d}: incs={d}", .{ header, incs }); return null; }
    cl.step = step;
    if (written[cl.bound] or written[cl.last]) { fuseTrace("B{d}: bound/last written", .{header}); return null; }
    if (step != cl.ind and written[step]) { fuseTrace("B{d}: step written", .{header}); return null; }
    if (cl.exit >= fs.streams.len or fs.streams[cl.exit] == null) {
        fuseTrace("B{d}: exit B{d} uncompiled", .{ header, cl.exit });
        return null;
    }
    if (cl.done >= fs.streams.len or fs.streams[cl.done] == null) {
        fuseTrace("B{d}: done B{d} uncompiled", .{ header, cl.done });
        return null;
    }
    fuseTrace("B{d}: FUSED (body B{d}, exit B{d}, done B{d})", .{ header, body, cl.exit, cl.done });
    return cl;
}

fn fuseArithSym(kind: ir.BinOp) []const u8 {
    return switch (kind) {
        .Add => "+",
        .Sub => "-",
        .Mul => "*",
        else => unreachable,
    };
}

fn fuseCmpSym(kind: ir.BinOp) []const u8 {
    return switch (kind) {
        .Less => "<",
        .LessEq => "<=",
        .Greater => ">",
        .GreaterEq => ">=",
        .Eq, .BoxedEq => "==",
        .NotEq, .BoxedNotEq => "!=",
        else => unreachable,
    };
}

fn fuseLastTrace(cl: *const CountedLoop) ?[3]u32 {
    var last: ?[3]u32 = null;
    if (cl.htrace) |t| last = t;
    for (cl.ops[0..cl.n_ops]) |op| {
        if (op == .trace) last = .{ op.trace.file, op.trace.start, op.trace.end };
    }
    if (cl.ltrace) |t| last = t;
    for (cl.latch_ops[0..cl.n_latch]) |op| {
        if (op == .trace) last = .{ op.trace.file, op.trace.start, op.trace.end };
    }
    return last;
}

fn emitFuseSpill(w: anytype, cl: *const CountedLoop) !void {
    if (fuseLastTrace(cl)) |t| {
        try w.print("        if (span_slot) kv_trace(span_slot, {d}u, {d}u, {d}u);\n", .{ t[0], t[1], t[2] });
    }
    for (cl.writes[0..cl.n_writes]) |r| {
        try w.print("        if (g{d} == 4) kv_set_char(kv_slot(regs, {d}u), (uint16_t)l{d}); else if (g{d} == 3) kv_set_tag(kv_slot(regs, {d}u), KVC_TAG_UNIT); else if (g{d} == 2) kv_set_bool(kv_slot(regs, {d}u), (uint8_t)l{d}); else if (g{d} == 1) kv_set_long(kv_slot(regs, {d}u), l{d}); else kv_const_int(kv_slot(regs, {d}u), (int32_t)l{d});\n", .{ r, r, r, r, r, r, r, r, r, r, r, r, r });
    }
}

/// Prologue tag propagation for one region op: updates the register width
/// tags and, for an arithmetic op, freezes its promoted-ness flag `f<idx>`.
/// Run twice before the loop, the tag state reaches its fixpoint (promotion
/// is driven by the deterministic op sequence); a third round that changes
/// any flag falls back to the generic path.
fn emitTagPropOp(w: anytype, op: FusedOp, idx: usize, round: u32) !void {
    switch (op) {
        .trace => {},
        .const_int => |c| try w.print("      g{d} = 0;\n", .{c.dst}),
        .const_scalar => |c| try w.print("      g{d} = {d};\n", .{ c.dst, c.g }),
        .move => |m| try w.print("      g{d} = g{d};\n", .{ m.dst, m.src }),
        .bin => |b| {
            const hot = hotIntExpr(b.kind).?;
            if (hot.is_bool) {
                try w.print("      g{d} = 2;\n", .{b.dst});
            } else if (round == 0) {
                // Char operands: Char-Char is Int, Char+/-Int stays Char;
                // either way the compute width is 32-bit (f = 0). The
                // legal-Kotlin combinations are the only reachable ones.
                try w.print("      if (g{d} == 4 || g{d} == 4) {{ f{d} = 0; g{d} = (g{d} == 4 && g{d} == 4) ? 0 : 4; }} else {{ f{d} = (g{d} | g{d}) & 1; g{d} = f{d}; }}\n", .{ b.lhs, b.rhs, idx, b.dst, b.lhs, b.rhs, idx, b.lhs, b.rhs, b.dst, idx });
            } else {
                try w.print("      {{ int nf; int ng; if (g{d} == 4 || g{d} == 4) {{ nf = 0; ng = (g{d} == 4 && g{d} == 4) ? 0 : 4; }} else {{ nf = (g{d} | g{d}) & 1; ng = nf; }} if (nf != f{d}) fok = 0; f{d} = nf; g{d} = ng; }}\n", .{ b.lhs, b.rhs, b.lhs, b.rhs, b.lhs, b.rhs, idx, idx, b.dst });
            }
        },
    }
}

/// In-loop emission: width decisions read the FROZEN per-op flags, so the
/// loop body carries no data-dependent tag writes and the C compiler can
/// unswitch it into typed variants.
fn emitFusedOp(w: anytype, op: FusedOp, idx: usize) !void {
    switch (op) {
        // Per-iteration span updates are unobservable inside a fused region
        // (no op in it can throw — divmod is excluded); the region's LAST
        // trace is written once at every exit instead.
        .trace => {},
        .const_int => |c| try w.print("        l{d} = (int32_t)0x{x}u;\n", .{ c.dst, c.v }),
        .const_scalar => |c| try w.print("        l{d} = (int64_t){d}ll;\n", .{ c.dst, c.v }),
        .move => |m| try w.print("        l{d} = l{d};\n", .{ m.dst, m.src }),
        .bin => |b| {
            const hot = hotIntExpr(b.kind).?;
            if (hot.is_bool) {
                if (b.kind == .BoxedEq or b.kind == .BoxedNotEq) {
                    const neg: []const u8 = if (b.kind == .BoxedNotEq) "!" else "";
                    try w.print("        l{d} = {s}(g{d} == g{d} && l{d} == l{d});\n", .{ b.dst, neg, b.lhs, b.rhs, b.lhs, b.rhs });
                } else {
                    try w.print("        l{d} = (l{d} {s} l{d});\n", .{ b.dst, b.lhs, fuseCmpSym(b.kind), b.rhs });
                }
            } else {
                try w.print("        if (f{d}) l{d} = (int64_t)((uint64_t)l{d} {s} (uint64_t)l{d}); else l{d} = (int32_t)((uint32_t)l{d} {s} (uint32_t)l{d});\n", .{ idx, b.dst, b.lhs, fuseArithSym(b.kind), b.rhs, b.dst, b.lhs, fuseArithSym(b.kind), b.rhs });
            }
        },
    }
}

/// Emit the typed replay of a recognized counted loop at its header label,
/// ahead of the generic per-op code (which stays as the fallthrough for
/// non-scalar entry tags and for interpreter entries at the inner labels).
fn emitFusedCountedLoop(w: anytype, cl: *const CountedLoop) !void {
    try w.print("  /* fused counted loop over blocks B{d}.. (typed int64 replay) */\n", .{cl.header});
    try w.print("  if (KV.usable) {{\n    int fok = 1;\n", .{});
    for (cl.regs[0..cl.n_regs]) |r| {
        try w.print("    int64_t l{d} = 0; int g{d} = 0; (void)l{d}; (void)g{d};\n", .{ r, r, r, r });
    }
    for (cl.reads[0..cl.n_reads]) |r| {
        try w.print("    {{ const uint8_t *s = kv_slot(regs, {d}u); uint64_t t = kv_tag(s); if (t == KVC_TAG_INT) {{ l{d} = kv_int(s); g{d} = 0; }} else if (t == KVC_TAG_LONG) {{ l{d} = kv_long(s); g{d} = 1; }} else if (t == KVC_TAG_CHAR) {{ l{d} = (int64_t)kv_char(s); g{d} = 4; }} else fok = 0; }}\n", .{ r, r, r, r, r, r, r });
    }
    // Per-arith-op frozen width flags, settled by two propagation rounds
    // (fixpoint) and a verify round; a tag pattern that has not converged
    // clears fok and the generic path serves.
    {
        var idx: usize = 0;
        for (cl.ops[0..cl.n_ops]) |op| {
            if (op == .bin and !hotIntExpr(op.bin.kind).?.is_bool)
                try w.print("    int f{d} = 0;\n", .{idx});
            idx += 1;
        }
        var lidx: usize = 100;
        for (cl.latch_ops[0..cl.n_latch]) |op| {
            if (op == .bin and !hotIntExpr(op.bin.kind).?.is_bool)
                try w.print("    int f{d} = 0;\n", .{lidx});
            lidx += 1;
        }
    }
    try w.print("    if (fok) {{\n", .{});
    inline for (.{ @as(u32, 0), @as(u32, 1), @as(u32, 2) }) |round| {
        var idx2: usize = 0;
        for (cl.ops[0..cl.n_ops]) |op| {
            try emitTagPropOp(w, op, idx2, round);
            idx2 += 1;
        }
        try w.print("      g{d} = 2;\n", .{cl.ldst});
        var lidx2: usize = 100;
        for (cl.latch_ops[0..cl.n_latch]) |op| {
            try emitTagPropOp(w, op, lidx2, round);
            lidx2 += 1;
        }
    }
    try w.print("      g{d} = 2;\n    }}\n", .{cl.hdst});
    try w.print("    if (fok) {{\n      uint32_t kfl = 0;\n", .{});
    try w.print("      l{d} = (l{d} {s} l{d});\n", .{ cl.hdst, cl.ind, fuseCmpSym(cl.hkind), cl.bound });
    try w.print("      if (!l{d}) {{\n", .{cl.hdst});
    try emitFuseSpill(w, cl);
    try w.print("        goto B{d};\n      }}\n", .{cl.exit});
    try w.print("      for (;;) {{\n", .{});
    {
        var idx3: usize = 0;
        for (cl.ops[0..cl.n_ops]) |op| {
            try emitFusedOp(w, op, idx3);
            idx3 += 1;
        }
    }
    try w.print("        l{d} = (l{d} == l{d});\n", .{ cl.ldst, cl.ind, cl.last });
    try w.print("        if (l{d}) {{\n", .{cl.ldst});
    try emitFuseSpill(w, cl);
    try w.print("        goto B{d};\n        }}\n", .{cl.done});
    {
        var lidx3: usize = 100;
        for (cl.latch_ops[0..cl.n_latch]) |op| {
            try emitFusedOp(w, op, lidx3);
            lidx3 += 1;
        }
    }
    // Periodic edge guard: keep the interpreter cadence (two per-jump
    // increments per iteration) by bumping the shared counter in bulk,
    // spilling first so an abort/GC observes a consistent register file.
    try w.print("        kfl += 1;\n        if ((kfl & 0xFFu) == 0) {{\n", .{});
    try emitFuseSpill(w, cl);
    try w.print("        *EV.counter += 511u;\n        if (kv_edge(ctx, &EV)) return;\n        }}\n", .{});
    try w.print("      }}\n    }}\n  }}\n", .{});
}

fn emitNativeBlock(w: anytype, f: *const ir.Func, st: *const ir.bc.Stream, block: u32, fs: *const ir.bc.FuncStreams, consts: []const ir.Const) !void {
    try w.print("B{d}:\n", .{block});
    if (recognizeCountedLoop(fs, block, consts)) |cl| try emitFusedCountedLoop(w, &cl);
    const code = st.code;
    var pc: usize = 0;
    var closed = false;
    while (pc < code.len) {
        const op: ir.bc.Op = @enumFromInt(code[pc]);
        switch (op) {
            .const_load => {
                try w.print("  if (klio_op_const_load(ctx, {d}u, {d}u)) return;\n", .{ code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .const_int => {
                try w.print("  if (KV.usable) kv_const_int(kv_slot(regs, {d}u), (int32_t)0x{x}u); else klio_op_const_int(ctx, {d}u, (int32_t)0x{x}u);\n", .{ code[pc + 1], code[pc + 2], code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .move => {
                try w.print("  if (KV.usable) memcpy(kv_slot(regs, {d}u), kv_slot(regs, {d}u), KVC_VALUE_SIZE); else klio_op_move(ctx, {d}u, {d}u);\n", .{ code[pc + 1], code[pc + 2], code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .load_param => {
                try w.print("  klio_op_load_param(ctx, {d}u, {d}u);\n", .{ code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .cell_get => {
                try w.print("  klio_op_cell_get(ctx, {d}u, {d}u);\n", .{ code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .trace => {
                try w.print("  if (span_slot) kv_trace(span_slot, {d}u, {d}u, {d}u); else klio_op_trace(ctx, {d}u, {d}u, {d}u);\n", .{ code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .bin => {
                try emitBinSite(w, block, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5]);
                pc += 6;
            },
            .escape => {
                // A statically-bound call quickens to the call op: the
                // native caller stays on the C stack and the callee's own
                // emitted body engages inside the recursive activation.
                const inst_idx = code[pc + 1];
                // A plain stored FIELD read runs inline behind a class guard:
                // the site caches the (class, slot) route the runtime
                // resolves on its first execution, and anything the guard
                // does not cover falls through to the escape, which carries
                // the full semantics.
                if (f.blocks[block].insts[inst_idx] == .GetField) {
                    const gf = f.blocks[block].insts[inst_idx].GetField;
                    try w.print(
                        "  {{ static uint64_t gfr_{d}_{d} = 0;\n" ++
                            "    if (!kv_getfield(ctx, regs, {d}u, {d}u, {d}u, {d}u, &gfr_{d}_{d}))\n" ++
                            "      if (klio_op_escape(ctx, {d}u, {d}u)) return; }}\n",
                        .{
                            block,        inst_idx,
                            block,        inst_idx, gf.dst.int(), gf.receiver.int(),
                            block,        inst_idx,
                            block,        inst_idx,
                        },
                    );
                    pc += 2;
                    continue;
                }
                if (f.blocks[block].insts[inst_idx] == .SetField) {
                    const sf = f.blocks[block].insts[inst_idx].SetField;
                    try w.print(
                        "  {{ static uint64_t sfr_{d}_{d} = 0;\n" ++
                            "    if (!kv_setfield(ctx, regs, {d}u, {d}u, {d}u, {d}u, &sfr_{d}_{d}))\n" ++
                            "      if (klio_op_escape(ctx, {d}u, {d}u)) return; }}\n",
                        .{
                            block,        inst_idx,
                            block,        inst_idx, sf.receiver.int(), sf.value.int(),
                            block,        inst_idx,
                            block,        inst_idx,
                        },
                    );
                    pc += 2;
                    continue;
                }
                if (f.blocks[block].insts[inst_idx] == .IndexSet) {
                    const ixs = f.blocks[block].insts[inst_idx].IndexSet;
                    try w.print(
                        "  if (!kv_index_set_int(regs, {d}u, {d}u, {d}u))\n" ++
                            "    if (klio_op_escape(ctx, {d}u, {d}u)) return;\n",
                        .{ ixs.receiver.int(), ixs.index.int(), ixs.value.int(), block, inst_idx },
                    );
                    pc += 2;
                    continue;
                }
                if (f.blocks[block].insts[inst_idx] == .Index) {
                    const ix = f.blocks[block].insts[inst_idx].Index;
                    try w.print(
                        "  if (!kv_index_int(regs, {d}u, {d}u, {d}u))\n" ++
                            "    if (klio_op_escape(ctx, {d}u, {d}u)) return;\n",
                        .{ ix.dst.int(), ix.receiver.int(), ix.index.int(), block, inst_idx },
                    );
                    pc += 2;
                    continue;
                }
                const op_name = switch (f.blocks[block].insts[inst_idx]) {
                    .Call => "klio_op_call",
                    else => "klio_op_escape",
                };
                try w.print("  if ({s}(ctx, {d}u, {d}u)) return;\n", .{ op_name, block, inst_idx });
                pc += 2;
            },
            .jump => {
                try w.print("  if (kv_edge(ctx, &EV)) return;\n  ", .{});
                try emitEdgeTo(w, fs, code[pc + 1]);
                try w.print("\n", .{});
                closed = true;
                pc += 2;
            },
            .br => {
                try w.print("  switch (klio_op_br(ctx, {d}u, {d}u)) {{\n  case 1: ", .{ block, code[pc + 1] });
                try emitEdgeTo(w, fs, code[pc + 2]);
                try w.print("\n  case 0: ", .{});
                try emitEdgeTo(w, fs, code[pc + 3]);
                try w.print("\n  default: return;\n  }}\n", .{});
                closed = true;
                pc += 4;
            },
            .ret => {
                try w.print("  klio_op_ret(ctx, {d}u, {d}u);\n  return;\n", .{ code[pc + 1], code[pc + 2] });
                closed = true;
                pc += 3;
            },
            .term_exit => {
                try w.print("  klio_op_term(ctx, {d}u);\n  return;\n", .{block});
                closed = true;
                pc += 1;
            },
            .cmp_br => {
                try emitCmpBrSite(w, fs, block, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7]);
                closed = true;
                pc += 8;
            },
        }
    }
    // A stream without fused terminators falls off its end: the real
    // terminator runs in the interpreter, same as the stream loop.
    if (!closed) try w.print("  klio_op_term(ctx, {d}u);\n  return;\n", .{block});
}

/// The C expression computing an Int/Int fast-path BinOp with
/// `applyBinop`'s exact semantics (wrap arithmetic via unsigned, C99
/// truncating div/mod), or null when the kind must stay on the helper.
/// Div/Mod also need the runtime guard `divmod_ok` (zero divisor and the
/// INT_MIN/-1 overflow both fall back to the interpreter arm).
fn hotIntExpr(kind: ir.BinOp) ?struct { expr: []const u8, is_bool: bool, divmod: bool } {
    return switch (kind) {
        .Add => .{ .expr = "(int32_t)((uint32_t)a + (uint32_t)b)", .is_bool = false, .divmod = false },
        .Sub => .{ .expr = "(int32_t)((uint32_t)a - (uint32_t)b)", .is_bool = false, .divmod = false },
        .Mul => .{ .expr = "(int32_t)((uint32_t)a * (uint32_t)b)", .is_bool = false, .divmod = false },
        .Div => .{ .expr = "a / b", .is_bool = false, .divmod = true },
        .Mod => .{ .expr = "a % b", .is_bool = false, .divmod = true },
        .Less => .{ .expr = "a < b", .is_bool = true, .divmod = false },
        .LessEq => .{ .expr = "a <= b", .is_bool = true, .divmod = false },
        .Greater => .{ .expr = "a > b", .is_bool = true, .divmod = false },
        .GreaterEq => .{ .expr = "a >= b", .is_bool = true, .divmod = false },
        .Eq, .BoxedEq => .{ .expr = "a == b", .is_bool = true, .divmod = false },
        .NotEq, .BoxedNotEq => .{ .expr = "a != b", .is_bool = true, .divmod = false },
        else => null,
    };
}

fn emitBinSite(w: anytype, block: u32, inst_idx: u32, kind_raw: u32, dst: u32, lhs: u32, rhs: u32) !void {
    const kind: ir.BinOp = @enumFromInt(kind_raw);
    const hot = hotIntExpr(kind) orelse {
        try w.print("  if (klio_op_bin(ctx, {d}u, {d}u, {d}u, {d}u, {d}u, {d}u)) return;\n", .{ block, inst_idx, kind_raw, dst, lhs, rhs });
        return;
    };
    // Mixed Int/Long promotes to Long exactly as `applyBinop` does —
    // EXCEPT boxed equality, which is tag-sensitive across widths and
    // only inlines Long/Long.
    const boxed_eq = kind == .BoxedEq or kind == .BoxedNotEq;
    try w.print("  {{ int kh = 0;\n", .{});
    try w.print("    uint8_t *bl = kv_slot(regs, {d}u), *br_ = kv_slot(regs, {d}u);\n", .{ lhs, rhs });
    try w.print("    if (KV.usable) {{\n      uint64_t tl = kv_tag(bl), tr = kv_tag(br_);\n", .{});
    try w.print("      if (tl == KVC_TAG_INT && tr == KVC_TAG_INT) {{\n", .{});
    try w.print("        int32_t a = kv_int(bl), b = kv_int(br_); (void)a; (void)b;\n", .{});
    if (hot.divmod) {
        try w.print("        if (b != 0 && !(a == INT32_MIN && b == -1)) {{ kv_const_int(kv_slot(regs, {d}u), {s}); kh = 1; }}\n", .{ dst, hot.expr });
    } else if (hot.is_bool) {
        try w.print("        kv_set_bool(kv_slot(regs, {d}u), (uint8_t)({s})); kh = 1;\n", .{ dst, hot.expr });
    } else {
        try w.print("        kv_const_int(kv_slot(regs, {d}u), {s}); kh = 1;\n", .{ dst, hot.expr });
    }
    if (boxed_eq) {
        try w.print("      }} else if (tl == KVC_TAG_LONG && tr == KVC_TAG_LONG) {{\n", .{});
    } else {
        try w.print("      }} else if ((tl == KVC_TAG_INT || tl == KVC_TAG_LONG) && (tr == KVC_TAG_INT || tr == KVC_TAG_LONG)) {{\n", .{});
    }
    try w.print("        int64_t a = (tl == KVC_TAG_INT) ? (int64_t)kv_int(bl) : kv_long(bl);\n", .{});
    try w.print("        int64_t b = (tr == KVC_TAG_INT) ? (int64_t)kv_int(br_) : kv_long(br_); (void)a; (void)b;\n", .{});
    const lexpr = hotLongExpr(kind);
    if (hot.divmod) {
        try w.print("        if (b != 0 && !(a == INT64_MIN && b == -1)) {{ kv_set_long(kv_slot(regs, {d}u), {s}); kh = 1; }}\n", .{ dst, lexpr });
    } else if (hot.is_bool) {
        try w.print("        kv_set_bool(kv_slot(regs, {d}u), (uint8_t)({s})); kh = 1;\n", .{ dst, lexpr });
    } else {
        try w.print("        kv_set_long(kv_slot(regs, {d}u), {s}); kh = 1;\n", .{ dst, lexpr });
    }
    try w.print("      }}\n    }}\n", .{});
    try w.print("    if (!kh && klio_op_bin(ctx, {d}u, {d}u, {d}u, {d}u, {d}u, {d}u)) return;\n", .{ block, inst_idx, kind_raw, dst, lhs, rhs });
    try w.print("  }}\n", .{});
}

/// The 64-bit form of `hotIntExpr`'s expressions (wrap via uint64_t).
fn hotLongExpr(kind: ir.BinOp) []const u8 {
    return switch (kind) {
        .Add => "(int64_t)((uint64_t)a + (uint64_t)b)",
        .Sub => "(int64_t)((uint64_t)a - (uint64_t)b)",
        .Mul => "(int64_t)((uint64_t)a * (uint64_t)b)",
        .Div => "a / b",
        .Mod => "a % b",
        .Less => "a < b",
        .LessEq => "a <= b",
        .Greater => "a > b",
        .GreaterEq => "a >= b",
        .Eq, .BoxedEq => "a == b",
        .NotEq, .BoxedNotEq => "a != b",
        else => unreachable,
    };
}

fn emitCmpBrSite(w: anytype, fs: *const ir.bc.FuncStreams, block: u32, inst_idx: u32, kind_raw: u32, dst: u32, lhs: u32, rhs: u32, t_block: u32, f_block: u32) !void {
    const kind: ir.BinOp = @enumFromInt(kind_raw);
    const hot = hotIntExpr(kind);
    if (hot != null and hot.?.is_bool) {
        // Inline compare, write dst (register state matches the unfused
        // form), run the taken-edge guard, branch. Mixed Int/Long
        // promotes exactly as the interpreter's fast arm does (boxed
        // equality stays Long/Long only); anything else falls to the
        // helper switch below.
        const boxed_eq = kind == .BoxedEq or kind == .BoxedNotEq;
        try w.print("  {{\n    uint8_t *bl = kv_slot(regs, {d}u), *br_ = kv_slot(regs, {d}u);\n", .{ lhs, rhs });
        try w.print("    if (KV.usable) {{\n      uint64_t tl = kv_tag(bl), tr = kv_tag(br_);\n", .{});
        if (boxed_eq) {
            try w.print("      int have = (tl == KVC_TAG_INT && tr == KVC_TAG_INT) || (tl == KVC_TAG_LONG && tr == KVC_TAG_LONG);\n", .{});
        } else {
            try w.print("      int have = (tl == KVC_TAG_INT || tl == KVC_TAG_LONG) && (tr == KVC_TAG_INT || tr == KVC_TAG_LONG);\n", .{});
        }
        try w.print("      if (have) {{\n", .{});
        try w.print("        int64_t a = (tl == KVC_TAG_INT) ? (int64_t)kv_int(bl) : kv_long(bl);\n", .{});
        try w.print("        int64_t b = (tr == KVC_TAG_INT) ? (int64_t)kv_int(br_) : kv_long(br_);\n", .{});
        try w.print("        int t = ({s});\n", .{hotLongExpr(kind)});
        try w.print("        kv_set_bool(kv_slot(regs, {d}u), (uint8_t)t);\n", .{dst});
        try w.print("        if (kv_edge(ctx, &EV)) return;\n", .{});
        try w.print("        if (t) ", .{});
        try emitEdgeTo(w, fs, t_block);
        try w.print("\n        else ", .{});
        try emitEdgeTo(w, fs, f_block);
        try w.print("\n      }}\n    }}\n  }}\n", .{});
    }
    try w.print("  switch (klio_op_cmp_br(ctx, {d}u, {d}u, {d}u, {d}u, {d}u, {d}u)) {{\n  case 1: ", .{ block, inst_idx, kind_raw, dst, lhs, rhs });
    try emitEdgeTo(w, fs, t_block);
    try w.print("\n  case 0: ", .{});
    try emitEdgeTo(w, fs, f_block);
    try w.print("\n  default: return;\n  }}\n", .{});
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
    // KLIO_PROF profiles `klio test` exactly as it does `klio run` (the
    // sampler is per-thread; this worker thread executes the tests).
    runtime.prof.maybeStart();
    defer runtime.prof.maybeReport();
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
        // Still print the summary line: a file whose only `@Test` methods
        // live on an ABSTRACT class contributes no cases but DID run, and a
        // harness that reads the summary must not score it as a child that
        // never reported.
        io.printStdout(gpa, "no tests found\n\n0 tests, 0 passed, 0 failed, 0 skipped\n", .{});
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
    runtime.prof.fnProfMaybeStart();
    ir.eval.frameCountInit();
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
        io.printStdout(gpa, "no tests found\n\n0 tests, 0 passed, 0 failed, 0 skipped\n", .{});
        return 0;
    }
    io.printStdout(gpa, "\n{d} tests, {d} passed, {d} failed, {d} skipped\n", .{
        report.results.len, report.passed, report.failed, report.skipped,
    });
    if (runtime.envOnce("KLIO_PUMP_DIAG") != null) interp_ir.coroutines_diag.dumpSleepCounts();
    {
        const mg = built.module.borrow();
        defer mg.deinit();
        ir.eval.fnProfDump(mg.get());
        ir.eval.frameCountDump(mg.get());
    }
    ir.eval.callStatsDump();
    ir.eval.dispatch_replay_hits = &interp_ir.VmHost.replayHits;
    ir.eval.ext_fb_counts = &interp_ir.VmHost.extFbCounts;
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
    if (audit) {
        var ndecl: usize = 0;
        for (combined) |*kf| ndecl += kf.decls.len;
        std.debug.print("[EAGER] {d} files / {d} top-level decls handed to the checker\n", .{ combined.len, ndecl });
    }
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
    // Picks whose declaration lives in a prebuilt image: no source span
    // exists for them anywhere, so they travel by FuncId instead.
    var out_fids = std.AutoHashMap(span_mod.Span, u32).init(gpa);
    var it = tc.resolved_calls.iterator();
    var n: usize = 0;
    var n_fid: usize = 0;
    var seen_total: usize = 0;
    var no_decl_span: usize = 0;
    var not_declared: usize = 0;
    while (it.next()) |e| {
        seen_total += 1;
        const decl = e.value_ptr.decl_span orelse {
            if (e.value_ptr.extern_fid) |fid| {
                out_fids.put(e.key_ptr.*, fid) catch {};
                n_fid += 1;
            } else no_decl_span += 1;
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
    if (audit) std.debug.print("[EAGER] {d} call resolutions recorded ({d} by image FuncId; typeck resolved {d}; {d} carried no decl span, {d} named a decl outside the checked sources)\n", .{ n, n_fid, seen_total, no_decl_span, not_declared });
    if (out_fids.count() != 0) {
        if (ir.pending_eager_call_fids) |*old_m| old_m.deinit();
        ir.pending_eager_call_fids = out_fids;
    } else out_fids.deinit();
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
    // The checker's CLASS evidence, folded into the same channel: a plain
    // user class is `Type.Unresolved` there, so `tc.types` cannot carry it,
    // and `expr_class` is where a receiver's class identity lives. Heads the
    // lowering module cannot resolve are dropped on READ (`eagerTypeOf`), so
    // an unresolvable name costs nothing rather than displacing a virtual
    // bind.
    var cn_added: usize = 0;
    {
        var cit = tc.expr_class.iterator();
        while (cit.next()) |e| {
            if (tout.contains(e.key_ptr.*)) continue;
            tout.put(e.key_ptr.*, .{ .name = e.value_ptr.*, .nullable = false }) catch continue;
            cn_added += 1;
        }
    }
    if (audit) std.debug.print("[EAGER] {d} type heads recorded ({d} excluded as instantiation-dependent, {d} from class evidence)\n", .{ tn + cn_added, tc.types_instantiation_dependent.count(), cn_added });
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
    {
        const mg = built.module.borrow();
        defer mg.deinit();
        ir.eval.fnProfDump(mg.get());
        ir.eval.frameCountDump(mg.get());
    }
    ir.eval.callStatsDump();
    ir.eval.dispatch_replay_hits = &interp_ir.VmHost.replayHits;
    ir.eval.ext_fb_counts = &interp_ir.VmHost.extFbCounts;
    ir.eval.dispatchStatsDump();
    // `KLIO_OP_PROF` starts for `run` too, but only `test` dumped it; the
    // per-opcode histogram belongs to both exits.
    ir.eval.opProfDump();
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
    var member_ext_aligned: usize = 0;
    var member_decl_aligned: usize = 0;
    var pkg_unloaded: usize = 0;
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
            // A member-shaped registry key is usually a DISPATCH key for an
            // EXTENSION the module does declare (`kotlin.Char.titlecase`
            // serves `kotlin.text.titlecase(Char)`): resolution reaches it
            // through the extension declaration, so it is ALIGNED, not
            // missing. A key with no extension of that simple name whose
            // declared receiver head names the owner (or a builtin the
            // owner satisfies) is a genuine member hole.
            {
                const simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
                const owner_cid: ?ir.ClassId = module.classIdByFqn(pkg) orelse
                    module.uniqueClassIdBySimpleName(owner_simple);
                var ext_aligned = false;
                for (module.funcsBySimpleName(simple)) |fid2| {
                    const f2 = module.funcById(fid2) orelse continue;
                    if (f2.params.len == 0 or !std.mem.eql(u8, f2.params[0].name, "this")) continue;
                    var rh = f2.params[0].ty.name;
                    if (std.mem.lastIndexOfScalar(u8, rh, '.')) |rd| rh = rh[rd + 1 ..];
                    rh = std.mem.trimEnd(u8, rh, "?");
                    if (std.mem.indexOfScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
                    if (std.mem.eql(u8, rh, owner_simple)) {
                        ext_aligned = true;
                        break;
                    }
                    // A one-or-two-letter receiver is a TYPE PARAMETER —
                    // a generic extension (`fun <T> T.also`) serves any
                    // owner-qualified key of its name.
                    if (rh.len != 0 and rh.len <= 2 and std.ascii.isUpper(rh[0])) {
                        ext_aligned = true;
                        break;
                    }
                    // An extension on a SUPERTYPE serves the subtype's key:
                    // `Iterable.indexOfFirst` answers the
                    // `MutableList.indexOfFirst` dispatch key.
                    if (owner_cid) |ocid| {
                        if (module.uniqueClassIdBySimpleName(rh)) |rcid| {
                            if (module.classIdIsOrExtends(ocid, rcid)) {
                                ext_aligned = true;
                                break;
                            }
                        }
                    }
                }
                if (ext_aligned) {
                    // The callable IS declared — as the extension the key
                    // dispatches for — so it does not count as missing.
                    member_ext_aligned += 1;
                    missing -= 1;
                    continue;
                }
                // A MEMBER the owner class (or a supertype it inherits
                // from) declares: `List.isEmpty` lives on the Collection
                // header. Arity-blind on purpose — an empty-shape
                // resolution probe refuses members with required
                // parameters (`MutableList.add`).
                if (owner_cid) |ocid| {
                    if (module.classHierarchyDeclaresMember(ocid, simple)) {
                        member_decl_aligned += 1;
                        missing -= 1;
                        continue;
                    }
                }
            }
            member_missing += 1;
            // `KLIO_DECL_AUDIT=members` lists them: the builtin-type members
            // are the last declaration hole, and grouping them by owner is
            // what sizes the work per type. The owner's class-row state is
            // printed with each row — a hole whose owner has NO row (or an
            // empty method list) is audit blindness, not a resolution gap.
            if (std.mem.eql(u8, runtime.envOnce("KLIO_DECL_AUDIT") orelse "", "members")) {
                const simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
                const owner_cid2: ?ir.ClassId = module.classIdByFqn(pkg) orelse
                    module.uniqueClassIdBySimpleName(owner_simple);
                _ = simple;
                if (owner_cid2) |oc| {
                    const nm = if (oc.int() < module.classes.items.len) module.classes.items[oc.int()].methods.len else 0;
                    io.printStdout(gpa, "[decl-audit] member: {s} (owner row, {d} methods)\n", .{ fqn, nm });
                } else {
                    io.printStdout(gpa, "[decl-audit] member: {s} (no owner row)\n", .{fqn});
                }
            }
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
        // A hole in a package with NO loaded declaration at all is the
        // audit's own program-scoping, not a symbol-table gap: the IR is
        // lazy, and `klio.bundle.__klio_bundle_readBytes` HAS a source
        // declaration a bundle-using program loads. Only a hole in a
        // LOADED package is actionable.
        {
            var pkg_loaded = false;
            for (module.funcs.items) |*mf| {
                if (std.mem.eql(u8, mf.package, pkg)) {
                    pkg_loaded = true;
                    break;
                }
            }
            if (!pkg_loaded) {
                pkg_unloaded += 1;
                continue;
            }
        }
        toplevel_missing += 1;
        const gop = by_pkg.getOrPut(pkg) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (samples.items.len < 40) samples.append(gpa, fqn) catch {};
    }
    io.printStdout(gpa, "[decl-audit] intrinsics={d} declared={d} missing={d} (builtin-type members {d}, extension-aligned {d}, member-aligned {d}, unaligned keys {d}, package-level holes {d}, package-unloaded {d})\n", .{ total, total - missing, missing, member_missing, member_ext_aligned, member_decl_aligned, unaligned, toplevel_missing, pkg_unloaded });
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
