//! Page-returning slab allocator for the tracing GC backend.
//!
//! libc and `smp_allocator` free-lists never return reclaimed pages to the OS,
//! so RSS grows with cumulative churn while the live set stays flat. Here
//! same-size cells share a `SLAB`-aligned slab, whose header a cell pointer
//! masked to the `SLAB` boundary finds, and the slab is `munmap`ped the instant
//! its last live cell frees. An allocation over `MAX_SMALL`, or needing more
//! than `CELL_ALIGN`, is a large block: a power of two up to `LARGE_MAX`,
//! parked mapped when freed for the next block of its size, and a direct
//! `mmap` above that. Free recognises each by the same test the allocation
//! used.
//!
//! One spinlock per size class guards that class's partial-slab list, and one
//! per large class its parked blocks. A lock is never held across a GC safe
//! point.

const std = @import("std");
const builtin = @import("builtin");
const trace = @import("trace.zig");
const gc = @import("gc.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const SLAB: usize = 256 * 1024; // slab span, and the cell-to-slab mask granularity
const CELL_ALIGN: usize = 16; // every slab cell is 16-byte aligned
const MAX_SMALL: usize = 8 * 1024; // above this, allocations are large blocks

/// Spaced finely below 256, where the `ControlBlock`s and host scratch cluster.
const class_sizes = [_]usize{
    16,   32,   48,   64,   80,   96,   112,  128,
    160,  192,  224,  256,  320,  384,  448,  512,
    640,  768,  896,  1024, 1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192,
};

/// Class per 16-byte size step, so a lookup is one load on every alloc and
/// free rather than a scan of the class table.
const class_by_step: [MAX_SMALL / CELL_ALIGN + 1]u8 = blk: {
    var t: [MAX_SMALL / CELL_ALIGN + 1]u8 = undefined;
    var ci: usize = 0;
    for (&t, 0..) |*slot, step| {
        while (class_sizes[ci] < step * CELL_ALIGN) ci += 1;
        slot.* = @intCast(ci);
    }
    break :blk t;
};

inline fn classIndex(size: usize) usize {
    // The caller guarantees size <= MAX_SMALL.
    return class_by_step[(size + CELL_ALIGN - 1) / CELL_ALIGN];
}

const FreeCell = struct { next: ?*FreeCell };

const SlabHeader = struct {
    class_idx: u32,
    total: u32, // cells in this slab
    free_count: u32, // cells on `free_head` plus the untouched run, dormant ones excluded
    cell_size: u32,
    free_head: ?*FreeCell,
    /// Cells from this index up have never been handed out. They carry no
    /// link storage and their pages are untouched, so a fresh slab costs a
    /// map and nothing more until its cells are used.
    bump: u32,
    next: ?*SlabHeader, // partial-list links, owned by the class lock
    prev: ?*SlabHeader,
    /// Bit p marks page p decommitted, its cells pulled off the free list so
    /// the discarded link storage is never read.
    dormant_pages: u64,
    /// Not handed out again until revived; counts toward the unmap test.
    dormant_cells: u32,
    /// Consecutive reclaim passes mostly free, so a slab empty only between
    /// two allocations stays out of reclaim.
    idle_passes: u8,
};

const MAX_PAGES = SLAB / 4096;
const MAX_CELL_WORDS = (SLAB / CELL_ALIGN + 63) / 64;
/// Keeps an actively cycled slab out of decommit and revive thrash.
const RECLAIM_IDLE_PASSES = 2;

const ClassState = struct {
    lock: SpinLock = .{},
    /// A full slab is unlinked and found again on free through the mask.
    partial: ?*SlabHeader = null,
    /// Fully free slabs kept mapped and threaded for reuse. Unmapping one the
    /// instant its last cell frees thrashes a workload holding a live cell
    /// across a call, and a sweep frees whole bursts per class, so they park
    /// here and age out after `RECLAIM_IDLE_PASSES`.
    spare: ?*SlabHeader = null,
    spare_count: u32 = 0,
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

/// `KLIO_SLAB_STAT`: bytes currently mapped from the OS. Independent of the
/// GC's cell accounting, so growth against a flat live set is a non-cell leak.
pub var mapped_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

// `KLIO_SLAB_TRACE` mmap-site tracer, below the GC allocator wrapper and the
// perm/nursery and main/worker splits, so it sees every mmap whatever the
// thread or generation.
pub var trace_enabled: bool = false;
/// `KLIO_SLAB_TRACE_ALL`: trace build-phase mmaps too; see `mapRaw`.
pub var trace_all: bool = false;
/// `KLIO_CELL_TRACE`: the same for small slab cells, whose alloc and free are
/// guaranteed-paired unlike the higher-level leak locator.
pub var cell_trace_enabled: bool = false;
const TRACE_FRAMES = 30;
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

// Per-size-class cell trace maps, guarded by the slab lock `allocSmall` and
// `freeSmall` already hold, so the tracer cannot starve the sweep.
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

fn mergeSite(sites: *std.ArrayList(TraceSite), r: *const MapRec) void {
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

pub fn traceReport() void {
    if (!trace_enabled and !cell_trace_enabled) return;
    var sites: std.ArrayList(TraceSite) = .empty;
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
        trace.dump(&st);
    }
    std.debug.print("\n[slabtrace] total live sites: {d}\n", .{sites.items.len});
}

fn onTraceSignal(_: std.c.SIG) callconv(.c) void {
    traceReport();
    std.c._exit(0);
}

pub fn installTraceSignalDump() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onTraceSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

// `page_allocator` allocations bypass the slab, so the tracer never sees them,
// and the GC, so they leak silently when a free is gated wrong.
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

pub fn tracedPage() Allocator {
    if (!trace_enabled) return std.heap.page_allocator;
    return .{ .ptr = undefined, .vtable = &traced_page_vtable };
}

/// Alloc and free apply the identical test, so free needs no per-pointer table
/// to tell a slab cell from a direct mmap.
inline fn isSmall(len: usize, alignment: Alignment) bool {
    return len <= MAX_SMALL and alignment.toByteUnits() <= CELL_ALIGN;
}


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
    _ = map_calls.fetchAdd(1, .monotonic);
    // Track only post-startup mmaps; `KLIO_SLAB_TRACE_ALL` drops the gate.
    if (trace_enabled and (gc.program_started or trace_all)) traceNote(@intFromPtr(m.ptr), size);
    if (map_sites_enabled) noteMapSite(size);
    return m;
}

// `KLIO_SLAB_MAPS`: every map call by the site that made it, whether or not
// the memory is still live, so a list that doubles through maps and copies
// shows as a site with a count, where the live tracer sees only its last size.
pub var map_sites_enabled: bool = false;
const MapSite = struct { addrs: [TRACE_FRAMES]usize, n: usize, count: usize, bytes: usize };
var map_sites: std.AutoHashMapUnmanaged(u64, MapSite) = .empty;

fn noteMapSite(size: usize) void {
    var addrs: [TRACE_FRAMES]usize = undefined;
    const st = std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &addrs);
    const n = st.return_addresses.len;
    const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(addrs[0..n]));
    traceLock();
    defer traceUnlock();
    const gop = map_sites.getOrPut(std.heap.page_allocator, key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{ .addrs = addrs, .n = n, .count = 0, .bytes = 0 };
    gop.value_ptr.count += 1;
    gop.value_ptr.bytes += size;
}

pub fn mapSitesReport() void {
    if (!map_sites_enabled) return;
    var sites: std.ArrayList(MapSite) = .empty;
    traceLock();
    var it = map_sites.iterator();
    while (it.next()) |e| sites.append(std.heap.page_allocator, e.value_ptr.*) catch {};
    traceUnlock();
    std.sort.pdq(MapSite, sites.items, {}, struct {
        fn lt(_: void, x: MapSite, y: MapSite) bool {
            return x.count > y.count;
        }
    }.lt);
    var total_bytes: usize = 0;
    for (sites.items) |*s| total_bytes += s.bytes;
    std.debug.print("[slabmaps] {d} maps, {d} bytes, from {d} sites\n", .{ map_calls.load(.monotonic), total_bytes, sites.items.len });
    var shown: usize = 0;
    for (sites.items) |*s| {
        if (shown >= 40) break;
        shown += 1;
        std.debug.print("\n[slabmaps] {d} maps, {d} bytes:\n", .{ s.count, s.bytes });
        const st: std.debug.StackTrace = .{ .return_addresses = s.addrs[0..s.n], .skipped = .none };
        trace.dump(&st);
    }
}

fn unmapRaw(ptr: [*]u8, size: usize) void {
    const aligned: [*]align(std.heap.page_size_min) u8 = @alignCast(ptr);
    if (trace_enabled) traceForget(@intFromPtr(ptr));
    std.posix.munmap(aligned[0..size]);
    _ = mapped_bytes.fetchSub(size, .monotonic);
    _ = unmap_calls.fetchAdd(1, .monotonic);
}

/// `KLIO_SLAB_STAT`: system calls made so far. A large allocation is one map
/// and its free one unmap, so a list that doubles past `MAX_SMALL` shows here.
pub var map_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
pub var unmap_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

inline fn pageUp(n: usize) usize {
    const p = std.heap.pageSize();
    return std.mem.alignForward(usize, n, p);
}

// Large blocks: a size from `MAX_SMALL` to `LARGE_MAX` rounds up to a power
// of two, and a freed block of that class parks on the class's list, mapped
// and resident, for the next block of its size. Page faults serialise across
// threads, so a build phase that maps, touches and unmaps a fresh block per
// list would otherwise spend its parallelism in the kernel. Above `LARGE_MAX`
// a block maps and unmaps directly. The reclaim pass ages parked blocks out.

const LARGE_MIN: usize = 16 * 1024;
const LARGE_MAX: usize = 4 * 1024 * 1024;
const large_class_count = std.math.log2_int(usize, LARGE_MAX / LARGE_MIN) + 1;

/// Link and age live in the block itself: it was in use, so its first page is
/// resident.
const LargeBlock = struct { next: ?*LargeBlock, idle_passes: u8 };
const LargeClass = struct { lock: SpinLock = .{}, head: ?*LargeBlock = null, count: u32 = 0 };
var large_classes: [large_class_count]LargeClass = blk: {
    var s: [large_class_count]LargeClass = undefined;
    for (&s) |*c| c.* = .{};
    break :blk s;
};

/// Null above `LARGE_MAX`: that block maps and unmaps directly.
inline fn largeClass(len: usize) ?usize {
    if (len > LARGE_MAX) return null;
    const rounded = std.math.ceilPowerOfTwo(usize, @max(len, LARGE_MIN)) catch unreachable;
    return std.math.log2_int(usize, rounded / LARGE_MIN);
}

inline fn largeClassSize(ci: usize) usize {
    return LARGE_MIN << @intCast(ci);
}

/// The mapped extent of a large block, which `free` and `resize` key on.
inline fn largeExtent(len: usize) usize {
    return if (largeClass(len)) |ci| largeClassSize(ci) else pageUp(len);
}

fn allocLarge(len: usize) ?[*]u8 {
    const ci = largeClass(len) orelse {
        const m = mapRaw(pageUp(len)) orelse return null;
        return m.ptr;
    };
    const lc = &large_classes[ci];
    {
        lc.lock.lock();
        defer lc.lock.unlock();
        if (lc.head) |b| {
            lc.head = b.next;
            lc.count -= 1;
            return @ptrCast(b);
        }
    }
    const m = mapRaw(largeClassSize(ci)) orelse return null;
    return m.ptr;
}

fn freeLarge(ptr: [*]u8, len: usize) void {
    const ci = largeClass(len) orelse {
        unmapRaw(ptr, pageUp(len));
        return;
    };
    const lc = &large_classes[ci];
    const b: *LargeBlock = @ptrCast(@alignCast(ptr));
    lc.lock.lock();
    defer lc.lock.unlock();
    b.* = .{ .next = lc.head, .idle_passes = 0 };
    lc.head = b;
    lc.count += 1;
}

/// Ages parked large blocks and unmaps those idle for `idle_passes`.
fn reclaimLarge(idle_passes: u32) void {
    for (&large_classes, 0..) |*lc, ci| {
        lc.lock.lock();
        defer lc.lock.unlock();
        var keep: ?*LargeBlock = null;
        var keep_count: u32 = 0;
        var b = lc.head;
        while (b) |blk| {
            const next = blk.next;
            blk.idle_passes +|= 1;
            if (blk.idle_passes >= idle_passes) {
                unmapRaw(@ptrCast(blk), largeClassSize(ci));
            } else {
                blk.next = keep;
                keep = blk;
                keep_count += 1;
            }
            b = next;
        }
        lc.head = keep;
        lc.count = keep_count;
    }
}

/// Bytes parked on the large-block lists.
fn largeParked() usize {
    var total: usize = 0;
    for (&large_classes, 0..) |*lc, ci| {
        lc.lock.lock();
        defer lc.lock.unlock();
        total += @as(usize, lc.count) * largeClassSize(ci);
    }
    return total;
}

/// Over-maps `len` bytes and trims the unaligned head and tail.
fn mapAligned(len: usize) ?usize {
    const over = mapRaw(len + SLAB) orelse return null;
    const base = @intFromPtr(over.ptr);
    const aligned = std.mem.alignForward(usize, base, SLAB);
    const head = aligned - base;
    if (head != 0) unmapRaw(over.ptr, head);
    const tail = (base + over.len) - (aligned + len);
    if (tail != 0) unmapRaw(@ptrFromInt(aligned + len), tail);
    return aligned;
}

// Fresh slabs are carved from a reserve mapped `RESERVE_SLABS` at a time and
// aligned once, so a slab costs an atomic step rather than a map and two
// trims. The reserve's unused tail is mapped but never touched, so it holds
// address space and no memory; a slab unmapped later splits the region.
const RESERVE_SLABS: usize = 16;
var reserve_next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var reserve_end: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var reserve_lock: SpinLock = .{};

fn mapSlabRegion() ?*SlabHeader {
    while (true) {
        const next = reserve_next.load(.acquire);
        if (next < reserve_end.load(.acquire)) {
            if (reserve_next.cmpxchgWeak(next, next + SLAB, .acq_rel, .acquire) == null) return @ptrFromInt(next);
            continue;
        }
        reserve_lock.lock();
        defer reserve_lock.unlock();
        if (reserve_next.load(.acquire) < reserve_end.load(.acquire)) continue;
        const region = mapAligned(RESERVE_SLABS * SLAB) orelse return null;
        reserve_end.store(region + RESERVE_SLABS * SLAB, .release);
        reserve_next.store(region + SLAB, .release);
        return @ptrFromInt(region);
    }
}

/// Bytes of the reserve mapped but not yet carved into a slab.
fn reserveUnused() usize {
    return reserve_end.load(.acquire) -| reserve_next.load(.acquire);
}

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
        .bump = 0,
        .next = null,
        .prev = null,
        .dormant_pages = 0,
        .dormant_cells = 0,
        .idle_passes = 0,
    };
    return s;
}

inline fn slabOf(ptr: [*]u8) *SlabHeader {
    return @ptrFromInt(@intFromPtr(ptr) & ~(SLAB - 1));
}

inline fn dataStart(s: *const SlabHeader) usize {
    return std.mem.alignForward(usize, @intFromPtr(s) + @sizeOf(SlabHeader), CELL_ALIGN);
}

inline fn cellAt(s: *const SlabHeader, i: usize) [*]u8 {
    return @ptrFromInt(dataStart(s) + i * s.cell_size);
}

/// Unlinks a slab from the partial list. Caller holds the lock.
fn unlinkPartial(cs: *ClassState, slab: *SlabHeader) void {
    if (slab.prev) |p| p.next = slab.next else cs.partial = slab.next;
    if (slab.next) |n| n.prev = slab.prev;
    slab.prev = null;
    slab.next = null;
}

/// Cells came back to a slab: relink one that was off the list as full, and
/// park one that is now wholly free. Caller holds the lock.
fn noteCellsReturned(cs: *ClassState, slab: *SlabHeader, was_full: bool) void {
    if (was_full) {
        slab.prev = null;
        slab.next = cs.partial;
        if (cs.partial) |p| p.prev = slab;
        cs.partial = slab;
    }
    if (slab.free_count + slab.dormant_cells == slab.total) {
        unlinkPartial(cs, slab);
        // Park it on the class's spare stack so the next burst reuses mapped
        // slabs. Parking never raises the peak, since these spans were garbage
        // moments ago, and the reclaim pass ages idle spares back to the OS. A
        // dormant-paged slab unmaps outright.
        if (slab.dormant_pages == 0) {
            slab.idle_passes = 0;
            slab.next = cs.spare;
            cs.spare = slab;
            cs.spare_count += 1;
        } else {
            unmapRaw(@ptrCast(slab), SLAB);
        }
    }
}

/// The parked spare before a freshly mapped slab. Caller holds the lock.
fn takeFrontier(cs: *ClassState, ci: usize) ?*SlabHeader {
    const s = if (cs.spare) |sp| blk: {
        cs.spare = sp.next;
        cs.spare_count -= 1;
        sp.idle_passes = 0;
        break :blk sp;
    } else newSlab(ci) orelse return null;
    s.prev = null;
    s.next = cs.partial;
    if (cs.partial) |p| p.prev = s;
    cs.partial = s;
    return s;
}

/// The head slab with a cell to give, reviving dormant pages before mapping
/// fresh memory so the address space stays bounded. Caller holds the lock.
fn frontierSlab(cs: *ClassState, ci: usize) ?*SlabHeader {
    var slab = cs.partial orelse takeFrontier(cs, ci) orelse return null;
    while (slab.free_head == null and slab.bump == slab.total) {
        if (slab.dormant_pages != 0) {
            _ = reviveOnePage(slab, class_sizes[ci], std.heap.pageSize());
            continue;
        }
        cs.partial = slab.next;
        if (slab.next) |n| n.prev = null;
        slab.next = null;
        slab = cs.partial orelse takeFrontier(cs, ci) orelse return null;
    }
    return slab;
}

/// A slab that gave its last cell leaves the partial list; a free finds it
/// again through the mask. Caller holds the lock.
inline fn noteCellsTaken(cs: *ClassState, slab: *SlabHeader) void {
    if (slab.free_count == 0 and slab.dormant_pages == 0) {
        cs.partial = slab.next;
        if (slab.next) |n| n.prev = null;
        slab.next = null;
    }
}

fn allocLockedOne(cs: *ClassState, ci: usize) ?[*]u8 {
    const slab = frontierSlab(cs, ci) orelse return null;
    const cell: [*]u8 = if (slab.free_head) |c| blk: {
        slab.free_head = c.next;
        break :blk @ptrCast(c);
    } else blk: {
        const c = cellAt(slab, slab.bump);
        slab.bump += 1;
        break :blk c;
    };
    slab.free_count -= 1;
    noteCellsTaken(cs, slab);
    return cell;
}

/// The untouched run of a magazine refill: up to `RUN_BYTES` of never-used
/// cells taken from the head slab in one step, threaded to nothing. False
/// when the head has freed cells, which are resident and come first, or no
/// untouched cells left; the caller then pops its free list.
fn takeRunLocked(cs: *ClassState, ci: usize, run: *Run) bool {
    const slab = frontierSlab(cs, ci) orelse return false;
    if (slab.free_head != null) return false;
    const left = slab.total - slab.bump;
    if (left == 0) return false;
    const n: u32 = @min(left, run_cells[ci]);
    run.next = @intFromPtr(cellAt(slab, slab.bump));
    run.end = run.next + @as(usize, n) * slab.cell_size;
    slab.bump += n;
    slab.free_count -= n;
    noteCellsTaken(cs, slab);
    return true;
}

/// Hands an unused run back: retracted when it is still the slab's frontier,
/// threaded onto the free list otherwise. Caller holds the lock.
fn returnRunLocked(cs: *ClassState, run: *Run) void {
    if (run.next == run.end) return;
    const slab = slabOf(@ptrFromInt(run.next));
    const was_full = slab.free_count == 0 and slab.dormant_pages == 0;
    const n: u32 = @intCast((run.end - run.next) / slab.cell_size);
    if (@intFromPtr(cellAt(slab, slab.bump)) == run.end) {
        slab.bump -= n;
        slab.free_count += n;
    } else {
        var p = run.next;
        while (p < run.end) : (p += slab.cell_size) {
            const cell: *FreeCell = @ptrFromInt(p);
            cell.next = slab.free_head;
            slab.free_head = cell;
        }
        slab.free_count += n;
    }
    run.* = .{};
    noteCellsReturned(cs, slab, was_full);
}

fn freeLockedOne(ptr: [*]u8, slab: *SlabHeader, cs: *ClassState) void {
    // A slab is off the partial list only when truly full: no free cell and no
    // dormant page. A reclaim pass can leave `free_count == 0` on a linked slab,
    // so re-linking on `free_count` alone would cycle the list.
    const was_full = slab.free_count == 0 and slab.dormant_pages == 0;
    const cell: *FreeCell = @ptrCast(@alignCast(ptr));
    cell.next = slab.free_head;
    slab.free_head = cell;
    slab.free_count += 1;
    noteCellsReturned(cs, slab, was_full);
}

// Per-thread magazines: taking the class spinlock on every alloc and free
// serializes the workers on a handful of hot size classes, so each thread
// caches free cells per class and takes the lock once per batch. Magazine cells
// are off their slab's free list, so the reclaim pass sees them as live.
//
// A refill prefers an untouched run of the head slab: one lock step hands a
// thread `RUN_BYTES` of cells it then bumps through with no link storage and
// no page touched before its first use. Ten threads building fresh trees
// otherwise spend their time on the class locks, threading and faulting in
// cells they are about to take.

/// About 4KB of cached free cells, at least 4, at most 64.
const mag_caps: [class_sizes.len]u16 = blk: {
    var c: [class_sizes.len]u16 = undefined;
    for (class_sizes, 0..) |sz, i| c[i] = @intCast(@min(64, @max(4, 4096 / sz)));
    break :blk c;
};

/// Cells per untouched run: one lock step per this much fresh memory.
const RUN_BYTES: usize = 16 * 1024;
const run_cells: [class_sizes.len]u32 = blk: {
    var c: [class_sizes.len]u32 = undefined;
    for (class_sizes, 0..) |sz, i| c[i] = @intCast(@max(1, RUN_BYTES / sz));
    break :blk c;
};

/// A contiguous run of never-used cells a thread bumps through.
const Run = struct { next: usize = 0, end: usize = 0 };

const Magazine = struct { head: ?*FreeCell = null, count: u16 = 0, run: Run = .{} };

threadlocal var magazines: [class_sizes.len]Magazine = @splat(.{});

/// Called at worker-thread exit so a dead thread strands nothing.
pub fn flushMagazines() void {
    for (&magazines, 0..) |*mag, ci| {
        if (mag.head == null and mag.run.next == mag.run.end) continue;
        const cs = &class_states[ci];
        cs.lock.lock();
        defer cs.lock.unlock();
        while (mag.head) |cell| {
            mag.head = cell.next;
            freeLockedOne(@ptrCast(cell), slabOf(@ptrCast(cell)), cs);
        }
        mag.count = 0;
        returnRunLocked(cs, &mag.run);
    }
}

fn allocSmall(len: usize) ?[*]u8 {
    const ci = classIndex(len);
    const cs = &class_states[ci];
    // A magazine round-trip would be invisible to the per-address cell tracer.
    if (cell_trace_enabled) {
        cs.lock.lock();
        defer cs.lock.unlock();
        const cell = allocLockedOne(cs, ci) orelse return null;
        // Sample 1 address in 256, deterministically so free's remove agrees.
        if (gc.program_started and (@intFromPtr(cell) & 0xff) == 0) cellTraceNote(ci, @intFromPtr(cell), len);
        return cell;
    }
    const mag = &magazines[ci];
    if (mag.head) |cell| {
        mag.head = cell.next;
        mag.count -= 1;
        return @ptrCast(cell);
    }
    if (mag.run.next < mag.run.end) {
        const cell: [*]u8 = @ptrFromInt(mag.run.next);
        mag.run.next += class_sizes[ci];
        return cell;
    }
    cs.lock.lock();
    defer cs.lock.unlock();
    if (takeRunLocked(cs, ci, &mag.run)) {
        const cell: [*]u8 = @ptrFromInt(mag.run.next);
        mag.run.next += class_sizes[ci];
        return cell;
    }
    const first = allocLockedOne(cs, ci) orelse return null;
    var want: u16 = mag_caps[ci] / 2;
    while (want > 0) : (want -= 1) {
        const extra = allocLockedOne(cs, ci) orelse break;
        const cell: *FreeCell = @ptrCast(@alignCast(extra));
        cell.next = mag.head;
        mag.head = cell;
        mag.count += 1;
    }
    return first;
}

/// `KLIO_SLAB_POISON`: overwrite a freed cell so a reader of freed memory
/// sees garbage at once instead of the old contents.
pub var poison_free: bool = false;

fn freeSmall(ptr: [*]u8) void {
    const slab = slabOf(ptr);
    const ci = slab.class_idx;
    const cs = &class_states[ci];
    if (builtin.mode == .Debug) {
        const data_start = std.mem.alignForward(usize, @intFromPtr(slab) + @sizeOf(SlabHeader), CELL_ALIGN);
        std.debug.assert((@intFromPtr(ptr) - data_start) % slab.cell_size == 0);
    }
    if (poison_free) @memset(ptr[0..slab.cell_size], 0xAA);
    if (cell_trace_enabled) {
        cs.lock.lock();
        defer cs.lock.unlock();
        if ((@intFromPtr(ptr) & 0xff) == 0) _ = class_trace[ci].map.remove(@intFromPtr(ptr));
        freeLockedOne(ptr, slab, cs);
        return;
    }
    const mag = &magazines[ci];
    if (mag.count < mag_caps[ci]) {
        const cell: *FreeCell = @ptrCast(@alignCast(ptr));
        cell.next = mag.head;
        mag.head = cell;
        mag.count += 1;
        return;
    }
    cs.lock.lock();
    defer cs.lock.unlock();
    freeLockedOne(ptr, slab, cs);
    var drain: u16 = mag_caps[ci] / 2;
    while (drain > 0) : (drain -= 1) {
        const cell = mag.head orelse break;
        mag.head = cell.next;
        mag.count -= 1;
        freeLockedOne(@ptrCast(cell), slabOf(@ptrCast(cell)), cs);
    }
}

// Page reclamation. A slab is `munmap`ped only when its last live cell frees,
// so one long-lived straggler keeps a whole span resident. This pass, run
// stop-the-world, decommits any page no live cell overlaps and pulls the free
// cells whose link storage lived there off the free list. Those cells go
// dormant, re-committed on demand by `allocSmall`.

/// Returns the resident pages to the OS while keeping the range mapped,
/// zero-filled on the next touch. Overlaying a fresh anonymous `MAP_FIXED`
/// mapping is the portable way to actually drop RSS: on macOS `madvise` leaves
/// the pages resident until reclaimed under pressure.
inline fn decommit(addr: usize, len: usize) void {
    const p: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr);
    _ = std.posix.mmap(
        p,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1,
        0,
    ) catch {};
}

/// The decommitted page stayed mapped, zero-filled, so re-threading its cells
/// faults it back in. Reusing dormant capacity bounds the address space.
fn reviveOnePage(s: *SlabHeader, cell_size: usize, pg: usize) u32 {
    if (s.dormant_pages == 0) return 0;
    const p: usize = @ctz(s.dormant_pages);
    s.dormant_pages &= ~(@as(u64, 1) << @intCast(p));
    const slab_base = @intFromPtr(s);
    const data_start = std.mem.alignForward(usize, slab_base + @sizeOf(SlabHeader), CELL_ALIGN);
    var revived: u32 = 0;
    var i: usize = 0;
    while (i < s.total) : (i += 1) {
        const cell_off = data_start + i * cell_size;
        if ((cell_off - slab_base) / pg != p) continue;
        const cell: *FreeCell = @ptrFromInt(cell_off);
        cell.next = s.free_head;
        s.free_head = cell;
        revived += 1;
    }
    s.free_count += revived;
    s.dormant_cells -= revived;
    return revived;
}

/// Stop-the-world only: the class lock is held and nothing else mutates it.
fn reclaimSlab(s: *SlabHeader, cell_size: usize, pg: usize) void {
    const live = s.total - s.free_count - s.dormant_cells;
    if (live * 2 > s.total) {
        s.idle_passes = 0;
        return;
    }
    if (s.idle_passes < RECLAIM_IDLE_PASSES) {
        s.idle_passes += 1;
        return;
    }
    const slab_base = @intFromPtr(s);
    const data_start = std.mem.alignForward(usize, slab_base + @sizeOf(SlabHeader), CELL_ALIGN);
    const n_pages = SLAB / pg;

    var free_bits = [_]u64{0} ** MAX_CELL_WORDS;
    {
        var fc = s.free_head;
        while (fc) |cell| {
            const idx = (@intFromPtr(cell) - data_start) / cell_size;
            free_bits[idx >> 6] |= @as(u64, 1) << @intCast(idx & 63);
            fc = cell.next;
        }
    }

    // A page is reclaimable iff no live cell overlaps it; page 0 is header.
    // The untouched run past `bump` is not resident and has no links to drop,
    // and a dormant page there would revive cells the run still owns.
    var reclaimable = [_]bool{false} ** MAX_PAGES;
    {
        const untouched_from = if (s.bump < s.total) (data_start + s.bump * cell_size - slab_base) / pg else n_pages;
        var p: usize = 1;
        while (p < n_pages) : (p += 1) {
            reclaimable[p] = p < untouched_from and (s.dormant_pages & (@as(u64, 1) << @intCast(p))) == 0;
        }
    }
    {
        var i: usize = 0;
        while (i < s.bump) : (i += 1) {
            const is_free = (free_bits[i >> 6] & (@as(u64, 1) << @intCast(i & 63))) != 0;
            const cell_off = data_start + i * cell_size;
            const start_pg = (cell_off - slab_base) / pg;
            const is_dormant = (s.dormant_pages & (@as(u64, 1) << @intCast(start_pg))) != 0;
            if (is_free or is_dormant) continue; // not a live cell
            const end_pg = (cell_off + cell_size - 1 - slab_base) / pg;
            var p = start_pg;
            while (p <= end_pg) : (p += 1) reclaimable[p] = false;
        }
    }

    var any = false;
    for (reclaimable[0..n_pages]) |r| {
        if (r) {
            any = true;
            break;
        }
    }
    if (!any) return;

    // Drop every cell whose link storage sits in a page about to be discarded:
    // reading its `next` would fault in a zeroed page.
    var new_head: ?*FreeCell = null;
    var kept: u32 = 0;
    var dropped: u32 = 0;
    {
        var fc = s.free_head;
        while (fc) |cell| {
            const nxt = cell.next;
            const start_pg = (@intFromPtr(cell) - slab_base) / pg;
            if (reclaimable[start_pg]) {
                dropped += 1;
            } else {
                cell.next = new_head;
                new_head = cell;
                kept += 1;
            }
            fc = nxt;
        }
    }
    s.free_head = new_head;
    s.free_count = kept + (s.total - s.bump);
    s.dormant_cells += dropped;

    var p: usize = 1;
    while (p < n_pages) {
        if (!reclaimable[p]) {
            p += 1;
            continue;
        }
        const run_start = p;
        while (p < n_pages and reclaimable[p]) : (p += 1) {
            s.dormant_pages |= @as(u64, 1) << @intCast(p);
        }
        decommit(slab_base + run_start * pg, (p - run_start) * pg);
    }
}

/// `KLIO_SLAB_STAT`: per size class, the spans on the partial list with their
/// free and dormant cells, and the parked spares. A full span is off every
/// list, so what is not counted here is live.
pub fn occupancyReport() void {
    var free_total: usize = 0;
    var dormant_total: usize = 0;
    var spare_total: usize = 0;
    std.debug.print("[slab] class  cell  partial   free-cells  dormant  spare\n", .{});
    for (&class_states, 0..) |*cs, ci| {
        cs.lock.lock();
        defer cs.lock.unlock();
        var partial: usize = 0;
        var free_cells: usize = 0;
        var dormant: usize = 0;
        var s = cs.partial;
        while (s) |p| : (s = p.next) {
            partial += 1;
            free_cells += p.free_count;
            dormant += p.dormant_cells;
        }
        if (partial == 0 and cs.spare_count == 0) continue;
        const sz = class_sizes[ci];
        std.debug.print("[slab] {d:>5} {d:>5} {d:>8} {d:>12} {d:>8} {d:>6}\n", .{ ci, sz, partial, free_cells, dormant, cs.spare_count });
        free_total += free_cells * sz;
        dormant_total += dormant * sz;
        spare_total += @as(usize, cs.spare_count) * SLAB;
    }
    const mapped = mapped_bytes.load(.monotonic);
    const reserve = reserveUnused();
    const parked_large = largeParked();
    std.debug.print("[slab] mapped {d}kb: free {d}kb, dormant {d}kb, spare {d}kb, reserve {d}kb, parked large {d}kb, live+headers {d}kb\n", .{
        mapped / 1024,
        free_total / 1024,
        dormant_total / 1024,
        spare_total / 1024,
        reserve / 1024,
        parked_large / 1024,
        (mapped -| free_total -| dormant_total -| spare_total -| reserve -| parked_large) / 1024,
    });
}

/// The GC's `release_to_os` hook, run stop-the-world after a sweep.
pub fn reclaimDormant() void {
    reclaimWith(RECLAIM_IDLE_PASSES);
}

/// One-off trim between two phases of a run (the program build and its
/// execution): the build's burst of scratch is not coming back, so every
/// parked spare goes now instead of ageing out over later collections.
pub fn reclaimAll() void {
    reclaimWith(1);
}

fn reclaimWith(idle_passes: u32) void {
    reclaimLarge(idle_passes);
    const pg = std.heap.pageSize();
    if (SLAB / pg > MAX_PAGES) return; // runtime page larger than the scan bound
    for (&class_states, 0..) |*cs, ci| {
        cs.lock.lock();
        defer cs.lock.unlock();
        // Dropping every parked spare here would make each collection of a
        // churn-heavy workload remap its whole burst, so they age out instead.
        var keep: ?*SlabHeader = null;
        var keep_count: u32 = 0;
        var sp = cs.spare;
        while (sp) |s| {
            const next = s.next;
            s.idle_passes +|= 1;
            if (s.idle_passes >= idle_passes) {
                unmapRaw(@ptrCast(s), SLAB);
            } else {
                s.next = keep;
                keep = s;
                keep_count += 1;
            }
            sp = next;
        }
        cs.spare = keep;
        cs.spare_count = keep_count;
        // Skip the partial head: it is the active allocation frontier.
        const head = cs.partial orelse continue;
        var slab = head.next;
        while (slab) |s| {
            reclaimSlab(s, class_sizes[ci], pg);
            slab = s.next;
        }
    }
}


fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    if (len == 0) return null;
    if (isSmall(len, alignment)) return allocSmall(len);
    return allocLarge(len);
}

fn resize(_: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    if (new_len == 0) return false;
    if (isSmall(buf.len, alignment)) {
        // `free` keys on the requested length, so the class must not change.
        if (!isSmall(new_len, alignment)) return false;
        return classIndex(new_len) == classIndex(buf.len);
    }
    if (isSmall(new_len, alignment)) return false;
    // `free` keys on the requested length, so the block stays what that
    // length maps to: its class, or its page count above the classes.
    const old_extent = largeExtent(buf.len);
    const new_extent = largeExtent(new_len);
    if (new_extent == old_extent) return true;
    if (new_extent > old_extent) return false;
    // A shrink gives the tail back in place, so a list that reserved for its
    // worst case and settled smaller neither copies nor remaps. A block
    // shrinking out of the classes would change what `free` does with it.
    if (largeClass(buf.len) == null and largeClass(new_len) != null) return false;
    unmapRaw(buf.ptr + new_extent, old_extent - new_extent);
    return true;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    // A pointer's slab-or-mmap classification is fixed for life, so free
    // agrees with alloc: only a shrink within a class, or one that stays
    // large, moves nothing. A list settling into its owned slice takes this.
    if (new_len == 0 or new_len > buf.len) return null;
    if (isSmall(buf.len, alignment) != isSmall(new_len, alignment)) return null;
    return if (resize(ctx, buf, alignment, new_len, ret_addr)) buf.ptr else null;
}

fn free(_: *anyopaque, buf: []u8, alignment: Alignment, _: usize) void {
    if (buf.len == 0) return;
    if (isSmall(buf.len, alignment)) {
        freeSmall(buf.ptr);
    } else {
        freeLarge(buf.ptr, buf.len);
    }
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// Stateless, so one shared instance serves every thread.
pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

test "slab alloc/free round-trips across classes and frees slabs" {
    const a = allocator;
    var bufs: [200][]u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        const sz = 16 + (i % 64) * 7; // 16..457, spanning many classes
        b.* = try a.alloc(u8, sz);
        @memset(b.*, @intCast(i & 0xff));
    }
    for (bufs) |b| try std.testing.expectEqual(@as(usize, 0), b.len & 0); // touch
    for (bufs) |b| a.free(b);
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
    try std.testing.expectEqual(addr1, @intFromPtr(p2.ptr));
}

test "slab magazine caches a freed cell and flush returns it" {
    const a = allocator;
    flushMagazines();
    const p1 = try a.alloc(u8, 64);
    const addr = @intFromPtr(p1.ptr);
    a.free(p1);
    flushMagazines();
    var bufs: [40][]u8 = undefined;
    var seen = false;
    for (&bufs) |*b| {
        b.* = try a.alloc(u8, 64);
        if (@intFromPtr(b.ptr) == addr) seen = true;
    }
    try std.testing.expect(seen);
    for (bufs) |b| a.free(b);
    flushMagazines();
}

test "slab spare stack parks freed slabs and ages them out across reclaim passes" {
    const a = allocator;
    const T = std.testing;
    flushMagazines();
    const ci = classIndex(2048);
    const cs = &class_states[ci];
    // Every fully-free slab parks, so a multi-slab burst parks more than one.
    const N = 400; // about 128 cells per 256K slab at 2 KiB, so several slabs
    var bufs: [N][]u8 = undefined;
    for (&bufs) |*b| b.* = try a.alloc(u8, 2048);
    for (bufs) |b| a.free(b);
    flushMagazines();
    var parked: u32 = 0;
    {
        cs.lock.lock();
        defer cs.lock.unlock();
        parked = cs.spare_count;
        try T.expect(parked >= 2);
        try T.expect(parked <= N);
    }
    // One pass is inside the hysteresis window, so the count must not shrink.
    reclaimDormant();
    {
        cs.lock.lock();
        defer cs.lock.unlock();
        try T.expectEqual(parked, cs.spare_count);
    }
    const p = try a.alloc(u8, 2048);
    a.free(p);
    flushMagazines();
    var pass: usize = 0;
    while (pass < RECLAIM_IDLE_PASSES + 1) : (pass += 1) reclaimDormant();
    {
        cs.lock.lock();
        defer cs.lock.unlock();
        try T.expectEqual(@as(u8, 0), cs.spare_count);
        try T.expectEqual(@as(?*SlabHeader, null), cs.spare);
    }
}

test "slab reclaim decommits sparse slabs, preserves stragglers, revives dormant" {
    const a = allocator;
    const T = std.testing;
    const N = 300; // 2 KiB cells, about 128 per slab, so several slabs
    var bufs: [N][]u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        b.* = try a.alloc(u8, 2048);
        @memset(b.*, @intCast(i & 0xff));
    }
    const kept = [_]usize{ 7, 140, 293 };
    for (bufs, 0..) |b, i| {
        const keep = i == kept[0] or i == kept[1] or i == kept[2];
        if (!keep) a.free(b);
    }
    // Clear the hysteresis so the sparse non-head slabs decommit.
    var pass: usize = 0;
    while (pass < RECLAIM_IDLE_PASSES + 2) : (pass += 1) reclaimDormant();
    // A straggler's own page is never discarded.
    for (kept) |k| for (bufs[k]) |byte| try T.expectEqual(@as(u8, @intCast(k & 0xff)), byte);
    var more: [N][]u8 = undefined;
    for (&more, 0..) |*b, i| {
        b.* = try a.alloc(u8, 2048);
        @memset(b.*, @intCast((i ^ 0x5a) & 0xff));
    }
    for (more, 0..) |b, i| for (b) |byte| try T.expectEqual(@as(u8, @intCast((i ^ 0x5a) & 0xff)), byte);
    for (kept) |k| for (bufs[k]) |byte| try T.expectEqual(@as(u8, @intCast(k & 0xff)), byte);
    for (more) |b| a.free(b);
    for (kept) |k| a.free(bufs[k]);
}

test "slab refill takes an untouched run and a flush gives it back" {
    const a = allocator;
    const T = std.testing;
    flushMagazines();
    const ci = classIndex(3584);
    const cs = &class_states[ci];
    const p1 = try a.alloc(u8, 3584);
    const p2 = try a.alloc(u8, 3584);
    // Consecutive cells of one run, taken from the slab in one step.
    try T.expectEqual(@intFromPtr(p1.ptr) + 3584, @intFromPtr(p2.ptr));
    const slab = slabOf(p1.ptr);
    {
        cs.lock.lock();
        defer cs.lock.unlock();
        try T.expectEqual(run_cells[ci], slab.bump);
        try T.expectEqual(slab.total - run_cells[ci], slab.free_count);
    }
    a.free(p2);
    a.free(p1);
    flushMagazines();
    {
        cs.lock.lock();
        defer cs.lock.unlock();
        // The unused tail of the run retracted the frontier; the two freed
        // cells sit on the free list; the slab is wholly free and parked.
        try T.expectEqual(@as(u32, 2), slab.bump);
        try T.expectEqual(slab.total, slab.free_count);
        try T.expectEqual(@as(?*SlabHeader, slab), cs.spare);
    }
    // A run that is no longer the frontier threads its cells instead.
    {
        cs.lock.lock();
        defer cs.lock.unlock();
        var r1: Run = .{};
        var r2: Run = .{};
        try T.expect(!takeRunLocked(cs, ci, &r1)); // freed cells come first
        const s = frontierSlab(cs, ci).?;
        try T.expectEqual(slab, s);
        s.free_head = null;
        s.free_count -= 2;
        try T.expect(takeRunLocked(cs, ci, &r1));
        try T.expect(takeRunLocked(cs, ci, &r2));
        try T.expectEqual(r1.end, r2.next);
        const bump_after = s.bump;
        returnRunLocked(cs, &r1);
        try T.expectEqual(bump_after, s.bump);
        try T.expectEqual(run_cells[ci], s.free_count - (s.total - s.bump));
        returnRunLocked(cs, &r2);
        try T.expectEqual(bump_after - run_cells[ci], s.bump);
    }
}

test "slab parks a freed large block for its class and the reclaim pass ages it out" {
    const a = allocator;
    const T = std.testing;
    const ci = largeClass(100 * 1024).?;
    try T.expectEqual(@as(usize, 128 * 1024), largeClassSize(ci));
    const lc = &large_classes[ci];
    reclaimAll();
    const p1 = try a.alloc(u8, 100 * 1024);
    const addr = @intFromPtr(p1.ptr);
    @memset(p1, 7);
    a.free(p1);
    try T.expectEqual(@as(u32, 1), lc.count);
    // The next block of the class is the parked one, resident as it was left.
    const p2 = try a.alloc(u8, 90 * 1024);
    try T.expectEqual(addr, @intFromPtr(p2.ptr));
    try T.expectEqual(@as(u32, 0), lc.count);
    // A shrink into a smaller class gives the tail back in place and the
    // block then parks under its new size.
    var list = p2;
    try T.expect(a.resize(list, 20 * 1024));
    list = list[0 .. 20 * 1024];
    a.free(list);
    try T.expectEqual(@as(u32, 0), lc.count);
    const small_ci = largeClass(20 * 1024).?;
    try T.expectEqual(@as(u32, 1), large_classes[small_ci].count);
    reclaimAll();
    try T.expectEqual(@as(u32, 0), large_classes[small_ci].count);
    // Above the classes a block maps and unmaps directly.
    try T.expectEqual(@as(?usize, null), largeClass(LARGE_MAX + 1));
    const huge = try a.alloc(u8, LARGE_MAX + 1);
    a.free(huge);
}
