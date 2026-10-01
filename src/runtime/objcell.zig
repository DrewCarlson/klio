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
const builtin = @import("builtin");
const trace = @import("trace.zig");
pub const gc = @import("gc.zig");
const slab = @import("slab.zig");

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

/// Whether a list's elements are read with no lock (`ObjRef.readAtMoving`).
/// Set where the process runs on the collector over the slab heap, whose freed
/// memory stays mapped until a stop that no read spans (`slab.unmapLater`);
/// `KLIO_LOCKFREE_READS=0` leaves it off. Fixed before the program runs.
pub var lockfree_reads: bool = false;

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
/// The cache's keys and table share a few pages: a page per key mapped a
/// fresh 16 KB for every variable the process ever asked about.
var env_cache_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    if (comptime !@import("builtin").link_libc) return null;
    const key = std.mem.span(name);
    env_cache_mutex.lock();
    defer env_cache_mutex.unlock();
    const a = env_cache_arena.allocator();
    if (env_cache == null) env_cache = std.StringHashMap(?[]const u8).init(a);
    if (env_cache.?.get(key)) |cached| return cached;
    const value: ?[]const u8 = if (std.c.getenv(name)) |raw| std.mem.span(raw) else null;
    const stable_key = a.dupe(u8, key) catch return value;
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

/// Test hook: force one variable's answer, bypassing the environment read, so
/// a test can exercise a switch without mutating the process environment.
pub fn envSetForTest(comptime name: [:0]const u8, value: ?[]const u8) void {
    const S = EnvSlot(name);
    S.value = value;
    S.state.store(1, .release);
}

/// Test hook: undo `envSetForTest`, so the next ask reads the environment.
pub fn envResetForTest(comptime name: [:0]const u8) void {
    EnvSlot(name).state.store(0, .release);
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
const SpinRwLock = RwLock(false);

/// `SpinRwLock` whose writers also turn a sequence, odd while one holds the
/// lock, so a reader that takes no lock can tell a write overlapped it
/// (`ObjRef.readAt`).
const SeqRwLock = RwLock(true);

fn RwLock(comptime sequenced: bool) type {
    return struct {
        const Self = @This();
        /// `0` free, positive the reader count, `WRITER` (the sign bit) exclusive.
        state: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
        /// Even while no writer holds the lock; each writer adds one as it takes
        /// the lock and one as it gives it back.
        seq: if (sequenced) std.atomic.Value(u32) else void = if (sequenced) std.atomic.Value(u32).init(0) else {},

        const WRITER: i32 = std.math.minInt(i32);

        fn lockShared(self: *Self) void {
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

        fn unlockShared(self: *Self) void {
            _ = self.state.fetchSub(1, .release);
        }

        fn lockExclusive(self: *Self) void {
            var b: Backoff = .{};
            while (true) {
                if (self.state.load(.monotonic) == 0 and
                    self.state.cmpxchgWeak(0, WRITER, .acquire, .monotonic) == null)
                {
                    if (sequenced) {
                        // Odd before any store the writer makes can be seen.
                        self.seq.store(self.seq.raw +% 1, .monotonic);
                        storeFence();
                    }
                    return;
                }
                b.pause();
            }
        }

        fn unlockExclusive(self: *Self) void {
            if (sequenced) self.seq.store(self.seq.raw +% 1, .release);
            // Entering readers may have bumped the state past `WRITER` before
            // undoing their `fetchAdd`, so a blind zero store would erase a bump
            // whose undo is still pending. Clear only the writer bit: the transient
            // reader count rides in the low bits.
            _ = self.state.fetchAnd(std.math.maxInt(i32), .release);
        }

        const Backoff = SpinBackoff;
    };
}

/// Guarded sections are short, so early retries spin on cheap hints.
const SpinBackoff = struct {
    n: u32 = 0,
    inline fn pause(self: *SpinBackoff) void {
        self.n +%= 1;
        if (self.n < 16) {
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }
};

/// Every store before it is seen before every store after it.
pub inline fn storeFence() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("dmb ishst" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

/// Every load before it is performed before every load after it.
pub inline fn loadFence() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("dmb ishld" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

/// A stand-in for `SpinRwLock` for a payload immutable for its whole lifetime,
/// opting in with `pub const objref_immutable = true`. Nothing ever takes an
/// exclusive borrow of such a cell, so every operation here is a no-op.
const NoopRwLock = struct {
    inline fn lockShared(_: *NoopRwLock) void {}
    inline fn unlockShared(_: *NoopRwLock) void {}
    inline fn lockExclusive(_: *NoopRwLock) void {}
    inline fn unlockExclusive(_: *NoopRwLock) void {}
};

/// The no-op lock when `T` declares itself immutable or changes only through
/// atomics (`objref_atomic`), the sequenced lock for
/// a run of values (an `Array<T>`'s or a list's) or a payload read with no lock
/// that opts in with `pub const objref_sequenced = true` (a map's), else the
/// spin lock.
fn LockFor(comptime T: type) type {
    if (isContainer(T) and @hasDecl(T, "objref_immutable") and T.objref_immutable) return NoopRwLock;
    if (isContainer(T) and @hasDecl(T, "objref_atomic") and T.objref_atomic) return NoopRwLock;
    if (isContainer(T) and @hasDecl(T, "objref_sequenced") and T.objref_sequenced) return SeqRwLock;
    return if (sequencedRun(T)) SeqRwLock else SpinRwLock;
}

fn sequencedRun(comptime T: type) bool {
    if (!isArrayListLike(T)) return false;
    const Elem = @typeInfo(@FieldType(T, "items")).pointer.child;
    return @typeInfo(Elem) == .@"union" and @hasDecl(Elem, "isNumberOrBool");
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
        lock: LockFor(T),
        data: T,

        /// The prefix before a cell outside the region heap; a region cell has none.
        pub inline fn prefix(cb: *const Self) *CellPrefix {
            return @ptrFromInt(@intFromPtr(cb) - prefix_bytes);
        }

        /// The allocator that made the cell: the process heap's for a region cell.
        pub inline fn allocatorOf(cb: *const Self) std.mem.Allocator {
            return if (gc.isRegion(&cb.hdr)) slab.allocator else cb.prefix().allocator;
        }
    };
}

/// What a cell carries before it when it is not a region cell: the allocator
/// that made it, which frees it, and its reference count. A region cell is made
/// on the process heap and freed by the collector alone, so it carries neither
/// and starts at its header.
pub const CellPrefix = struct {
    refcount: std.atomic.Value(usize),
    allocator: std.mem.Allocator,
};
/// A cell stays 16-byte aligned after its prefix.
pub const prefix_bytes = std.mem.alignForward(usize, @sizeOf(CellPrefix), 16);

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
/// The shortest array whose element stores remember a range: a shorter one
/// is cheaper to trace whole than to keep an entry for.
pub const range_min_len = 64;

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
        // The region's bytes count as its holes are taken.
        if (data.capacity != 0 and gc.region.owns(@intFromPtr(data.items.ptr))) return 0;
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

/// Whether a `U` holds a cell reference that a tracer must reach: a type with
/// a tracer of its own (a `Value` among them), a handle, a raw cell pointer,
/// or any of these inside its fields, elements or hash-map values, looked at
/// `depth` levels deep. A pointer to anything else is not followed.
fn holdsRefs(comptime U: type, comptime depth: u8) bool {
    if (depth == 0) return false;
    if (hasDeclSafe(U, "gc_pointer_free")) return false;
    if (hasDeclSafe(U, "gcMark") or hasDeclSafe(U, "gcTrace")) return true;
    if (isObjRef(U) or isCellType(U)) return true;
    if (isHashMapLike(U) and @hasDecl(U, "KV")) return holdsRefs(@FieldType(U.KV, "value"), depth - 1);
    return switch (@typeInfo(U)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            if (holdsRefs(f.type, depth - 1)) break true;
        } else false,
        .@"union" => |u| inline for (u.fields) |f| {
            if (holdsRefs(f.type, depth - 1)) break true;
        } else false,
        .optional => |o| holdsRefs(o.child, depth - 1),
        .array => |a| holdsRefs(a.child, depth - 1),
        .pointer => |p| switch (p.size) {
            .slice => holdsRefs(p.child, depth - 1),
            .one => isCellType(p.child),
            else => false,
        },
        else => false,
    };
}

/// A `ControlBlock`: what a raw `*X.Cell` field points at.
fn isCellType(comptime U: type) bool {
    return @typeInfo(U) == .@"struct" and @hasField(U, "hdr") and @FieldType(U, "hdr") == gc.GcHeader;
}

/// A payload or element the generic tracer walks as a leaf must hold no
/// reference, or the collector would sweep what it reaches.
fn assertLeaf(comptime U: type) void {
    @setEvalBranchQuota(200_000);
    if (comptime holdsRefs(U, 6)) {
        @compileError(@typeName(U) ++ " holds cell references but has no gcTrace or gcMark, so a mark would miss them");
    }
}

/// Shading a cell is how the graph advances; its own trace does the next
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
    } else {
        comptime assertLeaf(E);
    }
}

fn gcTraceData(comptime U: type, data: *const U, m: *gc.Marker) void {
    comptime if (!hasDeclSafe(U, "gcTrace") and !hasDeclSafe(U, "gcMark") and !isObjRef(U) and
        @typeInfo(U) != .optional and !isArrayListLike(U) and !isSlice(U) and !isHashMapLike(U)) assertLeaf(U);
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
        markArrayBuffer(U, data, m);
    } else if (comptime isSlice(U)) {
        for (data.*) |*e| gcTraceElem(@TypeOf(e.*), e, m);
    } else if (comptime isHashMapLike(U)) {
        var it = data.valueIterator();
        while (it.next()) |v| gcTraceElem(@TypeOf(v.*), v, m);
    }
}

/// The lines of an array-like payload's buffer, when the region holds it.
inline fn markArrayBuffer(comptime U: type, data: *const U, m: *gc.Marker) void {
    const Elem = @typeInfo(@FieldType(U, "items")).pointer.child;
    if (data.capacity != 0) m.markBuffer(@intFromPtr(data.items.ptr), data.capacity * @sizeOf(Elem));
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

/// Whether a payload's finalizer can have anything to free.
fn mayFinalize(comptime U: type) bool {
    return hasDeclSafe(U, "gcFinalize") or isArrayListLike(U) or isSlice(U) or isHashMapLike(U);
}

/// Whether a region cell holding `data` must be on the lists for its
/// finalizer: a payload whose buffers may all be in its cell says so
/// itself (`gcNeedsFinalize`).
fn finalizeNeeded(comptime U: type, data: *const U) bool {
    if (comptime !mayFinalize(U)) return false;
    if (comptime hasDeclSafe(U, "gcNeedsFinalize")) return data.gcNeedsFinalize();
    return true;
}

pub const BorrowMutError = error{AlreadyBorrowed};

/// The cell locks this thread holds, counted where runtime safety is on. No
/// cell lock, shared or exclusive, may be held across a safe point: a
/// collection's marker takes each cell's shared lock, so a thread stopped for
/// the collection while it holds an exclusive one stalls the mark; and a
/// writer spinning for a lock a stopped thread holds, shared or exclusive,
/// never reaches the safe point the stop waits for. A host op that runs user
/// code (a lambda, a user `equals` or `compareTo`, a user iterator) copies
/// out of its borrow first. A payload that declares itself immutable takes
/// no lock and is not counted.
threadlocal var locks_held: u32 = 0;

inline fn noteLock(comptime T: type, comptime delta: i2) void {
    if (!std.debug.runtime_safety or LockFor(T) != SpinRwLock) return;
    if (delta > 0) locks_held += 1 else locks_held -= 1;
}

/// Panics when this thread holds a cell lock; called where the interpreter
/// reaches a safe point. A no-op without runtime safety.
pub inline fn assertNoCellLock() void {
    if (!std.debug.runtime_safety) return;
    if (locks_held != 0) cellLockAtSafePoint();
}

noinline fn cellLockAtSafePoint() noreturn {
    std.debug.print("\n[cell-lock] a safe point was reached holding {d} cell lock(s)\n", .{locks_held});
    trace.dumpCurrent(.{});
    @panic("a cell lock is held across a safe point");
}

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

        /// A trace holds the cell's shared lock, so it reads the payload as a
        /// reader does: every store into a payload is made under the cell's
        /// exclusive lock or, for an instance's slots, the store sequence its
        /// tracer reads through. Only this thunk knows the lock's type.
        fn gcTraceThunk(h: *gc.GcHeader, m: *gc.Marker) void {
            // Every cell is 16-byte aligned, so recovering the block from its
            // header re-establishes that alignment.
            const cb: *Cell = @fieldParentPtr("hdr", @as(*align(16) gc.GcHeader, @alignCast(h)));
            m.markRegion(h, @intFromPtr(cb), cellBytes(cb));
            cb.lock.lockShared();
            defer cb.lock.unlockShared();
            gcTraceData(T, &cb.data, m);
        }

        /// The cell's allocation: the block and its trailing run.
        inline fn cellBytes(cb: *const Cell) usize {
            const extra: usize = if (comptime hasDeclSafe(T, "trailingBytes")) cb.data.trailingBytes() else 0;
            return @sizeOf(Cell) + extra;
        }

        /// A cell just made in region memory, `bytes` long with its trailing
        /// run: its size and flags, and its place on the lists when its
        /// finalizer has anything to free.
        inline fn regionMint(cell: *Cell, bytes: usize) void {
            const ext = externalBytes(T, &cell.data);
            cell.hdr.gc_bytes = gc.regionBytes(bytes + ext);
            const listed = finalizeNeeded(T, &cell.data);
            if (listed or ext != 0) gc.regionMinted(&cell.hdr, ext, listed);
        }

        /// Elements `lo` through `hi` of an array-like payload, clamped to
        /// its length now.
        fn gcTraceRangeThunk(h: *gc.GcHeader, m: *gc.Marker, lo: u32, hi: u32) void {
            if (comptime !isArrayListLike(T)) unreachable;
            const cb: *Cell = @fieldParentPtr("hdr", @as(*align(16) gc.GcHeader, @alignCast(h)));
            cb.lock.lockShared();
            defer cb.lock.unlockShared();
            markArrayBuffer(T, &cb.data, m);
            const items = cb.data.items;
            if (lo >= items.len) return;
            const end = @min(items.len, @as(usize, hi) + 1);
            for (items[lo..end]) |*e| gcTraceElem(@TypeOf(e.*), e, m);
        }
        const gc_desc: gc.GcDesc = .{ .trace = gcTraceThunk, .finalize = gcFinalizeThunk, .name = @typeName(T) };
        /// A swept cell under `KLIO_GC_POISON`: any trace of it traps, naming its type.
        const poison_desc: gc.GcDesc = .{ .trace = gc.poisonTrap, .finalize = gcFinalizeThunk, .name = @typeName(T) };

        /// Shallow: child cells are swept independently.
        fn gcFinalizeThunk(h: *gc.GcHeader) void {
            const cb: *Cell = @fieldParentPtr("hdr", @as(*align(16) gc.GcHeader, @alignCast(h)));
            if (h.gc_remembered and getenvSlice("KLIO_GC_REMEMBER_TRACE") != null) {
                std.debug.print("[gc-freed-remembered] SWEEP h={*} type={s}\n", .{ h, h.typeName() });
                trace.dumpCurrent(.{});
            }
            if (gc.gc_poison) {
                // Quarantine instead of freeing: keep the memory mapped,
                // scribble the payload and arm the trap, so a later live
                // reference is caught with this cell's type. Leaks by design.
                @memset(std.mem.asBytes(&cb.data), 0xDD);
                h.gc_desc = &poison_desc;
                h.gc_mark = 0;
                return;
            }
            gcFinalizeData(T, &cb.data, cb.allocatorOf());
            freeCell(cb);
        }

        /// The cell's allocation: the block, and after it the payload's
        /// trailing run when `initTrailing` made one. A region cell's memory
        /// comes free with its lines.
        fn freeCell(cb: *Cell) void {
            if (gc.isRegion(&cb.hdr)) return;
            const allocator = cb.prefix().allocator;
            const extra: usize = if (comptime hasDeclSafe(T, "trailingBytes")) cb.data.trailingBytes() else 0;
            const block: [*]align(@max(@alignOf(Cell), 16)) u8 = @ptrFromInt(@intFromPtr(cb) - prefix_bytes);
            const whole: []align(@max(@alignOf(Cell), 16)) u8 = block[0 .. prefix_bytes + @sizeOf(Cell) + extra];
            allocator.free(whole);
        }

        /// `bytes` of cell after a prefix naming `allocator`, from it.
        fn allocWithPrefix(allocator: std.mem.Allocator, bytes: usize) std.mem.Allocator.Error!*Cell {
            const block = try allocator.alignedAlloc(u8, .fromByteUnits(@max(@alignOf(Cell), 16)), prefix_bytes + bytes);
            const p: *CellPrefix = @ptrCast(block.ptr);
            p.* = .{ .refcount = std.atomic.Value(usize).init(1), .allocator = allocator };
            return @ptrCast(@alignCast(block.ptr + prefix_bytes));
        }

        /// `initOwned` with the payload's trailing run of `n` `T.Trailing`s in
        /// the same allocation, after the cell, which the payload adopts
        /// (`T.adoptTrailing`) for the caller to fill: one allocation and one
        /// free where a separate buffer takes two.
        pub fn initTrailing(allocator: std.mem.Allocator, v: T, n: usize) std.mem.Allocator.Error!Self {
            const Elem = T.Trailing;
            const bytes = @sizeOf(Cell) + n * @sizeOf(Elem);
            if (gc.gc_enabled) {
                if (gc.regionAlloc(allocator, bytes)) |mem| {
                    const cell: *Cell = @ptrCast(mem);
                    cell.* = .{ .hdr = .{ .gc_desc = &gc_desc }, .lock = .{}, .data = v };
                    const elems: [*]Elem = @ptrCast(@alignCast(mem + @sizeOf(Cell)));
                    cell.data.adoptTrailing(elems[0..n]);
                    regionMint(cell, bytes);
                    return .{ .cell = cell };
                }
            }
            const cell = try allocWithPrefix(allocator, bytes);
            cell.* = .{ .hdr = .{ .gc_desc = &gc_desc }, .lock = .{}, .data = v };
            const base: [*]u8 = @ptrCast(cell);
            const elems: [*]Elem = @ptrCast(@alignCast(base + @sizeOf(Cell)));
            cell.data.adoptTrailing(elems[0..n]);
            if (gc.gc_enabled) gc.register(&cell.hdr, prefix_bytes + bytes + externalBytes(T, &cell.data));
            return .{ .cell = cell };
        }

        /// Writes into `cell` the region cell `v`, `bytes` long with its
        /// trailing run, as the process heap's region makes it: the image
        /// `fromImage` copies. The payload must need no finalizer and hold
        /// nothing outside the cell.
        pub fn regionImage(cell: *Cell, v: T, bytes: usize) void {
            cell.* = .{ .hdr = .{ .gc_desc = &gc_desc, .gc_bytes = gc.regionBytes(bytes) }, .lock = .{}, .data = v };
        }

        /// A copy of `image` (`regionImage`) in this thread's region hole,
        /// or null when the thread has none to give; the caller sets what
        /// differs from cell to cell.
        pub inline fn fromImage(image: []align(16) const u8) ?Self {
            const mem = gc.regionAlloc(slab.allocator, image.len) orelse return null;
            @memcpy(mem[0..image.len], image);
            return .{ .cell = @ptrCast(mem) };
        }

        /// Free the cell now, whatever the refcount gating or memory mode, for a
        /// hand-managed process-global cache swapping its owner. The caller
        /// asserts no live handle dereferences it afterwards, and the cell must
        /// not be on the sweep registry, so mint it permanent (`setAllocPerm`).
        pub fn destroyImmediately(self: Self) void {
            if (gc.gc_enabled) gc.forgetCell(&self.cell.hdr);
            const allocator = self.cell.allocatorOf();
            if (comptime owns_bytes) {
                allocator.free(self.cell.data);
            } else if (comptime hasDeinit(T)) {
                deinitData(&self.cell.data, allocator);
            }
            freeCell(self.cell);
        }

        /// `init` without the dupe: the cell adopts `v` verbatim, so it takes a
        /// `[]const u8` caller's buffer and frees it under the reclaim path.
        pub fn initOwned(allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!Self {
            if (gc.gc_enabled) {
                if (gc.regionAlloc(allocator, @sizeOf(Cell))) |mem| {
                    const cell: *Cell = @ptrCast(mem);
                    cell.* = .{ .hdr = .{ .gc_desc = &gc_desc }, .lock = .{}, .data = v };
                    regionMint(cell, @sizeOf(Cell));
                    return .{ .cell = cell };
                }
            }
            const cell = try allocWithPrefix(allocator, @sizeOf(Cell));
            cell.* = .{ .hdr = .{ .gc_desc = &gc_desc }, .lock = .{}, .data = v };
            if (gc.gc_enabled) gc.register(&cell.hdr, prefix_bytes + @sizeOf(Cell) + externalBytes(T, &cell.data));
            return .{ .cell = cell };
        }

        /// Gated exactly like `deinit`: under the arena and the tracing GC
        /// neither side of the count runs.
        pub fn clone(self: Self) Self {
            if (reclaim_shared.load(.monotonic)) _ = self.cell.prefix().refcount.fetchAdd(1, .monotonic);
            return .{ .cell = self.cell };
        }

        /// Decrement the strong count and, at zero, run `T.deinit` if present
        /// and free the control block. Under the arena fast path this returns
        /// immediately, since the arena reclaims every cell on reset.
        pub fn deinit(self: Self) void {
            if (!reclaim_shared.load(.monotonic)) return;
            const prev = self.cell.prefix().refcount.fetchSub(1, .release);
            if (detectDoubleFree()) {
                // Never destroy here, so a second decrement stays observable:
                // `prev == 0` means a double-free.
                if (prev == 0 or prev > (1 << 40)) {
                    std.debug.print("\n[RC DOUBLE-FREE] cell={*} payload={s}\n", .{ self.cell, @typeName(T) });
                    trace.dumpCurrent(.{});
                }
                if (prev == 1) {
                    const allocator = self.cell.allocatorOf();
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
                _ = self.cell.prefix().refcount.load(.acquire);
                if (self.cell.hdr.gc_remembered and getenvSlice("KLIO_GC_REMEMBER_TRACE") != null) {
                    std.debug.print("[gc-freed-remembered] RC h={*} type={s}\n", .{ &self.cell.hdr, @typeName(T) });
                    trace.dumpCurrent(.{});
                }
                const allocator = self.cell.allocatorOf();
                if (comptime owns_bytes) {
                    allocator.free(self.cell.data);
                } else if (comptime hasDeinit(T)) {
                    deinitData(&self.cell.data, allocator);
                }
                freeCell(self.cell);
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

        /// Element `i` of a run of values read with no lock, as the JVM reads
        /// an array's element: null when a writer held the lock or took it
        /// during the read, or `i` is out of range, and the caller takes the
        /// lock. Only for a run whose buffer never moves while its cell lives
        /// (an `Array<T>`'s): a moved buffer may be gone before the sequence
        /// says so.
        pub inline fn readAt(self: Self, i: usize) ?@typeInfo(@FieldType(T, "items")).pointer.child {
            comptime std.debug.assert(sequencedRun(T));
            const Elem = @typeInfo(@FieldType(T, "items")).pointer.child;
            const cell = self.cell;
            const before = cell.lock.seq.load(.acquire);
            if (before & 1 != 0) return null;
            const items = cell.data.items;
            if (i >= items.len) return null;
            const words: *const [2]u64 = @ptrCast(&items[i]);
            var out: Elem = undefined;
            const ow: *[2]u64 = @ptrCast(&out);
            ow[0] = @atomicLoad(u64, &words[0], .monotonic);
            ow[1] = @atomicLoad(u64, &words[1], .monotonic);
            loadFence();
            if (cell.lock.seq.load(.monotonic) != before) return null;
            return out;
        }

        /// `readAt` for a run whose buffer moves as it grows, a list's. The buffer and
        /// its length are read between two equal even readings of the sequence, so
        /// they are one writer's; the element is read before a third. A buffer a
        /// writer replaces stays mapped until a stop, which no read spans, so a read
        /// of one just freed finds garbage the third reading throws away. Only where
        /// `lockfree_reads` holds.
        pub inline fn readAtMoving(self: Self, i: usize) ?@typeInfo(@FieldType(T, "items")).pointer.child {
            comptime std.debug.assert(sequencedRun(T));
            const Elem = @typeInfo(@FieldType(T, "items")).pointer.child;
            const cell = self.cell;
            const before = cell.lock.seq.load(.acquire);
            if (before & 1 != 0) return null;
            const words: *const [2]usize = @ptrCast(&cell.data.items);
            const ptr = @atomicLoad(usize, &words[0], .monotonic);
            const len = @atomicLoad(usize, &words[1], .monotonic);
            loadFence();
            if (cell.lock.seq.load(.monotonic) != before or i >= len) return null;
            const elem: *const [2]u64 = @ptrFromInt(ptr + i * @sizeOf(Elem));
            var out: Elem = undefined;
            const ow: *[2]u64 = @ptrCast(&out);
            ow[0] = @atomicLoad(u64, &elem[0], .monotonic);
            ow[1] = @atomicLoad(u64, &elem[1], .monotonic);
            loadFence();
            if (cell.lock.seq.load(.monotonic) != before) return null;
            return out;
        }

        /// A mutable borrow of an array-like payload for a store into element
        /// `index` and nowhere else. A tenured array at least `range_min_len`
        /// long remembers only the range such stores touch, so the next minor
        /// mark traces that range rather than the whole array; a store that
        /// moves other elements takes `borrowMut`.
        pub fn borrowMutAt(self: Self, index: usize) ObjGuardMut(T) {
            comptime std.debug.assert(isArrayListLike(T));
            const cell = self.cell;
            raceJitter();
            cell.lock.lockExclusive();
            noteLock(T, 1);
            if (comptime mayHoldRefs(T)) {
                if (cell.data.items.len >= range_min_len) {
                    gc.writeBarrierAt(&cell.hdr, index, gcTraceRangeThunk);
                } else {
                    gc.writeBarrier(&cell.hdr);
                }
            }
            return .{ .cell = cell };
        }

        /// A mutable borrow of an array-like payload for appending `count`
        /// elements and nothing else. The indices they land at are read under
        /// the lock, so a concurrent append cannot land outside the range
        /// remembered; a list that ends at least `range_min_len` long
        /// remembers only that range.
        pub fn borrowMutAppend(self: Self, count: usize) ObjGuardMut(T) {
            comptime std.debug.assert(isArrayListLike(T));
            const cell = self.cell;
            raceJitter();
            cell.lock.lockExclusive();
            noteLock(T, 1);
            if (comptime mayHoldRefs(T)) {
                if (count != 0) {
                    const at = cell.data.items.len;
                    if (at + count >= range_min_len) {
                        gc.writeBarrierAt(&cell.hdr, at, gcTraceRangeThunk);
                        gc.writeBarrierAt(&cell.hdr, at + count - 1, gcTraceRangeThunk);
                    } else {
                        gc.writeBarrier(&cell.hdr);
                    }
                }
            }
            return .{ .cell = cell };
        }

        /// Concurrent shared borrows proceed together and an exclusive borrow
        /// blocks until they drain. Never returns null; the optional is kept
        /// for source compatibility.
        pub fn tryBorrow(self: Self) ?ObjGuard(T) {
            const cell = self.cell;
            raceJitter();
            cell.lock.lockShared();
            noteLock(T, 1);
            return .{ .cell = cell };
        }

        /// Exclusive against every reader and writer, blocking rather than
        /// failing. Never returns the error.
        pub fn tryBorrowMut(self: Self) BorrowMutError!ObjGuardMut(T) {
            const cell = self.cell;
            raceJitter();
            cell.lock.lockExclusive();
            noteLock(T, 1);
            // Generational write barrier: a mutable borrow of a tenured cell
            // may store a nursery reference into it, so the cell joins the
            // remembered set. This one point covers every guarded mutation.
            if (comptime mayHoldRefs(T)) gc.writeBarrier(&cell.hdr);
            return .{ .cell = cell };
        }

        pub fn ptrEq(a: Self, b: Self) bool {
            return a.cell == b.cell;
        }

        /// 0 for a region cell, which keeps no count.
        pub fn strongCount(self: Self) usize {
            if (gc.isRegion(&self.cell.hdr)) return 0;
            return self.cell.prefix().refcount.load(.acquire);
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
            noteLock(T, -1);
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
            noteLock(T, -1);
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

test "a payload that holds a reference is told apart from a leaf for the compile-time tracer check" {
    const Box = ObjRef(u64);
    const Traced = struct {
        pub fn gcMark(_: @This(), _: *gc.Marker) void {}
    };
    comptime {
        std.debug.assert(holdsRefs(struct { n: u32, items: std.ArrayList(Box) }, 6));
        std.debug.assert(holdsRefs(struct { raw: ?*Box.Cell }, 6));
        std.debug.assert(holdsRefs(std.AutoHashMap(u64, struct { v: Traced }), 6));
        std.debug.assert(holdsRefs(union(enum) { ok: void, err: struct { v: [2]Traced } }, 6));
        std.debug.assert(!holdsRefs(struct { n: u32, bytes: []const u8, p: *anyopaque }, 6));
        std.debug.assert(!holdsRefs(std.AutoHashMap(u64, u32), 6));
        std.debug.assert(!holdsRefs(struct {
            pub const gc_pointer_free = true;
            b: Box,
        }, 6));
    }
}

test "a cell lock is counted until its guard lets go" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    const a = try ObjRef(i32).init(testing.allocator, 0);
    defer a.deinit();
    const b = try ObjRef(std.ArrayList(i32)).init(testing.allocator, .empty);
    defer b.deinit();
    const Frozen = struct {
        pub const objref_immutable = true;
        n: u32,
    };
    const f = try ObjRef(Frozen).init(testing.allocator, .{ .n = 1 });
    defer f.deinit();
    const before = locks_held;
    {
        const g = a.borrowMut();
        defer g.deinit();
        try testing.expectEqual(before + 1, locks_held);
        const h = b.borrowMutAt(0);
        defer h.deinit();
        try testing.expectEqual(before + 2, locks_held);
    }
    try testing.expectEqual(before, locks_held);
    {
        const r = a.borrow();
        defer r.deinit();
        try testing.expectEqual(before + 1, locks_held);
        // An immutable payload takes no lock.
        const fr = f.borrow();
        defer fr.deinit();
        try testing.expectEqual(before + 1, locks_held);
    }
    try testing.expectEqual(before, locks_held);
    assertNoCellLock();
}

test "appends to a tenured list from many threads leave every appended cell reachable to a minor mark" {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Box = ObjRef(u64);
    const List = std.ArrayList(Box);
    const old = try Box.init(a, 0);
    old.cell.hdr.gc_gen = 1;
    var items: List = .empty;
    try items.appendNTimes(std.heap.smp_allocator, old, 100);
    const list = try ObjRef(List).init(a, items);
    list.cell.hdr.gc_gen = 1;
    defer gc.drainRemembered();

    const Appender = struct {
        fn run(target: ObjRef(List), alloc: std.mem.Allocator, seed: u64) void {
            var n: usize = 0;
            while (n < 2000) : (n += 1) {
                const young = [_]Box{
                    Box.init(alloc, seed * 10_000 + n) catch unreachable,
                    Box.init(alloc, seed * 10_000 + n + 1) catch unreachable,
                };
                // One element at a time, and two at once, as add and addAll do.
                const k: usize = if (n % 3 == 0) 2 else 1;
                const g = target.borrowMutAppend(k);
                defer g.deinit();
                g.get().appendSlice(std.heap.smp_allocator, young[0..k]) catch unreachable;
            }
        }
    };
    var arenas: [4]std.heap.ArenaAllocator = undefined;
    for (&arenas) |*ar| ar.* = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer for (&arenas) |*ar| ar.deinit();
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Appender.run, .{ list, arenas[k].allocator(), k + 1 });
    for (threads) |t| t.join();
    defer list.cell.data.deinit(std.heap.smp_allocator);

    // A mark tenures what it reaches, so the young cells are counted first.
    const was_young = try a.alloc(bool, list.cell.data.items.len);
    var young: usize = 0;
    for (list.cell.data.items, was_young) |e, *y| {
        y.* = e.cell.hdr.gc_gen == 0;
        young += @intFromBool(y.*);
    }
    try testing.expect(young > 8000);
    var m: gc.Marker = .{ .epoch = 78, .arena = std.heap.page_allocator, .minor = true };
    defer m.grey.deinit(std.heap.page_allocator);
    _ = gc.traceRemembered(&m);
    m.drain();
    for (list.cell.data.items, was_young) |e, y| {
        if (!y) continue;
        try testing.expectEqual(@as(usize, 78), e.cell.hdr.gc_mark);
    }
    // Only the appended range was remembered; the list was not retraced whole.
    try testing.expect(!list.cell.hdr.gc_remembered);
    try testing.expect(list.cell.hdr.gc_range != 0);
}

test "stores into a tenured array from many threads leave every stored cell reachable to a minor mark" {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Box = ObjRef(u64);
    const List = std.ArrayList(Box);
    const old = try Box.init(a, 0);
    old.cell.hdr.gc_gen = 1;
    var items: List = .empty;
    try items.appendNTimes(a, old, 4096);
    const arr = try ObjRef(List).init(a, items);
    arr.cell.hdr.gc_gen = 1;
    defer gc.drainRemembered();

    const Writer = struct {
        fn run(target: ObjRef(List), alloc: std.mem.Allocator, seed: u64) void {
            var x = seed;
            var n: usize = 0;
            while (n < 3000) : (n += 1) {
                x = x *% 6364136223846793005 +% 1442695040888963407;
                const i: usize = @intCast((x >> 33) % 4096);
                const young = Box.init(alloc, x) catch unreachable;
                const g = target.borrowMutAt(i);
                defer g.deinit();
                g.get().items[i] = young;
            }
        }
    };
    // The arena is not thread-safe; each writer gets its own.
    var arenas: [4]std.heap.ArenaAllocator = undefined;
    for (&arenas) |*ar| ar.* = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer for (&arenas) |*ar| ar.deinit();
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Writer.run, .{ arr, arenas[k].allocator(), k + 1 });
    for (threads) |t| t.join();

    // A mark tenures what it reaches, so the young cells are counted first.
    var was_young: [4096]bool = undefined;
    var young: usize = 0;
    for (arr.cell.data.items, &was_young) |e, *y| {
        y.* = e.cell.hdr.gc_gen == 0;
        young += @intFromBool(y.*);
    }
    try testing.expect(young > 1000);
    var m: gc.Marker = .{ .epoch = 77, .arena = std.heap.page_allocator, .minor = true };
    defer m.grey.deinit(std.heap.page_allocator);
    _ = gc.traceRemembered(&m);
    m.drain();
    for (arr.cell.data.items, was_young) |e, y| {
        if (!y) continue;
        try testing.expectEqual(@as(usize, 77), e.cell.hdr.gc_mark);
    }
    // Only the array joined the range table; nothing was remembered whole.
    try testing.expect(!arr.cell.hdr.gc_remembered);
    try testing.expect(arr.cell.hdr.gc_range != 0);
}

test "a region cell's lines stay live while it is reachable and come free once it is not" {
    const prev_enabled = gc.gc_enabled;
    const prev_region = gc.region_on;
    gc.gc_enabled = true;
    gc.region_on = true;
    defer {
        gc.gc_enabled = prev_enabled;
        gc.region_on = prev_region;
    }
    const prev_perm = gc.allocPerm();
    gc.setAllocPerm(false);
    defer gc.setAllocPerm(prev_perm);
    gc.enterMutator();
    defer gc.exitMutator();
    const R = struct {
        var kept: ?*gc.GcHeader = null;
        var registered = false;
        fn root(m: *gc.Marker) void {
            if (kept) |h| m.shade(h);
        }
    };
    if (!R.registered) {
        gc.registerRoot(R.root);
        R.registered = true;
    }
    defer R.kept = null;
    const Box = ObjRef(u64);
    const keep = try Box.init(slab.allocator, 42);
    try testing.expect(gc.isRegion(&keep.cell.hdr));
    try testing.expect(keep.cell.hdr.gc_bytes & gc.listed_bit == 0);
    R.kept = &keep.cell.hdr;
    var dropped: [40]usize = undefined;
    for (&dropped, 0..) |*d, i| d.* = @intFromPtr((try Box.init(slab.allocator, i)).cell);
    // A payload with a buffer outside its cell is on the lists for its finalizer.
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(slab.allocator, "abc");
    const listed = try ObjRef(std.ArrayList(u8)).init(slab.allocator, bytes);
    try testing.expect(gc.isRegion(&listed.cell.hdr));
    try testing.expect(listed.cell.hdr.gc_bytes & gc.listed_bit != 0);

    gc.collect();
    try testing.expect(gc.region.lineMarkAt(@intFromPtr(keep.cell)) != 0);
    try testing.expectEqual(@as(u64, 42), keep.cell.data);
    // The cells nothing reached, past the kept cell's line, left theirs free.
    try testing.expectEqual(@as(u8, 0), gc.region.lineMarkAt(dropped[dropped.len / 2]));
    // New cells fill the free lines and never the kept cell's.
    const lo = @intFromPtr(keep.cell);
    const hi = lo + @sizeOf(Box.Cell);
    var n: usize = 0;
    while (n < 20_000) : (n += 1) {
        const c = @intFromPtr((try Box.init(slab.allocator, n)).cell);
        try testing.expect(c + @sizeOf(Box.Cell) <= lo or c >= hi);
    }
    try testing.expectEqual(@as(u64, 42), keep.cell.data);

    R.kept = null;
    gc.collect();
    try testing.expectEqual(@as(u8, 0), gc.region.lineMarkAt(lo));
}
