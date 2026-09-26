//! Winsock declarations for the socket layer on Windows, and the mapping
//! from Winsock error codes to the errno values the ktor actuals compare
//! against.
//!
//! The actuals name errors the POSIX way (`EAGAIN`, `ECONNREFUSED`) and look
//! their values up through `__kknet_errno_value`. On Windows those values are
//! the C runtime's `errno.h` constants (`E` below, the same values as
//! `std.c.E` there), and a failing Winsock call's `WSAGetLastError()` is
//! translated to one of them. A Winsock code with no POSIX counterpart is
//! recorded as itself; every one of those is 10000 or more, above every
//! errno value, and its message comes from the system.
//!
//! The mapping is plain data, so its tests run on every host.

const std = @import("std");
const builtin = @import("builtin");

/// The C runtime's errno values on Windows, the ones Winsock errors map to.
pub const E = enum(u16) {
    NOENT = 2,
    INTR = 4,
    IO = 5,
    BADF = 9,
    AGAIN = 11,
    NOMEM = 12,
    ACCES = 13,
    FAULT = 14,
    INVAL = 22,
    MFILE = 24,
    PIPE = 32,
    NAMETOOLONG = 38,
    NOTEMPTY = 41,
    ADDRINUSE = 100,
    ADDRNOTAVAIL = 101,
    AFNOSUPPORT = 102,
    ALREADY = 103,
    BADMSG = 104,
    CANCELED = 105,
    CONNABORTED = 106,
    CONNREFUSED = 107,
    CONNRESET = 108,
    DESTADDRREQ = 109,
    HOSTUNREACH = 110,
    INPROGRESS = 112,
    ISCONN = 113,
    LOOP = 114,
    MSGSIZE = 115,
    NETDOWN = 116,
    NETRESET = 117,
    NETUNREACH = 118,
    NOBUFS = 119,
    NOPROTOOPT = 123,
    NOTCONN = 126,
    NOTSOCK = 128,
    OPNOTSUPP = 130,
    OVERFLOW = 132,
    PROTONOSUPPORT = 135,
    PROTOTYPE = 136,
    TIMEDOUT = 138,
    WOULDBLOCK = 140,
    DQUOT = 10069,
};

comptime {
    // On Windows these are the C runtime's own values.
    if (builtin.os.tag == .windows) {
        for (@typeInfo(E).@"enum".fields) |f| {
            if (@intFromEnum(@field(std.c.E, f.name)) != f.value) @compileError("errno value mismatch for E" ++ f.name);
        }
    }
}

/// Winsock error codes (`winerror.h`).
pub const WSA = struct {
    pub const INVALID_HANDLE = 6;
    pub const NOT_ENOUGH_MEMORY = 8;
    pub const INVALID_PARAMETER = 87;
    pub const OPERATION_ABORTED = 995;
    pub const EINTR = 10004;
    pub const EBADF = 10009;
    pub const EACCES = 10013;
    pub const EFAULT = 10014;
    pub const EINVAL = 10022;
    pub const EMFILE = 10024;
    pub const EWOULDBLOCK = 10035;
    pub const EINPROGRESS = 10036;
    pub const EALREADY = 10037;
    pub const ENOTSOCK = 10038;
    pub const EDESTADDRREQ = 10039;
    pub const EMSGSIZE = 10040;
    pub const EPROTOTYPE = 10041;
    pub const ENOPROTOOPT = 10042;
    pub const EPROTONOSUPPORT = 10043;
    pub const ESOCKTNOSUPPORT = 10044;
    pub const EOPNOTSUPP = 10045;
    pub const EPFNOSUPPORT = 10046;
    pub const EAFNOSUPPORT = 10047;
    pub const EADDRINUSE = 10048;
    pub const EADDRNOTAVAIL = 10049;
    pub const ENETDOWN = 10050;
    pub const ENETUNREACH = 10051;
    pub const ENETRESET = 10052;
    pub const ECONNABORTED = 10053;
    pub const ECONNRESET = 10054;
    pub const ENOBUFS = 10055;
    pub const EISCONN = 10056;
    pub const ENOTCONN = 10057;
    pub const ESHUTDOWN = 10058;
    pub const ETOOMANYREFS = 10059;
    pub const ETIMEDOUT = 10060;
    pub const ECONNREFUSED = 10061;
    pub const ELOOP = 10062;
    pub const ENAMETOOLONG = 10063;
    pub const EHOSTDOWN = 10064;
    pub const EHOSTUNREACH = 10065;
    pub const ENOTEMPTY = 10066;
    pub const EDQUOT = 10069;
    pub const NOTINITIALISED = 10093;
    pub const EDISCON = 10101;
    pub const HOST_NOT_FOUND = 11001;
    pub const TRY_AGAIN = 11002;
    pub const NO_RECOVERY = 11003;
    pub const NO_DATA = 11004;
};

/// The errno value for a Winsock error code, or the code itself when POSIX
/// has no counterpart.
pub fn errnoOf(code: i32) i32 {
    const e: E = switch (code) {
        WSA.INVALID_HANDLE, WSA.EBADF => .BADF,
        WSA.NOT_ENOUGH_MEMORY => .NOMEM,
        WSA.INVALID_PARAMETER, WSA.EINVAL => .INVAL,
        WSA.OPERATION_ABORTED => .CANCELED,
        WSA.EINTR => .INTR,
        WSA.EACCES => .ACCES,
        WSA.EFAULT => .FAULT,
        WSA.EMFILE => .MFILE,
        // A non-blocking call that would block: POSIX says EAGAIN, and the
        // actuals' messages name it so on every platform.
        WSA.EWOULDBLOCK => .AGAIN,
        WSA.EINPROGRESS => .INPROGRESS,
        WSA.EALREADY => .ALREADY,
        WSA.ENOTSOCK => .NOTSOCK,
        WSA.EDESTADDRREQ => .DESTADDRREQ,
        WSA.EMSGSIZE => .MSGSIZE,
        WSA.EPROTOTYPE => .PROTOTYPE,
        WSA.ENOPROTOOPT => .NOPROTOOPT,
        WSA.EPROTONOSUPPORT => .PROTONOSUPPORT,
        WSA.EOPNOTSUPP => .OPNOTSUPP,
        WSA.EAFNOSUPPORT => .AFNOSUPPORT,
        WSA.EADDRINUSE => .ADDRINUSE,
        WSA.EADDRNOTAVAIL => .ADDRNOTAVAIL,
        WSA.ENETDOWN => .NETDOWN,
        WSA.ENETUNREACH => .NETUNREACH,
        WSA.ENETRESET => .NETRESET,
        WSA.ECONNABORTED => .CONNABORTED,
        WSA.ECONNRESET => .CONNRESET,
        WSA.ENOBUFS => .NOBUFS,
        WSA.EISCONN => .ISCONN,
        WSA.ENOTCONN => .NOTCONN,
        // Sending after `shutdown(SD_SEND)`; POSIX reports EPIPE.
        WSA.ESHUTDOWN => .PIPE,
        WSA.ETIMEDOUT => .TIMEDOUT,
        WSA.ECONNREFUSED => .CONNREFUSED,
        WSA.ELOOP => .LOOP,
        WSA.ENAMETOOLONG => .NAMETOOLONG,
        WSA.EHOSTUNREACH => .HOSTUNREACH,
        WSA.ENOTEMPTY => .NOTEMPTY,
        WSA.EDQUOT => .DQUOT,
        else => return code,
    };
    return @intFromEnum(e);
}

/// The errno value of `connect`'s failure: a non-blocking connect that has
/// started reports `WSAEWOULDBLOCK` on Windows and EINPROGRESS on POSIX.
pub fn connectErrnoOf(code: i32) i32 {
    if (code == WSA.EWOULDBLOCK) return @intFromEnum(E.INPROGRESS);
    return errnoOf(code);
}

/// The errno value of a name, `"EAGAIN"`, or -1.
pub fn errnoValue(name: []const u8) i32 {
    if (name.len < 2 or name[0] != 'E') return -1;
    const e = std.meta.stringToEnum(E, name[1..]) orelse return -1;
    return @intFromEnum(e);
}

/// The message for an errno value `errnoOf` produces, in the wording of the
/// POSIX C libraries. Null for a value without one here (a Winsock code, or
/// an errno value the C runtime describes).
pub fn message(errno: i32) ?[]const u8 {
    if (errno < 0 or errno > std.math.maxInt(u16)) return null;
    const e = std.enums.fromInt(E, errno) orelse return null;
    return switch (e) {
        .NOENT => "No such file or directory",
        .INTR => "Interrupted system call",
        .IO => "Input/output error",
        .BADF => "Bad file descriptor",
        .AGAIN => "Resource temporarily unavailable",
        .NOMEM => "Cannot allocate memory",
        .ACCES => "Permission denied",
        .FAULT => "Bad address",
        .INVAL => "Invalid argument",
        .MFILE => "Too many open files",
        .PIPE => "Broken pipe",
        .NAMETOOLONG => "File name too long",
        .NOTEMPTY => "Directory not empty",
        .ADDRINUSE => "Address already in use",
        .ADDRNOTAVAIL => "Cannot assign requested address",
        .AFNOSUPPORT => "Address family not supported by protocol",
        .ALREADY => "Operation already in progress",
        .BADMSG => "Bad message",
        .CANCELED => "Operation canceled",
        .CONNABORTED => "Software caused connection abort",
        .CONNREFUSED => "Connection refused",
        .CONNRESET => "Connection reset by peer",
        .DESTADDRREQ => "Destination address required",
        .HOSTUNREACH => "No route to host",
        .INPROGRESS => "Operation now in progress",
        .ISCONN => "Transport endpoint is already connected",
        .LOOP => "Too many levels of symbolic links",
        .MSGSIZE => "Message too long",
        .NETDOWN => "Network is down",
        .NETRESET => "Network dropped connection on reset",
        .NETUNREACH => "Network is unreachable",
        .NOBUFS => "No buffer space available",
        .NOPROTOOPT => "Protocol not available",
        .NOTCONN => "Transport endpoint is not connected",
        .NOTSOCK => "Socket operation on non-socket",
        .OPNOTSUPP => "Operation not supported",
        .OVERFLOW => "Value too large for defined data type",
        .PROTONOSUPPORT => "Protocol not supported",
        .PROTOTYPE => "Protocol wrong type for socket",
        .TIMEDOUT => "Connection timed out",
        .WOULDBLOCK => "Resource temporarily unavailable",
        .DQUOT => "Disk quota exceeded",
    };
}

// ---- declarations (referenced only by the Windows build) ----------------------

pub const SOCKET = usize;
pub const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
pub const SOCKET_ERROR: i32 = -1;

pub const AF_UNSPEC = 0;
pub const AF_UNIX = 1;
pub const AF_INET = 2;
pub const AF_INET6 = 23;
pub const SOCK_STREAM = 1;
pub const SOCK_DGRAM = 2;
pub const SOL_SOCKET = 0xffff;
pub const SO_KEEPALIVE = 0x0008;
pub const SO_BROADCAST = 0x0020;
pub const SO_LINGER = 0x0080;
pub const SO_SNDBUF = 0x1001;
pub const SO_RCVBUF = 0x1002;
pub const SO_ERROR = 0x1007;
pub const SO_TYPE = 0x1008;
pub const SO_EXCLUSIVEADDRUSE: i32 = ~@as(i32, 0x0004);
pub const IPPROTO_IP = 0;
pub const IPPROTO_TCP = 6;
pub const IP_TOS = 3;
pub const TCP_NODELAY = 1;
pub const SD_RECEIVE = 0;
pub const SD_SEND = 1;
pub const SD_BOTH = 2;
pub const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));
pub const WSA_FLAG_OVERLAPPED: u32 = 0x01;
pub const WSA_FLAG_NO_HANDLE_INHERIT: u32 = 0x80;
pub const HANDLE_FLAG_INHERIT: u32 = 0x1;
pub const AI_PASSIVE = 0x1;
pub const AI_NUMERICSERV = 0x8;

pub const POLLRDNORM: i16 = 0x0100;
pub const POLLRDBAND: i16 = 0x0200;
pub const POLLIN: i16 = POLLRDNORM | POLLRDBAND;
pub const POLLWRNORM: i16 = 0x0010;
pub const POLLOUT: i16 = POLLWRNORM;
pub const POLLERR: i16 = 0x0001;
pub const POLLHUP: i16 = 0x0002;
pub const POLLNVAL: i16 = 0x0004;

pub const sockaddr = std.os.windows.ws2_32.sockaddr;

pub const pollfd = extern struct {
    fd: SOCKET,
    events: i16,
    revents: i16,
};

pub const linger = extern struct {
    onoff: u16,
    linger: u16,
};

pub const addrinfo = extern struct {
    flags: i32,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*sockaddr,
    next: ?*addrinfo,
};

/// Large enough for either layout of `WSADATA`.
pub const WSADATA = extern struct { bytes: [512]u8 align(8) };

pub extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
pub extern "ws2_32" fn WSASocketW(af: i32, ty: i32, protocol: i32, info: ?*anyopaque, g: u32, flags: u32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
pub extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, arg: *u32) callconv(.winapi) i32;
pub extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, name: i32, value: [*]const u8, len: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, name: i32, value: [*]u8, len: *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr, len: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr, len: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr, len: ?*i32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr, len: *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getpeername(s: SOCKET, name: *sockaddr, len: *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn recvfrom(s: SOCKET, buf: [*]u8, len: i32, flags: i32, from: ?*sockaddr, from_len: ?*i32) callconv(.winapi) i32;
pub extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: i32, flags: i32, to: *const sockaddr, to_len: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAPoll(fds: [*]pollfd, count: u32, timeout: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getaddrinfo(node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const addrinfo, result: *?*addrinfo) callconv(.winapi) i32;
pub extern "ws2_32" fn freeaddrinfo(info: *addrinfo) callconv(.winapi) void;
pub extern "ws2_32" fn inet_ntop(family: i32, addr: *const anyopaque, buf: [*]u8, size: usize) callconv(.winapi) ?[*:0]const u8;

pub extern "kernel32" fn SetHandleInformation(h: *anyopaque, mask: u32, flags: u32) callconv(.winapi) i32;
pub extern "kernel32" fn FormatMessageW(flags: u32, source: ?*const anyopaque, id: u32, lang: u32, buf: [*]u16, size: u32, args: ?*anyopaque) callconv(.winapi) u32;

pub const FORMAT_MESSAGE_FROM_SYSTEM: u32 = 0x1000;
pub const FORMAT_MESSAGE_IGNORE_INSERTS: u32 = 0x200;

/// The system's message for a Winsock or Win32 error code, without its
/// trailing period and line break, written into `buf`.
pub fn systemMessage(code: u32, buf: []u8) ?[]const u8 {
    var wide: [512]u16 = undefined;
    const n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, null, code, 0, &wide, wide.len, null);
    if (n == 0) return null;
    var text = wide[0..n];
    while (text.len > 0 and (text[text.len - 1] == '\r' or text[text.len - 1] == '\n' or text[text.len - 1] == ' ' or text[text.len - 1] == '.')) text.len -= 1;
    var len: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(text);
    while (it.nextCodepoint() catch null) |cp| {
        var tmp: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (len + k > buf.len) break;
        @memcpy(buf[len..][0..k], tmp[0..k]);
        len += k;
    }
    return buf[0..len];
}

// ---- tests ----------------------------------------------------------------------

const testing = std.testing;

test "Winsock errors map to the errno values the ktor actuals name" {
    try testing.expectEqual(errnoValue("EAGAIN"), errnoOf(WSA.EWOULDBLOCK));
    try testing.expectEqual(errnoValue("ECONNREFUSED"), errnoOf(WSA.ECONNREFUSED));
    try testing.expectEqual(errnoValue("ECONNRESET"), errnoOf(WSA.ECONNRESET));
    try testing.expectEqual(errnoValue("ECONNABORTED"), errnoOf(WSA.ECONNABORTED));
    try testing.expectEqual(errnoValue("ENOTCONN"), errnoOf(WSA.ENOTCONN));
    try testing.expectEqual(errnoValue("ETIMEDOUT"), errnoOf(WSA.ETIMEDOUT));
    try testing.expectEqual(errnoValue("ENOTSOCK"), errnoOf(WSA.ENOTSOCK));
    try testing.expectEqual(errnoValue("EADDRINUSE"), errnoOf(WSA.EADDRINUSE));
    try testing.expectEqual(errnoValue("EBADF"), errnoOf(WSA.EBADF));
    try testing.expectEqual(errnoValue("EBADF"), errnoOf(WSA.INVALID_HANDLE));
    try testing.expectEqual(errnoValue("EINVAL"), errnoOf(WSA.EINVAL));
    try testing.expectEqual(errnoValue("EINTR"), errnoOf(WSA.EINTR));
    try testing.expectEqual(errnoValue("ENOMEM"), errnoOf(WSA.NOT_ENOUGH_MEMORY));
    try testing.expectEqual(errnoValue("EPIPE"), errnoOf(WSA.ESHUTDOWN));
    try testing.expectEqual(errnoValue("EAFNOSUPPORT"), errnoOf(WSA.EAFNOSUPPORT));
    try testing.expectEqual(errnoValue("ENOPROTOOPT"), errnoOf(WSA.ENOPROTOOPT));
    try testing.expectEqual(errnoValue("EHOSTUNREACH"), errnoOf(WSA.EHOSTUNREACH));
    try testing.expectEqual(errnoValue("ENETUNREACH"), errnoOf(WSA.ENETUNREACH));
}

test "the values are the Windows C runtime's" {
    try testing.expectEqual(@as(i32, 11), errnoValue("EAGAIN"));
    try testing.expectEqual(@as(i32, 140), errnoValue("EWOULDBLOCK"));
    try testing.expectEqual(@as(i32, 112), errnoValue("EINPROGRESS"));
    try testing.expectEqual(@as(i32, 107), errnoValue("ECONNREFUSED"));
    try testing.expectEqual(@as(i32, 108), errnoValue("ECONNRESET"));
    try testing.expectEqual(@as(i32, 100), errnoValue("EADDRINUSE"));
    try testing.expectEqual(@as(i32, 9), errnoValue("EBADF"));
    try testing.expectEqual(@as(i32, -1), errnoValue("AGAIN"));
    try testing.expectEqual(@as(i32, -1), errnoValue("ENOTANERRNO"));
    try testing.expectEqual(@as(i32, -1), errnoValue(""));
}

test "a started non-blocking connect reads as EINPROGRESS" {
    try testing.expectEqual(errnoValue("EINPROGRESS"), connectErrnoOf(WSA.EWOULDBLOCK));
    try testing.expectEqual(errnoValue("ECONNREFUSED"), connectErrnoOf(WSA.ECONNREFUSED));
    try testing.expectEqual(errnoValue("EALREADY"), connectErrnoOf(WSA.EALREADY));
}

test "a Winsock error without a POSIX counterpart keeps its own code" {
    for ([_]i32{ WSA.ESOCKTNOSUPPORT, WSA.EPFNOSUPPORT, WSA.ETOOMANYREFS, WSA.EHOSTDOWN, WSA.NOTINITIALISED, WSA.EDISCON, WSA.HOST_NOT_FOUND }) |code| {
        try testing.expectEqual(code, errnoOf(code));
        try testing.expect(message(code) == null);
    }
}

test "no mapped value collides with a Winsock code kept as itself" {
    // Every mapped value is either below 10000 or equal to its own code.
    var code: i32 = 0;
    while (code < 12000) : (code += 1) {
        const v = errnoOf(code);
        if (v != code) try testing.expect(v < 10000);
    }
}

test "every mapped errno value has a message" {
    inline for (@typeInfo(E).@"enum".fields) |f| try testing.expect(message(f.value) != null);
    try testing.expectEqualStrings("Connection refused", message(errnoOf(WSA.ECONNREFUSED)).?);
    try testing.expectEqualStrings("Resource temporarily unavailable", message(errnoOf(WSA.EWOULDBLOCK)).?);
    try testing.expect(message(-8) == null);
}
