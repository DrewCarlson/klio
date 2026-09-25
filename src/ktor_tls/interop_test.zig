//! Interop with Zig's own TLS client, std.crypto.tls.Client, over loopback
//! TCP in-process: the std client verifies this engine's server against the
//! fixture CA and the host name, sends a message, reads the reply and closes.

const std = @import("std");
const testing = std.testing;
const tls = std.crypto.tls;
const net = std.Io.net;

const session = @import("session.zig");
const tests = @import("tests.zig");

const Session = session.Session;
const a = testing.allocator;

const client_message = "hello from std.crypto.tls.Client";
const server_message = "hello from the klio TLS server";

const Shared = struct {
    io: std.Io,
    port: u16,
    anchors: *std.crypto.Certificate.Bundle,
    reply: [server_message.len]u8 = undefined,
    err: ?anyerror = null,
};

fn stdClient(sh: *Shared) void {
    stdClientRun(sh) catch |e| {
        sh.err = e;
    };
}

fn stdClientRun(sh: *Shared) !void {
    const io = sh.io;
    const addr: net.IpAddress = .{ .ip4 = .loopback(sh.port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var socket_read: [tls.Client.min_buffer_len]u8 = undefined;
    var socket_write: [tls.Client.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &socket_read);
    var writer = stream.writer(io, &socket_write);
    var tls_read: [tls.Client.min_buffer_len]u8 = undefined;
    var tls_write: [tls.Client.min_buffer_len]u8 = undefined;
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    var lock: std.Io.RwLock = .init;
    var client = try tls.Client.init(&reader.interface, &writer.interface, .{
        .host = .{ .explicit = "localhost" },
        .ca = .{ .bundle = .{ .gpa = std.heap.page_allocator, .io = io, .lock = &lock, .bundle = sh.anchors } },
        .write_buffer = &tls_write,
        .read_buffer = &tls_read,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = @as(i96, tests.now_sec) * std.time.ns_per_s },
    });
    try client.writer.writeAll(client_message);
    try client.writer.flush();
    try writer.interface.flush();
    try client.reader.readSliceAll(&sh.reply);
    try client.end();
    try writer.interface.flush();
}

/// Runs this engine's server over an accepted stream until the peer closes.
fn serve(io: std.Io, stream: net.Stream, s: *Session) !void {
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    var replied = false;
    while (true) {
        if (s.output().len > 0) {
            try writer.interface.writeAll(s.output());
            s.consumeOutput(s.output().len);
            try writer.interface.flush();
        }
        if (!replied and s.appData().len >= client_message.len) {
            try testing.expectEqualStrings(client_message, s.appData());
            s.consumeApp(client_message.len);
            try s.writeApp(server_message);
            replied = true;
            continue;
        }
        if (s.peerClosed() or s.failed()) return;
        const got = reader.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => return,
            else => return e,
        };
        const n = got.len;
        s.feed(got) catch |e| switch (e) {
            error.TlsFailure => {},
            else => return e,
        };
        reader.interface.toss(n);
    }
}

test "std.crypto.tls.Client completes a verified handshake with this server" {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = try tests.Env.init(a);
    defer env.deinit();
    // Only the P-256 identity: std's client offers ed25519 but maps no
    // certificate key type to it when checking CertificateVerify, so it
    // refuses every Ed25519 server with TlsBadSignatureScheme.
    for ([_]*const session.Identity{&env.p256.identity}) |id| {
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        var shared: Shared = .{ .io = io, .port = server.socket.address.getPort(), .anchors = &env.anchors };
        const thread = try std.Thread.spawn(.{}, stdClient, .{&shared});
        const stream = try server.accept(io);
        var s = Session.initServer(a, &.{ .identity = id }, tests.seed(8));
        defer s.deinit();
        const served = serve(io, stream, &s);
        stream.close(io);
        thread.join();
        try served;
        if (shared.err) |e| return e;
        if (s.failure()) |f| {
            std.debug.print("server failure: {t} {s}\n", .{ f.alert, f.reason });
            return error.TestUnexpectedResult;
        }
        try testing.expect(s.handshakeDone());
        try testing.expect(s.peerClosed());
        try testing.expectEqualStrings(server_message, &shared.reply);
    }
}
