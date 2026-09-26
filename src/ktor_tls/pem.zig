//! PEM text: certificate chains and the server's private key.
//!
//! Keys come as PKCS#8 (`BEGIN PRIVATE KEY`) for P-256 ECDSA, Ed25519 or
//! RSA, as SEC 1 (`BEGIN EC PRIVATE KEY`) for P-256, or as PKCS#1
//! (`BEGIN RSA PRIVATE KEY`). Encrypted keys are refused with an error that
//! names the form.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
pub const rsa = @import("rsa.zig");

pub const EcdsaP256 = crypto.sign.ecdsa.EcdsaP256Sha256;
pub const Ed25519 = crypto.sign.Ed25519;

const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

/// Walks the `-----BEGIN <label>-----` blocks of a PEM text.
pub const Iterator = struct {
    text: []const u8,
    label: []const u8,
    pos: usize = 0,

    pub fn init(text: []const u8, label: []const u8) Iterator {
        return .{ .text = text, .label = label };
    }

    /// The next block's DER bytes, owned by the caller.
    pub fn next(it: *Iterator, a: Allocator) !?[]u8 {
        var begin_buf: [64]u8 = undefined;
        var end_buf: [64]u8 = undefined;
        const begin = std.fmt.bufPrint(&begin_buf, "-----BEGIN {s}-----", .{it.label}) catch return error.InvalidPem;
        const end = std.fmt.bufPrint(&end_buf, "-----END {s}-----", .{it.label}) catch return error.InvalidPem;
        const b = std.mem.findPos(u8, it.text, it.pos, begin) orelse return null;
        const body_start = b + begin.len;
        const e = std.mem.findPos(u8, it.text, body_start, end) orelse return error.InvalidPem;
        it.pos = e + end.len;
        const body = it.text[body_start..e];
        const n = base64.calcSizeUpperBound(body.len);
        const out = try a.alloc(u8, n);
        // A block may be a private key: every buffer that held its bytes is
        // cleared before it is freed.
        defer {
            crypto.secureZero(u8, out);
            a.free(out);
        }
        const len = base64.decode(out, body) catch return error.InvalidPem;
        return try a.dupe(u8, out[0..len]);
    }
};

/// Whether `text` holds a block with this label.
pub fn has(text: []const u8, label: []const u8) bool {
    var buf: [64]u8 = undefined;
    const begin = std.fmt.bufPrint(&buf, "-----BEGIN {s}-----", .{label}) catch return false;
    return std.mem.find(u8, text, begin) != null;
}

/// Every certificate of a PEM chain as DER, leaf first as the text orders them.
pub fn certificates(a: Allocator, text: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |c| a.free(c);
        list.deinit(a);
    }
    var it: Iterator = .init(text, "CERTIFICATE");
    while (try it.next(a)) |der| try list.append(a, der);
    return list.toOwnedSlice(a);
}

pub const PrivateKey = union(enum) {
    p256: EcdsaP256.KeyPair,
    ed25519: Ed25519.KeyPair,
    rsa: rsa.KeyPair,
};

pub const KeyError = error{
    InvalidPem,
    InvalidPrivateKey,
    UnsupportedPrivateKey,
    UnsupportedRsaKey,
    EncryptedPrivateKey,
    MissingPrivateKey,
} || Allocator.Error;

/// A DER reader for the few key structures used here; every length is checked.
const Der = struct {
    buf: []const u8,
    pos: usize = 0,

    fn element(d: *Der, want_tag: u8) KeyError![]const u8 {
        if (d.buf.len - d.pos < 2) return error.InvalidPrivateKey;
        if (d.buf[d.pos] != want_tag) return error.InvalidPrivateKey;
        const first = d.buf[d.pos + 1];
        var i = d.pos + 2;
        var len: usize = 0;
        if (first & 0x80 == 0) {
            len = first;
        } else {
            // DER: the long form only for 128 and more, in the fewest bytes.
            const n = first & 0x7f;
            if (n == 0 or n > 3 or d.buf.len - i < n or d.buf[i] == 0) return error.InvalidPrivateKey;
            for (d.buf[i..][0..n]) |b| len = (len << 8) | b;
            if (len < 0x80) return error.InvalidPrivateKey;
            i += n;
        }
        if (d.buf.len - i < len) return error.InvalidPrivateKey;
        d.pos = i + len;
        return d.buf[i..][0..len];
    }

    fn peekTag(d: *const Der) ?u8 {
        return if (d.pos < d.buf.len) d.buf[d.pos] else null;
    }
};

const oid_ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const oid_prime256v1 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const oid_ed25519 = [_]u8{ 0x2b, 0x65, 0x70 };
const oid_rsa_encryption = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

/// An ECPrivateKey (RFC 5915) on P-256. `need_curve` when the structure
/// itself must name the curve (the SEC 1 form).
fn ecPrivateKey(der: []const u8, need_curve: bool) KeyError!PrivateKey {
    var outer: Der = .{ .buf = der };
    var d: Der = .{ .buf = try outer.element(0x30) };
    const version = try d.element(0x02);
    if (version.len != 1 or version[0] != 1) return error.InvalidPrivateKey;
    const secret = try d.element(0x04);
    if (secret.len != 32) return error.UnsupportedPrivateKey;
    var saw_curve = false;
    if (d.peekTag() == 0xa0) {
        var params: Der = .{ .buf = try d.element(0xa0) };
        const curve = try params.element(0x06);
        if (!std.mem.eql(u8, curve, &oid_prime256v1)) return error.UnsupportedPrivateKey;
        saw_curve = true;
    }
    if (need_curve and !saw_curve) return error.InvalidPrivateKey;
    const sk = EcdsaP256.SecretKey.fromBytes(secret[0..32].*) catch return error.InvalidPrivateKey;
    return .{ .p256 = EcdsaP256.KeyPair.fromSecretKey(sk) catch return error.InvalidPrivateKey };
}

/// An RSAPrivateKey (PKCS#1).
fn rsaPrivateKey(der: []const u8) KeyError!PrivateKey {
    var key: PrivateKey = .{ .rsa = undefined };
    rsa.KeyPair.fromPkcs1(&key.rsa, der) catch |e| return switch (e) {
        error.InvalidPrivateKey => error.InvalidPrivateKey,
        error.UnsupportedRsaKey => error.UnsupportedRsaKey,
    };
    return key;
}

/// A PKCS#8 PrivateKeyInfo holding a P-256, Ed25519 or RSA key.
fn pkcs8(der: []const u8) KeyError!PrivateKey {
    var outer: Der = .{ .buf = der };
    var d: Der = .{ .buf = try outer.element(0x30) };
    const version = try d.element(0x02);
    if (version.len != 1 or version[0] > 1) return error.InvalidPrivateKey;
    var alg: Der = .{ .buf = try d.element(0x30) };
    const oid = try alg.element(0x06);
    const key = try d.element(0x04);
    // Optional attributes, and a public key only in version 1 (RFC 5958);
    // nothing else follows.
    if (d.peekTag() == 0xa0) _ = try d.element(0xa0);
    if (version[0] == 1 and d.peekTag() == 0x81) _ = try d.element(0x81);
    if (d.peekTag() != null or outer.peekTag() != null) return error.InvalidPrivateKey;
    if (std.mem.eql(u8, oid, &oid_rsa_encryption)) {
        // rsaEncryption's parameters are NULL (RFC 8017 A.1), or absent.
        if (alg.peekTag() != null) {
            const params = try alg.element(0x05);
            if (params.len != 0 or alg.peekTag() != null) return error.InvalidPrivateKey;
        }
        return rsaPrivateKey(key);
    }
    if (std.mem.eql(u8, oid, &oid_ec_public_key)) {
        const curve = try alg.element(0x06);
        if (!std.mem.eql(u8, curve, &oid_prime256v1)) return error.UnsupportedPrivateKey;
        return ecPrivateKey(key, false);
    }
    if (std.mem.eql(u8, oid, &oid_ed25519)) {
        var inner: Der = .{ .buf = key };
        const seed = try inner.element(0x04);
        if (seed.len != 32) return error.InvalidPrivateKey;
        return .{ .ed25519 = Ed25519.KeyPair.generateDeterministic(seed[0..32].*) catch return error.InvalidPrivateKey };
    }
    return error.UnsupportedPrivateKey;
}

/// The private key in a PEM text.
pub fn privateKey(a: Allocator, text: []const u8) KeyError!PrivateKey {
    if (has(text, "ENCRYPTED PRIVATE KEY")) return error.EncryptedPrivateKey;
    // The traditional RSA and EC forms mark encryption with a header.
    if (std.mem.find(u8, text, "Proc-Type: 4,ENCRYPTED") != null) return error.EncryptedPrivateKey;
    if (has(text, "RSA PRIVATE KEY")) {
        var it: Iterator = .init(text, "RSA PRIVATE KEY");
        const der = (it.next(a) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPem,
        }) orelse return error.MissingPrivateKey;
        defer {
            crypto.secureZero(u8, der);
            a.free(der);
        }
        return rsaPrivateKey(der);
    }
    if (has(text, "PRIVATE KEY")) {
        var it: Iterator = .init(text, "PRIVATE KEY");
        const der = (it.next(a) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPem,
        }) orelse return error.MissingPrivateKey;
        defer {
            crypto.secureZero(u8, der);
            a.free(der);
        }
        return pkcs8(der);
    }
    if (has(text, "EC PRIVATE KEY")) {
        var it: Iterator = .init(text, "EC PRIVATE KEY");
        const der = (it.next(a) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPem,
        }) orelse return error.MissingPrivateKey;
        defer {
            crypto.secureZero(u8, der);
            a.free(der);
        }
        return ecPrivateKey(der, true);
    }
    return error.MissingPrivateKey;
}

/// Whether the key is the one certified by `leaf` (the leaf's parsed public key).
pub fn keyMatches(key: *const PrivateKey, parsed_leaf: *const crypto.Certificate.Parsed) bool {
    const pub_key = parsed_leaf.pubKey();
    return switch (key.*) {
        .p256 => |kp| parsed_leaf.pub_key_algo == .X9_62_id_ecPublicKey and
            parsed_leaf.pub_key_algo.X9_62_id_ecPublicKey == .X9_62_prime256v1 and
            std.mem.eql(u8, pub_key, &kp.public_key.toUncompressedSec1()),
        .ed25519 => |kp| parsed_leaf.pub_key_algo == .curveEd25519 and
            std.mem.eql(u8, pub_key, &kp.public_key.toBytes()),
        .rsa => |*kp| parsed_leaf.pub_key_algo == .rsaEncryption and kp.matchesPublicKey(pub_key),
    };
}

/// Clears the key's secret material.
pub fn wipe(key: *PrivateKey) void {
    crypto.secureZero(u8, std.mem.asBytes(key));
}

const testing = std.testing;

test "a PEM iterator decodes each block and refuses an unterminated one" {
    const text =
        \\junk
        \\-----BEGIN CERTIFICATE-----
        \\AQID
        \\-----END CERTIFICATE-----
        \\-----BEGIN CERTIFICATE-----
        \\BAU=
        \\-----END CERTIFICATE-----
    ;
    const certs = try certificates(testing.allocator, text);
    defer {
        for (certs) |c| testing.allocator.free(c);
        testing.allocator.free(certs);
    }
    try testing.expectEqual(@as(usize, 2), certs.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, certs[0]);
    try testing.expectEqualSlices(u8, &.{ 4, 5 }, certs[1]);
    try testing.expectError(error.InvalidPem, certificates(testing.allocator, "-----BEGIN CERTIFICATE-----\nAQID\n"));
}

test "key forms that are not supported say so" {
    try testing.expectError(error.EncryptedPrivateKey, privateKey(testing.allocator, "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAA==\n-----END ENCRYPTED PRIVATE KEY-----"));
    try testing.expectError(error.InvalidPrivateKey, privateKey(testing.allocator, "-----BEGIN RSA PRIVATE KEY-----\nAA==\n-----END RSA PRIVATE KEY-----"));
    try testing.expectError(error.MissingPrivateKey, privateKey(testing.allocator, "nothing here"));
    try testing.expectError(error.InvalidPrivateKey, privateKey(testing.allocator, "-----BEGIN PRIVATE KEY-----\nMAA=\n-----END PRIVATE KEY-----"));
}

test "RSA keys load from PKCS#8 and PKCS#1 and match their certificate" {
    const fixtures = @import("tls_fixtures");
    const a = testing.allocator;
    const k8 = try privateKey(a, fixtures.server_rsa_key);
    try testing.expect(k8 == .rsa);
    try testing.expectEqual(@as(usize, 2048), k8.rsa.bits);
    const k1 = try privateKey(a, fixtures.server_rsa_key_pkcs1);
    try testing.expect(k1 == .rsa);
    try testing.expectEqualSlices(u8, k8.rsa.modulus(), k1.rsa.modulus());
    try testing.expectEqualSlices(u8, &k8.rsa.d, &k1.rsa.d);
    const certs = try certificates(a, fixtures.server_rsa);
    defer {
        for (certs) |c| a.free(c);
        a.free(certs);
    }
    const parsed = try (crypto.Certificate{ .buffer = certs[0], .index = 0 }).parse();
    try testing.expect(keyMatches(&k8, &parsed));
    const other = try privateKey(a, fixtures.rsa3072_key);
    try testing.expect(!keyMatches(&other, &parsed));
    const ec = try privateKey(a, fixtures.server_p256_key);
    try testing.expect(!keyMatches(&ec, &parsed));
}

test "an RSA key outside the served range says so" {
    const fixtures = @import("tls_fixtures");
    try testing.expectError(error.UnsupportedRsaKey, privateKey(testing.allocator, fixtures.rsa1024_key));
    try testing.expectError(error.UnsupportedRsaKey, privateKey(testing.allocator, fixtures.rsa_even_e_key));
}

test "a long-form DER length that fits the short form is refused" {
    var d: Der = .{ .buf = &.{ 0x04, 0x81, 0x05, 1, 2, 3, 4, 5 } };
    try testing.expectError(error.InvalidPrivateKey, d.element(0x04));
    d = .{ .buf = &.{ 0x04, 0x82, 0x00, 0x05, 1, 2, 3, 4, 5 } };
    try testing.expectError(error.InvalidPrivateKey, d.element(0x04));
}

/// A PKCS#8 PrivateKeyInfo around `inner` with the given AlgorithmIdentifier
/// tail (after the OID) and trailing elements, for the tests below.
fn testPkcs8(buf: []u8, alg_tail: []const u8, inner: []const u8, trailing: []const u8) []const u8 {
    const Enc = struct {
        fn hdr(out: []u8, tag: u8, len: usize) usize {
            out[0] = tag;
            if (len < 0x80) {
                out[1] = @intCast(len);
                return 2;
            }
            out[1] = 0x82;
            out[2] = @intCast(len >> 8);
            out[3] = @intCast(len & 0xff);
            return 4;
        }
    };
    var alg_body: [64]u8 = undefined;
    var n = Enc.hdr(&alg_body, 0x06, oid_rsa_encryption.len);
    @memcpy(alg_body[n..][0..oid_rsa_encryption.len], &oid_rsa_encryption);
    n += oid_rsa_encryption.len;
    @memcpy(alg_body[n..][0..alg_tail.len], alg_tail);
    n += alg_tail.len;
    var body: [4096]u8 = undefined;
    var m: usize = 0;
    @memcpy(body[0..3], &[_]u8{ 0x02, 0x01, 0x00 });
    m = 3;
    m += Enc.hdr(body[m..], 0x30, n);
    @memcpy(body[m..][0..n], alg_body[0..n]);
    m += n;
    m += Enc.hdr(body[m..], 0x04, inner.len);
    @memcpy(body[m..][0..inner.len], inner);
    m += inner.len;
    @memcpy(body[m..][0..trailing.len], trailing);
    m += trailing.len;
    const h = Enc.hdr(buf, 0x30, m);
    @memcpy(buf[h..][0..m], body[0..m]);
    return buf[0 .. h + m];
}

test "PKCS#8 RSA parameters are NULL or absent, and nothing may follow the key" {
    const fixtures = @import("tls_fixtures");
    const a = testing.allocator;
    var it: Iterator = .init(fixtures.server_rsa_key_pkcs1, "RSA PRIVATE KEY");
    const inner = (try it.next(a)).?;
    defer {
        crypto.secureZero(u8, inner);
        a.free(inner);
    }
    var buf: [4096]u8 = undefined;
    try testing.expect((try pkcs8(testPkcs8(&buf, &.{ 0x05, 0x00 }, inner, &.{}))) == .rsa);
    try testing.expect((try pkcs8(testPkcs8(&buf, &.{}, inner, &.{}))) == .rsa);
    try testing.expectError(error.InvalidPrivateKey, pkcs8(testPkcs8(&buf, &.{ 0x05, 0x01, 0x00 }, inner, &.{})));
    try testing.expectError(error.InvalidPrivateKey, pkcs8(testPkcs8(&buf, &.{ 0x04, 0x00 }, inner, &.{})));
    try testing.expectError(error.InvalidPrivateKey, pkcs8(testPkcs8(&buf, &.{ 0x05, 0x00, 0x05, 0x00 }, inner, &.{})));
    // Attributes are allowed; a public key only in version 1; other trailing
    // elements never.
    try testing.expect((try pkcs8(testPkcs8(&buf, &.{ 0x05, 0x00 }, inner, &.{ 0xa0, 0x00 }))) == .rsa);
    try testing.expectError(error.InvalidPrivateKey, pkcs8(testPkcs8(&buf, &.{ 0x05, 0x00 }, inner, &.{ 0x81, 0x01, 0x00 })));
    try testing.expectError(error.InvalidPrivateKey, pkcs8(testPkcs8(&buf, &.{ 0x05, 0x00 }, inner, &.{ 0x04, 0x00 })));
}

test "an encrypted traditional key names the form" {
    const text =
        \\-----BEGIN RSA PRIVATE KEY-----
        \\Proc-Type: 4,ENCRYPTED
        \\DEK-Info: AES-256-CBC,00112233445566778899AABBCCDDEEFF
        \\
        \\AAAA
        \\-----END RSA PRIVATE KEY-----
    ;
    try testing.expectError(error.EncryptedPrivateKey, privateKey(testing.allocator, text));
}
