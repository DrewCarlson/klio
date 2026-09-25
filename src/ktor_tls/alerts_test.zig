//! One test per alert path. Each case drives a session with bytes a
//! misbehaving peer could send and checks the alert and reason the session
//! fails with. Encrypted messages come from scripted peers that derive the
//! handshake keys themselves from pinned ephemeral keys.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const X25519 = crypto.dh.X25519;

const session = @import("session.zig");
const suites = @import("suites.zig");
const wire = @import("wire.zig");
const tests = @import("tests.zig");

const Session = session.Session;
const Alert = session.AlertDescription;
const ET = session.ExtensionType;

const a = testing.allocator;

// ---- building messages ----------------------------------------------------

const Bytes = std.ArrayList(u8);

fn cat(parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}

fn u16be(v: u16) [2]u8 {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    return b;
}

fn u24be(v: u24) [3]u8 {
    var b: [3]u8 = undefined;
    std.mem.writeInt(u24, &b, v, .big);
    return b;
}

fn vec8(d: []const u8) ![]u8 {
    return cat(&.{ &.{@intCast(d.len)}, d });
}

fn vec16(d: []const u8) ![]u8 {
    return cat(&.{ &u16be(@intCast(d.len)), d });
}

fn ext(t: u16, d: []const u8) ![]u8 {
    return cat(&.{ &u16be(t), &u16be(@intCast(d.len)), d });
}

fn handshakeMsg(ht: u8, body: []const u8) ![]u8 {
    return cat(&.{ &.{ht}, &u24be(@intCast(body.len)), body });
}

fn record(ct: u8, payload: []const u8) ![]u8 {
    return cat(&.{ &.{ ct, 3, 3 }, &u16be(@intCast(payload.len)), payload });
}

/// Frees a list of owned slices at scope end.
const Arena = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Arena {
        return .{ .arena = .init(a) };
    }

    fn deinit(self: *Arena) void {
        self.arena.deinit();
    }

    fn keep(self: *Arena, b: []u8) ![]const u8 {
        const copy = try self.arena.allocator().dupe(u8, b);
        a.free(b);
        return copy;
    }
};

// ---- the pinned keys --------------------------------------------------------

const client_secret: [32]u8 = @splat(0x21);
const server_secret: [32]u8 = @splat(0x42);
const client_random: [32]u8 = @splat(0x11);
const server_random: [32]u8 = @splat(0x22);

fn pub25519(sk: [32]u8) [32]u8 {
    return X25519.recoverPublicKey(sk) catch unreachable;
}

// ---- server under test --------------------------------------------------------

const ServerCase = struct {
    env: tests.Env,
    cfg: session.ServerConfig,
    s: Session,

    fn init() !*ServerCase {
        const c = try a.create(ServerCase);
        errdefer a.destroy(c);
        c.env = try .init(a);
        c.cfg = .{ .identity = &c.env.p256.identity, .hooks = .{ .random = server_random, .x25519_secret = server_secret } };
        c.s = Session.initServer(a, &c.cfg, @splat(9));
        return c;
    }

    fn deinit(c: *ServerCase) void {
        c.s.deinit();
        c.env.deinit();
        a.destroy(c);
    }
};

/// The default ClientHello extensions, each replaceable by type or droppable.
const HelloExts = struct {
    versions: ?[]const u8 = &.{ 2, 0x03, 0x04 },
    groups: ?[]const u8 = &.{ 0, 2, 0x00, 0x1d },
    shares: ?[]const u8 = null,
    sig_algs: ?[]const u8 = &.{ 0, 4, 0x04, 0x03, 0x08, 0x07 },
    extra_first: []const []const u8 = &.{},
    extra_last: []const []const u8 = &.{},
};

fn defaultShares() ![]u8 {
    const pk = pub25519(client_secret);
    const entry = try cat(&.{ &u16be(0x001d), &u16be(32), &pk });
    defer a.free(entry);
    return vec16(entry);
}

fn helloExtensions(e: HelloExts) ![]u8 {
    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |p| a.free(p);
        parts.deinit(a);
    }
    for (e.extra_first) |x| try parts.append(a, try a.dupe(u8, x));
    if (e.versions) |v| try parts.append(a, try ext(ET.supported_versions, v));
    if (e.groups) |g| try parts.append(a, try ext(ET.supported_groups, g));
    const shares = if (e.shares) |s| try a.dupe(u8, s) else try defaultShares();
    defer a.free(shares);
    if (e.shares == null or e.shares.?.len != 0) try parts.append(a, try ext(ET.key_share, shares));
    if (e.sig_algs) |s| try parts.append(a, try ext(ET.signature_algorithms, s));
    for (e.extra_last) |x| try parts.append(a, try a.dupe(u8, x));
    return std.mem.concat(a, u8, parts.items);
}

const Hello = struct {
    version: u16 = 0x0303,
    session_id: []const u8 = "",
    suites: []const u8 = &.{ 0x13, 0x01 },
    compression: []const u8 = &.{0},
    /// Null leaves the extension block out entirely.
    extensions: ?[]const u8,
};

fn clientHelloMsg(h: Hello) ![]u8 {
    const sid = try vec8(h.session_id);
    defer a.free(sid);
    const cs = try vec16(h.suites);
    defer a.free(cs);
    const comp = try vec8(h.compression);
    defer a.free(comp);
    const ext_block = if (h.extensions) |e| try vec16(e) else try a.alloc(u8, 0);
    defer a.free(ext_block);
    const body = try cat(&.{ &u16be(h.version), &client_random, sid, cs, comp, ext_block });
    defer a.free(body);
    return handshakeMsg(1, body);
}

fn expectFailure(s: *const Session, alert: Alert, reason: []const u8) !void {
    const f = s.failure() orelse {
        std.debug.print("expected {t} ({s}), the session did not fail\n", .{ alert, reason });
        return error.TestUnexpectedResult;
    };
    if (f.alert != alert or !std.mem.eql(u8, f.reason, reason)) {
        std.debug.print("expected {t} ({s}), got {t} ({s})\n", .{ alert, reason, f.alert, f.reason });
        return error.TestUnexpectedResult;
    }
    try testing.expect(f.local);
    try testing.expect(s.failed());
}

/// Feeds a ClientHello built from `h` and expects the server to fail.
fn serverRefuses(h: Hello, alert: Alert, reason: []const u8) !void {
    const c = try ServerCase.init();
    defer c.deinit();
    const msg = try clientHelloMsg(h);
    defer a.free(msg);
    const rec = try record(22, msg);
    defer a.free(rec);
    try testing.expectError(error.TlsFailure, c.s.feed(rec));
    try expectFailure(&c.s, alert, reason);
    // A plaintext alert went out: level 2 and the description.
    const out = c.s.output();
    try testing.expectEqualSlices(u8, &.{ 21, 3, 3, 0, 2, 2, @intFromEnum(alert) }, out[out.len - 7 ..]);
}

fn exts(e: HelloExts) ![]u8 {
    return helloExtensions(e);
}

test "server: ClientHello framing" {
    var ar = Arena.init();
    defer ar.deinit();
    const good = try ar.keep(try exts(.{}));
    try serverRefuses(.{ .compression = &.{1}, .extensions = good }, .illegal_parameter, "ClientHello offers compression");
    try serverRefuses(.{ .compression = &.{ 0, 1 }, .extensions = good }, .illegal_parameter, "ClientHello offers compression");
    try serverRefuses(.{ .extensions = null }, .protocol_version, "the client does not speak TLS 1.3");
    try serverRefuses(.{ .session_id = &([_]u8{1} ** 33), .extensions = good }, .decode_error, "ClientHello session id longer than 32 bytes");
    try serverRefuses(.{ .suites = &.{0x13}, .extensions = good }, .decode_error, "malformed cipher suite list");
    try serverRefuses(.{ .suites = &.{}, .extensions = good }, .decode_error, "malformed cipher suite list");
    try serverRefuses(.{ .suites = &.{ 0x13, 0x04 }, .extensions = good }, .handshake_failure, "no cipher suite in common");

    // Truncated and padded bodies.
    const c = try ServerCase.init();
    defer c.deinit();
    const full = try clientHelloMsg(.{ .extensions = good });
    defer a.free(full);
    const cut = try handshakeMsg(1, full[4..40]);
    defer a.free(cut);
    const rec = try record(22, cut);
    defer a.free(rec);
    try testing.expectError(error.TlsFailure, c.s.feed(rec));
    try expectFailure(&c.s, .decode_error, "truncated ClientHello");

    const c2 = try ServerCase.init();
    defer c2.deinit();
    const padded = try handshakeMsg(1, try ar.keep(try cat(&.{ full[4..], &.{0} })));
    defer a.free(padded);
    const rec2 = try record(22, padded);
    defer a.free(rec2);
    try testing.expectError(error.TlsFailure, c2.s.feed(rec2));
    try expectFailure(&c2.s, .decode_error, "trailing bytes in ClientHello");
}

test "server: ClientHello extensions" {
    var ar = Arena.init();
    defer ar.deinit();
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .versions = null })) }, .protocol_version, "the client does not speak TLS 1.3");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .versions = &.{ 2, 0x03, 0x03 } })) }, .protocol_version, "the client does not speak TLS 1.3");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .versions = &.{ 3, 0x03, 0x04, 0x03 } })) }, .decode_error, "malformed supported_versions");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .groups = null })) }, .missing_extension, "ClientHello has no supported_groups");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .shares = &.{} })) }, .missing_extension, "ClientHello has no key_share");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .sig_algs = null })) }, .missing_extension, "ClientHello has no signature_algorithms");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .sig_algs = &.{ 0, 2, 0x08, 0x04 } })) }, .handshake_failure, "the client does not accept our certificate's signature scheme");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .sig_algs = &.{ 0, 3, 0x08, 0x04, 0 } })) }, .decode_error, "malformed signature_algorithms");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .groups = &.{ 0, 1, 0x1d } })) }, .decode_error, "malformed supported_groups");
    // A share for a group the client does not list.
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .groups = &.{ 0, 2, 0x00, 0x17 } })) }, .illegal_parameter, "key share for a group not in supported_groups");
    // Only ffdhe groups in common with nothing we support.
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .groups = &.{ 0, 2, 0x01, 0x00 }, .shares = try ar.keep(try vec16(&.{ 0x01, 0x00, 0, 1, 5 })) })) }, .handshake_failure, "no key exchange group in common");
    const pk = pub25519(client_secret);
    const two = try ar.keep(try vec16(try ar.keep(try cat(&.{ &.{ 0, 0x1d, 0, 32 }, &pk, &.{ 0, 0x1d, 0, 32 }, &pk }))));
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .shares = two })) }, .illegal_parameter, "two key shares for one group");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .shares = try ar.keep(try vec16(&.{ 0, 0x1d, 0, 0 })) })) }, .decode_error, "empty key share");
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .shares = try ar.keep(try vec16(&.{ 0, 0x1d, 0, 5, 1 })) })) }, .decode_error, "malformed key_share");
    const zero_share = try ar.keep(try vec16(try ar.keep(try cat(&.{ &.{ 0, 0x1d, 0, 32 }, &([_]u8{0} ** 32) }))));
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .shares = zero_share })) }, .illegal_parameter, "invalid key share");
    const dup = try ar.keep(try ext(ET.supported_versions, &.{ 2, 0x03, 0x04 }));
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .extra_last = &.{dup} })) }, .illegal_parameter, "duplicate extension");
    const psk = try ar.keep(try ext(ET.pre_shared_key, &.{ 0, 0 }));
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .extra_first = &.{psk} })) }, .illegal_parameter, "pre_shared_key is not the last extension");
    try serverRefuses(.{ .extensions = &.{ 0, 43, 0, 9 } }, .decode_error, "truncated extension");
    const sni = try ar.keep(try ext(ET.server_name, &.{ 0, 5, 0, 0, 9 }));
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .extra_last = &.{sni} })) }, .decode_error, "malformed server_name");
    var many: [33][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = try ar.keep(try ext(@intCast(0x7000 + i), ""));
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .extra_last = &many })) }, .illegal_parameter, "too many extensions");
    var shares_many: Bytes = .empty;
    defer shares_many.deinit(a);
    for (0..9) |i| try shares_many.appendSlice(a, &.{ 0x7a, @intCast(i), 0, 1, 1 });
    var groups_many: Bytes = .empty;
    defer groups_many.deinit(a);
    try groups_many.appendSlice(a, &u16be(18));
    for (0..9) |i| try groups_many.appendSlice(a, &.{ 0x7a, @intCast(i) });
    try serverRefuses(.{ .extensions = try ar.keep(try exts(.{ .groups = groups_many.items, .shares = try ar.keep(try vec16(shares_many.items)) })) }, .illegal_parameter, "too many key shares");
}

// ---- records, as seen by either side -----------------------------------------

fn feedServer(bytes: []const u8) !*ServerCase {
    const c = try ServerCase.init();
    errdefer c.deinit();
    try testing.expectError(error.TlsFailure, c.s.feed(bytes));
    return c;
}

test "records: framing and content types before the handshake" {
    var ar = Arena.init();
    defer ar.deinit();
    const good_exts = try ar.keep(try exts(.{}));
    const hello = try ar.keep(try clientHelloMsg(.{ .extensions = good_exts }));
    const cases = [_]struct { bytes: []const u8, alert: Alert, reason: []const u8 }{
        .{ .bytes = &.{ 22, 2, 0, 0, 1, 1 }, .alert = .protocol_version, .reason = "record version is not TLS" },
        .{ .bytes = &([_]u8{ 22, 3, 3, 0x40, 0x01 } ++ [_]u8{0} ** 0x4001), .alert = .record_overflow, .reason = "record longer than the limit" },
        .{ .bytes = &.{ 23, 3, 3, 0, 1, 0 }, .alert = .unexpected_message, .reason = "unprotected application data" },
        .{ .bytes = &.{ 22, 3, 3, 0, 0 }, .alert = .unexpected_message, .reason = "empty handshake record" },
        .{ .bytes = &.{ 30, 3, 3, 0, 1, 0 }, .alert = .unexpected_message, .reason = "unknown record type" },
        .{ .bytes = &.{ 20, 3, 3, 0, 1, 1 }, .alert = .unexpected_message, .reason = "change_cipher_spec before ClientHello" },
        .{ .bytes = &.{ 21, 3, 3, 0, 3, 2, 40, 0 }, .alert = .decode_error, .reason = "malformed alert" },
        .{ .bytes = &.{ 22, 3, 3, 0, 4, 20, 0, 0, 0 }, .alert = .unexpected_message, .reason = "expected ClientHello" },
        .{ .bytes = &.{ 22, 3, 3, 0, 4, 1, 0x03, 0, 0 }, .alert = .illegal_parameter, .reason = "handshake message too large" },
    };
    for (cases) |cs| {
        const c = try feedServer(cs.bytes);
        defer c.deinit();
        try expectFailure(&c.s, cs.alert, cs.reason);
    }
    // An alert that interrupts a fragmented handshake message.
    {
        const first = try ar.keep(try record(22, hello[0..10]));
        const alert = try ar.keep(try record(21, &.{ 1, 0 }));
        const c = try ServerCase.init();
        defer c.deinit();
        try c.s.feed(first);
        try testing.expectError(error.TlsFailure, c.s.feed(alert));
        try expectFailure(&c.s, .unexpected_message, "alert inside a handshake message");
    }
    // A malformed change_cipher_spec once the handshake has begun.
    {
        const c = try ServerCase.init();
        defer c.deinit();
        try c.s.feed(try ar.keep(try record(22, hello)));
        try testing.expectError(error.TlsFailure, c.s.feed(&.{ 20, 3, 3, 0, 1, 2 }));
        try expectFailure(&c.s, .unexpected_message, "malformed change_cipher_spec");
    }
}

// ---- a scripted server for the client under test ------------------------------

const ClientCase = struct {
    env: tests.Env,
    cfg: session.ClientConfig,
    c: Session,
    /// The ClientHello message the client sent (for the transcript).
    hello: []u8,
    transcript: Bytes = .empty,
    server_hs: suites.Secret = .{},
    client_hs: suites.Secret = .{},
    master: suites.Secret = .{},
    writer: ?suites.Cipher = null,

    fn init(verify_host: bool) !*ClientCase {
        const k = try a.create(ClientCase);
        errdefer a.destroy(k);
        k.env = try .init(a);
        errdefer k.env.deinit();
        k.cfg = if (verify_host) k.env.trust("localhost") else .{ .server_name = "localhost", .verification = .insecure_accept_any };
        k.cfg.cipher_suites = &.{.aes_128_gcm_sha256};
        // A TLS 1.3 peer; the TLS 1.2 cases have their own.
        k.cfg.tls12_suites = &.{};
        k.cfg.compat_mode = false;
        k.cfg.hooks = .{ .random = client_random, .x25519_secret = client_secret };
        k.c = try Session.initClient(a, &k.cfg, @splat(5));
        const out = k.c.output();
        k.hello = try a.dupe(u8, out[5..]);
        k.c.consumeOutput(out.len);
        k.transcript = .empty;
        try k.transcript.appendSlice(a, k.hello);
        k.server_hs = .{};
        k.client_hs = .{};
        k.master = .{};
        k.writer = null;
        return k;
    }

    fn deinit(k: *ClientCase) void {
        k.c.deinit();
        a.free(k.hello);
        k.transcript.deinit(a);
        k.env.deinit();
        a.destroy(k);
    }

    fn serverHelloBody(sid: []const u8, suite: u16, extensions: []const u8) ![]u8 {
        const s = try vec8(sid);
        defer a.free(s);
        const e = try vec16(extensions);
        defer a.free(e);
        return cat(&.{ &.{ 3, 3 }, &server_random, s, &u16be(suite), &.{0}, e });
    }

    fn goodServerHelloExts() ![]u8 {
        const pk = pub25519(server_secret);
        const ks = try ext(ET.key_share, &([_]u8{ 0, 0x1d, 0, 32 } ++ pk));
        defer a.free(ks);
        const sv = try ext(ET.supported_versions, &.{ 3, 4 });
        defer a.free(sv);
        return cat(&.{ ks, sv });
    }

    /// Sends a valid ServerHello and derives the handshake keys.
    fn acceptHello(k: *ClientCase) !void {
        const e = try goodServerHelloExts();
        defer a.free(e);
        const body = try serverHelloBody("", 0x1301, e);
        defer a.free(body);
        const msg = try handshakeMsg(2, body);
        defer a.free(msg);
        const rec = try record(22, msg);
        defer a.free(rec);
        try k.c.feed(rec);
        try k.transcript.appendSlice(a, msg);
        const shared = try X25519.scalarmult(server_secret, pub25519(client_secret));
        const suite: suites.Suite = .aes_128_gcm_sha256;
        const hs = suites.handshakeSecret(suite, &shared);
        const h = suites.hash(suite, k.transcript.items);
        k.server_hs = suites.deriveSecret(suite, &hs, "s hs traffic", &h);
        k.client_hs = suites.deriveSecret(suite, &hs, "c hs traffic", &h);
        k.master = suites.masterSecret(suite, &hs);
        k.writer = .init(suite, k.server_hs);
    }

    /// A protected record carrying `inner_ct` content.
    fn protect(k: *ClientCase, inner_ct: u8, content: []const u8) ![]u8 {
        const inner = try cat(&.{ content, &.{inner_ct} });
        defer a.free(inner);
        return sealed(&k.writer.?, inner);
    }

    fn sendProtected(k: *ClientCase, inner_ct: u8, content: []const u8) !void {
        const rec = try k.protect(inner_ct, content);
        defer a.free(rec);
        k.c.feed(rec) catch |e| switch (e) {
            error.TlsFailure => {},
            else => return e,
        };
    }

    fn handshake(k: *ClientCase, msg: []const u8) !void {
        try k.transcript.appendSlice(a, msg);
        try k.sendProtected(22, msg);
    }

    fn encryptedExtensions(k: *ClientCase) !void {
        try k.handshake(&.{ 8, 0, 0, 2, 0, 0 });
    }

    fn certificate(k: *ClientCase) !void {
        const der = k.env.p256.identity.chain[0];
        const entry = try cat(&.{ &u24be(@intCast(der.len)), der, &.{ 0, 0 } });
        defer a.free(entry);
        const body = try cat(&.{ &.{0}, &u24be(@intCast(entry.len)), entry });
        defer a.free(body);
        const msg = try handshakeMsg(11, body);
        defer a.free(msg);
        try k.handshake(msg);
    }

    fn certificateVerify(k: *ClientCase, scheme: u16, corrupt: bool) !void {
        const suite: suites.Suite = .aes_128_gcm_sha256;
        const h = suites.hash(suite, k.transcript.items);
        var content: [200]u8 = undefined;
        @memset(content[0..64], 0x20);
        const ctx = "TLS 1.3, server CertificateVerify";
        @memcpy(content[64..][0..ctx.len], ctx);
        content[64 + ctx.len] = 0;
        @memcpy(content[65 + ctx.len ..][0..32], h.slice());
        const signed = content[0 .. 65 + ctx.len + 32];
        const sig = try k.env.p256.identity.key.p256.sign(signed, null);
        var der_buf: [72]u8 = undefined;
        const der = sig.toDer(&der_buf);
        if (corrupt) der[der.len - 1] ^= 1;
        const body = try cat(&.{ &u16be(scheme), &u16be(@intCast(der.len)), der });
        defer a.free(body);
        const msg = try handshakeMsg(15, body);
        defer a.free(msg);
        try k.handshake(msg);
    }

    fn finished(k: *ClientCase, corrupt: bool) !void {
        const suite: suites.Suite = .aes_128_gcm_sha256;
        const h = suites.hash(suite, k.transcript.items);
        var v = suites.finishedData(suite, &k.server_hs, &h);
        if (corrupt) v.bytes[0] ^= 1;
        const msg = try handshakeMsg(20, v.slice());
        defer a.free(msg);
        try k.handshake(msg);
    }

    /// Completes the handshake and switches to the server's application keys.
    fn complete(k: *ClientCase) !void {
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try k.certificateVerify(session.SignatureScheme.ecdsa_secp256r1_sha256, false);
        try k.finished(false);
        try testing.expect(k.c.handshakeDone());
        const suite: suites.Suite = .aes_128_gcm_sha256;
        const h = suites.hash(suite, k.transcript.items);
        k.writer = .init(suite, suites.deriveSecret(suite, &k.master, "s ap traffic", &h));
    }
};

fn sealed(c: *suites.Cipher, inner: []const u8) ![]u8 {
    const total = inner.len + suites.tag_len;
    var header: [5]u8 = .{ 23, 3, 3, 0, 0 };
    std.mem.writeInt(u16, header[3..5], @intCast(total), .big);
    const out = try a.alloc(u8, 5 + total);
    @memcpy(out[0..5], &header);
    try c.seal(out[5..][0..inner.len], out[5 + inner.len ..][0..suites.tag_len], inner, &header);
    return out;
}

/// Feeds a plaintext ServerHello with the given pieces to a fresh client.
fn clientRefusesHello(sid: []const u8, suite: u16, extensions: []const u8, alert: Alert, reason: []const u8) !void {
    const k = try ClientCase.init(false);
    defer k.deinit();
    const body = try ClientCase.serverHelloBody(sid, suite, extensions);
    defer a.free(body);
    const msg = try handshakeMsg(2, body);
    defer a.free(msg);
    const rec = try record(22, msg);
    defer a.free(rec);
    try testing.expectError(error.TlsFailure, k.c.feed(rec));
    try expectFailure(&k.c, alert, reason);
}

test "client: ServerHello" {
    var ar = Arena.init();
    defer ar.deinit();
    const good = try ar.keep(try ClientCase.goodServerHelloExts());
    const pk = pub25519(server_secret);
    const ks = try ar.keep(try ext(ET.key_share, &([_]u8{ 0, 0x1d, 0, 32 } ++ pk)));
    const sv = try ar.keep(try ext(ET.supported_versions, &.{ 3, 4 }));
    try clientRefusesHello("", 0x1301, ks, .protocol_version, "the server does not speak TLS 1.3");
    try clientRefusesHello("", 0x1301, try ar.keep(try cat(&.{ ks, try ar.keep(try ext(ET.supported_versions, &.{ 3, 3 })) })), .illegal_parameter, "the server selected a version that was not offered");
    try clientRefusesHello("x", 0x1301, good, .illegal_parameter, "ServerHello session id does not echo ours");
    try clientRefusesHello("", 0x1302, good, .illegal_parameter, "the server selected a cipher suite that was not offered");
    try clientRefusesHello("", 0x1399, good, .illegal_parameter, "the server selected an unknown cipher suite");
    try clientRefusesHello("", 0x1301, sv, .missing_extension, "ServerHello has no key_share");
    const alpn = try ar.keep(try ext(ET.alpn, &.{ 0, 3, 2, 'h', '2' }));
    try clientRefusesHello("", 0x1301, try ar.keep(try cat(&.{ good, alpn })), .unsupported_extension, "ServerHello carries an extension that was not offered");
    const p256_share = try ar.keep(try ext(ET.key_share, &([_]u8{ 0, 0x17, 0, 32 } ++ pk)));
    try clientRefusesHello("", 0x1301, try ar.keep(try cat(&.{ p256_share, sv })), .illegal_parameter, "the server's key share is for a group we did not share");
    const zero = try ar.keep(try ext(ET.key_share, &([_]u8{ 0, 0x1d, 0, 32 } ++ [_]u8{0} ** 32)));
    try clientRefusesHello("", 0x1301, try ar.keep(try cat(&.{ zero, sv })), .illegal_parameter, "invalid key share");
    try clientRefusesHello("", 0x1301, try ar.keep(try cat(&.{ try ar.keep(try ext(ET.key_share, &.{ 0, 0x1d, 0, 5 })), sv })), .decode_error, "malformed key_share");

    // Legacy version and compression, which the builder above fixes.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        const bad = try ClientCase.serverHelloBody("", 0x1301, good);
        defer a.free(bad);
        bad[1] = 1;
        const rec = try ar.keep(try record(22, try ar.keep(try handshakeMsg(2, bad))));
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .illegal_parameter, "ServerHello legacy_version is not 1.2");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        const bad = try ClientCase.serverHelloBody("", 0x1301, good);
        defer a.free(bad);
        bad[2 + 32 + 1 + 2] = 1;
        const rec = try ar.keep(try record(22, try ar.keep(try handshakeMsg(2, bad))));
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .illegal_parameter, "ServerHello selected compression");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        const rec = try ar.keep(try record(22, try ar.keep(try handshakeMsg(2, &.{ 3, 3, 1 }))));
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .decode_error, "truncated ServerHello");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        const body = try ar.keep(try ClientCase.serverHelloBody("", 0x1301, good));
        const rec = try ar.keep(try record(22, try ar.keep(try handshakeMsg(2, try ar.keep(try cat(&.{ body, &.{0} }))))));
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .decode_error, "trailing bytes in ServerHello");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try testing.expectError(error.TlsFailure, k.c.feed(&.{ 22, 3, 3, 0, 4, 8, 0, 0, 0 }));
        try expectFailure(&k.c, .unexpected_message, "expected ServerHello");
    }
}

test "client: HelloRetryRequest" {
    var ar = Arena.init();
    defer ar.deinit();
    const sv = try ar.keep(try ext(ET.supported_versions, &.{ 3, 4 }));
    const ask = struct {
        fn f(group: u16) ![]u8 {
            return ext(ET.key_share, &u16be(group));
        }
    }.f;
    const hrr = struct {
        fn f(k: *ClientCase, extensions: []const u8, suite: u16) !void {
            const s = try vec8("");
            defer a.free(s);
            const e = try vec16(extensions);
            defer a.free(e);
            const body = try cat(&.{ &.{ 3, 3 }, &session.hello_retry_random, s, &u16be(suite), &.{0}, e });
            defer a.free(body);
            const msg = try handshakeMsg(2, body);
            defer a.free(msg);
            const rec = try record(22, msg);
            defer a.free(rec);
            k.c.feed(rec) catch |err| switch (err) {
                error.TlsFailure => {},
                else => return err,
            };
        }
    }.f;
    const cases = [_]struct { exts: []const u8, alert: Alert, reason: []const u8 }{
        .{ .exts = sv, .alert = .illegal_parameter, .reason = "HelloRetryRequest would not change the ClientHello" },
        .{ .exts = try ar.keep(try cat(&.{ sv, try ar.keep(try ask(0x001d)) })), .alert = .illegal_parameter, .reason = "HelloRetryRequest asks for a group already shared" },
        .{ .exts = try ar.keep(try cat(&.{ sv, try ar.keep(try ask(0x0100)) })), .alert = .illegal_parameter, .reason = "HelloRetryRequest asks for a group that was not offered" },
        .{ .exts = try ar.keep(try cat(&.{ sv, try ar.keep(try ext(ET.key_share, &.{0})) })), .alert = .decode_error, .reason = "malformed HelloRetryRequest key_share" },
        .{ .exts = try ar.keep(try cat(&.{ sv, try ar.keep(try ext(ET.cookie, &.{ 0, 0 })) })), .alert = .decode_error, .reason = "empty cookie" },
        .{ .exts = try ar.keep(try cat(&.{ sv, try ar.keep(try ext(ET.cookie, &.{ 0, 3, 1 })) })), .alert = .decode_error, .reason = "malformed cookie" },
    };
    for (cases) |cs| {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try hrr(k, cs.exts, 0x1301);
        try expectFailure(&k.c, cs.alert, cs.reason);
    }
    // A second retry, and a ServerHello that changes the retry's suite.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        k.cfg.cipher_suites = &.{ .aes_128_gcm_sha256, .aes_256_gcm_sha384 };
        const first = try ar.keep(try cat(&.{ sv, try ar.keep(try ask(0x0017)) }));
        try hrr(k, first, 0x1301);
        try testing.expect(!k.c.failed());
        try hrr(k, try ar.keep(try cat(&.{ sv, try ar.keep(try ask(0x0018)) })), 0x1301);
        try expectFailure(&k.c, .unexpected_message, "a second HelloRetryRequest");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        k.cfg.cipher_suites = &.{ .aes_128_gcm_sha256, .aes_256_gcm_sha384 };
        try hrr(k, try ar.keep(try cat(&.{ sv, try ar.keep(try ask(0x0017)) })), 0x1301);
        const body = try ar.keep(try ClientCase.serverHelloBody("", 0x1302, try ar.keep(try ClientCase.goodServerHelloExts())));
        const rec = try ar.keep(try record(22, try ar.keep(try handshakeMsg(2, body))));
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .illegal_parameter, "ServerHello changed the HelloRetryRequest's cipher suite");
    }
}

test "client: the server's encrypted flight" {
    // EncryptedExtensions.
    const ee_cases = [_]struct { msg: []const u8, alert: Alert, reason: []const u8 }{
        .{ .msg = &.{ 8, 0, 0, 6, 0, 4, 0, 51, 0, 0 }, .alert = .illegal_parameter, .reason = "EncryptedExtensions carries a hello-only extension" },
        .{ .msg = &.{ 8, 0, 0, 6, 0, 4, 0, 16, 0, 0 }, .alert = .unsupported_extension, .reason = "EncryptedExtensions carries an extension that was not offered" },
        .{ .msg = &.{ 8, 0, 0, 7, 0, 5, 0, 0, 0, 1, 0 }, .alert = .decode_error, .reason = "non-empty server_name acknowledgement" },
        .{ .msg = &.{ 8, 0, 0, 1, 0 }, .alert = .decode_error, .reason = "truncated EncryptedExtensions" },
        .{ .msg = &.{ 8, 0, 0, 3, 0, 0, 0 }, .alert = .decode_error, .reason = "trailing bytes in EncryptedExtensions" },
        .{ .msg = &.{ 11, 0, 0, 0 }, .alert = .unexpected_message, .reason = "expected EncryptedExtensions" },
    };
    for (ee_cases) |cs| {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.handshake(cs.msg);
        try expectFailure(&k.c, cs.alert, cs.reason);
        // The client protects its alert with its handshake keys.
        try testing.expect(k.c.output().len > 7);
        try testing.expectEqual(@as(u8, 23), k.c.output()[0]);
    }
    // Certificate and CertificateRequest.
    const cert_cases = [_]struct { msg: []const u8, alert: Alert, reason: []const u8 }{
        .{ .msg = &.{ 11, 0, 0, 4, 0, 0, 0, 0 }, .alert = .decode_error, .reason = "the server sent no certificate" },
        .{ .msg = &.{ 11, 0, 0, 5, 1, 7, 0, 0, 0 }, .alert = .illegal_parameter, .reason = "server Certificate has a request context" },
        .{ .msg = &.{ 11, 0, 0, 9, 0, 0, 0, 5, 0, 0, 0, 0, 0 }, .alert = .decode_error, .reason = "empty certificate entry" },
        .{ .msg = &.{ 11, 0, 0, 8, 0, 0, 0, 4, 0, 0, 9, 1 }, .alert = .decode_error, .reason = "truncated certificate entry" },
        .{ .msg = &.{ 11, 0, 0, 2, 0, 0 }, .alert = .decode_error, .reason = "truncated Certificate" },
        .{ .msg = &.{ 11, 0, 0, 5, 0, 0, 0, 0, 0 }, .alert = .decode_error, .reason = "trailing bytes in Certificate" },
        .{ .msg = &.{ 11, 0, 0, 12, 0, 0, 0, 8, 0, 0, 3, 1, 2, 3, 0, 0 }, .alert = .bad_certificate, .reason = "unparseable server certificate" },
        .{ .msg = &.{ 13, 0, 0, 3, 1, 0, 0 }, .alert = .decode_error, .reason = "truncated CertificateRequest" },
        .{ .msg = &.{ 13, 0, 0, 3, 0, 0, 0 }, .alert = .missing_extension, .reason = "CertificateRequest has no signature_algorithms" },
        .{ .msg = &.{ 13, 0, 0, 4, 1, 5, 0, 0 }, .alert = .illegal_parameter, .reason = "CertificateRequest context during the handshake" },
        .{ .msg = &.{ 13, 0, 0, 4, 0, 0, 0, 0 }, .alert = .decode_error, .reason = "trailing bytes in CertificateRequest" },
        .{ .msg = &.{ 15, 0, 0, 0 }, .alert = .unexpected_message, .reason = "expected Certificate" },
    };
    for (cert_cases) |cs| {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.handshake(cs.msg);
        try expectFailure(&k.c, cs.alert, cs.reason);
    }
    // A chain longer than the limit.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        var body: Bytes = .empty;
        defer body.deinit(a);
        try body.appendSlice(a, &.{ 0, 0, 0, 0 });
        for (0..11) |_| try body.appendSlice(a, &.{ 0, 0, 1, 0x30, 0, 0 });
        std.mem.writeInt(u24, body.items[1..4], @intCast(body.items.len - 4), .big);
        const msg = try handshakeMsg(11, body.items);
        defer a.free(msg);
        try k.handshake(msg);
        try expectFailure(&k.c, .bad_certificate, "certificate chain too long");
    }
    // After a CertificateRequest, another request is out of order.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.handshake(&.{ 13, 0, 0, 9, 0, 0, 6, 0, 13, 0, 2, 4, 3 });
        try k.handshake(&.{ 13, 0, 0, 9, 0, 0, 6, 0, 13, 0, 2, 4, 3 });
        try expectFailure(&k.c, .unexpected_message, "expected Certificate");
    }
    // Certificate verification through the scripted server.
    {
        const k = try ClientCase.init(true);
        defer k.deinit();
        k.cfg.verification.trust.now_sec = 4_102_444_800 * 2;
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try expectFailure(&k.c, .certificate_expired, "the server certificate has expired or is not yet valid");
    }
    // CertificateVerify.
    const S = session.SignatureScheme;
    const cv_cases = [_]struct { scheme: u16, corrupt: bool, alert: Alert, reason: []const u8 }{
        .{ .scheme = S.ecdsa_secp256r1_sha256, .corrupt = true, .alert = .decrypt_error, .reason = "CertificateVerify signature is invalid" },
        .{ .scheme = S.ed25519, .corrupt = false, .alert = .illegal_parameter, .reason = "CertificateVerify scheme does not match the certificate key" },
        .{ .scheme = S.rsa_pkcs1_sha256, .corrupt = false, .alert = .illegal_parameter, .reason = "CertificateVerify scheme does not match the certificate key" },
        .{ .scheme = 0x0203, .corrupt = false, .alert = .illegal_parameter, .reason = "CertificateVerify uses a scheme that was not offered" },
    };
    for (cv_cases) |cs| {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try k.certificateVerify(cs.scheme, cs.corrupt);
        try expectFailure(&k.c, cs.alert, cs.reason);
    }
    const cv_frames = [_]struct { msg: []const u8, reason: []const u8 }{
        .{ .msg = &.{ 15, 0, 0, 3, 4, 3, 0 }, .reason = "truncated CertificateVerify" },
        .{ .msg = &.{ 15, 0, 0, 5, 4, 3, 0, 0, 0 }, .reason = "trailing bytes in CertificateVerify" },
    };
    for (cv_frames) |cs| {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try k.handshake(cs.msg);
        try expectFailure(&k.c, .decode_error, cs.reason);
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try k.handshake(&.{ 20, 0, 0, 0 });
        try expectFailure(&k.c, .unexpected_message, "expected CertificateVerify");
    }
    // Finished.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try k.certificateVerify(S.ecdsa_secp256r1_sha256, false);
        try k.finished(true);
        try expectFailure(&k.c, .decrypt_error, "server Finished does not verify");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try k.certificateVerify(S.ecdsa_secp256r1_sha256, false);
        try k.handshake(&.{ 20, 0, 0, 1, 0 });
        try expectFailure(&k.c, .decode_error, "Finished has the wrong length");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.encryptedExtensions();
        try k.certificate();
        try k.certificateVerify(S.ecdsa_secp256r1_sha256, false);
        try k.handshake(&.{ 8, 0, 0, 2, 0, 0 });
        try expectFailure(&k.c, .unexpected_message, "expected Finished");
    }
}

test "client: protected records" {
    // Too short, tampered, padding only, oversized, and plaintext after keys.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try testing.expectError(error.TlsFailure, k.c.feed(&.{ 23, 3, 3, 0, 4, 1, 2, 3, 4 }));
        try expectFailure(&k.c, .bad_record_mac, "protected record too short");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        const rec = try k.protect(22, &.{ 8, 0, 0, 2, 0, 0 });
        defer a.free(rec);
        rec[7] ^= 1;
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .bad_record_mac, "record authentication failed");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        const rec = try sealed(&k.writer.?, &.{ 0, 0, 0 });
        defer a.free(rec);
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .unexpected_message, "protected record without a content type");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        const big = try a.alloc(u8, (1 << 14) + 2);
        defer a.free(big);
        @memset(big, 1);
        big[big.len - 1] = 23;
        const rec = try sealed(&k.writer.?, big);
        defer a.free(rec);
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .record_overflow, "record plaintext longer than the limit");
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try testing.expectError(error.TlsFailure, k.c.feed(&.{ 22, 3, 3, 0, 4, 8, 0, 0, 0 }));
        try expectFailure(&k.c, .unexpected_message, "unprotected record after keys changed");
    }
    // A ServerHello and EncryptedExtensions in one plaintext record.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        const e = try ClientCase.goodServerHelloExts();
        defer a.free(e);
        const body = try ClientCase.serverHelloBody("", 0x1301, e);
        defer a.free(body);
        const msg = try handshakeMsg(2, body);
        defer a.free(msg);
        const both = try cat(&.{ msg, &.{ 8, 0, 0, 2, 0, 0 } });
        defer a.free(both);
        const rec = try record(22, both);
        defer a.free(rec);
        try testing.expectError(error.TlsFailure, k.c.feed(rec));
        try expectFailure(&k.c, .unexpected_message, "handshake data after a key change in the same record");
    }
    // Application data before the handshake completes.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.acceptHello();
        try k.sendProtected(23, "early");
        try expectFailure(&k.c, .unexpected_message, "application data before the handshake completed");
    }
}

test "client: after the handshake" {
    const cases = [_]struct { ct: u8, msg: []const u8, alert: Alert, reason: []const u8 }{
        .{ .ct = 22, .msg = &.{ 24, 0, 0, 1, 2 }, .alert = .illegal_parameter, .reason = "KeyUpdate request value is not 0 or 1" },
        .{ .ct = 22, .msg = &.{ 24, 0, 0, 2, 0, 0 }, .alert = .decode_error, .reason = "malformed KeyUpdate" },
        .{ .ct = 22, .msg = &.{ 4, 0, 0, 3, 0, 0, 0 }, .alert = .decode_error, .reason = "truncated NewSessionTicket" },
        .{ .ct = 22, .msg = &.{ 4, 0, 0, 13, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0 }, .alert = .decode_error, .reason = "empty session ticket" },
        .{ .ct = 22, .msg = &.{ 4, 0, 0, 16, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 7, 0, 0, 0, 0 }, .alert = .decode_error, .reason = "trailing bytes in NewSessionTicket" },
        .{ .ct = 22, .msg = &.{ 13, 0, 0, 3, 0, 0, 0 }, .alert = .unexpected_message, .reason = "unexpected post-handshake message" },
        .{ .ct = 20, .msg = &.{1}, .alert = .unexpected_message, .reason = "unknown record type" },
    };
    for (cases) |cs| {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.complete();
        try k.sendProtected(cs.ct, cs.msg);
        try expectFailure(&k.c, cs.alert, cs.reason);
    }
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.complete();
        try testing.expectError(error.TlsFailure, k.c.feed(&.{ 20, 3, 3, 0, 1, 1 }));
        try expectFailure(&k.c, .unexpected_message, "change_cipher_spec after the handshake");
    }
    // Application data between two fragments of a handshake message.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.complete();
        try k.sendProtected(22, &.{ 4, 0, 0 });
        try k.sendProtected(23, "data");
        try expectFailure(&k.c, .unexpected_message, "application data inside a handshake message");
    }
    // A fatal alert from the peer, and data after close_notify is dropped.
    {
        const k = try ClientCase.init(false);
        defer k.deinit();
        try k.complete();
        try k.sendProtected(21, &.{ 1, 0 });
        try testing.expect(k.c.peerClosed());
        try k.sendProtected(23, "ignored");
        try testing.expectEqual(@as(usize, 0), k.c.appData().len);
        try k.sendProtected(21, &.{ 2, 80 });
        const f = k.c.failure().?;
        try testing.expectEqual(Alert.internal_error, f.alert);
        try testing.expect(!f.local);
    }
}

// ---- a scripted client for the server under test -----------------------------

const ScriptedClient = struct {
    sc: *ServerCase,
    transcript: Bytes = .empty,
    client_hs: suites.Secret = .{},
    writer: ?suites.Cipher = null,

    /// Sends a valid ClientHello and reads the server's flight, deriving the
    /// client handshake keys.
    fn start(extra: HelloExts) !ScriptedClient {
        const sc = try ServerCase.init();
        errdefer sc.deinit();
        var k: ScriptedClient = .{ .sc = sc };
        const e = try exts(extra);
        defer a.free(e);
        const hello = try clientHelloMsg(.{ .extensions = e });
        defer a.free(hello);
        const rec = try record(22, hello);
        defer a.free(rec);
        try sc.s.feed(rec);
        try k.transcript.appendSlice(a, hello);
        // The server's ServerHello is the first record of its output.
        const out = sc.s.output();
        const sh_len = std.mem.readInt(u16, out[3..5], .big);
        try k.transcript.appendSlice(a, out[5..][0..sh_len]);
        const shared = try X25519.scalarmult(client_secret, pub25519(server_secret));
        const suite: suites.Suite = .aes_128_gcm_sha256;
        const hs = suites.handshakeSecret(suite, &shared);
        const h = suites.hash(suite, k.transcript.items);
        k.client_hs = suites.deriveSecret(suite, &hs, "c hs traffic", &h);
        k.writer = .init(suite, k.client_hs);
        sc.s.consumeOutput(out.len);
        return k;
    }

    fn deinit(k: *ScriptedClient) void {
        k.transcript.deinit(a);
        k.sc.deinit();
    }

    fn send(k: *ScriptedClient, ct: u8, content: []const u8) !void {
        const inner = try cat(&.{ content, &.{ct} });
        defer a.free(inner);
        const rec = try sealed(&k.writer.?, inner);
        defer a.free(rec);
        k.sc.s.feed(rec) catch |e| switch (e) {
            error.TlsFailure => {},
            else => return e,
        };
    }
};

test "server: the client's second flight" {
    {
        var k = try ScriptedClient.start(.{});
        defer k.deinit();
        try k.send(22, &([_]u8{ 20, 0, 0, 32 } ++ [_]u8{0} ** 32));
        try expectFailure(&k.sc.s, .decrypt_error, "client Finished does not verify");
    }
    {
        var k = try ScriptedClient.start(.{});
        defer k.deinit();
        try k.send(22, &.{ 20, 0, 0, 2, 0, 0 });
        try expectFailure(&k.sc.s, .decode_error, "Finished has the wrong length");
    }
    {
        var k = try ScriptedClient.start(.{});
        defer k.deinit();
        try k.send(22, &.{ 11, 0, 0, 4, 0, 0, 0, 0 });
        try expectFailure(&k.sc.s, .unexpected_message, "expected Finished");
    }
    // The CCS a compatibility-mode client sends is dropped, not refused.
    {
        var k = try ScriptedClient.start(.{});
        defer k.deinit();
        try k.sc.s.feed(&.{ 20, 3, 3, 0, 1, 1 });
        try testing.expect(!k.sc.s.failed());
    }
}

test "server: after the handshake" {
    // Drive a real client against the server for a connected pair.
    var env = try tests.Env.init(a);
    defer env.deinit();
    const ccfg = env.trust("localhost");
    for ([_][]const u8{ &.{ 4, 0, 0, 13, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 7, 0, 0 }, &.{ 1, 0, 0, 0 } }) |msg| {
        var c = try Session.initClient(a, &ccfg, @splat(1));
        defer c.deinit();
        var s = Session.initServer(a, &.{ .identity = &env.p256.identity }, @splat(2));
        defer s.deinit();
        try tests.pump(&c, &s);
        try testing.expect(s.handshakeDone());
        try c.sendRawHandshake(msg);
        try tests.pump(&c, &s);
        const want = if (msg[0] == 4) "NewSessionTicket from a client" else "unexpected post-handshake message";
        try expectFailure(&s, .unexpected_message, want);
    }
}

test "server: a retried ClientHello must answer the HelloRetryRequest" {
    var ar = Arena.init();
    defer ar.deinit();
    const Retry = struct {
        fn run(second: HelloExts, sid2: []const u8, suites2: []const u8, alert: Alert, reason: []const u8) !void {
            const c = try a.create(ServerCase);
            defer a.destroy(c);
            c.env = try .init(a);
            defer c.env.deinit();
            // The server wants P-256; the first hello shares x25519 only.
            c.cfg = .{ .identity = &c.env.p256.identity, .groups = &.{.secp256r1} };
            c.s = Session.initServer(a, &c.cfg, @splat(9));
            defer c.s.deinit();
            const e1 = try exts(.{ .groups = &.{ 0, 4, 0x00, 0x1d, 0x00, 0x17 } });
            defer a.free(e1);
            const h1 = try clientHelloMsg(.{ .session_id = "abc", .extensions = e1 });
            defer a.free(h1);
            const r1 = try record(22, h1);
            defer a.free(r1);
            try c.s.feed(r1);
            try testing.expect(!c.s.failed());
            const e2 = try exts(second);
            defer a.free(e2);
            const h2 = try clientHelloMsg(.{ .session_id = sid2, .suites = suites2, .extensions = e2 });
            defer a.free(h2);
            const r2 = try record(22, h2);
            defer a.free(r2);
            try testing.expectError(error.TlsFailure, c.s.feed(r2));
            try expectFailure(&c.s, alert, reason);
        }
    };
    const both = &[_]u8{ 0, 4, 0x00, 0x1d, 0x00, 0x17 };
    const E = crypto.sign.ecdsa.EcdsaP256Sha256;
    const kp = try E.KeyPair.generateDeterministic(@splat(3));
    const p256_share = try ar.keep(try vec16(&([_]u8{ 0, 0x17, 0, 65 } ++ kp.public_key.toUncompressedSec1())));
    try Retry.run(.{ .groups = both }, "abc", &.{ 0x13, 0x01 }, .illegal_parameter, "retried ClientHello does not share the requested group");
    try Retry.run(.{ .groups = both, .shares = p256_share }, "abd", &.{ 0x13, 0x01 }, .illegal_parameter, "retried ClientHello changed its session id");
    try Retry.run(.{ .groups = both, .shares = p256_share }, "abc", &.{ 0x13, 0x03 }, .illegal_parameter, "retried ClientHello dropped the selected cipher suite");
    const early = try ar.keep(try ext(ET.early_data, ""));
    try Retry.run(.{ .groups = both, .shares = p256_share, .extra_last = &.{early} }, "abc", &.{ 0x13, 0x01 }, .illegal_parameter, "retried ClientHello offers early data");
}

test "server: a pinned cookie must come back" {
    var ar = Arena.init();
    defer ar.deinit();
    const cookie_ext = try ar.keep(try ext(ET.cookie, &.{ 0, 3, 7, 7, 7 }));
    const hrr_block = try ar.keep(try cat(&.{ try ar.keep(try ext(ET.supported_versions, &.{ 3, 4 })), try ar.keep(try ext(ET.key_share, &.{ 0, 0x17 })), cookie_ext }));
    const E = crypto.sign.ecdsa.EcdsaP256Sha256;
    const kp = try E.KeyPair.generateDeterministic(@splat(3));
    const p256_share = try ar.keep(try vec16(&([_]u8{ 0, 0x17, 0, 65 } ++ kp.public_key.toUncompressedSec1())));
    const both = &[_]u8{ 0, 4, 0x00, 0x1d, 0x00, 0x17 };
    for ([_]struct { cookie: ?[]const u8, alert: Alert, reason: []const u8 }{
        .{ .cookie = null, .alert = .missing_extension, .reason = "retried ClientHello has no cookie" },
        .{ .cookie = try ar.keep(try ext(ET.cookie, &.{ 0, 3, 7, 7, 8 })), .alert = .illegal_parameter, .reason = "retried ClientHello changed the cookie" },
        .{ .cookie = try ar.keep(try ext(ET.cookie, &.{ 0, 9 })), .alert = .decode_error, .reason = "malformed cookie" },
    }) |cs| {
        var env = try tests.Env.init(a);
        defer env.deinit();
        const cfg: session.ServerConfig = .{ .identity = &env.p256.identity, .groups = &.{.secp256r1}, .hooks = .{ .hello_retry_extensions = hrr_block } };
        var s = Session.initServer(a, &cfg, @splat(1));
        defer s.deinit();
        const e1 = try exts(.{ .groups = both });
        defer a.free(e1);
        const h1 = try clientHelloMsg(.{ .extensions = e1 });
        defer a.free(h1);
        const r1 = try record(22, h1);
        defer a.free(r1);
        try s.feed(r1);
        const extra: []const []const u8 = if (cs.cookie) |c| &.{c} else &.{};
        const e2 = try exts(.{ .groups = both, .shares = p256_share, .extra_last = extra });
        defer a.free(e2);
        const h2 = try clientHelloMsg(.{ .extensions = e2 });
        defer a.free(h2);
        const r2 = try record(22, h2);
        defer a.free(r2);
        try testing.expectError(error.TlsFailure, s.feed(r2));
        try expectFailure(&s, cs.alert, cs.reason);
    }
}

fn clientStartFails(cfg: *const session.ClientConfig, reason: []const u8) !void {
    var c = try Session.initClient(a, cfg, @splat(1));
    defer c.deinit();
    try expectFailure(&c, .internal_error, reason);
    try testing.expectEqual(@as(usize, 0), c.output().len);
}

test "configuration errors fail before anything is sent" {
    try clientStartFails(&.{ .server_name = "localhost", .verification = .insecure_accept_any, .cipher_suites = &.{} }, "no cipher suites or key share groups");
    try clientStartFails(&.{ .server_name = "localhost", .verification = .insecure_accept_any, .key_share_groups = &.{} }, "no cipher suites or key share groups");
    try clientStartFails(&.{ .server_name = "localhost", .verification = .insecure_accept_any, .key_share_groups = &.{@enumFromInt(0x0100)} }, "unsupported group");
    try clientStartFails(&.{ .server_name = "localhost", .verification = .insecure_accept_any, .hooks = .{ .p256_secret = @splat(0) }, .key_share_groups = &.{.secp256r1} }, "bad pinned P-256 key");
    // An extension block too long for its length field.
    const huge = try a.alloc(u8, 70_000);
    defer a.free(huge);
    @memset(huge, 0);
    try clientStartFails(&.{ .server_name = "localhost", .verification = .insecure_accept_any, .hooks = .{ .client_hello_extensions = huge } }, "message field too long");
}

test "a server's pinned inputs are checked" {
    var ar = Arena.init();
    defer ar.deinit();
    const good = try ar.keep(try exts(.{}));
    const hello = try ar.keep(try record(22, try ar.keep(try clientHelloMsg(.{ .extensions = good }))));
    {
        var env = try tests.Env.init(a);
        defer env.deinit();
        const long_sig = try a.alloc(u8, 600);
        defer a.free(long_sig);
        const cfg: session.ServerConfig = .{ .identity = &env.p256.identity, .hooks = .{ .signature = .{ .scheme = session.SignatureScheme.ecdsa_secp256r1_sha256, .bytes = long_sig } } };
        var s = Session.initServer(a, &cfg, @splat(1));
        defer s.deinit();
        try testing.expectError(error.TlsFailure, s.feed(hello));
        try expectFailure(&s, .internal_error, "pinned signature too long");
    }
    {
        var env = try tests.Env.init(a);
        defer env.deinit();
        const block = try ar.keep(try cat(&.{ try ar.keep(try ext(ET.supported_versions, &.{ 3, 4 })), try ar.keep(try ext(ET.cookie, &.{ 0, 9 })) }));
        const cfg: session.ServerConfig = .{ .identity = &env.p256.identity, .groups = &.{.secp256r1}, .hooks = .{ .hello_retry_extensions = block } };
        var s = Session.initServer(a, &cfg, @splat(1));
        defer s.deinit();
        const both = try ar.keep(try exts(.{ .groups = &.{ 0, 4, 0x00, 0x1d, 0x00, 0x17 } }));
        const h = try ar.keep(try record(22, try ar.keep(try clientHelloMsg(.{ .extensions = both }))));
        try testing.expectError(error.TlsFailure, s.feed(h));
        try expectFailure(&s, .internal_error, "bad pinned cookie");
    }
}
