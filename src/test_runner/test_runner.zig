//! Discovers and runs `kotlin.test` `@Test` functions through the real
//! interpreter pipeline. Discovery reads the user's parsed sources, so it
//! resolves annotations through each file's imports; execution drives the built
//! module through the public `Vm` embedder entry points only.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const interp_ir = @import("interp_ir");

const Allocator = std.mem.Allocator;
const Vm = interp_ir.Vm;
const Output = runtime.Output;
const Value = runtime.Value;

pub const Outcome = enum { passed, failed, skipped };

/// How per-test progress is reported as the run proceeds. `plain` is the
/// `[test] name TAG 12ms` line; `teamcity` is the service-message protocol an
/// IDE test tree consumes, so results appear as they finish rather than in one
/// block at the end.
pub const Reporter = enum { plain, teamcity };

var reporter: Reporter = .plain;

pub fn setReporter(mode: Reporter) void {
    reporter = mode;
}

pub const TestResult = struct {
    /// `MathTest.addition` or `topLevelTest`.
    display: []const u8,
    outcome: Outcome,
    /// Exception type and message, or an interpreter error.
    detail: ?[]const u8 = null,
};

pub const Report = struct {
    results: []TestResult,
    passed: usize,
    failed: usize,
    skipped: usize,

    pub fn deinit(self: *Report, gpa: Allocator) void {
        for (self.results) |r| {
            gpa.free(r.display);
            if (r.detail) |d| gpa.free(d);
        }
        gpa.free(self.results);
    }
};

/// The tests of a module lowered from sema, found by sema and named by id: a top-level `@Test` function, and per
/// test class its no-argument constructor and each `@Test`,
/// `@BeforeTest` and `@AfterTest` method's implementation for that class.
pub const ResolvedPlan = struct {
    top: []const ResolvedTop,
    classes: []const ResolvedClass,
};

pub const ResolvedTop = struct { display: []const u8, fid: ir.FuncId, ignored: bool };

pub const ResolvedClass = struct {
    cid: ir.ClassId,
    /// Null when the class has no constructor taking no arguments.
    ctor: ?ir.FuncId,
    methods: []const ResolvedMethod,
    befores: []const ir.FuncId,
    afters: []const ir.FuncId,
    class_ignored: bool,
};

pub const ResolvedMethod = struct { display: []const u8, fid: ir.FuncId, ignored: bool };

pub fn filterMatches(filter: ?[]const u8, name: []const u8) bool {
    const pat = filter orelse return true;
    var any_pos = false;
    var any_neg = false;
    var pos_hit = false;
    var it = std.mem.splitScalar(u8, pat, ',');
    while (it.next()) |p| {
        if (p.len == 0) continue;
        if (p[0] == '!') {
            any_neg = true;
            if (p.len > 1 and std.mem.find(u8, name, p[1..]) != null) return false;
            continue;
        }
        any_pos = true;
        if (p[0] == '=') {
            if (std.mem.eql(u8, name, p[1..])) pos_hit = true;
        } else if (std.mem.find(u8, name, p) != null) {
            pos_hit = true;
        }
    }
    // A purely negative pattern admits all it does not exclude; no tokens admits none.
    return pos_hit or (!any_pos and any_neg);
}

pub fn filterHasNegation(filter: ?[]const u8) bool {
    const pat = filter orelse return false;
    var it = std.mem.splitScalar(u8, pat, ',');
    while (it.next()) |p| {
        if (p.len > 1 and p[0] == '!') return true;
    }
    return false;
}

test "filterMatches negation carves one test out of a class" {
    try std.testing.expect(filterMatches("Recomposer,!validatePotentialDeadlock", "RecomposerTests"));
    try std.testing.expect(!filterMatches(
        "Recomposer,!validatePotentialDeadlock",
        "RecomposerTests.validatePotentialDeadlock",
    ));
    try std.testing.expect(filterMatches(
        "Recomposer,!validatePotentialDeadlock",
        "RecomposerTests.recomposesWhenStateChanges",
    ));
    try std.testing.expect(!filterMatches("!Snapshot", "SnapshotStateMapTests"));
    try std.testing.expect(filterMatches("!Snapshot", "RecomposerTests"));
}

const RunState = struct {
    gpa: Allocator,
    plan: *const ResolvedPlan,
    results: std.ArrayList(TestResult),
    /// Stamped when a test starts running; the delta at `record` is its own time,
    /// not the gap since the previous result.
    test_started_ns: i128 = 0,
    /// The test whose `testStarted` has been emitted and not yet finished.
    open_test: ?[]const u8 = null,
    /// The suite the service-message reporter has open, so it closes exactly one.
    current_suite: ?[]const u8 = null,
    /// Where service messages go. The program's own stdout, which is the stream
    /// an IDE parses them from, and which keeps a test's `println` in order with
    /// the events around it.
    out: ?Output = null,
};

fn describeThrow(gpa: Allocator, v: Value) []const u8 {
    // KLIO_ERR_TRACE renders the full throwable; type and message can mask one.
    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        if (ir.eval.formatThrowable(gpa, &v, &buf, false, 0)) {
            if (gpa.dupe(u8, buf.items)) |owned| return owned else |_| {}
        } else |_| {}
    }
    const ty: []const u8 = v.exceptionFqn() orelse "exception";
    const msg: ?[]const u8 = switch (v) {
        .Exception => |e| if (e.message.get()) |m| blk: {
            const g = m.borrow();
            defer g.deinit();
            break :blk g.get().bytes;
        } else null,
        else => null,
    };
    if (msg) |m| return std.fmt.allocPrint(gpa, "{s}: {s}", .{ ty, m }) catch gpa.dupe(u8, ty) catch "";
    return gpa.dupe(u8, ty) catch "";
}

/// TeamCity service-message escaping: the six characters the protocol reserves.
fn emitEscaped(out: Output, text: []const u8) void {
    for (text) |c| switch (c) {
        '\'' => out.write("|'"),
        '\n' => out.write("|n"),
        '\r' => out.write("|r"),
        '|' => out.write("||"),
        '[' => out.write("|["),
        ']' => out.write("|]"),
        else => out.write(&[_]u8{c}),
    };
}

/// `Class.method` splits into a suite and a test; a top-level test has no suite.
fn suiteOf(display: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, display, '.') orelse return null;
    if (dot == 0) return null;
    return display[0..dot];
}

fn testNameOf(display: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, display, '.') orelse return display;
    return display[dot + 1 ..];
}

/// A comparison failure carries both values, which an IDE turns into a
/// side-by-side diff when they travel as separate attributes. kotlin.test
/// renders `Expected <a>, actual <b>.`; the JUnit spelling turns up in ported
/// assertions.
const Comparison = struct { expected: []const u8, actual: []const u8 };

fn parseComparison(detail: []const u8) ?Comparison {
    if (parseBracketed(detail, "Expected <", ">, actual <")) |c| return c;
    if (parseBracketed(detail, "expected:<", "> but was:<")) |c| return c;
    return null;
}

fn parseBracketed(detail: []const u8, open: []const u8, mid: []const u8) ?Comparison {
    const start = std.mem.indexOf(u8, detail, open) orelse return null;
    const expected_start = start + open.len;
    const mid_at = std.mem.indexOfPos(u8, detail, expected_start, mid) orelse return null;
    const actual_start = mid_at + mid.len;
    if (actual_start >= detail.len) return null;
    const close = std.mem.lastIndexOfScalar(u8, detail, '>') orelse return null;
    if (close < actual_start) return null;
    return .{
        .expected = detail[expected_start..mid_at],
        .actual = detail[actual_start..close],
    };
}

test "a comparison failure splits into its two values" {
    const jetbrains = parseComparison("kotlin.AssertionError: Expected <4>, actual <5>.").?;
    try std.testing.expectEqualStrings("4", jetbrains.expected);
    try std.testing.expectEqualStrings("5", jetbrains.actual);
    const junit = parseComparison("expected:<a> but was:<b>").?;
    try std.testing.expectEqualStrings("a", junit.expected);
    try std.testing.expectEqualStrings("b", junit.actual);
    try std.testing.expect(parseComparison("plain failure") == null);
}

fn emitServiceMessages(
    st: *RunState,
    display: []const u8,
    outcome: Outcome,
    detail: ?[]const u8,
    dur_ms: i128,
) void {
    const out = st.out orelse return;
    const name = testNameOf(display);

    switch (outcome) {
        .passed => {},
        .skipped => {
            out.write("##teamcity[testIgnored name='");
            emitEscaped(out, name);
            out.write("']\n");
        },
        .failed => {
            const text = detail orelse "test failed";
            out.write("##teamcity[testFailed name='");
            emitEscaped(out, name);
            out.write("' message='");
            emitEscaped(out, text);
            if (parseComparison(text)) |cmp| {
                out.write("' type='comparisonFailure' expected='");
                emitEscaped(out, cmp.expected);
                out.write("' actual='");
                emitEscaped(out, cmp.actual);
            }
            out.write("' details='']\n");
        },
    }

    var buf: [64]u8 = undefined;
    const dur = std.fmt.bufPrint(&buf, "{d}", .{dur_ms}) catch "0";
    out.write("##teamcity[testFinished name='");
    emitEscaped(out, name);
    out.write("' duration='");
    out.write(dur);
    out.write("']\n");
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Closes the suite the last test opened, so the tree never ends mid-branch.
fn finishReporting(st: *const RunState) void {
    if (reporter != .teamcity) return;
    const out = st.out orelse return;
    if (st.current_suite) |open| {
        out.write("##teamcity[testSuiteFinished name='");
        emitEscaped(out, open);
        out.write("']\n");
    }
}

/// Opens a test: its duration counts from here, and anything it prints from here
/// until its result belongs to it rather than to the suite around it.
fn beginTest(st: *RunState, display: []const u8) void {
    if (st.open_test != null) return;
    st.test_started_ns = runtime.clockMonotonicNanos();
    st.open_test = display;
    if (reporter != .teamcity) return;
    const out = st.out orelse return;

    const suite = suiteOf(display);
    if (!eqlOpt(st.current_suite, suite)) {
        if (st.current_suite) |open| {
            out.write("##teamcity[testSuiteFinished name='");
            emitEscaped(out, open);
            out.write("']\n");
        }
        if (suite) |next| {
            out.write("##teamcity[testSuiteStarted name='");
            emitEscaped(out, next);
            out.write("' locationHint='klio://");
            emitEscaped(out, next);
            out.write("']\n");
        }
        st.current_suite = suite;
    }

    out.write("##teamcity[testStarted name='");
    emitEscaped(out, testNameOf(display));
    out.write("' locationHint='klio://");
    emitEscaped(out, display);
    out.write("' captureStandardOutput='true']\n");
}

fn record(st: *RunState, display: []const u8, outcome: Outcome, detail: ?[]const u8) Allocator.Error!void {
    // A result without a start is a test that never ran: open it now so every
    // outcome is reported inside its own start/finish pair.
    beginTest(st, display);
    const tag = switch (outcome) {
        .passed => "PASSED",
        .failed => "FAILED",
        .skipped => "SKIPPED",
    };
    const dur_ms: i128 = @divTrunc(runtime.clockMonotonicNanos() - st.test_started_ns, std.time.ns_per_ms);
    st.open_test = null;
    switch (reporter) {
        .plain => std.debug.print("[test] {s} {s} {d}ms\n", .{ display, tag, dur_ms }),
        .teamcity => emitServiceMessages(st, display, outcome, detail, dur_ms),
    }
    const owned_display = st.gpa.dupe(u8, display) catch |err| {
        std.debug.print("[test-runner] display allocation failed len={d}\n", .{display.len});
        return err;
    };
    errdefer st.gpa.free(owned_display);
    st.results.append(st.gpa, .{
        .display = owned_display,
        .outcome = outcome,
        .detail = detail,
    }) catch |err| {
        std.debug.print("[test-runner] result growth failed len={d} cap={d}\n", .{ st.results.items.len, st.results.capacity });
        return err;
    };
}

/// Per-test wall cap in seconds, 300 when `KLIO_TEST_WALL_CAP` is unset, so a
/// wedged test fails instead of hanging the run. `0` disables the cap.
fn wallCapSeconds() i64 {
    const S = struct {
        var cached: ?i64 = null;
    };
    if (S.cached) |v| return v;
    const v: i64 = blk: {
        const s = runtime.envOnce("KLIO_TEST_WALL_CAP") orelse break :blk 300;
        break :blk std.fmt.parseInt(i64, s, 10) catch 300;
    };
    S.cached = v;
    return v;
}

/// Per-test overrides: `KLIO_TEST_WALL_CAP_FOR=name=secs,...`. A declared
/// budget is an upper bound that must only shrink; exceeding it still fails.
fn wallCapForTest(name: []const u8) i64 {
    const spec = runtime.envOnce("KLIO_TEST_WALL_CAP_FOR") orelse return wallCapSeconds();
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |entry| {
        const eq = std.mem.findScalar(u8, entry, '=') orelse continue;
        const key = std.mem.trim(u8, entry[0..eq], " ");
        if (key.len == 0) continue;
        if (std.mem.find(u8, name, key) == null) continue;
        return std.fmt.parseInt(i64, std.mem.trim(u8, entry[eq + 1 ..], " "), 10) catch continue;
    }
    return wallCapSeconds();
}

fn armWallDeadlineFor(name: []const u8) void {
    const cap = wallCapForTest(name);
    if (cap <= 0) return;
    ir.eval.wall_cap_fires.store(0, .monotonic);
    ir.eval.test_wall_deadline_ms.store(ir.eval.nowMonotonicMs() + cap * 1000, .monotonic);
}

fn armWallDeadline() void {
    const cap = wallCapSeconds();
    if (cap <= 0) return;
    ir.eval.wall_cap_fires.store(0, .monotonic);
    ir.eval.test_wall_deadline_ms.store(ir.eval.nowMonotonicMs() + cap * 1000, .monotonic);
}

fn clearWallDeadline() void {
    ir.eval.test_wall_deadline_ms.store(0, .monotonic);
}

/// Clear a wall-capped test's drain-everything abandonment, cooperatively.
fn drainWallCapAbandon() void {
    if (!runtime.runBoundaryAbandonActive()) return;
    // Wait for quiescence, not a fixed window: a worker parked in a bounded
    // native wait outlives one, and clearing the flags strands it mid-task.
    // Poll the in-eval census until only this thread remains, bounded at 10 s.
    runtime.gc.enterBlockingSafe();
    var waited_ms: u64 = 0;
    while (ir.eval.threads_in_eval.load(.monotonic) != 0 and waited_ms < 10_000) {
        const ts = std.c.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
        waited_ms += 10;
    }
    runtime.gc.exitBlockingSafe();
    if (ir.eval.threads_in_eval.load(.monotonic) != 0) {
        std.debug.print(
            "[wall-cap] {d} abandoned worker(s) still executing after 10s drain; later tests may be contaminated\n",
            .{ir.eval.threads_in_eval.load(.monotonic)},
        );
    }
    runtime.setRunBoundaryAbandon(false);
    runtime.clearAbandon();
}

/// A throwable of a module lowered from sema, rendered by its `toString`.
fn resolvedFailure(st: *RunState, vm: *Vm, oc: interp_ir.CallOutcome) ?[]const u8 {
    return switch (oc) {
        .ok => null,
        .threw => |v| blk: {
            if (v == .Instance) {
                const text = vm.throwableText(st.gpa, &v) catch break :blk describeThrow(st.gpa, v);
                if (text) |t| break :blk t;
            }
            break :blk describeThrow(st.gpa, v);
        },
        .failed => |m| st.gpa.dupe(u8, m) catch "interpreter error",
    };
}

fn runResolvedBody(st: *RunState, vm: *Vm) Allocator.Error!void {
    defer clearWallDeadline();
    // The program starts before any test runs: its eager properties are
    // initialized, and one that throws fails the start instead.
    if (try vm.startProgram()) |oc| {
        if (resolvedFailure(st, vm, oc)) |d| try record(st, "<startup>", .failed, d);
        return;
    }
    const plan = st.plan;
    for (plan.top) |t| {
        if (t.ignored) {
            try record(st, t.display, .skipped, null);
            continue;
        }
        beginTest(st, t.display);
        armWallDeadlineFor(t.display);
        const oc = try vm.callArgs(t.fid, &.{});
        clearWallDeadline();
        drainWallCapAbandon();
        if (resolvedFailure(st, vm, oc)) |d| try record(st, t.display, .failed, d) else try record(st, t.display, .passed, null);
    }
    for (plan.classes) |ct| {
        for (ct.methods) |m| {
            if (ct.class_ignored or m.ignored) {
                try record(st, m.display, .skipped, null);
                continue;
            }
            const ctor = ct.ctor orelse {
                try record(st, m.display, .failed, try st.gpa.dupe(u8, "test class has no constructor without arguments"));
                continue;
            };
            // A fresh instance per test, as JUnit makes one.
            beginTest(st, m.display);
            armWallDeadlineFor(m.display);
            const made = try vm.newResolved(ct.cid, ctor);
            drainWallCapAbandon();
            const receiver = switch (made) {
                .ok => |v| v,
                else => {
                    clearWallDeadline();
                    try record(st, m.display, .failed, resolvedFailure(st, vm, made));
                    continue;
                },
            };
            var detail: ?[]const u8 = null;
            // @BeforeTest, then @Test, stopping at the first failure.
            for (ct.befores) |b| {
                if (resolvedFailure(st, vm, try vm.callArgs(b, &.{receiver}))) |d| {
                    detail = d;
                    break;
                }
            }
            if (detail == null) detail = resolvedFailure(st, vm, try vm.callArgs(m.fid, &.{receiver}));
            // @AfterTest always runs, on a fresh budget.
            drainWallCapAbandon();
            armWallDeadline();
            for (ct.afters) |a| {
                if (resolvedFailure(st, vm, try vm.callArgs(a, &.{receiver}))) |d| {
                    if (detail == null) detail = d else st.gpa.free(d);
                }
            }
            clearWallDeadline();
            drainWallCapAbandon();
            if (detail) |d| try record(st, m.display, .failed, d) else try record(st, m.display, .passed, null);
        }
    }
}

/// Runs the tests of `plan` against `vm`, a module lowered from sema.
/// Caller owns the `Report`.
pub fn runResolvedTests(gpa: Allocator, vm: *Vm, plan: *const ResolvedPlan, out: Output) Allocator.Error!Report {
    var st = RunState{
        .gpa = gpa,
        .plan = plan,
        .results = .empty,
        .test_started_ns = runtime.clockMonotonicNanos(),
        .out = out,
    };
    const prep = try vm.runCalls(out, *RunState, &st, runResolvedBody);
    finishReporting(&st);
    if (prep) |_| try record(&st, "<startup>", .failed, try gpa.dupe(u8, "module initialization failed"));
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    for (st.results.items) |r| switch (r.outcome) {
        .passed => passed += 1,
        .failed => failed += 1,
        .skipped => skipped += 1,
    };
    return .{ .results = try st.results.toOwnedSlice(gpa), .passed = passed, .failed = failed, .skipped = skipped };
}

test {
    std.testing.refAllDecls(@This());
}

test "filter matches any comma-separated substring" {
    try std.testing.expect(filterMatches(null, "Anything"));
    try std.testing.expect(filterMatches("Foo", "FooTests.bar"));
    try std.testing.expect(filterMatches("Foo,Baz", "BazTests.qux"));
    try std.testing.expect(!filterMatches("Foo,Baz", "QuuxTests.qux"));
    try std.testing.expect(!filterMatches(",", "QuuxTests.qux"));
    try std.testing.expect(filterMatches("=FooTests.bar", "FooTests.bar"));
    try std.testing.expect(!filterMatches("=FooTests.bar", "FooTests.barExtended"));
    try std.testing.expect(filterMatches("Foo,=BazTests.qux", "BazTests.qux"));
}
