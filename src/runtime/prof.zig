//! Statistical PC sampler. Enabled with `KLIO_PROF=1`. Installs a SIGPROF
//! handler driven by an ITIMER_PROF timer (CPU-time, so it samples only while
//! the program actually runs), records the interrupted instruction pointer into
//! a fixed buffer (signal-safe: one atomic increment + one store, no alloc),
//! and at exit symbolizes the collected PCs into a by-function histogram.
//!
//! This is the ground-truth profiling tool for the interpreter. `clockMonotonicNanos`
//! is useless for profiling (it spins up a threaded Io per call); a sampler that
//! attributes wall-by-function is the right instrument.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const cpu_context = std.debug.cpu_context;

const MAX_SAMPLES = 1 << 22; // 4M slots; overflow simply stops recording.

var samples: [MAX_SAMPLES]usize = undefined;
var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var active: bool = false;

fn handler(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    const cc = cpu_context.fromPosixSignalContext(ctx) orelse return;
    const pc = cc.getPc();
    const i = count.fetchAdd(1, .monotonic);
    if (i < MAX_SAMPLES) samples[i] = pc;
}

/// Start sampling if `KLIO_PROF` is set. Interval defaults to 1ms (1000 Hz);
/// override microseconds with `KLIO_PROF=<usec>`.
pub fn maybeStart() void {
    if (builtin.os.tag != .linux) return;
    const env = if (builtin.link_libc) (std.c.getenv("KLIO_PROF") orelse return) else return;
    const env_s = std.mem.span(env);
    var usec: i64 = 1000;
    if (env_s.len > 0 and env_s[0] >= '0' and env_s[0] <= '9') {
        usec = std.fmt.parseInt(i64, env_s, 10) catch 1000;
        if (usec < 100) usec = 100;
    }
    active = true;
    var act = posix.Sigaction{
        .handler = .{ .sigaction = handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.SIGINFO | posix.SA.RESTART,
    };
    posix.sigaction(.PROF, &act, null);
    // NOTE: the kernel reads `setitimer`'s second field as MICROseconds even
    // though std types it as `nsec`. Put the microsecond count there directly.
    const its = linux.itimerspec{
        .it_interval = .{ .sec = @divFloor(usec, 1_000_000), .nsec = @mod(usec, 1_000_000) },
        .it_value = .{ .sec = @divFloor(usec, 1_000_000), .nsec = @mod(usec, 1_000_000) },
    };
    _ = linux.setitimer(@intFromEnum(linux.ITIMER.PROF), &its, null);
}

const NameCount = struct { name: []const u8, count: u32 };

/// Stop sampling and print the by-function histogram to stderr.
pub fn maybeReport() void {
    if (!active) return;
    active = false;
    const zero = linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 0 },
    };
    _ = linux.setitimer(@intFromEnum(linux.ITIMER.PROF), &zero, null);

    const total = @min(count.load(.monotonic), MAX_SAMPLES);
    if (total == 0) {
        std.debug.print("[prof] no samples collected\n", .{});
        return;
    }

    const gpa = std.heap.c_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Fold identical PCs first so symbolization runs once per unique address.
    var addr_counts = std.AutoHashMap(usize, u32).init(gpa);
    defer addr_counts.deinit();
    for (samples[0..total]) |pc| {
        const e = addr_counts.getOrPut(pc) catch continue;
        if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;
    }

    const io = std.Options.debug_io;
    const di = std.debug.getSelfDebugInfo() catch {
        std.debug.print("[prof] debug info unavailable\n", .{});
        return;
    };

    var by_name = std.StringHashMap(u32).init(gpa);
    defer by_name.deinit();

    var it = addr_counts.iterator();
    while (it.next()) |entry| {
        const addr = entry.key_ptr.*;
        const c = entry.value_ptr.*;
        var syms: std.ArrayList(std.debug.Symbol) = .empty;
        defer syms.deinit(gpa);
        di.getSymbols(io, gpa, arena, addr -| 1, false, &syms) catch {
            accumulate(&by_name, arena, "<unknown>", c);
            continue;
        };
        const nm: []const u8 = if (syms.items.len > 0 and syms.items[0].name != null)
            syms.items[0].name.?
        else
            "<unknown>";
        accumulate(&by_name, arena, nm, c);
    }

    // Sort by count descending.
    var list = std.ArrayList(NameCount).empty;
    defer list.deinit(gpa);
    var nit = by_name.iterator();
    while (nit.next()) |e| {
        list.append(gpa, .{ .name = e.key_ptr.*, .count = e.value_ptr.* }) catch {};
    }
    std.mem.sort(NameCount, list.items, {}, struct {
        fn lt(_: void, a: NameCount, b: NameCount) bool {
            return a.count > b.count;
        }
    }.lt);

    std.debug.print("\n[prof] {d} samples by function (top 35):\n", .{total});
    const ft: f64 = @floatFromInt(total);
    var shown: usize = 0;
    for (list.items) |nc| {
        if (shown >= 35) break;
        const pct = 100.0 * @as(f64, @floatFromInt(nc.count)) / ft;
        std.debug.print("  {d:>6.2}%  {d:>8}  {s}\n", .{ pct, nc.count, nc.name });
        shown += 1;
    }
}

fn accumulate(map: *std.StringHashMap(u32), arena: std.mem.Allocator, name: []const u8, c: u32) void {
    const e = map.getOrPut(name) catch return;
    if (e.found_existing) {
        e.value_ptr.* += c;
    } else {
        // Key may point into per-call arena memory that getSymbols recycles;
        // dupe into the persistent report arena.
        e.key_ptr.* = arena.dupe(u8, name) catch name;
        e.value_ptr.* = c;
    }
}
