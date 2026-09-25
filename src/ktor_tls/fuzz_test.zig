//! Fuzz-style tests: random, truncated and corrupted input to both sides of
//! the session, and to the certificate and key parsers. Every run is
//! deterministic (seeded) and must end with the input refused or waiting for
//! more, never a crash. `KTOR_TLS_FUZZ_ITERATIONS` scales the counts.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("tls_fixtures");
const session = @import("session.zig");
const x509 = @import("x509.zig");
const pem = @import("pem.zig");
const tests = @import("tests.zig");

const Session = session.Session;
const a = testing.allocator;

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

/// After a refusal the session must say why, and stay refused.
fn checkConsistent(s: *Session) !void {
    if (s.failed()) {
        try testing.expect(s.failure() != null);
        try testing.expectError(error.TlsFailure, s.feed(&.{ 23, 3, 3, 0, 0 }));
    }
}

test "random records against a fresh server and a fresh client" {
    var env = try tests.Env.init(a);
    defer env.deinit();
    const ccfg = env.trust("localhost");
    const scfg: session.ServerConfig = .{ .identity = &env.p256.identity };
    var prng = std.Random.DefaultPrng.init(0x7c1f);
    const r = prng.random();
    var buf: [2048]u8 = undefined;
    for (0..iterations(3000)) |i| {
        const len = r.uintLessThan(usize, buf.len);
        r.bytes(buf[0..len]);
        if (len >= 5 and r.boolean()) {
            // A plausible header over random content.
            buf[0] = 20 + r.uintLessThan(u8, 4);
            buf[1] = 3;
            buf[2] = 3;
            std.mem.writeInt(u16, buf[3..5], @intCast(len - 5), .big);
            if (buf[0] == 22 and len >= 9 and r.boolean()) {
                buf[5] = r.uintLessThan(u8, 25);
                std.mem.writeInt(u24, buf[6..9], @intCast(len - 9), .big);
            }
        }
        var s = Session.initServer(a, &scfg, tests.seed(@truncate(i)));
        defer s.deinit();
        try feedIgnoringFailure(&s, buf[0..len]);
        try checkConsistent(&s);
        var c = try Session.initClient(a, &ccfg, tests.seed(@truncate(i)));
        defer c.deinit();
        try feedIgnoringFailure(&c, buf[0..len]);
        try checkConsistent(&c);
    }
}

const Mutation = enum { flip, truncate, insert, drop, duplicate, split };

/// A handshake and data exchange in which delivery number `target` is
/// corrupted. It must complete, fail on one side or both, or stall; the
/// seeds make the unmutated deliveries identical from run to run.
fn mutatedRun(env: *const tests.Env, target: usize, m: Mutation, r: std.Random) !void {
    const ccfg = env.trust("localhost");
    const scfg: session.ServerConfig = .{ .identity = &env.ed25519.identity };
    var c = try Session.initClient(a, &ccfg, tests.seed(1));
    defer c.deinit();
    var s = Session.initServer(a, &scfg, tests.seed(2));
    defer s.deinit();
    var delivery: usize = 0;
    var rounds: usize = 0;
    var wrote = false;
    while (rounds < 64) : (rounds += 1) {
        if (!wrote and c.handshakeDone() and !c.failed()) {
            try c.writeApp("application data after the handshake");
            wrote = true;
        }
        var moved = false;
        inline for (.{ .{ &c, &s }, .{ &s, &c } }) |pair| {
            const from = pair[0];
            const to = pair[1];
            if (from.output().len > 0) {
                const bytes = try a.dupe(u8, from.output());
                defer a.free(bytes);
                from.consumeOutput(bytes.len);
                moved = true;
                if (delivery == target) {
                    switch (m) {
                        .flip => {
                            const at = r.uintLessThan(usize, bytes.len);
                            bytes[at] ^= @as(u8, 1) << r.int(u3);
                            try feedIgnoringFailure(to, bytes);
                        },
                        .truncate => try feedIgnoringFailure(to, bytes[0..r.uintLessThan(usize, bytes.len)]),
                        .insert => {
                            var junk: [40]u8 = undefined;
                            r.bytes(&junk);
                            const at = r.uintLessThan(usize, bytes.len);
                            try feedIgnoringFailure(to, bytes[0..at]);
                            try feedIgnoringFailure(to, junk[0 .. 1 + r.uintLessThan(usize, junk.len - 1)]);
                            try feedIgnoringFailure(to, bytes[at..]);
                        },
                        .drop => {},
                        .duplicate => {
                            try feedIgnoringFailure(to, bytes);
                            try feedIgnoringFailure(to, bytes);
                        },
                        .split => {
                            const at = r.uintLessThan(usize, bytes.len);
                            try feedIgnoringFailure(to, bytes[0..at]);
                            try feedIgnoringFailure(to, bytes[at..]);
                        },
                    }
                } else {
                    try feedIgnoringFailure(to, bytes);
                }
                delivery += 1;
            }
        }
        if (!moved) break;
    }
    try checkConsistent(&c);
    try checkConsistent(&s);
    // A split delivery is not a corruption: it must still work.
    if (m == .split) {
        try testing.expect(c.handshakeDone() and s.handshakeDone());
    }
}

test "a handshake with one corrupted delivery refuses cleanly" {
    var env = try tests.Env.init(a);
    defer env.deinit();
    var prng = std.Random.DefaultPrng.init(0x51);
    const r = prng.random();
    const n = iterations(300);
    for (0..n) |i| {
        const m = std.enums.values(Mutation)[i % std.enums.values(Mutation).len];
        try mutatedRun(&env, r.uintLessThan(usize, 5), m, r);
    }
}

test "certificate parsing survives every truncation and random corruption" {
    const certs = try pem.certificates(a, fixtures.server_p256 ++ fixtures.ca ++ fixtures.server_ed25519);
    defer {
        for (certs) |c| a.free(c);
        a.free(certs);
    }
    var anchors: std.crypto.Certificate.Bundle = .empty;
    defer anchors.deinit(a);
    _ = try x509.addPem(&anchors, a, fixtures.ca, tests.now_sec);
    for (certs) |der| {
        try testing.expect(x509.wellFormed(der));
        for (0..der.len) |n| {
            try testing.expect(!x509.wellFormed(der[0..n]));
            try testing.expect(x509.parse(der[0..n]) == null);
        }
    }
    var prng = std.Random.DefaultPrng.init(0xce27);
    const r = prng.random();
    const copy = try a.alloc(u8, 4096);
    defer a.free(copy);
    for (0..iterations(3000)) |i| {
        const der = certs[i % certs.len];
        const buf = copy[0..der.len];
        @memcpy(buf, der);
        for (0..1 + r.uintLessThan(usize, 4)) |_| {
            buf[r.uintLessThan(usize, buf.len)] = r.int(u8);
        }
        if (x509.parse(buf)) |parsed| {
            _ = x509.hostMatches(buf, &parsed, "localhost");
            _ = x509.hostMatches(buf, &parsed, "127.0.0.1");
        }
        const chain = [_][]const u8{buf};
        x509.verifyChain(&chain, &.{&anchors}, "localhost", tests.now_sec) catch {};
    }
}

test "private key and PEM parsing survives corruption" {
    var prng = std.Random.DefaultPrng.init(0x9e3);
    const r = prng.random();
    const sources = [_][]const u8{ fixtures.server_p256_key, fixtures.server_ed25519_key, fixtures.untrusted_key, fixtures.server_p256 };
    const buf = try a.alloc(u8, 4096);
    defer a.free(buf);
    for (0..iterations(3000)) |i| {
        const src = sources[i % sources.len];
        const text = buf[0..src.len];
        @memcpy(text, src);
        for (0..1 + r.uintLessThan(usize, 3)) |_| {
            const at = r.uintLessThan(usize, text.len);
            // Keep the corruption inside the base64 alphabet most of the
            // time so it reaches the DER parsers.
            const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            text[at] = if (r.uintLessThan(u8, 4) != 0) alphabet[r.uintLessThan(usize, alphabet.len)] else r.int(u8);
        }
        if (pem.privateKey(a, text)) |_| {} else |_| {}
        if (pem.certificates(a, text)) |list| {
            for (list) |c| a.free(c);
            a.free(list);
        } else |_| {}
    }
}
