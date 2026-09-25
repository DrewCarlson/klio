//! TLS 1.2 client tests against a scripted server: full handshakes for each
//! suite and kind of server key, with and without the extended master
//! secret, application data both ways, and one test per reachable TLS 1.2
//! alert path. The server side here is built from RFC 5246 and RFC 8422
//! message by message; its key schedule is tls12.zig's, which tls12.zig's own
//! tests check against OpenSSL.

const std = @import("std");
const testing = std.testing;
const crypto = std.crypto;
const fixtures = @import("tls_fixtures");
const session = @import("session.zig");
const tls12 = @import("tls12.zig");
const pem = @import("pem.zig");
const tests = @import("tests.zig");

const a = testing.allocator;
const Session = session.Session;
const Suite12 = tls12.Suite12;
const Alert = session.AlertDescription;
const Scheme = session.SignatureScheme;

fn unhex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

const client_random: [32]u8 = @splat(0x11);
const default_server_random: [32]u8 = @splat(0x22);
const server_secret: [32]u8 = @splat(0x33);
/// X25519 public key of `server_secret` (tests/fixtures/tls/tls12-signatures.sh).
const server_public = unhex("7b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14");
/// server-rsa-key.pem's signatures over the ServerKeyExchange these tests
/// send with the default randoms (tls12-signatures.sh).
const rsa_pkcs1_sha256_sig = unhex("5f9ba95fca9067f1f5e129f9c904818478f919b6f7ea67b85bf9b5e0013779fca7f98bfb1faf82eedaacd14cc8d8f747b6ef81a75b4a3289ccb3fd7f6e5654e54fe8c6fcd0a254ef33cf135c13806f64cef284323ff4c7fa6142f3225c25e88dd2cae534db7a07bfcb00da436280a5124550179de06eae8b580f998fd96df5615ba244d0ae5995e7ecf89dbe153247d9f9d18d3ebeb49e48b052f23776227aeda3eaf5e974b97d289100d2abfe79a8f60b8278b32afc3b3e710bd1736b2308e0cb30323a6ce863df70572c33764d9622e85dfd97758dcda42061a831763865e89537a4e0349051b5ca421b0723c9db4d7e14c1619c327392bfdb1957eec337d6");
const rsa_pss_sha256_sig = unhex("278c9654fdc7c3d34427b3f06a38cc9c1ca2c8e865b0d3a184ad398216a061097bf4a990bc3926dd946cbc59346be0355b3abd620c27712d492b1014a535debc7ff0a51e97b4f637d71739a033d601e28bcba65ecc748a1d98e4651948c48b77a2707a015b5d60fcd47afa69786042f4d1df8d494a5ea3ede66c8036325d14b2a3cc9d573c47eb9fb877d911dce23e23677a801ac541f3bacc1b4b8cd0233b697a7adeafb90b1cd916143fd377e3c9fe6041063c244988815b3a1bc66712059aa4f8dba3660c820104329c0d73417d8b78a850b48c3ea7ee0b6b5c44dbeaf10c15f14d242c229dea36c3ccb113c3c81ccd23e77e10530c40486a769e99eff5c2");

// ---- message builders ------------------------------------------------------

const Bytes = std.ArrayList(u8);

fn put16(b: *Bytes, v: u16) !void {
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
}

fn put24(b: *Bytes, v: usize) !void {
    try b.appendSlice(a, &.{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
}

fn handshake(ht: u8, body: []const u8) ![]u8 {
    var b: Bytes = .empty;
    try b.append(a, ht);
    try put24(&b, body.len);
    try b.appendSlice(a, body);
    return b.toOwnedSlice(a);
}

fn record(ct: u8, payload: []const u8) ![]u8 {
    var b: Bytes = .empty;
    try b.appendSlice(a, &.{ ct, 3, 3 });
    try put16(&b, @intCast(payload.len));
    try b.appendSlice(a, payload);
    return b.toOwnedSlice(a);
}

const good_hello_extensions = [_]u8{ 0x00, 0x17, 0, 0, 0xff, 0x01, 0, 1, 0, 0x00, 0x0b, 0, 2, 1, 0 };
const good_hello_extensions_no_ems = [_]u8{ 0xff, 0x01, 0, 1, 0, 0x00, 0x0b, 0, 2, 1, 0 };

fn serverHelloBody(version: u16, random: [32]u8, suite: u16, compression: u8, extensions: []const u8) ![]u8 {
    var b: Bytes = .empty;
    try put16(&b, version);
    try b.appendSlice(a, &random);
    try b.append(a, 0);
    try put16(&b, suite);
    try b.append(a, compression);
    try put16(&b, @intCast(extensions.len));
    try b.appendSlice(a, extensions);
    return b.toOwnedSlice(a);
}

fn certificateBody(chain_pem: []const u8) ![]u8 {
    const chain = try pem.certificates(a, chain_pem);
    defer {
        for (chain) |c| a.free(c);
        a.free(chain);
    }
    var list: Bytes = .empty;
    defer list.deinit(a);
    for (chain) |der| {
        try put24(&list, der.len);
        try list.appendSlice(a, der);
    }
    var b: Bytes = .empty;
    try put24(&b, list.items.len);
    try b.appendSlice(a, list.items);
    return b.toOwnedSlice(a);
}

const Signer = union(enum) {
    p256: []const u8,
    ed25519: []const u8,
    pinned: []const u8,
};

/// ECParameters (named_curve, x25519) and the point, then the signature
/// over both randoms and those parameters.
fn serverKeyExchangeBody(random: [32]u8, point: []const u8, scheme: u16, signer: Signer) ![]u8 {
    var params: Bytes = .empty;
    defer params.deinit(a);
    try params.appendSlice(a, &.{ 3, 0x00, 0x1d, @intCast(point.len) });
    try params.appendSlice(a, point);
    const msg = try std.mem.concat(a, u8, &.{ &client_random, &random, params.items });
    defer a.free(msg);
    var sig_buf: [512]u8 = undefined;
    const sig: []const u8 = switch (signer) {
        .p256 => |key_pem| blk: {
            const key = try pem.privateKey(a, key_pem);
            const s = try key.p256.sign(msg, null);
            break :blk s.toDer(sig_buf[0..crypto.sign.ecdsa.EcdsaP256Sha256.Signature.der_encoded_length_max]);
        },
        .ed25519 => |key_pem| blk: {
            const key = try pem.privateKey(a, key_pem);
            const s = try key.ed25519.sign(msg, null);
            @memcpy(sig_buf[0..64], &s.toBytes());
            break :blk sig_buf[0..64];
        },
        .pinned => |bytes| bytes,
    };
    var b: Bytes = .empty;
    try b.appendSlice(a, params.items);
    try put16(&b, scheme);
    try put16(&b, @intCast(sig.len));
    try b.appendSlice(a, sig);
    return b.toOwnedSlice(a);
}

// ---- the scripted server -----------------------------------------------------

const Peer = struct {
    env: tests.Env,
    cfg: session.ClientConfig,
    c: Session,
    transcript: Bytes = .empty,
    suite: Suite12 = .ecdhe_ecdsa_aes_128_gcm_sha256,
    ems: bool = true,
    server_random: [32]u8 = default_server_random,
    client: ?tls12.Cipher12 = null,
    server: ?tls12.Cipher12 = null,
    /// The server's Finished message, once the client's is checked.
    server_finished: ?[16]u8 = null,

    /// A client offering `offer` (all TLS 1.2 suites when empty) whose
    /// ClientHello is already in the transcript.
    fn init(offer: []const Suite12) !*Peer {
        const p = try a.create(Peer);
        errdefer a.destroy(p);
        p.* = .{ .env = try .init(a), .cfg = undefined, .c = undefined };
        errdefer p.env.deinit();
        p.cfg = p.env.trust("localhost");
        if (offer.len != 0) p.cfg.tls12_suites = offer;
        p.cfg.hooks = .{ .random = client_random };
        p.c = try Session.initClient(a, &p.cfg, tests.seed(9));
        const out = p.c.output();
        try testing.expectEqual(@as(u8, 22), out[0]);
        try p.transcript.appendSlice(a, out[5..]);
        p.c.consumeOutput(out.len);
        return p;
    }

    fn deinit(p: *Peer) void {
        p.c.deinit();
        p.transcript.deinit(a);
        p.env.deinit();
        a.destroy(p);
    }

    /// Feeds handshake messages in one plaintext record and keeps them in
    /// the transcript.
    fn sendPlain(p: *Peer, msgs: []const []const u8) !void {
        const rec = try p.plainRecord(msgs);
        defer a.free(rec);
        try p.c.feed(rec);
    }

    /// Handshake messages as one plaintext record, kept in the transcript.
    fn plainRecord(p: *Peer, msgs: []const []const u8) ![]u8 {
        const joined = try std.mem.concat(a, u8, msgs);
        defer a.free(joined);
        try p.transcript.appendSlice(a, joined);
        return record(22, joined);
    }

    /// The usual first flight for `suite`: ServerHello, Certificate,
    /// ServerKeyExchange, ServerHelloDone.
    fn standardFlight(p: *Peer, chain_pem: []const u8, scheme: u16, signer: Signer, request_certificate: bool) !void {
        const flight = try p.firstFlight(chain_pem, scheme, signer, request_certificate);
        defer a.free(flight);
        try p.c.feed(flight);
    }

    fn firstFlight(p: *Peer, chain_pem: []const u8, scheme: u16, signer: Signer, request_certificate: bool) ![]u8 {
        const sh = try p.serverHello();
        defer a.free(sh);
        const cert_body = try certificateBody(chain_pem);
        defer a.free(cert_body);
        const cert = try handshake(11, cert_body);
        defer a.free(cert);
        const ske_body = try serverKeyExchangeBody(p.server_random, &server_public, scheme, signer);
        defer a.free(ske_body);
        const ske = try handshake(12, ske_body);
        defer a.free(ske);
        const cr = try handshake(13, &.{ 1, 64, 0, 2, 0x04, 0x03, 0, 0 });
        defer a.free(cr);
        const shd = try handshake(14, "");
        defer a.free(shd);
        return if (request_certificate) p.plainRecord(&.{ sh, cert, ske, cr, shd }) else p.plainRecord(&.{ sh, cert, ske, shd });
    }

    /// A good ServerHello for the peer's suite, owned by the caller.
    fn serverHello(p: *Peer) ![]u8 {
        const exts: []const u8 = if (p.ems) &good_hello_extensions else &good_hello_extensions_no_ems;
        const body = try serverHelloBody(0x0303, p.server_random, @intFromEnum(p.suite), 0, exts);
        defer a.free(body);
        return handshake(2, body);
    }

    /// Reads the client's second flight: [Certificate], ClientKeyExchange,
    /// ChangeCipherSpec and a protected Finished, deriving the keys as the
    /// server does and checking the client's verify_data.
    fn readClientFlight(p: *Peer, expect_certificate: bool) !void {
        const out = try a.dupe(u8, p.c.output());
        defer a.free(out);
        p.c.consumeOutput(out.len);
        var pos: usize = 0;
        var seen_certificate = false;
        var client_pub: ?[32]u8 = null;
        var master: [48]u8 = undefined;
        while (pos < out.len) {
            const ct = out[pos];
            const len = std.mem.readInt(u16, out[pos + 3 ..][0..2], .big);
            const payload = out[pos + 5 ..][0..len];
            pos += 5 + len;
            switch (ct) {
                22 => if (p.client == null) {
                    try p.transcript.appendSlice(a, payload);
                    switch (payload[0]) {
                        11 => {
                            try testing.expectEqualSlices(u8, &.{ 11, 0, 0, 3, 0, 0, 0 }, payload);
                            seen_certificate = true;
                        },
                        16 => {
                            try testing.expectEqual(@as(u8, 32), payload[4]);
                            client_pub = payload[5..37].*;
                        },
                        else => return error.UnexpectedClientMessage,
                    }
                } else {
                    // The protected Finished.
                    var plain: [16]u8 = undefined;
                    try testing.expectEqual(@as(usize, 16), payload.len - p.client.?.overhead());
                    try p.client.?.open(&plain, 22, payload);
                    const expected = tls12.verifyData(p.suite, &master, .client, &tls12.hash(p.suite, p.transcript.items));
                    try testing.expectEqualSlices(u8, &.{ 20, 0, 0, 12 }, plain[0..4]);
                    try testing.expectEqualSlices(u8, &expected, plain[4..16]);
                    try p.transcript.appendSlice(a, &plain);
                    const server_verify = tls12.verifyData(p.suite, &master, .server, &tls12.hash(p.suite, p.transcript.items));
                    var fin: [16]u8 = undefined;
                    @memcpy(fin[0..4], &[_]u8{ 20, 0, 0, 12 });
                    @memcpy(fin[4..], &server_verify);
                    p.server_finished = fin;
                },
                20 => {
                    try testing.expectEqualSlices(u8, &.{1}, payload);
                    const shared = try crypto.dh.X25519.scalarmult(server_secret, client_pub.?);
                    const session_hash = tls12.hash(p.suite, p.transcript.items);
                    master = tls12.masterSecret(p.suite, &shared, &client_random, &p.server_random, if (p.ems) &session_hash else null);
                    const k = tls12.keys(p.suite, &master, &client_random, &p.server_random);
                    p.client = k.client;
                    p.server = k.server;
                },
                else => return error.UnexpectedClientRecord,
            }
        }
        try testing.expectEqual(expect_certificate, seen_certificate);
        try testing.expect(p.server_finished != null);
    }

    fn sealed(p: *Peer, ct: u8, plain: []const u8) ![]u8 {
        const out = try a.alloc(u8, plain.len + p.server.?.overhead());
        defer a.free(out);
        try p.server.?.seal(out, ct, plain);
        return record(ct, out);
    }

    /// The server's ChangeCipherSpec and Finished.
    fn finish(p: *Peer) !void {
        const both = try p.finishRecords();
        defer a.free(both);
        try p.c.feed(both);
    }

    fn finishRecords(p: *Peer) ![]u8 {
        const ccs = [_]u8{ 20, 3, 3, 0, 1, 1 };
        const fin = try p.sealed(22, &p.server_finished.?);
        defer a.free(fin);
        return std.mem.concat(a, u8, &.{ &ccs, fin });
    }

    /// The client's next protected record.
    fn openClientRecord(p: *Peer, want_ct: u8) ![]u8 {
        const out = p.c.output();
        try testing.expectEqual(want_ct, out[0]);
        const len = std.mem.readInt(u16, out[3..5], .big);
        const plain = try a.alloc(u8, len - p.client.?.overhead());
        errdefer a.free(plain);
        try p.client.?.open(plain, want_ct, out[5..][0..len]);
        p.c.consumeOutput(5 + len);
        return plain;
    }
};

fn fullHandshake(suite: Suite12, ems: bool, chain_pem: []const u8, scheme: u16, signer: Signer, request_certificate: bool) !void {
    const p = try Peer.init(&.{});
    defer p.deinit();
    p.suite = suite;
    p.ems = ems;
    try p.standardFlight(chain_pem, scheme, signer, request_certificate);
    try testing.expect(!p.c.failed());
    try p.readClientFlight(request_certificate);
    try p.finish();
    try testing.expect(p.c.handshakeDone());
    try testing.expectEqual(session.tls12_version, p.c.negotiatedVersion());
    try testing.expectEqual(suite, p.c.negotiatedSuite12().?);

    // Application data both ways, then close_notify.
    const hello = try p.sealed(23, "hello from a TLS 1.2 server");
    defer a.free(hello);
    try p.c.feed(hello);
    try testing.expectEqualStrings("hello from a TLS 1.2 server", p.c.appData());
    p.c.consumeApp(p.c.appData().len);
    try p.c.writeApp("ping");
    const ping = try p.openClientRecord(23);
    defer a.free(ping);
    try testing.expectEqualStrings("ping", ping);
    try p.c.close();
    const bye = try p.openClientRecord(21);
    defer a.free(bye);
    try testing.expectEqualSlices(u8, &.{ 1, 0 }, bye);
}

test "the ClientHello offers TLS 1.2 beside 1.3" {
    const p = try Peer.init(&.{});
    defer p.deinit();
    const ch = p.transcript.items;
    // supported_versions lists 1.3 then 1.2.
    try testing.expect(std.mem.indexOf(u8, ch, &.{ 0, 43, 0, 5, 4, 3, 4, 3, 3 }) != null);
    try testing.expect(std.mem.indexOf(u8, ch, &.{ 0xc0, 0x2b, 0xc0, 0x2f, 0xcc, 0xa9, 0xcc, 0xa8, 0xc0, 0x2c, 0xc0, 0x30 }) != null);
    try testing.expect(std.mem.indexOf(u8, ch, &.{ 0x00, 0x17, 0, 0 }) != null);
    try testing.expect(std.mem.indexOf(u8, ch, &.{ 0xff, 0x01, 0, 1, 0 }) != null);
    try testing.expect(std.mem.indexOf(u8, ch, &.{ 0x00, 0x0b, 0, 2, 1, 0 }) != null);
}

test "TLS 1.2 handshakes with an ECDSA certificate for every ECDSA suite" {
    for ([_]Suite12{ .ecdhe_ecdsa_aes_128_gcm_sha256, .ecdhe_ecdsa_aes_256_gcm_sha384, .ecdhe_ecdsa_chacha20_poly1305_sha256 }) |suite| {
        try fullHandshake(suite, true, fixtures.server_p256, Scheme.ecdsa_secp256r1_sha256, .{ .p256 = fixtures.server_p256_key }, false);
    }
}

test "TLS 1.2 handshakes with an RSA certificate, PKCS#1 and PSS signatures" {
    for ([_]Suite12{ .ecdhe_rsa_aes_128_gcm_sha256, .ecdhe_rsa_aes_256_gcm_sha384, .ecdhe_rsa_chacha20_poly1305_sha256 }) |suite| {
        try fullHandshake(suite, true, fixtures.server_rsa, Scheme.rsa_pkcs1_sha256, .{ .pinned = &rsa_pkcs1_sha256_sig }, false);
    }
    try fullHandshake(.ecdhe_rsa_aes_128_gcm_sha256, true, fixtures.server_rsa, Scheme.rsa_pss_rsae_sha256, .{ .pinned = &rsa_pss_sha256_sig }, false);
}

test "TLS 1.2 handshakes with an Ed25519 certificate, without the extended master secret, and with a certificate request" {
    try fullHandshake(.ecdhe_ecdsa_aes_128_gcm_sha256, true, fixtures.server_ed25519, Scheme.ed25519, .{ .ed25519 = fixtures.server_ed25519_key }, false);
    try fullHandshake(.ecdhe_ecdsa_chacha20_poly1305_sha256, false, fixtures.server_p256, Scheme.ecdsa_secp256r1_sha256, .{ .p256 = fixtures.server_p256_key }, false);
    try fullHandshake(.ecdhe_rsa_aes_256_gcm_sha384, false, fixtures.server_rsa, Scheme.rsa_pkcs1_sha256, .{ .pinned = &rsa_pkcs1_sha256_sig }, true);
}

// ---- alerts -----------------------------------------------------------------

fn expectFailure(c: *const Session, alert: Alert, reason: []const u8) !void {
    const f = c.failure() orelse return error.NoFailure;
    if (f.alert != alert or !std.mem.eql(u8, f.reason, reason)) {
        std.debug.print("expected {s} ({s}), got {s} ({s})\n", .{ @tagName(alert), reason, @tagName(f.alert), f.reason });
        return error.TestUnexpectedResult;
    }
    try testing.expect(f.local);
}

fn helloRefused(offer: []const Suite12, version: u16, random: [32]u8, suite: u16, compression: u8, extensions: []const u8, alert: Alert, reason: []const u8) !void {
    const p = try Peer.init(offer);
    defer p.deinit();
    const body = try serverHelloBody(version, random, suite, compression, extensions);
    defer a.free(body);
    const msg = try handshake(2, body);
    defer a.free(msg);
    const rec = try record(22, msg);
    defer a.free(rec);
    try testing.expectError(error.TlsFailure, p.c.feed(rec));
    try expectFailure(&p.c, alert, reason);
}

test "a TLS 1.2 ServerHello is checked field by field" {
    const good = &good_hello_extensions;
    const r = default_server_random;
    var downgrade = r;
    @memcpy(downgrade[24..], "DOWNGRD\x01");
    try helloRefused(&.{}, 0x0303, downgrade, 0xc02b, 0, good, .illegal_parameter, "the server downgraded a TLS 1.3 connection");
    @memcpy(downgrade[24..], "DOWNGRD\x00");
    try helloRefused(&.{}, 0x0303, downgrade, 0xc02b, 0, good, .illegal_parameter, "the server downgraded a TLS 1.3 connection");
    try helloRefused(&.{}, 0x0302, r, 0xc02b, 0, good, .protocol_version, "the server does not speak TLS 1.2 or 1.3");
    try helloRefused(&.{.ecdhe_ecdsa_aes_128_gcm_sha256}, 0x0303, r, 0xc02f, 0, good, .illegal_parameter, "the server selected a cipher suite that was not offered");
    // TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA: a CBC suite, never offered.
    try helloRefused(&.{}, 0x0303, r, 0xc009, 0, good, .illegal_parameter, "the server selected an unknown cipher suite");
    try helloRefused(&.{}, 0x0303, r, 0xc02b, 1, good, .illegal_parameter, "ServerHello selected compression");
    try helloRefused(&.{}, 0x0303, r, 0xc02b, 0, &.{ 0xff, 0x01, 0, 2, 1, 7 }, .handshake_failure, "renegotiation_info is not empty");
    try helloRefused(&.{}, 0x0303, r, 0xc02b, 0, &.{ 0x00, 0x0b, 0, 2, 1, 1 }, .illegal_parameter, "the server does not accept uncompressed points");
    try helloRefused(&.{}, 0x0303, r, 0xc02b, 0, &.{ 0x00, 0x17, 0, 1, 0 }, .decode_error, "non-empty extended_master_secret");
    // ALPN and a TLS 1.3 key_share were not offered for TLS 1.2.
    try helloRefused(&.{}, 0x0303, r, 0xc02b, 0, &.{ 0x00, 0x10, 0, 5, 0, 3, 2, 'h', '2' }, .unsupported_extension, "ServerHello carries an extension that was not offered");
    try helloRefused(&.{}, 0x0303, r, 0xc02b, 0, &.{ 0x00, 0x33, 0, 2, 0, 0x1d }, .unsupported_extension, "ServerHello carries an extension that was not offered");
}

/// Sends ServerHello and then `rest` (whole handshake messages), expecting
/// the client to refuse with `alert`.
fn flightRefused(suite: Suite12, rest: []const []const u8, alert: Alert, reason: []const u8) !void {
    const p = try Peer.init(&.{});
    defer p.deinit();
    p.suite = suite;
    const sh = try p.serverHello();
    defer a.free(sh);
    const msgs = try a.alloc([]const u8, rest.len + 1);
    defer a.free(msgs);
    msgs[0] = sh;
    @memcpy(msgs[1..], rest);
    try testing.expectError(error.TlsFailure, p.sendPlain(msgs));
    try expectFailure(&p.c, alert, reason);
}

test "the certificate, ServerKeyExchange and ServerHelloDone are checked" {
    const p256_cert_body = try certificateBody(fixtures.server_p256);
    defer a.free(p256_cert_body);
    const p256_cert = try handshake(11, p256_cert_body);
    defer a.free(p256_cert);
    const signer: Signer = .{ .p256 = fixtures.server_p256_key };
    const ske_good_body = try serverKeyExchangeBody(default_server_random, &server_public, Scheme.ecdsa_secp256r1_sha256, signer);
    defer a.free(ske_good_body);
    const shd = try handshake(14, "");
    defer a.free(shd);

    // An EC certificate for an RSA suite.
    try flightRefused(.ecdhe_rsa_aes_128_gcm_sha256, &.{p256_cert}, .unsupported_certificate, "the server certificate's key does not match the cipher suite");
    // ServerHelloDone before the ServerKeyExchange.
    try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, shd }, .unexpected_message, "expected ServerKeyExchange");

    {
        var bad = try a.dupe(u8, ske_good_body);
        defer a.free(bad);
        bad[0] = 1; // explicit_prime curve parameters
        const ske = try handshake(12, bad);
        defer a.free(ske);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske }, .illegal_parameter, "ServerKeyExchange does not name a curve");
    }
    {
        var bad = try a.dupe(u8, ske_good_body);
        defer a.free(bad);
        bad[2] = 0x19; // secp521r1
        const ske = try handshake(12, bad);
        defer a.free(ske);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske }, .illegal_parameter, "ServerKeyExchange uses a group that was not offered");
    }
    {
        var bad = try a.dupe(u8, ske_good_body);
        defer a.free(bad);
        bad[bad.len - 3] ^= 1; // inside the DER signature
        const ske = try handshake(12, bad);
        defer a.free(ske);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske }, .decrypt_error, "ServerKeyExchange signature is invalid");
    }
    {
        // The signature of another point.
        const other = try serverKeyExchangeBody(default_server_random, &([_]u8{9} ** 32), Scheme.ecdsa_secp256r1_sha256, signer);
        defer a.free(other);
        var bad = try a.dupe(u8, ske_good_body);
        defer a.free(bad);
        @memcpy(bad[4..36], other[4..36]);
        const ske = try handshake(12, bad);
        defer a.free(ske);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske }, .decrypt_error, "ServerKeyExchange signature is invalid");
    }
    {
        // rsa_pkcs1_sha256 is offered, but the key is EC.
        const body = try serverKeyExchangeBody(default_server_random, &server_public, Scheme.rsa_pkcs1_sha256, .{ .pinned = &rsa_pkcs1_sha256_sig });
        defer a.free(body);
        const ske = try handshake(12, body);
        defer a.free(ske);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske }, .illegal_parameter, "ServerKeyExchange scheme does not match the certificate key");
    }
    {
        // rsa_pkcs1_sha1 is not offered.
        const body = try serverKeyExchangeBody(default_server_random, &server_public, 0x0201, signer);
        defer a.free(body);
        const ske = try handshake(12, body);
        defer a.free(ske);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske }, .illegal_parameter, "ServerKeyExchange uses a signature scheme that was not offered");
    }
    {
        // A low-order point: X25519 gives the all-zero secret.
        const body = try serverKeyExchangeBody(default_server_random, &([_]u8{0} ** 32), Scheme.ecdsa_secp256r1_sha256, signer);
        defer a.free(body);
        const ske = try handshake(12, body);
        defer a.free(ske);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske }, .illegal_parameter, "invalid ECDHE point");
    }
    {
        const ske = try handshake(12, ske_good_body);
        defer a.free(ske);
        const fin = try handshake(20, &([_]u8{0} ** 12));
        defer a.free(fin);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske, fin }, .unexpected_message, "expected ServerHelloDone");
        const bad_shd = try handshake(14, &.{0});
        defer a.free(bad_shd);
        try flightRefused(.ecdhe_ecdsa_aes_128_gcm_sha256, &.{ p256_cert, ske, bad_shd }, .decode_error, "ServerHelloDone has a body");
    }
}

/// A handshake up to the client's Finished, ready for the server's reply.
fn upToServerFinished(suite: Suite12) !*Peer {
    const p = try Peer.init(&.{});
    errdefer p.deinit();
    p.suite = suite;
    try p.standardFlight(fixtures.server_p256, Scheme.ecdsa_secp256r1_sha256, .{ .p256 = fixtures.server_p256_key }, false);
    try p.readClientFlight(false);
    return p;
}

test "the server's ChangeCipherSpec and Finished are checked" {
    {
        // Finished before ChangeCipherSpec: unprotected, in the wrong state.
        const p = try upToServerFinished(.ecdhe_ecdsa_aes_128_gcm_sha256);
        defer p.deinit();
        const rec = try record(22, &p.server_finished.?);
        defer a.free(rec);
        try testing.expectError(error.TlsFailure, p.c.feed(rec));
        try expectFailure(&p.c, .unexpected_message, "expected ChangeCipherSpec");
    }
    {
        const p = try upToServerFinished(.ecdhe_ecdsa_aes_256_gcm_sha384);
        defer p.deinit();
        p.server_finished.?[5] ^= 1;
        try testing.expectError(error.TlsFailure, p.finish());
        try expectFailure(&p.c, .decrypt_error, "server Finished does not verify");
    }
    {
        const p = try upToServerFinished(.ecdhe_ecdsa_chacha20_poly1305_sha256);
        defer p.deinit();
        const ccs = [_]u8{ 20, 3, 3, 0, 1, 1 };
        try p.c.feed(&ccs);
        const fin = try p.sealed(22, &p.server_finished.?);
        defer a.free(fin);
        fin[fin.len - 1] ^= 1;
        try testing.expectError(error.TlsFailure, p.c.feed(fin));
        try expectFailure(&p.c, .bad_record_mac, "record authentication failed");
    }
    {
        // A ChangeCipherSpec before ServerHelloDone.
        const p = try Peer.init(&.{});
        defer p.deinit();
        const sh = try p.serverHello();
        defer a.free(sh);
        try p.sendPlain(&.{sh});
        try testing.expectError(error.TlsFailure, p.c.feed(&.{ 20, 3, 3, 0, 1, 1 }));
        try expectFailure(&p.c, .unexpected_message, "unexpected change_cipher_spec");
    }
}

test "after a TLS 1.2 handshake: renegotiation is refused, warnings are ignored, a fatal alert ends it" {
    const p = try upToServerFinished(.ecdhe_ecdsa_aes_128_gcm_sha256);
    defer p.deinit();
    try p.finish();
    try testing.expect(p.c.handshakeDone());

    // HelloRequest: a no_renegotiation warning, and the connection goes on.
    const hr = try p.sealed(22, &.{ 0, 0, 0, 0 });
    defer a.free(hr);
    try p.c.feed(hr);
    const warning = try p.openClientRecord(21);
    defer a.free(warning);
    try testing.expectEqualSlices(u8, &.{ 1, 100 }, warning);

    // A warning from the server is ignored.
    const warn = try p.sealed(21, &.{ 1, 100 });
    defer a.free(warn);
    try p.c.feed(warn);
    try testing.expect(!p.c.failed());
    const data = try p.sealed(23, "still here");
    defer a.free(data);
    try p.c.feed(data);
    try testing.expectEqualStrings("still here", p.c.appData());

    // TLS 1.2 has no KeyUpdate.
    try testing.expectError(error.TlsFailure, p.c.requestKeyUpdate());

    const fatal = try p.sealed(21, &.{ 2, 40 });
    defer a.free(fatal);
    p.c.feed(fatal) catch {};
    try testing.expect(p.c.failed());
    const f = p.c.failure().?;
    try testing.expectEqual(Alert.handshake_failure, f.alert);
    try testing.expect(!f.local);
}

// ---- fuzz -------------------------------------------------------------------

fn iterations(default: usize) usize {
    const raw = std.c.getenv("KTOR_TLS_FUZZ_ITERATIONS") orelse return default;
    return std.fmt.parseInt(usize, std.mem.span(raw), 10) catch default;
}

fn feedIgnoringFailure(s: *Session, bytes: []const u8) !void {
    s.feed(bytes) catch |e| switch (e) {
        error.TlsFailure => {},
        else => return e,
    };
}

const Mutation = enum { flip, truncate, insert, drop, duplicate, split };

fn deliverMutated(c: *Session, original: []const u8, m: Mutation, r: std.Random) !void {
    const bytes = try a.dupe(u8, original);
    defer a.free(bytes);
    switch (m) {
        .flip => {
            bytes[r.uintLessThan(usize, bytes.len)] ^= @as(u8, 1) << r.int(u3);
            try feedIgnoringFailure(c, bytes);
        },
        .truncate => try feedIgnoringFailure(c, bytes[0..r.uintLessThan(usize, bytes.len)]),
        .insert => {
            var junk: [40]u8 = undefined;
            r.bytes(&junk);
            const at = r.uintLessThan(usize, bytes.len);
            try feedIgnoringFailure(c, bytes[0..at]);
            try feedIgnoringFailure(c, junk[0 .. 1 + r.uintLessThan(usize, junk.len - 1)]);
            try feedIgnoringFailure(c, bytes[at..]);
        },
        .drop => {},
        .duplicate => {
            try feedIgnoringFailure(c, bytes);
            try feedIgnoringFailure(c, bytes);
        },
        .split => {
            const at = r.uintLessThan(usize, bytes.len);
            try feedIgnoringFailure(c, bytes[0..at]);
            try feedIgnoringFailure(c, bytes[at..]);
        },
    }
    if (c.failed()) {
        try testing.expect(c.failure() != null);
        try testing.expectError(error.TlsFailure, c.feed(&.{ 23, 3, 3, 0, 0 }));
    }
}

/// A TLS 1.2 handshake whose delivery `target` (the first flight, the
/// ChangeCipherSpec and Finished, or application data) is corrupted. The
/// client must complete, refuse with a reason, or wait; a split delivery
/// must still work.
fn mutatedRun12(suite: Suite12, target: usize, m: Mutation, r: std.Random) !void {
    const p = try Peer.init(&.{});
    defer p.deinit();
    p.suite = suite;
    const signer: Signer, const chain, const scheme = if (suite.rsa())
        .{ .{ .pinned = &rsa_pkcs1_sha256_sig }, fixtures.server_rsa, Scheme.rsa_pkcs1_sha256 }
    else
        .{ .{ .p256 = fixtures.server_p256_key }, fixtures.server_p256, Scheme.ecdsa_secp256r1_sha256 };
    const flight = try p.firstFlight(chain, scheme, signer, false);
    defer a.free(flight);
    if (target == 0) {
        try deliverMutated(&p.c, flight, m, r);
        if (m == .split) try testing.expect(p.c.output().len > 0);
        return;
    }
    try p.c.feed(flight);
    try p.readClientFlight(false);
    const fin = try p.finishRecords();
    defer a.free(fin);
    if (target == 1) {
        try deliverMutated(&p.c, fin, m, r);
        if (m == .split) try testing.expect(p.c.handshakeDone());
        return;
    }
    try p.c.feed(fin);
    const data = try p.sealed(23, "application data after the handshake");
    defer a.free(data);
    try deliverMutated(&p.c, data, m, r);
    if (m == .split) try testing.expectEqualStrings("application data after the handshake", p.c.appData());
}

test "a TLS 1.2 handshake with one corrupted delivery refuses cleanly" {
    var prng = std.Random.DefaultPrng.init(0x1212);
    const r = prng.random();
    const all = std.enums.values(Suite12);
    for (0..iterations(300)) |i| {
        const m = std.enums.values(Mutation)[i % std.enums.values(Mutation).len];
        try mutatedRun12(all[(i / 6) % all.len], r.uintLessThan(usize, 3), m, r);
    }
}

test "random records against a client that negotiated TLS 1.2" {
    // Past the ServerHello, the client is in the TLS 1.2 states.
    var prng = std.Random.DefaultPrng.init(0x3c1a);
    const r = prng.random();
    var buf: [1024]u8 = undefined;
    for (0..iterations(1000)) |_| {
        const p = try Peer.init(&.{});
        defer p.deinit();
        const sh = try p.serverHello();
        defer a.free(sh);
        try p.sendPlain(&.{sh});
        const len = 1 + r.uintLessThan(usize, buf.len - 1);
        r.bytes(buf[0..len]);
        if (len >= 5 and r.boolean()) {
            buf[0] = 20 + r.uintLessThan(u8, 4);
            buf[1] = 3;
            buf[2] = 3;
            std.mem.writeInt(u16, buf[3..5], @intCast(len - 5), .big);
            if (buf[0] == 22 and len >= 9) {
                buf[5] = r.uintLessThan(u8, 21);
                std.mem.writeInt(u24, buf[6..9], @intCast(len - 9), .big);
            }
        }
        try deliverMutated(&p.c, buf[0..len], .split, r);
    }
}
