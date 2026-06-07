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
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Block the calling thread for `millis` milliseconds, restarting on
/// signal interruption so the full duration elapses.
fn sleepMillis(millis: u64) void {
    const total_ns = millis *% std.time.ns_per_ms;
    var req: std.os.linux.timespec = .{
        .sec = @intCast(total_ns / std.time.ns_per_s),
        .nsec = @intCast(total_ns % std.time.ns_per_s),
    };
    while (true) {
        var rem: std.os.linux.timespec = undefined;
        const rc = std.os.linux.nanosleep(&req, &rem);
        if (std.os.linux.errno(rc) == .INTR) {
            req = rem;
            continue;
        }
        return;
    }
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

    /// Post a `(slot, value)` resume entry and wake the driver.
    pub fn postResume(self: *DriverWakeup, slot: i64, value: Value) Allocator.Error!void {
        self.mailbox.lock();
        defer self.mailbox.unlock();
        try self.mailbox_entries.append(self.allocator, .{ .slot = slot, .value = value });
    }

    /// Take everything queued in the mailbox.
    pub fn drainMailbox(self: *DriverWakeup, allocator: Allocator) Allocator.Error![]MailboxEntry {
        self.mailbox.lock();
        defer self.mailbox.unlock();
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
/// owns the slot it parked on. The registry and its backing map live
/// for the whole process, mirroring the Rust `static LazyLock<Mutex<
/// HashMap<…>>>`: the map itself is never freed, so it is backed by the
/// page allocator rather than any per-run allocator. The `DriverWakeup`
/// handles it holds are owned clones, dropped on `unregisterSlot` /
/// `releaseOwnedSlots`.
const SlotOwners = struct {
    var mutex: SpinMutex = .{};
    var map: ?std.AutoHashMap(i64, ObjRef(DriverWakeup)) = null;

    /// Allocator backing the process-global registry; never freed.
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
};

/// Publish `slot` → `wakeup` so a worker thread's completion resume
/// routes back through the driver's mailbox.
pub fn registerSlotOwner(slot: i64, wakeup: *const ObjRef(DriverWakeup)) Allocator.Error!void {
    {
        const w = wakeup.borrowMut();
        defer w.deinit();
        try w.get().addOwnedSlot(slot);
    }
    SlotOwners.mutex.lock();
    defer SlotOwners.mutex.unlock();
    const m = try SlotOwners.ensure();
    const gop = try m.getOrPut(slot);
    if (gop.found_existing) gop.value_ptr.deinit();
    gop.value_ptr.* = wakeup.clone();
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
            .parked = std.AutoHashMap(u64, ParkedEntry).init(allocator),
            .ready = .empty,
            .launched = .empty,
            .pending_slot = null,
            .slot_to_token = std.AutoHashMap(i64, u64).init(allocator),
            .token_resume_value = std.AutoHashMap(u64, Value).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CooperativeInterceptor) void {
        self.wakeup.deinit();
        self.parked.deinit();
        self.ready.deinit(self.allocator);
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
    pub fn interceptSuspend(self: *CooperativeInterceptor, state_in: SuspendState) Allocator.Error!u64 {
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
        try self.parked.put(token, .{ .state = state, .wake_at = wake_at });
        return token;
    }

    /// Seam: record the slot the next indefinitely-parked activation is
    /// waiting on (set by `__kxco_parkSlot`). Also publishes the slot →
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
                    try out.append(allocator, .{ .slot = st.slot, .state = kv.value.state });
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

    /// Seam: queue a child `launch` block.
    pub fn enqueueLaunch(self: *CooperativeInterceptor, block: Value) Allocator.Error!void {
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

    /// Wake every parked activation whose wake-at is a finite
    /// virtual-time deadline (i.e. parked on a `delay`/`withTimeout`).
    /// Each is removed from `parked` ordering by being marked ready now,
    /// its resume value is set to the supplied `failure` (a
    /// `Value.Result { ok = false, … }` that the resume path in
    /// `ir.eval` routes as a throw at the suspension point), and the
    /// token is queued ready. Indefinite parks (`wake_at` ==
    /// `INDEFINITE`) such as join/await/channel-receive are not touched.
    pub fn cancelTimedParks(self: *CooperativeInterceptor, failure: Value) Allocator.Error!void {
        var due: std.ArrayList(u64) = .empty;
        defer due.deinit(self.allocator);
        var it = self.parked.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.wake_at != INDEFINITE) {
                try due.append(self.allocator, e.key_ptr.*);
            }
        }
        for (due.items) |tok| {
            if (self.parked.getPtr(tok)) |entry| {
                entry.wake_at = 0;
            }
            try self.token_resume_value.put(tok, failure);
            try self.ready.append(self.allocator, tok);
        }
    }

    /// Seam: nothing ready — advance the clock to the soonest timer and
    /// arm every activation due then. Under `Virtual` the clock jumps
    /// instantly; under `Wall` the thread sleeps until the real
    /// deadline. Returns whether any progress was made.
    pub fn advanceTime(self: *CooperativeInterceptor) Allocator.Error!bool {
        var soonest: ?i64 = null;
        {
            var it = self.parked.iterator();
            while (it.next()) |e| {
                const w = e.value_ptr.wake_at;
                if (w == INDEFINITE) continue;
                if (soonest == null or w < soonest.?) soonest = w;
            }
        }
        const t = soonest orelse return false;
        switch (self.mode) {
            .Virtual => {
                if (t > self.virtual_now) self.virtual_now = t;
            },
            .Wall => {
                const wait = @max(t - self.nowMillis(), 0);
                if (wait > 0) {
                    const wait_ms: u64 = @intCast(wait);
                    sleepMillis(wait_ms);
                }
            },
        }
        const now = self.nowMillis();
        var due: std.ArrayList(u64) = .empty;
        defer due.deinit(self.allocator);
        {
            var it = self.parked.iterator();
            while (it.next()) |e| {
                const w = e.value_ptr.wake_at;
                if (w != INDEFINITE and w <= now) {
                    try due.append(self.allocator, e.key_ptr.*);
                }
            }
        }
        std.mem.sort(u64, due.items, {}, std.sort.asc(u64));
        for (due.items) |tok| {
            try self.ready.append(self.allocator, tok);
        }
        return due.items.len != 0;
    }

    pub const SlotState = struct {
        slot: i64,
        state: SuspendState,
    };

    const SlotToken = struct {
        slot: i64,
        token: u64,
    };
};

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "intercept_suspend assigns tokens and queues ready / parks timed" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();
    ci.mode = .Virtual;

    // wake_in_millis == 0 -> immediately ready.
    const tok_ready = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 0 });
    try testing.expectEqual(@as(u64, 1), tok_ready);
    // positive -> parked on a timer, not ready yet.
    const tok_timed = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 50 });
    try testing.expectEqual(@as(u64, 2), tok_timed);

    try testing.expectEqual(@as(?u64, tok_ready), ci.nextReady());
    try testing.expectEqual(@as(?u64, null), ci.nextReady());
}

test "advance_time jumps the virtual clock and arms due tokens in order" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();
    ci.mode = .Virtual;

    const a = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 30 });
    const b = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 10 });
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
    const tok = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = -1 });
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
    const tok = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = -1 });

    try testing.expect(try ci.resumeSlotValue(3, .{ .Int = 42 }));
    try testing.expectEqual(@as(?u64, tok), ci.nextReady());
    const v = ci.takeResumeValue(tok);
    try testing.expect(v != null);
    try testing.expectEqual(@as(i32, 42), v.?.Int);
    // A second resume on the same slot finds no waiter.
    try testing.expect(!try ci.resumeSlot(3));
}

test "cancel_timed_parks wakes only finite-deadline parks with the failure" {
    var ci = try CooperativeInterceptor.new(testing.allocator);
    defer ci.deinit();
    ci.mode = .Virtual;

    const timed = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = 100 });
    const indef = try ci.interceptSuspend(.{ .token = 0, .wake_in_millis = -1 });

    try ci.cancelTimedParks(.{ .Bool = false });
    try testing.expectEqual(@as(?u64, timed), ci.nextReady());
    try testing.expectEqual(@as(?u64, null), ci.nextReady());
    const v = ci.takeResumeValue(timed);
    try testing.expect(v != null);
    try testing.expectEqual(false, v.?.Bool);
    // The indefinite park is untouched and still parked.
    try testing.expect(ci.parked.get(indef) != null);
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
        try w.get().postResume(9, .{ .Int = 7 });
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
