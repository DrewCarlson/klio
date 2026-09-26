//! The `klio` commands as a user runs them, through the binary
//! (`KLIO_ITEST_BIN`) against a scratch data home: what `run` and `test`
//! report before a program runs, the packs they load, the switches they
//! honor, and the commands built on the same pipeline.

const std = @import("std");
const runtime = @import("runtime");

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_ROOT = "/tmp/klio_itest_cli_commands";
const HOME = TMP_ROOT ++ "/home";

const RunResult = struct { code: u32, stdout: []u8, stderr: []u8 };

const Ctx = struct {
    a: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    env: std.process.Environ.Map,
};

var ctx_state: ?Ctx = null;
var threaded_state: ?std.Io.Threaded = null;

/// One scratch home for the suite, so the base image bakes once.
fn ctx() !*Ctx {
    if (ctx_state) |*c| return c;
    const a = file_arena.allocator();
    threaded_state = .init(a, .{});
    const io = threaded_state.?.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, TMP_ROOT) catch {};
    try cwd.createDirPath(io, HOME);
    var env = std.process.Environ.Map.init(a);
    runtime.procEnvPutAllInto(a, &env);
    try env.put("HOME", HOME);
    try env.put("KLIO_HOME", HOME);
    for ([_][]const u8{ "KLIO_SEMA_IMAGE", "KLIO_TRACE_RUN", "KLIO_PACK_DIAG" }) |k| {
        _ = env.array_hash_map.swapRemove(k);
    }
    const rel = env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
    const bin = cwd.realPathFileAlloc(io, rel, a) catch rel;
    ctx_state = .{ .a = a, .io = io, .bin = bin, .env = env };
    return &ctx_state.?;
}

fn klio(c: *Ctx, cwd: ?[]const u8, args: []const []const u8) !RunResult {
    return klioEnv(c, &c.env, cwd, args);
}

fn klioEnv(c: *Ctx, env: *std.process.Environ.Map, cwd: ?[]const u8, args: []const []const u8) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(c.a, c.bin);
    try argv.appendSlice(c.a, args);
    const r = std.process.run(c.a, c.io, .{
        .argv = argv.items,
        .environ_map = env,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
    }) catch |e| {
        std.debug.print("cli_commands: spawn {s} failed: {s}\n", .{ c.bin, @errorName(e) });
        return error.SpawnFailed;
    };
    const code: u32 = switch (r.term) {
        .exited => |x| x,
        else => 0xffff,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

fn write(c: *Ctx, rel: []const u8, text: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(c.a, "{s}/{s}", .{ TMP_ROOT, rel });
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(c.io, d);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = text });
    return path;
}

fn expectCode(r: RunResult, want: u32) !void {
    if (r.code == want) return;
    std.debug.print("exit {d}, wanted {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ r.code, want, r.stdout, r.stderr });
    return error.TestUnexpectedResult;
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, hay, needle) != null) return;
    std.debug.print("missing {s} in:\n{s}\n", .{ needle, hay });
    return error.TestUnexpectedResult;
}

test "a program that does not parse is reported and exits 1" {
    const c = try ctx();
    const path = try write(c, "bad_parse.kt", "fun main() {\n    println(\"hi\"\n}\n");
    const r = try klio(c, null, &.{ "run", path });
    try expectCode(r, 1);
    try std.testing.expectEqualStrings("", r.stdout);
    const want = try std.fmt.allocPrint(c.a, "{s}:3:1: error: expected `)` [E0001]\n}}\n^\n", .{path});
    try std.testing.expectEqualStrings(want, r.stderr);
}

test "a program that does not lex is reported and exits 1" {
    const c = try ctx();
    const path = try write(c, "bad_lex.kt", "fun main() {\n    val s = \"abc\n}\n");
    const r = try klio(c, null, &.{ "run", path });
    try expectCode(r, 1);
    try expectContains(r.stderr, "bad_lex.kt:2:17: error: newline in regular string literal");
}

test "klio test reports a source that does not parse" {
    const c = try ctx();
    const path = try write(c, "tests_bad/BadTest.kt", "class BadTest {\n    fun x( {\n}\n");
    const r = try klio(c, null, &.{ "test", path });
    try expectCode(r, 1);
    try expectContains(r.stderr, "BadTest.kt:2:");
    try expectContains(r.stderr, "error:");
}

test "klio test fails a source whose import names nothing" {
    const c = try ctx();
    const path = try write(c, "tests_import/ImportTest.kt", "import kotlin.collections.nothingHere\n\nclass ImportTest {\n    fun ok() {}\n}\n");
    const r = try klio(c, null, &.{ "test", path });
    try expectCode(r, 1);
    try expectContains(r.stderr, "ImportTest.kt:1:1: error: unresolved import `kotlin.collections.nothingHere`");
}

test "a program that cannot be read is named" {
    const c = try ctx();
    const r = try klio(c, null, &.{ "run", TMP_ROOT ++ "/missing.kt" });
    try expectCode(r, 1);
    try std.testing.expectEqualStrings("error: cannot read " ++ TMP_ROOT ++ "/missing.kt: ReadFailed\n", r.stderr);
}

test "klio test on a root with no sources says so" {
    const c = try ctx();
    const r = try klio(c, null, &.{ "test", TMP_ROOT ++ "/no_such_dir" });
    try expectCode(r, 1);
    try std.testing.expectEqualStrings("error: no `.kt` files found\n", r.stderr);
}

/// A library project, `demo.lib`, under `TMP_ROOT/demolib`, its pack built
/// at `target/packs/demo.lib.klio-pack` there. Answers the project's
/// directory.
fn demoLib(c: *Ctx) ![]const u8 {
    _ = try write(c, "demolib/klio.toml",
        \\[library]
        \\id = "demo.lib"
        \\version = "0.1.0"
        \\abi = 1
        \\
        \\[[source]]
        \\root = "src"
        \\
        \\[deps]
        \\stdlib = "*"
        \\
    );
    _ = try write(c, "demolib/src/demo/lib/Lib.kt",
        \\package demo.lib
        \\
        \\fun greet(who: String): String = "hello, $who"
        \\
        \\class Counter { var n = 0; fun bump(): Int { n += 1; return n } }
        \\
    );
    _ = try write(c, "demolib/src/demo/lib/Main.kt",
        \\package demo.lib
        \\
        \\fun main() {
        \\    println(greet("lib"))
        \\    val c = Counter()
        \\    c.bump()
        \\    println(c.bump())
        \\}
        \\
    );
    const dir = TMP_ROOT ++ "/demolib";
    try expectCode(try klio(c, dir, &.{ "pack", "build", "." }), 0);
    return dir;
}

test "a library runs its own sources beside its installed pack" {
    const c = try ctx();
    const dir = try demoLib(c);
    try expectCode(try klio(c, dir, &.{ "pack", "install", "target/packs/demo.lib.klio-pack" }), 0);
    // The installed pack declares everything the sources do; loading it
    // beside them would make every name ambiguous.
    const r = try klio(c, dir, &.{ "run", "src/demo/lib/Main.kt", "src/demo/lib/Lib.kt" });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("hello, lib\n2\n", r.stdout);
    // A consumer outside the project resolves against the pack.
    const user = try write(c, "demolib_user.kt",
        \\import demo.lib.greet
        \\fun main() { println(greet("user")) }
        \\
    );
    const u = try klio(c, null, &.{ "run", user });
    try expectCode(u, 0);
    try std.testing.expectEqualStrings("hello, user\n", u.stdout);
}

/// Builds and installs the pack of the project at `dir` (under TMP_ROOT) from
/// its klio.toml and one source file.
fn installPack(c: *Ctx, dir: []const u8, id: []const u8, manifest_tail: []const u8, src_rel: []const u8, src: []const u8) !void {
    _ = try write(c, try std.fmt.allocPrint(c.a, "{s}/klio.toml", .{dir}), try std.fmt.allocPrint(c.a,
        \\[library]
        \\id = "{s}"
        \\version = "0.1.0"
        \\abi = 1
        \\
        \\[[source]]
        \\root = "src"
        \\
        \\{s}
    , .{ id, manifest_tail }));
    _ = try write(c, try std.fmt.allocPrint(c.a, "{s}/src/{s}", .{ dir, src_rel }), src);
    const abs = try std.fmt.allocPrint(c.a, "{s}/{s}", .{ TMP_ROOT, dir });
    try expectCode(try klio(c, abs, &.{ "pack", "build", "." }), 0);
    const built = try std.fmt.allocPrint(c.a, "target/packs/{s}.klio-pack", .{id});
    try expectCode(try klio(c, abs, &.{ "pack", "install", built }), 0);
}

test "a pack's declared dependency loads with it, reached by a qualified name" {
    const c = try ctx();
    try installPack(c, "depbase", "demo.depbase", "[deps]\nstdlib = \"*\"\n", "demo/depbase/Base.kt",
        \\package demo.depbase
        \\
        \\class Event(val x: Float) { override fun toString() = "Event($x)" }
        \\
    );
    // The top pack names the dependency only by qualified name, with no import.
    try installPack(c, "deptop", "demo.deptop", "[deps]\nstdlib = \"*\"\n\"demo.depbase\" = \"*\"\n", "demo/deptop/Top.kt",
        \\package demo.deptop
        \\
        \\fun top(): String = demo.depbase.Event(1f).toString()
        \\
    );
    // The program imports the top pack alone and never names the dependency.
    const path = try write(c, "use_deptop.kt",
        \\import demo.deptop.top
        \\
        \\fun main() {
        \\    println(top())
        \\}
        \\
    );
    const r = try klio(c, null, &.{ "run", path });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("Event(1.0)\n", r.stdout);
}

test "a dependency of an unrequested feature does not load" {
    const c = try ctx();
    try installPack(c, "featdep", "demo.featdep", "[deps]\nstdlib = \"*\"\n", "demo/featdep/Dep.kt",
        \\package demo.featdep
        \\
        \\fun dep(): String = "dep"
        \\
    );
    _ = try write(c, "feathost/src/demo/feathost/Extra.kt",
        \\package demo.feathost
        \\
        \\fun extra(): String = demo.featdep.dep()
        \\
    );
    try installPack(c, "feathost", "demo.feathost",
        \\[features]
        \\default = ["core"]
        \\core = { sources = ["src/demo/feathost/Core.kt"] }
        \\extra = { sources = ["src/demo/feathost/Extra.kt"], requires = ["core"], deps = ["demo.featdep"] }
        \\
        \\[deps]
        \\stdlib = "*"
        \\
    , "demo/feathost/Core.kt",
        \\package demo.feathost
        \\
        \\fun core(): String = "core"
        \\
    );
    var env = try c.env.clone(c.a);
    try env.put("KLIO_PACK_TRACE", "1");
    // Without the feature its dependency stays out.
    const core_only = try write(c, "use_feathost_core.kt",
        \\import demo.feathost.core
        \\
        \\fun main() { println(core()) }
        \\
    );
    const off = try klioEnv(c, &env, null, &.{ "run", core_only });
    try expectCode(off, 0);
    try std.testing.expectEqualStrings("core\n", off.stdout);
    try expectContains(off.stderr, "[pack-load] demo.feathost ");
    if (std.mem.find(u8, off.stderr, "[pack-load] demo.featdep ") != null) {
        std.debug.print("demo.featdep loaded without its feature:\n{s}\n", .{off.stderr});
        return error.TestUnexpectedResult;
    }
    // With it, the dependency loads and the feature's qualified name into it
    // resolves.
    const with_extra = try write(c, "use_feathost_extra.kt",
        \\import demo.feathost.core
        \\import demo.feathost.extra
        \\
        \\fun main() { println(core() + " " + extra()) }
        \\
    );
    const on = try klioEnv(c, &env, null, &.{ "run", "--feature", "demo.feathost/extra", with_extra });
    try expectCode(on, 0);
    try std.testing.expectEqualStrings("core dep\n", on.stdout);
    try expectContains(on.stderr, "[pack-load] demo.featdep ");
}

test "a pack whose sources do not resolve does not build" {
    const c = try ctx();
    _ = try write(c, "badlib/klio.toml",
        \\[library]
        \\id = "demo.bad"
        \\version = "0.1.0"
        \\abi = 1
        \\
        \\[[source]]
        \\root = "src"
        \\
        \\[deps]
        \\stdlib = "*"
        \\
    );
    _ = try write(c, "badlib/src/demo/bad/Bad.kt",
        \\package demo.bad
        \\
        \\class Pos(val x: Int) {
        \\    override fun equals(other: Any?): Boolean {
        \\        if (javaClass != other?.javaClass) return false
        \\        return x == (other as Pos).x
        \\    }
        \\    override fun hashCode(): Int = x
        \\}
        \\
        \\fun greet(): String = "hi " + MISSING_NAME
        \\
        \\fun ok(): String = "ok"
        \\
    );
    const r = try klio(c, TMP_ROOT ++ "/badlib", &.{ "pack", "build", "." });
    try expectCode(r, 2);
    try expectContains(r.stderr, "src/demo/bad/Bad.kt:5:13: error: unresolved reference `javaClass`");
    try expectContains(r.stderr, "src/demo/bad/Bad.kt:11:31: error: unresolved reference `MISSING_NAME`");
    try expectContains(r.stderr, "pack build: ");
    try expectContains(r.stderr, "errors in demo.bad's sources");
}

test "an installed pack that does not decode is reported" {
    const c = try ctx();
    const pack = HOME ++ "/.klio/packs/demo.broken-0.1.0.klio-pack";
    try std.Io.Dir.cwd().createDirPath(c.io, HOME ++ "/.klio/packs");
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = pack, .data = "not a pack" });
    defer std.Io.Dir.cwd().deleteFile(c.io, pack) catch {};
    const path = try write(c, "use_broken.kt", "import demo.broken.thing\nfun main() { println(\"x\") }\n");
    const r = try klio(c, null, &.{ "run", path });
    try expectContains(r.stderr, "warning: skipping installed pack " ++ pack);
    try expectContains(r.stderr, "imports of `demo.broken` will not resolve from it");
}

test "--lazy-bodies is accepted and changes nothing" {
    const c = try ctx();
    const path = try write(c, "hello.kt", "fun main() { println(\"hello\") }\n");
    const r = try klio(c, null, &.{ "run", "--lazy-bodies", path });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("hello\n", r.stdout);
}

test "KLIO_TRACE_RUN and KLIO_RUN_STATS report the run's steps" {
    const c = try ctx();
    const path = try write(c, "traced.kt", "fun main() { println(\"traced\") }\n");
    var env = try c.env.clone(c.a);
    try env.put("KLIO_TRACE_RUN", "1");
    try env.put("KLIO_RUN_STATS", "1");
    const r = try klioEnv(c, &env, null, &.{ "run", path });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("traced\n", r.stdout);
    try expectContains(r.stderr, "[run]   main ");
    try expectContains(r.stderr, "[run] startup ");
    try expectContains(r.stderr, "[run-stats] boot_ms=");
}

test "a main that does not return Unit is not run" {
    const c = try ctx();
    const path = try write(c, "main_any.kt",
        \\fun main() = run {
        \\    println("ran")
        \\    1
        \\}
        \\
    );
    const r = try klio(c, null, &.{ "run", path });
    // kotlinc 2.4.20 compiles it and the JVM launcher refuses it: "Error:
    // Main method not found in class Main_anyKt". klio names the file.
    try expectCode(r, 1);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expectEqualStrings("error: no `main` function in main_any.kt\n", r.stderr);
}

test "a suspend main is the entry point" {
    const c = try ctx();
    const path = try write(c, "main_suspend.kt",
        \\suspend fun main() {
        \\    println("suspended")
        \\}
        \\
    );
    const r = try klio(c, null, &.{ "run", path });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("suspended\n", r.stdout);
}

test "an uncaught throwable prints its class, message, frames and causes" {
    const c = try ctx();
    const path = try write(c, "uncaught.kt",
        \\class Boom(msg: String, cause: Throwable? = null) : RuntimeException(msg, cause)
        \\// The frames below name these lines.
        \\fun inner(n: Int): Int {
        \\    if (n > 1) throw IllegalStateException("inner failed at $n")
        \\    return inner(n + 1)
        \\}
        \\fun outer() {
        \\    try { inner(0) } catch (e: IllegalStateException) { throw Boom("outer wrapped", e) }
        \\}
        \\fun main(args: Array<String>) {
        \\    println("start")
        \\    if (args.size == 0) outer()
        \\}
        \\
    );
    const r = try klio(c, null, &.{ "run", path });
    try expectCode(r, 1);
    try std.testing.expectEqualStrings("start\n", r.stdout);
    // kotlinc 2.4.20 prints these lines but for the names: the JVM's
    // java.lang.IllegalStateException for the cause, and each frame's
    // function in the file's facade class, `UncaughtKt.outer`.
    try std.testing.expectEqualStrings("Exception in thread \"main\" Boom: outer wrapped\n" ++
        "\tat outer(uncaught.kt:8)\n" ++
        "\tat main(uncaught.kt:12)\n" ++
        "Caused by: kotlin.IllegalStateException: inner failed at 2\n" ++
        "\tat inner(uncaught.kt:4)\n" ++
        "\tat inner(uncaught.kt:5)\n" ++
        "\tat inner(uncaught.kt:5)\n" ++
        "\t... 2 more\n", r.stderr);
}

test "an uncaught throwable on a thread prints under the thread's name and the run carries on" {
    const c = try ctx();
    const path = try write(c, "thread_uncaught.kt",
        \\import kotlin.concurrent.thread
        \\fun fail(): Nothing = throw IllegalStateException("boom")
        \\fun main() {
        \\    thread { println(Thread.currentThread().name) }.join()
        \\    val t = thread { fail() }
        \\    t.join()
        \\    println(t.name + " " + Thread.currentThread().name)
        \\}
        \\
    );
    const r = try klio(c, null, &.{ "run", path });
    // kotlinc 2.4.20: exit 0, the same stdout, and the same stderr lines but
    // for the names (java.lang.IllegalStateException, and the frames'
    // `Thread_uncaughtKt.fail` and `Thread_uncaughtKt.main$lambda$1`) and the
    // frame of the JVM's own `Thread.run` below the lambda.
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("Thread-0\nThread-1 main\n", r.stdout);
    try std.testing.expectEqualStrings("Exception in thread \"Thread-1\" kotlin.IllegalStateException: boom\n" ++
        "\tat fail(thread_uncaught.kt:2)\n" ++
        "\tat main.<anonymous>(thread_uncaught.kt:5)\n", r.stderr);
}

test "an uncaught throwable's header is its toString" {
    const c = try ctx();
    const path = try write(c, "custom_to_string.kt",
        \\class Custom(msg: String) : Exception(msg) {
        \\    override fun toString(): String = "Custom<" + message + ">"
        \\}
        \\fun main() { throw Custom("boom") }
        \\
    );
    const r = try klio(c, null, &.{ "run", path });
    try expectCode(r, 1);
    // kotlinc 2.4.20 prints the same header, and names the frame
    // `Custom_to_stringKt.main`, under which it adds the frame of the
    // synthetic `main(String[])` the JVM enters by.
    try std.testing.expectEqualStrings("Exception in thread \"main\" Custom<boom>\n" ++
        "\tat main(custom_to_string.kt:4)\n", r.stderr);
}

test "KLIO_FN_PROF names the program's functions" {
    const c = try ctx();
    const path = try write(c, "profiled.kt",
        \\fun fib(n: Int): Int = if (n < 2) n else fib(n - 1) + fib(n - 2)
        \\fun main() { println(fib(27)) }
        \\
    );
    var env = try c.env.clone(c.a);
    try env.put("KLIO_FN_PROF", "100");
    const r = try klioEnv(c, &env, null, &.{ "run", path });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("196418\n", r.stdout);
    try expectContains(r.stderr, "[fn-prof]");
    try expectContains(r.stderr, " fib\n");
}

test "dump-ir prints the program's functions as they lowered" {
    const c = try ctx();
    const path = try write(c, "dumped.kt", "fun twice(x: Int): Int = x * 2\nfun main() { println(twice(21)) }\n");
    const r = try klio(c, null, &.{ "dump-ir", path });
    try expectCode(r, 0);
    try expectContains(r.stdout, "  twice(x)   [kind=plain");
    try expectContains(r.stdout, "  main()   [kind=plain");
    try expectContains(r.stdout, "<- CallStatic twice#");
    try expectContains(r.stdout, "module rollup: 2 functions,");
    // A base function's body comes out of the base image when it is named.
    const f = try klio(c, null, &.{ "dump-ir", path, "--func", "kotlin.collections.listOf" });
    try expectCode(f, 0);
    try expectContains(f.stdout, "  listOf()   [kind=plain");
    try expectContains(f.stdout, "  b0:\n");
}

test "dump-ir reports what does not resolve and exits 1" {
    const c = try ctx();
    const path = try write(c, "dump_unresolved.kt", "fun main() { notDeclaredAnywhere() }\n");
    const r = try klio(c, null, &.{ "dump-ir", path });
    try expectCode(r, 1);
    try expectContains(r.stderr, "dump_unresolved.kt:1:14: error: unresolved reference `notDeclaredAnywhere`");
    try expectContains(r.stdout, "module rollup:");
}

test "transpile-dump prints the program's bytecode streams" {
    const c = try ctx();
    const path = try write(c, "streams.kt", "fun twice(x: Int): Int = x * 2\nfun main() { println(twice(21)) }\n");
    const r = try klio(c, null, &.{ "transpile-dump", path });
    try expectCode(r, 0);
    try expectContains(r.stdout, "fn twice (fid ");
    try expectContains(r.stdout, "fn main (fid ");
    try expectContains(r.stdout, " block b0:\n");
}

/// A home with nothing in it, and a working directory outside the checkout.
fn emptyEnv(c: *Ctx, name: []const u8) !struct { env: std.process.Environ.Map, cwd: []const u8 } {
    const dir = try std.fmt.allocPrint(c.a, "{s}/{s}", .{ TMP_ROOT, name });
    std.Io.Dir.cwd().deleteTree(c.io, dir) catch {};
    const home = try std.fmt.allocPrint(c.a, "{s}/home", .{dir});
    const cwd = try std.fmt.allocPrint(c.a, "{s}/cwd", .{dir});
    try std.Io.Dir.cwd().createDirPath(c.io, home);
    try std.Io.Dir.cwd().createDirPath(c.io, cwd);
    var env = try c.env.clone(c.a);
    try env.put("HOME", home);
    try env.put("KLIO_HOME", home);
    return .{ .env = env, .cwd = cwd };
}

test "bake-image writes a base run-image runs a program over with no home" {
    const c = try ctx();
    const program = try write(c, "imaged.kt",
        \\fun main(args: Array<String>) {
        \\    println("n=" + args.size)
        \\    for (a in args) println("arg: " + a)
        \\    println(listOf(3, 1, 2).sorted())
        \\}
        \\
    );
    const image = TMP_ROOT ++ "/imaged.klio-image";
    const b = try klio(c, null, &.{ "bake-image", program, "-o", image });
    try expectCode(b, 0);
    try expectContains(b.stdout, "wrote " ++ image ++ " (");
    var empty = try emptyEnv(c, "run_image");
    const r = try klioEnv(c, &empty.env, empty.cwd, &.{ "run-image", image, program, "one", "two three" });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("n=2\narg: one\narg: two three\n[1, 2, 3]\n", r.stdout);
    // Nothing was read from, or written to, the empty home.
    var home = try std.Io.Dir.cwd().openDir(c.io, empty.env.get("HOME").?, .{ .iterate = true });
    defer home.close(c.io);
    var it = home.iterate();
    try std.testing.expect((try it.next(c.io)) == null);
}

test "bake-image carries the packs the program imports" {
    const c = try ctx();
    const program = try write(c, "imaged_pack.kt", "import demo.lib.greet\nfun main() { println(greet(\"image\")) }\n");
    const dir = try demoLib(c);
    try expectCode(try klio(c, dir, &.{ "pack", "install", "target/packs/demo.lib.klio-pack" }), 0);
    const image = TMP_ROOT ++ "/imaged_pack.klio-image";
    try expectCode(try klio(c, null, &.{ "bake-image", program, "-o", image }), 0);
    var empty = try emptyEnv(c, "run_image_pack");
    const r = try klioEnv(c, &empty.env, empty.cwd, &.{ "run-image", image, program });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("hello, image\n", r.stdout);
}

test "bake-image does not ship a cached base image of another base" {
    const c = try ctx();
    var empty = try emptyEnv(c, "stale_cache");
    try empty.env.put("KLIO_STDLIB_IMAGE_SHIPPED", "0");
    const dir = try demoLib(c);
    const pack = try std.fmt.allocPrint(c.a, "{s}/target/packs/demo.lib.klio-pack", .{dir});
    try expectCode(try klioEnv(c, &empty.env, empty.cwd, &.{ "pack", "install", pack }), 0);
    const plain = try write(c, "stale_plain.kt", "fun main() { println(\"plain\") }\n");
    const with_lib = try write(c, "stale_lib.kt", "import demo.lib.greet\nfun main() { println(greet(\"lib\")) }\n");
    const cache = try std.fmt.allocPrint(c.a, "{s}/.klio/cache", .{empty.env.get("HOME").?});
    try expectCode(try klioEnv(c, &empty.env, empty.cwd, &.{ "bake", plain }), 0);
    const plain_image = try std.fmt.allocPrint(c.a, "{s}/{s}", .{ cache, try onlyFile(c, cache) });
    try expectCode(try klioEnv(c, &empty.env, empty.cwd, &.{ "bake", with_lib }), 0);
    // The plain base's cache entry now holds the image of the base with
    // the pack: a well-formed image of another base.
    var dir_it = try std.Io.Dir.cwd().openDir(c.io, cache, .{ .iterate = true });
    defer dir_it.close(c.io);
    var it = dir_it.iterate();
    var other: ?[]const u8 = null;
    while (try it.next(c.io)) |e| {
        const path = try std.fmt.allocPrint(c.a, "{s}/{s}", .{ cache, e.name });
        if (!std.mem.eql(u8, path, plain_image)) other = path;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, other orelse return error.TestUnexpectedResult, c.a, .unlimited);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = plain_image, .data = bytes });
    const image = TMP_ROOT ++ "/stale_plain.klio-image";
    try expectCode(try klioEnv(c, &empty.env, empty.cwd, &.{ "bake-image", plain, "-o", image }), 0);
    var fresh = try emptyEnv(c, "stale_cache_run");
    const r = try klioEnv(c, &fresh.env, fresh.cwd, &.{ "run-image", image, plain });
    try expectCode(r, 0);
    try std.testing.expectEqualStrings("plain\n", r.stdout);
}

test "run-image refuses a file that is not an image" {
    const c = try ctx();
    const program = try write(c, "not_an_image.kt", "fun main() {}\n");
    const r = try klio(c, null, &.{ "run-image", program, program });
    try expectCode(r, 1);
    try std.testing.expectEqualStrings("error: base image rejected (not a sema image); rebake it with this klio\n", r.stderr);
}

test "bake-image --stdlib-cache bakes the image a run without packs looks up" {
    const c = try ctx();
    const dir = TMP_ROOT ++ "/stdlib_cache";
    std.Io.Dir.cwd().deleteTree(c.io, dir) catch {};
    try expectCode(try klio(c, null, &.{ "bake-image", "--stdlib-cache", dir }), 0);
    const shipped = try onlyFile(c, dir);
    try std.testing.expect(std.mem.startsWith(u8, shipped, "sema-base-"));
    // `klio bake` over a program without packs caches the image a run of it
    // reads, under the same name.
    var empty = try emptyEnv(c, "bake_home");
    // Not the image a build installed beside the binary: the bake's own.
    try empty.env.put("KLIO_STDLIB_IMAGE_SHIPPED", "0");
    const program = try write(c, "baked.kt", "fun main() { println(\"baked\") }\n");
    const b = try klioEnv(c, &empty.env, empty.cwd, &.{ "bake", program });
    try expectCode(b, 0);
    try std.testing.expectEqualStrings("stdlib image ready\n", b.stdout);
    const cache = try std.fmt.allocPrint(c.a, "{s}/.klio/cache", .{empty.env.get("HOME").?});
    try std.testing.expectEqualStrings(shipped, try onlyFile(c, cache));
}

/// The name of the one file in `dir`.
fn onlyFile(c: *Ctx, dir_path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(c.io, dir_path, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    const first = (try it.next(c.io)) orelse return error.TestUnexpectedResult;
    const name = try c.a.dupe(u8, first.name);
    if ((try it.next(c.io)) != null) return error.TestUnexpectedResult;
    return name;
}
