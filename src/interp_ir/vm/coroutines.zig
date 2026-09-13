//! Coroutine scheduling: the cross-thread `DriverWakeup` mailbox and the
//! `CooperativeInterceptor`'s park / resume / ready-queue / virtual-time
//! machinery. The suspend engine (`ir.eval`) only pauses an activation into a
//! `SuspendState` and resumes one; when parked activations resume is decided here.

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

/// Indefinite park: resumed only by an explicit ready entry, never a timer.
const INDEFINITE: i64 = std.math.maxInt(i64);

fn monotonicNanos() i128 {
    return runtime.clockMonotonicNanos();
}

/// Event-wait one idle slice on the pump's gate, capped at `cap_us`. The epoch is
/// read before the emptiness check, so a post between the two returns at once.
fn gateWaitBrief(wakeup: *const ObjRef(DriverWakeup), cap_us: u64) void {
    const w = wakeup.borrowMut();
    const gp = &w.get().gate;
    const seen = gp.epochNow();
    const nonempty = w.get().mailboxNonEmpty();
    w.deinit();
    if (!nonempty) gp.waitFrom(seen, cap_us);
}

fn sleepMillis(millis: u64) void {
    runtime.clockSleepMillis(@intCast(@min(millis, @as(u64, std.math.maxInt(i64)))));
}

var pump_nosleep_state: u8 = 0;
fn pumpNoSleep() bool {
    if (pump_nosleep_state == 0)
        pump_nosleep_state = if (runtime.envOnce("KLIO_PUMP_NOSLEEP") != null) 2 else 1;
    return pump_nosleep_state == 2;
}

pub const SleepSite = enum { timer_wall, wakeup_pending, barrier_yield, root_parked };
var sleep_counts = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** 4;
fn countSleep(site: SleepSite) void {
    _ = sleep_counts[@intFromEnum(site)].fetchAdd(1, .monotonic);
}

var wall_streak: u64 = 0;
var streak_diag: ?bool = null;
fn streakDiagOn() bool {
    if (streak_diag == null) streak_diag = runtime.envOnce("KLIO_PUMP_DIAG") != null;
    return streak_diag.?;
}
fn endStreak(source: []const u8) void {
    if (wall_streak >= 50 and streakDiagOn())
        std.debug.print("[pump-streak] {d} idle rounds ended by {s}\n", .{ wall_streak, source });
    wall_streak = 0;
}
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

/// Cross-thread wakeup shared between a `runBlocking` driver and the workers it
/// dispatched: workers post resume entries and ring the gate, the driver drains and
/// parks on it. Held by `ObjRef`, so a worker may hold it while the driver does.
pub const DriverWakeup = struct {
    mailbox: SpinMutex = .{},
    mailbox_entries: std.ArrayList(MailboxEntry) = .empty,
    /// Drive-loop iteration count. A cross-thread resume waits (bounded) for two
    /// turns after its post, so the posted step runs before the resumer proceeds.
    turns: std.atomic.Value(u64) = .init(0),
    /// Set under the mailbox lock by the exit protocol. A closed mailbox rejects
    /// posts, so a racing resumer falls through to the persisted registry the driver
    /// populated strictly before closing.
    mailbox_closed: bool = false,
    gate: runtime.EventGate = .{},
    pending_workers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    owned_slots: SpinMutex = .{},
    owned_slot_set: std.ArrayList(i64) = .empty,
    allocator: Allocator,

    pub const MailboxEntry = struct {
        slot: i64,
        value: Value,
    };

    pub fn new(allocator: Allocator) Allocator.Error!ObjRef(DriverWakeup) {
        return ObjRef(DriverWakeup).init(allocator, .{ .allocator = allocator });
    }

    pub fn deinit(self: *DriverWakeup) void {
        self.mailbox_entries.deinit(self.allocator);
        self.owned_slot_set.deinit(self.allocator);
    }

    pub fn gcTrace(self: *const DriverWakeup, m: *runtime.gc.Marker) void {
        for (self.mailbox_entries.items) |e| e.value.gcMark(m);
    }

    /// Shallow: the spines only, since entry Values are independent cells.
    pub fn gcFinalize(self: *DriverWakeup, gc_alloc: std.mem.Allocator) void {
        _ = gc_alloc;
        self.mailbox_entries.deinit(self.allocator);
        self.owned_slot_set.deinit(self.allocator);
    }

    /// False means the mailbox is closed and the caller must route through the
    /// persisted registry.
    pub fn postResume(self: *DriverWakeup, slot: i64, value: Value) Allocator.Error!bool {
        {
            self.mailbox.lock();
            defer self.mailbox.unlock();
            if (self.mailbox_closed) return false;
            try self.mailbox_entries.append(self.allocator, .{ .slot = slot, .value = value });
        }
        self.gate.ring();
        return true;
    }

    pub fn mailboxNonEmpty(self: *DriverWakeup) bool {
        self.mailbox.lock();
        defer self.mailbox.unlock();
        return self.mailbox_entries.items.len != 0;
    }

    pub fn drainMailbox(self: *DriverWakeup, allocator: Allocator) Allocator.Error![]MailboxEntry {
        self.mailbox.lock();
        defer self.mailbox.unlock();
        const out = try self.mailbox_entries.toOwnedSlice(allocator);
        self.mailbox_entries = .empty;
        return out;
    }

    /// The exit protocol persists parked continuations before closing, so every
    /// later resume routes to the registry.
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

/// Process-global slot to owning `DriverWakeup`: a worker routes its completion
/// resume through the driver owning the slot it parked on. Its clones reach into
/// the per-run value graph, so `drainAll` sweeps at the run boundary.
const SlotOwners = struct {
    var mutex: SpinMutex = .{};
    var map: ?std.AutoHashMap(i64, ObjRef(DriverWakeup)) = null;
    /// Resumes that arrived before their slot had an owner. A waiter publishes
    /// itself to a rendezvous registry before arming its slot; a resume in that gap
    /// parks here and `registerSlotOwner` re-checks under the same mutex, so exactly
    /// one side always sees the other.
    var pending: ?std.AutoHashMap(i64, Value) = null;

    fn allocator() Allocator {
        return std.heap.page_allocator;
    }

    fn ensure() Allocator.Error!*std.AutoHashMap(i64, ObjRef(DriverWakeup)) {
        if (map == null) {
            map = std.AutoHashMap(i64, ObjRef(DriverWakeup)).init(allocator());
        }
        return &map.?;
    }

    /// The owner check and the stash are one atomic section against
    /// `registerSlotOwner`; false means the caller must retry the owner route.
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

    /// At the run boundary, once all workers have joined, so a slot left
    /// registered by an error path cannot survive into the next run's reset arena.
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

/// From `joinAllThreads` once every worker has joined, never from
/// `resetReceiverTls`, which also runs on workers and must not tear down a live
/// driver's registry.
pub fn drainSlotOwners() void {
    SlotOwners.drainAll();
}

/// Process-global slot to persisted `SuspendState`. A coroutine that parks
/// indefinitely outlives its driver, so a later resume from any thread claims it
/// (single winner via `fetchRemove` under the mutex) and drives it there: that is
/// how a coroutine hops OS threads. Swept at the run boundary like `SlotOwners`.
const PersistedParked = struct {
    /// Frames plus the page-allocator-owned scope delta re-established when
    /// whatever pump claims the slot resumes it.
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

/// A state left behind belongs to a coroutine whose resume never came; its frames
/// are arena-backed.
pub fn drainPersistedParked() void {
    PersistedParked.drainAll();
}

/// Process-global barrier over the per-pump logical clocks under
/// `TimeMode.Virtual`. A pump may jump to a future timer at `t` only once no other
/// live virtual pump is parked on an earlier timer that could post a resume
/// effective before `t`; otherwise a child's clock races ahead and fires its
/// `delay` before the parent reaches the `cancel` that preempts it. A pump
/// publishes a floor only while it holds a future timer, and a timer already due
/// (`yield`) skips the barrier as ready-now work.
const VirtualClock = struct {
    const Slot = struct {
        id: u64,
        /// Earliest virtual time this pump may act at; `INDEFINITE` when only an
        /// external event can resume it.
        floor: i64,
    };

    /// A pump with no finite floor yet, so not in `slots` and never holding the
    /// clock back.
    const UNREGISTERED: u64 = 0;

    var mutex: SpinMutex = .{};
    var slots: std.ArrayList(Slot) = .empty;
    var next_id: u64 = 1;
    /// The shared logical clock every virtual pump measures `delay` deadlines
    /// from; a pump resuming on a fresh interceptor seeds `virtual_now` from it.
    var now: i64 = 0;
    /// Dispatched pool tasks started with no barrier floor yet: nothing orders them,
    /// so a top-level driver must not advance virtual time while any is in flight.
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

    fn currentNow() i64 {
        mutex.lock();
        defer mutex.unlock();
        return now;
    }

    fn advanceNow(t: i64) void {
        mutex.lock();
        defer mutex.unlock();
        if (t > now) now = t;
    }

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

    /// Same-thread pumps are strictly nested: a lower one is a frozen ancestor that
    /// cannot post a cross-pump resume, so holding the barrier against the pump
    /// above it would deadlock both.
    fn onCurrentThreadStack(clock_id: u64) bool {
        if (clock_id == UNREGISTERED) return false;
        for (coro_stack.items) |*p| {
            if (p.clock_id == clock_id) return true;
        }
        return false;
    }

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

    /// A pump idle with its soonest timer at `t` may fire it only if no other live
    /// pump has a floor below `t`, since that pump runs first and may preempt it.
    fn mayFire(id: u64, t: i64) bool {
        const other = minOtherFloor(id) orelse return true;
        return other >= t;
    }

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

    fn drainAll() void {
        mutex.lock();
        defer mutex.unlock();
        slots.clearAndFree(allocator());
        now = 0;
        pool_unsettled = 0;
    }
};

/// Whether this thread's pool task still counts as unsettled; the first
/// `publishFloor` or `poolTaskRunEnd` settles the global count, once per task.
threadlocal var pool_task_unsettled: bool = false;

/// The runtime wall-block hook: a task entering a real `Thread.sleep` releases
/// its virtual-clock claim for the length of the sleep.
fn wallBlockSettle() void {
    if (pool_task_unsettled) {
        pool_task_unsettled = false;
        VirtualClock.settle();
    }
}

var wall_hook_installed = std.atomic.Value(bool).init(false);

/// A top-level driver must not advance virtual time across the window between
/// dispatch and the task establishing its barrier floor. Paired with
/// `poolTaskSettleDropped` or the task's first `publishFloor`.
pub fn poolTaskDispatched() void {
    if (root.coroutineTimeMode() != .Virtual) return;
    if (!wall_hook_installed.swap(true, .monotonic)) {
        runtime.setWallBlockHook(wallBlockSettle);
    }
    VirtualClock.enterUnsettled();
}

pub fn poolTaskSettleDropped() void {
    if (root.coroutineTimeMode() != .Virtual) return;
    VirtualClock.settle();
}

pub fn poolTaskRunBegin() void {
    pool_task_unsettled = root.coroutineTimeMode() == .Virtual;
}

pub fn poolTaskRunEnd() void {
    if (pool_task_unsettled) {
        pool_task_unsettled = false;
        VirtualClock.settle();
    }
}

pub fn drainVirtualClock() void {
    VirtualClock.drainAll();
}

pub fn registerSlotOwner(slot: i64, wakeup: *const ObjRef(DriverWakeup)) Allocator.Error!void {
    // The insert publishes this cell to worker threads, which `borrowMut` it to post
    // resumes concurrently with this driver's pump under the cell's reader/writer
    // lock; the slot is recorded before the insert makes it findable.
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
        // A resume may already have parked in the pending stash. Claim it under
        // the same lock that just made the owner visible, so the two cannot cross.
        if (SlotOwners.pending) |*p| {
            if (p.fetchRemove(slot)) |kv| break :blk kv.value;
        }
        break :blk null;
    };
    if (pending_resume) |v| {
        // Through the mailbox: the pump drains it after the activation has parked.
        const w = wakeup.borrowMut();
        defer w.deinit();
        _ = try w.get().postResume(slot, v);
    }
}

/// The handle is an owned clone the caller must `deinit`.
pub fn lookupSlotOwner(slot: i64) ?ObjRef(DriverWakeup) {
    SlotOwners.mutex.lock();
    defer SlotOwners.mutex.unlock();
    if (SlotOwners.map) |*m| {
        if (m.get(slot)) |w| return w.clone();
    }
    return null;
}

pub fn unregisterSlot(slot: i64) void {
    SlotOwners.mutex.lock();
    defer SlotOwners.mutex.unlock();
    if (SlotOwners.map) |*m| {
        if (m.fetchRemove(slot)) |kv| {
            kv.value.deinit();
        }
    }
}

/// One per nested `runBlocking` / `coroutineScope`.
pub const CooperativeInterceptor = struct {
    /// An `INDEFINITE` `wake_at` resumes only on an explicit ready entry.
    pub const ParkedEntry = struct {
        state: SuspendState,
        wake_at: i64,
        /// The active-scope pushes this activation owns, captured at park and
        /// restored at resume so a `coroutineContext` read sees this coroutine's
        /// scope, not the resuming pump's. Page-allocator owned.
        scope_delta: []Value = &.{},
    };

    /// Shared with dispatched workers and with `SLOT_OWNERS` entries for its slots.
    wakeup: ObjRef(DriverWakeup),
    mode: TimeMode,
    /// Wall-clock origin `delay` deadlines measure from, read lazily.
    started: ?i128,
    next_token: u64,
    virtual_now: i64,
    /// This pump's `VirtualClock` id, `UNREGISTERED` until it publishes a finite
    /// floor.
    clock_id: u64,
    /// Floor last written to the global clock; republished only on change, since
    /// taking the global lock once per round serialises tens of pumps.
    published_floor: i64,
    parked: std.AutoHashMap(u64, ParkedEntry),
    /// FIFO of tokens whose wakeup is due (timer fired or yielded).
    ready: std.ArrayList(u64),
    launched: std.ArrayList(Value),
    /// `withTimeout` gates scheduled while this pump's body ran. A gate cancels the
    /// timed block, so it must share that block's timer queue, but the block runs as
    /// its own nested pump; `coroutineStartRootOrSuspended` commits pending gates
    /// onto the child pump so the earlier deadline fires first.
    timeout_launched: std.ArrayList(Value),
    /// The virtual instant last observed and the real time this pump first saw it.
    starve_seen_now: i64 = -1,
    starve_base_real: i64 = 0,
    /// Set by `__kxco_parkSlot` just before the activation unwinds; consumed by the
    /// next `interceptSuspend`, binding that token to the slot.
    pending_slot: ?i64,
    slot_to_token: std.AutoHashMap(i64, u64),
    /// Absent means resume with `Unit`.
    token_resume_value: std.AutoHashMap(u64, Value),
    /// This pump's root while parked; an inline resume never steals it.
    root_tok: ?u64 = null,
    /// Set once a native channel delivery routed through an external dispatcher's
    /// queue: such a pump orders its dispatched resumes there, not on `drv.ready`.
    scheduler_backed: bool = false,
    /// A failure from an activation that ran inline, outside the drive loop. The
    /// loop cannot see it there, so it is raised on the next turn.
    pending_err: ?EvalError = null,
    allocator: Allocator,

    /// Under `Virtual`, seeds `virtual_now` from the shared clock so a coroutine
    /// resuming on a fresh pump keeps the virtual time already elapsed.
    pub fn new(allocator: Allocator) Allocator.Error!CooperativeInterceptor {
        const mode = root.coroutineTimeMode();
        return .{
            .wakeup = try DriverWakeup.new(allocator),
            .mode = mode,
            .started = null,
            .next_token = 0,
            .virtual_now = if (mode == .Virtual) VirtualClock.currentNow() else 0,
            .clock_id = VirtualClock.UNREGISTERED,
            .published_floor = INDEFINITE,
            .parked = std.AutoHashMap(u64, ParkedEntry).init(allocator),
            .ready = .empty,
            .launched = .empty,
            .timeout_launched = .empty,
            .starve_seen_now = -1,
            .starve_base_real = 0,
            .pending_slot = null,
            .slot_to_token = std.AutoHashMap(i64, u64).init(allocator),
            .token_resume_value = std.AutoHashMap(u64, Value).init(allocator),
            .allocator = allocator,
        };
    }

    /// GC: the wakeup mailbox, each parked activation's frames and scope delta, the
    /// queued blocks, and undelivered resume values.
    pub fn gcMark(self: *CooperativeInterceptor, m: *runtime.gc.Marker) void {
        m.shade(&self.wakeup.cell.hdr);
        var pit = self.parked.valueIterator();
        while (pit.next()) |e| {
            // Quiescent skip on minor marks: a fully-traced parked entry is frozen.
            if (m.minor and e.state.gc_quiesced) continue;
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
        // Free the page-allocator scope deltas of still-parked activations first.
        {
            var it = self.parked.valueIterator();
            while (it.next()) |e| {
                if (e.scope_delta.len != 0) coroStackAllocator().free(e.scope_delta);
            }
        }
        self.parked.deinit();
        self.ready.deinit(self.allocator);
        if (runtime.reclaimEnabled()) for (self.launched.items) |b| b.release(self.allocator);
        self.launched.deinit(self.allocator);
        if (runtime.reclaimEnabled()) for (self.timeout_launched.items) |b| b.release(self.allocator);
        self.timeout_launched.deinit(self.allocator);
        self.slot_to_token.deinit();
        self.token_resume_value.deinit();
    }

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

    /// Seam: assign a token and decode the resume directive in `wake_in_millis`
    /// (negative parks indefinitely, `0` is ready now, positive wakes that many
    /// millis later on the active clock).
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
        // Bind an armed slot to any parked activation, not only indefinite parks: a
        // block suspended on a timed `delay` must stay reachable through the slot so
        // a cancellation can resume it early.
        if (self.pending_slot) |slot| {
            self.pending_slot = null;
            try self.slot_to_token.put(slot, token);
        }
        try self.parked.put(token, .{ .state = state, .wake_at = wake_at, .scope_delta = scope_delta });
        return token;
    }

    /// Adopt a persisted parked activation into this pump, ready to run with
    /// `value`. Nesting a fresh drive inside the current activation instead would
    /// stack a whole native driver per unwind hop. Takes ownership of `scope_delta`.
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

    /// Seam: record the slot the next indefinitely-parked activation waits on and
    /// register it, so a worker can route its completion resume to this mailbox.
    pub fn setPendingSlot(self: *CooperativeInterceptor, slot: i64) Allocator.Error!void {
        self.pending_slot = slot;
        try registerSlotOwner(slot, &self.wakeup);
    }

    pub fn clearPendingSlot(self: *CooperativeInterceptor) void {
        self.pending_slot = null;
    }

    pub fn resumeSlot(self: *CooperativeInterceptor, slot: i64) Allocator.Error!bool {
        if (self.slot_to_token.fetchRemove(slot)) |kv| {
            unregisterSlot(slot);
            try self.ready.append(self.allocator, kv.value);
            return true;
        }
        return false;
    }

    pub fn resumeSlotValue(self: *CooperativeInterceptor, slot: i64, value: Value) Allocator.Error!bool {
        if (self.slot_to_token.fetchRemove(slot)) |kv| {
            unregisterSlot(slot);
            try self.token_resume_value.put(kv.value, value);
            try self.ready.append(self.allocator, kv.value);
            return true;
        }
        return false;
    }

    /// Claim the activation parked on `slot` for an inline resume, unbinding the slot
    /// without queueing. Null when this pump does not hold the slot, the token is not
    /// parked, or it is this pump's own root.
    pub fn claimSlotForInline(self: *CooperativeInterceptor, slot: i64) ?ParkedEntry {
        const tok = self.slot_to_token.get(slot) orelse return null;
        if (self.root_tok != null and self.root_tok.? == tok) return null;
        const entry = self.parked.fetchRemove(tok) orelse return null;
        _ = self.slot_to_token.remove(slot);
        unregisterSlot(slot);
        return entry.value;
    }

    pub fn takeResumeValue(self: *CooperativeInterceptor, token: u64) ?Value {
        if (self.token_resume_value.fetchRemove(token)) |kv| return kv.value;
        return null;
    }

    /// Remove every indefinitely-parked activation waiting on a slot, which the
    /// `startCoroutine` driver hands to program-lifetime storage so a coroutine
    /// survives its driver's return. Slice owned by `allocator`.
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

    /// Seam: this round's queued child `launch` blocks, owned by `allocator`.
    pub fn drainLaunched(self: *CooperativeInterceptor, allocator: Allocator) Allocator.Error![]Value {
        const out = try self.launched.toOwnedSlice(allocator);
        self.launched = .empty;
        return out;
    }

    /// The queue owns one reference until `drainLaunched`'s caller releases it.
    pub fn enqueueLaunch(self: *CooperativeInterceptor, block: Value) Allocator.Error!void {
        if (runtime.reclaimEnabled()) block.retain();
        if (pumpDiagEnabled()) std.debug.print("[tok] enqueueLaunch n={d}\n", .{self.launched.items.len + 1});
        try self.launched.append(self.allocator, block);
    }

    /// The queue owns one reference until the block is claimed and re-homed.
    pub fn enqueueTimeout(self: *CooperativeInterceptor, block: Value) Allocator.Error!void {
        if (runtime.reclaimEnabled()) block.retain();
        try self.timeout_launched.append(self.allocator, block);
    }

    /// Owned by `allocator`; each block carries the enqueue's reference, which the
    /// caller either re-homes or releases.
    pub fn drainTimeouts(self: *CooperativeInterceptor, allocator: Allocator) Allocator.Error![]Value {
        const out = try self.timeout_launched.toOwnedSlice(allocator);
        self.timeout_launched = .empty;
        return out;
    }

    /// Gates no nested pump claimed run here as plain timers. Keeps each block's
    /// enqueue reference.
    pub fn promoteTimeouts(self: *CooperativeInterceptor) Allocator.Error!void {
        if (self.timeout_launched.items.len == 0) return;
        for (self.timeout_launched.items) |b| try self.launched.append(self.allocator, b);
        self.timeout_launched.clearRetainingCapacity();
    }

    pub fn nextReady(self: *CooperativeInterceptor) ?u64 {
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    pub fn takeParked(self: *CooperativeInterceptor, token: u64) ?ParkedEntry {
        if (self.parked.fetchRemove(token)) |kv| {
            if (pumpDiagEnabled()) std.debug.print("[tok] take tok={d}\n", .{token});
            return kv.value;
        }
        if (pumpDiagEnabled()) std.debug.print("[tok] take tok={d} MISSING\n", .{token});
        return null;
    }

    pub const Advance = enum {
        fired,
        none,
        /// A timer exists but the barrier holds it: another live pump has earlier
        /// work that may post a cross-pump resume. Drain the mailbox and retry.
        blocked,
        /// A Wall timer is pending but not due; one sleep slice was taken. Drain
        /// the mailbox before retrying or a resume posted here waits out the timer.
        waiting,
    };

    /// Publish only on change: idle pumps otherwise republish the same floor every
    /// round and serialise on the barrier lock. A pump joins on its first finite one.
    fn publishFloor(self: *CooperativeInterceptor, floor: i64) void {
        // A publish point means the body has parked, so a dispatched pool task is
        // no longer unsettled: its floor now orders it.
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

    /// While this pump has work to run at `now` it holds the barrier floor at the
    /// shared clock, so wakeups fire by ascending deadline across pumps.
    fn claimNow(self: *CooperativeInterceptor) void {
        if (self.mode != .Virtual) return;
        const shared = VirtualClock.currentNow();
        if (shared > self.virtual_now) self.virtual_now = shared;
        self.publishFloor(self.virtual_now);
    }

    /// Whether this pump sat at one virtual instant longer in real time than the
    /// earliest parked timer's delay: virtual time must never run slower than real.
    pub fn virtualStarvationDue(self: *CooperativeInterceptor) bool {
        if (self.mode != .Virtual) return false;
        var soonest: ?i64 = null;
        var it = self.parked.iterator();
        while (it.next()) |e| {
            const w = e.value_ptr.wake_at;
            if (w == INDEFINITE) continue;
            if (soonest == null or w < soonest.?) soonest = w;
        }
        const t = soonest orelse return false;
        const now_real = ir.eval.nowMonotonicMs();
        if (self.starve_seen_now != self.virtual_now) {
            self.starve_seen_now = self.virtual_now;
            self.starve_base_real = now_real;
            return false;
        }
        const delay = t - self.virtual_now;
        if (delay <= 0) return true;
        return now_real - self.starve_base_real >= delay;
    }

    /// Seam: advance the clock to the soonest timer and arm every activation due
    /// then. `Virtual` jumps once the barrier permits; `Wall` sleeps toward it.
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
            // No finite timer: an indefinite floor never holds another pump back.
            if (self.mode == .Virtual) self.publishFloor(INDEFINITE);
            return .none;
        };
        switch (self.mode) {
            .Virtual => {
                // Catch up to the shared clock first; a timer at or before it is
                // then ready-now work, fired without a clock jump.
                const shared = VirtualClock.currentNow();
                if (shared > self.virtual_now) self.virtual_now = shared;
                // A timer already due at the current instant is ready-now work, not a
                // clock advance: firing it without the barrier cannot deadlock against
                // another pump at the same instant, and its floor stays here.
                if (t > self.virtual_now) {
                    self.publishFloor(t);
                    if (!VirtualClock.mayFire(self.clock_id, t)) return .blocked;
                    // A top-level driver also waits while a dispatched pool task it
                    // launched has published no floor: that coroutine may park on a
                    // sooner timer, or cancel this driver's job, first. The floor `t`
                    // stands, so a sibling with a sooner timer still advances.
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
                    // Sleep in slices: the pump must keep draining its mailbox so a
                    // resume can preempt the timer, and keep observing abandonment.
                    countSleep(.timer_wall);
                    wall_streak += 1;
                    if (!pumpNoSleep()) {
                        // A cross-thread post rings the gate, so the pump reacts in
                        // microseconds; a short spin phase serves back-to-back handoffs.
                        if (wall_streak <= 64) {
                            std.atomic.spinLoopHint();
                        } else {
                            const gp: *runtime.EventGate = blk: {
                                const w = self.wakeup.borrowMut();
                                defer w.deinit();
                                break :blk &w.get().gate;
                            };
                            const seen = gp.epochNow();
                            const nonempty = blk: {
                                const w = self.wakeup.borrowMut();
                                defer w.deinit();
                                break :blk w.get().mailboxNonEmpty();
                            };
                            if (!nonempty) {
                                const cap_us: u64 = @min(@as(u64, @intCast(wait)) * 1_000, 2_000);
                                gp.waitFrom(seen, cap_us);
                            }
                        }
                    }
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
        // Deadline order, token order breaking ties, as an event loop would fire.
        std.mem.sort(Due, due.items, {}, Due.lessThan);
        for (due.items) |d| {
            try self.ready.append(self.allocator, d.tok);
        }
        return if (due.items.len != 0) .fired else .none;
    }

    /// Arm already-due Wall deadlines without an idle round, or a yield-livelocked
    /// pair starves `withTimeout`. Queued entries clear `wake_at` so a later round
    /// cannot re-queue them.
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

    /// `.blocked` reports no progress, so the caller keeps draining its mailbox.
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

// The default interceptor's dispatch loop, the engine behind `runBlocking`: it
// never inspects the suspend mechanism, only parks and resumes through the seam.

const vmhost = @import("vmhost.zig");
const intrinsic_host = @import("intrinsic_host.zig");
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const Output = runtime.Output;
const RuntimeError = runtime.RuntimeError;
const RuntimeEvalResult = runtime.EvalResult;
const EvalError = ir.eval.EvalError;

/// This thread's interceptor stack, one entry per nested driven root.
/// Page-allocator backed; each interceptor's maps use its own run allocator.
threadlocal var coro_stack: std.ArrayList(CooperativeInterceptor) = .empty;

/// The active coroutine scope stack the `coroutineContext` read redirects through.
threadlocal var active_scope_stack: std.ArrayList(Value) = .empty;

fn coroStackAllocator() Allocator {
    return runtime.slab.tracedPage();
}

/// Assert (Debug) both stacks are empty at a run boundary, so coroutine context
/// leaked across runs is loud. The persisted registry is swept separately.
pub fn resetReceiverTls() void {
    std.debug.assert(coro_stack.items.len == 0);
    std.debug.assert(active_scope_stack.items.len == 0);
    coro_stack.clearRetainingCapacity();
    active_scope_stack.clearRetainingCapacity();
}

fn coroTop() ?*CooperativeInterceptor {
    if (coro_stack.items.len == 0) return null;
    return &coro_stack.items[coro_stack.items.len - 1];
}

/// Process-global coroutine roots, registered once. The locks are never held
/// across a safe point, so taking them here cannot deadlock the collector.
fn gcMarkCoroGlobal(m: *runtime.gc.Marker) void {
    PersistedParked.mutex.lock();
    if (PersistedParked.map) |*pm| {
        var it = pm.valueIterator();
        while (it.next()) |e| {
            if (m.minor and e.state.gc_quiesced) continue;
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

pub fn gcUninstallCoroRoot() void {
    if (!coro_troot_inited) return;
    runtime.gc.unregisterThreadRoot(&coro_troot);
    coro_troot_inited = false;
}

/// Thread-entry GC seam: join the mutator set, so a collection on any thread stops
/// this one at its next safe point. A thread entering during the program phase
/// mints nursery cells, keeping worker-minted structures visible to minor marks.
pub fn gcThreadEnter() void {
    if (!runtime.gc.gc_enabled) return;
    // `KLIO_WORKER_PERM=1` makes workers mint permanent cells instead.
    if (runtime.gc.program_started and
        !std.mem.eql(u8, runtime.envOnce("KLIO_WORKER_PERM") orelse "0", "1"))
    {
        runtime.gc.alloc_perm = false;
    }
    runtime.gc.enterMutator();
}

/// Leave the mutator set and unlink every per-thread root before teardown.
pub fn gcThreadExit() void {
    if (!runtime.gc.gc_enabled) return;
    runtime.gc.flushExternalDelta();
    runtime.gc.exitMutator();
    ir.eval.gcUninstallFrameRoot();
    runtime.gcUninstallKeepaliveRoot();
    gcUninstallCoroRoot();
    @import("compose.zig").gcUninstallComposeRoot();
}

fn coroPush(allocator: Allocator) Allocator.Error!void {
    ensureCoroRoot();
    try coro_stack.append(coroStackAllocator(), try CooperativeInterceptor.new(allocator));
}

/// The returned `wakeup` handle is owned by the caller, so global slot-owner
/// entries pointing at it can be released.
fn coroPop() ?ObjRef(DriverWakeup) {
    if (coro_stack.items.len == 0) return null;
    var ci = coro_stack.pop().?;
    const wakeup = ci.wakeup.clone();
    ci.deinit();
    return wakeup;
}

pub fn activeCoroScope() ?Value {
    if (active_scope_stack.items.len == 0) return null;
    return active_scope_stack.items[active_scope_stack.items.len - 1];
}

/// Pushes above this base become the activation's scope delta when it parks.
fn activeScopeDepth() usize {
    return active_scope_stack.items.len;
}

fn scopeDiagOn() bool {
    return runtime.envOnce("KLIO_SCOPE_DIAG") != null;
}
fn scopeIdent(v: *const Value) usize {
    return if (v.* == .Instance) v.Instance.identity() else 0;
}
/// Capture and remove the pushes above `base`, the scope delta owned by the
/// activation about to park: a suspension unwinds through Zig without running the
/// Kotlin `finally` that would pop them. Caller owns the page-allocator slice.
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

/// Restore a parked activation's scope delta before it resumes; the body's
/// `__klio_co_popScope` balances these pushes at completion.
fn restoreScopeDelta(delta: []const Value) void {
    if (scopeDiagOn() and delta.len != 0) {
        std.debug.print("[scope] restore depth={d}:", .{active_scope_stack.items.len});
        for (delta) |*v| std.debug.print(" {x}", .{scopeIdent(v)});
        std.debug.print("\n", .{});
    }
    for (delta) |s| active_scope_stack.append(coroStackAllocator(), s) catch {};
}

/// Pushes the driven coroutine's scope for a `driveRoot` activation. `Instance`
/// scopes only.
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
        // Remove this guard's own entry by identity, never a blind top pop:
        // activations interleave, so popping the top leaks ours for a later
        // positional capture to adopt.
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

/// `Throw -> Thrown`, `NonLocalReturn -> Return`, every other variant as `Type`.
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

// Lazy `sequence { yield(...) }` / `iterator { ... }` builder driver.
//
// The block is a restricted-suspension coroutine: each `yield(x)` writes `x` onto
// the `SequenceScope` instance and suspends (`RuntimeError.Suspend = -1`). No pump
// is pushed; it parks only via `yield`/`yieldAll`, never escaping this loop.

/// Set by `yield` immediately before it suspends, so `builderStep` tells a real
/// yield from any other suspension.
pub const seq_has_value_field = "__seq_has_value";
pub const seq_value_field = "__seq_value";
/// The pending `yieldAll` iterator, drained before the block resumes; `Null` or
/// absent when none is in flight.
pub const seq_yield_iter_field = "__seq_yield_iter";

const BuilderStepResult = runtime.BuilderStepResult;
const InstanceData = runtime.InstanceData;

const PendingKind = enum { value, yield_all, none };

/// Read-and-clears the single-value flag.
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

/// `.done` when the iterator is exhausted, where the caller clears it and
/// resumes the block.
fn drainOne(self: anytype, it: *const Value, out: Output) Allocator.Error!union(enum) { value: Value, done, err: RuntimeError } {
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

pub fn builderStep(self: anytype, state: runtime.BuilderStateRef, out: Output) Allocator.Error!BuilderStepResult {
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
    // A failed iterator rejects every later pull, matching
    // `SequenceBuilderIterator`.
    if (failed) {
        return .{ .err = .{ .Thrown = try Value.newException(a, .{
            .fqn = try runtime.strInit(a, "kotlin.IllegalStateException"),
            .message = .from(try runtime.strInit(a, "Iterator has failed.")),
            .cause = null,
            .suppressed = (try runtime.ValueList.init(a, .empty)).cell,
        }) } };
    }
    if (done) return .done;

    // Drain a stashed `yieldAll` before touching the coroutine, so an infinite
    // source never forces the block past its current suspension.
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

    // Loop past empty `yieldAll` suspensions: an exhausted one yields nothing.
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
            r = try self.evalClosureRaw(&block, &.{}, &scope, out);
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
            r = try self.resumeRaw(old, .Unit, out);
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

/// Only a Kotlin throw out of the block fails the iterator.
fn errIsThrow(e: *const RuntimeError) bool {
    return e.* == .Thrown;
}

/// Hand a freshly-suspended activation to the active interceptor. Consumes the
/// `*SuspendState` box: the value is copied in and the box freed, so the inner
/// `frames` list and dup'd slices belong to the copy.
fn park(allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!u64 {
    const top = coroTop() orelse return error.OutOfMemory; // "park outside runBlocking"
    return parkInto(top, allocator, st, scope_base);
}

/// Park into a specific pump: an activation resumed inline runs on whatever stack
/// resumed it but belongs to the pump it parked in, which `coroTop()` may not be.
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

pub fn driveRunBlocking(self: anytype, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return driveRoot(self, block, scope, out, false);
}

/// `persist = true` preserves a coroutine that parks indefinitely into
/// program-lifetime storage on driver exit; `persist = false` abandons it.
pub fn driveRoot(self: anytype, block: *const Value, scope: *const Value, out: Output, persist: bool) Allocator.Error!RuntimeEvalResult {
    const a = self.allocator;
    try coroPush(a);
    // A top-level driver holds the shared virtual clock at the current instant
    // while its body runs synchronously: a coroutine dispatched onto a pool worker
    // must not advance virtual time past `now` before the body reaches the
    // `delay`/`launch` that establish the sibling timers. A pool worker does not
    // claim, since its body may block for real.
    if (!vmhost.scheduler.onPoolWorker()) (coroTop().?).claimNow();
    // An activation abandoned with this pump never runs its scope pop, so the
    // pump truncates the stack to its entry depth on every exit path.
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    const guard = ActiveScopeGuard.enter(scope);
    defer guard.leave();

    // The root's scope base sits below the guard's push, so its park carries the
    // coroutine scope in the `ParkedEntry` and a persisted root re-establishes it
    // on a later pump; otherwise a dispatched delay loop is uncancellable.
    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    const root_scope_base = scope_depth;
    switch (try self.evalClosureRaw(block, &.{}, scope, out)) {
        .ok => |v| root_value = v,
        .err => |e| switch (e) {
            .Suspended => |st| root_token = try park(a, st, root_scope_base),
            else => {
                // Error exit runs the same protocol as quiescence; a bare pop would
                // leave stale owner registrations on a mailbox nobody drains.
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

/// A compiled root block on the same pump, entered by calling a native
/// continuation, so compiled and interpreted programs schedule alike.
pub fn driveRootNative(
    self: anytype,
    call: *const fn (?*anyopaque, runtime.CValue) callconv(.c) runtime.CValue,
    frame: ?*anyopaque,
    out: Output,
) Allocator.Error!RuntimeEvalResult {
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
    const produced = runtime.fromC(call(frame, runtime.toC(.Unit)));
    if (produced == .CoroutineSuspended) {
        const st = ir.eval.takeInFlightSuspend(a) orelse {
            try pumpExit(self, out, false);
            return .{ .err = .{ .Type = "compiled body suspended without a continuation" } };
        };
        root_token = try park(a, st, scope_depth);
    } else {
        root_value = produced;
    }

    if (try pumpLoop(self, &unit, out, false, true, &root_token, &root_value)) |err_result| {
        return err_result;
    }
    try pumpExit(self, out, false);
    return .{ .ok = root_value orelse Value.Unit };
}

/// The equivalent of kotlinc's `runSuspend` wrapper, so a real suspension parks
/// here instead of escaping the run loop. `main` runs in the empty context.
pub fn driveSuspendMain(self: anytype, main_id: ir.FuncId, out: Output) Allocator.Error!RuntimeEvalResult {
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

threadlocal var drive_depth: usize = 0;
threadlocal var drive_depth_max: usize = 0;
threadlocal var drive_count: usize = 0;

/// Drive a persisted continuation to quiescence on the calling thread under a
/// fresh pump, so a coroutine continues on whichever thread its resume arrived.
/// A new indefinite park is re-persisted.
pub fn driveResumed(self: anytype, state_in: SuspendState, value: Value, scope_delta: []const Value, out: Output) Allocator.Error!void {
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
    // Re-establish the activation's own scope before it runs. The base is the
    // depth before the restore, so a re-suspend re-captures the delta.
    const root_scope_base = activeScopeDepth();
    restoreScopeDelta(scope_delta);
    ir.eval.resume_route = "driveResumed";
    switch (try self.resumeRaw(&state, value, out)) {
        .ok => |v| root_value = v,
        .err => |e| switch (e) {
            .Suspended => |st| root_token = try park(a, st, root_scope_base),
            else => {
                // The terminal outcome goes through the completion continuation in
                // the frames; an error escaping raw has no awaiting caller here.
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

/// The shared driver pump: start queued launches, resume ready coroutines, advance
/// timers, drain the mailbox, and for a blocking root wait while the root or
/// dispatched pool work is in flight. Non-null means the pump failed and the
/// interceptor is popped; null means quiescence, with `pumpExit` left to run.
fn pumpLoop(
    self: anytype,
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
        // A deadlocked pump idles in this loop's sleep arms, never the eval loop,
        // so the test runner's watchdog must fire here.
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
            // A failure from an activation that ran inline on a resumer's stack is
            // raised here, where the loop's own failures are.
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
                // A compiled host has no module: its parked frames name themselves.
                const host_mod: ?*const ir.Module = if (@hasField(@TypeOf(self.*), "module")) blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    break :blk mg.get();
                } else null;
                var k: usize = 0;
                while (k < st.frames.items.len and k < 24) : (k += 1) {
                    const snap = st.frames.items[k];
                    const m: *const ir.Module = snap.module orelse (host_mod orelse continue);
                    const f = m.funcById(snap.func);
                    const nm = if (f) |ff| (if (ff.fqn.len != 0) ff.fqn else ff.name) else "?";
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
        // 0. A pool task's pump still running at the run boundary exits through
        //    the protocol.
        if (runtime.shouldAbandon()) {
            try pumpExit(self, out, persist);
            return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
        }

        // 0b. Anything still queued or parked when the root coroutine completes is
        //     outside its job tree and dies with the pump.
        if (stop_on_root_completion and root_token.* == null) break;

        // 0b'. A timeout gate no nested block claimed has no undispatched body to
        //      share a timer queue with, so it runs here as an ordinary timer.
        try (coroTop().?).promoteTimeouts();

        // 0c. While this pump has work at the current virtual instant, hold the
        //     barrier at `now`: a child on its way to `delay(d)` must register
        //     `now + d` before any pump jumps to a later deadline.
        if ((coroTop().?).launched.items.len != 0 or (coroTop().?).ready.items.len != 0) {
            (coroTop().?).claimNow();
        }

        // 1. Start queued child launches. A started launch may enqueue more, so
        //    the round drains again before the clock advances: a timer must park,
        //    its deadline measured from now, first.
        const launched = try (coroTop().?).drainLaunched(a);
        defer a.free(launched);
        // `drainLaunched` empties `self.launched`, so the interceptor no longer
        // marks these blocks. The keepalive restore is registered after the free's
        // `defer`, so it runs first and the slice is valid when it drops.
        const ka_launched = runtime.keepaliveMark();
        defer runtime.keepaliveRestore(ka_launched);
        runtime.keepalivePushSlice(launched);
        for (launched) |child| {
            const child_scope_base = activeScopeDepth();
            const child_res = try self.evalClosureRaw(&child, &.{}, scope, out);
            if (pumpDiagEnabled()) {
                const tag: []const u8 = switch (child_res) {
                    .ok => "ok",
                    .err => |e| @tagName(std.meta.activeTag(e)),
                };
                std.debug.print("[tok] launched-child -> {s}\n", .{tag});
            }
            switch (child_res) {
                // The launch queue's owned reference is done with once the block
                // completes; a suspended block keeps it until its park completes.
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
            // A yield-heavy round keeps the launch queue hot and would starve a
            // parked timer once real time outran the earliest virtual delay.
            if ((coroTop().?).virtualStarvationDue()) _ = try (coroTop().?).advanceTimeGated();
            continue;
        }

        // 2. Fire due Wall deadlines before resuming a ready coroutine, or a
        //    yield-livelocked pair starves `withTimeout` into an unkillable hang.
        try (coroTop().?).armDueWallTimers();
        inline_turn_resumes = 0;
        persist_inline_resumes = 0;
        if ((coroTop().?).nextReady()) |tok| {
            endStreak("ready");
            if ((coroTop().?).takeParked(tok)) |entry_in| {
                var entry = entry_in;
                const resume_with = (coroTop().?).takeResumeValue(tok) orelse Value.Unit;
                // The activation's own scope must be live for its own
                // `coroutineContext` reads; a re-suspension re-captures the delta.
                const scope_base = activeScopeDepth();
                restoreScopeDelta(entry.scope_delta);
                coroStackAllocator().free(entry.scope_delta);
                ir.eval.resume_route = "pump-ready";
                switch (try self.resumeRaw(&entry.state, resume_with, out)) {
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
                        // A launched child's CancellationException is swallowed,
                        // as in a real Kotlin runtime; the root keeps its throw.
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
            if ((coroTop().?).virtualStarvationDue()) _ = try (coroTop().?).advanceTimeGated();
            continue;
        }

        // 3. Advance to the nearest timer. `.blocked` means the barrier holds a
        //    future timer because another pump has earlier work that may cancel
        //    this one, so drain the mailbox and retry; a timer at `now` fires.
        const advance = try (coroTop().?).advanceTimeGated();
        if (advance == .fired) continue;
        const barrier_blocked = advance == .blocked;

        // 3b. Drain resumes posted by worker threads; if a worker is still in
        //     flight, wait briefly for it to post.
        const wakeup = (coroTop().?).wakeup.clone();
        defer {
            var w = wakeup;
            w.deinit();
        }
        _ = wakeup.cell.data.turns.fetchAdd(1, .release);
        wakeup.cell.data.gate.ring();
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
            gateWaitBrief(&wakeup, 1_000);
            _ = try drainWakeupInto(a, &wakeup, coroTop().?);
            continue;
        }

        // 3c. Barrier still holding: yield so the pump with the earlier deadline
        //     can post its cancellation. Never break, the timer is real work.
        if (barrier_blocked) {
            countSleep(.barrier_yield);
            std.Thread.yield() catch sleepMillis(1);
            continue;
        }

        // 3c'. Wall timer pending but not due; never break or park the root here.
        if (advance == .waiting) continue;

        // 3d. A blocking root must not return while its root coroutine is parked:
        //     the job machinery decides when the job completes.
        if (!persist and root_token.* != null) {
            idle_rounds += 1;
            if (idle_rounds == 3000) diagStalledPump(self, coroTop().?, root_token.*, false);
            // A parked root whose resumer never comes idles here, not in the eval
            // loop, so the watchdog must fire from this arm too.
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
            // A dispatched task that died with an internal error never completes its
            // coroutine, so no resume arrives and the run would idle here forever.
            if (vmhost.scheduler.takeFirstError()) |pool_err| {
                try pumpExit(self, out, persist);
                return .{ .err = pool_err };
            }
            // Deadlock breaker: an outer pump that failed during an inline resume
            // has its loop frozen beneath this one, so awaiters park above a
            // recorded failure. After a grace period, surface the stash.
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
            gateWaitBrief(&wakeup, 1_000);
            continue;
        }

        // 4. Nothing queued, ready, or timed: done, or deadlocked with no resumer.
        break;
    }
    return null;
}

/// Driver exit protocol, ordered to close the persist/post race with a resumer on
/// another thread: persist every indefinitely-parked continuation, so a racing
/// resumer that misses the mailbox finds the state; close the mailbox so a later
/// `postResume` reroutes; release the slot-owner entries; re-route the raced-in
/// entries through the persisted registry.
fn pumpExit(self: anytype, out: Output, persist: bool) Allocator.Error!void {
    const a = self.allocator;
    if (persist) {
        const saved = try (coroTop().?).drainIndefiniteParked(a);
        defer a.free(saved);
        for (saved) |s| try PersistedParked.put(s.slot, s.state, s.scope_delta);
    }
    // Queued-but-unstarted launches must still run: a cancelled coroutine completes
    // only when its start task observes the dead Job. Hand them to the pump below.
    var orphan_launched: []Value = &.{};
    if (coroTop()) |top| {
        if (top.launched.items.len != 0) orphan_launched = try top.drainLaunched(a);
    }
    defer if (orphan_launched.len != 0) a.free(orphan_launched);
    // A stashed inline-resume failure this pump never raised goes to the pump
    // below, whose loop head raises it; dropping it parks every awaiter forever.
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
            // The drained blocks carry the retain their enqueue took.
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
        // No persisted state: the waiter was abandoned with its driver.
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

/// `KLIO_PUMP_DIAG` dump of a pump that idled with its root still parked.
fn diagStalledPump(self: anytype, top: *CooperativeInterceptor, root_tok: ?u64, force: bool) void {
    if (!force and !pumpDiagEnabled()) return;
    std.debug.print("[PUMP] stalled root_tok={?d} parked={d} ready={d} launched={d} pumps={d}\n", .{
        root_tok, top.parked.count(), top.ready.items.len, top.launched.items.len, coro_stack.items.len,
    });
    // Every interceptor on this thread: a cancelled-but-uncompleted coroutine's
    // body can be parked in a nested pump the top-only view never shows.
    VirtualClock.dumpState();
    const host_mod2: ?*const ir.Module = if (@hasField(@TypeOf(self.*), "module")) blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get();
    } else null;
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
                const m: *const ir.Module = snap.module orelse (host_mod2 orelse continue);
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

pub fn runBlocking(self: anytype, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return driveRunBlocking(self, block, scope, out);
}

pub fn coroutineRunRoot(self: anytype, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    // A child started by `launch` inside a live driver joins the enclosing
    // interceptor, so a suspension parks there and that driver resumes it.
    if (coroTop() != null) {
        const a = self.allocator;
        // The coroutine's own scope must be active so `coroutineContext` resolves
        // to its `Job`.
        const scope_base = activeScopeDepth();
        var guard = ActiveScopeGuard{ .pushed = false };
        if (scope) |s| guard = ActiveScopeGuard.enter(s);
        defer guard.leave();
        switch (try self.evalClosureRaw(block, &.{}, null, out)) {
            .ok => |v| return .{ .ok = v },
            .err => |e| switch (e) {
                .Suspended => |st| {
                    // `park` moved this guard's push into the `ParkedEntry`, so the
                    // guard must not pop again.
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

pub fn coroutineHasDriver() bool {
    return coroTop() != null;
}

/// `ident` is 0 when nothing was pushed.
pub const UndispatchedEnter = struct { base: usize, ident: usize };
pub fn undispatchedFlatEnter(scope: *const Value) UndispatchedEnter {
    root_suspension_hit = false;
    const base = activeScopeDepth();
    const g = ActiveScopeGuard.enter(scope);
    return .{ .base = base, .ident = if (g.pushed) g.ident else 0 };
}

/// Undo `undispatchedFlatEnter`'s push by identity, never a blind top pop. No-op
/// once the entry was captured into a parked scope delta.
pub fn undispatchedFlatLeaveIdent(ident: usize) void {
    if (ident == 0) return;
    (ActiveScopeGuard{ .pushed = true, .ident = ident }).leave();
}

/// Null when a driver already encloses this thread.
pub fn rootPumpFlatEnter(allocator: Allocator, scope: *const Value) Allocator.Error!?UndispatchedEnter {
    if (coroTop() != null) return null;
    root_suspension_hit = false;
    try coroPush(allocator);
    if (!vmhost.scheduler.onPoolWorker()) (coroTop().?).claimNow();
    const base = activeScopeDepth();
    const g = ActiveScopeGuard.enter(scope);
    return .{ .base = base, .ident = if (g.pushed) g.ident else 0 };
}

/// `res_ok` null with `aborted` true only exits the pump.
pub fn rootPumpFlatFinish(self: anytype, out: Output, scope: *const Value, res_ok: ?Value, base: usize, aborted: bool) Allocator.Error!RuntimeEvalResult {
    defer active_scope_stack.shrinkRetainingCapacity(@min(base, active_scope_stack.items.len));
    if (aborted) {
        try pumpExit(self, out, true);
        return .{ .ok = Value.Unit };
    }
    var root_value: ?Value = res_ok;
    var root_token: ?u64 = null;
    if (try pumpLoop(self, scope, out, true, true, &root_token, &root_value)) |err_result| return err_result;
    try pumpExit(self, out, true);
    return .{ .ok = root_value orelse Value.Unit };
}

/// Reports the resumed value, or `CoroutineSuspended` when the root stays parked.
pub fn rootPumpFlatPark(self: anytype, allocator: Allocator, out: Output, st: *SuspendState, scope: *const Value, base: usize) Allocator.Error!RuntimeEvalResult {
    defer active_scope_stack.shrinkRetainingCapacity(@min(base, active_scope_stack.items.len));
    var root_token: ?u64 = try park(allocator, st, base);
    var root_value: ?Value = null;
    if (try pumpLoop(self, scope, out, true, true, &root_token, &root_value)) |err_result| return err_result;
    try pumpExit(self, out, true);
    if (root_token != null) return .{ .ok = Value.CoroutineSuspended };
    return .{ .ok = root_value orelse Value.Unit };
}

/// Hand the parked segment, with its scope delta above `scope_base`, to the
/// enclosing pump. Ownership of `st` moves to the pump.
pub fn undispatchedFlatPark(allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!Value {
    if (pumpDiagEnabled()) std.debug.print("[tok] barrier-park frames={d}\n", .{st.frames.items.len});
    _ = try park(allocator, st, scope_base);
    return Value.CoroutineSuspended;
}

/// Run `block` as a fresh root with no enclosing driver. A genuine suspension
/// parks the root, pumps to quiescence, persists it under its armed slot and
/// returns `CoroutineSuspended`; the completion arrives later through the captured
/// continuation.
pub fn coroutineStartRootOrSuspended(self: anytype, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    const a = self.allocator;
    const unit: Value = .Unit;
    const scope_v: *const Value = if (scope) |s| s else &unit;

    // Inside an existing driver an undispatched start runs only the synchronous
    // prefix: a real suspension parks onto the enclosing pump and is reported to
    // the caller, which continues while the tail resumes in queue order.
    if (coroTop() != null) {
        const scope_base = activeScopeDepth();
        var guard = ActiveScopeGuard.enter(scope_v);
        defer guard.leave();
        root_suspension_hit = false;
        switch (try self.evalClosureRaw(block, &.{}, scope_v, out)) {
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

    // Base below the guard's push, as in `driveRoot`, so a persisted root resumes
    // with `coroutineContext` intact on any later pump.
    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    const root_scope_base = scope_depth;
    switch (try self.evalClosureRaw(block, &.{}, scope_v, out)) {
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
    // Still parked after quiescence: persisted awaiting an external resume.
    if (root_token != null) return .{ .ok = Value.CoroutineSuspended };
    return .{ .ok = root_value orelse Value.Unit };
}

pub fn coroutineLaunch(self: anytype, block: *const Value, scope: *const Value, out: Output) Allocator.Error!?RuntimeError {
    _ = scope;
    if (coroTop()) |top| {
        try top.enqueueLaunch(block.*);
        return null;
    }
    // No active `runBlocking`: run the child eagerly through the driving host.
    return startChildEagerly(self, block, out);
}

/// `invokeCallable` is the interpreter's entry; a host without one starts the
/// block the way it starts a queued one.
fn startChildEagerly(self: anytype, block: *const Value, out: Output) Allocator.Error!?RuntimeError {
    if (@hasDecl(@TypeOf(self.*), "invokeCallable")) {
        return switch (try self.invokeCallable(block, &.{}, out)) {
            .ok => null,
            .err => |e| e,
        };
    }
    return switch (try self.evalClosureRaw(block, &.{}, null, out)) {
        .ok => null,
        .err => |e| mapDriverErr(self.allocator, e),
    };
}

/// `invokeOnTimeout`'s gate belongs with the block it cancels, which runs as its
/// own nested pump, so it is queued separately for `coroutineStartRootOrSuspended`
/// to move onto that pump, letting the earlier deadline fire first.
pub fn coroutineSpawnTimeout(self: anytype, block: *const Value, out: Output) Allocator.Error!?RuntimeError {
    if (coroTop()) |top| {
        try top.enqueueTimeout(block.*);
        return null;
    }
    return startChildEagerly(self, block, out);
}

pub fn coroutineArmSlot(self: anytype, slot: i64) void {
    _ = self;
    if (coroTop()) |top| top.setPendingSlot(slot) catch {};
}

pub fn coroutineDisarmSlot(self: anytype) void {
    _ = self;
    if (coroTop()) |top| top.clearPendingSlot();
}

/// Whether the most recent undispatched start saw its root body park.
threadlocal var last_root_parked_once: bool = false;

/// Set whenever a suspension boundary is crossed; reset when an undispatched start
/// begins its body, so a start that suspended is distinguishable.
threadlocal var root_suspension_hit: bool = false;

pub fn coroutineNoteSuspensionHit(self: anytype) void {
    _ = self;
    root_suspension_hit = true;
}

pub fn coroutineResetSuspensionHit() void {
    root_suspension_hit = false;
}

pub fn coroutineLastRootParkedOnce(self: anytype) bool {
    _ = self;
    return root_suspension_hit;
}

/// Push the block's own coroutine scope so `coroutineContext` resolves to it and a
/// cancellable suspension installs its handle on the right Job. Balanced by
/// `coroutinePopScope` when the resumed body completes.
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

pub fn coroutineResumeSlotValue(self: anytype, slot: i64, value: Value) void {
    // The waiter may be parked on this thread's pump, on a live pump on another
    // OS thread, or persisted after its pump exited.
    coroutineResumeExternal(self, slot, value, self.out_sink.output()) catch {};
}

fn parkedFuncName(self: anytype, st: *const SuspendState) []const u8 {
    if (st.frames.items.len == 0) return "<empty>";
    const snap = st.frames.items[0];
    const mg = self.module.borrow();
    defer mg.deinit();
    const m: *const ir.Module = snap.module orelse mg.get();
    const f = m.funcById(snap.func) orelse return "<unknown>";
    return if (f.fqn.len != 0) f.fqn else f.name;
}

/// `KLIO_NO_INLINE_RESUME` queues every resume on the pump instead.
fn inlineResumeEnabled() bool {
    return runtime.envOnce("KLIO_NO_INLINE_RESUME") == null;
}

fn persistResumeGateEnabled() bool {
    return true;
}

/// Depth of resumes running inline here. A resume arriving while one runs inline
/// still runs before control leaves the resumer, but on the outermost inline
/// resume's stack, so a rendezvous hand-off cannot recurse natively.
threadlocal var inline_depth: usize = 0;

/// Inline resumes since the pump last ran an activation. An activation that never
/// suspends would otherwise resume its peer inline forever, so the pump never turns
/// and virtual time never advances; past the budget resumes go back on the queue.
threadlocal var inline_turn_resumes: usize = 0;

/// How deep one resume may chase the resumes it causes.
const INLINE_CHAIN_BUDGET: usize = 32;

const INLINE_TURN_BUDGET: usize = 2048;

/// How many persisted resumes one synchronous scheduler advance may run inline, so
/// `advanceUntilIdle` goes idle instead of spinning. Reset when the pump turns.
const PERSIST_INLINE_BUDGET: usize = 64;

/// Persisted resumes run inline since the pump last turned, kept separate so the
/// per-advance cap does not throttle `resumeInlineOnce`.
threadlocal var persist_inline_resumes: usize = 0;

pub fn coroutineResumeInline(self: anytype, slot: i64, value: Value, out: Output) Allocator.Error!bool {
    if (!inlineResumeEnabled()) return false;
    if (!slotParkedHere(slot)) return false;
    // A resume raised by a step already running inline may itself run inline, but
    // bounded: a rendezvous hand-off never ends.
    if (inline_depth >= INLINE_CHAIN_BUDGET) return false;
    // A Kotlin-level resume already ordered by its dispatcher's queue is exempt
    // from the per-turn cap, as upstream runs it whenever its dispatcher does.
    if (inline_turn_resumes >= INLINE_TURN_BUDGET and !kotlin_resume_delivery) return false;
    // Dispatcher FIFO: if the pump owning this slot already has ready coroutines
    // queued, the inline shortcut would jump ahead of them, and upstream runs queued
    // resumes in post order. Scoped to Wall pumps: a `runTest` pump routes native
    // channel deliveries through the scheduler's queue, where deferring strands them.
    if (ownerReadyPending(slot)) return false;
    inline_turn_resumes += 1;
    inline_depth += 1;
    defer inline_depth -= 1;
    return resumeInlineOnce(self, slot, value, out);
}

/// Mark the pump owning `slot` as driven by an external dispatcher (a `runTest`
/// scheduler), which orders its dispatched resumes there, so deferring them to
/// `drv.ready` would strand them. Falls back to the innermost pump when unbound.
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

/// Whether the pump owning `slot` has a live parked coroutine queued ready that
/// this resume must fall behind, since a dispatched resume runs its dispatcher's
/// FIFO in post order. A `scheduler_backed` pump keeps the shortcut.
fn ownerReadyPending(slot: i64) bool {
    var i: usize = coro_stack.items.len;
    while (i > 0) {
        i -= 1;
        const drv = &coro_stack.items[i];
        if (drv.slot_to_token.get(slot) != null) {
            if (drv.scheduler_backed) return false;
            // A due deadline is ready work too: a dispatched resume chain never
            // returns to the pump, so arm the Wall timers here as well.
            drv.armDueWallTimers() catch {};
            for (drv.ready.items) |rtok| {
                if (drv.parked.contains(rtok)) return true;
            }
            return false;
        }
    }
    return false;
}

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

/// Resume the activation parked on `slot` on the current stack. False when no
/// pump here holds the slot, or it is a pump's own root.
fn resumeInlineOnce(self: anytype, slot: i64, value: Value, out: Output) Allocator.Error!bool {
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
        switch (try self.resumeRaw(&entry.state, value, out)) {
            .ok => {},
            .err => |e| switch (e) {
                // `park` captures the scope delta off the live stack, so it must
                // run before the truncation below.
                .Suspended => |st| {
                    _ = try parkInto(&coro_stack.items[i], a, st, scope_base);
                },
                // A cancelled child's throw dies with it; every other failure stays
                // on the owning pump, or the coroutine never completes.
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
        // Anything the resumed activation left on the active-scope stack would be
        // read as the host activation's scope by the next `coroutineContext`.
        if (active_scope_stack.items.len > scope_base)
            active_scope_stack.shrinkRetainingCapacity(scope_base);
        return true;
    }
    return false;
}

/// A Kotlin-level `resumeWith` delivery is in flight here, so a persisted target
/// must run on the caller's stack: deferring leaves a `runTest` advance idle with
/// the coroutine still queued.
threadlocal var kotlin_resume_delivery: bool = false;

/// Whether a cross-thread `resumeWith` post waits (bounded) for the owner pump to
/// run the routed step; the wait serializes the pool against the owner.
var sync_resume_checked: bool = false;
var sync_resume_on: bool = false;
fn syncResumeDelivery() bool {
    if (!sync_resume_checked) {
        sync_resume_checked = true;
        sync_resume_on = std.mem.eql(u8, runtime.envOnce("KLIO_SYNC_RESUME") orelse "0", "1");
    }
    return sync_resume_on;
}

/// A Kotlin `Continuation.resumeWith`, run on the caller's stack; the interceptor
/// already decided whether to dispatch, so only a step this thread's pumps do not
/// own falls back to the queue or mailbox route.
pub fn coroutineResumeContinuation(self: anytype, slot: i64, value: Value, out: Output) Allocator.Error!void {
    // `KLIO_RESUME_TRACE`: name the resumer, since diagnosing a double delivery
    // needs to know which Kotlin code performed each `resumeWith`.
    if (runtime.envOnce("KLIO_RESUME_TRACE") != null) {
        std.debug.print("[resume-call] slot={d} resumer:\n", .{slot});
        ir.eval.dumpFrameChainForDiagAlways();
    }
    // The flag spans the inline attempt too: a resume from a dispatcher's own queue
    // must not be deferred to a ready queue the scheduler never drains.
    const prev = kotlin_resume_delivery;
    kotlin_resume_delivery = true;
    defer kotlin_resume_delivery = prev;
    if (try coroutineResumeInline(self, slot, value, out)) return;
    return coroutineResumeExternal(self, slot, value, out);
}

/// Resume a persisted coroutine on this thread's live pump, on the caller's stack:
/// one step, re-parking into the same pump. Adopting it onto the ready queue would
/// defer it until a blocking advance returns. Bounded by the inline budgets.
fn resumePersistedOnTop(self: anytype, pe: PersistedParked.Entry, value: Value, out: Output) Allocator.Error!bool {
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
    // re-park re-captures it and the caller's scope stack is left as found.
    const scope_depth = active_scope_stack.items.len;
    defer active_scope_stack.shrinkRetainingCapacity(@min(scope_depth, active_scope_stack.items.len));
    var state = pe.state;
    const scope_base = activeScopeDepth();
    restoreScopeDelta(pe.scope_delta);
    coroStackAllocator().free(pe.scope_delta);
    ir.eval.resume_route = "persisted-on-top";
    switch (try self.resumeRaw(&state, value, out)) {
        .ok => {},
        // A re-suspension re-parks onto the live pump, staying inline-resumable.
        .err => |e| switch (e) {
            .Suspended => |st| _ = try park(a, st, scope_base),
            // A cancelled child's throw dies with it; every other outcome must reach
            // the pump, or the Job never completes and `runTest` joins forever.
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

pub fn coroutineResumeExternal(self: anytype, slot: i64, value: Value, out: Output) Allocator.Error!void {
    if (pumpDiagEnabled()) std.debug.print("[PUMP] resumeExternal slot={d} tid={d}\n", .{ slot, std.Thread.getCurrentId() });
    // Only the registered owner's pump may serve inline: a coroutine that re-parked
    // on another pump leaves a stale binding that would eat the resume.
    {
        const owner = lookupSlotOwner(slot);
        defer if (owner) |w| {
            var ww = w;
            ww.deinit();
        };
        var i: usize = coro_stack.items.len;
        while (i > 0) {
            i -= 1;
            const p = &coro_stack.items[i];
            if (owner) |w| {
                if (p.wakeup.cell != w.cell) continue;
            }
            if (p.resumeSlotValue(slot, value) catch false) {
                if (pumpDiagEnabled()) std.debug.print("[PUMP] resumeExternal slot={d} routed=inline-samethread\n", .{slot});
                return;
            }
        }
    }
    // Cross-thread: route through the owning driver's mailbox; a rejected post means
    // it just exited and persisted its coroutines, so fall through to the registry.
    // A slot with no owner and no persisted state belongs to a waiter that has not
    // armed, so the resume parks in the stash `registerSlotOwner` claims.
    while (true) {
        if (lookupSlotOwner(slot)) |w| {
            var ww = w;
            defer ww.deinit();
            const turns0 = ww.cell.data.turns.load(.acquire);
            const posted = blk: {
                const g = ww.borrowMut();
                defer g.deinit();
                break :blk try g.get().postResume(slot, value);
            };
            if (posted) {
                // A Kotlin `resumeWith` caller observes its resumption's effects
                // before continuing, so wait for two drive turns past the post.
                if (pumpDiagEnabled()) std.debug.print("[sync] post slot={d} krd={} t0={d}\n", .{ slot, kotlin_resume_delivery, turns0 });
                if (kotlin_resume_delivery and syncResumeDelivery()) {
                    // The owner pump normally turns within microseconds: spin
                    // first, then park in 100us slices, bounded at ~400ms.
                    var spins: u32 = 0;
                    while (spins < 4600) : (spins += 1) {
                        if (ww.cell.data.turns.load(.acquire) >= turns0 + 2) break;
                        if (spins < 200) {
                            std.atomic.spinLoopHint();
                        } else {
                            const seen = ww.cell.data.gate.epochNow();
                            if (ww.cell.data.turns.load(.acquire) >= turns0 + 2) break;
                            ww.cell.data.gate.waitFrom(seen, 100);
                        }
                    }
                    if (pumpDiagEnabled()) std.debug.print("[sync] done slot={d} turns={d} spins={d}\n", .{ slot, ww.cell.data.turns.load(.acquire), spins });
                }
                return;
            }
            // Mailbox closed: the owner exited and persisted its parked
            // coroutines strictly before closing.
            if (PersistedParked.take(slot)) |pe| {
                if (try resumePersistedOnTop(self, pe, value, out)) return;
                if (coroTop()) |top| {
                    try top.adoptPersisted(pe.state, pe.scope_delta, value);
                } else {
                    try driveResumed(self, pe.state, value, pe.scope_delta, out);
                    coroStackAllocator().free(pe.scope_delta);
                }
            }
            // No persisted state either: the waiter was abandoned with its driver.
            if (pumpDiagEnabled()) std.debug.print("[PUMP] resumeExternal slot={d} DROPPED mailbox-closed no-persist\n", .{slot});
            return;
        }
        // The owning root already returned, so the state was persisted. Adopt it
        // onto a live pump rather than nesting a fresh drive per unwind hop, which
        // stacks native drivers thousands deep; otherwise claim and drive it here.
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
        if (try SlotOwners.stashPendingIfUnowned(slot, value)) {
            if (pumpDiagEnabled()) std.debug.print("[PUMP] resumeExternal slot={d} stashed-unowned\n", .{slot});
            return;
        }
        // An owner registered between the miss and the stash; retry.
    }
}

pub fn coroutineDrainToIdle(self: anytype, out: Output) Allocator.Error!?RuntimeError {
    const a = self.allocator;
    while (true) {
        const top = coroTop() orelse break;
        const launched = try top.drainLaunched(a);
        defer a.free(launched);
        const scope = activeCoroScope() orelse Value.Unit;
        for (launched) |child| {
            const child_scope_base = activeScopeDepth();
            const child_res = try self.evalClosureRaw(&child, &.{}, &scope, out);
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
        // Re-drain after any start so a freshly scheduled timer parks before the
        // clock can advance, the same ordering as `pumpLoop`.
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
                switch (try self.resumeRaw(&entry.state, resume_with, out)) {
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
            // `.waiting`: a Wall timer pends and a sleep slice was taken, so keep
            // spinning toward it.
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

    // The contract `driveRoot` relies on: with the base read before the guard's
    // push, a park captures the guard's entry into the root's delta and `leave`
    // no-ops, so a later restore re-establishes the scope.
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
    // The entry survives the drain so an external resume still routes to the
    // persisted continuation.
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

// `setPendingSlot` registers an arena-backed clone in the process-global
// registry, and an error-path exit pops without `releaseOwnedSlots`, so
// `drainSlotOwners` must empty it before the arena reset frees the cell.
test "drainSlotOwners clears registry entries an error path left behind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A driver arms a slot, then exits on an error path with no
    // `releaseOwnedSlots`.
    const slot: i64 = 909;
    {
        var ci = try CooperativeInterceptor.new(arena.allocator());
        defer ci.deinit();
        try ci.setPendingSlot(slot);
        try testing.expect(lookupSlotOwner(slot) != null);
    }
    // The entry is still live here, exactly the leak the error path causes.
    {
        const stale = lookupSlotOwner(slot);
        try testing.expect(stale != null);
        stale.?.deinit();
    }

    drainSlotOwners();
    _ = arena.reset(.retain_capacity);

    // A surviving clone would dangle into the reset arena.
    try testing.expectEqual(@as(?ObjRef(DriverWakeup), null), lookupSlotOwner(slot));
}

// The `DriverWakeup` cell escapes to worker threads through `SlotOwners`, so a
// worker's `postResume` borrow races the driver pump's `drainMailbox` borrow on the
// same cell, mediated by the cell's reader/writer lock. `KLIO_RACE_JITTER` widens
// the window.

const WakeupRaceCtx = struct {
    /// First slot id this round owns; workers route through these.
    base_slot: i64,
    n_slots: i64,
    stop: *std.atomic.Value(bool),
};

fn wakeupRaceDriver(ctx: WakeupRaceCtx) void {
    // The driver pump, as `drainWakeupInto` does each idle round.
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
    // The dispatcher worker, as `coroutineResumeExternal`'s cross-thread branch.
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
    // Registering a span of slots below escapes the cell into the registry.
    var ci = try CooperativeInterceptor.new(a);
    defer ci.deinit();

    const base: i64 = (1 << 40) + @as(i64, @intCast(std.Thread.getCurrentId() & 0xffff)) * 64;
    const n: i64 = 8;
    var s: i64 = base;
    while (s < base + n) : (s += 1) try ci.setPendingSlot(s);

    var stop = std.atomic.Value(bool).init(false);
    const ctx = WakeupRaceCtx{ .base_slot = base, .n_slots = n, .stop = &stop };

    const driver = try std.Thread.spawn(.{}, wakeupRaceDriver, .{ctx});
    var workers: [4]std.Thread = undefined;
    for (&workers) |*wt| wt.* = try std.Thread.spawn(.{}, wakeupRaceWorker, .{ctx});
    for (&workers) |wt| wt.join();
    stop.store(true, .release);
    driver.join();

    // Drop this round's registry entries so the global map does not leak.
    {
        const w = ci.wakeup.borrowMut();
        defer w.deinit();
        w.get().releaseOwnedSlots();
    }
}
