//! `klio.StackTraceElement` members. The host renders each captured frame
//! as its function's Kotlin name and where it is, `pkg.Outer.f(File.kt:line)`,
//! or `pkg.Outer.f(Unknown Source)` for a frame without a position, and an
//! element is that text; its members read the parts back. `className` is
//! the name's qualifier, so a top-level function's is its package, and
//! `methodName` its last segment.

const std = @import("std");
const runtime = @import("runtime");

const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const Allocator = std.mem.Allocator;

/// A rendered frame split into its parts.
pub const Frame = struct {
    /// The function's Kotlin name, `pkg.Outer.f`.
    fqn: []const u8,
    /// Null for a frame without a source position.
    path: ?[]const u8,
    line: i32,
};

/// The parts of `text`, a frame as the host renders it.
pub fn parse(text: []const u8) Frame {
    const open = std.mem.findScalarLast(u8, text, '(') orelse return .{ .fqn = text, .path = null, .line = -1 };
    const fqn = text[0..open];
    const inner = std.mem.trimEnd(u8, text[open + 1 ..], ")");
    if (std.mem.eql(u8, inner, "Native Method")) return .{ .fqn = fqn, .path = null, .line = -2 };
    if (std.mem.eql(u8, inner, "Unknown Source")) return .{ .fqn = fqn, .path = null, .line = -1 };
    const colon = std.mem.findScalarLast(u8, inner, ':') orelse return .{ .fqn = fqn, .path = inner, .line = -1 };
    const line = std.fmt.parseInt(i32, inner[colon + 1 ..], 10) catch -1;
    return .{ .fqn = fqn, .path = inner[0..colon], .line = line };
}

fn frameOf(args: []const Value, comptime what: []const u8) union(enum) { frame: Frame, err: EvalResult } {
    if (args.len == 0 or args[0] != .String) {
        return .{ .err = .{ .err = .{ .Type = "StackTraceElement." ++ what ++ " requires a stack trace element" } } };
    }
    return .{ .frame = parse(args[0].String.asPtr().bytes) };
}

fn string(a: Allocator, s: []const u8) Allocator.Error!EvalResult {
    return .{ .ok = .{ .String = try runtime.strInit(a, s) } };
}

/// The qualifier of the frame's function.
pub fn class_name(ctx: *CallCtx) Allocator.Error!EvalResult {
    return classNameOf(ctx.allocator, ctx.args);
}

fn classNameOf(a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const fr = switch (frameOf(args, "className")) {
        .frame => |f| f,
        .err => |e| return e,
    };
    const dot = std.mem.findScalarLast(u8, fr.fqn, '.') orelse return string(a, "");
    return string(a, fr.fqn[0..dot]);
}

/// The frame's function name.
pub fn method_name(ctx: *CallCtx) Allocator.Error!EvalResult {
    return methodNameOf(ctx.allocator, ctx.args);
}

fn methodNameOf(a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const fr = switch (frameOf(args, "methodName")) {
        .frame => |f| f,
        .err => |e| return e,
    };
    const start = if (std.mem.findScalarLast(u8, fr.fqn, '.')) |dot| dot + 1 else 0;
    return string(a, fr.fqn[start..]);
}

/// The name of the frame's source file, null without a position.
pub fn file_name(ctx: *CallCtx) Allocator.Error!EvalResult {
    return fileNameOf(ctx.allocator, ctx.args);
}

fn fileNameOf(a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const fr = switch (frameOf(args, "fileName")) {
        .frame => |f| f,
        .err => |e| return e,
    };
    const path = fr.path orelse return .{ .ok = .Null };
    return string(a, std.fs.path.basename(path));
}

/// The frame's line: `-1` without one, `-2` for a native method, as the
/// JVM has them.
pub fn line_number(ctx: *CallCtx) Allocator.Error!EvalResult {
    return lineNumberOf(ctx.allocator, ctx.args);
}

fn lineNumberOf(_: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const fr = switch (frameOf(args, "lineNumber")) {
        .frame => |f| f,
        .err => |e| return e,
    };
    return .{ .ok = .{ .Int = fr.line } };
}

test "a rendered frame parses into its function, file and line" {
    const f = parse("demo.Box.run(Box.kt:42)");
    try std.testing.expectEqualStrings("demo.Box.run", f.fqn);
    try std.testing.expectEqualStrings("Box.kt", f.path.?);
    try std.testing.expectEqual(@as(i32, 42), f.line);
    const u = parse("demo.main.<anonymous>(Unknown Source)");
    try std.testing.expectEqualStrings("demo.main.<anonymous>", u.fqn);
    try std.testing.expect(u.path == null);
    try std.testing.expectEqual(@as(i32, -1), u.line);
    const n = parse("klio.Thread.sleep(Native Method)");
    try std.testing.expectEqualStrings("klio.Thread.sleep", n.fqn);
    try std.testing.expect(n.path == null);
    try std.testing.expectEqual(@as(i32, -2), n.line);
}

test "the members read the parts of the element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{.{ .String = try runtime.strInit(a, "demo.Outer.Box.run(Box.kt:42)") }};
    try std.testing.expectEqualStrings("demo.Outer.Box", (try classNameOf(a, &args)).ok.String.asPtr().bytes);
    try std.testing.expectEqualStrings("run", (try methodNameOf(a, &args)).ok.String.asPtr().bytes);
    try std.testing.expectEqualStrings("Box.kt", (try fileNameOf(a, &args)).ok.String.asPtr().bytes);
    try std.testing.expectEqual(@as(i32, 42), (try lineNumberOf(a, &args)).ok.Int);
    // A top-level function's qualifier is its package; the root package's
    // functions have none.
    const top = [_]Value{.{ .String = try runtime.strInit(a, "demo.main(main.kt:3)") }};
    try std.testing.expectEqualStrings("demo", (try classNameOf(a, &top)).ok.String.asPtr().bytes);
    try std.testing.expectEqualStrings("main", (try methodNameOf(a, &top)).ok.String.asPtr().bytes);
    const root = [_]Value{.{ .String = try runtime.strInit(a, "main(main.kt:3)") }};
    try std.testing.expectEqualStrings("", (try classNameOf(a, &root)).ok.String.asPtr().bytes);
    try std.testing.expectEqualStrings("main", (try methodNameOf(a, &root)).ok.String.asPtr().bytes);
}
