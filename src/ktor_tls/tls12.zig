//! TLS 1.2 (RFC 5246) for the client side: the ECDHE AEAD cipher suites, the
//! PRF, the master secret (plain or RFC 7627's extended form), the key block,
//! Finished values, and record protection. AES-GCM records carry RFC 5288's
//! explicit 8-byte nonce; ChaCha20-Poly1305 records use RFC 7905's IV XOR
//! sequence nonce. Every primitive is std.crypto's, and the PRF is std's
//! P_hash (`std.crypto.tls.hmacExpandLabel`).

const std = @import("std");
const crypto = std.crypto;
const tls = crypto.tls;
const suites = @import("suites.zig");

pub const Digest = suites.Digest;

pub const Suite12 = enum(u16) {
    ecdhe_ecdsa_aes_128_gcm_sha256 = 0xc02b,
    ecdhe_ecdsa_aes_256_gcm_sha384 = 0xc02c,
    ecdhe_rsa_aes_128_gcm_sha256 = 0xc02f,
    ecdhe_rsa_aes_256_gcm_sha384 = 0xc030,
    ecdhe_rsa_chacha20_poly1305_sha256 = 0xcca8,
    ecdhe_ecdsa_chacha20_poly1305_sha256 = 0xcca9,

    pub fn fromWire(v: u16) ?Suite12 {
        return std.enums.fromInt(Suite12, v);
    }

    /// Whether the server authenticates with an RSA key (otherwise ECDSA or
    /// EdDSA).
    pub fn rsa(s: Suite12) bool {
        return switch (s) {
            .ecdhe_rsa_aes_128_gcm_sha256, .ecdhe_rsa_aes_256_gcm_sha384, .ecdhe_rsa_chacha20_poly1305_sha256 => true,
            else => false,
        };
    }
};

pub const default_suites = [_]Suite12{
    .ecdhe_ecdsa_aes_128_gcm_sha256,
    .ecdhe_rsa_aes_128_gcm_sha256,
    .ecdhe_ecdsa_chacha20_poly1305_sha256,
    .ecdhe_rsa_chacha20_poly1305_sha256,
    .ecdhe_ecdsa_aes_256_gcm_sha384,
    .ecdhe_rsa_aes_256_gcm_sha384,
};

pub fn Params(comptime s: Suite12) type {
    return struct {
        pub const Aead = switch (s) {
            .ecdhe_ecdsa_aes_128_gcm_sha256, .ecdhe_rsa_aes_128_gcm_sha256 => crypto.aead.aes_gcm.Aes128Gcm,
            .ecdhe_ecdsa_aes_256_gcm_sha384, .ecdhe_rsa_aes_256_gcm_sha384 => crypto.aead.aes_gcm.Aes256Gcm,
            .ecdhe_rsa_chacha20_poly1305_sha256, .ecdhe_ecdsa_chacha20_poly1305_sha256 => crypto.aead.chacha_poly.ChaCha20Poly1305,
        };
        pub const Hash = switch (s) {
            .ecdhe_ecdsa_aes_256_gcm_sha384, .ecdhe_rsa_aes_256_gcm_sha384 => crypto.hash.sha2.Sha384,
            else => crypto.hash.sha2.Sha256,
        };
        pub const Hmac = crypto.auth.hmac.Hmac(Hash);
        pub const hash_len = Hash.digest_length;
        pub const key_len = Aead.key_length;
        /// The part of the nonce the key block supplies.
        pub const fixed_iv_len = if (Aead == crypto.aead.chacha_poly.ChaCha20Poly1305) 12 else 4;
        /// The part of the nonce each record carries.
        pub const explicit_nonce_len = if (Aead == crypto.aead.chacha_poly.ChaCha20Poly1305) 0 else 8;
    };
}

pub const tag_len = 16;
pub const verify_data_len = 12;
pub const master_secret_len = 48;

comptime {
    for (std.enums.values(Suite12)) |s| {
        std.debug.assert(Params(s).Aead.tag_length == tag_len);
        std.debug.assert(Params(s).Aead.nonce_length == 12);
    }
}

pub fn hashLen(suite: Suite12) usize {
    return switch (suite) {
        inline else => |s| Params(s).hash_len,
    };
}

/// The transcript hash under the suite's PRF hash.
pub fn hash(suite: Suite12, data: []const u8) Digest {
    return switch (suite) {
        inline else => |s| blk: {
            const P = Params(s);
            var out: Digest = .{ .len = P.hash_len };
            P.Hash.hash(data, out.bytes[0..P.hash_len], .{});
            break :blk out;
        },
    };
}

/// PRF(secret, label, seed) (RFC 5246 §5), `len` bytes.
fn prf(comptime P: type, secret: []const u8, label: []const u8, seed: []const []const u8, comptime len: usize) [len]u8 {
    var parts: [4][]const u8 = undefined;
    parts[0] = label;
    for (seed, 1..) |part, i| parts[i] = part;
    return tls.hmacExpandLabel(P.Hmac, secret, parts[0 .. 1 + seed.len], len);
}

/// The master secret from the (EC)DHE shared secret: over both randoms, or
/// over the session hash (the handshake through ClientKeyExchange) when
/// both sides agreed to the extended master secret.
pub fn masterSecret(
    suite: Suite12,
    pre_master: []const u8,
    client_random: *const [32]u8,
    server_random: *const [32]u8,
    session_hash: ?*const Digest,
) [master_secret_len]u8 {
    return switch (suite) {
        inline else => |s| blk: {
            const P = Params(s);
            if (session_hash) |h| break :blk prf(P, pre_master, "extended master secret", &.{h.slice()}, master_secret_len);
            break :blk prf(P, pre_master, "master secret", &.{ client_random, server_random }, master_secret_len);
        },
    };
}

pub const Side = enum { client, server };

/// verify_data for a Finished message.
pub fn verifyData(suite: Suite12, master: *const [master_secret_len]u8, side: Side, transcript: *const Digest) [verify_data_len]u8 {
    const label = switch (side) {
        .client => "client finished",
        .server => "server finished",
    };
    return switch (suite) {
        inline else => |s| prf(Params(s), master, label, &.{transcript.slice()}, verify_data_len),
    };
}

/// Compares received verify_data with the expected value in constant time.
pub fn verifyDataMatches(expected: *const [verify_data_len]u8, received: []const u8) bool {
    if (received.len != verify_data_len) return false;
    return crypto.timing_safe.eql([verify_data_len]u8, expected.*, received[0..verify_data_len].*);
}

pub const Keys = struct { client: Cipher12, server: Cipher12 };

/// The key block (client and server write keys, then IVs) as ciphers.
pub fn keys(suite: Suite12, master: *const [master_secret_len]u8, client_random: *const [32]u8, server_random: *const [32]u8) Keys {
    return switch (suite) {
        inline else => |s| blk: {
            const P = Params(s);
            const n = 2 * P.key_len + 2 * P.fixed_iv_len;
            var block = prf(P, master, "key expansion", &.{ server_random, client_random }, n);
            defer crypto.secureZero(u8, &block);
            var out: Keys = .{ .client = .{ .suite = suite }, .server = .{ .suite = suite } };
            @memcpy(out.client.key[0..P.key_len], block[0..P.key_len]);
            @memcpy(out.server.key[0..P.key_len], block[P.key_len..][0..P.key_len]);
            @memcpy(out.client.iv[0..P.fixed_iv_len], block[2 * P.key_len ..][0..P.fixed_iv_len]);
            @memcpy(out.server.iv[0..P.fixed_iv_len], block[2 * P.key_len + P.fixed_iv_len ..][0..P.fixed_iv_len]);
            break :blk out;
        },
    };
}

/// One direction's TLS 1.2 record protection.
pub const Cipher12 = struct {
    suite: Suite12,
    key: [32]u8 = @splat(0),
    /// GCM: the 4-byte salt; ChaCha20-Poly1305: the 12-byte IV.
    iv: [12]u8 = @splat(0),
    seq: u64 = 0,

    pub fn explicitLen(c: *const Cipher12) usize {
        return switch (c.suite) {
            inline else => |s| Params(s).explicit_nonce_len,
        };
    }

    /// Bytes a protected record adds to its plaintext.
    pub fn overhead(c: *const Cipher12) usize {
        return c.explicitLen() + tag_len;
    }

    pub fn wipe(c: *Cipher12) void {
        crypto.secureZero(u8, &c.key);
        crypto.secureZero(u8, &c.iv);
    }

    fn additionalData(seq: u64, ct: u8, len: usize) [13]u8 {
        var ad: [13]u8 = undefined;
        std.mem.writeInt(u64, ad[0..8], seq, .big);
        ad[8] = ct;
        ad[9] = 0x03;
        ad[10] = 0x03;
        std.mem.writeInt(u16, ad[11..13], @intCast(len), .big);
        return ad;
    }

    fn chachaNonce(c: *const Cipher12) [12]u8 {
        var n = c.iv;
        var seq: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq, c.seq, .big);
        for (seq, 0..) |b, i| n[4 + i] ^= b;
        return n;
    }

    /// Protects `plaintext`, a record of type `ct`, into `out`, which is
    /// `overhead()` bytes longer: the explicit nonce (GCM), the ciphertext
    /// and the tag. The explicit nonce is the sequence number.
    pub fn seal(c: *Cipher12, out: []u8, ct: u8, plaintext: []const u8) error{SequenceExhausted}!void {
        if (c.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
        const ad = additionalData(c.seq, ct, plaintext.len);
        switch (c.suite) {
            inline else => |s| {
                const P = Params(s);
                std.debug.assert(out.len == P.explicit_nonce_len + plaintext.len + tag_len);
                var nonce: [12]u8 = undefined;
                if (P.explicit_nonce_len == 0) {
                    nonce = c.chachaNonce();
                } else {
                    @memcpy(nonce[0..4], c.iv[0..4]);
                    std.mem.writeInt(u64, nonce[4..12], c.seq, .big);
                    @memcpy(out[0..8], nonce[4..12]);
                }
                const body = out[P.explicit_nonce_len..][0..plaintext.len];
                const tag = out[P.explicit_nonce_len + plaintext.len ..][0..tag_len];
                P.Aead.encrypt(body, tag, plaintext, &ad, nonce, c.key[0..P.key_len].*);
            },
        }
        c.seq += 1;
    }

    /// Opens a protected record of type `ct` into `out`, which is
    /// `overhead()` bytes shorter than `payload`. The sequence number
    /// advances only on success.
    pub fn open(c: *Cipher12, out: []u8, ct: u8, payload: []const u8) error{ BadRecordMac, SequenceExhausted }!void {
        if (c.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
        switch (c.suite) {
            inline else => |s| {
                const P = Params(s);
                if (payload.len < P.explicit_nonce_len + tag_len) return error.BadRecordMac;
                const body_len = payload.len - P.explicit_nonce_len - tag_len;
                std.debug.assert(out.len == body_len);
                var nonce: [12]u8 = undefined;
                if (P.explicit_nonce_len == 0) {
                    nonce = c.chachaNonce();
                } else {
                    @memcpy(nonce[0..4], c.iv[0..4]);
                    @memcpy(nonce[4..12], payload[0..8]);
                }
                const ad = additionalData(c.seq, ct, body_len);
                const body = payload[P.explicit_nonce_len..][0..body_len];
                const tag = payload[P.explicit_nonce_len + body_len ..][0..tag_len].*;
                P.Aead.decrypt(out, body, tag, &ad, nonce, c.key[0..P.key_len].*) catch return error.BadRecordMac;
            },
        }
        c.seq += 1;
    }
};

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn unhex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

fn range(comptime n: usize, comptime start: u8) [n]u8 {
    var out: [n]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = start + @as(u8, @intCast(i));
    return out;
}

test "the PRF matches the published SHA-256 and SHA-384 vectors" {
    const P256 = Params(.ecdhe_rsa_aes_128_gcm_sha256);
    const out256 = prf(P256, &unhex("9bbe436ba940f017b17652849a71db35"), "test label", &.{&unhex("a0ba9f936cda311827a6f796ffd5198c")}, 100);
    try testing.expectEqualSlices(u8, &unhex("e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a6b301791e90d35c9c9a46b4e14baf9af0fa022f7077def17abfd3797c0564bab4fbc91666e9def9b97fce34f796789baa48082d122ee42c5a72e5a5110fff70187347b66"), &out256);
    const P384 = Params(.ecdhe_rsa_aes_256_gcm_sha384);
    const out384 = prf(P384, &unhex("b80b733d6ceefcdc71566ea48e5567df"), "test label", &.{&unhex("cd665cf6a8447dd6ff8b27555edb7465")}, 148);
    try testing.expectEqualSlices(u8, &unhex("7b0c18e9ced410ed1804f2cfa34a336a1c14dffb4900bb5fd7942107e81c83cde9ca0faa60be9fe34f82b1233c9146a0e534cb400fed2700884f9dc236f80edd8bfa961144c9e8d792eca722a7b32fc3d416d473ebc2c5fd4abfdad05d9184259b5bf8cd4d90fa0d31e2dec479e4f1a26066f2eea9a69236a3e52655c9e9aee691c8f3a26854308d5eaa3be85e0990703d73e56f"), &out384);
}

// The expected values below come from OpenSSL 3.6's TLS1-PRF KDF over the
// same inputs.
test "the key schedule matches OpenSSL for both PRF hashes" {
    const cr = range(32, 0xa0);
    const sr = range(32, 0xb0);
    {
        const suite: Suite12 = .ecdhe_ecdsa_chacha20_poly1305_sha256;
        const pre = range(32, 1);
        const master = masterSecret(suite, &pre, &cr, &sr, null);
        try testing.expectEqualSlices(u8, &unhex("862132d900a80f579b5bb6d4f3c2471624323399972044750d3ebcb25077dd622f9ef49eccb62b6dbb4c2543b17f5b7a"), &master);
        const session_hash: Digest = .{ .bytes = range(32, 0xc0) ++ @as([16]u8, @splat(0)), .len = 32 };
        const ems = masterSecret(suite, &pre, &cr, &sr, &session_hash);
        try testing.expectEqualSlices(u8, &unhex("e2ce921f8ffc05eb3be904de41650489346bdb879425a5a8e58d37133f685de2920146c98eea9b43a0960e1ae1b14aa7"), &ems);
        // ChaCha20-Poly1305: two 32-byte keys, then two 12-byte IVs.
        const k = keys(suite, &master, &cr, &sr);
        const block = unhex("faccf980f834b4303068feea8c0a73aab1bd6ecc2faa58861f78dba2c72d3765967d1e968fda3801887dfbadf09e536f2ef95cbf6efc930d34c7d3c48db1775f7bd39a88294476238177f2b68de6476596ff5507401c0a82");
        try testing.expectEqualSlices(u8, block[0..32], &k.client.key);
        try testing.expectEqualSlices(u8, block[32..64], &k.server.key);
        try testing.expectEqualSlices(u8, block[64..76], &k.client.iv);
        try testing.expectEqualSlices(u8, block[76..88], &k.server.iv);
        const fin: Digest = .{ .bytes = range(32, 0x10) ++ @as([16]u8, @splat(0)), .len = 32 };
        try testing.expectEqualSlices(u8, &unhex("9c2d201be930b73a76e39d58"), &verifyData(suite, &master, .client, &fin));
        try testing.expectEqualSlices(u8, &unhex("badb338a97c2c28d0c49370e"), &verifyData(suite, &master, .server, &fin));
    }
    {
        const suite: Suite12 = .ecdhe_rsa_aes_256_gcm_sha384;
        const pre = range(48, 1);
        const master = masterSecret(suite, &pre, &cr, &sr, null);
        try testing.expectEqualSlices(u8, &unhex("5c50295662e9ac75915cad24a5e9c244116cbdae3ca2b5041efa8ab82d9373dd2dba6ffaa0d256d64a6301705095e519"), &master);
        const session_hash: Digest = .{ .bytes = range(48, 0x40), .len = 48 };
        const ems = masterSecret(suite, &pre, &cr, &sr, &session_hash);
        try testing.expectEqualSlices(u8, &unhex("f4db21ab1b4cea2ed46e363020d794be5979cc41ddaae9810401cc7e0c77764fc398f57f3bdd2cd3c8429b4785b545d9"), &ems);
        // AES-256-GCM: two 32-byte keys, then two 4-byte salts.
        const k = keys(suite, &master, &cr, &sr);
        const block = unhex("3748acfcb4dffd754320ae9f91b530231ac9af49a49fce12ea76060f8b7735b9725f0744e890901fbd5676817babe9b444fa46e4a12c0192018a83951a03f5f9a1aecba153f3588022ffced502c0686ef9ce634c9de612b3");
        try testing.expectEqualSlices(u8, block[0..32], &k.client.key);
        try testing.expectEqualSlices(u8, block[32..64], &k.server.key);
        try testing.expectEqualSlices(u8, block[64..68], k.client.iv[0..4]);
        try testing.expectEqualSlices(u8, block[68..72], k.server.iv[0..4]);
        const fin: Digest = .{ .bytes = range(48, 0x50), .len = 48 };
        try testing.expectEqualSlices(u8, &unhex("eec33a3539c535e71e9ba794"), &verifyData(suite, &master, .client, &fin));
        try testing.expectEqualSlices(u8, &unhex("8b3f7ae95117f40c462906ea"), &verifyData(suite, &master, .server, &fin));
    }
}

test "records follow RFC 5288 and RFC 7905: nonce, additional data and layout" {
    // GCM: the payload is the explicit nonce (the sequence number), the
    // ciphertext and the tag, over salt || explicit nonce and
    // seq || type || version || length.
    var c: Cipher12 = .{ .suite = .ecdhe_ecdsa_aes_128_gcm_sha256, .seq = 5 };
    @memcpy(c.key[0..16], &range(16, 0x30));
    @memcpy(c.iv[0..4], &[_]u8{ 1, 2, 3, 4 });
    var out: [8 + 5 + 16]u8 = undefined;
    try c.seal(&out, 23, "hello");
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 5 }, out[0..8]);
    var want: [5]u8 = undefined;
    var want_tag: [16]u8 = undefined;
    const ad = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 5, 23, 3, 3, 0, 5 };
    crypto.aead.aes_gcm.Aes128Gcm.encrypt(&want, &want_tag, "hello", &ad, .{ 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 5 }, range(16, 0x30));
    try testing.expectEqualSlices(u8, &want, out[8..13]);
    try testing.expectEqualSlices(u8, &want_tag, out[13..]);
    var r: Cipher12 = .{ .suite = .ecdhe_ecdsa_aes_128_gcm_sha256, .seq = 5, .key = c.key, .iv = c.iv };
    var pt: [5]u8 = undefined;
    try r.open(&pt, 23, &out);
    try testing.expectEqualStrings("hello", &pt);
    // The type is authenticated: the same bytes as a handshake record fail.
    var r2: Cipher12 = .{ .suite = .ecdhe_ecdsa_aes_128_gcm_sha256, .seq = 5, .key = c.key, .iv = c.iv };
    try testing.expectError(error.BadRecordMac, r2.open(&pt, 22, &out));
    try testing.expectEqual(@as(u64, 5), r2.seq);

    // ChaCha20-Poly1305: no explicit nonce; IV XOR the sequence number.
    var cc: Cipher12 = .{ .suite = .ecdhe_rsa_chacha20_poly1305_sha256, .seq = 1 };
    @memcpy(&cc.key, &range(32, 0x40));
    cc.iv = range(12, 0x70);
    var out2: [5 + 16]u8 = undefined;
    try cc.seal(&out2, 23, "world");
    var nonce = range(12, 0x70);
    nonce[11] ^= 1;
    const ad2 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1, 23, 3, 3, 0, 5 };
    crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(&want, &want_tag, "world", &ad2, nonce, range(32, 0x40));
    try testing.expectEqualSlices(u8, &want, out2[0..5]);
    try testing.expectEqualSlices(u8, &want_tag, out2[5..]);
    // Too short to hold a tag.
    try testing.expectError(error.BadRecordMac, r.open(pt[0..0], 23, out[0..10]));
}
