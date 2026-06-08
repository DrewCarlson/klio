//! `klio-parity <file.kt>` — compare our interpreter against JVM `kotlinc`.
//! Exit code 0 on parity, 1 on mismatch, 2 on harness error.
//!
//! Exposes `pub fn run` (not a real `main`); the orchestrator wires the exe.

const std = @import("std");
const parity = @import("parity.zig");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Run the parity harness over `args` (the full argv, including argv[0]).
/// Returns the process exit code (0 / 1 / 2).
pub fn run(allocator: Allocator, io: Io, args: []const []const u8) Allocator.Error!u8 {
    // Cap the harness process's RSS so a runaway program can't OOM the
    // machine; arm the opt-in run deadline. Call-once.
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    const file = if (args.len > 1) args[1] else {
        printErr(
            "usage: klio-parity <file.kt> [<file.kt> ...]\n       " ++
                "klio-parity --sweep [corpus|examples|all]\n       " ++
                "klio-parity --install [jvm|native|both]\n",
            .{},
        );
        return 2;
    };

    if (std.mem.eql(u8, file, "--sweep")) {
        const which = if (args.len > 2) args[2] else "all";
        return runSweepCmd(allocator, io, which);
    }
    if (std.mem.eql(u8, file, "--install")) {
        const second: ?[]const u8 = if (args.len > 2) args[2] else null;
        var kinds_buf: [2]parity.KotlincKind = undefined;
        var kinds: []const parity.KotlincKind = undefined;
        if (second != null and std.mem.eql(u8, second.?, "native")) {
            kinds_buf[0] = .Native;
            kinds = kinds_buf[0..1];
        } else if (second != null and std.mem.eql(u8, second.?, "both")) {
            kinds_buf[0] = .Jvm;
            kinds_buf[1] = .Native;
            kinds = kinds_buf[0..2];
        } else {
            kinds_buf[0] = .Jvm;
            kinds = kinds_buf[0..1];
        }
        for (kinds) |k| {
            switch (try parity.installKotlincKind(allocator, io, k, parity.TARGET_VERSION)) {
                .ok => |p| {
                    printOut("{s} kotlinc ready at {s}\n", .{ @tagName(k), p });
                    allocator.free(p);
                },
                .err => |e| {
                    const msg = try e.message(allocator);
                    defer allocator.free(msg);
                    printErr("install {s} failed: {s}\n", .{ @tagName(k), msg });
                    e.deinit(allocator);
                    return 2;
                },
            }
        }
        return 0;
    }

    var any_mismatch = false;
    for (args[1..]) |path| {
        switch (try parity.check(allocator, io, path)) {
            .ok => |report| {
                if (report.matched) {
                    printOut("[parity] {s}: ok\n", .{path});
                } else {
                    any_mismatch = true;
                    printOut("[parity] {s}: MISMATCH\n", .{path});
                    const diff = try parity.renderDiff(allocator, &report);
                    defer allocator.free(diff);
                    writeFd(1, diff);
                }
                allocator.free(report.kotlinc_stdout);
                allocator.free(report.klio_stdout);
                if (report.klio_error) |e| allocator.free(e);
            },
            .err => |e| {
                const msg = try e.message(allocator);
                defer allocator.free(msg);
                printErr("[parity] {s}: error: {s}\n", .{ path, msg });
                e.deinit(allocator);
                return 2;
            },
        }
    }
    return if (any_mismatch) 1 else 0;
}

/// `klio-parity --sweep [corpus|examples|all]` — the fast inner loop.
fn runSweepCmd(allocator: Allocator, io: Io, which: []const u8) Allocator.Error!u8 {
    switch (try parity.findKotlinc(allocator, io)) {
        .err => |e| {
            e.deinit(allocator);
            printErr(
                "[sweep] kotlinc not found (set KLIO_KOTLINC_JVM_HOME or run " ++
                    "`klio-parity --install`). The expected-output cache is keyed by " ++
                    "kotlinc version; a first run needs kotlinc to populate it.\n",
                .{},
            );
            return 2;
        },
        .ok => |k| allocator.free(k),
    }

    const jobs = parity.defaultJobs(allocator);

    const Group = struct { label: []const u8, paths: [][]u8 };
    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |g| {
            for (g.paths) |p| allocator.free(p);
            allocator.free(g.paths);
        }
        groups.deinit(allocator);
    }

    const want_corpus = std.mem.eql(u8, which, "corpus") or std.mem.eql(u8, which, "all");
    const want_examples = std.mem.eql(u8, which, "examples") or std.mem.eql(u8, which, "all");
    if (want_corpus) {
        const dir = try parity.corpusDir(allocator);
        defer allocator.free(dir);
        try groups.append(allocator, .{ .label = "corpus", .paths = try parity.collectKt(allocator, io, dir) });
    }
    if (want_examples) {
        const dir = try parity.examplesDir(allocator);
        defer allocator.free(dir);
        try groups.append(allocator, .{ .label = "examples", .paths = try parity.collectKt(allocator, io, dir) });
    }
    if (groups.items.len == 0) {
        printErr("[sweep] unknown target \"{s}\"; use corpus | examples | all\n", .{which});
        return 2;
    }

    const start = Io.Clock.now(.awake, io);
    var total: usize = 0;
    var total_pass: usize = 0;
    var any_fail = false;
    for (groups.items) |g| {
        const paths_const = try allocator.alloc([]const u8, g.paths.len);
        defer allocator.free(paths_const);
        for (g.paths, 0..) |p, i| paths_const[i] = p;

        switch (try parity.runSweep(allocator, io, g.label, paths_const, jobs)) {
            .ok => |res| {
                defer res.deinit(allocator);
                total += res.results.len;
                total_pass += res.passed();
                for (res.results) |r| {
                    const rel = std.fs.path.basename(r.path);
                    switch (r.verdict) {
                        .Mismatch => |report| {
                            any_fail = true;
                            printOut("[sweep {s}] MISMATCH {s}\n", .{ g.label, rel });
                            const diff = try parity.renderDiff(allocator, report);
                            defer allocator.free(diff);
                            writeFd(1, diff);
                        },
                        .KlioError => |e| {
                            any_fail = true;
                            printOut("[sweep {s}] KLIO ERROR {s}: {s}\n", .{ g.label, rel, e });
                        },
                        .Timeout => {
                            any_fail = true;
                            printOut("[sweep {s}] TIMEOUT {s}\n", .{ g.label, rel });
                        },
                        .KotlincError, .Pass => {},
                    }
                }
                printOut("[sweep {s}] {d}/{d} passed\n", .{ g.label, res.passed(), res.results.len });
            },
            .err => |e| {
                const msg = try e.message(allocator);
                defer allocator.free(msg);
                printErr("[sweep {s}] harness error: {s}\n", .{ g.label, msg });
                e.deinit(allocator);
                return 2;
            },
        }
    }
    const elapsed_ms = start.durationTo(Io.Clock.now(.awake, io)).toMilliseconds();
    const secs: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    printOut("=== sweep: {d}/{d} passed in {d:.1}s ===\n", .{ total_pass, total, secs });
    return if (any_fail) 1 else 0;
}

fn writeFd(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data.ptr + off, data.len - off);
        const e = std.os.linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return;
        if (rc == 0) return;
        off += rc;
    }
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFd(1, s);
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFd(2, s);
}

test {
    std.testing.refAllDecls(@This());
}
