//! StringBuilder stdlib intrinsics.
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`. A `StringBuilder` value
//! is an `ObjRef(std.ArrayList(u8))` holding the buffer as UTF-8 bytes; the
//! range/index operations that Kotlin defines over UTF-16 code units convert
//! between the UTF-8 buffer and a `[]u16` view as needed.

const std = @import("std");
const runtime = @import("runtime");

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

// ============================================================
// Shared helpers
// ============================================================

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn errResult(e: RuntimeError) EvalResult {
    return .{ .err = e };
}

/// `make_exception(fqn, message)` — build a thrown Kotlin Throwable value.
/// `fqn` is a static slice; `message`, when present, is owned by `allocator`.
fn makeException(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try StringRef.init(allocator, fqn),
        .message = if (message) |m| try StringRef.init(allocator, m) else null,
        .cause = null,
    } };
}

/// `RuntimeError::Thrown(make_exception(...))` as an `EvalResult` error.
fn thrown(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalResult {
    return errResult(.{ .Thrown = try makeException(allocator, fqn, message) });
}

/// The `StringBuilder` receiver in `args[0]`, or `null`. Mirrors Rust's
/// `sb_arg`; the caller turns `null` into a `Type` error via `sbTypeError`.
fn sbArg(args: []const Value) ?StringBuilderRef {
    if (args.len > 0) {
        if (args[0] == .StringBuilder) return args[0].StringBuilder;
    }
    return null;
}

fn sbTypeError(comptime what: []const u8) RuntimeError {
    return .{ .Type = what ++ " requires a StringBuilder receiver" };
}

/// Overwrite the builder's UTF-8 bytes with `bytes`.
fn setBuf(buf: *Buffer, allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, bytes);
}

/// The UTF-16 code units of `s` as Kotlin would iterate/index its chars.
/// Caller owns the result.
fn encodeUtf16(allocator: Allocator, s: []const u8) Allocator.Error![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(allocator);
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFFFF) {
            try out.append(allocator, @intCast(cp));
        } else {
            const adjusted = cp - 0x10000;
            try out.append(allocator, @intCast(0xD800 + (adjusted >> 10)));
            try out.append(allocator, @intCast(0xDC00 + (adjusted & 0x3FF)));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `String::from_utf16_lossy` — fold UTF-16 units back into a UTF-8 string,
/// reconstructing surrogate pairs (unpaired surrogates become U+FFFD).
/// Caller owns the result.
fn fromUtf16Lossy(allocator: Allocator, units: []const u16) Allocator.Error![]u8 {
    return runtime.charUnitsToString(allocator, units);
}

/// Render a single UTF-16 code unit (a Kotlin `Char`) as a UTF-8 string.
/// Caller owns the result.
fn charUnitToString(allocator: Allocator, unit: u16) Allocator.Error![]u8 {
    return runtime.charUnitToString(allocator, unit);
}

/// Number of Kotlin `Char`s — UTF-8 string `chars().count()` counts each
/// astral scalar as one `char`, matching Rust's `str::chars`.
fn charCount(s: []const u8) usize {
    var n: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

/// Render `v` the way Kotlin's `toString` / templates do. Caller owns it.
fn displayValue(allocator: Allocator, v: Value) Allocator.Error![]u8 {
    return v.display(allocator);
}

/// Append `v` to a UTF-8 buffer, mirroring Rust `append_value`.
fn appendValue(buf: *Buffer, allocator: Allocator, v: Value) Allocator.Error!void {
    switch (v) {
        .Null => try buf.appendSlice(allocator, "null"),
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            try buf.appendSlice(allocator, g.get().*);
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

/// The UTF-16 units of a `CharArray` / `CharSequence` / `Char` argument, for
/// the range ops. Caller owns the result; `null` if `v` is not such a value.
fn valueToUtf16(allocator: Allocator, v: Value) Allocator.Error!?[]u16 {
    switch (v) {
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return try encodeUtf16(allocator, g.get().*);
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
            const g = a.items.borrow();
            defer g.deinit();
            const elems = g.get().items;
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

fn rangeOob(allocator: Allocator, msg: []const u8) Allocator.Error!RuntimeError {
    return .{ .Thrown = try makeException(allocator, "kotlin.IndexOutOfBoundsException", msg) };
}

/// Byte offset of the `idx`-th Kotlin `char` in `buf`, mirroring Rust's
/// `sb_char_byte`. Returns `buf.len` for `idx == char_count`.
fn sbCharByte(buf: []const u8, idx: i64) ?usize {
    if (idx < 0) return null;
    const target: usize = @intCast(idx);
    if (target == charCount(buf)) return buf.len;
    var view = std.unicode.Utf8View.initUnchecked(buf);
    var it = view.iterator();
    var count: usize = 0;
    while (it.i < buf.len) {
        if (count == target) return it.i;
        _ = it.nextCodepoint();
        count += 1;
    }
    return null;
}

// ============================================================
// Constructors
// ============================================================

/// `String()` / `String(chars: CharArray)` / `String(chars, offset, length)`
/// / `String(other: CharSequence)`. klio registers `String` as a host ctor so
/// these shapes don't hit a 0-arg-only declaration.
pub fn string_ctor(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) {
        return ok(.{ .String = try StringRef.initOwned(a, try a.dupe(u8, "")) });
    }
    switch (ctx.args[0]) {
        // CharArray is a Value.Array, but some producers (e.g. toCharArray)
        // yield a Value.List of chars — accept either.
        .Array, .List => {
            const items_ref: ValueList = switch (ctx.args[0]) {
                .Array => |arr| arr.items,
                .List => |l| l.items,
                else => unreachable,
            };
            const prim_is_byte: bool = switch (ctx.args[0]) {
                .Array => |arr| if (arr.prim) |p| (p == .Byte or p == .UByte) else false,
                else => false,
            };
            const g = items_ref.borrow();
            defer g.deinit();
            const elems = g.get().items;

            var start: usize = 0;
            var count: usize = elems.len;
            if (ctx.args.len >= 3) {
                const off = ctx.args[1].asI64() orelse 0;
                const cnt = ctx.args[2].asI64() orelse 0;
                start = @intCast(@max(off, 0));
                count = @intCast(@max(cnt, 0));
            }
            const end = @min(start +| count, elems.len);
            if (start > elems.len or end > elems.len) {
                const msg = try std.fmt.allocPrint(a, "offset {d}, count {d}, size {d}", .{ start, count, elems.len });
                defer if (runtime.reclaimEnabled()) a.free(msg);
                return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
            }

            // `String(ByteArray[, offset, length][, charset])` decodes
            // bytes as UTF-8; `String(CharArray[, offset, count])` builds
            // from UTF-16 code units. `byteArrayOf` tags its array
            // `prim = Byte` even though the literal elements arrive as
            // `Int`, so key off the array kind (with an element-kind
            // fallback) rather than reading every slot as a NUL char.
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
                return ok(.{ .String = try StringRef.initOwned(a, s) });
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
                return ok(.{ .String = try StringRef.initOwned(a, s) });
            }
        },
        .String => |s| {
            const sg = s.borrow();
            defer sg.deinit();
            const dup = try a.dupe(u8, sg.get().*);
            return ok(.{ .String = try StringRef.initOwned(a, dup) });
        },
        .StringBuilder => |sb| {
            const sg = sb.borrow();
            defer sg.deinit();
            const dup = try a.dupe(u8, sg.get().items);
            return ok(.{ .String = try StringRef.initOwned(a, dup) });
        },
        else => {
            const s = try displayValue(a, ctx.args[0]);
            return ok(.{ .String = try StringRef.initOwned(a, s) });
        },
    }
}

/// `String::from_utf8_lossy` — decode UTF-8, replacing each invalid byte
/// sequence with U+FFFD. Caller owns the result.
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
        // empty buffer
    } else if (ctx.args.len == 1) {
        switch (ctx.args[0]) {
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                try buf.appendSlice(a, g.get().*);
            },
            .Int => |n| {
                if (n < 0) {
                    buf.deinit(a);
                    const msg = try std.fmt.allocPrint(a, "{d}", .{n});
                    defer if (runtime.reclaimEnabled()) a.free(msg);
                    return thrown(a, "kotlin.NegativeArraySizeException", msg);
                }
                try buf.ensureTotalCapacity(a, @intCast(n));
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
    return ok(.{ .StringBuilder = try StringBuilderRef.init(a, buf) });
}

// ============================================================
// Range ops (UTF-16 unit based)
// ============================================================

/// `StringBuilder.setRange(startIndex, endIndex, value: String)` — replace
/// the UTF-16 units in `[startIndex, endIndex)` with `value`.
pub fn string_builder_set_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.setRange"));
    const start = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse 0) else 0;
    const end = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
    const value = if (ctx.args.len > 3) (try valueToUtf16(a, ctx.args[3])) else null;
    if (value == null) return errResult(.{ .Type = "setRange value must be a String" });
    defer a.free(value.?);

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    const len: i64 = @intCast(units.len);
    if (start < 0 or start > len or start > end or end > len) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, length: {d}", .{ start, end, len });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }
    const new_units = try spliceUnits(a, units, @intCast(start), @intCast(end), value.?);
    defer a.free(new_units);
    const s = try fromUtf16Lossy(a, new_units);
    defer a.free(s);
    try setBuf(buf, a, s);
    return ok(.{ .StringBuilder = sb });
}

/// `Vec::splice(start..end, value)` — replace `units[start..end]` with
/// `value`. Caller owns the result.
fn spliceUnits(allocator: Allocator, units: []const u16, start: usize, end: usize, value: []const u16) Allocator.Error![]u16 {
    const head = units[0..start];
    const tail = units[end..];
    var out = try allocator.alloc(u16, head.len + value.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len .. head.len + value.len], value);
    @memcpy(out[head.len + value.len ..], tail);
    return out;
}

/// `StringBuilder.appendRange(value, startIndex, endIndex)` — append
/// `value[startIndex, endIndex)` (CharArray or CharSequence).
pub fn string_builder_append_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.appendRange"));
    const value = if (ctx.args.len > 1) (try valueToUtf16(a, ctx.args[1])) else null;
    if (value == null) return errResult(.{ .Type = "appendRange value must be a CharArray/CharSequence" });
    defer a.free(value.?);
    const vlen: i64 = @intCast(value.?.len);
    const start = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
    const end = if (ctx.args.len > 3) (ctx.args[3].asI64() orelse vlen) else vlen;
    if (start < 0 or start > end or end > vlen) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, vlen });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }
    const slice = value.?[@intCast(start)..@intCast(end)];

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    const combined = try std.mem.concat(a, u16, &.{ units, slice });
    defer a.free(combined);
    const s = try fromUtf16Lossy(a, combined);
    defer a.free(s);
    try setBuf(buf, a, s);
    return ok(.{ .StringBuilder = sb });
}

/// `StringBuilder.insertRange(index, value, startIndex, endIndex)` — insert
/// `value[startIndex, endIndex)` at `index`.
pub fn string_builder_insert_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.insertRange"));
    const index = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse 0) else 0;
    const value = if (ctx.args.len > 2) (try valueToUtf16(a, ctx.args[2])) else null;
    if (value == null) return errResult(.{ .Type = "insertRange value must be a CharArray/CharSequence" });
    defer a.free(value.?);
    const vlen: i64 = @intCast(value.?.len);
    const start = if (ctx.args.len > 3) (ctx.args[3].asI64() orelse 0) else 0;
    const end = if (ctx.args.len > 4) (ctx.args[4].asI64() orelse vlen) else vlen;
    if (start < 0 or start > end or end > vlen) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, vlen });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    const len: i64 = @intCast(units.len);
    if (index < 0 or index > len) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ index, len });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }
    const slice = value.?[@intCast(start)..@intCast(end)];
    const new_units = try spliceUnits(a, units, @intCast(index), @intCast(index), slice);
    defer a.free(new_units);
    const s = try fromUtf16Lossy(a, new_units);
    defer a.free(s);
    try setBuf(buf, a, s);
    return ok(.{ .StringBuilder = sb });
}

// ============================================================
// Append / set / length / get
// ============================================================

pub fn string_builder_append(ctx: *CallCtx) Allocator.Error!EvalResult {
    // `append(value: CharSequence?/CharArray, startIndex: Int, endIndex: Int)`
    // is the subrange overload — it appends `value[startIndex, endIndex)`, not
    // the three arguments separately. Detect it (a CharSequence/CharArray
    // value followed by two Ints) and route to the range append; everything
    // else is the single-value `append`.
    if (ctx.args.len == 4 and isCharSeqOrArray(ctx.args[1]) and
        ctx.args[2].asI64() != null and ctx.args[3].asI64() != null)
    {
        return string_builder_append_range(ctx);
    }
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.append"));
    {
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        for (ctx.args[1..]) |v| {
            try appendValue(buf, a, v);
        }
    }
    return ok(.{ .StringBuilder = sb });
}

fn isCharSeqOrArray(v: Value) bool {
    return switch (v) {
        .String, .StringBuilder, .Array => true,
        else => false,
    };
}

/// `StringBuilder.set(index, value: Char)` (`sb[i] = c`) — replace the
/// UTF-16 unit at `index`, in place.
pub fn string_builder_set(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.set"));
    const index = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (index == null) return errResult(.{ .Type = "StringBuilder.set index must be an Int" });
    if (ctx.args.len < 3 or ctx.args[2] != .Char) {
        return errResult(.{ .Type = "StringBuilder.set value must be a Char" });
    }
    const unit = ctx.args[2].Char;

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    var units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    if (index.? < 0 or @as(usize, @intCast(index.?)) >= units.len) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ index.?, units.len });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
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
    {
        const g = sb.borrowMut();
        defer g.deinit();
        const buf = g.get();
        for (ctx.args[1..]) |v| {
            try appendValue(buf, a, v);
        }
        try buf.append(a, '\n');
    }
    return ok(.{ .StringBuilder = sb });
}

pub fn string_builder_length(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.length"));
    const g = sb.borrow();
    defer g.deinit();
    return ok(Value.newInt(@intCast(charCount(g.get().items))));
}

pub fn string_builder_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.toString"));
    const g = sb.borrow();
    defer g.deinit();
    const dup = try a.dupe(u8, g.get().items);
    return ok(.{ .String = try StringRef.initOwned(a, dup) });
}

pub fn string_builder_get(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.get"));
    const idx = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (idx == null) return errResult(.{ .Type = "StringBuilder[index] requires Int" });

    const g = sb.borrow();
    defer g.deinit();
    const buf = g.get().items;
    const units = try encodeUtf16(a, buf);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    return ok(.{ .Char = units[@intCast(idx.?)] });
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
        const g = sb.borrowMut();
        defer g.deinit();
        g.get().clearRetainingCapacity();
    }
    return ok(.{ .StringBuilder = sb });
}

// ============================================================
// Char-index ops (Kotlin `char` based)
// ============================================================

pub fn string_builder_insert(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.insert"));
    const idx = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (idx == null) return errResult(.{ .Type = "insert index must be Int" });
    if (ctx.args.len < 3) return errResult(.{ .Arity = "insert requires a value" });

    var piece: Buffer = .empty;
    defer piece.deinit(a);
    try appendValue(&piece, a, ctx.args[2]);

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const n: i64 = @intCast(charCount(buf.items));
    if (idx.? < 0 or idx.? > n) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    const byte = sbCharByte(buf.items, idx.?).?;
    try buf.insertSlice(a, byte, piece.items);
    return ok(.{ .StringBuilder = sb });
}

pub fn string_builder_delete_at(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.deleteAt"));
    const idx = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (idx == null) return errResult(.{ .Type = "deleteAt index must be Int" });

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const n: i64 = @intCast(charCount(buf.items));
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    const byte = sbCharByte(buf.items, idx.?).?;
    const ch_len = std.unicode.utf8ByteSequenceLength(buf.items[byte]) catch 1;
    try replaceRange(buf, a, byte, byte + ch_len, "");
    return ok(.{ .StringBuilder = sb });
}

pub fn string_builder_delete_range(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.deleteRange"));
    const start = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (start == null) return errResult(.{ .Type = "deleteRange start must be Int" });
    const end = if (ctx.args.len > 2) ctx.args[2].asI64() else null;
    if (end == null) return errResult(.{ .Type = "deleteRange end must be Int" });

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const n: i64 = @intCast(charCount(buf.items));
    if (start.? < 0 or end.? > n or start.? > end.?) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, length: {d}", .{ start.?, end.?, n });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    const sb_byte = sbCharByte(buf.items, start.?).?;
    const eb_byte = sbCharByte(buf.items, end.?).?;
    try replaceRange(buf, a, sb_byte, eb_byte, "");
    return ok(.{ .StringBuilder = sb });
}

/// `String::replace_range(start_byte..end_byte, repl)` — splice `repl` over a
/// byte range of the buffer.
fn replaceRange(buf: *Buffer, allocator: Allocator, start_byte: usize, end_byte: usize, repl: []const u8) Allocator.Error!void {
    const head = buf.items[0..start_byte];
    const tail = buf.items[end_byte..];
    var out = try allocator.alloc(u8, head.len + repl.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len .. head.len + repl.len], repl);
    @memcpy(out[head.len + repl.len ..], tail);
    defer allocator.free(out);
    try setBuf(buf, allocator, out);
}

pub fn string_builder_set_length(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.setLength"));
    const new_len = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (new_len == null) return errResult(.{ .Type = "setLength requires Int" });
    if (new_len.? < 0) {
        const msg = try std.fmt.allocPrint(a, "newLength: {d}", .{new_len.?});
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const cur: i64 = @intCast(charCount(buf.items));
    if (new_len.? <= cur) {
        const byte = sbCharByte(buf.items, new_len.?).?;
        buf.shrinkRetainingCapacity(byte);
    } else {
        var i: i64 = cur;
        while (i < new_len.?) : (i += 1) {
            try buf.append(a, 0);
        }
    }
    return ok(.Unit);
}

pub fn string_builder_reverse(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.reverse"));
    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    // Reverse by Kotlin `char` (UTF-8 scalar), mirroring `chars().rev()`.
    var rev: std.ArrayList(u8) = .empty;
    defer rev.deinit(a);
    var view = std.unicode.Utf8View.initUnchecked(buf.items);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        try rev.insertSlice(a, 0, slice);
    }
    try setBuf(buf, a, rev.items);
    return ok(.{ .StringBuilder = sb });
}

pub fn string_builder_substring(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.substring"));
    const start = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (start == null) return errResult(.{ .Type = "substring start must be Int" });

    const g = sb.borrow();
    defer g.deinit();
    const buf = g.get().items;
    const n: i64 = @intCast(charCount(buf));
    var end: i64 = n;
    if (ctx.args.len > 2) {
        if (ctx.args[2].isIntegral()) {
            end = ctx.args[2].asI64().?;
        } else {
            return errResult(.{ .Type = "substring end must be Int" });
        }
    }
    if (start.? < 0 or end > n or start.? > end) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, length: {d}", .{ start.?, end, n });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    const sb_byte = sbCharByte(buf, start.?).?;
    const eb_byte = sbCharByte(buf, end).?;
    const dup = try a.dupe(u8, buf[sb_byte..eb_byte]);
    return ok(.{ .String = try StringRef.initOwned(a, dup) });
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

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const n: i64 = @intCast(charCount(buf.items));
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    const byte = sbCharByte(buf.items, idx.?).?;
    const old_len = std.unicode.utf8ByteSequenceLength(buf.items[byte]) catch 1;
    const repl = try charUnitToString(a, ch);
    defer a.free(repl);
    try replaceRange(buf, a, byte, byte + old_len, repl);
    return ok(.Unit);
}

/// `replace(startIndex, endIndex, newString)` — splice `newString` over the
/// `[start, end)` char range. Returns the builder (Kotlin/JVM semantics).
pub fn string_builder_replace(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.replace"));
    const start = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (start == null) return errResult(.{ .Type = "replace start must be Int" });
    const end0 = if (ctx.args.len > 2) ctx.args[2].asI64() else null;
    if (end0 == null) return errResult(.{ .Type = "replace end must be Int" });
    if (ctx.args.len < 4) return errResult(.{ .Type = "replace requires a replacement string" });
    const repl: []const u8 = switch (ctx.args[3]) {
        .String => |s| blk: {
            const sg = s.borrow();
            defer sg.deinit();
            break :blk try a.dupe(u8, sg.get().*);
        },
        else => try displayValue(a, ctx.args[3]),
    };
    defer a.free(repl);

    const g = sb.borrowMut();
    defer g.deinit();
    const buf = g.get();
    const n: i64 = @intCast(charCount(buf.items));
    if (start.? < 0 or start.? > n or start.? > end0.?) {
        const msg = try std.fmt.allocPrint(a, "start {d}, end {d}, length {d}", .{ start.?, end0.?, n });
        defer if (runtime.reclaimEnabled()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    // Kotlin/JVM clamps the end to the current length.
    const end = @min(end0.?, n);
    const sb_byte = sbCharByte(buf.items, start.?).?;
    const eb_byte = sbCharByte(buf.items, end).?;
    try replaceRange(buf, a, sb_byte, eb_byte, repl);
    return ok(.{ .StringBuilder = sb });
}

pub fn string_builder_last_index(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.lastIndex"));
    const g = sb.borrow();
    defer g.deinit();
    const n: i64 = @intCast(charCount(g.get().items));
    return ok(Value.newInt(n - 1));
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn newSb(a: Allocator, seed: []const u8) Allocator.Error!Value {
    var buf: Buffer = .empty;
    try buf.appendSlice(a, seed);
    return .{ .StringBuilder = try StringBuilderRef.init(a, buf) };
}

/// Free a produced value and its backing heap. Under reclaim the `StringRef`
/// cell owns its `[]const u8` and frees it on `deinit`, so dropping the cell
/// is enough; under the arena fast path `deinit` is a no-op and the arena
/// reclaims the bytes wholesale.
fn freeSb(v: Value, a: Allocator) void {
    _ = a;
    switch (v) {
        .StringBuilder => |sb| sb.deinit(),
        .String => |s| {
            s.deinit();
        },
        .Exception => |e| {
            e.fqn.deinit();
            if (e.message) |m| {
                m.deinit();
            }
        },
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
    const seed = try StringRef.init(a, "hi");
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
    try testing.expectEqualStrings("kotlin.NegativeArraySizeException", r.err.Thrown.exceptionFqn().?);
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
    _ = try string_builder_append(&c);
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
    _ = try string_builder_append(&c);
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
    const s = try StringRef.init(a, "hi");
    defer s.deinit();
    var args = [_]Value{ sb, .{ .String = s } };
    var c = tc.ctx(a, &args);
    _ = try string_builder_append_line(&c);
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
    const s = try StringRef.init(a, "abcdef");
    defer s.deinit();
    var args = [_]Value{ sb, .{ .String = s }, .{ .Int = 1 }, .{ .Int = 4 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_append(&c);
    try testing.expect(r == .ok);
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
    try testing.expectEqualStrings("data", g.get().*);
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
        try testing.expectEqualStrings("kotlin.IndexOutOfBoundsException", r.err.Thrown.exceptionFqn().?);
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
    _ = try string_builder_clear(&c);
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
    _ = try string_builder_insert(&c);
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
    _ = try string_builder_delete_at(&c);
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
    _ = try string_builder_delete_range(&c);
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
        _ = try string_builder_set_length(&c);
        const g = sb.StringBuilder.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("abc", g.get().items);
    }
    {
        const sb = try newSb(a, "ab");
        defer freeSb(sb, a);
        var args = [_]Value{ sb, .{ .Int = 4 } };
        var c = tc.ctx(a, &args);
        _ = try string_builder_set_length(&c);
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
    _ = try string_builder_reverse(&c);
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
    try testing.expectEqualStrings("bcd", g.get().*);
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
    const repl = try StringRef.init(a, "XY");
    defer repl.deinit();
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Int = 4 }, .{ .String = repl } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_replace(&c);
    try testing.expect(r == .ok);
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
    const val = try StringRef.init(a, "Z");
    defer val.deinit();
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .Int = 4 }, .{ .String = val } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_set_range(&c);
    try testing.expect(r == .ok);
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
    const val = try StringRef.init(a, "abcdef");
    defer val.deinit();
    var args = [_]Value{ sb, .{ .String = val }, .{ .Int = 2 }, .{ .Int = 5 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_append_range(&c);
    try testing.expect(r == .ok);
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
    const val = try StringRef.init(a, "abcdef");
    defer val.deinit();
    var args = [_]Value{ sb, .{ .Int = 1 }, .{ .String = val }, .{ .Int = 1 }, .{ .Int = 3 } };
    var c = tc.ctx(a, &args);
    const r = try string_builder_insert_range(&c);
    try testing.expect(r == .ok);
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
        try testing.expectEqualStrings("", g.get().*);
    }
    {
        const s = try StringRef.init(a, "hello");
        defer s.deinit();
        var args = [_]Value{.{ .String = s }};
        var c = tc.ctx(a, &args);
        const r = try string_ctor(&c);
        defer freeSb(r.ok, a);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("hello", g.get().*);
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
    var args = [_]Value{.{ .Array = .{ .items = list, .prim = .Char } }};
    var c = tc.ctx(a, &args);
    const r = try string_ctor(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("hi", g.get().*);
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
    var args = [_]Value{.{ .Array = .{ .items = list, .prim = .Byte } }};
    var c = tc.ctx(a, &args);
    const r = try string_ctor(&c);
    try testing.expect(r == .ok);
    defer freeSb(r.ok, a);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("hi", g.get().*);
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
