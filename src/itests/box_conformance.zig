//! kotlinc's box-test conformance corpus (`kotlin/compiler/testData/codegen/box`)
//! run through child `klio run`s: every selected test's `box()` must return
//! `"OK"`. The pass count is a ratchet floor and the failure count a ceiling
//! with no slack — both equal the measured census, and each root fix moves
//! them (floor up, ceiling down). Selection is by directive
//! (`box_support.zig`); the exclusion census is printed with every run.
const std = @import("std");
const box = @import("box_support.zig");

const BASELINE = box.BASELINE;
const MAX_FAILED = box.MAX_FAILED;

test "box conformance corpus holds its ratchet" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const s = try box.runCensus(arena.allocator(), "box_conformance");
    box.printSummary("box_conformance", s, BASELINE, MAX_FAILED);
    try std.testing.expect(s.passed >= BASELINE);
    try std.testing.expect(s.failed <= MAX_FAILED);
}
