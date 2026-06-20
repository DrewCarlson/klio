//! Native bindings for `kotlinx-datetime`.
//!
//! The Kotlin shim under `shim/` declares the public API; the bindings
//! here expose host-side helpers the shim calls into:
//!
//! - system clock (`__kxdt_currentTimeMillis`,
//!   `__kxdt_currentNanosOfSecond`, `__kxdt_currentSystemTimeZoneId`)
//! - `Instant` <-> `LocalDateTime` conversion in a given IANA tz
//! - ISO-8601 rendering and parsing of `Instant`
//! - tz id validation
//!
//! Top-level arithmetic, formatting of `LocalDate` / `LocalTime` /
//! `LocalDateTime`, and operator dispatch are pure-Kotlin in the shim.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const HostBindings = stdlib.HostBindings;

/// Build a registry populated with this crate's native bindings, keyed by
/// the FQN the shim's `external` declarations resolve to.
pub fn hostBindings(allocator: std.mem.Allocator) std.mem.Allocator.Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("kotlinx.datetime.__kxdt_currentTimeMillis", currentTimeMillis);
    try b.register("kotlinx.datetime.__kxdt_currentNanosOfSecond", currentNanosOfSecond);
    try b.register("kotlinx.datetime.__kxdt_currentSystemTimeZoneId", currentSystemTzId);
    try b.register("kotlinx.datetime.__kxdt_instantToLocalParts", instantToLocalParts);
    try b.register("kotlinx.datetime.__kxdt_localToInstant", localToInstant);
    try b.register("kotlinx.datetime.__kxdt_instantToString", instantToString);
    try b.register("kotlinx.datetime.__kxdt_parseInstant", parseInstant);
    try b.register("kotlinx.datetime.__kxdt_validateTimeZone", validateTimeZone);
    try b.register("kotlinx.datetime.__kxdt_addPeriod", addPeriod);
    return b;
}

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!EvalResult {
    return .{ .err = .{ .Type = try std.fmt.allocPrint(allocator, fmt, args) } };
}

fn typeErrLit(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

// -------------------------------------------------------------------------
// Wall-clock readings
// -------------------------------------------------------------------------

const Now = struct {
    secs: i64,
    nanos: u32,
};

fn utcNow() Now {
    const w = runtime.clockWallTime();
    return .{ .secs = w.secs, .nanos = w.nanos };
}

fn currentTimeMillis(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    const now = utcNow();
    const millis = now.secs * 1000 + @divTrunc(@as(i64, now.nanos), 1_000_000);
    return ok(.{ .Long = millis });
}

fn currentNanosOfSecond(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    const now = utcNow();
    return ok(Value.newInt(@as(i64, now.nanos)));
}

fn currentSystemTzId(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const id = systemTimeZoneId(ctx.allocator) catch try ctx.allocator.dupe(u8, "UTC");
    return ok(.{ .String = try runtime.strInitOwned(ctx.allocator, id) });
}

/// Best-effort detection of the host IANA tz id. Honors `$TZ` when it
/// names a zone, then the `/etc/localtime` symlink target, else `UTC`.
/// The returned slice is owned by `allocator`.
fn systemTimeZoneId(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    if (try getEnvVar(allocator, "TZ")) |tz| {
        if (tz.len != 0 and tz[0] != ':') return tz;
        allocator.free(tz);
    }
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", &buf)) |n| {
        const target = buf[0..n];
        if (std.mem.indexOf(u8, target, "zoneinfo/")) |i| {
            const id = target[i + "zoneinfo/".len ..];
            if (id.len != 0) return try allocator.dupe(u8, id);
        }
    } else |_| {}
    return try allocator.dupe(u8, "UTC");
}

/// Read an environment variable's value. Returns an `allocator`-owned copy or
/// null. Reads the process environment portably (see `runtime.procEnvGetVar`).
fn getEnvVar(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    return runtime.procEnvGetVar(allocator, name);
}

// -------------------------------------------------------------------------
// Argument coercion
// -------------------------------------------------------------------------

const ArgError = error{ OutOfMemory, BadArg };

fn argLong(ctx: *CallCtx, idx: usize) ArgError!i64 {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .Long => |l| return l,
            .Int => |i| return @as(i64, i),
            else => {},
        }
    }
    return ArgError.BadArg;
}

// Kotlin Long.toInt() truncates.
fn argI32(ctx: *CallCtx, idx: usize) ArgError!i32 {
    return @truncate(try argLong(ctx, idx));
}

fn argStr(ctx: *CallCtx, idx: usize) ArgError![]const u8 {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                return try ctx.allocator.dupe(u8, g.get().bytes);
            },
            else => {},
        }
    }
    return ArgError.BadArg;
}

fn badLongArg(allocator: std.mem.Allocator, idx: usize) std.mem.Allocator.Error!EvalResult {
    return typeErr(allocator, "kotlinx.datetime: argument {d} must be Int/Long", .{idx});
}

fn badStrArg(allocator: std.mem.Allocator, idx: usize) std.mem.Allocator.Error!EvalResult {
    return typeErr(allocator, "kotlinx.datetime: argument {d} must be String", .{idx});
}

// -------------------------------------------------------------------------
// Civil-time math (Howard Hinnant's algorithms; proleptic Gregorian)
// -------------------------------------------------------------------------

/// Days since 1970-01-01 for a y/m/d in the proleptic Gregorian calendar.
fn daysFromCivil(y: i64, m: u32, d: u32) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe: i64 = yy - era * 400;
    const mp: i64 = @intCast((m + 9) % 12);
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: u32, d: u32 };

/// y/m/d for a count of days since 1970-01-01.
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: u32) u32 {
    const table = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (m == 2 and isLeap(y)) return 29;
    return table[m - 1];
}

const Parts = struct {
    year: i64,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    nano: u32,
};

/// Decompose an epoch second (plus sub-second nanos) into civil parts.
fn partsFromEpoch(epoch_sec: i64, nano: u32) Parts {
    const days = @divFloor(epoch_sec, 86_400);
    var rem = epoch_sec - days * 86_400; // 0..86399
    const c = civilFromDays(days);
    const hour: u32 = @intCast(@divFloor(rem, 3600));
    rem -= @as(i64, hour) * 3600;
    const minute: u32 = @intCast(@divFloor(rem, 60));
    const second: u32 = @intCast(rem - @as(i64, minute) * 60);
    return .{
        .year = c.y,
        .month = c.m,
        .day = c.d,
        .hour = hour,
        .minute = minute,
        .second = second,
        .nano = nano,
    };
}

fn epochFromCivil(p: Parts) i64 {
    const days = daysFromCivil(p.year, p.month, p.day);
    return days * 86_400 + @as(i64, p.hour) * 3600 + @as(i64, p.minute) * 60 + @as(i64, p.second);
}

// -------------------------------------------------------------------------
// IANA timezone offsets (TZif / system zoneinfo)
// -------------------------------------------------------------------------

/// UTC offset in seconds for a tz id at a given UTC instant. `"Z"` / `"UTC"`
/// are offset 0. Unknown ids return null so callers fall back to UTC, matching
/// the Rust path where `parse_tz` returned `None`.
fn tzOffsetAtUtc(allocator: std.mem.Allocator, id: []const u8, epoch_sec: i64) ?i32 {
    if (std.mem.eql(u8, id, "Z") or std.mem.eql(u8, id, "UTC")) return 0;
    const data = readZoneInfo(allocator, id) catch return null;
    defer allocator.free(data);
    return tzifOffsetUtc(data, epoch_sec);
}

/// Resolve a local (wall-clock) instant to a UTC offset for `id`. Mirrors the
/// "single" local-time semantics: the offset whose application reproduces the
/// requested local time. Returns null on unknown id, leaving UTC fallback.
fn tzOffsetForLocal(allocator: std.mem.Allocator, id: []const u8, local_epoch: i64) ?i32 {
    if (std.mem.eql(u8, id, "Z") or std.mem.eql(u8, id, "UTC")) return 0;
    const data = readZoneInfo(allocator, id) catch return null;
    defer allocator.free(data);
    return tzifOffsetLocal(data, local_epoch);
}

fn readZoneInfo(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    // Reject traversal / absolute ids before touching the filesystem.
    if (id.len == 0 or id[0] == '/' or std.mem.indexOf(u8, id, "..") != null) {
        return error.BadZone;
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/usr/share/zoneinfo/{s}", .{id}) catch return error.BadZone;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadZone,
    };
}

const TzifEntry = struct {
    transition: i64,
    offset: i32,
};

/// A TZif buffer's parsed transition table: the initial (pre-history) offset
/// and the chronologically ordered transitions.
const TzifTable = struct {
    initial_offset: i32,
    entries: []TzifEntry,
};

fn parseTzif(allocator: std.mem.Allocator, data: []const u8) ?TzifTable {
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "TZif")) return null;
    const version = data[4];
    const first = parseTzifBlock(allocator, data, 0, 4) catch return null;
    if (version == '2' or version == '3') {
        // Skip the v1 block and parse the 64-bit block that follows.
        const v1_len = tzifBlockLen(data, 0, 4) orelse return first;
        if (v1_len >= data.len) return first;
        if (data.len < v1_len + 44 or !std.mem.eql(u8, data[v1_len .. v1_len + 4], "TZif")) return first;
        if (parseTzifBlock(allocator, data, v1_len, 8)) |second| {
            allocator.free(first.entries);
            return second;
        } else |_| {
            return first;
        }
    }
    return first;
}

fn readBe(comptime T: type, b: []const u8) T {
    return std.mem.readInt(T, b[0..@sizeOf(T)], .big);
}

const TzifCounts = struct {
    isutcnt: u32,
    isstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,
};

fn readCounts(data: []const u8, base: usize) TzifCounts {
    return .{
        .isutcnt = readBe(u32, data[base + 20 .. base + 24]),
        .isstdcnt = readBe(u32, data[base + 24 .. base + 28]),
        .leapcnt = readBe(u32, data[base + 28 .. base + 32]),
        .timecnt = readBe(u32, data[base + 32 .. base + 36]),
        .typecnt = readBe(u32, data[base + 36 .. base + 40]),
        .charcnt = readBe(u32, data[base + 40 .. base + 44]),
    };
}

/// Byte length of the TZif block starting at `base` (header + body), used to
/// step from the v1 block to the v2/v3 block. `time_size` is 4 (v1) or 8 (v2).
fn tzifBlockLen(data: []const u8, base: usize, time_size: usize) ?usize {
    if (base + 44 > data.len) return null;
    const c = readCounts(data, base);
    const leap_size: usize = if (time_size == 8) 12 else 8;
    const body = c.timecnt * time_size + c.timecnt * 1 + c.typecnt * 6 +
        c.charcnt + c.leapcnt * leap_size + c.isstdcnt + c.isutcnt;
    return base + 44 + body;
}

fn parseTzifBlock(allocator: std.mem.Allocator, data: []const u8, base: usize, time_size: usize) !TzifTable {
    if (base + 44 > data.len) return error.Bad;
    const c = readCounts(data, base);
    var pos = base + 44;
    const transitions_pos = pos;
    pos += c.timecnt * time_size;
    const indices_pos = pos;
    pos += c.timecnt;
    const types_pos = pos;
    pos += c.typecnt * 6;
    if (pos > data.len) return error.Bad;

    // ttinfo offsets (utoff is the first i32 of each 6-byte record).
    const type_offsets = try allocator.alloc(i32, @max(c.typecnt, 1));
    defer allocator.free(type_offsets);
    var ti: usize = 0;
    while (ti < c.typecnt) : (ti += 1) {
        type_offsets[ti] = readBe(i32, data[types_pos + ti * 6 .. types_pos + ti * 6 + 4]);
    }

    const entries = try allocator.alloc(TzifEntry, c.timecnt);
    errdefer allocator.free(entries);
    var k: usize = 0;
    while (k < c.timecnt) : (k += 1) {
        const t: i64 = if (time_size == 8)
            readBe(i64, data[transitions_pos + k * 8 .. transitions_pos + k * 8 + 8])
        else
            @as(i64, readBe(i32, data[transitions_pos + k * 4 .. transitions_pos + k * 4 + 4]));
        const idx = data[indices_pos + k];
        const off = if (idx < c.typecnt) type_offsets[idx] else 0;
        entries[k] = .{ .transition = t, .offset = off };
    }

    // Initial offset: the first ttinfo, else 0.
    const initial: i32 = if (c.typecnt > 0) type_offsets[0] else 0;
    return .{ .initial_offset = initial, .entries = entries };
}

fn tzifOffsetUtc(data: []const u8, epoch_sec: i64) ?i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const table = parseTzif(arena.allocator(), data) orelse return null;
    var off = table.initial_offset;
    for (table.entries) |e| {
        if (epoch_sec >= e.transition) off = e.offset else break;
    }
    return off;
}

fn tzifOffsetLocal(data: []const u8, local_epoch: i64) ?i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const table = parseTzif(arena.allocator(), data) orelse return null;
    // Walk transitions in local time and pick the segment whose local span
    // contains `local_epoch` (local = utc + offset).
    var off = table.initial_offset;
    for (table.entries) |e| {
        const seg_local_start = e.transition + e.offset;
        if (local_epoch >= seg_local_start) off = e.offset else break;
    }
    return off;
}

// -------------------------------------------------------------------------
// Array result helper
// -------------------------------------------------------------------------

fn makeLongArray(allocator: std.mem.Allocator, values: []const i64) std.mem.Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, values.len);
    for (values) |v| list.appendAssumeCapacity(.{ .Long = v });
    return try runtime.ArrayData.initPacked(allocator, PrimitiveArrayKind.Long, list.items);
}

// -------------------------------------------------------------------------
// Bindings
// -------------------------------------------------------------------------

fn instantToLocalParts(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const epoch_sec = argLong(ctx, 0) catch return badLongArg(ctx.allocator, 0);
    // Kotlin Int nanos reinterpreted as the u32 the conversion expects.
    const nanos: u32 = @bitCast(argI32(ctx, 1) catch return badLongArg(ctx.allocator, 1));
    const tz_id = argStr(ctx, 2) catch return badStrArg(ctx.allocator, 2);
    defer ctx.allocator.free(tz_id);

    const offset = tzOffsetAtUtc(ctx.allocator, tz_id, epoch_sec) orelse 0;
    const p = partsFromEpoch(epoch_sec + @as(i64, offset), nanos);
    return ok(try makeLongArray(ctx.allocator, &.{
        p.year,
        @as(i64, p.month),
        @as(i64, p.day),
        @as(i64, p.hour),
        @as(i64, p.minute),
        @as(i64, p.second),
        @as(i64, p.nano),
    }));
}

fn localToInstant(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const year = argI32(ctx, 0) catch return badLongArg(ctx.allocator, 0);
    const month: i32 = argI32(ctx, 1) catch return badLongArg(ctx.allocator, 1);
    const day: i32 = argI32(ctx, 2) catch return badLongArg(ctx.allocator, 2);
    const hour: i32 = argI32(ctx, 3) catch return badLongArg(ctx.allocator, 3);
    const minute: i32 = argI32(ctx, 4) catch return badLongArg(ctx.allocator, 4);
    const second: i32 = argI32(ctx, 5) catch return badLongArg(ctx.allocator, 5);
    const nano: i32 = argI32(ctx, 6) catch return badLongArg(ctx.allocator, 6);
    const tz_id = argStr(ctx, 7) catch return badStrArg(ctx.allocator, 7);
    defer ctx.allocator.free(tz_id);

    if (month < 1 or month > 12 or day < 1 or
        day > daysInMonth(@as(i64, year), @intCast(month)))
    {
        return typeErr(ctx.allocator, "invalid date {d}-{d}-{d}", .{ year, month, day });
    }
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or
        second < 0 or second > 59 or nano < 0 or nano > 999_999_999)
    {
        return typeErrLit("invalid time-of-day");
    }
    const local_parts: Parts = .{
        .year = @as(i64, year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .nano = @bitCast(nano),
    };
    const local_epoch = epochFromCivil(local_parts);
    const offset = tzOffsetForLocal(ctx.allocator, tz_id, local_epoch) orelse 0;
    const utc_epoch = local_epoch - @as(i64, offset);
    return ok(try makeLongArray(ctx.allocator, &.{ utc_epoch, @as(i64, local_parts.nano) }));
}

/// RFC-3339 / ISO-8601 rendering with chrono's `AutoSi` fractional digits:
/// trailing zero groups are dropped, picking 0/3/6/9 fraction digits.
fn instantToString(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const epoch_sec = argLong(ctx, 0) catch return badLongArg(ctx.allocator, 0);
    const nanos: u32 = @bitCast(argI32(ctx, 1) catch return badLongArg(ctx.allocator, 1));
    const p = partsFromEpoch(epoch_sec, nanos);

    const head = try std.fmt.allocPrint(
        ctx.allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
        .{ @abs(p.year), p.month, p.day, p.hour, p.minute, p.second },
    );
    defer ctx.allocator.free(head);

    const owned = if (p.nano == 0)
        try std.fmt.allocPrint(ctx.allocator, "{s}Z", .{head})
    else if (p.nano % 1_000_000 == 0)
        try std.fmt.allocPrint(ctx.allocator, "{s}.{d:0>3}Z", .{ head, p.nano / 1_000_000 })
    else if (p.nano % 1_000 == 0)
        try std.fmt.allocPrint(ctx.allocator, "{s}.{d:0>6}Z", .{ head, p.nano / 1_000 })
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}.{d:0>9}Z", .{ head, p.nano });

    return ok(.{ .String = try runtime.strInitOwned(ctx.allocator, owned) });
}

fn parseInstant(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const input = argStr(ctx, 0) catch return badStrArg(ctx.allocator, 0);
    defer ctx.allocator.free(input);
    const parsed = parseRfc3339(input) orelse
        return typeErr(ctx.allocator, "failed to parse Instant `{s}`", .{input});
    return ok(try makeLongArray(ctx.allocator, &.{ parsed.epoch_sec, @as(i64, parsed.nanos) }));
}

fn validateTimeZone(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const id = argStr(ctx, 0) catch return badStrArg(ctx.allocator, 0);
    defer ctx.allocator.free(id);
    const valid = std.mem.eql(u8, id, "Z") or std.mem.eql(u8, id, "UTC") or
        zoneExists(ctx.allocator, id);
    return ok(.{ .Bool = valid });
}

fn zoneExists(allocator: std.mem.Allocator, id: []const u8) bool {
    const data = readZoneInfo(allocator, id) catch return false;
    defer allocator.free(data);
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "TZif");
}

/// Apply a calendar period in the given tz. Arguments: epochSeconds, nanos,
/// years, months, days, hours, minutes, seconds, nanoAdjust, tzId. Returns
/// `[epochSeconds, nanos]`.
fn addPeriod(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const epoch_sec = argLong(ctx, 0) catch return badLongArg(ctx.allocator, 0);
    const nanos: u32 = @bitCast(argI32(ctx, 1) catch return badLongArg(ctx.allocator, 1));
    const years = argI32(ctx, 2) catch return badLongArg(ctx.allocator, 2);
    const months = argI32(ctx, 3) catch return badLongArg(ctx.allocator, 3);
    const days = argI32(ctx, 4) catch return badLongArg(ctx.allocator, 4);
    const hours = argI32(ctx, 5) catch return badLongArg(ctx.allocator, 5);
    const minutes = argI32(ctx, 6) catch return badLongArg(ctx.allocator, 6);
    const seconds = argI32(ctx, 7) catch return badLongArg(ctx.allocator, 7);
    const nano_adjust = argLong(ctx, 8) catch return badLongArg(ctx.allocator, 8);
    const tz_id = argStr(ctx, 9) catch return badStrArg(ctx.allocator, 9);
    defer ctx.allocator.free(tz_id);

    const total_months = @as(i64, years) * 12 + @as(i64, months);

    // Shift in local wall-clock time, mirroring chrono's fixed-offset path:
    // capture the zone offset at the source instant, apply months on the
    // local civil date, then re-derive UTC via that same offset window.
    const offset = tzOffsetAtUtc(ctx.allocator, tz_id, epoch_sec) orelse 0;
    var local = partsFromEpoch(epoch_sec + @as(i64, offset), nanos);

    if (total_months != 0) {
        local = addMonths(local, total_months) orelse
            return typeErrLit("DateTimePeriod month overflow");
    }

    var local_epoch = epochFromCivil(local);
    const secs = @as(i64, days) * 86_400 + @as(i64, hours) * 3_600 +
        @as(i64, minutes) * 60 + @as(i64, seconds);
    const total_nanos = nano_adjust + secs * 1_000_000_000;
    const carry_secs = @divFloor(total_nanos, 1_000_000_000);
    var nano_total = @as(i64, local.nano) + @mod(total_nanos, 1_000_000_000);
    local_epoch += carry_secs;
    if (nano_total >= 1_000_000_000) {
        nano_total -= 1_000_000_000;
        local_epoch += 1;
    }

    const utc_epoch = local_epoch - @as(i64, offset);
    return ok(try makeLongArray(ctx.allocator, &.{ utc_epoch, nano_total }));
}

/// Add (or subtract) whole months to a civil date, clamping the day to the
/// target month's length, matching chrono's `checked_add_months` semantics.
fn addMonths(p: Parts, total_months: i64) ?Parts {
    const m0: i64 = @as(i64, p.month) - 1 + total_months;
    const new_year = p.year + @divFloor(m0, 12);
    const new_month: u32 = @intCast(@mod(m0, 12) + 1);
    const dim = daysInMonth(new_year, new_month);
    const new_day = if (p.day > dim) dim else p.day;
    return .{
        .year = new_year,
        .month = new_month,
        .day = new_day,
        .hour = p.hour,
        .minute = p.minute,
        .second = p.second,
        .nano = p.nano,
    };
}

// -------------------------------------------------------------------------
// RFC-3339 parsing
// -------------------------------------------------------------------------

const ParsedInstant = struct { epoch_sec: i64, nanos: u32 };

fn parseDigits(s: []const u8, n: usize) ?u32 {
    if (s.len < n) return null;
    var v: u32 = 0;
    for (s[0..n]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Parse an RFC-3339 timestamp (date-time with `T`/space separator and a
/// `Z`/numeric offset), returning the UTC epoch and sub-second nanos.
fn parseRfc3339(input: []const u8) ?ParsedInstant {
    var s = input;
    if (s.len < 20) return null;
    const year_i = parseSignedYear(s) orelse return null;
    s = s[year_i.consumed..];
    if (s.len < 1 or s[0] != '-') return null;
    s = s[1..];
    const month = parseDigits(s, 2) orelse return null;
    s = s[2..];
    if (s.len < 1 or s[0] != '-') return null;
    s = s[1..];
    const day = parseDigits(s, 2) orelse return null;
    s = s[2..];
    if (s.len < 1 or (s[0] != 'T' and s[0] != 't' and s[0] != ' ')) return null;
    s = s[1..];
    const hour = parseDigits(s, 2) orelse return null;
    s = s[2..];
    if (s.len < 1 or s[0] != ':') return null;
    s = s[1..];
    const minute = parseDigits(s, 2) orelse return null;
    s = s[2..];
    if (s.len < 1 or s[0] != ':') return null;
    s = s[1..];
    const second = parseDigits(s, 2) orelse return null;
    s = s[2..];

    var nanos: u32 = 0;
    if (s.len > 0 and s[0] == '.') {
        s = s[1..];
        var frac: [9]u8 = .{ '0', '0', '0', '0', '0', '0', '0', '0', '0' };
        var i: usize = 0;
        while (s.len > 0 and s[0] >= '0' and s[0] <= '9') {
            if (i < 9) {
                frac[i] = s[0];
            }
            i += 1;
            s = s[1..];
        }
        if (i == 0) return null;
        nanos = parseDigits(&frac, 9) orelse return null;
    }

    // Offset: Z/z or +-HH:MM.
    var offset_sec: i64 = 0;
    if (s.len == 0) return null;
    if (s[0] == 'Z' or s[0] == 'z') {
        s = s[1..];
    } else if (s[0] == '+' or s[0] == '-') {
        const sign: i64 = if (s[0] == '-') -1 else 1;
        s = s[1..];
        const oh = parseDigits(s, 2) orelse return null;
        s = s[2..];
        if (s.len < 1 or s[0] != ':') return null;
        s = s[1..];
        const om = parseDigits(s, 2) orelse return null;
        s = s[2..];
        offset_sec = sign * (@as(i64, oh) * 3600 + @as(i64, om) * 60);
    } else {
        return null;
    }
    if (s.len != 0) return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year_i.year, month)) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    const local_epoch = epochFromCivil(.{
        .year = year_i.year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = @min(second, 59),
        .nano = nanos,
    });
    return .{ .epoch_sec = local_epoch - offset_sec, .nanos = nanos };
}

const YearParse = struct { year: i64, consumed: usize };

fn parseSignedYear(s: []const u8) ?YearParse {
    var i: usize = 0;
    var sign: i64 = 1;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        if (s[0] == '-') sign = -1;
        i = 1;
    }
    if (s.len < i + 4) return null;
    const y = parseDigits(s[i..], 4) orelse return null;
    return .{ .year = sign * @as(i64, y), .consumed = i + 4 };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn makeCtx(host: runtime.IntrinsicHost, out: runtime.Output, args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = out,
        .host = host,
        .allocator = testing.allocator,
    };
}

const Harness = struct {
    h: runtime.NoopHost,
    cap: runtime.CaptureOutput,

    fn init() Harness {
        return .{
            .h = runtime.NoopHost.init(testing.allocator),
            .cap = runtime.CaptureOutput.init(testing.allocator),
        };
    }
    fn deinit(self: *Harness) void {
        self.h.deinit();
        self.cap.deinit();
    }
    fn ctx(self: *Harness, args: []const Value) CallCtx {
        return makeCtx(self.h.host(), self.cap.output(), args);
    }
};

fn freeArray(v: Value) void {
    // Releasing the last handle deinits the backing buffer via the cell's own
    // allocator; no manual inner deinit.
    v.Array.deinitStorage();
}

fn freeString(v: Value) void {
    // The intrinsics mint these via `initOwned`, so the cell owns its byte
    // buffer and frees it on the final `deinit` under reclaim.
    v.String.deinit();
}

test "civil-day round trip across the epoch and a leap day" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const c = civilFromDays(0);
    try testing.expectEqual(@as(i64, 1970), c.y);
    try testing.expectEqual(@as(u32, 1), c.m);
    try testing.expectEqual(@as(u32, 1), c.d);

    // 2024-02-29 is a real leap day.
    const d = daysFromCivil(2024, 2, 29);
    const back = civilFromDays(d);
    try testing.expectEqual(@as(i64, 2024), back.y);
    try testing.expectEqual(@as(u32, 2), back.m);
    try testing.expectEqual(@as(u32, 29), back.d);
}

test "instantToLocalParts decomposes a UTC instant" {
    var hh = Harness.init();
    defer hh.deinit();
    var tz = try runtime.strInit(testing.allocator, "UTC");
    defer tz.deinit();
    const args = [_]Value{ .{ .Long = 1_700_000_000 }, .{ .Int = 0 }, .{ .String = tz } };
    var ctx = hh.ctx(&args);
    const r = try instantToLocalParts(&ctx);
    try testing.expect(r == .ok);
    defer freeArray(r.ok);
    const items = try r.ok.Array.snapshot(testing.allocator);
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(i64, 2023), items[0].Long);
    try testing.expectEqual(@as(i64, 11), items[1].Long);
    try testing.expectEqual(@as(i64, 14), items[2].Long);
    try testing.expectEqual(@as(i64, 22), items[3].Long);
    try testing.expectEqual(@as(i64, 13), items[4].Long);
    try testing.expectEqual(@as(i64, 20), items[5].Long);
    try testing.expectEqual(@as(i64, 0), items[6].Long);
}

test "localToInstant is the inverse in UTC" {
    var hh = Harness.init();
    defer hh.deinit();
    var tz = try runtime.strInit(testing.allocator, "UTC");
    defer tz.deinit();
    const args = [_]Value{
        .{ .Int = 2023 }, .{ .Int = 11 }, .{ .Int = 14 },
        .{ .Int = 22 },   .{ .Int = 13 }, .{ .Int = 20 },
        .{ .Int = 0 },    .{ .String = tz },
    };
    var ctx = hh.ctx(&args);
    const r = try localToInstant(&ctx);
    try testing.expect(r == .ok);
    defer freeArray(r.ok);
    const items = try r.ok.Array.snapshot(testing.allocator);
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(i64, 1_700_000_000), items[0].Long);
    try testing.expectEqual(@as(i64, 0), items[1].Long);
}

test "localToInstant rejects an impossible date" {
    var hh = Harness.init();
    defer hh.deinit();
    var tz = try runtime.strInit(testing.allocator, "UTC");
    defer tz.deinit();
    const args = [_]Value{
        .{ .Int = 2023 }, .{ .Int = 2 },  .{ .Int = 30 },
        .{ .Int = 0 },    .{ .Int = 0 },  .{ .Int = 0 },
        .{ .Int = 0 },    .{ .String = tz },
    };
    var ctx = hh.ctx(&args);
    const r = try localToInstant(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    testing.allocator.free(r.err.Type);
}

test "instantToString renders RFC-3339 with AutoSi fractions" {
    var hh = Harness.init();
    defer hh.deinit();
    {
        const args = [_]Value{ .{ .Long = 1_700_000_000 }, .{ .Int = 0 } };
        var ctx = hh.ctx(&args);
        const r = try instantToString(&ctx);
        try testing.expect(r == .ok);
        defer freeString(r.ok);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("2023-11-14T22:13:20Z", g.get().bytes);
    }
    {
        const args = [_]Value{ .{ .Long = 0 }, .{ .Int = 123_000_000 } };
        var ctx = hh.ctx(&args);
        const r = try instantToString(&ctx);
        try testing.expect(r == .ok);
        defer freeString(r.ok);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("1970-01-01T00:00:00.123Z", g.get().bytes);
    }
    {
        const args = [_]Value{ .{ .Long = 0 }, .{ .Int = 1 } };
        var ctx = hh.ctx(&args);
        const r = try instantToString(&ctx);
        try testing.expect(r == .ok);
        defer freeString(r.ok);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("1970-01-01T00:00:00.000000001Z", g.get().bytes);
    }
}

test "parseInstant round-trips and normalizes offsets" {
    var hh = Harness.init();
    defer hh.deinit();
    {
        var s = try runtime.strInit(testing.allocator, "2023-11-14T22:13:20Z");
        defer s.deinit();
        const args = [_]Value{.{ .String = s }};
        var ctx = hh.ctx(&args);
        const r = try parseInstant(&ctx);
        try testing.expect(r == .ok);
        defer freeArray(r.ok);
        const items = try r.ok.Array.snapshot(testing.allocator);
        defer testing.allocator.free(items);
        try testing.expectEqual(@as(i64, 1_700_000_000), items[0].Long);
        try testing.expectEqual(@as(i64, 0), items[1].Long);
    }
    {
        // +02:00 wall clock is the same instant two hours earlier in UTC.
        var s = try runtime.strInit(testing.allocator, "2023-11-15T00:13:20+02:00");
        defer s.deinit();
        const args = [_]Value{.{ .String = s }};
        var ctx = hh.ctx(&args);
        const r = try parseInstant(&ctx);
        try testing.expect(r == .ok);
        defer freeArray(r.ok);
        const items = try r.ok.Array.snapshot(testing.allocator);
        defer testing.allocator.free(items);
        try testing.expectEqual(@as(i64, 1_700_000_000), items[0].Long);
    }
}

test "parseInstant rejects malformed input" {
    var hh = Harness.init();
    defer hh.deinit();
    var s = try runtime.strInit(testing.allocator, "not-a-date");
    defer s.deinit();
    const args = [_]Value{.{ .String = s }};
    var ctx = hh.ctx(&args);
    const r = try parseInstant(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    testing.allocator.free(r.err.Type);
}

test "validateTimeZone accepts UTC and Z, rejects garbage" {
    var hh = Harness.init();
    defer hh.deinit();
    inline for (.{ "UTC", "Z" }) |id| {
        var s = try runtime.strInit(testing.allocator, id);
        defer s.deinit();
        const args = [_]Value{.{ .String = s }};
        var ctx = hh.ctx(&args);
        const r = try validateTimeZone(&ctx);
        try testing.expect(r == .ok);
        try testing.expectEqual(true, r.ok.Bool);
    }
    {
        var s = try runtime.strInit(testing.allocator, "Not/AZone");
        defer s.deinit();
        const args = [_]Value{.{ .String = s }};
        var ctx = hh.ctx(&args);
        const r = try validateTimeZone(&ctx);
        try testing.expect(r == .ok);
        try testing.expectEqual(false, r.ok.Bool);
    }
}

test "addPeriod adds calendar months with day clamping in UTC" {
    var hh = Harness.init();
    defer hh.deinit();
    var tz = try runtime.strInit(testing.allocator, "UTC");
    defer tz.deinit();
    // 2023-01-31 + 1 month clamps to 2023-02-28.
    const start = epochFromCivil(.{
        .year = 2023, .month = 1, .day = 31,
        .hour = 0,    .minute = 0, .second = 0,
        .nano = 0,
    });
    const args = [_]Value{
        .{ .Long = start }, .{ .Int = 0 }, .{ .Int = 0 }, .{ .Int = 1 },
        .{ .Int = 0 },      .{ .Int = 0 }, .{ .Int = 0 }, .{ .Int = 0 },
        .{ .Long = 0 },     .{ .String = tz },
    };
    var ctx = hh.ctx(&args);
    const r = try addPeriod(&ctx);
    try testing.expect(r == .ok);
    defer freeArray(r.ok);
    const items = try r.ok.Array.snapshot(testing.allocator);
    defer testing.allocator.free(items);
    const p = partsFromEpoch(items[0].Long, 0);
    try testing.expectEqual(@as(i64, 2023), p.year);
    try testing.expectEqual(@as(u32, 2), p.month);
    try testing.expectEqual(@as(u32, 28), p.day);
}

test "addPeriod applies a time delta with nano carry" {
    var hh = Harness.init();
    defer hh.deinit();
    var tz = try runtime.strInit(testing.allocator, "UTC");
    defer tz.deinit();
    const args = [_]Value{
        .{ .Long = 1_000 },       .{ .Int = 500_000_000 }, .{ .Int = 0 }, .{ .Int = 0 },
        .{ .Int = 0 },            .{ .Int = 0 },           .{ .Int = 0 }, .{ .Int = 5 },
        .{ .Long = 600_000_000 }, .{ .String = tz },
    };
    var ctx = hh.ctx(&args);
    const r = try addPeriod(&ctx);
    try testing.expect(r == .ok);
    defer freeArray(r.ok);
    const items = try r.ok.Array.snapshot(testing.allocator);
    defer testing.allocator.free(items);
    // +5s plus 0.6s nano on top of 0.5s carries one second.
    try testing.expectEqual(@as(i64, 1_006), items[0].Long);
    try testing.expectEqual(@as(i64, 100_000_000), items[1].Long);
}

test "argument type errors surface as RuntimeError.Type" {
    var hh = Harness.init();
    defer hh.deinit();
    const args = [_]Value{.{ .Bool = true }};
    var ctx = hh.ctx(&args);
    const r = try instantToString(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    testing.allocator.free(r.err.Type);
}

test "hostBindings registers every native symbol" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("kotlinx.datetime.__kxdt_currentTimeMillis") != null);
    try testing.expect(b.resolve("kotlinx.datetime.__kxdt_localToInstant") != null);
    try testing.expect(b.resolve("kotlinx.datetime.__kxdt_addPeriod") != null);
    try testing.expectEqual(@as(usize, 9), b.len());
}

test "currentTimeMillis returns a positive Long" {
    var hh = Harness.init();
    defer hh.deinit();
    var ctx = hh.ctx(&.{});
    const r = try currentTimeMillis(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Long);
    try testing.expect(r.ok.Long > 0);
}
