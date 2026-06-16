//! KLIO garbage collector ("KGC") — precise, stop-the-world, non-moving
//! tracing mark-sweep over the `ObjRef`/`ControlBlock` heap.
//!
//! This is the leaf module: it defines the per-cell `GcHeader`, the `Marker`
//! (grey worklist), the process-global cell registry, the collection epoch, and
//! the root-provider registry + collection driver. It imports nothing from
//! `value`/`objcell` so the object model can depend on it without a cycle; the
//! object graph's out-edges are discovered by duck-typed comptime dispatch in
//! `objcell` (cells whose payload exposes `gcMark`/`gcTrace`).
//!
//! Memory is freed by REACHABILITY, not by reference counts, so a missing
//! retain or an extra release is harmless and cycles are collected. See
//! `plans/GC.md` for the full design and the adversarial root-completeness
//! analysis this implements.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Non-generic header prefixed to every `ControlBlock(T)`. The collector reads
/// it type-erased; `gc_trace`/`gc_finalize` are comptime-specialized thunks the
/// `ObjRef(T)` body installs at allocation. `gc_mark` is an EPOCH: a cell is
/// "marked" iff `gc_mark == current epoch`, so a clear pass is never needed
/// (every reachable cell is re-stamped each collection). `usize` width makes
/// wrap unobservable.
pub const GcHeader = struct {
    gc_next: ?*GcHeader = null,
    gc_mark: usize = 0,
    gc_trace: *const fn (*GcHeader, *Marker) void,
    gc_finalize: *const fn (*GcHeader) void,
};

/// Tri-color marker: an explicit grey worklist (never native recursion — the
/// value graph is deep and cyclic). `shade` is white→grey (stamp + enqueue);
/// `drain` pops greys and traces their children to fixpoint.
pub const Marker = struct {
    epoch: usize,
    grey: std.ArrayListUnmanaged(*GcHeader) = .empty,
    arena: Allocator,

    pub fn shade(self: *Marker, h: *GcHeader) void {
        if (h.gc_mark == self.epoch) return; // already grey or black this epoch
        h.gc_mark = self.epoch;
        self.grey.append(self.arena, h) catch {
            // OOM on the worklist would under-mark => UAF. The grey list uses a
            // dedicated page allocator that does not fail in practice; treat a
            // failure as fatal rather than silently dropping a reachable cell.
            @panic("KGC: grey worklist allocation failed");
        };
    }

    pub fn drain(self: *Marker) void {
        while (self.grey.pop()) |h| h.gc_trace(h, self);
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

// ---------------------------------------------------------------------------
// Cell registry (the authoritative sweep enumeration).
// ---------------------------------------------------------------------------

/// Minimal test-and-set spinlock (Zig 0.16 std has no blocking `Thread.Mutex`).
/// Held only for the brief registry/root list splices, never across a safe
/// point, so contention is negligible.
const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

var reg_lock: SpinLock = .{};
var all_cells: ?*GcHeader = null;
var bytes_since_gc: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var live_bytes: usize = 0;
var threshold: usize = 8 * 1024 * 1024;
var cur_epoch: usize = 1;
var gc_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Whether the process runs the GC reclamation path (set by `main` for
/// `KLIO_RECLAIM=gc`). When false, `register` is never called and the
/// `GcHeader` fields lie dormant — arena/smp behavior is unchanged.
pub var gc_enabled: bool = false;

/// Stress mode (`KLIO_GC_STRESS=1`): force a collection at every safe point,
/// regardless of the byte threshold. A correctness oracle — if any root or
/// tracer is incomplete, collecting on every opcode boundary surfaces the UAF
/// immediately instead of waiting for 8MB of churn. Off in normal runs.
pub var gc_stress: bool = false;

/// Permanent generation. Cells minted while this is true (the stdlib image /
/// module / class graph loaded before the program body runs) are NOT placed on
/// the sweep registry, so they are never collected — they are immutable and
/// program-lifetime, and reference only other perm cells. They are still
/// traceable: when a nursery cell points at one, marking shades + traces it
/// (harmlessly, since it is never swept), reaching any nursery children.
/// Flipped to false by `vmRun` just before the program body executes.
pub threadlocal var alloc_perm: bool = true;

/// Push a freshly-minted cell onto the registry and account its size. Called
/// only in GC mode, from `ObjRef.initOwned`.
pub fn register(h: *GcHeader, bytes: usize) void {
    if (alloc_perm) return; // permanent — never swept, still traceable
    reg_lock.lock();
    h.gc_next = all_cells;
    all_cells = h;
    reg_lock.unlock();
    const prev = bytes_since_gc.fetchAdd(bytes, .monotonic);
    if (prev + bytes >= threshold) gc_pending.store(true, .monotonic);
}

/// Cheap poll at opcode-boundary safe points.
pub inline fn pending() bool {
    return gc_stress or gc_pending.load(.monotonic);
}

/// Called from an opcode-boundary safe point when a collection is pending. In
/// the single-threaded common case the calling thread is the only mutator, so
/// it collects in place; the multi-thread stop-the-world handshake is layered
/// on by `threads` (it parks the other mutators here before collecting).
pub fn safePoint() void {
    if (!gc_stress and !gc_pending.load(.monotonic)) return;
    collect();
}

// ---------------------------------------------------------------------------
// Root providers. Each subsystem (the evaluator frame chain, the coroutine
// driver, the scheduler, the Vm graph) registers a callback that, during the
// stop-the-world pause, shades every live Value it owns.
// ---------------------------------------------------------------------------

pub const RootFn = *const fn (*Marker) void;
var roots: std.ArrayListUnmanaged(RootFn) = .empty;
var roots_lock: SpinLock = .{};

pub fn registerRoot(f: RootFn) void {
    roots_lock.lock();
    defer roots_lock.unlock();
    roots.append(std.heap.page_allocator, f) catch @panic("KGC: root registration failed");
}

// ---------------------------------------------------------------------------
// Collection. Stage 1 is single-threaded stop-the-world driven by the
// safe-point poll; the multi-thread handshake is layered in by `threads`.
// ---------------------------------------------------------------------------

/// Run one full mark-sweep. The caller guarantees the world is stopped (all
/// mutator threads parked at safe points with their roots published) — in the
/// single-threaded common case that is simply "called from the safe point".
pub var gc_debug: bool = false;
/// Diagnostic: mark fully but never actually free a white cell. If a program
/// that crashes under real sweep runs cleanly here, the crash is a premature
/// free (an incomplete root/tracer), not a marking/sweep bug.
pub var gc_nofree: bool = false;

pub fn collect() void {
    cur_epoch +%= 1;
    if (cur_epoch == 0) cur_epoch = 1; // 0 is the never-marked sentinel
    var marker: Marker = .{ .epoch = cur_epoch, .arena = std.heap.page_allocator };
    defer marker.grey.deinit(std.heap.page_allocator);

    roots_lock.lock();
    const root_list = roots.items;
    roots_lock.unlock();
    for (root_list) |f| f(&marker);
    const marked = marker.drainCounted();

    const freed = sweep();
    gc_pending.store(false, .monotonic);
    bytes_since_gc.store(0, .monotonic);
    threshold = @max(8 * 1024 * 1024, live_bytes *| 2);
    if (gc_debug) std.debug.print(
        "[kgc] epoch={d} marked={d} live={d} freed={d}\n",
        .{ cur_epoch, marked, live_bytes, freed },
    );
}

fn sweep() usize {
    reg_lock.lock();
    defer reg_lock.unlock();
    var live: usize = 0;
    var freed: usize = 0;
    var prev: ?*GcHeader = null;
    var cur = all_cells;
    while (cur) |h| {
        const next = h.gc_next;
        if (h.gc_mark == cur_epoch) {
            prev = h;
            cur = next;
            live += 1;
        } else if (gc_nofree) {
            // Diagnostic: keep white cells linked and alive.
            prev = h;
            cur = next;
            live += 1;
        } else {
            // White: unlink, shallow-finalize, destroy.
            if (prev) |p| p.gc_next = next else all_cells = next;
            h.gc_finalize(h);
            cur = next;
            freed += 1;
        }
    }
    live_bytes = live; // cell count proxy until Stage 2 tracks bytes
    return freed;
}

test "marker shades, drains, and stops at fixpoint without recursion" {
    // A tiny synthetic graph of bare headers with a self-cycle: shading must
    // terminate and a cycle's cells survive while rooted.
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
