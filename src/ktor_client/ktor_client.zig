//! Native HTTP engine for klio's ktor-client pack.
//!
//! The Kotlin shim declares the client surface; the engine helpers bind here
//! against a blocking HTTP/1.1 transport over the platform sockets, so each
//! request blocks the calling thread. A request returns a flat `Array<String>`
//! shaped `[statusCode, body, contentType, headerKey, headerVal, ...]`, so the
//! shim rebuilds a `HttpResponse` without constructing Kotlin instances here.

const std = @import("std");

const runtime = @import("runtime");
const stdlib = @import("stdlib");

const CallCtx = runtime.CallCtx;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const Output = runtime.Output;
const HostBindings = stdlib.HostBindings;

const Allocator = std.mem.Allocator;
const c = std.c;
const posix = std.posix;

pub fn hostBindings(allocator: Allocator) Allocator.Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("io.ktor.client.engine.__kktor_request", request);
    try b.register("io.ktor.client.engine.__kktor_get", get);
    try b.register("io.ktor.client.engine.__kktor_post", post);
    try b.register("io.ktor.client.engine.__kktor_setHeader", set_header);
    try b.register("io.ktor.server.engine.__kktor_serve", serve);
    try b.register("io.ktor.util.date.getTimeMillis", get_time_millis);
    try b.register("io.ktor.util.__kktor_digest", digest);
    // These lock classes take the same per-object reentrant monitor as
    // `kotlin.synchronized`: a `ByteChannel` can be written from a worker while
    // another coroutine reads, so the actual must exclude across threads.
    try b.register("io.ktor.utils.io.locks.ReentrantLock.lock", stdlib.implementations.concurrent_lock_enter);
    try b.register("io.ktor.utils.io.locks.ReentrantLock.tryLock", stdlib.implementations.concurrent_lock_try_enter);
    try b.register("io.ktor.utils.io.locks.ReentrantLock.unlock", stdlib.implementations.concurrent_lock_exit);
    try b.register("io.ktor.utils.io.locks.synchronized", stdlib.implementations.concurrent_synchronized);
    return b;
}

fn get_time_millis(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Long = runtime.clockWallMillis() } };
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

fn arg_string_array(allocator: Allocator, ctx: *const CallCtx, idx: usize) Allocator.Error!ArgResult([][]const u8) {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .Array => |a| {
                const items = try a.snapshot(allocator);
                defer if (runtime.freeScratch()) allocator.free(items);
                var out = try allocator.alloc([]const u8, items.len);
                for (items, 0..) |v, i| {
                    switch (v) {
                        .String => |s| {
                            const sg = s.borrow();
                            defer sg.deinit();
                            out[i] = try allocator.dupe(u8, sg.get().bytes);
                        },
                        else => out[i] = try allocator.dupe(u8, ""),
                    }
                }
                return .{ .ok = out };
            },
            else => {},
        }
    }
    const msg = try std.fmt.allocPrint(allocator, "ktor-client: argument {d} must be Array<String>", .{idx});
    return .{ .err = .{ .Type = msg } };
}

fn make_string_array(allocator: Allocator, values: [][]const u8) Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacityPrecise(allocator, values.len);
    for (values) |s| {
        list.appendAssumeCapacity(.{ .String = try runtime.strInit(allocator, s) });
    }
    const items = try ValueList.init(allocator, list);
    return runtime.ArrayData.fromBoxedList(items);
}

/// Free an owned slice of owned strings produced by `perform`: under a freeing
/// allocator `makeStringArray` copied the bytes into fresh cells, so the
/// originals are independent. The arena fast path reclaims them wholesale.
fn freeOwnedStrings(allocator: Allocator, values: [][]const u8) void {
    if (!runtime.freeScratch()) return;
    for (values) |s| allocator.free(s);
    allocator.free(values);
}

const HeaderPair = struct { key: []const u8, value: []const u8 };

fn perform(
    allocator: Allocator,
    method: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) Allocator.Error![][]const u8 {
    // The reserved `__klio_cfg_*` header keys carry per-request config and are
    // stripped; the rest are forwarded verbatim.
    var timeout_ms: u64 = 60_000;
    var tls_insecure: bool = false;
    var connect_timeout_ms: ?u64 = null;
    var user_headers: std.ArrayList([]const u8) = .empty;
    defer user_headers.deinit(allocator);
    {
        var i: usize = 0;
        while (i + 1 < headers.len) : (i += 2) {
            const k = headers[i];
            const v = headers[i + 1];
            if (std.mem.eql(u8, k, "__klio_cfg_timeout_ms")) {
                timeout_ms = std.fmt.parseInt(u64, v, 10) catch timeout_ms;
            } else if (std.mem.eql(u8, k, "__klio_cfg_connect_timeout_ms")) {
                connect_timeout_ms = std.fmt.parseInt(u64, v, 10) catch null;
            } else if (std.mem.eql(u8, k, "__klio_cfg_tls_insecure")) {
                tls_insecure = std.mem.eql(u8, v, "true");
            } else {
                try user_headers.append(allocator, k);
                try user_headers.append(allocator, v);
            }
        }
    }
    if (tls_insecure) {
        // This transport wires in no permissive TLS verifier, so the request is
        // surfaced rather than silently ignored.
        stderrPrint("warning: __klio_cfg_tls_insecure requested; insecure mode is a no-op until a custom verifier is wired\n");
    }

    const result = httpRequest(allocator, .{
        .method = method,
        .url = url,
        .body = body,
        .user_headers = user_headers.items,
        .timeout_ms = timeout_ms,
        .connect_timeout_ms = connect_timeout_ms,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var out = try allocator.alloc([]const u8, 3);
            out[0] = try allocator.dupe(u8, "0");
            out[1] = try std.fmt.allocPrint(allocator, "transport error: {s}", .{@errorName(e)});
            out[2] = try allocator.dupe(u8, "");
            return out;
        },
    };
    return result;
}

const RequestInputs = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8,
    user_headers: []const []const u8,
    timeout_ms: u64,
    connect_timeout_ms: ?u64,
};

const TransportError = error{
    OutOfMemory,
    UnsupportedScheme,
    InvalidUrl,
    ResolveFailed,
    ConnectFailed,
    SocketFailed,
    WriteFailed,
    ReadFailed,
    BadResponse,
};

fn httpRequest(allocator: Allocator, in: RequestInputs) TransportError![][]const u8 {
    const target = try parseUrl(in.url);
    if (!std.ascii.eqlIgnoreCase(target.scheme, "http")) return error.UnsupportedScheme;

    const addr = try resolveIp4(target.host, target.port);
    const connect_ms = in.connect_timeout_ms orelse in.timeout_ms;
    const fd = try connectTimeout(addr, connect_ms);
    defer _ = c.close(fd);
    applyTimeout(fd, in.timeout_ms);

    const send_body = !(std.mem.eql(u8, in.method, "GET") or
        std.mem.eql(u8, in.method, "HEAD") or
        std.mem.eql(u8, in.method, "DELETE") or
        in.body.len == 0);

    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(allocator);
    try req.appendSlice(allocator, in.method);
    try req.append(allocator, ' ');
    try req.appendSlice(allocator, target.path);
    try req.appendSlice(allocator, " HTTP/1.1\r\n");
    try req.appendSlice(allocator, "Host: ");
    try req.appendSlice(allocator, target.host);
    try req.appendSlice(allocator, "\r\n");
    try req.appendSlice(allocator, "Connection: close\r\n");
    {
        var i: usize = 0;
        while (i + 1 < in.user_headers.len) : (i += 2) {
            try req.appendSlice(allocator, in.user_headers[i]);
            try req.appendSlice(allocator, ": ");
            try req.appendSlice(allocator, in.user_headers[i + 1]);
            try req.appendSlice(allocator, "\r\n");
        }
    }
    if (send_body) {
        var lenbuf: [24]u8 = undefined;
        const ls = std.fmt.bufPrint(&lenbuf, "{d}", .{in.body.len}) catch unreachable;
        try req.appendSlice(allocator, "Content-Length: ");
        try req.appendSlice(allocator, ls);
        try req.appendSlice(allocator, "\r\n");
    }
    try req.appendSlice(allocator, "\r\n");
    if (send_body) try req.appendSlice(allocator, in.body);

    writeAll(fd, req.items) catch return error.WriteFailed;

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    readToEnd(allocator, fd, &raw) catch return error.ReadFailed;

    return flattenResponse(allocator, raw.items);
}

fn flattenResponse(allocator: Allocator, raw: []const u8) TransportError![][]const u8 {
    const sep = std.mem.find(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    const head = raw[0..sep];
    const body = raw[sep + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    const status = parseStatusLine(status_line) orelse return error.BadResponse;

    var content_type: []const u8 = "";
    var pairs: std.ArrayList(HeaderPair) = .empty;
    defer pairs.deinit(allocator);
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "content-type")) {
            content_type = val;
        }
        try pairs.append(allocator, .{ .key = key, .value = val });
    }

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{status}));
    try out.append(allocator, try allocator.dupe(u8, body));
    try out.append(allocator, try allocator.dupe(u8, content_type));
    for (pairs.items) |p| {
        try out.append(allocator, try allocator.dupe(u8, p.key));
        try out.append(allocator, try allocator.dupe(u8, p.value));
    }
    return out.toOwnedSlice(allocator);
}

fn parseStatusLine(line: []const u8) ?i64 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return null; // HTTP version
    const code = it.next() orelse return null;
    return std.fmt.parseInt(i64, code, 10) catch null;
}

const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Split `scheme://host[:port][/path]`; the path defaults to `/` and the port to
/// the scheme default.
fn parseUrl(url: []const u8) TransportError!ParsedUrl {
    const scheme_end = std.mem.find(u8, url, "://") orelse return error.InvalidUrl;
    const scheme = url[0..scheme_end];
    const rest = url[scheme_end + 3 ..];
    const authority_end = std.mem.findAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    const path = if (authority_end < rest.len) rest[authority_end..] else "/";
    if (authority.len == 0) return error.InvalidUrl;

    var host = authority;
    var port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "https")) 443 else 80;
    if (std.mem.findScalarLast(u8, authority, ':')) |ci| {
        host = authority[0..ci];
        port = std.fmt.parseInt(u16, authority[ci + 1 ..], 10) catch return error.InvalidUrl;
    }
    return .{ .scheme = scheme, .host = host, .port = port, .path = path };
}

fn resolveIp4(host: []const u8, port: u16) TransportError!posix.sockaddr.in {
    if (parseIp4Literal(host)) |octets| {
        return makeSockaddrIn(octets, port);
    }
    const octets = resolveDns(host) catch return error.ResolveFailed;
    return makeSockaddrIn(octets, port);
}

fn makeSockaddrIn(octets: [4]u8, port: u16) posix.sockaddr.in {
    // `addr` holds the four octets in network order, and a bit-cast preserves
    // that layout regardless of host endianness.
    return .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(octets),
    };
}

fn parseIp4Literal(host: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (i != 4) return null;
    return octets;
}

/// UDP DNS A-record query against the first nameserver in `/etc/resolv.conf`,
/// falling back to systemd-resolved's stub at `127.0.0.53`.
fn resolveDns(host: []const u8) ![4]u8 {
    const server = readResolvConf() orelse [4]u8{ 127, 0, 0, 53 };

    var query: [512]u8 = undefined;
    const qlen = buildDnsQuery(&query, host) orelse return error.InvalidUrl;

    const fd = c.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    applyTimeout(fd, 5000);

    const addr = makeSockaddrIn(server, 53);
    const sent = c.sendto(
        fd,
        &query,
        qlen,
        0,
        @ptrCast(&addr),
        @sizeOf(posix.sockaddr.in),
    );
    if (sent < 0) return error.WriteFailed;

    var resp: [512]u8 = undefined;
    const got = c.recvfrom(fd, &resp, resp.len, 0, null, null);
    if (got < 0) return error.ReadFailed;
    return parseDnsAnswer(resp[0..@intCast(got)]) orelse error.ResolveFailed;
}

fn readResolvConf() ?[4]u8 {
    const fd = c.open("/etc/resolv.conf", .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n_rc = c.read(fd, &buf, buf.len);
    if (n_rc < 0) return null;
    const text = buf[0..@intCast(n_rc)];
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        const prefix = "nameserver";
        if (std.mem.startsWith(u8, t, prefix)) {
            const ip = std.mem.trim(u8, t[prefix.len..], " \t");
            if (parseIp4Literal(ip)) |o| return o;
        }
    }
    return null;
}

fn buildDnsQuery(buf: []u8, host: []const u8) ?usize {
    if (buf.len < 12) return null;
    buf[0] = 0x4b;
    buf[1] = 0x4b;
    buf[2] = 0x01; // RD
    buf[3] = 0x00;
    buf[4] = 0x00;
    buf[5] = 0x01; // QDCOUNT = 1
    buf[6] = 0x00;
    buf[7] = 0x00;
    buf[8] = 0x00;
    buf[9] = 0x00;
    buf[10] = 0x00;
    buf[11] = 0x00;
    var pos: usize = 12;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return null;
        if (pos + 1 + label.len >= buf.len) return null;
        buf[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(buf[pos .. pos + label.len], label);
        pos += label.len;
    }
    if (pos + 5 > buf.len) return null;
    buf[pos] = 0; // root label
    pos += 1;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01; // QTYPE = A
    buf[pos + 2] = 0x00;
    buf[pos + 3] = 0x01; // QCLASS = IN
    pos += 4;
    return pos;
}

fn parseDnsAnswer(resp: []const u8) ?[4]u8 {
    if (resp.len < 12) return null;
    const qd = std.mem.readInt(u16, resp[4..6], .big);
    const an = std.mem.readInt(u16, resp[6..8], .big);
    var pos: usize = 12;
    var q: usize = 0;
    while (q < qd) : (q += 1) {
        pos = skipName(resp, pos) orelse return null;
        if (pos + 4 > resp.len) return null;
        pos += 4; // QTYPE + QCLASS
    }
    var a: usize = 0;
    while (a < an) : (a += 1) {
        pos = skipName(resp, pos) orelse return null;
        if (pos + 10 > resp.len) return null;
        const rtype = std.mem.readInt(u16, resp[pos..][0..2], .big);
        const rdlen = std.mem.readInt(u16, resp[pos + 8 ..][0..2], .big);
        pos += 10;
        if (pos + rdlen > resp.len) return null;
        if (rtype == 1 and rdlen == 4) {
            return .{ resp[pos], resp[pos + 1], resp[pos + 2], resp[pos + 3] };
        }
        pos += rdlen;
    }
    return null;
}

fn skipName(resp: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < resp.len) {
        const len = resp[pos];
        if (len == 0) return pos + 1;
        if (len & 0xC0 == 0xC0) return pos + 2; // compression pointer
        pos += 1 + len;
    }
    return null;
}

fn connectTimeout(addr: posix.sockaddr.in, timeout_ms: u64) TransportError!i32 {
    const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    applyTimeout(fd, timeout_ms);
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    if (rc < 0) return error.ConnectFailed;
    return fd;
}

fn applyTimeout(fd: i32, timeout_ms: u64) void {
    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const bytes = std.mem.asBytes(&tv);
    _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, bytes.ptr, @intCast(bytes.len));
    _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, bytes.ptr, @intCast(bytes.len));
}

fn writeAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = c.write(fd, data.ptr + off, data.len - off);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

fn readToEnd(allocator: Allocator, fd: i32, out: *std.ArrayList(u8)) !void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const rc = c.read(fd, &chunk, chunk.len);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(rc)]);
    }
}

fn request(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const method = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const url = switch (try arg_string(a, ctx, 1)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const body = switch (try arg_string(a, ctx, 2)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const headers = switch (try arg_string_array(a, ctx, 3)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    if (envIsSet(a, "KLIO_TRACE_HTTP")) {
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[HTTP] {s} {s}\n", .{ method, url }) catch "[HTTP]\n";
        stderrPrint(line);
    }
    const out = try perform(a, method, url, body, headers);
    defer freeOwnedStrings(a, out);
    return .{ .ok = try make_string_array(a, out) };
}

fn get(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const url = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const out = try perform(a, "GET", url, "", &.{});
    defer freeOwnedStrings(a, out);
    return .{ .ok = try make_string_array(a, out) };
}

fn post(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const url = switch (try arg_string(a, ctx, 0)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const body = switch (try arg_string(a, ctx, 1)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const out = try perform(a, "POST", url, body, &.{});
    defer freeOwnedStrings(a, out);
    return .{ .ok = try make_string_array(a, out) };
}

fn set_header(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .Unit };
}

const HeaderPairOwned = struct { key: []const u8, value: []const u8 };

const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    headers: []HeaderPairOwned,
};

/// Read one HTTP/1.1 request off `fd` as `(method, path, body, headers)`, with
/// `Content-Length` driving the body read. Null on a closed or malformed stream.
fn read_request(allocator: Allocator, fd: i32) Allocator.Error!?ParsedRequest {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var chunk: [1024]u8 = undefined;
    var header_end: ?usize = null;
    while (header_end == null) {
        const rc = c.read(fd, &chunk, chunk.len);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return null;
        }
        if (rc == 0) return null;
        try buf.appendSlice(allocator, chunk[0..@intCast(rc)]);
        header_end = std.mem.find(u8, buf.items, "\r\n\r\n");
    }
    const sep = header_end.?;
    const head = buf.items[0..sep];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return null;
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method_raw = parts.next() orelse return null;
    const path_raw = parts.next() orelse return null;
    const method = try allocator.dupe(u8, method_raw);
    const path = try allocator.dupe(u8, path_raw);

    var content_length: usize = 0;
    var headers: std.ArrayList(HeaderPairOwned) = .empty;
    while (lines.next()) |line| {
        const t = std.mem.trimEnd(u8, line, " \t\r");
        if (t.len == 0) break;
        const colon = std.mem.findScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        const val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (key.len == 0) continue;
        try headers.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, val),
        });
        if (std.ascii.eqlIgnoreCase(key, "content-length")) {
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }
    const header_slice = try headers.toOwnedSlice(allocator);

    var body: []const u8 = "";
    if (content_length > 0) {
        const have = buf.items.len - (sep + 4);
        var body_buf = try allocator.alloc(u8, content_length);
        const take = @min(have, content_length);
        @memcpy(body_buf[0..take], buf.items[sep + 4 .. sep + 4 + take]);
        var filled = take;
        while (filled < content_length) {
            const rc = c.read(fd, body_buf.ptr + filled, content_length - filled);
            if (rc < 0) {
                if (posix.errno(rc) == .INTR) continue;
                return null;
            }
            if (rc == 0) return null;
            filled += @intCast(rc);
        }
        body = body_buf;
    }
    return .{ .method = method, .path = path, .body = body, .headers = header_slice };
}

fn asciiStripPrefixIgnoreCase(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (s.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix)) return null;
    return s[prefix.len..];
}

fn reason_phrase(status: i64) []const u8 {
    return switch (status) {
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "OK",
    };
}

fn write_response(
    allocator: Allocator,
    fd: i32,
    status: i64,
    content_type: []const u8,
    body: []const u8,
    headers: []const HeaderPairOwned,
) Allocator.Error!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ status, reason_phrase(status), content_type, body.len });
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, "content-type") or
            std.ascii.eqlIgnoreCase(h.key, "content-length") or
            std.ascii.eqlIgnoreCase(h.key, "connection")) continue;
        try out.print(allocator, "{s}: {s}\r\n", .{ h.key, h.value });
    }
    try out.appendSlice(allocator, "\r\n");
    try out.appendSlice(allocator, body);
    writeAll(fd, out.items) catch {};
}

/// Bind `127.0.0.1:port` and serve forever, handing each request to `dispatch`,
/// a Kotlin `(Array<String>) -> Array<String>` over
/// `[method, path, body, …headers]` returning `[status, contentType, body,
/// …headers]`, sequentially on the serving thread.
///
/// The accept is polled with a timeout so a daemon serve dispatched onto the
/// coroutine worker pool notices the run-boundary abandon request between
/// connections; on the main thread `shouldAbandon` stays false.
fn serve(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const port: u16 = blk: {
        if (ctx.args.len >= 1) {
            switch (ctx.args[0]) {
                .Int => |p| break :blk std.math.cast(u16, p) orelse 0,
                .Long => |p| break :blk std.math.cast(u16, p) orelse 0,
                else => {},
            }
        }
        return .{ .err = .{ .Type = "__kktor_serve: port must be Int" } };
    };
    const dispatch: Value = if (ctx.args.len >= 2)
        ctx.args[1]
    else
        return .{ .err = .{ .Type = "__kktor_serve: missing dispatch lambda" } };

    const listen_fd = bindListener(port) catch {
        const msg = try std.fmt.allocPrint(a, "__kktor_serve: bind {d} failed", .{port});
        return .{ .err = .{ .Type = msg } };
    };
    defer _ = c.close(listen_fd);

    const serve_max: usize = blk: {
        const v = runtime.envOnce("KLIO_SERVE_MAX") orelse break :blk 0;
        break :blk std.fmt.parseInt(usize, v, 10) catch 0;
    };
    var served: usize = 0;

    while (true) {
        if (runtime.shouldAbandon()) break;
        if (serve_max != 0 and served >= serve_max) break;
        var pfd = [_]posix.pollfd{.{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 }};
        // The accept wait holds no unrooted live Value, so it is bracketed as a
        // GC blocking-safe region and a concurrent worker's collection can
        // complete its rendezvous while this thread parks.
        runtime.gc.enterBlockingSafe();
        const ready = c.poll(&pfd, 1, 200);
        runtime.gc.exitBlockingSafe();
        if (ready <= 0) continue; // timeout (re-check abandon) or transient error
        const conn = c.accept(listen_fd, null, null);
        if (conn < 0) continue;
        defer _ = c.close(conn);
        const parsed = (try read_request(a, conn)) orelse continue;
        // The parsed strings are owned by `a` and their bytes are copied into the
        // request array's cells, so free the originals under a freeing allocator.
        defer if (runtime.freeScratch()) {
            a.free(parsed.method);
            a.free(parsed.path);
            if (parsed.body.len != 0) a.free(parsed.body);
            for (parsed.headers) |h| {
                a.free(h.key);
                a.free(h.value);
            }
            a.free(parsed.headers);
        };
        var items: std.ArrayList(Value) = .empty;
        try items.append(a, .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, parsed.method)) });
        try items.append(a, .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, parsed.path)) });
        try items.append(a, .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, parsed.body)) });
        for (parsed.headers) |h| {
            try items.append(a, .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, h.key)) });
            try items.append(a, .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, h.value)) });
        }
        const req = runtime.ArrayData.fromBoxedList(try ValueList.init(a, items));
        // serve owns `req` and `invokeCallable` only borrows it.
        defer if (runtime.reclaimEnabled()) req.release(a);
        const resp = try ctx.host.invokeCallable(&dispatch, &.{req}, ctx.out);
        switch (resp) {
            .err => |e| return .{ .err = e },
            .ok => |rv| {
                const decoded = try decode_response(a, &rv);
                try write_response(a, conn, decoded.status, decoded.content_type, decoded.body, decoded.headers);
                if (runtime.freeScratch()) {
                    a.free(decoded.content_type);
                    a.free(decoded.body);
                    for (decoded.headers) |h| {
                        a.free(h.key);
                        a.free(h.value);
                    }
                    a.free(decoded.headers);
                }
                if (runtime.reclaimEnabled()) rv.release(a);
            },
        }
        served += 1;
    }
    return .{ .ok = .Unit };
}

fn bindListener(port: u16) !i32 {
    const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    const one: c_int = 1;
    _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
    const addr = makeSockaddrIn(.{ 127, 0, 0, 1 }, port);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) < 0) return error.BindFailed;
    if (c.listen(fd, 128) < 0) return error.ListenFailed;
    return fd;
}

const DecodedResponse = struct {
    status: i64,
    content_type: []const u8,
    body: []const u8,
    headers: []HeaderPairOwned,
};

fn decode_response(allocator: Allocator, v: *const Value) Allocator.Error!DecodedResponse {
    const items_ref: ?ValueList = switch (v.*) {
        .Array => |a| a.boxedList(),
        .List => |l| l.items,
        else => null,
    };
    if (items_ref) |items| {
        const g = items.borrow();
        defer g.deinit();
        const slice = g.get().items;
        const status: i64 = if (slice.len > 0) switch (slice[0]) {
            .String => |s| blk: {
                const sg = s.borrow();
                defer sg.deinit();
                break :blk std.fmt.parseInt(i64, sg.get().bytes, 10) catch 200;
            },
            .Int => |i| @intCast(i),
            .Long => |l| l,
            else => 200,
        } else 200;
        var hdrs: std.ArrayList(HeaderPairOwned) = .empty;
        var i: usize = 3;
        while (i + 1 < slice.len) : (i += 2) {
            try hdrs.append(allocator, .{
                .key = try strAt(allocator, slice, i),
                .value = try strAt(allocator, slice, i + 1),
            });
        }
        return .{
            .status = status,
            .content_type = try strAt(allocator, slice, 1),
            .body = try strAt(allocator, slice, 2),
            .headers = try hdrs.toOwnedSlice(allocator),
        };
    }
    return .{
        .status = 500,
        .content_type = try allocator.dupe(u8, "text/plain"),
        .body = try allocator.dupe(u8, ""),
        .headers = &.{},
    };
}

fn strAt(allocator: Allocator, slice: []const Value, i: usize) Allocator.Error![]const u8 {
    if (i < slice.len) {
        switch (slice[i]) {
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                return allocator.dupe(u8, g.get().bytes);
            },
            else => {},
        }
    }
    return allocator.dupe(u8, "");
}

fn _kind_in_scope(_: PrimitiveArrayKind) void {}

fn stderrPrint(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = c.write(2, s.ptr + off, s.len - off);
        if (rc < 0) return;
        if (rc == 0) return;
        off += @intCast(rc);
    }
}

fn envIsSet(allocator: Allocator, name: []const u8) bool {
    return runtime.procEnvIsSet(allocator, name);
}

const testing = std.testing;

fn makeCtx(allocator: Allocator, host: runtime.IntrinsicHost, out: Output, args: []const Value) CallCtx {
    return .{ .args = args, .out = out, .host = host, .allocator = allocator };
}

test "host bindings register the engine surface" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("io.ktor.client.engine.__kktor_request") != null);
    try testing.expect(b.resolve("io.ktor.client.engine.__kktor_get") != null);
    try testing.expect(b.resolve("io.ktor.client.engine.__kktor_post") != null);
    try testing.expect(b.resolve("io.ktor.client.engine.__kktor_setHeader") != null);
    try testing.expect(b.resolve("io.ktor.server.engine.__kktor_serve") != null);
    try testing.expect(b.resolve("io.ktor.util.date.getTimeMillis") != null);
    try testing.expect(b.resolve("io.ktor.util.__kktor_digest") != null);
    try testing.expect(b.resolve("io.ktor.utils.io.locks.ReentrantLock.lock") != null);
    try testing.expect(b.resolve("io.ktor.utils.io.locks.ReentrantLock.tryLock") != null);
    try testing.expect(b.resolve("io.ktor.utils.io.locks.ReentrantLock.unlock") != null);
    try testing.expect(b.resolve("io.ktor.client.engine.__nope") == null);
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

test "set_header is a Unit no-op" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(testing.allocator, h.host(), cap.output(), &.{});
    const r = try set_header(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Unit);
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

test "arg_string_array reads strings and maps non-strings to empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);
    var items: std.ArrayList(Value) = .empty;
    try items.append(a, .{ .String = try runtime.strInit(a, "k") });
    try items.append(a, .{ .Int = 7 });
    const arr = runtime.ArrayData.fromBoxedList(try ValueList.init(a, items));
    var ctx = makeCtx(a, h.host(), cap.output(), &.{arr});
    switch (try arg_string_array(a, &ctx, 0)) {
        .ok => |v| {
            try testing.expectEqual(@as(usize, 2), v.len);
            try testing.expectEqualStrings("k", v[0]);
            try testing.expectEqualStrings("", v[1]);
        },
        .err => return error.TestUnexpectedResult,
    }
    switch (try arg_string_array(a, &ctx, 1)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            try testing.expect(e == .Type);
            try testing.expectEqualStrings("ktor-client: argument 1 must be Array<String>", e.Type);
        },
    }
}

test "make_string_array wraps values in a non-prim Array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vals = try a.alloc([]const u8, 2);
    vals[0] = "200";
    vals[1] = "body";
    const v = try make_string_array(a, vals);
    try testing.expect(v == .Array);
    try testing.expect(v.Array.primKind() == null);
    const items = try v.Array.snapshot(a);
    defer a.free(items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expect(items[0] == .String);
}

test "reason_phrase maps known codes and defaults to OK" {
    try testing.expectEqualStrings("Created", reason_phrase(201));
    try testing.expectEqualStrings("No Content", reason_phrase(204));
    try testing.expectEqualStrings("Bad Request", reason_phrase(400));
    try testing.expectEqualStrings("Unauthorized", reason_phrase(401));
    try testing.expectEqualStrings("Forbidden", reason_phrase(403));
    try testing.expectEqualStrings("Not Found", reason_phrase(404));
    try testing.expectEqualStrings("Internal Server Error", reason_phrase(500));
    try testing.expectEqualStrings("OK", reason_phrase(200));
    try testing.expectEqualStrings("OK", reason_phrase(418));
}

test "decode_response pulls status, content type and body from an Array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(Value) = .empty;
    try items.append(a, .{ .String = try runtime.strInit(a, "201") });
    try items.append(a, .{ .String = try runtime.strInit(a, "application/json") });
    try items.append(a, .{ .String = try runtime.strInit(a, "{}") });
    const arr = runtime.ArrayData.fromBoxedList(try ValueList.init(a, items));
    const d = try decode_response(a, &arr);
    try testing.expectEqual(@as(i64, 201), d.status);
    try testing.expectEqualStrings("application/json", d.content_type);
    try testing.expectEqualStrings("{}", d.body);
}

test "decode_response accepts an Int status and a List backing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(Value) = .empty;
    try items.append(a, .{ .Int = 404 });
    try items.append(a, .{ .String = try runtime.strInit(a, "text/plain") });
    try items.append(a, .{ .String = try runtime.strInit(a, "nope") });
    const list = try Value.newList(a, .{ .items = try ValueList.init(a, items), .mutable = false, .enum_entries = false, .backing = null });
    const d = try decode_response(a, &list);
    try testing.expectEqual(@as(i64, 404), d.status);
    try testing.expectEqualStrings("text/plain", d.content_type);
    try testing.expectEqualStrings("nope", d.body);
}

test "decode_response falls back for a non-array value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Value{ .Int = 1 };
    const d = try decode_response(a, &v);
    try testing.expectEqual(@as(i64, 500), d.status);
    try testing.expectEqualStrings("text/plain", d.content_type);
    try testing.expectEqualStrings("", d.body);
}

test "parseUrl splits scheme host port and path" {
    {
        const u = try parseUrl("http://127.0.0.1:8080/path?q=1");
        try testing.expectEqualStrings("http", u.scheme);
        try testing.expectEqualStrings("127.0.0.1", u.host);
        try testing.expectEqual(@as(u16, 8080), u.port);
        try testing.expectEqualStrings("/path?q=1", u.path);
    }
    {
        const u = try parseUrl("http://example.com/");
        try testing.expectEqualStrings("example.com", u.host);
        try testing.expectEqual(@as(u16, 80), u.port);
        try testing.expectEqualStrings("/", u.path);
    }
    {
        const u = try parseUrl("https://example.com");
        try testing.expectEqual(@as(u16, 443), u.port);
        try testing.expectEqualStrings("/", u.path);
    }
    try testing.expectError(error.InvalidUrl, parseUrl("not-a-url"));
}

test "parseIp4Literal accepts dotted quads and rejects names" {
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, parseIp4Literal("127.0.0.1").?);
    try testing.expect(parseIp4Literal("example.com") == null);
    try testing.expect(parseIp4Literal("1.2.3") == null);
    try testing.expect(parseIp4Literal("1.2.3.4.5") == null);
}

test "parseStatusLine reads the numeric code" {
    try testing.expectEqual(@as(i64, 200), parseStatusLine("HTTP/1.1 200 OK").?);
    try testing.expectEqual(@as(i64, 404), parseStatusLine("HTTP/1.1 404 Not Found").?);
    try testing.expect(parseStatusLine("garbage") == null);
}

test "flattenResponse extracts status body content-type and headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Test: yes\r\n\r\n{\"ok\":true}";
    const out = try flattenResponse(a, raw);
    try testing.expectEqualStrings("200", out[0]);
    try testing.expectEqualStrings("{\"ok\":true}", out[1]);
    try testing.expectEqualStrings("application/json", out[2]);
    try testing.expectEqualStrings("Content-Type", out[3]);
    try testing.expectEqualStrings("application/json", out[4]);
    try testing.expectEqualStrings("X-Test", out[5]);
    try testing.expectEqualStrings("yes", out[6]);
}

test "buildDnsQuery and parseDnsAnswer round-trip an A record" {
    var q: [512]u8 = undefined;
    const n = buildDnsQuery(&q, "example.com").?;
    try testing.expect(n > 12);
    try testing.expectEqual(@as(u8, 7), q[12]);

    var resp: [512]u8 = undefined;
    @memcpy(resp[0..n], q[0..n]);
    resp[2] = 0x81; // QR + RD
    resp[3] = 0x80; // RA
    resp[6] = 0x00;
    resp[7] = 0x01; // ANCOUNT = 1
    var pos = n;
    resp[pos] = 0xC0; // name pointer to offset 12
    resp[pos + 1] = 12;
    resp[pos + 2] = 0x00;
    resp[pos + 3] = 0x01; // TYPE A
    resp[pos + 4] = 0x00;
    resp[pos + 5] = 0x01; // CLASS IN
    resp[pos + 6] = 0;
    resp[pos + 7] = 0;
    resp[pos + 8] = 0;
    resp[pos + 9] = 60; // TTL
    resp[pos + 10] = 0x00;
    resp[pos + 11] = 0x04; // RDLENGTH = 4
    resp[pos + 12] = 93;
    resp[pos + 13] = 184;
    resp[pos + 14] = 216;
    resp[pos + 15] = 34;
    pos += 16;
    const octets = parseDnsAnswer(resp[0..pos]).?;
    try testing.expectEqual([4]u8{ 93, 184, 216, 34 }, octets);
}

test "asciiStripPrefixIgnoreCase honors case insensitivity" {
    try testing.expectEqualStrings(" 42", asciiStripPrefixIgnoreCase("Content-Length: 42", "content-length:").?);
    try testing.expect(asciiStripPrefixIgnoreCase("Other: 1", "content-length:") == null);
}

test {
    std.testing.refAllDecls(@This());
    _ = _kind_in_scope;
}
