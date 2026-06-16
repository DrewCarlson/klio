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
/// `KLIO_RECLAIM=free`: a real freeing allocator (`smp_allocator`) with the
/// reference-counting reclamation path left OFF. Reclaims the host scratch and
/// container temporaries the run path explicitly frees (the bulk of a server's
/// per-request churn) without activating `ObjRef.deinit`'s value-graph teardown
/// (not yet reconciled on the coroutine/ktor host path). Safe for long-running
/// processes.
///
/// `KLIO_RECLAIM=smp`/`1`: a real freeing allocator (`smp_allocator`) with the
/// reference-counting reclamation path left ON. Use to measure that a
/// long-running process keeps memory bounded.
///
/// `KLIO_RECLAIM=debug`: a checking allocator (`DebugAllocator` with
/// thread-safety + safety quarantine) with reclamation ON. Use to surface
/// use-after-free / double-free / leaks at their source.
pub fn main(init: std.process.Init.Minimal) !u8 {
    const mode = runtime.allocChoice();
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
        .gc => {
            // Tracing GC (KGC): a freeing backing allocator + reachability-based
            // reclamation. Reference counting is neutralized (deinit/retain/
            // release no-op), so the collector alone frees, by reachability.
            runtime.gc.gc_enabled = true;
            if (runtime.getenvSlice("KLIO_GC_STRESS")) |v| {
                runtime.gc.gc_stress = v.len != 0 and !std.mem.eql(u8, v, "0");
            }
            if (runtime.getenvSlice("KLIO_GC_DEBUG")) |v| {
                runtime.gc.gc_debug = v.len != 0 and !std.mem.eql(u8, v, "0");
            }
            if (runtime.getenvSlice("KLIO_GC_NOFREE")) |v| {
                runtime.gc.gc_nofree = v.len != 0 and !std.mem.eql(u8, v, "0");
            }
            runtime.setReclaim(false);
            return cli.run(std.heap.smp_allocator, init.args);
        },
        .debug => {
            var dbg: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
            defer _ = dbg.deinit();
            return cli.run(dbg.allocator(), init.args);
        },
    }
}
