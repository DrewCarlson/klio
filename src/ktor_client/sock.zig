//! The platform layer under the socket natives: BSD sockets on POSIX systems
//! and Winsock on Windows, behind one set of calls with POSIX meaning.
//!
//! A descriptor is an `i32` on every platform, as the Kotlin actuals hold it.
//! On Windows it is the `SOCKET` handle; handles fit in 32 bits (the system
//! keeps them there so 32- and 64-bit processes can share them), and a
//! handle that did not would be refused rather than truncated.
//!
//! A failing call returns -1 and records an errno value in a per-thread slot
//! (`lastErrno`). On Windows that value is the Winsock error translated to
//! the C runtime's errno constant (`winsock.errnoOf`), so the actuals compare
//! against the same names everywhere. Where the platforms differ in meaning,
//! Windows is brought to the POSIX behaviour:
//! - a non-blocking `connect` in progress reads EINPROGRESS;
//! - a datagram socket does not report an earlier datagram's ICMP
//!   port-unreachable on a later receive, and a datagram longer than the
//!   buffer is truncated to it;
//! - `SO_REUSEADDR`'s POSIX meaning (rebinding a port whose old connections
//!   are in TIME_WAIT) is Windows' default, so the option is not set there:
//!   Windows' own `SO_REUSEADDR` would let another socket take over a port in
//!   use. `SO_REUSEPORT` has no Windows counterpart; turning it on fails with
//!   ENOPROTOOPT.
//! - the selector's wakeup is a connected loopback socket pair instead of a
//!   pipe, since only sockets can be polled.
//! - there is no SIGPIPE to ignore; a send on a closed connection fails.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
pub const winsock = @import("winsock.zig");

pub const is_windows = builtin.os.tag == .windows;

const c = std.c;
const posix = std.posix;
const ws = winsock;

pub const Fd = i32;

/// Family codes of the klio address encoding and of `socket`.
pub const family_inet: u8 = 4;
pub const family_inet6: u8 = 6;
pub const family_unix: u8 = 1;

/// Readiness bits as the actuals use them.
pub const poll_in: i32 = 1;
pub const poll_out: i32 = 2;
pub const poll_err: i32 = 4;
pub const poll_hup: i32 = 8;
pub const poll_nval: i32 = 16;

// ---- errors ---------------------------------------------------------------------

threadlocal var last_errno: i32 = 0;

pub fn lastErrno() i32 {
    return last_errno;
}

pub fn setLastErrno(v: i32) void {
    last_errno = v;
}

/// Records `e` and returns -1.
pub fn fail(e: c.E) i32 {
    last_errno = @intFromEnum(e);
    return -1;
}

/// Records the error of the call that just failed and returns -1.
fn failed() i32 {
    last_errno = if (is_windows) ws.errnoOf(ws.WSAGetLastError()) else @intCast(c._errno().*);
    return -1;
}

fn interrupted() bool {
    return !is_windows and c._errno().* == @intFromEnum(c.E.INTR);
}

/// The platform value of the errno constant `name` (`"EAGAIN"`), or -1.
pub fn errnoValue(name: []const u8) i32 {
    if (name.len < 2 or name[0] != 'E') return -1;
    const e = std.meta.stringToEnum(c.E, name[1..]) orelse return -1;
    return @intFromEnum(e);
}

extern "c" fn strerror(errnum: c_int) ?[*:0]const u8;
extern "c" fn gai_strerror(errcode: c_int) ?[*:0]const u8;

/// The message for an errno value; a negative value is a resolver error as
/// `resolve` records it.
pub fn message(e: i32, buf: *[256]u8) []const u8 {
    if (is_windows) {
        // Every value recorded here is a mapped errno value or a Winsock
        // code; the system describes the latter and resolver errors.
        if (ws.message(e)) |m| return m;
        const code: i64 = if (e < 0) -@as(i64, e) else e;
        if (code >= 10000 and code <= std.math.maxInt(u32)) {
            var text: [256]u8 = undefined;
            if (ws.systemMessage(@intCast(code), &text)) |m| {
                @memcpy(buf[0..m.len], m);
                return buf[0..m.len];
            }
        }
        return std.fmt.bufPrint(buf, "Unknown error {d}", .{e}) catch "Unknown error";
    } else if (e < 0) {
        const code: c_int = if (e == std.math.minInt(i32)) std.math.maxInt(c_int) else -e;
        const p = gai_strerror(code) orelse return "Unknown error";
        return std.mem.span(p);
    }
    const p = strerror(e) orelse return "Unknown error";
    return std.mem.span(p);
}

// ---- Winsock startup and handles ---------------------------------------------------

var wsa_lock: sync.Lock = .{};
var wsa_started = std.atomic.Value(bool).init(false);

/// Starts Winsock once per process. False with the error recorded when it
/// cannot start.
fn ensureStarted() bool {
    if (!is_windows) return true;
    if (wsa_started.load(.acquire)) return true;
    wsa_lock.lock();
    defer wsa_lock.unlock();
    if (wsa_started.load(.acquire)) return true;
    var data: ws.WSADATA = undefined;
    const rc = ws.WSAStartup(0x0202, &data);
    if (rc != 0) {
        last_errno = ws.errnoOf(rc);
        return false;
    }
    wsa_started.store(true, .release);
    return true;
}

fn handle(fd: Fd) ws.SOCKET {
    return @bitCast(@as(isize, fd));
}

/// The descriptor for a new socket, or -1 when its handle does not fit.
fn adopt(s: ws.SOCKET) Fd {
    if (s == ws.INVALID_SOCKET) return failed();
    const v: isize = @bitCast(s);
    if (v < 0 or v > std.math.maxInt(i32)) {
        _ = ws.closesocket(s);
        return fail(.MFILE);
    }
    _ = ws.SetHandleInformation(@ptrFromInt(s), ws.HANDLE_FLAG_INHERIT, 0);
    return @intCast(v);
}

fn wsResult(rc: i32) i32 {
    return if (rc == ws.SOCKET_ERROR) failed() else rc;
}

// ---- addresses ------------------------------------------------------------------

pub const sockaddr = if (is_windows) ws.sockaddr else c.sockaddr;
const AF_INET: u32 = if (is_windows) ws.AF_INET else posix.AF.INET;
const AF_INET6: u32 = if (is_windows) ws.AF_INET6 else posix.AF.INET6;
const AF_UNIX: u32 = if (is_windows) ws.AF_UNIX else posix.AF.UNIX;
const AF_UNSPEC: u32 = if (is_windows) ws.AF_UNSPEC else posix.AF.UNSPEC;

pub const SockAddr = struct {
    storage: sockaddr.storage = undefined,
    len: u32 = 0,

    pub fn ptr(self: *const SockAddr) *const sockaddr {
        return @ptrCast(&self.storage);
    }

    fn mut(self: *SockAddr) *sockaddr {
        return @ptrCast(&self.storage);
    }
};

fn platformFamily(code: u8) ?u32 {
    return switch (code) {
        family_inet => AF_INET,
        family_inet6 => AF_INET6,
        family_unix => AF_UNIX,
        else => null,
    };
}

/// The platform `sockaddr` for a klio-encoded address:
/// - IPv4: `[4, port_hi, port_lo, a0, a1, a2, a3]`
/// - IPv6: `[6, port_hi, port_lo, addr[16], flowinfo(4, BE), scope_id(4, BE)]`
/// - Unix: `[1, path bytes...]`
pub fn decodeAddr(bytes: []const u8) ?SockAddr {
    if (bytes.len == 0) return null;
    var out: SockAddr = .{};
    @memset(std.mem.asBytes(&out.storage), 0);
    switch (bytes[0]) {
        family_inet => {
            if (bytes.len != 7) return null;
            const sin: *sockaddr.in = @ptrCast(&out.storage);
            sin.* = .{ .port = std.mem.nativeToBig(u16, std.mem.readInt(u16, bytes[1..3], .big)), .addr = @bitCast(bytes[3..7].*) };
            out.len = @sizeOf(sockaddr.in);
        },
        family_inet6 => {
            if (bytes.len != 27) return null;
            const sin6: *sockaddr.in6 = @ptrCast(&out.storage);
            sin6.* = .{
                .port = std.mem.nativeToBig(u16, std.mem.readInt(u16, bytes[1..3], .big)),
                .flowinfo = std.mem.nativeToBig(u32, std.mem.readInt(u32, bytes[19..23], .big)),
                .addr = bytes[3..19].*,
                .scope_id = std.mem.readInt(u32, bytes[23..27], .big),
            };
            out.len = @sizeOf(sockaddr.in6);
        },
        family_unix => {
            const path = bytes[1..];
            const sun: *sockaddr.un = @ptrCast(&out.storage);
            sun.* = .{ .path = undefined };
            @memset(&sun.path, 0);
            if (path.len >= sun.path.len) return null;
            @memcpy(sun.path[0..path.len], path);
            out.len = @intCast(@offsetOf(sockaddr.un, "path") + path.len + 1);
        },
        else => return null,
    }
    return out;
}

/// The klio encoding of a platform `sockaddr`, written into `buf`.
pub fn encodeAddr(sa: *const sockaddr, len: u32, buf: *[128]u8) ?[]const u8 {
    const fam: u32 = sa.family;
    if (fam == AF_INET) {
        if (len < @sizeOf(sockaddr.in)) return null;
        const sin: *const sockaddr.in = @ptrCast(@alignCast(sa));
        buf[0] = family_inet;
        std.mem.writeInt(u16, buf[1..3], std.mem.bigToNative(u16, sin.port), .big);
        buf[3..7].* = @bitCast(sin.addr);
        return buf[0..7];
    }
    if (fam == AF_INET6) {
        if (len < @sizeOf(sockaddr.in6)) return null;
        const sin6: *const sockaddr.in6 = @ptrCast(@alignCast(sa));
        buf[0] = family_inet6;
        std.mem.writeInt(u16, buf[1..3], std.mem.bigToNative(u16, sin6.port), .big);
        buf[3..19].* = sin6.addr;
        std.mem.writeInt(u32, buf[19..23], std.mem.bigToNative(u32, sin6.flowinfo), .big);
        std.mem.writeInt(u32, buf[23..27], sin6.scope_id, .big);
        return buf[0..27];
    }
    if (fam == AF_UNIX) {
        const sun: *const sockaddr.un = @ptrCast(@alignCast(sa));
        const off = @offsetOf(sockaddr.un, "path");
        const avail: usize = if (len > off) @min(len - off, sun.path.len) else 0;
        const path = std.mem.sliceTo(sun.path[0..avail], 0);
        if (path.len + 1 > buf.len) return null;
        buf[0] = family_unix;
        @memcpy(buf[1 .. 1 + path.len], path);
        return buf[0 .. 1 + path.len];
    }
    return null;
}

// ---- sockets --------------------------------------------------------------------

/// A socket of family `family` (4, 6, 1) and type `stype` (1 stream, 2
/// datagram), not inherited by child processes.
pub fn socket(family: u8, stype: i64) Fd {
    const fam = platformFamily(family) orelse return fail(.AFNOSUPPORT);
    const ty: u32 = switch (stype) {
        1 => if (is_windows) ws.SOCK_STREAM else posix.SOCK.STREAM,
        2 => if (is_windows) ws.SOCK_DGRAM else posix.SOCK.DGRAM,
        else => return fail(.INVAL),
    };
    if (is_windows) {
        if (!ensureStarted()) return -1;
        const fd = adopt(ws.WSASocketW(@intCast(fam), @intCast(ty), 0, null, 0, ws.WSA_FLAG_OVERLAPPED | ws.WSA_FLAG_NO_HANDLE_INHERIT));
        if (fd >= 0 and stype == 2) udpNoConnReset(fd);
        return fd;
    }
    const fd = c.socket(fam, ty, 0);
    if (fd < 0) return failed();
    _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    if (comptime builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }
    return fd;
}

extern "ws2_32" fn WSAIoctl(s: ws.SOCKET, code: u32, in: ?*const anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32, returned: *u32, overlapped: ?*anyopaque, routine: ?*anyopaque) callconv(.winapi) i32;

/// Keeps a Windows datagram socket from failing a receive with the ICMP
/// port-unreachable an earlier send provoked, which POSIX does not report on
/// an unconnected socket.
fn udpNoConnReset(fd: Fd) void {
    const SIO_UDP_CONNRESET: u32 = 0x9800000C;
    const off: u32 = 0;
    var returned: u32 = 0;
    _ = WSAIoctl(handle(fd), SIO_UDP_CONNRESET, &off, @sizeOf(u32), null, 0, &returned, null, null);
}

pub fn close(fd: Fd) i32 {
    if (is_windows) return wsResult(ws.closesocket(handle(fd)));
    const rc = c.close(fd);
    return if (rc < 0) failed() else rc;
}

/// `how`: 0 receive, 1 send, anything else both.
pub fn shutdown(fd: Fd, how: i64) i32 {
    if (is_windows) {
        const h: i32 = switch (how) {
            0 => ws.SD_RECEIVE,
            1 => ws.SD_SEND,
            else => ws.SD_BOTH,
        };
        return wsResult(ws.shutdown(handle(fd), h));
    }
    const h: c_int = switch (how) {
        0 => posix.SHUT.RD,
        1 => posix.SHUT.WR,
        else => posix.SHUT.RDWR,
    };
    const rc = c.shutdown(fd, h);
    return if (rc < 0) failed() else rc;
}

pub fn setNonblocking(fd: Fd) i32 {
    if (is_windows) {
        var on: u32 = 1;
        return wsResult(ws.ioctlsocket(handle(fd), ws.FIONBIO, &on));
    }
    const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return failed();
    const nb: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    const rc = c.fcntl(fd, posix.F.SETFL, flags | nb);
    return if (rc < 0) failed() else rc;
}

fn setIntOpt(fd: Fd, level: i32, name: i32, value: c_int) i32 {
    if (is_windows) return wsResult(ws.setsockopt(handle(fd), level, name, std.mem.asBytes(&value), @sizeOf(c_int)));
    const rc = c.setsockopt(fd, level, @bitCast(name), &value, @sizeOf(c_int));
    return if (rc < 0) failed() else rc;
}

/// `IP_TOS`: 1 on Linux, 3 on the BSDs, Darwin and Windows.
const ip_tos: i32 = if (builtin.os.tag == .linux) 1 else 3;

/// Option codes: 1 SO_REUSEADDR, 2 SO_REUSEPORT, 3 SO_BROADCAST, 4 SO_RCVBUF,
/// 5 SO_SNDBUF, 6 TCP_NODELAY, 7 SO_KEEPALIVE, 8 SO_LINGER (value: seconds, a
/// negative value turns lingering off), 9 IP_TOS.
pub fn setOption(fd: Fd, code: i64, value: c_int) i32 {
    if (is_windows) return switch (code) {
        1 => 0,
        2 => if (value == 0) 0 else fail(.NOPROTOOPT),
        3 => setIntOpt(fd, ws.SOL_SOCKET, ws.SO_BROADCAST, value),
        4 => setIntOpt(fd, ws.SOL_SOCKET, ws.SO_RCVBUF, value),
        5 => setIntOpt(fd, ws.SOL_SOCKET, ws.SO_SNDBUF, value),
        6 => setIntOpt(fd, ws.IPPROTO_TCP, ws.TCP_NODELAY, value),
        7 => setIntOpt(fd, ws.SOL_SOCKET, ws.SO_KEEPALIVE, value),
        8 => blk: {
            const l = ws.linger{ .onoff = if (value >= 0) 1 else 0, .linger = @intCast(std.math.clamp(value, 0, std.math.maxInt(u16))) };
            break :blk wsResult(ws.setsockopt(handle(fd), ws.SOL_SOCKET, ws.SO_LINGER, std.mem.asBytes(&l), @sizeOf(ws.linger)));
        },
        9 => setIntOpt(fd, ws.IPPROTO_IP, ip_tos, value),
        else => fail(.NOPROTOOPT),
    };
    return switch (code) {
        1 => setIntOpt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, value),
        2 => setIntOpt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, value),
        3 => setIntOpt(fd, posix.SOL.SOCKET, posix.SO.BROADCAST, value),
        4 => setIntOpt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, value),
        5 => setIntOpt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, value),
        6 => setIntOpt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, value),
        7 => setIntOpt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, value),
        8 => blk: {
            const l = c.linger{ .onoff = if (value >= 0) 1 else 0, .linger = @max(value, 0) };
            const rc = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.LINGER, &l, @sizeOf(c.linger));
            break :blk if (rc < 0) failed() else rc;
        },
        9 => setIntOpt(fd, posix.IPPROTO.IP, ip_tos, value),
        else => fail(.NOPROTOOPT),
    };
}

pub fn connect(fd: Fd, sa: *const SockAddr) i32 {
    if (is_windows) {
        if (ws.connect(handle(fd), sa.ptr(), @intCast(sa.len)) == 0) return 0;
        last_errno = ws.connectErrnoOf(ws.WSAGetLastError());
        return -1;
    }
    while (true) {
        if (c.connect(fd, sa.ptr(), sa.len) == 0) return 0;
        if (interrupted()) continue;
        return failed();
    }
}

pub fn bind(fd: Fd, sa: *const SockAddr) i32 {
    if (is_windows) return wsResult(ws.bind(handle(fd), sa.ptr(), @intCast(sa.len)));
    const rc = c.bind(fd, sa.ptr(), sa.len);
    return if (rc < 0) failed() else rc;
}

pub fn listen(fd: Fd, backlog: i64) i32 {
    const n = std.math.clamp(backlog, 0, std.math.maxInt(i32));
    if (is_windows) return wsResult(ws.listen(handle(fd), @intCast(n)));
    const rc = c.listen(fd, @intCast(n));
    return if (rc < 0) failed() else rc;
}

pub fn accept(fd: Fd) Fd {
    if (is_windows) return adopt(ws.accept(handle(fd), null, null));
    while (true) {
        const nfd = c.accept(fd, null, null);
        if (nfd >= 0) {
            _ = c.fcntl(nfd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
            if (comptime builtin.os.tag.isDarwin()) {
                const one: c_int = 1;
                _ = c.setsockopt(nfd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &one, @sizeOf(c_int));
            }
            return nfd;
        }
        if (interrupted()) continue;
        return failed();
    }
}

/// The pending error on a socket as an errno value, or -1.
pub fn soError(fd: Fd) i32 {
    var v: c_int = 0;
    if (is_windows) {
        var len: i32 = @sizeOf(c_int);
        if (ws.getsockopt(handle(fd), ws.SOL_SOCKET, ws.SO_ERROR, std.mem.asBytes(&v), &len) == ws.SOCKET_ERROR) return failed();
        return ws.errnoOf(v);
    }
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &v, &len) < 0) return failed();
    return v;
}

/// The socket's local (`peer` false) or remote address. False on failure.
pub fn sockName(fd: Fd, peer: bool, out: *SockAddr) bool {
    if (is_windows) {
        var len: i32 = @sizeOf(sockaddr.storage);
        const rc = if (peer) ws.getpeername(handle(fd), out.mut(), &len) else ws.getsockname(handle(fd), out.mut(), &len);
        if (rc == ws.SOCKET_ERROR) {
            _ = failed();
            return false;
        }
        out.len = @intCast(len);
        return true;
    }
    var len: c.socklen_t = @sizeOf(sockaddr.storage);
    const rc = if (peer) c.getpeername(fd, out.mut(), &len) else c.getsockname(fd, out.mut(), &len);
    if (rc < 0) {
        _ = failed();
        return false;
    }
    out.len = len;
    return true;
}

const send_flags: u32 = if (builtin.os.tag == .linux) std.os.linux.MSG.NOSIGNAL else 0;

fn ioLen(n: usize) i32 {
    return @intCast(@min(n, std.math.maxInt(i32)));
}

/// Bytes received, 0 at the end of the stream, or -1.
pub fn recv(fd: Fd, buf: []u8) isize {
    if (is_windows) return wsResult(ws.recv(handle(fd), buf.ptr, ioLen(buf.len), 0));
    while (true) {
        const n = c.recv(fd, buf.ptr, buf.len, 0);
        if (n >= 0) return n;
        if (interrupted()) continue;
        return failed();
    }
}

pub fn send(fd: Fd, buf: []const u8) isize {
    if (is_windows) return wsResult(ws.send(handle(fd), buf.ptr, ioLen(buf.len), 0));
    while (true) {
        const n = c.send(fd, buf.ptr, buf.len, send_flags);
        if (n >= 0) return n;
        if (interrupted()) continue;
        return failed();
    }
}

/// A datagram and its sender. A datagram longer than `buf` is cut to it.
pub fn recvFrom(fd: Fd, buf: []u8, from: *SockAddr) isize {
    if (is_windows) {
        var len: i32 = @sizeOf(sockaddr.storage);
        const n = ws.recvfrom(handle(fd), buf.ptr, ioLen(buf.len), 0, from.mut(), &len);
        if (n == ws.SOCKET_ERROR) {
            // Windows fails a truncated datagram; POSIX delivers what fits.
            if (ws.WSAGetLastError() != ws.WSA.EMSGSIZE) return failed();
            from.len = @intCast(len);
            return ioLen(buf.len);
        }
        from.len = @intCast(len);
        return n;
    }
    while (true) {
        var len: c.socklen_t = @sizeOf(sockaddr.storage);
        const n = c.recvfrom(fd, buf.ptr, buf.len, 0, from.mut(), &len);
        if (n >= 0) {
            from.len = len;
            return n;
        }
        if (interrupted()) continue;
        return failed();
    }
}

pub fn sendTo(fd: Fd, buf: []const u8, to: *const SockAddr) isize {
    if (is_windows) return wsResult(ws.sendto(handle(fd), buf.ptr, ioLen(buf.len), 0, to.ptr(), @intCast(to.len)));
    while (true) {
        const n = c.sendto(fd, buf.ptr, buf.len, send_flags, to.ptr(), to.len);
        if (n >= 0) return n;
        if (interrupted()) continue;
        return failed();
    }
}

/// Whether `fd` names an open descriptor.
pub fn fdValid(fd: Fd) bool {
    if (fd < 0) return false;
    if (is_windows) {
        var ty: c_int = 0;
        var len: i32 = @sizeOf(c_int);
        if (ws.getsockopt(handle(fd), ws.SOL_SOCKET, ws.SO_TYPE, std.mem.asBytes(&ty), &len) == 0) return true;
        return ws.WSAGetLastError() != ws.WSA.ENOTSOCK;
    }
    const rc = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    return rc != -1 or c._errno().* != @intFromEnum(c.E.BADF);
}

pub fn ignoreSigpipe() void {
    if (is_windows) return;
    var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}

// ---- the selector's wakeup ---------------------------------------------------------

/// A non-blocking `[read, write]` pair: a pipe, or on Windows a connected
/// loopback socket pair. Null with the error recorded.
pub fn wakePair() ?[2]Fd {
    if (is_windows) return loopbackPair();
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) < 0) {
        _ = failed();
        return null;
    }
    for (fds) |fd| {
        _ = setNonblocking(fd);
        _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    }
    return .{ fds[0], fds[1] };
}

/// Two connected loopback stream sockets. The accepted end is checked to be
/// the one this call connected, so no other local process can take its place.
fn loopbackPair() ?[2]Fd {
    const lfd = socket(family_inet, 1);
    if (lfd < 0) return null;
    defer _ = close(lfd);
    const loopback = [_]u8{ family_inet, 0, 0, 127, 0, 0, 1 };
    var any = decodeAddr(&loopback).?;
    if (bind(lfd, &any) < 0 or listen(lfd, 1) < 0) return null;
    var bound: SockAddr = .{};
    if (!sockName(lfd, false, &bound)) return null;
    const w = socket(family_inet, 1);
    if (w < 0) return null;
    if (connect(w, &bound) < 0) {
        _ = close(w);
        return null;
    }
    const r = accept(lfd);
    if (r < 0) {
        _ = close(w);
        return null;
    }
    var mine: SockAddr = .{};
    var theirs: SockAddr = .{};
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const same = sockName(w, false, &mine) and sockName(r, true, &theirs) and
        std.mem.eql(u8, encodeAddr(mine.ptr(), mine.len, &a) orelse "", encodeAddr(theirs.ptr(), theirs.len, &b) orelse "-");
    if (!same or setNonblocking(r) < 0 or setNonblocking(w) < 0) {
        if (!same) _ = fail(.CONNABORTED);
        _ = close(r);
        _ = close(w);
        return null;
    }
    _ = setOption(w, 6, 1);
    return .{ r, w };
}

/// Writes one byte: 1, or -1 (a full pipe is EAGAIN).
pub fn wakeSignal(fd: Fd) i64 {
    const b = [1]u8{7};
    if (is_windows) return send(fd, &b);
    while (true) {
        const n = c.write(fd, &b, 1);
        if (n >= 0) return n;
        if (interrupted()) continue;
        return failed();
    }
}

/// Reads everything buffered: the byte count, or -1.
pub fn wakeDrain(fd: Fd) i64 {
    var total: i64 = 0;
    var buf: [1024]u8 = undefined;
    while (true) {
        const n: isize = if (is_windows) recv(fd, &buf) else c.read(fd, &buf, buf.len);
        if (n > 0) {
            total += n;
            continue;
        }
        if (n == 0) return total;
        if (is_windows) {
            if (last_errno == @intFromEnum(c.E.AGAIN)) return total;
            return -1;
        }
        const e = c._errno().*;
        if (e == @intFromEnum(c.E.INTR)) continue;
        if (e == @intFromEnum(c.E.AGAIN)) return total;
        return failed();
    }
}

// ---- readiness ------------------------------------------------------------------

pub const PollFd = if (is_windows) ws.pollfd else c.pollfd;

const POLL_IN: i16 = if (is_windows) ws.POLLIN else posix.POLL.IN;
const POLL_OUT: i16 = if (is_windows) ws.POLLOUT else posix.POLL.OUT;
const POLL_ERR: i16 = if (is_windows) ws.POLLERR else posix.POLL.ERR;
const POLL_HUP: i16 = if (is_windows) ws.POLLHUP else posix.POLL.HUP;
const POLL_NVAL: i16 = if (is_windows) ws.POLLNVAL else posix.POLL.NVAL;

/// The poll entry for `fd` with the actuals' interest bits.
pub fn pollEntry(fd: Fd, events: i32) PollFd {
    var ev: i16 = 0;
    if (events & poll_in != 0) ev |= POLL_IN;
    if (events & poll_out != 0) ev |= POLL_OUT;
    return .{ .fd = if (is_windows) handle(fd) else fd, .events = ev, .revents = 0 };
}

/// An entry's readiness as the actuals' bits.
pub fn pollReady(p: PollFd) i32 {
    var r: i32 = 0;
    if (p.revents & POLL_IN != 0) r |= poll_in;
    if (p.revents & POLL_OUT != 0) r |= poll_out;
    if (p.revents & POLL_ERR != 0) r |= poll_err;
    if (p.revents & POLL_HUP != 0) r |= poll_hup;
    if (p.revents & POLL_NVAL != 0) r |= poll_nval;
    return r;
}

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

/// One wait of up to `ms` milliseconds: the ready count, 0 on timeout, -1
/// with the error recorded, or null when a signal interrupted it.
pub fn pollOnce(pfds: []PollFd, ms: i32) ?i32 {
    if (is_windows) {
        if (pfds.len == 0) {
            Sleep(@intCast(@max(ms, 0)));
            return 0;
        }
        const rc = ws.WSAPoll(pfds.ptr, @intCast(pfds.len), ms);
        if (rc != ws.SOCKET_ERROR) return rc;
        if (ws.WSAGetLastError() != ws.WSA.ENOTSOCK) return failed();
        // A closed socket fails the whole wait; report it on its own entry,
        // as `poll` does.
        var n: i32 = 0;
        for (pfds) |*p| {
            const v: isize = @bitCast(p.fd);
            p.revents = 0;
            if (!fdValid(@intCast(std.math.clamp(v, -1, std.math.maxInt(i32))))) {
                p.revents = POLL_NVAL;
                n += 1;
            }
        }
        return if (n > 0) n else failed();
    }
    const rc = c.poll(pfds.ptr, @intCast(pfds.len), ms);
    if (rc >= 0) return rc;
    if (interrupted()) return null;
    return failed();
}

// ---- names ----------------------------------------------------------------------

/// Stream-socket addresses for `host` and `port`, appended to `out`. False
/// with the resolver's error recorded negated (below every errno value).
pub fn resolve(a: std.mem.Allocator, host: [:0]const u8, port: u16, out: *std.ArrayList(SockAddr)) std.mem.Allocator.Error!bool {
    var port_buf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch unreachable;
    if (is_windows) {
        if (!ensureStarted()) return false;
        var hints: ws.addrinfo = std.mem.zeroes(ws.addrinfo);
        hints.family = ws.AF_UNSPEC;
        hints.socktype = ws.SOCK_STREAM;
        hints.flags = ws.AI_PASSIVE | ws.AI_NUMERICSERV;
        var res: ?*ws.addrinfo = null;
        const rc = ws.getaddrinfo(host.ptr, port_z.ptr, &hints, &res);
        if (rc != 0) {
            last_errno = -rc;
            return false;
        }
        defer if (res) |r| ws.freeaddrinfo(r);
        var cur = res;
        while (cur) |ai| : (cur = ai.next) try appendAddr(a, out, ai.addr, @intCast(ai.addrlen));
        return true;
    }
    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.family = AF_UNSPEC;
    hints.socktype = posix.SOCK.STREAM;
    hints.flags = .{ .PASSIVE = true, .NUMERICSERV = true };
    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host.ptr, port_z.ptr, &hints, &res);
    if (@intFromEnum(rc) != 0) {
        last_errno = -@as(i32, @intCast(@intFromEnum(rc)));
        return false;
    }
    defer if (res) |r| c.freeaddrinfo(r);
    var cur = res;
    while (cur) |ai| : (cur = ai.next) try appendAddr(a, out, ai.addr, ai.addrlen);
    return true;
}

fn appendAddr(a: std.mem.Allocator, out: *std.ArrayList(SockAddr), sa: ?*sockaddr, len: u32) std.mem.Allocator.Error!void {
    const src = sa orelse return;
    if (len > @sizeOf(sockaddr.storage)) return;
    var s: SockAddr = .{ .len = len };
    @memcpy(std.mem.asBytes(&s.storage)[0..len], @as([*]const u8, @ptrCast(src))[0..len]);
    try out.append(a, s);
}

extern "c" fn inet_ntop(af: c_int, src: *const anyopaque, dst: [*]u8, size: c.socklen_t) ?[*:0]const u8;

/// The text of a raw IPv4 (4 bytes) or IPv6 (16 bytes) address, as the
/// system's `inet_ntop` writes it.
pub fn ntop(bytes: []const u8, out: *[64]u8) ?[]const u8 {
    const af: u32 = switch (bytes.len) {
        4 => AF_INET,
        16 => AF_INET6,
        else => return null,
    };
    if (is_windows) {
        if (!ensureStarted()) return null;
        const p = ws.inet_ntop(@intCast(af), bytes.ptr, out, out.len) orelse return null;
        return std.mem.span(p);
    }
    const p = inet_ntop(@intCast(af), bytes.ptr, out, out.len) orelse return null;
    return std.mem.span(p);
}

// ---- tests ----------------------------------------------------------------------

const testing = std.testing;

fn waitReady(fd: Fd, events: i32) !i32 {
    var p = [_]PollFd{pollEntry(fd, events)};
    var left: i32 = 50;
    while (left > 0) : (left -= 1) {
        const n = pollOnce(&p, 100) orelse continue;
        if (n != 0) return pollReady(p[0]);
    }
    return error.Timeout;
}

fn loopbackListener(out: *SockAddr) !Fd {
    const lfd = socket(family_inet, 1);
    try testing.expect(lfd >= 0);
    var any = decodeAddr(&.{ family_inet, 0, 0, 127, 0, 0, 1 }).?;
    try testing.expectEqual(@as(i32, 0), bind(lfd, &any));
    try testing.expectEqual(@as(i32, 0), listen(lfd, 8));
    try testing.expect(sockName(lfd, false, out));
    return lfd;
}

test "a stream connects, would block when empty, carries bytes and ends" {
    var bound: SockAddr = .{};
    const lfd = try loopbackListener(&bound);
    defer _ = close(lfd);
    const cfd = socket(family_inet, 1);
    try testing.expect(cfd >= 0);
    defer _ = close(cfd);
    try testing.expectEqual(@as(i32, 0), connect(cfd, &bound));
    const sfd = accept(lfd);
    try testing.expect(sfd >= 0);
    defer _ = close(sfd);
    try testing.expect(setNonblocking(sfd) >= 0);

    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(isize, -1), recv(sfd, &buf));
    try testing.expectEqual(errnoValue("EAGAIN"), lastErrno());

    try testing.expectEqual(@as(isize, 5), send(cfd, "hello"));
    try testing.expect(try waitReady(sfd, poll_in) & poll_in != 0);
    try testing.expectEqual(@as(isize, 5), recv(sfd, &buf));
    try testing.expectEqualStrings("hello", buf[0..5]);

    var peer: SockAddr = .{};
    try testing.expect(sockName(sfd, true, &peer));
    var enc: [128]u8 = undefined;
    try testing.expectEqual(family_inet, encodeAddr(peer.ptr(), peer.len, &enc).?[0]);

    try testing.expectEqual(@as(i32, 0), shutdown(cfd, 1));
    _ = try waitReady(sfd, poll_in);
    try testing.expectEqual(@as(isize, 0), recv(sfd, &buf));
    try testing.expectEqual(@as(i32, 0), soError(sfd));
}

test "a non-blocking connect to a closed port is in progress, then refused" {
    var bound: SockAddr = .{};
    const lfd = try loopbackListener(&bound);
    _ = close(lfd);
    const fd = socket(family_inet, 1);
    try testing.expect(fd >= 0);
    defer _ = close(fd);
    try testing.expect(setNonblocking(fd) >= 0);
    if (connect(fd, &bound) == 0) return error.UnexpectedConnect;
    if (lastErrno() == errnoValue("EINPROGRESS")) {
        _ = try waitReady(fd, poll_out);
        try testing.expectEqual(errnoValue("ECONNREFUSED"), soError(fd));
    } else {
        try testing.expectEqual(errnoValue("ECONNREFUSED"), lastErrno());
    }
}

test "the wakeup pair signals, drains, and polls invalid once closed" {
    const pair = wakePair().?;
    try testing.expectEqual(@as(i64, 0), wakeDrain(pair[0]));
    try testing.expectEqual(@as(i64, 1), wakeSignal(pair[1]));
    try testing.expectEqual(@as(i64, 1), wakeSignal(pair[1]));
    try testing.expect(try waitReady(pair[0], poll_in) & poll_in != 0);
    try testing.expectEqual(@as(i64, 2), wakeDrain(pair[0]));
    try testing.expect(fdValid(pair[0]));
    try testing.expectEqual(@as(i32, 0), close(pair[1]));
    try testing.expectEqual(@as(i32, 0), close(pair[0]));
    try testing.expect(!fdValid(-1));
    try testing.expect(try waitReady(pair[0], poll_in) & poll_nval != 0);
}

test "a closed descriptor fails with EBADF or ENOTSOCK" {
    const pair = wakePair().?;
    _ = close(pair[1]);
    _ = close(pair[0]);
    try testing.expectEqual(@as(i32, -1), close(pair[0]));
    const e = lastErrno();
    try testing.expect(e == errnoValue("EBADF") or e == errnoValue("ENOTSOCK"));
}

test "a numeric host resolves without the network" {
    var list: std.ArrayList(SockAddr) = .empty;
    defer list.deinit(testing.allocator);
    try testing.expect(try resolve(testing.allocator, "127.0.0.1", 443, &list));
    try testing.expect(list.items.len >= 1);
    var enc: [128]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ family_inet, 1, 187, 127, 0, 0, 1 }, encodeAddr(list.items[0].ptr(), list.items[0].len, &enc).?);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("127.0.0.1", ntop(&.{ 127, 0, 0, 1 }, &out).?);
}

test "an unknown family, type or option is refused with its errno" {
    try testing.expectEqual(@as(Fd, -1), socket(9, 1));
    try testing.expectEqual(errnoValue("EAFNOSUPPORT"), lastErrno());
    try testing.expectEqual(@as(Fd, -1), socket(family_inet, 3));
    try testing.expectEqual(errnoValue("EINVAL"), lastErrno());
    var buf: [256]u8 = undefined;
    try testing.expect(message(errnoValue("EAFNOSUPPORT"), &buf).len > 0);
}
