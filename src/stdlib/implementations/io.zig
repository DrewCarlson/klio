//! io stdlib intrinsics (print / println / readLine / readln / readlnOrNull).
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`. For member access the
//! receiver is `args[0]`, with any further user arguments following.

const std = @import("std");
const runtime = @import("runtime");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

// ============================================================
// io
// ============================================================

/// Render a value via its user-overridden `toString()` when one
/// exists, falling back to the runtime's structural Display
/// rendering. Used by `println` / `print` so plain-class instances
/// pick up `override fun toString()` rather than always landing on
/// the default `ClassName@<hex>` shape.
///
/// The returned bytes are owned by `ctx.allocator`; the caller frees them.
pub fn renderViaUserToString(ctx: *CallCtx, v: *const Value) std.mem.Allocator.Error![]u8 {
    if (v.* == .Instance) {
        if (try ctx.host.invokeMethod(v, "toString", &.{}, ctx.out)) |res| {
            if (res == .ok and res.ok == .String) {
                const g = res.ok.String.borrow();
                const rendered = try ctx.allocator.dupe(u8, g.get().*);
                g.deinit();
                res.ok.String.deinit();
                return rendered;
            }
        }
    }
    return v.display(ctx.allocator);
}

pub fn io_println(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    switch (ctx.args.len) {
        0 => {
            ctx.out.writeln("");
            return ok(.Unit);
        },
        1 => {
            const rendered = try renderViaUserToString(ctx, &ctx.args[0]);
            defer ctx.allocator.free(rendered);
            ctx.out.writeln(rendered);
            return ok(.Unit);
        },
        else => {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "println expects 0 or 1 arguments, got {d}",
                .{ctx.args.len},
            );
            return .{ .err = .{ .Arity = msg } };
        },
    }
}

pub fn io_print(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    switch (ctx.args.len) {
        0 => return ok(.Unit),
        1 => {
            const rendered = try renderViaUserToString(ctx, &ctx.args[0]);
            defer ctx.allocator.free(rendered);
            ctx.out.write(rendered);
            return ok(.Unit);
        },
        else => {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "print expects 0 or 1 arguments, got {d}",
                .{ctx.args.len},
            );
            return .{ .err = .{ .Arity = msg } };
        },
    }
}

pub fn io_read_line(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(ctx.allocator);

    var byte: [1]u8 = undefined;
    var saw_any = false;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch |e| {
            buf.deinit(ctx.allocator);
            const msg = try std.fmt.allocPrint(ctx.allocator, "readLine failed: {s}", .{@errorName(e)});
            return .{ .err = .{ .Type = msg } };
        };
        if (n == 0) break;
        saw_any = true;
        if (byte[0] == '\n') break;
        try buf.append(ctx.allocator, byte[0]);
    }

    if (!saw_any and buf.items.len == 0) {
        buf.deinit(ctx.allocator);
        return ok(.Null);
    }

    // `read_line` keeps the trailing `\n`; we already stop before storing it,
    // so only a trailing `\r` (CRLF) remains to strip.
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\r') {
        _ = buf.pop();
    }

    const owned = try buf.toOwnedSlice(ctx.allocator);
    return ok(.{ .String = try StringRef.init(ctx.allocator, owned) });
}

/// `readlnOrNull()` — identical to `readLine()` (String, or null at EOF).
pub fn io_readln_or_null(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return io_read_line(ctx);
}

/// `readln()` — `readLine()` but throwing `RuntimeException` at EOF.
pub fn io_readln(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = try io_read_line(ctx);
    switch (r) {
        .ok => |v| {
            if (v == .Null) {
                return .{ .err = .{ .Thrown = .{ .Exception = .{
                    .fqn = try StringRef.init(ctx.allocator, "kotlin.RuntimeException"),
                    .message = try StringRef.init(ctx.allocator, "EOF has been reached"),
                    .cause = null,
                } } } };
            }
            return r;
        },
        .err => return r,
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const CaptureOutput = runtime.CaptureOutput;

fn noopCtx(args: []const Value, out: runtime.Output) CallCtx {
    return .{
        .args = args,
        .out = out,
        .host = undefined,
        .allocator = testing.allocator,
    };
}

test "println with no args emits an empty line" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = noopCtx(&.{}, cap.output());
    const r = try io_println(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Unit);
    try testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    try testing.expectEqualStrings("", cap.lines.items[0]);
}

test "println renders its single argument" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{.{ .Int = 42 }};
    var ctx = noopCtx(&args, cap.output());
    const r = try io_println(&ctx);
    try testing.expect(r.ok == .Unit);
    try testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    try testing.expectEqualStrings("42", cap.lines.items[0]);
}

test "println rejects more than one argument" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{ .{ .Int = 1 }, .{ .Int = 2 } };
    var ctx = noopCtx(&args, cap.output());
    const r = try io_println(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Arity);
    defer testing.allocator.free(r.err.Arity);
    try testing.expectEqualStrings("println expects 0 or 1 arguments, got 2", r.err.Arity);
}

test "print with no args writes nothing" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = noopCtx(&.{}, cap.output());
    const r = try io_print(&ctx);
    try testing.expect(r.ok == .Unit);
    try testing.expectEqual(@as(usize, 0), cap.lines.items.len);
    try testing.expectEqual(@as(usize, 0), cap.partial.items.len);
}

test "print writes without a trailing newline" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{.{ .Bool = true }};
    var ctx = noopCtx(&args, cap.output());
    const r = try io_print(&ctx);
    try testing.expect(r.ok == .Unit);
    // No full line recorded; the text sits in the pending partial.
    try testing.expectEqual(@as(usize, 0), cap.lines.items.len);
    try testing.expectEqualStrings("true", cap.partial.items);
}

test "print rejects more than one argument" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{ .{ .Int = 1 }, .{ .Int = 2 } };
    var ctx = noopCtx(&args, cap.output());
    const r = try io_print(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Arity);
    defer testing.allocator.free(r.err.Arity);
    try testing.expectEqualStrings("print expects 0 or 1 arguments, got 2", r.err.Arity);
}

test "render via user to string falls back to structural display" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var noop = runtime.NoopHost.init(testing.allocator);
    defer noop.deinit();
    const v = Value{ .Int = 7 };
    const args = [_]Value{v};
    var ctx = CallCtx{
        .args = &args,
        .out = cap.output(),
        .host = noop.host(),
        .allocator = testing.allocator,
    };
    const s = try renderViaUserToString(&ctx, &ctx.args[0]);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("7", s);
}
