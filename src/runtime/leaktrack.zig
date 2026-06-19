//! Diagnostic leak locator (KLIO_GC_ALLOC=leaktrack). Wraps a child allocator,
//! keys every outstanding allocation by its capture stack, and at process exit
//! dumps the sites holding the most un-freed bytes. Under the tracing GC the
//! collector frees cells by reachability, so what remains outstanding at exit is
//! the live set plus any raw host-temporary the port never frees — this names
//! those sites directly, ranked by bytes. Scaffolding, not a production path.

const std = @import("std");
const gc = @import("gc.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const FRAMES = 12;

const Record = struct {
    len: usize,
    addrs: [FRAMES]usize,
    n: usize,
    /// The intrinsic fqn active when this allocation was made (a `back`-owned
    /// copy), or "" for allocations outside any intrinsic. Lets `reportByFqn`
    /// attribute leaked raw scratch to the specific stdlib op that made it —
    /// the stack alone collapses every intrinsic to the `func(&ctx)` call site.
    fqn: []const u8 = "",
};

/// Set by `dispatchIntrinsic` around `func(&ctx)`: the fqn of the intrinsic
/// currently executing on this thread (innermost wins; nested intrinsic calls
/// save/restore it). Read by `note` to tag each allocation. No-op overhead when
/// leaktrack is not the backing allocator (just a threadlocal pointer write).
pub threadlocal var current_fqn: ?[]const u8 = null;

const Site = struct {
    addrs: [FRAMES]usize,
    n: usize,
    bytes: usize,
    count: usize,
};

const back = std.heap.page_allocator;

var lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
fn acquire() void {
    while (lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn release() void {
    lock.store(false, .release);
}

var live: std.AutoHashMapUnmanaged(usize, Record) = .empty;
var child_alloc: Allocator = undefined;
var initialized: bool = false;

fn capture(ret: usize) Record {
    var r: Record = .{ .len = 0, .addrs = undefined, .n = 0 };
    const st = std.debug.captureCurrentStackTrace(.{ .first_address = ret }, &r.addrs);
    r.n = st.return_addresses.len;
    return r;
}

fn note(ptr: [*]u8, len: usize, ret: usize) void {
    acquire();
    defer release();
    var rec = capture(ret);
    rec.len = len;
    rec.fqn = if (current_fqn) |f| (back.dupe(u8, f) catch "") else "";
    live.put(back, @intFromPtr(ptr), rec) catch return;
}

fn forget(ptr: [*]u8) void {
    acquire();
    defer release();
    if (live.fetchRemove(@intFromPtr(ptr))) |kv| {
        if (kv.value.fqn.len != 0) back.free(kv.value.fqn);
    }
}

fn alloc(_: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
    const p = child_alloc.rawAlloc(len, a, ra) orelse return null;
    // Only attribute allocations made during program execution; the static
    // image (parser/stdlib build) is permanent baseline and would drown out the
    // per-iteration host-temporary leaks this hunts.
    if (gc.program_started) note(p, len, @returnAddress());
    return p;
}
fn resize(_: *anyopaque, buf: []u8, a: Alignment, new: usize, ra: usize) bool {
    if (!child_alloc.rawResize(buf, a, new, ra)) return false;
    acquire();
    defer release();
    if (live.getPtr(@intFromPtr(buf.ptr))) |r| r.len = new;
    return true;
}
fn remap(_: *anyopaque, buf: []u8, a: Alignment, new: usize, ra: usize) ?[*]u8 {
    const p = child_alloc.rawRemap(buf, a, new, ra) orelse return null;
    forget(buf.ptr);
    note(p, new, @returnAddress());
    return p;
}
fn free(_: *anyopaque, buf: []u8, a: Alignment, ra: usize) void {
    forget(buf.ptr);
    child_alloc.rawFree(buf, a, ra);
}

const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

/// Wrap `child`; all subsequent allocations are tracked until `report`.
pub fn wrap(child: Allocator) Allocator {
    child_alloc = child;
    initialized = true;
    return .{ .ptr = undefined, .vtable = &vtable };
}

fn onSignal(_: std.c.SIG) callconv(.c) void {
    report();
    std.c._exit(0);
}

/// Install a SIGTERM/SIGINT handler that dumps the report and exits. Used to
/// profile a long-running server (which never returns from `main`): the load
/// harness `kill`s the process and the handler runs the report first.
pub fn installSignalDump() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// Dump outstanding bytes grouped by the intrinsic fqn that allocated them
/// (KLIO_LEAK_BY_FQN). After a final collect, GC-managed result cells are gone,
/// so what remains under an fqn is the raw scratch that intrinsic leaks per call.
pub fn reportByFqn() void {
    if (!initialized) return;
    const Bucket = struct { fqn: []const u8, bytes: usize, count: usize };
    var buckets: std.ArrayListUnmanaged(Bucket) = .empty;
    acquire();
    var it = live.iterator();
    outer: while (it.next()) |e| {
        const rec = e.value_ptr;
        for (buckets.items) |*b| {
            if (std.mem.eql(u8, b.fqn, rec.fqn)) {
                b.bytes += rec.len;
                b.count += 1;
                continue :outer;
            }
        }
        buckets.append(back, .{ .fqn = rec.fqn, .bytes = rec.len, .count = 1 }) catch {};
    }
    release();
    std.sort.pdq(Bucket, buckets.items, {}, struct {
        fn lt(_: void, x: Bucket, y: Bucket) bool {
            return x.bytes > y.bytes;
        }
    }.lt);
    std.debug.print("\n[leaktrack-by-fqn] outstanding bytes per intrinsic:\n", .{});
    var shown: usize = 0;
    for (buckets.items) |*b| {
        if (shown >= 40) break;
        shown += 1;
        const label = if (b.fqn.len == 0) "<non-intrinsic>" else b.fqn;
        std.debug.print("  {d:>10} bytes  {d:>6} allocs  {s}\n", .{ b.bytes, b.count, label });
    }
}

fn sameSite(a: *const Record, b: *const Site) bool {
    if (a.n != b.n) return false;
    var i: usize = 0;
    while (i < a.n) : (i += 1) if (a.addrs[i] != b.addrs[i]) return false;
    return true;
}

/// Dump the top outstanding-byte sites to stderr, symbolized.
pub fn report() void {
    if (!initialized) return;
    acquire();
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var it = live.iterator();
    outer: while (it.next()) |e| {
        const rec = e.value_ptr;
        for (sites.items) |*s| {
            if (sameSite(rec, s)) {
                s.bytes += rec.len;
                s.count += 1;
                continue :outer;
            }
        }
        var s: Site = .{ .addrs = rec.addrs, .n = rec.n, .bytes = rec.len, .count = 1 };
        s.addrs = rec.addrs;
        sites.append(back, s) catch {};
    }
    release();
    std.sort.pdq(Site, sites.items, {}, struct {
        fn lt(_: void, x: Site, y: Site) bool {
            return x.bytes > y.bytes;
        }
    }.lt);
    var shown: usize = 0;
    for (sites.items) |*s| {
        if (shown >= 25) break;
        shown += 1;
        std.debug.print("\n[leaktrack] outstanding {d} bytes in {d} allocs:\n", .{ s.bytes, s.count });
        const st: std.debug.StackTrace = .{ .return_addresses = s.addrs[0..s.n], .skipped = .none };
        std.debug.dumpStackTrace(&st);
    }
}
