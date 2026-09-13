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
            // Name the frame and its function so a wrong-value branch is
            // attributable without a debugger: the value alone cannot say
            // WHICH branch mis-wired.
            const fname: []const u8 = if (currentFrameFunc()) |cf| cf.fqn else "?";
            const fid: u32 = if (currentFrameFunc()) |cf| cf.id.int() else 0;
            const sp: ?span.Span = if (ev_state.evtls.frame_chain) |fr| fr.cur_span else null;
            const msg = if (sp) |p2|
                try std.fmt.allocPrint(allocator, "non-bool in branch: {s} (in {s}#{d} at f{d}:{d})", .{ s, fname, fid, p2.file.int(), p2.start })
            else
                try std.fmt.allocPrint(allocator, "non-bool in branch: {s} (in {s}#{d})", .{ s, fname, fid });
            return .{ .err = .{ .Type = msg } };
        },
    }
}

pub fn constMatches(module: *const Module, id: ConstId, v: *const Value) bool {
    const c = &module.consts.items[id.int()];
    // String switch keys (`when (s) { "lit" -> … }`) compare by content
    // against the subject without allocating a StringRef for the key.
    if (c.* == .String) {
        if (v.* != .String) return false;
        const g = v.String.borrow();
        defer g.deinit();
        return std.mem.eql(u8, c.String, g.get().bytes);
    }
    // An unsuffixed integer literal takes the subject's type (`when (l:
    // Long) { 42 -> }` compares `42L`), so an integral key compares by
    // value against any signed integral subject, and an unsigned key
    // against any unsigned one.
    switch (c.*) {
        .Int, .Long, .Short, .Byte => {
            const k: i64 = switch (c.*) {
                .Int => |i| i,
                .Long => |l| l,
                .Short => |x| x,
                .Byte => |x| x,
                else => unreachable,
            };
            return switch (v.*) {
                .Int => |i| i == k,
                .Long => |l| l == k,
                .Short => |x| @as(i64, x) == k,
                .Byte => |x| @as(i64, x) == k,
                else => false,
            };
        },
        .UInt, .ULong, .UShort, .UByte => {
            const k: u64 = switch (c.*) {
                .UInt => |x| x,
                .ULong => |x| x,
                .UShort => |x| x,
                .UByte => |x| x,
                else => unreachable,
            };
            return switch (v.*) {
                .UInt => |x| @as(u64, x) == k,
                .ULong => |x| x == k,
                .UShort => |x| @as(u64, x) == k,
                .UByte => |x| @as(u64, x) == k,
                else => false,
            };
        },
        else => {},
    }
    var lhs = constToValueNoAlloc(c);
    return Value.structuralEq(&lhs, v);
}

/// `const_to_value` for non-String consts: avoids an allocator when the
/// caller only compares structurally. String consts are handled directly
/// in `constMatches`, so this maps them to `.Null`.
fn constToValueNoAlloc(c: *const Const) Value {
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
        .String => .Null, // handled by constToValue; never a switch key
        .Null => .Null,
    };
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
            // Negating NaN keeps the canonical quiet NaN instead of the
            // IEEE sign-bit flip: `Double.NaN` is declared upstream as
            // `-(0.0/0.0)` and every platform's constant evaluation yields
            // the canonical positive NaN (the commonTest pins
            // `Double.NaN.toRawBits() == 0x7FF8000000000000`).
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
    }
    const s = v.display(allocator) catch "?";
    const msg = try std.fmt.allocPrint(allocator, "UnOp.{s} on {s} ({s})", .{ @tagName(op), s, @tagName(v.*) });
    return errResult(.{ .Type = msg });
}

/// Render a Value to its Kotlin string representation. For
/// `Value.Instance`, dispatches `toString()` through the host so
/// user-defined overrides fire; primitives use `renderValue`'s fast
/// path. Caller owns the returned string.
pub fn stringify(comptime H: type, allocator: Allocator, host: *H, v: *const Value) Allocator.Error!union(enum) { ok: []const u8, err: EvalError } {
    // Instances dispatch their `toString()` override; List/Set/Map and the
    // tuple shapes dispatch too so their element `toString()` fires (the fast
    // `renderValue`/`display` formatter prints `ClassName@id` for a user
    // element), and `Result` so `Failure($exception)` interpolates the
    // payload's override. Arrays keep Kotlin's identity `toString`, so they
    // are not included.
    if (v.* == .Instance or v.* == .List or v.* == .Set or v.* == .Map or v.* == .Result or
        v.* == .Pair or v.* == .Triple)
    {
        switch (try host.callMember(allocator, v, "toString", &.{})) {
            .ok => |result| {
                if (result == .String) {
                    const g = result.String.borrow();
                    defer g.deinit();
                    return .{ .ok = try allocator.dupe(u8, g.get().bytes) };
                }
                return .{ .ok = try renderValue(allocator, &result) };
            },
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = try renderValue(allocator, v) };
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
        // `!=` dispatches `equals` too, then negates (see the operator-method
        // caller); without this a user `!=` fell through to structural/identity
        // comparison and `a != b` was true even when `a == b`.
        .NotEq, .BoxedNotEq => "equals",
        .Less, .LessEq, .Greater, .GreaterEq => "compareTo",
        .RangeTo => "rangeTo",
        .RangeUntil => "rangeUntil",
        else => null,
    };
}

/// The in-place compound-assign operator (`plusAssign` family) paired
/// with a binary arithmetic op.
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

/// Render a value into an owned string the way Kotlin's `toString` /
/// string templates do.
fn renderValue(allocator: Allocator, v: *const Value) Allocator.Error![]const u8 {
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

/// Streaming UTF-16 code-unit cursor over a UTF-8 slice. Astral
/// codepoints yield a high surrogate then a low one on the next call.
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

/// Lexicographic compare in UTF-16 code units to match Kotlin's
/// `String.compareTo`.
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

/// Kotlin's defined numeric conversions and operator semantics.
pub fn applyBinop(allocator: Allocator, op: BinOp, l: *const Value, r: *const Value) Allocator.Error!EvalResult {
    // Kotlin promotes `Byte`/`Short` to `Int` in arithmetic and
    // comparison. Widen and re-dispatch.
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
    // Float comparisons widen the Float operand to Double and
    // re-dispatch.
    if ((op == .Less or op == .LessEq or op == .Greater or op == .GreaterEq) and
        (l.* == .Float or r.* == .Float))
    {
        const nl = widenFloat(l);
        const nr = widenFloat(r);
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
            // A boxed capture compares by its CONTENT: the Cell is a
            // carrier (an anon-object method's captured outer `var`),
            // never a user value.
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

            // Mixed-width unsigned equality compares by magnitude
            // (`0u == 0uL`); same-tag and signed paths keep structural equality.
            // Mirrors the relational `compareValues` unsigned reconciliation.
            if (std.meta.activeTag(lc) != std.meta.activeTag(rc)) {
                if (asUnsigned(&lc)) |lu| {
                    if (asUnsigned(&rc)) |ru| {
                        const eq = lu == ru;
                        const neg = op == .NotEq or op == .BoxedNotEq;
                        return ok(.{ .Bool = if (neg) !eq else eq });
                    }
                }
                // Mixed-width SIGNED integer equality compares by numeric value:
                // Kotlin promotes `1 == 1L`. This also reconciles a value whose
                // Long type came from a widened Int literal against a real Long
                // (`const val X: LongAlias = -1` vs a Long `-1`). Boxed `Any`
                // equality is EXCLUDED: `(1 as Any) != (1L as Any)` in Kotlin,
                // so those keep the tag-sensitive structural comparison.
                if (op == .Eq or op == .NotEq) {
                    if (asSignedI64(&lc)) |ls| {
                        if (asSignedI64(&rc)) |rs| {
                            const eq = ls == rs;
                            return ok(.{ .Bool = if (op == .NotEq) !eq else eq });
                        }
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
        },
        .RangeTo, .RangeUntil => {
            if (try rangeValue(allocator, op, l, r)) |v| return ok(v);
        },
        .StringConcat => {
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

/// Comparison dispatch for `<`, `<=`, `>`, `>=`. Returns `null` for an
/// unhandled operand pairing.
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
        // The relational operators `<` `<=` `>` `>=` on concrete Double/Float
        // follow IEEE-754: any comparison involving a NaN is false. Zig's
        // native float operators already honor this, so compare directly
        // instead of going through `std.math.order` (which asserts non-NaN).
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
    // Mixed Int/Long.
    if (l.* == .Int and r.* == .Long) return Pair.cmpOrder(op, std.math.order(@as(i64, l.Int), r.Long));
    if (l.* == .Long and r.* == .Int) return Pair.cmpOrder(op, std.math.order(l.Long, @as(i64, r.Int)));
    // Mixed-width unsigned (`ULong` vs `UInt`, etc.) compare by magnitude.
    if (asUnsigned(l)) |lu| {
        if (asUnsigned(r)) |ru| return Pair.cmpOrder(op, std.math.order(lu, ru));
        // Mixed unsigned / signed: a negative signed value is below every
        // unsigned value; otherwise compare magnitudes. (kotlinc coerces the
        // literal, but a bare pairing still has a well-defined numeric order.)
        if (asSignedI64(r)) |ri| return Pair.cmpOrder(op, cmpU64I64(lu, ri));
    }
    if (asUnsigned(r)) |ru| {
        if (asSignedI64(l)) |li| return Pair.cmpOrder(op, invertOrder(cmpU64I64(ru, li)));
    }
    // Mixed with Double (IEEE relational semantics: the Double side may be NaN).
    if (l.* == .Int and r.* == .Double) return Pair.cmpFloat(op, @as(f64, @floatFromInt(l.Int)), r.Double);
    if (l.* == .Double and r.* == .Int) return Pair.cmpFloat(op, l.Double, @as(f64, @floatFromInt(r.Int)));
    if (l.* == .Long and r.* == .Double) return Pair.cmpFloat(op, @as(f64, @floatFromInt(l.Long)), r.Double);
    if (l.* == .Double and r.* == .Long) return Pair.cmpFloat(op, l.Double, @as(f64, @floatFromInt(r.Long)));
    if (l.* == .String and r.* == .String) {
        const lg = l.String.borrow();
        defer lg.deinit();
        const rg = r.String.borrow();
        defer rg.deinit();
        return Pair.cmpOrder(op, utf16Cmp(lg.get().bytes, rg.get().bytes));
    }
    return null;
}

/// Build a `Range` value for `..` / `..<`. Returns `null` for unhandled
/// operand pairings.
/// `a..b` / `a..<b` as a value. Reads only its operands, so a compiled program
/// builds its ranges through the same function the evaluator uses.
pub fn rangeValue(allocator: Allocator, op: BinOp, l: *const Value, r: *const Value) Allocator.Error!?Value {
    // Resolve the operand pairing to (start, end-bound, kind). UByte/UShort
    // promote to a UInt range, mirroring Kotlin's `UByte.rangeTo` etc.
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
        // `a ..< MIN_VALUE` is empty -> the kind's EMPTY range; otherwise the
        // inclusive end is one before the exclusive bound.
        if (kind.untilEmpty(bound)) {
            const e = kind.emptyBounds();
            return try Value.newRange(allocator, .{ .start = e[0], .end = e[1], .step = 1, .kind = kind });
        }
        bound -= 1;
    }
    return try Value.newRange(allocator, .{ .start = start, .end = bound, .step = 1, .kind = kind });
}

/// A UByte/UShort/UInt value as an i64 (for forming a UInt range), else null.
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

fn widenFloat(v: *const Value) Value {
    return switch (v.*) {
        .Float => |f| .{ .Double = @as(f64, f) },
        else => v.*,
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

// -------------------------------------------------------------------------
// Host — the pluggable dispatch trait the evaluator delegates through.
// -------------------------------------------------------------------------
