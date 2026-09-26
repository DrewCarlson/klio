//! RSA server keys: the private key a certificate's rsaEncryption key pairs
//! with, and RSASSA-PSS signing (RFC 8017 §8.1) for a TLS 1.3
//! CertificateVerify.
//!
//! The arithmetic is std.crypto.ff's: the private operation is `m^d mod n`
//! with `powWithEncodedExponent`, constant time in the exponent, without the
//! CRT (so no CRT fault attack applies), and every signature is checked with
//! the public exponent before it leaves. The encoding is EMSA-PSS-ENCODE
//! (§9.1.1) with MGF1 over the signature's hash and a salt as long as the
//! hash, as TLS 1.3 requires; std's `Certificate.rsa` verifies the same
//! encoding and its tests check this one against it.

const std = @import("std");
const crypto = std.crypto;

pub const max_bits = 4096;
pub const min_bits = 2048;
pub const max_bytes = max_bits / 8;

const Modulus = crypto.ff.Modulus(max_bits);
const Fe = Modulus.Fe;

pub const Error = error{
    /// The DER is malformed or inconsistent (d >= n, zero values).
    InvalidPrivateKey,
    /// Well formed, but outside what is served: a modulus outside 2048 to
    /// 4096 bits, an even or out-of-range public exponent, or more than two
    /// primes.
    UnsupportedRsaKey,
};

pub const Hash = enum { sha256, sha384, sha512 };

pub const KeyPair = struct {
    n: Modulus,
    /// The modulus, big-endian, `len` bytes with no leading zero.
    n_bytes: [max_bytes]u8,
    len: usize,
    bits: usize,
    /// The public exponent, big-endian, without leading zeros.
    e_bytes: [4]u8,
    e_len: usize,
    /// The private exponent, big-endian, left-padded to `len` bytes so the
    /// exponentiation's length does not depend on it.
    d: [max_bytes]u8,

    /// An RSAPrivateKey (RFC 8017 A.1.2), DER, into `out`.
    pub fn fromPkcs1(out: *KeyPair, der: []const u8) Error!void {
        var outer: Der = .{ .buf = der };
        var seq: Der = .{ .buf = try outer.element(0x30) };
        if (!outer.done()) return error.InvalidPrivateKey;
        const version = try seq.integer();
        if (version.len != 1) return error.InvalidPrivateKey;
        // Version 1 is the multi-prime form.
        if (version[0] != 0) return if (version[0] == 1) error.UnsupportedRsaKey else error.InvalidPrivateKey;
        const n = try seq.integer();
        const e = try seq.integer();
        const d = try seq.integer();
        // p, q, d mod (p-1), d mod (q-1), q^-1 mod p: well formed, unused
        // (no CRT).
        for (0..5) |_| _ = try seq.integer();
        if (!seq.done()) return error.InvalidPrivateKey;
        return fromParts(out, n, e, d);
    }

    /// A key, into `out`, from its unsigned big-endian modulus, public and
    /// private exponents, each without leading zeros. On failure `out`
    /// holds nothing secret.
    pub fn fromParts(out: *KeyPair, n: []const u8, e: []const u8, d: []const u8) Error!void {
        if (n.len == 0 or e.len == 0 or d.len == 0) return error.InvalidPrivateKey;
        if (n[0] == 0 or e[0] == 0 or d[0] == 0) return error.InvalidPrivateKey;
        if (n.len > max_bytes) return error.UnsupportedRsaKey;
        const n_mod = Modulus.fromBytes(n, .big) catch |err| return switch (err) {
            error.EvenModulus, error.ModulusTooSmall => error.InvalidPrivateKey,
            error.Overflow => error.UnsupportedRsaKey,
        };
        const bits = n_mod.bits();
        if (bits < min_bits or bits > max_bits) return error.UnsupportedRsaKey;
        // Any odd public exponent with 3 <= e < 2^32.
        if (e.len > 4) return error.UnsupportedRsaKey;
        var e_val: u32 = 0;
        for (e) |b| e_val = (e_val << 8) | b;
        if (e_val < 3 or e_val & 1 == 0) return error.UnsupportedRsaKey;
        if (d.len > n.len) return error.InvalidPrivateKey;
        out.* = .{
            .n = n_mod,
            .n_bytes = @splat(0),
            .len = n.len,
            .bits = bits,
            .e_bytes = @splat(0),
            .e_len = e.len,
            .d = @splat(0),
        };
        @memcpy(out.n_bytes[0..n.len], n);
        @memcpy(out.e_bytes[0..e.len], e);
        @memcpy(out.d[n.len - d.len .. n.len], d);
        // 0 < d < n (d has no leading zero, so it is not zero), compared on
        // the padded bytes so no other copy of d is made.
        if (crypto.timing_safe.compare(u8, out.d[0..n.len], n, .big) != .lt) {
            out.wipe();
            return error.InvalidPrivateKey;
        }
    }

    pub fn modulus(kp: *const KeyPair) []const u8 {
        return kp.n_bytes[0..kp.len];
    }

    pub fn exponent(kp: *const KeyPair) []const u8 {
        return kp.e_bytes[0..kp.e_len];
    }

    pub fn wipe(kp: *KeyPair) void {
        crypto.secureZero(u8, &kp.d);
    }

    /// Whether this is the key of a certificate's RSA public key (the
    /// `RSAPublicKey` DER a parsed certificate's `pubKey()` returns). std's
    /// `parseDer` trusts the lengths it reads; the key comes from a
    /// certificate `x509.parse` has already walked, which checks them.
    pub fn matchesPublicKey(kp: *const KeyPair, pub_key_der: []const u8) bool {
        const parts = crypto.Certificate.rsa.PublicKey.parseDer(pub_key_der) catch return false;
        const e = std.mem.trimStart(u8, parts.exponent, &.{0});
        return std.mem.eql(u8, parts.modulus, kp.modulus()) and std.mem.eql(u8, e, kp.exponent());
    }

    /// An RSASSA-PSS signature of `msg` with `hash`, MGF1 over the same hash
    /// and `salt` (as long as the hash), written into `out` (at least the
    /// modulus length). The signature is verified before it is returned.
    pub fn signPss(kp: *const KeyPair, hash: Hash, msg: []const u8, salt: []const u8, out: []u8) error{SigningFailed}![]u8 {
        return switch (hash) {
            .sha256 => kp.signPssWith(crypto.hash.sha2.Sha256, msg, salt, out),
            .sha384 => kp.signPssWith(crypto.hash.sha2.Sha384, msg, salt, out),
            .sha512 => kp.signPssWith(crypto.hash.sha2.Sha512, msg, salt, out),
        };
    }

    fn signPssWith(kp: *const KeyPair, comptime H: type, msg: []const u8, salt: []const u8, out: []u8) error{SigningFailed}![]u8 {
        if (salt.len != H.digest_length or out.len < kp.len) return error.SigningFailed;
        // At least 256 exponent bytes: std's exponentiation takes its
        // constant-time windowed path for every secret exponent that long.
        std.debug.assert(kp.len >= min_bits / 8);
        // The encoded message is emBits = modBits - 1 bits long, so as an
        // integer it is below the modulus; it is right-aligned in `len`
        // bytes (one leading zero byte when modBits - 1 is a multiple of 8).
        var em_buf: [max_bytes]u8 = @splat(0);
        defer crypto.secureZero(u8, &em_buf);
        const em_bits = kp.bits - 1;
        const em_len = (em_bits + 7) / 8;
        const em = em_buf[kp.len - em_len .. kp.len];
        emsaPssEncode(H, msg, salt, em_bits, em) catch return error.SigningFailed;

        const m = Fe.fromBytes(kp.n, em_buf[0..kp.len], .big) catch return error.SigningFailed;
        const s = kp.n.powWithEncodedExponent(m, kp.d[0..kp.len], .big) catch return error.SigningFailed;
        // Check the signature before it leaves: s^e mod n must give back EM.
        const back = kp.n.powWithEncodedPublicExponent(s, kp.exponent(), .big) catch return error.SigningFailed;
        if (!back.eql(m)) return error.SigningFailed;
        s.toBytes(out[0..kp.len], .big) catch return error.SigningFailed;
        return out[0..kp.len];
    }
};

pub const VerifyError = error{InvalidSignature};

/// RSASSA-PSS-VERIFY (RFC 8017 §8.1.2) with MGF1 over `hash` and a salt as
/// long as the hash, for a public key of 1024 to 4096 bits given as its
/// big-endian modulus and exponent (leading zeros allowed). Any modulus
/// length works, including one whose encoded message is a byte shorter than
/// the modulus.
pub fn verifyPss(hash: Hash, n: []const u8, e: []const u8, sig: []const u8, msg: []const u8) VerifyError!void {
    return switch (hash) {
        .sha256 => verifyPssWith(crypto.hash.sha2.Sha256, n, e, sig, msg),
        .sha384 => verifyPssWith(crypto.hash.sha2.Sha384, n, e, sig, msg),
        .sha512 => verifyPssWith(crypto.hash.sha2.Sha512, n, e, sig, msg),
    };
}

fn verifyPssWith(comptime H: type, n_raw: []const u8, e_raw: []const u8, sig: []const u8, msg: []const u8) VerifyError!void {
    const n = std.mem.trimStart(u8, n_raw, &.{0});
    const e = std.mem.trimStart(u8, e_raw, &.{0});
    if (n.len == 0 or n.len > max_bytes or e.len == 0 or e.len > 4) return error.InvalidSignature;
    const n_mod = Modulus.fromBytes(n, .big) catch return error.InvalidSignature;
    const bits = n_mod.bits();
    if (bits < 1024) return error.InvalidSignature;
    var e_val: u32 = 0;
    for (e) |b| e_val = (e_val << 8) | b;
    if (e_val < 3 or e_val & 1 == 0) return error.InvalidSignature;
    // 1. The signature is exactly k bytes; 2. s < n.
    const k = n.len;
    if (sig.len != k) return error.InvalidSignature;
    const s = Fe.fromBytes(n_mod, sig, .big) catch return error.InvalidSignature;
    const m = n_mod.powWithEncodedPublicExponent(s, e, .big) catch return error.InvalidSignature;
    var em_buf: [max_bytes]u8 = undefined;
    m.toBytes(em_buf[0..k], .big) catch return error.InvalidSignature;
    // EM = I2OSP(m, emLen): a byte shorter than k when modBits - 1 is a
    // multiple of 8, and then the leading byte must be zero.
    const em_bits = bits - 1;
    const em_len = (em_bits + 7) / 8;
    if (em_len < k and em_buf[0] != 0) return error.InvalidSignature;
    try emsaPssVerify(H, msg, em_buf[k - em_len .. k], em_bits);
}

/// EMSA-PSS-VERIFY (RFC 8017 §9.1.2) with a salt as long as the hash.
fn emsaPssVerify(comptime H: type, msg: []const u8, em: []const u8, em_bits: usize) VerifyError!void {
    const h_len = H.digest_length;
    const s_len = h_len;
    const em_len = em.len;
    if (em_len < h_len + s_len + 2) return error.InvalidSignature;
    if (em[em_len - 1] != 0xbc) return error.InvalidSignature;
    const db_len = em_len - h_len - 1;
    const h = em[db_len..][0..h_len];
    const zero_bits: u3 = @intCast(8 * em_len - em_bits);
    const top_mask: u8 = @as(u8, 0xff) >> zero_bits;
    if (em[0] & ~top_mask != 0) return error.InvalidSignature;
    var db_buf: [max_bytes]u8 = undefined;
    const db = db_buf[0..db_len];
    @memcpy(db, em[0..db_len]);
    mgf1Xor(H, h, db);
    db[0] &= top_mask;
    const ps_len = db_len - s_len - 1;
    for (db[0..ps_len]) |b| if (b != 0) return error.InvalidSignature;
    if (db[ps_len] != 0x01) return error.InvalidSignature;
    const salt = db[db_len - s_len ..];
    var m_hash: [h_len]u8 = undefined;
    H.hash(msg, &m_hash, .{});
    var h2: [h_len]u8 = undefined;
    var hasher = H.init(.{});
    hasher.update(&([_]u8{0} ** 8));
    hasher.update(&m_hash);
    hasher.update(salt);
    hasher.final(&h2);
    if (!crypto.timing_safe.eql([h_len]u8, h.*, h2)) return error.InvalidSignature;
}

/// EMSA-PSS-ENCODE (RFC 8017 §9.1.1) with MGF1 over `H` and a salt of
/// `salt.len` bytes, into `em` (emLen = ceil(em_bits / 8) bytes).
pub fn emsaPssEncode(comptime H: type, msg: []const u8, salt: []const u8, em_bits: usize, em: []u8) error{EncodingError}!void {
    const h_len = H.digest_length;
    const em_len = (em_bits + 7) / 8;
    if (em.len != em_len) return error.EncodingError;
    // 3. emLen < hLen + sLen + 2.
    if (em_len < h_len + salt.len + 2) return error.EncodingError;
    // 2. mHash = Hash(M).
    var m_hash: [h_len]u8 = undefined;
    H.hash(msg, &m_hash, .{});
    // 5-6. H = Hash(0x00 * 8 || mHash || salt).
    var h: [h_len]u8 = undefined;
    {
        var hasher = H.init(.{});
        hasher.update(&([_]u8{0} ** 8));
        hasher.update(&m_hash);
        hasher.update(salt);
        hasher.final(&h);
    }
    // 7-8. DB = PS || 0x01 || salt, emLen - hLen - 1 bytes.
    const db_len = em_len - h_len - 1;
    const db = em[0..db_len];
    @memset(db, 0);
    db[db_len - salt.len - 1] = 0x01;
    @memcpy(db[db_len - salt.len ..], salt);
    // 9-10. maskedDB = DB xor MGF1(H, emLen - hLen - 1).
    mgf1Xor(H, &h, db);
    // 11. Clear the leftmost 8 * emLen - emBits bits.
    const zero_bits: u3 = @intCast(8 * em_len - em_bits);
    db[0] &= @as(u8, 0xff) >> zero_bits;
    // 12. EM = maskedDB || H || 0xbc.
    @memcpy(em[db_len..][0..h_len], &h);
    em[em_len - 1] = 0xbc;
}

/// XORs MGF1(seed) (RFC 8017 B.2.1) over `out`.
fn mgf1Xor(comptime H: type, seed: *const [H.digest_length]u8, out: []u8) void {
    var counter: u32 = 0;
    var idx: usize = 0;
    while (idx < out.len) : (counter += 1) {
        var block: [H.digest_length]u8 = undefined;
        var hasher = H.init(.{});
        hasher.update(seed);
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        hasher.update(&c);
        hasher.final(&block);
        const n = @min(block.len, out.len - idx);
        for (out[idx..][0..n], block[0..n]) |*o, b| o.* ^= b;
        idx += n;
    }
}

/// A strict DER reader for RSAPrivateKey: definite minimal lengths and
/// minimal non-negative INTEGERs.
const Der = struct {
    buf: []const u8,
    pos: usize = 0,

    fn done(d: *const Der) bool {
        return d.pos == d.buf.len;
    }

    fn element(d: *Der, tag: u8) Error![]const u8 {
        if (d.buf.len - d.pos < 2 or d.buf[d.pos] != tag) return error.InvalidPrivateKey;
        const first = d.buf[d.pos + 1];
        var i = d.pos + 2;
        var len: usize = first;
        if (first & 0x80 != 0) {
            const n = first & 0x7f;
            // Long form only for lengths of 128 and more, without leading
            // zero bytes, and no indefinite length.
            if (n == 0 or n > 3 or d.buf.len - i < n or d.buf[i] == 0) return error.InvalidPrivateKey;
            len = 0;
            for (d.buf[i..][0..n]) |b| len = (len << 8) | b;
            if (len < 0x80) return error.InvalidPrivateKey;
            i += n;
        }
        if (d.buf.len - i < len) return error.InvalidPrivateKey;
        d.pos = i + len;
        return d.buf[i..][0..len];
    }

    /// A non-negative INTEGER's magnitude, without its sign byte.
    fn integer(d: *Der) Error![]const u8 {
        const v = try d.element(0x02);
        if (v.len == 0 or v[0] & 0x80 != 0) return error.InvalidPrivateKey;
        if (v.len > 1 and v[0] == 0) {
            if (v[1] & 0x80 == 0) return error.InvalidPrivateKey;
            return v[1..];
        }
        return v;
    }
};

// ---- tests ----------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("tls_fixtures");

fn keyFromPem(text: []const u8) !KeyPair {
    const pem = @import("pem.zig");
    const key = try pem.privateKey(testing.allocator, text);
    return switch (key) {
        .rsa => |kp| kp,
        else => error.TestUnexpectedResult,
    };
}

fn hexBytes(buf: []u8, hex: []const u8) ![]u8 {
    const text = std.mem.trim(u8, hex, " \n");
    return std.fmt.hexToBytes(buf, text);
}

const all_keys = [_][]const u8{
    fixtures.server_rsa_key, fixtures.rsa2049_key, fixtures.rsa2050_key, fixtures.rsa3072_key, fixtures.rsa4096_key,
};

test "PSS signatures verify with std's RSASSA-PSS and with this verifier for each hash and modulus size" {
    const Rsa = crypto.Certificate.rsa;
    const msg = "the content of a CertificateVerify";
    var prng = std.Random.DefaultPrng.init(0x5eed);
    for (all_keys) |text| {
        const kp = try keyFromPem(text);
        inline for (.{ .{ Hash.sha256, crypto.hash.sha2.Sha256 }, .{ Hash.sha384, crypto.hash.sha2.Sha384 }, .{ Hash.sha512, crypto.hash.sha2.Sha512 } }) |pair| {
            var salt: [pair[1].digest_length]u8 = undefined;
            prng.random().bytes(&salt);
            var out: [max_bytes]u8 = undefined;
            const sig = try kp.signPss(pair[0], msg, &salt, &out);
            try testing.expectEqual(kp.len, sig.len);
            try verifyPss(pair[0], kp.modulus(), kp.exponent(), sig, msg);
            try testing.expectError(error.InvalidSignature, verifyPss(pair[0], kp.modulus(), kp.exponent(), sig, "another message"));
            // std's verifier asserts on a modulus whose encoded message is a
            // byte shorter; it checks the other sizes independently.
            if ((kp.bits - 1) % 8 != 0) switch (kp.len) {
                inline 256, 384, 512 => |n| {
                    const public = try Rsa.PublicKey.fromBytes(kp.exponent(), kp.modulus());
                    try Rsa.PSSSignature.verify(n, sig[0..n].*, msg, public, pair[1]);
                },
                else => {},
            };
        }
    }
}

test "signatures with a pinned salt match an independent computation, including short encodings" {
    // rsa-pss-kat.py computes EMSA-PSS and m^d mod n with Python integers
    // for each key, this message and this salt; OpenSSL verifies each.
    var salt: [32]u8 = undefined;
    for (&salt, 0..) |*b, i| b.* = @intCast(i);
    const cases = [_]struct { key: []const u8, expected: []const u8 }{
        .{ .key = fixtures.server_rsa_key, .expected = fixtures.rsa_pss_kat_sha256 },
        // 2049 bits: the encoded message is a byte shorter than the modulus.
        .{ .key = fixtures.rsa2049_key, .expected = fixtures.rsa2049_pss_kat_sha256 },
        // 2050 bits: seven top bits of the encoded message are cleared.
        .{ .key = fixtures.rsa2050_key, .expected = fixtures.rsa2050_pss_kat_sha256 },
    };
    for (cases) |cs| {
        const kp = try keyFromPem(cs.key);
        var out: [max_bytes]u8 = undefined;
        const sig = try kp.signPss(.sha256, "klio RSA-PSS known answer", &salt, &out);
        var expected_buf: [max_bytes]u8 = undefined;
        const expected = try hexBytes(&expected_buf, cs.expected);
        try testing.expectEqualSlices(u8, expected, sig);
    }
}

test "a wrong private exponent is caught before the signature leaves" {
    var kp = try keyFromPem(fixtures.server_rsa_key);
    kp.d[kp.len - 1] ^= 0x02;
    var out: [max_bytes]u8 = undefined;
    try testing.expectError(error.SigningFailed, kp.signPss(.sha256, "m", &([_]u8{0} ** 32), &out));
}

test "a wrong salt length or a short buffer is refused" {
    const kp = try keyFromPem(fixtures.server_rsa_key);
    var out: [max_bytes]u8 = undefined;
    try testing.expectError(error.SigningFailed, kp.signPss(.sha256, "m", &([_]u8{0} ** 20), &out));
    try testing.expectError(error.SigningFailed, kp.signPss(.sha256, "m", &([_]u8{0} ** 32), out[0..100]));
}

test "the verifier refuses altered signatures, keys and encodings" {
    const kp = try keyFromPem(fixtures.rsa2049_key);
    var out: [max_bytes]u8 = undefined;
    const sig = try kp.signPss(.sha256, "m", &([_]u8{9} ** 32), &out);
    const n = kp.modulus();
    const e = kp.exponent();
    try verifyPss(.sha256, n, e, sig, "m");
    try testing.expectError(error.InvalidSignature, verifyPss(.sha384, n, e, sig, "m"));
    var bad: [max_bytes]u8 = undefined;
    @memcpy(bad[0..sig.len], sig);
    bad[sig.len - 1] ^= 1;
    try testing.expectError(error.InvalidSignature, verifyPss(.sha256, n, e, bad[0..sig.len], "m"));
    // A signature of the wrong length, and one not below the modulus.
    try testing.expectError(error.InvalidSignature, verifyPss(.sha256, n, e, sig[1..], "m"));
    try testing.expectError(error.InvalidSignature, verifyPss(.sha256, n, e, n, "m"));
    // Keys the verifier does not take.
    try testing.expectError(error.InvalidSignature, verifyPss(.sha256, n, &.{2}, sig, "m"));
    try testing.expectError(error.InvalidSignature, verifyPss(.sha256, n, &.{ 1, 0, 0, 0, 1 }, sig, "m"));
    try testing.expectError(error.InvalidSignature, verifyPss(.sha256, n[0..64], e, sig[0..64], "m"));
    // A leading zero on the modulus is ignored, as in a DER INTEGER.
    var padded: [max_bytes + 1]u8 = undefined;
    padded[0] = 0;
    @memcpy(padded[1 .. n.len + 1], n);
    try verifyPss(.sha256, padded[0 .. n.len + 1], e, sig, "m");
}

test "EMSA-PSS clears the top bits, ends in 0xbc and embeds the salt" {
    const H = crypto.hash.sha2.Sha256;
    var em: [256]u8 = undefined;
    const salt = [_]u8{0xab} ** 32;
    try emsaPssEncode(H, "m", &salt, 2047, &em);
    try testing.expectEqual(@as(u8, 0xbc), em[255]);
    try testing.expect(em[0] & 0x80 == 0);
    try emsaPssVerify(H, "m", &em, 2047);
    // Unmask DB and find PS || 0x01 || salt.
    var db: [256 - 33]u8 = undefined;
    @memcpy(&db, em[0..db.len]);
    mgf1Xor(H, em[db.len..][0..32], &db);
    db[0] &= 0x7f;
    for (db[0 .. db.len - 33]) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(@as(u8, 1), db[db.len - 33]);
    try testing.expectEqualSlices(u8, &salt, db[db.len - 32 ..]);
    try testing.expectError(error.EncodingError, emsaPssEncode(H, "m", &salt, 2047, em[0..255]));
    // A set top bit, a wrong trailer.
    var bad = em;
    bad[0] |= 0x80;
    try testing.expectError(error.InvalidSignature, emsaPssVerify(H, "m", &bad, 2047));
    bad = em;
    bad[255] = 0xbd;
    try testing.expectError(error.InvalidSignature, emsaPssVerify(H, "m", &bad, 2047));
}

test "key parts outside the served range are refused" {
    const kp = try keyFromPem(fixtures.server_rsa_key);
    const n = kp.modulus();
    const d = std.mem.trimStart(u8, kp.d[0..kp.len], &.{0});
    var out: KeyPair = undefined;
    try testing.expectError(error.UnsupportedRsaKey, KeyPair.fromParts(&out, n, &.{ 1, 0, 0, 0, 1 }, d));
    try testing.expectError(error.UnsupportedRsaKey, KeyPair.fromParts(&out, n, &.{2}, d));
    try testing.expectError(error.UnsupportedRsaKey, KeyPair.fromParts(&out, n, &.{1}, d));
    try testing.expectError(error.UnsupportedRsaKey, KeyPair.fromParts(&out, n, &.{ 1, 0 }, d));
    // e = 3 and e = 2^32 - 1 are accepted.
    try KeyPair.fromParts(&out, n, &.{3}, d);
    try KeyPair.fromParts(&out, n, &.{ 0xff, 0xff, 0xff, 0xff }, d);
    // d >= n, d = 0, leading zeros.
    try testing.expectError(error.InvalidPrivateKey, KeyPair.fromParts(&out, n, &.{3}, n));
    try testing.expectError(error.InvalidPrivateKey, KeyPair.fromParts(&out, n, &.{3}, &.{0}));
    try testing.expectError(error.InvalidPrivateKey, KeyPair.fromParts(&out, n, &.{ 0, 3 }, d));
    // A 1024-bit modulus.
    var small: [128]u8 = n[0..128].*;
    small[127] |= 1;
    try testing.expectError(error.UnsupportedRsaKey, KeyPair.fromParts(&out, &small, &.{3}, &.{5}));
    // An even modulus.
    var even: [256]u8 = undefined;
    @memcpy(&even, n);
    even[255] &= 0xfe;
    try testing.expectError(error.InvalidPrivateKey, KeyPair.fromParts(&out, &even, &.{3}, &.{5}));
}

test "a short private exponent is left-padded to the modulus length" {
    const kp = try keyFromPem(fixtures.server_rsa_key);
    var out: KeyPair = undefined;
    try KeyPair.fromParts(&out, kp.modulus(), kp.exponent(), &.{ 0x01, 0x05 });
    for (out.d[0 .. out.len - 2]) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x05 }, out.d[out.len - 2 .. out.len]);
    for (out.d[out.len..]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "strict DER: non-minimal integers and lengths are refused" {
    var d: Der = .{ .buf = &.{ 0x02, 0x02, 0x00, 0x01 } };
    try testing.expectError(error.InvalidPrivateKey, d.integer());
    d = .{ .buf = &.{ 0x02, 0x01, 0x80 } };
    try testing.expectError(error.InvalidPrivateKey, d.integer());
    d = .{ .buf = &.{ 0x02, 0x00 } };
    try testing.expectError(error.InvalidPrivateKey, d.integer());
    d = .{ .buf = &.{ 0x02, 0x81, 0x01, 0x05 } };
    try testing.expectError(error.InvalidPrivateKey, d.integer());
    const padded_len = [_]u8{ 0x02, 0x82, 0x00, 0x81 } ++ [_]u8{1} ** 0x81;
    d = .{ .buf = &padded_len };
    try testing.expectError(error.InvalidPrivateKey, d.integer());
    d = .{ .buf = &.{ 0x02, 0x80, 0x01, 0x00, 0x00 } };
    try testing.expectError(error.InvalidPrivateKey, d.integer());
    d = .{ .buf = &.{ 0x02, 0x02, 0x00, 0x80 } };
    try testing.expectEqualSlices(u8, &.{0x80}, try d.integer());
    var out: KeyPair = undefined;
    // Trailing bytes after the key's SEQUENCE.
    try testing.expectError(error.InvalidPrivateKey, KeyPair.fromPkcs1(&out, &.{ 0x30, 0x03, 0x02, 0x01, 0x00, 0x00 }));
    // The multi-prime form.
    try testing.expectError(error.UnsupportedRsaKey, KeyPair.fromPkcs1(&out, &.{ 0x30, 0x03, 0x02, 0x01, 0x01 }));
}

test "the key matches its certificate's public key and no other" {
    const kp = try keyFromPem(fixtures.server_rsa_key);
    const pem = @import("pem.zig");
    const certs = try pem.certificates(testing.allocator, fixtures.server_rsa);
    defer {
        for (certs) |c| testing.allocator.free(c);
        testing.allocator.free(certs);
    }
    const parsed = try (crypto.Certificate{ .buffer = certs[0], .index = 0 }).parse();
    try testing.expect(kp.matchesPublicKey(parsed.pubKey()));
    const other = try keyFromPem(fixtures.rsa3072_key);
    try testing.expect(!other.matchesPublicKey(parsed.pubKey()));
}

test "wiping clears the private exponent" {
    var kp = try keyFromPem(fixtures.server_rsa_key);
    kp.wipe();
    for (kp.d) |b| try testing.expectEqual(@as(u8, 0), b);
}
