//! `klio sema`: run the semantic analysis over the base set and the given
//! files and print its census, the references it could not resolve by
//! reason. Nothing executes, so a whole-corpus census takes seconds.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const span = @import("span");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const sema = @import("sema");
const stdlib_pack = @import("stdlib_pack");
const pack = @import("pack");
const serialization_pass = @import("serialization_pass");
const stdlib = @import("stdlib");
const lower_driver = @import("lower_driver");
const sema_actuals_embedded = @import("sema_actuals_embedded");

const io = @import("io.zig");
const pack_cache = @import("pack_cache.zig");
const project = @import("project.zig");
const cli = @import("cli.zig");
const sema_base_cache = @import("sema_base_cache.zig");
const interp_ir = @import("interp_ir");
const codec = interp_ir.codec;
const diagnostics = @import("diagnostics");

const Allocator = std.mem.Allocator;

const usage =
    \\usage: klio sema [options] [files or directories...]
    \\  --sites N        print the first N unresolved sites of each reason (default 5)
    \\  --headers-only   resolve declaration headers only, no bodies
    \\  --bodies WHICH   resolve bodies of: program (default), base, all
    \\  --dump PATH      write the resolution of the program files as TSV
    \\  --unresolved PATH write the program files' unresolved sites as TSV:
    \\                   path, start, end, reason, detail
    \\  --each           analyze every program file as its own program, against
    \\                   one parse of the base set; prints a census line per file
    \\  -j N             with --each, analyze N programs at once (default: cores, at most 8)
    \\  --in-process     with --each, analyze in threads of this process instead of one
    \\                   forked child per program (a panic then ends the whole run)
    \\  --no-packs       do not load the installed packs the programs import
    \\  --all-packs      load every installed pack with every feature, whatever the
    \\                   programs import: with --bodies all and --lower, the census
    \\                   of everything that ships
    \\  --feature P/F    load feature F of pack P, as `klio run --feature` does;
    \\                   with --each, a program's `// Run with: klio run ...`
    \\                   header flags are honored too
    \\  --quiet          totals only
    \\  --class FQN      print a class's kind, supertypes and declared members
    \\  --lower          bridge and lower the analyzed bodies from sema's records
    \\                   and print the lowering census: bodies lowered, and the
    \\                   failures by kind (missing record, unsupported construct,
    \\                   bridge gap, lowering error, unbound native)
    \\
    \\Directories are searched recursively for .kt files.
    \\
;

pub fn run(gpa: Allocator, args: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sites_per_reason: usize = 5;
    var headers_only = false;
    var bodies: enum { program, base, all } = .program;
    var dump_path: ?[]const u8 = null;
    var unresolved_path: ?[]const u8 = null;
    var quiet = false;
    var each = false;
    var in_process = false;
    var with_packs = true;
    var all_packs = false;
    var lower = false;
    var jobs: usize = 0;
    var inputs: std.ArrayList([]const u8) = .empty;
    var feature_specs: std.ArrayList([]const u8) = .empty;
    var show_classes: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--sites") and i + 1 < args.len) {
            i += 1;
            sites_per_reason = std.fmt.parseInt(usize, args[i], 10) catch 5;
        } else if (std.mem.eql(u8, a, "--headers-only")) {
            headers_only = true;
        } else if (std.mem.eql(u8, a, "--bodies") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "base")) bodies = .base else if (std.mem.eql(u8, args[i], "all")) bodies = .all else bodies = .program;
        } else if (std.mem.eql(u8, a, "--dump") and i + 1 < args.len) {
            i += 1;
            dump_path = args[i];
        } else if (std.mem.eql(u8, a, "--unresolved") and i + 1 < args.len) {
            i += 1;
            unresolved_path = args[i];
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--each")) {
            each = true;
        } else if (std.mem.eql(u8, a, "--in-process")) {
            in_process = true;
        } else if (std.mem.eql(u8, a, "--lower")) {
            lower = true;
        } else if (std.mem.eql(u8, a, "--all-packs")) {
            all_packs = true;
        } else if (std.mem.eql(u8, a, "--no-packs")) {
            with_packs = false;
        } else if (std.mem.eql(u8, a, "--feature") and i + 1 < args.len) {
            i += 1;
            feature_specs.append(arena, args[i]) catch return 2;
        } else if (std.mem.startsWith(u8, a, "--feature=")) {
            feature_specs.append(arena, a["--feature=".len..]) catch return 2;
        } else if (std.mem.eql(u8, a, "-j") and i + 1 < args.len) {
            i += 1;
            jobs = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--class") and i + 1 < args.len) {
            i += 1;
            show_classes.append(arena, args[i]) catch return 2;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            io.printStdout(gpa, usage, .{});
            return 0;
        } else {
            inputs.append(arena, a) catch return 2;
        }
    }

    var map = span.SourceMap.init(arena);
    // The serialization pass reads source text through the active map and
    // registers the files it generates there.
    span.active_map = &map;
    defer span.active_map = null;
    var files: std.ArrayList(sema.SourceFile) = .empty;

    // The base set: the stdlib sources the base image is built from. Its
    // common `expect` declarations declare the builtins themselves.
    var perr: pack.PackError = undefined;
    var stdlib_src = (stdlib_pack.stdlibSources(arena, null, &perr) catch return 2) orelse {
        io.printStderr(gpa, "error: the stdlib sources are not available\n", .{});
        return 2;
    };
    defer stdlib_src.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    for (stdlib_src.files) |sf| {
        addBaseSource(arena, &scratch, &map, &files, sf.rel_path, sf.bytes) catch return 2;
    }
    // The base a program runs on: klio's actuals beside the stdlib, as a run
    // and a pack build load them.
    addSemaActuals(arena, &scratch, &map, &files) catch return 2;
    const n_stdlib = files.items.len;
    var syntax: Syntax = .{};
    for (inputs.items) |path| {
        addPath(arena, &map, &files, path, &syntax) catch |e| {
            io.printStderr(gpa, "error: cannot read {s}: {s}\n", .{ path, @errorName(e) });
            return 2;
        };
    }
    // A program that does not parse is analyzed as far as it parsed; its
    // errors say why its census reads as it does.
    if (syntax.files != 0) {
        io.writeStderr(syntax.text.items);
        io.printStdout(gpa, "[sema] program files with syntax errors: {d}\n", .{syntax.files});
    }

    // The installed packs the programs import, the way `klio run` selects
    // them, as part of the shared base. The pack sources come from the klio
    // data home (`KLIO_HOME`), so a local pack build is what is analyzed.
    var programs: std.ArrayList(sema.SourceFile) = .empty;
    programs.appendSlice(arena, files.items[n_stdlib..]) catch return 2;
    // The library each pack file came from, for the census by library.
    var lib_of_file: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    files.shrinkRetainingCapacity(n_stdlib);
    if (each) {
        for (programs.items) |p| runWithFeatures(arena, map.get(p.ast.span.file).source, &feature_specs) catch return 2;
    }
    if (with_packs) {
        var program_asts: std.ArrayList(ast.KotlinFile) = .empty;
        for (programs.items) |p| program_asts.append(arena, p.ast.*) catch return 2;
        var features = cli.parseRequestedFeatures(arena, feature_specs.items);
        const loaded = pack_cache.loadInstalledPacksOpts(arena, program_asts.items, &map, &features, .{ .include_stdlib = false, .report_failures = false, .all = all_packs });
        for (loaded.asts, 0..) |*pa, li| {
            if (li < loaded.lib_ids.len) lib_of_file.put(arena, pa.span.file.int(), loaded.lib_ids[li]) catch return 2;
            const owned = arena.create(ast.KotlinFile) catch return 2;
            owned.* = pa.*;
            const path = if (pa.span.file.int() < map.files.items.len) map.get(pa.span.file).path else "<pack>";
            files.append(arena, .{ .ast = owned, .path = path, .origin = .pack }) catch return 2;
        }
    }
    // `@Serializable` classes get their generated serializers before sema
    // sees them, as they do before lowering: the packs' once, each
    // program's with the packs in view.
    const serial = Serial.init(arena, &map, files.items[n_stdlib..]) catch return 2;
    files.shrinkRetainingCapacity(n_stdlib);
    files.appendSlice(arena, serial.packs) catch return 2;
    const n_base = files.items.len;

    if (each) {
        return runEach(gpa, arena, &map, &serial, files.items[0..n_base], programs.items, .{
            .dump_path = dump_path,
            .unresolved_path = unresolved_path,
            .sites_per_reason = sites_per_reason,
            .quiet = quiet,
            .jobs = jobs,
            .headers_only = headers_only,
            .in_process = in_process,
        });
    }

    files.appendSlice(arena, serial.programFiles(arena, &map, programs.items) catch return 2) catch return 2;

    const t0 = nowNs();
    const s = sema.Sema.init(arena) catch return 2;
    s.addFiles(files.items) catch return 2;
    sema.headers.resolveAllHeaders(s) catch return 2;
    const t_headers = nowNs() - t0;
    if (!headers_only) {
        const origins: []const sema.Origin = switch (bodies) {
            .program => &.{.program},
            .base => &.{.base},
            .all => &.{ .base, .pack, .program },
        };
        s.resolveBodies(origins) catch return 2;
    }
    const out = sema.output.build(s) catch return 2;
    const t_total = nowNs() - t0;
    if (out.orphans != 0) io.printStdout(gpa, "[sema] records without a node: {d}\n", .{out.orphans});

    if (dump_path) |dp| {
        sema.dump.writeTsv(s, arena, &map, dp) catch |e| {
            io.printStderr(gpa, "error: cannot write {s}: {s}\n", .{ dp, @errorName(e) });
            return 2;
        };
    }

    if (unresolved_path) |up| {
        var buf: std.ArrayList(u8) = .empty;
        for (s.census.sites.items) |site| {
            const fc = s.fileOf(site.file) orelse continue;
            if (fc.origin != .program) continue;
            appendUnresolved(arena, &buf, fc.path, site) catch return 2;
        }
        writeOut(gpa, arena, up, buf.items) catch return 2;
    }

    for (show_classes.items) |fqn| showClass(gpa, s, fqn);
    printCensus(gpa, arena, s, &map, sites_per_reason, quiet, files.items.len, t_headers, t_total);
    if (lower and !headers_only) {
        const origins: []const sema.Origin = switch (bodies) {
            .program => &.{.program},
            .base => &.{.base},
            .all => &.{ .base, .pack, .program },
        };
        var lowered_files: std.ArrayList(u32) = .empty;
        for (s.files.items, 0..) |fc, fi| {
            for (origins) |o| if (fc.origin == o) lowered_files.append(arena, @intCast(fi)) catch return 2;
        }
        const t_lower = nowNs();
        const r = lower_driver.lower_census.run(arena, s, &map, out.files, &.{}, lowered_files.items, hostBinding(gpa)) catch |e| {
            io.printStderr(gpa, "error: lowering failed: {s}\n", .{@errorName(e)});
            return 2;
        };
        var buf: std.ArrayList(u8) = .empty;
        lower_driver.lower_census.print(arena, &buf, r, sites_per_reason) catch return 2;
        printByLibrary(arena, &buf, s, r, &lib_of_file) catch return 2;
        buf.print(arena, "[lower] time {d} ms\n", .{(nowNs() - t_lower) / std.time.ns_per_ms}) catch return 2;
        io.printStdout(gpa, "{s}", .{buf.items});
        if (r.bodies != r.lowered) return 1;
    }
    return if (s.census.total() == 0) 0 else 1;
}

/// The census by library: for each library with a failure, sema's sites
/// and the lowering failures by kind, then each message (numbers folded)
/// with its count. A file no pack loaded is the base's or the program's.
fn printByLibrary(a: Allocator, w: *std.ArrayList(u8), s: *sema.Sema, r: lower_driver.lower_census.Result, lib_of_file: *const std.AutoHashMapUnmanaged(u32, []const u8)) !void {
    const Lib = struct {
        sema_sites: u32 = 0,
        counts: [lower_driver.lower_census.n_kinds]u32 = @splat(0),
        messages: std.StringArrayHashMapUnmanaged(u32) = .empty,
    };
    var libs: std.StringArrayHashMapUnmanaged(Lib) = .empty;
    const libOf = struct {
        fn f(sm: *sema.Sema, map: *const std.AutoHashMapUnmanaged(u32, []const u8), file: ?u32) []const u8 {
            const id = file orelse return "?";
            if (map.get(id)) |lib| return lib;
            for (sm.files.items) |fc| {
                if ((fc.ast orelse continue).span.file.int() != id) continue;
                return switch (fc.origin) {
                    .base => "stdlib",
                    .program => "program",
                    .pack => "generated",
                };
            }
            return "?";
        }
    }.f;
    for (s.census.sites.items) |site| {
        const fc = s.fileOf(site.file) orelse continue;
        const gop = try libs.getOrPut(a, libOf(s, lib_of_file, (fc.ast orelse continue).span.file.int()));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.sema_sites += 1;
        const key = try std.fmt.allocPrint(a, "sema {s}", .{@tagName(site.reason)});
        const m = try gop.value_ptr.messages.getOrPut(a, key);
        if (!m.found_existing) m.value_ptr.* = 0;
        m.value_ptr.* += 1;
    }
    for (r.entries) |e| {
        const gop = try libs.getOrPut(a, libOf(s, lib_of_file, e.file));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.counts[@intFromEnum(e.kind)] += 1;
        const text = try lower_driver.lower_census.fold(a, if (e.kind == .unbound_native) e.func else e.msg);
        const key = try std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(e.kind), text });
        const m = try gop.value_ptr.messages.getOrPut(a, key);
        if (!m.found_existing) m.value_ptr.* = 0;
        m.value_ptr.* += 1;
    }
    if (libs.count() == 0) return;
    try w.print(a, "\n[census] by library:\n", .{});
    var it = libs.iterator();
    while (it.next()) |lib| {
        try w.print(a, "  {s}: sema {d}", .{ lib.key_ptr.*, lib.value_ptr.sema_sites });
        for (lib.value_ptr.counts, 0..) |c, k| {
            if (c != 0) try w.print(a, ", {s} {d}", .{ @tagName(@as(lower_driver.lower_census.Kind, @enumFromInt(k))), c });
        }
        try w.print(a, "\n", .{});
        var mit = lib.value_ptr.messages.iterator();
        while (mit.next()) |m| try w.print(a, "  {d:>7}  {s}\n", .{ m.value_ptr.*, m.key_ptr.* });
    }
}

/// The `actual`s the sema pipeline adds to the base (`kotlin-klio/kotlin-sema`):
/// declarations the name-resolving interpreter serves from the host, which
/// the pipeline needs as Kotlin. Read from the checkout when there is one,
/// else the copies the binary carries.
pub const sema_actuals_dir = stdlib.pack_builder.SEMA_ACTUALS_DIR;

/// The host's natives, the packs' included, by symbol: set once by
/// `hostBinding` before a build reads it.
var host_bindings: ?stdlib.HostBindings = null;

pub fn hostNative(fqn: []const u8) ?stdlib.StdlibFn {
    if (host_bindings) |*hb| if (hb.resolve(fqn)) |f| return f;
    return stdlib.implementation(fqn);
}

/// How the bridge binds the base, the packs and the program to the host:
/// the natives of the stdlib and of every pack, host members by name, and
/// the host's calling convention for varargs.
pub fn hostBinding(gpa: Allocator) lower_driver.pipeline.Binding {
    if (host_bindings == null) host_bindings = pack_cache.mergedHostBindings(gpa);
    return .{ .natives = hostNative, .host_symbol = stdlib.declarationHostSymbol, .host_members = true, .spread_varargs = true, .constructors = stdlib.constructorNative, .host_fns = interp_ir.hostMemberFn, .host_tries = interp_ir.hostMemberTry };
}

fn addSemaActuals(arena: Allocator, scratch: *std.heap.ArenaAllocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile)) !void {
    for (try semaActuals(arena)) |f| try addBaseSource(arena, scratch, map, files, f.path, f.text);
}

/// klio's actuals the base holds beside the stdlib: the checkout's files,
/// else the copies the binary carries.
fn semaActuals(arena: Allocator) ![]const BaseFile {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    var out: std.ArrayList(BaseFile) = .empty;
    for (stdlib.pack_builder.SEMA_ACTUAL_FILES) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sema_actuals_dir, name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, arena, .unlimited) catch |e| switch (e) {
            error.FileNotFound => embeddedActual(name) orelse continue,
            else => return e,
        };
        try out.append(arena, .{ .path = path, .text = bytes, .origin = .base });
    }
    return out.items;
}

fn embeddedActual(name: []const u8) ?[]const u8 {
    for (sema_actuals_embedded.files) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.bytes;
    }
    return null;
}

test "a program file's lex and parse diagnostics are rendered and stop the load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = span.SourceMap.init(a);
    var files: std.ArrayList(sema.SourceFile) = .empty;
    var report: LoadReport = .{};
    try addProgramSource(a, &map, &files, "ok.kt", "fun main() {}\n", &report);
    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expectEqualStrings("", report.syntax.items);
    try std.testing.expectError(error.ProgramSyntax, addProgramSource(a, &map, &files, "bad.kt", "fun main() {\n    println(\"hi\"\n}\n", &report));
    try std.testing.expectEqualStrings("bad.kt:3:1: error: expected `)` [E0001]\n}\n^\n", report.syntax.items);
    report.syntax.clearRetainingCapacity();
    try std.testing.expectError(error.ProgramSyntax, addProgramSource(a, &map, &files, "lex.kt", "val s = \"abc\n", &report));
    try std.testing.expect(std.mem.startsWith(u8, report.syntax.items, "lex.kt:1:"));
    try std.testing.expectEqual(@as(usize, 1), files.items.len);
}

test "every file of the sema actuals directory is listed, so the binary carries it" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(fio, sema_actuals_dir, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(fio);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(fio)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".kt")) continue;
        n += 1;
        var listed = false;
        for (stdlib.pack_builder.SEMA_ACTUAL_FILES) |name| {
            if (std.mem.eql(u8, name, e.name)) listed = true;
        }
        if (!listed) std.debug.print("{s}/{s} is not in stdlib_sources.SEMA_ACTUAL_FILES\n", .{ sema_actuals_dir, e.name });
        try std.testing.expect(listed);
    }
    try std.testing.expectEqual(stdlib.pack_builder.SEMA_ACTUAL_FILES.len, n);
}

/// How `loadSources` loads a run's files.
pub const LoadOptions = struct {
    /// `<pack>/<feature>` requests, as `--feature` spells them.
    feature_specs: []const []const u8 = &.{},
    with_packs: bool = true,
    /// Print the pack loader's warnings: a wanted pack that does not decode,
    /// and the pack feature an import needs.
    report_pack_failures: bool = false,
    /// Where the program's lex and parse diagnostics and an unreadable path
    /// are reported.
    report: ?*LoadReport = null,
    /// The inputs are test roots, as `klio test` takes them: a root that is
    /// neither a directory nor a `.kt` file holds no tests.
    test_roots: bool = false,
    /// The programs' texts, one per input: parsed instead of reading the
    /// inputs, which only name them.
    program_texts: ?[]const []const u8 = null,
    /// The base's files, as a sema image carries them: registered and parsed
    /// in place of the stdlib sources, the sema actuals and the installed
    /// packs, so nothing is read from the data home or the checkout.
    base: ?[]const BaseFile = null,
    /// With `base`, the base image they were baked into. When no program is
    /// one the serialization pass rewrites, the base's files register from
    /// the image and none of them parses (`Sources.image`).
    base_image: ?[]const u8 = null,
    /// Receives the base's files as they were registered, for a sema image.
    record_base: ?*std.ArrayList(BaseFile) = null,
    /// Receives the packs the programs' imports selected.
    selection: ?*pack_cache.Selection = null,
    /// Looks the base's image up in the cache before any of the base
    /// parses. When there is one, and no program is one the serialization
    /// pass rewrites (it reads the packs' declarations from their source),
    /// nothing of the base parses: `Sources.image` is the image, and the
    /// base's files join the source map with their lines only.
    image: bool = false,
};

/// A file of a run's base, in the order `loadSources` registered it: the
/// stdlib's and the sema actuals' (`.base`), then the packs' (`.pack`). The
/// serializers generated for the packs are not among them; a load generates
/// them again.
pub const BaseFile = struct {
    path: []const u8,
    text: []const u8,
    origin: sema.Origin,
};

/// What `loadSources` found wrong with the program before any analysis.
pub const LoadReport = struct {
    /// The program files' lex and parse diagnostics, warnings included,
    /// rendered plain: file by file, each file's lexer diagnostics before
    /// its parser's, up to the first file with an error.
    syntax: std.ArrayList(u8) = .empty,
    /// The program files' lex and parse diagnostics as values, spanned in
    /// the run's map: filled once the program has loaded.
    syntax_diags: std.ArrayList(diagnostics.Diagnostic) = .empty,
    /// The program path that could not be read, and why.
    unreadable: ?struct { path: []const u8, err: anyerror } = null,
};

/// The files a run analyzes, loaded as `klio sema` loads them: the stdlib
/// sources, the installed packs the programs import (with the requested
/// features), and the programs, each with the serializers generated for it.
/// A program that does not lex or parse is `error.ProgramSyntax`, one that
/// cannot be read `error.ProgramUnreadable`; `opts.report` says what.
pub fn loadSources(arena: Allocator, map: *span.SourceMap, inputs: []const []const u8, opts: LoadOptions) !lower_driver.pipeline.Sources {
    // The programs are parsed first, into a map of their own: a program that
    // does not parse stops the run before anything else loads, and their
    // imports choose the packs. They join `map` after the base, so no base
    // file's id depends on the program (the base image holds the base's
    // spans).
    var scratch_report: LoadReport = .{};
    const report = opts.report orelse &scratch_report;
    var scan_map = span.SourceMap.init(arena);
    var scanned: std.ArrayList(sema.SourceFile) = .empty;
    for (inputs, 0..) |path, k| {
        if (opts.program_texts) |texts| {
            try addProgramSource(arena, &scan_map, &scanned, path, texts[k], report);
            continue;
        }
        addPathChecked(arena, &scan_map, &scanned, path, report) catch |e| switch (e) {
            error.ProgramSyntax => return e,
            error.OutOfMemory => return e,
            else => {
                if (opts.test_roots and !std.mem.endsWith(u8, path, ".kt")) continue;
                report.unreadable = .{ .path = path, .err = e };
                return error.ProgramUnreadable;
            },
        };
    }

    // The base parses with the language as it is by default: `--language`
    // is the program's, and the base, its image and every run over it are
    // one whatever a program turns on.
    const program_language = parser.language;
    parser.language = .{};
    defer parser.language = program_language;

    var files: std.ArrayList(sema.SourceFile) = .empty;
    const map_start = map.files.items.len;
    var n_stdlib: usize = 0;
    var map_stdlib: usize = 0;
    var key: ?[16]u8 = null;
    if (opts.base) |base| {
        if (opts.base_image) |bytes| {
            const fr = lower_driver.pipeline.base_image.front(arena, bytes) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return error.MalformedImage,
            };
            if (!try serializedPrograms(arena, &scan_map, scanned.items, fr.driver)) {
                parser.language = program_language;
                const programs = try overImage(arena, map, &scan_map, scanned.items, fr, report);
                return .{ .base = &.{}, .program = programs, .image = bytes };
            }
            // Baked for programs the pass did not rewrite, the image
            // carries no base source for it to read.
            if (base.len == 0) return error.ImageWithoutBaseSources;
        }
        try addImageBase(arena, map, &files, base);
        for (files.items) |f| {
            if (f.origin == .pack) break;
            n_stdlib += 1;
        }
        for (base) |f| {
            if (f.origin == .pack) break;
            map_stdlib += 1;
        }
        map_stdlib += map_start;
    } else {
        var perr: pack.PackError = undefined;
        var stdlib_src = (try stdlib_pack.stdlibSources(arena, null, &perr)) orelse return error.StdlibSourcesMissing;
        defer stdlib_src.deinit();
        const actuals = try semaActuals(arena);
        // What the base is, before any of it parses: the files it is built
        // from and the packs the programs select, which name its image.
        var base_key = sema_base_cache.Key.init();
        for (stdlib_src.files) |sf| base_key.file(sf.rel_path, sf.bytes);
        for (actuals) |f| base_key.file(f.path, f.text);
        if (opts.with_packs) {
            var own_selection: pack_cache.Selection = .{};
            const sel = opts.selection orelse &own_selection;
            // A pack without an import section parses to tell its imports;
            // its files register here, not in `map`.
            var pack_map = span.SourceMap.init(arena);
            _ = try loadPacks(arena, &scanned, &pack_map, opts, .{ .asts_needed = false, .selection = sel, .report = opts.report_pack_failures });
            for (sel.packs.items) |sp| base_key.pack(&sp.hash, sp.features);
        }
        key = base_key.final();
        if (opts.image and opts.record_base == null and !sema_base_cache.disabled()) {
            var cached = try cachedImage(arena, key.?);
            // No image yet: the base bakes on a heap of its own, dropped
            // whole once the image exists, and the run goes on from the
            // image as a run over a cached one does.
            if (cached == null) cached = try bakeOnOwnHeap(arena, stdlib_src.files, actuals, &scanned, opts, key.?);
            if (cached) |found| {
                if (!try serializedPrograms(arena, &scan_map, scanned.items, found.front.driver)) {
                    parser.language = program_language;
                    const programs = try overImage(arena, map, &scan_map, scanned.items, found.front, report);
                    return .{ .base = &.{}, .program = programs, .image = found.bytes, .key = key };
                }
            }
        }
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        for (stdlib_src.files) |sf| try addBaseSource(arena, &scratch, map, &files, sf.rel_path, sf.bytes);
        for (actuals) |f| try addBaseSource(arena, &scratch, map, &files, f.path, f.text);
        n_stdlib = files.items.len;
        map_stdlib = map.files.items.len;
        if (opts.with_packs) {
            const loaded = try loadPacks(arena, &scanned, map, opts, .{ .asts_needed = true, .selection = null, .report = false });
            for (loaded.asts) |*pa| {
                const owned = try arena.create(ast.KotlinFile);
                owned.* = pa.*;
                const path = if (pa.span.file.int() < map.files.items.len) map.get(pa.span.file).path else "<pack>";
                try files.append(arena, .{ .ast = owned, .path = path, .origin = .pack });
            }
        }
    }
    if (opts.record_base) |out| {
        for (map.files.items[map_start..], map_start..) |f, i| {
            try out.append(arena, .{ .path = f.path, .text = f.source, .origin = if (i < map_stdlib) .base else .pack });
        }
    }
    const serial = try Serial.init(arena, map, files.items[n_stdlib..]);
    files.shrinkRetainingCapacity(n_stdlib);
    try files.appendSlice(arena, serial.packs);
    parser.language = program_language;
    var programs: std.ArrayList(sema.SourceFile) = .empty;
    for (scanned.items) |p| {
        const src = scan_map.get(p.ast.span.file);
        try addSourceReporting(arena, map, &programs, p.path, src.source, .program, null, &report.syntax_diags);
    }
    return .{
        .base = files.items,
        .program = try serial.programFiles(arena, map, programs.items),
        .key = key,
        .record = try serial.record(arena),
    };
}

const PackLoad = struct { asts_needed: bool, selection: ?*pack_cache.Selection, report: bool };

/// The installed packs the programs `scanned` select, loaded into `map`.
fn loadPacks(arena: Allocator, scanned: *const std.ArrayList(sema.SourceFile), map: *span.SourceMap, opts: LoadOptions, how: PackLoad) !pack_cache.LoadedPacks {
    var program_asts: std.ArrayList(ast.KotlinFile) = .empty;
    var program_paths: std.ArrayList([]const u8) = .empty;
    for (scanned.items) |p| {
        try program_asts.append(arena, p.ast.*);
        try program_paths.append(arena, p.path);
    }
    var features = cli.parseRequestedFeatures(arena, opts.feature_specs);
    // A project's own sources never load its installed pack beside them,
    // and a project loads only the libraries its manifest declares.
    return pack_cache.loadInstalledPacksOpts(arena, program_asts.items, map, &features, .{
        .include_stdlib = false,
        .report_failures = how.report,
        .exclude_lib_ids = project.ownLibraryExclusion(arena, program_paths.items),
        .declared_lib_ids = project.declaredDependencyIds(arena, program_paths.items),
        .selection = how.selection,
        .asts_needed = how.asts_needed,
    });
}

const Found = struct { bytes: []const u8, front: lower_driver.pipeline.base_image.Front };

/// The programs `scanned`, joining `map` after the base's files as the
/// image `fr` registers them, with their lines only.
fn overImage(arena: Allocator, map: *span.SourceMap, scan_map: *const span.SourceMap, scanned: []const sema.SourceFile, fr: lower_driver.pipeline.base_image.Front, report: *LoadReport) ![]const sema.SourceFile {
    for (fr.sources) |src| _ = try map.addLines(src.path, src.line_starts);
    var programs: std.ArrayList(sema.SourceFile) = .empty;
    for (scanned) |p| {
        const src = scan_map.get(p.ast.span.file);
        try addSourceReporting(arena, map, &programs, p.path, src.source, .program, null, &report.syntax_diags);
    }
    return programs.items;
}

/// Parses, analyzes, lowers and bakes the base on the build heap
/// (`runtime.slab.buildHeap`), writes the image to the cache under `key`,
/// and drops the heap: nothing of the build outlives the bake but the
/// image. The image as the cache maps it, else its bytes on the process
/// heap when the cache cannot keep it.
fn bakeOnOwnHeap(arena: Allocator, stdlib_files: []const pack.schema.SourceFile, actuals: []const BaseFile, scanned: *const std.ArrayList(sema.SourceFile), opts: LoadOptions, key: [16]u8) !?Found {
    const gpa = std.heap.smp_allocator;
    const bytes = blk: {
        const heap = runtime.slab.buildHeap();
        defer runtime.slab.releaseAll(heap);
        const ba = heap.allocator();
        const map = try ba.create(span.SourceMap);
        map.* = span.SourceMap.init(ba);
        // The serialization pass registers the files it generates in the
        // active map.
        const saved_map = span.active_map;
        span.active_map = map;
        defer span.active_map = saved_map;
        var files: std.ArrayList(sema.SourceFile) = .empty;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        for (stdlib_files) |sf| try addBaseSource(ba, &scratch, map, &files, sf.rel_path, sf.bytes);
        for (actuals) |f| try addBaseSource(ba, &scratch, map, &files, f.path, f.text);
        const n_stdlib = files.items.len;
        if (opts.with_packs) {
            const loaded = try loadPacks(ba, scanned, map, opts, .{ .asts_needed = true, .selection = null, .report = false });
            for (loaded.asts) |*pa| {
                const owned = try ba.create(ast.KotlinFile);
                owned.* = pa.*;
                const path = if (pa.span.file.int() < map.files.items.len) map.get(pa.span.file).path else "<pack>";
                try files.append(ba, .{ .ast = owned, .path = path, .origin = .pack });
            }
        }
        const serial = try Serial.init(ba, map, files.items[n_stdlib..]);
        files.shrinkRetainingCapacity(n_stdlib);
        try files.appendSlice(ba, serial.packs);
        var t = lower_driver.pipeline.Timing.start();
        const baked = try lower_driver.pipeline.bakeBase(ba, gpa, files.items, hostBinding(gpa), map, try serial.record(ba));
        t.mark("bake base image");
        break :blk baked;
    };
    if (sema_base_cache.pathFor(arena, key)) |path| {
        sema_base_cache.write(arena, path, bytes);
        if (try cachedImage(arena, key)) |found| {
            gpa.free(bytes);
            return found;
        }
    }
    const fr = lower_driver.pipeline.base_image.front(arena, bytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    return .{ .bytes = bytes, .front = fr };
}

/// The cached image of the base `key` names, when the cache has one this
/// klio reads.
fn cachedImage(arena: Allocator, key: [16]u8) !?Found {
    if (sema_base_cache.disabled()) return null;
    const path = sema_base_cache.pathFor(arena, key) orelse return null;
    const bytes = sema_base_cache.read(arena, path) orelse return null;
    const fr = lower_driver.pipeline.base_image.front(arena, bytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    return .{ .bytes = bytes, .front = fr };
}

/// Whether the serialization pass rewrites one of the programs: one that
/// writes `@Serializable`, or uses one of the packs' meta-serializable
/// annotations, which `record` (`Serial.record`) names. `scan_map` holds
/// the programs.
pub fn serializedPrograms(arena: Allocator, scan_map: *const span.SourceMap, programs: []const sema.SourceFile, record: []const u8) !bool {
    // The pass reads a file's text through the active map.
    const saved = span.active_map;
    span.active_map = scan_map;
    defer span.active_map = saved;
    var meta = std.StringHashMap(void).init(arena);
    const names: []const []const u8 = if (record.len == 0) &.{} else codec.decodeBytes([]const []const u8, arena, record) catch &.{};
    for (names) |n| try meta.put(n, {});
    for (programs) |p| {
        if (serialization_pass.fileMentionsSerializable(p.ast) or serialization_pass.fileUsesMetaSerializable(p.ast, &meta)) return true;
    }
    return false;
}

/// Registers and parses a base a sema image carries, as `loadSources`
/// registers the stdlib, the sema actuals and the packs: the stdlib's
/// files one by one, the packs' as the pack loader parses them, skipping
/// one that does not parse as the loader does. The map entries, and so the
/// base's file ids, are the ones the image was baked against.
fn addImageBase(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), base: []const BaseFile) !void {
    var pack_ids: std.ArrayList(span.FileId) = .empty;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    for (base) |f| {
        if (f.origin != .pack) {
            try addBaseSource(arena, &scratch, map, files, f.path, f.text);
            continue;
        }
        try pack_ids.append(arena, try map.add(f.path, f.text));
    }
    const parsed = try pack_cache.parsePackSources(arena, map, pack_ids.items);
    for (parsed, pack_ids.items) |maybe, fid| {
        const file_ast = maybe orelse continue;
        if (file_ast.package) |pkg| {
            var name: std.ArrayList(u8) = .empty;
            for (pkg.path, 0..) |seg, k| {
                if (k != 0) try name.append(arena, '.');
                try name.appendSlice(arena, seg.name);
            }
            if (name.items.len != 0) stdlib.registerKnownPackage(name.items);
        }
        const owned = try arena.create(ast.KotlinFile);
        owned.* = file_ast;
        try files.append(arena, .{ .ast = owned, .path = map.get(fid).path, .origin = .pack });
    }
}

/// `addPath` for a program: its lex and parse diagnostics are rendered into
/// `report.syntax`, and the first file with an error is `error.ProgramSyntax`.
fn addPathChecked(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), path: []const u8, report: *LoadReport) !void {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    const st = try std.Io.Dir.cwd().statFile(fio, path, .{});
    if (st.kind == .directory) {
        for (try ktFilesBelow(arena, path)) |full| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(fio, full, arena, .unlimited);
            try addProgramSource(arena, map, files, full, bytes, report);
        }
        return;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(fio, path, arena, .unlimited);
    try addProgramSource(arena, map, files, path, bytes, report);
}

/// Parses a program file as `addSource` does, rendering its diagnostics.
pub fn addProgramSource(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), path: []const u8, bytes: []const u8, report: *LoadReport) !void {
    const id = try map.add(path, bytes);
    const src = map.get(id).source;
    var lx = try lexer.Lexer.init(arena, id, src);
    const lexed = try lx.tokenize();
    try lexed.diagnostics.render(arena, map, &report.syntax);
    if (lexed.diagnostics.hasErrors()) return error.ProgramSyntax;
    const p = parser.Parser.new(arena, id, src, lexed.tokens, lexed.strings);
    const saved_language = parser.language;
    defer parser.language = saved_language;
    runWithLanguage(src);
    const file_ast = try arena.create(ast.KotlinFile);
    file_ast.* = p.parseFile();
    try p.diagnostics.render(arena, map, &report.syntax);
    if (p.diagnostics.hasErrors()) return error.ProgramSyntax;
    try files.append(arena, .{ .ast = file_ast, .path = path, .origin = .program });
}

const EachOptions = struct {
    dump_path: ?[]const u8,
    unresolved_path: ?[]const u8,
    sites_per_reason: usize,
    quiet: bool,
    jobs: usize,
    headers_only: bool,
    in_process: bool,
};

const Reason = sema.census.Reason;
const n_reasons = std.meta.fields(Reason).len;

/// One program's analysis, kept after its `Sema` is dropped.
const ProgramResult = struct {
    ok: bool = false,
    /// Why the analysis did not finish: the child's panic line or signal.
    failure: []const u8 = "",
    resolved: u64 = 0,
    /// Unresolved sites in the program file.
    counts: [n_reasons]u64 = @splat(0),
    sites: []const sema.census.Site = &.{},
    /// Each site's `path:line:col`, formatted where the analysis ran: a
    /// forked child's generated files are not in the parent's map.
    site_locs: []const []const u8 = &.{},
    /// Sites outside the program file (the base set's headers); the same for
    /// every program, so the aggregate takes them from the first one.
    base_counts: [n_reasons]u64 = @splat(0),
    base_sites: []const sema.census.Site = &.{},
    base_site_locs: []const []const u8 = &.{},
    /// The program's dump lines, formatted.
    tsv: []const u8 = "",
    ns: u64 = 0,
};

const EachShared = struct {
    map: *span.SourceMap,
    serial: *const Serial,
    base: []const sema.SourceFile,
    programs: []const sema.SourceFile,
    results: []ProgramResult,
    /// Owns every result's sites and text; guarded by `lock`.
    out_arena: Allocator,
    lock: std.atomic.Mutex = .unlocked,
    next: std.atomic.Value(usize) = .init(0),
    dump: bool,
    headers_only: bool,
    in_process: bool,

    fn worker(self: *EachShared) void {
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.programs.len) return;
            const t0 = nowNs();
            var r = (if (self.in_process) self.runInProcess(i) else self.runIsolated(i)) catch |e| ProgramResult{ .failure = @errorName(e) };
            r.ns = nowNs() - t0;
            self.results[i] = r;
        }
    }

    fn runInProcess(self: *EachShared, i: usize) !ProgramResult {
        var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer run_arena.deinit();
        const bytes = try self.analyze(run_arena.allocator(), self.programs[i]);
        return self.decode(bytes);
    }

    /// Runs one program's analysis in a forked child, so a panic in the
    /// analysis costs that program only. The child inherits the parsed
    /// base set, writes its encoded result to a pipe and exits; its stderr
    /// is kept for the failure reason.
    fn runIsolated(self: *EachShared, i: usize) !ProgramResult {
        if (comptime builtin.os.tag == .windows) return error.NoForkOnWindows;
        var out_fds: [2]std.c.fd_t = undefined;
        var err_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&out_fds) != 0) return error.PipeFailed;
        if (std.c.pipe(&err_fds) != 0) {
            _ = std.c.close(out_fds[0]);
            _ = std.c.close(out_fds[1]);
            return error.PipeFailed;
        }
        const pid = std.c.fork();
        if (pid < 0) {
            for ([_]std.c.fd_t{ out_fds[0], out_fds[1], err_fds[0], err_fds[1] }) |fd| _ = std.c.close(fd);
            return error.ForkFailed;
        }
        if (pid == 0) {
            _ = std.c.close(out_fds[0]);
            _ = std.c.close(err_fds[0]);
            _ = std.c.dup2(err_fds[1], 2);
            var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            const bytes = self.analyze(run_arena.allocator(), self.programs[i]) catch std.c._exit(3);
            writeAll(out_fds[1], bytes) catch std.c._exit(4);
            std.c._exit(0);
        }
        _ = std.c.close(out_fds[1]);
        _ = std.c.close(err_fds[1]);
        defer _ = std.c.close(out_fds[0]);
        defer _ = std.c.close(err_fds[0]);

        var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer run_arena.deinit();
        const ra = run_arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        var err: std.ArrayList(u8) = .empty;
        try drain(ra, out_fds[0], &out, err_fds[0], &err);
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0) {}
        const st: u32 = @bitCast(status);
        if (std.c.W.IFEXITED(st) and std.c.W.EXITSTATUS(st) == 0) return self.decode(out.items);

        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        const why = if (panicLine(err.items)) |line|
            try self.out_arena.dupe(u8, line)
        else if (std.c.W.IFSIGNALED(st))
            try std.fmt.allocPrint(self.out_arena, "signal {d}", .{@intFromEnum(std.c.W.TERMSIG(st))})
        else
            try std.fmt.allocPrint(self.out_arena, "exit {d}", .{std.c.W.EXITSTATUS(st)});
        return .{ .failure = why };
    }

    /// Resolves the base set plus one program file in a fresh analysis and
    /// encodes what outlives it.
    fn analyze(self: *EachShared, ra: Allocator, program: sema.SourceFile) ![]const u8 {
        // The serialization pass keeps process-wide state and appends to
        // the map; threads of one process take turns.
        const own = blk: {
            if (self.in_process) while (!self.lock.tryLock()) std.atomic.spinLoopHint();
            defer if (self.in_process) self.lock.unlock();
            break :blk try self.serial.programFiles(ra, self.map, &.{program});
        };
        const files = try ra.alloc(sema.SourceFile, self.base.len + own.len);
        @memcpy(files[0..self.base.len], self.base);
        @memcpy(files[self.base.len..], own);
        const s = try sema.Sema.init(ra);
        try s.addFiles(files);
        try sema.headers.resolveAllHeaders(s);
        if (!self.headers_only) try s.resolveBodies(&.{.program});
        _ = try sema.output.build(s);

        var tsv: []const u8 = "";
        if (self.dump) {
            var lines: std.ArrayList(sema.dump.Line) = .empty;
            try sema.dump.collect(s, ra, self.map, &lines);
            tsv = try sema.dump.format(ra, lines.items);
        }
        var buf: std.ArrayList(u8) = .empty;
        try putInt(ra, &buf, u64, s.census.resolved);
        try putInt(ra, &buf, u32, @intCast(s.census.sites.items.len));
        const program_index: u32 = @intCast(self.base.len);
        for (s.census.sites.items) |site| {
            try putInt(ra, &buf, u8, @intFromEnum(site.reason));
            try putInt(ra, &buf, u8, @intFromBool(site.file >= program_index));
            try putInt(ra, &buf, u32, site.sp.file.int());
            try putInt(ra, &buf, u32, site.sp.start);
            try putInt(ra, &buf, u32, site.sp.end);
            try putInt(ra, &buf, u32, @intCast(site.detail.len));
            try buf.appendSlice(ra, site.detail);
            const loc = location(ra, self.map, site.sp);
            try putInt(ra, &buf, u32, @intCast(loc.len));
            try buf.appendSlice(ra, loc);
        }
        try putInt(ra, &buf, u64, tsv.len);
        try buf.appendSlice(ra, tsv);
        return buf.items;
    }

    /// Reads `analyze`'s encoding into a result owned by `out_arena`.
    fn decode(self: *EachShared, bytes: []const u8) !ProgramResult {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        const a = self.out_arena;
        var rd: Reader = .{ .bytes = bytes };
        var r: ProgramResult = .{ .ok = true };
        r.resolved = try rd.int(u64);
        const n = try rd.int(u32);
        var sites: std.ArrayList(sema.census.Site) = .empty;
        var base_sites: std.ArrayList(sema.census.Site) = .empty;
        var locs: std.ArrayList([]const u8) = .empty;
        var base_locs: std.ArrayList([]const u8) = .empty;
        for (0..n) |_| {
            const reason: Reason = @enumFromInt(try rd.int(u8));
            const in_program = try rd.int(u8) != 0;
            const file = span.FileId.from(try rd.int(u32));
            const start = try rd.int(u32);
            const end = try rd.int(u32);
            const detail = try a.dupe(u8, try rd.take(try rd.int(u32)));
            const loc = try a.dupe(u8, try rd.take(try rd.int(u32)));
            const site: sema.census.Site = .{ .reason = reason, .file = 0, .sp = span.Span.init(file, start, end), .detail = detail };
            if (in_program) {
                r.counts[@intFromEnum(reason)] += 1;
                try sites.append(a, site);
                try locs.append(a, loc);
            } else {
                r.base_counts[@intFromEnum(reason)] += 1;
                try base_sites.append(a, site);
                try base_locs.append(a, loc);
            }
        }
        r.tsv = try a.dupe(u8, try rd.take(@intCast(try rd.int(u64))));
        r.sites = sites.items;
        r.site_locs = locs.items;
        r.base_sites = base_sites.items;
        r.base_site_locs = base_locs.items;
        return r;
    }
};

fn appendUnresolved(a: Allocator, buf: *std.ArrayList(u8), path: []const u8, site: sema.census.Site) !void {
    try buf.print(a, "{s}\t{d}\t{d}\t{s}\t", .{ path, site.sp.start, site.sp.end, @tagName(site.reason) });
    for (site.detail) |ch| try buf.append(a, if (ch == '\t' or ch == '\n') ' ' else ch);
    try buf.append(a, '\n');
}

fn writeOut(gpa: Allocator, arena: Allocator, path: []const u8, bytes: []const u8) !void {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = bytes }) catch |e| {
        io.printStderr(gpa, "error: cannot write {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
}

fn putInt(a: Allocator, buf: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try buf.appendSlice(a, &b);
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.TruncatedResult;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn int(self: *Reader, comptime T: type) !T {
        const b = try self.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }
};

fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Reads two pipes to their end, whichever has data, so a child that fills
/// one while the other is read never blocks.
fn drain(a: Allocator, fd_a: std.c.fd_t, buf_a: *std.ArrayList(u8), fd_b: std.c.fd_t, buf_b: *std.ArrayList(u8)) !void {
    var fds = [_]std.c.pollfd{
        .{ .fd = fd_a, .events = std.c.POLL.IN, .revents = 0 },
        .{ .fd = fd_b, .events = std.c.POLL.IN, .revents = 0 },
    };
    const bufs = [_]*std.ArrayList(u8){ buf_a, buf_b };
    var open: usize = 2;
    var chunk: [64 * 1024]u8 = undefined;
    while (open != 0) {
        if (std.c.poll(&fds, fds.len, -1) < 0) continue;
        for (&fds, bufs) |*p, buf| {
            if (p.fd < 0 or p.revents == 0) continue;
            const n = std.c.read(p.fd, &chunk, chunk.len);
            if (n <= 0) {
                p.fd = -1;
                open -= 1;
                continue;
            }
            try buf.appendSlice(a, chunk[0..@intCast(n)]);
        }
    }
}

/// The first line of a panic message in a child's stderr.
fn panicLine(err: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, err, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "panic: ")) |i| return line[i..];
    }
    return null;
}

/// `--each`: every program file is analyzed as its own program against the
/// base set, the way kotlinc compiles each corpus file on its own. The base
/// set is parsed once and shared read-only; each program gets a fresh
/// `Sema`, in a forked child unless `--in-process`, several at a time.
fn runEach(gpa: Allocator, arena: Allocator, map: *span.SourceMap, serial: *const Serial, base: []const sema.SourceFile, programs: []const sema.SourceFile, opts: EachOptions) u8 {
    const t0 = nowNs();
    var in_process = opts.in_process;
    if (builtin.os.tag == .windows and !in_process) {
        io.writeStderr("note: --each analyzes every program in this process on Windows, which has no fork; a panic in one ends the whole run\n");
        in_process = true;
    }
    const results = arena.alloc(ProgramResult, programs.len) catch return 2;
    @memset(results, .{});
    var shared: EachShared = .{
        .map = map,
        .serial = serial,
        .base = base,
        .programs = programs,
        .results = results,
        .out_arena = arena,
        .dump = opts.dump_path != null,
        .headers_only = opts.headers_only,
        .in_process = in_process,
    };
    const cores = std.Thread.getCpuCount() catch 1;
    var jobs = if (opts.jobs != 0) opts.jobs else @min(cores, 8);
    jobs = @max(1, @min(jobs, programs.len));
    const threads = arena.alloc(?runtime.platform.Thread, jobs) catch return 2;
    for (threads) |*th| th.* = runtime.platform.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, EachShared.worker, .{&shared}) catch null;
    // A worker that failed to start leaves its share to the others; with
    // none started, the calling thread does the work.
    var started: usize = 0;
    for (threads) |th| started += @intFromBool(th != null);
    if (started == 0) shared.worker();
    for (threads) |th| if (th) |t| t.join();
    const t_total = nowNs() - t0;

    var counts: [n_reasons]u64 = @splat(0);
    var resolved: u64 = 0;
    var failed: usize = 0;
    var dump_buf: std.ArrayList(u8) = .empty;
    var first_ok: ?*const ProgramResult = null;
    for (programs, results) |prog, *r| {
        if (!r.ok) {
            failed += 1;
            io.printStdout(gpa, "[sema-file] {s} failed: {s}\n", .{ prog.path, r.failure });
            continue;
        }
        if (first_ok == null) first_ok = r;
        var unresolved: u64 = 0;
        for (r.counts, 0..) |c, k| {
            counts[k] += c;
            unresolved += c;
        }
        resolved += r.resolved;
        io.printStdout(gpa, "[sema-file] {s} resolved={d} unresolved={d} {d}ms\n", .{ prog.path, r.resolved, unresolved, r.ns / 1_000_000 });
        dump_buf.appendSlice(arena, r.tsv) catch return 2;
    }
    var base_unresolved: u64 = 0;
    if (first_ok) |r| {
        for (r.base_counts, 0..) |c, k| {
            counts[k] += c;
            base_unresolved += c;
        }
    }

    if (opts.dump_path) |dp| writeOut(gpa, arena, dp, dump_buf.items) catch return 2;
    if (opts.unresolved_path) |up| {
        var buf: std.ArrayList(u8) = .empty;
        for (programs, results) |prog, *r| {
            for (r.sites) |site| appendUnresolved(arena, &buf, prog.path, site) catch return 2;
        }
        writeOut(gpa, arena, up, buf.items) catch return 2;
    }

    var total: u64 = 0;
    for (counts) |c| total += c;
    io.printStdout(gpa, "[sema] programs={d} failed={d} jobs={d} resolved={d} unresolved={d} base-unresolved={d} total={d}ms\n", .{
        programs.len,
        failed,
        jobs,
        resolved,
        total,
        base_unresolved,
        t_total / 1_000_000,
    });
    inline for (std.meta.fields(Reason)) |f| {
        if (counts[f.value] != 0) io.printStdout(gpa, "[sema] {s:<22} {d}\n", .{ f.name, counts[f.value] });
    }
    if (!opts.quiet) {
        inline for (std.meta.fields(Reason)) |f| {
            var shown: usize = 0;
            outer: for (results) |*r| {
                for (r.sites, r.site_locs) |site, loc| {
                    if (@intFromEnum(site.reason) != f.value) continue;
                    if (shown >= opts.sites_per_reason) break :outer;
                    shown += 1;
                    io.printStdout(gpa, "  {s} {s}: {s}\n", .{ f.name, loc, site.detail });
                }
            }
            if (first_ok) |r| {
                for (r.base_sites, r.base_site_locs) |site, loc| {
                    if (@intFromEnum(site.reason) != f.value) continue;
                    if (shown >= opts.sites_per_reason) break;
                    shown += 1;
                    io.printStdout(gpa, "  {s} {s}: {s}\n", .{ f.name, loc, site.detail });
                }
            }
        }
    }
    if (failed != 0) return 2;
    return if (total == 0) 0 else 1;
}

/// Prints what the analysis knows about one class: kind, supertypes and
/// every declared member.
fn showClass(gpa: Allocator, s: *sema.Sema, fqn: []const u8) void {
    const cls = s.classByFqn(fqn);
    if (cls == .none) {
        io.printStdout(gpa, "[class] {s}: not declared\n", .{fqn});
        return;
    }
    const info = s.syms.classInfo(cls);
    io.printStdout(gpa, "[class] {s} sym={d} kind={s} flags.expect={} superseded={}\n", .{ fqn, cls.int(), @tagName(info.kind), s.syms.flags(cls).expect, s.syms.flags(cls).superseded });
    const sts = sema.headers.supertypes(s, cls) catch return;
    for (sts) |st| {
        const text = sema.render.typeStr(s, s.arena, st) catch "?";
        io.printStdout(gpa, "[class]   super {s}\n", .{text});
    }
    var it = s.syms.classInfo(cls).members.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.items) |m| {
            io.printStdout(gpa, "[class]   {s} {s}\n", .{ @tagName(s.syms.kind(m)), s.str(e.key_ptr.*) });
        }
    }
}

fn printCensus(gpa: Allocator, arena: Allocator, s: *sema.Sema, map: *span.SourceMap, per_reason: usize, quiet: bool, n_files: usize, t_headers: u64, t_total: u64) void {
    const c = &s.census;
    io.printStdout(gpa, "[sema] files={d} symbols={d} types={d} resolved={d} unresolved={d} headers={d}ms total={d}ms\n", .{
        n_files,
        s.syms.count(),
        s.types.items.items.len,
        c.resolved,
        c.total(),
        t_headers / 1_000_000,
        t_total / 1_000_000,
    });
    inline for (std.meta.fields(sema.census.Reason)) |f| {
        const n = c.counts[f.value];
        if (n != 0) io.printStdout(gpa, "[sema] {s:<22} {d}\n", .{ f.name, n });
    }
    if (quiet) return;
    inline for (std.meta.fields(sema.census.Reason)) |f| {
        var shown: usize = 0;
        for (c.sites.items) |site| {
            if (@intFromEnum(site.reason) != f.value) continue;
            if (shown >= per_reason) break;
            shown += 1;
            const loc = location(arena, map, site.sp);
            io.printStdout(gpa, "  {s} {s}: {s}\n", .{ f.name, loc, site.detail });
        }
    }
}

fn location(arena: Allocator, map: *span.SourceMap, sp: span.Span) []const u8 {
    if (sp.file.int() >= map.files.items.len) return "<builtin>";
    const sf = map.get(sp.file);
    const lc = sf.lineCol(sp.start);
    return std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ sf.path, lc.line, lc.col }) catch "?";
}

fn nowNs() u64 {
    return runtime.platform.monotonicNs() orelse 0;
}

/// The serialization pass over the analysis's inputs. The packs are
/// transformed once; a program is transformed together with the packs'
/// original files, so its serializers see theirs, and keeps only what
/// belongs to it.
/// One of a library's own source files, as `klio pack build` collected it.
pub const LibraryFile = struct { path: []const u8, bytes: []const u8 };

/// A library to check: its own files, its id, the libraries it may load
/// (its dependencies and those its features name), and the features of
/// them it asks for, as `<pack>/<feature>`.
pub const Library = struct {
    files: []const LibraryFile,
    id: []const u8,
    deps: []const []const u8,
    feature_specs: []const []const u8,
};

/// What is wrong with a library's own sources, measured as the census
/// measures a pack: the files analyzed as a pack over the stdlib and its
/// installed dependencies, every pack body resolved, its own bodies
/// lowered. A reference sema cannot resolve and a body that does not lower
/// are errors: kotlinc would not compile the library, and the function
/// would run with no body. A bodyless declaration no native binds is not
/// one; the census tracks those. Renders the errors into `out`, in the form
/// the lexer's and parser's take, and answers how many there are.
pub fn checkLibrarySources(gpa: Allocator, arena: Allocator, lib: Library, out: *std.ArrayList(u8)) !usize {
    var map = span.SourceMap.init(arena);
    const saved_map = span.active_map;
    span.active_map = &map;
    defer span.active_map = saved_map;

    var files: std.ArrayList(sema.SourceFile) = .empty;
    var perr: pack.PackError = undefined;
    var stdlib_src = (try stdlib_pack.stdlibSources(arena, null, &perr)) orelse return error.StdlibSourcesMissing;
    defer stdlib_src.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    for (stdlib_src.files) |sf| try addBaseSource(arena, &scratch, &map, &files, sf.rel_path, sf.bytes);
    try addSemaActuals(arena, &scratch, &map, &files);

    var own: std.ArrayList(sema.SourceFile) = .empty;
    for (lib.files) |f| try addSource(arena, &map, &own, f.path, f.bytes, .pack);
    var own_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var own_asts: std.ArrayList(ast.KotlinFile) = .empty;
    for (own.items) |f| {
        try own_ids.put(arena, f.ast.span.file.int(), {});
        try own_asts.append(arena, f.ast.*);
    }
    // Its dependencies, as a loaded pack brings them, never its installed
    // copy.
    var features = cli.parseRequestedFeatures(arena, lib.feature_specs);
    const loaded = pack_cache.loadInstalledPacksOpts(arena, own_asts.items, &map, &features, .{
        .include_stdlib = false,
        .report_failures = false,
        .exclude_lib_ids = &.{lib.id},
        .declared_lib_ids = lib.deps,
        .dep_lib_ids = lib.deps,
    });
    var packs: std.ArrayList(sema.SourceFile) = .empty;
    for (loaded.asts) |*pa| {
        const owned = try arena.create(ast.KotlinFile);
        owned.* = pa.*;
        const path = if (pa.span.file.int() < map.files.items.len) map.get(pa.span.file).path else "<pack>";
        try packs.append(arena, .{ .ast = owned, .path = path, .origin = .pack });
    }
    try packs.appendSlice(arena, own.items);
    const serial = try Serial.init(arena, &map, packs.items);
    try files.appendSlice(arena, serial.packs);

    const s = try sema.Sema.init(arena);
    try s.addFiles(files.items);
    try sema.headers.resolveAllHeaders(s);
    // The stdlib's bodies too: an inline function of it is instantiated
    // from them.
    try s.resolveBodies(&.{ .base, .pack });
    const records = try sema.output.build(s);

    var n: usize = 0;
    var shown: usize = 0;
    for (s.census.sites.items) |site| {
        const fc = s.fileOf(site.file) orelse continue;
        if (!own_ids.contains((fc.ast orelse continue).span.file.int())) continue;
        n += 1;
        if (site.reason != .receiver_unresolved) shown += 1;
    }
    for (s.census.sites.items) |site| {
        const fc = s.fileOf(site.file) orelse continue;
        if (!own_ids.contains((fc.ast orelse continue).span.file.int())) continue;
        // A member of a receiver that did not resolve follows from the
        // receiver's own error.
        if (site.reason == .receiver_unresolved and shown != 0) continue;
        const d = diagnostics.Diagnostic.err(try sema.diagnose.message(s, arena, site), site.sp);
        try diagnostics.render.plain.render(arena, &.{d}, &map, out);
    }

    var lowered_files: std.ArrayList(u32) = .empty;
    for (s.files.items, 0..) |fc, fi| {
        if (own_ids.contains((fc.ast orelse continue).span.file.int())) try lowered_files.append(arena, @intCast(fi));
    }
    const r = try lower_driver.lower_census.run(arena, s, &map, records.files, &.{}, lowered_files.items, hostBinding(gpa));
    for (r.entries) |e| {
        if (e.kind == .unbound_native) continue;
        const id = e.file orelse continue;
        if (!own_ids.contains(id)) continue;
        n += 1;
        // What did not resolve does not lower either: said once above.
        if (shown != 0) continue;
        try out.print(arena, "{s}: error: `{s}` does not lower: {s}\n", .{ e.where, e.func, e.msg });
    }
    return n;
}

const Serial = struct {
    pack_originals: []const ast.KotlinFile,
    /// The transformed packs followed by their generated files.
    packs: []const sema.SourceFile,
    /// How many generated files the packs alone produce.
    n_pack_generated: usize,
    /// The packs' `@MetaSerializable` annotation classes: a program class
    /// carrying one is serializable without spelling `@Serializable`.
    pack_meta: std.StringHashMap(void),

    fn init(a: Allocator, map: *span.SourceMap, pack_files: []const sema.SourceFile) !Serial {
        const originals = try a.alloc(ast.KotlinFile, pack_files.len);
        for (pack_files, originals) |f, *o| o.* = f.ast.*;
        const out = try transform(a, map, originals, "");
        const packs = try a.alloc(sema.SourceFile, out.len);
        for (out, packs, 0..) |*f, *sf, k| {
            sf.* = if (k < pack_files.len)
                .{ .ast = f, .path = pack_files[k].path, .origin = .pack }
            else
                .{ .ast = f, .path = map.get(f.span.file).path, .origin = .pack, .generated = true };
        }
        return .{
            .pack_originals = originals,
            .packs = packs,
            .n_pack_generated = out.len - pack_files.len,
            .pack_meta = try serialization_pass.metaSerializableNames(a, originals),
        };
    }

    /// What an image baked from these packs keeps for a run that does not
    /// parse them: their meta-serializable annotations' names, which tell
    /// whether the pass rewrites a program.
    fn record(self: *const Serial, a: Allocator) ![]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var it = self.pack_meta.keyIterator();
        while (it.next()) |k| try names.append(a, k.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        const bytes = try codec.encodeBytes([]const []const u8, std.heap.smp_allocator, &names.items);
        defer std.heap.smp_allocator.free(bytes);
        return a.dupe(u8, bytes);
    }

    /// The programs as sema should see them: transformed, followed by the
    /// files generated for them. Programs that declare nothing serializable
    /// come back as they are.
    fn programFiles(self: *const Serial, a: Allocator, map: *span.SourceMap, programs: []const sema.SourceFile) ![]const sema.SourceFile {
        var any = false;
        for (programs) |p| {
            any = any or serialization_pass.fileMentionsSerializable(p.ast) or
                serialization_pass.fileUsesMetaSerializable(p.ast, &self.pack_meta);
        }
        if (!any) return programs;
        const n_p = self.pack_originals.len;
        const input = try a.alloc(ast.KotlinFile, n_p + programs.len);
        @memcpy(input[0..n_p], self.pack_originals);
        for (programs, input[n_p..]) |p, *f| f.* = p.ast.*;
        const name = if (programs.len == 1) programs[0].path else "";
        const out = try transform(a, map, input, name);
        var files: std.ArrayList(sema.SourceFile) = .empty;
        for (programs, out[n_p..input.len]) |p, *f| try files.append(a, .{ .ast = f, .path = p.path, .origin = .program });
        for (out[input.len + self.n_pack_generated ..]) |*f| {
            try files.append(a, .{ .ast = f, .path = map.get(f.span.file).path, .origin = .program, .generated = true });
        }
        return files.items;
    }

    /// Runs the pass and re-parses each generated file under the id of
    /// the map entry the pass registered for it, so its spans resolve
    /// through the map like any other file's. `owner` names the program a
    /// generated file belongs to, when there is one.
    fn transform(a: Allocator, map: *span.SourceMap, input: []const ast.KotlinFile, owner: []const u8) ![]ast.KotlinFile {
        const out = try serialization_pass.transformFiles(a, input);
        for (out[input.len..]) |*gf| {
            const want = try std.fmt.allocPrint(a, "<generated-serializers-{d}>", .{gf.span.file.int()});
            var k = map.files.items.len;
            const idx = while (k > 0) {
                k -= 1;
                if (std.mem.eql(u8, map.files.items[k].path, want)) break k;
            } else return error.GeneratedFileNotRegistered;
            const entry = &map.files.items[idx];
            if (owner.len != 0) entry.path = try std.fmt.allocPrint(a, "{s}<serializers>", .{owner});
            const id = span.FileId.from(@intCast(idx));
            var lx = try lexer.Lexer.init(a, id, entry.source);
            const lexed = try lx.tokenize();
            const p = parser.Parser.new(a, id, entry.source, lexed.tokens, lexed.strings);
            gf.* = p.parseFile();
        }
        return out;
    }
};

/// The `--feature` flags of a program's `// Run with: klio run ...` header
/// line, the convention the example corpus uses for the packs it needs.
fn runWithFeatures(a: Allocator, source: []const u8, specs: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 12) return;
        const at = std.mem.indexOf(u8, line, "Run with: klio run") orelse continue;
        var words = std.mem.tokenizeAny(u8, line[at + "Run with: klio run".len ..], " \t\r");
        while (words.next()) |w| {
            if (std.mem.eql(u8, w, "--feature")) {
                if (words.next()) |v| try specs.append(a, v);
            } else if (std.mem.startsWith(u8, w, "--feature=")) {
                try specs.append(a, w["--feature=".len..]);
            }
        }
        return;
    }
}

/// The lex and parse errors of the program files a run analyzes, rendered,
/// and how many files have them.
const Syntax = struct {
    text: std.ArrayList(u8) = .empty,
    files: usize = 0,
};

/// A program file, or every `.kt` file below a program directory.
fn addPath(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), path: []const u8, syntax: *Syntax) !void {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    const st = try std.Io.Dir.cwd().statFile(fio, path, .{});
    if (st.kind == .directory) return addDir(arena, map, files, path, syntax);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(fio, path, arena, .unlimited);
    try addSourceReporting(arena, map, files, path, bytes, .program, syntax, null);
}

/// Every `.kt` file below `dir_path`, recursively, sorted by path the way
/// the oracle orders them.
fn addDir(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), dir_path: []const u8, syntax: *Syntax) !void {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    for (try ktFilesBelow(arena, dir_path)) |full| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(fio, full, arena, .unlimited);
        try addSourceReporting(arena, map, files, full, bytes, .program, syntax, null);
    }
}

/// The paths of the `.kt` files below `dir_path_in`, sorted.
fn ktFilesBelow(arena: Allocator, dir_path_in: []const u8) ![]const []const u8 {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    const dir_path = std.mem.trimEnd(u8, dir_path_in, "/");
    var dir = try std.Io.Dir.cwd().openDir(fio, if (dir_path.len == 0) "/" else dir_path, .{ .iterate = true });
    defer dir.close(fio);
    var rels: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(fio)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".kt")) continue;
        try rels.append(arena, try arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, rels.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const out = try arena.alloc([]const u8, rels.items.len);
    for (rels.items, out) |rel, *o| o.* = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, rel });
    return out;
}

fn addSource(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), path: []const u8, bytes: []const u8, origin: sema.Origin) !void {
    return addSourceReporting(arena, map, files, path, bytes, origin, null, null);
}

/// `addSource` for a base file: parsed in `scratch`, so the run keeps only
/// its tree (`parser.parseMoved`); one that does not parse is added as
/// `addSource` adds it.
/// The file keeps the map's copies of `path` and `bytes`: the stdlib's
/// sources are freed once they are added.
fn addBaseSource(arena: Allocator, scratch: *std.heap.ArenaAllocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), path: []const u8, bytes: []const u8) !void {
    const id = try map.add(path, bytes);
    const src = map.get(id).source;
    const owned_path = map.get(id).path;
    const tree = try parser.parseMoved(arena, scratch, id, src) orelse
        return parseAdded(arena, map, files, id, owned_path, .base, null, null);
    const file_ast = try arena.create(ast.KotlinFile);
    file_ast.* = tree;
    try files.append(arena, .{ .ast = file_ast, .path = owned_path, .origin = .base });
}

/// `addSource`, rendering the file's diagnostics into `syntax` when it has
/// a lex or parse error, and adding every one of them to `diags`.
fn addSourceReporting(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), path: []const u8, bytes: []const u8, origin: sema.Origin, syntax: ?*Syntax, diags: ?*std.ArrayList(diagnostics.Diagnostic)) !void {
    return parseAdded(arena, map, files, try map.add(path, bytes), path, origin, syntax, diags);
}

/// `addSourceReporting` for the file `id` already in `map`.
fn parseAdded(arena: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), id: span.FileId, path: []const u8, origin: sema.Origin, syntax: ?*Syntax, diags: ?*std.ArrayList(diagnostics.Diagnostic)) !void {
    const src = map.get(id).source;
    var lx = try lexer.Lexer.init(arena, id, src);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(arena, id, src, lexed.tokens, lexed.strings);
    const file_ast = try arena.create(ast.KotlinFile);
    // A program parses with the language features its `// Run with:` line
    // turns on, as `klio run` would, and only it.
    const saved_language = parser.language;
    defer parser.language = saved_language;
    if (origin == .program) runWithLanguage(src);
    file_ast.* = p.parseFile();
    if (syntax) |out| {
        if (lexed.diagnostics.hasErrors() or p.diagnostics.hasErrors()) {
            try lexed.diagnostics.render(arena, map, &out.text);
            try p.diagnostics.render(arena, map, &out.text);
            out.files += 1;
        }
    }
    if (diags) |out| {
        try out.appendSlice(arena, lexed.diagnostics.diags());
        try out.appendSlice(arena, p.diagnostics.diags());
    }
    try files.append(arena, .{ .ast = file_ast, .path = path, .origin = origin });
}

/// The `--language=+Feature` flags of a program's `// Run with: klio run`
/// header line, applied to the parser.
fn runWithLanguage(source: []const u8) void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 12) return;
        const at = std.mem.indexOf(u8, line, "Run with: klio run") orelse continue;
        var words = std.mem.tokenizeAny(u8, line[at + "Run with: klio run".len ..], " \t\r");
        while (words.next()) |w| {
            if (std.mem.startsWith(u8, w, "--language=")) {
                var specs = std.mem.splitScalar(u8, w["--language=".len..], ',');
                while (specs.next()) |spec| _ = parser.setLanguageFeature(spec);
            }
        }
        return;
    }
}
