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

/// The three sample tables are `mmap`ed by `maybeStart`, never declared as
/// static arrays. At 4M slots each they are 32 MB apiece, and a Debug build
/// fills an `undefined` global with a poison pattern — so as statics they could
/// not live in `.bss` and became 96 MB of real bytes in EVERY binary, for a
/// sampler that is off unless `KLIO_PROF` is set (they were the bulk of a
/// 525 MB `klio`). Null until started; the handler bails on null.
var samples: ?[*]usize = null;
/// Caller PC (one frame up via the frame pointer, Debug builds keep it),
/// 0 when unavailable — lets the report attribute a hot leaf to its
/// callers (`KLIO_PROF_CALLERS=<leaf-substring>`).
var callers: ?[*]usize = null;
var callers2: ?[*]usize = null;

/// Reserve the sample tables. Anonymous `mmap`, so the pages are committed by
/// the kernel only as the sampler actually touches them.
fn allocTables() bool {
    const bytes = MAX_SAMPLES * @sizeOf(usize);
    const m = std.posix.mmap(
        null,
        bytes * 3,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return false;
    const base: [*]usize = @ptrCast(@alignCast(m.ptr));
    samples = base;
    callers = base + MAX_SAMPLES;
    callers2 = base + 2 * MAX_SAMPLES;
    return true;
}
var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var active: bool = false;

fn handler(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    const cc = cpu_context.fromPosixSignalContext(ctx) orelse return;
    const pc = cc.getPc();
    const sm = samples orelse return;
    const c1 = callers orelse return;
    const c2 = callers2 orelse return;
    const i = count.fetchAdd(1, .monotonic);
    if (i < MAX_SAMPLES) {
        sm[i] = pc;
        const pair = callerPcsFromContext(ctx);
        c1[i] = pair[0];
        c2[i] = pair[1];
    }
}

/// One frame up: read the saved return address through the frame pointer
/// (Debug builds keep it). Signal-safe (guarded loads); returns 0 when
/// the frame pointer looks bogus.
fn callerPcsFromContext(ctx: ?*anyopaque) [2]usize {
    if (builtin.cpu.arch != .x86_64) return .{ 0, 0 };
    const cc = cpu_context.fromPosixSignalContext(ctx) orelse return .{ 0, 0 };
    const sp: usize = @intCast(cc.gprs.get(.rsp));
    var bp: usize = @intCast(cc.gprs.get(.rbp));
    var out: [2]usize = .{ 0, 0 };
    for (0..2) |lvl| {
        // The frame pointer must sit on this stack, above SP and within a
        // sane window — anything else is a leaf without FP or a foreign
        // register value, and dereferencing it in a signal handler kills
        // the process.
        if (bp <= sp or bp - sp > (1 << 23) or bp % @alignOf(usize) != 0) break;
        const ret_ptr: *const usize = @ptrFromInt(bp + @sizeOf(usize));
        out[lvl] = ret_ptr.*;
        const next_ptr: *const usize = @ptrFromInt(bp);
        const next = next_ptr.*;
        if (next <= bp) break;
        bp = next;
    }
    return out;
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
    if (!allocTables()) return;
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
    if (builtin.os.tag != .linux) return;
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
    const sm = (samples orelse return)[0..total];
    for (sm) |pc| {
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

    // Caller attribution for one hot leaf: KLIO_PROF_CALLERS=<substring>
    // folds the CALLER PCs of every sample whose leaf symbol contains the
    // substring, naming who drives it.
    const want_env = if (builtin.link_libc) std.c.getenv("KLIO_PROF_CALLERS") else null;
    if (want_env) |we| {
        const want = std.mem.span(we);
        var leaf_cache = std.AutoHashMap(usize, bool).init(gpa);
        defer leaf_cache.deinit();
        var caller_counts = std.AutoHashMap(usize, u32).init(gpa);
        defer caller_counts.deinit();
        var matched: usize = 0;
        for (sm, (callers orelse return)[0..total], (callers2 orelse return)[0..total]) |pc, caller, caller2| {
            const is_leaf = blk: {
                const g = leaf_cache.getOrPut(pc) catch break :blk false;
                if (g.found_existing) break :blk g.value_ptr.*;
                var syms: std.ArrayList(std.debug.Symbol) = .empty;
                defer syms.deinit(gpa);
                di.getSymbols(io, gpa, arena, pc -| 1, false, &syms) catch {
                    g.value_ptr.* = false;
                    break :blk false;
                };
                const nm: []const u8 = if (syms.items.len > 0 and syms.items[0].name != null) syms.items[0].name.? else "";
                g.value_ptr.* = std.mem.indexOf(u8, nm, want) != null;
                break :blk g.value_ptr.*;
            };
            if (!is_leaf) continue;
            matched += 1;
            // Attribute one entry per level so a thin wrapper's own caller
            // shows up alongside it.
            const e = caller_counts.getOrPut(caller) catch continue;
            if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;
            if (caller2 != 0) {
                const e2 = caller_counts.getOrPut(caller2) catch continue;
                if (e2.found_existing) e2.value_ptr.* += 1 else e2.value_ptr.* = 1;
            }
        }
        var cby_name = std.StringHashMap(u32).init(gpa);
        defer cby_name.deinit();
        var cit = caller_counts.iterator();
        while (cit.next()) |e| {
            const addr = e.key_ptr.*;
            if (addr == 0) {
                accumulate(&cby_name, arena, "<no-fp>", e.value_ptr.*);
                continue;
            }
            var syms: std.ArrayList(std.debug.Symbol) = .empty;
            defer syms.deinit(gpa);
            di.getSymbols(io, gpa, arena, addr -| 1, false, &syms) catch {
                accumulate(&cby_name, arena, "<unknown>", e.value_ptr.*);
                continue;
            };
            const nm: []const u8 = if (syms.items.len > 0 and syms.items[0].name != null) syms.items[0].name.? else "<unknown>";
            accumulate(&cby_name, arena, nm, e.value_ptr.*);
        }
        var clist = std.ArrayList(NameCount).empty;
        defer clist.deinit(gpa);
        var cnit = cby_name.iterator();
        while (cnit.next()) |e| clist.append(gpa, .{ .name = e.key_ptr.*, .count = e.value_ptr.* }) catch {};
        std.mem.sort(NameCount, clist.items, {}, struct {
            fn lt(_: void, a: NameCount, b: NameCount) bool {
                return a.count > b.count;
            }
        }.lt);
        std.debug.print("[prof] callers of leaves matching \"{s}\" ({d} samples):\n", .{ want, matched });
        var cshown: usize = 0;
        for (clist.items) |nc| {
            if (cshown >= 15) break;
            std.debug.print("  {d:>8}  {s}\n", .{ nc.count, nc.name });
            cshown += 1;
        }
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
