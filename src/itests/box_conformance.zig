//! kotlinc's box corpus (`kotlin/compiler/testData/codegen/box`) through child
//! `klio run`s: each selected test's `box()` must return "OK". The pass floor
//! and failure ceiling sit exactly on the measured census.
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
