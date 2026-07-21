//! Discovers and runs `kotlin.test` `@Test` functions through the real
//! interpreter pipeline. Discovery is driven from the user's parsed sources
//! (so it is naturally scoped to the program under test and resolves the
//! `kotlin.test` annotations through each file's imports); execution drives
//! the already-built module through the embedder entry points on `Vm`
//! (`prepare` / `callNoArg` / `construct` / `callMethod`).
//!
//! This module lives outside the core interpreter: it consumes the public
//! `interp_ir` Vm API and adds no test-specific machinery to the evaluator.

const std = @import("std");
const ast = @import("ast");
const ir = @import("ir");
const runtime = @import("runtime");
const interp_ir = @import("interp_ir");

const Allocator = std.mem.Allocator;
const Vm = interp_ir.Vm;
const Output = runtime.Output;
const Value = runtime.Value;

pub const Outcome = enum { passed, failed, skipped };

pub const TestResult = struct {
    /// Human-facing identity, e.g. `MathTest.addition` or `topLevelTest`.
    display: []const u8,
    outcome: Outcome,
    /// Failure detail (exception type + message, or an interpreter error).
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

// ---- discovered test plan ------------------------------------------------

const TopTest = struct { display: []const u8, fid: ?ir.FuncId, ignored: bool };
const Method = struct { display: []const u8, name: []const u8, ignored: bool };
const ClassTests = struct {
    cid: ?ir.ClassId,
    class_name: []const u8,
    methods: []Method,
    befores: [][]const u8,
    afters: [][]const u8,
    class_ignored: bool,
};

const Plan = struct {
    top: []TopTest,
    classes: []ClassTests,
};

// ---- annotation resolution (import-aware) --------------------------------

fn joinPath(gpa: Allocator, path: []const ast.Ident) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (path, 0..) |id, i| {
        if (i != 0) buf.append(gpa, '.') catch return "";
        buf.appendSlice(gpa, id.name) catch return "";
    }
    return buf.toOwnedSlice(gpa) catch "";
}

/// True if `imports` brings `kotlin.test.<simple>` into scope under its bare
/// name — an explicit `import kotlin.test.<simple>` or `import kotlin.test.*`.
fn importsKotlinTest(imports: []const ast.ImportDecl, simple: []const u8) bool {
    for (imports) |imp| {
        if (imp.path.len == 0) continue;
        if (imp.wildcard) {
            if (pathEquals(imp.path, &.{ "kotlin", "test" })) return true;
            continue;
        }
        // `import kotlin.test.<simple>` (no alias rename of the leaf).
        if (imp.alias != null) continue;
        if (imp.path.len == 3 and
            std.mem.eql(u8, imp.path[0].name, "kotlin") and
            std.mem.eql(u8, imp.path[1].name, "test") and
            std.mem.eql(u8, imp.path[2].name, simple)) return true;
    }
    return false;
}

fn pathEquals(path: []const ast.Ident, segs: []const []const u8) bool {
    if (path.len != segs.len) return false;
    for (path, segs) |id, s| {
        if (!std.mem.eql(u8, id.name, s)) return false;
    }
    return true;
}

/// True if any annotation in `annos` resolves to `kotlin.test.<simple>` given
/// the declaring file's `imports`.
fn hasKotlinTestAnno(
    annos: []const ast.Annotation,
    imports: []const ast.ImportDecl,
    simple: []const u8,
) bool {
    for (annos) |an| {
        if (an.path.len == 0) continue;
        const leaf = an.path[an.path.len - 1].name;
        if (!std.mem.eql(u8, leaf, simple)) continue;
        if (an.path.len > 1) {
            // Fully or partially qualified use site: accept `kotlin.test.X`.
            if (an.path.len == 3 and
                std.mem.eql(u8, an.path[0].name, "kotlin") and
                std.mem.eql(u8, an.path[1].name, "test")) return true;
            continue;
        }
        if (importsKotlinTest(imports, simple)) return true;
    }
    return false;
}

// ---- discovery -----------------------------------------------------------

fn filePackage(gpa: Allocator, file: *const ast.KotlinFile) []const u8 {
    const pkg = file.package orelse return "";
    return joinPath(gpa, pkg.path);
}

fn qualify(gpa: Allocator, pkg: []const u8, name: []const u8) []const u8 {
    if (pkg.len == 0) return gpa.dupe(u8, name) catch "";
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ pkg, name }) catch "";
}

/// One class declaration plus the imports of its declaring file (needed to
/// resolve `kotlin.test` annotations on its members).
const ClassEntry = struct { cls: *const ast.Class, imports: []const ast.ImportDecl };

/// True when `only_fids` is unrestricted (empty) or contains `fid`.
fn fileSelected(only_fids: []const u32, fid: u32) bool {
    if (only_fids.len == 0) return true;
    for (only_fids) |x| if (x == fid) return true;
    return false;
}

/// `filter == null` runs everything; otherwise a test runs when its display
/// name (a top-level `method`, or a class's `Class`) contains any of the
/// comma-separated substrings. A token beginning with `=` matches the entire
/// display name, which the isolated runner uses to avoid prefix collisions.
fn filterMatches(filter: ?[]const u8, name: []const u8) bool {
    const pat = filter orelse return true;
    var it = std.mem.splitScalar(u8, pat, ',');
    while (it.next()) |p| {
        if (p.len == 0) continue;
        if (p[0] == '=') {
            if (std.mem.eql(u8, name, p[1..])) return true;
        } else if (std.mem.indexOf(u8, name, p) != null) {
            return true;
        }
    }
    return false;
}

fn discover(gpa: Allocator, module: *const ir.Module, user_asts: []const ast.KotlinFile, only_fids: []const u32, filter: ?[]const u8) Allocator.Error!Plan {
    var top: std.ArrayList(TopTest) = .empty;
    var classes: std.ArrayList(ClassTests) = .empty;

    // Index every class by simple name so a concrete class can pull in the
    // `@Test` methods it inherits from abstract base classes (the stdlib tests
    // put the test bodies in abstract `…Tests` bases and run them through
    // concrete subclasses). The index spans every file so cross-file helper /
    // base classes resolve even when test discovery is narrowed to one file.
    var index = std.StringHashMap(ClassEntry).init(gpa);
    defer index.deinit();
    for (user_asts) |*file| {
        for (file.decls) |*d| {
            if (d.* == .Class) try index.put(d.Class.name.name, .{ .cls = &d.Class, .imports = file.imports });
        }
    }

    for (user_asts) |*file| {
        // `--only-file`: compile every file (above) but discover tests only in
        // the selected file(s), so a file's tests run with cross-file helpers
        // available yet are not double-counted across sibling files.
        if (!fileSelected(only_fids, file.span.file.int())) continue;
        const pkg = filePackage(gpa, file);
        defer gpa.free(pkg);
        for (file.decls) |*d| {
            switch (d.*) {
                .Function => |*f| {
                    if (!hasKotlinTestAnno(f.annotations, file.imports, "Test")) continue;
                    if (!filterMatches(filter, f.name.name)) continue;
                    const fqn = qualify(gpa, pkg, f.name.name);
                    defer gpa.free(fqn);
                    try top.append(gpa, .{
                        .display = try gpa.dupe(u8, f.name.name),
                        .fid = module.funcIdByFqn(fqn),
                        .ignored = hasKotlinTestAnno(f.annotations, file.imports, "Ignore"),
                    });
                },
                .Class => |*c| {
                    // An abstract class is never instantiated directly; its
                    // tests run through concrete subclasses (below).
                    if (c.is_abstract) continue;
                    const ct = try discoverClass(gpa, module, &index, file, c, pkg, filter);
                    if (ct) |found| try classes.append(gpa, found);
                },
                else => {},
            }
        }
    }
    return .{
        .top = try top.toOwnedSlice(gpa),
        .classes = try classes.toOwnedSlice(gpa),
    };
}

/// Collect `@Test`/`@BeforeTest`/`@AfterTest` methods of `class_name` and,
/// transitively, of its supertypes resolvable in `index`. Tests/befores/afters
/// are de-duplicated by name (a most-derived declaration wins), so an override
/// is not run twice. `display_class` is the concrete class the tests run under.
fn collectClassMethods(
    gpa: Allocator,
    index: *const std.StringHashMap(ClassEntry),
    cls: *const ast.Class,
    imports: anytype,
    display_class: []const u8,
    methods: *std.ArrayList(Method),
    befores: *std.ArrayList([]const u8),
    afters: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    visited: *std.StringHashMap(void),
) Allocator.Error!void {
    if (visited.contains(cls.name.name)) return;
    try visited.put(cls.name.name, {});
    // Collect from the concrete class decl itself — NOT an `index.get` by
    // simple name, which would resolve to a same-named class in a different
    // package and silently drop this one's tests. The index is only for
    // supertype recursion (Kotlin supertypes are referenced by simple name).
    for (cls.members) |*m| {
        if (m.* != .Function) continue;
        const f = &m.Function;
        if (hasKotlinTestAnno(f.annotations, imports, "BeforeTest") and !seen.contains(f.name.name)) {
            try befores.append(gpa, try gpa.dupe(u8, f.name.name));
        }
        if (hasKotlinTestAnno(f.annotations, imports, "AfterTest") and !seen.contains(f.name.name)) {
            try afters.append(gpa, try gpa.dupe(u8, f.name.name));
        }
        if (hasKotlinTestAnno(f.annotations, imports, "Test") and !seen.contains(f.name.name)) {
            try methods.append(gpa, .{
                .display = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ display_class, f.name.name }),
                .name = try gpa.dupe(u8, f.name.name),
                .ignored = hasKotlinTestAnno(f.annotations, imports, "Ignore"),
            });
        }
        if (hasKotlinTestAnno(f.annotations, imports, "Test") or
            hasKotlinTestAnno(f.annotations, imports, "BeforeTest") or
            hasKotlinTestAnno(f.annotations, imports, "AfterTest"))
        {
            try seen.put(f.name.name, {});
        }
    }
    for (cls.supertypes) |*st| {
        const sup = index.get(st.name.name) orelse continue;
        try collectClassMethods(gpa, index, sup.cls, sup.imports, display_class, methods, befores, afters, seen, visited);
    }
}

fn discoverClass(
    gpa: Allocator,
    module: *const ir.Module,
    index: *const std.StringHashMap(ClassEntry),
    file: *const ast.KotlinFile,
    c: *const ast.Class,
    pkg: []const u8,
    filter: ?[]const u8,
) Allocator.Error!?ClassTests {
    var methods: std.ArrayList(Method) = .empty;
    var befores: std.ArrayList([]const u8) = .empty;
    var afters: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    var visited = std.StringHashMap(void).init(gpa);
    defer visited.deinit();
    try collectClassMethods(gpa, index, c, file.imports, c.name.name, &methods, &befores, &afters, &seen, &visited);
    // Method-level `--filter`: if the class name itself does not match, keep
    // only the methods whose `Class.method` display matches (a class whose
    // name matches keeps all its methods). Dropped methods are freed here.
    if (filter) |pat| {
        if (!filterMatches(pat, c.name.name)) {
            var kept: usize = 0;
            for (methods.items) |m| {
                if (filterMatches(pat, m.display)) {
                    methods.items[kept] = m;
                    kept += 1;
                } else {
                    gpa.free(m.display);
                    gpa.free(m.name);
                }
            }
            methods.shrinkRetainingCapacity(kept);
        }
    }
    if (methods.items.len == 0) {
        methods.deinit(gpa);
        befores.deinit(gpa);
        afters.deinit(gpa);
        return null;
    }
    const fqn = qualify(gpa, pkg, c.name.name);
    defer gpa.free(fqn);
    return .{
        .cid = module.classIdByFqn(fqn),
        .class_name = try gpa.dupe(u8, c.name.name),
        .methods = try methods.toOwnedSlice(gpa),
        .befores = try befores.toOwnedSlice(gpa),
        .afters = try afters.toOwnedSlice(gpa),
        .class_ignored = hasKotlinTestAnno(c.annotations, file.imports, "Ignore"),
    };
}

fn freePlan(gpa: Allocator, plan: *Plan) void {
    for (plan.top) |t| gpa.free(t.display);
    gpa.free(plan.top);
    for (plan.classes) |ct| {
        gpa.free(ct.class_name);
        for (ct.methods) |m| {
            gpa.free(m.display);
            gpa.free(m.name);
        }
        gpa.free(ct.methods);
        for (ct.befores) |b| gpa.free(b);
        gpa.free(ct.befores);
        for (ct.afters) |a| gpa.free(a);
        gpa.free(ct.afters);
    }
    gpa.free(plan.classes);
}

// ---- execution -----------------------------------------------------------

const RunState = struct {
    gpa: Allocator,
    plan: *const Plan,
    results: std.ArrayList(TestResult),
    /// The previous `record`'s monotonic reading; the delta is the
    /// finished test's wall time in the progress stream.
    last_record_ns: i128 = 0,
};

/// Pull a printable `type: message` (or just `type`) out of a thrown value.
fn describeThrow(gpa: Allocator, v: Value) []const u8 {
    // Full rendered throwable (type, message, frames, causes) under
    // KLIO_ERR_TRACE — a teardown-masked failure is undiagnosable from
    // the type+message line alone.
    if (runtime.getenvSlice("KLIO_ERR_TRACE") != null) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        if (ir.eval.formatThrowable(gpa, &v, &buf, false, 0)) {
            if (gpa.dupe(u8, buf.items)) |owned| return owned else |_| {}
        } else |_| {}
    }
    const ty: []const u8 = v.exceptionFqn() orelse "exception";
    const msg: ?[]const u8 = switch (v) {
        .Exception => |e| if (e.message) |m| blk: {
            const g = m.borrow();
            defer g.deinit();
            break :blk g.get().bytes;
        } else null,
        else => null,
    };
    if (msg) |m| return std.fmt.allocPrint(gpa, "{s}: {s}", .{ ty, m }) catch gpa.dupe(u8, ty) catch "";
    return gpa.dupe(u8, ty) catch "";
}

fn record(st: *RunState, display: []const u8, outcome: Outcome, detail: ?[]const u8) Allocator.Error!void {
    // Stream per-test progress to stderr as each test completes — the
    // stdout report stays a single post-run block (consumers parse it),
    // but a long corpus run is observable while it happens. The duration
    // since the previous record is this test's wall time (setup included),
    // making the stream double as a per-test profile.
    const tag = switch (outcome) {
        .passed => "PASSED",
        .failed => "FAILED",
        .skipped => "SKIPPED",
    };
    const now_ns = runtime.clockMonotonicNanos();
    const dur_ms: i128 = @divTrunc(now_ns - st.last_record_ns, std.time.ns_per_ms);
    st.last_record_ns = now_ns;
    std.debug.print("[test] {s} {s} {d}ms\n", .{ display, tag, dur_ms });
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

/// Run one no-arg call and convert a non-`ok` outcome into a failure detail
/// string (owned by `gpa`). Returns null on success.
fn failureDetail(st: *RunState, oc: interp_ir.CallOutcome) ?[]const u8 {
    return switch (oc) {
        .ok => null,
        .threw => |v| describeThrow(st.gpa, v),
        .failed => |m| st.gpa.dupe(u8, m) catch "interpreter error",
    };
}

/// Per-test wall cap in seconds from `KLIO_TEST_WALL_CAP` (0/unset = off).
/// A wedged test (a genuine deadlock, a spinning virtual-clock loop) then
/// fails with "test wall-clock deadline exceeded" instead of hanging every
/// test after it in the class.
fn wallCapSeconds() i64 {
    const S = struct {
        var cached: ?i64 = null;
    };
    if (S.cached) |v| return v;
    const v: i64 = blk: {
        const s = runtime.getenvSlice("KLIO_TEST_WALL_CAP") orelse break :blk 0;
        break :blk std.fmt.parseInt(i64, s, 10) catch 0;
    };
    S.cached = v;
    return v;
}

fn armWallDeadline() void {
    const cap = wallCapSeconds();
    if (cap <= 0) return;
    ir.eval.test_wall_deadline_ms.store(ir.eval.nowMonotonicMs() + cap * 1000, .monotonic);
}

fn clearWallDeadline() void {
    ir.eval.test_wall_deadline_ms.store(0, .monotonic);
}

fn runBody(st: *RunState, vm: *Vm) Allocator.Error!void {
    defer clearWallDeadline();
    for (st.plan.top) |t| {
        if (t.ignored) {
            try record(st, t.display, .skipped, null);
            continue;
        }
        const fid = t.fid orelse {
            try record(st, t.display, .failed, try st.gpa.dupe(u8, "test function not found in built module"));
            continue;
        };
        armWallDeadline();
        const oc = try vm.callNoArg(fid);
        clearWallDeadline();
        if (failureDetail(st, oc)) |d| {
            try record(st, t.display, .failed, d);
        } else {
            try record(st, t.display, .passed, null);
        }
    }

    for (st.plan.classes) |ct| {
        for (ct.methods) |m| {
            if (ct.class_ignored or m.ignored) {
                try record(st, m.display, .skipped, null);
                continue;
            }
            const cid = ct.cid orelse {
                try record(st, m.display, .failed, try st.gpa.dupe(u8, "test class not found in built module"));
                continue;
            };
            // Fresh instance per test (JUnit semantics).
            armWallDeadline();
            const inst = try vm.construct(cid);
            switch (inst) {
                .ok => |receiver| {
                    var detail: ?[]const u8 = null;
                    // @BeforeTest -> @Test, stopping at the first failure.
                    for (ct.befores) |b| {
                        if (failureDetail(st, try vm.callMethod(&receiver, b))) |d| {
                            detail = d;
                            break;
                        }
                    }
                    if (detail == null) {
                        detail = failureDetail(st, try vm.callMethod(&receiver, m.name));
                    }
                    // @AfterTest always runs (on a fresh deadline budget so a
                    // timed-out test still tears down); its failure surfaces
                    // only if the test itself passed.
                    armWallDeadline();
                    for (ct.afters) |a| {
                        const ad = failureDetail(st, try vm.callMethod(&receiver, a));
                        if (ad) |d| {
                            if (detail == null) detail = d else st.gpa.free(d);
                        }
                    }
                    clearWallDeadline();
                    if (detail) |d| try record(st, m.display, .failed, d) else try record(st, m.display, .passed, null);
                },
                .threw => |v| try record(st, m.display, .failed, describeThrow(st.gpa, v)),
                .failed => |msg| try record(st, m.display, .failed, try st.gpa.dupe(u8, msg)),
            }
        }
    }
}

/// Discover and run every `@Test` in `user_asts` against the prepared `vm`,
/// writing test-program output to `out`. The returned `Report` is owned by
/// the caller (`Report.deinit`).
/// Discover the `@Test` display names WITHOUT running them (the `--isolate`
/// driver spawns one sub-process per name). Caller owns each returned string
/// and the slice.
pub fn listTests(
    gpa: Allocator,
    vm: *Vm,
    user_asts: []const ast.KotlinFile,
    only_fids: []const u32,
    filter: ?[]const u8,
) Allocator.Error![][]const u8 {
    var plan: Plan = blk: {
        const mg = vm.module.borrow();
        defer mg.deinit();
        break :blk try discover(gpa, mg.get(), user_asts, only_fids, filter);
    };
    defer freePlan(gpa, &plan);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for (plan.top) |t| try names.append(gpa, try gpa.dupe(u8, t.display));
    for (plan.classes) |c| for (c.methods) |m| try names.append(gpa, try gpa.dupe(u8, m.display));
    return names.toOwnedSlice(gpa);
}

pub fn runTests(
    gpa: Allocator,
    vm: *Vm,
    user_asts: []const ast.KotlinFile,
    out: Output,
    only_fids: []const u32,
    filter: ?[]const u8,
) Allocator.Error!Report {
    var plan: Plan = blk: {
        const mg = vm.module.borrow();
        defer mg.deinit();
        break :blk try discover(gpa, mg.get(), user_asts, only_fids, filter);
    };
    defer freePlan(gpa, &plan);

    // Stamp the clock at run start so the FIRST test's streamed duration is
    // real; it previously printed 0ms (the delta base was unset), which read
    // as "did not run" whenever a --filter made the target test the first.
    var st = RunState{ .gpa = gpa, .plan = &plan, .results = .empty, .last_record_ns = runtime.clockMonotonicNanos() };
    const prep = try vm.runCalls(out, *RunState, &st, runBody);
    if (prep) |_| {
        // Startup failed; surface it as a single failing entry so the caller
        // reports a non-zero exit.
        try record(&st, "<startup>", .failed, try gpa.dupe(u8, "module initialization failed"));
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    for (st.results.items) |r| switch (r.outcome) {
        .passed => passed += 1,
        .failed => failed += 1,
        .skipped => skipped += 1,
    };
    return .{
        .results = try st.results.toOwnedSlice(gpa),
        .passed = passed,
        .failed = failed,
        .skipped = skipped,
    };
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
