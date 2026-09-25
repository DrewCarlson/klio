//! PEM text: certificate chains and the server's private key.
//!
//! Keys come as PKCS#8 (`BEGIN PRIVATE KEY`) for P-256 ECDSA or Ed25519, or
//! as SEC 1 (`BEGIN EC PRIVATE KEY`) for P-256. Encrypted keys and RSA keys
//! are refused with an error that names the form.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

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
        errdefer a.free(out);
        const len = base64.decode(out, body) catch return error.InvalidPem;
        return try a.realloc(out, len);
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
};

pub const KeyError = error{
    InvalidPem,
    InvalidPrivateKey,
    UnsupportedPrivateKey,
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
            const n = first & 0x7f;
            if (n == 0 or n > 3 or d.buf.len - i < n) return error.InvalidPrivateKey;
            for (d.buf[i..][0..n]) |b| len = (len << 8) | b;
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

/// A PKCS#8 PrivateKeyInfo holding a P-256 or Ed25519 key.
fn pkcs8(der: []const u8) KeyError!PrivateKey {
    var outer: Der = .{ .buf = der };
    var d: Der = .{ .buf = try outer.element(0x30) };
    const version = try d.element(0x02);
    if (version.len != 1 or version[0] > 1) return error.InvalidPrivateKey;
    var alg: Der = .{ .buf = try d.element(0x30) };
    const oid = try alg.element(0x06);
    const key = try d.element(0x04);
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
    if (has(text, "RSA PRIVATE KEY")) return error.UnsupportedPrivateKey;
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
    };
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
    try testing.expectError(error.UnsupportedPrivateKey, privateKey(testing.allocator, "-----BEGIN RSA PRIVATE KEY-----\nAA==\n-----END RSA PRIVATE KEY-----"));
    try testing.expectError(error.MissingPrivateKey, privateKey(testing.allocator, "nothing here"));
    try testing.expectError(error.InvalidPrivateKey, privateKey(testing.allocator, "-----BEGIN PRIVATE KEY-----\nMAA=\n-----END PRIVATE KEY-----"));
}
