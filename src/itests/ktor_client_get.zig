//! End-to-end ktor-client gate: a real `klio` child process performs a GET
//! against a localhost HTTP server owned by this test, through the real
//! pack pipeline (`klio pack build` + `pack install` into a scratch HOME,
//! then `klio run --feature io.ktor/client`). Asserts status + body, plus
//! the typed `body<T>()` variant under `client-serialization`.
//!
//! This is the gate the ktor surface previously lacked: it exercises the
//! installed-pack feature gating, the host `__kktor_request` transport, and
//! the kotlinx-serialization typed-body path with zero network dependency
//! (the server lives in this process).

const std = @import("std");
const linux = std.os.linux;

const FIXED_BODY = "{\"name\":\"Ada\",\"age\":36,\"roles\":[\"ADMIN\",\"USER\"]}";

// -------------------------------------------------------------------------
// In-test HTTP server: accept loop on 127.0.0.1:<ephemeral>, fixed JSON
// response per request, closes each connection (the engine sends
// `Connection: close`). Mirrors the raw-syscall style of src/ktor_client.
// -------------------------------------------------------------------------

fn makeSockaddrLoopback(port: u16) linux.sockaddr.in {
    return .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
}

const Server = struct {
    fd: i32,
    port: u16,
    thread: std.Thread,
    stop: std.atomic.Value(bool),
    /// Requests served — the send-count oracle (one logical GET must
    /// issue exactly one request).
    hits: std.atomic.Value(u32),

    fn start(self: *Server) !void {
        const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return error.SocketFailed;
        const fd: i32 = @intCast(fd_rc);
        errdefer _ = linux.close(fd);
        const one: i32 = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
        var addr = makeSockaddrLoopback(0);
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
            return error.BindFailed;
        var len: u32 = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&addr), &len)) != .SUCCESS)
            return error.GetSockNameFailed;
        if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ListenFailed;
        self.fd = fd;
        self.port = std.mem.bigToNative(u16, addr.port);
        self.stop = std.atomic.Value(bool).init(false);
        self.hits = std.atomic.Value(u32).init(0);
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
    }

    fn shutdown(self: *Server) void {
        self.stop.store(true, .release);
        // Unblock the accept with a self-connection.
        const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.errno(fd_rc) == .SUCCESS) {
            const cfd: i32 = @intCast(fd_rc);
            var addr = makeSockaddrLoopback(self.port);
            _ = linux.connect(cfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
            _ = linux.close(cfd);
        }
        self.thread.join();
        _ = linux.close(self.fd);
    }

    fn serveLoop(self: *Server) void {
        while (true) {
            const rc = linux.accept(self.fd, null, null);
            if (self.stop.load(.acquire)) {
                if (linux.errno(rc) == .SUCCESS) _ = linux.close(@intCast(rc));
                return;
            }
            if (linux.errno(rc) != .SUCCESS) continue;
            const cfd: i32 = @intCast(rc);
            defer _ = linux.close(cfd);
            _ = self.hits.fetchAdd(1, .monotonic);
            // Read the request until the head is complete plus, for a
            // request carrying a Content-Length, the full body — a POST's
            // payload is echoed back so the serialize-request path is
            // asserted on the wire.
            var buf: [8192]u8 = undefined;
            var total: usize = 0;
            var head_end: ?usize = null;
            var content_len: usize = 0;
            while (total < buf.len) {
                const r = linux.read(cfd, buf[total..].ptr, buf.len - total);
                if (linux.errno(r) != .SUCCESS or r == 0) break;
                total += r;
                if (head_end == null) {
                    if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                        head_end = idx + 4;
                        content_len = parseContentLength(buf[0..idx]);
                    }
                }
                if (head_end) |he| {
                    if (total >= he + content_len) break;
                }
            }
            const is_post = std.mem.startsWith(u8, buf[0..total], "POST ");
            const body: []const u8 = blk: {
                if (is_post) {
                    if (head_end) |he| break :blk buf[he..@min(total, he + content_len)];
                }
                break :blk FIXED_BODY;
            };
            var resp_buf: [512]u8 = undefined;
            const resp = std.fmt.bufPrint(
                &resp_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ body.len, body },
            ) catch return;
            var off: usize = 0;
            while (off < resp.len) {
                const w = linux.write(cfd, resp.ptr + off, resp.len - off);
                if (linux.errno(w) != .SUCCESS or w == 0) break;
                off += w;
            }
        }
    }
};

/// `Content-Length` value in a request head, or 0 when absent.
fn parseContentLength(head: []const u8) usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) continue;
        const v = std.mem.trim(u8, line[colon + 1 ..], " ");
        return std.fmt.parseInt(usize, v, 10) catch 0;
    }
    return 0;
}

// -------------------------------------------------------------------------
// Child-process plumbing.
// -------------------------------------------------------------------------

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
        std.debug.print("ktor_client_get: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

/// Build + install the dependency packs and the ktor pack into a scratch
/// HOME, once per test-process. The pack images go to target/packs/ (the
/// CLI's default output), the installs into `<home>/.klio/packs`.
fn installPacks(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, home) catch {};
    const pack_dirs = [_][]const u8{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-ktor-client",
    };
    const pack_files = [_][]const u8{
        "target/packs/kotlinx.atomicfu.klio-pack",
        "target/packs/kotlinx.coroutines.klio-pack",
        "target/packs/kotlinx.io.klio-pack",
        "target/packs/kotlinx.serialization.klio-pack",
        "target/packs/io.ktor.klio-pack",
    };
    for (pack_dirs) |d| {
        const r = try runKlio(allocator, io, env, &.{ KLIO_BIN, "pack", "build", d });
        if (!r.ok) {
            std.debug.print("ktor_client_get: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.PackBuildFailed;
        }
    }
    for (pack_files) |f| {
        const r = try runKlio(allocator, io, env, &.{ KLIO_BIN, "pack", "install", f });
        if (!r.ok) {
            std.debug.print("ktor_client_get: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.PackInstallFailed;
        }
    }
}

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var packs_installed = false;

const SCRATCH_HOME = "/tmp/klio_itest_ktor_home";
const TMP_DIR = "/tmp/klio_itest_ktor";

fn runProgram(name: []const u8, src: []const u8, feature: []const u8, expected: []const u8) !void {
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

    var server: Server = undefined;
    try server.start();
    defer server.shutdown();

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch {};
    const port_str = try std.fmt.allocPrint(a, "{d}", .{server.port});
    const prog = try std.mem.replaceOwned(u8, a, src, "PORT", port_str);
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try cwd.writeFile(io, .{ .sub_path = path, .data = prog });

    const r = try runKlio(a, io, &env, &.{ KLIO_BIN, "run", "--feature", feature, path });
    if (!r.ok) {
        std.debug.print("ktor_client_get {s}: klio run failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ name, r.stdout, r.stderr });
        return error.KlioRunFailed;
    }
    try std.testing.expectEqualStrings(expected, r.stdout);
    // One logical GET = exactly one request on the wire.
    try std.testing.expectEqual(@as(u32, 1), server.hits.load(.monotonic));
}

test "client GET single-sends with status and body (default engine)" {
    try runProgram("get_plain",
        \\import io.ktor.client.*
        \\import io.ktor.client.request.*
        \\import io.ktor.client.statement.*
        \\
        \\suspend fun main() {
        \\    val client = HttpClient()
        \\    val resp = client.get("http://127.0.0.1:PORT/u")
        \\    println("status=" + resp.status)
        \\    println("body=" + resp.bodyAsText())
        \\    client.close()
        \\}
        \\
    , "io.ktor/client",
        \\status=200 OK
        \\body={"name":"Ada","age":36,"roles":["ADMIN","USER"]}
        \\
    );
}

test "client GET with explicit engine and followRedirects off" {
    try runProgram("get_explicit",
        \\import io.ktor.client.*
        \\import io.ktor.client.request.*
        \\import io.ktor.client.statement.*
        \\
        \\suspend fun main() {
        \\    val client = HttpClient(KlioClient) {
        \\        followRedirects = false
        \\    }
        \\    val resp = client.get("http://127.0.0.1:PORT/u")
        \\    println("status=" + resp.status)
        \\    println("body=" + resp.bodyAsText())
        \\    client.close()
        \\}
        \\
    , "io.ktor/client",
        \\status=200 OK
        \\body={"name":"Ada","age":36,"roles":["ADMIN","USER"]}
        \\
    );
}

test "typed body deserializes through client-serialization" {
    try runProgram("get_typed",
        \\import io.ktor.client.*
        \\import io.ktor.client.call.*
        \\import io.ktor.client.plugins.contentnegotiation.*
        \\import io.ktor.client.request.*
        \\import io.ktor.serialization.kotlinx.json.*
        \\import kotlinx.serialization.Serializable
        \\
        \\@Serializable
        \\data class User(val name: String, val age: Int, val roles: List<String>)
        \\
        \\suspend fun main() {
        \\    val client = HttpClient {
        \\        install(ContentNegotiation) { json() }
        \\    }
        \\    val resp = client.get("http://127.0.0.1:PORT/u")
        \\    val user = resp.body<User>()
        \\    println("user=" + user)
        \\    println("first=" + user.roles.first())
        \\    client.close()
        \\}
        \\
    , "io.ktor/client-serialization",
        \\user=User(name=Ada, age=36, roles=[ADMIN, USER])
        \\first=ADMIN
        \\
    );
}

test "POST setBody serializes through ContentNegotiation onto the wire" {
    try runProgram("post_typed",
        \\import io.ktor.client.*
        \\import io.ktor.client.plugins.contentnegotiation.*
        \\import io.ktor.client.request.*
        \\import io.ktor.client.statement.*
        \\import io.ktor.http.*
        \\import io.ktor.serialization.kotlinx.json.*
        \\import kotlinx.serialization.Serializable
        \\
        \\@Serializable
        \\data class User(val name: String, val age: Int, val roles: List<String>)
        \\
        \\suspend fun main() {
        \\    val client = HttpClient {
        \\        install(ContentNegotiation) { json() }
        \\    }
        \\    val resp = client.post("http://127.0.0.1:PORT/u") {
        \\        contentType(ContentType.Application.Json)
        \\        setBody(User("Bo", 7, listOf("USER")))
        \\    }
        \\    println("status=" + resp.status)
        \\    println("echo=" + resp.bodyAsText())
        \\    client.close()
        \\}
        \\
    , "io.ktor/client-serialization",
        \\status=200 OK
        \\echo={"name":"Bo","age":7,"roles":["USER"]}
        \\
    );
}
