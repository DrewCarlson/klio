//! Host-protection backstops that keep a runaway interpreted program to a
//! single process: an RSS watchdog that aborts before the OOM killer fires, an
//! opt-in wall-clock run deadline, and a capped subprocess runner that drains
//! both pipes so a chatty child cannot deadlock. Each `start*` is call-once.

const std = @import("std");
const builtin = @import("builtin");

const proc_env = @import("proc_env.zig");

const Allocator = std.mem.Allocator;

/// Default RSS cap. Each program in an in-process harness gets its own arena,
/// so the resident peak is one program's worth, and a runaway program races
/// unbounded toward OOM rather than plateauing. `KLIO_RSS_CAP_KB` overrides.
const DEFAULT_RSS_CAP_KB: u64 = 6 * 1024 * 1024;

/// Nanoseconds.
const POLL_NS: u64 = 100 * std.time.ns_per_ms;

var memory_watchdog_started = std.atomic.Value(bool).init(false);
var run_deadline_started = std.atomic.Value(bool).init(false);
var noted_no_rss = std.atomic.Value(bool).init(false);

/// `KLIO_RSS_CAP_KB` sets the cap; unset or unparseable means the default.
pub fn startMemoryWatchdog() void {
    if (memory_watchdog_started.swap(true, .seq_cst)) return;

    // Where RSS cannot be sampled, note it once and no-op.
    if (currentRssKb() == null) {
        noteNoRss();
        return;
    }

    const cap_kb = readCapKb();
    const t = std.Thread.spawn(.{}, memoryWatchdogLoop, .{cap_kb}) catch return;
    t.detach();
}

fn readCapKb() u64 {
    const a = std.heap.page_allocator;
    if (readEnvU64(a, "KLIO_RSS_CAP_KB")) |v| {
        if (v > 0) return v;
    }
    if (readEnvU64(a, "KLIO_PARITY_RSS_CAP_KB")) |v| {
        if (v > 0) return v;
    }
    return DEFAULT_RSS_CAP_KB;
}

fn readEnvU64(a: Allocator, name: []const u8) ?u64 {
    const raw = proc_env.getVar(a, name) catch return null;
    const v = raw orelse return null;
    defer a.free(v);
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

fn sleepNs(ns: u64) void {
    if (builtin.os.tag == .linux) {
        const ts = std.os.linux.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.os.linux.nanosleep(&ts, null);
        return;
    }
    if (builtin.os.tag.isDarwin()) {
        const ts = std.c.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.c.nanosleep(&ts, null);
        return;
    }
    const ms: i64 = @intCast(ns / std.time.ns_per_ms);
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

fn memoryWatchdogLoop(cap_kb: u64) void {
    while (true) {
        sleepNs(POLL_NS);
        const rss = currentRssKb() orelse continue;
        if (rss > cap_kb) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "[klio] RSS {d}KB exceeded cap {d}KB — aborting to avoid system OOM " ++
                    "(raise KLIO_RSS_CAP_KB if intentional)\n",
                .{ rss, cap_kb },
            ) catch "[klio] RSS exceeded cap — aborting to avoid system OOM\n";
            writeStderr(msg);
            std.process.abort();
        }
    }
}

/// From `/proc/self/statm` field 2 on Linux and mach task basic info on macOS.
/// Null on any other platform or on a read error.
pub fn currentRssKb() ?u64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const fd_raw = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd_raw) != .SUCCESS) return null;
        const fd: i32 = @intCast(fd_raw);
        defer _ = linux.close(fd);

        var buf: [256]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return null;
        const data = buf[0..n];

        // statm is "size resident shared text lib data dt", in pages.
        var it = std.mem.tokenizeScalar(u8, data, ' ');
        _ = it.next() orelse return null; // total program size
        const resident = it.next() orelse return null;
        const trimmed = std.mem.trim(u8, resident, " \t\r\n");
        const pages = std.fmt.parseInt(u64, trimmed, 10) catch return null;
        const page_kb = std.heap.pageSize() / 1024;
        return pages * page_kb;
    }
    if (builtin.os.tag.isDarwin()) {
        // `resident_size` is in bytes.
        var info: std.c.mach_task_basic_info = undefined;
        var count: std.c.mach_msg_type_number_t = std.c.MACH.TASK.BASIC.INFO_COUNT;
        const kr = std.c.task_info(
            std.c.mach_task_self(),
            std.c.MACH.TASK.BASIC.INFO,
            @ptrCast(&info),
            &count,
        );
        if (kr != 0) return null;
        return @as(u64, @intCast(info.resident_size)) / 1024;
    }
    return null;
}

fn noteNoRss() void {
    if (noted_no_rss.swap(true, .seq_cst)) return;
    writeStderr("[klio] RSS watchdog unavailable on this platform; memory cap not enforced\n");
}

/// `KLIO_RUN_TIMEOUT_S` arms it; unset or zero leaves it off.
pub fn startRunDeadline() void {
    const secs = readEnvU64(std.heap.page_allocator, "KLIO_RUN_TIMEOUT_S") orelse 0;
    if (secs == 0) return;
    if (run_deadline_started.swap(true, .seq_cst)) return;
    const t = std.Thread.spawn(.{}, runDeadlineLoop, .{secs}) catch return;
    t.detach();
}

fn runDeadlineLoop(secs: u64) void {
    sleepNs(secs * std.time.ns_per_s);
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "[klio] exceeded run timeout of {d}s — aborting (raise KLIO_RUN_TIMEOUT_S if intentional)\n",
        .{secs},
    ) catch "[klio] exceeded run timeout — aborting\n";
    writeStderr(msg);
    std.process.abort();
}

pub const CapResult = union(enum) {
    done: struct {
        term: std.process.Child.Term,
        stdout: []u8,
        stderr: []u8,
    },
    timeout,
    spawn_failed,
};

/// Drains both pipes so a chatty child cannot deadlock on a full pipe buffer,
/// and kills it past `timeout_ms`, where 0 means no timeout. The caller owns
/// the captured buffers.
pub fn runCapped(
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: u64,
) Allocator.Error!CapResult {
    const timeout: std.Io.Timeout = if (timeout_ms == 0)
        .none
    else
        .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
            .clock = .awake,
        } };

    const r = std.process.run(allocator, io, .{
        .argv = argv,
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.Timeout => return .timeout,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .spawn_failed,
    };
    return .{ .done = .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr } };
}

/// Each Kotlin call re-enters the evaluator through the host, so the
/// nested-call chain is stack-heavy. `KLIO_MAX_EVAL_DEPTH` defaults well below
/// this stack's frame ceiling and turns unbounded recursion into a clean
/// `StackOverflowError`.
pub const INTERPRET_STACK_SIZE: usize = 256 * 1024 * 1024;

/// If the thread cannot be spawned, `func` runs inline on the current stack.
pub fn runOnBigStack(
    comptime Ctx: type,
    comptime Ret: type,
    comptime func: fn (Ctx) Ret,
    ctx: Ctx,
) Ret {
    const Runner = struct {
        ctx: Ctx,
        result: Ret = undefined,
        fn entry(self: *@This()) void {
            self.result = func(self.ctx);
        }
    };
    var runner = Runner{ .ctx = ctx };
    const t = std.Thread.spawn(
        .{ .stack_size = INTERPRET_STACK_SIZE },
        Runner.entry,
        .{&runner},
    ) catch return func(ctx);
    t.join();
    return runner.result;
}

/// Switches the stack pointer to `sp_top`, calls `func(arg)`, then restores it,
/// so `func` runs on a caller-supplied stack without leaving the OS thread.
/// `sp_top` must be 16-byte aligned and point just past a writable region. This
/// keeps the interpreter on the process main thread, which macOS AppKit and the
/// single-threaded Skia GPU context both require.
noinline fn callOnStack(
    sp_top: usize,
    func: *const fn (*anyopaque) callconv(.c) void,
    arg: *anyopaque,
) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x20, sp
            \\ mov sp, %[sp]
            \\ mov x0, %[arg]
            \\ blr %[func]
            \\ mov sp, x20
            :
            : [sp] "r" (sp_top),
              [func] "r" (func),
              [arg] "r" (arg),
            : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x20 = true, .x30 = true, .memory = true, .nzcv = true }),
        .x86_64 => asm volatile (
            \\ movq %%rsp, %%r15
            \\ movq %[sp], %%rsp
            \\ movq %[arg], %%rdi
            \\ callq *%[func]
            \\ movq %%r15, %%rsp
            :
            : [sp] "r" (sp_top),
              [func] "r" (func),
              [arg] "r" (arg),
            : .{ .rax = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r15 = true, .memory = true, .cc = true }),
        else => func(arg),
    }
}

/// Unlike `runOnBigStack` this spawns no worker, so the interpreter stays on
/// the process main thread. Falls back to an inline call when mapping fails.
pub fn runOnBigStackMainThread(
    comptime Ctx: type,
    comptime Ret: type,
    comptime func: fn (Ctx) Ret,
    ctx: Ctx,
) Ret {
    if (comptime builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64) {
        return func(ctx);
    }
    // Already switched by the CLI entry: do not map a second reserve.
    if (on_big_stack) return func(ctx);
    const Runner = struct {
        ctx: Ctx,
        result: Ret = undefined,
        fn entry(arg: *anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            self.result = func(self.ctx);
        }
    };
    var runner = Runner{ .ctx = ctx };
    const stack = std.posix.mmap(
        null,
        INTERPRET_STACK_SIZE,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return func(ctx);
    defer std.posix.munmap(stack);
    const sp_top = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len, 16);
    on_big_stack = true;
    defer on_big_stack = false;
    callOnStack(sp_top, Runner.entry, &runner);
    return runner.result;
}

threadlocal var on_big_stack: bool = false;

/// A process-lifetime interpreter stack for an OS-driven frame loop, which
/// re-enters the VM on its own small UI-thread stack each vsync. Mapped on
/// first use and never unmapped; only the hosted-UI frame callback maps it.
var persistent_stack: ?[]align(std.heap.page_size_min) u8 = null;

/// Each call starts at the top of the shared stack, so this is valid only for a
/// body that fully returns: nothing may survive across the switch back, which
/// holds because the interpreter's suspension state is heap-resident.
pub fn runOnPersistentBigStack(
    comptime Ctx: type,
    comptime Ret: type,
    comptime func: fn (Ctx) Ret,
    ctx: Ctx,
) Ret {
    if (comptime builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64) {
        return func(ctx);
    }
    const stack = persistent_stack orelse blk: {
        const s = std.posix.mmap(
            null,
            INTERPRET_STACK_SIZE,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return func(ctx);
        persistent_stack = s;
        break :blk s;
    };
    const Runner = struct {
        ctx: Ctx,
        result: Ret = undefined,
        fn entry(arg: *anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            self.result = func(self.ctx);
        }
    };
    var runner = Runner{ .ctx = ctx };
    const sp_top = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len, 16);
    callOnStack(sp_top, Runner.entry, &runner);
    return runner.result;
}

/// Used on the abort path, so it must not allocate.
pub fn writeStderr(msg: []const u8) void {
    if (builtin.os.tag == .linux) {
        var off: usize = 0;
        while (off < msg.len) {
            const n = std.os.linux.write(2, msg.ptr + off, msg.len - off);
            if (std.os.linux.errno(n) != .SUCCESS) return;
            if (n == 0) return;
            off += n;
        }
        return;
    }
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    std.Io.File.stderr().writeStreamingAll(threaded.io(), msg) catch {};
}

const testing = std.testing;

test "startMemoryWatchdog is call-once and does not abort under the default cap" {
    startMemoryWatchdog();
    startMemoryWatchdog();
}

test "startRunDeadline default-off is a no-op" {
    startRunDeadline();
}

test "currentRssKb reads a plausible value on linux" {
    if (builtin.os.tag != .linux) return;
    const rss = currentRssKb() orelse return error.SkipZigTest;
    try testing.expect(rss > 0);
}

test "readCapKb falls back to the 6 GiB default" {
    if (proc_env.isSet(testing.allocator, "KLIO_RSS_CAP_KB")) return;
    if (proc_env.isSet(testing.allocator, "KLIO_PARITY_RSS_CAP_KB")) return;
    try testing.expectEqual(DEFAULT_RSS_CAP_KB, readCapKb());
}
