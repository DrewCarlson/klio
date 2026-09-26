//! `klio run`: runs a program through sema, the bridge and lowering from
//! sema, then the VM on the resolved instructions. The base comes from its
//! image when one is cached.

const std = @import("std");
const span = @import("span");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const lower_driver = @import("lower_driver");
const ir = @import("ir");
const sema = @import("sema");
const diagnostics = @import("diagnostics");
const compose_ui = @import("compose_ui");

const io = @import("io.zig");
const sema_cmd = @import("sema_cmd.zig");
const sema_base_cache = @import("sema_base_cache.zig");
const sema_diagnostics = @import("sema_diagnostics.zig");

const Allocator = std.mem.Allocator;
const pipeline = lower_driver.pipeline;

const ExecCtx = struct { a: Allocator, gpa: Allocator, br: *ir.bridge.Bridge, main: ir.FuncId, out: runtime.Output, args: []const []const u8 };
const ExecOutcome = struct { exec: ?pipeline.Exec = null, err: ?anyerror = null };

fn execEntry(ctx: ExecCtx) ExecOutcome {
    const exec = pipeline.execute(ctx.a, ctx.gpa, ctx.br, ctx.main, ctx.out, .{ .args = ctx.args, .keep_vm = compose_ui.hostedActive }) catch |e| return .{ .err = e };
    return .{ .exec = exec };
}

/// The run's build over the cached base image, baked first when there is
/// none; over the base analyzed afresh when there is no cache or the image
/// is not of this base.
pub fn buildRun(gpa: Allocator, arena: Allocator, map: *const span.SourceMap, src: pipeline.Sources, binding: pipeline.Binding) !pipeline.Built {
    if (sema_base_cache.disabled()) return pipeline.build(arena, src, binding);
    const path = sema_base_cache.pathFor(arena, map, src.base) orelse return pipeline.build(arena, src, binding);
    if (sema_base_cache.read(arena, path)) |bytes| {
        if (pipeline.buildOnBase(arena, src, binding, bytes)) |b| return b else |e| switch (e) {
            error.Stale, error.Malformed => {},
            else => return e,
        }
    }
    const bytes = try bakeBase(gpa, arena, src.base, binding, path);
    return pipeline.buildOnBase(arena, src, binding, bytes) catch |e| switch (e) {
        error.Stale, error.Malformed => pipeline.build(arena, src, binding),
        else => e,
    };
}

/// Sema over `src` as `buildRun` analyzes it, with nothing lowered: over
/// the cached base image, baked first when there is none.
pub fn analyzeRun(gpa: Allocator, arena: Allocator, map: *const span.SourceMap, src: pipeline.Sources, binding: pipeline.Binding) !*sema.Sema {
    if (sema_base_cache.disabled()) return pipeline.analyze(arena, src);
    const path = sema_base_cache.pathFor(arena, map, src.base) orelse return pipeline.analyze(arena, src);
    if (sema_base_cache.read(arena, path)) |bytes| {
        if (pipeline.analyzeOnBase(arena, src, binding, bytes)) |s| return s else |e| switch (e) {
            error.Stale, error.Malformed => {},
            else => return e,
        }
    }
    const bytes = try bakeBase(gpa, arena, src.base, binding, path);
    return pipeline.analyzeOnBase(arena, src, binding, bytes) catch |e| switch (e) {
        error.Stale, error.Malformed => pipeline.analyze(arena, src),
        else => e,
    };
}

/// The base image of `base`: the cached one, else the one the build
/// installed, else baked now and cached. Owned by `arena`.
pub fn baseImage(gpa: Allocator, arena: Allocator, map: *const span.SourceMap, base: []const sema.SourceFile, binding: pipeline.Binding) ![]const u8 {
    const path = if (sema_base_cache.disabled()) null else sema_base_cache.pathFor(arena, map, base);
    if (path) |p| {
        if (sema_base_cache.read(arena, p)) |bytes| {
            if (pipeline.base_image.header(bytes) != null) return bytes;
        }
    }
    return bakeBase(gpa, arena, base, binding, path);
}

/// Bakes the base image of `base` afresh into `arena`, whatever the cache
/// holds, and caches it.
pub fn bakeBaseFresh(gpa: Allocator, arena: Allocator, map: *const span.SourceMap, base: []const sema.SourceFile, binding: pipeline.Binding) ![]const u8 {
    const path = if (sema_base_cache.disabled()) null else sema_base_cache.pathFor(arena, map, base);
    return bakeBase(gpa, arena, base, binding, path);
}

/// Bakes the base image of `base` into `arena`, and writes it to the cache
/// at `path` when there is one.
fn bakeBase(gpa: Allocator, arena: Allocator, base: []const sema.SourceFile, binding: pipeline.Binding, path: ?[]const u8) ![]const u8 {
    // The bake's cells are permanent, so it shares the run's arena.
    var t = pipeline.Timing.start();
    const baked = try pipeline.bakeBase(arena, gpa, base, binding);
    defer gpa.free(baked);
    t.mark("bake base image");
    if (path) |p| sema_base_cache.write(arena, p, baked);
    return arena.dupe(u8, baked);
}

/// The exit code of a program that did not load, with why on stderr: 1 for
/// a program that does not read or parse (its diagnostics are already
/// printed), 2 for anything else.
pub fn loadFailed(gpa: Allocator, e: anyerror, report: *const sema_cmd.LoadReport) u8 {
    switch (e) {
        error.ProgramSyntax => return 1,
        error.ProgramUnreadable => {
            io.printStderr(gpa, "error: cannot read {s}: ReadFailed\n", .{report.unreadable.?.path});
            return 1;
        },
        else => {
            io.printStderr(gpa, "error: cannot load the program: {s}\n", .{@errorName(e)});
            return 2;
        },
    }
}

/// A run's allocations: the build's arena and its source map, on the heap,
/// because a hosted UI keeps using both after `run` returns.
pub const RunMemory = struct {
    arena_state: *std.heap.ArenaAllocator,
    map: *span.SourceMap,
    /// The active source map this run's replaced, back in place after it.
    prev_map: ?*const span.SourceMap,

    pub fn init() !RunMemory {
        const state = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        state.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const map = try state.allocator().create(span.SourceMap);
        map.* = span.SourceMap.init(state.allocator());
        const prev = span.active_map;
        span.active_map = map;
        return .{ .arena_state = state, .map = map, .prev_map = prev };
    }

    pub fn arena(self: RunMemory) Allocator {
        return self.arena_state.allocator();
    }

    /// Frees the run, unless a hosted UI still re-enters its VM.
    pub fn deinit(self: RunMemory) void {
        if (compose_ui.hostedActive()) return;
        span.active_map = self.prev_map;
        self.arena_state.deinit();
        std.heap.page_allocator.destroy(self.arena_state);
    }
};

pub fn run(gpa: Allocator, paths: []const []const u8, feature_specs: []const []const u8) u8 {
    pipeline.hooks.start();
    const t_start = runtime.clockMonotonicNanos();
    const mem = RunMemory.init() catch return 2;
    defer mem.deinit();
    const arena = mem.arena();
    const map = mem.map;

    const p = switch (prepare(gpa, mem, paths, .{ .feature_specs = feature_specs, .report_pack_failures = true }, null)) {
        .ok => |ok| ok,
        .exit => |code| return code,
    };
    var t = pipeline.Timing.start();
    const t_built = runtime.clockMonotonicNanos();
    const code = runBuilt(gpa, arena, map, p.src.program, &p.built, &.{});
    t.mark("execute");
    runtime.prof.phaseMark("execute");
    if (pipeline.hooks.traceRunOn()) {
        const t_end = runtime.clockMonotonicNanos();
        std.debug.print("[run] startup {d}ms, prepare {d}ms, execute {d}ms, {d}ms after start (rss {d}mb)\n", .{
            (t_start -| runtime.process_start_ns) / 1_000_000,
            (t_built - t_start) / 1_000_000,
            (t_end - t_built) / 1_000_000,
            (t_end -| runtime.process_start_ns) / 1_000_000,
            (runtime.currentRssKb() orelse 0) / 1024,
        });
    }
    return code;
}

pub const Prepared = struct { src: pipeline.Sources, built: pipeline.Built };

/// A base image to build over, and what to tell the user to do when it is
/// not of this klio or of the base `LoadOptions.base` names.
pub const GivenImage = struct { bytes: []const u8, remedy: []const u8 };

/// Loads `paths` and builds them as `klio run` does, into `mem`. When that
/// fails, why is printed and `.exit` holds the exit code. With `image`, the
/// build extends that base image instead of one from the cache.
pub fn prepare(gpa: Allocator, mem: RunMemory, paths: []const []const u8, opts: sema_cmd.LoadOptions, image: ?GivenImage) union(enum) { ok: Prepared, exit: u8 } {
    var t = pipeline.Timing.start();
    var report: sema_cmd.LoadReport = .{};
    var load_opts = opts;
    load_opts.report = &report;
    const loaded = sema_cmd.loadSources(mem.arena(), mem.map, paths, load_opts);
    io.writeStderr(report.syntax.items);
    const src = loaded catch |e| return .{ .exit = loadFailed(gpa, e, &report) };
    t.mark("load and parse");
    runtime.prof.phaseMark("load and parse");
    const binding = sema_cmd.hostBinding(gpa);
    if (image) |given| {
        const built = pipeline.buildOnBase(mem.arena(), src, binding, given.bytes) catch |e| {
            switch (e) {
                error.Stale => io.printStderr(gpa, "error: the base image was baked by another klio or from another base; {s}\n", .{given.remedy}),
                error.Malformed => io.printStderr(gpa, "error: the base image is malformed; {s}\n", .{given.remedy}),
                else => io.printStderr(gpa, "error: the sema pipeline failed: {s}\n", .{@errorName(e)}),
            }
            return .{ .exit = if (e == error.Stale or e == error.Malformed) 1 else 2 };
        };
        t.mark("build");
        runtime.prof.phaseMark("build");
        return .{ .ok = .{ .src = src, .built = built } };
    }
    const built = buildRun(gpa, mem.arena(), mem.map, src, binding) catch |e| {
        io.printStderr(gpa, "error: the sema pipeline failed: {s}\n", .{@errorName(e)});
        return .{ .exit = 2 };
    };
    t.mark("build");
    runtime.prof.phaseMark("build");
    return .{ .ok = .{ .src = src, .built = built } };
}

/// Runs a built program: what sema could not resolve and what did not lower
/// in `program`'s files is an error, then `main` runs with `args`. The exit
/// code: 0, 1 for an error in the program or an uncaught throwable, 2 when
/// the run itself failed.
pub fn runBuilt(gpa: Allocator, arena: Allocator, map: *const span.SourceMap, program: []const sema.SourceFile, built: *const pipeline.Built, args: []const []const u8) u8 {
    if (reportProgramErrors(gpa, arena, map, program, built) != 0) return 1;
    const s = built.s;
    const found = pipeline.mainOf(s) catch {
        io.printStderr(gpa, "error: out of memory\n", .{});
        return 2;
    };
    const main_sym = found orelse {
        io.printStderr(gpa, "error: no `main` function in {s}\n", .{pipeline.mainFileName(s)});
        return 1;
    };
    const main = built.br.funcOfOpt(main_sym) orelse {
        io.printStderr(gpa, "error: `main` has no id\n", .{});
        return 1;
    };
    return runMain(gpa, arena, built, main, args);
}

/// Runs `main` of a built program with `args`, on the big stack.
pub fn runMain(gpa: Allocator, arena: Allocator, built: *const pipeline.Built, main: ir.FuncId, args: []const []const u8) u8 {
    var stdout = io.StdoutSink{};
    // On the big stack the name-resolving run uses, so deep recursion in
    // the program has the same room.
    const ran = runtime.runOnBigStackMainThread(ExecCtx, ExecOutcome, execEntry, .{ .a = arena, .gpa = gpa, .br = built.br, .main = main, .out = stdout.output(), .args = args });
    const exec = ran.exec orelse {
        io.printStderr(gpa, "error: {s}\n", .{@errorName(ran.err.?)});
        return 2;
    };

    return switch (exec.result) {
        .ok => 0,
        .threw => blk: {
            io.printStderr(gpa, "{s}\n", .{exec.diag});
            break :blk 1;
        },
        .failed => blk: {
            io.printStderr(gpa, "runtime error: {s}\n", .{exec.diag});
            break :blk 1;
        },
    };
}

/// Prints what sema found wrong in `program`'s files and what did not
/// lower there, and answers how many. The base's failures are only counted
/// (`KLIO_SEMA_PIPELINE_BASE` prints them): only a body the run reaches
/// matters.
pub fn reportProgramErrors(gpa: Allocator, arena: Allocator, map: *const span.SourceMap, program: []const sema.SourceFile, built: *const pipeline.Built) usize {
    var out: std.ArrayList(u8) = .empty;
    const n = programDiagnostics(arena, map, program, built, .Error, &out) catch |e| {
        io.printStderr(gpa, "error: cannot report the program's errors: {s}\n", .{@errorName(e)});
        return 1;
    };
    io.writeStderr(out.items);
    var base_errors: usize = 0;
    for (built.prog.errors.items) |le| {
        if (!inProgram(map, program, le.span)) base_errors += 1;
    }
    if (base_errors != 0 and std.c.getenv("KLIO_SEMA_PIPELINE_BASE") != null) {
        for (built.prog.errors.items) |le| {
            const f = built.br.m.funcs.items[le.func.int()];
            io.printStderr(gpa, "[base] {s}: in {s}: {s}\n", .{ pipeline.where(arena, map, le.span) catch "?", f.fqn, le.msg });
        }
    }
    return n;
}

/// Whether a site of the program's that is shown lies within `sp` or
/// holds it.
fn reportedAt(sites: []const sema.census.Site, sp: span.Span) bool {
    for (sites) |site| {
        if (site.sp.file.int() != sp.file.int()) continue;
        if (site.sp.start <= sp.end and sp.start <= site.sp.end) return true;
    }
    return false;
}

fn inProgram(map: *const span.SourceMap, program: []const sema.SourceFile, sp: span.Span) bool {
    const file = if (sp.file.int() < map.files.items.len) map.get(sp.file).path else "";
    for (program) |p| {
        if (std.mem.eql(u8, p.path, file)) return true;
    }
    return false;
}

/// How many of the program's imports name nothing: each fails the program
/// as kotlinc fails its compilation, whatever `programDiagnostics`'
/// severity for the rest.
pub fn programImportErrors(built: *const pipeline.Built) usize {
    const s = built.s;
    var n: usize = 0;
    for (s.census.sites.items) |site| {
        const fc = s.fileOf(site.file) orelse continue;
        if (fc.origin == .program and site.reason == .unresolved_import) n += 1;
    }
    return n;
}

/// Renders into `out`, with `severity`, what sema found wrong in
/// `program`'s files (`sema_diagnostics.collect`, warnings aside) and what
/// did not lower there, in the form the lexer's and parser's diagnostics
/// take; answers how many there are.
pub fn programDiagnostics(arena: Allocator, map: *const span.SourceMap, program: []const sema.SourceFile, built: *const pipeline.Built, severity: diagnostics.Severity, out: *std.ArrayList(u8)) !usize {
    const s = built.s;
    const found = try sema_diagnostics.collect(arena, s, .{ .error_severity = severity, .warnings = false });
    try diagnostics.render.plain.renderWith(arena, found.list, map, out, .{ .codes = false });
    var n: usize = found.sites.len;
    // What did not lower follows from what did not resolve where sema
    // reported something at its place; anywhere else, it is klio's to fix,
    // and shown whatever sema found elsewhere.
    for (built.prog.errors.items) |le| {
        if (!inProgram(map, program, le.span)) continue;
        n += 1;
        if (found.primary != 0 and reportedAt(found.sites, le.span)) continue;
        const f = built.br.m.funcs.items[le.func.int()];
        var d = diagnostics.Diagnostic.err(try std.fmt.allocPrint(arena, "klio cannot run `{s}`: {s}", .{ f.fqn, le.msg }), le.span);
        d.severity = severity;
        try diagnostics.render.plain.render(arena, &.{d}, map, out);
    }
    return n;
}
