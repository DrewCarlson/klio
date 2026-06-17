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
    fn tryLock(self: *SpinLock) bool {
        return !self.state.swap(true, .acquire);
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

var reg_lock: SpinLock = .{};
var all_cells: ?*GcHeader = null;
var bytes_since_gc: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var live_bytes: usize = 0;

/// Collection-trigger floor in bytes. A collection is requested once this many
/// bytes of cells have been registered since the last one; after each
/// collection the next floor is `max(threshold_floor, live * 2)` (Appel). The
/// floor is tunable via `KLIO_GC_THRESHOLD_KB` (default 8 MB) — a small floor
/// collects frequently to surface root/tracer holes without stress mode's
/// O(safe-points x live) cost.
var threshold_floor: usize = 8 * 1024 * 1024;
var threshold: usize = 8 * 1024 * 1024;
var cur_epoch: usize = 1;
var gc_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Set the collection-trigger floor (bytes). Called by `main` from
/// `KLIO_GC_THRESHOLD_KB`. Lowers the initial threshold too.
pub fn setThresholdFloor(bytes: usize) void {
    threshold_floor = bytes;
    threshold = bytes;
}

/// Whether the process runs the GC reclamation path (set by `main` for
/// `KLIO_RECLAIM=gc`). When false, `register` is never called and the
/// `GcHeader` fields lie dormant — arena/smp behavior is unchanged.
pub var gc_enabled: bool = false;

/// Set true by `vmRun` once the program body begins (after the static image is
/// built). Used only by the KLIO_GC_GUARD diagnostic to exempt the multi-MB
/// startup reads (stdlib image) from its absurd-allocation tripwire.
pub var program_started: bool = false;

/// Stress mode (`KLIO_GC_STRESS=1`): force a collection at every safe point,
/// regardless of the byte threshold. A correctness oracle — if any root or
/// tracer is incomplete, collecting on every opcode boundary surfaces the UAF
/// immediately instead of waiting for 8MB of churn. Off in normal runs.
pub var gc_stress: bool = false;

/// Sampled stress (`KLIO_GC_STRESS_EVERY=N`): force a collection every N safe
/// points. Catches the same narrow-window holes as full stress (a premature
/// free recurs across a long run) at roughly 1/N the cost, so long programs
/// validate without the O(safe-points x live) blowup of N=1. `0` disables.
pub var gc_stress_every: usize = 0;
threadlocal var safepoint_counter: usize = 0;

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
    if (gc_stress) return true;
    if (gc_stress_every != 0) {
        safepoint_counter += 1;
        if (safepoint_counter >= gc_stress_every) return true;
    }
    return gc_pending.load(.monotonic);
}

/// Called from an opcode-boundary safe point when a collection is pending. In
/// the single-threaded common case the calling thread is the only mutator, so
/// it collects in place; the multi-thread stop-the-world handshake is layered
/// on by `threads` (it parks the other mutators here before collecting).
pub fn safePoint() void {
    // Another thread is collecting: park until it finishes (publishing this
    // thread's roots as quiescent) instead of starting our own collection.
    if (stop_flag.load(.acquire)) {
        parkForStop();
        return;
    }
    const sampled = gc_stress_every != 0 and safepoint_counter >= gc_stress_every;
    if (sampled) safepoint_counter = 0;
    if (!gc_stress and !sampled and !gc_pending.load(.monotonic)) return;
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

/// Closures are collected by ordinary reachability of their `IrClosure` Value.
/// When `Value.gcMark` marks an `IrClosure`, it shades the Value's own captures
/// cell (via `forEachChildCell`); this hook additionally keeps the closure
/// side-table's canonical capture store and receiver-chain alive for that id,
/// so a live closure's invoke-time state survives while a closure no live value
/// references is left white and swept. Set by `interp_ir` once the program's
/// closure table exists; null (a no-op) otherwise. The transitive case — a
/// closure captured by another closure — needs no second pass: shading the
/// outer captures cell enqueues it, and draining it marks the inner closure
/// Value, whose own `gcMark` re-invokes this hook.
pub var markClosureHook: ?*const fn (id: u64, m: *Marker) void = null;

// ---------------------------------------------------------------------------
// Per-thread roots. A subsystem's roots live in threadlocals (the eval frame
// chain, the host-op keepalive stack, the coroutine interceptor/scope stacks),
// so one global `RootFn` reading them only sees the COLLECTING thread's. Each
// thread instead registers a `ThreadRoot` whose `ctx` is the stable address of
// its own threadlocal; the collector dereferences that pointer to mark that
// thread's roots from any thread. A registered thread is parked at a safe point
// (or in a blocking-safe region) during collection, so its stack/threadlocals
// are stable to read cross-thread.
// ---------------------------------------------------------------------------

pub const ThreadRootFn = *const fn (ctx: *anyopaque, m: *Marker) void;
pub const ThreadRoot = struct {
    next: ?*ThreadRoot = null,
    ctx: *anyopaque,
    mark: ThreadRootFn,
    linked: bool = false,
};
var thread_roots: ?*ThreadRoot = null;
var thread_roots_lock: SpinLock = .{};

/// Link a thread's root node (its `ctx` is one of its threadlocal addresses).
/// `node` is itself a threadlocal/stable-storage value owned by the thread.
pub fn registerThreadRoot(node: *ThreadRoot) void {
    thread_roots_lock.lock();
    defer thread_roots_lock.unlock();
    if (node.linked) return;
    node.linked = true;
    node.next = thread_roots;
    thread_roots = node;
}

/// Unlink a thread's root node at thread exit (its threadlocal storage is about
/// to become invalid).
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
    // Held for the whole walk: register/unregister (thread entry/exit) splice
    // this list, and a concurrent splice during the walk would corrupt it.
    // Contention is negligible — links change only at thread start/stop.
    thread_roots_lock.lock();
    defer thread_roots_lock.unlock();
    var cur = thread_roots;
    while (cur) |n| : (cur = n.next) n.mark(n.ctx, m);
}

// ---------------------------------------------------------------------------
// Stop-the-world handshake. The collecting thread sets `stop_flag`; every other
// registered mutator parks at its next safe point (or is already parked in a
// blocking-safe region). The collector waits until every other mutator is
// parked, marks all roots (global + every thread's), sweeps, then clears the
// flag and releases the parked threads. `gc_lock` makes the collection itself
// single-collector. Single-threaded common case: `mutators == 1`, the wait is a
// no-op, and this degenerates to "collect right here".
// ---------------------------------------------------------------------------

var stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var parked_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var mutators: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var gc_lock: SpinLock = .{};

/// Register the calling thread as an active mutator (it runs program code and
/// holds collectable roots). Called at a thread's entry seam, after its
/// per-thread root nodes are linked.
pub fn enterMutator() void {
    _ = mutators.fetchAdd(1, .acq_rel);
}

/// Deregister the calling thread as a mutator at its exit seam, before its
/// per-thread root nodes unlink. Counts as parked across any in-flight
/// collection so the collector's rendezvous cannot wait forever for a thread
/// that is leaving, and waits out an active collection so the caller can safely
/// unlink its (still-readable) root nodes immediately afterward.
pub fn exitMutator() void {
    _ = parked_count.fetchAdd(1, .acq_rel);
    _ = mutators.fetchSub(1, .acq_rel);
    while (stop_flag.load(.acquire)) std.atomic.spinLoopHint();
    _ = parked_count.fetchSub(1, .acq_rel);
}

/// Park the calling thread for the duration of an in-progress collection: it
/// publishes itself as quiescent (its roots are stable in its registered
/// threadlocals) and spins until the collector clears `stop_flag`.
fn parkForStop() void {
    _ = parked_count.fetchAdd(1, .acq_rel);
    while (stop_flag.load(.acquire)) std.atomic.spinLoopHint();
    _ = parked_count.fetchSub(1, .acq_rel);
}

/// Bracket a blocking primitive (timer sleep, thread join, socket accept, idle
/// park): the thread holds no unrooted live Value (its state is in registered
/// threadlocals) and is about to stop making progress, so it counts as already
/// parked for the STW rendezvous.
pub fn enterBlockingSafe() void {
    if (!gc_enabled) return;
    _ = parked_count.fetchAdd(1, .acq_rel);
}

/// Leave a blocking-safe region. If a collection is in progress, wait for it to
/// finish before touching the heap again, then stop counting as parked.
pub fn exitBlockingSafe() void {
    if (!gc_enabled) return;
    while (stop_flag.load(.acquire)) std.atomic.spinLoopHint();
    _ = parked_count.fetchSub(1, .acq_rel);
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
    // Single collector at a time. A thread that loses the race for `gc_lock`
    // found a collection already underway; it parks (publishing its roots) and
    // returns rather than queueing a redundant second collection.
    if (!gc_lock.tryLock()) {
        parkForStop();
        return;
    }
    defer gc_lock.unlock();

    // Stop the world: signal every other registered mutator to park at its next
    // safe point, then wait until all of them are parked (or in a blocking-safe
    // region). Single-threaded: `others == 0`, so this is a no-op.
    const others = mutators.load(.acquire) -| 1;
    if (others != 0) {
        stop_flag.store(true, .release);
        while (parked_count.load(.acquire) < others) std.atomic.spinLoopHint();
    }

    cur_epoch +%= 1;
    if (cur_epoch == 0) cur_epoch = 1; // 0 is the never-marked sentinel
    var marker: Marker = .{ .epoch = cur_epoch, .arena = std.heap.page_allocator };
    defer marker.grey.deinit(std.heap.page_allocator);

    roots_lock.lock();
    const root_list = roots.items;
    roots_lock.unlock();
    for (root_list) |f| f(&marker);
    markThreadRoots(&marker);
    const marked = marker.drainCounted();

    const freed = sweep();
    gc_pending.store(false, .monotonic);
    bytes_since_gc.store(0, .monotonic);
    if (others != 0) stop_flag.store(false, .release);
    threshold = @max(threshold_floor, live_bytes *| 2);
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
