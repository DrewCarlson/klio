//! The host operating system beneath the runtime: clocks and sleeping, a
//! mutex and condition variable, anonymous virtual memory, threads whose
//! stack is reserved rather than committed, the running executable's path,
//! shared libraries and a termination hook. POSIX hosts go through libc;
//! Windows goes through kernel32.
//!
//! Windows differences a caller sees:
//! - `sleepNs` and `Cond.timedWait` have millisecond granularity. The first
//!   use raises the process timer resolution to 1 ms (`timeBeginPeriod`), so
//!   a 1 ms wait is about 1 ms rather than the default 15.6 ms tick.
//! - `unmap` of part of a mapping decommits that part; the reservation is
//!   released once none of it is committed, as a POSIX `munmap` of the last
//!   piece would release the address range.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

/// Whether `Mutex` and `Cond` block in the OS. Without libc on a POSIX host
/// the callers fall back to spinning and yielding.
pub const has_os_sync = is_windows or (builtin.link_libc and !builtin.single_threaded);

/// kernel32 and winmm, declared with plain integer types.
pub const win = struct {
    pub const BOOL = c_int;
    pub const HANDLE = *anyopaque;
    pub const INFINITE: u32 = 0xFFFF_FFFF;

    pub const MEM_COMMIT: u32 = 0x1000;
    pub const MEM_RESERVE: u32 = 0x2000;
    pub const MEM_DECOMMIT: u32 = 0x4000;
    pub const MEM_RELEASE: u32 = 0x8000;
    pub const PAGE_NOACCESS: u32 = 0x01;
    pub const PAGE_READWRITE: u32 = 0x04;

    pub const STACK_SIZE_PARAM_IS_A_RESERVATION: u32 = 0x0001_0000;
    pub const FIBER_FLAG_FLOAT_SWITCH: u32 = 0x1;
    pub const ERROR_ALREADY_FIBER: u32 = 1280;
    pub const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;

    pub const FILETIME = extern struct { low: u32, high: u32 };
    pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
    pub const CONDITION_VARIABLE = extern struct { ptr: ?*anyopaque = null };
    pub const MEMORY_BASIC_INFORMATION = extern struct {
        BaseAddress: ?*anyopaque,
        AllocationBase: ?*anyopaque,
        AllocationProtect: u32,
        PartitionId: u16,
        RegionSize: usize,
        State: u32,
        Protect: u32,
        Type: u32,
    };

    pub const ThreadProc = *const fn (?*anyopaque) callconv(.winapi) u32;
    pub const FiberProc = *const fn (?*anyopaque) callconv(.winapi) void;
    pub const CtrlHandler = *const fn (u32) callconv(.winapi) BOOL;

    pub extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetSystemTimePreciseAsFileTime(ft: *FILETIME) callconv(.winapi) void;
    pub extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    pub extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

    pub extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn VirtualFree(addr: *anyopaque, size: usize, kind: u32) callconv(.winapi) BOOL;
    pub extern "kernel32" fn VirtualQuery(addr: ?*const anyopaque, info: *MEMORY_BASIC_INFORMATION, len: usize) callconv(.winapi) usize;

    pub extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
    pub extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
    pub extern "kernel32" fn SleepConditionVariableSRW(cv: *CONDITION_VARIABLE, lock: *SRWLOCK, ms: u32, flags: u32) callconv(.winapi) BOOL;
    pub extern "kernel32" fn WakeAllConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;
    pub extern "kernel32" fn WakeConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;

    pub extern "kernel32" fn CreateThread(attrs: ?*anyopaque, stack: usize, start: ThreadProc, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
    pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;

    pub extern "kernel32" fn ConvertThreadToFiber(param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn ConvertFiberToThread() callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateFiberEx(commit: usize, reserve: usize, flags: u32, start: FiberProc, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn SwitchToFiber(fiber: *anyopaque) callconv(.winapi) void;
    pub extern "kernel32" fn DeleteFiber(fiber: *anyopaque) callconv(.winapi) void;

    pub extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, buf: [*]u16, len: u32) callconv(.winapi) u32;
    pub extern "kernel32" fn LoadLibraryExW(path: [*:0]const u16, file: ?HANDLE, flags: u32) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GetProcAddress(module: HANDLE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn FreeLibrary(module: HANDLE) callconv(.winapi) BOOL;

    pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?CtrlHandler, add: BOOL) callconv(.winapi) BOOL;

    pub const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
    };
    pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    pub extern "kernel32" fn GetProcessTimes(process: HANDLE, created: *FILETIME, exited: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) BOOL;
    pub extern "kernel32" fn K32GetProcessMemoryInfo(process: HANDLE, counters: *PROCESS_MEMORY_COUNTERS, cb: u32) callconv(.winapi) BOOL;

    pub const GENERIC_READ: u32 = 0x8000_0000;
    pub const FILE_SHARE_READ: u32 = 0x1;
    pub const FILE_SHARE_DELETE: u32 = 0x4;
    pub const OPEN_EXISTING: u32 = 3;
    pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    pub const PAGE_READONLY: u32 = 0x02;
    pub const FILE_MAP_READ: u32 = 0x4;
    pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    pub const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: u32,
        OffsetHigh: u32,
        hEvent: ?HANDLE,
    };
    pub extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn GetFileSizeEx(file: HANDLE, size: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn ReadFile(file: HANDLE, buf: [*]u8, len: u32, read: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateFileMappingW(file: HANDLE, security: ?*anyopaque, protect: u32, size_high: u32, size_low: u32, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn MapViewOfFile(mapping: HANDLE, access: u32, offset_high: u32, offset_low: u32, len: usize) callconv(.winapi) ?*anyopaque;

    pub extern "winmm" fn timeBeginPeriod(ms: u32) callconv(.winapi) u32;

    /// The fiber running on this thread, when it is one (`GetCurrentFiber`).
    pub fn currentFiber() ?*anyopaque {
        return std.os.windows.teb().NtTib.DUMMYUNIONNAME.FiberData;
    }
};

// ---------------------------------------------------------------- clocks

var qpc_freq = std.atomic.Value(i64).init(0);

fn qpcFrequency() i64 {
    const cached = qpc_freq.load(.monotonic);
    if (cached != 0) return cached;
    var f: i64 = 0;
    if (win.QueryPerformanceFrequency(&f) == 0 or f <= 0) f = 1;
    qpc_freq.store(f, .monotonic);
    return f;
}

/// Nanoseconds on a clock that never goes back; only differences mean
/// anything. Null when the host has no such clock reachable here.
pub fn monotonicNs() ?u64 {
    if (comptime is_windows) {
        var c: i64 = 0;
        if (win.QueryPerformanceCounter(&c) == 0 or c < 0) return null;
        const f = qpcFrequency();
        const whole: u64 = @intCast(@divTrunc(c, f));
        const part: u64 = @intCast(@divTrunc(@rem(c, f) * std.time.ns_per_s, f));
        return whole * std.time.ns_per_s + part;
    }
    if (comptime !builtin.link_libc) return null;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return null;
    const ns = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    if (ns < 0) return null;
    return @intCast(@min(ns, std.math.maxInt(u64)));
}

/// Nanoseconds since the Unix epoch, or null where no wall clock is
/// reachable here.
pub fn realtimeNs() ?i128 {
    if (comptime is_windows) {
        var ft: win.FILETIME = undefined;
        win.GetSystemTimePreciseAsFileTime(&ft);
        // 100 ns ticks since 1601-01-01; the Unix epoch is 11644473600 s later.
        const ticks: i128 = (@as(i128, ft.high) << 32) | ft.low;
        return (ticks - 116_444_736_000_000_000) * 100;
    }
    if (comptime !builtin.link_libc) return null;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

var timer_resolution_raised = std.atomic.Value(bool).init(false);

/// Windows waits round up to the system timer tick, 15.6 ms by default; the
/// runtime's idle loops wait about a millisecond at a time.
fn raiseTimerResolution() void {
    if (comptime !is_windows) return;
    if (timer_resolution_raised.load(.monotonic)) return;
    if (timer_resolution_raised.swap(true, .acq_rel)) return;
    _ = win.timeBeginPeriod(1);
}

/// Sleeps the calling thread about `ns`; false where the host has no sleep
/// reachable here (the caller then sleeps through `std.Io`). Windows sleeps
/// whole milliseconds, rounding up.
pub fn sleepNs(ns: u64) bool {
    if (comptime is_windows) {
        raiseTimerResolution();
        const ms = std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable;
        win.Sleep(@intCast(@min(ms, win.INFINITE - 1)));
        return true;
    }
    if (comptime !builtin.link_libc) return false;
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
    return true;
}

// ---------------------------------------------------------------- mutex, condition

/// An OS mutex: a pthread mutex, or a slim reader/writer lock held
/// exclusively on Windows. Zero-initialised; never moved while in use.
pub const Mutex = struct {
    impl: Impl = .{},

    const Impl = if (is_windows) win.SRWLOCK else if (has_os_sync) std.c.pthread_mutex_t else struct {};

    pub fn lock(self: *Mutex) void {
        if (comptime is_windows) return win.AcquireSRWLockExclusive(&self.impl);
        if (comptime has_os_sync) _ = std.c.pthread_mutex_lock(&self.impl);
    }

    pub fn unlock(self: *Mutex) void {
        if (comptime is_windows) return win.ReleaseSRWLockExclusive(&self.impl);
        if (comptime has_os_sync) _ = std.c.pthread_mutex_unlock(&self.impl);
    }
};

/// A condition variable used with one `Mutex`. Waits may return early; the
/// caller re-checks its condition.
pub const Cond = struct {
    impl: Impl = .{},

    const Impl = if (is_windows) win.CONDITION_VARIABLE else if (has_os_sync) std.c.pthread_cond_t else struct {};

    pub fn wait(self: *Cond, m: *Mutex) void {
        if (comptime is_windows) {
            _ = win.SleepConditionVariableSRW(&self.impl, &m.impl, win.INFINITE, 0);
            return;
        }
        if (comptime has_os_sync) _ = std.c.pthread_cond_wait(&self.impl, &m.impl);
    }

    /// Waits at most `timeout_ns`; Windows rounds up to whole milliseconds.
    pub fn timedWait(self: *Cond, m: *Mutex, timeout_ns: u64) void {
        if (comptime is_windows) {
            raiseTimerResolution();
            const ms = std.math.divCeil(u64, timeout_ns, std.time.ns_per_ms) catch unreachable;
            _ = win.SleepConditionVariableSRW(&self.impl, &m.impl, @intCast(@min(ms, win.INFINITE - 1)), 0);
            return;
        }
        if (comptime !has_os_sync) return;
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const add_ns: i128 = @as(i128, ts.nsec) + timeout_ns;
        ts.sec += @intCast(@divFloor(add_ns, std.time.ns_per_s));
        ts.nsec = @intCast(@mod(add_ns, std.time.ns_per_s));
        _ = std.c.pthread_cond_timedwait(&self.impl, &m.impl, &ts);
    }

    pub fn broadcast(self: *Cond) void {
        if (comptime is_windows) return win.WakeAllConditionVariable(&self.impl);
        if (comptime has_os_sync) _ = std.c.pthread_cond_broadcast(&self.impl);
    }

    pub fn signal(self: *Cond) void {
        if (comptime is_windows) return win.WakeConditionVariable(&self.impl);
        if (comptime has_os_sync) _ = std.c.pthread_cond_signal(&self.impl);
    }
};

// ---------------------------------------------------------------- virtual memory

pub const page_align = std.heap.page_size_min;

/// `len` bytes of fresh, zeroed, read-write memory, page aligned.
pub fn map(len: usize) ?[*]align(page_align) u8 {
    if (comptime is_windows) {
        const p = win.VirtualAlloc(null, len, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE) orelse return null;
        return @ptrCast(@alignCast(p));
    }
    const m = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
    return m.ptr;
}

/// Serialises the Windows decommit-then-maybe-release step, so the release
/// test sees a reservation no other unmap is changing.
var win_unmap_lock: Mutex = .{};

/// Gives back `[ptr, ptr+len)`, all or part of one `map` or `mapAligned`
/// result.
pub fn unmap(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    if (comptime is_windows) {
        win_unmap_lock.lock();
        defer win_unmap_lock.unlock();
        _ = win.VirtualFree(@ptrCast(ptr), len, win.MEM_DECOMMIT);
        releaseIfDecommitted(ptr);
        return;
    }
    const aligned: [*]align(page_align) u8 = @alignCast(ptr);
    std.posix.munmap(aligned[0..len]);
}

/// Releases the reservation holding `addr` when none of it is committed:
/// its first region is reserved-only and runs to the reservation's end.
fn releaseIfDecommitted(addr: [*]u8) void {
    var info: win.MEMORY_BASIC_INFORMATION = undefined;
    if (win.VirtualQuery(addr, &info, @sizeOf(win.MEMORY_BASIC_INFORMATION)) == 0) return;
    const base = info.AllocationBase orelse return;
    if (win.VirtualQuery(base, &info, @sizeOf(win.MEMORY_BASIC_INFORMATION)) == 0) return;
    if (info.State != win.MEM_RESERVE) return;
    const end = @intFromPtr(base) + info.RegionSize;
    var next: win.MEMORY_BASIC_INFORMATION = undefined;
    if (win.VirtualQuery(@ptrFromInt(end), &next, @sizeOf(win.MEMORY_BASIC_INFORMATION)) != 0 and next.AllocationBase == base) return;
    _ = win.VirtualFree(base, 0, win.MEM_RELEASE);
}

/// `len` bytes of fresh read-write memory starting at a multiple of
/// `alignment` (a power of two at least a page); its address. POSIX maps
/// `len + alignment` and trims the ends. Windows cannot trim a reservation,
/// so it finds an aligned address in a probe reservation, releases the probe
/// and maps exactly there, retrying if another thread took the range first.
pub fn mapAligned(len: usize, alignment: usize) ?usize {
    if (comptime is_windows) {
        var attempts: usize = 0;
        while (attempts < 64) : (attempts += 1) {
            const probe = win.VirtualAlloc(null, len + alignment, win.MEM_RESERVE, win.PAGE_NOACCESS) orelse return null;
            const aligned = std.mem.alignForward(usize, @intFromPtr(probe), alignment);
            _ = win.VirtualFree(probe, 0, win.MEM_RELEASE);
            if (win.VirtualAlloc(@ptrFromInt(aligned), len, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)) |p| return @intFromPtr(p);
        }
        return null;
    }
    const over = map(len + alignment) orelse return null;
    const base = @intFromPtr(over);
    const aligned = std.mem.alignForward(usize, base, alignment);
    const head = aligned - base;
    if (head != 0) unmap(over, head);
    const tail = (base + len + alignment) - (aligned + len);
    if (tail != 0) unmap(@ptrFromInt(aligned + len), tail);
    return aligned;
}

/// Returns the resident pages of `[addr, addr+len)` to the OS while the range
/// stays mapped, zero-filled on the next touch. POSIX overlays a fresh
/// anonymous mapping (on macOS `madvise` leaves the pages resident until
/// memory runs short); Windows decommits and recommits, which leaves
/// demand-zero pages.
pub fn discard(addr: usize, len: usize) void {
    if (len == 0) return;
    if (comptime is_windows) {
        _ = win.VirtualFree(@ptrFromInt(addr), len, win.MEM_DECOMMIT);
        _ = win.VirtualAlloc(@ptrFromInt(addr), len, win.MEM_COMMIT, win.PAGE_READWRITE);
        return;
    }
    const p: [*]align(page_align) u8 = @ptrFromInt(addr);
    _ = std.posix.mmap(p, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0) catch {};
}

// ---------------------------------------------------------------- threads

/// The stack of a thread that runs a few frames of host code (unmapping,
/// freeing arenas). glibc carves the thread's static TLS block out of its
/// stack and refuses a stack that cannot hold that block plus its minimum
/// (128 KB on aarch64); the runtime's `threadlocal` state is large, and
/// `std.Thread.spawn` treats the refusal as unreachable. The stack is
/// address space until it is touched.
pub const small_thread_stack: usize = 1024 * 1024;

/// A thread whose stack is `stack_size` bytes of address space. On Windows
/// the size is a reservation, committed as the stack grows; `std.Thread`
/// commits the whole size up front there, which charges a 64 MB worker
/// stack against the system commit limit before the thread runs. Elsewhere
/// this is `std.Thread`, whose stacks are already reserved lazily.
pub const Thread = struct {
    inner: Inner,

    const Inner = if (is_windows) *WinThread else std.Thread;

    pub const SpawnError = std.Thread.SpawnError;

    /// `f` returns `void`.
    pub fn spawn(config: std.Thread.SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Thread {
        if (comptime !is_windows) return .{ .inner = try std.Thread.spawn(config, f, args) };
        return .{ .inner = try WinThread.spawn(config.stack_size, f, args) };
    }

    pub fn join(self: Thread) void {
        if (comptime is_windows) return self.inner.join();
        self.inner.join();
    }

    pub fn detach(self: Thread) void {
        if (comptime is_windows) return self.inner.detach();
        self.inner.detach();
    }
};

const WinThread = struct {
    handle: win.HANDLE = undefined,
    /// running, then `detached` or `done`, whichever comes first; the second
    /// of the two frees the instance.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(running),
    free: *const fn (*WinThread) void,

    const running: u8 = 0;
    const detached: u8 = 1;
    const done: u8 = 2;

    fn Instance(comptime f: anytype, comptime Args: type) type {
        return struct {
            thread: WinThread,
            args: Args,

            fn entry(param: ?*anyopaque) callconv(.winapi) u32 {
                const self: *@This() = @ptrCast(@alignCast(param.?));
                const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
                if (R != void) @compileError("a runtime thread's function returns void");
                @call(.auto, f, self.args);
                if (self.thread.state.swap(done, .acq_rel) == detached) destroy(&self.thread);
                return 0;
            }

            fn destroy(t: *WinThread) void {
                const self: *@This() = @fieldParentPtr("thread", t);
                std.heap.page_allocator.destroy(self);
            }
        };
    }

    fn spawn(stack_size: usize, comptime f: anytype, args: anytype) std.Thread.SpawnError!*WinThread {
        const I = Instance(f, @TypeOf(args));
        const inst = std.heap.page_allocator.create(I) catch return error.OutOfMemory;
        inst.* = .{ .thread = .{ .free = I.destroy }, .args = args };
        const h = win.CreateThread(null, stack_size, I.entry, inst, win.STACK_SIZE_PARAM_IS_A_RESERVATION, null) orelse {
            std.heap.page_allocator.destroy(inst);
            return error.SystemResources;
        };
        inst.thread.handle = h;
        return &inst.thread;
    }

    fn join(self: *WinThread) void {
        _ = win.WaitForSingleObject(self.handle, win.INFINITE);
        _ = win.CloseHandle(self.handle);
        self.free(self);
    }

    fn detach(self: *WinThread) void {
        _ = win.CloseHandle(self.handle);
        if (self.state.swap(detached, .acq_rel) == done) self.free(self);
    }
};

// ---------------------------------------------------------------- process

/// The process's resident memory in bytes: its working set on Windows.
/// Null elsewhere; the watchdog reads Linux and macOS its own way.
pub fn residentBytes() ?u64 {
    if (comptime !is_windows) return null;
    var pmc: win.PROCESS_MEMORY_COUNTERS = std.mem.zeroes(win.PROCESS_MEMORY_COUNTERS);
    pmc.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS);
    if (win.K32GetProcessMemoryInfo(win.GetCurrentProcess(), &pmc, pmc.cb) == 0) return null;
    return pmc.WorkingSetSize;
}

/// CPU time the process has used, user and system, in microseconds.
pub fn processCpuMicros() ?i64 {
    if (comptime is_windows) {
        var created: win.FILETIME = undefined;
        var exited: win.FILETIME = undefined;
        var kernel: win.FILETIME = undefined;
        var user: win.FILETIME = undefined;
        if (win.GetProcessTimes(win.GetCurrentProcess(), &created, &exited, &kernel, &user) == 0) return null;
        const ticks = (@as(u64, kernel.high) << 32 | kernel.low) + (@as(u64, user.high) << 32 | user.low);
        return @intCast(ticks / 10);
    }
    const ru = std.posix.getrusage(0);
    return (@as(i64, ru.utime.sec) + ru.stime.sec) * 1_000_000 + ru.utime.usec + ru.stime.usec;
}

pub fn processId() u64 {
    if (comptime is_windows) return win.GetCurrentProcessId();
    if (comptime builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    return @intCast(std.c.getpid());
}

/// The running executable's path with links resolved, in `buf`. Null where
/// it cannot be found.
pub fn selfExePath(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const n = std.os.linux.readlink("/proc/self/exe", buf, buf.len);
            if (std.os.linux.errno(n) != .SUCCESS or n == 0 or n >= buf.len) return null;
            return buf[0..n];
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            var raw: [std.fs.max_path_bytes]u8 = undefined;
            var n: u32 = raw.len;
            if (std.c._NSGetExecutablePath(&raw, &n) != 0) return null;
            const real = std.c.realpath(@ptrCast(&raw), buf) orelse return null;
            return std.mem.sliceTo(real, 0);
        },
        .windows => {
            var wide: [32 * 1024]u16 = undefined;
            const n = win.GetModuleFileNameW(null, &wide, wide.len);
            if (n == 0 or n >= wide.len) return null;
            const len = std.unicode.utf16LeToUtf8(buf, wide[0..n]) catch return null;
            return buf[0..len];
        },
        else => return null,
    }
}

// ---------------------------------------------------------------- read-only files

/// A file opened for reading at offsets, which can also be mapped read-only.
/// For the executable's own appended payload, read before the CLI parses
/// argv, so it goes to the host directly rather than through `std.Io`.
pub const ReadOnlyFile = struct {
    handle: Handle,

    const Handle = if (is_windows) win.HANDLE else std.c.fd_t;

    pub fn open(path: []const u8) ?ReadOnlyFile {
        if (comptime is_windows) {
            const wide = std.unicode.wtf8ToWtf16LeAllocZ(std.heap.page_allocator, path) catch return null;
            defer std.heap.page_allocator.free(wide);
            const h = win.CreateFileW(wide.ptr, win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_DELETE, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
            if (h == win.INVALID_HANDLE_VALUE) return null;
            return .{ .handle = h };
        }
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buf.len) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const fd = std.c.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY });
        if (fd < 0) return null;
        return .{ .handle = fd };
    }

    pub fn close(self: ReadOnlyFile) void {
        if (comptime is_windows) {
            _ = win.CloseHandle(self.handle);
            return;
        }
        _ = std.c.close(self.handle);
    }

    pub fn size(self: ReadOnlyFile) ?u64 {
        if (comptime is_windows) {
            var n: i64 = 0;
            if (win.GetFileSizeEx(self.handle, &n) == 0 or n < 0) return null;
            return @intCast(n);
        }
        const end = std.c.lseek(self.handle, 0, std.c.SEEK.END);
        if (end < 0) return null;
        return @intCast(end);
    }

    /// Reads into `buf` from `offset`; the bytes read, fewer at the end of
    /// the file or on an error.
    pub fn readAt(self: ReadOnlyFile, buf: []u8, offset: u64) usize {
        var done: usize = 0;
        while (done < buf.len) {
            const want = buf.len - done;
            const at = offset + done;
            const n: usize = if (comptime is_windows) blk: {
                var ov: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED);
                ov.Offset = @truncate(at);
                ov.OffsetHigh = @truncate(at >> 32);
                var got: u32 = 0;
                const chunk: u32 = @intCast(@min(want, std.math.maxInt(u32)));
                if (win.ReadFile(self.handle, buf[done..].ptr, chunk, &got, &ov) == 0) break :blk 0;
                break :blk got;
            } else blk: {
                const r = std.c.pread(self.handle, buf[done..].ptr, want, @intCast(at));
                break :blk if (r <= 0) 0 else @intCast(r);
            };
            if (n == 0) break;
            done += n;
        }
        return done;
    }

    /// The first `len` bytes mapped read-only. The mapping outlives the
    /// handle and stays for the process's life.
    pub fn mapAll(self: ReadOnlyFile, len: usize) ?[]const u8 {
        if (comptime is_windows) {
            const m = win.CreateFileMappingW(self.handle, null, win.PAGE_READONLY, 0, 0, null) orelse return null;
            defer _ = win.CloseHandle(m);
            const view = win.MapViewOfFile(m, win.FILE_MAP_READ, 0, 0, len) orelse return null;
            const p: [*]const u8 = @ptrCast(view);
            return p[0..len];
        }
        const mapped = std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, self.handle, 0) catch return null;
        return mapped[0..len];
    }
};

// ---------------------------------------------------------------- shared libraries

/// A shared library opened by path or name: `dlopen` on POSIX hosts
/// (`std.DynLib`), `LoadLibraryExW` on Windows.
pub const DynLib = struct {
    inner: Inner,

    const Inner = if (is_windows) win.HANDLE else std.DynLib;

    pub const Error = error{ FileNotFound, NameTooLong, InvalidUtf8 };

    pub fn open(path: []const u8) Error!DynLib {
        if (comptime !is_windows) {
            return .{ .inner = std.DynLib.open(path) catch return error.FileNotFound };
        }
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(std.heap.page_allocator, path) catch |e| switch (e) {
            error.OutOfMemory => return error.NameTooLong,
            else => return error.InvalidUtf8,
        };
        defer std.heap.page_allocator.free(wide);
        // A path names the library's directory as the one its own
        // dependencies load from, as `dlopen` resolves an rpath.
        const flags: u32 = if (std.fs.path.isAbsolute(path)) win.LOAD_WITH_ALTERED_SEARCH_PATH else 0;
        const h = win.LoadLibraryExW(wide.ptr, null, flags) orelse return error.FileNotFound;
        return .{ .inner = h };
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        if (comptime !is_windows) return self.inner.lookup(T, name);
        const p = win.GetProcAddress(self.inner, name.ptr) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    pub fn close(self: *DynLib) void {
        if (comptime !is_windows) return self.inner.close();
        _ = win.FreeLibrary(self.inner);
    }
};

// ---------------------------------------------------------------- termination

/// Runs `report` when the process is asked to stop (SIGTERM or SIGINT; a
/// console Ctrl+C, Ctrl+Break or close on Windows) and then exits with 0.
/// For diagnostics that print what they gathered when a run is stopped.
pub fn onTerminate(comptime report: fn () void) void {
    const Hook = struct {
        fn posix(_: std.c.SIG) callconv(.c) void {
            report();
            std.c._exit(0);
        }
        fn windows(_: u32) callconv(.winapi) win.BOOL {
            report();
            win.ExitProcess(0);
        }
    };
    if (comptime is_windows) {
        _ = win.SetConsoleCtrlHandler(Hook.windows, 1);
        return;
    }
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = Hook.posix },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "monotonicNs never goes back" {
    const a = monotonicNs() orelse return error.SkipZigTest;
    const b = monotonicNs().?;
    try testing.expect(b >= a);
}

test "realtimeNs is after 2020" {
    const ns = realtimeNs() orelse return error.SkipZigTest;
    try testing.expect(ns > 1_577_836_800 * std.time.ns_per_s);
}

test "sleepNs sleeps at least as long as asked" {
    const before = monotonicNs() orelse return error.SkipZigTest;
    try testing.expect(sleepNs(2 * std.time.ns_per_ms));
    try testing.expect(monotonicNs().? - before >= 2 * std.time.ns_per_ms);
}

test "a timed wait on a condition returns without a signal" {
    if (!has_os_sync) return error.SkipZigTest;
    var m: Mutex = .{};
    var c: Cond = .{};
    const before = monotonicNs().?;
    m.lock();
    c.timedWait(&m, 5 * std.time.ns_per_ms);
    m.unlock();
    try testing.expect(monotonicNs().? - before >= std.time.ns_per_ms);
}

test "a broadcast wakes a waiter" {
    if (!has_os_sync) return error.SkipZigTest;
    const S = struct {
        m: Mutex = .{},
        c: Cond = .{},
        flag: bool = false,
        fn waiter(s: *@This()) void {
            s.m.lock();
            defer s.m.unlock();
            while (!s.flag) s.c.wait(&s.m);
        }
    };
    var s: S = .{};
    const t = try Thread.spawn(.{}, S.waiter, .{&s});
    s.m.lock();
    s.flag = true;
    s.c.broadcast();
    s.m.unlock();
    t.join();
}

test "a thread with a large reserved stack runs and joins" {
    const S = struct {
        fn deep(out: *usize) void {
            var buf: [256 * 1024]u8 = undefined;
            @memset(&buf, 1);
            out.* = buf[buf.len - 1];
        }
    };
    var got: usize = 0;
    const t = try Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, S.deep, .{&got});
    t.join();
    try testing.expectEqual(@as(usize, 1), got);
}

test "a detached thread finishes on its own" {
    const S = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            flag.store(true, .release);
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    const t = try Thread.spawn(.{}, S.run, .{&flag});
    t.detach();
    var waited: usize = 0;
    while (!flag.load(.acquire) and waited < 2000) : (waited += 1) _ = sleepNs(std.time.ns_per_ms);
    try testing.expect(flag.load(.acquire));
}

test "map gives zeroed memory and unmap takes it back in pieces" {
    const pg = std.heap.pageSize();
    const p = map(4 * pg) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(u8, 0), p[3 * pg]);
    p[0] = 7;
    p[3 * pg] = 9;
    unmap(p + 2 * pg, 2 * pg);
    try testing.expectEqual(@as(u8, 7), p[0]);
    unmap(p, 2 * pg);
}

test "mapAligned lands on the alignment and discard zeroes a page" {
    const alignment: usize = 256 * 1024;
    const len: usize = 4 * alignment;
    const base = mapAligned(len, alignment) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 0), base % alignment);
    const p: [*]u8 = @ptrFromInt(base);
    p[0] = 1;
    p[len - 1] = 2;
    const pg = std.heap.pageSize();
    discard(base, pg);
    try testing.expectEqual(@as(u8, 0), p[0]);
    try testing.expectEqual(@as(u8, 2), p[len - 1]);
    p[0] = 3;
    unmap(p, alignment);
    unmap(p + alignment, len - alignment);
}

test "selfExePath names an existing file" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = selfExePath(&buf) orelse return error.SkipZigTest;
    try testing.expect(path.len > 0);
    try testing.expect(std.fs.path.isAbsolute(path));
}

test "processId is nonzero" {
    try testing.expect(processId() != 0);
}
