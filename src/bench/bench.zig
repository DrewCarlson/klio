//! Shared bench plumbing: corpus loader, per-stage pipeline runners, timing,
//! and the JSON result schema. Alloc-light so it does not perturb its numbers.

const std = @import("std");

const ast = @import("ast");
const ir = @import("ir");
const klio_child = @import("klio_child");
const lexer = @import("lexer");
const lower_driver = @import("lower_driver");
const pack = @import("pack");
const parser = @import("parser");
const runtime = @import("runtime");
const sema = @import("sema");
const span = @import("span");
const stdlib = @import("stdlib");
const stdlib_pack = @import("stdlib_pack");

const KotlinFile = ast.KotlinFile;
const LexResult = lexer.LexResult;
const Lexer = lexer.Lexer;
const FileId = span.FileId;
const SourceMap = span.SourceMap;
const bridge = ir.bridge;

pub const refrunner = @import("refrunner.zig");
pub const schema = @import("schema.zig");
pub const main = @import("main.zig");

pub const BenchRecord = schema.BenchRecord;
pub const BenchReport = schema.BenchReport;
pub const RegressionLevel = schema.RegressionLevel;

/// Bench corpus path, relative to the process cwd. Caller owns the result.
pub fn corpusRoot(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return allocator.dupe(u8, "tests/fixtures/bench_corpus");
}

/// Every `.kt` under `dir`, sorted. Caller owns the slice and each path.
pub fn collectKt(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) std.mem.Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    try collectKtInto(allocator, io, dir, &out);
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn collectKtInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    out: *std.ArrayList([]u8),
) std.mem.Allocator.Error!void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        const path = std.fs.path.join(allocator, &.{ dir, entry.name }) catch continue;
        if (entry.kind == .directory) {
            collectKtInto(allocator, io, path, out) catch {};
            allocator.free(path);
        } else if (std.mem.endsWith(u8, entry.name, ".kt")) {
            try out.append(allocator, path);
        } else {
            allocator.free(path);
        }
    }
}

pub const Program = struct {
    path: []const u8,
    source: []const u8,
    allocator: std.mem.Allocator,

    /// `path` is duplicated into `allocator`.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Program {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        const owned_path = try allocator.dupe(u8, path);
        return .{ .path = owned_path, .source = source, .allocator = allocator };
    }

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.path);
        self.allocator.free(self.source);
    }

    /// Stable JSON label, `game/entity_tick`. Caller owns it.
    pub fn label(self: *const Program, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const root = try corpusRoot(allocator);
        defer allocator.free(root);
        var rel = self.path;
        if (std.mem.startsWith(u8, rel, root)) {
            rel = rel[root.len..];
            while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
        }
        if (std.mem.endsWith(u8, rel, ".kt")) rel = rel[0 .. rel.len - 3];
        const owned = try allocator.dupe(u8, rel);
        for (owned) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        return owned;
    }
};

pub const Lexed = struct {
    id: FileId,
    source: []const u8,
    result: LexResult,
};

pub fn lex(allocator: std.mem.Allocator, map: *SourceMap, prog: *const Program) !Lexed {
    const id = try map.add(prog.path, prog.source);
    var lx = try Lexer.init(allocator, id, prog.source);
    const result = try lx.tokenize();
    return .{ .id = id, .source = prog.source, .result = result };
}

pub fn parse(allocator: std.mem.Allocator, lexed: *const Lexed) KotlinFile {
    var p = parser.Parser.new(allocator, lexed.id, lexed.source, lexed.result.tokens, lexed.result.strings);
    return p.parseFile();
}

/// The base a program is analyzed against: the stdlib sources and the
/// declarations sema needs as Kotlin, read once.
pub const BaseSources = struct {
    files: []const Source,

    pub const Source = struct { path: []const u8, text: []const u8 };

    pub fn load(a: std.mem.Allocator, io: std.Io) !BaseSources {
        var out: std.ArrayList(Source) = .empty;
        var perr: pack.PackError = undefined;
        var src = (try stdlib_pack.stdlibSources(a, null, &perr)) orelse return error.StdlibSourcesMissing;
        for (src.files) |sf| try out.append(a, .{ .path = try a.dupe(u8, sf.rel_path), .text = try a.dupe(u8, sf.bytes) });
        src.deinit();
        for (stdlib.pack_builder.SEMA_ACTUAL_FILES) |name| {
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ stdlib.pack_builder.SEMA_ACTUALS_DIR, name });
            const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
            try out.append(a, .{ .path = path, .text = text });
        }
        return .{ .files = out.items };
    }
};

/// The stages sema and lowering run over the base and a program, as a cold
/// `klio run` (`KLIO_SEMA_IMAGE=0`) runs them.
pub const Stage = enum { headers, bodies, records, bridge, lower };
pub const n_stages = std.meta.fields(Stage).len;

fn hostNative(fqn: []const u8) ?runtime.StdlibFn {
    return stdlib.implementation(fqn);
}

/// Parses the base and `prog` into `a` (untimed), then runs every stage and
/// returns each one's nanoseconds.
pub fn runStages(a: std.mem.Allocator, base: *const BaseSources, prog: *const Program) ![n_stages]u64 {
    var map = SourceMap.init(a);
    var base_files: std.ArrayList(sema.SourceFile) = .empty;
    for (base.files) |f| try lower_driver.parseInto(a, &map, &base_files, f.path, f.text, .base);
    var program: std.ArrayList(sema.SourceFile) = .empty;
    try lower_driver.parseInto(a, &map, &program, prog.path, prog.source, .program);

    var ns: [n_stages]u64 = undefined;
    var t = Timer.start();
    const s = try sema.Sema.init(a);
    try s.addFiles(base_files.items);
    const base_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try s.addFiles(program.items);
    const program_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try sema.headers.resolveAllHeaders(s);
    ns[@intFromEnum(Stage.headers)] = t.lap();
    try s.resolveBodies(&.{ .base, .pack, .program });
    ns[@intFromEnum(Stage.bodies)] = t.lap();
    const out = try sema.output.build(s);
    ns[@intFromEnum(Stage.records)] = t.lap();
    const saved_perm = runtime.gc.allocPerm();
    runtime.gc.setAllocPerm(true);
    defer runtime.gc.setAllocPerm(saved_perm);
    const br = try bridge.build(a, s, .{
        .natives = hostNative,
        .host_symbol = stdlib.declarationHostSymbol,
        .host_members = true,
        .spread_varargs = true,
        .constructors = stdlib.constructorNative,
        .records = out.files,
        .layers = try a.dupe(bridge.Layer, &.{ base_layer, program_layer }),
    });
    ns[@intFromEnum(Stage.bridge)] = t.lap();
    _ = try ir.lower_sema.lowerProgram(a, s, br);
    ns[@intFromEnum(Stage.lower)] = t.lap();
    return ns;
}

/// Captured stdout owned by the caller, or a failure description owned by
/// the caller.
pub const RunOutcome = union(enum) {
    ok: []u8,
    err: []u8,
};

/// Where the end-to-end runs keep their base image: a home of their own, so
/// a bench never installs packs it does not use.
pub const E2E_HOME = "/tmp/klio_bench_home";

/// Runs `prog` as a user does, through the harness binary (`KLIO_ITEST_BIN`)
/// over the base image cached in `E2E_HOME`.
pub fn runFull(allocator: std.mem.Allocator, prog: *const Program) !RunOutcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try klio_child.envFor(a, E2E_HOME);
    const r = try klio_child.runKlio(a, &env, &.{ klio_child.bin(), "run", prog.path }, .{});
    if (r.exitedZero()) return .{ .ok = try allocator.dupe(u8, r.stdout) };
    return .{ .err = try std.fmt.allocPrint(allocator, "exit {d}: {s}", .{ r.code(), r.stderr }) };
}

/// Nanoseconds on the monotonic clock since `start` or the last `lap`.
pub const Timer = struct {
    last: u64,

    pub fn start() Timer {
        return .{ .last = runtime.clockMonotonicNanos() };
    }

    pub fn read(self: *const Timer) u64 {
        return runtime.clockMonotonicNanos() - self.last;
    }

    pub fn lap(self: *Timer) u64 {
        const now = runtime.clockMonotonicNanos();
        defer self.last = now;
        return now - self.last;
    }
};

pub const Timing = struct {
    iters: u64,
    median_ns: u64,
    p99_ns: u64,

    fn of(samples: []u64) Timing {
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        const n = samples.len;
        return .{ .iters = n, .median_ns = samples[n / 2], .p99_ns = samples[@min(n * 99 / 100, n - 1)] };
    }
};

/// Time `ctx.call()` over at least `min_total_ns`; returns median, p99, iters.
pub fn timeIters(
    allocator: std.mem.Allocator,
    ctx: anytype,
    min_total_ns: u64,
    min_iters: u32,
) std.mem.Allocator.Error!Timing {
    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(allocator);
    var timer = Timer.start();
    const start_all = timer.read();
    while (samples.items.len < min_iters or (timer.read() - start_all) < min_total_ns) {
        var t = Timer.start();
        ctx.call();
        try samples.append(allocator, t.read());
        if (samples.items.len > 10_000) break;
    }
    return Timing.of(samples.items);
}

pub const StageTimings = struct {
    lex: Timing,
    parse: Timing,
    stages: [n_stages]Timing,
    e2e: Timing,
};

/// Time each stage independently against a fresh input, so one stage's cache
/// effects do not help the next.
pub fn timePipelineStages(
    allocator: std.mem.Allocator,
    base: *const BaseSources,
    prog: *const Program,
    budget_per_stage_ns: u64,
) !StageTimings {
    const lex_ctx = struct {
        a: std.mem.Allocator,
        p: *const Program,
        fn call(self: @This()) void {
            var map = SourceMap.init(self.a);
            defer map.deinit();
            var lexed = lex(self.a, &map, self.p) catch return;
            lexed.result.deinit(self.a);
        }
    }{ .a = allocator, .p = prog };
    const lex_t = try timeIters(allocator, lex_ctx, budget_per_stage_ns, 5);

    const parse_ctx = struct {
        a: std.mem.Allocator,
        p: *const Program,
        fn call(self: @This()) void {
            var arena = std.heap.ArenaAllocator.init(self.a);
            defer arena.deinit();
            const aa = arena.allocator();
            var map = SourceMap.init(aa);
            var lexed = lex(aa, &map, self.p) catch return;
            _ = parse(aa, &lexed);
        }
    }{ .a = allocator, .p = prog };
    const parse_t = try timeIters(allocator, parse_ctx, budget_per_stage_ns, 5);

    // One pass times every stage; the budget bounds the passes.
    var samples: [n_stages]std.ArrayList(u64) = @splat(.empty);
    defer for (&samples) |*s| s.deinit(allocator);
    var timer = Timer.start();
    while (samples[0].items.len < 3 or timer.read() < budget_per_stage_ns * n_stages) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const ns = try runStages(arena.allocator(), base, prog);
        for (&samples, ns) |*s, v| try s.append(allocator, v);
        if (samples[0].items.len >= 50) break;
    }
    var stages: [n_stages]Timing = undefined;
    for (&stages, &samples) |*st, *s| st.* = Timing.of(s.items);

    const e2e_ctx = struct {
        a: std.mem.Allocator,
        p: *const Program,
        fn call(self: @This()) void {
            const outcome = runFull(self.a, self.p) catch return;
            switch (outcome) {
                inline else => |s| self.a.free(s),
            }
        }
    }{ .a = allocator, .p = prog };
    const e2e_t = try timeIters(allocator, e2e_ctx, budget_per_stage_ns, 3);

    return .{
        .lex = lex_t,
        .parse = parse_t,
        .stages = stages,
        .e2e = e2e_t,
    };
}

pub fn quickRunNs(ctx: anytype) u64 {
    var t = Timer.start();
    ctx.call();
    return @truncate(t.read());
}

const testing = std.testing;

test {
    _ = schema;
    _ = refrunner;
    _ = main;
}

// `Value` is pinned at 64 bytes or less; a bump means a variant grew.
test "value_size_is_pinned" {
    const sz = @sizeOf(runtime.Value);
    try testing.expect(sz <= 64);
}

test "collect_kt_finds_corpus" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try corpusRoot(testing.allocator);
    defer testing.allocator.free(root);
    const files = try collectKt(testing.allocator, io, root);
    defer {
        for (files) |f| testing.allocator.free(f);
        testing.allocator.free(files);
    }
    try testing.expect(files.len != 0);
}

test "every stage runs over the base and a bench program, and the harness runs it" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const files = try collectKt(a, io, try corpusRoot(a));
    const prog = try Program.load(a, io, files[0]);
    const base = try BaseSources.load(a, io);
    const ns = try runStages(a, &base, &prog);
    for (ns) |v| try testing.expect(v > 0);
    switch (try runFull(a, &prog)) {
        .ok => {},
        .err => |e| {
            std.debug.print("bench: {s} through the harness: {s}\n", .{ prog.path, e });
            return error.TestUnexpectedResult;
        },
    }
}
