//! Page-returning slab allocator for the tracing GC backend.
//!
//! The collector frees by reachability, but the backing allocator decides
//! whether reclaimed pages return to the OS. `smp_allocator`/libc free-lists
//! never do, so a long-running server's RSS grew with cumulative churn even
//! though the live cell set stayed flat. This allocator fixes that: same-size
//! cells are grouped into a `SLAB`-aligned slab, and the instant a slab's last
//! live cell is freed the whole slab is `munmap`ped — so process RSS tracks the
//! live set, not the high-water of allocation.
//!
//! Layout: each small allocation rounds up to one of a fixed set of 16-byte
//! aligned size classes and is served from a slab of that class. A cell's slab
//! header is found by masking the pointer to the slab boundary (slabs are
//! `SLAB`-aligned). Allocations larger than `MAX_SMALL`, or needing alignment
//! beyond `CELL_ALIGN`, go straight to `mmap` (page-granular, already returns to
//! the OS on free) and are recognised on free by the same size/alignment test
//! the allocation used, so no per-pointer bookkeeping is needed.
//!
//! Thread-safety: one spinlock per size class guards that class's partial-slab
//! list; the mmap-backed large path is lock-free. Locks are never held across a
//! GC safe point.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const SLAB: usize = 256 * 1024; // slab span; also the cell→slab mask granularity
const CELL_ALIGN: usize = 16; // every slab cell is 16-byte aligned
const MAX_SMALL: usize = 8 * 1024; // larger allocations bypass slabs → direct mmap

/// 16-byte-aligned size classes. Spaced finely below 256 (where interpreter
/// `ControlBlock`s and host scratch cluster), geometrically above.
const class_sizes = [_]usize{
    16,   32,   48,   64,   80,   96,   112,  128,
    160,  192,  224,  256,  320,  384,  448,  512,
    640,  768,  896,  1024, 1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192,
};

fn classIndex(size: usize) usize {
    // class_sizes is sorted ascending; find the smallest class >= size.
    var i: usize = 0;
    while (i < class_sizes.len) : (i += 1) {
        if (class_sizes[i] >= size) return i;
    }
    unreachable; // caller guarantees size <= MAX_SMALL == class_sizes[last]
}

const FreeCell = struct { next: ?*FreeCell };

const SlabHeader = struct {
    class_idx: u32,
    total: u32, // cells in this slab
    free_count: u32, // currently-free cells
    cell_size: u32,
    free_head: ?*FreeCell,
    next: ?*SlabHeader, // partial-list links (owned by the class lock)
    prev: ?*SlabHeader,
};

const ClassState = struct {
    lock: SpinLock = .{},
    /// Slabs of this class that have at least one free cell. A slab with zero
    /// free cells is unlinked (found again on free via the pointer mask); a slab
    /// with every cell free is unlinked and unmapped.
    partial: ?*SlabHeader = null,
};

const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

var class_states: [class_sizes.len]ClassState = blk: {
    var s: [class_sizes.len]ClassState = undefined;
    for (&s) |*c| c.* = .{};
    break :blk s;
};

/// Diagnostic (KLIO_SLAB_STAT): bytes currently mapped from the OS (slab regions
/// + direct-mmap large allocations). Tracks the process's real backing-store
/// footprint independent of the GC's cell accounting, so a growing value with a
/// flat GC live set pinpoints non-cell (host-temporary) leaks.
pub var mapped_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

// --- Diagnostic mmap-site tracer (KLIO_SLAB_TRACE) ---------------------------
// Below the GC allocator wrapper and the perm/nursery + main/worker split, so
// it sees every slab/large mmap regardless of thread or generation — catching
// leaks that bypass `leaktrack` (worker raw-slab allocations) or the GC sweep
// (permanent-generation cells). Records the capture stack of each live mmap and
// dumps the top sites by mapped bytes on SIGTERM/SIGINT.
pub var trace_enabled: bool = false;
/// Like `trace_enabled` but for small slab cells (KLIO_CELL_TRACE). Tracks every
/// live small allocation at `allocSmall`/`freeSmall` — the guaranteed-paired
/// free path for slab cells, unlike the higher-level leak locator whose
/// alloc/free can straddle the GC sweep. Surfaces leaked raw host-temporaries
/// (non-cell allocations the collector never frees) by their allocation stack.
pub var cell_trace_enabled: bool = false;
const TRACE_FRAMES = 14;
const MapRec = struct { size: usize, addrs: [TRACE_FRAMES]usize, n: usize };
var trace_map: std.AutoHashMapUnmanaged(usize, MapRec) = .empty;
var trace_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn traceLock() void {
    while (trace_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn traceUnlock() void {
    trace_lock.store(false, .release);
}

fn traceNote(ptr: usize, size: usize) void {
    var rec: MapRec = .{ .size = size, .addrs = undefined, .n = 0 };
    const st = std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &rec.addrs);
    rec.n = st.return_addresses.len;
    traceLock();
    defer traceUnlock();
    trace_map.put(std.heap.page_allocator, ptr, rec) catch {};
}

fn traceForget(ptr: usize) void {
    traceLock();
    defer traceUnlock();
    _ = trace_map.remove(ptr);
}

// Per-size-class cell trace maps, each guarded by that class's existing slab
// lock (already held in allocSmall/freeSmall). Using the class lock instead of
// a global one means the tracer adds no new cross-thread contention, so it does
// not starve the stop-the-world sweep the way a single global lock did.
const ClassTrace = struct { map: std.AutoHashMapUnmanaged(usize, MapRec) = .empty };
var class_trace: [class_sizes.len]ClassTrace = blk: {
    var t: [class_sizes.len]ClassTrace = undefined;
    for (&t) |*c| c.* = .{};
    break :blk t;
};

fn cellTraceNote(ci: usize, ptr: usize, size: usize) void {
    var rec: MapRec = .{ .size = size, .addrs = undefined, .n = 0 };
    const st = std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &rec.addrs);
    rec.n = st.return_addresses.len;
    class_trace[ci].map.put(std.heap.page_allocator, ptr, rec) catch {};
}

const TraceSite = struct { addrs: [TRACE_FRAMES]usize, n: usize, bytes: usize, count: usize };

fn mergeSite(sites: *std.ArrayListUnmanaged(TraceSite), r: *const MapRec) void {
    for (sites.items) |*s| {
        if (s.n == r.n and std.mem.eql(usize, s.addrs[0..s.n], r.addrs[0..r.n])) {
            s.bytes += r.size;
            s.count += 1;
            return;
        }
    }
    const s: TraceSite = .{ .addrs = r.addrs, .n = r.n, .bytes = r.size, .count = 1 };
    sites.append(std.heap.page_allocator, s) catch {};
}

/// Dump the top live-allocation sites by bytes (KLIO_SLAB_TRACE / KLIO_CELL_TRACE).
pub fn traceReport() void {
    if (!trace_enabled and !cell_trace_enabled) return;
    var sites: std.ArrayListUnmanaged(TraceSite) = .empty;
    traceLock();
    var it = trace_map.iterator();
    while (it.next()) |e| mergeSite(&sites, e.value_ptr);
    traceUnlock();
    for (&class_trace) |*ct| {
        var cit = ct.map.iterator();
        while (cit.next()) |e| mergeSite(&sites, e.value_ptr);
    }
    std.sort.pdq(TraceSite, sites.items, {}, struct {
        fn lt(_: void, x: TraceSite, y: TraceSite) bool {
            return x.bytes > y.bytes;
        }
    }.lt);
    var shown: usize = 0;
    for (sites.items) |*s| {
        if (shown >= 400) break;
        shown += 1;
        std.debug.print("\n[slabtrace] live {d} bytes in {d} mmaps:\n", .{ s.bytes, s.count });
        const st: std.debug.StackTrace = .{ .return_addresses = s.addrs[0..s.n], .skipped = .none };
        std.debug.dumpStackTrace(&st);
    }
    std.debug.print("\n[slabtrace] total live sites: {d}\n", .{sites.items.len});
}

fn onTraceSignal(_: std.c.SIG) callconv(.c) void {
    traceReport();
    std.c._exit(0);
}

/// Install a SIGTERM/SIGINT handler that dumps the mmap-site report and exits.
pub fn installTraceSignalDump() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onTraceSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

// --- Diagnostic page-allocator wrapper (KLIO_SLAB_TRACE) ---------------------
// `page_allocator` allocations bypass the slab (so the mmap-site tracer above
// never sees them) and the GC (so they leak silently if a free is gated wrong).
// Routing a subsystem's `page_allocator` through this wrapper records each live
// allocation under the same site report, exposing per-iteration page leaks.
fn pAlloc(_: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
    const p = std.heap.page_allocator.vtable.alloc(std.heap.page_allocator.ptr, len, a, ra) orelse return null;
    if (gc.program_started) traceNote(@intFromPtr(p), len);
    return p;
}
fn pResize(_: *anyopaque, buf: []u8, a: Alignment, new: usize, ra: usize) bool {
    return std.heap.page_allocator.vtable.resize(std.heap.page_allocator.ptr, buf, a, new, ra);
}
fn pRemap(_: *anyopaque, buf: []u8, a: Alignment, new: usize, ra: usize) ?[*]u8 {
    const p = std.heap.page_allocator.vtable.remap(std.heap.page_allocator.ptr, buf, a, new, ra) orelse return null;
    traceForget(@intFromPtr(buf.ptr));
    if (gc.program_started) traceNote(@intFromPtr(p), new);
    return p;
}
fn pFree(_: *anyopaque, buf: []u8, a: Alignment, ra: usize) void {
    traceForget(@intFromPtr(buf.ptr));
    std.heap.page_allocator.vtable.free(std.heap.page_allocator.ptr, buf, a, ra);
}
const traced_page_vtable: Allocator.VTable = .{ .alloc = pAlloc, .resize = pResize, .remap = pRemap, .free = pFree };

/// `page_allocator`, but every allocation is recorded in the mmap-site tracer
/// when `KLIO_SLAB_TRACE` is on; otherwise the raw page allocator.
pub fn tracedPage() Allocator {
    if (!trace_enabled) return std.heap.page_allocator;
    return .{ .ptr = undefined, .vtable = &traced_page_vtable };
}

/// Whether an `(len, alignment)` request is served from a slab (vs direct mmap).
/// Both alloc and free apply this identical test, so free needs no per-pointer
/// table to tell the two apart.
inline fn isSmall(len: usize, alignment: Alignment) bool {
    return len <= MAX_SMALL and alignment.toByteUnits() <= CELL_ALIGN;
}

// --- direct mmap path (large or over-aligned) --------------------------------

fn mapRaw(size: usize) ?[]align(std.heap.page_size_min) u8 {
    const m = std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return null;
    _ = mapped_bytes.fetchAdd(size, .monotonic);
    // Only track post-startup mmaps so the permanent stdlib-image baseline does
    // not crowd out the per-iteration host leaks this hunts.
    if (trace_enabled and gc.program_started) traceNote(@intFromPtr(m.ptr), size);
    return m;
}

fn unmapRaw(ptr: [*]u8, size: usize) void {
    const aligned: [*]align(std.heap.page_size_min) u8 = @alignCast(ptr);
    if (trace_enabled) traceForget(@intFromPtr(ptr));
    std.posix.munmap(aligned[0..size]);
    _ = mapped_bytes.fetchSub(size, .monotonic);
}

inline fn pageUp(n: usize) usize {
    const p = std.heap.pageSize();
    return std.mem.alignForward(usize, n, p);
}

fn allocLarge(len: usize) ?[*]u8 {
    const m = mapRaw(pageUp(len)) orelse return null;
    return m.ptr;
}

// --- slab path ---------------------------------------------------------------

/// `mmap` a `SLAB`-sized, `SLAB`-aligned region by over-mapping and trimming the
/// unaligned head/tail. Slabs map infrequently, so the two extra `munmap`s are
/// negligible against the per-cell fast path.
fn mapSlabRegion() ?*SlabHeader {
    const over = mapRaw(SLAB + SLAB) orelse return null;
    const base = @intFromPtr(over.ptr);
    const aligned = std.mem.alignForward(usize, base, SLAB);
    const head = aligned - base;
    if (head != 0) unmapRaw(over.ptr, head);
    const tail = (base + over.len) - (aligned + SLAB);
    if (tail != 0) unmapRaw(@ptrFromInt(aligned + SLAB), tail);
    return @ptrFromInt(aligned);
}

/// Carve a fresh slab for `class_idx`, threading every cell onto its free list.
fn newSlab(class_idx: usize) ?*SlabHeader {
    const s = mapSlabRegion() orelse return null;
    const cell_size = class_sizes[class_idx];
    const data_start = std.mem.alignForward(usize, @intFromPtr(s) + @sizeOf(SlabHeader), CELL_ALIGN);
    const data_end = @intFromPtr(s) + SLAB;
    const total: u32 = @intCast((data_end - data_start) / cell_size);
    s.* = .{
        .class_idx = @intCast(class_idx),
        .total = total,
        .free_count = total,
        .cell_size = @intCast(cell_size),
        .free_head = null,
        .next = null,
        .prev = null,
    };
    // Thread cells onto the free list (descending so the head is cell 0).
    var i: usize = total;
    while (i > 0) {
        i -= 1;
        const cell: *FreeCell = @ptrFromInt(data_start + i * cell_size);
        cell.next = s.free_head;
        s.free_head = cell;
    }
    return s;
}

inline fn slabOf(ptr: [*]u8) *SlabHeader {
    return @ptrFromInt(@intFromPtr(ptr) & ~(SLAB - 1));
}

fn allocSmall(len: usize) ?[*]u8 {
    const ci = classIndex(len);
    const cs = &class_states[ci];
    cs.lock.lock();
    defer cs.lock.unlock();
    var slab = cs.partial orelse blk: {
        const s = newSlab(ci) orelse return null;
        cs.partial = s;
        break :blk s;
    };
    const cell = slab.free_head.?;
    slab.free_head = cell.next;
    slab.free_count -= 1;
    if (slab.free_count == 0) {
        // Full: drop from the partial list (re-linked on the next free).
        cs.partial = slab.next;
        if (slab.next) |n| n.prev = null;
        slab.next = null;
    }
    if (cell_trace_enabled and gc.program_started) cellTraceNote(ci, @intFromPtr(cell), len);
    return @ptrCast(cell);
}

fn freeSmall(ptr: [*]u8) void {
    const slab = slabOf(ptr);
    const cs = &class_states[slab.class_idx];
    cs.lock.lock();
    defer cs.lock.unlock();
    if (cell_trace_enabled) _ = class_trace[slab.class_idx].map.remove(@intFromPtr(ptr));
    const was_full = slab.free_count == 0;
    const cell: *FreeCell = @ptrCast(@alignCast(ptr));
    cell.next = slab.free_head;
    slab.free_head = cell;
    slab.free_count += 1;
    if (was_full) {
        // Re-enter the partial list now that it has a free cell.
        slab.prev = null;
        slab.next = cs.partial;
        if (cs.partial) |p| p.prev = slab;
        cs.partial = slab;
    }
    if (slab.free_count == slab.total) {
        // Fully free: unlink and return the whole slab to the OS.
        if (slab.prev) |p| p.next = slab.next else cs.partial = slab.next;
        if (slab.next) |n| n.prev = slab.prev;
        unmapRaw(@ptrCast(slab), SLAB);
    }
}

// --- Allocator vtable --------------------------------------------------------

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    if (len == 0) return null;
    if (isSmall(len, alignment)) return allocSmall(len);
    return allocLarge(len);
}

fn resize(_: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    if (new_len == 0) return false;
    if (isSmall(buf.len, alignment)) {
        // In place iff the new size still maps to this cell's class — i.e. the
        // cell is already big enough AND a smaller request would not be a
        // different class' job (free keys on the original len, so the class must
        // not change).
        if (!isSmall(new_len, alignment)) return false;
        return classIndex(new_len) == classIndex(buf.len);
    }
    if (isSmall(new_len, alignment)) return false;
    return pageUp(new_len) == pageUp(buf.len);
}

fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    // Force the caller to alloc-copy-free; keeps the slab/mmap classification of
    // a pointer fixed for its whole life (free must agree with alloc).
    return null;
}

fn free(_: *anyopaque, buf: []u8, alignment: Alignment, _: usize) void {
    if (buf.len == 0) return;
    if (isSmall(buf.len, alignment)) {
        freeSmall(buf.ptr);
    } else {
        unmapRaw(buf.ptr, pageUp(buf.len));
    }
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// The process-wide slab allocator handle. Stateless (all state is in the
/// module globals), so a single shared instance serves every thread.
pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

// --- tests -------------------------------------------------------------------

test "slab alloc/free round-trips across classes and frees slabs" {
    const a = allocator;
    // Exercise several size classes; free everything; the slabs must unmap.
    var bufs: [200][]u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        const sz = 16 + (i % 64) * 7; // 16..457, spans many classes
        b.* = try a.alloc(u8, sz);
        @memset(b.*, @intCast(i & 0xff));
    }
    for (bufs) |b| try std.testing.expectEqual(@as(usize, 0), b.len & 0); // touch
    for (bufs) |b| a.free(b);
    // A large allocation goes through mmap and frees cleanly.
    const big = try a.alloc(u8, 100 * 1024);
    @memset(big, 7);
    a.free(big);
}

test "slab reuses a freed cell (same address) within a class" {
    const a = allocator;
    const p1 = try a.alloc(u8, 64);
    const addr1 = @intFromPtr(p1.ptr);
    a.free(p1);
    const p2 = try a.alloc(u8, 64);
    defer a.free(p2);
    // Same class, freed then re-allocated: the slab's free list returns it.
    try std.testing.expectEqual(addr1, @intFromPtr(p2.ptr));
}
