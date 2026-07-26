//! Coroutine driver support — the cross-thread `DriverWakeup` mailbox
//! and the `CooperativeInterceptor`'s park / resume / ready-queue /
//! virtual-time machinery.
//!
//! Layer 2 — the default `ContinuationInterceptor`. This is the only
//! place coroutine *scheduling* happens. The core suspend engine
//! (Layer 1, `ir.eval`) is dispatcher- and time-agnostic: it only
//! pauses an activation into a `SuspendState` and resumes one. Every
//! decision about *when* and in what order parked activations resume —
//! the cooperative ready queue and virtual-time advance — lives here,
//! behind the named seams below, so a later thread-dispatching
//! interceptor can replace it without touching Layer 1.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const root = @import("../interp_ir.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const SuspendState = ir.eval.SuspendState;
const ObjRef = runtime.ObjRef;
const SpinMutex = root.SpinMutex;
const TimeMode = root.TimeMode;

/// Indefinite-park sentinel: an activation with this wake-at deadline
/// resumes only on an explicit ready entry, never on a timer.
const INDEFINITE: i64 = std.math.maxInt(i64);

/// Raw monotonic clock reading in nanoseconds. Backs the `Wall`-mode
/// origin and elapsed-since-origin reading.
fn monotonicNanos() i128 {
    return runtime.clockMonotonicNanos();
}

/// Block the calling thread for `millis` milliseconds.
fn sleepMillis(millis: u64) void {
    runtime.clockSleepMillis(@intCast(@min(millis, @as(u64, std.math.maxInt(i64)))));
}

/// Where pump wall-clock sleeps come from, counted when `KLIO_PUMP_DIAG` is
/// set (`sleep_diag`) and dumped at process exit — the idle-tax attribution
/// tool: a virtual-time test suite should spend ~0 here.
pub const SleepSite = enum { timer_wall, wakeup_pending, barrier_yield, root_parked };
var sleep_counts = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** 4;
fn countSleep(site: SleepSite) void {
    _ = sleep_counts[@intFromEnum(site)].fetchAdd(1, .monotonic);
}

/// Consecutive wall-timer idle rounds; a progress point that ends a long
/// streak reports its source under KLIO_PUMP_DIAG so the real wake channel
/// is attributable.
var wall_streak: u64 = 0;
var streak_diag: ?bool = null;
fn streakDiagOn() bool {
    if (streak_diag == null) streak_diag = runtime.getenvSlice("KLIO_PUMP_DIAG") != null;
    return streak_diag.?;
}
fn endStreak(source: []const u8) void {
    if (wall_streak >= 50 and streakDiagOn())
        std.debug.print("[pump-streak] {d} idle rounds ended by {s}\n", .{ wall_streak, source });
    wall_streak = 0;
}
/// Wall-mode timer registrations bucketed by requested delay (<=1ms, <=20ms,
/// <=200ms, <=2s, >2s): attribution for the real-wait tax.
var wall_delay_buckets = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** 5;
fn countWallDelay(millis: i64) void {
    const idx: usize = if (millis <= 1) 0 else if (millis <= 20) 1 else if (millis <= 200) 2 else if (millis <= 2000) 3 else 4;
    _ = wall_delay_buckets[idx].fetchAdd(1, .monotonic);
    if (millis > 2000 and streakDiagOn())
        std.debug.print("[wall-timer] registered {d}ms\n", .{millis});
}
pub fn dumpSleepCounts() void {
    std.debug.print("[pump-sleep] timer_wall={d} wakeup_pending={d} barrier_yield={d} root_parked={d} | wall delays <=1ms={d} <=20ms={d} <=200ms={d} <=2s={d} >2s={d}\n", .{
        sleep_counts[0].load(.monotonic),
        sleep_counts[1].load(.monotonic),
        sleep_counts[2].load(.monotonic),
        sleep_counts[3].load(.monotonic),
        wall_delay_buckets[0].load(.monotonic),
        wall_delay_buckets[1].load(.monotonic),
        wall_delay_buckets[2].load(.monotonic),
        wall_delay_buckets[3].load(.monotonic),
        wall_delay_buckets[4].load(.monotonic),
    });
}

/// Cross-thread wakeup primitive shared between a `runBlocking` driver
/// and any worker threads it has dispatched via `__kxco_dispatch`
/// (real-thread `Dispatchers.Default`). Workers post resume entries
/// into the mailbox and notify; the driver drains the mailbox and parks
/// on the condition when there is no local progress and at least one
/// worker is still outstanding.
///
/// Shared by `ObjRef` handle (atomic strong count) so it is safe to
/// hold from a worker thread while the driver also holds it.
pub const DriverWakeup = struct {
    mailbox: SpinMutex = .{},
    mailbox_entries: std.ArrayList(MailboxEntry) = .empty,
    /// Set under the mailbox lock by the owning driver's exit protocol.
    /// A closed mailbox rejects posts, so a racing resumer falls through
    /// to the persisted-continuation registry the driver populated
    /// strictly before closing — no resume can land in a mailbox nobody
    /// will ever drain again.
    mailbox_closed: bool = false,
    pending_workers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    owned_slots: SpinMutex = .{},
    owned_slot_set: std.ArrayList(i64) = .empty,
    allocator: Allocator,

    pub const MailboxEntry = struct {
        slot: i64,
        value: Value,
    };

    /// Fresh wakeup behind a shared handle.
    pub fn new(allocator: Allocator) Allocator.Error!ObjRef(DriverWakeup) {
        return ObjRef(DriverWakeup).init(allocator, .{ .allocator = allocator });
    }

    pub fn deinit(self: *DriverWakeup) void {
        self.mailbox_entries.deinit(self.allocator);
        self.owned_slot_set.deinit(self.allocator);
    }

    /// GC tracer: a wakeup's mailbox holds resume Values not yet delivered.
    pub fn gcTrace(self: *const DriverWakeup, m: *runtime.gc.Marker) void {
        for (self.mailbox_entries.items) |e| e.value.gcMark(m);
    }

    /// GC finalizer (shallow): free the mailbox/owned-slot spines. The mailbox
    /// entries' Values are independent cells swept on their own.
    pub fn gcFinalize(self: *DriverWakeup, gc_alloc: std.mem.Allocator) void {
        _ = gc_alloc;
        self.mailbox_entries.deinit(self.allocator);
        self.owned_slot_set.deinit(self.allocator);
    }

    /// Post a `(slot, value)` resume entry and wake the driver. Returns
    /// `false` when the mailbox is already closed (the driver exited);
    /// the caller must route the resume through the persisted registry.
    pub fn postResume(self: *DriverWakeup, slot: i64, value: Value) Allocator.Error!bool {
        self.mailbox.lock();
        defer self.mailbox.unlock();
        if (self.mailbox_closed) return false;
        try self.mailbox_entries.append(self.allocator, .{ .slot = slot, .value = value });
        return true;
    }

    /// Take everything queued in the mailbox.
    pub fn drainMailbox(self: *DriverWakeup, allocator: Allocator) Allocator.Error![]MailboxEntry {
        self.mailbox.lock();
        defer self.mailbox.unlock();
        const out = try self.mailbox_entries.toOwnedSlice(allocator);
        self.mailbox_entries = .empty;
        return out;
    }

    /// Close the mailbox and take whatever raced in. Part of the driver
    /// exit protocol: persist parked continuations first, then close, so
    /// every later resume routes to the persisted registry.
    pub fn closeAndDrain(self: *DriverWakeup, allocator: Allocator) Allocator.Error![]MailboxEntry {
        self.mailbox.lock();
        defer self.mailbox.unlock();
        self.mailbox_closed = true;
        const out = try self.mailbox_entries.toOwnedSlice(allocator);
        self.mailbox_entries = .empty;
        return out;
    }

    pub fn pending(self: *DriverWakeup) usize {
        return self.pending_workers.load(.acquire);
    }

    pub fn workerStarted(self: *DriverWakeup) void {
        _ = self.pending_workers.fetchAdd(1, .acq_rel);
    }

    pub fn workerDone(self: *DriverWakeup) void {
        _ = self.pending_workers.fetchSub(1, .acq_rel);
    }

    pub fn addOwnedSlot(self: *DriverWakeup, slot: i64) Allocator.Error!void {
        self.owned_slots.lock();
        defer self.owned_slots.unlock();
        for (self.owned_slot_set.items) |s| {
            if (s == slot) return;
        }
        try self.owned_slot_set.append(self.allocator, slot);
    }

    /// Drop every `SLOT_OWNERS` entry this driver owns, returning its
    /// owned-slot set to empty.
    pub fn releaseOwnedSlots(self: *DriverWakeup) void {
        self.owned_slots.lock();
        const slots = self.owned_slot_set;
        self.owned_slot_set = .empty;
        self.owned_slots.unlock();
        defer {
            var s = slots;
            s.deinit(self.allocator);
        }
        SlotOwners.mutex.lock();
        defer SlotOwners.mutex.unlock();
        if (SlotOwners.map) |*m| {
            for (slots.items) |s| {
                if (m.fetchRemove(s)) |kv| {
                    kv.value.deinit();
                }
            }
        }
    }
};

/// Process-global slot → owning `DriverWakeup` registry. A worker
/// thread routes its completion resume back through the driver that
/// owns the slot it parked on. The map's spine is `page_allocator`-
/// backed (it must outlive any one run's allocator while workers route
/// through it), but the `ObjRef(DriverWakeup)` clones it holds reach
/// into the per-run value graph, so the registry is tied to the run:
/// `drainAll` empties it and frees the spine capacity at the run
/// boundary (after every worker has joined), so no entry can survive a
/// run to dangle into the next run's reset/reused arena. Live entries
/// are dropped on `unregisterSlot` / `releaseOwnedSlots`; `drainAll` is
/// the defensive sweep that covers the error/abort/cancel paths where
/// neither ran.
const SlotOwners = struct {
    var mutex: SpinMutex = .{};
    var map: ?std.AutoHashMap(i64, ObjRef(DriverWakeup)) = null;
    /// Resumes that arrived before their slot had an owner. A waiter
    /// publishes itself to a rendezvous registry (a channel waiter
    /// queue, a completion handler) before arming its slot; a resume
    /// landing in that gap finds no owner and no persisted state and
    /// must not be dropped — it parks here, and `registerSlotOwner`
    /// re-checks under the same mutex, so exactly one of the two sides
    /// always sees the other.
    var pending: ?std.AutoHashMap(i64, Value) = null;

    /// Allocator backing the process-global registry spine.
    fn allocator() Allocator {
        return std.heap.page_allocator;
    }

    /// The live registry map, created on first use.
    fn ensure() Allocator.Error!*std.AutoHashMap(i64, ObjRef(DriverWakeup)) {
        if (map == null) {
            map = std.AutoHashMap(i64, ObjRef(DriverWakeup)).init(allocator());
        }
        return &map.?;
    }

    /// Stash an undeliverable resume for `slot`, unless an owner has
    /// appeared — the registration check and the stash are one atomic
    /// section against `registerSlotOwner`. Returns whether the value
    /// was stashed (`false` ⇒ the caller must retry the owner route).
    fn stashPendingIfUnowned(slot: i64, value: Value) Allocator.Error!bool {
        mutex.lock();
        defer mutex.unlock();
        if (map) |*m| {
            if (m.contains(slot)) return false;
        }
        if (pending == null) {
            pending = std.AutoHashMap(i64, Value).init(allocator());
        }
        try pending.?.put(slot, value);
        return true;
    }

    /// Drop every entry and free the map's spine. Run at the run
    /// boundary once all workers have joined, so a slot left registered
    /// by an error/abort/cancel path (whose `DriverWakeup` cell is
    /// arena-backed) cannot survive into the next run's reset arena.
    /// Pending resumes are arena-keyed Values and sweep with it.
    fn drainAll() void {
        mutex.lock();
        defer mutex.unlock();
        if (map) |*m| {
            var it = m.valueIterator();
            while (it.next()) |w| w.deinit();
            m.deinit();
            map = null;
        }
        if (pending) |*p| {
            p.deinit();
            pending = null;
        }
    }
};

/// Empty the process-global slot-owner registry. Called at the run
/// boundary from `joinAllThreads` (the top-level driver thread, after
/// every worker has joined) so the registry never holds a clone of an
/// arena-backed `DriverWakeup` into the next run's reset arena. Balances
/// `registerSlotOwner` on every path the per-driver `releaseOwnedSlots`
/// misses (error, abort, cancellation, worker-error). Not called from the
/// per-thread `resetReceiverTls`: that also runs on worker threads, which
/// must not tear down the registry the live driver is still routing through.
pub fn drainSlotOwners() void {
    SlotOwners.drainAll();
}

/// Process-global slot → persisted `SuspendState` registry. A coroutine
/// that parks indefinitely inside a driven root outlives the driver that
/// started it (the `startCoroutine` boundary, and every dispatcher pool
/// task whose body suspends awaiting an external event). The state is
/// keyed by its rendezvous slot here so a later `Continuation.resume`
/// from ANY thread — the runBlocking driver, another pool worker, a
/// `kotlin.concurrent.thread` body — can claim it (single winner via
/// `fetchRemove` under the mutex) and drive it to completion on the
/// resuming thread. This is what lets a coroutine hop between OS threads:
/// it parks on worker A, A's pump exits and persists it, and the resume
/// dispatched to worker B claims and continues it there.
///
/// The map spine is `page_allocator`-backed; the `SuspendState` payloads
/// reach into the run's value graph, so the registry is swept at the run
/// boundary (`drainPersistedParked` from `joinAllThreads`) exactly like
/// `SlotOwners`.
const PersistedParked = struct {
    /// A cross-pump parked activation: its frames plus the per-activation
    /// scope delta (page-allocator owned, so it can move across threads)
    /// that must be re-established when it resumes on whatever pump claims
    /// its slot.
    const Entry = struct {
        state: SuspendState,
        scope_delta: []Value = &.{},
    };

    var mutex: SpinMutex = .{};
    var map: ?std.AutoHashMap(i64, Entry) = null;

    fn allocator() Allocator {
        return std.heap.page_allocator;
    }

    fn put(slot: i64, state: SuspendState, scope_delta: []Value) Allocator.Error!void {
        if (pumpDiagEnabled()) {
            std.debug.print("[tok] persist slot={d} frames={d}:", .{ slot, state.frames.items.len });
            for (state.frames.items) |*fr| std.debug.print(" #{d}@{d}:{d}/{x}", .{ fr.func.int(), fr.block.int(), fr.inst_idx, fr.regs.ptrIdentity() });
            var seg = state.tails;
            while (seg) |t| : (seg = t.next) {
                std.debug.print(" |tail", .{});
                var i = t.head;
                while (i < t.frames.items.len) : (i += 1) {
                    const fr2 = &t.frames.items[i];
                    std.debug.print(" #{d}@{d}:{d}/{x}", .{ fr2.func.int(), fr2.block.int(), fr2.inst_idx, fr2.regs.ptrIdentity() });
                }
            }
            std.debug.print("\n", .{});
        }
        mutex.lock();
        defer mutex.unlock();
        if (map == null) {
            map = std.AutoHashMap(i64, Entry).init(allocator());
        }
        try map.?.put(slot, .{ .state = state, .scope_delta = scope_delta });
    }

    /// Claim the persisted entry for `slot`. Single winner.
    fn take(slot: i64) ?Entry {
        mutex.lock();
        defer mutex.unlock();
        if (map) |*m| {
            if (m.fetchRemove(slot)) |kv| return kv.value;
        }
        return null;
    }

    fn drainAll() void {
        mutex.lock();
        defer mutex.unlock();
        if (map) |*m| {
            var it = m.valueIterator();
            while (it.next()) |e| {
                if (e.scope_delta.len != 0) allocator().free(e.scope_delta);
            }
            m.deinit();
            map = null;
        }
    }
};

/// Empty the persisted-continuation registry at the run boundary (after
/// every worker has joined). A state left behind belongs to a coroutine
/// whose resume never came; its frames are arena-backed and must not
/// survive into the next run's reset arena.
pub fn drainPersistedParked() void {
    PersistedParked.drainAll();
}

/// Process-global virtual-time barrier coordinating the independent
/// per-pump logical clocks under `TimeMode.Virtual`. A `runBlocking`
/// driver and every coroutine it dispatches onto a `Dispatchers.Default`
/// worker each run their own `CooperativeInterceptor` with its own
/// `virtual_now`; left uncoordinated, a dispatched child's clock races
/// ahead of its parent's and fires the child's `delay` before the parent
/// has even reached the `delay`/`cancel` that should preempt it (a
/// cross-pump cancellation lost to a future timer). Real kotlinx shares a
/// single monotonic clock across dispatchers; this barrier restores that
/// ordering for the virtual clock: a pump may jump its clock to a *future*
/// timer at time `t` only once no other live virtual pump is parked on an
/// earlier timer that could post a cross-pump resume effective before `t`.
/// A pump publishes a "floor" — its soonest parked timer — only while it
/// actually holds a future timer; a pump with no virtual timer (running a
/// body, blocked in a real `Thread.sleep`, or awaiting an external resume)
/// is implicitly `INDEFINITE` and never holds the global clock back.
/// Registration is lazy (`UNREGISTERED` until the first finite publish),
/// so the vast majority of pumps — every timer-free dispatcher task —
/// never touch the global lock. A timer already due at the current instant
/// (`yield`) is ready-now work and fires without consulting the barrier.
const VirtualClock = struct {
    const Slot = struct {
        id: u64,
        /// Earliest virtual time this pump may still act at. `INDEFINITE`
        /// when the pump has only indefinitely-parked work (it can be
        /// resumed only by an external event, never by the clock, so it
        /// never holds the global minimum back).
        floor: i64,
    };

    /// Sentinel for a pump that has never published a finite floor and so
    /// is not in `slots`. The overwhelming majority of pumps — every
    /// dispatcher task with no `delay`, every `Thread.sleep` body — never
    /// touch a virtual timer, so registration is lazy: a pump joins the
    /// barrier only the first time it would publish a finite deadline.
    /// This keeps heavy fan-out workloads (hundreds of short-lived
    /// `Dispatchers.Default` tasks) entirely off the single global lock.
    const UNREGISTERED: u64 = 0;

    var mutex: SpinMutex = .{};
    var slots: std.ArrayList(Slot) = .empty;
    var next_id: u64 = 1;
    /// The shared logical clock. Every virtual pump measures `delay`
    /// deadlines from this single monotonic value, and a pump that resumes
    /// on a fresh interceptor (a cross-pump hop) seeds its `virtual_now`
    /// from it, so accumulated virtual time is never lost across the hop.
    /// Only ever advances; reset at the run boundary by `drainAll`.
    var now: i64 = 0;
    /// Count of dispatched pool tasks that have started running but whose
    /// pump has not yet published any barrier floor (it is still executing
    /// toward its first suspension). Such a task holds no floor, so the
    /// per-pump floor comparison cannot order it; a top-level driver must not
    /// advance virtual time while any is in flight, lest it fire a timer
    /// ahead of a sibling that will park on a sooner one (or fail and cancel
    /// the driver's job). A task that has published a floor — even a future
    /// one it is now barrier-parked on — no longer counts here; the floor
    /// mechanism orders it, so the gate cannot deadlock against it.
    var pool_unsettled: usize = 0;

    fn allocator() Allocator {
        return std.heap.page_allocator;
    }

    fn enterUnsettled() void {
        mutex.lock();
        defer mutex.unlock();
        pool_unsettled += 1;
    }

    fn settle() void {
        mutex.lock();
        defer mutex.unlock();
        if (pool_unsettled != 0) pool_unsettled -= 1;
    }

    fn hasUnsettled() bool {
        mutex.lock();
        defer mutex.unlock();
        return pool_unsettled != 0;
    }

    /// Current shared virtual time. A new or resuming pump starts here.
    fn currentNow() i64 {
        mutex.lock();
        defer mutex.unlock();
        return now;
    }

    /// Advance the shared clock to `t` (a future timer a pump is firing).
    /// Monotonic: a stale lower value never moves it back.
    fn advanceNow(t: i64) void {
        mutex.lock();
        defer mutex.unlock();
        if (t > now) now = t;
    }

    /// Lazily join the barrier with an initial finite floor. Returns the
    /// pump's id (`UNREGISTERED` only on OOM, treated as "never holds the
    /// clock back").
    fn registerWith(floor: i64) u64 {
        mutex.lock();
        defer mutex.unlock();
        const id = next_id;
        next_id += 1;
        slots.append(allocator(), .{ .id = id, .floor = floor }) catch return UNREGISTERED;
        return id;
    }

    fn unregister(id: u64) void {
        if (id == UNREGISTERED) return;
        mutex.lock();
        defer mutex.unlock();
        for (slots.items, 0..) |s, i| {
            if (s.id == id) {
                _ = slots.swapRemove(i);
                return;
            }
        }
    }

    fn publish(id: u64, floor: i64) void {
        if (id == UNREGISTERED) return;
        mutex.lock();
        defer mutex.unlock();
        for (slots.items) |*s| {
            if (s.id == id) {
                s.floor = floor;
                return;
            }
        }
    }

    /// True if `clock_id` belongs to a pump on the CURRENT thread's
    /// interceptor stack. Same-thread pumps are strictly nested: a lower one
    /// is a frozen ancestor of the caller (a `coroutineScope`/`withTimeout`/
    /// nested-`runBlocking` boundary), never concurrent with it. A frozen
    /// pump cannot run to post a cross-pump resume that preempts another's
    /// timer, so it must not hold the barrier against a same-thread pump
    /// driving above it — otherwise the ancestor's stale floor deadlocks the
    /// child's virtual-clock advance (each waits for the other forever).
    /// `coro_stack` is thread-local, so this reads only this thread's pumps.
    fn onCurrentThreadStack(clock_id: u64) bool {
        if (clock_id == UNREGISTERED) return false;
        for (coro_stack.items) |*p| {
            if (p.clock_id == clock_id) return true;
        }
        return false;
    }

    /// The minimum floor across every registered pump *other* than `id` and
    /// other than this thread's frozen ancestors (see `onCurrentThreadStack`).
    /// `null` when no such pump has a finite floor: the caller is free to
    /// advance to its own timer.
    fn minOtherFloor(id: u64) ?i64 {
        mutex.lock();
        defer mutex.unlock();
        var m: ?i64 = null;
        for (slots.items) |s| {
            if (s.id == id) continue;
            if (onCurrentThreadStack(s.id)) continue;
            if (s.floor == INDEFINITE) continue;
            if (m == null or s.floor < m.?) m = s.floor;
        }
        return m;
    }

    /// Whether a pump holding token `id`, idle with its soonest timer at
    /// `t`, may fire it now. It may unless another live pump still has a
    /// floor strictly below `t` (that pump runs first and may post a
    /// cross-pump resume that preempts this timer).
    fn mayFire(id: u64, t: i64) bool {
        const other = minOtherFloor(id) orelse return true;
        return other >= t;
    }

    /// Diagnostic: the shared clock, the unsettled-pool count, and every
    /// registered pump's published floor. A caught pump hang uses this to
    /// tell whether an advance is barrier-blocked (a sibling floor below the
    /// timer) or gate-blocked (an unsettled pool task).
    fn dumpState() void {
        mutex.lock();
        defer mutex.unlock();
        std.debug.print("[PUMP] vclock now={d} pool_unsettled={d} slots={d}:", .{ now, pool_unsettled, slots.items.len });
        for (slots.items) |s| {
            if (s.floor == INDEFINITE) {
                std.debug.print(" clk{d}=INDEF", .{s.id});
            } else {
                std.debug.print(" clk{d}={d}", .{ s.id, s.floor });
            }
        }
        std.debug.print("\n", .{});
    }

    /// Clear every registered pump at a run boundary. Pumps unregister
    /// themselves at `deinit`, so this is normally a no-op; it drops
    /// anything an error path left behind so a stale floor cannot hold the
    /// next run's pumps back.
    fn drainAll() void {
        mutex.lock();
        defer mutex.unlock();
        slots.clearAndFree(allocator());
        now = 0;
        pool_unsettled = 0;
    }
};

/// Whether the pool task running on this thread still counts as "unsettled"
/// (its pump has not yet published any barrier floor). Armed by `poolTaskRun`
/// when a task that was counted at dispatch begins; the first `publishFloor`
/// on this thread, or `poolTaskRun`'s `defer` if the task never published,
/// clears it (settling the global count exactly once per dispatched task).
threadlocal var pool_task_unsettled: bool = false;

/// Settle the pool task running on the calling thread, if it is still
/// unsettled. Installed as the runtime wall-block hook so a dispatched task
/// entering a real `Thread.sleep` (wall work, not a virtual suspension)
/// releases its virtual-clock claim instead of holding a top-level driver
/// across the whole sleep.
fn wallBlockSettle() void {
    if (pool_task_unsettled) {
        pool_task_unsettled = false;
        VirtualClock.settle();
    }
}

var wall_hook_installed = std.atomic.Value(bool).init(false);

/// Count a coroutine dispatched onto the pool as "unsettled" from the moment
/// it is posted: a top-level driver must not advance virtual time across the
/// window between dispatch and the task establishing its barrier floor. Paired
/// with `poolTaskSettleDropped` (task never ran) or the task's first
/// `publishFloor` / `poolTaskRun` end (task ran). No-op under wall time.
pub fn poolTaskDispatched() void {
    if (root.coroutineTimeMode() != .Virtual) return;
    if (!wall_hook_installed.swap(true, .monotonic)) {
        runtime.setWallBlockHook(wallBlockSettle);
    }
    VirtualClock.enterUnsettled();
}

/// Settle a dispatched task that was dropped before running (pool stopping).
pub fn poolTaskSettleDropped() void {
    if (root.coroutineTimeMode() != .Virtual) return;
    VirtualClock.settle();
}

/// Run-time bracket for a pool task body: arm the per-thread unsettled flag so
/// the first `publishFloor` settles this task's dispatch count, and settle on
/// return if the body never published (a synchronous body or immediate throw).
pub fn poolTaskRunBegin() void {
    pool_task_unsettled = root.coroutineTimeMode() == .Virtual;
}

pub fn poolTaskRunEnd() void {
    if (pool_task_unsettled) {
        pool_task_unsettled = false;
        VirtualClock.settle();
    }
}

/// Clear the process-global virtual-clock barrier at a run boundary.
pub fn drainVirtualClock() void {
    VirtualClock.drainAll();
}

/// Register `slot` → `wakeup` so a worker thread's completion resume
/// routes back through the driver's mailbox.
pub fn registerSlotOwner(slot: i64, wakeup: *const ObjRef(DriverWakeup)) Allocator.Error!void {
    // Registering the slot makes this `DriverWakeup` reachable from the
    // process-global `SlotOwners` map, where a `Dispatchers.Default`/`IO`
    // worker thread will `lookupSlotOwner` it and `borrowMut` to post a
    // completion resume, concurrently with this driver's pump borrowing
    // it in `drainWakeupInto`/`pending`. The cell's reader/writer lock
    // mediates those concurrent borrows; the registry insert below is
    // sequenced after the slot is recorded on the cell.
    {
        const w = wakeup.borrowMut();
        defer w.deinit();
        try w.get().addOwnedSlot(slot);
    }
    const pending_resume: ?Value = blk: {
        SlotOwners.mutex.lock();
        defer SlotOwners.mutex.unlock();
        const m = try SlotOwners.ensure();
        const gop = try m.getOrPut(slot);
        if (gop.found_existing) gop.value_ptr.deinit();
        gop.value_ptr.* = wakeup.clone();
        // A resume for this slot may already have arrived and parked in
        // the pending stash (the resumer ran in the publish-before-arm
        // gap). Claim it under the same lock that just made the owner
        // visible, so the resumer's miss and this claim cannot cross.
        if (SlotOwners.pending) |*p| {
            if (p.fetchRemove(slot)) |kv| break :blk kv.value;
        }
        break :blk null;
    };
    if (pending_resume) |v| {
        // Deliver through the owner's own mailbox: the pump drains it on
        // its next idle round, after the activation has actually parked.
        const w = wakeup.borrowMut();
        defer w.deinit();
        _ = try w.get().postResume(slot, v);
    }
}

/// The driver that owns `slot`, if any. The returned handle is an
/// owned clone — the caller must `deinit` it.
pub fn lookupSlotOwner(slot: i64) ?ObjRef(DriverWakeup) {
    SlotOwners.mutex.lock();
    defer SlotOwners.mutex.unlock();
    if (SlotOwners.map) |*m| {
        if (m.get(slot)) |w| return w.clone();
    }
    return null;
}

/// Drop the registry entry for `slot`.
pub fn unregisterSlot(slot: i64) void {
    SlotOwners.mutex.lock();
    defer SlotOwners.mutex.unlock();
    if (SlotOwners.map) |*m| {
        if (m.fetchRemove(slot)) |kv| {
            kv.value.deinit();
        }
    }
}

/// Cooperative interceptor — one per nested `runBlocking` /
/// `coroutineScope`. Holds the park/resume bookkeeping and the
/// virtual-time clock for one driver.
pub const CooperativeInterceptor = struct {
    /// token → (parked activation, virtual-time wakeup; `INDEFINITE` =
    /// only an explicit ready entry resumes it).
    pub const ParkedEntry = struct {
        state: SuspendState,
        wake_at: i64,
        /// The active-scope pushes this activation owns (the
        /// `__klio_co_pushScope` entries it made since it last began
        /// running, captured off the live `active_scope_stack` when it
        /// parked). Restored onto the stack when the activation resumes
        /// so a suspend-implicit `coroutineContext` read *after* the
        /// resume resolves to this coroutine's own scope, not to the
        /// resuming pump's active scope. Page-allocator owned; freed when
        /// the entry is taken (`takeParked`) or dropped. Empty when the
        /// activation held no scope of its own.
        scope_delta: []Value = &.{},
    };

    /// Cross-thread wakeup. Shared with worker threads dispatched from
    /// this driver and with `SLOT_OWNERS` entries for any slot this
    /// driver owns. Workers post completion resumes through it.
    wakeup: ObjRef(DriverWakeup),
    mode: TimeMode,
    /// Wall-clock origin in nanoseconds; `delay` deadlines are measured
    /// from here. Set lazily on first use so an all-virtual run never
    /// reads the clock.
    started: ?i128,
    next_token: u64,
    virtual_now: i64,
    /// This pump's id in the process-global `VirtualClock` barrier, or
    /// `VirtualClock.UNREGISTERED` until it first publishes a finite floor.
    /// Coordinates clock jumps with every other live virtual pump so a
    /// dispatched child's logical clock cannot run ahead of its parent's.
    clock_id: u64,
    /// The floor value last written to the global `VirtualClock` for this
    /// pump. The barrier is republished only when the floor actually
    /// changes, so an idle pump waiting on an external resume (the common
    /// case: every `Dispatchers.Default` await) does not hammer the global
    /// barrier lock once per pump round — that contention alone, with tens
    /// of concurrent pumps, serialised the whole runtime.
    published_floor: i64,
    parked: std.AutoHashMap(u64, ParkedEntry),
    /// FIFO of tokens whose wakeup is due (timer fired or yielded).
    ready: std.ArrayList(u64),
    /// Child `launch` blocks queued during the active scope.
    launched: std.ArrayList(Value),
    /// `withTimeout` timeout-gate blocks (`invokeOnTimeout`) scheduled on
    /// THIS pump while its body was executing. A gate cancels the timed
    /// block, so it must share the block's timer queue — but the block runs
    /// as its OWN nested pump (an undispatched `startCoroutineUnintercepted…`
    /// split). `coroutineStartRootOrSuspended` claims a parent's pending
    /// gates and, once it sees the block actually suspend, commits them onto
    /// the block's (child) pump so the earliest deadline across the two
    /// timers fires first. A gate no nested block claims (e.g. a bare
    /// `select { onTimeout(…) }`) is promoted into `launched` by the pump
    /// loop and runs on this pump as an ordinary timer.
    timeout_launched: std.ArrayList(Value),
    /// Set by `__kxco_parkSlot` immediately before the activation
    /// unwinds with an indefinite suspend; consumed by the next
    /// `interceptSuspend` to bind that token to the slot.
    pending_slot: ?i64,
    /// slot id → token of the activation parked on that slot.
    slot_to_token: std.AutoHashMap(i64, u64),
    /// token → value the activation should observe as the result of its
    /// suspending call when resumed. Absent ⇒ resume with `Unit`.
    token_resume_value: std.AutoHashMap(u64, Value),
    /// This pump's root activation while it is parked; an inline resume never
    /// steals it (the pump publishes the root's value and stops on it).
    root_tok: ?u64 = null,
    /// Set once a native channel delivery to one of this pump's waiters routed
    /// through an external dispatcher's queue (`__kxco_chanResumeRoute` code 1 —
    /// a `runTest` `TestCoroutineScheduler`). Such a pump orders its dispatched
    /// resumes on that scheduler, not `drv.ready`, so the inline-resume FIFO
    /// deferral (`ownerReadyPending`) must stay off for it.
    scheduler_backed: bool = false,
    /// A failure raised by an activation this pump owns that ran INLINE (on a
    /// resumer's stack, outside the drive loop). The loop cannot see it there,
    /// so it is left here and raised on the next turn, exactly as if the loop
    /// had run the activation itself.
    pending_err: ?EvalError = null,
    allocator: Allocator,

    /// Fresh interceptor honoring this thread's time mode. Under `Virtual`
    /// it seeds `virtual_now` from the shared logical clock so a coroutine
    /// resuming on a fresh pump (a cross-pump hop) keeps the virtual time
    /// already elapsed — its next `delay` is measured from there, not 0.
    pub fn new(allocator: Allocator) Allocator.Error!CooperativeInterceptor {
        const mode = root.coroutineTimeMode();
        return .{
            .wakeup = try DriverWakeup.new(allocator),
            .mode = mode,
            .started = null,
            .next_token = 0,
            .virtual_now = if (mode == .Virtual) VirtualClock.currentNow() else 0,
            // Join the barrier lazily (on the first finite-floor publish),
            // so timer-free pumps never touch the global lock.
            .clock_id = VirtualClock.UNREGISTERED,
            .published_floor = INDEFINITE,
            .parked = std.AutoHashMap(u64, ParkedEntry).init(allocator),
            .ready = .empty,
            .launched = .empty,
            .timeout_launched = .empty,
            .pending_slot = null,
            .slot_to_token = std.AutoHashMap(i64, u64).init(allocator),
            .token_resume_value = std.AutoHashMap(u64, Value).init(allocator),
            .allocator = allocator,
        };
    }

    /// GC: mark every Value this driver keeps live — its wakeup mailbox, every
    /// parked activation's frames + scope delta, the queued `launch` blocks, and
    /// the resume values waiting to be delivered.
    pub fn gcMark(self: *CooperativeInterceptor, m: *runtime.gc.Marker) void {
        m.shade(&self.wakeup.cell.hdr);
        var pit = self.parked.valueIterator();
        while (pit.next()) |e| {
            ir.eval.gcMarkSuspendState(&e.state, m);
            for (e.scope_delta) |v| v.gcMark(m);
        }
        for (self.launched.items) |v| v.gcMark(m);
        for (self.timeout_launched.items) |v| v.gcMark(m);
        var rit = self.token_resume_value.valueIterator();
        while (rit.next()) |v| v.gcMark(m);
    }

    pub fn deinit(self: *CooperativeInterceptor) void {
        VirtualClock.unregister(self.clock_id);
        self.wakeup.deinit();
        // Free the page-allocator scope deltas held by any still-parked
        // activation (a pump abandoning parked coroutines at exit) before
        // dropping the map spine.
        {
            var it = self.parked.valueIterator();
            while (it.next()) |e| {
                if (e.scope_delta.len != 0) coroStackAllocator().free(e.scope_delta);
            }
        }
        self.parked.deinit();
        self.ready.deinit(self.allocator);
        // Release any blocks still queued (never drained) so the queue's owned
        // references do not leak when the interceptor is torn down.
        if (runtime.reclaimEnabled()) for (self.launched.items) |b| b.release(self.allocator);
        self.launched.deinit(self.allocator);
        if (runtime.reclaimEnabled()) for (self.timeout_launched.items) |b| b.release(self.allocator);
        self.timeout_launched.deinit(self.allocator);
        self.slot_to_token.deinit();
        self.token_resume_value.deinit();
    }

    /// Current clock reading in millis: the logical clock under
    /// `Virtual`, elapsed wall-clock since first use under `Wall`.
    pub fn nowMillis(self: *CooperativeInterceptor) i64 {
        switch (self.mode) {
            .Virtual => return self.virtual_now,
            .Wall => {
                const start = self.started orelse blk: {
                    const now = monotonicNanos();
                    self.started = now;
                    break :blk now;
                };
                const elapsed_ns = monotonicNanos() - start;
                return @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
            },
        }
    }

    /// Seam: intercept a freshly-suspended activation. Assigns a token,
    /// decodes the Layer-2 resume directive carried in `wake_in_millis`
    /// (negative = park indefinitely, `0` = ready now, positive = wake
    /// that much later on the active clock), and records it. Returns the
    /// token so the driver can recognise the root's completion.
    pub fn interceptSuspend(self: *CooperativeInterceptor, state_in: SuspendState, scope_delta: []Value) Allocator.Error!u64 {
        var state = state_in;
        self.next_token += 1;
        const token = self.next_token;
        state.token = token;
        const wake_at = if (state.wake_in_millis < 0)
            INDEFINITE
        else
            self.nowMillis() + state.wake_in_millis;
        if (self.mode == .Wall and state.wake_in_millis > 0) {
            countWallDelay(state.wake_in_millis);
            if (state.wake_in_millis > 2000 and streakDiagOn())
                std.debug.print("[wall-timer] slot_bound={}\n", .{self.pending_slot != null});
        }
        if (state.wake_in_millis == 0) {
            try self.ready.append(self.allocator, token);
        }
        // Bind an armed slot to *any* parked activation, not only
        // indefinite parks. `suspendCoroutineUninterceptedOrReturn`
        // arms its slot before running its block; if the block suspends
        // on a *timed* `delay` (e.g. inside `withTimeout`), the
        // activation must stay reachable through the slot so a later
        // cancellation can resume it early with the exception instead of
        // waiting out the timer.
        if (self.pending_slot) |slot| {
            self.pending_slot = null;
            try self.slot_to_token.put(slot, token);
        }
        try self.parked.put(token, .{ .state = state, .wake_at = wake_at, .scope_delta = scope_delta });
        return token;
    }

    /// Adopt a persisted parked activation into THIS pump, ready to run
    /// with `value` as its resume — the resume-chain flattener. A resume
    /// targeting a persisted coroutine while a pump is live on this
    /// thread must not nest a fresh drive inside the current activation:
    /// each unwind hop would stack a whole native driver (DeepRecursive's
    /// trampoline unwinds thousands of hops). Adopted here, the pump loop
    /// drives it after the current activation completes, exactly like a
    /// slot-owned resume. The entry takes ownership of `scope_delta`.
    pub fn adoptPersisted(self: *CooperativeInterceptor, state_in: SuspendState, scope_delta: []Value, value: Value) Allocator.Error!void {
        var state = state_in;
        self.next_token += 1;
        const token = self.next_token;
        state.token = token;
        if (pumpDiagEnabled()) {
            std.debug.print("[tok] adopt tok={d} frames={d}:", .{ token, state.frames.items.len });
            for (state.frames.items) |*fr| std.debug.print(" #{d}@{d}:{d}/{x}", .{ fr.func.int(), fr.block.int(), fr.inst_idx, fr.regs.ptrIdentity() });
            var seg = state.tails;
            while (seg) |t| : (seg = t.next) {
                std.debug.print(" |tail", .{});
                var i = t.head;
                while (i < t.frames.items.len) : (i += 1) {
                    const fr2 = &t.frames.items[i];
                    std.debug.print(" #{d}@{d}:{d}/{x}", .{ fr2.func.int(), fr2.block.int(), fr2.inst_idx, fr2.regs.ptrIdentity() });
                }
            }
            std.debug.print("\n", .{});
        }
        try self.parked.put(token, .{ .state = state, .wake_at = INDEFINITE, .scope_delta = scope_delta });
        try self.token_resume_value.put(token, value);
        try self.ready.append(self.allocator, token);
    }

    /// Seam: record the slot the next indefinitely-parked activation is
    /// waiting on (set by `__kxco_parkSlot`). Also registers the slot →
    /// driver mapping so a worker thread can route its completion resume
    /// back through the driver's mailbox.
    pub fn setPendingSlot(self: *CooperativeInterceptor, slot: i64) Allocator.Error!void {
        self.pending_slot = slot;
        try registerSlotOwner(slot, &self.wakeup);
    }

    pub fn clearPendingSlot(self: *CooperativeInterceptor) void {
        self.pending_slot = null;
    }

    /// Seam: if a token is waiting on `slot`, move it into the ready
    /// queue and clear the mapping. Returns whether a waiter was found.
    pub fn resumeSlot(self: *CooperativeInterceptor, slot: i64) Allocator.Error!bool {
        if (self.slot_to_token.fetchRemove(slot)) |kv| {
            unregisterSlot(slot);
            try self.ready.append(self.allocator, kv.value);
            return true;
        }
        return false;
    }

    /// Like `resumeSlot` but records `value` so the resumed activation
    /// observes it as its suspending call's result.
    pub fn resumeSlotValue(self: *CooperativeInterceptor, slot: i64, value: Value) Allocator.Error!bool {
        if (self.slot_to_token.fetchRemove(slot)) |kv| {
            unregisterSlot(slot);
            try self.token_resume_value.put(kv.value, value);
            try self.ready.append(self.allocator, kv.value);
            return true;
        }
        return false;
    }

    /// Claim the activation parked on `slot` for an INLINE resume: take the
    /// parked entry and unbind the slot, without queueing it. Null when this
    /// pump does not hold the slot, when the token is not actually parked
    /// (already queued or running — unbinding then would drop the resume), or
    /// when it is this pump's own root, whose completion the pump owns.
    pub fn claimSlotForInline(self: *CooperativeInterceptor, slot: i64) ?ParkedEntry {
        const tok = self.slot_to_token.get(slot) orelse return null;
        if (self.root_tok != null and self.root_tok.? == tok) return null;
        const entry = self.parked.fetchRemove(tok) orelse return null;
        _ = self.slot_to_token.remove(slot);
        unregisterSlot(slot);
        return entry.value;
    }

    /// Take the pending resume value for `token`, if one was set by
    /// `resumeSlotValue`.
    pub fn takeResumeValue(self: *CooperativeInterceptor, token: u64) ?Value {
        if (self.token_resume_value.fetchRemove(token)) |kv| return kv.value;
        return null;
    }

    /// Remove every indefinitely-parked activation still waiting on a
    /// slot, returning `(slot, state)` pairs. Used by the
    /// `startCoroutine` driver to hand a coroutine that parked awaiting
    /// an external `resume` to program-lifetime storage so it survives
    /// the driver's return. The returned slice is owned by `allocator`.
    pub fn drainIndefiniteParked(self: *CooperativeInterceptor, allocator: Allocator) Allocator.Error![]SlotState {
        var slots: std.ArrayList(SlotToken) = .empty;
        defer slots.deinit(self.allocator);
        var it = self.slot_to_token.iterator();
        while (it.next()) |e| {
            try slots.append(self.allocator, .{ .slot = e.key_ptr.*, .token = e.value_ptr.* });
        }
        var out: std.ArrayList(SlotState) = .empty;
        for (slots.items) |st| {
            const is_indefinite = if (self.parked.get(st.token)) |p| p.wake_at == INDEFINITE else false;
            if (is_indefinite) {
                if (self.parked.fetchRemove(st.token)) |kv| {
                    _ = self.slot_to_token.remove(st.slot);
                    try out.append(allocator, .{ .slot = st.slot, .state = kv.value.state, .scope_delta = kv.value.scope_delta });
                }
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Seam: take the child `launch` blocks queued this round. The
    /// returned slice is owned by `allocator`.
    pub fn drainLaunched(self: *CooperativeInterceptor, allocator: Allocator) Allocator.Error![]Value {
        const out = try self.launched.toOwnedSlice(allocator);
        self.launched = .empty;
        return out;
    }

    /// Seam: queue a child `launch` block. The queue owns one reference to
    /// the block until it is drained and dispatched (`drainLaunched` callers
    /// release it after running it).
    pub fn enqueueLaunch(self: *CooperativeInterceptor, block: Value) Allocator.Error!void {
        if (runtime.reclaimEnabled()) block.retain();
        if (pumpDiagEnabled()) std.debug.print("[tok] enqueueLaunch n={d}\n", .{self.launched.items.len + 1});
        try self.launched.append(self.allocator, block);
    }

    /// Seam: queue a `withTimeout` timeout-gate block (see `timeout_launched`).
    /// The queue owns one reference until the block is claimed and re-homed.
    pub fn enqueueTimeout(self: *CooperativeInterceptor, block: Value) Allocator.Error!void {
        if (runtime.reclaimEnabled()) block.retain();
        try self.timeout_launched.append(self.allocator, block);
    }

    /// Take the pending timeout-gate blocks (owned by `allocator`). Each
    /// carries the reference the enqueue took; the caller re-homes it onto
    /// another pump's `launched` or `timeout_launched` (keeping the retain)
    /// or releases it.
    pub fn drainTimeouts(self: *CooperativeInterceptor, allocator: Allocator) Allocator.Error![]Value {
        const out = try self.timeout_launched.toOwnedSlice(allocator);
        self.timeout_launched = .empty;
        return out;
    }

    /// Move any timeout-gate blocks no nested pump claimed into `launched`,
    /// so the ordinary drain runs them on THIS pump as plain timers (the
    /// bare `select { onTimeout(…) }` path, with no undispatched block to
    /// share a timer queue with). Keeps each block's enqueue reference.
    pub fn promoteTimeouts(self: *CooperativeInterceptor) Allocator.Error!void {
        if (self.timeout_launched.items.len == 0) return;
        for (self.timeout_launched.items) |b| try self.launched.append(self.allocator, b);
        self.timeout_launched.clearRetainingCapacity();
    }

    /// Seam: next ready token, if any.
    pub fn nextReady(self: *CooperativeInterceptor) ?u64 {
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    /// Seam: take the parked activation for a token.
    pub fn takeParked(self: *CooperativeInterceptor, token: u64) ?ParkedEntry {
        if (self.parked.fetchRemove(token)) |kv| {
            if (pumpDiagEnabled()) std.debug.print("[tok] take tok={d}\n", .{token});
            return kv.value;
        }
        if (pumpDiagEnabled()) std.debug.print("[tok] take tok={d} MISSING\n", .{token});
        return null;
    }

    /// Outcome of a time-advance attempt.
    pub const Advance = enum {
        /// At least one timer fired (its token is now ready).
        fired,
        /// No timer to advance to (only indefinite parks, or nothing
        /// parked).
        none,
        /// A timer exists but the process-global virtual-clock barrier is
        /// holding it: another live virtual pump still has earlier work
        /// that may post a cross-pump resume. The caller must keep
        /// draining its mailbox and retry rather than fire or exit.
        blocked,
        /// A Wall timer is pending but not yet due (one sleep slice was
        /// taken). The caller must drain its mailbox before retrying — a
        /// resume posted from this thread (a cancellation handler firing
        /// inside an activation, before its park bound the slot) would
        /// otherwise wait out the whole timer.
        waiting,
    };

    /// Publish `floor` to the global barrier only when it differs from the
    /// last value this pump wrote. Idle pumps overwhelmingly republish the
    /// same floor every round; skipping the no-op write keeps tens of
    /// concurrent pumps off the single barrier lock. A pump joins the
    /// barrier lazily, on its first *finite* floor: while it has no virtual
    /// timer it stays unregistered (implicitly `INDEFINITE`), so a heavy
    /// fan-out of timer-free tasks never touches the global lock.
    fn publishFloor(self: *CooperativeInterceptor, floor: i64) void {
        // Reaching a publish point means this pump's body has parked and the
        // pump is now declaring its barrier position: a dispatched pool task
        // is no longer "unsettled" — its floor (this value) now orders it, so
        // a waiting top-level driver may proceed past the startup gate.
        if (pool_task_unsettled) {
            pool_task_unsettled = false;
            VirtualClock.settle();
        }
        if (self.published_floor == floor) return;
        self.published_floor = floor;
        if (self.clock_id == VirtualClock.UNREGISTERED) {
            if (floor == INDEFINITE) return; // implicitly indefinite already
            self.clock_id = VirtualClock.registerWith(floor);
            return;
        }
        VirtualClock.publish(self.clock_id, floor);
    }

    /// Claim the current shared instant: while this pump has work to run at
    /// `now` (queued launches, ready coroutines) it holds the barrier floor
    /// at the shared clock so no other pump advances virtual time past the
    /// current instant before this pump has reached and parked on its own
    /// timer. Without it, a pump still starting a child that is about to
    /// `delay(d)` would let a sibling pump jump to a *later* timer first,
    /// reordering wakeups (a `delay`-then-`cancel` race that must fire by
    /// ascending deadline across all pumps). No-op outside `Virtual`.
    fn claimNow(self: *CooperativeInterceptor) void {
        if (self.mode != .Virtual) return;
        const shared = VirtualClock.currentNow();
        if (shared > self.virtual_now) self.virtual_now = shared;
        self.publishFloor(self.virtual_now);
    }

    /// Seam: nothing ready — advance the clock to the soonest timer and
    /// arm every activation due then. Under `Virtual` the clock jumps to
    /// the timer once the global barrier permits; under `Wall` the thread
    /// sleeps toward the real deadline.
    pub fn advanceTimeGated(self: *CooperativeInterceptor) Allocator.Error!Advance {
        var soonest: ?i64 = null;
        {
            var it = self.parked.iterator();
            while (it.next()) |e| {
                const w = e.value_ptr.wake_at;
                if (w == INDEFINITE) continue;
                if (soonest == null or w < soonest.?) soonest = w;
            }
        }
        const t = soonest orelse {
            // No finite timer: publish an indefinite floor so this pump
            // never holds another pump's clock back while it waits on an
            // external resume.
            if (self.mode == .Virtual) self.publishFloor(INDEFINITE);
            return .none;
        };
        switch (self.mode) {
            .Virtual => {
                // Catch up to the shared clock first: another pump may have
                // advanced global time past this pump's local view while it
                // was busy. A timer at or before the shared `now` is then
                // ready-now work, fired without a clock jump.
                const shared = VirtualClock.currentNow();
                if (shared > self.virtual_now) self.virtual_now = shared;
                // A timer already due at the current instant (`yield`, an
                // immediate dispatch handshake) is ready-now work, not a
                // clock advance: fire it without consulting the barrier so
                // it cannot deadlock against another pump sitting at the
                // same instant. The barrier only gates a genuine jump into
                // the future, where a still-earlier pump might post a
                // cross-pump resume that should preempt this timer. While
                // this pump holds a due timer its floor stays at the
                // current instant, so a pump with a *future* timer still
                // waits for it.
                if (t > self.virtual_now) {
                    self.publishFloor(t);
                    if (!VirtualClock.mayFire(self.clock_id, t)) return .blocked;
                    // A top-level driver must also wait while a dispatched
                    // pool task it (transitively) launched is still running
                    // toward its first suspension and has not yet published a
                    // barrier floor: that coroutine may park on a sooner timer
                    // — or fail and cancel this driver's job — before this
                    // future timer fires. The floor `t` published above stands
                    // (not lowered to the current instant), so a sibling whose
                    // own sooner timer is below `t` may still advance to it.
                    // Once every such task has published a floor (settled), the
                    // floor mechanism orders them, so the gate cannot deadlock
                    // against a task barrier-parked on a *later* timer.
                    if (!vmhost.scheduler.onPoolWorker() and VirtualClock.hasUnsettled()) {
                        return .blocked;
                    }
                    self.virtual_now = t;
                    VirtualClock.advanceNow(t);
                } else {
                    self.publishFloor(self.virtual_now);
                }
            },
            .Wall => {
                const wait = @max(t - self.nowMillis(), 0);
                if (wait > 0) {
                    // Sleep toward the deadline one millisecond at a
                    // time: the pump must keep draining its cross-thread
                    // mailbox between slices (a resume can preempt the
                    // timer — a cancellation arriving from another pump
                    // must not wait out a parked `delay`) and must keep
                    // observing run-boundary abandonment. `.waiting`
                    // reports the pending timer as progress while sending
                    // the pump through its mailbox drain before the next
                    // round.
                    countSleep(.timer_wall);
                    wall_streak += 1;
                    if (runtime.getenvSlice("KLIO_PUMP_NOSLEEP") == null)
                        sleepMillis(@min(@as(u64, @intCast(wait)), 1));
                    if (self.nowMillis() < t) return .waiting;
                    endStreak("timer-deadline-reached");
                }
            },
        }
        const now = self.nowMillis();
        const Due = struct {
            tok: u64,
            wake_at: i64,
            fn lessThan(_: void, x: @This(), y: @This()) bool {
                if (x.wake_at != y.wake_at) return x.wake_at < y.wake_at;
                return x.tok < y.tok;
            }
        };
        var due: std.ArrayList(Due) = .empty;
        defer due.deinit(self.allocator);
        {
            var it = self.parked.iterator();
            while (it.next()) |e| {
                const w = e.value_ptr.wake_at;
                if (w != INDEFINITE and w <= now) {
                    try due.append(self.allocator, .{ .tok = e.key_ptr.*, .wake_at = w });
                }
            }
        }
        // Fire in DEADLINE order (token order breaks ties): when a slow
        // round leaves several timers due at once, the earliest deadline
        // resumes first, exactly as an event loop would have fired them.
        std.mem.sort(Due, due.items, {}, Due.lessThan);
        for (due.items) |d| {
            try self.ready.append(self.allocator, d.tok);
        }
        return if (due.items.len != 0) .fired else .none;
    }

    /// Arm every DUE Wall-clock deadline (already passed) into the ready
    /// queue without waiting for an idle round. Timers otherwise fire only
    /// when NO coroutine is ready, so a yield-livelocked pair starves
    /// `withTimeout` forever — a real event loop interleaves its timer
    /// queue with its run queue. Queued entries leave timer-land
    /// (`wake_at` cleared) so successive rounds cannot double-queue them.
    pub fn armDueWallTimers(self: *CooperativeInterceptor) Allocator.Error!void {
        if (self.mode != .Wall) return;
        const now = self.nowMillis();
        var it = self.parked.iterator();
        while (it.next()) |e| {
            const w = e.value_ptr.wake_at;
            if (w != INDEFINITE and w <= now) {
                try self.ready.append(self.allocator, e.key_ptr.*);
                e.value_ptr.wake_at = INDEFINITE;
            }
        }
    }

    /// Bool-returning shim over `advanceTimeGated`: progress was made when
    /// a timer fired. A `.blocked` outcome reports no progress (the caller
    /// must keep draining its mailbox), preserving the historical
    /// single-pump contract for callers that do not coordinate the global
    /// clock barrier.
    pub fn advanceTime(self: *CooperativeInterceptor) Allocator.Error!bool {
        return (try self.advanceTimeGated()) == .fired;
    }

    pub const SlotState = struct {
        slot: i64,
        state: SuspendState,
        scope_delta: []Value = &.{},
    };

    const SlotToken = struct {
        slot: i64,
        token: u64,
    };
};

// -------------------------------------------------------------------------
// Layer 2 — the default interceptor's dispatch loop (the engine behind
// `runBlocking`). Drives Layer-1 activations: it never inspects the
// suspend mechanism, only parks / resumes through the interceptor seam.
//
// The loop, its `CooperativeInterceptor` stack, active-scope stack, and
// persisted-park table are all co-located here.
// -------------------------------------------------------------------------

const vmhost = @import("vmhost.zig");
const intrinsic_host = @import("intrinsic_host.zig");
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const Output = runtime.Output;
const RuntimeError = runtime.RuntimeError;
const RuntimeEvalResult = runtime.EvalResult;
const EvalError = ir.eval.EvalError;

/// This thread's coroutine interceptor stack — one entry per nested
/// `runBlocking` / driven root.
/// Backed by the page allocator: the stack itself is thread-lifetime and
/// holds at most a handful of entries; each interceptor's own maps use
/// the run allocator passed to `CooperativeInterceptor.new`.
threadlocal var coro_stack: std.ArrayList(CooperativeInterceptor) = .empty;

/// Stack of the active coroutine's `CoroutineScope` value (the driven
/// root scope). The suspend-implicit `coroutineContext` read redirects to
/// the active scope's context via this stack. Page-allocator backed for
/// the same reason.
threadlocal var active_scope_stack: std.ArrayList(Value) = .empty;

fn coroStackAllocator() Allocator {
    return runtime.slab.tracedPage();
}

/// Assert (Debug) the coroutine interceptor and active-scope stacks are empty
/// at a run boundary and clear them so leaked-across-runs coroutine context is
/// a loud failure. The persisted-continuation registry is NOT reset here: it
/// is process-global, holds continuations that outlive the driver that
/// started them, and is swept once per run by `drainPersistedParked`.
pub fn resetReceiverTls() void {
    std.debug.assert(coro_stack.items.len == 0);
    std.debug.assert(active_scope_stack.items.len == 0);
    coro_stack.clearRetainingCapacity();
    active_scope_stack.clearRetainingCapacity();
}

/// The active interceptor (top of this thread's stack), or `null`.
fn coroTop() ?*CooperativeInterceptor {
    if (coro_stack.items.len == 0) return null;
    return &coro_stack.items[coro_stack.items.len - 1];
}

/// GC root provider for the coroutine subsystem. Marks every Value reachable
/// from a parked or in-flight coroutine: this thread's active interceptors and
/// scope stack, the process-global persisted-continuation registry, and the
/// slot-owner wakeup mailboxes. The locks are never held across a safe point
/// (coroutine bookkeeping runs between eval frames, not inside the block loop),
/// so taking them here cannot deadlock against the collecting mutator.
/// Process-global coroutine roots: the persisted-continuation registry and the
/// slot-owner wakeup mailboxes. Registered once.
fn gcMarkCoroGlobal(m: *runtime.gc.Marker) void {
    PersistedParked.mutex.lock();
    if (PersistedParked.map) |*pm| {
        var it = pm.valueIterator();
        while (it.next()) |e| {
            ir.eval.gcMarkSuspendState(&e.state, m);
            for (e.scope_delta) |v| v.gcMark(m);
        }
    }
    PersistedParked.mutex.unlock();

    SlotOwners.mutex.lock();
    if (SlotOwners.map) |*sm| {
        var it = sm.valueIterator();
        while (it.next()) |w| m.shade(&w.cell.hdr);
    }
    SlotOwners.mutex.unlock();

    if (runtime.gc.gc_debug) {
        const so = if (SlotOwners.map) |sm| sm.count() else 0;
        const sp = if (SlotOwners.pending) |pm| pm.count() else 0;
        const pp = if (PersistedParked.map) |pm| pm.count() else 0;
        const cs = coro_stack.items.len;
        const ss = active_scope_stack.items.len;
        std.debug.print("[coro] slot_owners={d} pending={d} persisted={d} coro_stack={d} scope_stack={d}\n", .{ so, sp, pp, cs, ss });
    }
}

/// Per-thread coroutine roots: this thread's interceptor stack and active scope
/// stack. `ctx` is `&coro_anchor` (pointers to this thread's two stacks).
const CoroAnchor = struct {
    coro: *std.ArrayList(CooperativeInterceptor),
    scope: *std.ArrayList(Value),
};
threadlocal var coro_anchor: CoroAnchor = undefined;
threadlocal var coro_troot: runtime.gc.ThreadRoot = undefined;
threadlocal var coro_troot_inited: bool = false;

fn gcMarkCoroLocalCtx(ctx: *anyopaque, m: *runtime.gc.Marker) void {
    const a: *const CoroAnchor = @ptrCast(@alignCast(ctx));
    for (a.coro.items) |*ci| ci.gcMark(m);
    for (a.scope.items) |v| v.gcMark(m);
}

var coro_global_registered = std.atomic.Value(bool).init(false);

fn ensureCoroRoot() void {
    if (!runtime.gc.gc_enabled) return;
    if (!coro_global_registered.swap(true, .monotonic))
        runtime.gc.registerRoot(gcMarkCoroGlobal);
    if (!coro_troot_inited) {
        coro_troot_inited = true;
        coro_anchor = .{ .coro = &coro_stack, .scope = &active_scope_stack };
        coro_troot = .{ .ctx = @ptrCast(&coro_anchor), .mark = gcMarkCoroLocalCtx };
        runtime.gc.registerThreadRoot(&coro_troot);
    }
}

/// Unlink this thread's coroutine root node at its exit seam.
pub fn gcUninstallCoroRoot() void {
    if (!coro_troot_inited) return;
    runtime.gc.unregisterThreadRoot(&coro_troot);
    coro_troot_inited = false;
}

/// Thread-entry GC seam (the main run thread and every spawned worker /
/// dispatcher thread): join the mutator set so a collection on any thread stops
/// this one at its next safe point before reading the shared heap. The
/// per-thread root nodes (frames, keepalive, interceptor stack) link lazily on
/// first use. Worker threads stay in the permanent generation: a worker-minted
/// cell can be referenced cross-thread through paths the collector does not yet
/// fully root (queued tasks, the dispatched result handoff), so sweeping them
/// would be unsound. Only main-minted cells they reference are reclaimed.
pub fn gcThreadEnter() void {
    if (!runtime.gc.gc_enabled) return;
    runtime.gc.enterMutator();
}

/// Thread-exit GC seam: leave the mutator set (parking through any in-flight
/// collection) and unlink every per-thread root node before this thread's
/// threadlocal storage is torn down.
pub fn gcThreadExit() void {
    if (!runtime.gc.gc_enabled) return;
    runtime.gc.exitMutator();
    ir.eval.gcUninstallFrameRoot();
    runtime.gcUninstallKeepaliveRoot();
    gcUninstallCoroRoot();
    @import("compose.zig").gcUninstallComposeRoot();
}

/// Push a fresh interceptor for a newly-entered driven root.
fn coroPush(allocator: Allocator) Allocator.Error!void {
    ensureCoroRoot();
    try coro_stack.append(coroStackAllocator(), try CooperativeInterceptor.new(allocator));
}

/// Pop and deinit the top interceptor, returning its `wakeup` handle so
/// the caller can release any global slot-owner entries that still point
/// at it. The returned handle is owned by the caller (must `deinit`).
fn coroPop() ?ObjRef(DriverWakeup) {
    if (coro_stack.items.len == 0) return null;
    var ci = coro_stack.pop().?;
    const wakeup = ci.wakeup.clone();
    ci.deinit();
    return wakeup;
}

/// The active coroutine scope (top of the driver stack), if any. Public
/// so the field-read path (`coroutineContext` redirect) can consult the
/// real stack.
pub fn activeCoroScope() ?Value {
    if (active_scope_stack.items.len == 0) return null;
    return active_scope_stack.items[active_scope_stack.items.len - 1];
}

/// The current active-scope stack depth — the base an activation's run
/// segment starts at, so the pushes it makes above this base can be
/// captured as its per-activation scope delta when it parks.
fn activeScopeDepth() usize {
    return active_scope_stack.items.len;
}

/// Capture and remove the active-scope pushes above `base` — the scope
/// delta owned by the activation that is about to park. A suspension
/// unwinds through Zig without running the Kotlin `finally` that would
/// pop these, so they would otherwise linger on the live stack and a
/// later sibling resume would read this activation's stale scope as its
/// own (cancellation over-delivery). Returning them to the ParkedEntry
/// keeps the live stack reflecting only running activations. Caller owns
/// the returned slice (page-allocator). Empty when nothing was pushed.
fn scopeDiagOn() bool {
    return runtime.getenvSlice("KLIO_SCOPE_DIAG") != null;
}
fn scopeIdent(v: *const Value) usize {
    return if (v.* == .Instance) v.Instance.identity() else 0;
}
fn captureScopeDelta(base: usize) []Value {
    const n = active_scope_stack.items.len;
    if (scopeDiagOn() and n > base) {
        std.debug.print("[scope] capture base={d} n={d}:", .{ base, n });
        for (active_scope_stack.items[base..n]) |*v| std.debug.print(" {x}", .{scopeIdent(v)});
        std.debug.print("\n", .{});
    }
    if (n <= base) return &.{};
    const delta = coroStackAllocator().dupe(Value, active_scope_stack.items[base..n]) catch return &.{};
    active_scope_stack.shrinkRetainingCapacity(base);
    return delta;
}

/// Restore a parked activation's captured scope delta onto the live
/// stack just before it resumes, so its post-resume suspending calls and
/// `coroutineContext` reads see its own scope on top. The resumed body's
/// `__klio_co_popScope` (from `startBlock`'s `finally`) balances these
/// pushes when it finally completes; a re-suspension re-captures them.
fn restoreScopeDelta(delta: []const Value) void {
    if (scopeDiagOn() and delta.len != 0) {
        std.debug.print("[scope] restore depth={d}:", .{active_scope_stack.items.len});
        for (delta) |*v| std.debug.print(" {x}", .{scopeIdent(v)});
        std.debug.print("\n", .{});
    }
    for (delta) |s| active_scope_stack.append(coroStackAllocator(), s) catch {};
}

/// RAII-style scope guard: pushes the driven coroutine's scope for the
/// lifetime of a `driveRoot` activation so the `coroutineContext`
/// intrinsic resolves to it. Only `Instance` scopes are pushed.
const ActiveScopeGuard = struct {
    pushed: bool,
    ident: usize = 0,

    fn enter(scope: *const Value) ActiveScopeGuard {
        if (scope.* == .Instance) {
            if (scopeDiagOn())
                std.debug.print("[scope] guard-enter depth={d} id={x}\n", .{ active_scope_stack.items.len, scopeIdent(scope) });
            active_scope_stack.append(coroStackAllocator(), scope.*) catch return .{ .pushed = false };
            return .{ .pushed = true, .ident = scopeIdent(scope) };
        }
        return .{ .pushed = false };
    }

    fn leave(self: ActiveScopeGuard) void {
        if (!self.pushed) return;
        // Remove OUR OWN entry, topmost-first by identity — never a blind
        // top pop. Activations interleave on this stack: the driven body's
        // own `startBlock` pushes (or a nested drive's guard) can sit above
        // this guard's entry when it unwinds, and popping the top removes
        // THEIRS while leaking OURS — a later positional delta capture then
        // adopts the leaked scope as another coroutine's own, and every
        // resume of that coroutine restores the wrong scope (a channel
        // cancellation armed through it binds to the wrong Job). If our
        // entry is gone already (captured into a delta), remove nothing.
        var i: usize = active_scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (scopeIdent(&active_scope_stack.items[i]) == self.ident) {
                if (scopeDiagOn())
                    std.debug.print("[scope] guard-leave idx={d} id={x}\n", .{ i, self.ident });
                _ = active_scope_stack.orderedRemove(i);
                return;
            }
        }
        if (scopeDiagOn())
            std.debug.print("[scope] guard-leave id={x} (already captured)\n", .{self.ident});
    }
};

/// Map an `EvalError` onto the runtime's `RuntimeError`: `Throw -> Thrown`,
/// `NonLocalReturn -> Return`, every other variant rendered as `Type`.
fn mapDriverErr(allocator: Allocator, e: EvalError) RuntimeError {
    return switch (e) {
        .Throw => |v| .{ .Thrown = v },
        .NonLocalReturn => |v| .{ .Return = v },
        .LabeledReturn => |lr| .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } },
        .Type => |s| .{ .Type = s },
        .Unsupported => |s| .{ .Type = s },
        .Unbound => |s| .{ .Unbound = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .CalleeFailed => |s| .{ .CalleeFailed = s },
        .Arity => |s| .{ .Arity = s },
        .StackOverflow => |s| .{ .Type = s },
        .Suspended => .{ .Type = std.fmt.allocPrint(allocator, "coroutine suspended outside a driver", .{}) catch "coroutine suspended outside a driver" },
    };
}

// -------------------------------------------------------------------------
// Lazy `sequence { yield(...) }` / `iterator { ... }` builder driver.
//
// The builder block is a restricted-suspension coroutine: each `yield(x)`
// writes `x` onto the `SequenceScope` instance and suspends the block
// (`RuntimeError.Suspend = -1`), which the eval engine captures as a
// `SuspendState`. The consumer drives it one element at a time: the first
// `builderStep` starts the block (`evalClosureRaw`), each later step resumes
// the captured continuation (`resumeRaw`) until the next `yield`. No coroutine
// driver / pump is pushed — the block parks only via `yield`/`yieldAll`, never
// a `delay`, so its suspensions never escape this step loop.
// -------------------------------------------------------------------------

/// Scope field the `yield` intrinsic sets to `true` immediately before it
/// suspends, so `builderStep` can tell a real yield apart from any other
/// suspension a (mis-written) builder block might attempt.
pub const seq_has_value_field = "__seq_has_value";
/// Scope field holding the value passed to `yield(value)`.
pub const seq_value_field = "__seq_value";
/// Scope field holding the pending `yieldAll` iterator (an `Iterator` Value)
/// the consumer drains lazily before the block resumes; `Null`/absent when no
/// `yieldAll` is in flight.
pub const seq_yield_iter_field = "__seq_yield_iter";

const BuilderStepResult = runtime.BuilderStepResult;
const InstanceData = runtime.InstanceData;

const PendingKind = enum { value, yield_all, none };

/// Inspect the scope after a suspension: did the block yield a single value,
/// stash a `yieldAll` iterator, or suspend on something else? Read-and-clears
/// the single-value flag.
fn classifySuspension(scope: *const Value) struct { kind: PendingKind, value: Value } {
    if (scope.* != .Instance) return .{ .kind = .none, .value = .Unit };
    const g = scope.Instance.borrowMut();
    defer g.deinit();
    const inst = g.get();
    if (inst.get(seq_has_value_field)) |has| {
        if (has == .Bool and has.Bool) {
            const v = inst.get(seq_value_field) orelse Value.Unit;
            _ = inst.set(seq_has_value_field, .{ .Bool = false });
            return .{ .kind = .value, .value = v };
        }
    }
    if (inst.get(seq_yield_iter_field)) |it| {
        if (it != .Null) return .{ .kind = .yield_all, .value = it };
    }
    return .{ .kind = .none, .value = .Unit };
}

/// The pending `yieldAll` iterator on the scope, or `null`.
fn pendingYieldIter(scope: *const Value) ?Value {
    if (scope.* != .Instance) return null;
    const g = scope.Instance.borrow();
    defer g.deinit();
    const it = g.get().get(seq_yield_iter_field) orelse return null;
    if (it == .Null) return null;
    return it;
}

fn clearYieldIter(scope: *const Value) void {
    if (scope.* != .Instance) return;
    const g = scope.Instance.borrowMut();
    defer g.deinit();
    _ = g.get().set(seq_yield_iter_field, .Null);
}

/// Pull one element from the pending `yieldAll` iterator: `hasNext()` then
/// `next()`. Returns the element, or `null` when the iterator is exhausted
/// (the caller then clears it and resumes the block), or an error.
fn drainOne(self: *VmIntrinsicHost, it: *const Value, out: Output) Allocator.Error!union(enum) { value: Value, done, err: RuntimeError } {
    const hn = (try intrinsic_host.invokeMethod(self, it, "hasNext", &.{}, out)) orelse
        return .{ .err = .{ .Type = "yieldAll: argument is not an Iterator" } };
    switch (hn) {
        .ok => |b| if (!(b == .Bool and b.Bool)) return .done,
        .err => |e| return .{ .err = e },
    }
    const nx = (try intrinsic_host.invokeMethod(self, it, "next", &.{}, out)) orelse
        return .{ .err = .{ .Type = "yieldAll: Iterator has no next()" } };
    return switch (nx) {
        .ok => |v| .{ .value = v },
        .err => |e| .{ .err = e },
    };
}

/// Drive a lazy `sequence{}`/`iterator{}` builder one element. Starts the block
/// on the first call and resumes the captured continuation on each later call,
/// returning the next yielded value or `.done` at completion.
pub fn builderStep(self: *VmIntrinsicHost, state: runtime.BuilderStateRef, out: Output) Allocator.Error!BuilderStepResult {
    const a = self.allocator;

    var done: bool = undefined;
    var failed: bool = undefined;
    var scope: Value = undefined;
    {
        const g = state.borrow();
        done = g.get().done;
        failed = g.get().failed;
        scope = g.get().scope.asPtr().*;
        g.deinit();
    }
    // The block already threw out of an earlier pull; a failed iterator
    // rejects every later pull, matching `SequenceBuilderIterator`.
    if (failed) {
        return .{ .err = .{ .Thrown = .{ .Exception = .{
            .fqn = try runtime.strInit(a, "kotlin.IllegalStateException"),
            .message = try runtime.strInit(a, "Iterator has failed."),
            .cause = null,
            .suppressed = (try runtime.ValueList.init(a, .empty)).cell,
        } } } };
    }
    if (done) return .done;

    // Phase A: keep draining a yieldAll iterator stashed on the scope before
    // touching the coroutine, so its elements interleave lazily (an infinite
    // yieldAll source never forces the block past its current suspension).
    if (pendingYieldIter(&scope)) |it| {
        switch (try drainOne(self, &it, out)) {
            .value => |v| return .{ .value = v },
            .done => clearYieldIter(&scope),
            .err => |e| {
                const g = state.borrowMut();
                g.get().done = true;
                g.get().failed = errIsThrow(&e);
                g.deinit();
                return .{ .err = e };
            },
        }
    }

    // Phase B: start or resume the coroutine, looping past empty yieldAll
    // suspensions (a `yieldAll` of an empty/exhausted iterator yields nothing
    // and the block must run on to its next real suspension).
    while (true) {
        var started: bool = undefined;
        var cont: ?*SuspendState = undefined;
        var block: Value = undefined;
        {
            const g = state.borrow();
            started = g.get().started;
            cont = if (g.get().cont) |c| @ptrCast(@alignCast(c)) else null;
            block = g.get().block.asPtr().*;
            g.deinit();
        }

        var r: ir.eval.EvalResult = undefined;
        if (!started) {
            {
                const g = state.borrowMut();
                g.get().started = true;
                g.deinit();
            }
            r = try intrinsic_host.evalClosureRaw(self, &block, &.{}, &scope, out);
        } else {
            const old = cont orelse {
                const g = state.borrowMut();
                g.get().done = true;
                g.deinit();
                return .done;
            };
            {
                const g = state.borrowMut();
                g.get().cont = null;
                g.deinit();
            }
            ir.eval.resume_route = "yield-rotate";
            r = try intrinsic_host.resumeRaw(self, old, .Unit, out);
            // `resumeContinuation` freed `old.frames`; free the box itself.
            a.destroy(old);
        }

        switch (r) {
            .ok => {
                const g = state.borrowMut();
                g.get().done = true;
                g.deinit();
                return .done;
            },
            .err => |e| switch (e) {
                .Suspended => |new_state| {
                    {
                        const g = state.borrowMut();
                        g.get().cont = @ptrCast(new_state);
                        g.deinit();
                    }
                    const cls = classifySuspension(&scope);
                    switch (cls.kind) {
                        .value => return .{ .value = cls.value },
                        .yield_all => {
                            // Drain the first element now; if the iterator is
                            // empty, clear it and resume the block again.
                            const it = pendingYieldIter(&scope) orelse continue;
                            switch (try drainOne(self, &it, out)) {
                                .value => |v| return .{ .value = v },
                                .done => {
                                    clearYieldIter(&scope);
                                    continue;
                                },
                                .err => |de| {
                                    const g = state.borrowMut();
                                    g.get().done = true;
                                    g.get().failed = errIsThrow(&de);
                                    g.deinit();
                                    return .{ .err = de };
                                },
                            }
                        },
                        .none => {
                            // Suspended via something other than yield/yieldAll.
                            const g = state.borrowMut();
                            g.get().done = true;
                            g.get().cont = null;
                            g.deinit();
                            new_state.deinit(a);
                            a.destroy(new_state);
                            return .{ .err = .{ .Type = "sequence/iterator builder suspended on a call other than yield/yieldAll" } };
                        },
                    }
                },
                else => {
                    const mapped = mapDriverErr(a, e);
                    const g = state.borrowMut();
                    g.get().done = true;
                    g.get().failed = errIsThrow(&mapped);
                    g.deinit();
                    return .{ .err = mapped };
                },
            },
        }
    }
}

/// Whether a pull's error was a Kotlin throw out of the builder block (as
/// opposed to an interpreter-level failure); only a throw flips the
/// iterator into the failed state.
fn errIsThrow(e: *const RuntimeError) bool {
    return e.* == .Thrown;
}

/// Hand a freshly-suspended Layer-1 activation to the active interceptor
/// (Layer 2). Returns the token so the driver can recognise the root's
/// completion. The `*SuspendState` box is consumed: its value is copied
/// into the interceptor and the box freed (the inner `frames` ArrayList /
/// dup'd slices are now owned by the copied value).
fn park(allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!u64 {
    const top = coroTop() orelse return error.OutOfMemory; // "park outside runBlocking"
    return parkInto(top, allocator, st, scope_base);
}

/// Park into a SPECIFIC pump. An activation resumed inline runs on whatever
/// stack resumed it, which may sit under a nested pump; it still belongs to the
/// pump it was parked in, and must go back there — `coroTop()` would hand it to
/// a pump that is about to exit.
fn parkInto(pump: *CooperativeInterceptor, allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!u64 {
    const value = st.*;
    allocator.destroy(st);
    const delta = captureScopeDelta(scope_base);
    const tok = try pump.interceptSuspend(value, delta);
    if (pumpDiagEnabled()) {
        const g = pump.parked.getPtr(tok);
        std.debug.print("[tok] park tok={d} wake={?d} frames={d}:", .{
            tok,
            if (g) |e| e.wake_at else null,
            value.frames.items.len,
        });
        for (value.frames.items) |*fr| {
            var printed = false;
            if (fr.module) |mm| {
                if (mm.funcById(fr.func)) |f| {
                    const loc = ir.eval.funcFirstLoc(f);
                    std.debug.print(" #{d}({s}:{d})@{d}:{d}", .{ fr.func.int(), loc.path, loc.line, fr.block.int(), fr.inst_idx });
                    printed = true;
                }
            }
            if (!printed) std.debug.print(" #{d}@{d}:{d}", .{ fr.func.int(), fr.block.int(), fr.inst_idx });
        }
        var seg = value.tails;
        while (seg) |t| : (seg = t.next) {
            std.debug.print(" |tail", .{});
            var i = t.head;
            while (i < t.frames.items.len) : (i += 1) {
                const fr = &t.frames.items[i];
                std.debug.print(" #{d}@{d}:{d}/{x}", .{ fr.func.int(), fr.block.int(), fr.inst_idx, fr.regs.ptrIdentity() });
            }
        }
        std.debug.print("\n", .{});
    }
    return tok;
}

/// Layer 2 — the default interceptor's dispatch loop (`drive_run_blocking`).
pub fn driveRunBlocking(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return driveRoot(self, block, scope, out, false);
}

/// `driveRunBlocking` with control over whether a coroutine that parks
/// indefinitely (awaiting an external resume) is preserved into
/// program-lifetime storage on driver exit (`persist = true`, the
/// `startCoroutine` boundary and every dispatcher pool task) or simply
/// abandoned (`persist = false`, `runBlocking`). One tightly-coupled
/// coroutine state machine.
pub fn driveRoot(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output, persist: bool) Allocator.Error!RuntimeEvalResult {
    const a = self.allocator;
    try coroPush(a);
    // A top-level (non-pool-worker) driver holds the shared virtual clock at
    // the current instant while it runs its body's synchronous prefix: a
    // coroutine the body dispatches onto a pool worker must not advance
    // virtual time past `now` before the body has reached the `delay`/`launch`
    // that establish the sibling timers. Without this a `Dispatchers.Default`
    // child could run through its whole `delay` chain on another thread while
    // `runBlocking` is still executing synchronously, reordering cross-pump
    // wakeups. A pool-worker driver does NOT claim — its body may do real
    // blocking work (`Thread.sleep`) that must not hold the virtual clock,
    // and a sibling's floor already orders any virtual `delay` it parks on.
    if (!vmhost.scheduler.onPoolWorker()) (coroTop().?).claimNow();
    // An undispatched block's scope push (`coroutinePushScope`) pops when
    // its activation completes; an activation abandoned with this pump
    // never completes, so the pump truncates the stack back to its entry
    // depth on every exit path.
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    const guard = ActiveScopeGuard.enter(scope);
    defer guard.leave();

    // Root coroutine. Its scope base sits BELOW the guard's push, so the
    // root's park carries the coroutine scope in its ParkedEntry (the same
    // contract as `coroutineRunRoot`'s enclosing-driver branch). A root
    // persisted at pump exit then re-establishes its own scope when
    // `driveResumed` re-drives it on a later pump — without this, every
    // fresh suspension point after the first cross-pump hop resolved
    // `coroutineContext` to nothing: `context[Job]` was null, no
    // parent-cancellation handle was installed, and a dispatched
    // `while (true) { delay(1) }` loop became uncancellable. The guard's
    // identity-aware `leave` no-ops once the entry moved into the delta.
    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    const root_scope_base = scope_depth;
    switch (try intrinsic_host.evalClosureRaw(self, block, &.{}, scope, out)) {
        .ok => |v| root_value = v,
        .err => |e| switch (e) {
            .Suspended => |st| root_token = try park(a, st, root_scope_base),
            else => {
                // Error exit runs the same exit protocol as quiescence:
                // persist (in persist mode), close the mailbox, release
                // the slot-owner entries. A bare pop would leave stale
                // owner registrations pointing at an open mailbox nobody
                // drains — a silently lost resume for every sibling.
                try pumpExit(self, out, persist);
                return .{ .err = mapDriverErr(a, e) };
            },
        },
    }

    if (try pumpLoop(self, scope, out, persist, !persist, &root_token, &root_value)) |err_result| {
        return err_result;
    }
    try pumpExit(self, out, persist);
    return .{ .ok = root_value orelse Value.Unit };
}

/// Drive a `suspend fun main` to completion. kotlinc wraps a suspend main
/// in `runSuspend`; this is the equivalent root driver, so a real
/// suspension (`delay`, an awaited `Job`, …) parks and resumes here instead
/// of escaping the run loop as a "suspended outside a driver" error. `main`
/// runs in the empty coroutine context (the `Unit` root scope).
pub fn driveSuspendMain(self: *VmIntrinsicHost, main_id: ir.FuncId, out: Output) Allocator.Error!RuntimeEvalResult {
    const a = self.allocator;
    try coroPush(a);
    if (!vmhost.scheduler.onPoolWorker()) (coroTop().?).claimNow();
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    const unit: Value = .Unit;
    const guard = ActiveScopeGuard.enter(&unit);
    defer guard.leave();

    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    const root_scope_base = activeScopeDepth();
    switch (try intrinsic_host.evalFuncRaw(self, main_id, out)) {
        .ok => |v| root_value = v,
        .err => |e| switch (e) {
            .Suspended => |st| root_token = try park(a, st, root_scope_base),
            else => {
                try pumpExit(self, out, false);
                return .{ .err = mapDriverErr(a, e) };
            },
        },
    }
    if (try pumpLoop(self, &unit, out, false, true, &root_token, &root_value)) |err_result| {
        return err_result;
    }
    try pumpExit(self, out, false);
    return .{ .ok = root_value orelse Value.Unit };
}

/// Resume a persisted continuation claimed from `PersistedParked` and
/// drive it (and anything it launches) to quiescence on the calling
/// thread, under a fresh pump. This is the cross-pump resume engine: a
/// coroutine that parked on one OS thread continues here, on whichever
/// thread its resume arrived (for dispatcher coroutines that is a pool
/// worker, because the resume itself travels as a dispatched runnable).
/// A new indefinite park is re-persisted, so a coroutine can hop pumps
/// any number of times.
threadlocal var drive_depth: usize = 0;
threadlocal var drive_depth_max: usize = 0;
threadlocal var drive_count: usize = 0;

pub fn driveResumed(self: *VmIntrinsicHost, state_in: SuspendState, value: Value, scope_delta: []const Value, out: Output) Allocator.Error!void {
    const a = self.allocator;
    drive_depth += 1;
    drive_count += 1;
    if (drive_depth > drive_depth_max) {
        drive_depth_max = drive_depth;
        if (pumpDiagEnabled() and drive_depth_max % 64 == 0)
            std.debug.print("[PUMP] driveResumed depth={d} count={d}\n", .{ drive_depth_max, drive_count });
    }
    defer drive_depth -= 1;
    try coroPush(a);
    if (!vmhost.scheduler.onPoolWorker()) (coroTop().?).claimNow();
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    var state = state_in;
    // Re-establish the cross-pump activation's own scope before it runs,
    // so its post-resume suspending calls resolve `coroutineContext` to
    // its own coroutine. Base is the depth before restore (a re-suspend
    // re-captures the restored delta).
    const root_scope_base = activeScopeDepth();
    restoreScopeDelta(scope_delta);
    ir.eval.resume_route = "driveResumed";
    switch (try intrinsic_host.resumeRaw(self, &state, value, out)) {
        .ok => |v| root_value = v,
        .err => |e| switch (e) {
            .Suspended => |st| root_token = try park(a, st, root_scope_base),
            else => {
                // The resumed coroutine's terminal outcome is delivered
                // through its completion continuation inside the frames;
                // an error escaping raw has no awaiting caller on this
                // thread. The pump still exits through the protocol so
                // its slot registrations and mailbox close cleanly.
                try pumpExit(self, out, true);
                return;
            },
        },
    }
    const scope = activeCoroScope() orelse Value.Unit;
    if (try pumpLoop(self, &scope, out, true, false, &root_token, &root_value)) |_| {
        return;
    }
    try pumpExit(self, out, true);
}

/// The shared driver pump: start queued launches, resume ready
/// coroutines, advance timers, drain the cross-thread mailbox, and — for
/// a blocking root — wait while the root is alive or dispatched pool
/// work that can still resume one of this driver's coroutines is in
/// flight. Returns a non-null error result when the pump failed (the
/// interceptor has been popped); null on quiescence (the interceptor is
/// still pushed and `pumpExit` must run).
fn pumpLoop(
    self: *VmIntrinsicHost,
    scope: *const Value,
    out: Output,
    persist: bool,
    stop_on_root_completion: bool,
    root_token: *?u64,
    root_value: *?Value,
) Allocator.Error!?RuntimeEvalResult {
    const a = self.allocator;
    var idle_rounds: usize = 0;
    var diag_loops: usize = 0;
    while (true) {
        diag_loops += 1;
        // Per-test wall deadline: a deadlocked pump idles in this loop's
        // sleep arms, never the eval loop, so the test runner's watchdog
        // must fire here — checked cheaply per iteration (the loop already
        // does map borrows and clock work each round).
        if (diag_loops % 64 == 0) {
            const wall_dl = ir.eval.test_wall_deadline_ms.load(.monotonic);
            if (wall_dl != 0 and ir.eval.nowMonotonicMs() > wall_dl) {
                std.debug.print("[wall-cap] pump wall-clock deadline exceeded — stalled pump state follows:\n", .{});
                if (coroTop()) |t| diagStalledPump(self, t, root_token.*, true);
                ir.eval.wallCapAbandon();
                try pumpExit(self, out, persist);
                return .{ .err = .{ .Type = "test wall-clock deadline exceeded" } };
            }
        }
        if (coroTop()) |top| {
            top.root_tok = root_token.*;
            // A failure from an activation of this pump that ran inline on a
            // resumer's stack: raise it here, where the loop's own failures
            // are raised.
            if (top.pending_err) |pe| {
                top.pending_err = null;
                try pumpExit(self, out, persist);
                return .{ .err = mapDriverErr(a, pe) };
            }
        }
        if (pumpDiagEnabled() and diag_loops % 2000 == 0) {
            const t = coroTop().?;
            std.debug.print("[PUMP] loop {d}: ready={d} launched={d} parked={d} root={?}\n", .{ diag_loops, t.ready.items.len, t.launched.items.len, t.parked.count(), root_token.* });
            var sit = t.slot_to_token.iterator();
            while (sit.next()) |e| std.debug.print("[PUMP]   slot {d} -> tok {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
            var it = t.parked.iterator();
            while (it.next()) |e| {
                std.debug.print("[PUMP]   parked tok={d} wake={d}:", .{ e.key_ptr.*, e.value_ptr.wake_at });
                const st = &e.value_ptr.state;
                const mg = self.module.borrow();
                defer mg.deinit();
                var k: usize = 0;
                while (k < st.frames.items.len and k < 24) : (k += 1) {
                    const snap = st.frames.items[k];
                    const m: *const ir.Module = snap.module orelse mg.get();
                    const f = m.funcById(snap.func);
                    const nm = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "?";
                    // The declaration site disambiguates same-named frames
                    // (`<lambda>`): which source declared the parked caller.
                    if (f) |ff| {
                        const loc = ir.eval.funcFirstLoc(ff);
                        std.debug.print(" {s}#{d}({s}:{d})", .{ nm, snap.func.int(), loc.path, loc.line });
                    } else {
                        std.debug.print(" {s}#{d}", .{ nm, snap.func.int() });
                    }
                }
                std.debug.print("\n", .{});
            }
        }
        // 0. Daemon abandonment: a pool task's pump still running at the
        //    run boundary stops pumping and exits through the protocol.
        if (runtime.shouldAbandon()) {
            try pumpExit(self, out, persist);
            return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
        }

        // 0b. A blocking root returns the moment its root coroutine has
        //     completed: for `runBlocking` that is the job-tree
        //     completion. Anything still queued or parked on this pump
        //     is outside its job tree (an orphaned daemon launch, a
        //     cancelled child's stale timer) and dies with the pump,
        //     exactly as upstream `runBlocking` returns without it.
        if (stop_on_root_completion and root_token.* == null) break;

        // 0b'. Any `withTimeout` timeout gate no nested block claimed (a bare
        //      `select { onTimeout(…) }`, whose `invokeOnTimeout` has no
        //      undispatched body to share a timer queue with) runs as an
        //      ordinary timer on THIS pump: promote it into the launch queue.
        try (coroTop().?).promoteTimeouts();

        // 0c. While this pump still has work to run at the current virtual
        //     instant — a queued launch to start, or a coroutine already
        //     ready — hold the shared-clock barrier at `now` so no sibling
        //     pump advances virtual time past this instant before this pump
        //     reaches and parks on its own timer. A child still on its way
        //     to `delay(d)` must register its `now + d` deadline before any
        //     pump jumps to a later one, so cross-pump wakeups fire in
        //     ascending-deadline order.
        if ((coroTop().?).launched.items.len != 0 or (coroTop().?).ready.items.len != 0) {
            (coroTop().?).claimNow();
        }

        // 1. Start any queued child launches. A started launch may
        //    enqueue more (a `delay` schedules its timer through a
        //    spawned block), so a round that started anything loops back
        //    to drain again BEFORE the clock may advance: a timer must
        //    be parked, with its deadline measured from the current
        //    time, before `advanceTime` picks the next wakeup.
        const launched = try (coroTop().?).drainLaunched(a);
        defer a.free(launched);
        // `drainLaunched` empties `self.launched`, so the interceptor no longer
        // marks these blocks. While an earlier block runs and suspends, a
        // collection would otherwise reclaim the not-yet-started blocks' closure
        // slots (and sweep their capture stores). Root the whole batch for the
        // loop; the restore is registered after the free's `defer` so it runs
        // first (LIFO) — the slice is still valid when the keepalive drops it.
        const ka_launched = runtime.keepaliveMark();
        defer runtime.keepaliveRestore(ka_launched);
        runtime.keepalivePushSlice(launched);
        for (launched) |child| {
            const child_scope_base = activeScopeDepth();
            const child_res = try intrinsic_host.evalClosureRaw(self, &child, &.{}, scope, out);
            if (pumpDiagEnabled()) {
                const tag: []const u8 = switch (child_res) {
                    .ok => "ok",
                    .err => |e| @tagName(std.meta.activeTag(e)),
                };
                std.debug.print("[tok] launched-child -> {s}\n", .{tag});
            }
            switch (child_res) {
                // The block ran to completion: the launch queue's owned
                // reference is no longer needed. A *suspended* block is still
                // in flight (its captured continuation must stay live until it
                // resumes), so its reference is kept and released when its
                // park completes via the snapshot teardown.
                .ok => if (runtime.reclaimEnabled()) child.release(a),
                .err => |e| switch (e) {
                    .Suspended => |st| _ = try park(a, st, child_scope_base),
                    else => {
                        try pumpExit(self, out, persist);
                        return .{ .err = mapDriverErr(a, e) };
                    },
                },
            }
        }
        if (launched.len != 0) {
            endStreak("launched");
            idle_rounds = 0;
            continue;
        }

        // 2. Resume a ready coroutine, if any — but first fire any DUE
        //    Wall deadlines, or a yield-livelocked coroutine pair starves
        //    `withTimeout` (the runTest watchdog never fires and a livelock
        //    reads as an unkillable hang instead of a timeout failure).
        try (coroTop().?).armDueWallTimers();
        inline_turn_resumes = 0;
        persist_inline_resumes = 0;
        if ((coroTop().?).nextReady()) |tok| {
            endStreak("ready");
            if ((coroTop().?).takeParked(tok)) |entry_in| {
                var entry = entry_in;
                const resume_with = (coroTop().?).takeResumeValue(tok) orelse Value.Unit;
                // Re-establish this activation's own scope before it runs:
                // its post-resume suspending calls and `coroutineContext`
                // reads must see its scope, not the pump's. The base is the
                // depth *before* restore, so a re-suspension re-captures the
                // restored delta (whose `finally` pop was skipped).
                const scope_base = activeScopeDepth();
                restoreScopeDelta(entry.scope_delta);
                coroStackAllocator().free(entry.scope_delta);
                ir.eval.resume_route = "pump-ready";
                switch (try intrinsic_host.resumeRaw(self, &entry.state, resume_with, out)) {
                    .ok => |v| {
                        if (root_token.* != null and root_token.*.? == tok) {
                            root_value.* = v;
                            root_token.* = null;
                        }
                    },
                    .err => |e| switch (e) {
                        .Suspended => |st2| {
                            const new_tok = try park(a, st2, scope_base);
                            if (root_token.* != null and root_token.*.? == tok) {
                                root_token.* = new_tok;
                            }
                        },
                        // A launched child observing a CancellationException
                        // (Job.cancel / withTimeout cooperative cancel) is
                        // swallowed, matching a real Kotlin runtime; the root
                        // keeps its throw semantics.
                        .Throw => |v| {
                            if ((root_token.* == null or root_token.*.? != tok) and root.isCancellationException(&v)) {
                                // swallow
                            } else {
                                try pumpExit(self, out, persist);
                                return .{ .err = mapDriverErr(a, e) };
                            }
                        },
                        else => {
                            try pumpExit(self, out, persist);
                            return .{ .err = mapDriverErr(a, e) };
                        },
                    },
                }
            }
            continue;
        }

        // 3. No ready coroutine — advance virtual time to the nearest
        //    timer and arm every coroutine due then. A `.blocked` outcome
        //    means a *future* timer is parked but the global virtual-clock
        //    barrier is holding it because another live pump still has
        //    earlier work that may cancel this one; fall through to drain
        //    the mailbox (the cancellation's arrival path) and retry. An
        //    immediate (`<= now`) timer always fires, so a timer-free or
        //    yield-only pump behaves exactly as before the barrier.
        const advance = try (coroTop().?).advanceTimeGated();
        if (advance == .fired) continue;
        const barrier_blocked = advance == .blocked;

        // 3b. Cross-thread bridge: drain any resumes posted by worker
        //     threads (e.g. `Dispatchers.Default`) into the interceptor; if
        //     a worker is still in flight, wait briefly for it to post.
        const wakeup = (coroTop().?).wakeup.clone();
        defer {
            var w = wakeup;
            w.deinit();
        }
        const had_resume = try drainWakeupInto(a, &wakeup, coroTop().?);
        if (had_resume) {
            endStreak("mailbox");
            idle_rounds = 0;
            continue;
        }
        var pending: usize = 0;
        {
            const w = wakeup.borrowMut();
            pending = w.get().pending();
            w.deinit();
        }
        if (pending > 0) {
            countSleep(.wakeup_pending);
            sleepMillis(1);
            _ = try drainWakeupInto(a, &wakeup, coroTop().?);
            continue;
        }

        // 3c. The global virtual-clock barrier is still holding this pump's
        //     timer: yield so the pump with the earlier deadline runs and
        //     can post a cross-pump cancellation, then loop to re-drain.
        //     Never break here — the timer is real work, just not yet
        //     allowed to fire.
        if (barrier_blocked) {
            countSleep(.barrier_yield);
            std.Thread.yield() catch sleepMillis(1);
            continue;
        }

        // 3c'. A Wall timer is pending but not due (advanceTimeGated took
        //      its sleep slice). The mailbox above is drained; retry.
        //      Never break or park the root here — the timer is real work.
        if (advance == .waiting) continue;

        // 3d. A blocking root must not return while its root coroutine is
        //     still parked. For `runBlocking` the root parks until its
        //     coroutine's job completes, and the job machinery — not a
        //     host-side count — decides when that is: children on this
        //     pump, children dispatched to pool workers, and children
        //     resumed from explicit threads all complete the job (or are
        //     not part of it, like `GlobalScope` daemons) exactly as
        //     upstream structured concurrency defines. The completion
        //     resume arrives locally or through the mailbox above.
        if (!persist and root_token.* != null) {
            idle_rounds += 1;
            if (idle_rounds == 3000) diagStalledPump(self, coroTop().?, root_token.*, false);
            // Per-test wall deadline: a genuinely deadlocked pump (a parked
            // root whose resumer never comes — the Recomposer deadlock-
            // regression shape) idles HERE, not in the eval loop, so the
            // test runner's watchdog must fire from this arm too.
            {
                const wall_dl = ir.eval.test_wall_deadline_ms.load(.monotonic);
                if (wall_dl != 0 and ir.eval.nowMonotonicMs() > wall_dl) {
                    std.debug.print("[wall-cap] pump wall-clock deadline exceeded (parked root) — stalled pump state follows:\n", .{});
                    diagStalledPump(self, coroTop().?, root_token.*, true);
                    ir.eval.wallCapAbandon();
                    try pumpExit(self, out, persist);
                    return .{ .err = .{ .Type = "test wall-clock deadline exceeded" } };
                }
            }
            // Deadlock breaker: an activation belonging to an OUTER pump that
            // failed during an inline resume leaves its error stashed on that
            // pump (`resumeInlineOnce`), whose own loop is frozen beneath this
            // one — its coroutine never completes, so every awaiter up here
            // parks forever and this loop idles above a recorded failure.
            // After a grace period of total idleness, surface the stashed
            // error instead of sleeping indefinitely; a cross-thread resume
            // arriving within the grace period keeps the normal path, and an
            // outer pump that regains control raises its own stash first.
            if (idle_rounds >= 3000) {
                var pi: usize = coro_stack.items.len;
                while (pi > 1) {
                    pi -= 1;
                    const outer = &coro_stack.items[pi - 1];
                    if (outer.pending_err) |pe| {
                        outer.pending_err = null;
                        try pumpExit(self, out, persist);
                        return .{ .err = mapDriverErr(a, pe) };
                    }
                }
            }
            countSleep(.root_parked);
            sleepMillis(1);
            continue;
        }

        // 4. Nothing queued, nothing ready, no timers: done (or
        //    deadlocked on an indefinitely-parked coroutine with no
        //    resumer).
        break;
    }
    return null;
}

/// Driver exit protocol. Ordering closes the persist/post race with a
/// resumer on another thread:
///   1. persist every indefinitely-parked continuation (persist mode) —
///      a racing resumer that misses the mailbox finds the state here;
///   2. close the mailbox and take whatever raced in before the close —
///      any later `postResume` is rejected and reroutes itself;
///   3. release this driver's global slot-owner entries;
///   4. re-route the raced-in entries through the persisted registry.
fn pumpExit(self: *VmIntrinsicHost, out: Output, persist: bool) Allocator.Error!void {
    const a = self.allocator;
    if (persist) {
        const saved = try (coroTop().?).drainIndefiniteParked(a);
        defer a.free(saved);
        for (saved) |s| try PersistedParked.put(s.slot, s.state, s.scope_delta);
    }
    // Queued-but-unstarted child launches must still run: dispatch guarantees
    // a dispatched block eventually executes. A root that exits with a throw
    // (a `coroutineScope` body failing) has just CANCELLED those children —
    // but a cancelled coroutine only COMPLETES when its start task runs and
    // observes the dead Job. Dropping the tasks here left every such child
    // active forever, and the scope's completing-waiting-children state (and
    // every awaiter of it) hung. Hand them to the enclosing pump.
    var orphan_launched: []Value = &.{};
    if (coroTop()) |top| {
        if (top.launched.items.len != 0) orphan_launched = try top.drainLaunched(a);
    }
    defer if (orphan_launched.len != 0) a.free(orphan_launched);
    // A stashed inline-resume failure this pump never got to raise (its exit
    // path skipped the loop-head check) must not die with it: hand it to the
    // pump below, whose loop-head raises it. Dropping it here left the failed
    // activation's coroutine incomplete and every awaiter parked forever.
    if (coroTop()) |top| {
        if (top.pending_err) |pe| {
            top.pending_err = null;
            if (coro_stack.items.len >= 2) {
                const below = &coro_stack.items[coro_stack.items.len - 2];
                if (below.pending_err == null) below.pending_err = pe;
                if (pumpDiagEnabled()) std.debug.print("[tok] pumpExit hands pending_err down\n", .{});
            } else if (pumpDiagEnabled()) {
                std.debug.print("[tok] pumpExit DROPS pending_err (last pump)\n", .{});
            }
        }
    }
    var leftovers: []DriverWakeup.MailboxEntry = &.{};
    if (coroPop()) |w| {
        var ww = w;
        {
            const g = ww.borrowMut();
            leftovers = g.get().closeAndDrain(a) catch &.{};
            g.get().releaseOwnedSlots();
            g.deinit();
        }
        ww.deinit();
    }
    if (orphan_launched.len != 0) {
        if (coroTop()) |below| {
            // Ownership transfers: the drained blocks carry the retain their
            // original enqueue took.
            for (orphan_launched) |b| try below.launched.append(below.allocator, b);
            if (pumpDiagEnabled())
                std.debug.print("[PUMP] pumpExit hands {d} unstarted launch(es) down\n", .{orphan_launched.len});
        } else {
            if (runtime.reclaimEnabled()) for (orphan_launched) |b| b.release(a);
            if (pumpDiagEnabled())
                std.debug.print("[PUMP] pumpExit drops {d} unstarted launch(es) (last pump)\n", .{orphan_launched.len});
        }
    }
    defer if (leftovers.len != 0) a.free(leftovers);
    for (leftovers) |entry| {
        if (PersistedParked.take(entry.slot)) |pe| {
            try driveResumed(self, pe.state, entry.value, pe.scope_delta, out);
            coroStackAllocator().free(pe.scope_delta);
        }
        // No persisted state: the waiter was abandoned with its driver
        // (a runBlocking exit) — the entry has nowhere to land.
    }
}

var pump_diag_state: u8 = 0;

pub fn pumpDiagEnabled() bool {
    if (pump_diag_state == 0) {
        const v = runtime.procEnvGetVar(std.heap.page_allocator, "KLIO_PUMP_DIAG") catch null;
        pump_diag_state = if (v != null) 2 else 1;
    }
    return pump_diag_state == 2;
}

/// One-shot stderr dump of a blocking pump that has idled for several
/// seconds with its root still parked - the shape of a lost resume.
/// Gated on `KLIO_PUMP_DIAG`; a diagnosis aid, never load-bearing.
fn diagStalledPump(self: *VmIntrinsicHost, top: *CooperativeInterceptor, root_tok: ?u64, force: bool) void {
    if (!force and !pumpDiagEnabled()) return;
    std.debug.print("[PUMP] stalled root_tok={?d} parked={d} ready={d} launched={d} pumps={d}\n", .{
        root_tok, top.parked.count(), top.ready.items.len, top.launched.items.len, coro_stack.items.len,
    });
    // EVERY interceptor on this thread: a cancelled-but-uncompleted
    // coroutine's body can be parked in a NESTED pump the top-only view
    // never shows. Name the parked frames (innermost first) so a caught
    // hang says WHERE each stuck coroutine is suspended, not just how deep.
    VirtualClock.dumpState();
    const mg = self.module.borrow();
    defer mg.deinit();
    for (coro_stack.items, 0..) |*drv, di| {
        std.debug.print("[PUMP] pump[{d}] clk={d} vnow={d} mode={s}\n", .{
            di, drv.clock_id, drv.virtual_now, @tagName(drv.mode),
        });
        var pit = drv.parked.iterator();
        while (pit.next()) |e| {
            std.debug.print("[PUMP] pump[{d}] parked tok={d} wake={d} frames={d}:", .{
                di, e.key_ptr.*, e.value_ptr.wake_at, e.value_ptr.state.frames.items.len,
            });
            const st = &e.value_ptr.state;
            var k: usize = 0;
            while (k < st.frames.items.len and k < 12) : (k += 1) {
                const snap = st.frames.items[k];
                const m: *const ir.Module = snap.module orelse mg.get();
                const f = m.funcById(snap.func);
                const nm = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "?";
                std.debug.print(" {s}", .{nm});
            }
            std.debug.print("\n", .{});
        }
    }
    var it = top.slot_to_token.iterator();
    while (it.next()) |e| {
        std.debug.print("[PUMP] slot={d} -> tok={d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    SlotOwners.mutex.lock();
    if (SlotOwners.map) |*m| {
        std.debug.print("[PUMP] slot_owners={d}\n", .{m.count()});
    }
    if (SlotOwners.pending) |*p| {
        std.debug.print("[PUMP] pending_resumes={d}\n", .{p.count()});
    }
    SlotOwners.mutex.unlock();
    PersistedParked.mutex.lock();
    if (PersistedParked.map) |*m| {
        std.debug.print("[PUMP] persisted={d}\n", .{m.count()});
    }
    PersistedParked.mutex.unlock();
}

/// Drain everything the worker-thread mailbox posted into the interceptor
/// as slot resumes. Returns whether any entry was routed.
fn drainWakeupInto(allocator: Allocator, wakeup: *const ObjRef(DriverWakeup), top: *CooperativeInterceptor) Allocator.Error!bool {
    const drained = blk: {
        const g = wakeup.borrowMut();
        defer g.deinit();
        break :blk try g.get().drainMailbox(allocator);
    };
    defer allocator.free(drained);
    for (drained) |entry| {
        const routed = try top.resumeSlotValue(entry.slot, entry.value);
        if (pumpDiagEnabled())
            std.debug.print("[PUMP] drain slot={d} routed={}\n", .{ entry.slot, routed });
    }
    return drained.len != 0;
}

// -------------------------------------------------------------------------
// `runtime.IntrinsicHost` coroutine vtable entry points.
// -------------------------------------------------------------------------

pub fn runBlocking(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return driveRunBlocking(self, block, scope, out);
}

pub fn coroutineRunRoot(self: *VmIntrinsicHost, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    // Already inside a cooperative driver (a child started by `launch`
    // while a `runBlocking` loop runs): join the enclosing interceptor
    // rather than spinning an isolated root. The block runs on the shared
    // virtual clock; if it suspends, its activation is parked on the
    // active interceptor and the start completes normally (the enclosing
    // driver resumes it when its slot/timer is due).
    if (coroTop() != null) {
        const a = self.allocator;
        // Make the coroutine's own scope active while the block runs so a
        // suspend-implicit `coroutineContext` read resolves to its `Job`.
        const scope_base = activeScopeDepth();
        var guard = ActiveScopeGuard{ .pushed = false };
        if (scope) |s| guard = ActiveScopeGuard.enter(s);
        defer guard.leave();
        switch (try intrinsic_host.evalClosureRaw(self, block, &.{}, null, out)) {
            .ok => |v| return .{ .ok = v },
            .err => |e| switch (e) {
                .Suspended => |st| {
                    // The activation parks with its own scope (this guard's
                    // push plus anything the block pushed) carried in its
                    // ParkedEntry, re-established on resume. `park` removes
                    // them from the live stack, so the guard must not pop
                    // again on its `defer`.
                    guard.pushed = false;
                    _ = try park(a, st, scope_base);
                    return .{ .ok = Value.Unit };
                },
                .Throw => |v| return .{ .err = .{ .Thrown = v } },
                .NonLocalReturn => |v| return .{ .err = .{ .Return = v } },
                else => return .{ .err = mapDriverErr(a, e) },
            },
        }
    }
    const unit: Value = .Unit;
    return driveRoot(self, block, if (scope) |s| s else &unit, out, true);
}

/// Whether an enclosing cooperative driver is live on this thread. The
/// Kotlin start intrinsics branch on this: with a driver, an undispatched
/// block joins the enclosing pump; without one, it must become its own
/// root (`coroutineStartRootOrSuspended`).
pub fn coroutineHasDriver() bool {
    return coroTop() != null;
}

/// The flat-driver counterpart of `coroutineStartRootOrSuspended`'s
/// enclosing-driver branch entry: capture the scope base and push the
/// scope guard, exactly as `ActiveScopeGuard.enter` does. Returned ident
/// is 0 when nothing was pushed.
pub const UndispatchedEnter = struct { base: usize, ident: usize };
pub fn undispatchedFlatEnter(scope: *const Value) UndispatchedEnter {
    const base = activeScopeDepth();
    const g = ActiveScopeGuard.enter(scope);
    return .{ .base = base, .ident = if (g.pushed) g.ident else 0 };
}

/// Undo `undispatchedFlatEnter`'s push by identity (the guard's `leave`
/// semantics — never a blind top pop). No-op for ident 0 or when the
/// entry was already captured into a parked scope delta.
pub fn undispatchedFlatLeaveIdent(ident: usize) void {
    if (ident == 0) return;
    (ActiveScopeGuard{ .pushed = true, .ident = ident }).leave();
}

/// Barrier park for a flat undispatched-start activation: hand the parked
/// segment (with its scope delta above `scope_base`) to the enclosing
/// pump, exactly as the recursive branch's `park` does, and return the
/// value the Kotlin caller continues with. Ownership of `st` moves to the
/// pump.
pub fn undispatchedFlatPark(allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!Value {
    if (pumpDiagEnabled()) std.debug.print("[tok] barrier-park frames={d}\n", .{st.frames.items.len});
    _ = try park(allocator, st, scope_base);
    return Value.CoroutineSuspended;
}

/// Run `block` as a fresh root on this thread with NO enclosing driver
/// (`DeepRecursive`'s plain `runCallLoop` driving suspend blocks through
/// `startCoroutineUninterceptedOrReturn`). A synchronous completion
/// returns the block's value directly. A genuine suspension parks the
/// root, pumps to quiescence, persists the parked root under its armed
/// slot (`pumpExit` persist mode), and returns `Value.CoroutineSuspended`
/// — the eventual async completion arrives through the continuation
/// captured at the suspension point (`coroutineResumeExternal` →
/// `PersistedParked.take` → `driveResumed`), exactly like the ktor
/// ByteChannel write side.
pub fn coroutineStartRootOrSuspended(self: *VmIntrinsicHost, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    const a = self.allocator;
    const unit: Value = .Unit;
    const scope_v: *const Value = if (scope) |s| s else &unit;

    // Inside an existing driver, undispatched start runs only the synchronous
    // prefix. A real suspension is parked directly onto the enclosing pump and
    // reported to the Kotlin caller; the parent then continues and the parked
    // tail resumes in ordinary queue order. This is the defining
    // startCoroutineUninterceptedOrReturn boundary.
    if (coroTop() != null) {
        const scope_base = activeScopeDepth();
        var guard = ActiveScopeGuard.enter(scope_v);
        defer guard.leave();
        switch (try intrinsic_host.evalClosureRaw(self, block, &.{}, scope_v, out)) {
            .ok => |v| return .{ .ok = v },
            .err => |e| switch (e) {
                .Suspended => |st| {
                    guard.pushed = false;
                    _ = try park(a, st, scope_base);
                    return .{ .ok = Value.CoroutineSuspended };
                },
                else => return .{ .err = mapDriverErr(a, e) },
            },
        }
    }

    try coroPush(a);
    if (!vmhost.scheduler.onPoolWorker()) (coroTop().?).claimNow();
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    const guard = ActiveScopeGuard.enter(scope_v);
    defer guard.leave();

    // Base below the guard's push, as in `driveRoot`: the root's park
    // carries its coroutine scope so a persisted root resumes with
    // `coroutineContext` (Job + interceptor) intact on any later pump.
    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    const root_scope_base = scope_depth;
    switch (try intrinsic_host.evalClosureRaw(self, block, &.{}, scope_v, out)) {
        .ok => |v| root_value = v,
        .err => |e| switch (e) {
            .Suspended => |st| root_token = try park(a, st, root_scope_base),
            .Throw => |v| {
                try pumpExit(self, out, true);
                return .{ .err = .{ .Thrown = v } };
            },
            else => {
                try pumpExit(self, out, true);
                return .{ .err = mapDriverErr(a, e) };
            },
        },
    }
    if (try pumpLoop(self, scope_v, out, true, true, &root_token, &root_value)) |err_result| {
        return err_result;
    }
    try pumpExit(self, out, true);
    // Root still parked after quiescence: it is persisted awaiting an
    // external resume — report suspension to the Kotlin caller.
    if (root_token != null) return .{ .ok = Value.CoroutineSuspended };
    return .{ .ok = root_value orelse Value.Unit };
}

pub fn coroutineLaunch(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!?RuntimeError {
    _ = scope;
    if (coroTop()) |top| {
        try top.enqueueLaunch(block.*);
        return null;
    }
    // No active runBlocking — run the child eagerly.
    const r = try intrinsic_host.invokeCallable(self, block, &.{}, out);
    return switch (r) {
        .ok => null,
        .err => |e| e,
    };
}

/// `withTimeout`'s `invokeOnTimeout` schedules its cancellation gate through
/// this. The gate belongs with the block it cancels, which runs as its own
/// nested pump (the undispatched split); queue the gate on a distinct list so
/// `coroutineStartRootOrSuspended` can move it onto that pump and let the
/// earliest of the two deadlines fire first. A gate scheduled with no
/// enclosing pump runs eagerly, exactly like a bare launch.
pub fn coroutineSpawnTimeout(self: *VmIntrinsicHost, block: *const Value, out: Output) Allocator.Error!?RuntimeError {
    if (coroTop()) |top| {
        try top.enqueueTimeout(block.*);
        return null;
    }
    const r = try intrinsic_host.invokeCallable(self, block, &.{}, out);
    return switch (r) {
        .ok => null,
        .err => |e| e,
    };
}

pub fn coroutineArmSlot(self: *VmIntrinsicHost, slot: i64) void {
    _ = self;
    if (coroTop()) |top| top.setPendingSlot(slot) catch {};
}

pub fn coroutineDisarmSlot(self: *VmIntrinsicHost) void {
    _ = self;
    if (coroTop()) |top| top.clearPendingSlot();
}

/// Push the active coroutine scope for an undispatched block running
/// inline in the caller's activation (`startCoroutineUninterceptedOrReturn`
/// over a `ScopeCoroutine` / `TimeoutCoroutine`). The suspend-implicit
/// `coroutineContext` then resolves to the block's own coroutine, so a
/// cancellable suspension inside it installs its parent-cancellation
/// handle on the right Job. Balanced by `coroutinePopScope` from the
/// Kotlin side (the pop is skipped over a suspension unwind and runs
/// when the resumed body finally completes).
pub fn coroutinePushScope(scope: *const Value) void {
    if (scopeDiagOn())
        std.debug.print("[scope] push depth={d} id={x}\n", .{ active_scope_stack.items.len, scopeIdent(scope) });
    active_scope_stack.append(coroStackAllocator(), scope.*) catch {};
}

pub fn coroutineScopeIdent(v: *const Value) usize {
    return scopeIdent(v);
}

pub fn coroutinePopScope() void {
    if (scopeDiagOn() and active_scope_stack.items.len != 0)
        std.debug.print("[scope] pop depth={d} id={x}\n", .{ active_scope_stack.items.len - 1, scopeIdent(&active_scope_stack.items[active_scope_stack.items.len - 1]) });
    if (active_scope_stack.items.len != 0) {
        _ = active_scope_stack.pop();
    }
}

pub fn coroutineResumeSlotValue(self: *VmIntrinsicHost, slot: i64, value: Value) void {
    // Same routing as `coroutineResumeExternal`: the waiter may be parked
    // on this thread's pump, on a live pump on another OS thread (a
    // channel receiver parked in the runBlocking driver while a
    // dispatcher worker sends), or persisted after its pump exited. The
    // shared output sink carries any inline drive's writes.
    coroutineResumeExternal(self, slot, value, self.out_sink.output()) catch {};
}

/// Name of the innermost function in a parked activation — diagnostics only.
fn parkedFuncName(self: *VmIntrinsicHost, st: *const SuspendState) []const u8 {
    if (st.frames.items.len == 0) return "<empty>";
    const snap = st.frames.items[0];
    const mg = self.module.borrow();
    defer mg.deinit();
    const m: *const ir.Module = snap.module orelse mg.get();
    const f = m.funcById(snap.func) orelse return "<unknown>";
    return if (f.fqn.len != 0) f.fqn else f.name;
}

/// Escape hatch: queue every continuation resume on the pump instead of running
/// it on the caller's stack (the pre-dispatch-aware behaviour). Diagnostics only.
fn inlineResumeEnabled() bool {
    return runtime.getenvSlice("KLIO_NO_INLINE_RESUME") == null;
}

/// The persisted inline-resume path (`resumePersistedOnTop`) lets the Compose
/// recomposer, parked inside a `withContext`/`coroutineScope` frame, wake and
/// settle synchronously while a test-scheduler advance is in progress. It ships
/// unconditionally now (the plugin is the only compose path); the coroutine
/// suites hold at baseline with it on.
fn persistResumeGateEnabled() bool {
    return true;
}

/// Resume the activation parked on `slot` on the current stack. Returns false
/// when no pump on this thread holds the slot, or it is a pump's own root.
/// A resume that arrived while another one was already running inline on this
/// thread. Kotlin's unconfined event loop does the same thing: the coroutine
/// step still runs before control leaves the resumer, but on the OUTERMOST
/// inline resume's stack rather than nested inside the current one. Without
/// this a rendezvous hand-off (a `SharedFlow` emitter and its collector
/// resuming each other) recurses natively until the stack dies.
threadlocal var inline_depth: usize = 0;

/// Inline resumes performed since the pump last ran an activation. An activation
/// that never suspends (`while (isActive) flow.emit(…)`) would otherwise resume
/// its peer inline for ever: the peer re-arms as a waiter, the next emit finds it
/// ready, and the emitter never parks — so the pump never turns, the scheduler
/// never runs, and virtual time never advances. Past the budget its resumes go
/// back on the queue, which restores the back-pressure that makes it park.
threadlocal var inline_turn_resumes: usize = 0;

/// How deep one resume may chase the resumes it causes before the rest go back
/// on the pump queue. Deep enough for a recomposition's chain, far short of an
/// unbounded hand-off loop.
const INLINE_CHAIN_BUDGET: usize = 32;

/// How many resumes one pump turn may run inline. Far above what driving a frame
/// of recomposition needs, far below a hand-off loop's appetite.
const INLINE_TURN_BUDGET: usize = 2048;

/// How many PERSISTED resumes one synchronous scheduler advance may run inline
/// (`resumePersistedOnTop`). Driving a recomposition frame to quiescence needs
/// only a handful (recomposer wake, frame launch, frame fire, recompose); a
/// `while (isActive) yield()` body re-dispatching every turn is deferred once
/// past this, so `advanceUntilIdle` goes idle instead of spinning. Reset when
/// the pump actually turns (it does not during an advance).
const PERSIST_INLINE_BUDGET: usize = 64;

/// Persisted resumes run inline since the pump last turned. Distinct from
/// `inline_turn_resumes` so the tight per-advance cap does not also throttle the
/// established live-pump inline path (`resumeInlineOnce`).
threadlocal var persist_inline_resumes: usize = 0;

pub fn coroutineResumeInline(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) Allocator.Error!bool {
    if (!inlineResumeEnabled()) return false;
    if (!slotParkedHere(slot)) return false;
    // A resume RAISED BY a step already running inline may itself run inline —
    // a composition recomposing inside a frame resumes several coroutines in a
    // chain, and every one of them owes its work to the caller that advanced the
    // clock. But the chain must be BOUNDED: a rendezvous hand-off (a `SharedFlow`
    // emitter and its collector resume each other with no suspension in between)
    // never ends, and following it inline means control never returns to the
    // caller and virtual time never advances. Past the budget the remaining steps
    // go back on the pump queue, which is where they ran before.
    if (inline_depth >= INLINE_CHAIN_BUDGET) return false;
    if (inline_turn_resumes >= INLINE_TURN_BUDGET) return false;
    // Dispatcher FIFO on a `runBlocking` event loop: if the pump owning this
    // slot already has other ready coroutines queued, the inline shortcut would
    // jump ahead of them. Upstream's event-loop dispatcher runs queued resumes
    // in the order they were posted, so a `yield` (or any dispatched resume)
    // must fall behind a coroutine a native channel/StateFlow waiter already
    // made ready. Defer to the queue — `coroutineResumeExternal` appends behind
    // the ready work, and the Wall pump's own loop drains it in order.
    //
    // Scoped to Wall pumps (`runBlocking`): a Virtual pump (`runTest`) drives
    // its body through inline resumes with no pump turn, and routes native
    // channel deliveries through the scheduler's own dispatch queue
    // (`__kxco_chanResumeRoute`), so deferring there would strand the resume
    // (including a teardown cancel) with nothing to drain it. The inline
    // shortcut also stays sound whenever the ready queue is empty (it then IS
    // the next task), preserving the fast path and the compose recomposition
    // chain, which resumes into an empty queue.
    if (ownerReadyPending(slot)) return false;
    inline_turn_resumes += 1;
    inline_depth += 1;
    defer inline_depth -= 1;
    return resumeInlineOnce(self, slot, value, out);
}

/// Mark the pump on this thread that owns `slot` as driven by an external
/// dispatcher (a `runTest` `TestCoroutineScheduler`): a native channel delivery
/// to one of its waiters routed through that dispatcher's own queue
/// (`__kxco_chanResumeRoute` code 1) rather than the pump's ready queue. Such a
/// pump orders its dispatched resumes elsewhere, so the inline shortcut must NOT
/// defer them to `drv.ready` — doing so strands them until the scheduler idles.
/// Falls back to the innermost pump when the slot is not bound to a pump yet.
pub fn markSlotOwnerSchedulerBacked(slot: i64) void {
    var i: usize = coro_stack.items.len;
    while (i > 0) {
        i -= 1;
        const drv = &coro_stack.items[i];
        if (drv.slot_to_token.get(slot) != null) {
            drv.scheduler_backed = true;
            return;
        }
    }
    if (coro_stack.items.len != 0) coro_stack.items[coro_stack.items.len - 1].scheduler_backed = true;
}

/// Does a pump on this thread that owns `slot` have a live parked coroutine
/// queued ready that this resume must fall behind? A dispatched resume (a
/// `yield`, a pump-backed channel delivery) runs its dispatcher's FIFO queue in
/// post order, so it must not jump a coroutine already made ready — this holds
/// under BOTH time modes for a plain pump. A `scheduler_backed` pump (`runTest`)
/// keeps the inline shortcut: it orders its dispatched resumes on the
/// `TestCoroutineScheduler`, not `drv.ready`. Stale `ready` tokens (already
/// resumed inline, no `parked` entry) never count.
fn ownerReadyPending(slot: i64) bool {
    var i: usize = coro_stack.items.len;
    while (i > 0) {
        i -= 1;
        const drv = &coro_stack.items[i];
        if (drv.slot_to_token.get(slot) != null) {
            if (drv.scheduler_backed) return false;
            for (drv.ready.items) |rtok| {
                if (drv.parked.contains(rtok)) return true;
            }
            return false;
        }
    }
    return false;
}

/// Is `slot` held by a pump on this thread and parked (not this pump's root)?
fn slotParkedHere(slot: i64) bool {
    var i: usize = coro_stack.items.len;
    while (i > 0) {
        i -= 1;
        const drv = &coro_stack.items[i];
        const tok = drv.slot_to_token.get(slot) orelse continue;
        if (drv.root_tok != null and drv.root_tok.? == tok) return false;
        return drv.parked.contains(tok);
    }
    return false;
}

fn resumeInlineOnce(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) Allocator.Error!bool {
    var i: usize = coro_stack.items.len;
    while (i > 0) {
        i -= 1;
        var entry = coro_stack.items[i].claimSlotForInline(slot) orelse continue;
        const a = self.allocator;
        if (pumpDiagEnabled())
            std.debug.print("[PUMP] resumeInline slot={d} fn={s}\n", .{ slot, parkedFuncName(self, &entry.state) });
        const scope_base = activeScopeDepth();
        restoreScopeDelta(entry.scope_delta);
        coroStackAllocator().free(entry.scope_delta);
        ir.eval.resume_route = "inline-claim";
        switch (try intrinsic_host.resumeRaw(self, &entry.state, value, out)) {
            .ok => {},
            .err => |e| switch (e) {
                // `park` captures the activation's scope delta off the live
                // stack, so it must run before the truncation below.
                .Suspended => |st| {
                    _ = try parkInto(&coro_stack.items[i], a, st, scope_base);
                },
                // A cancelled child's throw dies with it, as in the drive loop.
                // Every other failure belongs to the pump that owns this
                // activation: leave it there rather than dropping it, or the
                // coroutine simply never completes and its awaiters hang.
                .Throw => |v| {
                    if (!root.isCancellationException(&v)) {
                        if (pumpDiagEnabled()) std.debug.print("[tok] inline-resume THROW held as pending_err\n", .{});
                        coro_stack.items[i].pending_err = e;
                    }
                },
                else => {
                    if (pumpDiagEnabled()) std.debug.print("[tok] inline-resume ERR held as pending_err: {s}\n", .{@tagName(std.meta.activeTag(e))});
                    coro_stack.items[i].pending_err = e;
                },
            },
        }
        // The resumed activation ran on THIS stack: anything it left on the
        // active-scope stack would be read as the HOST activation's coroutine
        // scope by the next `coroutineContext`. The pump resumes on a clean
        // stack and never has to care; an inline resume restores what it found.
        if (active_scope_stack.items.len > scope_base)
            active_scope_stack.shrinkRetainingCapacity(scope_base);
        return true;
    }
    return false;
}

/// A Kotlin `Continuation.resumeWith` — the coroutine's own state-machine step.
/// Kotlin runs it on the caller's stack; whether a resume is DISPATCHED at all
/// was decided above this, by the continuation's interceptor. Only a step this
/// thread's pumps do not own falls back to the queue / mailbox route.
///
/// klio's NATIVE suspensions (a channel waiter) do not pass through an
/// interceptor at all, so for them the pump queue IS the dispatch: they keep
/// using `coroutineResumeExternal` and run on a later pump turn.
/// A Kotlin-level `Continuation.resumeWith` delivery is in flight on this
/// thread. A PERSISTED target must then run on the caller's stack (the
/// dispatcher running the resume decided this is its moment), not defer to a
/// later pump turn — a `runTest` scheduler advance would otherwise go idle
/// with the resumed coroutine still queued and never run it.
threadlocal var kotlin_resume_delivery: bool = false;

pub fn coroutineResumeContinuation(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) Allocator.Error!void {
    // KLIO_RESUME_TRACE: name the RESUMER — the route prints below show the
    // frames a delivery re-runs, but a double-delivery diagnosis needs to know
    // which Kotlin code performed each `Continuation.resumeWith`.
    if (runtime.getenvSlice("KLIO_RESUME_TRACE") != null) {
        std.debug.print("[resume-call] slot={d} resumer:\n", .{slot});
        ir.eval.dumpFrameChainForDiagAlways();
    }
    if (try coroutineResumeInline(self, slot, value, out)) return;
    const prev = kotlin_resume_delivery;
    kotlin_resume_delivery = true;
    defer kotlin_resume_delivery = prev;
    return coroutineResumeExternal(self, slot, value, out);
}

/// Resume a persisted coroutine (its owning drive already exited) on THIS
/// thread's existing live pump, on the caller's stack — one step, re-parking
/// into the same pump. Gated on the Compose lowering plugin
/// (`persistResumeGateEnabled`): when a snapshot apply resumes the recomposer
/// while the runBlocking pump `coroTop` is blocked in an `advanceTimeBy`,
/// adopting the resume onto the pump's ready queue would defer it until the
/// advance returns — the recomposer would never reach the `withFrameNanos`
/// that schedules its frame, so a state change never settles. Running it on the
/// existing pump (not a fresh one) keeps its later suspension owned by a live
/// pump, so the next resume takes the ordinary inline path. Off outside the
/// compose plugin, so the coroutine suites keep their pre-existing deferral.
/// Bounded: `inline_depth` caps nested resumes; `persist_inline_resumes` caps
/// the total inline resumes since the pump last turned, so a re-dispatching
/// body cannot spin unbounded.
fn resumePersistedOnTop(self: *VmIntrinsicHost, pe: PersistedParked.Entry, value: Value, out: Output) Allocator.Error!bool {
    if (!inlineResumeEnabled()) return false;
    if (!persistResumeGateEnabled() and !kotlin_resume_delivery) return false;
    if (coroTop() == null) return false;
    if (inline_depth >= INLINE_CHAIN_BUDGET) return false;
    if (persist_inline_resumes >= PERSIST_INLINE_BUDGET) return false;
    persist_inline_resumes += 1;
    inline_depth += 1;
    defer inline_depth -= 1;
    const a = self.allocator;
    // Restore the coroutine's own scope for the step, then shrink back so a
    // re-park's `finally` pop (skipped over the suspension) is re-captured and
    // the caller's scope stack is left exactly as found.
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    var state = pe.state;
    const scope_base = activeScopeDepth();
    restoreScopeDelta(pe.scope_delta);
    coroStackAllocator().free(pe.scope_delta);
    ir.eval.resume_route = "persisted-on-top";
    switch (try intrinsic_host.resumeRaw(self, &state, value, out)) {
        .ok => {},
        // A re-suspension re-parks onto the existing live pump (`park` targets
        // `coroTop`), so it stays inline-resumable.
        .err => |e| switch (e) {
            .Suspended => |st| _ = try park(a, st, scope_base),
            // A cancelled child's throw dies with it, exactly as on the
            // other resume paths. EVERY other outcome — an AssertionError
            // out of a test body, a Vm miss — must reach the pump: the
            // silent discard here turned every throwing test body under
            // the compose plugin into an indefinite hang (the coroutine's
            // Job never completed, and runTest joined against it forever).
            .Throw => |v| {
                if (!root.isCancellationException(&v)) {
                    if (coro_stack.items.len != 0)
                        coro_stack.items[coro_stack.items.len - 1].pending_err = e;
                }
            },
            else => {
                if (coro_stack.items.len != 0)
                    coro_stack.items[coro_stack.items.len - 1].pending_err = e;
            },
        },
    }
    return true;
}

pub fn coroutineResumeExternal(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) Allocator.Error!void {
    if (pumpDiagEnabled()) std.debug.print("[PUMP] resumeExternal slot={d} tid={d}\n", .{ slot, std.Thread.getCurrentId() });
    // A live cooperative driver on THIS thread still holding the slot?
    // Enqueue there — its drive loop runs the activation.
    {
        var i: usize = coro_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (coro_stack.items[i].resumeSlotValue(slot, value) catch false) return;
        }
    }
    // Cross-thread: the slot is owned by a live driver on another OS
    // thread (e.g. a `Dispatchers.Default` worker resuming `await` back
    // on the main `runBlocking` pump). Route through that driver's
    // mailbox; a rejected post means the driver just exited and persisted
    // its parked coroutines, so fall through to the persisted registry.
    // A slot with no owner and no persisted state belongs to a waiter
    // that has published itself but not yet armed (the registration gap);
    // the resume parks in the pending stash, which `registerSlotOwner`
    // claims under the same lock — never dropped.
    while (true) {
        if (lookupSlotOwner(slot)) |w| {
            var ww = w;
            defer ww.deinit();
            const posted = blk: {
                const g = ww.borrowMut();
                defer g.deinit();
                break :blk try g.get().postResume(slot, value);
            };
            if (posted) return;
            // Mailbox closed: the owner just exited and persisted its
            // parked coroutines strictly before closing.
            if (PersistedParked.take(slot)) |pe| {
                if (try resumePersistedOnTop(self, pe, value, out)) return;
                if (coroTop()) |top| {
                    try top.adoptPersisted(pe.state, pe.scope_delta, value);
                } else {
                    try driveResumed(self, pe.state, value, pe.scope_delta, out);
                    coroStackAllocator().free(pe.scope_delta);
                }
            }
            // No persisted state either: the waiter was abandoned with
            // its driver (a runBlocking exit) — nowhere to land.
            return;
        }
        // The coroutine parked inside a driven root that already
        // returned; its state was persisted. With a pump live on this
        // thread, adopt it there (the resume-chain flattener: nesting a
        // fresh drive per unwind hop stacks native drivers thousands
        // deep under DeepRecursive's trampoline). Otherwise claim it
        // (single winner) and drive it to quiescence on this thread
        // under a fresh pump — the cross-pump resume that lets a
        // coroutine continue on a different OS thread.
        if (PersistedParked.take(slot)) |pe| {
            if (try resumePersistedOnTop(self, pe, value, out)) return;
            if (coroTop()) |top| {
                try top.adoptPersisted(pe.state, pe.scope_delta, value);
                return;
            }
            try driveResumed(self, pe.state, value, pe.scope_delta, out);
            coroStackAllocator().free(pe.scope_delta);
            return;
        }
        if (try SlotOwners.stashPendingIfUnowned(slot, value)) return;
        // An owner registered between the miss and the stash; retry the
        // owner route.
    }
}

pub fn coroutineDrainToIdle(self: *VmIntrinsicHost, out: Output) Allocator.Error!?RuntimeError {
    const a = self.allocator;
    while (true) {
        const top = coroTop() orelse break;
        const launched = try top.drainLaunched(a);
        defer a.free(launched);
        const scope = activeCoroScope() orelse Value.Unit;
        for (launched) |child| {
            const child_scope_base = activeScopeDepth();
            const child_res = try intrinsic_host.evalClosureRaw(self, &child, &.{}, &scope, out);
            switch (child_res) {
                .ok => if (runtime.reclaimEnabled()) child.release(a),
                .err => |e| switch (e) {
                    .Suspended => |st| _ = try park(a, st, child_scope_base),
                    .Throw => |v| {
                        if (!root.isCancellationException(&v)) return mapDriverErr(a, e);
                    },
                    else => return mapDriverErr(a, e),
                },
            }
        }
        // Re-drain after any start so a freshly scheduled timer parks
        // before the clock can advance (same ordering as `pumpLoop`).
        if (launched.len != 0) continue;
        if ((coroTop().?).nextReady()) |tok| {
            endStreak("ready");
            if ((coroTop().?).takeParked(tok)) |entry_in| {
                var entry = entry_in;
                const resume_with = (coroTop().?).takeResumeValue(tok) orelse Value.Unit;
                const scope_base = activeScopeDepth();
                restoreScopeDelta(entry.scope_delta);
                coroStackAllocator().free(entry.scope_delta);
                ir.eval.resume_route = "drain-ready";
                switch (try intrinsic_host.resumeRaw(self, &entry.state, resume_with, out)) {
                    .ok => {},
                    .err => |e| switch (e) {
                        .Suspended => |st2| _ = try park(a, st2, scope_base),
                        .Throw => |v| {
                            if (!root.isCancellationException(&v)) return mapDriverErr(a, e);
                        },
                        else => return mapDriverErr(a, e),
                    },
                }
            }
            continue;
        }
        switch (try (coroTop().?).advanceTimeGated()) {
            // `.waiting`: a Wall timer pends and one sleep slice was taken
            // inside the gate — keep spinning toward it, as the old
            // fired-while-pending contract did.
            .fired, .waiting => continue,
            .none, .blocked => break,
        }
    }
    return null;
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "pump-root scope base sits below the guard so a persisted root carries its scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Minimal Instance scope (the shape `ActiveScopeGuard` pushes).
    const cls: runtime.ClassDef = .{
        .name = "S",
        .fqn = "S",
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try runtime.ObjRef(?runtime.ObjRef(runtime.InstanceData)).init(a, null),
        .enclosing_class = try runtime.ObjRef(?runtime.ObjRef(runtime.ClassDef)).init(a, null),
        .nested_classes = &.{},
        .captured_env = try runtime.ObjRef(runtime.Env).init(a, runtime.Env.init(a)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try runtime.ObjRef(?runtime.ObjRef(runtime.InstanceData)).init(a, null),
    };
    const cls_ref = try runtime.ObjRef(runtime.ClassDef).init(a, cls);
    const inst = try runtime.ObjRef(runtime.InstanceData).init(a, .{
        .class = cls_ref,
        .fields = .empty,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    const scope: Value = .{ .Instance = inst };

    // The contract `driveRoot` / `coroutineStartRootOrSuspended` rely on:
    // with the root's scope base read BEFORE the guard's push, a park at
    // that base captures the guard's scope entry into the root's delta
    // (removing it from the live stack), the guard's identity-aware
    // `leave` then no-ops, and a later restore re-establishes the scope
    // for the resumed root. Without this the persisted root resumed with
    // no scope: `coroutineContext` lost its `Job`, no parent-cancellation
    // handle was installed, and a dispatched delay loop out-lived
    // `Job.cancel`.
    const base = activeScopeDepth();
    const guard = ActiveScopeGuard.enter(&scope);
    try testing.expectEqual(base + 1, activeScopeDepth());

    const delta = captureScopeDelta(base);
    defer coroStackAllocator().free(delta);
    try testing.expectEqual(@as(usize, 1), delta.len);
    try testing.expectEqual(scopeIdent(&scope), scopeIdent(&delta[0]));
    try testing.expectEqual(base, activeScopeDepth());

    // The entry moved into the delta: leave must not pop anything else.
    guard.leave();
    try testing.expectEqual(base, activeScopeDepth());

    // The resumed root re-establishes its scope from the delta.
    restoreScopeDelta(delta);
    try testing.expectEqual(base + 1, activeScopeDepth());
    try testing.expectEqual(scopeIdent(&scope), scopeIdent(&activeCoroScope().?));
    _ = active_scope_stack.pop();
    try testing.expectEqual(base, activeScopeDepth());
}

test "intercept_suspend assigns tokens and queues ready / parks timed" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();
    ci.mode = .Virtual;

    // wake_in_millis == 0 -> immediately ready.
    const tok_ready = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 0 }, &.{});
    try testing.expectEqual(@as(u64, 1), tok_ready);
    // positive -> parked on a timer, not ready yet.
    const tok_timed = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 50 }, &.{});
    try testing.expectEqual(@as(u64, 2), tok_timed);

    try testing.expectEqual(@as(?u64, tok_ready), ci.nextReady());
    try testing.expectEqual(@as(?u64, null), ci.nextReady());
}

test "advance_time jumps the virtual clock and arms due tokens in order" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();
    ci.mode = .Virtual;

    const a = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 30 }, &.{});
    const b = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 10 }, &.{});
    _ = a;
    _ = b;
    try testing.expectEqual(@as(?u64, null), ci.nextReady());

    try testing.expect(try ci.advanceTime());
    try testing.expectEqual(@as(i64, 10), ci.virtual_now);
    // The 10ms timer (token 2) is now due; the 30ms one is not.
    try testing.expectEqual(@as(?u64, 2), ci.nextReady());
    try testing.expectEqual(@as(?u64, null), ci.nextReady());
    // The driver consumes the parked activation it just resumed.
    try testing.expect(ci.takeParked(2) != null);

    try testing.expect(try ci.advanceTime());
    try testing.expectEqual(@as(i64, 30), ci.virtual_now);
    try testing.expectEqual(@as(?u64, 1), ci.nextReady());
    try testing.expect(ci.takeParked(1) != null);
}

test "indefinite park survives advance_time and drains by slot" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();
    ci.mode = .Virtual;

    try ci.setPendingSlot(7);
    const tok = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = -1 }, &.{});
    // No timed parks -> no progress.
    try testing.expect(!try ci.advanceTime());

    const drained = try ci.drainIndefiniteParked(testing.allocator);
    defer testing.allocator.free(drained);
    try testing.expectEqual(@as(usize, 1), drained.len);
    try testing.expectEqual(@as(i64, 7), drained[0].slot);
    try testing.expectEqual(tok, drained[0].state.token);
    // The slot registry entry survives the drain so an external resume
    // can still route to the persisted continuation; the driver clears
    // it when the slot is finally consumed.
    const owner = lookupSlotOwner(7);
    try testing.expect(owner != null);
    owner.?.deinit();
    unregisterSlot(7);
}

test "resume_slot_value queues the waiter and records its resume value" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();
    ci.mode = .Virtual;

    try ci.setPendingSlot(3);
    const tok = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = -1 }, &.{});

    try testing.expect(try ci.resumeSlotValue(3, .{ .Int = 42 }));
    try testing.expectEqual(@as(?u64, tok), ci.nextReady());
    const v = ci.takeResumeValue(tok);
    try testing.expect(v != null);
    try testing.expectEqual(@as(i32, 42), v.?.Int);
    // A second resume on the same slot finds no waiter.
    try testing.expect(!try ci.resumeSlot(3));
}

test "launch queue drains FIFO" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();

    try ci.enqueueLaunch(.{ .Int = 1 });
    try ci.enqueueLaunch(.{ .Int = 2 });
    const drained = try ci.drainLaunched(testing.allocator);
    defer testing.allocator.free(drained);
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqual(@as(i32, 1), drained[0].Int);
    try testing.expectEqual(@as(i32, 2), drained[1].Int);
    // A second drain is empty.
    const again = try ci.drainLaunched(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 0), again.len);
}

test "driver wakeup mailbox round-trips and worker counter tracks pending" {
    const wakeup = try DriverWakeup.new(testing.allocator);
    defer wakeup.deinit();
    {
        const w = wakeup.borrowMut();
        defer w.deinit();
        try testing.expectEqual(@as(usize, 0), w.get().pending());
        w.get().workerStarted();
        try testing.expectEqual(@as(usize, 1), w.get().pending());
        try testing.expect(try w.get().postResume(9, .{ .Int = 7 }));
        const drained = try w.get().drainMailbox(testing.allocator);
        defer testing.allocator.free(drained);
        try testing.expectEqual(@as(usize, 1), drained.len);
        try testing.expectEqual(@as(i64, 9), drained[0].slot);
        try testing.expectEqual(@as(i32, 7), drained[0].value.Int);
        w.get().workerDone();
        try testing.expectEqual(@as(usize, 0), w.get().pending());
    }
}

test "slot owner registry routes lookups and clears on release" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();

    try ci.setPendingSlot(101);
    const owner = lookupSlotOwner(101);
    try testing.expect(owner != null);
    owner.?.deinit();

    // Releasing the driver's owned slots drops the registry entry.
    {
        const w = ci.wakeup.borrowMut();
        defer w.deinit();
        w.get().releaseOwnedSlots();
    }
    try testing.expectEqual(@as(?ObjRef(DriverWakeup), null), lookupSlotOwner(101));
}

// -------------------------------------------------------------------------
// Cross-run dangle regression. `setPendingSlot` registers an arena-backed
// `DriverWakeup` clone in the process-global registry. A driver that ends
// on an error/abort/cancel path pops without `releaseOwnedSlots`, leaving
// the entry behind; under the in-process harness the run arena is then
// reset, freeing the cell the stale clone points at. `drainSlotOwners` —
// the run-boundary sweep — must empty the registry before that reset so the
// next run never resolves a slot to a clone into reused arena memory.
// -------------------------------------------------------------------------
test "drainSlotOwners clears registry entries an error path left behind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Run N: a driver arms a slot on its arena-backed wakeup, then exits on
    // an error path (no `releaseOwnedSlots`). The interceptor itself is torn
    // down (the `coroPop` deinit) but the global entry survives.
    const slot: i64 = 909;
    {
        var ci = try CooperativeInterceptor.new(arena.allocator());
        defer ci.deinit();
        try ci.setPendingSlot(slot);
        try testing.expect(lookupSlotOwner(slot) != null);
    }
    // The entry is still live here — exactly the leak the error path causes.
    {
        const stale = lookupSlotOwner(slot);
        try testing.expect(stale != null);
        stale.?.deinit();
    }

    // Run-boundary sweep, then the arena reset that frees run N's cells.
    drainSlotOwners();
    _ = arena.reset(.retain_capacity);

    // Run N+1 reuses the same arena. The registry must be empty — a surviving
    // clone would dangle into the reset arena.
    try testing.expectEqual(@as(?ObjRef(DriverWakeup), null), lookupSlotOwner(slot));
}

// -------------------------------------------------------------------------
// Cross-thread regression: the `DriverWakeup` cell escapes to dispatcher
// worker threads through the process-global `SlotOwners` registry
// (`setPendingSlot` -> `registerSlotOwner`). A `Dispatchers.Default`/`IO`
// worker resumes a parent `await`/`join` by `lookupSlotOwner` +
// `borrowMut(postResume)` while the driver pump concurrently `borrowMut`s
// the same cell in `drainMailbox`. The cell's reader/writer lock mediates
// those concurrent borrows. This test reproduces the exact escape +
// concurrent-borrow pattern; built with `KLIO_RACE_JITTER` it widens the
// window so any borrow-ordering regression aborts here deterministically.
// -------------------------------------------------------------------------

const WakeupRaceCtx = struct {
    /// First slot id this round owns; workers route through these.
    base_slot: i64,
    n_slots: i64,
    stop: *std.atomic.Value(bool),
};

fn wakeupRaceDriver(ctx: WakeupRaceCtx) void {
    // The driver pump: spin draining whatever slot owners are live,
    // exactly like `drainWakeupInto` does each idle round.
    const a = std.heap.page_allocator;
    while (!ctx.stop.load(.acquire)) {
        var s: i64 = ctx.base_slot;
        while (s < ctx.base_slot + ctx.n_slots) : (s += 1) {
            if (lookupSlotOwner(s)) |w| {
                var ww = w;
                const g = ww.borrowMut();
                const drained = g.get().drainMailbox(a) catch &.{};
                a.free(drained);
                g.deinit();
                ww.deinit();
            }
        }
    }
}

fn wakeupRaceWorker(ctx: WakeupRaceCtx) void {
    // The dispatcher worker: route a completion resume back through the
    // owning driver's mailbox, exactly like `coroutineResumeExternal`'s
    // cross-thread branch.
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        var s: i64 = ctx.base_slot;
        while (s < ctx.base_slot + ctx.n_slots) : (s += 1) {
            if (lookupSlotOwner(s)) |w| {
                var ww = w;
                const g = ww.borrowMut();
                _ = g.get().postResume(s, .Unit) catch false;
                g.deinit();
                ww.deinit();
            }
        }
    }
}

test "DriverWakeup survives concurrent cross-thread borrows" {
    const a = std.heap.page_allocator;
    // A fresh interceptor mints a `DriverWakeup`; registering a span of
    // slots below escapes the cell into the global registry.
    var ci = try CooperativeInterceptor.new(a);
    defer ci.deinit();

    const base: i64 = (1 << 40) + @as(i64, @intCast(std.Thread.getCurrentId() & 0xffff)) * 64;
    const n: i64 = 8;
    var s: i64 = base;
    // Registering each slot escapes the wakeup cell into the global
    // registry, the real escape seam.
    while (s < base + n) : (s += 1) try ci.setPendingSlot(s);

    var stop = std.atomic.Value(bool).init(false);
    const ctx = WakeupRaceCtx{ .base_slot = base, .n_slots = n, .stop = &stop };

    const driver = try std.Thread.spawn(.{}, wakeupRaceDriver, .{ctx});
    var workers: [4]std.Thread = undefined;
    for (&workers) |*wt| wt.* = try std.Thread.spawn(.{}, wakeupRaceWorker, .{ctx});
    for (&workers) |wt| wt.join();
    stop.store(true, .release);
    driver.join();

    // Drop the registry entries this round owns so the global map does not
    // leak across the suite.
    {
        const w = ci.wakeup.borrowMut();
        defer w.deinit();
        w.get().releaseOwnedSlots();
    }
}
