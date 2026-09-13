const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const runtime = @import("runtime");

/// iOS and Android cannot symbolize their own image: the iOS simulator SDK
/// omits the dyld image-header lookup `SelfInfo` links against, and a packaged
/// app sends crashes to the OS reporter anyway. Panics route to a minimal
/// handler there so `SelfInfo` is never linked. Desktop keeps the full panic.
const is_mobile_target = runtime.trace.mobile;

pub const panic = if (is_mobile_target)
    std.debug.FullPanic(runtime.trace.panicFn)
else
    std.debug.FullPanic(std.debug.defaultPanic);

/// macOS: return every malloc zone's cached free pages to the OS. Called after
/// a sweep so RSS tracks the live set rather than cumulative churn.
extern "c" fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;
fn gcReleaseToOs() void {
    if (builtin.os.tag == .macos) _ = malloc_zone_pressure_relief(null, 0);
}

/// `KLIO_GC_GUARD`: panic with a stack trace on an absurdly sized allocation,
/// the signature of a use-after-free reading a corrupted length out of a swept
/// buffer, so the offending site is pinpointed instead of surfacing as a
/// distant out-of-memory.
fn guardAllocator(inner: std.mem.Allocator) std.mem.Allocator {
    const G = struct {
        var backing: std.mem.Allocator = undefined;
        // Armed only during program execution: startup legitimately reads the
        // multi-megabyte stdlib image.
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

/// Performance profile from argv (`--opt`/`-O`) and `KLIO_OPT`, resolved before
/// the backing allocator is chosen. Defaults to `fast`.
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

/// Every command runs on a large stack reserve, virtual until touched: lowering
/// deeply-chained expressions recurses past a default main-thread stack, and
/// only a cold bake reaches that path.
///
/// The reserve is an in-thread stack switch, not a worker thread, so the command
/// stays on the process main thread. AppKit and Metal reject calls from any
/// other thread, and a Compose UI program drives them from here.
const CliCtx = struct {
    a: std.mem.Allocator,
    args: std.process.Args,
};

fn cliBody(ctx: CliCtx) u8 {
    return cli.run(ctx.a, ctx.args) catch 1;
}

fn runCli(a: std.mem.Allocator, args: std.process.Args) u8 {
    return runtime.runOnBigStackMainThread(CliCtx, u8, cliBody, .{ .a = a, .args = args });
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    // The program thread reads its per-thread interpreter state from ordinary
    // globals, every other thread from a threadlocal. Claim before any
    // interpreter thread exists.
    runtime.tls_fast.claimOwner();
    runtime.runstats.markStart();
    // attachSegfaultHandler pulls the `SelfInfo` symbolizer, absent on mobile.
    if (comptime !is_mobile_target) {
        if (runtime.envOnce("KLIO_SEGV_TRACE")) |_| std.debug.attachSegfaultHandler();
    }
    if (runtime.envOnce("KLIO_PROF_ALL")) |_| runtime.prof.maybeStart();
    defer if (runtime.envOnce("KLIO_PROF_ALL")) |_| runtime.prof.maybeReport();
    // In bundle mode argv belongs to the embedded program, so the profile comes
    // from KLIO_OPT alone.
    runtime.perf.setProfile(if (cli.bundleModeActive())
        runtime.perf.resolveBinaryProfile(&.{})
    else
        resolveProfile(init.args));

    // Mobile has no diagnostic allocator modes: the branches below instantiate
    // `DebugAllocator`, whose leak reporting pulls `SelfInfo`. Take the
    // process-lifetime arena and comptime-drop the switch.
    if (comptime is_mobile_target) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = runtime.allocTrackWrap(arena.allocator());
        defer runtime.allocTrackReportStderr();
        return runCli(a, init.args);
    }

    const mode = runtime.allocChoice();
    switch (mode) {
        .arena => {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = runtime.allocTrackWrap(arena.allocator());
            defer runtime.allocTrackReportStderr();
            return runCli(a, init.args);
        },
        .smp => {
            return runCli(std.heap.smp_allocator, init.args);
        },
        .gc => {
            // Tracing collector: a freeing backing allocator plus
            // reachability-based reclamation. Reference counting no-ops, so the
            // collector alone frees.
            runtime.backing.configureGcFromEnv();
            if (runtime.envOnce("KLIO_GC_GUARD")) |v| {
                // GUARD=dbg: route the freeing backing through the checking
                // allocator so a use-after-free of a swept cell is caught at the
                // access.
                if (std.mem.eql(u8, v, "dbg")) {
                    var dbg: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
                    defer _ = dbg.deinit();
                    return runCli(dbg.allocator(), init.args);
                }
                return runCli(guardAllocator(std.heap.smp_allocator), init.args);
            }
            // The collector frees by reachability; the backend decides whether
            // reclaimed pages return to the OS. Default `slab` shares a slab
            // between same-size cells and unmaps it the instant its last cell is
            // freed, so RSS tracks the live set. KLIO_GC_ALLOC picks another:
            //   slab   (default) page-returning slab allocator
            //   smp              fastest; free-lists never return pages
            //   gpa              page-returning general-purpose allocator, slow
            //   calloc           libc malloc plus macOS pressure-relief trim
            const alloc_mode = runtime.envOnce("KLIO_GC_ALLOC") orelse "slab";
            // Returns stably-sparse regions to the OS after each sweep. The
            // non-slab backends override this hook or leave it over empty class
            // lists, where it no-ops.
            runtime.gc.release_to_os = runtime.slab.reclaimDormant;
            if (std.mem.eql(u8, alloc_mode, "smp")) {
                return runCli(std.heap.smp_allocator, init.args);
            }
            if (std.mem.eql(u8, alloc_mode, "gpa")) {
                var gpa: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = false, .stack_trace_frames = 10 }) = .init;
                defer _ = gpa.deinit();
                return runCli(gpa.allocator(), init.args);
            }
            if (std.mem.eql(u8, alloc_mode, "calloc")) {
                runtime.gc.release_to_os = gcReleaseToOs;
                return runCli(std.heap.c_allocator, init.args);
            }
            if (std.mem.eql(u8, alloc_mode, "leaktrack")) {
                if (runtime.envOnce("KLIO_LEAK_BY_FQN")) |_| runtime.leaktrack.by_fqn_only = true;
                const a = runtime.leaktrack.wrap(runtime.slab.allocator);
                runtime.leaktrack.installSignalDump();
                const rc = runCli(a, init.args);
                // Collect once more so merely-uncollected cells are freed before
                // the report; what remains is a genuine host-temporary leak.
                runtime.gc.collect();
                if (runtime.envOnce("KLIO_LEAK_BY_FQN")) |_|
                    runtime.leaktrack.reportByFqn()
                else
                    runtime.leaktrack.report();
                return rc;
            }
            if (runtime.envOnce("KLIO_SLAB_TRACE")) |_| {
                runtime.slab.trace_enabled = true;
                runtime.slab.installTraceSignalDump();
                const rc = runCli(runtime.slab.allocator, init.args);
                runtime.slab.traceReport();
                return rc;
            }
            if (runtime.envOnce("KLIO_CELL_TRACE")) |_| {
                runtime.slab.cell_trace_enabled = true;
                runtime.slab.installTraceSignalDump();
                const rc = runCli(runtime.slab.allocator, init.args);
                runtime.slab.traceReport();
                return rc;
            }
            if (runtime.envOnce("KLIO_SLAB_STAT")) |_| {
                const rc = runCli(runtime.slab.allocator, init.args);
                std.debug.print(
                    "[slab] mapped_bytes={d} ({d} MB)\n",
                    .{ runtime.slab.mapped_bytes.load(.monotonic), runtime.slab.mapped_bytes.load(.monotonic) / (1024 * 1024) },
                );
                return rc;
            }
            return runCli(runtime.slab.allocator, init.args);
        },
        .debug => {
            var dbg: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
            defer _ = dbg.deinit();
            return runCli(dbg.allocator(), init.args);
        },
    }
}
