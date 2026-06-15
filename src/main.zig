const std = @import("std");
const cli = @import("cli");
const runtime = @import("runtime");

/// Backing-allocator selection for the process.
///
/// Default (`KLIO_RECLAIM` unset / `0`): the whole process runs on one
/// process-lifetime arena, freed once at exit. Per-cell `ObjRef.deinit` is the
/// arena fast path (`setReclaim(false)` in the run path), so reclamation is a
/// no-op — the arena reclaims everything wholesale.
///
/// `KLIO_RECLAIM=smp`/`1`: a real freeing allocator (`smp_allocator`) with the
/// reference-counting reclamation path left ON. Use to measure that a
/// long-running process keeps memory bounded.
///
/// `KLIO_RECLAIM=debug`: a checking allocator (`DebugAllocator` with
/// thread-safety + safety quarantine) with reclamation ON. Use to surface
/// use-after-free / double-free / leaks at their source.
pub fn main(init: std.process.Init.Minimal) !u8 {
    const mode = reclaimAllocMode();
    switch (mode) {
        .arena => {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = runtime.allocTrackWrap(arena.allocator());
            defer runtime.allocTrackReportStderr();
            return cli.run(a, init.args);
        },
        .smp => {
            return cli.run(std.heap.smp_allocator, init.args);
        },
        .debug => {
            var dbg: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
            defer _ = dbg.deinit();
            return cli.run(dbg.allocator(), init.args);
        },
    }
}

const AllocMode = enum { arena, smp, debug };

fn reclaimAllocMode() AllocMode {
    const v = runtime.reclaimRequested();
    if (!v) return .arena;
    const raw = runtime.getenvSlice("KLIO_RECLAIM") orelse return .smp;
    if (std.mem.eql(u8, raw, "debug")) return .debug;
    return .smp;
}
