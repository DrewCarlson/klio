//! End-to-end bench driver. Emits stable JSON on stdout and human
//! summary on stderr.
//!
//! Usage:
//!   klio-bench            # all corpora, fast budget
//!   klio-bench --full     # extended workloads, ref runners
//!   klio-bench --json     # JSON only, no stderr summary
//!   klio-bench --diff <baseline.json>

const std = @import("std");
const bench = @import("bench.zig");
const runtime = @import("runtime");
const schema = bench.schema;
const refrunner = bench.refrunner;

const BenchRecord = schema.BenchRecord;
const BenchReport = schema.BenchReport;
const RegressionLevel = schema.RegressionLevel;

const Args = struct {
    full: bool = false,
    json_only: bool = false,
    diff_path: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    filter: ?[]const u8 = null,
};

const ParsedArgs = union(enum) {
    ok: Args,
    exit: u8,
};

fn parseArgs(args: []const []const u8) ParsedArgs {
    var out = Args{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--full")) {
            out.full = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            out.json_only = true;
        } else if (std.mem.eql(u8, a, "--diff")) {
            i += 1;
            if (i < args.len) out.diff_path = args[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i < args.len) out.out_path = args[i];
        } else if (std.mem.eql(u8, a, "--filter")) {
            i += 1;
            if (i < args.len) out.filter = args[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printErr(
                "klio-bench [--full] [--json] [--filter substr] [--out file] [--diff baseline.json]\n",
                .{},
            );
            return .{ .exit = 0 };
        } else {
            printErr("unknown arg: {s}\n", .{a});
            return .{ .exit = 2 };
        }
    }
    return .{ .ok = out };
}

fn reportDiff(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8, report: *const BenchReport) std.mem.Allocator.Error!?u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, base_path, allocator, .unlimited) catch {
        printErr("[bench] baseline {s} unreadable; skipping diff\n", .{base_path});
        return null;
    };
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(BenchReport, allocator, data, .{ .ignore_unknown_fields = true }) catch {
        printErr("[bench] baseline {s} unreadable; skipping diff\n", .{base_path});
        return null;
    };
    defer parsed.deinit();

    const rows = schema.diff(allocator, &parsed.value, report) catch return null;
    defer allocator.free(rows);

    var red: usize = 0;
    var yellow: usize = 0;
    for (rows) |r| {
        const tag = switch (r.level) {
            .Green => " ok",
            .Yellow => blk: {
                yellow += 1;
                break :blk "yel";
            },
            .Red => blk: {
                red += 1;
                break :blk "RED";
            },
        };
        printErr("[{s}] {s: >8} {s: <40} {d: >10} ns  ({d:+.1}%)\n", .{
            tag,
            r.stage,
            r.workload,
            r.cur_ns,
            (r.ratio - 1.0) * 100.0,
        });
    }
    printErr("[bench] {d} red, {d} yellow, {d} total\n", .{ red, yellow, rows.len });
    if (red > 0) return 1;
    return null;
}

/// Library entry point. Returns the process exit code. Mirrors the Rust
/// `main` but takes args + allocator explicitly so the orchestrator wires
/// the real executable.
pub fn run(allocator: std.mem.Allocator, raw_args: []const []const u8) u8 {
    // Cap the bench process's RSS so a runaway corpus entry can't OOM the
    // machine. Call-once.
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const parsed = parseArgs(raw_args);
    const args = switch (parsed) {
        .ok => |a| a,
        .exit => |code| return code,
    };

    const root = bench.corpusRoot(allocator) catch return 1;
    defer allocator.free(root);
    const files = bench.collectKt(allocator, io, root) catch return 1;
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    const budget_ns: u64 = if (args.full) 1500 * std.time.ns_per_ms else 250 * std.time.ns_per_ms;

    var records: std.ArrayList(BenchRecord) = .empty;
    defer {
        for (records.items) |rec| {
            allocator.free(rec.stage);
            allocator.free(rec.workload);
        }
        records.deinit(allocator);
    }

    for (files) |path| {
        var prog = bench.Program.load(allocator, io, path) catch |e| {
            printErr("skip {s}: {s}\n", .{ path, @errorName(e) });
            continue;
        };
        defer prog.deinit();

        const label = prog.label(allocator) catch continue;
        defer allocator.free(label);

        if (args.filter) |f| {
            if (std.mem.indexOf(u8, label, f) == null) continue;
        }
        if (!args.json_only) {
            printErr("[bench] {s}\n", .{label});
        }

        const stages = bench.timePipelineStages(allocator, &prog, budget_ns) catch continue;
        const stage_pairs = [_]struct { name: []const u8, t: bench.Timing }{
            .{ .name = "lex", .t = stages.lex },
            .{ .name = "parse", .t = stages.parse },
            .{ .name = "resolve", .t = stages.resolve },
            .{ .name = "typeck", .t = stages.typeck },
            .{ .name = "e2e", .t = stages.e2e },
        };
        for (stage_pairs) |sp| {
            var rec = BenchRecord{
                .stage = allocator.dupe(u8, sp.name) catch continue,
                .workload = allocator.dupe(u8, label) catch continue,
                .median_ns = sp.t.median_ns,
                .p99_ns = sp.t.p99_ns,
                .iters = sp.t.iters,
            };
            if (args.full and std.mem.eql(u8, sp.name, "e2e")) {
                if (refrunner.timeKotlincNative(allocator, io, prog.path, 3)) |nat| {
                    switch (nat) {
                        .ok => |d| rec.ref_kotlinc_native_ns = d,
                        .err => |e| e.deinit(allocator),
                    }
                } else |_| {}
                if (refrunner.timeKotlincJvm(allocator, io, prog.path, 3)) |jvm| {
                    switch (jvm) {
                        .ok => |d| rec.ref_kotlinc_jvm_ns = d,
                        .err => |e| e.deinit(allocator),
                    }
                } else |_| {}
            }
            records.append(allocator, rec) catch {
                allocator.free(rec.stage);
                allocator.free(rec.workload);
                continue;
            };
        }
    }

    const sha = gitSha(allocator, io) orelse (allocator.dupe(u8, "unknown") catch return 1);
    defer allocator.free(sha);
    const host = hostString(allocator) catch return 1;
    defer allocator.free(host);

    const report = BenchReport{
        .git_sha = sha,
        .host = host,
        .records = records.items,
    };

    var json_buf: std.ArrayList(u8) = .empty;
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &json_buf);
        report.writeJson(&aw.writer) catch return 1;
        json_buf = aw.toArrayList();
    }
    defer json_buf.deinit(allocator);

    if (args.out_path) |p| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = json_buf.items }) catch |e| {
            printErr("write {s}: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
    } else {
        printOut(io, json_buf.items);
        printOut(io, "\n");
    }

    if (args.diff_path) |base| {
        if (reportDiff(allocator, io, base, &report) catch null) |code| {
            return code;
        }
    }

    return 0;
}

fn gitSha(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    const r = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
    }) catch return null;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return null;
    const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
    return allocator.dupe(u8, trimmed) catch null;
}

fn hostString(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    const os = @tagName(@import("builtin").os.tag);
    const arch = @tagName(@import("builtin").cpu.arch);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ os, arch });
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    // Silent under the test runner: arg-parsing tests exercise the usage/error
    // paths for their exit codes, and stray stderr makes `zig build test` flag
    // the test command as failed even though the unit passed.
    if (@import("builtin").is_test) return;
    std.debug.print(fmt, args);
}

fn printOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

const testing = std.testing;

test "parse args handles flags" {
    const a = parseArgs(&.{ "--full", "--json", "--filter", "micro", "--out", "x.json" });
    switch (a) {
        .ok => |args| {
            try testing.expect(args.full);
            try testing.expect(args.json_only);
            try testing.expectEqualStrings("micro", args.filter.?);
            try testing.expectEqualStrings("x.json", args.out_path.?);
        },
        .exit => return error.TestUnexpectedResult,
    }
}

test "parse args rejects unknown flag" {
    const a = parseArgs(&.{"--bogus"});
    try testing.expectEqual(@as(u8, 2), a.exit);
}

test "parse args help exits zero" {
    const a = parseArgs(&.{"--help"});
    try testing.expectEqual(@as(u8, 0), a.exit);
}
