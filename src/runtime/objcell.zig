//! Adaptive reference-counted, interior-mutable cell behind `ObjRef`.
//!
//! `ObjRef(T)` is the handle to a shared, interior-mutable Kotlin heap
//! object. The backing is a heap-allocated control block holding an
//! atomic strong count (so handles are safe to share across threads)
//! over a borrow path that stays non-atomic and `RefCell`-fast until a
//! reference is published across threads.
//!
//! While a cell is **unshared** (only ever reachable from its creating
//! thread — the case for essentially every object, and the only case
//! until a reference is published across threads) borrow tracking is a
//! single non-atomic `flag`, exactly `RefCell`'s algorithm and speed.
//! When the runtime publishes a reference to another thread it calls
//! `publish`, which transitions the cell to **shared** under a release
//! store before the reference can be observed elsewhere; shared cells
//! mediate all access through `lock`, a reader/writer lock — any number
//! of concurrent shared `borrow`s, an exclusive `borrowMut`.
//!
//! `flag`: `0` = free, `n > 0` = `n` shared borrows, `-1` = mutably
//! borrowed (the `RefCell` encoding). Only the UNSHARED path touches
//! `flag`; the SHARED path's discipline is the `RwLock` itself.
//!
//! Synchronization choice: Zig 0.16's std has no blocking
//! `Thread.Mutex`/`RwLock` (those moved behind the `Io` interface), so
//! the SHARED reader/writer lock here is a small spin lock built on
//! `std.atomic.Value` with a `spinLoopHint`/`Thread.yield` backoff.
//! It provides the same discipline the protocol needs: many concurrent
//! shared readers, one exclusive writer, with acquire/release ordering.
//! The `state` `release` store on `publish` paired with the `acquire`
//! load in every borrow is the publication happens-before edge; the
//! per-cell lock orders all post-publication accesses.
//!
//! Allocator convention: an `ObjRef` owns a heap-allocated control
//! block. The allocator used to create it is stored *inside* the
//! control block, so `clone`, `deinit`, `borrow`, etc. need no
//! allocator argument — only `init` does. `deinit` decrements the
//! strong count and frees the block (running `T`'s `deinit` if it has
//! one) when the count reaches zero.

const std = @import("std");

const UNSHARED: u8 = 0;
const SHARED: u8 = 1;

/// Reader/writer spin lock for the SHARED path. `state` encodes the
/// lock as `RefCell` does its flag: `0` free, `n > 0` n active readers,
/// `WRITER` (the sign bit) exclusive writer. Many readers proceed
/// concurrently; a writer is exclusive against all readers and writers.
const SpinRwLock = struct {
    /// `0` = free; positive = reader count; `WRITER` = exclusively
    /// write-locked.
    state: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    const WRITER: i32 = std.math.minInt(i32);

    fn lockShared(self: *SpinRwLock) void {
        while (true) {
            const s = self.state.load(.monotonic);
            if (s >= 0) {
                if (self.state.cmpxchgWeak(s, s + 1, .acquire, .monotonic) == null) {
                    return;
                }
            }
            backoff();
        }
    }

    fn unlockShared(self: *SpinRwLock) void {
        _ = self.state.fetchSub(1, .release);
    }

    fn lockExclusive(self: *SpinRwLock) void {
        while (true) {
            if (self.state.cmpxchgWeak(0, WRITER, .acquire, .monotonic) == null) {
                return;
            }
            backoff();
        }
    }

    fn unlockExclusive(self: *SpinRwLock) void {
        self.state.store(0, .release);
    }

    inline fn backoff() void {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }
};

/// Exclusive spin lock. Zig 0.16's std has no blocking `Thread.Mutex`
/// (synchronization moved behind the `Io` interface), so this is a small
/// spin lock over `std.atomic.Value` with the same `spinLoopHint`/
/// `Thread.yield` backoff as `SpinRwLock`. It is the one shared mutex
/// definition imported by the interpreter, the stdlib concurrency
/// intrinsics, and the shared output/closure handles; it provides the
/// exclusive-access discipline a `Mutex` would, with acquire/release
/// ordering.
pub const SpinMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinMutex) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

/// Heap-allocated control block for one `ObjRef`: an atomic strong
/// count plus the adaptive cell (publication `state`, the UNSHARED
/// `RefCell` borrow `flag`, the SHARED reader/writer `lock`, the data,
/// and the owning allocator).
pub fn ControlBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        refcount: std.atomic.Value(usize),
        state: std.atomic.Value(u8),
        flag: isize,
        lock: SpinRwLock,
        data: T,
        allocator: std.mem.Allocator,
    };
}

/// Error returned by `ObjRef.tryBorrowMut` when the cell is already
/// borrowed (mirrors Rust's `BorrowMutError` / `std::cell::BorrowMutError`).
pub const BorrowMutError = error{AlreadyBorrowed};

/// Handle to a shared, interior-mutable Kotlin heap object.
///
/// Clone increments the strong count; `deinit` decrements it and frees
/// the backing control block when it reaches zero. The handle itself is
/// a plain pointer-sized value; copying the struct without going through
/// `clone` does NOT bump the count, so copy only when you also `deinit`
/// exactly once per logical owner (the Rust `Clone`/`Drop` discipline).
pub fn ObjRef(comptime T: type) type {
    return struct {
        const Self = @This();
        const Cell = ControlBlock(T);

        cell: *Cell,

        /// Allocate a new cell holding `v`. The allocator is retained
        /// inside the control block and reused for `deinit`.
        pub fn init(allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!Self {
            const cell = try allocator.create(Cell);
            cell.* = .{
                .refcount = std.atomic.Value(usize).init(1),
                .state = std.atomic.Value(u8).init(UNSHARED),
                .flag = 0,
                .lock = .{},
                .data = v,
                .allocator = allocator,
            };
            return .{ .cell = cell };
        }

        /// Increment the strong count and return another handle to the
        /// same cell (Rust's `Clone for ObjRef` / `Arc::clone`).
        pub fn clone(self: Self) Self {
            _ = self.cell.refcount.fetchAdd(1, .monotonic);
            return .{ .cell = self.cell };
        }

        /// Drop one handle: decrement the strong count and, when it hits
        /// zero, run `T.deinit` if present and free the control block
        /// (Rust's `Drop for Arc`).
        pub fn deinit(self: Self) void {
            if (self.cell.refcount.fetchSub(1, .release) == 1) {
                // Acquire-load pairs with the release decrements of the
                // other handles so all their writes happen-before this
                // free (Arc's drop ordering).
                _ = self.cell.refcount.load(.acquire);
                const allocator = self.cell.allocator;
                if (comptime hasDeinit(T)) {
                    deinitData(&self.cell.data, allocator);
                }
                allocator.destroy(self.cell);
            }
        }

        fn hasDeinit(comptime U: type) bool {
            return switch (@typeInfo(U)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(U, "deinit"),
                else => false,
            };
        }

        fn deinitData(data: *T, allocator: std.mem.Allocator) void {
            const Fn = @TypeOf(T.deinit);
            const info = @typeInfo(Fn).@"fn";
            // Support both `deinit(self)` and `deinit(self, allocator)`.
            if (info.params.len >= 2) {
                data.deinit(allocator);
            } else {
                data.deinit();
            }
        }

        /// Shared borrow, exactly like `RefCell::borrow`.
        /// Panics if the cell is already mutably borrowed (UNSHARED path).
        pub fn borrow(self: Self) ObjGuard(T) {
            return self.tryBorrow() orelse @panic("ObjRef already mutably borrowed");
        }

        /// Mutable borrow, exactly like `RefCell::borrow_mut`.
        /// Panics if the cell is already borrowed (UNSHARED path).
        pub fn borrowMut(self: Self) ObjGuardMut(T) {
            return self.tryBorrowMut() catch @panic("ObjRef already borrowed");
        }

        /// Fallible shared borrow (mirrors `RefCell::try_borrow`).
        pub fn tryBorrow(self: Self) ?ObjGuard(T) {
            const cell = self.cell;
            if (cell.state.load(.acquire) == SHARED) {
                // SHARED path: the read lock is the discipline. Many
                // shared borrows run concurrently; an exclusive
                // borrowMut blocks until they drain. `flag` is not
                // consulted or mutated here.
                cell.lock.lockShared();
                return .{ .cell = cell, .shared = true };
            }
            const f = cell.flag;
            if (f < 0) return null;
            cell.flag = f + 1;
            return .{ .cell = cell, .shared = false };
        }

        /// Fallible mutable borrow (mirrors `RefCell::try_borrow_mut`).
        pub fn tryBorrowMut(self: Self) BorrowMutError!ObjGuardMut(T) {
            const cell = self.cell;
            if (cell.state.load(.acquire) == SHARED) {
                // SHARED path: the write lock is the discipline —
                // exclusive against every reader and writer. It blocks
                // (monitor-like) rather than failing if borrows are
                // live on other threads; that is the intended behavior,
                // not a RefCell-style error. `flag` is untouched.
                cell.lock.lockExclusive();
                return .{ .cell = cell, .shared = true };
            }
            if (cell.flag != 0) return BorrowMutError.AlreadyBorrowed;
            cell.flag = -1;
            return .{ .cell = cell, .shared = false };
        }

        /// Transition the cell to the shared state with a release store.
        /// Called at the publication seam before the reference escapes
        /// to another thread. Idempotent.
        pub fn publish(self: Self) void {
            self.cell.state.store(SHARED, .release);
        }

        pub fn isShared(self: Self) bool {
            return self.cell.state.load(.acquire) == SHARED;
        }

        /// Whether two handles name the same backing cell.
        pub fn ptrEq(a: Self, b: Self) bool {
            return a.cell == b.cell;
        }

        pub fn strongCount(self: Self) usize {
            return self.cell.refcount.load(.acquire);
        }

        pub fn asPtr(self: Self) *T {
            return &self.cell.data;
        }

        /// Address-stable identity of the backing cell, usable as a key
        /// in a visited set when walking a (possibly cyclic) value
        /// graph. Two `ObjRef`s with this same value share the cell.
        pub fn identity(self: Self) usize {
            return @intFromPtr(&self.cell.data);
        }
    };
}

/// Shared-borrow guard. On the UNSHARED path it restores the `RefCell`
/// borrow count on `deinit`; on the SHARED path it instead holds a read
/// lock for its lifetime and the lock — not `flag` — is the discipline.
pub fn ObjGuard(comptime T: type) type {
    return struct {
        const Self = @This();
        cell: *ControlBlock(T),
        shared: bool,

        /// Borrowed view of the cell's data. Valid until `deinit`.
        pub fn get(self: Self) *const T {
            return &self.cell.data;
        }

        /// Release the shared borrow.
        pub fn deinit(self: Self) void {
            if (self.shared) {
                // SHARED path: release the read lock.
                self.cell.lock.unlockShared();
            } else {
                // UNSHARED path: decrement the RefCell borrow count.
                self.cell.flag -= 1;
            }
        }
    };
}

/// Mutable-borrow guard. On the UNSHARED path it restores the `RefCell`
/// borrow flag on `deinit`; on the SHARED path it instead holds an
/// exclusive write lock for its lifetime.
pub fn ObjGuardMut(comptime T: type) type {
    return struct {
        const Self = @This();
        cell: *ControlBlock(T),
        shared: bool,

        /// Mutable view of the cell's data. Valid until `deinit`.
        pub fn get(self: Self) *T {
            return &self.cell.data;
        }

        /// Release the exclusive borrow.
        pub fn deinit(self: Self) void {
            if (self.shared) {
                // SHARED path: release the write lock.
                self.cell.lock.unlockExclusive();
            } else {
                // UNSHARED path: clear the RefCell borrow flag.
                self.cell.flag = 0;
            }
        }
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "unshared borrow and borrow_mut round-trip" {
    const obj = try ObjRef(i32).init(testing.allocator, 0);
    defer obj.deinit();

    {
        const g = obj.borrowMut();
        defer g.deinit();
        g.get().* = 42;
    }
    {
        const g = obj.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(i32, 42), g.get().*);
    }
    try testing.expect(!obj.isShared());
}

test "try_borrow_mut fails while shared-borrowed (unshared path)" {
    const obj = try ObjRef(i32).init(testing.allocator, 1);
    defer obj.deinit();

    const r = obj.borrow();
    defer r.deinit();
    // A live shared borrow blocks an exclusive borrow.
    try testing.expectError(BorrowMutError.AlreadyBorrowed, obj.tryBorrowMut());
    // Multiple concurrent shared borrows are fine.
    const r2 = obj.tryBorrow();
    try testing.expect(r2 != null);
    r2.?.deinit();
}

test "try_borrow fails while mutably borrowed (unshared path)" {
    const obj = try ObjRef(i32).init(testing.allocator, 1);
    defer obj.deinit();

    const w = obj.borrowMut();
    defer w.deinit();
    try testing.expect(obj.tryBorrow() == null);
    try testing.expectError(BorrowMutError.AlreadyBorrowed, obj.tryBorrowMut());
}

test "clone shares the cell and tracks strong count" {
    const a = try ObjRef(i32).init(testing.allocator, 7);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.strongCount());

    const b = a.clone();
    try testing.expectEqual(@as(usize, 2), a.strongCount());
    try testing.expect(ObjRef(i32).ptrEq(a, b));
    try testing.expectEqual(a.identity(), b.identity());

    {
        const g = b.borrowMut();
        defer g.deinit();
        g.get().* = 99;
    }
    {
        const g = a.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(i32, 99), g.get().*);
    }

    b.deinit();
    try testing.expectEqual(@as(usize, 1), a.strongCount());
}

test "ptr_eq distinguishes distinct cells" {
    const a = try ObjRef(i32).init(testing.allocator, 0);
    defer a.deinit();
    const b = try ObjRef(i32).init(testing.allocator, 0);
    defer b.deinit();
    try testing.expect(!ObjRef(i32).ptrEq(a, b));
    try testing.expect(a.identity() != b.identity());
}

test "publish flips to shared and shared path serializes" {
    const obj = try ObjRef(i32).init(testing.allocator, 5);
    defer obj.deinit();

    obj.publish();
    try testing.expect(obj.isShared());

    // On the shared path, multiple read guards coexist.
    const r1 = obj.borrow();
    const r2 = obj.borrow();
    try testing.expectEqual(@as(i32, 5), r1.get().*);
    try testing.expectEqual(@as(i32, 5), r2.get().*);
    r1.deinit();
    r2.deinit();

    // An exclusive borrow once readers are gone.
    {
        const w = obj.borrowMut();
        defer w.deinit();
        w.get().* = 6;
    }
    {
        const g = obj.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(i32, 6), g.get().*);
    }
}

test "deinit runs T.deinit when the last handle drops" {
    const Counted = struct {
        slot: *usize,
        fn deinit(self: *@This()) void {
            self.slot.* += 1;
        }
    };
    var drops: usize = 0;

    const a = try ObjRef(Counted).init(testing.allocator, .{ .slot = &drops });
    const b = a.clone();
    a.deinit();
    try testing.expectEqual(@as(usize, 0), drops); // still one handle live
    b.deinit();
    try testing.expectEqual(@as(usize, 1), drops); // T.deinit ran exactly once
}

const THREADS: usize = 8;
const PUSHES_PER_THREAD: usize = 2_000;

const IntList = struct {
    items: std.ArrayList(i32) = .empty,
    fn deinit(self: *IntList, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
};

const PushWorker = struct {
    obj: ObjRef(IntList),
    allocator: std.mem.Allocator,
    t: usize,

    fn run(self: PushWorker) void {
        var i: usize = 0;
        while (i < PUSHES_PER_THREAD) : (i += 1) {
            {
                const g = self.obj.borrowMut();
                defer g.deinit();
                g.get().items.append(
                    self.allocator,
                    @intCast(self.t * PUSHES_PER_THREAD + i),
                ) catch unreachable;
            }
            // Interleave shared reads to stress the lock under mixed
            // shared/exclusive contention.
            const r = self.obj.borrow();
            _ = r.get().items.items.len;
            r.deinit();
        }
    }
};

test "shared objref concurrent push is consistent" {
    const allocator = testing.allocator;
    var obj = try ObjRef(IntList).init(allocator, .{});
    defer obj.deinit();
    // Publish before the handle escapes to any other thread.
    obj.publish();
    try testing.expect(obj.isShared());

    var handles: [THREADS]std.Thread = undefined;
    var t: usize = 0;
    while (t < THREADS) : (t += 1) {
        const worker = PushWorker{ .obj = obj.clone(), .allocator = allocator, .t = t };
        handles[t] = try std.Thread.spawn(.{}, PushWorker.run, .{worker});
    }
    // Each worker holds its own clone; release them here, the threads'
    // copies keep the cell alive for the duration.
    t = 0;
    while (t < THREADS) : (t += 1) {
        handles[t].join();
    }
    // The workers' clones are leaked-by-value into the closure; reclaim
    // one decref per spawned worker.
    t = 0;
    while (t < THREADS) : (t += 1) {
        obj.deinit();
    }

    const g = obj.borrow();
    defer g.deinit();
    try testing.expectEqual(THREADS * PUSHES_PER_THREAD, g.get().items.items.len);

    // Every value in [0, THREADS*PUSHES) must appear exactly once.
    var seen = try allocator.alloc(bool, THREADS * PUSHES_PER_THREAD);
    defer allocator.free(seen);
    @memset(seen, false);
    for (g.get().items.items) |v| {
        const idx: usize = @intCast(v);
        try testing.expect(idx < seen.len); // not corrupted
        try testing.expect(!seen[idx]); // not duplicated (no lost/torn write)
        seen[idx] = true;
    }
    for (seen) |b| try testing.expect(b); // no missing elements
}

const CounterWorker = struct {
    obj: ObjRef(i64),
    applied: *std.atomic.Value(usize),

    fn run(self: CounterWorker) void {
        var i: usize = 0;
        while (i < PUSHES_PER_THREAD) : (i += 1) {
            {
                const g = self.obj.borrowMut();
                defer g.deinit();
                g.get().* += 1;
            }
            _ = self.applied.fetchAdd(1, .monotonic);
        }
    }
};

test "shared objref read modify counter" {
    var obj = try ObjRef(i64).init(testing.allocator, 0);
    defer obj.deinit();
    obj.publish();

    var applied = std.atomic.Value(usize).init(0);

    var handles: [THREADS]std.Thread = undefined;
    var t: usize = 0;
    while (t < THREADS) : (t += 1) {
        const worker = CounterWorker{ .obj = obj.clone(), .applied = &applied };
        handles[t] = try std.Thread.spawn(.{}, CounterWorker.run, .{worker});
    }
    t = 0;
    while (t < THREADS) : (t += 1) {
        handles[t].join();
    }
    t = 0;
    while (t < THREADS) : (t += 1) {
        obj.deinit();
    }

    const total: i64 = @intCast(THREADS * PUSHES_PER_THREAD);
    {
        const g = obj.borrow();
        defer g.deinit();
        try testing.expectEqual(total, g.get().*); // no lost increment under lock
    }
    try testing.expectEqual(THREADS * PUSHES_PER_THREAD, applied.load(.monotonic));
}

const HandoffWriter = struct {
    obj_out: *?ObjRef(IntList),
    ready: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    fn run(self: HandoffWriter) void {
        var obj = ObjRef(IntList).init(self.allocator, .{}) catch unreachable;
        {
            const g = obj.borrowMut();
            defer g.deinit();
            var i: i32 = 0;
            while (i < 64) : (i += 1) g.get().items.append(self.allocator, i) catch unreachable;
        }
        obj.publish();
        self.obj_out.* = obj;
        self.ready.store(true, .release);
    }
};

const HandoffReader = struct {
    obj_in: *?ObjRef(IntList),
    ready: *std.atomic.Value(bool),

    fn run(self: HandoffReader) void {
        while (!self.ready.load(.acquire)) std.atomic.spinLoopHint();
        const obj = self.obj_in.*.?;
        const g = obj.borrow();
        defer g.deinit();
        std.debug.assert(g.get().items.items.len == 64);
        for (g.get().items.items, 0..) |v, i| {
            std.debug.assert(v == @as(i32, @intCast(i))); // never a partial pre-publish write
        }
    }
};

test "publish then handoff orders the write" {
    const allocator = testing.allocator;
    const ROUNDS: usize = 50;
    var round: usize = 0;
    while (round < ROUNDS) : (round += 1) {
        var slot: ?ObjRef(IntList) = null;
        var ready = std.atomic.Value(bool).init(false);

        const writer = try std.Thread.spawn(.{}, HandoffWriter.run, .{HandoffWriter{
            .obj_out = &slot,
            .ready = &ready,
            .allocator = allocator,
        }});
        const reader = try std.Thread.spawn(.{}, HandoffReader.run, .{HandoffReader{
            .obj_in = &slot,
            .ready = &ready,
        }});
        writer.join();
        reader.join();

        slot.?.deinit();
    }
}
