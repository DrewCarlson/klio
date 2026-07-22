//! Stack-trace dumping that compiles out on mobile app targets.
//!
//! Mobile apps (iOS, Android) cannot symbolize their own image at runtime: the
//! iOS simulator SDK does not export the dyld image-header lookup
//! `std.debug.SelfInfo` links against, and a packaged app has nowhere to print a
//! trace regardless (crashes go to the OS crash reporter — see `main.zig`). These
//! wrappers forward to std on desktop and comptime-drop the symbolizer on mobile
//! so `SelfInfo` (and the missing dyld symbol it references) is never linked into
//! a mobile build. The diagnostic call sites route through here instead of
//! calling `std.debug` directly.
const std = @import("std");
const builtin = @import("builtin");

/// True for the mobile app targets whose stack-trace symbolizer must be elided.
pub const mobile = builtin.os.tag == .ios or
    (builtin.os.tag == .linux and (builtin.abi == .android or builtin.abi == .androideabi));

/// `std.debug.dumpCurrentStackTrace`, elided on mobile.
pub inline fn dumpCurrent(options: std.debug.StackUnwindOptions) void {
    if (comptime !mobile) std.debug.dumpCurrentStackTrace(options);
}

/// `std.debug.dumpStackTrace`, elided on mobile.
pub inline fn dump(stack_trace: anytype) void {
    if (comptime !mobile) std.debug.dumpStackTrace(stack_trace);
}
