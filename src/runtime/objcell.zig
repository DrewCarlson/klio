//! Reference-counted, interior-mutable cell behind `ObjRef`.
//!
//! `ObjRef(T)` is the handle to a shared, interior-mutable Kotlin heap
//! object. The backing is a heap-allocated control block holding an
//! atomic strong count (so handles are safe to share across threads)
//! and a per-cell reader/writer lock that mediates every borrow.
//!
//! Every `borrow` takes a shared (reader) lock; every `borrowMut` takes
//! an exclusive (writer) lock. Any number of concurrent shared borrows
//! proceed together; an exclusive borrow is exclusive against all
//! readers and writers. The lock's acquire/release ordering is the
//! happens-before edge that makes cross-thread access sound, so a
//! reference can escape to another thread with no separate publication
//! step.
//!
//! Single-threaded execution never takes an overlapping *conflicting*
//! borrow on one cell (a `borrowMut` while a borrow on the same cell is
//! live, or vice versa): the interpreter and stdlib copy out of a borrow
//! before running any user code, so the reader/writer lock is always
//! uncontended on the single-thread path — an uncontended `cmpxchg`,
//! the same fast path a `RefCell` borrow flag would take.
//!
//! Synchronization choice: Zig 0.16's std has no blocking
//! `Thread.Mutex`/`RwLock` (those moved behind the `Io` interface), so
//! the reader/writer lock here is a small spin lock built on
//! `std.atomic.Value` with a `spinLoopHint`/`Thread.yield` backoff. It
//! provides the discipline the model needs: many concurrent shared
//! readers, one exclusive writer, with acquire/release ordering.
//!
//! Allocator convention: an `ObjRef` owns a heap-allocated control
//! block. The allocator used to create it is stored *inside* the
//! control block, so `clone`, `deinit`, `borrow`, etc. need no
//! allocator argument — only `init` does. `deinit` decrements the
//! strong count and frees the block (running `T`'s `deinit` if it has
//! one) when the count reaches zero.

const std = @import("std");

/// Per-thread teardown mode for `ObjRef.deinit`.
///
/// `true` (the default) runs the full Arc/Drop path: the atomic refcount
/// decrement, `T.deinit`, and `allocator.destroy(cell)`. This is the only
/// mode the leak-checking unit tests and the real-thread objcell/objref
/// stress tests ever run under, so they keep exercising the full
/// refcount/free path that catches use-after-free and leaks.
///
/// `false` is the arena fast path: `ObjRef.deinit` returns immediately
/// without touching the refcount, the payload `T.deinit`, or the destroy,
/// because the backing arena frees every cell en masse on reset. It is
/// opt-in by the arena-backed run configs (the `klio` binary's run path,
/// the e2e/parity/differential harnesses) for the duration of one program
/// and restored afterward. It must NEVER be set on a thread that runs on a
/// leak-checking `testing.allocator`, or a UAF/leak would be masked.
///
/// Threadlocal so a spawned worker inherits the spawning run's mode the
/// same way the coroutine time mode does: the worker explicitly carries
/// the flag through the spawn seed and sets it on entry.
threadlocal var reclaim_tls: bool = true;

/// Set the current thread's `ObjRef.deinit` teardown mode. `true` = full
/// refcount/destroy/`T.deinit` path; `false` = arena fast path (skip
/// per-cell teardown, the arena reclaims). Defaults to `true`.
pub fn setReclaim(on: bool) void {
    reclaim_tls = on;
}

/// Whether the current thread runs `ObjRef.deinit`'s full teardown path.
pub fn reclaimEnabled() bool {
    return reclaim_tls;
}

/// Whether the process was asked to run the freeing reference-counting path
/// (a real allocator + reclaim-ON) instead of the arena fast path, via the
/// `KLIO_RECLAIM` environment variable (`1`/`smp`/`debug` = on; unset/`0` =
/// off). The run path consults this to decide whether to disable reclaim; the
/// process entry point consults it to pick the backing allocator. Cached so
/// repeated checks across the run are cheap and consistent.
var reclaim_req_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0); // 0 unknown, 1 off, 2 on

/// libc `getenv` wrapper returning a borrowed slice. Returns null in a build
/// without libc (module test binaries) — those never set the env anyway.
pub fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    if (comptime !@import("builtin").link_libc) return null;
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// Diagnostic: when `KLIO_RC_DETECT` is set, `ObjRef.deinit` leaks freed cells
/// and dumps a stack trace on a second decrement (a double-free). Off by
/// default; only used to pinpoint reclamation double-frees during the host
/// reconciliation.
var detect_df_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
fn detectDoubleFree() bool {
    switch (detect_df_state.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const on = blk: {
        const v = getenvSlice("KLIO_RC_DETECT") orelse break :blk false;
        break :blk v.len != 0 and !std.mem.eql(u8, v, "0");
    };
    detect_df_state.store(if (on) 2 else 1, .monotonic);
    return on;
}

pub fn reclaimRequested() bool {
    switch (reclaim_req_state.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const on = blk: {
        const v = getenvSlice("KLIO_RECLAIM") orelse break :blk false;
        // `free` selects a freeing allocator (see `main.zig`) while leaving
        // the refcount reclamation path OFF: it reclaims the host scratch and
        // container temporaries the run path explicitly frees, without
        // activating `ObjRef.deinit`'s value-graph teardown (not yet
        // reconciled on the coroutine/ktor host path).
        if (std.mem.eql(u8, v, "free")) break :blk false;
        break :blk v.len != 0 and !std.mem.eql(u8, v, "0");
    };
    reclaim_req_state.store(if (on) 2 else 1, .monotonic);
    return on;
}

/// Which backing allocator the process entry point should install. Distinct
/// from `reclaimRequested` because `free` mode wants a freeing allocator with
/// reclaim OFF.
pub const AllocChoice = enum { arena, smp, debug };
pub fn allocChoice() AllocChoice {
    const v = getenvSlice("KLIO_RECLAIM") orelse return .arena;
    if (v.len == 0 or std.mem.eql(u8, v, "0")) return .arena;
    if (std.mem.eql(u8, v, "debug")) return .debug;
    return .smp; // "free", "smp", "1", or any other non-zero value
}

/// Reader/writer spin lock. `state` encodes the lock as `RefCell` does
/// its flag: `0` free, `n > 0` n active readers, `WRITER` (the sign bit)
/// exclusive writer. Many readers proceed concurrently; a writer is
/// exclusive against all readers and writers.
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

/// True when `name=<non-empty,!=0>` appears in `/proc/self/environ`.
/// Allocation-free: streams the procfs file through a stack buffer. Zig
/// 0.16's std env API moved behind `Io`; this is the no-`Io` reader the
/// diagnostic path can use safely.
fn procEnvironHas(comptime name: []const u8) bool {
    if (@import("builtin").os.tag != .linux) return false;
    const fd = std.os.linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return false;
    const ifd: i32 = @intCast(fd);
    defer _ = std.os.linux.close(ifd);
    var buf: [16384]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const rc = std.os.linux.read(ifd, buf[len..].ptr, buf.len - len);
        const e = std.os.linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) break;
        if (rc == 0) break;
        len += rc;
    }
    var it = std.mem.splitScalar(u8, buf[0..len], 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            const val = entry[eq + 1 ..];
            return val.len != 0 and !std.mem.eql(u8, val, "0");
        }
    }
    return false;
}

/// `KLIO_RACE_JITTER`-gated interleaving widener. Inserted into the
/// borrow lock-acquisition window so a genuine cross-thread borrow race
/// reproduces reliably under test instead of only on a rare
/// interleaving. Off (zero cost beyond the cached branch) unless the env
/// var is set. Diagnostic-only; never enabled in the shipped suite.
var race_jitter_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0); // 0 unknown, 1 off, 2 on

fn raceJitterEnabled() bool {
    switch (race_jitter_state.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const on = procEnvironHas("KLIO_RACE_JITTER");
    race_jitter_state.store(if (on) 2 else 1, .monotonic);
    return on;
}

inline fn raceJitter() void {
    if (!raceJitterEnabled()) return;
    var i: usize = 0;
    while (i < 64) : (i += 1) std.atomic.spinLoopHint();
    std.Thread.yield() catch {};
}

/// Heap-allocated control block for one `ObjRef`: an atomic strong
/// count, the per-cell reader/writer `lock`, the data, and the owning
/// allocator.
pub fn ControlBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        refcount: std.atomic.Value(usize),
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

        /// Whether this cell's payload is a `[]const u8` the cell owns and
        /// must free on teardown. Only the string-bytes payload qualifies;
        /// every other `ObjRef` payload is freed by its own `deinit` or is a
        /// borrow.
        const owns_bytes = (T == []const u8);

        /// Allocate a new cell holding `v`. The allocator is retained
        /// inside the control block and reused for `deinit`.
        ///
        /// For a `[]const u8` payload under the reclaim path, the bytes are
        /// **duped** so the cell owns a private copy it can free on teardown:
        /// `StringRef` byte ownership is otherwise ambiguous (some callers pass
        /// interned/borrowed module-const bytes, others owned buffers), and a
        /// uniform owned copy makes `release` able to free without corrupting a
        /// borrowed original. Under the arena fast path (`!reclaim_tls`) the
        /// slice is stored as-is — the arena reclaims everything wholesale, so
        /// the dupe would be wasted. Owned-buffer callers that want to transfer
        /// their buffer instead of paying a second allocation use `initOwned`.
        pub fn init(allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!Self {
            var data = v;
            if (comptime owns_bytes) {
                if (reclaim_tls) data = try allocator.dupe(u8, v);
            }
            return initOwned(allocator, data);
        }

        /// Like `init`, but takes ownership of `v` verbatim with no dupe.
        /// For a `[]const u8` payload this means the cell adopts the caller's
        /// buffer (and will free it on teardown under the reclaim path); the
        /// caller must not free it afterward. Identical to `init` for every
        /// non-bytes payload.
        pub fn initOwned(allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!Self {
            const cell = try allocator.create(Cell);
            cell.* = .{
                .refcount = std.atomic.Value(usize).init(1),
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
        ///
        /// Under the arena fast path (`reclaimEnabled() == false`) this
        /// returns immediately without the atomic decrement, the payload
        /// `T.deinit`, or the destroy: the backing arena reclaims every
        /// cell wholesale on reset, so the per-cell teardown is wasted
        /// work. The default is the full path, so the leak-checking and
        /// real-thread stress configs (which never disable reclaim) keep
        /// the refcount/free discipline that catches UAF/leaks.
        pub fn deinit(self: Self) void {
            if (!reclaim_tls) return;
            const prev = self.cell.refcount.fetchSub(1, .release);
            if (detectDoubleFree()) {
                // Diagnostic mode: never destroy the cell (leak it) so a second
                // decrement is observable. A `prev` of 0 means we just dropped a
                // cell whose count was already zero — a double-free; dump the
                // offending stack.
                if (prev == 0 or prev > (1 << 40)) {
                    std.debug.print("\n[RC DOUBLE-FREE] cell={*} payload={s}\n", .{ self.cell, @typeName(T) });
                    std.debug.dumpCurrentStackTrace(.{});
                }
                if (prev == 1) {
                    const allocator = self.cell.allocator;
                    if (comptime owns_bytes) {
                        allocator.free(self.cell.data);
                    } else if (comptime hasDeinit(T)) {
                        deinitData(&self.cell.data, allocator);
                    }
                    // leak the control block (do not destroy) to keep count==0 observable
                }
                return;
            }
            if (prev == 1) {
                // Acquire-load pairs with the release decrements of the
                // other handles so all their writes happen-before this
                // free (Arc's drop ordering).
                _ = self.cell.refcount.load(.acquire);
                const allocator = self.cell.allocator;
                if (comptime owns_bytes) {
                    // The cell owns its string bytes (see `init`); free them.
                    allocator.free(self.cell.data);
                } else if (comptime hasDeinit(T)) {
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

        /// Shared borrow, like `RefCell::borrow`: takes the reader lock.
        pub fn borrow(self: Self) ObjGuard(T) {
            return self.tryBorrow() orelse unreachable;
        }

        /// Mutable borrow, like `RefCell::borrow_mut`: takes the writer
        /// lock.
        pub fn borrowMut(self: Self) ObjGuardMut(T) {
            return self.tryBorrowMut() catch unreachable;
        }

        /// Shared borrow: take the reader lock. Many concurrent shared
        /// borrows proceed together; an exclusive borrow blocks until
        /// they drain. Always succeeds (never returns null) — the
        /// optional return is kept for source compatibility.
        pub fn tryBorrow(self: Self) ?ObjGuard(T) {
            const cell = self.cell;
            raceJitter();
            cell.lock.lockShared();
            return .{ .cell = cell };
        }

        /// Mutable borrow: take the writer lock — exclusive against every
        /// reader and writer. Blocks until any live borrows drain rather
        /// than failing. Always succeeds (never returns the error) — the
        /// error union is kept for source compatibility.
        pub fn tryBorrowMut(self: Self) BorrowMutError!ObjGuardMut(T) {
            const cell = self.cell;
            raceJitter();
            cell.lock.lockExclusive();
            return .{ .cell = cell };
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

/// Shared-borrow guard. Holds the reader lock for its lifetime and
/// releases it on `deinit`.
pub fn ObjGuard(comptime T: type) type {
    return struct {
        const Self = @This();
        cell: *ControlBlock(T),

        /// Borrowed view of the cell's data. Valid until `deinit`.
        pub fn get(self: Self) *const T {
            return &self.cell.data;
        }

        /// Release the shared (reader) lock.
        pub fn deinit(self: Self) void {
            self.cell.lock.unlockShared();
        }
    };
}

/// Mutable-borrow guard. Holds the exclusive (writer) lock for its
/// lifetime and releases it on `deinit`.
pub fn ObjGuardMut(comptime T: type) type {
    return struct {
        const Self = @This();
        cell: *ControlBlock(T),

        /// Mutable view of the cell's data. Valid until `deinit`.
        pub fn get(self: Self) *T {
            return &self.cell.data;
        }

        /// Release the exclusive (writer) lock.
        pub fn deinit(self: Self) void {
            self.cell.lock.unlockExclusive();
        }
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "borrow and borrow_mut round-trip" {
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
}

test "concurrent shared borrows coexist on one cell" {
    const obj = try ObjRef(i32).init(testing.allocator, 7);
    defer obj.deinit();

    // Many readers proceed together (reader count climbs).
    const r1 = obj.borrow();
    const r2 = obj.borrow();
    const r3 = obj.borrow();
    try testing.expectEqual(@as(i32, 7), r1.get().*);
    try testing.expectEqual(@as(i32, 7), r3.get().*);
    r1.deinit();
    r2.deinit();
    r3.deinit();

    // Once readers drain, an exclusive borrow proceeds.
    {
        const w = obj.borrowMut();
        defer w.deinit();
        w.get().* = 8;
    }
    {
        const g = obj.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(i32, 8), g.get().*);
    }
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
    // The per-cell lock mediates every cross-thread borrow; no publish
    // step is needed before the handle escapes to other threads.

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
            std.debug.assert(v == @as(i32, @intCast(i))); // never a partial write
        }
    }
};

test "handoff orders the write across threads" {
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
