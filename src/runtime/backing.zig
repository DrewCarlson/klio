//! Process backing setup: the collector's knobs and the allocator family a
//! program runs on. Every entry point that runs a program comes through here —
//! the `klio` binary, a bundle, and the C-ABI entries a transpiled binary calls
//! — so a transpiled program gets the same collector and the same
//! page-returning slab as `klio run`, instead of the never-free arena it used
//! to fall back to (measured: same program, 144 MB peak vs 93 MB interpreted).

const std = @import("std");
const objcell = @import("objcell.zig");
const gc = @import("gc.zig");
const slab = @import("slab.zig");
const perf = @import("perf.zig");

fn envOn(comptime name: [:0]const u8) ?bool {
    const v = objcell.envOnce(name) orelse return null;
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

/// Turn on the tracing collector and apply its diagnostic knobs. Idempotent.
/// The caller still chooses the backing allocator (`processAllocator`, or one
/// of the diagnostic families the CLI exposes).
pub fn configureGcFromEnv() void {
    // Tracing GC (KGC): a freeing backing allocator + reachability-based
    // reclamation. Reference counting is neutralized (deinit/retain/release
    // no-op), so the collector alone frees, by reachability.
    gc.gc_enabled = true;
    if (envOn("KLIO_GC_STRESS")) |v| gc.gc_stress = v;
    if (envOn("KLIO_GC_DEBUG")) |v| gc.gc_debug = v;
    if (envOn("KLIO_GC_HIST")) |v| gc.gc_hist = v;
    if (envOn("KLIO_GC_NOFREE")) |v| gc.gc_nofree = v;
    if (envOn("KLIO_GC_EXT")) |v| gc.external_accounting = v;
    if (envOn("KLIO_GC_POISON")) |v| gc.gc_poison = v;
    if (envOn("KLIO_GC_MINOR_STOP")) |v| gc.minor_stops_at_tenured = v;
    if (envOn("KLIO_GC_GEN")) |v| gc.generational = v;
    if (objcell.envOnce("KLIO_GC_THRESHOLD_KB")) |v| {
        if (std.fmt.parseInt(usize, v, 10) catch null) |kb| {
            if (kb != 0) gc.setThresholdFloor(kb * 1024);
        }
    }
    if (objcell.envOnce("KLIO_GC_STRESS_EVERY")) |v| {
        gc.gc_stress_every = std.fmt.parseInt(usize, v, 10) catch 0;
    }
    objcell.setReclaim(false);
    // The slab backend returns the pages of stably-sparse regions to the OS
    // after each sweep; a caller selecting another backend overrides this.
    gc.release_to_os = slab.reclaimDormant;
}

/// The backing allocator for the resolved performance profile, with the
/// collector configured when the profile asks for it. The arena profile fills
/// `arena_slot`; the caller owns its teardown.
pub fn processAllocator(arena_slot: *?std.heap.ArenaAllocator) std.mem.Allocator {
    switch (perf.allocChoice()) {
        .gc => {
            configureGcFromEnv();
            return slab.allocator;
        },
        .smp => return std.heap.smp_allocator,
        .arena, .debug => {
            arena_slot.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            return arena_slot.*.?.allocator();
        },
    }
}

test "the gc profile configures the collector and hands back the slab" {
    const prev = gc.gc_enabled;
    defer gc.gc_enabled = prev;
    const prev_release = gc.release_to_os;
    defer gc.release_to_os = prev_release;
    perf.setProfile(.fast);
    defer perf.setProfile(null);
    var arena: ?std.heap.ArenaAllocator = null;
    defer if (arena) |*a| a.deinit();
    const a = processAllocator(&arena);
    try std.testing.expect(gc.gc_enabled);
    try std.testing.expect(gc.release_to_os != null);
    try std.testing.expect(arena == null);
    const buf = try a.alloc(u8, 32);
    a.free(buf);
}
