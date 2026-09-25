//! Precise, non-moving mark-sweep collector over the `ObjRef`/`ControlBlock`
//! heap. A minor marks with the world stopped; a major marks whole in one
//! stop or spans stops, traced between them in slices or by the marking
//! thread (`KLIO_GC_MAJOR`); the sweep runs on a sweeper thread once the
//! world has restarted. Frees by reachability, so a missing retain or an extra
//! release is harmless and cycles are collected. Imports nothing from
//! `value`, and from `objcell` only its cell-lock check; out-edges are found
//! by comptime dispatch in `objcell`.

const std = @import("std");
const builtin = @import("builtin");
const tls_fast = @import("tls_fast.zig");
const trace = @import("trace.zig");
const clock_mod = @import("clock.zig");
const slab = @import("slab.zig");
const assertNoCellLock = @import("objcell.zig").assertNoCellLock;
const Allocator = std.mem.Allocator;

/// Type-erased header on every `ControlBlock(T)`. `gc_mark` is an epoch,
/// marked iff equal to the current one, so no clear pass is needed.
pub const GcHeader = struct {
    gc_next: ?*GcHeader = null,
    gc_mark: usize = 0,
    gc_trace: *const fn (*GcHeader, *Marker) void,
    gc_finalize: *const fn (*GcHeader) void,
    /// Payload `@typeName(T)`, interned per type so pointer identity keys it.
    gc_type: [*:0]const u8 = "",
    /// 0 = nursery, swept every collection; 1 = tenured, swept only by major
    /// ones. A cell tenures on surviving its first collection.
    gc_gen: u8 = 0,
    /// Set by `writeBarrier` on a store into a tenured cell: it joins the
    /// remembered set, so a tenured-to-nursery edge cannot be missed.
    gc_remembered: bool = false,
    /// One past the cell's entry in `ranged`, 0 for none: a large tenured
    /// array whose element stores reported their indices remembers only the
    /// range they touched. Rides in the padding before `gc_bytes`.
    gc_range: u16 = 0,
    /// `@sizeOf(Cell)` plus external payload bytes at mint.
    gc_bytes: u32 = 0,
};

/// `KLIO_GC_HIST`: print live cells per payload type after each collection.
pub var gc_hist: bool = false;

/// Tri-color marker over an explicit grey worklist, never native recursion:
/// the value graph is deep and cyclic.
pub const Marker = struct {
    epoch: usize,
    grey: std.ArrayList(*GcHeader) = .empty,
    arena: Allocator,
    /// Minor collections sweep only the nursery, so marking stops at each
    /// tenured cell; tenure or the remembered set covers its children.
    minor: bool = false,
    /// A major mark between the stops it spans: nursery cells are left to
    /// the remark, which marks the nursery itself. A tracer must not record
    /// that this mark traced everything a structure holds.
    between_stops: bool = false,
    /// `KLIO_GC_VERIFY`: the cell being checked. A child it reaches that is
    /// unmarked is reported, not marked: for a minor an unmarked nursery
    /// child is an edge no write barrier recorded; for a major any unmarked
    /// child is, since the major's marked set must be closed.
    verify_from: ?*GcHeader = null,
    verify_major: bool = false,
    /// Nursery cells this mark reached, and their bytes. Each is tenured as
    /// it is marked, so the world restarts before the sweep does: a store
    /// into a survivor from then on meets the write barrier.
    promoted: usize = 0,
    promoted_bytes: usize = 0,
    /// When set, each cell this mark promotes, for a major in progress to
    /// shade once the mark is done.
    promoted_list: ?*std.ArrayList(*GcHeader) = null,
    /// Registered cells this mark reached; a permanent cell carries no bytes.
    live: usize = 0,

    pub fn shade(self: *Marker, h: *GcHeader) void {
        if (self.verify_from) |from| {
            if (self.verify_major) {
                if (h.gc_mark != self.epoch) verifyReportMajor(from, h);
            } else if (h.gc_gen == 0 and h.gc_mark != self.epoch) {
                verifyReport(from, h);
            }
            return;
        }
        if (gc_poison and h.gc_trace == poisonTrap) {
            std.debug.print("\n[GC-POISON-SHADE] root reached SWEPT cell: type={s} ctx={s}:{d}\n", .{ h.gc_type, poison_ctx_name, poison_ctx_idx });
            trace.dumpCurrent(.{});
            @panic("KGC: root shaded a swept cell (incomplete root)");
        }
        // Sound while every tenured-to-nursery edge is remembered.
        if (self.minor and h.gc_gen != 0 and minor_stops_at_tenured) return;
        // The same holds the other way: a nursery cell a tenured cell holds
        // is reached again from a remembered cell by the remark.
        if (self.between_stops and h.gc_gen == 0) return;
        if (h.gc_mark == self.epoch) return; // already grey or black this epoch
        h.gc_mark = self.epoch;
        if (h.gc_gen == 0) {
            h.gc_gen = 1;
            self.promoted += 1;
            self.promoted_bytes += h.gc_bytes;
            if (self.promoted_list) |list| list.append(std.heap.page_allocator, h) catch
                @panic("KGC: promoted list allocation failed");
        }
        if (h.gc_bytes != 0) self.live += 1;
        self.grey.append(self.arena, h) catch {
            // Under-marking would be a use-after-free.
            @panic("KGC: grey worklist allocation failed");
        };
    }

    pub fn drain(self: *Marker) void {
        while (self.grey.pop()) |h| h.gc_trace(h, self);
    }

    /// Whether this mark reaches everything a structure it traces holds and
    /// tenures it, so a tracer may record that a frozen structure needs no
    /// retrace by the next minor. A spanning major between its stops leaves
    /// nursery cells to the remark, and a verify pass marks nothing.
    pub inline fn marksWhole(self: *const Marker) bool {
        return !self.between_stops and self.verify_from == null;
    }

    fn drainCounted(self: *Marker) usize {
        var n: usize = 0;
        while (self.grey.pop()) |h| {
            n += 1;
            h.gc_trace(h, self);
        }
        return n;
    }
};

/// Test-and-set spinlock, never held across a safe point.
const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn tryLock(self: *SpinLock) bool {
        return !self.state.swap(true, .acquire);
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

var reg_lock: SpinLock = .{};
/// Cells minted since the last collection; survivors move to `tenured`.
var nursery: ?*GcHeader = null;
var tenured: ?*GcHeader = null;
var tenured_count: usize = 0;
var bytes_since_gc: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
/// Major-trigger accumulator: promoted bytes plus net external growth.
var bytes_since_major: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var live_bytes: usize = 0;

/// Collections default to minor, nursery-only sweeps, with major ones on an
/// Appel schedule over promoted bytes. `KLIO_GC_GEN=0` forces every one major.
pub var generational: bool = true;
var major_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Major trigger, recomputed after each major from the surviving live set.
var major_threshold: usize = 8 * 1024 * 1024;

/// How a major collection marks, set by `KLIO_GC_MAJOR`. By default
/// (`concurrent`) it spans stops: it begins in a minor's stop, the marking
/// thread traces it while the mutators run, and that thread runs the remark
/// once nothing is left to trace. `slices` spans it the same way but traces
/// a slice at each minor's stop instead, and is what a build without threads
/// falls back to; `stop` marks it whole in one stop.
pub const MajorMode = enum { stop, slices, concurrent };
pub var major_mode: MajorMode = .concurrent;
/// `KLIO_GC_SLICE`: how many cells a slice traces beyond what its minor
/// handed the major.
pub var slice_budget: usize = 10_000;
/// `KLIO_GC_MAJOR_EVERY=N`: every Nth collection is a major; `0` disables.
pub var major_every: usize = 0;
var collections_since_major: usize = 0;

// A major that spans stops. Its first stop is a minor's, which then shades
// the roots into the major and restarts the world with every live cell
// tenured. Between stops the major traces tenured cells only and passes
// over nursery cells. Every minor while it runs hands the major the marked
// cells the write barrier remembered in the minor's window, and the
// survivors the minor promoted. The remark, in a stop of its own, shades
// the roots again, retraces every marked cell mutated since the major
// began, marks the nursery with the major's epoch and drains.
//
// Why that marks everything live: every cell the major marked and traced
// before a store into it went through the write barrier, which puts a
// tenured cell on the remembered set once per minor window; each window's
// set reaches the major, which retraces every such cell it has marked with
// what the cell holds by then, and traces one it has not marked whole if it
// reaches it later. A cell born during the major is a nursery cell until a
// minor promotes it (shaded into the major then) or the remark reaches it.
// Anything that holds it is a root, another nursery cell, or a tenured
// cell stored into after it was born, which is remembered. So the remark,
// tracing from the roots and the remembered cells through the nursery,
// reaches every newborn cell still live and, through it, any tenured cell
// only it holds that the major has not traced.

/// The major in progress, touched only inside stops or under `major_lock`.
const MajorMark = struct {
    active: bool = false,
    marker: Marker = .{ .epoch = 0, .arena = std.heap.page_allocator },
    /// Cells the minors of this major remembered: retraced before it ends,
    /// whole or by span.
    dirty: std.ArrayList(*GcHeader) = .empty,
    dirty_spans: std.ArrayList(Span) = .empty,
    /// The survivors of the current minor, shaded into the major after it.
    promoted: std.ArrayList(*GcHeader) = .empty,
    /// No grey or dirty cell is left, so the next collection is the remark.
    drained: bool = false,
    /// Stops the major has spanned and cells it traced between them.
    stops: usize = 0,
    traced: usize = 0,

    fn reset(self: *MajorMark) void {
        self.marker.grey.clearRetainingCapacity();
        self.dirty.clearRetainingCapacity();
        self.dirty_spans.clearRetainingCapacity();
        self.promoted.clearRetainingCapacity();
        self.active = false;
        self.drained = false;
        self.stops = 0;
        self.traced = 0;
    }

    fn workLeft(self: *const MajorMark) bool {
        return self.marker.grey.items.len != 0 or self.dirty.items.len != 0 or self.dirty_spans.items.len != 0;
    }
};
var major_mark: MajorMark = .{};
/// Held by a caller outside a stop that edits the major's lists.
var major_lock: SpinLock = .{};

fn spanningMajors() bool {
    return major_mode != .stop and generational and minor_stops_at_tenured;
}

// The marking thread. It traces a spanning major between the major's stops
// while the mutators run, `marker_batch` cells at a time. It is not a
// mutator: it holds `major_lock` while it traces a batch, and a collection
// takes that lock once the mutators have stopped, so the major's lists and
// marks change hands only between batches. It reads each cell under the
// cell's shared lock, which no stopped thread holds, and passes over nursery
// cells as every spanning major does. With nothing left to trace it runs the
// remark itself.

const has_marking_thread = builtin.link_libc and !builtin.single_threaded;

/// Cells the marking thread traces before it looks for a stop again.
var marker_batch: usize = 256;

const MarkingThread = struct {
    sync: SweepSync = .{},
    /// A major began and the thread has not taken it up yet.
    wanted: bool = false,
    started: bool = false,
    /// Tests hand the thread one batch at a time: below zero it runs free,
    /// otherwise it waits for a step before each batch.
    steps: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1),
    batches: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};
var marking_thread: MarkingThread = .{};

fn markingThreadMain() void {
    const mt = &marking_thread;
    while (true) {
        mt.sync.lock();
        while (!mt.wanted) mt.sync.wait();
        mt.wanted = false;
        mt.sync.unlock();
        markConcurrently();
    }
}

/// Starts the marking thread if it has not started; false when it cannot.
/// A collection calls this before it raises its stop, so the spawn, which
/// takes milliseconds on a loaded machine, is never part of a pause.
fn startMarkingThread() bool {
    if (comptime !has_marking_thread) return false;
    const mt = &marking_thread;
    mt.sync.lock();
    defer mt.sync.unlock();
    return startMarkingThreadLocked(mt);
}

fn startMarkingThreadLocked(mt: *MarkingThread) bool {
    if (mt.started) return true;
    const t = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, markingThreadMain, .{}) catch return false;
    t.detach();
    mt.started = true;
    installForkHandler();
    return true;
}

/// Hands the major just begun to the marking thread, starting the thread
/// first if it has not started. False when it could not start. World stopped.
fn wakeMarkingThread() bool {
    if (comptime !has_marking_thread) return false;
    const mt = &marking_thread;
    mt.sync.lock();
    defer mt.sync.unlock();
    if (!startMarkingThreadLocked(mt)) return false;
    mt.wanted = true;
    mt.sync.broadcast();
    return true;
}

/// Traces the major in progress while the mutators run, then ends it.
fn markConcurrently() void {
    const mm = &major_mark;
    const mt = &marking_thread;
    while (true) {
        // A stop owns the major's lists until it ends.
        if (stopRaised()) waitStopEnd(null);
        if (!takeMarkerStep()) continue;
        if (!major_lock.tryLock()) {
            std.Thread.yield() catch {};
            continue;
        }
        if (!mm.active) {
            major_lock.unlock();
            return;
        }
        const done = majorSlice(marker_batch, true);
        if (done) mm.drained = true;
        major_lock.unlock();
        _ = mt.batches.fetchAdd(1, .release);
        // Nothing left to trace: the remark, as a collection of its own. A
        // collection already under way is waited out instead, and the loop
        // looks again.
        if (done) collectImpl(false);
    }
}

/// True when the thread may trace a batch now; a test grants each one.
fn takeMarkerStep() bool {
    const steps = &marking_thread.steps;
    const n = steps.load(.acquire);
    if (n < 0) return true;
    if (n > 0 and steps.cmpxchgWeak(n, n - 1, .acq_rel, .acquire) == null) return true;
    std.Thread.yield() catch {};
    return false;
}

/// The first stop of a spanning major, after its minor: every live cell is
/// tenured now, so the roots shaded here are the major's snapshot.
fn beginMajor() void {
    const mm = &major_mark;
    mm.reset();
    cur_epoch = nextEpoch(cur_epoch);
    const grey = mm.marker.grey;
    mm.marker = .{ .epoch = cur_epoch, .arena = std.heap.page_allocator, .between_stops = true, .grey = grey };
    mm.active = true;
    mm.stops = 1;
    markRoots(&mm.marker);
}

/// Hands the major the cells the write barrier remembered in the window
/// that just closed, and returns how many. Only cells the major has marked
/// need a retrace: one it has not reached yet is traced whole when it is.
/// Caller holds `remembered_lock`, world stopped.
fn harvestRemembered() usize {
    const mm = &major_mark;
    const epoch = mm.marker.epoch;
    const a = std.heap.page_allocator;
    var n: usize = 0;
    for (remembered.items) |h| {
        if (h.gc_mark != epoch) continue;
        mm.dirty.append(a, h) catch @panic("KGC: dirty list allocation failed");
        n += 1;
    }
    for (ranged[0..ranged_len]) |*e| {
        const h = e.h orelse continue;
        if (h.gc_remembered or h.gc_mark != epoch) continue;
        mm.dirty_spans.append(a, .{ .h = h, .lo = e.lo.load(.monotonic), .hi = e.hi.load(.monotonic), .trace = e.trace }) catch
            @panic("KGC: dirty list allocation failed");
        n += 1;
    }
    return n;
}

/// Traces up to `budget` cells of the major: grey cells first, then the
/// marked cells its minors remembered. True once neither is left. The
/// marking thread passes `yield_to_stop`, so a stop raised meanwhile waits
/// for one cell rather than the rest of the batch.
fn majorSlice(budget: usize, comptime yield_to_stop: bool) bool {
    const mm = &major_mark;
    const m = &mm.marker;
    var left = budget;
    while (left != 0) : (left -= 1) {
        if (yield_to_stop and stopRaised()) return false;
        if (m.grey.pop()) |h| {
            h.gc_trace(h, m);
            mm.traced += 1;
        } else if (mm.dirty.pop()) |h| {
            if (h.gc_mark == m.epoch) h.gc_trace(h, m);
        } else if (mm.dirty_spans.pop()) |sp| {
            if (sp.h.gc_mark == m.epoch) sp.trace(sp.h, m, sp.lo, sp.hi);
        } else {
            return true;
        }
    }
    return !mm.workLeft();
}

/// Takes `major_lock` for a stop. The marking thread may be descheduled
/// while it holds the lock, so after a short spin this yields the core.
fn lockMajorForStop() void {
    var rounds: u32 = 0;
    while (!major_lock.tryLock()) : (rounds +|= 1) {
        if (rounds < spin_rounds) std.atomic.spinLoopHint() else std.Thread.yield() catch std.atomic.spinLoopHint();
    }
}

/// Drops the major in progress; it frees nothing, and its marks age out.
fn abortMajor() void {
    major_lock.lock();
    defer major_lock.unlock();
    major_mark.reset();
}

/// Removes every cell `drop` selects from the major's lists, for a caller
/// about to free them.
fn scrubMajor(ctx: anytype, comptime drop: fn (@TypeOf(ctx), *GcHeader) bool) void {
    major_lock.lock();
    defer major_lock.unlock();
    const mm = &major_mark;
    if (!mm.active) return;
    inline for (.{ &mm.marker.grey, &mm.dirty, &mm.promoted }) |list| {
        var i: usize = 0;
        while (i < list.items.len) {
            if (drop(ctx, list.items[i])) _ = list.swapRemove(i) else i += 1;
        }
    }
    var i: usize = 0;
    while (i < mm.dirty_spans.items.len) {
        if (drop(ctx, mm.dirty_spans.items[i].h)) _ = mm.dirty_spans.swapRemove(i) else i += 1;
    }
}

fn nextEpoch(e: usize) usize {
    const n = e +% 1;
    return if (n == 0) 1 else n; // 0 is the never-marked sentinel
}

/// The remembered set: tenured cells mutated since promotion, re-traced at the
/// start of every minor mark and drained by every collection.
var remember_trace_init: bool = false;
var remember_trace_on: bool = false;
fn rememberTraceOn() bool {
    if (comptime !@import("builtin").link_libc) return false;
    if (!remember_trace_init) {
        remember_trace_on = std.c.getenv("KLIO_GC_REMEMBER_TRACE") != null;
        remember_trace_init = true;
    }
    return remember_trace_on;
}

var remembered: std.ArrayList(*GcHeader) = .empty;
var remembered_lock: SpinLock = .{};

/// Traces elements `lo` through `hi` of an array-like cell.
pub const RangeTraceFn = *const fn (h: *GcHeader, m: *Marker, lo: u32, hi: u32) void;

/// A large tenured array's element stores since the last collection: the
/// lowest and highest index written. Its cell's `gc_range` names the entry.
const RangeEntry = struct {
    h: ?*GcHeader = null,
    lo: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    hi: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    trace: RangeTraceFn = undefined,
};

/// Fixed so a store's fast path can widen an entry while another thread
/// adds one: the table never moves. Full, a store remembers the whole cell.
var ranged: [4096]RangeEntry = @splat(.{});
var ranged_len: usize = 0;

/// Record a reference store: a tenured cell joins the remembered set.
pub inline fn writeBarrier(h: *GcHeader) void {
    if (h.gc_gen == 0) return;
    if (@atomicLoad(bool, &h.gc_remembered, .monotonic)) return;
    writeBarrierSlow(h);
}

/// Record a store into element `index` of an array-like cell, and only
/// there: the next minor mark traces the range of indices stored since the
/// last collection rather than the whole array. A store that moves other
/// elements (an insert, a removal, a sort) uses `writeBarrier`.
pub inline fn writeBarrierAt(h: *GcHeader, index: usize, trace_range: RangeTraceFn) void {
    if (h.gc_gen == 0) return;
    if (@atomicLoad(bool, &h.gc_remembered, .monotonic)) return;
    const i: u32 = std.math.lossyCast(u32, index);
    const slot = @atomicLoad(u16, &h.gc_range, .acquire);
    if (slot != 0) {
        // Stores never overlap a collection, which runs with the world
        // stopped at safe points, so the entry is this cell's until then.
        const e = &ranged[slot - 1];
        if (i < e.lo.load(.monotonic)) _ = e.lo.fetchMin(i, .monotonic);
        if (i > e.hi.load(.monotonic)) _ = e.hi.fetchMax(i, .monotonic);
        return;
    }
    writeBarrierAtSlow(h, i, trace_range);
}

fn writeBarrierAtSlow(h: *GcHeader, i: u32, trace_range: RangeTraceFn) void {
    {
        remembered_lock.lock();
        defer remembered_lock.unlock();
        if (h.gc_remembered) return;
        if (h.gc_range != 0) {
            const e = &ranged[h.gc_range - 1];
            _ = e.lo.fetchMin(i, .monotonic);
            _ = e.hi.fetchMax(i, .monotonic);
            return;
        }
        if (ranged_len < ranged.len) {
            const e = &ranged[ranged_len];
            e.h = h;
            e.lo.store(i, .monotonic);
            e.hi.store(i, .monotonic);
            e.trace = trace_range;
            ranged_len += 1;
            @atomicStore(u16, &h.gc_range, @intCast(ranged_len), .release);
            return;
        }
    }
    writeBarrierSlow(h);
}

/// Unlinks `h`'s range entry, if it has one. Caller holds `remembered_lock`.
fn dropRange(h: *GcHeader) void {
    if (h.gc_range == 0) return;
    ranged[h.gc_range - 1].h = null;
    h.gc_range = 0;
}

/// Empties the range table. Caller holds `remembered_lock`, world stopped.
fn clearRanges() void {
    for (ranged[0..ranged_len]) |*e| {
        if (e.h) |h| h.gc_range = 0;
        e.h = null;
    }
    ranged_len = 0;
}

/// A remembered range of a tenured array: elements `lo` through `hi`.
const Span = struct { h: *GcHeader, lo: u32, hi: u32, trace: RangeTraceFn };

/// Trace every remembered cell, from a snapshot taken outside
/// `remembered_lock`: a tracer can reach a write barrier that takes it. A
/// cell remembered whole is traced whole, and one remembered by range only
/// over its range. Returns how many of each it traced.
pub fn traceRemembered(marker: *Marker) RememberedCounts {
    return traceRememberedIf(marker, false);
}

/// `traceRemembered`, skipping with `only_marked` every cell this mark has
/// not reached: the remark traces such a cell whole if it reaches it later.
fn traceRememberedIf(marker: *Marker, only_marked: bool) RememberedCounts {
    remembered_lock.lock();
    const snapshot = std.heap.page_allocator.dupe(*GcHeader, remembered.items) catch
        @panic("KGC: remembered snapshot allocation failed");
    const spans = std.heap.page_allocator.alloc(Span, ranged_len) catch
        @panic("KGC: remembered snapshot allocation failed");
    var n: usize = 0;
    for (ranged[0..ranged_len]) |*e| {
        const h = e.h orelse continue;
        if (h.gc_remembered) continue;
        spans[n] = .{ .h = h, .lo = e.lo.load(.monotonic), .hi = e.hi.load(.monotonic), .trace = e.trace };
        n += 1;
    }
    remembered_lock.unlock();
    defer std.heap.page_allocator.free(snapshot);
    defer std.heap.page_allocator.free(spans);
    return retrace(marker, snapshot, spans[0..n], only_marked);
}

/// Traces `whole` cells whole and `spans` over their ranges, skipping with
/// `only_marked` every cell `marker` has not reached.
fn retrace(marker: *Marker, whole: []const *GcHeader, spans: []const Span, only_marked: bool) RememberedCounts {
    var counts: RememberedCounts = .{};
    for (whole) |h| {
        if (only_marked and h.gc_mark != marker.epoch) continue;
        if (rem_top) {
            const t = clock_mod.monotonicNanos();
            const g = marker.grey.items.len;
            h.gc_trace(h, marker);
            remTopNote(h, clock_mod.monotonicNanos() - t, marker.grey.items.len -| g);
        } else h.gc_trace(h, marker);
        counts.whole += 1;
    }
    for (spans) |sp| {
        if (only_marked and sp.h.gc_mark != marker.epoch) continue;
        sp.trace(sp.h, marker, sp.lo, sp.hi);
        counts.spans += 1;
        counts.span_len += sp.hi - sp.lo + 1;
    }
    return counts;
}

/// `KLIO_GC_REM_TOP`: a collection whose retrace of whole remembered cells
/// takes over a millisecond prints the payload types that took it
/// (`[kgc-rem]`): cells, time, and the children they shaded.
pub var rem_top: bool = false;
const RemTop = struct { ty: ?[*:0]const u8 = null, n: usize = 0, ns: u64 = 0, shaded: usize = 0, largest_ns: u64 = 0, largest: ?*GcHeader = null };
var rem_top_rows: [32]RemTop = @splat(.{});

/// Cells whose whole retrace took over 200 us: the next barrier that
/// remembers one prints the stack that stored into it (`[kgc-rem-store]`).
var rem_watch: [8]?*GcHeader = @splat(null);

fn remWatch(h: *GcHeader) void {
    for (&rem_watch) |*w| {
        if (w.* == h) return;
    }
    for (&rem_watch) |*w| {
        if (w.* == null) {
            w.* = h;
            return;
        }
    }
}

fn remWatchHit(h: *GcHeader) void {
    for (&rem_watch) |*w| {
        if (w.* != h) continue;
        w.* = null;
        std.debug.print("[kgc-rem-store] a whole-cell barrier on {s} {*}, which a retrace found large:\n", .{ h.gc_type, h });
        trace.dumpCurrent(.{});
        return;
    }
}

fn remTopNote(h: *GcHeader, ns: u64, shaded: usize) void {
    if (ns > 200 * std.time.ns_per_us) remWatch(h);
    for (&rem_top_rows) |*r| {
        if (r.n == 0) r.ty = h.gc_type;
        if (r.ty != h.gc_type) continue;
        r.n += 1;
        r.ns += ns;
        r.shaded += shaded;
        if (ns > r.largest_ns) {
            r.largest_ns = ns;
            r.largest = h;
        }
        return;
    }
}

fn remTopReport(epoch: usize, kind: []const u8) void {
    std.mem.sort(RemTop, &rem_top_rows, {}, struct {
        fn gt(_: void, a: RemTop, b: RemTop) bool {
            return a.ns > b.ns;
        }
    }.gt);
    for (rem_top_rows[0..@min(6, rem_top_rows.len)]) |r| {
        if (r.n == 0) break;
        std.debug.print("[kgc-rem] epoch={d} kind={s} type={s} cells={d} us={d} shaded={d} largest_us={d} largest={*}\n", .{
            epoch, kind, r.ty.?, r.n, r.ns / 1000, r.shaded, r.largest_ns / 1000, r.largest,
        });
    }
}

fn remTopClear() void {
    rem_top_rows = @splat(.{});
}

pub const RememberedCounts = struct {
    whole: usize = 0,
    spans: usize = 0,
    span_len: usize = 0,

    fn add(self: *RememberedCounts, other: RememberedCounts) void {
        self.whole += other.whole;
        self.spans += other.spans;
        self.span_len += other.span_len;
    }
};

fn writeBarrierSlow(h: *GcHeader) void {
    remembered_lock.lock();
    defer remembered_lock.unlock();
    if (h.gc_remembered) return;
    h.gc_remembered = true;
    if (rem_top) remWatchHit(h);
    if (rememberTraceOn()) {
        std.debug.print("[gc-remember] h={*} gen={d} type={s} program_started={}\n", .{ h, h.gc_gen, h.gc_type, program_started });
    }
    remembered.append(std.heap.page_allocator, h) catch
        @panic("KGC: remembered set allocation failed");
}

/// An address range about to be unmapped as a whole.
pub const Range = struct { start: usize, len: usize };

fn inRanges(ranges: []const Range, h: *GcHeader) bool {
    const addr = @intFromPtr(h);
    for (ranges) |r| {
        if (addr >= r.start and addr < r.start + r.len) return true;
    }
    return false;
}

/// Unlinks every cell inside `ranges` from the collector's lists before the
/// memory goes away under it: a build phase mints permanent cells and a store
/// into one puts it on the remembered set, which the next collection would
/// otherwise trace through freed memory. A major in progress ends here: it
/// would go on tracing cells live when it began, and one of those may hold
/// a cell in the ranges though nothing live does now.
pub fn forgetRanges(ranges: []const Range) void {
    waitSweep();
    abortMajor();
    {
        remembered_lock.lock();
        defer remembered_lock.unlock();
        var i: usize = 0;
        while (i < remembered.items.len) {
            if (inRanges(ranges, remembered.items[i])) {
                _ = remembered.swapRemove(i);
            } else {
                i += 1;
            }
        }
        for (ranged[0..ranged_len]) |*e| {
            if (e.h) |h| if (inRanges(ranges, h)) {
                e.h = null;
            };
        }
    }
    {
        program_perm_lock.lock();
        defer program_perm_lock.unlock();
        program_perm = unlinkInRanges(program_perm, ranges);
    }
    {
        reg_lock.lock();
        defer reg_lock.unlock();
        nursery = unlinkInRanges(nursery, ranges);
        const before = tenured_count;
        tenured = unlinkInRanges(tenured, ranges);
        var n: usize = 0;
        var cur = tenured;
        while (cur) |h| : (cur = h.gc_next) n += 1;
        tenured_count = n;
        if (before != n) live_bytes = n;
    }
}

fn unlinkInRanges(head: ?*GcHeader, ranges: []const Range) ?*GcHeader {
    var out = head;
    var prev: ?*GcHeader = null;
    var cur = head;
    while (cur) |h| {
        const next = h.gc_next;
        if (inRanges(ranges, h)) {
            if (prev) |p| p.gc_next = next else out = next;
        } else {
            prev = h;
        }
        cur = next;
    }
    return out;
}

/// Drop one cell from the remembered set and the major's lists, for a
/// caller about to free it.
pub fn forgetCell(h: *GcHeader) void {
    scrubMajor(h, isCell);
    remembered_lock.lock();
    defer remembered_lock.unlock();
    dropRange(h);
    if (!h.gc_remembered) return;
    h.gc_remembered = false;
    for (remembered.items, 0..) |e, i| {
        if (e == h) {
            _ = remembered.swapRemove(i);
            break;
        }
    }
}

fn isCell(target: *GcHeader, h: *GcHeader) bool {
    return h == target;
}

/// Clear every remembered flag and empty the list. A boundary that frees
/// permanent cells wholesale must call this first: they are never swept.
/// A major in progress needs every window's remembered cells, so it ends.
pub fn drainRemembered() void {
    abortMajor();
    remembered_lock.lock();
    defer remembered_lock.unlock();
    for (remembered.items) |h| h.gc_remembered = false;
    remembered.clearRetainingCapacity();
    clearRanges();
}

/// `KLIO_GC_REMEMBER_TRACE`: report remembered entries whose page is unmapped.
pub fn validateRemembered(tag: []const u8) void {
    if (!rememberTraceOn()) return;
    remembered_lock.lock();
    defer remembered_lock.unlock();
    const pg = std.heap.pageSize();
    var bad: usize = 0;
    for (remembered.items) |h| {
        const base = std.mem.alignBackward(usize, @intFromPtr(h), pg);
        const rc = std.os.linux.msync(@ptrFromInt(base), pg, std.os.linux.MSF.ASYNC);
        if (rc != 0) {
            bad += 1;
            std.debug.print("[gc-validate] {s}: UNMAPPED h={*}\n", .{ tag, h });
        }
    }
    std.debug.print("[gc-validate] {s}: n={d} bad={d}\n", .{ tag, remembered.items.len, bad });
}

/// Collection-trigger floor in bytes (`KLIO_GC_THRESHOLD_KB`, default 8 MB).
/// The next threshold is `max(floor, live * growth)`.
var threshold_floor: usize = 8 * 1024 * 1024;
var freed_since_trim: usize = 0;
var threshold: usize = 8 * 1024 * 1024;

/// Appel growth multiplier, minimum 2. `KLIO_GC_GROWTH` overrides it.
var growth_factor_cache: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
fn growthFactor() usize {
    const cached = growth_factor_cache.load(.monotonic);
    if (cached != 0) return cached;
    var f: usize = 2;
    if (comptime @import("builtin").link_libc) {
        if (std.c.getenv("KLIO_GC_GROWTH")) |raw| {
            f = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 2;
            if (f < 2) f = 2;
        }
    }
    growth_factor_cache.store(f, .monotonic);
    return f;
}
var cur_epoch: usize = 1;
var gc_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn setThresholdFloor(bytes: usize) void {
    threshold_floor = bytes;
    threshold = bytes;
    major_threshold = bytes;
}

/// `KLIO_RECLAIM=gc`. When false, `register` is never called.
pub var gc_enabled: bool = false;

/// True once the program body begins; read only by `KLIO_GC_GUARD`.
pub var program_started: bool = false;

/// While true, `register` links every permanent cell onto the program-perm
/// list for `freeProgramPerm` to release at the run boundary.
pub var program_perm_collect: bool = false;
var program_perm: ?*GcHeader = null;
var program_perm_lock: SpinLock = .{};

/// Free every cell on the program-perm list. Run boundary only, strictly after
/// the final collect and `drainRemembered`.
pub fn freeProgramPerm() void {
    program_perm_lock.lock();
    var cur = program_perm;
    program_perm = null;
    program_perm_lock.unlock();
    var freed: usize = 0;
    while (cur) |h| {
        cur = h.gc_next;
        h.gc_next = null;
        h.gc_finalize(h);
        freed += 1;
    }
    if (gc_debug) std.debug.print("[kgc] program-perm freed={d}\n", .{freed});
}

/// `KLIO_GC_STRESS=1`: collect at every safe point, whatever the threshold.
pub var gc_stress: bool = false;

/// `KLIO_GC_STRESS_EVERY=N`: collect every N safe points; `0` disables.
pub var gc_stress_every: usize = 0;
/// The opcode-boundary poll counters. They are read and written on every
/// instruction, and on Darwin a `threadlocal` access is a call into dyld, so
/// they live off the thread-local block.
const PollCounters = struct { safepoint: usize = 0, idle: usize = 0 };

const poll_tls = tls_fast.PerThread(PollCounters);

inline fn pollCounters() *PollCounters {
    return poll_tls.get();
}

/// Permanent generation. Cells minted while this is true never join the sweep
/// registry: they are immutable and reference only other permanent cells.
/// They stay traceable. `vmRun` clears it before the program body.
pub threadlocal var alloc_perm: bool = true;

pub fn register(h: *GcHeader, bytes: usize) void {
    if (alloc_perm) {
        // Minted tenured so a minor mark stops here instead of walking the
        // image graph, and so mutating it at runtime trips the write barrier.
        h.gc_gen = 1;
        // A permanent cell born holding nursery references is a reachability
        // hole: no barrier records birth edges, so program-phase threads must
        // not mint permanent. `gc_next` is unused for perm cells, so it
        // carries the program-perm list.
        if (program_perm_collect) {
            program_perm_lock.lock();
            h.gc_next = program_perm;
            program_perm = h;
            program_perm_lock.unlock();
        }
        return;
    }
    h.gc_bytes = std.math.lossyCast(u32, bytes);
    reg_lock.lock();
    h.gc_next = nursery;
    nursery = h;
    reg_lock.unlock();
    const prev = bytes_since_gc.fetchAdd(bytes, .monotonic);
    if (prev + bytes >= threshold) gc_pending.store(true, .monotonic);
}

/// Account heap growth the registry cannot see: frame buffers and suspension
/// snapshots are traced through the frame chain, never swept, and must still
/// advance the Appel trigger.
pub fn noteExternalBytes(bytes: usize) void {
    if (!gc_enabled) return;
    const ext = ext_tls.get();
    ext.delta += @as(isize, @intCast(@min(bytes, std.math.maxInt(isize))));
    if (ext.delta >= EXT_FLUSH) flushExternalDelta();
}

/// External bytes released. External buffers are freed explicitly and never
/// swept, so they advance the trigger by net growth only while registry cells
/// stay on gross accounting.
pub fn noteExternalFreed(bytes: usize) void {
    if (!gc_enabled) return;
    const ext = ext_tls.get();
    ext.delta -= @as(isize, @intCast(@min(bytes, std.math.maxInt(isize))));
    if (ext.delta <= -EXT_FLUSH) flushExternalDelta();
}

/// Per-thread net unflushed external bytes: deltas batch thread-locally and
/// reach the shared counters `EXT_FLUSH` bytes at a time. Every arg carrier
/// taken or returned moves it, so it lives off the thread-local block.
const ExtDelta = struct { delta: isize = 0 };
const ext_tls = tls_fast.PerThread(ExtDelta);
const EXT_FLUSH: isize = 256 * 1024;

pub fn flushExternalDelta() void {
    const ext = ext_tls.get();
    const d = ext.delta;
    if (d == 0) return;
    ext.delta = 0;
    if (d > 0) {
        const b: usize = @intCast(d);
        _ = external_live.fetchAdd(b, .monotonic);
        const mprev = bytes_since_major.fetchAdd(b, .monotonic);
        if (mprev +| b >= major_threshold) major_pending.store(true, .monotonic);
        const prev = bytes_since_gc.fetchAdd(b, .monotonic);
        if (prev +| b >= threshold) gc_pending.store(true, .monotonic);
    } else {
        const b: usize = @intCast(-d);
        subSaturating(&external_live, b);
        subSaturating(&bytes_since_gc, b);
        subSaturating(&bytes_since_major, b);
    }
}

/// Subtract without going below zero. The clamp must be part of the same
/// atomic step, or two threads each reading a value that covers their own
/// subtraction both subtract and wrap the counter.
fn subSaturating(c: *std.atomic.Value(usize), bytes: usize) void {
    var cur = c.load(.monotonic);
    while (true) {
        const next = cur -| bytes;
        cur = c.cmpxchgWeak(cur, next, .monotonic, .monotonic) orelse return;
    }
}

var external_live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// `KLIO_GC_EXT=0` disables external-bytes Appel accounting.
pub var external_accounting: bool = true;

/// `pending` for a caller that counts its own polls and runs `idleProbeNow`
/// every 64k of them: one load, no per-thread lookup.
pub inline fn pendingFlag() bool {
    if (gc_stress or gc_stress_every != 0) return pending();
    return gc_pending.load(.monotonic);
}

/// External bytes a caller batched on its own per-thread state, net, applied
/// to the shared counters now.
pub fn noteExternalNet(delta: isize) void {
    if (!gc_enabled or delta == 0) return;
    const ext = ext_tls.get();
    ext.delta += delta;
    flushExternalDelta();
}

/// Cheap poll at opcode-boundary safe points. Every 64k polls it probes for
/// idle reclamation, so a program that bursts and goes quiet still returns its
/// heap to the OS.
pub inline fn pending() bool {
    if (gc_stress) return true;
    const pc = pollCounters();
    if (gc_stress_every != 0) {
        pc.safepoint += 1;
        if (pc.safepoint >= gc_stress_every) return true;
    }
    pc.idle += 1;
    if (pc.idle & 0xFFFF == 0) idleProbe();
    return gc_pending.load(.monotonic);
}

/// Accessors for the transpiled hot path's inlined edge guard. Stress modes
/// are reported so the emitted code takes the full slow path on every edge.
pub fn idleTickPtr() *usize {
    return &pollCounters().idle;
}
pub fn pendingFlagPtr() *const bool {
    return &gc_pending.raw;
}
pub fn stressActive() bool {
    return gc_stress or gc_stress_every != 0;
}
pub fn idleProbeNow() void {
    idleProbe();
}
/// Wall-clock (ms) when the last collection finished; 0 before the first.
var last_collect_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var last_live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
/// True once the quiescent-period collection ran; re-armed by real allocation.
var idle_collected: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
const IDLE_COLLECT_MS: u64 = 1000;

fn idleProbe() void {
    if (gc_pending.load(.monotonic)) return;
    if (idle_collected.load(.monotonic)) return;
    // Registered-cell bytes under-count the real heap, so no size gate is
    // reliable here; the latch bounds the cost to one collection per period.
    const last = last_collect_ms.load(.monotonic);
    if (last == 0) return;
    const now = nowMillis();
    if (now -| last < IDLE_COLLECT_MS) return;
    idle_collected.store(true, .monotonic);
    major_pending.store(true, .monotonic); // idle reclamation wants the full heap back
    gc_pending.store(true, .monotonic);
    if (gc_debug) std.debug.print("[gc] idle collection requested\n", .{});
}

fn nowMillis() u64 {
    const ns = clock_mod.monotonicNanos();
    return @intCast(ns / std.time.ns_per_ms);
}

/// Runs a pending collection from a safe point. With one mutator the caller
/// collects in place; with more, the handshake parks the others here first.
pub fn safePoint() void {
    // Every mark takes each cell's shared lock, so a thread that parks or
    // collects here holding one would stall it.
    assertNoCellLock();
    if (stopRaised()) {
        parkForStop();
        return;
    }
    // The stress counter is the only per-thread state this needs, and stress is
    // disarmed in every ordinary run. Reading it unconditionally cost a
    // per-thread fetch at a point the frameless walker reaches once per block,
    // so the ordinary answer is now two atomic loads and no thread state.
    var sampled = false;
    if (gc_stress_every != 0) {
        const pc = pollCounters();
        sampled = pc.safepoint >= gc_stress_every;
        if (sampled) pc.safepoint = 0;
    }
    if (!gc_stress and !sampled and !gc_pending.load(.monotonic)) return;
    collectImpl(false);
}

// Each subsystem registers a callback that shades every live Value it owns.

pub const RootFn = *const fn (*Marker) void;
var roots: std.ArrayList(RootFn) = .empty;
var roots_lock: SpinLock = .{};

pub fn registerRoot(f: RootFn) void {
    roots_lock.lock();
    defer roots_lock.unlock();
    roots.append(std.heap.page_allocator, f) catch @panic("KGC: root registration failed");
}

/// Keeps the closure side-table's capture store and receiver chain alive for a
/// closure id that marking reached. A closure captured by another needs no
/// second pass: draining the outer captures cell re-invokes this hook.
pub var markClosureHook: ?*const fn (id: u64, m: *Marker) void = null;

/// Reclaims closure side-table slots no live value referenced in `epoch`.
/// Called after the sweep, world still stopped, so the side-table is stable.
pub var sweepClosureHook: ?*const fn (epoch: usize) void = null;

/// Singleton identity of a closure id: non-zero and keyed on (module, body
/// function) when it captures nothing, 0 when it captures. Kotlin makes a
/// non-capturing lambda literal a singleton, so `structuralEq` compares by it.
pub var closureSingletonHook: ?*const fn (id: u64) u64 = null;

/// Writes what a closure id's `toString` answers, for the host's display of
/// a closure; false when the host renders it itself.
pub var closureTextHook: ?*const fn (id: u64, w: *std.Io.Writer) std.Io.Writer.Error!bool = null;

/// Marks the Values reachable from a parked lazy-`sequence{}` continuation, an
/// `ir.eval.SuspendState` box held opaquely because `runtime` cannot import
/// `ir`.
pub var markSuspendHook: ?*const fn (cont: *anyopaque, m: *Marker) void = null;

/// Finalizes an abandoned continuation: a `Builder` source swept before
/// completion still owns its `SuspendState` box.
pub var freeSuspendHook: ?*const fn (cont: *anyopaque, a: std.mem.Allocator) void = null;

// Per-thread roots. Several root sets live in threadlocals, so a global
// `RootFn` would see only the collecting thread's. Each thread registers a
// `ThreadRoot` whose `ctx` is its own threadlocal's stable address, which is
// safe to read cross-thread because that thread is parked during collection.

pub const ThreadRootFn = *const fn (ctx: *anyopaque, m: *Marker) void;
pub const ThreadRoot = struct {
    next: ?*ThreadRoot = null,
    ctx: *anyopaque,
    mark: ThreadRootFn,
    linked: bool = false,
};
var thread_roots: ?*ThreadRoot = null;
var thread_roots_lock: SpinLock = .{};

/// Both `node` and its `ctx` are stable storage owned by that thread.
pub fn registerThreadRoot(node: *ThreadRoot) void {
    thread_roots_lock.lock();
    defer thread_roots_lock.unlock();
    if (node.linked) return;
    node.linked = true;
    node.next = thread_roots;
    thread_roots = node;
}

/// Unlink at thread exit, before its threadlocal storage becomes invalid.
pub fn unregisterThreadRoot(node: *ThreadRoot) void {
    thread_roots_lock.lock();
    defer thread_roots_lock.unlock();
    if (!node.linked) return;
    var pp: *?*ThreadRoot = &thread_roots;
    while (pp.*) |n| {
        if (n == node) {
            pp.* = n.next;
            node.linked = false;
            node.next = null;
            return;
        }
        pp = &n.next;
    }
}

fn markThreadRoots(m: *Marker) void {
    // Held for the whole walk: a concurrent splice would corrupt the list.
    thread_roots_lock.lock();
    defer thread_roots_lock.unlock();
    var cur = thread_roots;
    while (cur) |n| : (cur = n.next) n.mark(n.ctx, m);
}

/// Shades every registered root and every thread's roots.
fn markRoots(m: *Marker) void {
    roots_lock.lock();
    const root_list = roots.items;
    roots_lock.unlock();
    for (root_list) |f| f(m);
    markThreadRoots(m);
}

// Stop-the-world handshake. The collecting thread raises a stop; every other
// mutator parks at its next safe point or is already in a blocking-safe
// region. `gc_lock` keeps collection single-collector.

/// The stop word: the stop's generation in the high 32 bits, the raised bit,
/// and in the low bits how many mutators have parked for that stop. A park is
/// one compare-exchange on the word, so it counts only toward the stop raised
/// when it lands. Kept apart, a thread that read the generation of one stop
/// and added to the count after the next was raised made a count no parked
/// thread stood behind, and the collector marked with that thread running.
var stop_word = std.atomic.Value(u64).init(0);
const stop_raised_bit: u64 = 1 << 31;
const stop_count_mask: u64 = stop_raised_bit - 1;

inline fn stopGenOf(w: u64) u32 {
    return @truncate(w >> 32);
}

inline fn stopRaised() bool {
    return stop_word.load(.seq_cst) & stop_raised_bit != 0;
}

/// Mutators parked for the stop now raised.
fn stoppedCount() usize {
    return @intCast(stop_word.load(.seq_cst) & stop_count_mask);
}

/// The next stop, with nobody counted yet. Caller holds `mutator_lock`.
/// The mutators' poll reads only the pending flag, so it is set too: a stop
/// no allocation asked for, such as the marking thread's remark, is seen at
/// the next poll rather than at the next collection some allocation asks for.
fn raiseStop() void {
    const gen = stopGenOf(stop_word.load(.seq_cst)) +% 1;
    stop_word.store((@as(u64, gen) << 32) | stop_raised_bit, .seq_cst);
    gc_pending.store(true, .monotonic);
}

/// Ends the stop and wakes every thread asleep on it.
fn endStop() void {
    stop_word.store(@as(u64, stopGenOf(stop_word.load(.seq_cst))) << 32, .seq_cst);
    stop_gate.wake();
}

var parked_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Mutators counted parked by a blocking-safe bracket now.
pub fn parkedCount() usize {
    return parked_count.load(.seq_cst);
}

/// Whether fewer than `others` mutators are parked for the stop now raised.
/// A thread leaving a blocking bracket moves from the bracket count to the
/// stop's, so the stop's count is read first: read the other way round, a
/// thread that moved between the two reads counted twice and let the
/// collector mark while another mutator still ran. Read this way it counts
/// once or not at all, and the rendezvous waits for it.
fn rendezvousShort(others: usize) bool {
    const stopped = stoppedCount();
    return stopped + parked_count.load(.seq_cst) < others;
}
var mutators: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var gc_lock: SpinLock = .{};

/// Whether a stop-the-world collection is in progress. A mutator that mutates
/// or frees while it is true is a rendezvous bug.
pub fn worldStopped() bool {
    return world_marking.load(.acquire);
}
/// True from "every other mutator is parked" to the release.
pub var world_marking: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Thread identity at the width this build can hold atomically: a 32-bit
/// target narrows the id, whose low bits stay distinct.
pub const Tid = if (@bitSizeOf(std.Thread.Id) <= @bitSizeOf(usize)) std.Thread.Id else usize;
pub var collector_tid: std.atomic.Value(Tid) = std.atomic.Value(Tid).init(0);
pub inline fn currentTid() Tid {
    return @truncate(std.Thread.getCurrentId());
}
pub var dbg_mutators: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
pub var dbg_parked: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
pub var dbg_collector_park: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub threadlocal var is_mutator: bool = false;

/// Serializes mutator-set membership against the start of a stop, so no thread
/// slips into or out of the set between the snapshot and the rendezvous.
var mutator_lock: SpinLock = .{};

/// Register the caller as a mutator, after its root nodes are linked.
pub fn enterMutator() void {
    while (true) {
        mutator_lock.lock();
        if (!stopRaised()) {
            is_mutator = true;
            _ = mutators.fetchAdd(1, .acq_rel);
            lateRegister();
            mutator_lock.unlock();
            return;
        }
        mutator_lock.unlock();
        // A stop in progress whose snapshot predates this thread.
        waitStopEnd(null);
    }
}

/// Deregister the caller at its exit seam, before its root nodes unlink.
/// Counts as parked across an in-flight collection and waits one out, so the
/// caller can then unlink safely.
pub fn exitMutator() void {
    // Leaving must be atomic against a stop's `others` snapshot: counting the
    // leaver as parked could cover for another mutator still running.
    while (true) {
        mutator_lock.lock();
        if (!stopRaised()) {
            is_mutator = false;
            _ = mutators.fetchSub(1, .acq_rel);
            lateUnregister();
            mutator_lock.unlock();
            return;
        }
        mutator_lock.unlock();
        parkForStop();
    }
}

/// Park for an in-progress collection: count toward it and wait until the
/// collector ends it.
fn parkForStop() void {
    var w = stop_word.load(.seq_cst);
    // Only for a stop actually raised: a thread that lost the `gc_lock` race
    // before the winner raised its stop would otherwise satisfy the rendezvous
    // and run on through the mark.
    if (w & stop_raised_bit == 0) return;
    // The collector never waits on its own stop.
    if (collector_tid.load(.acquire) == currentTid()) return;
    while (w & stop_raised_bit != 0) {
        // Counted toward the stop raised now; a failed exchange saw the word
        // move, and the loop looks again.
        if (stop_word.cmpxchgWeak(w, w + 1, .seq_cst, .seq_cst)) |seen| {
            w = seen;
            continue;
        }
        // The collector may be asleep waiting for this count.
        rendezvous_gate.wake();
        // Wait out this stop. A stop raised again before this thread saw the
        // last one end has a tally without it, so the loop counts it again.
        waitStopEnd(stopGenOf(w));
        w = stop_word.load(.seq_cst);
    }
}

/// Depth of blocking-primitive brackets. Inside one the thread holds no
/// unrooted live Value and makes no progress, so it counts as parked.
pub threadlocal var blocking_safe_depth: u32 = 0;

/// How many nested reasons this thread is parked for. The rendezvous counts
/// threads, so `parked_count` moves only on the 0<->1 edges; a count per reason
/// would let one thread satisfy `parked_count >= others` alone.
pub threadlocal var park_depth: u32 = 0;

// Waiting through the OS. A thread waiting for a stop to end, and the
// collector waiting for the mutators to park, spin a moment, yield a few
// times, and then sleep on a gate; whoever changes what they wait for wakes
// the gate's sleepers. The sleeper count and the state waited on are each
// written before the other is read, all sequentially consistent, so either
// the waiter sees the change or the waker sees the sleeper.

const has_os_wait = builtin.link_libc and !builtin.single_threaded;

const Gate = struct {
    mutex: if (has_os_wait) std.c.pthread_mutex_t else void = if (has_os_wait) .{} else {},
    cond: if (has_os_wait) std.c.pthread_cond_t else void = if (has_os_wait) .{} else {},
    sleepers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Sleeps until `still(arg)` is false.
    fn sleepWhile(self: *Gate, comptime still: fn (usize) bool, arg: usize) void {
        if (comptime !has_os_wait) {
            while (still(arg)) std.Thread.yield() catch std.atomic.spinLoopHint();
            return;
        }
        _ = std.c.pthread_mutex_lock(&self.mutex);
        _ = self.sleepers.fetchAdd(1, .seq_cst);
        while (still(arg)) _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        _ = self.sleepers.fetchSub(1, .seq_cst);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// One load when nobody sleeps.
    fn wake(self: *Gate) void {
        if (comptime !has_os_wait) return;
        if (self.sleepers.load(.seq_cst) == 0) return;
        _ = std.c.pthread_mutex_lock(&self.mutex);
        _ = std.c.pthread_cond_broadcast(&self.cond);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }
};

/// Threads waiting for a stop to end.
var stop_gate: Gate = .{};
/// The collector waiting for the mutators to park.
var rendezvous_gate: Gate = .{};

/// A short stop ends inside the spin, so its waiters never reach the OS.
const spin_rounds = 256;
const yield_rounds = 16;

/// Spins, yields, then sleeps on `gate` while `still(arg)` holds.
fn waitOut(gate: *Gate, comptime still: fn (usize) bool, arg: usize) void {
    var rounds: u32 = 0;
    while (still(arg)) : (rounds += 1) {
        if (rounds < spin_rounds) {
            std.atomic.spinLoopHint();
        } else if (rounds < spin_rounds + yield_rounds) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        } else {
            gate.sleepWhile(still, arg);
            return;
        }
    }
}

/// Whether a stop is raised, and for a nonzero `gen_plus_one` whether it is
/// still that generation's.
fn stopHolds(gen_plus_one: usize) bool {
    const w = stop_word.load(.seq_cst);
    if (w & stop_raised_bit == 0) return false;
    return gen_plus_one == 0 or stopGenOf(w) == @as(u32, @truncate(gen_plus_one - 1));
}

/// Waits until no stop is raised, or, given `gen`, until that stop has
/// ended or another has been raised in its place.
fn waitStopEnd(gen: ?u32) void {
    waitOut(&stop_gate, stopHolds, if (gen) |g| @as(usize, g) + 1 else 0);
}

/// The collector's side of the rendezvous.
fn awaitRendezvous(others: usize) void {
    if (has_late_dump and late_ms != 0) return awaitRendezvousLate(others);
    waitOut(&rendezvous_gate, rendezvousShort, others);
}

// `KLIO_GC_LATE=<ms>`: a rendezvous still short after this long has every
// other mutator print its native stack (`[gc-late]`). A parked thread shows the
// park; a late one shows what it runs without reaching a safe point.

const has_late_dump = builtin.link_libc and !builtin.single_threaded and
    (builtin.os.tag == .macos or builtin.os.tag == .linux);

pub var late_ms: u64 = 0;
const late_cap = 128;
/// The mutators' threads, kept only while `late_ms` is set. Written under
/// `mutator_lock`.
var late_threads: [late_cap]?std.c.pthread_t = @splat(null);
var late_print_lock: SpinLock = .{};
var late_handler_installed: bool = false;

fn lateRegister() void {
    if (comptime !has_late_dump) return;
    if (late_ms == 0) return;
    const me = std.c.pthread_self();
    for (&late_threads) |*slot| {
        if (slot.* == null) {
            slot.* = me;
            return;
        }
    }
}

fn lateUnregister() void {
    if (comptime !has_late_dump) return;
    if (late_ms == 0) return;
    const me = std.c.pthread_self();
    for (&late_threads) |*slot| {
        if (slot.*) |t| if (t == me) {
            slot.* = null;
            return;
        };
    }
}

fn lateHandler(_: std.c.SIG) callconv(.c) void {
    late_print_lock.lock();
    defer late_print_lock.unlock();
    std.debug.print("[gc-late] thread {d} park_depth={d} blocking_safe={d}\n", .{ currentTid(), park_depth, blocking_safe_depth });
    trace.dumpCurrent(.{});
}

/// The rendezvous with the late report: spins and yields while short, and once
/// `late_ms` has passed signals every other registered mutator to print.
fn awaitRendezvousLate(others: usize) void {
    if (comptime !has_late_dump) return;
    if (!late_handler_installed) {
        late_handler_installed = true;
        var act = std.posix.Sigaction{
            .handler = .{ .handler = lateHandler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.USR2, &act, null);
    }
    const t0 = clock_mod.monotonicNanos();
    var reported = false;
    var rounds: u32 = 0;
    while (rendezvousShort(others)) : (rounds +%= 1) {
        if (rounds < spin_rounds) {
            std.atomic.spinLoopHint();
            continue;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
        if (reported or clock_mod.monotonicNanos() - t0 < late_ms * std.time.ns_per_ms) continue;
        reported = true;
        std.debug.print("[gc-late] rendezvous short after {d} ms: {d} of {d} counted ({d} stopped, {d} in brackets)\n", .{
            late_ms, stoppedCount() + parked_count.load(.seq_cst), others, stoppedCount(), parked_count.load(.seq_cst),
        });
        const me = std.c.pthread_self();
        mutator_lock.lock();
        for (late_threads) |slot| {
            const t = slot orelse continue;
            if (t == me) continue;
            _ = std.c.pthread_kill(t, .USR2);
        }
        mutator_lock.unlock();
    }
}

fn parkPublish() void {
    // Only mutators are counted: a parked non-mutator would satisfy the
    // rendezvous one thread early.
    if (!is_mutator) return;
    park_depth += 1;
    if (park_depth == 1) {
        _ = parked_count.fetchAdd(1, .seq_cst);
        // A collector may be asleep waiting for this thread.
        if (stopRaised()) rendezvous_gate.wake();
    }
}

fn parkUnpublish() void {
    if (park_depth == 0) return;
    park_depth -= 1;
    if (park_depth == 0) _ = parked_count.fetchSub(1, .seq_cst);
}

pub fn enterBlockingSafe() void {
    if (!gc_enabled) return;
    // Counted parked from here: a mark may take any cell's shared lock.
    assertNoCellLock();
    blocking_safe_depth += 1;
    parkPublish();
}

/// Wait out an in-progress collection before touching the heap again.
pub fn exitBlockingSafe() void {
    if (!gc_enabled) return;
    // Nothing inside a bracket takes a cell lock.
    assertNoCellLock();
    blocking_safe_depth -|= 1;
    parkUnpublish();
    // Inside an outer bracket the thread is still counted parked.
    if (park_depth != 0) return;
    // Counted as running from the unpublish on. A stop that counted this
    // thread parked may be marking now, and one raised since needs it parked:
    // it waits either out as a stopped thread, never between a check and the
    // unpublish.
    if (is_mutator) parkForStop() else waitStopEnd(null);
}

/// `KLIO_GC_DEBUG`: one `[kgc]` line per collection.
pub var gc_debug: bool = false;
/// `KLIO_GC_NOFREE`: mark fully but never free a white cell, so a crash that
/// disappears here is a premature free.
pub var gc_nofree: bool = false;

/// Called after marking, before the sweep, world still stopped.
pub var audit_hook: ?*const fn (major: bool, epoch: usize) void = null;
/// Diagnostics: called after the sweep, world still stopped.
pub var post_sweep_hook: ?*const fn (major: bool, epoch: usize) void = null;

pub fn cellSweepFate(h: *const GcHeader, major: bool) enum { marked, tenured, white } {
    if (h.gc_mark == sweep_epoch) return .marked;
    if (!major and h.gc_gen != 0) return .tenured;
    return .white;
}

/// `KLIO_GC_POISON`: quarantine white cells instead of freeing them, swapping
/// the tracer to `poisonTrap` so a live reference fires it next collection.
pub var gc_poison: bool = false;
/// Diagnostic context for `[GC-POISON-SHADE]`: the root walk that was marking
/// when a swept cell was shaded.
pub threadlocal var poison_ctx_name: []const u8 = "";
pub threadlocal var poison_ctx_idx: usize = 0;

/// Whether poison mode already swept `h`, so a host walk can probe before
/// dereferencing the payload.
pub fn cellSweptPoisoned(h: *const GcHeader) bool {
    return gc_poison and h.gc_trace == poisonTrap;
}
/// Whether a minor mark stops at tenured cells. `KLIO_GC_MINOR_STOP=0` turns
/// the shortcut off; a full-trace minor still sweeps only the nursery.
pub var minor_stops_at_tenured: bool = true;

/// Reaching this tracer means a live value referenced a swept cell.
pub fn poisonTrap(h: *GcHeader, _: *Marker) void {
    std.debug.print("\n[GC-POISON] live reference to SWEPT cell: type={s}\n", .{h.gc_type});
    trace.dumpCurrent(.{});
    @panic("KGC: use-after-free — a live value referenced a swept cell (incomplete root)");
}

/// A major collection, finished: its sweep is done when this returns.
pub fn collect() void {
    collectImpl(true);
    waitSweep();
}

/// Live cells the last collection kept, for the `KLIO_RUN_STATS` report.
pub fn liveCellsAfterCollect() usize {
    return last_live.load(.monotonic);
}

/// One mark-sweep with the world stopped. `force_major` sweeps the whole graph.
fn collectImpl(force_major: bool) void {
    if (!gc_lock.tryLock()) {
        // A mutator counts toward the stop it finds; any other thread only
        // waits it out.
        if (is_mutator) parkForStop() else waitStopEnd(null);
        return;
    }
    defer gc_lock.unlock();
    // The last collection's sweep still owns the lists it detached.
    waitSweep();
    collector_tid.store(currentTid(), .release);
    defer collector_tid.store(0, .release);
    // The collector's own buffered delta joins the shared counters before the
    // threshold math reads them.
    flushExternalDelta();

    // A major this collection may begin runs on the marking thread, started
    // here while the mutators still run.
    if (major_mode == .concurrent and spanningMajors()) _ = startMarkingThread();

    // Timed only under `KLIO_GC_DEBUG`, which reports each phase.
    const t_raise: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;

    // Stop the world. The snapshot and the raise happen under the membership
    // lock, so `others` and `parked_count` describe the same cohort. The stop
    // is raised with no other mutator too: a thread joining the set while
    // this collection marks or sweeps must wait it out, and `enterMutator`
    // waits only on the flag.
    mutator_lock.lock();
    // The collector stops every mutator but itself, and counts itself only if
    // it is one: a thread collecting from outside the set stops them all.
    const others = mutators.load(.acquire) -| @intFromBool(is_mutator);
    raiseStop();
    mutator_lock.unlock();
    // A thread still asleep on the last stop counts itself for this one.
    stop_gate.wake();
    // Threads in blocking-safe brackets cannot run, so they count parked.
    if (others != 0) awaitRendezvous(others);
    const t_stopped: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
    dbg_collector_park.store(park_depth, .release);
    dbg_mutators.store(mutators.load(.acquire), .release);
    dbg_parked.store(parked_count.load(.acquire), .release);
    world_marking.store(true, .release);
    defer world_marking.store(false, .release);
    // The marking thread lets go of the major between batches, and at the
    // next cell once it sees the stop.
    lockMajorForStop();

    collections_since_major +%= 1;
    const want_major = force_major or !generational or gc_stress or
        major_pending.load(.monotonic) or
        (major_every != 0 and collections_since_major >= major_every);
    const mm = &major_mark;
    const kind: Kind = if (mm.active)
        (if (force_major or mm.drained) .remark else .slice)
    else if (want_major)
        (if (!force_major and spanningMajors()) .initial else .major)
    else
        .minor;
    const major = kind == .major or kind == .remark;
    if (kind == .major or kind == .initial) collections_since_major = 0;

    // A remark finishes the major's own mark; every other kind marks afresh.
    var own: Marker = .{ .epoch = 0, .arena = std.heap.page_allocator };
    defer own.grey.deinit(std.heap.page_allocator);
    const marker: *Marker = if (kind == .remark) &mm.marker else &own;
    if (kind == .remark) {
        mm.marker.between_stops = false;
        mm.stops += 1;
    } else {
        cur_epoch = nextEpoch(cur_epoch);
        own.epoch = cur_epoch;
        own.minor = kind != .major;
        if (kind == .slice) {
            own.promoted_list = &mm.promoted;
            mm.stops += 1;
        }
    }
    sweep_epoch = marker.epoch;

    markRoots(marker);
    // A minor re-traces every remembered cell, whose children may be nursery
    // cells the roots cannot reach. The remark re-traces the ones the major
    // marked, with the cells its minors remembered: each was mutated since
    // the major may have traced it. Traced directly, not shaded.
    const t_roots: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
    var rem: RememberedCounts = .{};
    if (kind != .major) rem = traceRememberedIf(marker, kind == .remark);
    if (kind == .remark) rem.add(retrace(marker, mm.dirty.items, mm.dirty_spans.items, true));
    const t_rem: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
    if (rem_top) {
        if (gc_debug and t_rem - t_roots > std.time.ns_per_ms) remTopReport(marker.epoch, kindName(kind));
        remTopClear();
    }
    const marked = marker.drainCounted();
    const t_marked: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
    if (verifyOn()) {
        if (major) verifyMajorClosed(marker.epoch) else verifyTenured(marker.epoch);
    }
    // Drain the remembered set: after a minor every survivor is tenured, after
    // a major the fresh full mark subsumes it. A major in progress takes the
    // window's cells first. Cleared before the sweep.
    remembered_lock.lock();
    if (rememberTraceOn()) {
        std.debug.print("[gc-drain] n={d} major={} program_started={}\n", .{ remembered.items.len, major, program_started });
        for (remembered.items) |h| std.debug.print("[gc-drain]   h={*}\n", .{h});
    }
    var added: usize = 0;
    if (kind == .slice) added = harvestRemembered();
    for (remembered.items) |h| h.gc_remembered = false;
    remembered.clearRetainingCapacity();
    clearRanges();
    remembered_lock.unlock();

    // The spanning major's share of this stop.
    var sliced: usize = 0;
    switch (kind) {
        .initial => {
            beginMajor();
            // Without a marking thread the major goes on in slices.
            if (major_mode == .concurrent and !wakeMarkingThread()) major_mode = .slices;
        },
        .slice => {
            for (mm.promoted.items) |h| mm.marker.shade(h);
            added += mm.promoted.items.len;
            mm.promoted.clearRetainingCapacity();
            if (major_mode == .slices) {
                const before = mm.traced;
                // At least what this stop added, so the major always gains
                // on what the mutators hand it.
                mm.drained = majorSlice(slice_budget + added, false);
                sliced = mm.traced - before;
            } else if (added != 0) {
                // The marking thread has more to trace before the remark.
                mm.drained = false;
            }
            if (verifyOn()) verifyMajorWindow();
        },
        else => {},
    }
    const t_sliced: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;

    if (audit_hook) |f| f(major, marker.epoch);
    // The counts come from the mark: every nursery cell it reached is tenured
    // already, and every cell it missed is garbage.
    if (major) {
        tenured_count = marker.live;
    } else {
        tenured_count += marker.promoted;
        const mprev = bytes_since_major.fetchAdd(marker.promoted_bytes, .monotonic);
        if (mprev + marker.promoted_bytes >= major_threshold) major_pending.store(true, .monotonic);
    }
    live_bytes = tenured_count; // cell count proxy
    if (major) {
        major_pending.store(false, .monotonic);
        bytes_since_major.store(0, .monotonic);
        major_threshold = @max(threshold_floor, (live_bytes +| external_live.load(.monotonic)) *| growthFactor());
        threshold = if (generational)
            threshold_floor
        else
            @max(threshold_floor, (live_bytes +| external_live.load(.monotonic)) *| growthFactor());
    }
    // Detach what this collection sweeps: the nursery, and a major's tenured
    // list. Cells minted from here on start a fresh nursery.
    reg_lock.lock();
    const job: SweepJob = .{ .nursery = nursery, .tenured = if (major) tenured else null, .epoch = marker.epoch };
    nursery = null;
    if (major) tenured = null;
    reg_lock.unlock();
    // Handed off, the sweep frees while the mutators run; otherwise it
    // finishes here, inside the stop.
    const swept_here = !(sweepOffPause() and postSweep(job));
    const freed: usize = if (swept_here) sweepJob(job) else 0;
    const t_swept: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
    if (post_sweep_hook) |f| f(major, marker.epoch);
    // Major only: a minor mark never re-stamps tenured closures.
    if (major) {
        if (sweepClosureHook) |f| f(marker.epoch);
    }
    const t_closures: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
    const major_stops = mm.stops;
    if (kind == .remark) mm.reset();
    gc_pending.store(false, .monotonic);
    // A collection that saw real allocation re-arms the idle probe.
    if (bytes_since_gc.load(.monotonic) >= threshold_floor / 2) {
        idle_collected.store(false, .monotonic);
    }
    last_live.store(live_bytes, .monotonic);
    last_collect_ms.store(nowMillis(), .monotonic);
    bytes_since_gc.store(0, .monotonic);
    // The stop ends here; the deferred clear covers only early returns.
    world_marking.store(false, .release);
    major_lock.unlock();
    endStop();
    const t_released: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
    if (swept_here) noteFreed(freed);
    // `stop_us` is the rendezvous; `pause_us` runs from the raise to the
    // release, the time every other mutator stood still. A sweep handed to
    // the sweeper reports on its own `[kgc-sweep]` line. `slice` counts the
    // cells a spanning major traced in this stop, `major_stops` the stops it
    // has spanned, and `closures_us` a major's pass over the closure table.
    if (gc_debug) std.debug.print(
        "[kgc] epoch={d} kind={s} marked={d} live={d} freed={d} mark_us={d} sweep_us={d} stop_us={d} pause_us={d} others={d} sweep={s} roots_us={d} rem_us={d} rem_whole={d} rem_spans={d} rem_span_len={d} slice={d} slice_us={d} major_stops={d} closures_us={d}\n",
        .{
            marker.epoch,                  kindName(kind),
            marked,                        live_bytes,
            freed,                         (t_marked - t_stopped) / 1000,
            (t_swept - t_sliced) / 1000,   (t_stopped - t_raise) / 1000,
            (t_released - t_raise) / 1000, others,
            if (swept_here) "pause" else "sweeper", (t_roots - t_stopped) / 1000,
            (t_rem - t_roots) / 1000,      rem.whole,
            rem.spans,                     rem.span_len,
            sliced,                        (t_sliced - t_marked) / 1000,
            if (kind == .minor or kind == .major) 0 else major_stops,
            (t_closures - t_swept) / 1000,
        },
    );
    if (gc_hist) liveTypeHistogram();
}

/// What a collection does. A spanning major's first stop is `initial`, a
/// minor that also shades the roots into it; each later minor is a `slice`;
/// its last stop is the `remark`.
const Kind = enum { minor, major, initial, slice, remark };

/// A minor during a major the marking thread traces does none of the
/// major's tracing, and reports as a minor.
fn kindName(kind: Kind) []const u8 {
    if (kind == .slice and major_mode != .slices) return "minor";
    return @tagName(kind);
}

/// The epoch the collection in progress sweeps by.
var sweep_epoch: usize = 0;

/// Returns swept pages to the OS: the backing allocator holds freed memory in
/// free-lists, so RSS otherwise tracks the allocation high-water.
/// Rate-limited, since trimming every collection is steady mmap traffic.
fn noteFreed(freed: usize) void {
    freed_since_trim +|= freed;
    if (freed_since_trim >= 32 * 1024 * 1024) {
        freed_since_trim = 0;
        if (release_to_os) |f| f();
    }
}

// The sweeper thread. A collection detaches the lists it sweeps, hands them
// here and restarts the world; the next collection, and anything else that
// walks the lists, waits for the sweep first. It is not a mutator: it frees
// only cells the mark left white, which nothing live points to, and relinks
// survivors through `gc_next`, which no mutator reads.

const has_sweeper = builtin.link_libc and !builtin.single_threaded;

/// `KLIO_GC_SWEEP=pause` keeps every sweep inside its collection's stop.
pub var sweep_in_pause: bool = false;

fn sweepOffPause() bool {
    if (comptime !has_sweeper) return false;
    // Each of these reads the lists, or keeps white cells, as the sweep leaves them.
    return !sweep_in_pause and !gc_nofree and !gc_hist and post_sweep_hook == null;
}

const SweepJob = struct {
    nursery: ?*GcHeader,
    /// A major's tenured list; a minor's stays where it is.
    tenured: ?*GcHeader,
    epoch: usize,
};

const Chain = struct {
    head: ?*GcHeader = null,
    tail: ?*GcHeader = null,

    fn push(self: *Chain, h: *GcHeader) void {
        h.gc_next = self.head;
        if (self.head == null) self.tail = h;
        self.head = h;
    }
};

/// Frees the job's white cells and links its survivors into the tenured list.
/// A nursery cell survives by its generation, since the mark that reached it
/// tenured it and a spanning major may have marked it since; a tenured cell
/// by its mark.
fn sweepJob(job: SweepJob) usize {
    var kept: Chain = .{};
    var freed = sweepChain(job.nursery, null, &kept);
    freed += sweepChain(job.tenured, job.epoch, &kept);
    if (kept.tail) |t| {
        reg_lock.lock();
        defer reg_lock.unlock();
        t.gc_next = tenured;
        tenured = kept.head;
    }
    return freed;
}

fn sweepChain(head: ?*GcHeader, epoch: ?usize, kept: *Chain) usize {
    var freed: usize = 0;
    var cur = head;
    while (cur) |h| {
        const next = h.gc_next;
        const live = if (epoch) |e| h.gc_mark == e else h.gc_gen != 0;
        if (live) {
            kept.push(h);
        } else if (gc_nofree) {
            // Kept white, it tenures with the marked cells.
            h.gc_gen = 1;
            kept.push(h);
        } else {
            h.gc_finalize(h);
            freed += 1;
        }
        cur = next;
    }
    return freed;
}

const SweepSync = if (has_sweeper) struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},

    fn lock(self: *@This()) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *@This()) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }
    fn wait(self: *@This()) void {
        _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
    }
    fn broadcast(self: *@This()) void {
        _ = std.c.pthread_cond_broadcast(&self.cond);
    }
} else struct {
    fn lock(_: *@This()) void {}
    fn unlock(_: *@This()) void {}
    fn wait(_: *@This()) void {}
    fn broadcast(_: *@This()) void {}
};

var sweep_sync: SweepSync = .{};
var sweep_job: ?SweepJob = null;
/// Set as a job is handed off, cleared once its sweep has finished.
var sweep_pending = std.atomic.Value(bool).init(false);
/// While nonzero, a collection sweeps inside its own stop.
var sweep_holds: usize = 0;
var sweeper_started = false;
/// Tests hold a handed-off job back, to look at the world between the
/// release and the sweep.
var sweep_gate = std.atomic.Value(bool).init(false);

fn sweeperMain() void {
    while (true) {
        sweep_sync.lock();
        while (sweep_job == null) sweep_sync.wait();
        const job = sweep_job.?;
        sweep_job = null;
        sweep_sync.unlock();
        while (sweep_gate.load(.acquire)) std.Thread.yield() catch {};
        const t0: u64 = if (gc_debug) clock_mod.monotonicNanos() else 0;
        const freed = sweepJob(job);
        // Cells freed here wait in this thread's magazines until flushed, and
        // the heap they came from may be released before the next job.
        slab.flushMagazines();
        flushExternalDelta();
        noteFreed(freed);
        if (gc_debug) std.debug.print("[kgc-sweep] epoch={d} freed={d} sweep_us={d}\n", .{ job.epoch, freed, (clock_mod.monotonicNanos() - t0) / 1000 });
        sweep_sync.lock();
        sweep_pending.store(false, .release);
        sweep_sync.broadcast();
        sweep_sync.unlock();
    }
}

/// Hands `job` to the sweeper. False when sweeps are held inside the stop or
/// no sweeper thread could start; the caller then sweeps it.
fn postSweep(job: SweepJob) bool {
    sweep_sync.lock();
    defer sweep_sync.unlock();
    if (sweep_holds != 0) return false;
    if (!sweeper_started) {
        const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, sweeperMain, .{}) catch return false;
        t.detach();
        sweeper_started = true;
        installForkHandler();
    }
    sweep_job = job;
    sweep_pending.store(true, .release);
    sweep_sync.broadcast();
    return true;
}

var fork_handler_installed = std.atomic.Value(bool).init(false);

fn installForkHandler() void {
    if (fork_handler_installed.swap(true, .acq_rel)) return;
    _ = std.c.pthread_atfork(null, null, threadsGoneInChild);
}

/// A forked child has neither the sweeper nor the marking thread, and
/// starts its own on its first hand-off. A sweep in flight at the fork stays
/// unswept there, so its cells leak in the child and none is freed early;
/// a major in progress is dropped, which frees nothing.
fn threadsGoneInChild() callconv(.c) void {
    sweep_sync = .{};
    sweep_job = null;
    sweep_pending.store(false, .monotonic);
    sweeper_started = false;
    marking_thread.sync = .{};
    marking_thread.wanted = false;
    marking_thread.started = false;
    major_lock = .{};
    major_mark.reset();
}

/// Returns once no handed-off sweep is in flight: one load when none is.
pub fn waitSweep() void {
    if (!sweep_pending.load(.acquire)) return;
    sweep_sync.lock();
    defer sweep_sync.unlock();
    while (sweep_pending.load(.acquire)) sweep_sync.wait();
}

/// Keeps every later sweep inside its collection's stop and waits out the
/// one in flight, for a caller about to unmap memory the lists may name.
/// Pair with `releaseSweeper`.
pub fn holdSweeper() void {
    sweep_sync.lock();
    defer sweep_sync.unlock();
    sweep_holds += 1;
    while (sweep_pending.load(.acquire)) sweep_sync.wait();
}

pub fn releaseSweeper() void {
    sweep_sync.lock();
    defer sweep_sync.unlock();
    sweep_holds -= 1;
}

var verify_init: bool = false;
var verify_on: bool = false;
fn verifyOn() bool {
    if (!verify_init) {
        verify_on = std.c.getenv("KLIO_GC_VERIFY") != null;
        verify_init = true;
    }
    return verify_on;
}
var verify_reports: usize = 0;

/// Names what holds an unrecorded edge (a class and field), set by the
/// runtime module that knows the payload types.
pub var verify_describe: ?*const fn (from: *GcHeader, to: *GcHeader) void = null;

fn verifyReport(from: *GcHeader, to: *GcHeader) void {
    verify_reports += 1;
    if (verify_reports > 20) return;
    std.debug.print("[gc-verify] tenured {s} ({*}, remembered={}) -> unmarked nursery {s} ({*})\n", .{ from.gc_type, from, from.gc_remembered, to.gc_type, to });
    if (verify_describe) |f| f(from, to);
    if (verify_reports == 1) trace.dumpCurrent(.{});
}

/// After a minor mark: every tenured cell's children that are nursery
/// cells must be marked, or a store into it skipped the write barrier. A
/// tenured cell that is already unreachable is walked too, so its stale
/// edges report as well.
fn verifyTenured(epoch: usize) void {
    var cur = tenured;
    while (cur) |t| : (cur = t.gc_next) {
        var vm: Marker = .{ .epoch = epoch, .arena = std.heap.page_allocator, .verify_from = t };
        t.gc_trace(t, &vm);
    }
}

fn verifyReportMajor(from: *GcHeader, to: *GcHeader) void {
    verify_reports += 1;
    if (verify_reports > 20) return;
    std.debug.print("[gc-verify] major: marked {s} ({*}, gen={d}) -> unmarked {s} ({*}, gen={d})\n", .{ from.gc_type, from, from.gc_gen, to.gc_type, to, to.gc_gen });
    if (verify_describe) |f| f(from, to);
    if (verify_reports == 1) trace.dumpCurrent(.{});
}

/// Traces every cell on the lists marked in `epoch` and not in `exempt`,
/// reporting each child left unmarked.
fn verifyMarkedClosed(epoch: usize, exempt: ?*const std.AutoHashMapUnmanaged(*GcHeader, void)) void {
    for ([2]?*GcHeader{ tenured, nursery }) |head| {
        var cur = head;
        while (cur) |c| : (cur = c.gc_next) {
            if (c.gc_mark != epoch) continue;
            if (exempt) |set| if (set.contains(c)) continue;
            var vm: Marker = .{ .epoch = epoch, .arena = std.heap.page_allocator, .verify_from = c, .verify_major = true };
            c.gc_trace(c, &vm);
        }
    }
}

/// After a major's last mark: every cell it marked holds only marked cells,
/// so nothing the sweep frees is reachable from what it keeps.
fn verifyMajorClosed(epoch: usize) void {
    verifyMarkedClosed(epoch, null);
}

/// After a slice of a spanning major, world stopped: a cell the major
/// marked and not retracing later (not grey, not remembered by a minor
/// since) holds only marked cells. A store into a traced cell that no
/// barrier recorded, or a child a tracer skipped, breaks it.
fn verifyMajorWindow() void {
    const mm = &major_mark;
    var exempt: std.AutoHashMapUnmanaged(*GcHeader, void) = .empty;
    defer exempt.deinit(std.heap.page_allocator);
    const a = std.heap.page_allocator;
    for (mm.marker.grey.items) |h| exempt.put(a, h, {}) catch @panic("KGC: verify allocation failed");
    for (mm.dirty.items) |h| exempt.put(a, h, {}) catch @panic("KGC: verify allocation failed");
    for (mm.dirty_spans.items) |sp| exempt.put(a, sp.h, {}) catch @panic("KGC: verify allocation failed");
    verifyMarkedClosed(mm.marker.epoch, &exempt);
}

/// Top live-cell payload types by count, bucketed on `gc_type` pointer
/// identity. Walks the registry under the sweep's lock.
fn liveTypeHistogram() void {
    const Bucket = struct { name: [*:0]const u8, count: usize };
    var buckets: [128]Bucket = undefined;
    var n: usize = 0;
    reg_lock.lock();
    for ([2]?*GcHeader{ nursery, tenured }) |head| {
        var cur = head;
        while (cur) |h| : (cur = h.gc_next) {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (buckets[i].name == h.gc_type) {
                    buckets[i].count += 1;
                    break;
                }
            }
            if (i == n and n < buckets.len) {
                buckets[n] = .{ .name = h.gc_type, .count = 1 };
                n += 1;
            }
        }
    }
    reg_lock.unlock();
    var shown: usize = 0;
    while (shown < 16) : (shown += 1) {
        var best: usize = buckets.len;
        var best_count: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (buckets[i].count > best_count) {
                best_count = buckets[i].count;
                best = i;
            }
        }
        if (best == buckets.len) break;
        std.debug.print("[kgc-hist] {d} x {s}\n", .{ buckets[best].count, buckets[best].name });
        buckets[best].count = 0;
    }
}

/// Platform trim hook, such as `malloc_zone_pressure_relief`. Null means none.
pub var release_to_os: ?*const fn () void = null;

test "minor mark stops at tenured cells; major stamps them" {
    const T = struct {
        fn trace(_: *GcHeader, _: *Marker) void {}
        fn fin(_: *GcHeader) void {}
    };
    const prev_stop = minor_stops_at_tenured;
    minor_stops_at_tenured = true;
    defer minor_stops_at_tenured = prev_stop;
    var a: GcHeader = .{ .gc_trace = T.trace, .gc_finalize = T.fin, .gc_gen = 1 };
    var minor: Marker = .{ .epoch = 3, .arena = std.testing.allocator, .minor = true };
    defer minor.grey.deinit(std.testing.allocator);
    minor.shade(&a);
    try std.testing.expectEqual(@as(usize, 0), minor.grey.items.len);
    try std.testing.expectEqual(@as(usize, 0), a.gc_mark); // untouched by a minor
    var major: Marker = .{ .epoch = 3, .arena = std.testing.allocator };
    defer major.grey.deinit(std.testing.allocator);
    major.shade(&a);
    try std.testing.expectEqual(@as(usize, 1), major.grey.items.len);
    try std.testing.expectEqual(@as(usize, 3), a.gc_mark);
}

test "a remembered cell's tracer may run the write barrier during a minor mark" {
    const T = struct {
        var other: GcHeader = .{ .gc_trace = idle, .gc_finalize = fin, .gc_gen = 1 };
        fn idle(_: *GcHeader, _: *Marker) void {}
        fn fin(_: *GcHeader) void {}
        fn barrierTrace(_: *GcHeader, _: *Marker) void {
            writeBarrier(&other);
        }
    };
    var cell: GcHeader = .{ .gc_trace = T.barrierTrace, .gc_finalize = T.fin, .gc_gen = 1 };
    writeBarrier(&cell);
    try std.testing.expect(cell.gc_remembered);
    var marker = Marker{ .epoch = 1, .arena = std.heap.page_allocator, .minor = true };
    defer marker.grey.deinit(std.heap.page_allocator);
    _ = traceRemembered(&marker);
    try std.testing.expect(T.other.gc_remembered);
    remembered_lock.lock();
    remembered.clearRetainingCapacity();
    cell.gc_remembered = false;
    T.other.gc_remembered = false;
    remembered_lock.unlock();
}

test "write barrier records a tenured cell once and skips nursery cells" {
    const T = struct {
        fn trace(_: *GcHeader, _: *Marker) void {}
        fn fin(_: *GcHeader) void {}
    };
    var young: GcHeader = .{ .gc_trace = T.trace, .gc_finalize = T.fin };
    writeBarrier(&young);
    try std.testing.expect(!young.gc_remembered);
    var old: GcHeader = .{ .gc_trace = T.trace, .gc_finalize = T.fin, .gc_gen = 1 };
    writeBarrier(&old);
    try std.testing.expect(old.gc_remembered);
    const n = remembered.items.len;
    writeBarrier(&old); // second store: already remembered, no duplicate entry
    try std.testing.expectEqual(n, remembered.items.len);
    remembered_lock.lock();
    remembered.clearRetainingCapacity();
    old.gc_remembered = false;
    remembered_lock.unlock();
}

/// Raises a stop as `collectImpl` does, for the handshake tests.
fn testRaiseStop() void {
    mutator_lock.lock();
    raiseStop();
    mutator_lock.unlock();
    stop_gate.wake();
}

fn testSleepMs(ms: u32) void {
    const ts = std.c.timespec{ .sec = 0, .nsec = @as(c_long, ms) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// Waits up to two seconds for `pred`.
fn testWaitFor(comptime pred: fn () bool) bool {
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        if (pred()) return true;
        testSleepMs(1);
    }
    return pred();
}

test "a thread parked for a stop counts itself for the next one raised before it saw the first end" {
    const prev = gc_enabled;
    gc_enabled = true;
    defer gc_enabled = prev;
    const T = struct {
        var ready = std.atomic.Value(bool).init(false);
        fn run() void {
            enterMutator();
            ready.store(true, .release);
            while (!stopRaised()) std.atomic.spinLoopHint();
            parkForStop();
            exitMutator();
        }
        fn isReady() bool {
            return ready.load(.acquire);
        }
        fn oneStopped() bool {
            return stoppedCount() == 1;
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{});
    try std.testing.expect(testWaitFor(T.isReady));
    testRaiseStop();
    try std.testing.expect(testWaitFor(T.oneStopped));
    // The stop ends and the next is raised before the parked thread looks.
    testRaiseStop();
    const counted = testWaitFor(T.oneStopped);
    endStop();
    t.join();
    try std.testing.expect(counted);
}

test "a thread leaving a blocking bracket during a stop stays counted and waits it out" {
    const prev = gc_enabled;
    gc_enabled = true;
    defer gc_enabled = prev;
    const T = struct {
        var parked = std.atomic.Value(bool).init(false);
        var go = std.atomic.Value(bool).init(false);
        var left = std.atomic.Value(bool).init(false);
        fn run() void {
            enterMutator();
            enterBlockingSafe();
            parked.store(true, .release);
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            exitBlockingSafe();
            left.store(true, .release);
            exitMutator();
        }
        fn isParked() bool {
            return parked.load(.acquire);
        }
        fn hasLeft() bool {
            return left.load(.acquire);
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{});
    try std.testing.expect(testWaitFor(T.isParked));
    testRaiseStop();
    try std.testing.expectEqual(@as(usize, 1), parked_count.load(.acquire) + stoppedCount());
    T.go.store(true, .release);
    testSleepMs(20);
    const ran_during_stop = T.left.load(.acquire);
    const counted = parked_count.load(.acquire) + stoppedCount();
    endStop();
    try std.testing.expect(testWaitFor(T.hasLeft));
    t.join();
    try std.testing.expect(!ran_during_stop);
    try std.testing.expectEqual(@as(usize, 1), counted);
    try std.testing.expectEqual(@as(usize, 0), parked_count.load(.acquire));
}

test "marker shades, drains, and stops at fixpoint without recursion" {
    const T = struct {
        var traced: usize = 0;
        fn trace(_: *GcHeader, _: *Marker) void {
            traced += 1;
        }
        fn fin(_: *GcHeader) void {}
    };
    var a: GcHeader = .{ .gc_trace = T.trace, .gc_finalize = T.fin };
    var m: Marker = .{ .epoch = 7, .arena = std.testing.allocator };
    defer m.grey.deinit(std.testing.allocator);
    m.shade(&a);
    m.shade(&a); // idempotent
    try std.testing.expectEqual(@as(usize, 1), m.grey.items.len);
    m.drain();
    try std.testing.expectEqual(@as(usize, 7), a.gc_mark);
    try std.testing.expectEqual(@as(usize, 1), T.traced);
}

test "a thread joining the mutator set during a collection with no other mutator waits it out" {
    const S = struct {
        var armed = std.atomic.Value(bool).init(false);
        var entering = std.atomic.Value(bool).init(false);
        var entered = std.atomic.Value(bool).init(false);
        var entered_during = std.atomic.Value(bool).init(false);
        var go = std.atomic.Value(bool).init(false);
        fn root(_: *Marker) void {
            if (!armed.load(.acquire)) return;
            // The other thread starts joining only now, with this collection's
            // stop raised, and the collection is held open to watch whether it
            // gets in before the collection ends.
            go.store(true, .release);
            while (!entering.load(.acquire)) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < 2_000_000) : (i += 1) {
                if (entered.load(.acquire)) {
                    entered_during.store(true, .release);
                    return;
                }
                std.atomic.spinLoopHint();
            }
        }
        fn joiner() void {
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            entering.store(true, .release);
            enterMutator();
            entered.store(true, .release);
            exitMutator();
        }
    };
    registerRoot(S.root);
    S.armed.store(true, .release);
    defer S.armed.store(false, .release);
    enterMutator();
    const t = try std.Thread.spawn(.{}, S.joiner, .{});
    collect();
    exitMutator();
    t.join();
    try std.testing.expect(S.entered.load(.acquire));
    try std.testing.expect(!S.entered_during.load(.acquire));
}

/// Cells for the sweep tests: registered on the nursery, never reached by a
/// root unless one shades them, and counted as they are finalized.
const SweepTestCells = struct {
    var cells: [4]GcHeader = @splat(.{ .gc_trace = idle, .gc_finalize = fin });
    var finalized = std.atomic.Value(usize).init(0);
    var fin_tid = std.atomic.Value(Tid).init(0);
    var rooted = std.atomic.Value(?*GcHeader).init(null);

    fn idle(_: *GcHeader, _: *Marker) void {}
    fn fin(h: *GcHeader) void {
        h.* = .{ .gc_trace = idle, .gc_finalize = fin };
        fin_tid.store(currentTid(), .release);
        _ = finalized.fetchAdd(1, .acq_rel);
    }
    fn root(m: *Marker) void {
        if (rooted.load(.acquire)) |h| m.shade(h);
    }
    var root_registered = false;

    /// Registers every cell on the nursery; `keep` is shaded by a root.
    fn arm(keep: ?*GcHeader) void {
        if (!root_registered) {
            registerRoot(root);
            root_registered = true;
        }
        finalized.store(0, .release);
        fin_tid.store(0, .release);
        rooted.store(keep, .release);
        alloc_perm = false;
        for (&cells) |*h| register(h, 64);
        major_pending.store(false, .monotonic);
    }

    /// Frees whatever the test left tenured.
    fn disarm() void {
        rooted.store(null, .release);
        collect();
        alloc_perm = true;
    }
};

test "a collection's survivors are tenured before its sweep, which runs after the stop on the sweeper" {
    if (comptime !has_sweeper) return error.SkipZigTest;
    const C = SweepTestCells;
    const keep = &C.cells[0];
    C.arm(keep);
    defer C.disarm();
    sweep_gate.store(true, .release);
    defer sweep_gate.store(false, .release);
    collectImpl(false);
    // The world has restarted and the sweep has not begun.
    try std.testing.expect(!stopRaised());
    try std.testing.expect(sweep_pending.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), C.finalized.load(.acquire));
    try std.testing.expectEqual(@as(u8, 1), keep.gc_gen);
    // A store into the survivor now is remembered for the next minor.
    writeBarrier(keep);
    try std.testing.expect(keep.gc_remembered);
    sweep_gate.store(false, .release);
    waitSweep();
    try std.testing.expectEqual(@as(usize, 3), C.finalized.load(.acquire));
    try std.testing.expect(C.fin_tid.load(.acquire) != currentTid());
    try std.testing.expectEqual(@as(usize, cur_epoch), keep.gc_mark);
}

test "a collection waits for the sweep in flight before it marks" {
    if (comptime !has_sweeper) return error.SkipZigTest;
    const C = SweepTestCells;
    C.arm(null);
    defer C.disarm();
    const S = struct {
        var done = std.atomic.Value(bool).init(false);
        fn second() void {
            collectImpl(false);
            done.store(true, .release);
        }
    };
    sweep_gate.store(true, .release);
    defer sweep_gate.store(false, .release);
    collectImpl(false);
    const t = try std.Thread.spawn(.{}, S.second, .{});
    testSleepMs(20);
    try std.testing.expect(!S.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), C.finalized.load(.acquire));
    sweep_gate.store(false, .release);
    t.join();
    try std.testing.expect(S.done.load(.acquire));
    waitSweep();
    try std.testing.expectEqual(@as(usize, 4), C.finalized.load(.acquire));
}

test "a held sweeper leaves each sweep inside its collection's stop" {
    const C = SweepTestCells;
    C.arm(null);
    defer C.disarm();
    holdSweeper();
    defer releaseSweeper();
    collectImpl(false);
    try std.testing.expect(!sweep_pending.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), C.finalized.load(.acquire));
    try std.testing.expectEqual(currentTid(), C.fin_tid.load(.acquire));
}

/// Cells with two edges each for the spanning-major tests: registered on the
/// nursery, reachable from a root the test sets, and recorded as finalized.
/// Each test runs under `KLIO_GC_VERIFY` and counts its reports.
const GraphCells = struct {
    const Cell = struct {
        hdr: GcHeader = .{ .gc_trace = traceKids, .gc_finalize = fin },
        kids: [2]?*GcHeader = .{ null, null },
    };
    var cells: [6]Cell = @splat(.{});
    var freed: [6]bool = @splat(false);
    var root: ?*GcHeader = null;
    var root_registered = false;
    var saved_mode: MajorMode = .stop;
    var saved_budget: usize = 0;
    var saved_verify: [2]bool = .{ false, false };
    var reports_before: usize = 0;

    fn traceKids(h: *GcHeader, m: *Marker) void {
        const c: *Cell = @fieldParentPtr("hdr", h);
        for (c.kids) |k| if (k) |x| m.shade(x);
    }
    fn fin(h: *GcHeader) void {
        const c: *Cell = @fieldParentPtr("hdr", h);
        const i = (@intFromPtr(c) - @intFromPtr(&cells[0])) / @sizeOf(Cell);
        freed[i] = true;
        c.* = .{};
    }
    fn rootFn(m: *Marker) void {
        if (root) |r| m.shade(r);
    }
    fn hdr(i: usize) *GcHeader {
        return &cells[i].hdr;
    }
    /// A mutator's store: the barrier, then the edge.
    fn store(from: usize, slot: usize, to: ?usize) void {
        writeBarrier(hdr(from));
        cells[from].kids[slot] = if (to) |t| hdr(t) else null;
    }
    fn born(i: usize) void {
        cells[i] = .{};
        alloc_perm = false;
        register(hdr(i), 64);
    }
    fn reports() usize {
        return verify_reports - reports_before;
    }

    /// Links 0 -> 1 -> 2 under a root on 0 and tenures them with a minor;
    /// spanning majors then trace one cell a slice.
    fn arm() void {
        if (!root_registered) {
            registerRoot(rootFn);
            root_registered = true;
        }
        saved_verify = .{ verify_init, verify_on };
        verify_init = true;
        verify_on = true;
        reports_before = verify_reports;
        freed = @splat(false);
        for (0..3) |i| born(i);
        cells[0].kids[0] = hdr(1);
        cells[1].kids[0] = hdr(2);
        root = hdr(0);
        major_pending.store(false, .monotonic);
        collectImpl(false);
        waitSweep();
        saved_mode = major_mode;
        saved_budget = slice_budget;
        major_mode = .slices;
        slice_budget = 1;
    }

    /// Begins a spanning major and traces one slice: 0 is traced and its
    /// child 1 is grey, while 2, under 1, is untraced.
    fn beginAndSlice() void {
        major_pending.store(true, .monotonic);
        collectImpl(false);
        waitSweep();
        std.debug.assert(major_mark.active);
        collectImpl(false);
        waitSweep();
    }

    /// Runs collections until the major ends.
    fn finish() void {
        var n: usize = 0;
        while (major_mark.active and n < 64) : (n += 1) {
            collectImpl(false);
            waitSweep();
        }
        std.debug.assert(!major_mark.active);
    }

    fn disarm() void {
        root = null;
        // A major still running keeps what it marked; the second collect
        // frees it.
        collect();
        collect();
        major_mode = saved_mode;
        slice_budget = saved_budget;
        verify_init = saved_verify[0];
        verify_on = saved_verify[1];
        verify_reports = reports_before;
        alloc_perm = true;
    }
};

test "a spanning major finds a reference moved into a cell it already traced" {
    const G = GraphCells;
    G.arm();
    defer G.disarm();
    G.beginAndSlice();
    try std.testing.expectEqual(major_mark.marker.epoch, G.hdr(0).gc_mark);
    try std.testing.expect(G.hdr(2).gc_mark != major_mark.marker.epoch);
    // The only path to 2 moves into 0, which the major will not trace
    // again unless the barrier's record of the store reaches it.
    G.store(0, 1, 2);
    G.store(1, 0, null);
    G.finish();
    try std.testing.expect(!G.freed[0] and !G.freed[1] and !G.freed[2]);
    try std.testing.expectEqual(@as(usize, 0), G.reports());
}

test "a cell born during a spanning major holds the only path to one the major has not traced" {
    const G = GraphCells;
    G.arm();
    defer G.disarm();
    G.beginAndSlice();
    // A newborn 3 takes the only path to 2, and the traced 0 takes 3. The
    // remark reaches 3 from 0, remembered for the store, and 2 through it.
    G.born(3);
    G.cells[3].kids[0] = G.hdr(2);
    G.store(0, 1, 3);
    G.store(1, 0, null);
    collectImpl(true);
    waitSweep();
    try std.testing.expect(!major_mark.active);
    try std.testing.expect(!G.freed[3] and !G.freed[2]);
    try std.testing.expectEqual(@as(usize, 0), G.reports());
}

test "a survivor a minor promotes during a spanning major outlives the minor's sweep" {
    const G = GraphCells;
    G.arm();
    defer G.disarm();
    G.beginAndSlice();
    G.born(3);
    G.cells[3].kids[0] = G.hdr(2);
    G.store(0, 1, 3);
    G.store(1, 0, null);
    // The next minor promotes 3 and the major shades it with its own epoch
    // before the minor's sweep runs: the sweep keeps it by generation.
    collectImpl(false);
    waitSweep();
    try std.testing.expect(major_mark.active);
    try std.testing.expectEqual(major_mark.marker.epoch, G.hdr(3).gc_mark);
    try std.testing.expect(!G.freed[3]);
    G.finish();
    try std.testing.expect(!G.freed[3] and !G.freed[2]);
    try std.testing.expectEqual(@as(usize, 0), G.reports());
}

test "a cell freed by hand during a spanning major leaves the major's lists" {
    const G = GraphCells;
    const S = struct {
        var traced_after_free = false;
        fn trap(_: *GcHeader, _: *Marker) void {
            traced_after_free = true;
        }
    };
    G.arm();
    defer G.disarm();
    // 5 is off the registry and tenured, as a cache cell freed by hand is.
    G.cells[5] = .{};
    G.hdr(5).gc_gen = 1;
    G.store(1, 1, 5);
    G.beginAndSlice();
    collectImpl(false);
    waitSweep();
    // 1 is traced now, and 5 is grey.
    try std.testing.expectEqual(major_mark.marker.epoch, G.hdr(5).gc_mark);
    G.store(1, 1, null);
    forgetCell(G.hdr(5));
    G.hdr(5).gc_trace = S.trap;
    collectImpl(true);
    waitSweep();
    G.cells[5] = .{};
    try std.testing.expect(!S.traced_after_free);
}

test "the major verifier reports a store into a traced cell that no barrier recorded" {
    const G = GraphCells;
    G.arm();
    defer G.disarm();
    G.beginAndSlice();
    // 0 takes 2 behind the barrier's back while 1, recorded, lets go of it:
    // the next slice finds 0 marked, not due a retrace, and holding an
    // unmarked cell.
    G.cells[0].kids[1] = G.hdr(2);
    G.store(1, 0, null);
    collectImpl(false);
    waitSweep();
    try std.testing.expect(G.reports() != 0);
    G.cells[0].kids[1] = null;
    G.finish();
}

/// The spanning-major cells with the marking thread tracing the major one
/// cell a batch, each batch granted by the test.
const ConcurrentCells = struct {
    var saved_batch: usize = 0;

    fn arm() void {
        GraphCells.arm();
        major_mode = .concurrent;
        saved_batch = marker_batch;
        marker_batch = 1;
        marking_thread.steps.store(0, .release);
    }

    fn disarm() void {
        runFree();
        _ = testWaitFor(majorEnded);
        marker_batch = saved_batch;
        GraphCells.disarm();
    }

    /// Begins a major; the marking thread takes it up and waits for a step.
    fn begin() void {
        major_pending.store(true, .monotonic);
        collectImpl(false);
        waitSweep();
        std.debug.assert(major_mark.active);
    }

    /// Lets the marking thread trace `n` batches and waits until it has.
    fn step(n: usize) void {
        const before = marking_thread.batches.load(.acquire);
        marking_thread.steps.store(@intCast(n), .release);
        while (marking_thread.batches.load(.acquire) < before + n) std.Thread.yield() catch {};
    }

    fn runFree() void {
        marking_thread.steps.store(-1, .release);
    }

    fn majorEnded() bool {
        major_lock.lock();
        defer major_lock.unlock();
        return !major_mark.active;
    }
};

test "the marking thread ends a major with no collection from the mutators" {
    if (comptime !has_marking_thread) return error.SkipZigTest;
    const G = GraphCells;
    const C = ConcurrentCells;
    C.arm();
    defer C.disarm();
    C.begin();
    C.runFree();
    // It traces the three cells and runs the remark itself.
    try std.testing.expect(testWaitFor(C.majorEnded));
    waitSweep();
    try std.testing.expect(!G.freed[0] and !G.freed[1] and !G.freed[2]);
    try std.testing.expectEqual(@as(usize, 0), G.reports());
}

test "the marking thread's remark finds a reference moved into a cell it already traced" {
    if (comptime !has_marking_thread) return error.SkipZigTest;
    const G = GraphCells;
    const C = ConcurrentCells;
    C.arm();
    defer C.disarm();
    C.begin();
    C.step(1);
    // 0 is traced and 1 grey. The only path to 2 moves into 0 while no
    // minor runs, so only the remark's retrace of the remembered set finds it.
    try std.testing.expectEqual(major_mark.marker.epoch, G.hdr(0).gc_mark);
    G.store(0, 1, 2);
    G.store(1, 0, null);
    C.runFree();
    try std.testing.expect(testWaitFor(C.majorEnded));
    waitSweep();
    try std.testing.expect(!G.freed[2]);
    try std.testing.expectEqual(@as(usize, 0), G.reports());
}

test "a minor during a concurrent major hands its remembered cells to the marking thread" {
    if (comptime !has_marking_thread) return error.SkipZigTest;
    const G = GraphCells;
    const C = ConcurrentCells;
    C.arm();
    defer C.disarm();
    C.begin();
    C.step(1);
    G.store(0, 1, 2);
    G.store(1, 0, null);
    // The minor closes the window that remembered 0; the marking thread
    // must retrace 0 from what the minor handed it.
    collectImpl(false);
    waitSweep();
    try std.testing.expect(major_mark.active);
    C.runFree();
    try std.testing.expect(testWaitFor(C.majorEnded));
    waitSweep();
    try std.testing.expect(!G.freed[2]);
    try std.testing.expectEqual(@as(usize, 0), G.reports());
}

test "a stop waits for the marking thread's batch before it touches the major" {
    if (comptime !has_marking_thread) return error.SkipZigTest;
    const G = GraphCells;
    const C = ConcurrentCells;
    const S = struct {
        var inside = std.atomic.Value(bool).init(false);
        var release = std.atomic.Value(bool).init(false);
        var marked_during = std.atomic.Value(bool).init(false);
        var marked = std.atomic.Value(bool).init(false);
        var armed = std.atomic.Value(bool).init(true);
        /// Holds the first trace of the cell, the marking thread's, open.
        fn blockingTrace(_: *GcHeader, _: *Marker) void {
            if (!armed.swap(false, .acq_rel)) return;
            inside.store(true, .release);
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            inside.store(false, .release);
        }
        fn audit(_: bool, _: usize) void {
            if (inside.load(.acquire)) marked_during.store(true, .release);
            marked.store(true, .release);
        }
        fn collector() void {
            collectImpl(false);
        }
        fn isInside() bool {
            return inside.load(.acquire);
        }
    };
    C.arm();
    defer C.disarm();
    // 4 hangs off 1 and is tenured; its tracer holds the batch open.
    G.born(4);
    G.store(1, 1, 4);
    collectImpl(false);
    waitSweep();
    C.begin();
    G.hdr(4).gc_trace = S.blockingTrace;
    C.step(2);
    // 0 and 1 are traced; the next batch is 4's.
    marking_thread.steps.store(1, .release);
    try std.testing.expect(testWaitFor(S.isInside));
    const prev_audit = audit_hook;
    audit_hook = S.audit;
    defer audit_hook = prev_audit;
    const t = try std.Thread.spawn(.{}, S.collector, .{});
    testSleepMs(30);
    const marked_while_held = S.marked.load(.acquire);
    S.release.store(true, .release);
    t.join();
    G.hdr(4).gc_trace = GraphCells.traceKids;
    try std.testing.expect(!marked_while_held);
    try std.testing.expect(!S.marked_during.load(.acquire));
    try std.testing.expect(S.marked.load(.acquire));
}

test "a stop raised mid-batch waits for one cell of the marking thread's batch" {
    if (comptime !has_marking_thread) return error.SkipZigTest;
    const S = struct {
        const Cell = GraphCells.Cell;
        var chain: [64]Cell = undefined;
        var traced = std.atomic.Value(usize).init(0);
        var armed = std.atomic.Value(bool).init(false);
        var registered = false;
        /// The fifth cell holds its trace open until a stop is raised.
        fn trace(h: *GcHeader, m: *Marker) void {
            const n = traced.fetchAdd(1, .acq_rel);
            if (n == 4) {
                while (!stopRaised()) std.atomic.spinLoopHint();
            }
            const c: *Cell = @fieldParentPtr("hdr", h);
            if (c.kids[0]) |k| m.shade(k);
        }
        fn root(m: *Marker) void {
            if (armed.load(.acquire)) m.shade(&chain[0].hdr);
        }
        fn fifthReached() bool {
            return traced.load(.acquire) >= 5;
        }
    };
    // Tenured cells off the registry, as permanent ones are: marked and
    // traced, never swept.
    for (&S.chain, 0..) |*c, i| {
        c.* = .{ .hdr = .{ .gc_trace = S.trace, .gc_finalize = GraphCells.fin, .gc_gen = 1 } };
        c.kids[0] = if (i + 1 < S.chain.len) &S.chain[i + 1].hdr else null;
    }
    if (!S.registered) {
        registerRoot(S.root);
        S.registered = true;
    }
    S.armed.store(true, .release);
    const saved_mode = major_mode;
    const saved_batch = marker_batch;
    major_mode = .concurrent;
    marker_batch = S.chain.len;
    marking_thread.steps.store(0, .release);
    defer {
        S.armed.store(false, .release);
        marking_thread.steps.store(-1, .release);
        _ = testWaitFor(ConcurrentCells.majorEnded);
        major_mode = saved_mode;
        marker_batch = saved_batch;
    }
    alloc_perm = false;
    defer alloc_perm = true;
    major_pending.store(true, .monotonic);
    collectImpl(false);
    waitSweep();
    try std.testing.expect(major_mark.active);
    // One batch could trace the whole chain; the stop takes it from the
    // marking thread at the cell after the one it is tracing.
    marking_thread.steps.store(1, .release);
    try std.testing.expect(testWaitFor(S.fifthReached));
    testRaiseStop();
    lockMajorForStop();
    const at_stop = S.traced.load(.acquire);
    major_lock.unlock();
    endStop();
    try std.testing.expect(at_stop <= 6);
}

test "a stop no allocation asked for reaches the mutators' poll" {
    const prev = gc_enabled;
    gc_enabled = true;
    defer gc_enabled = prev;
    const T = struct {
        var ready = std.atomic.Value(bool).init(false);
        var quit = std.atomic.Value(bool).init(false);
        var collected = std.atomic.Value(bool).init(false);
        /// Polls as the interpreter does: only the pending flag.
        fn mutator() void {
            enterMutator();
            ready.store(true, .release);
            while (!quit.load(.acquire)) {
                if (pending()) safePoint();
                std.atomic.spinLoopHint();
            }
            exitMutator();
        }
        /// Collects from outside the mutator set, as the marking thread's
        /// remark does.
        fn collector() void {
            collectImpl(false);
            collected.store(true, .release);
        }
        fn isReady() bool {
            return ready.load(.acquire);
        }
        fn isCollected() bool {
            return collected.load(.acquire);
        }
    };
    gc_pending.store(false, .monotonic);
    const m = try std.Thread.spawn(.{}, T.mutator, .{});
    try std.testing.expect(testWaitFor(T.isReady));
    const c = try std.Thread.spawn(.{}, T.collector, .{});
    const in_time = testWaitFor(T.isCollected);
    // Leaving parks the mutator for a stop still waiting on it.
    T.quit.store(true, .release);
    m.join();
    c.join();
    try std.testing.expect(in_time);
}

test "a park lands only on the stop raised when it lands" {
    // What a parker read of one stop, before the next was raised.
    testRaiseStop();
    const seen = stop_word.load(.seq_cst);
    endStop();
    testRaiseStop();
    // Its count lands now: the word moved, so the exchange fails and the new
    // stop's tally holds only parks made for it.
    try std.testing.expect(stop_word.cmpxchgStrong(seen, seen + 1, .seq_cst, .seq_cst) != null);
    try std.testing.expectEqual(@as(usize, 0), stoppedCount());
    endStop();
    try std.testing.expect(!stopRaised());
}

test "a thread moving from a blocking bracket to a stop counts once toward the rendezvous" {
    const prev = gc_enabled;
    gc_enabled = true;
    defer gc_enabled = prev;
    const T = struct {
        var quit = std.atomic.Value(bool).init(false);
        var ready = std.atomic.Value(usize).init(0);
        // Set while the thread is in a bracket or parked for a stop, the only
        // states the collector may count it in.
        var quiet: [4]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false));
        fn run(i: usize) void {
            enterMutator();
            _ = ready.fetchAdd(1, .acq_rel);
            while (!quit.load(.acquire)) {
                quiet[i].store(true, .seq_cst);
                enterBlockingSafe();
                var k: u32 = 0;
                while (k < 8) : (k += 1) std.atomic.spinLoopHint();
                // Parks here, moving from the bracket count to the stop's.
                exitBlockingSafe();
                quiet[i].store(false, .seq_cst);
                k = 0;
                while (k < 8) : (k += 1) std.atomic.spinLoopHint();
                if (stopRaised()) {
                    quiet[i].store(true, .seq_cst);
                    parkForStop();
                    quiet[i].store(false, .seq_cst);
                }
            }
            exitMutator();
        }
        fn allReady() bool {
            return ready.load(.acquire) == 4;
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, T.run, .{i});
    try std.testing.expect(testWaitFor(T.allReady));
    var escaped: usize = 0;
    var round: usize = 0;
    while (round < 50_000) : (round += 1) {
        testRaiseStop();
        while (rendezvousShort(4)) std.atomic.spinLoopHint();
        for (&T.quiet) |*q| {
            if (!q.load(.seq_cst)) escaped += 1;
        }
        endStop();
    }
    T.quit.store(true, .release);
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 0), escaped);
}

test "threads waiting out a long stop sleep instead of spinning" {
    if (comptime !has_os_wait) return error.SkipZigTest;
    const prev = gc_enabled;
    gc_enabled = true;
    defer gc_enabled = prev;
    const T = struct {
        var ready = std.atomic.Value(usize).init(0);
        var done = std.atomic.Value(usize).init(0);
        fn run() void {
            enterMutator();
            _ = ready.fetchAdd(1, .acq_rel);
            while (!stopRaised()) std.atomic.spinLoopHint();
            parkForStop();
            _ = done.fetchAdd(1, .acq_rel);
            exitMutator();
        }
        fn allReady() bool {
            return ready.load(.acquire) == 3;
        }
        fn allStopped() bool {
            return stoppedCount() == 3;
        }
        fn allDone() bool {
            return done.load(.acquire) == 3;
        }
    };
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, T.run, .{});
    try std.testing.expect(testWaitFor(T.allReady));
    testRaiseStop();
    try std.testing.expect(testWaitFor(T.allStopped));
    // Held for 300 ms: three spinning or yielding waiters would burn most of
    // a core each.
    const before = testCpuMicros();
    testSleepMs(300);
    const burned = testCpuMicros() - before;
    try std.testing.expectEqual(@as(usize, 0), T.done.load(.acquire));
    endStop();
    try std.testing.expect(testWaitFor(T.allDone));
    for (threads) |t| t.join();
    try std.testing.expect(burned < 60_000);
}

test "a collector waiting on a mutator that parks late sleeps until it parks" {
    if (comptime !has_os_wait) return error.SkipZigTest;
    const prev = gc_enabled;
    gc_enabled = true;
    defer gc_enabled = prev;
    const T = struct {
        var ready = std.atomic.Value(bool).init(false);
        var parked = std.atomic.Value(bool).init(false);
        fn run() void {
            enterMutator();
            ready.store(true, .release);
            while (!stopRaised()) std.atomic.spinLoopHint();
            // Off doing something that is not a safe point for 300 ms.
            testSleepMs(300);
            parked.store(true, .release);
            parkForStop();
            exitMutator();
        }
        fn isReady() bool {
            return ready.load(.acquire);
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{});
    try std.testing.expect(testWaitFor(T.isReady));
    testRaiseStop();
    const before = testCpuMicros();
    awaitRendezvous(1);
    const burned = testCpuMicros() - before;
    // The rendezvous completed only once the mutator parked, and the
    // collector slept through the wait instead of spinning a core.
    try std.testing.expect(T.parked.load(.acquire));
    endStop();
    t.join();
    try std.testing.expect(burned < 60_000);
}

fn testCpuMicros() i64 {
    const ru = std.posix.getrusage(0);
    return (@as(i64, ru.utime.sec) + ru.stime.sec) * 1_000_000 + ru.utime.usec + ru.stime.usec;
}
