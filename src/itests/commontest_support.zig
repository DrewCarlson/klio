//! Shared driver for library `commonTest` suites: discover a library's upstream
//! common test tree and run every `@Test`-bearing file through a child
//! `klio test` in the shared test home, where every shipped pack is installed
//! (`klio_child.home`). A file
//! without `@Test` is a shared fixture compiled into every test file's module,
//! and passes are counted per `PASSED` line so a killed file still counts.

const std = @import("std");
const runtime = @import("runtime");
const klio_child = @import("klio_child");

pub const Config = struct {
    name: []const u8,
    /// Common test directories, discovered recursively.
    test_roots: []const []const u8,
    /// Ratchet floor on total passing cases: raise as fixes land, never lower.
    baseline: usize,
    /// klio-authored actuals added to every test file's module.
    extra_support: []const []const u8 = &.{},
    timeout_ms: i64 = 60_000,
    require_no_failures: bool = false,
    /// Ceiling on failing cases, the mirror of the floor: a suite can trade a
    /// fixed test for a broken one and still clear it. Lower only.
    max_failed: ?usize = null,
    /// Compile the whole source set into every child, running only the target
    /// file's `@Test` methods: upstream commonTest is one compilation unit, so a
    /// top-level helper in one `@Test`-bearing file is visible from another.
    whole_source_set: bool = false,
    /// Ceiling on cases that never reported, which the floor and `max_failed`
    /// both miss.
    max_incomplete: ?usize = null,
    /// Files, matched by path suffix, emitted one child per `@Test`. The split
    /// child compiles the same closure, so counting is unchanged.
    split_files: []const []const u8 = &.{},
    /// One child per module directory (the path up to `/src/commonTest`). Pure
    /// unit-test modules only: classes must not share state across files.
    batch_dirs: bool = false,
    /// Extra environment for every child. A compute-heavy test declares its
    /// per-test wall budget through `KLIO_TEST_WALL_CAP_FOR` here.
    extra_env: []const [2][]const u8 = &.{},
    /// Extra `klio test` arguments for every child (`--feature …`).
    extra_args: []const []const u8 = &.{},
    /// A program the suite's tests reach over the network, run beside them.
    service: ?Service = null,
};

/// A program a suite's tests call over the network (a test server), run for
/// the suite's duration: `klio <args>` starts in the background, the suite
/// runs once `port` accepts connections on 127.0.0.1, and the service is
/// stopped when the suite ends. Its output goes to a log in the temporary
/// directory whose tail the census prints when the service never answers or
/// the suite fails.
pub const Service = struct {
    /// `klio` arguments, e.g. `run --feature io.ktor/test-server server.kt`.
    args: []const []const u8,
    /// The port the service listens on. Zero picks a free port, which the
    /// service and every test child read from `KLIO_SERVICE_PORT`. A fixed
    /// port serves tests that name one; suites sharing a fixed port take
    /// turns on a lock file, across worktrees too.
    port: u16 = 0,
    /// How long the port may take to accept, in ms on a ReleaseSafe harness.
    ready_ms: i64 = 180_000,
};

const RunningService = struct {
    child: std.process.Child,
    lock: ?std.Io.File,
    log_path: []const u8,

    fn stop(rs: *RunningService, io: std.Io) void {
        rs.child.kill(io);
        if (rs.lock) |f| {
            f.unlock(io);
            f.close(io);
        }
    }
};

fn tempDir(env: *const std.process.Environ.Map) []const u8 {
    return env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp";
}

fn freeLoopbackPort(io: std.Io) !u16 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    return srv.socket.address.getPort();
}

fn portAccepts(io: std.Io, port: u16) bool {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

/// The last `n` bytes of the service log, for a failure report.
fn serviceLogTail(a: std.mem.Allocator, io: std.Io, path: []const u8, n: usize) []const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |e| return @errorName(e);
    return bytes[if (bytes.len > n) bytes.len - n else 0..];
}

fn startService(
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    cfg: Config,
    svc: Service,
    slowdown: i64,
) !RunningService {
    const port = if (svc.port != 0) svc.port else try freeLoopbackPort(io);
    try env.put("KLIO_SERVICE_PORT", try std.fmt.allocPrint(a, "{d}", .{port}));
    const tmp = tempDir(env);
    var lock: ?std.Io.File = null;
    errdefer if (lock) |f| {
        f.unlock(io);
        f.close(io);
    };
    if (svc.port != 0) {
        const lock_path = try std.fs.path.join(a, &.{ tmp, try std.fmt.allocPrint(a, "klio-census-service-{d}.lock", .{port}) });
        const f = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false });
        f.lock(io, .exclusive) catch |e| {
            f.close(io);
            return e;
        };
        lock = f;
    }
    if (portAccepts(io, port)) {
        std.debug.print("{s}_commontest: port {d} is already taken; the service cannot start\n", .{ cfg.name, port });
        return error.ServicePortTaken;
    }
    const log_path = try std.fs.path.join(a, &.{ tmp, try std.fmt.allocPrint(a, "klio-census-{s}-service.log", .{cfg.name}) });
    const log = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    defer log.close(io);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, klioBin(env));
    try argv.appendSlice(a, svc.args);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    const deadline = runtime.clockMonotonicNanos() + @as(u64, @intCast(svc.ready_ms * slowdown)) * std.time.ns_per_ms;
    while (runtime.clockMonotonicNanos() < deadline) {
        if (portAccepts(io, port)) return .{ .child = child, .lock = lock, .log_path = log_path };
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }
    child.kill(io);
    std.debug.print("{s}_commontest: the service did not accept on port {d}; its log ({s}) ends:\n{s}\n", .{
        cfg.name, port, log_path, serviceLogTail(a, io, log_path, 2000),
    });
    return error.ServiceNotReady;
}

fn klioBin(env: *const std.process.Environ.Map) []const u8 {
    return env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
}

/// Child deadlines are tuned on ReleaseSafe; a Debug harness scales them by this.
const debug_harness_slowdown: i64 = 4;

pub fn harnessSlowdown(env: *const std.process.Environ.Map) i64 {
    return if (std.mem.endsWith(u8, klioBin(env), "-Debug")) debug_harness_slowdown else 1;
}

/// `KLIO_TEST_WALL_CAP_FOR` is `name=secs,name=secs`; multiply every `secs`.
fn scaleWallCapList(allocator: std.mem.Allocator, list: []const u8, factor: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    var first = true;
    while (it.next()) |item| {
        if (!first) try out.append(allocator, ',');
        first = false;
        if (std.mem.findScalarLast(u8, item, '=')) |eq| {
            if (std.fmt.parseInt(i64, item[eq + 1 ..], 10) catch null) |secs| {
                const scaled = try std.fmt.allocPrint(allocator, "{s}={d}", .{ item[0..eq], secs * factor });
                defer allocator.free(scaled);
                try out.appendSlice(allocator, scaled);
                continue;
            }
        }
        try out.appendSlice(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

pub fn scaleWallCaps(allocator: std.mem.Allocator, env: *std.process.Environ.Map, factor: i64) !void {
    const default_cap: i64 = 300;
    const cap = if (env.get("KLIO_TEST_WALL_CAP")) |v| (std.fmt.parseInt(i64, v, 10) catch default_cap) else default_cap;
    try env.put("KLIO_TEST_WALL_CAP", try std.fmt.allocPrint(allocator, "{d}", .{cap * factor}));
    if (env.get("KLIO_TEST_WALL_CAP_FOR")) |list| {
        try env.put("KLIO_TEST_WALL_CAP_FOR", try scaleWallCapList(allocator, list, factor));
    }
}

test "wall cap list scaling multiplies every per-test cap" {
    const a = std.testing.allocator;
    const got = try scaleWallCapList(a, "A.t=390,B.test=10,odd", 4);
    defer a.free(got);
    try std.testing.expectEqualStrings("A.t=1560,B.test=40,odd", got);
}

fn envWithHome(allocator: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(allocator, &map);
    try map.put("HOME", home);
    try map.put("KLIO_HOME", home);
    return map;
}

fn workerCount() usize {
    // KLIO_ITEST_JOBS overrides the width; the clamp keeps a full-stack run
    // from oversubscribing when every suite spawns its own pool.
    if (std.c.getenv("KLIO_ITEST_JOBS")) |v| {
        if (std.fmt.parseInt(usize, std.mem.span(v), 10) catch null) |n| {
            if (n >= 1) return @min(n, 64);
        }
    }
    const cores = std.Thread.getCpuCount() catch 4;
    return std.math.clamp(cores, 1, 8);
}

const RunResult = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

fn runKlio(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
    timeout_ms: i64,
) !RunResult {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const r = std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |e| {
        if (e == error.Timeout) return .{ .term = .{ .exited = 124 }, .stdout = "", .stderr = "" };
        std.debug.print("{s}_commontest: spawn {s} failed: {s}\n", .{ argv[0], argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn collectKt(a: std.mem.Allocator, io: std.Io, dir: []const u8, out: *std.ArrayList([]u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            const sub = try std.fs.path.join(a, &.{ dir, entry.name });
            try collectKt(a, io, sub, out);
        } else if (std.mem.endsWith(u8, entry.name, ".kt")) {
            try out.append(a, try std.fs.path.join(a, &.{ dir, entry.name }));
        }
    }
}

fn fileHasTest(a: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return false;
    return std.mem.find(u8, bytes, "@Test") != null;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// What one test source contributes to, and needs from, its compilation unit.
/// Declarations count only at column zero, so a member never provides for
/// another file.
const DeclScan = struct {
    package: []const u8,
    /// Packages this file resolves unqualified names against.
    scopes: []const []const u8,
    declares: []const []const u8,
    words: []const []const u8,
};

const decl_keywords = [_][]const u8{ "fun", "val", "var", "class", "interface", "object", "typealias" };
const decl_modifiers = [_][]const u8{
    "public",   "internal", "private", "protected", "expect",  "actual",
    "open",     "abstract", "sealed",  "final",     "data",    "value",
    "enum",     "annotation", "inline", "suspend",  "external", "const",
    "lateinit", "operator", "infix",   "tailrec",
};

fn wordAt(src: []const u8, i: usize) []const u8 {
    var e = i;
    while (e < src.len and isIdentByte(src[e])) e += 1;
    return src[i..e];
}

fn isDeclKeyword(w: []const u8) bool {
    for (decl_keywords) |k| if (std.mem.eql(u8, w, k)) return true;
    return false;
}

fn isDeclModifier(w: []const u8) bool {
    for (decl_modifiers) |k| if (std.mem.eql(u8, w, k)) return true;
    return false;
}

/// The name a top-level declaration binds, given the text after its keyword.
/// `inline fun<T: Flow<Int>> CoroutineScope.helper(...)` yields `helper`.
fn declaredName(tail: []const u8, is_fun: bool) ?[]const u8 {
    var i: usize = 0;
    while (i < tail.len and (tail[i] == ' ' or tail[i] == '\t')) i += 1;
    if (i < tail.len and tail[i] == '<') {
        var depth: usize = 0;
        while (i < tail.len) : (i += 1) {
            if (tail[i] == '<') depth += 1;
            if (tail[i] == '>') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
            if (tail[i] == '\n') return null;
        }
        while (i < tail.len and (tail[i] == ' ' or tail[i] == '\t')) i += 1;
    }
    if (i >= tail.len or !(std.ascii.isAlphabetic(tail[i]) or tail[i] == '_')) return null;
    if (!is_fun) return wordAt(tail, i);
    var name = wordAt(tail, i);
    var k = i + name.len;
    while (k < tail.len) {
        switch (tail[k]) {
            '<', '[' => {
                var depth: usize = 0;
                while (k < tail.len) : (k += 1) {
                    if (tail[k] == '<' or tail[k] == '[') depth += 1;
                    if (tail[k] == '>' or tail[k] == ']') {
                        depth -= 1;
                        if (depth == 0) {
                            k += 1;
                            break;
                        }
                    }
                    if (tail[k] == '\n') return name;
                }
            },
            '?' => k += 1,
            '.' => {
                k += 1;
                if (k >= tail.len or !(std.ascii.isAlphabetic(tail[k]) or tail[k] == '_')) return name;
                name = wordAt(tail, k);
                k += name.len;
            },
            else => return name,
        }
    }
    return name;
}

/// The first `class X` name in the file, the test class for `--filter`.
fn classNameOf(src: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.findPos(u8, src, i, "class ")) |p| {
        i = p + 6;
        if (p != 0 and isIdentByte(src[p - 1])) continue;
        var e = i;
        while (e < src.len and isIdentByte(src[e])) e += 1;
        if (e > i) return src[i..e];
    }
    return null;
}

/// Every `fun NAME` following an `@Test`, tolerating modifier lines between.
fn collectTestFns(a: std.mem.Allocator, src: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (std.mem.findPos(u8, src, i, "@Test")) |p| {
        i = p + 5;
        const fnp = std.mem.findPos(u8, src, i, "fun ") orelse return;
        // The fn belongs to this annotation only if no further @Test precedes it.
        if (std.mem.findPos(u8, src, i, "@Test")) |nxt| {
            if (nxt < fnp) continue;
        }
        const e = fnp + 4;
        var b2 = e;
        while (b2 < src.len and isIdentByte(src[b2])) b2 += 1;
        if (b2 > e) try out.append(a, src[e..b2]);
        i = b2;
    }
}

fn scanDecls(a: std.mem.Allocator, src: []const u8) !DeclScan {
    var declares: std.ArrayList([]const u8) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    var scopes: std.ArrayList([]const u8) = .empty;
    var package: []const u8 = "";
    var line_start = true;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            line_start = true;
            i += 1;
            continue;
        }
        if (!(std.ascii.isAlphabetic(c) or c == '_')) {
            if (c != ' ' and c != '\t') line_start = false;
            i += 1;
            continue;
        }
        const w = wordAt(src, i);
        try words.append(a, w);
        if (line_start and (i == 0 or src[i - 1] == '\n')) {
            if (std.mem.eql(u8, w, "package")) {
                var p = i + w.len;
                while (p < src.len and (src[p] == ' ' or src[p] == '\t')) p += 1;
                var e = p;
                while (e < src.len and src[e] != '\n' and src[e] != ' ') e += 1;
                package = src[p..e];
            } else if (std.mem.eql(u8, w, "import")) {
                var p = i + w.len;
                while (p < src.len and (src[p] == ' ' or src[p] == '\t')) p += 1;
                var e = p;
                while (e < src.len and (isIdentByte(src[e]) or src[e] == '.' or src[e] == '*')) e += 1;
                const path = src[p..e];
                // `import a.b.*` and `import a.b.Name` both scope package `a.b`.
                if (std.mem.findScalarLast(u8, path, '.')) |dot| {
                    try scopes.append(a, path[0..dot]);
                }
            } else {
                var p = i;
                var head = w;
                while (isDeclModifier(head)) {
                    p += head.len;
                    while (p < src.len and (src[p] == ' ' or src[p] == '\t')) p += 1;
                    if (p >= src.len or !(std.ascii.isAlphabetic(src[p]) or src[p] == '_')) break;
                    head = wordAt(src, p);
                }
                if (isDeclKeyword(head)) {
                    const tail = src[p + head.len ..];
                    if (declaredName(tail, std.mem.eql(u8, head, "fun"))) |n| try declares.append(a, n);
                }
            }
        }
        line_start = false;
        i += w.len;
    }
    try scopes.append(a, package);
    return .{ .package = package, .scopes = scopes.items, .declares = declares.items, .words = words.items };
}

/// Test files `target` must compile with, transitively, because it names
/// something they declare at top level in its own package. Compiled alone it
/// silently loses the inherited cases.
fn providerClosure(
    a: std.mem.Allocator,
    scans: []const DeclScan,
    owner: *const std.StringHashMapUnmanaged(std.ArrayList(usize)),
    target: usize,
) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    var queue: std.ArrayList(usize) = .empty;
    try queue.append(a, target);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const s = scans[queue.items[head]];
        for (s.words) |name| {
            for (s.declares) |d| {
                if (std.mem.eql(u8, d, name)) break;
            } else {
                for (s.scopes) |scope| {
                    const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ scope, name });
                    const owners = owner.get(key) orelse continue;
                    for (owners.items) |idx| {
                        for (queue.items) |seen| {
                            if (seen == idx) break;
                        } else {
                            try queue.append(a, idx);
                            try out.append(a, idx);
                        }
                    }
                }
            }
        }
    }
    return out.items;
}

/// Count per-test `PASSED` lines (`<Class>.<method> PASSED`).
fn passedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " PASSED")) n += 1;
    }
    return n;
}

/// Sum the `N failed` counts from every `M tests, ... N failed, ...` line.
fn failedCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const marker = " failed,";
        const idx = std.mem.find(u8, line, marker) orelse continue;
        var start = idx;
        while (start > 0 and line[start - 1] >= '0' and line[start - 1] <= '9') start -= 1;
        n += std.fmt.parseInt(usize, line[start..idx], 10) catch 0;
    }
    return n;
}

var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// ktor's own test server (tests/fixtures/ktor/test_server.kt over the pack's
/// `test-server` feature), which the ktor client suites call at
/// 127.0.0.1:8080 as upstream's do. The tests name the port, so it is fixed.
const ktor_test_server: Service = .{
    .args = &.{ "run", "--feature", "io.ktor/test-server", "tests/fixtures/ktor/test_server.kt" },
    .port = 8080,
};

/// The suite registry, shared by the itest gates and the `klio-census` driver.
/// Floors and ceilings are ratchets: tighten only.
pub const suites = [_]Config{
    .{
        .name = "coroutines",
        .test_roots = &.{"kotlin-klio/klio-kotlinx-coroutines/upstream/kotlinx-coroutines-core/common/test"},
        .extra_support = &.{
            "kotlin-klio/klio-kotlinx-coroutines/upstream/test-utils/common/src/TestBase.common.kt",
            "kotlin-klio/klio-kotlinx-coroutines/upstream/test-utils/common/src/LaunchFlow.kt",
            "kotlin-klio/klio-kotlinx-coroutines/upstream/test-utils/common/src/MainDispatcherTestBase.kt",
            "kotlin-klio/klio-kotlinx-coroutines/klioTest/kotlinx/coroutines/testing/TestBase.kt",
        },
        // The hot children cross the 60s default under load; the cap is a hang
        // guard, not a wall ratchet.
        .timeout_ms = 150_000,
        .baseline = 1299,
        .max_failed = 0,
        .max_incomplete = 1,
    },
    .{
        .name = "datetime",
        .test_roots = &.{
            "kotlin-klio/klio-kotlinx-datetime/upstream/core/common/test",
            "kotlin-klio/klio-kotlinx-datetime/upstream/core/commonKotlin/test",
        },
        .whole_source_set = true,
        .timeout_ms = 1_000_000,
        // These two are compute-bound and run for minutes.
        .extra_env = &.{.{ "KLIO_TEST_WALL_CAP_FOR", "LocalDateTest.fromEpochDays=900,LocalDateTest.toEpochDays=600" }},
        .split_files = &.{"common/test/LocalDateTest.kt"},
        .baseline = 519,
        .max_failed = 0,
        .max_incomplete = 1,
    },
    .{
        .name = "serialization",
        .test_roots = &.{"kotlin-klio/klio-kotlinx-serialization/upstream/core/commonTest"},
        .extra_support = &.{"kotlin-klio/klio-kotlinx-serialization/klioTest/kotlinx/serialization/test/CurrentPlatform.kt"},
        .baseline = 138,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        .name = "serialization_json",
        .test_roots = &.{"kotlin-klio/klio-kotlinx-serialization/upstream/formats/json-tests/commonTest/src"},
        .extra_support = &.{
            "kotlin-klio/klio-kotlinx-serialization/klioTest/kotlinx/serialization/test/CurrentPlatform.kt",
            "kotlin-klio/klio-kotlinx-serialization/klioTest/json/StreamSupport.kt",
            "kotlin-klio/klio-kotlinx-serialization/upstream/formats/json-okio/commonMain/src/kotlinx/serialization/json/okio/OkioStreams.kt",
            "kotlin-klio/klio-kotlinx-serialization/upstream/formats/json-okio/commonMain/src/kotlinx/serialization/json/okio/internal/OkioJsonStreams.kt",
        },
        // The suite's KXIO streaming mode runs the json-io module, which pulls json and the kotlinx.io pack.
        .extra_args = &.{ "--feature", "kotlinx.serialization/json-io" },
        // Two compute-heavy files; splitting keeps their fast tests counted.
        .split_files = &.{ "json/JsonHugeDataSerializationTest.kt", "json/JsonUnicodeTest.kt" },
        .extra_env = &.{.{ "KLIO_TEST_WALL_CAP_FOR", "JsonUnicodeTest.testRandomEscapeSequences=900,JsonHugeDataSerializationTest.test=900" }},
        .timeout_ms = 1_000_000,
        .baseline = 747,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        .name = "io",
        .test_roots = &.{
            "kotlin-klio/klio-kotlinx-io/upstream/core/common/test",
            "kotlin-klio/klio-kotlinx-io/upstream/bytestring/common/test",
        },
        .extra_support = &.{"kotlin-klio/klio-kotlinx-io/klioTest/kotlinx/io/TestActuals.kt"},
        .baseline = 1191,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // The census form of `itest-androidx_collection_commontest`, which
        // also runs its inline-receiver smoke first.
        .name = "androidx_collection",
        .test_roots = &.{"kotlin-klio/klio-androidx-collection/upstream/collection/collection/src/commonTest/kotlin"},
        // Above the compute-heavy tail: a 1M-iteration stress test.
        .timeout_ms = 180_000,
        .baseline = 1841,
        .max_failed = 0,
    },
    .{
        .name = "atomicfu",
        .test_roots = &.{"kotlin-klio/klio-kotlinx-atomicfu/upstream/atomicfu/src/commonTest/kotlin"},
        .whole_source_set = true,
        .baseline = 67,
        .max_failed = 0,
        .max_incomplete = 2,
    },
    .{
        .name = "ktor",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-io/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-utils/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-http/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-http/ktor-http-cio/common/test",
        },
        // Pinning http-cio (which pulls http, utils and io) keeps the load
        // from activating serialization.
        .extra_args = &.{ "--feature", "io.ktor/http-cio", "--feature", "io.ktor/test-base" },
        .baseline = 496,
        .max_failed = 0,
        .max_incomplete = 2,
    },
    .{
        // ktor-network's common, jvmAndPosix and posix suites over klio's
        // socket layer. The nix-only suites test upstream's pselect selector
        // and read descriptors through cinterop, neither of which klio runs;
        // their nix TestUtils actual is the one file taken from that set.
        .name = "ktor_network",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-network/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-network/jvmAndPosix/test",
            "kotlin-klio/klio-ktor/upstream/ktor-network/posix/test",
        },
        .extra_support = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-network/nix/test/io/ktor/network/sockets/tests/TestUtils.nix.kt",
        },
        .extra_args = &.{ "--feature", "io.ktor/network", "--feature", "io.ktor/test-base" },
        .baseline = 25,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // ktor-client-core's commonTest, with ktor-client-mock's own suite:
        // the client, its plugins and `MockEngine`.
        .name = "ktor_client_core",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-core/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-mock/common/test",
        },
        .extra_args = &.{ "--feature", "io.ktor/client-mock,server-test-host,client-content-negotiation,serialization-kotlinx-json,test-base" },
        .baseline = 93,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // ktor-server-core's commonTest with the test host's and test base's
        // own suites: routing, plugins, hooks, config and `testApplication`.
        .name = "ktor_server_core",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-core/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-test-host/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-test-base/common/test",
        },
        .extra_args = &.{ "--feature", "io.ktor/server-test-base,serialization-kotlinx-json" },
        .baseline = 147,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // ktor-server-cio's commonTest: the CIO engine through the shared
        // engine suites (HTTP, WebSockets) over real loopback sockets.
        .name = "ktor_server_cio",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-cio/common/test",
        },
        .extra_args = &.{ "--feature", "io.ktor/server-cio,server-test-suites" },
        .timeout_ms = 300_000,
        .baseline = 98,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // ktor-server-tests' commonTest (routing, sessions, cookies, the
        // plugins of the `ktor-server` umbrella), with upstream's JVM
        // CompressionTest and CompressionAcceptEncodingTest ported to klio.
        .name = "ktor_server_tests",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-tests/common/test",
            "kotlin-klio/klio-ktor/klioTest/io/ktor/server/plugins/compression",
        },
        .extra_args = &.{ "--feature", "io.ktor/server-test-host,test-base,server-rate-limit,server-auto-head-response,server-caching-headers,server-call-id,server-compression,server-conditional-headers,server-content-negotiation,server-cors,server-data-conversion,server-double-receive,server-forwarded-header,server-hsts,server-http-redirect,server-method-override,server-partial-content,server-sessions,server-sse,server-status-pages,serialization-kotlinx-json" },
        .timeout_ms = 90_000,
        .baseline = 455,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // The server plugin modules' commonTest suites, each over
        // `testApplication`.
        .name = "ktor_server_plugins",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-auth/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-auth-api-key/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-body-limit/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-caching-headers/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-content-negotiation/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-csrf/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-default-headers/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-double-receive/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-rate-limit/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-request-validation/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-resources/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-sessions/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-sse/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-status-pages/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-websockets/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-server/ktor-server-plugins/ktor-server-di/common/test",
            // Upstream's JVM CallLoggingTest on klio's CallLogging port.
            "kotlin-klio/klio-ktor/klioTest/io/ktor/server/plugins/calllogging",
        },
        .extra_args = &.{ "--feature", "io.ktor/server-test-host,server-auth,server-auth-api-key,server-body-limit,server-caching-headers,server-call-logging,server-content-negotiation,server-csrf,server-default-headers,server-di,server-double-receive,server-rate-limit,server-request-validation,server-resources,server-sessions,server-sse,server-status-pages,server-websockets,server-call-id,client-content-negotiation,client-websockets,serialization-kotlinx-json,test-base" },
        // A hung case fails on runTest's own 60 s timeout; the child needs
        // the time to report it.
        .timeout_ms = 90_000,
        .baseline = 297,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // The client plugin modules' commonTest suites, over `MockEngine` and
        // `testApplication`.
        .name = "ktor_client_plugins",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-plugins/ktor-client-auth/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-plugins/ktor-client-bom-remover/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-plugins/ktor-client-call-id/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-plugins/ktor-client-content-negotiation/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-plugins/ktor-client-encoding/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-plugins/ktor-client-resources/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-plugins/ktor-client-websockets/common/test",
        },
        .extra_args = &.{ "--feature", "io.ktor/client-mock,client-test-base,client-auth,client-bom-remover,client-call-id,client-content-negotiation,client-encoding,client-resources,client-websockets,client-logging,server-test-host,server-call-id,serialization-kotlinx-json" },
        // AuthTest, BomRemoverTest, ContentEncodingTest and WebSocketRemoteTest
        // call ktor's test server through every registered engine.
        .service = ktor_test_server,
        .baseline = 125,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // ktor-client-tests' commonTest: the client end to end over CIO
        // against ktor's test server.
        .name = "ktor_client_tests",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-tests/common/test",
        },
        // The module's commonMain, which its tests build on.
        .extra_support = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-tests/common/src/io/ktor/client/tests/utils/Generators.kt",
        },
        .extra_args = &.{ "--feature", "io.ktor/client-cio,client-test-base,client-mock,client-logging,client-auth,client-encoding,client-content-negotiation,client-websockets,serialization-kotlinx-json,test-base" },
        .service = ktor_test_server,
        .timeout_ms = 300_000,
        // DispatcherTest x1: Dispatchers.IO's toString is not "Dispatchers.IO".
        .baseline = 387,
        .max_failed = 1,
        .max_incomplete = 0,
    },
    .{
        // ktor-client-cio's commonTest: the CIO engine's own cases, against
        // ktor's test server and servers of their own.
        .name = "ktor_client_cio",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-client/ktor-client-cio/common/test",
        },
        .extra_args = &.{ "--feature", "io.ktor/client-cio,client-test-base,client-websockets,network,test-base" },
        .service = ktor_test_server,
        .timeout_ms = 300_000,
        .baseline = 13,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // ktor-serialization-kotlinx-json's commonTest over the shared
        // serialization test base.
        .name = "ktor_serialization",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-shared/ktor-serialization/ktor-serialization-kotlinx/ktor-serialization-kotlinx-json/common/test",
        },
        .extra_support = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-shared/ktor-serialization/ktor-serialization-kotlinx/ktor-serialization-kotlinx-tests/common/src/AbstractSerializationTest.kt",
            "kotlin-klio/klio-ktor/upstream/ktor-shared/ktor-serialization/ktor-serialization-kotlinx/ktor-serialization-kotlinx-tests/common/src/AbstractContextualSerializationTest.kt",
        },
        .extra_args = &.{ "--feature", "io.ktor/serialization-kotlinx-json,client-mock,client-content-negotiation,test-base" },
        .baseline = 14,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // The shared modules' commonTest suites: the WebSocket frame and
        // session model, type-safe resources and the test base.
        .name = "ktor_shared",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-shared/ktor-websockets/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-shared/ktor-resources/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-shared/ktor-test-base/common/test",
        },
        .extra_args = &.{ "--feature", "io.ktor/websockets,resources,test-base" },
        .baseline = 50,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // Kruth's assertion surface is a klio-authored stand-in under
        // tests/compose_ui_commontest_actuals.
        .name = "compose_ui",
        .test_roots = &.{
            "kotlin-klio/klio-compose-runtime/upstream/compose/ui/ui-util/src/commonTest/kotlin",
            "kotlin-klio/klio-compose-runtime/upstream/compose/ui/ui-geometry/src/commonTest/kotlin",
            "kotlin-klio/klio-compose-runtime/upstream/compose/ui/ui-unit/src/commonTest/kotlin",
            "kotlin-klio/klio-compose-runtime/upstream/compose/ui/ui-graphics/src/commonTest/kotlin",
            "kotlin-klio/klio-compose-runtime/upstream/compose/ui/ui-text/src/commonTest/kotlin",
            "kotlin-klio/klio-compose-runtime/upstream/compose/ui/ui/src/commonTest/kotlin",
        },
        .extra_support = &.{
            "tests/compose_ui_commontest_actuals/androidx/kruth/Kruth.kt",
        },
        .batch_dirs = true,
        // Each child compiles its module's whole commonTest set once (~115s on
        // four cores), so the cap leaves room for a slower machine.
        .timeout_ms = 600_000,
        .baseline = 452,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // animation-core's commonTest, asserted through upstream Kruth.
        .name = "compose_animation",
        .test_roots = &.{"kotlin-klio/klio-compose-runtime/upstream/compose/animation/animation-core/src/commonTest/kotlin"},
        .extra_support = &kruth_support,
        .extra_args = &.{ "--feature", "kotlinx.coroutines/test" },
        .batch_dirs = true,
        .timeout_ms = 300_000,
        .baseline = 107,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // graphics-shapes' commonTest (the rounded polygons and morphs
        // material3 draws), asserted through upstream Kruth.
        .name = "compose_shapes",
        .test_roots = &.{"kotlin-klio/klio-compose-runtime/upstream/graphics/graphics-shapes/src/commonTest/kotlin"},
        .extra_support = &kruth_support,
        .batch_dirs = true,
        .timeout_ms = 300_000,
        .baseline = 148,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // lifecycle-viewmodel's commonTest (ViewModel, its store, the
        // provider and its factories), asserted through upstream Kruth, with
        // klio's actual of the suite's IgnoreWebTarget.
        .name = "lifecycle_viewmodel",
        .test_roots = &.{"kotlin-klio/klio-compose-runtime/upstream/lifecycle/lifecycle-viewmodel/src/commonTest/kotlin"},
        .extra_support = &(kruth_support ++ [_][]const u8{"tests/lifecycle_commontest_actuals/viewmodel"}),
        .extra_args = &.{ "--feature", "androidx.lifecycle/viewmodel" },
        .batch_dirs = true,
        .timeout_ms = 300_000,
        .baseline = 35,
        .max_failed = 0,
        .max_incomplete = 0,
    },
    .{
        // savedstate's commonTest (SavedState, its registry, and the
        // kotlinx.serialization codec), asserted through upstream Kruth, with
        // the nonAndroidTest actuals and klio's IgnoreWebTarget. The codec
        // failures are a reified `T?` losing its `?` inside another inline
        // function's reified `T`, so the non-null serializer is picked.
        .name = "savedstate",
        .test_roots = &.{"kotlin-klio/klio-compose-runtime/upstream/savedstate/savedstate/src/commonTest/kotlin"},
        .extra_support = &(kruth_support ++ [_][]const u8{
            "kotlin-klio/klio-compose-runtime/upstream/savedstate/savedstate/src/nonAndroidTest/kotlin",
            "tests/savedstate_commontest_actuals",
        }),
        .extra_args = &.{ "--feature", "kotlinx.serialization/json" },
        .batch_dirs = true,
        .timeout_ms = 600_000,
        .baseline = 333,
        .max_failed = 23,
        .max_incomplete = 0,
    },
};

/// androidx.kruth, the assertion library the compose suites are written
/// against, from the upstream checkout.
const kruth_support = [_][]const u8{
    "kotlin-klio/klio-compose-runtime/upstream/kruth/kruth/src/commonMain/kotlin",
    "kotlin-klio/klio-compose-runtime/upstream/kruth/kruth/src/nonJvmMain/kotlin",
    "kotlin-klio/klio-compose-runtime/upstream/kruth/kruth/src/nativeMain/kotlin",
};

pub fn runSuiteNamed(name: []const u8) !void {
    for (&suites) |*cfg| {
        if (std.mem.eql(u8, cfg.name, name)) return runSuite(cfg.*);
    }
    std.debug.print("unknown census suite: {s}\n", .{name});
    return error.UnknownSuite;
}

pub fn runSuite(cfg: Config) !void {
    const a = arena_inst.allocator();
    defer _ = arena_inst.reset(.free_all);
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var any_root = false;
    for (cfg.test_roots) |root| {
        if (std.Io.Dir.cwd().access(io, root, .{})) |_| any_root = true else |_| {}
    }
    if (!any_root) {
        std.debug.print("{s}_commontest: no commonTest path present; skipping\n", .{cfg.name});
        return error.SkipZigTest;
    }

    var env = try envWithHome(a, try klio_child.home(a));
    for (cfg.extra_env) |kv| try env.put(kv[0], kv[1]);
    const slowdown = harnessSlowdown(&env);
    if (slowdown != 1) try scaleWallCaps(a, &env, slowdown);

    var all: std.ArrayList([]u8) = .empty;
    for (cfg.test_roots) |root| try collectKt(a, io, root, &all);
    std.mem.sort([]u8, all.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var support: std.ArrayList([]const u8) = .empty;
    for (cfg.extra_support) |s| try support.append(a, s);
    var targets: std.ArrayList([]const u8) = .empty;
    for (all.items) |p| {
        if (fileHasTest(a, io, p)) try targets.append(a, p) else try support.append(a, p);
    }

    var scans: std.ArrayList(DeclScan) = .empty;
    var owner: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (targets.items, 0..) |t, ti| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, t, a, .unlimited) catch "";
        const s = try scanDecls(a, bytes);
        try scans.append(a, s);
        for (s.declares) |d| {
            const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ s.package, d });
            const gop = try owner.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, ti);
        }
    }

    var jobs: std.ArrayList([]const []const u8) = .empty;
    // Split-file children carry the longest tests, so they head the queue.
    var split_jobs: std.ArrayList([]const []const u8) = .empty;
    if (cfg.batch_dirs) {
        var group_index = std.StringHashMap(usize).init(a);
        var group_files: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        for (targets.items) |target| {
            const key: []const u8 = if (std.mem.find(u8, target, "/src/commonTest")) |ix|
                target[0 .. ix + "/src/commonTest".len]
            else
                std.fs.path.dirname(target) orelse target;
            const gop = try group_index.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = group_files.items.len;
                try group_files.append(a, .empty);
            }
            try group_files.items[gop.value_ptr.*].append(a, target);
        }
        for (group_files.items) |files| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, klioBin(&env));
            try argv.append(a, "test");
            try argv.appendSlice(a, cfg.extra_args);
            try argv.appendSlice(a, support.items);
            try argv.appendSlice(a, files.items);
            if (std.c.getenv("KLIO_CENSUS_ARGV") != null) {
                std.debug.print("[census-argv]", .{});
                for (argv.items) |arg| std.debug.print(" {s}", .{arg});
                std.debug.print("\n", .{});
            }
            try jobs.append(a, try argv.toOwnedSlice(a));
        }
    }
    for (targets.items, 0..) |target, ti| {
        if (cfg.batch_dirs) break;
        const split_this = blk: {
            for (cfg.split_files) |sf| {
                if (std.mem.endsWith(u8, target, sf)) break :blk true;
            }
            break :blk false;
        };
        if (split_this) {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, target, a, .unlimited) catch "";
            const cls = classNameOf(bytes) orelse target;
            var names: std.ArrayList([]const u8) = .empty;
            try collectTestFns(a, bytes, &names);
            for (names.items) |tn| {
                var argv: std.ArrayList([]const u8) = .empty;
                try argv.append(a, klioBin(&env));
                try argv.append(a, "test");
                try argv.appendSlice(a, cfg.extra_args);
                if (cfg.whole_source_set) {
                    try argv.appendSlice(a, support.items);
                    try argv.appendSlice(a, targets.items);
                } else {
                    const bases = try providerClosure(a, scans.items, &owner, ti);
                    try argv.appendSlice(a, support.items);
                    for (bases) |bi| try argv.append(a, targets.items[bi]);
                    try argv.append(a, target);
                }
                try argv.append(a, try std.fmt.allocPrint(a, "--filter={s}.{s}", .{ cls, tn }));
                if (std.c.getenv("KLIO_CENSUS_ARGV") != null) {
                    std.debug.print("[census-argv]", .{});
                    for (argv.items) |arg| std.debug.print(" {s}", .{arg});
                    std.debug.print("\n", .{});
                }
                try split_jobs.append(a, try argv.toOwnedSlice(a));
            }
            if (names.items.len != 0) continue;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, klioBin(&env));
        try argv.append(a, "test");
        try argv.appendSlice(a, cfg.extra_args);
        if (cfg.whole_source_set) {
            try argv.append(a, "--only-file");
            try argv.append(a, target);
            try argv.appendSlice(a, support.items);
            try argv.appendSlice(a, targets.items);
        } else {
            const bases = try providerClosure(a, scans.items, &owner, ti);
            if (bases.len != 0) {
                // `--only-file` keeps providers compiled but unrun, so each
                // case counts once.
                try argv.append(a, "--only-file");
                try argv.append(a, target);
            }
            try argv.appendSlice(a, support.items);
            for (bases) |bi| try argv.append(a, targets.items[bi]);
            try argv.append(a, target);
        }
        if (std.c.getenv("KLIO_CENSUS_ARGV") != null) {
                    std.debug.print("[census-argv]", .{});
                    for (argv.items) |arg| std.debug.print(" {s}", .{arg});
                    std.debug.print("\n", .{});
                }
                try jobs.append(a, try argv.toOwnedSlice(a));
    }
    if (split_jobs.items.len != 0) {
        try split_jobs.appendSlice(a, jobs.items);
        jobs = split_jobs;
    }

    var next = std.atomic.Value(usize).init(0);
    var total_passed = std.atomic.Value(usize).init(0);
    var total_failed = std.atomic.Value(usize).init(0);
    var hung = std.atomic.Value(usize).init(0);
    const Pool = struct {
        fn worker(
            queue: []const []const []const u8,
            penv: *std.process.Environ.Map,
            pnext: *std.atomic.Value(usize),
            ppassed: *std.atomic.Value(usize),
            pfailed: *std.atomic.Value(usize),
            phung: *std.atomic.Value(usize),
            timeout_ms: i64,
        ) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            while (true) {
                const i = pnext.fetchAdd(1, .monotonic);
                if (i >= queue.len) return;
                _ = arena.reset(.retain_capacity);
                const ct_t0 = runtime.clockMonotonicNanos();
                const r = runKlio(arena.allocator(), penv, queue[i], timeout_ms) catch |e| {
                    _ = phung.fetchAdd(1, .monotonic);
                    std.debug.print("[census-hung] {s} <- {s}\n", .{ @errorName(e), queue[i][queue[i].len - 1] });
                    continue;
                };
                if (std.c.getenv("KLIO_CENSUS_TIMES") != null) {
                    // The target follows `--only-file`, else it is the last arg.
                    var tgt: []const u8 = queue[i][queue[i].len - 1];
                    for (queue[i], 0..) |arg2, qi| {
                        if (std.mem.eql(u8, arg2, "--only-file") and qi + 1 < queue[i].len) {
                            tgt = queue[i][qi + 1];
                            break;
                        }
                    }
                    std.debug.print("[census-time] {d}ms files={d} passed={d} target={s}\n", .{
                        (runtime.clockMonotonicNanos() -% ct_t0) / std.time.ns_per_ms,
                        queue[i].len - 2,
                        passedLineCount(r.stdout),
                        tgt,
                    });
                }
                _ = ppassed.fetchAdd(passedLineCount(r.stdout), .monotonic);
                const nf = failedCount(r.stdout);
                _ = pfailed.fetchAdd(nf, .monotonic);
                // Name every failing case: a red census has no other way to say
                // what drifted.
                if (nf != 0) {
                    const want_err = std.c.getenv("KLIO_CENSUS_ERRS") != null;
                    var itn = std.mem.splitScalar(u8, r.stdout, '\n');
                    var prev_failed = false;
                    while (itn.next()) |line| {
                        if (want_err and prev_failed and line.len != 0 and (line[0] == ' ' or line[0] == '\t')) {
                            std.debug.print("[census-err] {s}\n", .{std.mem.trim(u8, line, " \t")});
                        }
                        prev_failed = false;
                        if (std.mem.endsWith(u8, line, " FAILED")) {
                            std.debug.print("[census-fail] {s} <- {s}\n", .{ line, queue[i][queue[i].len - 1] });
                            prev_failed = true;
                        }
                    }
                }
                if (std.mem.find(u8, r.stdout, " passed,") == null) {
                    _ = phung.fetchAdd(1, .monotonic);
                    const tail_from = if (r.stderr.len > 400) r.stderr.len - 400 else 0;
                    std.debug.print("[census-nosummary] <- {s}\n{s}\n", .{ queue[i][queue[i].len - 1], r.stderr[tail_from..] });
                }
            }
        }
    };
    var service: ?RunningService = if (cfg.service) |svc| try startService(a, io, &env, cfg, svc, slowdown) else null;
    defer if (service) |*rs| rs.stop(io);

    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const []const []const u8, jobs.items), &env, &next, &total_passed, &total_failed, &hung, cfg.timeout_ms * slowdown,
        }));
    }
    for (threads.items) |t| t.join();

    const passed = total_passed.load(.monotonic);
    const failed = total_failed.load(.monotonic);
    if (service) |rs| {
        if (failed != 0 or passed < cfg.baseline) std.debug.print("{s}_commontest: the service's log ({s}) ends:\n{s}\n", .{
            cfg.name, rs.log_path, serviceLogTail(a, io, rs.log_path, 2000),
        });
    }
    std.debug.print(
        "{s}_commontest: {d} passed, {d} failed across {d} files, {d} did not complete (baseline {d})\n",
        .{ cfg.name, passed, failed, targets.items.len, hung.load(.monotonic), cfg.baseline },
    );
    try std.testing.expect(passed >= cfg.baseline);
    if (cfg.require_no_failures) try std.testing.expectEqual(@as(usize, 0), failed);
    if (cfg.max_failed) |cap| {
        if (failed > cap) {
            std.debug.print(
                "{s}_commontest: {d} failing cases exceeds the ceiling {d} — a floor-clearing run can still regress inside the red mass\n",
                .{ cfg.name, failed, cap },
            );
            return error.FailureCeilingExceeded;
        }
    }
    if (cfg.max_incomplete) |cap| {
        const inc = hung.load(.monotonic);
        if (inc > cap) {
            std.debug.print(
                "{s}_commontest: {d} cases did not complete, ceiling {d}\n",
                .{ cfg.name, inc, cap },
            );
            return error.IncompleteCeilingExceeded;
        }
    }
}

test "top-level declarations provide for other files in the same package" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const base =
        \\package kotlinx.coroutines.flow
        \\
        \\abstract class FlatMapBaseTest : TestBase() {
        \\    abstract fun <T> Flow<T>.flatMap(m: (T) -> Flow<T>): Flow<T>
        \\}
        \\
        \\inline fun<T: Flow<Int>> CoroutineScope.helper(flow: T) {}
        \\
    ;
    const sub =
        \\package kotlinx.coroutines.flow
        \\
        \\class FlattenConcatTest : FlatMapBaseTest() {
        \\    private class Box(val i: Int)
        \\    fun t() { helper(flowOf(1)) }
        \\}
        \\
    ;
    const other =
        \\package kotlinx.coroutines.channels
        \\
        \\class FlatMapBaseTest
        \\
    ;

    const s_base = try scanDecls(aa, base);
    const s_sub = try scanDecls(aa, sub);
    const s_other = try scanDecls(aa, other);

    try std.testing.expectEqualStrings("kotlinx.coroutines.flow", s_base.package);
    try std.testing.expectEqual(@as(usize, 2), s_base.declares.len);
    try std.testing.expectEqualStrings("FlatMapBaseTest", s_base.declares[0]);
    try std.testing.expectEqualStrings("helper", s_base.declares[1]);
    try std.testing.expectEqual(@as(usize, 1), s_sub.declares.len);
    try std.testing.expectEqualStrings("FlattenConcatTest", s_sub.declares[0]);

    const scans = [_]DeclScan{ s_base, s_sub, s_other };
    var owner: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (scans, 0..) |s, i| {
        for (s.declares) |d| {
            const key = try std.fmt.allocPrint(aa, "{s}\x00{s}", .{ s.package, d });
            const gop = try owner.getOrPut(aa, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(aa, i);
        }
    }

    const need = try providerClosure(aa, &scans, &owner, 1);
    try std.testing.expectEqual(@as(usize, 1), need.len);
    try std.testing.expectEqual(@as(usize, 0), need[0]);
    try std.testing.expectEqual(@as(usize, 0), (try providerClosure(aa, &scans, &owner, 2)).len);

    const importer =
        \\package kotlinx.coroutines.flow
        \\
        \\import kotlinx.coroutines.channels.*
        \\
        \\class Uses {
        \\    fun t() { helper(flowOf(1)) }
        \\}
        \\
    ;
    const provider =
        \\package kotlinx.coroutines.channels
        \\
        \\inline fun<T> CoroutineScope.helper(flow: T) {}
        \\
    ;
    const s_imp = try scanDecls(aa, importer);
    const s_prov = try scanDecls(aa, provider);
    const scans2 = [_]DeclScan{ s_imp, s_prov };
    var owner2: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (scans2, 0..) |sc, i| {
        for (sc.declares) |d| {
            const key = try std.fmt.allocPrint(aa, "{s}\x00{s}", .{ sc.package, d });
            const gop = try owner2.getOrPut(aa, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(aa, i);
        }
    }
    const imported = try providerClosure(aa, &scans2, &owner2, 0);
    try std.testing.expectEqual(@as(usize, 1), imported.len);
    try std.testing.expectEqual(@as(usize, 1), imported[0]);
}
