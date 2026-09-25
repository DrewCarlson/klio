//! The TLS 1.3 cipher suites and the key schedule over them (RFC 8446 §7).
//! Every primitive is std.crypto's: the AEADs, SHA-2, HMAC and HKDF, with
//! `std.crypto.tls.hkdfExpandLabel` for the labelled expansions. A suite is
//! chosen at run time, so secrets and keys live in fixed-size buffers sized
//! for the largest suite and each operation dispatches on the suite once.

const std = @import("std");
const crypto = std.crypto;
const tls = crypto.tls;

pub const Suite = enum(u16) {
    aes_128_gcm_sha256 = 0x1301,
    aes_256_gcm_sha384 = 0x1302,
    chacha20_poly1305_sha256 = 0x1303,

    pub fn fromWire(v: u16) ?Suite {
        return std.enums.fromInt(Suite, v);
    }

    pub fn hashLen(s: Suite) usize {
        return switch (s) {
            inline else => |t| Params(t).hash_len,
        };
    }
};

pub fn Params(comptime s: Suite) type {
    return struct {
        pub const Aead = switch (s) {
            .aes_128_gcm_sha256 => crypto.aead.aes_gcm.Aes128Gcm,
            .aes_256_gcm_sha384 => crypto.aead.aes_gcm.Aes256Gcm,
            .chacha20_poly1305_sha256 => crypto.aead.chacha_poly.ChaCha20Poly1305,
        };
        pub const Hash = switch (s) {
            .aes_128_gcm_sha256, .chacha20_poly1305_sha256 => crypto.hash.sha2.Sha256,
            .aes_256_gcm_sha384 => crypto.hash.sha2.Sha384,
        };
        pub const Hmac = crypto.auth.hmac.Hmac(Hash);
        pub const Hkdf = crypto.kdf.hkdf.Hkdf(Hmac);
        pub const hash_len = Hash.digest_length;
        pub const key_len = Aead.key_length;
        pub const tag_len = Aead.tag_length;
    };
}

pub const max_hash_len = 48;
pub const max_key_len = 32;
pub const iv_len = 12;
pub const tag_len = 16;

comptime {
    for (std.enums.values(Suite)) |s| {
        std.debug.assert(Params(s).Aead.nonce_length == iv_len);
        std.debug.assert(Params(s).tag_len == tag_len);
    }
}

/// A secret of the suite's hash length.
pub const Secret = struct {
    bytes: [max_hash_len]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(s: *const Secret) []const u8 {
        return s.bytes[0..s.len];
    }

    fn of(comptime n: usize, b: [n]u8) Secret {
        var out: Secret = .{ .len = n };
        @memcpy(out.bytes[0..n], &b);
        return out;
    }

    pub fn wipe(s: *Secret) void {
        crypto.secureZero(u8, &s.bytes);
        s.len = 0;
    }
};

/// A transcript hash value.
pub const Digest = Secret;

pub fn hash(suite: Suite, data: []const u8) Digest {
    return switch (suite) {
        inline else => |s| blk: {
            const P = Params(s);
            var out: [P.hash_len]u8 = undefined;
            P.Hash.hash(data, &out, .{});
            break :blk Secret.of(P.hash_len, out);
        },
    };
}

fn hashArray(comptime P: type, d: []const u8) [P.hash_len]u8 {
    return d[0..P.hash_len].*;
}

pub fn extract(suite: Suite, salt: []const u8, ikm: []const u8) Secret {
    return switch (suite) {
        inline else => |s| Secret.of(Params(s).hash_len, Params(s).Hkdf.extract(salt, ikm)),
    };
}

/// HKDF-Expand-Label producing a secret of the hash length.
pub fn expandSecret(suite: Suite, secret: *const Secret, label: []const u8, context: []const u8) Secret {
    return switch (suite) {
        inline else => |s| blk: {
            const P = Params(s);
            break :blk Secret.of(P.hash_len, tls.hkdfExpandLabel(P.Hkdf, hashArray(P, secret.slice()), label, context, P.hash_len));
        },
    };
}

/// Derive-Secret(secret, label, messages) with the transcript hash given.
pub fn deriveSecret(suite: Suite, secret: *const Secret, label: []const u8, transcript: *const Digest) Secret {
    return expandSecret(suite, secret, label, transcript.slice());
}

pub fn emptyHash(suite: Suite) Digest {
    return hash(suite, "");
}

/// The early secret with no PSK: HKDF-Extract(0, 0).
pub fn earlySecret(suite: Suite) Secret {
    const zeros: [max_hash_len]u8 = @splat(0);
    const n = suite.hashLen();
    return extract(suite, zeros[0..n], zeros[0..n]);
}

/// The handshake secret from the (EC)DHE shared secret.
pub fn handshakeSecret(suite: Suite, shared: []const u8) Secret {
    const early = earlySecret(suite);
    const empty = emptyHash(suite);
    const derived = deriveSecret(suite, &early, "derived", &empty);
    return extract(suite, derived.slice(), shared);
}

pub fn masterSecret(suite: Suite, handshake_secret: *const Secret) Secret {
    const empty = emptyHash(suite);
    const derived = deriveSecret(suite, handshake_secret, "derived", &empty);
    const zeros: [max_hash_len]u8 = @splat(0);
    return extract(suite, derived.slice(), zeros[0..suite.hashLen()]);
}

/// Finished verify_data: HMAC(finished_key, transcript hash).
pub fn finishedData(suite: Suite, traffic_secret: *const Secret, transcript: *const Digest) Digest {
    return switch (suite) {
        inline else => |s| blk: {
            const P = Params(s);
            const key = tls.hkdfExpandLabel(P.Hkdf, hashArray(P, traffic_secret.slice()), "finished", "", P.Hmac.key_length);
            var out: [P.Hmac.mac_length]u8 = undefined;
            P.Hmac.create(&out, transcript.slice(), &key);
            break :blk Secret.of(P.Hmac.mac_length, out);
        },
    };
}

/// Compares received verify_data with the expected value in constant time.
pub fn finishedMatches(expected: *const Digest, received: []const u8) bool {
    if (received.len != expected.len) return false;
    var diff: u8 = 0;
    for (expected.slice(), received) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// One direction's record protection: the traffic secret, its key and IV,
/// and the record sequence number.
pub const Cipher = struct {
    suite: Suite,
    secret: Secret,
    key: [max_key_len]u8 = @splat(0),
    iv: [iv_len]u8 = @splat(0),
    seq: u64 = 0,

    pub fn init(suite: Suite, secret: Secret) Cipher {
        var c: Cipher = .{ .suite = suite, .secret = secret };
        switch (suite) {
            inline else => |s| {
                const P = Params(s);
                const prk = hashArray(P, secret.slice());
                const key = tls.hkdfExpandLabel(P.Hkdf, prk, "key", "", P.key_len);
                @memcpy(c.key[0..P.key_len], &key);
                c.iv = tls.hkdfExpandLabel(P.Hkdf, prk, "iv", "", iv_len);
            },
        }
        return c;
    }

    /// The next generation of this direction's keys (KeyUpdate).
    pub fn updated(c: *const Cipher) Cipher {
        return .init(c.suite, expandSecret(c.suite, &c.secret, "traffic upd", ""));
    }

    pub fn wipe(c: *Cipher) void {
        c.secret.wipe();
        crypto.secureZero(u8, &c.key);
        crypto.secureZero(u8, &c.iv);
    }

    fn nonce(c: *const Cipher) [iv_len]u8 {
        var n = c.iv;
        var seq: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq, c.seq, .big);
        for (seq, 0..) |b, i| n[iv_len - 8 + i] ^= b;
        return n;
    }

    /// Encrypts `plaintext` into `out` (same length) with `tag`, the record
    /// header `ad` as associated data, and advances the sequence number.
    pub fn seal(c: *Cipher, out: []u8, tag: *[tag_len]u8, plaintext: []const u8, ad: []const u8) error{SequenceExhausted}!void {
        if (c.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
        const n = c.nonce();
        switch (c.suite) {
            inline else => |s| {
                const P = Params(s);
                P.Aead.encrypt(out, tag, plaintext, ad, n, c.key[0..P.key_len].*);
            },
        }
        c.seq += 1;
    }

    /// Decrypts and authenticates; the sequence number advances only on success.
    pub fn open(c: *Cipher, out: []u8, ciphertext: []const u8, tag: [tag_len]u8, ad: []const u8) error{ BadRecordMac, SequenceExhausted }!void {
        if (c.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
        const n = c.nonce();
        switch (c.suite) {
            inline else => |s| {
                const P = Params(s);
                P.Aead.decrypt(out, ciphertext, tag, ad, n, c.key[0..P.key_len].*) catch return error.BadRecordMac;
            },
        }
        c.seq += 1;
    }
};

const testing = std.testing;

fn unhex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "the RFC 8448 simple handshake key schedule" {
    const suite: Suite = .aes_128_gcm_sha256;
    const early = earlySecret(suite);
    try testing.expectEqualSlices(u8, &unhex("33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"), early.slice());
    const shared = unhex("8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d");
    const hs = handshakeSecret(suite, &shared);
    try testing.expectEqualSlices(u8, &unhex("1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac"), hs.slice());
    const hello_hash = Secret.of(32, unhex("860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8"));
    const s_hs = deriveSecret(suite, &hs, "s hs traffic", &hello_hash);
    try testing.expectEqualSlices(u8, &unhex("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38"), s_hs.slice());
    const c = Cipher.init(suite, s_hs);
    try testing.expectEqualSlices(u8, &unhex("3fce516009c21727d0f2e4e86ee403bc"), c.key[0..16]);
    try testing.expectEqualSlices(u8, &unhex("5d313eb2671276ee13000b30"), &c.iv);
    const master = masterSecret(suite, &hs);
    try testing.expectEqualSlices(u8, &unhex("18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919"), master.slice());
    const handshake_hash = Secret.of(32, unhex("9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13"));
    const c_ap = deriveSecret(suite, &master, "c ap traffic", &handshake_hash);
    try testing.expectEqualSlices(u8, &unhex("9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5"), c_ap.slice());
    const client_app = Cipher.init(suite, c_ap);
    try testing.expectEqualSlices(u8, &unhex("17422dda596ed5d9acd890e3c63f5051"), client_app.key[0..16]);
    try testing.expectEqualSlices(u8, &unhex("5b78923dee08579033e523d9"), &client_app.iv);
}

test "a sealed record opens once, and not after tampering" {
    const suite: Suite = .chacha20_poly1305_sha256;
    const secret = extract(suite, "salt", "ikm");
    var w = Cipher.init(suite, secret);
    var r = Cipher.init(suite, secret);
    const ad = [_]u8{ 0x17, 0x03, 0x03, 0x00, 0x15 };
    var ct: [5]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    try w.seal(&ct, &tag, "hello", &ad);
    var pt: [5]u8 = undefined;
    try r.open(&pt, &ct, tag, &ad);
    try testing.expectEqualStrings("hello", &pt);
    // The reader is now one record ahead, so a replay of the same record fails.
    try testing.expectError(error.BadRecordMac, r.open(&pt, &ct, tag, &ad));
    var r2 = Cipher.init(suite, secret);
    ct[0] ^= 1;
    try testing.expectError(error.BadRecordMac, r2.open(&pt, &ct, tag, &ad));
    try testing.expectEqual(@as(u64, 0), r2.seq);
}

test "a key update derives the next traffic secret" {
    const suite: Suite = .aes_256_gcm_sha384;
    const c = Cipher.init(suite, extract(suite, "a", "b"));
    const next = c.updated();
    try testing.expect(!std.mem.eql(u8, c.secret.slice(), next.secret.slice()));
    try testing.expectEqual(@as(u8, 48), next.secret.len);
    try testing.expectEqual(@as(u64, 0), next.seq);
}
