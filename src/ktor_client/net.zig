//! Socket natives behind klio's ktor-network actuals.
//!
//! Upstream ktor-network's posix source set reaches the platform through
//! cinterop (`ktor_recv`, `ktor_connect`, pselect over `fd_set`s). klio's
//! actuals keep the same structure and call these natives instead. Each one
//! mirrors a POSIX call: it returns the call's result, and on failure returns
//! -1 and records `errno` in a per-thread slot that `__kknet_errno` reads back,
//! the way the upstream code reads `errno` right after the failing call. The
//! calls themselves go through `sock.zig`, which gives Windows the same
//! meaning over Winsock, so the actuals are the same on every platform.
//!
//! Addresses cross the boundary in a compact klio encoding rather than as a
//! platform `sockaddr` (see `sock.decodeAddr`). Family and socket-type
//! arguments use the same codes (4, 6, 1; 1 = stream, 2 = datagram), mapped
//! to the platform values there.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
pub const sock = @import("sock.zig");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const HostBindings = stdlib.HostBindings;
const Allocator = std.mem.Allocator;

pub const family_inet = sock.family_inet;
pub const family_inet6 = sock.family_inet6;
pub const family_unix = sock.family_unix;
pub const poll_in = sock.poll_in;
pub const poll_out = sock.poll_out;
pub const poll_err = sock.poll_err;
pub const poll_hup = sock.poll_hup;
pub const poll_nval = sock.poll_nval;
pub const SockAddr = sock.SockAddr;
pub const decodeAddr = sock.decodeAddr;
pub const encodeAddr = sock.encodeAddr;
pub const errnoValue = sock.errnoValue;

pub fn register(b: *HostBindings) Allocator.Error!void {
    const P = "io.ktor.network.util.";
    try b.register(P ++ "__kknet_socket", nSocket);
    try b.register(P ++ "__kknet_errno", nErrno);
    try b.register(P ++ "__kknet_errno_value", nErrnoValue);
    try b.register(P ++ "__kknet_strerror", nStrerror);
    try b.register(P ++ "__kknet_close", nClose);
    try b.register(P ++ "__kknet_shutdown", nShutdown);
    try b.register(P ++ "__kknet_nonblocking", nNonblocking);
    try b.register(P ++ "__kknet_setopt", nSetopt);
    try b.register(P ++ "__kknet_connect", nConnect);
    try b.register(P ++ "__kknet_bind", nBind);
    try b.register(P ++ "__kknet_listen", nListen);
    try b.register(P ++ "__kknet_accept", nAccept);
    try b.register(P ++ "__kknet_so_error", nSoError);
    try b.register(P ++ "__kknet_sockname", nSockname);
    try b.register(P ++ "__kknet_peername", nPeername);
    try b.register(P ++ "__kknet_getaddrinfo", nGetaddrinfo);
    try b.register(P ++ "__kknet_recv", nRecv);
    try b.register(P ++ "__kknet_send", nSend);
    try b.register(P ++ "__kknet_recvfrom", nRecvfrom);
    try b.register(P ++ "__kknet_sendto", nSendto);
    try b.register(P ++ "__kknet_pipe", nPipe);
    try b.register(P ++ "__kknet_pipe_signal", nPipeSignal);
    try b.register(P ++ "__kknet_pipe_drain", nPipeDrain);
    try b.register(P ++ "__kknet_poll", nPoll);
    try b.register(P ++ "__kknet_fd_valid", nFdValid);
    try b.register(P ++ "__kknet_ignore_sigpipe", nIgnoreSigpipe);
    try b.register(P ++ "__kknet_ntop", nNtop);
    // ktor-io's `PosixException` reads errno names, messages and the last
    // failure from the same slot.
    const E = "io.ktor.utils.io.errors.";
    try b.register(E ++ "__kkio_errno_value", nErrnoValue);
    try b.register(E ++ "__kkio_strerror", nStrerror);
    try b.register(E ++ "__kkio_last_errno", nErrno);
}

// ---- argument and result helpers ------------------------------------------

pub fn argInt(ctx: *const CallCtx, i: usize) i64 {
    if (i >= ctx.args.len) return 0;
    return ctx.args[i].asI64() orelse 0;
}

pub fn int(v: i64) EvalResult {
    return .{ .ok = Value.newInt(v) };
}

/// A `Long` answer, as a native Kotlin declares `: Long` (a handle) returns it.
pub fn long(v: i64) EvalResult {
    return .{ .ok = Value.newLong(v) };
}

pub fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

/// Runs `f` over the bytes of the ByteArray argument `i` (`mutable` for a
/// write into it). A boxed array is copied through a scratch buffer.
pub fn withBytes(
    ctx: *CallCtx,
    i: usize,
    comptime mutable: bool,
    state: anytype,
    comptime f: fn (@TypeOf(state), []u8) i64,
) Allocator.Error!?i64 {
    if (i >= ctx.args.len or ctx.args[i] != .Array) return null;
    const arr = ctx.args[i].Array;
    switch (arr.storage()) {
        .scalars => |pb| {
            if (mutable) {
                const g = pb.borrowMut();
                defer g.deinit();
                return f(state, g.get().bytes.items);
            } else {
                const g = pb.borrow();
                defer g.deinit();
                return f(state, @constCast(g.get().bytes.items));
            }
        },
        .boxed => {
            const n = arr.len();
            const tmp = try ctx.allocator.alloc(u8, n);
            defer ctx.allocator.free(tmp);
            for (tmp, 0..) |*b, k| b.* = switch (arr.get(k)) {
                .Byte => |x| @bitCast(x),
                else => 0,
            };
            const r = f(state, tmp);
            if (mutable) for (tmp, 0..) |b, k| arr.set(ctx.allocator, k, .{ .Byte = @bitCast(b) });
            return r;
        },
    }
}

fn byteArrayCopy(ctx: *const CallCtx, i: usize, out: []u8) ?[]u8 {
    if (i >= ctx.args.len or ctx.args[i] != .Array) return null;
    const arr = ctx.args[i].Array;
    switch (arr.storage()) {
        .scalars => |pb| {
            const g = pb.borrow();
            defer g.deinit();
            const src = g.get().bytes.items;
            if (src.len > out.len) return null;
            @memcpy(out[0..src.len], src);
            return out[0..src.len];
        },
        .boxed => {
            const n = arr.len();
            if (n > out.len) return null;
            for (out[0..n], 0..) |*b, k| b.* = switch (arr.get(k)) {
                .Byte => |x| @bitCast(x),
                else => 0,
            };
            return out[0..n];
        },
    }
}

pub fn newByteArray(a: Allocator, bytes: []const u8) Allocator.Error!Value {
    return .{ .Array = runtime.ArrayData.scalars(try runtime.PrimBuf.initBytes(a, .Byte, bytes), .Byte) };
}

fn newIntArray(a: Allocator, ints: []const i32) Allocator.Error!Value {
    return .{ .Array = runtime.ArrayData.scalars(try runtime.PrimBuf.initBytes(a, .Int, std.mem.sliceAsBytes(ints)), .Int) };
}

fn fdArg(ctx: *const CallCtx, i: usize) sock.Fd {
    return @intCast(std.math.clamp(argInt(ctx, i), -1, std.math.maxInt(i32)));
}

fn addrArg(ctx: *const CallCtx, i: usize) ?SockAddr {
    var buf: [256]u8 = undefined;
    const bytes = byteArrayCopy(ctx, i, &buf) orelse return null;
    return decodeAddr(bytes);
}

// ---- natives ----------------------------------------------------------------

fn nSocket(ctx: *CallCtx) Allocator.Error!EvalResult {
    const fam: u8 = @intCast(std.math.clamp(argInt(ctx, 0), 0, 255));
    return int(sock.socket(fam, argInt(ctx, 1)));
}

fn nErrno(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return int(sock.lastErrno());
}

fn nErrnoValue(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .String) return typeErr("__kknet_errno_value: name must be a String");
    const g = ctx.args[0].String.borrow();
    defer g.deinit();
    return int(errnoValue(g.get().bytes));
}

/// The message for an errno value; a negative value is a resolver error as
/// `__kknet_getaddrinfo` records it.
fn nStrerror(ctx: *CallCtx) Allocator.Error!EvalResult {
    const e: i32 = @intCast(std.math.clamp(argInt(ctx, 0), std.math.minInt(i32), std.math.maxInt(i32)));
    var buf: [256]u8 = undefined;
    return .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, sock.message(e, &buf)) } };
}

/// The textual form of a raw IPv4 (4 bytes) or IPv6 (16 bytes) address, as
/// `inet_ntop` writes it.
fn nNtop(ctx: *CallCtx) Allocator.Error!EvalResult {
    var raw: [16]u8 = undefined;
    const bytes = byteArrayCopy(ctx, 0, &raw) orelse return typeErr("__kknet_ntop: address must be a ByteArray");
    var out: [64]u8 = undefined;
    const text = sock.ntop(bytes, &out) orelse return .{ .ok = .Null };
    return .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, text) } };
}

fn nClose(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.close(fdArg(ctx, 0)));
}

fn nShutdown(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.shutdown(fdArg(ctx, 0), argInt(ctx, 1)));
}

fn nNonblocking(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.setNonblocking(fdArg(ctx, 0)));
}

/// Option codes: see `sock.setOption`.
fn nSetopt(ctx: *CallCtx) Allocator.Error!EvalResult {
    const value: c_int = @intCast(std.math.clamp(argInt(ctx, 2), std.math.minInt(c_int), std.math.maxInt(c_int)));
    return int(sock.setOption(fdArg(ctx, 0), argInt(ctx, 1), value));
}

fn nConnect(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sa = addrArg(ctx, 1) orelse return int(sock.fail(.INVAL));
    return int(sock.connect(fdArg(ctx, 0), &sa));
}

fn nBind(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sa = addrArg(ctx, 1) orelse return int(sock.fail(.INVAL));
    return int(sock.bind(fdArg(ctx, 0), &sa));
}

fn nListen(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.listen(fdArg(ctx, 0), argInt(ctx, 1)));
}

fn nAccept(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.accept(fdArg(ctx, 0)));
}

fn nSoError(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.soError(fdArg(ctx, 0)));
}

fn nameOf(ctx: *CallCtx, comptime peer: bool) Allocator.Error!EvalResult {
    var sa: SockAddr = .{};
    if (!sock.sockName(fdArg(ctx, 0), peer, &sa)) return .{ .ok = .Null };
    var buf: [128]u8 = undefined;
    const enc = encodeAddr(sa.ptr(), sa.len, &buf) orelse {
        _ = sock.fail(.AFNOSUPPORT);
        return .{ .ok = .Null };
    };
    return .{ .ok = try newByteArray(ctx.allocator, enc) };
}

fn nSockname(ctx: *CallCtx) Allocator.Error!EvalResult {
    return nameOf(ctx, false);
}

fn nPeername(ctx: *CallCtx) Allocator.Error!EvalResult {
    return nameOf(ctx, true);
}

/// `getaddrinfo(host, port)` for stream sockets as a list of encoded
/// addresses, or null with the resolver's error recorded as errno (resolver
/// codes are reported negated, below every errno value).
fn nGetaddrinfo(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len < 1 or ctx.args[0] != .String) return typeErr("__kknet_getaddrinfo: host must be a String");
    const host = blk: {
        const g = ctx.args[0].String.borrow();
        defer g.deinit();
        break :blk try a.dupeZ(u8, g.get().bytes);
    };
    defer a.free(host);
    const port: u16 = @intCast(std.math.clamp(argInt(ctx, 1), 0, 65535));

    var addrs: std.ArrayList(SockAddr) = .empty;
    defer addrs.deinit(a);
    // Name resolution may block on the network, so the thread counts as parked.
    runtime.gc.enterBlockingSafe();
    const ok = sock.resolve(a, host, port, &addrs);
    runtime.gc.exitBlockingSafe();
    if (!(try ok)) return .{ .ok = .Null };

    var items: std.ArrayList(Value) = .empty;
    for (addrs.items) |*sa| {
        var buf: [128]u8 = undefined;
        const enc = encodeAddr(sa.ptr(), sa.len, &buf) orelse continue;
        try items.append(a, try newByteArray(a, enc));
    }
    return .{ .ok = runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, items)) };
}

const IoRange = struct { fd: sock.Fd, off: usize, len: usize };

fn rangeArgs(ctx: *const CallCtx) IoRange {
    return .{
        .fd = fdArg(ctx, 0),
        .off = @intCast(std.math.clamp(argInt(ctx, 2), 0, std.math.maxInt(i32))),
        .len = @intCast(std.math.clamp(argInt(ctx, 3), 0, std.math.maxInt(i32))),
    };
}

fn window(r: IoRange, buf: []u8) ?[]u8 {
    if (r.off > buf.len or r.len > buf.len - r.off) return null;
    return buf[r.off..][0..r.len];
}

fn recvInto(r: IoRange, buf: []u8) i64 {
    return sock.recv(r.fd, window(r, buf) orelse return sock.fail(.INVAL));
}

fn sendFrom(r: IoRange, buf: []u8) i64 {
    return sock.send(r.fd, window(r, buf) orelse return sock.fail(.INVAL));
}

/// `recv(fd, buf[off, off + len))`: the byte count, 0 at end of stream.
fn nRecv(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = (try withBytes(ctx, 1, true, rangeArgs(ctx), recvInto)) orelse return typeErr("__kknet_recv: buffer must be a ByteArray");
    return int(n);
}

fn nSend(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = (try withBytes(ctx, 1, false, rangeArgs(ctx), sendFrom)) orelse return typeErr("__kknet_send: buffer must be a ByteArray");
    return int(n);
}

const RecvFrom = struct { r: IoRange, from: *SockAddr };

fn recvFromInto(s: RecvFrom, buf: []u8) i64 {
    return sock.recvFrom(s.r.fd, window(s.r, buf) orelse return sock.fail(.INVAL), s.from);
}

/// `recvfrom(fd, buf[off, off + len))`: null on failure, otherwise the
/// sender's encoded address with the byte count appended as four big-endian
/// bytes.
fn nRecvfrom(ctx: *CallCtx) Allocator.Error!EvalResult {
    var from: SockAddr = .{};
    const st: RecvFrom = .{ .r = rangeArgs(ctx), .from = &from };
    const n = (try withBytes(ctx, 1, true, st, recvFromInto)) orelse return typeErr("__kknet_recvfrom: buffer must be a ByteArray");
    if (n < 0) return .{ .ok = .Null };
    var buf: [132]u8 = undefined;
    const enc = encodeAddr(from.ptr(), from.len, buf[0..128]) orelse {
        _ = sock.fail(.AFNOSUPPORT);
        return .{ .ok = .Null };
    };
    const total = enc.len + 4;
    std.mem.writeInt(u32, buf[enc.len..][0..4], @intCast(n), .big);
    return .{ .ok = try newByteArray(ctx.allocator, buf[0..total]) };
}

const SendTo = struct { r: IoRange, to: SockAddr };

fn sendToFrom(s: SendTo, buf: []u8) i64 {
    return sock.sendTo(s.r.fd, window(s.r, buf) orelse return sock.fail(.INVAL), &s.to);
}

/// `sendto(fd, buf[off, off + len), addr)`.
fn nSendto(ctx: *CallCtx) Allocator.Error!EvalResult {
    const to = addrArg(ctx, 4) orelse return int(sock.fail(.INVAL));
    const n = (try withBytes(ctx, 1, false, SendTo{ .r = rangeArgs(ctx), .to = to }, sendToFrom)) orelse return typeErr("__kknet_sendto: buffer must be a ByteArray");
    return int(n);
}

/// The selector's non-blocking wakeup pair as `[read, write]`, or null.
fn nPipe(ctx: *CallCtx) Allocator.Error!EvalResult {
    const fds = sock.wakePair() orelse return .{ .ok = .Null };
    return .{ .ok = try newIntArray(ctx.allocator, &fds) };
}

/// Writes one byte to the wakeup pair: 1, or -1 (a full pipe is `EAGAIN`).
fn nPipeSignal(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.wakeSignal(fdArg(ctx, 0)));
}

/// Reads everything buffered in the wakeup pair: the byte count, or -1.
fn nPipeDrain(ctx: *CallCtx) Allocator.Error!EvalResult {
    return int(sock.wakeDrain(fdArg(ctx, 0)));
}

/// The first `out.len` elements of the IntArray argument `i`, or null when it
/// is shorter.
fn intArrayPrefix(ctx: *const CallCtx, i: usize, out: []i32) ?[]i32 {
    if (i >= ctx.args.len or ctx.args[i] != .Array) return null;
    const arr = ctx.args[i].Array;
    if (arr.len() < out.len) return null;
    for (out, 0..) |*x, k| x.* = @intCast(std.math.clamp(arr.get(k).asI64() orelse 0, std.math.minInt(i32), std.math.maxInt(i32)));
    return out;
}

/// Waits up to `timeout_ms` (forever when negative) for the entries,
/// polling the run boundary between slices of a longer wait.
pub fn pollFds(pfds: []sock.PollFd, timeout_ms: i64) i32 {
    const slice_ms: i64 = 100;
    var remaining = timeout_ms;
    while (true) {
        if (runtime.shouldAbandon()) return 0;
        const wait: i64 = if (remaining < 0) slice_ms else @min(remaining, slice_ms);
        runtime.gc.enterBlockingSafe();
        const rc = sock.pollOnce(pfds, @intCast(wait));
        runtime.gc.exitBlockingSafe();
        const n = rc orelse continue;
        if (n != 0) return n;
        if (remaining >= 0) {
            remaining -= wait;
            if (remaining <= 0) return 0;
        }
    }
}

/// Polls in flight across threads, for `KLIO_NET_TRACE`.
var polls_in_flight = std.atomic.Value(i64).init(0);

/// `KLIO_NET_TRACE`: one line as a selector poll starts (`rc` null) and one as
/// it returns, with the thread, the polls then in flight and the descriptors.
fn tracePoll(fds: []const i32, timeout_ms: i64, rc: ?i32) void {
    const tid = std.Thread.getCurrentId();
    if (rc) |r| {
        const n = polls_in_flight.fetchSub(1, .monotonic) - 1;
        std.debug.print("[kknet] poll exit tid={d} in_flight={d} rc={d}\n", .{ tid, n, r });
        return;
    }
    const n = polls_in_flight.fetchAdd(1, .monotonic) + 1;
    std.debug.print("[kknet] poll enter tid={d} in_flight={d} timeout={d} fds={any}\n", .{ tid, n, timeout_ms, fds });
}

/// `poll(fds, events, revents, count, timeoutMs)`: `events` holds `poll_in` /
/// `poll_out` bits per descriptor, `revents` receives the ready bits plus
/// `poll_err`, `poll_hup`, `poll_nval`. A negative timeout waits until an
/// event or the run boundary. Returns the ready count, 0 on timeout, -1.
fn nPoll(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const count: usize = @intCast(std.math.clamp(argInt(ctx, 3), 0, 1 << 20));
    const fds = try a.alloc(i32, count);
    defer a.free(fds);
    const evs = try a.alloc(i32, count);
    defer a.free(evs);
    _ = intArrayPrefix(ctx, 0, fds) orelse return typeErr("__kknet_poll: fds must be an IntArray of at least count");
    _ = intArrayPrefix(ctx, 1, evs) orelse return typeErr("__kknet_poll: events must be an IntArray of at least count");
    const pfds = try a.alloc(sock.PollFd, count);
    defer a.free(pfds);
    for (pfds, fds, evs) |*p, fd, ev| p.* = sock.pollEntry(fd, ev);
    const trace = runtime.envOnce("KLIO_NET_TRACE") != null;
    if (trace) tracePoll(fds, argInt(ctx, 4), null);
    const rc = pollFds(pfds, argInt(ctx, 4));
    if (trace) tracePoll(fds, argInt(ctx, 4), rc);
    if (rc > 0 and ctx.args.len > 2 and ctx.args[2] == .Array) {
        const out = ctx.args[2].Array;
        const n = @min(count, out.len());
        for (pfds[0..n], 0..) |p, k| out.set(a, k, Value.newInt(sock.pollReady(p)));
    }
    return int(rc);
}

fn nFdValid(ctx: *CallCtx) Allocator.Error!EvalResult {
    return .{ .ok = .{ .Bool = sock.fdValid(fdArg(ctx, 0)) } };
}

fn nIgnoreSigpipe(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    sock.ignoreSigpipe();
    return .{ .ok = .Unit };
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test {
    _ = sock;
    _ = sock.winsock;
}

test "address encoding round-trips IPv4, IPv6 and unix addresses" {
    const v4 = [_]u8{ family_inet, 0x1f, 0x90, 127, 0, 0, 1 };
    const sa4 = decodeAddr(&v4).?;
    const sin: *const sock.sockaddr.in = @ptrCast(&sa4.storage);
    try testing.expectEqual(@as(u16, 8080), std.mem.bigToNative(u16, sin.port));
    var buf: [128]u8 = undefined;
    try testing.expectEqualSlices(u8, &v4, encodeAddr(sa4.ptr(), sa4.len, &buf).?);

    var v6: [27]u8 = undefined;
    v6[0] = family_inet6;
    std.mem.writeInt(u16, v6[1..3], 443, .big);
    for (v6[3..19], 0..) |*b, i| b.* = @intCast(i);
    std.mem.writeInt(u32, v6[19..23], 0x12345, .big);
    std.mem.writeInt(u32, v6[23..27], 3, .big);
    const sa6 = decodeAddr(&v6).?;
    try testing.expectEqualSlices(u8, &v6, encodeAddr(sa6.ptr(), sa6.len, &buf).?);

    const un = [_]u8{family_unix} ++ "/tmp/klio.sock".*;
    const sau = decodeAddr(&un).?;
    try testing.expectEqualSlices(u8, &un, encodeAddr(sau.ptr(), sau.len, &buf).?);
}

test "malformed encoded addresses decode to null" {
    try testing.expect(decodeAddr(&.{}) == null);
    try testing.expect(decodeAddr(&.{ family_inet, 0, 80 }) == null);
    try testing.expect(decodeAddr(&.{ family_inet6, 0, 80, 1, 2 }) == null);
    try testing.expect(decodeAddr(&.{ 9, 0, 80, 1, 2, 3, 4 }) == null);
    var long_path: [300]u8 = @splat('a');
    long_path[0] = family_unix;
    try testing.expect(decodeAddr(&long_path) == null);
}

test "errno names map to this platform's values" {
    try testing.expectEqual(@as(i32, @intFromEnum(std.c.E.AGAIN)), errnoValue("EAGAIN"));
    try testing.expectEqual(@as(i32, @intFromEnum(std.c.E.CONNREFUSED)), errnoValue("ECONNREFUSED"));
    try testing.expectEqual(@as(i32, @intFromEnum(std.c.E.BADF)), errnoValue("EBADF"));
    try testing.expectEqual(@as(i32, -1), errnoValue("AGAIN"));
    try testing.expectEqual(@as(i32, -1), errnoValue("ENOTANERRNO"));
    try testing.expectEqual(@as(i32, -1), errnoValue(""));
}

fn callNative(f: *const fn (*CallCtx) Allocator.Error!EvalResult, args: []const Value) !Value {
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

test "a loopback stream connects, accepts and carries bytes both ways" {
    const a = testing.allocator;
    const lfd = (try callNative(nSocket, &.{ Value.newInt(family_inet), Value.newInt(1) })).asI64().?;
    try testing.expect(lfd >= 0);
    defer _ = sock.close(@intCast(lfd));
    const any = try newByteArray(a, &.{ family_inet, 0, 0, 127, 0, 0, 1 });
    defer any.release(a);
    try testing.expectEqual(@as(?i64, 0), (try callNative(nBind, &.{ Value.newInt(lfd), any })).asI64());
    try testing.expectEqual(@as(?i64, 0), (try callNative(nListen, &.{ Value.newInt(lfd), Value.newInt(8) })).asI64());
    const bound = try callNative(nSockname, &.{Value.newInt(lfd)});
    defer bound.release(a);
    try testing.expect(bound == .Array);
    try testing.expectEqual(@as(usize, 7), bound.Array.len());

    const cfd = (try callNative(nSocket, &.{ Value.newInt(family_inet), Value.newInt(1) })).asI64().?;
    defer _ = sock.close(@intCast(cfd));
    try testing.expectEqual(@as(?i64, 0), (try callNative(nConnect, &.{ Value.newInt(cfd), bound })).asI64());
    const sfd = (try callNative(nAccept, &.{Value.newInt(lfd)})).asI64().?;
    try testing.expect(sfd >= 0);
    defer _ = sock.close(@intCast(sfd));
    try testing.expect((try callNative(nNonblocking, &.{Value.newInt(sfd)})).asI64().? >= 0);

    // Nothing sent yet: a non-blocking read would block.
    const empty = try newByteArray(a, &([_]u8{0} ** 16));
    defer empty.release(a);
    try testing.expectEqual(@as(?i64, -1), (try callNative(nRecv, &.{ Value.newInt(sfd), empty, Value.newInt(0), Value.newInt(16) })).asI64());
    try testing.expectEqual(@as(?i64, errnoValue("EAGAIN")), (try callNative(nErrno, &.{})).asI64());

    const msg = try newByteArray(a, "xxhello");
    defer msg.release(a);
    try testing.expectEqual(@as(?i64, 5), (try callNative(nSend, &.{ Value.newInt(cfd), msg, Value.newInt(2), Value.newInt(5) })).asI64());

    const fds = try newIntArray(a, &.{@intCast(sfd)});
    defer fds.release(a);
    const evs = try newIntArray(a, &.{poll_in});
    defer evs.release(a);
    const rev = try newIntArray(a, &.{0});
    defer rev.release(a);
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPoll, &.{ fds, evs, rev, Value.newInt(1), Value.newInt(5000) })).asI64());
    try testing.expect(rev.Array.get(0).asI64().? & poll_in != 0);

    try testing.expectEqual(@as(?i64, 5), (try callNative(nRecv, &.{ Value.newInt(sfd), empty, Value.newInt(3), Value.newInt(13) })).asI64());
    try testing.expectEqual(@as(i8, 'h'), empty.Array.get(3).Byte);
    try testing.expectEqual(@as(i8, 'o'), empty.Array.get(7).Byte);

    // An out-of-range window is refused before the call.
    try testing.expectEqual(@as(?i64, -1), (try callNative(nRecv, &.{ Value.newInt(sfd), empty, Value.newInt(10), Value.newInt(7) })).asI64());
    try testing.expectEqual(@as(?i64, errnoValue("EINVAL")), (try callNative(nErrno, &.{})).asI64());

    // Shutting the writer down reads as end of stream.
    try testing.expectEqual(@as(?i64, 0), (try callNative(nShutdown, &.{ Value.newInt(cfd), Value.newInt(1) })).asI64());
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPoll, &.{ fds, evs, rev, Value.newInt(1), Value.newInt(5000) })).asI64());
    try testing.expectEqual(@as(?i64, 0), (try callNative(nRecv, &.{ Value.newInt(sfd), empty, Value.newInt(0), Value.newInt(16) })).asI64());
}

test "a refused connection reports ECONNREFUSED through SO_ERROR" {
    const a = testing.allocator;
    // Bind and close a listener to find a port nothing listens on.
    const lfd = sock.socket(family_inet, 1);
    try testing.expect(lfd >= 0);
    var any = decodeAddr(&.{ family_inet, 0, 0, 127, 0, 0, 1 }).?;
    try testing.expectEqual(@as(i32, 0), sock.bind(lfd, &any));
    var bound: SockAddr = .{};
    try testing.expect(sock.sockName(lfd, false, &bound));
    _ = sock.close(lfd);
    var enc_buf: [128]u8 = undefined;
    const addr = try newByteArray(a, encodeAddr(bound.ptr(), bound.len, &enc_buf).?);
    defer addr.release(a);

    const fd = (try callNative(nSocket, &.{ Value.newInt(family_inet), Value.newInt(1) })).asI64().?;
    defer _ = sock.close(@intCast(fd));
    _ = try callNative(nNonblocking, &.{Value.newInt(fd)});
    const rc = (try callNative(nConnect, &.{ Value.newInt(fd), addr })).asI64().?;
    if (rc == -1) {
        const e = (try callNative(nErrno, &.{})).asI64().?;
        if (e == errnoValue("EINPROGRESS")) {
            var p = [_]sock.PollFd{sock.pollEntry(@intCast(fd), poll_out)};
            _ = pollFds(&p, 5000);
            try testing.expectEqual(@as(?i64, errnoValue("ECONNREFUSED")), (try callNative(nSoError, &.{Value.newInt(fd)})).asI64());
        } else {
            try testing.expectEqual(@as(i64, errnoValue("ECONNREFUSED")), e);
        }
    } else return error.UnexpectedConnect;
}

test "poll reads the first count entries of longer arrays and times out" {
    const a = testing.allocator;
    const p = try callNative(nPipe, &.{});
    defer p.release(a);
    const r = p.Array.get(0).asI64().?;
    const w = p.Array.get(1).asI64().?;
    defer _ = sock.close(@intCast(r));
    defer _ = sock.close(@intCast(w));
    // Capacity past `count` is ignored, as the selector's reused arrays need.
    const fds = try newIntArray(a, &.{ @intCast(r), -1, -1, -1 });
    defer fds.release(a);
    const evs = try newIntArray(a, &.{ poll_in, 0, 0, 0 });
    defer evs.release(a);
    const rev = try newIntArray(a, &.{ 0, 0, 0, 0 });
    defer rev.release(a);
    try testing.expectEqual(@as(?i64, 0), (try callNative(nPoll, &.{ fds, evs, rev, Value.newInt(1), Value.newInt(20) })).asI64());
    _ = try callNative(nPipeSignal, &.{Value.newInt(w)});
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPoll, &.{ fds, evs, rev, Value.newInt(1), Value.newInt(-1) })).asI64());
    try testing.expectEqual(@as(?i64, poll_in), rev.Array.get(0).asI64());
    // A count past the arrays' length is refused.
    try testing.expectError(error.NativeFailed, callNative(nPoll, &.{ fds, evs, rev, Value.newInt(5), Value.newInt(0) }));
}

test "a closed descriptor polls as invalid" {
    const a = testing.allocator;
    const pair = sock.wakePair().?;
    _ = sock.close(pair[1]);
    _ = sock.close(pair[0]);
    const fds = try newIntArray(a, &.{pair[0]});
    defer fds.release(a);
    const evs = try newIntArray(a, &.{poll_in});
    defer evs.release(a);
    const rev = try newIntArray(a, &.{0});
    defer rev.release(a);
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPoll, &.{ fds, evs, rev, Value.newInt(1), Value.newInt(1000) })).asI64());
    try testing.expect(rev.Array.get(0).asI64().? & poll_nval != 0);
}

test "ntop prints IPv4 and IPv6 addresses the way inet_ntop does" {
    const a = testing.allocator;
    const v4 = try newByteArray(a, &.{ 10, 0, 0, 42 });
    defer v4.release(a);
    const s4 = try callNative(nNtop, &.{v4});
    defer s4.release(a);
    {
        const g = s4.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("10.0.0.42", g.get().bytes);
    }
    var loop6: [16]u8 = @splat(0);
    loop6[15] = 1;
    const v6 = try newByteArray(a, &loop6);
    defer v6.release(a);
    const s6 = try callNative(nNtop, &.{v6});
    defer s6.release(a);
    {
        const g = s6.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("::1", g.get().bytes);
    }
    const bad = try newByteArray(a, &.{ 1, 2, 3 });
    defer bad.release(a);
    try testing.expect((try callNative(nNtop, &.{bad})) == .Null);
}

test "the wakeup pair signals and drains" {
    const a = testing.allocator;
    const p = try callNative(nPipe, &.{});
    defer p.release(a);
    const r = p.Array.get(0).asI64().?;
    const w = p.Array.get(1).asI64().?;
    defer _ = sock.close(@intCast(r));
    defer _ = sock.close(@intCast(w));
    try testing.expectEqual(@as(?i64, 0), (try callNative(nPipeDrain, &.{Value.newInt(r)})).asI64());
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPipeSignal, &.{Value.newInt(w)})).asI64());
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPipeSignal, &.{Value.newInt(w)})).asI64());
    // Both bytes are readable before the drain counts them.
    const fds = try newIntArray(a, &.{@intCast(r)});
    defer fds.release(a);
    const evs = try newIntArray(a, &.{poll_in});
    defer evs.release(a);
    const rev = try newIntArray(a, &.{0});
    defer rev.release(a);
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPoll, &.{ fds, evs, rev, Value.newInt(1), Value.newInt(5000) })).asI64());
    try testing.expectEqual(@as(?i64, 2), (try callNative(nPipeDrain, &.{Value.newInt(r)})).asI64());
    try testing.expect((try callNative(nFdValid, &.{Value.newInt(r)})).Bool);
    try testing.expect(!(try callNative(nFdValid, &.{Value.newInt(-1)})).Bool);
}

test "getaddrinfo resolves a numeric host without the network" {
    const a = testing.allocator;
    const host = Value{ .String = try runtime.strInit(a, "127.0.0.1") };
    defer host.release(a);
    const list = try callNative(nGetaddrinfo, &.{ host, Value.newInt(8080) });
    defer list.release(a);
    try testing.expect(list == .Array);
    try testing.expect(list.Array.len() >= 1);
    const first = list.Array.get(0);
    try testing.expectEqual(@as(usize, 7), first.Array.len());
    try testing.expectEqual(@as(i8, family_inet), first.Array.get(0).Byte);
    try testing.expectEqual(@as(i8, @bitCast(@as(u8, 0x1f))), first.Array.get(1).Byte);
    try testing.expectEqual(@as(i8, @bitCast(@as(u8, 0x90))), first.Array.get(2).Byte);
}

test "a datagram longer than the buffer is cut to it" {
    const a = testing.allocator;
    const rfd = sock.socket(family_inet, 2);
    try testing.expect(rfd >= 0);
    defer _ = sock.close(rfd);
    var any = decodeAddr(&.{ family_inet, 0, 0, 127, 0, 0, 1 }).?;
    try testing.expectEqual(@as(i32, 0), sock.bind(rfd, &any));
    var bound: SockAddr = .{};
    try testing.expect(sock.sockName(rfd, false, &bound));
    const wfd = sock.socket(family_inet, 2);
    try testing.expect(wfd >= 0);
    defer _ = sock.close(wfd);
    try testing.expectEqual(@as(isize, 10), sock.sendTo(wfd, "0123456789", &bound));
    var p = [_]sock.PollFd{sock.pollEntry(rfd, poll_in)};
    try testing.expectEqual(@as(i32, 1), pollFds(&p, 5000));
    const buf = try newByteArray(a, &([_]u8{0} ** 4));
    defer buf.release(a);
    const got = try callNative(nRecvfrom, &.{ Value.newInt(rfd), buf, Value.newInt(0), Value.newInt(4) });
    defer got.release(a);
    try testing.expect(got == .Array);
    // The sender's 7-byte address, then the count.
    try testing.expectEqual(@as(usize, 11), got.Array.len());
    try testing.expectEqual(@as(i8, 4), got.Array.get(10).Byte);
    try testing.expectEqual(@as(i8, '3'), buf.Array.get(3).Byte);
}

test "the reuse options follow each platform's meaning" {
    const fd = sock.socket(family_inet, 1);
    try testing.expect(fd >= 0);
    defer _ = sock.close(fd);
    try testing.expectEqual(@as(i32, 0), sock.setOption(fd, 1, 1));
    try testing.expectEqual(@as(i32, 0), sock.setOption(fd, 2, 0));
    if (sock.is_windows) {
        try testing.expectEqual(@as(i32, -1), sock.setOption(fd, 2, 1));
        try testing.expectEqual(errnoValue("ENOPROTOOPT"), sock.lastErrno());
    } else {
        try testing.expectEqual(@as(i32, 0), sock.setOption(fd, 2, 1));
    }
    try testing.expectEqual(@as(i32, -1), sock.setOption(fd, 42, 1));
    try testing.expectEqual(errnoValue("ENOPROTOOPT"), sock.lastErrno());
}

test "messages name the errors the actuals report" {
    var buf: [256]u8 = undefined;
    const refused = sock.message(errnoValue("ECONNREFUSED"), &buf);
    try testing.expect(std.ascii.indexOfIgnoreCase(refused, "refused") != null);
    try testing.expect(sock.message(errnoValue("EAGAIN"), &buf).len > 0);
}
