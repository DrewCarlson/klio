//! Reified inline `Json` extension gate: a real `klio` child process runs
//! `Json.encodeToString` / `Json.decodeFromString` through the installed
//! kotlinx-serialization pack (`klio pack build` + `pack install` into a
//! scratch HOME, then `klio run --feature kotlinx.serialization/json`).
//!
//! Pins the two call shapes the inline-splice machinery must cover: a
//! plain program body, and a hook-style lambda with no expected type —
//! the shape where the call head `Json` is a companioned class name and
//! the splice site has no type context. Expected outputs are
//! kotlinc-verified (kotlinc-jvm 2.3.21 + the kotlinx-serialization
//! compiler plugin); the fixtures live here rather than the parity corpus
//! because the in-process parity harness folds in only the coroutines /
//! atomicfu / io packs.

const std = @import("std");

const KLIO_BIN = "zig-out/bin/klio";

fn envWithHome(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    const data = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/environ", allocator, .unlimited) catch
        return map;
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
    }
    try map.put("HOME", home);
    return map;
}

fn runKlio(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
) !struct { ok: bool, stdout: []u8, stderr: []u8 } {
    const r = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = env,
    }) catch |e| {
        std.debug.print("json_reified_inline: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

/// Build + install the kotlinx-serialization pack into a scratch HOME,
/// once per test-process.
fn installPacks(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, home) catch {};
    {
        const r = try runKlio(allocator, io, env, &.{ KLIO_BIN, "pack", "build", "kotlin-klio/klio-kotlinx-serialization" });
        if (!r.ok) {
            std.debug.print("json_reified_inline: pack build failed:\n{s}\n", .{r.stderr});
            return error.PackBuildFailed;
        }
    }
    {
        const r = try runKlio(allocator, io, env, &.{ KLIO_BIN, "pack", "install", "target/packs/kotlinx.serialization.klio-pack" });
        if (!r.ok) {
            std.debug.print("json_reified_inline: pack install failed:\n{s}\n", .{r.stderr});
            return error.PackInstallFailed;
        }
    }
}

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var packs_installed = false;

const SCRATCH_HOME = "/tmp/klio_itest_json_home";
const TMP_DIR = "/tmp/klio_itest_json";

fn runProgram(name: []const u8, src: []const u8, expected: []const u8) !void {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try envWithHome(a, io, SCRATCH_HOME);
    if (!packs_installed) {
        try installPacks(a, io, &env, SCRATCH_HOME);
        packs_installed = true;
    }

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try cwd.writeFile(io, .{ .sub_path = path, .data = src });

    const r = try runKlio(a, io, &env, &.{ KLIO_BIN, "run", "--feature", "kotlinx.serialization/json", path });
    if (!r.ok) {
        std.debug.print("json_reified_inline {s}: klio run failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ name, r.stdout, r.stderr });
        return error.KlioRunFailed;
    }
    try std.testing.expectEqualStrings(expected, r.stdout);
}

test "reified Json round-trip in a plain program body" {
    try runProgram("json_plain",
        \\import kotlinx.serialization.Serializable
        \\import kotlinx.serialization.json.Json
        \\
        \\@Serializable
        \\data class User(val name: String, val age: Int)
        \\
        \\fun main() {
        \\    val user = User("amy", 31)
        \\    val s = Json.encodeToString(user)
        \\    println(s)
        \\    val back = Json.decodeFromString<User>(s)
        \\    println(back)
        \\}
        \\
    ,
        \\{"name":"amy","age":31}
        \\User(name=amy, age=31)
        \\
    );
}

test "reified Json calls inside a hook-style lambda with no expected type" {
    try runProgram("json_hook",
        \\import kotlinx.serialization.Serializable
        \\import kotlinx.serialization.json.Json
        \\
        \\@Serializable
        \\data class User(val name: String, val age: Int)
        \\
        \\fun takeAny(f: () -> Any?): Any? = f()
        \\
        \\class Hooks {
        \\    private val handlers = mutableListOf<(User) -> String>()
        \\    fun on(block: (User) -> String) { handlers.add(block) }
        \\    fun fire(u: User): String {
        \\        var out = ""
        \\        for (h in handlers) out = h(u)
        \\        return out
        \\    }
        \\}
        \\
        \\fun main() {
        \\    val hooks = Hooks()
        \\    hooks.on { user ->
        \\        Json.encodeToString(user)
        \\    }
        \\    println(hooks.fire(User("amy", 31)))
        \\    hooks.on { user ->
        \\        val s = Json.encodeToString(user)
        \\        val back = Json.decodeFromString<User>(s)
        \\        back.name
        \\    }
        \\    println(hooks.fire(User("bo", 7)))
        \\    val u = User("amy", 31)
        \\    println(takeAny { Json.encodeToString(u) })
        \\    println(takeAny { Json.decodeFromString<User>("""{"name":"bo","age":7}""") })
        \\}
        \\
    ,
        \\{"name":"amy","age":31}
        \\bo
        \\{"name":"amy","age":31}
        \\User(name=bo, age=7)
        \\
    );
}
