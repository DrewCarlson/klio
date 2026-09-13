//! Stack-trace dumping that compiles out on mobile app targets: iOS and
//! Android cannot symbolize their own image at runtime, and a packaged app has
//! nowhere to print a trace. These wrappers forward to std on desktop and
//! comptime-drop the symbolizer on mobile, so `SelfInfo`, and the dyld symbol
//! it references, is never linked into a mobile build.
const std = @import("std");
const builtin = @import("builtin");

pub const mobile = builtin.os.tag == .ios or
    (builtin.os.tag == .linux and (builtin.abi == .android or builtin.abi == .androideabi));

pub inline fn dumpCurrent(options: std.debug.StackUnwindOptions) void {
    if (comptime !mobile) std.debug.dumpCurrentStackTrace(options);
}

pub inline fn dump(stack_trace: anytype) void {
    if (comptime !mobile) std.debug.dumpStackTrace(stack_trace);
}

/// Writes the message to stderr and aborts, so the OS crash reporter records
/// it. Only ever instantiated on a libc-linked mobile build.
pub fn panicFn(msg: []const u8, _: ?usize) noreturn {
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, "\n".ptr, 1);
    std.c.abort();
}
