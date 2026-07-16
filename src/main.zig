const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const runtime = @import("runtime");

/// macOS: ask every malloc zone to return its cached free pages to the OS.
/// Called by the collector after a sweep so process RSS tracks the live set,
/// not the cumulative allocation churn the libc free-lists would otherwise hold.
extern "c" fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;
fn gcReleaseToOs() void {
    if (builtin.os.tag == .macos) _ = malloc_zone_pressure_relief(null, 0);
}

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

/// Resolve the performance profile from argv (`--opt`/`-O`) and `KLIO_OPT`
/// before the backing allocator is chosen, defaulting to `fast` for the binary.
fn resolveProfile(args: std.process.Args) runtime.perf.Profile {
    const pa = std.heap.page_allocator;
    var it = args.iterateAllocator(pa) catch return runtime.perf.resolveBinaryProfile(&.{});
    defer it.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |s| pa.free(s);
        list.deinit(pa);
    }
    while (it.next()) |a| {
        const d = pa.dupe(u8, a) catch break;
        list.append(pa, d) catch {
            pa.free(d);
            break;
        };
    }
    return runtime.perf.resolveBinaryProfile(list.items);
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    if (runtime.getenvSlice("KLIO_SEGV_TRACE")) |_| std.debug.attachSegfaultHandler();
    if (runtime.getenvSlice("KLIO_PROF_ALL")) |_| runtime.prof.maybeStart();
    defer if (runtime.getenvSlice("KLIO_PROF_ALL")) |_| runtime.prof.maybeReport();
    // In bundle mode argv belongs entirely to the embedded program, so the
    // performance profile comes from the environment (KLIO_OPT) alone.
    runtime.perf.setProfile(if (cli.bundleModeActive())
        runtime.perf.resolveBinaryProfile(&.{})
    else
        resolveProfile(init.args));
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
            if (runtime.getenvSlice("KLIO_GC_HIST")) |v| {
                runtime.gc.gc_hist = v.len != 0 and !std.mem.eql(u8, v, "0");
            }
            if (runtime.getenvSlice("KLIO_GC_NOFREE")) |v| {
                runtime.gc.gc_nofree = v.len != 0 and !std.mem.eql(u8, v, "0");
            }
            if (runtime.getenvSlice("KLIO_GC_EXT")) |v| {
                runtime.gc.external_accounting = v.len != 0 and !std.mem.eql(u8, v, "0");
            }
            if (runtime.getenvSlice("KLIO_GC_POISON")) |v| {
                runtime.gc.gc_poison = v.len != 0 and !std.mem.eql(u8, v, "0");
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
            // Backing allocator. The collector frees by reachability, but the
            // backend decides whether reclaimed pages return to the OS. The
            // default is the slab allocator (`runtime.slab`): same-size cells
            // share a slab, and a slab returns to the OS the instant its last
            // cell is freed — so RSS tracks the live set, not cumulative churn.
            // The stock free-list allocators never return pages (RSS grew with
            // total work even though the collector kept the live set flat).
            // KLIO_GC_ALLOC selects an alternative for comparison:
            //   slab   (default) — page-returning slab allocator
            //   smp              — fastest; free-lists never return pages
            //   gpa              — page-returning general-purpose allocator (slow)
            //   calloc           — libc malloc + macOS pressure-relief trim
            const alloc_mode = runtime.getenvSlice("KLIO_GC_ALLOC") orelse "slab";
            // The slab backend returns the pages of stably-sparse regions to the OS
            // after each sweep; the non-slab backends below either override this or
            // do not touch the slab (the hook then no-ops over empty class lists).
            runtime.gc.release_to_os = runtime.slab.reclaimDormant;
            if (std.mem.eql(u8, alloc_mode, "smp")) {
                return cli.run(std.heap.smp_allocator, init.args);
            }
            if (std.mem.eql(u8, alloc_mode, "gpa")) {
                var gpa: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = false, .stack_trace_frames = 10 }) = .init;
                defer _ = gpa.deinit();
                return cli.run(gpa.allocator(), init.args);
            }
            if (std.mem.eql(u8, alloc_mode, "calloc")) {
                runtime.gc.release_to_os = gcReleaseToOs;
                return cli.run(std.heap.c_allocator, init.args);
            }
            if (std.mem.eql(u8, alloc_mode, "leaktrack")) {
                if (runtime.getenvSlice("KLIO_LEAK_BY_FQN")) |_| runtime.leaktrack.by_fqn_only = true;
                const a = runtime.leaktrack.wrap(runtime.slab.allocator);
                runtime.leaktrack.installSignalDump();
                const rc = cli.run(a, init.args);
                // Force a final collection so GC-managed cells that were merely
                // uncollected (not leaked) are freed before the report; what
                // remains outstanding is the genuine raw host-temporary leak.
                runtime.gc.collect();
                if (runtime.getenvSlice("KLIO_LEAK_BY_FQN")) |_|
                    runtime.leaktrack.reportByFqn()
                else
                    runtime.leaktrack.report();
                return rc;
            }
            if (runtime.getenvSlice("KLIO_SLAB_TRACE")) |_| {
                runtime.slab.trace_enabled = true;
                runtime.slab.installTraceSignalDump();
                const rc = cli.run(runtime.slab.allocator, init.args);
                runtime.slab.traceReport();
                return rc;
            }
            if (runtime.getenvSlice("KLIO_CELL_TRACE")) |_| {
                runtime.slab.cell_trace_enabled = true;
                runtime.slab.installTraceSignalDump();
                const rc = cli.run(runtime.slab.allocator, init.args);
                runtime.slab.traceReport();
                return rc;
            }
            if (runtime.getenvSlice("KLIO_SLAB_STAT")) |_| {
                const rc = cli.run(runtime.slab.allocator, init.args);
                std.debug.print(
                    "[slab] mapped_bytes={d} ({d} MB)\n",
                    .{ runtime.slab.mapped_bytes.load(.monotonic), runtime.slab.mapped_bytes.load(.monotonic) / (1024 * 1024) },
                );
                return rc;
            }
            return cli.run(runtime.slab.allocator, init.args);
        },
        .debug => {
            var dbg: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
            defer _ = dbg.deinit();
            return cli.run(dbg.allocator(), init.args);
        },
    }
}
