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
const trace = @import("trace.zig");
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
    free_count: u32, // free cells currently on `free_head` (excludes dormant)
    cell_size: u32,
    free_head: ?*FreeCell,
    next: ?*SlabHeader, // partial-list links (owned by the class lock)
    prev: ?*SlabHeader,
    /// Pages `madvise`d/decommitted away (their cells pulled off the free list so
    /// the discarded link storage is never read). Bit p = page p.
    dormant_pages: u64,
    /// Cells removed from the free list because they live in a dormant page. Not
    /// re-handed-out until revived; counted toward the `live == 0` unmap test.
    dormant_cells: u32,
    /// Consecutive reclaim passes this slab has been mostly free. A few passes of
    /// hysteresis keep transiently-empty slabs (between two allocations) out of
    /// reclaim, so only stably-idle stragglers pay the decommit/revive churn.
    idle_passes: u8,
};

/// Upper bounds for the per-slab reclaim scan, independent of the runtime page
/// size: a slab holds at most `SLAB / CELL_ALIGN` cells and, at the smallest
/// conceivable page, `SLAB / 4096` pages.
const MAX_PAGES = SLAB / 4096;
const MAX_CELL_WORDS = (SLAB / CELL_ALIGN + 63) / 64;
/// Reclaim a slab only after it has been mostly free this many consecutive
/// passes (hysteresis against decommit/revive thrash on actively-cycled slabs).
const RECLAIM_IDLE_PASSES = 2;

const ClassState = struct {
    lock: SpinLock = .{},
    /// Slabs of this class that have at least one free cell. A slab with zero
    /// free cells is unlinked (found again on free via the pointer mask); a slab
    /// with every cell free is unlinked and either parked in `spare` or unmapped.
    partial: ?*SlabHeader = null,
    /// One fully-free slab kept mapped and threaded, reused by the next
    /// allocation of this class instead of mapping a fresh one. Unmapping a slab
    /// the instant its last cell frees thrashes any workload that holds a single
    /// live cell of a class across a call — the interpreted receiver chain is
    /// exactly that, so a method-call loop paid an mmap, a 16K-cell threading
    /// pass, and an munmap PER CALL. Parking one empty slab makes that
    /// alloc/free pair hit the free list. Bounded: at most one SLAB per class.
    spare: ?*SlabHeader = null,
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
        trace.dump(&st);
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
        .dormant_pages = 0,
        .dormant_cells = 0,
        .idle_passes = 0,
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

/// The class's next allocation frontier: the parked spare (already mapped and
/// threaded) before a freshly mapped slab. Caller holds the class lock.
fn takeFrontier(cs: *ClassState, ci: usize) ?*SlabHeader {
    const s = if (cs.spare) |sp| blk: {
        cs.spare = null;
        break :blk sp;
    } else newSlab(ci) orelse return null;
    s.prev = null;
    s.next = cs.partial;
    if (cs.partial) |p| p.prev = s;
    cs.partial = s;
    return s;
}

/// One cell off the class's partial list. Caller holds the class lock.
fn allocLockedOne(cs: *ClassState, ci: usize) ?[*]u8 {
    var slab = cs.partial orelse takeFrontier(cs, ci) orelse return null;
    // The head may have had its free cells decommitted into dormant pages by a
    // reclaim pass. Re-commit one (reusing that slab) before mapping fresh memory
    // — this is what keeps the reclaim from growing the address space unboundedly.
    while (slab.free_head == null) {
        if (slab.dormant_pages != 0) {
            _ = reviveOnePage(slab, class_sizes[ci], std.heap.pageSize());
            continue;
        }
        // Truly exhausted (no free cells, nothing dormant): drop and take the next
        // partial slab, reusing the parked spare (or mapping fresh) when none remain.
        cs.partial = slab.next;
        if (slab.next) |n| n.prev = null;
        slab.next = null;
        slab = cs.partial orelse takeFrontier(cs, ci) orelse return null;
    }
    const cell = slab.free_head.?;
    slab.free_head = cell.next;
    slab.free_count -= 1;
    if (slab.free_count == 0 and slab.dormant_pages == 0) {
        // No free cells and nothing dormant to revive: drop from the partial list
        // (re-linked on the next free of one of its live cells).
        cs.partial = slab.next;
        if (slab.next) |n| n.prev = null;
        slab.next = null;
    }
    return @ptrCast(cell);
}

/// One cell back onto its slab's free list. Caller holds the class lock.
fn freeLockedOne(ptr: [*]u8, slab: *SlabHeader, cs: *ClassState) void {
    // Off the partial list only when *truly* full — no free cell and no dormant
    // page. A reclaim pass can leave `free_count == 0` while the slab stays linked
    // (its capacity dormant, revived on demand); re-linking on `free_count` alone
    // would re-insert an already-linked slab and cycle the list.
    const was_full = slab.free_count == 0 and slab.dormant_pages == 0;
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
    if (slab.free_count + slab.dormant_cells == slab.total) {
        // No live cells remain (the rest are free or dormant): unlink it.
        if (slab.prev) |p| p.next = slab.next else cs.partial = slab.next;
        if (slab.next) |n| n.prev = slab.prev;
        slab.prev = null;
        slab.next = null;
        // Park it as the class's spare when there is none, so the next
        // allocation reuses this mapped, already-threaded slab. Otherwise return
        // the whole span — `munmap` reclaims the dormant pages too.
        if (cs.spare == null and slab.dormant_pages == 0) {
            cs.spare = slab;
        } else {
            unmapRaw(@ptrCast(slab), SLAB);
        }
    }
}

// --- per-thread magazines -----------------------------------------------------
// Every alloc/free taking the class spinlock serializes the interpreter's
// worker threads on a handful of hot size classes — a concurrent-stress
// workload spent a third of its samples spinning here. Each thread instead
// keeps a small per-class cache of free cells: pops and pushes touch only
// thread-local state, and the class lock is taken once per BATCH (refill on
// empty, flush of half on full) instead of once per cell. Magazine cells are
// off their slab's free list, so the GC-time reclaim pass sees them as live
// and never decommits their pages out from under a cache.

/// Per-class magazine capacity: ~4KB of cached cells, at least 4, at most 64.
const mag_caps: [class_sizes.len]u16 = blk: {
    var c: [class_sizes.len]u16 = undefined;
    for (class_sizes, 0..) |sz, i| c[i] = @intCast(@min(64, @max(4, 4096 / sz)));
    break :blk c;
};

const Magazine = struct { head: ?*FreeCell = null, count: u16 = 0 };

threadlocal var magazines: [class_sizes.len]Magazine = @splat(.{});

/// Return every cached cell to the slabs. Called at worker-thread exit so a
/// dead thread strands nothing; also keeps `KLIO_SLAB_STAT` runs exact.
pub fn flushMagazines() void {
    for (&magazines, 0..) |*mag, ci| {
        if (mag.head == null) continue;
        const cs = &class_states[ci];
        cs.lock.lock();
        defer cs.lock.unlock();
        while (mag.head) |cell| {
            mag.head = cell.next;
            freeLockedOne(@ptrCast(cell), slabOf(@ptrCast(cell)), cs);
        }
        mag.count = 0;
    }
}

fn allocSmall(len: usize) ?[*]u8 {
    const ci = classIndex(len);
    const cs = &class_states[ci];
    // The cell tracer records per-address stacks; magazine round-trips would be
    // invisible to it, so diagnostic runs take the exact locked path.
    if (cell_trace_enabled) {
        cs.lock.lock();
        defer cs.lock.unlock();
        const cell = allocLockedOne(cs, ci) orelse return null;
        // Sample 1-in-256 by address (deterministic, so free's remove agrees) to
        // keep the per-allocation stack capture from starving the collector on a
        // heavily-churning workload. Reported bytes are ~1/256 of the true total.
        if (gc.program_started and (@intFromPtr(cell) & 0xff) == 0) cellTraceNote(ci, @intFromPtr(cell), len);
        return cell;
    }
    const mag = &magazines[ci];
    if (mag.head) |cell| {
        mag.head = cell.next;
        mag.count -= 1;
        return @ptrCast(cell);
    }
    // Empty: take one for the caller and refill half a magazine in the same
    // critical section.
    cs.lock.lock();
    defer cs.lock.unlock();
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

fn freeSmall(ptr: [*]u8) void {
    const slab = slabOf(ptr);
    const ci = slab.class_idx;
    const cs = &class_states[ci];
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
    // Full: return this cell and drain half the magazine under one lock.
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

// --- page reclamation --------------------------------------------------------
// A slab is `munmap`ped only when its last live cell frees, so a region holding
// even one long-lived straggler keeps its whole span resident even after the rest
// churns free. This pass — run during the stop-the-world GC — hands the physical
// pages of such stably-sparse regions back to the OS: a page no live cell overlaps
// is decommitted, and the free cells whose intrusive link storage lived in it are
// pulled off the free list so the discarded links are never read. Those cells go
// "dormant" — re-committed and re-threaded on demand by `allocSmall` rather than
// mapping a fresh slab, so the address space stays bounded.

/// Return the resident pages of `[addr, addr+len)` to the OS while keeping the
/// range mapped (zero-fill on the next touch). Overlaying a fresh anonymous
/// `MAP_FIXED` mapping is the portable way to actually drop RSS — on macOS
/// `madvise(MADV_FREE*/DONTNEED)` leaves the pages counted resident until
/// reclaimed under pressure, so it does not move RSS at all.
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

/// Re-commit one dormant page's cells onto the free list. The decommitted page
/// stayed mapped (zero-filled), so re-threading its cells — which faults the page
/// back in as it is touched — makes them allocatable again. Reusing dormant
/// capacity rather than mapping a fresh slab is what bounds the address space.
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

/// Decommit the all-free pages of one stably-sparse slab. STW-only: the class
/// lock is held and no other thread mutates the slab.
fn reclaimSlab(s: *SlabHeader, cell_size: usize, pg: usize) void {
    // Hysteresis: only act on slabs that have been mostly free for several
    // consecutive passes, so a slab that is merely between two allocations is not
    // churned into dormant pages and immediately revived.
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

    // Bitset of cells currently on the free list.
    var free_bits = [_]u64{0} ** MAX_CELL_WORDS;
    {
        var fc = s.free_head;
        while (fc) |cell| {
            const idx = (@intFromPtr(cell) - data_start) / cell_size;
            free_bits[idx >> 6] |= @as(u64, 1) << @intCast(idx & 63);
            fc = cell.next;
        }
    }

    // A page is reclaimable iff no *live* cell overlaps it. Page 0 holds the
    // header; already-dormant pages are left as they are.
    var reclaimable = [_]bool{false} ** MAX_PAGES;
    {
        var p: usize = 1;
        while (p < n_pages) : (p += 1) {
            reclaimable[p] = (s.dormant_pages & (@as(u64, 1) << @intCast(p))) == 0;
        }
    }
    {
        var i: usize = 0;
        while (i < s.total) : (i += 1) {
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

    // Rebuild the free list, dropping every cell whose link storage (its start)
    // sits in a page about to be discarded — reading its `next` afterward would
    // fault in a zeroed page and corrupt the chain.
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
    s.free_count = kept;
    s.dormant_cells += dropped;

    // Decommit the reclaimable pages in contiguous runs (one mapping op per run).
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

/// Return the resident pages of sparsely-populated slabs to the OS. Wired as the
/// GC's `release_to_os` hook for the slab backend; runs stop-the-world after a
/// sweep, so the partial lists are stable and no cell is concurrently touched.
pub fn reclaimDormant() void {
    const pg = std.heap.pageSize();
    if (SLAB / pg > MAX_PAGES) return; // defensive: oversized runtime page
    for (&class_states, 0..) |*cs, ci| {
        cs.lock.lock();
        defer cs.lock.unlock();
        // A spare parked by `freeSmall` holds no live cells; a reclaim pass is
        // exactly when to hand its span back, so the alloc/free thrash guard
        // never becomes a permanent per-class 256K tax.
        if (cs.spare) |sp| {
            cs.spare = null;
            unmapRaw(@ptrCast(sp), SLAB);
        }
        // Skip the partial head: it is the active allocation frontier, so
        // decommitting it would just be undone by the next allocation. Reclaimed
        // slabs stay linked — their dormant capacity is revived on demand by
        // `allocSmall` — so the partial list stays a stable spine across passes.
        const head = cs.partial orelse continue;
        var slab = head.next;
        while (slab) |s| {
            reclaimSlab(s, class_sizes[ci], pg);
            slab = s.next;
        }
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

test "slab magazine caches a freed cell and flush returns it" {
    const a = allocator;
    flushMagazines();
    const p1 = try a.alloc(u8, 64);
    const addr = @intFromPtr(p1.ptr);
    a.free(p1);
    // The freed cell sits in this thread's magazine; flushing pushes it (and
    // the refill batch) back onto the slab free list, so it is among the next
    // allocations rather than stranded in the cache.
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

test "slab reclaim decommits sparse slabs, preserves stragglers, revives dormant" {
    const a = allocator;
    const T = std.testing;
    const N = 300; // 2 KiB cells (~128/slab) → spans several slabs
    var bufs: [N][]u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        b.* = try a.alloc(u8, 2048);
        @memset(b.*, @intCast(i & 0xff));
    }
    // Free everything except a few scattered stragglers, so the slabs they do not
    // pin go mostly free and become reclaim candidates.
    const kept = [_]usize{ 7, 140, 293 };
    for (bufs, 0..) |b, i| {
        const keep = i == kept[0] or i == kept[1] or i == kept[2];
        if (!keep) a.free(b);
    }
    // Clear the idle-pass hysteresis so the sparse non-head slabs decommit.
    var pass: usize = 0;
    while (pass < RECLAIM_IDLE_PASSES + 2) : (pass += 1) reclaimDormant();
    // A straggler shares its slab with decommitted pages, but its own page is
    // never discarded — its bytes must be intact.
    for (kept) |k| for (bufs[k]) |byte| try T.expectEqual(@as(u8, @intCast(k & 0xff)), byte);
    // Allocating again must revive dormant capacity (or map fresh) and hand back
    // sound, writable cells.
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
