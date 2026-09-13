//! Reference-counted, interior-mutable cell behind `ObjRef`.
//!
//! `ObjRef(T)` is the handle to a shared Kotlin heap object, backed by a heap
//! control block with an atomic strong count and a per-cell reader/writer lock
//! whose acquire/release ordering is the happens-before edge that makes
//! cross-thread access sound, so a reference can escape to another thread with
//! no separate publication step. Single-threaded execution never takes two
//! conflicting borrows on one cell, since the interpreter and stdlib copy out
//! of a borrow before running user code.
//!
//! The allocator that created a control block is stored inside it, so only
//! `init` takes one.

const std = @import("std");
const trace = @import("trace.zig");
pub const gc = @import("gc.zig");

/// Teardown mode for `ObjRef.deinit`. `true`, the default, runs the atomic
/// decrement, `T.deinit` and `allocator.destroy(cell)`; it must never be false
/// on a thread running on a leak-checking `testing.allocator`. `false` is the
/// arena fast path, where `deinit` returns without touching the refcount, the
/// payload or the destroy, because the arena frees every cell on reset.
///
/// Process-wide rather than per-thread, since `reclaimEnabled()` is read on
/// nearly every register write. Monotonic suffices: the value changes only at
/// run boundaries, with no interpreter thread in flight.
var reclaim_shared: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

pub fn setReclaim(on: bool) void {
    reclaim_shared.store(on, .monotonic);
}

pub fn reclaimEnabled() bool {
    return reclaim_shared.load(.monotonic);
}

/// Whether raw host temporaries, allocations that are not cells, must be freed
/// explicitly. True whenever the backing allocator actually frees: the
/// reference-counting modes, and the tracing GC, under which refcount teardown
/// is off but raw scratch is invisible to the collector. Deliberately distinct
/// from `reclaimEnabled()`, which must stay off under the GC.
pub fn freeScratch() bool {
    return reclaim_shared.load(.monotonic) or gc.gc_enabled;
}

/// Whether `KLIO_RECLAIM` asked for the freeing reference-counting path rather
/// than the arena; also selects the backing allocator at the entry point.
var reclaim_req_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0); // 0 unknown, 1 off, 2 on

/// Null in a build without libc. Memoized, because the trace gates consult it
/// on hot paths while `getenv` takes a process-wide lock per call, and the
/// process env never changes mid-run.
var env_cache_mutex: SpinMutex = .{};
var env_cache: ?std.StringHashMap(?[]const u8) = null;

pub fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    if (comptime !@import("builtin").link_libc) return null;
    const key = std.mem.span(name);
    env_cache_mutex.lock();
    defer env_cache_mutex.unlock();
    if (env_cache == null) env_cache = std.StringHashMap(?[]const u8).init(std.heap.page_allocator);
    if (env_cache.?.get(key)) |cached| return cached;
    const value: ?[]const u8 = if (std.c.getenv(name)) |raw| std.mem.span(raw) else null;
    const stable_key = std.heap.page_allocator.dupe(u8, key) catch return value;
    env_cache.?.put(stable_key, value) catch {};
    return value;
}

/// One variable's slot. A `struct` declared inside `envOnce` would not be
/// per-name: a comptime pointer parameter does not re-instantiate the body, so
/// every call site would share one static. Keying a type on the name does.
fn EnvSlot(comptime name: [:0]const u8) type {
    return struct {
        const key: [:0]const u8 = name;
        var state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
        var value: ?[]const u8 = null;
    };
}

/// Answered from a per-name static after the first ask, since `getenvSlice`
/// hashes the name under a mutex on every call.
pub fn envOnce(comptime name: [:0]const u8) ?[]const u8 {
    const S = EnvSlot(name);
    if (S.state.load(.acquire) == 0) {
        S.value = getenvSlice(S.key.ptr);
        S.state.store(1, .release);
    }
    return S.value;
}

pub fn envSetOnce(comptime name: [:0]const u8) bool {
    return envOnce(name) != null;
}

test "envOnce answers per variable, not per first read" {
    try std.testing.expect(envOnce("KLIO_ENVONCE_SELFTEST_A") == null);
    try std.testing.expect(envOnce("KLIO_ENVONCE_SELFTEST_B") == null);
    try std.testing.expect(EnvSlot("KLIO_ENVONCE_SELFTEST_A") != EnvSlot("KLIO_ENVONCE_SELFTEST_B"));
}

/// `KLIO_RC_DETECT`: leak freed cells and dump a stack trace on a second
/// decrement, pinpointing a double-free.
var detect_df_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
fn detectDoubleFree() bool {
    switch (detect_df_state.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const on = blk: {
        const v = envOnce("KLIO_RC_DETECT") orelse break :blk false;
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
        // Unset is the tracing GC, which reclaims by reachability.
        const v = envOnce("KLIO_RECLAIM") orelse break :blk false;
        // `free` selects a freeing allocator while leaving refcount reclamation
        // off, so it reclaims only the scratch the run path frees explicitly.
        // `arena`, `0` and `gc` also leave it off.
        if (std.mem.eql(u8, v, "free") or std.mem.eql(u8, v, "arena") or std.mem.eql(u8, v, "gc")) break :blk false;
        break :blk v.len != 0 and !std.mem.eql(u8, v, "0");
    };
    reclaim_req_state.store(if (on) 2 else 1, .monotonic);
    return on;
}

/// Many readers proceed concurrently; a writer is exclusive against all.
const SpinRwLock = struct {
    /// `0` free, positive the reader count, `WRITER` (the sign bit) exclusive.
    state: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    const WRITER: i32 = std.math.minInt(i32);

    fn lockShared(self: *SpinRwLock) void {
        // One wait-free `fetchAdd`, so concurrent readers never fail each other
        // where a compare-exchange loop would storm. Only an active writer, a
        // negative state, forces the undo-and-spin.
        const prev = self.state.fetchAdd(1, .acquire);
        if (prev >= 0) return;
        _ = self.state.fetchSub(1, .monotonic);
        var b: Backoff = .{};
        while (true) {
            b.pause();
            const s = self.state.load(.monotonic);
            if (s >= 0) {
                const again = self.state.fetchAdd(1, .acquire);
                if (again >= 0) return;
                _ = self.state.fetchSub(1, .monotonic);
            }
        }
    }

    fn unlockShared(self: *SpinRwLock) void {
        _ = self.state.fetchSub(1, .release);
    }

    fn lockExclusive(self: *SpinRwLock) void {
        var b: Backoff = .{};
        while (true) {
            if (self.state.load(.monotonic) == 0 and
                self.state.cmpxchgWeak(0, WRITER, .acquire, .monotonic) == null)
            {
                return;
            }
            b.pause();
        }
    }

    fn unlockExclusive(self: *SpinRwLock) void {
        // Entering readers may have bumped the state past `WRITER` before
        // undoing their `fetchAdd`, so a blind zero store would erase a bump
        // whose undo is still pending. Clear only the writer bit: the transient
        // reader count rides in the low bits.
        _ = self.state.fetchAnd(std.math.maxInt(i32), .release);
    }

    /// Guarded sections are short, so early retries spin on cheap hints.
    const Backoff = struct {
        n: u32 = 0,
        inline fn pause(self: *Backoff) void {
            self.n +%= 1;
            if (self.n < 16) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    };
};

/// A stand-in for `SpinRwLock` for a payload immutable for its whole lifetime,
/// opting in with `pub const objref_immutable = true`. Nothing ever takes an
/// exclusive borrow of such a cell, so every operation here is a no-op.
const NoopRwLock = struct {
    inline fn lockShared(_: *NoopRwLock) void {}
    inline fn unlockShared(_: *NoopRwLock) void {}
    inline fn lockExclusive(_: *NoopRwLock) void {}
    inline fn unlockExclusive(_: *NoopRwLock) void {}
};

/// The no-op lock when `T` declares itself immutable, else the spin lock.
fn LockFor(comptime T: type) type {
    return if (isContainer(T) and @hasDecl(T, "objref_immutable") and T.objref_immutable) NoopRwLock else SpinRwLock;
}

/// Exclusive spin lock, since Zig 0.16's std has no blocking `Thread.Mutex`.
/// The one shared mutex definition the rest of the interpreter imports.
pub const SpinMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinMutex) void {
        var b: SpinRwLock.Backoff = .{};
        // Test-and-test-and-set: spin on a plain load while the lock is held,
        // so waiters share the cache line instead of ping-ponging it.
        while (true) {
            if (!self.locked.load(.monotonic)) {
                if (!self.locked.swap(true, .acquire)) return;
            }
            b.pause();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

/// A value that is neither empty nor `0` counts as set. Allocation-free, so the
/// diagnostic path needs no `Io`.
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
        const eq = std.mem.findScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            const val = entry[eq + 1 ..];
            return val.len != 0 and !std.mem.eql(u8, val, "0");
        }
    }
    return false;
}

/// `KLIO_RACE_JITTER`: widen the borrow lock-acquisition window so a genuine
/// cross-thread borrow race reproduces reliably under test.
var race_jitter_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0); // 0 unknown, 1 off, 2 on

/// Kept out of `raceJitterEnabled`: Zig does not reclaim block-scoped stack
/// allocations (ziglang/zig#23475), so `procEnvironHas`'s 16 KB read buffer
/// would sit in the caller's prologue on every call.
noinline fn raceJitterProbe() bool {
    const on = procEnvironHas("KLIO_RACE_JITTER");
    race_jitter_state.store(if (on) 2 else 1, .monotonic);
    return on;
}

fn raceJitterEnabled() bool {
    switch (race_jitter_state.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    return raceJitterProbe();
}

inline fn raceJitter() void {
    if (!raceJitterEnabled()) return;
    var i: usize = 0;
    while (i < 64) : (i += 1) std.atomic.spinLoopHint();
    std.Thread.yield() catch {};
}

pub fn ControlBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        /// First, so the type-erased collector recovers `data` at a fixed
        /// offset through `@fieldParentPtr`. 16-byte aligned so a `Value`
        /// payload can tag a cell pointer in its low four bits.
        hdr: gc.GcHeader align(16),
        refcount: std.atomic.Value(usize),
        lock: LockFor(T),
        data: T,
        allocator: std.mem.Allocator,
    };
}

// GC trace and finalize dispatch, duck-typed so `objcell` depends on neither
// `value` nor `class` nor `env`. A payload `T` declares how the collector walks
// its out-edges and tears down its own buffers:
//   - `gcMark(self, *gc.Marker)`: a Value, shading its child cells
//   - `gcTrace(self: *const T, *gc.Marker)`: a struct holding Values
//   - `gcFinalize(self: *T, Allocator)`: shallow teardown of its own buffers
// std payloads are handled structurally; anything else with Value out-edges and
// none of these traces as a leaf, which the verify oracle catches.

fn isContainer(comptime U: type) bool {
    return switch (@typeInfo(U)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}
fn hasDeclSafe(comptime U: type, comptime name: []const u8) bool {
    return isContainer(U) and @hasDecl(U, name);
}
fn isArrayListLike(comptime U: type) bool {
    return @typeInfo(U) == .@"struct" and @hasField(U, "items") and @hasField(U, "capacity");
}
fn isHashMapLike(comptime U: type) bool {
    return @typeInfo(U) == .@"struct" and @hasDecl(U, "valueIterator") and @hasDecl(U, "count");
}
fn isSlice(comptime U: type) bool {
    return @typeInfo(U) == .pointer and @typeInfo(U).pointer.size == .slice;
}

/// The collection trigger must count these, or a cell with a small control
/// block over a large backing would not advance the threshold.
fn externalBytes(comptime U: type, data: *const U) usize {
    if (comptime U == []const u8) return data.len;
    if (comptime hasDeclSafe(U, "gcExternalBytes")) return data.gcExternalBytes();
    if (comptime isArrayListLike(U)) {
        const Elem = @typeInfo(@TypeOf(data.items)).pointer.child;
        return data.capacity * @sizeOf(Elem);
    }
    if (comptime isSlice(U)) return data.len * @sizeOf(@typeInfo(U).pointer.child);
    return 0;
}
fn isObjRef(comptime U: type) bool {
    return @typeInfo(U) == .@"struct" and @hasField(U, "cell") and @hasDecl(U, "clone");
}

/// Mirrors `gcTraceData`'s dispatch: if the tracer would walk nothing, a store
/// cannot create a cell edge and mutable access needs no write barrier. A
/// payload with a no-op `gcTrace` opts out with `gc_pointer_free = true`.
fn mayHoldRefs(comptime U: type) bool {
    if (comptime hasDeclSafe(U, "gc_pointer_free")) return false;
    if (comptime hasDeclSafe(U, "gcTrace")) return true;
    if (comptime hasDeclSafe(U, "gcMark")) return true;
    if (comptime isObjRef(U)) return true;
    if (comptime @typeInfo(U) == .optional) return mayHoldRefs(@typeInfo(U).optional.child);
    if (comptime isArrayListLike(U)) return mayHoldRefs(@typeInfo(@FieldType(U, "items")).pointer.child);
    if (comptime isSlice(U)) return mayHoldRefs(@typeInfo(U).pointer.child);
    if (comptime isHashMapLike(U)) return true; // value type not recoverable generically; conservative
    return false;
}

/// Shading a cell is how the graph advances; its own `gc_trace` does the next
/// level.
fn gcTraceElem(comptime E: type, e: *const E, m: *gc.Marker) void {
    if (comptime hasDeclSafe(E, "gcMark")) {
        e.gcMark(m);
    } else if (comptime hasDeclSafe(E, "gcTrace")) {
        e.gcTrace(m);
    } else if (comptime isObjRef(E)) {
        m.shade(&e.cell.hdr);
    } else if (comptime @typeInfo(E) == .optional) {
        if (e.*) |inner| gcTraceElem(@TypeOf(inner), &inner, m);
    }
}

fn gcTraceData(comptime U: type, data: *const U, m: *gc.Marker) void {
    if (comptime hasDeclSafe(U, "gcTrace")) {
        data.gcTrace(m);
    } else if (comptime hasDeclSafe(U, "gcMark")) {
        data.gcMark(m);
    } else if (comptime isObjRef(U)) {
        m.shade(&data.cell.hdr);
    } else if (comptime @typeInfo(U) == .optional) {
        if (data.*) |inner| gcTraceElem(@TypeOf(inner), &inner, m);
    } else if (comptime isArrayListLike(U)) {
        for (data.items) |*e| gcTraceElem(@TypeOf(e.*), e, m);
    } else if (comptime isSlice(U)) {
        for (data.*) |*e| gcTraceElem(@TypeOf(e.*), e, m);
    } else if (comptime isHashMapLike(U)) {
        var it = data.valueIterator();
        while (it.next()) |v| gcTraceElem(@TypeOf(v.*), v, m);
    }
}

fn gcFinalizeData(comptime U: type, data: *U, a: std.mem.Allocator) void {
    if (comptime hasDeclSafe(U, "gcFinalize")) {
        data.gcFinalize(a);
    } else if (comptime U == []const u8) {
        a.free(data.*);
    } else if (comptime isArrayListLike(U)) {
        data.deinit(a);
    } else if (comptime isSlice(U)) {
        a.free(data.*);
    } else if (comptime isHashMapLike(U)) {
        data.deinit();
    }
}

pub const BorrowMutError = error{AlreadyBorrowed};

/// A nullable `ObjRef(T)` the size of a pointer. `?ObjRef(T)` is not: Zig's
/// null-pointer optimization applies to a bare `?*T`, not to an optional of a
/// single-pointer struct, which carries a tag word and costs 16 bytes.
pub fn OptRef(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Ref = ObjRef(T);

        cell: ?*Ref.Cell = null,

        pub inline fn from(r: ?Ref) Self {
            return .{ .cell = if (r) |x| x.cell else null };
        }

        pub inline fn get(self: Self) ?Ref {
            return if (self.cell) |c| Ref{ .cell = c } else null;
        }

        pub inline fn isSome(self: Self) bool {
            return self.cell != null;
        }
    };
}

/// Handle to a shared, interior-mutable Kotlin heap object. Copying the struct
/// without `clone` does not bump the strong count, so copy only where you also
/// `deinit` exactly once per logical owner.
pub fn ObjRef(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Cell = ControlBlock(T);

        cell: *Cell,

        /// The cell owns and frees a `[]const u8` payload; every other payload
        /// is freed by its own `deinit`.
        const owns_bytes = (T == []const u8);

        /// Allocate a cell holding `v`; the allocator is kept inside it. A
        /// `[]const u8` payload is duped under the reclaim path so the cell owns
        /// a private copy it can free, since callers pass a mix of borrowed
        /// module-const bytes and owned buffers. A caller transferring its own
        /// buffer uses `initOwned`.
        pub fn init(allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!Self {
            var data = v;
            if (comptime owns_bytes) {
                if (reclaim_shared.load(.monotonic) or gc.gc_enabled) data = try allocator.dupe(u8, v);
            }
            return initOwned(allocator, data);
        }

        fn gcTraceThunk(h: *gc.GcHeader, m: *gc.Marker) void {
            // Every cell is 16-byte aligned, so recovering the block from its
            // header re-establishes that alignment.
            const cb: *Cell = @fieldParentPtr("hdr", @as(*align(16) gc.GcHeader, @alignCast(h)));
            gcTraceData(T, &cb.data, m);
        }
        /// Shallow: child cells are swept independently.
        fn gcFinalizeThunk(h: *gc.GcHeader) void {
            const cb: *Cell = @fieldParentPtr("hdr", @as(*align(16) gc.GcHeader, @alignCast(h)));
            if (h.gc_remembered and getenvSlice("KLIO_GC_REMEMBER_TRACE") != null) {
                std.debug.print("[gc-freed-remembered] SWEEP h={*} type={s}\n", .{ h, h.gc_type });
                trace.dumpCurrent(.{});
            }
            if (gc.gc_poison) {
                // Quarantine instead of freeing: keep the memory mapped,
                // scribble the payload and arm the trap, so a later live
                // reference is caught with this cell's type. Leaks by design.
                @memset(std.mem.asBytes(&cb.data), 0xDD);
                h.gc_trace = gc.poisonTrap;
                h.gc_mark = 0;
                return;
            }
            gcFinalizeData(T, &cb.data, cb.allocator);
            cb.allocator.destroy(cb);
        }

        /// Free the cell now, whatever the refcount gating or memory mode, for a
        /// hand-managed process-global cache swapping its owner. The caller
        /// asserts no live handle dereferences it afterwards, and the cell must
        /// not be on the sweep registry, so mint it under `alloc_perm`.
        pub fn destroyImmediately(self: Self) void {
            if (gc.gc_enabled) gc.forgetCell(&self.cell.hdr);
            const allocator = self.cell.allocator;
            if (comptime owns_bytes) {
                allocator.free(self.cell.data);
            } else if (comptime hasDeinit(T)) {
                deinitData(&self.cell.data, allocator);
            }
            allocator.destroy(self.cell);
        }

        /// `init` without the dupe: the cell adopts `v` verbatim, so it takes a
        /// `[]const u8` caller's buffer and frees it under the reclaim path.
        pub fn initOwned(allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!Self {
            const cell = try allocator.create(Cell);
            cell.* = .{
                .hdr = .{ .gc_trace = gcTraceThunk, .gc_finalize = gcFinalizeThunk, .gc_type = @typeName(T) },
                .refcount = std.atomic.Value(usize).init(1),
                .lock = .{},
                .data = v,
                .allocator = allocator,
            };
            if (gc.gc_enabled) gc.register(&cell.hdr, @sizeOf(Cell) + externalBytes(T, &cell.data));
            return .{ .cell = cell };
        }

        /// Gated exactly like `deinit`: under the arena and the tracing GC
        /// neither side of the count runs.
        pub fn clone(self: Self) Self {
            if (reclaim_shared.load(.monotonic)) _ = self.cell.refcount.fetchAdd(1, .monotonic);
            return .{ .cell = self.cell };
        }

        /// Decrement the strong count and, at zero, run `T.deinit` if present
        /// and free the control block. Under the arena fast path this returns
        /// immediately, since the arena reclaims every cell on reset.
        pub fn deinit(self: Self) void {
            if (!reclaim_shared.load(.monotonic)) return;
            const prev = self.cell.refcount.fetchSub(1, .release);
            if (detectDoubleFree()) {
                // Never destroy here, so a second decrement stays observable:
                // `prev == 0` means a double-free.
                if (prev == 0 or prev > (1 << 40)) {
                    std.debug.print("\n[RC DOUBLE-FREE] cell={*} payload={s}\n", .{ self.cell, @typeName(T) });
                    trace.dumpCurrent(.{});
                }
                if (prev == 1) {
                    const allocator = self.cell.allocator;
                    if (comptime owns_bytes) {
                        allocator.free(self.cell.data);
                    } else if (comptime hasDeinit(T)) {
                        deinitData(&self.cell.data, allocator);
                    }
                    // Leak the control block, keeping count == 0 observable.
                }
                return;
            }
            if (prev == 1) {
                // This acquire load pairs with the other handles' release
                // decrements, so their writes happen-before this free.
                _ = self.cell.refcount.load(.acquire);
                if (self.cell.hdr.gc_remembered and getenvSlice("KLIO_GC_REMEMBER_TRACE") != null) {
                    std.debug.print("[gc-freed-remembered] RC h={*} type={s}\n", .{ &self.cell.hdr, @typeName(T) });
                    trace.dumpCurrent(.{});
                }
                const allocator = self.cell.allocator;
                if (comptime owns_bytes) {
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
            if (info.params.len >= 2) {
                data.deinit(allocator);
            } else {
                data.deinit();
            }
        }

        pub fn borrow(self: Self) ObjGuard(T) {
            return self.tryBorrow() orelse unreachable;
        }

        pub fn borrowMut(self: Self) ObjGuardMut(T) {
            return self.tryBorrowMut() catch unreachable;
        }

        /// Concurrent shared borrows proceed together and an exclusive borrow
        /// blocks until they drain. Never returns null; the optional is kept
        /// for source compatibility.
        pub fn tryBorrow(self: Self) ?ObjGuard(T) {
            const cell = self.cell;
            raceJitter();
            cell.lock.lockShared();
            return .{ .cell = cell };
        }

        /// Exclusive against every reader and writer, blocking rather than
        /// failing. Never returns the error.
        pub fn tryBorrowMut(self: Self) BorrowMutError!ObjGuardMut(T) {
            const cell = self.cell;
            raceJitter();
            cell.lock.lockExclusive();
            // Generational write barrier: a mutable borrow of a tenured cell
            // may store a nursery reference into it, so the cell joins the
            // remembered set. This one point covers every guarded mutation.
            if (comptime mayHoldRefs(T)) gc.writeBarrier(&cell.hdr);
            return .{ .cell = cell };
        }

        pub fn ptrEq(a: Self, b: Self) bool {
            return a.cell == b.cell;
        }

        pub fn strongCount(self: Self) usize {
            return self.cell.refcount.load(.acquire);
        }

        pub fn asPtr(self: Self) *T {
            // Unguarded mutable access carries the same write-barrier
            // obligation as a mutable borrow.
            if (comptime mayHoldRefs(T)) gc.writeBarrier(&self.cell.hdr);
            return &self.cell.data;
        }

        /// No lock, no write barrier. Only for a payload the caller can prove is
        /// not mutated concurrently, such as a settled registry table.
        pub fn asPtrConst(self: Self) *const T {
            return &self.cell.data;
        }

        /// Address-stable, so it works as a visited-set key on a cyclic graph.
        pub fn identity(self: Self) usize {
            return @intFromPtr(&self.cell.data);
        }
    };
}

pub fn ObjGuard(comptime T: type) type {
    return struct {
        const Self = @This();
        cell: *ControlBlock(T),

        pub fn get(self: Self) *const T {
            return &self.cell.data;
        }

        pub fn deinit(self: Self) void {
            self.cell.lock.unlockShared();
        }
    };
}

pub fn ObjGuardMut(comptime T: type) type {
    return struct {
        const Self = @This();
        cell: *ControlBlock(T),

        pub fn get(self: Self) *T {
            return &self.cell.data;
        }

        pub fn deinit(self: Self) void {
            self.cell.lock.unlockExclusive();
        }
    };
}

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

    const r1 = obj.borrow();
    const r2 = obj.borrow();
    const r3 = obj.borrow();
    try testing.expectEqual(@as(i32, 7), r1.get().*);
    try testing.expectEqual(@as(i32, 7), r3.get().*);
    r1.deinit();
    r2.deinit();
    r3.deinit();

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
    // The per-cell lock mediates every cross-thread borrow, so the handle needs
    // no publication step before it escapes.

    var handles: [THREADS]std.Thread = undefined;
    var t: usize = 0;
    while (t < THREADS) : (t += 1) {
        const worker = PushWorker{ .obj = obj.clone(), .allocator = allocator, .t = t };
        handles[t] = try std.Thread.spawn(.{}, PushWorker.run, .{worker});
    }
    t = 0;
    while (t < THREADS) : (t += 1) {
        handles[t].join();
    }
    // Reclaim one decrement per spawned worker's clone.
    t = 0;
    while (t < THREADS) : (t += 1) {
        obj.deinit();
    }

    const g = obj.borrow();
    defer g.deinit();
    try testing.expectEqual(THREADS * PUSHES_PER_THREAD, g.get().items.items.len);

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
