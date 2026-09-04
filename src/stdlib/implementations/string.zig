//! String stdlib intrinsics.
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`. For member access the
//! receiver is `args[0]`, with any further user arguments following. A
//! `RuntimeError` surfaces as data via `EvalResult`; OOM surfaces as a Zig
//! error. Heap that an intrinsic produces is allocated with `ctx.allocator`.

const std = @import("std");
const runtime = @import("runtime");
const text = @import("../text.zig");
const regexp = @import("regexp.zig");
const char = @import("char.zig");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const SequenceData = runtime.SequenceData;
const SequenceSource = runtime.SequenceSource;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const charUnitsToString = runtime.charUnitsToString;
const charUnitToString = runtime.charUnitToString;
const isWtf8SurrogateAt = runtime.isWtf8SurrogateAt;
const wtf8SurrogateUnit = runtime.wtf8SurrogateUnit;
const coalesceSurrogates = runtime.coalesceSurrogates;

const Allocator = std.mem.Allocator;

// ============================================================
// Small data-construction helpers.
// ============================================================

fn errType(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

fn errArity(msg: []const u8) EvalResult {
    return .{ .err = .{ .Arity = msg } };
}

/// Build a thrown Kotlin Throwable value. `message` is owned by the
/// allocator (or null). Mirrors `exceptions::make_exception`.
fn makeException(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!Value {
    const fqn_ref = try runtime.strInitOwned(allocator, try allocator.dupe(u8, fqn));
    const msg_ref: ?StringRef = if (message) |m| try runtime.strInit(allocator, m) else null;
    return try Value.newException(allocator, .{ .fqn = fqn_ref, .message = .from(msg_ref), .cause = null });
}

fn thrown(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalResult {
    return .{ .err = .{ .Thrown = try makeException(allocator, fqn, message) } };
}

/// Like `thrown`, but for an OWNED `message` buffer. `makeException` dupes the
/// message under the reclaim path, so the caller's buffer must be freed there
/// to avoid leaking it (the arena fast path reclaims it wholesale).
fn thrownOwned(allocator: Allocator, fqn: []const u8, message: []const u8) Allocator.Error!EvalResult {
    const res = try thrown(allocator, fqn, message);
    if (runtime.freeScratch()) allocator.free(message);
    return res;
}

/// Build a `List` / `MutableList` from an owned slice of values. Mirrors
/// `collections::make_list`.
fn makeList(allocator: Allocator, items: []Value, mutable: bool) Allocator.Error!Value {
    const list = std.ArrayList(Value).fromOwnedSlice(items);
    const items_ref = try ValueList.init(allocator, list);
    return try Value.newList(allocator, .{ .items = items_ref, .mutable = mutable, .enum_entries = false, .backing = null });
}

/// Build an items-only `Sequence` from an owned slice. Mirrors
/// `sequence::make_sequence`. klio collects eagerly, which is faithful for
/// finite inputs (every `String`).
fn makeSequence(allocator: Allocator, items: []Value) Allocator.Error!Value {
    const slice_ref = try runtime.ValueSlice.init(allocator, items);
    const data: SequenceData = .{ .source = .{ .Items = slice_ref }, .ops = &.{} };
    const data_ref = try ObjRef(SequenceData).init(allocator, data);
    return .{ .Sequence = data_ref };
}

/// Wrap an owned `[]const u8` in a fresh `String` value.
fn newString(allocator: Allocator, owned: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInitOwned(allocator, owned) };
}

/// Default radix (10) or the Int radix in `v`. Mirrors `numeric::recv_int_radix`.
fn recvIntRadix(allocator: Allocator, v: ?Value, what: []const u8) Allocator.Error!union(enum) { ok: i64, err: RuntimeError } {
    if (v) |val| {
        if (val.asI64()) |n| return .{ .ok = n };
        const msg = try std.fmt.allocPrint(allocator, "{s} radix must be Int", .{what});
        return .{ .err = .{ .Type = msg } };
    }
    return .{ .ok = 10 };
}

/// Decode a `Char` code unit to a Unicode scalar. A lone surrogate has no
/// scalar value (`null`). Mirrors `char::char_unit_to_scalar`.
fn charUnitToScalar(unit: u16) ?u21 {
    if (unit >= 0xD800 and unit <= 0xDFFF) return null;
    return unit;
}

// ============================================================
// String members (receiver in args[0])
// ============================================================

/// Borrow the `String` receiver's bytes. The slice stays valid for the
/// call: the receiver `String` lives in `ctx.args`.
fn recvString(allocator: Allocator, args: []const Value, what: []const u8) Allocator.Error!union(enum) { ok: []const u8, err: RuntimeError } {
    if (args.len == 0) {
        const msg = try std.fmt.allocPrint(allocator, "{s} requires a receiver", .{what});
        return .{ .err = .{ .Type = msg } };
    }
    switch (args[0]) {
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            noteRecvData(g.get());
            return .{ .ok = g.get().bytes };
        },
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            recv_memo.valid = false;
            return .{ .ok = g.get().items };
        },
        else => |other| {
            const od = try other.display(allocator);
            const msg = try std.fmt.allocPrint(allocator, "{s} requires a String receiver, got {s}", .{ what, od });
            return .{ .err = .{ .Type = msg } };
        },
    }
}

/// Stringify a `String`-like argument. Mirrors `arg_as_string`. Caller
/// owns the returned slice.
fn argAsString(allocator: Allocator, v: Value, what: []const u8) Allocator.Error!union(enum) { ok: []const u8, err: RuntimeError } {
    switch (v) {
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return .{ .ok = try allocator.dupe(u8, g.get().bytes) };
        },
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            return .{ .ok = try allocator.dupe(u8, g.get().items) };
        },
        .Char => |c| return .{ .ok = try charUnitToString(allocator, c) },
        .Int => |n| return .{ .ok = try std.fmt.allocPrint(allocator, "{d}", .{n}) },
        .Double => |d| return .{ .ok = try Value.renderDouble(allocator, d) },
        .Bool => |b| return .{ .ok = try allocator.dupe(u8, if (b) "true" else "false") },
        else => {
            const od = try v.display(allocator);
            const msg = try std.fmt.allocPrint(allocator, "{s} requires a String-like argument, got {s}", .{ what, od });
            return .{ .err = .{ .Type = msg } };
        },
    }
}

/// Number of UTF-16 code units in `s` — Kotlin's `String.length` /
/// indexing unit (an astral scalar counts as 2).
/// True if `s` is pure ASCII (no byte has the high bit set). For an ASCII string
/// the UTF-16 length and indices coincide with byte offsets, so the per-codepoint
/// `utf8Decode` walks collapse to direct byte access. The scan itself is a simple
/// byte loop the compiler vectorizes — far cheaper than decoding each codepoint.
fn asciiScan(s: []const u8) bool {
    if (memoFor(s)) |m| return m.ascii;
    for (s) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

/// The most recent `String` RECEIVER's cached header meta and its cell. The
/// builtins receive bare bytes, so without this every `substring`/
/// `startsWith`/`indexOf` rescanned the whole receiver for ASCII-ness, and
/// a non-ASCII receiver was re-walked from byte 0 on each index conversion:
/// a lexer stepping through a long source one token at a time was
/// quadratic. Keyed by the immutable bytes' address and length; only
/// `String` cells set it (a StringBuilder's buffer mutates in place and is
/// never memoized), and every receiver extraction re-points it, so a slice
/// that matches IS the live receiver's bytes. Walk positions live on the
/// cell's own cursor (see `StringData.cursor`), so they carry across calls
/// and across the other paths that read the same string.
const RecvMemo = struct {
    ptr: [*]const u8 = undefined,
    len: usize = 0,
    valid: bool = false,
    ascii: bool = false,
    u16_len: usize = 0,
    cell: ?*const runtime.StringData = null,

    fn cursor(self: *const RecvMemo) runtime.StringData.Cursor {
        const c = self.cell orelse return .{ .u16_pos = 0, .byte_pos = 0 };
        return c.cursorGet();
    }
    fn save(self: *const RecvMemo, u16_pos: usize, byte_pos: usize) void {
        if (self.cell) |c| c.cursorSet(u16_pos, byte_pos);
    }
};
threadlocal var recv_memo: RecvMemo = .{};

fn memoFor(s: []const u8) ?*RecvMemo {
    if (!recv_memo.valid or recv_memo.ptr != s.ptr or recv_memo.len != s.len) return null;
    return &recv_memo;
}

fn noteRecvData(d: *const runtime.StringData) void {
    if (recv_memo.valid and recv_memo.ptr == d.bytes.ptr and recv_memo.len == d.bytes.len) return;
    recv_memo = .{
        .ptr = d.bytes.ptr,
        .len = d.bytes.len,
        .valid = true,
        .ascii = d.ascii,
        .u16_len = d.u16_len,
        .cell = d,
    };
}

/// Byte offset of the boundary at UTF-16 index `target` in a non-ASCII
/// string, walking from `from` (a known index/offset pair, `0/0` when none).
fn unitBoundaryFrom(s: []const u8, from: runtime.StringData.Cursor, target: usize) runtime.StringData.Cursor {
    var it = Utf16View{ .bytes = s };
    var count: usize = 0;
    if (from.byte_pos <= s.len and from.u16_pos > target) {
        // The cursor is AHEAD of the target (an escaper reads `text[i]`, then
        // appends `text[last, i)`): step back over whole code points from it
        // rather than restarting at byte 0. A 4-byte sequence is one astral
        // scalar (two units); a WTF-8 surrogate or any shorter sequence is
        // one unit. A target inside an astral pair lands after the pair,
        // as the forward walk does.
        var c = from.u16_pos;
        var pos = from.byte_pos;
        while (c > target and pos > 0) {
            var lead = pos - 1;
            while (lead > 0 and (s[lead] & 0xC0) == 0x80) lead -= 1;
            const units: usize = if (pos - lead == 4) 2 else 1;
            if (c - units < target) break;
            c -= units;
            pos = lead;
        }
        return .{ .u16_pos = c, .byte_pos = pos };
    }
    if (from.u16_pos <= target and from.byte_pos <= s.len) {
        count = from.u16_pos;
        it.pos = from.byte_pos;
    }
    while (count < target) {
        _ = it.next() orelse break;
        count += 1;
        if (it.pending_low != null) {
            _ = it.next();
            count += 1;
        }
    }
    return .{ .u16_pos = count, .byte_pos = it.pos };
}

/// The byte range of `d.bytes[start, end)` in UTF-16 indices, through the
/// string's own cursor: advancing ranges over one string (an escaper's
/// `append(text, from, to)` runs) stay linear overall.
pub fn utf16RangeBytes(d: *const runtime.StringData, start: usize, end: usize) [2]usize {
    if (d.ascii) return .{ @min(start, d.bytes.len), @min(end, d.bytes.len) };
    const lo = unitBoundaryFrom(d.bytes, d.cursorGet(), start);
    const hi = unitBoundaryFrom(d.bytes, lo, end);
    d.cursorSet(hi.u16_pos, hi.byte_pos);
    return .{ lo.byte_pos, hi.byte_pos };
}

fn utf16Len(s: []const u8) usize {
    if (memoFor(s)) |m| return m.u16_len;
    if (asciiScan(s)) return s.len; // ASCII: one unit per byte
    var n: usize = 0;
    var it = Utf16View{ .bytes = s };
    while (it.next()) |_| n += 1;
    return n;
}

/// The UTF-16 code unit at index `i` (Kotlin `String` indexing), if any.
/// On the memoized receiver the walk resumes from the last position, so a
/// sequential `s[i]` loop over a non-ASCII string stays linear.
fn utf16UnitAt(s: []const u8, i: usize) ?u16 {
    var n: usize = 0;
    var it = Utf16View{ .bytes = s };
    const memo = memoFor(s);
    if (memo) |m| {
        const c = m.cursor();
        if (c.u16_pos <= i and c.byte_pos <= s.len) {
            n = c.u16_pos;
            it.pos = c.byte_pos;
        }
    }
    while (true) {
        const start = it.pos;
        const u = it.next() orelse return null;
        if (it.pending_low) |low| {
            if (n == i or n + 1 == i) {
                if (memo) |m| m.save(n, start);
                return if (n == i) u else low;
            }
            _ = it.next();
            n += 2;
        } else {
            if (n == i) {
                if (memo) |m| m.save(n, start);
                return u;
            }
            n += 1;
        }
    }
}

/// The UTF-16 code units of `s`, owned by the allocator.
fn utf16Units(allocator: Allocator, s: []const u8) Allocator.Error![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(allocator);
    var it = Utf16View{ .bytes = s };
    while (it.next()) |u| try out.append(allocator, u);
    return out.toOwnedSlice(allocator);
}

/// Case-insensitive equality of two UTF-16 code units (Kotlin's
/// `equals(ignoreCase=true)` per-char rule). Lone surrogates compare by
/// raw equality (no case mapping).
fn charUnitsEqIgnoreCase(a: u16, b: u16) bool {
    const ca = charUnitToScalar(a);
    const cb = charUnitToScalar(b);
    if (ca != null and cb != null) {
        if (ca.? == cb.?) return true;
        // Kotlin's per-char fold: uppercase both; on a miss, lowercase
        // the UPPERCASED forms (not the originals — 'ϑ' uppercases to
        // 'Θ' whose lowercase meets lowercase('ϴ'), while lowercasing
        // the originals directly never converges).
        const ua = scalarToUpper(ca.?);
        const ub = scalarToUpper(cb.?);
        if (ua == ub) return true;
        return scalarToLower(ua) == scalarToLower(ub);
    }
    return a == b;
}

/// The substring spanning UTF-16 units `[start, end)`. Owned by the
/// allocator.
fn utf16Slice(allocator: Allocator, s: []const u8, start: usize, end: usize) Allocator.Error![]u8 {
    // Both boundaries on whole characters: the slice is the bytes between
    // them, found through the receiver's cursor rather than by converting
    // the whole string. A range that splits a surrogate pair keeps the
    // unit path, which renders the lone halves.
    const lo = utf16Boundary(s, start);
    const hi = utf16Boundary(s, end);
    if (lo.u16_pos == start and hi.u16_pos == end and lo.byte_pos <= hi.byte_pos) {
        return allocator.dupe(u8, s[lo.byte_pos..hi.byte_pos]);
    }
    const units = try utf16Units(allocator, s);
    defer allocator.free(units);
    return charUnitsToString(allocator, units[start..end]);
}

pub fn string_length(ctx: *CallCtx) Allocator.Error!EvalResult {
    // O(1): the UTF-16 length is cached on the string at creation.
    if (ctx.args.len > 0 and ctx.args[0] == .String) {
        const g = ctx.args[0].String.borrow();
        defer g.deinit();
        return .{ .ok = Value.newInt(@intCast(g.get().u16_len)) };
    }
    const r = try recvString(ctx.allocator, ctx.args, "String.length");
    return switch (r) {
        .ok => unreachable, // a String receiver was handled above
        .err => |e| .{ .err = e },
    };
}

/// `String.toString()` — the receiver itself.
pub fn string_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .String) {
        const r = try recvString(ctx.allocator, ctx.args, "String.toString");
        switch (r) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = .{ .String = ctx.args[0].String.clone() } };
}

/// `String.encodeToByteArray()` / `String.toByteArray()` — the receiver's
/// UTF-8 bytes as a Kotlin signed `ByteArray`. An explicit charset argument
/// is treated as UTF-8.
pub fn string_to_byte_array(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toByteArray");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // `encodeToByteArray(startIndex, endIndex, throwOnInvalidSequence)` indices
    // are Kotlin char (UTF-16 unit) offsets, not byte offsets; an astral char
    // is a 4-byte UTF-8 sequence counted as two units. `String.toByteArray`
    // (a separate stdlib entry that shares this body) is always called with a
    // charset receiver-arg and no range, so the range path is encode-only.
    const char_len = charLen(s);
    // A range is requested when a positional/named startIndex or endIndex slot
    // carries an integer (a defaulted slot reorders to `Null` and keeps the
    // default). `String.toByteArray` shares this body but always passes only a
    // charset receiver-arg, so it never enters the range/bounds path.
    const has_start = ctx.args.len > 1 and isIntLike(ctx.args[1]);
    const has_end = ctx.args.len > 2 and isIntLike(ctx.args[2]);
    const start = if (has_start) (ctx.args[1].asI64() orelse 0) else 0;
    const end = if (has_end) (ctx.args[2].asI64() orelse char_len) else char_len;
    if (has_start or has_end) {
        // AbstractList.checkBoundsIndexes: OOB throws IndexOutOfBoundsException;
        // start > end throws IllegalArgumentException.
        if (start < 0 or end > char_len) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, char_len });
            return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
        }
        if (start > end) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d} > endIndex: {d}", .{ start, end });
            return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
        }
    }
    // Slice in UTF-16-unit space (decode → slice → re-encode) so a range that
    // splits an astral char's surrogate pair yields the expected lone
    // surrogate, then encode that.
    var unit_list: std.ArrayList(u16) = .empty;
    defer unit_list.deinit(ctx.allocator);
    var uv = Utf16View{ .bytes = s };
    while (uv.next()) |u| try unit_list.append(ctx.allocator, u);
    const slice_owned = try runtime.charUnitsToString(ctx.allocator, unit_list.items[@intCast(start)..@intCast(end)]);
    defer ctx.allocator.free(slice_owned);
    const slice = slice_owned;
    // A lone surrogate (stored as WTF-8) is not valid UTF-8: encodeToByteArray
    // replaces it with U+FFFD by default, or throws CharacterCodingException
    // when `throwOnInvalidSequence` is set. Any Bool argument is that flag.
    var throw_on_invalid = false;
    for (ctx.args[1..]) |arg| {
        if (arg == .Bool) throw_on_invalid = arg.Bool;
    }
    var out: std.ArrayList(Value) = .empty;
    defer out.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < slice.len) {
        if (isWtf8SurrogateAt(slice, i)) {
            if (throw_on_invalid) {
                return try thrown(ctx.allocator, "kotlin.text.CharacterCodingException", "Unmappable character");
            }
            for ([_]u8{ 0xEF, 0xBF, 0xBD }) |b| try out.append(ctx.allocator, .{ .Byte = @bitCast(b) });
            i += 3;
        } else {
            try out.append(ctx.allocator, .{ .Byte = @bitCast(slice[i]) });
            i += 1;
        }
    }
    return .{ .ok = try runtime.ArrayData.initPacked(ctx.allocator, .Byte, out.items) };
}

/// Number of Kotlin char (UTF-16) units the UTF-8 string `s` decodes to: a
/// 4-byte sequence (astral plane) is two units, everything else is one.
fn charLen(s: []const u8) i64 {
    var n: i64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const adv = if (i + len > s.len) 1 else len;
        n += if (adv == 4) 2 else 1;
        i += adv;
    }
    return n;
}

/// Byte offset of Kotlin char unit `target` within UTF-8 string `s`.
fn charToByteOffset(s: []const u8, target: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < s.len and units < target) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const adv = if (i + len > s.len) 1 else len;
        units += if (adv == 4) 2 else 1;
        i += adv;
    }
    return i;
}

fn isIntLike(v: Value) bool {
    return switch (v) {
        .Int, .Long, .Short, .Byte => true,
        else => false,
    };
}

/// `ByteArray.decodeToString(startIndex = 0, endIndex = size,
/// throwOnInvalidSequence = false)` — decode the byte range as UTF-8.
/// Malformed sequences become U+FFFD, matching Kotlin's default
/// (non-throwing) behaviour.
pub fn byte_array_decode_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Array) {
        return errType("decodeToString requires a ByteArray receiver");
    }
    const elems = try ctx.args[0].Array.snapshot(ctx.allocator);
    defer if (runtime.freeScratch()) ctx.allocator.free(elems);
    var bytes = try ctx.allocator.alloc(u8, elems.len);
    defer ctx.allocator.free(bytes);
    for (elems, 0..) |v, i| {
        bytes[i] = switch (v) {
            .Byte => |b| @bitCast(b),
            .UByte => |b| b,
            .Int => |x| @truncate(@as(u32, @bitCast(x))),
            .Long => |x| @truncate(@as(u64, @bitCast(x))),
            else => 0,
        };
    }
    const len: i64 = @intCast(bytes.len);
    const has_start = ctx.args.len > 1 and isIntLike(ctx.args[1]);
    const has_end = ctx.args.len > 2 and isIntLike(ctx.args[2]);
    const start = if (has_start) (ctx.args[1].asI64() orelse 0) else 0;
    const end = if (has_end) (ctx.args[2].asI64() orelse len) else len;
    // AbstractList.checkBoundsIndexes: out-of-bounds throws
    // IndexOutOfBoundsException; start > end throws IllegalArgumentException.
    if (start < 0 or end > len) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, len });
        return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
    }
    if (start > end) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d} > endIndex: {d}", .{ start, end });
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    const slice = bytes[@intCast(start)..@intCast(end)];
    // `throwOnInvalidSequence` is the third user parameter (`args[3]` after
    // the receiver and the reordered start/end slots).
    const throw_invalid = ctx.args.len > 3 and ctx.args[3] == .Bool and ctx.args[3].Bool;
    if (throw_invalid and !utf8WellFormed(slice)) {
        return try thrown(ctx.allocator, "kotlin.text.CharacterCodingException", "Input length = 1");
    }
    const out = try utf8Lossy(ctx.allocator, slice);
    return .{ .ok = try newString(ctx.allocator, out) };
}

/// Strict UTF-8 well-formedness check matching Kotlin's decoder: rejects
/// overlong forms, surrogate code points (U+D800..U+DFFF), code points above
/// U+10FFFF, and truncated sequences.
fn utf8WellFormed(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return false;
        if (i + len > bytes.len) return false;
        _ = std.unicode.utf8Decode(bytes[i .. i + len]) catch return false;
        i += len;
    }
    return true;
}

pub fn string_uppercase(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.uppercase");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = try newString(ctx.allocator, try mapCase(ctx.allocator, s, true)) };
}

pub fn string_lowercase(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.lowercase");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = try newString(ctx.allocator, try mapCase(ctx.allocator, s, false)) };
}

pub fn string_plus(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return errArity("String.plus requires one argument");
    const s: []const u8 = if (ctx.args[0] == .Null)
        "null"
    else blk: {
        const r = try recvString(ctx.allocator, ctx.args, "String.plus");
        break :blk switch (r) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
    };
    const other = ctx.args[1];
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(ctx.allocator);
    try joined.appendSlice(ctx.allocator, s);
    // An instance operand must stringify through its (possibly overridden)
    // `toString()` so `"x=" + obj` matches the template `"x=$obj"`. A
    // CONTAINER goes the same way: the structural renderer prints
    // `ClassName@id` for a user element, so `"" + listOf(obj)` disagreed with
    // `"$listOf(obj)"` and with `listOf(obj).toString()`.
    if (other == .Instance or other == .List or other == .Set or other == .Map or
        other == .Pair or other == .Triple or other == .Result)
    {
        const mr = try ctx.host.invokeMethod(&other, "toString", &.{}, ctx.out);
        if (mr) |res| {
            switch (res) {
                .ok => |val| {
                    if (val == .String) {
                        const g = val.String.borrow();
                        defer g.deinit();
                        try joined.appendSlice(ctx.allocator, g.get().bytes);
                        return .{ .ok = try newString(ctx.allocator, try joined.toOwnedSlice(ctx.allocator)) };
                    }
                },
                .err => |e| return .{ .err = e },
            }
        }
    }
    const od = try other.display(ctx.allocator);
    defer ctx.allocator.free(od);
    try joined.appendSlice(ctx.allocator, od);
    return .{ .ok = try newString(ctx.allocator, try joined.toOwnedSlice(ctx.allocator)) };
}

pub fn string_get(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .String) {
        const r = try recvString(ctx.allocator, ctx.args, "String.get");
        return switch (r) {
            .ok => unreachable, // a String receiver is handled below
            .err => |e| .{ .err = e },
        };
    }
    if (ctx.args.len < 2 or ctx.args[1] != .Int) {
        return errType("String.get requires an Int index");
    }
    const idx = ctx.args[1].Int;
    if (idx < 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "index {d} out of bounds", .{idx});
        return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
    }
    const ui: usize = @intCast(idx);
    var unit: ?u16 = null;
    var u16len: usize = 0;
    {
        const g = ctx.args[0].String.borrow();
        defer g.deinit();
        const sd = g.get();
        u16len = sd.u16_len;
        // ASCII: the UTF-16 unit at `ui` is just byte `ui` — O(1), no walk (this
        // is what makes `for (i in indices) s[i]` linear instead of quadratic).
        if (sd.ascii) {
            unit = if (ui < sd.bytes.len) @as(u16, sd.bytes[ui]) else null;
        } else {
            noteRecvData(sd);
            unit = utf16UnitAt(sd.bytes, ui);
        }
    }
    if (unit) |c| return .{ .ok = .{ .Char = c } };
    const msg = try std.fmt.allocPrint(ctx.allocator, "index {d} out of bounds (length {d})", .{ idx, u16len });
    return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
}

pub fn string_substring(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.substring");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const len: i64 = @intCast(utf16Len(s));
    var start: i64 = undefined;
    var end: i64 = undefined;
    const rest = ctx.args[1..];
    if (rest.len == 1 and rest[0] == .Range) {
        // `substring(range)` keeps `range.start .. range.endInclusive`,
        // i.e. an exclusive end of `endInclusive + 1`.
        const rg = rest[0].Range;
        start = rg.start;
        end = rg.end + 1;
    } else if (rest.len == 1 and rest[0].isIntegral()) {
        start = rest[0].asI64().?;
        end = len;
    } else if (rest.len == 2 and rest[0].isIntegral() and rest[1].isIntegral()) {
        start = rest[0].asI64().?;
        end = rest[1].asI64().?;
    } else {
        return errArity("substring requires 1 or 2 Int args");
    }
    // `String.substring(begin[, end])` throws StringIndexOutOfBoundsException
    // (an IndexOutOfBoundsException) for every out-of-bounds case, including
    // `begin > end`.
    if (start < 0 or end > len or start > end) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "begin {d}, end {d}, length {d}", .{ start, end, len });
        return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
    }
    return .{ .ok = try newString(ctx.allocator, try utf16Slice(ctx.allocator, s, @intCast(start), @intCast(end))) };
}

/// `CharSequence.padStart(length, padChar = ' ')` / `padEnd`.
fn stringPad(ctx: *CallCtx, at_start: bool, who: []const u8) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, who);
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const cur_len: i64 = @intCast(utf16Len(s));
    if (ctx.args.len < 2) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "{s} requires an Int length", .{who});
        return errArity(msg);
    }
    const length = ctx.args[1].asI64() orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "{s} requires an Int length", .{who});
        return errArity(msg);
    };
    if (length < 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Desired length {d} is less than zero.", .{length});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    var pad: u16 = ' ';
    if (ctx.args.len > 2) {
        switch (ctx.args[2]) {
            .Char => |c| pad = c,
            else => |other| {
                const od = try other.display(ctx.allocator);
                const msg = try std.fmt.allocPrint(ctx.allocator, "{s}: padChar must be a Char, got {s}", .{ who, od });
                return errType(msg);
            },
        }
    }
    if (length <= cur_len) {
        return .{ .ok = .{ .String = ctx.args[0].String.clone() } };
    }
    const pad_count: usize = @intCast(length - cur_len);
    var padding = try ctx.allocator.alloc(u16, pad_count);
    defer ctx.allocator.free(padding);
    for (0..pad_count) |i| padding[i] = pad;
    const pad_str = try charUnitsToString(ctx.allocator, padding);
    defer ctx.allocator.free(pad_str);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    if (at_start) {
        try out.appendSlice(ctx.allocator, pad_str);
        try out.appendSlice(ctx.allocator, s);
    } else {
        try out.appendSlice(ctx.allocator, s);
        try out.appendSlice(ctx.allocator, pad_str);
    }
    return .{ .ok = try newString(ctx.allocator, try out.toOwnedSlice(ctx.allocator)) };
}

pub fn string_pad_start(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringPad(ctx, true, "padStart");
}

pub fn string_pad_end(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringPad(ctx, false, "padEnd");
}

pub fn string_starts_with(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.startsWith");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("startsWith requires an argument");
    const pr = try argAsString(ctx.allocator, ctx.args[1], "startsWith");
    const prefix = switch (pr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(prefix);
    // Remaining args are `startIndex: Int` and/or `ignoreCase: Boolean`.
    var ignore_case = false;
    var start_index: i64 = 0;
    var k: usize = 2;
    while (k < ctx.args.len) : (k += 1) {
        if (ctx.args[k] == .Bool) {
            ignore_case = ctx.args[k].Bool;
        } else if (ctx.args[k].asI64()) |iv| {
            start_index = iv;
        }
    }
    if (start_index < 0) return .{ .ok = .{ .Bool = false } };
    // Case-sensitive with a prefix free of surrogate encodings (`ED ..`):
    // unit-wise equality is byte-wise equality of the UTF-8, so compare the
    // bytes at the start boundary instead of converting the whole receiver.
    if (!ignore_case and std.mem.indexOfScalar(u8, prefix, 0xED) == null) {
        const lo = utf16Boundary(s, @intCast(start_index));
        if (lo.u16_pos == start_index) {
            if (lo.byte_pos + prefix.len > s.len) return .{ .ok = .{ .Bool = false } };
            return .{ .ok = .{ .Bool = std.mem.eql(u8, s[lo.byte_pos..][0..prefix.len], prefix) } };
        }
    }
    const sc = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(sc);
    const pc = try utf16Units(ctx.allocator, prefix);
    defer ctx.allocator.free(pc);
    if (start_index + @as(i64, @intCast(pc.len)) > @as(i64, @intCast(sc.len))) {
        return .{ .ok = .{ .Bool = false } };
    }
    const off: usize = @intCast(start_index);
    for (pc, 0..) |b, i| {
        const a = sc[off + i];
        const eq = if (ignore_case) charUnitsEqIgnoreCase(a, b) else a == b;
        if (!eq) return .{ .ok = .{ .Bool = false } };
    }
    return .{ .ok = .{ .Bool = true } };
}

/// `String.regionMatches(thisOffset, other, otherOffset, length,
/// ignoreCase = false)` — true when the `length`-char regions match.
pub fn string_region_matches(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.regionMatches");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const this_off = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (this_off == null) return errType("regionMatches: thisOffset");
    if (ctx.args.len < 3) return errArity("regionMatches: other");
    const or_ = try argAsString(ctx.allocator, ctx.args[2], "regionMatches");
    const other = switch (or_) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(other);
    const other_off = if (ctx.args.len > 3) ctx.args[3].asI64() else null;
    if (other_off == null) return errType("regionMatches: otherOffset");
    const length = if (ctx.args.len > 4) ctx.args[4].asI64() else null;
    if (length == null) return errType("regionMatches: length");
    const ignore_case = ctx.args.len > 5 and ctx.args[5] == .Bool and ctx.args[5].Bool;
    const sc = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(sc);
    const oc = try utf16Units(ctx.allocator, other);
    defer ctx.allocator.free(oc);
    const to = this_off.?;
    const oo = other_off.?;
    const ln = length.?;
    if (ln < 0 or to < 0 or oo < 0 or
        to + ln > @as(i64, @intCast(sc.len)) or
        oo + ln > @as(i64, @intCast(oc.len)))
    {
        return .{ .ok = .{ .Bool = false } };
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(ln))) : (i += 1) {
        const a = sc[@as(usize, @intCast(to)) + i];
        const b = oc[@as(usize, @intCast(oo)) + i];
        const eq = if (ignore_case) charUnitsEqIgnoreCase(a, b) else a == b;
        if (!eq) return .{ .ok = .{ .Bool = false } };
    }
    return .{ .ok = .{ .Bool = true } };
}

/// `internal inline fun String.skipWhile(startIndex, predicate)`.
pub fn string_skip_while(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.skipWhile");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const start = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (start == null) return errType("skipWhile: startIndex");
    if (ctx.args.len < 3) return errArity("skipWhile: predicate");
    const block = ctx.args[2];
    const chars = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(chars);
    var i: i64 = if (start.? < 0) 0 else start.?;
    while (@as(usize, @intCast(i)) < chars.len) {
        const c = Value{ .Char = chars[@intCast(i)] };
        const keep = try ctx.host.invokeCallable(&block, &.{c}, ctx.out);
        switch (keep) {
            .ok => |val| if (!(val == .Bool and val.Bool)) break,
            .err => |e| return .{ .err = e },
        }
        i += 1;
    }
    return .{ .ok = Value.newInt(i) };
}

pub fn string_ends_with(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.endsWith");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("endsWith requires an argument");
    const sr = try argAsString(ctx.allocator, ctx.args[1], "endsWith");
    const suffix = switch (sr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(suffix);
    const ignore_case = ctx.args.len > 2 and ctx.args[2] == .Bool and ctx.args[2].Bool;
    const sc = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(sc);
    const pc = try utf16Units(ctx.allocator, suffix);
    defer ctx.allocator.free(pc);
    if (pc.len > sc.len) return .{ .ok = .{ .Bool = false } };
    const off = sc.len - pc.len;
    for (pc, 0..) |b, i| {
        const a = sc[off + i];
        const eq = if (ignore_case) charUnitsEqIgnoreCase(a, b) else a == b;
        if (!eq) return .{ .ok = .{ .Bool = false } };
    }
    return .{ .ok = .{ .Bool = true } };
}

pub fn string_filter(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.filter");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("filter requires a block");
    const block = ctx.args[1];
    var kept: std.ArrayList(u16) = .empty;
    defer kept.deinit(ctx.allocator);
    var it = Utf16View{ .bytes = s };
    while (it.next()) |ch| {
        const v = Value{ .Char = ch };
        const res = try ctx.host.invokeCallable(&block, &.{v}, ctx.out);
        switch (res) {
            .ok => |val| if (val == .Bool and val.Bool) try kept.append(ctx.allocator, ch),
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = try newString(ctx.allocator, try charUnitsToString(ctx.allocator, kept.items)) };
}

pub fn string_count(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.count");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len == 1) {
        return .{ .ok = Value.newInt(@intCast(utf16Len(s))) };
    }
    const block = ctx.args[1];
    var n: i64 = 0;
    var it = Utf16View{ .bytes = s };
    while (it.next()) |ch| {
        const v = Value{ .Char = ch };
        const res = try ctx.host.invokeCallable(&block, &.{v}, ctx.out);
        switch (res) {
            .ok => |val| if (val == .Bool and val.Bool) {
                n += 1;
            },
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = Value.newInt(n) };
}

pub fn string_map(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.map");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("map requires a block");
    const block = ctx.args[1];
    var result: std.ArrayList(Value) = .empty;
    errdefer result.deinit(ctx.allocator);
    var it = Utf16View{ .bytes = s };
    while (it.next()) |ch| {
        const v = Value{ .Char = ch };
        const res = try ctx.host.invokeCallable(&block, &.{v}, ctx.out);
        switch (res) {
            .ok => |val| try result.append(ctx.allocator, val),
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = try makeList(ctx.allocator, try result.toOwnedSlice(ctx.allocator), false) };
}

pub fn string_any(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.any");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len == 1) {
        return .{ .ok = .{ .Bool = s.len != 0 } };
    }
    const block = ctx.args[1];
    var it = Utf16View{ .bytes = s };
    while (it.next()) |ch| {
        const v = Value{ .Char = ch };
        const res = try ctx.host.invokeCallable(&block, &.{v}, ctx.out);
        switch (res) {
            .ok => |val| if (val == .Bool and val.Bool) return .{ .ok = .{ .Bool = true } },
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = .{ .Bool = false } };
}

pub fn string_all(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.all");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("all requires a block");
    const block = ctx.args[1];
    var it = Utf16View{ .bytes = s };
    while (it.next()) |ch| {
        const v = Value{ .Char = ch };
        const res = try ctx.host.invokeCallable(&block, &.{v}, ctx.out);
        switch (res) {
            .ok => |val| if (!(val == .Bool and val.Bool)) return .{ .ok = .{ .Bool = false } },
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = .{ .Bool = true } };
}

pub fn string_none(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try string_any(ctx);
    switch (r) {
        .ok => |val| return .{ .ok = .{ .Bool = val == .Bool and val.Bool == false } },
        .err => |e| return .{ .err = e },
    }
}

/// `String.equals(other, ignoreCase = false)`.
pub fn string_equals(ctx: *CallCtx) Allocator.Error!EvalResult {
    // `String?.equals(other, ignoreCase)` on a null receiver: equal iff `other`
    // is also null (the bodyless expect would otherwise evaluate to Unit).
    if (ctx.args.len > 0 and ctx.args[0] == .Null) {
        return .{ .ok = .{ .Bool = ctx.args.len > 1 and ctx.args[1] == .Null } };
    }
    // `Char.equals(other: Char, ignoreCase)` shares the `kotlin.text.equals`
    // FQN with `String?.equals`; dispatch it by receiver kind.
    if (ctx.args.len > 0 and ctx.args[0] == .Char) {
        var ceq = false;
        if (ctx.args.len > 1 and ctx.args[1] == .Char) {
            const ic = ctx.args.len > 2 and ctx.args[2] == .Bool and ctx.args[2].Bool;
            ceq = if (ic) char.charEqIgnoreCase(ctx.args[0].Char, ctx.args[1].Char) else ctx.args[0].Char == ctx.args[1].Char;
        }
        return .{ .ok = .{ .Bool = ceq } };
    }
    const r = try recvString(ctx.allocator, ctx.args, "String.equals");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const ignore_case = ctx.args.len > 2 and ctx.args[2] == .Bool and ctx.args[2].Bool;
    var eq = false;
    if (ctx.args.len > 1 and ctx.args[1] == .String) {
        const g = ctx.args[1].String.borrow();
        defer g.deinit();
        const o = g.get().bytes;
        if (ignore_case) {
            eq = try eqIgnoreCaseUnicode(ctx.allocator, s, o);
        } else {
            eq = std.mem.eql(u8, s, o);
        }
    }
    return .{ .ok = .{ .Bool = eq } };
}

/// `CharSequence.contentEquals(other: CharSequence?, ignoreCase = false)`.
pub fn char_sequence_content_equals(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return errType("contentEquals requires a receiver");
    if (ctx.args[0] == .Null) {
        return .{ .ok = .{ .Bool = ctx.args.len >= 2 and ctx.args[1] == .Null } };
    }
    const ar = try charSeqToString(ctx.allocator, ctx.args[0], "contentEquals");
    const a = switch (ar) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(a);
    if (ctx.args.len < 2 or ctx.args[1] == .Null) return .{ .ok = .{ .Bool = false } };
    const otr = try charSeqToString(ctx.allocator, ctx.args[1], "contentEquals");
    const other = switch (otr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(other);
    const ignore_case = ctx.args.len > 2 and ctx.args[2] == .Bool and ctx.args[2].Bool;
    const eq = if (ignore_case)
        try eqIgnoreCaseUnicode(ctx.allocator, a, other)
    else
        std.mem.eql(u8, a, other);
    return .{ .ok = .{ .Bool = eq } };
}

/// `CharSequence.elementAt(index)` — the `Char` (UTF-16 unit) at `index`.
pub fn char_sequence_element_at(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return errType("elementAt requires a receiver");
    const sr = try charSeqToString(ctx.allocator, ctx.args[0], "elementAt");
    const s = switch (sr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(s);
    const index = if (ctx.args.len > 1) ctx.args[1].asI64() else null;
    if (index == null) return errType("elementAt index must be an Int");
    const units = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(units);
    const idx = index.?;
    if (idx < 0 or @as(usize, @intCast(idx)) >= units.len) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "index: {d}, length: {d}", .{ idx, units.len });
        return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
    }
    return .{ .ok = .{ .Char = units[@intCast(idx)] } };
}

pub fn string_contains(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.contains");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("contains requires an argument");
    // `regex in string` → CharSequence.contains(Regex) → regex.containsMatchIn.
    if (ctx.args[1] == .Regex) {
        return .{ .ok = .{ .Bool = try regexp.regexContainsIn(ctx.allocator, ctx.args[1].Regex, s) } };
    }
    const nr = try argAsString(ctx.allocator, ctx.args[1], "contains");
    const needle = switch (nr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(needle);
    const ignore_case = ctx.args.len > 2 and ctx.args[2] == .Bool and ctx.args[2].Bool;
    const found = if (ignore_case) blk: {
        const lhay = try mapCase(ctx.allocator, s, false);
        defer ctx.allocator.free(lhay);
        const lneed = try mapCase(ctx.allocator, needle, false);
        defer ctx.allocator.free(lneed);
        break :blk std.mem.indexOf(u8, lhay, lneed) != null;
    } else std.mem.indexOf(u8, s, needle) != null;
    return .{ .ok = .{ .Bool = found } };
}

pub fn string_index_of(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.indexOf");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("indexOf requires an argument");
    const nr = try argAsString(ctx.allocator, ctx.args[1], "indexOf");
    const needle = switch (nr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(needle);
    const start_i64 = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse 0) else 0;
    const start_u16: usize = if (start_i64 < 0) 0 else @intCast(start_i64);
    // Two shapes share this name: the public
    // `indexOf(other, startIndex = 0, ignoreCase = false)` and the stdlib's
    // internal `indexOf(other, startIndex, endIndex, ignoreCase, last = ...)`
    // (args[3] is an Int endIndex there, and args[4] the flag). Reading the
    // internal shape's endIndex as the flag searched case-sensitively and
    // ignored the bound.
    const internal_shape = ctx.args.len > 3 and ctx.args[3] != .Bool;
    const end_u16: ?usize = if (internal_shape) blk: {
        const e = ctx.args[3].asI64() orelse break :blk null;
        break :blk if (e < 0) 0 else @intCast(e);
    } else null;
    const flag_idx: usize = if (internal_shape) 4 else 3;
    const ignore_case = ctx.args.len > flag_idx and ctx.args[flag_idx] == .Bool and ctx.args[flag_idx].Bool;
    const last_flag = internal_shape and ctx.args.len > 5 and ctx.args[5] == .Bool and ctx.args[5].Bool;
    if (last_flag) {
        // Backward form (the lastIndexOf driver): the largest match start in
        // `[endIndex, startIndex]` (the internal signature runs its indices
        // from startIndex DOWN to endIndex).
        const total = utf16Len(s);
        const upper: usize = @min(start_u16, total);
        const lower: usize = end_u16 orelse 0;
        const hay2 = if (ignore_case) try mapCase(ctx.allocator, s, false) else s;
        defer if (ignore_case and runtime.freeScratch()) ctx.allocator.free(hay2);
        const ndl2 = if (ignore_case) try mapCase(ctx.allocator, needle, false) else needle;
        defer if (ignore_case and runtime.freeScratch()) ctx.allocator.free(ndl2);
        var best: i64 = -1;
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, hay2, search_from, ndl2)) |pos| {
            const start_char = utf16Len(s[0..pos]);
            if (start_char > upper) break;
            if (start_char >= lower) best = @intCast(start_char);
            search_from = pos + 1;
        }
        return .{ .ok = Value.newInt(best) };
    }
    // The empty string matches at the start index, clamped to the length (the
    // JVM behavior `"abc".indexOf("", n)` returns `n.coerceAtMost(length)`).
    if (needle.len == 0) {
        const total = utf16Len(s);
        return .{ .ok = Value.newInt(@intCast(@min(start_u16, total))) };
    }
    const start_byte = utf16IndexToByte(s, start_u16);
    if (start_byte > s.len) return .{ .ok = Value.newInt(-1) };
    // The internal shape's endIndex bounds the match START (a match may
    // extend past it); search the full tail and bound-check the hit.
    const end_start_byte: usize = if (end_u16) |e| @min(utf16IndexToByte(s, e), s.len) else s.len;
    if (end_start_byte < start_byte) return .{ .ok = Value.newInt(-1) };
    const hay = s[start_byte..];
    var found: ?usize = null;
    if (ignore_case) {
        const lhay = try mapCase(ctx.allocator, hay, false);
        defer ctx.allocator.free(lhay);
        const lneed = try mapCase(ctx.allocator, needle, false);
        defer ctx.allocator.free(lneed);
        if (std.mem.indexOf(u8, lhay, lneed)) |off| found = start_byte + off;
    } else {
        if (std.mem.indexOf(u8, hay, needle)) |off| found = start_byte + off;
    }
    if (found) |f| {
        if (f > end_start_byte) found = null;
    }
    return .{ .ok = Value.newInt(byteToCharIndex(s, found)) };
}

/// Byte offset of the char boundary at or after the given UTF-16 code-unit
/// index — the inverse of `byteToCharIndex`'s unit.
fn utf16IndexToByte(s: []const u8, target: usize) usize {
    return utf16Boundary(s, target).byte_pos;
}

/// The boundary reached for UTF-16 index `target`: its byte offset and the
/// unit index actually landed on (one past `target` when `target` names the
/// low half of a surrogate pair, whose bytes cannot be split).
fn utf16Boundary(s: []const u8, target: usize) runtime.StringData.Cursor {
    if (target == 0) return .{ .u16_pos = 0, .byte_pos = 0 };
    if (asciiScan(s)) {
        const b = @min(target, s.len); // ASCII: unit index == byte index
        return .{ .u16_pos = b, .byte_pos = b };
    }
    const memo = memoFor(s);
    const from: runtime.StringData.Cursor = if (memo) |m| m.cursor() else .{ .u16_pos = 0, .byte_pos = 0 };
    const at = unitBoundaryFrom(s, from, target);
    if (memo) |m| m.save(at.u16_pos, at.byte_pos);
    return at;
}

pub fn string_last_index_of(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.lastIndexOf");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("lastIndexOf requires an argument");
    const nr = try argAsString(ctx.allocator, ctx.args[1], "lastIndexOf");
    const needle = switch (nr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(needle);
    const total = utf16Len(s);
    // Optional `startIndex: Int` then `ignoreCase: Boolean`. The search runs
    // backward from `startIndex` (a code-unit index, default the last index),
    // returning the start of the last occurrence whose start is <= startIndex.
    var from_char: i64 = @intCast(total);
    var ignore_case = false;
    var k: usize = 2;
    while (k < ctx.args.len) : (k += 1) {
        if (ctx.args[k] == .Bool) {
            ignore_case = ctx.args[k].Bool;
        } else if (ctx.args[k].asI64()) |iv| {
            from_char = iv;
        }
    }
    if (from_char < 0) return .{ .ok = Value.newInt(-1) };
    const limit_char: usize = @min(@as(usize, @intCast(from_char)), total);
    if (needle.len == 0) return .{ .ok = Value.newInt(@intCast(limit_char)) };
    const hay = if (ignore_case) try mapCase(ctx.allocator, s, false) else s;
    defer if (ignore_case and runtime.freeScratch()) ctx.allocator.free(hay);
    const ndl = if (ignore_case) try mapCase(ctx.allocator, needle, false) else needle;
    defer if (ignore_case and runtime.freeScratch()) ctx.allocator.free(ndl);
    var result: i64 = -1;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, search_from, ndl)) |pos| {
        const start_char = utf16Len(s[0..pos]);
        if (start_char > limit_char) break;
        result = @intCast(start_char);
        search_from = pos + 1;
    }
    return .{ .ok = Value.newInt(result) };
}

/// Kotlin indexOf/lastIndexOf return an Int code-unit index (or -1).
fn byteToCharIndex(s: []const u8, byte: ?usize) i64 {
    const b = byte orelse return -1;
    if (memoFor(s)) |m| {
        if (m.ascii) return @intCast(@min(b, s.len));
        var it = Utf16View{ .bytes = s };
        var count: usize = 0;
        const c = m.cursor();
        if (c.byte_pos <= b) {
            count = c.u16_pos;
            it.pos = c.byte_pos;
        }
        while (it.pos < b) {
            _ = it.next() orelse break;
            count += 1;
            if (it.pending_low != null) {
                _ = it.next();
                count += 1;
            }
        }
        m.save(count, it.pos);
        return @intCast(count);
    }
    return @intCast(utf16Len(s[0..b]));
}

pub fn string_replace(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.replace");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len > 1 and ctx.args[1] == .Regex) {
        const repl: ?Value = if (ctx.args.len > 2) ctx.args[2] else null;
        return regexp.stringRegexReplace(ctx, ctx.args[0].String, ctx.args[1].Regex, repl, false, "replace");
    }
    if (ctx.args.len < 2) return errArity("replace requires old");
    const olr = try argAsString(ctx.allocator, ctx.args[1], "replace");
    const old = switch (olr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(old);
    if (ctx.args.len < 3) return errArity("replace requires new");
    const ner = try argAsString(ctx.allocator, ctx.args[2], "replace");
    const new = switch (ner) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(new);
    const ignore_case = ctx.args.len > 3 and ctx.args[3] == .Bool and ctx.args[3].Bool;
    const out = if (ignore_case)
        try replaceAllIgnoreCase(ctx.allocator, s, old, new, null)
    else
        try replaceAll(ctx.allocator, s, old, new, null);
    return .{ .ok = try newString(ctx.allocator, out) };
}

/// trim / trimStart / trimEnd, honoring the optional argument: a vararg
/// Char set, a `(Char)->Boolean` predicate, or nothing (whitespace).
fn stringTrimGeneric(ctx: *CallCtx, trim_start: bool, trim_end: bool, who: []const u8) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, who);
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const cs = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(cs);
    const extra = ctx.args[1..];
    var keep = try ctx.allocator.alloc(bool, cs.len);
    defer ctx.allocator.free(keep);
    var all_char = extra.len > 0;
    for (extra) |v| {
        if (v != .Char) {
            all_char = false;
            break;
        }
    }
    if (extra.len == 0) {
        for (cs, 0..) |c, i| {
            const sc = charUnitToScalar(c);
            keep[i] = !(sc != null and isWhitespace(sc.?));
        }
    } else if (all_char) {
        for (cs, 0..) |c, i| {
            var in_set = false;
            for (extra) |v| {
                if (v.Char == c) {
                    in_set = true;
                    break;
                }
            }
            keep[i] = !in_set;
        }
    } else {
        const block = extra[0];
        for (cs, 0..) |c, i| {
            const res = try ctx.host.invokeCallable(&block, &.{Value{ .Char = c }}, ctx.out);
            switch (res) {
                .ok => |val| {
                    const trimmable = val == .Bool and val.Bool;
                    keep[i] = !trimmable;
                },
                .err => |e| return .{ .err = e },
            }
        }
    }
    var lo: usize = 0;
    if (trim_start) {
        lo = cs.len;
        for (keep, 0..) |k, i| {
            if (k) {
                lo = i;
                break;
            }
        }
    }
    var hi: usize = cs.len;
    if (trim_end) {
        hi = 0;
        var i: usize = cs.len;
        while (i > 0) : (i -= 1) {
            if (keep[i - 1]) {
                hi = i;
                break;
            }
        }
    }
    if (hi < lo) hi = lo;
    return .{ .ok = try newString(ctx.allocator, try charUnitsToString(ctx.allocator, cs[lo..hi])) };
}

pub fn string_trim(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringTrimGeneric(ctx, true, true, "String.trim");
}
pub fn string_trim_start(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringTrimGeneric(ctx, true, false, "String.trimStart");
}
pub fn string_trim_end(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringTrimGeneric(ctx, false, true, "String.trimEnd");
}

pub fn string_repeat(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (std.c.getenv("KLIO_REPEAT_DBG") != null) {
        std.debug.print("[srep] nargs={d}", .{ctx.args.len});
        for (ctx.args) |a| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(a))});
        std.debug.print("\n", .{});
    }
    const r = try recvString(ctx.allocator, ctx.args, "String.repeat");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) {
        return errType("repeat requires an Int count");
    }
    const n = ctx.args[1].Int;
    if (n < 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Count `n` must be non-negative, but was {d}", .{n});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    const count: usize = @intCast(n);
    var out = try ctx.allocator.alloc(u8, s.len * count);
    var off: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(out[off .. off + s.len], s);
        off += s.len;
    }
    return .{ .ok = try newString(ctx.allocator, out) };
}

pub fn string_reversed(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.reversed");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // Reverse by Unicode scalar.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    var i: usize = s.len;
    while (i > 0) {
        // Walk back to the start of the preceding scalar.
        var start = i - 1;
        while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
        try out.appendSlice(ctx.allocator, s[start..i]);
        i = start;
    }
    return .{ .ok = try newString(ctx.allocator, try out.toOwnedSlice(ctx.allocator)) };
}

/// Kotlin `String.compareTo(other, ignoreCase = true)`: per scalar, when the
/// two differ, compare uppercased forms then lowercased-uppercased forms; the
/// shorter string sorts first on a common prefix.
fn compareIgnoreCaseUtf8(a: []const u8, b: []const u8) std.math.Order {
    var ia = (std.unicode.Utf8View.init(a) catch return text.compareUtf16(a, b)).iterator();
    var ib = (std.unicode.Utf8View.init(b) catch return text.compareUtf16(a, b)).iterator();
    while (true) {
        const ca = ia.nextCodepoint();
        const cb = ib.nextCodepoint();
        if (ca == null and cb == null) return .eq;
        if (ca == null) return .lt;
        if (cb == null) return .gt;
        if (ca.? == cb.?) continue;
        const ua = scalarToUpper(ca.?);
        const ub = scalarToUpper(cb.?);
        if (ua != ub) {
            const la = scalarToLower(ua);
            const lb = scalarToLower(ub);
            if (la != lb) return std.math.order(la, lb);
        }
    }
}

/// `compareIgnoreCaseUtf8` returning kotlinc's VALUE: `compareToIgnoreCase`
/// is the difference of the case-folded units at the first mismatch, and the
/// length difference when one string is a prefix of the other.
fn compareIgnoreCaseUtf8Difference(a: []const u8, b: []const u8) i32 {
    var ia = (std.unicode.Utf8View.init(a) catch return text.compareUtf16Difference(a, b)).iterator();
    var ib = (std.unicode.Utf8View.init(b) catch return text.compareUtf16Difference(a, b)).iterator();
    while (true) {
        const ca = ia.nextCodepoint();
        const cb = ib.nextCodepoint();
        if (ca == null and cb == null) return 0;
        if (ca == null or cb == null) return text.utf16Len(a) - text.utf16Len(b);
        if (ca.? == cb.?) continue;
        const ua = scalarToUpper(ca.?);
        const ub = scalarToUpper(cb.?);
        if (ua != ub) {
            const la = scalarToLower(ua);
            const lb = scalarToLower(ub);
            if (la != lb) return @as(i32, @intCast(la)) - @as(i32, @intCast(lb));
        }
    }
}

pub fn string_compare_to(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.compareTo");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2 or ctx.args[1] != .String) {
        return errType("compareTo requires a String");
    }
    const g = ctx.args[1].String.borrow();
    defer g.deinit();
    const ignore_case = ctx.args.len > 2 and ctx.args[2] == .Bool and ctx.args[2].Bool;
    const v: i32 = if (ignore_case)
        compareIgnoreCaseUtf8Difference(s, g.get().bytes)
    else
        text.compareUtf16Difference(s, g.get().bytes);
    return .{ .ok = .{ .Int = v } };
}

pub fn string_to_int(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toInt");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const rr = try recvIntRadix(ctx.allocator, if (ctx.args.len > 1) ctx.args[1] else null, "String.toInt");
    const radix = switch (rr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (radix < 2 or radix > 36) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "radix {d} was not in valid range 2..36", .{radix});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    const parsed = parseIntRadix(s, @intCast(radix));
    if (parsed) |v| {
        if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
            return .{ .ok = Value.newInt(v) };
        }
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "For input string: \"{s}\"", .{s});
    return try thrownOwned(ctx.allocator, "kotlin.NumberFormatException", msg);
}

pub fn string_to_int_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toIntOrNull");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const rr = try recvIntRadix(ctx.allocator, if (ctx.args.len > 1) ctx.args[1] else null, "String.toIntOrNull");
    const radix = switch (rr) {
        .ok => |v| v,
        .err => return .{ .ok = .Null },
    };
    // An invalid radix is a programming error and throws even on the OrNull
    // path (Kotlin's `checkRadix`); only an unparseable string yields null.
    if (radix < 2 or radix > 36) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "radix {d} was not in valid range 2..36", .{radix});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    const parsed = parseIntRadix(s, @intCast(radix));
    if (parsed) |v| {
        if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
            return .{ .ok = Value.newInt(v) };
        }
    }
    return .{ .ok = .Null };
}

/// Parse a signed integer in the given radix (Kotlin semantics: trims
/// whitespace, accepts a leading sign). Returns null on any failure.
fn parseIntRadix(raw: []const u8, radix: u32) ?i64 {
    const s = std.mem.trim(u8, raw, " \t\n\r");
    if (s.len == 0) return null;
    var negative = false;
    var body = s;
    if (s[0] == '-') {
        negative = true;
        body = s[1..];
    } else if (s[0] == '+') {
        body = s[1..];
    }
    if (body.len == 0) return null;
    // Accumulate in the negative range so the most-negative value (e.g.
    // Long.MIN_VALUE, whose magnitude is one past Long.MAX_VALUE) is
    // representable; flip to positive at the end when not negative.
    var acc: i64 = 0;
    for (body) |ch| {
        const d = digitValue(ch, radix) orelse return null;
        acc = std.math.mul(i64, acc, @intCast(radix)) catch return null;
        acc = std.math.sub(i64, acc, @intCast(d)) catch return null;
    }
    if (!negative) {
        acc = std.math.negate(acc) catch return null;
    }
    return acc;
}

fn digitValue(ch: u8, radix: u32) ?u32 {
    const d: u32 = switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'z' => 10 + (ch - 'a'),
        'A'...'Z' => 10 + (ch - 'A'),
        else => return null,
    };
    if (d >= radix) return null;
    return d;
}

pub fn string_to_list(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toList");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    var items: std.ArrayList(Value) = .empty;
    errdefer items.deinit(ctx.allocator);
    var it = Utf16View{ .bytes = s };
    while (it.next()) |u| try items.append(ctx.allocator, .{ .Char = u });
    return .{ .ok = try makeList(ctx.allocator, try items.toOwnedSlice(ctx.allocator), false) };
}

pub fn string_split(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try stringSplitItems(ctx, "String.split");
    return switch (r) {
        .ok => |items| .{ .ok = try makeList(ctx.allocator, items, false) },
        .err => |e| .{ .err = e },
    };
}

/// `splitToSequence(...)` shares `split`'s delimiter handling.
pub fn string_split_to_sequence(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try stringSplitItems(ctx, "String.splitToSequence");
    return switch (r) {
        .ok => |items| .{ .ok = try makeSequence(ctx.allocator, items) },
        .err => |e| .{ .err = e },
    };
}

fn stringSplitItems(ctx: *CallCtx, who: []const u8) Allocator.Error!union(enum) { ok: []Value, err: RuntimeError } {
    const r = try recvString(ctx.allocator, ctx.args, who);
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len > 1 and ctx.args[1] == .Regex) {
        var limit: i64 = 0;
        if (ctx.args.len > 2) {
            const v = ctx.args[2];
            if (v.isIntegral()) {
                limit = v.asI64().?;
            } else {
                return .{ .err = .{ .Type = "split limit must be Int" } };
            }
        }
        const res = try regexp.stringRegexSplitItems(ctx, ctx.args[0].String, ctx.args[1].Regex, limit);
        return switch (res) {
            .ok => |items| .{ .ok = items },
            .err => |e| .{ .err = e },
        };
    }
    // `split(vararg delimiters: String/Char, ignoreCase = false, limit = 0)`.
    var delims: std.ArrayList([]const u8) = .empty;
    defer {
        for (delims.items) |d| ctx.allocator.free(d);
        delims.deinit(ctx.allocator);
    }
    var ignore_case = false;
    var limit: i64 = 0;
    for (ctx.args[1..]) |a| {
        switch (a) {
            .String, .Char => {
                if (try delimToString(ctx.allocator, a)) |d| try delims.append(ctx.allocator, d);
            },
            .Bool => |b| ignore_case = b,
            .Array => |arr| {
                const sn = try arr.snapshot(ctx.allocator);
                defer if (runtime.freeScratch()) ctx.allocator.free(sn);
                for (sn) |it| {
                    if (try delimToString(ctx.allocator, it)) |d| {
                        try delims.append(ctx.allocator, d);
                    } else {
                        return .{ .err = .{ .Type = "String.split delimiters must be String or Char" } };
                    }
                }
            },
            .List => |l| {
                const g = l.items.borrow();
                defer g.deinit();
                for (g.get().items) |it| {
                    if (try delimToString(ctx.allocator, it)) |d| {
                        try delims.append(ctx.allocator, d);
                    } else {
                        return .{ .err = .{ .Type = "String.split delimiters must be String or Char" } };
                    }
                }
            },
            .Null => {},
            else => {
                if (a.isIntegral()) {
                    limit = a.asI64().?;
                } else {
                    return .{ .err = .{ .Type = "String.split requires String, Char, or Regex delimiters" } };
                }
            },
        }
    }
    if (limit < 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Limit must be non-negative, but was {d}", .{limit});
        return switch (try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg)) {
            .err => |e| .{ .err = e },
            .ok => unreachable,
        };
    }
    // `split(vararg)` with no delimiters supplied returns the whole string
    // as a single element. A supplied empty-string delimiter still splits
    // at every position (matched length 0), so it is not "no delimiter".
    if (delims.items.len == 0) {
        var single: std.ArrayList(Value) = .empty;
        try single.append(ctx.allocator, try newString(ctx.allocator, try ctx.allocator.dupe(u8, s)));
        return .{ .ok = try single.toOwnedSlice(ctx.allocator) };
    }
    const out = try splitOnAny(ctx.allocator, s, delims.items, ignore_case, limit);
    return .{ .ok = out };
}

/// Stringify a String/Char delimiter (owned), or null if not one.
fn delimToString(allocator: Allocator, v: Value) Allocator.Error!?[]const u8 {
    switch (v) {
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return try allocator.dupe(u8, g.get().bytes);
        },
        .Char => |c| return try charUnitToString(allocator, c),
        else => return null,
    }
}

/// Advance one UTF-8 code point forward from byte offset `i` in `s`.
fn nextCharBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + 1;
    while (j < s.len and !isCharBoundary(s, j)) j += 1;
    return j;
}

/// Split `s` on any of `delims`, mirroring `DelimitedRangesSequence`: at
/// each search position find the first (declaration-order) delimiter that
/// matches and emit the segment before it. A positive `limit` bounds the
/// number of substrings; an empty-string delimiter matches with length 0
/// (advancing the search by one code point) so `"abc".split("")` yields
/// the inter-character segments. ASCII `ignore_case`.
fn splitOnAny(allocator: Allocator, s: []const u8, delims: []const []const u8, ignore_case: bool, limit: i64) Allocator.Error![]Value {
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(allocator);
    var seg_start: usize = 0;
    var search: usize = 0;
    while (true) {
        if (limit > 0 and @as(i64, @intCast(out.items.len)) == limit - 1) break;
        if (search > s.len) break;
        // Find the first delimiter match at or after `search`.
        var match_at: ?usize = null;
        var match_len: usize = 0;
        var pos: usize = search;
        scan: while (pos <= s.len) {
            for (delims) |d| {
                const end = pos + d.len;
                if (end <= s.len and (d.len == 0 or (isCharBoundary(s, pos) and isCharBoundary(s, end)))) {
                    const cand = s[pos..end];
                    const eq = if (ignore_case) std.ascii.eqlIgnoreCase(cand, d) else std.mem.eql(u8, cand, d);
                    if (eq) {
                        match_at = pos;
                        match_len = d.len;
                        break :scan;
                    }
                }
            }
            if (pos >= s.len) break;
            pos = nextCharBoundary(s, pos);
        }
        const idx = match_at orelse break;
        try out.append(allocator, try newString(allocator, try allocator.dupe(u8, s[seg_start..idx])));
        seg_start = idx + match_len;
        // A zero-length match (empty delimiter) advances the search one
        // code point so the next iteration makes progress; at end of input
        // that pushes `search` past `s.len`, ending the loop after the
        // final trailing segment is emitted.
        if (match_len == 0) {
            search = if (seg_start >= s.len) s.len + 1 else nextCharBoundary(s, seg_start);
        } else {
            search = seg_start;
        }
    }
    try out.append(allocator, try newString(allocator, try allocator.dupe(u8, s[seg_start..])));
    return out.toOwnedSlice(allocator);
}

fn isCharBoundary(s: []const u8, i: usize) bool {
    if (i == 0 or i == s.len) return true;
    return (s[i] & 0xC0) != 0x80;
}

pub fn string_chunked(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.chunked");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) {
        return errType("chunked requires an Int size");
    }
    const size_i = ctx.args[1].Int;
    if (size_i <= 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Size {d} must be greater than zero.", .{size_i});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    const size: usize = @intCast(size_i);
    const transform: ?Value = if (ctx.args.len > 2 and ctx.args[2] != .Null) ctx.args[2] else null;
    const chars = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(chars);
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < chars.len) {
        const end = @min(i + size, chars.len);
        const piece = try charUnitsToString(ctx.allocator, chars[i..end]);
        if (transform) |block| {
            const arg = try newString(ctx.allocator, piece);
            const res = try ctx.host.invokeCallable(&block, &.{arg}, ctx.out);
            switch (res) {
                .ok => |val| try out.append(ctx.allocator, val),
                .err => |e| return .{ .err = e },
            }
        } else {
            try out.append(ctx.allocator, try newString(ctx.allocator, piece));
        }
        i += size;
    }
    return .{ .ok = try makeList(ctx.allocator, try out.toOwnedSlice(ctx.allocator), false) };
}

fn isCallableTransform(v: Value) bool {
    return switch (v) {
        .IrClosure, .Intrinsic => true,
        else => false,
    };
}

pub fn string_windowed(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.windowed");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) {
        return errType("windowed requires an Int size");
    }
    const size_i = ctx.args[1].Int;
    if (size_i <= 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "size {d} must be greater than zero.", .{size_i});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    // Peel a trailing callable as the `transform` (the `windowed(size,
    // step, partialWindows, transform)` overload). The scalar step /
    // partialWindows read positionally from the remaining args, so a
    // trailing lambda with omitted middle defaults binds correctly.
    var n_scalar = ctx.args.len;
    const transform: ?Value = if (n_scalar > 2 and isCallableTransform(ctx.args[n_scalar - 1])) blk: {
        n_scalar -= 1;
        break :blk ctx.args[n_scalar];
    } else null;
    var step: i64 = 1;
    if (n_scalar > 2) {
        if (ctx.args[2].isIntegral()) {
            step = ctx.args[2].asI64().?;
        } else {
            return errType("windowed step must be Int");
        }
    }
    var partial = false;
    if (n_scalar > 3) {
        switch (ctx.args[3]) {
            .Bool => |b| partial = b,
            .Null => {},
            else => return errType("windowed partialWindows must be Bool"),
        }
    }
    if (step <= 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "step {d} must be greater than zero.", .{step});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    const chars = try utf16Units(ctx.allocator, s);
    defer ctx.allocator.free(chars);
    const size: usize = @intCast(size_i);
    const step_u: usize = @intCast(step);
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < chars.len) {
        const end = i + size;
        var window: ?Value = null;
        if (end <= chars.len) {
            window = try newString(ctx.allocator, try charUnitsToString(ctx.allocator, chars[i..end]));
        } else if (partial) {
            window = try newString(ctx.allocator, try charUnitsToString(ctx.allocator, chars[i..]));
        } else {
            break;
        }
        if (window) |w| {
            if (transform) |t| {
                switch (try ctx.host.invokeCallable(&t, &.{w}, ctx.out)) {
                    .ok => |v| try out.append(ctx.allocator, v),
                    .err => |e| return .{ .err = e },
                }
            } else {
                try out.append(ctx.allocator, w);
            }
        }
        i += step_u;
    }
    return .{ .ok = try makeList(ctx.allocator, try out.toOwnedSlice(ctx.allocator), false) };
}

pub fn string_to_double(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toDouble");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (parseDouble(s)) |d| return .{ .ok = .{ .Double = d } };
    const msg = try std.fmt.allocPrint(ctx.allocator, "For input string: \"{s}\"", .{s});
    return try thrownOwned(ctx.allocator, "kotlin.NumberFormatException", msg);
}

fn numberFormatError(allocator: Allocator, s: []const u8) Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(allocator, "For input string: \"{s}\"", .{s});
    return try thrownOwned(allocator, "kotlin.NumberFormatException", msg);
}

pub fn string_to_float(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toFloat");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (parseFloat(s)) |f| return .{ .ok = .{ .Float = f } };
    return numberFormatError(ctx.allocator, s);
}

pub fn string_to_float_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toFloatOrNull");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (parseFloat(s)) |f| return .{ .ok = .{ .Float = f } };
    return .{ .ok = .Null };
}

pub fn string_to_short(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toShort");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const rr = try recvIntRadix(ctx.allocator, if (ctx.args.len > 1) ctx.args[1] else null, "String.toShort");
    const radix = switch (rr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (parseIntRadix(s, @intCast(radix))) |v| {
        if (v >= std.math.minInt(i16) and v <= std.math.maxInt(i16)) {
            return .{ .ok = .{ .Short = @intCast(v) } };
        }
    }
    return numberFormatError(ctx.allocator, s);
}

pub fn string_to_byte(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toByte");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const rr = try recvIntRadix(ctx.allocator, if (ctx.args.len > 1) ctx.args[1] else null, "String.toByte");
    const radix = switch (rr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (parseIntRadix(s, @intCast(radix))) |v| {
        if (v >= std.math.minInt(i8) and v <= std.math.maxInt(i8)) {
            return .{ .ok = .{ .Byte = @intCast(v) } };
        }
    }
    return numberFormatError(ctx.allocator, s);
}

/// Deprecated `String.capitalize()` — upper-case the first scalar.
pub fn string_capitalize(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.capitalize");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = try newString(ctx.allocator, try capitalizeFirst(ctx.allocator, s, true)) };
}

pub fn string_decapitalize(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.decapitalize");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = try newString(ctx.allocator, try capitalizeFirst(ctx.allocator, s, false)) };
}

fn capitalizeFirst(allocator: Allocator, s: []const u8, upper: bool) Allocator.Error![]u8 {
    if (s.len == 0) return allocator.dupe(u8, "");
    const first_len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    const fend = @min(first_len, s.len);
    const cp = std.unicode.utf8Decode(s[0..fend]) catch s[0];
    const mapped = if (upper) scalarToUpper(cp) else scalarToLower(cp);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(mapped), &buf) catch blk: {
        break :blk std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    };
    try out.appendSlice(allocator, buf[0..n]);
    try out.appendSlice(allocator, s[fend..]);
    return out.toOwnedSlice(allocator);
}

// ============================================================
// Additional String members
// ============================================================

fn missingArg(allocator: Allocator, v: ?Value, s: []const u8) Allocator.Error![]const u8 {
    if (v) |val| {
        switch (val) {
            .String => |sr| {
                const g = sr.borrow();
                defer g.deinit();
                return allocator.dupe(u8, g.get().bytes);
            },
            .Char => |c| return charUnitToString(allocator, c),
            else => {},
        }
    }
    return allocator.dupe(u8, s);
}

pub fn string_substring_before(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.substringBefore");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("substringBefore requires a delimiter");
    const dr = try argAsString(ctx.allocator, ctx.args[1], "substringBefore");
    const delim = switch (dr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(delim);
    if (std.mem.indexOf(u8, s, delim)) |idx| {
        return .{ .ok = try newString(ctx.allocator, try ctx.allocator.dupe(u8, s[0..idx])) };
    }
    return .{ .ok = try newString(ctx.allocator, try missingArg(ctx.allocator, if (ctx.args.len > 2) ctx.args[2] else null, s)) };
}

pub fn string_substring_after(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.substringAfter");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("substringAfter requires a delimiter");
    const dr = try argAsString(ctx.allocator, ctx.args[1], "substringAfter");
    const delim = switch (dr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(delim);
    if (std.mem.indexOf(u8, s, delim)) |idx| {
        return .{ .ok = try newString(ctx.allocator, try ctx.allocator.dupe(u8, s[idx + delim.len ..])) };
    }
    return .{ .ok = try newString(ctx.allocator, try missingArg(ctx.allocator, if (ctx.args.len > 2) ctx.args[2] else null, s)) };
}

pub fn string_substring_before_last(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.substringBeforeLast");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("substringBeforeLast requires a delimiter");
    const dr = try argAsString(ctx.allocator, ctx.args[1], "substringBeforeLast");
    const delim = switch (dr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(delim);
    if (std.mem.lastIndexOf(u8, s, delim)) |idx| {
        return .{ .ok = try newString(ctx.allocator, try ctx.allocator.dupe(u8, s[0..idx])) };
    }
    return .{ .ok = try newString(ctx.allocator, try missingArg(ctx.allocator, if (ctx.args.len > 2) ctx.args[2] else null, s)) };
}

pub fn string_substring_after_last(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.substringAfterLast");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len < 2) return errArity("substringAfterLast requires a delimiter");
    const dr = try argAsString(ctx.allocator, ctx.args[1], "substringAfterLast");
    const delim = switch (dr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(delim);
    if (std.mem.lastIndexOf(u8, s, delim)) |idx| {
        return .{ .ok = try newString(ctx.allocator, try ctx.allocator.dupe(u8, s[idx + delim.len ..])) };
    }
    return .{ .ok = try newString(ctx.allocator, try missingArg(ctx.allocator, if (ctx.args.len > 2) ctx.args[2] else null, s)) };
}

pub fn string_replace_first(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.replaceFirst");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (ctx.args.len > 1 and ctx.args[1] == .Regex) {
        const repl: ?Value = if (ctx.args.len > 2) ctx.args[2] else null;
        return regexp.stringRegexReplace(ctx, ctx.args[0].String, ctx.args[1].Regex, repl, true, "replaceFirst");
    }
    if (ctx.args.len < 2) return errArity("replaceFirst requires old");
    const olr = try argAsString(ctx.allocator, ctx.args[1], "replaceFirst");
    const old = switch (olr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(old);
    if (ctx.args.len < 3) return errArity("replaceFirst requires new");
    const ner = try argAsString(ctx.allocator, ctx.args[2], "replaceFirst");
    const new = switch (ner) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    defer ctx.allocator.free(new);
    const ignore_case = ctx.args.len > 3 and ctx.args[3] == .Bool and ctx.args[3].Bool;
    const out = if (ignore_case)
        try replaceAllIgnoreCase(ctx.allocator, s, old, new, 1)
    else
        try replaceAll(ctx.allocator, s, old, new, 1);
    return .{ .ok = try newString(ctx.allocator, out) };
}

pub fn string_trim_indent(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.trimIndent");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(ctx.allocator);
    {
        var it = std.mem.splitScalar(u8, s, '\n');
        while (it.next()) |l| try lines.append(ctx.allocator, l);
    }
    // Minimum indent of non-blank lines.
    var min_indent: ?usize = null;
    for (lines.items) |l| {
        if (lineAllWhitespace(l)) continue;
        var ind: usize = 0;
        for (l) |c| {
            if (c == ' ' or c == '\t') ind += 1 else break;
        }
        if (min_indent == null or ind < min_indent.?) min_indent = ind;
    }
    const mi = min_indent orelse 0;
    var out_lines: std.ArrayList([]const u8) = .empty;
    defer out_lines.deinit(ctx.allocator);
    // Drop the first line and the last line if blank; every other line (blank or
    // not) keeps whatever remains after removing the common indent — so a blank
    // line wider than the common indent retains its extra whitespace.
    const last_idx = lines.items.len - 1;
    for (lines.items, 0..) |l, idx| {
        if ((idx == 0 or idx == last_idx) and lineAllWhitespace(l)) continue;
        try out_lines.append(ctx.allocator, try dropLeadingChars(ctx.allocator, l, mi));
    }
    return .{ .ok = try newString(ctx.allocator, try joinLines(ctx.allocator, out_lines.items)) };
}

/// Drop the first `n` Unicode scalars from `l`. Owned slice.
fn dropLeadingChars(allocator: Allocator, l: []const u8, n: usize) Allocator.Error![]const u8 {
    var i: usize = 0;
    var dropped: usize = 0;
    while (dropped < n and i < l.len) {
        const len = std.unicode.utf8ByteSequenceLength(l[i]) catch 1;
        i = @min(i + len, l.len);
        dropped += 1;
    }
    return allocator.dupe(u8, l[i..]);
}

pub fn string_trim_margin(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.trimMargin");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    var prefix_buf: []const u8 = "|";
    var prefix_owned: ?[]const u8 = null;
    defer if (prefix_owned) |p| ctx.allocator.free(p);
    if (ctx.args.len > 1) {
        switch (ctx.args[1]) {
            .String => |p| {
                const g = p.borrow();
                defer g.deinit();
                prefix_owned = try ctx.allocator.dupe(u8, g.get().bytes);
                prefix_buf = prefix_owned.?;
            },
            .Char => |c| {
                prefix_owned = try charUnitToString(ctx.allocator, c);
                prefix_buf = prefix_owned.?;
            },
            else => |other| {
                prefix_owned = try other.display(ctx.allocator);
                prefix_buf = prefix_owned.?;
            },
        }
    }
    // Split into lines (LF / CR / CRLF), mirroring `lines()`.
    var raw_lines: std.ArrayList([]const u8) = .empty;
    defer raw_lines.deinit(ctx.allocator);
    {
        var i: usize = 0;
        var line_start: usize = 0;
        while (i < s.len) {
            if (s[i] == '\n' or s[i] == '\r') {
                try raw_lines.append(ctx.allocator, s[line_start..i]);
                if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') i += 1;
                i += 1;
                line_start = i;
            } else i += 1;
        }
        try raw_lines.append(ctx.allocator, s[line_start..]);
    }
    var out_lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (out_lines.items) |l| ctx.allocator.free(l);
        out_lines.deinit(ctx.allocator);
    }
    const last_index = raw_lines.items.len - 1;
    for (raw_lines.items, 0..) |l, idx| {
        // A blank first or last line is dropped entirely (`reindent`).
        if ((idx == 0 or idx == last_index) and lineIsBlank(l)) continue;
        // Cut at the margin prefix following the leading whitespace; a line
        // with no such prefix (including an all-whitespace line) is kept
        // unchanged (`indentCutFunction(...) ?: value`).
        const fnw = firstNonWhitespaceByte(l);
        if (fnw) |w| {
            if (std.mem.startsWith(u8, l[w..], prefix_buf)) {
                try out_lines.append(ctx.allocator, try ctx.allocator.dupe(u8, l[w + prefix_buf.len ..]));
                continue;
            }
        }
        try out_lines.append(ctx.allocator, try ctx.allocator.dupe(u8, l));
    }
    return .{ .ok = try newString(ctx.allocator, try joinLines(ctx.allocator, out_lines.items)) };
}

/// Byte offset of the first non-whitespace code point in `l`, or null when
/// every code point is whitespace (`indexOfFirst { !it.isWhitespace() }`).
fn firstNonWhitespaceByte(l: []const u8) ?usize {
    var i: usize = 0;
    while (i < l.len) {
        const len = std.unicode.utf8ByteSequenceLength(l[i]) catch 1;
        const end = @min(i + len, l.len);
        const cp = std.unicode.utf8Decode(l[i..end]) catch l[i];
        if (!isWhitespace(@intCast(cp))) return i;
        i = end;
    }
    return null;
}

/// Whether every code point in `l` is whitespace (`CharSequence.isBlank`).
fn lineIsBlank(l: []const u8) bool {
    return firstNonWhitespaceByte(l) == null;
}

pub fn string_lines(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.lines");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // Kotlin lines() splits on \r\n, \r, and \n.
    const normalized = try normalizeNewlines(ctx.allocator, s);
    defer ctx.allocator.free(normalized);
    var items: std.ArrayList(Value) = .empty;
    errdefer items.deinit(ctx.allocator);
    var it = std.mem.splitScalar(u8, normalized, '\n');
    while (it.next()) |p| try items.append(ctx.allocator, try newString(ctx.allocator, try ctx.allocator.dupe(u8, p)));
    return .{ .ok = try makeList(ctx.allocator, try items.toOwnedSlice(ctx.allocator), false) };
}

pub fn string_to_char_array(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toCharArray");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(ctx.allocator);
    var it = Utf16View{ .bytes = s };
    while (it.next()) |u| try units.append(ctx.allocator, u);
    const length: i64 = @intCast(units.items.len);

    // `toCharArray(destination, destinationOffset, startIndex, endIndex)`:
    // copy the `[startIndex, endIndex)` subrange into the existing
    // `destination` CharArray at `destinationOffset` and return it.
    if (ctx.args.len > 1 and ctx.args[1] == .Array) {
        const dest = ctx.args[1].Array;
        const dest_offset = if (ctx.args.len > 2 and isIntLike(ctx.args[2])) (ctx.args[2].asI64() orelse 0) else 0;
        const start = if (ctx.args.len > 3 and isIntLike(ctx.args[3])) (ctx.args[3].asI64() orelse 0) else 0;
        const end = if (ctx.args.len > 4 and isIntLike(ctx.args[4])) (ctx.args[4].asI64() orelse length) else length;
        if (start < 0 or end > length) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, length });
            return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
        }
        if (start > end) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d} > endIndex: {d}", .{ start, end });
            return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
        }
        const dest_len: i64 = @intCast(dest.len());
        const count = end - start;
        if (dest_offset < 0 or dest_offset + count > dest_len) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "destinationOffset: {d}, count: {d}, destination.length: {d}", .{ dest_offset, count, dest_len });
            return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
        }
        var i: i64 = 0;
        while (i < count) : (i += 1) {
            dest.set(ctx.allocator, @intCast(dest_offset + i), .{ .Char = units.items[@intCast(start + i)] });
        }
        return .{ .ok = ctx.args[1] };
    }

    // `toCharArray()` / `toCharArray(startIndex, endIndex)`: a fresh
    // CharArray holding the `[startIndex, endIndex)` subrange.
    const start = if (ctx.args.len > 1 and isIntLike(ctx.args[1])) (ctx.args[1].asI64() orelse 0) else 0;
    const end = if (ctx.args.len > 2 and isIntLike(ctx.args[2])) (ctx.args[2].asI64() orelse length) else length;
    if (start < 0 or end > length) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d}, endIndex: {d}, size: {d}", .{ start, end, length });
        return try thrownOwned(ctx.allocator, "kotlin.IndexOutOfBoundsException", msg);
    }
    if (start > end) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "startIndex: {d} > endIndex: {d}", .{ start, end });
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    var k: i64 = start;
    while (k < end) : (k += 1) try items.append(ctx.allocator, .{ .Char = units.items[@intCast(k)] });
    return .{ .ok = try runtime.ArrayData.initPacked(ctx.allocator, .Char, items.items) };
}

pub fn string_to_long(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toLong");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const rr = try recvIntRadix(ctx.allocator, if (ctx.args.len > 1) ctx.args[1] else null, "String.toLong");
    const radix = switch (rr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (radix < 2 or radix > 36) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "radix {d} was not in valid range 2..36", .{radix});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    if (parseIntRadix(s, @intCast(radix))) |v| {
        return .{ .ok = .{ .Long = v } };
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "For input string: \"{s}\"", .{s});
    return try thrownOwned(ctx.allocator, "kotlin.NumberFormatException", msg);
}

pub fn string_to_long_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toLongOrNull");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const rr = try recvIntRadix(ctx.allocator, if (ctx.args.len > 1) ctx.args[1] else null, "String.toLongOrNull");
    const radix = switch (rr) {
        .ok => |v| v,
        .err => return .{ .ok = .Null },
    };
    if (radix < 2 or radix > 36) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "radix {d} was not in valid range 2..36", .{radix});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    if (parseIntRadix(s, @intCast(radix))) |v| {
        return .{ .ok = .{ .Long = v } };
    }
    return .{ .ok = .Null };
}

const UKind = enum { ubyte, ushort, uint, ulong };

fn uLimit(kind: UKind) u64 {
    return switch (kind) {
        .ubyte => 0xFF,
        .ushort => 0xFFFF,
        .uint => 0xFFFFFFFF,
        .ulong => 0xFFFFFFFFFFFFFFFF,
    };
}

fn uMake(kind: UKind, v: u64) Value {
    return switch (kind) {
        .ubyte => .{ .UByte = @truncate(v) },
        .ushort => .{ .UShort = @truncate(v) },
        .uint => .{ .UInt = @truncate(v) },
        .ulong => .{ .ULong = v },
    };
}

/// Parse an unsigned magnitude in `radix`, capped at `limit`. Kotlin's
/// unsigned parse accepts an optional leading `+` (never `-`) and yields
/// null on any invalid digit or overflow past `limit`.
fn parseUintRadix(raw: []const u8, radix: u32, limit: u64) ?u64 {
    const s = std.mem.trim(u8, raw, " \t\n\r");
    if (s.len == 0) return null;
    var body = s;
    if (s[0] == '+') {
        body = s[1..];
    } else if (s[0] < '0') {
        return null;
    }
    if (body.len == 0) return null;
    var acc: u64 = 0;
    for (body) |ch| {
        const d = digitValue(ch, radix) orelse return null;
        acc = std.math.mul(u64, acc, @intCast(radix)) catch return null;
        acc = std.math.add(u64, acc, @intCast(d)) catch return null;
        if (acc > limit) return null;
    }
    return acc;
}

fn stringToUnsigned(ctx: *CallCtx, kind: UKind, or_null: bool, what: []const u8) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, what);
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const rr = try recvIntRadix(ctx.allocator, if (ctx.args.len > 1) ctx.args[1] else null, what);
    const radix = switch (rr) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (radix < 2 or radix > 36) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "radix {d} was not in valid range 2..36", .{radix});
        return try thrownOwned(ctx.allocator, "kotlin.IllegalArgumentException", msg);
    }
    if (parseUintRadix(s, @intCast(radix), uLimit(kind))) |m| {
        return .{ .ok = uMake(kind, m) };
    }
    if (or_null) return .{ .ok = .Null };
    const msg = try std.fmt.allocPrint(ctx.allocator, "For input string: \"{s}\"", .{s});
    return try thrownOwned(ctx.allocator, "kotlin.NumberFormatException", msg);
}

pub fn string_to_ubyte(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .ubyte, false, "String.toUByte");
}
pub fn string_to_ubyte_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .ubyte, true, "String.toUByteOrNull");
}
pub fn string_to_ushort(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .ushort, false, "String.toUShort");
}
pub fn string_to_ushort_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .ushort, true, "String.toUShortOrNull");
}
pub fn string_to_uint(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .uint, false, "String.toUInt");
}
pub fn string_to_uint_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .uint, true, "String.toUIntOrNull");
}
pub fn string_to_ulong(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .ulong, false, "String.toULong");
}
pub fn string_to_ulong_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    return stringToUnsigned(ctx, .ulong, true, "String.toULongOrNull");
}

pub fn string_to_double_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toDoubleOrNull");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (parseDouble(s)) |d| return .{ .ok = .{ .Double = d } };
    return .{ .ok = .Null };
}

pub fn string_to_boolean(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toBoolean");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = .{ .Bool = std.ascii.eqlIgnoreCase(s, "true") } };
}

pub fn string_to_boolean_strict_or_null(ctx: *CallCtx) Allocator.Error!EvalResult {
    const r = try recvString(ctx.allocator, ctx.args, "String.toBooleanStrictOrNull");
    const s = switch (r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (std.mem.eql(u8, s, "true")) return .{ .ok = .{ .Bool = true } };
    if (std.mem.eql(u8, s, "false")) return .{ .ok = .{ .Bool = false } };
    return .{ .ok = .Null };
}

// ============================================================
// String.format / kotlin.text.format
// ============================================================

pub fn string_format_static(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .String) {
        return errType("format requires a format String");
    }
    const g = ctx.args[0].String.borrow();
    const fmt = g.get().bytes;
    const args = ctx.args[1..];
    const out = try formatKotlin(ctx.allocator, fmt, args);
    g.deinit();
    return switch (out) {
        .ok => |s| .{ .ok = try newString(ctx.allocator, s) },
        .err => |e| .{ .err = e },
    };
}

pub fn string_format_member(ctx: *CallCtx) Allocator.Error!EvalResult {
    // Receiver-style `"%d".format(x)` — receiver is args[0], args follow.
    return string_format_static(ctx);
}

const FmtResult = union(enum) { ok: []u8, err: RuntimeError };

/// Render a format string in the printf subset Kotlin commonly uses.
fn formatKotlin(allocator: Allocator, fmt: []const u8, args: []const Value) Allocator.Error!FmtResult {
    var chars = try decodeScalars(allocator, fmt);
    defer allocator.free(chars);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var arg_idx: usize = 0;
    while (i < chars.len) {
        const c = chars[i];
        if (c != '%') {
            try appendScalar(allocator, &out, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= chars.len) {
            return .{ .err = .{ .Thrown = try makeException(allocator, "java.util.UnknownFormatConversionException", "trailing %") } };
        }
        // Optional argument index `n$`.
        const start_i = i;
        var idx_override: ?usize = null;
        var j = i;
        while (j < chars.len and isAsciiDigit(chars[j])) j += 1;
        if (j > i and j < chars.len and chars[j] == '$') {
            const n = parseUsizeScalars(chars[i..j]) orelse 0;
            if (n > 0) idx_override = n - 1;
            i = j + 1;
        } else {
            i = start_i;
        }
        // Flags.
        var flag_left = false;
        var flag_zero = false;
        var flag_plus = false;
        var flag_space = false;
        var flag_hash = false;
        var flag_comma = false;
        while (i < chars.len) {
            switch (chars[i]) {
                '-' => flag_left = true,
                '0' => flag_zero = true,
                '+' => flag_plus = true,
                ' ' => flag_space = true,
                '#' => flag_hash = true,
                ',' => flag_comma = true,
                else => break,
            }
            i += 1;
        }
        // Width.
        var width: ?usize = null;
        const wstart = i;
        while (i < chars.len and isAsciiDigit(chars[i])) i += 1;
        if (i > wstart) width = parseUsizeScalars(chars[wstart..i]) orelse 0;
        // Precision.
        var precision: ?usize = null;
        if (i < chars.len and chars[i] == '.') {
            i += 1;
            const pstart = i;
            while (i < chars.len and isAsciiDigit(chars[i])) i += 1;
            if (i > pstart) precision = parseUsizeScalars(chars[pstart..i]) orelse 0;
        }
        if (i >= chars.len) {
            return .{ .err = .{ .Thrown = try makeException(allocator, "java.util.UnknownFormatConversionException", "incomplete format specifier") } };
        }
        const conv = chars[i];
        i += 1;
        if (conv == '%') {
            try out.append(allocator, '%');
            continue;
        }
        if (conv == 'n') {
            try out.append(allocator, '\n');
            continue;
        }
        const consumed_idx = idx_override orelse arg_idx;
        if (idx_override == null) arg_idx += 1;
        const arg: Value = if (consumed_idx < args.len) args[consumed_idx] else .Null;
        const bodyr = try formatConv(allocator, conv, arg, flag_plus, flag_space, flag_hash, flag_zero, flag_comma, precision);
        const body = switch (bodyr) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer allocator.free(body);
        const padded = try padSpec(allocator, body, width, flag_left, flag_zero and !isStringLike(conv));
        defer allocator.free(padded);
        try out.appendSlice(allocator, padded);
    }
    return .{ .ok = try out.toOwnedSlice(allocator) };
}

fn isStringLike(c: u21) bool {
    return c == 's' or c == 'S' or c == 'c' or c == 'C' or c == 'b' or c == 'B';
}

fn padSpec(allocator: Allocator, body: []const u8, width: ?usize, left: bool, zero: bool) Allocator.Error![]u8 {
    const w = width orelse return allocator.dupe(u8, body);
    const cur = utf16Len(body);
    if (cur >= w) return allocator.dupe(u8, body);
    const pad = w - cur;
    const ch: u8 = if (zero) '0' else ' ';
    const pad_buf = try allocator.alloc(u8, pad);
    defer allocator.free(pad_buf);
    @memset(pad_buf, ch);
    if (zero) {
        if (body.len > 0 and body[0] == '-') {
            return std.fmt.allocPrint(allocator, "-{s}{s}", .{ pad_buf, body[1..] });
        }
        if (body.len > 0 and body[0] == '+') {
            return std.fmt.allocPrint(allocator, "+{s}{s}", .{ pad_buf, body[1..] });
        }
    }
    if (left) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ body, pad_buf });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ pad_buf, body });
}

fn formatConv(
    allocator: Allocator,
    conv: u21,
    arg: Value,
    plus: bool,
    space: bool,
    hash: bool,
    zero: bool,
    comma: bool,
    precision: ?usize,
) Allocator.Error!FmtResult {
    _ = zero;
    switch (conv) {
        'd', 'i' => {
            const nr = asLongForFormat(allocator, arg);
            const n = switch (nr) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const mag: u64 = if (n < 0) @as(u64, @intCast(-(n + 1))) + 1 else @intCast(n);
            const body = if (comma) try fmtWithCommas(allocator, n) else try std.fmt.allocPrint(allocator, "{d}", .{mag});
            defer allocator.free(body);
            const s = try signWrap(allocator, body, n < 0, plus, space);
            return .{ .ok = s };
        },
        'x', 'X' => {
            const nr = asLongForFormat(allocator, arg);
            const n = switch (nr) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const u: u64 = @bitCast(n);
            const raw = if (conv == 'X')
                try std.fmt.allocPrint(allocator, "{X}", .{u})
            else
                try std.fmt.allocPrint(allocator, "{x}", .{u});
            defer allocator.free(raw);
            if (hash) {
                const pfx = if (conv == 'X') "0X" else "0x";
                return .{ .ok = try std.fmt.allocPrint(allocator, "{s}{s}", .{ pfx, raw }) };
            }
            return .{ .ok = try allocator.dupe(u8, raw) };
        },
        'o' => {
            const nr = asLongForFormat(allocator, arg);
            const n = switch (nr) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const u: u64 = @bitCast(n);
            return .{ .ok = try std.fmt.allocPrint(allocator, "{o}", .{u}) };
        },
        'b', 'B' => {
            const s = switch (arg) {
                .Null => "false",
                .Bool => |b| if (b) "true" else "false",
                else => "true",
            };
            if (conv == 'B') {
                const up = try allocator.alloc(u8, s.len);
                _ = std.ascii.upperString(up, s);
                return .{ .ok = up };
            }
            return .{ .ok = try allocator.dupe(u8, s) };
        },
        's', 'S' => {
            var s: []u8 = switch (arg) {
                .String => |v| blk: {
                    const g = v.borrow();
                    defer g.deinit();
                    break :blk try allocator.dupe(u8, g.get().bytes);
                },
                .Null => try allocator.dupe(u8, "null"),
                else => try arg.display(allocator),
            };
            if (precision) |p| {
                const units = try utf16Units(allocator, s);
                defer allocator.free(units);
                const take = @min(p, units.len);
                const truncated = try charUnitsToString(allocator, units[0..take]);
                allocator.free(s);
                s = truncated;
            }
            if (conv == 'S') {
                const up = try mapCase(allocator, s, true);
                allocator.free(s);
                return .{ .ok = up };
            }
            return .{ .ok = s };
        },
        'c', 'C' => {
            const s = switch (arg) {
                .Char => |c| try charUnitToString(allocator, c),
                .Int => |n| blk: {
                    if (n < 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF)) {
                        const msg = try std.fmt.allocPrint(allocator, "%c: invalid code point {d}", .{n});
                        return .{ .err = .{ .Type = msg } };
                    }
                    var buf: [4]u8 = undefined;
                    const ln = std.unicode.utf8Encode(@intCast(n), &buf) catch {
                        const msg = try std.fmt.allocPrint(allocator, "%c: invalid code point {d}", .{n});
                        return .{ .err = .{ .Type = msg } };
                    };
                    break :blk try allocator.dupe(u8, buf[0..ln]);
                },
                else => return .{ .err = .{ .Type = try allocator.dupe(u8, "%c requires Char or Int code point") } },
            };
            if (conv == 'C') {
                const up = try mapCase(allocator, s, true);
                allocator.free(s);
                return .{ .ok = up };
            }
            return .{ .ok = s };
        },
        'f' => {
            const dr = asDoubleForFormat(allocator, arg);
            const d = switch (dr) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const p = precision orelse 6;
            const raw = try std.fmt.allocPrint(allocator, "{d:.[1]}", .{ @abs(d), p });
            defer allocator.free(raw);
            const body = if (comma) try insertCommasDecimal(allocator, raw) else try allocator.dupe(u8, raw);
            defer allocator.free(body);
            const neg = std.math.signbit(d) and !std.math.isNan(d);
            const s = try signWrap(allocator, body, neg, plus, space);
            return .{ .ok = s };
        },
        'e', 'E' => {
            const dr = asDoubleForFormat(allocator, arg);
            const d = switch (dr) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const p = precision orelse 6;
            const raw = try std.fmt.allocPrint(allocator, "{e:.[1]}", .{ @abs(d), p });
            defer allocator.free(raw);
            const s = try normalizeScientific(allocator, raw, conv == 'E');
            defer allocator.free(s);
            const neg = std.math.signbit(d);
            const out = try signWrap(allocator, s, neg, plus, space);
            return .{ .ok = out };
        },
        'g', 'G' => {
            const dr = asDoubleForFormat(allocator, arg);
            const d = switch (dr) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            var p = precision orelse 6;
            if (p < 1) p = 1;
            const exp: i32 = if (d == 0.0) 0 else @intFromFloat(std.math.floor(std.math.log10(@abs(d))));
            const use_scientific = exp < -4 or exp >= @as(i32, @intCast(p));
            if (use_scientific) {
                return formatConv(allocator, if (conv == 'G') 'E' else 'e', arg, plus, space, hash, false, comma, p - 1);
            }
            const prec_i: i32 = @as(i32, @intCast(p)) - 1 - exp;
            const prec: usize = if (prec_i < 0) 0 else @intCast(prec_i);
            return formatConv(allocator, 'f', arg, plus, space, hash, false, comma, prec);
        },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "conversion: {u}", .{conv});
            const exc = try makeException(allocator, "java.util.UnknownFormatConversionException", msg);
            if (runtime.freeScratch()) allocator.free(msg);
            return .{ .err = .{ .Thrown = exc } };
        },
    }
}

/// Prefix a sign or space onto `body`. Returns an owned slice.
fn signWrap(allocator: Allocator, body: []const u8, negative: bool, plus: bool, space: bool) Allocator.Error![]u8 {
    if (negative) return std.fmt.allocPrint(allocator, "-{s}", .{body});
    if (plus) return std.fmt.allocPrint(allocator, "+{s}", .{body});
    if (space) return std.fmt.allocPrint(allocator, " {s}", .{body});
    return allocator.dupe(u8, body);
}

fn asLongForFormat(allocator: Allocator, v: Value) union(enum) { ok: i64, err: RuntimeError } {
    if (v.asI64()) |n| return .{ .ok = n };
    switch (v) {
        .Char => |c| return .{ .ok = @intCast(c) },
        .Bool => |b| return .{ .ok = @intFromBool(b) },
        else => {
            const od = v.display(allocator) catch return .{ .err = .{ .Type = "integer format spec requires Int-like" } };
            const msg = std.fmt.allocPrint(allocator, "integer format spec requires Int-like, got {s}", .{od}) catch return .{ .err = .{ .Type = "integer format spec requires Int-like" } };
            return .{ .err = .{ .Type = msg } };
        },
    }
}

fn asDoubleForFormat(allocator: Allocator, v: Value) union(enum) { ok: f64, err: RuntimeError } {
    switch (v) {
        .Double => |d| return .{ .ok = d },
        .Int => |n| return .{ .ok = @floatFromInt(n) },
        else => {
            const od = v.display(allocator) catch return .{ .err = .{ .Type = "float format spec requires Number" } };
            const msg = std.fmt.allocPrint(allocator, "float format spec requires Number, got {s}", .{od}) catch return .{ .err = .{ .Type = "float format spec requires Number" } };
            return .{ .err = .{ .Type = msg } };
        },
    }
}

fn fmtWithCommas(allocator: Allocator, n: i64) Allocator.Error![]u8 {
    const mag: u64 = if (n < 0) @as(u64, @intCast(-(n + 1))) + 1 else @intCast(n);
    const digits = try std.fmt.allocPrint(allocator, "{d}", .{mag});
    defer allocator.free(digits);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (digits, 0..) |ch, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try out.append(allocator, ',');
        try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}

fn insertCommasDecimal(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const whole = if (dot) |d| s[0..d] else s;
    const frac: ?[]const u8 = if (dot) |d| s[d + 1 ..] else null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (whole, 0..) |ch, i| {
        if (i > 0 and (whole.len - i) % 3 == 0) try out.append(allocator, ',');
        try out.append(allocator, ch);
    }
    if (frac) |f| {
        try out.append(allocator, '.');
        try out.appendSlice(allocator, f);
    }
    return out.toOwnedSlice(allocator);
}

/// Convert Zig's `1.234e2` form into Java's `1.234e+02`. Owned slice.
fn normalizeScientific(allocator: Allocator, s: []const u8, upper: bool) Allocator.Error![]u8 {
    const epos = std.mem.indexOfScalar(u8, s, 'e') orelse std.mem.indexOfScalar(u8, s, 'E');
    const mantissa = if (epos) |p| s[0..p] else s;
    const exp_str = if (epos) |p| s[p + 1 ..] else "0";
    const exp_n: i32 = std.fmt.parseInt(i32, exp_str, 10) catch 0;
    const exp_sign: u8 = if (exp_n < 0) '-' else '+';
    const exp_mag: u32 = @intCast(if (exp_n < 0) -exp_n else exp_n);
    const e_letter: u8 = if (upper) 'E' else 'e';
    return std.fmt.allocPrint(allocator, "{s}{c}{c}{d:0>2}", .{ mantissa, e_letter, exp_sign, exp_mag });
}

// ============================================================
// UTF-16 / scalar utilities
// ============================================================

/// Streams the UTF-16 code units of a UTF-8 string one at a time. A
/// supplementary code point yields its high surrogate, then its low
/// surrogate on the following call.
const Utf16View = struct {
    bytes: []const u8,
    pos: usize = 0,
    pending_low: ?u16 = null,

    fn next(self: *Utf16View) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        if (self.pos >= self.bytes.len) return null;
        // A WTF-8 lone surrogate (`ED A0-BF 8x`) decodes to its surrogate code
        // unit directly — `utf8Decode` would reject it.
        if (isWtf8SurrogateAt(self.bytes, self.pos)) {
            const unit = wtf8SurrogateUnit(self.bytes, self.pos);
            self.pos += 3;
            return unit;
        }
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.pos]) catch {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        };
        if (self.pos + len > self.bytes.len) {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.pos .. self.pos + len]) catch {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        };
        self.pos += len;
        if (cp <= 0xFFFF) return @intCast(cp);
        const adjusted = cp - 0x10000;
        const high: u16 = @intCast(0xD800 + (adjusted >> 10));
        const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
        self.pending_low = low;
        return high;
    }
};

fn appendScalar(allocator: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const scalar: u21 = if (cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF)) cp else 0xFFFD;
    const n = std.unicode.utf8Encode(scalar, &buf) catch blk: {
        break :blk std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    };
    try out.appendSlice(allocator, buf[0..n]);
}

/// Decode a UTF-8 string into its Unicode scalars. Malformed bytes become
/// individual scalars (matching `Vec<char>` over a valid string; klio
/// inputs are valid UTF-8). Owned slice.
fn decodeScalars(allocator: Allocator, s: []const u8) Allocator.Error![]u21 {
    var out: std.ArrayList(u21) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        };
        try out.append(allocator, cp);
        i += len;
    }
    return out.toOwnedSlice(allocator);
}

fn isAsciiDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

fn parseUsizeScalars(scalars: []const u21) ?usize {
    var acc: usize = 0;
    for (scalars) |c| {
        if (!isAsciiDigit(c)) return null;
        acc = std.math.mul(usize, acc, 10) catch return null;
        acc = std.math.add(usize, acc, @as(usize, @intCast(c - '0'))) catch return null;
    }
    return acc;
}

/// Decode `bytes` as UTF-8, substituting U+FFFD for malformed sequences
/// (`String::from_utf8_lossy`). Owned slice.
fn utf8Lossy(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const b0 = bytes[i];
        if (b0 < 0x80) {
            try out.append(allocator, b0);
            i += 1;
            continue;
        }
        // Unicode "U+FFFD substitution of maximal subparts" (Table 3-7): a lead
        // byte fixes the sequence length and the valid range of its first
        // continuation; the rest must be 80-BF. An ill-formed sequence emits
        // ONE U+FFFD for its maximal valid prefix, then resumes at the first
        // byte that broke it. C0/C1 and F5-FF are never lead bytes.
        var length: usize = 0;
        var lo2: u8 = 0x80;
        var hi2: u8 = 0xBF;
        if (b0 >= 0xC2 and b0 <= 0xDF) {
            length = 2;
        } else if (b0 == 0xE0) {
            length = 3;
            lo2 = 0xA0;
        } else if (b0 >= 0xE1 and b0 <= 0xEF) {
            // ED A0-BF 80-BF structurally encodes a surrogate: like the JVM
            // decoder, consume the whole 3-byte sequence and emit a single
            // U+FFFD for the surrogate code point (utf8Decode rejects it), rather
            // than splitting per the stricter WHATWG maximal-subpart rule.
            length = 3;
        } else if (b0 == 0xF0) {
            length = 4;
            lo2 = 0x90;
        } else if (b0 >= 0xF1 and b0 <= 0xF3) {
            length = 4;
        } else if (b0 == 0xF4) {
            length = 4;
            hi2 = 0x8F; // <= U+10FFFF
        } else {
            try appendScalar(allocator, &out, 0xFFFD); // invalid lead byte
            i += 1;
            continue;
        }
        var consumed: usize = 1;
        var well_formed = true;
        while (consumed < length) : (consumed += 1) {
            if (i + consumed >= bytes.len) {
                well_formed = false;
                break;
            }
            const bc = bytes[i + consumed];
            const lo: u8 = if (consumed == 1) lo2 else 0x80;
            const hi: u8 = if (consumed == 1) hi2 else 0xBF;
            if (bc < lo or bc > hi) {
                well_formed = false;
                break;
            }
        }
        if (well_formed) {
            const cp = std.unicode.utf8Decode(bytes[i .. i + length]) catch 0xFFFD;
            try appendScalar(allocator, &out, cp);
            i += length;
        } else {
            try appendScalar(allocator, &out, 0xFFFD);
            i += consumed; // maximal subpart length (>= 1)
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Map every scalar of `s` to upper- or lower-case. Owned slice. Covers
/// ASCII and the common 1:1 Latin mappings; non-1:1 expansions fall back to
/// the scalar unchanged.
fn mapCase(allocator: Allocator, s: []const u8, upper: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        };
        const end = @min(i + len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        };
        if (if (upper) scalarToUpperMulti(cp) else scalarToLowerMulti(cp)) |seq| {
            for (seq) |mc| try appendScalar(allocator, &out, mc);
            i = end;
            continue;
        }
        const mapped = if (upper) scalarToUpper(cp) else scalarToLower(cp);
        try appendScalar(allocator, &out, @intCast(mapped));
        i = end;
    }
    return out.toOwnedSlice(allocator);
}

/// Case-insensitive Unicode equality via case-folded comparison. Strings
/// are compared after lower-casing each scalar.
fn eqIgnoreCaseUnicode(allocator: Allocator, a: []const u8, b: []const u8) Allocator.Error!bool {
    // Kotlin's `equals(ignoreCase = true)` folds PER UTF-16 UNIT (each
    // char uppercased, then lowercased on a miss) — whole-string
    // lowercasing diverges where a char's lowercase differs but its
    // uppercase folds ('ſ' vs 'S': lowercase keeps 'ſ', uppercase folds
    // to 'S'), and multi-char expansions ("ß" vs "SS") must NOT equate.
    const ua = try utf16Units(allocator, a);
    defer allocator.free(ua);
    const ub = try utf16Units(allocator, b);
    defer allocator.free(ub);
    if (ua.len != ub.len) return false;
    for (ua, ub) |x, y| {
        if (!charUnitsEqIgnoreCase(x, y)) return false;
    }
    return true;
}

/// Lower-case a single Unicode scalar (ASCII + common Latin/Greek/Cyrillic
/// 1:1 ranges).
fn scalarToLower(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    // The full Unicode 1:1 table — a hand-rolled range subset here missed
    // real mappings (KELVIN SIGN -> 'k' broke compareTo(ignoreCase)).
    return char.lowerScalar(cp);
}

/// Unicode SpecialCasing unconditional multi-character upper-casings — a
/// single scalar whose upper-case form is a sequence (`ß` -> `SS`, the `ﬀ`…`ﬆ`
/// ligatures). `String.uppercase()` / `Char.uppercase()` apply these; the 1:1
/// `scalarToUpper` cannot express an expansion.
fn scalarToUpperMulti(cp: u21) ?[]const u21 {
    return switch (cp) {
        0x00DF => &.{ 'S', 'S' }, // ß LATIN SMALL LETTER SHARP S
        0xFB00 => &.{ 'F', 'F' }, // ﬀ
        0xFB01 => &.{ 'F', 'I' }, // ﬁ
        0xFB02 => &.{ 'F', 'L' }, // ﬂ
        0xFB03 => &.{ 'F', 'F', 'I' }, // ﬃ
        0xFB04 => &.{ 'F', 'F', 'L' }, // ﬄ
        0xFB05 => &.{ 'S', 'T' }, // ﬅ LATIN SMALL LIGATURE LONG S T
        0xFB06 => &.{ 'S', 'T' }, // ﬆ LATIN SMALL LIGATURE ST
        // Greek small letters with dialytika + tonos -> capital + combining marks.
        0x0390 => &.{ 0x0399, 0x0308, 0x0301 }, // ΐ
        0x03B0 => &.{ 0x03A5, 0x0308, 0x0301 }, // ΰ
        else => null,
    };
}

/// Unicode SpecialCasing unconditional multi-character lower-casings.
fn scalarToLowerMulti(cp: u21) ?[]const u21 {
    return switch (cp) {
        0x0130 => &.{ 0x0069, 0x0307 }, // İ -> i + COMBINING DOT ABOVE
        else => null,
    };
}

/// Upper-case a single Unicode scalar (inverse of `scalarToLower`'s ranges).
fn scalarToUpper(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toUpper(@intCast(cp));
    // The full Unicode 1:1 table, matching scalarToLower.
    return char.upperScalar(cp);
}

/// Unicode whitespace test for the scalars Kotlin programs encounter.
fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680 => true,
        0x2000...0x200A => true,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn lineAllWhitespace(l: []const u8) bool {
    var i: usize = 0;
    while (i < l.len) {
        const len = std.unicode.utf8ByteSequenceLength(l[i]) catch 1;
        const end = @min(i + len, l.len);
        const cp = std.unicode.utf8Decode(l[i..end]) catch return false;
        if (!isWhitespace(cp)) return false;
        i = end;
    }
    return true;
}

/// Case-insensitive equality of two UTF-16 unit sub-slices of equal length.
fn unitsEqIgnoreCase(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!char.charEqIgnoreCase(x, y)) return false;
    }
    return true;
}

/// `replace`/`replaceFirst` with ASCII/Unicode case folding. Matches the
/// JVM behavior of comparing each candidate window to `old` with
/// `Char.equals(ignoreCase = true)`. Works in UTF-16 units so a delimiter
/// matches at code-unit boundaries. `max` bounds the number of replacements.
fn replaceAllIgnoreCase(allocator: Allocator, s: []const u8, old: []const u8, new: []const u8, max: ?usize) Allocator.Error![]u8 {
    const su = try utf16Units(allocator, s);
    defer allocator.free(su);
    const ou = try utf16Units(allocator, old);
    defer allocator.free(ou);
    const nu = try utf16Units(allocator, new);
    defer allocator.free(nu);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(allocator);
    var count: usize = 0;
    if (ou.len == 0) {
        try out.appendSlice(allocator, nu);
        count += 1;
        for (su) |u| {
            try out.append(allocator, u);
            if (max == null or count < max.?) {
                try out.appendSlice(allocator, nu);
                count += 1;
            }
        }
        return charUnitsToString(allocator, out.items);
    }
    var i: usize = 0;
    while (i < su.len) {
        if ((max == null or count < max.?) and i + ou.len <= su.len and
            unitsEqIgnoreCase(su[i .. i + ou.len], ou))
        {
            try out.appendSlice(allocator, nu);
            i += ou.len;
            count += 1;
        } else {
            try out.append(allocator, su[i]);
            i += 1;
        }
    }
    return charUnitsToString(allocator, out.items);
}

/// Replace occurrences of `old` with `new`, up to `max` (null = all). An
/// empty `old` inserts `new` between every char and at both ends. Owned
/// slice.
fn replaceAll(allocator: Allocator, s: []const u8, old: []const u8, new: []const u8, max: ?usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (old.len == 0) {
        // Insert `new` between every char and at both ends.
        var count: usize = 0;
        try out.appendSlice(allocator, new);
        count += 1;
        var i: usize = 0;
        while (i < s.len) {
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + len, s.len);
            try out.appendSlice(allocator, s[i..end]);
            if (max == null or count < max.?) {
                try out.appendSlice(allocator, new);
                count += 1;
            }
            i = end;
        }
        return out.toOwnedSlice(allocator);
    }
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len) {
        if ((max == null or count < max.?) and i + old.len <= s.len and std.mem.eql(u8, s[i .. i + old.len], old)) {
            try out.appendSlice(allocator, new);
            i += old.len;
            count += 1;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Normalize CRLF and lone CR to LF. Owned slice.
fn normalizeNewlines(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\r') {
            try out.append(allocator, '\n');
            if (i + 1 < s.len and s[i + 1] == '\n') {
                i += 2;
            } else {
                i += 1;
            }
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Join lines with `\n` and trim leading/trailing empty lines (trimIndent).
fn joinLines(allocator: Allocator, lines: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lines, 0..) |l, i| {
        if (i > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, l);
    }
    return out.toOwnedSlice(allocator);
}

/// Stringify a CharSequence receiver (String or StringBuilder). Owned slice.
fn charSeqToString(allocator: Allocator, v: Value, what: []const u8) Allocator.Error!union(enum) { ok: []u8, err: RuntimeError } {
    switch (v) {
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            return .{ .ok = try allocator.dupe(u8, g.get().items) };
        },
        else => {
            const r = try argAsString(allocator, v, what);
            return switch (r) {
                .ok => |s| .{ .ok = @constCast(s) },
                .err => |e| .{ .err = e },
            };
        },
    }
}

/// Parse a Double the way Kotlin's `String.toDouble` does (Java
/// `Double.parseDouble`): trims surrounding whitespace, accepts Kotlin's
/// `NaN`/`Infinity` spellings, otherwise standard float syntax.
/// Kotlin only accepts the exact-case `NaN`/`Infinity` symbols (with an
/// optional sign); a number otherwise begins with a digit, `.` or sign. A
/// leading letter (after an optional sign) is a non-canonical spelling like
/// "naN"/"inf"/"infinity" that `std.fmt.parseFloat` would wrongly accept, so
/// reject it. (A digit-led overflow like "1e400" correctly yields Infinity.)
/// Kotlin/Java accept a single trailing float type-suffix (`f`/`F`/`d`/`D`),
/// which `std.fmt.parseFloat` does not. Strip it. For a hex literal the suffix
/// letters are also hex digits, so only strip when a `p`/`P` binary exponent is
/// present (a complete hex float); a bare `0x1f` keeps its `f` (and is rejected
/// for lacking the exponent).
fn stripFloatSuffix(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const last = s[s.len - 1];
    if (last != 'f' and last != 'F' and last != 'd' and last != 'D') return s;
    const body = s[0 .. s.len - 1];
    const after_sign = if (body.len > 0 and (body[0] == '+' or body[0] == '-')) body[1..] else body;
    const is_hex = after_sign.len >= 2 and after_sign[0] == '0' and (after_sign[1] == 'x' or after_sign[1] == 'X');
    if (!is_hex) return body;
    if (std.mem.indexOfScalar(u8, body, 'p') != null or std.mem.indexOfScalar(u8, body, 'P') != null) return body;
    return s;
}

fn floatSymbolReject(s: []const u8) bool {
    const body = if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s[1..] else s;
    if (body.len == 0) return false;
    // A non-canonical nan/inf spelling (leading letter).
    if (std.ascii.isAlphabetic(body[0])) return true;
    // A hex float requires a `p`/`P` binary exponent (Java/Kotlin format
    // `0x1.8p3`). `std.fmt.parseFloat` also accepts a bare hex *integer*
    // (`0x11ff33`), which Kotlin rejects — so reject a `0x…` lacking `p`/`P`.
    if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) {
        return std.mem.indexOfScalar(u8, body, 'p') == null and std.mem.indexOfScalar(u8, body, 'P') == null;
    }
    return false;
}

/// Java/Kotlin `parseDouble` trims any leading/trailing char `<= ' '`
/// (the same set `String.trim()` strips — space, tab, newlines, and NUL and
/// other ASCII controls). All such code units are single WTF-8 bytes.
fn trimNumericWhitespace(raw: []const u8) []const u8 {
    var lo: usize = 0;
    var hi: usize = raw.len;
    while (lo < hi and raw[lo] <= 0x20) lo += 1;
    while (hi > lo and raw[hi - 1] <= 0x20) hi -= 1;
    return raw[lo..hi];
}

fn parseDouble(raw: []const u8) ?f64 {
    const s = trimNumericWhitespace(raw);
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "NaN") or std.mem.eql(u8, s, "+NaN") or std.mem.eql(u8, s, "-NaN")) return std.math.nan(f64);
    if (std.mem.eql(u8, s, "Infinity") or std.mem.eql(u8, s, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
    if (floatSymbolReject(s)) return null;
    return std.fmt.parseFloat(f64, stripFloatSuffix(s)) catch null;
}

fn parseFloat(raw: []const u8) ?f32 {
    const s = trimNumericWhitespace(raw);
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "NaN") or std.mem.eql(u8, s, "+NaN") or std.mem.eql(u8, s, "-NaN")) return std.math.nan(f32);
    if (std.mem.eql(u8, s, "Infinity") or std.mem.eql(u8, s, "+Infinity")) return std.math.inf(f32);
    if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f32);
    if (floatSymbolReject(s)) return null;
    return std.fmt.parseFloat(f32, stripFloatSuffix(s)) catch null;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn ctxFor(allocator: Allocator, args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = undefined,
        .host = undefined,
        .allocator = allocator,
    };
}

fn strVal(allocator: Allocator, s: []const u8) !Value {
    return .{ .String = try runtime.strInitOwned(allocator, try allocator.dupe(u8, s)) };
}

fn expectStr(allocator: Allocator, res: EvalResult, want: []const u8) !void {
    switch (res) {
        .ok => |v| {
            try testing.expect(v == .String);
            const g = v.String.borrow();
            defer g.deinit();
            try testing.expectEqualStrings(want, g.get().bytes);
        },
        .err => return error.UnexpectedError,
    }
    _ = allocator;
}

test "plus accepts its nullable String receiver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ .Null, try strVal(a, "tail") });
        try expectStr(a, try string_plus(&ctx), "nulltail");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "head"), .Null });
        try expectStr(a, try string_plus(&ctx), "headnull");
    }
}

test "length counts utf16 code units" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "hello")});
        const r = try string_length(&ctx);
        try testing.expectEqual(@as(i32, 5), r.ok.Int);
    }
    {
        // An astral scalar counts as 2 UTF-16 units.
        var ctx = ctxFor(a, &.{try strVal(a, "\u{1F600}")});
        const r = try string_length(&ctx);
        try testing.expectEqual(@as(i32, 2), r.ok.Int);
    }
}

test "uppercase and lowercase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "Hello")});
        try expectStr(a, try string_uppercase(&ctx), "HELLO");
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "Hello")});
        try expectStr(a, try string_lowercase(&ctx), "hello");
    }
}

test "substring with one and two args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abcdef"), .{ .Int = 2 } });
        try expectStr(a, try string_substring(&ctx), "cdef");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abcdef"), .{ .Int = 1 }, .{ .Int = 4 } });
        try expectStr(a, try string_substring(&ctx), "bcd");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "ab"), .{ .Int = 0 }, .{ .Int = 5 } });
        const r = try string_substring(&ctx);
        try testing.expect(r == .err and r.err == .Thrown);
    }
}

test "get returns char and bounds-checks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abc"), .{ .Int = 1 } });
        const r = try string_get(&ctx);
        try testing.expectEqual(@as(u16, 'b'), r.ok.Char);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abc"), .{ .Int = 9 } });
        const r = try string_get(&ctx);
        try testing.expect(r == .err and r.err == .Thrown);
    }
}

test "starts and ends with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "hello"), try strVal(a, "he") });
        try testing.expect((try string_starts_with(&ctx)).ok.Bool);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "hello"), try strVal(a, "lo") });
        try testing.expect((try string_ends_with(&ctx)).ok.Bool);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "hello"), try strVal(a, "xx") });
        try testing.expect(!(try string_starts_with(&ctx)).ok.Bool);
    }
}

test "contains and indexOf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abcabc"), try strVal(a, "bc") });
        try testing.expect((try string_contains(&ctx)).ok.Bool);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abcabc"), try strVal(a, "bc") });
        try testing.expectEqual(@as(i32, 1), (try string_index_of(&ctx)).ok.Int);
    }
    {
        // startIndex skips the first match.
        var ctx = ctxFor(a, &.{ try strVal(a, "abcabc"), try strVal(a, "bc"), .{ .Int = 2 } });
        try testing.expectEqual(@as(i32, 4), (try string_index_of(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abcabc"), try strVal(a, "bc") });
        try testing.expectEqual(@as(i32, 4), (try string_last_index_of(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abc"), try strVal(a, "z") });
        try testing.expectEqual(@as(i32, -1), (try string_index_of(&ctx)).ok.Int);
    }
}

test "contentEquals implements nullable CharSequence equality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ .Null, .Null, .{ .Bool = true } });
        try testing.expect((try char_sequence_content_equals(&ctx)).ok.Bool);
    }
    {
        var ctx = ctxFor(a, &.{ .Null, try strVal(a, "sample"), .{ .Bool = true } });
        try testing.expect(!(try char_sequence_content_equals(&ctx)).ok.Bool);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "sample"), .Null, .{ .Bool = true } });
        try testing.expect(!(try char_sequence_content_equals(&ctx)).ok.Bool);
    }
}

test "replace and replaceFirst" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "a-b-c"), try strVal(a, "-"), try strVal(a, "_") });
        try expectStr(a, try string_replace(&ctx), "a_b_c");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "a-b-c"), try strVal(a, "-"), try strVal(a, "_") });
        try expectStr(a, try string_replace_first(&ctx), "a_b-c");
    }
}

test "trim variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "  hi  ")});
        try expectStr(a, try string_trim(&ctx), "hi");
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "  hi  ")});
        try expectStr(a, try string_trim_start(&ctx), "hi  ");
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "  hi  ")});
        try expectStr(a, try string_trim_end(&ctx), "  hi");
    }
    {
        // Trim a vararg char set.
        var ctx = ctxFor(a, &.{ try strVal(a, "xxabcxx"), .{ .Char = 'x' } });
        try expectStr(a, try string_trim(&ctx), "abc");
    }
}

test "repeat and reversed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "ab"), .{ .Int = 3 } });
        try expectStr(a, try string_repeat(&ctx), "ababab");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "ab"), .{ .Int = -1 } });
        const r = try string_repeat(&ctx);
        try testing.expect(r == .err and r.err == .Thrown);
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "abc")});
        try expectStr(a, try string_reversed(&ctx), "cba");
    }
}

test "compareTo yields the code-unit difference kotlinc yields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `'c' - 'd'` is -1, so this pair passes under a sign-only result too;
    // the cases below are the ones that distinguish them.
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abc"), try strVal(a, "abd") });
        try testing.expectEqual(@as(i32, -1), (try string_compare_to(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "abc"), try strVal(a, "abc") });
        try testing.expectEqual(@as(i32, 0), (try string_compare_to(&ctx)).ok.Int);
    }
    // First mismatch: the difference of the code units, not its sign.
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "a"), try strVal(a, "c") });
        try testing.expectEqual(@as(i32, -2), (try string_compare_to(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "A"), try strVal(a, "a") });
        try testing.expectEqual(@as(i32, -32), (try string_compare_to(&ctx)).ok.Int);
    }
    // A prefix: the LENGTH difference in UTF-16 code units.
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "ab"), try strVal(a, "abcd") });
        try testing.expectEqual(@as(i32, -2), (try string_compare_to(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, ""), try strVal(a, "abc") });
        try testing.expectEqual(@as(i32, -3), (try string_compare_to(&ctx)).ok.Int);
    }
    // `ignoreCase` folds first, then takes the same difference.
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "A"), try strVal(a, "a"), .{ .Bool = true } });
        try testing.expectEqual(@as(i32, 0), (try string_compare_to(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "a"), try strVal(a, "C"), .{ .Bool = true } });
        try testing.expectEqual(@as(i32, -2), (try string_compare_to(&ctx)).ok.Int);
    }
}

test "toInt parses with radix and bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "42")});
        try testing.expectEqual(@as(i32, 42), (try string_to_int(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "ff"), .{ .Int = 16 } });
        try testing.expectEqual(@as(i32, 255), (try string_to_int(&ctx)).ok.Int);
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "nope")});
        const r = try string_to_int(&ctx);
        try testing.expect(r == .err and r.err == .Thrown);
    }
    {
        // Overflows i32 -> null for toIntOrNull.
        var ctx = ctxFor(a, &.{try strVal(a, "9999999999")});
        try testing.expect((try string_to_int_or_null(&ctx)).ok == .Null);
    }
}

test "toLong and toDouble" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "9999999999")});
        try testing.expectEqual(@as(i64, 9999999999), (try string_to_long(&ctx)).ok.Long);
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "3.5")});
        try testing.expectEqual(@as(f64, 3.5), (try string_to_double(&ctx)).ok.Double);
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "bad")});
        try testing.expect((try string_to_double_or_null(&ctx)).ok == .Null);
    }
}

test "toBoolean variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "TRUE")});
        try testing.expect((try string_to_boolean(&ctx)).ok.Bool);
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "TRUE")});
        try testing.expect((try string_to_boolean_strict_or_null(&ctx)).ok == .Null);
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "false")});
        try testing.expect(!(try string_to_boolean_strict_or_null(&ctx)).ok.Bool);
    }
}

test "split on delimiters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{ try strVal(a, "a,b,c"), try strVal(a, ",") });
    const r = try string_split(&ctx);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    try testing.expectEqual(@as(usize, 3), items.len);
    {
        const gg = items[0].String.borrow();
        defer gg.deinit();
        try testing.expectEqualStrings("a", gg.get().bytes);
    }
    {
        const gg = items[2].String.borrow();
        defer gg.deinit();
        try testing.expectEqualStrings("c", gg.get().bytes);
    }
}

test "split honors limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{ try strVal(a, "a,b,c"), try strVal(a, ","), .{ .Int = 2 } });
    const r = try string_split(&ctx);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    try testing.expectEqual(@as(usize, 2), items.len);
    const gg = items[1].String.borrow();
    defer gg.deinit();
    try testing.expectEqualStrings("b,c", gg.get().bytes);
}

test "padStart and padEnd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "7"), .{ .Int = 3 }, .{ .Char = '0' } });
        try expectStr(a, try string_pad_start(&ctx), "007");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "7"), .{ .Int = 3 } });
        try expectStr(a, try string_pad_end(&ctx), "7  ");
    }
    {
        // Already at/over length: returned unchanged.
        var ctx = ctxFor(a, &.{ try strVal(a, "abcd"), .{ .Int = 2 } });
        try expectStr(a, try string_pad_start(&ctx), "abcd");
    }
}

test "chunked splits into pieces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{ try strVal(a, "abcde"), .{ .Int = 2 } });
    const r = try string_chunked(&ctx);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    try testing.expectEqual(@as(usize, 3), items.len);
    const gg = items[2].String.borrow();
    defer gg.deinit();
    try testing.expectEqualStrings("e", gg.get().bytes);
}

test "windowed produces sliding windows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{ try strVal(a, "abcd"), .{ .Int = 2 } });
    const r = try string_windowed(&ctx);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    try testing.expectEqual(@as(usize, 3), items.len);
    const gg = items[0].String.borrow();
    defer gg.deinit();
    try testing.expectEqualStrings("ab", gg.get().bytes);
}

test "equals with ignoreCase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "Hi"), try strVal(a, "hi"), .{ .Bool = true } });
        try testing.expect((try string_equals(&ctx)).ok.Bool);
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "Hi"), try strVal(a, "hi") });
        try testing.expect(!(try string_equals(&ctx)).ok.Bool);
    }
}

test "substringBefore and After" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "key=value"), try strVal(a, "=") });
        try expectStr(a, try string_substring_before(&ctx), "key");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "key=value"), try strVal(a, "=") });
        try expectStr(a, try string_substring_after(&ctx), "value");
    }
    {
        // Missing delimiter returns the whole receiver by default.
        var ctx = ctxFor(a, &.{ try strVal(a, "novalue"), try strVal(a, "=") });
        try expectStr(a, try string_substring_after(&ctx), "novalue");
    }
}

test "lines splits on newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{try strVal(a, "a\r\nb\nc")});
    const r = try string_lines(&ctx);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 3), g.get().items.len);
}

test "trimIndent and trimMargin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "    a\n    b")});
        try expectStr(a, try string_trim_indent(&ctx), "a\nb");
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "    |a\n    |b")});
        try expectStr(a, try string_trim_margin(&ctx), "a\nb");
    }
}

test "toByteArray and decodeToString roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{try strVal(a, "hi")});
    const ba = try string_to_byte_array(&ctx);
    try testing.expect(ba.ok == .Array);
    var ctx2 = ctxFor(a, &.{ba.ok});
    try expectStr(a, try byte_array_decode_to_string(&ctx2), "hi");
}

test "toCharArray and toList" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "ab")});
        const r = try string_to_char_array(&ctx);
        try testing.expect(r.ok == .Array and r.ok.Array.prim.? == .Char);
        try testing.expectEqual(@as(usize, 2), r.ok.Array.len());
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "ab")});
        const r = try string_to_list(&ctx);
        const g = r.ok.List.items.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(u16, 'a'), g.get().items[0].Char);
    }
}

test "capitalize and decapitalize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{try strVal(a, "hello")});
        try expectStr(a, try string_capitalize(&ctx), "Hello");
    }
    {
        var ctx = ctxFor(a, &.{try strVal(a, "Hello")});
        try expectStr(a, try string_decapitalize(&ctx), "hello");
    }
}

test "format integer specifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "%05d"), .{ .Int = 42 } });
        try expectStr(a, try string_format_static(&ctx), "00042");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "%x"), .{ .Int = 255 } });
        try expectStr(a, try string_format_static(&ctx), "ff");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "%,d"), .{ .Int = 1234567 } });
        try expectStr(a, try string_format_static(&ctx), "1,234,567");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "%+d"), .{ .Int = 7 } });
        try expectStr(a, try string_format_static(&ctx), "+7");
    }
}

test "format string and float specifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "[%5s]"), try strVal(a, "hi") });
        try expectStr(a, try string_format_static(&ctx), "[   hi]");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "[%-5s]"), try strVal(a, "hi") });
        try expectStr(a, try string_format_static(&ctx), "[hi   ]");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "%.2f"), .{ .Double = 3.14159 } });
        try expectStr(a, try string_format_static(&ctx), "3.14");
    }
    {
        var ctx = ctxFor(a, &.{ try strVal(a, "%d%%"), .{ .Int = 50 } });
        try expectStr(a, try string_format_static(&ctx), "50%");
    }
    {
        // Positional argument index.
        var ctx = ctxFor(a, &.{ try strVal(a, "%2$s %1$s"), try strVal(a, "a"), try strVal(a, "b") });
        try expectStr(a, try string_format_static(&ctx), "b a");
    }
}

test "format scientific normalizes exponent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{ try strVal(a, "%.2e"), .{ .Double = 12345.0 } });
    try expectStr(a, try string_format_static(&ctx), "1.23e+04");
}

test "non-string receiver errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctxFor(a, &.{.{ .Int = 5 }});
    const r = try string_length(&ctx);
    try testing.expect(r == .err and r.err == .Type);
}
