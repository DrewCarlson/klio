//! Opt-in allocation tracker: wrap any backing allocator to count bytes,
//! allocations, frees, and a power-of-two size histogram, with named phase
//! snapshots so a caller can attribute a region of work (e.g. the stdlib
//! image decode) to a byte delta.
//!
//! Gated by `KLIO_ALLOC_TRACK`: when unset, `wrap` returns the child
//! allocator untouched (zero overhead, zero behavior change). When set,
//! `wrap` installs a global tracking layer and `reportStderr` / `snapshot`
//! expose the running totals. The whole-process report prints at exit when
//! `main` calls `reportStderr`.

const std = @import("std");
const builtin = @import("builtin");
const trace = @import("trace.zig");
const SpinMutex = @import("objcell.zig").SpinMutex;

const BUCKETS = 40;

const State = struct {
    child: std.mem.Allocator = undefined,
    bytes_alloc: u64 = 0,
    bytes_free: u64 = 0,
    count_alloc: u64 = 0,
    count_free: u64 = 0,
    count_resize: u64 = 0,
    hist: [BUCKETS]u64 = @splat(0),
    mutex: SpinMutex = .{},
};

var state: State = .{};
var active: bool = false;

pub const Snap = struct {
    bytes_alloc: u64,
    bytes_free: u64,
    count_alloc: u64,
    count_free: u64,

    pub fn liveBytes(self: Snap) u64 {
        return self.bytes_alloc - self.bytes_free;
    }
};

fn enabledByEnv() bool {
    const v = if (builtin.link_libc) std.c.getenv("KLIO_ALLOC_TRACK") else null;
    if (v == null) return false;
    const s = std.mem.span(v.?);
    return s.len != 0 and !std.mem.eql(u8, s, "0");
}

/// Returns a tracking allocator wrapping `child` when `KLIO_ALLOC_TRACK` is
/// set, otherwise `child` itself.
pub fn wrap(child: std.mem.Allocator) std.mem.Allocator {
    if (!enabledByEnv()) return child;
    state = .{ .child = child };
    active = true;
    return .{ .ptr = undefined, .vtable = &vtable };
}

pub fn isActive() bool {
    return active;
}

pub fn snapshot() Snap {
    state.mutex.lock();
    defer state.mutex.unlock();
    return .{
        .bytes_alloc = state.bytes_alloc,
        .bytes_free = state.bytes_free,
        .count_alloc = state.count_alloc,
        .count_free = state.count_free,
    };
}

fn bucketOf(len: usize) usize {
    if (len == 0) return 0;
    const b = 63 - @clz(len);
    return @min(@as(usize, b), BUCKETS - 1);
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
};

fn allocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const p = state.child.rawAlloc(len, alignment, ret_addr) orelse return null;
    state.mutex.lock();
    state.bytes_alloc += len;
    state.count_alloc += 1;
    state.hist[bucketOf(len)] += 1;
    state.mutex.unlock();
    return p;
}

fn resizeFn(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const ok = state.child.rawResize(memory, alignment, new_len, ret_addr);
    if (ok) {
        state.mutex.lock();
        state.count_resize += 1;
        if (new_len > memory.len) state.bytes_alloc += new_len - memory.len else state.bytes_free += memory.len - new_len;
        state.mutex.unlock();
    }
    return ok;
}

fn remapFn(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const p = state.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    state.mutex.lock();
    state.count_resize += 1;
    if (new_len > memory.len) state.bytes_alloc += new_len - memory.len else state.bytes_free += memory.len - new_len;
    state.mutex.unlock();
    return p;
}

fn freeFn(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    state.child.rawFree(memory, alignment, ret_addr);
    state.mutex.lock();
    state.bytes_free += memory.len;
    state.count_free += 1;
    state.mutex.unlock();
}

/// Print a labeled snapshot delta since `since` to stderr.
pub fn reportPhase(label: []const u8, since: Snap) void {
    if (!active) return;
    const now = snapshot();
    const da = now.bytes_alloc - since.bytes_alloc;
    const dc = now.count_alloc - since.count_alloc;
    std.debug.print(
        "[alloc-track] {s}: +{d:.1} MB in {d} allocs (live now {d:.1} MB)\n",
        .{ label, mb(da), dc, mb(now.liveBytes()) },
    );
}

/// Print the full process report (totals + histogram) to stderr.
pub fn reportStderr() void {
    if (!active) return;
    state.mutex.lock();
    defer state.mutex.unlock();
    const live = state.bytes_alloc - state.bytes_free;
    std.debug.print(
        "[alloc-track] TOTAL alloc {d:.1} MB / {d} allocs, freed {d:.1} MB / {d} frees, live {d:.1} MB\n",
        .{ mb(state.bytes_alloc), state.count_alloc, mb(state.bytes_free), state.count_free, mb(live) },
    );
    std.debug.print("[alloc-track] size histogram (alloc count by 2^k bytes):\n", .{});
    for (state.hist, 0..) |c, k| {
        if (c == 0) continue;
        const lo: u64 = if (k == 0) 0 else @as(u64, 1) << @intCast(k);
        std.debug.print("  2^{d:>2} (~{d:>9} B): {d}\n", .{ k, lo, c });
    }
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

// -------------------------------------------------------------------------
// Page-allocator probe: a passthrough over `std.heap.page_allocator` that
// (when KLIO_PAGE_TRACE is set) dumps a stack trace for allocations in a
// target size window, to attribute large direct page mmaps to their source.
// -------------------------------------------------------------------------

var page_trace_on: bool = false;
var page_trace_inited: bool = false;
var page_dumped: u32 = 0;
var page_mutex: SpinMutex = .{};
var page_hist: [BUCKETS]u64 = @splat(0);
var page_bytes: u64 = 0;

fn pageTraceEnabled() bool {
    if (page_trace_inited) return page_trace_on;
    page_trace_inited = true;
    const v = if (builtin.link_libc) std.c.getenv("KLIO_PAGE_TRACE") else null;
    page_trace_on = v != null and std.mem.span(v.?).len != 0 and !std.mem.eql(u8, std.mem.span(v.?), "0");
    return page_trace_on;
}

const page_vtable: std.mem.Allocator.VTable = .{
    .alloc = pageAllocFn,
    .resize = pageResizeFn,
    .remap = pageRemapFn,
    .free = pageFreeFn,
};

/// `std.heap.page_allocator` plus optional large-allocation stack tracing.
pub fn pageAllocator() std.mem.Allocator {
    if (!pageTraceEnabled()) return std.heap.page_allocator;
    return .{ .ptr = undefined, .vtable = &page_vtable };
}

fn pageAllocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const p = std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
    page_mutex.lock();
    page_hist[bucketOf(len)] += 1;
    page_bytes += len;
    page_mutex.unlock();
    if (len >= 96 * 1024 and len <= 160 * 1024) {
        page_mutex.lock();
        const n = page_dumped;
        if (page_dumped < 4) page_dumped += 1;
        page_mutex.unlock();
        if (n < 4) {
            std.debug.print("[page-trace] direct page alloc of {d} bytes:\n", .{len});
            trace.dumpCurrent(.{ .first_address = @returnAddress() });
        }
    }
    return p;
}

/// Print the page-allocator size histogram (only meaningful with tracing on).
pub fn reportPageStderr() void {
    if (!pageTraceEnabled()) return;
    page_mutex.lock();
    defer page_mutex.unlock();
    std.debug.print("[page-trace] TOTAL through wrapped page_allocator: {d:.1} MB\n", .{mb(page_bytes)});
    for (page_hist, 0..) |c, k| {
        if (c == 0) continue;
        const lo: u64 = if (k == 0) 0 else @as(u64, 1) << @intCast(k);
        std.debug.print("  page 2^{d:>2} (~{d:>9} B): {d}\n", .{ k, lo, c });
    }
}

fn pageResizeFn(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    return std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr);
}

fn pageRemapFn(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr);
}

fn pageFreeFn(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
}
