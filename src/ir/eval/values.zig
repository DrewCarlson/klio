//! Value semantics with no frame coupling: truthiness, constants, unary and
//! binary operators, comparison, and ranges.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const RangeKind = runtime.RangeKind;

const BinOp = ir.BinOp;
const Const = ir.Const;
const ConstId = ir.ConstId;
const Module = ir.Module;
const UnOp = ir.UnOp;

const ev_diag = @import("diag.zig");
const ev_exec = @import("exec.zig");
const ev_flow = @import("flow.zig");
const ev_state = @import("state.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const currentFrameFunc = ev_state.currentFrameFunc;
const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
const errResult = ev_flow.errResult;
const ok = ev_flow.ok;
const scalarBin = ev_exec.scalarBin;
const strVal = ev_state.strVal;

pub fn valueTruthy(allocator: Allocator, v: *const Value) Allocator.Error!union(enum) { ok: bool, err: EvalError } {
    switch (v.*) {
        .Bool => |b| return .{ .ok = b },
        else => {
            const s = v.display(allocator) catch "?";
            const fname: []const u8 = if (currentFrameFunc()) |cf| cf.fqn else "?";
            const fid: u32 = if (currentFrameFunc()) |cf| cf.id.int() else 0;
            const sp: ?span.Span = if (ev_state.evtlsPtr().frame_chain) |fr| fr.span() else null;
            const msg = if (sp) |p2|
                try std.fmt.allocPrint(allocator, "non-bool in branch: {s} (in {s}#{d} at f{d}:{d})", .{ s, fname, fid, p2.file.int(), p2.start })
            else
                try std.fmt.allocPrint(allocator, "non-bool in branch: {s} (in {s}#{d})", .{ s, fname, fid });
            return .{ .err = .{ .Type = msg } };
        },
    }
}

pub fn constToValue(allocator: Allocator, c: *const Const) Allocator.Error!Value {
    return switch (c.*) {
        .Unit => .Unit,
        .Int => |i| .{ .Int = i },
        .Long => |l| .{ .Long = l },
        .UInt => |v| .{ .UInt = v },
        .ULong => |v| .{ .ULong = v },
        .UShort => |v| .{ .UShort = v },
        .UByte => |v| .{ .UByte = v },
        .Short => |v| .{ .Short = v },
        .Byte => |v| .{ .Byte = v },
        .Double => |d| .{ .Double = d },
        .Float => |f| .{ .Float = f },
        .Bool => |b| .{ .Bool = b },
        .Char => |c2| .{ .Char = c2 },
        .String => |s| try strVal(allocator, s),
        .Null => .Null,
    };
}

pub fn applyUnop(allocator: Allocator, op: UnOp, v: *const Value) Allocator.Error!EvalResult {
    switch (op) {
        .Neg => switch (v.*) {
            .Int => |i| return ok(.{ .Int = -%i }),
            .Long => |l| return ok(.{ .Long = -%l }),
            // Negating NaN keeps the canonical quiet NaN instead of flipping the IEEE sign bit: `Double.NaN.toRawBits()` is `0x7FF8000000000000`.
            .Double => |d| return ok(.{ .Double = if (std.math.isNan(d)) std.math.nan(f64) else -d }),
            .Float => |f| return ok(.{ .Float = if (std.math.isNan(f)) std.math.nan(f32) else -f }),
            // `Byte`/`Short.unaryMinus()` widen to `Int` (Kotlin).
            .Byte => |b| return ok(.{ .Int = -@as(i32, b) }),
            .Short => |s| return ok(.{ .Int = -@as(i32, s) }),
            else => {},
        },
        .Plus => return ok(v.*),
        .Inc => switch (v.*) {
            .Int => |i| return ok(.{ .Int = i +% 1 }),
            .Long => |l| return ok(.{ .Long = l +% 1 }),
            .Float => |f| return ok(.{ .Float = f + 1.0 }),
            .Double => |d| return ok(.{ .Double = d + 1.0 }),
            .Char => |c| return ok(.{ .Char = c +% 1 }),
            // `inc()`/`dec()` keep the receiver's type.
            .Byte => |b| return ok(.{ .Byte = b +% 1 }),
            .Short => |s| return ok(.{ .Short = s +% 1 }),
            .UByte => |b| return ok(.{ .UByte = b +% 1 }),
            .UShort => |s| return ok(.{ .UShort = s +% 1 }),
            .UInt => |x| return ok(.{ .UInt = x +% 1 }),
            .ULong => |x| return ok(.{ .ULong = x +% 1 }),
            else => {},
        },
        .Dec => switch (v.*) {
            .Int => |i| return ok(.{ .Int = i -% 1 }),
            .Long => |l| return ok(.{ .Long = l -% 1 }),
            .Float => |f| return ok(.{ .Float = f - 1.0 }),
            .Double => |d| return ok(.{ .Double = d - 1.0 }),
            .Char => |c| return ok(.{ .Char = c -% 1 }),
            .Byte => |b| return ok(.{ .Byte = b -% 1 }),
            .Short => |s| return ok(.{ .Short = s -% 1 }),
            .UByte => |b| return ok(.{ .UByte = b -% 1 }),
            .UShort => |s| return ok(.{ .UShort = s -% 1 }),
            .UInt => |x| return ok(.{ .UInt = x -% 1 }),
            .ULong => |x| return ok(.{ .ULong = x -% 1 }),
            else => {},
        },
        .ToByte, .ToShort, .ToInt, .ToLong, .ToFloat, .ToDouble, .ToChar => {
            if (runtime.numconv.convert(op.conversion().?, v.*)) |out| return ok(out);
        },
        .Inv, .ToRawBits, .ToBits, .FloatFromBits, .DoubleFromBits, .CountTrailingZeroBits, .UIntToFloat, .UIntToDouble, .ULongToFloat, .ULongToDouble, .Sin, .Cos, .Sqrt, .ToULong, .ToUInt, .ToUShort, .ToUByte, .UnsignedBits => {
            if (runtime.numfn.apply(op.function().?, v.*)) |out| return ok(out);
        },
    }
    const s = v.display(allocator) catch "?";
    const msg = try std.fmt.allocPrint(allocator, "UnOp.{s} on {s} ({s})", .{ @tagName(op), s, @tagName(v.*) });
    return errResult(.{ .Type = msg });
}

pub fn valueToI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Int => |i| @as(i64, i),
        .Long => |l| l,
        else => null,
    };
}

pub fn isSetOrMap(v: *const Value) bool {
    return v.* == .Set or v.* == .Map;
}

pub fn operatorMethod(op: BinOp) ?[]const u8 {
    return switch (op) {
        .Add => "plus",
        .Sub => "minus",
        .Mul => "times",
        .Div => "div",
        .Mod => "rem",
        .Eq, .BoxedEq => "equals",
        // `!=` dispatches `equals` as well; the operator-method caller negates the result.
        .NotEq, .BoxedNotEq => "equals",
        .Less, .LessEq, .Greater, .GreaterEq => "compareTo",
        .RangeTo => "rangeTo",
        .RangeUntil => "rangeUntil",
        else => null,
    };
}

/// The in-place compound-assign method (`plusAssign` family) for a binary arithmetic op.
pub fn compoundAssignMethod(op: BinOp) ?[]const u8 {
    return switch (op) {
        .Add => "plusAssign",
        .Sub => "minusAssign",
        .Mul => "timesAssign",
        .Div => "divAssign",
        .Mod => "remAssign",
        else => null,
    };
}

/// Render a value the way Kotlin's `toString` and string templates do. Caller owns the string.
pub fn renderValue(allocator: Allocator, v: *const Value) Allocator.Error![]const u8 {
    return switch (v.*) {
        .Unit => allocator.dupe(u8, "kotlin.Unit"),
        .Int => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .Long => |l| std.fmt.allocPrint(allocator, "{d}", .{l}),
        .Short => |s| std.fmt.allocPrint(allocator, "{d}", .{s}),
        .Byte => |b| std.fmt.allocPrint(allocator, "{d}", .{b}),
        .UInt => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .ULong => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .UShort => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .UByte => |u| std.fmt.allocPrint(allocator, "{d}", .{u}),
        .Double => |d| runtime.kotlinDoubleToString(allocator, d),
        .Float => |f| runtime.kotlinFloatToString(allocator, f),
        .Bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk allocator.dupe(u8, g.get().bytes);
        },
        .Char => |c| runtime.charUnitToString(allocator, c),
        .Null => allocator.dupe(u8, "null"),
        else => v.display(allocator),
    };
}

/// One side of a string concatenation as its text: a string's own bytes, a number's,
/// a Boolean's, `null`'s or an ASCII Char's written to `buf`, as `renderValue` renders them.
const Piece = struct { bytes: []const u8, u16_len: u32, ascii: bool };

fn concatPiece(v: *const Value, buf: *[24]u8) ?Piece {
    const text: []const u8 = switch (v.*) {
        .String => |s| {
            const d = s.asPtrConst();
            return .{ .bytes = d.bytes, .u16_len = d.u16_len, .ascii = d.ascii };
        },
        .Int => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .Long => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .Short => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .Byte => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .UInt => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .ULong => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .UShort => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .UByte => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch return null,
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .Char => |c| if (c < 0x80) blk: {
            buf[0] = @intCast(c);
            break :blk buf[0..1];
        } else return null,
        else => return null,
    };
    return .{ .bytes = text, .u16_len = @intCast(text.len), .ascii = true };
}

/// `l + r` as strings made in one allocation, the sides read in place (`concatPiece`); null
/// when either side needs `renderValue`.
pub fn concatInPlace(allocator: Allocator, l: *const Value, r: *const Value) Allocator.Error!?runtime.StringRef {
    var lb: [24]u8 = undefined;
    var rb: [24]u8 = undefined;
    const lp = concatPiece(l, &lb) orelse return null;
    const rp = concatPiece(r, &rb) orelse return null;
    const ref = try runtime.strInitTrailing(allocator, lp.bytes.len + rp.bytes.len);
    const d = ref.asPtr();
    const s = @constCast(d.bytes);
    @memcpy(s[0..lp.bytes.len], lp.bytes);
    @memcpy(s[lp.bytes.len..], rp.bytes);
    d.u16_len = lp.u16_len + rp.u16_len;
    d.ascii = lp.ascii and rp.ascii;
    return ref;
}

/// UTF-16 code-unit cursor over UTF-8: an astral codepoint yields its high surrogate, then the low one.
const Utf16Cursor = struct {
    it: std.unicode.Utf8Iterator,
    pending_low: ?u16 = null,

    fn init(s: []const u8) Utf16Cursor {
        return .{ .it = std.unicode.Utf8View.initUnchecked(s).iterator() };
    }

    fn next(self: *Utf16Cursor) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        const cp = self.it.nextCodepoint() orelse return null;
        if (cp <= 0xFFFF) return @intCast(cp);
        const adjusted = cp - 0x10000;
        const high: u16 = @intCast(0xD800 + (adjusted >> 10));
        self.pending_low = @intCast(0xDC00 + (adjusted & 0x3FF));
        return high;
    }
};

/// Lexicographic compare in UTF-16 code units, matching Kotlin's `String.compareTo`.
fn utf16Cmp(left: []const u8, right: []const u8) std.math.Order {
    var lc = Utf16Cursor.init(left);
    var rc = Utf16Cursor.init(right);
    while (true) {
        const lu = lc.next();
        const ru = rc.next();
        if (lu == null and ru == null) return .eq;
        if (lu == null) return .lt;
        if (ru == null) return .gt;
        if (lu.? < ru.?) return .lt;
        if (lu.? > ru.?) return .gt;
    }
}

fn arithExc(allocator: Allocator, msg: []const u8) Allocator.Error!EvalError {
    return .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, "kotlin.ArithmeticException"),
        .message = .from(try runtime.strInit(allocator, msg)),
        .cause = null,
    }) };
}

pub fn applyBinop(allocator: Allocator, op: BinOp, l: *const Value, r: *const Value) Allocator.Error!EvalResult {
    // Kotlin promotes `Byte`/`Short` to `Int` in arithmetic and comparison; widen and re-dispatch.
    if ((promoteByteShort(l) != null or promoteByteShort(r) != null) and op != .StringConcat) {
        const nl = promoteByteShort(l) orelse l.*;
        const nr = promoteByteShort(r) orelse r.*;
        return applyBinop(allocator, op, &nl, &nr);
    }
    // Kotlin promotes UByte/UShort to UInt in arithmetic and comparison.
    if ((promoteUByteUShort(l) != null or promoteUByteUShort(r) != null) and op != .StringConcat) {
        const nl = promoteUByteUShort(l) orelse l.*;
        const nr = promoteUByteUShort(r) orelse r.*;
        return applyBinop(allocator, op, &nl, &nr);
    }
    switch (op) {
        .Add => {
            if (l.* == .Int and r.* == .Int) return ok(.{ .Int = l.Int +% r.Int });
            if (l.* == .Char and r.* == .Int) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) +% @as(i64, r.Int)))) });
            if (l.* == .Char and r.* == .Long) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) +% r.Long))) });
            if (l.* == .Long and r.* == .Long) return ok(.{ .Long = l.Long +% r.Long });
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = l.Long +% @as(i64, r.Int) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = @as(i64, l.Int) +% r.Long });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double + @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) + r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double + @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) + r.Double });
            if (l.* == .UInt and r.* == .UInt) return ok(.{ .UInt = l.UInt +% r.UInt });
            if (l.* == .ULong and r.* == .ULong) return ok(.{ .ULong = l.ULong +% r.ULong });
            if (l.* == .ULong and r.* == .UInt) return ok(.{ .ULong = l.ULong +% @as(u64, r.UInt) });
            if (l.* == .UInt and r.* == .ULong) return ok(.{ .ULong = @as(u64, l.UInt) +% r.ULong });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float + r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) + r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double + @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) + r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float + @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) + r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float + @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double + r.Double });
            if (l.* == .String) {
                const g = l.String.borrow();
                defer g.deinit();
                const rs = try renderValue(allocator, r);
                defer allocator.free(rs);
                const s = try std.mem.concat(allocator, u8, &.{ g.get().bytes, rs });
                return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
            }
            if (r.* == .String) {
                const ls = try renderValue(allocator, l);
                defer allocator.free(ls);
                const g = r.String.borrow();
                defer g.deinit();
                const s = try std.mem.concat(allocator, u8, &.{ ls, g.get().bytes });
                return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
            }
        },
        .Sub => {
            if (l.* == .Int and r.* == .Int) return ok(.{ .Int = l.Int -% r.Int });
            if (l.* == .Char and r.* == .Char) return ok(.{ .Int = @as(i32, l.Char) - @as(i32, r.Char) });
            if (l.* == .Char and r.* == .Int) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) -% @as(i64, r.Int)))) });
            if (l.* == .Char and r.* == .Long) return ok(.{ .Char = @truncate(@as(u64, @bitCast(@as(i64, l.Char) -% r.Long))) });
            if (l.* == .Long and r.* == .Long) return ok(.{ .Long = l.Long -% r.Long });
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = l.Long -% @as(i64, r.Int) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = @as(i64, l.Int) -% r.Long });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double - @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) - r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double - @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) - r.Double });
            if (l.* == .UInt and r.* == .UInt) return ok(.{ .UInt = l.UInt -% r.UInt });
            if (l.* == .ULong and r.* == .ULong) return ok(.{ .ULong = l.ULong -% r.ULong });
            if (l.* == .ULong and r.* == .UInt) return ok(.{ .ULong = l.ULong -% @as(u64, r.UInt) });
            if (l.* == .UInt and r.* == .ULong) return ok(.{ .ULong = @as(u64, l.UInt) -% r.ULong });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float - r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) - r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double - @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) - r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float - @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) - r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float - @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double - r.Double });
        },
        .Mul => {
            if (l.* == .Int and r.* == .Int) return ok(.{ .Int = l.Int *% r.Int });
            if (l.* == .Long and r.* == .Long) return ok(.{ .Long = l.Long *% r.Long });
            if (l.* == .Long and r.* == .Int) return ok(.{ .Long = l.Long *% @as(i64, r.Int) });
            if (l.* == .Int and r.* == .Long) return ok(.{ .Long = @as(i64, l.Int) *% r.Long });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double * @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) * r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double * @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) * r.Double });
            if (l.* == .UInt and r.* == .UInt) return ok(.{ .UInt = l.UInt *% r.UInt });
            if (l.* == .ULong and r.* == .ULong) return ok(.{ .ULong = l.ULong *% r.ULong });
            if (l.* == .ULong and r.* == .UInt) return ok(.{ .ULong = l.ULong *% @as(u64, r.UInt) });
            if (l.* == .UInt and r.* == .ULong) return ok(.{ .ULong = @as(u64, l.UInt) *% r.ULong });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float * r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) * r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double * @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) * r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float * @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) * r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float * @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double * r.Double });
        },
        .Div => {
            if (l.* == .Long and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = divTruncI64(l.Long, r.Long) });
            }
            if (l.* == .Int and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Int = divTruncI32(l.Int, r.Int) });
            }
            if (l.* == .Long and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = divTruncI64(l.Long, @as(i64, r.Int)) });
            }
            if (l.* == .Int and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = divTruncI64(@as(i64, l.Int), r.Long) });
            }
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = l.Double / @as(f64, @floatFromInt(r.Int)) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Int)) / r.Double });
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = l.Double / @as(f64, @floatFromInt(r.Long)) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @as(f64, @floatFromInt(l.Long)) / r.Double });
            if (l.* == .UInt and r.* == .UInt) {
                if (r.UInt == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .UInt = l.UInt / r.UInt });
            }
            if (l.* == .ULong and r.* == .ULong) {
                if (r.ULong == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .ULong = l.ULong / r.ULong });
            }
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = l.Float / r.Float });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @as(f64, l.Float) / r.Double });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = l.Double / @as(f64, r.Float) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Int)) / r.Float });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = l.Float / @as(f32, @floatFromInt(r.Int)) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @as(f32, @floatFromInt(l.Long)) / r.Float });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = l.Float / @as(f32, @floatFromInt(r.Long)) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = l.Double / r.Double });
        },
        .Mod => {
            if (l.* == .Long and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = remTruncI64(l.Long, r.Long) });
            }
            if (l.* == .Int and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Int = remTruncI32(l.Int, r.Int) });
            }
            if (l.* == .Long and r.* == .Int) {
                if (r.Int == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = remTruncI64(l.Long, @as(i64, r.Int)) });
            }
            if (l.* == .Int and r.* == .Long) {
                if (r.Long == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .Long = remTruncI64(@as(i64, l.Int), r.Long) });
            }
            if (l.* == .UInt and r.* == .UInt) {
                if (r.UInt == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .UInt = l.UInt % r.UInt });
            }
            if (l.* == .ULong and r.* == .ULong) {
                if (r.ULong == 0) return errResult(try arithExc(allocator, "/ by zero"));
                return ok(.{ .ULong = l.ULong % r.ULong });
            }
            if (l.* == .Double and r.* == .Long) return ok(.{ .Double = @rem(l.Double, @as(f64, @floatFromInt(r.Long))) });
            if (l.* == .Long and r.* == .Double) return ok(.{ .Double = @rem(@as(f64, @floatFromInt(l.Long)), r.Double) });
            if (l.* == .Double and r.* == .Double) return ok(.{ .Double = @rem(l.Double, r.Double) });
            if (l.* == .Double and r.* == .Int) return ok(.{ .Double = @rem(l.Double, @as(f64, @floatFromInt(r.Int))) });
            if (l.* == .Int and r.* == .Double) return ok(.{ .Double = @rem(@as(f64, @floatFromInt(l.Int)), r.Double) });
            if (l.* == .Float and r.* == .Float) return ok(.{ .Float = @rem(l.Float, r.Float) });
            if (l.* == .Float and r.* == .Double) return ok(.{ .Double = @rem(@as(f64, l.Float), r.Double) });
            if (l.* == .Double and r.* == .Float) return ok(.{ .Double = @rem(l.Double, @as(f64, r.Float)) });
            if (l.* == .Int and r.* == .Float) return ok(.{ .Float = @rem(@as(f32, @floatFromInt(l.Int)), r.Float) });
            if (l.* == .Float and r.* == .Int) return ok(.{ .Float = @rem(l.Float, @as(f32, @floatFromInt(r.Int))) });
            if (l.* == .Long and r.* == .Float) return ok(.{ .Float = @rem(@as(f32, @floatFromInt(l.Long)), r.Float) });
            if (l.* == .Float and r.* == .Long) return ok(.{ .Float = @rem(l.Float, @as(f32, @floatFromInt(r.Long))) });
        },
        .Eq, .NotEq, .BoxedEq, .BoxedNotEq => {
            // A capture `Cell` is a carrier for an anon-object method's outer `var`, never a user value, so it compares by content.
            var lc = l.*;
            while (lc == .Cell) {
                const cg = lc.Cell.borrow();
                lc = cg.get().*;
                cg.deinit();
            }
            var rc = r.*;
            while (rc == .Cell) {
                const cg = rc.Cell.borrow();
                rc = cg.get().*;
                cg.deinit();
            }

            // Mixed-width unsigned equality compares by magnitude (`0u == 0uL`); same-tag and signed pairings stay structural.
            if (std.meta.activeTag(lc) != std.meta.activeTag(rc)) {
                if (asUnsigned(&lc)) |lu| {
                    if (asUnsigned(&rc)) |ru| {
                        const eq = lu == ru;
                        const neg = op == .NotEq or op == .BoxedNotEq;
                        return ok(.{ .Bool = if (neg) !eq else eq });
                    }
                }
                // Mixed-width signed equality compares numerically: Kotlin promotes `1 == 1L`.
                // Boxed `Any` is excluded, `(1 as Any) != (1L as Any)`, and keeps the tag-sensitive comparison.
                if (op == .Eq or op == .NotEq) {
                    if (asSignedI64(&lc)) |ls| {
                        if (asSignedI64(&rc)) |rs| {
                            const eq = ls == rs;
                            return ok(.{ .Bool = if (op == .NotEq) !eq else eq });
                        }
                    }
                    // A Double against a Float compares as Double under IEEE, as
                    // `scalarBin` does: `0.0 == -0.0F`, and NaN equals nothing.
                    if ((lc == .Double and rc == .Float) or (lc == .Float and rc == .Double)) {
                        const a: f64 = if (lc == .Double) lc.Double else @floatCast(lc.Float);
                        const b: f64 = if (rc == .Double) rc.Double else @floatCast(rc.Float);
                        const eq = a == b;
                        return ok(.{ .Bool = if (op == .NotEq) !eq else eq });
                    }
                }
            }
            const eq = if (op == .BoxedEq or op == .BoxedNotEq)
                Value.structuralEqBoxed(&lc, &rc)
            else
                Value.structuralEq(&lc, &rc);
            const neg = op == .NotEq or op == .BoxedNotEq;
            return ok(.{ .Bool = if (neg) !eq else eq });
        },
        .Less, .LessEq, .Greater, .GreaterEq => {
            if (try compareValues(op, l, r)) |b| return ok(.{ .Bool = b });
        },
        .And, .Or, .Xor, .Shl, .Shr, .UShr => {
            if (op == .And and l.* == .Bool and r.* == .Bool) return ok(.{ .Bool = l.Bool and r.Bool });
            if (op == .Or and l.* == .Bool and r.* == .Bool) return ok(.{ .Bool = l.Bool or r.Bool });
            if (scalarBin(op, l.*, r.*)) |v| return ok(v);
            if (ev_exec.wideScalarBin(op, l.*, r.*)) |v| return ok(v);
        },
        .RangeTo, .RangeUntil => {
            if (try rangeValue(allocator, op, l, r)) |v| return ok(v);
        },
        .StringConcat => {
            if (try concatInPlace(allocator, l, r)) |s| return ok(.{ .String = s });
            const ls = try renderValue(allocator, l);
            defer allocator.free(ls);
            const rs = try renderValue(allocator, r);
            defer allocator.free(rs);
            const s = try std.mem.concat(allocator, u8, &.{ ls, rs });
            return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
        },
        else => {},
    }
    const lstr = l.display(allocator) catch "?";
    const rstr = r.display(allocator) catch "?";
    const msg = try std.fmt.allocPrint(allocator, "BinOp.{s} on {s} and {s}", .{ @tagName(op), lstr, rstr });
    dumpFrameChainForDiag();
    return errResult(.{ .Type = msg });
}

fn asUnsigned(v: *const Value) ?u64 {
    return switch (v.*) {
        .UByte => |x| x,
        .UShort => |x| x,
        .UInt => |x| x,
        .ULong => |x| x,
        else => null,
    };
}

fn asSignedI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Byte => |x| x,
        .Short => |x| x,
        .Int => |x| x,
        .Long => |x| x,
        else => null,
    };
}

/// Order an unsigned `u` against a signed `s`: any negative `s` is below `u`.
fn cmpU64I64(u: u64, s: i64) std.math.Order {
    if (s < 0) return .gt;
    return std.math.order(u, @as(u64, @intCast(s)));
}

fn invertOrder(o: std.math.Order) std.math.Order {
    return switch (o) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

/// Comparison dispatch for `<`, `<=`, `>`, `>=`; `null` for an unhandled operand pairing.
/// A signed number as one of the three kinds a mixed comparison widens
/// through; null for any other value.
const Widened = union(enum) { Long: i64, Float: f32, Double: f64 };

fn widenedSigned(v: *const Value) ?Widened {
    return switch (v.*) {
        .Byte => |x| .{ .Long = x },
        .Short => |x| .{ .Long = x },
        .Int => |x| .{ .Long = x },
        .Long => |x| .{ .Long = x },
        .Float => |x| .{ .Float = x },
        .Double => |x| .{ .Double = x },
        else => null,
    };
}

fn asF64Of(w: Widened) f64 {
    return switch (w) {
        .Long => |x| @floatFromInt(x),
        .Float => |x| x,
        .Double => |x| x,
    };
}

fn asF32Of(w: Widened) f32 {
    return switch (w) {
        .Long => |x| @floatFromInt(x),
        .Float => |x| x,
        .Double => |x| @floatCast(x),
    };
}

fn compareValues(op: BinOp, l: *const Value, r: *const Value) Allocator.Error!?bool {
    const Pair = struct {
        fn cmpOrder(o: BinOp, order: std.math.Order) bool {
            return switch (o) {
                .Less => order == .lt,
                .LessEq => order != .gt,
                .Greater => order == .gt,
                .GreaterEq => order != .lt,
                else => unreachable,
            };
        }
        // IEEE-754: any relational comparison with a NaN is false, which Zig's float operators honor and `std.math.order` asserts against.
        fn cmpFloat(o: BinOp, a: f64, b: f64) bool {
            return switch (o) {
                .Less => a < b,
                .LessEq => a <= b,
                .Greater => a > b,
                .GreaterEq => a >= b,
                else => unreachable,
            };
        }
    };
    if (l.* == .Int and r.* == .Int) return Pair.cmpOrder(op, std.math.order(l.Int, r.Int));
    if (l.* == .Long and r.* == .Long) return Pair.cmpOrder(op, std.math.order(l.Long, r.Long));
    if (l.* == .Double and r.* == .Double) return Pair.cmpFloat(op, l.Double, r.Double);
    if (l.* == .Float and r.* == .Float) return Pair.cmpFloat(op, @as(f64, l.Float), @as(f64, r.Float));
    if (l.* == .Char and r.* == .Char) return Pair.cmpOrder(op, std.math.order(l.Char, r.Char));
    // `Boolean` is `Comparable`: `false < true` (compareTo ordinal order).
    if (l.* == .Bool and r.* == .Bool) return Pair.cmpOrder(op, std.math.order(@intFromBool(l.Bool), @intFromBool(r.Bool)));
    if (l.* == .UInt and r.* == .UInt) return Pair.cmpOrder(op, std.math.order(l.UInt, r.UInt));
    if (l.* == .ULong and r.* == .ULong) return Pair.cmpOrder(op, std.math.order(l.ULong, r.ULong));
    if (l.* == .UShort and r.* == .UShort) return Pair.cmpOrder(op, std.math.order(l.UShort, r.UShort));
    if (l.* == .UByte and r.* == .UByte) return Pair.cmpOrder(op, std.math.order(l.UByte, r.UByte));
    if (l.* == .Int and r.* == .Long) return Pair.cmpOrder(op, std.math.order(@as(i64, l.Int), r.Long));
    if (l.* == .Long and r.* == .Int) return Pair.cmpOrder(op, std.math.order(l.Long, @as(i64, r.Int)));
    if (asUnsigned(l)) |lu| {
        if (asUnsigned(r)) |ru| return Pair.cmpOrder(op, std.math.order(lu, ru));
        if (asSignedI64(r)) |ri| return Pair.cmpOrder(op, cmpU64I64(lu, ri));
    }
    if (asUnsigned(r)) |ru| {
        if (asSignedI64(l)) |li| return Pair.cmpOrder(op, invertOrder(cmpU64I64(ru, li)));
    }
    // Mixed signed operands widen as the JVM's comparisons do: to Double when
    // either side is one, else to Float when either side is one (`i2f`
    // rounds, so `16777217 > 16777216f` is false), else to Long.
    if (widenedSigned(l)) |lw| if (widenedSigned(r)) |rw| {
        if (lw == .Double or rw == .Double) return Pair.cmpFloat(op, asF64Of(lw), asF64Of(rw));
        if (lw == .Float or rw == .Float) return Pair.cmpFloat(op, @as(f64, asF32Of(lw)), @as(f64, asF32Of(rw)));
        return Pair.cmpOrder(op, std.math.order(lw.Long, rw.Long));
    };
    if (l.* == .String and r.* == .String) {
        const lg = l.String.borrow();
        defer lg.deinit();
        const rg = r.String.borrow();
        defer rg.deinit();
        return Pair.cmpOrder(op, utf16Cmp(lg.get().bytes, rg.get().bytes));
    }
    return null;
}

/// `a..b` / `a..<b` as a value; `null` for an unhandled operand pairing.
pub fn rangeValue(allocator: Allocator, op: BinOp, l: *const Value, r: *const Value) Allocator.Error!?Value {
    // UByte/UShort promote to a UInt range, mirroring Kotlin's `UByte.rangeTo`.
    var start: i64 = undefined;
    var bound: i64 = undefined;
    var kind: RangeKind = undefined;
    if (l.* == .Int and r.* == .Int) {
        start = l.Int;
        bound = r.Int;
        kind = .Int;
    } else if (l.* == .Char and r.* == .Char) {
        start = l.Char;
        bound = r.Char;
        kind = .Char;
    } else if (l.* == .Long and r.* == .Long) {
        start = l.Long;
        bound = r.Long;
        kind = .Long;
    } else if (l.* == .Int and r.* == .Long) {
        start = l.Int;
        bound = r.Long;
        kind = .Long;
    } else if (l.* == .Long and r.* == .Int) {
        start = l.Long;
        bound = r.Int;
        kind = .Long;
    } else if (l.* == .ULong and r.* == .ULong) {
        start = @bitCast(l.ULong);
        bound = @bitCast(r.ULong);
        kind = .ULong;
    } else if (smallUnsigned(l)) |lu| {
        const ru = smallUnsigned(r) orelse return null;
        start = lu;
        bound = ru;
        kind = .UInt;
    } else return null;

    if (op == .RangeUntil) {
        // `a ..< MIN_VALUE` is the kind's EMPTY range; otherwise the inclusive end is one below the bound.
        if (kind.untilEmpty(bound)) {
            const e = kind.emptyBounds();
            return try Value.newRange(allocator, .{ .start = e[0], .end = e[1], .step = 1, .kind = kind });
        }
        bound -= 1;
    }
    return try Value.newRange(allocator, .{ .start = start, .end = bound, .step = 1, .kind = kind });
}

fn smallUnsigned(v: *const Value) ?i64 {
    return switch (v.*) {
        .UByte => |x| @as(i64, x),
        .UShort => |x| @as(i64, x),
        .UInt => |x| @as(i64, x),
        else => null,
    };
}

fn promoteByteShort(v: *const Value) ?Value {
    return switch (v.*) {
        .Byte => |b| .{ .Int = @as(i32, b) },
        .Short => |s| .{ .Int = @as(i32, s) },
        else => null,
    };
}

fn promoteUByteUShort(v: *const Value) ?Value {
    return switch (v.*) {
        .UByte => |b| .{ .UInt = @as(u32, b) },
        .UShort => |s| .{ .UInt = @as(u32, s) },
        else => null,
    };
}

/// Truncating integer division with `MIN / -1` wrapping to `MIN`.
pub fn divTruncI64(a: i64, b: i64) i64 {
    if (a == std.math.minInt(i64) and b == -1) return std.math.minInt(i64);
    return @divTrunc(a, b);
}

pub fn divTruncI32(a: i32, b: i32) i32 {
    if (a == std.math.minInt(i32) and b == -1) return std.math.minInt(i32);
    return @divTrunc(a, b);
}

pub fn remTruncI64(a: i64, b: i64) i64 {
    if (a == std.math.minInt(i64) and b == -1) return 0;
    return @rem(a, b);
}

pub fn remTruncI32(a: i32, b: i32) i32 {
    if (a == std.math.minInt(i32) and b == -1) return 0;
    return @rem(a, b);
}

pub fn envVarSet(name: []const u8) bool {
    return runtime.procEnvIsSet(std.heap.page_allocator, name);
}

pub fn constStr(module: *const Module, id: ConstId) ?[]const u8 {
    return switch (module.consts.items[id.int()]) {
        .String => |s| s,
        else => null,
    };
}

pub inline fn fastIndexGet(recv: *const Value, idx_v: *const Value) ?Value {
    if (idx_v.* != .Int) return null;
    const idx = idx_v.Int;
    if (idx < 0) return null;
    const ui: usize = @intCast(idx);
    switch (recv.*) {
        .Array => |arr| switch (arr.storage()) {
            .scalars => |pb| {
                // Read without the cell's lock: an array's buffer never moves
                // once made, and an element is at most a word, which a racing
                // store replaces whole, as the JVM's array reads see stores.
                const buf = &pb.cell.data;
                if (ui >= buf.len()) return null;
                // An unsigned array over signed backing (`UIntArray(intArray)`)
                // tags elements by `arr.prim`, not the buffer's storage kind.
                return buf.getAs(ui, arr.primKind() orelse buf.kind); // fresh scalar
            },
            .boxed => |vl| {
                // No lock where no count is kept: an array's buffer never moves.
                if (!runtime.reclaimEnabled()) if (vl.readAt(ui)) |elem| return elem;
                const g = vl.borrow();
                defer g.deinit();
                const items = g.get().items;
                if (ui >= items.len) return null;
                const elem = items[ui];
                elem.retain();
                return elem;
            },
        },
        .List => |l| {
            // No lock for a list that is no view (`readAtMoving`).
            if (l.backing == null and runtime.lockfreeReads() and !runtime.reclaimEnabled()) {
                if (l.items.readAtMoving(ui)) |elem| return elem;
            }
            // A stale subList view must fail fast: the slow path's read guard
            // throws ConcurrentModificationException.
            // An array `.asList()` view re-reads its scalar source so a later
            // array write shows through on this indexed load.
            recv.refreshArrayView();
            recv.refreshSublistView();
            const g = l.items.borrow();
            defer g.deinit();
            const items = g.get().items;
            if (ui >= items.len) return null;
            const elem = items[ui];
            elem.retain();
            return elem;
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            const sd = g.get();
            // The UTF-16 unit at `ui` is byte `ui` when every byte is ASCII;
            // otherwise the cursor-resumed walk answers, so an in-bounds index
            // is served here whatever the string holds. Out of bounds is the
            // one case left, and the caller raises it.
            if (sd.ascii) return if (ui < sd.bytes.len) .{ .Char = sd.bytes[ui] } else null;
            return if (sd.utf16UnitAt(ui)) |u| .{ .Char = u } else null;
        },
        // A builder carries no immutable header, so its ASCII-ness, length and
        // cursor live in the reader memo every mutating builtin invalidates.
        .StringBuilder => |sb| {
            const g = sb.borrow();
            defer g.deinit();
            const items = g.get().items;
            const m = runtime.sbMemoFor(@intFromPtr(sb.cell), items);
            if (m.ascii) return if (ui < items.len) .{ .Char = items[ui] } else null;
            return if (runtime.sbUnitAt(m, items, ui)) |u| .{ .Char = u } else null;
        },
        else => return null,
    }
}

/// Indexed-store fast path for `a[i] = v` on an `Array` or a plain mutable
/// `List`, with the `coll_array_set` ownership: release the overwritten element,
/// retain the incoming one. Returns the set-EXPRESSION's value, `Unit` for an
/// array and the PREVIOUS element for a list per Kotlin's `MutableList.set`.
/// Out-of-bounds, an immutable receiver and a live view return null.
pub inline fn fastIndexSet(allocator: Allocator, recv: *const Value, idx_v: *const Value, new_val: Value) ?Value {
    if (idx_v.* != .Int) return null;
    const idx = idx_v.Int;
    if (idx < 0) return null;
    const ui: usize = @intCast(idx);
    switch (recv.*) {
        .Array => |arr| switch (arr.storage()) {
            .scalars => |pb| {
                const g = pb.borrowMut();
                defer g.deinit();
                if (ui >= g.get().len()) return null;
                g.get().setAs(ui, new_val, arr.primKind() orelse g.get().kind);
                return Value.Unit;
            },
            .boxed => |vl| {
                const g = vl.borrowMutAt(ui);
                defer g.deinit();
                const items = g.get().items;
                if (ui >= items.len) return null;
                if (runtime.reclaimEnabled()) {
                    items[ui].release(allocator);
                    new_val.retain();
                }
                items[ui] = new_val;
                return Value.Unit;
            },
        },
        .List => |l| {
            if (!l.mutable or l.backing != null) return null;
            const g = l.items.borrowMutAt(ui);
            defer g.deinit();
            const items = g.get().items;
            if (ui >= items.len) return null;
            if (runtime.reclaimEnabled()) new_val.retain();
            const prev = items[ui];
            items[ui] = new_val;
            return prev;
        },
        else => return null,
    }
}
