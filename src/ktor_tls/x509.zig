//! Certificate checks around std.crypto.Certificate.
//!
//! std's certificate parser indexes its input as it walks the DER structure
//! and assumes the lengths it reads are consistent, so a malformed certificate
//! from a peer could make it read out of bounds. `wellFormed` walks exactly
//! the elements std's `parse` visits, with every length checked, and a
//! certificate reaches std only after it passes. Host names are matched here
//! rather than by std's `verifyHostName`, which parses the subject alternative
//! name extension unchecked and knows only DNS names; this matcher also
//! accepts IP address entries for an IP-literal host.

const std = @import("std");
const Certificate = std.crypto.Certificate;
const Bundle = Certificate.Bundle;

/// One DER element: its tag byte and the bounds of its contents.
const Tlv = struct {
    tag: u8,
    start: usize,
    end: usize,

    fn constructed(t: Tlv) bool {
        return t.tag & 0x20 != 0;
    }
};

/// The element whose header starts at `pos`, when its header and contents fit
/// before `limit`. Only definite lengths of up to four length bytes, as std's
/// parser reads them.
fn tlv(buf: []const u8, pos: usize, limit: usize) ?Tlv {
    if (limit > buf.len or pos >= limit or limit - pos < 2) return null;
    const tag = buf[pos];
    // High tag numbers (0x1f) are not used by X.509.
    if (tag & 0x1f == 0x1f) return null;
    const first = buf[pos + 1];
    var i = pos + 2;
    var len: usize = 0;
    if (first & 0x80 == 0) {
        len = first;
    } else {
        const n = first & 0x7f;
        if (n == 0 or n > 4) return null;
        if (limit - i < n) return null;
        for (buf[i..][0..n]) |b| len = (len << 8) | b;
        i += n;
    }
    if (limit - i < len) return null;
    return .{ .tag = tag, .start = i, .end = i + len };
}

const tag_integer = 0x02;
const tag_bit_string = 0x03;
const tag_octet_string = 0x04;
const tag_oid = 0x06;
const tag_sequence = 0x30;
const tag_set = 0x31;
const tag_boolean = 0x01;

const oid_ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const oid_rsa_encryption = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
const oid_subject_alt_name = [_]u8{ 0x55, 0x1d, 0x11 };

fn contentsEql(buf: []const u8, t: Tlv, want: []const u8) bool {
    return std.mem.eql(u8, buf[t.start..t.end], want);
}

/// An RSAPublicKey (SEQUENCE { INTEGER, INTEGER }) laid out as std's
/// `rsa.PublicKey.parseDer` reads it.
fn rsaKeyWellFormed(key: []const u8) bool {
    const seq = tlv(key, 0, key.len) orelse return false;
    if (seq.tag != tag_sequence) return false;
    const modulus = tlv(key, seq.start, seq.end) orelse return false;
    if (modulus.tag != tag_integer) return false;
    const exponent = tlv(key, modulus.end, seq.end) orelse return false;
    return exponent.tag == tag_integer;
}

/// Whether std's `Certificate.parse` can walk `der` without leaving it: every
/// element it visits is present and inside its parent.
pub fn wellFormed(der: []const u8) bool {
    const cert = tlv(der, 0, der.len) orelse return false;
    if (cert.tag != tag_sequence or cert.end != der.len) return false;
    const tbs = tlv(der, cert.start, cert.end) orelse return false;
    if (tbs.tag != tag_sequence) return false;

    const version_elem = tlv(der, tbs.start, tbs.end) orelse return false;
    var is_v1 = true;
    var serial = version_elem;
    if (version_elem.tag == 0xa0) {
        const v = tlv(der, version_elem.start, version_elem.end) orelse return false;
        if (v.tag != tag_integer or v.end - v.start != 1) return false;
        is_v1 = der[v.start] == 0;
        serial = tlv(der, version_elem.end, tbs.end) orelse return false;
    }
    const tbs_signature = tlv(der, serial.end, tbs.end) orelse return false;
    const issuer = tlv(der, tbs_signature.end, tbs.end) orelse return false;
    const validity = tlv(der, issuer.end, tbs.end) orelse return false;
    const not_before = tlv(der, validity.start, validity.end) orelse return false;
    _ = tlv(der, not_before.end, validity.end) orelse return false;
    const subject = tlv(der, validity.end, tbs.end) orelse return false;
    if (!namesWellFormed(der, subject)) return false;
    if (!namesWellFormed(der, issuer)) return false;

    const spki = tlv(der, subject.end, tbs.end) orelse return false;
    const spki_alg = tlv(der, spki.start, spki.end) orelse return false;
    const alg_oid = tlv(der, spki_alg.start, spki_alg.end) orelse return false;
    if (alg_oid.tag != tag_oid) return false;
    if (contentsEql(der, alg_oid, &oid_ec_public_key)) {
        const params = tlv(der, alg_oid.end, spki_alg.end) orelse return false;
        if (params.tag != tag_oid) return false;
    }
    const pub_key = tlv(der, spki_alg.end, spki.end) orelse return false;
    if (pub_key.tag != tag_bit_string or pub_key.end == pub_key.start) return false;
    if (contentsEql(der, alg_oid, &oid_rsa_encryption)) {
        if (!rsaKeyWellFormed(der[pub_key.start + 1 .. pub_key.end])) return false;
    }

    const sig_algo = tlv(der, tbs.end, cert.end) orelse return false;
    const sig_algo_oid = tlv(der, sig_algo.start, sig_algo.end) orelse return false;
    if (sig_algo_oid.tag != tag_oid) return false;
    const sig = tlv(der, sig_algo.end, cert.end) orelse return false;
    if (sig.tag != tag_bit_string or sig.end == sig.start) return false;

    // Extensions, the way std looks for them: the element after the key info,
    // taken when its tag number is 3.
    if (!is_v1 and spki.end < tbs.end) {
        const outer = tlv(der, spki.end, tbs.end) orelse return false;
        if (outer.tag & 0x1f == 3) {
            const exts = tlv(der, outer.start, outer.end) orelse return false;
            var i = exts.start;
            while (i < exts.end) {
                const ext = tlv(der, i, exts.end) orelse return false;
                i = ext.end;
                const oid = tlv(der, ext.start, ext.end) orelse return false;
                if (oid.tag != tag_oid) return false;
                var value = tlv(der, oid.end, ext.end) orelse return false;
                if (value.tag == tag_boolean) value = tlv(der, value.end, ext.end) orelse return false;
                if (value.tag != tag_octet_string) return false;
            }
        }
    }
    return true;
}

/// A Name: SEQUENCE of SET of SEQUENCE { OID, value }, walked as std walks it.
fn namesWellFormed(der: []const u8, name: Tlv) bool {
    var i = name.start;
    while (i < name.end) {
        const rdn = tlv(der, i, name.end) orelse return false;
        i = rdn.end;
        var j = rdn.start;
        while (j < rdn.end) {
            const atav = tlv(der, j, rdn.end) orelse return false;
            j = atav.end;
            var k = atav.start;
            while (k < atav.end) {
                const ty = tlv(der, k, atav.end) orelse return false;
                const val = tlv(der, ty.end, atav.end) orelse return false;
                k = val.end;
            }
        }
    }
    return true;
}

/// Parses a certificate that passed `wellFormed`.
pub fn parse(der: []const u8) ?Certificate.Parsed {
    if (!wellFormed(der)) return null;
    const cert: Certificate = .{ .buffer = der, .index = 0 };
    return cert.parse() catch null;
}

/// An IP address literal as its network-order bytes.
pub const IpAddress = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    pub fn bytes(ip: *const IpAddress) []const u8 {
        return switch (ip.*) {
            .v4 => |*b| b,
            .v6 => |*b| b,
        };
    }
};

pub fn parseIp(host: []const u8) ?IpAddress {
    const h = if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (std.Io.net.Ip4Address.parse(h, 0)) |a| return .{ .v4 = a.bytes } else |_| {}
    if (std.Io.net.Ip6Address.parse(h, 0)) |a| return .{ .v6 = a.bytes } else |_| {}
    return null;
}

/// RFC 6125 DNS name matching: case-insensitive, with a wildcard only as the
/// whole leftmost label and covering exactly one label.
fn dnsNameMatches(host: []const u8, pattern: []const u8) bool {
    if (host.len == 0 or pattern.len == 0) return false;
    const h = std.mem.trimEnd(u8, host, ".");
    const p = std.mem.trimEnd(u8, pattern, ".");
    if (std.ascii.eqlIgnoreCase(h, p)) return true;
    if (p.len < 3 or !std.mem.startsWith(u8, p, "*.")) return false;
    const suffix = p[2..];
    if (std.mem.findScalar(u8, suffix, '*') != null) return false;
    // A wildcard never covers a public suffix-like single label.
    if (std.mem.findScalar(u8, suffix, '.') == null) return false;
    const dot = std.mem.findScalar(u8, h, '.') orelse return false;
    if (dot == 0) return false;
    return std.ascii.eqlIgnoreCase(suffix, h[dot + 1 ..]);
}

/// Whether the certificate was issued for `host`: an IP literal against the
/// subject alternative name's IP entries, a DNS name against its DNS entries,
/// or against the common name when the certificate carries no alternative
/// names.
pub fn hostMatches(der: []const u8, parsed: *const Certificate.Parsed, host: []const u8) bool {
    const ip = parseIp(host);
    const san = sanValue(der) orelse {
        if (ip != null) return false;
        return dnsNameMatches(host, parsed.commonName());
    };
    const names = tlv(san, 0, san.len) orelse return false;
    if (names.tag != tag_sequence) return false;
    var i = names.start;
    while (i < names.end) {
        const name = tlv(san, i, names.end) orelse return false;
        i = name.end;
        const value = san[name.start..name.end];
        switch (name.tag) {
            0x82 => if (ip == null and dnsNameMatches(host, value)) return true,
            0x87 => if (ip) |*addr| {
                if (std.mem.eql(u8, value, addr.bytes())) return true;
            },
            else => {},
        }
    }
    return false;
}

/// The subject alternative name extension's value (the DER inside its OCTET
/// STRING), from a certificate that passed `wellFormed`.
fn sanValue(der: []const u8) ?[]const u8 {
    const cert = tlv(der, 0, der.len) orelse return null;
    const tbs = tlv(der, cert.start, cert.end) orelse return null;
    var elem = tlv(der, tbs.start, tbs.end) orelse return null;
    var i = elem.end;
    // Walk the TBS fields to the extensions: [0] version, serial, signature,
    // issuer, validity, subject, spki, then [1]/[2]/[3].
    while (i < tbs.end) {
        elem = tlv(der, i, tbs.end) orelse return null;
        i = elem.end;
        if (elem.tag != 0xa3) continue;
        const exts = tlv(der, elem.start, elem.end) orelse return null;
        var j = exts.start;
        while (j < exts.end) {
            const ext = tlv(der, j, exts.end) orelse return null;
            j = ext.end;
            const oid = tlv(der, ext.start, ext.end) orelse return null;
            if (!contentsEql(der, oid, &oid_subject_alt_name)) continue;
            var value = tlv(der, oid.end, ext.end) orelse return null;
            if (value.tag == tag_boolean) value = tlv(der, value.end, ext.end) orelse return null;
            return der[value.start..value.end];
        }
    }
    return null;
}

/// Why a chain was refused, as the alert it sends.
pub const ChainError = error{
    BadCertificate,
    UnsupportedCertificate,
    CertificateExpired,
    UnknownCa,
};

fn mapVerify(err: anyerror) ChainError {
    return switch (err) {
        error.CertificateExpired, error.CertificateNotYetValid => error.CertificateExpired,
        error.CertificateSignatureAlgorithmUnsupported,
        error.CertificateSignatureNamedCurveUnsupported,
        error.CertificateSignatureUnsupportedBitCount,
        => error.UnsupportedCertificate,
        else => error.BadCertificate,
    };
}

pub const max_chain_len = 10;

/// Checks the peer's chain (leaf first): each certificate is signed by the
/// next and valid at `now_sec`, some certificate is issued by (or is) one of
/// the anchors in `bundles`, and the leaf was issued for `host`.
pub fn verifyChain(chain: []const []const u8, bundles: []const *const Bundle, host: []const u8, now_sec: i64) ChainError!void {
    if (chain.len == 0 or chain.len > max_chain_len) return error.BadCertificate;
    var parsed: [max_chain_len]Certificate.Parsed = undefined;
    for (chain, 0..) |der, i| parsed[i] = parse(der) orelse return error.BadCertificate;
    if (!hostMatches(chain[0], &parsed[0], host)) return error.BadCertificate;
    for (0..chain.len) |i| {
        if (i > 0) parsed[i - 1].verify(parsed[i], now_sec) catch |e| return mapVerify(e);
        for (bundles) |anchors| {
            if (anchors.verify(parsed[i], now_sec)) {
                return;
            } else |e| switch (e) {
                error.CertificateIssuerNotFound => {},
                else => return mapVerify(e),
            }
        }
    }
    return error.UnknownCa;
}

/// Adds the certificates of a PEM text to `bundle`. Returns how many were
/// added; an expired or unparseable certificate is skipped as std's own
/// loaders skip them.
pub fn addPem(bundle: *Bundle, gpa: std.mem.Allocator, pem_text: []const u8, now_sec: i64) !usize {
    const pem = @import("pem.zig");
    var it = pem.Iterator.init(pem_text, "CERTIFICATE");
    var added: usize = 0;
    while (try it.next(gpa)) |der| {
        defer gpa.free(der);
        if (!wellFormed(der)) return error.InvalidCertificate;
        const start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.appendSlice(gpa, der);
        const before = bundle.map.count();
        bundle.parseCert(gpa, start, now_sec) catch return error.InvalidCertificate;
        if (bundle.map.count() > before) added += 1;
    }
    return added;
}

const testing = std.testing;

test "tlv refuses lengths that leave the buffer" {
    try testing.expect(tlv(&.{ 0x30, 0x03, 0x02, 0x01, 0x05 }, 0, 5) != null);
    try testing.expect(tlv(&.{ 0x30, 0x04, 0x02, 0x01, 0x05 }, 0, 5) == null);
    try testing.expect(tlv(&.{ 0x30, 0x81 }, 0, 2) == null);
    try testing.expect(tlv(&.{ 0x30, 0x85, 0, 0, 0, 0, 1 }, 0, 7) == null);
    try testing.expect(tlv(&.{ 0x30, 0x80 }, 0, 2) == null);
    try testing.expect(tlv(&.{0x30}, 0, 1) == null);
}

test "dns names match exactly or by one leftmost wildcard label" {
    try testing.expect(dnsNameMatches("localhost", "localhost"));
    try testing.expect(dnsNameMatches("API.example.com", "api.example.COM"));
    try testing.expect(dnsNameMatches("a.example.com", "*.example.com"));
    try testing.expect(!dnsNameMatches("a.b.example.com", "*.example.com"));
    try testing.expect(!dnsNameMatches("example.com", "*.example.com"));
    try testing.expect(!dnsNameMatches("host.com", "*.com"));
    try testing.expect(!dnsNameMatches("a.example.com", "a*.example.com"));
    try testing.expect(!dnsNameMatches("", "localhost"));
}

test "ip literals parse in both families" {
    const v4 = parseIp("127.0.0.1").?;
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, v4.bytes());
    const v6 = parseIp("[::1]").?;
    try testing.expectEqual(@as(u8, 1), v6.bytes()[15]);
    try testing.expect(parseIp("localhost") == null);
}
