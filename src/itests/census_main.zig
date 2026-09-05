//! `klio-census` — the link-free census driver
//! (plans/verification-latency-campaign.md Task 2). Runs any commontest
//! suite from the SHARED registry (`commontest_support.suites`) against the
//! installed `zig-out/bin/klio-harness`, so iterating on the interpreter
//! costs one harness rebuild instead of a whole-program itest link per
//! suite. The itest gates remain the CI authority; both consume the same
//! configs, floors, and ceilings, so this can never drift green.
//!
//! Usage: klio-census <suite>[,<suite>...] | all
//! Env: KLIO_ITEST_BIN overrides the child binary (default
//! zig-out/bin/klio-harness); KLIO_ITEST_JOBS the per-suite worker count;
//! KLIO_CENSUS_NAMES / KLIO_CENSUS_TIMES as in the gates.

const std = @import("std");
const support = @import("commontest_support.zig");
const box = @import("box_support.zig");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    var ai = init.args.iterate();
    while (ai.next()) |a2| try list.append(gpa, a2);
    const args = list.items;
    if (args.len < 2) {
        std.debug.print("usage: klio-census <suite>[,<suite>...] | all\navailable:", .{});
        for (&support.suites) |*cfg| std.debug.print(" {s}", .{cfg.name});
        std.debug.print(" box", .{});
        std.debug.print("\n", .{});
        return 2;
    }
    var failed = false;
    if (std.mem.eql(u8, args[1], "all")) {
        for (&support.suites) |*cfg| {
            support.runSuite(cfg.*) catch {
                failed = true;
            };
        }
    } else {
        var it = std.mem.splitScalar(u8, args[1], ',');
        while (it.next()) |name| {
            if (std.mem.eql(u8, name, "box")) {
                const s = box.runCensus(arena.allocator(), "box_conformance") catch {
                    failed = true;
                    continue;
                };
                box.printSummary("box_conformance", s, box.BASELINE, box.MAX_FAILED);
                if (s.passed < box.BASELINE or s.failed > box.MAX_FAILED) failed = true;
                continue;
            }
            support.runSuiteNamed(name) catch |e| {
                if (e == error.UnknownSuite) return 2;
                failed = true;
            };
        }
    }
    if (failed) return 1;
    return 0;
}
