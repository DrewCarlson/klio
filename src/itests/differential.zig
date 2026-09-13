//! Differential pack-vs-direct harness over `examples/*.kt` and
//! `tests/fixtures/coroutine_smoke/*.kt`: a kotlinx-using program runs under
//! both `SourcePacks` and `CompiledPacks` and the outputs must be identical. A
//! pure-stdlib program has only `EmbeddedOnly`, so it compares nothing and is
//! skipped; the e2e corpus gate owns single-mode example output.

const std = @import("std");
const parity = @import("parity");
const runtime = @import("runtime");

/// Stderr from a passing `zig build test` step renders as a failed command.
fn verbose() bool {
    return runtime.envOnce("KLIO_ITEST_VERBOSE") != null;
}

const EXAMPLES = "examples";
const SMOKE_DIR = "tests/fixtures/coroutine_smoke";

fn usesKotlinxPack(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.startsWith(u8, line, "import kotlinx.") or
            std.mem.startsWith(u8, line, "import  kotlinx."))
        {
            return true;
        }
    }
    return false;
}

fn applicableModes(src: []const u8) []const parity.LoadMode {
    if (usesKotlinxPack(src)) {
        return &.{ .SourcePacks, .CompiledPacks };
    }
    return &.{.EmbeddedOnly};
}

const RunOutcome = union(enum) {
    out: []u8,
    err: []u8,
};

fn runOne(gpa: std.mem.Allocator, io: std.Io, file: []const u8, mode: parity.LoadMode) !RunOutcome {
    const res = try parity.runInMode(gpa, io, file, mode);
    return switch (res) {
        .ok => |got| .{ .out = got },
        .err => |msg| .{ .err = msg },
    };
}

/// Returns the number of cross-mode divergences. Runs share one arena, reset
/// between programs; the cross-program globals live on the page allocator.
fn checkCorpus(io: std.Io, files: []const []const u8) !usize {
    // Each cached base is a full stdlib+packs clone, so cap the LRU at the
    // working set: the two load modes compared for the current program.
    parity.base_cache_max = 2;

    var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run_arena.deinit();

    var failures: usize = 0;
    var pack_programs: usize = 0;
    for (files) |file| {
        _ = run_arena.reset(.{ .retain_with_limit = 64 * 1024 * 1024 });
        const ra = run_arena.allocator();
        const src = std.Io.Dir.cwd().readFileAlloc(io, file, ra, .unlimited) catch |e| {
            std.debug.print("differential SKIP {s}: read failed ({s})\n", .{ file, @errorName(e) });
            continue;
        };
        const modes = applicableModes(src);
        if (modes.len < 2) continue;
        pack_programs += 1;

        var baseline: ?RunOutcome = null;
        var baseline_mode: parity.LoadMode = undefined;
        for (modes) |mode| {
            const outcome = try runOne(ra, io, file, mode);
            if (baseline) |base| {
                const a = switch (base) {
                    .out => |o| o,
                    .err => |e| e,
                };
                const b = switch (outcome) {
                    .out => |o| o,
                    .err => |e| e,
                };
                const same_kind = std.meta.activeTag(base) == std.meta.activeTag(outcome);
                if (!same_kind or !std.mem.eql(u8, a, b)) {
                    failures += 1;
                    std.debug.print(
                        "differential DIVERGENCE {s}:\n  [{s}] {s}\n  [{s}] {s}\n",
                        .{
                            file,
                            @tagName(baseline_mode), a,
                            @tagName(mode),          b,
                        },
                    );
                }
            } else {
                baseline = outcome;
                baseline_mode = mode;
            }
        }
    }
    if (verbose()) std.debug.print(
        "differential: {d} programs, {d} pack-using (ran >=2 modes)\n",
        .{ files.len, pack_programs },
    );
    return failures;
}

test "examples + coroutine smoke are byte-identical across load modes" {
    var list_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer list_arena.deinit();
    const la = list_arena.allocator();
    var threaded: std.Io.Threaded = .init(la, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var corpus: std.ArrayList([]u8) = .empty;
    defer corpus.deinit(la);

    const examples = parity.collectKt(la, io, EXAMPLES) catch |e| {
        std.debug.print("differential: collectKt(examples) failed ({s})\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try corpus.appendSlice(la, examples);

    const smoke = parity.collectKt(la, io, SMOKE_DIR) catch &.{};
    try corpus.appendSlice(la, smoke);

    if (corpus.items.len == 0) {
        std.debug.print("differential: empty corpus; skipping\n", .{});
        return error.SkipZigTest;
    }

    // Grouping by base key keeps the two-entry cache hot within each group.
    parity.groupByBaseKey(la, io, corpus.items);

    const failures = try checkCorpus(io, corpus.items);
    if (failures != 0) {
        std.debug.print("differential: {d} program(s) diverged across load modes\n", .{failures});
        return error.PackVsDirectDivergence;
    }
}

// A mutation leaking out of one run into the shared per-process base would
// make an output depend on which programs ran before it.
test "corpus outputs are independent of program order" {
    var list_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer list_arena.deinit();
    const la = list_arena.allocator();
    var threaded: std.Io.Threaded = .init(la, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var corpus: std.ArrayList([]u8) = .empty;
    defer corpus.deinit(la);
    const examples = parity.collectKt(la, io, EXAMPLES) catch |e| {
        std.debug.print("differential order: collectKt(examples) failed ({s})\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try corpus.appendSlice(la, examples);
    const smoke = parity.collectKt(la, io, SMOKE_DIR) catch &.{};
    try corpus.appendSlice(la, smoke);
    if (corpus.items.len == 0) return error.SkipZigTest;

    // Leakage shows up against any surrounding programs, so a deterministic
    // sample suffices. Every pack-using program stays: those bases carry the
    // most shared state.
    var sampled: std.ArrayList([]u8) = .empty;
    defer sampled.deinit(la);
    {
        var pure: std.ArrayList([]u8) = .empty;
        defer pure.deinit(la);
        for (corpus.items) |file| {
            const src = std.Io.Dir.cwd().readFileAlloc(io, file, la, .unlimited) catch continue;
            if (applicableModes(src).len > 1)
                try sampled.append(la, file)
            else
                try pure.append(la, file);
        }
        const max_pure = 12;
        const stride = @max(pure.items.len / max_pure, 1);
        var i: usize = 0;
        while (i < pure.items.len) : (i += stride) try sampled.append(la, pure.items[i]);
    }
    corpus.clearRetainingCapacity();
    try corpus.appendSlice(la, sampled.items);
    // Grouping keeps the cache hot and still gives every program a different
    // predecessor set in the two passes.
    parity.groupByBaseKey(la, io, corpus.items);

    const Key = struct { file: []const u8, mode: parity.LoadMode };
    var recorded: std.ArrayList(struct { key: Key, kind: u8, text: []u8 }) = .empty;
    defer recorded.deinit(la);

    var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run_arena.deinit();

    // Forward pass: record every outcome.
    for (corpus.items) |file| {
        if (verbose()) std.debug.print("differential order FWD {s}\n", .{file});
        _ = run_arena.reset(.{ .retain_with_limit = 64 * 1024 * 1024 });
        const ra = run_arena.allocator();
        const src = std.Io.Dir.cwd().readFileAlloc(io, file, ra, .unlimited) catch continue;
        for (applicableModes(src)) |mode| {
            const outcome = try runOne(ra, io, file, mode);
            const kind: u8 = if (outcome == .out) 0 else 1;
            const text = switch (outcome) {
                .out => |o| o,
                .err => |e| e,
            };
            try recorded.append(la, .{
                .key = .{ .file = file, .mode = mode },
                .kind = kind,
                .text = try la.dupe(u8, text),
            });
        }
    }

    var failures: usize = 0;
    var idx: usize = recorded.items.len;
    while (idx > 0) {
        idx -= 1;
        const rec = recorded.items[idx];
        if (verbose()) std.debug.print("differential order REV {s} [{s}]\n", .{ rec.key.file, @tagName(rec.key.mode) });
        _ = run_arena.reset(.{ .retain_with_limit = 64 * 1024 * 1024 });
        const ra = run_arena.allocator();
        const outcome = try runOne(ra, io, rec.key.file, rec.key.mode);
        const kind: u8 = if (outcome == .out) 0 else 1;
        const text = switch (outcome) {
            .out => |o| o,
            .err => |e| e,
        };
        if (kind != rec.kind or !std.mem.eql(u8, text, rec.text)) {
            failures += 1;
            std.debug.print(
                "differential ORDER DIVERGENCE {s} [{s}]:\n  forward: {s}\n  reverse: {s}\n",
                .{ rec.key.file, @tagName(rec.key.mode), rec.text, text },
            );
        }
    }
    if (verbose()) std.debug.print("differential order: {d} (program, mode) outcomes re-checked in reverse\n", .{recorded.items.len});
    if (failures != 0) return error.OrderDependentOutput;
}
