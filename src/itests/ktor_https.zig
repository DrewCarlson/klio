//! End-to-end HTTPS gate: a background child `klio` serves an `sslConnector`
//! on the `Klio` engine with the test certificates under tests/fixtures/tls,
//! and this test is the client, through Zig's own std.crypto.tls.Client: it
//! verifies the server's chain against the test CA and the host name, sends
//! HTTP/1.1 requests over the TLS stream and reads the responses.

const std = @import("std");
const census_support = @import("commontest_support.zig");
const runtime = @import("runtime");
const klio_child = @import("klio_child");
const net = std.Io.net;
const tls = std.crypto.tls;

fn klioBin(env: *const std.process.Environ.Map) []const u8 {
    return env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
}

fn envWithHome(allocator: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(allocator, &map);
    try map.put("HOME", home);
    try map.put("KLIO_HOME", home);
    return map;
}

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

fn waitForServer(io: std.Io, port: u16, slowdown: i64) bool {
    const attempts: usize = @intCast(1200 * slowdown);
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
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

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_DIR = "/tmp/klio_itest_ktorhttps";
const FIXTURES = "tests/fixtures/tls";

const SERVER_SRC =
    \\import io.ktor.server.application.install
    \\import io.ktor.server.engine.embeddedServer
    \\import io.ktor.server.engine.klio.Klio
    \\import io.ktor.server.engine.sslConnector
    \\import io.ktor.server.plugins.httpsredirect.HttpsRedirect
    \\import io.ktor.server.plugins.origin
    \\import io.ktor.server.request.receiveText
    \\import io.ktor.server.response.respondText
    \\import io.ktor.server.routing.get
    \\import io.ktor.server.routing.post
    \\import io.ktor.server.routing.routing
    \\
    \\const val CHAIN = """CHAIN_PEM"""
    \\const val KEY = """KEY_PEM"""
    \\
    \\fun main() {
    \\    embeddedServer(Klio, configure = {
    \\        sslConnector(CHAIN, KEY) {
    \\            host = "127.0.0.1"
    \\            port = PORT
    \\        }
    \\    }) {
    \\        // Redirects plain calls only: every call here arrives over TLS.
    \\        install(HttpsRedirect) { sslPort = PORT }
    \\        routing {
    \\            get("/hello") { call.respondText("hello over TLS") }
    \\            post("/length") { call.respondText("length=" + call.receiveText().length) }
    \\            get("/where") {
    \\                val local = call.request.local
    \\                call.respondText("${local.scheme} ${call.request.origin.scheme} ${local.serverPort}")
    \\            }
    \\        }
    \\    }.start(wait = true)
    \\}
;

/// One HTTPS request through std.crypto.tls.Client; the response bytes up to
/// the server's close, owned by `a`.
fn httpsRequest(a: std.mem.Allocator, io: std.Io, port: u16, anchors: *std.crypto.Certificate.Bundle, request: []const u8) ![]u8 {
    const addr = try net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const socket_read = try a.alloc(u8, tls.Client.min_buffer_len);
    const socket_write = try a.alloc(u8, tls.Client.min_buffer_len);
    const tls_read = try a.alloc(u8, tls.Client.min_buffer_len);
    const tls_write = try a.alloc(u8, tls.Client.min_buffer_len);
    var reader = stream.reader(io, socket_read);
    var writer = stream.writer(io, socket_write);
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    var lock: std.Io.RwLock = .init;
    var client = try tls.Client.init(&reader.interface, &writer.interface, .{
        .host = .{ .explicit = "localhost" },
        .ca = .{ .bundle = .{ .gpa = a, .io = io, .lock = &lock, .bundle = anchors } },
        .write_buffer = tls_write,
        .read_buffer = tls_read,
        .entropy = &entropy,
        .realtime_now = std.Io.Timestamp.now(io, .real),
    });
    try client.writer.writeAll(request);
    try client.writer.flush();
    try writer.interface.flush();
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    // The response ends with the server's close_notify; a connection that
    // closes without one fails the read as truncated.
    while (true) {
        const n = try client.reader.readSliceShort(&buf);
        try out.appendSlice(a, buf[0..n]);
        if (n < buf.len) break;
    }
    return out.toOwnedSlice(a);
}

fn statusOf(resp: []const u8) ?u16 {
    const line_end = std.mem.find(u8, resp, "\r\n") orelse return null;
    var it = std.mem.tokenizeScalar(u8, resp[0..line_end], ' ');
    _ = it.next() orelse return null;
    const code = it.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn bodyOf(resp: []const u8) []const u8 {
    const sep = std.mem.find(u8, resp, "\r\n\r\n") orelse return "";
    return resp[sep + 4 ..];
}

test "https: std.crypto.tls.Client verifies the Klio engine's certificate and talks HTTP/1.1 over it" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = try envWithHome(a, try klio_child.home(a));
    const cwd = std.Io.Dir.cwd();

    const chain = try cwd.readFileAlloc(io, FIXTURES ++ "/server-p256.pem", a, .limited(1 << 20));
    const key = try cwd.readFileAlloc(io, FIXTURES ++ "/server-p256-key.pem", a, .limited(1 << 20));
    var anchors: std.crypto.Certificate.Bundle = .empty;
    try anchors.addCertsFromFilePath(a, io, std.Io.Timestamp.now(io, .real), cwd, FIXTURES ++ "/ca.pem");

    const port = try freePort(io);
    cwd.createDirPath(io, TMP_DIR) catch {};
    var prog = try std.mem.replaceOwned(u8, a, SERVER_SRC, "CHAIN_PEM", chain);
    prog = try std.mem.replaceOwned(u8, a, prog, "KEY_PEM", key);
    prog = try std.mem.replaceOwned(u8, a, prog, "PORT", try std.fmt.allocPrint(a, "{d}", .{port}));
    const path = TMP_DIR ++ "/https_server.kt";
    try cwd.writeFile(io, .{ .sub_path = path, .data = prog });

    var child = std.process.spawn(io, .{
        .argv = &.{ klioBin(&env), "run", "--feature", "io.ktor/server-cio,server-http-redirect", path },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        std.debug.print("ktor_https: spawn klio failed: {s}\n", .{@errorName(e)});
        return error.SpawnFailed;
    };
    defer child.kill(io);

    if (!waitForServer(io, port, census_support.harnessSlowdown(&env))) {
        std.debug.print("ktor_https: server never came up on port {d}\n", .{port});
        return error.ServerDidNotStart;
    }

    {
        const resp = try httpsRequest(a, io, port, &anchors, "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try std.testing.expectEqual(@as(?u16, 200), statusOf(resp));
        try std.testing.expectEqualStrings("hello over TLS", bodyOf(resp));
    }
    {
        const body = try a.alloc(u8, 50_000);
        @memset(body, 'z');
        const head = try std.fmt.allocPrint(a, "POST /length HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        const resp = try httpsRequest(a, io, port, &anchors, try std.mem.concat(a, u8, &.{ head, body }));
        try std.testing.expectEqual(@as(?u16, 200), statusOf(resp));
        try std.testing.expectEqualStrings("length=50000", bodyOf(resp));
    }
    {
        // A call on the HTTPS connector knows it: the https scheme, and 443
        // for a Host header without a port.
        const resp = try httpsRequest(a, io, port, &anchors, "GET /where HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try std.testing.expectEqual(@as(?u16, 200), statusOf(resp));
        try std.testing.expectEqualStrings("https https 443", bodyOf(resp));
    }
}
