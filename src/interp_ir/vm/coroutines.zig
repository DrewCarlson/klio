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

/// Coroutines that parked indefinitely inside a driven root and are
/// awaiting an external `Continuation.resume`. Keyed by rendezvous slot;
/// the resume drives the saved state to completion. Program/thread
/// lifetime — the held continuation outlives the driver that started it
/// (the Rust `PERSISTED_PARKED`).
threadlocal var persisted_parked: ?std.AutoHashMap(i64, SuspendState) = null;

fn coroStackAllocator() Allocator {
    return std.heap.page_allocator;
}

/// Assert (Debug) the coroutine interceptor and active-scope stacks are empty
/// at a run boundary and clear them so leaked-across-runs coroutine context is
/// a loud failure. `persisted_parked` is intentionally NOT reset here: it holds
/// continuations that outlive the driver that started them.
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

/// Push a fresh interceptor for a newly-entered driven root.
fn coroPush(allocator: Allocator) Allocator.Error!void {
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
fn park(allocator: Allocator, st: *SuspendState) Allocator.Error!u64 {
    const top = coroTop() orelse return error.OutOfMemory; // "park outside runBlocking"
    const value = st.*;
    allocator.destroy(st);
    return top.interceptSuspend(value);
}

/// Layer 2 — the default interceptor's dispatch loop (`drive_run_blocking`).
pub fn driveRunBlocking(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return driveRoot(self, block, scope, out, false);
}

/// `driveRunBlocking` with control over whether a coroutine that parks
/// indefinitely (awaiting an external resume) is preserved into
/// program-lifetime storage on driver exit (`persist = true`, the
/// `startCoroutine` boundary) or simply abandoned (`persist = false`,
/// `runBlocking`). One tightly-coupled coroutine state machine.
pub fn driveRoot(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output, persist: bool) Allocator.Error!RuntimeEvalResult {
    const a = self.allocator;
    try coroPush(a);
    const guard = ActiveScopeGuard.enter(scope);
    defer guard.leave();

    // Root coroutine.
    var root_value: ?Value = null;
    var root_token: ?u64 = null;
    switch (try intrinsic_host.evalClosureRaw(self, block, &.{}, scope, out)) {
        .ok => |v| root_value = v,
        .err => |e| switch (e) {
            .Suspended => |st| root_token = try park(a, st),
            else => {
                if (coroPop()) |w| {
                    var ww = w;
                    ww.deinit();
                }
                return .{ .err = mapDriverErr(a, e) };
            },
        },
    }

    while (true) {
        // 1. Start any queued child launches.
        const launched = try (coroTop().?).drainLaunched(a);
        defer a.free(launched);
        const progressed = launched.len != 0;
        for (launched) |child| {
            switch (try intrinsic_host.evalClosureRaw(self, &child, &.{}, scope, out)) {
                .ok => {},
                .err => |e| switch (e) {
                    .Suspended => |st| _ = try park(a, st),
                    else => {
                        if (coroPop()) |w| {
                            var ww = w;
                            ww.deinit();
                        }
                        return .{ .err = mapDriverErr(a, e) };
                    },
                },
            }
        }

        // 2. Resume a ready coroutine, if any.
        if ((coroTop().?).nextReady()) |tok| {
            if ((coroTop().?).takeParked(tok)) |entry_in| {
                var entry = entry_in;
                const resume_with = (coroTop().?).takeResumeValue(tok) orelse Value.Unit;
                switch (try intrinsic_host.resumeRaw(self, &entry.state, resume_with, out)) {
                    .ok => |v| {
                        if (root_token != null and root_token.? == tok) {
                            root_value = v;
                            root_token = null;
                        }
                    },
                    .err => |e| switch (e) {
                        .Suspended => |st2| {
                            const new_tok = try park(a, st2);
                            if (root_token != null and root_token.? == tok) {
                                root_token = new_tok;
                            }
                        },
                        // A launched child observing a CancellationException
                        // (Job.cancel / withTimeout cooperative cancel) is
                        // swallowed, matching a real Kotlin runtime; the root
                        // keeps its throw semantics.
                        .Throw => |v| {
                            if ((root_token == null or root_token.? != tok) and root.isCancellationException(&v)) {
                                // swallow
                            } else {
                                if (coroPop()) |w| {
                                    var ww = w;
                                    ww.deinit();
                                }
                                return .{ .err = mapDriverErr(a, e) };
                            }
                        },
                        else => {
                            if (coroPop()) |w| {
                                var ww = w;
                                ww.deinit();
                            }
                            return .{ .err = mapDriverErr(a, e) };
                        },
                    },
                }
            }
            continue;
        }

        // 3. No ready coroutine — advance virtual time to the nearest timer
        //    and arm every coroutine due then.
        if (try (coroTop().?).advanceTime()) continue;

        // 3b. Cross-thread bridge: drain any resumes posted by worker
        //     threads (e.g. `Dispatchers.Default`) into the interceptor; if
        //     a worker is still in flight, wait briefly for it to post.
        const wakeup = (coroTop().?).wakeup.clone();
        defer {
            var w = wakeup;
            w.deinit();
        }
        const had_resume = try drainWakeupInto(a, &wakeup, coroTop().?);
        if (had_resume) continue;
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

        // 4. Nothing ready, no timers: done (or deadlocked on an
        //    indefinitely-parked coroutine with no resumer).
        if (!progressed) break;
    }

    if (persist) {
        // A coroutine that parked indefinitely is alive, waiting on a
        // continuation held outside this driver. Preserve it so a later
        // external resume can drive it to completion.
        const saved = try (coroTop().?).drainIndefiniteParked(a);
        defer a.free(saved);
        if (saved.len != 0) {
            const m = try persistedParkedMap();
            for (saved) |s| try m.put(s.slot, s.state);
        }
    }

    // Release any global slot-owner entries still pointing at this driver's
    // wakeup so cross-thread routing doesn't leak.
    if (coroPop()) |w| {
        var ww = w;
        {
            const g = ww.borrowMut();
            g.get().releaseOwnedSlots();
            g.deinit();
        }
        ww.deinit();
    }
    return .{ .ok = root_value orelse Value.Unit };
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

/// The persisted-parked map, created on first use.
fn persistedParkedMap() Allocator.Error!*std.AutoHashMap(i64, SuspendState) {
    if (persisted_parked == null) {
        persisted_parked = std.AutoHashMap(i64, SuspendState).init(coroStackAllocator());
    }
    return &persisted_parked.?;
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
        var guard = ActiveScopeGuard{ .pushed = false };
        if (scope) |s| guard = ActiveScopeGuard.enter(s);
        defer guard.leave();
        switch (try intrinsic_host.evalClosureRaw(self, block, &.{}, null, out)) {
            .ok => |v| return .{ .ok = v },
            .err => |e| switch (e) {
                .Suspended => |st| {
                    _ = try park(a, st);
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

pub fn coroutineResumeSlotValue(self: *VmIntrinsicHost, slot: i64, value: Value) void {
    _ = self;
    var i: usize = coro_stack.items.len;
    while (i > 0) {
        i -= 1;
        if (coro_stack.items[i].resumeSlotValue(slot, value) catch false) break;
    }
}

pub fn coroutineCancelTimedParksWith(self: *VmIntrinsicHost, cause: ?Value) Allocator.Error!void {
    const a = self.allocator;
    const exc = cause orelse Value{ .Exception = .{
        .fqn = try runtime.StringRef.init(a, "kotlin.coroutines.cancellation.CancellationException"),
        .message = try runtime.StringRef.init(a, "StandaloneCoroutine was cancelled"),
        .cause = null,
    } };
    const payload = try Value.box(a, exc);
    const failure = Value{ .Result = .{ .ok = false, .payload = payload } };
    if (coroTop()) |top| try top.cancelTimedParks(failure);
}

pub fn coroutineResumeExternal(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) Allocator.Error!void {
    // A live cooperative driver still holding this slot? Enqueue there —
    // its drive loop runs the activation.
    {
        var i: usize = coro_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (coro_stack.items[i].resumeSlotValue(slot, value) catch false) return;
        }
    }
    // Cross-thread: the slot is owned by a driver on another OS thread
    // (e.g. a `Dispatchers.Default` worker resuming `await` back on the
    // main `runBlocking` pump). Route through the driver's mailbox.
    if (lookupSlotOwner(slot)) |w| {
        var ww = w;
        defer ww.deinit();
        const g = ww.borrowMut();
        defer g.deinit();
        try g.get().postResume(slot, value);
        return;
    }
    // Otherwise the coroutine parked inside a driven root that already
    // returned; its state was preserved. Drive it to completion now.
    if (persisted_parked) |*m| {
        if (m.fetchRemove(slot)) |kv| {
            var st = kv.value;
            _ = try intrinsic_host.resumeRaw(self, &st, value, out);
        }
    }
}

pub fn coroutineDrainToIdle(self: *VmIntrinsicHost, out: Output) Allocator.Error!?RuntimeError {
    const a = self.allocator;
    while (true) {
        const top = coroTop() orelse break;
        const launched = try top.drainLaunched(a);
        defer a.free(launched);
        const progressed = launched.len != 0;
        const scope = activeCoroScope() orelse Value.Unit;
        for (launched) |child| {
            switch (try intrinsic_host.evalClosureRaw(self, &child, &.{}, &scope, out)) {
                .ok => {},
                .err => |e| switch (e) {
                    .Suspended => |st| _ = try park(a, st),
                    .Throw => |v| {
                        if (!root.isCancellationException(&v)) return mapDriverErr(a, e);
                    },
                    else => return mapDriverErr(a, e),
                },
            }
        }
        if ((coroTop().?).nextReady()) |tok| {
            if ((coroTop().?).takeParked(tok)) |entry_in| {
                var entry = entry_in;
                const resume_with = (coroTop().?).takeResumeValue(tok) orelse Value.Unit;
                switch (try intrinsic_host.resumeRaw(self, &entry.state, resume_with, out)) {
                    .ok => {},
                    .err => |e| switch (e) {
                        .Suspended => |st2| _ = try park(a, st2),
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
        if (!progressed) break;
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
                g.get().postResume(s, .Unit) catch {};
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
