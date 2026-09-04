//! StringBuilder stdlib intrinsics.
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`. A `StringBuilder` value
//! is an `ObjRef(std.ArrayList(u8))` holding the buffer as UTF-8 bytes; the
//! range/index operations that Kotlin defines over UTF-16 code units convert
//! between the UTF-8 buffer and a `[]u16` view as needed.

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

// ============================================================
// Shared helpers
// ============================================================

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

/// Return the *receiver* StringBuilder (the fluent `append`/`insert`/… methods
/// hand `this` back for chaining). Host calls return owned values and the
/// dispatch writes the result into a register that takes ownership, so retain
/// the borrowed receiver first or it is released one time too many when that
/// register is overwritten/torn down. No-op under the arena fast path.
fn okSb(sb: StringBuilderRef) EvalResult {
    const v = Value{ .StringBuilder = sb };
    v.retain();
    return .{ .ok = v };
}

fn errResult(e: RuntimeError) EvalResult {
    return .{ .err = e };
}

/// `make_exception(fqn, message)` — build a thrown Kotlin Throwable value.
/// `fqn` is a static slice; `message`, when present, is owned by `allocator`.
fn makeException(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!Value {
    return try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, fqn),
        .message = .from(if (message) |m| try runtime.strInit(allocator, m) else null),
        .cause = null,
    });
}

/// `RuntimeError::Thrown(make_exception(...))` as an `EvalResult` error.
fn thrown(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalResult {
    return errResult(.{ .Thrown = try makeException(allocator, fqn, message) });
}

/// The `StringBuilder` receiver in `args[0]`, or `null`; the caller turns
/// `null` into a `Type` error via `sbTypeError`.
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

/// Number of Kotlin `Char`s = UTF-16 code units: an astral scalar is two units
/// (a surrogate pair), a lone WTF-8 surrogate and any BMP scalar are one. For a
/// surrogate-free string this equals the scalar count, so normal text is
/// unaffected.
/// Reader-side memo for ONE builder: ASCII-ness, UTF-16 length, and a
/// UTF-16/byte cursor, keyed by the builder's cell and its buffer identity.
/// Every mutating builtin (through `sbMut`) and every construction of a
/// builder invalidates a memo on that cell, so a read-only phase — the okio
/// shim's reader doing `sb[pos++]` and `sb.length` per code point over a
/// 150 KB JSON buffer — costs O(1) per read instead of re-encoding the
/// whole buffer, while any write simply recomputes on the next read.
const SbMemo = struct {
    cell: usize = 0,
    ptr: [*]const u8 = undefined,
    len: usize = 0,
    ascii: bool = false,
    u16_len: usize = 0,
    u16_pos: usize = 0,
    byte_pos: usize = 0,
};
threadlocal var sb_memo: SbMemo = .{};

pub fn sbMemoInvalidate(cell: usize) void {
    if (sb_memo.cell == cell) sb_memo.cell = 0;
}

fn sbMut(sb: anytype) @TypeOf(sb.borrowMut()) {
    sbMemoInvalidate(@intFromPtr(sb.cell));
    return sb.borrowMut();
}

fn sbMemoFor(sb: anytype, items: []const u8) *SbMemo {
    const key = @intFromPtr(sb.cell);
    if (sb_memo.cell == key and sb_memo.ptr == items.ptr and sb_memo.len == items.len) return &sb_memo;
    var ascii = true;
    for (items) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    sb_memo = .{
        .cell = key,
        .ptr = items.ptr,
        .len = items.len,
        .ascii = ascii,
        .u16_len = if (ascii) items.len else charCount(items),
    };
    return &sb_memo;
}

/// The UTF-16 unit at index `idx` of a non-ASCII buffer, resuming from the
/// memo's cursor when it is at or before the target and leaving the cursor
/// on the character found, so a sequential read stays linear.
fn sbUnitAt(m: *SbMemo, s: []const u8, idx: usize) ?u16 {
    var n: usize = 0;
    var i: usize = 0;
    if (m.u16_pos <= idx and m.byte_pos <= s.len) {
        n = m.u16_pos;
        i = m.byte_pos;
    }
    while (i < s.len) {
        if (runtime.isWtf8SurrogateAt(s, i)) {
            if (n == idx) {
                m.u16_pos = n;
                m.byte_pos = i;
                const unit: u16 = (@as(u16, s[i] & 0x0F) << 12) | (@as(u16, s[i + 1] & 0x3F) << 6) | @as(u16, s[i + 2] & 0x3F);
                return unit;
            }
            n += 1;
            i += 3;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch s[i];
        const units: usize = if (cp > 0xFFFF) 2 else 1;
        if (idx < n + units) {
            m.u16_pos = n;
            m.byte_pos = i;
            if (cp <= 0xFFFF) return @intCast(cp);
            const v = cp - 0x10000;
            return if (idx == n) @intCast(0xD800 + (v >> 10)) else @intCast(0xDC00 + (v & 0x3FF));
        }
        n += units;
        i = end;
    }
    return null;
}

fn charCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (runtime.isWtf8SurrogateAt(s, i)) {
            n += 1;
            i += 3;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch s[i];
        n += if (cp > 0xFFFF) 2 else 1;
        i = end;
    }
    return n;
}

/// Decode `s` to UTF-16 code units (WTF-8 lone surrogates kept as their unit).
/// Caller owns the result.
fn bufUnits(a: Allocator, s: []const u8) Allocator.Error![]u16 {
    return encodeUtf16(a, s);
}

/// Re-encode UTF-16 `units` to a WTF-8 byte buffer (surrogate pairs coalesced
/// into astral scalars, lone surrogates kept as WTF-8) and install it as the
/// builder's contents.
fn setBufUnits(buf: *Buffer, a: Allocator, units: []const u16) Allocator.Error!void {
    const bytes = try runtime.charUnitsToString(a, units);
    defer a.free(bytes);
    try setBuf(buf, a, bytes);
}

/// Render `v` the way Kotlin's `toString` / templates do. Caller owns it.
fn displayValue(allocator: Allocator, v: Value) Allocator.Error![]u8 {
    return v.display(allocator);
}

/// Append `v` to a UTF-8 buffer.
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

/// Whether an instance's class directly declares `CharSequence` among its
/// supertypes — the shapes whose `length` the append/insert overflow guard
/// consults before materialising any content.
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

/// Guard an append/insert of `v` onto `sb`: when the argument's length is
/// knowable up front (strings, builders, user CharSequences via their
/// `length` property) and the combined UTF-16 length exceeds
/// `Int.MAX_VALUE`, throw OutOfMemoryError BEFORE materialising anything —
/// the JVM builder grows capacity first, so an overflowing CharSequence's
/// chars are never read.
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
            const r = ctx.host.getProperty(v, "length", ctx.out) catch return null;
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
        return try thrown(ctx.allocator, "kotlin.OutOfMemoryError", "Requested character sequence exceeds the maximum length");
    }
    return null;
}

/// The text `append(value)` / `insert(_, value)` writes for `value`. Owned by
/// the caller. Unlike `appendValue` this renders a `StringBuilder` as its
/// content, a `CharArray` as its characters, and any other object via its
/// `toString()` (run through the host) — matching `append(CharSequence)` /
/// `append(CharArray)` / `append(Any?)`. Rendered before the receiver buffer
/// is borrowed so a user `toString()` can run without holding that borrow.
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
        // `append(Any?)` calls the value's `toString()` — a user override on an
        // instance, and a container's own rendering, which is what makes its
        // ELEMENTS' overrides fire (the structural renderer prints
        // `ClassName@id` for a user element).
        .Instance, .List, .Set, .Map, .Pair, .Triple, .Result => {
            if (try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out)) |res| {
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

/// The UTF-16 units of a `CharArray` / `CharSequence` / `Char` argument, for
/// the range ops. Caller owns the result; `null` if `v` is not such a value.
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

fn rangeOob(allocator: Allocator, msg: []const u8) Allocator.Error!RuntimeError {
    return .{ .Thrown = try makeException(allocator, "kotlin.IndexOutOfBoundsException", msg) };
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
        return ok(.{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "")) });
    }
    switch (ctx.args[0]) {
        // CharArray is a Value.Array, but some producers (e.g. toCharArray)
        // yield a Value.List of chars — accept either.
        .Array, .List => {
            const prim_is_byte: bool = switch (ctx.args[0]) {
                .Array => |arr| if (arr.prim) |p| (p == .Byte or p == .UByte) else false,
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
                // `String(chars, offset, count)` throws when offset or count
                // is negative or the slice runs past the array end (JVM's
                // StringIndexOutOfBoundsException, an IndexOutOfBoundsException).
                if (off < 0 or cnt < 0 or off > size - cnt) {
                    const msg = try std.fmt.allocPrint(a, "offset {d}, count {d}, size {d}", .{ off, cnt, size });
                    defer if (runtime.freeScratch()) a.free(msg);
                    return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
                }
                start = @intCast(off);
                count = @intCast(cnt);
            }
            const end = @min(start +| count, elems.len);

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
                try buf.appendSlice(a, g.get().bytes);
            },
            .Int => |n| {
                if (n < 0) {
                    buf.deinit(a);
                    const msg = try std.fmt.allocPrint(a, "{d}", .{n});
                    defer if (runtime.freeScratch()) a.free(msg);
                    return thrown(a, "kotlin.NegativeArraySizeException", msg);
                }
                try buf.ensureTotalCapacityPrecise(a, @intCast(n));
            },
            // `StringBuilder(content: CharSequence)` — seed from another
            // builder's current contents.
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

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    const len: i64 = @intCast(units.len);
    // Throw only for start < 0, start > length, or start > endIndex; an
    // endIndex past the length is clamped (Kotlin/JVM semantics).
    if (start < 0 or start > len or start > end) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, length: {d}", .{ start, end, len });
        defer if (runtime.freeScratch()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }
    const clamped_end = @min(end, len);
    const new_units = try spliceUnits(a, units, @intCast(start), @intCast(clamped_end), value.?);
    defer a.free(new_units);
    const s = try fromUtf16Lossy(a, new_units);
    defer a.free(s);
    try setBuf(buf, a, s);
    return okSb(sb);
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
    // A `String` value appends its byte range directly: the range's bytes
    // come from the string's own UTF-16 cursor, and the builder's buffer is
    // never re-encoded (an escaper appending run after run of a long text
    // was quadratic in both).
    if (ctx.args.len > 1 and ctx.args[1] == .String) {
        const g = ctx.args[1].String.borrow();
        defer g.deinit();
        const d = g.get();
        const vlen: i64 = @intCast(d.u16_len);
        const start = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
        const end = if (ctx.args.len > 3) (ctx.args[3].asI64() orelse vlen) else vlen;
        if (start < 0 or start > end or end > vlen) {
            const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, vlen });
            defer if (runtime.freeScratch()) a.free(msg);
            return errResult(try rangeOob(a, msg));
        }
        const range = string.utf16RangeBytes(d, @intCast(start), @intCast(end));
        const gb = sbMut(sb);
        defer gb.deinit();
        try gb.get().appendSlice(a, d.bytes[range[0]..range[1]]);
        return okSb(sb);
    }
    const value = if (ctx.args.len > 1) (try valueToUtf16(a, ctx.args[1])) else null;
    if (value == null) return errResult(.{ .Type = "appendRange value must be a CharArray/CharSequence" });
    defer a.free(value.?);
    const vlen: i64 = @intCast(value.?.len);
    const start = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
    const end = if (ctx.args.len > 3) (ctx.args[3].asI64() orelse vlen) else vlen;
    if (start < 0 or start > end or end > vlen) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, vlen });
        defer if (runtime.freeScratch()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }
    const slice = value.?[@intCast(start)..@intCast(end)];

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
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ index, len });
        defer if (runtime.freeScratch()) a.free(msg);
        return errResult(try rangeOob(a, msg));
    }
    const slice = value.?[@intCast(start)..@intCast(end)];
    const new_units = try spliceUnits(a, units, @intCast(index), @intCast(index), slice);
    defer a.free(new_units);
    const s = try fromUtf16Lossy(a, new_units);
    defer a.free(s);
    try setBuf(buf, a, s);
    return okSb(sb);
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
        // `append(str: CharArray, offset, len)` is a deprecated stub that always
        // throws (KT-15220); the real CharArray subrange is `appendRange`. Only
        // the `CharSequence` subrange overload appends `value[start, end)`.
        if (ctx.args[1] == .Array) {
            return thrown(ctx.allocator, "kotlin.NotImplementedError", "An operation is not implemented.");
        }
        return string_builder_append_range(ctx);
    }
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.append"));
    // Render each argument before borrowing the buffer: a user `toString()`
    // must not run while the receiver buffer is held mutably.
    for (ctx.args[1..]) |v| {
        if (try appendOverflowGuard(ctx, sb, &v)) |oom| return oom;
        const piece = try renderPiece(ctx, v);
        defer a.free(piece);
        const g = sbMut(sb);
        defer g.deinit();
        try g.get().appendSlice(a, piece);
    }
    return okSb(sb);
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

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    var units = try encodeUtf16(a, buf.items);
    defer a.free(units);
    if (index.? < 0 or @as(usize, @intCast(index.?)) >= units.len) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ index.?, units.len });
        defer if (runtime.freeScratch()) a.free(msg);
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

/// `StringBuilder.capacity()` — the backing buffer's current capacity (always
/// >= length). `StringBuilder(n)` reserves exactly `n`.
pub fn string_builder_capacity(ctx: *CallCtx) Allocator.Error!EvalResult {
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.capacity"));
    const g = sb.borrow();
    defer g.deinit();
    return ok(Value.newInt(@intCast(g.get().capacity)));
}

/// `StringBuilder.ensureCapacity(minimumCapacity)` — grow the backing buffer so
/// its capacity is at least `minimumCapacity`; a non-positive argument is
/// ignored (matching the JVM contract).
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

/// `StringBuilder.trimToSize()` — a capacity hint with no observable effect
/// on the contents (klio's buffer has no separate capacity to shrink).
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
    // Coalesce any WTF-8 surrogate pairs accumulated from individual `Char`
    // appends into astral scalars, so the result is canonical UTF-8 (a builder
    // fed a high+low pair equals the astral string literal).
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
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    const ui: usize = @intCast(idx.?);
    if (m.ascii) return ok(.{ .Char = buf[ui] });
    if (sbUnitAt(m, buf, ui)) |u| return ok(.{ .Char = u });
    const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
    defer if (runtime.freeScratch()) a.free(msg);
    return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
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

// ============================================================
// Char-index ops (Kotlin `char` based)
// ============================================================

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

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    // Splice in UTF-16-unit space so the insert index matches Kotlin even when
    // the buffer (or piece) contains astral chars / lone surrogates.
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (idx.? < 0 or idx.? > n) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
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

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
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

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    // Kotlin throws only for startIndex < 0, > length, or > endIndex; an
    // endIndex past the length is clamped (deletes through the end).
    if (start.? < 0 or start.? > n or start.? > end.?) {
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, length: {d}", .{ start.?, end.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
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
        const msg = try std.fmt.allocPrint(a, "newLength: {d}", .{new_len.?});
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const cur: usize = units.len;
    const target: usize = @intCast(new_len.?);
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
    const g = sbMut(sb);
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
    return okSb(sb);
}

pub fn string_builder_substring(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.substring"));
    // `subSequence(range: IntRange)` — a single range argument whose `first`
    // and `last + 1` are the substring bounds.
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
        const msg = try std.fmt.allocPrint(a, "startIndex: {d}, endIndex: {d}, length: {d}", .{ start.?, end, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
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

    const g = sbMut(sb);
    defer g.deinit();
    const buf = g.get();
    const units = try bufUnits(a, buf.items);
    defer a.free(units);
    const n: i64 = @intCast(units.len);
    if (idx.? < 0 or idx.? >= n) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, length: {d}", .{ idx.?, n });
        defer if (runtime.freeScratch()) a.free(msg);
        return thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    }
    units[@intCast(idx.?)] = ch;
    try setBufUnits(buf, a, units);
    return ok(.Unit);
}

/// `replace(startIndex, endIndex, newString)` — splice `newString` over the
/// `[start, end)` char range. Returns the builder (Kotlin/JVM semantics).
pub fn string_builder_replace(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const sb = sbArg(ctx.args) orelse return errResult(sbTypeError("StringBuilder.replace"));
    // The CharSequence `replace(oldValue, newValue[, ignoreCase])` and
    // `replace(regex, replacement/transform)` extensions share this name with the
    // Java `replace(start: Int, end: Int, str)` range mutator; a non-integer
    // second argument is one of the extensions — snapshot the receiver as a
    // String and route it to the String intrinsic.
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn newSb(a: Allocator, seed: []const u8) Allocator.Error!Value {
    var buf: Buffer = .empty;
    try buf.appendSlice(a, seed);
    const ref = try StringBuilderRef.init(a, buf);
    sbMemoInvalidate(@intFromPtr(ref.cell));
    return .{ .StringBuilder = ref };
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
