//! Socket natives behind klio's ktor-network actuals.
//!
//! Upstream ktor-network's posix source set reaches the platform through
//! cinterop (`ktor_recv`, `ktor_connect`, pselect over `fd_set`s). klio's
//! actuals keep the same structure and call these natives instead. Each one
//! mirrors a POSIX call: it returns the call's result, and on failure returns
//! -1 and records `errno` in a per-thread slot that `__kknet_errno` reads back,
//! the way the upstream code reads `errno` right after the failing call.
//!
//! Addresses cross the boundary in a compact klio encoding rather than as a
//! platform `sockaddr`:
//! - IPv4: `[4, port_hi, port_lo, a0, a1, a2, a3]`
//! - IPv6: `[6, port_hi, port_lo, addr[16], flowinfo(4, BE), scope_id(4, BE)]`
//! - Unix: `[1, path bytes...]`
//! Family and socket-type arguments use the same codes (4, 6, 1; 1 = stream,
//! 2 = datagram), mapped to the platform values here.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const HostBindings = stdlib.HostBindings;
const Allocator = std.mem.Allocator;
const c = std.c;
const posix = std.posix;

pub const family_inet: u8 = 4;
pub const family_inet6: u8 = 6;
pub const family_unix: u8 = 1;

threadlocal var last_errno: i32 = 0;

/// Records the calling thread's `errno` for `__kknet_errno` and returns -1.
fn failed() i32 {
    last_errno = @intCast(c._errno().*);
    return -1;
}

fn setErrno(e: c.E) i32 {
    last_errno = @intFromEnum(e);
    return -1;
}

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
    var pb = runtime.PrimBuf{ .kind = .Byte };
    try pb.bytes.appendSlice(a, bytes);
    return .{ .Array = runtime.ArrayData.scalars(try runtime.ObjRef(runtime.PrimBuf).initOwned(a, pb), .Byte) };
}

fn newIntArray(a: Allocator, ints: []const i32) Allocator.Error!Value {
    var pb = runtime.PrimBuf{ .kind = .Int };
    try pb.bytes.appendSlice(a, std.mem.sliceAsBytes(ints));
    return .{ .Array = runtime.ArrayData.scalars(try runtime.ObjRef(runtime.PrimBuf).initOwned(a, pb), .Int) };
}

// ---- address encoding -----------------------------------------------------

pub const SockAddr = struct {
    storage: c.sockaddr.storage = undefined,
    len: c.socklen_t = 0,

    fn ptr(self: *const SockAddr) *const c.sockaddr {
        return @ptrCast(&self.storage);
    }
};

fn platformFamily(code: u8) ?u32 {
    return switch (code) {
        family_inet => posix.AF.INET,
        family_inet6 => posix.AF.INET6,
        family_unix => posix.AF.UNIX,
        else => null,
    };
}

/// The platform `sockaddr` for a klio-encoded address.
pub fn decodeAddr(bytes: []const u8) ?SockAddr {
    if (bytes.len == 0) return null;
    var out: SockAddr = .{};
    @memset(std.mem.asBytes(&out.storage), 0);
    switch (bytes[0]) {
        family_inet => {
            if (bytes.len != 7) return null;
            const sin: *c.sockaddr.in = @ptrCast(&out.storage);
            sin.* = .{ .port = std.mem.nativeToBig(u16, std.mem.readInt(u16, bytes[1..3], .big)), .addr = @bitCast(bytes[3..7].*) };
            out.len = @sizeOf(c.sockaddr.in);
        },
        family_inet6 => {
            if (bytes.len != 27) return null;
            const sin6: *c.sockaddr.in6 = @ptrCast(&out.storage);
            sin6.* = .{
                .port = std.mem.nativeToBig(u16, std.mem.readInt(u16, bytes[1..3], .big)),
                .flowinfo = std.mem.nativeToBig(u32, std.mem.readInt(u32, bytes[19..23], .big)),
                .addr = bytes[3..19].*,
                .scope_id = std.mem.readInt(u32, bytes[23..27], .big),
            };
            out.len = @sizeOf(c.sockaddr.in6);
        },
        family_unix => {
            const path = bytes[1..];
            const sun: *c.sockaddr.un = @ptrCast(&out.storage);
            sun.* = .{ .path = undefined };
            @memset(&sun.path, 0);
            if (path.len >= sun.path.len) return null;
            @memcpy(sun.path[0..path.len], path);
            out.len = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
        },
        else => return null,
    }
    return out;
}

/// The klio encoding of a platform `sockaddr`, written into `buf`.
pub fn encodeAddr(sa: *const c.sockaddr, len: c.socklen_t, buf: *[128]u8) ?[]const u8 {
    const fam: u32 = sa.family;
    if (fam == posix.AF.INET) {
        if (len < @sizeOf(c.sockaddr.in)) return null;
        const sin: *const c.sockaddr.in = @ptrCast(@alignCast(sa));
        buf[0] = family_inet;
        std.mem.writeInt(u16, buf[1..3], std.mem.bigToNative(u16, sin.port), .big);
        buf[3..7].* = @bitCast(sin.addr);
        return buf[0..7];
    }
    if (fam == posix.AF.INET6) {
        if (len < @sizeOf(c.sockaddr.in6)) return null;
        const sin6: *const c.sockaddr.in6 = @ptrCast(@alignCast(sa));
        buf[0] = family_inet6;
        std.mem.writeInt(u16, buf[1..3], std.mem.bigToNative(u16, sin6.port), .big);
        buf[3..19].* = sin6.addr;
        std.mem.writeInt(u32, buf[19..23], std.mem.bigToNative(u32, sin6.flowinfo), .big);
        std.mem.writeInt(u32, buf[23..27], sin6.scope_id, .big);
        return buf[0..27];
    }
    if (fam == posix.AF.UNIX) {
        const sun: *const c.sockaddr.un = @ptrCast(@alignCast(sa));
        const off = @offsetOf(c.sockaddr.un, "path");
        const avail: usize = if (len > off) @min(len - off, sun.path.len) else 0;
        const path = std.mem.sliceTo(sun.path[0..avail], 0);
        if (path.len + 1 > buf.len) return null;
        buf[0] = family_unix;
        @memcpy(buf[1 .. 1 + path.len], path);
        return buf[0 .. 1 + path.len];
    }
    return null;
}

// ---- natives ----------------------------------------------------------------

fn nSocket(ctx: *CallCtx) Allocator.Error!EvalResult {
    const fam = platformFamily(@intCast(std.math.clamp(argInt(ctx, 0), 0, 255))) orelse return int(setErrno(.AFNOSUPPORT));
    const ty: u32 = switch (argInt(ctx, 1)) {
        1 => posix.SOCK.STREAM,
        2 => posix.SOCK.DGRAM,
        else => return int(setErrno(.INVAL)),
    };
    const fd = c.socket(fam, ty, 0);
    if (fd < 0) return int(failed());
    // Descriptors never leak into a child process.
    _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    if (comptime builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }
    return int(fd);
}

fn nErrno(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return int(last_errno);
}

/// The platform value of the errno constant `name` (`"EAGAIN"`), or -1.
pub fn errnoValue(name: []const u8) i32 {
    if (name.len < 2 or name[0] != 'E') return -1;
    const e = std.meta.stringToEnum(c.E, name[1..]) orelse return -1;
    return @intFromEnum(e);
}

fn nErrnoValue(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .String) return typeErr("__kknet_errno_value: name must be a String");
    const g = ctx.args[0].String.borrow();
    defer g.deinit();
    return int(errnoValue(g.get().bytes));
}

extern "c" fn strerror(errnum: c_int) ?[*:0]const u8;
extern "c" fn gai_strerror(errcode: c_int) ?[*:0]const u8;
extern "c" fn inet_ntop(af: c_int, src: *const anyopaque, dst: [*]u8, size: c.socklen_t) ?[*:0]const u8;

/// The message for an errno value; a negative value is a resolver (`EAI`)
/// code as `__kknet_getaddrinfo` records it.
fn nStrerror(ctx: *CallCtx) Allocator.Error!EvalResult {
    const e: c_int = @intCast(std.math.clamp(argInt(ctx, 0), std.math.minInt(c_int) + 1, std.math.maxInt(c_int)));
    const p = if (e < 0) gai_strerror(-e) else strerror(e);
    const msg: []const u8 = if (p) |m| std.mem.span(m) else "Unknown error";
    return .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, msg) } };
}

/// The textual form of a raw IPv4 (4 bytes) or IPv6 (16 bytes) address, as
/// `inet_ntop` writes it.
fn nNtop(ctx: *CallCtx) Allocator.Error!EvalResult {
    var raw: [16]u8 = undefined;
    const bytes = byteArrayCopy(ctx, 0, &raw) orelse return typeErr("__kknet_ntop: address must be a ByteArray");
    const af: c_int = switch (bytes.len) {
        4 => posix.AF.INET,
        16 => posix.AF.INET6,
        else => return .{ .ok = .Null },
    };
    var out: [64]u8 = undefined;
    const p = inet_ntop(af, bytes.ptr, &out, out.len) orelse return .{ .ok = .Null };
    return .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, std.mem.span(p)) } };
}

fn fdArg(ctx: *const CallCtx, i: usize) c_int {
    return @intCast(std.math.clamp(argInt(ctx, i), -1, std.math.maxInt(c_int)));
}

fn nClose(ctx: *CallCtx) Allocator.Error!EvalResult {
    const rc = c.close(fdArg(ctx, 0));
    return int(if (rc < 0) failed() else rc);
}

fn nShutdown(ctx: *CallCtx) Allocator.Error!EvalResult {
    const how: c_int = switch (argInt(ctx, 1)) {
        0 => posix.SHUT.RD,
        1 => posix.SHUT.WR,
        else => posix.SHUT.RDWR,
    };
    const rc = c.shutdown(fdArg(ctx, 0), how);
    return int(if (rc < 0) failed() else rc);
}

fn nNonblocking(ctx: *CallCtx) Allocator.Error!EvalResult {
    const fd = fdArg(ctx, 0);
    const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return int(failed());
    const nb: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    const rc = c.fcntl(fd, posix.F.SETFL, flags | nb);
    return int(if (rc < 0) failed() else rc);
}

/// `IP_TOS`: 1 on Linux, 3 on the BSDs and Darwin.
const ip_tos: u32 = if (builtin.os.tag == .linux) 1 else 3;

/// Option codes: 1 SO_REUSEADDR, 2 SO_REUSEPORT, 3 SO_BROADCAST, 4 SO_RCVBUF,
/// 5 SO_SNDBUF, 6 TCP_NODELAY, 7 SO_KEEPALIVE, 8 SO_LINGER (value: seconds, a
/// negative value turns lingering off), 9 IP_TOS.
fn nSetopt(ctx: *CallCtx) Allocator.Error!EvalResult {
    const fd = fdArg(ctx, 0);
    const value: c_int = @intCast(std.math.clamp(argInt(ctx, 2), std.math.minInt(c_int), std.math.maxInt(c_int)));
    const Opt = struct { level: i32, name: u32 };
    const opt: Opt = switch (argInt(ctx, 1)) {
        1 => .{ .level = posix.SOL.SOCKET, .name = posix.SO.REUSEADDR },
        2 => .{ .level = posix.SOL.SOCKET, .name = posix.SO.REUSEPORT },
        3 => .{ .level = posix.SOL.SOCKET, .name = posix.SO.BROADCAST },
        4 => .{ .level = posix.SOL.SOCKET, .name = posix.SO.RCVBUF },
        5 => .{ .level = posix.SOL.SOCKET, .name = posix.SO.SNDBUF },
        6 => .{ .level = posix.IPPROTO.TCP, .name = posix.TCP.NODELAY },
        7 => .{ .level = posix.SOL.SOCKET, .name = posix.SO.KEEPALIVE },
        8 => {
            const l = c.linger{ .onoff = if (value >= 0) 1 else 0, .linger = @max(value, 0) };
            const rc = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.LINGER, &l, @sizeOf(c.linger));
            return int(if (rc < 0) failed() else rc);
        },
        9 => .{ .level = posix.IPPROTO.IP, .name = ip_tos },
        else => return int(setErrno(.NOPROTOOPT)),
    };
    const rc = c.setsockopt(fd, opt.level, opt.name, &value, @sizeOf(c_int));
    return int(if (rc < 0) failed() else rc);
}

fn addrArg(ctx: *const CallCtx, i: usize) ?SockAddr {
    var buf: [256]u8 = undefined;
    const bytes = byteArrayCopy(ctx, i, &buf) orelse return null;
    return decodeAddr(bytes);
}

fn nConnect(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sa = addrArg(ctx, 1) orelse return int(setErrno(.INVAL));
    while (true) {
        const rc = c.connect(fdArg(ctx, 0), sa.ptr(), sa.len);
        if (rc == 0) return int(0);
        if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
        return int(failed());
    }
}

fn nBind(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sa = addrArg(ctx, 1) orelse return int(setErrno(.INVAL));
    const rc = c.bind(fdArg(ctx, 0), sa.ptr(), sa.len);
    return int(if (rc < 0) failed() else rc);
}

fn nListen(ctx: *CallCtx) Allocator.Error!EvalResult {
    const backlog: c_uint = @intCast(std.math.clamp(argInt(ctx, 1), 0, std.math.maxInt(c_int)));
    const rc = c.listen(fdArg(ctx, 0), backlog);
    return int(if (rc < 0) failed() else rc);
}

fn nAccept(ctx: *CallCtx) Allocator.Error!EvalResult {
    while (true) {
        const fd = c.accept(fdArg(ctx, 0), null, null);
        if (fd >= 0) {
            _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
            if (comptime builtin.os.tag.isDarwin()) {
                const one: c_int = 1;
                _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &one, @sizeOf(c_int));
            }
            return int(fd);
        }
        if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
        return int(failed());
    }
}

fn nSoError(ctx: *CallCtx) Allocator.Error!EvalResult {
    var v: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    const rc = c.getsockopt(fdArg(ctx, 0), posix.SOL.SOCKET, posix.SO.ERROR, &v, &len);
    if (rc < 0) return int(failed());
    return int(v);
}

fn nameOf(ctx: *CallCtx, comptime peer: bool) Allocator.Error!EvalResult {
    var ss: c.sockaddr.storage = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.storage);
    const sa: *c.sockaddr = @ptrCast(&ss);
    const rc = if (peer) c.getpeername(fdArg(ctx, 0), sa, &len) else c.getsockname(fdArg(ctx, 0), sa, &len);
    if (rc < 0) {
        _ = failed();
        return .{ .ok = .Null };
    }
    var buf: [128]u8 = undefined;
    const enc = encodeAddr(sa, len, &buf) orelse {
        _ = setErrno(.AFNOSUPPORT);
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
/// addresses, or null with the resolver's error recorded as errno (`EAI`
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
    var port_buf: [16]u8 = undefined;
    const port = std.fmt.bufPrintZ(&port_buf, "{d}", .{std.math.clamp(argInt(ctx, 1), 0, 65535)}) catch unreachable;

    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.family = posix.AF.UNSPEC;
    hints.socktype = posix.SOCK.STREAM;
    hints.flags = .{ .PASSIVE = true, .NUMERICSERV = true };
    var res: ?*c.addrinfo = null;
    // Name resolution may block on the network, so the thread counts as parked.
    runtime.gc.enterBlockingSafe();
    const rc = c.getaddrinfo(host.ptr, port.ptr, &hints, &res);
    runtime.gc.exitBlockingSafe();
    if (@intFromEnum(rc) != 0) {
        last_errno = -@as(i32, @intCast(@intFromEnum(rc)));
        return .{ .ok = .Null };
    }
    defer if (res) |r| c.freeaddrinfo(r);

    var items: std.ArrayList(Value) = .empty;
    var cur = res;
    while (cur) |ai| : (cur = ai.next) {
        const sa = ai.addr orelse continue;
        var buf: [128]u8 = undefined;
        const enc = encodeAddr(sa, ai.addrlen, &buf) orelse continue;
        try items.append(a, try newByteArray(a, enc));
    }
    return .{ .ok = runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, items)) };
}

const IoRange = struct { fd: c_int, off: usize, len: usize, flags: u32 };

fn rangeArgs(ctx: *const CallCtx) IoRange {
    return .{
        .fd = fdArg(ctx, 0),
        .off = @intCast(std.math.clamp(argInt(ctx, 2), 0, std.math.maxInt(i32))),
        .len = @intCast(std.math.clamp(argInt(ctx, 3), 0, std.math.maxInt(i32))),
        .flags = if (builtin.os.tag == .linux) std.os.linux.MSG.NOSIGNAL else 0,
    };
}

fn recvInto(r: IoRange, buf: []u8) i64 {
    if (r.off > buf.len or r.len > buf.len - r.off) return setErrno(.INVAL);
    while (true) {
        const n = c.recv(r.fd, buf.ptr + r.off, r.len, 0);
        if (n >= 0) return n;
        if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
        return failed();
    }
}

fn sendFrom(r: IoRange, buf: []u8) i64 {
    if (r.off > buf.len or r.len > buf.len - r.off) return setErrno(.INVAL);
    while (true) {
        const n = c.send(r.fd, buf.ptr + r.off, r.len, r.flags);
        if (n >= 0) return n;
        if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
        return failed();
    }
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

const RecvFrom = struct { r: IoRange, from: *c.sockaddr.storage, from_len: *c.socklen_t };

fn recvFromInto(s: RecvFrom, buf: []u8) i64 {
    const r = s.r;
    if (r.off > buf.len or r.len > buf.len - r.off) return setErrno(.INVAL);
    while (true) {
        s.from_len.* = @sizeOf(c.sockaddr.storage);
        const n = c.recvfrom(r.fd, buf.ptr + r.off, r.len, 0, @ptrCast(s.from), s.from_len);
        if (n >= 0) return n;
        if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
        return failed();
    }
}

/// `recvfrom(fd, buf[off, off + len))`: null on failure, otherwise the
/// sender's encoded address with the byte count appended as four big-endian
/// bytes.
fn nRecvfrom(ctx: *CallCtx) Allocator.Error!EvalResult {
    var from: c.sockaddr.storage = undefined;
    var from_len: c.socklen_t = 0;
    const st: RecvFrom = .{ .r = rangeArgs(ctx), .from = &from, .from_len = &from_len };
    const n = (try withBytes(ctx, 1, true, st, recvFromInto)) orelse return typeErr("__kknet_recvfrom: buffer must be a ByteArray");
    if (n < 0) return .{ .ok = .Null };
    var buf: [132]u8 = undefined;
    const enc = encodeAddr(@ptrCast(&from), from_len, buf[0..128]) orelse {
        _ = setErrno(.AFNOSUPPORT);
        return .{ .ok = .Null };
    };
    const total = enc.len + 4;
    std.mem.writeInt(u32, buf[enc.len..][0..4], @intCast(n), .big);
    return .{ .ok = try newByteArray(ctx.allocator, buf[0..total]) };
}

const SendTo = struct { r: IoRange, to: SockAddr };

fn sendToFrom(s: SendTo, buf: []u8) i64 {
    const r = s.r;
    if (r.off > buf.len or r.len > buf.len - r.off) return setErrno(.INVAL);
    while (true) {
        const n = c.sendto(r.fd, buf.ptr + r.off, r.len, r.flags, s.to.ptr(), s.to.len);
        if (n >= 0) return n;
        if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
        return failed();
    }
}

/// `sendto(fd, buf[off, off + len), addr)`.
fn nSendto(ctx: *CallCtx) Allocator.Error!EvalResult {
    const to = addrArg(ctx, 4) orelse return int(setErrno(.INVAL));
    const n = (try withBytes(ctx, 1, false, SendTo{ .r = rangeArgs(ctx), .to = to }, sendToFrom)) orelse return typeErr("__kknet_sendto: buffer must be a ByteArray");
    return int(n);
}

fn setNonblockCloexec(fd: c_int) void {
    const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    const nb: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    if (flags >= 0) _ = c.fcntl(fd, posix.F.SETFL, flags | nb);
    _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
}

/// A non-blocking pipe as `[read, write]`, or null.
fn nPipe(ctx: *CallCtx) Allocator.Error!EvalResult {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) < 0) {
        _ = failed();
        return .{ .ok = .Null };
    }
    setNonblockCloexec(fds[0]);
    setNonblockCloexec(fds[1]);
    return .{ .ok = try newIntArray(ctx.allocator, &.{ fds[0], fds[1] }) };
}

/// Writes one byte to the pipe: 1, or -1 (a full pipe is `EAGAIN`).
fn nPipeSignal(ctx: *CallCtx) Allocator.Error!EvalResult {
    const b = [1]u8{7};
    while (true) {
        const n = c.write(fdArg(ctx, 0), &b, 1);
        if (n >= 0) return int(n);
        if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
        return int(failed());
    }
}

/// Reads everything buffered in the pipe: the byte count, or -1.
fn nPipeDrain(ctx: *CallCtx) Allocator.Error!EvalResult {
    var total: i64 = 0;
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = c.read(fdArg(ctx, 0), &buf, buf.len);
        if (n > 0) {
            total += n;
            continue;
        }
        if (n == 0) return int(total);
        const e = c._errno().*;
        if (e == @intFromEnum(c.E.INTR)) continue;
        if (e == @intFromEnum(c.E.AGAIN)) return int(total);
        return int(failed());
    }
}

pub const poll_in: i32 = 1;
pub const poll_out: i32 = 2;
pub const poll_err: i32 = 4;
pub const poll_hup: i32 = 8;
pub const poll_nval: i32 = 16;

/// The first `out.len` elements of the IntArray argument `i`, or null when it
/// is shorter.
fn intArrayPrefix(ctx: *const CallCtx, i: usize, out: []i32) ?[]i32 {
    if (i >= ctx.args.len or ctx.args[i] != .Array) return null;
    const arr = ctx.args[i].Array;
    if (arr.len() < out.len) return null;
    for (out, 0..) |*x, k| x.* = @intCast(std.math.clamp(arr.get(k).asI64() orelse 0, std.math.minInt(i32), std.math.maxInt(i32)));
    return out;
}

/// Waits up to `sliceMs` for any of `count` descriptors, polling the run
/// boundary between slices of a longer wait.
pub fn pollFds(pfds: []c.pollfd, timeout_ms: i64) i32 {
    const slice_ms: i64 = 100;
    var remaining = timeout_ms;
    while (true) {
        if (runtime.shouldAbandon()) return 0;
        const wait: i64 = if (remaining < 0) slice_ms else @min(remaining, slice_ms);
        runtime.gc.enterBlockingSafe();
        const rc = c.poll(pfds.ptr, @intCast(pfds.len), @intCast(wait));
        runtime.gc.exitBlockingSafe();
        if (rc > 0) return rc;
        if (rc < 0) {
            if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
            return failed();
        }
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
    const pfds = try a.alloc(c.pollfd, count);
    defer a.free(pfds);
    for (pfds, fds, evs) |*p, fd, ev| {
        var events: i16 = 0;
        if (ev & poll_in != 0) events |= posix.POLL.IN;
        if (ev & poll_out != 0) events |= posix.POLL.OUT;
        p.* = .{ .fd = fd, .events = events, .revents = 0 };
    }
    const trace = runtime.envOnce("KLIO_NET_TRACE") != null;
    if (trace) tracePoll(fds, argInt(ctx, 4), null);
    const rc = pollFds(pfds, argInt(ctx, 4));
    if (trace) tracePoll(fds, argInt(ctx, 4), rc);
    if (rc > 0 and ctx.args.len > 2 and ctx.args[2] == .Array) {
        const out = ctx.args[2].Array;
        const n = @min(count, out.len());
        for (pfds[0..n], 0..) |p, k| {
            var r: i32 = 0;
            if (p.revents & posix.POLL.IN != 0) r |= poll_in;
            if (p.revents & posix.POLL.OUT != 0) r |= poll_out;
            if (p.revents & posix.POLL.ERR != 0) r |= poll_err;
            if (p.revents & posix.POLL.HUP != 0) r |= poll_hup;
            if (p.revents & posix.POLL.NVAL != 0) r |= poll_nval;
            out.set(a, k, Value.newInt(r));
        }
    }
    return int(rc);
}

fn nFdValid(ctx: *CallCtx) Allocator.Error!EvalResult {
    const rc = c.fcntl(fdArg(ctx, 0), posix.F.GETFL, @as(c_int, 0));
    return .{ .ok = .{ .Bool = rc != -1 or c._errno().* != @intFromEnum(c.E.BADF) } };
}

fn nIgnoreSigpipe(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.PIPE, &act, null);
    return .{ .ok = .Unit };
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "address encoding round-trips IPv4, IPv6 and unix addresses" {
    const v4 = [_]u8{ family_inet, 0x1f, 0x90, 127, 0, 0, 1 };
    const sa4 = decodeAddr(&v4).?;
    const sin: *const c.sockaddr.in = @ptrCast(&sa4.storage);
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
    try testing.expectEqual(@as(i32, @intFromEnum(c.E.AGAIN)), errnoValue("EAGAIN"));
    try testing.expectEqual(@as(i32, @intFromEnum(c.E.CONNREFUSED)), errnoValue("ECONNREFUSED"));
    try testing.expectEqual(@as(i32, @intFromEnum(c.E.BADF)), errnoValue("EBADF"));
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
    defer _ = c.close(@intCast(lfd));
    const any = try newByteArray(a, &.{ family_inet, 0, 0, 127, 0, 0, 1 });
    defer any.release(a);
    try testing.expectEqual(@as(?i64, 0), (try callNative(nBind, &.{ Value.newInt(lfd), any })).asI64());
    try testing.expectEqual(@as(?i64, 0), (try callNative(nListen, &.{ Value.newInt(lfd), Value.newInt(8) })).asI64());
    const bound = try callNative(nSockname, &.{Value.newInt(lfd)});
    defer bound.release(a);
    try testing.expect(bound == .Array);
    try testing.expectEqual(@as(usize, 7), bound.Array.len());

    const cfd = (try callNative(nSocket, &.{ Value.newInt(family_inet), Value.newInt(1) })).asI64().?;
    defer _ = c.close(@intCast(cfd));
    try testing.expectEqual(@as(?i64, 0), (try callNative(nConnect, &.{ Value.newInt(cfd), bound })).asI64());
    const sfd = (try callNative(nAccept, &.{Value.newInt(lfd)})).asI64().?;
    try testing.expect(sfd >= 0);
    defer _ = c.close(@intCast(sfd));
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
    const lfd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var sa: c.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try testing.expectEqual(@as(c_int, 0), c.bind(lfd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)));
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(lfd, @ptrCast(&sa), &len);
    _ = c.close(lfd);
    var enc: [7]u8 = .{ family_inet, 0, 0, 127, 0, 0, 1 };
    std.mem.writeInt(u16, enc[1..3], std.mem.bigToNative(u16, sa.port), .big);
    const addr = try newByteArray(a, &enc);
    defer addr.release(a);

    const fd = (try callNative(nSocket, &.{ Value.newInt(family_inet), Value.newInt(1) })).asI64().?;
    defer _ = c.close(@intCast(fd));
    _ = try callNative(nNonblocking, &.{Value.newInt(fd)});
    const rc = (try callNative(nConnect, &.{ Value.newInt(fd), addr })).asI64().?;
    if (rc == -1) {
        const e = (try callNative(nErrno, &.{})).asI64().?;
        if (e == errnoValue("EINPROGRESS")) {
            var p = [_]c.pollfd{.{ .fd = @intCast(fd), .events = posix.POLL.OUT, .revents = 0 }};
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
    defer _ = c.close(@intCast(r));
    defer _ = c.close(@intCast(w));
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
    var raw: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&raw));
    _ = c.close(raw[1]);
    _ = c.close(raw[0]);
    const fds = try newIntArray(a, &.{raw[0]});
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

test "the wakeup pipe signals and drains" {
    const a = testing.allocator;
    const p = try callNative(nPipe, &.{});
    defer p.release(a);
    const r = p.Array.get(0).asI64().?;
    const w = p.Array.get(1).asI64().?;
    defer _ = c.close(@intCast(r));
    defer _ = c.close(@intCast(w));
    try testing.expectEqual(@as(?i64, 0), (try callNative(nPipeDrain, &.{Value.newInt(r)})).asI64());
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPipeSignal, &.{Value.newInt(w)})).asI64());
    try testing.expectEqual(@as(?i64, 1), (try callNative(nPipeSignal, &.{Value.newInt(w)})).asI64());
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
