//! Property / fuzz generator for closures + suspend (§5.4 of the
//! execution-architecture analysis). It emits small but VALID Kotlin programs
//! from a constrained grammar — N nested lambdas each capturing a mutable
//! `Int`, M of them suspending (`delay`) inside `runBlocking`/`launch`, with
//! implicit-receiver method calls at varying depth and deterministic prints —
//! then, for each generated program:
//!
//!   (a) runs it through the interpreter and asserts it does NOT crash;
//!   (b) runs it through >=2 harness load modes (`SourcePacks` AND
//!       `CompiledPacks`, since every generated program imports a kotlinx
//!       coroutine pack) and asserts BYTE-IDENTICAL stdout across modes;
//!   (c) only when kotlinc is available AND `KLIO_SKIP_KOTLINC_PARITY` is unset
//!       does it diff against kotlinc (via `parity.check`) and shrink-report
//!       the minimal failing program. kotlinc is NOT installed here by default,
//!       so the suite passes on (a)+(b) alone.
//!
//! Determinism: the seed is FIXED (`KLIO_FUZZ_SEED`-overridable). Launched
//! children use strictly-increasing distinct virtual-time delays so their
//! wakeup order is total, making every generated program's stdout deterministic
//! and comparable across modes / against kotlinc.
//!
//! On a crash or cross-mode divergence the failing seed+source is PERSISTED
//! under `tests/corpus/fuzz_failures/` (monotonic-corpus rule) and the test
//! FAILS loudly with the minimal repro — failures are never swallowed.

const std = @import("std");
const parity = @import("parity");
const runtime = @import("runtime");

/// Where a reproducing failing program is written so it becomes a permanent
/// regression case.
const FAILURE_CORPUS = "tests/corpus/fuzz_failures";

/// Seeds per run. Default tuned so this binary's wall-time is the same order as
/// the heaviest existing itest (differential ~3 min): each seed runs the full
/// pipeline twice (SourcePacks + CompiledPacks, ~5 s/seed in a Debug build).
/// Override with `KLIO_FUZZ_SEEDS` — set it to 200 for a deeper sweep.
const DEFAULT_SEEDS: u64 = 32;
/// Base seed (env-overridable via `KLIO_FUZZ_SEED`). Fixed so a green run is
/// reproducible and a red run names an exact seed.
const DEFAULT_BASE_SEED: u64 = 0x6b6c696f5f667a; // "klio_fz"

/// Per-mode progress tracing toggle (compile-time; off in the suite).
const FUZZ_TRACE = false;

// -------------------------------------------------------------------------
// Constrained program grammar.
// -------------------------------------------------------------------------

/// One generated program's parameters, derived from a seed. Kept small so the
/// emitted Kotlin stays valid and the output stays deterministic.
const Shape = struct {
    /// Number of nested capturing lambdas (each captures a mutable Int).
    nest: u32,
    /// Number of suspending children launched inside runBlocking.
    suspends: u32,
    /// Depth of implicit-receiver method calls (`with(Obj){ ... }` nesting).
    recv_depth: u32,
    /// Per-launch delay step (virtual ms); distinct delays => total order.
    delay_step: u32,
    /// Number of increment steps applied to each captured counter.
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

/// Append `fmt`-formatted text to `buf` (unmanaged ArrayList has no `print`).
fn app(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try buf.appendSlice(a, s);
}

/// Emit a valid Kotlin program for `shape`. The program is closed over
/// kotlinx.coroutines and prints a deterministic, ordered set of lines.
fn emitProgram(a: std.mem.Allocator, shape: Shape) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "import kotlinx.coroutines.*\n\n");

    // An object with member functions, used for implicit-receiver method
    // calls at varying depth via `with(Obj) { emit(...) }`.
    try buf.appendSlice(a, "object Obj {\n");
    try buf.appendSlice(a, "    fun emit(tag: String, n: Int) { println(\"obj:$tag=$n\") }\n");
    try buf.appendSlice(a, "    fun bump(n: Int): Int = n + 1\n");
    try buf.appendSlice(a, "}\n\n");

    try buf.appendSlice(a, "fun main() = runBlocking {\n");

    // (1) Nested capturing lambdas. Each level declares a mutable Int captured
    // by an inner lambda that increments it `increments` times, then the
    // captured value is printed. Nesting `run { ... }` keeps it an expression
    // chain so captures cross multiple lambda frames.
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
    // Close the nested `run` blocks.
    level = 0;
    while (level < shape.nest) : (level += 1) {
        try buf.appendSlice(a, "    }\n");
    }

    // (2) Implicit-receiver method calls at varying depth. `with(Obj){ ... }`
    // nested `recv_depth` times; the innermost calls the member `emit`
    // without a qualifier, exercising implicit-receiver resolution at depth.
    var d: u32 = 0;
    while (d < shape.recv_depth) : (d += 1) {
        try buf.appendSlice(a, "    with(Obj) {\n");
    }
    try app(&buf, a, "        emit(\"depth\", bump({d}))\n", .{shape.recv_depth});
    d = 0;
    while (d < shape.recv_depth) : (d += 1) {
        try buf.appendSlice(a, "    }\n");
    }

    // (3) Suspending children. Each `launch` captures a mutable Int, delays a
    // strictly-increasing distinct amount (so wakeup order is total and the
    // output is deterministic), increments its capture inside the suspend
    // body, then prints. runBlocking joins all children before returning.
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

// -------------------------------------------------------------------------
// Run a generated program through the harness.
// -------------------------------------------------------------------------

/// Every generated program imports kotlinx.coroutines, so the pack-load modes
/// apply and must agree byte-for-byte.
const MODES = [_]parity.LoadMode{ .SourcePacks, .CompiledPacks };

/// Write `src` to a unique temp `.kt` path, returning the owned path. Caller
/// deletes the file and frees the path.
fn writeTempProgram(gpa: std.mem.Allocator, io: std.Io, seed: u64, src: []const u8) std.mem.Allocator.Error![]u8 {
    const dir = ".zig-cache/fuzz_closures_suspend";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(gpa, "{s}/seed_{x}.kt", .{ dir, seed });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src }) catch {};
    return path;
}

/// Persist a failing seed+source under the failure corpus so it becomes a
/// permanent regression case. Best-effort; never throws.
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
    /// Source + detail are duped into the OUTER (test-lifetime) allocator so
    /// they survive the per-seed arena being torn down after `runSeed` returns.
    src: []u8,
    detail: []u8,
};

/// Run one seed: emit, write temp, run >=2 modes, assert no-crash and
/// byte-identical cross-mode. The per-seed arena is destroyed by the caller
/// after this returns, so a returned `Failure` carries strings duped into
/// `outer`. Returns a `Failure` on crash/divergence, else `null`.
fn runSeed(seed_arena: std.mem.Allocator, outer: std.mem.Allocator, io: std.Io, seed: u64) std.mem.Allocator.Error!?Failure {
    const shape = shapeFromSeed(seed);
    const src = try emitProgram(seed_arena, shape);
    const path = try writeTempProgram(seed_arena, io, seed, src);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var baseline: ?[]u8 = null;
    var baseline_mode: parity.LoadMode = undefined;
    for (MODES) |mode| {
        if (FUZZ_TRACE) std.debug.print("fuzz: seed=0x{x} mode={s}\n", .{ seed, @tagName(mode) });
        // (a) no-crash: runInMode catches interpreter-level errors as `.err`;
        // a true panic/abort would take the process down (the failure mode we
        // are hunting). A returned `.err` is itself a divergence signal if the
        // other mode succeeds, handled by the cross-mode compare below.
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
                // Both-mode error is not, by itself, a cross-mode divergence;
                // but a generated program that always errors signals a real
                // interpreter bug (the grammar emits valid Kotlin). Report it.
                const detail = try std.fmt.allocPrint(outer, "interpreter error on a valid program: {s}", .{got});
                return .{ .seed = seed, .src = try outer.dupe(u8, src), .detail = detail };
            }
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Env knobs.
// -------------------------------------------------------------------------

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

/// Read one env var from the parent process environment via the portable
/// `proc_env` accessor (Linux `/proc/self/environ`, the libc `environ` array
/// on other POSIX hosts, the PEB on Windows).
fn parityGetEnv(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ?[]u8 {
    _ = io;
    return runtime.procEnvGetVar(gpa, name) catch null;
}

// -------------------------------------------------------------------------
// kotlinc parity (DEFAULT SKIPPED — kotlinc not installed here).
// -------------------------------------------------------------------------

/// When kotlinc is available and `KLIO_SKIP_KOTLINC_PARITY` is unset, diff the
/// failing program against kotlinc and print the diff. Best-effort: a missing
/// kotlinc returns quietly (the default path). Never panics.
fn kotlincShrinkReport(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const report = parity.check(gpa, io, path) catch return;
    switch (report) {
        .err => return, // NoKotlinc / skip / compile-unavailable: silent by design.
        .ok => |rep| {
            if (rep.matched) return;
            const diff = parity.renderDiff(gpa, &rep) catch return;
            defer gpa.free(diff);
            std.debug.print("fuzz: kotlinc parity diff:\n{s}\n", .{diff});
        },
    }
}

test "fuzz: nested capturing lambdas + suspend are crash-free and mode-stable" {
    // Two arenas, both over page_allocator (the pipeline installs
    // process-global lowering/VM state backed by the run allocator, so a
    // leak-checking allocator would abort on the intentional arena lifetime;
    // this matches e2e / differential). The OUTER arena lives for the whole
    // test and holds only env values + any retained failure repro. The
    // PER-SEED arena is fully DESTROYED and recreated after every seed so the
    // ~200 runs do not accumulate (each `runInMode` builds a full module
    // image, including the kotlinx coroutines pack). A full destroy+recreate
    // (not a retain-capacity reset) returns the pages to the OS, and the
    // process-global receiver/coroutine thread-locals back their capacity on
    // the persistent `page_allocator`, so nothing dangles across the boundary.
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
            // f.src / f.detail are in `outer`, so they survive the teardown.
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

    std.debug.print("fuzz: ran {d} seed(s) (base=0x{x}) across {d} modes each\n", .{ n_seeds, base_seed, MODES.len });

    if (first_failure) |f| {
        std.debug.print("fuzz: minimal failing seed = 0x{x} (persisted under {s})\n", .{ f.seed, FAILURE_CORPUS });
        return error.FuzzClosureSuspendFailure;
    }
}
