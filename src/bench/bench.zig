//! Shared bench plumbing: corpus loader, per-stage pipeline runners, timing,
//! and the JSON result schema. Alloc-light so it does not perturb its numbers.

const std = @import("std");

const ast = @import("ast");
const interp_ir = @import("interp_ir");
const lexer = @import("lexer");
const parser = @import("parser");
const resolver = @import("resolver");
const runtime = @import("runtime");
const span = @import("span");
const typeck = @import("typeck");

const KotlinFile = ast.KotlinFile;
const Vm = interp_ir.Vm;
const buildModule = interp_ir.build.buildModule;
const Output = runtime.Output;
const LexResult = lexer.LexResult;
const Lexer = lexer.Lexer;
const Resolution = resolver.Resolution;
const FileId = span.FileId;
const SourceMap = span.SourceMap;
const TypeCheck = typeck.TypeCheck;

pub const refrunner = @import("refrunner.zig");
pub const schema = @import("schema.zig");
pub const main = @import("main.zig");

pub const BenchRecord = schema.BenchRecord;
pub const BenchReport = schema.BenchReport;
pub const RegressionLevel = schema.RegressionLevel;

/// Captures lines: every embedded newline flushes one line, newline trimmed.
const CaptureOutput = struct {
    lines: std.ArrayList([]const u8) = .empty,
    cur: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CaptureOutput {
        return .{ .lines = .empty, .cur = .empty, .allocator = allocator };
    }

    fn deinit(self: *CaptureOutput) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.cur.deinit(self.allocator);
    }

    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: *CaptureOutput = @ptrCast(@alignCast(ctx));
        self.cur.appendSlice(self.allocator, s) catch return;
        while (std.mem.indexOfScalar(u8, self.cur.items, '\n')) |idx| {
            const line = self.allocator.dupe(u8, self.cur.items[0..idx]) catch return;
            self.lines.append(self.allocator, line) catch {};
            const rest = self.cur.items[idx + 1 ..];
            std.mem.copyForwards(u8, self.cur.items[0..rest.len], rest);
            self.cur.shrinkRetainingCapacity(rest.len);
        }
    }

    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        vtWrite(ctx, s);
        vtWrite(ctx, "\n");
    }

    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    fn output(self: *CaptureOutput) Output {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Caller owns the returned bytes.
    fn join(self: *const CaptureOutput, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.mem.join(allocator, "\n", self.lines.items);
    }
};

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
    var p = parser.Parser.new(allocator, lexed.id, lexed.source, lexed.result.tokens);
    return p.parseFile();
}

pub fn resolveOnly(allocator: std.mem.Allocator, file: *const KotlinFile) !Resolution {
    return resolver.resolve(allocator, file);
}

pub fn typeckOnly(allocator: std.mem.Allocator, file: *const KotlinFile, res: *const Resolution) !TypeCheck {
    return typeck.typecheck(allocator, file, res);
}

/// Captured stdout owned by the caller, or a static failure description
/// (except the allocated `runtime: ...` form).
pub const RunOutcome = union(enum) {
    ok: []u8,
    err: []const u8,
};

pub fn runFull(allocator: std.mem.Allocator, prog: *const Program) std.mem.Allocator.Error!RunOutcome {
    var map = SourceMap.init(allocator);
    defer map.deinit();
    var lexed = lex(allocator, &map, prog) catch return .{ .err = "lex errors" };
    defer lexed.result.deinit(allocator);
    if (lexed.result.diagnostics.hasErrors()) {
        return .{ .err = "lex errors" };
    }
    var ast_file = parse(allocator, &lexed);
    _ = resolveOnly(allocator, &ast_file) catch return .{ .err = "resolve error" };

    var cap = CaptureOutput.init(allocator);
    defer cap.deinit();

    var built = buildModule(allocator, &ast_file) catch return .{ .err = "build error" };
    const main_id = built.main orelse {
        built.deinit();
        return .{ .err = "no main function in module" };
    };
    const fb = Vm.fromBuilt(allocator, &built) catch {
        built.deinit();
        return .{ .err = "build error" };
    };
    built.deinit();
    var vm = fb.vm;
    defer vm.deinit();
    const result = vm.run(main_id, cap.output()) catch return .{ .err = "out of memory" };
    switch (result) {
        .err => |e| {
            switch (e) {
                .InvalidMain => return .{ .err = "no main function in module" },
                .Eval => |s| {
                    const msg = std.fmt.allocPrint(allocator, "runtime: {s}", .{s}) catch "runtime error";
                    return .{ .err = msg };
                },
            }
        },
        .ok => {},
    }
    const out = cap.join(allocator) catch return .{ .err = "out of memory" };
    return .{ .ok = out };
}

pub const Timing = struct {
    iters: u64,
    median_ns: u64,
    p99_ns: u64,
};

/// Time `ctx.call()` over at least `min_total_ns`; returns median, p99, iters.
pub fn timeIters(
    allocator: std.mem.Allocator,
    ctx: anytype,
    min_total_ns: u64,
    min_iters: u32,
) std.mem.Allocator.Error!Timing {
    var samples: std.ArrayList(u128) = .empty;
    defer samples.deinit(allocator);
    var timer = std.time.Timer.start() catch unreachable;
    const start_all = timer.read();
    while (samples.items.len < min_iters or (timer.read() - start_all) < min_total_ns) {
        var t = std.time.Timer.start() catch unreachable;
        ctx.call();
        try samples.append(allocator, t.read());
        if (samples.items.len > 10_000) break;
    }
    std.mem.sort(u128, samples.items, {}, std.sort.asc(u128));
    const n = samples.items.len;
    const median = samples.items[n / 2];
    const p99 = samples.items[@min(n * 99 / 100, n - 1)];
    return .{
        .iters = @intCast(n),
        .median_ns = @truncate(median),
        .p99_ns = @truncate(p99),
    };
}

pub const StageTimings = struct {
    lex: Timing,
    parse: Timing,
    resolve: Timing,
    typeck: Timing,
    e2e: Timing,
};

/// Time each stage independently against a fresh input, so one stage's cache
/// effects do not help the next.
pub fn timePipelineStages(
    allocator: std.mem.Allocator,
    prog: *const Program,
    budget_per_stage_ns: u64,
) std.mem.Allocator.Error!StageTimings {
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

    const resolve_ctx = struct {
        a: std.mem.Allocator,
        p: *const Program,
        fn call(self: @This()) void {
            var arena = std.heap.ArenaAllocator.init(self.a);
            defer arena.deinit();
            const aa = arena.allocator();
            var map = SourceMap.init(aa);
            var lexed = lex(aa, &map, self.p) catch return;
            const file = parse(aa, &lexed);
            _ = resolveOnly(aa, &file) catch return;
        }
    }{ .a = allocator, .p = prog };
    const resolve_t = try timeIters(allocator, resolve_ctx, budget_per_stage_ns, 5);

    const typeck_ctx = struct {
        a: std.mem.Allocator,
        p: *const Program,
        fn call(self: @This()) void {
            var arena = std.heap.ArenaAllocator.init(self.a);
            defer arena.deinit();
            const aa = arena.allocator();
            var map = SourceMap.init(aa);
            var lexed = lex(aa, &map, self.p) catch return;
            const file = parse(aa, &lexed);
            const res = resolveOnly(aa, &file) catch return;
            _ = typeckOnly(aa, &file, &res) catch return;
        }
    }{ .a = allocator, .p = prog };
    const typeck_t = try timeIters(allocator, typeck_ctx, budget_per_stage_ns, 5);

    const interp_ctx = struct {
        a: std.mem.Allocator,
        p: *const Program,
        fn call(self: @This()) void {
            const outcome = runFull(self.a, self.p) catch return;
            switch (outcome) {
                .ok => |s| self.a.free(s),
                .err => |s| {
                    if (std.mem.startsWith(u8, s, "runtime: ")) self.a.free(s);
                },
            }
        }
    }{ .a = allocator, .p = prog };
    const interp_t = try timeIters(allocator, interp_ctx, budget_per_stage_ns, 3);

    return .{
        .lex = lex_t,
        .parse = parse_t,
        .resolve = resolve_t,
        .typeck = typeck_t,
        .e2e = interp_t,
    };
}

pub fn quickRunNs(ctx: anytype) u64 {
    var t = std.time.Timer.start() catch unreachable;
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
