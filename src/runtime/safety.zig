//! Host-protection safety backstops.
//!
//! A runaway interpreted program (an unbounded range/sequence, an
//! interpreter regression that materializes too much, a non-terminating
//! recursion) must never take the host machine down with it. These guards
//! keep the blast radius to a single process:
//!
//! - `startMemoryWatchdog` polls the process's own RSS and aborts the
//!   instant it crosses a hard cap, before the kernel OOM-killer fires
//!   and before the machine swaps to death.
//! - `startRunDeadline` is an opt-in wall-clock timeout that aborts a run
//!   that outlives its budget (default off so long legitimate runs — a
//!   pack build, a corpus sweep — are unaffected).
//! - `runCapped` spawns an external subprocess (kotlinc / java), draining
//!   both pipes so a chatty child cannot deadlock, and kills it past a
//!   timeout.
//!
//! Each `start*` is call-once: wiring it at every run/test entry point is
//! safe and idempotent. RSS is read from `/proc/self/statm` on Linux and
//! from the mach task basic info on macOS; on targets without an RSS source
//! the watchdog no-ops with a one-time note rather than blocking them.

const std = @import("std");
const builtin = @import("builtin");

const proc_env = @import("proc_env.zig");

const Allocator = std.mem.Allocator;

/// Default RSS cap: 6 GiB. The in-process harnesses
/// (differential / e2e / fuzz) run the whole corpus through one long-lived
/// process, but each program is run on a per-program arena that is reset (or
/// destroyed) between programs, so the resident peak is a single program's
/// worth rather than the accumulated corpus. A single runaway program — which
/// races unbounded toward system OOM, not a bounded plateau — is still aborted
/// long before the machine is endangered. Override with `KLIO_RSS_CAP_KB` (or
/// the legacy `KLIO_PARITY_RSS_CAP_KB`) to raise or lower the bound.
const DEFAULT_RSS_CAP_KB: u64 = 6 * 1024 * 1024;

/// How often the watchdogs sample, in nanoseconds (100ms).
const POLL_NS: u64 = 100 * std.time.ns_per_ms;

var memory_watchdog_started = std.atomic.Value(bool).init(false);
var run_deadline_started = std.atomic.Value(bool).init(false);
var noted_no_rss = std.atomic.Value(bool).init(false);

/// Start the RSS watchdog (call-once). Reads `KLIO_RSS_CAP_KB` (or the legacy
/// `KLIO_PARITY_RSS_CAP_KB`); `0` / unset / unparseable means
/// `DEFAULT_RSS_CAP_KB`. Spawns a daemon thread that samples RSS every 100ms
/// and aborts the process the instant RSS exceeds the cap.
pub fn startMemoryWatchdog() void {
    if (memory_watchdog_started.swap(true, .seq_cst)) return;

    // Start only where RSS can be sampled (Linux, macOS); elsewhere the
    // watchdog is a no-op with a one-time note so other targets never block.
    if (currentRssKb() == null) {
        noteNoRss();
        return;
    }

    const cap_kb = readCapKb();
    const t = std.Thread.spawn(.{}, memoryWatchdogLoop, .{cap_kb}) catch return;
    t.detach();
}

fn readCapKb() u64 {
    // `procEnvGetVar` reads the whole environment block, so use a real
    // allocator rather than a small fixed buffer.
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
    // Cross-platform fallback (used by the one-shot deadline on other targets).
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

/// Current resident-set size in KiB. Read from `/proc/self/statm` on Linux
/// (field 2 = resident pages) and from the mach task basic info on macOS.
/// Returns `null` on any other platform or on a read error.
fn currentRssKb() ?u64 {
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

        // statm: "size resident shared text lib data dt" (pages).
        var it = std.mem.tokenizeScalar(u8, data, ' ');
        _ = it.next() orelse return null; // total program size
        const resident = it.next() orelse return null;
        const trimmed = std.mem.trim(u8, resident, " \t\r\n");
        const pages = std.fmt.parseInt(u64, trimmed, 10) catch return null;
        const page_kb = std.heap.pageSize() / 1024;
        return pages * page_kb;
    }
    if (builtin.os.tag.isDarwin()) {
        // mach `task_info(MACH_TASK_BASIC_INFO)` reports `resident_size` in bytes.
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

/// Start the opt-in wall-clock run deadline (call-once). Reads
/// `KLIO_RUN_TIMEOUT_S`; `0` / unset disables it (the default, so the test
/// suite and long legitimate runs are unaffected). When `>0`, a daemon thread
/// aborts the process once the deadline passes.
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

/// Outcome of a capped subprocess run.
pub const CapResult = union(enum) {
    /// The child exited (normally or with a signal); stdout/stderr captured.
    done: struct {
        term: std.process.Child.Term,
        stdout: []u8,
        stderr: []u8,
    },
    /// The child outlived `timeout_ms` and was killed.
    timeout,
    /// The child could not be spawned or its pipes could not be drained.
    spawn_failed,
};

/// Spawn `argv`, capturing stdout/stderr while draining both pipes so a
/// chatty child cannot deadlock on a full pipe buffer, and killing the child
/// if it outlives `timeout_ms` (0 = no timeout). The caller owns
/// `done.stdout` / `done.stderr`.
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

/// Worker stack size for the top-level interpret thread. The IR evaluator's
/// nested-call chain (each Kotlin call re-enters the evaluator through the
/// host) is stack-heavy, so a generous stack lets deep-but-finite legitimate
/// recursion run to completion. The eval-depth cap (`KLIO_MAX_EVAL_DEPTH`,
/// default well below this stack's frame ceiling) is the backstop that
/// converts unbounded recursion into a clean `StackOverflowError` before the
/// stack actually faults.
pub const INTERPRET_STACK_SIZE: usize = 256 * 1024 * 1024;

/// Run `func(ctx)` on a fresh thread with a large stack and return its result.
/// `func` may be `Allocator.Error!T` or a plain `T`; the result type is
/// inferred. If the worker thread cannot be spawned, `func` runs inline on the
/// current stack so behavior is identical (just without the larger stack).
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

/// Switch the stack pointer to `sp_top`, call `func(arg)`, then restore it —
/// running `func` on a caller-supplied stack without leaving the current OS
/// thread. `sp_top` must point just past a writable region and be 16-byte
/// aligned. Used to give the interpreter a large stack while keeping it on the
/// process main thread (macOS AppKit + a single-threaded Skia GPU context both
/// require the main thread).
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

/// Run `func(ctx)` on the current OS thread but on a freshly mmap'd large stack
/// (via `callOnStack`), returning its result. Unlike `runOnBigStack` this does
/// not spawn a worker thread, so the interpreter keeps running on the process
/// main thread — required on macOS, where AppKit windowing and the single-thread
/// Skia GPU (Metal) context must both live on the main thread. Falls back to an
/// inline call on the current stack if the mapping fails or the arch is
/// unsupported (same behavior, just the smaller default stack).
pub fn runOnBigStackMainThread(
    comptime Ctx: type,
    comptime Ret: type,
    comptime func: fn (Ctx) Ret,
    ctx: Ctx,
) Ret {
    if (comptime builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64) {
        return func(ctx);
    }
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
    callOnStack(sp_top, Runner.entry, &runner);
    return runner.result;
}

/// Write directly to the stderr fd. Used on the abort path, so it must not
/// allocate (a memory breach has already fired). Linux issues the raw
/// syscall; other platforms fall back to the buffered file writer.
fn writeStderr(msg: []const u8) void {
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
    // Idempotent; a second call is a no-op. The default 6 GiB cap is far
    // above this test process's RSS, so the watchdog never fires here.
    startMemoryWatchdog();
    startMemoryWatchdog();
}

test "startRunDeadline default-off is a no-op" {
    // With KLIO_RUN_TIMEOUT_S unset the deadline never arms.
    startRunDeadline();
}

test "currentRssKb reads a plausible value on linux" {
    if (builtin.os.tag != .linux) return;
    const rss = currentRssKb() orelse return error.SkipZigTest;
    // Any live process holds at least a few pages resident.
    try testing.expect(rss > 0);
}

test "readCapKb falls back to the 6 GiB default" {
    // Neither cap var is expected to be set in the test environment.
    if (proc_env.isSet(testing.allocator, "KLIO_RSS_CAP_KB")) return;
    if (proc_env.isSet(testing.allocator, "KLIO_PARITY_RSS_CAP_KB")) return;
    try testing.expectEqual(DEFAULT_RSS_CAP_KB, readCapKb());
}
