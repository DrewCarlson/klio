//! Session tests: handshakes between the two sides over the fixture
//! certificates, certificate verification outcomes, key updates and close.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;

const fixtures = @import("tls_fixtures");
const session = @import("session.zig");
const pem = @import("pem.zig");
const x509 = @import("x509.zig");

const Session = session.Session;
const ClientConfig = session.ClientConfig;
const ServerConfig = session.ServerConfig;
const Identity = session.Identity;
const AlertDescription = session.AlertDescription;

/// 2027-01-15: inside every fixture's validity except expired.pem's.
pub const now_sec: i64 = 1_800_000_000;

pub fn seed(n: u8) [32]u8 {
    return @splat(n);
}

/// A server identity loaded from PEM, owning its chain.
pub const OwnedIdentity = struct {
    identity: Identity,
    chain: [][]u8,

    pub fn load(a: Allocator, chain_pem: []const u8, key_pem: []const u8) !OwnedIdentity {
        const chain = try pem.certificates(a, chain_pem);
        errdefer {
            for (chain) |c| a.free(c);
            a.free(chain);
        }
        const key = try pem.privateKey(a, key_pem);
        return .{ .identity = .{ .chain = chain, .key = key }, .chain = chain };
    }

    pub fn deinit(o: *OwnedIdentity, a: Allocator) void {
        for (o.chain) |c| a.free(c);
        a.free(o.chain);
    }
};

pub const Env = struct {
    a: Allocator,
    anchors: Bundle = .empty,
    p256: OwnedIdentity,
    ed25519: OwnedIdentity,
    untrusted: OwnedIdentity,
    expired: OwnedIdentity,

    pub fn init(a: Allocator) !Env {
        var env: Env = .{
            .a = a,
            .p256 = try .load(a, fixtures.server_p256, fixtures.server_p256_key),
            .ed25519 = try .load(a, fixtures.server_ed25519, fixtures.server_ed25519_key),
            .untrusted = try .load(a, fixtures.untrusted, fixtures.untrusted_key),
            .expired = try .load(a, fixtures.expired, fixtures.expired_key),
        };
        _ = try x509.addPem(&env.anchors, a, fixtures.ca, now_sec);
        return env;
    }

    pub fn deinit(e: *Env) void {
        e.anchors.deinit(e.a);
        e.p256.deinit(e.a);
        e.ed25519.deinit(e.a);
        e.untrusted.deinit(e.a);
        e.expired.deinit(e.a);
    }

    pub fn trust(e: *const Env, host: []const u8) ClientConfig {
        return .{ .server_name = host, .verification = .{ .trust = .{ .anchors = &e.anchors, .now_sec = now_sec } } };
    }
};

/// Moves queued bytes between the two sides until neither has anything to
/// send. A side's failure is left for the test to inspect.
pub fn pump(c: *Session, s: *Session) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var moved = false;
        inline for (.{ .{ c, s }, .{ s, c } }) |pair| {
            const from = pair[0];
            const to = pair[1];
            if (from.output().len > 0) {
                const bytes = try testing.allocator.dupe(u8, from.output());
                defer testing.allocator.free(bytes);
                from.consumeOutput(bytes.len);
                to.feed(bytes) catch |e| switch (e) {
                    error.TlsFailure => {},
                    else => return e,
                };
                moved = true;
            }
        }
        if (!moved) return;
    }
    return error.TestUnexpectedResult;
}

fn exchange(c: *Session, s: *Session) !void {
    try c.writeApp("ping from the client");
    try pump(c, s);
    try testing.expectEqualStrings("ping from the client", s.appData());
    s.consumeApp(s.appData().len);
    try s.writeApp("pong from the server");
    try pump(c, s);
    try testing.expectEqualStrings("pong from the server", c.appData());
    c.consumeApp(c.appData().len);
}

fn handshake(ccfg: *const ClientConfig, scfg: *const ServerConfig) !struct { c: Session, s: Session } {
    var c = try Session.initClient(testing.allocator, ccfg, seed(1));
    errdefer c.deinit();
    var s = Session.initServer(testing.allocator, scfg, seed(2));
    errdefer s.deinit();
    try pump(&c, &s);
    if (std.c.getenv("KTOR_TLS_TEST_TRACE") != null) {
        if (c.failure()) |f| std.debug.print("client failure: {t} local={} {s}\n", .{ f.alert, f.local, f.reason });
        if (s.failure()) |f| std.debug.print("server failure: {t} local={} {s}\n", .{ f.alert, f.local, f.reason });
    }
    return .{ .c = c, .s = s };
}

test "a handshake over each server key completes and carries data both ways" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    for ([_]*const Identity{ &env.p256.identity, &env.ed25519.identity }) |id| {
        const ccfg = env.trust("localhost");
        const scfg: ServerConfig = .{ .identity = id };
        var pair = try handshake(&ccfg, &scfg);
        defer pair.c.deinit();
        defer pair.s.deinit();
        try testing.expect(pair.c.handshakeDone());
        try testing.expect(pair.s.handshakeDone());
        try testing.expectEqualStrings("localhost", pair.s.requestedServerName().?);
        try exchange(&pair.c, &pair.s);
        try pair.c.close();
        try pump(&pair.c, &pair.s);
        try testing.expect(pair.s.peerClosed());
        try testing.expectError(error.TlsFailure, pair.c.writeApp("after close"));
    }
}

test "every cipher suite and key exchange group negotiates" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    for (session.default_suites) |suite| {
        for ([_]session.Group{ .x25519, .secp256r1, .secp384r1 }) |group| {
            var ccfg = env.trust("localhost");
            ccfg.cipher_suites = &.{suite};
            ccfg.key_share_groups = &.{group};
            const scfg: ServerConfig = .{ .identity = &env.p256.identity };
            var pair = try handshake(&ccfg, &scfg);
            defer pair.c.deinit();
            defer pair.s.deinit();
            try testing.expect(pair.c.handshakeDone());
            try testing.expectEqual(suite, pair.s.negotiatedSuite().?);
            try exchange(&pair.c, &pair.s);
        }
    }
}

test "a missing key share costs a HelloRetryRequest, with and without compatibility mode" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    for ([_]bool{ true, false }) |compat| {
        var ccfg = env.trust("localhost");
        ccfg.compat_mode = compat;
        ccfg.key_share_groups = &.{.x25519};
        const scfg: ServerConfig = .{ .identity = &env.p256.identity, .groups = &.{.secp256r1} };
        var pair = try handshake(&ccfg, &scfg);
        defer pair.c.deinit();
        defer pair.s.deinit();
        try testing.expect(pair.c.handshakeDone());
        try testing.expect(pair.s.handshakeDone());
        try exchange(&pair.c, &pair.s);
    }
    // A strict server preference retries even though the client shared a
    // group the server supports.
    var ccfg = env.trust("localhost");
    ccfg.key_share_groups = &.{.x25519};
    const strict: ServerConfig = .{ .identity = &env.p256.identity, .groups = &.{ .secp256r1, .x25519 }, .strict_group_preference = true };
    var pair = try handshake(&ccfg, &strict);
    defer pair.c.deinit();
    defer pair.s.deinit();
    try testing.expect(pair.c.handshakeDone());
    try exchange(&pair.c, &pair.s);
}

test "IP literal hosts match the certificate's address entries and send no SNI" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "127.0.0.1", "::1" }) |host| {
        const ccfg = env.trust(host);
        const scfg: ServerConfig = .{ .identity = &env.p256.identity };
        var pair = try handshake(&ccfg, &scfg);
        defer pair.c.deinit();
        defer pair.s.deinit();
        try testing.expect(pair.c.handshakeDone());
        try testing.expect(pair.s.requestedServerName() == null);
    }
}

fn expectRefused(ccfg: *const ClientConfig, scfg: *const ServerConfig, alert: AlertDescription, reason: []const u8) !void {
    var pair = try handshake(ccfg, scfg);
    defer pair.c.deinit();
    defer pair.s.deinit();
    try testing.expect(pair.c.failed());
    const cf = pair.c.failure().?;
    try testing.expectEqual(alert, cf.alert);
    try testing.expectEqualStrings(reason, cf.reason);
    try testing.expect(cf.local);
    // The server hears the alert.
    try testing.expect(pair.s.failed());
    const sf = pair.s.failure().?;
    try testing.expectEqual(alert, sf.alert);
    try testing.expect(!sf.local);
}

test "certificate verification refuses an untrusted, expired or misnamed server" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    const localhost = env.trust("localhost");
    try expectRefused(&localhost, &.{ .identity = &env.untrusted.identity }, .unknown_ca, "the server certificate is not issued by a trusted authority");
    try expectRefused(&localhost, &.{ .identity = &env.expired.identity }, .certificate_expired, "the server certificate has expired or is not yet valid");
    const other = env.trust("example.com");
    try expectRefused(&other, &.{ .identity = &env.p256.identity }, .bad_certificate, "the server certificate is not valid for this host");
    const other_ip = env.trust("10.0.0.1");
    try expectRefused(&other_ip, &.{ .identity = &env.p256.identity }, .bad_certificate, "the server certificate is not valid for this host");
    // Not before the CA existed.
    var early = env.trust("localhost");
    early.verification.trust.now_sec = 946_684_800;
    try expectRefused(&early, &.{ .identity = &env.p256.identity }, .certificate_expired, "the server certificate has expired or is not yet valid");
    // An issuer on a curve std.crypto does not verify with.
    var p521_anchors: Bundle = .empty;
    defer p521_anchors.deinit(testing.allocator);
    _ = try x509.addPem(&p521_anchors, testing.allocator, fixtures.p521_ca, now_sec);
    var by_p521 = try OwnedIdentity.load(testing.allocator, fixtures.server_p521ca, fixtures.server_p256_key);
    defer by_p521.deinit(testing.allocator);
    const p521_trust: ClientConfig = .{ .server_name = "localhost", .verification = .{ .trust = .{ .anchors = &p521_anchors, .now_sec = now_sec } } };
    try expectRefused(&p521_trust, &.{ .identity = &by_p521.identity }, .unsupported_certificate, "the server certificate uses an unsupported algorithm");
}

test "the insecure mode accepts an untrusted certificate but still checks the signature" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    const ccfg: ClientConfig = .{ .server_name = "localhost", .verification = .insecure_accept_any };
    var pair = try handshake(&ccfg, &.{ .identity = &env.untrusted.identity });
    defer pair.c.deinit();
    defer pair.s.deinit();
    try testing.expect(pair.c.handshakeDone());
    try exchange(&pair.c, &pair.s);
    // A server whose key does not match its certificate fails the signature.
    const mismatched: Identity = .{ .chain = env.untrusted.identity.chain, .key = env.p256.identity.key };
    try expectRefused(&ccfg, &.{ .identity = &mismatched }, .decrypt_error, "CertificateVerify signature is invalid");
}

test "a client without a server name cannot verify" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    const ccfg: ClientConfig = .{ .verification = .{ .trust = .{ .anchors = &env.anchors, .now_sec = now_sec } } };
    var c = try Session.initClient(testing.allocator, &ccfg, seed(1));
    defer c.deinit();
    try testing.expect(c.failed());
    try testing.expectEqualStrings("certificate verification needs a server name", c.failure().?.reason);
    try testing.expectEqual(@as(usize, 0), c.output().len);
}

test "key updates in both directions keep the connection working" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    const ccfg = env.trust("localhost");
    var pair = try handshake(&ccfg, &.{ .identity = &env.p256.identity });
    defer pair.c.deinit();
    defer pair.s.deinit();
    try pair.c.requestKeyUpdate();
    try exchange(&pair.c, &pair.s);
    try pair.s.requestKeyUpdate();
    try pair.s.requestKeyUpdate();
    try exchange(&pair.c, &pair.s);
}

test "a connection whose record sequence would wrap fails instead" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    const ccfg = env.trust("localhost");
    var pair = try handshake(&ccfg, &.{ .identity = &env.p256.identity });
    defer pair.c.deinit();
    defer pair.s.deinit();
    pair.c.write.?.seq = std.math.maxInt(u64);
    try testing.expectError(error.TlsFailure, pair.c.writeApp("one more"));
    try testing.expectEqualStrings("record sequence exhausted", pair.c.failure().?.reason);
    pair.s.read.?.seq = std.math.maxInt(u64);
    try pair.s.writeApp("to the client");
    try pump(&pair.c, &pair.s);
    var pair2 = try handshake(&ccfg, &.{ .identity = &env.p256.identity });
    defer pair2.c.deinit();
    defer pair2.s.deinit();
    pair2.s.read.?.seq = std.math.maxInt(u64);
    try pair2.c.writeApp("to the server");
    try pump(&pair2.c, &pair2.s);
    try testing.expectEqualStrings("record sequence exhausted", pair2.s.failure().?.reason);
}

test "large writes span records and byte-at-a-time delivery reassembles them" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    const ccfg = env.trust("localhost");
    var c = try Session.initClient(testing.allocator, &ccfg, seed(3));
    defer c.deinit();
    var s = Session.initServer(testing.allocator, &.{ .identity = &env.ed25519.identity }, seed(4));
    defer s.deinit();
    // Deliver the whole handshake one byte at a time.
    var rounds: usize = 0;
    while (!(c.handshakeDone() and s.handshakeDone()) and rounds < 16) : (rounds += 1) {
        inline for (.{ .{ &c, &s }, .{ &s, &c } }) |pair| {
            const bytes = try testing.allocator.dupe(u8, pair[0].output());
            defer testing.allocator.free(bytes);
            pair[0].consumeOutput(bytes.len);
            for (bytes) |b| try pair[1].feed(&.{b});
        }
    }
    try testing.expect(c.handshakeDone() and s.handshakeDone());
    const big = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try c.writeApp(big);
    try pump(&c, &s);
    try testing.expectEqualSlices(u8, big, s.appData());
}
