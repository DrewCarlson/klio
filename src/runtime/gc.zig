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
const trace = @import("trace.zig");
const clock_mod = @import("clock.zig");
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
    /// `@typeName(T)` of the payload, for the live-cell type histogram
    /// (`KLIO_GC_HIST`). Interned per type, so pointer identity keys the buckets.
    gc_type: [*:0]const u8 = "",
    /// Generation: 0 = nursery (swept by every collection), 1 = tenured
    /// (swept only by major collections). A cell is tenured when it survives
    /// its first collection; permanent-image cells are minted tenured so a
    /// minor mark never walks the stdlib graph.
    gc_gen: u8 = 0,
    /// Set by `writeBarrier` when a reference is stored into this (tenured)
    /// cell after tenuring: the cell joins the remembered set and is re-traced
    /// by the next minor mark so a tenured→nursery edge cannot be missed.
    /// Cleared when the remembered set drains (every collection).
    gc_remembered: bool = false,
    /// Registered size of the cell (`@sizeOf(Cell)` + external payload bytes at
    /// mint), so promotion can advance the major-collection trigger by real
    /// bytes. Fits the header's existing padding.
    gc_bytes: u32 = 0,
};

/// Diagnostic (KLIO_GC_HIST): after each collection, print the live-cell count
/// per payload type. A type whose live count climbs request-over-request is a
/// reachability (root) leak — something keeps that object graph rooted.
pub var gc_hist: bool = false;

/// Tri-color marker: an explicit grey worklist (never native recursion — the
/// value graph is deep and cyclic). `shade` is white→grey (stamp + enqueue);
/// `drain` pops greys and traces their children to fixpoint.
pub const Marker = struct {
    epoch: usize,
    grey: std.ArrayListUnmanaged(*GcHeader) = .empty,
    arena: Allocator,
    /// Minor collection: only nursery cells are swept, so marking stops at
    /// every tenured cell — its children are covered either by tenure (they
    /// were reachable when it was promoted) or by the remembered set (it was
    /// mutated since). A major collection traces the full graph.
    minor: bool = false,

    pub fn shade(self: *Marker, h: *GcHeader) void {
        if (gc_poison and h.gc_trace == poisonTrap) {
            std.debug.print("\n[GC-POISON-SHADE] root reached SWEPT cell: type={s}\n", .{h.gc_type});
            trace.dumpCurrent(.{});
            @panic("KGC: root shaded a swept cell (incomplete root)");
        }
        // Tenured cells are not swept by a minor, so stopping the walk at
        // them is safe ONLY if every tenured->nursery edge is in the
        // remembered set. The boxed Value payloads broke that assumption
        // somewhere (a live nursery box behind an un-remembered tenured cell
        // was swept — StringTest.zipWithNext GPF), so minors keep the cheap
        // nursery-only SWEEP but trace THROUGH tenured cells; the mark can
        // stop only at tenured cells it has already visited this epoch.
        // KLIO_GC_MINOR_STOP=1 restores the old early stop for bisecting the
        // missing barrier.
        if (self.minor and h.gc_gen != 0 and minor_stops_at_tenured) return;
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
/// Cells minted since the last collection. Every collection sweeps this list;
/// survivors move to `tenured`.
var nursery: ?*GcHeader = null;
/// Cells that survived a collection. Swept only by major collections; a minor
/// mark never visits them (the remembered set covers tenured→nursery edges).
var tenured: ?*GcHeader = null;
var tenured_count: usize = 0;
var bytes_since_gc: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
/// Bytes promoted into the tenured generation (plus net external growth)
/// since the last major collection — the major trigger's accumulator.
var bytes_since_major: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var live_bytes: usize = 0;

/// Generational mode: collections default to minor (nursery-only) sweeps, with
/// major (full-graph) collections on an Appel schedule over promoted bytes.
/// `KLIO_GC_GEN=0` forces every collection major (the pre-generational
/// behavior) for comparison and diagnosis.
pub var generational: bool = true;
var major_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Appel trigger for major collections: fires once `bytes_since_major`
/// crosses it; recomputed after each major from the surviving live set.
var major_threshold: usize = 8 * 1024 * 1024;

/// The remembered set: tenured cells mutated since promotion. Re-traced at the
/// start of every minor mark (a tenured cell's new children may be nursery
/// cells); drained (flags cleared, list emptied) by every collection.
var remembered: std.ArrayListUnmanaged(*GcHeader) = .empty;
var remembered_lock: SpinLock = .{};

/// Record a reference-store into an already-registered cell. Nursery cells
/// need no record (a minor mark traces them from the roots); a tenured cell
/// joins the remembered set once so the next minor mark re-traces it. With the
/// GC disabled every header keeps `gc_gen == 0`, so this is one predictable
/// branch.
pub inline fn writeBarrier(h: *GcHeader) void {
    if (h.gc_gen == 0) return;
    if (@atomicLoad(bool, &h.gc_remembered, .monotonic)) return;
    writeBarrierSlow(h);
}

fn writeBarrierSlow(h: *GcHeader) void {
    remembered_lock.lock();
    defer remembered_lock.unlock();
    if (h.gc_remembered) return;
    h.gc_remembered = true;
    remembered.append(std.heap.page_allocator, h) catch
        @panic("KGC: remembered set allocation failed");
}

/// Collection-trigger floor in bytes. A collection is requested once this many
/// bytes of cells have been registered since the last one; after each
/// collection the next floor is `max(threshold_floor, live * 2)` (Appel). The
/// floor is tunable via `KLIO_GC_THRESHOLD_KB` (default 8 MB) — a small floor
/// collects frequently to surface root/tracer holes without stress mode's
/// O(safe-points x live) cost.
var threshold_floor: usize = 8 * 1024 * 1024;
var freed_since_trim: usize = 0;
var threshold: usize = 8 * 1024 * 1024;

/// Appel growth multiplier: the next collection fires after `live * factor`
/// bytes. 2 keeps peak memory tight but spends ~half the run marking when
/// the allocation churn rate matches the live-set size (the DeepRecursive
/// commontests: a 100k-node live tree plus per-step suspension snapshots).
/// `KLIO_GC_GROWTH` overrides (integer, min 2).
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

/// Set the collection-trigger floor (bytes). Called by `main` from
/// `KLIO_GC_THRESHOLD_KB`. Lowers the initial threshold too.
pub fn setThresholdFloor(bytes: usize) void {
    threshold_floor = bytes;
    threshold = bytes;
    major_threshold = bytes;
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
    if (alloc_perm) {
        // Permanent — never swept, still traceable. Minted tenured so a minor
        // mark stops at it instead of walking the stdlib image graph, and so
        // a runtime mutation of a permanent cell hits the write barrier.
        h.gc_gen = 1;
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

/// Account heap growth the registry cannot see (frame register buffers
/// and suspension snapshots live in libc storage so the collector never
/// sweeps them, but they are traced through the frame chain and their
/// growth must still advance the Appel trigger — otherwise a program
/// building a deep suspended chain collects at the floor forever and
/// re-marks the whole chain quadratically).
pub fn noteExternalBytes(bytes: usize) void {
    if (!gc_enabled) return;
    _ = external_live.fetchAdd(bytes, .monotonic);
    const mprev = bytes_since_major.fetchAdd(bytes, .monotonic);
    if (mprev +| bytes >= major_threshold) major_pending.store(true, .monotonic);
    const prev = bytes_since_gc.fetchAdd(bytes, .monotonic);
    if (prev +| bytes >= threshold) gc_pending.store(true, .monotonic);
}

/// External (non-registry) bytes released back — keeps `external_live`
/// tracking the traced-but-unswept footprint so the Appel threshold can
/// include it. The trigger credit matters as much as the live credit:
/// external buffers are freed explicitly, never swept, so their churn
/// produces NO collectable garbage — counting their gross allocation into
/// `bytes_since_gc` made collections scale with CALL RATE (every frame's
/// register buffer advanced the trigger even when freed a microsecond
/// later), and each collection re-marked the whole live set for nothing.
/// External bytes therefore advance the trigger by NET growth only;
/// registry cells keep gross accounting (their garbage does accumulate).
pub fn noteExternalFreed(bytes: usize) void {
    if (!gc_enabled) return;
    subSaturating(&external_live, bytes);
    subSaturating(&bytes_since_gc, bytes);
    subSaturating(&bytes_since_major, bytes);
}

/// Subtract without ever going below zero. The clamp has to be part of the
/// same atomic step: a load-then-`fetchSub(@min(...))` pair lets two threads
/// each read a value that covers their own subtraction and then both subtract,
/// wrapping the counter to near `maxInt`. A wrapped counter then made the next
/// `noteExternalBytes` addition overflow, which aborted the interpreter under
/// the concurrent snapshot tests.
fn subSaturating(c: *std.atomic.Value(usize), bytes: usize) void {
    var cur = c.load(.monotonic);
    while (true) {
        const next = cur -| bytes;
        cur = c.cmpxchgWeak(cur, next, .monotonic, .monotonic) orelse return;
    }
}

var external_live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Gate for the external-bytes Appel accounting. Enabled by default so frame
/// buffers and suspension snapshots advance the same Appel trigger as traced
/// cells; `KLIO_GC_EXT=0` remains available for diagnosis and comparison.
pub var external_accounting: bool = true;

/// Cheap poll at opcode-boundary safe points. Every ~64k polls it also
/// probes for IDLE reclamation: a program that bursts (leaving a large
/// heap) and then goes quiet never crosses the allocation threshold
/// again, so its garbage would stay committed forever. One bonus
/// collection per quiescent period returns the heap to its live set (and
/// the pages to the OS); real allocation activity re-arms the probe.
pub inline fn pending() bool {
    if (gc_stress) return true;
    if (gc_stress_every != 0) {
        safepoint_counter += 1;
        if (safepoint_counter >= gc_stress_every) return true;
    }
    idle_tick += 1;
    if (idle_tick & 0xFFFF == 0) idleProbe();
    return gc_pending.load(.monotonic);
}

threadlocal var idle_tick: usize = 0;
/// Wall-clock (ms) when the last collection finished; 0 before the first.
var last_collect_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
/// Live bytes measured by the last collection.
var last_live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
/// The one-shot latch: true once the quiescent-period collection ran;
/// re-armed (set false) by any collection that saw real allocation.
var idle_collected: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
/// Quiescence window before the bonus collection fires.
const IDLE_COLLECT_MS: u64 = 1000;

fn idleProbe() void {
    if (gc_pending.load(.monotonic)) return;
    if (idle_collected.load(.monotonic)) return;
    // NOTE: registered-cell bytes wildly under-count the real heap (raw
    // string/array payloads are not cells), so there is no reliable
    // "worth it" size gate here — the latch already bounds the cost to
    // one collection per quiescent period.
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
    collectImpl(false);
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

/// Post-sweep hook: reclaim the metadata of closure side-table slots no live
/// value referenced this collection (`epoch`). Set by `interp_ir` alongside
/// `markClosureHook`; null (a no-op) otherwise. Called inside the stop-the-world
/// pause, after the sweep, so the side-table is stable.
pub var sweepClosureHook: ?*const fn (epoch: usize) void = null;

/// Singleton identity of a closure id for Kotlin's non-capturing-lambda
/// semantics: a stable non-zero value keyed on the closure's (module, body
/// function) when it captures nothing, and 0 when it captures (so identity
/// falls back to the closure id). A non-capturing lambda literal is a singleton
/// in Kotlin — every evaluation yields the same instance — but klio materialises
/// a fresh closure id per evaluation. `structuralEq` compares two closures by
/// this identity so two evaluations of the same non-capturing literal compare
/// equal (`===`/`==`) as they do in Kotlin. Set by `interp_ir`; null means the
/// fallback id comparison. Installed in every memory mode, not only under GC.
pub var closureSingletonHook: ?*const fn (id: u64) u64 = null;

/// Marks the live Values reachable from a parked lazy-`sequence{}` builder
/// continuation. The continuation is an `ir.eval.SuspendState` box held by a
/// `Sequence`'s `Builder` source (an `*anyopaque` because `runtime` cannot
/// import `ir`); `SequenceData.gcTrace` invokes this to shade each frame
/// snapshot's regs/params/captures. Set by `interp_ir` to point at
/// `ir.eval.gcMarkSuspendStateOpaque`; null (a no-op) otherwise.
pub var markSuspendHook: ?*const fn (cont: *anyopaque, m: *Marker) void = null;

/// Finalize an abandoned lazy-`sequence{}` builder continuation: a `Sequence`
/// whose `Builder` source was swept without being driven to completion still
/// owns its `SuspendState` box (frames with retained snapshot values + raw
/// slice buffers). `BuilderState.gcFinalize`/`deinit` invokes this to release
/// and free it through the cell's allocator. Set by `interp_ir`; null (a no-op)
/// otherwise.
pub var freeSuspendHook: ?*const fn (cont: *anyopaque, a: std.mem.Allocator) void = null;

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

/// Diagnostic (KLIO_GC_POISON): on sweep, do NOT free a white cell. Instead
/// quarantine it — leak the memory, overwrite the payload, and swap its tracer
/// to `poisonTrap`. If a live value still references the cell, the NEXT
/// collection re-shades + traces it, firing the trap with the cell's type and a
/// stack trace: the exact swept-while-live cell that an incomplete root missed.
pub var gc_poison: bool = false;
/// Whether a MINOR mark stops at tenured cells (the classic generational
/// shortcut). Off by default until the boxed-payload remembered-set hole is
/// found; `KLIO_GC_MINOR_STOP=1` turns the shortcut back on.
pub var minor_stops_at_tenured: bool = false;

/// Tracer installed on a quarantined (poisoned) cell. Reaching it means a live
/// value referenced a cell the prior collection swept — a missing-root UAF.
pub fn poisonTrap(h: *GcHeader, _: *Marker) void {
    std.debug.print("\n[GC-POISON] live reference to SWEPT cell: type={s}\n", .{h.gc_type});
    trace.dumpCurrent(.{});
    @panic("KGC: use-after-free — a live value referenced a swept cell (incomplete root)");
}

pub fn collect() void {
    collectImpl(true);
}

fn collectImpl(force_major: bool) void {
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

    const major = force_major or !generational or gc_stress or
        major_pending.load(.monotonic);

    cur_epoch +%= 1;
    if (cur_epoch == 0) cur_epoch = 1; // 0 is the never-marked sentinel
    var marker: Marker = .{
        .epoch = cur_epoch,
        .arena = std.heap.page_allocator,
        .minor = !major,
    };
    defer marker.grey.deinit(std.heap.page_allocator);

    roots_lock.lock();
    const root_list = roots.items;
    roots_lock.unlock();
    for (root_list) |f| f(&marker);
    markThreadRoots(&marker);
    // Minor: re-trace every tenured cell mutated since promotion — its
    // children may be nursery cells the root scan cannot otherwise reach.
    // Traced directly (not shaded): tenured cells are outside a minor sweep.
    if (!major) {
        for (remembered.items) |h| h.gc_trace(h, &marker);
    }
    const marked = marker.drainCounted();
    // Drain the remembered set under both kinds: after a minor every survivor
    // is tenured (old→young edges became old→old); after a major the fresh
    // full mark subsumes it. Cleared before the sweep so no entry dangles.
    for (remembered.items) |h| h.gc_remembered = false;
    remembered.clearRetainingCapacity();

    const freed = if (major) sweepFull() else sweepMinor();
    // Reclaim closure side-table metadata for slots no live value marked this
    // epoch (still stop-the-world: the side-table is stable). Major only: a
    // minor mark never re-stamps tenured closures, so its epoch proves nothing
    // about their liveness.
    if (major) {
        if (sweepClosureHook) |f| f(cur_epoch);
    }
    gc_pending.store(false, .monotonic);
    // A collection that saw real allocation re-arms the idle probe, so
    // the NEXT quiescent period gets its bonus reclamation; the idle
    // collection itself (near-zero churn) stays latched.
    if (bytes_since_gc.load(.monotonic) >= threshold_floor / 2) {
        idle_collected.store(false, .monotonic);
    }
    last_live.store(live_bytes, .monotonic);
    last_collect_ms.store(nowMillis(), .monotonic);
    bytes_since_gc.store(0, .monotonic);
    if (others != 0) stop_flag.store(false, .release);
    if (major) {
        major_pending.store(false, .monotonic);
        bytes_since_major.store(0, .monotonic);
        major_threshold = @max(threshold_floor, (live_bytes +| external_live.load(.monotonic)) *| growthFactor());
        threshold = if (generational)
            threshold_floor
        else
            @max(threshold_floor, (live_bytes +| external_live.load(.monotonic)) *| growthFactor());
    }
    // Return the pages the swept cells freed back to the OS. The backing
    // allocator caches freed memory in its free-lists (RSS reflects the
    // allocation high-water, not the live set), so after a collection that
    // reclaimed real garbage, ask it to trim — keeping process RSS tracking the
    // live set, not the cumulative churn. Set by `main` to the platform trim.
    // Rate-limited: trimming after EVERY freeing collection turned into
    // steady mmap/munmap traffic under allocation-churn-heavy runs (the
    // trim itself profiled alongside the marking); RSS only needs to track
    // the live set coarsely, so trim once a meaningful amount accumulates.
    freed_since_trim +|= freed;
    if (freed_since_trim >= 32 * 1024 * 1024) {
        freed_since_trim = 0;
        if (release_to_os) |f| f();
    }
    if (gc_debug) std.debug.print(
        "[kgc] epoch={d} kind={s} marked={d} live={d} freed={d}\n",
        .{ cur_epoch, if (major) "major" else "minor", marked, live_bytes, freed },
    );
    if (gc_hist) liveTypeHistogram();
}

/// Print the top live-cell payload types by count (KLIO_GC_HIST). Buckets by
/// `gc_type` pointer identity (interned `@typeName`). O(live x distinct types);
/// fine for a diagnostic. Walks the registry under the same lock as the sweep.
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
    // Simple selection of the top 16 by count.
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

/// Platform hook to return cached free memory to the OS after a collection
/// (e.g. `malloc_zone_pressure_relief` on macOS). Null = no trim.
pub var release_to_os: ?*const fn () void = null;

/// Minor sweep: walk only the nursery. Marked cells promote to the tenured
/// list (their promotion bytes advance the major trigger); white cells free.
/// The nursery is empty afterwards.
fn sweepMinor() usize {
    reg_lock.lock();
    defer reg_lock.unlock();
    var freed: usize = 0;
    var promoted: usize = 0;
    var promoted_bytes: usize = 0;
    var cur = nursery;
    while (cur) |h| {
        const next = h.gc_next;
        if (h.gc_mark == cur_epoch or gc_nofree) {
            h.gc_gen = 1;
            h.gc_next = tenured;
            tenured = h;
            promoted += 1;
            promoted_bytes += h.gc_bytes;
        } else {
            h.gc_finalize(h);
            freed += 1;
        }
        cur = next;
    }
    nursery = null;
    tenured_count += promoted;
    live_bytes = tenured_count; // cell count proxy
    const mprev = bytes_since_major.fetchAdd(promoted_bytes, .monotonic);
    if (mprev + promoted_bytes >= major_threshold) major_pending.store(true, .monotonic);
    return freed;
}

/// Major sweep: promote nursery survivors, then free every unmarked tenured
/// cell. Runs after a full-graph mark, so an unmarked tenured cell is garbage.
fn sweepFull() usize {
    reg_lock.lock();
    defer reg_lock.unlock();
    var freed: usize = 0;
    var cur = nursery;
    while (cur) |h| {
        const next = h.gc_next;
        if (h.gc_mark == cur_epoch or gc_nofree) {
            h.gc_gen = 1;
            h.gc_next = tenured;
            tenured = h;
        } else {
            h.gc_finalize(h);
            freed += 1;
        }
        cur = next;
    }
    nursery = null;
    var live: usize = 0;
    var prev: ?*GcHeader = null;
    cur = tenured;
    while (cur) |h| {
        const next = h.gc_next;
        if (h.gc_mark == cur_epoch or gc_nofree) {
            prev = h;
            live += 1;
        } else {
            if (prev) |p| p.gc_next = next else tenured = next;
            h.gc_finalize(h);
            freed += 1;
        }
        cur = next;
    }
    tenured_count = live;
    live_bytes = live; // cell count proxy
    return freed;
}

test "minor mark stops at tenured cells; major stamps them" {
    const T = struct {
        fn trace(_: *GcHeader, _: *Marker) void {}
        fn fin(_: *GcHeader) void {}
    };
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
    // Undo the global side effect so other tests see a clean remembered set.
    remembered_lock.lock();
    remembered.clearRetainingCapacity();
    old.gc_remembered = false;
    remembered_lock.unlock();
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
