//! Shared dispatcher worker pool behind `Dispatchers.Default` and `Dispatchers.IO`.
//! One pool of OS threads serves both, mirroring upstream's `CoroutineScheduler`:
//! `Default` is the CPU-bounded view, `IO` the elastic one, so a `withContext(IO)`
//! hop stays on the pool. Per-view execution is FIFO; workers spawn on demand to the
//! ceiling and park on an event when idle. The pool is per-run and its tasks are
//! daemons (work never blocks process exit), torn down by `shutdownAndJoin`.

const std = @import("std");

const runtime = @import("runtime");
const root = @import("../interp_ir.zig");
const coroutines = @import("coroutines.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const SendableVmSeed = root.SendableVmSeed;
const TimeMode = root.TimeMode;

pub const Kind = enum { default, io };

pub const Task = struct {
    seed: SendableVmSeed,
    block: Value,
    time_mode: TimeMode,
    reclaim: bool,
    kind: Kind,
};

/// True while this thread runs a pool task, so a blocking wait never waits on itself.
threadlocal var in_pool_task: bool = false;

pub fn onPoolWorker() bool {
    return in_pool_task;
}

pub const Pool = struct {
    mutex: runtime.SpinMutex = .{},
    /// Rung on every post, completion and stop, so an idle worker parks, not polls.
    gate: runtime.EventGate = .{},
    /// FIFO per view; head-index pops are O(1) and the spine compacts past half.
    queue_default: Fifo = .{},
    queue_io: Fifo = .{},
    /// Worker join handles, owned by the pool.
    workers: std.ArrayList(std.Thread) = .empty,
    running: usize = 0,
    running_default: usize = 0,
    worker_seq: usize = 0,
    stopping: bool = false,
    /// First internal task failure of the run, read at the run boundary.
    first_error: ?RuntimeError = null,
    /// Executes one task; production materializes a child Vm, tests inject a stub.
    run_fn: *const fn (task: *Task) ?RuntimeError = runVmTask,
    /// Releases a task that never ran (dropped at shutdown).
    drop_fn: *const fn (task: *Task) void = dropVmTask,
    /// Concurrency cap of the Default view; 0 = derive from nproc.
    default_cap_override: usize = 0,
    /// Pool worker ceiling (the IO view's parallelism); 0 = derive.
    max_workers_override: usize = 0,

    const Fifo = struct {
        items: std.ArrayList(Task) = .empty,
        head: usize = 0,

        fn len(self: *const Fifo) usize {
            return self.items.items.len - self.head;
        }

        fn push(self: *Fifo, a: Allocator, t: Task) Allocator.Error!void {
            try self.items.append(a, t);
        }

        fn pop(self: *Fifo) ?Task {
            if (self.head == self.items.items.len) return null;
            const t = self.items.items[self.head];
            self.head += 1;
            if (self.head >= 64 and self.head * 2 >= self.items.items.len) {
                const remaining = self.items.items.len - self.head;
                std.mem.copyForwards(Task, self.items.items[0..remaining], self.items.items[self.head..]);
                self.items.shrinkRetainingCapacity(remaining);
                self.head = 0;
            }
            return t;
        }

        fn clear(self: *Fifo, a: Allocator) void {
            self.items.deinit(a);
            self.* = .{};
        }
    };

    /// Process-lifetime allocator for the pool's own spines (queues, worker list).
    fn allocator(self: *Pool) Allocator {
        _ = self;
        return std.heap.page_allocator;
    }

    /// `KLIO_MAX_WORKERS`: process-wide ceiling on worker threads; 0 means unset.
    fn envWorkerCap() usize {
        const S = struct {
            var cached = std.atomic.Value(usize).init(std.math.maxInt(usize));
        };
        const c = S.cached.load(.monotonic);
        if (c != std.math.maxInt(usize)) return c;
        var v: usize = 0;
        if (runtime.envOnce("KLIO_MAX_WORKERS")) |raw| {
            v = std.fmt.parseInt(usize, raw, 10) catch 0;
        }
        S.cached.store(v, .monotonic);
        return v;
    }

    /// `getCpuCount` is a syscall and `maxWorkers` runs on every post, so cache it.
    fn cpuCountCached() usize {
        const S = struct {
            var cached: std.atomic.Value(usize) = .init(0);
        };
        const c = S.cached.load(.monotonic);
        if (c != 0) return c;
        const n = std.Thread.getCpuCount() catch 1;
        S.cached.store(n, .monotonic);
        return n;
    }

    pub fn defaultCap(self: *Pool) usize {
        if (self.default_cap_override != 0) return self.default_cap_override;
        const n = cpuCountCached();
        const cap = envWorkerCap();
        if (cap != 0) return @max(2, @min(cap, n));
        // Half the cores by default: several harness instances routinely run side by side.
        return @max(2, (n + 1) / 2);
    }

    pub fn maxWorkers(self: *Pool) usize {
        if (self.max_workers_override != 0) return self.max_workers_override;
        const cap = envWorkerCap();
        if (cap != 0) return @max(2, cap);
        // Elastic IO ceiling: parked workers cost address space, not compute.
        return @max(16, cpuCountCached());
    }

    /// Post a task, spawning a worker when none is idle and the pool is below its
    /// ceiling. A post into a stopping pool is dropped.
    pub fn post(self: *Pool, task: Task) Allocator.Error!void {
        gcInstallPoolRoot();
        const a = self.allocator();
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) {
                var t = task;
                self.drop_fn(&t);
                return;
            }
            switch (task.kind) {
                .default => try self.queue_default.push(a, task),
                .io => try self.queue_io.push(a, task),
            }
            // Spawn against the backlog so an IO burst reaches the view's full width.
            const idle = self.workers.items.len - self.running;
            const backlog = self.queue_default.len() + self.queue_io.len();
            if (idle < backlog and self.workers.items.len < self.maxWorkers()) {
                // Spawn under the lock so a concurrent shutdown never sees a
                // reserved-but-unstarted handle.
                self.worker_seq += 1;
                const handle = std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, workerMain, .{ self, self.worker_seq }) catch null;
                if (handle) |h| {
                    self.workers.append(a, h) catch {
                        // Untracked worker: runs detached and exits on the stopping flag.
                        h.detach();
                    };
                } else {
                    self.worker_seq -= 1;
                }
            }
        }
        self.gate.ring();
    }

    /// Queued plus running tasks, excluding the caller's own, so `runBlocking` waits out
    /// work that could resume its coroutines.
    pub fn outstandingOther(self: *Pool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const total = self.queue_default.len() + self.queue_io.len() + self.running;
        if (in_pool_task and total > 0) return total - 1;
        return total;
    }

    pub fn takeFirstError(self: *Pool) ?RuntimeError {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.first_error;
        self.first_error = null;
        return e;
    }

    /// Run-boundary teardown: stop accepting work, ask in-flight tasks to abandon (the
    /// evaluator and host sleeps poll that flag), join every worker, drop queued tasks,
    /// reset. `first_error` survives for `takeFirstError`, read strictly after this join.
    pub fn shutdownAndJoin(self: *Pool) void {
        const a = self.allocator();
        var handles: std.ArrayList(std.Thread) = .empty;
        defer handles.deinit(a);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.workers.items.len == 0 and
                self.queue_default.len() == 0 and self.queue_io.len() == 0)
            {
                return;
            }
            self.stopping = true;
        }
        // Wake every idle worker so it observes `stopping` immediately.
        self.gate.ring();
        runtime.requestAbandon();
        defer runtime.clearAbandon();
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            handles.appendSlice(a, self.workers.items) catch {};
            self.workers.clearRetainingCapacity();
        }
        for (handles.items) |h| h.join();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue_default.pop()) |t| {
            var task = t;
            self.drop_fn(&task);
        }
        while (self.queue_io.pop()) |t| {
            var task = t;
            self.drop_fn(&task);
        }
        self.queue_default.clear(a);
        self.queue_io.clear(a);
        self.workers.deinit(a);
        self.workers = .empty;
        self.running = 0;
        self.running_default = 0;
        self.worker_seq = 0;
        self.stopping = false;
    }

    /// Take the next task in view-FIFO order under the Default cap. Caller holds the mutex.
    fn takeEligible(self: *Pool) ?Task {
        if (self.running_default < self.defaultCap()) {
            if (self.queue_default.pop()) |t| {
                self.running += 1;
                self.running_default += 1;
                return t;
            }
        }
        if (self.queue_io.pop()) |t| {
            self.running += 1;
            return t;
        }
        return null;
    }

    fn workerMain(self: *Pool, seq: usize) void {
        const tid = std.Thread.getCurrentId();
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "DefaultDispatcher-worker-{d}", .{seq}) catch "DefaultDispatcher-worker";
        runtime.setThreadName(tid, name);
        defer runtime.clearThreadName(tid);
        coroutines.gcThreadEnter();
        defer coroutines.gcThreadExit();
        defer runtime.slab.flushMagazines();
        while (true) {
            var task: Task = blk: {
                while (true) {
                    // Epoch read BEFORE the emptiness check: a post landing between the
                    // two bumps it, so the wait returns immediately.
                    const seen = self.gate.epochNow();
                    {
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        // Stopping wins over the backlog: queued daemon tasks are
                        // dropped, not run.
                        if (self.stopping) return;
                        if (self.takeEligible()) |t| break :blk t;
                    }
                    // Idle park; the 1ms cap paces the abandon poll and the wait is
                    // GC-safe.
                    self.gate.waitFrom(seen, 1_000);
                }
            };
            in_pool_task = true;
            runtime.setThreadAbandonable(true);
            const err = self.run_fn(&task);
            // An abandoned task's unwind error is the abandonment, not a failure to
            // surface.
            const abandoned = runtime.shouldAbandon();
            runtime.setThreadAbandonable(false);
            in_pool_task = false;
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.running -= 1;
                if (task.kind == .default) self.running_default -= 1;
                if (err) |e| {
                    if (!abandoned and self.first_error == null) self.first_error = e;
                }
            }
            // A freed Default cap slot may unblock a parked sibling.
            self.gate.ring();
        }
    }
};

/// Materialize a child `Vm` from the task's seed on this worker thread and run the
/// block under the posting run's modes.
fn runVmTask(task: *Task) ?RuntimeError {
    root.setCoroutineTimeMode(task.time_mode);
    runtime.setReclaim(task.reclaim);
    // The task counted as unsettled on the virtual clock at dispatch; its pump's first
    // barrier floor settles it.
    coroutines.poolTaskRunBegin();
    defer coroutines.poolTaskRunEnd();
    // The block is reachable only through this stack local now; pin it for the task.
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePush(task.block);
    // Balance the post-time retain; runs after `vm.deinit` (LIFO).
    defer if (runtime.reclaimEnabled()) task.block.release(task.seed.allocator);
    var vm = task.seed.materialize() catch {
        return .{ .Type = "failed to materialize dispatch worker Vm" };
    };
    defer vm.deinit();
    const r = vm.runThreadBlock(&task.block) catch {
        return .{ .Type = "dispatch worker out of memory" };
    };
    return switch (r) {
        .ok => null,
        .err => |e| switch (e) {
            .Return => null,
            else => blk: {
                if (runtime.procEnvGetVar(std.heap.page_allocator, "KLIO_PUMP_DIAG") catch null != null) {
                    std.debug.print("[PUMP] worker task error: {any}\n", .{e});
                }
                break :blk e;
            },
        },
    };
}

/// Drop a task that never ran; the seed's handles release through child-Vm teardown.
fn dropVmTask(task: *Task) void {
    // Release the dispatch-time unsettled count so no virtual-clock gate is held.
    coroutines.poolTaskSettleDropped();
    if (runtime.reclaimEnabled()) task.block.release(task.seed.allocator);
    var vm = task.seed.materialize() catch return;
    vm.deinit();
}

/// The process-global pool serving `Dispatchers.Default` / `IO`.
var global_pool: Pool = .{};

pub fn globalPool() *Pool {
    return &global_pool;
}

// GC root: a queued task's block is reachable only through the pool FIFO until a worker
// dequeues it; a running block is pinned by its worker's keepalive stack. Marking runs
// stop-the-world with every worker parked, so the pool mutex is uncontended here.
var pool_root_registered = std.atomic.Value(bool).init(false);

fn gcInstallPoolRoot() void {
    if (!runtime.gc.gc_enabled) return;
    if (!pool_root_registered.swap(true, .monotonic))
        runtime.gc.registerRoot(gcMarkPool);
}

fn gcMarkPool(m: *runtime.gc.Marker) void {
    global_pool.mutex.lock();
    defer global_pool.mutex.unlock();
    const qd = &global_pool.queue_default;
    for (qd.items.items[qd.head..]) |*t| t.block.gcMark(m);
    const qi = &global_pool.queue_io;
    for (qi.items.items[qi.head..]) |*t| t.block.gcMark(m);
}

pub fn post(task: Task) Allocator.Error!void {
    return global_pool.post(task);
}

pub fn outstandingOther() usize {
    return global_pool.outstandingOther();
}

pub fn shutdownAndJoin() void {
    global_pool.shutdownAndJoin();
}

pub fn takeFirstError() ?RuntimeError {
    return global_pool.takeFirstError();
}


const testing = std.testing;

var test_counter = std.atomic.Value(usize).init(0);
var test_concurrent = std.atomic.Value(usize).init(0);
var test_max_concurrent = std.atomic.Value(usize).init(0);

fn stubSeed() SendableVmSeed {
    return undefined;
}

fn noopDrop(task: *Task) void {
    _ = task;
}

fn countingRunner(task: *Task) ?RuntimeError {
    _ = task;
    const now = test_concurrent.fetchAdd(1, .acq_rel) + 1;
    var max = test_max_concurrent.load(.acquire);
    while (now > max) {
        if (test_max_concurrent.cmpxchgWeak(max, now, .acq_rel, .acquire)) |seen| {
            max = seen;
        } else break;
    }
    runtime.clockSleepMillis(2);
    _ = test_concurrent.fetchSub(1, .acq_rel);
    _ = test_counter.fetchAdd(1, .monotonic);
    return null;
}

fn stubTask(kind: Kind) Task {
    return .{
        .seed = stubSeed(),
        .block = .Unit,
        .time_mode = .Wall,
        .reclaim = false,
        .kind = kind,
    };
}

fn posterMain(pool: *Pool, n: usize, kind: Kind) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pool.post(stubTask(kind)) catch {};
    }
}

test "pool runs every task posted from many threads and joins clean" {
    var pool: Pool = .{ .run_fn = countingRunner, .drop_fn = noopDrop, .default_cap_override = 3, .max_workers_override = 6 };
    // The stub runner never touches the seed, so no queued task may remain at shutdown.
    test_counter.store(0, .release);
    test_concurrent.store(0, .release);
    test_max_concurrent.store(0, .release);

    var posters: [4]std.Thread = undefined;
    for (&posters, 0..) |*p, i| {
        const kind: Kind = if (i % 2 == 0) .default else .io;
        p.* = try std.Thread.spawn(.{}, posterMain, .{ &pool, 25, kind });
    }
    for (&posters) |p| p.join();

    var spins: usize = 0;
    while (test_counter.load(.acquire) < 100 and spins < 10_000) : (spins += 1) {
        runtime.clockSleepMillis(1);
    }
    try testing.expectEqual(@as(usize, 100), test_counter.load(.acquire));
    try testing.expectEqual(@as(usize, 0), pool.outstandingOther());

    pool.shutdownAndJoin();
    try testing.expectEqual(@as(usize, 0), pool.workers.items.len);
    try testing.expect(!pool.stopping);
}

var test_default_concurrent = std.atomic.Value(usize).init(0);
var test_default_max = std.atomic.Value(usize).init(0);
var test_default_done = std.atomic.Value(usize).init(0);

fn defaultCapRunner(task: *Task) ?RuntimeError {
    if (task.kind == .default) {
        const now = test_default_concurrent.fetchAdd(1, .acq_rel) + 1;
        var max = test_default_max.load(.acquire);
        while (now > max) {
            if (test_default_max.cmpxchgWeak(max, now, .acq_rel, .acquire)) |seen| {
                max = seen;
            } else break;
        }
        runtime.clockSleepMillis(2);
        _ = test_default_concurrent.fetchSub(1, .acq_rel);
    }
    _ = test_default_done.fetchAdd(1, .monotonic);
    return null;
}

test "default view never exceeds its cap while io tasks share the pool" {
    var pool: Pool = .{ .run_fn = defaultCapRunner, .drop_fn = noopDrop, .default_cap_override = 2, .max_workers_override = 8 };
    test_default_concurrent.store(0, .release);
    test_default_max.store(0, .release);
    test_default_done.store(0, .release);

    var i: usize = 0;
    while (i < 20) : (i += 1) try pool.post(stubTask(.default));
    i = 0;
    while (i < 10) : (i += 1) try pool.post(stubTask(.io));

    var spins: usize = 0;
    while (test_default_done.load(.acquire) < 30 and spins < 10_000) : (spins += 1) {
        runtime.clockSleepMillis(1);
    }
    try testing.expectEqual(@as(usize, 30), test_default_done.load(.acquire));
    try testing.expect(test_default_max.load(.acquire) <= 2);
    pool.shutdownAndJoin();
}

var test_order_mutex: runtime.SpinMutex = .{};
var test_order: std.ArrayList(usize) = .empty;

fn orderRunner(task: *Task) ?RuntimeError {
    test_order_mutex.lock();
    defer test_order_mutex.unlock();
    test_order.append(std.heap.page_allocator, @intCast(task.block.Int)) catch {};
    return null;
}

test "single-worker pool executes tasks in FIFO order" {
    var pool: Pool = .{ .run_fn = orderRunner, .drop_fn = noopDrop, .default_cap_override = 1, .max_workers_override = 1 };
    test_order_mutex.lock();
    test_order.clearRetainingCapacity();
    test_order_mutex.unlock();

    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        var t = stubTask(.default);
        t.block = .{ .Int = i };
        try pool.post(t);
    }
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        test_order_mutex.lock();
        const n = test_order.items.len;
        test_order_mutex.unlock();
        if (n >= 16) break;
        runtime.clockSleepMillis(1);
    }
    pool.shutdownAndJoin();
    test_order_mutex.lock();
    defer test_order_mutex.unlock();
    try testing.expectEqual(@as(usize, 16), test_order.items.len);
    for (test_order.items, 0..) |v, idx| {
        try testing.expectEqual(@as(usize, idx), @as(usize, @intCast(v)));
    }
}

test "shutdown drops queued tasks and resets for reuse" {
    var pool: Pool = .{ .run_fn = countingRunner, .drop_fn = noopDrop, .default_cap_override = 1, .max_workers_override = 1 };
    try pool.post(stubTask(.default));
    pool.shutdownAndJoin();
    try testing.expect(!pool.stopping);
    test_counter.store(0, .release);
    try pool.post(stubTask(.io));
    var spins: usize = 0;
    while (test_counter.load(.acquire) < 1 and spins < 10_000) : (spins += 1) {
        runtime.clockSleepMillis(1);
    }
    try testing.expectEqual(@as(usize, 1), test_counter.load(.acquire));
    pool.shutdownAndJoin();
}

test {
    testing.refAllDecls(@This());
}
