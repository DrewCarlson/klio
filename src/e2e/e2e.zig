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
    // The pipeline allocates phase-scoped data freed by an arena at run end
    // (as the binary does); use an arena here rather than the leak-checking
    // testing allocator, which would abort on the intentional arena lifetime.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const files = parity.collectKt(gpa, io, EXAMPLES) catch |e| {
        std.debug.print("e2e: collectKt failed ({s}); skipping\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer {
        for (files) |p| gpa.free(p);
        gpa.free(files);
    }
    if (files.len == 0) {
        std.debug.print("e2e: no examples found; skipping\n", .{});
        return error.SkipZigTest;
    }

    var failures: usize = 0;
    for (files) |kt| {
        const base = std.fs.path.basename(kt);
        const stem = base[0 .. base.len - ".kt".len];
        const exp_path = try std.fmt.allocPrint(gpa, "{s}/{s}.out", .{ EXPECTED, stem });
        defer gpa.free(exp_path);

        const expected = std.Io.Dir.cwd().readFileAlloc(io, exp_path, gpa, .unlimited) catch |e| {
            std.debug.print("e2e SKIP {s}: no expected ({s})\n", .{ stem, @errorName(e) });
            continue;
        };
        defer gpa.free(expected);

        const res = parity.runWithPacks(gpa, io, kt) catch |e| {
            failures += 1;
            std.debug.print("e2e FAIL {s}: run error {s}\n", .{ stem, @errorName(e) });
            continue;
        };
        switch (res) {
            .ok => |got| {
                defer gpa.free(got);
                if (!std.mem.eql(u8, got, expected)) {
                    failures += 1;
                    std.debug.print("e2e FAIL {s}:\n  got:  {s}\n  want: {s}\n", .{ stem, got, expected });
                }
            },
            .err => |msg| {
                defer gpa.free(msg);
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
