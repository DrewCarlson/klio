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
/// origin and elapsed-since-origin reading (the Rust
/// `std::time::Instant`).
fn monotonicNanos() i128 {
    return runtime.clockMonotonicNanos();
}

/// Block the calling thread for `millis` milliseconds.
fn sleepMillis(millis: u64) void {
    runtime.clockSleepMillis(@intCast(@min(millis, @as(u64, std.math.maxInt(i64)))));
}


/// Cross-thread wakeup primitive shared between a `runBlocking` driver
/// and any worker threads it has dispatched via `__kxco_dispatch`
/// (real-thread `Dispatchers.Default`). Workers post resume entries
/// into the mailbox and notify; the driver drains the mailbox and parks
/// on the condition when there is no local progress and at least one
/// worker is still outstanding.
///
/// Shared by `ObjRef` handle (atomic strong count) so it is safe to
/// hold from a worker thread while the driver also holds it; this is
/// the Rust `Arc<DriverWakeup>`.
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

    fn allocator() Allocator {
        return std.heap.page_allocator;
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

    /// The minimum floor across every registered pump *other* than `id`.
    /// `null` when no other pump has a finite floor: the caller is free to
    /// advance to its own timer.
    fn minOtherFloor(id: u64) ?i64 {
        mutex.lock();
        defer mutex.unlock();
        var m: ?i64 = null;
        for (slots.items) |s| {
            if (s.id == id) continue;
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

    /// Clear every registered pump at a run boundary. Pumps unregister
    /// themselves at `deinit`, so this is normally a no-op; it drops
    /// anything an error path left behind so a stale floor cannot hold the
    /// next run's pumps back.
    fn drainAll() void {
        mutex.lock();
        defer mutex.unlock();
        slots.clearAndFree(allocator());
    }
};

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
    /// Set by `__kxco_parkSlot` immediately before the activation
    /// unwinds with an indefinite suspend; consumed by the next
    /// `interceptSuspend` to bind that token to the slot.
    pending_slot: ?i64,
    /// slot id → token of the activation parked on that slot.
    slot_to_token: std.AutoHashMap(i64, u64),
    /// token → value the activation should observe as the result of its
    /// suspending call when resumed. Absent ⇒ resume with `Unit`.
    token_resume_value: std.AutoHashMap(u64, Value),
    allocator: Allocator,

    /// Fresh interceptor honoring this thread's time mode.
    pub fn new(allocator: Allocator) Allocator.Error!CooperativeInterceptor {
        return .{
            .wakeup = try DriverWakeup.new(allocator),
            .mode = root.coroutineTimeMode(),
            .started = null,
            .next_token = 0,
            .virtual_now = 0,
            // Join the barrier lazily (on the first finite-floor publish),
            // so timer-free pumps never touch the global lock.
            .clock_id = VirtualClock.UNREGISTERED,
            .published_floor = INDEFINITE,
            .parked = std.AutoHashMap(u64, ParkedEntry).init(allocator),
            .ready = .empty,
            .launched = .empty,
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
        try self.launched.append(self.allocator, block);
    }

    /// Seam: next ready token, if any.
    pub fn nextReady(self: *CooperativeInterceptor) ?u64 {
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    /// Seam: take the parked activation for a token.
    pub fn takeParked(self: *CooperativeInterceptor, token: u64) ?ParkedEntry {
        if (self.parked.fetchRemove(token)) |kv| return kv.value;
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
    };

    /// Publish `floor` to the global barrier only when it differs from the
    /// last value this pump wrote. Idle pumps overwhelmingly republish the
    /// same floor every round; skipping the no-op write keeps tens of
    /// concurrent pumps off the single barrier lock. A pump joins the
    /// barrier lazily, on its first *finite* floor: while it has no virtual
    /// timer it stays unregistered (implicitly `INDEFINITE`), so a heavy
    /// fan-out of timer-free tasks never touches the global lock.
    fn publishFloor(self: *CooperativeInterceptor, floor: i64) void {
        if (self.published_floor == floor) return;
        self.published_floor = floor;
        if (self.clock_id == VirtualClock.UNREGISTERED) {
            if (floor == INDEFINITE) return; // implicitly indefinite already
            self.clock_id = VirtualClock.registerWith(floor);
            return;
        }
        VirtualClock.publish(self.clock_id, floor);
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
                    self.virtual_now = t;
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
                    // observing run-boundary abandonment. Returning
                    // `true` reports the pending timer as progress; the
                    // pump comes back next round.
                    sleepMillis(@min(@as(u64, @intCast(wait)), 1));
                    if (self.nowMillis() < t) return .fired;
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
// The Rust crate keeps this loop in `vm/intrinsic_host.rs` with the
// `CooperativeInterceptor` stack, active-scope stack, and persisted-park
// table living in `lib.rs`'s thread-locals. The Zig port co-locates the
// whole driver with its machinery here.
// -------------------------------------------------------------------------

const vmhost = @import("vmhost.zig");
const intrinsic_host = @import("intrinsic_host.zig");
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const Output = runtime.Output;
const RuntimeError = runtime.RuntimeError;
const RuntimeEvalResult = runtime.EvalResult;
const EvalError = ir.eval.EvalError;

/// This thread's coroutine interceptor stack — one entry per nested
/// `runBlocking` / driven root (`with_coro` over the Rust `EXEC.coro`).
/// Backed by the page allocator: the stack itself is thread-lifetime and
/// holds at most a handful of entries; each interceptor's own maps use
/// the run allocator passed to `CooperativeInterceptor.new`.
threadlocal var coro_stack: std.ArrayList(CooperativeInterceptor) = .empty;

/// Stack of the active coroutine's `CoroutineScope` value (the driven
/// root scope). The suspend-implicit `coroutineContext` read redirects to
/// the active scope's context via this stack (the Rust
/// `ACTIVE_CORO_SCOPE`). Page-allocator backed for the same reason.
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

/// The active coroutine scope (top of the driver stack), if any. Mirrors
/// the Rust `active_coro_scope`. Public so the field-read path
/// (`coroutineContext` redirect) can consult the real stack.
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
fn captureScopeDelta(base: usize) []Value {
    const n = active_scope_stack.items.len;
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
    for (delta) |s| active_scope_stack.append(coroStackAllocator(), s) catch {};
}

/// RAII-style scope guard: pushes the driven coroutine's scope for the
/// lifetime of a `driveRoot` activation so the `coroutineContext`
/// intrinsic resolves to it. Only `Instance` scopes are pushed, matching
/// the Rust `ActiveScopeGuard::enter`.
const ActiveScopeGuard = struct {
    pushed: bool,

    fn enter(scope: *const Value) ActiveScopeGuard {
        if (scope.* == .Instance) {
            active_scope_stack.append(coroStackAllocator(), scope.*) catch return .{ .pushed = false };
            return .{ .pushed = true };
        }
        return .{ .pushed = false };
    }

    fn leave(self: ActiveScopeGuard) void {
        if (self.pushed and active_scope_stack.items.len != 0) {
            _ = active_scope_stack.pop();
        }
    }
};

/// Map an `EvalError` onto the runtime's `RuntimeError`, mirroring the
/// Rust `map_err` closure in `drive_root` (`Throw -> Thrown`,
/// `NonLocalReturn -> Return`, every other variant rendered as `Type`).
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

/// Hand a freshly-suspended Layer-1 activation to the active interceptor
/// (Layer 2). Returns the token so the driver can recognise the root's
/// completion. The `*SuspendState` box is consumed: its value is copied
/// into the interceptor and the box freed (the inner `frames` ArrayList /
/// dup'd slices are now owned by the copied value).
fn park(allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!u64 {
    const top = coroTop() orelse return error.OutOfMemory; // "park outside runBlocking"
    const value = st.*;
    allocator.destroy(st);
    const delta = captureScopeDelta(scope_base);
    return top.interceptSuspend(value, delta);
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
    // An undispatched block's scope push (`coroutinePushScope`) pops when
    // its activation completes; an activation abandoned with this pump
    // never completes, so the pump truncates the stack back to its entry
    // depth on every exit path.
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    const guard = ActiveScopeGuard.enter(scope);
    defer guard.leave();

    // Root coroutine.
    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    const root_scope_base = activeScopeDepth();
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

    if (try pumpLoop(self, scope, out, persist, &root_token, &root_value)) |err_result| {
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
    if (try pumpLoop(self, &unit, out, false, &root_token, &root_value)) |err_result| {
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
pub fn driveResumed(self: *VmIntrinsicHost, state_in: SuspendState, value: Value, scope_delta: []const Value, out: Output) Allocator.Error!void {
    const a = self.allocator;
    try coroPush(a);
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
    if (try pumpLoop(self, &scope, out, true, &root_token, &root_value)) |_| {
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
    root_token: *?u64,
    root_value: *?Value,
) Allocator.Error!?RuntimeEvalResult {
    const a = self.allocator;
    var idle_rounds: usize = 0;
    while (true) {
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
        if (!persist and root_token.* == null) break;

        // 1. Start any queued child launches. A started launch may
        //    enqueue more (a `delay` schedules its timer through a
        //    spawned block), so a round that started anything loops back
        //    to drain again BEFORE the clock may advance: a timer must
        //    be parked, with its deadline measured from the current
        //    time, before `advanceTime` picks the next wakeup.
        const launched = try (coroTop().?).drainLaunched(a);
        defer a.free(launched);
        for (launched) |child| {
            const child_scope_base = activeScopeDepth();
            const child_res = try intrinsic_host.evalClosureRaw(self, &child, &.{}, scope, out);
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
            idle_rounds = 0;
            continue;
        }

        // 2. Resume a ready coroutine, if any.
        if ((coroTop().?).nextReady()) |tok| {
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
            std.Thread.yield() catch sleepMillis(1);
            continue;
        }

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
            if (idle_rounds == 3000) diagStalledPump(coroTop().?, root_token.*);
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
fn diagStalledPump(top: *CooperativeInterceptor, root_tok: ?u64) void {
    if (!pumpDiagEnabled()) return;
    std.debug.print("[PUMP] stalled root_tok={?d} parked={d} ready={d} launched={d}\n", .{
        root_tok, top.parked.count(), top.ready.items.len, top.launched.items.len,
    });
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
        _ = try top.resumeSlotValue(entry.slot, entry.value);
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
    active_scope_stack.append(coroStackAllocator(), scope.*) catch {};
}

pub fn coroutinePopScope() void {
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
                try driveResumed(self, pe.state, value, pe.scope_delta, out);
                coroStackAllocator().free(pe.scope_delta);
            }
            // No persisted state either: the waiter was abandoned with
            // its driver (a runBlocking exit) — nowhere to land.
            return;
        }
        // The coroutine parked inside a driven root that already
        // returned; its state was persisted. Claim it (single winner)
        // and drive it to quiescence on this thread under a fresh pump —
        // the cross-pump resume that lets a coroutine continue on a
        // different OS thread.
        if (PersistedParked.take(slot)) |pe| {
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
            if ((coroTop().?).takeParked(tok)) |entry_in| {
                var entry = entry_in;
                const resume_with = (coroTop().?).takeResumeValue(tok) orelse Value.Unit;
                const scope_base = activeScopeDepth();
                restoreScopeDelta(entry.scope_delta);
                coroStackAllocator().free(entry.scope_delta);
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
        if (try (coroTop().?).advanceTime()) continue;
        break;
    }
    return null;
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
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
