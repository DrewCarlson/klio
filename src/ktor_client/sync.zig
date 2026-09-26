//! Locks and condition variables for the ktor natives' threads: pthreads on
//! POSIX systems, slim reader/writer locks and condition variables on
//! Windows. Both start from a zero value and need no teardown.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

const is_windows = builtin.os.tag == .windows;

const win = struct {
    const SRWLOCK = std.os.windows.SRWLOCK;
    const CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE;
    const INFINITE: u32 = 0xFFFF_FFFF;

    extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn TryAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) u8;
    extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn SleepConditionVariableSRW(cv: *CONDITION_VARIABLE, lock: *SRWLOCK, ms: u32, flags: u32) callconv(.winapi) i32;
    extern "kernel32" fn WakeAllConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;
};

/// A plain mutual-exclusion lock.
pub const Lock = struct {
    raw: if (is_windows) win.SRWLOCK else std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Lock) void {
        if (is_windows) win.AcquireSRWLockExclusive(&self.raw) else _ = std.c.pthread_mutex_lock(&self.raw);
    }

    pub fn tryLock(self: *Lock) bool {
        if (is_windows) return win.TryAcquireSRWLockExclusive(&self.raw) != 0;
        return std.c.pthread_mutex_trylock(&self.raw) == .SUCCESS;
    }

    pub fn unlock(self: *Lock) void {
        if (is_windows) win.ReleaseSRWLockExclusive(&self.raw) else _ = std.c.pthread_mutex_unlock(&self.raw);
    }
};

/// A condition variable used with a `Lock`.
pub const Cond = struct {
    raw: if (is_windows) win.CONDITION_VARIABLE else std.c.pthread_cond_t = .{},

    /// Releases `l`, waits for a broadcast (or a spurious wakeup) and takes
    /// `l` again.
    pub fn wait(self: *Cond, l: *Lock) void {
        if (is_windows) {
            _ = win.SleepConditionVariableSRW(&self.raw, &l.raw, win.INFINITE, 0);
        } else {
            _ = std.c.pthread_cond_wait(&self.raw, &l.raw);
        }
    }

    pub fn broadcast(self: *Cond) void {
        if (is_windows) win.WakeAllConditionVariable(&self.raw) else _ = std.c.pthread_cond_broadcast(&self.raw);
    }
};

/// A lock taken from interpreter threads. Waiting for it counts as blocking
/// for the collector, so a collection never waits on a thread parked here.
pub const Mutex = struct {
    l: Lock = .{},

    pub fn lock(self: *Mutex) void {
        if (self.l.tryLock()) return;
        runtime.gc.enterBlockingSafe();
        self.l.lock();
        runtime.gc.exitBlockingSafe();
    }

    pub fn unlock(self: *Mutex) void {
        self.l.unlock();
    }
};

const testing = std.testing;

test "a condition wakes a waiter once the state it waits for is set" {
    const Shared = struct {
        l: Lock = .{},
        cv: Cond = .{},
        ready: bool = false,
        seen: bool = false,

        fn waiter(s: *@This()) void {
            s.l.lock();
            defer s.l.unlock();
            while (!s.ready) s.cv.wait(&s.l);
            s.seen = true;
        }
    };
    var s: Shared = .{};
    const t = try std.Thread.spawn(.{}, Shared.waiter, .{&s});
    s.l.lock();
    s.ready = true;
    s.cv.broadcast();
    s.l.unlock();
    t.join();
    try testing.expect(s.seen);
}

test "a held lock refuses tryLock until it is released" {
    var l: Lock = .{};
    l.lock();
    const Other = struct {
        fn attempt(lk: *Lock, out: *bool) void {
            out.* = lk.tryLock();
            if (out.*) lk.unlock();
        }
    };
    var got = true;
    const t = try std.Thread.spawn(.{}, Other.attempt, .{ &l, &got });
    t.join();
    try testing.expect(!got);
    l.unlock();
    try testing.expect(l.tryLock());
    l.unlock();
}
