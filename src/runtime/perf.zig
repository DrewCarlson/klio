//! Runtime performance configuration: one resolved `Config` that gates the JIT
//! tiers and the memory backend, instead of each subsystem probing its own env
//! var. A single profile (`fast`/`safe`/`off`) is the primary control, exposed
//! identically through the CLI (`--opt <profile>`) and the environment
//! (`KLIO_OPT`). The low-level env vars stay as diagnostic overrides layered on
//! top of the profile.
//!
//! The process entry point (`main.zig`) resolves the profile once for the
//! `klio` binary, defaulting to `fast`. Contexts that never call `setProfile`
//! (the in-process multi-program test harness) keep the conservative default —
//! interpreter, bounded GC — so a hot loop never silently compiles per worker.

const std = @import("std");
const objcell = @import("objcell.zig");
const getenvSlice = objcell.getenvSlice;
const envOnce = objcell.envOnce;

/// Bundled performance preset. `fast` turns on everything that speeds up a
/// normal single-program run; `safe` keeps the interpreter; `off` also drops
/// the bounded collector for the simplest never-free arena.
pub const Profile = enum { fast, safe, off };

/// Backing-allocator family for the run. Mirrors the historical `KLIO_RECLAIM`
/// values; `gc` is the tracing collector with the page-returning slab backend.
pub const AllocChoice = enum { arena, smp, debug, gc };

pub const Config = struct {
    /// Loop-header JIT (`KLIO_JIT`).
    jit_loop: bool,
    /// Whole-function JIT / native recursion (`KLIO_FUNC_JIT`); implies the loop tier.
    jit_func: bool,
    /// Backing allocator the entry point installs.
    reclaim: AllocChoice,
};

fn forProfile(p: Profile) Config {
    return switch (p) {
        .fast => .{ .jit_loop = true, .jit_func = true, .reclaim = .gc },
        .safe => .{ .jit_loop = false, .jit_func = false, .reclaim = .gc },
        .off => .{ .jit_loop = false, .jit_func = false, .reclaim = .arena },
    };
}

/// Parse a profile name. Accepts a few friendly aliases.
pub fn parseProfile(s: []const u8) ?Profile {
    const eq = std.mem.eql;
    if (eq(u8, s, "fast") or eq(u8, s, "full") or eq(u8, s, "on")) return .fast;
    if (eq(u8, s, "safe") or eq(u8, s, "balanced")) return .safe;
    if (eq(u8, s, "off") or eq(u8, s, "none") or eq(u8, s, "interp")) return .off;
    return null;
}

/// Profile used when nothing set the config — conservative, so the in-process
/// test harness and any embedder default to the interpreter.
const default_profile: Profile = .safe;

var profile_override: ?Profile = null;
var cached: ?Config = null;

/// Set the base profile (e.g. from the CLI `--opt` flag or `KLIO_OPT`). Passing
/// `null` clears an explicit choice and falls back to the env/default. Resets the
/// resolved cache so the next read re-applies the granular overrides.
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

/// The resolved configuration. Base profile precedence: explicit `setProfile`
/// (CLI), then `KLIO_OPT`, then the conservative default. The granular env vars
/// (`KLIO_JIT`, `KLIO_FUNC_JIT`, `KLIO_RECLAIM`) override individual fields.
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

/// Backing-allocator family for the entry point. Honors the profile + override.
pub fn allocChoice() AllocChoice {
    return get().reclaim;
}

/// Resolve the entry-point profile for the `klio` binary from its argv and the
/// environment, defaulting to `fast`. Recognizes `--opt <v>`, `--opt=<v>`, and
/// `-O <v>`/`-O<v>` anywhere in the arguments. An unknown value falls through to
/// the env/`fast` default (the CLI surfaces the error separately).
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
    // Default by subcommand. `test` runs many small programs whose hot loops
    // are dispatch-heavy (assertions, collection ops) rather than pure numeric
    // kernels, so the loop JIT's per-block tracking costs more than it saves;
    // default it to the plain interpreter (`safe`). A single `run` keeps `fast`.
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
