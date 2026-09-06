//! The kotlinc box-test conformance corpus: every program under
//! `kotlin/compiler/testData/codegen/box` declares `fun box(): String` that
//! must return `"OK"`. Each selected test runs as its own child `klio run`
//! (its `// FILE:` sections materialized as separate source files, plus a
//! synthesized `main` that calls `box()` and asserts the answer), so a
//! crash or hang isolates to one named test.
//!
//! Tests are selected by their header directives, never by name: a
//! directive klio honors or can ignore is on the allow list, a directive
//! that binds the test to a JVM/JS/multi-module framework feature excludes
//! it, and an unknown directive excludes it under `unknown:<NAME>` so the
//! exclusion census names what to teach the runner next. Shared by the
//! `box_conformance` itest (the ratchet) and `klio-census box`.
const std = @import("std");
const runtime = @import("runtime");

pub const CORPUS = "kotlin/compiler/testData/codegen/box";
pub const HELPERS_DIR = "kotlin/compiler/testData/diagnostics/helpers/coroutines";
const HELPERS = [_][]const u8{
    HELPERS_DIR ++ "/CoroutineUtil.kt",
    HELPERS_DIR ++ "/CoroutineHelpers.kt",
    HELPERS_DIR ++ "/StateMachineChecker.kt",
    HELPERS_DIR ++ "/TailCallOptimizationChecker.kt",
};
pub const SCRATCH_HOME = "/tmp/klio_itest_box_home";

/// The ratchet: the measured pass count of the last recorded census is the
/// floor (raise as fixes land, never lower) and its measured failure count
/// the ceiling with no slack (lower as fixes land; raise only with a
/// root-caused record). First census 2026-09-05 (build-2.4.10-RC corpus,
/// ReleaseSafe harness): 5246 passed, 1105 failed, 20 did not complete of
/// 6371 selected, 980 excluded by directive — `plans/kotlinc-box-conformance.md`.
/// Kotlin 2.4 destructuring forms: 5409 / 942. Explicit primitive
/// `rangeTo` + invoked lambda arguments: 5440 / 911. Enum entries with
/// bodies as real subclasses: 5461 / 890. Language feature flags and the
/// name-based short form: 5477 / 874. Corpus syntax gaps and contextual
/// anonymous functions: 5506 / 845. Tailrec self-calls in tail position
/// in every form: 5530 / 822. Bare accessors, enum secondary
/// constructors, vararg enum entries: 5542 / 810. Parent secondary
/// constructors from subclass headers, enum overrides virtual: 5553 / 799.
/// Omitted varargs empty on every route, SAM context parameters: 5560 / 792.
/// Annotation instances by value, captured locals in super calls, enum
/// static scope and initialization: 5623 / 729.
/// The `provideDelegate` convention at every delegated property: 5647 / 705.
/// Callable references compare by target, receiver and adaptation: 5665 / 687.
pub const BASELINE: usize = 5665;
pub const MAX_FAILED: usize = 687;

/// Directives that bind a test to a framework feature klio has no
/// counterpart for: a backend restriction, a second module, reflection,
/// JDK classes, compiler flags, an older language version, or a helper the
/// test framework synthesizes.
const EXCLUDE = [_][]const u8{
    "TARGET_BACKEND",       "MODULE",                             "WITH_REFLECT",
    "FULL_JDK",             "JVM_TARGET",                         "FREE_COMPILER_ARGS",
    "API_VERSION",          "LANGUAGE_VERSION",                   "ASSERTIONS_MODE",
    "USE_OLD_INLINE_CLASSES_MANGLING_SCHEME", "ENABLE_JVM_PREVIEW", "CHECK_STATE_MACHINE",
    "CHECK_TAIL_CALL_OPTIMIZATION", "WITH_PLATFORM_LIBS",         "JDK_KIND",
    "NATIVE_STANDALONE",    "ALLOW_KOTLIN_PACKAGE",               "INHERIT_MULTIFILE_PARTS",
    "SAM_CONVERSIONS",      "JVM_DEFAULT_MODE",                   "STRING_CONCAT",
    "LAMBDAS",              "JVM_ABI_K1_K2_DIFF",                 "CHECK_TYPE_WITH_EXACT",
};
/// Directives klio honors (`WITH_STDLIB`, `WITH_COROUTINES`, `LANGUAGE`
/// enabling a feature, the value-class placeholder) or can ignore: notes,
/// per-backend mutes, IR/bytecode dump and listing checks that sit beside
/// the `box()` answer, JS/wasm/native pipeline flags.
const ALLOW = [_][]const u8{
    "WITH_STDLIB",                  "WITH_RUNTIME",                        "WITH_COROUTINES",
    "LANGUAGE",                     "WORKS_WHEN_VALUE_CLASS",              "ISSUE",
    "IGNORE_BACKEND",               "IGNORE_BACKEND_K1",                   "IGNORE_BACKEND_K2",
    "IGNORE_BACKEND_K2_MULTI_MODULE", "IGNORE_BACKEND_MULTI_MODULE",       "IGNORE_IR_DESERIALIZATION_TEST",
    "IGNORE_HMPP",                  "IGNORE_NATIVE",                       "IGNORE_DEXING",
    "IGNORE_FIR_DIAGNOSTICS_DIFF",  "IGNORE_BACKED",                       "DONT_TARGET_EXACT_BACKEND",
    "KJS_WITH_FULL_RUNTIME",        "KJS_FULL_RUNTIME",                    "TODO",
    "REASON",                       "STATUS",                              "NOTE",
    "FIR_IDENTICAL",                "FIR_DUMP",                            "DUMP_IR",
    "DUMP_IR_OF_PREPROCESSED_INLINE_FUNCTIONS", "DUMP_IR_AFTER_INLINE",   "NO_CHECK_LAMBDA_INLINING",
    "USE_OLD_EXCEPTION_HANDLING_PROPOSAL", "USE_NEW_EXCEPTION_HANDLING_PROPOSAL", "CHECK_BYTECODE_LISTING",
    "CHECK_BYTECODE_TEXT",          "CHECK_CASES_COUNT",                   "CHECK_IF_COUNT",
    "CHECK_NOT_CALLED",             "DIAGNOSTICS",                         "FILECHECK_STAGE",
    "SKIP_MANGLE_VERIFICATION",     "SKIP_DCE_DRIVEN",                     "SKIP_NODE_JS",
    "SKIP_KLIB_TEST",               "SKIP_IR_INCREMENTAL_CHECKS",          "SKIP_KT_DUMP",
    "DISABLE_IR_VISIBILITY_CHECKS", "STOP_EVALUATION_CHECKS",              "RUN_THIRD_PARTY_OPTIMIZER",
    "OPT_IN",                       "PROPERTY_LAZY_INITIALIZATION",        "DISABLE_NATIVE",
    "IGNORE_KLIB_RUNTIME_ERRORS_WITH_CUSTOM_SECOND_STAGE", "IGNORE_KLIB_BACKEND_ERRORS_WITH_CUSTOM_FIRST_STAGE",
    "IGNORE_KLIB_BACKEND_ERRORS_WITH_CUSTOM_SECOND_STAGE", "WASM_FAILS_IN", "WASM_MUTE_REASON",
    "WASM_FAILS_IN_MULTI_MODULE_MODE", "WASM_FAILS_IN_MULTI_MODULE_MODE_WINDOWS", "WASM_FAILS_IN_SINGLE_MODULE_MODE",
    "WASM_DCE_EXPECTED_OUTPUT_SIZE", "WASM_OPT_EXPECTED_OUTPUT_SIZE",      "WASM_CHECK_INSTRUCTION_NOT_IN_FUNCTION",
    "WASM_ALLOW_FQNAME_IN_KCLASS",  "FULL_RUNTIME",                        "IGNORE_HEADER_MODE",
    "CHECK_BREAKS_COUNT",           "CHECK_CONTAINS_NO_CALLS",             "CHECK_FUNCTION_EXISTS",
    "CHECK_LABELS_COUNT",           "CHECK_STRING_LITERAL_COUNT",          "DUMP_CFG",
    "ENHANCED_COROUTINES_DEBUGGING", "ES_MODULES",                         "EXPECT_GENERATED_JS",
    "FIXME",                        "NB",                                  "IGNORE_KLIB_FRONTEND_ERRORS_WITH_CUSTOM_SECOND_STAGE",
    "IGNORE_LIGHT_TREE",            "KLIB_RELATIVE_PATH_BASES",            "NO_COMMON_FILES",
    "RETURN_VALUE_CHECKER_MODE",    "SANITIZE_PARENTHESES",                "CHECK_NOT_CALLED_IN_SCOPE",
    "RECOMPILE",                    "SKIP_IR_DESERIALIZATION_CHECKS",      "SKIP_TXT",
    "SPLIT_PER_MODULE",             "USE_TYPE_TABLE",                      "WITH_SDTLIB",
    "WTIH_STDLIB",
};

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

pub const Directive = struct { name: []const u8, value: []const u8 };

/// `// NAME` or `// NAME: value` (an old `// !NAME` spelling too), with
/// nothing else on the line. Uppercase words in ordinary comments
/// (`// TODO: …`) match as well; the caller confines the header scan to the
/// lines before the first code line and the allow list carries the note
/// words.
pub fn parseDirective(line: []const u8) ?Directive {
    const s = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, s, "//")) return null;
    var i: usize = 2;
    while (i < s.len and s[i] == ' ') i += 1;
    if (i < s.len and s[i] == '!') i += 1;
    const start = i;
    if (i >= s.len or !(s[i] >= 'A' and s[i] <= 'Z')) return null;
    while (i < s.len and ((s[i] >= 'A' and s[i] <= 'Z') or (s[i] >= '0' and s[i] <= '9') or s[i] == '_')) i += 1;
    const name = s[start..i];
    while (i < s.len and s[i] == ' ') i += 1;
    if (i == s.len) return .{ .name = name, .value = "" };
    if (s[i] != ':') return null;
    return .{ .name = name, .value = std.mem.trim(u8, s[i + 1 ..], " \t") };
}

fn isCommentOrBlank(line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t\r");
    return s.len == 0 or std.mem.startsWith(u8, s, "//") or std.mem.startsWith(u8, s, "/*") or std.mem.startsWith(u8, s, "*");
}

pub const Section = struct { name: []const u8, text: []const u8 };

pub const Case = struct {
    rel: []const u8,
    sections: []const Section = &.{},
    /// Why the test is not run (the exclusion census key), or null.
    reason: ?[]const u8 = null,
    with_coroutines: bool = false,
    value_class_placeholder: bool = false,
    /// `// LANGUAGE: +Feature …` specs, passed to the child as `--language=`.
    language: []const u8 = "",
    /// The package of the file that declares `box()`, for the import in
    /// the synthesized main.
    package: ?[]const u8 = null,
};

fn packageOf(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const s = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, s, "package ")) {
            const rest = std.mem.trim(u8, s["package ".len..], " \t;");
            return if (rest.len == 0) null else rest;
        }
    }
    return null;
}

fn languageDisablesFeature(value: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t,");
    while (it.next()) |tok| if (tok.len > 0 and tok[0] == '-') return true;
    return false;
}

/// Parse one corpus file: header directives, `// FILE:` sections, and the
/// selection verdict.
pub fn parseCase(a: std.mem.Allocator, rel: []const u8, src: []const u8) !Case {
    var c: Case = .{ .rel = rel };
    var sections: std.ArrayList(Section) = .empty;
    var cur_name: []const u8 = "__preamble.kt";
    var cur: std.ArrayList(u8) = .empty;
    var in_header = true;
    var reason: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (parseDirective(line)) |d| {
            if (std.mem.eql(u8, d.name, "FILE")) {
                try sections.append(a, .{ .name = cur_name, .text = try cur.toOwnedSlice(a) });
                cur_name = if (d.value.len == 0) "__unnamed.kt" else d.value;
                continue;
            }
            if (std.mem.eql(u8, d.name, "MODULE")) {
                reason = reason orelse "MODULE";
                continue;
            }
            if (in_header) {
                if (inList(&EXCLUDE, d.name)) {
                    reason = reason orelse d.name;
                } else if (std.mem.eql(u8, d.name, "LANGUAGE")) {
                    if (languageDisablesFeature(d.value)) reason = reason orelse "LANGUAGE:-feature";
                    c.language = d.value;
                } else if ((std.mem.eql(u8, d.name, "IGNORE_BACKEND") or std.mem.eql(u8, d.name, "IGNORE_BACKEND_K2")) and
                    std.mem.indexOf(u8, d.value, "ANY") != null)
                {
                    // A mute on every backend under the current frontend.
                    // `IGNORE_BACKEND_K1` mutes the retired K1 frontend only
                    // and `_MULTI_MODULE` mutes a mode this runner never
                    // uses; both stay selected.
                    reason = reason orelse try std.fmt.allocPrint(a, "{s}:ANY", .{d.name});
                } else if (std.mem.eql(u8, d.name, "WITH_COROUTINES")) {
                    c.with_coroutines = true;
                } else if (std.mem.eql(u8, d.name, "WORKS_WHEN_VALUE_CLASS")) {
                    c.value_class_placeholder = true;
                } else if (!inList(&ALLOW, d.name)) {
                    reason = reason orelse try std.fmt.allocPrint(a, "unknown:{s}", .{d.name});
                }
            }
            try cur.appendSlice(a, line);
            try cur.append(a, '\n');
            continue;
        }
        if (!isCommentOrBlank(line)) in_header = false;
        try cur.appendSlice(a, line);
        try cur.append(a, '\n');
    }
    try sections.append(a, .{ .name = cur_name, .text = try cur.toOwnedSlice(a) });

    var kept: std.ArrayList(Section) = .empty;
    var has_box = false;
    for (sections.items) |s| {
        var only_comments = true;
        var lit = std.mem.splitScalar(u8, s.text, '\n');
        while (lit.next()) |l| if (!isCommentOrBlank(l)) {
            only_comments = false;
            break;
        };
        if (only_comments) continue;
        if (!std.mem.endsWith(u8, s.name, ".kt")) {
            reason = reason orelse "non-kt-section";
            continue;
        }
        if (std.mem.indexOf(u8, s.text, "fun box()") != null) {
            has_box = true;
            c.package = packageOf(s.text);
        }
        try kept.append(a, s);
    }
    if (!has_box) reason = reason orelse "no-box";
    c.sections = try kept.toOwnedSlice(a);
    c.reason = reason;
    return c;
}

/// The `box/diagnostics` tests carry diagnostics-test markup
/// (`<!NON_TAIL_RECURSIVE_CALL!>call<!>`, `<!>`) that the framework strips
/// before compiling; strip it the same way.
pub fn stripDiagnosticMarkup(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, "<!") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 2 <= text.len and text[i] == '<' and text[i + 1] == '!') {
            if (std.mem.indexOfPos(u8, text, i + 2, "!>")) |close| {
                // `<!IDENT, IDENT2!>` opens a marked region.
                var ident_like = true;
                for (text[i + 2 .. close]) |ch| {
                    if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == ',' or ch == ' ' or ch == '(' or ch == ')' or ch == '"' or ch == '.' or ch == ':' or ch == ';')) {
                        ident_like = false;
                        break;
                    }
                }
                if (ident_like and close > i + 2) {
                    i = close + 2;
                    continue;
                }
            }
            if (i + 3 <= text.len and text[i + 2] == '>') {
                i += 3;
                continue;
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

pub fn synthesizedMain(a: std.mem.Allocator, c: *const Case) ![]const u8 {
    const import_line = if (c.package) |p| try std.fmt.allocPrint(a, "import {s}.box\n", .{p}) else "";
    return std.fmt.allocPrint(a,
        \\{s}fun main() {{
        \\    val r = box()
        \\    if (r != "OK") throw AssertionError("box() returned " + r)
        \\    println("BOX-OK")
        \\}}
        \\
    , .{import_line});
}

pub const Summary = struct {
    total: usize = 0,
    selected: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    excluded: usize = 0,
    incomplete: usize = 0,
};

fn klioBin(env: *const std.process.Environ.Map) []const u8 {
    return env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
}

fn envUsize(name: []const u8, default: usize) usize {
    if (std.c.getenv(@ptrCast(name.ptr))) |v| {
        if (std.fmt.parseInt(usize, std.mem.span(v), 10) catch null) |n| return n;
    }
    return default;
}

fn workerCount() usize {
    // Box children are sub-second programs, so the runner takes its own
    // width before the census-wide `KLIO_ITEST_JOBS` (sized for heavy
    // library children).
    const own = envUsize("KLIO_BOX_JOBS", 0);
    if (own >= 1) return @min(own, 64);
    const n = envUsize("KLIO_ITEST_JOBS", 0);
    if (n >= 1) return @min(n, 64);
    const cores = std.Thread.getCpuCount() catch 4;
    return std.math.clamp(cores, 1, 8);
}

const RunResult = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8, timed_out: bool = false };

fn runChild(a: std.mem.Allocator, env: *std.process.Environ.Map, argv: []const []const u8, timeout_ms: i64) !RunResult {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const r = std.process.run(a, threaded.io(), .{
        .argv = argv,
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |e| {
        if (e == error.Timeout) return .{ .term = .{ .exited = 124 }, .stdout = "", .stderr = "", .timed_out = true };
        return e;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

/// 1,483 corpus files `import kotlin.test.*`; the pack is built from the
/// tree and installed into the scratch home once per census, the way the
/// library censuses install theirs.
fn installKotlinTest(a: std.mem.Allocator, env: *std.process.Environ.Map, bin: []const u8, cap_ms: i64) !void {
    const b = try runChild(a, env, &.{ bin, "pack", "build", "kotlin-klio/klio-kotlin-test" }, cap_ms);
    if (b.term != .exited or b.term.exited != 0) {
        std.debug.print("box_conformance: kotlin.test pack build failed:\n{s}\n", .{b.stderr});
        return error.PackBuildFailed;
    }
    const i = try runChild(a, env, &.{ bin, "pack", "install", "target/packs/kotlin.test.klio-pack" }, cap_ms);
    if (i.term != .exited or i.term.exited != 0) {
        std.debug.print("box_conformance: kotlin.test pack install failed:\n{s}\n", .{i.stderr});
        return error.PackInstallFailed;
    }
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(end, 160)];
}

fn lastLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, t, '\n')) |i| i + 1 else 0;
    return t[start..@min(t.len, start + 160)];
}

fn collectKt(a: std.mem.Allocator, io: std.Io, dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            try collectKt(a, io, try std.fs.path.join(a, &.{ dir, entry.name }), out);
        } else if (std.mem.endsWith(u8, entry.name, ".kt")) {
            try out.append(a, try std.fs.path.join(a, &.{ dir, entry.name }));
        }
    }
}

const Job = struct { case: *const Case, argv: []const []const u8 };

const Pool = struct {
    fn worker(
        jobs: []const Job,
        env: *std.process.Environ.Map,
        next: *std.atomic.Value(usize),
        passed: *std.atomic.Value(usize),
        failed: *std.atomic.Value(usize),
        incomplete: *std.atomic.Value(usize),
        timeout_ms: i64,
    ) void {
        var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_inst.deinit();
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= jobs.len) break;
            _ = arena_inst.reset(.retain_capacity);
            const a = arena_inst.allocator();
            const job = jobs[i];
            const r = runChild(a, env, job.argv, timeout_ms) catch {
                _ = incomplete.fetchAdd(1, .monotonic);
                std.debug.print("[box-incomplete] {s}: spawn failed\n", .{job.case.rel});
                continue;
            };
            if (r.timed_out) {
                _ = incomplete.fetchAdd(1, .monotonic);
                std.debug.print("[box-timeout] {s}\n", .{job.case.rel});
                continue;
            }
            const exited_ok = r.term == .exited and r.term.exited == 0;
            if (exited_ok and std.mem.indexOf(u8, r.stdout, "BOX-OK") != null) {
                _ = passed.fetchAdd(1, .monotonic);
                continue;
            }
            if (r.term != .exited) {
                _ = incomplete.fetchAdd(1, .monotonic);
                std.debug.print("[box-crash] {s}: {s}\n", .{ job.case.rel, lastLine(r.stderr) });
                continue;
            }
            _ = failed.fetchAdd(1, .monotonic);
            const why = if (r.stderr.len > 0) firstLine(r.stderr) else lastLine(r.stdout);
            std.debug.print("[box-fail] {s}: {s}\n", .{ job.case.rel, why });
        }
    }
};

/// Run the census: parse every corpus file, print the exclusion census and
/// every failure by name, and return the counts. `KLIO_BOX_FILTER` keeps
/// only the tests whose path contains the substring; `KLIO_ITEST_JOBS`
/// sets the worker width; `KLIO_BOX_TIMEOUT_MS` the per-test wall
/// (default 60 s, ×4 on a Debug harness).
pub fn runCensus(a: std.mem.Allocator, label: []const u8) !Summary {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().access(io, CORPUS, .{}) catch {
        std.debug.print("{s}: corpus {s} not populated (scripts/init-kotlin-submodule.sh); skipping\n", .{ label, CORPUS });
        return error.SkipZigTest;
    };
    var env = std.process.Environ.Map.init(a);
    runtime.procEnvPutAllInto(a, &env);
    try env.put("HOME", SCRATCH_HOME);
    const bin = klioBin(&env);
    const slowdown: i64 = if (std.mem.endsWith(u8, bin, "-Debug")) 4 else 1;
    const timeout_ms: i64 = @as(i64, @intCast(envUsize("KLIO_BOX_TIMEOUT_MS", 60_000))) * slowdown;
    const filter: ?[]const u8 = if (std.c.getenv("KLIO_BOX_FILTER")) |v| std.mem.span(v) else null;

    std.Io.Dir.cwd().createDirPath(io, SCRATCH_HOME) catch {};
    try installKotlinTest(a, &env, bin, 120_000 * slowdown);

    var files: std.ArrayList([]const u8) = .empty;
    try collectKt(a, io, CORPUS, &files);
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var summary: Summary = .{ .total = files.items.len };
    var reasons = std.StringHashMap(usize).init(a);
    var jobs: std.ArrayList(Job) = .empty;
    const cases_dir = SCRATCH_HOME ++ "/cases";
    std.Io.Dir.cwd().createDirPath(io, cases_dir) catch {};
    for (files.items) |path| {
        const rel = path[CORPUS.len + 1 ..];
        if (filter) |f| if (std.mem.indexOf(u8, rel, f) == null) continue;
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch continue;
        const case = try a.create(Case);
        case.* = try parseCase(a, rel, src);
        if (case.reason) |why| {
            summary.excluded += 1;
            const g = try reasons.getOrPut(why);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
            continue;
        }
        summary.selected += 1;
        const dir_name = try std.mem.replaceOwned(u8, a, rel[0 .. rel.len - 3], "/", "__");
        const dir = try std.fs.path.join(a, &.{ cases_dir, dir_name });
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, bin);
        try argv.append(a, "run");
        if (case.language.len != 0) try argv.append(a, try std.fmt.allocPrint(a, "--language={s}", .{case.language}));
        for (case.sections, 0..) |s, si| {
            const base = std.fs.path.basename(s.name);
            const fname = try std.fmt.allocPrint(a, "{d}_{s}", .{ si, base });
            const fpath = try std.fs.path.join(a, &.{ dir, fname });
            const stripped = try stripDiagnosticMarkup(a, s.text);
            const text = if (case.value_class_placeholder)
                try std.mem.replaceOwned(u8, a, stripped, "OPTIONAL_JVM_INLINE_ANNOTATION", "@JvmInline")
            else
                stripped;
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fpath, .data = text });
            try argv.append(a, fpath);
        }
        if (case.with_coroutines) for (HELPERS) |h| try argv.append(a, h);
        const main_path = try std.fs.path.join(a, &.{ dir, "__box_main.kt" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = try synthesizedMain(a, case) });
        try argv.append(a, main_path);
        try jobs.append(a, .{ .case = case, .argv = try argv.toOwnedSlice(a) });
    }

    // Exclusion census, largest reason first.
    {
        const Entry = struct { k: []const u8, v: usize };
        var list: std.ArrayList(Entry) = .empty;
        var rit = reasons.iterator();
        while (rit.next()) |e| try list.append(a, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
        std.mem.sort(Entry, list.items, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return x.v > y.v or (x.v == y.v and std.mem.lessThan(u8, x.k, y.k));
            }
        }.lt);
        for (list.items) |e| std.debug.print("[box-excluded] {s}: {d}\n", .{ e.k, e.v });
    }

    // One serial warm-up run bakes the stdlib image into the scratch home
    // before the pool fans out.
    if (jobs.items.len > 0) {
        _ = runChild(a, &env, jobs.items[0].argv, timeout_ms * 4) catch {};
    }

    var next = std.atomic.Value(usize).init(0);
    var passed = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(usize).init(0);
    var incomplete = std.atomic.Value(usize).init(0);
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const Job, jobs.items), &env, &next, &passed, &failed, &incomplete, timeout_ms,
        }));
    }
    for (threads.items) |t| t.join();
    summary.passed = passed.load(.monotonic);
    summary.failed = failed.load(.monotonic);
    summary.incomplete = incomplete.load(.monotonic);
    return summary;
}

pub fn printSummary(label: []const u8, s: Summary, baseline: usize, max_failed: usize) void {
    std.debug.print(
        "{s}: {d} passed, {d} failed, {d} did not complete of {d} selected ({d} excluded of {d} files; baseline {d}, max_failed {d})\n",
        .{ label, s.passed, s.failed, s.incomplete, s.selected, s.excluded, s.total, baseline, max_failed },
    );
}

test "directive lines parse and ordinary comments do not" {
    const d = parseDirective("// LANGUAGE: +ContextParameters").?;
    try std.testing.expectEqualStrings("LANGUAGE", d.name);
    try std.testing.expectEqualStrings("+ContextParameters", d.value);
    try std.testing.expectEqualStrings("WITH_STDLIB", parseDirective("// WITH_STDLIB").?.name);
    try std.testing.expectEqualStrings("LANGUAGE", parseDirective("// !LANGUAGE: -Foo").?.name);
    try std.testing.expect(parseDirective("// KT-12345 regression") == null);
    try std.testing.expect(parseDirective("// see the spec") == null);
    try std.testing.expect(parseDirective("val x = 1 // OK") == null);
}

test "diagnostics-test markup is stripped, comparison operators are not" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const got = try stripDiagnosticMarkup(arena.allocator(), "return 1 + <!NON_TAIL_RECURSIVE_CALL!>bad<!>(x - 1) <!A, B!>+<!> y");
    try std.testing.expectEqualStrings("return 1 + bad(x - 1) + y", got);
    const same = try stripDiagnosticMarkup(arena.allocator(), "if (a <! b) x else y");
    try std.testing.expectEqualStrings("if (a <! b) x else y", same);
}

test "a case splits FILE sections, finds the box package, and selects by directive" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const src =
        \\// WITH_STDLIB
        \\// FILE: lib.kt
        \\package foo
        \\fun helper() = "OK"
        \\// FILE: main.kt
        \\package foo
        \\fun box(): String = helper()
        \\
    ;
    const c = try parseCase(arena.allocator(), "x/y.kt", src);
    try std.testing.expect(c.reason == null);
    try std.testing.expectEqual(@as(usize, 2), c.sections.len);
    try std.testing.expectEqualStrings("foo", c.package.?);
    const m = try synthesizedMain(arena.allocator(), &c);
    try std.testing.expect(std.mem.startsWith(u8, m, "import foo.box\n"));

    const jvm = try parseCase(arena.allocator(), "x/z.kt", "// TARGET_BACKEND: JVM\nfun box() = \"OK\"\n");
    try std.testing.expectEqualStrings("TARGET_BACKEND", jvm.reason.?);
    const unknown = try parseCase(arena.allocator(), "x/w.kt", "// SOME_NEW_THING\nfun box() = \"OK\"\n");
    try std.testing.expectEqualStrings("unknown:SOME_NEW_THING", unknown.reason.?);
    const minus = try parseCase(arena.allocator(), "x/v.kt", "// LANGUAGE: -Inline\nfun box() = \"OK\"\n");
    try std.testing.expectEqualStrings("LANGUAGE:-feature", minus.reason.?);
    const body_comment = try parseCase(arena.allocator(), "x/u.kt", "fun box(): String {\n    // TODO: tighten\n    return \"OK\"\n}\n");
    try std.testing.expect(body_comment.reason == null);
}
