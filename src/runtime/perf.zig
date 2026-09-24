//! Runtime performance configuration: one resolved `Config` choosing the
//! memory backend, from `--opt <profile>` or `KLIO_OPT`, with `KLIO_RECLAIM`
//! as the override. A context that never calls `setProfile` keeps the
//! default.

const std = @import("std");
const objcell = @import("objcell.zig");
const envOnce = objcell.envOnce;

/// `fast` and `safe` run with the tracing collector, `off` drops it for an
/// arena.
pub const Profile = enum { fast, safe, off };

/// Mirrors the `KLIO_RECLAIM` values; `gc` is the tracing collector.
pub const AllocChoice = enum { arena, smp, debug, gc };

pub const Config = struct {
    reclaim: AllocChoice,
};

fn forProfile(p: Profile) Config {
    return switch (p) {
        .fast, .safe => .{ .reclaim = .gc },
        .off => .{ .reclaim = .arena },
    };
}

pub fn parseProfile(s: []const u8) ?Profile {
    const eq = std.mem.eql;
    if (eq(u8, s, "fast") or eq(u8, s, "full") or eq(u8, s, "on")) return .fast;
    if (eq(u8, s, "safe") or eq(u8, s, "balanced")) return .safe;
    if (eq(u8, s, "off") or eq(u8, s, "none") or eq(u8, s, "interp")) return .off;
    return null;
}

const default_profile: Profile = .safe;

var profile_override: ?Profile = null;
var cached: ?Config = null;

/// `null` falls back to the env or default and resets the resolved cache.
pub fn setProfile(p: ?Profile) void {
    profile_override = p;
    cached = null;
}

fn envReclaim() ?AllocChoice {
    const v = envOnce("KLIO_RECLAIM") orelse return null;
    if (v.len == 0 or std.mem.eql(u8, v, "gc")) return .gc;
    if (std.mem.eql(u8, v, "arena") or std.mem.eql(u8, v, "0")) return .arena;
    if (std.mem.eql(u8, v, "debug")) return .debug;
    return .smp; // "free", "smp", "1", or any other non-zero value
}

/// Precedence: an explicit `setProfile`, then `KLIO_OPT`, then the default.
///
/// Split so the resolved answer is one branch; the resolution itself is cold.
pub fn get() Config {
    return cached orelse resolve();
}

fn resolve() Config {
    const base = profile_override orelse blk: {
        const v = envOnce("KLIO_OPT") orelse break :blk default_profile;
        break :blk parseProfile(v) orelse default_profile;
    };
    var c = forProfile(base);
    if (envReclaim()) |r| c.reclaim = r;
    cached = c;
    return c;
}

pub fn allocChoice() AllocChoice {
    return get().reclaim;
}

pub fn resolveBinaryProfile(args: []const []const u8) Profile {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--opt") or std.mem.eql(u8, a, "-O")) {
            if (i + 1 < args.len) {
                if (parseProfile(args[i + 1])) |p| return p;
            }
        } else if (std.mem.startsWith(u8, a, "--opt=")) {
            if (parseProfile(a["--opt=".len..])) |p| return p;
        } else if (std.mem.startsWith(u8, a, "-O") and a.len > 2) {
            if (parseProfile(a[2..])) |p| return p;
        }
    }
    if (envOnce("KLIO_OPT")) |v| {
        if (parseProfile(v)) |p| return p;
    }
    return .fast;
}

test "profile presets" {
    try std.testing.expectEqual(AllocChoice.gc, forProfile(.fast).reclaim);
    try std.testing.expectEqual(AllocChoice.gc, forProfile(.safe).reclaim);
    try std.testing.expectEqual(AllocChoice.arena, forProfile(.off).reclaim);
}

test "profile parsing + aliases" {
    try std.testing.expectEqual(Profile.fast, parseProfile("fast").?);
    try std.testing.expectEqual(Profile.fast, parseProfile("on").?);
    try std.testing.expectEqual(Profile.safe, parseProfile("balanced").?);
    try std.testing.expectEqual(Profile.off, parseProfile("none").?);
    try std.testing.expectEqual(@as(?Profile, null), parseProfile("bogus"));
}

test "resolveBinaryProfile reads flags and defaults to fast" {
    try std.testing.expectEqual(Profile.fast, resolveBinaryProfile(&.{ "run", "a.kt" }));
    try std.testing.expectEqual(Profile.safe, resolveBinaryProfile(&.{ "run", "--opt", "safe", "a.kt" }));
    try std.testing.expectEqual(Profile.off, resolveBinaryProfile(&.{ "run", "--opt=off", "a.kt" }));
    try std.testing.expectEqual(Profile.safe, resolveBinaryProfile(&.{ "run", "-Osafe", "a.kt" }));
}
