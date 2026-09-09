//! Opt-in run accounting (`KLIO_RUN_STATS=1`), one line on stderr when the
//! program's `main` returns:
//!
//!   [run-stats] boot_ms=.. exec_ms=.. total_ms=.. rss_start_kb=.. rss_end_kb=.. rss_after_gc_kb=..
//!
//! `boot` is everything before the program runs (pack load, parse, lower, bake
//! or image assembly); `exec` is the program itself. `rss_start` is what the
//! process already holds when `main` is entered, and `rss_after_gc` is what
//! survives a full collection at exit — the residency a longer-lived program
//! would keep paying. Every entry point that runs a program (the CLI, a bundle,
//! the C-ABI entries a transpiled binary calls) reports through here, so the
//! numbers are comparable across them.

const std = @import("std");
const objcell = @import("objcell.zig");
const clock = @import("clock.zig");
const safety = @import("safety.zig");
const gc = @import("gc.zig");
const slab = @import("slab.zig");

var gate: enum { unset, on, off } = .unset;

/// Whether `KLIO_RUN_STATS` asked for the report.
pub fn enabled() bool {
    if (gate == .unset) gate = if (objcell.envOnce("KLIO_RUN_STATS") != null) .on else .off;
    return gate == .on;
}

var start_ns: ?u64 = null;
var exec_start_ns: u64 = 0;
var boot_ns: u64 = 0;
var exec_ns: u64 = 0;
var rss_start_kb: u64 = 0;

/// First instruction of the process entry point. Idempotent: the CLI marks it
/// in `main`, and the C-ABI entries mark it for a transpiled binary whose `main`
/// is not ours.
pub fn markStart() void {
    if (!enabled()) return;
    if (start_ns == null) start_ns = clock.monotonicNanos();
}

/// The program is about to run: boot is over.
pub fn markExecStart() void {
    if (!enabled()) return;
    const now = clock.monotonicNanos();
    if (start_ns == null) start_ns = now;
    exec_start_ns = now;
    boot_ns = now -| start_ns.?;
    rss_start_kb = safety.currentRssKb() orelse 0;
}

/// The program's `main` returned.
pub fn markExecEnd() void {
    if (!enabled()) return;
    exec_ns = clock.monotonicNanos() -| exec_start_ns;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

/// Collect once and print the line. A collection here is the point: it separates
/// the garbage the run happened to be holding from what it actually retains.
pub fn report() void {
    if (!enabled()) return;
    const rss_end_kb = safety.currentRssKb() orelse 0;
    const mapped_end_kb = slab.mapped_bytes.load(.monotonic) / 1024;
    var live_cells: usize = 0;
    if (gc.gc_enabled) {
        gc.collect();
        if (gc.release_to_os) |f| f();
        live_cells = gc.liveCellsAfterCollect();
    }
    const rss_after_kb = safety.currentRssKb() orelse 0;
    const mapped_after_kb = slab.mapped_bytes.load(.monotonic) / 1024;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "[run-stats] boot_ms={d:.1} exec_ms={d:.1} total_ms={d:.1} rss_start_kb={d} rss_end_kb={d} " ++
            "rss_after_gc_kb={d} mapped_end_kb={d} mapped_after_gc_kb={d} live_cells_after_gc={d}\n",
        .{
            ms(boot_ns),        ms(exec_ns),    ms(boot_ns + exec_ns),
            rss_start_kb,       rss_end_kb,     rss_after_kb,
            mapped_end_kb,      mapped_after_kb, live_cells,
        },
    ) catch return;
    safety.writeStderr(line);
}

test "disabled by default reports nothing and stays cheap" {
    if (objcell.envOnce("KLIO_RUN_STATS") != null) return error.SkipZigTest;
    try std.testing.expect(!enabled());
    markStart();
    markExecStart();
    markExecEnd();
    report();
    try std.testing.expectEqual(@as(u64, 0), boot_ns);
}
