//! Cross-thread registries: per-OS-thread display names, the daemon-task
//! abandonment flags, and run-boundary cleanup hooks a layer registers so the
//! boundary empties its state before the run arena resets.

const std = @import("std");
const objcell = @import("objcell.zig");

const SpinMutex = objcell.SpinMutex;

/// The spines live for the whole process.
fn registryAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}


var names_mutex: SpinMutex = .{};
var names: ?std.AutoHashMap(u64, []const u8) = null;

/// The bytes are copied. A worker registers on entry and clears on exit, so a
/// recycled OS thread id never reports a stale name.
pub fn setThreadName(id: u64, name: []const u8) void {
    const a = registryAllocator();
    const copy = a.dupe(u8, name) catch return;
    names_mutex.lock();
    defer names_mutex.unlock();
    if (names == null) names = std.AutoHashMap(u64, []const u8).init(a);
    const gop = names.?.getOrPut(id) catch {
        a.free(copy);
        return;
    };
    if (gop.found_existing) a.free(gop.value_ptr.*);
    gop.value_ptr.* = copy;
}

/// The JVM's thread counter. A `Thread` made without a name takes
/// "Thread-N" from it, and Kotlin's `thread { }` makes one before it names
/// it, so every `thread { }` takes a number.
var thread_number = std.atomic.Value(u64).init(0);

pub fn nextThreadNumber() u64 {
    registerRunBoundaryHook(resetThreadNumber);
    return thread_number.fetchAdd(1, .monotonic);
}

fn resetThreadNumber() void {
    thread_number.store(0, .monotonic);
}

/// The OS thread running the program's `main`, the JVM's "main" thread; 0
/// outside a run.
var program_thread = std.atomic.Value(u64).init(0);

pub fn setProgramThread(id: u64) void {
    program_thread.store(id, .release);
}

/// Whether the calling thread runs the program's `main`: the thread
/// `Dispatchers.Main` confines its coroutines to.
pub fn onProgramThread() bool {
    const t = program_thread.load(.acquire);
    return t != 0 and t == @as(u64, std.Thread.getCurrentId());
}

pub fn clearThreadName(id: u64) void {
    names_mutex.lock();
    defer names_mutex.unlock();
    if (names) |*m| {
        if (m.fetchRemove(id)) |kv| registryAllocator().free(kv.value);
    }
}

/// Copied into `allocator`-owned bytes.
pub fn threadName(allocator: std.mem.Allocator, id: u64) ?[]const u8 {
    names_mutex.lock();
    defer names_mutex.unlock();
    if (names) |*m| {
        if (m.get(id)) |n| {
            return allocator.dupe(u8, n) catch null;
        }
    }
    return null;
}

// Daemon-task abandonment. Dispatcher pool tasks are daemons, so the run
// boundary does not wait for them: an in-flight task is asked to stop through
// this flag, which the evaluator and the sleep primitives poll.

/// Set for the duration of the pool's run-boundary shutdown.
var abandon_requested = std.atomic.Value(bool).init(false);

/// Never set on the main thread or on explicit `kotlin.concurrent.thread`
/// workers, which are always joined.
threadlocal var thread_abandonable: bool = false;

pub fn setThreadAbandonable(on: bool) void {
    thread_abandonable = on;
}

pub fn isThreadAbandonable() bool {
    return thread_abandonable;
}

/// Hooks the coroutine layer installs to hear that this thread enters and
/// leaves a real `Thread.sleep`. A sleeping thread advances no cooperative
/// virtual clock, so it releases its hold on it for the length of the sleep.
var wall_block_hook: ?*const fn () void = null;
var wall_unblock_hook: ?*const fn () void = null;

pub fn setWallBlockHooks(block: *const fn () void, unblock: *const fn () void) void {
    wall_unblock_hook = unblock;
    wall_block_hook = block;
}

pub fn notifyWallBlock() void {
    if (wall_block_hook) |h| h();
}

pub fn notifyWallUnblock() void {
    if (wall_unblock_hook) |h| h();
}

pub fn requestAbandon() void {
    abandon_requested.store(true, .release);
}

pub fn clearAbandon() void {
    abandon_requested.store(false, .release);
}

/// Run-boundary hard stop: every thread still executing user code, including
/// explicit `kotlin.concurrent.thread` workers that are otherwise never
/// abandonable, must stop, or a leaked spinning thread hangs the final join.
var run_boundary_abandon = std.atomic.Value(bool).init(false);

pub fn setRunBoundaryAbandon(on: bool) void {
    run_boundary_abandon.store(on, .release);
}

/// The test runner consults this after a test to know a wall-cap abort fired
/// and a grace drain is needed.
pub fn runBoundaryAbandonActive() bool {
    return run_boundary_abandon.load(.acquire);
}

/// True when abandonment is requested and the thread is either abandonable or
/// the boundary is draining.
///
/// The request flag is read first because it is a plain global and the other
/// two are not: `thread_abandonable` is threadlocal, and on Darwin every read
/// of it is a `_tlv_get_addr` call. This guard runs on every branch and back
/// edge the evaluator takes, and abandonment is off for all but the last
/// instants of a run, so the ordinary answer is one load, inline.
pub inline fn shouldAbandon() bool {
    if (!abandon_requested.load(.monotonic)) return false;
    return shouldAbandonRequested();
}

fn shouldAbandonRequested() bool {
    if (!abandon_requested.load(.acquire)) return false;
    return thread_abandonable or run_boundary_abandon.load(.acquire);
}

/// Raw flag addresses for the transpiled hot path's inlined edge guard.
/// `thread_abandonable` is threadlocal, so the pointer is valid only on the
/// fetching thread and is refreshed per activation entry.
pub fn abandonablePtr() *const bool {
    return &thread_abandonable;
}
pub fn runBoundaryAbandonPtr() *const bool {
    return &run_boundary_abandon.raw;
}
pub fn abandonRequestedPtr() *const bool {
    return &abandon_requested.raw;
}


const Hook = *const fn () void;

var hooks_mutex: SpinMutex = .{};
var hooks: ?std.ArrayList(Hook) = null;

/// Runs after all workers have joined and before the run arena resets.
/// Registering the same function twice is a no-op.
pub fn registerRunBoundaryHook(hook: Hook) void {
    hooks_mutex.lock();
    defer hooks_mutex.unlock();
    if (hooks == null) hooks = .empty;
    for (hooks.?.items) |h| {
        if (h == hook) return;
    }
    hooks.?.append(registryAllocator(), hook) catch {};
}

/// Called once per run, after every worker has joined.
pub fn runBoundarySweep() void {
    const snapshot = blk: {
        hooks_mutex.lock();
        defer hooks_mutex.unlock();
        const list = hooks orelse break :blk &[_]Hook{};
        break :blk registryAllocator().dupe(Hook, list.items) catch &[_]Hook{};
    };
    defer if (snapshot.len != 0) registryAllocator().free(snapshot);
    for (snapshot) |h| h();
}


const testing = std.testing;

test "thread name registry set / read / clear round-trip" {
    const id: u64 = 0xfff1;
    setThreadName(id, "DefaultDispatcher-worker-1");
    const got = threadName(testing.allocator, id);
    try testing.expect(got != null);
    defer testing.allocator.free(got.?);
    try testing.expectEqualStrings("DefaultDispatcher-worker-1", got.?);
    clearThreadName(id);
    try testing.expectEqual(@as(?[]const u8, null), threadName(testing.allocator, id));
}

test "thread name re-registration replaces the old name" {
    const id: u64 = 0xfff2;
    setThreadName(id, "a");
    setThreadName(id, "b");
    const got = threadName(testing.allocator, id);
    try testing.expect(got != null);
    defer testing.allocator.free(got.?);
    try testing.expectEqualStrings("b", got.?);
    clearThreadName(id);
}

var hook_fires: u32 = 0;

fn testHook() void {
    hook_fires += 1;
}

test "run boundary hooks register once and fire per sweep" {
    registerRunBoundaryHook(testHook);
    registerRunBoundaryHook(testHook);
    const before = hook_fires;
    runBoundarySweep();
    try testing.expectEqual(before + 1, hook_fires);
}
