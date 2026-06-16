//! Native HTTP engine for klio's ktor-client pack.
//!
//! The Kotlin shim declares `HttpClient`, `HttpRequestBuilder`,
//! `HttpResponse`, and the common `HttpMethod` surface. The engine
//! helpers `__kktor_request` / `__kktor_get` / `__kktor_post` are
//! bound here against a small blocking HTTP/1.1 transport built on the
//! platform sockets, keeping the dependency footprint modest and
//! avoiding pulling a full async runtime into the interpreter: each
//! request blocks the calling thread for its duration.
//!
//! Each request returns a flat `Array<String>` shaped like
//! `[statusCode, body, contentType, headerKey, headerVal, ...]` so
//! the shim can rebuild a `HttpResponse` without the native side
//! having to construct Kotlin instances.

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
// The HTTP transport is a small blocking client/server over libc sockets,
// which the binary links on every target (zstd pulls in libc). `posix`
// supplies the address/constant types; `c` the syscalls; errno comes back
// through `posix.errno`.
const c = std.c;
const posix = std.posix;

/// Build the FQN -> `StdlibFn` registry for the ktor-client pack. Mirrors
/// the Rust `host_bindings!` macro expansion: each `"fqn" => function`
/// pair is registered into a fresh `HostBindings`.
pub fn hostBindings(allocator: Allocator) Allocator.Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("io.ktor.client.engine.__kktor_request", request);
    try b.register("io.ktor.client.engine.__kktor_get", get);
    try b.register("io.ktor.client.engine.__kktor_post", post);
    try b.register("io.ktor.client.engine.__kktor_setHeader", set_header);
    // Server engine: bind a socket and dispatch each request back
    // into the interpreter's routing lambda.
    try b.register("io.ktor.server.engine.__kktor_serve", serve);
    // Platform clock for `io.ktor.util.date` (the posix actual reads it
    // via cinterop; klio supplies the wall-clock epoch millis).
    try b.register("io.ktor.util.date.getTimeMillis", get_time_millis);
    // `io.ktor.utils.io.locks.ReentrantLock`: real locks over the same
    // per-object reentrant monitor as `kotlin.synchronized`, keyed on
    // the receiver's identity. A `ByteChannel` can be written from a
    // `Dispatchers.Default` worker while another coroutine reads, so
    // the lock actual must hold real exclusion across threads.
    try b.register("io.ktor.utils.io.locks.ReentrantLock.lock", stdlib.implementations.concurrent_lock_enter);
    try b.register("io.ktor.utils.io.locks.ReentrantLock.tryLock", stdlib.implementations.concurrent_lock_try_enter);
    try b.register("io.ktor.utils.io.locks.ReentrantLock.unlock", stdlib.implementations.concurrent_lock_exit);
    // The locks actual's top-level `synchronized(lock, block)` shares the
    // bare name with the stdlib host binding; bind the pack fqn so a call
    // that resolves to the pack's lifted declaration (instead of the
    // default import) still holds the real monitor.
    try b.register("io.ktor.utils.io.locks.synchronized", stdlib.implementations.concurrent_synchronized);
    return b;
}

fn get_time_millis(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Long = runtime.clockWallMillis() } };
}

/// `Result<T, RuntimeError>` returned by the argument decoders. OOM stays
/// a Zig error; a `RuntimeError` surfaces as data.
fn ArgResult(comptime T: type) type {
    return union(enum) { ok: T, err: RuntimeError };
}

/// Read the `idx`th argument as a `String`. Returns an owned copy.
fn arg_string(allocator: Allocator, ctx: *const CallCtx, idx: usize) Allocator.Error!ArgResult([]const u8) {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                return .{ .ok = try allocator.dupe(u8, g.get().*) };
            },
            else => {},
        }
    }
    const msg = try std.fmt.allocPrint(allocator, "ktor-client: argument {d} must be a String", .{idx});
    return .{ .err = .{ .Type = msg } };
}

/// Read the `idx`th argument as an `Array<String>`. Non-string items
/// become empty strings, matching the Rust fallback. Returns owned copies.
fn arg_string_array(allocator: Allocator, ctx: *const CallCtx, idx: usize) Allocator.Error!ArgResult([][]const u8) {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .Array => |a| {
                const g = a.items.borrow();
                defer g.deinit();
                const items = g.get().items;
                var out = try allocator.alloc([]const u8, items.len);
                for (items, 0..) |v, i| {
                    switch (v) {
                        .String => |s| {
                            const sg = s.borrow();
                            defer sg.deinit();
                            out[i] = try allocator.dupe(u8, sg.get().*);
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

/// Wrap an owned slice of owned strings in a `Value::Array { prim: None }`.
fn make_string_array(allocator: Allocator, values: [][]const u8) Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacityPrecise(allocator, values.len);
    for (values) |s| {
        list.appendAssumeCapacity(.{ .String = try StringRef.init(allocator, s) });
    }
    const items = try ValueList.init(allocator, list);
    return .{ .Array = .{ .items = items, .prim = null } };
}

/// Free an owned slice of owned strings produced by `perform`. The strings
/// are copied into fresh `StringRef` cells by `make_string_array` (which
/// `.init`-dupes under reclaim), so the originals must be released. Gated on
/// reclaim: under the arena fast path the arena reclaims them wholesale.
fn freeOwnedStrings(allocator: Allocator, values: [][]const u8) void {
    if (!runtime.reclaimEnabled()) return;
    for (values) |s| allocator.free(s);
    allocator.free(values);
}

/// One header key/value pair captured off a response.
const HeaderPair = struct { key: []const u8, value: []const u8 };

/// Carry out a single blocking HTTP/1.1 request and flatten the response
/// into `[statusCode, body, contentType, headerKey, headerVal, ...]`. All
/// strings are owned by `allocator`.
fn perform(
    allocator: Allocator,
    method: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) Allocator.Error![][]const u8 {
    // Extract per-request config from reserved header keys before
    // they hit the agent. `__klio_cfg_*` keys are stripped; the
    // remainder are forwarded verbatim.
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
        // A permissive TLS verifier is not wired into this transport.
        // Surface the request explicitly so users know it was honored.
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
            // Transport-level failure: `["0", "transport error: ...", ""]`.
            var out = try allocator.alloc([]const u8, 3);
            out[0] = try allocator.dupe(u8, "0");
            out[1] = try std.fmt.allocPrint(allocator, "transport error: {s}", .{@errorName(e)});
            out[2] = try allocator.dupe(u8, "");
            return out;
        },
    };
    return result;
}

/// Inputs for a single transport request.
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

/// Drive the request over a TCP socket and flatten the response. The
/// returned slice and every string it holds are owned by `allocator`.
fn httpRequest(allocator: Allocator, in: RequestInputs) TransportError![][]const u8 {
    const target = try parseUrl(in.url);
    if (!std.ascii.eqlIgnoreCase(target.scheme, "http")) return error.UnsupportedScheme;

    const addr = try resolveIp4(target.host, target.port);
    const connect_ms = in.connect_timeout_ms orelse in.timeout_ms;
    const fd = try connectTimeout(addr, connect_ms);
    defer _ = c.close(fd);
    applyTimeout(fd, in.timeout_ms);

    // `GET`/`HEAD`/`DELETE` and any empty-body method skip sending a
    // request body.
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

/// Parse `[status, body, contentType, k, v, ...]` out of a raw HTTP/1.1
/// response. Strings are owned by `allocator`.
fn flattenResponse(allocator: Allocator, raw: []const u8) TransportError![][]const u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    const head = raw[0..sep];
    const body = raw[sep + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    const status = parseStatusLine(status_line) orelse return error.BadResponse;

    var content_type: []const u8 = "";
    var pairs: std.ArrayList(HeaderPair) = .empty;
    defer pairs.deinit(allocator);
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
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

/// Pull the numeric status code out of `HTTP/1.1 200 OK`.
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

/// Split `scheme://host[:port][/path]` into its parts. The path defaults
/// to `/` and the port to the scheme default (80 for http, 443 for https).
fn parseUrl(url: []const u8) TransportError!ParsedUrl {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const scheme = url[0..scheme_end];
    const rest = url[scheme_end + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    const path = if (authority_end < rest.len) rest[authority_end..] else "/";
    if (authority.len == 0) return error.InvalidUrl;

    var host = authority;
    var port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "https")) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |ci| {
        host = authority[0..ci];
        port = std.fmt.parseInt(u16, authority[ci + 1 ..], 10) catch return error.InvalidUrl;
    }
    return .{ .scheme = scheme, .host = host, .port = port, .path = path };
}

/// Resolve a host to an IPv4 `sockaddr.in`. Numeric dotted-quads are
/// parsed directly; hostnames are looked up over UDP DNS.
fn resolveIp4(host: []const u8, port: u16) TransportError!posix.sockaddr.in {
    if (parseIp4Literal(host)) |octets| {
        return makeSockaddrIn(octets, port);
    }
    const octets = resolveDns(host) catch return error.ResolveFailed;
    return makeSockaddrIn(octets, port);
}

fn makeSockaddrIn(octets: [4]u8, port: u16) posix.sockaddr.in {
    // `addr` holds the four octets in network order in memory; a bit-cast
    // preserves that layout regardless of host endianness.
    return .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(octets),
    };
}

/// Parse a dotted-quad literal into four octets, or `null` if not numeric.
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

/// Minimal UDP DNS A-record query against the first nameserver in
/// `/etc/resolv.conf` (falling back to `127.0.0.53`, systemd-resolved's
/// stub). Returns the first A record's four octets.
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

/// Read the first `nameserver` line from `/etc/resolv.conf`.
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

/// Encode a standard A-record DNS query for `host` into `buf`, returning
/// its length.
fn buildDnsQuery(buf: []u8, host: []const u8) ?usize {
    if (buf.len < 12) return null;
    // Header: id=0x4b4b, RD flag set, 1 question.
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

/// Walk a DNS response and return the first A record's four octets.
fn parseDnsAnswer(resp: []const u8) ?[4]u8 {
    if (resp.len < 12) return null;
    const qd = std.mem.readInt(u16, resp[4..6], .big);
    const an = std.mem.readInt(u16, resp[6..8], .big);
    var pos: usize = 12;
    // Skip the question section.
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

/// Advance past a (possibly compressed) DNS name, returning the position
/// just after it.
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

/// Connect a fresh TCP socket to `addr`, honoring `timeout_ms` for the
/// connect itself.
fn connectTimeout(addr: posix.sockaddr.in, timeout_ms: u64) TransportError!i32 {
    const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    applyTimeout(fd, timeout_ms);
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    if (rc < 0) return error.ConnectFailed;
    return fd;
}

/// Apply a send/receive timeout to a socket (best-effort).
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
    // Permanent, env-gated HTTP trace (`KLIO_TRACE_HTTP=1`): logs each
    // outbound request to stderr. Useful for confirming whether a client
    // call actually reached the engine's transport layer.
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

// Signature is fixed by the `host_bindings!` registration table.
fn set_header(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .Unit };
}

// ----- Server engine -----

/// One parsed inbound HTTP/1.1 request.
const HeaderPairOwned = struct { key: []const u8, value: []const u8 };

const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    headers: []HeaderPairOwned,
};

/// Read one HTTP/1.1 request off `fd`: returns `(method, path, body, headers)`.
/// Every request header is collected (and `Content-Length` also drives the
/// body read). Returns `null` on a closed / malformed stream. All strings
/// are owned by `allocator`.
fn read_request(allocator: Allocator, fd: i32) Allocator.Error!?ParsedRequest {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    // Read until we see the header terminator.
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
        header_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n");
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
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
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

/// Case-insensitive `strip_prefix`.
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
        // 200 and any unmapped code use the generic OK phrase.
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
    // Handler-supplied response headers. Content-Type / Content-Length /
    // Connection are emitted above, so skip any duplicates the handler set.
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

/// `__kktor_serve(port, dispatch)`: bind `127.0.0.1:port` and serve
/// forever. Each request is handed to `dispatch` — a Kotlin lambda
/// `(Array<String>) -> Array<String>` taking `[method, path, body, …headers]`
/// and returning `[status, contentType, body, …headers]` — run on this
/// thread. Connections are accepted and handled sequentially on the serving
/// thread (the dispatch lambda runs on the Vm that owns it).
///
/// The accept is polled with a timeout so a daemon serve started by
/// `start(wait = false)` (dispatched onto the coroutine worker pool) can
/// notice the run-boundary abandon request between connections and return;
/// on the main thread `shouldAbandon` stays false, so it serves forever.
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

    while (true) {
        if (runtime.shouldAbandon()) break;
        var pfd = [_]posix.pollfd{.{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = c.poll(&pfd, 1, 200);
        if (ready <= 0) continue; // timeout (re-check abandon) or transient error
        const conn = c.accept(listen_fd, null, null);
        if (conn < 0) continue;
        defer _ = c.close(conn);
        const parsed = (try read_request(a, conn)) orelse continue;
        // Request array: [method, path, body, hk1, hv1, hk2, hv2, ...] — the
        // shim reads the fixed head and the trailing header key/value pairs.
        var items: std.ArrayList(Value) = .empty;
        try items.append(a, .{ .String = try StringRef.initOwned(a, try a.dupe(u8, parsed.method)) });
        try items.append(a, .{ .String = try StringRef.initOwned(a, try a.dupe(u8, parsed.path)) });
        try items.append(a, .{ .String = try StringRef.initOwned(a, try a.dupe(u8, parsed.body)) });
        for (parsed.headers) |h| {
            try items.append(a, .{ .String = try StringRef.initOwned(a, try a.dupe(u8, h.key)) });
            try items.append(a, .{ .String = try StringRef.initOwned(a, try a.dupe(u8, h.value)) });
        }
        const req = Value{ .Array = .{ .items = try ValueList.init(a, items), .prim = null } };
        // serve owns `req`; invokeCallable BORROWS its args, so release it per
        // iteration. No-op under the arena fast path.
        defer if (runtime.reclaimEnabled()) req.release(a);
        const resp = try ctx.host.invokeCallable(&dispatch, &.{req}, ctx.out);
        switch (resp) {
            .err => |e| return .{ .err = e },
            .ok => |rv| {
                const decoded = try decode_response(a, &rv);
                try write_response(a, conn, decoded.status, decoded.content_type, decoded.body, decoded.headers);
                // `rv` is an owned host result; release it once decoded+written.
                if (runtime.reclaimEnabled()) rv.release(a);
            },
        }
    }
    return .{ .ok = .Unit };
}

/// Bind and listen on `127.0.0.1:port`, returning the listening fd.
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

/// Decoded `[status, contentType, body, hk1, hv1, ...]` response.
const DecodedResponse = struct {
    status: i64,
    content_type: []const u8,
    body: []const u8,
    headers: []HeaderPairOwned,
};

/// Pull `[status, contentType, body, hk1, hv1, ...]` out of the dispatch
/// lambda's returned `Array<String>`, with lenient fallbacks. The trailing
/// key/value pairs are response headers. Strings are owned by `allocator`.
fn decode_response(allocator: Allocator, v: *const Value) Allocator.Error!DecodedResponse {
    const items_ref: ?ValueList = switch (v.*) {
        .Array => |a| a.items,
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
                break :blk std.fmt.parseInt(i64, sg.get().*, 10) catch 200;
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

/// The `i`th item rendered as an owned string, or `""` when it is missing
/// or not a `String`.
fn strAt(allocator: Allocator, slice: []const Value, i: usize) Allocator.Error![]const u8 {
    if (i < slice.len) {
        switch (slice[i]) {
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                return allocator.dupe(u8, g.get().*);
            },
            else => {},
        }
    }
    return allocator.dupe(u8, "");
}

// Bring `PrimitiveArrayKind` into the import group for forward-compat
// when the binding starts returning typed arrays.
fn _kind_in_scope(_: PrimitiveArrayKind) void {}

/// Write `s` to stderr (best-effort), mirroring Rust's `eprintln!`.
fn stderrPrint(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = c.write(2, s.ptr + off, s.len - off);
        if (rc < 0) return;
        if (rc == 0) return;
        off += @intCast(rc);
    }
}

/// `std::env::var(name).is_ok()` — true when the env var is present.
/// Reads the process environment portably (see `runtime.procEnvIsSet`).
fn envIsSet(allocator: Allocator, name: []const u8) bool {
    return runtime.procEnvIsSet(allocator, name);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
    const s = Value{ .String = try StringRef.init(a, "hello") };
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
    try items.append(a, .{ .String = try StringRef.init(a, "k") });
    try items.append(a, .{ .Int = 7 });
    const arr = Value{ .Array = .{ .items = try ValueList.init(a, items), .prim = null } };
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
    try testing.expect(v.Array.prim == null);
    const g = v.Array.items.borrow();
    defer g.deinit();
    const items = g.get().items;
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
    try items.append(a, .{ .String = try StringRef.init(a, "201") });
    try items.append(a, .{ .String = try StringRef.init(a, "application/json") });
    try items.append(a, .{ .String = try StringRef.init(a, "{}") });
    const arr = Value{ .Array = .{ .items = try ValueList.init(a, items), .prim = null } };
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
    try items.append(a, .{ .String = try StringRef.init(a, "text/plain") });
    try items.append(a, .{ .String = try StringRef.init(a, "nope") });
    const list = Value{ .List = .{ .items = try ValueList.init(a, items), .mutable = false, .enum_class = null, .backing = null } };
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
    // Header pairs follow the fixed prefix.
    try testing.expectEqualStrings("Content-Type", out[3]);
    try testing.expectEqualStrings("application/json", out[4]);
    try testing.expectEqualStrings("X-Test", out[5]);
    try testing.expectEqualStrings("yes", out[6]);
}

test "buildDnsQuery and parseDnsAnswer round-trip an A record" {
    var q: [512]u8 = undefined;
    const n = buildDnsQuery(&q, "example.com").?;
    // Header is 12 bytes; question has the encoded name + 4 trailing bytes.
    try testing.expect(n > 12);
    // 7 'example' 3 'com' 0 + qtype/qclass.
    try testing.expectEqual(@as(u8, 7), q[12]);

    // Build a fake response: echo the question, then one A answer.
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
