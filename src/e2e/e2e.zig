//! End-to-end corpus test: every `examples/*.kt` through the `klio` binary
//! (`KLIO_ITEST_BIN`, the harness build.zig installs beside the suite),
//! asserted against the byte-exact expected stdout under
//! `tests/corpus/expected/`. The programs run in the shared test home, where
//! every shipped pack is installed as a user installs them (`klio_child`),
//! each with the arguments its `Run with:` header names.

const std = @import("std");
const runtime = @import("runtime");
const klio_child = @import("klio_child");

const EXAMPLES = "examples";
const EXPECTED = "tests/corpus/expected";
const RUN_TIMEOUT_MS: i64 = 180_000;

fn klioBin() []const u8 {
    return klio_child.bin();
}

/// `KLIO_E2E_SHARD=K/N` runs only the programs hashing into shard K of N.
fn shardSkip(stem: []const u8) bool {
    const s = runtime.envOnce("KLIO_E2E_SHARD") orelse return false;
    const slash = std.mem.findScalar(u8, s, '/') orelse return false;
    const k = std.fmt.parseInt(u64, s[0..slash], 10) catch return false;
    const n = std.fmt.parseInt(u64, s[slash + 1 ..], 10) catch return false;
    if (n == 0) return false;
    var h = std.hash.Wyhash.init(0);
    h.update(stem);
    return (h.final() % n) != k;
}

/// SKIP notices are silent by default: stderr from a passing `zig build` run
/// step is rendered as a failed command. `KLIO_ITEST_VERBOSE` surfaces them.
fn verbose() bool {
    return klio_child.verbose();
}

fn interactive(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 12) break;
        if (std.mem.find(u8, line, "corpus: interactive") != null) return true;
    }
    return false;
}

const Case = struct { path: []const u8, stem: []const u8, expected: []const u8, args: []const []const u8 };

const Shared = struct {
    cases: []const Case,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
    lock: runtime.SpinMutex = .{},
};

fn worker(sh: *Shared) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (true) {
        const i = sh.next.fetchAdd(1, .monotonic);
        if (i >= sh.cases.len) return;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const c = sh.cases[i];
        const failed = runCase(a, sh, c) catch |e| blk: {
            sh.lock.lock();
            defer sh.lock.unlock();
            std.debug.print("e2e FAIL {s}: {s}\n", .{ c.stem, @errorName(e) });
            break :blk true;
        };
        if (failed) _ = sh.failures.fetchAdd(1, .monotonic);
    }
}

fn runCase(a: std.mem.Allocator, sh: *Shared, c: Case) !bool {
    var env = try klio_child.baseEnv(a);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ klioBin(), "run", c.path });
    try argv.appendSlice(a, c.args);
    const r = try klio_child.runKlio(a, &env, argv.items, .{ .timeout_ms = RUN_TIMEOUT_MS });
    const ok = r.term == .exited and r.term.exited == 0 and std.mem.eql(u8, r.stdout, c.expected);
    if (ok) return false;
    sh.lock.lock();
    defer sh.lock.unlock();
    const code: i64 = switch (r.term) {
        .exited => |x| x,
        else => -1,
    };
    const err_head = r.stderr[0..@min(r.stderr.len, 600)];
    std.debug.print("e2e FAIL {s} exit {d}:\n  got:  {s}\n  want: {s}\n  stderr: {s}\n", .{ c.stem, code, r.stdout, c.expected, err_head });
    return true;
}

fn cases(a: std.mem.Allocator, io: std.Io, only: ?[]const []const u8) ![]Case {
    var out: std.ArrayList(Case) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, EXAMPLES, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".kt")) continue;
        const stem = try a.dupe(u8, e.name[0 .. e.name.len - ".kt".len]);
        if (only) |names| {
            var hit = false;
            for (names) |n| {
                if (std.mem.eql(u8, n, stem)) hit = true;
            }
            if (!hit) continue;
        }
        if (runtime.envOnce("KLIO_E2E_FILTER")) |f| {
            if (std.mem.find(u8, stem, f) == null) continue;
        }
        if (shardSkip(stem)) continue;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ EXAMPLES, e.name });
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        if (interactive(src)) continue;
        const exp_path = try std.fmt.allocPrint(a, "{s}/{s}.out", .{ EXPECTED, stem });
        const expected = std.Io.Dir.cwd().readFileAlloc(io, exp_path, a, .unlimited) catch |err| {
            if (verbose()) std.debug.print("e2e SKIP {s}: no expected ({s})\n", .{ stem, @errorName(err) });
            continue;
        };
        try out.append(a, .{ .path = path, .stem = stem, .expected = expected, .args = try klio_child.runArgs(a, src) });
    }
    std.mem.sort(Case, out.items, {}, struct {
        fn lt(_: void, x: Case, y: Case) bool {
            return std.mem.lessThan(u8, x.stem, y.stem);
        }
    }.lt);
    return out.items;
}

fn runCorpus(only: ?[]const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const list = cases(a, io, only) catch |e| {
        std.debug.print("e2e: cannot list the examples ({s}); skipping\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    if (list.len == 0) return error.SkipZigTest;
    // Installs the packs before the workers start when no home was named.
    _ = try klio_child.home(a);

    var sh: Shared = .{ .cases = list };
    const cores = std.Thread.getCpuCount() catch 4;
    const n = std.math.clamp(cores / 2, 1, 8);
    const threads = try a.alloc(std.Thread, n);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&sh});
    for (threads) |t| t.join();
    const failures = sh.failures.load(.monotonic);
    if (failures != 0) {
        std.debug.print("e2e: {d}/{d} corpus programs failed\n", .{ failures, list.len });
        return error.CorpusMismatch;
    }
}

test "e2e corpus matches expected output" {
    try runCorpus(null);
}
