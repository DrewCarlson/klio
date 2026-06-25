//! Cross-thread runtime registries shared by every interpreter layer:
//! per-OS-thread display-name overrides (dispatcher worker threads
//! report upstream-shaped names through `Thread.currentThread().name`)
//! and run-boundary cleanup hooks (a layer that keeps process-global
//! state keyed into a run's value graph registers a sweep here so the
//! run boundary empties it before the run arena is reset).

const std = @import("std");
const objcell = @import("objcell.zig");

const SpinMutex = objcell.SpinMutex;

/// Allocator backing the process-global registries; the spines live for
/// the whole process, entries are bounded by live threads / hooks.
fn registryAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

// -------------------------------------------------------------------------
// Thread display names.
// -------------------------------------------------------------------------

var names_mutex: SpinMutex = .{};
var names: ?std.AutoHashMap(u64, []const u8) = null;

/// Register a display name for the OS thread `id`. The name bytes are
/// copied into the registry. A worker registers on entry and clears on
/// exit (`clearThreadName`) so a recycled OS thread id never reports a
/// stale name.
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

/// Drop the display name registered for `id`, if any.
pub fn clearThreadName(id: u64) void {
    names_mutex.lock();
    defer names_mutex.unlock();
    if (names) |*m| {
        if (m.fetchRemove(id)) |kv| registryAllocator().free(kv.value);
    }
}

/// The display name registered for `id`, copied into `allocator`-owned
/// bytes, or `null` when the thread has no override.
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

// -------------------------------------------------------------------------
// Daemon-task abandonment.
//
// Dispatcher pool tasks are daemons (upstream `GlobalScope` semantics):
// the run boundary does not wait for them. A task still in flight when
// the pool shuts down is asked to stop through this flag; the evaluator
// and the host sleep primitives poll it on abandonable threads and abort
// the task cooperatively, so the pool can join its workers without
// waiting out (or hanging on) a daemon body.
// -------------------------------------------------------------------------

/// Process-global "abandon in-flight daemon tasks now" request, set for
/// the duration of the pool's run-boundary shutdown.
var abandon_requested = std.atomic.Value(bool).init(false);

/// `true` on threads whose current work may be abandoned (dispatcher
/// pool workers running a task). Never set on the main thread or on
/// explicit `kotlin.concurrent.thread` workers, which are always joined.
threadlocal var thread_abandonable: bool = false;

/// Mark the calling thread's current work abandonable (dispatcher pool
/// task execution) or not.
pub fn setThreadAbandonable(on: bool) void {
    thread_abandonable = on;
}

/// Whether the calling thread's current work is abandonable.
pub fn isThreadAbandonable() bool {
    return thread_abandonable;
}

/// Optional hook the coroutine layer installs to be told the calling thread
/// is about to block in a real wall sleep (`Thread.sleep`). A dispatched pool
/// task doing wall work is not advancing the cooperative virtual clock, so the
/// hook settles its virtual-clock "unsettled" count, letting a top-level
/// driver advance virtual time without waiting out the wall sleep. `null`
/// until installed; a no-op for every non-coroutine build.
var wall_block_hook: ?*const fn () void = null;

pub fn setWallBlockHook(hook: *const fn () void) void {
    wall_block_hook = hook;
}

/// Notify the installed hook (if any) that this thread is entering a wall
/// sleep. Cheap when no hook is installed.
pub fn notifyWallBlock() void {
    if (wall_block_hook) |h| h();
}

/// Ask every abandonable thread to abort its current task.
pub fn requestAbandon() void {
    abandon_requested.store(true, .release);
}

/// Withdraw the abandon request (the pool finished its shutdown).
pub fn clearAbandon() void {
    abandon_requested.store(false, .release);
}

/// Whether the calling thread should abort its current task: it is
/// abandonable and the run boundary has requested abandonment. The
/// threadlocal gate keeps the check free for every non-pool thread.
pub fn shouldAbandon() bool {
    if (!thread_abandonable) return false;
    return abandon_requested.load(.acquire);
}

// -------------------------------------------------------------------------
// Run-boundary sweep hooks.
// -------------------------------------------------------------------------

const Hook = *const fn () void;

var hooks_mutex: SpinMutex = .{};
var hooks: ?std.ArrayList(Hook) = null;

/// Register a cleanup hook to run at every run boundary (after all
/// worker threads have joined, before the run arena can be reset).
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

/// Invoke every registered run-boundary hook. Called exactly once per
/// run from the top-level driver thread after every worker has joined.
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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
