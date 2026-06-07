//! Real-OS-thread stress + ordering tests for `ObjRef`'s publish protocol
//! (port of crates/klio-runtime/tests/objref_threads.rs). Exercises the
//! actual `std`-backed adaptive cell across genuine threads through the
//! public `runtime` module API.
//!
//! `ObjRef` does its own ref-counted heap allocation/free, so these use the
//! leak-checking testing allocator directly (no pipeline arena involved):
//! every cell is freed when its last handle drops.

const std = @import("std");
const runtime = @import("runtime");

const ObjRef = runtime.ObjRef;

const THREADS: usize = 8;
const PUSHES_PER_THREAD: usize = 2_000;

const IntList = struct {
    items: std.ArrayList(i32) = .empty,
    // `pub` so the generic `ObjRef` in the runtime module can see this via
    // `@hasDecl` and run it when the last handle drops (a non-`pub` decl is
    // invisible across the module boundary).
    pub fn deinit(self: *IntList, allocator: std.mem.Allocator) void {
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
        // Release this worker's clone of the shared handle.
        self.obj.deinit();
    }
};

// After `publish()`, N threads hammer the same shared `ObjRef` with
// interleaved `borrowMut().append(..)` and `borrow()` reads. The lock must
// serialize every access: the final length equals the exact total of pushes
// and every element is one we pushed (no corruption, no lost write).
test "shared objref concurrent push is consistent" {
    const allocator = std.testing.allocator;
    const obj = try ObjRef(IntList).init(allocator, .{});
    defer obj.deinit();
    // Publish before the handle escapes to any other thread.
    obj.publish();
    try std.testing.expect(obj.isShared());

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

    const g = obj.borrow();
    defer g.deinit();
    try std.testing.expectEqual(THREADS * PUSHES_PER_THREAD, g.get().items.items.len);

    // Every value in [0, THREADS*PUSHES) must appear exactly once.
    var seen = try allocator.alloc(bool, THREADS * PUSHES_PER_THREAD);
    defer allocator.free(seen);
    @memset(seen, false);
    for (g.get().items.items) |v| {
        const idx: usize = @intCast(v);
        try std.testing.expect(idx < seen.len); // not corrupted
        try std.testing.expect(!seen[idx]); // not duplicated (no lost/torn write)
        seen[idx] = true;
    }
    for (seen) |b| try std.testing.expect(b); // no missing elements
}

const HandoffWriter = struct {
    slot: *?ObjRef(IntList),
    ready: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    fn run(self: HandoffWriter) void {
        const obj = ObjRef(IntList).init(self.allocator, .{}) catch unreachable;
        {
            const g = obj.borrowMut();
            defer g.deinit();
            var i: i32 = 0;
            while (i < 64) : (i += 1) g.get().items.append(self.allocator, i) catch unreachable;
        }
        obj.publish();
        self.slot.* = obj;
        // Release store hands the published handle to the reader.
        self.ready.store(true, .release);
    }
};

const HandoffReader = struct {
    slot: *?ObjRef(IntList),
    ready: *std.atomic.Value(bool),

    fn run(self: HandoffReader) void {
        while (!self.ready.load(.acquire)) std.atomic.spinLoopHint();
        const obj = self.slot.*.?;
        const g = obj.borrow();
        defer g.deinit();
        std.debug.assert(g.get().items.items.len == 64);
        for (g.get().items.items, 0..) |v, i| {
            // Never a partial pre-publish write.
            std.debug.assert(v == @as(i32, @intCast(i)));
        }
    }
};

// Publish-then-handoff ordering: the writing thread mutates the value,
// `publish()`es, then hands the handle to a reader thread. The reader (which
// only sees the handle *after* publish) must observe the fully-written
// value, never a partial state.
test "publish then handoff orders the write" {
    const allocator = std.testing.allocator;
    const ROUNDS: usize = 200;

    var round: usize = 0;
    while (round < ROUNDS) : (round += 1) {
        var slot: ?ObjRef(IntList) = null;
        var ready = std.atomic.Value(bool).init(false);

        const writer = try std.Thread.spawn(.{}, HandoffWriter.run, .{HandoffWriter{
            .slot = &slot,
            .ready = &ready,
            .allocator = allocator,
        }});
        const reader = try std.Thread.spawn(.{}, HandoffReader.run, .{HandoffReader{
            .slot = &slot,
            .ready = &ready,
        }});
        writer.join();
        reader.join();

        slot.?.deinit();
    }
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
        self.obj.deinit();
    }
};

// Many threads each clone the shared handle and do a read/modify under the
// lock; an atomic side-counter cross-checks that exactly the expected number
// of mutations were applied.
test "shared objref read modify counter" {
    const allocator = std.testing.allocator;
    const obj = try ObjRef(i64).init(allocator, 0);
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

    const total: i64 = @intCast(THREADS * PUSHES_PER_THREAD);
    {
        const g = obj.borrow();
        defer g.deinit();
        try std.testing.expectEqual(total, g.get().*); // no lost increment under lock
    }
    try std.testing.expectEqual(THREADS * PUSHES_PER_THREAD, applied.load(.monotonic));
}
