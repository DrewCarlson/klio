//! Shared driver for library `commonTest` suites: discover a library's own
//! upstream common test tree, build and install its pack (plus deps), and run
//! every `@Test`-bearing file through a child `klio test` against the pack.
//!
//! A file without `@Test` is a shared fixture, compiled into every test file's
//! module; `extra_support` files (klio-authored platform actuals) are added the
//! same way. Pass counting is per-`PASSED`-line so a file killed mid-run still
//! contributes the cases it printed before the kill. The suite ratchets on the
//! total pass count; raise the baseline as fixes land, never lower it.
//! `max_failed`/`max_incomplete` bound the other direction — a floor alone
//! cannot see a regression inside the red mass.

const std = @import("std");
const runtime = @import("runtime");

pub const Pack = struct { dir: []const u8, artifact: []const u8 };

pub const Config = struct {
    /// Short label for log lines (e.g. "atomicfu").
    name: []const u8,
    /// One or more common test directories to discover recursively.
    test_roots: []const []const u8,
    /// Per-suite scratch HOME the child packs install into.
    scratch_home: []const u8,
    /// Packs to build+install, in dependency order (deps before dependents).
    packs: []const Pack,
    /// Minimum total passing cases. A ratchet floor; raise as fixes land.
    baseline: usize,
    /// klio-authored actual/fixture files added to every test file's module.
    extra_support: []const []const u8 = &.{},
    /// Per-file child timeout.
    timeout_ms: i64 = 60_000,
    /// Once a suite reaches full coverage, set true to also fail on any
    /// non-passing case (a hard 100% gate on top of the ratchet).
    require_no_failures: bool = false,
    /// Ceiling on failing cases. A pass-count floor alone cannot see a
    /// regression INSIDE the red mass — a suite can trade a fixed test for
    /// a broken one, or grow new failures, and still clear its floor. Seed
    /// from the measured solo census and lower it as fixes land, never
    /// raise it. Null leaves the suite floor-only (state why).
    max_failed: ?usize = null,
    /// Compile the WHOLE test source set into every child and run only the
    /// target file's `@Test` methods (`--only-file`). Upstream commonTest is
    /// one compilation unit, so a helper declared top-level in one
    /// `@Test`-bearing file is visible from another (`checkComponents` in
    /// kotlinx-datetime's LocalDateTimeTest.kt, used by InstantTest.kt); the
    /// default one-target-per-child model cannot see it. Costs compile time
    /// per child, so it is opted into per suite.
    whole_source_set: bool = false,
    /// Ceiling on cases that never reported (timeout / crash). These are
    /// invisible to both the floor and `max_failed`, so they get their own
    /// bound: a suite whose children start hanging is regressing even when
    /// the surviving cases still pass.
    max_incomplete: ?usize = null,
};

fn klioBin(env: *const std.process.Environ.Map) []const u8 {
    return env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
}

fn envWithHome(allocator: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(allocator, &map);
    try map.put("HOME", home);
    return map;
}

fn workerCount() usize {
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

fn installPacks(allocator: std.mem.Allocator, env: *std.process.Environ.Map, cfg: Config) !void {
    for (cfg.packs) |p| {
        const b = try runKlio(allocator, env, &.{ klioBin(env), "pack", "build", p.dir }, 120_000);
        if (b.term != .exited or b.term.exited != 0) {
            std.debug.print("{s}_commontest: pack build {s} failed:\n{s}\n", .{ cfg.name, p.dir, b.stderr });
            return error.PackBuildFailed;
        }
        const i = try runKlio(allocator, env, &.{ klioBin(env), "pack", "install", p.artifact }, 120_000);
        if (i.term != .exited or i.term.exited != 0) {
            std.debug.print("{s}_commontest: pack install {s} failed:\n{s}\n", .{ cfg.name, p.artifact, i.stderr });
            return error.PackInstallFailed;
        }
    }
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
    return std.mem.indexOf(u8, bytes, "@Test") != null;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// What one test source contributes to, and needs from, its compilation unit:
/// the package it declares, the names it declares at TOP level (column zero,
/// so a nested or member declaration never provides for another file), and
/// every identifier it mentions.
const DeclScan = struct {
    package: []const u8,
    /// Every package whose top-level declarations this file resolves an
    /// unqualified name against: its own, plus each import's package.
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
/// Skips a `fun`'s type parameters and extension receiver so
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
    // Walk the receiver/name path to the identifier the call site uses.
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
            // A declaration at column zero: skip its modifiers, then read
            // the bound name.
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
                // `import a.b.*` scopes package `a.b`; `import a.b.Name`
                // scopes `a.b` too — the leaf is the declaration.
                if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
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

/// Test files that `target` must be compiled with because it names something
/// they declare at top level in its own package, transitively. Upstream
/// commonTest is one compilation unit, so a `@Test`-bearing file may extend a
/// base class or call a helper declared in ANOTHER `@Test`-bearing file
/// (`FlattenConcatTest : FlatMapBaseTest()`); compiled alone it resolves the
/// name against whatever else matches and loses the inherited cases outright.
fn providerClosure(
    a: std.mem.Allocator,
    scans: []const DeclScan,
    owner: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)),
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

/// Count per-test `PASSED` lines (`<Class>.<method> PASSED`). Robust to a file
/// killed mid-run: passes printed before the kill still count.
fn passedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " PASSED")) n += 1;
    }
    return n;
}

/// Sum the `N failed` counts from every `M tests, ... N failed, ...` summary
/// line the run printed.
fn failedCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const marker = " failed,";
        const idx = std.mem.indexOf(u8, line, marker) orelse continue;
        var start = idx;
        while (start > 0 and line[start - 1] >= '0' and line[start - 1] <= '9') start -= 1;
        n += std.fmt.parseInt(usize, line[start..idx], 10) catch 0;
    }
    return n;
}

var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Run one library's commonTest suite and assert the pass-count ratchet.
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

    std.Io.Dir.cwd().createDirPath(io, cfg.scratch_home) catch {};
    var env = try envWithHome(a, cfg.scratch_home);
    try installPacks(a, &env, cfg);

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
    var owner: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
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
    for (targets.items, 0..) |target, ti| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, klioBin(&env));
        try argv.append(a, "test");
        if (cfg.whole_source_set) {
            try argv.append(a, "--only-file");
            try argv.append(a, target);
            try argv.appendSlice(a, support.items);
            try argv.appendSlice(a, targets.items);
        } else {
            const bases = try providerClosure(a, scans.items, &owner, ti);
            if (bases.len != 0) {
                // The provider files carry their own cases; `--only-file`
                // keeps them compiled but unrun so each case counts once.
                try argv.append(a, "--only-file");
                try argv.append(a, target);
            }
            try argv.appendSlice(a, support.items);
            for (bases) |bi| try argv.append(a, targets.items[bi]);
            try argv.append(a, target);
        }
        try jobs.append(a, try argv.toOwnedSlice(a));
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
                const r = runKlio(arena.allocator(), penv, queue[i], timeout_ms) catch {
                    _ = phung.fetchAdd(1, .monotonic);
                    continue;
                };
                // Latency census: per-child wall, argv size, and pass count —
                // the budget table's raw rows (KLIO_CENSUS_TIMES=1).
                if (std.c.getenv("KLIO_CENSUS_TIMES") != null) {
                    std.debug.print("[census-time] {d}ms files={d} passed={d} target={s}\n", .{
                        (runtime.clockMonotonicNanos() -% ct_t0) / std.time.ns_per_ms,
                        queue[i].len - 2,
                        passedLineCount(r.stdout),
                        queue[i][queue[i].len - 1],
                    });
                }
                _ = ppassed.fetchAdd(passedLineCount(r.stdout), .monotonic);
                const nf = failedCount(r.stdout);
                _ = pfailed.fetchAdd(nf, .monotonic);
                // Census diagnosis: name every failing case (and its file) so
                // a red census is actionable without a by-hand re-run.
                if (nf != 0 and std.c.getenv("KLIO_CENSUS_NAMES") != null) {
                    var itn = std.mem.splitScalar(u8, r.stdout, '\n');
                    while (itn.next()) |line| {
                        if (std.mem.endsWith(u8, line, " FAILED")) {
                            std.debug.print("[census-fail] {s} <- {s}\n", .{ line, queue[i][queue[i].len - 1] });
                        }
                    }
                }
                if (std.mem.indexOf(u8, r.stdout, " passed,") == null) _ = phung.fetchAdd(1, .monotonic);
            }
        }
    };
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const []const []const u8, jobs.items), &env, &next, &total_passed, &total_failed, &hung, cfg.timeout_ms,
        }));
    }
    for (threads.items) |t| t.join();

    const passed = total_passed.load(.monotonic);
    const failed = total_failed.load(.monotonic);
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
    // A `fun`'s type parameters and extension receiver are not its name.
    try std.testing.expectEqualStrings("helper", s_base.declares[1]);
    // An indented member declaration provides for nobody.
    try std.testing.expectEqual(@as(usize, 1), s_sub.declares.len);
    try std.testing.expectEqualStrings("FlattenConcatTest", s_sub.declares[0]);

    const scans = [_]DeclScan{ s_base, s_sub, s_other };
    var owner: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
    for (scans, 0..) |s, i| {
        for (s.declares) |d| {
            const key = try std.fmt.allocPrint(aa, "{s}\x00{s}", .{ s.package, d });
            const gop = try owner.getOrPut(aa, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(aa, i);
        }
    }

    // The subclass pulls in the file declaring its base and its helper; the
    // same-named class in another package is not a provider.
    const need = try providerClosure(aa, &scans, &owner, 1);
    try std.testing.expectEqual(@as(usize, 1), need.len);
    try std.testing.expectEqual(@as(usize, 0), need[0]);
    // A file that needs nothing pulls in nothing.
    try std.testing.expectEqual(@as(usize, 0), (try providerClosure(aa, &scans, &owner, 2)).len);

    // An IMPORTED package is a provider scope too: a helper declared in
    // `kotlinx.coroutines.channels` reaches a file that wildcard-imports it.
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
    var owner2: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
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
