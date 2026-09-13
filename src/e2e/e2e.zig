//! End-to-end corpus test: runs every `examples/*.kt` through the in-process
//! klio pipeline (`parity.runWithPacks`) and asserts stdout matches the
//! checked-in expected output under `tests/corpus/expected/`, which holds the
//! byte-exact kotlinc-compatible stdout for each program. Needs no external
//! reference at test time.
const std = @import("std");
const parity = @import("parity");
const jit = @import("ir").jit_loop;

const parser = @import("parser");
const EXAMPLES = "examples";

/// Apply the `--language=` specs an example declares in a `Run with:` header
/// comment, as `scripts/corpus_check.py` does on the CLI route. They apply to
/// the parser for this example only.
fn applyRunDirective(io: std.Io, a: std.mem.Allocator, path: []const u8) void {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 12) break;
        const at = std.mem.indexOf(u8, line, "Run with:") orelse continue;
        var it = std.mem.tokenizeAny(u8, line[at + "Run with:".len ..], " \t");
        while (it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--language=")) {
                var specs = std.mem.tokenizeAny(u8, arg["--language=".len..], ",");
                while (specs.next()) |spec| _ = parser.setLanguageFeature(spec);
            }
        }
        return;
    }
}

const EXPECTED = "tests/corpus/expected";

/// `KLIO_E2E_SHARD=K/N` runs only the programs whose name hashes into
/// shard K of N, so the gate fans the corpus across parallel processes.
fn shardSkip(stem: []const u8) bool {
    const spec = std.c.getenv("KLIO_E2E_SHARD") orelse return false;
    const s = std.mem.span(spec);
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    const k = std.fmt.parseInt(u64, s[0..slash], 10) catch return false;
    const n = std.fmt.parseInt(u64, s[slash + 1 ..], 10) catch return false;
    if (n == 0) return false;
    var h = std.hash.Wyhash.init(0);
    h.update(stem);
    return (h.final() % n) != k;
}

/// Per-program SKIP notices are silent by default: a passing `zig build` run
/// step that writes to stderr is rendered as a failed command by the build
/// runner. `KLIO_ITEST_VERBOSE` surfaces them.
fn verbose() bool {
    return std.c.getenv("KLIO_ITEST_VERBOSE") != null;
}

fn runCorpus(jit_on: bool) !void {
    jit.setEnabledForTest(jit_on);
    defer jit.setEnabledForTest(false);

    // The corpus spans ~8 distinct pack masks, each otherwise retaining its own
    // full stdlib clone. Grouping by base key lets a cache of one base cover the
    // run with one rebuild per mask, staying under the RSS watchdog.
    parity.base_cache_max = if (std.c.getenv("KLIO_E2E_NO_EVICT") != null) 0 else 1;

    var list_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer list_arena.deinit();
    const la = list_arena.allocator();
    var threaded: std.Io.Threaded = .init(la, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const files = parity.collectKt(la, io, EXAMPLES) catch |e| {
        std.debug.print("e2e: collectKt failed ({s}); skipping\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    if (files.len == 0) {
        std.debug.print("e2e: no examples found; skipping\n", .{});
        return error.SkipZigTest;
    }
    parity.groupByBaseKey(la, io, files);

    var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run_arena.deinit();

    var failures: usize = 0;
    for (files) |kt| {
        // Drop the previous program's JIT state: its module memory is about to be
        // recycled, so a reused `*Func` address must not inherit stale native code.
        jit.resetForTest();
        _ = run_arena.reset(.retain_capacity);
        const a = run_arena.allocator();
        const base = std.fs.path.basename(kt);
        const stem = base[0 .. base.len - ".kt".len];
        if (std.c.getenv("KLIO_E2E_FILTER")) |f| {
            if (std.mem.indexOf(u8, stem, std.mem.span(f)) == null) continue;
        }
        if (shardSkip(stem)) continue;
        if (std.c.getenv("KLIO_E2E_TRACE") != null) std.debug.print("e2e RUN {s} (jit={})\n", .{ stem, jit_on });
        const exp_path = try std.fmt.allocPrint(a, "{s}/{s}.out", .{ EXPECTED, stem });

        const expected = std.Io.Dir.cwd().readFileAlloc(io, exp_path, a, .unlimited) catch |e| {
            if (verbose()) std.debug.print("e2e SKIP {s}: no expected ({s})\n", .{ stem, @errorName(e) });
            continue;
        };

        applyRunDirective(io, a, kt);
        defer parser.language = .{};
        const res = parity.runWithPacks(a, io, kt) catch |e| {
            failures += 1;
            std.debug.print("e2e FAIL {s} (jit={}): run error {s}\n", .{ stem, jit_on, @errorName(e) });
            continue;
        };
        switch (res) {
            .ok => |got| {
                if (!std.mem.eql(u8, got, expected)) {
                    failures += 1;
                    std.debug.print("e2e FAIL {s} (jit={}):\n  got:  {s}\n  want: {s}\n", .{ stem, jit_on, got, expected });
                }
            },
            .err => |msg| {
                failures += 1;
                std.debug.print("e2e FAIL {s} (jit={}): klio error: {s}\n", .{ stem, jit_on, msg });
            },
        }
    }

    if (failures != 0) {
        std.debug.print("e2e (jit={}): {d}/{d} corpus programs failed\n", .{ jit_on, failures, files.len });
        return error.CorpusMismatch;
    }
}

test "e2e corpus matches expected output (jit on)" {
    try runCorpus(true);
}

test "e2e corpus matches expected output (jit off)" {
    try runCorpus(false);
}

// The whole-function JIT (native recursion) is opt-in via `KLIO_FUNC_JIT`, so
// the corpus passes above never exercise it. Run a small main-thread-only set
// here so the per-thread compiled-code retention cannot accumulate.
test "function-JIT recursion matches the interpreter" {
    jit.setEnabledForTest(true);
    jit.setFuncEnabledForTest(true);
    defer jit.setEnabledForTest(false);
    defer jit.setFuncEnabledForTest(false);
    parity.base_cache_max = if (std.c.getenv("KLIO_E2E_NO_EVICT") != null) 0 else 2;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_][]const u8{ "jit_recursion", "jit_inline_call_loop", "jit_char_tag_static_call" };
    for (cases) |stem| {
        jit.resetForTest();
        const kt = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ EXAMPLES, stem });
        const exp_path = try std.fmt.allocPrint(a, "{s}/{s}.out", .{ EXPECTED, stem });
        const expected = std.Io.Dir.cwd().readFileAlloc(io, exp_path, a, .unlimited) catch |e| {
            if (verbose()) std.debug.print("func-jit SKIP {s}: no expected ({s})\n", .{ stem, @errorName(e) });
            continue;
        };
        const res = parity.runWithPacks(a, io, kt) catch |e| {
            std.debug.print("func-jit FAIL {s}: run error {s}\n", .{ stem, @errorName(e) });
            return error.FuncJitMismatch;
        };
        switch (res) {
            .ok => |got| if (!std.mem.eql(u8, got, expected)) {
                std.debug.print("func-jit FAIL {s}:\n  got:  {s}\n  want: {s}\n", .{ stem, got, expected });
                return error.FuncJitMismatch;
            },
            .err => |msg| {
                std.debug.print("func-jit FAIL {s}: klio error: {s}\n", .{ stem, msg });
                return error.FuncJitMismatch;
            },
        }
    }
}
