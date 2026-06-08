//! End-to-end corpus test: run every examples/*.kt through the in-process klio
//! pipeline (the `parity` module's runWithPacks) and assert stdout matches the
//! checked-in expected output under tests/corpus/expected/. This makes the
//! behavioral corpus part of `zig build test`, self-contained (no external
//! reference needed at test time).
//!
//! The expected outputs were captured from the reference implementation and are
//! the byte-exact kotlinc-compatible stdout for each program.
const std = @import("std");
const parity = @import("parity");

const EXAMPLES = "examples";
const EXPECTED = "tests/corpus/expected";

test "e2e corpus matches expected output" {
    // Stable arena for the file list + io (lives for the whole test).
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

    // Per-program arena: reset between programs so each run's phase-scoped data
    // (ASTs, IR, the rebuilt packs, VM graph) is reclaimed instead of
    // accumulating across the whole corpus in one process. Safe because the
    // cross-program global state (inline-fn tables, receiver guard stacks) is
    // backed by page_allocator, not this arena.
    var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run_arena.deinit();

    var failures: usize = 0;
    for (files) |kt| {
        _ = run_arena.reset(.retain_capacity);
        const a = run_arena.allocator();
        const base = std.fs.path.basename(kt);
        const stem = base[0 .. base.len - ".kt".len];
        const exp_path = try std.fmt.allocPrint(a, "{s}/{s}.out", .{ EXPECTED, stem });

        const expected = std.Io.Dir.cwd().readFileAlloc(io, exp_path, a, .unlimited) catch |e| {
            std.debug.print("e2e SKIP {s}: no expected ({s})\n", .{ stem, @errorName(e) });
            continue;
        };

        const res = parity.runWithPacks(a, io, kt) catch |e| {
            failures += 1;
            std.debug.print("e2e FAIL {s}: run error {s}\n", .{ stem, @errorName(e) });
            continue;
        };
        switch (res) {
            .ok => |got| {
                if (!std.mem.eql(u8, got, expected)) {
                    failures += 1;
                    std.debug.print("e2e FAIL {s}:\n  got:  {s}\n  want: {s}\n", .{ stem, got, expected });
                }
            },
            .err => |msg| {
                failures += 1;
                std.debug.print("e2e FAIL {s}: klio error: {s}\n", .{ stem, msg });
            },
        }
    }

    if (failures != 0) {
        std.debug.print("e2e: {d}/{d} corpus programs failed\n", .{ failures, files.len });
        return error.CorpusMismatch;
    }
}
