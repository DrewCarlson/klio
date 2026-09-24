//! How `klio test` reports: the per-test listing, a JSON summary, or the
//! service messages an IDE reads, and the runs it spreads over processes
//! (`--isolate`, and a project's test groups).

const std = @import("std");
const runtime = @import("runtime");
const test_runner = @import("test_runner");

const io = @import("io.zig");

/// `plain` is the per-test list plus summary, `json` a machine-readable object,
/// `ij` the service-message stream an IDE test tree consumes as tests finish.
pub const TestFormat = enum { plain, json, ij };

fn writeJsonString(gpa: std.mem.Allocator, s: []const u8) void {
    io.printStdout(gpa, "\"", .{});
    for (s) |c| switch (c) {
        '"' => io.printStdout(gpa, "\\\"", .{}),
        '\\' => io.printStdout(gpa, "\\\\", .{}),
        '\n' => io.printStdout(gpa, "\\n", .{}),
        '\r' => io.printStdout(gpa, "\\r", .{}),
        '\t' => io.printStdout(gpa, "\\t", .{}),
        else => if (c < 0x20) io.printStdout(gpa, "\\u{x:0>4}", .{c}) else io.printStdout(gpa, "{c}", .{c}),
    };
    io.printStdout(gpa, "\"", .{});
}

/// Prints a test report as `format` asks. A code when the report settles
/// the exit status (json, ij, nothing ran), null when the caller's own
/// tail follows the plain listing.
pub fn printTestReport(gpa: std.mem.Allocator, report: *const test_runner.Report, format: TestFormat) ?u8 {
    if (format == .json) {
        io.printStdout(gpa, "{{\"total\":{d},\"passed\":{d},\"failed\":{d},\"skipped\":{d},\"tests\":[", .{
            report.results.len, report.passed, report.failed, report.skipped,
        });
        for (report.results, 0..) |r, idx| {
            if (idx != 0) io.printStdout(gpa, ",", .{});
            io.printStdout(gpa, "{{\"name\":", .{});
            writeJsonString(gpa, r.display);
            io.printStdout(gpa, ",\"outcome\":\"{s}\"", .{@tagName(r.outcome)});
            if (r.detail) |d| {
                io.printStdout(gpa, ",\"detail\":", .{});
                writeJsonString(gpa, d);
            }
            io.printStdout(gpa, "}}", .{});
        }
        io.printStdout(gpa, "]}}\n", .{});
        return if (report.failed > 0) @as(u8, 1) else 0;
    }

    // `ij` already streamed every result as a service message.
    if (format == .ij) return if (report.failed > 0) @as(u8, 1) else 0;

    for (report.results) |r| {
        const tag = switch (r.outcome) {
            .passed => "PASSED",
            .failed => "FAILED",
            .skipped => "SKIPPED",
        };
        io.printStdout(gpa, "{s} {s}\n", .{ r.display, tag });
        if (r.detail) |d| io.printStdout(gpa, "    {s}\n", .{d});
    }
    if (report.results.len == 0) {
        if (report.failed != 0) {
            io.printStdout(gpa, "test runner failed before producing a result\n", .{});
            return 1;
        }
        io.printStdout(gpa, "no tests found\n\n0 tests, 0 passed, 0 failed, 0 skipped\n", .{});
        return 0;
    }
    io.printStdout(gpa, "\n{d} tests, {d} passed, {d} failed, {d} skipped\n", .{
        report.results.len, report.passed, report.failed, report.skipped,
    });
    return null;
}

/// `--isolate`: run each `@Test` in its own sub-process under a wall-clock
/// timeout, so a hang or crash is pinpointed. `base_args` is the `test` argv
/// minus `--isolate`/`--jobs`; each test runs under one exact `--filter==<name>`.
pub fn runTestsIsolated(
    gpa: std.mem.Allocator,
    self: []const u8,
    base_args: []const []const u8,
    timeout_s: u64,
) u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const rio = threaded.io();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    runtime.procEnvPutAllInto(gpa, &env);

    var list_argv: std.ArrayList([]const u8) = .empty;
    defer list_argv.deinit(gpa);
    list_argv.append(gpa, self) catch return 2;
    list_argv.append(gpa, "test") catch return 2;
    list_argv.appendSlice(gpa, base_args) catch return 2;
    list_argv.append(gpa, "--list") catch return 2;
    const listed = std.process.run(gpa, rio, .{ .argv = list_argv.items, .environ_map = &env }) catch {
        io.writeStderr("error: --isolate: failed to enumerate tests\n");
        return 2;
    };
    defer gpa.free(listed.stdout);
    defer gpa.free(listed.stderr);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, listed.stdout, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len != 0) names.append(gpa, t) catch return 2;
    }
    if (names.items.len == 0) {
        // A file whose only `@Test` methods are on an abstract class still ran.
        io.printStdout(gpa, "no tests found\n\n0 tests, 0 passed, 0 failed, 0 skipped\n", .{});
        return 0;
    }

    const timeout_ms: i64 = @intCast(timeout_s * 1000);
    var passed: usize = 0;
    var failed: usize = 0;
    var timed_out: usize = 0;
    for (names.items) |name| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        const filt = std.fmt.allocPrint(gpa, "--filter=={s}", .{name}) catch return 2;
        defer gpa.free(filt);
        argv.append(gpa, self) catch return 2;
        argv.append(gpa, "test") catch return 2;
        argv.appendSlice(gpa, base_args) catch return 2;
        argv.append(gpa, filt) catch return 2;
        const res = std.process.run(gpa, rio, .{
            .argv = argv.items,
            .environ_map = &env,
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
        }) catch |e| {
            if (e == error.Timeout) {
                io.printStdout(gpa, "{s} TIMEOUT ({d}s)\n", .{ name, timeout_s });
                timed_out += 1;
            } else {
                io.printStdout(gpa, "{s} ERROR (spawn failed)\n", .{name});
                failed += 1;
            }
            continue;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        // exit 0 passed, exit 1 failed, abnormal termination is a crash.
        switch (res.term) {
            .exited => |c| if (c == 0) {
                io.printStdout(gpa, "{s} PASSED\n", .{name});
                passed += 1;
            } else {
                io.printStdout(gpa, "{s} FAILED\n", .{name});
                failed += 1;
            },
            else => {
                io.printStdout(gpa, "{s} CRASH\n", .{name});
                timed_out += 1;
            },
        }
    }
    io.printStdout(gpa, "\n{d} tests, {d} passed, {d} failed, {d} timeout/crash\n", .{
        names.items.len, passed, failed, timed_out,
    });
    return if (failed + timed_out > 0) 1 else 0;
}

/// Runs each test group in its own process.
///
/// A program leaves state behind that the next one in the same process finds
/// installed over a released arena: the closure spine is the one that crashes
/// first. Nothing had ever run two programs in one process, so rather than
/// audit every global for it, a group gets a process, which is also what
/// `--isolate` does for a single test.
pub fn runTestGroups(
    gpa: std.mem.Allocator,
    self: []const u8,
    groups: []const []const u8,
    base_args: []const []const u8,
) u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const rio = threaded.io();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    runtime.procEnvPutAllInto(gpa, &env);

    var worst: u8 = 0;
    for (groups) |name| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        const flag = std.fmt.allocPrint(gpa, "--test-group={s}", .{name}) catch return 2;
        defer gpa.free(flag);
        argv.append(gpa, self) catch return 2;
        argv.append(gpa, "test") catch return 2;
        argv.appendSlice(gpa, base_args) catch return 2;
        argv.append(gpa, flag) catch return 2;

        io.printStdout(gpa, "[{s}]\n", .{name});
        const res = std.process.run(gpa, rio, .{ .argv = argv.items, .environ_map = &env }) catch {
            io.printStdout(gpa, "error: test group `{s}` failed to start\n", .{name});
            worst = 2;
            continue;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        io.writeStdout(res.stdout);
        if (res.stderr.len != 0) io.writeStderr(res.stderr);
        const code: u8 = switch (res.term) {
            .exited => |c| @intCast(c),
            else => 2,
        };
        if (code > worst) worst = code;
    }
    return worst;
}
