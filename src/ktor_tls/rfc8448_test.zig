//! Both sides of RFC 8448's traces, byte for byte: section 3 (a simple 1-RTT
//! handshake, application data and closure) and section 5 (a
//! HelloRetryRequest from x25519 to P-256).
//!
//! What the trace fixes and this engine would otherwise choose itself comes
//! in through `TestHooks`: the hello randoms, the ephemeral private keys, the
//! ClientHello and EncryptedExtensions extension blocks (the trace's client
//! offers groups, a session ticket and a record size limit this engine does
//! not), the HelloRetryRequest's cookie, and the server's RSA-PSS
//! CertificateVerify signature (this engine's servers sign with P-256 or
//! Ed25519 keys). Every record, key, transcript hash, Finished value and
//! ciphertext is the engine's own, and every record it writes must equal the
//! trace's.

const std = @import("std");
const testing = std.testing;
const session = @import("session.zig");
const wire = @import("wire.zig");
const pem = @import("pem.zig");
const rfc = @import("rfc8448.zig");

const Session = session.Session;

/// The pieces of a ClientHello message the hooks take.
const Hello = struct { random: [32]u8, extensions: []const u8 };

fn clientHello(msg: []const u8) !Hello {
    var r: wire.Reader = .init(msg[4..]);
    _ = try r.int(u16);
    const random = (try r.array(32)).*;
    _ = try r.vec(u8);
    _ = try r.vec(u16);
    _ = try r.vec(u8);
    return .{ .random = random, .extensions = try r.vec(u16) };
}

/// A ServerHello's random and extension block.
fn serverHello(msg: []const u8) !Hello {
    var r: wire.Reader = .init(msg[4..]);
    _ = try r.int(u16);
    const random = (try r.array(32)).*;
    _ = try r.vec(u8);
    _ = try r.int(u16);
    _ = try r.int(u8);
    return .{ .random = random, .extensions = try r.vec(u16) };
}

fn encryptedExtensions(msg: []const u8) ![]const u8 {
    var r: wire.Reader = .init(msg[4..]);
    return r.vec(u16);
}

fn certificateDer(msg: []const u8) ![]const u8 {
    var r: wire.Reader = .init(msg[4..]);
    _ = try r.vec(u8);
    var list = try r.sub(u24);
    return list.vec(u24);
}

fn signature(msg: []const u8) !struct { scheme: u16, bytes: []const u8 } {
    var r: wire.Reader = .init(msg[4..]);
    const scheme = try r.int(u16);
    return .{ .scheme = scheme, .bytes = try r.vec(u16) };
}

/// The next `want.len` bytes the session queued are `want`.
fn expectOutput(s: *Session, want: []const u8) !void {
    const out = s.output();
    try testing.expect(out.len >= want.len);
    try testing.expectEqualSlices(u8, want, out[0..want.len]);
    s.consumeOutput(want.len);
}

fn feed(s: *Session, parts: []const []const u8) !void {
    for (parts) |p| try s.feed(p);
}

/// The trace's server key is RSA, which this engine does not sign with; the
/// session needs a key of its own that the pinned signature stands in for.
fn anyKey() !pem.PrivateKey {
    const E = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    return .{ .p256 = try E.KeyPair.generateDeterministic(@splat(7)) };
}

test "RFC 8448 section 3, client side" {
    const ch = try clientHello(&rfc.s3_client_hello);
    const cfg: session.ClientConfig = .{
        .server_name = "server",
        // The trace's certificate is self-signed and expired in 2026.
        .verification = .insecure_accept_any,
        .cipher_suites = &.{ .aes_128_gcm_sha256, .chacha20_poly1305_sha256, .aes_256_gcm_sha384 },
        .compat_mode = false,
        .hooks = .{
            .random = ch.random,
            .x25519_secret = rfc.s3_client_x25519_secret,
            .client_hello_extensions = ch.extensions,
        },
    };
    var c = try Session.initClient(testing.allocator, &cfg, @splat(1));
    defer c.deinit();
    try expectOutput(&c, &rfc.s3_client_hello_record);

    try feed(&c, &.{ &rfc.s3_server_hello_record, &rfc.s3_server_flight_record });
    try testing.expect(c.handshakeDone());
    try expectOutput(&c, &rfc.s3_client_finished_record);

    // The ticket is read and dropped; resumption is not supported.
    try c.feed(&rfc.s3_new_session_ticket_record);
    try c.writeApp(&rfc.s3_application_data);
    try expectOutput(&c, &rfc.s3_client_application_record);
    try c.feed(&rfc.s3_server_application_record);
    try testing.expectEqualSlices(u8, &rfc.s3_application_data, c.appData());

    try c.close();
    try expectOutput(&c, &rfc.s3_client_alert_record);
    try c.feed(&rfc.s3_server_alert_record);
    try testing.expect(c.peerClosed());
    try testing.expect(c.failure() == null);
}

test "RFC 8448 section 3, server side" {
    const sh = try serverHello(&rfc.s3_server_hello);
    const sig = try signature(&rfc.s3_certificate_verify);
    const chain = [_][]const u8{try certificateDer(&rfc.s3_certificate)};
    const identity: session.Identity = .{ .chain = &chain, .key = try anyKey() };
    const cfg: session.ServerConfig = .{
        .identity = &identity,
        .hooks = .{
            .random = sh.random,
            .x25519_secret = rfc.s3_server_x25519_secret,
            .encrypted_extensions = try encryptedExtensions(&rfc.s3_encrypted_extensions),
            .signature = .{ .scheme = sig.scheme, .bytes = sig.bytes },
        },
    };
    var s = Session.initServer(testing.allocator, &cfg, @splat(2));
    defer s.deinit();

    try s.feed(&rfc.s3_client_hello_record);
    try expectOutput(&s, &rfc.s3_server_hello_record);
    try expectOutput(&s, &rfc.s3_server_flight_record);
    try testing.expectEqual(@as(usize, 0), s.output().len);

    try s.feed(&rfc.s3_client_finished_record);
    try testing.expect(s.handshakeDone());
    try testing.expectEqualStrings("server", s.requestedServerName().?);

    // The trace's server issues a ticket before its application data, which
    // puts that record at sequence number 1.
    try s.sendRawHandshake(&rfc.s3_new_session_ticket);
    try expectOutput(&s, &rfc.s3_new_session_ticket_record);
    try s.feed(&rfc.s3_client_application_record);
    try testing.expectEqualSlices(u8, &rfc.s3_application_data, s.appData());
    try s.writeApp(&rfc.s3_application_data);
    try expectOutput(&s, &rfc.s3_server_application_record);

    try s.feed(&rfc.s3_client_alert_record);
    try testing.expect(s.peerClosed());
    try s.close();
    try expectOutput(&s, &rfc.s3_server_alert_record);
}

test "RFC 8448 section 5, client side" {
    const ch1 = try clientHello(&rfc.s5_client_hello);
    const ch2 = try clientHello(&rfc.s5_retry_client_hello);
    try testing.expectEqualSlices(u8, &ch1.random, &ch2.random);
    const cfg: session.ClientConfig = .{
        .server_name = "server",
        .verification = .insecure_accept_any,
        .cipher_suites = &.{ .aes_128_gcm_sha256, .chacha20_poly1305_sha256, .aes_256_gcm_sha384 },
        .compat_mode = false,
        .hooks = .{
            .random = ch1.random,
            .x25519_secret = rfc.s5_client_x25519_secret,
            .p256_secret = rfc.s5_client_p256_secret,
            .client_hello_extensions = ch1.extensions,
            .retry_hello_extensions = ch2.extensions,
        },
    };
    var c = try Session.initClient(testing.allocator, &cfg, @splat(3));
    defer c.deinit();
    try expectOutput(&c, &rfc.s5_client_hello_record);

    try c.feed(&rfc.s5_hello_retry_request_record);
    try expectOutput(&c, &rfc.s5_retry_client_hello_record);

    try feed(&c, &.{ &rfc.s5_server_hello_record, &rfc.s5_server_flight_record });
    try testing.expect(c.handshakeDone());
    try expectOutput(&c, &rfc.s5_client_finished_record);
}

test "RFC 8448 section 5, server side" {
    const hrr = try serverHello(&rfc.s5_hello_retry_request);
    const sh = try serverHello(&rfc.s5_server_hello);
    const sig = try signature(&rfc.s5_certificate_verify);
    const chain = [_][]const u8{try certificateDer(&rfc.s5_certificate)};
    const identity: session.Identity = .{ .chain = &chain, .key = try anyKey() };
    const cfg: session.ServerConfig = .{
        .identity = &identity,
        // The trace's server prefers P-256 even though the client shared x25519.
        .groups = &.{ .secp256r1, .secp384r1, .x25519 },
        .strict_group_preference = true,
        .hooks = .{
            .random = sh.random,
            .p256_secret = rfc.s5_server_p256_secret,
            .hello_retry_extensions = hrr.extensions,
            .encrypted_extensions = try encryptedExtensions(&rfc.s5_encrypted_extensions),
            .signature = .{ .scheme = sig.scheme, .bytes = sig.bytes },
        },
    };
    var s = Session.initServer(testing.allocator, &cfg, @splat(4));
    defer s.deinit();

    try s.feed(&rfc.s5_client_hello_record);
    try expectOutput(&s, &rfc.s5_hello_retry_request_record);
    try s.feed(&rfc.s5_retry_client_hello_record);
    try expectOutput(&s, &rfc.s5_server_hello_record);
    try expectOutput(&s, &rfc.s5_server_flight_record);
    try s.feed(&rfc.s5_client_finished_record);
    try testing.expect(s.handshakeDone());
}
