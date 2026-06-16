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
/// Diagnostic backing allocator (KLIO_GC_GUARD): panic with a stack trace on an
/// allocation whose size is absurd (the signature of a use-after-free reading a
/// corrupted length out of a swept buffer), so the offending site is pinpointed
/// instead of surfacing as a generic out-of-memory far away.
fn guardAllocator(inner: std.mem.Allocator) std.mem.Allocator {
    const G = struct {
        var backing: std.mem.Allocator = undefined;
        // Only arm during program execution (alloc_perm flips false in vmRun);
        // startup reads the multi-MB stdlib image while still permanent.
        const LIMIT = 1 << 20; // 1 MB
        fn armed(len: usize) bool {
            return len > LIMIT and runtime.gc.program_started;
        }
        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            _ = ctx;
            if (armed(len)) @panic("KGC guard: absurd allocation size (likely UAF on a swept buffer)");
            return backing.rawAlloc(len, a, ra);
        }
        fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) bool {
            _ = ctx;
            if (armed(new)) @panic("KGC guard: absurd resize size (likely UAF on a swept buffer)");
            return backing.rawResize(buf, a, new, ra);
        }
        fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) ?[*]u8 {
            _ = ctx;
            if (armed(new)) @panic("KGC guard: absurd remap size (likely UAF on a swept buffer)");
            return backing.rawRemap(buf, a, new, ra);
        }
        fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
            _ = ctx;
            backing.rawFree(buf, a, ra);
        }
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    };
    G.backing = inner;
    return .{ .ptr = undefined, .vtable = &G.vtable };
}

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
            if (runtime.getenvSlice("KLIO_GC_THRESHOLD_KB")) |v| {
                if (std.fmt.parseInt(usize, v, 10) catch null) |kb| {
                    if (kb != 0) runtime.gc.setThresholdFloor(kb * 1024);
                }
            }
            if (runtime.getenvSlice("KLIO_GC_STRESS_EVERY")) |v| {
                runtime.gc.gc_stress_every = std.fmt.parseInt(usize, v, 10) catch 0;
            }
            runtime.setReclaim(false);
            if (runtime.getenvSlice("KLIO_GC_GUARD")) |v| {
                // GUARD=dbg: route the GC's freeing backing through the checking
                // allocator so a use-after-free of a swept cell is caught at the
                // access with a stack trace, not as a far-away corruption.
                if (std.mem.eql(u8, v, "dbg")) {
                    var dbg: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
                    defer _ = dbg.deinit();
                    return cli.run(dbg.allocator(), init.args);
                }
                return cli.run(guardAllocator(std.heap.smp_allocator), init.args);
            }
            return cli.run(std.heap.smp_allocator, init.args);
        },
        .debug => {
            var dbg: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
            defer _ = dbg.deinit();
            return cli.run(dbg.allocator(), init.args);
        },
    }
}
