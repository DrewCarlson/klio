//! Property fuzzer for closures plus suspend: it emits valid Kotlin from a
//! constrained grammar and asserts per program that the interpreter does not
//! crash and that stdout is byte-identical across both pack-load modes. Every
//! delay is distinct, so wakeup order is total and stdout is comparable.
//! A failing seed is persisted under `tests/corpus/fuzz_failures/`.

const std = @import("std");
const parity = @import("parity");
const runtime = @import("runtime");

const FAILURE_CORPUS = "tests/corpus/fuzz_failures";

/// Seeds per run, overridable with `KLIO_FUZZ_SEEDS`.
const DEFAULT_SEEDS: u64 = 32;
/// Base seed, overridable with `KLIO_FUZZ_SEED`. Fixed so runs reproduce.
const DEFAULT_BASE_SEED: u64 = 0x6b6c696f5f667a; // "klio_fz"

const FUZZ_TRACE = false;

/// One generated program's parameters, derived from a seed.
const Shape = struct {
    nest: u32,
    suspends: u32,
    recv_depth: u32,
    /// Virtual ms between successive launches.
    delay_step: u32,
    increments: u32,
};

fn shapeFromSeed(seed: u64) Shape {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    return .{
        .nest = r.intRangeAtMost(u32, 1, 4),
        .suspends = r.intRangeAtMost(u32, 1, 4),
        .recv_depth = r.intRangeAtMost(u32, 1, 3),
        .delay_step = r.intRangeAtMost(u32, 1, 7) * 10,
        .increments = r.intRangeAtMost(u32, 1, 5),
    };
}

/// Formatted append, which an unmanaged ArrayList has no `print` for.
fn app(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try buf.appendSlice(a, s);
}

/// Emit the Kotlin program for `shape`. Caller owns the result.
fn emitProgram(a: std.mem.Allocator, shape: Shape) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "import kotlinx.coroutines.*\n\n");

    try buf.appendSlice(a, "object Obj {\n");
    try buf.appendSlice(a, "    fun emit(tag: String, n: Int) { println(\"obj:$tag=$n\") }\n");
    try buf.appendSlice(a, "    fun bump(n: Int): Int = n + 1\n");
    try buf.appendSlice(a, "}\n\n");

    try buf.appendSlice(a, "fun main() = runBlocking {\n");

    var level: u32 = 0;
    while (level < shape.nest) : (level += 1) {
        try buf.appendSlice(a, "    run {\n");
        try app(&buf, a, "        var acc{d} = {d}\n", .{ level, level });
        try app(&buf, a, "        val step{d} = {{ acc{d} = acc{d} + 1 }}\n", .{ level, level, level });
        var k: u32 = 0;
        while (k < shape.increments) : (k += 1) {
            try app(&buf, a, "        step{d}()\n", .{level});
        }
        try app(&buf, a, "        println(\"acc{d}=$acc{d}\")\n", .{ level, level });
    }
    level = 0;
    while (level < shape.nest) : (level += 1) {
        try buf.appendSlice(a, "    }\n");
    }

    var d: u32 = 0;
    while (d < shape.recv_depth) : (d += 1) {
        try buf.appendSlice(a, "    with(Obj) {\n");
    }
    try app(&buf, a, "        emit(\"depth\", bump({d}))\n", .{shape.recv_depth});
    d = 0;
    while (d < shape.recv_depth) : (d += 1) {
        try buf.appendSlice(a, "    }\n");
    }

    var s: u32 = 0;
    while (s < shape.suspends) : (s += 1) {
        const delay = (s + 1) * shape.delay_step;
        try app(&buf, a, "    var c{d} = {d}\n", .{ s, s * 10 });
        try app(&buf, a, "    launch {{ delay({d}L); c{d} = c{d} + {d}; println(\"job{d}:$c{d}\") }}\n", .{
            delay, s, s, shape.increments, s, s,
        });
    }
    try buf.appendSlice(a, "    println(\"launched\")\n");

    try buf.appendSlice(a, "}\n");
    return buf.toOwnedSlice(a);
}

const MODES = [_]parity.LoadMode{ .SourcePacks, .CompiledPacks };

/// Caller deletes the file and frees the returned path.
fn writeTempProgram(gpa: std.mem.Allocator, io: std.Io, seed: u64, src: []const u8) std.mem.Allocator.Error![]u8 {
    const dir = ".zig-cache/fuzz_closures_suspend";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(gpa, "{s}/seed_{x}.kt", .{ dir, seed });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src }) catch {};
    return path;
}

fn persistFailure(gpa: std.mem.Allocator, io: std.Io, seed: u64, src: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, FAILURE_CORPUS) catch {};
    const path = std.fmt.allocPrint(gpa, "{s}/fuzz_seed_{x}.kt", .{ FAILURE_CORPUS, seed }) catch return;
    defer gpa.free(path);
    const header = std.fmt.allocPrint(
        gpa,
        "// fuzz_closures_suspend repro for seed=0x{x}\n// Reproduce: KLIO_FUZZ_SEED=0x{x} KLIO_FUZZ_SEEDS=1 zig build test\n",
        .{ seed, seed },
    ) catch return;
    defer gpa.free(header);
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(gpa);
    full.appendSlice(gpa, header) catch return;
    full.appendSlice(gpa, src) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = full.items }) catch {};
    std.debug.print("fuzz: persisted failing repro -> {s}\n", .{path});
}

const Failure = struct {
    seed: u64,
    /// Duped into the test-lifetime allocator, outliving the per-seed arena.
    src: []u8,
    detail: []u8,
};

/// Returns a `Failure` on a crash or cross-mode divergence, with its strings
/// duped into `outer` because the caller destroys `seed_arena` on return.
fn runSeed(seed_arena: std.mem.Allocator, outer: std.mem.Allocator, io: std.Io, seed: u64) std.mem.Allocator.Error!?Failure {
    const shape = shapeFromSeed(seed);
    const src = try emitProgram(seed_arena, shape);
    const path = try writeTempProgram(seed_arena, io, seed, src);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var baseline: ?[]u8 = null;
    var baseline_mode: parity.LoadMode = undefined;
    for (MODES) |mode| {
        if (FUZZ_TRACE) std.debug.print("fuzz: seed=0x{x} mode={s}\n", .{ seed, @tagName(mode) });
        // runInMode reports interpreter errors as `.err`; a real panic takes
        // the process down, which is the crash this hunts for.
        const res = try parity.runInMode(seed_arena, io, path, mode);
        const got: []u8 = switch (res) {
            .ok => |o| o,
            .err => |e| try std.fmt.allocPrint(seed_arena, "<err> {s}", .{e}),
        };
        const is_err = res == .err;
        if (baseline) |base| {
            if (!std.mem.eql(u8, base, got)) {
                const detail = try std.fmt.allocPrint(
                    outer,
                    "cross-mode divergence: [{s}]\n{s}\n[{s}]\n{s}",
                    .{ @tagName(baseline_mode), base, @tagName(mode), got },
                );
                return .{ .seed = seed, .src = try outer.dupe(u8, src), .detail = detail };
            }
        } else {
            baseline = got;
            baseline_mode = mode;
            if (is_err) {
                // The grammar only emits valid Kotlin, so any error is a bug.
                const detail = try std.fmt.allocPrint(outer, "interpreter error on a valid program: {s}", .{got});
                return .{ .seed = seed, .src = try outer.dupe(u8, src), .detail = detail };
            }
        }
    }
    return null;
}

fn envU64(gpa: std.mem.Allocator, io: std.Io, name: []const u8, default: u64) u64 {
    const v = parityGetEnv(gpa, io, name) orelse return default;
    defer gpa.free(v);
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) {
        return std.fmt.parseInt(u64, t[2..], 16) catch default;
    }
    return std.fmt.parseInt(u64, t, 10) catch default;
}

fn envFlag(gpa: std.mem.Allocator, io: std.Io, name: []const u8) bool {
    const v = parityGetEnv(gpa, io, name) orelse return false;
    defer gpa.free(v);
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

fn parityGetEnv(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ?[]u8 {
    _ = io;
    return runtime.procEnvGetVar(gpa, name) catch null;
}

/// Diff a failing program against kotlinc, quiet when kotlinc is absent.
fn kotlincShrinkReport(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const report = parity.check(gpa, io, path) catch return;
    switch (report) {
        .err => return,
        .ok => |rep| {
            if (rep.matched) return;
            const diff = parity.renderDiff(gpa, &rep) catch return;
            defer gpa.free(diff);
            std.debug.print("fuzz: kotlinc parity diff:\n{s}\n", .{diff});
        },
    }
}

test "fuzz: nested capturing lambdas + suspend are crash-free and mode-stable" {
    // Both arenas sit on page_allocator: the pipeline installs process-global
    // state backed by the run allocator, which a leak-checking allocator would
    // flag at teardown. The per-seed arena is destroyed and recreated per seed
    // so each run's module image returns its pages instead of accumulating.
    var outer_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer outer_arena.deinit();
    const outer = outer_arena.allocator();

    var threaded: std.Io.Threaded = .init(outer, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base_seed = envU64(outer, io, "KLIO_FUZZ_SEED", DEFAULT_BASE_SEED);
    const n_seeds = envU64(outer, io, "KLIO_FUZZ_SEEDS", DEFAULT_SEEDS);
    const do_kotlinc = !envFlag(outer, io, "KLIO_SKIP_KOTLINC_PARITY");

    var first_failure: ?Failure = null;
    var i: u64 = 0;
    while (i < n_seeds) : (i += 1) {
        const seed = base_seed +% (i *% 0x9e3779b97f4a7c15);

        var seed_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const failure = try runSeed(seed_arena.allocator(), outer, io, seed);
        seed_arena.deinit();

        if (failure) |f| {
            persistFailure(outer, io, f.seed, f.src);
            std.debug.print(
                "fuzz: FAILURE seed=0x{x}\n{s}\n--- program ---\n{s}\n",
                .{ f.seed, f.detail, f.src },
            );
            if (do_kotlinc) {
                const path = try std.fmt.allocPrint(outer, "{s}/fuzz_seed_{x}.kt", .{ FAILURE_CORPUS, f.seed });
                kotlincShrinkReport(outer, io, path);
            }
            if (first_failure == null) first_failure = f;
            break;
        }
    }

    // An unconditional stderr summary makes `zig build test` report the
    // passing test command as failed.
    if (FUZZ_TRACE) std.debug.print("fuzz: ran {d} seed(s) (base=0x{x}) across {d} modes each\n", .{ n_seeds, base_seed, MODES.len });

    if (first_failure) |f| {
        std.debug.print("fuzz: minimal failing seed = 0x{x} (persisted under {s})\n", .{ f.seed, FAILURE_CORPUS });
        return error.FuzzClosureSuspendFailure;
    }
}
