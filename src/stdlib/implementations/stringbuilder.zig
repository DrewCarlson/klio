//! StringBuilder stdlib intrinsics.
//!
//! A `StringBuilder` value is an `ObjRef(std.ArrayList(u8))` holding the buffer
//! as UTF-8 bytes; the range and index operations Kotlin defines over UTF-16
//! code units convert between that buffer and a `[]u16` view as needed.

const std = @import("std");
const runtime = @import("runtime");
const string = @import("string.zig");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;

const Buffer = std.ArrayList(u8);
const StringBuilderRef = ObjRef(Buffer);

const Allocator = std.mem.Allocator;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

/// Return the receiver StringBuilder, since the fluent methods hand `this` back
/// for chaining. Dispatch writes the host result into a register that takes
/// ownership, so the borrowed receiver is retained first.
fn okSb(sb: StringBuilderRef) EvalResult {
    const v = Value{ .StringBuilder = sb };
    v.retain();
    return .{ .ok = v };
}

fn errResult(e: RuntimeError) EvalResult {
    return .{ .err = e };
}

fn makeException(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!Value {
    return try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, fqn),
        .message = .from(if (message) |m| try runtime.strInit(allocator, m) else null),
        .cause = null,
    });
}

fn thrown(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalResult {
    return errResult(.{ .Thrown = try makeException(allocator, fqn, message) });
}

fn sbArg(args: []const Value) ?StringBuilderRef {
    if (args.len > 0) {
        if (args[0] == .StringBuilder) return args[0].StringBuilder;
    }
    return null;
}

fn sbTypeError(comptime what: []const u8) RuntimeError {
    return .{ .Type = what ++ " requires a StringBuilder receiver" };
}

fn setBuf(buf: *Buffer, allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, bytes);
}

fn encodeUtf16(allocator: Allocator, s: []const u8) Allocator.Error![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (runtime.isWtf8SurrogateAt(s, i)) {
            try out.append(allocator, runtime.wtf8SurrogateUnit(s, i));
            i += 3;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch s[i];
        if (cp <= 0xFFFF) {
            try out.append(allocator, @intCast(cp));
        } else {
            const adjusted = cp - 0x10000;
            try out.append(allocator, @intCast(0xD800 + (adjusted >> 10)));
            try out.append(allocator, @intCast(0xDC00 + (adjusted & 0x3FF)));
        }
        i = end;
    }
    return out.toOwnedSlice(allocator);
}

fn fromUtf16Lossy(allocator: Allocator, units: []const u16) Allocator.Error![]u8 {
    return runtime.charUnitsToString(allocator, units);
}

fn charUnitToString(allocator: Allocator, unit: u16) Allocator.Error![]u8 {
    return runtime.charUnitToString(allocator, unit);
}

const SbMemo = runtime.SbMemo;

pub fn sbMemoInvalidate(cell: usize) void {
    runtime.sbMemoInvalidate(cell);
}

fn sbMut(sb: anytype) @TypeOf(sb.borrowMut()) {
    runtime.sbMemoInvalidate(@intFromPtr(sb.cell));
    return sb.borrowMut();
}

/// Whether every byte of the builder is ASCII, so a UTF-16 index is a byte index: known from
/// its header with no scan where the last change kept it so, else scanned.
fn asciiBytes(sb: anytype, items: []const u8) bool {
    if (runtime.sbAsciiLen(@intFromPtr(sb.cell), items.len) != null) return true;
    for (items) |b| if (b >= 0x80) return false;
    return true;
}

fn allAscii(bytes: []const u8) bool {
    for (bytes) |b| if (b >= 0x80) return false;
    return true;
}

fn sbMemoFor(sb: anytype, items: []const u8) *SbMemo {
    return runtime.sbMemoFor(@intFromPtr(sb.cell), items);
}

fn sbUnitAt(m: *SbMemo, s: []const u8, idx: usize) ?u16 {
    return runtime.sbUnitAt(m, s, idx);
}

fn charCount(s: []const u8) usize {
    return runtime.sbCharCount(s);
}

fn bufUnits(a: Allocator, s: []const u8) Allocator.Error![]u16 {
    return encodeUtf16(a, s);
}

fn setBufUnits(buf: *Buffer, a: Allocator, units: []const u16) Allocator.Error!void {
    const bytes = try runtime.charUnitsToString(a, units);
    defer a.free(bytes);
    try setBuf(buf, a, bytes);
}

fn displayValue(allocator: Allocator, v: Value) Allocator.Error![]u8 {
    return v.display(allocator);
}

fn appendValue(buf: *Buffer, allocator: Allocator, v: Value) Allocator.Error!void {
    switch (v) {
        .Null => try buf.appendSlice(allocator, "null"),
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            try buf.appendSlice(allocator, g.get().bytes);
        },
        .Char => |c| {
            const piece = try charUnitToString(allocator, c);
            defer allocator.free(piece);
            try buf.appendSlice(allocator, piece);
        },
        else => {
            const piece = try displayValue(allocator, v);
            defer allocator.free(piece);
            try buf.appendSlice(allocator, piece);
        },
    }
}

fn instanceIsCharSequence(v: *const Value) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    for (cg.get().supertype_names) |s| {
        if (std.mem.eql(u8, s, "CharSequence")) return true;
    }
    return false;
}

/// Guard an append or insert: when the argument's length is knowable up front
/// and the combined UTF-16 length exceeds `Int.MAX_VALUE`, throw OutOfMemoryError
/// before materialising anything, as the JVM builder grows capacity first and
/// never reads the overflowing CharSequence's chars.
fn appendOverflowGuard(ctx: *CallCtx, sb: StringBuilderRef, v: *const Value) Allocator.Error!?EvalResult {
    const add: i64 = switch (v.*) {
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk @intCast(g.get().u16_len);
        },
        .StringBuilder => |other| blk: {
            const g = other.borrow();
            defer g.deinit();
            break :blk @intCast(g.get().items.len);
        },
        .Instance => blk: {
            if (!instanceIsCharSequence(v)) return null;
            const r = ctx.host.callWellKnown(v, .length, &.{}, ctx.out) catch return null;
            const res = r orelse return null;
            switch (res) {
                .ok => |lv| break :blk lv.asI64() orelse return null,
                .err => return null,
            }
        },
        else => return null,
    };
    const cur: i64 = blk: {
        const g = sb.borrow();
        defer g.deinit();
        break :blk @intCast(g.get().items.len);
    };
    if (cur + add > std.math.maxInt(i32)) {
        return try thrown(ctx.allocator, "klio.OutOfMemoryError", "Requested character sequence exceeds the maximum length");
    }
    return null;
}

/// The text `append(value)` and `insert(_, value)` write. Rendered before the
/// receiver buffer is borrowed, so a user `toString()` runs without that borrow.
fn renderPiece(ctx: *CallCtx, v: Value) Allocator.Error![]u8 {
    const a = ctx.allocator;
    switch (v) {
        .Null => return a.dupe(u8, "null"),
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return a.dupe(u8, g.get().bytes);
        },
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            return a.dupe(u8, g.get().items);
        },
        .Char => |c| return charUnitToString(a, c),
        .Array => |arr| {
            const elems = try arr.snapshot(a);
            defer if (runtime.freeScratch()) a.free(elems);
            var all_char = true;
            for (elems) |e| {
                if (e != .Char) {
                    all_char = false;
                    break;
                }
            }
            if (all_char) {
                var buf: Buffer = .empty;
                errdefer buf.deinit(a);
                for (elems) |e| {
                    const piece = try charUnitToString(a, e.Char);
                    defer a.free(piece);
                    try buf.appendSlice(a, piece);
                }
                return buf.toOwnedSlice(a);
            }
        },
        // `append(Any?)` calls the value's `toString()`, so a user override and a
        // container's own rendering fire.
        .Instance, .List, .Set, .Map, .Pair, .Triple, .Result => {
            if (try ctx.host.callWellKnown(&v, .to_string, &.{}, ctx.out)) |res| {
                switch (res) {
                    .ok => |sv| if (sv == .String) {
                        const g = sv.String.borrow();
                        defer g.deinit();
                        return a.dupe(u8, g.get().bytes);
                    },
                    .err => {},
                }
            }
        },
        else => {},
    }
    return displayValue(a, v);
}

fn valueToUtf16(allocator: Allocator, v: Value) Allocator.Error!?[]u16 {
    switch (v) {
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return try encodeUtf16(allocator, g.get().bytes);
        },
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            return try encodeUtf16(allocator, g.get().items);
        },
        .Char => |u| {
            const out = try allocator.alloc(u16, 1);
            out[0] = u;
            return out;
        },
        .Array => |a| {
            const elems = try a.snapshot(allocator);
            defer if (runtime.freeScratch()) allocator.free(elems);
            var out = try allocator.alloc(u16, elems.len);
            for (elems, 0..) |e, i| {
                if (e == .Char) {
                    out[i] = e.Char;
                } else {
                    allocator.free(out);
                    return null;
                }
            }
            return out;
        },
        else => return null,
    }
}

const UnitsResult = union(enum) { ok: []u16, err: RuntimeError };

/// The UTF-16 units in [start, end) of a program's own CharSequence, read as a
/// builder reads one: its `length` first, the range checked against it, then
/// `get` for each index of the range. The caller frees the units.
fn userSeqRange(ctx: *CallCtx, v: *const Value, start_arg: ?Value, end_arg: ?Value) Allocator.Error!UnitsResult {
    const a = ctx.allocator;
    const lr = (try ctx.host.callWellKnown(v, .length, &.{}, ctx.out)) orelse
        return .{ .err = .{ .Type = "the CharSequence has no length" } };
    const vlen: i64 = switch (lr) {
        .ok => |lv| lv.asI64() orelse 0,
        .err => |e| return .{ .err = e },
    };
    const start = if (start_arg) |sa| (sa.asI64() orelse 0) else 0;
    const end = if (end_arg) |ea| (ea.asI64() orelse vlen) else vlen;
    if (start < 0 or start > end or end > vlen) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start, end, vlen });
        defer if (runtime.freeScratch()) a.free(msg);
        return .{ .err = try rangeOob(a, msg) };
    }
    const out = try a.alloc(u16, @intCast(end - start));
    errdefer a.free(out);
    var i = start;
    while (i < end) : (i += 1) {
        const cr = (try ctx.host.callWellKnown(v, .char_at, &.{Value.newInt(i)}, ctx.out)) orelse {
            a.free(out);
            return .{ .err = .{ .Type = "the CharSequence has no get" } };
        };
        switch (cr) {
            .ok => |cv| out[@intCast(i - start)] = if (cv == .Char) cv.Char else 0,
            .err => |e| {
                a.free(out);
                return .{ .err = e };
            },
        }
    }
    return .{ .ok = out };
}

fn rangeOob(allocator: Allocator, msg: []const u8) Allocator.Error!RuntimeError {
    return .{ .Thrown = try makeException(allocator, "kotlin.IndexOutOfBoundsException", msg) };
}

/// A range of the builder or string itself, which Java checks with its string bounds check.
fn stringRangeOob(allocator: Allocator, msg: []const u8) Allocator.Error!RuntimeError {
    return .{ .Thrown = try makeException(allocator, "klio.StringIndexOutOfBoundsException", msg) };
}


pub fn string_ctor(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) {
        return ok(.{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "")) });
    }
    switch (ctx.args[0]) {
        // CharArray is a Value.Array, but `toCharArray` yields a Value.List of
        // chars, so accept either.
        .Array, .List => {
            const prim_is_byte: bool = switch (ctx.args[0]) {
                .Array => |arr| if (arr.primKind()) |p| (p == .Byte or p == .UByte) else false,
                else => false,
            };
            const elems: []Value = switch (ctx.args[0]) {
                .Array => |arr| try arr.snapshot(a),
                .List => |l| blk: {
                    const g = l.items.borrow();
                    defer g.deinit();
                    break :blk try a.dupe(Value, g.get().items);
                },
                else => unreachable,
            };
            defer if (runtime.freeScratch()) a.free(elems);

            var start: usize = 0;
            var count: usize = elems.len;
            if (ctx.args.len >= 3) {
                const off = ctx.args[1].asI64() orelse 0;
                const cnt = ctx.args[2].asI64() orelse 0;
                const size: i64 = @intCast(elems.len);
                if (off < 0 or cnt < 0 or off > size - cnt) {
                    const msg = try std.fmt.allocPrint(a, "Range [{d}, {d} + {d}) out of bounds for length {d}", .{ off, off, cnt, size });
                    defer if (runtime.freeScratch()) a.free(msg);
                    return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
                }
                start = @intCast(off);
                count = @intCast(cnt);
            }
            const end = @min(start +| count, elems.len);

            // `byteArrayOf` tags its array `prim = Byte` though its literal
            // elements arrive as `Int`, so dispatch keys off the array kind,
            // with an element-kind fallback.
            const first_is_byte = elems.len > start and (elems[start] == .Byte or elems[start] == .UByte);
            const is_bytes = prim_is_byte or first_is_byte;
            if (is_bytes) {
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(a);
                for (elems[start..end]) |v| {
                    const b: u8 = switch (v) {
                        .Byte => |x| @bitCast(x),
                        .UByte => |x| x,
                        .Int => |x| @truncate(@as(u32, @bitCast(x))),
                        else => 0,
                    };
                    try bytes.append(a, b);
                }
                const s = try utf8Lossy(a, bytes.items);
                return ok(.{ .String = try runtime.strInitOwned(a, s) });
            } else {
                var units = try a.alloc(u16, end - start);
                defer a.free(units);
                for (elems[start..end], 0..) |v, i| {
                    units[i] = switch (v) {
                        .Char => |c| c,
                        else => 0,
                    };
                }
                const s = try fromUtf16Lossy(a, units);
                return ok(.{ .String = try runtime.strInitOwned(a, s) });
            }
        },
        .String => |s| {
            const sg = s.borrow();
            defer sg.deinit();
            const dup = try a.dupe(u8, sg.get().bytes);
            return ok(.{ .String = try runtime.strInitOwned(a, dup) });
        },
        .StringBuilder => |sb| {
            const sg = sb.borrow();
            defer sg.deinit();
            const dup = try a.dupe(u8, sg.get().items);
            return ok(.{ .String = try runtime.strInitOwned(a, dup) });
        },
        else => {
            const s = try displayValue(a, ctx.args[0]);
            return ok(.{ .String = try runtime.strInitOwned(a, s) });
        },
    }
}

fn utf8Lossy(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return allocator.dupe(u8, bytes);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try appendReplacement(allocator, &out);
            i += 1;
            continue;
        };
        if (i + len > bytes.len) {
            try appendReplacement(allocator, &out);
            i += 1;
            continue;
        }
        if (std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(allocator, bytes[i .. i + len]);
            i += len;
        } else {
            try appendReplacement(allocator, &out);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendReplacement(allocator: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    try out.appendSlice(allocator, buf[0..n]);
}

pub fn string_builder_ctor(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    var buf: Buffer = .empty;
    errdefer buf.deinit(a);
    if (ctx.args.len == 0) {
    } else if (ctx.args.len == 1) {
        switch (ctx.args[0]) {
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                try buf.appendSlice(a, g.get().bytes);
            },
            .Int => |n| {
                if (n < 0) {
                    buf.deinit(a);
                    const msg = try std.fmt.allocPrint(a, "{d}", .{n});
                    defer if (runtime.freeScratch()) a.free(msg);
                    return thrown(a, "klio.NegativeArraySizeException", msg);
                }
                try buf.ensureTotalCapacityPrecise(a, @intCast(n));
            },
            .StringBuilder => |sb| {
                const g = sb.borrow();
                defer g.deinit();
                try buf.appendSlice(a, g.get().items);
            },
            else => {
                buf.deinit(a);
                return errResult(.{ .Type = "StringBuilder takes 0 or 1 argument" });
            },
        }
    } else {
        buf.deinit(a);
        return errResult(.{ .Type = "StringBuilder takes 0 or 1 argument" });
    }
    const ref = try StringBuilderRef.init(a, buf);
    sbMemoInvalidate(@intFromPtr(ref.cell));
    return ok(.{ .StringBuilder = ref });
}

pub fn string_builder_set_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.setRange"));
    const start = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse 0) else 0;
    const end = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
    const value = if (ctx.args.len > 3) (try valueToUtf16(a, ctx.args[3])) else null;
    if (value == null) return errResult(.{ .Type = "setRange value must be a String" });
    defer a.free(value.?);

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    const len: i64 = @intCast(units.len);
    // Throws only for start < 0, start > length or start > endIndex; an endIndex
    // past the length is clamped.
    if (start < 0 or start > len or start > end) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start, @min(end, len), len });
        defer if (runtime.freeScratch()) a.free(msg);
        return errResult(try stringRangeOob(a, msg));
    }
    const clamped_end = @min(end, len);
    const new_units = try spliceUnits(a, units, @intCast(start), @intCast(clamped_end), value.?);
    defer a.free(new_units);
    const s = try fromUtf16Lossy(a, new_units);
    defer a.free(s);
    try setBuf(buf, a, s);
    return okSb(sb);
}

fn spliceUnits(allocator: Allocator, units: []const u16, start: usize, end: usize, value: []const u16) Allocator.Error![]u16 {
    const head = units[0..start];
    const tail = units[end..];
    var out = try allocator.alloc(u16, head.len + value.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len .. head.len + value.len], value);
    @memcpy(out[head.len + value.len ..], tail);
    return out;
}

pub fn string_builder_append_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.appendRange"));
    // A `String` appends its byte range directly, through the string's own UTF-16
    // cursor, so run-after-run appends stay linear.
    if (ctx.args.len > 1 and ctx.args[1] == .String) {
        const g = ctx.args[1].String.borrow();
        defer g.deinit();
        const d = g.get();
        const vlen: i64 = @intCast(d.u16_len);
        const start = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
        const end = if (ctx.args.len > 3) (ctx.args[3].asI64() orelse vlen) else vlen;
        if (start < 0 or start > end or end > vlen) {
            const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start, end, vlen });
            defer if (runtime.freeScratch()) a.free(msg);
            return errResult(try rangeOob(a, msg));
        }
        const range = string.utf16RangeBytes(d, @intCast(start), @intCast(end));
        const gb = sbMut(sb);
        defer gb.deinit();
        try gb.get().appendSlice(a, d.bytes[range[0]..range[1]]);
        return okSb(sb);
    }
    if (ctx.args.len > 1 and ctx.args[1] == .Instance) {
        const r = try userSeqRange(ctx, &ctx.args[1], if (ctx.args.len > 2) ctx.args[2] else null, if (ctx.args.len > 3) ctx.args[3] else null);
        const units = switch (r) {
            .ok => |u| u,
            .err => |e| return errResult(e),
        };
        defer a.free(units);
        return appendUnits(a, sb, units);
    }
    const value = if (ctx.args.len > 1) (try valueToUtf16(a, ctx.args[1])) else null;
    if (value == null) return errResult(.{ .Type = "appendRange value must be a CharArray/CharSequence" });
    defer a.free(value.?);
    const vlen: i64 = @intCast(value.?.len);
    const start = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
    const end = if (ctx.args.len > 3) (ctx.args[3].asI64() orelse vlen) else vlen;
    if (start < 0 or start > end or end > vlen) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start, end, vlen });
        defer if (runtime.freeScratch()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }
    return appendUnits(a, sb, value.?[@intCast(start)..@intCast(end)]);
}

fn appendUnits(a: Allocator, sb: StringBuilderRef, slice: []const u16) Allocator.Error!EvalResult {
    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    const combined = try std.mem.concat(a, u16, &.{ units, slice });
    defer a.free(combined);
    const s = try fromUtf16Lossy(a, combined);
    defer a.free(s);
    try setBuf(buf, a, s);
    return okSb(sb);
}

pub fn string_builder_insert_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.insertRange"));
    const index = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse 0) else 0;
    // A program's own CharSequence gives the range it is asked for.
    const user_units: ?[]u16 = if (ctx.args.len > 2 and ctx.args[2] == .Instance) blk: {
        const r = try userSeqRange(ctx, &ctx.args[2], if (ctx.args.len > 3) ctx.args[3] else null, if (ctx.args.len > 4) ctx.args[4] else null);
        break :blk switch (r) {
            .ok => |u| u,
            .err => |e| return errResult(e),
        };
    } else null;
    defer if (user_units) |u| a.free(u);
    const value = if (user_units != null) try a.dupe(u16, user_units.?) else if (ctx.args.len > 2) (try valueToUtf16(a, ctx.args[2])) else null;
    if (value == null) return errResult(.{ .Type = "insertRange value must be a CharArray/CharSequence" });
    defer a.free(value.?);
    const vlen: i64 = @intCast(value.?.len);
    const start = if (user_units != null) 0 else if (ctx.args.len > 3) (ctx.args[3].asI64() orelse 0) else 0;
    const end = if (user_units != null) vlen else if (ctx.args.len > 4) (ctx.args[4].asI64() orelse vlen) else vlen;
    if (start < 0 or start > end or end > vlen) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start, end, vlen });
        defer if (runtime.freeScratch()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    const len: i64 = @intCast(units.len);
    if (index < 0 or index > len) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ index, len, len });
        defer if (runtime.freeScratch()) a.free(msg);
        return errResult(try stringRangeOob(a, msg));
    }
    const slice = value.?[@intCast(start)..@intCast(end)];
    const new_units = try spliceUnits(a, units, @intCast(index), @intCast(index), slice);
    defer a.free(new_units);
    const s = try fromUtf16Lossy(a, new_units);
    defer a.free(s);
    try setBuf(buf, a, s);
    return okSb(sb);
}

pub fn string_builder_append(ctx: *CallCtx) Allocator.Error!EvalResult {
    // `append(value, startIndex, endIndex)` is the subrange overload: it appends
    // `value[startIndex, endIndex)`, not the three arguments separately.
    if (ctx.args.len == 4 and isCharSeqOrArray(ctx.args[1]) and
        ctx.args[2].asI64() != null and ctx.args[3].asI64() != null)
    {
        // `append(str: CharArray, offset, len)` is the JVM's member, `len` characters
        // from `offset`; the common library deprecates its extension of the shape and
        // leaves it unimplemented.
        if (ctx.args[1] == .Array) {
            const offset = ctx.args[2].asI64().?;
            const end = offset + ctx.args[3].asI64().?;
            const n: i64 = @intCast(ctx.args[1].Array.len());
            if (offset < 0 or offset > end or end > n) {
                const msg = try std.fmt.allocPrint(ctx.allocator, "Range [{d}, {d}) out of bounds for length {d}", .{ offset, end, n });
                defer if (runtime.freeScratch()) ctx.allocator.free(msg);
                return thrown(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
            }
            const range = [_]Value{ ctx.args[0], ctx.args[1], Value.newInt(@intCast(offset)), Value.newInt(@intCast(end)) };
            var sub = ctx.*;
            sub.args = &range;
            return string_builder_append_range(&sub);
        }
        return string_builder_append_range(ctx);
    }
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.append"));
    for (ctx.args[1..]) |v| {
        if (try appendOverflowGuard(ctx, sb, &v)) |oom| return oom;
        // A string's bytes and a number's digits go straight into the
        // buffer, with nothing rendered apart first.
        var digits: [20]u8 = undefined;
        const direct: ?[]const u8 = switch (v) {
            .Int => |x| runtime.decimal(&digits, x),
            .Long => |x| runtime.decimal(&digits, x),
            else => null,
        };
        if (direct != null or v == .String) {
            const sg = if (v == .String) v.String.borrow() else null;
            defer if (sg) |x| x.deinit();
            const piece = direct orelse sg.?.get().bytes;
            const g = sb.borrowMut();
            defer g.deinit();
            const buf = g.get();
            const before_ptr = buf.items.ptr;
            const before_len = buf.items.len;
            try buf.appendSlice(a, piece);
            runtime.sbMemoAppended(@intFromPtr(sb.cell), before_ptr, before_len, buf.items, piece);
            continue;
        }
        const piece = try renderPiece(ctx, v);
        defer a.free(piece);
        // The memo follows the append, so reading the length after each
        // one stays O(1).
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        const before_ptr = buf.items.ptr;
        const before_len = buf.items.len;
        try buf.appendSlice(a, piece);
        runtime.sbMemoAppended(@intFromPtr(sb.cell), before_ptr, before_len, buf.items, piece);
    }
    return okSb(sb);
}

// A program's own CharSequence is an instance; `append(vararg String?)` never
// takes one, so an instance with two Ints after it is the subrange overload.
fn isCharSeqOrArray(v: Value) bool {
    return switch (v) {
        .String, .StringBuilder, .Array, .Instance => true,
        else => false,
    };
}

pub fn string_builder_set(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.set"));
    const index = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (index == null) return errResult(.{ .Type = "StringBuilder.set index must be an Int" });
    if (ctx.args.len < 3 or ctx.args[2] != .Char) {
        return errResult(.{ .Type = "StringBuilder.set value must be a Char" });
    }
    const unit = ctx.args[2].Char;

    if (unit < 0x80) {
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        if (asciiBytes(sb, buf.items)) {
            if (index.? < 0 or @as(usize, @intCast(index.?)) >= buf.items.len) {
                const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ index.?, buf.items.len });
                defer if (runtime.freeScratch()) a.free(msg);
                return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
            }
            buf.items[@intCast(index.?)] = @intCast(unit);
            runtime.sbMemoAscii(@intFromPtr(sb.cell), buf.items.len);
            return ok(.Unit);
        }
    }
    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    var units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    if (index.? < 0 or @as(usize, @intCast(index.?)) >= units.len) {
        const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ index.?, units.len });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }
    units[@intCast(index.?)] = unit;
    const s = try fromUtf16Lossy(a, units);
    defer a.free(s);
    try setBuf(buf, a, s);
    return ok(.Unit);
}

pub fn string_builder_append_line(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.appendLine"));
    for (ctx.args[1..]) |v| {
        const piece = try renderPiece(ctx, v);
        defer a.free(piece);
        const g = sbMut(sb);
        defer g.deinit();
        try g.get().appendSlice(a, piece);
    }
    {
        const g = sbMut(sb);
        defer g.deinit();
        try g.get().append(a, '\n');
    }
    return okSb(sb);
}

pub fn string_builder_length(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.length"));
    const g = sb.borrow();
    defer g.deinit();
    return ok(Value.newInt(@intCast(sbMemoFor(sb, g.get().items).u16_len)));
}

pub fn string_builder_capacity(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.capacity"));
    const g = sb.borrow();
    defer g.deinit();
    return ok(Value.newInt(@intCast(g.get().capacity)));
}

pub fn string_builder_ensure_capacity(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.ensureCapacity"));
    if (ctx.args.len >= 2) {
        if (ctx.args[1].asI64()) |n| {
            if (n > 0) {
                const g = sbMut(sb);
                defer g.deinit();
                try g.get().ensureTotalCapacity(ctx.allocator, @intCast(n));
            }
        }
    }
    return ok(.Unit);
}

pub fn string_builder_trim_to_size(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.trimToSize"));
    return ok(.Unit);
}

pub fn string_builder_indices(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.indices"));
    const g = sb.borrow();
    defer g.deinit();
    const len: i64 = @intCast(charCount(g.get().items));
    return ok(try Value.newRange(ctx.allocator, .{ .start = 0, .end = len - 1, .step = 1, .kind = .Int }));
}

pub fn string_builder_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.toString"));
    const g = sb.borrow();
    defer g.deinit();
    // Coalesce WTF-8 surrogate pairs from individual `Char` appends into astral
    // scalars, so a builder fed a high plus low pair equals the astral literal.
    const dup = try runtime.coalesceSurrogates(a, g.get().items);
    return ok(.{ .String = try runtime.strInitOwned(a, dup) });
}

pub fn string_builder_get(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.get"));
    const idx = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (idx == null) return errResult(.{ .Type = "StringBuilder[index] requires Int" });

    const g = sb.borrow();
    defer g.deinit();
    const buf = g.get().items;
    const m = sbMemoFor(sb, buf);
    const n: i64 = @intCast(m.u16_len);
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ idx.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }
    const ui: usize = @intCast(idx.?);
    if (m.ascii) return ok(.{ .Char = buf[ui] });
    if (sbUnitAt(m, buf, ui)) |u| return ok(.{ .Char = u });
    const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ idx.?, n });
    defer if (runtime.freeScratch()) a.free(msg);
    return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
}

pub fn string_builder_is_empty(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.isEmpty"));
    const g = sb.borrow();
    defer g.deinit();
    return ok(.{ .Bool = g.get().items.len == 0 });
}

pub fn string_builder_is_not_empty(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.isNotEmpty"));
    const g = sb.borrow();
    defer g.deinit();
    return ok(.{ .Bool = g.get().items.len != 0 });
}

pub fn string_builder_clear(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.clear"));
    {
        const g = sbMut(sb);
        defer g.deinit();
        g.get().clearRetainingCapacity();
    }
    return okSb(sb);
}

pub fn string_builder_insert(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.insert"));
    const idx = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (idx == null) return errResult(.{ .Type = "insert index must be Int" });
    if (ctx.args.len < 3) return errResult(.{ .Arity = "insert requires a value" });

    if (try appendOverflowGuard(ctx, sb, &ctx.args[2])) |oom| return oom;
    const piece_bytes = try renderPiece(ctx, ctx.args[2]);
    defer a.free(piece_bytes);
    var piece: Buffer = .empty;
    defer piece.deinit(a);
    try piece.appendSlice(a, piece_bytes);

    if (allAscii(piece_bytes)) {
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        if (asciiBytes(sb, buf.items)) {
            if (idx.? < 0 or idx.? > buf.items.len) {
                const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ idx.?, buf.items.len, buf.items.len });
                defer if (runtime.freeScratch()) a.free(msg);
                return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
            }
            try buf.insertSlice(a, @intCast(idx.?), piece_bytes);
            runtime.sbMemoAscii(@intFromPtr(sb.cell), buf.items.len);
            return okSb(sb);
        }
    }
    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    // Splice in UTF-16-unit space so the insert index matches Kotlin even with
    // astral chars or lone surrogates in the buffer.
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (idx.? < 0 or idx.? > n) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ idx.?, n, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }
    const piece_units = try bufUnits(a, piece.items);
    defer a.free(piece_units);
    const at: usize = @intCast(idx.?);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, units[0..at]);
    try out.appendSlice(a, piece_units);
    try out.appendSlice(a, units[at..]);
    try setBufUnits(buf, a, out.items);
    return okSb(sb);
}

pub fn string_builder_delete_at(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.deleteAt"));
    const idx = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (idx == null) return errResult(.{ .Type = "deleteAt index must be Int" });

    {
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        if (asciiBytes(sb, buf.items)) {
            if (idx.? < 0 or idx.? >= buf.items.len) {
                const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ idx.?, buf.items.len });
                defer if (runtime.freeScratch()) a.free(msg);
                return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
            }
            _ = buf.orderedRemove(@intCast(idx.?));
            runtime.sbMemoAscii(@intFromPtr(sb.cell), buf.items.len);
            return okSb(sb);
        }
    }
    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ idx.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }
    const at: usize = @intCast(idx.?);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, units[0..at]);
    try out.appendSlice(a, units[at + 1 ..]);
    try setBufUnits(buf, a, out.items);
    return okSb(sb);
}

pub fn string_builder_delete_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.deleteRange"));
    const start = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (start == null) return errResult(.{ .Type = "deleteRange start must be Int" });
    const end = if (ctx.args.len > 2) ctx.args[2].asI64() else null;
    if (end == null) return errResult(.{ .Type = "deleteRange end must be Int" });

    {
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        if (asciiBytes(sb, buf.items)) {
            const n: i64 = @intCast(buf.items.len);
            // Kotlin throws only for startIndex < 0, > length or > endIndex; an endIndex
            // past the length deletes through the end.
            if (start.? < 0 or start.? > n or start.? > end.?) {
                const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start.?, @min(end.?, n), n });
                defer if (runtime.freeScratch()) a.free(msg);
                return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
            }
            const s: usize = @intCast(start.?);
            const e: usize = @intCast(@min(end.?, n));
            buf.replaceRangeAssumeCapacity(s, e - s, &.{});
            runtime.sbMemoAscii(@intFromPtr(sb.cell), buf.items.len);
            return okSb(sb);
        }
    }
    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    // Kotlin throws only for startIndex < 0, > length or > endIndex; an endIndex
    // past the length deletes through the end.
    if (start.? < 0 or start.? > n or start.? > end.?) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start.?, @min(end.?, n), n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }
    const s: usize = @intCast(start.?);
    const e: usize = @intCast(@min(end.?, n));
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, units[0..s]);
    try out.appendSlice(a, units[e..]);
    try setBufUnits(buf, a, out.items);
    return okSb(sb);
}

pub fn string_builder_set_length(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.setLength"));
    const new_len = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (new_len == null) return errResult(.{ .Type = "setLength requires Int" });
    if (new_len.? < 0) {
        const msg = try std.fmt.allocPrint(a, "String index out of range: {d}", .{new_len.?});
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }

    const target: usize = @intCast(new_len.?);
    {
        // Where every character is one byte, as ASCII's are, the bytes are
        // the UTF-16 units: cut or pad them in place.
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        if (target == 0 or sbMemoFor(sb, buf.items).ascii) {
            runtime.sbMemoInvalidate(@intFromPtr(sb.cell));
            if (target <= buf.items.len) buf.shrinkRetainingCapacity(target) else try buf.appendNTimes(a, 0, target - buf.items.len);
            return ok(.Unit);
        }
    }
    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const cur: usize = units.len;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(a);
    if (target <= cur) {
        try out.appendSlice(a, units[0..target]);
    } else {
        try out.appendSlice(a, units);
        // Kotlin pads the grown region with U+0000.
        try out.appendNTimes(a, 0, target - cur);
    }
    try setBufUnits(buf, a, out.items);
    return ok(.Unit);
}

pub fn string_builder_reverse(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.reverse"));
    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    // Each character's bytes, in order, at the mirrored place: a surrogate pair stays one.
    const rev = try a.alloc(u8, buf.items.len);
    defer a.free(rev);
    var view = std.unicode.Utf8View.initUnchecked(buf.items);
    var it = view.iterator();
    var end = rev.len;
    while (it.nextCodepointSlice()) |slice| {
        end -= slice.len;
        @memcpy(rev[end..][0..slice.len], slice);
    }
    @memcpy(buf.items, rev);
    // The length and the ASCII-ness are the same, the cursor no longer is.
    if (runtime.sbAsciiLen(@intFromPtr(sb.cell), buf.items.len) != null) {
        runtime.sbMemoAscii(@intFromPtr(sb.cell), buf.items.len);
    } else runtime.sbMemoInvalidate(@intFromPtr(sb.cell));
    return okSb(sb);
}

pub fn string_builder_substring(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.substring"));
    const is_range = ctx.args.len == 2 and ctx.args[1] == .Range;
    const start = if (is_range)
        @as(?i64, ctx.args[1].Range.start)
    else if (ctx.args.len > 1)
        ctx.args[1].asI64()
    else
        null;
    if (start == null) return errResult(.{ .Type = "substring start must be Int" });

    const g = sb.borrow();
    defer g.deinit();
    const buf = g.get().items;
    if (asciiBytes(sb, buf)) {
        const n: i64 = @intCast(buf.len);
        var end: i64 = n;
        if (is_range) {
            end = ctx.args[1].Range.end + 1;
        } else if (ctx.args.len > 2) {
            if (ctx.args[2].isIntegral()) {
                end = ctx.args[2].asI64().?;
            } else {
                return errResult(.{ .Type = "substring end must be Int" });
            }
        }
        if (start.? < 0 or end > n or start.? > end) {
            const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start.?, end, n });
            defer if (runtime.freeScratch()) a.free(msg);
            return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
        }
        return ok(.{ .String = try runtime.strInit(a, buf[@intCast(start.?)..@intCast(end)]) });
    }
    const units = try bufUnits(a, buf);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    var end: i64 = n;
    if (is_range) {
        end = ctx.args[1].Range.end + 1;
    } else if (ctx.args.len > 2) {
        if (ctx.args[2].isIntegral()) {
            end = ctx.args[2].asI64().?;
        } else {
            return errResult(.{ .Type = "substring end must be Int" });
        }
    }
    if (start.? < 0 or end > n or start.? > end) {
        const msg = try std.fmt.allocPrint(a, "Range [{d}, {d}) out of bounds for length {d}", .{ start.?, end, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }
    const dup = try runtime.charUnitsToString(a, units[@intCast(start.?)..@intCast(end)]);
    return ok(.{ .String = try runtime.strInitOwned(a, dup) });
}

pub fn string_builder_set_char_at(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.setCharAt"));
    const idx = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (idx == null) return errResult(.{ .Type = "setCharAt index must be Int" });
    if (ctx.args.len < 3 or ctx.args[2] != .Char) {
        return errResult(.{ .Type = "setCharAt requires a Char" });
    }
    const ch = ctx.args[2].Char;

    if (ch < 0x80) {
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        if (asciiBytes(sb, buf.items)) {
            if (idx.? < 0 or idx.? >= buf.items.len) {
                const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ idx.?, buf.items.len });
                defer if (runtime.freeScratch()) a.free(msg);
                return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
            }
            buf.items[@intCast(idx.?)] = @intCast(ch);
            runtime.sbMemoAscii(@intFromPtr(sb.cell), buf.items.len);
            return ok(.Unit);
        }
    }
    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ idx.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "klio.StringIndexOutOfBoundsException", msg);
    }
    units[@intCast(idx.?)] = ch;
    try setBufUnits(buf, a, units);
    return ok(.Unit);
}

pub fn string_builder_replace(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.replace"));
    // The CharSequence `replace(oldValue, newValue)` extensions share this name
    // with the Java `replace(start: Int, end: Int, str)` range mutator, so a
    // non-integer second argument routes to the String intrinsic.
    if (ctx.args.len > 1 and !ctx.args[1].isIntegral()) {
        const str_val: Value = blk: {
            const sg = sb.borrow();
            defer sg.deinit();
            break :blk .{ .String = try runtime.strInit(a, sg.get().items) };
        };
        const new_args = try a.dupe(Value, ctx.args);
        defer a.free(new_args);
        new_args[0] = str_val;
        var new_ctx = ctx.*;
        new_ctx.args = new_args;
        return string.string_replace(&new_ctx);
    }
    const start = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (start == null) return errResult(.{ .Type = "replace start must be Int" });
    const end0 = if (ctx.args.len > 2) ctx.args[2].asI64() else null;
    if (end0 == null) return errResult(.{ .Type = "replace end must be Int" });
    if (ctx.args.len < 4) return errResult(.{ .Type = "replace requires a replacement string" });
    const repl: []const u8 = switch (ctx.args[3]) {
        .String => |s| blk: {
            const sg = s.borrow();
            defer sg.deinit();
            break :blk try a.dupe(u8, sg.get().bytes);
        },
        else => try displayValue(a, ctx.args[3]),
    };
    defer a.free(repl);

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (start.? < 0 or start.? > n or start.? > end0.?) {
        const msg = try std.fmt.allocPrint(a, "start {d}, end {d}, length {d}", .{ start.?, end0.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    // Kotlin/JVM clamps the end to the current length.
    const end: usize = @intCast(@min(end0.?, n));
    const s: usize = @intCast(start.?);
    const repl_units = try bufUnits(a, repl);
    defer a.free(repl_units);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, units[0..s]);
    try out.appendSlice(a, repl_units);
    try out.appendSlice(a, units[end..]);
    try setBufUnits(buf, a, out.items);
    return okSb(sb);
}

pub fn string_builder_last_index(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.lastIndex"));
    const g = sb.borrow();
    defer g.deinit();
    const n: i64 = @intCast(charCount(g.get().items));
    return ok(Value.newInt(n - 1));
}

const testing = std.testing;

fn newSb(a: Allocator, seed: []const u8) Allocator.Error!Value {
    var buf: Buffer = .empty;
    try buf.appendSlice(a, seed);
    const ref = try StringBuilderRef.init(a, buf);
    sbMemoInvalidate(@intFromPtr(ref.cell));
    return .{ .StringBuilder = ref };
}

/// Free a produced value and its heap: under reclaim the `StringRef` cell frees
/// its bytes on `deinit`; under the arena the arena reclaims them.
fn freeSb(v: Value, a: Allocator) void {
    _ = a;
    switch (v) {
        .StringBuilder => |sb| sb.deinit(),
        .String => |s| {
            s.deinit();
        },
        .Exception => |e| runtime.exceptionRefOf(e).deinit(),
        else => {},
    }
}

const TestCtx = struct {
    cap: runtime.CaptureOutput,
    noop: runtime.NoopHost,

    fn init(a: Allocator) TestCtx {
        return .{ .cap = runtime.CaptureOutput.init(a), .noop = runtime.NoopHost.init(a) };
    }
    fn deinit(self: *TestCtx) void {
        self.cap.deinit();
        self.noop.deinit();
    }
    fn ctx(self: *TestCtx, a: Allocator, args: []const Value) CallCtx {
        return .{ .args = args, .out = self.cap.output(), .host = self.noop.host(), .allocator = a };
    }
};

test "string builder ctor seeds from string" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const seed = try runtime.strInit(a, "hi");
    defer seed.deinit();
    var args = [_]Value{.{ .String = seed }};
    var c = tc.ctx(a, &args);
    const r = try string_builder_ctor(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = r.ok.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("hi", g.get().items);
}

test "string builder ctor negative capacity throws" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    var args = [_]Value{.{ .Int = -1 }};
    var c = tc.ctx(a, &args);
    const r = try string_builder_ctor(&c);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Thrown);
    defer freeSb(r.err.Thrown, a);
    try testing.expectEqualStrings("klio.NegativeArraySizeException", r.err.Thrown.exceptionFqn().?);
}

test "append concatenates values" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "a");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Bool = true } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_append(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("a1true", g.get().items);
}

test "append null renders as null" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .Null };
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_append(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("null", g.get().items);
}

test "append char" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "x");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Char = 'y' } };
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_append(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("xy", g.get().items);
}

test "appendLine adds newline" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "");
    defer freeSb(sb, a);
    const s = try runtime.strInit(a, "hi");
    defer s.deinit();
    var args = [_]Value{ sb, .{ .String = s } };
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_append_line(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("hi\n", g.get().items);
}

test "append subrange overload appends slice" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "");
    defer freeSb(sb, a);
    const s = try runtime.strInit(a, "abcdef");
    defer s.deinit();
    var args = [_]Value{ sb, .{ .String = s }, .{ .Int = 1 }, .{ .Int = 4 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_append(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("bcd", g.get().items);
}

test "length and lastIndex count chars" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "hello");
    defer freeSb(sb, a);
    var args = [_]Value{sb};
    var c = tc.ctx(a, &args);
    const len = try string_builder_length(&c);
    try testing.expectEqual(@as(i32, 5), len.ok.Int);
    const li = try string_builder_last_index(&c);
    try testing.expectEqual(@as(i32, 4), li.ok.Int);
}

test "toString produces a string" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "data");
    defer freeSb(sb, a);
    var args = [_]Value{sb};
    var c = tc.ctx(a, &args);
    const r = try string_builder_to_string(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("data", g.get().bytes);
}

test "get returns char and bounds-checks" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "abc");
    defer freeSb(sb, a);
    {
        var args = [_]Value{ sb, .{ .Int = 1 } };
        var c = tc.ctx(a, &args);
        const r = try string_builder_get(&c);
        try testing.expectEqual(@as(u16, 'b'), r.ok.Char);
    }
    {
        var args = [_]Value{ sb, .{ .Int = 9 } };
        var c = tc.ctx(a, &args);
        const r = try string_builder_get(&c);
        try testing.expect(r == .err);
        defer freeSb(r.err.Thrown, a);
        try testing.expectEqualStrings("klio.StringIndexOutOfBoundsException", r.err.Thrown.exceptionFqn().?);
    }
}

test "isEmpty and isNotEmpty" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const empty = try newSb(a, "");
    defer freeSb(empty, a);
    const full = try newSb(a, "x");
    defer freeSb(full, a);
    {
        var args = [_]Value{empty};
        var c = tc.ctx(a, &args);
        try testing.expect((try string_builder_is_empty(&c)).ok.Bool);
        try testing.expect(!(try string_builder_is_not_empty(&c)).ok.Bool);
    }
    {
        var args = [_]Value{full};
        var c = tc.ctx(a, &args);
        try testing.expect(!(try string_builder_is_empty(&c)).ok.Bool);
        try testing.expect((try string_builder_is_not_empty(&c)).ok.Bool);
    }
}

test "clear empties the buffer" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "stuff");
    defer freeSb(sb, a);
    var args = [_]Value{sb};
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_clear(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.get().items.len);
}

test "insert at index" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "ac");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Char = 'b' } };
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_insert(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("abc", g.get().items);
}

test "insert out of range throws" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "ac");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 9 }, .{ .Char = 'b' } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_insert(&c);
    try testing.expect(r == .err);
    defer freeSb(r.err.Thrown, a);
}

test "deleteAt removes a char" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "abc");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 1 } };
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_delete_at(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("ac", g.get().items);
}

test "deleteRange removes a span" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "abcdef");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Int = 4 } };
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_delete_range(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("aef", g.get().items);
}

test "setLength truncates and pads" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    {
        const sb = try newSb(a, "abcdef");
        defer freeSb(sb, a);
        var args = [_]Value{ sb, .{ .Int = 3 } };
        var c = tc.ctx(a, &args);
        const __sbres = try string_builder_set_length(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
        const g = sb.StringBuilder.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("abc", g.get().items);
    }
    {
        const sb = try newSb(a, "ab");
        defer freeSb(sb, a);
        var args = [_]Value{ sb, .{ .Int = 4 } };
        var c = tc.ctx(a, &args);
        const __sbres = try string_builder_set_length(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
        const g = sb.StringBuilder.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(usize, 4), g.get().items.len);
        try testing.expectEqual(@as(u8, 0), g.get().items[3]);
    }
}

test "reverse flips chars" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "abc");
    defer freeSb(sb, a);
    var args = [_]Value{sb};
    var c = tc.ctx(a, &args);
    const __sbres = try string_builder_reverse(&c);
    defer if (__sbres == .ok) freeSb(__sbres.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("cba", g.get().items);
}

test "substring extracts range" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "abcdef");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Int = 4 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_substring(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("bcd", g.get().bytes);
}

test "setCharAt replaces a char in place" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "cat");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Char = 'u' } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_set_char_at(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("cut", g.get().items);
}

test "set replaces a code unit and returns Unit" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "cat");
    defer freeSb(sb, a);
    var args = [_]Value{ sb, .{ .Int = 0 }, .{ .Char = 'b' } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_set(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    try testing.expect(r.ok == .Unit);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("bat", g.get().items);
}

test "replace splices a string" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "abcdef");
    defer freeSb(sb, a);
    const repl = try runtime.strInit(a, "XY");
    defer repl.deinit();
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Int = 4 }, .{ .String = repl } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_replace(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("aXYef", g.get().items);
}

test "setRange replaces utf16 units" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "abcdef");
    defer freeSb(sb, a);
    const val = try runtime.strInit(a, "Z");
    defer val.deinit();
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Int = 4 }, .{ .String = val } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_set_range(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("aZef", g.get().items);
}

test "appendRange appends a slice of a string" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "x");
    defer freeSb(sb, a);
    const val = try runtime.strInit(a, "abcdef");
    defer val.deinit();
    var args = [_]Value{ sb, .{ .String = val }, .{ .Int = 2 }, .{ .Int = 5 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_append_range(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("xcde", g.get().items);
}

test "insertRange inserts a slice" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "XY");
    defer freeSb(sb, a);
    const val = try runtime.strInit(a, "abcdef");
    defer val.deinit();
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .String = val }, .{ .Int = 1 }, .{ .Int = 3 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_insert_range(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = sb.StringBuilder.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("XbcY", g.get().items);
}

test "string ctor empty and from string" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    {
        var args = [_]Value{};
        var c = tc.ctx(a, &args);
        const r = try string_ctor(&c);
        defer freeSb(r.ok, a);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("", g.get().bytes);
    }
    {
        const s = try runtime.strInit(a, "hello");
        defer s.deinit();
        var args = [_]Value{.{ .String = s }};
        var c = tc.ctx(a, &args);
        const r = try string_ctor(&c);
        defer freeSb(r.ok, a);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("hello", g.get().bytes);
    }
}

test "string ctor from char array builds from code units" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    var list: ValueList = try ValueList.init(a, .empty);
    defer list.deinit();
    {
        const g = list.borrowMut();
        defer g.deinit();
        try g.get().append(a, .{ .Char = 'h' });
        try g.get().append(a, .{ .Char = 'i' });
    }
    const char_arr = blk: {
        const g = list.borrow();
        defer g.deinit();
        break :blk try runtime.ArrayData.initPacked(a, .Char, g.get().items);
    };
    defer char_arr.Array.deinitStorage();
    var args = [_]Value{char_arr};
    var c = tc.ctx(a, &args);
    const r = try string_ctor(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("hi", g.get().bytes);
}

test "string ctor from byte array decodes utf8" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    var list: ValueList = try ValueList.init(a, .empty);
    defer list.deinit();
    {
        const g = list.borrowMut();
        defer g.deinit();
        try g.get().append(a, .{ .Byte = 'h' });
        try g.get().append(a, .{ .Byte = 'i' });
    }
    const byte_arr = blk: {
        const g = list.borrow();
        defer g.deinit();
        break :blk try runtime.ArrayData.initPacked(a, .Byte, g.get().items);
    };
    defer byte_arr.Array.deinitStorage();
    var args = [_]Value{byte_arr};
    var c = tc.ctx(a, &args);
    const r = try string_ctor(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("hi", g.get().bytes);
}

test "non-receiver argument is a type error" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    var args = [_]Value{.{ .Int = 1 }};
    var c = tc.ctx(a, &args);
    const r = try string_builder_length(&c);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "the length read after each append follows the appends and any other change" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "a");
    defer freeSb(sb, a);
    const Len = struct {
        fn of(t: *TestCtx, al: Allocator, s: Value) !i32 {
            var args = [_]Value{s};
            var c = t.ctx(al, &args);
            return (try string_builder_length(&c)).ok.Int;
        }
        fn append(t: *TestCtx, al: Allocator, s: Value, v: Value) !void {
            var args = [_]Value{ s, v };
            var c = t.ctx(al, &args);
            const r = try string_builder_append(&c);
            freeSb(r.ok, al);
        }
    };
    try testing.expectEqual(@as(i32, 1), try Len.of(&tc, a, sb));
    try Len.append(&tc, a, sb, .{ .Int = 42 });
    try testing.expectEqual(@as(i32, 3), try Len.of(&tc, a, sb));
    // A character outside ASCII is one unit; each half of a surrogate pair is one.
    try Len.append(&tc, a, sb, .{ .Char = 0xE9 });
    try testing.expectEqual(@as(i32, 4), try Len.of(&tc, a, sb));
    try Len.append(&tc, a, sb, .{ .Char = 0xD83D });
    try Len.append(&tc, a, sb, .{ .Char = 0xDE00 });
    try testing.expectEqual(@as(i32, 6), try Len.of(&tc, a, sb));
    // A change other than an append is counted afresh.
    var args = [_]Value{ sb, .{ .Int = 2 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_set_length(&c);
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i32, 2), try Len.of(&tc, a, sb));
    try Len.append(&tc, a, sb, .{ .Char = 'z' });
    try testing.expectEqual(@as(i32, 3), try Len.of(&tc, a, sb));
}

fn sbBytes(v: Value) []const u8 {
    return v.StringBuilder.asPtrConst().items;
}

test "an ASCII builder is edited in place and keeps its length known with no scan" {
    const a = testing.allocator;
    var tc = TestCtx.init(a);
    defer tc.deinit();
    const sb = try newSb(a, "hello");
    defer freeSb(sb, a);
    const cell = @intFromPtr(sb.StringBuilder.cell);
    const Op = struct { f: *const fn (*CallCtx) Allocator.Error!EvalResult, args: []const Value, want: []const u8 };
    const ops = [_]Op{
        .{ .f = string_builder_insert, .args = &.{ sb, .{ .Int = 0 }, .{ .Char = '[' } }, .want = "[hello" },
        .{ .f = string_builder_delete_at, .args = &.{ sb, .{ .Int = 5 } }, .want = "[hell" },
        .{ .f = string_builder_set_char_at, .args = &.{ sb, .{ .Int = 1 }, .{ .Char = 'H' } }, .want = "[Hell" },
        .{ .f = string_builder_delete_range, .args = &.{ sb, .{ .Int = 2 }, .{ .Int = 4 } }, .want = "[Hl" },
        .{ .f = string_builder_reverse, .args = &.{sb}, .want = "lH[" },
    };
    for (ops) |op| {
        var args: [3]Value = undefined;
        @memcpy(args[0..op.args.len], op.args);
        var c = tc.ctx(a, args[0..op.args.len]);
        const r = try op.f(&c);
        try testing.expect(r == .ok);
        defer freeSb(r.ok, a);
        try testing.expectEqualStrings(op.want, sbBytes(sb));
        try testing.expectEqual(@as(?usize, op.want.len), runtime.sbAsciiLen(cell, op.want.len));
    }
    // A non-ASCII character takes the builder off the known-ASCII path, and the edit still lands.
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Char = 0xE9 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_set_char_at(&c);
    defer freeSb(r.ok, a);
    try testing.expectEqualStrings("l\u{e9}[", sbBytes(sb));
    try testing.expectEqual(@as(?usize, null), runtime.sbAsciiLen(cell, sbBytes(sb).len));
}
