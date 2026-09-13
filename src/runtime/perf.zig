//! Runtime performance configuration: one resolved `Config` gating the JIT
//! tiers and the memory backend, from `--opt <profile>` or `KLIO_OPT`, with the
//! low-level env vars as overrides. A context that never calls `setProfile`
//! keeps the conservative default.

const std = @import("std");
const objcell = @import("objcell.zig");
const getenvSlice = objcell.getenvSlice;
const envOnce = objcell.envOnce;

/// `fast` speeds a normal run, `safe` keeps the interpreter, `off` also drops
/// the bounded collector.
pub const Profile = enum { fast, safe, off };

/// Mirrors the `KLIO_RECLAIM` values; `gc` is the tracing collector.
pub const AllocChoice = enum { arena, smp, debug, gc };

pub const Config = struct {
    /// `KLIO_JIT`.
    jit_loop: bool,
    /// `KLIO_FUNC_JIT`; implies the loop tier.
    jit_func: bool,
    reclaim: AllocChoice,
};

fn forProfile(p: Profile) Config {
    return switch (p) {
        .fast => .{ .jit_loop = true, .jit_func = true, .reclaim = .gc },
        .safe => .{ .jit_loop = false, .jit_func = false, .reclaim = .gc },
        .off => .{ .jit_loop = false, .jit_func = false, .reclaim = .arena },
    };
}

pub fn parseProfile(s: []const u8) ?Profile {
    const eq = std.mem.eql;
    if (eq(u8, s, "fast") or eq(u8, s, "full") or eq(u8, s, "on")) return .fast;
    if (eq(u8, s, "safe") or eq(u8, s, "balanced")) return .safe;
    if (eq(u8, s, "off") or eq(u8, s, "none") or eq(u8, s, "interp")) return .off;
    return null;
}

/// Conservative, so any embedder defaults to the interpreter.
const default_profile: Profile = .safe;

var profile_override: ?Profile = null;
var cached: ?Config = null;

/// `null` falls back to the env or default and resets the resolved cache.
pub fn setProfile(p: ?Profile) void {
    profile_override = p;
    cached = null;
}

fn envBool(name: [*:0]const u8) ?bool {
    const v = getenvSlice(name) orelse return null;
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

fn envReclaim() ?AllocChoice {
    const v = envOnce("KLIO_RECLAIM") orelse return null;
    if (v.len == 0 or std.mem.eql(u8, v, "gc")) return .gc;
    if (std.mem.eql(u8, v, "arena") or std.mem.eql(u8, v, "0")) return .arena;
    if (std.mem.eql(u8, v, "debug")) return .debug;
    return .smp; // "free", "smp", "1", or any other non-zero value
}

/// Precedence: an explicit `setProfile`, then `KLIO_OPT`, then the default.
pub fn get() Config {
    if (cached) |c| return c;
    const base = profile_override orelse blk: {
        const v = envOnce("KLIO_OPT") orelse break :blk default_profile;
        break :blk parseProfile(v) orelse default_profile;
    };
    var c = forProfile(base);
    if (envBool("KLIO_JIT")) |b| c.jit_loop = b;
    if (envBool("KLIO_FUNC_JIT")) |b| {
        c.jit_func = b;
        if (b) c.jit_loop = true; // function mode rides on the loop tier
    }
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
    // `test` runs many small programs whose hot loops are dispatch-heavy, so
    // the loop JIT's tracking costs more than it saves.
    {
        var j: usize = 1; // args[0] is the executable path
        while (j < args.len) : (j += 1) {
            const a = args[j];
            if (a.len > 0 and a[0] == '-') continue;
            if (std.mem.eql(u8, a, "test")) return .safe;
            break; // the first non-flag token is the subcommand
        }
    }
    return .fast;
}

test "profile presets" {
    try std.testing.expectEqual(true, forProfile(.fast).jit_loop);
    try std.testing.expectEqual(true, forProfile(.fast).jit_func);
    try std.testing.expectEqual(AllocChoice.gc, forProfile(.fast).reclaim);
    try std.testing.expectEqual(false, forProfile(.safe).jit_loop);
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
