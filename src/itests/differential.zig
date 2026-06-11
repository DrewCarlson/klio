//! Differential pack-vs-direct harness (§5.1 of the execution-architecture
//! analysis). For every program in the corpus it runs the program through each
//! `LoadMode` that APPLIES to it and asserts the stdout is byte-identical
//! across modes. This converts pack-vs-direct resolution divergence (bug
//! Class C) from a field bug into a default-target test failure.
//!
//! Applicable modes:
//!   - A pure-stdlib program (no `kotlinx.*` import) is only meaningful under
//!     `EmbeddedOnly` — the kotlinx packs would not load for it — so it runs a
//!     single mode and passes trivially.
//!   - A program that uses a kotlinx pack runs `SourcePacks` (packs parsed from
//!     source) AND `CompiledPacks` (packs round-tripped through a compiled
//!     `.klio-pack` image), and the two outputs must match byte-for-byte.
//!
//! The corpus is every `examples/*.kt` (pure stdlib) plus the kotlinx-using
//! `tests/fixtures/coroutine_smoke/*.kt` so at least one pack-using program is
//! exercised across ≥2 modes.

const std = @import("std");
const parity = @import("parity");

const EXAMPLES = "examples";
const SMOKE_DIR = "tests/fixtures/coroutine_smoke";

/// True when `src` imports any `kotlinx.*` package, i.e. the program pulls in a
/// kotlinx pack and is therefore meaningful under the pack-loading modes.
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

/// The set of load modes that applies to a program with the given source.
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

/// Run every program in `files` through every applicable mode and assert the
/// stdout is byte-identical across modes. Returns the number of divergences.
///
/// Each program (and each mode within it) is run on a per-program arena that is
/// reset between iterations so the per-run phase-scoped data — ASTs, IR, the
/// rebuilt kotlinx/coroutines packs, the VM graph — is reclaimed instead of
/// accumulating across the whole corpus in one process. Safe because the
/// cross-program global state (inline-fn tables, receiver guard stacks) is
/// backed by page_allocator, not this arena.
fn checkCorpus(io: std.Io, files: []const []const u8) !usize {
    var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run_arena.deinit();

    var failures: usize = 0;
    var pack_programs: usize = 0;
    for (files) |file| {
        _ = run_arena.reset(.retain_capacity);
        const ra = run_arena.allocator();
        const src = std.Io.Dir.cwd().readFileAlloc(io, file, ra, .unlimited) catch |e| {
            std.debug.print("differential SKIP {s}: read failed ({s})\n", .{ file, @errorName(e) });
            continue;
        };
        const modes = applicableModes(src);
        if (modes.len > 1) pack_programs += 1;

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
    std.debug.print(
        "differential: {d} programs, {d} pack-using (ran >=2 modes)\n",
        .{ files.len, pack_programs },
    );
    return failures;
}

test "examples + coroutine smoke are byte-identical across load modes" {
    // Stable arena for the corpus file list + io (lives for the whole test).
    // The per-program pipeline allocations live in checkCorpus's own arena,
    // which it resets between programs so they do not accumulate.
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

    const failures = try checkCorpus(io, corpus.items);
    if (failures != 0) {
        std.debug.print("differential: {d} program(s) diverged across load modes\n", .{failures});
        return error.PackVsDirectDivergence;
    }
}
