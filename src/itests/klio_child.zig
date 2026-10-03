//! The child runner the program-running suites share: Kotlin runs through the
//! harness binary (`KLIO_ITEST_BIN`) out of process, as a user runs it, over
//! a data home with every shipped pack installed.
//!
//! The build installs the packs once into a shared home keyed by the pack
//! sources and the harness binary (`klio-test-home`, see `test_home.zig`) and
//! names it in `KLIO_ITEST_HOME`. A suite binary started by hand without that
//! variable installs them under `FALLBACK_ROOT` on first use instead.

const std = @import("std");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// Where a hand-run suite keeps its packs when the build named no home: a
/// directory per harness binary under it, so a suite run by another checkout
/// or another binary never reinstalls the packs under a run in flight.
pub const FALLBACK_ROOT = "/tmp/klio_itest_home";
pub const RUN_TIMEOUT_MS: i64 = 180_000;

/// The harness binary the suites spawn.
pub fn bin() []const u8 {
    return runtime.envOnce("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
}

/// SKIP notices and progress are silent by default: stderr from a passing
/// `zig build` run step is rendered as a failed command.
pub fn verbose() bool {
    return runtime.envOnce("KLIO_ITEST_VERBOSE") != null;
}

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn exitedZero(self: Output) bool {
        return self.term == .exited and self.term.exited == 0;
    }

    /// The exit code, or -1 for a signal or a stop.
    pub fn code(self: Output) i64 {
        return switch (self.term) {
            .exited => |x| x,
            else => -1,
        };
    }
};

pub const SpawnOptions = struct {
    timeout_ms: i64 = RUN_TIMEOUT_MS,
    cwd: ?[]const u8 = null,
};

/// Runs `argv` under `env`, killing it after `opts.timeout_ms` (term 124).
pub fn runKlio(a: Allocator, env: *const Environ.Map, argv: []const []const u8, opts: SpawnOptions) !Output {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Fork fails with EAGAIN when many suites spawn at once, which is
    // machine pressure rather than a verdict.
    var attempt: usize = 0;
    var child = while (true) : (attempt += 1) {
        break std.process.spawn(io, .{
            .argv = argv,
            .environ_map = env,
            .cwd = if (opts.cwd) |c| .{ .path = c } else .inherit,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |e| {
            if (e != error.SystemResources or attempt >= 3) return e;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2000), .awake) catch {};
            continue;
        };
    };
    defer child.kill(io);
    var mrb: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, mrb.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    var timed_out = false;
    while (mr.fill(64, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(opts.timeout_ms), .clock = .awake } })) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }
    const term: std.process.Child.Term = if (timed_out) blk: {
        child.kill(io);
        break :blk .{ .exited = 124 };
    } else try child.wait(io);
    const out = try mr.toOwnedSlice(0);
    const err_out = try mr.toOwnedSlice(1);
    return .{ .term = term, .stdout = out, .stderr = err_out };
}

/// The parent's environment with `home` as the data home, the base image
/// cache on, a clipboard of the program's own, so a test run neither reads
/// nor replaces the user's, and the en-US locale and a light system theme
/// whatever the host's.
pub fn envFor(a: Allocator, home_dir: []const u8) !Environ.Map {
    var map = Environ.Map.init(a);
    runtime.procEnvPutAllInto(a, &map);
    try map.put("HOME", home_dir);
    try map.put("KLIO_HOME", home_dir);
    try map.put("KLIO_CLIPBOARD", "private");
    try map.put("KLIO_LOCALE", "en-US");
    try map.put("KLIO_SYSTEM_THEME", "light");
    _ = map.swapRemove("KLIO_SEMA_IMAGE");
    return map;
}

/// `envFor` the shared test home.
pub fn baseEnv(a: Allocator) !Environ.Map {
    return envFor(a, try home(a));
}

/// Names the `<name>.input` beside the program `path` as its windows'
/// scripted input (`KLIO_WIN_INPUT`), as the corpus runs a windowed example:
/// without it a window on a display waits for input that never comes.
pub fn putWindowInput(a: Allocator, env: *Environ.Map, path: []const u8) !void {
    if (!std.mem.endsWith(u8, path, ".kt")) return;
    const script = try std.fmt.allocPrint(a, "{s}.input", .{path[0 .. path.len - ".kt".len]});
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const abs = std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), script, a) catch |e| switch (e) {
        error.FileNotFound => return,
        else => |x| return x,
    };
    try env.put("KLIO_WIN_INPUT", abs);
}

var fallback_lock: runtime.SpinMutex = .{};
var fallback_home: ?[]const u8 = null;

/// The data home the suites run in: `KLIO_ITEST_HOME`, else the binary's
/// directory under `FALLBACK_ROOT` with every pack installed into it on first
/// use.
pub fn home(a: Allocator) ![]const u8 {
    if (runtime.envOnce("KLIO_ITEST_HOME")) |h| return h;
    fallback_lock.lock();
    defer fallback_lock.unlock();
    if (fallback_home) |h| return h;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try fallbackDir(std.heap.page_allocator, bin(), runtime.envOnce("PWD") orelse "");
    try ensureHome(a, io, bin(), dir, try binaryKey(a, io, bin()));
    fallback_home = dir;
    return dir;
}

/// The fallback home of the harness `klio_bin` named from `cwd`: one per
/// binary, whatever it was rebuilt into since.
fn fallbackDir(a: Allocator, klio_bin: []const u8, cwd: []const u8) ![]const u8 {
    var h = std.hash.Wyhash.init(0);
    if (!std.fs.path.isAbsolute(klio_bin)) h.update(cwd);
    h.update("\x00");
    h.update(klio_bin);
    return std.fmt.allocPrint(a, "{s}/{x:0>16}", .{ FALLBACK_ROOT, h.final() });
}

test "each harness binary has a fallback home of its own" {
    const a = std.testing.allocator;
    const main_rel = try fallbackDir(a, "zig-out/bin/klio", "/src/klio");
    defer a.free(main_rel);
    const wt_rel = try fallbackDir(a, "zig-out/bin/klio", "/src/klio/.claude/worktrees/w");
    defer a.free(wt_rel);
    const other = try fallbackDir(a, "/snap/klio-harness", "/src/klio");
    defer a.free(other);
    const same = try fallbackDir(a, "/snap/klio-harness", "/elsewhere");
    defer a.free(same);
    try std.testing.expect(std.mem.startsWith(u8, main_rel, FALLBACK_ROOT ++ "/"));
    try std.testing.expect(!std.mem.eql(u8, main_rel, wt_rel));
    try std.testing.expect(!std.mem.eql(u8, main_rel, other));
    try std.testing.expectEqualStrings(other, same);
}

const KEY_FILE = ".klio-itest-key";

/// Makes `home_dir` a data home with every shipped pack built and installed
/// by `klio_bin`, unless it already holds the packs of `key`.
pub fn ensureHome(a: Allocator, io: std.Io, klio_bin: []const u8, home_dir: []const u8, key: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const key_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ home_dir, KEY_FILE });
    if (cwd.readFileAlloc(io, key_path, a, .limited(1 << 16))) |have| {
        if (std.mem.eql(u8, have, key)) return;
    } else |_| {}
    cwd.deleteTree(io, home_dir) catch {};
    try cwd.createDirPath(io, home_dir);
    var env = try envFor(a, home_dir);
    try installPacks(a, io, &env, klio_bin, home_dir);
    try cwd.writeFile(io, .{ .sub_path = key_path, .data = key });
}

/// The fallback home's key: the binary's path, size and modification time.
fn binaryKey(a: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    return std.fmt.allocPrint(a, "{s}\n{d}\n{d}\n", .{ path, st.size, st.mtime.nanoseconds });
}

/// The shipped pack directories under `kotlin-klio/`, sorted.
pub fn packDirs(a: Allocator, io: std.Io) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    var root = try std.Io.Dir.cwd().openDir(io, "kotlin-klio", .{ .iterate = true });
    defer root.close(io);
    var it = root.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        // The upstream runtime's own sources; the engine pack supplies
        // `androidx.compose.runtime`.
        if (std.mem.eql(u8, e.name, "klio-compose-runtime")) continue;
        const toml = try std.fmt.allocPrint(a, "kotlin-klio/{s}/klio.toml", .{e.name});
        std.Io.Dir.cwd().access(io, toml, .{}) catch continue;
        try dirs.append(a, try std.fmt.allocPrint(a, "kotlin-klio/{s}", .{e.name}));
    }
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return dirs.items;
}

/// Builds and installs every shipped pack into the home `env` names, the
/// artifacts under `<home_dir>/.build`, retrying the ones whose dependencies
/// are not installed yet until a round installs nothing more.
pub fn installPacks(a: Allocator, io: std.Io, env: *const Environ.Map, klio_bin: []const u8, home_dir: []const u8) !void {
    const build_dir = try std.fmt.allocPrint(a, "{s}/.build", .{home_dir});
    try std.Io.Dir.cwd().createDirPath(io, build_dir);
    var remaining = try packDirs(a, io);
    while (remaining.len != 0) {
        var next: std.ArrayList([]const u8) = .empty;
        var last_log: []const u8 = "";
        for (remaining) |d| {
            const out = try std.fmt.allocPrint(a, "{s}/{s}.klio-pack", .{ build_dir, std.fs.path.basename(d) });
            const b = try runKlio(a, env, &.{ klio_bin, "pack", "build", d, "--out", out }, .{ .timeout_ms = 900_000 });
            if (b.exitedZero()) {
                const i = try runKlio(a, env, &.{ klio_bin, "pack", "install", out }, .{ .timeout_ms = 120_000 });
                if (i.exitedZero()) continue;
                last_log = i.stderr;
            } else last_log = b.stderr;
            try next.append(a, d);
        }
        if (next.items.len == remaining.len) {
            for (next.items) |d| std.debug.print("klio-test-home: pack {s} did not build or install\n", .{d});
            std.debug.print("{s}\n", .{last_log[0..@min(last_log.len, 2000)]});
            return error.PackInstallFailed;
        }
        remaining = next.items;
    }
}

/// The arguments a `// Run with: klio run ...` header names, the file aside.
pub fn runArgs(a: Allocator, src: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 12) break;
        const at = std.mem.find(u8, line, "Run with: klio run") orelse continue;
        var toks = std.mem.tokenizeAny(u8, line[at + "Run with: klio run".len ..], " \t\r");
        while (toks.next()) |t| {
            if (std.mem.endsWith(u8, t, ".kt")) continue;
            try out.append(a, t);
        }
        break;
    }
    return out.items;
}

/// How a program's base is built: from the base image the home caches (the
/// default), or analyzed and lowered afresh (`KLIO_SEMA_IMAGE=0`).
pub const Mode = enum { image, cold };

pub const RunOptions = struct {
    mode: Mode = .image,
    /// Extra `klio run` arguments, before the files.
    args: []const []const u8 = &.{},
    /// Extra environment, as name/value pairs.
    env: []const [2][]const u8 = &.{},
    timeout_ms: i64 = RUN_TIMEOUT_MS,
};

/// A program run's verdict: its stdout when it exited 0, else what it
/// reported on stderr (its exit status when stderr is empty).
pub const Result = union(enum) {
    ok: []u8,
    err: []u8,
};

/// Runs `files` as one program with `klio run --virtual-time`.
pub fn run(a: Allocator, files: []const []const u8, opts: RunOptions) !Result {
    var env = try baseEnv(a);
    if (opts.mode == .cold) try env.put("KLIO_SEMA_IMAGE", "0");
    if (files.len != 0) try putWindowInput(a, &env, files[0]);
    for (opts.env) |kv| try env.put(kv[0], kv[1]);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ bin(), "run", "--virtual-time" });
    try argv.appendSlice(a, opts.args);
    try argv.appendSlice(a, files);
    const r = try runKlio(a, &env, argv.items, .{ .timeout_ms = opts.timeout_ms });
    if (r.exitedZero()) return .{ .ok = try linesOf(a, r.stdout) };
    if (r.term == .exited and r.term.exited == 124)
        return .{ .err = try std.fmt.allocPrint(a, "timed out after {d} ms\n{s}", .{ opts.timeout_ms, r.stderr }) };
    if (std.mem.trim(u8, r.stderr, " \t\r\n").len == 0)
        return .{ .err = try std.fmt.allocPrint(a, "klio exited with {any} and no message", .{r.term}) };
    return .{ .err = r.stderr };
}

pub fn runFile(a: Allocator, file: []const u8) !Result {
    return run(a, &.{file}, .{});
}

pub fn runFiles(a: Allocator, files: []const []const u8) !Result {
    return run(a, files, .{});
}

/// Stdout as the suites' expectations read it: every line newline-terminated,
/// a trailing partial line included.
pub fn linesOf(a: Allocator, stdout: []const u8) ![]u8 {
    if (stdout.len == 0 or stdout[stdout.len - 1] == '\n') return a.dupe(u8, stdout);
    return std.fmt.allocPrint(a, "{s}\n", .{stdout});
}

/// Every `.kt` file directly under `dir`, sorted; none when `dir` is missing.
pub fn collectKt(a: Allocator, io: std.Io, dir: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".kt")) continue;
        try out.append(a, try std.fs.path.join(a, &.{ dir, entry.name }));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

/// Writes `src` to `<dir>/<name>` and returns the path.
pub fn writeProgram(a: Allocator, dir: []const u8, name: []const u8, src: []const u8) ![]const u8 {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
    return path;
}

test "runArgs takes the header's flags and drops the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try runArgs(arena.allocator(), "// demo\n// Run with: klio run --feature kotlinx.serialization/json demo.kt\nfun main() {}\n");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("--feature", got[0]);
    try std.testing.expectEqualStrings("kotlinx.serialization/json", got[1]);
    try std.testing.expectEqual(@as(usize, 0), (try runArgs(arena.allocator(), "fun main() {}\n")).len);
}

test "a program with an .input beside it runs with that script as its window input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "windowed.kt", .data = "fun main() {}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "windowed.input", .data = "100ms press 10 10\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain.kt", .data = "fun main() {}\n" });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var env = Environ.Map.init(a);
    try putWindowInput(a, &env, try std.fmt.allocPrint(a, "{s}/plain.kt", .{dir}));
    try std.testing.expect(env.get("KLIO_WIN_INPUT") == null);

    try putWindowInput(a, &env, try std.fmt.allocPrint(a, "{s}/windowed.kt", .{dir}));
    const script = env.get("KLIO_WIN_INPUT") orelse return error.TestExpectedWindowInput;
    try std.testing.expect(std.fs.path.isAbsolute(script));
    try std.testing.expect(std.mem.endsWith(u8, script, "/windowed.input"));
}

test "linesOf terminates a partial line and keeps empty lines between" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a\nb\n", try linesOf(a, "a\nb\n"));
    try std.testing.expectEqualStrings("a\nb\n", try linesOf(a, "a\nb"));
    try std.testing.expectEqualStrings("a\n\nb\n", try linesOf(a, "a\n\nb\n"));
    try std.testing.expectEqualStrings("", try linesOf(a, ""));
    try std.testing.expectEqualStrings("\n", try linesOf(a, "\n"));
    try std.testing.expectEqualStrings("\n\n", try linesOf(a, "\n\n"));
}
