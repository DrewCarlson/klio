//! Precise, stop-the-world, non-moving mark-sweep collector over the
//! `ObjRef`/`ControlBlock` heap. Frees by reachability, so a missing retain or
//! an extra release is harmless and cycles are collected. Imports nothing from
//! `value`/`objcell`; out-edges are found by comptime dispatch in `objcell`.

const std = @import("std");
const trace = @import("trace.zig");
const clock_mod = @import("clock.zig");
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

    pub fn shade(self: *Marker, h: *GcHeader) void {
        if (gc_poison and h.gc_trace == poisonTrap) {
            std.debug.print("\n[GC-POISON-SHADE] root reached SWEPT cell: type={s} ctx={s}:{d}\n", .{ h.gc_type, poison_ctx_name, poison_ctx_idx });
            trace.dumpCurrent(.{});
            @panic("KGC: root shaded a swept cell (incomplete root)");
        }
        // Sound while every tenured-to-nursery edge is remembered.
        if (self.minor and h.gc_gen != 0 and minor_stops_at_tenured) return;
        if (h.gc_mark == self.epoch) return; // already grey or black this epoch
        h.gc_mark = self.epoch;
        self.grey.append(self.arena, h) catch {
            // Under-marking would be a use-after-free.
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

/// Record a reference store: a tenured cell joins the remembered set.
pub inline fn writeBarrier(h: *GcHeader) void {
    if (h.gc_gen == 0) return;
    if (@atomicLoad(bool, &h.gc_remembered, .monotonic)) return;
    writeBarrierSlow(h);
}

/// Trace every remembered cell, from a snapshot taken outside
/// `remembered_lock`: a tracer can reach a write barrier that takes it.
fn traceRemembered(marker: *Marker) void {
    remembered_lock.lock();
    const snapshot = std.heap.page_allocator.dupe(*GcHeader, remembered.items) catch
        @panic("KGC: remembered snapshot allocation failed");
    remembered_lock.unlock();
    defer std.heap.page_allocator.free(snapshot);
    for (snapshot) |h| h.gc_trace(h, marker);
}

fn writeBarrierSlow(h: *GcHeader) void {
    remembered_lock.lock();
    defer remembered_lock.unlock();
    if (h.gc_remembered) return;
    h.gc_remembered = true;
    if (rememberTraceOn()) {
        std.debug.print("[gc-remember] h={*} gen={d} type={s} program_started={}\n", .{ h, h.gc_gen, h.gc_type, program_started });
    }
    remembered.append(std.heap.page_allocator, h) catch
        @panic("KGC: remembered set allocation failed");
}

/// Drop one cell from the remembered set, for a caller about to free it.
pub fn forgetCell(h: *GcHeader) void {
    remembered_lock.lock();
    defer remembered_lock.unlock();
    if (!h.gc_remembered) return;
    h.gc_remembered = false;
    for (remembered.items, 0..) |e, i| {
        if (e == h) {
            _ = remembered.swapRemove(i);
            break;
        }
    }
}

/// Clear every remembered flag and empty the list. A boundary that frees
/// permanent cells wholesale must call this first: they are never swept.
pub fn drainRemembered() void {
    remembered_lock.lock();
    defer remembered_lock.unlock();
    for (remembered.items) |h| h.gc_remembered = false;
    remembered.clearRetainingCapacity();
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
threadlocal var safepoint_counter: usize = 0;

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
    ext_delta += @as(isize, @intCast(@min(bytes, std.math.maxInt(isize))));
    if (ext_delta >= EXT_FLUSH) flushExternalDelta();
}

/// External bytes released. External buffers are freed explicitly and never
/// swept, so they advance the trigger by net growth only while registry cells
/// stay on gross accounting.
pub fn noteExternalFreed(bytes: usize) void {
    if (!gc_enabled) return;
    ext_delta -= @as(isize, @intCast(@min(bytes, std.math.maxInt(isize))));
    if (ext_delta <= -EXT_FLUSH) flushExternalDelta();
}

/// Per-thread net unflushed external bytes: deltas batch thread-locally and
/// reach the shared counters `EXT_FLUSH` bytes at a time.
threadlocal var ext_delta: isize = 0;
const EXT_FLUSH: isize = 256 * 1024;

pub fn flushExternalDelta() void {
    const d = ext_delta;
    if (d == 0) return;
    ext_delta = 0;
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

/// Cheap poll at opcode-boundary safe points. Every 64k polls it probes for
/// idle reclamation, so a program that bursts and goes quiet still returns its
/// heap to the OS.
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

/// Accessors for the transpiled hot path's inlined edge guard. Stress modes
/// are reported so the emitted code takes the full slow path on every edge.
pub fn idleTickPtr() *usize {
    return &idle_tick;
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
    if (stop_flag.load(.acquire)) {
        parkForStop();
        return;
    }
    const sampled = gc_stress_every != 0 and safepoint_counter >= gc_stress_every;
    if (sampled) safepoint_counter = 0;
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

// Stop-the-world handshake. The collecting thread sets `stop_flag`; every
// other mutator parks at its next safe point or is already in a blocking-safe
// region. `gc_lock` keeps collection single-collector.

var stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var parked_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var mutators: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var gc_lock: SpinLock = .{};

/// Whether a stop-the-world collection is in progress. A mutator that mutates
/// or frees while it is true is a rendezvous bug.
pub fn worldStopped() bool {
    return world_marking.load(.acquire);
}
/// True from "every other mutator is parked" to the end of the sweep.
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
        if (!stop_flag.load(.acquire)) {
            is_mutator = true;
            _ = mutators.fetchAdd(1, .acq_rel);
            mutator_lock.unlock();
            return;
        }
        mutator_lock.unlock();
        // A stop in progress whose snapshot predates this thread.
        spinWait(stopFlagSet);
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
        if (!stop_flag.load(.acquire)) {
            is_mutator = false;
            _ = mutators.fetchSub(1, .acq_rel);
            mutator_lock.unlock();
            return;
        }
        mutator_lock.unlock();
        parkForStop();
    }
}

/// Park for an in-progress collection: publish as quiescent and spin until the
/// collector clears `stop_flag`.
fn parkForStop() void {
    // Increment only for a stop actually in progress: a thread that lost the
    // `gc_lock` race just before the winner raised `stop_flag` would otherwise
    // satisfy the rendezvous and run on through the mark.
    if (!stop_flag.load(.acquire)) return;
    // Counted for this stop only; the next raise resets the tally.
    _ = stopped_count.fetchAdd(1, .acq_rel);
    spinWait(stopFlagSet);
}

/// Depth of blocking-primitive brackets. Inside one the thread holds no
/// unrooted live Value and makes no progress, so it counts as parked.
pub threadlocal var blocking_safe_depth: u32 = 0;

/// How many nested reasons this thread is parked for. The rendezvous counts
/// threads, so `parked_count` moves only on the 0<->1 edges; a count per reason
/// would let one thread satisfy `parked_count >= others` alone.
pub threadlocal var park_depth: u32 = 0;

/// Threads parked for the current stop. Reset as each stop is raised, so a
/// leftover publication cannot satisfy the next rendezvous.
var stopped_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Wait for `pred` to go false: spin briefly, then yield.
fn spinWait(comptime pred: fn () bool) void {
    var rounds: u32 = 0;
    while (pred()) {
        rounds +|= 1;
        if (rounds <= 256) {
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
}

fn stopFlagSet() bool {
    return stop_flag.load(.acquire);
}

fn parkPublish() void {
    // Only mutators are counted: a parked non-mutator would satisfy the
    // rendezvous one thread early.
    if (!is_mutator) return;
    park_depth += 1;
    if (park_depth == 1) _ = parked_count.fetchAdd(1, .acq_rel);
}

fn parkUnpublish() void {
    if (park_depth == 0) return;
    park_depth -= 1;
    if (park_depth == 0) _ = parked_count.fetchSub(1, .acq_rel);
}

pub fn enterBlockingSafe() void {
    if (!gc_enabled) return;
    blocking_safe_depth += 1;
    parkPublish();
}

/// Wait out an in-progress collection before touching the heap again.
pub fn exitBlockingSafe() void {
    if (!gc_enabled) return;
    spinWait(stopFlagSet);
    blocking_safe_depth -|= 1;
    parkUnpublish();
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
    if (h.gc_mark == cur_epoch) return .marked;
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

pub fn collect() void {
    collectImpl(true);
}

/// Live cells the last collection kept, for the `KLIO_RUN_STATS` report.
pub fn liveCellsAfterCollect() usize {
    return last_live.load(.monotonic);
}

/// One mark-sweep with the world stopped. `force_major` sweeps the whole graph.
fn collectImpl(force_major: bool) void {
    if (!gc_lock.tryLock()) {
        parkForStop();
        return;
    }
    defer gc_lock.unlock();
    collector_tid.store(currentTid(), .release);
    defer collector_tid.store(0, .release);
    // The collector's own buffered delta joins the shared counters before the
    // threshold math reads them.
    flushExternalDelta();

    // Stop the world. The snapshot and the raise happen under the membership
    // lock, so `others` and `parked_count` describe the same cohort.
    mutator_lock.lock();
    const others = mutators.load(.acquire) -| 1;
    stopped_count.store(0, .release);
    if (others != 0) stop_flag.store(true, .release);
    mutator_lock.unlock();
    if (others != 0) {
        // Threads in blocking-safe brackets cannot run, so they count parked.
        while (parked_count.load(.acquire) + stopped_count.load(.acquire) < others)
            std.atomic.spinLoopHint();
    }
    dbg_collector_park.store(park_depth, .release);
    dbg_mutators.store(mutators.load(.acquire), .release);
    dbg_parked.store(parked_count.load(.acquire), .release);
    world_marking.store(true, .release);
    defer world_marking.store(false, .release);

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
    // Minor: re-trace every remembered cell, whose children may be nursery
    // cells the root scan cannot reach. Traced directly, not shaded.
    if (!major) traceRemembered(&marker);
    const marked = marker.drainCounted();
    // Drain the remembered set: after a minor every survivor is tenured, after
    // a major the fresh full mark subsumes it. Cleared before the sweep.
    remembered_lock.lock();
    if (rememberTraceOn()) {
        std.debug.print("[gc-drain] n={d} major={} program_started={}\n", .{ remembered.items.len, major, program_started });
        for (remembered.items) |h| std.debug.print("[gc-drain]   h={*}\n", .{h});
    }
    for (remembered.items) |h| h.gc_remembered = false;
    remembered.clearRetainingCapacity();
    remembered_lock.unlock();

    if (audit_hook) |f| f(major, cur_epoch);
    const freed = if (major) sweepFull() else sweepMinor();
    if (post_sweep_hook) |f| f(major, cur_epoch);
    // Major only: a minor mark never re-stamps tenured closures.
    if (major) {
        if (sweepClosureHook) |f| f(cur_epoch);
    }
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
    // Return the swept pages to the OS: the backing allocator holds freed
    // memory in free-lists, so RSS otherwise tracks the allocation high-water.
    // Rate-limited, since trimming every collection is steady mmap traffic.
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

/// Minor sweep: marked nursery cells promote and advance the major trigger,
/// white cells are freed, and the nursery is empty afterwards.
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

/// Major sweep: runs after a full mark, so an unmarked tenured cell is garbage.
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
    traceRemembered(&marker);
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
