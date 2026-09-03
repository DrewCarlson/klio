//! End-to-end ktor server gate: a real `klio` child runs `embeddedServer`
//! (through the installed packs, `klio run --feature io.ktor/server-
//! serialization`) while this test acts as the HTTP client. The server
//! blocks in the native `__kktor_serve` accept loop, so it is spawned as a
//! background process, driven over real sockets, and killed at the end.
//!
//! Asserts the routing surface the server shim adds on top of the native
//! loop: path parameters (`/users/{id}`), query parameters, request and
//! response headers, status codes, content types, raw `receiveText`, and
//! the typed JSON `receive<T>()` / `respond<T>()` content-negotiation path.

const std = @import("std");
const runtime = @import("runtime");
const net = std.Io.net;

/// The `klio` binary to spawn: `KLIO_ITEST_BIN` when set (the build run
/// step points it at the harness-optimized install), else the Debug install.
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
        std.debug.print("ktor_server: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

/// Build + install the dependency packs and the ktor pack into a scratch
/// HOME, once per test-process.
fn installPacks(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, home) catch {};
    const pack_dirs = [_][]const u8{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-ktor",
    };
    const pack_files = [_][]const u8{
        "target/packs/kotlinx.atomicfu.klio-pack",
        "target/packs/kotlinx.coroutines.klio-pack",
        "target/packs/kotlinx.io.klio-pack",
        "target/packs/kotlinx.serialization.klio-pack",
        "target/packs/io.ktor.klio-pack",
    };
    for (pack_dirs) |d| {
        const r = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "build", d });
        if (!r.ok) {
            std.debug.print("ktor_server: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.PackBuildFailed;
        }
    }
    for (pack_files) |f| {
        const r = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "install", f });
        if (!r.ok) {
            std.debug.print("ktor_server: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.PackInstallFailed;
        }
    }
}

// -------------------------------------------------------------------------
// Minimal HTTP/1.1 client over std.Io.net (the test drives the klio server).
// -------------------------------------------------------------------------

/// An ephemeral free port: bind one, read the assigned port, release it.
fn freePort(io: std.Io) !u16 {
    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();
    srv.deinit(io);
    return port;
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Poll-connect until the server accepts (or give up). A bare connect that
/// closes without a request is handled by the serve loop as a dropped read.
fn waitForServer(io: std.Io, port: u16) bool {
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const addr = net.IpAddress.parse("127.0.0.1", port) catch return false;
        if (addr.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
            return true;
        } else |_| {
            sleepMs(io, 25);
        }
    }
    return false;
}

/// Send a raw HTTP/1.1 request and return the full response bytes (the
/// server sends `Connection: close`, so read to EOF). Owned by `a`.
fn httpRequest(a: std.mem.Allocator, io: std.Io, port: u16, req: []const u8) ![]u8 {
    const addr = try net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const iw = &writer.interface;
    try iw.writeAll(req);
    try iw.flush();

    var rbuf: [32768]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const ir = &reader.interface;
    while (true) {
        ir.fillMore() catch break;
        if (ir.buffered().len >= rbuf.len) break;
    }
    return a.dupe(u8, ir.buffered());
}

fn buildRequest(
    a: std.mem.Allocator,
    method: []const u8,
    target: []const u8,
    headers: []const [2][]const u8,
    body: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n", .{ method, target });
    for (headers) |h| try out.print(a, "{s}: {s}\r\n", .{ h[0], h[1] });
    if (body.len > 0) try out.print(a, "Content-Length: {d}\r\n", .{body.len});
    try out.appendSlice(a, "Connection: close\r\n\r\n");
    try out.appendSlice(a, body);
    return out.toOwnedSlice(a);
}

fn statusOf(resp: []const u8) ?u16 {
    const line_end = std.mem.indexOf(u8, resp, "\r\n") orelse return null;
    var it = std.mem.tokenizeScalar(u8, resp[0..line_end], ' ');
    _ = it.next() orelse return null; // HTTP/1.1
    const code = it.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn bodyOf(resp: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return "";
    return resp[sep + 4 ..];
}

/// Case-insensitive header lookup over the response head.
fn headerOf(resp: []const u8, name: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse resp.len;
    var lines = std.mem.splitSequence(u8, resp[0..sep], "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

// -------------------------------------------------------------------------

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const SCRATCH_HOME = "/tmp/klio_itest_ktorsrv_home";
const TMP_DIR = "/tmp/klio_itest_ktorsrv";

const SERVER_SRC =
    \\import io.ktor.server.engine.embeddedServer
    \\import io.ktor.server.engine.klio.Klio
    \\import io.ktor.server.application.Application
    \\import io.ktor.server.routing.routing
    \\import io.ktor.server.routing.route
    \\import io.ktor.server.routing.get
    \\import io.ktor.server.routing.post
    \\import io.ktor.server.response.respondText
    \\import io.ktor.server.response.respond
    \\import io.ktor.server.request.receiveText
    \\import io.ktor.server.request.receive
    \\import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
    \\import io.ktor.server.plugins.contentnegotiation.install
    \\import io.ktor.serialization.kotlinx.json.json
    \\import io.ktor.http.HttpStatusCode
    \\import io.ktor.http.ContentType
    \\import kotlinx.serialization.Serializable
    \\
    \\@Serializable
    \\data class User(val id: Int, val name: String)
    \\
    \\fun main() {
    \\    embeddedServer(Klio, port = PORT) {
    \\        install(ContentNegotiation) { json() }
    \\        routing {
    \\            get("/users/{id}") {
    \\                val id = call.parameters["id"]
    \\                val q = call.request.queryParameters["q"]
    \\                val tag = call.request.headers["X-Tag"]
    \\                call.respondText("id=$id q=$q tag=$tag", status = HttpStatusCode.OK)
    \\            }
    \\            post("/items") {
    \\                val b = call.receiveText()
    \\                call.response.headers.append("X-Made", "yes")
    \\                call.respondText("created:$b", contentType = ContentType.Text.Plain, status = HttpStatusCode.Created)
    \\            }
    \\            post("/users") {
    \\                val u = call.receive<User>()
    \\                call.respond(HttpStatusCode.Created, User(u.id, u.name + "!"))
    \\            }
    \\            route("/api") {
    \\                route("/v1") {
    \\                    get("/ping") { call.respondText("pong") }
    \\                }
    \\            }
    \\            get("/files/{path...}") { call.respondText("f=" + (call.parameters.getAll("path")?.joinToString("/") ?: "")) }
    \\            get("/any/*/end") { call.respondText("wild") }
    \\        }
    \\    }.start(wait = true)
    \\}
;

// `start(wait = false)` returns immediately (so the following `delay` +
// `println` run) and the daemon serve loop is abandoned at the run boundary
// (so the process exits instead of hanging in `joinAllThreads`).
//
// `embeddedServer` is called at top level, not inside `runBlocking`: Kotlin
// resolves a bare call with an implicit `CoroutineScope` receiver to the
// `CoroutineScope.embeddedServer` extension, which would parent the
// application `SupervisorJob` to the enclosing `runBlocking` job and make
// `runBlocking` wait on it forever. The top-level overload parents the
// application to `GlobalScope`, which the run boundary abandons cleanly.
const ASYNC_SRC =
    \\import io.ktor.server.engine.embeddedServer
    \\import io.ktor.server.engine.klio.Klio
    \\import io.ktor.server.routing.routing
    \\import io.ktor.server.routing.get
    \\import io.ktor.server.response.respondText
    \\import kotlinx.coroutines.runBlocking
    \\import kotlinx.coroutines.delay
    \\
    \\fun main() {
    \\    val server = embeddedServer(Klio, port = PORT) {
    \\        routing { get("/hi") { call.respondText("ok") } }
    \\    }
    \\    server.start(wait = false)
    \\    runBlocking { delay(300) }
    \\    println("served and exiting")
    \\}
;

test "server: routing, params, headers, status codes, and typed JSON" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try envWithHome(a, SCRATCH_HOME);
    try installPacks(a, io, &env, SCRATCH_HOME);

    const port = try freePort(io);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch {};
    const port_str = try std.fmt.allocPrint(a, "{d}", .{port});
    const prog = try std.mem.replaceOwned(u8, a, SERVER_SRC, "PORT", port_str);
    const path = try std.fmt.allocPrint(a, "{s}/server.kt", .{TMP_DIR});
    try cwd.writeFile(io, .{ .sub_path = path, .data = prog });

    var child = std.process.spawn(io, .{
        .argv = &.{ klioBin(&env), "run", "--feature", "io.ktor/server-serialization", path },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        std.debug.print("ktor_server: spawn klio failed: {s}\n", .{@errorName(e)});
        return error.SpawnFailed;
    };
    // `kill` terminates the forever-serving child, waits, and reaps it in
    // one call (a following `wait` would double-reap), so it stands alone.
    defer child.kill(io);

    if (!waitForServer(io, port)) {
        std.debug.print("ktor_server: server never came up on port {d}\n", .{port});
        return error.ServerDidNotStart;
    }

    // GET with a path parameter, query parameter, and request header.
    {
        const req = try buildRequest(a, "GET", "/users/42?q=hi", &.{.{ "X-Tag", "abc" }}, "");
        const resp = try httpRequest(a, io, port, req);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(resp));
        try std.testing.expectEqualStrings("id=42 q=hi tag=abc", bodyOf(resp));
    }

    // POST raw text -> 201, custom response header echoed back.
    {
        const req = try buildRequest(a, "POST", "/items", &.{}, "widget");
        const resp = try httpRequest(a, io, port, req);
        try std.testing.expectEqual(@as(?u16, 201), statusOf(resp));
        try std.testing.expectEqualStrings("yes", headerOf(resp, "X-Made") orelse "");
        try std.testing.expectEqualStrings("created:widget", bodyOf(resp));
    }

    // POST typed JSON through ContentNegotiation -> 201 application/json.
    {
        const req = try buildRequest(a, "POST", "/users", &.{.{ "Content-Type", "application/json" }}, "{\"id\":7,\"name\":\"Ada\"}");
        const resp = try httpRequest(a, io, port, req);
        try std.testing.expectEqual(@as(?u16, 201), statusOf(resp));
        try std.testing.expectEqualStrings("application/json", headerOf(resp, "Content-Type") orelse "");
        try std.testing.expectEqualStrings("{\"id\":7,\"name\":\"Ada!\"}", bodyOf(resp));
    }

    // Unmatched route -> 404.
    {
        const req = try buildRequest(a, "GET", "/nope", &.{}, "");
        const resp = try httpRequest(a, io, port, req);
        try std.testing.expectEqual(@as(?u16, 404), statusOf(resp));
    }

    // Nested `route { route { get } }` -> the accumulated prefix matches.
    {
        const req = try buildRequest(a, "GET", "/api/v1/ping", &.{}, "");
        const resp = try httpRequest(a, io, port, req);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(resp));
        try std.testing.expectEqualStrings("pong", bodyOf(resp));
    }

    // Tailcard `{path...}` captures the rest of the path.
    {
        const req = try buildRequest(a, "GET", "/files/a/b/c.txt", &.{}, "");
        const resp = try httpRequest(a, io, port, req);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(resp));
        try std.testing.expectEqualStrings("f=a/b/c.txt", bodyOf(resp));
    }

    // `*` matches any single segment; a longer path does not.
    {
        const ok = try httpRequest(a, io, port, try buildRequest(a, "GET", "/any/X/end", &.{}, ""));
        try std.testing.expectEqual(@as(?u16, 200), statusOf(ok));
        try std.testing.expectEqualStrings("wild", bodyOf(ok));
        const no = try httpRequest(a, io, port, try buildRequest(a, "GET", "/any/X/Y/end", &.{}, ""));
        try std.testing.expectEqual(@as(?u16, 404), statusOf(no));
    }
}

test "server: start(wait = false) is non-blocking and the daemon serve abandons at exit" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try envWithHome(a, SCRATCH_HOME);
    try installPacks(a, io, &env, SCRATCH_HOME);

    const port = try freePort(io);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch {};
    const port_str = try std.fmt.allocPrint(a, "{d}", .{port});
    const prog = try std.mem.replaceOwned(u8, a, ASYNC_SRC, "PORT", port_str);
    const path = try std.fmt.allocPrint(a, "{s}/async_server.kt", .{TMP_DIR});
    try cwd.writeFile(io, .{ .sub_path = path, .data = prog });

    // `start(wait = false)` must return so `delay` + the final `println` run,
    // and the program must then exit on its own (the daemon serve loop notices
    // the run-boundary abandon) rather than hang in `joinAllThreads`. A
    // timeout converts a hang into a visible failure.
    const r = std.process.run(a, io, .{
        .argv = &.{ klioBin(&env), "run", "--feature", "io.ktor/server", path },
        .environ_map = &env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(120_000), .clock = .awake } },
    }) catch |e| {
        std.debug.print("ktor_server async: run failed: {s}\n", .{@errorName(e)});
        return error.RunFailed;
    };
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "served and exiting") != null);
}
