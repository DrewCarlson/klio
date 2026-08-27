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
    // FP-less leaf (compiler-rt memset, libc): the frame pointer still holds
    // the CALLER's frame, so the leaf's return address is on the stack between
    // SP and BP. Scan that window for the first own-text address and report it
    // as the caller — heuristic (a spilled stale return address can match),
    // but it turns an unattributable <no-fp> bucket into the right caller for
    // the overwhelmingly common case.
    if (out[0] == 0) {
        const anchor = @intFromPtr(&handler);
        const lo = anchor -| (1 << 29);
        const hi = anchor +| (1 << 29);
        const cap: usize = if (bp > sp and bp - sp < (1 << 12)) bp else sp + (1 << 9);
        var p = sp;
        while (p + @sizeOf(usize) <= cap) : (p += @sizeOf(usize)) {
            if (p % @alignOf(usize) != 0) break;
            const v = @as(*const usize, @ptrFromInt(p)).*;
            if (v > lo and v < hi and v != anchor) {
                out[0] = v;
                break;
            }
        }
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

// ---------------------------------------------------------------------------
// Opcode sampler (`KLIO_OP_PROF`): instead of machine PCs (which the linker's
// identical-code folding merges into unattributable blobs), sample the
// interpreter's own "currently executing opcode" tag. The eval loop stores
// each instruction's enum tag into `current_op` (a threadlocal, gated on
// `op_prof_active`); the SIGPROF handler increments a per-tag counter. The
// innermost frame's store wins, so the histogram reads as self-time by
// opcode — including time spent inside the host machinery an opcode
// dispatches into. Works on macOS and Linux (libc setitimer).
// ---------------------------------------------------------------------------

pub var op_prof_active: bool = false;
pub threadlocal var current_op: u16 = OP_OUTSIDE;
/// Tag meaning "not inside execInst" (startup, host-only threads, GC).
pub const OP_OUTSIDE: u16 = 0x1FF;
/// Host-route sub-tags: stages inside a dispatch arm set these so the
/// histogram splits an opcode's time by route. The eval loop overwrites the
/// tag at the next instruction, so a route tag covers exactly the host work
/// until either the callee's first instruction or the next stage marker.
pub const OP_ROUTE_BASE: u16 = 0x100;
pub inline fn opRoute(route: u16) void {
    if (op_prof_active) current_op = OP_ROUTE_BASE + route;
}
const OP_SLOTS = 512;
var op_hist: [OP_SLOTS]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));

const c_itimerval = extern struct {
    it_interval: std.c.timeval,
    it_value: std.c.timeval,
};
extern "c" fn setitimer(which: c_int, new: *const c_itimerval, old: ?*c_itimerval) c_int;
const ITIMER_PROF_C: c_int = 2;

fn opHandler(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx;
    _ = op_hist[current_op & (OP_SLOTS - 1)].fetchAdd(1, .monotonic);
}

pub fn opProfMaybeStart() void {
    if (comptime !builtin.link_libc) return;
    const env = std.c.getenv("KLIO_OP_PROF") orelse return;
    const env_s = std.mem.span(env);
    var usec: i64 = 1000;
    if (env_s.len > 0 and env_s[0] >= '0' and env_s[0] <= '9') {
        usec = std.fmt.parseInt(i64, env_s, 10) catch 1000;
        if (usec < 100) usec = 100;
    }
    op_prof_active = true;
    var act = posix.Sigaction{
        .handler = .{ .sigaction = opHandler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.SIGINFO | posix.SA.RESTART,
    };
    posix.sigaction(.PROF, &act, null);
    const itv = c_itimerval{
        .it_interval = .{ .sec = @intCast(@divFloor(usec, 1_000_000)), .usec = @intCast(@mod(usec, 1_000_000)) },
        .it_value = .{ .sec = @intCast(@divFloor(usec, 1_000_000)), .usec = @intCast(@mod(usec, 1_000_000)) },
    };
    _ = setitimer(ITIMER_PROF_C, &itv, null);
}

// ---------------------------------------------------------------------------
// Kotlin-function sampler (`KLIO_FN_PROF`): the PC sampler attributes time to
// INTERPRETER functions; this one attributes it to the interpreted program's
// own functions. `runFrameExec` stamps the executing func id into a
// threadlocal (gated on `fn_prof_active`) and restores the caller's on exit,
// so the histogram reads as self-time per Kotlin function — the census that
// says which library bodies are worth serving natively.
// ---------------------------------------------------------------------------

pub var fn_prof_active: bool = false;
pub threadlocal var current_fn: u32 = FN_OUTSIDE;
/// Id meaning "not inside an interpreted frame".
pub const FN_OUTSIDE: u32 = 0xFFFF_FFFF;
const FN_SLOTS: usize = 1 << 17;
var fn_hist: [FN_SLOTS]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0));

fn fnHandler(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx;
    const f = current_fn;
    if (f == FN_OUTSIDE) return;
    _ = fn_hist[f & (FN_SLOTS - 1)].fetchAdd(1, .monotonic);
}

pub fn fnProfMaybeStart() void {
    if (comptime !builtin.link_libc) return;
    const env = std.c.getenv("KLIO_FN_PROF") orelse return;
    const env_s = std.mem.span(env);
    var usec: i64 = 1000;
    if (env_s.len > 0 and env_s[0] >= '0' and env_s[0] <= '9') {
        usec = std.fmt.parseInt(i64, env_s, 10) catch 1000;
        if (usec < 100) usec = 100;
    }
    fn_prof_active = true;
    var act = posix.Sigaction{
        .handler = .{ .sigaction = fnHandler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.SIGINFO | posix.SA.RESTART,
    };
    posix.sigaction(.PROF, &act, null);
    const itv = c_itimerval{
        .it_interval = .{ .sec = @intCast(@divFloor(usec, 1_000_000)), .usec = @intCast(@mod(usec, 1_000_000)) },
        .it_value = .{ .sec = @intCast(@divFloor(usec, 1_000_000)), .usec = @intCast(@mod(usec, 1_000_000)) },
    };
    _ = setitimer(ITIMER_PROF_C, &itv, null);
}

/// The raw per-id sample counts (index = func id, folded into the table).
/// The caller maps ids to names — the runtime layer cannot see the IR.
pub fn fnProfCounts() ?*const [FN_SLOTS]std.atomic.Value(u32) {
    if (!fn_prof_active) return null;
    return &fn_hist;
}

/// The raw per-tag sample counts (index = instruction enum tag;
/// `OP_OUTSIDE` = time outside the eval loop). The caller maps indexes to
/// opcode names — the runtime layer cannot see the IR enum.
pub fn opProfCounts() ?*const [OP_SLOTS]std.atomic.Value(u64) {
    if (!op_prof_active) return null;
    return &op_hist;
}

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

    const maps = MapRanges.read(arena);
    var it = addr_counts.iterator();
    while (it.next()) |entry| {
        const addr = entry.key_ptr.*;
        const c = entry.value_ptr.*;
        var syms: std.ArrayList(std.debug.Symbol) = .empty;
        defer syms.deinit(gpa);
        di.getSymbols(io, gpa, arena, addr -| 1, false, &syms) catch {
            accumulate(&by_name, arena, maps.label(arena, addr), c);
            continue;
        };
        const nm: []const u8 = if (syms.items.len > 0 and syms.items[0].name != null)
            syms.items[0].name.?
        else
            maps.label(arena, addr);
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

    if (builtin.link_libc and std.c.getenv("KLIO_PROF_RAW") != null) {
        const RawPc = struct {
            addr: usize,
            count: u32,
            fn lt(_: void, a: @This(), b: @This()) bool {
                return a.count > b.count;
            }
        };
        var raw_list = std.ArrayList(RawPc).empty;
        defer raw_list.deinit(gpa);
        var rit = addr_counts.iterator();
        while (rit.next()) |e| raw_list.append(gpa, .{ .addr = e.key_ptr.*, .count = e.value_ptr.* }) catch {};
        std.mem.sort(RawPc, raw_list.items, {}, RawPc.lt);
        std.debug.print("[prof-raw] top unique PCs:\n", .{});
        for (raw_list.items, 0..) |rc, i| {
            if (i >= 10) break;
            std.debug.print("  0x{x}  {d}\n", .{ rc.addr, rc.count });
        }
    }

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

/// The process's /proc/self/maps regions, held so an address the debug-info
/// symbolizer cannot resolve is at least attributed to its mapped module
/// (`<unknown:libc.so.6>`) instead of one opaque bucket.
const MapRanges = struct {
    starts: []usize = &.{},
    ends: []usize = &.{},
    names: [][]const u8 = &.{},

    fn read(arena: std.mem.Allocator) MapRanges {
        var out: MapRanges = .{};
        if (@import("builtin").os.tag != .linux) return out;
        // Raw procfs read: Zig 0.16's std fs API moved behind `Io` (same
        // no-`Io` pattern as objcell's `procEnvironHas`).
        const fd_raw = std.os.linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY }, 0);
        if (@as(isize, @bitCast(fd_raw)) < 0) return out;
        const fd: i32 = @intCast(fd_raw);
        defer _ = std.os.linux.close(fd);
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(arena);
        var chunk: [16384]u8 = undefined;
        while (true) {
            const n_raw = std.os.linux.read(fd, &chunk, chunk.len);
            if (@as(isize, @bitCast(n_raw)) <= 0) break;
            const n: usize = n_raw;
            text_buf.appendSlice(arena, chunk[0..n]) catch return out;
            if (text_buf.items.len > 4 * 1024 * 1024) break;
        }
        const text = arena.dupe(u8, text_buf.items) catch return out;
        var starts: std.ArrayList(usize) = .empty;
        var ends: std.ArrayList(usize) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const s = std.fmt.parseInt(usize, line[0..dash], 16) catch continue;
            const e = std.fmt.parseInt(usize, line[dash + 1 .. sp], 16) catch continue;
            const base = if (std.mem.lastIndexOfScalar(u8, line, '/')) |i|
                line[i + 1 ..]
            else if (std.mem.lastIndexOfScalar(u8, line, ' ')) |i|
                line[i + 1 ..]
            else
                "";
            starts.append(arena, s) catch return out;
            ends.append(arena, e) catch return out;
            names.append(arena, base) catch return out;
        }
        out.starts = starts.items;
        out.ends = ends.items;
        out.names = names.items;
        return out;
    }

    fn label(self: *const MapRanges, arena: std.mem.Allocator, addr: usize) []const u8 {
        for (self.starts, self.ends, self.names) |s, e, nm| {
            if (addr >= s and addr < e) {
                if (nm.len == 0) return "<unknown:anon>";
                return std.fmt.allocPrint(arena, "<unknown:{s}>", .{nm}) catch "<unknown>";
            }
        }
        return "<unknown>";
    }
};

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
