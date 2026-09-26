//! Host natives behind klio's ktor pack: the socket layer ktor-network's
//! actuals call (`net.zig`), `io.ktor.util`'s message digests and clock, and
//! the ktor-io lock actuals.

const std = @import("std");

const runtime = @import("runtime");
const stdlib = @import("stdlib");

const CallCtx = runtime.CallCtx;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const Output = runtime.Output;
const HostBindings = stdlib.HostBindings;

const Allocator = std.mem.Allocator;

pub const net = @import("net.zig");
pub const tls = @import("tls.zig");
pub const zlib = @import("zlib.zig");
const env = @import("env.zig");

pub fn hostBindings(allocator: Allocator) Allocator.Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("io.ktor.util.date.getTimeMillis", get_time_millis);
    try b.register("io.ktor.util.__kktor_digest", digest);
    try b.register("io.ktor.util.__kktor_getenv", getenv);
    try b.register("io.ktor.util.__kktor_setenv", setenvNative);
    try b.register("io.ktor.util.__kktor_unsetenv", unsetenvNative);
    try b.register("io.ktor.util.__kktor_environ", environNative);
    try b.register("io.ktor.util.__kktor_available_processors", availableProcessors);
    try b.register("io.ktor.util.__kktor_print_error", printError);
    // These lock classes take the same per-object reentrant monitor as
    // `kotlin.synchronized`: a `ByteChannel` can be written from a worker while
    // another coroutine reads, so the actual must exclude across threads.
    try b.register("io.ktor.utils.io.locks.ReentrantLock.lock", stdlib.implementations.concurrent_lock_enter);
    try b.register("io.ktor.utils.io.locks.ReentrantLock.tryLock", stdlib.implementations.concurrent_lock_try_enter);
    try b.register("io.ktor.utils.io.locks.ReentrantLock.unlock", stdlib.implementations.concurrent_lock_exit);
    try b.register("io.ktor.utils.io.locks.synchronized", stdlib.implementations.concurrent_synchronized);
    try net.register(&b);
    try tls.register(&b);
    try zlib.register(&b);
    return b;
}

fn get_time_millis(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Long = runtime.clockWallMillis() } };
}

/// The process environment is one table per process; these calls take turns.
var env_lock: runtime.SpinMutex = .{};

/// `io.ktor.util.__kktor_getenv(name)`: the process environment variable, or
/// null when unset: the posix `getenv` ktor's native logger and server
/// environment read.
fn getenv(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const name = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    defer a.free(name);
    // Copied out under the lock and turned into a String after it, so no
    // interpreter allocation runs while another thread may spin on it.
    const ca = std.heap.c_allocator;
    const copy = blk: {
        env_lock.lock();
        defer env_lock.unlock();
        break :blk try env.get(ca, name) orelse return .{ .ok = .Null };
    };
    defer ca.free(copy);
    return .{ .ok = .{ .String = try runtime.strInit(a, copy) } };
}

/// `io.ktor.util.__kktor_setenv(name, value)`: posix `setenv` without
/// overwriting, as ktor's native `setEnvironmentProperty` calls it.
fn setenvNative(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const name = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    defer a.free(name);
    const value = switch (try arg_string(a, ctx, 1)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    defer a.free(value);
    env_lock.lock();
    defer env_lock.unlock();
    try env.setIfAbsent(std.heap.c_allocator, name, value);
    return .{ .ok = .Unit };
}

/// `io.ktor.util.__kktor_unsetenv(name)`: posix `unsetenv`.
fn unsetenvNative(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const name = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    defer a.free(name);
    env_lock.lock();
    defer env_lock.unlock();
    try env.unset(std.heap.c_allocator, name);
    return .{ .ok = .Unit };
}

/// `io.ktor.util.__kktor_environ()`: every `NAME=value` entry of the process
/// environment, in `environ` order.
fn environNative(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const ca = std.heap.c_allocator;
    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| ca.free(e);
        entries.deinit(ca);
    }
    {
        env_lock.lock();
        defer env_lock.unlock();
        try env.entries(ca, &entries);
    }
    var items: std.ArrayList(Value) = .empty;
    for (entries.items) |e| try items.append(a, .{ .String = try runtime.strInit(a, e) });
    return .{ .ok = runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, items)) };
}

fn availableProcessors(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    const n = std.Thread.getCpuCount() catch 1;
    return .{ .ok = Value.newInt(@intCast(@max(n, 1))) };
}

/// `io.ktor.util.__kktor_print_error(message)`: the message on stderr, with no
/// newline added, as the native server's `fprintf(stderr, "%s", ...)`.
fn printError(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const msg = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    defer a.free(msg);
    env.writeStderr(msg);
    return .{ .ok = .Unit };
}

/// The JVM's `MessageDigest` algorithms, those of its SUN provider.
const DigestAlg = enum { md2, md5, sha1, sha224, sha256, sha384, sha512, sha512_224, sha512_256, sha3_224, sha3_256, sha3_384, sha3_512 };

/// Each name `MessageDigest.getInstance` accepts, compared ignoring case: the
/// algorithm's standard name, its aliases, and its OID, which may also be
/// written with an `OID.` prefix.
const digest_names = [_]struct { name: []const u8, alg: DigestAlg, oid: bool = false }{
    .{ .name = "MD2", .alg = .md2 },
    .{ .name = "1.2.840.113549.2.2", .alg = .md2, .oid = true },
    .{ .name = "MD5", .alg = .md5 },
    .{ .name = "1.2.840.113549.2.5", .alg = .md5, .oid = true },
    .{ .name = "SHA-1", .alg = .sha1 },
    .{ .name = "SHA", .alg = .sha1 },
    .{ .name = "SHA1", .alg = .sha1 },
    .{ .name = "1.3.14.3.2.26", .alg = .sha1, .oid = true },
    .{ .name = "SHA-224", .alg = .sha224 },
    .{ .name = "SHA224", .alg = .sha224 },
    .{ .name = "2.16.840.1.101.3.4.2.4", .alg = .sha224, .oid = true },
    .{ .name = "SHA-256", .alg = .sha256 },
    .{ .name = "SHA256", .alg = .sha256 },
    .{ .name = "2.16.840.1.101.3.4.2.1", .alg = .sha256, .oid = true },
    .{ .name = "SHA-384", .alg = .sha384 },
    .{ .name = "SHA384", .alg = .sha384 },
    .{ .name = "2.16.840.1.101.3.4.2.2", .alg = .sha384, .oid = true },
    .{ .name = "SHA-512", .alg = .sha512 },
    .{ .name = "SHA512", .alg = .sha512 },
    .{ .name = "2.16.840.1.101.3.4.2.3", .alg = .sha512, .oid = true },
    .{ .name = "SHA-512/224", .alg = .sha512_224 },
    .{ .name = "SHA512/224", .alg = .sha512_224 },
    .{ .name = "2.16.840.1.101.3.4.2.5", .alg = .sha512_224, .oid = true },
    .{ .name = "SHA-512/256", .alg = .sha512_256 },
    .{ .name = "SHA512/256", .alg = .sha512_256 },
    .{ .name = "2.16.840.1.101.3.4.2.6", .alg = .sha512_256, .oid = true },
    .{ .name = "SHA3-224", .alg = .sha3_224 },
    .{ .name = "2.16.840.1.101.3.4.2.7", .alg = .sha3_224, .oid = true },
    .{ .name = "SHA3-256", .alg = .sha3_256 },
    .{ .name = "2.16.840.1.101.3.4.2.8", .alg = .sha3_256, .oid = true },
    .{ .name = "SHA3-384", .alg = .sha3_384 },
    .{ .name = "2.16.840.1.101.3.4.2.9", .alg = .sha3_384, .oid = true },
    .{ .name = "SHA3-512", .alg = .sha3_512 },
    .{ .name = "2.16.840.1.101.3.4.2.10", .alg = .sha3_512, .oid = true },
};

fn digestAlg(name: []const u8) ?DigestAlg {
    const oid = asciiStripPrefixIgnoreCase(name, "OID.");
    for (digest_names) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, name)) return e.alg;
        if (e.oid) if (oid) |o| if (std.mem.eql(u8, e.name, o)) return e.alg;
    }
    return null;
}

fn hashWith(comptime H: type, input: []const u8, out: *[64]u8) []const u8 {
    H.hash(input, out[0..H.digest_length], .{});
    return out[0..H.digest_length];
}

/// The digest of `input` under `alg`, written into `out`.
fn digestInto(alg: DigestAlg, input: []const u8, out: *[64]u8) []const u8 {
    const h = std.crypto.hash;
    return switch (alg) {
        .md2 => blk: {
            md2(input, out[0..16]);
            break :blk out[0..16];
        },
        .md5 => hashWith(h.Md5, input, out),
        .sha1 => hashWith(h.Sha1, input, out),
        .sha224 => hashWith(h.sha2.Sha224, input, out),
        .sha256 => hashWith(h.sha2.Sha256, input, out),
        .sha384 => hashWith(h.sha2.Sha384, input, out),
        .sha512 => hashWith(h.sha2.Sha512, input, out),
        .sha512_224 => hashWith(h.sha2.Sha512_224, input, out),
        .sha512_256 => hashWith(h.sha2.Sha512_256, input, out),
        .sha3_224 => hashWith(h.sha3.Sha3_224, input, out),
        .sha3_256 => hashWith(h.sha3.Sha3_256, input, out),
        .sha3_384 => hashWith(h.sha3.Sha3_384, input, out),
        .sha3_512 => hashWith(h.sha3.Sha3_512, input, out),
    };
}

/// MD2's substitution of the bytes, from the digits of pi (RFC 1319).
const md2_s = [256]u8{
    41,  46,  67,  201, 162, 216, 124, 1,   61,  54,  84,  161, 236, 240, 6,   19,
    98,  167, 5,   243, 192, 199, 115, 140, 152, 147, 43,  217, 188, 76,  130, 202,
    30,  155, 87,  60,  253, 212, 224, 22,  103, 66,  111, 24,  138, 23,  229, 18,
    190, 78,  196, 214, 218, 158, 222, 73,  160, 251, 245, 142, 187, 47,  238, 122,
    169, 104, 121, 145, 21,  178, 7,   63,  148, 194, 16,  137, 11,  34,  95,  33,
    128, 127, 93,  154, 90,  144, 50,  39,  53,  62,  204, 231, 191, 247, 151, 3,
    255, 25,  48,  179, 72,  165, 181, 209, 215, 94,  146, 42,  172, 86,  170, 198,
    79,  184, 56,  210, 150, 164, 125, 182, 118, 252, 107, 226, 156, 116, 4,   241,
    69,  157, 112, 89,  100, 113, 135, 32,  134, 91,  207, 101, 230, 45,  168, 2,
    27,  96,  37,  173, 174, 176, 185, 246, 28,  70,  97,  105, 52,  64,  126, 15,
    85,  71,  163, 35,  221, 81,  175, 58,  195, 92,  249, 206, 186, 197, 234, 38,
    44,  83,  13,  110, 133, 40,  132, 9,   211, 223, 205, 244, 65,  129, 77,  82,
    106, 220, 55,  200, 108, 193, 171, 250, 36,  225, 123, 8,   12,  189, 177, 74,
    120, 136, 149, 139, 227, 99,  232, 109, 233, 203, 213, 254, 59,  0,   29,  57,
    242, 239, 183, 14,  102, 88,  208, 228, 166, 119, 114, 248, 235, 117, 75,  10,
    49,  68,  80,  180, 143, 237, 31,  26,  219, 153, 141, 51,  159, 17,  131, 20,
};

const Md2State = struct {
    x: [48]u8 = @splat(0),
    checksum: [16]u8 = @splat(0),
    last: u8 = 0,

    fn block(st: *Md2State, m: *const [16]u8, sum: bool) void {
        if (sum) for (m, 0..) |b, j| {
            st.checksum[j] ^= md2_s[b ^ st.last];
            st.last = st.checksum[j];
        };
        for (m, 0..) |b, j| {
            st.x[16 + j] = b;
            st.x[32 + j] = b ^ st.x[j];
        }
        var t: u8 = 0;
        for (0..18) |round| {
            for (&st.x) |*v| {
                v.* ^= md2_s[t];
                t = v.*;
            }
            t +%= @intCast(round);
        }
    }
};

/// MD2 (RFC 1319): the message padded to 16-byte blocks, then its checksum.
fn md2(input: []const u8, out: *[16]u8) void {
    var st: Md2State = .{};
    var i: usize = 0;
    while (i + 16 <= input.len) : (i += 16) st.block(input[i..][0..16], true);
    var last: [16]u8 = undefined;
    const rest = input.len - i;
    const pad: u8 = @intCast(16 - rest);
    @memcpy(last[0..rest], input[i..]);
    @memset(last[rest..], pad);
    st.block(&last, true);
    const sum = st.checksum;
    st.block(&sum, false);
    out.* = st.x[0..16].*;
}

/// `io.ktor.util.__kktor_digest(name, bytes, length)`: the digest of
/// `bytes[0, length)` under the JVM `MessageDigest` algorithm `name`, or null
/// for a name the JVM does not provide.
fn digest(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const name = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    defer a.free(name);
    const alg = digestAlg(name) orelse return .{ .ok = .Null };
    if (ctx.args.len < 3 or ctx.args[1] != .Array) return .{ .err = .{ .Type = "__kktor_digest: bytes must be a ByteArray" } };
    const arr = ctx.args[1].Array;
    const want = ctx.args[2].asI64() orelse return .{ .err = .{ .Type = "__kktor_digest: length must be an Int" } };
    const n: usize = @intCast(std.math.clamp(want, 0, @as(i64, @intCast(arr.len()))));
    const input = try a.alloc(u8, n);
    defer a.free(input);
    for (input, 0..) |*b, i| b.* = switch (arr.get(i)) {
        .Byte => |x| @bitCast(x),
        else => 0,
    };
    var buf: [64]u8 = undefined;
    const d = digestInto(alg, input, &buf);
    var vals: [64]Value = undefined;
    for (d, 0..) |b, i| vals[i] = .{ .Byte = @bitCast(b) };
    return .{ .ok = try runtime.ArrayData.initPacked(a, .Byte, vals[0..d.len]) };
}

fn ArgResult(comptime T: type) type {
    return union(enum) { ok: T, err: RuntimeError };
}

fn arg_string(allocator: Allocator, ctx: *const CallCtx, idx: usize) Allocator.Error!ArgResult([]const u8) {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                return .{ .ok = try allocator.dupe(u8, g.get().bytes) };
            },
            else => {},
        }
    }
    const msg = try std.fmt.allocPrint(allocator, "ktor-client: argument {d} must be a String", .{idx});
    return .{ .err = .{ .Type = msg } };
}

fn asciiStripPrefixIgnoreCase(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (s.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix)) return null;
    return s[prefix.len..];
}

const testing = std.testing;

test {
    _ = net;
    _ = tls;
    _ = zlib;
    _ = env;
    _ = @import("sync.zig");
    _ = @import("zdeflate.zig");
}

fn makeCtx(allocator: Allocator, host: runtime.IntrinsicHost, out: Output, args: []const Value) CallCtx {
    return .{ .args = args, .out = out, .host = host, .allocator = allocator };
}

test "host bindings register the pack's natives" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("io.ktor.network.util.__kknet_socket") != null);
    try testing.expect(b.resolve("io.ktor.network.util.__kknet_poll") != null);
    try testing.expect(b.resolve("io.ktor.utils.io.errors.__kkio_errno_value") != null);
    try testing.expect(b.resolve("io.ktor.client.engine.__kktor_request") == null);
    try testing.expect(b.resolve("io.ktor.server.engine.__kktor_serve") == null);
    try testing.expect(b.resolve("io.ktor.util.date.getTimeMillis") != null);
    try testing.expect(b.resolve("io.ktor.util.__kktor_digest") != null);
    try testing.expect(b.resolve("io.ktor.utils.io.locks.ReentrantLock.lock") != null);
    try testing.expect(b.resolve("io.ktor.utils.io.locks.ReentrantLock.tryLock") != null);
    try testing.expect(b.resolve("io.ktor.utils.io.locks.ReentrantLock.unlock") != null);
    try testing.expect(b.resolve("io.ktor.client.engine.__nope") == null);
}

test "getenv reads a set variable and is null for an unset one" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    // PATH is set in every environment the tests run in.
    const set = Value{ .String = try runtime.strInit(testing.allocator, "PATH") };
    defer set.release(testing.allocator);
    var ctx = makeCtx(testing.allocator, h.host(), cap.output(), &.{set});
    const r = try getenv(&ctx);
    try testing.expect(r == .ok and r.ok == .String);
    r.ok.release(testing.allocator);
    const unset = Value{ .String = try runtime.strInit(testing.allocator, "KLIO_KTOR_SURELY_UNSET_VARIABLE") };
    defer unset.release(testing.allocator);
    var ctx2 = makeCtx(testing.allocator, h.host(), cap.output(), &.{unset});
    const r2 = try getenv(&ctx2);
    try testing.expect(r2 == .ok and r2.ok == .Null);
}

test "get_time_millis returns a positive Long" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(testing.allocator, h.host(), cap.output(), &.{});
    const r = try get_time_millis(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Long);
    try testing.expect(r.ok.Long > 0);
}

fn hexOf(buf: []u8, d: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (d, 0..) |b, i| {
        buf[2 * i] = digits[b >> 4];
        buf[2 * i + 1] = digits[b & 15];
    }
    return buf[0 .. 2 * d.len];
}

test "digestAlg takes the JVM's names, aliases and OIDs, ignoring case" {
    try testing.expectEqual(DigestAlg.sha256, digestAlg("SHA-256").?);
    try testing.expectEqual(DigestAlg.sha256, digestAlg("sha256").?);
    try testing.expectEqual(DigestAlg.sha1, digestAlg("SHA").?);
    try testing.expectEqual(DigestAlg.sha1, digestAlg("oid.1.3.14.3.2.26").?);
    try testing.expectEqual(DigestAlg.sha256, digestAlg("OID.2.16.840.1.101.3.4.2.1").?);
    try testing.expectEqual(DigestAlg.sha512_224, digestAlg("SHA512/224").?);
    try testing.expectEqual(DigestAlg.sha3_512, digestAlg("2.16.840.1.101.3.4.2.10").?);
    try testing.expectEqual(DigestAlg.md2, digestAlg("md2").?);
    try testing.expect(digestAlg("OID.SHA-256") == null);
    try testing.expect(digestAlg(" SHA-256") == null);
    try testing.expect(digestAlg("SHA_256") == null);
    try testing.expect(digestAlg("SHA-2") == null);
    try testing.expect(digestAlg("") == null);
}

test "digestInto matches the JVM's MessageDigest for every algorithm" {
    // Each expected value is the JVM's (OpenJDK 21) digest of "abc".
    const cases = [_]struct { DigestAlg, []const u8 }{
        .{ .md2, "da853b0d3f88d99b30283a69e6ded6bb" },
        .{ .md5, "900150983cd24fb0d6963f7d28e17f72" },
        .{ .sha1, "a9993e364706816aba3e25717850c26c9cd0d89d" },
        .{ .sha224, "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7" },
        .{ .sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
        .{ .sha384, "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7" },
        .{ .sha512, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f" },
        .{ .sha512_224, "4634270f707b6a54daae7530460842e20e37ed265ceee9a43e8924aa" },
        .{ .sha512_256, "53048e2681941ef99b2e29b76b4c7dabe4c2d0c634fc6d46e0e2f13107e7af23" },
        .{ .sha3_224, "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf" },
        .{ .sha3_256, "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532" },
        .{ .sha3_384, "ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25" },
        .{ .sha3_512, "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0" },
    };
    var buf: [64]u8 = undefined;
    var hex: [128]u8 = undefined;
    for (cases) |cs| try testing.expectEqualStrings(cs[1], hexOf(&hex, digestInto(cs[0], "abc", &buf)));
}

test "md2 pads to a whole block and folds in the checksum" {
    var out: [16]u8 = undefined;
    var hex: [32]u8 = undefined;
    // RFC 1319's test suite.
    md2("", &out);
    try testing.expectEqualStrings("8350e5a3e24c153df2275c9f80692773", hexOf(&hex, &out));
    md2("message digest", &out);
    try testing.expectEqualStrings("ab4f496bfb2a530b219ff33031fe06b0", hexOf(&hex, &out));
    md2("abcdefghijklmnopqrstuvwxyz", &out);
    try testing.expectEqualStrings("4e8ddff3650292ab5a4108c3aa47940b", hexOf(&hex, &out));
    md2("12345678901234567890123456789012345678901234567890123456789012345678901234567890", &out);
    try testing.expectEqualStrings("d5976f79d83d3a0dc9806c3c66f3efd8", hexOf(&hex, &out));
}

test "digest hashes the array's first length bytes, and is null for an unknown name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);
    const name = Value{ .String = try runtime.strInit(a, "sha-256") };
    const bytes = try runtime.ArrayData.initPacked(a, .Byte, &.{ .{ .Byte = 'a' }, .{ .Byte = 'b' }, .{ .Byte = 'c' }, .{ .Byte = 'x' } });
    var ctx = makeCtx(a, h.host(), cap.output(), &.{ name, bytes, .{ .Int = 3 } });
    const r = try digest(&ctx);
    try testing.expect(r == .ok and r.ok == .Array);
    const out = try r.ok.Array.snapshot(a);
    try testing.expectEqual(@as(usize, 32), out.len);
    var raw: [32]u8 = undefined;
    for (out, 0..) |v, i| raw[i] = @bitCast(v.Byte);
    var hex: [64]u8 = undefined;
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hexOf(&hex, &raw));

    const unknown = Value{ .String = try runtime.strInit(a, "FOO") };
    var ctx2 = makeCtx(a, h.host(), cap.output(), &.{ unknown, bytes, .{ .Int = 0 } });
    const r2 = try digest(&ctx2);
    try testing.expect(r2 == .ok and r2.ok == .Null);
}

test "arg_string reads a String and rejects others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);
    const s = Value{ .String = try runtime.strInit(a, "hello") };
    var ctx = makeCtx(a, h.host(), cap.output(), &.{s});
    switch (try arg_string(a, &ctx, 0)) {
        .ok => |v| try testing.expectEqualStrings("hello", v),
        .err => return error.TestUnexpectedResult,
    }
    switch (try arg_string(a, &ctx, 1)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            try testing.expect(e == .Type);
            try testing.expectEqualStrings("ktor-client: argument 1 must be a String", e.Type);
        },
    }
}

test "asciiStripPrefixIgnoreCase honors case insensitivity" {
    try testing.expectEqualStrings(" 42", asciiStripPrefixIgnoreCase("Content-Length: 42", "content-length:").?);
    try testing.expect(asciiStripPrefixIgnoreCase("Other: 1", "content-length:") == null);
}

test {
    std.testing.refAllDecls(@This());
}
