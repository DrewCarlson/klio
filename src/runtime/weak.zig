//! Weak references and cleaners over the tracing collector, the runtime half
//! of Kotlin/Native's `kotlin.native.ref.WeakReference` and `createCleaner`.
//!
//! A weak cell holds its referent without tracing it. Every weak cell is on a
//! registry the collector reads after each mark with the world still stopped:
//! a live weak cell whose referent that collection is about to free has its
//! referent cleared before the sweep can free it, and a dead weak cell leaves
//! the registry. The referent never moves (the collector does not move cells),
//! so the registry keeps the referent's header from the cell's creation.
//!
//! A cleaner is a registry record of its owner (a `Cleaner` object, which
//! holds the cleanup job in a field) and the job. When a collection finds the
//! owner dead, the record's job is marked again, so it and what it captured
//! survive the sweep, and moves to a queue a cleaner thread drains, as
//! Kotlin/Native runs cleanup actions on a thread of their own. A live
//! owner's job costs a collection nothing beyond the owner's own trace.
//! Nothing the collector does runs Kotlin code.
//!
//! A native finalizer is the cheap form of a cleaner for a peer of a native
//! object: a C function and the pointer it frees, run once, by `runNative`
//! (a peer's `close()`) or after a collection finds the owner dead. It needs
//! no Kotlin job and marks nothing; the sweeper thread calls it once the
//! world has restarted.

const std = @import("std");
const objcell = @import("objcell.zig");
const gc = objcell.gc;
const value_mod = @import("value.zig");
const platform = @import("platform.zig");
const threads_mod = @import("threads.zig");

const Value = value_mod.Value;
const GcHeader = gc.GcHeader;

/// The payload of a weak cell. Written only at creation, by `clear()`, and by
/// the collector with the world stopped.
pub const WeakData = struct {
    referent: Value,
    /// The referent has no cell the collector can tell the fate of, so the
    /// weak cell holds it as a strong one would rather than risk a dangling
    /// reference.
    strong: bool = false,

    pub fn gcTrace(self: *const WeakData, m: *gc.Marker) void {
        if (self.strong) self.referent.gcMark(m);
    }

    pub fn deinit(self: *WeakData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.referent.release(std.heap.page_allocator);
    }
};

pub const WeakRef = objcell.ObjRef(WeakData);

/// The header of the cell `v` itself lives in, or null for a value with no
/// cell of its own (a primitive, a closure-less intrinsic).
pub fn cellOf(v: Value) ?*GcHeader {
    const Visitor = struct {
        out: *?*GcHeader,
        pub fn visit(self: @This(), objref: anytype) void {
            if (self.out.* == null) self.out.* = &objref.cell.hdr;
        }
    };
    if (v == .Class) return &v.Class.cell.hdr;
    var out: ?*GcHeader = null;
    v.forEachChildCell(Visitor{ .out = &out });
    return out;
}

const WeakEntry = struct {
    cell: *GcHeader,
    target: *GcHeader,
    weak: *WeakData,
};

const CleanerEntry = struct {
    owner: *GcHeader,
    job: Value,
};

/// Entries registered since the last collection are young: a minor can free
/// their cells. Every survivor of a minor is tenured by it, so after one pass
/// an entry is old and only a major needs to look at it again.
fn Generations(comptime E: type) type {
    return struct {
        young: std.ArrayList(E) = .empty,
        old: std.ArrayList(E) = .empty,

        fn clear(self: *@This()) void {
            self.young.clearRetainingCapacity();
            self.old.clearRetainingCapacity();
        }

        /// Runs `pass` over the entries this collection can free, keeping
        /// those it returns true for; a minor's survivors become old.
        fn sweep(self: *@This(), major: bool, ctx: anytype, comptime pass: fn (@TypeOf(ctx), E) bool) void {
            if (major) retain(&self.old, ctx, pass);
            retain(&self.young, ctx, pass);
            self.old.appendSlice(reg_alloc, self.young.items) catch @panic("KGC: weak registry allocation failed");
            self.young.clearRetainingCapacity();
        }

        fn retain(list: *std.ArrayList(E), ctx: anytype, comptime pass: fn (@TypeOf(ctx), E) bool) void {
            var i: usize = 0;
            while (i < list.items.len) {
                if (pass(ctx, list.items[i])) i += 1 else _ = list.swapRemove(i);
            }
        }

        fn forgetIn(self: *@This(), rs: []const gc.Range, comptime inside: fn ([]const gc.Range, E) bool) void {
            inline for (.{ &self.young, &self.old }) |list| {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (inside(rs, list.items[i])) _ = list.swapRemove(i) else i += 1;
                }
            }
        }
    };
}

/// A native finalizer's record. The owner holds its address as a Long; it is
/// freed once the owner is dead and the finalizer has run or been skipped.
pub const NativeRecord = struct {
    finalizer: *const fn (?*anyopaque) callconv(.c) void,
    ptr: usize,
    /// What the native object holds that the collector counts until the
    /// finalizer runs (`peer_bytes`).
    bytes: usize = 0,
    /// 0 armed, 1 run: whoever moves it runs the finalizer.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn run(self: *NativeRecord) bool {
        if (self.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return false;
        self.finalizer(@ptrFromInt(self.ptr));
        if (self.bytes != 0) gc.noteExternalFreed(self.bytes);
        return true;
    }
};

/// The bytes a native object holds beyond its owner's cell, for an owner
/// registered with `registerNative`: while the owner lives they count
/// toward the collector's trigger as external memory, so dropping large
/// native objects brings a collection as dropping as much heap does. Set by
/// the library whose natives make them; null counts none.
pub var peer_bytes: ?*const fn (owner: Value, ptr: usize) usize = null;

const NativeEntry = struct {
    owner: *GcHeader,
    rec: *NativeRecord,
};

/// Weak cells, cleaners and the cleanup queue each have a lock of their own,
/// so creating a weak cell, registering a cleaner and taking a job never wait
/// on one another. The collector's pass takes each in turn with the world
/// stopped.
var weak_lock: platform.Mutex = .{};
var weaks: Generations(WeakEntry) = .{};

var cleaner_lock: platform.Mutex = .{};
var cleaners: Generations(CleanerEntry) = .{};
/// Whether this run's cleaner thread has been asked for.
var worker_started: bool = false;

/// Jobs whose owner a collection found dead, waiting for the cleaner thread:
/// `pending[head..]`, rooted until taken.
var queue_lock: platform.Mutex = .{};
var queue_cond: platform.Cond = .{};
var pending: std.ArrayList(Value) = .empty;
var head: usize = 0;

var native_lock: platform.Mutex = .{};
var natives: Generations(NativeEntry) = .{};
/// Records whose owner a collection found dead, for the sweeper to run.
var native_ready: std.ArrayList(*NativeRecord) = .empty;

var hooks_lock: platform.Mutex = .{};
var hooks_installed = std.atomic.Value(bool).init(false);
const reg_alloc = std.heap.page_allocator;
/// Native finalizer records are small and many: one page each from the page
/// allocator would cost a mapping per peer.
const rec_alloc = if (@import("builtin").link_libc) std.heap.c_allocator else std.heap.smp_allocator;

fn installHooks() void {
    if (hooks_installed.load(.acquire)) return;
    hooks_lock.lock();
    defer hooks_lock.unlock();
    if (hooks_installed.load(.acquire)) return;
    gc.weak_hook = processAfterMark;
    gc.weak_forget_hook = forget;
    gc.native_finalize_hook = runReadyNatives;
    gc.registerRoot(markRoots);
    threads_mod.registerRunBoundaryHook(runBoundary);
    hooks_installed.store(true, .release);
}

/// A weak cell for `referent`, registered with the collector.
pub fn newWeak(allocator: std.mem.Allocator, referent: Value) std.mem.Allocator.Error!Value {
    const target = cellOf(referent);
    referent.retain();
    const ref = try WeakRef.init(allocator, .{ .referent = referent, .strong = target == null and !referent.isPrimitive() });
    if (target) |t| {
        // A cell that is never swept is never freed, so its weak cells never
        // need clearing.
        if (gc.gc_enabled and t.gc_bytes != 0) {
            installHooks();
            weak_lock.lock();
            defer weak_lock.unlock();
            try weaks.young.append(reg_alloc, .{ .cell = &ref.cell.hdr, .target = t, .weak = &ref.cell.data });
        }
    }
    return .{ .Weak = ref };
}

/// The referent, or null once it was cleared or collected.
pub fn get(v: Value) Value {
    if (v != .Weak) return .Null;
    const g = v.Weak.borrow();
    defer g.deinit();
    const r = g.get().referent;
    r.retain();
    return r;
}

/// Drops the referent. The registry entry stays until a collection finds its
/// target or its cell dead, which clears nothing further.
pub fn clear(v: Value) void {
    if (v != .Weak) return;
    const g = v.Weak.borrowMut();
    defer g.deinit();
    const w = g.get();
    w.referent.release(std.heap.page_allocator);
    w.referent = .Null;
    w.strong = false;
}

/// Registers `job` to be run on the cleaner thread once `owner` dies. True
/// when this run has no cleaner thread yet and the caller must start one.
pub fn registerCleaner(owner: Value, job: Value) std.mem.Allocator.Error!bool {
    const h = cellOf(owner) orelse return false;
    if (!gc.gc_enabled or h.gc_bytes == 0) return false;
    installHooks();
    cleaner_lock.lock();
    defer cleaner_lock.unlock();
    job.retain();
    try cleaners.young.append(reg_alloc, .{ .owner = h, .job = job });
    if (worker_started) return false;
    worker_started = true;
    return true;
}

/// Registers `finalizer(ptr)` to run once `owner` dies, and returns the
/// record's address for `runNative`. With no collector the owner never dies,
/// so only `runNative` runs it.
pub fn registerNative(owner: Value, finalizer: usize, ptr: usize) std.mem.Allocator.Error!usize {
    const rec = try rec_alloc.create(NativeRecord);
    rec.* = .{ .finalizer = @ptrFromInt(finalizer), .ptr = ptr };
    const h = cellOf(owner) orelse return @intFromPtr(rec);
    if (!gc.gc_enabled or h.gc_bytes == 0) return @intFromPtr(rec);
    installHooks();
    rec.bytes = if (peer_bytes) |f| f(owner, ptr) else 0;
    {
        native_lock.lock();
        defer native_lock.unlock();
        try natives.young.append(reg_alloc, .{ .owner = h, .rec = rec });
    }
    if (rec.bytes != 0) gc.noteExternalBytes(rec.bytes);
    return @intFromPtr(rec);
}

/// Runs the record's finalizer now unless it already ran. True when this
/// call ran it.
pub fn runNative(handle: usize) bool {
    if (handle == 0) return false;
    const rec: *NativeRecord = @ptrFromInt(handle);
    return rec.run();
}

/// Runs, then frees, every record whose owner died. The sweeper calls this
/// after its sweep; nothing else holds a record once its owner is dead.
fn runReadyNatives() void {
    native_lock.lock();
    const ready = native_ready;
    native_ready = .empty;
    native_lock.unlock();
    var list = ready;
    defer list.deinit(reg_alloc);
    for (list.items) |rec| {
        _ = rec.run();
        rec_alloc.destroy(rec);
    }
}

fn nativePass(major: bool, e: NativeEntry) bool {
    if (!gc.cellDead(e.owner, major)) return true;
    native_ready.append(reg_alloc, e.rec) catch @panic("KGC: native finalizer queue allocation failed");
    return false;
}

/// Waits for the next cleanup job and returns it, or null once the run is
/// ending. Waits blocking-safe, and takes the job only once running again as
/// a mutator, so the job stays rooted on the queue until the caller holds it.
pub fn takeCleanup() ?Value {
    if (comptime !platform.has_os_sync) return null;
    while (true) {
        if (takeReady()) |job| return job;
        gc.enterBlockingSafe();
        threads_mod.notifyWallBlock();
        queue_lock.lock();
        while (head == pending.items.len and !threads_mod.shouldAbandon()) {
            queue_cond.timedWait(&queue_lock, 50 * std.time.ns_per_ms);
        }
        queue_lock.unlock();
        threads_mod.notifyWallUnblock();
        gc.exitBlockingSafe();
        if (threads_mod.shouldAbandon()) return null;
    }
}

fn takeReady() ?Value {
    queue_lock.lock();
    defer queue_lock.unlock();
    if (head == pending.items.len) return null;
    const job = pending.items[head];
    head += 1;
    if (head == pending.items.len) {
        pending.clearRetainingCapacity();
        head = 0;
    }
    return job;
}

fn weakPass(major: bool, e: WeakEntry) bool {
    if (gc.cellDead(e.cell, major)) return false;
    if (gc.cellDead(e.target, major)) {
        // No mutator runs and no tracer reads a weak cell's referent, so the
        // store needs neither the cell's lock nor a write barrier: Null makes
        // no edge.
        e.weak.referent = .Null;
        return false;
    }
    return true;
}

const CleanerCtx = struct { major: bool, m: *gc.Marker };

fn cleanerPass(ctx: CleanerCtx, e: CleanerEntry) bool {
    if (!gc.cellDead(e.owner, ctx.major)) return true;
    // The owner goes; its job must not: marking it now, before the sweep,
    // keeps it and everything it captured.
    e.job.gcMark(ctx.m);
    pending.append(reg_alloc, e.job) catch @panic("KGC: cleaner queue allocation failed");
    return false;
}

/// With the world stopped after a mark: queues the job of every cleaner
/// whose owner this collection frees, marking what the job reaches so it
/// outlives the sweep; then clears every live weak cell whose referent is
/// still unmarked and drops dead weak cells. A weak reference to what a
/// queued job holds stays set until the job has run.
fn processAfterMark(major: bool, m: *gc.Marker) void {
    {
        cleaner_lock.lock();
        defer cleaner_lock.unlock();
        queue_lock.lock();
        defer queue_lock.unlock();
        const before = pending.items.len;
        cleaners.sweep(major, CleanerCtx{ .major = major, .m = m }, cleanerPass);
        m.drain();
        if (pending.items.len != before) queue_cond.broadcast();
    }
    {
        native_lock.lock();
        defer native_lock.unlock();
        natives.sweep(major, major, nativePass);
    }
    weak_lock.lock();
    defer weak_lock.unlock();
    weaks.sweep(major, major, weakPass);
}

/// Queued jobs are roots until the cleaner thread takes them.
fn markRoots(m: *gc.Marker) void {
    queue_lock.lock();
    defer queue_lock.unlock();
    for (pending.items[head..]) |j| j.gcMark(m);
}

fn weakInside(rs: []const gc.Range, e: WeakEntry) bool {
    return gc.inRanges(rs, e.cell) or gc.inRanges(rs, e.target);
}

fn cleanerInside(rs: []const gc.Range, e: CleanerEntry) bool {
    return gc.inRanges(rs, e.owner);
}

fn nativeInside(rs: []const gc.Range, e: NativeEntry) bool {
    return gc.inRanges(rs, e.owner);
}

/// Forgets every entry for a cell about to be freed wholesale: those inside
/// `ranges`, or all of them for null.
fn forget(ranges: ?[]const gc.Range) void {
    weak_lock.lock();
    defer weak_lock.unlock();
    cleaner_lock.lock();
    defer cleaner_lock.unlock();
    const rs = ranges orelse {
        weaks.clear();
        cleaners.clear();
        // The run is over, so every owner it registered is garbage: its
        // native objects are freed now rather than never.
        {
            native_lock.lock();
            defer native_lock.unlock();
            for (natives.young.items) |e| native_ready.append(reg_alloc, e.rec) catch {};
            for (natives.old.items) |e| native_ready.append(reg_alloc, e.rec) catch {};
            natives.clear();
        }
        runReadyNatives();
        queue_lock.lock();
        defer queue_lock.unlock();
        pending.clearRetainingCapacity();
        head = 0;
        return;
    };
    weaks.forgetIn(rs, weakInside);
    cleaners.forgetIn(rs, cleanerInside);
    native_lock.lock();
    defer native_lock.unlock();
    natives.forgetIn(rs, nativeInside);
}

/// A run's weak cells, cleaners and cleaner thread end with it.
fn runBoundary() void {
    forget(null);
    cleaner_lock.lock();
    defer cleaner_lock.unlock();
    worker_started = false;
}

pub fn weakCount() usize {
    weak_lock.lock();
    defer weak_lock.unlock();
    return weaks.young.items.len + weaks.old.items.len;
}

pub fn pendingCount() usize {
    queue_lock.lock();
    defer queue_lock.unlock();
    return pending.items.len - head;
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn idleTrace(_: *GcHeader, _: *gc.Marker) void {}
fn idleFinalize(_: *GcHeader) void {}

/// A header the registry's pass judges without a collection: `gen` 1 is
/// tenured, `marked` carries the last sweep's epoch, `bytes` 0 is permanent.
fn testHeader(gen: u8, marked: bool, bytes: u32) GcHeader {
    return .{
        .gc_trace = idleTrace,
        .gc_finalize = idleFinalize,
        .gc_gen = gen,
        .gc_bytes = bytes,
        .gc_mark = if (marked) gc.sweepEpoch() else gc.sweepEpoch() +% 1,
    };
}

/// The registry's pass as a collection runs it, with a marker for the jobs it
/// keeps; the tests' jobs are plain values, which mark nothing.
fn testPass(major: bool) void {
    var m: gc.Marker = .{ .epoch = gc.sweepEpoch(), .arena = testing.allocator };
    defer m.grey.deinit(testing.allocator);
    processAfterMark(major, &m);
}

fn resetRegistry() void {
    weaks.clear();
    cleaners.clear();
    natives.clear();
    native_ready.clearRetainingCapacity();
    pending.clearRetainingCapacity();
    head = 0;
}

test "a minor clears a weak cell whose young referent it frees" {
    defer resetRegistry();
    var cell = testHeader(1, false, 32);
    var target = testHeader(0, false, 32);
    var data: WeakData = .{ .referent = .{ .Int = 7 } };
    try weaks.young.append(reg_alloc, .{ .cell = &cell, .target = &target, .weak = &data });
    testPass(false);
    try testing.expect(data.referent == .Null);
    try testing.expectEqual(@as(usize, 0), (weaks.young.items.len + weaks.old.items.len));
}

test "a minor keeps a weak cell whose referent is tenured" {
    defer resetRegistry();
    var cell = testHeader(0, true, 32);
    var target = testHeader(1, false, 32);
    var data: WeakData = .{ .referent = .{ .Int = 7 } };
    try weaks.young.append(reg_alloc, .{ .cell = &cell, .target = &target, .weak = &data });
    testPass(false);
    try testing.expectEqual(@as(i32, 7), data.referent.Int);
    try testing.expectEqual(@as(usize, 1), (weaks.young.items.len + weaks.old.items.len));
}

test "a major clears a weak cell whose tenured referent it did not mark" {
    defer resetRegistry();
    var cell = testHeader(1, true, 32);
    var live = testHeader(1, true, 32);
    var dead = testHeader(1, false, 32);
    var kept: WeakData = .{ .referent = .{ .Int = 1 } };
    var cleared: WeakData = .{ .referent = .{ .Int = 2 } };
    try weaks.young.append(reg_alloc, .{ .cell = &cell, .target = &live, .weak = &kept });
    try weaks.young.append(reg_alloc, .{ .cell = &cell, .target = &dead, .weak = &cleared });
    testPass(true);
    try testing.expectEqual(@as(i32, 1), kept.referent.Int);
    try testing.expect(cleared.referent == .Null);
    try testing.expectEqual(@as(usize, 1), (weaks.young.items.len + weaks.old.items.len));
}

test "a minor leaves old entries to the major, and survivors of a minor become old" {
    defer resetRegistry();
    var cell = testHeader(1, true, 32);
    var target = testHeader(1, false, 32);
    var old_data: WeakData = .{ .referent = .{ .Int = 5 } };
    try weaks.old.append(reg_alloc, .{ .cell = &cell, .target = &target, .weak = &old_data });
    var young_cell = testHeader(0, true, 32);
    var young_target = testHeader(1, false, 32);
    var young_data: WeakData = .{ .referent = .{ .Int = 6 } };
    try weaks.young.append(reg_alloc, .{ .cell = &young_cell, .target = &young_target, .weak = &young_data });
    testPass(false);
    try testing.expectEqual(@as(i32, 5), old_data.referent.Int);
    try testing.expectEqual(@as(i32, 6), young_data.referent.Int);
    try testing.expectEqual(@as(usize, 0), weaks.young.items.len);
    try testing.expectEqual(@as(usize, 2), weaks.old.items.len);
    testPass(true);
    try testing.expect(old_data.referent == .Null);
    try testing.expect(young_data.referent == .Null);
}

test "a permanent referent is never cleared" {
    defer resetRegistry();
    var cell = testHeader(1, true, 32);
    var target = testHeader(1, false, 0);
    var data: WeakData = .{ .referent = .{ .Int = 3 } };
    try weaks.young.append(reg_alloc, .{ .cell = &cell, .target = &target, .weak = &data });
    testPass(true);
    try testing.expectEqual(@as(i32, 3), data.referent.Int);
}

test "a dead weak cell leaves the registry without touching its referent" {
    defer resetRegistry();
    var cell = testHeader(0, false, 32);
    var target = testHeader(0, false, 32);
    var data: WeakData = .{ .referent = .{ .Int = 4 } };
    try weaks.young.append(reg_alloc, .{ .cell = &cell, .target = &target, .weak = &data });
    testPass(false);
    try testing.expectEqual(@as(i32, 4), data.referent.Int);
    try testing.expectEqual(@as(usize, 0), (weaks.young.items.len + weaks.old.items.len));
}

test "a cleaner whose owner dies queues its job, and only then" {
    defer resetRegistry();
    var dead_owner = testHeader(0, false, 32);
    var live_owner = testHeader(0, true, 32);
    try cleaners.young.append(reg_alloc, .{ .owner = &dead_owner, .job = .{ .Int = 11 } });
    try cleaners.young.append(reg_alloc, .{ .owner = &live_owner, .job = .{ .Int = 12 } });
    testPass(false);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqual(@as(i32, 11), pending.items[0].Int);
    try testing.expectEqual(@as(usize, 1), (cleaners.young.items.len + cleaners.old.items.len));
    try testing.expectEqual(@as(i32, 12), cleaners.old.items[0].job.Int);
}

test "a dead owner's job is marked, so the sweep keeps it for the cleaner thread" {
    defer resetRegistry();
    const job = try Value.newCell(testing.allocator, .{ .Int = 9 });
    defer job.Cell.destroyImmediately();
    job.Cell.cell.hdr.gc_mark = gc.sweepEpoch() +% 1;
    var owner = testHeader(0, false, 32);
    try cleaners.young.append(reg_alloc, .{ .owner = &owner, .job = job });
    testPass(false);
    try testing.expectEqual(gc.sweepEpoch(), job.Cell.cell.hdr.gc_mark);
    try testing.expectEqual(@as(usize, 1), pendingCount());
}

var native_calls: usize = 0;
fn countFinalizer(p: ?*anyopaque) callconv(.c) void {
    _ = p;
    native_calls += 1;
}

test "a native finalizer runs once, by close or after its owner dies" {
    defer resetRegistry();
    native_calls = 0;
    const closed = try rec_alloc.create(NativeRecord);
    closed.* = .{ .finalizer = countFinalizer, .ptr = 1 };
    const dropped = try rec_alloc.create(NativeRecord);
    dropped.* = .{ .finalizer = countFinalizer, .ptr = 2 };
    const kept = try rec_alloc.create(NativeRecord);
    defer rec_alloc.destroy(kept);
    kept.* = .{ .finalizer = countFinalizer, .ptr = 3 };
    var dead_a = testHeader(0, false, 32);
    var dead_b = testHeader(0, false, 32);
    var live = testHeader(0, true, 32);
    try natives.young.append(reg_alloc, .{ .owner = &dead_a, .rec = closed });
    try natives.young.append(reg_alloc, .{ .owner = &dead_b, .rec = dropped });
    try natives.young.append(reg_alloc, .{ .owner = &live, .rec = kept });
    try testing.expect(runNative(@intFromPtr(closed)));
    try testing.expect(!runNative(@intFromPtr(closed)));
    try testing.expectEqual(@as(usize, 1), native_calls);
    testPass(false);
    runReadyNatives();
    try testing.expectEqual(@as(usize, 2), native_calls);
    try testing.expectEqual(@as(u8, 0), kept.state.load(.acquire));
    try testing.expectEqual(@as(usize, 1), natives.old.items.len);
}

test "a native object's bytes count as external memory until its finalizer runs" {
    const prev = gc.gc_enabled;
    gc.gc_enabled = true;
    defer gc.gc_enabled = prev;
    const before = gc.externalLiveBytes();
    const rec = try rec_alloc.create(NativeRecord);
    defer rec_alloc.destroy(rec);
    rec.* = .{ .finalizer = countFinalizer, .ptr = 1, .bytes = 4 << 20 };
    gc.noteExternalBytes(rec.bytes);
    try testing.expectEqual(before + (4 << 20), gc.externalLiveBytes());
    try testing.expect(rec.run());
    try testing.expectEqual(before, gc.externalLiveBytes());
    // Run once, released once.
    try testing.expect(!rec.run());
    try testing.expectEqual(before, gc.externalLiveBytes());
}

test "forgetting ranges drops the entries inside them" {
    defer resetRegistry();
    var cells: [2]GcHeader = .{ testHeader(1, true, 32), testHeader(1, true, 32) };
    var target = testHeader(1, true, 32);
    var data: WeakData = .{ .referent = .{ .Int = 1 } };
    try weaks.young.append(reg_alloc, .{ .cell = &cells[0], .target = &target, .weak = &data });
    try weaks.young.append(reg_alloc, .{ .cell = &cells[1], .target = &target, .weak = &data });
    const ranges = [_]gc.Range{.{ .start = @intFromPtr(&cells[0]), .len = @sizeOf(GcHeader) }};
    forget(&ranges);
    try testing.expectEqual(@as(usize, 1), (weaks.young.items.len + weaks.old.items.len));
    try testing.expectEqual(&cells[1], weaks.young.items[0].cell);
}

test "a value's own cell is the one the registry watches" {
    try testing.expect(cellOf(.{ .Int = 1 }) == null);
    try testing.expect(cellOf(.Null) == null);
    const cell = try Value.newCell(testing.allocator, .{ .Int = 5 });
    defer cell.Cell.destroyImmediately();
    try testing.expectEqual(&cell.Cell.cell.hdr, cellOf(cell).?);
}
