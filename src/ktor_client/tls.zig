//! TLS natives behind klio's ktor-network-tls actuals: handles to
//! `ktor_tls` sessions that the Kotlin side pumps between a socket's channels
//! and the application's.
//!
//! A session handle is used from whichever coroutine threads read and write
//! the connection, so each one carries its own mutex. Nothing inside that
//! mutex allocates interpreter memory: bytes are copied out under it and
//! turned into Kotlin arrays after it is released, so a collection that
//! stops this thread never waits on another thread blocked on the mutex.
//!
//! Failures return a status (0 handle, -1) and leave a message the Kotlin
//! side reads with `__kktls_error` (per session) or `__kktls_last_error`
//! (per thread, for handle creation).

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const ktor_tls = @import("ktor_tls");
const net = @import("net.zig");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const HostBindings = stdlib.HostBindings;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;
const Session = ktor_tls.Session;

/// Session memory lives outside the collected heap and moves between threads.
const gpa = std.heap.c_allocator;

pub fn register(b: *HostBindings) Allocator.Error!void {
    const P = "io.ktor.network.tls.";
    try b.register(P ++ "__kktls_client", nClient);
    try b.register(P ++ "__kktls_identity", nIdentity);
    try b.register(P ++ "__kktls_identity_free", nIdentityFree);
    try b.register(P ++ "__kktls_server", nServer);
    try b.register(P ++ "__kktls_feed", nFeed);
    try b.register(P ++ "__kktls_take_output", nTakeOutput);
    try b.register(P ++ "__kktls_read", nRead);
    try b.register(P ++ "__kktls_write", nWrite);
    try b.register(P ++ "__kktls_close", nClose);
    try b.register(P ++ "__kktls_state", nState);
    try b.register(P ++ "__kktls_error", nError);
    try b.register(P ++ "__kktls_free", nFree);
    try b.register(P ++ "__kktls_last_error", nLastError);
}

// ---- handles ----------------------------------------------------------------

/// A blocking mutex. Waiting for it counts as blocking for the collector, so
/// a collection never waits on a thread parked here.
pub const Mutex = struct {
    m: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        if (std.c.pthread_mutex_trylock(&self.m) == .SUCCESS) return;
        runtime.gc.enterBlockingSafe();
        _ = std.c.pthread_mutex_lock(&self.m);
        runtime.gc.exitBlockingSafe();
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.m);
    }
};

/// A server identity, shared by every connection of one connector.
const Identity = struct {
    refs: std.atomic.Value(u32) = .init(1),
    chain: [][]u8,
    identity: ktor_tls.Identity,

    fn release(id: *Identity) void {
        if (id.refs.fetchSub(1, .acq_rel) != 1) return;
        for (id.chain) |c| gpa.free(c);
        gpa.free(id.chain);
        std.crypto.secureZero(u8, std.mem.asBytes(&id.identity.key));
        gpa.destroy(id);
    }
};

const Entry = struct {
    mutex: Mutex = .{},
    session: Session = undefined,
    client_config: ktor_tls.ClientConfig = undefined,
    server_config: ktor_tls.ServerConfig = undefined,
    server_name: ?[]u8 = null,
    anchors: ?*Bundle = null,
    identity: ?*Identity = null,

    fn destroy(e: *Entry) void {
        e.session.deinit();
        if (e.server_name) |n| gpa.free(n);
        if (e.anchors) |b| {
            b.deinit(gpa);
            gpa.destroy(b);
        }
        if (e.identity) |id| id.release();
        gpa.destroy(e);
    }
};

const Table = struct {
    mutex: Mutex = .{},
    sessions: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    identities: std.AutoHashMapUnmanaged(u64, *Identity) = .empty,
    next: u64 = 1,
};

var table: Table = .{};

fn putSession(e: *Entry) Allocator.Error!u64 {
    table.mutex.lock();
    defer table.mutex.unlock();
    const id = table.next;
    table.next += 1;
    try table.sessions.put(gpa, id, e);
    return id;
}

fn getSession(id: i64) ?*Entry {
    if (id <= 0) return null;
    table.mutex.lock();
    defer table.mutex.unlock();
    return table.sessions.get(@intCast(id));
}

/// A session handle's entry, locked; null for an unknown handle.
fn lockSession(id: i64) ?*Entry {
    const e = getSession(id) orelse return null;
    e.mutex.lock();
    return e;
}

threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&last_error_buf, fmt, args) catch last_error_buf[0..];
    last_error_len = msg.len;
}

// ---- the platform ---------------------------------------------------------

/// Fresh OS randomness for a session's generator.
fn osSeed() [32]u8 {
    var seed: [32]u8 = undefined;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    io.randomSecure(&seed) catch io.random(&seed);
    return seed;
}

fn nowSec() i64 {
    return @divFloor(runtime.clockWallMillis(), 1000);
}

/// The operating system's trusted roots, loaded once.
const System = struct {
    var mutex: Mutex = .{};
    var loaded = false;
    var bundle: Bundle = .empty;

    fn anchors() *const Bundle {
        mutex.lock();
        defer mutex.unlock();
        if (!loaded) {
            loaded = true;
            var threaded: std.Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            const io = threaded.io();
            bundle.rescan(gpa, io, std.Io.Timestamp.now(io, .real)) catch {
                bundle.deinit(gpa);
                bundle = .empty;
            };
        }
        return &bundle;
    }
};

// ---- argument helpers ---------------------------------------------------------

/// The String argument `i` copied into `gpa` memory, or null for a null.
fn argString(ctx: *const CallCtx, i: usize) Allocator.Error!?[]u8 {
    if (i >= ctx.args.len) return null;
    return switch (ctx.args[i]) {
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk try gpa.dupe(u8, g.get().bytes);
        },
        else => null,
    };
}

fn argBool(ctx: *const CallCtx, i: usize) bool {
    if (i >= ctx.args.len) return false;
    return ctx.args[i] == .Bool and ctx.args[i].Bool;
}

/// `len` bytes of the ByteArray argument `i` from `off`, copied into `gpa`
/// memory; null when the range does not fit the array.
fn argRange(ctx: *CallCtx, i: usize, off: i64, len: i64) Allocator.Error!?[]u8 {
    if (off < 0 or len < 0) return null;
    const Copy = struct {
        off: usize,
        out: []u8,
        fn run(st: *const @This(), bytes: []u8) i64 {
            if (st.off > bytes.len or bytes.len - st.off < st.out.len) return -1;
            @memcpy(st.out, bytes[st.off..][0..st.out.len]);
            return 0;
        }
    };
    const out = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(out);
    const st: Copy = .{ .off = @intCast(off), .out = out };
    const r = try net.withBytes(ctx, i, false, &st, Copy.run);
    if (r == null or r.? != 0) {
        gpa.free(out);
        return null;
    }
    return out;
}

fn stringResult(a: Allocator, s: []const u8) Allocator.Error!EvalResult {
    return .{ .ok = .{ .String = try runtime.strInit(a, s) } };
}

/// Takes the returned bytes (owned by `gpa`) into a ByteArray.
fn bytesResult(a: Allocator, bytes: ?[]u8) Allocator.Error!EvalResult {
    const b = bytes orelse return .{ .ok = .Null };
    defer gpa.free(b);
    return .{ .ok = try net.newByteArray(a, b) };
}

// ---- natives ---------------------------------------------------------------

/// `__kktls_client(serverName, trustPem, systemTrust, insecure): Long`.
/// The session has queued its ClientHello. 0 when the configuration is
/// refused; `__kktls_last_error` says why.
fn nClient(ctx: *CallCtx) Allocator.Error!EvalResult {
    const server_name = try argString(ctx, 0);
    const trust_pem = try argString(ctx, 1);
    defer if (trust_pem) |p| gpa.free(p);
    const system_trust = argBool(ctx, 2);
    const insecure = argBool(ctx, 3);

    const e = try gpa.create(Entry);
    e.* = .{ .server_name = server_name };
    var ok = false;
    defer if (!ok) {
        if (e.server_name) |n| gpa.free(n);
        if (e.anchors) |b| {
            b.deinit(gpa);
            gpa.destroy(b);
        }
        gpa.destroy(e);
    };
    const now = nowSec();
    if (trust_pem) |pem_text| {
        const b = try gpa.create(Bundle);
        b.* = .empty;
        e.anchors = b;
        const added = ktor_tls.x509.addPem(b, gpa, pem_text, now) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                setLastError("the trusted certificates are not valid PEM certificates", .{});
                return net.int(0);
            },
        };
        if (added == 0 and !system_trust) {
            setLastError("no trusted certificate is currently valid", .{});
            return net.int(0);
        }
    }
    e.client_config = .{
        .server_name = e.server_name,
        .verification = if (insecure) .insecure_accept_any else .{ .trust = .{
            .anchors = e.anchors,
            .system_anchors = if (system_trust) System.anchors() else null,
            .now_sec = now,
        } },
    };
    e.session = try Session.initClient(gpa, &e.client_config, osSeed());
    if (e.session.failure()) |f| {
        setLastError("{s}", .{f.reason});
        e.session.deinit();
        return net.int(0);
    }
    const id = putSession(e) catch |err| {
        e.session.deinit();
        return err;
    };
    ok = true;
    return net.int(@intCast(id));
}

/// `__kktls_identity(chainPem, keyPem): Long`: a server identity for
/// `__kktls_server`, or 0 with `__kktls_last_error` saying why.
fn nIdentity(ctx: *CallCtx) Allocator.Error!EvalResult {
    const chain_pem = (try argString(ctx, 0)) orelse return net.typeErr("__kktls_identity: the certificate chain is null");
    defer gpa.free(chain_pem);
    const key_pem = (try argString(ctx, 1)) orelse return net.typeErr("__kktls_identity: the private key is null");
    defer {
        std.crypto.secureZero(u8, key_pem);
        gpa.free(key_pem);
    }
    const chain = ktor_tls.pem.certificates(gpa, chain_pem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setLastError("the certificate chain is not valid PEM", .{});
            return net.int(0);
        },
    };
    var keep = false;
    defer if (!keep) {
        for (chain) |c| gpa.free(c);
        gpa.free(chain);
    };
    if (chain.len == 0) {
        setLastError("the certificate chain holds no certificate", .{});
        return net.int(0);
    }
    const leaf = ktor_tls.x509.parse(chain[0]) orelse {
        setLastError("the first certificate of the chain cannot be parsed", .{});
        return net.int(0);
    };
    const key = ktor_tls.pem.privateKey(gpa, key_pem) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EncryptedPrivateKey => setLastError("encrypted private keys are not supported; decrypt it first", .{}),
            error.UnsupportedPrivateKey => setLastError("the private key must be a P-256 ECDSA or Ed25519 key", .{}),
            error.MissingPrivateKey => setLastError("no private key found in the key PEM", .{}),
            else => setLastError("the private key is not valid", .{}),
        }
        return net.int(0);
    };
    if (!ktor_tls.pem.keyMatches(&key, &leaf)) {
        setLastError("the private key does not match the certificate", .{});
        return net.int(0);
    }
    const id = try gpa.create(Identity);
    id.* = .{ .chain = chain, .identity = .{ .chain = chain, .key = key } };
    table.mutex.lock();
    defer table.mutex.unlock();
    const handle = table.next;
    table.next += 1;
    table.identities.put(gpa, handle, id) catch |err| {
        gpa.destroy(id);
        return err;
    };
    keep = true;
    return net.int(@intCast(handle));
}

fn nIdentityFree(ctx: *CallCtx) Allocator.Error!EvalResult {
    const handle = net.argInt(ctx, 0);
    if (handle <= 0) return .{ .ok = .Unit };
    const id = blk: {
        table.mutex.lock();
        defer table.mutex.unlock();
        const kv = table.identities.fetchRemove(@intCast(handle)) orelse return .{ .ok = .Unit };
        break :blk kv.value;
    };
    id.release();
    return .{ .ok = .Unit };
}

/// `__kktls_server(identity): Long`: a server session awaiting a ClientHello.
fn nServer(ctx: *CallCtx) Allocator.Error!EvalResult {
    const handle = net.argInt(ctx, 0);
    const id = blk: {
        table.mutex.lock();
        defer table.mutex.unlock();
        const found = table.identities.get(@intCast(@max(handle, 0))) orelse {
            setLastError("unknown server identity", .{});
            return net.int(0);
        };
        _ = found.refs.fetchAdd(1, .acq_rel);
        break :blk found;
    };
    const e = gpa.create(Entry) catch |err| {
        id.release();
        return err;
    };
    e.* = .{ .identity = id };
    e.server_config = .{ .identity = &id.identity };
    e.session = Session.initServer(gpa, &e.server_config, osSeed());
    const sid = putSession(e) catch |err| {
        e.destroy();
        return err;
    };
    return net.int(@intCast(sid));
}

/// `__kktls_feed(h, bytes, off, len): Int`: 0, or -1 once the session failed.
fn nFeed(ctx: *CallCtx) Allocator.Error!EvalResult {
    const bytes = (try argRange(ctx, 1, net.argInt(ctx, 2), net.argInt(ctx, 3))) orelse
        return net.typeErr("__kktls_feed: the byte range does not fit the array");
    defer gpa.free(bytes);
    const e = lockSession(net.argInt(ctx, 0)) orelse return net.int(-1);
    defer e.mutex.unlock();
    e.session.feed(bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TlsFailure => return net.int(-1),
    };
    return net.int(0);
}

/// `__kktls_take_output(h): ByteArray?`: everything queued for the peer.
fn nTakeOutput(ctx: *CallCtx) Allocator.Error!EvalResult {
    const copy = blk: {
        const e = lockSession(net.argInt(ctx, 0)) orelse break :blk null;
        defer e.mutex.unlock();
        const out = e.session.output();
        if (out.len == 0) break :blk null;
        const c = try gpa.dupe(u8, out);
        e.session.consumeOutput(out.len);
        break :blk c;
    };
    return bytesResult(ctx.allocator, copy);
}

/// `__kktls_read(h, max): ByteArray?`: up to `max` bytes of decrypted data.
fn nRead(ctx: *CallCtx) Allocator.Error!EvalResult {
    const max: usize = @intCast(@max(net.argInt(ctx, 1), 0));
    const copy = blk: {
        const e = lockSession(net.argInt(ctx, 0)) orelse break :blk null;
        defer e.mutex.unlock();
        const data = e.session.appData();
        const n = @min(data.len, max);
        if (n == 0) break :blk null;
        const c = try gpa.dupe(u8, data[0..n]);
        std.crypto.secureZero(u8, @constCast(data[0..n]));
        e.session.consumeApp(n);
        break :blk c;
    };
    return bytesResult(ctx.allocator, copy);
}

/// `__kktls_write(h, bytes, off, len): Int`: 0, or -1 when the session
/// cannot send application data.
fn nWrite(ctx: *CallCtx) Allocator.Error!EvalResult {
    const bytes = (try argRange(ctx, 1, net.argInt(ctx, 2), net.argInt(ctx, 3))) orelse
        return net.typeErr("__kktls_write: the byte range does not fit the array");
    defer gpa.free(bytes);
    const e = lockSession(net.argInt(ctx, 0)) orelse return net.int(-1);
    defer e.mutex.unlock();
    e.session.writeApp(bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TlsFailure => return net.int(-1),
    };
    return net.int(0);
}

/// `__kktls_close(h)`: queues close_notify.
fn nClose(ctx: *CallCtx) Allocator.Error!EvalResult {
    const e = lockSession(net.argInt(ctx, 0)) orelse return .{ .ok = .Unit };
    defer e.mutex.unlock();
    try e.session.close();
    return .{ .ok = .Unit };
}

pub const state_handshake_done = 1;
pub const state_failed = 2;
pub const state_peer_closed = 4;
pub const state_failed_locally = 8;

/// `__kktls_state(h): Int`: the state bits above, with the failure's alert
/// description in bits 16..23.
fn nState(ctx: *CallCtx) Allocator.Error!EvalResult {
    const e = lockSession(net.argInt(ctx, 0)) orelse return net.int(state_failed);
    defer e.mutex.unlock();
    const s = &e.session;
    var bits: i64 = 0;
    if (s.handshakeDone()) bits |= state_handshake_done;
    if (s.peerClosed()) bits |= state_peer_closed;
    if (s.failure()) |f| {
        bits |= state_failed;
        if (f.local) bits |= state_failed_locally;
        bits |= @as(i64, @intFromEnum(f.alert)) << 16;
    }
    return net.int(bits);
}

/// `__kktls_error(h): String?`: why the session failed.
fn nError(ctx: *CallCtx) Allocator.Error!EvalResult {
    var buf: [256]u8 = undefined;
    const msg = blk: {
        const e = lockSession(net.argInt(ctx, 0)) orelse break :blk std.fmt.bufPrint(&buf, "the TLS session is closed", .{}) catch unreachable;
        defer e.mutex.unlock();
        const f = e.session.failure() orelse return .{ .ok = .Null };
        break :blk if (f.local)
            std.fmt.bufPrint(&buf, "{s} (sent alert {s})", .{ f.reason, alertName(f.alert) }) catch buf[0..]
        else
            std.fmt.bufPrint(&buf, "the peer sent alert {s}", .{alertName(f.alert)}) catch buf[0..];
    };
    return stringResult(ctx.allocator, msg);
}

fn alertName(a: ktor_tls.AlertDescription) []const u8 {
    return std.enums.tagName(ktor_tls.AlertDescription, a) orelse "unknown";
}

/// `__kktls_free(h)`: drops the session. Idempotent.
fn nFree(ctx: *CallCtx) Allocator.Error!EvalResult {
    const handle = net.argInt(ctx, 0);
    if (handle <= 0) return .{ .ok = .Unit };
    const e = blk: {
        table.mutex.lock();
        defer table.mutex.unlock();
        const kv = table.sessions.fetchRemove(@intCast(handle)) orelse return .{ .ok = .Unit };
        break :blk kv.value;
    };
    // Another thread may still be inside a call on this handle.
    e.mutex.lock();
    e.mutex.unlock();
    e.destroy();
    return .{ .ok = .Unit };
}

fn nLastError(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (last_error_len == 0) return .{ .ok = .Null };
    return stringResult(ctx.allocator, last_error_buf[0..last_error_len]);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn call(f: *const fn (*CallCtx) Allocator.Error!EvalResult, args: []const Value) !Value {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx: CallCtx = .{ .args = args, .out = cap.output(), .host = h.host(), .allocator = testing.allocator };
    const r = try f(&ctx);
    return switch (r) {
        .ok => |v| v,
        .err => error.NativeFailed,
    };
}

fn str(s: []const u8) !Value {
    return .{ .String = try runtime.strInit(testing.allocator, s) };
}

fn bytesOf(v: Value) ![]u8 {
    const arr = v.Array;
    const out = try testing.allocator.alloc(u8, arr.len());
    for (out, 0..) |*b, k| b.* = @bitCast(arr.get(k).Byte);
    return out;
}

/// Moves one side's queued bytes to the other through the natives.
fn relay(from: i64, to: i64) !bool {
    const out = try call(nTakeOutput, &.{Value.newInt(from)});
    if (out == .Null) return false;
    defer out.release(testing.allocator);
    const n: i64 = @intCast(out.Array.len());
    _ = try call(nFeed, &.{ Value.newInt(to), out, Value.newInt(0), Value.newInt(n) });
    return true;
}

test "a client and a server handle complete a handshake and exchange data through the natives" {
    const fixtures = @import("tls_fixtures");
    const chain = try str(fixtures.server_p256);
    defer chain.release(testing.allocator);
    const key = try str(fixtures.server_p256_key);
    defer key.release(testing.allocator);
    const ident = (try call(nIdentity, &.{ chain, key })).asI64().?;
    try testing.expect(ident > 0);
    defer _ = call(nIdentityFree, &.{Value.newInt(ident)}) catch {};

    const host = try str("localhost");
    defer host.release(testing.allocator);
    const ca = try str(fixtures.ca);
    defer ca.release(testing.allocator);
    const c = (try call(nClient, &.{ host, ca, .{ .Bool = false }, .{ .Bool = false } })).asI64().?;
    try testing.expect(c > 0);
    defer _ = call(nFree, &.{Value.newInt(c)}) catch {};
    const s = (try call(nServer, &.{Value.newInt(ident)})).asI64().?;
    try testing.expect(s > 0);
    defer _ = call(nFree, &.{Value.newInt(s)}) catch {};

    while (try relay(c, s) or try relay(s, c)) {}
    try testing.expect((try call(nState, &.{Value.newInt(c)})).asI64().? & state_handshake_done != 0);
    try testing.expect((try call(nState, &.{Value.newInt(s)})).asI64().? & state_handshake_done != 0);

    const msg = try net.newByteArray(testing.allocator, "over TLS");
    defer msg.release(testing.allocator);
    try testing.expectEqual(@as(i64, 0), (try call(nWrite, &.{ Value.newInt(c), msg, Value.newInt(0), Value.newInt(8) })).asI64().?);
    _ = try relay(c, s);
    const got = try call(nRead, &.{ Value.newInt(s), Value.newInt(4) });
    defer got.release(testing.allocator);
    const got_bytes = try bytesOf(got);
    defer testing.allocator.free(got_bytes);
    try testing.expectEqualStrings("over", got_bytes);
    const rest = try call(nRead, &.{ Value.newInt(s), Value.newInt(100) });
    defer rest.release(testing.allocator);
    const rest_bytes = try bytesOf(rest);
    defer testing.allocator.free(rest_bytes);
    try testing.expectEqualStrings(" TLS", rest_bytes);
    try testing.expect((try call(nRead, &.{ Value.newInt(s), Value.newInt(100) })) == .Null);
}

test "an untrusted server fails the client with a message" {
    const fixtures = @import("tls_fixtures");
    const chain = try str(fixtures.untrusted);
    defer chain.release(testing.allocator);
    const key = try str(fixtures.untrusted_key);
    defer key.release(testing.allocator);
    const ident = (try call(nIdentity, &.{ chain, key })).asI64().?;
    defer _ = call(nIdentityFree, &.{Value.newInt(ident)}) catch {};
    const host = try str("localhost");
    defer host.release(testing.allocator);
    const ca = try str(fixtures.ca);
    defer ca.release(testing.allocator);
    const c = (try call(nClient, &.{ host, ca, .{ .Bool = false }, .{ .Bool = false } })).asI64().?;
    defer _ = call(nFree, &.{Value.newInt(c)}) catch {};
    const s = (try call(nServer, &.{Value.newInt(ident)})).asI64().?;
    defer _ = call(nFree, &.{Value.newInt(s)}) catch {};
    while (try relay(c, s) or try relay(s, c)) {}
    const bits = (try call(nState, &.{Value.newInt(c)})).asI64().?;
    try testing.expect(bits & state_failed != 0 and bits & state_failed_locally != 0);
    try testing.expectEqual(@as(i64, @intFromEnum(ktor_tls.AlertDescription.unknown_ca)), bits >> 16);
    const msg = try call(nError, &.{Value.newInt(c)});
    defer msg.release(testing.allocator);
    const g = msg.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("the server certificate is not issued by a trusted authority (sent alert unknown_ca)", g.get().bytes);
}

test "identities refuse a key that does not match or is unsupported" {
    const fixtures = @import("tls_fixtures");
    const chain = try str(fixtures.server_p256);
    defer chain.release(testing.allocator);
    const other = try str(fixtures.untrusted_key);
    defer other.release(testing.allocator);
    try testing.expectEqual(@as(i64, 0), (try call(nIdentity, &.{ chain, other })).asI64().?);
    const msg = try call(nLastError, &.{});
    defer msg.release(testing.allocator);
    const g = msg.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("the private key does not match the certificate", g.get().bytes);
    const rsa = try str("-----BEGIN RSA PRIVATE KEY-----\nAA==\n-----END RSA PRIVATE KEY-----");
    defer rsa.release(testing.allocator);
    try testing.expectEqual(@as(i64, 0), (try call(nIdentity, &.{ chain, rsa })).asI64().?);
}

test "a client without a server name cannot verify, and unknown handles are refused" {
    const ca = try str(@import("tls_fixtures").ca);
    defer ca.release(testing.allocator);
    try testing.expectEqual(@as(i64, 0), (try call(nClient, &.{ .Null, ca, .{ .Bool = false }, .{ .Bool = false } })).asI64().?);
    const empty = try net.newByteArray(testing.allocator, "");
    defer empty.release(testing.allocator);
    try testing.expectEqual(@as(i64, -1), (try call(nFeed, &.{ Value.newInt(987654), empty, Value.newInt(0), Value.newInt(0) })).asI64().?);
    try testing.expect((try call(nTakeOutput, &.{Value.newInt(987654)})) == .Null);
    _ = try call(nFree, &.{Value.newInt(987654)});
}
